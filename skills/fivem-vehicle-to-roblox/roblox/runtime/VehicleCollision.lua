--!nonstrict
--[[
	VehicleCollision — passages de roues dans la hitbox (Edit ou serveur ; idempotent).

		local Collision = require(ReplicatedStorage.FiveMVehicles.VehicleCollision)
		Collision.CarveWheelWells(model)   -- creuse le volume balayé par chaque roue dans les pièces col__*

	Appelé par le Setup ; relançable sur un véhicule déjà installé (il ne recreuse pas : attribut
	`WheelWellsCarved` = Collision.Version).

	POURQUOI (m422, 2026-11-12, mesuré en Studio) : la collision officielle GTA (`col__chassis__1`) est une
	coque presque convexe dont le fond est plat sous toute la voiture, passages de roues compris : au droit des
	roues arrière elle descendait à −34 cm sous VehicleRoot, la carrosserie visible à 0 / −2 cm. Dans GTA les
	roues ont leur propre physique ; ici la suspension est faite de rayons et les cylindres de roues ne
	collisionnent pas pendant la conduite, si bien qu'une roue qui montait sur une rampe ou un rondin faisait
	toucher l'obstacle À LA COQUE, dans le passage de roue : voiture posée « sur rien », roue en l'air, ou
	bloquée devant un rondin sans contact visible.

	Le volume retiré par roue est celui qu'elle balaie : un « stade » d'axe X (deux cylindres, détente maximale
	et compression maximale, reliés par une boîte), de rayon égal à la plus grande demi-longueur de la roue
	braquée au maximum (roues directrices) plus une marge, et qui s'étend vers l'intérieur jusqu'à la face
	intérieure de la roue braquée. Vers l'extérieur il traverse la coque (l'ouverture de l'aile).
	La soustraction est celle de Roblox (GeometryService:SubtractAsync) ; la pièce creusée remplace l'ancienne
	(mêmes nom, réglages, attributs, groupe de collision et soudure). Seules les pièces dont la boîte englobante
	recoupe un volume de roue sont traitées (les vitres GTA, maillages non fermés, refusent la soustraction).
]]
local GeometryService = game:GetService("GeometryService")

local Collision = {}
Collision.Version = 1
Collision.Margin = 0.03 -- m autour du volume balayé
Collision.OuterReach = 0.6 -- m au-delà de la face extérieure de la roue (traverse l'aile)

local function steerLock(cfg)
	local h = cfg.Handling or {}
	return h.SteeringLockRad or math.rad(h.SteeringLockDeg or 35)
end

-- Volumes à retirer, en pièces temporaires (monde). Renvoie la liste et un dossier à détruire.
function Collision.WheelCutters(model, cfg)
	local root = model.PrimaryPart
	local spm = cfg.StudsPerMeter or 3.571
	local h = cfg.Handling or {}
	local upper = (h.SuspensionUpperLimit or 0.1) + (h.SuspensionRaise or 0)
	local lower = h.SuspensionLowerLimit or -0.15
	local folder = Instance.new("Folder")
	folder.Name = "F2R_WheelCutters"
	folder.Parent = workspace
	local cutters = {}
	local lock = steerLock(cfg)
	local function part(shape, size, cf)
		local p = Instance.new("Part")
		p.Shape = shape
		p.Anchored = true
		p.CanCollide = false
		p.Size = size * spm
		p.CFrame = root.CFrame * cf
		p.Parent = folder
		table.insert(cutters, p)
		return p
	end
	for bone, w in pairs(cfg.Wheels or {}) do
		local pos = Vector3.new(w.Position[1], w.Position[2], w.Position[3])
		local r, hw = w.Radius, w.Width / 2
		local steers = w.Steer == true
		local th = steers and lock or 0
		-- demi-longueur (z) et retrait vers l'intérieur (x) de la roue braquée au maximum
		local zHalf = steers and math.sqrt(r * r + hw * hw) or r
		local inward = hw * math.cos(th) + r * math.sin(th)
		local m = Collision.Margin
		local side = pos.X < 0 and -1 or 1
		local xIn = math.abs(pos.X) - inward - m
		local xOut = math.abs(pos.X) + hw + Collision.OuterReach
		local cx = side * (xIn + xOut) / 2 * spm
		local len = xOut - xIn
		local R = zHalf + m
		local yTop, yBot = pos.Y + upper, pos.Y + lower
		-- cylindres d'axe X (Part.Cylinder : axe = X local)
		part(Enum.PartType.Cylinder, Vector3.new(len, 2 * R, 2 * R), CFrame.new(cx, yTop * spm, pos.Z * spm))
		part(Enum.PartType.Cylinder, Vector3.new(len, 2 * R, 2 * R), CFrame.new(cx, yBot * spm, pos.Z * spm))
		part(Enum.PartType.Block, Vector3.new(len, yTop - yBot, 2 * R), CFrame.new(cx, (yTop + yBot) / 2 * spm, pos.Z * spm))
	end
	return cutters, folder
end

-- boîtes englobantes monde (8 coins) qui se recouvrent
local function aabb(p)
	local h = p.Size / 2
	local lo, hi = Vector3.one * math.huge, -Vector3.one * math.huge
	for _, sx in ipairs({ -1, 1 }) do
		for _, sy in ipairs({ -1, 1 }) do
			for _, sz in ipairs({ -1, 1 }) do
				local q = p.CFrame:PointToWorldSpace(Vector3.new(sx * h.X, sy * h.Y, sz * h.Z))
				lo, hi = lo:Min(q), hi:Max(q)
			end
		end
	end
	return lo, hi
end
local function intersects(a, b)
	local alo, ahi = aabb(a)
	local blo, bhi = aabb(b)
	return alo.X <= bhi.X and blo.X <= ahi.X and alo.Y <= bhi.Y and blo.Y <= ahi.Y and alo.Z <= bhi.Z and blo.Z <= ahi.Z
end

-- La géométrie creusée remplace la pièce : nouvelle pièce au même endroit, mêmes nom, réglages, attributs,
-- groupe de collision et soudure (un MeshPart n'a pas SubstituteGeometry, et changer le CFrame d'une
-- pièce soudée en Edit déplacerait tout le véhicule).
local function replacePart(old, new)
	new.Name = old.Name
	new.Anchored = old.Anchored
	new.Transparency = old.Transparency
	new.CastShadow = old.CastShadow
	new.CanCollide, new.CanQuery, new.CanTouch = old.CanCollide, old.CanQuery, old.CanTouch
	new.Massless = old.Massless
	new.CollisionGroup = old.CollisionGroup
	new.CustomPhysicalProperties = old.CustomPhysicalProperties
	for k, v in pairs(old:GetAttributes()) do
		new:SetAttribute(k, v)
	end
	local weldTo
	for _, j in ipairs(old:GetChildren()) do
		if j:IsA("WeldConstraint") then
			weldTo = (j.Part0 == old) and j.Part1 or j.Part0
		end
	end
	new.Parent = old.Parent
	if weldTo then
		local w = Instance.new("WeldConstraint")
		w.Part0, w.Part1, w.Parent = weldTo, new, new
	end
	old:Destroy()
end

function Collision.CarveWheelWells(model)
	if model:GetAttribute("WheelWellsCarved") == Collision.Version then
		return { skipped = true }
	end
	local cfgModule = model:FindFirstChild("VehicleConfig")
	assert(model.PrimaryPart and cfgModule, "VehicleCollision : PrimaryPart ou VehicleConfig manquant")
	local cfg = require(cfgModule:Clone())
	local collF = model:FindFirstChild("Collision")
	if not collF or not cfg.Wheels then
		return { carved = 0 }
	end
	local cutters, folder = Collision.WheelCutters(model, cfg)
	local carved, failed = {}, {}
	for _, p in ipairs(collF:GetDescendants()) do
		if p:IsA("MeshPart") and p:GetAttribute("Kind") == "collision" then
			local hit = {}
			for _, c in ipairs(cutters) do
				if intersects(p, c) then
					table.insert(hit, c)
				end
			end
			if #hit > 0 then
				local ok, res = pcall(function()
					return GeometryService:SubtractAsync(p, hit, {
						CollisionFidelity = p.CollisionFidelity,
						RenderFidelity = Enum.RenderFidelity.Automatic,
						SplitApart = false,
					})
				end)
				if ok and res and res[1] then
					local name = p.Name
					for i = 2, #res do
						res[i]:Destroy()
					end
					local ok2, err2 = pcall(replacePart, p, res[1])
					if ok2 then
						table.insert(carved, name)
					else
						res[1]:Destroy()
						table.insert(failed, name .. " : " .. tostring(err2))
					end
				else
					table.insert(failed, p.Name .. " : " .. tostring(res))
				end
			end
		end
	end
	folder:Destroy()
	if #failed == 0 then
		model:SetAttribute("WheelWellsCarved", Collision.Version)
	end
	table.sort(carved)
	return { carved = #carved, parts = carved, failed = failed }
end

return Collision
