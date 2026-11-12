--!nonstrict
--[[
	Analyseur commun des essais de conduite : la MÊME fonction calcule les grandeurs sur une trace
	FiveM (calibration/<véhicule>/fivem/*.json, tools/fivem-telemetry) et sur une trace Roblox
	(roblox/DriveBench.lua, champ `samples` de chaque essai). Luau pur : tourne sous lune (gta.luau)
	et dans Studio (ModuleScript, côté client du conducteur).

		local A = require(analyze)
		local m = A.run("corner40", columns, rows, { stepCut = true })  -- grandeurs (SI, °, °/s, g, km/h)

	Colonnes utilisées (noms de la télémétrie FiveM) : t (ms), str, hb, vFwd, vLat (m/s), wz (rad/s),
	roll, pitch (°), pz (m), wheelsOnGround.

	Fenêtres d'analyse. Les essais FiveM du créneau, du slalom et du virage 80 ont été faits sur le tablier
	de l'aéroport, dont la bande plate ne fait que ≈ 12 m de large au nord de l'axe de départ : au-delà, à
	y ≈ −3031, le bord du tablier forme une arête longitudinale de ≈ +0,35 m. Le véhicule la
	franchit en biais pendant la manœuvre (créneau ~2,0 s, slalom 8,4 s, virage 80 1,3 s). Tout ce qui suit
	ce franchissement n'est pas de la dynamique de manœuvre. On coupe donc chaque trace (GTA comme Roblox)
	à la même fenêtre `clean` ; côté GTA, on coupe aussi au premier écart d'altitude de caisse > 8 mm.
]]
local A = {}

-- fenêtres (s depuis le début de la manœuvre)
A.Windows = {
	corner40 = { start = 1.0, clean = 4.0, steady = { 2.0, 4.0 } },
	corner80 = { start = 1.0, clean = 1.28, steady = { 1.0, 1.28 } },
	stepsteer = { start = 0.5, clean = 1.9, steady = { 1.0, 1.8 } },
	slalom = { start = 0.39, clean = 8.3 },
	handbrake = {},
	curb20 = {},
	curb60 = {},
}

local function col(columns)
	local ix = {}
	for i, c in ipairs(columns) do
		ix[c] = i
	end
	return function(row, name)
		local i = ix[name]
		return i and row[i] or nil
	end
end

local function deg(x)
	return x * 180 / math.pi
end

local function mean(list)
	if #list == 0 then
		return nil
	end
	local s = 0
	for _, v in ipairs(list) do
		s += v
	end
	return s / #list
end

-- début de la manœuvre : première ligne où |str| atteint la consigne (traces FiveM : l'élan est dans la
-- trace) ; une trace Roblox commence déjà à la manœuvre (index 1)
local function startIndex(g, rows, target)
	if not target then
		return 1
	end
	for i, r in ipairs(rows) do
		if math.abs(g(r, "str") or 0) >= target * 0.99 then
			return i
		end
	end
	return 1
end

-- fin propre : fenêtre `clean`, et premier écart d'altitude de caisse > 8 mm (marche du tablier)
local function cleanEnd(g, rows, i0, clean, stepCut)
	local t0 = g(rows[i0], "t")
	local z0 = stepCut and g(rows[i0], "pz") or nil
	local last = i0
	for i = i0, #rows do
		local r = rows[i]
		if clean and (g(r, "t") - t0) / 1000 > clean then
			break
		end
		if z0 and math.abs(g(r, "pz") - z0) > 0.008 then
			return last, true
		end
		last = i
	end
	return last, false
end

local function lateral(g, r)
	local v = g(r, "vFwd")
	local lat = math.abs(v * g(r, "wz")) / 9.81
	local slip = math.abs(v) > 2 and math.abs(math.deg(math.atan2(g(r, "vLat"), math.abs(v)))) or nil
	return lat, slip
end

local function manoeuvre(test, g, rows, opts)
	local W = A.Windows[test] or {}
	local i0 = startIndex(g, rows, W.start)
	local i1, cut = cleanEnd(g, rows, i0, W.clean, opts.stepCut)
	local t0 = g(rows[i0], "t")
	local m = { window = (g(rows[i1], "t") - t0) / 1000, cutByStep = cut }
	local maxRoll, maxYaw, maxLat, maxSlip, minWheels = 0, 0, 0, 0, 4
	local sLat, sSlip, sRoll, sV, sW = {}, {}, {}, {}, {}
	for i = i0, i1 do
		local r = rows[i]
		local t = (g(r, "t") - t0) / 1000
		local lat, slip = lateral(g, r)
		maxRoll = math.max(maxRoll, math.abs(g(r, "roll")))
		maxYaw = math.max(maxYaw, math.abs(deg(g(r, "wz"))))
		minWheels = math.min(minWheels, g(r, "wheelsOnGround") or 4)
		if math.abs(g(r, "vFwd")) > 2 then
			maxLat = math.max(maxLat, lat)
			maxSlip = math.max(maxSlip, slip or 0)
		end
		if W.steady and t >= W.steady[1] and t <= W.steady[2] then
			table.insert(sLat, lat)
			table.insert(sSlip, slip or 0)
			table.insert(sRoll, math.abs(g(r, "roll")))
			table.insert(sV, math.abs(g(r, "vFwd")))
			table.insert(sW, math.abs(g(r, "wz")))
		end
	end
	m.maxRoll, m.maxYaw, m.peakLatG, m.maxSlip, m.minWheels = maxRoll, maxYaw, maxLat, maxSlip, minWheels
	if #sLat > 0 then
		m.steadyLatG = mean(sLat)
		m.steadySlip = mean(sSlip)
		m.steadyRoll = mean(sRoll)
		m.radius = mean(sV) / math.max(mean(sW), 1e-6)
		m.rollPerG = m.steadyRoll / math.max(m.steadyLatG, 1e-6)
	end
	-- fin de la trace entière (pas seulement de la fenêtre propre) : vitesse de sortie
	m.endSpeedKmh = math.abs(g(rows[#rows], "vFwd")) * 3.6
	local fullMaxSlip = 0
	for i = i0, #rows do
		local _, slip = lateral(g, rows[i])
		fullMaxSlip = math.max(fullMaxSlip, slip or 0)
	end
	m.fullMaxSlip = fullMaxSlip
	return m
end

local function handbrake(g, rows)
	local m = { maxYaw = 0, maxSlip = 0 }
	local started = false
	for _, r in ipairs(rows) do
		if (g(r, "hb") or 0) >= 1 then
			started = true
		end
		if started then
			m.maxYaw = math.max(m.maxYaw, math.abs(deg(g(r, "wz"))))
			local _, slip = lateral(g, r)
			m.maxSlip = math.max(m.maxSlip, slip or 0)
		end
	end
	return m
end

-- Marche : altitude et assiette de référence prises en régime établi avant la marche ; montée de caisse =
-- altitude moyenne une fois posé sur le dessus (assiette revenue à ±0,3 ° de la référence).
local function curb(g, rows)
	local m = { airborneFrames = 0, minWheels = 4, maxDropKmh = 0 }
	-- régime établi : première ligne au-dessus de 90 % de la vitesse finale de croisière
	local vRef = 0
	for _, r in ipairs(rows) do
		vRef = math.max(vRef, math.abs(g(r, "vFwd")))
	end
	local iS
	for i, r in ipairs(rows) do
		if math.abs(g(r, "vFwd")) >= 0.9 * vRef then
			iS = i
			break
		end
	end
	iS = iS or 1
	-- référence : 0,5 s après la stabilisation
	local tS = g(rows[iS], "t")
	local zs, ps = {}, {}
	local iC
	for i = iS, #rows do
		local r = rows[i]
		local dt = (g(r, "t") - tS) / 1000
		if dt >= 0.5 and dt <= 1.5 then
			table.insert(zs, g(r, "pz"))
			table.insert(ps, g(r, "pitch"))
		end
	end
	local z0, p0 = mean(zs) or g(rows[iS], "pz"), mean(ps) or g(rows[iS], "pitch")
	for i = iS, #rows do
		if math.abs(g(rows[i], "pz") - z0) > 0.01 then
			iC = i
			break
		end
	end
	m.basePitch, m.baseZ = p0, z0
	if not iC then
		m.error = "marche non rencontrée"
		return m
	end
	local tC = g(rows[iC], "t")
	local vC = math.abs(g(rows[math.max(iC - 1, 1)], "vFwd"))
	m.entryKmh = vC * 3.6
	local maxP, minP, maxPR = -math.huge, math.huge, 0
	local onTop, vMin, last = {}, math.huge, nil
	for i = iC, #rows do
		local r = rows[i]
		local dt = (g(r, "t") - tC) / 1000
		if dt > 6 then
			break
		end
		local p = g(r, "pitch")
		maxP, minP = math.max(maxP, p), math.min(minP, p)
		if (g(r, "wheelsOnGround") or 4) == 0 then
			m.airborneFrames += 1
		end
		m.minWheels = math.min(m.minWheels, g(r, "wheelsOnGround") or 4)
		local v = math.abs(g(r, "vFwd"))
		vMin = math.min(vMin, v)
		if last then
			m.maxDropKmh = math.max(m.maxDropKmh, (last - v) * 3.6)
			local dtRow = (g(r, "t") - g(rows[i - 1], "t")) / 1000
			if dtRow > 0 then
				maxPR = math.max(maxPR, math.abs(p - g(rows[i - 1], "pitch")) / dtRow)
			end
		end
		last = v
		if g(r, "pz") - z0 > 0.08 and math.abs(p - p0) < 0.3 then
			table.insert(onTop, g(r, "pz") - z0)
		end
	end
	m.pitchUp = maxP - p0 -- cabrage (nez levé) par rapport à l'assiette de croisière
	m.pitchDown = minP - p0 -- plongée (nez baissé)
	m.maxPitchAbs = math.max(math.abs(maxP), math.abs(minP)) -- même définition que maxPitch des résumés
	m.maxPitchRate = maxPR
	m.speedLossKmh = (vC - vMin) * 3.6
	m.bodyRise = mean(onTop)
	return m
end

-- opts.stepCut : couper aussi au premier écart d'altitude de caisse > 8 mm (traces FiveM du tablier ;
-- pas sur la piste Roblox, plate, où la caisse s'enfonce de plus de 8 mm en virage)
function A.run(test, columns, rows, opts)
	opts = opts or {}
	local g = col(columns)
	if #rows == 0 then
		return { error = "trace vide" }
	end
	if test == "handbrake" then
		return handbrake(g, rows)
	elseif test == "curb20" or test == "curb60" then
		return curb(g, rows)
	end
	return manoeuvre(test, g, rows, opts)
end

return A
