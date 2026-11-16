--!nonstrict
-- FiveMVehicles/VehicleCustomization (ModuleScript, ReplicatedStorage)
-- « La custom » : mods visuels (kits carcols), couleurs (primaire, secondaire, nacré, jantes,
-- intérieur, tableau de bord), livrées, extras, vitres, teinte, néons, xénons, plaque.
--
-- À appeler CÔTÉ SERVEUR (les changements de transparence / couleur se répliquent).
-- L'état est stocké en attributs sur le modèle => persistant, sérialisable, visible des clients.
--
--   local Custom = require(ReplicatedStorage.FiveMVehicles.VehicleCustomization)
--   Custom.SetMod(car, "Spoiler", 2)          -- 0 = d'origine
--   Custom.SetColor(car, "Primary", Color3.fromRGB(200, 0, 0))
--   Custom.SetLivery(car, 1)                  -- 0 = aucune
--   Custom.SetExtra(car, 1, false)
--   local save = Custom.Serialize(car) ; Custom.Apply(otherCar, save)
--   Custom.SetPaint(car, "Primary", 28, "Metallic")   -- peinture GTA n° 28 (VehiclePaints), finition
--
-- Menu de custom côté client (vMenu ou autre) : il envoie VehicleEvent « Custom » (voir
-- Custom.HandleRemote) ; le serveur refuse tout tant que le jeu n'a pas posé sa règle
-- d'autorisation par Custom.SetRemotePolicy(function(player, model, op) ... end).

local Custom = {}

local PAINT_LAYERS = { "Primary", "Secondary", "Pearlescent", "Wheel", "InteriorTrim", "Dashboard" }
Custom.PaintLayers = PAINT_LAYERS

-- Palette GTA (module VehiclePaints, voisin de celui-ci), chargée à la première peinture.
local paintsModule
local function paints()
	paintsModule = paintsModule or require(script.Parent:WaitForChild("VehiclePaints"))
	return paintsModule
end

local function getConfig(model)
	local cfg = model:FindFirstChild("VehicleConfig")
	return cfg and require(cfg) or {}
end

local function visualParts(model)
	local out = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and d:GetAttribute("F2RPart") then
			table.insert(out, d)
		end
	end
	return out
end
Custom.VisualParts = visualParts

local function boneChainHas(part, hidden)
	local chain = part:GetAttribute("BoneChain") or part:GetAttribute("Bone") or ""
	for bone in string.gmatch(chain, "[^/]+") do
		if hidden[bone] then
			return true
		end
	end
	return false
end

-- Recalcule la visibilité de toutes les pièces à partir des attributs du modèle.
function Custom.Refresh(model)
	local cfg = getConfig(model)
	local hidden = {}
	-- os masqués par les mods actifs (turnOffBones)
	for slot, slotInfo in pairs(cfg.Mods or {}) do
		local idx = model:GetAttribute("Mod_" .. slot) or 0
		local opt = slotInfo.Options and slotInfo.Options[idx]
		if opt and opt.TurnOffBones then
			for _, b in ipairs(opt.TurnOffBones) do
				hidden[b] = true
			end
		end
	end
	-- portières / capot / coffre arrachés (Custom.RemoveDoor) : leurs pièces disparaissent
	for bone in pairs(cfg.Hinges or {}) do
		if model:GetAttribute("DoorRemoved_" .. bone) == true then
			hidden[bone] = true
		end
	end
	local invisible = model:GetAttribute("Invisible") == true
	-- décalques, textures et écrans (plaques) suivent la visibilité du véhicule entier
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Decal") then -- (Texture hérite de Decal)
			if invisible then
				if d:GetAttribute("BaseTransparency") == nil then
					d:SetAttribute("BaseTransparency", d.Transparency)
				end
				d.Transparency = 1
			elseif d:GetAttribute("BaseTransparency") ~= nil then
				d.Transparency = d:GetAttribute("BaseTransparency")
			end
		elseif d:IsA("SurfaceGui") then
			if invisible then
				if d:GetAttribute("WasEnabled") == nil then
					d:SetAttribute("WasEnabled", d.Enabled)
				end
				d.Enabled = false
			elseif d:GetAttribute("WasEnabled") ~= nil then
				d.Enabled = d:GetAttribute("WasEnabled")
				d:SetAttribute("WasEnabled", nil)
			end
		end
	end
	for _, part in ipairs(visualParts(model)) do
		local visible = true
		local slot = part:GetAttribute("ModSlot")
		if slot then
			visible = (model:GetAttribute("Mod_" .. slot) or 0) == part:GetAttribute("ModIndex")
		elseif boneChainHas(part, hidden) then
			visible = false
		end
		local extra = part:GetAttribute("Extra")
		if extra and model:GetAttribute("Extra_" .. extra) == false then
			visible = false
		end
		local window = part:GetAttribute("Window")
		if
			window
			and part:GetAttribute("Kind") == "glass"
			and (model:GetAttribute("WindowDown_" .. window) == true or model:GetAttribute("WindowBroken_" .. window) == true)
		then
			visible = false
		end
		if invisible then
			visible = false
		end
		local base = part:GetAttribute("BaseTransparency") or 0
		if part:GetAttribute("Kind") == "glass" then
			base = model:GetAttribute("WindowTint") or base
		end
		part.Transparency = visible and base or 1
		part:SetAttribute("Visible", visible)
	end
	if Custom.RefreshNeons then
		Custom.RefreshNeons(model)
	end
end

-- ------------------------------------------------------------------ mods
function Custom.SetMod(model, slot, index)
	local cfg = getConfig(model)
	local info = cfg.Mods and cfg.Mods[slot]
	assert(info, "Slot de mod inconnu : " .. tostring(slot))
	index = math.clamp(math.floor(index or 0), 0, #info.Options)
	model:SetAttribute("Mod_" .. slot, index)
	Custom.Refresh(model)
end

function Custom.GetMod(model, slot)
	return model:GetAttribute("Mod_" .. slot) or 0
end

-- ------------------------------------------------------------------ couleurs
local function applyPaint(part, color)
	part.Color = color
	local sa = part:FindFirstChildOfClass("SurfaceAppearance")
	if sa then
		-- SurfaceAppearance.Color teinte la ColorMap ; sinon AlphaMode Overlay laisse voir Part.Color
		pcall(function()
			sa.Color = color
		end)
	end
end

-- Décoloration de la peinture (vMenu « Décoloration de la peinture », 0 = neuve, 1 = très passée) : la couleur
-- perd sa saturation, s'éclaircit vers un gris crayeux et la carrosserie perd son brillant. Attribut PaintFade ;
-- la couleur choisie (Color_<couche>) reste intacte, seule la couleur affichée est passée.
Custom.PaintFadeLook = { Saturation = 0.65, Lighten = 0.35, Chalk = 0.78, Reflectance = 0.85 }

local function fadeAmount(model)
	local f = model:GetAttribute("PaintFade")
	return type(f) == "number" and math.clamp(f, 0, 1) or 0
end

local function fadedColor(model, color)
	local f = fadeAmount(model)
	if f <= 0 then
		return color
	end
	local L = Custom.PaintFadeLook
	local h, sat, v = color:ToHSV()
	local target = Color3.fromHSV(h, sat * (1 - L.Saturation * f), v + (L.Chalk - v) * L.Lighten * f)
	return target
end

function Custom.SetColor(model, layer, color)
	assert(table.find(PAINT_LAYERS, layer), "Couche de peinture inconnue : " .. tostring(layer))
	model:SetAttribute("Color_" .. layer, color)
	local shown = fadedColor(model, color)
	for _, part in ipairs(visualParts(model)) do
		if part:GetAttribute("PaintLayer") == layer then
			applyPaint(part, shown)
		end
	end
end

function Custom.GetColor(model, layer)
	return model:GetAttribute("Color_" .. layer)
end

function Custom.SetPaintMaterial(model, layer, material, reflectance)
	for _, part in ipairs(visualParts(model)) do
		if part:GetAttribute("PaintLayer") == layer then
			part.Material = material
			if reflectance then
				part.Reflectance = reflectance
			end
		end
	end
end

-- ------------------------------------------------------------------ peintures GTA et finitions
-- Finition -> aspect Roblox des pièces peintes SANS SurfaceAppearance (une SurfaceAppearance
-- impose son propre rendu : seule la couleur s'y applique). Les pièces visuelles du convertisseur
-- sont Massless et sans collision : changer leur matériau ne touche pas la conduite.
Custom.FinishLooks = {
	Classic = { Material = Enum.Material.SmoothPlastic, Reflectance = 0.04 },
	Metallic = { Material = Enum.Material.SmoothPlastic, Reflectance = 0.12 },
	Pearl = { Material = Enum.Material.SmoothPlastic, Reflectance = 0.2 },
	Matte = { Material = Enum.Material.SmoothPlastic, Reflectance = 0 },
	Metal = { Material = Enum.Material.Metal, Reflectance = 0.08 },
	Chrome = { Material = Enum.Material.SmoothPlastic, Reflectance = 0.6 },
	Worn = { Material = Enum.Material.Plastic, Reflectance = 0 },
}

function Custom.SetFinish(model, layer, finish)
	assert(table.find(PAINT_LAYERS, layer), "Couche de peinture inconnue : " .. tostring(layer))
	local look = Custom.FinishLooks[finish]
	assert(look, "Finition inconnue : " .. tostring(finish))
	model:SetAttribute("Finish_" .. layer, finish)
	local dull = 1 - Custom.PaintFadeLook.Reflectance * fadeAmount(model)
	for _, part in ipairs(visualParts(model)) do
		if part:GetAttribute("PaintLayer") == layer and not part:FindFirstChildOfClass("SurfaceAppearance") then
			part.Material = look.Material
			part.Reflectance = look.Reflectance * dull
		end
	end
end

-- Décoloration 0..1 (0 ou nil = peinture neuve) ; réapplique la couleur et la finition de chaque couche peinte.
function Custom.SetPaintFade(model, amount)
	amount = math.clamp(tonumber(amount) or 0, 0, 1)
	model:SetAttribute("PaintFade", amount > 0.001 and amount or nil)
	for layer in pairs(Custom.LayersPresent(model)) do
		local c = model:GetAttribute("Color_" .. layer)
		if typeof(c) == "Color3" then
			Custom.SetColor(model, layer, c)
		end
		local finish = model:GetAttribute("Finish_" .. layer)
		if Custom.FinishLooks[finish] then
			Custom.SetFinish(model, layer, finish)
		elseif fadeAmount(model) > 0 then
			local dull = 1 - Custom.PaintFadeLook.Reflectance * fadeAmount(model)
			for _, part in ipairs(visualParts(model)) do
				if part:GetAttribute("PaintLayer") == layer and not part:FindFirstChildOfClass("SurfaceAppearance") then
					if part:GetAttribute("FadeBaseReflectance") == nil then
						part:SetAttribute("FadeBaseReflectance", part.Reflectance)
					end
					part.Reflectance = part:GetAttribute("FadeBaseReflectance") * dull
				end
			end
		else
			for _, part in ipairs(visualParts(model)) do
				local base = part:GetAttribute("FadeBaseReflectance")
				if base ~= nil and part:GetAttribute("PaintLayer") == layer then
					part.Reflectance = base
				end
			end
		end
	end
end

-- Peinture n° index de la palette GTA (VehiclePaints) sur une couche ; finish = finition voulue
-- (sinon celle de la peinture : Metallic, Matte, Metal, Chrome, Worn...).
function Custom.SetPaint(model, layer, index, finish)
	local p = paints().Get(index)
	assert(p, "Peinture inconnue : " .. tostring(index))
	Custom.SetColor(model, layer, p.Color)
	model:SetAttribute("Paint_" .. layer, index)
	Custom.SetFinish(model, layer, finish or p.Finish)
end

-- Couleur libre (hors palette) : la couche n'a plus de numéro de peinture GTA.
function Custom.SetCustomColor(model, layer, color)
	Custom.SetColor(model, layer, color)
	model:SetAttribute("Paint_" .. layer, nil)
end

-- Combinaison de couleurs d'usine n° n (1..#VehicleConfig.Colors.Variations, carvariations.meta) :
-- { principale, secondaire, nacré, jantes } en index de palette.
function Custom.SetFactoryColors(model, n)
	local combos = (getConfig(model).Colors or {}).Variations or {}
	local combo = combos[n]
	assert(combo, "Combinaison d'usine inconnue : " .. tostring(n))
	for i, layer in ipairs({ "Primary", "Secondary", "Pearlescent", "Wheel" }) do
		local index = combo[i]
		if index and paints().Get(index) then
			Custom.SetPaint(model, layer, index)
		end
	end
	model:SetAttribute("FactoryColors", n)
end

-- Couches de peinture qui ont au moins une pièce sur ce véhicule (un menu grise les autres).
function Custom.LayersPresent(model)
	local out = {}
	for _, part in ipairs(visualParts(model)) do
		local layer = part:GetAttribute("PaintLayer")
		if layer then
			out[layer] = true
		end
	end
	return out
end

-- ------------------------------------------------------------------ remote « Custom » (menus client)
-- Appel client : VehicleEvent:FireServer(model, "Custom", op, ...). Le skill ne sait pas qui a le
-- droit de modifier un véhicule (admin, propriétaire, garage payant...) : sans règle posée par le jeu,
-- tout est refusé. La règle reçoit (player, model, op) et renvoie true pour autoriser.
local remotePolicy = nil

function Custom.SetRemotePolicy(fn)
	assert(fn == nil or type(fn) == "function", "SetRemotePolicy attend une fonction ou nil")
	remotePolicy = fn
end

function Custom.GetRemotePolicy()
	return remotePolicy
end

local function validLayer(layer)
	return type(layer) == "string" and table.find(PAINT_LAYERS, layer) ~= nil
end

local function validIndex(n)
	return type(n) == "number" and n == n and n % 1 == 0 and paints().Get(n) ~= nil
end

local function finite(x)
	return type(x) == "number" and x == x and x > -math.huge and x < math.huge
end

-- Les opérations acceptées (Custom.HandleRemote) sont en fin de module : elles appellent toute l'API.

-- ------------------------------------------------------------------ livrées
function Custom.SetLivery(model, index)
	local store = model:FindFirstChild("Liveries")
	local count = store and #store:GetChildren() or 0
	index = math.clamp(math.floor(index or 0), 0, count)
	model:SetAttribute("Livery", index)
	local template = store and store:FindFirstChild(tostring(index))
	for _, part in ipairs(visualParts(model)) do
		if part:GetAttribute("Livery") then
			local old = part:FindFirstChildOfClass("SurfaceAppearance")
			if old then
				old:Destroy()
			end
			if template then
				local sa = template:Clone()
				sa.Name = "LiverySurface"
				pcall(function()
					sa.AlphaMode = Enum.AlphaMode.Overlay
				end)
				sa.Parent = part
			end
		end
	end
	-- recolore (la livrée laisse voir Part.Color là où elle est transparente)
	for _, layer in ipairs(PAINT_LAYERS) do
		local c = model:GetAttribute("Color_" .. layer)
		if c then
			Custom.SetColor(model, layer, c)
		end
	end
end

-- ------------------------------------------------------------------ extras / vitres
function Custom.SetExtra(model, n, enabled)
	model:SetAttribute("Extra_" .. tostring(n), enabled and true or false)
	Custom.Refresh(model)
end

function Custom.SetWindowDown(model, windowBone, down)
	model:SetAttribute("WindowDown_" .. windowBone, down and true or false)
	Custom.Refresh(model)
end

-- Vitres brisées (Custom.SmashWindows) : les vitres disparaissent jusqu'à la réparation (Custom.Repair).
function Custom.SmashWindows(model)
	for _, bone in ipairs(Custom.WindowBones(model)) do
		model:SetAttribute("WindowBroken_" .. bone, true)
	end
	Custom.Refresh(model)
end

-- Os des vitres présents sur ce véhicule (attribut `Window` des pièces de verre), triés.
function Custom.WindowBones(model)
	local seen, out = {}, {}
	for _, part in ipairs(visualParts(model)) do
		local w = part:GetAttribute("Window")
		if w and part:GetAttribute("Kind") == "glass" and not seen[w] then
			seen[w] = true
			table.insert(out, w)
		end
	end
	table.sort(out)
	return out
end

local function glassParts(model)
	local out = {}
	for _, part in ipairs(visualParts(model)) do
		if part:GetAttribute("Kind") == "glass" then
			table.insert(out, part)
		end
	end
	return out
end

-- Teinte d'origine gardée à la première retouche : « D'origine » (WindowTints[1]) y revient.
local function keepStockTint(model)
	if model:GetAttribute("WindowTintStock") ~= nil then
		return
	end
	model:SetAttribute("WindowTintStock", model:GetAttribute("WindowTint") or -1)
	for _, part in ipairs(glassParts(model)) do
		if part:GetAttribute("StockColor") == nil then
			part:SetAttribute("StockColor", part.Color)
		end
	end
end

-- 0 = vitres claires, 1 = opaques (les teintes GTA vont ~0.35 -> 0.9) ; color = teinte du verre (nil = fumé)
function Custom.SetWindowTint(model, amount, color)
	keepStockTint(model)
	amount = math.clamp(amount, 0, 0.95)
	model:SetAttribute("WindowTint", 0.6 - amount * 0.6)
	local base = color or Color3.new(0.12, 0.13, 0.14)
	for _, part in ipairs(glassParts(model)) do
		part.Color = base:Lerp(Color3.new(0.02, 0.02, 0.02), amount * (color and 0.4 or 1))
	end
	Custom.Refresh(model)
end

-- Teintes de vitres de GTA, dans l'ordre des menus (vMenu : D'origine, Aucune, Limousine, Fumé clair,
-- Fumé foncé, Noir intégral, Vert). Amount : opacité 0..0,95 de SetWindowTint.
Custom.WindowTints = {
	{ Name = "Stock", Label = "D'origine" },
	{ Name = "None", Label = "Aucune", Amount = 0 },
	{ Name = "Limo", Label = "Limousine", Amount = 0.8 },
	{ Name = "LightSmoke", Label = "Fumé clair", Amount = 0.35 },
	{ Name = "DarkSmoke", Label = "Fumé foncé", Amount = 0.6 },
	{ Name = "PureBlack", Label = "Noir intégral", Amount = 0.95 },
	{ Name = "Green", Label = "Vert", Amount = 0.55, Color = Color3.fromRGB(30, 90, 45) },
}

function Custom.SetWindowTintPreset(model, index)
	local preset = Custom.WindowTints[index]
	assert(preset, "Teinte de vitres inconnue : " .. tostring(index))
	if preset.Amount then
		Custom.SetWindowTint(model, preset.Amount, preset.Color)
	else
		local stock = model:GetAttribute("WindowTintStock")
		if stock ~= nil then
			model:SetAttribute("WindowTint", stock >= 0 and stock or nil)
			for _, part in ipairs(glassParts(model)) do
				local c = part:GetAttribute("StockColor")
				if typeof(c) == "Color3" then
					part.Color = c
				end
			end
		end
		Custom.Refresh(model)
	end
	model:SetAttribute("TintPreset", index)
end

-- ------------------------------------------------------------------ néons / xénons / fumée / plaque
-- Couleurs prédéfinies des néons et des phares xénon de GTA (même liste dans le jeu), libellés FR.
Custom.LightColors = {
	{ Name = "White", Label = "Blanc", Color = Color3.fromRGB(255, 255, 255) },
	{ Name = "Blue", Label = "Bleu", Color = Color3.fromRGB(2, 21, 255) },
	{ Name = "ElectricBlue", Label = "Bleu électrique", Color = Color3.fromRGB(3, 83, 255) },
	{ Name = "MintGreen", Label = "Vert menthe", Color = Color3.fromRGB(0, 255, 140) },
	{ Name = "LimeGreen", Label = "Vert citron", Color = Color3.fromRGB(94, 255, 1) },
	{ Name = "Yellow", Label = "Jaune", Color = Color3.fromRGB(255, 255, 0) },
	{ Name = "GoldenShower", Label = "Pluie d'or", Color = Color3.fromRGB(255, 150, 5) },
	{ Name = "Orange", Label = "Orange", Color = Color3.fromRGB(255, 62, 0) },
	{ Name = "Red", Label = "Rouge", Color = Color3.fromRGB(255, 1, 1) },
	{ Name = "PonyPink", Label = "Rose poney", Color = Color3.fromRGB(255, 50, 100) },
	{ Name = "HotPink", Label = "Rose vif", Color = Color3.fromRGB(255, 5, 190) },
	{ Name = "Purple", Label = "Violet", Color = Color3.fromRGB(35, 1, 255) },
	{ Name = "Blacklight", Label = "Lumière noire", Color = Color3.fromRGB(15, 3, 255) },
}
-- Lumière des xénons de série (sans couleur choisie) : blanc bleuté.
Custom.XenonDefault = Color3.fromRGB(200, 220, 255)

-- Les 4 rampes du dossier Neons (posées par le Setup sous la caisse) rangées par côté, d'après leur
-- position dans le repère du VehicleRoot (avant = −Z, gauche = −X).
Custom.NeonSides = { "Front", "Back", "Left", "Right" }
local function neonSideOf(model, part)
	local side = part:GetAttribute("NeonSide")
	if side then
		return side
	end
	local root = model.PrimaryPart
	if not root then
		return nil
	end
	local p = root.CFrame:PointToObjectSpace(part.Position)
	if part.Size.X >= part.Size.Z then
		side = p.Z < 0 and "Front" or "Back"
	else
		side = p.X < 0 and "Left" or "Right"
	end
	part:SetAttribute("NeonSide", side)
	return side
end

-- Néons d'un côté allumés (attribut Neon_<côté>) ; l'ancien attribut global `Neon` vaut « les 4 ».
local function neonOn(model, side)
	local v = model:GetAttribute("Neon_" .. side)
	if v ~= nil then
		return v == true
	end
	return model:GetAttribute("Neon") == true
end

function Custom.RefreshNeons(model)
	local folder = model:FindFirstChild("Neons")
	if not folder then
		return
	end
	local color = model:GetAttribute("NeonColor")
	color = typeof(color) == "Color3" and color or Color3.fromRGB(0, 140, 255)
	local hidden = model:GetAttribute("Invisible") == true
	for _, p in ipairs(folder:GetChildren()) do
		if p:IsA("BasePart") then
			local side = neonSideOf(model, p)
			local on = side ~= nil and neonOn(model, side) and not hidden
			p.Color = color
			p.Transparency = on and 0 or 1
			local light = p:FindFirstChildOfClass("SurfaceLight") or p:FindFirstChildOfClass("PointLight")
			if light then
				light.Color = color
				light.Enabled = on
			end
		end
	end
end

local function paintNeons(model)
	Custom.RefreshNeons(model)
end

-- Côtés du véhicule qui ont une rampe de néon.
function Custom.NeonSidesPresent(model)
	local out = {}
	local folder = model:FindFirstChild("Neons")
	for _, p in ipairs(folder and folder:GetChildren() or {}) do
		if p:IsA("BasePart") then
			local side = neonSideOf(model, p)
			if side then
				out[side] = true
			end
		end
	end
	return out
end

-- Tous les néons (compatibilité) : enabled pour les 4 côtés.
function Custom.SetNeon(model, enabled, color)
	color = color or model:GetAttribute("NeonColor") or Color3.fromRGB(0, 140, 255)
	model:SetAttribute("Neon", enabled and true or false)
	for _, side in ipairs(Custom.NeonSides) do
		model:SetAttribute("Neon_" .. side, nil)
	end
	model:SetAttribute("NeonColor", color)
	paintNeons(model)
end

function Custom.SetNeonSide(model, side, enabled)
	assert(table.find(Custom.NeonSides, side), "Côté de néon inconnu : " .. tostring(side))
	-- premier réglage par côté : les autres côtés partent de l'état global
	for _, s in ipairs(Custom.NeonSides) do
		if model:GetAttribute("Neon_" .. s) == nil then
			model:SetAttribute("Neon_" .. s, model:GetAttribute("Neon") == true)
		end
	end
	model:SetAttribute("Neon_" .. side, enabled and true or false)
	local any = false
	for _, s in ipairs(Custom.NeonSides) do
		any = any or model:GetAttribute("Neon_" .. s) == true
	end
	model:SetAttribute("Neon", any)
	paintNeons(model)
end

function Custom.SetNeonColor(model, color)
	model:SetAttribute("NeonColor", color)
	paintNeons(model)
end

function Custom.SetXenon(model, color)
	-- nil = phares halogènes d'origine ; le runtime client colore les phares (VehicleRuntime)
	model:SetAttribute("XenonColor", color)
end

-- Fumée de pneus colorée (VehicleTyreFx lit TyreSmokeColor) ; nil = fumée d'origine.
function Custom.SetTyreSmoke(model, color)
	model:SetAttribute("TyreSmokeColor", color)
end

-- Plaque imposée par le code du jeu (non filtrée ; pour une saisie de joueur : VehiclePlates.RequestCustom).
-- texte vide ou nil = plaque unique générée au format GTA. Renvoie true, texte  ou  false, raison.
local platesModule = nil
local function getPlates()
	-- un seul registre par exemplaire de ce module : en Edit, la copie de VehiclePlates est faite UNE fois
	-- (une copie par appel donnait un registre neuf à chaque SetPlate : Lookup ne retrouvait rien)
	if platesModule then
		return platesModule
	end
	-- le Setup charge ce module par une copie sans parent : on retombe sur ReplicatedStorage
	local folder = script.Parent or game:GetService("ReplicatedStorage"):FindFirstChild("FiveMVehicles")
	local mod = folder and folder:FindFirstChild("VehiclePlates")
	if not mod then
		return nil
	end
	if not game:GetService("RunService"):IsRunning() then
		mod = mod:Clone() -- Edit : éviter la version mise en cache par un require précédent
	end
	platesModule = require(mod)
	return platesModule
end

-- Le registre des plaques utilisé par ce module (VehiclePlates), ou nil s'il n'est pas installé.
function Custom.Plates()
	return getPlates()
end

function Custom.SetPlate(model, text)
	local Plates = getPlates()
	if not Plates then
		model:SetAttribute("PlateText", tostring(text or ""))
		return false, "no_plates_module"
	end
	return Plates.Assign(model, text)
end

function Custom.SetPlateStyle(model, index)
	local Plates = getPlates()
	model:SetAttribute("PlateStyle", index)
	model:SetAttribute("PlateStyleChosen", true) -- plus de tirage au sort à la réapparition (Plates.UseStyles)
	if Plates then
		Plates.Render(model)
	end
end

-- ------------------------------------------------------------------ performance (améliorations du garage)
-- Niveaux 0 (d'origine) .. max, en attributs `Perf_<Slot>` ; le moteur de conduite (VehicleDynamics, via
-- VehicleDrive) les applique en direct : Engine, Transmission, Brakes, Suspension, Turbo (0/1), Unlimited
-- (0/1 : débridage, seulement si le véhicule a une vitesse bridée d'origine), Armor (sans effet de conduite).
-- Les pourcentages viennent des statMods du carcols (cfg.StatMods), sinon des valeurs par défaut du moteur.
local PERF_DEFAULT_LEVELS = { Engine = 4, Transmission = 3, Brakes = 3, Suspension = 4, Armor = 5 }

function Custom.PerformanceSlots(model)
	local cfg = getConfig(model)
	local out = {}
	for slot, n in pairs(PERF_DEFAULT_LEVELS) do
		local list = cfg.StatMods and cfg.StatMods[slot]
		out[slot] = (type(list) == "table" and #list > 0) and #list or n
	end
	out.Turbo = 1
	if cfg.Performance and cfg.Performance.LimiterKmh then
		out.Unlimited = 1
	end
	return out
end

function Custom.SetPerformance(model, slot, level)
	local max = Custom.PerformanceSlots(model)[slot]
	if not max then
		return false, "slot"
	end
	level = math.clamp(math.floor(tonumber(level) or 0), 0, max)
	model:SetAttribute("Perf_" .. slot, level > 0 and level or nil)
	return true, level
end

function Custom.GetPerformance(model)
	local cfg = getConfig(model)
	local out = {}
	for slot, max in pairs(Custom.PerformanceSlots(model)) do
		local lvl = model:GetAttribute("Perf_" .. slot) or 0
		local list = cfg.StatMods and cfg.StatMods[slot]
		local item = (type(list) == "table" and lvl > 0) and list[math.min(lvl, #list)] or nil
		out[slot] = { Level = lvl, Max = max, Modifier = item and item.Modifier or nil }
	end
	return out
end

-- ------------------------------------------------------------------ son moteur (banque du jeu)
-- Un véhicule converti porte UN son du pack maison (VehicleConfig.Audio). Le jeu peut publier les autres sons du
-- pack dans ReplicatedStorage.FiveMVehicles.EngineSoundBank (scripts/engine_sound_bank.py) : le véhicule peut alors
-- prendre n'importe quel son de SA catégorie (coupé, sport, super…), jamais d'une autre. Choix = attribut
-- EngineSound (absent = son d'origine) ; chaque client refait ses couches de son (VehicleRuntime).
local ENGINE_CLASS_CATEGORY = {
	VC_COMPACT = "compact", VC_SEDAN = "berline", VC_SUV = "suv", VC_COUPE = "coupe", VC_MUSCLE = "muscle",
	VC_SPORT_CLASSIC = "classique", VC_SPORT = "sport", VC_SUPER = "super", VC_MOTORCYCLE = "sport",
	VC_OFF_ROAD = "toutterrain", VC_MILITARY = "toutterrain", VC_INDUSTRIAL = "pickup", VC_UTILITY = "pickup",
	VC_VAN = "pickup", VC_COMMERCIAL = "pickup", VC_SERVICE = "pickup", VC_EMERGENCY = "berline",
} -- = CLASS_TO_CATEGORY de scripts/f2r/sound_pack.py

local bankCache
local function engineSoundBank()
	if bankCache == nil then
		local folder = script.Parent or game:GetService("ReplicatedStorage"):FindFirstChild("FiveMVehicles")
		local mod = folder and folder:FindFirstChild("EngineSoundBank")
		local ok, bank = pcall(function()
			return mod and require(mod)
		end)
		bankCache = (ok and type(bank) == "table" and bank) or false
	end
	return bankCache or nil
end
Custom.EngineSoundBank = engineSoundBank

-- Son d'origine du véhicule (nom du pack, ex. « brolver_coupe_05 ») lu dans Audio.Source, ou nil.
local function originalEngineSound(cfg)
	local src = (cfg.Audio or {}).Source
	return type(src) == "string" and string.match(src, "^awc:([%w_]-)_moteur_") or nil
end

-- { Category, Default (son d'origine ou nil), Current, List = { {Name, Label} } } : les sons que CE véhicule peut
-- prendre (sa catégorie), son d'origine compris ; nil si le véhicule n'a pas de catégorie connue.
function Custom.EngineSounds(model)
	local cfg = getConfig(model)
	local bank = engineSoundBank() or {}
	local default = originalEngineSound(cfg)
	local category = (default and bank[default] and bank[default].Category)
		or (default and string.match(default, "^brolver_(%a+)_%d+$"))
		or ENGINE_CLASS_CATEGORY[string.upper(tostring(cfg.Class or ""))]
	if not category then
		return nil
	end
	local list = {}
	for name, entry in pairs(bank) do
		if entry.Category == category and entry.Loops then
			table.insert(list, { Name = name, Label = entry.Label or name })
		end
	end
	if default and not bank[default] then
		-- son d'origine absent de la banque : il reste choisissable (il est déjà dans le véhicule)
		local n = string.match(default, "_(%d+)$")
		table.insert(list, { Name = default, Label = n and (category .. " " .. tonumber(n)) or default })
	end
	table.sort(list, function(x, y)
		return x.Name < y.Name
	end)
	local current = model:GetAttribute("EngineSound")
	return { Category = category, Default = default, Current = type(current) == "string" and current or default, List = list }
end

-- Met le son `name` (de la catégorie du véhicule) ; nil ou le son d'origine = retour à l'origine.
function Custom.SetEngineSound(model, name)
	local info = Custom.EngineSounds(model)
	if name == nil or (info and name == info.Default) then
		model:SetAttribute("EngineSound", nil)
		return true
	end
	if not info then
		return false, "absent"
	end
	for _, item in ipairs(info.List) do
		if item.Name == name then
			model:SetAttribute("EngineSound", name)
			return true
		end
	end
	return false, "other_category"
end

-- ------------------------------------------------------------------ options & sauvegarde
function Custom.GetOptions(model)
	local cfg = getConfig(model)
	local mods = {}
	for slot, info in pairs(cfg.Mods or {}) do
		local labels = {}
		for i, opt in ipairs(info.Options) do
			labels[i] = opt.Label
		end
		mods[slot] = { Label = info.Label, Options = labels }
	end
	local store = model:FindFirstChild("Liveries")
	return {
		Mods = mods,
		Liveries = cfg.LiveryNames or {},
		LiveryCount = store and #store:GetChildren() or 0,
		Extras = cfg.Extras or {},
		PaintLayers = PAINT_LAYERS,
		LayersPresent = Custom.LayersPresent(model),
		FactoryColors = #((cfg.Colors or {}).Variations or {}),
		Performance = Custom.PerformanceSlots(model),
		StatMods = cfg.StatMods or {},
		EngineSounds = Custom.EngineSounds(model),
	}
end

local SAVE_PREFIXES = { "Mod_", "Color_", "Paint_", "Finish_", "Extra_", "Perf_", "WindowDown_", "Neon_", "Tune_" }
-- PlateStyleChosen : style choisi par le joueur (SetPlateStyle) -> sauvegardé avec lui, pas de tirage au sort à la
-- réapparition (VehiclePlates.UseStyles avec Random). Le serveur réapplique la config propre de chaque véhicule à
-- son apparition : un style présent dans la sauvegarde ne veut donc PAS dire « choisi ».
local SAVE_KEYS = {
	"Livery", "WindowTint", "WindowTintStock", "TintPreset", "Neon", "NeonColor", "XenonColor", "TyreSmokeColor",
	"PlateText", "PlateStyle", "PlateStyleChosen", "EngineSound", "PaintFade",
}

-- Clé gardée dans une sauvegarde / acceptée à la restauration. Vitres : seulement les vraies vitres du modèle (une
-- clé WindowDown_<n'importe quoi> pouvait venir d'un client avant le 2026-11-16).
local function savable(model, k, windows)
	if table.find(SAVE_KEYS, k) ~= nil then
		return true
	end
	if string.sub(k, 1, 11) == "WindowDown_" then
		return windows[string.sub(k, 12)] == true
	end
	for _, p in ipairs(SAVE_PREFIXES) do
		if string.sub(k, 1, #p) == p then
			return true
		end
	end
	return false
end
local function windowSet(model)
	local set = {}
	for _, w in ipairs(Custom.WindowBones(model)) do
		set[w] = true
	end
	return set
end

function Custom.Serialize(model)
	local out = {}
	local windows = windowSet(model)
	for k, v in pairs(model:GetAttributes()) do
		local keep = savable(model, k, windows)
		if keep then
			if typeof(v) == "Color3" then
				out[k] = { "Color3", v.R, v.G, v.B }
			else
				out[k] = v
			end
		end
	end
	return out
end

-- Clés dont l'absence dans une sauvegarde vaut « état d'origine » : Apply les efface pour que
-- restaurer une sauvegarde annule aussi ce qui a été activé APRÈS elle (néons, xénons, mods,
-- extras, vitres, perfs). Les couleurs, la livrée, la teinte et la plaque absentes sont gardées.
local RESET_PREFIXES = { "Mod_", "Extra_", "Perf_", "WindowDown_", "Neon_", "Tune_" }
local RESET_KEYS = { "Neon", "NeonColor", "XenonColor", "TyreSmokeColor", "PlateStyleChosen", "EngineSound", "PaintFade" }

function Custom.Apply(model, data)
	data = data or {}
	for k in pairs(model:GetAttributes()) do
		if data[k] == nil then
			local reset = table.find(RESET_KEYS, k) ~= nil
			for _, p in ipairs(RESET_PREFIXES) do
				if string.sub(k, 1, #p) == p then
					reset = true
				end
			end
			if reset then
				-- Extra_<n> absent = extra d'origine (visible)
				model:SetAttribute(k, if string.sub(k, 1, 6) == "Extra_" then true else nil)
			end
		end
	end
	local windows = windowSet(model)
	for k, v in pairs(data) do
		if type(k) == "string" and #k <= 64 and savable(model, k, windows) then
			if type(v) == "table" and v[1] == "Color3" then
				v = Color3.new(v[2], v[3], v[4])
			end
			if type(v) ~= "table" then
				model:SetAttribute(k, v)
			end
		end
	end
	for _, layer in ipairs(PAINT_LAYERS) do
		local c = model:GetAttribute("Color_" .. layer)
		if c then
			Custom.SetColor(model, layer, c)
		end
	end
	for _, layer in ipairs(PAINT_LAYERS) do
		local finish = model:GetAttribute("Finish_" .. layer)
		if Custom.FinishLooks[finish] then
			Custom.SetFinish(model, layer, finish)
		end
	end
	Custom.SetLivery(model, model:GetAttribute("Livery") or 0)
	local tint = model:GetAttribute("TintPreset")
	if type(tint) == "number" and Custom.WindowTints[tint] then
		Custom.SetWindowTintPreset(model, tint)
	end
	paintNeons(model)
	Custom.SetPaintFade(model, model:GetAttribute("PaintFade") or 0)
	if model:GetAttribute("PlateText") then
		Custom.SetPlate(model, model:GetAttribute("PlateText"))
	end
	Custom.Refresh(model)
end

-- ------------------------------------------------------------------ état du véhicule (menus admin type vMenu)
-- Ces fonctions agissent sur le véhicule entier (portières arrachées, réparation, réglages de conduite,
-- gel, visibilité, alarme, moteur, phares, verrouillage, occupants). À appeler côté serveur.
local accessModule = nil
local function access()
	if accessModule == nil then
		local folder = script.Parent or game:GetService("ReplicatedStorage"):FindFirstChild("FiveMVehicles")
		local mod = folder and folder:FindFirstChild("VehicleAccess")
		accessModule = mod and require(mod) or false
	end
	return accessModule or nil
end

local function seatsOf(model)
	local out = {}
	local folder = model:FindFirstChild("Seats")
	for _, s in ipairs(folder and folder:GetChildren() or {}) do
		if s:IsA("Seat") or s:IsA("VehicleSeat") then
			table.insert(out, s)
		end
	end
	-- conducteur d'abord, puis par nom (ordre stable pour « changer de siège »)
	table.sort(out, function(a, b)
		if (a.Name == "DriverSeat") ~= (b.Name == "DriverSeat") then
			return a.Name == "DriverSeat"
		end
		return a.Name < b.Name
	end)
	return out
end
Custom.Seats = seatsOf

-- Portière / capot / coffre arraché : ses pièces disparaissent jusqu'à la réparation. keepDebris : une copie
-- de ses pièces tombe au sol et disparaît après DebrisLifetime s (comme dans GTA) ; sinon elle disparaît aussitôt.
Custom.DebrisLifetime = 30
function Custom.RemoveDoor(model, bone, keepDebris)
	local cfg = getConfig(model)
	assert(cfg.Hinges and cfg.Hinges[bone], "Charnière inconnue : " .. tostring(bone))
	if model:GetAttribute("DoorRemoved_" .. bone) == true then
		return false
	end
	if keepDebris then
		local pieces = {}
		for _, part in ipairs(visualParts(model)) do
			if part.Transparency < 1 and boneChainHas(part, { [bone] = true }) then
				table.insert(pieces, part)
			end
		end
		if #pieces > 0 then
			local debris = Instance.new("Model")
			debris.Name = model.Name .. "_" .. bone .. "_debris"
			local first
			for _, part in ipairs(pieces) do
				local copy = part:Clone()
				for _, d in ipairs(copy:GetChildren()) do
					if d:IsA("JointInstance") or d:IsA("Constraint") or d:IsA("Attachment") or d:IsA("Light") then
						d:Destroy()
					end
				end
				copy.Anchored = false
				copy.Massless = false
				copy.CanCollide = false
				copy.CanQuery = false
				copy.CanTouch = false
				copy:SetAttribute("F2RPart", nil)
				copy.Parent = debris
				if first then
					local w = Instance.new("WeldConstraint")
					w.Part0, w.Part1, w.Parent = first, copy, copy
				else
					first = copy
					copy.CanCollide = true -- une seule pièce touche le sol (assez pour tomber et rouler)
				end
			end
			debris.PrimaryPart = first
			debris.Parent = workspace
			game:GetService("Debris"):AddItem(debris, Custom.DebrisLifetime)
		end
	end
	model:SetAttribute("DoorRemoved_" .. bone, true)
	model:SetAttribute("Door_" .. bone, 0)
	Custom.Refresh(model)
	return true
end

-- Réparation (GTA) : portières remises, vitres réparées et remontées, véhicule remis sur ses roues s'il est
-- retourné. Ne touche ni à la custom ni aux réglages.
function Custom.Repair(model)
	for k in pairs(model:GetAttributes()) do
		if string.sub(k, 1, 12) == "DoorRemoved_" or string.sub(k, 1, 13) == "WindowBroken_" then
			model:SetAttribute(k, nil)
		elseif string.sub(k, 1, 11) == "WindowDown_" then
			model:SetAttribute(k, false)
		end
	end
	local A = access()
	if A and A.IsUpsideDown(model) and model.PrimaryPart then
		local root = model.PrimaryPart
		A.PlaceOnGround(model, root.Position, root.CFrame.LookVector)
		model:SetAttribute("Flipped", false)
	end
	Custom.Refresh(model)
end

-- Remet le véhicule droit sur ses roues, là où il est (sans attente ni condition, contrairement à
-- Access.Recover qui sert au joueur).
function Custom.Flip(model)
	local A = access()
	local root = model.PrimaryPart
	if not A or not root then
		return false
	end
	local look = root.CFrame.LookVector
	if math.abs(look.Y) > 0.95 then
		look = -root.CFrame.UpVector
	end
	A.PlaceOnGround(model, root.Position, look)
	model:SetAttribute("Flipped", false)
	return true
end

-- Réglages de conduite façon menu admin (VehicleDynamics.SetTune, appliqués en direct par VehicleDrive) :
--   PowerMult / TorqueMult  multiplicateur de puissance / de couple (1 = d'origine ; leur produit est plafonné
--                           à Dyn.Tuning.MaxForceMult pour que la physique tienne)
--   SpeedLimitKmh           limiteur de vitesse réglé par le joueur (0 ou nil = aucun)
--   DriftTyres              pneus de drift : adhérence réduite
Custom.TuneKeys = { PowerMult = "number", TorqueMult = "number", SpeedLimitKmh = "number", DriftTyres = "boolean" }
function Custom.SetTune(model, key, value)
	local t = Custom.TuneKeys[key]
	assert(t, "Réglage inconnu : " .. tostring(key))
	if value ~= nil then
		assert(type(value) == t, "Réglage " .. key .. " : " .. t .. " attendu")
	end
	if key == "PowerMult" or key == "TorqueMult" then
		value = value and math.clamp(value, 1, 1024) or nil
		if value == 1 then
			value = nil
		end
	elseif key == "SpeedLimitKmh" then
		value = (value and value > 0) and math.clamp(value, 5, 600) or nil
	elseif key == "DriftTyres" then
		value = value == true or nil
	end
	model:SetAttribute("Tune_" .. key, value)
end

-- Gel : VehicleRoot ancré, même avec un conducteur (VehicleAccess respecte l'attribut Frozen).
function Custom.SetFrozen(model, frozen)
	local root = model.PrimaryPart
	model:SetAttribute("Frozen", frozen == true or nil)
	if not root then
		return
	end
	if frozen then
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		root.Anchored = true
	else
		local seat = model:FindFirstChild("DriverSeat", true)
		local driven = seat and seat:IsA("Seat") and seat.Occupant ~= nil
		if driven then
			root.Anchored = false
			model:SetAttribute("Parked", false)
		else
			model:SetAttribute("Parked", true) -- reste posé, comme un véhicule garé, jusqu'au prochain conducteur
		end
	end
end

-- Véhicule invisible (pièces, décalques, plaques, néons ; les feux sont éteints par le runtime client).
function Custom.SetVisible(model, visible)
	model:SetAttribute("Invisible", (not visible) or nil)
	Custom.Refresh(model)
end

-- Alarme : feux de détresse et klaxon intermittent pendant AlarmDuration s (runtime client, attribut AlarmUntil).
Custom.AlarmDuration = 30
function Custom.SetAlarm(model, on)
	model:SetAttribute("AlarmUntil", on and (workspace:GetServerTimeNow() + Custom.AlarmDuration) or nil)
end

function Custom.AlarmActive(model)
	local t = model:GetAttribute("AlarmUntil")
	return type(t) == "number" and workspace:GetServerTimeNow() < t
end

-- Moteur toujours allumé : le serveur le rallume s'il est coupé (FiveMVehiclesServer).
function Custom.SetEngineAlwaysOn(model, on)
	model:SetAttribute("EngineAlwaysOn", on == true or nil)
	if on then
		model:SetAttribute("Engine", true)
	end
end

-- Feux (vMenu, véhicule personnel) : "Auto" = selon l'heure (Lighting.ClockTime, allumés de 19 h à 7 h),
-- "Off" = éteints, "On" = croisement.
function Custom.SetLights(model, mode)
	if mode == "Off" then
		model:SetAttribute("Headlights", 0)
	elseif mode == "On" then
		model:SetAttribute("Headlights", 1)
	elseif mode == "Auto" then
		local h = game:GetService("Lighting").ClockTime
		model:SetAttribute("Headlights", (h >= 19 or h < 7) and 1 or 0)
	else
		error("Mode de feux inconnu : " .. tostring(mode))
	end
	model:SetAttribute("LightsMode", mode)
end

-- Air de klaxon (vMenu « Jouer un air de klaxon ») : durées en s, klaxon / silence alternés.
Custom.HornTune = { 0.18, 0.12, 0.18, 0.12, 0.18, 0.3, 0.5, 0.3, 0.18, 0.12, 0.5 }
local hornPlaying = setmetatable({}, { __mode = "k" })
function Custom.PlayHornTune(model)
	if hornPlaying[model] then
		return false
	end
	hornPlaying[model] = true
	task.spawn(function()
		for i, d in ipairs(Custom.HornTune) do
			if not model.Parent then
				break
			end
			model:SetAttribute("Horn", i % 2 == 1)
			task.wait(d)
		end
		if model.Parent then
			model:SetAttribute("Horn", false)
		end
		hornPlaying[model] = nil
	end)
	return true
end

-- Fait descendre tous les occupants (posés dehors comme avec F).
function Custom.KickOccupants(model)
	local A = access()
	local n = 0
	for _, seat in ipairs(seatsOf(model)) do
		local hum = seat.Occupant
		if hum and hum.Parent then
			n += 1
			if A then
				task.spawn(A.EjectOccupant, model, seat, hum, hum.Parent)
			else
				hum.Sit = false
			end
		end
	end
	return n
end

-- Passe le joueur au siège libre suivant de ce véhicule (vMenu « Changer de siège »).
function Custom.CycleSeat(player, model)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum or not hum.SeatPart or not hum.SeatPart:IsDescendantOf(model) then
		return false, "not_seated"
	end
	local seats = seatsOf(model)
	local current = table.find(seats, hum.SeatPart) or 0
	for step = 1, #seats - 1 do
		local seat = seats[(current - 1 + step) % #seats + 1]
		if seat.Occupant == nil then
			local weld = hum.SeatPart:FindFirstChild("SeatWeld")
			if weld then
				weld:Destroy()
			end
			seat:Sit(hum)
			return true, seat.Name
		end
	end
	return false, "no_free_seat"
end

-- ------------------------------------------------------------------ remote « Custom » : opérations acceptées
local function validLayer(layer)
	return type(layer) == "string" and table.find(PAINT_LAYERS, layer) ~= nil
end

local function validIndex(n)
	return type(n) == "number" and n == n and n % 1 == 0 and paints().Get(n) ~= nil
end

local function finite(x)
	return type(x) == "number" and x == x and x > -math.huge and x < math.huge
end

local function integer(x)
	return finite(x) and x % 1 == 0
end

local function validColor(c)
	return typeof(c) == "Color3" and finite(c.R) and finite(c.G) and finite(c.B)
end

local function clampColor(c)
	return Color3.new(math.clamp(c.R, 0, 1), math.clamp(c.G, 0, 1), math.clamp(c.B, 0, 1))
end

local OPS = {}

OPS.Paint = function(model, layer, index, finish)
	if not validLayer(layer) or not validIndex(index) then
		return false, "invalid"
	end
	if finish ~= nil and (type(finish) ~= "string" or Custom.FinishLooks[finish] == nil) then
		return false, "invalid"
	end
	if not Custom.LayersPresent(model)[layer] then
		return false, "absent"
	end
	Custom.SetPaint(model, layer, index, finish)
	return true
end

OPS.Color = function(model, layer, color)
	if not validLayer(layer) or not validColor(color) then
		return false, "invalid"
	end
	if not Custom.LayersPresent(model)[layer] then
		return false, "absent"
	end
	Custom.SetCustomColor(model, layer, clampColor(color))
	return true
end

OPS.Factory = function(model, n)
	local combos = (getConfig(model).Colors or {}).Variations or {}
	if not integer(n) or combos[n] == nil then
		return false, "invalid"
	end
	Custom.SetFactoryColors(model, n)
	return true
end

OPS.Mod = function(model, slot, index)
	local info = type(slot) == "string" and (getConfig(model).Mods or {})[slot]
	if not info or not integer(index) or index < 0 or index > #(info.Options or {}) then
		return false, "invalid"
	end
	Custom.SetMod(model, slot, index)
	return true
end

OPS.Perf = function(model, slot, level)
	if type(slot) ~= "string" or not integer(level) then
		return false, "invalid"
	end
	local ok = Custom.SetPerformance(model, slot, level)
	return ok, (not ok) and "absent" or nil
end

OPS.Livery = function(model, index)
	local store = model:FindFirstChild("Liveries")
	local count = store and #store:GetChildren() or 0
	if not integer(index) or index < 0 or index > count then
		return false, "invalid"
	end
	Custom.SetLivery(model, index)
	return true
end

OPS.Extra = function(model, n, enabled)
	if not integer(n) or type(enabled) ~= "boolean" then
		return false, "invalid"
	end
	local present = (getConfig(model).Extras or {})[n] ~= nil
	if not present then
		for _, part in ipairs(visualParts(model)) do
			if part:GetAttribute("Extra") == n then
				present = true
				break
			end
		end
	end
	if not present then
		return false, "absent"
	end
	Custom.SetExtra(model, n, enabled)
	return true
end

OPS.Tint = function(model, index)
	if not integer(index) or Custom.WindowTints[index] == nil then
		return false, "invalid"
	end
	if #glassParts(model) == 0 then
		return false, "absent"
	end
	Custom.SetWindowTintPreset(model, index)
	return true
end

OPS.Neon = function(model, side, enabled)
	if type(enabled) ~= "boolean" then
		return false, "invalid"
	end
	if side == "All" then
		Custom.SetNeon(model, enabled)
		return true
	end
	if type(side) ~= "string" or not table.find(Custom.NeonSides, side) then
		return false, "invalid"
	end
	if not Custom.NeonSidesPresent(model)[side] then
		return false, "absent"
	end
	Custom.SetNeonSide(model, side, enabled)
	return true
end

OPS.NeonColor = function(model, color)
	if not validColor(color) then
		return false, "invalid"
	end
	Custom.SetNeonColor(model, clampColor(color))
	return true
end

OPS.Xenon = function(model, enabled, color)
	if type(enabled) ~= "boolean" or (color ~= nil and not validColor(color)) then
		return false, "invalid"
	end
	Custom.SetXenon(model, enabled and (color and clampColor(color) or Custom.XenonDefault) or nil)
	return true
end

OPS.TyreSmoke = function(model, enabled, color)
	if type(enabled) ~= "boolean" or (color ~= nil and not validColor(color)) then
		return false, "invalid"
	end
	Custom.SetTyreSmoke(model, enabled and (color and clampColor(color) or Color3.new(1, 1, 1)) or nil)
	return true
end

OPS.Plate = function(model, text, _, _, player)
	if type(text) ~= "string" or #text > 32 then
		return false, "invalid"
	end
	local Plates = getPlates()
	if not Plates then
		return false, "no_plates_module"
	end
	if text == "" then
		return Plates.Assign(model, nil)
	end
	return Plates.RequestCustom(player, model, text)
end

OPS.PlateStyle = function(model, index)
	local Plates = getPlates()
	if not integer(index) or not Plates or Plates.GetStyle(index) == nil then
		return false, "invalid"
	end
	Custom.SetPlateStyle(model, index)
	return true
end

OPS.Window = function(model, bone, down)
	if type(bone) ~= "string" or type(down) ~= "boolean" or not table.find(Custom.WindowBones(model), bone) then
		return false, "absent"
	end
	if model:GetAttribute("WindowBroken_" .. bone) == true then
		return false, "broken"
	end
	Custom.SetWindowDown(model, bone, down)
	return true
end

-- Portière / capot / coffre ouvert ou fermé, sans condition de portée (menu : véhicule personnel à distance).
OPS.Door = function(model, bone, open)
	local hinges = getConfig(model).Hinges or {}
	if type(bone) ~= "string" or hinges[bone] == nil or type(open) ~= "boolean" then
		return false, "absent"
	end
	if model:GetAttribute("DoorRemoved_" .. bone) == true then
		return false, "removed"
	end
	model:SetAttribute("Door_" .. bone, open and 1 or 0)
	return true
end

OPS.SmashWindows = function(model)
	if #Custom.WindowBones(model) == 0 then
		return false, "absent"
	end
	Custom.SmashWindows(model)
	return true
end

OPS.RemoveDoor = function(model, bone, keepDebris)
	local hinges = getConfig(model).Hinges or {}
	if type(bone) ~= "string" or hinges[bone] == nil or type(keepDebris) ~= "boolean" then
		return false, "absent"
	end
	local ok = Custom.RemoveDoor(model, bone, keepDebris)
	return ok, (not ok) and "already" or nil
end

OPS.Repair = function(model)
	Custom.Repair(model)
	return true
end

OPS.Flip = function(model)
	return Custom.Flip(model)
end

OPS.Tune = function(model, key, value)
	local t = type(key) == "string" and Custom.TuneKeys[key]
	if not t or (value ~= nil and type(value) ~= t) or (t == "number" and value ~= nil and not finite(value)) then
		return false, "invalid"
	end
	Custom.SetTune(model, key, value)
	return true
end

OPS.Freeze = function(model, on)
	if type(on) ~= "boolean" then
		return false, "invalid"
	end
	Custom.SetFrozen(model, on)
	return true
end

OPS.Visible = function(model, on)
	if type(on) ~= "boolean" then
		return false, "invalid"
	end
	Custom.SetVisible(model, on)
	return true
end

OPS.Alarm = function(model, on)
	if type(on) ~= "boolean" then
		return false, "invalid"
	end
	Custom.SetAlarm(model, on)
	return true
end

OPS.Engine = function(model, on)
	if type(on) ~= "boolean" then
		return false, "invalid"
	end
	if not on and model:GetAttribute("EngineAlwaysOn") == true then
		return false, "always_on"
	end
	model:SetAttribute("Engine", on)
	return true
end

OPS.EngineAlwaysOn = function(model, on)
	if type(on) ~= "boolean" then
		return false, "invalid"
	end
	Custom.SetEngineAlwaysOn(model, on)
	return true
end

OPS.Lights = function(model, mode)
	if mode ~= "Auto" and mode ~= "Off" and mode ~= "On" then
		return false, "invalid"
	end
	Custom.SetLights(model, mode)
	return true
end

OPS.Lock = function(model, locked)
	if type(locked) ~= "boolean" then
		return false, "invalid"
	end
	local A = access()
	if A then
		A.SetLocked(model, locked)
	else
		model:SetAttribute("Locked", locked)
	end
	return true
end

OPS.KickOut = function(model)
	if Custom.KickOccupants(model) == 0 then
		return false, "empty"
	end
	return true
end

OPS.PaintFade = function(model, amount)
	if not finite(amount) then
		return false, "invalid"
	end
	if next(Custom.LayersPresent(model)) == nil then
		return false, "absent"
	end
	Custom.SetPaintFade(model, amount)
	return true
end

OPS.EngineSound = function(model, name)
	if name ~= nil and (type(name) ~= "string" or #name > 64) then
		return false, "invalid"
	end
	return Custom.SetEngineSound(model, name)
end

OPS.HornTune = function(model)
	if not Custom.PlayHornTune(model) then
		return false, "busy"
	end
	return true
end

OPS.Seat = function(model, _, _, _, player)
	return Custom.CycleSeat(player, model)
end

-- Opérations acceptées par le remote (pour un menu : savoir ce que ce runtime sait faire).
Custom.RemoteOps = {}
for name in pairs(OPS) do
	table.insert(Custom.RemoteOps, name)
end
table.sort(Custom.RemoteOps)

-- Contrôle les arguments (types, bornes, existence sur ce véhicule) puis applique.
-- Renvoie true, détail  ou  false, raison ("invalid", "absent", "filtered"…). player : celui qui demande
-- (nécessaire pour la plaque, filtrée pour lui, et le changement de siège).
function Custom.HandleRemote(model, op, a, b, c, player)
	local fn = type(op) == "string" and OPS[op]
	if not fn then
		return false, "unknown_op"
	end
	return fn(model, a, b, c, player)
end

return Custom
