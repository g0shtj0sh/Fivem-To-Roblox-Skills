--!nonstrict
-- FiveMVehiclesServer (Script, ServerScriptService)
-- Autorité serveur : valide les actions du conducteur (phares, clignotants, klaxon, sirène,
-- moteur), relaie la télémétrie (régime, accélérateur...) aux autres joueurs via attributs,
-- gère portes / capot / coffre (ProximityPrompt), monter / descendre (F), stationnement et remise
-- sur les roues (VehicleAccess), et applique la custom au démarrage.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local folder = ReplicatedStorage:WaitForChild("FiveMVehicles")
local Custom = require(folder:WaitForChild("VehicleCustomization"))
local Access = require(folder:WaitForChild("VehicleAccess"))
local SeatFit = require(folder:WaitForChild("VehicleSeatFit"))
local remote = folder:WaitForChild("VehicleEvent")
local telemetry = folder:WaitForChild("VehicleTelemetry")

local TAG = "FiveMVehicle"
local TOGGLES = {
	Engine = "boolean",
	Headlights = "number",
	Indicator = "string",
	Siren = "boolean",
	SirenSound = "string",
	Horn = "boolean",
	ExtraLights = "boolean",
}
local VALID = {
	Indicator = { Off = true, Left = true, Right = true, Hazard = true },
	SirenSound = { off = true, wail = true, yelp = true, priority = true },
}

local function humanoidOf(player)
	local char = player.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

local function isDriver(player, model)
	local seat = model:FindFirstChild("DriverSeat", true)
	local hum = humanoidOf(player)
	return seat ~= nil and hum ~= nil and seat.Occupant == hum
end

local function isOccupantOrNear(player, model, maxDist)
	local hum = humanoidOf(player)
	if not hum then
		return false
	end
	if hum.SeatPart and hum.SeatPart:IsDescendantOf(model) then
		return true
	end
	local root = hum.RootPart
	return root ~= nil and model.PrimaryPart ~= nil and (root.Position - model.PrimaryPart.Position).Magnitude <= maxDist
end

remote.OnServerEvent:Connect(function(player, model, action, key, value, ...)
	if typeof(model) ~= "Instance" or not CollectionService:HasTag(model, TAG) then
		return
	end
	if action == "Set" then
		local t = TOGGLES[key]
		if not t or typeof(value) ~= t or not isDriver(player, model) then
			return
		end
		if VALID[key] and not VALID[key][value] then
			return
		end
		if key == "Headlights" then
			value = math.clamp(math.floor(value), 0, 2)
		end
		if key == "Siren" and not model:GetAttribute("HasSiren") then
			return
		end
		model:SetAttribute(key, value)
	elseif action == "Door" then
		local cfg = require(model.VehicleConfig)
		if type(key) ~= "string" or not (cfg.Hinges and cfg.Hinges[key]) then
			return
		end
		if not isOccupantOrNear(player, model, 25) then
			return
		end
		local cur = model:GetAttribute("Door_" .. key) or 0
		model:SetAttribute("Door_" .. key, cur > 0.5 and 0 or 1)
	elseif action == "Fit" then
		-- corps de l'occupant adapté à l'habitacle (VehicleSeatFit) ; validé et borné côté serveur
		SeatFit.Apply(player, model, key, value, ...)
	elseif action == "Exit" then
		Access.Exit(player)
	elseif action == "Recover" then
		Access.Recover(player, model)
	elseif action == "Window" then
		if type(key) ~= "string" or not isOccupantOrNear(player, model, 6) then
			return
		end
		Custom.SetWindowDown(model, key, value == true)
	end
end)

-- Télémétrie du conducteur (10 Hz, non fiable) -> attributs lus par les autres clients
telemetry.OnServerEvent:Connect(function(player, model, rpm, throttle, steer, brake, reverse, gear)
	if typeof(model) ~= "Instance" or not CollectionService:HasTag(model, TAG) then
		return
	end
	if type(rpm) ~= "number" or type(throttle) ~= "number" or type(steer) ~= "number" then
		return
	end
	if rpm ~= rpm or throttle ~= throttle or steer ~= steer then
		return -- NaN
	end
	if not isDriver(player, model) then
		return
	end
	model:SetAttribute("Rpm", math.clamp(rpm, 0, 20000))
	model:SetAttribute("Throttle", math.clamp(throttle, 0, 1))
	model:SetAttribute("Steer", math.clamp(steer, -1, 1))
	model:SetAttribute("Brake", brake == true)
	model:SetAttribute("Reverse", reverse == true)
	if type(gear) == "number" then
		model:SetAttribute("Gear", math.clamp(math.floor(gear), -1, 12))
	end
end)

local function enterPrompts(model)
	local out = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d:GetAttribute("SeatName") then
			table.insert(out, d)
		end
	end
	return out
end

-- Invites « Conduire / Monter » : visibles seulement si la place est libre, le véhicule non
-- verrouillé et sur ses roues. L'attribut Available garde la vérité serveur (le client masque
-- localement les invites du véhicule où il est assis, puis revient à Available).
local function refreshPrompts(model)
	local locked = model:GetAttribute("Locked") == true
	local flipped = model:GetAttribute("Flipped") == true
	local seats = model:FindFirstChild("Seats")
	for _, prompt in ipairs(enterPrompts(model)) do
		local seat = seats and seats:FindFirstChild(prompt:GetAttribute("SeatName"))
		local available = seat ~= nil and seat.Occupant == nil and not locked and not flipped
		prompt:SetAttribute("Available", available)
		prompt.Enabled = available
	end
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d:GetAttribute("Recover") then
			d.Enabled = flipped
		end
	end
end

local function setupVehicle(model)
	Access.TagCollision(model)
	Access.Watch(model)
	local root = model.PrimaryPart
	if root then
		model:SetAttribute("Parked", root.Anchored)
	end
	for _, seat in ipairs((model:FindFirstChild("Seats") or Instance.new("Folder")):GetChildren()) do
		if not (seat:IsA("Seat") or seat:IsA("VehicleSeat")) then
			continue
		end
		local isDriver = seat.Name == "DriverSeat"
		local last = nil -- { humanoid, character }
		seat:GetPropertyChangedSignal("Occupant"):Connect(function()
			local hum = seat.Occupant
			if hum then
				local char = hum.Parent
				last = { hum, char }
				Access.SetOccupantGroup(char, true)
				if isDriver then
					local plr = Players:GetPlayerFromCharacter(char)
					model:SetAttribute("DriverUserId", plr and plr.UserId or 0)
					Access.OnDriverChanged(model, plr)
					-- le moteur démarre quand le conducteur s'assoit (comme GTA)
					if model:GetAttribute("AutoStartEngine") ~= false then
						model:SetAttribute("Engine", true)
					end
				end
			else
				-- descendu par un autre moyen que F (saut, script tiers) : on le pose dehors aussi
				local prev = last
				last = nil
				if prev then
					SeatFit.Restore(prev[1]) -- taille d'origine rendue avant de le poser dehors
				end
				if prev and prev[1].Parent and prev[1].Health > 0 and not Access.WasPlacedRecently(prev[2]) then
					Access.EjectOccupant(model, seat, prev[1], prev[2])
				end
				if isDriver then
					model:SetAttribute("DriverUserId", 0)
					model:SetAttribute("Horn", false)
					model:SetAttribute("Brake", false)
					model:SetAttribute("Throttle", 0)
					model:SetAttribute("Steer", 0)
					Access.OnDriverChanged(model, nil)
				end
			end
			refreshPrompts(model)
		end)
	end
	for _, attr in ipairs({ "Locked", "Flipped" }) do
		model:GetAttributeChangedSignal(attr):Connect(function()
			refreshPrompts(model)
		end)
	end
	-- invites : portes / capot / coffre (G), monter (F), remettre sur ses roues (F, maintenu)
	for _, prompt in ipairs(model:GetDescendants()) do
		if not prompt:IsA("ProximityPrompt") then
			continue
		end
		if prompt:GetAttribute("HingeBone") then
			prompt.Triggered:Connect(function(player)
				local bone = prompt:GetAttribute("HingeBone")
				if not isOccupantOrNear(player, model, prompt.MaxActivationDistance + 10) then
					return
				end
				local cur = model:GetAttribute("Door_" .. bone) or 0
				model:SetAttribute("Door_" .. bone, cur > 0.5 and 0 or 1)
			end)
		elseif prompt:GetAttribute("SeatName") then
			prompt.Triggered:Connect(function(player)
				Access.Enter(player, model, prompt:GetAttribute("SeatName"), prompt)
			end)
		elseif prompt:GetAttribute("Recover") then
			prompt.Triggered:Connect(function(player)
				Access.Recover(player, model)
			end)
		end
	end
	refreshPrompts(model)
	Custom.Apply(model, Custom.Serialize(model))
end

for _, m in ipairs(CollectionService:GetTagged(TAG)) do
	task.spawn(setupVehicle, m)
end
CollectionService:GetInstanceAddedSignal(TAG):Connect(setupVehicle)
CollectionService:GetInstanceRemovedSignal(TAG):Connect(Access.Unwatch)
