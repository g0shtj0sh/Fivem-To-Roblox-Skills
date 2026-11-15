--!nonstrict
--[[
	VehicleTarget — portières, capot et coffre au « troisième œil », comme les serveurs FiveM (ox_target, qb-target).

		require(ReplicatedStorage.FiveMVehicles.VehicleTarget).Start()   -- FiveMVehiclesClient l'appelle

	Clavier + souris : on MAINTIENT Alt gauche, le curseur se libère, on vise une portière / le capot / le coffre
	d'un véhicule proche : une étiquette nomme la pièce et l'action (« Ouvrir » / « Fermer ») ; un clic gauche
	l'ouvre ou la ferme. Relâcher Alt rend la souris à la caméra. Rien à l'écran tant qu'Alt n'est pas maintenu.
	Tactile et manette : pas d'Alt ni de curseur ; les invites « Ouvrir / fermer » (ProximityPrompt du Setup)
	restent pour eux et sont masquées sur clavier + souris.

	Référence FiveM (ox_target, client/defaults.lua, consulté le 2026-11-15) : touche de ciblage `LMENU` (Alt
	gauche) maintenue, sélection au clic gauche ; une portière est ciblée quand le point visé est à moins de
	0,5 m de l'os `door_*` (ou 0,72 m de l'os `seat_*` du même côté), capot et coffre par un décalage ; distance
	d'interaction 2 m ; rien quand le véhicule est verrouillé ou quand on est à bord. Écart voulu (demande de
	l'utilisateur, 2026-11-15) : ASSIS dans un véhicule, Alt + clic marche aussi, sur ce véhicule seulement, sans
	limite de portée et même verrouillé ; en vue intérieure, VehicleCamera fige la vue pendant le maintien
	(`Target.IsActive()`) pour que le curseur puisse viser. Ici on vise les pièces
	visuelles de la portière elle-même (dossiers `Visual/<os>` de la charnière et de ses os enfants : vitre,
	poignée, clignotant…) — plus précis que la distance à l'os, et identique pour le capot et le coffre.

	Réglages (attributs de ReplicatedStorage.FiveMVehicles) :
	- `TargetKey` (défaut "LeftAlt") : nom d'un Enum.KeyCode ;
	- `TargetReachMeters` (défaut 2.5) : distance max entre le joueur et le point visé (ox_target : 2 m) ;
	- `TargetToggle` (défaut false) : un appui active le ciblage, le suivant le coupe (ox_target `toggleHotkey`).
	Le serveur revérifie tout (action `Door` de VehicleEvent : distance à la charnière, verrou, débit).
]]
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local RunService = game:GetService("RunService")

local Target = {}

local TAG = "FiveMVehicle"
local SCAN_METERS = 8 -- véhicules examinés autour du joueur
local DOOR_LABELS = {
	door_dside_f = "Portière avant gauche", door_pside_f = "Portière avant droite",
	door_dside_r = "Portière arrière gauche", door_pside_r = "Portière arrière droite",
	bonnet = "Capot", boot = "Coffre", boot_2 = "Coffre 2",
}

local folder = ReplicatedStorage:WaitForChild("FiveMVehicles")
local remote = folder:WaitForChild("VehicleEvent")
local player = Players.LocalPlayer

local started = false
local holding = false
local current = nil -- { model, bone, label }
local gui, chip, objectLabel, actionLabel
local parts = setmetatable({}, { __mode = "k" }) -- model -> { { part, bone } } (pièces visuelles des charnières)

local function settingKey()
	local name = folder:GetAttribute("TargetKey")
	local ok, key = pcall(function()
		return Enum.KeyCode[name or "LeftAlt"]
	end)
	return ok and key or Enum.KeyCode.LeftAlt
end

local function reachStuds(cfg)
	local m = folder:GetAttribute("TargetReachMeters")
	m = (type(m) == "number" and m == m and m > 0) and math.min(m, 6) or 2.5
	return m * ((cfg and cfg.StudsPerMeter) or 3.571)
end

local configs = setmetatable({}, { __mode = "k" })
local function configOf(model)
	local c = configs[model]
	if c == nil then
		local mod = model:FindFirstChild("VehicleConfig")
		local ok, cfg = pcall(function()
			return mod and require(mod)
		end)
		c = ok and cfg or false
		configs[model] = c
	end
	return c or nil
end

-- os -> charnière qui le porte (lui-même, ou l'ancêtre le plus proche qui est une charnière)
local function hingeOf(cfg, bone)
	local hinges, bones = cfg.Hinges or {}, cfg.Bones or {}
	local cur, n = bone, 0
	while cur and n < 64 do
		if hinges[cur] then
			return cur
		end
		cur = bones[cur] and bones[cur].Parent
		n += 1
	end
	return nil
end

local function hingeParts(model)
	local list = parts[model]
	if list and #list > 0 then
		return list
	end
	list = {}
	local cfg = configOf(model)
	local visual = model:FindFirstChild("Visual")
	if cfg and cfg.Hinges and visual then
		for _, ownerFolder in ipairs(visual:GetChildren()) do
			local bone = hingeOf(cfg, ownerFolder.Name)
			if bone then
				for _, d in ipairs(ownerFolder:GetDescendants()) do
					if d:IsA("BasePart") then
						table.insert(list, { d, bone })
					end
				end
			end
		end
	end
	parts[model] = list
	return list
end

-- Rayon contre la boîte orientée d'une pièce : distance le long du rayon, ou nil.
local function rayBox(origin, dir, cf, size)
	local o = cf:PointToObjectSpace(origin)
	local d = cf:VectorToObjectSpace(dir)
	local h = size / 2
	local tmin, tmax = 0, math.huge
	for _, axis in ipairs({ "X", "Y", "Z" }) do
		local oa, da, ha = o[axis], d[axis], h[axis]
		if math.abs(da) < 1e-8 then
			if oa < -ha or oa > ha then
				return nil
			end
		else
			local t1, t2 = (-ha - oa) / da, (ha - oa) / da
			if t1 > t2 then
				t1, t2 = t2, t1
			end
			tmin, tmax = math.max(tmin, t1), math.min(tmax, t2)
			if tmin > tmax then
				return nil
			end
		end
	end
	return tmin
end

local function seatedIn()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.SeatPart
	if not seat then
		return nil
	end
	for _, m in ipairs(CollectionService:GetTagged(TAG)) do
		if seat:IsDescendantOf(m) then
			return m
		end
	end
	return nil
end

-- Assis dans un véhicule (demande de l'utilisateur, 2026-11-15) : on vise SES portières, son capot et son coffre,
-- sans limite de portée (le capot et le coffre sont à plus de 2,5 m du siège) et sans viser les autres
-- véhicules. ox_target ne cible rien à bord ; ici, comme les menus du jeu, l'occupant garde la main sur son
-- véhicule (le serveur l'accepte : action `Door`, occupant du véhicule).
local function pick()
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local cam = workspace.CurrentCamera
	if not root or not cam then
		return nil
	end
	local inside = seatedIn()
	local mouse = UserInputService:GetMouseLocation()
	local ray = cam:ViewportPointToRay(mouse.X, mouse.Y)
	local best, bestT = nil, math.huge
	for _, model in ipairs(inside and { inside } or CollectionService:GetTagged(TAG)) do
		local pp = model.PrimaryPart
		local cfg = pp and configOf(model)
		if cfg and (inside or (pp.Position - root.Position).Magnitude <= SCAN_METERS * (cfg.StudsPerMeter or 3.571)) then
			local reach = inside and math.huge or reachStuds(cfg)
			for _, entry in ipairs(hingeParts(model)) do
				local part = entry[1]
				if part.Parent then
					local t = rayBox(ray.Origin, ray.Direction, part.CFrame, part.Size)
					if t and t < bestT then
						local hit = ray.Origin + ray.Direction * t
						if (hit - root.Position).Magnitude <= reach then
							best, bestT = { model = model, bone = entry[2], inside = inside == model }, t
						end
					end
				end
			end
		end
	end
	return best
end

-- verrou : il empêche d'ouvrir de l'extérieur, pas de l'intérieur (même règle que le serveur)
local function lockedFor(target)
	return target.model:GetAttribute("Locked") == true and not target.inside
end

-- ------------------------------------------------------------------ étiquette au curseur
local function buildGui()
	gui = Instance.new("ScreenGui")
	gui.Name = "F2R_VehicleTarget"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 50
	gui.Enabled = false
	chip = Instance.new("Frame")
	chip.Name = "Chip"
	chip.AutomaticSize = Enum.AutomaticSize.XY
	chip.BackgroundColor3 = Color3.fromRGB(18, 18, 20)
	chip.BackgroundTransparency = 0.25
	chip.BorderSizePixel = 0
	chip.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = chip
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 14), UDim.new(0, 14)
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 8), UDim.new(0, 10)
	pad.Parent = chip
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 1)
	list.Parent = chip
	local function label(name, order, size, color, weight)
		local l = Instance.new("TextLabel")
		l.Name = name
		l.LayoutOrder = order
		l.AutomaticSize = Enum.AutomaticSize.XY
		l.BackgroundTransparency = 1
		l.FontFace = Font.new("rbxasset://fonts/families/BuilderSans.json", weight)
		l.TextSize = size
		l.TextColor3 = color
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.Parent = chip
		return l
	end
	objectLabel = label("Object", 1, 16, Color3.fromRGB(190, 190, 196), Enum.FontWeight.Medium)
	actionLabel = label("Action", 2, 22, Color3.fromRGB(255, 255, 255), Enum.FontWeight.Bold)
	gui.Parent = player:WaitForChild("PlayerGui")
end

local function refreshChip()
	if not gui then
		return
	end
	if not (holding and current) then
		gui.Enabled = false
		return
	end
	local model, bone = current.model, current.bone
	objectLabel.Text = DOOR_LABELS[bone] or bone
	if lockedFor(current) then
		actionLabel.Text = "Verrouillé"
		actionLabel.TextColor3 = Color3.fromRGB(235, 120, 110)
	else
		local open = (model:GetAttribute("Door_" .. bone) or 0) > 0.5
		actionLabel.Text = open and "Fermer" or "Ouvrir"
		actionLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	end
	local m = UserInputService:GetMouseLocation() - Vector2.new(0, game:GetService("GuiService"):GetGuiInset().Y)
	chip.Position = UDim2.fromOffset(m.X + 18, m.Y + 14)
	gui.Enabled = true
end

-- ------------------------------------------------------------------ maintien de la touche
local function onClick(_, state)
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	if not (holding and current) then
		return Enum.ContextActionResult.Pass
	end
	if not lockedFor(current) then
		remote:FireServer(current.model, "Door", current.bone)
	end
	return Enum.ContextActionResult.Sink -- le clic ne part pas vers un outil tenu
end

local function setHolding(on)
	if holding == on then
		return
	end
	holding = on
	if on then
		ContextActionService:BindActionAtPriority("F2R_TargetClick", onClick, false,
			Enum.ContextActionPriority.High.Value + 10, Enum.UserInputType.MouseButton1)
		RunService:BindToRenderStep("F2R_Target", Enum.RenderPriority.Camera.Value + 2, function()
			-- après la caméra : elle remet LockCenter chaque image en première personne / verrou de Maj
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
			current = pick()
			refreshChip()
		end)
	else
		ContextActionService:UnbindAction("F2R_TargetClick")
		pcall(function()
			RunService:UnbindFromRenderStep("F2R_Target")
		end)
		current = nil
		refreshChip()
	end
end

-- ------------------------------------------------------------------ invites tactiles / manette
local function promptsWanted()
	local t = UserInputService:GetLastInputType()
	if t == Enum.UserInputType.Touch or string.find(t.Name, "^Gamepad") then
		return true
	end
	return not (UserInputService.KeyboardEnabled and UserInputService.MouseEnabled)
end

local function applyPrompt(prompt, wanted, seated)
	if prompt:IsA("ProximityPrompt") and prompt:GetAttribute("HingeBone") then
		-- à bord, FiveMVehiclesClient masque déjà toutes les invites du véhicule : ne pas les rallumer
		if seated and prompt:IsDescendantOf(seated) then
			return
		end
		prompt.Enabled = wanted
	end
end

local lastWanted = nil
local function applyPrompts(force)
	local wanted = promptsWanted()
	if wanted == lastWanted and not force then
		return -- LastInputTypeChanged bascule sans cesse entre clavier et souris : rien à refaire
	end
	lastWanted = wanted
	local seated = seatedIn()
	for _, m in ipairs(CollectionService:GetTagged(TAG)) do
		for _, d in ipairs(m:GetDescendants()) do
			applyPrompt(d, wanted, seated)
		end
	end
end

local function watchVehicle(m)
	parts[m] = nil
	applyPrompts(true)
	m.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") then
			parts[m] = nil
		end
		applyPrompt(d, promptsWanted(), seatedIn())
	end)
end

function Target.Start()
	if started then
		return
	end
	started = true
	buildGui()
	local key = settingKey()
	UserInputService.InputBegan:Connect(function(input, processed)
		if input.KeyCode == key and not processed and UserInputService.MouseEnabled then
			if folder:GetAttribute("TargetToggle") == true then
				setHolding(not holding) -- ox_target `toggleHotkey` : un appui active, le suivant désactive
			else
				setHolding(true)
			end
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == key and folder:GetAttribute("TargetToggle") ~= true then
			setHolding(false)
		end
	end)
	UserInputService.WindowFocusReleased:Connect(function()
		setHolding(false) -- Alt+Tab : la fin de l'appui n'arrive jamais
	end)
	UserInputService.TextBoxFocused:Connect(function()
		setHolding(false)
	end)
	folder:GetAttributeChangedSignal("TargetKey"):Connect(function()
		setHolding(false)
		key = settingKey()
	end)
	UserInputService.LastInputTypeChanged:Connect(function()
		applyPrompts(false)
	end)
	for _, m in ipairs(CollectionService:GetTagged(TAG)) do
		watchVehicle(m)
	end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(watchVehicle)
end

-- pour les tests : ce que viserait le curseur maintenant, sans la touche ; et si le ciblage est actif
function Target.Pick()
	return pick()
end

function Target.IsActive()
	return holding
end

return Target
