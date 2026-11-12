--!nonstrict
--[[
	Banc de conduite LONGITUDINAL, hors Roblox.

	VehicleDynamics est un module pur : on peut le faire tourner sous lune
	(https://github.com/lune-org/lune) en lui fournissant des contacts de roue
	a plat et en integrant la vitesse soi-meme. Cela couvre tous les essais en
	ligne droite — acceleration, passages de rapports, vitesse de pointe,
	freinage, roue libre, marche arriere — sans ouvrir Roblox Studio.

	Ce qu'il ne couvre PAS : tout ce qui demande le solveur 3D de Roblox, donc
	le lateral, le roulis et la bordure. Pour ceux-la, roblox/DriveBench.lua.
	La COTE, en revanche, est couverte depuis le 2026-11-12 : une pente en ligne
	droite ne demande que la gravite le long de la pente et les charges corrigees.

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

local DT = 1 / 60 -- modifiable par le banc de vol, pour prouver l'independance au pas
local function newSim(ov) return Dyn.new(cfg, Vector3.new(0, 0, 0), ov) end

-- `pente` est en pourcentage (montee positive). Une pente en ligne droite ne demande que deux
-- choses : la composante de gravite le long de la pente, et les charges corrigees. On impose les
-- charges par la compression des contacts, de sorte que la suspension du moteur rende exactement
--     Nav = m.g (cos.b/L - sin.h/L)   et   Nar = m.g (cos.a/L + sin.h/L)
-- h etant la hauteur du centre de gravite au-dessus du contact (mesuree a 0,45 m en Studio).
local COM_H = 0.45
local TRACE = false
local LAUNCH_TRACE = (process.env.RIG_DEPART == "1") -- RIG_DEPART=1 : trace du depart arrete (0-1,6 s)
local function step(sim, v, inp, pente)
	pente = pente or 0
	local th = math.atan(pente / 100)
	local cosT, sinT = math.cos(th), math.sin(th)
	local P = sim.P
	-- empattement et repartition, depuis les positions de roue du module
	local zF, zR, nF, nR = 0, 0, 0, 0
	for _, w in ipairs(P.wheels) do
		if w.front then zF += w.rest.Z; nF += 1 else zR += w.rest.Z; nR += 1 end
	end
	zF, zR = zF / math.max(nF, 1), zR / math.max(nR, 1)
	local base = math.max(zR - zF, 0.5)
	local contacts = {}
	for i, w in ipairs(P.wheels) do
		local n = w.front and (nF or 2) or (nR or 2)
		-- charge visee pour cette roue (en unites du moteur : une acceleration specifique)
		local partF = (zR - 0) / base -- centre de gravite a l'origine du repere des roues
		local statique = w.front and (partF / nF) or ((1 - partF) / nR)
		local transfert = sinT * COM_H / base / n * (w.front and -1 or 1)
		local cible = P.g * (statique * cosT + transfert)
		local x = w.x0 + (cible - w.load) / math.max(w.k, 1e-6)
		contacts[i] = { grounded = true, x = x, xdot = 0, vLong = v, vLat = 0, grip = 1 }
	end
	local out = Dyn.step(sim, inp, contacts, DT, {
		vBody = Vector3.new(0, 0, -v), wBody = Vector3.new(0, 0, 0), up = Vector3.new(0, 1, 0),
		slopeSin = sinT,
	})
	local ax = 0
	for i in ipairs(P.wheels) do ax += out.wheels[i].Fx end
	ax -= out.body.Z
	ax -= P.g * sinT -- gravite le long de la pente
	return ax, out
end

-- Profil de pente MESURE pendant le lancement en cote (moyenne des 3 passes FiveM, pas de 0,1 s,
-- en pourcentage). La pente n'est pas constante : elle passe de 17,1 % a 38,2 % en 4 s, et une
-- pente constante egale a la moyenne (25 %) penalise a tort le debut, ou l'acceleration compte.
local PENTE_LANCEMENT = {
	{ 0.00, 17.13 }, { 0.10, 17.13 }, { 0.20, 17.38 }, { 0.30, 17.82 }, { 0.40, 18.18 },
	{ 0.50, 18.22 }, { 0.60, 17.81 }, { 0.70, 17.47 }, { 0.80, 16.86 }, { 0.90, 15.29 },
	{ 1.00, 14.80 }, { 1.10, 16.96 }, { 1.20, 21.54 }, { 1.30, 25.20 }, { 1.40, 26.54 },
	{ 1.50, 25.58 }, { 1.60, 21.50 }, { 1.70, 19.40 }, { 1.80, 20.04 }, { 1.90, 21.43 },
	{ 2.00, 22.36 }, { 2.10, 23.14 }, { 2.20, 24.11 }, { 2.30, 25.13 }, { 2.40, 26.02 },
	{ 2.50, 26.58 }, { 2.60, 27.12 }, { 2.70, 27.59 }, { 2.80, 27.59 }, { 2.90, 27.64 },
	{ 3.00, 28.81 }, { 3.10, 31.40 }, { 3.20, 33.42 }, { 3.30, 32.99 }, { 3.40, 31.30 },
	{ 3.50, 31.58 }, { 3.60, 34.16 }, { 3.70, 36.48 }, { 3.80, 36.98 }, { 3.90, 36.23 },
	{ 4.00, 38.23 },
}

local function penteA(t)
	local p = PENTE_LANCEMENT
	if t <= p[1][1] then return p[1][2] end
	for i = 2, #p do
		if t <= p[i][1] then
			local a, b = p[i - 1], p[i]
			local f = (t - a[1]) / math.max(b[1] - a[1], 1e-9)
			return a[2] + f * (b[2] - a[2])
		end
	end
	return p[#p][2]
end

--- Essai de cote, calque sur `hill` de tools/fivem-telemetry : le vehicule est a l'arret sur la
--- pente, on relache tout pendant 2 s (recul), puis plein gaz pendant 4 s (vitesse et distance).
--- GTA, lui, ne bouge PAS d'un millimetre pendant les 2 s relachees, au point mort et sans
--- pression de frein : c'est du frottement statique.
local function hill(ov, pente, penteLancement)
	local sim = newSim(ov)
	local v, dist, reculMin = 0, 0, 0
	-- 2 s tout relache
	for _ = 1, math.floor(2.0 / DT) do
		local a = step(sim, v, { Throttle = 0, Brake = 0, Steer = 0, Engine = true }, pente)
		v += a * DT
		dist += v * DT
		reculMin = math.min(reculMin, v * 3.6)
	end
	local recul = math.abs(dist)
	-- 4 s plein gaz, sur la pente du lancement (plus raide : le vehicule monte)
	local sim2 = newSim(ov)
	local v2, d2, vmin, t2 = 0, 0, 0, 0
	local gears = {}
	for _ = 1, math.floor(4.0 / DT) do
		-- la pente du lancement suit le profil MESURE, sauf si on en impose une
		local pl = penteLancement or penteA(t2)
		local a, out = step(sim2, v2, { Throttle = 1, Brake = 0, Steer = 0, Engine = true }, pl)
		if TRACE and math.abs(t2 % 0.15) < DT then
			print(("       %5.2f %7.2f %8.3f %7.3f %4d %8.3f   pente %5.1f %%  a %+6.2f")
				:format(t2, v2 * 3.6, d2, out.rpm, out.gear, out.clutch, pl, a))
		end
		t2 += DT
		v2 += a * DT
		d2 += v2 * DT
		vmin = math.min(vmin, v2 * 3.6)
		gears[out.gear] = true
	end
	local g = {}
	for k in pairs(gears) do table.insert(g, k) end
	table.sort(g)
	return { recul = recul, reculVmin = reculMin, lancementKmh = v2 * 3.6, lancementDist = d2,
		lancementVmin = vmin, rapports = g }
end

local FULL = { Throttle = 1, Brake = 0, Steer = 0, Engine = true }
local NONE = { Throttle = 0, Brake = 0, Steer = 0, Engine = true }
local STOP = { Throttle = 0, Brake = 1, Steer = 0, Engine = true }

local function run(ov)
	local res = {}
	local sim = newSim(ov)
	-- au repos, moteur au ralenti, avant les gaz (comme l'essai GTA) : le départ arrêté s'arme (Dyn.Tuning.Launch*)
	for _ = 1, math.floor(0.3 / DT) do
		step(sim, 0, NONE)
	end
	local v, t, dist, gear, lastRpm = 0, 0, 0, 1, 0.2
	res.shifts = {}
	local vmax = 0
	while t < 45 do
		local a, out = step(sim, v, FULL)
		v = math.max(v + a * DT, 0); dist += v * DT; t += DT
		if LAUNCH_TRACE and t <= 1.6 and math.abs(t % 0.09) < DT then
			print(("  depart %5.2f s  %6.1f km/h  regime %.2f  embrayage %.2f  rapport %d"):format(t, v * 3.6, out.rpm, out.clutch, out.gear))
		end
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

-- `lune run rig.luau cote [pente %] [pente du lancement %]`
-- Cibles GTA (3 passes, essai `hill` de tools/fivem-telemetry) : pente 17,1 % a l'arret et
-- 25,0 % en moyenne pendant le lancement ; recul tout relache 0,000 m ; lancement 45,1 km/h
-- sur 32,5 m en 4 s, rapports 1 puis 2.
if mode == "kstick" then
	print(("%-10s %-10s %13s %12s %12s"):format("KStick", "CStick", "banc long.", "recul m", "fluage km/h"))
	for _, k in ipairs({ 200, 400, 800, 1600, 3200, 6400 }) do
		for _, cc in ipairs({ 28, 60, 120 }) do
			local ov = { KStick = k, CStick = cc }
			local r = run(ov)
			local q = hill(ov, 17.1, nil)
			print(("%-10d %-10d %12.2f %% %12.4f %12.2f"):format(k, cc, 100 * score(r), q.recul, q.reculVmin))
		end
	end
	print(("%-21s %12s   %12.4f"):format("CIBLE", "GTA", 0.0))
	return
end

if mode == "vol" then
	-- Banc de VOL LIBRE : aucun contact, on integre la vitesse angulaire et l'assiette a partir du
	-- couple que rend le moteur, puis on relit les trois constantes mesurees en jeu.
	--
	-- Reperes. Le moteur travaille en X a droite, Y en haut, Z vers l'arriere (`vf = -vBody.Z`),
	-- donc la rotation autour de X est le tangage et celle autour de Z le roulis. Un couple X
	-- POSITIF leve le nez : c'est la convention du moteur lui-meme, ou les gaz donnent
	-- `-AirPitch` et "piquent du nez". Le haut du monde exprime en repere local vaut alors
	-- (0, cos t, -sin t) pour une assiette t, le roulis se faisant autour de Z et ne touchant pas
	-- la composante Z. C'est ce que le moteur relit par asin(-up.Z).
	--
	-- Cibles GTA (15 vols au tremplin, 3 passes par cas, essai `airtime` de tools/fivem-telemetry) :
	--   couple  90,8 deg/s2 par unite d'entree, sur les DEUX axes
	--   plafond 61,1 deg/s
	--   borne d'assiette en piquer -37,7 deg
	--   sans entree : rotation CONSERVEE (acceleration mesuree +1,1 deg/s2)
	local sim = newSim(nil)
	local GY = sim.T.GyrationSq

	-- wx0 : le taux de tangage initial, comme celui que le tremplin imprime en jeu (-30 deg/s)
	local pas = DT
	local function voler(inp, wx0, duree, pitch0)
		local wx, wz, pitch = math.rad(wx0 or 0), 0, math.rad(pitch0 or 0)
		local h = {}
		for k = 1, math.floor(duree / pas) do
			local out = Dyn.step(sim, inp, {}, pas, {
				vBody = Vector3.new(0, 0, -20),
				wBody = Vector3.new(wx, 0, wz),
				up = Vector3.new(0, math.cos(pitch), -math.sin(pitch)),
			})
			local a = out.torque / GY
			wx += a.X * pas
			wz += a.Z * pas
			pitch += wx * pas
			h[k] = { t = k * pas, wx = math.deg(wx), wz = math.deg(wz),
				pitch = math.deg(pitch), ax = math.deg(a.X), az = math.deg(a.Z) }
		end
		return h
	end

	-- 1) LE COUPLE : lu sur les premieres images, loin du plafond, a partir du repos
	print("1) couple de controle, par unite d'entree (loin du plafond)")
	print(("   %-26s %14s %14s   %s"):format("entree", "obtenu", "GTA", "ecart"))
	local cas = {
		{ "cabrage (frein = S)", { Brake = 1 }, "ax", 90.8 },
		{ "piquer (gaz = W)", { Throttle = 1 }, "ax", -90.8 },
		{ "roulis gauche", { Steer = -1 }, "az", 90.8 },
		{ "roulis droite", { Steer = 1 }, "az", -90.8 },
	}
	for _, c in ipairs(cas) do
		local h = voler(c[2], 0, 0.1, 0)
		local got = h[1][c[3]]
		print(("   %-26s %11.1f /s2 %11.1f /s2   %+6.1f %%")
			:format(c[1], got, c[4], (got - c[4]) / math.abs(c[4]) * 100))
	end

	-- 2) LE PLAFOND : on pousse une seconde pleine et on regarde ou le taux se fige
	print("")
	print("2) plafond de vitesse angulaire (1 s d'entree pleine)")
	print(("   %-26s %14s %14s   %s"):format("entree", "taux final", "GTA", "ecart"))
	for _, c in ipairs({
		{ "cabrage", { Brake = 1 }, "wx", 61.1 },
		{ "roulis gauche", { Steer = -1 }, "wz", 61.1 },
		{ "roulis droite", { Steer = 1 }, "wz", -61.1 },
	}) do
		local h = voler(c[2], 0, 1.0, 0)
		local got = h[#h][c[3]]
		print(("   %-26s %11.1f /s  %11.1f /s    %+6.1f %%")
			:format(c[1], got, c[4], (got - c[4]) / math.abs(c[4]) * 100))
	end

	-- 3) LA BORNE D'ASSIETTE EN PIQUER : on rejoue le vol du jeu, nez en bas, en partant du
	-- tangage que le tremplin imprime (-30 deg/s) et de son assiette au decollage (+6 deg)
	print("")
	print("3) borne d'assiette en piquer (gaz plein, depart comme au tremplin)")
	local h = voler({ Throttle = 1 }, -30, 1.4, 6)
	local amin, tmin = 0, 0
	for _, r in ipairs(h) do
		if r.pitch < amin then amin, tmin = r.pitch, r.t end
	end
	print(("   %-26s %11.1f deg  %11.1f deg   %+6.1f %%")
		:format("assiette la plus basse", amin, -37.7, (amin + 37.7) / 37.7 * 100))
	print(("   %-26s %11.2f s"):format("atteinte a", tmin))
	print(("   %-26s %11.1f /s   (plafond %.1f)"):format("taux le plus negatif",
		(function() local m = 0 for _, r in ipairs(h) do if r.wx < m then m = r.wx end end return m end)(),
		-61.1))
	-- sonde du franchissement
	if process.args[2] == "sonde" then
		print("   sonde du franchissement :")
		local T = sim.T
		for _, r in ipairs(h) do
			local marge = math.rad(r.pitch) - T.AirPitchFloor
			if marge < 0.10 and marge > -0.06 then
				print(("      t %.3f  assiette %+7.3f  marge %+7.3f deg  taux %+7.2f  "
					.. "taux admis %+7.2f  couple %+8.1f"):format(r.t, r.pitch, math.deg(marge),
					r.wx, math.deg(math.min(math.sqrt(2 * T.AirBoundTorque * math.max(marge, 0)),
						math.max(marge, 0) / DT)), r.ax))
			end
		end
	end
	print("   assiette au cours du vol :")
	local pas = math.max(1, math.floor(#h / 8))
	local l = "      "
	for k = 1, #h, pas do
		l = l .. ("%.2fs:%+.1f  "):format(h[k].t, h[k].pitch)
	end
	print(l)

	-- 4) SANS ENTREE : la rotation doit etre CONSERVEE, pas amortie
	print("")
	print("4) sans entree : la rotation est-elle conservee ?")
	local h0 = voler({}, -30, 1.0, 0)
	print(("   %-26s %11.1f /s -> %8.1f /s   GTA : conservee (-28 a -32)")
		:format("taux de tangage", -30.0, h0[#h0].wx))
	print(("   %-26s %11.1f /s2  GTA %10.1f /s2"):format("acceleration moyenne",
		(h0[#h0].wx + 30.0) / 1.0, 1.1))

	-- 5) INDEPENDANCE AU PAS. Les deux ecretages visent PILE la limite au lieu de couper apres
	-- l'avoir franchie ; si c'est bien fait, plafond et borne ne doivent pas bouger avec le pas.
	print("")
	print("5) independance au pas de temps")
	print(("   %-12s %14s %16s"):format("pas", "plafond /s", "borne d'assiette"))
	for _, hz in ipairs({ 30, 60, 120, 240 }) do
		pas = 1 / hz
		local hp = voler({ Brake = 1 }, 0, 1.5, 0)
		local hb = voler({ Throttle = 1 }, -30, 1.6, 6)
		local amin = 0
		for _, r in ipairs(hb) do
			if r.pitch < amin then amin = r.pitch end
		end
		print(("   %-12s %11.2f /s %13.2f deg"):format(("%d Hz"):format(hz), hp[#hp].wx, amin))
	end
	pas = DT
	print(("   %-12s %11.2f /s %13.2f deg"):format("GTA", 61.1, -37.7))
	return
end

if mode == "souspas" then
	-- Effet du nombre de sous-pas sur les DEUX bancs. La stabilite de l'integration de omega
	-- demande h < 2.KappaPeak.vRef.Iw/(r^2.fmax), soit environ 43 sous-pas a 60 Hz avec
	-- IwRel = 0,03 : avec 8, le pas est cinq fois au-dela de la limite.
	print(("%-10s %13s %12s %12s %12s"):format("SubSteps", "banc long.", "recul", "km/h", "dist"))
	for _, n in ipairs({ 8, 16, 32, 64 }) do
		local r = run({ SubSteps = n })
		local q = hill({ SubSteps = n }, 17.1, nil)
		local qa = hill({ SubSteps = n, SlopeAssist = 0.537 }, 17.1, nil)
		print(("%-10d %12.2f %% %12.4f %12.2f %12.2f   avec apport : %6.2f km/h %6.2f m")
			:format(n, 100 * score(r), q.recul, q.lancementKmh, q.lancementDist,
				qa.lancementKmh, qa.lancementDist))
	end
	print(("%-10s %14s %12.4f %12.2f %12.2f"):format("CIBLE", "GTA", 0.0, 45.10, 32.50))
	return
end

if mode == "cote" then
	local pente = tonumber(process.args[2] or "") or 17.1
	local penteL = tonumber(process.args[3] or "") -- nil = profil mesure
	TRACE = (process.args[4] == "trace")
	if TRACE then
		print("       t, km/h, distance, regime, rapport, embrayage, pente, acceleration")
	end
	local variantes = {
		{ nom = "sans apport (livre)", ov = nil },
		{ nom = "apport 0,537", ov = { SlopeAssist = 0.537 } },
		{ nom = "apport + 4x sous-pas", ov = { SlopeAssist = 0.537, SubSteps = 16 } },
		{ nom = "apport + IwRel 0,10", ov = { SlopeAssist = 0.537, IwRel = 0.10 } },
		{ nom = "apport + IwRel 0,25", ov = { SlopeAssist = 0.537, IwRel = 0.25 } },
		{ nom = "sans apport + IwRel 0,10", ov = { IwRel = 0.10 } },
	}
	if process.args[5] == "variantes" then
		print(("%-26s %10s %10s %10s"):format("variante", "recul m", "km/h", "distance m"))
		for _, v in ipairs(variantes) do
			local q = hill(v.ov, pente, penteL)
			print(("%-26s %10.4f %10.2f %10.2f"):format(v.nom, q.recul, q.lancementKmh, q.lancementDist))
		end
		print(("%-26s %10.4f %10.2f %10.2f"):format("CIBLE GTA", 0.0, 45.10, 32.50))
		return
	end
	local r = hill(nil, pente, penteL)
	print(("=== COTE   pente %.1f %% a l'arret, %s au lancement")
		:format(pente, penteL and ("%.1f %%"):format(penteL) or "profil mesure 17->38 %"))
	print(("   recul tout relache        %8.4f m      GTA   0.0000   (vitesse min %+.2f km/h)")
		:format(r.recul, r.reculVmin))
	print(("   lancement 4 s             %8.2f km/h   GTA    45.10   ecart %+6.1f %%")
		:format(r.lancementKmh, 100 * (r.lancementKmh - 45.10) / 45.10))
	print(("   lancement 4 s             %8.2f m      GTA    32.50   ecart %+6.1f %%")
		:format(r.lancementDist, 100 * (r.lancementDist - 32.50) / 32.50))
	print(("   recul au lancement        %8.2f km/h   GTA    -0.36"):format(r.lancementVmin))
	local g = {}
	for _, k in ipairs(r.rapports) do table.insert(g, tostring(k)) end
	print(("   rapports traverses        %8s        GTA    1, 2"):format(table.concat(g, ", ")))
	return
end

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
