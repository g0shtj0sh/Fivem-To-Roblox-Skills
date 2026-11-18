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
local damageModule = folder:FindFirstChild("VehicleDamage")
local Damage = damageModule and require(damageModule) or nil
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
	InteriorLight = "boolean",
	ParkingBrake = "boolean", -- frein à main serré (touche P) : reste serré à la sortie, comme le moteur
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

-- Débit des autres actions, par joueur et par action (audit multijoueur 2026-11-16 : télémétrie, bascules, vitres
-- et ajustement de siège n'avaient aucune limite ; chaque envoi devient des attributs répliqués à tous les joueurs).
-- Au-delà, la demande est ignorée sans bruit (une mauvaise connexion ressemble à un tricheur).
local RATES = {
	telemetry = { 15, 20 }, -- le client en envoie 10 par seconde
	set = { 8, 12 }, -- phares, clignotants, klaxon, sirène, moteur
	window = { 4, 6 },
	impact = { 6, 8 },
	fit = { 2, 3 },
}
local buckets = {}
local function allowed(player, action)
	local r = RATES[action]
	local now = os.clock()
	local per = buckets[player]
	if not per then
		per = {}
		buckets[player] = per
	end
	local b = per[action]
	if not b then
		b = { tokens = r[2], t = now }
		per[action] = b
	end
	b.tokens = math.min(r[2], b.tokens + (now - b.t) * r[1])
	b.t = now
	if b.tokens < 1 then
		return false
	end
	b.tokens -= 1
	return true
end

Players.PlayerRemoving:Connect(function(player)
	customBuckets[player] = nil
	buckets[player] = nil
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
		if not t or typeof(value) ~= t or not isDriver(player, model) or not allowed(player, "set") then
			return
		end
		-- demande refusée : le client a déjà écrit la valeur chez lui (retour visuel immédiat) ; on lui renvoie la
		-- vraie, sinon il garde par ex. un moteur HS « allumé » et conduit quand même (bug signalé le 2026-11-18)
		local function refuse()
			remote:FireClient(player, "Resync", model, key, model:GetAttribute(key))
		end
		if model:GetAttribute("Wrecked") == true then
			return refuse() -- véhicule en feu / épave (VehicleDamage) : plus rien ne marche jusqu'à la réparation
		end
		if t == "number" and (value ~= value or math.abs(value) == math.huge) then
			return refuse()
		end
		if VALID[key] and not VALID[key][value] then
			return refuse()
		end
		if key == "Headlights" then
			value = math.clamp(math.floor(value), 0, 2)
		end
		if key == "Siren" and not model:GetAttribute("HasSiren") then
			return refuse()
		end
		if key == "Engine" and value == false and model:GetAttribute("EngineAlwaysOn") == true then
			return refuse() -- « Moteur toujours allumé » (Custom.SetEngineAlwaysOn)
		end
		if key == "Engine" and value == true and model:GetAttribute("EngineDead") == true then
			return refuse() -- moteur détruit (VehicleDamage) : il faut réparer
		end
		if key == "Engine" then
			-- moteur coupé par le conducteur : il le reste à la sortie et quand on remonte (GTA) ; sinon, en sortant, le
			-- moteur continue de tourner (2026-11-18, demande de l'utilisateur)
			model:SetAttribute("EngineOffByDriver", value == false or nil)
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
	elseif action == "Impact" then
		-- choc mesuré par le client du conducteur (VehicleDrive) : direction (x, z du repère du véhicule) et force
		local dx, dz, strength, dy = key, value, ...
		dy = dy or 0 -- composante verticale (toit / dessous) : clients d'avant 2026-11-18 sans elle
		if not Damage or not isDriver(player, model) or not allowed(player, "impact") then
			return
		end
		if type(dx) ~= "number" or type(dz) ~= "number" or type(strength) ~= "number" then
			return
		end
		if type(dy) ~= "number" or dy ~= dy or math.abs(dy) > 1.01 then
			return
		end
		if dx ~= dx or dz ~= dz or strength ~= strength or math.abs(dx) > 1.01 or math.abs(dz) > 1.01 then
			return
		end
		Damage.Apply(model, Vector3.new(dx, dy, dz), strength)
	elseif action == "Fit" then
		-- corps de l'occupant adapté à l'habitacle (VehicleSeatFit) ; validé et borné côté serveur
		if allowed(player, "fit") then
			SeatFit.Apply(player, model, key, value, ...)
		end
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
		-- seulement une vraie vitre de ce modèle (avant 2026-11-16 : n'importe quel nom devenait un attribut
		-- WindowDown_<nom> répliqué à tous et gardé dans les sauvegardes) ; verrouillé : occupants seulement
		if type(key) ~= "string" or #key > 32 or not isOccupantOrNear(player, model, 6) or not allowed(player, "window") then
			return
		end
		if not table.find(Custom.WindowBones(model), key) then
			return
		end
		local hum = humanoidOf(player)
		local inside = hum and hum.SeatPart and hum.SeatPart:IsDescendantOf(model)
		if model:GetAttribute("Locked") == true and not inside then
			return
		end
		if model:GetAttribute("WindowBroken_" .. key) == true then
			return
		end
		Custom.SetWindowDown(model, key, value == true)
	end
end)

-- Télémétrie du conducteur (10 Hz, non fiable) -> attributs lus par les autres clients
telemetry.OnServerEvent:Connect(function(player, model, rpm, throttle, steer, brake, reverse, gear, tyreFx, spinF, spinR)
	if typeof(model) ~= "Instance" or not CollectionService:HasTag(model, TAG) then
		return
	end
	if type(rpm) ~= "number" or type(throttle) ~= "number" or type(steer) ~= "number" then
		return
	end
	if rpm ~= rpm or throttle ~= throttle or steer ~= steer then
		return -- NaN
	end
	if not isDriver(player, model) or not allowed(player, "telemetry") then
		return
	end
	-- valeurs arrondies : moins de changements répliqués à tous les joueurs (Roblox n'envoie que ce qui change)
	model:SetAttribute("Rpm", math.round(math.clamp(rpm, 0, 20000) / 25) * 25)
	model:SetAttribute("Throttle", math.round(math.clamp(throttle, 0, 1) * 32) / 32)
	-- braquage EFFECTIF des roues (fraction de la butée mécanique), pas la touche brute : à vitesse le moteur de
	-- conduite réduit l'angle ; avec la touche brute les autres voyaient les roues braquées à fond (audit 2026-11-16)
	model:SetAttribute("Steer", math.round(math.clamp(steer, -1, 1) * 64) / 64)
	model:SetAttribute("Brake", brake == true)
	model:SetAttribute("Reverse", reverse == true)
	if type(gear) == "number" and gear == gear and math.abs(gear) ~= math.huge then
		model:SetAttribute("Gear", math.clamp(math.floor(gear), -1, 12))
	end
	-- traces et fumée par roue (VehicleTyreFx : 4 bits par roue), purement visuelles
	if type(tyreFx) == "number" and tyreFx == tyreFx then
		model:SetAttribute("TyreFx", math.clamp(math.floor(tyreFx), 0, 0xFFFFFFFF))
	end
	-- roues qui patinent ou sont bloquées (burn, frein à main) : vitesse de surface avant / arrière, purement visuelle
	local function finite(x)
		return type(x) == "number" and x == x and math.abs(x) < 1e6
	end
	if finite(spinF) and finite(spinR) then
		local q = function(x)
			return math.round(math.clamp(x, -150, 150) * 2) / 2
		end
		model:SetAttribute("AxleSpin", Vector2.new(q(spinF), q(spinR)))
	elseif model:GetAttribute("AxleSpin") ~= nil then
		model:SetAttribute("AxleSpin", nil)
	end
end)

-- Saleté : monte avec le temps de conduite (pleine en ~35 min sur route, ~15 min hors route),
-- sauf KeepClean. Vérifié toutes les 2 s, écrit seulement par pas de 1 % (une écriture répliquée de temps en temps).
-- Au TEMPS de conduite, pas à la distance (2026-11-16, demande de l'utilisateur : « se salir au bout de ~30 min de
-- route, ~15 min si on va beaucoup dans la terre »). Avant : pleine en 8 km de route (≈ 5 min à 100 km/h), ×4 hors route.
local DIRT_FULL_S = 35 * 60 -- s de conduite sur route pour être pleinement sale
local DIRT_OFFROAD_MULT = 2.3 -- terre, herbe, sable, neige… : pleine en ≈ 15 min
local DIRT_MIN_SPEED = 2 -- m/s (≈ 7 km/h) : à l'arrêt ou au pas, la voiture ne se salit pas
local DIRT_TICK = 2 -- s entre deux relevés
local OFFROAD = { Grass = true, LeafyGrass = true, Mud = true, Ground = true, Sand = true, Snow = true, Rock = true,
	Slate = true, Glacier = true, Salt = true, Sandstone = true, CrackedLava = true }
local dirtCarry = setmetatable({}, { __mode = "k" })
local dirtShown = setmetatable({}, { __mode = "k" })
task.spawn(function()
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	while true do
		task.wait(DIRT_TICK)
		for _, model in ipairs(CollectionService:GetTagged(TAG)) do
			local root = model.PrimaryPart
			local seat = model:FindFirstChild("DriverSeat", true)
			if root and not root.Anchored and seat and seat.Occupant and model:GetAttribute("KeepClean") ~= true then
				local ok, cfg = pcall(require, model:FindFirstChild("VehicleConfig"))
				local spm = (ok and cfg and cfg.StudsPerMeter) or 3.571
				local speed = root.AssemblyLinearVelocity.Magnitude / spm
				if speed > DIRT_MIN_SPEED then
					params.FilterDescendantsInstances = { model }
					local hit = workspace:Raycast(root.Position, Vector3.new(0, -4 * spm, 0), params)
					local mult = (hit and OFFROAD[hit.Material.Name]) and DIRT_OFFROAD_MULT or 1
					local shown = model:GetAttribute("DirtLevel") or 0
					local cur = math.max(dirtCarry[model] or 0, shown)
					if shown < (dirtShown[model] or shown) then
						cur = shown -- lavé ou réglé entre-temps
					end
					local new = math.min(1, cur + DIRT_TICK * mult / DIRT_FULL_S)
					dirtCarry[model] = new -- reste sous le pas gardé ici (un attribut serait répliqué à tous)
					if math.floor(new * 100) ~= math.floor(shown * 100) then
						model:SetAttribute("DirtLevel", math.floor(new * 100) / 100)
					end
					dirtShown[model] = model:GetAttribute("DirtLevel") or 0
				end
			end
		end
	end
end)

-- Chocs d'un véhicule SANS conducteur (le serveur tient sa physique) : même mesure que VehicleDrive, côté serveur.
if Damage then
	local RunService = game:GetService("RunService")
	local lastVel = setmetatable({}, { __mode = "k" })
	local lastHit = setmetatable({}, { __mode = "k" })
	local lastAng = setmetatable({}, { __mode = "k" })
	local armedAt = setmetatable({}, { __mode = "k" })
	local lastUp = setmetatable({}, { __mode = "k" })
	local lastRoll = setmetatable({}, { __mode = "k" })
	RunService.Heartbeat:Connect(function()
		for _, model in ipairs(CollectionService:GetTagged(TAG)) do
			local root = model.PrimaryPart
			local seat = model:FindFirstChild("DriverSeat", true)
			-- tonneau : chaque passage sur le toit (vecteur haut qui passe sous l'horizontale) = un choc de toit, quel que
			-- soit celui qui tient la physique (le serveur voit la position répliquée)
			if root and not root.Anchored then
				local upY = root.CFrame.UpVector.Y
				local prevUp = lastUp[model]
				lastUp[model] = upY
				if prevUp and prevUp >= -0.2 and upY < -0.2 and os.clock() - (lastRoll[model] or 0) > 0.4 then
					lastRoll[model] = os.clock()
					local ok, cfg = pcall(require, model:FindFirstChild("VehicleConfig"))
					local spm = (ok and cfg and cfg.StudsPerMeter) or 3.571
					local speed = root.AssemblyLinearVelocity.Magnitude / spm
					Damage.Apply(model, Vector3.yAxis, math.max(Damage.RollMin or 14, speed))
				end
			else
				lastUp[model] = nil
			end
			if root and not root.Anchored and not (seat and seat.Occupant) then
				local v = root.AssemblyLinearVelocity
				local prev = lastVel[model]
				lastVel[model] = v
				local w = root.AssemblyAngularVelocity
				local prevW = lastAng[model]
				lastAng[model] = w
				if not prev then
					armedAt[model] = os.clock() + 0.5 -- reprise de la physique par le serveur : vitesses discontinues
				end
				if prev and os.clock() >= (armedAt[model] or 0) then
					local ok, cfg = pcall(require, model:FindFirstChild("VehicleConfig"))
					local spm = (ok and cfg and cfg.StudsPerMeter) or 3.571
					local dv = root.CFrame:VectorToObjectSpace(v - prev) / spm
					local dw = prevW and root.CFrame:VectorToObjectSpace(w - prevW) or Vector3.zero
					local dir, strength = Damage.Measure(dv, dw, root.CFrame.UpVector.Y)
					if dir and os.clock() - (lastHit[model] or 0) > 0.15 then
						lastHit[model] = os.clock()
						Damage.Apply(model, dir, strength)
					end
				end
			else
				lastVel[model] = nil
				lastAng[model] = nil
			end
		end
	end)
end

-- Pannes et feu (VehicleDamage, 2026-11-18) : calage / moteur qui lâche au hasard selon la fumée, flammes qui
-- brûlent les occupants (dégâts) et enflamment quelques secondes qui s'approche du foyer (sans dégâts).
if Damage then
	task.spawn(function()
		local dt = Damage.TickEvery
		while true do
			task.wait(dt)
			for _, model in ipairs(CollectionService:GetTagged(TAG)) do
				if not model:IsDescendantOf(workspace) then
					continue
				end
				local ok = pcall(Damage.Tick, model, dt)
				if ok and model:GetAttribute("Burning") == true then
					local occupants = {}
					for _, seat in ipairs((model:FindFirstChild("Seats") or Instance.new("Folder")):GetChildren()) do
						local hum = (seat:IsA("Seat") or seat:IsA("VehicleSeat")) and seat.Occupant
						if hum and hum.Parent then
							occupants[hum.Parent] = true
							Damage.Ignite(hum.Parent, Damage.OccupantAfterburn, Damage.OccupantBurnDps)
						end
					end
					local firePos, spm = Damage.FirePosition(model)
					if firePos then
						local reach = Damage.NearFireRadius * spm
						for _, plr in ipairs(Players:GetPlayers()) do
							local char = plr.Character
							local hrp = char and char:FindFirstChild("HumanoidRootPart")
							if hrp and not occupants[char] and (hrp.Position - firePos).Magnitude < reach then
								Damage.Ignite(char, Damage.NearBurnTime, 0)
							end
						end
					end
				end
			end
			Damage.BurnTick(dt)
		end
	end)
end

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
	-- vitres texturées installées avant le 2026-11-18 (AlphaMode Transparency : teinte ignorée) -> Overlay
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") and p:GetAttribute("Kind") == "glass" then
			local gsa = p:FindFirstChildOfClass("SurfaceAppearance")
			if gsa and gsa.AlphaMode ~= Enum.AlphaMode.Overlay then
				gsa.AlphaMode = Enum.AlphaMode.Overlay
			end
		end
	end
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
					-- … sauf s'il a été coupé exprès (touche moteur) : il reste coupé jusqu'à ce qu'on le relance
					if model:GetAttribute("AutoStartEngine") ~= false and model:GetAttribute("EngineDead") ~= true
						and model:GetAttribute("EngineOffByDriver") ~= true then
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
					model:SetAttribute("AxleSpin", nil)
					-- sans ça le régime, le rapport et la marche arrière du dernier envoi restaient figés pour tout le
					-- monde (mesuré 2026-11-16 : 5750 tr/min, feux de recul allumés) ; sans Rpm, le rendu l'estime
					model:SetAttribute("Rpm", nil)
					model:SetAttribute("Gear", nil)
					model:SetAttribute("Reverse", false)
					model:SetAttribute("Cruise", nil)
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
