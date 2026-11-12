--!nonstrict
--[[
	air.luau — analyse d'un vol au tremplin (contrôle en l'air), LE MÊME CODE pour les traces FiveM
	(tools/fivem-telemetry, essai `airtime`) et les traces Roblox (roblox/DriveBench.lua, Bench.air).
	Module pur : ni Instance ni service, il tourne sous lune comme dans Studio.

		local Air = require(path.to.air)
		local m = Air.analyze(columns, rows, { axis = "roulis", amp = 1 })

	Colonnes utilisées (par nom) : t (ms), roll, pitch (°), wheelsOnGround, wz (rad/s) ; pz et heightAbove
	si présents. Repère commun aux deux traces : roulis + pour « roulis +1 », assiette + nez levé.

	Ce que l'analyse lit, et pourquoi séparément (calibration/m422/README.md, « Contrôle en l'air ») :
	la rotation monte à couple constant PUIS SE FIGE SUR LE PLAFOND ; une accélération moyennée sur tout le vol
	mélange les deux dans une proportion qui dépend de la durée du vol (erreur passée : roulis sous-estimé de
	14 %, tangage positif dans les deux sens). Donc :
	  - le COUPLE : pente (moindres carrés) du taux de l'axe commandé sur la MONTÉE SEULE, du début du vol
	    jusqu'à l'entrée dans la bande du plafond (ou jusqu'à l'extrême s'il n'y a pas de plateau) ;
	  - le PLAFOND : la valeur extrême, retenue seulement si au moins 3 images restent dans sa bande ;
	  - la BORNE : l'assiette la plus basse en piqué.
	Les taux sont dérivés de `roll` et `pitch` par différence centrée, sur les images de vol intérieures.
	Un CHOC (taux qui change de plus de Air.ImpactAccel en une image : la queue qui touche, un rebond) coupe
	la fenêtre : ce qui suit n'est plus du vol commandé. Un vol où un axe dépasse Air.TumbleRate est une
	culbute imprimée par le tremplin : `tumble` = true, à écarter.
]]
local Air = {}
Air.Tol = 2.0 -- °/s : bande du plafond (σ GTA ≈ 1,1 °/s)
Air.MinPlateau = 3 -- images dans la bande pour retenir un plafond
Air.ImpactAccel = 1500 -- °/s² : au-delà en une image, c'est un choc (borne de piqué ≈ 710, commande 91)
Air.TumbleRate = 95 -- °/s : au-delà, le vol ne mesure plus la commande
Air.Fall = 5.0 -- °/s : sous l'extrême de plus que ça, la fenêtre du plafond est finie (borne, choc)
Air.PlateauRatio = 0.35 -- pente du second segment / pente de la montée : en dessous, c'est un plateau

local function slope(ts, ys, i0, i1)
	local n, st, sy, stt, sty = 0, 0, 0, 0, 0
	for k = i0, i1 do
		if ts[k] and ys[k] then
			local t, y = ts[k], ys[k]
			n += 1
			st += t
			sy += y
			stt += t * t
			sty += t * y
		end
	end
	if n < 3 then
		return nil, n
	end
	local den = n * stt - st * st
	if den == 0 then
		return nil, n
	end
	return (n * sty - st * sy) / den, n
end

-- droite des moindres carrés : pente, nombre de points, somme des carrés des résidus
function Air.fit(ts, ys, i0, i1)
	local a, n = slope(ts, ys, i0, i1)
	if not a then
		return nil, n, 0
	end
	local st, sy, c = 0, 0, 0
	for k = i0, i1 do
		if ts[k] and ys[k] then
			st += ts[k]
			sy += ys[k]
			c += 1
		end
	end
	local b = sy / c - a * st / c
	local e = 0
	for k = i0, i1 do
		if ts[k] and ys[k] then
			local d = ys[k] - (a * ts[k] + b)
			e += d * d
		end
	end
	return a, n, e
end

local function r2(x)
	if x == nil or x ~= x then
		return nil
	end
	return math.floor(x * 100 + 0.5) / 100
end

-- Plus long segment d'images consécutives sans aucune roue au sol.
function Air.flight(C, rows)
	local best0, best1, cur0 = nil, nil, nil
	for k, row in ipairs(rows) do
		if row[C.wheelsOnGround] == 0 then
			cur0 = cur0 or k
			if not best0 or (k - cur0) > (best1 - best0) then
				best0, best1 = cur0, k
			end
		else
			cur0 = nil
		end
	end
	return best0, best1
end

function Air.analyze(columns, rows, case)
	local C = {}
	for k, name in ipairs(columns) do
		C[name] = k
	end
	assert(C.t and C.roll and C.pitch and C.wheelsOnGround, "colonnes t, roll, pitch, wheelsOnGround requises")
	local axis = case.axis or "rien"
	local amp = case.amp or 0
	local m = { axis = axis, amp = amp }
	local f0, f1 = Air.flight(C, rows)
	if not f0 or f1 - f0 < 4 then
		m.error = "pas de vol exploitable"
		return m
	end
	local T = function(k)
		return rows[k][C.t] / 1000
	end
	m.flightFrames = f1 - f0 + 1
	-- durée : du premier pas sans contact au premier pas qui retouche (ou à la dernière image de vol)
	m.airSeconds = r2(((rows[f1 + 1] and T(f1 + 1)) or T(f1)) - T(f0))
	m.frameMs = r2((T(f1) - T(f0)) / (f1 - f0) * 1000)
	m.takeoffPitch = r2(rows[f0][C.pitch])

	-- taux par différence centrée, images intérieures du vol
	local ts, rate = {}, { pitch = {}, roll = {}, yaw = {} }
	for k = f0 + 1, f1 - 1 do
		local dt = T(k + 1) - T(k - 1)
		if dt > 0 then
			ts[k] = T(k)
			rate.pitch[k] = (rows[k + 1][C.pitch] - rows[k - 1][C.pitch]) / dt
			rate.roll[k] = (rows[k + 1][C.roll] - rows[k - 1][C.roll]) / dt
			if C.wz then
				rate.yaw[k] = math.deg(rows[k][C.wz])
			end
		end
	end
	local k0, k1 = f0 + 1, f1 - 1

	-- choc : premier pas où le taux de tangage ou de roulis saute de plus de ImpactAccel
	local kCut = k1
	for k = k0 + 1, k1 do
		local dt = (ts[k] and ts[k - 1]) and (ts[k] - ts[k - 1]) or nil
		if dt and dt > 0 then
			for _, ax in ipairs({ "pitch", "roll" }) do
				local acc = (rate[ax][k] - rate[ax][k - 1]) / dt
				if math.abs(acc) > Air.ImpactAccel then
					m.impact = m.impact
						or {
							t = r2(ts[k] - T(f0)),
							axis = ax,
							from = r2(rate[ax][k - 1]),
							to = r2(rate[ax][k]),
							pitch = r2(rows[k][C.pitch]),
							roll = r2(rows[k][C.roll]),
							pz = C.pz and r2(rows[k][C.pz]) or nil,
							heightAbove = C.heightAbove and r2(rows[k][C.heightAbove]) or nil,
						}
					kCut = math.min(kCut, k - 1)
				end
			end
		end
	end
	if C.pz then
		m.pzTakeoff = r2(rows[f0][C.pz])
	end

	-- extrêmes (vol entier) et culbute
	local worst = 0
	m.minPitch, m.maxPitch, m.minRoll, m.maxRoll = math.huge, -math.huge, math.huge, -math.huge
	for k = f0, f1 do
		m.minPitch = math.min(m.minPitch, rows[k][C.pitch])
		m.maxPitch = math.max(m.maxPitch, rows[k][C.pitch])
		m.minRoll = math.min(m.minRoll, rows[k][C.roll])
		m.maxRoll = math.max(m.maxRoll, rows[k][C.roll])
	end
	m.extremeRates = {}
	for _, ax in ipairs({ "pitch", "roll", "yaw" }) do
		local hi, lo = -math.huge, math.huge
		for k = k0, kCut do
			local v = rate[ax][k]
			if v then
				hi, lo = math.max(hi, v), math.min(lo, v)
				worst = math.max(worst, math.abs(v))
			end
		end
		m.extremeRates[ax] = { r2(lo), r2(hi) }
	end
	m.minPitch, m.maxPitch, m.minRoll, m.maxRoll = r2(m.minPitch), r2(m.maxPitch), r2(m.minRoll), r2(m.maxRoll)
	m.worstRate = r2(worst)
	m.tumble = worst > Air.TumbleRate
	m.rateAtTakeoff = { pitch = r2(rate.pitch[k0]), roll = r2(rate.roll[k0]) }

	if axis == "rien" or amp == 0 then
		-- conservation : pente du taux sur tout le vol avant un choc, par axe
		m.drift = {}
		for _, ax in ipairs({ "pitch", "roll" }) do
			local a, n = slope(ts, rate[ax], k0, kCut)
			m.drift[ax] = { accel = r2(a), n = n, from = r2(rate[ax][k0]), to = r2(rate[ax][kCut]) }
		end
		return m
	end

	local ax = (axis == "tangage") and "pitch" or "roll"
	local dir = amp > 0 and 1 or -1
	-- extrême dans le sens commandé, avant un choc
	local kx, qx = nil, -math.huge
	for k = k0, kCut do
		local q = rate[ax][k] and dir * rate[ax][k]
		if q and q > qx then
			kx, qx = k, q
		end
	end
	if not kx then
		m.error = "pas de taux sur l'axe commandé"
		return m
	end
	-- fin de la fenêtre commandée : dernière image encore près de l'extrême (en piqué, la borne fait ensuite
	-- retomber le taux : ce n'est plus le plafond)
	local kLast = kx
	for k = kx, kCut do
		if rate[ax][k] and dir * rate[ax][k] >= qx - Air.Fall then
			kLast = k
		else
			break
		end
	end
	-- la première image intérieure mêle encore le pas où l'entrée n'était pas armée : on part de la suivante
	local kStart = k0 + 1
	-- montée puis plateau : deux droites ajustées de part et d'autre d'une rupture cherchée sur toute la
	-- fenêtre (moindres carrés). Un seuil « à x °/s de l'extrême » ne marche pas : le plateau dérive de
	-- quelques °/s (bruit, couplage des angles d'Euler quand l'assiette varie) et l'extrême tombe à la fin.
	local best = nil
	for kb = kStart + 3, kLast - 2 do
		local a1, n1, e1 = Air.fit(ts, rate[ax], kStart, kb)
		local a2, n2, e2 = Air.fit(ts, rate[ax], kb, kLast)
		if a1 and a2 and n2 >= Air.MinPlateau then
			local e = e1 + e2
			if not best or e < best.e then
				best = { kb = kb, a1 = a1, n1 = n1, a2 = a2, n2 = n2, e = e }
			end
		end
	end
	local plateau = best and dir * best.a1 > 0 and math.abs(best.a2) < Air.PlateauRatio * math.abs(best.a1)
	local kEnd = plateau and best.kb or kx
	local a, n = slope(ts, rate[ax], kStart, kEnd)
	m.torque = { accel = r2(a), n = n, from = r2(rate[ax][kStart]), to = r2(rate[ax][kEnd]), tEnd = r2(ts[kEnd] - T(f0)) }
	local sum, cnt = 0, 0
	if plateau then
		for k = best.kb, kLast do
			if rate[ax][k] then
				sum += rate[ax][k]
				cnt += 1
			end
		end
	end
	m.ceiling = {
		extreme = r2(dir * qx),
		frames = cnt,
		mean = cnt > 0 and r2(sum / cnt) or nil,
		drift = plateau and r2(best.a2) or nil, -- pente du plateau, °/s²
		retained = plateau and cnt >= Air.MinPlateau or false,
	}
	-- dernier taux avant de se poser (ou avant un choc) : ralentit-il ?
	m.rateAtEnd = r2(rate[ax][kCut])
	m.slowdown = r2(qx - dir * rate[ax][kCut]) -- °/s perdus entre l'extrême et la fin du vol commandé
	if ax == "pitch" and dir < 0 then
		-- borne en piqué : assiette la plus basse, et assiette au retour du taux à zéro après l'extrême
		local lo = math.huge
		for k = f0, f1 do
			lo = math.min(lo, rows[k][C.pitch])
		end
		m.bound = { minPitch = r2(lo) }
		for k = kx, k1 do
			if rate.pitch[k] and rate.pitch[k] >= 0 then
				m.bound.pitchAtZeroRate = r2(rows[k][C.pitch])
				m.bound.tZero = r2(ts[k] - T(f0))
				m.bound.zeroAfter = r2(ts[k] - ts[kx])
				break
			end
		end
	end
	m.extreme = ax == "pitch" and (dir > 0 and m.maxPitch or m.minPitch) or (dir > 0 and m.maxRoll or m.minRoll)
	return m
end

return Air
