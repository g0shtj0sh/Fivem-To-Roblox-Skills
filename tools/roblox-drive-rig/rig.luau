--!nonstrict
--[[
	Banc de conduite LONGITUDINAL, hors Roblox.

	VehicleDynamics est un module pur : on peut le faire tourner sous lune
	(https://github.com/lune-org/lune) en lui fournissant des contacts de roue
	a plat et en integrant la vitesse soi-meme. Cela couvre tous les essais en
	ligne droite — acceleration, passages de rapports, vitesse de pointe,
	freinage, roue libre, marche arriere — sans ouvrir Roblox Studio.

	Ce qu'il ne couvre PAS : tout ce qui demande le solveur 3D de Roblox, donc
	le lateral, le roulis, la bordure et la cote. Pour ceux-la, roblox/DriveBench.lua.

	Usage :
	    lune run tools/roblox-drive-rig/rig.luau report
	    lune run tools/roblox-drive-rig/rig.luau report <KDrag> <EngineBrakeG> <FirstGearForce> <IwRel>
	    lune run tools/roblox-drive-rig/rig.luau scan

	Les valeurs de reference sont celles du m422 mesurees dans GTA V (FiveM) :
	calibration/m422/README.md.
]]
local rbx = require("@lune/roblox")
local process = require("@lune/process")
local fs = require("@lune/fs")
local Vector3 = rbx.Vector3

-- VehicleDynamics lit Vector3 comme une GLOBALE, ce que lune ne fournit pas : on
-- recopie le module avec une ligne d'import en tete, puis on require la copie.
local MODULE = "skills/fivem-vehicle-to-roblox/roblox/runtime/VehicleDynamics.lua"
local SHIM = "tools/roblox-drive-rig/.VehicleDynamics.luau"
local IMPORT = 'local Vector3 = require("@lune/roblox").Vector3'
fs.writeFile(SHIM, IMPORT .. string.char(10) .. fs.readFile(MODULE))
local Dyn = require("./.VehicleDynamics")

local R = 0.44
local cfg = {
	Handling = {
		GravityMs2 = 9.8, Gearbox = "auto", MassKg = 2200,
		DriveForce = 0.2,
		DriveMaxFlatVelMs = 1.2 * 135 / 3.6,
		MaxFlatVelMs = 135 / 3.6,
		Gears = 6, DriveInertia = 1.0, DriveBiasFront = 0.5,
		ClutchChangeRateUp = 1.8, ClutchChangeRateDown = 1.8,
		BrakeForce = 0.6, BrakeFront = 2 * 0.65, BrakeRear = 2 * 0.35,
		HandBrakeForce = 0.35,
		TractionCurveMax = 1.9, TractionCurveMin = 1.5, TractionCurveLateralDeg = 19.0,
		TractionFront = 1.0, TractionRear = 1.0,
		TractionLossMult = 0.9, LowSpeedTractionLossMult = 1.0,
		SuspensionUpperLimit = 0.1, SuspensionLowerLimit = -0.18,
		SuspensionForce = 1.4, SuspensionFront = 2 * 0.51, SuspensionRear = 2 * 0.49,
		SuspensionCompDamp = 0.7, SuspensionReboundDamp = 1.2,
		AntiRollBarForce = 0.9, AntiRollFront = 1.0, AntiRollRear = 1.0,
		RollCentreHeightFront = 0.3, RollCentreHeightRear = 0.4,
		DragCoeff = 8.0, SteeringLockDeg = 35.0,
	},
	Wheels = {
		wheel_lf = { Position = { -0.86, -0.35, -1.5 }, Radius = R, Front = true, Left = true, Steer = true },
		wheel_rf = { Position = { 0.86, -0.35, -1.5 }, Radius = R, Front = true, Left = false, Steer = true },
		wheel_lr = { Position = { -0.86, -0.35, 1.5 }, Radius = R, Front = false, Left = true, Steer = false },
		wheel_rr = { Position = { 0.86, -0.35, 1.5 }, Radius = R, Front = false, Left = false, Steer = false },
	},
}

local DT = 1 / 60
local function newSim(ov) return Dyn.new(cfg, Vector3.new(0, 0, 0), ov) end

local function step(sim, v, inp)
	local contacts = {}
	for i, w in ipairs(sim.P.wheels) do
		contacts[i] = { grounded = true, x = w.x0, xdot = 0, vLong = v, vLat = 0, grip = 1 }
	end
	local out = Dyn.step(sim, inp, contacts, DT, {
		vBody = Vector3.new(0, 0, -v), wBody = Vector3.new(0, 0, 0), up = Vector3.new(0, 1, 0),
	})
	local ax = 0
	for i in ipairs(sim.P.wheels) do ax += out.wheels[i].Fx end
	ax -= out.body.Z
	return ax, out
end

local FULL = { Throttle = 1, Brake = 0, Steer = 0, Engine = true }
local NONE = { Throttle = 0, Brake = 0, Steer = 0, Engine = true }
local STOP = { Throttle = 0, Brake = 1, Steer = 0, Engine = true }

local function run(ov)
	local res = {}
	local sim = newSim(ov)
	local v, t, dist, gear, lastRpm = 0, 0, 0, 1, 0.2
	res.shifts = {}
	local vmax = 0
	while t < 45 do
		local a, out = step(sim, v, FULL)
		v = math.max(v + a * DT, 0); dist += v * DT; t += DT
		if out.gear > gear then
			table.insert(res.shifts, { from = gear, to = out.gear, kmh = v * 3.6, rpm = lastRpm })
			gear = out.gear
		end
		lastRpm = out.rpm
		if not res.t60 and v * 3.6 >= 60 then res.t60 = t end
		if not res.t100 and v * 3.6 >= 100 then res.t100 = t end
		if not res.v4 and t >= 4.0 then res.v4, res.d4 = v * 3.6, dist end
		vmax = math.max(vmax, v)
	end
	res.vmax = vmax * 3.6

	sim = newSim(ov); v, t = 0, 0
	while v * 3.6 < 100 and t < 45 do
		local a = step(sim, v, FULL); v = math.max(v + a * DT, 0); t += DT
	end
	local v0, tb, db, peak = v, 0, 0, 0
	while v > 0.05 and tb < 20 do
		local a = step(sim, v, STOP)
		peak = math.max(peak, -a); v = math.max(v + a * DT, 0); db += v * DT; tb += DT
	end
	res.brakeDist, res.brakeTime = db, tb
	res.brakeG = (v0 * v0 / (2 * math.max(db, 0.01))) / 9.8
	res.brakePeakG = peak / 9.8

	sim = newSim(ov); v, t = 0, 0
	while v * 3.6 < 110 and t < 45 do
		local a = step(sim, v, FULL); v = math.max(v + a * DT, 0); t += DT
	end
	local vc, dc, tc = v, 0, 0
	while v * 3.6 > 30 and tc < 90 do
		local a = step(sim, v, NONE); v = math.max(v + a * DT, 0); dc += v * DT; tc += DT
	end
	res.coastDist = dc
	res.coastG = ((vc * vc - v * v) / (2 * math.max(dc, 0.01))) / 9.8

	sim = newSim(ov); v, t = 0, 0
	local engaged, dr = nil, 0
	while t < 10 do
		local a, out = step(sim, v, STOP)
		v += a * DT; t += DT
		if out.reverse and not engaged then engaged = t end
		if engaged then
			dr += math.abs(v) * DT
			if t - engaged >= 4 then break end
		end
	end
	res.revKmh, res.revDist = v * 3.6, dr
	return res
end

local M = {
	t60 = 3.44, t100 = 8.90, vmax = 118.9, v4 = 67.3, d4 = 44.1,
	brakeDist = 20.6, brakeTime = 1.57, brakeG = 1.81,
	coastDist = 115.2, coastG = 0.38, revKmh = -48.8, revDist = 41.4,
	shift1 = 40.0, shift2 = 80.7, shift3 = 110.6,
}
local SCORED = { "t60", "t100", "vmax", "v4", "d4", "coastDist", "brakeDist", "revKmh" }

local function score(res)
	local e, n = 0, 0
	for _, k in ipairs(SCORED) do
		local got = res[k]
		if got == nil then return 1e9 end
		local r = (got - M[k]) / math.abs(M[k])
		e += r * r; n += 1
	end
	return math.sqrt(e / n)
end

local mode = (process.args[1] or "report")

if mode == "scan" then
	local best, bestOv = 1e9, nil
	local function try(kd, eb, fg, iw)
		local ov = { KDrag = kd, EngineBrakeG = eb, FirstGearForce = fg, IwRel = iw }
		local s = score(run(ov))
		if s < best then best, bestOv = s, ov end
	end
	-- la trainee est ancree par la pointe (mesure la plus robuste) : on la laisse
	-- varier peu, et on cherche sur le frein moteur, la poussee de 1re et l'inertie
	-- de roue, qui n'a jamais ete mesuree.
	for _, kd in ipairs({ 2.2, 2.3, 2.42, 2.5, 2.6 }) do
		for _, eb in ipairs({ 0.7, 0.9, 1.1, 1.3, 1.5 }) do
			for _, fg in ipairs({ 1.4, 1.6, 1.8, 2.0 }) do
				for _, iw in ipairs({ 0.03, 0.06, 0.10, 0.15, 0.20, 0.25 }) do
					try(kd, eb, fg, iw)
				end
			end
		end
	end
	print(("grossier : KDrag %.2f  EngineBrakeG %.2f  FirstGearForce %.2f  IwRel %.3f  erreur %.4f")
		:format(bestOv.KDrag, bestOv.EngineBrakeG, bestOv.FirstGearForce, bestOv.IwRel, best))
	local c = bestOv
	for i = -2, 2 do
		for j = -2, 2 do
			for k = -2, 2 do
				for l = -2, 2 do
					try(c.KDrag + i * 0.05, c.EngineBrakeG + j * 0.05,
						c.FirstGearForce + k * 0.05, math.max(c.IwRel + l * 0.02, 0.01))
				end
			end
		end
	end
	print(("affine  : KDrag %.3f  EngineBrakeG %.3f  FirstGearForce %.3f  IwRel %.3f  erreur %.4f")
		:format(bestOv.KDrag, bestOv.EngineBrakeG, bestOv.FirstGearForce, bestOv.IwRel, best))
	return
end

local function show(name, res)
	print(("=== %s   (erreur quadratique moyenne %.1f %%)"):format(name, score(res) * 100))
	local function line(lab, got, want, unit)
		print(("   %-24s %9.2f %-5s  GTA %8.2f   ecart %+7.1f %%")
			:format(lab, got, unit, want, (got - want) / math.abs(want) * 100))
	end
	line("0-60 km/h", res.t60 or 99, M.t60, "s")
	line("0-100 km/h", res.t100 or 99, M.t100, "s")
	line("vitesse de pointe", res.vmax, M.vmax, "km/h")
	line("plein gaz 4 s", res.v4 or 0, M.v4, "km/h")
	line("plein gaz 4 s", res.d4 or 0, M.d4, "m")
	for i, s in ipairs(res.shifts) do
		if i <= 3 then
			line(("passage %d->%d"):format(s.from, s.to), s.kmh, M["shift" .. i], "km/h")
			print(("   %-24s regime %.3f"):format("", s.rpm))
		end
	end
	line("100-0 distance", res.brakeDist, M.brakeDist, "m")
	line("100-0 temps", res.brakeTime, M.brakeTime, "s")
	line("100-0 deceleration", res.brakeG, M.brakeG, "g")
	line("roue libre 110-30", res.coastDist, M.coastDist, "m")
	line("roue libre 110-30", res.coastG, M.coastG, "g")
	line("marche arriere 4 s", res.revKmh, M.revKmh, "km/h")
	line("marche arriere 4 s", res.revDist, M.revDist, "m")
	local sim = newSim(nil)
	print(("   %-24s %9.2f km/h"):format("PredictTopSpeed", Dyn.PredictTopSpeed(sim) * 3.6))
	print(("   %-24s muMax %.2f g  muMin %.2f g  alphaPeak %.2f deg  dragK %.3e")
		:format("parametres", sim.P.muMax, sim.P.muMin, math.deg(sim.P.alphaPeak), sim.P.dragK))
end

local kd, eb, fg = process.args[2], process.args[3], process.args[4]
if kd then
	local ov = { KDrag = tonumber(kd), EngineBrakeG = tonumber(eb), FirstGearForce = tonumber(fg),
		IwRel = tonumber(process.args[5]) }
	show(("KDrag %s  EngineBrakeG %s  FirstGearForce %s  IwRel %s"):format(kd, eb, fg,
		tostring(process.args[5])), run(ov))
else
	show("CALAGE APPLIQUE (valeurs par defaut du module)", run(nil))
end
