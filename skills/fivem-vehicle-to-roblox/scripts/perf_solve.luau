--!nonstrict
--[[
	Calage « performances réelles » (lancé par scripts/f2r/performance.py, ou à la main) :

	    lune run scripts/perf_solve.luau <entree.json> [sortie.json]

	Fait tourner le VRAI moteur de conduite (roblox/runtime/VehicleDynamics.lua) en ligne droite, à plat,
	et cherche les valeurs du handling qui redonnent les performances du vrai véhicule :

	  - vitesse de pointe PHYSIQUE (débridée) : DriveMaxFlatVel est posée pour que le dernier rapport
	    l'atteigne à TOP_RPM du régime, et la traînée pour que la poussée l'égale exactement à cette vitesse ;
	  - 0-100 km/h : DriveForce, par dichotomie sur la simulation complète (départ arrêté, embrayage,
	    passages de rapports, adhérence du mod) ;
	  - le nombre de rapports du vrai véhicule ;
	  - la vitesse bridée d'origine devient un limiteur électronique (cfg.Performance.LimiterKmh), que
	    l'amélioration `Unlimited` (débridage) lève.

	L'adhérence, la suspension, la direction et le freinage restent ceux du mod.

	Entrée : { Handling = {...}, Wheels = {...}, DriveTuning = {...}?, StatMods = {...}?,
	           Target = { ZeroTo100S, VmaxKmh, LimiterKmh?, Gears? } }
	Sortie : { Handling = { valeurs calées }, Result = { mesures du banc }, Upgrades = { aperçu } }
]]
local rbx = require("@lune/roblox")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Vector3 = rbx.Vector3

local TOP_RPM = 0.90 -- régime du dernier rapport à la vitesse de pointe débridée : la marge jusqu'au rupteur
-- absorbe le glissement des pneus (3 à 4 % à pleine vitesse) et laisse monter la vitesse avec les améliorations
local DT = 1 / 60

-- chemin du module : à côté de ce script (../roblox/runtime), lu par luau.load avec Vector3 en globale
local here = (process.args[0] or ""):match("^(.*)[/\\]") or "."
local function findModule()
	local cands = {
		process.env.F2R_DYNAMICS or "",
		here .. "/../roblox/runtime/VehicleDynamics.lua",
		"skills/fivem-vehicle-to-roblox/roblox/runtime/VehicleDynamics.lua",
		"roblox/runtime/VehicleDynamics.lua",
		"../roblox/runtime/VehicleDynamics.lua",
	}
	for _, p in ipairs(cands) do
		if p ~= "" and fs.isFile(p) then
			return p
		end
	end
	error("VehicleDynamics.lua introuvable (variable F2R_DYNAMICS)")
end
local env = setmetatable({ Vector3 = Vector3 }, { __index = getfenv and getfenv(1) or _G })
local Dyn = luau.load(fs.readFile(findModule()), { debugName = "VehicleDynamics", environment = env })()

local inPath = process.args[1]
assert(inPath, "usage : lune run perf_solve.luau <entree.json> [sortie.json]")
local input = serde.decode("json", fs.readFile(inPath))
local target = input.Target or {}

local FULL = { Throttle = 1, Brake = 0, Steer = 0, Engine = true }
local NONE = { Throttle = 0, Brake = 0, Steer = 0, Engine = true }

local function cfgWith(h)
	return {
		Handling = h, Wheels = input.Wheels, DriveTuning = input.DriveTuning, StatMods = input.StatMods,
		Performance = { LimiterKmh = target.LimiterKmh },
	}
end

-- Report de charge longitudinal : en 3D, l'accélération charge l'arrière (et le freinage l'avant) par le
-- tangage de la caisse ; sans lui, une propulsion serait sous-estimée au départ. On l'impose par la
-- compression des contacts, avec l'accélération du pas précédent : ΔN = a · h / empattement.
-- h = hauteur du centre de gravité au-dessus du sol (mesurée à 0,45 m en Studio sur la voiture de
-- référence ; `Target.ComHeightM` pour un autre véhicule).
local COM_H = tonumber(target.ComHeightM) or 0.45
local function step(sim, v, inp, aPrev)
	local P = sim.P
	local zF, zR, nF, nR = 0, 0, 0, 0
	for _, w in ipairs(P.wheels) do
		if w.front then
			zF += w.rest.Z
			nF += 1
		else
			zR += w.rest.Z
			nR += 1
		end
	end
	zF, zR = zF / math.max(nF, 1), zR / math.max(nR, 1)
	local wheelbase = math.max(zR - zF, 0.5)
	local contacts = {}
	for i, w in ipairs(P.wheels) do
		local n = w.front and math.max(nF, 1) or math.max(nR, 1)
		local dN = (aPrev or 0) * COM_H / wheelbase / n * (w.front and -1 or 1)
		local x = w.x0 + dN / math.max(w.k, 1e-6)
		contacts[i] = { grounded = true, x = x, xdot = 0, vLong = v, vLat = 0, grip = 1 }
	end
	local out = Dyn.step(sim, inp, contacts, DT, {
		vBody = Vector3.new(0, 0, -v), wBody = Vector3.new(0, 0, 0), up = Vector3.new(0, 1, 0),
	})
	local ax = 0
	for i in ipairs(P.wheels) do
		ax += out.wheels[i].Fx
	end
	return ax - out.body.Z, out
end

-- accélération plein gaz depuis l'arrêt ; s'arrête à `untilKmh` ou à `tMax`
local function run(h, upgrades, untilKmh, tMax)
	local sim = Dyn.new(cfgWith(h), Vector3.new(0, 0, 0), nil, upgrades)
	for _ = 1, math.floor(0.3 / DT) do
		step(sim, 0, NONE)
	end
	local res = { shifts = {} }
	local v, t, gear, vmax, flat, a = 0, 0, 1, 0, 0, 0
	while t < tMax do
		local out
		a, out = step(sim, v, FULL, a)
		v = math.max(v + a * DT, 0)
		t += DT
		if out.gear > gear then
			table.insert(res.shifts, { From = gear, To = out.gear, Kmh = math.floor(v * 36 + 0.5) / 10 })
			gear = out.gear
		end
		local kmh = v * 3.6
		if not res.t100 and kmh >= 100 then
			res.t100 = t
		end
		if not res.t200 and kmh >= 200 then
			res.t200 = t
		end
		if v > vmax + 0.01 then
			vmax, flat = v, 0
		else
			flat += DT
		end
		if (untilKmh and kmh >= untilKmh) or flat > 4 then
			break
		end
	end
	res.vmax = vmax * 3.6
	res.sim = sim
	return res
end

local function round(x, n)
	local k = 10 ^ (n or 3)
	return math.floor(x * k + 0.5) / k
end

-- ------------------------------------------------------------------ calage
local base = table.clone(input.Handling)
local probe = Dyn.new(cfgWith(base), Vector3.new(0, 0, 0))
local T = probe.T
local gears = tonumber(target.Gears) or base.Gears or 5
if base.Gearbox == "electric" then
	gears = 1
end
local vTop = assert(tonumber(target.VmaxKmh), "Target.VmaxKmh manquant") / 3.6
local h = table.clone(base)
h.Gears = gears
local topRatio = 0.9 -- dernier rapport GTA (aussi le seul rapport d'un électrique)
local flat = vTop * topRatio / TOP_RPM
h.DriveMaxFlatVelMs = flat
h.MaxFlatVelMs = flat / 1.2
h.MaxFlatVelKmh = flat / 1.2 * 3.6
h.DriveMaxFlatVelKmh = flat * 3.6
h.RedlineTopGearKmh = flat / topRatio * 3.6
-- temps de passage du vrai véhicule : GTA met (1 − 0,1) / ClutchChangeRate à refermer l'embrayage, gaz coupés
local shiftS = tonumber(target.ShiftTimeS)
if shiftS and shiftS > 0 then
	h.ClutchChangeRateUp = 0.9 / shiftS
	h.ClutchChangeRateDown = 0.9 / shiftS
	h.ShiftTimeUpS, h.ShiftTimeDownS = shiftS, shiftS
end
local fall = math.max(1 - (T.TorqueFallSlope or 2) * (TOP_RPM - 0.8), 0.6)
local gearForce = (gears == 1) and (T.FirstGearForce or 1) or 1

local function withDrive(D)
	local hh = table.clone(h)
	hh.DriveForce = D
	local dragK = D * topRatio * fall * (h.GravityMs2 or 9.8) * gearForce / (vTop * vTop)
	hh.DragAccelCoeff = dragK / (T.KDrag or 1)
	hh.DragCoeff = hh.DragAccelCoeff * 1e4
	return hh
end

local function t100(D)
	local r = run(withDrive(D), nil, 101, 30)
	return r.t100 or 99
end

local want = tonumber(target.ZeroTo100S)
local D, limited, bestT = nil, false, nil
if want then
	-- t100(D) n'est PAS monotone : trop de force fait patiner (rupteur, adhérence du mod). On repère d'abord le
	-- meilleur temps sur une grille, puis on cherche par dichotomie sur la branche descendante, à gauche.
	local grid, prevD = {}, nil
	local dBest, tBest = nil, math.huge
	local d = 0.03
	while d <= 4.0 do
		local t = t100(d)
		table.insert(grid, { d, t })
		if t < tBest then
			dBest, tBest = d, t
		end
		d *= 1.15
	end
	bestT = tBest
	if tBest > want then
		-- l'adhérence du mod ne permet pas ce temps. On vise 2 % au-dessus du meilleur, sur la branche de
		-- gauche : au meilleur temps exact, la moindre amélioration moteur ferait patiner davantage et
		-- allongerait le 0-100 ; un peu en dessous, elle le raccourcit encore un peu.
		limited = true
		want = tBest * 1.02
	end
	do
		for _, g in ipairs(grid) do
			if g[1] < dBest and g[2] > want then
				prevD = g[1]
			end
		end
		local lo, hi = prevD or 0.01, dBest
		for _ = 1, 30 do
			local m = (lo + hi) / 2
			if t100(m) > want then
				lo = m
			else
				hi = m
			end
		end
		D = hi
	end
else
	D = base.DriveForce or 0.2
end

local hFit = withDrive(D)
local stock = run(hFit, nil, nil, 120)
local unl = run(hFit, { Unlimited = 1 }, nil, 120)
local maxed = run(hFit, { Engine = 4, Transmission = 3, Turbo = 1, Unlimited = 1 }, nil, 120)

local out = {
	Handling = {
		DriveForce = round(D, 5),
		Gears = gears,
		DriveMaxFlatVelMs = round(hFit.DriveMaxFlatVelMs, 4),
		DriveMaxFlatVelKmh = round(hFit.DriveMaxFlatVelKmh, 2),
		MaxFlatVelMs = round(hFit.MaxFlatVelMs, 4),
		MaxFlatVelKmh = round(hFit.MaxFlatVelKmh, 2),
		RedlineTopGearKmh = round(hFit.RedlineTopGearKmh, 2),
		DragAccelCoeff = round(hFit.DragAccelCoeff, 8),
		DragCoeff = round(hFit.DragCoeff, 4),
		ClutchChangeRateUp = hFit.ClutchChangeRateUp and round(hFit.ClutchChangeRateUp, 4),
		ClutchChangeRateDown = hFit.ClutchChangeRateDown and round(hFit.ClutchChangeRateDown, 4),
		ShiftTimeUpS = shiftS,
		ShiftTimeDownS = shiftS,
	},
	Result = {
		ZeroTo100S = stock.t100 and round(stock.t100, 2),
		ZeroTo200S = stock.t200 and round(stock.t200, 2),
		VmaxKmh = round(stock.vmax, 1),
		VmaxUnlimitedKmh = round(unl.vmax, 1),
		PredictTopSpeedKmh = round(Dyn.PredictTopSpeed(unl.sim) * 3.6, 1),
		Shifts = stock.shifts,
		TractionLimited = limited,
		BestZeroTo100S = bestT and round(bestT, 2),
	},
	Upgrades = {
		Max = {
			Levels = "Engine 4, Transmission 3, Turbo, Unlimited",
			ZeroTo100S = maxed.t100 and round(maxed.t100, 2),
			VmaxKmh = round(maxed.vmax, 1),
		},
	},
}
local json = serde.encode("json", out, true)
if process.args[2] then
	fs.writeFile(process.args[2], json)
else
	print(json)
end
