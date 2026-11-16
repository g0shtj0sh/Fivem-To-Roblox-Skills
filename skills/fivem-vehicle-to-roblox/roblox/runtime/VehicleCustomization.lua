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
		if window and model:GetAttribute("WindowDown_" .. window) == true and part:GetAttribute("Kind") == "glass" then
			visible = false
		end
		local base = part:GetAttribute("BaseTransparency") or 0
		if part:GetAttribute("Kind") == "glass" then
			base = model:GetAttribute("WindowTint") or base
		end
		part.Transparency = visible and base or 1
		part:SetAttribute("Visible", visible)
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

function Custom.SetColor(model, layer, color)
	assert(table.find(PAINT_LAYERS, layer), "Couche de peinture inconnue : " .. tostring(layer))
	model:SetAttribute("Color_" .. layer, color)
	for _, part in ipairs(visualParts(model)) do
		if part:GetAttribute("PaintLayer") == layer then
			applyPaint(part, color)
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
	for _, part in ipairs(visualParts(model)) do
		if part:GetAttribute("PaintLayer") == layer and not part:FindFirstChildOfClass("SurfaceAppearance") then
			part.Material = look.Material
			part.Reflectance = look.Reflectance
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

-- Opérations acceptées et contrôle de leurs arguments (types, bornes, existence sur ce véhicule).
-- Renvoie true si l'opération a été appliquée.
function Custom.HandleRemote(model, op, a, b, c)
	if op == "Paint" then
		-- (layer, index, finish?)
		if not validLayer(a) or not validIndex(b) then
			return false
		end
		if c ~= nil and (type(c) ~= "string" or Custom.FinishLooks[c] == nil) then
			return false
		end
		if not Custom.LayersPresent(model)[a] then
			return false
		end
		Custom.SetPaint(model, a, b, c)
		return true
	elseif op == "Color" then
		-- (layer, Color3) : couleur libre
		if not validLayer(a) or typeof(b) ~= "Color3" then
			return false
		end
		if not (finite(b.R) and finite(b.G) and finite(b.B)) or not Custom.LayersPresent(model)[a] then
			return false
		end
		Custom.SetCustomColor(model, a, Color3.new(math.clamp(b.R, 0, 1), math.clamp(b.G, 0, 1), math.clamp(b.B, 0, 1)))
		return true
	elseif op == "Factory" then
		-- (n) : combinaison d'usine
		local combos = (getConfig(model).Colors or {}).Variations or {}
		if type(a) ~= "number" or a ~= a or a % 1 ~= 0 or combos[a] == nil then
			return false
		end
		Custom.SetFactoryColors(model, a)
		return true
	end
	return false
end

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

-- 0 = vitres claires, 1 = opaques (les teintes GTA vont ~0.35 -> 0.9)
function Custom.SetWindowTint(model, amount)
	amount = math.clamp(amount, 0, 0.95)
	model:SetAttribute("WindowTint", 0.6 - amount * 0.6)
	for _, part in ipairs(visualParts(model)) do
		if part:GetAttribute("Kind") == "glass" then
			part.Color = Color3.new(0.12, 0.13, 0.14):Lerp(Color3.new(0.02, 0.02, 0.02), amount)
		end
	end
	Custom.Refresh(model)
end

-- ------------------------------------------------------------------ néons / xénons / plaque
local function paintNeons(model, enabled, color)
	color = color or Color3.fromRGB(0, 140, 255)
	local folder = model:FindFirstChild("Neons")
	if folder then
		for _, p in ipairs(folder:GetChildren()) do
			if p:IsA("BasePart") then
				p.Color = color
				p.Transparency = enabled and 0 or 1
				local light = p:FindFirstChildOfClass("SurfaceLight") or p:FindFirstChildOfClass("PointLight")
				if light then
					light.Color = color
					light.Enabled = enabled
				end
			end
		end
	end
end

function Custom.SetNeon(model, enabled, color)
	color = color or Color3.fromRGB(0, 140, 255)
	model:SetAttribute("Neon", enabled and true or false)
	model:SetAttribute("NeonColor", color)
	paintNeons(model, enabled, color)
end

function Custom.SetXenon(model, color)
	-- nil = phares halogènes d'origine
	model:SetAttribute("XenonColor", color)
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
	}
end

local SAVE_PREFIXES = { "Mod_", "Color_", "Paint_", "Finish_", "Extra_", "Perf_", "WindowDown_" }
local SAVE_KEYS = { "Livery", "WindowTint", "Neon", "NeonColor", "XenonColor", "PlateText", "PlateStyle" }

function Custom.Serialize(model)
	local out = {}
	for k, v in pairs(model:GetAttributes()) do
		local keep = table.find(SAVE_KEYS, k) ~= nil
		for _, p in ipairs(SAVE_PREFIXES) do
			if string.sub(k, 1, #p) == p then
				keep = true
			end
		end
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
local RESET_PREFIXES = { "Mod_", "Extra_", "Perf_", "WindowDown_" }
local RESET_KEYS = { "Neon", "NeonColor", "XenonColor" }

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
	for k, v in pairs(data) do
		if type(v) == "table" and v[1] == "Color3" then
			v = Color3.new(v[2], v[3], v[4])
		end
		model:SetAttribute(k, v)
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
	paintNeons(model, model:GetAttribute("Neon") == true, model:GetAttribute("NeonColor"))
	if model:GetAttribute("PlateText") then
		Custom.SetPlate(model, model:GetAttribute("PlateText"))
	end
	Custom.Refresh(model)
end

return Custom
