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
local Plates = require(folder:WaitForChild("VehiclePlates"))
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

-- Limite des demandes de custom par joueur (menus) : jeton par jeton, CUSTOM_RATE par seconde.
local CUSTOM_RATE, CUSTOM_BURST = 8, 12
local customBuckets = {}

local function customAllowed(player)
	local now = os.clock()
	local b = customBuckets[player]
	if not b then
		b = { tokens = CUSTOM_BURST, t = now }
		customBuckets[player] = b
	end
	b.tokens = math.min(CUSTOM_BURST, b.tokens + (now - b.t) * CUSTOM_RATE)
	b.t = now
	if b.tokens < 1 then
		return false
	end
	b.tokens -= 1
	return true
end

Players.PlayerRemoving:Connect(function(player)
	customBuckets[player] = nil
end)

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

-- Portes : DOOR_RATE par seconde, rafale DOOR_BURST (6 éléments ouverts d'un coup par un menu + marge).
local DOOR_RATE, DOOR_BURST = 6, 8
local doorBuckets = {}
local function doorAllowed(player)
	local now = os.clock()
	local b = doorBuckets[player]
	if not b then
		b = { tokens = DOOR_BURST, t = now }
		doorBuckets[player] = b
	end
	b.tokens = math.min(DOOR_BURST, b.tokens + (now - b.t) * DOOR_RATE)
	b.t = now
	if b.tokens < 1 then
		return false
	end
	b.tokens -= 1
	return true
end
Players.PlayerRemoving:Connect(function(player)
	doorBuckets[player] = nil
end)

-- Dehors : le joueur doit être près de la charnière visée (ox_target : 2 m du point visé ; ici 3,5 m de la
-- charnière, une portière mesure ≈ 1,2 m, plus la latence) et le véhicule déverrouillé. À bord : toujours permis.
local DOOR_REACH_M = 3.5
local function canReachDoor(player, model, bone, cfg)
	local hum = humanoidOf(player)
	if not hum or hum.Health <= 0 then
		return false
	end
	if hum.SeatPart and hum.SeatPart:IsDescendantOf(model) then
		return true
	end
	if model:GetAttribute("Locked") == true then
		return false
	end
	local root = hum.RootPart
	local joints = model:FindFirstChild("Joints")
	local pivot = joints and joints:FindFirstChild("Pivot_" .. bone)
	local at = (pivot and pivot:IsA("BasePart") and pivot.Position) or (model.PrimaryPart and model.PrimaryPart.Position)
	if not root or not at then
		return false
	end
	return (root.Position - at).Magnitude <= DOOR_REACH_M * (cfg.StudsPerMeter or 3.571)
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
		if key == "Engine" and value == false and model:GetAttribute("EngineAlwaysOn") == true then
			return -- « Moteur toujours allumé » (Custom.SetEngineAlwaysOn)
		end
		model:SetAttribute(key, value)
	elseif action == "Door" then
		-- portières / capot / coffre : à bord (menus du jeu), ou dehors à portée de la charnière visée
		-- (VehicleTarget, Alt + clic ; invites au tactile). Débit limité : un menu « toutes les portes » en
		-- envoie jusqu'à 6 d'un coup.
		if not doorAllowed(player) then
			return
		end
		local cfg = require(model.VehicleConfig)
		if type(key) ~= "string" or #key > 64 or not (cfg.Hinges and cfg.Hinges[key]) then
			return
		end
		if not canReachDoor(player, model, key, cfg) then
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
	elseif action == "Custom" then
		-- custom depuis un menu client (VehicleCustomization.HandleRemote) : refusé tant que le jeu
		-- n'a pas posé sa règle (Custom.SetRemotePolicy) ; débit limité ; arguments contrôlés.
		local policy = Custom.GetRemotePolicy()
		if not policy or type(key) ~= "string" or not customAllowed(player) then
			return
		end
		local okPolicy, allowed = pcall(policy, player, model, key)
		if not okPolicy or allowed ~= true then
			remote:FireClient(player, "CustomResult", model, key, false, "denied")
			return
		end
		local b, c = ...
		local ok, applied, why = pcall(Custom.HandleRemote, model, key, value, b, c, player)
		if not ok then
			warn("[FiveMVehicles] custom refusée :", applied)
			applied, why = false, "error"
		end
		-- réponse au menu (notification) : op, appliquée ?, raison du refus ou détail (texte de plaque…)
		remote:FireClient(player, "CustomResult", model, key, applied == true, why)
	elseif action == "Window" then
		if type(key) ~= "string" or not isOccupantOrNear(player, model, 6) then
			return
		end
		if model:GetAttribute("WindowBroken_" .. key) == true then
			return
		end
		Custom.SetWindowDown(model, key, value == true)
	end
end)

-- Télémétrie du conducteur (10 Hz, non fiable) -> attributs lus par les autres clients
telemetry.OnServerEvent:Connect(function(player, model, rpm, throttle, steer, brake, reverse, gear, tyreFx)
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
	-- traces et fumée par roue (VehicleTyreFx : 4 bits par roue), purement visuelles
	if type(tyreFx) == "number" and tyreFx == tyreFx then
		model:SetAttribute("TyreFx", math.clamp(math.floor(tyreFx), 0, 0xFFFFFFFF))
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

-- Sièges : pas d'assise au simple contact. Un Seat Roblox assoit qui le touche ; portière ouverte, le joueur
-- qui frôle le siège se retrouvait assis sans avoir appuyé sur F (signalé sur le m422, 2026-11-12). Seul
-- Access.Enter (invite F) assoit, par Seat:Sit, qui ne dépend pas du contact. Rattrape les véhicules
-- installés avant ce correctif (le Setup pose déjà CanTouch = false).
local function noTouchSeats(model)
	local seats = model:FindFirstChild("Seats")
	for _, s in ipairs(seats and seats:GetChildren() or {}) do
		if s:IsA("Seat") or s:IsA("VehicleSeat") then
			s.CanTouch = false
		end
	end
end

local function setupVehicle(model)
	Access.TagCollision(model)
	Access.Watch(model)
	noTouchSeats(model)
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
					model:SetAttribute("TyreFx", 0)
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
				-- invite (tactile / manette) : mêmes règles que Alt + clic (VehicleTarget)
				if not doorAllowed(player) or not canReachDoor(player, model, bone, require(model.VehicleConfig)) then
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
	-- plaque unique (garde la sienne si elle est libre, sinon en génère une : copies d'un même modèle)
	Plates.Register(model)
end

for _, m in ipairs(CollectionService:GetTagged(TAG)) do
	task.spawn(setupVehicle, m)
end
CollectionService:GetInstanceAddedSignal(TAG):Connect(setupVehicle)
CollectionService:GetInstanceRemovedSignal(TAG):Connect(Access.Unwatch)
