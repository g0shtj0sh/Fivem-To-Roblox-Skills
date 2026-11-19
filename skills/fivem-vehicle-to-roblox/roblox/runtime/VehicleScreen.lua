--!nonstrict
-- FiveMVehicles/VehicleScreen (ModuleScript, client)
-- Combiné d'instruments VIVANT dans l'habitacle : un écran (SurfaceGui) posé exactement sur l'image du combiné du
-- modèle (même texture, même cadrage) et, par-dessus, ce qui bouge — vitesse, rapport, remplissage des arcs de
-- vitesse et de régime, heure du jeu. Dans GTA ces éléments sont dessinés par le jeu dans une texture ; ici l'image
-- d'origine reste la base et seuls les éléments vivants sont ajoutés (demande de l'utilisateur, 2026-11-16 : « le plus
-- possible comme la texture du modèle »).
--
-- Mise en page par véhicule (VehicleConfig.ClusterScreen), en PIXELS de la texture du combiné :
--   Origin, Du, Dv : point (u, v) de la texture -> position (m, repère du véhicule) = Origin + Du·u + Dv·v
--                   (ajustement affine sur les sommets de la pièce d'écran, scripts du jeu)
--   TextureSize {W, H}, Crop {x0, y0, x1, y1}, Image = id de la texture (ou de son recadrage)
--   HideParts = { "nom", … } : pièces du modèle masquées chez le joueur tant que l'écran vit (ex. l'écran générique
--                GTA « script_rt_dials » posé sur le combiné : barres et « 888 » figés)
--   Elements = { { Kind = "cover"|"gear"|"speed"|"unit"|"clock"|"arc", Rect = {x, y, w, h} | Points = {{x, y}…},
--                 Size, Align, Value = "speed"|"rpm", Width, Color = {r, g, b} } }
--   Needles = { { Value = "speed"|"rpm"|"fuel"|"temp", Origin, Du, Dv, TextureSize (repère du CADRAN : îlot UV de la
--                pièce, souvent différent de celui de l'écran), Pivot = {x, y} px, Min, Max, A0, A1 (degrés, sens horaire
--                depuis le haut de la texture, à Min / à Max), Length, Tail, Width (px), Color, Lift (m, défaut 0,0008) } }
--                aiguilles 3D (fines pièces soudées à VehicleRoot, tournées à chaque image) ; Néon phares allumés.
--                fuel : attribut Fuel (0..1, ou 0..100) du véhicule, sinon 0,75 ; temp : chauffe en ~40 s moteur tournant.
--   HideAlways = true : HideParts masquées chez tous les clients, tout le temps (cadrans génériques GTA « script_rt »,
--                redessinés par le jeu dans GTA : sans lui ils restent blancs avec des aiguilles figées).
-- Construit seulement pour le véhicule où le joueur local est assis ; détruit à la descente.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

local Screen = {}
Screen.Rate = 20 -- mises à jour par seconde
Screen.Font = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold)

local folder = script.Parent
local active -- { model, part, gui, update }
local buildNeedlesOnly -- défini plus bas (aiguilles)

local function c3(t, default)
	return type(t) == "table" and Color3.fromRGB(t[1], t[2], t[3]) or default
end

local function seatedModel()
	local hum = Players.LocalPlayer.Character and Players.LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.SeatPart
	local m = seat and seat.Parent and seat.Parent.Name == "Seats" and seat.Parent.Parent
	return m and m:FindFirstChild("VehicleConfig") and m.PrimaryPart and m or nil
end

-- ------------------------------------------------------------------ aiguilles
local NEEDLE_RATE = 10 -- lissage (1/s) des aiguilles d'essence et de température
local warm = setmetatable({}, { __mode = "k" }) -- modèle -> température 0..1 (chauffe / refroidit)

local function v3(t)
	return Vector3.new(t[1], t[2], t[3])
end

local function makeNeedles(model, cfg, L)
	local spm = cfg.StudsPerMeter or 3.571
	local root = model.PrimaryPart
	local list = {}
	for i, n in ipairs(L.Needles or {}) do
		local W, H = n.TextureSize and n.TextureSize[1] or 1024, n.TextureSize and n.TextureSize[2] or 1024
		local O, Du, Dv = v3(n.Origin), v3(n.Du), v3(n.Dv)
		local function map(px, py) -- pixel du cadran -> position (studs, repère de VehicleRoot)
			return (O + Du * (px / W) + Dv * (py / H)) * spm
		end
		local normal = Du:Cross(Dv).Unit
		if normal.Z < 0 then -- face vers le conducteur (habitacle vers +Z, avant du véhicule vers -Z)
			normal = -normal
		end
		local pxScale = (Du.Magnitude / W + Dv.Magnitude / H) / 2 * spm -- studs par pixel
		local part = Instance.new("Part")
		part.Name = "F2R_Needle_" .. tostring(n.Value or i)
		part.Size = Vector3.new((n.Width or 10) * pxScale, ((n.Length or 200) + (n.Tail or 30)) * pxScale, 0.0012 * spm)
		part.Color = c3(n.Color, Color3.fromRGB(255, 70, 20))
		part.Material = Enum.Material.SmoothPlastic
		part.CanCollide, part.CanTouch, part.CanQuery, part.Massless = false, false, false, true
		part.CastShadow = false
		part.CFrame = root.CFrame
		local weld = Instance.new("Weld")
		weld.Part0, weld.Part1 = root, part
		weld.Parent = part
		part.Parent = model
		local entry = { spec = n, part = part, weld = weld, map = map, normal = normal, lift = (n.Lift or 0.0008) * spm, shown = nil }
		function entry.set(angleDeg)
			local a = math.rad(angleDeg)
			local s, c = math.sin(a), -math.cos(a) -- direction dans la texture (y vers le bas)
			local px, py = n.Pivot[1], n.Pivot[2]
			local tip = map(px + s * (n.Length or 200), py + c * (n.Length or 200))
			local tail = map(px - s * (n.Tail or 30), py - c * (n.Tail or 30))
			local y = (tip - tail).Unit
			local x = y:Cross(entry.normal).Unit
			local z = x:Cross(y).Unit
			weld.C0 = CFrame.fromMatrix((tip + tail) / 2 + entry.normal * entry.lift, x, y, z)
		end
		table.insert(list, entry)
	end
	return list
end

local function needleValue(model, entry, d, dt)
	local n = entry.spec
	local v
	if n.Value == "rpm" then
		v = d.Engine == false and 0 or (d.Rpm or 0)
	elseif n.Value == "fuel" then
		local f = model:GetAttribute("Fuel")
		f = type(f) == "number" and (f > 1 and f / 100 or f) or 0.75
		local target = d.Engine == false and 0 or f -- contact coupé : l'aiguille retombe, comme sur l'E36
		entry.smooth = (entry.smooth or 0) + (target - (entry.smooth or 0)) * (1 - math.exp(-NEEDLE_RATE * 0.3 * dt))
		v = entry.smooth
	elseif n.Value == "temp" then
		local t = warm[model] or 0
		if d.Engine then
			t = math.min(0.5, t + dt / 80) -- ~40 s pour atteindre le milieu
		else
			t = math.max(0, t - dt / 240)
		end
		warm[model] = t
		v = t
	else -- speed
		local kmh = math.abs(d.SpeedMs or 0) * 3.6
		if d.Speed and d.Unit then
			kmh = d.Unit == "mph" and d.Speed * 1.609344 or d.Speed -- valeur lissée par VehicleDashboard
		end
		v = n.Unit == "mph" and kmh / 1.609344 or kmh
	end
	local mn, mx = n.Min or 0, n.Max or 1
	local t = math.clamp((v - mn) / math.max(mx - mn, 1e-6), 0, 1.04) -- un poil au-delà de la butée
	return (n.A0 or -120) + t * ((n.A1 or 120) - (n.A0 or -120))
end

local function updateNeedles(model, list, d, dt)
	local lit = (d.Headlights or 0) > 0
	for _, e in ipairs(list) do
		e.set(needleValue(model, e, d, dt))
		if e.shown ~= lit then
			e.part.Material = lit and Enum.Material.Neon or Enum.Material.SmoothPlastic
			e.shown = lit
		end
	end
end

local function hideParts(model, L, hidden)
	for _, name in ipairs(L.HideParts or {}) do
		local hp = model:FindFirstChild(name, true)
		if hp and hp:IsA("BasePart") then
			if hidden and hidden[hp] == nil then
				hidden[hp] = hp.LocalTransparencyModifier
			end
			hp:SetAttribute("F2R_ScreenHidden", true) -- respecté par les niveaux de détail (VehicleRuntime)
			hp.LocalTransparencyModifier = 1
		end
	end
end

-- Combiné sans écran (Origin/Crop absents) : seulement des aiguilles et des pièces masquées.
buildNeedlesOnly = function(model, cfg, L)
	local needles = makeNeedles(model, cfg, L)
	local hidden = {}
	if not L.HideAlways then
		hideParts(model, L, hidden)
	end
	local Dashboard = require(folder:WaitForChild("VehicleDashboard"))
	local holder = Instance.new("Folder")
	return {
		model = model,
		part = holder,
		gui = Instance.new("Folder"),
		hidden = hidden,
		needles = needles,
		everyFrame = true,
		update = function(dt)
			local d = Dashboard.Read(model, dt) or {}
			updateNeedles(model, needles, d, dt)
		end,
	}
end

local function build(model)
	local cfg = require(model.VehicleConfig)
	local L = cfg.ClusterScreen
	if type(L) ~= "table" then
		return nil
	end
	if not (L.Origin and L.Crop) then
		return L.Needles and buildNeedlesOnly(model, cfg, L) or nil
	end
	local spm = cfg.StudsPerMeter or 3.571
	local W, H = L.TextureSize[1], L.TextureSize[2]
	local x0, y0, x1, y1 = L.Crop[1], L.Crop[2], L.Crop[3], L.Crop[4]
	local O = Vector3.new(L.Origin[1], L.Origin[2], L.Origin[3])
	local Du = Vector3.new(L.Du[1], L.Du[2], L.Du[3])
	local Dv = Vector3.new(L.Dv[1], L.Dv[2], L.Dv[3])
	local function at(px, py)
		return (O + Du * (px / W) + Dv * (py / H)) * spm
	end
	local center = at((x0 + x1) / 2, (y0 + y1) / 2)
	local right = Du.Unit
	local up = -Dv.Unit
	local look = up:Cross(-right) -- face avant tournée vers le conducteur
	center += look * 0.0015 * spm -- un poil devant l'image, sans la masquer de travers
	local root = model.PrimaryPart
	local part = Instance.new("Part")
	part.Name = "F2R_ClusterScreen"
	part.Size = Vector3.new(Du.Magnitude * (x1 - x0) / W * spm, Dv.Magnitude * (y1 - y0) / H * spm, 0.01)
	part.CFrame = root.CFrame * CFrame.fromMatrix(center, -right, up)
	part.Transparency = 1
	part.CanCollide, part.CanTouch, part.CanQuery, part.Massless = false, false, false, true
	part.CastShadow = false
	local weld = Instance.new("WeldConstraint")
	weld.Part0, weld.Part1 = root, part
	weld.Parent = part
	part.Parent = model

	local gui = Instance.new("SurfaceGui")
	gui.Name = "F2R_Cluster"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = Vector2.new(x1 - x0, y1 - y0)
	gui.LightInfluence = 0
	gui.Brightness = 1.6
	gui.ResetOnSpawn = false
	gui.Adornee = part
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function rect(r)
		return UDim2.fromOffset(r[1] - x0, r[2] - y0), UDim2.fromOffset(r[3], r[4])
	end
	local updaters = {}
	for _, e in ipairs(L.Elements or {}) do
		if e.Kind == "cover" then
			local f = Instance.new("Frame")
			f.Position, f.Size = rect(e.Rect)
			f.BackgroundColor3 = c3(e.Color, Color3.new(0, 0, 0))
			f.BorderSizePixel = 0
			f.Parent = gui
		elseif e.Kind == "arc" then
			-- remplissage le long d'une ligne brisée (centre de la bande de l'arc), en N segments
			local pts = {}
			for _, p in ipairs(e.Points) do
				table.insert(pts, Vector2.new(p[1] - x0, p[2] - y0))
			end
			local lens, total = {}, 0
			for i = 1, #pts - 1 do
				lens[i] = (pts[i + 1] - pts[i]).Magnitude
				total += lens[i]
			end
			local n = e.Segments or 28
			local segs = {}
			for k = 1, n do
				local d = (k - 0.5) / n * total
				local i, acc = 1, 0
				while i < #pts - 1 and acc + lens[i] < d do
					acc += lens[i]
					i += 1
				end
				local a, b = pts[i], pts[i + 1]
				local t = math.clamp((d - acc) / lens[i], 0, 1)
				local p = a:Lerp(b, t)
				local dir = (b - a).Unit
				local f = Instance.new("Frame")
				f.AnchorPoint = Vector2.new(0.5, 0.5)
				f.Position = UDim2.fromOffset(p.X, p.Y)
				f.Size = UDim2.fromOffset(e.Width or 14, total / n + 1.5)
				f.Rotation = math.deg(math.atan2(dir.Y, dir.X)) - 90
				f.BackgroundColor3 = c3(e.Color, Color3.fromRGB(225, 30, 40))
				f.BorderSizePixel = 0
				f.Visible = false
				f.Parent = gui
				segs[k] = f
			end
			table.insert(updaters, function(d)
				local v = 0
				if e.Value == "rpm" then
					v = (d.Rpm or 0) / (e.Max or 8000)
				else
					v = (d.Speed or 0) / math.max(e.Max or d.TopSpeed or 300, 1)
				end
				local lit = math.floor(math.clamp(v, 0, 1) * n + 0.5)
				for k, f in ipairs(segs) do
					f.Visible = k <= lit
				end
			end)
		else
			local t = Instance.new("TextLabel")
			t.Position, t.Size = rect(e.Rect)
			t.BackgroundTransparency = 1
			t.FontFace = Screen.Font
			t.TextSize = e.Size or 24
			t.TextColor3 = c3(e.Color, Color3.fromRGB(245, 245, 245))
			t.TextXAlignment = e.Align == "right" and Enum.TextXAlignment.Right
				or e.Align == "left" and Enum.TextXAlignment.Left or Enum.TextXAlignment.Center
			t.Text = ""
			t.Parent = gui
			table.insert(updaters, function(d)
				if e.Kind == "gear" then
					t.Text = d.Gear or ""
				elseif e.Kind == "speed" then
					t.Text = tostring(math.floor((d.Speed or 0) + 0.5))
				elseif e.Kind == "unit" then
					t.Text = d.Unit or "km/h"
				elseif e.Kind == "clock" then
					local h = Lighting.ClockTime
					t.Text = string.format("%02d:%02d", math.floor(h), math.floor((h % 1) * 60))
				end
			end)
		end
	end
	local hidden = {}
	if not L.HideAlways then
		hideParts(model, L, hidden)
	end
	local needles = L.Needles and makeNeedles(model, cfg, L) or nil
	local Dashboard = require(folder:WaitForChild("VehicleDashboard"))
	return {
		model = model,
		part = part,
		gui = gui,
		hidden = hidden,
		needles = needles,
		everyFrame = needles ~= nil,
		update = function(dt)
			local d = Dashboard.Read(model, dt) or {}
			if needles then
				updateNeedles(model, needles, d, dt)
			end
			if d.Engine == false then
				d.Speed, d.Rpm = d.Speed or 0, 0
			end
			for _, u in ipairs(updaters) do
				u(d)
			end
		end,
	}
end

local function stop()
	if active then
		for hp, v in pairs(active.hidden or {}) do
			if hp.Parent then
				hp:SetAttribute("F2R_ScreenHidden", nil)
				hp.LocalTransparencyModifier = v
			end
		end
		for _, e in ipairs(active.needles or {}) do
			e.part:Destroy()
		end
		active.gui:Destroy()
		active.part:Destroy()
		active = nil
	end
end

-- HideAlways : pièces masquées chez ce client sur tous les véhicules qui le demandent (pas seulement le sien).
local function prepare(model)
	task.spawn(function()
		local cfgModule = model:WaitForChild("VehicleConfig", 30)
		if not cfgModule then
			return
		end
		local ok, cfg = pcall(require, cfgModule)
		local L = ok and type(cfg) == "table" and cfg.ClusterScreen
		if type(L) == "table" and L.HideAlways and L.HideParts then
			local t0 = os.clock() -- streaming : les pièces (sous Visual/<os>/) peuvent arriver après le modèle
			for _, name in ipairs(L.HideParts) do
				while not model:FindFirstChild(name, true) and os.clock() - t0 < 10 and model.Parent do
					task.wait(0.25)
				end
			end
			hideParts(model, L, nil)
		end
	end)
end

function Screen.Start()
	local CollectionService = game:GetService("CollectionService")
	for _, m in ipairs(CollectionService:GetTagged("FiveMVehicle")) do
		prepare(m)
	end
	CollectionService:GetInstanceAddedSignal("FiveMVehicle"):Connect(prepare)
	local acc = 0
	RunService.RenderStepped:Connect(function(dt)
		local m = seatedModel()
		if not m or (active and active.model ~= m) then
			stop()
		end
		if m and not active then
			local ok, built = pcall(build, m)
			active = ok and built or nil
			if not ok then
				warn("[VehicleScreen] " .. tostring(built))
			end
			if not active then
				-- pas de combiné décrit pour ce véhicule : on ne réessaie qu'au prochain véhicule
				active = { model = m, part = Instance.new("Folder"), gui = Instance.new("Folder"), update = function() end }
			end
		end
		acc += dt
		if active and (active.everyFrame or acc >= 1 / Screen.Rate) then
			active.update(acc)
			acc = 0
		end
	end)
end

return Screen
