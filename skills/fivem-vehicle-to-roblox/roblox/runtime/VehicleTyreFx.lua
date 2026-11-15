--!nonstrict
--[[
	VehicleTyreFx (ModuleScript, ReplicatedStorage.FiveMVehicles) — traces de pneus et fumée, façon GTA V.

	Appelé par VehicleRuntime à chaque image, pour chaque véhicule proche, sur CHAQUE client (effet purement visuel).

	La règle de GTA (analyse 2026-11-14 : deux vidéos de drift GTA V image par image + code de GTA Vice City
	rétro-ingénié, projet reVC, CAutomobile : même test pour la fumée PARTICLE_RUBBER_SMOKE et la trace
	CSkidmarks::RegisterOne) : PAR ROUE, trace et fumée partent ENSEMBLE quand la roue glisse dans son propre
	repère — glisse latérale au-delà de l'adhérence (drift), patinage (burn, départ) ou roue bloquée (freinage
	sans ABS, frein à main). Une roue avant braquée dans le sens où va la voiture ne glisse pas : elle ne marque
	pas. Voiture redressée ou presque arrêtée : plus rien. Sur l'eau : rien (choix de l'utilisateur, 2026-11-14).

	Intensité d'une roue (0..1) — corrigée le 2026-11-15 (« je tourne à peine qu'il y a déjà les traces et la
	fumée alors qu'on n'est même pas en drift ») : le glissement combiné dépassait le pic dès qu'on braquait à
	fond (les roues AVANT qui ripent en sous-virage), d'où des traces dans un simple virage. Désormais :
	  - patinage / blocage (part LE LONG de la roue : burn, départ, frein à main, roue bloquée) : marque seul ;
	  - glisse de côté : marque seulement si la VOITURE dérive (angle entre son cap et la trajectoire de son
	    essieu arrière au-delà de DriftStart) ; une roue qui ripe dans un virage tenu ne marque pas.
	Le conducteur la calcule à chaque image (VehicleDrive → télémétrie `TyreFx`) ; les autres clients la
	lisent dans l'attribut `TyreFx` du véhicule (4 bits par roue, roues triées par nom d'os, 10 Hz).

	Trace : un ruban continu par roue (Beams couchés au sol qui se rejoignent point pour point : même point,
	même largeur, même opacité à la jonction), au lieu d'une suite de blocs ; opacité lissée dans le temps,
	fondu d'entrée et de sortie, segments presque alignés fusionnés.

	Réglages par véhicule : attribut `TyreSmokeColor` (Color3, comme la couleur de fumée de pneu de GTA) ;
	`TyreFx = false` sur le véhicule pour couper l'effet.
	Seuils, tailles et durées posés à l'œil contre les vidéos de référence : non mesurés dans GTA.
]]
local Workspace = game:GetService("Workspace")

local Fx = {}
Fx.SlideStart = 1.0 -- glissement combiné (VehicleDynamics, 1 = pic d'adhérence) sous lequel rien ne marque
Fx.LongV0 = 2.0 -- m/s de patinage / blocage au contact : début de la trace
Fx.LongV1 = 9 -- m/s : intensité pleine
Fx.LatV0 = 2.5 -- m/s de glisse de côté au contact : début (si la voiture dérive)
Fx.LatV1 = 9
Fx.DriftStart = 14 -- ° entre le cap et la trajectoire de l'essieu arrière : en dessous, pas de trace de côté
Fx.DriftFull = 24 -- ° : la glisse de côté marque pleinement (mesuré m422, 2026-11-15 : pleine butée 30 / 50 / 80 km/h
--                    → 11,8 / 16,1 / 15,6 ° au plus ; frein à main à 70 km/h → 25,7 °)
Fx.LoadMin = 0.35 -- charge de la roue / charge moyenne : en dessous, un patinage ne marque pas
Fx.LoadFull = 0.75
Fx.DriftMinSpeed = 2.5 -- m/s : en dessous, l'angle de dérive n'a pas de sens (0)
Fx.SmokeRate = 32 -- particules par seconde et par roue à intensité pleine
Fx.SmokeStart = 0.15 -- intensité sous laquelle la trace marque déjà mais sans fumée
Fx.SmokeColor = Color3.fromRGB(228, 228, 228)
Fx.MarkColor = Color3.fromRGB(28, 28, 28)
Fx.MarkAlpha = 0.42 -- opacité de la trace à intensité pleine (elle part de 0)
Fx.MarkGamma = 0.7 -- courbe intensité → opacité
Fx.MarkRate = 10 -- 1/s : lissage de l'opacité (évite les à-coups d'une image à l'autre)
Fx.MarkWidth = 0.75 -- part de la largeur du pneu
Fx.SegMin = 0.8 -- studs entre deux points de trace
Fx.SegJoin = 6 -- studs : un segment presque aligné avec le précédent l'allonge au lieu d'en créer un
Fx.JoinCos = math.cos(math.rad(2.5))
Fx.SegMax = 8 -- au-delà (téléport, saut), la trace repart de zéro
Fx.Lift = 0.04 -- studs au-dessus du sol
Fx.MaxMarks = 1500 -- segments gardés sur ce client (les plus vieux sont repris)
Fx.MarkLife = 120 -- s avant que la trace ne commence à s'effacer
Fx.MarkFade = 20 -- s d'effacement
Fx.PatchEvery = 0.35 -- s : burn sur place, une couche de gomme de plus sous la roue
Fx.PatchMax = 5 -- couches au plus au même endroit
Fx.SmokeTexture = "rbxasset://textures/particles/smoke_main.dds"

-- sols meubles : pas de fumée de gomme mais de la poussière, et une trace de la couleur du sol (GTA : traces
-- de terre). L'eau ne donne rien.
local SOFT = {
	Grass = true, LeafyGrass = true, Ground = true, Mud = true, Sand = true, Snow = true,
}

-- ------------------------------------------------------------------ intensité et transport
local function ramp(x, a, b)
	return math.clamp((x - a) / (b - a), 0, 1)
end

-- angle de dérive de l'ESSIEU ARRIÈRE (°) : vBody (m/s) et wBody (rad/s) dans le repère de la voiture (-Z vers
-- l'avant), rearZ (m) position de l'essieu arrière. Pas celui du centre de gravité : à pleine butée et basse
-- vitesse, la géométrie seule y donne 5 à 14 ° sans aucune glisse (mesures m422, calibration/m422/README.md),
-- alors que l'essieu arrière d'une voiture qui tient la route avance presque droit (dérive de ses pneus, < pic).
function Fx.DriftAngle(vBody, wBody, rearZ)
	if not vBody then
		return 0
	end
	local fwd = math.abs(vBody.Z)
	local lat = math.abs(vBody.X + (wBody and wBody.Y or 0) * (rearZ or 0))
	if math.sqrt(fwd * fwd + lat * lat) < Fx.DriftMinSpeed then
		return 0
	end
	return math.deg(math.atan2(lat, fwd))
end

-- w : une roue de VehicleDynamics (out.wheels[i]) ; ctx : { drift = Fx.DriftAngle(...), fzMean = charge moyenne
-- des roues au sol (même unité que w.Fz) } — un nombre seul est lu comme `drift`.
function Fx.Intensity(w, ctx)
	if not (w and w.grounded) or (w.slip or 0) < Fx.SlideStart then
		return 0
	end
	if type(ctx) ~= "table" then
		ctx = { drift = ctx }
	end
	if w.slipLong == nil then
		return ramp(w.slipV or 0, Fx.LongV0, Fx.LongV1) -- moteur d'avant 2026-11-15 : vitesse combinée
	end
	-- une roue délestée (intérieure en virage serré) qui patine ne laisse rien : mesuré, elle s'emballe
	-- (jusqu'à 29 m/s de patinage à pleine butée 80 km/h) sans que la voiture glisse
	local load = 1
	if ctx.fzMean and ctx.fzMean > 1e-3 and w.Fz then
		load = ramp(w.Fz / ctx.fzMean, Fx.LoadMin, Fx.LoadFull)
	end
	local kLong = ramp(math.abs(w.slipLong), Fx.LongV0, Fx.LongV1) * load
	local kLat = ramp(math.abs(w.slipLat or 0), Fx.LatV0, Fx.LatV1) * ramp(ctx.drift or 0, Fx.DriftStart, Fx.DriftFull)
	return math.max(kLong, kLat)
end

-- ordre des roues : noms d'os triés (le même sur tous les clients)
function Fx.Bones(cfg)
	local list = {}
	for bone in pairs(cfg.Wheels or {}) do
		table.insert(list, bone)
	end
	table.sort(list)
	return list
end

-- { [bone] = 0..1 } -> entier (4 bits par roue, 8 roues au plus)
function Fx.Pack(map, bones)
	local n = 0
	for i, bone in ipairs(bones) do
		if i > 8 then
			break
		end
		local q = math.clamp(math.floor((map[bone] or 0) * 15 + 0.5), 0, 15)
		n = bit32.bor(n, bit32.lshift(q, 4 * (i - 1)))
	end
	return n
end

function Fx.Unpack(n, bones)
	local map = {}
	if type(n) ~= "number" then
		return map
	end
	for i, bone in ipairs(bones) do
		if i > 8 then
			break
		end
		map[bone] = bit32.band(bit32.rshift(n, 4 * (i - 1)), 15) / 15
	end
	return map
end

-- ------------------------------------------------------------------ traces (pool commun à tout le client)
-- Un segment = un Beam couché au sol entre deux attachements (sur une pièce invisible ancrée à l'origine :
-- la position d'un attachement est sa position dans le monde). La largeur d'un Beam qui ne fait pas face à la
-- caméra s'étend le long de l'axe Y de ses attachements (même convention que le kit VFX, pen.ts) : chaque
-- point de la trace porte la direction « en travers » (bissectrice aux virages) commune aux deux segments qui
-- s'y rejoignent, d'où un ruban sans joint ni marche.
local marks = { list = {}, cursor = 0, scan = 0, folder = nil, host = nil }

local function markFolder()
	if not marks.folder or not marks.folder.Parent then
		local f = Workspace:FindFirstChild("F2R_TyreMarks")
		if not f then
			f = Instance.new("Folder")
			f.Name = "F2R_TyreMarks"
			f.Parent = Workspace
		end
		marks.folder = f
	end
	return marks.folder
end

local function markHost()
	if not marks.host or not marks.host.Parent then
		local p = Instance.new("Part")
		p.Name = "TyreMarkHost"
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Locked = true
		p.Transparency = 1
		p.Size = Vector3.new(0.2, 0.2, 0.2)
		p.CFrame = CFrame.identity
		p.Parent = markFolder()
		marks.host = p
		marks.list = {} -- les Beams de l'ancienne pièce ont disparu avec elle
		marks.cursor, marks.scan = 0, 0
	end
	return marks.host
end

local function newSegment()
	local host = markHost()
	local a0 = Instance.new("Attachment")
	local a1 = Instance.new("Attachment")
	a0.Parent = host
	a1.Parent = host
	local beam = Instance.new("Beam")
	beam.Name = "TyreMark"
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.FaceCamera = false
	beam.Segments = 1
	beam.Texture = ""
	beam.LightEmission = 0
	beam.LightInfluence = 1
	beam.TextureSpeed = 0
	beam.Parent = host
	return { beam = beam, a0 = a0, a1 = a1 }
end

-- repère d'un point de trace : X le long de la trace, Y en travers (sens de la largeur du Beam)
local function frameAt(p, along, across)
	local x = along - across * along:Dot(across)
	if x.Magnitude < 1e-4 then
		x = across:Cross(Vector3.yAxis)
		if x.Magnitude < 1e-4 then
			x = Vector3.xAxis
		end
	end
	return CFrame.fromMatrix(p, x.Unit, across)
end

local function paint(m)
	local fade = m.fade or 0
	m.beam.Transparency = NumberSequence.new(1 - m.alpha0 * (1 - fade), 1 - m.alpha1 * (1 - fade))
end

-- pose un segment de a (en travers acrossA, opacité alphaA) à b ; renvoie son entrée (à prolonger ou à raccorder)
local function layMark(a, b, acrossA, acrossB, alphaA, alphaB, width, color)
	local d = b - a
	if d.Magnitude < 1e-3 then
		return nil
	end
	markHost()
	marks.cursor = marks.cursor % Fx.MaxMarks + 1
	local m = marks.list[marks.cursor]
	if not m then
		m = newSegment()
		marks.list[marks.cursor] = m
	end
	m.serial = (m.serial or 0) + 1 -- une roue qui tient encore ce segment le reconnaît (repris par le pool sinon)
	local along = d.Unit
	m.a0.CFrame = frameAt(a, along, acrossA)
	m.a1.CFrame = frameAt(b, along, acrossB)
	m.beam.Width0 = width
	m.beam.Width1 = width
	if m.color ~= color then
		m.color = color
		m.beam.Color = ColorSequence.new(color)
	end
	m.alpha0, m.alpha1, m.fade = alphaA, alphaB, 0
	paint(m)
	m.beam.Enabled = true
	m.born = os.clock()
	m.live = true
	m.a, m.b, m.len, m.dir = a, b, d.Magnitude, along
	return m
end

-- effacement progressif des vieilles traces : une tranche du pool par image
local function ageMarks()
	local n = #marks.list
	local now = os.clock()
	if n == 0 or marks.agedAt == now then
		return -- une seule tranche par image, quel que soit le nombre de véhicules
	end
	marks.agedAt = now
	for _ = 1, math.min(60, n) do
		marks.scan = marks.scan % n + 1
		local m = marks.list[marks.scan]
		if m and m.live then
			local age = now - m.born
			if age > Fx.MarkLife then
				m.fade = math.clamp((age - Fx.MarkLife) / Fx.MarkFade, 0, 1)
				paint(m)
				if m.fade >= 1 then
					m.live = false
					m.beam.Enabled = false
				end
			end
		end
	end
end

-- ------------------------------------------------------------------ fumée
local function makeEmitter(root, bone)
	local att = Instance.new("Attachment")
	att.Name = "F2R_TyreFx_" .. bone
	att.Parent = root
	local e = Instance.new("ParticleEmitter")
	e.Name = "TyreSmoke"
	e.Texture = Fx.SmokeTexture
	e.Rate = 0
	e.Enabled = true
	e.Lifetime = NumberRange.new(1.6, 2.6)
	e.Speed = NumberRange.new(1, 3)
	e.SpreadAngle = Vector2.new(40, 40)
	e.EmissionDirection = Enum.NormalId.Top
	e.Acceleration = Vector3.new(0, 1.2, 0)
	e.Drag = 1.5
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-30, 30)
	e.LightEmission = 0
	e.LightInfluence = 1
	e.VelocityInheritance = 0
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.8),
		NumberSequenceKeypoint.new(0.3, 2.4),
		NumberSequenceKeypoint.new(1, 5),
	})
	-- entre en fondu, reste légère, finit transparente (une courbe qui ne finit pas à 1 fait sauter la particule)
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.08, 0.55),
		NumberSequenceKeypoint.new(0.5, 0.75),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Parent = att
	return att, e
end

-- ------------------------------------------------------------------ par véhicule
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = false

local function surfaceColor(material)
	local ok, c = pcall(function()
		return Workspace.Terrain:GetMaterialColor(material)
	end)
	return ok and c or Color3.fromRGB(110, 95, 75)
end

-- en travers de la trace, dans le plan du sol
local function acrossOf(along, normal)
	local r = along:Cross(normal)
	if r.Magnitude < 1e-4 then
		return nil
	end
	return r.Unit
end

-- prolonge la trace d'une roue jusqu'à p (opacité alpha) : raccord au segment précédent par la bissectrice,
-- ou allongement du précédent s'il est presque aligné et encore court
local function extendTrail(ws, p, normal, alpha, width, color)
	local d = p - ws.last
	local along = d.Unit
	local across = acrossOf(along, normal)
	if not across then
		return
	end
	local prev = ws.seg
	if prev and prev.serial ~= ws.segSerial then
		prev = nil -- repris par le pool entre-temps
	end
	if prev and prev.color == color and prev.dir:Dot(along) >= Fx.JoinCos and prev.len + d.Magnitude <= Fx.SegJoin
		and math.abs(prev.alpha1 - alpha) < 0.06 then
		-- presque dans le prolongement : on allonge le segment (moins de Beams, aucun joint visible)
		local a = prev.a
		local dir = (p - a).Unit
		local acrossA = prev.a0.CFrame.YVector
		prev.a0.CFrame = frameAt(a, dir, acrossA)
		prev.a1.CFrame = frameAt(p, dir, acrossOf(dir, normal) or across)
		prev.b, prev.len, prev.dir = p, (p - a).Magnitude, dir
		prev.alpha1 = alpha
		paint(prev)
		prev.born = os.clock()
		ws.last, ws.lastAlpha = p, alpha
		return
	end
	local acrossA = across
	if prev then
		-- coin : les deux segments partagent la bissectrice au point commun
		local mid = prev.a1.CFrame.YVector + across
		if mid.Magnitude > 1e-3 and prev.a1.CFrame.YVector:Dot(across) > 0 then
			acrossA = mid.Unit
			prev.a1.CFrame = frameAt(prev.b, prev.dir, acrossA)
		end
	end
	local m = layMark(ws.last, p, acrossA, across, ws.lastAlpha or 0, alpha, width, color)
	if m then
		ws.seg, ws.segSerial = m, m.serial
	end
	ws.last, ws.lastAlpha = p, alpha
end

-- r : rendu VehicleRuntime ; s : son état (s.TyreFx = { [bone] = 0..1 })
function Fx.Update(r, dt, s)
	local model, root, cfg = r.Model, r.Root, r.Config
	local st = r.TyreFxState
	if not st then
		st = { wheels = {}, bones = Fx.Bones(cfg) }
		r.TyreFxState = st
	end
	ageMarks()
	local enabled = model:GetAttribute("TyreFx") ~= false
	local fx = (enabled and s.TyreFx) or {}
	local spm = r.Spm
	local smokeColor = model:GetAttribute("TyreSmokeColor")
	if typeof(smokeColor) ~= "Color3" then
		smokeColor = Fx.SmokeColor
	end
	rayParams.FilterDescendantsInstances = { model, markFolder() }
	local blend = 1 - math.exp(-Fx.MarkRate * math.max(dt, 0))
	for _, bone in ipairs(st.bones) do
		local w = cfg.Wheels[bone]
		local ws = st.wheels[bone]
		if not ws then
			ws = { alpha = 0 }
			st.wheels[bone] = ws
		end
		local k = fx[bone] or 0
		-- opacité visée, lissée : entre et sort en fondu au lieu de sauter d'un bloc à l'autre
		local target = k > 0 and Fx.MarkAlpha * k ^ Fx.MarkGamma or 0
		ws.alpha += (target - ws.alpha) * blend
		if target == 0 and ws.alpha < 0.03 then
			ws.alpha = 0
		end
		local hit
		if k > 0 or ws.last then
			local susp = (s.Suspension and s.Suspension[bone] or 0) * spm
			local center = root.CFrame:PointToWorldSpace(Vector3.new(w.Position[1], w.Position[2], w.Position[3]) * spm + Vector3.new(0, susp, 0))
			local reach = (w.Radius or 0.33) * spm + 1.5
			hit = Workspace:Raycast(center, -root.CFrame.UpVector * reach, rayParams)
			if hit and hit.Material == Enum.Material.Water then
				hit = nil -- sur l'eau : rien
			end
		end
		local soft = hit and SOFT[hit.Material.Name] == true
		-- fumée
		if hit and k > Fx.SmokeStart then
			if not ws.emitter then
				ws.att, ws.emitter = makeEmitter(root, bone)
			end
			ws.att.WorldCFrame = CFrame.new(hit.Position + hit.Normal * 0.3)
			local color = soft and surfaceColor(hit.Material) or smokeColor
			if ws.color ~= color then
				ws.color = color
				ws.emitter.Color = ColorSequence.new(color)
			end
			ws.emitter.Rate = Fx.SmokeRate * (k - Fx.SmokeStart) / (1 - Fx.SmokeStart)
		elseif ws.emitter then
			ws.emitter.Rate = 0
		end
		-- trace
		if hit then
			local p = hit.Position + hit.Normal * Fx.Lift
			local width = (w.Width or 0.22) * spm * Fx.MarkWidth
			local mColor = soft and surfaceColor(hit.Material):Lerp(Color3.new(0, 0, 0), 0.45) or Fx.MarkColor
			if ws.last then
				local dist = (p - ws.last).Magnitude
				if dist > Fx.SegMax then
					ws.last, ws.seg = nil, nil
				elseif dist >= Fx.SegMin then
					extendTrail(ws, p, hit.Normal, ws.alpha, width, mColor)
					ws.still, ws.patches = 0, 0
				elseif k > 0 then
					-- burn sur place : la gomme s'accumule sous la roue en une tache qui fonce (GTA), sans
					-- dépasser PatchMax couches au même endroit
					ws.still = (ws.still or 0) + dt
					if ws.still >= Fx.PatchEvery and (ws.patches or 0) < Fx.PatchMax then
						ws.still = 0
						ws.patches = (ws.patches or 0) + 1
						local fwd = root.CFrame.LookVector
						fwd = (fwd - hit.Normal * fwd:Dot(hit.Normal))
						local across = fwd.Magnitude > 1e-3 and acrossOf(fwd.Unit, hit.Normal)
						if across then
							local half = fwd.Unit * ((w.Radius or 0.33) * spm * 0.6)
							local a = ws.alpha * 0.5
							layMark(p - half, p + half, across, across, a, a, width, mColor)
						end
					end
				end
				-- fin de trace : la roue ne glisse plus et l'opacité est retombée à 0
				if k == 0 and ws.alpha == 0 then
					ws.last, ws.seg = nil, nil
				end
			elseif k > 0 then
				ws.last, ws.lastAlpha, ws.seg = p, 0, nil -- départ à opacité nulle : la trace entre en fondu
				ws.still, ws.patches = 0, 0
			end
		else
			ws.last, ws.seg = nil, nil
		end
	end
end

-- arrêt (véhicule hors de portée, détaché) : plus de fumée, la trace en cours se termine
function Fx.Stop(r)
	local st = r.TyreFxState
	if not st then
		return
	end
	for _, ws in pairs(st.wheels) do
		if ws.emitter then
			ws.emitter.Rate = 0
		end
		ws.last, ws.seg, ws.alpha = nil, nil, 0
	end
end

-- efface toutes les traces de ce client (tests)
function Fx.ClearMarks()
	if marks.host then
		marks.host:Destroy()
		marks.host = nil
	end
	table.clear(marks.list)
	marks.cursor, marks.scan = 0, 0
end

function Fx.MarkCount()
	local n = 0
	for _, m in ipairs(marks.list) do
		if m.live then
			n += 1
		end
	end
	return n
end

return Fx
