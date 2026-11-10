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

local Custom = {}

local PAINT_LAYERS = { "Primary", "Secondary", "Pearlescent", "Wheel", "InteriorTrim", "Dashboard" }

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
function Custom.SetNeon(model, enabled, color)
	color = color or Color3.fromRGB(0, 140, 255)
	model:SetAttribute("Neon", enabled and true or false)
	model:SetAttribute("NeonColor", color)
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

function Custom.SetXenon(model, color)
	-- nil = phares halogènes d'origine
	model:SetAttribute("XenonColor", color)
end

function Custom.SetPlate(model, text)
	text = string.sub(tostring(text or ""), 1, 8)
	model:SetAttribute("PlateText", text)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("TextLabel") and d.Name == "PlateText" then
			d.Text = text
		end
	end
end

-- ------------------------------------------------------------------ performance (pour ton moteur physique)
-- Les mods de perf (moteur, freins, boîte, suspension, blindage, turbo) ne changent rien
-- visuellement : on stocke juste le niveau ; ton moteur physique lit Custom.GetPerformance().
function Custom.SetPerformance(model, slot, level)
	model:SetAttribute("Perf_" .. slot, level)
end

function Custom.GetPerformance(model)
	local cfg = getConfig(model)
	local out = {}
	for slot, levels in pairs(cfg.StatMods or {}) do
		local lvl = model:GetAttribute("Perf_" .. slot) or 0
		out[slot] = { Level = lvl, Modifier = lvl > 0 and levels[lvl] and levels[lvl].Modifier or 0 }
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
		Performance = cfg.StatMods or {},
	}
end

local SAVE_PREFIXES = { "Mod_", "Color_", "Extra_", "Perf_", "WindowDown_" }
local SAVE_KEYS = { "Livery", "WindowTint", "Neon", "NeonColor", "XenonColor", "PlateText" }

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

function Custom.Apply(model, data)
	for k, v in pairs(data or {}) do
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
	Custom.SetLivery(model, model:GetAttribute("Livery") or 0)
	if model:GetAttribute("Neon") ~= nil then
		Custom.SetNeon(model, model:GetAttribute("Neon"), model:GetAttribute("NeonColor"))
	end
	if model:GetAttribute("PlateText") then
		Custom.SetPlate(model, model:GetAttribute("PlateText"))
	end
	Custom.Refresh(model)
end

return Custom
