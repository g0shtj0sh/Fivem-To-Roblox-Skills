--!nonstrict
--[[
	VehicleDashboard — tableau de bord du véhicule (client) : les valeurs à afficher, et un compteur de vitesse
	simple pour le conducteur local.

		local Dashboard = require(ReplicatedStorage.FiveMVehicles.VehicleDashboard)
		local d = Dashboard.Read(model)        -- valeurs à l'instant (table ci-dessous), nil sans rendu attaché
		Dashboard.Start(model) / Dashboard.Stop()  -- compteur intégré ; FiveMVehiclesClient l'appelle au volant

	Le compteur intégré s'adapte au véhicule par sa configuration, sans réglage :
	- vitesse lue sur VehicleRoot (même valeur que le moteur de conduite), unité km/h ou mph ;
	- rapport engagé (« R » en marche arrière, « N » moteur coupé, « D » pour une boîte électrique à un rapport) ;
	- barre de régime entre le ralenti et le rupteur du véhicule (`Audio.IdleRpm` / `Audio.MaxRpm`), zone rouge
	  sur les 10 derniers %.

	Réglages (attributs, sur ReplicatedStorage.FiveMVehicles pour tout le jeu, ou sur un véhicule) :
	- `BuiltinSpeedometer = false` : pas de compteur intégré (un HUD du jeu lit alors Dashboard.Read) ;
	- `SpeedUnit = "mph"` (défaut "kmh").

	Dashboard.Read(model) renvoie :
		SpeedMs     m/s, signé (+ = avant)            Speed      |vitesse| dans l'unité, lissée comme l'affichage
		Unit        "km/h" ou "mph"                    TopSpeed   vitesse de pointe estimée, dans l'unité
		DialMax     haut d'un cadran (TopSpeed + 10 %, arrondi à 20)
		Gear        texte du rapport ("R", "N", "D", "1".."n")   GearNumber -1 (arrière), 1..n
		GearCount   nombre de rapports avant          Rpm        tr/min (sons du véhicule)
		Rpm01       0 au ralenti, 1 au rupteur          RpmGta     même valeur à l'échelle GTA (0,2 ralenti, 1 rupteur)
		Redline     true dans les 10 derniers % du régime
		Engine, Headlights (0/1/2), Indicator ("Off", "Left", "Right", "Hazard"), Brake, Reverse
		DashboardType  type de tableau de bord GTA (`vehicles.meta`), "" s'il est inconnu

	Référence GTA V (pourquoi ces valeurs) : GTA V n'affiche aucun compteur dans son HUD ; la vitesse se lit sur
	les cadrans du tableau de bord intérieur, dont le modèle est choisi par `dashboardType` (`vehicles.meta`,
	VDT_*) avec une graduation propre au modèle (et non au véhicule : un cadran plafonne, d'où des aiguilles
	fausses sur les véhicules de mod). Les HUD des serveurs FiveM reconstruisent donc un compteur à partir des
	natives : vitesse de l'entité en m/s (×3,6 en km/h, ×2,236936 en mph), régime normalisé 0,2 (ralenti)
	→ 1,0 (rupteur), rapport engagé (0 = marche arrière), état du moteur et des feux. On expose les mêmes
	grandeurs, à partir de la configuration convertie (handling.meta) et de l'état du rendu.
]]
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Runtime = require(script.Parent:WaitForChild("VehicleRuntime"))

local Dashboard = {}

local KMH, MPH = 3.6, 2.2369363
local SPEED_SMOOTH, RPM_SMOOTH = 10, 14 -- 1/s : lissage exponentiel indépendant de la cadence d'image
local REDLINE = 0.9

local function folderAttr(model, name)
	local v = model and model:GetAttribute(name)
	if v ~= nil then
		return v
	end
	local f = ReplicatedStorage:FindFirstChild("FiveMVehicles")
	return f and f:GetAttribute(name)
end

function Dashboard.Enabled(model)
	return folderAttr(model, "BuiltinSpeedometer") ~= false
end

-- lissage par véhicule (Speed lissée partagée entre Read et l'affichage)
local smooth = setmetatable({}, { __mode = "k" })

function Dashboard.Read(model, dt)
	local r = Runtime.Get(model)
	if not r then
		return nil
	end
	local cfg = r.Config or {}
	local h = cfg.Handling or {}
	local a = cfg.Audio or {}
	local s = r.State or {}
	local mph = string.lower(tostring(folderAttr(model, "SpeedUnit") or "kmh")) == "mph"
	local k = mph and MPH or KMH

	local speedMs = s.Speed or 0
	local electric = h.Gearbox == "electric"
	local gearCount = electric and 1 or math.max(1, h.Gears or 6)
	local engine = model:GetAttribute("Engine") == true
	local reverse = (s.Gear ~= nil and s.Gear < 0) or s.Reverse == true and speedMs < -0.5

	local idle, maxRpm = a.IdleRpm or 850, a.MaxRpm or 7200
	local rpm = engine and (s.Rpm or idle) or 0
	local rpm01 = engine and math.clamp((rpm - idle) / math.max(maxRpm - idle, 1), 0, 1) or 0

	local st = smooth[model]
	if not st then
		st = { speed = math.abs(speedMs) * k, rpm = rpm01 }
		smooth[model] = st
	end
	if dt then
		st.speed += (math.abs(speedMs) * k - st.speed) * (1 - math.exp(-SPEED_SMOOTH * dt))
		st.rpm += (rpm01 - st.rpm) * (1 - math.exp(-RPM_SMOOTH * dt))
	end

	local gear
	if not engine then
		gear = "N"
	elseif reverse then
		gear = "R"
	elseif electric then
		gear = "D"
	else
		gear = tostring(math.clamp(s.Gear or 1, 1, gearCount))
	end

	-- vitesse de pointe : vitesse au rupteur sur le dernier rapport (convertisseur), sinon handling brut
	local topKmh = h.RedlineTopGearKmh or ((h.MaxFlatVelKmh or 160) * 1.2 / 0.9)
	local top = topKmh / 3.6 * k
	local dialMax = math.max(20, math.ceil(top * 1.1 / 20) * 20)

	return {
		SpeedMs = speedMs,
		Speed = st.speed,
		Unit = mph and "mph" or "km/h",
		TopSpeed = top,
		DialMax = dialMax,
		Gear = gear,
		GearNumber = reverse and -1 or (s.Gear or 1),
		GearCount = gearCount,
		Rpm = rpm,
		Rpm01 = st.rpm,
		RpmGta = engine and (0.2 + 0.8 * st.rpm) or 0,
		Redline = engine and st.rpm >= REDLINE,
		Engine = engine,
		Headlights = model:GetAttribute("Headlights") or 0,
		Indicator = model:GetAttribute("Indicator") or "Off",
		Brake = s.Brake == true,
		Reverse = reverse,
		DashboardType = cfg.DashboardType or "",
	}
end

-- ------------------------------------------------------------------ compteur intégré
-- Volontairement sobre (le jeu le remplace quand il a sa charte) : gros chiffres blancs cerclés de noir,
-- lisibles sur le ciel comme sur l'asphalte, sans plaque ; en bas au centre, hors des contrôles tactiles
-- (stick à gauche, boutons à droite) et dans la zone sûre de Roblox.
local FONT = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.ExtraBold)
local FONT_BOLD = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Bold)
local WHITE = Color3.fromRGB(255, 255, 255)
local INK = Color3.fromRGB(10, 12, 16)
local RED = Color3.fromRGB(255, 72, 60)

local function label(parent, name, font, size, pos, xAlign, text)
	local t = Instance.new("TextLabel")
	t.Name = name
	t.BackgroundTransparency = 1
	t.FontFace = font
	t.TextSize = size
	t.TextColor3 = WHITE
	t.TextXAlignment = xAlign
	t.TextYAlignment = Enum.TextYAlignment.Bottom
	t.Position = UDim2.fromOffset(pos[1], pos[2])
	t.Size = UDim2.fromOffset(pos[3], pos[4])
	t.Text = text
	local stroke = Instance.new("UIStroke")
	stroke.Color = INK
	stroke.Thickness = math.max(1.5, size / 22)
	stroke.Transparency = 0.25
	stroke.Parent = t
	t.Parent = parent
	return t
end

local function rounded(f, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = f
end

local function build()
	local gui = Instance.new("ScreenGui")
	gui.Name = "F2R_Speedometer"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 5

	local root = Instance.new("Frame")
	root.Name = "Speedometer"
	root.AnchorPoint = Vector2.new(0.5, 1)
	root.Position = UDim2.new(0.5, 0, 1, -16)
	root.Size = UDim2.fromOffset(220, 84)
	root.BackgroundTransparency = 1
	root.Parent = gui
	local scale = Instance.new("UIScale")
	scale.Parent = root

	-- vitesse (alignée à droite contre le rapport et l'unité)
	local speed = label(root, "Speed", FONT, 60, { 0, 0, 148, 66 }, Enum.TextXAlignment.Right, "0")
	local gear = label(root, "Gear", FONT, 30, { 156, 6, 64, 32 }, Enum.TextXAlignment.Left, "N")
	local unit = label(root, "Unit", FONT_BOLD, 16, { 157, 40, 64, 20 }, Enum.TextXAlignment.Left, "KM/H")
	unit.TextTransparency = 0.1

	-- régime : piste sombre, zone rouge fixe, remplissage blanc (rouge au rupteur)
	local track = Instance.new("Frame")
	track.Name = "Rpm"
	track.Position = UDim2.fromOffset(10, 72)
	track.Size = UDim2.fromOffset(200, 7)
	track.BackgroundColor3 = INK
	track.BackgroundTransparency = 0.45
	track.BorderSizePixel = 0
	rounded(track, 4)
	track.Parent = root
	local zone = Instance.new("Frame")
	zone.Name = "Redline"
	zone.Position = UDim2.fromScale(REDLINE, 0)
	zone.Size = UDim2.fromScale(1 - REDLINE, 1)
	zone.BackgroundColor3 = RED
	zone.BackgroundTransparency = 0.45
	zone.BorderSizePixel = 0
	rounded(zone, 4)
	zone.Parent = track
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = WHITE
	fill.BorderSizePixel = 0
	fill.ZIndex = 2
	rounded(fill, 4)
	fill.Parent = track

	return gui, { root = root, scale = scale, speed = speed, gear = gear, unit = unit, fill = fill }
end

-- échelle d'écran : 1 sur un écran de 720 px de haut, bornée pour que l'unité reste ≥ 12 px dessinés
local function screenScale()
	local cam = Workspace.CurrentCamera
	local y = cam and cam.ViewportSize.Y or 720
	return math.clamp(y / 720, 0.78, 1.5)
end

local active = nil

function Dashboard.Stop()
	if active then
		active.conn:Disconnect()
		active.gui:Destroy()
		active = nil
	end
end

function Dashboard.Start(model)
	if active and active.model == model then
		return
	end
	Dashboard.Stop()
	local player = Players.LocalPlayer
	local pg = player and player:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return
	end
	local gui, ui = build()
	gui.Parent = pg
	active = { model = model, gui = gui }
	active.conn = RunService.RenderStepped:Connect(function(dt)
		if model.Parent == nil then
			Dashboard.Stop()
			return
		end
		local d = Dashboard.Enabled(model) and Dashboard.Read(model, dt)
		gui.Enabled = d ~= nil and d ~= false
		if not gui.Enabled then
			return
		end
		ui.scale.Scale = screenScale()
		ui.speed.Text = tostring(math.floor(d.Speed + 0.5))
		ui.gear.Text = d.Gear
		ui.unit.Text = string.upper(d.Unit)
		ui.fill.Size = UDim2.fromScale(d.Rpm01, 1)
		ui.fill.BackgroundColor3 = d.Redline and RED or WHITE
	end)
end

return Dashboard
