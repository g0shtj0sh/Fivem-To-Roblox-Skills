--!nonstrict
--[[
	VehicleCamera (ModuleScript, ReplicatedStorage.FiveMVehicles) — caméra de l'occupant local, façon Assetto Corsa.

		local Camera = require(ReplicatedStorage.FiveMVehicles.VehicleCamera)
		Camera.Start()                         -- FiveMVehiclesClient l'appelle une fois
		Camera.SetSettings({ Fov = 72 })       -- le jeu (ou son menu) règle la caméra ; Camera.Changed prévient
		Camera.ApplyPreset("Dynamic")          -- jeu d'effets : "Calm" (défaut) ou "Dynamic"
		Camera.SetView("Cockpit")              -- ou Camera.CycleView() ; touche V / bouton « Vue »

	Vues (cycle de V, comme la touche F1 d'Assetto Corsa) :
	- ChaseNear / Chase : caméra de poursuite. Réglages en MÈTRES (Distance, Height) et degrés (Pitch), convertis
	  avec le StudsPerMeter du véhicule. Comportement relevé sur DynaCam (chase cam CSP de kirbyguy22) et sa version
	  « Imagined Visuals », réécrit ici :
	  · point suivi = centre des roues, distance comptée depuis l'essieu arrière (une voiture longue est cadrée comme
	    une courte) ;
	  · la caméra suit la DIRECTION DE LA VITESSE (pas le capot) dès ~1 m/s : en glisse, la voiture tourne librement
	    devant elle et se voit de biais, voire de face en toupie (vidéo de référence waVSKP0OuOs) ; l'angle de glisse
	    peut être exagéré (SlipExaggerate) ; pas d'orbite en vraie marche arrière (attribut Reverse, ou lente) ;
	  · elle suit la pente (inclinaison de la vitesse, lissée) ; Pitch incline la vue et la hauteur le compense ;
	  · effets (0 = coupé) : AccelFx (recul à l'accélération, rapprochement au freinage), BrakeDip (plongée au
	    freinage), RollFx (roulis en virage), BumpFx (rebond sur les bosses), SpeedShake (léger tremblement avec la
	    vitesse), Impact (secousse aux chocs) ; FovDynamic + FovGain élargissent le champ avec la vitesse, la distance
	    est alors corrigée pour garder la voiture à la même taille à l'écran ;
	  · regarder autour : clic droit maintenu + souris, stick droit, glisser au doigt ; C (R3) regarde derrière ;
	    la vue revient d'elle-même derrière la voiture (RecenterDelay) ;
	  · un mur entre la voiture et la caméra rapproche la caméra (Collide).
	- Bonnet : sur le capot, au pied du pare-brise, le capot visible en bas.
	- Cockpit : l'œil GTA du siège (VehiclePose.EyeWorld). La vue tourne avec le véhicule, cap borné à ±YawMax,
	  recentrage automatique ; seuls les avant-bras et les mains du personnage sont visibles. Tête « physique »
	  (Settings.Neck, comportement relevé sur NeckFX / AC Head Physics de Jack Sankey & Jordash, réécrit ici) :
	  · chaque axe est un ressort amorti (fréquence Hz, amortissement 0..1) ; les déplacements (avant, côté,
	    vertical) sont poussés par les accélérations du véhicule en g, la tête reste en arrière à l'accélération,
	    part vers l'extérieur en virage ;
	  · les rotations (tangage, roulis, lacet) gardent la tête stable dans le monde puis la ramènent vers l'habitacle :
	    la voiture bouge autour du regard ; « Tracking » = suivi des yeux (passe-haut sur la rotation du véhicule) ;
	  · pivots : le déplacement avant fait hocher la tête, le déplacement latéral la penche et la tourne pour viser
	    un point devant ; regard un peu dans le virage (SteerFollow × angle du volant) ; à-coup au passage de
	    rapport (GearKick) ; tout s'efface sous ThresholdKmh..FullKmh ;
	  · regarder derrière : LookBack degrés (130 : par-dessus l'épaule), transition lissée.

	En entrant dans un véhicule : vue Cockpit si le joueur était en première personne, sinon la dernière vue
	extérieure (DefaultView au début). Pendant le ciblage de VehicleTarget (Alt), la vue est figée, souris libre.
	Attribut `ChaseCamera = false` sur un véhicule : caméra de Roblox (pivot sur l'œil) au lieu des vues extérieures ;
	`PovCamera = false` : pas de vue cockpit.
]]
local Players = game:GetService("Players")
local ContextActionService = game:GetService("ContextActionService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local Pose = require(script.Parent:WaitForChild("VehiclePose"))

-- VehicleTarget (facultatif) : vrai pendant qu'on maintient Alt pour viser une pièce du véhicule
local targetModule = false
local function targeting()
	if targetModule == false then
		local m = script.Parent:FindFirstChild("VehicleTarget")
		local ok, mod = pcall(function()
			return m and require(m)
		end)
		targetModule = (ok and type(mod) == "table" and mod.IsActive) and mod or nil
	end
	return targetModule ~= nil and targetModule.IsActive() == true
end

local Camera = {}
Camera.Tag = "FiveMVehicle"
Camera.Views = { "ChaseNear", "Chase", "Bonnet", "Cockpit" }
Camera.ViewLabels = { ChaseNear = "Poursuite proche", Chase = "Poursuite", Bonnet = "Capot", Cockpit = "Cockpit" }

-- Jeux d'effets de la poursuite. « Calm » = Imagined Visuals (FOV fixe, sans recul ni roulis), « Dynamic » = DynaCam.
Camera.Presets = {
	Calm = { Fov = 72, FovDynamic = false, FovGain = 0, BrakeZoom = 0, AccelFx = 0, BrakeDip = 0, RollFx = 0,
		BumpFx = 0.5, SpeedShake = 1, ShakeSpeed = 25, Impact = 1 },
	Dynamic = { Fov = 55, FovDynamic = true, FovGain = 25, BrakeZoom = 1, AccelFx = 1, BrakeDip = 1, RollFx = 1,
		BumpFx = 1, SpeedShake = 1, ShakeSpeed = 45, Impact = 1 },
}

-- Réglages courants (le jeu les change avec SetSettings ; tout est lu à chaque image)
Camera.Settings = {
	Preset = "Calm",
	DefaultView = "ChaseNear",
	-- mètres, mètres, degrés. Calés en Studio sur les vidéos de référence (comparaison à même hauteur d'image,
	-- 2026-11-16) : proche = poursuite No Hesi (horizon 47 %, voiture ≈ 0,5 × la hauteur d'écran), poursuite =
	-- vidéo « last christmas » (voiture ≈ 0,4 × la hauteur, horizon 40 %). Les réglages AC d'origine (2,4 / 1,15 / 13
	-- et 2,8 / 1,25 / 15) donnaient une caméra trop proche qui plongeait sur le toit avec nos repères.
	ChaseNear = { Distance = 2.9, Height = 1.15, Pitch = 3 },
	Chase = { Distance = 3.2, Height = 1.55, Pitch = 10 },
	Bonnet = { Fov = 65, Forward = 1.15, Height = 0.2 }, -- avance depuis l'œil (m), hauteur au-dessus du capot (m)
	-- FOV vertical 55 : cadrage des vidéos de référence (volant ≈ 0,8 × la hauteur d'écran) ; le « FOV 100 » du guide
	-- NeckFX donnait une vue bien trop large (refusé par l'utilisateur, 2026-11-16). Pitch : regard vers le bas (°).
	-- Forward : avance de l'œil vers le volant (m). Calé sur la vue cockpit de référence (volant ≈ 0,7 × la hauteur).
	Cockpit = { Fov = 55, Forward = 0.03, Pitch = 6, LookBack = 130 },
	-- tête physique du cockpit : réglages « NeckFX Imagined Visuals » fournis par l'utilisateur (2026-11-16)
	Neck = {
		Enabled = true,
		Strength = 1, -- multiplie les déplacements et les rotations de la tête (0 = tête fixe)
		FrequencyScale = 1, DampingScale = 1, ThresholdKmh = 3, FullKmh = 10,
		-- au-dessus de Bandwidth (Hz), la tête suit la voiture (« Max Frequency » de NeckFX) : notre caisse vibre bien
		-- plus que celle d'Assetto Corsa, stabilisée à toutes les fréquences la vue faisait danser tout l'habitacle
		-- (mesuré 2026-11-16 : 17,5 °/s de rotation de la vue en ligne droite contre 0,13 sans la tête)
		Bandwidth = 2.5,
		RotationScale = 0.5, -- part des rotations de la tête gardée (réalisme dosé, comme les références)
		Pitch = { On = true, Freq = 0.7, Damp = 0.85, Tracking = false },
		Roll = { On = true, Freq = 1, Damp = 1, Tracking = false },
		Yaw = { On = true, Freq = 1.5, Damp = 0.85, Tracking = true },
		Forward = { On = true, Freq = 1.5, Damp = 0.85, Scale = 2 },
		Side = { On = true, Freq = 1.3, Damp = 0.85, Scale = 1 },
		Vertical = { On = true, Freq = 3.5, Damp = 0.85, Scale = 1, Recenter = 1 },
		ForwardPitchPivot = 0.7, -- m (0 = sans) : le déplacement avant fait hocher la tête
		SideRollPivot = 0.4, -- m : le déplacement latéral la penche (0,2 du preset NeckFX : 5,8° en virage, trop)
		SideSighting = 25, -- m : et la tourne pour garder un point visé devant
		-- regard dans le virage : léger (la tête tourne très peu dans les vidéos de référence ; 0,1 / 20° tournait trop)
		SteerFollow = 0.04, SteerMax = 6, SteerRatio = 14, Smoothing = 0.25,
		GearKick = { On = true, Scale = 0.15, Vertical = 1, Forward = 0.5, Pitch = 1, Freq = 4, Damp = 0.26, Gas = 0 },
		Limits = { Forward = 0.25, Side = 0.12, Vertical = 0.14, Angle = 30 }, -- garde-fous (m, degrés)
	},
	-- 1 : la poursuite suit la TRAJECTOIRE comme DynaCam et les vidéos de référence : en drift la voiture tourne
	-- devant une caméra qui garde le sens de la route (utilisateur, 2026-11-16, vidéo waVSKP0OuOs) ;
	-- 0 : elle reste collée derrière le capot (refusé : « on a toujours la vue arrière de notre véhicule »)
	VelocityFollow = 1,
	SlipExaggerate = 0,
	Collide = true,
	-- effets (remplis par le preset)
}
for k, v in pairs(Camera.Presets.Calm) do
	Camera.Settings[k] = v
end

Camera.YawMax = 110 -- cockpit : degrés de part et d'autre de l'avant
Camera.PitchUp = 30
Camera.PitchDown = 45
Camera.StartPitch = 4 -- cockpit : degrés vers le bas à l'ouverture de la vue
Camera.RecenterDelay = 1.5 -- s sans toucher à la vue avant de revenir vers l'avant (toutes les vues)
Camera.RecenterRate = 2.5 -- 1/s
Camera.RecenterSpeed = 3 -- m/s : en dessous, la vue reste où on l'a laissée
Camera.ToggleKey = Enum.KeyCode.V
Camera.LookBackKeys = { Enum.KeyCode.C, Enum.KeyCode.ButtonR3 }
Camera.ExitZoom = 12 -- studs : distance de la caméra de Roblox à la sortie du véhicule
Camera.Visible = { LeftLowerArm = 0.55, RightLowerArm = 0.55, LeftHand = 0.75, RightHand = 0.75 }

local changed = Instance.new("BindableEvent")
Camera.Changed = changed.Event -- (settings, view)

local player = Players.LocalPlayer
local state = {
	view = nil, -- vue en cours, nil hors véhicule
	lastOutside = nil, -- dernière vue extérieure choisie
	model = nil,
	yaw = 0, -- regard (cockpit : relatif à l'habitacle ; poursuite/capot : décalage autour de la voiture)
	pitch = 0,
	lastLook = 0,
	touches = {},
	fovBefore = nil,
	offsetHum = nil,
	-- poursuite
	dirFlat = nil,
	dirY = 0,
	slip = 0,
	speed = 0,
	lastVel = nil,
	acc = Vector3.zero, -- g lissées (x latéral, y vertical, z longitudinal)
	accFast = Vector3.zero,
	accSlow = Vector3.zero,
	lastAccRaw = Vector3.zero,
	bump = 0,
	bumpV = 0,
	after = 0,
	fovAdd = 0,
	t = 0,
	head = Vector3.zero,
}

local function deepMerge(dst, src)
	for k, v in pairs(src) do
		if type(v) == "table" and type(dst[k]) == "table" then
			deepMerge(dst[k], v)
		else
			dst[k] = v
		end
	end
end

local function copy(t)
	local c = {}
	for k, v in pairs(t) do
		c[k] = type(v) == "table" and copy(v) or v
	end
	return c
end

function Camera.GetSettings()
	return copy(Camera.Settings)
end

function Camera.SetSettings(partial)
	if type(partial) ~= "table" then
		return
	end
	deepMerge(Camera.Settings, partial)
	changed:Fire(Camera.GetSettings(), state.view)
end

function Camera.ApplyPreset(name)
	local p = Camera.Presets[name]
	if not p then
		return false
	end
	local s = copy(p)
	s.Preset = name
	Camera.SetSettings(s)
	return true
end

function Camera.GetView()
	return state.view
end

function Camera.IsPov()
	return state.view == "Cockpit"
end

-- ------------------------------------------------------------------ véhicule occupé
local function occupied()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.SeatPart
	local model = seat and seat.Parent and seat.Parent.Name == "Seats" and seat.Parent.Parent
	if model and CollectionService:HasTag(model, Camera.Tag) and model.PrimaryPart and hum.RootPart then
		return model, seat, hum, char
	end
	return nil
end

local cfgCache = setmetatable({}, { __mode = "k" })
local function config(model)
	local c = cfgCache[model]
	if c == nil then
		local m = model:FindFirstChild("VehicleConfig")
		local ok, r = pcall(function()
			return require(m)
		end)
		c = (ok and type(r) == "table" and r) or false
		cfgCache[model] = c
	end
	return c or nil
end

-- géométrie utile à la poursuite (repère du véhicule, mètres) : centre des roues, demi-empattement, essieu arrière
local geoCache = setmetatable({}, { __mode = "k" })
local function geometry(model)
	local g = geoCache[model]
	if g then
		return g
	end
	local cfg = config(model) or {}
	local spm = cfg.StudsPerMeter or 3.571
	local sum, n, zMin, zMax, yLow = Vector3.zero, 0, math.huge, -math.huge, math.huge
	for _, w in pairs(cfg.Wheels or {}) do
		local p = w.Position
		if p then
			sum += Vector3.new(p[1], p[2], p[3])
			n += 1
			zMin = math.min(zMin, p[3])
			zMax = math.max(zMax, p[3])
			yLow = math.min(yLow, p[2] - (w.Radius or 0.33))
		end
	end
	if n == 0 then
		local size = model:GetExtentsSize() / spm
		g = { spm = spm, center = Vector3.zero, halfWB = size.Z * 0.3, ground = -size.Y / 2 }
	else
		g = { spm = spm, center = sum / n, halfWB = math.max((zMax - zMin) / 2, 0.5), ground = yLow }
	end
	geoCache[model] = g
	return g
end

local function enabledPov(model, seat)
	return model:GetAttribute("PovCamera") ~= false and Pose.EyeWorld(model, seat) ~= nil
end
local function enabledChase(model)
	return model:GetAttribute("ChaseCamera") ~= false
end
local function viewAllowed(model, seat, v)
	if v == "Cockpit" then
		return enabledPov(model, seat)
	elseif v == "Bonnet" then
		return enabledChase(model) and Pose.EyeWorld(model, seat) ~= nil
	end
	return enabledChase(model)
end

local function anyDown(keys)
	for _, k in ipairs(keys) do
		if UserInputService:IsKeyDown(k) then
			return true
		end
	end
	for _, pad in ipairs(UserInputService:GetConnectedGamepads()) do
		for _, k in ipairs(keys) do
			if UserInputService:IsGamepadButtonDown(pad, k) then
				return true
			end
		end
	end
	return false
end

-- ------------------------------------------------------------------ corps du personnage (cockpit)
-- Bras de la vue intérieure : les VRAIS avant-bras et mains, amincis sur ce client seulement (une taille changée
-- par un client ne se réplique pas). Tailles d'origine rendues à la sortie.
local thinned = {}
local function restoreArms()
	for part, t in pairs(thinned) do
		if part.Parent and part.Size == t.set then
			part.Size = t.orig
		end
	end
	table.clear(thinned)
end
local function thinArms(char)
	for name, thin in pairs(Camera.Visible) do
		local part = char:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			local t = thinned[part]
			if not t or part.Size ~= t.set then
				local orig = part.Size
				local set = Vector3.new(orig.X * thin, orig.Y, orig.Z * thin)
				thinned[part] = { orig = orig, set = set }
				part.Size = set
			end
		end
	end
end
local bodyHidden = false
local function setBody(char, pov)
	if not char then
		return
	end
	if pov == bodyHidden and not pov then
		return
	end
	for _, p in ipairs(char:GetDescendants()) do
		if p:IsA("BasePart") then
			local isLimb = p.Parent == char and Camera.Visible[p.Name] ~= nil
			p.LocalTransparencyModifier = (pov and not isLimb) and 1 or 0
		end
	end
	if pov then
		thinArms(char)
	else
		restoreArms()
	end
	bodyHidden = pov
end

-- ------------------------------------------------------------------ vues
local neck, resetNeck -- tête physique du cockpit (définies plus bas)
local driveModule = false -- VehicleDrive (facultatif), chargé à la première image du cockpit

local function resetDynamics()
	state.dirFlat = nil
	state.reverseMode = false
	state.dirY = 0
	state.slip = 0
	state.lastVel = nil
	state.velF = nil
	state.accNeck = Vector3.zero
	state.acc, state.accFast, state.accSlow, state.lastAccRaw = Vector3.zero, Vector3.zero, Vector3.zero, Vector3.zero
	state.bump, state.bumpV, state.after, state.fovAdd = 0, 0, 0, 0
	state.head = Vector3.zero
end

local function setView(v, char)
	if state.view == v then
		return
	end
	local was = state.view
	state.view = v
	state.yaw = 0
	state.pitch = (v == "Cockpit") and -math.rad(Camera.Settings.Cockpit.Pitch or Camera.StartPitch) or 0
	state.lastLook = os.clock()
	if v and v ~= "Cockpit" then
		state.lastOutside = v
	end
	if was == "Cockpit" and v ~= "Cockpit" then
		setBody(char or player.Character, false)
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
	end
	if was == nil then
		resetDynamics()
	end
	if v == "Cockpit" and was ~= "Cockpit" then
		resetNeck()
	end
	changed:Fire(Camera.GetSettings(), v)
end

function Camera.SetView(v)
	local model, seat, _, char = occupied()
	if not model or not table.find(Camera.Views, v) or not viewAllowed(model, seat, v) then
		return false
	end
	setView(v, char)
	return true
end

function Camera.CycleView()
	local model, seat, _, char = occupied()
	if not model then
		return nil
	end
	local i = table.find(Camera.Views, state.view) or 0
	for step = 1, #Camera.Views do
		local v = Camera.Views[(i + step - 1) % #Camera.Views + 1]
		if viewAllowed(model, seat, v) then
			setView(v, char)
			return v
		end
	end
	return state.view
end

-- regard (radians) : entrée des scripts et des essais
local function look(dYaw, dPitch)
	if state.view == "Cockpit" then
		state.yaw = math.clamp(state.yaw + dYaw, -math.rad(Camera.YawMax), math.rad(Camera.YawMax))
		state.pitch = math.clamp(state.pitch + dPitch, -math.rad(Camera.PitchDown), math.rad(Camera.PitchUp))
	else
		state.yaw = (state.yaw + dYaw + math.pi) % (2 * math.pi) - math.pi
		-- poursuite / capot : comme la caméra de Roblox, souris vers le haut = caméra plus basse qui regarde en l'air
		state.pitch = math.clamp(state.pitch + dPitch, -math.rad(60), math.rad(15))
	end
	state.lastLook = os.clock()
end
function Camera.Look(dYaw, dPitch)
	look(dYaw, dPitch or 0)
end

-- ------------------------------------------------------------------ outils
local function lerpK(rate, dt)
	return 1 - math.exp(-rate * dt)
end
local function flat(v)
	local f = Vector3.new(v.X, 0, v.Z)
	return f.Magnitude > 1e-4 and f.Unit or nil
end
local function signedAngle(a, b) -- de a vers b autour de +Y
	return math.atan2(a:Cross(b).Y, a:Dot(b))
end
local function rotY(v, a)
	return CFrame.Angles(0, a, 0):VectorToWorldSpace(v)
end
local function softsat(x) -- sin(atan(x)) : linéaire près de 0, borné à ±1
	return x / math.sqrt(1 + x * x)
end
local function sigmoid(x)
	return 1 / (1 + math.exp(-x))
end
local function deadzone(x) -- palier doux au centre (roulis), ±1 au-delà
	return 0.5 * (math.tanh((x + 3) / 2) + math.tanh((x - 3) / 2))
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local function collide(target, pos, model)
	local list = { model }
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	rayParams.FilterDescendantsInstances = list
	local d = pos - target
	local hit = Workspace:Raycast(target, d, rayParams)
	if hit and hit.Instance.CanCollide then
		return target + d.Unit * math.max((hit.Position - target).Magnitude - 0.4, 0.5)
	end
	return pos
end

-- accélérations du véhicule (g, repère : x latéral, y vertical, z avant) et secousses, lissées comme DynaCam
local function updateDynamics(root, g, dt)
	local spm = g.spm
	local vel = root.AssemblyLinearVelocity / spm
	local cf = root.CFrame
	-- la vitesse lue à chaque image tremble (pas physiques, réseau) : dérivée d'une vitesse lissée, sinon les
	-- accélérations font trembler la tête du cockpit
	state.velF = state.velF and state.velF:Lerp(vel, lerpK(20, dt)) or vel
	if state.lastVel and dt > 0 then
		local a = (state.velF - state.lastVel) / dt / 9.81
		local raw = Vector3.new(a:Dot(cf.RightVector), a.Y, a:Dot(cf.LookVector))
		state.acc = state.acc:Lerp(raw, lerpK(3, dt))
		state.accFast = state.accFast:Lerp(raw, lerpK(15, dt))
		state.accSlow = state.accSlow:Lerp(raw, lerpK(1, dt))
		state.accNeck = (state.accNeck or Vector3.zero):Lerp(raw, lerpK(6, dt))
		local jerk = (raw - state.lastAccRaw) / dt / 16
		state.lastAccRaw = raw
		-- choc : un à-coup fort laisse une secousse qui retombe
		local j = jerk.Magnitude
		state.after += ((j > 8 and math.min(j - 8, 10) or 0) * (Camera.Settings.Impact or 0) - state.after) * lerpK(8, dt)
		-- rebond vertical : ressort amorti (raideur 10, amortissement 10) tiré vers l'à-coup vertical
		local sub = math.max(1, math.ceil(dt / (1 / 240)))
		local h = dt / sub
		for _ = 1, sub do
			local acc = 10 * (math.clamp(jerk.Y, -5, 5) - state.bump) - 10 * state.bumpV
			state.bumpV += acc * h
			state.bump += state.bumpV * h
		end
	end
	state.lastVel = state.velF
	state.speed += (vel.Magnitude - state.speed) * lerpK(30, dt)
	return vel
end

local function noise(seed)
	return math.noise(state.t * 6, seed, 0.5)
end

-- ------------------------------------------------------------------ poursuite
local function chaseCFrame(model, root, dt, viewSettings)
	local S = Camera.Settings
	local g = geometry(model)
	local spm = g.spm
	local cf = root.CFrame
	local vel = updateDynamics(root, g, dt)
	local carDir = cf.LookVector
	local carFlat = flat(carDir) or Vector3.zAxis
	local speed = vel.Magnitude

	-- direction suivie : la trajectoire dès ~1 m/s (pas en marche arrière), lissée
	local follow = (S.VelocityFollow or 1) * math.clamp(state.speed - 1, 0, 1)
	local target = carDir
	-- vraie marche arrière : pas d'orbite. On y entre seulement en reculant depuis (presque) l'arrêt ; une toupie à
	-- vitesse (la voiture glisse l'arrière en avant) n'en est pas une : la caméra garde la trajectoire et montre
	-- l'avant de la voiture. (L'attribut Reverse ne suffit pas : il passe à true dès que la voiture recule, toupie
	-- comprise — mesuré 2026-11-16 : caméra recollée au capot à 126° de glisse et 30 km/h.)
	local backwards = speed > 0.1 and vel.Unit:Dot(carDir) < -0.25
	if not backwards then
		state.reverseMode = false
	elseif not state.reverseMode and speed < (Camera.ReverseEnterSpeed or 1.5) then
		state.reverseMode = true
	end
	local reversing = backwards and state.reverseMode
	if speed > 0.1 and not reversing then
		target = carDir:Lerp(vel.Unit, follow)
	end
	state.dirY += ((speed < 0.1 and carDir.Y or target.Y) - state.dirY) * lerpK(4, dt)
	local tFlat = flat(target) or carFlat
	-- rotation lissée par l'ANGLE (un mélange de vecteurs passerait par zéro sur un demi-tour : saut de caméra)
	state.dirFlat = state.dirFlat
			and rotY(state.dirFlat, signedAngle(state.dirFlat, tFlat) * lerpK(Camera.Settings.FollowRate or 6, dt))
		or tFlat
	local dirFlat = flat(state.dirFlat) or carFlat
	-- angle de glisse un peu exagéré (la voiture se montre davantage de biais)
	local angle = reversing and 0 or signedAngle(carFlat, dirFlat)
	state.slip += ((S.SlipExaggerate or 1) * 0.32 * softsat(2 * angle) - state.slip) * lerpK(8, dt)
	local view = rotY(dirFlat, state.slip)

	-- regarder autour / derrière, et retour derrière la voiture
	local mps = speed
	-- angle fixe : revient derrière la voiture dès qu'on ne regarde plus autour (clic droit, stick, doigt)
	if not state.looking then
		local k = lerpK(6, dt)
		state.yaw -= state.yaw * k
		state.pitch -= state.pitch * k
	end
	local yaw = state.yaw + (anyDown(Camera.LookBackKeys) and math.pi or 0)
	view = rotY(view, yaw)

	-- pente de la route
	local roadPitch = math.asin(math.clamp(state.dirY, -0.9, 0.9))
	local right = view:Cross(Vector3.yAxis).Unit
	local dir3 = (view * math.cos(roadPitch) + Vector3.yAxis * math.sin(roadPitch)).Unit
	-- regard vertical (souris, stick) : orbite autour du point visé
	dir3 = CFrame.fromAxisAngle(right, state.pitch):VectorToWorldSpace(dir3)

	-- champ de vision (vertical) et distance
	local base = S.Fov or 72
	if S.FovDynamic then
		local az = state.accSlow.Z
		local accelPart = az > 0 and softsat(az) or (S.BrakeZoom or 0) * 0.5 * softsat(2 * az)
		state.fovAdd += ((S.FovGain or 0) * softsat(state.speed / 36) + accelPart * 20 - state.fovAdd) * lerpK(5, dt)
	else
		state.fovAdd += (0 - state.fovAdd) * lerpK(5, dt)
	end
	local fov = math.clamp(base + state.fovAdd, 10, 110)
	local az = state.acc.Z
	local accelPush = (az > 0 and 2 * softsat(0.5 * az) or softsat(az)) * g.halfWB * 1.5 * (S.AccelFx or 0)
	local D = viewSettings.Distance + 0.1 + 1.5 * g.halfWB + accelPush
	-- quand le FOV s'élargit, la caméra se rapproche pour garder la voiture à la même taille
	D += (D - (2.5 * g.halfWB + 1.1)) * (math.tan(math.rad(base) / 2) / math.tan(math.rad(fov) / 2) - 1)
	local pitchUser = math.rad(viewSettings.Pitch)
	-- Height = hauteur de la caméra au-dessus du point suivi (≈ centre de gravité) ; Pitch penche la vue vers le bas
	local H = viewSettings.Height

	-- position (orbite autour du point suivi, distance comptée depuis l'essieu arrière)
	-- point suivi : centre des roues, un peu au-dessus (≈ centre de gravité), avancé d'un quart d'empattement
	local anchor = cf:PointToWorldSpace(Vector3.new(g.center.X, g.center.Y + 0.15, g.center.Z) * spm)
		+ carDir * (0.5 * g.halfWB * spm)
	local camUp = right:Cross(dir3).Unit
	local shakeK = sigmoid(state.speed / (S.ShakeSpeed or 25) * 5 - 5) * (S.SpeedShake or 0)
	local bumpK = math.clamp(state.bump, -1, 1) * (S.BumpFx or 0)
	local after = state.after
	local pos = anchor - dir3 * D * spm + camUp * H * spm
		+ camUp * (bumpK * 0.15 + noise(3) * after * 0.03) * spm
		+ right * (noise(1) * shakeK * 0.004 + noise(2) * after * 0.03) * spm
	local lookTarget = anchor + camUp * 0.5 * spm -- pour la collision : du toit vers la caméra

	-- orientation : inclinaison réglée, regard vertical, plongée au freinage, bosses, tremblement
	local lookDir = (CFrame.fromAxisAngle(right, -pitchUser)):VectorToWorldSpace(dir3)
	local dip = az < 0 and 2 * softsat(-az / 2) or 0.1 * softsat(-10 * az)
	local tilt = -math.rad(dip * 7) * (S.BrakeDip or 0) - bumpK * 0.05
		+ noise(4) * (shakeK * 0.0012 + after * 0.02)
	lookDir = CFrame.fromAxisAngle(right, tilt):VectorToWorldSpace(lookDir)
	lookDir = CFrame.fromAxisAngle(camUp, noise(5) * (after * 0.008 + shakeK * 0.0008)):VectorToWorldSpace(lookDir)
	local roll = deadzone(3.4 * state.accFast.X) * -0.06 * (S.RollFx or 0) + noise(6) * after * 0.02
	local up = CFrame.fromAxisAngle(lookDir, roll):VectorToWorldSpace(Vector3.yAxis)

	if S.Collide ~= false then
		pos = collide(lookTarget, pos, model)
	end
	return CFrame.lookAt(pos, pos + lookDir, up), fov
end

-- ------------------------------------------------------------------ capot
local bonnetCache = setmetatable({}, { __mode = "k" })
local bonnetParams = RaycastParams.new()
bonnetParams.FilterType = Enum.RaycastFilterType.Include
local function bonnetLocal(model, seat)
	local c = bonnetCache[model]
	if c then
		return c
	end
	local S = Camera.Settings.Bonnet
	local g = geometry(model)
	local root = model.PrimaryPart
	local eye = root.CFrame:PointToObjectSpace(Pose.EyeWorld(model, seat))
	local p = Vector3.new(0, eye.Y, eye.Z - (S.Forward or 0.75) * g.spm)
	-- hauteur du capot à cet endroit : la coque de collision du véhicule (les pièces visibles ne sont pas visées)
	local parts = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and d.CanQuery and d.CanCollide then
			table.insert(parts, d)
		end
	end
	bonnetParams.FilterDescendantsInstances = parts
	local from = root.CFrame:PointToWorldSpace(p + Vector3.new(0, 3 * g.spm, 0))
	local hit = #parts > 0 and Workspace:Raycast(from, -root.CFrame.UpVector * 6 * g.spm, bonnetParams)
	if hit then
		local y = root.CFrame:PointToObjectSpace(hit.Position).Y + (S.Height or 0.1) * g.spm
		p = Vector3.new(0, math.min(y, eye.Y), p.Z)
	end
	bonnetCache[model] = p
	return p
end

local function bonnetCFrame(model, seat, root, dt)
	local cf = root.CFrame
	updateDynamics(root, geometry(model), dt)
	if not state.looking then
		local k = lerpK(6, dt)
		state.yaw -= state.yaw * k
		state.pitch -= state.pitch * k
	end
	local yaw = state.yaw + (anyDown(Camera.LookBackKeys) and math.pi or 0)
	local p = cf:PointToWorldSpace(bonnetLocal(model, seat))
	return CFrame.new(p) * cf.Rotation * CFrame.Angles(0, yaw, 0) * CFrame.Angles(math.clamp(state.pitch, -0.6, 0.6) - math.rad(2), 0, 0),
		Camera.Settings.Bonnet.Fov or 65
end

-- ------------------------------------------------------------------ cockpit
-- tête physique (Settings.Neck) : ressorts amortis par axe ; x'' = −2ζω·x' − ω²·x + a
neck = { x = { 0, 0 }, y = { 0, 0 }, z = { 0, 0 }, pitch = { 0, 0 }, roll = { 0, 0 }, yaw = { 0, 0 },
	kick = { 0, 0 }, hpY = { 0, 0 }, hpRate = { pitch = { 0, 0 }, roll = { 0, 0 }, yaw = { 0, 0 } }, look = 0, back = 0,
	lastRot = nil, gear = nil }
resetNeck = function()
	for _, k in ipairs({ "x", "y", "z", "pitch", "roll", "yaw", "kick", "hpY" }) do
		neck[k][1], neck[k][2] = 0, 0
	end
	for _, r in pairs(neck.hpRate) do
		r[1], r[2] = 0, 0
	end
	neck.look, neck.lastRot, neck.gear, neck.lp = 0, nil, nil, nil
end
local function springStep(s, freq, damp, a, dt)
	local w = 2 * math.pi * math.min(freq, 9.7)
	local n = math.max(1, math.ceil(dt / (1 / 240)))
	local h = dt / n
	for _ = 1, n do
		s[2] += (-2 * math.min(damp, 1) * w * s[2] - w * w * s[1] + a) * h
		s[1] += s[2] * h
	end
	return s[1]
end
-- passe-haut du 1er ordre (constante de temps tau) : ne garde que les changements
local function highPass(st, input, tau, dt)
	if not tau or tau <= 0 then
		st[1], st[2] = input, input
		return input
	end
	local a = tau / (tau + dt)
	st[1] = a * (st[1] + input - st[2])
	st[2] = input
	return st[1]
end
-- garde-fou : linéaire jusqu'à la moitié de la limite, puis courbe jusqu'à la limite
local function softClip(v, max)
	if not max or max <= 0 then
		return v
	end
	local a = math.abs(v)
	if a <= max * 0.5 then
		return v
	end
	local xm = 1.5 * max
	local out = a >= xm and max or (max - (a - xm) ^ 2 / (2 * max))
	return math.sign(v) * out
end
local function smoothStep01(x, zero)
	if x >= 1 then
		return 1
	elseif x <= zero then
		return 0
	end
	local t = (x - zero) / (1 - zero)
	return -2 * t ^ 3 + 3 * t ^ 2
end

local function neckPose(model, root, dt)
	local N = Camera.Settings.Neck
	if not N or N.Enabled == false then
		return CFrame.identity
	end
	local cfg = config(model) or {}
	local k = N.Strength or 1
	local fs, ds = N.FrequencyScale or 1, N.DampingScale or 1
	local kmh = state.speed * 3.6
	local full = math.max(N.FullKmh or 10, 0.1)
	local on = smoothStep01(kmh / full, (N.ThresholdKmh or 3) / full)
	local L = N.Limits or {}
	-- accélérations du véhicule en g (x à droite, y en haut, z vers l'avant), légèrement lissées
	local a = state.accNeck or Vector3.zero
	-- déplacements : la tête reste en arrière de l'accélération
	local dx = N.Side.On and springStep(neck.x, N.Side.Freq * fs, N.Side.Damp * ds, (N.Side.Scale or 1) * a.X, dt) or 0
	local ay = highPass(neck.hpY, a.Y, N.Vertical.Recenter, dt)
	local dy = N.Vertical.On and springStep(neck.y, N.Vertical.Freq * fs, N.Vertical.Damp * ds, (N.Vertical.Scale or 1) * ay, dt) or 0
	local dz = N.Forward.On and springStep(neck.z, N.Forward.Freq * fs, N.Forward.Damp * ds, (N.Forward.Scale or 1) * a.Z, dt) or 0
	dx, dy, dz = softClip(dx, L.Side), softClip(dy, L.Vertical), softClip(dz, L.Forward)
	-- rotations : la tête garde son orientation dans le monde (on retranche la rotation du véhicule), puis revient
	local rot = root.CFrame.Rotation
	local rx, ry, rz = 0, 0, 0
	if neck.lastRot and dt > 0 then
		rx, ry, rz = neck.lastRot:ToObjectSpace(rot):ToEulerAnglesYXZ()
	end
	neck.lastRot = rot
	local maxA = math.rad(L.Angle or 30)
	local function axis(name, A, delta)
		if not A.On then
			return 0
		end
		local f, z = A.Freq * fs, A.Damp * ds
		local rate = delta / math.max(dt, 1e-4)
		if A.Tracking then
			-- suivi des yeux : seule la partie rapide de la rotation du véhicule est compensée
			rate = highPass(neck.hpRate[name], rate, 1 / (2 * math.pi * f), dt)
			f, z = f * 1.2, z * 0.5
		end
		local s = neck[name]
		s[1] -= rate * dt
		return softClip(springStep(s, f, z, 0, dt), maxA)
	end
	local pitch = axis("pitch", N.Pitch, rx)
	local yaw = axis("yaw", N.Yaw, ry)
	local roll = axis("roll", N.Roll, rz)
	-- seules les rotations lentes restent compensées : passe-bas (Bandwidth) sur les angles de la tête
	local bw = N.Bandwidth or 0
	if bw > 0 then
		local kb = 1 - math.exp(-dt * 2 * math.pi * bw)
		neck.lp = neck.lp or { 0, 0, 0 }
		neck.lp[1] += (pitch - neck.lp[1]) * kb
		neck.lp[2] += (yaw - neck.lp[2]) * kb
		neck.lp[3] += (roll - neck.lp[3]) * kb
		pitch, yaw, roll = neck.lp[1], neck.lp[2], neck.lp[3]
	end
	local rs = N.RotationScale or 1
	pitch, yaw, roll = pitch * rs, yaw * rs, roll * rs
	-- pivots : avancer fait hocher, glisser de côté penche et tourne la tête
	if (N.ForwardPitchPivot or 0) ~= 0 then
		pitch += dz / N.ForwardPitchPivot
	end
	if (N.SideRollPivot or 0) ~= 0 then
		roll += dx / N.SideRollPivot
	end
	if (N.SideSighting or 0) ~= 0 then
		yaw -= dx / N.SideSighting -- tête partie à gauche : elle tourne à droite pour garder le point visé
	end
	-- à-coup au passage de rapport
	local gear = model:GetAttribute("Gear")
	local G = N.GearKick
	if G and G.On and neck.gear ~= nil and gear ~= neck.gear then
		neck.kick[2] = (G.Scale or 0.15) * 0.5
	end
	neck.gear = gear
	local kick = (G and G.On) and springStep(neck.kick, G.Freq or 4, G.Damp or 0.26, 0, dt) or 0
	local maxRpm = (cfg.Audio and cfg.Audio.MaxRpm) or 7000
	local rpmK = (1 + 2 * (model:GetAttribute("Throttle") or 0) * ((G and G.Gas) or 0))
		* math.clamp((model:GetAttribute("Rpm") or 0) / maxRpm, 0, 1.2)
	if G and G.On then
		dy += kick * (G.Vertical or 1) * rpmK
		dz += a.Z * kick * (G.Forward or 0.5) * rpmK * 3
		pitch -= a.Z * kick * (G.Pitch or 1) * 2 * rpmK
	end
	-- regard dans le virage : une part de l'angle du volant, lissée. Conducteur local : la direction calculée par
	-- le moteur de conduite (à jour à chaque image) ; passager : l'attribut Steer répliqué
	local steer = model:GetAttribute("Steer") or 0
	if driveModule == false then
		local mod = script.Parent:FindFirstChild("VehicleDrive")
		local ok, r = pcall(function()
			return mod and require(mod)
		end)
		driveModule = (ok and type(r) == "table" and r.Get) and r or nil
	end
	local active = driveModule and driveModule.Get()
	if active and active.car == model and active.out and active.out.lock and active.out.lock > 1e-3 then
		steer = -(active.out.steerAngle or 0) / active.out.lock
	end
	local lock = (cfg.Handling and cfg.Handling.SteeringLockDeg) or 35
	local wheelDeg = steer * lock * (N.SteerRatio or 14)
	local lookT = softClip(-math.rad(wheelDeg) * (N.SteerFollow or 0), math.rad(N.SteerMax or 20))
	neck.look += (lookT - neck.look) * (1 - math.exp(-dt / math.max(N.Smoothing or 0.08, 1e-3)))
	local spm = geometry(model).spm
	local m = on * k
	-- repère : X à droite, Y en haut, −Z vers l'avant (la tête recule de dz, part de −dx, descend de dy)
	return CFrame.new(Vector3.new(-dx, -dy, dz) * m * spm)
		* CFrame.Angles(0, yaw * m + neck.look, 0) * CFrame.Angles(pitch * m, 0, 0) * CFrame.Angles(0, 0, roll * m)
end

local function cockpitCFrame(model, seat, root, dt, char)
	local eye = Pose.EyeWorld(model, seat)
	local g = geometry(model)
	updateDynamics(root, g, dt)
	-- angle fixe (Assetto Corsa) : la vue ne tourne que pendant qu'on regarde (clic droit, stick, doigt) et revient
	-- droit devant dès qu'on lâche
	local basePitch = -math.rad(Camera.Settings.Cockpit.Pitch or Camera.StartPitch)
	if not state.looking then
		local k = lerpK(8, dt)
		state.yaw -= state.yaw * k
		state.pitch += (basePitch - state.pitch) * k
	end
	-- regarder derrière : par-dessus l'épaule (LookBack degrés), transition lissée
	local backT = anyDown(Camera.LookBackKeys) and math.rad(Camera.Settings.Cockpit.LookBack or 130) or 0
	neck.back += (backT - neck.back) * lerpK(12, dt)
	local head = neckPose(model, root, dt)
	-- l'œil GTA du siège est un peu loin du volant par rapport aux vues cockpit de référence : avance réglable (m)
	local fwd = (Camera.Settings.Cockpit.Forward or 0) * g.spm
	local cf = CFrame.new(eye) * root.CFrame.Rotation * CFrame.new(0, 0, -fwd) * head
		* CFrame.Angles(0, state.yaw + neck.back, 0) * CFrame.Angles(state.pitch, 0, 0)
	setBody(char, true)
	return cf, Camera.Settings.Cockpit.Fov or 100
end

-- caméra de Roblox (véhicule avec ChaseCamera = false) : pivot sur l'œil du conducteur
local function setOffset(hum, eye)
	local hrp = hum.RootPart
	local h = (hum.RigType == Enum.HumanoidRigType.R15 and hum.AutomaticScalingEnabled) and (1.5 + (hrp.Size.Y - 2) / 2)
		or 1.5
	hum.CameraOffset = hrp.CFrame:VectorToObjectSpace(eye - hrp.Position) - Vector3.new(0, h, 0)
	state.offsetHum = hum
end
local function clearOffset()
	if state.offsetHum then
		if state.offsetHum.Parent then
			state.offsetHum.CameraOffset = Vector3.zero
		end
		state.offsetHum = nil
	end
end

local function leave(char)
	local cam = Workspace.CurrentCamera
	if state.view then
		local wasPov = state.view == "Cockpit"
		state.view = nil
		cam.CameraType = Enum.CameraType.Custom
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if hum then
			cam.CameraSubject = hum
		end
		if state.fovBefore then
			cam.FieldOfView = state.fovBefore
			state.fovBefore = nil
		end
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
		setBody(char, false)
		if not wasPov and player.CameraMode ~= Enum.CameraMode.LockFirstPerson then
			-- la caméra de Roblox reprend au plus près : on l'éloigne une image par la distance minimale
			local was = player.CameraMinZoomDistance
			player.CameraMinZoomDistance = math.min(Camera.ExitZoom, player.CameraMaxZoomDistance)
			task.delay(0.1, function()
				player.CameraMinZoomDistance = was
			end)
		end
		changed:Fire(Camera.GetSettings(), nil)
	end
	state.model = nil
	clearOffset()
end

local started = false
function Camera.Start()
	if started then
		return
	end
	started = true

	local function cycle(_, inputState)
		if inputState ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		if occupied() then
			Camera.CycleView()
		end
		return Enum.ContextActionResult.Sink
	end
	local bound = false
	local function bindCycle(on)
		if on and not bound then
			ContextActionService:BindAction("F2R_View", cycle, true, Camera.ToggleKey)
			ContextActionService:SetTitle("F2R_View", "Vue")
		elseif not on and bound then
			ContextActionService:UnbindAction("F2R_View")
		end
		bound = on
	end

	local rmb = false
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if not state.view then
			return
		end
		if input.UserInputType == Enum.UserInputType.Touch then
			state.touches[input] = true
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			rmb = true
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		state.touches[input] = nil
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			rmb = false
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if not state.view then
			return
		end
		if input.UserInputType == Enum.UserInputType.Touch and state.touches[input] then
			look(-input.Delta.X * 0.0045, -input.Delta.Y * 0.0045)
		end
	end)

	RunService:BindToRenderStep("F2R_VehicleCamera", Enum.RenderPriority.Camera.Value + 1, function(dt)
		state.t += dt
		local model, seat, hum, char = occupied()
		local anyView = model ~= nil and (enabledChase(model) or enabledPov(model, seat))
		bindCycle(anyView)
		if not model then
			leave(player.Character)
			return
		end
		local cam = Workspace.CurrentCamera
		if model ~= state.model then
			-- entrée : cockpit si on était en première personne, sinon la dernière vue extérieure
			leave(char)
			state.model = model
			local firstPerson = player.CameraMode == Enum.CameraMode.LockFirstPerson
				or (cam.CFrame.Position - cam.Focus.Position).Magnitude < 1
			local want = firstPerson and "Cockpit" or (state.lastOutside or Camera.Settings.DefaultView)
			if not viewAllowed(model, seat, want) then
				want = nil
				for _, v in ipairs(Camera.Views) do
					if viewAllowed(model, seat, v) then
						want = v
						break
					end
				end
			end
			if want then
				state.fovBefore = cam.FieldOfView
				setView(want, char)
			end
		end
		if not state.view then
			-- aucune de nos vues : caméra de Roblox pivotant sur l'œil
			local eye = Pose.EyeWorld(model, seat)
			if eye then
				setOffset(hum, eye)
			end
			return
		end
		clearOffset()

		cam.CameraType = Enum.CameraType.Scriptable
		local aiming = targeting()
		local sens = UserSettings():GetService("UserGameSettings").MouseSensitivity
		-- toutes les vues : souris libre, clic droit maintenu pour regarder autour (comme la caméra de Roblox et
		-- Assetto Corsa) ; le cockpit garde un angle fixe le reste du temps
		if not aiming then
			UserInputService.MouseBehavior = rmb and Enum.MouseBehavior.LockCurrentPosition or Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
		end
		local looking = rmb or next(state.touches) ~= nil
		local d = aiming and Vector2.zero or UserInputService:GetMouseDelta()
		if d.Magnitude > 0 and rmb then
			look(-d.X * 0.002 * math.pi * sens, -d.Y * 0.0015 * math.pi * sens)
		end
		for _, pad in ipairs(UserInputService:GetConnectedGamepads()) do
			for _, st in ipairs(UserInputService:GetGamepadState(pad)) do
				if st.KeyCode == Enum.KeyCode.Thumbstick2 and st.Position.Magnitude > 0.2 then
					look(-st.Position.X * 4 * dt, st.Position.Y * 3 * dt)
					looking = true
				end
			end
		end
		state.looking = looking

		local root = model.PrimaryPart
		local cf, fov
		if state.view == "Cockpit" then
			cf, fov = cockpitCFrame(model, seat, root, dt, char)
		elseif state.view == "Bonnet" then
			cf, fov = bonnetCFrame(model, seat, root, dt)
			setBody(char, false)
		else
			cf, fov = chaseCFrame(model, root, dt, Camera.Settings[state.view] or Camera.Settings.Chase)
			setBody(char, false)
		end
		cam.CFrame = cf
		cam.Focus = cf
		cam.FieldOfView = fov
	end)
end

return Camera
