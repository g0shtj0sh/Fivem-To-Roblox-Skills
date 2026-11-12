--!nonstrict
--[[
	VehicleLights — équipement lumineux d'un véhicule converti (Edit ou serveur ; idempotent).

		local Lights = require(ReplicatedStorage.FiveMVehicles.VehicleLights)
		Lights.Rig(model)   -- (re)construit les lumières, la lampe de plaque, l'état « éteint » des optiques

	Appelé par le Setup ; peut être relancé sur un véhicule déjà installé (il remplace ce qu'il a posé et
	les anciennes lumières `Light_<rôle>`, jamais celles des gyrophares ni des néons de bas de caisse).

	Ce qui imite GTA V, et pourquoi (comparaison faite en Studio sur le m422, 2026-11-12) :
	- Les optiques sont les maillages du shader `vehicle_lightsemissive`, une pièce par feu. GTA les
	  affiche texturées éteintes et les fait briller ×3 allumées. Dans Roblox, un `MeshPart` Neon qui garde
	  son `TextureID` reste presque éteint : la texture sombre (lightmodules, ext_lights) multiplie la
	  lueur. CAUSE DÉMONTRÉE : TextureID retiré → la signature lumineuse s'allume. On garde donc la
	  texture dans l'attribut `OffTexture` et le runtime la retire à l'allumage (VehicleRuntime.setPart).
	- Les lumières n'éclairent que DEVANT leur optique : des `SpotLight` posés juste hors de l'optique,
	  orientés vers l'extérieur. Les anciennes `PointLight` sans ombre, posées au centre de l'optique,
	  éclairaient à travers la carrosserie (habitacle rouge, flaque rouge sur le côté avant) ; le 3ᵉ feu
	  stop était dans l'habitacle. Un cône tourné vers l'extérieur ne peut pas éclairer sa propre voiture.
	- Les phares portent des ombres (`Shadows`), mais seulement pour la voiture du joueur local (le runtime
	  les active) : ailleurs le coût n'en vaut pas la peine. Posés au centre de l'optique, ils étaient
	  masqués par le boîtier du phare : aucun faisceau au sol.
	- La plaque arrière est éclairée par une lampe dirigée vers le bas ; les textes de plaque suivent
	  l'éclairage (`LightInfluence` 1) au lieu d'être pleinement lumineux jour et nuit.
]]
local Lights = {}

-- Réglages par famille de feu. Portées en studs, angles en degrés, couleurs dans le runtime.
-- `out` : marge hors de l'optique (m). Valeurs de départ, ajustées à l'œil sur le m422 de nuit.
Lights.Spec = {
	headlight = { class = "SpotLight", dir = "front", angle = 60, range = 60, out = 0.06 },
	taillight = { class = "SpotLight", dir = "back", angle = 120, range = 5, out = 0.05 },
	brakelight = { class = "SpotLight", dir = "back", angle = 120, range = 7, out = 0.05 },
	reversinglight = { class = "SpotLight", dir = "back", angle = 100, range = 14, out = 0.05 },
	indicator = { class = "SpotLight", dir = "auto", angle = 120, range = 5, out = 0.05 },
	extralight = { class = "PointLight", range = 10, out = 0 },
	plate = { class = "SpotLight", angle = 150, range = 2.5 },
}
Lights.Tag = "Lamp_" -- nom des attachments posés par Rig

local FACE = {
	front = Enum.NormalId.Front,
	back = Enum.NormalId.Back,
	left = Enum.NormalId.Left,
	right = Enum.NormalId.Right,
	down = Enum.NormalId.Bottom,
}
local DIR = {
	front = Vector3.new(0, 0, -1),
	back = Vector3.new(0, 0, 1),
	left = Vector3.new(-1, 0, 0),
	right = Vector3.new(1, 0, 0),
}

local function family(role)
	return string.match(role, "^(%a+)") or role
end

-- boîte englobante (repère du véhicule, studs) d'un ensemble de pièces
local function boundsOf(vf, parts)
	local lo, hi = Vector3.one * math.huge, -Vector3.one * math.huge
	for _, p in ipairs(parts) do
		local h = p.Size / 2
		for _, sx in ipairs({ -1, 1 }) do
			for _, sy in ipairs({ -1, 1 }) do
				for _, sz in ipairs({ -1, 1 }) do
					local q = vf:PointToObjectSpace(p.CFrame:PointToWorldSpace(Vector3.new(sx * h.X, sy * h.Y, sz * h.Z)))
					lo, hi = lo:Min(q), hi:Max(q)
				end
			end
		end
	end
	return lo, hi
end

-- Sens d'éclairage d'un clignotant : avant ou arrière s'il est dans un quart de la longueur, sinon de côté
-- (répétiteur de rétroviseur ou d'aile).
local function indicatorDir(role, center, lenStuds)
	local z = center.Z
	if z < -lenStuds * 0.25 then
		return "front"
	elseif z > lenStuds * 0.25 then
		return "back"
	end
	return (string.sub(role, -2, -2) == "l") and "left" or "right"
end

function Lights.Rig(model)
	local root = model.PrimaryPart
	local cfgModule = model:FindFirstChild("VehicleConfig")
	assert(root and cfgModule, "VehicleLights.Rig : PrimaryPart ou VehicleConfig manquant")
	local cfg = require(cfgModule:Clone())
	local spm = cfg.StudsPerMeter or 3.571
	local vf = root.CFrame -- VehicleRoot est posé au repère du véhicule par le Setup
	local b = cfg.Bounds or { Min = { -1, -0.5, -2.3 }, Max = { 1, 1, 2.3 } }
	local lenStuds = (b.Max[3] - b.Min[3]) * spm

	-- 1. nettoyage : anciennes lumières de rôle (sauf gyrophares) et celles d'un Rig précédent
	local byRole = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Attachment") and d:GetAttribute("LightRole") then
			local role = d:GetAttribute("LightRole")
			local old = string.sub(d.Name, 1, 6) == "Light_" and not string.find(role, "^siren")
			if old or string.sub(d.Name, 1, #Lights.Tag) == Lights.Tag then
				d:Destroy()
			end
		elseif d:IsA("BasePart") and d:GetAttribute("LightRole") then
			local role = d:GetAttribute("LightRole")
			byRole[role] = byRole[role] or {}
			table.insert(byRole[role], d)
			-- état éteint : la texture GTA de l'optique, retirée par le runtime à l'allumage
			if d:IsA("MeshPart") and d:GetAttribute("OffTexture") == nil then
				d:SetAttribute("OffTexture", d.TextureID)
			end
		end
	end

	-- 2. une lumière par rôle, juste hors de l'optique, tournée vers l'extérieur
	local roles = {}
	for role in pairs(cfg.Lights or {}) do
		roles[role] = true
	end
	for role in pairs(byRole) do
		roles[role] = true
	end
	local made = {}
	for role in pairs(roles) do
		local spec = Lights.Spec[family(role)]
		if spec and role ~= "always_on" then
			local parts = byRole[role]
			local lo, hi
			if parts then
				lo, hi = boundsOf(vf, parts)
			else
				local p = cfg.Lights[role]
				local c = Vector3.new(p[1], p[2], p[3]) * spm
				lo, hi = c, c
			end
			local c = (lo + hi) / 2
			local dir = spec.dir == "auto" and indicatorDir(role, c, lenStuds) or spec.dir
			local pos = c
			if dir and DIR[dir] then
				local d = DIR[dir]
				-- extrême de l'optique dans ce sens, plus la marge
				local ext = Vector3.new(
					d.X > 0 and hi.X or (d.X < 0 and lo.X or c.X),
					c.Y,
					d.Z > 0 and hi.Z or (d.Z < 0 and lo.Z or c.Z)
				)
				pos = ext + d * (spec.out * spm)
			end
			local holder = parts and parts[1] or root
			local a = Instance.new("Attachment")
			a.Name = Lights.Tag .. role
			a:SetAttribute("LightRole", role)
			a.Parent = holder
			a.WorldCFrame = vf * CFrame.new(pos) -- axes du véhicule : Front = avant (−Z)
			local l = Instance.new(spec.class)
			l.Range = spec.range
			if l:IsA("SpotLight") then
				l.Angle = spec.angle
				l.Face = FACE[dir] or Enum.NormalId.Front
			end
			l.Shadows = false
			l.Enabled = false
			l.Parent = a
			table.insert(made, role)
		end
	end

	-- 3. plaques : textes soumis à l'éclairage ; lampe au-dessus de la plaque arrière
	local plates = 0
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("SurfaceGui") and d.Name == "Plate" and d.Parent and d.Parent:IsA("BasePart") then
			local p = d.Parent
			d.LightInfluence = 1
			local n = p.CFrame:VectorToWorldSpace(Vector3.FromNormalId(d.Face))
			if n:Dot(vf.LookVector) < -0.5 then -- plaque tournée vers l'arrière
				local up = vf.UpVector
				-- demi-hauteur de la plaque le long du haut du véhicule
				local h = 0
				for _, ax in ipairs({ p.CFrame.RightVector * p.Size.X, p.CFrame.UpVector * p.Size.Y, p.CFrame.LookVector * p.Size.Z }) do
					h += math.abs(ax:Dot(up)) / 2
				end
				local a = Instance.new("Attachment")
				a.Name = Lights.Tag .. "plate"
				a:SetAttribute("LightRole", "plate")
				a.Parent = p
				local pos = p.Position + up * (h + 0.03 * spm) + n * (0.06 * spm)
				a.WorldCFrame = vf.Rotation + pos
				local l = Instance.new("SpotLight")
				l.Face = Enum.NormalId.Bottom
				l.Angle = Lights.Spec.plate.angle
				l.Range = Lights.Spec.plate.range
				l.Shadows = false
				l.Enabled = false
				l.Parent = a
				plates += 1
			end
		end
	end
	model:SetAttribute("LightsRig", 1)
	table.sort(made)
	return { lights = made, plateLamps = plates }
end

return Lights
