--!nonstrict
--[[
	VehiclePose (ModuleScript, ReplicatedStorage.FiveMVehicles) — posture des occupants, sur CHAQUE client.

		local Pose = require(ReplicatedStorage.FiveMVehicles.VehiclePose)
		Pose.Start()          -- FiveMVehiclesClient l'appelle une fois : pose tous les occupants de tous les véhicules
		Pose.HipPoint(model, seat) -- point de hanche visé (mètres, repère du véhicule), lu par VehicleSeatFit

	Pourquoi : la posture assise de Roblox (buste droit, cuisses à l'horizontale, tibias verticaux) ne rentre
	pas dans un coupé bas. Sur le m422 (2026-11-12), les pieds passaient sous le siège, l'adaptation au
	siège réduisait le corps à 64 % (49 % en largeur) et, à la première personne, on voyait le volant de loin,
	au-dessus des sièges.

	Ce que fait GTA, et ce qu'on reprend :
	- la posture dépend du `layout` du véhicule (vehicles.meta, `CONFIG.Layout`) : LAYOUT_LOW (sportive basse)
	  joue un conducteur incliné, jambes allongées vers les pédales ; le bassin du personnage est posé sur
	  l'os du siège (`seat_*`) ;
	- la caméra à la première personne est à `PovCameraOffset` de l'os du siège (`Seats[i].PovOffset`, repère du
	  véhicule ; m422 : 22,5 cm en arrière et 58,5 cm au-dessus), pas sur la tête du personnage : Pose.EyeWorld,
	  utilisé par VehicleCamera.

	Comment : les articulations (Motor6D.Transform) sont réécrites à chaque image après l'animation d'assise
	(RunService.PreSimulation) ; les transforms ne se répliquent pas, d'où un calcul sur chaque client, identique
	partout (mêmes données). Bassin posé sur l'os du siège et incliné selon le layout ; jambes et bras par
	cinématique inverse à deux segments vers des cibles du véhicule : pieds sur le plancher devant le siège
	(lu dans la grille d'habitacle `CONFIG.Cabin`, sinon estimé), mains sur la jante du volant à 9 h 15 (elles
	suivent sa rotation) pour le conducteur, sur les cuisses pour les passagers. R15 complet ; R6 : angles fixes.

	Réglages : attribut `DrivingPose = false` sur le véhicule pour garder la posture de Roblox.
]]
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local Fit = require(script.Parent:WaitForChild("VehicleSeatFit"))

local Pose = {}
Pose.Tag = "FiveMVehicle"

-- Inclinaison du dossier (degrés, vers l'arrière) et extension des jambes (part de leur longueur) par layout.
-- Valeurs posées à l'œil sur le m422 (LAYOUT_LOW), non mesurées dans GTA.
Pose.Layouts = {
	LAYOUT_LOW = { recline = 22, legReach = 0.93 },
	LAYOUT_STANDARD = { recline = 14, legReach = 0.86 },
	default = { recline = 16, legReach = 0.88 },
}
-- layouts où cette posture n'a pas de sens (deux-roues, quads, bateaux, aéronefs) : posture de Roblox
Pose.Skip = { "BIKE", "QUAD", "BOAT", "JETSKI", "HELI", "PLANE", "BICYCLE", "TRAIN" }
Pose.GripAngle = 0 -- degrés au-dessus de l'horizontale : mains à 9 h 15, sur les côtés de la jante (à 30 °, « 10 h 10 », les avant-bras
-- cachaient le volant et les compteurs à la première personne ; demande de l'utilisateur, 2026-11-13)
Pose.GripRadius = 0.92 -- part du rayon de la jante (mesuré sur les pièces portées par l'os du volant)
Pose.DefaultPov = Vector3.new(0, 0.585, 0.225) -- m, repère du véhicule (PovCameraOffset GTA le plus courant)
Pose.HandTurnMax = 100 -- degrés : rotation du volant suivie par les mains

local cfgCache = setmetatable({}, { __mode = "k" })
local wheelCache = setmetatable({}, { __mode = "k" })
local footCache = setmetatable({}, { __mode = "k" })

local function config(model)
	local c = cfgCache[model]
	if c == nil then
		local m = model:FindFirstChild("VehicleConfig")
		local ok, r = pcall(function()
			return require(m)
		end)
		c = (ok and r) or false
		cfgCache[model] = c
	end
	return c or nil
end

local function layoutOf(cfg)
	local name = tostring(cfg.Layout or "")
	for _, k in ipairs(Pose.Skip) do
		if string.find(name, k) then
			return nil
		end
	end
	return Pose.Layouts[name] or Pose.Layouts.default
end

local function seatData(cfg, seat)
	local bone = string.gsub(seat.Name == "DriverSeat" and "" or seat.Name, "^Seat_", "")
	for _, s in ipairs(cfg.Seats or {}) do
		if (seat.Name == "DriverSeat" and s.Driver) or s.Bone == bone then
			return s
		end
	end
	return nil
end

-- Point de hanche visé : l'os du siège (mètres, repère du véhicule). GTA y pose le bassin du personnage.
function Pose.HipPoint(model, seat)
	local cfg = config(model)
	local s = cfg and seatData(cfg, seat)
	if not s or not s.Position then
		return nil
	end
	return Vector3.new(s.Position[1], s.Position[2], s.Position[3])
end

function Pose.Active(model, seat)
	if model:GetAttribute("DrivingPose") == false then
		return false
	end
	local cfg = config(model)
	return cfg ~= nil and layoutOf(cfg) ~= nil and Pose.HipPoint(model, seat) ~= nil
end

-- Volant : centre, rayon de jante et prises (repère du pivot au repos, pour suivre sa rotation)
local function wheelInfo(model, cfg)
	local w = wheelCache[model]
	if w ~= nil then
		return w or nil
	end
	w = false
	local sw = cfg.SteeringWheel
	-- l'articulation (Motor6D) du volant : un dossier du rendu porte le même nom, on cherche la bonne classe
	local joint
	for _, d in ipairs(sw and model:GetDescendants() or {}) do
		if d:IsA("Motor6D") and d.Name == sw.Bone then
			joint = d
			break
		end
	end
	if joint and joint.Part0 and joint.Part1 then
		local root = model.PrimaryPart
		local spm = cfg.StudsPerMeter or 3.571
		local restCf = joint.Part0.CFrame * joint.C0
		local center = restCf.Position
		local axis = root.CFrame:VectorToWorldSpace(Vector3.new(sw.Axis[1], sw.Axis[2], sw.Axis[3])).Unit
		-- rayon : la plus grande distance au centre, dans le plan de la jante, des coins des pièces portées
		local r = 0
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("WeldConstraint") and (d.Part0 == joint.Part1 or d.Part1 == joint.Part1) then
				local p = (d.Part0 == joint.Part1) and d.Part1 or d.Part0
				if p and p.Transparency < 1 then
					local h = p.Size / 2
					for _, sx in ipairs({ -1, 1 }) do
						for _, sy in ipairs({ -1, 1 }) do
							for _, sz in ipairs({ -1, 1 }) do
								local q = p.CFrame:PointToWorldSpace(Vector3.new(sx * h.X, sy * h.Y, sz * h.Z)) - center
								r = math.max(r, (q - axis * q:Dot(axis)).Magnitude)
							end
						end
					end
				end
			end
		end
		if r < 0.1 * spm or r > 0.4 * spm then
			r = 0.18 * spm
		end
		local right = root.CFrame.RightVector
		right = (right - axis * right:Dot(axis)).Unit
		local up = axis:Cross(right).Unit
		if up:Dot(root.CFrame.UpVector) < 0 then
			up = -up
		end
		local a = math.rad(Pose.GripAngle)
		local rg = r * Pose.GripRadius
		local function grip(side)
			return restCf:PointToObjectSpace(center + right * (side * rg * math.cos(a)) + up * (rg * math.sin(a)))
		end
		w = { joint = joint, left = grip(-1), right = grip(1) }
	end
	wheelCache[model] = w
	return w or nil
end

-- Plancher et tablier devant un siège (mètres, repère du véhicule), lus dans la grille d'habitacle
local function footInfo(model, seat, hip)
	local key = seat
	local f = footCache[key]
	if f then
		return f
	end
	local g = Fit.Grid(model)
	local floorY, wallZ, clearZ = hip.Y - 0.3, hip.Z - 1.1, hip.Z - 0.35
	if g then
		-- plancher : premier « interdit » en descendant, 55 cm devant la hanche
		local z = hip.Z - 0.55
		for y = hip.Y, hip.Y - 0.8, -0.02 do
			if Fit.IsBad(g, Vector3.new(hip.X, y, z)) then
				floorY = y + 0.02
				break
			end
		end
		-- tablier : premier « interdit » en avançant, 10 cm au-dessus du plancher, à partir de l'endroit où le
		-- plancher a été lu (plus près, on tombait sur l'avant du coussin : pieds rentrés sous le siège)
		for zz = hip.Z - 0.55, hip.Z - 1.6, -0.02 do
			if Fit.IsBad(g, Vector3.new(hip.X, floorY + 0.1, zz)) then
				wallZ = zz + 0.02
				break
			end
		end
		-- avant du coussin : première tranche libre de haut en bas (12 cm sous la hanche jusqu'au plancher)
		for zz = hip.Z - 0.15, hip.Z - 0.7, -0.02 do
			local free = true
			for y = hip.Y - 0.12, floorY + 0.04, -0.03 do
				if Fit.IsBad(g, Vector3.new(hip.X, y, zz)) then
					free = false
					break
				end
			end
			if free then
				clearZ = zz - 0.03
				break
			end
		end
	end
	f = { floorY = floorY, wallZ = wallZ, clearZ = clearZ }
	footCache[key] = f
	return f
end

-- ------------------------------------------------------------------ cinématique inverse (R15)
local function frameFrom(a, b)
	-- base orthonormée (a, b orthogonalisé, a × b)
	local bb = (b - a * b:Dot(a))
	if bb.Magnitude < 1e-4 then
		bb = (math.abs(a.X) < 0.9) and Vector3.xAxis or Vector3.yAxis
		bb = (bb - a * bb:Dot(a))
	end
	bb = bb.Unit
	return CFrame.fromMatrix(Vector3.zero, a, bb, a:Cross(bb))
end

-- Pose d'un segment dont l'articulation proche est en j1 et la lointaine en j2 (repère de la pièce) :
-- j1 sur `from`, l'axe j1→j2 sur `dir`, l'axe X de la pièce (charnière) vers `hinge`.
local function segment(j1, j2, from, dir, hinge)
	local a = (j2 - j1).Unit
	local rest = frameFrom(a, Vector3.xAxis)
	local world = frameFrom(dir, hinge)
	local R = world * rest:Inverse()
	return CFrame.new(from) * R * CFrame.new(-j1)
end

-- Deux segments de longueurs l1, l2 depuis A vers T, articulation du milieu vers `pole`
local function solve2(A, T, l1, l2, pole)
	local d = T - A
	local dist = math.clamp(d.Magnitude, math.abs(l1 - l2) + 1e-3, l1 + l2 - 1e-3)
	local dir = d.Magnitude > 1e-4 and d.Unit or -Vector3.yAxis
	local cosA = math.clamp((l1 * l1 + dist * dist - l2 * l2) / (2 * l1 * dist), -1, 1)
	local pp = pole - dir * pole:Dot(dir)
	pp = pp.Magnitude > 1e-4 and pp.Unit or Vector3.yAxis
	local M = A + dir * (l1 * cosA) + pp * (l1 * math.sqrt(1 - cosA * cosA))
	local E = A + dir * dist
	return M, E
end

local function setT(j, partCf0, childCf)
	-- Part1 = Part0 * C0 * T * C1⁻¹  ⇒  T = (Part0 * C0)⁻¹ * Part1 * C1
	j.Transform = (partCf0 * j.C0):Inverse() * childCf * j.C1
end

-- Articulation d'un avatar : Motor6D (rig classique) ou AnimationConstraint (articulations « mises à jour » de
-- Roblox, constatées sur un avatar R15 le 2026-11-12 : sans elles, aucune posture ne s'appliquait). Les deux ont
-- Transform ; l'AnimationConstraint relie Attachment0 (côté parent) et Attachment1 (côté enfant), qui jouent le
-- rôle de C0 / C1 : Attachment1.WorldCFrame = Attachment0.WorldCFrame * Transform.
local function wrapJoint(j)
	if not j then
		return nil
	end
	if j:IsA("Motor6D") then
		return j
	end
	if not j:IsA("AnimationConstraint") then
		return nil
	end
	return setmetatable({}, {
		__index = function(_, k)
			local a0, a1 = j.Attachment0, j.Attachment1
			if k == "C0" then
				return a0 and a0.CFrame or CFrame.identity
			elseif k == "C1" then
				return a1 and a1.CFrame or CFrame.identity
			elseif k == "Part0" then
				return a0 and a0.Parent
			elseif k == "Part1" then
				return a1 and a1.Parent
			end
			return j[k]
		end,
		__newindex = function(_, k, v)
			j[k] = v
		end,
	})
end

local rigCache = setmetatable({}, { __mode = "k" })
local function rigOf(char)
	local r = rigCache[char]
	if r and r.ok and r.root.Parent then
		return r
	end
	local function m(part, name)
		local p = char:FindFirstChild(part)
		return wrapJoint(p and p:FindFirstChild(name))
	end
	r = {
		root = m("LowerTorso", "Root"),
		waist = m("UpperTorso", "Waist"),
		neck = m("Head", "Neck"),
		limbs = {
			{ side = 1, arm = true, a = m("RightUpperArm", "RightShoulder"), b = m("RightLowerArm", "RightElbow"), c = m("RightHand", "RightWrist") },
			{ side = -1, arm = true, a = m("LeftUpperArm", "LeftShoulder"), b = m("LeftLowerArm", "LeftElbow"), c = m("LeftHand", "LeftWrist") },
			{ side = 1, arm = false, a = m("RightUpperLeg", "RightHip"), b = m("RightLowerLeg", "RightKnee"), c = m("RightFoot", "RightAnkle") },
			{ side = -1, arm = false, a = m("LeftUpperLeg", "LeftHip"), b = m("LeftLowerLeg", "LeftKnee"), c = m("LeftFoot", "LeftAnkle") },
		},
	}
	r.ok = r.root ~= nil and r.waist ~= nil
	for _, l in ipairs(r.limbs) do
		r.ok = r.ok and l.a ~= nil and l.b ~= nil and l.c ~= nil
	end
	if not r.ok then
		-- R6
		local torso = char:FindFirstChild("Torso")
		local hrp = char:FindFirstChild("HumanoidRootPart")
		r.r6 = {
			root = wrapJoint(hrp and hrp:FindFirstChild("RootJoint")),
			rh = wrapJoint(torso and torso:FindFirstChild("Right Hip")),
			lh = wrapJoint(torso and torso:FindFirstChild("Left Hip")),
			rs = wrapJoint(torso and torso:FindFirstChild("Right Shoulder")),
			ls = wrapJoint(torso and torso:FindFirstChild("Left Shoulder")),
		}
	end
	rigCache[char] = r
	return r
end

local function poseR15(rig, hrp, model, cfg, seat, lay)
	local root = model.PrimaryPart
	local spm = cfg.StudsPerMeter or 3.571
	local VF = root.CFrame
	local hipLocal = Pose.HipPoint(model, seat)
	local hipW = VF:PointToWorldSpace(hipLocal * spm)
	local up, fwd, right = VF.UpVector, VF.LookVector, VF.RightVector

	-- bassin : centre des hanches sur l'os du siège, incliné vers l'arrière
	local rh, lh = rig.limbs[3].a, rig.limbs[4].a
	local mid = (rh.C0.Position + lh.C0.Position) / 2
	local rot = VF.Rotation * CFrame.Angles(math.rad(lay.recline), 0, 0)
	local LT = CFrame.new(hipW) * rot * CFrame.new(-mid)
	setT(rig.root, hrp.CFrame, LT)
	local UT = LT * rig.waist.C0 * rig.waist.C1:Inverse()
	rig.waist.Transform = CFrame.identity
	if rig.neck then
		rig.neck.Transform = CFrame.Angles(-math.rad(lay.recline) * 0.8, 0, 0) -- regard droit devant
	end

	local wheel = seat.Name == "DriverSeat" and wheelInfo(model, cfg) or nil
	local wheelCf
	if wheel then
		-- les mains suivent la rotation du volant jusqu'à ±HandTurnMax ; au-delà (volant à 270 ° de butée), elles
		-- resteraient croisées : elles s'arrêtent, comme un conducteur qui change de prise
		local ax, ang = wheel.joint.Transform:ToAxisAngle()
		local lim = math.rad(Pose.HandTurnMax)
		wheelCf = wheel.joint.Part0.CFrame * wheel.joint.C0 * CFrame.fromAxisAngle(ax, math.clamp(ang, -lim, lim))
	end
	local feet = footInfo(model, seat, hipLocal)
	local thighMid = {}

	-- jambes d'abord (les mains des passagers se posent sur les cuisses)
	for i = 3, 4 do
		local l = rig.limbs[i]
		local A = (LT * l.a.C0).Position
		local j1, j2 = l.a.C1.Position, l.b.C0.Position
		local k1, k2 = l.b.C1.Position, l.c.C0.Position
		local l1, l2 = (j2 - j1).Magnitude, (k2 - k1).Magnitude
		-- cheville : sur le plancher, en avant, à la hauteur de la cheville au-dessus de la semelle
		local foot = l.c.Part1
		local ankleH = (foot and (foot.Size.Y * 0.5 + l.c.C1.Position.Y) or 0.2) / spm
		local hipL = VF:PointToObjectSpace(A) / spm
		local dy = (feet.floorY + ankleH + 0.02) - hipL.Y
		local reach = lay.legReach * (l1 + l2) / spm
		local footLen = (foot and foot.Size.Z or 0.8) / spm
		-- pied posé sur le plancher, devant le coussin et derrière le tablier ; une jambe trop courte pour
		-- atteindre le plancher devant le coussin laisse le pied pendre devant lui (jamais dans le coussin)
		local minH = math.max(hipL.Z - feet.clearZ, 0.05)
		local maxH = math.max(hipL.Z - (feet.wallZ + footLen * 0.8), minH)
		local horiz = math.clamp(math.sqrt(math.max(reach * reach - dy * dy, 0)), minH, maxH)
		if horiz * horiz + dy * dy > reach * reach then
			dy = -math.sqrt(math.max(reach * reach - horiz * horiz, 0))
		end
		local target = VF:PointToWorldSpace(Vector3.new(hipL.X + l.side * 0.03, hipL.Y + dy, hipL.Z - horiz) * spm)
		local K, E = solve2(A, target, l1, l2, up + fwd * 0.4)
		local shin = (E - K).Unit
		local thigh = (K - A).Unit
		-- genou : le tibia part vers l'arrière de la cuisse (+Z de la pièce) ⇒ charnière X = tibia × cuisse
		local hinge = shin:Cross(thigh)
		hinge = hinge.Magnitude > 1e-3 and hinge.Unit or right
		if hinge:Dot(right) < 0 then
			hinge = -hinge
		end
		local UL = segment(j1, j2, A, thigh, hinge)
		local LL = segment(k1, k2, K, shin, hinge)
		setT(l.a, LT, UL)
		setT(l.b, UL, LL)
		l.c.Transform = CFrame.Angles(math.rad(25), 0, 0) -- pied relevé vers la pédale
		thighMid[l.side] = (A + K) / 2
	end

	for i = 1, 2 do
		local l = rig.limbs[i]
		local A = (UT * l.a.C0).Position
		local j1, j2 = l.a.C1.Position, l.b.C0.Position
		local k1, k2 = l.b.C1.Position, l.c.C0.Position
		local l1, l2 = (j2 - j1).Magnitude, (k2 - k1).Magnitude
		local hand = l.c.C1.Position.Magnitude -- poignet → centre de la main
		local grip
		if wheelCf then
			grip = wheelCf:PointToWorldSpace(l.side > 0 and wheel.right or wheel.left)
		else
			grip = (thighMid[l.side] or (A + fwd * l1)) + up * (0.05 * spm)
		end
		local target = grip - (grip - A).Unit * hand
		local M, E = solve2(A, target, l1, l2, -up + right * (l.side * 0.7) - fwd * 0.3)
		local upper, fore = (M - A).Unit, (E - M).Unit
		-- coude : l'avant-bras part vers l'avant du bras (−Z de la pièce) ⇒ charnière X = bras × avant-bras
		local hinge = upper:Cross(fore)
		hinge = hinge.Magnitude > 1e-3 and hinge.Unit or right
		if hinge:Dot(right) < 0 then
			hinge = -hinge
		end
		local UA = segment(j1, j2, A, upper, hinge)
		local LA = segment(k1, k2, M, fore, hinge)
		setT(l.a, UT, UA)
		setT(l.b, UA, LA)
		l.c.Transform = CFrame.identity
	end
end

local function poseR6(r6, lay)
	if not (r6.root and r6.rh and r6.lh) then
		return
	end
	local rc = math.rad(lay.recline)
	r6.root.Transform = CFrame.Angles(-rc, 0, 0) -- RootJoint d'un R6 : X vers l'arrière inversé (C0 tourné)
	local leg = math.rad(90 - lay.recline + 12)
	r6.rh.Transform = CFrame.Angles(0, 0, leg)
	r6.lh.Transform = CFrame.Angles(0, 0, -leg)
	if r6.rs and r6.ls then
		local arm = math.rad(70)
		r6.rs.Transform = CFrame.Angles(0, 0, arm)
		r6.ls.Transform = CFrame.Angles(0, 0, -arm)
	end
end

-- ------------------------------------------------------------------ œil du conducteur (VehicleCamera)
-- Œil GTA de l'occupant d'un siège (studs, monde) : os du siège + PovCameraOffset (`Seats[i].PovOffset`).
function Pose.EyeWorld(model, seat)
	local cfg = config(model)
	if not cfg then
		return nil
	end
	local s = seatData(cfg, seat)
	local hip = Pose.HipPoint(model, seat)
	if not hip or not model.PrimaryPart then
		return nil
	end
	local spm = cfg.StudsPerMeter or 3.571
	local off = (s and s.PovOffset) and Vector3.new(s.PovOffset[1], s.PovOffset[2], s.PovOffset[3]) or Pose.DefaultPov
	return model.PrimaryPart.CFrame:PointToWorldSpace((hip + off) * spm)
end

-- ------------------------------------------------------------------ boucle
-- l'adaptation au siège réduit le corps autour du point de hanche quand la posture le tient. Ne comptent pas les
-- pièces que la posture pose au contact par construction : mains sur la jante, cuisses sur le coussin (le bassin
-- est sur l'os du siège), pieds sur le plancher ou pendants devant le coussin. Mesuré sur le m422 (2026-11-12) :
-- en les comptant, l'adaptation descendait jusqu'à sa borne (50 %, largeur 30 %) sans jamais y arriver : plus le
-- corps rapetisse, plus les jambes courtes pendent contre le coussin. La taille se décide donc sur le buste, la tête
-- et les bras (pavillon, console, portière) ; les jambes suivent par cinématique inverse.
Fit.PoseHip = function(model, seat)
	return Pose.Active(model, seat) and Pose.HipPoint(model, seat) or nil
end
Fit.PoseSkip = {
	LeftHand = true, RightHand = true,
	LeftUpperLeg = true, RightUpperLeg = true, LeftLowerLeg = true, RightLowerLeg = true,
	LeftFoot = true, RightFoot = true,
}

local started = false
function Pose.Start()
	if started then
		return
	end
	started = true
	Pose.Stats = { frames = 0, posed = 0, error = nil } -- diagnostic : images, occupants posés, dernière erreur
	RunService.PreSimulation:Connect(function()
		Pose.Stats.frames += 1
		for _, model in ipairs(CollectionService:GetTagged(Pose.Tag)) do
			local seats = model.PrimaryPart and model:FindFirstChild("Seats")
			if seats then
				for _, seat in ipairs(seats:GetChildren()) do
					local hum = seat:IsA("Seat") and seat.Occupant
					if hum and Pose.Active(model, seat) then
						local char = hum.Parent
						local hrp = hum.RootPart
						local cfg = config(model)
						local lay = layoutOf(cfg)
						if hrp and char then
							local rig = rigOf(char)
							local ok, err = pcall(function()
								if rig.ok then
									poseR15(rig, hrp, model, cfg, seat, lay)
								elseif rig.r6 then
									poseR6(rig.r6, lay)
								end
							end)
							if ok then
								Pose.Stats.posed += 1
							else
								Pose.Stats.error = tostring(err)
							end
							if not ok and not rig.warned then
								rig.warned = true
								warn("[VehiclePose] " .. tostring(err))
							end
						end
					end
				end
			end
		end
	end)
end

return Pose
