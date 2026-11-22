--!nonstrict
-- FiveMVehicles/VehicleDrive (ModuleScript, CLIENT du conducteur)
-- Fait rouler le véhicule : un spherecast par roue, VehicleDynamics pour les forces, une VectorForce et un
-- Torque (monde) sur VehicleRoot, et la télémétrie vers VehicleRuntime (son, roues, volant, feux de recul).
-- Le serveur confie la physique au conducteur (SetNetworkOwner) ; ce module ne tourne que chez lui.
--
--   local Drive = require(FiveMVehicles.VehicleDrive)
--   Drive.Start(car)                     -- fait automatiquement par FiveMVehiclesClient pour le conducteur
--   Drive.SetOverride({ Throttle = 1 })  -- entrées imposées (tests, IA) ; nil pour rendre la main au joueur
--   Drive.Get()                          -- { sim, out, car } du véhicule conduit (lecture)
--   Drive.Stop()
--
-- Brancher son propre châssis à la place de VehicleDynamics : voir references/roblox-integration.md
-- (« Interface d'adaptation ») — mêmes entrées (VehicleInput.Controls), même télémétrie (Runtime.SetTelemetry).

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local folder = script.Parent
local Dyn = require(folder:WaitForChild("VehicleDynamics"))
local Runtime = require(folder:WaitForChild("VehicleRuntime"))
local Input = require(folder:WaitForChild("VehicleInput"))
local TyreFx = require(folder:WaitForChild("VehicleTyreFx"))
-- VehicleDamage peut arriver chez le client APRÈS ce module (réplication au démarrage : constaté 2026-11-16, aucun
-- choc n'était envoyé) : cherché à nouveau toutes les 2 s tant qu'il manque
local damageMod, damageLook = nil, -math.huge
local function damageApi()
	if damageMod == nil and os.clock() - damageLook > 2 then
		damageLook = os.clock()
		local m = folder:FindFirstChild("VehicleDamage")
		local ok, mod = pcall(function()
			return m and require(m)
		end)
		damageMod = (ok and mod) or nil
	end
	return damageMod
end

local Drive = {}
Drive.Active = nil -- { car, cfg, sim, root, spm, wheels, ... }
Drive.Override = nil
Drive.StepMode = nil -- "BindToSimulation" | "PreSimulation"

-- Régulateur (« cruise ») et limiteur (« limit ») de vitesse, pour le RP (2026-11-16). Régulateur : garde la vitesse
-- choisie, l'accélérateur du joueur passe par-dessus, frein / frein à main / marche arrière le coupent. Limiteur :
-- plafonne l'accélérateur à la vitesse choisie. Un correcteur PI agit sur l'accélérateur seulement.
Drive.Cruise = nil -- { mode, target (m/s), i }
Drive.CruiseChanged = Instance.new("BindableEvent") -- (mode | nil, km/h | nil, raison | nil)
Drive.CruiseMinKmh = 20
Drive.LimiterDefaultKmh = 50

local function cruiseOff(reason)
	if Drive.Cruise then
		Drive.Cruise = nil
		Drive.CruiseChanged:Fire(nil, nil, reason)
	end
end

-- Active / coupe le régulateur ("cruise") ou le limiteur ("limit") à la vitesse actuelle. Renvoie true si actif.
function Drive.ToggleCruise(mode)
	local a = Drive.Active
	if not a then
		return false
	end
	if Drive.Cruise and Drive.Cruise.mode == mode then
		cruiseOff("off")
		return false
	end
	local v = (a.out and a.out.speed) or 0
	local kmh = v * 3.6
	if mode == "cruise" and (kmh < Drive.CruiseMinKmh or (a.out and a.out.reverse)) then
		Drive.CruiseChanged:Fire(nil, nil, "too_slow")
		return false
	end
	if mode == "limit" then
		kmh = kmh >= 10 and math.floor(kmh / 5 + 0.5) * 5 or Drive.LimiterDefaultKmh
	end
	Drive.Cruise = { mode = mode, target = kmh / 3.6, i = (a.lastThrottle or 0.3) }
	Drive.CruiseChanged:Fire(mode, math.floor(kmh + 0.5), nil)
	return true
end

local function findOrMake(parent, className, name)
	local o = parent:FindFirstChild(name)
	if o and o.ClassName == className then
		return o
	end
	o = Instance.new(className)
	o.Name = name
	o.Parent = parent
	return o
end

-- forces : créées par le Setup (DriveAttachment / DriveForce / DriveTorque) ; recréées localement si absentes
local function actuators(root)
	local att = findOrMake(root, "Attachment", "DriveAttachment")
	local vf = findOrMake(root, "VectorForce", "DriveForce")
	vf.Attachment0 = att
	vf.ApplyAtCenterOfMass = true
	vf.RelativeTo = Enum.ActuatorRelativeTo.World
	local tq = findOrMake(root, "Torque", "DriveTorque")
	tq.Attachment0 = att
	tq.RelativeTo = Enum.ActuatorRelativeTo.World
	vf.Enabled, tq.Enabled = true, true
	return vf, tq
end

local function excludeList(car)
	local list = { car }
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	return list
end

function Drive.Stop()
	local a = Drive.Active
	cruiseOff("exit")
	Drive.Active = nil
	if not a then
		return
	end
	for _, c in ipairs(a.conns) do
		c:Disconnect()
	end
	if a.ghost and Drive.RestoreGhost then
		Drive.RestoreGhost(a)
	end
	if a.unbind then
		pcall(a.unbind)
	end
	if a.vf then
		a.vf.Force = Vector3.zero
	end
	if a.tq then
		a.tq.Torque = Vector3.zero
	end
	Runtime.SetTelemetry(a.car, nil)
end

function Drive.SetOverride(t)
	Drive.Override = t
end

function Drive.Get()
	return Drive.Active
end

-- ------------------------------------------------------------------ choc contre le véhicule d'un autre joueur
-- Chaque conducteur simule SA voiture ; celle d'un autre joueur n'est chez lui qu'une copie reçue par le réseau, que
-- le moteur physique traite comme un objet de masse infinie qui avance. Mesuré (Play 2 joueurs, 2026-11-19, 355e
-- contre m422, 41 + 41 km/h de face) : chacune repartait EN ARRIÈRE à 35-38 km/h, comme une balle sur un mur qui
-- avance. 1re correction (2026-11-19) : au pas du choc, vitesse dans l'axe des deux véhicules = choc entre deux masses.
-- Banc 2 joueurs du 2026-11-22 (crash2_bench, 355e contre 355e) : encore faux dès que les deux clients ne voient pas
-- le choc au même moment.
--   * arrière 60 km/h sur voiture arrêtée (attendu : les deux à ~30) : la percutante s'arrêtait net (elle retapait
--     la copie de l'autre, encore immobile chez elle le temps de la réplication), la percutée partait à 18 km/h (son
--     client voyait le choc 0,25 s plus tard, avec la vitesse de l'autre déjà réduite) ;
--   * côté 50 km/h : la percutée 14 km/h et AUCUN dégât (sa variation de vitesse < MinImpact) ;
--   * de face 60 + 60 : arrêt juste, mais 0,5 m de hausse, roulis 18-31°, lacet 31° et 13 km/h de recul pour l'une
--     (la copie, de masse infinie, pousse aussi en hauteur et en rotation, et continue d'avancer).
-- Méthode actuelle :
--   1. le premier client qui voit le choc calcule le résultat pour LES DEUX (quantité de mouvement conservée, rebond
--      PairElasticity), avec sa vitesse et celle de la copie juste avant ; la poussée du pas (hausse, rotation,
--      dérive) est ramenée à la part réelle du choc (facteur k) ;
--   2. il l'envoie (« PairHit ») : le serveur applique les dégâts aux deux (même Δv, chacun de son côté) et transmet
--      au conducteur de l'autre sa variation de vitesse ; s'il a vu le choc plus tard, ou pas encore, il l'adopte (le
--      plus ancien GetServerTimeNow l'emporte des deux côtés) ;
--   3. la copie de l'autre ne nous touche plus (groupe fantôme, local) tant qu'elle est en retard sur la vraie
--      voiture : au moins PairGhostMin, jusqu'à ce qu'elles ne se chevauchent plus, au plus PairGhostMax.
-- Voiture qui retombe sur une autre : pas de changement de vitesse (le sol porte celle du dessous), mais le client
-- de celle du dessus fait appliquer à l'autre les dégâts du toit. Une voiture garée réveillée (simulée par nous,
-- VehicleAccess) n'est pas concernée : là, la physique est juste.
Drive.PairImpactDv = 0.6 -- m/s de variation horizontale en une image (60 Hz) : seuil de choc. 2 avant le 2026-11-22 :
-- un second contact lent (on rattrape l'autre, qui freine) restait à la physique, et contre une copie de masse
-- infinie la voiture montait dessus (roulis 41-44°). Un freinage à 1 g fait 0,16 m/s par image : seul un contact
-- (avec une voiture d'un autre joueur à portée, qui se rapproche) atteint 0,6.
Drive.PairVerticalDv = 2 -- m/s de variation verticale : retombée sur l'autre
Drive.PairElasticity = 0.05
Drive.PairWindow = 0.5 -- s : arbitrage entre les deux clients, et à-coups de la copie annulés pendant
Drive.PairStepDv = 1 -- m/s dans l'axe du choc en un pas, pendant la fenêtre : poussée de la copie, annulée
Drive.PairSnapDv = 0.5 -- m/s : rapprochement en dessous duquel un à-coup contre une copie est un rattrapage réseau
Drive.PairSnapRel = 1.5 -- m/s : … à condition que les deux ne bougent presque pas l'une par rapport à l'autre
Drive.PairGhostMin = 0.4 -- s : le temps que la copie de l'autre reflète le choc (réplication)
Drive.PairGhostMax = 3 -- s
-- Après le choc, chaque client a arrêté sa voiture contre la copie EN RETARD de l'autre : les vraies voitures finissent
-- l'une dans l'autre (de face 60 + 60 km/h : centres CROISÉS, mesuré 2026-11-22). Chacune s'écarte alors de l'autre
-- dans l'axe du choc jusqu'à la distance de deux pare-chocs moins PairCrumple (tôle écrasée), à PairSeparate de plus
-- que la vraie voiture de l'autre : un rebond réel (coefficient 0,1-0,2 à 60 km/h) est du même ordre.
Drive.PairSeparate = 2.5 -- m/s
Drive.PairSeparateMaxDv = 0.02 -- m/s par pas au plus (≈ 5 m/s² à 240 Hz) : poussée douce, jamais de lancer
Drive.PairCrumple = 1 -- m : écrasement total des deux tôles laissé
Drive.PairFullAngle = 50 -- ° entre rapprochement et axe des centres : en deçà, choc plein
Drive.PairTiltDamp = 0.96 -- par pas à 240 Hz : vitesses de tangage et de roulis divisées par ~10 en 0,25 s, après un choc
-- Mémoire d'un choc avec chaque autre voiture : un message « PairHit » de l'autre arrivé après la fenêtre (0,6 s sous
-- charge, mesuré 2026-11-22) était pris pour un NOUVEAU choc et réappliqué (les deux renvoyées à ~30 km/h) ; et un
-- second à-coup contre la même voiture garde l'axe du premier (centres croisés : l'axe recalculé s'inversait).
Drive.PairMemory = 2 -- s
Drive.PairGhostGroup = "FiveMVehicleDebris" -- groupe déjà non collisionnable avec les véhicules (VehicleAccess)
local CollectionService = game:GetService("CollectionService")
local XZ = Vector3.new(1, 0, 1)

local radiusCache = setmetatable({}, { __mode = "k" })
-- demi-diagonale horizontale de la boîte du véhicule (m), lue dans sa VehicleConfig
local function radiusOf(model)
	local r = radiusCache[model]
	if r then
		return r
	end
	r = 3
	local m = model:FindFirstChild("VehicleConfig")
	local ok, cfg = pcall(function()
		return m and require(m)
	end)
	local b = ok and cfg and cfg.Bounds
	if b then
		local dx = math.max(math.abs(b.Min[1]), math.abs(b.Max[1]))
		local dz = math.max(math.abs(b.Min[3]), math.abs(b.Max[3]))
		r = math.sqrt(dx * dx + dz * dz)
	end
	radiusCache[model] = r
	return r
end

local function otherVehicleInContact(car, root, spm)
	local best, bestD = nil, math.huge
	local myR = radiusOf(car) * spm
	for _, other in ipairs(CollectionService:GetTagged("FiveMVehicle")) do
		local oroot = other ~= car and other.PrimaryPart
		-- conduite par un AUTRE joueur (DriverUserId posé par le serveur) : chez nous, une copie réseau. Une voiture
		-- garée réveillée à notre approche est simulée par nous (VehicleAccess) : pas concernée. (ReceiveAge ne les
		-- distingue pas : 0 aussi pour la copie, mesuré 2026-11-19.)
		local driverId = other ~= car and other:GetAttribute("DriverUserId")
		local me = Players.LocalPlayer
		if oroot and not oroot.Anchored and type(driverId) == "number" and driverId ~= 0 and me and driverId ~= me.UserId then
			local d = ((oroot.Position - root.Position) * XZ).Magnitude
			local reach = myR + radiusOf(other) * spm + 1.5 * spm
			if d < reach and d < bestD then
				best, bestD = other, d
			end
		end
	end
	return best
end

-- la copie de l'autre véhicule passe dans le groupe fantôme, chez nous seulement (propriété non répliquée)
local function restoreGhost(a)
	local g = a.ghost
	if not g then
		return
	end
	a.ghost = nil
	for p, group in pairs(g.saved) do
		if p.Parent and p.CollisionGroup == Drive.PairGhostGroup then
			p.CollisionGroup = group
		end
	end
end
Drive.RestoreGhost = restoreGhost

-- vOther : vitesse estimée de la VRAIE voiture de l'autre après le choc (la copie, en retard, ne la montre pas encore)
-- demi-boîte (m) du véhicule, lue dans sa VehicleConfig
local halfCache = setmetatable({}, { __mode = "k" })
local function halfOf(model)
	local h = halfCache[model]
	if h then
		return h
	end
	h = Vector3.new(1, 0.8, 2.3)
	local m = model:FindFirstChild("VehicleConfig")
	local ok, cfg = pcall(function()
		return m and require(m)
	end)
	local b = ok and cfg and cfg.Bounds
	if b then
		h = Vector3.new(b.Max[1] - b.Min[1], b.Max[2] - b.Min[2], b.Max[3] - b.Min[3]) / 2
	end
	halfCache[model] = h
	return h
end
-- étendue (m) de la boîte du véhicule dans la direction n (monde)
local function extentAlong(model, cf, n)
	local h = halfOf(model)
	return math.abs(n:Dot(cf.RightVector)) * h.X + math.abs(n:Dot(cf.UpVector)) * h.Y + math.abs(n:Dot(cf.LookVector)) * h.Z
end

-- vOther : vitesse estimée de la VRAIE voiture de l'autre après le choc (la copie, en retard, ne la montre pas encore) ;
-- n : axe du choc (de l'autre vers nous) au moment où on l'a vu
local function ghostCopy(a, other, vOther, n, vPre)
	if a.ghost and a.ghost.model == other then
		a.ghost.t0 = os.clock()
		a.ghost.vOther = vOther or a.ghost.vOther
		a.ghost.n = n or a.ghost.n
		a.ghost.vPre = vPre or a.ghost.vPre
		return
	end
	restoreGhost(a)
	local saved = {}
	for _, p in ipairs(other:GetDescendants()) do
		if p:IsA("BasePart") and p.CanCollide and p.CollisionGroup ~= Drive.PairGhostGroup then
			saved[p] = p.CollisionGroup
			p.CollisionGroup = Drive.PairGhostGroup
		end
	end
	a.ghost = { model = other, saved = saved, t0 = os.clock(), checkAt = 0, vOther = vOther, n = n, vPre = vPre }
end

local ghostOverlap = OverlapParams.new()
ghostOverlap.FilterType = Enum.RaycastFilterType.Include
ghostOverlap.RespectCanCollide = false
-- Rend la vitesse corrigée (ou nil). Tant que les deux se chevauchent (après PairGhostMin), on s'écarte de la copie
-- à PairSeparate (chacun de son côté) : de face, chaque client arrête sa voiture contre la copie EN RETARD de
-- l'autre, les vraies voitures finissent l'une dans l'autre (60 + 60 km/h : centres à 1 m, mesuré 2026-11-22) ; rendre
-- la collision ainsi les faisait exploser (roulis 49°, 1 m de hausse).
local function updateGhost(a, root, now)
	local g = a.ghost
	if not g then
		return nil
	end
	local el = now - g.t0
	local oroot = g.model.PrimaryPart
	if el > Drive.PairGhostMax or not g.model.Parent or not oroot then
		restoreGhost(a)
		return nil
	end
	-- remis dans son groupe par une réplication (pièce remplacée, réglage du serveur) : de nouveau fantôme
	for p in pairs(g.saved) do
		if p.Parent and p.CollisionGroup ~= Drive.PairGhostGroup then
			p.CollisionGroup = Drive.PairGhostGroup
		end
	end
	local spm = a.spm
	local n = g.n
	if not n then
		local d = (root.Position - oroot.Position) * XZ
		n = d.Magnitude > 1e-3 and d.Unit or nil
	end
	if not n then
		return nil
	end
	-- la copie montre-t-elle déjà le choc (sa vitesse a fait l'essentiel du chemin vers celle estimée) ? Avant, elle
	-- est en retard : c'est l'estimation qui compte. Après, c'est elle (l'autre peut freiner fort : à l'arrière, la
	-- percutée freinait à ~1 g, la percutante la rattrapait dans la copie fantôme puis montait dessus, roulis 41°,
	-- mesuré 2026-11-22).
	local vCopy = oroot.AssemblyLinearVelocity
	if not g.caught then
		local est = g.vOther and g.vOther:Dot(n)
		local pre = g.vPre and g.vPre:Dot(n)
		g.caught = not est or not pre or math.abs(vCopy:Dot(n) - est) <= 0.4 * math.abs(pre - est) + 1 * spm
	end
	local vO = g.caught and vCopy or g.vOther or vCopy
	-- distance des centres dans l'axe du choc (fixé au choc : il s'inversait quand elles se traversaient) contre celle
	-- de deux voitures pare-chocs contre pare-chocs, moins l'écrasement de la tôle
	local dist = (root.Position - oroot.Position):Dot(n)
	local want = (extentAlong(a.car, root.CFrame, n) + extentAlong(g.model, oroot.CFrame, n) - Drive.PairCrumple) * spm
	if dist < want then
		if el >= Drive.PairGhostMin then
			local target = vO:Dot(n) + Drive.PairSeparate * spm
			local v = root.AssemblyLinearVelocity
			local cur = v:Dot(n)
			if cur < target then
				-- on roule vers l'autre : ce sont NOS freins qui ralentissent (vitesse imposée à la caisse, les pneus
				-- poussaient au ras du sol et la voiture se cabrait, 20° mesurés le 2026-11-22)
				local look = root.CFrame.LookVector
				local fwd = v:Dot(look) / spm
				-- dès qu'on roule (en avant ou en arrière) vers l'autre. De biais à 45°, une fois la glissade latérale
				-- mangée par les pneus, chaque voiture repartait dans l'axe de son capot, droit dans l'autre (centres
				-- à 0,6 m à l'arrêt, mesuré 2026-11-22)
				local amount = math.clamp((target - cur) / spm / 4, 0.25, 1)
				if fwd > 0.5 and -look:Dot(n) > 0.3 then
					return nil, amount
				elseif fwd < -0.5 and look:Dot(n) > 0.3 then
					return nil, amount, nil, true -- en marche arrière, c'est l'accélérateur qui freine
				end
				-- à l'arrêt ou presque : petite poussée, freins relâchés (sinon ils retiennent les roues). Sous ~0,3 m/s
				-- les pneus « collent » (VehicleDynamics, VStick) et annulaient 0,02 m/s par pas : départ à 0,6 m/s
				local step = Drive.PairSeparateMaxDv * spm
				if math.abs(cur) < 0.6 * spm then
					step = math.max(step, 0.6 * spm - math.abs(cur))
				end
				return v + n * math.min(target - cur, step), nil, true
			end
		end
		return nil
	end
	if el < Drive.PairGhostMin or not g.caught or now < g.checkAt then
		return nil
	end
	g.checkAt = now + 0.1
	local list = {}
	for p in pairs(g.saved) do
		if p.Parent then
			table.insert(list, p)
		end
	end
	ghostOverlap.FilterDescendantsInstances = list
	for _, p in ipairs(a.car:GetDescendants()) do
		if p:IsA("BasePart") and p.CanCollide and #Workspace:GetPartsInPart(p, ghostOverlap) > 0 then
			return nil -- encore l'une dans l'autre (coins) : on attend
		end
	end
	restoreGhost(a)
	return nil
end

Drive.PairTrace = {}
local function pairTrace(line)
	table.insert(Drive.PairTrace, line)
	if #Drive.PairTrace > 30 then
		table.remove(Drive.PairTrace, 1)
	end
end

-- roues remises à la vitesse imposée (Dyn.MatchWheelSpeed)
local function matchWheels(a, v)
	if a.sim and Dyn.MatchWheelSpeed then
		Dyn.MatchWheelSpeed(a.sim, -a.root.CFrame:VectorToObjectSpace(v).Z / a.spm)
	end
end

local function logPair(a, other, tServer, n)
	a.pairLog = a.pairLog or setmetatable({}, { __mode = "k" })
	local rec = a.pairLog[other]
	if rec and os.clock() - rec.t < Drive.PairMemory then
		rec.t = os.clock()
		rec.n = rec.n or n
		return rec
	end
	rec = { t = os.clock(), tServer = tServer, n = n }
	a.pairLog[other] = rec
	return rec
end
local function recentPair(a, other)
	local rec = a.pairLog and a.pairLog[other]
	return rec and os.clock() - rec.t < Drive.PairMemory and rec or nil
end

-- Rend vitesse et vitesse angulaire corrigées (ou nil), et true si la mesure de dégâts de ce pas est à sauter
-- (dégâts d'un choc entre joueurs appliqués par le serveur, « PairHit »).
local function pairImpact(a, root, vWorld, wWorld, now)
	local spm = a.spm
	local prev = a.prevVel
	local pair = a.pair
	if pair and (now > pair.untilT or not pair.root or not pair.root.Parent) then
		a.pair = nil
		pair = nil
	end
	if pair then
		if pair.n and prev and math.abs((vWorld - prev):Dot(pair.n)) / spm > Drive.PairStepDv then
			return prev, a.prevAng, true -- la copie pousse encore (en retard ou en avance sur la vraie voiture)
		end
		return nil
	end
	if not prev then
		return nil
	end
	local dvH = ((vWorld - prev) * XZ).Magnitude / spm
	local dvY = math.abs(vWorld.Y - prev.Y) / spm
	if dvH < Drive.PairImpactDv and dvY < Drive.PairVerticalDv then
		return nil
	end
	local other = otherVehicleInContact(a.car, root, spm)
	if not other then
		return nil
	end
	local oroot = other.PrimaryPart
	local tS = Workspace:GetServerTimeNow()
	if dvY >= Drive.PairVerticalDv and dvY > dvH then
		-- choc vertical : on retombe sur l'autre (au-dessus) ; le sol la porte, seules ses dégâts de toit sont à faire
		if oroot.Position.Y < root.Position.Y - 0.5 * spm and prev.Y < 0 then
			a.pair = { root = oroot, model = other, untilT = now + Drive.PairWindow, tServer = tS, prevVel = prev }
			a.pendingPair = { other, Vector3.new(0, -(vWorld.Y - prev.Y), 0), tS, nil, "top" }
		end
		return nil
	end
	local vB = a.prevOther and a.prevOther[other] or oroot.AssemblyLinearVelocity
	local d = (root.Position - oroot.Position) * XZ
	if d.Magnitude < 1e-3 then
		return nil
	end
	local rec = recentPair(a, other)
	local n = rec and rec.n or d.Unit -- de l'autre véhicule vers le nôtre (celui du premier choc s'il est récent)
	-- choc franc : l'axe est celui du rapprochement (vitesses exactes) et non des centres (la copie de l'autre est en
	-- retard : de biais à 45°, l'axe des centres penchait vers sa trajectoire et 60 % de la quantité de mouvement se
	-- perdait, mesuré 2026-11-22). Les deux repartent à la même vitesse (modèle « choc plein » de la reconstruction
	-- d'accidents). Choc rasant (au-delà de PairFullAngle) : axe des centres, un frottement ne les colle pas.
	local rel = (prev - vB) * XZ
	if not rec and rel.Magnitude > 0.5 * spm then
		local nRel = -rel.Unit
		if nRel:Dot(n) > math.cos(math.rad(Drive.PairFullAngle)) then
			n = nRel
		end
	end
	local mA, mB = root.AssemblyMass, oroot.AssemblyMass
	local uA, uB = prev:Dot(n), vB:Dot(n)
	if uA - uB > -Drive.PairSnapDv * spm then
		if rel.Magnitude > Drive.PairSnapRel * spm then
			-- elles bougent l'une par rapport à l'autre mais pas dans cet axe : contact rasant (coins), laissé à la
			-- physique. Le traiter en rattrapage rendait la copie fantôme : de biais à 45°, les deux voitures se
			-- traversaient (mesuré 2026-11-22)
			return nil
		end
		-- ne se rapprochaient pas (ou à peine), et pourtant un à-coup : c'est la copie de l'autre qui rattrape la vraie
		-- voiture d'un coup (réplication suspendue puis reprise : copie figée 0,5 s à 6 m de sa place, puis saut,
		-- mesuré de face 60 + 60 le 2026-11-22 : nous renvoyait à 31 km/h en arrière). Aucun choc réel : pas annulé.
		a.pair = { root = oroot, model = other, n = n, untilT = now + Drive.PairWindow, tServer = tS, prevVel = prev }
		ghostCopy(a, other, vB, n, vB)
		logPair(a, other, tS, n)
		return prev, a.prevAng, true
	end
	-- Impulsion au POINT DE CONTACT (reconstruction d'accidents, modèle « choc plein ») : vitesse ET rotation de
	-- lacet de chacune. Centré : comme avant (rotation nulle). Décalé (coin contre coin) : moins de vitesse perdue,
	-- et les voitures tournent. Avant (2026-11-22), un choc avant avec 0,4 m de recouvrement arrêtait net les deux.
	local e = Drive.PairElasticity
	local t = Vector3.new(-n.Z, 0, n.X) -- horizontal, perpendiculaire à l'axe
	local cA, cB = root.Position * XZ, oroot.Position * XZ
	local wA = extentAlong(a.car, root.CFrame, t) * spm
	local wB = extentAlong(other, oroot.CFrame, t) * spm
	local tA, tB = cA:Dot(t), cB:Dot(t)
	local lo, hi = math.max(tA - wA, tB - wB), math.min(tA + wA, tB + wB)
	local tc = lo < hi and (lo + hi) / 2 or (tA + tB) / 2 -- milieu de la zone qui se recouvre
	local sA = cA:Dot(n) - extentAlong(a.car, root.CFrame, n) * spm -- face de A tournée vers B
	local sB = cB:Dot(n) + extentAlong(other, oroot.CFrame, n) * spm -- face de B tournée vers A
	local pC = n * ((sA + sB) / 2) + t * tc
	local rA, rB = pC - cA, pC - cB
	local function crossY(r, vec) -- (r × vec).Y
		return r.Z * vec.X - r.X * vec.Z
	end
	local hA, hB = halfOf(a.car), halfOf(other)
	local IA = mA * ((2 * hA.X * spm) ^ 2 + (2 * hA.Z * spm) ^ 2) / 12 -- lacet, boîte pleine
	local IB = mB * ((2 * hB.X * spm) ^ 2 + (2 * hB.Z * spm) ^ 2) / 12
	local wAy = (a.prevAng or wWorld).Y
	local wBy = oroot.AssemblyAngularVelocity.Y
	local vpA = prev + Vector3.new(wAy * rA.Z, 0, -wAy * rA.X)
	local vpB = vB + Vector3.new(wBy * rB.Z, 0, -wBy * rB.X)
	local vrel = (vpA - vpB):Dot(n)
	if vrel >= 0 then
		vrel = uA - uB -- les points de contact s'éloignent déjà (rotation) : choc compté au centre
		rA, rB = Vector3.zero, Vector3.zero
	end
	local rnA, rnB = crossY(rA, n), crossY(rB, n)
	local k = 1 / mA + 1 / mB + rnA * rnA / IA + rnB * rnB / IB
	local j = -(1 + e) * vrel / k -- impulsion reçue par nous, le long de n
	local dvA, dvB = n * (j / mA), -n * (j / mB)
	local dwA, dwB = rnA * j / IA, -rnB * j / IB
	local v = prev + dvA
	-- rotation : celle d'avant le choc + celle de l'impulsion ; le reste du pas (tangage, roulis donnés par la copie
	-- de masse infinie) est jeté
	local w = (a.prevAng or Vector3.zero) + Vector3.new(0, dwA, 0)
	a.pair = { root = oroot, model = other, n = n, untilT = now + Drive.PairWindow, tServer = tS, prevVel = prev, prevAng = a.prevAng }
	ghostCopy(a, other, vB + dvB, n, vB)
	logPair(a, other, tS, n)
	a.pendingPair = { other, dvB, tS, dvA, nil, dwB }
	-- trace (bancs d'essai, 30 dernières lignes) : chocs calculés ici et reçus de l'autre client
	pairTrace(string.format("local t=%.2f uA=%.1f uB=%.1f vrel=%.1f dvA=%.1f dvB=%.1f dwA=%.2f n=(%.2f,%.2f)",
		tS % 100, uA / spm, uB / spm, vrel / spm, dvA.Magnitude / spm, dvB.Magnitude / spm, dwA, n.X, n.Z))
	return v, w, true
end

-- Variation de vitesse calculée par le client de l'autre conducteur (serveur, « PairHit ») : dvVec en studs/s,
-- tServer = heure serveur où il a vu le choc.
function Drive.OnPairHit(fromCar, dvVec, tServer, dwY)
	local a = Drive.Active
	if not a or typeof(fromCar) ~= "Instance" or typeof(dvVec) ~= "Vector3" or type(tServer) ~= "number" then
		return
	end
	dwY = (type(dwY) == "number" and dwY == dwY) and math.clamp(dwY, -12, 12) or 0 -- rad/s de lacet
	pairTrace(string.format("remote t=%.2f dv=%.1f dw=%.2f pair=%s", tServer % 100, dvVec.Magnitude / a.spm, dwY,
		tostring(a.pair and a.pair.model == fromCar and (a.pair.tServer % 100))))
	if dvVec.Magnitude / a.spm > 60 then
		return
	end
	local root = a.root
	local pair = a.pair
	if pair and pair.model == fromCar and os.clock() <= pair.untilT then
		if pair.tServer <= tServer then
			return -- nous l'avons vu en premier : notre calcul fait foi (l'autre client adopte le nôtre)
		end
		-- vu avant nous par l'autre (nous, avec sa copie en retard) : son calcul fait foi, tel quel (même axe des deux
		-- côtés, sinon chacun corrigeait dans le sien)
		local cur = root.AssemblyLinearVelocity
		local v = pair.prevVel + dvVec
		v = Vector3.new(v.X, cur.Y, v.Z)
		root.AssemblyAngularVelocity = (pair.prevAng or Vector3.zero) + Vector3.new(0, dwY, 0)
		root.AssemblyLinearVelocity = v
		a.prevVel = v
		matchWheels(a, v)
		pair.tServer = tServer
		return
	end
	if recentPair(a, fromCar) then
		return -- ce choc est déjà traité ici (message arrivé après la fenêtre) : ne pas le réappliquer
	end
	-- pas encore vu ici (la copie de l'autre n'est pas encore arrivée au contact)
	local oroot = fromCar.PrimaryPart
	local vCopy = (a.prevOther and a.prevOther[fromCar]) or (oroot and oroot.AssemblyLinearVelocity) or Vector3.zero
	local mRatio = oroot and root.AssemblyMass / math.max(oroot.AssemblyMass, 1e-3) or 1
	local v = root.AssemblyLinearVelocity + dvVec
	root.AssemblyLinearVelocity = v
	root.AssemblyAngularVelocity += Vector3.new(0, dwY, 0)
	a.prevVel = v
	a.prevAng = root.AssemblyAngularVelocity
	matchWheels(a, v)
	local h = dvVec * XZ
	a.pair = {
		root = fromCar.PrimaryPart, model = fromCar, n = h.Magnitude > 1e-3 and h.Unit or nil,
		untilT = os.clock() + Drive.PairWindow, tServer = tServer, prevVel = v - dvVec,
	}
	ghostCopy(a, fromCar, vCopy - dvVec * mRatio, h.Magnitude > 1e-3 and h.Unit or nil, vCopy)
	logPair(a, fromCar, tServer, h.Magnitude > 1e-3 and h.Unit or nil)
end

-- vitesses des autres véhicules au pas précédent (avant un choc, la copie reçue n'a pas encore bougé)
local function rememberOthers(a)
	local t = {}
	for _, other in ipairs(CollectionService:GetTagged("FiveMVehicle")) do
		local oroot = other ~= a.car and other.PrimaryPart
		if oroot then
			t[other] = oroot.AssemblyLinearVelocity
		end
	end
	a.prevOther = t
end

-- ------------------------------------------------------------------ piéton percuté
-- Sans rien, la voiture poussait un piéton DEBOUT devant elle comme un chasse-neige (mesuré, Play 2 joueurs
-- 2026-11-19 : joueur à pied percuté à 40 km/h, porté 51 m devant le pare-chocs, toujours debout, aucun dégât).
-- Le client du conducteur repère un personnage vivant et debout dans l'avant (ou l'arrière) de sa voiture qui
-- s'en rapproche vite ; le serveur valide (FiveMVehiclesServer, « HitPed ») et le fait renverser.
Drive.PedMinSpeed = 2.5 -- m/s de rapprochement : en dessous, on le pousse doucement, sans le renverser
Drive.PedEvery = 1 / 30 -- s entre deux recherches
Drive.PedCooldown = 1.5 -- s par victime
local pedParams = OverlapParams.new()
pedParams.FilterType = Enum.RaycastFilterType.Exclude
pedParams.RespectCanCollide = false

local function findPedestrians(a, root, cf, vWorld, now)
	if now - (a.pedAt or 0) < Drive.PedEvery then
		return
	end
	a.pedAt = now
	local spm = a.spm
	if (vWorld * XZ).Magnitude / spm < Drive.PedMinSpeed then
		return
	end
	local b = a.cfg.Bounds
	if not b then
		return
	end
	local lo = Vector3.new(b.Min[1], b.Min[2], b.Min[3])
	local hi = Vector3.new(b.Max[1], b.Max[2], b.Max[3])
	-- anticipation : le piéton doit être repéré AVANT le contact (voir plus bas), à toute vitesse
	local margin = 0.35 + (vWorld * XZ).Magnitude / spm * (Drive.PedEvery + 0.03)
	local size = (hi - lo + Vector3.new(2 * margin, 0.6, 2 * margin)) * spm
	local center = cf * CFrame.new((lo + hi) / 2 * spm + Vector3.new(0, 0.3 * spm, 0))
	local me = Players.LocalPlayer
	pedParams.FilterDescendantsInstances = { a.car, me and me.Character }
	local seen = {}
	for _, part in ipairs(Workspace:GetPartBoundsInBox(center, size, pedParams)) do
		local model = part:FindFirstAncestorOfClass("Model")
		local hum = model and model:FindFirstChildOfClass("Humanoid")
		local hrp = hum and model:FindFirstChild("HumanoidRootPart")
		if hrp and not seen[model] and hum.Health > 0 and not hum.SeatPart then
			seen[model] = true
			a.pedLast = a.pedLast or setmetatable({}, { __mode = "k" })
			if now - (a.pedLast[model] or -math.huge) >= Drive.PedCooldown then
				-- vitesse de rapprochement : vitesse de la voiture au point du piéton, moins la sienne, vers lui
				local rel = root:GetVelocityAtPosition(hrp.Position) - hrp.AssemblyLinearVelocity
				local toPed = (hrp.Position - root.Position) * XZ
				local closing = toPed.Magnitude > 1e-3 and rel:Dot(toPed.Unit) / spm or 0
				if closing >= Drive.PedMinSpeed then
					a.pedLast[model] = now
					a.pendingPeds = a.pendingPeds or {}
					table.insert(a.pendingPeds, { model, vWorld })
					-- Chez ce client, un piéton qu'il ne simule pas est une copie de masse infinie : la voiture s'y
					-- arrêtait net comme sur un mur (PNJ à 40 km/h : 41 → 2 km/h en un pas, 2026-11-19), ou le poussait
					-- quand Roblox nous en avait confié la physique. Un piéton (80 kg) ne freine presque pas une voiture :
					-- ici, ses pièces ne touchent plus cette voiture ; le serveur le renverse (« HitPed ») et pose le même
					-- groupe pour tous pendant qu'il est à terre.
					-- sauf joueur immunisé (attribut du jeu, KnockdownImmunityAttribute) : le serveur ne le renversera pas,
					-- la voiture le traversait debout pendant 4 s (audit 2026-11-19)
					local touched = {}
					local immunity = folder:GetAttribute("KnockdownImmunityAttribute")
					local victimPlayer = game:GetService("Players"):GetPlayerFromCharacter(model)
					local immune = victimPlayer ~= nil and type(immunity) == "string" and victimPlayer:GetAttribute(immunity) == true
					for _, d in ipairs(immune and {} or model:GetDescendants()) do
						if d:IsA("BasePart") and d.CollisionGroup ~= "FiveMVehicleOccupant" then
							touched[d] = d.CollisionGroup
							d.CollisionGroup = "FiveMVehicleOccupant"
						end
					end
					-- rendu après le renversement (≤ 3,5 s) ; le serveur, lui, rend le sien à la relève
					task.delay(4, function()
						for d, g in pairs(touched) do
							if d.Parent and d.CollisionGroup == "FiveMVehicleOccupant" then
								d.CollisionGroup = g
							end
						end
					end)
				end
			end
		end
	end
end

-- ------------------------------------------------------------------ dégâts de roue, herse
-- Herse : une pièce taguée « SpikeStrip », ou dans un modèle tagué ainsi (jusqu'à 3 parents).
local function isSpike(inst)
	for _ = 1, 4 do
		if not inst then
			return false
		end
		if CollectionService:HasTag(inst, "SpikeStrip") then
			return true
		end
		inst = inst.Parent
	end
	return false
end

-- { [os] = état } lu sur les attributs WheelState_<os> (VehicleDamage)
local function wheelStates(car)
	local t = {}
	for name, v in pairs(car:GetAttributes()) do
		if string.sub(name, 1, 11) == "WheelState_" then
			t[string.sub(name, 12)] = v
		end
	end
	return t
end

local function step(a, dt)
	local car, root, spm, sim = a.car, a.root, a.spm, a.sim
	if not car.Parent or not root.Parent then
		Drive.Stop()
		return
	end
	if root.Anchored then
		-- stationné, ou déplacé par le serveur (Access.Teleport) : forces coupées, état remis au repos
		a.vf.Force, a.tq.Torque = Vector3.zero, Vector3.zero
		-- une pièce ancrée garde sa vitesse et la reprend au désancrage (mesuré : véhicule rattrapé
		-- d'une chute à 166 studs/s puis projeté à 60 studs de haut) : on l'annule chez le propriétaire
		root.AssemblyLinearVelocity, root.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
		if not a.wasAnchored then
			a.wasAnchored = true
			Dyn.reset(sim)
			a.xPrev = {}
		end
		-- vitesses d'avant l'ancrage oubliées : au désancrage (Access.Teleport, rattrapage du vide, reprise par le
		-- contrôle de vraisemblance), la vitesse passait d'un coup de l'ancienne à 0 -> faux choc à pleine force
		-- (27 m/s à 100 km/h ; audit 2026-11-19). Sans prevVel, la mesure de choc attend 0,5 s (plus bas).
		a.prevVel, a.prevAng = nil, nil
		return
	end
	a.wasAnchored = false
	a.filterAge += dt
	if a.filterAge > 1 then
		a.filterAge = 0
		a.params.FilterDescendantsInstances = excludeList(car)
	end
	local cf = root.CFrame
	local up = cf.UpVector
	local P, S = sim.P, sim.S

	-- contacts : un spherecast par roue depuis le haut du débattement (+ marge), vers le bas de la caisse
	local contacts = {}
	local travelSt = P.travel * spm
	for i, w in ipairs(P.wheels) do
		local r = w.radius * spm
		local topLocal = (w.rest + Vector3.new(0, P.upper + P.raise, 0)) * spm
		local origin = cf:PointToWorldSpace(topLocal) + up * a.margin
		local len = a.margin + travelSt + a.extraReach
		-- roue arrachée (WheelState 3, VehicleDamage) : le contact reste (le moyeu frotte, VehicleDynamics)
		local state = w.state or 0
		local hit = Workspace:Spherecast(origin, r * 0.95, -up * len, a.params)
		-- pièce non solide (roue d'une autre voiture, décor) touchée par le rayon : pas un sol. Les rayons
		-- ignorent CanCollide (les herses, non solides, doivent être vues) : on roulait sur les cylindres de roues
		-- d'une voiture qu'on percutait, l'avant montait dessus (mesuré 2026-11-22, Play 2 joueurs)
		for _ = 1, 3 do
			if not hit or hit.Instance.CanCollide or isSpike(hit.Instance) then
				break
			end
			a.params:AddToFilter(hit.Instance)
			hit = Workspace:Spherecast(origin, r * 0.95, -up * len, a.params)
		end
		local c = { grounded = false, x = 0, xdot = 0, vLong = 0, vLat = 0, grip = 1 }
		if hit and state == 0 and isSpike(hit.Instance) then
			-- herse (tag SpikeStrip) : le serveur vérifie et crève le pneu (« Spike »)
			local now = os.clock()
			a.spikeAt = a.spikeAt or {}
			if now - (a.spikeAt[w.bone] or -math.huge) > 1 then
				a.spikeAt[w.bone] = now
				a.pendingSpikes = a.pendingSpikes or {}
				table.insert(a.pendingSpikes, w.bone)
			end
		end
		if hit then
			local d = hit.Distance - a.margin -- déplacement du centre de roue depuis le haut du débattement
			if state == 1 or state >= 3 then
				-- pneu à plat (ou moyeu d'une roue arrachée) : le coin descend. Pas pour une roue cassée (faussée, pas
				-- dégonflée), et peu : 7 cm sur un seul coin déchargeaient la diagonale par les barres anti-roulis
				-- (BavrenN4 : 0,68 et 0,32 au lieu de ≈ 2,45 m/s² de charge) ; la roue opposée patinait dans le vide
				-- et, différentiel ouvert, la voiture ne repartait plus (mesuré le 2026-11-19)
				d += (Dyn.Tuning.FlatDrop or 0.04) * spm
			end
			if d <= travelSt then
				local x = (travelSt - math.max(d, -travelSt)) / spm -- m depuis la détente maximale
				c.grounded = true
				c.x = x
				c.xdot = (x - (a.xPrev[i] or x)) / dt
				a.xPrev[i] = x
				local steer = Dyn.WheelSteer(sim, i)
				local fwd = (cf * CFrame.Angles(0, steer, 0)).LookVector
				local right = fwd:Cross(up)
				local vc = root:GetVelocityAtPosition(hit.Position)
				c.vLong = vc:Dot(fwd) / spm
				c.vLat = vc:Dot(right) / spm
				c.grip = Dyn.MaterialGrip(hit.Material.Name)
			else
				a.xPrev[i] = nil
			end
		else
			a.xPrev[i] = nil
		end
		contacts[i] = c
	end

	-- entrées
	local ctrl = Input.Controls
	local inp = {
		Throttle = ctrl.Throttle, Brake = ctrl.Brake, Steer = ctrl.Steer, Handbrake = ctrl.Handbrake or car:GetAttribute("ParkingBrake") == true,
		-- moteur HS (fumée noire) ou épave en feu : aucune poussée, même si un attribut local dit le contraire
		Engine = car:GetAttribute("Engine") ~= false and car:GetAttribute("EngineDead") ~= true
			and car:GetAttribute("Wrecked") ~= true,
		GearUp = a.gearUp, GearDown = a.gearDown,
	}
	a.gearUp, a.gearDown = false, false
	for k, v in pairs(Drive.Override or {}) do
		inp[k] = v
	end
	local cr = Drive.Cruise
	if cr then
		local v = (a.out and a.out.speed) or 0
		if cr.mode == "cruise" and ((inp.Brake or 0) > 0.1 or inp.Handbrake or (a.out and a.out.reverse) or not inp.Engine) then
			cruiseOff("brake")
		else
			local err = cr.target - v
			local u = math.clamp(0.35 * err + cr.i, 0, 1)
			if u > 0 and u < 1 then
				cr.i = math.clamp(cr.i + 0.12 * err * dt, 0, 1)
			end
			if cr.mode == "cruise" then
				inp.Throttle = math.max(inp.Throttle or 0, u)
			else
				inp.Throttle = math.min(inp.Throttle or 0, u)
			end
		end
	end
	-- moteur touché (VehicleDamage) : moins de puissance
	local Damage = damageApi()
	if Damage then
		inp.Throttle = (inp.Throttle or 0) * Damage.PowerFactor(car)
	end
	a.lastThrottle = inp.Throttle

	local vWorld = root.AssemblyLinearVelocity
	-- choc contre la voiture d'un autre joueur : vitesse corrigée (voir pairImpact) AVANT la mesure des dégâts, qui
	-- comptait sinon le double (rebond sur une copie de masse infinie)
	local fixedV, fixedW, pairSkip = pairImpact(a, root, vWorld, root.AssemblyAngularVelocity, os.clock())
	if fixedV then
		root.AssemblyLinearVelocity = fixedV
		vWorld = fixedV
		matchWheels(a, fixedV)
	end
	if fixedW then
		root.AssemblyAngularVelocity = fixedW
	end
	local sepV, sepBrake, sepNudge, sepReverse = updateGhost(a, root, os.clock())
	if sepBrake and sepReverse then
		inp.Throttle, inp.Brake = math.max(inp.Throttle or 0, sepBrake), 0
	elseif sepBrake then
		inp.Brake, inp.Throttle = math.max(inp.Brake or 0, sepBrake), 0
	end
	if sepNudge then
		inp.Brake, inp.Handbrake, inp.Throttle = 0, false, 0
	end
	if sepV then
		root.AssemblyLinearVelocity = sepV
		vWorld = sepV
		-- roues comprises : freinée par la caisse et poussée par des roues encore lancées, elle se cabrait (22°)
		matchWheels(a, sepV)
	end
	-- tangage et roulis amortis tant que dure l'après-choc entre joueurs : la caisse plongeait au choc (-6°) puis la
	-- suspension la renvoyait nez en l'air (12-23°, mesuré à l'arrière 60 km/h le 2026-11-22) ; lacet libre
	if a.ghost or a.pair then
		local wl = cf:VectorToObjectSpace(root.AssemblyAngularVelocity)
		local f = Drive.PairTiltDamp
		root.AssemblyAngularVelocity = cf:VectorToWorldSpace(Vector3.new(wl.X * f, wl.Y, wl.Z * f))
	end
	rememberOthers(a)
	findPedestrians(a, root, cf, vWorld, os.clock())
	-- choc : variation brutale de la vitesse horizontale en un pas (un freinage fort ≈ 0,2 m/s par pas) ; envoyée au
	-- serveur (VehicleDamage.Apply), direction = du centre vers le point touché, dans le repère du véhicule
	local wWorld = root.AssemblyAngularVelocity
	-- prise en main (le véhicule était garé / ancré, ou tenu par le serveur) : les vitesses lues ne se suivent pas, la
	-- première mesure donnait un faux choc à pleine force (mesuré 2026-11-18 : moteur −605 en s'asseyant) → 0,5 s sans
	-- mesure de choc
	if root.Anchored or not a.prevVel then
		a.impactArmedAt = os.clock() + 0.5
	end
	if Damage and a.prevVel and not root.Anchored and not pairSkip and os.clock() >= (a.impactArmedAt or 0) then
		-- choc 3D (VehicleDamage.Measure) : horizontal, vertical (toit, dessous) et rotation stoppée net (tonneaux)
		local dv = cf:VectorToObjectSpace(vWorld - a.prevVel) / spm
		local dw = a.prevAng and cf:VectorToObjectSpace(wWorld - a.prevAng) or Vector3.zero
		local dir, strength = (Damage.Measure or function() end)(dv, dw, cf.UpVector.Y)
		if dir and os.clock() - (a.lastImpact or 0) > 0.15 then
			a.lastImpact = os.clock()
			-- envoyé hors de la boucle physique (BindToSimulation : un FireServer fait ici n'arrivait jamais au
			-- serveur, mesuré 2026-11-16) : gardé, envoyé au prochain Heartbeat (le plus fort s'il y en a plusieurs)
			if not a.pendingImpact or a.pendingImpact[3] < strength then
				a.pendingImpact = { dir.X, dir.Z, strength, dir.Y }
			end
		end
	end
	a.prevAng = wWorld
	a.prevVel = vWorld
	local ctx = {
		vBody = cf:VectorToObjectSpace(vWorld) / spm,
		wBody = cf:VectorToObjectSpace(root.AssemblyAngularVelocity),
		up = cf:VectorToObjectSpace(Vector3.yAxis),
	}
	local out = Dyn.step(sim, inp, contacts, dt, ctx)
	a.out = out
	a.contacts = contacts

	-- forces spécifiques (m/s², local) -> forces Roblox (monde) : × StudsPerMeter × AssemblyMass
	local m = root.AssemblyMass
	local com = root.AssemblyCenterOfMass
	local Ftot, Ttot = Vector3.zero, Vector3.zero
	for i, w in ipairs(P.wheels) do
		local o = out.wheels[i]
		if contacts[i].grounded then
			local steerCF = cf * CFrame.Angles(0, o.steer, 0)
			local fwd, right = steerCF.LookVector, steerCF.RightVector
			local Fn = up * (o.Fz * spm * m)
			local Ft = (fwd * o.Fx + right * o.Fy) * (spm * m)
			local pN = cf:PointToWorldSpace(o.point * spm)
			local pT = cf:PointToWorldSpace(o.lateralPoint * spm)
			Ftot += Fn + Ft
			Ttot += (pN - com):Cross(Fn) + (pT - com):Cross(Ft)
		end
	end
	Ftot += cf:VectorToWorldSpace(out.body) * (spm * m)
	-- gravité : on vise la gravité du véhicule (P.g) au lieu de Workspace.Gravity
	Ftot += Vector3.yAxis * ((Workspace.Gravity / spm - P.g) * spm * m)
	Ttot += cf:VectorToWorldSpace(out.torque) * (spm * spm * m)
	a.vf.Force = Ftot
	a.tq.Torque = Ttot

	-- télémétrie -> rendu (son moteur, roues, volant, feux de recul, compte-tours)
	local audio = a.cfg.Audio or {}
	local idle, maxRpm = audio.IdleRpm or 850, audio.MaxRpm or 7200
	local spin, susp, tyre = {}, {}, {}
	if not a.rearZ then
		local z, n = 0, 0
		for _, w in ipairs(P.wheels) do
			if not w.front then
				z += w.rest.Z
				n += 1
			end
		end
		a.rearZ = n > 0 and z / n or 0
	end
	-- traces : une glisse de côté ne marque que si la voiture dérive (essieu arrière)
	local fzSum, fzN = 0, 0
	for _, ow in ipairs(out.wheels) do
		if ow.grounded then
			fzSum += ow.Fz or 0
			fzN += 1
		end
	end
	local tyreCtx = {
		drift = TyreFx.DriftAngle(ctx.vBody, ctx.wBody, a.rearZ),
		fzMean = fzN > 0 and fzSum / fzN or 0,
	}
	for i, w in ipairs(P.wheels) do
		spin[w.bone] = out.omega[i]
		susp[w.bone] = out.travel[i]
		local ow = out.wheels[i]
		tyre[w.bone] = TyreFx.Intensity(ow, tyreCtx)
	end
	Runtime.SetTelemetry(car, {
		-- sous le ralenti (démarreur, moteur qui s'arrête) : proportionnel, 0 = moteur arrêté
		Rpm = (out.rpm >= 0.2) and (idle + (math.min(out.rpm, 1) - 0.2) / 0.8 * (maxRpm - idle)) or (math.max(out.rpm, 0) / 0.2 * idle),
		Gear = out.gear,
		-- accélérateur EFFECTIF (en marche arrière, c'est S) : le son moteur en tire la charge enfoncé / relâché
		Throttle = out.drive or inp.Throttle,
		Brake = (inp.Brake or 0) > 0.1 and out.gear >= 1,
		Reverse = out.reverse,
		Speed = out.speed,
		Steer = -out.steerAngle / math.max(out.lock, 1e-3),
		WheelSteer = out.lock,
		WheelSpin = spin,
		Suspension = susp,
		TyreFx = tyre, -- traces et fumée par roue (VehicleTyreFx), 0..1
		Burnout = out.burnout,
	})
	car:SetAttribute("Gear", out.gear)
end

function Drive.Start(car)
	if Drive.Active and Drive.Active.car == car then
		return Drive.Active
	end
	Drive.Stop()
	local cfgModule = car:FindFirstChild("VehicleConfig")
	local root = car.PrimaryPart
	if not cfgModule or not root then
		return nil
	end
	local cfg = require(cfgModule)
	local spm = cfg.StudsPerMeter or 3.571
	local comLocal = root.CFrame:PointToObjectSpace(root.AssemblyCenterOfMass) / spm
	-- améliorations du garage (attributs Perf_<Slot> posés par VehicleCustomization)
	local function upgrades()
		local levels = {}
		for _, slot in ipairs(Dyn.UpgradeSlots) do
			levels[slot] = car:GetAttribute("Perf_" .. slot) or 0
		end
		return levels
	end
	-- tous les réglages Tune_<clé> du véhicule (VehicleCustomization.TuneKeys : multiplicateurs, pneus, préparation)
	local function tune()
		local t = {}
		for name, value in pairs(car:GetAttributes()) do
			if string.sub(name, 1, 5) == "Tune_" then
				t[string.sub(name, 6)] = value
			end
		end
		return t
	end
	local sim = Dyn.new(cfg, comLocal, nil, upgrades())
	Dyn.SetTune(sim, tune())
	local vf, tq = actuators(root)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = excludeList(car)
	params.IgnoreWater = true
	-- règles de collision du véhicule : les rayons des roues ignorent ce que la caisse traverse (débris d'ouvrants
	-- arrachés, corps renversés) ; sans ça les roues montaient sur une portière tombée (audit 2026-11-19)
	params.CollisionGroup = "FiveMVehicle"
	local a = {
		car = car, cfg = cfg, sim = sim, root = root, spm = spm, vf = vf, tq = tq, params = params,
		filterAge = 0, xPrev = {}, conns = {}, margin = 0.3 * spm, extraReach = 0.25 * spm,
	}
	table.insert(a.conns, car.AttributeChanged:Connect(function(attr)
		if string.sub(attr, 1, 5) == "Perf_" then
			Dyn.SetUpgrades(sim, upgrades())
		elseif string.sub(attr, 1, 5) == "Tune_" then
			Dyn.SetTune(sim, tune())
		elseif string.sub(attr, 1, 11) == "WheelState_" then
			Dyn.SetWheelStates(sim, wheelStates(car))
		end
	end))
	Dyn.SetWheelStates(sim, wheelStates(car))
	-- chocs mesurés dans la boucle physique, envoyés au serveur ici (VehicleDamage)
	table.insert(a.conns, RunService.Heartbeat:Connect(function()
		-- choc entre joueurs (pairImpact) : calcul pour les deux, envoyé au serveur (dégâts des deux, transmis à l'autre)
		local pp = a.pendingPair
		if pp then
			a.pendingPair = nil
			local remote = folder:FindFirstChild("VehicleEvent")
			if remote then
				remote:FireServer(car, "PairHit", pp[1], pp[2], pp[3], pp[4], pp[5], pp[6])
			end
		end
		local imp = a.pendingImpact
		if imp then
			a.pendingImpact = nil
			local remote = folder:FindFirstChild("VehicleEvent")
			if remote then
				remote:FireServer(car, "Impact", imp[1], imp[2], imp[3], imp[4])
			end
		end
		-- piétons percutés (findPedestrians), envoyés hors de la boucle physique comme les chocs
		-- roues sur une herse (contacts), envoyées hors de la boucle physique
		local spikes = a.pendingSpikes
		if spikes then
			a.pendingSpikes = nil
			local remote = folder:FindFirstChild("VehicleEvent")
			for _, bone in ipairs(remote and spikes or {}) do
				remote:FireServer(car, "Spike", bone)
			end
		end
		local peds = a.pendingPeds
		if peds then
			a.pendingPeds = nil
			local remote = folder:FindFirstChild("VehicleEvent")
			for _, hit in ipairs(remote and peds or {}) do
				remote:FireServer(car, "HitPed", hit[1], hit[2])
			end
		end
	end))
	table.insert(a.conns, Input.Action.Event:Connect(function(name)
		if name == "GearUp" then
			a.gearUp = true
		elseif name == "GearDown" then
			a.gearDown = true
		end
	end))
	-- pas fixe : BindToSimulation si disponible (indépendant des images), sinon PreSimulation
	local ok, conn = pcall(function()
		return RunService:BindToSimulation(function(dt)
			a.stepped = true
			step(a, typeof(dt) == "number" and dt or 1 / 60)
		end, Enum.StepFrequency.Hz60)
	end)
	if ok and conn then
		Drive.StepMode = "BindToSimulation"
		a.unbind = function()
			if typeof(conn) == "RBXScriptConnection" then
				conn:Disconnect()
			elseif typeof(conn) == "table" and conn.Disconnect then
				conn:Disconnect()
			end
		end
		-- certaines versions demandent UseFixedSimulation : si aucun pas n'arrive, on bascule
		task.delay(0.5, function()
			if Drive.Active == a and not a.stepped then
				pcall(a.unbind)
				Drive.StepMode = "PreSimulation"
				table.insert(a.conns, RunService.PreSimulation:Connect(function(dt)
					step(a, dt)
				end))
			end
		end)
	else
		Drive.StepMode = "PreSimulation"
		table.insert(a.conns, RunService.PreSimulation:Connect(function(dt)
			a.stepped = true
			step(a, dt)
		end))
	end
	Drive.Active = a
	return a
end

return Drive
