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
-- ROBUSTESSE (2026-11-16) puis VITESSE (2026-11-18, demande de l'utilisateur : « que ça prenne en compte la vitesse […]
-- à toute vitesse dans un mur c'est forcément beaucoup plus de dégâts qu'à 10 km/h »). Les points perdus suivent
-- l'ÉNERGIE du choc (carré de la variation de vitesse) au lieu d'une droite : K × (Δv² − MinImpact²).
-- Avant (droite) : mur à ~90 km/h (Δv 26,6 m/s) ≈ 125 points au moteur, 50 km/h ≈ 50.
-- Mesuré sur la m422 (EngineDamageMult du mod inclus), choc de face, Play Studio 2026-11-18 :
-- 20 km/h ≈ 3 · 28 km/h ≈ 22 · 50 km/h ≈ 92 · 72 km/h ≈ 200 · 95 km/h ≈ 370 · 118 km/h ≈ 570 (fumée claire)
-- · 144 km/h ≈ 850 (fumée noire d'un coup). Un 2e gros choc met le feu ; les accrochages restent légers ; un choc
-- à l'arrière (loin du moteur) touche ~7 fois moins le moteur.
Damage.MinImpact = 5 -- m/s de variation de vitesse horizontale en un pas : en dessous, rien
Damage.MaxImpact = 45
Damage.BodyK = 0.6 -- points de carrosserie par (m/s)² au-delà du seuil
Damage.EngineK = 0.4 -- points moteur par (m/s)², × proximité du moteur (0,12..1)
Damage.LightMin = 9 -- m/s : un feu ne casse qu'au-delà
Damage.SmokeBelow = 450 -- fumée CLAIRE : le moteur peut caler (on le redémarre)
Damage.HeavySmokeBelow = 220 -- fumée NOIRE : le moteur peut lâcher à tout moment, définitivement (réparation)
Damage.FireBelow = 60 -- FEU : véhicule mort, occupants brûlés
Damage.LightRadius = 0.55 -- m (+ 0,05 par m/s au-delà du seuil)
-- VITRES (2026-11-19, utilisateur : « cassées au premier coup, toutes en même temps alors que j'ai percuté
-- qu'à l'avant »). Une vitre casse quand le point de choc est assez près de son BORD le plus proche (distance 3D à
-- sa boîte, m), plus près que la portée = Reach + ReachPerMs × (force − seuil). Avant : distance À PLAT au CENTRE de
-- chaque vitre, 0,7 m + 0,06 par m/s dès 13 m/s ; un choc « par-dessous » (voiture qui retombe, fond qui tape) était
-- placé sous le centre de la caisse et, la hauteur étant ignorée, toutes les vitres étaient « à portée » (mesuré sur la
-- 325e : 6 vitres sur 6 à 14 m/s par le toit / le dessous, 0 par un choc avant pur).
-- Verre trempé (vitres latérales, lunette arrière) : casse quand il est touché de près.
Damage.WindowMin = 15 -- m/s (≈ 54 km/h perdus d'un coup)
Damage.WindowReach = 0.35 -- m
Damage.WindowReachPerMs = 0.03
-- Pare-brise feuilleté (os « windscreen ») : bien plus résistant. 325e : choc avant pur dans un mur ≥ ≈ 25 m/s
-- (≈ 90 km/h), angle avant ≥ ≈ 19 m/s.
Damage.WindscreenMin = 18
Damage.WindscreenReach = 0.9
Damage.WindscreenReachPerMs = 0.05
-- Choc de toit (tonneau, Damage.RollMin à chaque passage) : le toit s'écrase, les vitres proches du toit cassent.
-- Un choc par-dessous (réception, fond qui tape) ne casse aucune vitre.
Damage.RoofWindowReach = 0.85
Damage.RoofWindowReachPerMs = 0.03
Damage.DetachAt = 22 -- m/s (≈ 80 km/h dans un mur) : un ouvrant du côté du choc est arraché ; il TOMBE
-- (copie physique) et disparaît après VehicleCustomization.DebrisLifetime s, comme les éclats de vitre
Damage.DetachRadius = 1.0 -- m
-- ROUES (2026-11-19, demande de l'utilisateur : « plusieurs stades : crevaison, direction cassée, roue arrachée qui
-- part comme les autres pièces »). Santé par roue WheelHealth_<os> (1000), état WheelState_<os> : 1 crevé (sous
-- WheelBurstBelow), 2 cassé (sous WheelBreakBelow : la roue reste braquée de travers, VehicleDynamics.WheelSteer),
-- 3 arraché (à 0 : la roue tombe en débris, le moyeu frotte au sol sans moteur ni direction). Un état ne redescend qu'à la réparation. Chaque choc
-- retire à une roue énergie × WheelK × proximité (1 au centre de la roue, 0 à WheelReach du point d'impact).
-- Herse (Damage.Puncture) : crève un pneu intact. Pneus increvables (Tune_BulletproofTyres) : jamais crevés, mais une
-- roue peut toujours se casser ou partir sur un gros choc. Pas de crevaison par la chaleur ni par un burn (décision
-- de l'utilisateur, 2026-11-14).
Damage.WheelHealthMax = 1000
Damage.WheelBurstBelow = 650
Damage.WheelBreakBelow = 300
-- Le choc est réduit à UN point (ImpactPoint : milieu du pare-chocs, du flanc ou coin) : une roue avant est à
-- ≈ 1,15 m à l'horizontale du milieu du pare-chocs, une roue à ≈ 1,3-1,5 m du milieu du flanc (BavrenN4). Avec une
-- portée de 1,2 m, ni un choc de face ni un choc latéral n'atteignaient les roues (mesuré le 2026-11-19).
Damage.WheelK = 2.5 -- points par (m/s)² d'énergie de choc
Damage.WheelReach = 1.8 -- m, distance HORIZONTALE (repère du véhicule) entre le point de choc et le centre de roue
-- TONNEAUX (2026-11-18, utilisateur : « on fait plein de tonneaux et on ressort avec rien ») : avant, seule la
-- variation de vitesse HORIZONTALE dans le repère de la voiture comptait ; un choc sur le toit (axe Y de la voiture) ou
-- une rotation stoppée net ne faisaient rien. Damage.Measure compte maintenant aussi :
Damage.VerticalWeight = 0.85 -- la part verticale (repère voiture) du choc : toit, dessous, réception d'un saut
Damage.SpinArm = 0.9 -- m : un arrêt brutal de rotation = choc de Δω × bras de levier au coin de la caisse
Damage.SpinUpright = 0.6 -- vecteur haut (Y) sous lequel la voiture est « hors d'aplomb » et la rotation compte
Damage.RollMin = 16 -- m/s : choc de toit appliqué à CHAQUE passage sur le toit (un tonneau), au moins cette force,
-- sinon la vitesse de la voiture à cet instant. Mesuré (Play Studio, m422 projetée en tonneaux) : les chocs pris image
-- par image restaient faibles (5 à 13 m/s : l'impact s'étale sur plusieurs images) → 4 tonneaux ≈ −30 moteur seulement.
-- Part de la vitesse de la voiture comptée comme force d'un choc de toit (2026-11-19, utilisateur : « à peine un tonneau,
-- un peu vite, et la voiture prend feu direct »). À 1 (avant), un tonneau à 90 km/h valait 25 m/s, soit ≈ 216 points
-- moteur par contact du toit (325e : EngineDamageMult 1,5, proximité 0,6) : 3-4 contacts et le moteur passait sous
-- FireBelow. À 0,6 : 16 m/s (RollMin) jusqu'à ≈ 96 km/h, ≈ 80 points par contact.
Damage.RollSpeedShare = 0.6
Damage.RollEngineMin = 0.6 -- proximité minimale du moteur pour un choc de toit / dessous (une voiture qui fait
-- plusieurs tonneaux finit par fumer, même si le toit est loin du moteur)

-- PANNES (2026-11-18, demande de l'utilisateur). Tirées par le serveur (Damage.Tick, toutes les TickEvery s, moteur
-- allumé) et à chaque choc. Probabilités PAR SECONDE moteur allumé (au ralenti ×0,5) :
--   fumée claire → CALAGE (Engine = false, EngineFault = "stall") : on redémarre normalement (touche moteur) ;
--   fumée noire  → MOTEUR HS (EngineDead, EngineFault = "dead") : il ne redémarre plus jusqu'à la réparation ;
--   feu          → ÉPAVE (Wrecked, Burning) : plus rien ne marche (moteur, phares, klaxon, sirène, clignotants),
--                  les occupants prennent feu et des dégâts, qui s'approche du feu s'enflamme quelques secondes.
Damage.TickEvery = 0.5
Damage.StallPerSecond = 1 / 45 -- fumée claire : un calage toutes les ~45 s de moteur allumé (en moyenne)
Damage.DeathPerSecond = 1 / 35 -- fumée noire : le moteur lâche après ~35 s en moyenne
Damage.StallOnHit = 0.35 -- choc (≥ MinImpact) en fumée claire : chance de caler sur le coup
Damage.DeathOnHit = 0.5 -- choc en fumée noire : chance que le moteur lâche sur le coup
Damage.BurnTime = 90 -- s de flammes, puis l'épave fume noir (toujours morte)
-- Brûlures (personnages) : un Fire Roblox sur le torse, retiré après sa durée.
Damage.OccupantBurnDps = 9 -- points de vie par seconde à bord d'un véhicule en feu
Damage.OccupantAfterburn = 4 -- s : il brûle encore après être sorti (mêmes dégâts)
Damage.NearFireRadius = 1.3 -- m autour du foyer (moteur) : un piéton qui s'approche prend feu…
Damage.NearBurnTime = 3 -- s… quelques secondes, sans dégâts (demande : « pas forcément faire des dégâts »)

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
	local horizontal = Vector3.new(dir.X, 0, dir.Z).Magnitude
	if horizontal < 0.7 and math.abs(dir.Y) > 1e-3 then
		-- choc par le toit ou le dessous (tonneau, réception) : point sur la face du haut / du bas
		local t = math.min(tx, tz, half.Y / math.abs(dir.Y))
		return c + dir * t
	end
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

-- Choc d'un pas physique (client du conducteur ou serveur) : dv = variation de vitesse (m/s), dw = variation de
-- vitesse angulaire (rad/s), toutes deux dans le repère du véhicule. Rend direction (du centre vers le point touché,
-- repère du véhicule) et force (m/s), ou nil sous le seuil.
function Damage.Measure(dv, dw, upY)
	local lin = Vector3.new(dv.X, dv.Y * Damage.VerticalWeight, dv.Z)
	-- rotation stoppée net : seulement hors d'aplomb (tonneau, voiture sur le flanc) ; à plat sur ses roues, la
	-- rotation ne compte pas (évite les faux chocs de lacet : dérapage, prise en main)
	local tumbling = upY == nil or upY < Damage.SpinUpright
	local spin = tumbling and (dw and dw.Magnitude or 0) * Damage.SpinArm or 0
	local strength = math.max(lin.Magnitude, spin)
	if strength <= Damage.MinImpact then
		return nil
	end
	local dir = lin.Magnitude > 1 and -lin.Unit or Vector3.yAxis -- rotation stoppée sans choc net : le toit / un coin
	return dir, strength
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
	dir = Vector3.new(dir.X, dir.Y or 0, dir.Z)
	if dir.Magnitude < 1e-3 then
		return
	end
	dir = dir.Unit
	local vertical = Vector3.new(dir.X, 0, dir.Z).Magnitude < 0.7 -- toit / dessous
	local cfg = cfgOf(model)
	local h = cfg.Handling or {}
	local P = Damage.ImpactPoint(cfg, dir)

	local energy = strength * strength - Damage.MinImpact * Damage.MinImpact -- (m/s)², croît avec le carré de la vitesse
	local body = model:GetAttribute("BodyHealth") or 1000
	body -= energy * Damage.BodyK * (h.CollisionDamageMult or 1)
	model:SetAttribute("BodyHealth", math.max(0, math.floor(body)))

	local enginePos = cfg.EnginePosition and v3(cfg.EnginePosition) or Vector3.new(0, 0, -1.4)
	local near = math.clamp(1.4 - (P - enginePos).Magnitude / 1.6, 0.12, 1)
	if vertical then
		near = math.max(near, Damage.RollEngineMin)
	end
	local engine = model:GetAttribute("EngineHealth") or 1000
	engine -= energy * Damage.EngineK * (h.EngineDamageMult or 1) * near
	engine = math.max(-100, math.floor(engine))
	model:SetAttribute("EngineHealth", engine)
	Damage.CheckState(model, true)

	-- feux au point d'impact
	local lr = Damage.LightRadius + 0.05 * over
	for role, pos in pairs(strength >= Damage.LightMin and cfg.Lights or {}) do
		if (v3(pos) - P).Magnitude < lr then
			model:SetAttribute("LightBroken_" .. role, true)
		end
	end
	-- vitres au point d'impact
	local smashed = false
	local fromBelow = vertical and dir.Y < 0
	local fromAbove = vertical and dir.Y > 0
	if not fromBelow and strength >= math.min(Damage.WindowMin, Damage.WindscreenMin) then
		local root, spm = model.PrimaryPart, cfg.StudsPerMeter or 3.571
		local Pw = root.CFrame:PointToWorldSpace(P * spm)
		-- par vitre (os) : la plus petite distance du point de choc au bord de ses pièces de verre
		local dist = {}
		for _, p in ipairs(model:GetDescendants()) do
			local bone = p:IsA("BasePart") and p:GetAttribute("Kind") == "glass" and p:GetAttribute("Window")
			if bone and model:GetAttribute("WindowBroken_" .. bone) ~= true then
				local l = p.CFrame:PointToObjectSpace(Pw)
				local h = p.Size / 2
				local onBox = Vector3.new(math.clamp(l.X, -h.X, h.X), math.clamp(l.Y, -h.Y, h.Y), math.clamp(l.Z, -h.Z, h.Z))
				local d = (l - onBox).Magnitude / spm
				dist[bone] = math.min(dist[bone] or math.huge, d)
			end
		end
		for bone, d in pairs(dist) do
			local laminated = bone == "windscreen" -- pare-brise avant ; la lunette arrière (windscreen_r) est trempée
			local min, reach, per
			if fromAbove then
				min, reach, per = Damage.RollMin, Damage.RoofWindowReach, Damage.RoofWindowReachPerMs
			elseif laminated then
				min, reach, per = Damage.WindscreenMin, Damage.WindscreenReach, Damage.WindscreenReachPerMs
			else
				min, reach, per = Damage.WindowMin, Damage.WindowReach, Damage.WindowReachPerMs
			end
			if strength >= min and d < reach + per * (strength - min) then
				model:SetAttribute("WindowBroken_" .. bone, true)
				smashed = true
			end
		end
		-- l'attribut seul ne cache rien : c'est Custom.Refresh qui rend la vitre invisible. Sans lui, la vitre cassée
		-- (éclats joués) restait affichée jusqu'au prochain rafraîchissement — un changement de teinte la faisait
		-- enfin disparaître (signalé par l'utilisateur, 2026-11-19 ; reproduit : choc de 16 m/s, vitres à 0,45).
		-- Un choc ≥ DetachAt le masquait, l'arrachage d'une portière rafraîchissant tout.
		if smashed then
			local custom = script.Parent:FindFirstChild("VehicleCustomization")
			local ok, Custom = pcall(function()
				return custom and require(custom)
			end)
			if ok and Custom and Custom.Refresh then
				pcall(Custom.Refresh, model)
			end
		end
	end
	-- ouvrant arraché sur un très gros choc de son côté
	if strength >= Damage.DetachAt and not vertical then
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
	-- roues proches du point d'impact
	for bone, w in pairs(cfg.Wheels or {}) do
		local d = ((v3(w.Position) - P) * Vector3.new(1, 0, 1)).Magnitude
		if d < Damage.WheelReach then
			Damage.HitWheel(model, bone, energy * Damage.WheelK * (1 - d / Damage.WheelReach))
		end
	end
	model:SetAttribute("LastImpact", string.format("%.2f,%.2f,%.1f", dir.X, dir.Z, strength))
end

local function custom()
	local m = script.Parent:FindFirstChild("VehicleCustomization")
	local ok, C = pcall(function()
		return m and require(m)
	end)
	return ok and C or nil
end

-- Copie physique des pièces d'une roue, qui tombe, roule et disparaît après DebrisLifetime s (comme un ouvrant
-- arraché, VehicleCustomization.RemoveDoor), dans le groupe des débris (ne touche ni véhicule ni occupant).
local function dropWheel(model, bone)
	local C = custom()
	local root = model.PrimaryPart
	if not root then
		return
	end
	local pieces = {}
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") and part.Transparency < 1 and part:GetAttribute("F2RPart") then
			local chain = part:GetAttribute("BoneChain") or part:GetAttribute("Bone") or ""
			if string.find("/" .. chain .. "/", "/" .. bone .. "/", 1, true) then
				table.insert(pieces, part)
			end
		end
	end
	if #pieces == 0 then
		return
	end
	local debris = Instance.new("Model")
	debris.Name = model.Name .. "_" .. bone .. "_debris"
	local first
	for _, part in ipairs(pieces) do
		local copy = part:Clone()
		for _, d in ipairs(copy:GetDescendants()) do
			if d:IsA("JointInstance") or d:IsA("WeldConstraint") or d:IsA("Constraint") or d:IsA("Attachment") or d:IsA("Light") then
				d:Destroy()
			end
		end
		copy.Anchored, copy.CanCollide, copy.CanQuery, copy.CanTouch, copy.Massless = false, false, false, false, true
		copy:SetAttribute("F2RPart", nil)
		copy.Parent = debris
		if first then
			local wc = Instance.new("WeldConstraint")
			wc.Part0, wc.Part1, wc.Parent = first, copy, copy
		else
			first = copy
			copy.CanCollide = true -- une seule pièce touche le sol (assez pour tomber et rouler)
			copy.Massless = false
		end
	end
	debris.PrimaryPart = first
	local okA, Access = pcall(require, script.Parent:WaitForChild("VehicleAccess", 5))
	if okA and Access and Access.TagDebris then
		Access.TagDebris(debris)
	end
	debris.Parent = workspace
	local away = (first.Position - root.Position) * Vector3.new(1, 0, 1)
	away = away.Magnitude > 1e-3 and away.Unit or Vector3.zero
	first.AssemblyLinearVelocity = root.AssemblyLinearVelocity + away * 10 + Vector3.new(0, 8, 0)
	first.AssemblyAngularVelocity = root.CFrame.RightVector * (root.AssemblyLinearVelocity.Magnitude / 1.5) -- elle roule
	pcall(function()
		first:SetNetworkOwner(nil)
	end)
	game:GetService("Debris"):AddItem(debris, (C and C.DebrisLifetime) or 60)
end

-- SERVEUR. État d'une roue (ne fait que monter jusqu'à la réparation) ; 3 = arrachée (débris, pièces masquées).
function Damage.SetWheelState(model, bone, state)
	local cur = model:GetAttribute("WheelState_" .. bone) or 0
	if state <= cur then
		return
	end
	if state == 1 and model:GetAttribute("Tune_BulletproofTyres") == true then
		return -- pneus increvables
	end
	model:SetAttribute("WheelState_" .. bone, state)
	if state >= 3 then
		dropWheel(model, bone)
		local C = custom()
		if C and C.Refresh then
			pcall(C.Refresh, model) -- masque la roue sur la voiture (VehicleCustomization.Refresh)
		end
	end
end

-- SERVEUR. Retire `amount` points à une roue et en déduit son état.
function Damage.HitWheel(model, bone, amount)
	if model:GetAttribute("NoDamage") == true or amount <= 0 then
		return
	end
	local hp = (model:GetAttribute("WheelHealth_" .. bone) or Damage.WheelHealthMax) - amount
	hp = math.max(0, math.floor(hp))
	model:SetAttribute("WheelHealth_" .. bone, hp)
	local state = (hp <= 0 and 3) or (hp < Damage.WheelBreakBelow and 2)
		or (hp < Damage.WheelBurstBelow and model:GetAttribute("Tune_BulletproofTyres") ~= true and 1) or 0
	Damage.SetWheelState(model, bone, state)
end

-- SERVEUR. Herse : crève le pneu d'une roue intacte (pas de dégât de santé en plus).
function Damage.Puncture(model, bone)
	if model:GetAttribute("NoDamage") == true then
		return false
	end
	if (model:GetAttribute("WheelState_" .. bone) or 0) ~= 0 or model:GetAttribute("Tune_BulletproofTyres") == true then
		return false
	end
	Damage.SetWheelState(model, bone, 1)
	return true
end

function Damage.Reset(model)
	for k in pairs(model:GetAttributes()) do
		if string.sub(k, 1, 12) == "LightBroken_" or string.sub(k, 1, 11) == "WheelState_" or string.sub(k, 1, 12) == "WheelHealth_" then
			model:SetAttribute(k, nil)
		end
	end
	model:SetAttribute("BodyHealth", nil)
	model:SetAttribute("EngineHealth", nil)
	model:SetAttribute("EngineDead", nil)
	model:SetAttribute("EngineFault", nil)
	model:SetAttribute("Wrecked", nil)
	model:SetAttribute("Burning", nil)
	model:SetAttribute("BurnUntil", nil)
end

-- Stade de la panne d'après la santé du moteur : 0 sain, 1 fumée claire, 2 fumée noire, 3 feu.
function Damage.Stage(model)
	local e = model:GetAttribute("EngineHealth") or 1000
	return (e < Damage.FireBelow and 3) or (e < Damage.HeavySmokeBelow and 2) or (e < Damage.SmokeBelow and 1) or 0
end

local function setFault(model, kind)
	-- horodaté pour que le client du conducteur affiche le message même si la panne se répète
	model:SetAttribute("EngineFault", kind .. ":" .. string.format("%.2f", workspace:GetServerTimeNow()))
end

function Damage.Stall(model)
	if model:GetAttribute("Engine") == true and model:GetAttribute("EngineAlwaysOn") ~= true then
		model:SetAttribute("Engine", false)
		setFault(model, "stall")
	end
end

function Damage.Kill(model)
	if model:GetAttribute("EngineDead") ~= true then
		model:SetAttribute("EngineDead", true)
		model:SetAttribute("Engine", false)
		setFault(model, "dead")
	end
end

-- Véhicule en feu : tout est coupé et reste coupé jusqu'à la réparation (Repair → Damage.Reset).
function Damage.Wreck(model)
	if model:GetAttribute("Wrecked") == true then
		return
	end
	model:SetAttribute("Wrecked", true)
	model:SetAttribute("EngineDead", true)
	model:SetAttribute("Engine", false)
	model:SetAttribute("Burning", true)
	model:SetAttribute("BurnUntil", workspace:GetServerTimeNow() + Damage.BurnTime)
	for k, v in pairs({ Headlights = 0, Indicator = "Off", Siren = false, Horn = false, ExtraLights = false,
		InteriorLight = false, Throttle = 0 }) do
		if model:GetAttribute(k) ~= nil then
			model:SetAttribute(k, v)
		end
	end
	local custom = script.Parent:FindFirstChild("VehicleCustomization")
	local ok, Custom = pcall(function()
		return custom and require(custom)
	end)
	if ok and Custom and Custom.RefreshNeons then
		pcall(Custom.RefreshNeons, model) -- néons coupés (RefreshNeons lit Wrecked)
	end
	setFault(model, "fire")
end

-- SERVEUR. Applique le stade : feu → épave ; santé ≤ 0 → moteur mort. onHit : tirage « sur le coup » d'un choc.
function Damage.CheckState(model, onHit)
	if model:GetAttribute("NoDamage") == true then
		return
	end
	local stage = Damage.Stage(model)
	if stage >= 3 then
		Damage.Wreck(model)
		return
	end
	local e = model:GetAttribute("EngineHealth") or 1000
	if e <= 0 then
		Damage.Kill(model)
		return
	end
	if onHit and model:GetAttribute("Engine") == true then
		if stage == 2 and math.random() < Damage.DeathOnHit then
			Damage.Kill(model)
		elseif stage >= 1 and math.random() < Damage.StallOnHit then
			Damage.Stall(model)
		end
	end
end

-- SERVEUR, toutes les dt s : pannes au hasard pendant que le moteur tourne, fin des flammes.
function Damage.Tick(model, dt)
	if model:GetAttribute("NoDamage") == true then
		return
	end
	if model:GetAttribute("Burning") == true then
		local untilT = model:GetAttribute("BurnUntil") or 0
		if workspace:GetServerTimeNow() >= untilT then
			model:SetAttribute("Burning", false) -- les flammes s'éteignent, l'épave fume noir
		end
		return
	end
	local stage = Damage.Stage(model)
	if stage == 0 or model:GetAttribute("Engine") ~= true or model:GetAttribute("EngineAlwaysOn") == true then
		return
	end
	local idle = (model:GetAttribute("Throttle") or 0) < 0.05
	local k = dt * (idle and 0.5 or 1)
	if stage >= 2 then
		if math.random() < Damage.DeathPerSecond * k then
			Damage.Kill(model)
		end
	elseif math.random() < Damage.StallPerSecond * k then
		Damage.Stall(model)
	end
end

-- SERVEUR. Met un personnage en feu `seconds` s (prolonge s'il brûle déjà) ; dps = dégâts par seconde (0 : aucun).
local burning = setmetatable({}, { __mode = "k" }) -- character -> { untilT, dps, fire }
function Damage.Ignite(character, seconds, dps)
	local hum = character and character:FindFirstChildOfClass("Humanoid")
	local torso = character and (character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
		or character:FindFirstChild("HumanoidRootPart"))
	if not hum or not torso or hum.Health <= 0 then
		return
	end
	local b = burning[character]
	local now = os.clock()
	if b and b.fire.Parent then
		b.untilT = math.max(b.untilT, now + seconds)
		b.dps = math.max(b.dps, dps)
		return
	end
	local fire = Instance.new("Fire")
	fire.Name = "F2R_Burning"
	fire.Size = 4
	fire.Heat = 7
	fire.Color = Color3.fromRGB(255, 120, 40)
	fire.SecondaryColor = Color3.fromRGB(255, 50, 10)
	fire.Parent = torso
	burning[character] = { untilT = now + seconds, dps = dps, fire = fire, hum = hum }
end

-- SERVEUR, toutes les dt s : brûlures en cours (dégâts, extinction).
function Damage.BurnTick(dt)
	local now = os.clock()
	for character, b in pairs(burning) do
		if now >= b.untilT or not b.fire.Parent or b.hum.Health <= 0 or not character.Parent then
			b.fire:Destroy()
			burning[character] = nil
		elseif b.dps > 0 then
			b.hum:TakeDamage(b.dps * dt)
		end
	end
end

-- Foyer d'un véhicule en feu (studs, monde) : la position du moteur.
function Damage.FirePosition(model)
	local root = model.PrimaryPart
	if not root then
		return nil
	end
	local cfg = cfgOf(model)
	local spm = cfg.StudsPerMeter or 3.571
	local pos = cfg.EnginePosition and v3(cfg.EnginePosition) or Vector3.new(0, 0.2, -1.4)
	return root.CFrame:PointToWorldSpace(pos * spm), spm
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
	local stage = Damage.Stage(model)
	if model:GetAttribute("Wrecked") == true then
		-- épave : flammes tant que Burning, puis fumée noire (même si la santé a été remontée par un script)
		stage = model:GetAttribute("Burning") == true and 3 or 2
	end
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
	fx.smoke.Color = ColorSequence.new(stage >= 2 and Color3.fromRGB(40, 40, 42) or Color3.fromRGB(205, 205, 210))
	-- en feu : la fumée reste derrière les flammes (ZOffset) et n'est presque plus éclairée par la lumière du feu
	fx.smoke.LightInfluence = stage >= 3 and 0.3 or 1
	fx.smoke.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(0.6, 0.6), NumberSequenceKeypoint.new(1, 1) })
	fx.fire.Enabled = stage >= 3
	fx.fire.Rate = 55
	fx.light.Enabled = stage >= 3
end

return Damage
