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
-- Habitacle = boîte des vitres (pièces Kind=glass) dans le repère du véhicule, rétrécie de CabinInset sur les côtés
-- (l'intérieur des vitres latérales) et descendue de CabinBelow sous leur bas (planche de bord). Renvoie une
-- fonction point (monde) -> booléen, ou nil sans vitres.
-- Vitres teintées : sous cette transparence (teintes Fumé clair et plus foncées ; d'origine 0,45 et Aucune 0,88 au-dessus),
-- le verre passe en SmoothPlastic qui reflète un peu (voir Refresh).
Custom.DarkTintBelow = 0.42
Custom.DarkTintReflectance = 0.2
Custom.CabinInset = 0.05 -- m
Custom.CabinBelow = 0.45 -- m
function Custom.CabinBox(model)
	local root = model.PrimaryPart
	if not root then
		return nil
	end
	local spm = getConfig(model).StudsPerMeter or 3.571
	local mn, mx
	for _, part in ipairs(visualParts(model)) do
		if part:GetAttribute("Kind") == "glass" and part:GetAttribute("Window") then
			local cf = root.CFrame:ToObjectSpace(part.CFrame)
			local h = part.Size / 2
			for _, sx in ipairs({ -1, 1 }) do
				for _, sy in ipairs({ -1, 1 }) do
					for _, sz in ipairs({ -1, 1 }) do
						local c = cf:PointToWorldSpace(Vector3.new(sx * h.X, sy * h.Y, sz * h.Z)) / spm
						mn = mn and mn:Min(c) or c
						mx = mx and mx:Max(c) or c
					end
				end
			end
		end
	end
	if not mn then
		return nil
	end
	local inset, below = Custom.CabinInset, Custom.CabinBelow
	return function(worldPos)
		local l = root.CFrame:PointToObjectSpace(worldPos) / spm
		return l.X > mn.X + inset and l.X < mx.X - inset and l.Z > mn.Z and l.Z < mx.Z and l.Y > mn.Y - below and l.Y < mx.Y
	end
end

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
	-- portières / capot / coffre arrachés (Custom.RemoveDoor) : leurs pièces disparaissent, PIÈCES DE CUSTOM COMPRISES.
	-- Avant le 2026-11-19, une pièce de custom (ModSlot) ne regardait que la custom choisie : un capot de custom arraché
	-- tombait (copie) mais restait affiché sur la voiture (signalé par l'utilisateur). Ensemble séparé de `hidden`
	-- (os masqués par les customs) : un mod qui masque l'os d'origine « bonnet » ne doit pas se masquer lui-même.
	local removed = {}
	for bone in pairs(cfg.Hinges or {}) do
		if model:GetAttribute("DoorRemoved_" .. bone) == true then
			hidden[bone] = true
			removed[bone] = true
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
	local cabin = Custom.CabinBox(model)
	for _, part in ipairs(visualParts(model)) do
		local visible = true
		local slot = part:GetAttribute("ModSlot")
		if slot then
			visible = (model:GetAttribute("Mod_" .. slot) or 0) == part:GetAttribute("ModIndex")
			if visible and boneChainHas(part, removed) then
				visible = false
			end
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
		if part:GetAttribute("Kind") == "glass" and not part:GetAttribute("Window") then
			-- capot transparent des feux : jamais teinté. Option du véhicule PlainLightCovers : masqué, les optiques
			-- se voient en 3D unie (la conversion lui a posé la texture des vitres, sérigraphie à points de GTA :
			-- feux arrière « texturés » sur la 325e, demande de l'utilisateur 2026-11-19).
			if model:GetAttribute("PlainLightCovers") == true then
				visible = false
			end
		end
		if part:GetAttribute("Kind") == "glass" then
			if part:GetAttribute("Window") then
				base = model:GetAttribute("WindowTint") or base
			end
			-- texture des vitres (GlassTexture) : en AlphaMode Transparency, l'alpha de la texture décide seul et
			-- Part.Transparency / Part.Color sont ignorés -> toutes les teintes rendaient pareil (mesuré, 2026-11-18).
			-- Overlay : la texture se pose sur Part.Color et la transparence de la pièce s'applique. Corrige aussi
			-- les véhicules installés avant ce correctif.
			local gsa = part:FindFirstChildOfClass("SurfaceAppearance")
			if gsa and gsa.AlphaMode ~= Enum.AlphaMode.Overlay then
				gsa.AlphaMode = Enum.AlphaMode.Overlay
			end
			-- teinte FONCÉE : le matériau Glass de Roblox laisse voir l'habitacle même presque opaque (325e en Noir
			-- intégral, transparence 0,044 : sièges nets à travers la lunette, capture 2026-11-19) -> SmoothPlastic
			-- reflétant, vraiment sombre. Verre d'origine et « Aucune » restent en Glass (reflets de vrai verre).
			-- Vu de l'intérieur, le joueur voit dehors (VehicleRuntime, vitre sans tain en vue intérieure).
			if part:GetAttribute("Window") then
				if part:GetAttribute("GlassMaterial") == nil then
					part:SetAttribute("GlassMaterial", part.Material.Name)
					part:SetAttribute("GlassReflectance", part.Reflectance)
				end
				local dark = base < Custom.DarkTintBelow
				part.Material = dark and Enum.Material.SmoothPlastic or (Enum.Material[part:GetAttribute("GlassMaterial")] or Enum.Material.Glass)
				part.Reflectance = dark and Custom.DarkTintReflectance or (part:GetAttribute("GlassReflectance") or 0)
				part:SetAttribute("DarkTint", dark)
			end
		elseif base > 0 and part:GetAttribute("Kind") == "light" and cabin and cabin(part.Position) then
			-- optique DANS l'habitacle (voyants du tableau de bord, plafonnier du mod…) : opaque. Transparente (0,15),
			-- Roblox la triait avec les vitres et la dessinait parfois DEVANT une vitre teintée : on la voyait à
			-- travers le noir intégral (signalé par l'utilisateur, 2026-11-19, 325e). Les feux extérieurs gardent 0,15.
			base = 0
		end
		part.Transparency = visible and base or 1
		part:SetAttribute("Visible", visible)
	end
	-- décalques, textures et écrans (plaque) posés sur une pièce masquée (coffre arraché…) : masqués avec elle
	-- (signalé par l'utilisateur, 2026-11-16 : la plaque restait en l'air quand le coffre était parti)
	for _, d in ipairs(model:GetDescendants()) do
		-- hôte = la pièce visuelle la plus proche (la plaque est une SurfaceGui sur « PlateSurfaceRear », pièce
		-- invisible posée DANS boot__licenseplate : c'est la visibilité de cette dernière qui compte)
		local host = d.Parent
		while host and host:IsA("BasePart") and host:GetAttribute("Visible") == nil and host.Parent and host.Parent:IsA("BasePart") do
			host = host.Parent
		end
		if not invisible and host and host:IsA("BasePart") and (d:IsA("Decal") or d:IsA("SurfaceGui")) then
			local hide = host:GetAttribute("Visible") == false
			if d:IsA("Decal") then
				if hide then
					if d:GetAttribute("BaseTransparency") == nil then
						d:SetAttribute("BaseTransparency", d.Transparency)
					end
					d.Transparency = 1
				elseif d:GetAttribute("BaseTransparency") ~= nil then
					d.Transparency = d:GetAttribute("BaseTransparency")
				end
			elseif hide then
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
Custom.PaintFadeLook = { Saturation = 0.45, Lighten = 0.25, Chalk = 0.78, Reflectance = 0.85 } -- 0.65 / 0.35 essayés : rouge 100 % passé = rose pastel, trop fort (observé, 2026-11-16)

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

-- vitres (pièces de verre portées par un os de vitre) : les seules que la teinte touche. Les autres pièces de verre sont
-- les capots transparents des feux (325e : chassis__vehglass couvre les phares et les feux arrière) ; teintés avant le
-- 2026-11-19, ils assombrissaient les optiques.
local function glassParts(model)
	local out = {}
	for _, part in ipairs(visualParts(model)) do
		if part:GetAttribute("Kind") == "glass" and part:GetAttribute("Window") then
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
-- Transparence = ClearTransparency x (1 - amount). 0.6 avant le 2026-11-18 : « Aucune », « Fumé clair » et
-- « D'origine » (0.45) se confondaient ; 0.88 = verre clair qui garde son reflet (observé en Play, BavrenN4).
Custom.ClearGlassTransparency = 0.88
function Custom.SetWindowTint(model, amount, color)
	keepStockTint(model)
	amount = math.clamp(amount, 0, 0.95)
	model:SetAttribute("WindowTint", Custom.ClearGlassTransparency * (1 - amount))
	local base = color or Color3.new(0.12, 0.13, 0.14)
	for _, part in ipairs(glassParts(model)) do
		part.Color = base:Lerp(Color3.new(0.02, 0.02, 0.02), amount * (color and 0.4 or 1))
	end
	Custom.Refresh(model)
end

-- Teintes de vitres de GTA, dans l'ordre des menus (vMenu : D'origine, Aucune, Limousine, Fumé clair,
-- Fumé foncé, Noir intégral, Vert). Amount : opacité 0..0,95 de SetWindowTint.
-- Ordre de GTA : Aucune < D'origine (0.45) < Fumé clair < Fumé foncé < Limousine < Noir intégral. Le matériau Glass
-- éclaircit beaucoup : Fumé clair 0.35 / foncé 0.6 / Limo 0.8 se confondaient avec Aucune (observé, 2026-11-18).
Custom.WindowTints = {
	{ Name = "Stock", Label = "D'origine" },
	{ Name = "None", Label = "Aucune", Amount = 0 },
	{ Name = "Limo", Label = "Limousine", Amount = 0.85 },
	{ Name = "LightSmoke", Label = "Fumé clair", Amount = 0.55 },
	{ Name = "DarkSmoke", Label = "Fumé foncé", Amount = 0.72 },
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
	local root = model.PrimaryPart or model:FindFirstChild("VehicleRoot")
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

-- NÉONS FAÇON GTA V (2026-11-18, demandes de l'utilisateur : « comme dans GTA 5 et adapté à chaque véhicule »,
-- puis « les néons de véhicules, c'est des VRAIES lumières […] tes parts de néon en invisible et leur lueur »).
-- RÈGLE : un néon = des tubes (Parts) INVISIBLES calés sous la caisse + de VRAIES lumières Roblox (une SurfaceLight vers le sol par tube, sans ombres, v9)
-- tournées vers le sol. JAMAIS d'image, de SurfaceGui ou d'« UI » pour dessiner la nappe (essayé le 2026-11-18 :
-- rejeté, « ce n'est pas une UI »). Méthode :
--   · position de chaque tube MESURÉE sur le véhicule (rayons tirés du dessous contre ses pièces de collision) ;
--   · DEUX SurfaceLight par tube, comme une source linéaire qui éclaire tout autour d'elle : une vers le bas et
--     l'extérieur (face Bottom du tube incliné), une vers le bas et l'intérieur, SOUS la voiture (face latérale
--     intérieure) — demande du 2026-11-18 : « les néons devraient pointer vers le sol et faire une zone plus large
--     […] là c'est trop sur les bords ». Angle 150, sans ombres.
--   · Essais (Play Studio, m422, nuit, caméra posée 2,5 s) : une seule lumière inclinée vers l'extérieur → nappe
--     seulement au bord, rien sous la voiture ; une seule lumière droite vers le bas (angle 170–175) → trop rasante,
--     nappe collée à la caisse ou cachée dessous ; Angle 120 → rectangles à bords nets ; PointLight sous la caisse →
--     carrosserie et habitacle teintés.
--   · Juger une lumière caméra POSÉE depuis ~2 s : juste après un déplacement de caméra, le rendu des petites lumières
--     n'est pas encore à jour (captures « frame » trompeuses).
--   · v7 (2026-11-18, retour « la lumière n'est pas diffusée de manière assez homogène », références : photos de kits
--     LED réels + captures GTA Online) : la référence est une BANDE CONTINUE au sol le long du bas de caisse, la plus
--     forte au ras de la caisse, qui s'estompe doucement sur ~0,5–1 m, sans bord net, dessous éclairé, roues sombres.
--     Les SurfaceLight donnaient des rectangles aux bords durs et des taches séparées. Remplacées par une CHAÎNE de
--     PointLight à ombres par tube (une tous les LightSpacing m), rentrée sous la caisse : leurs disques se recouvrent
--     en un dégradé régulier. Ombres OBLIGATOIRES : sans elles jantes, passages de roue et habitacle se teintent
--     (essayé, Play PC, BavrenN4). Tubes avant / arrière raccourcis et peu rentrés : rentrés vers l'essieu, ils
--     éclairaient l'intérieur des jantes avant. Juger la voiture POSÉE sur ses roues : un prototype qui flottait de
--     0,2 m (lumières plus hautes) donnait une nappe plus large et plus claire. Réglage final : 0,4 m d'écart
--     (16 lumières sur BavrenN4), luminosité 7.
--   · v8 (2026-11-19, retour « un peu moins de portée […] le même type de lumière que les phares, là ça clignote,
--     je veux du réalisme et que ce soit propre », vidéo de l'utilisateur en roulant) : la v7 (15 PointLight À OMBRES
--     par voiture) faisait de grands blocs de lumière qui sautaient d'une image à l'autre en roulant — rendu de
--     secours « en grille » de Roblox (cellules de ~4 studs) quand il y a trop de lumières locales / d'ombres à
--     calculer ou quand la qualité graphique baisse. HYPOTHÈSE (non reproduite chez l'agent, qualité 10 fixe) :
--     dépassement du budget de lumières détaillées. Correctif : comme les phares, des SpotLight SANS ombres, et
--     peu nombreuses : 3 par côté + 1 devant + 1 derrière = 8. Chacune regarde droit vers le bas avec Angle 180
--     (une demi-sphère) : elle ne peut pas éclairer la caisse au-dessus d'elle, donc plus besoin d'ombres. Portées
--     1,25 m (côtés) / 1,1 m (bouts) : nappe serrée sous la voiture, ~0,8 m de débord.
--   · v9 (2026-11-19, capture de l'utilisateur, de jour, vue de côté basse : « ça fait pas néon du tout, les lumières
--     ne sont pas là où elles sont censées être, c'est juste des points ») : les 8 SpotLight de la v8, rentrées de
--     0,3 m sous la caisse, faisaient chacune une petite tache cachée sous la voiture ; de jour on ne voyait que des
--     points. Un néon est une source EN LIGNE : UNE SurfaceLight par tube, sur la face du dessous d'un tube À PLAT
--     posé AU BORD du bas de caisse (plus rentré), Angle 180 (demi-espace vers le bas : la caisse au-dessus ne peut
--     pas être éclairée, pas d'ombres), tube latéral prolongé de 0,15 m à chaque bout. 4 lumières par voiture, sans
--     ombres. Vérifié (Play PC) de jour sous l'angle de l'utilisateur et de nuit : bande continue au ras du bas de
--     caisse. Les rectangles durs de la v3–v6 venaient des Angle 120–150 sur des tubes inclinés.
--   · v10 (2026-11-19, « ça n'épouse pas bien les côtés du véhicule, surtout l'avant et l'arrière ») : le tube
--     avant / arrière était un segment droit entre les roues → tache ronde au milieu du bouclier. Il devient
--     EndSegments segments à plat qui suivent le bord du bouclier mesuré par rayons (bord le plus extérieur à
--     chaque abscisse, rentré de EndInset), d'un coin à l'autre (EndSpan × demi-largeur). Une SurfaceLight par
--     segment.
Custom.NeonLayoutVersion = 21
Custom.Neon = {
	Tube = 0.035, -- m : épaisseur du tube (invisible)
	SideInset = 0, -- m : tube au bord du bas de caisse (v9 ; 0,18 en v6–v8 : lumière cachée sous la voiture)
	EndInset = 0.09, -- m : rentré sous le bouclier depuis son bord
	ArchGap = 1.08, -- × rayon de roue : zone de mesure du bas de caisse, entre les arches
	SideFraction = 0.82, -- part de cette zone sondée
	SideReach = -1.33, -- × rayon de roue au-delà des axes (négatif : le tube s'arrête entre les arches)
	EndSegments = 4, -- v10 : segments avant / arrière qui suivent le contour du bouclier
	EndSpan = 0.92, -- part de la demi-largeur du bouclier couverte (jusqu'aux coins)
	SideTilt = 0, -- ° : tube à plat (v9 : la face du dessous regarde droit vers le sol)
	EndTilt = 0,
	SideExtend = 0.15, -- m ajoutés à chaque bout du tube latéral
	Angle = 180, -- SurfaceLight : demi-espace sous le tube
	SideRange = 1.5, -- m
	EndRange = 1.45, -- m (v10 : segments courts, un peu plus de portée pour égaler les côtés)
	Brightness = 6,
}

local function neonBodyParts(model)
	-- pièces de collision de la caisse (les seules interrogeables par rayon), sans les roues
	local out = {}
	local col = model:FindFirstChild("Collision")
	for _, d in ipairs(col and col:GetDescendants() or {}) do
		if d:IsA("BasePart") and d.CanQuery and not string.find(string.lower(d.Name), "wheel") then
			table.insert(out, d)
		end
	end
	return out
end

-- Calcule et pose les 4 tubes d'après la géométrie du véhicule (serveur, une fois par version de calage).
-- Rend true si le calage est fait (ou déjà fait).
function Custom.LayoutNeons(model)
	local folder = model:FindFirstChild("Neons")
	if not folder then
		return false
	end
	if folder:GetAttribute("Layout") == Custom.NeonLayoutVersion then
		return true
	end
	if not game:GetService("RunService"):IsServer() or not model:IsDescendantOf(workspace) then
		return false
	end
	local root = model:FindFirstChild("VehicleRoot") or model.PrimaryPart
	local cfg = getConfig(model)
	local spm = cfg.StudsPerMeter or 3.571
	local wheels = cfg.Wheels
	if not root or type(wheels) ~= "table" then
		return false
	end
	local N = Custom.Neon
	-- roues (studs, repère du VehicleRoot : X droite, Y haut, −Z avant)
	local frontZ, rearZ, track, radius, width, groundY, axleY = math.huge, -math.huge, 0, 0, 0, math.huge, 0
	local nW = 0
	for _, w in pairs(wheels) do
		if type(w) == "table" and type(w.Position) == "table" then
			local pos = Vector3.new(w.Position[1], w.Position[2], w.Position[3]) * spm
			local r = (w.Radius or 0.33) * spm
			frontZ, rearZ = math.min(frontZ, pos.Z), math.max(rearZ, pos.Z)
			track = math.max(track, math.abs(pos.X))
			radius, width = math.max(radius, r), math.max(width, (w.Width or 0.25) * spm)
			groundY = math.min(groundY, pos.Y - r)
			axleY += pos.Y
			nW += 1
		end
	end
	if nW < 2 or rearZ - frontZ < 1 then
		return false
	end
	axleY /= nW
	local b = cfg.Bounds
	local halfX = b and math.max(math.abs(b.Min[1]), math.abs(b.Max[1])) * spm or track + width
	local minZ = b and b.Min[3] * spm or frontZ - radius * 2
	local maxZ = b and b.Max[3] * spm or rearZ + radius * 2

	local body = neonBodyParts(model)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = body
	local rcf = root.CFrame
	local probeLen = (axleY + radius * 0.5) - (groundY - 1) + 1
	-- hauteur du dessous de caisse en (x, z), nil si rien au-dessus jusqu'à l'axe des roues + ½ rayon
	local function under(x, z)
		if #body == 0 then
			return nil
		end
		local o = rcf:PointToWorldSpace(Vector3.new(x, groundY - 1, z))
		local hit = workspace:Raycast(o, rcf.UpVector * probeLen, params)
		return hit and rcf:PointToObjectSpace(hit.Position).Y or nil
	end
	local lowY = axleY + radius * 0.15 -- un bas de caisse / bouclier : sous l'axe (un peu au-dessus au plus)
	local step = 0.03 * spm

	local tube = N.Tube * spm
	local strips = {}
	-- tubes latéraux : bord du bas de caisse entre les arches de roue
	local zA, zB = frontZ + radius * N.ArchGap, rearZ - radius * N.ArchGap
	local mid, span = (zA + zB) / 2, (zB - zA) * N.SideFraction
	for _, sgn in ipairs({ -1, 1 }) do
		local edge = nil
		for i = 0, 4 do
			local z = mid + (i / 4 - 0.5) * span
			local x = halfX
			local found
			while x > 0.2 * spm do
				local y = under(sgn * x, z)
				if y and y < lowY then
					found = x
					break
				end
				x -= step
			end
			if found then
				edge = edge and math.min(edge, found) or found
			end
		end
		edge = edge or (track - width * 0.5)
		local x = sgn * math.max(edge - N.SideInset * spm, 0.2 * spm)
		local y = math.huge
		for i = 0, 6 do
			local hy = under(x, mid + (i / 6 - 0.5) * span)
			if hy then
				y = math.min(y, hy)
			end
		end
		if y == math.huge then
			y = groundY + 0.18 * spm
		end
		y = math.max(y - tube * 0.6, groundY + 0.04 * spm)
		strips[sgn < 0 and "Left" or "Right"] = { {
			cf = CFrame.new(x, y, (frontZ + rearZ) / 2) * CFrame.Angles(0, 0, math.rad(sgn * N.SideTilt)),
			size = Vector3.new(tube, tube, math.max((rearZ - frontZ) + 2 * radius * N.SideReach, (rearZ - frontZ) * 0.4) + 2 * N.SideExtend * spm),
			isEnd = false,
		} }
	end
	-- tubes avant / arrière (v10) : plusieurs segments qui SUIVENT le contour du bouclier, mesuré par rayons, d'un coin
	-- à l'autre (un tube droit entre les roues laissait une tache ronde au milieu, « ça n'épouse pas l'avant et
	-- l'arrière », 2026-11-19)
	for _, e in ipairs({ { "Front", -1, frontZ, minZ }, { "Back", 1, rearZ, maxZ } }) do
		local name, sgn, axleZ, endZ = e[1], e[2], e[3], e[4]
		local limitZ = math.abs(axleZ) + radius * 1.02 -- jamais dans la roue
		local lowEnd = lowY + radius * 0.3 -- bouclier : son bord peut remonter un peu dans les coins
		-- bord du bouclier (z le plus extérieur) à l'abscisse x
		local function edgeAt(x)
			local z = math.abs(endZ)
			while z > limitZ do
				local y = under(x, sgn * z)
				if y and y < lowEnd then
					return z, y
				end
				z -= step
			end
			return nil
		end
		-- largeur du bouclier : mesurée juste derrière son bord central
		local zc = edgeAt(0) or (math.abs(endZ) - 0.2 * spm)
		local wx = 0
		local x = 0
		while x < halfX do
			local y = under(x, sgn * math.max(zc - N.EndInset * spm, limitZ))
			if y and y < lowEnd then
				wx = x
			end
			x += step * 2
		end
		local span = (wx > 0 and wx or track) * N.EndSpan
		local pts = {}
		local yMin = math.huge
		for i = 0, N.EndSegments do
			local px = -span + 2 * span * i / N.EndSegments
			local ez, ey = edgeAt(px)
			if ez then
				table.insert(pts, Vector3.new(px, 0, sgn * math.max(ez - N.EndInset * spm, limitZ + tube)))
				yMin = math.min(yMin, ey)
			end
		end
		if yMin == math.huge then
			yMin = groundY + 0.2 * spm
		end
		local y = math.max(yMin - tube * 0.6, groundY + 0.04 * spm)
		local segs = {}
		if #pts < 2 then
			pts = { Vector3.new(-span, 0, sgn * (zc - N.EndInset * spm)), Vector3.new(span, 0, sgn * (zc - N.EndInset * spm)) }
		end
		for k = 1, #pts - 1 do
			local a0, a1 = pts[k] + Vector3.new(0, y, 0), pts[k + 1] + Vector3.new(0, y, 0)
			local mid = (a0 + a1) / 2
			table.insert(segs, {
				cf = CFrame.lookAt(mid, a1, Vector3.yAxis), -- à plat, −Z le long du segment
				size = Vector3.new(tube, tube, (a1 - a0).Magnitude),
				isEnd = true,
			})
		end
		strips[name] = segs
	end

	-- pose : on garde les pièces existantes (une par côté), soudure refaite après le déplacement
	local bySide = {}
	for _, p in ipairs(folder:GetChildren()) do
		if p:IsA("BasePart") then
			local side = neonSideOf(model, p)
			if side and not bySide[side] then
				bySide[side] = p
			else
				p:Destroy()
			end
		end
	end
	for i, side in ipairs(Custom.NeonSides) do
		for k, st in ipairs(strips[side] or {}) do
			local p = k == 1 and bySide[side] or nil
			if not p then
				p = Instance.new("Part")
				p.Name = k == 1 and ("Neon" .. i) or ("Neon" .. i .. "_" .. k)
				p.Material = Enum.Material.Neon
				p.CanCollide, p.CanQuery, p.CanTouch, p.Massless = false, false, false, true
				p.Parent = folder
			end
			p:SetAttribute("NeonSide", side)
			for _, c in ipairs(p:GetChildren()) do
				if c:IsA("WeldConstraint") or c:IsA("Light") or (c:IsA("Attachment") and (c.Name == "NeonGlow" or c.Name == "NeonLight")) then
					c:Destroy()
				end
			end
			p.CastShadow = false
			p.Transparency = 1
			p.Size = st.size
			p.CFrame = rcf * st.cf
			-- une SurfaceLight par tube, face du dessous : source en ligne, comme un vrai tube néon (v9)
			local light = Instance.new("SurfaceLight")
			light.Name = "NeonLight"
			light.Face = Enum.NormalId.Bottom
			light.Angle = N.Angle
			light.Range = (st.isEnd and N.EndRange or N.SideRange) * spm
			light.Brightness = N.Brightness
			light.Shadows = false -- demi-espace vers le bas : n'éclaire pas la caisse ; pas d'ombres (coût, v7 : blocs)
			light.Enabled = false
			light.Parent = p
			local w = Instance.new("WeldConstraint")
			w.Part0, w.Part1, w.Parent = root, p, p
		end
	end
	local oldGlow = model:FindFirstChild("NeonGlow") -- nappe dessinée d'un essai rejeté (2026-11-18) : retirée
	if oldGlow then
		oldGlow:Destroy()
	end
	folder:SetAttribute("Layout", Custom.NeonLayoutVersion)
	folder:SetAttribute("LayoutBody", #body) -- 0 = pas de collision interrogeable : calage d'après les roues seules
	return true
end

function Custom.RefreshNeons(model)
	local folder = model:FindFirstChild("Neons")
	if not folder then
		return
	end
	pcall(Custom.LayoutNeons, model)
	local color = model:GetAttribute("NeonColor")
	color = typeof(color) == "Color3" and color or Color3.fromRGB(0, 140, 255)
	local hidden = model:GetAttribute("Invisible") == true
	for _, p in ipairs(folder:GetChildren()) do
		if p:IsA("BasePart") then
			local side = neonSideOf(model, p)
			-- épave (VehicleDamage : véhicule en feu) : plus d'électricité, néons coupés jusqu'à la réparation
			local on = side ~= nil and neonOn(model, side) and not hidden and model:GetAttribute("Wrecked") ~= true
			p.Color = color
			-- tube toujours invisible une fois calé (GTA V : on ne voit pas les barres, on voit leur lumière) ; un
			-- véhicule pas encore calé (hors Workspace) garde l'ancien tube visible
			p.Transparency = (on and folder:GetAttribute("Layout") == nil) and 0 or 1
			p:SetAttribute("NeonLit", on)
			for _, light in ipairs(p:GetDescendants()) do
				if light:IsA("Light") then
					light.Color = color
					light.Enabled = on
				end
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

-- Couleur du plafonnier (lumière intérieure, touche I / portière ouverte) ; nil = blanc chaud d'origine
-- (demande de l'utilisateur, 2026-11-18 : « la lumière intérieure on doit pouvoir la custom aussi »).
function Custom.SetInteriorLightColor(model, color)
	model:SetAttribute("InteriorLightColor", color)
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

-- ------------------------------------------------------------------ klaxon (banque du jeu)
-- Le jeu publie ses klaxons dans ReplicatedStorage.FiveMVehicles.HornBank ({ [nom] = { Label, SoundId } }, gardé par
-- les réinstallations). Choix = attribut HornSound (absent = klaxon d'origine) ; chaque client change le son
-- (VehicleRuntime). Remplace l'emplacement « Klaxon » de GTA (46 noms sans son dans les mods).
local hornBankCache
local function hornBank()
	if hornBankCache == nil then
		local folder = script.Parent or game:GetService("ReplicatedStorage"):FindFirstChild("FiveMVehicles")
		local mod = folder and folder:FindFirstChild("HornBank")
		local ok, bank = pcall(function()
			return mod and require(mod)
		end)
		hornBankCache = (ok and type(bank) == "table" and bank) or false
	end
	return hornBankCache or nil
end
Custom.HornBank = hornBank

-- { Current (nom ou nil = d'origine), List = { {Name, Label} } } ; nil sans banque
function Custom.HornSounds(model)
	local bank = hornBank()
	if not bank then
		return nil
	end
	local list = {}
	for name, entry in pairs(bank) do
		if type(entry) == "table" and type(entry.SoundId) == "string" then
			table.insert(list, { Name = name, Label = entry.Label or name })
		end
	end
	table.sort(list, function(x, y)
		return x.Name < y.Name
	end)
	local current = model:GetAttribute("HornSound")
	return { Current = type(current) == "string" and current or nil, List = list }
end

function Custom.SetHornSound(model, name)
	if name ~= nil then
		local bank = hornBank()
		if not bank or type(bank[name]) ~= "table" then
			return false, "unknown"
		end
	end
	model:SetAttribute("HornSound", name)
	return true
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
	local original = originalEngineSound(cfg)
	-- son PAR DÉFAUT choisi pour ce véhicule (VehicleConfig.Audio.DefaultSound, un son de la banque), sinon son d'origine
	local wanted = (cfg.Audio or {}).DefaultSound
	local default = (type(wanted) == "string" and bank[wanted] and bank[wanted].Loops) and wanted or original
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
	if original and not bank[original] then
		-- son d'origine absent de la banque : il reste choisissable (il est déjà dans le véhicule)
		local n = string.match(original, "_(%d+)$")
		table.insert(list, { Name = original, Label = n and (category .. " " .. tonumber(n)) or original })
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
-- Noms affichés des emplacements de custom (menus du jeu en français, comme le reste du RMenu). Un mod ne donne souvent
-- que des clés de texte GTA (« MNU_EXH1 », la même pour trois échappements) ou le nom de fichier du modèle
-- (« e36_wing_1 ») : illisibles dans un menu (rm3e36, 2026-11-19). Ils deviennent « <emplacement> <n> ».
Custom.ModSlotLabels = {
	Spoiler = "Aileron", FrontBumper = "Pare-chocs avant", RearBumper = "Pare-chocs arrière", SideSkirt = "Bas de caisse",
	Exhaust = "Échappement", Frame = "Arceau", Grille = "Calandre", Hood = "Capot", LeftFender = "Aile gauche",
	RightFender = "Aile droite", Roof = "Toit", FrontWheels = "Jantes", RearWheels = "Jantes arrière",
	PlateHolder = "Support de plaque", VanityPlate = "Plaque de fantaisie", TrimDesign = "Garniture",
	Ornaments = "Ornements", Dashboard = "Tableau de bord", DialDesign = "Cadrans", DoorSpeaker = "Haut-parleurs de portière",
	Seats = "Sièges", SteeringWheel = "Volant", ShiftLever = "Levier de vitesse", Plaque = "Plaque", Speakers = "Sono",
	Trunk = "Coffre", Hydraulics2 = "Hydraulique", EngineBlock = "Bloc moteur", AirFilter = "Filtre à air",
	Struts = "Barres anti-rapprochement", ArchCover = "Passages de roue", Aerials = "Antennes", Trim2 = "Garniture extérieure",
	Tank = "Réservoir", LeftDoor = "Portière gauche", RightDoor = "Portière droite", Livery = "Décoration", Lightbar = "Rampe de lumières",
}

local function readableModLabel(label, slotLabel, index, opt)
	local raw = type(label) == "string" and label or ""
	local code = raw == "" or raw:match("^[%u%d_]+$") ~= nil -- clé de texte GTA (MNU_EXH1, CMOD_…)
		or (type(opt) == "table" and opt.Model ~= nil and string.lower(raw) == string.lower(tostring(opt.Model)))
		or raw:match("^[%l%d]+_[%l%d_]+$") ~= nil -- nom de fichier (e36_wing_1)
	return code and (slotLabel .. " " .. index) or raw
end

function Custom.GetOptions(model)
	local cfg = getConfig(model)
	local mods = {}
	for slot, info in pairs(cfg.Mods or {}) do
		local slotLabel = Custom.ModSlotLabels[slot] or info.Label or slot
		local labels = {}
		for i, opt in ipairs(info.Options) do
			labels[i] = readableModLabel(opt.Label, slotLabel, i, opt)
		end
		mods[slot] = { Label = slotLabel, Options = labels }
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
		HornSounds = Custom.HornSounds(model),
	}
end

local SAVE_PREFIXES = { "Mod_", "Color_", "Paint_", "Finish_", "Extra_", "Perf_", "WindowDown_", "Neon_", "Tune_",
	"LightBroken_" }
-- PlateStyleChosen : style choisi par le joueur (SetPlateStyle) -> sauvegardé avec lui, pas de tirage au sort à la
-- réapparition (VehiclePlates.UseStyles avec Random). Le serveur réapplique la config propre de chaque véhicule à
-- son apparition : un style présent dans la sauvegarde ne veut donc PAS dire « choisi ».
local SAVE_KEYS = {
	"Livery", "WindowTint", "WindowTintStock", "TintPreset", "Neon", "NeonColor", "XenonColor", "InteriorLightColor", "TyreSmokeColor",
	"PlateText", "PlateStyle", "PlateStyleChosen", "EngineSound", "PaintFade", "HornSound", "DirtLevel", "KeepClean",
	"BodyHealth", "EngineHealth", "EngineDead", "Wrecked", "NoDamage",
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
local RESET_PREFIXES = { "Mod_", "Extra_", "Perf_", "WindowDown_", "Neon_", "Tune_", "LightBroken_" }
local RESET_KEYS = { "Neon", "NeonColor", "XenonColor", "InteriorLightColor", "TyreSmokeColor", "PlateStyleChosen", "EngineSound", "PaintFade",
	"HornSound", "DirtLevel", "KeepClean", "BodyHealth", "EngineHealth", "EngineDead", "Wrecked", "NoDamage" }

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
Custom.DebrisLifetime = 60 -- s (demande de l'utilisateur, 2026-11-16 : « tomber puis disparaître 1 min après »)
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
				-- TOUS les descendants : la plaque est une pièce enfant (PlateSurfaceRear) soudée à la pièce d'origine ;
				-- sa soudure clonée garderait la copie accrochée au véhicule
				local nested = {}
				for _, d in ipairs(copy:GetDescendants()) do
					if d:IsA("JointInstance") or d:IsA("WeldConstraint") or d:IsA("Constraint") or d:IsA("Attachment") or d:IsA("Light") then
						d:Destroy()
					elseif d:IsA("BasePart") then
						d.Anchored, d.CanCollide, d.CanQuery, d.CanTouch, d.Massless = false, false, false, false, true
						table.insert(nested, d)
					end
				end
				copy.Anchored = false
				copy.Massless = false
				copy.CanCollide = false
				copy.CanQuery = false
				copy.CanTouch = false
				copy:SetAttribute("F2RPart", nil)
				copy.Parent = debris
				for _, n in ipairs(nested) do
					local w = Instance.new("WeldConstraint")
					w.Part0, w.Part1, w.Parent = copy, n, n
				end
				if first then
					local w = Instance.new("WeldConstraint")
					w.Part0, w.Part1, w.Parent = first, copy, copy
				else
					first = copy
					copy.CanCollide = true -- une seule pièce touche le sol (assez pour tomber et rouler)
				end
			end
			debris.PrimaryPart = first
			-- groupe des débris AVANT d'entrer dans le monde : né dans la coque du véhicule, il ne doit pas la toucher
			local okAccess, Access = pcall(require, script.Parent:WaitForChild("VehicleAccess", 5))
			if okAccess and Access and Access.TagDebris then
				Access.TagDebris(debris)
			end
			debris.Parent = workspace
			-- elle part avec l'élan du véhicule, un peu écartée de la caisse (sinon elle reste « posée » dessus)
			local root = model.PrimaryPart
			if root and first then
				local away = (first.Position - root.Position) * Vector3.new(1, 0, 1)
				away = away.Magnitude > 1e-3 and away.Unit or Vector3.zero
				first.AssemblyLinearVelocity = root.AssemblyLinearVelocity + away * 8 + Vector3.new(0, 6, 0)
				first.AssemblyAngularVelocity = root.AssemblyAngularVelocity
				pcall(function()
					first:SetNetworkOwner(nil)
				end)
			end
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
-- ------------------------------------------------------------------ saleté
-- DirtLevel 0..1 (VehicleRuntime l'affiche : crasse projetée sur la carrosserie). Monte en roulant (serveur, plus vite
-- hors route), sauf KeepClean ; Wash / Repair la remettent à 0 ; le niveau GTA 0..15 du vMenu = DirtLevel × 15.
function Custom.SetDirt(model, level)
	model:SetAttribute("DirtLevel", math.clamp(tonumber(level) or 0, 0, 1))
	return true
end
function Custom.Wash(model)
	return Custom.SetDirt(model, 0)
end

function Custom.Repair(model)
	model:SetAttribute("DirtLevel", 0)
	local dm = script.Parent:FindFirstChild("VehicleDamage")
	local okD, Damage = pcall(function()
		return dm and require(dm)
	end)
	if okD and Damage then
		Damage.Reset(model) -- santé, feux cassés, moteur détruit, épave
	end
	Custom.RefreshNeons(model) -- néons coupés sur une épave : rallumés si demandés
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
--                           à Dyn.Tuning.MaxForceMult pour que la physique tienne ; sous 1 pour une préparation)
--   SpeedLimitKmh           limiteur de vitesse réglé par le joueur (0 ou nil = aucun)
--   DriftTyres / WinterTyres / RaceTyres
--                           pneus (un seul type à la fois) : drift = moins d'adhérence ; hiver = bien meilleur sur
--                           les sols glissants (un peu sur la glace), un peu moins sur sec ; course = bien plus
--                           d'adhérence et une réponse plus vive, moins bons hors route (VehicleDynamics.Tuning)
--   préparation (Custom.PrepKeys) : multiplicateurs des valeurs d'origine ou valeurs imposées, voir Custom.PrepRanges
Custom.TyreKeys = { "DriftTyres", "WinterTyres", "RaceTyres" }
-- { clé, min, max, valeur d'origine (= réglage absent) } ; mêmes bornes que VehicleDynamics.SetUpgrades
Custom.PrepRanges = {
	{ key = "GripMult", min = 0.3, max = 2, origin = 1 }, -- adhérence (× d'origine)
	{ key = "SlideGrip", min = 0.5, max = 1.1, origin = nil }, -- adhérence en glisse / adhérence max (GTA Min/Max)
	{ key = "LateralMult", min = 0.5, max = 2, origin = 1 }, -- angle où l'adhérence latérale culmine (× d'origine)
	{ key = "RearGripMult", min = 0.4, max = 1.6, origin = 1 }, -- adhérence de l'arrière (× d'origine)
	{ key = "SteerLockDeg", min = 15, max = 80, origin = nil }, -- angle de braquage (°)
	{ key = "PowerMult", min = 0.3, max = 16, origin = 1 }, -- force motrice (× d'origine)
	{ key = "TopSpeedMult", min = 0.5, max = 2, origin = 1 }, -- vitesse de pointe (× d'origine)
	{ key = "ShiftMult", min = 0.3, max = 4, origin = 1 }, -- vitesse de passage des rapports (× d'origine)
	{ key = "BrakeMult", min = 0.3, max = 3, origin = 1 }, -- freins (× d'origine)
	{ key = "SuspMult", min = 0.4, max = 2.5, origin = 1 }, -- raideur de suspension et anti-roulis (× d'origine)
	{ key = "LowSpeedLoss", min = 0, max = 3, origin = nil }, -- perte d'adhérence au démarrage (GTA LowSpeedTractionLossMult)
	{ key = "DriveBiasFront", min = 0, max = 1, origin = nil }, -- 0 propulsion, 1 traction, entre = intégrale
}
Custom.PrepKeys = {}
for _, r in ipairs(Custom.PrepRanges) do
	Custom.PrepKeys[r.key] = r
end
Custom.TuneKeys = {
	PowerMult = "number", TorqueMult = "number", SpeedLimitKmh = "number",
	DriftTyres = "boolean", WinterTyres = "boolean", RaceTyres = "boolean",
}
for _, r in ipairs(Custom.PrepRanges) do
	Custom.TuneKeys[r.key] = "number"
end
function Custom.SetTune(model, key, value)
	local t = Custom.TuneKeys[key]
	assert(t, "Réglage inconnu : " .. tostring(key))
	if value ~= nil then
		assert(type(value) == t, "Réglage " .. key .. " : " .. t .. " attendu")
	end
	local range = Custom.PrepKeys[key]
	if key == "TorqueMult" then
		value = value and math.clamp(value, 1, 1024) or nil
		if value == 1 then
			value = nil
		end
	elseif range then
		value = value and math.clamp(value, range.min, range.max) or nil
		if value ~= nil and range.origin ~= nil and math.abs(value - range.origin) < 1e-3 then
			value = nil -- valeur d'origine : réglage retiré
		end
	elseif key == "SpeedLimitKmh" then
		value = (value and value > 0) and math.clamp(value, 5, 600) or nil
	elseif t == "boolean" then
		value = value == true or nil
		if value then
			for _, other in ipairs(Custom.TyreKeys) do
				if other ~= key then
					model:SetAttribute("Tune_" .. other, nil) -- un seul type de pneus monté
				end
			end
		end
	end
	model:SetAttribute("Tune_" .. key, value)
end

-- Préparations fournies (2026-11-19). Drift : à la manière des serveurs de drift de GTA V (handling « drift » :
-- TractionCurveMax/Min bas et rapprochés, braquage 60-65°, propulsion, perte d'adhérence à basse vitesse relevée,
-- puissance en plus) : la voiture décroche au moindre coup de gaz et glisse longtemps. Course : grip, freins,
-- rapports et suspension relevés. Valeurs de départ : à juger au volant et régler.
Custom.PrepPresets = {
	{
		id = "drift",
		name = "Prépa drift",
		values = {
			GripMult = 0.62, SlideGrip = 0.97, LateralMult = 1.35, RearGripMult = 0.8, SteerLockDeg = 65,
			PowerMult = 1.7, ShiftMult = 1.6, SuspMult = 1.3, LowSpeedLoss = 1.4, DriveBiasFront = 0,
		},
	},
	{
		id = "course",
		name = "Prépa course",
		values = {
			GripMult = 1.35, SlideGrip = 0.9, LateralMult = 0.85, RearGripMult = 1.05, PowerMult = 1.35,
			TopSpeedMult = 1.12, ShiftMult = 2.5, BrakeMult = 1.5, SuspMult = 1.5, LowSpeedLoss = 0.5,
		},
	},
}

-- Applique une préparation complète : toutes les clés de préparation absentes de `values` reviennent à l'origine
-- (values = nil : préparation d'origine). `name` (≤ 40 caractères) est affiché par le jeu (attribut PrepName).
function Custom.SetPrep(model, values, name)
	for _, r in ipairs(Custom.PrepRanges) do
		local v = values and values[r.key]
		Custom.SetTune(model, r.key, type(v) == "number" and v or nil)
	end
	model:SetAttribute("PrepName", (values and type(name) == "string" and #name > 0) and string.sub(name, 1, 40) or nil)
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
	if on and model:GetAttribute("EngineDead") ~= true then
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

OPS.InteriorLight = function(model, on)
	if type(on) ~= "boolean" then
		return false, "invalid"
	end
	if model:GetAttribute("Wrecked") == true then
		return false, "wrecked"
	end
	model:SetAttribute("InteriorLight", on)
	return true
end

OPS.InteriorColor = function(model, color)
	if color ~= nil and not validColor(color) then
		return false, "invalid"
	end
	Custom.SetInteriorLightColor(model, color and clampColor(color) or nil)
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

OPS.NoDamage = function(model, on)
	model:SetAttribute("NoDamage", on == true or nil)
	return true
end

OPS.Wash = function(model)
	return Custom.Wash(model)
end

OPS.Dirt = function(model, level)
	if type(level) ~= "number" or level ~= level then
		return false, "invalid"
	end
	return Custom.SetDirt(model, math.clamp(math.floor(level), 0, 15) / 15)
end

OPS.KeepClean = function(model, on)
	model:SetAttribute("KeepClean", on == true or nil)
	if on == true then
		model:SetAttribute("DirtLevel", 0)
	end
	return true
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
	if Custom.PrepKeys[key] then
		model:SetAttribute("PrepName", nil) -- réglage touché à la main : ce n'est plus la préparation nommée
	end
	return true
end

-- Préparation complète d'un coup : values = { clé = nombre } (clés de Custom.PrepKeys seulement), nil = d'origine
OPS.Prep = function(model, values, name)
	if values ~= nil and type(values) ~= "table" then
		return false, "invalid"
	end
	local clean = nil
	if values then
		clean = {}
		local n = 0
		for k, v in pairs(values) do
			n += 1
			if n > 32 or type(k) ~= "string" or not Custom.PrepKeys[k] or type(v) ~= "number" or not finite(v) then
				return false, "invalid"
			end
			clean[k] = v
		end
	end
	if name ~= nil and (type(name) ~= "string" or #name > 40) then
		return false, "invalid"
	end
	Custom.SetPrep(model, clean, name)
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
	if on and model:GetAttribute("EngineDead") == true then
		return false, "engine_dead" -- moteur HS ou véhicule en feu (VehicleDamage) : il faut réparer
	end
	model:SetAttribute("EngineOffByDriver", on == false or nil) -- coupé exprès : pas de redémarrage auto à l'assise
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

OPS.HornSound = function(model, name)
	if name ~= nil and (type(name) ~= "string" or #name > 64) then
		return false, "invalid"
	end
	return Custom.SetHornSound(model, name)
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
