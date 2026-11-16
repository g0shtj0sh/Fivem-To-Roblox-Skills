--!nonstrict
-- FiveMVehicles/VehiclePlates (ModuleScript, ReplicatedStorage)
-- Plaques d'immatriculation façon GTA V :
--   * surfaces posées par le Setup exactement sur chaque plaque (zone de texte du shader GTA
--     `LicensePlateFontExtents`), texte rendu caractère par caractère (8 cases, centré) ;
--   * styles de plaque (fond, couleur du texte, police standard OU planche de caractères) ;
--   * registre serveur : plaques uniques au format GTA (« 46EEK572 »), recherche par plaque,
--     plaques personnalisées filtrées par Roblox, stockage persistant au choix.
--
-- Côté SERVEUR :
--   local Plates = require(ReplicatedStorage.FiveMVehicles.VehiclePlates)
--   Plates.Assign(car)                                  -- plaque unique générée
--   Plates.Assign(car, "AB12CDE", { OwnerUserId = 123 }) -- plaque imposée (code du jeu, non filtrée)
--   local ok, why = Plates.RequestCustom(player, car, "MA CAISSE") -- saisie d'un joueur : filtrée
--       (Plates.FilterText ; Roblox ne filtre rien dans Studio) ; plus de 8 caractères → false, "too_long"
--   local entry = Plates.Lookup("46EEK572")            -- { Model, OwnerUserId, Text } ou nil
--   Plates.SetStyle(car, 2)
--   Plates.RegisterStyle(2, { Name = "Jaune", BackgroundColor = Color3.fromRGB(250, 205, 30),
--       TextColor = Color3.fromRGB(15, 15, 15) })
--   Plates.SetStore(Plates.DataStore("Plates_v1"))       -- plaques des véhicules possédés persistantes
--
-- PLAQUES DU JEU (images) — un jeu remplace les styles du skill par les siens, au démarrage du serveur :
--   Plates.UseStyles({
--       { Name = "Classique", Background = "rbxassetid://…", BackgroundColor = …, TextColor = …,
--         TextRect = { 0.08, 0.36, 0.84, 0.42 }, Weight = 3 },
--       …
--   }, { Random = true })
--   Background = image de TOUTE la plaque (étirée sur la surface, rapport largeur / hauteur ≈ 2:1 comme les
--   plaques GTA) ; TextRect = zone libre de CETTE image où écrire le numéro (fractions x, y, largeur, hauteur de la
--   plaque ; remplace la zone du shader GTA) ; Random = chaque véhicule qui apparaît reçoit un style tiré au sort
--   (pondéré par Weight, stable pour une même plaque) tant qu'aucun style n'a été choisi (SetStyle,
--   Custom.SetPlateStyle ; attribut PlateStyleChosen, gardé par Custom.Serialize / Apply).

local Plates = {}

Plates.Letters = 8 -- maximum GTA
Plates.Format = "##AAA###" -- plaques aléatoires GTA : # chiffre, A lettre, autre caractère = littéral
Plates.Charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 "
Plates.DefaultStyle = 1
Plates.PixelsPerStud = 220

local function defaultFont()
	local ok, f = pcall(function()
		return Font.new(Font.fromEnum(Enum.Font.RobotoMono).Family, Enum.FontWeight.Bold)
	end)
	return ok and f or nil
end

-- Style par défaut : plaque neutre (fond clair, texte bleu foncé, police standard à chasse fixe).
-- Il recouvre la texture d'origine du mod (souvent la plaque « San Andreas » de GTA).
local SKILL_STYLE = {
		Name = "Standard",
		BackgroundColor = Color3.fromRGB(242, 242, 236),
		Background = nil, -- "rbxassetid://..." : image de fond de toute la plaque
		KeepOriginal = false, -- true : laisse visible la texture d'origine du mod (pas de fond dessiné)
		TextColor = Color3.fromRGB(28, 40, 110),
		Font = defaultFont(), -- police Roblox (Font) ; ignorée si Atlas est défini
		Atlas = nil, -- planche de caractères : { Image, Chars, Columns, CellSize = Vector2 }
		LetterFill = 0.92, -- part de la case occupée par le caractère
		TextRect = nil, -- { x, y, w, h } (fractions de la plaque) : zone du texte propre à l'image Background
		Weight = 1, -- poids du tirage au sort (UseStyles avec Random)
}
Plates.Styles = { [1] = table.clone(SKILL_STYLE) }
Plates.RandomStyles = false

function Plates.RegisterStyle(index, def)
	assert(type(index) == "number" and type(def) == "table", "RegisterStyle(index, def)")
	local base = table.clone(Plates.Styles[Plates.DefaultStyle])
	for k, v in pairs(def) do
		base[k] = v
	end
	Plates.Styles[index] = base
	return base
end

function Plates.GetStyle(index)
	return Plates.Styles[index or Plates.DefaultStyle] or Plates.Styles[Plates.DefaultStyle]
end

-- Style tiré au sort pour une plaque (pondéré par Weight, déterministe : même texte -> même style).
function Plates.PickStyle(text)
	local keys, total = {}, 0
	for k, st in pairs(Plates.Styles) do
		if type(k) == "number" and k > 0 and k < 1000 and (st.Weight or 1) > 0 then
			table.insert(keys, k)
			total += st.Weight or 1
		end
	end
	if total <= 0 then
		return Plates.DefaultStyle
	end
	table.sort(keys)
	local h = 7
	for i = 1, #(text or "") do
		h = (h * 31 + string.byte(text, i)) % 2147483647
	end
	local r = (h % 100000) / 100000 * total
	for _, k in ipairs(keys) do
		r -= Plates.Styles[k].Weight or 1
		if r < 0 then
			return k
		end
	end
	return keys[#keys]
end

-- ------------------------------------------------------------------ texte
-- Texte nettoyé (A-Z, 0-9, espaces simples), SANS couper à Plates.Letters.
function Plates.Clean(text)
	text = string.upper(tostring(text or ""))
	text = string.gsub(text, "[^A-Z0-9 ]", "")
	text = string.gsub(text, "^%s+", "")
	text = string.gsub(text, "%s+$", "")
	text = string.gsub(text, "%s+", " ")
	return text
end

-- Texte nettoyé et coupé à Plates.Letters (recherche, plaque imposée par le jeu).
function Plates.Normalize(text)
	return string.sub(Plates.Clean(text), 1, Plates.Letters)
end

function Plates.IsValid(text)
	return type(text) == "string" and #text >= 1 and #text <= Plates.Letters and Plates.Normalize(text) == text
end

local rng = Random.new()
local function randomPlate()
	local out = table.create(#Plates.Format)
	for i = 1, #Plates.Format do
		local c = string.sub(Plates.Format, i, i)
		if c == "#" then
			out[i] = tostring(rng:NextInteger(0, 9))
		elseif c == "A" then
			out[i] = string.char(rng:NextInteger(65, 90))
		else
			out[i] = c
		end
	end
	return table.concat(out)
end

-- ------------------------------------------------------------------ rendu
local function glyph(style, ch, parent, order)
	local fill = style.LetterFill or 0.92
	local cell = Instance.new("Frame")
	cell.Name = "C" .. order
	cell.LayoutOrder = order
	cell.BackgroundTransparency = 1
	cell.Size = UDim2.fromScale(1 / Plates.Letters, 1)
	cell.Parent = parent
	if ch == " " then
		return cell
	end
	local atlas = style.Atlas
	if atlas and atlas.Image then
		local i = string.find(atlas.Chars or "", ch, 1, true)
		if i then
			local cols = atlas.Columns or 10
			local size = atlas.CellSize or Vector2.new(64, 96)
			local img = Instance.new("ImageLabel")
			img.Name = "Glyph"
			img.BackgroundTransparency = 1
			img.Image = atlas.Image
			img.ImageRectSize = size
			img.ImageRectOffset = Vector2.new(((i - 1) % cols) * size.X, math.floor((i - 1) / cols) * size.Y)
			img.ImageColor3 = style.TextColor or Color3.new(0, 0, 0)
			img.ScaleType = Enum.ScaleType.Fit
			img.AnchorPoint = Vector2.new(0.5, 0.5)
			img.Position = UDim2.fromScale(0.5, 0.5)
			img.Size = UDim2.fromScale(fill, fill)
			img.Parent = cell
			return cell
		end
	end
	local label = Instance.new("TextLabel")
	label.Name = "Glyph"
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.fromScale(fill, fill)
	label.TextScaled = true
	if style.Font then
		label.FontFace = style.Font
	else
		label.Font = Enum.Font.RobotoMono
	end
	label.TextColor3 = style.TextColor or Color3.new(0, 0, 0)
	label.Text = ch
	label.Parent = cell
	return cell
end

-- Construit (ou met à jour) le contenu d'une SurfaceGui « Plate ».
function Plates.RenderGui(gui, text, style)
	style = style or Plates.GetStyle()
	gui.LightInfluence = 1
	gui:SetAttribute("Text", text)
	local bg = gui:FindFirstChild("Background")
	if bg then
		local keep = style.KeepOriginal == true or gui:GetAttribute("NoBackground") == true
		bg.BackgroundTransparency = keep and 1 or 0
		bg.BackgroundColor3 = style.BackgroundColor or Color3.new(1, 1, 1)
		bg.Image = (not keep and style.Background) or ""
		bg.ImageTransparency = 0
	end
	local holder = gui:FindFirstChild("PlateText", true)
	if not holder then
		return
	end
	-- zone du texte : celle de l'image du style (TextRect) sinon celle de la plaque (shader GTA), gardée en
	-- attribut ZoneRect à la première fois pour pouvoir y revenir
	if holder.Parent == gui and holder:IsA("Frame") then
		local zone = holder:GetAttribute("ZoneRect")
		if typeof(zone) ~= "Rect" then
			zone = Rect.new(holder.Position.X.Scale, holder.Position.Y.Scale,
				holder.Position.X.Scale + holder.Size.X.Scale, holder.Position.Y.Scale + holder.Size.Y.Scale)
			holder:SetAttribute("ZoneRect", zone)
		end
		local r = style.TextRect
		if r and not (style.KeepOriginal == true or gui:GetAttribute("NoBackground") == true) then
			holder.Position = UDim2.fromScale(r[1], r[2])
			holder.Size = UDim2.fromScale(r[3], r[4])
		else
			holder.Position = UDim2.fromScale(zone.Min.X, zone.Min.Y)
			holder.Size = UDim2.fromScale(zone.Width, zone.Height)
		end
	end
	-- véhicule installé AVANT les plaques à cases : « PlateText » y est un simple TextLabel. On lui donne le
	-- texte tel quel (des cases dessinées dedans se superposaient à l'ancien texte : plaque illisible).
	-- Pour avoir les vraies plaques, refaire le Setup du véhicule avec ce runtime.
	if holder:IsA("TextLabel") then
		for _, c in ipairs(holder:GetChildren()) do
			if c:IsA("GuiObject") or c:IsA("UIListLayout") then
				c:Destroy()
			end
		end
		holder.Text = text
		holder.TextColor3 = style.TextColor or holder.TextColor3
		return
	end
	for _, c in ipairs(holder:GetChildren()) do
		if not c:IsA("UIListLayout") then
			c:Destroy()
		end
	end
	if not holder:FindFirstChildOfClass("UIListLayout") then
		local layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = holder
	end
	for i = 1, math.min(#text, Plates.Letters) do
		glyph(style, string.sub(text, i, i), holder, i)
	end
end

-- Applique PlateText / PlateStyle (attributs du modèle) à toutes ses plaques.
function Plates.Render(model)
	local text = model:GetAttribute("PlateText") or ""
	local style = Plates.GetStyle(model:GetAttribute("PlateStyle"))
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("SurfaceGui") and d.Name == "Plate" then
			Plates.RenderGui(d, text, style)
		end
	end
end

-- Crée la SurfaceGui « Plate » d'une surface : fond (plaque entière) + zone de texte (TextRect, fractions).
function Plates.BuildGui(surface, face, textRect)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Plate"
	gui.Face = face or Enum.NormalId.Back
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = Plates.PixelsPerStud
	gui.LightInfluence = 1
	local bg = Instance.new("ImageLabel")
	bg.Name = "Background"
	bg.Size = UDim2.fromScale(1, 1)
	bg.BorderSizePixel = 0
	bg.ScaleType = Enum.ScaleType.Stretch
	bg.Parent = gui
	local r = textRect or { 0.05, 0.3, 0.9, 0.5 }
	local holder = Instance.new("Frame")
	holder.Name = "PlateText"
	holder.BackgroundTransparency = 1
	holder.Position = UDim2.fromScale(r[1], r[2])
	holder.Size = UDim2.fromScale(r[3], r[4])
	holder.Parent = gui
	gui.Parent = surface
	return gui
end

-- ------------------------------------------------------------------ registre (serveur)
local live = {} -- [TEXT] = { Model, OwnerUserId, Text }
local byModel = {} -- [model] = TEXT
local watched = {} -- [model] = connexion Destroying (libération de la plaque)

-- Stockage persistant (facultatif) : { Reserve(text, info) -> bool, Release(text), Get(text) -> info|nil }.
-- Par défaut : aucun (plaques valables pour la session du serveur seulement).
local store = nil
function Plates.HasStore()
	return store ~= nil
end

function Plates.SetStore(s)
	store = s
end

-- Stockage DataStore prêt à l'emploi : une clé par plaque, réservation atomique (UpdateAsync).
-- À n'utiliser que pour les véhicules possédés (info.OwnerUserId), pour ménager les quotas DataStore.
function Plates.DataStore(name)
	local ds = game:GetService("DataStoreService"):GetDataStore(name or "FiveMVehiclePlates")
	return {
		Reserve = function(text, info)
			local ok, result = pcall(function()
				return ds:UpdateAsync("p_" .. text, function(old)
					if old and old.OwnerUserId ~= info.OwnerUserId then
						return nil -- déjà prise par un autre joueur : pas d'écriture
					end
					return { OwnerUserId = info.OwnerUserId, Vehicle = info.Vehicle, Time = os.time() }
				end)
			end)
			return ok and result ~= nil and result.OwnerUserId == info.OwnerUserId
		end,
		Release = function(text)
			pcall(function()
				ds:RemoveAsync("p_" .. text)
			end)
		end,
		Get = function(text)
			local ok, v = pcall(function()
				return ds:GetAsync("p_" .. text)
			end)
			return ok and v or nil
		end,
	}
end

local function takenBy(text, model, ownerId)
	local e = live[text]
	if e and e.Model ~= model and e.Model.Parent ~= nil then
		return true
	end
	if store and store.Get then
		local saved = store.Get(text)
		if saved and saved.OwnerUserId ~= ownerId then
			return true
		end
	end
	return false
end

-- Les plaques générées ne sont comparées qu'aux véhicules présents (pas au stockage persistant, pour
-- ménager les quotas) : 1,7 milliard de combinaisons au format GTA, une collision est négligeable.
function Plates.Generate(model)
	for _ = 1, 50 do
		local t = randomPlate()
		local e = live[t]
		if not e or e.Model == model or e.Model.Parent == nil then
			return t
		end
	end
	error("VehiclePlates : impossible de générer une plaque libre")
end

local function release(model)
	local old = byModel[model]
	if old and live[old] and live[old].Model == model then
		live[old] = nil
	end
	byModel[model] = nil
end

-- Attribue une plaque au véhicule (texte nil = générée). info = { OwnerUserId = number?, Persist = bool? }.
-- Renvoie true, texte  ou  false, raison ("invalid", "taken", "store").
function Plates.Assign(model, text, info)
	info = info or {}
	local owner = info.OwnerUserId or model:GetAttribute("OwnerUserId")
	if text == nil or text == "" then
		text = Plates.Generate(model)
	else
		text = Plates.Normalize(text)
		if not Plates.IsValid(text) then
			return false, "invalid"
		end
		if takenBy(text, model, owner) then
			return false, "taken"
		end
	end
	if store and owner and info.Persist ~= false then
		if not store.Reserve(text, { OwnerUserId = owner, Vehicle = model:GetAttribute("ModelName") or model.Name }) then
			return false, "store"
		end
	end
	local previous = byModel[model]
	release(model)
	if previous and previous ~= text and store and owner and info.Persist ~= false and store.Release then
		store.Release(previous)
	end
	live[text] = { Model = model, OwnerUserId = owner, Text = text }
	byModel[model] = text
	-- libère la plaque quand le véhicule est détruit, quel que soit le chemin d'attribution
	-- (Register, Custom.SetPlate, Custom.Apply d'une sauvegarde) ; une seule connexion par modèle
	if not watched[model] then
		watched[model] = model.Destroying:Connect(function()
			release(model)
			local c = watched[model]
			watched[model] = nil
			if c then
				c:Disconnect()
			end
		end)
	end
	model:SetAttribute("PlateText", text)
	if info.PickStyle and Plates.RandomStyles and not model:GetAttribute("PlateStyleChosen") then
		model:SetAttribute("PlateStyle", Plates.PickStyle(text))
	elseif not Plates.Styles[model:GetAttribute("PlateStyle") or 0] then
		model:SetAttribute("PlateStyle", Plates.DefaultStyle)
	end
	Plates.Render(model)
	return true, text
end

-- À appeler à l'apparition d'un véhicule (fait par FiveMVehiclesServer) : garde sa plaque si elle est libre,
-- sinon en génère une (copies d'un même modèle, plaque vide).
function Plates.Register(model)
	if byModel[model] then
		return byModel[model]
	end
	local current = model:GetAttribute("PlateText")
	local ok, text = Plates.Assign(model, current ~= "" and current or nil, { PickStyle = true })
	if not ok then
		ok, text = Plates.Assign(model, nil, { PickStyle = true })
	end
	return text
end

-- Remplace les styles du skill par ceux du jeu (liste 1..n, voir l'en-tête). opts = { Random = bool,
-- Default = index }. Les véhicules déjà présents sont redessinés (et tirés au sort si Random, sauf style choisi).
function Plates.UseStyles(list, opts)
	assert(type(list) == "table" and #list > 0, "UseStyles(list, opts) : liste de styles non vide")
	opts = opts or {}
	local styles = {}
	for i, def in ipairs(list) do
		local st = table.clone(SKILL_STYLE)
		for k, v in pairs(def) do
			st[k] = v
		end
		styles[i] = st
	end
	Plates.Styles = styles
	Plates.DefaultStyle = (opts.Default and styles[opts.Default]) and opts.Default or 1
	Plates.RandomStyles = opts.Random == true
	for model, text in pairs(byModel) do
		if model.Parent ~= nil then
			if Plates.RandomStyles and not model:GetAttribute("PlateStyleChosen") then
				model:SetAttribute("PlateStyle", Plates.PickStyle(text))
			elseif not styles[model:GetAttribute("PlateStyle") or 0] then
				model:SetAttribute("PlateStyle", Plates.DefaultStyle)
			end
			Plates.Render(model)
		end
	end
	return styles
end

function Plates.Lookup(text)
	text = Plates.Normalize(text)
	local e = live[text]
	if e and e.Model.Parent ~= nil then
		return { Model = e.Model, OwnerUserId = e.OwnerUserId, Text = text }
	end
	if store and store.Get then
		local saved = store.Get(text)
		if saved then
			return { Model = nil, OwnerUserId = saved.OwnerUserId, Text = text, Vehicle = saved.Vehicle }
		end
	end
	return nil
end

-- Filtre de texte d'une plaque saisie par un joueur : (player, text) -> texte filtré (erreur levée = échec).
-- Par défaut le filtre Roblox (diffusion publique). ATTENTION : Roblox ne filtre RIEN dans Studio
-- (le texte revient intact, grossièretés comprises) ; le refus « filtered » ne s'observe qu'en serveur
-- publié, ou en remplaçant ce filtre pour un test. Un jeu peut le remplacer (liste maison en plus du filtre
-- Roblox), jamais par un filtre plus permissif que celui de Roblox.
local function robloxFilter(player, text)
	local result = game:GetService("TextService"):FilterStringAsync(text, player.UserId, Enum.TextFilterContext.PublicChat)
	return result:GetNonChatStringForBroadcastAsync()
end
Plates.FilterText = robloxFilter

local studioWarned = false

-- Plaque personnalisée demandée par un joueur : nettoyée (A-Z, 0-9, espace), filtrée (Plates.FilterText,
-- obligatoire pour un texte saisi par un joueur et affiché aux autres), unique. Un texte trop long est
-- REFUSÉ, pas coupé (le joueur doit voir la plaque qu'il a demandée). Renvoie true, texte  ou  false, raison
-- ("invalid", "too_long", "filtered", "filter_error", "taken", "store").
function Plates.RequestCustom(player, model, text)
	local clean = Plates.Clean(text)
	if #clean > Plates.Letters then
		return false, "too_long"
	end
	if not Plates.IsValid(clean) then
		return false, "invalid"
	end
	if not studioWarned and game:GetService("RunService"):IsStudio() and Plates.FilterText == robloxFilter then
		studioWarned = true
		warn("[VehiclePlates] Studio : Roblox ne filtre pas le texte ici ; les plaques personnalisées ne sont filtrées qu'en serveur publié")
	end
	local ok, filtered = pcall(Plates.FilterText, player, clean)
	if not ok or type(filtered) ~= "string" then
		return false, "filter_error"
	end
	if filtered ~= clean then
		return false, "filtered"
	end
	return Plates.Assign(model, clean, { OwnerUserId = player.UserId })
end

function Plates.SetStyle(model, index)
	model:SetAttribute("PlateStyle", index)
	model:SetAttribute("PlateStyleChosen", true)
	Plates.Render(model)
end

return Plates
