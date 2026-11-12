--!nonstrict
--[[
	TestGrounds.lua — map d'essai véhicules PERMANENTE, à construire en mode édition (pas en Play), enregistrée
	avec la place. Un grand plateau quadrillé façon « grid map » : chaque atelier isole un comportement du
	moteur de conduite, avec des panneaux qui disent ce qu'on teste et à quelle valeur.

		local Grounds = require(module)
		local model, info = Grounds.build(workspace)          -- origine auto : au-delà de tout le Workspace (+X)
		local model, info = Grounds.build(workspace, CFrame.new(x, y, z))
		info.teleport                                          -- CFrame de départ (hub, cap vers −Z)
		Grounds.find()                                         -- le modèle déjà construit, ou nil

	Toutes les cotes sont en MÈTRES (× StudsPerMeter, 3,571 par défaut) : un tremplin de 1,53 m est celui de GTA.
	Repère : origine = centre du plateau, dessus du sol à y = 0, les voies se parcourent vers −Z (comme TestTrack).
	Le hub (départ) est au sud (+Z) ; ouest = −X, est = +X.

	Ateliers (dossiers du modèle) :
		00_Sol          plateau 750 × 1150 m en dalles de 50 m alternées (repère de vitesse et de distance), muret
		01_Hub          aire de départ, point de téléportation `TeleportPoint`, plan des ateliers
		02_Piste        ligne droite de 1,1 km, repères tous les 100 m jusqu'à 800 m, zone de freinage, bac à sable
		03_Surfaces     11 bandes de 300 m : asphalte, béton, pavés, herbe, terre, boue, sable, neige, glacier, glace,
		                µ-split (glace à gauche, asphalte à droite) — adhérence de VehicleDynamics.MaterialGrip
		04_Bosses       dos-d'âne 5 à 15 cm, plateaux, coussins, bandes rugueuses, tôle ondulée, gendarmes couchés, crête
		05_Marches      marches de 5 à 30 cm, bordure d'un seul côté, escalier, trottoir en biais, plancher à trous
		06_Articulation bosses alternées 30 et 50 cm, rondins, marche de 50 cm, chute de 1 m
		07_Sauts        tremplins GTA (14,6 °), 5, 10, 20, 30 °, saut avec réception, table
		08_Pentes       côtes de 10, 20, 30, 45 et 60 % (6 m de dénivelé)
		09_Devers       dévers de 10, 20, 30 et 40 ° (renversement)
		10_Virage       virage relevé à 30 °, rayon 46 m, raccordements progressifs
		11_Maniabilite  skidpad (rayon 30 m), slalom (18 m), évitement ISO 3888-1
		12_Crash        mur de béton, poteau, pile de caisses libres
		13_ToutTerrain  champ de bosses, jardin de rochers, rondins en vrac, bascule, pont étroit

	Pièces ancrées sauf les cônes, les caisses et la planche de la bascule (articulée par une HingeConstraint).
	Rien n'est retiré d'une construction précédente sauf avec opts.replace = true.
]]
local Workspace = game:GetService("Workspace")

local Grounds = {}
Grounds.Name = "F2R_TestGrounds"
Grounds.Version = 1
Grounds.StudsPerMeter = 3.571
Grounds.HalfX = 375 -- m
Grounds.HalfZ = 575 -- m
Grounds.Tile = 50 -- m
Grounds.PadY = 0.03 -- m : dessus des revêtements d'atelier, au-dessus du sol (jamais dans son plan)

local C = {
	tileA = Color3.fromRGB(128, 128, 132),
	tileB = Color3.fromRGB(112, 112, 118),
	asphalt = Color3.fromRGB(58, 58, 62),
	concrete = Color3.fromRGB(175, 175, 170),
	white = Color3.fromRGB(240, 240, 240),
	yellow = Color3.fromRGB(240, 200, 40),
	orange = Color3.fromRGB(255, 120, 20),
	red = Color3.fromRGB(200, 40, 40),
	wood = Color3.fromRGB(140, 100, 60),
	earth = Color3.fromRGB(120, 95, 70),
	rock = Color3.fromRGB(110, 108, 104),
	board = Color3.fromRGB(28, 40, 64),
	post = Color3.fromRGB(90, 90, 95),
	ramp = Color3.fromRGB(210, 170, 60),
	hill = Color3.fromRGB(150, 130, 110),
	bank = Color3.fromRGB(150, 150, 160),
}

-- ------------------------------------------------------------------ outils
local S, O, root
local function m(v)
	return v * S
end
-- CFrame monde d'un point (mètres, repère du plateau)
local function at(x, y, z)
	return O * CFrame.new(x * S, y * S, z * S)
end

local function newPart(class, parent, name, sizeM, cf, color, material)
	local p = Instance.new(class or "Part")
	p.Name = name
	p.Anchored = true
	p.Size = Vector3.new(m(sizeM.X), m(sizeM.Y), m(sizeM.Z))
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.Concrete
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- Bloc posé : x, z = centre ; y0 = dessous ; taille (largeur X, hauteur, longueur Z) en m.
local function block(parent, name, x, y0, z, w, h, l, color, material)
	return newPart("Part", parent, name, Vector3.new(w, h, l), at(x, y0 + h / 2, z), color, material)
end

-- Bloc défini par ses bornes (x0..x1, z0..z1) : taille et centre dérivés des mêmes bornes.
local function slab(parent, name, x0, x1, z0, z1, y0, h, color, material)
	local xa, xb = math.min(x0, x1), math.max(x0, x1)
	local za, zb = math.min(z0, z1), math.max(z0, z1)
	return block(parent, name, (xa + xb) / 2, y0, (za + zb) / 2, xb - xa, h, zb - za, color, material)
end

-- Revêtement d'atelier : dessus à PadY, épaisseur 0,2 m (dessous dans le sol). Longueur découpée par 500 m
-- (une pièce Roblox ne dépasse pas 2048 studs).
local function pad(parent, name, x0, x1, z0, z1, color, material)
	local za, zb = math.min(z0, z1), math.max(z0, z1)
	local n = math.max(1, math.ceil((zb - za) / 500))
	local step = (zb - za) / n
	local parts = {}
	for i = 0, n - 1 do
		table.insert(parts, slab(parent, name, x0, x1, za + i * step, za + (i + 1) * step, Grounds.PadY - 0.2, 0.2,
			color, material or Enum.Material.Asphalt))
	end
	return parts
end

local padTop = Grounds.PadY

-- Rampe qui MONTE vers −Z : lèvre basse à z0, arête haute à z0 − l (WedgePart tourné d'un demi-tour).
local function rampUp(parent, name, x, z0, w, l, h, y0, color, material)
	y0 = y0 or padTop
	return newPart("WedgePart", parent, name, Vector3.new(w, h, l),
		at(x, y0 + h / 2, z0 - l / 2) * CFrame.Angles(0, math.pi, 0), color or C.ramp, material)
end
-- Rampe qui DESCEND vers −Z : arête haute à z0, lèvre basse à z0 − l (WedgePart non tourné : haut côté +Z).
local function rampDown(parent, name, x, z0, w, l, h, y0, color, material)
	y0 = y0 or padTop
	return newPart("WedgePart", parent, name, Vector3.new(w, h, l), at(x, y0 + h / 2, z0 - l / 2), color or C.ramp,
		material)
end

-- Dos-d'âne circulaire en travers de la voie : longueur au sol L, hauteur h, sur la largeur w.
-- Un cylindre (axe X) de rayon R = (L²/4 + h²) / 2h dont seule la calotte dépasse du revêtement.
local function cyl(p)
	p.Shape = Enum.PartType.Cylinder
	return p
end
local function hump(parent, name, x, z, w, L, h, color, material)
	local R = (L * L / 4 + h * h) / (2 * h)
	return cyl(newPart("Part", parent, name, Vector3.new(w, 2 * R, 2 * R), at(x, padTop + h - R, z), color or C.yellow,
		material or Enum.Material.Asphalt))
end

-- Panneau : deux poteaux et un tableau dont la face avant regarde (fx, fz) ; texte en SurfaceGui.
local function sign(parent, name, text, x, z, fx, fz, w, h, bottom)
	w, h, bottom = w or 6, h or 2, bottom or 1.2
	local model = Instance.new("Model")
	model.Name = name
	local pos = at(x, bottom + h / 2, z).Position
	local face = O:VectorToWorldSpace(Vector3.new(fx, 0, fz)).Unit
	local cf = CFrame.lookAt(pos, pos + face)
	local boardT = 0.12
	local board = newPart("Part", model, "Board", Vector3.new(w, h, boardT), cf, C.board, Enum.Material.SmoothPlastic)
	for _, sx in ipairs({ -1, 1 }) do
		local postH = bottom + h * 0.85
		-- poteaux derrière le tableau (contact par la face arrière : pas de plan commun visible)
		local pcf = cf * CFrame.new(m(sx * (w / 2 - 0.3)), m(-(bottom + h / 2) + postH / 2), m(boardT / 2 + 0.06))
		newPart("Part", model, "Post", Vector3.new(0.12, postH, 0.12), pcf, C.post, Enum.Material.Metal)
	end
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Label"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 24
	gui.LightInfluence = 0
	gui.Brightness = 1.6
	gui.MaxDistance = 600
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextWrapped = true
	label.Text = text
	local pad_ = Instance.new("UIPadding")
	for _, k in ipairs({ "PaddingLeft", "PaddingRight", "PaddingTop", "PaddingBottom" }) do
		pad_[k] = UDim.new(0.04, 0)
	end
	pad_.Parent = label
	label.Parent = gui
	gui.Parent = board
	model.PrimaryPart = board
	model.Parent = parent
	return model
end
-- Portique tourné vers le conducteur qui arrive par le sud (roule vers −Z) : le bas du tableau est à 2,6 m au
-- moins et les poteaux s'écartent de toute la largeur du tableau, pour qu'un véhicule passe dessous. Les panneaux
-- posés sur une trajectoire sont TOUJOURS des portiques.
Grounds.GantryClearance = 2.6 -- m
local function signS(parent, name, text, x, z, w, h, bottom)
	return sign(parent, name, text, x, z, 0, 1, w, h, math.max(bottom or 0, Grounds.GantryClearance))
end

-- Cône de chantier libre (corps + socle soudés) : renversable, léger.
local function cone(parent, x, z)
	local model = Instance.new("Model")
	model.Name = "Cone"
	local base = newPart("Part", model, "Base", Vector3.new(0.4, 0.04, 0.4), at(x, 0.02 + padTop, z), C.orange,
		Enum.Material.SmoothPlastic)
	local body = cyl(newPart("Part", model, "Body", Vector3.new(0.7, 0.25, 0.25),
		at(x, padTop + 0.04 + 0.35, z) * CFrame.Angles(0, 0, math.pi / 2), C.orange, Enum.Material.SmoothPlastic))
	local band = cyl(newPart("Part", model, "Band", Vector3.new(0.12, 0.27, 0.27),
		at(x, padTop + 0.04 + 0.45, z) * CFrame.Angles(0, 0, math.pi / 2), C.white, Enum.Material.SmoothPlastic))
	for _, p in ipairs({ body, band }) do
		local wc = Instance.new("WeldConstraint")
		wc.Part0, wc.Part1, wc.Parent = base, p, p
		p.CanTouch = false
	end
	for _, p in ipairs({ base, body, band }) do
		p.Anchored = false
		p.CustomPhysicalProperties = PhysicalProperties.new(0.3, 0.6, 0.2)
	end
	model.PrimaryPart = base
	model.Parent = parent
	return model
end

local function folder(name)
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = root
	return f
end

-- ------------------------------------------------------------------ ateliers
local function buildGround(rng)
	local f = folder("00_Sol")
	local T = Grounds.Tile
	local nx, nz = math.floor(2 * Grounds.HalfX / T), math.floor(2 * Grounds.HalfZ / T)
	for i = 0, nx - 1 do
		for j = 0, nz - 1 do
			local x0, z0 = -Grounds.HalfX + i * T, -Grounds.HalfZ + j * T
			slab(f, "Tile", x0, x0 + T, z0, z0 + T, -1.2, 1.2, ((i + j) % 2 == 0) and C.tileA or C.tileB,
				Enum.Material.Concrete)
		end
	end
	-- muret (type GBA) : les côtés nord et sud possèdent les angles, est et ouest s'arrêtent à leur face
	local H, W = 0.8, 0.6
	local hx, hz = Grounds.HalfX, Grounds.HalfZ
	-- nord et sud : bandes de W sur toute la largeur ; découpées par 100 m le long de X
	for _, zs in ipairs({ -1, 1 }) do
		local zIn, zOut = zs * (hz - W), zs * hz
		local n = math.ceil(2 * hx / 100)
		for k = 0, n - 1 do
			local xa, xb = -hx + k * 2 * hx / n, -hx + (k + 1) * 2 * hx / n
			slab(f, "Barrier", xa, xb, zIn, zOut, 0, H, C.concrete, Enum.Material.Concrete)
		end
	end
	for _, xs in ipairs({ -1, 1 }) do
		local xIn, xOut = xs * (hx - W), xs * hx
		local za, zb = -(hz - W), hz - W
		local n = math.ceil((zb - za) / 100)
		for k = 0, n - 1 do
			slab(f, "Barrier", xIn, xOut, za + k * (zb - za) / n, za + (k + 1) * (zb - za) / n, 0, H, C.concrete,
				Enum.Material.Concrete)
		end
	end
end

local function buildHub()
	local f = folder("01_Hub")
	pad(f, "HubPad", -40, 40, 460, 540, C.asphalt)
	-- lignes de stationnement (marquages séparés, aucun recouvrement)
	for i = -3, 3 do
		slab(f, "ParkLine", i * 5 - 0.06, i * 5 + 0.06, 528, 538, padTop, 0.01, C.white, Enum.Material.SmoothPlastic)
	end
	local tp = block(f, "TeleportPoint", 0, padTop + 0.5, 520, 1, 1, 1, C.yellow, Enum.Material.Neon)
	tp.CFrame = at(0, padTop + 1, 520) -- cap vers −Z
	tp.Transparency, tp.CanCollide, tp.CanQuery, tp.CanTouch = 1, false, false, false
	signS(f, "Title", "MAP D'ESSAI VÉHICULES", 0, 470, 16, 3, 4.4)
	signS(f, "PlanWest", "← SURFACES · BOSSES · MARCHES · ARTICULATION · MANIABILITÉ · CRASH", -27, 470, 14, 2.4)
	signS(f, "PlanNorth", "↑ SAUTS · VIRAGE RELEVÉ", 0, 476, 10, 1.4)
	signS(f, "PlanEast", "→ PENTES · DÉVERS · TOUT-TERRAIN · PISTE 1 KM", 27, 470, 14, 2.4)
	return tp
end

local function buildDrag()
	local f = folder("02_Piste")
	local x0, x1 = 310, 350
	pad(f, "Strip", x0, x1, -560, 560, C.asphalt)
	slab(f, "StartLine", x0, x1, 529.75, 530.25, padTop, 0.01, C.white, Enum.Material.SmoothPlastic)
	-- ligne médiane pointillée : 3 m peints tous les 12 m
	for z = 520, -550, -12 do
		slab(f, "CenterDash", 329.9, 330.1, z - 3, z, padTop, 0.01, C.white, Enum.Material.SmoothPlastic)
	end
	sign(f, "Start", "PISTE 1 KM · départ arrêté ici · 0 à 800 m", 355, 534, 0, 1, 9, 2, 1.2)
	for d = 100, 800, 100 do
		sign(f, "Dist" .. d, d .. " m", 356, 530 - d, 0, 1, 3, 1.4, 1)
		-- trait au sol à chaque repère (sur le bord, hors de la ligne médiane)
		slab(f, "DistLine", x0, x0 + 4, 530 - d - 0.25, 530 - d + 0.25, padTop, 0.01, C.yellow,
			Enum.Material.SmoothPlastic)
	end
	sign(f, "Brake", "ZONE DE FREINAGE", 356, -290, 0, 1, 6, 1.6, 1)
	slab(f, "SandTrap", x0, x1, -574.4, -560, -0.15, 0.25, Color3.fromRGB(210, 190, 140), Enum.Material.Sand)
end

local function buildSurfaces()
	local f = folder("03_Surfaces")
	local list = {
		{ "Asphalte", Enum.Material.Asphalt, C.asphalt, "1,00" },
		{ "Béton", Enum.Material.Concrete, C.concrete, "1,00" },
		{ "Pavés", Enum.Material.Cobblestone, Color3.fromRGB(130, 120, 110), "0,90" },
		{ "Herbe", Enum.Material.Grass, Color3.fromRGB(90, 140, 60), "0,70" },
		{ "Terre", Enum.Material.Ground, C.earth, "0,75" },
		{ "Boue", Enum.Material.Mud, Color3.fromRGB(90, 70, 50), "0,55" },
		{ "Sable", Enum.Material.Sand, Color3.fromRGB(210, 190, 140), "0,55" },
		{ "Neige", Enum.Material.Snow, Color3.fromRGB(235, 240, 245), "0,45" },
		{ "Glacier", Enum.Material.Glacier, Color3.fromRGB(190, 220, 240), "0,30" },
		{ "Glace", Enum.Material.Ice, Color3.fromRGB(200, 230, 250), "0,20" },
	}
	local x = -360
	for i, s in ipairs(list) do
		pad(f, "Surface_" .. s[1], x, x + 12, 140, 440, s[3], s[2])
		signS(f, "Sign_" .. s[1], s[1] .. " · adhérence " .. s[4], x + 6, 446, 9, 1.4, 0.8)
		x += 12.5
	end
	-- µ-split : glace à gauche (−X), asphalte à droite, jointive au milieu (deux pièces bout à bout)
	pad(f, "Split_Ice", x, x + 6, 140, 440, Color3.fromRGB(200, 230, 250), Enum.Material.Ice)
	pad(f, "Split_Asphalt", x + 6, x + 12, 140, 440, C.asphalt, Enum.Material.Asphalt)
	signS(f, "Sign_Split", "µ-split · glace | asphalte", x + 6, 446, 9, 1.4, 0.8)
	signS(f, "Zone", "SURFACES · freinage, motricité, dérive", -290, 455, 14, 2.2, 5.2)
end

local function buildBumps(rng)
	-- trois voies parallèles, roulées vers −Z
	local L1, L2, L3 = -195, -170, -145
	local W = 14
	local fb = folder("04_Bosses")
	local fm = folder("05_Marches")
	local fa = folder("06_Articulation")
	for _, x in ipairs({ L1, L2, L3 }) do
		pad(x == L1 and fb or (x == L2 and fm or fa), "Lane", x - W / 2, x + W / 2, -100, 440, C.asphalt)
	end
	local function lbl(fold, text, x, z)
		-- panneau bas dans l'interstice à gauche de la voie (hors trajectoire)
		sign(fold, "Sign", text, x - W / 2 - 2.5, z + 3, 0, 1, 4.5, 1.2, 0.6)
	end

	-- 04 Bosses -------------------------------------------------------------------------------------------
	local hs = { 0.05, 0.075, 0.10, 0.125, 0.15 }
	for i, h in ipairs(hs) do
		local z = 400 - (i - 1) * 25
		hump(fb, "Hump_" .. math.floor(h * 1000 + 0.5) .. "mm", L1, z, W, 3.7, h)
		lbl(fb, string.format("Dos-d'âne %g cm", h * 100), L1, z)
	end
	-- plateaux (ralentisseurs trapézoïdaux) : rampes 1:10, dessus de 6 m
	for i, h in ipairs({ 0.10, 0.15 }) do
		local z0 = 270 - (i - 1) * 30
		local r = h * 10
		rampUp(fb, "TableUp", L1, z0, W, r, h, padTop, C.yellow, Enum.Material.Asphalt)
		block(fb, "TableTop", L1, padTop, z0 - r - 3, W, h, 6, C.asphalt, Enum.Material.Asphalt)
		rampDown(fb, "TableDown", L1, z0 - r - 6, W, r, h, padTop, C.yellow, Enum.Material.Asphalt)
		lbl(fb, string.format("Plateau %g cm", h * 100), L1, z0)
	end
	-- coussins berlinois : trois blocs de 1,8 m, 7 cm, les roues les enjambent ou non
	for _, dx in ipairs({ -4, 0, 4 }) do
		block(fb, "Cushion", L1 + dx, padTop, 205, 1.8, 0.07, 3, C.red, Enum.Material.Asphalt)
	end
	lbl(fb, "Coussins 7 cm", L1, 207)
	-- bandes rugueuses : 30 barres de 2 cm tous les 0,6 m
	for k = 0, 29 do
		block(fb, "Rumble", L1, padTop, 180 - k * 0.6, W, 0.02, 0.25, C.white, Enum.Material.SmoothPlastic)
	end
	lbl(fb, "Bandes rugueuses 2 cm", L1, 181)
	-- tôle ondulée : 80 ondes de 3 cm tous les 0,8 m
	for k = 0, 79 do
		hump(fb, "Washboard", L1, 140 - k * 0.8, W, 0.8, 0.03, C.earth, Enum.Material.Ground)
	end
	lbl(fb, "Tôle ondulée 3 cm", L1, 141)
	hump(fb, "Gendarme_20cm", L1, 40, W, 2.5, 0.2)
	lbl(fb, "Gendarme 20 cm", L1, 41)
	hump(fb, "Gendarme_30cm", L1, 10, W, 3, 0.3)
	lbl(fb, "Gendarme 30 cm", L1, 11)
	hump(fb, "Crest_1m", L1, -40, W, 16, 1.0, C.hill, Enum.Material.Asphalt)
	lbl(fb, "Crête 1 m (envol)", L1, -31)
	signS(fb, "Zone", "BOSSES · dos-d'âne, tôle, crête", L1, 452, 9, 1.8, 1.2)

	-- 05 Marches ------------------------------------------------------------------------------------------
	for i, h in ipairs({ 0.05, 0.10, 0.15, 0.20, 0.30 }) do
		local z0 = 400 - (i - 1) * 50
		block(fm, "Step_" .. math.floor(h * 100 + 0.5) .. "cm", L2, padTop, z0 - 10, W, h, 20, C.concrete,
			Enum.Material.Concrete)
		lbl(fm, string.format("Marche %g cm", h * 100), L2, z0)
	end
	-- bordure d'un seul côté (roues gauches seulement)
	block(fm, "CurbLeft", L2 - W / 4, padTop, 140, W / 2, 0.15, 20, C.concrete, Enum.Material.Concrete)
	lbl(fm, "Bordure 15 cm côté gauche", L2, 150)
	-- escalier : 5 marches de 15 × 40 cm, palier de 6 m, redescente
	local z = 100
	for k = 1, 5 do
		block(fm, "Stair", L2, padTop, z - 0.2, W, 0.15 * k, 0.4, C.concrete, Enum.Material.Concrete)
		z -= 0.4
	end
	block(fm, "Landing", L2, padTop, z - 3, W, 0.75, 6, C.concrete, Enum.Material.Concrete)
	z -= 6
	for k = 5, 1, -1 do
		block(fm, "Stair", L2, padTop, z - 0.2, W, 0.15 * k, 0.4, C.concrete, Enum.Material.Concrete)
		z -= 0.4
	end
	lbl(fm, "Escalier 5 × 15 cm", L2, 100)
	-- trottoir en biais (30 °) de 25 cm : une roue après l'autre
	local p = block(fm, "CurbDiagonal", L2, padTop, 60, W / math.cos(math.rad(30)) - 2, 0.25, 1, C.concrete,
		Enum.Material.Concrete)
	p.CFrame = at(L2, padTop + 0.125, 60) * CFrame.Angles(0, math.rad(30), 0)
	lbl(fm, "Trottoir en biais 25 cm", L2, 64)
	-- plancher à trous : 25 cm de haut, trous de 2 × 2 m (« nids-de-poule »), segments pleins fusionnés
	rampUp(fm, "DeckRamp", L2, 30, W, 2.5, 0.25, padTop, C.concrete, Enum.Material.Concrete)
	local cells, rows = 7, 40
	local zTop = 30 - 2.5
	for r = 0, rows - 1 do
		local za, zb = zTop - (r + 1) * 2, zTop - r * 2
		local runStart = nil
		for c = 0, cells do
			local hole = c < cells and r > 0 and r < rows - 1 and rng:NextNumber() < 0.2
			local solid = c < cells and not hole
			if solid and not runStart then
				runStart = c
			elseif not solid and runStart then
				slab(fm, "Deck", L2 - W / 2 + runStart * 2, L2 - W / 2 + c * 2, za, zb, padTop, 0.25, C.concrete,
					Enum.Material.Concrete)
				runStart = nil
			end
		end
	end
	rampDown(fm, "DeckRampDown", L2, zTop - rows * 2, W, 2.5, 0.25, padTop, C.concrete, Enum.Material.Concrete)
	lbl(fm, "Nids-de-poule 25 cm", L2, 31)
	signS(fm, "Zone", "MARCHES · 5 à 30 cm, escalier, trous", L2, 452, 9, 1.8, 1.2)

	-- 06 Articulation -------------------------------------------------------------------------------------
	-- gradué : une sportive basse (garde ≈ 12 cm) passe les 15 cm et bute sur les 30 cm (vérifié en Studio)
	for k = 0, 5 do
		local side = (k % 2 == 0) and -1 or 1
		hump(fa, "Alt15", L3 + side * W / 4, 430 - k * 6, W / 2, 3, 0.15, C.hill, Enum.Material.Ground)
	end
	lbl(fa, "Bosses alternées 15 cm", L3, 431)
	for k = 0, 7 do
		local side = (k % 2 == 0) and -1 or 1
		hump(fa, "Alt30", L3 + side * W / 4, 385 - k * 6, W / 2, 3, 0.3, C.hill, Enum.Material.Ground)
	end
	lbl(fa, "Bosses alternées 30 cm", L3, 386)
	for k = 0, 5 do
		local side = (k % 2 == 0) and 1 or -1
		hump(fa, "Alt50", L3 + side * W / 4, 320 - k * 8, W / 2, 4, 0.5, C.hill, Enum.Material.Ground)
	end
	lbl(fa, "Bosses alternées 50 cm", L3, 321)
	for i, r in ipairs({ 0.05, 0.12, 0.25 }) do
		for k = 0, 2 do
			cyl(block(fa, "Log", L3, padTop, 230 - (i - 1) * 15 - k * 3, W, 2 * r, 2 * r, C.wood, Enum.Material.Wood))
		end
		lbl(fa, string.format("Rondins Ø %g cm", r * 200), L3, 230 - (i - 1) * 15)
	end
	local log = cyl(block(fa, "LogDiagonal", L3, padTop, 160, W / math.cos(math.rad(30)) - 2, 0.5, 0.5, C.wood,
		Enum.Material.Wood))
	log.CFrame = at(L3, padTop + 0.25, 160) * CFrame.Angles(0, math.rad(30), 0)
	lbl(fa, "Rondin en biais Ø 50 cm", L3, 164)
	block(fa, "Ledge50", L3, padTop, 110, W, 0.5, 20, C.concrete, Enum.Material.Concrete)
	lbl(fa, "Marche 50 cm", L3, 121)
	rampUp(fa, "DropRamp", L3, 80, W, 4, 1.0, padTop, C.ramp)
	block(fa, "DropTop", L3, padTop, 80 - 4 - 5, W, 1.0, 10, C.concrete, Enum.Material.Concrete)
	lbl(fa, "Chute de 1 m", L3, 81)
	signS(fa, "Zone", "ARTICULATION · croisement, rondins", L3, 452, 9, 1.8, 1.2)
end

local function buildJumps()
	local f = folder("07_Sauts")
	local zR = 150 -- lèvre des tremplins
	local jumps = {
		{ x = -95, w = 4.02, l = 5.86, h = 1.53, t = "Tremplin GTA 14,6° (1,53 m)" },
		{ x = -77, w = 8, h = 1.0, a = 5, t = "Tremplin 5° (1 m)" },
		{ x = -59, w = 8, h = 1.5, a = 10, t = "Tremplin 10° (1,5 m)" },
		{ x = -41, w = 8, h = 2.0, a = 20, t = "Tremplin 20° (2 m)" },
		{ x = -23, w = 8, h = 2.5, a = 30, t = "Tremplin 30° (2,5 m)" },
	}
	for _, j in ipairs(jumps) do
		local l = j.l or (j.h / math.tan(math.rad(j.a)))
		pad(f, "RunUp", j.x - 5, j.x + 5, zR, 440, C.asphalt)
		rampUp(f, "Ramp", j.x, zR, j.w, l, j.h, 0)
		signS(f, "Sign", j.t, j.x, 447, 8, 1.4, 0.8)
	end
	-- saut avec réception : départ 12° jusqu'à 3 m, vide de 15 m, réception à 10°. Portée balistique
	-- v²·sin 24° / g : 15 m demandent ≈ 68 km/h AU DÉCOLLAGE, la réception (17 m) accepte jusqu'à ≈ 100 km/h.
	-- VÉRIFIÉ en Studio : avec un vide de 25 m (≈ 88 km/h requis), le m422 décollé à 82 km/h retombait dans le
	-- vide et percutait la face haute (verticale) de la réception.
	local x = 0
	local lUp = 3 / math.tan(math.rad(12))
	local lDown = 3 / math.tan(math.rad(10))
	pad(f, "RunUp", x - 6, x + 6, zR, 440, C.asphalt)
	rampUp(f, "GapLaunch", x, zR, 10, lUp, 3, 0)
	rampDown(f, "GapLanding", x, zR - lUp - 15, 10, lDown, 3, 0)
	signS(f, "Sign", "Saut 15 m · décoller à 70 km/h ou plus", x, 447, 9, 1.4, 0.8)
	-- table : montée 15° jusqu'à 2 m, dessus 15 m, descente 15°
	x = 26
	local l = 2 / math.tan(math.rad(15))
	pad(f, "RunUp", x - 6, x + 6, zR, 440, C.asphalt)
	rampUp(f, "TableUp", x, zR, 10, l, 2, 0)
	block(f, "TableTop", x, 0, zR - l - 7.5, 10, 2, 15, C.ramp, Enum.Material.Concrete)
	rampDown(f, "TableDown", x, zR - l - 15, 10, l, 2, 0)
	signS(f, "Sign", "Table 15° · 2 m", x, 447, 8, 1.4, 0.8)
	signS(f, "Zone", "SAUTS · élan 290 m, réception libre jusqu'à 350 m", -40, 455, 12, 2, 5.2)
end

local function buildHills()
	local f = folder("08_Pentes")
	local H, top = 6, 10
	for i, g in ipairs({ 0.10, 0.20, 0.30, 0.45, 0.60 }) do
		local x = 100 + (i - 1) * 25
		local l = H / g
		local z0 = 420
		pad(f, "Approach", x - 5, x + 5, z0, 440, C.asphalt)
		rampUp(f, "Up", x, z0, 10, l, H, 0, C.hill)
		block(f, "Top", x, 0, z0 - l - top / 2, 10, H, top, C.hill, Enum.Material.Concrete)
		rampDown(f, "Down", x, z0 - l - top, 10, l, H, 0, C.hill)
		signS(f, "Sign", string.format("Côte %d %% (%.1f°)", g * 100, math.deg(math.atan(g))), x, 446, 8, 1.4, 0.8)
	end
	signS(f, "Zone", "PENTES · côte, démarrage en côte, frein à main", 150, 455, 12, 2, 5.2)
end

local function buildBanks()
	local f = folder("09_Devers")
	for i, a in ipairs({ 10, 20, 30, 40 }) do
		local x = 100 + (i - 1) * 30
		local w, l = 12, 60
		local h = w * math.tan(math.rad(a))
		-- monte vers +X : WedgePart tourné de +90 ° (son +Z local devient +X)
		newPart("WedgePart", f, "Bank" .. a, Vector3.new(l, h, w), at(x, h / 2, 80) * CFrame.Angles(0, math.pi / 2, 0),
			C.bank, Enum.Material.Concrete)
		signS(f, "Sign", string.format("Dévers %d° · entrer par le bord bas (ouest)", a), x, 116, 9, 1.4, 0.8)
	end
	signS(f, "Zone", "DÉVERS · renversement latéral", 145, 128, 12, 2, 1.6)
end

local function buildBankedCurve()
	local f = folder("10_Virage")
	local cx, cz = 0, -330
	local Rin, W = 40, 12
	local Rm, Rout = Rin + W / 2, Rin + W
	-- entrée côté est (x = cx + Rm) en roulant vers −Z, demi-tour par le nord, sortie côté ouest vers +Z
	pad(f, "Entry", cx + Rin, cx + Rout, cz, -200, C.asphalt)
	pad(f, "Exit", cx - Rout, cx - Rin, cz, -200, C.asphalt)
	local bankMax, ramp = 30, 40 -- °, raccordement sur 40 ° d'arc de chaque côté
	local function bankAt(phi)
		local d = math.min(phi, 180 - phi)
		return bankMax * math.clamp(d / ramp, 0, 1)
	end
	local phi = 0
	while phi < 180 - 1e-6 do
		local d = math.min(phi, 180 - phi)
		local step = (d < ramp) and 1 or 2
		step = math.min(step, 180 - phi)
		local mid = phi + step / 2
		local bank = math.max(bankAt(mid), 0.5)
		local h = W * math.tan(math.rad(bank))
		-- corde prise au rayon extérieur : les coins se touchent pile au bord haut et se chevauchent un peu vers
		-- l'intérieur, là où leurs faces sont presque au sol
		local chord = 2 * Rout * math.sin(math.rad(step / 2))
		local r = math.rad(mid)
		local px, pz = cx + Rm * math.cos(r), cz - Rm * math.sin(r)
		local pos = at(px, h / 2, pz).Position
		local centre = at(cx, h / 2, cz).Position
		-- l'avant du coin regarde le centre : son côté haut (+Z local) est à l'extérieur
		local p = newPart("WedgePart", f, "Bank", Vector3.new(chord, h, W), CFrame.lookAt(pos, centre), C.bank,
			Enum.Material.Asphalt)
		p:SetAttribute("BankDeg", bank)
		phi += step
	end
	signS(f, "Zone", "VIRAGE RELEVÉ 30° · rayon 46 m · entrée à droite", cx + Rm, -196, 9, 1.8, 1.2)
end

local function buildHandling()
	local f = folder("11_Maniabilite")
	-- skidpad : disque d'asphalte de 45 m, anneau peint à 30 m
	local cx, cz = -290, -130
	local disc = newPart("Part", f, "Skidpad", Vector3.new(0.2, 90, 90),
		at(cx, padTop - 0.1, cz) * CFrame.Angles(0, 0, math.pi / 2), C.asphalt, Enum.Material.Asphalt)
	disc.Shape = Enum.PartType.Cylinder
	local n = 72
	for k = 0, n - 1 do
		if k % 2 == 0 then
			local a = (k + 0.5) / n * 2 * math.pi
			local chord = 2 * 30 * math.sin(math.pi / n)
			local p = block(f, "Ring30", cx + 30 * math.cos(a), padTop, cz + 30 * math.sin(a), 0.2, 0.01, chord,
				C.white, Enum.Material.SmoothPlastic)
			p.CFrame = at(cx + 30 * math.cos(a), padTop + 0.005, cz + 30 * math.sin(a)) * CFrame.Angles(0, -a, 0)
		end
	end
	signS(f, "SignSkid", "SKIDPAD · cercle de 30 m · adhérence latérale", cx, -80, 10, 1.6, 1)
	-- slalom : 12 cônes tous les 18 m
	local xs = -335
	pad(f, "SlalomLane", xs - 6, xs + 6, -480, -195, C.asphalt)
	for k = 0, 11 do
		cone(f, xs, -230 - k * 18)
	end
	signS(f, "SignSlalom", "SLALOM · 12 cônes, 18 m", xs, -190, 8, 1.4, 0.8)
	-- évitement ISO 3888-1 (largeur de véhicule 2 m) : couloirs de cônes
	local xl = -270
	pad(f, "IsoLane", xl - 9, xl + 7, -480, -195, C.asphalt)
	local function gate(z0, z1, xc, width)
		for _, z in ipairs({ z0, (z0 + z1) / 2, z1 }) do
			cone(f, xc - width / 2, z)
			cone(f, xc + width / 2, z)
		end
	end
	gate(-250, -265, xl, 1.1 * 2 + 0.25) -- section 1, 15 m
	gate(-295, -320, xl - 3.5, 2 + 1) -- section 3, 25 m, décalée de 3,5 m à gauche (−X)
	gate(-345, -360, xl, 1.3 * 2 + 0.25) -- section 5, 15 m
	signS(f, "SignIso", "ÉVITEMENT ISO 3888-1 · double changement de voie", xl, -190, 10, 1.6, 0.8)
	signS(f, "Zone", "MANIABILITÉ", -262, -60, 10, 2, 1.6)
end

local function buildCrash()
	local f = folder("12_Crash")
	-- mur
	pad(f, "WallLane", -176, -154, -500, -150, C.asphalt) -- bords hors des joints de dalles (x = −175)
	block(f, "Wall", -165, 0, -506, 20, 3, 2, C.concrete, Enum.Material.Concrete)
	signS(f, "SignWall", "MUR · béton 3 m · élan 350 m", -165, -146, 8, 1.4, 0.8)
	-- poteau
	pad(f, "PoleLane", -205, -185, -420, -150, C.asphalt)
	cyl(block(f, "Pole", -195, padTop, -425, 6, 0.3, 0.3, C.post, Enum.Material.Metal)).CFrame =
		at(-195, padTop + 3, -425) * CFrame.Angles(0, 0, math.pi / 2)
	signS(f, "SignPole", "POTEAU · Ø 30 cm", -195, -146, 6, 1.4, 0.8)
	-- caisses libres
	pad(f, "CrateLane", -140, -120, -440, -150, C.asphalt)
	for ix = 0, 4 do
		for iz = 0, 2 do
			for iy = 0, 2 do
				local p = block(f, "Crate", -132 + ix * 1.02, padTop + iy * 1.0, -420 - iz * 1.02, 1, 1, 1,
					Color3.fromRGB(170, 130, 80), Enum.Material.Cardboard)
				p.Anchored = false
				p.CustomPhysicalProperties = PhysicalProperties.new(0.15, 0.5, 0.2)
			end
		end
	end
	signS(f, "SignCrates", "CAISSES · 45 caisses libres", -130, -146, 7, 1.4, 0.8)
	signS(f, "Zone", "CRASH", -165, -132, 8, 2, 5.2)
end

local function buildOffroad(rng)
	local f = folder("13_ToutTerrain")
	-- revêtements de terre : le champ de bosses, puis rochers et rondins (bandes séparées, jamais superposées)
	pad(f, "Dirt", 98, 282, -262, -78, C.earth, Enum.Material.Ground)
	pad(f, "Dirt", 98, 182, -372, -288, Color3.fromRGB(105, 95, 80), Enum.Material.Ground)
	pad(f, "Dirt", 204, 276, -366, -294, Color3.fromRGB(110, 90, 65), Enum.Material.Ground)
	-- champ de bosses : calottes de sphère enterrées
	local placed = {}
	local tries = 0
	while #placed < 90 and tries < 2000 do
		tries += 1
		local r = rng:NextNumber(1.5, 4.5)
		local hAbove = rng:NextNumber(0.3, math.min(1.2, r * 0.6))
		local x, z = rng:NextNumber(100 + r, 280 - r), rng:NextNumber(-260 + r, -80 - r)
		local ok = true
		for _, q in ipairs(placed) do
			if (q[1] - x) ^ 2 + (q[2] - z) ^ 2 < (q[3] + r + 1) ^ 2 then
				ok = false
				break
			end
		end
		if ok then
			table.insert(placed, { x, z, r })
			local b = newPart("Part", f, "Mogul", Vector3.new(2 * r, 2 * r, 2 * r), at(x, hAbove - r, z), C.earth,
				Enum.Material.Ground)
			b.Shape = Enum.PartType.Ball
		end
	end
	signS(f, "SignMoguls", "CHAMP DE BOSSES · 30 cm à 1,2 m", 145, -72, 10, 1.6, 1)
	-- jardin de rochers
	for k = 1, 60 do
		local s = rng:NextNumber(0.4, 1.4)
		local x, z = rng:NextNumber(102, 178), rng:NextNumber(-368, -292)
		newPart("Part", f, "Rock", Vector3.new(s * rng:NextNumber(0.8, 1.4), s, s * rng:NextNumber(0.8, 1.4)),
			at(x, s * 0.15, z) * CFrame.Angles(rng:NextNumber(-0.6, 0.6), rng:NextNumber(0, math.pi), rng:NextNumber(-0.6, 0.6)),
			C.rock, Enum.Material.Slate)
	end
	signS(f, "SignRocks", "JARDIN DE ROCHERS", 140, -284, 8, 1.4, 0.8)
	-- rondins en vrac
	for k = 1, 10 do
		local r = rng:NextNumber(0.15, 0.35)
		local len = rng:NextNumber(6, 12)
		local x, z = rng:NextNumber(208, 272), rng:NextNumber(-362, -298)
		cyl(newPart("Part", f, "Log", Vector3.new(len, 2 * r, 2 * r),
			at(x, r, z) * CFrame.Angles(0, rng:NextNumber(0, math.pi), 0), C.wood, Enum.Material.Wood))
	end
	signS(f, "SignLogs", "RONDINS EN VRAC", 240, -284, 7, 1.4, 0.8)
	-- bascule : planche libre de 18 m sur un axe à 1,2 m (HingeConstraint), plus légère qu'un véhicule
	local bx, bz = 140, -440
	local pivotY = 1.2
	local base = block(f, "SeesawBase", bx, 0, bz, 6, pivotY - 0.1, 1, C.post, Enum.Material.Metal)
	local tilt = math.asin(pivotY / 9)
	local plank = newPart("Part", f, "SeesawPlank", Vector3.new(5, 0.15, 18),
		-- extrémité BASSE côté sud (+Z), celle par où l'on arrive ; VÉRIFIÉ en Studio : dans l'autre sens le haut
		-- (2,4 m) est face au conducteur et la voiture se coince dessous. Abordée par le bas, la planche bascule de
		-- −7,7 à +7,7 ° sous le m422.
		at(bx, pivotY + 0.075, bz) * CFrame.Angles(tilt, 0, 0), C.wood, Enum.Material.WoodPlanks)
	plank.Anchored = false
	plank.CustomPhysicalProperties = PhysicalProperties.new(0.05, 0.8, 0.2)
	local a0 = Instance.new("Attachment")
	a0.Name = "Hinge"
	a0.Parent = base
	a0.WorldCFrame = at(bx, pivotY, bz)
	local a1 = Instance.new("Attachment")
	a1.Name = "Hinge"
	a1.Parent = plank
	a1.WorldCFrame = at(bx, pivotY, bz)
	local hinge = Instance.new("HingeConstraint")
	hinge.Attachment0, hinge.Attachment1 = a0, a1
	hinge.LimitsEnabled = true
	hinge.LowerAngle, hinge.UpperAngle = -20, 20
	hinge.Parent = plank
	signS(f, "SignSeesaw", "BASCULE · planche libre de 18 m", bx, -424, 8, 1.4, 0.8)
	-- pont étroit : 2,6 m de large, 1,2 m de haut, 30 m
	local px = 230
	rampUp(f, "BridgeUp", px, -430, 2.6, 6, 1.2, 0, C.wood, Enum.Material.WoodPlanks)
	block(f, "Bridge", px, 0, -436 - 15, 2.6, 1.2, 30, C.wood, Enum.Material.WoodPlanks)
	rampDown(f, "BridgeDown", px, -466, 2.6, 6, 1.2, 0, C.wood, Enum.Material.WoodPlanks)
	signS(f, "SignBridge", "PONT ÉTROIT · 2,6 m", px, -424, 6, 1.4, 0.8)
	signS(f, "Zone", "TOUT-TERRAIN", 190, -60, 9, 2, 1.6)
end

-- ------------------------------------------------------------------ API
function Grounds.find(parent)
	return (parent or Workspace):FindFirstChild(Grounds.Name)
end

-- Origine au-delà de toutes les pièces de Workspace (côté +X), au niveau y = 0.
function Grounds.autoOrigin(spm)
	spm = spm or Grounds.StudsPerMeter
	local maxX, minZ, maxZ = -math.huge, math.huge, -math.huge
	for _, d in ipairs(Workspace:GetDescendants()) do
		if d:IsA("BasePart") and d ~= Workspace.Terrain then
			local p, s = d.Position, d.Size
			maxX = math.max(maxX, p.X + s.Magnitude / 2)
			minZ, maxZ = math.min(minZ, p.Z), math.max(maxZ, p.Z)
		end
	end
	if maxX == -math.huge then
		return CFrame.new(0, 0, 0)
	end
	return CFrame.new(maxX + Grounds.HalfX * spm + 1000, 0, (minZ + maxZ) / 2)
end

function Grounds.build(parent, origin, opts)
	opts = opts or {}
	parent = parent or Workspace
	local old = Grounds.find(parent)
	if old then
		assert(opts.replace, Grounds.Name .. " existe déjà : passer opts.replace = true pour le reconstruire")
		origin = origin or old:GetAttribute("Origin")
		old:Destroy()
	end
	S = opts.studsPerMeter or Grounds.StudsPerMeter
	O = origin or Grounds.autoOrigin(S)
	local rng = Random.new(opts.seed or 422)
	root = Instance.new("Model")
	root.Name = Grounds.Name
	root:SetAttribute("Origin", O)
	root:SetAttribute("StudsPerMeter", S)
	root:SetAttribute("Version", Grounds.Version)
	buildGround(rng)
	local tp = buildHub()
	buildDrag()
	buildSurfaces()
	buildBumps(rng)
	buildJumps()
	buildHills()
	buildBanks()
	buildBankedCurve()
	buildHandling()
	buildCrash()
	buildOffroad(rng)
	root.PrimaryPart = tp
	root.Parent = parent
	local n = 0
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			n += 1
		end
	end
	return root, { teleport = tp.CFrame, origin = O, parts = n }
end

return Grounds
