--!nonstrict
--[[
	TestTrack.lua — piste d'essai temporaire pour les mesures de conduite (SERVEUR, en Play).
	À créer en Play seulement (rien n'est enregistré dans la place), loin du reste de la carte :
	une plaque de 2048 × 6144 studs (≈ 573 × 1720 m, dont 400 studs derrière le départ), une marche et une côte,
	aux dimensions de la campagne FiveM du m422 (calibration/m422/README.md) pour que les deux colonnes se comparent.

		local Track = require(module)
		local t = Track.build(folder)              -- origine auto : au-delà de tout ce que contient Workspace
		Track.place(car, t.lanes.straight, player) -- pose le véhicule au départ d'une voie (cap vers -Z)
		Track.destroy()

	Voies (CFrame de départ, le véhicule regarde vers l'avant de la voie) :
		straight  x = 0      : 0-100, vitesse de pointe, freinage, virages (la plaque fait ±1024 studs)
		curb      x = -700   : marche de 0,149 m de haut et 12,2 m de long à 74 m devant le départ (les
		                       conteneurs posés dans GTA : on monte la marche, on roule dessus, on redescend)
		hill      x = +700   : côte à HillGrade (16,5 %, pente relevée dans GTA) de HillLength studs, plateau, descente
	Le véhicule qui sort de la plaque tombe : VehicleAccess le remet à sa dernière position sûre
	(attribut VoidRecoveries). Garder la piste loin des autres véhicules et décors.
]]
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Track = {}
Track.Tile = 2048
Track.Tiles = 3
Track.Behind = 400 -- studs de plaque derrière le départ (marche arrière)
-- Marche : mesurée dans GTA à +0,149 m, dessus plat sur 12,2 m, à 74 m du départ. Avant le 2026-11-12 c'était
-- une barre de 2 studs (0,56 m) de long à 500 studs : une bosse franchie par les deux essieux, pas une marche.
Track.CurbDistance = 74 * 3.571 -- studs
Track.CurbHeight = 0.149 -- m
Track.CurbLength = 12.2 -- m
Track.HillStart = 300 -- studs devant le départ
Track.HillLength = 200 -- studs
Track.HillGrade = 0.165 -- pente au point d'arrêt dans GTA (16,5 %, 9,35 °) ; 0,15 avant le 2026-11-12
Track.LaneOffset = 700
Track.StudsPerMeter = 3.571

local current = nil

local function part(parent, name, size, cf, color, class)
	local p = Instance.new(class or "Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Material = Enum.Material.Concrete
	p.Color = color
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- origine au-delà de toutes les pièces de Workspace (côté +X), au niveau y = 0
local function autoOrigin()
	local maxX, minZ, maxZ = -math.huge, math.huge, -math.huge
	for _, d in ipairs(Workspace:GetDescendants()) do
		if d:IsA("BasePart") and d ~= Workspace.Terrain then
			local p, s = d.Position, d.Size
			maxX = math.max(maxX, p.X + s.Magnitude / 2)
			minZ, maxZ = math.min(minZ, p.Z), math.max(maxZ, p.Z)
		end
	end
	if maxX == -math.huge then
		return CFrame.new(0, 0, 0)
	end
	local z = (minZ + maxZ) / 2 + Track.Tile * Track.Tiles / 2
	return CFrame.new(maxX + Track.Tile / 2 + 500, 0, z)
end

function Track.build(parent, origin)
	Track.destroy()
	origin = origin or autoOrigin()
	local folder = Instance.new("Folder")
	folder.Name = "F2R_TestTrack"
	local spm = Track.StudsPerMeter
	-- plaque : surface à y = 0 de l'origine, de z = +Behind (marche arrière) à z = Behind - Tiles × Tile
	for i = 0, Track.Tiles - 1 do
		local shade = (i % 2 == 0) and Color3.fromRGB(120, 120, 124) or Color3.fromRGB(100, 100, 106)
		part(folder, "Pad" .. (i + 1), Vector3.new(Track.Tile, 4, Track.Tile),
			origin * CFrame.new(0, -2, Track.Behind - Track.Tile / 2 - i * Track.Tile), shade)
	end
	-- repères tous les 100 m le long de la voie droite (visuels, sans collision)
	for d = 0, Track.Tile * Track.Tiles - 200, 100 * spm do
		local m = part(folder, "Marker", Vector3.new(1, 3, 1), origin * CFrame.new(-12, 1.5, -d), Color3.fromRGB(240, 240, 240))
		m.CanCollide, m.CanQuery, m.CanTouch = false, false, false -- repère visuel seulement
	end
	-- marche (voie curb) : plateau de CurbLength m à CurbHeight m, arête franche des deux côtés
	local ch = Track.CurbHeight * spm
	local cl = Track.CurbLength * spm
	part(folder, "Curb", Vector3.new(40, ch, cl),
		origin * CFrame.new(-Track.LaneOffset, ch / 2, -Track.CurbDistance - cl / 2), Color3.fromRGB(200, 200, 200))
	-- côte (voie hill) : montée, plateau, descente
	local rise = Track.HillLength * Track.HillGrade
	local z0 = -Track.HillStart
	local x = Track.LaneOffset
	part(folder, "HillUp", Vector3.new(40, rise, Track.HillLength),
		origin * CFrame.new(x, rise / 2, z0 - Track.HillLength / 2) * CFrame.Angles(0, math.pi, 0),
		Color3.fromRGB(150, 130, 110), "WedgePart")
	part(folder, "HillTop", Vector3.new(40, rise, 200),
		origin * CFrame.new(x, rise / 2, z0 - Track.HillLength - 100), Color3.fromRGB(150, 130, 110))
	part(folder, "HillDown", Vector3.new(40, rise, Track.HillLength),
		origin * CFrame.new(x, rise / 2, z0 - Track.HillLength - 200 - Track.HillLength / 2),
		Color3.fromRGB(150, 130, 110), "WedgePart")
	folder.Parent = parent or Workspace
	current = {
		folder = folder,
		origin = origin,
		lanes = {
			straight = origin,
			curb = origin * CFrame.new(-Track.LaneOffset, 0, 0),
			hill = origin * CFrame.new(Track.LaneOffset, 0, 0),
		},
		curbAt = origin * CFrame.new(-Track.LaneOffset, 0, -Track.CurbDistance),
		hillGrade = Track.HillGrade,
	}
	return current
end

function Track.get()
	return current
end

-- Pose le véhicule à `cf` (position et cap), roues au sol ; VehicleAccess.Teleport rend la physique
-- au conducteur éventuel. Avec `player`, le client reçoit d'abord la zone (StreamingEnabled).
function Track.place(car, cf, player)
	local Access = require(ReplicatedStorage:WaitForChild("FiveMVehicles"):WaitForChild("VehicleAccess"))
	if player and Workspace.StreamingEnabled then
		pcall(function()
			player:RequestStreamAroundAsync(cf.Position, 5)
		end)
	end
	Access.PlaceOnGround(car, cf.Position, cf.LookVector)
	return car:GetPivot()
end

function Track.destroy()
	if current and current.folder then
		current.folder:Destroy()
	end
	current = nil
end

return Track
