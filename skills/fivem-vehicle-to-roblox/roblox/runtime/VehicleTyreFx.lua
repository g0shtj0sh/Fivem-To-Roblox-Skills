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

	Intensité d'une roue (0..1) : 0 tant que le glissement combiné de VehicleDynamics reste sous le pic
	d'adhérence (SlideStart) ; au-delà, elle suit la vitesse de glissement au contact (V0 → V1 m/s).
	Le conducteur la calcule à chaque image (VehicleDrive → télémétrie `TyreFx`) ; les autres clients la
	lisent dans l'attribut `TyreFx` du véhicule (4 bits par roue, roues triées par nom d'os, 10 Hz).

	Réglages par véhicule : attribut `TyreSmokeColor` (Color3, comme la couleur de fumée de pneu de GTA) ;
	`TyreFx = false` sur le véhicule pour couper l'effet.
	Seuils, tailles et durées posés à l'œil contre les vidéos de référence : non mesurés dans GTA.
]]
local Workspace = game:GetService("Workspace")

local Fx = {}
Fx.SlideStart = 1.0 -- glissement combiné (VehicleDynamics, 1 = pic d'adhérence) à partir duquel la roue marque
Fx.V0 = 1.5 -- m/s de glissement au contact : début de la trace et de la fumée
Fx.V1 = 10 -- m/s : intensité pleine
Fx.SmokeRate = 40 -- particules par seconde et par roue à intensité pleine
Fx.SmokeColor = Color3.fromRGB(228, 228, 228)
Fx.MarkColor = Color3.fromRGB(18, 18, 18)
Fx.MarkAlpha = { 0.3, 0.75 } -- opacité de la trace à intensité nulle / pleine
Fx.MarkWidth = 0.85 -- part de la largeur du pneu
Fx.SegMin = 0.6 -- studs entre deux points de trace
Fx.SegMax = 8 -- au-delà (téléport, saut), la trace repart de zéro
Fx.MaxMarks = 1500 -- segments gardés sur ce client (les plus vieux sont repris)
Fx.MarkLife = 120 -- s avant que la trace ne commence à s'effacer
Fx.MarkFade = 20 -- s d'effacement
Fx.PatchEvery = 0.35 -- s : burn sur place, une couche de gomme de plus sous la roue
Fx.PatchMax = 6 -- couches au plus au même endroit
Fx.SmokeTexture = "rbxasset://textures/particles/smoke_main.dds"

-- sols meubles : pas de fumée de gomme mais de la poussière, et une trace de la couleur du sol (GTA : traces
-- de terre). L'eau ne donne rien.
local SOFT = {
	Grass = true, LeafyGrass = true, Ground = true, Mud = true, Sand = true, Snow = true,
}

-- ------------------------------------------------------------------ intensité et transport
function Fx.Intensity(slip, slipV, grounded)
	if not grounded or (slip or 0) < Fx.SlideStart then
		return 0
	end
	return math.clamp(((slipV or 0) - Fx.V0) / (Fx.V1 - Fx.V0), 0, 1)
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
local marks = { list = {}, cursor = 0, scan = 0, folder = nil }

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

local function newMarkPart()
	local p = Instance.new("Part")
	p.Name = "TyreMark"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Locked = true
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = markFolder()
	return p
end

local function layMark(a, b, normal, width, alpha, color)
	local d = b - a
	local len = d.Magnitude
	if len < 1e-3 then
		return
	end
	marks.cursor = marks.cursor % Fx.MaxMarks + 1
	local m = marks.list[marks.cursor]
	if not m then
		m = { part = newMarkPart() }
		marks.list[marks.cursor] = m
	end
	local fwd = d / len
	local right = fwd:Cross(normal)
	if right.Magnitude < 1e-3 then
		return
	end
	right = right.Unit
	local up = right:Cross(fwd)
	local mid = (a + b) / 2 + normal * 0.02
	local p = m.part
	p.Size = Vector3.new(width, 0.05, len)
	p.CFrame = CFrame.fromMatrix(mid, right, up)
	p.Color = color
	p.Transparency = 1 - alpha
	m.alpha = alpha
	m.born = os.clock()
	m.live = true
end

-- effacement progressif des vieilles traces : une tranche du pool par image
local function ageMarks()
	local n = #marks.list
	local now = os.clock()
	if n == 0 or marks.agedAt == now then
		return -- une seule tranche par image, quel que soit le nombre de véhicules
	end
	marks.agedAt = now
	local fadeStart = Fx.MarkLife
	for _ = 1, math.min(60, n) do
		marks.scan = marks.scan % n + 1
		local m = marks.list[marks.scan]
		if m and m.live then
			local age = now - m.born
			if age > fadeStart then
				local f = math.clamp((age - fadeStart) / Fx.MarkFade, 0, 1)
				m.part.Transparency = 1 - m.alpha * (1 - f)
				if f >= 1 then
					m.live = false
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
	for _, bone in ipairs(st.bones) do
		local w = cfg.Wheels[bone]
		local ws = st.wheels[bone]
		if not ws then
			ws = {}
			st.wheels[bone] = ws
		end
		local k = fx[bone] or 0
		local hit
		if k > 0 then
			local susp = (s.Suspension and s.Suspension[bone] or 0) * spm
			local center = root.CFrame:PointToWorldSpace(Vector3.new(w.Position[1], w.Position[2], w.Position[3]) * spm + Vector3.new(0, susp, 0))
			local reach = (w.Radius or 0.33) * spm + 1.5
			hit = Workspace:Raycast(center, -root.CFrame.UpVector * reach, rayParams)
			if hit and hit.Material == Enum.Material.Water then
				hit = nil -- sur l'eau : rien
			end
		end
		-- fumée
		if hit then
			if not ws.emitter then
				ws.att, ws.emitter = makeEmitter(root, bone)
			end
			local soft = SOFT[hit.Material.Name] == true
			ws.att.WorldCFrame = CFrame.new(hit.Position + hit.Normal * 0.3)
			local color = soft and surfaceColor(hit.Material) or smokeColor
			if ws.color ~= color then
				ws.color = color
				ws.emitter.Color = ColorSequence.new(color)
			end
			ws.emitter.Rate = Fx.SmokeRate * k
			-- trace
			local p = hit.Position
			local width = (w.Width or 0.22) * spm * Fx.MarkWidth
			local alpha = Fx.MarkAlpha[1] + (Fx.MarkAlpha[2] - Fx.MarkAlpha[1]) * k
			local mColor = soft and surfaceColor(hit.Material):Lerp(Color3.new(0, 0, 0), 0.45) or Fx.MarkColor
			if ws.last then
				local dist = (p - ws.last).Magnitude
				if dist > Fx.SegMax then
					ws.last = p
				elseif dist >= Fx.SegMin then
					layMark(ws.last, p, hit.Normal, width, alpha, mColor)
					ws.last = p
					ws.still, ws.patches = 0, 0
				else
					-- burn sur place : la gomme s'accumule sous la roue en une tache qui fonce (GTA), sans
					-- dépasser PatchMax couches au même endroit
					ws.still = (ws.still or 0) + dt
					if ws.still >= Fx.PatchEvery and (ws.patches or 0) < Fx.PatchMax then
						ws.still = 0
						ws.patches = (ws.patches or 0) + 1
						local fwd = root.CFrame.LookVector
						fwd = (fwd - hit.Normal * fwd:Dot(hit.Normal))
						if fwd.Magnitude > 1e-3 then
							local half = fwd.Unit * ((w.Radius or 0.33) * spm * 0.6)
							layMark(p - half, p + half, hit.Normal, width, alpha * 0.6, mColor)
						end
					end
				end
			else
				ws.last = p
				ws.still, ws.patches = 0, 0
			end
		else
			if ws.emitter then
				ws.emitter.Rate = 0
			end
			ws.last = nil
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
		ws.last = nil
	end
end

-- efface toutes les traces de ce client (tests)
function Fx.ClearMarks()
	for _, m in ipairs(marks.list) do
		m.part:Destroy()
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
