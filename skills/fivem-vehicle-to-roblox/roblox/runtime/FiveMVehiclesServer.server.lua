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
-- (victime : Model, joueur victime ou nil, véhicule, conducteur, vitesse km/h, élan donné en studs/s) — à écouter
-- par le jeu (blessures, amendes…) ; serveur seulement
local pedestrianHit = folder:FindFirstChild("PedestrianHit")
if not pedestrianHit then
	pedestrianHit = Instance.new("BindableEvent")
	pedestrianHit.Name = "PedestrianHit"
	pedestrianHit.Parent = folder
end
local pedHits = setmetatable({}, { __mode = "k" })
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
	ped = { 6, 10 }, -- piétons percutés (VehicleDrive, « HitPed »)
	spike = { 8, 12 }, -- roues sur une herse (VehicleDrive, « Spike »)
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

-- Vitesse de pointe récente de chaque véhicule vue par le serveur (m/s, linéaire + rotation × 2 m), relevée toutes
-- les 0,1 s, gardée 1,5 s : plafond des chocs annoncés par un client (« Impact »).
local speedPeak = setmetatable({}, { __mode = "k" }) -- model -> { peak, at }
local knockToken = setmetatable({}, { __mode = "k" }) -- victime -> numéro du dernier renversement
local function spmOf(model)
	local cfgModule = model:FindFirstChild("VehicleConfig")
	local ok, cfg = pcall(require, cfgModule)
	return (ok and type(cfg) == "table" and cfg.StudsPerMeter) or 3.571
end
task.spawn(function()
	while true do
		task.wait(0.1)
		local now = os.clock()
		for _, m in ipairs(CollectionService:GetTagged(TAG)) do
			local r = m.PrimaryPart
			if r and not r.Anchored then
				local spm = spmOf(m)
				local v = r.AssemblyLinearVelocity.Magnitude / spm + r.AssemblyAngularVelocity.Magnitude * 2
				local rec = speedPeak[m]
				if not rec or v >= rec[1] or now - rec[2] > 1.5 then
					speedPeak[m] = { v, now }
				end
			end
		end
	end
end)
local pairSeen = setmetatable({}, { __mode = "k" }) -- véhicule -> { autre véhicule -> os.clock() } (« PairHit »)
local function impactCap(model)
	local now = os.clock()
	local function peak(m)
		local rec = speedPeak[m]
		return (rec and now - rec[2] <= 1.6) and rec[1] or 0
	end
	local cap = peak(model)
	local root = model.PrimaryPart
	if root then
		for _, other in ipairs(CollectionService:GetTagged(TAG)) do
			local r = other ~= model and other.PrimaryPart
			if r and (r.Position - root.Position).Magnitude < 12 * spmOf(model) then
				cap = math.max(cap, peak(model) + peak(other))
			end
		end
	end
	return cap * 1.3 + 6
end

remote.OnServerEvent:Connect(function(player, model, action, key, value, ...)
	if typeof(model) ~= "Instance" or not CollectionService:HasTag(model, TAG) then
		return
	end
	if action == "Set" then
		local t = TOGGLES[key]
		if not t or typeof(value) ~= t then
			return
		end
		-- demande refusée : le client a déjà écrit la valeur chez lui (retour visuel immédiat) ; on lui renvoie la
		-- vraie, sinon il garde par ex. un moteur HS « allumé » et conduit quand même (bug signalé le 2026-11-18)
		local function refuse()
			remote:FireClient(player, "Resync", model, key, model:GetAttribute(key))
		end
		-- débit dépassé ou plus conducteur : renvoyée aussi (avant : return silencieux, Engine local divergeait en
		-- martelant la touche ; audit 2026-11-19)
		if not isDriver(player, model) or not allowed(player, "set") then
			return refuse()
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
		-- pièce arrachée (Custom.RemoveDoor) : sa collision invisible pivotait, le plafonnier s'allumait et le son
		-- changeait (audit 2026-11-19)
		if model:GetAttribute("DoorRemoved_" .. key) == true then
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
		-- force plafonnée par ce que le serveur a vu : vitesse de pointe récente de cette voiture et des véhicules
		-- proches (choc reçu à l'arrêt), rotation comprise (tonneaux). Avant : jusqu'à MaxImpact (45) même à l'arrêt,
		-- un client pouvait mettre sa voiture en feu avec ses passagers (audit 2026-11-19)
		strength = math.min(strength, impactCap(model))
		Damage.Apply(model, Vector3.new(dx, dy, dz), strength)
	elseif action == "PairHit" then
		-- choc entre deux voitures conduites, calculé par le client qui l'a vu le premier (VehicleDrive.pairImpact) :
		-- other = l'autre véhicule, dvOther / dvSelf = variations de vitesse (studs/s, monde), tS = heure serveur du
		-- choc, mode « top » = retombée sur l'autre (dégâts de toit, pas de vitesse transmise). Le serveur applique les
		-- dégâts aux deux (même Δv de part et d'autre : avant, la percutée n'en prenait souvent aucun, mesuré
		-- 2026-11-22) et transmet au conducteur de l'autre sa variation de vitesse.
		local other, dvOther, tS, dvSelf, mode, dwOther = key, value, ...
		if not Damage or not isDriver(player, model) or not allowed(player, "impact") then
			return
		end
		if typeof(other) ~= "Instance" or other == model or not CollectionService:HasTag(other, TAG) then
			return
		end
		if typeof(dvOther) ~= "Vector3" or type(tS) ~= "number" or tS ~= tS then
			return
		end
		if (dvSelf ~= nil and typeof(dvSelf) ~= "Vector3") or (mode ~= nil and mode ~= "top") then
			return
		end
		local r1, r2 = model.PrimaryPart, other.PrimaryPart
		if not r1 or not r2 or math.abs(tS - workspace:GetServerTimeNow()) > 3 then
			return
		end
		local spm = spmOf(model)
		-- le serveur voit les deux en retard : 12 m + 0,5 s de trajet de chacune
		local reach = 12 * spm + 0.5 * (r1.AssemblyLinearVelocity.Magnitude + r2.AssemblyLinearVelocity.Magnitude)
		if (r1.Position - r2.Position).Magnitude > reach then
			return
		end
		-- un seul calcul par choc : le premier reçu (celui du client qui l'a vu le premier) ; l'autre client l'adopte
		local now = os.clock()
		local last = math.max(pairSeen[model] and pairSeen[model][other] or 0, pairSeen[other] and pairSeen[other][model] or 0)
		if now - last < 0.6 then
			return
		end
		pairSeen[model] = pairSeen[model] or setmetatable({}, { __mode = "k" })
		pairSeen[model][other] = now
		local function hit(m, dv)
			local mag = dv.Magnitude
			if mag > 1e-3 and m.PrimaryPart then
				local s = math.min(mag / spmOf(m), impactCap(m))
				-- direction du centre vers le point touché = à l'opposé de la variation de vitesse (VehicleDamage)
				Damage.Apply(m, m.PrimaryPart.CFrame:VectorToObjectSpace(-dv / mag), s)
			end
		end
		hit(other, dvOther)
		if dvSelf then
			hit(model, dvSelf)
		end
		if mode == nil and dvOther.Magnitude / spm <= 60 then
			local driverId = other:GetAttribute("DriverUserId")
			local drv = type(driverId) == "number" and Players:GetPlayerByUserId(driverId)
			if drv and drv ~= player then
				-- dwOther : variation de sa vitesse de lacet (rad/s, choc décalé), bornée
				local dw = (type(dwOther) == "number" and dwOther == dwOther) and math.clamp(dwOther, -12, 12) or 0
				remote:FireClient(drv, "PairHit", model, dvOther, tS, dw)
			end
		end
	elseif action == "Spike" then
		-- roue sur une herse (tag SpikeStrip), signalée par le client du conducteur : le serveur vérifie qu'une herse
		-- est bien sous cette roue (positions vues par le serveur) puis crève le pneu (VehicleDamage.Puncture)
		local bone = key
		if not Damage or not Damage.Puncture or not isDriver(player, model) or not allowed(player, "spike") then
			return
		end
		local cfg = require(model.VehicleConfig)
		local w = type(bone) == "string" and #bone <= 32 and cfg.Wheels and cfg.Wheels[bone]
		local root = model.PrimaryPart
		if not w or not root then
			return
		end
		local spm = cfg.StudsPerMeter or 3.571
		local at = root.CFrame:PointToWorldSpace(Vector3.new(w.Position[1], w.Position[2], w.Position[3]) * spm)
		-- tolérance : 3 m + 0,4 s de trajet. Le serveur voit la voiture en retard sur son conducteur (réplication) :
		-- avec 2,5 m fixes, la moitié des passages à 70 km/h étaient refusés (2026-11-19). Sans enjeu de triche :
		-- le client ne peut crever que les pneus de la voiture qu'il conduit, près d'une herse.
		local reach = 3 + 0.4 * root.AssemblyLinearVelocity.Magnitude / spm
		local near = false
		for _, part in ipairs(workspace:GetPartBoundsInRadius(at, reach * spm)) do
			local inst = part
			for _ = 1, 4 do
				if not inst then
					break
				end
				if CollectionService:HasTag(inst, "SpikeStrip") then
					near = true
					break
				end
				inst = inst.Parent
			end
			if near then
				break
			end
		end
		if near then
			Damage.Puncture(model, bone)
		end
	elseif action == "HitPed" then
		-- piéton percuté, repéré par le client du conducteur (VehicleDrive.findPedestrians). Le serveur vérifie le
		-- conducteur, la distance (positions vues par le serveur) et plafonne la vitesse à celle qu'il voit ;
		-- puis il déclenche FiveMVehicles.PedestrianHit (le jeu peut y ajouter blessures, sanctions…) et, sauf
		-- attribut PedestrianKnockdown = false sur ReplicatedStorage.FiveMVehicles, renverse la victime.
		local victim, vCar = key, value
		if not isDriver(player, model) or not allowed(player, "ped") then
			return
		end
		if typeof(victim) ~= "Instance" or not victim:IsA("Model") or typeof(vCar) ~= "Vector3" then
			return
		end
		if vCar.X ~= vCar.X or vCar.Y ~= vCar.Y or vCar.Z ~= vCar.Z then
			return
		end
		local hum = victim:FindFirstChildOfClass("Humanoid")
		local hrp = victim:FindFirstChild("HumanoidRootPart")
		local root = model.PrimaryPart
		if not hum or not hrp or not root or hum.Health <= 0 or hum.SeatPart then
			return
		end
		local cfg = require(model.VehicleConfig)
		local spm = cfg.StudsPerMeter or 3.571
		local b = cfg.Bounds or { Min = { -1, 0, -2.3 }, Max = { 1, 1, 2.3 } }
		local radius = math.max(math.abs(b.Min[1]), b.Max[1], math.abs(b.Min[3]), b.Max[3])
		if (hrp.Position - root.Position).Magnitude > (radius + 4) * spm then
			return -- trop loin pour le serveur (latence comprise)
		end
		-- vitesse plafonnée par celle que voit le serveur (+30 % et 1,5 m/s de marge pour la latence). Avant :
		-- seen + 5, soit 5 m/s pour une voiture À L'ARRÊT -> un client pouvait renverser tout le monde à ~6 m
		-- (audit 2026-11-19)
		local seen = root.AssemblyLinearVelocity.Magnitude / spm
		local speed = math.min(vCar.Magnitude / spm, seen * 1.3 + 1.5) -- m/s
		if speed < 2.5 then
			return
		end
		pedHits[victim] = pedHits[victim] or 0
		if os.clock() - pedHits[victim] < 1 then
			return
		end
		pedHits[victim] = os.clock()
		local flat = vCar * Vector3.new(1, 0, 1)
		local dir = flat.Magnitude > 1e-3 and flat.Unit or ((hrp.Position - root.Position) * Vector3.new(1, 0, 1)).Unit
		-- projeté à peu près à la vitesse de la voiture, un peu vers le haut (choc sur le pare-chocs puis le capot)
		local knock = (dir * speed * 0.9 + Vector3.new(0, 1.2 + 0.12 * speed, 0)) * spm
		local seconds = math.clamp(1 + 0.08 * speed, 1.2, 3.5)
		local victimPlayer = Players:GetPlayerFromCharacter(victim)
		pedestrianHit:Fire(victim, victimPlayer, model, player, speed * 3.6, knock)
		if folder:GetAttribute("PedestrianKnockdown") == false then
			return
		end
		local immunity = folder:GetAttribute("KnockdownImmunityAttribute")
		if victimPlayer and type(immunity) == "string" and victimPlayer:GetAttribute(immunity) == true then
			return
		end
		-- renversé, il ne touche plus les véhicules jusqu'à se relever : sans ça la voiture le rattrapait et le
		-- POUSSAIT au sol sur 8 m avant de lui passer dessus (PNJ, 40 km/h, mesuré 2026-11-19). Groupe posé par le
		-- serveur : identique chez tous les clients.
		-- jeton : un second renversement annule les fins du premier (sinon la collision revenait, ou un PNJ se
		-- relevait, en plein second renversement ; audit 2026-11-19)
		knockToken[victim] = (knockToken[victim] or 0) + 1
		local token = knockToken[victim]
		task.delay(0.12, function()
			if victim.Parent and hum.Health > 0 then
				Access.SetOccupantGroup(victim, true)
			end
		end)
		task.delay(seconds, function()
			if knockToken[victim] == token and victim.Parent and not hum.SeatPart then
				Access.SetOccupantGroup(victim, false)
			end
		end)
		if victimPlayer then
			remote:FireClient(victimPlayer, "Knockdown", knock, seconds)
		else
			-- PNJ (physique du serveur) : renversé ici
			hum.PlatformStand = true
			hrp.AssemblyLinearVelocity = knock
			hrp.AssemblyAngularVelocity = Vector3.new(math.random() - 0.5, 0, math.random() - 0.5) * 6
			task.delay(seconds, function()
				if knockToken[victim] == token and hum.Parent and hum.Health > 0 then
					hum.PlatformStand = false
					hum:ChangeState(Enum.HumanoidStateType.GettingUp)
				end
			end)
		end
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
			-- protégé : une erreur sur un véhicule (attribut du jeu de mauvais type…) arrêtait la saleté pour tout le
			-- serveur (audit 2026-11-19)
			pcall(function()
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
			end)
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
	local rollDue = setmetatable({}, { __mode = "k" })
	local ROLL_WINDOW = 0.6 -- s après le passage sur le toit pour que le toit touche quelque chose
	-- Le toit touche-t-il quelque chose ? Balayage d'une sphère du centre vers le toit (vecteur haut de la voiture,
	-- tourné vers le sol pendant le tonneau), jusqu'au haut de la caisse + 0,35 m, contre ce qui entre en collision
	-- avec les véhicules (sol, murs, autres voitures ; pas les occupants ni les débris).
	local roofParams = RaycastParams.new()
	roofParams.FilterType = Enum.RaycastFilterType.Exclude
	roofParams.CollisionGroup = "FiveMVehicle"
	local function roofTouches(model, root)
		local ok, cfg = pcall(require, model:FindFirstChild("VehicleConfig"))
		cfg = ok and cfg or {}
		local spm = cfg.StudsPerMeter or 3.571
		local b = cfg.Bounds or { Min = { -0.9, -0.3, -2.2 }, Max = { 0.9, 1.2, 2.2 } }
		local reach = (b.Max[2] + 0.35) * spm
		local radius = math.min(math.abs(b.Min[1]), b.Max[1], 0.6) * spm
		roofParams.FilterDescendantsInstances = { model }
		local hit = workspace:Spherecast(root.Position, radius, root.CFrame.UpVector * reach, roofParams)
		return hit ~= nil
	end
	RunService.Heartbeat:Connect(function()
		for _, model in ipairs(CollectionService:GetTagged(TAG)) do
			local root = model.PrimaryPart
			local seat = model:FindFirstChild("DriverSeat", true)
			-- tonneau : un passage sur le toit (vecteur haut qui passe sous l'horizontale) ouvre une fenêtre de
			-- RollWindow s ; le choc de toit ne compte que si le toit TOUCHE quelque chose pendant ce temps, quel que soit
			-- celui qui tient la physique (le serveur voit la position répliquée). Avant le 2026-11-19, le seul passage
			-- comptait : des tonneaux EN L'AIR (tremplin) prenaient un choc de 16 m/s par tour, jusqu'au feu (signalé
			-- par l'utilisateur : « les dégâts se font dus au choc, pas au tonneau »).
			if root and not root.Anchored then
				local upY = root.CFrame.UpVector.Y
				local prevUp = lastUp[model]
				lastUp[model] = upY
				if prevUp and prevUp >= -0.2 and upY < -0.2 and os.clock() - (lastRoll[model] or 0) > 0.4 then
					rollDue[model] = os.clock() + ROLL_WINDOW
				end
				local due = rollDue[model]
				if due and (os.clock() > due or upY > 0.2) then
					rollDue[model] = nil
				elseif due and roofTouches(model, root) then
					rollDue[model] = nil
					lastRoll[model] = os.clock()
					local ok, cfg = pcall(require, model:FindFirstChild("VehicleConfig"))
					local spm = (ok and cfg and cfg.StudsPerMeter) or 3.571
					local speed = root.AssemblyLinearVelocity.Magnitude / spm
					Damage.Apply(model, Vector3.yAxis, math.max(Damage.RollMin or 14, speed * (Damage.RollSpeedShare or 1)))
				end
			else
				lastUp[model] = nil
				rollDue[model] = nil
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
				-- feu protégé aussi : une erreur ici arrêtait flammes et brûlures pour tout le serveur (audit 2026-11-19)
				pcall(function()
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
				end)
			end
			pcall(Damage.BurnTick, dt)
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

-- véhicules déjà branchés : un modèle tagué retiré puis remis (Parent nil puis workspace : garage, dépôt ; tag
-- retiré puis remis) repassait ici et doublait toutes les connexions (invite de portière basculée deux fois = rien ;
-- audit 2026-11-19)
local setupDone = setmetatable({}, { __mode = "k" })

local function setupVehicle(model)
	Access.TagCollision(model)
	Access.Watch(model)
	noTouchSeats(model)
	if setupDone[model] then
		refreshPrompts(model)
		return
	end
	setupDone[model] = true
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
				-- invite (tactile / manette) : mêmes règles que Alt + clic (VehicleTarget) ; pièce arrachée : plus rien
				-- à ouvrir (audit 2026-11-19)
				if model:GetAttribute("DoorRemoved_" .. bone) == true then
					return
				end
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
