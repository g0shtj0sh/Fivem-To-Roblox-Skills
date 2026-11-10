--!nonstrict
-- FiveMVehicles/VehicleInput (ModuleScript, client)
-- Contrôles du véhicule façon GTA : clavier, manette, tactile.
-- Ne fait AUCUNE physique : ton moteur physique lit simplement VehicleInput.Controls.
--
--   local Input = require(ReplicatedStorage.FiveMVehicles.VehicleInput)
--   RunService.Heartbeat:Connect(function(dt)
--       local c = Input.Controls   -- Throttle 0..1, Brake 0..1, Steer -1..1, Handbrake bool, ...
--   end)
--   Input.Action.Event:Connect(function(name, value) ... end) -- "Horn", "Headlights", "GearUp"...

local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Input = {}

-- Modifiable librement (ou depuis ton propre menu d'options)
Input.Bindings = {
	Throttle = { Enum.KeyCode.W, Enum.KeyCode.ButtonR2 },
	Brake = { Enum.KeyCode.S, Enum.KeyCode.ButtonL2 },
	SteerLeft = { Enum.KeyCode.A },
	SteerRight = { Enum.KeyCode.D },
	Handbrake = { Enum.KeyCode.Space, Enum.KeyCode.ButtonR1 },
	Horn = { Enum.KeyCode.E, Enum.KeyCode.ButtonL3 },
	Headlights = { Enum.KeyCode.H, Enum.KeyCode.DPadRight },
	IndicatorLeft = { Enum.KeyCode.Left },
	IndicatorRight = { Enum.KeyCode.Right },
	Hazard = { Enum.KeyCode.Down },
	Siren = { Enum.KeyCode.Q, Enum.KeyCode.DPadLeft },
	SirenTone = { Enum.KeyCode.R },
	Engine = { Enum.KeyCode.Z },
	GearUp = { Enum.KeyCode.LeftShift, Enum.KeyCode.ButtonY },
	GearDown = { Enum.KeyCode.LeftControl, Enum.KeyCode.ButtonX },
	LookBack = { Enum.KeyCode.C, Enum.KeyCode.ButtonR3 },
}
Input.SteerSpeed = 4.0 -- vitesse de braquage clavier (unités/s)
Input.SteerReturn = 6.0 -- vitesse de retour au centre
Input.Deadzone = 0.12

Input.Controls = {
	Throttle = 0,
	Brake = 0,
	Steer = 0,
	Handbrake = false,
	LookBack = false,
}
Input.Action = Instance.new("BindableEvent") -- (actionName, value)
Input.Enabled = false

local held = {}
local analog = { throttle = 0, brake = 0, steer = 0 }
local stepConn

local function fire(name, value)
	Input.Action:Fire(name, value)
end

local function onAction(name, state, obj)
	local down = state == Enum.UserInputState.Begin
	local up = state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel
	if obj and obj.KeyCode == Enum.KeyCode.ButtonR2 then
		analog.throttle = obj.Position.Z
		return Enum.ContextActionResult.Sink
	elseif obj and obj.KeyCode == Enum.KeyCode.ButtonL2 then
		analog.brake = obj.Position.Z
		return Enum.ContextActionResult.Sink
	end
	if down then
		held[name] = true
	elseif up then
		held[name] = nil
	end
	if name == "Handbrake" or name == "LookBack" then
		Input.Controls[name] = held[name] == true
	elseif down and name ~= "Throttle" and name ~= "Brake" and name ~= "SteerLeft" and name ~= "SteerRight" then
		fire(name, true)
	elseif up and name == "Horn" then
		fire("Horn", false)
	end
	return Enum.ContextActionResult.Sink
end

local function onThumbstick(_, _, obj)
	if obj.KeyCode == Enum.KeyCode.Thumbstick1 then
		local x = obj.Position.X
		analog.steer = math.abs(x) > Input.Deadzone and x or 0
	end
	return Enum.ContextActionResult.Pass
end

local function getMoveVector()
	-- tactile / joystick dynamique : on réutilise le module de contrôle de Roblox
	local ok, vec = pcall(function()
		local pm = require(Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule"))
		return pm:GetControls():GetMoveVector()
	end)
	return ok and vec or Vector3.zero
end

local function step(dt)
	local c = Input.Controls
	local keyThrottle = held.Throttle and 1 or 0
	local keyBrake = held.Brake and 1 or 0
	local keySteer = (held.SteerRight and 1 or 0) - (held.SteerLeft and 1 or 0)
	local move = UserInputService.TouchEnabled and getMoveVector() or Vector3.zero

	c.Throttle = math.max(keyThrottle, analog.throttle, math.max(0, -move.Z))
	c.Brake = math.max(keyBrake, analog.brake, math.max(0, move.Z))

	local target = keySteer ~= 0 and keySteer or (analog.steer ~= 0 and analog.steer or move.X)
	if keySteer ~= 0 then
		c.Steer = c.Steer + math.clamp(target - c.Steer, -Input.SteerSpeed * dt, Input.SteerSpeed * dt)
	elseif analog.steer ~= 0 or move.X ~= 0 then
		c.Steer = target
	else
		c.Steer = c.Steer + math.clamp(-c.Steer, -Input.SteerReturn * dt, Input.SteerReturn * dt)
	end
	c.Steer = math.clamp(c.Steer, -1, 1)
end

function Input.Enable()
	if Input.Enabled then
		return
	end
	Input.Enabled = true
	for name, keys in pairs(Input.Bindings) do
		ContextActionService:BindActionAtPriority("F2R_" .. name, function(_, state, obj)
			return onAction(name, state, obj)
		end, false, Enum.ContextActionPriority.High.Value, table.unpack(keys))
	end
	ContextActionService:BindAction("F2R_Thumbstick", onThumbstick, false, Enum.KeyCode.Thumbstick1)
	-- boutons tactiles (mobile)
	if UserInputService.TouchEnabled then
		for _, name in ipairs({ "Horn", "Headlights", "Handbrake" }) do
			ContextActionService:BindAction("F2R_Touch_" .. name, function(_, state, obj)
				return onAction(name, state, obj)
			end, true)
			ContextActionService:SetTitle("F2R_Touch_" .. name, ({ Horn = "Klaxon", Headlights = "Phares", Handbrake = "Frein à main" })[name])
		end
	end
	stepConn = RunService.RenderStepped:Connect(step)
end

function Input.Disable()
	if not Input.Enabled then
		return
	end
	Input.Enabled = false
	for name in pairs(Input.Bindings) do
		ContextActionService:UnbindAction("F2R_" .. name)
	end
	ContextActionService:UnbindAction("F2R_Thumbstick")
	for _, name in ipairs({ "Horn", "Headlights", "Handbrake" }) do
		ContextActionService:UnbindAction("F2R_Touch_" .. name)
	end
	if stepConn then
		stepConn:Disconnect()
		stepConn = nil
	end
	table.clear(held)
	analog.throttle, analog.brake, analog.steer = 0, 0, 0
	local c = Input.Controls
	c.Throttle, c.Brake, c.Steer, c.Handbrake, c.LookBack = 0, 0, 0, false, false
	fire("Horn", false)
end

return Input
