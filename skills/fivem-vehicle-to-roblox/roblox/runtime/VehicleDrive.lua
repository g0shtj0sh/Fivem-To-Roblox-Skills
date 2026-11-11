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

local Drive = {}
Drive.Active = nil -- { car, cfg, sim, root, spm, wheels, ... }
Drive.Override = nil
Drive.StepMode = nil -- "BindToSimulation" | "PreSimulation"

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
		a.vf.Force, a.tq.Torque = Vector3.zero, Vector3.zero
		return
	end
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
		Throttle = ctrl.Throttle, Brake = ctrl.Brake, Steer = ctrl.Steer, Handbrake = ctrl.Handbrake,
		Engine = car:GetAttribute("Engine") ~= false,
		GearUp = a.gearUp, GearDown = a.gearDown,
	}
	a.gearUp, a.gearDown = false, false
	for k, v in pairs(Drive.Override or {}) do
		inp[k] = v
	end

	local vWorld = root.AssemblyLinearVelocity
	local ctx = {
		vBody = cf:VectorToObjectSpace(vWorld) / spm,
		wBody = cf:VectorToObjectSpace(root.AssemblyAngularVelocity),
		up = cf:VectorToObjectSpace(Vector3.yAxis),
	}
	local out = Dyn.step(sim, inp, contacts, dt, ctx)
	a.out = out

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
	local spin, susp = {}, {}
	for i, w in ipairs(P.wheels) do
		spin[w.bone] = out.omega[i]
		susp[w.bone] = out.travel[i]
	end
	Runtime.SetTelemetry(car, {
		Rpm = idle + (math.clamp(out.rpm, 0.2, 1) - 0.2) / 0.8 * (maxRpm - idle),
		Gear = out.gear,
		Throttle = inp.Throttle,
		Brake = (inp.Brake or 0) > 0.1 and out.gear >= 1,
		Reverse = out.reverse,
		Speed = out.speed,
		Steer = -out.steerAngle / math.max(out.lock, 1e-3),
		WheelSteer = out.lock,
		WheelSpin = spin,
		Suspension = susp,
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
	local sim = Dyn.new(cfg, comLocal)
	local vf, tq = actuators(root)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = excludeList(car)
	params.IgnoreWater = true
	local a = {
		car = car, cfg = cfg, sim = sim, root = root, spm = spm, vf = vf, tq = tq, params = params,
		filterAge = 0, xPrev = {}, conns = {}, margin = 0.3 * spm, extraReach = 0.25 * spm,
	}
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
