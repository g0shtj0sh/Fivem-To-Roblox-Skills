--!nonstrict
-- FiveMVehicles/VehicleDamage (ModuleScript, serveur ET client)
-- Dégâts LOCALISÉS sans déformation du modèle (trop coûteuse sur Roblox) — demande de l'utilisateur, 2026-11-16.
--   Détection : le client du conducteur (VehicleDrive) mesure la variation brutale de vitesse horizontale d'un pas
--   physique (un choc ; un freinage fort ≈ 0,2 m/s par pas) et l'envoie (action « Impact » : direction, force) ;
--   le serveur fait de même pour un véhicule sans conducteur (il en tient la physique).
--   Effets, au point d'impact estimé (bord de la boîte du véhicule dans la direction du choc) :
--     · santé carrosserie et moteur (attributs BodyHealth, EngineHealth, 1000 = neuf), moteur touché d'autant plus
--       que le choc est près de lui ; multiplicateurs du handling (CollisionDamageMult, EngineDamageMult) ;
--     · feux proches cassés (LightBroken_<rôle>), vitres proches brisées (WindowBroken_<os> : éclats en particules),
--       portière / capot / coffre arrachés sur un très gros choc de leur côté (DoorRemoved_<os>) ;
--     · moteur : fumée grise (< SmokeBelow), noire (< HeavySmokeBelow), feu (< FireBelow), puis il cale et ne
--       redémarre plus (EngineDead) ; puissance réduite quand il est touché (VehicleDrive).
--   Rien ne tourne en continu : tout est calculé au moment du choc ; les effets du moteur sont des émetteurs posés
--   une fois sur chaque client. Repair remet tout à neuf. NoDamage = invincible.

local Damage = {}
-- ROBUSTESSE (2026-11-16, demande de l'utilisateur : « les véhicules bien plus robustes, le but n'est pas d'aller
-- au garage toutes les 2 min », pensé pour les courses-poursuites). Avant : MinImpact 4, BodyPerMs 26,
-- EnginePerMs 20, feux dès le seuil, vitres 7, arrachage 16 — un mur à ~90 km/h (variation mesurée 26,6 m/s)
-- ôtait ~450 points au moteur et faisait fumer dès le 1er choc. Maintenant, même mur : ~125 points au moteur,
-- fumée après 4 à 5 gros chocs de face, moteur mort après ~8 ; un accrochage à 50 km/h (~14 m/s) : ~50 points.
Damage.MinImpact = 6 -- m/s de variation de vitesse horizontale en un pas : en dessous, rien
Damage.MaxImpact = 40
Damage.BodyPerMs = 10 -- points de carrosserie par m/s au-delà du seuil
Damage.EnginePerMs = 6.5
Damage.LightMin = 9 -- m/s : un feu ne casse qu'au-delà
Damage.SmokeBelow = 450
Damage.HeavySmokeBelow = 220
Damage.FireBelow = 60
Damage.LightRadius = 0.55 -- m (+ 0,05 par m/s au-delà du seuil)
Damage.WindowRadius = 0.7 -- m (+ 0,06 par m/s) ; une vitre ne casse qu'au-delà de WindowMin
Damage.WindowMin = 13
Damage.DetachAt = 22 -- m/s (≈ 80 km/h dans un mur) : un ouvrant du côté du choc est arraché ; il TOMBE
-- (copie physique) et disparaît après VehicleCustomization.DebrisLifetime s, comme les éclats de vitre
Damage.DetachRadius = 1.0 -- m

local function cfgOf(model)
	local m = model:FindFirstChild("VehicleConfig")
	local ok, cfg = pcall(function()
		return m and require(m)
	end)
	return ok and cfg or {}
end

local function v3(t)
	return Vector3.new(t[1], t[2], t[3])
end

-- Point d'impact estimé (m, repère du véhicule) : du centre de la boîte, dans la direction du choc (horizontale),
-- jusqu'à son bord, à mi-hauteur de caisse.
function Damage.ImpactPoint(cfg, dir)
	local b = cfg.Bounds
	if not b then
		return dir * 1.5
	end
	local mn, mx = v3(b.Min), v3(b.Max)
	local c = (mn + mx) / 2
	local half = (mx - mn) / 2
	local tx = math.abs(dir.X) > 1e-3 and half.X / math.abs(dir.X) or math.huge
	local tz = math.abs(dir.Z) > 1e-3 and half.Z / math.abs(dir.Z) or math.huge
	local t = math.min(tx, tz)
	return Vector3.new(c.X + dir.X * t, c.Y + 0.15 * half.Y, c.Z + dir.Z * t)
end

local function partCenters(model, cfg, prefix)
	-- centre moyen (m, repère du véhicule) des pièces dont le nom commence par prefix
	local root = model.PrimaryPart
	local spm = cfg.StudsPerMeter or 3.571
	local sum, n = Vector3.zero, 0
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") and string.sub(p.Name, 1, #prefix) == prefix then
			sum += root.CFrame:PointToObjectSpace(p.Position) / spm
			n += 1
		end
	end
	return n > 0 and sum / n or nil
end

-- SERVEUR. dir : direction (repère du véhicule) du centre vers le point touché ; strength : m/s.
function Damage.Apply(model, dir, strength)
	if model:GetAttribute("NoDamage") == true or not model.PrimaryPart then
		return
	end
	strength = math.clamp(tonumber(strength) or 0, 0, Damage.MaxImpact)
	local over = strength - Damage.MinImpact
	if over <= 0 then
		return
	end
	dir = Vector3.new(dir.X, 0, dir.Z)
	if dir.Magnitude < 1e-3 then
		return
	end
	dir = dir.Unit
	local cfg = cfgOf(model)
	local h = cfg.Handling or {}
	local P = Damage.ImpactPoint(cfg, dir)

	local body = model:GetAttribute("BodyHealth") or 1000
	body -= over * Damage.BodyPerMs * (h.CollisionDamageMult or 1)
	model:SetAttribute("BodyHealth", math.max(0, math.floor(body)))

	local enginePos = cfg.EnginePosition and v3(cfg.EnginePosition) or Vector3.new(0, 0, -1.4)
	local near = math.clamp(1.4 - (P - enginePos).Magnitude / 1.6, 0.12, 1)
	local engine = model:GetAttribute("EngineHealth") or 1000
	engine -= over * Damage.EnginePerMs * (h.EngineDamageMult or 1) * near
	engine = math.max(-100, math.floor(engine))
	model:SetAttribute("EngineHealth", engine)
	if engine <= 0 then
		model:SetAttribute("EngineDead", true)
		model:SetAttribute("Engine", false)
	end

	-- feux au point d'impact
	local lr = Damage.LightRadius + 0.05 * over
	for role, pos in pairs(strength >= Damage.LightMin and cfg.Lights or {}) do
		if (v3(pos) - P).Magnitude < lr then
			model:SetAttribute("LightBroken_" .. role, true)
		end
	end
	-- vitres au point d'impact
	if strength >= Damage.WindowMin then
		local wr = Damage.WindowRadius + 0.06 * over
		local root, spm = model.PrimaryPart, cfg.StudsPerMeter or 3.571
		for _, p in ipairs(model:GetDescendants()) do
			local bone = p:IsA("BasePart") and p:GetAttribute("Kind") == "glass" and p:GetAttribute("Window")
			if bone and model:GetAttribute("WindowBroken_" .. bone) ~= true then
				local c = root.CFrame:PointToObjectSpace(p.Position) / spm
				-- distance horizontale au point d'impact (une vitre est plus haute que le point de choc)
				if (Vector3.new(c.X, P.Y, c.Z) - P).Magnitude < wr then
					model:SetAttribute("WindowBroken_" .. bone, true)
				end
			end
		end
	end
	-- ouvrant arraché sur un très gros choc de son côté
	if strength >= Damage.DetachAt then
		local custom = script.Parent:FindFirstChild("VehicleCustomization")
		local ok, Custom = pcall(function()
			return custom and require(custom)
		end)
		for bone in pairs(cfg.Hinges or {}) do
			local c = partCenters(model, cfg, bone .. "__")
			if c and (Vector3.new(c.X, P.Y, c.Z) - P).Magnitude < Damage.DetachRadius and model:GetAttribute("DoorRemoved_" .. bone) ~= true then
				if ok and Custom and Custom.RemoveDoor then
					pcall(Custom.RemoveDoor, model, bone, true) -- la pièce tombe au sol
				end
			end
		end
	end
	model:SetAttribute("LastImpact", string.format("%.2f,%.2f,%.1f", dir.X, dir.Z, strength))
end

function Damage.Reset(model)
	for k in pairs(model:GetAttributes()) do
		if string.sub(k, 1, 12) == "LightBroken_" then
			model:SetAttribute(k, nil)
		end
	end
	model:SetAttribute("BodyHealth", nil)
	model:SetAttribute("EngineHealth", nil)
	model:SetAttribute("EngineDead", nil)
end

-- Facteur de puissance d'un moteur touché (VehicleDrive) : 1 au-dessus de 450, 0,55 à 0
function Damage.PowerFactor(model)
	local e = model:GetAttribute("EngineHealth")
	if not e or e >= Damage.SmokeBelow then
		return 1
	end
	return 0.55 + 0.45 * math.clamp(e / Damage.SmokeBelow, 0, 1)
end

-- CLIENT : fumée et feu du moteur (un émetteur posé à la position du moteur, réglé selon EngineHealth)
Damage.SmokeTexture = "rbxasset://textures/particles/smoke_main.dds"
Damage.FireTexture = "rbxasset://textures/particles/fire_main.dds"
function Damage.UpdateFx(renderer)
	local model = renderer.Model
	local e = model:GetAttribute("EngineHealth") or 1000
	local stage = (e < Damage.FireBelow and 3) or (e < Damage.HeavySmokeBelow and 2) or (e < Damage.SmokeBelow and 1) or 0
	if (renderer.LodTier or 0) >= 2 and stage < 3 then
		stage = 0 -- au loin : la fumée légère n'est pas dessinée
	end
	if stage == renderer.DamageStage then
		return
	end
	renderer.DamageStage = stage
	local fx = renderer.DamageFx
	if not fx then
		if stage == 0 then
			return
		end
		local cfg = renderer.Config
		local pos = cfg.EnginePosition and v3(cfg.EnginePosition) or Vector3.new(0, 0.2, -1.4)
		local att = Instance.new("Attachment")
		att.Name = "F2R_EngineFx"
		att.Position = (pos + Vector3.new(0, 0.35, 0)) * renderer.Spm
		local smoke = Instance.new("ParticleEmitter")
		smoke.Texture = Damage.SmokeTexture
		smoke.Lifetime = NumberRange.new(1.6, 2.8)
		smoke.Speed = NumberRange.new(2, 5)
		smoke.SpreadAngle = Vector2.new(25, 25)
		smoke.Acceleration = Vector3.new(0, 4, 0)
		smoke.Drag = 1
		smoke.Rotation = NumberRange.new(0, 360)
		smoke.RotSpeed = NumberRange.new(-40, 40)
		smoke.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.6), NumberSequenceKeypoint.new(1, 6.5) })
		smoke.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(0.6, 0.6),
			NumberSequenceKeypoint.new(1, 1) })
		smoke.LightInfluence = 1
		smoke.ZOffset = -1
		smoke.Parent = att
		local fire = Instance.new("ParticleEmitter")
		fire.Texture = Damage.FireTexture
		-- flammes DEVANT la fumée (ZOffset), plus grosses et plus vives : la fumée noire les cachait (capture de
		-- l'utilisateur, 2026-11-16) ; la fumée s'éclaircit et ralentit quand le moteur brûle (stage 3)
		fire.Lifetime = NumberRange.new(0.45, 0.9)
		fire.Speed = NumberRange.new(4, 8)
		fire.SpreadAngle = Vector2.new(22, 22)
		fire.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2.6), NumberSequenceKeypoint.new(0.5, 1.8),
			NumberSequenceKeypoint.new(1, 0.3) })
		fire.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.05), NumberSequenceKeypoint.new(0.7, 0.3),
			NumberSequenceKeypoint.new(1, 1) })
		fire.Rotation = NumberRange.new(0, 360)
		fire.RotSpeed = NumberRange.new(-90, 90)
		fire.Brightness = 3
		fire.ZOffset = 3
		fire.LightEmission = 1
		fire.Color = ColorSequence.new(Color3.fromRGB(255, 160, 60), Color3.fromRGB(255, 60, 20))
		fire.Enabled = false
		fire.Parent = att
		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(255, 130, 50)
		light.Range = 14
		light.Brightness = 4
		light.Enabled = false
		light.Parent = att
		att.Parent = renderer.Root
		fx = { att = att, smoke = smoke, fire = fire, light = light }
		renderer.DamageFx = fx
	end
	fx.smoke.Enabled = stage >= 1
	fx.smoke.Rate = (stage >= 2 and 22) or 9
	fx.smoke.Color = ColorSequence.new(stage >= 2 and Color3.fromRGB(40, 40, 42) or Color3.fromRGB(170, 170, 172))
	-- en feu : la fumée reste derrière les flammes (ZOffset) et n'est presque plus éclairée par la lumière du feu
	fx.smoke.LightInfluence = stage >= 3 and 0.3 or 1
	fx.smoke.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(0.6, 0.6), NumberSequenceKeypoint.new(1, 1) })
	fx.fire.Enabled = stage >= 3
	fx.fire.Rate = 55
	fx.light.Enabled = stage >= 3
end

return Damage
