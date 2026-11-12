--!nonstrict
--[[
	DriveBench.lua — banc de mesure de conduite (client du conducteur, en Play).
	Impose des entrées au moteur de conduite (VehicleDrive.SetOverride) et mesure le véhicule conduit.
	Renvoie une table de fonctions ; chaque essai renvoie une table de mesures (unités SI : m, m/s, km/h, s, °).

		local Bench = require(module)            -- ModuleScript (client : loadstring y est interdit)
		Bench.accel(30)                          -- plein gaz : 0-100, 0-max, vitesse de pointe, rapports
		Bench.brake(100)                         -- 100-0 au frein (ou { handbrake = true })
		Bench.corner(40, 1)                      -- virage braquage plein à 40 km/h : roulis, lacet, dérive
		Bench.reverse(4)                         -- marche arrière
		Bench.curb(20, 160)                      -- bordure abordée à 20 km/h, jusqu'à 160 m parcourus
		Bench.hill(20)                           -- démarrage en côte : arrêt, maintien, recul, reprise
		Bench.stepsteer(60, 0.5)                 -- créneau : braquage brusque maintenu à vitesse tenue
		Bench.slalom(60, 0.5, 2, 12)             -- slalom : braquage sinus (amplitude, période s, durée s)
		Bench.trace(seconds, inputs)             -- trace libre, échantillons à chaque image

	Échantillons : chaque essai garde aussi `r.samples`, une ligne par image pendant la manœuvre, avec les
	MÊMES colonnes que la télémétrie FiveM (tools/fivem-telemetry) : Bench.Columns. Le comparateur
	tools/drive-compare/compare.py calcule les mêmes grandeurs sur les deux traces.
	Repère : vFwd + vers l'avant, vLat + vers la droite (m/s) ; wz lacet (rad/s, + = vers la gauche, comme le
	z vers le haut de GTA) ; roll, pitch en degrés (pitch + = nez levé) ; pz hauteur de VehicleRoot (m).

	Chaque essai commence là où se trouve le véhicule : prévoir une piste dégagée devant lui.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Drive = require(ReplicatedStorage:WaitForChild("FiveMVehicles"):WaitForChild("VehicleDrive"))

local Bench = {}

local function active()
	local a = Drive.Get()
	assert(a, "aucun véhicule conduit par le joueur local")
	return a
end

local function state(a)
	local root = a.root
	local spm = a.spm
	local cf = root.CFrame
	local vLocal = cf:VectorToObjectSpace(root.AssemblyLinearVelocity) / spm
	local w = cf:VectorToObjectSpace(root.AssemblyAngularVelocity)
	local _, _, roll = cf:ToOrientation()
	local o = a.out or {}
	return {
		t = os.clock(),
		pos = root.Position / spm,
		speed = -vLocal.Z, -- m/s vers l'avant
		lat = vLocal.X,
		yawRate = w.Y,
		roll = math.deg(math.asin(math.clamp(cf.RightVector.Y, -1, 1))),
		pitch = math.deg(math.asin(math.clamp(cf.LookVector.Y, -1, 1))),
		up = cf.UpVector.Y,
		gear = o.gear,
		grounded = (function()
			local n = 0
			for _, c in ipairs(a.contacts or {}) do
				if c.grounded then
					n += 1
				end
			end
			return n
		end)(),
		rpm = o.rpm,
		clutch = o.clutch,
	}
end

Bench.Columns = { "t", "str", "thr", "brk", "hb", "vFwd", "vLat", "wz", "roll", "pitch", "pz", "wheelsOnGround", "gear" }

local function r3(x)
	return math.floor((x or 0) * 1000 + 0.5) / 1000
end

-- une ligne d'échantillon (colonnes Bench.Columns), `t` en ms comme les traces FiveM
local function sampleRow(a, t0, inputs)
	local s = state(a)
	local i = inputs or Drive.Override or {}
	return {
		math.floor((os.clock() - t0) * 1000 + 0.5), r3(i.Steer), r3(i.Throttle), r3(i.Brake), i.Handbrake and 1 or 0,
		r3(s.speed), r3(s.lat), r3(s.yawRate), r3(s.roll), r3(s.pitch), r3(s.pos.Y), s.grounded, s.gear or 0,
	}
end

-- Tenue de ligne (comme un conducteur) : en ligne droite, le volant corrige l'écart latéral et le cap
-- par rapport à la ligne de départ. Sans elle, une petite dissymétrie (conducteur assis d'un côté)
-- fait tourner le véhicule sur un très grand rayon (mesuré : ~3,7 km).
local line = nil
function Bench.setLine(cf)
	line = cf
end
local function lineSteer(a)
	if not line then
		return 0
	end
	local cf = a.root.CFrame
	local off = line:PointToObjectSpace(cf.Position).X / a.spm -- m à droite de la ligne
	local fwd = line:VectorToObjectSpace(cf.LookVector)
	local heading = math.atan2(fwd.X, -fwd.Z) -- rad, + = vers la droite
	return math.clamp(-(off * 0.15 + heading * 3), -0.4, 0.4) -- Steer -1 = gauche : à droite de la ligne, on braque à gauche
end

-- `inputs` : table fixe, ou fonction (a) -> table recalculée à chaque image (régulateur de vitesse…).
-- Les entrées sont posées AVANT le pas de simulation ; `each` ne sert qu'à mesurer / arrêter.
-- `rec` : table où ajouter une ligne d'échantillon par image (voir Bench.Columns), ou nil.
local function hold(inputs, seconds, each, keepLine, rec)
	local a = Drive.Get()
	local t0 = os.clock()
	while os.clock() - t0 < seconds do
		local i = table.clone(type(inputs) == "function" and inputs(a) or inputs)
		if keepLine and a then
			i.Steer = lineSteer(a)
		end
		Drive.SetOverride(i)
		RunService.Heartbeat:Wait()
		if rec and a then
			table.insert(rec.rows, sampleRow(a, rec.t0, i))
		end
		if each and each(os.clock() - t0) then
			break
		end
	end
end

local function newRec()
	return { t0 = os.clock(), rows = {} }
end

-- arrêt : frein en marche avant ; en marche arrière c'est l'accélérateur qui freine (comme dans GTA :
-- frein maintenu = reculer)
local function stopInputs(a)
	if state(a).speed < -0.5 then
		return { Throttle = 1, Brake = 0, Steer = 0, Handbrake = false }
	end
	return { Throttle = 0, Brake = 1, Steer = lineSteer(a), Handbrake = false }
end

local function settle(a, seconds)
	local t0 = os.clock()
	while os.clock() - t0 < (seconds or 6) do
		Drive.SetOverride(stopInputs(a))
		RunService.Heartbeat:Wait()
		if math.abs(state(a).speed) < 0.2 then
			break
		end
	end
	hold({ Throttle = 0, Brake = 0, Steer = 0 }, 0.3)
end

function Bench.accel(maxSeconds)
	local a = active()
	settle(a)
	local r = { shifts = {} }
	local s0 = state(a)
	local lastGear = s0.gear
	local lastV, lastT = 0, os.clock()
	local plateau = 0
	hold({ Throttle = 1, Brake = 0, Steer = 0, Handbrake = false }, maxSeconds or 30, function(t)
		local s = state(a)
		local kmh = s.speed * 3.6
		if not r.t60 and kmh >= 60 then
			r.t60 = t
		end
		if not r.t100 and kmh >= 100 then
			r.t100 = t
		end
		if s.gear ~= lastGear then
			table.insert(r.shifts, string.format("%d->%d à %.0f km/h, régime %.2f, %.2f s", lastGear or 0, s.gear or 0, kmh, s.rpm or 0, t))
			lastGear = s.gear
		end
		r.vmax = math.max(r.vmax or 0, kmh)
		r.minUp = math.min(r.minUp or 1, s.up)
		-- plateau : moins de 0,3 km/h gagné en 2 s
		if os.clock() - lastT >= 2 then
			plateau = (kmh - lastV < 0.3) and (plateau + 1) or 0
			lastV, lastT = kmh, os.clock()
			if plateau >= 1 and kmh > 30 then
				r.plateauAt = t
				return true
			end
		end
		return false
	end, true)
	r.distance = (state(a).pos - s0.pos).Magnitude
	r.endGear = state(a).gear
	settle(a)
	return r
end

function Bench.brake(fromKmh, opts)
	opts = opts or {}
	local a = active()
	settle(a)
	hold({ Throttle = 1, Brake = 0, Steer = 0 }, 40, function()
		return state(a).speed * 3.6 >= fromKmh
	end, true)
	local s0 = state(a)
	local inputs = opts.handbrake and { Throttle = 0, Brake = 0, Steer = 0, Handbrake = true }
		or { Throttle = 0, Brake = 1, Steer = 0, Handbrake = false }
	local r = { from = s0.speed * 3.6 }
	local rec = newRec()
	hold(inputs, 15, function(t)
		local s = state(a)
		r.maxYaw = math.max(r.maxYaw or 0, math.abs(math.deg(s.yawRate)))
		if s.speed < 0.3 then
			r.time = t
			return true
		end
		return false
	end, not opts.handbrake, rec)
	r.samples = rec.rows
	r.distance = (state(a).pos - s0.pos).Magnitude
	r.decelG = r.time and (s0.speed / r.time / 9.8) or nil
	settle(a)
	return r
end

function Bench.corner(kmh, steer, seconds)
	local a = active()
	settle(a)
	hold({ Throttle = 1, Brake = 0, Steer = 0 }, 30, function()
		return state(a).speed * 3.6 >= kmh
	end, true)
	-- maintient la vitesse (gaz proportionnels, même loi que tools/fivem-telemetry) en braquant à fond
	local r = { kmh = kmh }
	local rec = newRec()
	local p0 = state(a).pos
	hold(function()
		local err = kmh / 3.6 - state(a).speed
		return { Throttle = math.clamp(0.4 + err * 0.4, 0, 1), Brake = 0, Steer = steer or 1, Handbrake = false }
	end, seconds or 4, function()
		local s = state(a)
		r.maxRoll = math.max(r.maxRoll or 0, math.abs(s.roll))
		r.maxYawRate = math.max(r.maxYawRate or 0, math.abs(math.deg(s.yawRate)))
		r.minUp = math.min(r.minUp or 1, s.up)
		r.minWheels = math.min(r.minWheels or 4, s.grounded)
		if math.abs(s.speed) > 2 then
			local beta = math.deg(math.atan2(s.lat, math.abs(s.speed)))
			r.maxSlip = math.max(r.maxSlip or 0, math.abs(beta))
			-- accélération latérale ≈ v × lacet
			r.maxLatG = math.max(r.maxLatG or 0, math.abs(s.speed * s.yawRate) / 9.8)
		end
		return false
	end, false, rec)
	r.samples = rec.rows
	r.endSpeed = state(a).speed * 3.6
	r.displacement = (state(a).pos - p0).Magnitude
	r.rolledOver = (r.minUp or 1) < 0.3
	settle(a)
	return r
end

-- Créneau : vitesse atteinte, 1 s de stabilisation en ligne droite, puis braquage brusque maintenu.
function Bench.stepsteer(kmh, steer, seconds)
	local a = active()
	kmh = kmh or 60
	settle(a)
	hold({ Throttle = 1, Brake = 0, Steer = 0 }, 60, function()
		return state(a).speed * 3.6 >= kmh
	end, true)
	hold(function()
		local th, br = Bench._cruise(state(a), kmh)
		return { Throttle = th, Brake = br, Steer = 0, Handbrake = false }
	end, 1.0, nil, true)
	local r = { kmh = kmh, steer = steer or 0.5, entrySpeed = state(a).speed * 3.6 }
	local rec = newRec()
	hold(function()
		local th, br = Bench._cruise(state(a), kmh)
		return { Throttle = th, Brake = br, Steer = steer or 0.5, Handbrake = false }
	end, seconds or 4, function()
		local s = state(a)
		r.maxYawRate = math.max(r.maxYawRate or 0, math.abs(math.deg(s.yawRate)))
		r.maxRoll = math.max(r.maxRoll or 0, math.abs(s.roll))
		r.minUp = math.min(r.minUp or 1, s.up)
		return false
	end, false, rec)
	r.samples = rec.rows
	r.endSpeed = state(a).speed * 3.6
	settle(a)
	return r
end

-- Slalom : braquage sinus d'amplitude `amp` et de période `period` (s) à vitesse tenue.
function Bench.slalom(kmh, amp, period, seconds)
	local a = active()
	kmh, amp, period = kmh or 60, amp or 0.5, period or 2
	settle(a)
	hold({ Throttle = 1, Brake = 0, Steer = 0 }, 60, function()
		return state(a).speed * 3.6 >= kmh
	end, true)
	local r = { kmh = kmh, amplitude = amp, period = period }
	local rec = newRec()
	local start = os.clock()
	hold(function()
		local th, br = Bench._cruise(state(a), kmh)
		local t = os.clock() - start
		return { Throttle = th, Brake = br, Steer = amp * math.sin(2 * math.pi * t / period), Handbrake = false }
	end, seconds or 12, function()
		local s = state(a)
		r.maxRoll = math.max(r.maxRoll or 0, math.abs(s.roll))
		r.maxYawRate = math.max(r.maxYawRate or 0, math.abs(math.deg(s.yawRate)))
		r.minUp = math.min(r.minUp or 1, s.up)
		return false
	end, false, rec)
	r.samples = rec.rows
	r.endSpeed = state(a).speed * 3.6
	settle(a)
	return r
end

function Bench.reverse(seconds)
	local a = active()
	settle(a)
	local r = {}
	local p0 = state(a).pos
	hold({ Throttle = 0, Brake = 1, Steer = 0 }, seconds or 4, function()
		local s = state(a)
		r.minSpeed = math.min(r.minSpeed or 0, s.speed * 3.6)
		r.gear = s.gear
		return false
	end)
	r.distance = (state(a).pos - p0).Magnitude
	settle(a)
	return r
end

-- gaz / frein pour tenir une vitesse (km/h)
local function cruise(s, kmh)
	local err = kmh / 3.6 - s.speed
	if err < -1.5 then
		return 0, math.clamp(-err * 0.3, 0, 1)
	end
	return math.clamp(0.25 + err * 0.5, 0, 1), 0
end
Bench._cruise = cruise

-- Bordure de trottoir prise de face à vitesse tenue : tangage, roues décollées, vitesse perdue.
function Bench.curb(kmh, untilMeters)
	local a = active()
	settle(a)
	local s0 = state(a)
	local r = { kmh = kmh, maxPitch = 0, maxRoll = 0, minGrounded = 4, airborne = 0, minUp = 1 }
	local rec = newRec()
	local lastV = nil
	local function cruiseInputs()
		local th, br = cruise(state(a), kmh)
		return { Throttle = th, Brake = br, Steer = 0, Handbrake = false }
	end
	hold(cruiseInputs, 60, function(t)
		local s = state(a)
		local dist = (s.pos - s0.pos).Magnitude
		if s.speed * 3.6 > kmh * 0.9 then
			r.reachedAt = r.reachedAt or dist
		end
		if r.reachedAt then
			r.maxPitch = math.max(r.maxPitch, math.abs(s.pitch))
			r.maxRoll = math.max(r.maxRoll, math.abs(s.roll))
			r.minGrounded = math.min(r.minGrounded, s.grounded)
			r.minUp = math.min(r.minUp, s.up)
			if s.grounded == 0 then
				r.airborne += 1
			end
			-- plus forte chute de vitesse d'une image à l'autre (choc)
			if lastV then
				r.maxDrop = math.max(r.maxDrop or 0, (lastV - s.speed) * 3.6)
			end
			lastV = s.speed
		end
		return dist >= (untilMeters or 160)
	end, true, rec)
	r.samples = rec.rows
	r.endSpeed = state(a).speed * 3.6
	r.distance = (state(a).pos - s0.pos).Magnitude
	settle(a)
	return r
end

-- Démarrage en côte : monter à `kmh`, freiner jusqu'à l'arrêt dans la pente, maintenir 1,5 s au frein
-- à main, relâcher tout 2 s (recul ?), puis plein gaz 4 s.
function Bench.hill(kmh, minPitchDeg)
	local a = active()
	settle(a)
	local r = { kmh = kmh }
	local slope = 0
	hold(function()
		local th, br = cruise(state(a), kmh or 20)
		return { Throttle = th, Brake = br, Steer = 0, Handbrake = false }
	end, 40, function(t)
		local s = state(a)
		slope = (s.pitch > (minPitchDeg or 5)) and (slope + 1) or 0
		return slope >= 20 -- ~1/3 s dans la pente
	end, true)
	r.pitch = state(a).pitch
	if r.pitch < (minPitchDeg or 5) then
		r.error = "pente non atteinte"
		return r
	end
	hold({ Throttle = 0, Brake = 1, Steer = 0 }, 6, function()
		return math.abs(state(a).speed) < 0.1
	end, true)
	r.pitchStopped = state(a).pitch
	r.gradeStopped = math.tan(math.rad(r.pitchStopped)) * 100
	local p0 = state(a).pos
	-- frein à main (frein maintenu à l'arrêt = marche arrière, comme dans GTA)
	hold({ Throttle = 0, Brake = 0, Steer = 0, Handbrake = true }, 1.5, nil, true)
	r.creepBrake = (state(a).pos - p0).Magnitude
	local p1 = state(a).pos
	r.minSpeedReleased = 0
	hold({ Throttle = 0, Brake = 0, Steer = 0, Handbrake = false }, 2, function()
		r.minSpeedReleased = math.min(r.minSpeedReleased, state(a).speed * 3.6)
		return false
	end, true)
	r.rollbackReleased = (state(a).pos - p1).Magnitude
	local p2 = state(a).pos
	r.minSpeedLaunch = 0
	hold({ Throttle = 1, Brake = 0, Steer = 0, Handbrake = false }, 4, function()
		local s = state(a)
		r.minSpeedLaunch = math.min(r.minSpeedLaunch, s.speed * 3.6)
		r.launchSpeed = s.speed * 3.6
		return false
	end, true)
	r.launchDistance = (state(a).pos - p2).Magnitude
	r.launchGear = state(a).gear
	settle(a)
	return r
end

function Bench.trace(seconds, inputs)
	local a = active()
	local rows = {}
	hold(inputs, seconds, function(t)
		local s = state(a)
		table.insert(rows, string.format("%.2f;%.2f;%s;%.2f;%.1f;%.1f", t, s.speed * 3.6, tostring(s.gear), s.rpm or 0, s.roll, math.deg(s.yawRate)))
		return false
	end)
	Drive.SetOverride(nil)
	return rows
end

function Bench.release()
	Drive.SetOverride(nil)
end

-- Exporte un résultat en JSON par pages (execute_luau coupe sa réponse vers 64 Ko) :
--   local n = Bench.exportPages(r, 40000) ; Bench.page(i) -> texte de la page i
local pages = {}
function Bench.exportPages(r, size)
	local HttpService = game:GetService("HttpService")
	local out = table.clone(r)
	out.columns = Bench.Columns
	local text = HttpService:JSONEncode(out)
	pages = {}
	size = size or 40000
	for i = 1, #text, size do
		table.insert(pages, string.sub(text, i, i + size - 1))
	end
	return #pages
end
function Bench.page(i)
	return pages[i]
end

return Bench
