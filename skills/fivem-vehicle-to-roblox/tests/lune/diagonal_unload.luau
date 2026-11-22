--!nonstrict
--[[
	Banc « voiture posée en diagonale » (2026-11-22) : rejoue avec le VRAI VehicleDynamics la pose mesurée en Studio
	(m422, roue avant droite sur une bordure de 10 cm, voiture à 15° du bord) : compressions de suspension relevées
	roue par roue (contacts au sol, l'arrière droite à charge nulle), plein gaz 1 s puis marche arrière 2 s, caisse
	libre en ligne droite (1D). Compare Tuning.UnloadedWheelLock coupé / actif, pneus sains et arrière crevés, et la
	route plate (témoin : rien ne doit changer).

	    lune run tests/lune/diagonal_unload.luau <vehicle_config.json (clé roblox_config)>

	Sort une ligne par cas : distance avant / arrière (m), régime moyen, roue la plus rapide (rad/s).
	Échec (code 1) si le correctif ne fait pas repartir la pose diagonale, ou change la route plate de plus de 2 %.
]]
local rbx = require("@lune/roblox")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Vector3 = rbx.Vector3

-- lancé depuis le dossier du skill (ou F2R_DYNAMICS = chemin du module)
local modPath
for _, p in ipairs({ process.env.F2R_DYNAMICS or "", "roblox/runtime/VehicleDynamics.lua",
	"skills/fivem-vehicle-to-roblox/roblox/runtime/VehicleDynamics.lua" }) do
	if p ~= "" and fs.isFile(p) then
		modPath = p
		break
	end
end
assert(modPath, "VehicleDynamics.lua introuvable : lancer depuis le dossier du skill ou poser F2R_DYNAMICS")
local env = setmetatable({ Vector3 = Vector3 }, { __index = getfenv and getfenv(1) or _G })
local Dyn = luau.load(fs.readFile(modPath), { debugName = "VehicleDynamics", environment = env })()

local cfgPath = assert(process.args[1], "usage : lune run diagonal_unload.luau <vehicle_config.json>")
local doc = serde.decode("json", fs.readFile(cfgPath))
local cfg = doc.roblox_config or doc

local DT = 1 / 60
-- écart de compression au repos (m) mesuré en Studio sur la pose bloquée de la m422 (repos 0,18 : lf 0,161,
-- lr 0,200, rf 0,199, rr 0,133), appliqué autour du repos de chaque véhicule (avant droite et arrière gauche
-- enfoncées, la diagonale opposée détendue)
local DIAGONAL = { wheel_lf = -0.019, wheel_lr = 0.020, wheel_rf = 0.019, wheel_rr = -0.047 }

local function run(lock, pose, flats, inp, dur)
	Dyn.Tuning.UnloadedWheelLock = lock
	local sim = Dyn.new(cfg, Vector3.new(0, 0, 0))
	if flats then
		local st = {}
		for _, w in ipairs(sim.P.wheels) do
			st[w.bone] = w.front and 0 or 1
		end
		Dyn.SetWheelStates(sim, st)
	end
	local function contacts(v)
		local c = {}
		for i, w in ipairs(sim.P.wheels) do
			local x = w.x0 + (pose and pose[w.bone] or 0)
			c[i] = { grounded = true, x = x, xdot = 0, vLong = v, vLat = 0, grip = 1 }
		end
		return c
	end
	local idle = { Throttle = 0, Brake = 0, Steer = 0, Engine = true }
	for _ = 1, math.floor(0.5 / DT) do
		Dyn.step(sim, idle, contacts(0), DT, { vBody = Vector3.new(0, 0, 0), wBody = Vector3.new(0, 0, 0), up = Vector3.new(0, 1, 0) })
	end
	local v, d, rpmSum, n, omMax = 0, 0, 0, 0, 0
	for _ = 1, math.floor(dur / DT) do
		local out = Dyn.step(sim, inp, contacts(v), DT, { vBody = Vector3.new(0, 0, -v), wBody = Vector3.new(0, 0, 0), up = Vector3.new(0, 1, 0) })
		local ax = 0
		for i in ipairs(sim.P.wheels) do
			ax += out.wheels[i].Fx
			omMax = math.max(omMax, math.abs(out.omega[i]))
		end
		ax -= out.body.Z
		v += ax * DT
		d += v * DT
		rpmSum += out.rpmRaw
		n += 1
	end
	return d, rpmSum / n, omMax
end

local FWD = { Throttle = 1, Brake = 0, Steer = 0, Engine = true }
local REV = { Throttle = 0, Brake = 1, Steer = 0, Engine = true }
local res = {}
local shares = {}
do
	local sim = Dyn.new(cfg, Vector3.new(0, 0, 0))
	for _, w in ipairs(sim.P.wheels) do
		table.insert(shares, string.format("%s=%.2f", w.bone, w.driveShare))
	end
end
print("parts de couple : " .. table.concat(shares, " "))
for _, case in ipairs({ { "plat", nil, false }, { "diagonale", DIAGONAL, false }, { "diagonale + arrière crevés", DIAGONAL, true } }) do
	for _, lock in ipairs({ false, true }) do
		local f, rpmF, omF = run(lock, case[2], case[3], FWD, 1.0)
		local r, rpmR, omR = run(lock, case[2], case[3], REV, 2.0)
		res[case[1] .. tostring(lock)] = { f = f, r = r }
		print(string.format("%-28s lock=%-5s avant %6.2f m (régime %.2f, roue max %5.0f rad/s) | arrière %7.2f m (régime %.2f, roue max %5.0f)",
			case[1], tostring(lock), f, rpmF, omF, r, rpmR, omR))
	end
end
local ok = true
local pOff, pOn = res["platfalse"], res["plattrue"]
if math.abs(pOn.f / pOff.f - 1) > 0.02 or math.abs(pOn.r / pOff.r - 1) > 0.02 then
	print("ÉCHEC : la route plate change avec le correctif")
	ok = false
end
local dOn = res["diagonaletrue"]
if dOn.f < 0.5 * pOn.f or math.abs(dOn.r) < 0.3 * math.abs(pOn.r) then
	print("ÉCHEC : la pose diagonale ne repart pas avec le correctif")
	ok = false
end
print(ok and "OK" or "ÉCHEC")
process.exit(ok and 0 or 1)
