--!nonstrict
-- FiveMVehicles/VehicleAccess (ModuleScript, SERVEUR uniquement)
-- Monter / descendre, verrouillage, stationnement (ancrage) et remise sur les roues.
-- Utilisé par FiveMVehiclesServer ; appelable par ton propre code serveur (et par Verify.lua) :
--
--   local Access = require(ReplicatedStorage.FiveMVehicles.VehicleAccess)
--   Access.Enter(player, car, "DriverSeat")   --> true | false, raison
--   Access.Exit(player)                       --> true | false, raison
--   Access.Recover(player, car)               --> true | false, raison
--   Access.SetLocked(car, true)
--   Access.PlaceOnGround(car, position, look) -- pose droit, roues au sol (garage, essais)
--   Access.Teleport(car, pivot)               -- déplacer un véhicule (même conduit) depuis le serveur
--   Access.MarkMoved(car, grace)              -- après un déplacement fait autrement par ton code serveur
--
-- Attributs du modèle :
--   Locked (bool)            invites masquées et montée refusée (on peut toujours descendre)
--   ParkAnchorDelay (s, 5)   délai sans conducteur et à l'arrêt avant ancrage de VehicleRoot
--   Parked (bool)            VehicleRoot ancré par le stationnement
--   Flipped (bool)           retourné ou sur le côté depuis plus de FLIP_DELAY s, quasi immobile
--   RecoverCooldown (s, 5)   délai entre deux remises sur les roues
--   VoidMargin (studs, 60)   tombé dans le vide : remis à sa dernière position sûre avant d'atteindre
--                            Workspace.FallenPartsDestroyHeight + VoidMargin (sinon Roblox le détruit)
--   VoidRecoveries (int)     nombre de remises après une chute (lecture)
--   TeleportGraceUntil       heure serveur jusqu'à laquelle le contrôle de vraisemblance tolère un saut
--                            (posé par Access.Teleport / MarkMoved)
-- Attributs des sièges (posés par le Setup) : Side (-1 gauche / 1 droite), Door (os de portière).

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Access = {}

Access.VehicleGroup = "FiveMVehicle"
Access.OccupantGroup = "FiveMVehicleOccupant"
Access.EnterReach = 6 -- studs au-delà de MaxActivationDistance de l'invite (latence)
Access.DoorOpenTime = 0.35 -- s avant de s'asseoir / après l'ouverture
Access.DoorCloseDelay = 1.1 -- s avant de refermer la portière ouverte pour monter / descendre
-- s sans collision avec le véhicule après la descente : jusqu'à ce que la portière soit refermée.
-- Sinon la portière encore ouverte (animée par le client, qui possède la physique) balaie l'endroit
-- où le joueur vient d'être posé et pousse joueur et véhicule (mesuré : 3 studs de glissade).
Access.OccupantGrace = Access.DoorOpenTime + Access.DoorCloseDelay + 0.6
Access.FlipUp = 0.5 -- UpVector.Y en dessous duquel le véhicule est « retourné ou sur le côté » (60°)
Access.FlipDelay = 2
Access.StillSpeed = 0.4 -- studs/s : « quasi immobile »
Access.StillSpin = 0.3 -- rad/s
Access.VoidLookahead = 0.5 -- s : position prévue (vitesse de chute) comparée au seuil de destruction
Access.SafeEvery = 0.5 -- s entre deux enregistrements de la position sûre

local groupsReady = false
local plausibility = setmetatable({}, { __mode = "k" }) -- [model] = { pos, t, cf, player }

-- À appeler après tout déplacement du véhicule par le serveur (garage, téléport, remise) : sinon le
-- contrôle de vraisemblance prend le saut pour de la triche et remet le véhicule à son ancienne place.
-- La tolérance est un attribut (TeleportGraceUntil, heure serveur) : elle vaut aussi quand le
-- déplacement vient d'un autre contexte Luau (Actor, autre script qui a son propre require).
function Access.MarkMoved(model, grace)
	local pl = plausibility[model]
	local root = model.PrimaryPart
	if pl and root then
		pl.pos, pl.t, pl.cf = root.Position, os.clock(), root.CFrame
	end
	local untilT = Workspace:GetServerTimeNow() + (grace or 1)
	if untilT > (model:GetAttribute("TeleportGraceUntil") or 0) then
		model:SetAttribute("TeleportGraceUntil", untilT)
	end
end

local function driverOf(model)
	local seat = model:FindFirstChild("DriverSeat", true)
	local occ = seat and seat.Occupant
	return occ and Players:GetPlayerFromCharacter(occ.Parent)
end

-- Déplace le véhicule (pivot du modèle) depuis le serveur, même conduit. Un simple PivotTo serveur
-- ne suffit pas quand un client possède la physique : il renvoie son ancienne position (mesuré : le
-- véhicule revient en arrière, penché). On ancre VehicleRoot (le serveur reprend la main, le moteur
-- de conduite se met en pause), on déplace, puis on désancre et on rend la physique au conducteur.
Access.TeleportHold = 0.25 -- s ancré
function Access.Teleport(model, pivot)
	local root = model.PrimaryPart
	if not root then
		return false
	end
	local wasAnchored = root.Anchored
	Access.MarkMoved(model, 1.5)
	-- vitesses annulées avant l'ancrage : une pièce ancrée garde sa vitesse et la reprend ensuite
	root.AssemblyLinearVelocity, root.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
	root.Anchored = true
	model:PivotTo(pivot)
	Access.MarkMoved(model, 1.5)
	if not wasAnchored then
		task.delay(Access.TeleportHold, function()
			if not model.Parent or not root.Parent then
				return
			end
			root.Anchored = false
			root.AssemblyLinearVelocity, root.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
			Access.MarkMoved(model, 1)
			local driver = driverOf(model)
			pcall(function()
				root:SetNetworkOwner(driver)
			end)
		end)
	end
	return true
end
local function ensureGroups()
	if groupsReady then
		return
	end
	groupsReady = true
	for _, g in ipairs({ Access.VehicleGroup, Access.OccupantGroup }) do
		if not PhysicsService:IsCollisionGroupRegistered(g) then
			PhysicsService:RegisterCollisionGroup(g)
		end
	end
	PhysicsService:CollisionGroupSetCollidable(Access.VehicleGroup, Access.OccupantGroup, false)
end

local function config(model)
	local m = model:FindFirstChild("VehicleConfig")
	return m and require(m) or {}
end

local function seatsOf(model)
	local out = {}
	local folder = model:FindFirstChild("Seats")
	for _, s in ipairs(folder and folder:GetChildren() or {}) do
		if s:IsA("Seat") or s:IsA("VehicleSeat") then
			table.insert(out, s)
		end
	end
	return out
end

local function vehicleOfSeat(seat)
	local m = seat and seat:FindFirstAncestorOfClass("Model")
	while m and not m:FindFirstChild("VehicleConfig") do
		m = m.Parent and m.Parent:FindFirstAncestorOfClass("Model")
	end
	return m
end

local function humanoidOf(player)
	local char = player and player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum and hum.Health > 0 then
		return hum, char
	end
	return nil
end

-- ------------------------------------------------------------------ portières
local doorTokens = setmetatable({}, { __mode = "k" })
local function openDoorBriefly(model, bone)
	local hinges = bone and config(model).Hinges
	if not (hinges and hinges[bone]) then
		return
	end
	if (model:GetAttribute("Door_" .. bone) or 0) > 0.5 and not (doorTokens[model] and doorTokens[model][bone]) then
		return -- ouverte à la main (G) : on n'y touche pas
	end
	doorTokens[model] = doorTokens[model] or {}
	local token = {}
	doorTokens[model][bone] = token
	model:SetAttribute("Door_" .. bone, 1)
	task.delay(Access.DoorCloseDelay + Access.DoorOpenTime, function()
		if doorTokens[model] and doorTokens[model][bone] == token then
			doorTokens[model][bone] = nil
			model:SetAttribute("Door_" .. bone, 0)
		end
	end)
end

-- ------------------------------------------------------------------ collision des occupants
local savedGroups = setmetatable({}, { __mode = "k" }) -- [character] = { [part] = group }
local graceTokens = setmetatable({}, { __mode = "k" })

local function setOccupantGroup(char, on)
	ensureGroups()
	if on then
		graceTokens[char] = nil
		local saved = savedGroups[char] or {}
		savedGroups[char] = saved
		for _, p in ipairs(char:GetDescendants()) do
			if p:IsA("BasePart") and p.CollisionGroup ~= Access.OccupantGroup then
				saved[p] = p.CollisionGroup
				p.CollisionGroup = Access.OccupantGroup
			end
		end
	else
		local token = {}
		graceTokens[char] = token
		task.delay(Access.OccupantGrace, function()
			if graceTokens[char] ~= token then
				return
			end
			graceTokens[char] = nil
			local saved = savedGroups[char]
			savedGroups[char] = nil
			for p, g in pairs(saved or {}) do
				if p.Parent and p.CollisionGroup == Access.OccupantGroup then
					p.CollisionGroup = g
				end
			end
		end)
	end
end

-- ------------------------------------------------------------------ position de descente
local function standHeight(hum, char)
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if hum.RigType == Enum.HumanoidRigType.R6 then
		return 3
	end
	return hum.HipHeight + (hrp and hrp.Size.Y / 2 or 1)
end

-- Cherche où poser le personnage : côté de sa portière, puis l'autre côté, puis sur le toit.
-- Chaque candidat est descendu au sol par un rayon puis contrôlé : aucune pièce solide dans le
-- volume du personnage (collision du véhicule comprise).
function Access.ExitCFrame(model, seat, hum, char)
	local root = model.PrimaryPart
	local cfg = config(model)
	local spm = cfg.StudsPerMeter or 3.571
	local b = cfg.Bounds or { Min = { -1, -0.5, -2.3 }, Max = { 1, 0.9, 2.3 } }
	local lo = Vector3.new(b.Min[1], b.Min[2], b.Min[3]) * spm
	local hi = Vector3.new(b.Max[1], b.Max[2], b.Max[3]) * spm
	local seatLocal = root.CFrame:PointToObjectSpace(seat.Position)
	local side = seat:GetAttribute("Side") or (seatLocal.X < 0 and -1 or 1)
	local h = standHeight(hum, char)
	local yaw = CFrame.lookAlong(Vector3.zero, Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z).Unit)

	local exclude = RaycastParams.new()
	exclude.FilterType = Enum.RaycastFilterType.Exclude
	exclude.FilterDescendantsInstances = { model, char }
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	overlap.FilterDescendantsInstances = { char }
	overlap.RespectCanCollide = true
	-- volume du personnage debout, bras compris (R6 : 4 studs d'épaule à épaule), orienté comme le
	-- véhicule ; il commence 0,6 stud au-dessus du sol pour tolérer une pente (6° sur 2 studs = 0,2)
	local FEET = 0.6
	local box = Vector3.new(4.2, h * 2 - FEET, 2)

	local function free(groundY, at)
		local center = Vector3.new(at.X, groundY + FEET + box.Y / 2, at.Z)
		for _, p in ipairs(Workspace:GetPartBoundsInBox(CFrame.new(center) * yaw, box, overlap)) do
			if p.CanCollide then
				return false
			end
		end
		return true
	end

	local tried = {}
	for _, s in ipairs({ side, -side }) do
		for _, extra in ipairs({ box.X / 2 + 0.3, box.X / 2 + 1.5, box.X / 2 + 3 }) do
			local x = s > 0 and hi.X + extra or lo.X - extra
			local top = root.CFrame:PointToWorldSpace(Vector3.new(x, hi.Y + 2, seatLocal.Z))
			local hit = Workspace:Raycast(top, Vector3.new(0, -(hi.Y - lo.Y) - 12, 0), exclude)
			if hit then
				if free(hit.Position.Y, hit.Position) then
					return CFrame.new(hit.Position + Vector3.new(0, h, 0)) * yaw, (s == side) and "door" or "other_side"
				end
				table.insert(tried, "blocked")
			end
		end
	end
	-- dernier recours : debout sur le toit (rayon vers le bas sur le véhicule seul)
	local onCar = RaycastParams.new()
	onCar.FilterType = Enum.RaycastFilterType.Include
	onCar.FilterDescendantsInstances = { model }
	local above = root.CFrame:PointToWorldSpace(Vector3.new(0, hi.Y + 8, seatLocal.Z))
	local roofHit = Workspace:Raycast(above, Vector3.new(0, -(hi.Y - lo.Y) - 16, 0), onCar)
	local roofY = roofHit and roofHit.Position.Y or root.CFrame:PointToWorldSpace(Vector3.new(0, hi.Y, 0)).Y
	return CFrame.new(Vector3.new(above.X, roofY + h + 0.1, above.Z)) * yaw, "roof"
end

-- ------------------------------------------------------------------ monter / descendre
function Access.CanEnter(player, model, seat)
	local hum, char = humanoidOf(player)
	if not hum then
		return false, "no_character"
	end
	if not seat or not seat:IsDescendantOf(model) then
		return false, "no_seat"
	end
	if model:GetAttribute("Locked") == true then
		return false, "locked"
	end
	if model:GetAttribute("Flipped") == true then
		return false, "flipped"
	end
	if seat.Occupant then
		return false, "occupied"
	end
	if hum.SeatPart then
		return false, "already_seated"
	end
	return true, nil, hum, char
end

function Access.Enter(player, model, seatName, prompt)
	local seat = model:FindFirstChild("Seats") and model.Seats:FindFirstChild(seatName)
	local ok, why, hum, char = Access.CanEnter(player, model, seat)
	if not ok then
		return false, why
	end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	local from = prompt and prompt.Parent and prompt.Parent:IsA("Attachment") and prompt.Parent.WorldPosition or seat.Position
	local reach = (prompt and prompt.MaxActivationDistance or 8) + Access.EnterReach
	if not hrp or (hrp.Position - from).Magnitude > reach then
		return false, "too_far"
	end
	openDoorBriefly(model, seat:GetAttribute("Door"))
	task.wait(Access.DoorOpenTime)
	-- l'état a pu changer pendant l'ouverture
	ok, why = Access.CanEnter(player, model, seat)
	if not ok then
		return false, why
	end
	setOccupantGroup(char, true)
	seat:Sit(hum)
	return true
end

function Access.Exit(player)
	local hum, char = humanoidOf(player)
	if not hum or not hum.SeatPart then
		return false, "not_seated"
	end
	local seat = hum.SeatPart
	local model = vehicleOfSeat(seat)
	if not model then
		return false, "not_a_vehicle"
	end
	return Access.EjectOccupant(model, seat, hum, char)
end

-- Fait descendre l'occupant d'un siège et le pose dehors (aussi utilisé quand un joueur quitte
-- son siège par un autre moyen : saut, script tiers).
local placedAt = setmetatable({}, { __mode = "k" })
function Access.WasPlacedRecently(char)
	return placedAt[char] ~= nil and os.clock() - placedAt[char] < 1
end

function Access.EjectOccupant(model, seat, hum, char)
	placedAt[char] = os.clock()
	openDoorBriefly(model, seat:GetAttribute("Door"))
	local weld = seat:FindFirstChild("SeatWeld")
	if weld then
		weld:Destroy()
	end
	if hum.Sit then
		hum.Sit = false
	end
	local cf, where = Access.ExitCFrame(model, seat, hum, char)
	-- Le personnage appartient physiquement à son client : une téléportation faite par le serveur
	-- seul est écrasée par le client qui le croit encore assis (mesuré). On demande donc au client
	-- de se poser lui-même (VehicleEvent « PlaceAt »), et on pose aussi côté serveur en secours.
	local player = Players:GetPlayerFromCharacter(char)
	local remote = script.Parent:FindFirstChild("VehicleEvent")
	if player and remote then
		remote:FireClient(player, "PlaceAt", cf)
	end
	char:PivotTo(cf)
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if hrp then
		hrp.AssemblyLinearVelocity = Vector3.zero
		hrp.AssemblyAngularVelocity = Vector3.zero
	end
	setOccupantGroup(char, false)
	return true, where, cf
end

function Access.SetLocked(model, locked)
	model:SetAttribute("Locked", locked == true)
end

-- ------------------------------------------------------------------ remise sur les roues
local lastRecover = setmetatable({}, { __mode = "k" })

function Access.IsUpsideDown(model)
	local root = model.PrimaryPart
	return root ~= nil and root.CFrame.UpVector.Y < Access.FlipUp
end

function Access.Recover(player, model)
	local root = model.PrimaryPart
	if not root then
		return false, "no_root"
	end
	if not Access.IsUpsideDown(model) then
		return false, "not_flipped"
	end
	-- (une pièce ancrée garde la dernière vitesse lue : on ne la compte pas)
	if not root.Anchored and root.AssemblyLinearVelocity.Magnitude > 3 then
		return false, "moving"
	end
	local cooldown = model:GetAttribute("RecoverCooldown") or 5
	if lastRecover[model] and os.clock() - lastRecover[model] < cooldown then
		return false, "cooldown"
	end
	if player then
		local hum, char = humanoidOf(player)
		if not hum then
			return false, "no_character"
		end
		local inside = hum.SeatPart and hum.SeatPart:IsDescendantOf(model)
		local hrp = char:FindFirstChild("HumanoidRootPart")
		if not inside and (not hrp or (hrp.Position - root.Position).Magnitude > 30) then
			return false, "too_far"
		end
	end
	lastRecover[model] = os.clock()
	-- cap conservé, véhicule remis droit, puis posé : bas des roues sur la surface dessous
	local look = root.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.2 then
		local up = root.CFrame.UpVector
		flat = Vector3.new(-up.X, 0, -up.Z) -- véhicule debout sur le nez / l'arrière
	end
	Access.PlaceOnGround(model, root.Position, flat)
	model:SetAttribute("Flipped", false)
	return true
end

-- Pose le véhicule droit, cap `look` (horizontal), roues sur la surface sous `pos` (studs, monde).
-- Vitesses remises à zéro. Sert à la remise sur les roues, aux essais et à ton propre code (garage…).
function Access.PlaceOnGround(model, pos, look)
	local root = model.PrimaryPart
	if not root then
		return false
	end
	local cfg = config(model)
	local spm = cfg.StudsPerMeter or 3.571
	local flat = look and Vector3.new(look.X, 0, look.Z) or Vector3.new(0, 0, -1)
	flat = flat.Magnitude > 1e-3 and flat.Unit or Vector3.new(0, 0, -1)
	local lowest = math.huge
	for _, w in pairs(cfg.Wheels or {}) do
		lowest = math.min(lowest, (w.Position[2] - (w.Radius or 0.35)) * spm)
	end
	if lowest == math.huge then
		lowest = (cfg.Bounds and cfg.Bounds.Min[2] or -0.5) * spm
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { model }
	local hit = Workspace:Raycast(pos + Vector3.new(0, 20, 0), Vector3.new(0, -60, 0), params)
	local y = hit and (hit.Position.Y - lowest + 0.05) or (pos.Y + 4)
	local target = CFrame.lookAlong(Vector3.new(pos.X, y, pos.Z), flat)
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	Access.Teleport(model, target * root.CFrame:ToObjectSpace(model:GetPivot()))
	return hit ~= nil
end

-- ------------------------------------------------------------------ stationnement + état « retourné »
local watch = {} -- [model] = { stillSince, flipSince, safe, safeAt }

function Access.Watch(model)
	watch[model] = watch[model] or { safe = model:GetPivot(), safeAt = 0 }
end

-- Chute dans le vide : avant que Roblox ne détruise les pièces sous FallenPartsDestroyHeight, le
-- serveur reprend la physique, remet le véhicule (et ses occupants, soudés aux sièges) à sa dernière
-- position sûre, vitesses nulles, puis rend la physique au conducteur.
function Access.RecoverFromVoid(model)
	local st = watch[model]
	local root = model.PrimaryPart
	if not st or not root then
		return false
	end
	Access.Teleport(model, st.safe + Vector3.new(0, 0.3, 0))
	model:SetAttribute("VoidRecoveries", (model:GetAttribute("VoidRecoveries") or 0) + 1)
	model:SetAttribute("Flipped", false)
	return true
end

local function inVoid(model, root)
	local floor = Workspace.FallenPartsDestroyHeight + (model:GetAttribute("VoidMargin") or 60)
	local vy = math.min(root.AssemblyLinearVelocity.Y, 0)
	return root.Position.Y + vy * Access.VoidLookahead < floor
end

local safeParams = RaycastParams.new()
safeParams.FilterType = Enum.RaycastFilterType.Exclude
local function trackSafe(model, root, st, now)
	if root.Anchored then
		st.safe = model:GetPivot()
		return
	end
	if now - (st.safeAt or 0) < Access.SafeEvery then
		return
	end
	-- droit, sans grande vitesse verticale, sol à moins de ~3 m sous le centre
	if root.CFrame.UpVector.Y < 0.85 or math.abs(root.AssemblyLinearVelocity.Y) > 10 then
		return
	end
	safeParams.FilterDescendantsInstances = { model }
	local spm = config(model).StudsPerMeter or 3.571
	if Workspace:Raycast(root.Position, Vector3.new(0, -3 * spm, 0), safeParams) then
		st.safe, st.safeAt = model:GetPivot(), now
	end
end

function Access.Unwatch(model)
	watch[model] = nil
end

function Access.Step()
	local now = os.clock()
	for model, st in pairs(watch) do
		local root = model.PrimaryPart
		if not model.Parent or not root then
			watch[model] = nil
			continue
		end
		if not root.Anchored and inVoid(model, root) then
			Access.RecoverFromVoid(model)
			continue
		end
		trackSafe(model, root, st, now)
		local driverSeat = model:FindFirstChild("DriverSeat", true)
		local hasDriver = driverSeat and driverSeat.Occupant ~= nil
		if hasDriver then
			Access.CheckPlausibility(model)
		end
		local still = root.Anchored
			or (root.AssemblyLinearVelocity.Magnitude < Access.StillSpeed and root.AssemblyAngularVelocity.Magnitude < Access.StillSpin)
		-- retourné / sur le côté, quasi immobile, depuis FlipDelay s
		if Access.IsUpsideDown(model) and (still or root.AssemblyLinearVelocity.Magnitude < 1.5) then
			st.flipSince = st.flipSince or now
			if now - st.flipSince >= Access.FlipDelay and model:GetAttribute("Flipped") ~= true then
				model:SetAttribute("Flipped", true)
			end
		else
			st.flipSince = nil
			if model:GetAttribute("Flipped") == true then
				model:SetAttribute("Flipped", false)
			end
		end
		-- stationnement : sans conducteur et à l'arrêt depuis ParkAnchorDelay s -> ancré
		if not root.Anchored and not hasDriver and still then
			st.stillSince = st.stillSince or now
			if now - st.stillSince >= (model:GetAttribute("ParkAnchorDelay") or 5) then
				root.Anchored = true
				model:SetAttribute("Parked", true)
				st.stillSince = nil
			end
		else
			st.stillSince = nil
		end
	end
end

-- Cylindres de roues : solides quand personne ne conduit (le véhicule repose dessus), non solides
-- quand le moteur de conduite tourne (suspension par rayons ; une roue solide la contrarierait).
local function setWheelColliders(model, solid)
	local folder = model:FindFirstChild("Collision")
	local cfg = config(model)
	local default = not (cfg.Collision and cfg.Collision.WheelsCollide == false)
	for _, d in ipairs(folder and folder:GetDescendants() or {}) do
		if d:IsA("BasePart") and d:GetAttribute("Kind") == "collision_wheel" then
			d.CanCollide = solid and default
		end
	end
end
Access.SetWheelColliders = setWheelColliders

-- Conducteur assis : le véhicule est libéré (désancré) et sa physique confiée au conducteur ;
-- conducteur parti : la physique revient au serveur.
function Access.OnDriverChanged(model, player)
	local root = model.PrimaryPart
	if not root then
		return
	end
	if player then
		local builtin = model:GetAttribute("UseBuiltinDrive") ~= false
		if builtin then
			setWheelColliders(model, false)
		end
		if root.Anchored then
			root.Anchored = false
		end
		model:SetAttribute("Parked", false)
		pcall(function()
			root:SetNetworkOwner(player)
		end)
		plausibility[model] = { pos = root.Position, t = os.clock(), player = player }
	else
		setWheelColliders(model, true)
		plausibility[model] = nil
		if not root.Anchored then
			pcall(function()
				root:SetNetworkOwner(nil)
			end)
		end
	end
end

-- Contrôle de vraisemblance du véhicule piloté par un client (le serveur ne voit pas sa physique) :
-- vitesse <= RedlineTopGearKmh × SpeedMargin, déplacement entre deux contrôles plausible. En cas d'écart,
-- le serveur reprend la physique, remet le véhicule à sa dernière position valide, puis la rend.
Access.SpeedMargin = 1.35
Access.TeleportSlack = 8 -- studs
function Access.CheckPlausibility(model)
	local st = plausibility[model]
	local root = model.PrimaryPart
	if not st or not root or root.Anchored then
		return true
	end
	local grace = model:GetAttribute("TeleportGraceUntil")
	if grace and Workspace:GetServerTimeNow() < grace then
		st.pos, st.t, st.cf = root.Position, os.clock(), root.CFrame
		return true
	end
	local cfg = config(model)
	local spm = cfg.StudsPerMeter or 3.571
	local h = cfg.Handling or {}
	local vmax = ((h.RedlineTopGearKmh or 250) / 3.6) * spm * Access.SpeedMargin + 10
	local now = os.clock()
	local dt = math.max(now - st.t, 1e-3)
	local moved = (root.Position - st.pos).Magnitude
	local speed = root.AssemblyLinearVelocity.Magnitude
	if speed > vmax or moved > vmax * dt * 1.5 + Access.TeleportSlack then
		model:SetAttribute("DriveViolations", (model:GetAttribute("DriveViolations") or 0) + 1)
		local last = st.cf
		pcall(function()
			root:SetNetworkOwner(nil)
		end)
		if last then
			model:PivotTo(last * root.CFrame:ToObjectSpace(model:GetPivot()))
		end
		root.AssemblyLinearVelocity, root.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
		task.delay(1, function()
			if plausibility[model] == st and st.player.Parent and not root.Anchored then
				pcall(function()
					root:SetNetworkOwner(st.player)
				end)
			end
		end)
		st.pos, st.t = root.Position, now
		return false
	end
	st.pos, st.t, st.cf = root.Position, now, root.CFrame
	return true
end

-- Pièces de collision du véhicule dans le groupe dédié (pour laisser passer ses occupants).
function Access.TagCollision(model)
	ensureGroups()
	local folder = model:FindFirstChild("Collision")
	local list = folder and folder:GetDescendants() or {}
	local hitbox = model:FindFirstChild("Hitbox")
	if hitbox then
		table.insert(list, hitbox)
	end
	for _, p in ipairs(list) do
		if p:IsA("BasePart") then
			p.CollisionGroup = Access.VehicleGroup
		end
	end
end

Access.SetOccupantGroup = setOccupantGroup
Access.OpenDoorBriefly = openDoorBriefly

if RunService:IsServer() then
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc >= 0.25 then
			acc = 0
			Access.Step()
		end
	end)
end

return Access
