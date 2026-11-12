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
		Bench.stepsteer(60, 0.5)                 -- créneau : consigne GTA 0,5 (demande effective 1/3, zone morte)
		Bench.slalom(60, 0.5, 2, 12)             -- slalom : consigne sinus (amplitude, période s, durée s), écrêtée par la zone morte
		Bench.air(90, "roulis", 1)               -- vol au tremplin (Track.buildRamp) : entrée en vol libre seulement
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

-- `str` = consigne passée à GTA (brute, comme dans les traces FiveM : l'analyseur y cale ses fenêtres) ;
-- `strEff` = demande réellement donnée au moteur après la zone morte ; `steerDeg` = braquage de roue
-- appliqué par VehicleDynamics (°, angle unique des deux roues avant, signe du moteur).
Bench.Columns = {
	"t", "str", "thr", "brk", "hb", "vFwd", "vLat", "wz", "roll", "pitch", "pz", "wheelsOnGround", "gear",
	"strEff", "steerDeg",
}

-- Zone morte de l'axe analogique de GTA, MESURÉE à 0,2501 (calibration/m422/README.md, « La direction, à
-- consigne constante ») : une consigne c donne la demande sign(c) × max(0, (|c| − 0,25) / 0,75). Les essais
-- FiveM ont été enregistrés avec des consignes brutes (créneau 0,50 → 1/3 ; slalom 0,5 sin → sinus écrêté) :
-- le banc alimente donc le moteur avec la demande EFFECTIVE, pas la consigne.
Bench.GtaDeadzone = 0.25
function Bench.gtaAxis(c)
	local dz = Bench.GtaDeadzone
	local m = math.max(0, (math.abs(c) - dz) / (1 - dz))
	return (c < 0 and -1 or 1) * math.min(m, 1)
end

local function r3(x)
	return math.floor((x or 0) * 1000 + 0.5) / 1000
end

-- une ligne d'échantillon (colonnes Bench.Columns), `t` en ms comme les traces FiveM
local function sampleRow(a, t0, inputs)
	local s = state(a)
	local i = inputs or Drive.Override or {}
	local S = a.sim and a.sim.S
	return {
		math.floor((os.clock() - t0) * 1000 + 0.5), r3(i.Consigne or i.Steer), r3(i.Throttle), r3(i.Brake),
		i.Handbrake and 1 or 0,
		r3(s.speed), r3(s.lat), r3(s.yawRate), r3(s.roll), r3(s.pitch), r3(s.pos.Y), s.grounded, s.gear or 0,
		r3(i.Steer), r3(S and math.deg(S.steerAngle or 0) or 0),
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
		local c = steer or 1
		return {
			Throttle = math.clamp(0.4 + err * 0.4, 0, 1), Brake = 0, Steer = Bench.gtaAxis(c), Consigne = c,
			Handbrake = false,
		}
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
	local c = steer or 0.5
	local r = { kmh = kmh, steer = c, steerEff = Bench.gtaAxis(c), entrySpeed = state(a).speed * 3.6 }
	local rec = newRec()
	hold(function()
		local th, br = Bench._cruise(state(a), kmh)
		return { Throttle = th, Brake = br, Steer = Bench.gtaAxis(c), Consigne = c, Handbrake = false }
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
		local c = amp * math.sin(2 * math.pi * t / period)
		return { Throttle = th, Brake = br, Steer = Bench.gtaAxis(c), Consigne = c, Handbrake = false }
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

-- Contrôle en l'air au tremplin (TestTrack : Track.buildRamp sur la voie straight, Bench.setLine sur la voie).
-- `axe` : "tangage", "roulis" ou "rien" ; `amp` : −1, 0 ou +1 (convention de la campagne GTA) :
--   tangage amp > 0 lève le nez → Brake = amp ; amp < 0 pique → Throttle = −amp ; roulis → Steer = −amp.
-- Approche à vitesse tenue (`kmh`, consigne GTA 90) en tenant la ligne, jusqu'au décollage. L'ENTRÉE N'EST
-- APPLIQUÉE QUE PENDANT LE VOL LIBRE (quatre roues hors contact, `grounded` == 0) et relâchée dès qu'une roue
-- retouche : la trace isole le vol. Aucun gaz en vol hors du tangage : dans le moteur, W pique du nez.
--
-- Échantillonnage au PAS DE SIMULATION (même liaison que VehicleDrive : BindToSimulation ou PreSimulation),
-- pas à Heartbeat : une fenêtre Studio sans focus rend à ~15 i/s, ce qui laisserait 18 images sur 1,2 s de vol
-- et décalerait l'armement de l'entrée d'une image de rendu. `t` est le temps de simulation cumulé (ms).
--
-- Il n'y a PAS de canal de vitesse angulaire de tangage ni de roulis : les taux sont dérivés des colonnes
-- `pitch` et `roll` par différence centrée, comme l'analyse côté FiveM. Statistiques sur les images de vol
-- seulement (images intérieures pour les taux). `r.samples` couvre 0,5 s avant le décollage jusqu'à 0,3 s après
-- le premier contact ; l'analyse détaillée (couple sur la montée, plafond, borne) est faite par
-- tools/drive-compare/air.luau, le même code que sur les traces GTA.
-- opts : { untilMeters = distance max d'approche (m, 600), airMax = vol max enregistré (s, 4) }
function Bench.air(kmh, axe, amp, opts)
	opts = opts or {}
	local a = active()
	kmh, axe, amp = kmh or 90, axe or "rien", amp or 0
	settle(a)
	local s0 = state(a)
	local r = { kmh = kmh, axis = axe, amp = amp, stepMode = Drive.StepMode }
	local rows = {}
	local simT = 0
	local phase = "approach" -- approach → air → landed → done
	local nAir, iOff, iLand, tLand = 0, nil, nil, nil
	local function flightInputs()
		local i = { Throttle = 0, Brake = 0, Steer = 0, Handbrake = false }
		if axe == "tangage" then
			if amp > 0 then
				i.Brake = amp
			elseif amp < 0 then
				i.Throttle = -amp
			end
		elseif axe == "roulis" then
			i.Steer = -amp
		end
		return i
	end
	local done = false
	local function onStep(dt)
		if done then
			return
		end
		dt = typeof(dt) == "number" and dt or 1 / 60
		simT += dt
		local s = state(a)
		local i
		if phase == "approach" then
			local th, br = cruise(s, kmh)
			i = { Throttle = th, Brake = br, Steer = lineSteer(a), Handbrake = false }
			-- décollage : deux pas consécutifs sans contact (même règle que tools/fivem-telemetry)
			nAir = (s.grounded == 0) and (nAir + 1) or 0
			if nAir >= 2 and s.speed * 3.6 > kmh * 0.5 then
				phase = "air"
				iOff = #rows -- la ligne précédente est la première image sans contact
				r.takeoffSpeed = s.speed * 3.6
				i = flightInputs()
			elseif (s.pos - s0.pos).Magnitude > (opts.untilMeters or 600) then
				r.error = "pas de décollage avant " .. tostring(opts.untilMeters or 600) .. " m"
				done = true
			end
		elseif phase == "air" then
			if s.grounded > 0 then
				phase = "landed"
				iLand = #rows + 1
				tLand = simT
				i = { Throttle = 0, Brake = 0, Steer = 0, Handbrake = false }
			else
				i = flightInputs()
				if simT - (rows[iOff] and rows[iOff][1] / 1000 or simT) > (opts.airMax or 4) then
					phase = "landed"
					iLand = #rows + 1
					tLand = simT
				end
			end
		else
			i = { Throttle = 0, Brake = 0, Steer = 0, Handbrake = false }
			if simT - tLand >= 0.3 then
				done = true
			end
		end
		Drive.SetOverride(i)
		local row = sampleRow(a, 0, i)
		row[1] = math.floor(simT * 1000 + 0.5)
		table.insert(rows, row)
	end
	local conn, unbind
	if Drive.StepMode == "BindToSimulation" then
		local ok, c = pcall(function()
			return RunService:BindToSimulation(onStep, Enum.StepFrequency.Hz60)
		end)
		if ok and c then
			unbind = function()
				pcall(function()
					c:Disconnect()
				end)
			end
		end
	end
	if not unbind then
		conn = RunService.PreSimulation:Connect(onStep)
		unbind = function()
			conn:Disconnect()
		end
		r.stepMode = (r.stepMode or "?") .. "/bench:PreSimulation"
	end
	local t0 = os.clock()
	while not done and os.clock() - t0 < 90 do
		RunService.Heartbeat:Wait()
	end
	done = true
	unbind()
	Drive.SetOverride({ Throttle = 0, Brake = 0, Steer = 0, Handbrake = false })
	if not iOff then
		r.error = r.error or "pas de décollage"
		settle(a)
		return r
	end
	-- colonnes utiles (Bench.Columns)
	local C = {}
	for k, name in ipairs(Bench.Columns) do
		C[name] = k
	end
	iLand = iLand or #rows + 1
	-- images de vol : de iOff à iLand − 1 (aucune roue en contact)
	local f0, f1 = iOff, iLand - 1
	r.flightFrames = f1 - f0 + 1
	r.airSeconds = (rows[iLand] and rows[iLand][1] or rows[f1][1]) / 1000 - rows[f0][1] / 1000
	r.takeoffPitch = rows[f0][C.pitch]
	r.takeoffRoll = rows[f0][C.roll]
	r.landSpeed = rows[math.min(iLand, #rows)][C.vFwd] * 3.6
	r.minPitch, r.maxPitch, r.minRoll, r.maxRoll = math.huge, -math.huge, math.huge, -math.huge
	for k = f0, f1 do
		local row = rows[k]
		r.minPitch = math.min(r.minPitch, row[C.pitch])
		r.maxPitch = math.max(r.maxPitch, row[C.pitch])
		r.minRoll = math.min(r.minRoll, row[C.roll])
		r.maxRoll = math.max(r.maxRoll, row[C.roll])
	end
	-- taux par différence centrée, images de vol intérieures seulement (°/s)
	local rate = { pitch = { -math.huge, math.huge }, roll = { -math.huge, math.huge }, yaw = { -math.huge, math.huge } }
	for k = f0 + 1, f1 - 1 do
		local dtk = (rows[k + 1][1] - rows[k - 1][1]) / 1000
		if dtk > 0 then
			for _, ax in ipairs({ "pitch", "roll" }) do
				local q = (rows[k + 1][C[ax]] - rows[k - 1][C[ax]]) / dtk
				rate[ax][1] = math.max(rate[ax][1], q)
				rate[ax][2] = math.min(rate[ax][2], q)
			end
		end
		local wz = math.deg(rows[k][C.wz])
		rate.yaw[1] = math.max(rate.yaw[1], wz)
		rate.yaw[2] = math.min(rate.yaw[2], wz)
	end
	r.maxPitchRate, r.minPitchRate = rate.pitch[1], rate.pitch[2]
	r.maxRollRate, r.minRollRate = rate.roll[1], rate.roll[2]
	r.maxYawRate, r.minYawRate = rate.yaw[1], rate.yaw[2]
	-- un vol commandé ne peut pas dépasser le plafond (61 °/s) de beaucoup : au-delà de 95 °/s sur un axe,
	-- c'est le tremplin qui a imprimé une culbute, et le vol ne mesure plus rien
	local worst = 0
	for _, v in ipairs({ r.maxPitchRate, r.minPitchRate, r.maxRollRate, r.minRollRate, r.maxYawRate, r.minYawRate }) do
		if v == v and math.abs(v) ~= math.huge then
			worst = math.max(worst, math.abs(v))
		end
	end
	r.worstRate = worst
	r.tumble = worst > 95
	-- échantillons : 0,5 s avant le décollage → 0,3 s après le premier contact
	local tFrom = rows[f0][1] - 500
	local samples = {}
	for _, row in ipairs(rows) do
		if row[1] >= tFrom then
			table.insert(samples, row)
		end
	end
	r.samples = samples
	r.takeoffIndex = f0 - (#rows - #samples) -- indices dans r.samples
	r.landIndex = iLand - (#rows - #samples)
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
