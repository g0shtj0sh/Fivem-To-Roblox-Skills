--!nonstrict
--[[
	Installation du véhicule « __VEHICLE_NAME__ » converti depuis FiveM / GTA V.

	1. Roblox Studio > Avatar (ou Accueil) > Importer 3D > choisir __VEHICLE_NAME__.glb
	   (garder les options par défaut, « Insert using scene position » cochée si proposée).
	2. Sélectionner le modèle importé dans l'Explorateur.
	3. Modèle > « Exécuter un script » (Run Script) > choisir ce fichier
	   — ou copier-coller tout ce fichier dans la barre de commande puis Entrée.

	Le script : recale l'échelle et l'orientation, crée la racine, les articulations
	(roues, portes, capot, coffre, volant, gyrophares), les lumières, sièges, sons,
	livrées, néons, plaque, applique les couleurs par défaut, et installe/actualise les
	modules runtime (ReplicatedStorage.FiveMVehicles, ServerScriptService, StarterPlayerScripts).
	Généré par fivem-vehicle-to-roblox — ne pas éditer à la main, relancer le convertisseur.
]]

local CONFIG = __CONFIG_TABLE__
local CONFIG_SOURCE = __CONFIG_SOURCE__
local PARTS = __PARTS_TABLE__
local SOUND_IDS = __SOUND_IDS__ -- { ["engine_on_1.wav"] = "rbxassetid://123", ... } (vide = à remplir)
local SOURCES = __RUNTIME_SOURCES__ -- nil dans la variante « studio/ » : runtime installé à part (FiveMRuntime.lua)
local RUNTIME_VERSION = __RUNTIME_VERSION__

local Selection = game:GetService("Selection")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local warnings = {}
local function log(...)
	print("[FiveM→Roblox]", ...)
end
local function warnf(fmt, ...)
	local msg = string.format(fmt, ...)
	table.insert(warnings, msg)
	warn("[FiveM→Roblox] " .. msg)
end
local function v3(t)
	return Vector3.new(t[1], t[2], t[3])
end
local function c3(t, fallback)
	if not t then
		return fallback or Color3.new(0.8, 0.8, 0.8)
	end
	return Color3.new(t[1], t[2], t[3])
end

ChangeHistoryService:SetWaypoint("FiveM vehicle setup: début")

-- ------------------------------------------------------------------ 1. modèle importé
-- Automatisation (execute_luau) : _G.F2R_TARGET désigne le modèle importé, sans sélection.
local model = typeof(_G.F2R_TARGET) == "Instance" and _G.F2R_TARGET:IsA("Model") and _G.F2R_TARGET or nil
local NO_GROUND = _G.F2R_NO_GROUND == true -- true : garder la hauteur d'import (pas de pose au sol)
_G.F2R_TARGET, _G.F2R_NO_GROUND = nil, nil
for _, s in ipairs(model and {} or Selection:Get()) do
	if s:IsA("Model") then
		model = s
		break
	end
end
if not model then
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("BasePart") and d.Name == CONFIG.ProbePart then
			model = d:FindFirstAncestorOfClass("Model")
			-- remonter jusqu'au modèle racine importé
			while model and model.Parent and model.Parent:IsA("Model") and model.Parent ~= workspace do
				model = model.Parent
			end
			break
		end
	end
end
assert(model, "Sélectionne le modèle importé (" .. CONFIG.Name .. ".glb) dans l'Explorateur puis relance.")
assert(not model:FindFirstChild("VehicleConfig"), "Ce modèle est déjà installé. Ré-importe le .glb pour recommencer.")
model.Name = CONFIG.Name

local byName = {}
for _, d in ipairs(model:GetDescendants()) do
	if d:IsA("BasePart") and not byName[d.Name] then
		byName[d.Name] = d
	end
end
local missing, expected, missingNames = 0, 0, {}
for name in pairs(PARTS) do
	expected += 1
	if not byName[name] then
		missing += 1
		table.insert(missingNames, name)
	end
end
table.sort(missingNames)
model:SetAttribute("F2RExpectedParts", expected)
model:SetAttribute("F2RMissingParts", table.concat(missingNames, ","))
if missing > 0 then
	warnf("%d pièce(s) attendue(s) introuvable(s) dans le modèle importé (noms modifiés par l'importeur ?)", missing)
end

-- ------------------------------------------------------------------ 2. échelle + repère
local function refWorld()
	local pts = {}
	for i, name in ipairs(CONFIG.RefParts) do
		local p = byName[name]
		assert(p, "Pièce de référence introuvable : " .. name)
		pts[i] = p.Position
	end
	return pts
end
local refLocal = {}
for i, name in ipairs(CONFIG.RefParts) do
	refLocal[i] = v3(PARTS[name].Center)
end

do
	local w = refWorld()
	local importedSpm = (w[2] - w[1]).Magnitude / (refLocal[2] - refLocal[1]).Magnitude
	local factor = CONFIG.StudsPerMeter / importedSpm
	if math.abs(factor - 1) > 0.005 then
		model:ScaleTo(model:GetScale() * factor)
		log(string.format("Échelle ajustée ×%.4f (%.3f studs/m)", factor, CONFIG.StudsPerMeter))
	end
end

local function basis(a, b, c)
	local e1 = (b - a).Unit
	local e2 = (c - a) - e1 * (c - a):Dot(e1)
	e2 = e2.Unit
	local e3 = e1:Cross(e2)
	return CFrame.fromMatrix(Vector3.zero, e1, e2, e3)
end

local spm = CONFIG.StudsPerMeter
local VF -- repère véhicule dans le monde (rotation + origine), unités : studs
do
	local w = refWorld()
	local bl = basis(refLocal[1] * spm, refLocal[2] * spm, refLocal[3] * spm)
	local bw = basis(w[1], w[2], w[3])
	local rot = bw * bl:Inverse()
	local origin = w[1] - rot:VectorToWorldSpace(refLocal[1] * spm)
	VF = CFrame.new(origin) * rot
	-- contrôle : erreur moyenne sur toutes les pièces
	local err, n = 0, 0
	for name, info in pairs(PARTS) do
		local p = byName[name]
		if p and info.Center then
			err += (p.Position - VF:PointToWorldSpace(v3(info.Center) * spm)).Magnitude
			n += 1
		end
	end
	if n > 0 and err / n > 0.15 * spm then
		warnf("Recalage imprécis (erreur moyenne %.2f studs) : l'importeur a peut-être mis le modèle en miroir.", err / n)
	end
	-- on remet le véhicule droit, avant vers -Z, à sa position actuelle
	local upright = CFrame.new(VF.Position)
	model:PivotTo(upright * VF:Inverse() * model:GetPivot())
	VF = upright
end
local function L2W(t)
	return VF:PointToWorldSpace(v3(t) * spm)
end

-- ------------------------------------------------------------------ 3. racine + organisation
local root = Instance.new("Part")
root.Name = "VehicleRoot"
root.Size = Vector3.new(1, 1, 1)
root.CFrame = VF
root.Transparency = 1
root.CanCollide = false
root.CanQuery = false
root.Anchored = true -- ton moteur physique peut le désancrer
root.Parent = model
model.PrimaryPart = root

local lo, hi = v3(CONFIG.Bounds.Min) * spm, v3(CONFIG.Bounds.Max) * spm
local hitbox = Instance.new("Part")
hitbox.Name = "Hitbox"
hitbox.Size = hi - lo
hitbox.CFrame = VF * CFrame.new((lo + hi) / 2)
hitbox.Transparency = 1
hitbox.CanCollide = true
hitbox.Anchored = false
hitbox.Massless = false
hitbox.Parent = model
local hw = Instance.new("WeldConstraint")
hw.Part0, hw.Part1, hw.Parent = root, hitbox, hitbox

local visual = Instance.new("Folder")
visual.Name = "Visual"
visual.Parent = model
local jointsFolder = Instance.new("Folder")
jointsFolder.Name = "Joints"
jointsFolder.Parent = model

-- ------------------------------------------------------------------ 4. pivots articulés
local pivots = { [CONFIG.RootBone] = root }
local function boneDepth(b)
	local d = 0
	local cur = CONFIG.Bones[b]
	while cur and cur.Parent and d < 64 do
		d += 1
		cur = CONFIG.Bones[cur.Parent]
	end
	return d
end
local dynamic = {}
for _, b in ipairs(CONFIG.DynamicBones) do
	table.insert(dynamic, b)
end
table.sort(dynamic, function(a, b)
	return boneDepth(a) < boneDepth(b)
end)
local function parentPivot(bone)
	local cur = CONFIG.Bones[bone] and CONFIG.Bones[bone].Parent
	while cur do
		if pivots[cur] and cur ~= bone then
			return pivots[cur]
		end
		cur = CONFIG.Bones[cur] and CONFIG.Bones[cur].Parent
	end
	return root
end
for _, bone in ipairs(dynamic) do
	local info = CONFIG.Bones[bone]
	if info then
		local p = Instance.new("Part")
		p.Name = "Pivot_" .. bone
		p.Size = Vector3.new(0.2, 0.2, 0.2)
		p.Transparency = 1
		p.CanCollide, p.CanQuery, p.CanTouch, p.Massless = false, false, false, true
		p.CFrame = VF.Rotation + L2W(info.Position)
		p.Parent = jointsFolder
		local parent = parentPivot(bone)
		local m = Instance.new("Motor6D")
		m.Name = bone
		m.Part0 = parent
		m.Part1 = p
		m.C0 = parent.CFrame:ToObjectSpace(p.CFrame)
		m.C1 = CFrame.identity
		m:SetAttribute("Bone", bone)
		m.Parent = jointsFolder
		pivots[bone] = p
	end
end

-- ------------------------------------------------------------------ 5. pièces visuelles
local defaultColors = {}
for layer, rgb in pairs(CONFIG.Colors.Default or {}) do
	defaultColors[layer] = c3(rgb)
end
local LIGHT_OFF = {
	headlight = Color3.fromRGB(200, 200, 205),
	always_on = Color3.fromRGB(200, 200, 205),
	taillight = Color3.fromRGB(90, 10, 10),
	brakelight = Color3.fromRGB(90, 10, 10),
	indicator = Color3.fromRGB(150, 80, 20),
	reversinglight = Color3.fromRGB(200, 200, 205),
	extralight = Color3.fromRGB(150, 150, 160),
}
local ownerFolders = {}
local function folderFor(info)
	local key = info.ModSlot and ("Mod_" .. info.ModSlot .. "_" .. info.ModIndex) or info.Owner
	local f = ownerFolders[key]
	if not f then
		f = Instance.new("Folder")
		f.Name = key
		f.Parent = visual
		ownerFolders[key] = f
	end
	return f
end

-- Collision officielle du véhicule (col__<os>__<n>) : pièces invisibles qui forment la hitbox
-- fidèle, soudées à leur os (une portière ouverte garde sa collision). La précision de collision
-- ne s'écrit pas par script : on l'applique par CreateMeshPartAsync + ApplyMesh (taille gardée).
local AssetService = game:GetService("AssetService")
local collisionFolder
local collisionParts = {}
local function collisionFolderFor(owner)
	if not collisionFolder then
		collisionFolder = Instance.new("Folder")
		collisionFolder.Name = "Collision"
		collisionFolder.Parent = model
	end
	local f = collisionFolder:FindFirstChild(owner)
	if not f then
		f = Instance.new("Folder")
		f.Name = owner
		f.Parent = collisionFolder
	end
	return f
end

for name, info in pairs(PARTS) do
	local p = byName[name]
	if p and info.Kind == "collision" then
		for _, c in ipairs(p:GetChildren()) do
			if c:IsA("SurfaceAppearance") then
				c:Destroy()
			end
		end
		if p:IsA("MeshPart") then
			p.TextureID = ""
		end
		p.Anchored = false
		p.Transparency = 1
		p.CastShadow = false
		p.CanCollide, p.CanQuery, p.CanTouch = true, true, true
		p.Massless = info.Owner ~= CONFIG.RootBone
		p:SetAttribute("F2RPart", true)
		p:SetAttribute("Kind", "collision")
		p:SetAttribute("Bone", info.Bone)
		p:SetAttribute("BoneChain", info.BoneChain)
		p:SetAttribute("Owner", info.Owner)
		p:SetAttribute("Convex", info.Convex == true)
		p:SetAttribute("BaseTransparency", 1)
		if p:IsA("MeshPart") then
			local want = info.Convex and Enum.CollisionFidelity.Hull or Enum.CollisionFidelity.PreciseConvexDecomposition
			local ok, err = pcall(function()
				local tmp = AssetService:CreateMeshPartAsync(p.MeshContent, { CollisionFidelity = want })
				p:ApplyMesh(tmp)
				tmp:Destroy()
			end)
			if not ok then
				warnf("Précision de collision non appliquée à %s (%s) : reste %s.", name, tostring(err), tostring(p.CollisionFidelity))
			end
		end
		p.Parent = collisionFolderFor(info.Owner)
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = pivots[info.Owner] or root
		weld.Part1 = p
		weld.Parent = p
		table.insert(collisionParts, p)
	elseif p then
		local sa = p:FindFirstChildOfClass("SurfaceAppearance")
		p.Anchored = false
		p.CanCollide, p.CanQuery, p.CanTouch, p.Massless = false, false, false, true
		p:SetAttribute("F2RPart", true)
		p:SetAttribute("Kind", info.Kind)
		p:SetAttribute("Bone", info.Bone)
		p:SetAttribute("BoneChain", info.BoneChain)
		p:SetAttribute("Owner", info.Owner)
		if info.ModSlot then
			p:SetAttribute("ModSlot", info.ModSlot)
			p:SetAttribute("ModIndex", info.ModIndex)
		end
		if info.Extra then
			p:SetAttribute("Extra", info.Extra)
		end
		if info.Window then
			p:SetAttribute("Window", info.Window)
		end
		local kind = info.Kind
		local base = 0
		if kind == "paint" or info.Paint then
			local color = defaultColors[info.Paint or "Primary"] or Color3.new(0.85, 0.85, 0.85)
			if info.Paint then
				p:SetAttribute("PaintLayer", info.Paint)
			end
			if info.CustomColor then
				color = c3(info.CustomColor)
			end
			p.Material = Enum.Material.SmoothPlastic
			p.Reflectance = (info.Paint == "Primary" or info.Paint == "Secondary") and 0.05 or 0
			p.Color = color
			if info.Livery then
				p:SetAttribute("Livery", true)
				if sa then
					sa:Destroy() -- remplacé par la livrée choisie (dossier Liveries)
				end
			elseif sa and not info.HasTexture then
				sa:Destroy()
			elseif sa then
				pcall(function()
					sa.Color = color
				end)
			end
		elseif kind == "glass" then
			if sa then
				sa:Destroy()
			end
			p.Material = Enum.Material.Glass
			p.Color = c3(info.AvgColor, Color3.new(0.1, 0.11, 0.12)):Lerp(Color3.new(0.05, 0.05, 0.06), 0.5)
			base = 0.45
			p.CastShadow = false
		elseif kind == "light" or kind == "siren" then
			if sa then
				sa:Destroy()
			end
			local role = info.Light or ("siren" .. tostring(info.Siren))
			if kind == "light" then
				p:SetAttribute("LightRole", role)
			else
				p:SetAttribute("Siren", info.Siren)
			end
			local family = string.match(role, "^(%a+)") or "headlight"
			local off = info.AvgColor and c3(info.AvgColor) or LIGHT_OFF[family] or Color3.new(0.6, 0.6, 0.6)
			p:SetAttribute("OffColor", off)
			p:SetAttribute("OffMaterial", "Glass")
			p:SetAttribute("OffTransparency", 0.15)
			p.Material = Enum.Material.Glass
			p.Color = off
			base = 0.15
			p.CastShadow = false
		elseif kind == "decal" then
			if sa then
				pcall(function()
					sa.AlphaMode = Enum.AlphaMode.Transparency
				end)
			end
			p.CastShadow = false
		elseif kind == "rotor" then
			base = 0.6
		elseif not sa then
			p.Color = c3(info.AvgColor, kind == "tire" and Color3.fromRGB(25, 25, 25) or Color3.fromRGB(60, 60, 62))
			if info.CustomColor then
				p.Color = c3(info.CustomColor)
			end
		end
		p:SetAttribute("BaseTransparency", base)
		p.Transparency = info.ModSlot and 1 or base
		if kind == "plate" then
			local face = Enum.NormalId.Back
			if info.Normal then
				local nl = p.CFrame:VectorToObjectSpace(VF:VectorToWorldSpace(v3(info.Normal)))
				local ax = { { "Right", nl.X }, { "Left", -nl.X }, { "Top", nl.Y }, { "Bottom", -nl.Y }, { "Back", nl.Z }, { "Front", -nl.Z } }
				table.sort(ax, function(a, b)
					return a[2] > b[2]
				end)
				face = Enum.NormalId[ax[1][1]]
			end
			local gui = Instance.new("SurfaceGui")
			gui.Name = "Plate"
			gui.Face = face
			gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
			gui.PixelsPerStud = 60
			local label = Instance.new("TextLabel")
			label.Name = "PlateText"
			label.Size = UDim2.fromScale(0.8, 0.5)
			label.Position = UDim2.fromScale(0.1, 0.3)
			label.BackgroundTransparency = 1
			label.TextScaled = true
			label.Font = Enum.Font.Arcade
			label.TextColor3 = Color3.fromRGB(20, 30, 90)
			label.Text = CONFIG.PlateText or "F2R 000"
			label.Parent = gui
			gui.Parent = p
		end
		p.Parent = folderFor(info)
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = pivots[info.Owner] or root
		weld.Part1 = p
		weld.Parent = p
	end
end

-- roues de collision (Disc GTA -> cylindres), et rôle de la boîte « Hitbox »
local coll = CONFIG.Collision or {}
for bone, w in pairs(coll.Wheels or {}) do
	local pv = pivots[bone]
	if pv then
		local c = Instance.new("Part")
		c.Name = "Collision_" .. bone
		c.Shape = Enum.PartType.Cylinder -- axe = X de la pièce = axe de la roue
		c.Size = Vector3.new(w.Width * spm, w.Radius * 2 * spm, w.Radius * 2 * spm)
		c.CFrame = VF.Rotation + L2W(w.Center)
		c.Transparency = 1
		c.CastShadow = false
		-- solides par défaut : le véhicule désancré (conducteur à bord) repose sur ses roues ;
		-- un moteur physique à roues propres peut les rendre non solides (CanCollide = false)
		c.CanCollide = coll.WheelsCollide ~= false
		c.CanQuery, c.CanTouch = true, true
		c.Massless = true
		c:SetAttribute("Kind", "collision_wheel")
		c:SetAttribute("Owner", bone)
		c.Parent = collisionFolderFor(bone)
		local weld = Instance.new("WeldConstraint")
		weld.Part0, weld.Part1, weld.Parent = pv, c, c
		table.insert(collisionParts, c)
	end
end
if #collisionParts > 0 then
	-- la boîte reste comme volume englobant (repères, zones), sans collision ni rayons
	hitbox.CanCollide, hitbox.CanQuery, hitbox.CanTouch = false, false, false
	hitbox.Massless = true
	hitbox:SetAttribute("BoundsOnly", true)
	model:SetAttribute("CollisionSource", coll.Source or "gta")
else
	model:SetAttribute("CollisionSource", "box")
	if coll.Source == "gta" then
		warnf("Collision GTA attendue mais aucune pièce col__* trouvée : hitbox = boîte englobante.")
	end
end

-- ------------------------------------------------------------------ 6. livrées
local liveries = Instance.new("Folder")
liveries.Name = "Liveries"
liveries.Parent = model
for i, carrierName in ipairs(CONFIG.LiveryCarriers or {}) do
	local carrier = byName[carrierName]
	if carrier then
		local sa = carrier:FindFirstChildOfClass("SurfaceAppearance")
		if not sa and carrier:IsA("MeshPart") and carrier.TextureID ~= "" then
			sa = Instance.new("SurfaceAppearance")
			sa.ColorMap = carrier.TextureID
		end
		if sa then
			local copy = sa:Clone()
			copy.Name = tostring(i)
			pcall(function()
				copy.AlphaMode = Enum.AlphaMode.Overlay
			end)
			copy.Parent = liveries
		else
			warnf("Livrée %d : texture non importée (vérifier l'option textures de l'importeur)", i)
		end
		carrier:Destroy()
	end
end

-- ------------------------------------------------------------------ 7. lumières
local function attachmentAt(bone, parentPart, role, worldPos)
	local a = Instance.new("Attachment")
	a.Name = "Light_" .. role
	a:SetAttribute("LightRole", role)
	a.CFrame = parentPart.CFrame:ToObjectSpace(VF.Rotation + worldPos)
	a.Parent = parentPart
	return a
end
local ls = CONFIG.LightSettings or {}
for role, pos in pairs(CONFIG.Lights or {}) do
	local owner = pivots[CONFIG.LightOwners and CONFIG.LightOwners[role] or ""] or root
	local a = attachmentAt(role, owner, role, L2W(pos))
	local light
	if string.find(role, "^headlight") then
		light = Instance.new("SpotLight")
		light.Face = Enum.NormalId.Front
		local h = ls.headLight or {}
		light.Range = math.clamp((h.falloffMax or 30) * spm * 0.6, 20, 60)
		light.Angle = math.clamp((h.outerConeAngle or 60) * 1.2, 45, 120)
		light.Brightness = 2
		light.Shadows = true
	elseif string.find(role, "^reversinglight") then
		light = Instance.new("SpotLight")
		light.Face = Enum.NormalId.Back
		light.Range = 16
		light.Angle = 90
		light.Brightness = 1.5
	else
		light = Instance.new("PointLight")
		light.Range = string.find(role, "^indicator") and 6 or 8
		light.Brightness = 1
		light.Color = string.find(role, "^indicator") and Color3.fromRGB(255, 120, 0) or Color3.fromRGB(255, 20, 20)
	end
	light.Enabled = false
	light.Parent = a
end
for i, siren in pairs(CONFIG.Sirens and CONFIG.Sirens.Lights or {}) do
	local bone = "siren" .. i
	if CONFIG.Bones[bone] then
		local a = attachmentAt(bone, pivots[bone] or root, bone, L2W(CONFIG.Bones[bone].Position))
		local l = Instance.new("PointLight")
		l.Range = 18
		l.Brightness = 3
		l.Color = c3(siren.Color, Color3.new(1, 0, 0))
		l.Enabled = false
		l.Parent = a
	end
end

-- ------------------------------------------------------------------ 8. sièges
local seats = Instance.new("Folder")
seats.Name = "Seats"
seats.Parent = model
for i, s in ipairs(CONFIG.Seats or {}) do
	local seat = Instance.new("Seat")
	seat.Name = s.Driver and "DriverSeat" or ("Seat_" .. s.Bone)
	seat.Size = Vector3.new(1.6, 0.4, 1.6)
	seat.Transparency = 1
	seat.CanCollide = false
	seat.Massless = true
	seat.Anchored = false
	seat.CFrame = VF.Rotation + L2W(s.Position) - Vector3.new(0, 0.3 * spm, 0)
	-- côté de la portière (-1 gauche, 1 droite, repère du véhicule) et portière associée
	local side = (s.Position[1] or 0) < 0 and -1 or 1
	seat:SetAttribute("Side", side)
	local door = string.gsub(s.Bone or "", "^seat_", "door_")
	if not (CONFIG.Hinges and CONFIG.Hinges[door]) then
		-- portière la plus proche du même côté (sièges arrière sans portière dédiée, noms non standard)
		door = nil
		local best = math.huge
		for bone, h in pairs(CONFIG.Hinges or {}) do
			local hp = h.Pivot or (CONFIG.Bones[bone] and CONFIG.Bones[bone].Position)
			if hp and string.find(bone, "^door_") and (hp[1] < 0) == (side < 0) then
				local d = math.abs(hp[3] - s.Position[3])
				if d < best then
					door, best = bone, d
				end
			end
		end
	end
	if door then
		seat:SetAttribute("Door", door)
	end
	seat.Parent = seats
	local w = Instance.new("WeldConstraint")
	w.Part0, w.Part1, w.Parent = root, seat, seat

	-- invite « Conduire / Monter » (F, manette Y ; bouton à l'écran sur mobile), dehors, côté portière
	local halfWidth = math.max(math.abs(CONFIG.Bounds.Min[1]), math.abs(CONFIG.Bounds.Max[1]))
	local a = Instance.new("Attachment")
	a.Name = "Enter_" .. seat.Name
	a.Parent = root -- parent d'abord : WorldPosition d'un attachment sans parent devient une position locale
	a.WorldPosition = L2W({ side * (halfWidth + 0.35), (s.Position[2] or 0) + 0.15, s.Position[3] or 0 })
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "EnterPrompt"
	prompt.ActionText = s.Driver and "Conduire" or "Monter"
	prompt.ObjectText = CONFIG.DisplayName or CONFIG.Name
	prompt.KeyboardKeyCode = Enum.KeyCode.F
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonY
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = math.max(6, 1.6 * spm)
	prompt.RequiresLineOfSight = false
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton -- avant / arrière : la plus proche
	prompt:SetAttribute("SeatName", seat.Name)
	prompt:SetAttribute("Available", true)
	prompt.Parent = a
end
do -- invite « Remettre sur ses roues » : activée par le serveur quand le véhicule est retourné
	local a = Instance.new("Attachment")
	a.Name = "RecoverPrompt"
	a.Parent = root
	a.WorldPosition = VF.Position
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "RecoverPrompt"
	prompt.ActionText = "Remettre sur ses roues"
	prompt.ObjectText = CONFIG.DisplayName or CONFIG.Name
	prompt.KeyboardKeyCode = Enum.KeyCode.F
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonY
	prompt.HoldDuration = 1
	prompt.MaxActivationDistance = math.max(10, 3 * spm)
	prompt.RequiresLineOfSight = false
	prompt.Enabled = false
	prompt:SetAttribute("Recover", true)
	prompt.Parent = a
end

-- ------------------------------------------------------------------ 9. portes (ProximityPrompt)
local DOOR_LABELS = {
	door_dside_f = "Portière avant gauche", door_pside_f = "Portière avant droite",
	door_dside_r = "Portière arrière gauche", door_pside_r = "Portière arrière droite",
	bonnet = "Capot", boot = "Coffre", boot_2 = "Coffre 2",
}
if CONFIG.DoorPrompts ~= false then
	for bone, hinge in pairs(CONFIG.Hinges or {}) do
		local pv = pivots[bone]
		if pv then
			local a = Instance.new("Attachment")
			a.Name = "Prompt_" .. bone
			a.Parent = pv
			a.WorldPosition = L2W(hinge.Center or CONFIG.Bones[bone].Position)
			local prompt = Instance.new("ProximityPrompt")
			prompt.ActionText = "Ouvrir / fermer"
			prompt.ObjectText = DOOR_LABELS[bone] or bone
			prompt.KeyboardKeyCode = Enum.KeyCode.G
			prompt.HoldDuration = 0
			prompt.MaxActivationDistance = 7
			prompt.RequiresLineOfSight = false
			prompt:SetAttribute("HingeBone", bone)
			prompt.Parent = a
		end
	end
end

-- ------------------------------------------------------------------ 10. sons
local sounds = Instance.new("Attachment")
sounds.Name = "Sounds"
sounds.Parent = root
sounds.WorldPosition = L2W(CONFIG.EnginePosition or { 0, 0.5, -1.2 })
local missingSounds = 0
local function makeSound(name, file, volume)
	local s = Instance.new("Sound")
	s.Name = name
	s.SoundId = SOUND_IDS[file] or ""
	if s.SoundId == "" then
		missingSounds += 1
	end
	s:SetAttribute("SourceFile", file)
	s.Volume = volume
	s.RollOffMode = Enum.RollOffMode.InverseTapered
	s.RollOffMinDistance = 12
	s.RollOffMaxDistance = 220
	s.Parent = sounds
	return s
end
for _, loop in ipairs(CONFIG.Audio.EngineLoops or {}) do
	makeSound(loop.Name, loop.File, 0).Looped = true
end
for key, file in pairs(CONFIG.Audio.Files or {}) do
	makeSound(key, file, (key == "Horn" or string.find(key, "^Siren")) and 1 or 0.6)
end
if missingSounds > 0 then
	warnf("%d son(s) sans SoundId : uploade le dossier sounds/ (roblox_upload.py ou Creator Hub) puis relance le convertisseur avec --sound-ids, ou renseigne SoundId à la main (attribut SourceFile).", missingSounds)
end

-- ------------------------------------------------------------------ 11. néons
local neons = Instance.new("Folder")
neons.Name = "Neons"
neons.Parent = model
do
	local y = lo.Y + 0.08 * spm
	local cz = (lo.Z + hi.Z) / 2
	local cx = (lo.X + hi.X) / 2
	local inset = 0.25 * spm
	local strips = {
		{ Vector3.new(cx, y, lo.Z + inset), Vector3.new((hi.X - lo.X) * 0.8, 0.1, 0.1) },
		{ Vector3.new(cx, y, hi.Z - inset), Vector3.new((hi.X - lo.X) * 0.8, 0.1, 0.1) },
		{ Vector3.new(lo.X + inset, y, cz), Vector3.new(0.1, 0.1, (hi.Z - lo.Z) * 0.7) },
		{ Vector3.new(hi.X - inset, y, cz), Vector3.new(0.1, 0.1, (hi.Z - lo.Z) * 0.7) },
	}
	for i, s in ipairs(strips) do
		local p = Instance.new("Part")
		p.Name = "Neon" .. i
		p.Material = Enum.Material.Neon
		p.Size = s[2]
		p.CFrame = VF * CFrame.new(s[1])
		p.Transparency = 1
		p.CanCollide, p.CanQuery, p.CanTouch, p.Massless = false, false, false, true
		p.Parent = neons
		local l = Instance.new("PointLight")
		l.Range = 8
		l.Brightness = 2
		l.Enabled = false
		l.Parent = p
		local w = Instance.new("WeldConstraint")
		w.Part0, w.Part1, w.Parent = root, p, p
	end
end

-- ------------------------------------------------------------------ 12. config + attributs
local function luaLiteral(v, indent)
	indent = indent or ""
	local t = typeof(v)
	if t == "string" then
		return string.format("%q", v)
	elseif t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then
			return "0"
		end
		return (v == math.floor(v) and math.abs(v) < 1e15) and string.format("%d", v) or string.format("%.6g", v)
	elseif t == "boolean" or t == "nil" then
		return tostring(v)
	elseif t == "table" then
		local keys = {}
		for k in pairs(v) do
			table.insert(keys, k)
		end
		if #keys == 0 then
			return "{}"
		end
		table.sort(keys, function(a, b)
			if type(a) == type(b) then
				return a < b
			end
			return type(a) == "number"
		end)
		local inner = indent .. "\t"
		local parts = {}
		for _, k in ipairs(keys) do
			local key = (type(k) == "string" and string.match(k, "^[%a_][%w_]*$")) and k or ("[" .. luaLiteral(k) .. "]")
			table.insert(parts, inner .. key .. " = " .. luaLiteral(v[k], inner))
		end
		return "{\n" .. table.concat(parts, ",\n") .. ",\n" .. indent .. "}"
	end
	return "nil"
end
local cfgModule = Instance.new("ModuleScript")
cfgModule.Name = "VehicleConfig"
cfgModule.Source = CONFIG_SOURCE or ("-- Généré par fivem-vehicle-to-roblox\nreturn " .. luaLiteral(CONFIG))
cfgModule.Parent = model

local defaults = {
	Engine = false, Headlights = 0, Indicator = "Off", Siren = false, SirenSound = "wail",
	HasSiren = CONFIG.HasSiren == true, Horn = false, Brake = false, Reverse = false,
	Throttle = 0, Steer = 0, Livery = CONFIG.DefaultLivery or 0, PlateText = CONFIG.PlateText or "F2R 000",
	AutoStartEngine = true, WindowTint = 0.45, Neon = false,
	Locked = false, ParkAnchorDelay = 5, Parked = true, Flipped = false, RecoverCooldown = 5,
}
for k, v in pairs(defaults) do
	model:SetAttribute(k, v)
end
for layer, color in pairs(defaultColors) do
	model:SetAttribute("Color_" .. layer, color)
end
for slot in pairs(CONFIG.Mods or {}) do
	model:SetAttribute("Mod_" .. slot, 0)
end
for _, n in ipairs(CONFIG.Extras or {}) do
	model:SetAttribute("Extra_" .. n, true)
end
CollectionService:AddTag(model, "FiveMVehicle")
pcall(function()
	-- avec StreamingEnabled : le véhicule arrive en entier chez le client (pièces, joints, config)
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
end)

-- ------------------------------------------------------------------ 13. modules runtime
local folder = ReplicatedStorage:FindFirstChild("FiveMVehicles") or Instance.new("Folder")
folder.Name = "FiveMVehicles"
folder.Parent = ReplicatedStorage
local function upsert(parent, className, name, source)
	local obj = parent:FindFirstChild(name)
	if obj and obj.ClassName ~= className then
		obj:Destroy()
		obj = nil
	end
	obj = obj or Instance.new(className)
	obj.Name = name
	if source then
		obj.Source = source
	end
	obj.Parent = parent
	return obj
end
if SOURCES then
	upsert(folder, "ModuleScript", "VehicleRuntime", SOURCES.VehicleRuntime)
	upsert(folder, "ModuleScript", "VehicleCustomization", SOURCES.VehicleCustomization)
	upsert(folder, "ModuleScript", "VehicleInput", SOURCES.VehicleInput)
	upsert(folder, "ModuleScript", "VehicleAccess", SOURCES.VehicleAccess)
	upsert(folder, "RemoteEvent", "VehicleEvent")
	if not folder:FindFirstChild("VehicleTelemetry") then
		local ok = pcall(function()
			upsert(folder, "UnreliableRemoteEvent", "VehicleTelemetry")
		end)
		if not ok then
			upsert(folder, "RemoteEvent", "VehicleTelemetry")
		end
	end
	upsert(ServerScriptService, "Script", "FiveMVehiclesServer", SOURCES.Server)
	upsert(StarterPlayer:WaitForChild("StarterPlayerScripts"), "LocalScript", "FiveMVehiclesClient", SOURCES.Client)
	folder:SetAttribute("RuntimeVersion", RUNTIME_VERSION)
elseif folder:GetAttribute("RuntimeVersion") ~= RUNTIME_VERSION then
	warnf("Runtime FiveMVehicles absent ou d'une autre version (%s, attendu %s) : exécuter studio/FiveMRuntime.lua.",
		tostring(folder:GetAttribute("RuntimeVersion")), RUNTIME_VERSION)
end

-- application de la livrée / couleurs / visibilité par défaut (code partagé avec le runtime)
-- copie : en Edit, require() renverrait la version chargée plus tôt dans la session Studio
local okCustom, Custom = pcall(function()
	return require(folder.VehicleCustomization:Clone())
end)
if okCustom then
	Custom.Apply(model, Custom.Serialize(model))
else
	warnf("Impossible de charger VehicleCustomization dans Studio : %s", tostring(Custom))
end

-- ------------------------------------------------------------------ 14. pose au sol
-- Le modèle arrive à la hauteur d'import (Importer 3D, insert_asset) : on pose le bas des roues
-- sur ce qu'il y a dessous (rayon vers le bas, véhicule exclu), à 200 studs au plus.
local groundedBy = nil
if not NO_GROUND then
	local lowest = math.huge
	for _, w in pairs(CONFIG.Wheels or {}) do
		lowest = math.min(lowest, (w.Position[2] - (w.Radius or 0.35)) * spm)
	end
	if lowest == math.huge then
		lowest = lo.Y
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { model }
	local hit = workspace:Raycast(root.Position + Vector3.new(0, 2, 0), Vector3.new(0, -200, 0), params)
	if hit then
		groundedBy = hit.Position.Y - (root.Position.Y + lowest)
		model:PivotTo(model:GetPivot() + Vector3.new(0, groundedBy, 0))
		log(string.format("Posé au sol (%+.2f studs, sur %s).", groundedBy, hit.Instance:GetFullName()))
	else
		warnf("Pas de sol sous le véhicule (200 studs) : laissé à sa hauteur d'import.")
	end
end

-- conteneurs vides laissés par l'importeur (Model « <pièce>_Node » d'insert_asset, etc.)
for _, d in ipairs(model:GetDescendants()) do
	if d:IsA("Model") and d.Parent and #d:GetDescendants() == 0 then
		d:Destroy()
	end
end

Selection:Set({ model })
ChangeHistoryService:SetWaypoint("FiveM vehicle setup: fin")
log(string.format("« %s » installé : %d pièces, %d articulations, %d mods, %d livrée(s).",
	CONFIG.DisplayName or CONFIG.Name, #visual:GetDescendants(), #jointsFolder:GetChildren(),
	CONFIG.ModCount or 0, #liveries:GetChildren()))
if #warnings > 0 then
	log(#warnings .. " avertissement(s) — voir ci-dessus.")
end
return {
	ok = true,
	model = model:GetFullName(),
	parts = #visual:GetDescendants(),
	joints = #jointsFolder:GetChildren(),
	liveries = #liveries:GetChildren(),
	missingParts = missing,
	missingSounds = missingSounds,
	groundedBy = groundedBy,
	collisionParts = #collisionParts,
	warnings = warnings,
}
