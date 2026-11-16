--!nonstrict
-- FiveMVehicles/VehicleRuntime (ModuleScript, client)
-- Rendu côté client d'un véhicule converti : lumières (phares, feux, stop, clignotants,
-- recul, gyrophares/sirènes), sons (moteur multi-couches, démarreur, klaxon, sirène,
-- clignotant), roues (rotation/braquage/suspension), volant, portes/capot/coffre.
--
-- AUCUNE physique ici. Ton moteur physique fournit la télémétrie (facultatif) :
--   Runtime.SetTelemetry(car, {
--       Rpm = 3500, Gear = 3, Throttle = 0.8, Brake = 0, Speed = 22.5 (m/s),
--       Steer = -0.3 (-1..1), WheelSpin = { wheel_lf = 40 (rad/s), ... },
--       Suspension = { wheel_lf = 0.02 (m, + = vers le haut), ... },
--   })
-- Sans télémétrie, le régime / la rotation des roues sont estimés depuis la vitesse du châssis.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local Runtime = {}
Runtime.__index = Runtime
Runtime.RenderDistance = 350 -- studs
Runtime.SteeringWheelDeg = 90 -- rotation du volant à pleine butée des roues (GTA, steerWheelMult = 1)

-- réglages du moteur de conduite (fondu du braquage avec la vitesse), lus une fois
local tyreFx
local function tyreFxModule()
	if tyreFx == nil then
		local m = script.Parent:FindFirstChild("VehicleTyreFx")
		local ok, mod = pcall(function()
			return m and require(m)
		end)
		tyreFx = (ok and mod) or false
	end
	return tyreFx
end

local backfire
local function backfireModule()
	if backfire == nil then
		local m = script.Parent:FindFirstChild("VehicleBackfire")
		local ok, mod = pcall(function()
			return m and require(m)
		end)
		backfire = (ok and mod) or false
	end
	return backfire
end

-- Suspension vue par les autres joueurs (passagers, piétons) : seul le conducteur simule les roues et sa télémétrie
-- ne quitte pas son PC ; ailleurs les roues restaient figées au repos pendant que la caisse répliquée bougeait
-- (signalé par l'utilisateur à deux joueurs, 2026-11-16). Chaque client sonde donc lui-même le sol sous chaque roue,
-- avec la géométrie du moteur de conduite (VehicleDrive : un spherecast par roue depuis le haut du débattement).
Runtime.SuspensionEstimateDistance = 200 -- studs de la caméra : au-delà, roues laissées telles quelles

local dynModule
local function dynamics()
	if dynModule == nil then
		local m = script.Parent:FindFirstChild("VehicleDynamics")
		local ok, Dyn = pcall(function()
			return m and require(m)
		end)
		dynModule = (ok and Dyn) or false
	end
	return dynModule
end

local dynT
local function dynTuning()
	if dynT == nil then
		local m = script.Parent:FindFirstChild("VehicleDynamics")
		local ok, Dyn = pcall(function()
			return m and require(m)
		end)
		dynT = (ok and Dyn and Dyn.Tuning) or {}
	end
	return dynT
end
Runtime.MasterVolume = 1

local renderers = {} -- [model] = renderer

local LIGHT_COLORS = {
	head = Color3.fromRGB(255, 248, 235),
	tail = Color3.fromRGB(150, 0, 0),
	brake = Color3.fromRGB(255, 20, 20),
	indicator = Color3.fromRGB(255, 120, 0),
	reverse = Color3.fromRGB(255, 255, 255),
	drl = Color3.fromRGB(255, 252, 245),
	plate = Color3.fromRGB(255, 244, 220),
}

-- Feux de croisement / pleins phares, comme GTA V (visualsettings.dat d'origine, relevé 2026-11-13 dans deux
-- sauvegardes indépendantes du fichier du jeu : VisualV « original files » et EffectsOverhaul « BaseGameBackup ») :
--   car.headlights.fullbeam.IntensityMult 1.1   car.headlights.fullbeam.DistMult 1.3
--   car.headlights.aim.dippedbeam.mod    -0.2   car.headlights.aim.fullbeam.mod  0.0
-- Les pleins phares portent PLUS LOIN (×1,3) et visent à l'horizontale ; l'intensité ne monte que de 10 %.
-- Les croisements sont baissés vers la route. Dans Roblox la portée d'un SpotLight plafonne à 60 studs : les
-- pleins phares prennent ce maximum et les croisements 60 / 1,3.
-- Tangage des croisements : −10°. Essai Studio (2026-11-13, m422 de nuit, vue de dessus) : à −3° la tache au sol
-- restait presque aussi longue qu'en pleins phares (le cône Roblox est rond, 60° soit ±30° : baisser l'axe de 3°
-- ne coupe presque rien vers l'horizon) ; à −10° elle se ramasse devant la voiture et les pleins phares portent
-- nettement plus loin. Hypothèse non vérifiée : l'`aim.dippedbeam.mod` −0,2 de GTA serait en radians (−11,5°).
-- Ancien comportement (remplacé) : même portée et même angle, luminosité doublée (3 → 6).
-- Largeur (demande de l'utilisateur, 2026-11-16 : « éclaire seulement plus loin, il faut aussi plus large ») :
-- les pleins phares ouvrent aussi le cône (60° → 100°). Dans Roblox la luminosité d'un SpotLight ne baisse pas
-- quand son angle s'ouvre : la tache s'étale sans pâlir. Le cône est rond, il monte donc aussi (±50°).
Runtime.Headlights = {
	FullRange = 60, -- studs (maximum d'un SpotLight)
	DistMult = 1.3, -- GTA fullbeam.DistMult
	IntensityMult = 1.1, -- GTA fullbeam.IntensityMult
	Brightness = 3, -- croisements
	DippedPitch = -10, -- degrés, faisceau baissé (réglé à l'essai, voir plus haut)
	FullPitch = 0,
	DippedAngle = 60, -- degrés, ouverture totale du cône en croisement (= VehicleLights.Spec.headlight.angle)
	FullAngle = 100, -- degrés, ouverture en pleins phares : plus large que les croisements
}

local function bit(seq, beat)
	-- séquenceur GTA : 32 pas, bit de poids fort = premier pas
	return bit32.band(bit32.rshift(seq, 31 - (beat % 32)), 1) == 1
end

-- ------------------------------------------------------------------ construction
function Runtime.Attach(model)
	if renderers[model] then
		return renderers[model]
	end
	local cfgModule = model:FindFirstChild("VehicleConfig")
	if not cfgModule or not model.PrimaryPart then
		return nil
	end
	local self = setmetatable({}, Runtime)
	self.Model = model
	self.Config = require(cfgModule)
	self.Root = model.PrimaryPart
	self.Spm = self.Config.StudsPerMeter or 3.571
	self.Joints = {}
	self.Hinge = {}
	self.SpinAngle = {}
	self.LightParts = {}
	self.LightObjects = {}
	self.SirenParts = {}
	self.LastLightState = {}
	self.Telemetry = nil
	self.TelemetryTime = 0
	self.EngineWasOn = false
	self.BlinkState = false

	local joints = model:FindFirstChild("Joints", true)
	if joints then
		for _, m in ipairs(joints:GetChildren()) do
			if m:IsA("Motor6D") then
				self.Joints[m:GetAttribute("Bone") or m.Name] = m
			end
		end
	end
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			local role = d:GetAttribute("LightRole")
			if role then
				self.LightParts[role] = self.LightParts[role] or {}
				table.insert(self.LightParts[role], d)
			end
			local siren = d:GetAttribute("Siren")
			if siren then
				self.SirenParts[siren] = self.SirenParts[siren] or {}
				table.insert(self.SirenParts[siren], d)
			end
		elseif d:IsA("Light") and d.Parent and d.Parent:IsA("Attachment") then
			local role = d.Parent:GetAttribute("LightRole")
			if role then
				self.LightObjects[role] = self.LightObjects[role] or {}
				table.insert(self.LightObjects[role], d)
			end
		end
	end
	self:_prepareSuspensionHinges()
	self.Sounds = model:FindFirstChild("Sounds", true)
	self:_prepareAudio()
	-- son moteur changé en jeu (custom « EngineSound ») : les couches sont refaites avec les boucles de la banque
	model:GetAttributeChangedSignal("EngineSound"):Connect(function()
		if renderers[model] == self then
			self:_resetAudio()
			self:_prepareAudio()
		end
	end)
	renderers[model] = self
	model.Destroying:Connect(function()
		Runtime.Detach(model)
	end)
	return self
end

function Runtime.Detach(model)
	local r = renderers[model]
	if r then
		r:_stopAllSounds()
		for _, l in pairs(r.Layers or {}) do
			if l.group then
				l.group:Destroy()
			end
		end
		for _, snd in ipairs(r.BankSounds or {}) do
			snd:Destroy()
		end
		renderers[model] = nil
	end
end

function Runtime.Get(model)
	return renderers[model]
end

function Runtime.SetTelemetry(model, t)
	local r = renderers[model] or Runtime.Attach(model)
	if r then
		r.Telemetry = t
		r.TelemetryTime = os.clock()
	end
end

-- ------------------------------------------------------------------ état
function Runtime:_state()
	local m = self.Model
	local cfg = self.Config
	local h = cfg.Handling or {}
	local a = cfg.Audio or {}
	local idle = a.IdleRpm or 850
	local maxRpm = a.MaxRpm or 7200
	local s = {
		Engine = m:GetAttribute("Engine") == true,
		Headlights = m:GetAttribute("Headlights") or 0,
		Brake = m:GetAttribute("Brake") == true,
		Reverse = m:GetAttribute("Reverse") == true,
		Indicator = m:GetAttribute("Indicator") or "Off",
		Siren = m:GetAttribute("Siren") == true,
		SirenSound = m:GetAttribute("SirenSound") or "wail",
		Horn = m:GetAttribute("Horn") == true,
		Steer = m:GetAttribute("Steer") or 0,
		Throttle = m:GetAttribute("Throttle") or 0,
		Rpm = m:GetAttribute("Rpm"),
		Gear = m:GetAttribute("Gear"),
	}
	-- traces et fumée des autres conducteurs (VehicleTyreFx) ; le conducteur local les a dans sa télémétrie
	local fxMod = tyreFxModule()
	if fxMod then
		self.TyreFxBones = self.TyreFxBones or fxMod.Bones(cfg)
		s.TyreFx = fxMod.Unpack(m:GetAttribute("TyreFx"), self.TyreFxBones)
	end
	local vel = self.Root.AssemblyLinearVelocity
	local fwd = self.Root.CFrame.LookVector
	s.Speed = vel:Dot(fwd) / self.Spm -- m/s, signé
	-- conducteur local : ses entrées priment sur les attributs répliqués (aucune latence)
	for k, v in pairs(self.LocalOverride or {}) do
		s[k] = v
	end
	local t = self.Telemetry
	if t and os.clock() - self.TelemetryTime < 0.5 then
		for k, v in pairs(t) do
			s[k] = v
		end
	end
	-- alarme (VehicleCustomization.SetAlarm) : feux de détresse et klaxon intermittent jusqu'à AlarmUntil
	local alarmUntil = m:GetAttribute("AlarmUntil")
	if type(alarmUntil) == "number" and workspace:GetServerTimeNow() < alarmUntil then
		s.Alarm = true
		s.Indicator = "Hazard"
		s.Horn = (os.clock() % 0.9) < 0.45
	end
	s.Invisible = m:GetAttribute("Invisible") == true
	if s.Rpm == nil then
		-- estimation : boîte à N rapports répartis sur la vitesse max
		local gears = math.max(1, h.Gears or 6)
		local vmax = math.max(5, (h.MaxFlatVelKmh or 160) / 3.6)
		local v = math.abs(s.Speed)
		if v < 0.5 then
			s.Rpm = idle + (maxRpm - idle) * 0.55 * s.Throttle
			s.Gear = 1
		else
			local g = math.clamp(math.ceil(v / vmax * gears), 1, gears)
			local lo, hi = (g - 1) / gears * vmax, g / gears * vmax
			local frac = math.clamp((v - lo) / math.max(hi - lo, 0.1), 0, 1)
			s.Rpm = idle + (maxRpm - idle) * (0.35 + 0.6 * frac)
			s.Gear = g
		end
		s.Rpm = math.clamp(s.Rpm, idle, maxRpm)
	end
	if s.Reverse == false and s.Speed < -0.6 and s.Throttle == 0 then
		s.Reverse = true
	end
	return s
end

-- ------------------------------------------------------------------ roues / charnières
-- Bras de suspension (suspension_*) : une pièce GTA d'un seul tenant qui va de la caisse à la roue. La
-- translater avec la roue la détachait de la caisse quand la roue se détendait dans le vide (pièce qui
-- « vole », m422 2026-11-12). On la fait PIVOTER autour d'un axe longitudinal posé à son extrémité côté
-- caisse, de l'angle qui amène le point à l'aplomb de la roue sur le débattement de la roue. L'axe se lit
-- dans la géométrie au repos (boîte des pièces portées par l'os), donc sans rien demander à la conversion.
local function carriedParts(model, pivot)
	local out, seen, queue = {}, { [pivot] = true }, { pivot }
	while #queue > 0 do
		local p = table.remove(queue)
		table.insert(out, p)
		for _, d in ipairs(p:GetJoints()) do
			if d:IsA("WeldConstraint") or (d:IsA("JointInstance") and not d:IsA("Motor6D")) then
				local other = (d.Part0 == p) and d.Part1 or d.Part0
				if other and not seen[other] and other:IsDescendantOf(model) then
					seen[other] = true
					table.insert(queue, other)
				end
			end
		end
	end
	return out
end

function Runtime:_prepareSuspensionHinges()
	self.SuspHinge = {}
	local cfg = self.Config
	local root = self.Root
	for bone, f in pairs(cfg.WheelFollowers or {}) do
		local j = self.Joints[bone]
		local w = cfg.Wheels and cfg.Wheels[f.Wheel]
		if f.Kind == "suspension" and j and j.Part0 and j.Part1 and w then
			local wx = w.Position[1] * self.Spm
			local side = wx < 0 and -1 or 1
			local corners = {}
			local inner = math.huge
			for _, p in ipairs(carriedParts(self.Model, j.Part1)) do
				if p ~= j.Part1 or p.Transparency < 1 then
					local h = p.Size / 2
					for _, sx in ipairs({ -1, 1 }) do
						for _, sy in ipairs({ -1, 1 }) do
							for _, sz in ipairs({ -1, 1 }) do
								local q = root.CFrame:PointToObjectSpace(p.CFrame:PointToWorldSpace(Vector3.new(sx * h.X, sy * h.Y, sz * h.Z)))
								table.insert(corners, q)
								inner = math.min(inner, side * q.X)
							end
						end
					end
				end
			end
			-- hauteur du pivot : celle de l'extrémité intérieure (moyenne des coins à moins de 5 cm d'elle).
			-- À la hauteur du centre de roue, l'ancrage tournait autour d'un axe décalé et glissait de
			-- 6 à 8 cm vers l'intérieur à pleine détente (mesuré en Play, m422).
			local ySum, yN = 0, 0
			for _, q in ipairs(corners) do
				if side * q.X <= inner + 0.05 * self.Spm then
					ySum += q.Y
					yN += 1
				end
			end
			local lever = wx - side * inner -- studs, du pivot à l'aplomb de la roue (signé)
			if yN > 0 and math.abs(lever) > 0.05 * self.Spm then
				-- pivot (repère du véhicule) à l'extrémité intérieure, à sa hauteur, à la longueur du centre de roue
				local hingeRoot = Vector3.new(side * inner, ySum / yN, w.Position[3] * self.Spm)
				local frame = j.Part0.CFrame * j.C0 -- repère de Transform au repos
				local hingeWorld = root.CFrame:PointToWorldSpace(hingeRoot)
				self.SuspHinge[bone] = {
					h = frame:PointToObjectSpace(hingeWorld),
					axis = frame:VectorToObjectSpace(root.CFrame:VectorToWorldSpace(Vector3.zAxis)),
					up = frame:VectorToObjectSpace(root.CFrame.UpVector),
					lever = lever,
				}
			end
		end
	end
end

function Runtime:_updateJoints(dt, s)
	local cfg = self.Config
	local lock = math.rad((cfg.Handling and cfg.Handling.SteeringLockDeg) or 35)
	for bone, w in pairs(cfg.Wheels or {}) do
		local j = self.Joints[bone]
		if j then
			local spin
			if s.WheelSpin and s.WheelSpin[bone] then
				spin = s.WheelSpin[bone]
			else
				spin = s.Speed / math.max(w.Radius or 0.33, 0.05)
			end
			self.SpinAngle[bone] = ((self.SpinAngle[bone] or 0) - spin * dt) % (2 * math.pi)
			local steer = w.Steer and (-(s.Steer or 0) * (s.WheelSteer or lock)) or 0
			local susp = (s.Suspension and s.Suspension[bone] or 0) * self.Spm
			j.Transform = CFrame.new(0, susp, 0) * CFrame.Angles(0, steer, 0) * CFrame.Angles(self.SpinAngle[bone], 0, 0)
		end
	end
	-- étriers (hub_*) et bras de suspension (suspension_*) : suivent leur roue sans tourner avec elle ;
	-- le braquage pivote autour de l'axe vertical de la roue (Offset = centre de roue - os, en mètres)
	for bone, f in pairs(cfg.WheelFollowers or {}) do
		local j = self.Joints[bone]
		local w = cfg.Wheels and cfg.Wheels[f.Wheel]
		if j and w then
			local susp = (s.Suspension and s.Suspension[f.Wheel] or 0) * self.Spm
			local steer = (f.Steer and w.Steer) and (-(s.Steer or 0) * (s.WheelSteer or lock)) or 0
			local hinge = self.SuspHinge and self.SuspHinge[bone]
			if hinge then
				-- rotation autour de l'axe longitudinal passant par l'ancrage côté caisse : le point à
				-- l'aplomb de la roue monte ou descend de `susp` (rotation de +θ autour de Z : Δy = x·sin θ)
				local th = math.asin(math.clamp(susp / hinge.lever, -0.95, 0.95))
				j.Transform = CFrame.new(hinge.h) * CFrame.fromAxisAngle(hinge.axis, th) * CFrame.new(-hinge.h)
			else
				local o = f.Offset or { 0, 0, 0 }
				local d = Vector3.new(o[1], o[2], o[3]) * self.Spm
				j.Transform = CFrame.new(0, susp, 0) * CFrame.new(d) * CFrame.Angles(0, steer, 0) * CFrame.new(-d)
			end
		end
	end
	for bone, hinge in pairs(cfg.Hinges or {}) do
		local j = self.Joints[bone]
		if j then
			local target = self.Model:GetAttribute("Door_" .. bone) or 0
			local cur = self.Hinge[bone] or 0
			cur = cur + math.clamp(target - cur, -dt * 1.6, dt * 1.6)
			self.Hinge[bone] = cur
			local ax = hinge.Axis
			j.Transform = CFrame.fromAxisAngle(Vector3.new(ax[1], ax[2], ax[3]), cur * math.rad(hinge.OpenAngle or 60))
		end
	end
	-- Volant : comme GTA, il suit l'ANGLE RÉEL des roues avant (réduit avec la vitesse), pas la commande, et ne
	-- fait que ≈ 90 ° à pleine butée × steerWheelMult (vehicles.meta ; les mods « 480 ° / 900 ° » le relèvent).
	-- Avant le 2026-11-13 : commande × 270 °, si bien qu'à vitesse, roues à peine braquées, le volant faisait
	-- déjà presque un tour (signalé sur le m422). Un ancien CONFIG (MaxAngle 270, sans WheelMult) prend 90 °.
	local sw = cfg.SteeringWheel
	if sw and self.Joints[sw.Bone] then
		local ax = sw.Axis
		local hd = cfg.Handling or {}
		local T = dynTuning()
		local mech = hd.SteeringLockRad or math.rad(hd.SteeringLockDeg or 35)
		local full = mech * (T.SteerLockMeanPct or 1) -- butée réellement atteinte à l'arrêt (MESURÉ : 0,875)
		-- angle des roues avant (rad). Le conducteur le connaît (télémétrie WheelSteer) ; les autres clients
		-- n'ont que la commande : on lui applique la même réduction avec la vitesse que le moteur de conduite.
		local lockNow = s.WheelSteer
		if not lockNow then
			local fade = 1 + (math.abs(s.Speed or 0) / (T.SteerFade or 15)) ^ (T.SteerFadePower or 2)
			lockNow = math.min(math.max(mech / fade, mech * (T.SteerMinPct or 0.15)), full)
		end
		local frac = math.clamp((s.Steer or 0) * lockNow / math.max(full, 1e-3), -1, 1)
		local maxDeg = Runtime.SteeringWheelDeg * (sw.WheelMult or 1)
		self.Joints[sw.Bone].Transform = CFrame.fromAxisAngle(Vector3.new(ax[1], ax[2], ax[3]), frac * math.rad(maxDeg))
	end
	if s.Siren then
		for i, siren in pairs(cfg.Sirens and cfg.Sirens.Lights or {}) do
			local j = self.Joints["siren" .. i]
			if j and siren.Rotate then
				self.SpinAngle["siren" .. i] = ((self.SpinAngle["siren" .. i] or 0) + dt * (siren.RotationSpeed or 6)) % (2 * math.pi)
				j.Transform = CFrame.Angles(0, self.SpinAngle["siren" .. i], 0)
			end
		end
	end
end

-- ------------------------------------------------------------------ lumières
-- Une optique allumée est du Neon SANS texture : un MeshPart Neon qui garde son TextureID (texture GTA
-- sombre) reste presque éteint (mesuré sur le m422, 2026-11-12). La texture revient à l'extinction
-- (attribut OffTexture, posé par VehicleLights.Rig).
-- Optique à émission masquée (VehicleLights.EmissiveSetup) : seule la partie claire de sa texture s'allume, à une
-- intensité par famille de feu (réglée de jour et de nuit sur la m422, 2026-11-15) ; teinte = couleur du feu
-- ramenée à sa composante la plus forte (la texture donne déjà la couleur du verre).
Runtime.EmissiveStrength = {
	headlight = 10, always_on = 8, taillight = 4, brakelight = 12, reversinglight = 10, indicator = 12,
	extralight = 12, default = 8,
}
local function emissiveFamily(part, color)
	local role = part:GetAttribute("LightRole") or ""
	local family = string.match(role, "^(%a+)") or "default"
	if role == "always_on" then
		family = "always_on"
	elseif family == "taillight" and color and color.R > 0.9 and color.G < 0.2 then
		family = "brakelight" -- feu arrière qui sert aussi de stop (véhicule sans pièce brakelight)
	end
	return family
end

local function setPart(part, on, color)
	local sa = part:GetAttribute("EmissiveLit") and part:FindFirstChildOfClass("SurfaceAppearance")
	if sa then
		local S = Runtime.EmissiveStrength
		if on then
			local c = color or Color3.new(1, 1, 1)
			local m = math.max(c.R, c.G, c.B, 1e-3)
			sa.EmissiveTint = Color3.new(c.R / m, c.G / m, c.B / m)
			sa.EmissiveStrength = S[emissiveFamily(part, color)] or S.default
			sa.Color = Color3.new(1, 1, 1)
		else
			sa.EmissiveStrength = 0
			local off = part:GetAttribute("EmissiveOffTint") or 1
			sa.Color = Color3.new(off, off, off)
		end
		return
	end
	local offTex = part:GetAttribute("OffTexture")
	if on then
		part.Material = Enum.Material.Neon
		part.Color = color
		if offTex ~= nil and part:IsA("MeshPart") then
			part.TextureID = ""
		end
		if part:GetAttribute("Visible") ~= false then
			part.Transparency = 0
		end
	else
		if offTex ~= nil and part:IsA("MeshPart") then
			part.TextureID = offTex
		end
		part.Material = Enum.Material[part:GetAttribute("OffMaterial") or "Glass"]
		part.Color = part:GetAttribute("OffColor") or Color3.new(0.6, 0.6, 0.6)
		if part:GetAttribute("Visible") ~= false then
			part.Transparency = part:GetAttribute("OffTransparency") or 0
		end
	end
end

function Runtime:_setRole(role, on, color, brightness)
	local key = role .. (on and "1" or "0") .. (color and tostring(color) or "") .. tostring(brightness)
	if self.LastLightState[role] == key then
		return
	end
	self.LastLightState[role] = key
	for _, p in ipairs(self.LightParts[role] or {}) do
		setPart(p, on, color)
	end
	for _, l in ipairs(self.LightObjects[role] or {}) do
		l.Enabled = on
		if color then
			l.Color = color
		end
		if brightness then
			l.Brightness = brightness
		end
	end
end

-- Portée, ouverture et visée des phares selon le mode (croisement ou route). Les attachments des phares sont posés par
-- VehicleLights.Rig aux axes du véhicule (avant = −Z) : on garde cette pose et on la tourne autour de X.
function Runtime:_aimHeadlights(full)
	if self.HeadBeamFull == full then
		return
	end
	self.HeadBeamFull = full
	local H = Runtime.Headlights
	local range = full and H.FullRange or H.FullRange / H.DistMult
	local pitch = math.rad(full and H.FullPitch or H.DippedPitch)
	local angle = full and H.FullAngle or H.DippedAngle
	self.HeadBase = self.HeadBase or {}
	for _, role in ipairs({ "headlight_l", "headlight_r" }) do
		for _, l in ipairs(self.LightObjects[role] or {}) do
			l.Range = range
			if l:IsA("SpotLight") then
				l.Angle = angle
			end
			local a = l.Parent
			if a and a:IsA("Attachment") then
				self.HeadBase[a] = self.HeadBase[a] or a.CFrame
				a.CFrame = self.HeadBase[a] * CFrame.Angles(pitch, 0, 0)
			end
		end
	end
end

function Runtime:_updateLights(s)
	-- véhicule rendu invisible (VehicleCustomization.SetVisible) : tous les feux éteints
	if s.Invisible then
		for role in pairs(self.LightObjects or {}) do
			self:_setRole(role, false)
		end
		for role in pairs(self.LightParts or {}) do
			self:_setRole(role, false)
		end
		return
	end
	local now = os.clock()
	local blink = (now % 0.75) < 0.4
	if blink ~= self.BlinkState then
		self.BlinkState = blink
		if s.Indicator ~= "Off" and self.IsLocalOccupant and self.Sounds then
			local snd = self.Sounds:FindFirstChild(blink and "IndicatorOn" or "IndicatorOff")
			if snd then
				snd:Play()
			end
		end
	end
	local xenon = self.Model:GetAttribute("XenonColor")
	local headColor = xenon or LIGHT_COLORS.head
	local hl = s.Headlights
	local sirenCfg = self.Config.Sirens
	local beat = sirenCfg and math.floor(now * (sirenCfg.Bpm or 220) / 60) or 0
	local wigL = s.Siren and sirenCfg and sirenCfg.HeadLightLeft and sirenCfg.HeadLightLeft ~= 0 and bit(sirenCfg.HeadLightLeft, beat)
	local wigR = s.Siren and sirenCfg and sirenCfg.HeadLightRight and sirenCfg.HeadLightRight ~= 0 and bit(sirenCfg.HeadLightRight, beat)

	-- croisement / route (portée et visée, voir Runtime.Headlights) ; ombres seulement pour la voiture du joueur local
	local H = Runtime.Headlights
	local full = hl >= 2
	local headBright = full and H.Brightness * H.IntensityMult or H.Brightness
	self:_setRole("headlight_l", hl >= 1 or wigL, headColor, headBright)
	self:_setRole("headlight_r", hl >= 1 or wigR, headColor, headBright)
	self:_aimHeadlights(full)
	local shadows = self.IsLocalOccupant == true
	if self.HeadShadows ~= shadows then
		self.HeadShadows = shadows
		for _, r in ipairs({ "headlight_l", "headlight_r" }) do
			for _, l in ipairs(self.LightObjects[r] or {}) do
				l.Shadows = shadows
			end
		end
	end
	self:_setRole("plate", hl >= 1, LIGHT_COLORS.plate, 1.5)
	self:_setRole("always_on", s.Engine, LIGHT_COLORS.drl)
	local hasBrakeParts = self.LightParts.brakelight_l or self.LightParts.brakelight_r or self.LightParts.brakelight_m
	local tailOn = hl >= 1 or (s.Brake and not hasBrakeParts)
	local tailColor = (s.Brake and not hasBrakeParts) and LIGHT_COLORS.brake or LIGHT_COLORS.tail
	local tailBright = (s.Brake and not hasBrakeParts) and 1.2 or 0.35
	self:_setRole("taillight_l", tailOn, tailColor, tailBright)
	self:_setRole("taillight_r", tailOn, tailColor, tailBright)
	for _, r in ipairs({ "brakelight_l", "brakelight_r" }) do
		self:_setRole(r, s.Brake, LIGHT_COLORS.brake, 1.2)
	end
	self:_setRole("brakelight_m", s.Brake, LIGHT_COLORS.brake, 0.6)
	self:_setRole("reversinglight_l", s.Reverse, LIGHT_COLORS.reverse, 1.2)
	self:_setRole("reversinglight_r", s.Reverse, LIGHT_COLORS.reverse, 1.2)
	local left = (s.Indicator == "Left" or s.Indicator == "Hazard") and blink
	local right = (s.Indicator == "Right" or s.Indicator == "Hazard") and blink
	self:_setRole("indicator_lf", left, LIGHT_COLORS.indicator, 1)
	self:_setRole("indicator_lr", left, LIGHT_COLORS.indicator, 1)
	self:_setRole("indicator_rf", right, LIGHT_COLORS.indicator, 1)
	self:_setRole("indicator_rr", right, LIGHT_COLORS.indicator, 1)
	for i = 1, 4 do
		local on = s.Siren and ((beat + i) % 2 == 0) or (self.Model:GetAttribute("ExtraLights") == true)
		self:_setRole("extralight_" .. i, on, i % 2 == 0 and Color3.fromRGB(255, 30, 30) or Color3.fromRGB(30, 60, 255), 3)
	end
	-- gyrophares (carcols.meta <Sirens>)
	if sirenCfg then
		for i, siren in pairs(sirenCfg.Lights or {}) do
			local seq = siren.Sequencer or 0xAAAAAAAA
			local on = s.Siren and (seq == 0 or bit(seq, beat))
			local c = siren.Color and Color3.new(siren.Color[1], siren.Color[2], siren.Color[3]) or Color3.new(1, 0, 0)
			local key = "siren" .. i
			local stateKey = on and "1" or "0"
			if self.LastLightState[key] ~= stateKey then
				self.LastLightState[key] = stateKey
				for _, p in ipairs(self.SirenParts[i] or {}) do
					setPart(p, on, c)
				end
				for _, l in ipairs(self.LightObjects[key] or {}) do
					l.Enabled = on
				end
			end
		end
	end
end

-- ------------------------------------------------------------------ audio
-- ------------------------------------------------------------------ son moteur (façon GTA)
-- GTA V joue deux sources par voiture : le MOTEUR (côté capot, vers l'avant) et l'ÉCHAPPEMENT (aux pots, vers
-- l'arrière, audible de plus loin), chacune en accélérateur enfoncé et relâché, au régime courant
-- (conférence GDC 2014 de Rockstar North, « The Sound of GTA V »). Ici, chaque couche a des boucles à régimes
-- mesurés (convertisseur, engine_loops.py) : on mélange les deux voisines du régime (fondu à puissance
-- constante), on règle leur hauteur sur le régime exact, et on passe d'enfoncé à relâché en fondu lissé.
-- Les voitures lointaines ne jouent que l'échappement (comme les PNJ de GTA, version allégée) ; en vue
-- intérieure, l'échappement est étouffé et le moteur passe devant.
Runtime.EngineAudio = {
	LayerGain = { engine = 0.75, exhaust = 1.0 },
	LodDistance = 140, -- studs : au-delà, la couche moteur se tait (l'échappement porte plus loin)
	Rolloff = { engine = { 8, 170 }, exhaust = { 12, 320 } }, -- studs (min, max), InverseTapered
	LoadAttack = 0.06, -- s : passage relâché → enfoncé
	LoadRelease = 0.12, -- s : enfoncé → relâché
	VolumeRate = 16, -- 1/s : lissage des volumes
	PitchMin = 0.5,
	PitchMax = 2.0,
	InteriorExhaustDb = { High = -14, Mid = -6, Low = 0 }, -- égaliseur de l'échappement en vue intérieure
	InteriorEngineBoost = 1.25,
}

local function exhaustPosition(cfg)
	if cfg.ExhaustPosition then
		return Vector3.new(cfg.ExhaustPosition[1], cfg.ExhaustPosition[2], cfg.ExhaustPosition[3])
	end
	local sum, n = Vector3.zero, 0
	for name, b in pairs(cfg.Bones or {}) do
		if (name == "exhaust" or string.match(name, "^exhaust_%d+$")) and b.Position then
			sum += Vector3.new(b.Position[1], b.Position[2], b.Position[3])
			n += 1
		end
	end
	if n > 0 then
		return sum / n
	end
	local bnd = cfg.Bounds
	if bnd and bnd.Max then
		return Vector3.new(0, (bnd.Min and bnd.Min[2] or 0) + 0.3, bnd.Max[3] - 0.2)
	end
	return Vector3.new(0, 0.3, 2.2)
end

-- Banque des sons moteur du jeu (ReplicatedStorage.FiveMVehicles.EngineSoundBank, écrite par
-- scripts/engine_sound_bank.py) : { [nom] = { Category, Label, IdleRpm, Loops = { {Name, Rpm, Load, Layer, SoundId} } } }.
local bankCache
local function engineSoundBank()
	if bankCache == nil then
		local mod = script.Parent and script.Parent:FindFirstChild("EngineSoundBank")
		local ok, bank = pcall(function()
			return mod and require(mod)
		end)
		bankCache = (ok and type(bank) == "table" and bank) or false
	end
	return bankCache or nil
end
Runtime.EngineSoundBank = engineSoundBank

-- Boucles jouées par ce véhicule : celles de son VehicleConfig, ou celles du son choisi dans la banque
-- (attribut EngineSound) ; les Sound de la banque sont créés ici, sur ce client seulement.
function Runtime:_engineLoops(a)
	local name = self.Model:GetAttribute("EngineSound")
	local bank = type(name) == "string" and engineSoundBank()
	local entry = bank and bank[name]
	if not (entry and entry.Loops) then
		return a.EngineLoops or {}, nil
	end
	self.BankSounds = {}
	local list, preload = {}, {}
	for _, loop in ipairs(entry.Loops) do
		local snd = Instance.new("Sound")
		snd.Name = "Bank_" .. loop.Name
		snd.SoundId = loop.SoundId
		snd.Volume = 0
		snd:SetAttribute("EngineSound", name)
		snd.Parent = self.Sounds
		table.insert(self.BankSounds, snd)
		table.insert(preload, snd)
		table.insert(list, { Name = snd.Name, Rpm = loop.Rpm, Load = loop.Load, Layer = loop.Layer })
	end
	task.spawn(function()
		pcall(function()
			game:GetService("ContentProvider"):PreloadAsync(preload)
		end)
	end)
	return list, entry
end

-- Défait les couches (avant de les refaire avec un autre son) : voix coupées, groupes et Sound de la banque détruits.
function Runtime:_resetAudio()
	self:_stopAllSounds()
	for _, l in pairs(self.Layers or {}) do
		for _, list in ipairs({ l.on, l.off }) do
			for _, item in ipairs(list) do
				item.Sound:Stop()
				item.Sound.Volume = 0
			end
		end
		if l.group then
			l.group:Destroy()
		end
	end
	for _, snd in ipairs(self.BankSounds or {}) do
		snd:Destroy()
	end
	self.BankSounds = nil
	self.Layers = {}
end

function Runtime:_prepareAudio()
	self.Layers = {}
	local a = self.Config.Audio
	if not (a and self.Sounds) then
		return
	end
	local E = Runtime.EngineAudio
	local loops, bankEntry = self:_engineLoops(a)
	local idleRpm = (bankEntry and bankEntry.IdleRpm) or a.IdleRpm or 850
	local function layer(name)
		local l = self.Layers[name]
		if not l then
			l = { on = {}, off = {}, idle = nil }
			self.Layers[name] = l
		end
		return l
	end
	for _, loop in ipairs(loops) do
		local snd = self.Sounds:FindFirstChild(loop.Name, true) or (self.Root and self.Root:FindFirstChild(loop.Name, true))
		if snd and snd:IsA("Sound") then
			snd.Looped = true
			snd.Volume = 0
			local l = layer(loop.Layer or "engine")
			if loop.Load == "idle" then
				l.idle = { Sound = snd, Rpm = loop.Rpm or idleRpm }
			else
				table.insert(l[loop.Load == "off" and "off" or "on"], { Sound = snd, Rpm = loop.Rpm })
			end
		end
	end
	-- ancien format : un seul « Idle » (couche moteur)
	local legacyIdle = not bankEntry and self.Sounds:FindFirstChild("Idle")
	if legacyIdle and legacyIdle:IsA("Sound") then
		local l = layer("engine")
		if not l.idle then
			legacyIdle.Looped = true
			l.idle = { Sound = legacyIdle, Rpm = a.IdleRpm or 850 }
		end
	end
	-- placement (local à ce client) : l'échappement aux pots, le moteur au capot ; portée propre à chaque couche
	local exhaust = self.Layers.exhaust
	local exhaustAtt
	if exhaust then
		exhaustAtt = self.Root:FindFirstChild("SoundsExhaust")
		if not exhaustAtt then
			exhaustAtt = Instance.new("Attachment")
			exhaustAtt.Name = "SoundsExhaust"
			exhaustAtt.Position = exhaustPosition(self.Config) * self.Spm
			exhaustAtt.Parent = self.Root
		end
	end
	for name, l in pairs(self.Layers) do
		table.sort(l.on, function(x, y)
			return x.Rpm < y.Rpm
		end)
		table.sort(l.off, function(x, y)
			return x.Rpm < y.Rpm
		end)
		-- le ralenti ouvre chaque liste : le fondu passe sans trou du ralenti à la première boucle
		if l.idle then
			table.insert(l.on, 1, l.idle)
			table.insert(l.off, 1, l.idle)
		end
		-- groupe de son par couche (égaliseur de la vue intérieure)
		local g = Instance.new("SoundGroup")
		g.Name = "F2R_" .. name .. "_" .. self.Model.Name
		g.Volume = 1
		local eq = Instance.new("EqualizerSoundEffect")
		eq.Enabled = false
		eq.Parent = g
		g.Parent = game:GetService("SoundService")
		l.group, l.eq = g, eq
		local ro = E.Rolloff[name] or E.Rolloff.engine
		l.rpmOf = {}
		for _, list in ipairs({ l.on, l.off }) do
			for _, item in ipairs(list) do
				local snd = item.Sound
				l.rpmOf[snd] = item.Rpm
				snd.SoundGroup = g
				snd.RollOffMode = Enum.RollOffMode.InverseTapered
				snd.RollOffMinDistance = ro[1]
				snd.RollOffMaxDistance = ro[2]
				if name == "exhaust" and exhaustAtt and snd.Parent ~= exhaustAtt then
					snd.Parent = exhaustAtt
				end
			end
		end
	end
	self.LoadSmooth = 0
	if not self.AudioDestroyHooked then
		self.AudioDestroyHooked = true
		self.Model.Destroying:Connect(function()
			for _, l in pairs(self.Layers or {}) do
				if l.group then
					l.group:Destroy()
				end
			end
		end)
	end
end

function Runtime:_stopAllSounds()
	if self.Sounds then
		for _, s in ipairs(self.Sounds:GetChildren()) do
			if s:IsA("Sound") then
				s:Stop()
			end
		end
	end
	-- l'échappement vit sur sa propre attache (SoundsExhaust)
	local ex = self.Root and self.Root:FindFirstChild("SoundsExhaust")
	if ex then
		for _, s in ipairs(ex:GetChildren()) do
			if s:IsA("Sound") then
				s:Stop()
				s.Volume = 0
			end
		end
	end
end

local function crossfade(list, rpm)
	-- poids des boucles : les deux voisines du régime, fondu à puissance constante
	local w = {}
	local n = #list
	if n == 0 then
		return w
	end
	if rpm <= list[1].Rpm then
		w[1] = 1
	elseif rpm >= list[n].Rpm then
		w[n] = 1
	else
		for i = 1, n - 1 do
			local a, b = list[i].Rpm, list[i + 1].Rpm
			if rpm >= a and rpm <= b then
				local t = (rpm - a) / math.max(b - a, 1)
				w[i] = math.cos(t * math.pi / 2)
				w[i + 1] = math.sin(t * math.pi / 2)
				break
			end
		end
	end
	return w
end

local cameraModule
local function interiorView(r)
	if not r.IsLocalOccupant then
		return false
	end
	if cameraModule == nil then
		local m = script.Parent:FindFirstChild("VehicleCamera")
		local ok, mod = pcall(function()
			return m and require(m)
		end)
		cameraModule = (ok and mod) or false
	end
	return cameraModule and cameraModule.IsPov and cameraModule.IsPov() or false
end

function Runtime:_updateAudio(dt, s)
	if not self.Sounds then
		return
	end
	local a = self.Config.Audio or {}
	local E = Runtime.EngineAudio
	local vol = Runtime.MasterVolume * (a.Volume or 1)
	local engineOn = s.Engine
	if engineOn and not self.EngineWasOn then
		-- bruit de démarreur : seulement un VRAI son (Sound « Start » qui ne vient pas de engine_start.wav). Les
		-- anciennes conversions installaient un démarreur synthétisé (engine_start.wav), refusé par l'utilisateur
		-- (2026-11-16) : il n'est plus joué, même s'il est encore dans le véhicule.
		local start = self.Sounds:FindFirstChild("Start")
		if start and start:IsA("Sound") and start:GetAttribute("SourceFile") ~= "engine_start.wav" then
			start:Play()
		end
	end
	self.EngineWasOn = engineOn
	local rpm = s.Rpm or a.IdleRpm or 850
	-- charge : enfoncé ↔ relâché, lissée (attaque rapide, relâche un peu plus lente)
	local target = math.clamp((s.Throttle or 0) * 1.6, 0, 1)
	local tau = target > (self.LoadSmooth or 0) and E.LoadAttack or E.LoadRelease
	self.LoadSmooth = (self.LoadSmooth or 0) + (target - (self.LoadSmooth or 0)) * (1 - math.exp(-dt / tau))
	local load = self.LoadSmooth
	local onMix, offMix = math.sin(load * math.pi / 2), math.cos(load * math.pi / 2)
	local cam = Workspace.CurrentCamera
	local dist = cam and (cam.CFrame.Position - self.Root.Position).Magnitude or 0
	local inside = interiorView(self)
	local k = math.clamp(dt * E.VolumeRate, 0, 1)
	for name, l in pairs(self.Layers or {}) do
		local gain = (a.LayerGain and a.LayerGain[name]) or E.LayerGain[name] or 1
		if name == "engine" and dist > E.LodDistance and not self.IsLocalOccupant then
			gain = 0 -- version allégée de loin : l'échappement seul
		end
		if inside then
			gain *= (name == "engine") and E.InteriorEngineBoost or 1
		end
		if l.eq then
			local muffle = inside and name == "exhaust"
			l.eq.Enabled = muffle
			if muffle then
				l.eq.HighGain, l.eq.MidGain, l.eq.LowGain = E.InteriorExhaustDb.High, E.InteriorExhaustDb.Mid, E.InteriorExhaustDb.Low
			end
		end
		local hasOff = #l.off > ((l.idle and 1) or 0)
		local seen = {}
		for _, pair in ipairs({ { l.on, hasOff and onMix or (0.55 + 0.45 * load) }, { l.off, hasOff and offMix or 0 } }) do
			local list, mix = pair[1], pair[2]
			local weights = crossfade(list, rpm)
			for i, item in ipairs(list) do
				local snd = item.Sound
				local part = engineOn and (weights[i] or 0) * mix or 0
				-- le ralenti est dans les deux listes : ses deux parts s'ajoutent en puissance
				seen[snd] = math.sqrt((seen[snd] or 0) ^ 2 + part * part)
			end
		end
		for snd, part in pairs(seen) do
			local want = part * gain * vol
			snd.Volume += (want - snd.Volume) * k
			snd.PlaybackSpeed = math.clamp(rpm / math.max(l.rpmOf[snd] or rpm, 1), E.PitchMin, E.PitchMax)
			if snd.Volume > 0.004 then
				if not snd.IsPlaying then
					snd.TimePosition = math.random() * math.max(snd.TimeLength - 0.05, 0)
					snd:Play()
				end
			elseif snd.IsPlaying then
				snd:Stop() -- une boucle muette ne garde pas de voix
			end
		end
	end
	local horn = self.Sounds:FindFirstChild("Horn")
	if horn then
		horn.Looped = true
		if s.Horn and not horn.IsPlaying then
			horn:Play()
		elseif not s.Horn and horn.IsPlaying then
			horn:Stop()
		end
	end
	for _, kind in ipairs({ "wail", "yelp", "priority" }) do
		local snd = self.Sounds:FindFirstChild("Siren_" .. kind)
		if snd then
			snd.Looped = true
			local play = s.Siren and s.SirenSound == kind
			if play and not snd.IsPlaying then
				snd:Play()
			elseif not play and snd.IsPlaying then
				snd:Stop()
			end
		end
	end
end

-- ------------------------------------------------------------------ boucle
function Runtime:_estimateSuspension(dt)
	local Dyn = dynamics()
	if not Dyn then
		return nil
	end
	if self.SuspP == nil then
		local root = self.Root
		local comLocal = root.CFrame:PointToObjectSpace(root.AssemblyCenterOfMass) / self.Spm
		local ok, sim = pcall(Dyn.new, self.Config, comLocal)
		self.SuspP = (ok and sim and sim.P) or false
		self.SuspEst = {}
		self.SuspParams = RaycastParams.new()
		self.SuspParams.FilterType = Enum.RaycastFilterType.Exclude
		self.SuspParams.IgnoreWater = true
		self.SuspFilterAge = math.huge
	end
	local P = self.SuspP
	if not P then
		return nil
	end
	local cam = Workspace.CurrentCamera
	if cam and (cam.CFrame.Position - self.Root.Position).Magnitude > Runtime.SuspensionEstimateDistance then
		return self.SuspEst
	end
	self.SuspFilterAge += dt
	if self.SuspFilterAge > 1 then
		self.SuspFilterAge = 0
		local list = { self.Model }
		for _, pl in ipairs(Players:GetPlayers()) do
			if pl.Character then
				table.insert(list, pl.Character)
			end
		end
		self.SuspParams.FilterDescendantsInstances = list
	end
	local spm = self.Spm
	local cf = self.Root.CFrame
	local up = cf.UpVector
	local margin, extra = 0.3 * spm, 0.25 * spm
	local travelSt = P.travel * spm
	local k = 1 - math.exp(-dt * 25) -- lissage : la caisse répliquée arrive par à-coups
	for _, w in ipairs(P.wheels) do
		local origin = cf:PointToWorldSpace((w.rest + Vector3.new(0, P.upper + P.raise, 0)) * spm) + up * margin
		local hit = Workspace:Spherecast(origin, w.radius * spm * 0.95, -up * (margin + travelSt + extra), self.SuspParams)
		local target = -w.x0 -- roue pendante
		if hit then
			local d = hit.Distance - margin
			if d <= travelSt then
				target = (travelSt - math.max(d, -travelSt)) / spm - w.x0
			end
		end
		local cur = self.SuspEst[w.bone] or target
		self.SuspEst[w.bone] = cur + (target - cur) * k
	end
	return self.SuspEst
end

function Runtime:Update(dt)
	local s = self:_state()
	if not s.Suspension then
		s.Suspension = self:_estimateSuspension(dt) -- pas de télémétrie : ce client ne conduit pas ce véhicule
	end
	self.State = s
	self:_updateJoints(dt, s)
	self:_updateLights(s)
	self:_updateAudio(dt, s)
	local fxMod = tyreFxModule()
	if fxMod then
		fxMod.Update(self, dt, s)
	end
	local bf = backfireModule()
	if bf then
		bf.Update(self, dt, s)
	end
end

local accum = 0
RunService.RenderStepped:Connect(function(dt)
	local cam = Workspace.CurrentCamera
	local camPos = cam and cam.CFrame.Position or Vector3.zero
	accum += dt
	local slowTick = accum > 0.2
	if slowTick then
		accum = 0
	end
	for model, r in pairs(renderers) do
		if model.Parent == nil or not r.Root.Parent then
			Runtime.Detach(model)
		else
			local near = (r.Root.Position - camPos).Magnitude < Runtime.RenderDistance
			if near or r.IsLocalOccupant then
				r:Update(dt)
			elseif slowTick then
				r:_stopAllSounds()
				local fxMod = tyreFxModule()
				if fxMod then
					fxMod.Stop(r)
				end
			end
		end
	end
end)

return Runtime
