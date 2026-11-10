--!nonstrict
-- FiveMVehiclesClient (LocalScript, StarterPlayerScripts)
-- Rend tous les véhicules convertis (lumières, sons, roues, portes) et, quand le joueur
-- est au volant, active les contrôles et envoie ses actions / sa télémétrie au serveur.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local folder = ReplicatedStorage:WaitForChild("FiveMVehicles")
local Runtime = require(folder:WaitForChild("VehicleRuntime"))
local Input = require(folder:WaitForChild("VehicleInput"))
local remote = folder:WaitForChild("VehicleEvent")
local telemetry = folder:WaitForChild("VehicleTelemetry")

local TAG = "FiveMVehicle"
local player = Players.LocalPlayer
local driving = nil -- modèle conduit par le joueur local
local occupying = nil

for _, m in ipairs(CollectionService:GetTagged(TAG)) do
	task.spawn(Runtime.Attach, m)
end
CollectionService:GetInstanceAddedSignal(TAG):Connect(function(m)
	task.defer(Runtime.Attach, m)
end)
CollectionService:GetInstanceRemovedSignal(TAG):Connect(Runtime.Detach)

local function set(key, value)
	if not driving then
		return
	end
	driving:SetAttribute(key, value) -- retour visuel immédiat, le serveur confirme
	remote:FireServer(driving, "Set", key, value)
end

Input.Action.Event:Connect(function(name, value)
	local m = driving
	if not m then
		return
	end
	if name == "Horn" then
		set("Horn", value == true)
	elseif name == "Headlights" then
		set("Headlights", ((m:GetAttribute("Headlights") or 0) + 1) % 3)
	elseif name == "IndicatorLeft" then
		set("Indicator", m:GetAttribute("Indicator") == "Left" and "Off" or "Left")
	elseif name == "IndicatorRight" then
		set("Indicator", m:GetAttribute("Indicator") == "Right" and "Off" or "Right")
	elseif name == "Hazard" then
		set("Indicator", m:GetAttribute("Indicator") == "Hazard" and "Off" or "Hazard")
	elseif name == "Siren" and m:GetAttribute("HasSiren") then
		set("Siren", not m:GetAttribute("Siren"))
	elseif name == "SirenTone" and m:GetAttribute("HasSiren") then
		local order = { "wail", "yelp", "priority", "off" }
		local cur = table.find(order, m:GetAttribute("SirenSound") or "wail") or 1
		set("SirenSound", order[cur % #order + 1])
	elseif name == "Engine" then
		set("Engine", not m:GetAttribute("Engine"))
	end
	-- "GearUp", "GearDown", "LookBack"... : à écouter par ton moteur physique via Input.Action
end)

local function onSeated(active, seat)
	local model = nil
	if active and seat then
		for _, m in ipairs(CollectionService:GetTagged(TAG)) do
			if seat:IsDescendantOf(m) then
				model = m
				break
			end
		end
	end
	if occupying and occupying ~= model then
		local r = Runtime.Get(occupying)
		if r then
			r.IsLocalOccupant = false
			r.LocalOverride = nil
		end
	end
	occupying = model
	if model then
		local r = Runtime.Attach(model)
		if r then
			r.IsLocalOccupant = true
		end
	end
	if model and seat.Name == "DriverSeat" then
		driving = model
		Input.Enable()
	else
		if driving then
			set("Horn", false)
		end
		driving = nil
		Input.Disable()
	end
end

local function hookCharacter(char)
	local hum = char:WaitForChild("Humanoid")
	hum.Seated:Connect(onSeated)
	if hum.SeatPart then
		onSeated(true, hum.SeatPart)
	end
end
if player.Character then
	task.spawn(hookCharacter, player.Character)
end
player.CharacterAdded:Connect(hookCharacter)

-- Entrées locales -> rendu immédiat + télémétrie 10 Hz vers le serveur
local sendAcc = 0
RunService.Heartbeat:Connect(function(dt)
	local m = driving
	if not m then
		return
	end
	local r = Runtime.Get(m)
	local c = Input.Controls
	local st = r and r.State or {}
	local speed = st.Speed or 0
	-- feux stop : pédale de frein enfoncée tant qu'on ne recule pas ; feux de recul en marche arrière
	local brake = c.Brake > 0.1 and speed > -0.5
	local reverse = (st.Gear ~= nil and st.Gear < 0) or speed < -0.5
	if r then
		r.LocalOverride = { Steer = c.Steer, Throttle = c.Throttle, Brake = brake, Reverse = reverse }
	end
	sendAcc += dt
	if sendAcc >= 0.1 then
		sendAcc = 0
		telemetry:FireServer(m, st.Rpm or 0, c.Throttle, c.Steer, brake, reverse, st.Gear)
	end
end)
