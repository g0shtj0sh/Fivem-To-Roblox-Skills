--!nonstrict
-- FiveMVehicles/VehicleDrive (ModuleScript, CLIENT du conducteur)
-- Fait rouler le véhicule : un spherecast par roue, VehicleDynamics pour les forces, une VectorForce et un
-- Torque (monde) sur VehicleRoot, et la télémétrie vers VehicleRuntime (son, roues, volant, feux de recul).
-- Le serveur confie la physique au conducteur (SetNetworkOwner) ; ce module ne tourne que chez lui.
--
--   local Drive = require(FiveMVehicles.VehicleDrive)
--   Drive.Start(car)                     -- fait automatiquement par FiveMVehiclesClient pour le conducteur
--   Drive.SetOverride({ Throttle = 1 })  -- entrées imposées (tests, IA) ; nil pour rendre la main au joueur
--   Drive.Get()                          -- { sim, out, car } du véhicule conduit (lecture)
--   Drive.Stop()
--
-- Brancher son propre châssis à la place de VehicleDynamics : voir references/roblox-integration.md
-- (« Interface d'adaptation ») — mêmes entrées (VehicleInput.Controls), même télémétrie (Runtime.SetTelemetry).

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local folder = script.Parent
local Dyn = require(folder:WaitForChild("VehicleDynamics"))
local Runtime = require(folder:WaitForChild("VehicleRuntime"))
local Input = require(folder:WaitForChild("VehicleInput"))
local TyreFx = require(folder:WaitForChild("VehicleTyreFx"))
-- VehicleDamage peut arriver chez le client APRÈS ce module (réplication au démarrage : constaté 2026-11-16, aucun
-- choc n'était envoyé) : cherché à nouveau toutes les 2 s tant qu'il manque
local damageMod, damageLook = nil, -math.huge
local function damageApi()
	if damageMod == nil and os.clock() - damageLook > 2 then
		damageLook = os.clock()
		local m = folder:FindFirstChild("VehicleDamage")
		local ok, mod = pcall(function()
			return m and require(m)
		end)
		damageMod = (ok and mod) or nil
	end
	return damageMod
end

local Drive = {}
Drive.Active = nil -- { car, cfg, sim, root, spm, wheels, ... }
Drive.Override = nil
Drive.StepMode = nil -- "BindToSimulation" | "PreSimulation"

-- Régulateur (« cruise ») et limiteur (« limit ») de vitesse, pour le RP (2026-11-16). Régulateur : garde la vitesse
-- choisie, l'accélérateur du joueur passe par-dessus, frein / frein à main / marche arrière le coupent. Limiteur :
-- plafonne l'accélérateur à la vitesse choisie. Un correcteur PI agit sur l'accélérateur seulement.
Drive.Cruise = nil -- { mode, target (m/s), i }
Drive.CruiseChanged = Instance.new("BindableEvent") -- (mode | nil, km/h | nil, raison | nil)
Drive.CruiseMinKmh = 20
Drive.LimiterDefaultKmh = 50

local function cruiseOff(reason)
	if Drive.Cruise then
		Drive.Cruise = nil
		Drive.CruiseChanged:Fire(nil, nil, reason)
	end
end

-- Active / coupe le régulateur ("cruise") ou le limiteur ("limit") à la vitesse actuelle. Renvoie true si actif.
function Drive.ToggleCruise(mode)
	local a = Drive.Active
	if not a then
		return false
	end
	if Drive.Cruise and Drive.Cruise.mode == mode then
		cruiseOff("off")
		return false
	end
	local v = (a.out and a.out.speed) or 0
	local kmh = v * 3.6
	if mode == "cruise" and (kmh < Drive.CruiseMinKmh or (a.out and a.out.reverse)) then
		Drive.CruiseChanged:Fire(nil, nil, "too_slow")
		return false
	end
	if mode == "limit" then
		kmh = kmh >= 10 and math.floor(kmh / 5 + 0.5) * 5 or Drive.LimiterDefaultKmh
	end
	Drive.Cruise = { mode = mode, target = kmh / 3.6, i = (a.lastThrottle or 0.3) }
	Drive.CruiseChanged:Fire(mode, math.floor(kmh + 0.5), nil)
	return true
end

local function findOrMake(parent, className, name)
	local o = parent:FindFirstChild(name)
	if o and o.ClassName == className then
		return o
	end
	o = Instance.new(className)
	o.Name = name
	o.Parent = parent
	return o
end

-- forces : créées par le Setup (DriveAttachment / DriveForce / DriveTorque) ; recréées localement si absentes
local function actuators(root)
	local att = findOrMake(root, "Attachment", "DriveAttachment")
	local vf = findOrMake(root, "VectorForce", "DriveForce")
	vf.Attachment0 = att
	vf.ApplyAtCenterOfMass = true
	vf.RelativeTo = Enum.ActuatorRelativeTo.World
	local tq = findOrMake(root, "Torque", "DriveTorque")
	tq.Attachment0 = att
	tq.RelativeTo = Enum.ActuatorRelativeTo.World
	vf.Enabled, tq.Enabled = true, true
	return vf, tq
end

local function excludeList(car)
	local list = { car }
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	return list
end

function Drive.Stop()
	local a = Drive.Active
	cruiseOff("exit")
	Drive.Active = nil
	if not a then
		return
	end
	for _, c in ipairs(a.conns) do
		c:Disconnect()
	end
	if a.unbind then
		pcall(a.unbind)
	end
	if a.vf then
		a.vf.Force = Vector3.zero
	end
	if a.tq then
		a.tq.Torque = Vector3.zero
	end
	Runtime.SetTelemetry(a.car, nil)
end

function Drive.SetOverride(t)
	Drive.Override = t
end

function Drive.Get()
	return Drive.Active
end

local function step(a, dt)
	local car, root, spm, sim = a.car, a.root, a.spm, a.sim
	if not car.Parent or not root.Parent then
		Drive.Stop()
		return
	end
	if root.Anchored then
		-- stationné, ou déplacé par le serveur (Access.Teleport) : forces coupées, état remis au repos
		a.vf.Force, a.tq.Torque = Vector3.zero, Vector3.zero
		-- une pièce ancrée garde sa vitesse et la reprend au désancrage (mesuré : véhicule rattrapé
		-- d'une chute à 166 studs/s puis projeté à 60 studs de haut) : on l'annule chez le propriétaire
		root.AssemblyLinearVelocity, root.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
		if not a.wasAnchored then
			a.wasAnchored = true
			Dyn.reset(sim)
			a.xPrev = {}
		end
		return
	end
	a.wasAnchored = false
	a.filterAge += dt
	if a.filterAge > 1 then
		a.filterAge = 0
		a.params.FilterDescendantsInstances = excludeList(car)
	end
	local cf = root.CFrame
	local up = cf.UpVector
	local P, S = sim.P, sim.S

	-- contacts : un spherecast par roue depuis le haut du débattement (+ marge), vers le bas de la caisse
	local contacts = {}
	local travelSt = P.travel * spm
	for i, w in ipairs(P.wheels) do
		local r = w.radius * spm
		local topLocal = (w.rest + Vector3.new(0, P.upper + P.raise, 0)) * spm
		local origin = cf:PointToWorldSpace(topLocal) + up * a.margin
		local len = a.margin + travelSt + a.extraReach
		local hit = Workspace:Spherecast(origin, r * 0.95, -up * len, a.params)
		local c = { grounded = false, x = 0, xdot = 0, vLong = 0, vLat = 0, grip = 1 }
		if hit then
			local d = hit.Distance - a.margin -- déplacement du centre de roue depuis le haut du débattement
			if d <= travelSt then
				local x = (travelSt - math.max(d, -travelSt)) / spm -- m depuis la détente maximale
				c.grounded = true
				c.x = x
				c.xdot = (x - (a.xPrev[i] or x)) / dt
				a.xPrev[i] = x
				local steer = w.steer and S.steerAngle or 0
				local fwd = (cf * CFrame.Angles(0, steer, 0)).LookVector
				local right = fwd:Cross(up)
				local vc = root:GetVelocityAtPosition(hit.Position)
				c.vLong = vc:Dot(fwd) / spm
				c.vLat = vc:Dot(right) / spm
				c.grip = Dyn.MaterialGrip(hit.Material.Name)
			else
				a.xPrev[i] = nil
			end
		else
			a.xPrev[i] = nil
		end
		contacts[i] = c
	end

	-- entrées
	local ctrl = Input.Controls
	local inp = {
		Throttle = ctrl.Throttle, Brake = ctrl.Brake, Steer = ctrl.Steer, Handbrake = ctrl.Handbrake or car:GetAttribute("ParkingBrake") == true,
		-- moteur HS (fumée noire) ou épave en feu : aucune poussée, même si un attribut local dit le contraire
		Engine = car:GetAttribute("Engine") ~= false and car:GetAttribute("EngineDead") ~= true
			and car:GetAttribute("Wrecked") ~= true,
		GearUp = a.gearUp, GearDown = a.gearDown,
	}
	a.gearUp, a.gearDown = false, false
	for k, v in pairs(Drive.Override or {}) do
		inp[k] = v
	end
	local cr = Drive.Cruise
	if cr then
		local v = (a.out and a.out.speed) or 0
		if cr.mode == "cruise" and ((inp.Brake or 0) > 0.1 or inp.Handbrake or (a.out and a.out.reverse) or not inp.Engine) then
			cruiseOff("brake")
		else
			local err = cr.target - v
			local u = math.clamp(0.35 * err + cr.i, 0, 1)
			if u > 0 and u < 1 then
				cr.i = math.clamp(cr.i + 0.12 * err * dt, 0, 1)
			end
			if cr.mode == "cruise" then
				inp.Throttle = math.max(inp.Throttle or 0, u)
			else
				inp.Throttle = math.min(inp.Throttle or 0, u)
			end
		end
	end
	-- moteur touché (VehicleDamage) : moins de puissance
	local Damage = damageApi()
	if Damage then
		inp.Throttle = (inp.Throttle or 0) * Damage.PowerFactor(car)
	end
	a.lastThrottle = inp.Throttle

	local vWorld = root.AssemblyLinearVelocity
	-- choc : variation brutale de la vitesse horizontale en un pas (un freinage fort ≈ 0,2 m/s par pas) ; envoyée au
	-- serveur (VehicleDamage.Apply), direction = du centre vers le point touché, dans le repère du véhicule
	if Damage and a.prevVel then
		local dv = cf:VectorToObjectSpace(vWorld - a.prevVel) / spm
		local hz = Vector3.new(dv.X, 0, dv.Z)
		if hz.Magnitude > Damage.MinImpact and os.clock() - (a.lastImpact or 0) > 0.15 then
			a.lastImpact = os.clock()
			local dir = -hz.Unit
			-- envoyé hors de la boucle physique (BindToSimulation : un FireServer fait ici n'arrivait jamais au
			-- serveur, mesuré 2026-11-16) : gardé, envoyé au prochain Heartbeat (le plus fort s'il y en a plusieurs)
			if not a.pendingImpact or a.pendingImpact[3] < hz.Magnitude then
				a.pendingImpact = { dir.X, dir.Z, hz.Magnitude }
			end
		end
	end
	a.prevVel = vWorld
	local ctx = {
		vBody = cf:VectorToObjectSpace(vWorld) / spm,
		wBody = cf:VectorToObjectSpace(root.AssemblyAngularVelocity),
		up = cf:VectorToObjectSpace(Vector3.yAxis),
	}
	local out = Dyn.step(sim, inp, contacts, dt, ctx)
	a.out = out
	a.contacts = contacts

	-- forces spécifiques (m/s², local) -> forces Roblox (monde) : × StudsPerMeter × AssemblyMass
	local m = root.AssemblyMass
	local com = root.AssemblyCenterOfMass
	local Ftot, Ttot = Vector3.zero, Vector3.zero
	for i, w in ipairs(P.wheels) do
		local o = out.wheels[i]
		if contacts[i].grounded then
			local steerCF = cf * CFrame.Angles(0, o.steer, 0)
			local fwd, right = steerCF.LookVector, steerCF.RightVector
			local Fn = up * (o.Fz * spm * m)
			local Ft = (fwd * o.Fx + right * o.Fy) * (spm * m)
			local pN = cf:PointToWorldSpace(o.point * spm)
			local pT = cf:PointToWorldSpace(o.lateralPoint * spm)
			Ftot += Fn + Ft
			Ttot += (pN - com):Cross(Fn) + (pT - com):Cross(Ft)
		end
	end
	Ftot += cf:VectorToWorldSpace(out.body) * (spm * m)
	-- gravité : on vise la gravité du véhicule (P.g) au lieu de Workspace.Gravity
	Ftot += Vector3.yAxis * ((Workspace.Gravity / spm - P.g) * spm * m)
	Ttot += cf:VectorToWorldSpace(out.torque) * (spm * spm * m)
	a.vf.Force = Ftot
	a.tq.Torque = Ttot

	-- télémétrie -> rendu (son moteur, roues, volant, feux de recul, compte-tours)
	local audio = a.cfg.Audio or {}
	local idle, maxRpm = audio.IdleRpm or 850, audio.MaxRpm or 7200
	local spin, susp, tyre = {}, {}, {}
	if not a.rearZ then
		local z, n = 0, 0
		for _, w in ipairs(P.wheels) do
			if not w.front then
				z += w.rest.Z
				n += 1
			end
		end
		a.rearZ = n > 0 and z / n or 0
	end
	-- traces : une glisse de côté ne marque que si la voiture dérive (essieu arrière)
	local fzSum, fzN = 0, 0
	for _, ow in ipairs(out.wheels) do
		if ow.grounded then
			fzSum += ow.Fz or 0
			fzN += 1
		end
	end
	local tyreCtx = {
		drift = TyreFx.DriftAngle(ctx.vBody, ctx.wBody, a.rearZ),
		fzMean = fzN > 0 and fzSum / fzN or 0,
	}
	for i, w in ipairs(P.wheels) do
		spin[w.bone] = out.omega[i]
		susp[w.bone] = out.travel[i]
		local ow = out.wheels[i]
		tyre[w.bone] = TyreFx.Intensity(ow, tyreCtx)
	end
	Runtime.SetTelemetry(car, {
		-- sous le ralenti (démarreur, moteur qui s'arrête) : proportionnel, 0 = moteur arrêté
		Rpm = (out.rpm >= 0.2) and (idle + (math.min(out.rpm, 1) - 0.2) / 0.8 * (maxRpm - idle)) or (math.max(out.rpm, 0) / 0.2 * idle),
		Gear = out.gear,
		-- accélérateur EFFECTIF (en marche arrière, c'est S) : le son moteur en tire la charge enfoncé / relâché
		Throttle = out.drive or inp.Throttle,
		Brake = (inp.Brake or 0) > 0.1 and out.gear >= 1,
		Reverse = out.reverse,
		Speed = out.speed,
		Steer = -out.steerAngle / math.max(out.lock, 1e-3),
		WheelSteer = out.lock,
		WheelSpin = spin,
		Suspension = susp,
		TyreFx = tyre, -- traces et fumée par roue (VehicleTyreFx), 0..1
		Burnout = out.burnout,
	})
	car:SetAttribute("Gear", out.gear)
end

function Drive.Start(car)
	if Drive.Active and Drive.Active.car == car then
		return Drive.Active
	end
	Drive.Stop()
	local cfgModule = car:FindFirstChild("VehicleConfig")
	local root = car.PrimaryPart
	if not cfgModule or not root then
		return nil
	end
	local cfg = require(cfgModule)
	local spm = cfg.StudsPerMeter or 3.571
	local comLocal = root.CFrame:PointToObjectSpace(root.AssemblyCenterOfMass) / spm
	-- améliorations du garage (attributs Perf_<Slot> posés par VehicleCustomization)
	local function upgrades()
		local levels = {}
		for _, slot in ipairs(Dyn.UpgradeSlots) do
			levels[slot] = car:GetAttribute("Perf_" .. slot) or 0
		end
		return levels
	end
	local function tune()
		local t = {}
		for key in pairs({ PowerMult = true, TorqueMult = true, SpeedLimitKmh = true, DriftTyres = true }) do
			t[key] = car:GetAttribute("Tune_" .. key)
		end
		return t
	end
	local sim = Dyn.new(cfg, comLocal, nil, upgrades())
	Dyn.SetTune(sim, tune())
	local vf, tq = actuators(root)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = excludeList(car)
	params.IgnoreWater = true
	local a = {
		car = car, cfg = cfg, sim = sim, root = root, spm = spm, vf = vf, tq = tq, params = params,
		filterAge = 0, xPrev = {}, conns = {}, margin = 0.3 * spm, extraReach = 0.25 * spm,
	}
	table.insert(a.conns, car.AttributeChanged:Connect(function(attr)
		if string.sub(attr, 1, 5) == "Perf_" then
			Dyn.SetUpgrades(sim, upgrades())
		elseif string.sub(attr, 1, 5) == "Tune_" then
			Dyn.SetTune(sim, tune())
		end
	end))
	-- chocs mesurés dans la boucle physique, envoyés au serveur ici (VehicleDamage)
	table.insert(a.conns, RunService.Heartbeat:Connect(function()
		local imp = a.pendingImpact
		if imp then
			a.pendingImpact = nil
			local remote = folder:FindFirstChild("VehicleEvent")
			if remote then
				remote:FireServer(car, "Impact", imp[1], imp[2], imp[3])
			end
		end
	end))
	table.insert(a.conns, Input.Action.Event:Connect(function(name)
		if name == "GearUp" then
			a.gearUp = true
		elseif name == "GearDown" then
			a.gearDown = true
		end
	end))
	-- pas fixe : BindToSimulation si disponible (indépendant des images), sinon PreSimulation
	local ok, conn = pcall(function()
		return RunService:BindToSimulation(function(dt)
			a.stepped = true
			step(a, typeof(dt) == "number" and dt or 1 / 60)
		end, Enum.StepFrequency.Hz60)
	end)
	if ok and conn then
		Drive.StepMode = "BindToSimulation"
		a.unbind = function()
			if typeof(conn) == "RBXScriptConnection" then
				conn:Disconnect()
			elseif typeof(conn) == "table" and conn.Disconnect then
				conn:Disconnect()
			end
		end
		-- certaines versions demandent UseFixedSimulation : si aucun pas n'arrive, on bascule
		task.delay(0.5, function()
			if Drive.Active == a and not a.stepped then
				pcall(a.unbind)
				Drive.StepMode = "PreSimulation"
				table.insert(a.conns, RunService.PreSimulation:Connect(function(dt)
					step(a, dt)
				end))
			end
		end)
	else
		Drive.StepMode = "PreSimulation"
		table.insert(a.conns, RunService.PreSimulation:Connect(function(dt)
			a.stepped = true
			step(a, dt)
		end))
	end
	Drive.Active = a
	return a
end

return Drive
