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
-- avance. Correction : au pas du choc, la vitesse dans l'axe des deux véhicules est remplacée par celle d'un choc
-- entre deux masses (quantité de mouvement conservée, rebond PairElasticity), calculée avec la vitesse de l'autre
-- AVANT le choc ; les deux clients font le même calcul et trouvent le même résultat. Un véhicule dont ce client
-- possède aussi la physique (voiture garée réveillée, VehicleAccess) n'est pas concerné : là, la physique est juste.
Drive.PairImpactDv = 2 -- m/s de variation horizontale en un pas : seuil de choc
Drive.PairElasticity = 0.05
Drive.PairWindow = 0.35 -- s : la copie de l'autre continue d'avancer le temps d'un aller-retour réseau ; corrigé pendant
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

-- vitesse corrigée (monde, studs/s) ou nil
local function pairImpact(a, root, vWorld, now)
	local spm = a.spm
	local pair = a.pair
	if not pair then
		if not a.prevVel or ((vWorld - a.prevVel) * XZ).Magnitude / spm < Drive.PairImpactDv then
			return nil
		end
		local other = otherVehicleInContact(a.car, root, spm)
		if not other then
			return nil
		end
		local oroot = other.PrimaryPart
		pair = {
			root = oroot,
			mB = oroot.AssemblyMass,
			vB = a.prevOther and a.prevOther[other] or oroot.AssemblyLinearVelocity,
			vA = a.prevVel,
			untilT = now + Drive.PairWindow,
		}
		a.pair = pair
	end
	if now > pair.untilT or not pair.root.Parent then
		a.pair = nil
		return nil
	end
	local d = (root.Position - pair.root.Position) * XZ
	if d.Magnitude < 1e-3 then
		return nil
	end
	local n = d.Unit -- de l'autre véhicule vers le nôtre
	local mA = root.AssemblyMass
	local uA, uB = pair.vA:Dot(n), pair.vB:Dot(n)
	if uA - uB >= 0 then
		return nil -- ne se rapprochaient pas dans cet axe
	end
	local e = Drive.PairElasticity
	local u = (mA * uA + pair.mB * uB - pair.mB * e * (uA - uB)) / (mA + pair.mB)
	-- seule la composante dans l'axe du choc est remplacée ; ce qui est transversal et vertical reste à la physique
	local cur = vWorld:Dot(n)
	if math.abs(cur - u) < 0.05 * spm then
		return nil
	end
	return vWorld + n * (u - cur)
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
					local touched = {}
					for _, d in ipairs(model:GetDescendants()) do
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
	local fixed = pairImpact(a, root, vWorld, os.clock())
	if fixed then
		root.AssemblyLinearVelocity = fixed
		vWorld = fixed
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
	if Damage and a.prevVel and not root.Anchored and os.clock() >= (a.impactArmedAt or 0) then
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
