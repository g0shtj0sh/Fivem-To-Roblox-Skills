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
Runtime.Headlights = {
	FullRange = 60, -- studs (maximum d'un SpotLight)
	DistMult = 1.3, -- GTA fullbeam.DistMult
	IntensityMult = 1.1, -- GTA fullbeam.IntensityMult
	Brightness = 3, -- croisements
	DippedPitch = -10, -- degrés, faisceau baissé (réglé à l'essai, voir plus haut)
	FullPitch = 0,
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
local function setPart(part, on, color)
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

-- Portée et visée des phares selon le mode (croisement ou route). Les attachments des phares sont posés par
-- VehicleLights.Rig aux axes du véhicule (avant = −Z) : on garde cette pose et on la tourne autour de X.
function Runtime:_aimHeadlights(full)
	if self.HeadBeamFull == full then
		return
	end
	self.HeadBeamFull = full
	local H = Runtime.Headlights
	local range = full and H.FullRange or H.FullRange / H.DistMult
	local pitch = math.rad(full and H.FullPitch or H.DippedPitch)
	self.HeadBase = self.HeadBase or {}
	for _, role in ipairs({ "headlight_l", "headlight_r" }) do
		for _, l in ipairs(self.LightObjects[role] or {}) do
			l.Range = range
			local a = l.Parent
			if a and a:IsA("Attachment") then
				self.HeadBase[a] = self.HeadBase[a] or a.CFrame
				a.CFrame = self.HeadBase[a] * CFrame.Angles(pitch, 0, 0)
			end
		end
	end
end

function Runtime:_updateLights(s)
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
function Runtime:_prepareAudio()
	self.Loops = { on = {}, off = {} }
	local a = self.Config.Audio
	if not (a and self.Sounds) then
		return
	end
	for _, loop in ipairs(a.EngineLoops or {}) do
		local snd = self.Sounds:FindFirstChild(loop.Name)
		if snd then
			snd.Looped = true
			snd.Volume = 0
			table.insert(self.Loops[loop.Load] or self.Loops.on, { Sound = snd, Rpm = loop.Rpm })
		end
	end
	for _, list in pairs(self.Loops) do
		table.sort(list, function(x, y)
			return x.Rpm < y.Rpm
		end)
	end
	self.Idle = self.Sounds:FindFirstChild("Idle")
	if self.Idle then
		self.Idle.Looped = true
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
end

local function crossfade(list, rpm)
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
				w[i] = math.cos(t * math.pi / 2) -- fondu à puissance constante
				w[i + 1] = math.sin(t * math.pi / 2)
				break
			end
		end
	end
	return w
end

function Runtime:_updateAudio(dt, s)
	if not self.Sounds then
		return
	end
	local a = self.Config.Audio or {}
	local vol = Runtime.MasterVolume * (a.Volume or 1)
	local engineOn = s.Engine
	if engineOn and not self.EngineWasOn then
		local start = self.Sounds:FindFirstChild("Start")
		if start then
			start:Play()
		end
	end
	self.EngineWasOn = engineOn
	local idleRpm = a.IdleRpm or 850
	local maxRpm = a.MaxRpm or 7200
	local rpm = s.Rpm or idleRpm
	local idleW = math.clamp(1 - (rpm - idleRpm) / (0.12 * (maxRpm - idleRpm)), 0, 1)
	local hasOff = #self.Loops.off > 0
	local load = math.clamp((s.Throttle or 0) * 1.5, 0, 1)
	for loadName, list in pairs(self.Loops) do
		local weights = crossfade(list, rpm)
		local mix
		if loadName == "on" then
			mix = hasOff and load or (0.55 + 0.45 * load)
		else
			mix = 1 - load
		end
		for i, l in ipairs(list) do
			local target = engineOn and (weights[i] or 0) * mix * (1 - idleW * 0.85) * vol or 0
			local snd = l.Sound
			snd.Volume = snd.Volume + (target - snd.Volume) * math.clamp(dt * 12, 0, 1)
			snd.PlaybackSpeed = math.clamp(rpm / l.Rpm, 0.45, 2.2)
			if snd.Volume > 0.005 and not snd.IsPlaying then
				snd:Play()
			elseif snd.Volume <= 0.005 and snd.IsPlaying and not engineOn then
				snd:Stop()
			end
		end
	end
	if self.Idle then
		local target = engineOn and idleW * vol or 0
		self.Idle.Volume = self.Idle.Volume + (target - self.Idle.Volume) * math.clamp(dt * 12, 0, 1)
		self.Idle.PlaybackSpeed = math.clamp(rpm / idleRpm, 0.8, 1.6)
		if engineOn and not self.Idle.IsPlaying then
			self.Idle:Play()
		elseif not engineOn and self.Idle.IsPlaying and self.Idle.Volume < 0.01 then
			self.Idle:Stop()
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
function Runtime:Update(dt)
	local s = self:_state()
	self.State = s
	self:_updateJoints(dt, s)
	self:_updateLights(s)
	self:_updateAudio(dt, s)
	local fxMod = tyreFxModule()
	if fxMod then
		fxMod.Update(self, dt, s)
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
