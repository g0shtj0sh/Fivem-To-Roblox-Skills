--!nonstrict
--[[
	VehicleBackfire (ModuleScript, ReplicatedStorage.FiveMVehicles) — retours de flamme à l'échappement, façon GTA V.

	Appelé par VehicleRuntime à chaque image, pour chaque véhicule proche, sur CHAQUE client (effet purement visuel :
	le régime, l'accélérateur et le rapport sont déjà répliqués, rien de plus ne passe par le réseau).

	Quand (GTA V, observé par les joueurs : forums GTA, GameFAQs, vidéos ; aucun seuil publié) :
	- au LEVER DE PIED à haut régime : une salve de 2 à 4 détonations (le cas le plus fréquent) ;
	- au PASSAGE DE RAPPORT sous les gaz : une détonation ;
	- au RUPTEUR (pied au plancher, burn compris) : des détonations espacées au hasard.
	Qui : dans GTA, surtout les ÉCHAPPEMENTS AMÉLIORÉS (Los Santos Customs) et quelques voitures haut de gamme d'origine.
	Ici : attribut `Backfire` du véhicule — true toujours, false jamais, absent : seulement avec un échappement
	amélioré (`Mod_Exhaust` > 0, VehicleCustomization).

	Où : aux os d'échappement GTA du véhicule (`CONFIG.Bones.exhaust`, `exhaust_2`…), flamme vers l'arrière.
	Chaque détonation : une flamme courte (particules additives) et une LUMIÈRE orange qui éclaire le sol et la caisse
	(PointLight, ≥ 0,1 s : plus court, Roblox peut ne jamais l'afficher).
	Son : `Backfire.SoundId` ou attribut `BackfireSoundId` (sur le véhicule ou sur ReplicatedStorage.FiveMVehicles) ;
	vide = flamme sans son.
	Seuils et tailles posés à l'œil (non mesurés dans GTA).
]]
local Backfire = {}
Backfire.SoundId = ""
Backfire.LiftRpm = 0.65 -- régime normalisé (ralenti 0 → rupteur 1) au-dessus duquel un lever de pied pétarade
Backfire.LiftFrom = 0.6 -- accélérateur « enfoncé »
Backfire.LiftTo = 0.15 -- accélérateur « relâché »
Backfire.LiftWindow = 0.4 -- s : le pied doit se lever dans ce délai après avoir été enfoncé
Backfire.BurstPops = { 2, 4 } -- détonations par salve
Backfire.BurstSpan = 0.45 -- s : durée d'une salve
Backfire.ShiftRpm = 0.55 -- régime minimal avant un passage de rapport qui pétarade
Backfire.LimiterRpm = 0.96
Backfire.LimiterGap = { 0.18, 0.5 } -- s entre deux détonations au rupteur
Backfire.Cooldown = 0.07 -- s minimum entre deux détonations
Backfire.FlameTexture = "rbxasset://textures/particles/fire_main.dds"
Backfire.LightColor = Color3.fromRGB(255, 140, 50)
Backfire.LightBrightness = 6
Backfire.LightRange = 12 -- studs (à 3,571 studs/m)
Backfire.LightTime = 0.12 -- s

local function enabled(model)
	local a = model:GetAttribute("Backfire")
	if a ~= nil then
		return a == true
	end
	return (model:GetAttribute("Mod_Exhaust") or 0) > 0
end

local function soundId(model)
	local id = model:GetAttribute("BackfireSoundId")
	if type(id) ~= "string" or id == "" then
		local folder = script.Parent
		id = folder and folder:GetAttribute("BackfireSoundId")
	end
	if type(id) ~= "string" or id == "" then
		id = Backfire.SoundId
	end
	return id
end

local function makeExhaust(root, name, posStuds, scale)
	local att = Instance.new("Attachment")
	att.Name = "F2R_Backfire_" .. name
	-- la flamme sort vers l'arrière du véhicule (+Z local, l'avant est −Z), légèrement vers le bas
	local rear = Vector3.new(0, -0.08, 1).Unit
	att.CFrame = CFrame.lookAt(posStuds, posStuds + rear)
	att.Parent = root
	local e = Instance.new("ParticleEmitter")
	e.Name = "Flame"
	e.Texture = Backfire.FlameTexture
	e.Enabled = false
	e.EmissionDirection = Enum.NormalId.Front
	-- un JET de flamme, pas un nuage : particules couchées dans leur sens de déplacement et étirées
	-- (Squash négatif), cône étroit, vie courte ; la première version (rotation libre, traînée forte)
	-- donnait un nuage d'étincelles (essai 2026-11-14)
	e.Lifetime = NumberRange.new(0.05, 0.1)
	e.Speed = NumberRange.new(14 * scale, 22 * scale)
	e.SpreadAngle = Vector2.new(5, 5)
	e.Drag = 3
	e.Orientation = Enum.ParticleOrientation.VelocityParallel
	e.Squash = NumberSequence.new(-1.2)
	e.LightEmission = 1
	e.LightInfluence = 0
	e.Brightness = 4
	e.ZOffset = 0.3
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35 * scale),
		NumberSequenceKeypoint.new(0.3, 0.6 * scale),
		NumberSequenceKeypoint.new(1, 0.15 * scale),
	})
	e.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 250, 225)),
		ColorSequenceKeypoint.new(0.25, Color3.fromRGB(255, 190, 70)),
		ColorSequenceKeypoint.new(0.7, Color3.fromRGB(255, 110, 25)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(170, 40, 10)),
	})
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05),
		NumberSequenceKeypoint.new(0.7, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Parent = att
	-- cœur : un éclat blanc-orangé à la sortie du pot, très bref, qui fait lire la détonation
	local core = Instance.new("ParticleEmitter")
	core.Name = "FlameCore"
	core.Texture = Backfire.FlameTexture
	core.Enabled = false
	core.EmissionDirection = Enum.NormalId.Front
	core.Lifetime = NumberRange.new(0.04, 0.07)
	core.Speed = NumberRange.new(3 * scale, 6 * scale)
	core.SpreadAngle = Vector2.new(10, 10)
	core.Rotation = NumberRange.new(0, 360)
	core.LightEmission = 1
	core.LightInfluence = 0
	core.Brightness = 6
	core.ZOffset = 0.4
	core.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.45 * scale),
		NumberSequenceKeypoint.new(1, 0.2 * scale),
	})
	core.Color = ColorSequence.new(Color3.fromRGB(255, 225, 160), Color3.fromRGB(255, 140, 40))
	core.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.6, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	core.Parent = att
	local l = Instance.new("PointLight")
	l.Name = "FlameLight"
	l.Color = Backfire.LightColor
	l.Range = Backfire.LightRange * scale
	l.Brightness = 0
	l.Shadows = false
	l.Enabled = true
	l.Parent = att
	return { att = att, emitter = e, core = core, light = l }
end

local function prepare(r)
	local st = { exhausts = {}, queue = {}, lastPop = 0, light = 0, hotT = nil, hotRpm = 0, gear = nil, nextLimiter = 0 }
	local cfg, spm = r.Config, r.Spm
	local scale = spm / 3.571
	local names = {}
	for name in pairs(cfg.Bones or {}) do
		if name == "exhaust" or name:match("^exhaust_%d+$") then
			table.insert(names, name)
		end
	end
	table.sort(names)
	for _, name in ipairs(names) do
		local p = cfg.Bones[name].Position
		if p then
			table.insert(st.exhausts, makeExhaust(r.Root, name, Vector3.new(p[1], p[2], p[3]) * spm, scale))
		end
	end
	return st
end

local function pop(st, model)
	local now = os.clock()
	if now - st.lastPop < Backfire.Cooldown then
		return
	end
	st.lastPop = now
	st.light = Backfire.LightTime
	local id = soundId(model)
	for _, ex in ipairs(st.exhausts) do
		ex.emitter:Emit(math.random(14, 20))
		ex.core:Emit(2)
	end
	if id ~= "" and st.exhausts[1] then
		local ex = st.exhausts[1]
		local s = ex.sound
		if not s then
			s = Instance.new("Sound")
			s.Name = "BackfirePop"
			s.RollOffMode = Enum.RollOffMode.InverseTapered
			s.RollOffMinDistance = 8
			s.RollOffMaxDistance = 140
			s.Volume = 0.8
			s.Parent = ex.att
			ex.sound = s
		end
		if s.SoundId ~= id then
			s.SoundId = id
		end
		s.PlaybackSpeed = 0.9 + math.random() * 0.25
		s.TimePosition = 0
		s:Play()
	end
	st.pops = (st.pops or 0) + 1
end

local function burst(st, now)
	local n = math.random(Backfire.BurstPops[1], Backfire.BurstPops[2])
	for i = 0, n - 1 do
		table.insert(st.queue, now + (i / math.max(n - 1, 1)) * Backfire.BurstSpan * (0.7 + math.random() * 0.3))
	end
end

-- r : rendu VehicleRuntime ; s : son état (Rpm en tr/min, Throttle 0..1, Gear)
function Backfire.Update(r, dt, s)
	local model = r.Model
	local st = r.BackfireState
	if not enabled(model) or s.Engine == false then
		if st then
			st.light = 0
			for _, ex in ipairs(st.exhausts) do
				ex.light.Brightness = 0
			end
			table.clear(st.queue)
			st.hotT = nil
		end
		return
	end
	if not st then
		st = prepare(r)
		r.BackfireState = st
	end
	if #st.exhausts == 0 then
		return
	end
	local now = os.clock()
	local a = r.Config.Audio or {}
	local idle, maxRpm = a.IdleRpm or 850, a.MaxRpm or 7200
	local rpm = math.clamp(((s.Rpm or idle) - idle) / math.max(maxRpm - idle, 1), 0, 1.1)
	local thr = s.Throttle or 0

	-- lever de pied à haut régime : salve
	if thr >= Backfire.LiftFrom then
		st.hotT, st.hotRpm = now, math.max(rpm, (st.hotT and now - st.hotT < Backfire.LiftWindow) and st.hotRpm or 0)
	elseif thr <= Backfire.LiftTo and st.hotT then
		if now - st.hotT < Backfire.LiftWindow and st.hotRpm >= Backfire.LiftRpm then
			burst(st, now)
		end
		st.hotT = nil
	end
	-- passage de rapport sous les gaz
	local gear = s.Gear
	if st.gear and gear and gear > st.gear and st.gear >= 1 and thr >= 0.5 and (st.lastRpm or 0) >= Backfire.ShiftRpm then
		table.insert(st.queue, now)
	end
	st.gear = gear
	st.lastRpm = rpm
	-- rupteur
	if rpm >= Backfire.LimiterRpm and thr >= 0.9 then
		if now >= st.nextLimiter then
			if st.nextLimiter > 0 then
				table.insert(st.queue, now)
			end
			st.nextLimiter = now + Backfire.LimiterGap[1] + math.random() * (Backfire.LimiterGap[2] - Backfire.LimiterGap[1])
		end
	else
		st.nextLimiter = 0
	end
	-- détonations dues
	local i = 1
	while i <= #st.queue do
		if now >= st.queue[i] then
			table.remove(st.queue, i)
			pop(st, model)
		else
			i += 1
		end
	end
	-- lumière : pleine puis éteinte en LightTime
	if st.light > 0 then
		st.light = math.max(st.light - dt, 0)
		local b = Backfire.LightBrightness * (st.light / Backfire.LightTime)
		for _, ex in ipairs(st.exhausts) do
			ex.light.Brightness = b
		end
	end
end

-- essais : une détonation tout de suite
function Backfire.Pop(r)
	if not r.BackfireState then
		r.BackfireState = prepare(r)
	end
	pop(r.BackfireState, r.Model)
end

function Backfire.Count(r)
	return r.BackfireState and r.BackfireState.pops or 0
end

return Backfire
