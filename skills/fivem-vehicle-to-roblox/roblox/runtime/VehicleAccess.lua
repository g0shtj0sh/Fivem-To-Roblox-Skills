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
--
-- Attributs du modèle :
--   Locked (bool)            invites masquées et montée refusée (on peut toujours descendre)
--   ParkAnchorDelay (s, 5)   délai sans conducteur et à l'arrêt avant ancrage de VehicleRoot
--   Parked (bool)            VehicleRoot ancré par le stationnement
--   Flipped (bool)           retourné ou sur le côté depuis plus de FLIP_DELAY s, quasi immobile
--   RecoverCooldown (s, 5)   délai entre deux remises sur les roues
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

local groupsReady = false
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
	if root.AssemblyLinearVelocity.Magnitude > 3 then
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
	local cfg = config(model)
	local spm = cfg.StudsPerMeter or 3.571
	-- cap conservé, véhicule remis droit, puis posé : bas des roues sur la surface dessous
	local look = root.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.2 then
		local up = root.CFrame.UpVector
		flat = Vector3.new(-up.X, 0, -up.Z) -- véhicule debout sur le nez / l'arrière
	end
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
	local pos = root.Position
	local hit = Workspace:Raycast(pos + Vector3.new(0, 20, 0), Vector3.new(0, -60, 0), params)
	local y = hit and (hit.Position.Y - lowest + 0.05) or (pos.Y + 4)
	local target = CFrame.lookAlong(Vector3.new(pos.X, y, pos.Z), flat)
	model:PivotTo(target * root.CFrame:ToObjectSpace(model:GetPivot()))
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	model:SetAttribute("Flipped", false)
	return true
end

-- ------------------------------------------------------------------ stationnement + état « retourné »
local watch = {} -- [model] = { stillSince, flipSince }

function Access.Watch(model)
	watch[model] = watch[model] or {}
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
		local driverSeat = model:FindFirstChild("DriverSeat", true)
		local hasDriver = driverSeat and driverSeat.Occupant ~= nil
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

-- Conducteur assis : le véhicule est libéré (désancré) et sa physique confiée au conducteur.
function Access.OnDriverChanged(model, player)
	local root = model.PrimaryPart
	if not root then
		return
	end
	if player then
		if root.Anchored then
			root.Anchored = false
		end
		model:SetAttribute("Parked", false)
		pcall(function()
			root:SetNetworkOwner(player)
		end)
	elseif not root.Anchored then
		pcall(function()
			root:SetNetworkOwnershipAuto()
		end)
	end
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
