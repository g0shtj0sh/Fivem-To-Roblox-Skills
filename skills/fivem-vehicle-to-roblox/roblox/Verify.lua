--!nonstrict
--[[
	Verify.lua — contrôle d'un véhicule converti par fivem-vehicle-to-roblox, dans Studio.

	Le fichier renvoie une fonction verify(opts) -> chaîne JSON.
		Edit / serveur (execute_luau) : loadstring(source)()(opts)
		client en Play (loadstring y est interdit) : ModuleScript -> require(module)(opts)
	Options (table opts, ou _G.F2R_VERIFY) :
		model  : le Model installé (défaut : premier modèle tagué FiveMVehicle du Workspace)
		checks : liste de groupes à lancer (défaut selon le contexte, voir DEFAULTS)
	Renvoie une chaîne JSON :
		{ vehicle, context, pass, fail, warn, skip, results = { {group, name, status, detail} } }
	status ∈ "pass" | "fail" | "warn" | "skip".

	Groupes :
		runtime    modules runtime installés (ReplicatedStorage / ServerScriptService / StarterPlayerScripts)
		structure  pièces attendues présentes et nommées, échelle (empattement), véhicule droit, avant vers −Z de VehicleRoot
		wheels     roues à leur place (pivots et géométrie), côtés gauche/droite
		collision  hitbox fidèle : collision GTA présente, invisible, solide, bien soudée, précision
		           réglée ; rayons depuis les 6 faces : écart hitbox / carrosserie visible (et ancienne boîte)
		sounds     SoundId renseignés, boucles moteur présentes (client en Play : chargement réel)
		custom     SetColor / SetMod / SetLivery / SetExtra / SetNeon / SetPlate, Serialize / Apply restaure l'état
		joints     Motor6D qui bougent (roues, volant, portes, capot, coffre) — client en Play (runtime actif)
		lights     chaque LightRole passe en Neon selon Headlights / Brake / Indicator / Reverse / Engine / Siren — client en Play
		audio      les boucles moteur jouent quand Engine = true — client en Play
		access     invites « Conduire / Monter » (F, manette Y) par siège, côté portière, dehors ;
		           invite « Remettre sur ses roues » ; attributs Locked / ParkAnchorDelay
		-- scénarios SERVEUR en Play, avec un joueur (opts.player, sinon le premier) :
		seats_play monter puis descendre à chaque place (opts.seat pour une seule) : assis, portière
		           ouverte puis refermée, regard vers l'avant, tête et jambes hors de la carrosserie,
		           invite masquée, puis posé au sol côté portière, hors de la collision
		lock_play  Locked = true : invites masquées et montée refusée, puis déverrouillage
		park_play  conducteur à bord : VehicleRoot désancré ; descendu : ancré après ParkAnchorDelay
		flip_play  retournement forcé : Flipped après 2 s, invite de remise, Recover le remet droit et au sol
		void_play  chute dans le vide : remis à sa dernière position sûre avant FallenPartsDestroyHeight,
		           aucune pièce détruite (VehicleAccess.RecoverFromVoid)
		-- scénario CLIENT en Play, joueur au volant (après seats_play ou Access.Enter côté serveur) :
		drive_play accélérer 3 s puis freiner : vitesse, rapport, régime cohérent avec la vitesse, arrêt,
		           véhicule droit et au sol (moteur de conduite VehicleDrive)
]]

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")
local ContentProvider = game:GetService("ContentProvider")

local function run(opts)
opts = opts or _G.F2R_VERIFY or {}
_G.F2R_VERIFY = nil

local context = (not RunService:IsRunning()) and "edit" or (RunService:IsClient() and "client" or "server")
local DEFAULTS = {
	edit = { "runtime", "structure", "wheels", "collision", "access", "sounds", "custom" },
	server = { "runtime", "structure", "wheels", "collision", "access", "sounds", "custom" },
	client = { "joints", "lights", "sounds", "audio" },
}

local results = {}
local counts = { pass = 0, fail = 0, warn = 0, skip = 0 }
local currentGroup = "?"
local function rec(status, name, detail)
	counts[status] += 1
	table.insert(results, { group = currentGroup, name = name, status = status, detail = detail })
end
local function check(cond, name, detail, softStatus)
	rec(cond and "pass" or (softStatus or "fail"), name, detail)
	return cond
end
local function fmt(...)
	return string.format(...)
end
local function v3(t)
	return Vector3.new(t[1], t[2], t[3])
end

-- En Edit, require() garde la première version chargée dans la session Studio : on requiert
-- une copie du ModuleScript pour tester le code réellement installé.
local function freshRequire(ms)
	if context == "edit" then
		local copy = ms:Clone()
		return require(copy)
	end
	return require(ms)
end

-- ------------------------------------------------------------------ cible
local model = opts.model
if not model then
	for _, m in ipairs(CollectionService:GetTagged("FiveMVehicle")) do
		if m:IsDescendantOf(workspace) then
			model = m
			break
		end
	end
end
if not model then
	return HttpService:JSONEncode({ context = context, fail = 1, results = { { group = "setup", name = "model", status = "fail", detail = "aucun modèle FiveMVehicle trouvé" } } })
end
local cfgModule = model:FindFirstChild("VehicleConfig")
if not cfgModule then
	return HttpService:JSONEncode({ context = context, fail = 1, results = { { group = "setup", name = "VehicleConfig", status = "fail", detail = "absent : Setup non exécuté" } } })
end
local okCfg, CONFIG = pcall(require, cfgModule)
if not okCfg then
	return HttpService:JSONEncode({ context = context, fail = 1, results = { { group = "setup", name = "VehicleConfig", status = "fail", detail = tostring(CONFIG) } } })
end
local spm = CONFIG.StudsPerMeter or 3.571
local root = model.PrimaryPart
local joints = model:FindFirstChild("Joints")

local function pivotOf(bone)
	return joints and joints:FindFirstChild("Pivot_" .. bone)
end
local function motorOf(bone)
	if not joints then
		return nil
	end
	for _, m in ipairs(joints:GetChildren()) do
		if m:IsA("Motor6D") and (m:GetAttribute("Bone") or m.Name) == bone then
			return m
		end
	end
	return nil
end
local function partsWhere(fn)
	local out = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and d:GetAttribute("F2RPart") and fn(d) then
			table.insert(out, d)
		end
	end
	return out
end
local function localCF(part)
	return root.CFrame:ToObjectSpace(part.CFrame)
end
local function angleBetween(a, b)
	local _, ang = a:ToObjectSpace(b):ToAxisAngle()
	return math.deg(math.abs(ang))
end
-- angle attendu ramené dans [0, 180] (ToAxisAngle donne la plus petite rotation : 270° -> 90°)
local function folded(deg)
	deg = deg % 360
	return deg > 180 and 360 - deg or deg
end
-- Le runtime avance sur RenderStepped, qui ralentit ou se fige quand la fenêtre Studio n'a
-- pas le focus : on attend la condition (avec délai max) en comptant les images rendues,
-- pour distinguer « rendu figé » d'un vrai défaut.
local function waitFor(pred, timeout)
	local frames = 0
	local conn = RunService.RenderStepped:Connect(function()
		frames += 1
	end)
	local t0 = os.clock()
	local ok = pred()
	while not ok and os.clock() - t0 < timeout do
		task.wait()
		ok = pred()
	end
	conn:Disconnect()
	return ok, frames, os.clock() - t0
end

-- ------------------------------------------------------------------ groupes
local groups = {}

function groups.runtime()
	local folder = ReplicatedStorage:FindFirstChild("FiveMVehicles")
	check(folder ~= nil, "ReplicatedStorage.FiveMVehicles", folder and ("RuntimeVersion " .. tostring(folder:GetAttribute("RuntimeVersion"))) or "absent")
	for _, n in ipairs({ "VehicleRuntime", "VehicleCustomization", "VehicleInput", "VehicleAccess", "VehicleDashboard", "VehiclePose", "VehicleCamera", "VehicleEvent", "VehicleTelemetry" }) do
		local o = folder and folder:FindFirstChild(n)
		check(o ~= nil, "FiveMVehicles." .. n, o and o.ClassName or "absent")
	end
	local srv = ServerScriptService:FindFirstChild("FiveMVehiclesServer")
	check(srv ~= nil and srv:IsA("Script"), "ServerScriptService.FiveMVehiclesServer", srv and srv.ClassName or "absent")
	local sps = StarterPlayer:FindFirstChild("StarterPlayerScripts")
	local cli = sps and sps:FindFirstChild("FiveMVehiclesClient")
	check(cli ~= nil and cli:IsA("LocalScript"), "StarterPlayerScripts.FiveMVehiclesClient", cli and cli.ClassName or "absent")
	check(CollectionService:HasTag(model, "FiveMVehicle"), "tag FiveMVehicle", model:GetFullName())
end

function groups.structure()
	check(root ~= nil and root.Name == "VehicleRoot", "PrimaryPart = VehicleRoot", root and root.Name or "nil")
	if not root then
		return
	end
	-- pièces attendues (le Setup les a retrouvées par leur nom dans le modèle importé)
	local expected = model:GetAttribute("F2RExpectedParts")
	local missingNames = model:GetAttribute("F2RMissingParts") or ""
	local found = partsWhere(function()
		return true
	end)
	if expected then
		check(#found == expected and missingNames == "", "pièces présentes et nommées",
			fmt("%d/%d trouvées%s", #found, expected, missingNames ~= "" and (" ; manquantes : " .. missingNames) or ""))
	else
		check(#found > 0, "pièces présentes", fmt("%d pièces F2RPart (nombre attendu inconnu : Setup antérieur)", #found), "warn")
	end
	local unnamed, noKind = 0, 0
	for _, p in ipairs(found) do
		if string.find(p.Name, "_Node$") or p.Name == "" then
			unnamed += 1
		end
		if not p:GetAttribute("Kind") or not p:GetAttribute("Owner") then
			noKind += 1
		end
	end
	check(unnamed == 0 and noKind == 0, "attributs de pièce (Kind, Owner)", fmt("%d sans nom propre, %d sans Kind/Owner", unnamed, noKind))
	local leftovers = 0
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Model") and string.find(d.Name, "_Node$") then
			leftovers += 1
		end
	end
	check(leftovers == 0, "conteneurs d'import vides retirés", fmt("%d Model *_Node restants", leftovers), "warn")

	-- véhicule droit, avant vers −Z
	local up = root.CFrame.UpVector
	local look = root.CFrame.LookVector
	check(up.Y > 0.999, "véhicule droit", fmt("UpVector = (%.3f, %.3f, %.3f)", up.X, up.Y, up.Z))
	-- le véhicule peut regarder n'importe où dans le monde (tourné après l'installation) : on contrôle
	-- qu'il est à plat, puis que l'avant géométrique est du côté −Z de VehicleRoot
	check(math.abs(look.Y) < 0.01, "avant à l'horizontale (VehicleRoot)", fmt("LookVector = (%.3f, %.3f, %.3f)", look.X, look.Y, look.Z))

	-- l'avant géométrique (roues avant, phares) doit être du côté −Z de VehicleRoot
	local fz, rz, nf, nr = 0, 0, 0, 0
	for bone, w in pairs(CONFIG.Wheels or {}) do
		local pv = pivotOf(bone)
		if pv then
			if w.Front then
				fz += root.CFrame:PointToObjectSpace(pv.Position).Z
				nf += 1
			else
				rz += root.CFrame:PointToObjectSpace(pv.Position).Z
				nr += 1
			end
		end
	end
	if nf > 0 and nr > 0 then
		fz, rz = fz / nf, rz / nr
		check(fz < rz, "roues avant côté −Z (repère du véhicule)", fmt("z avant %.2f, z arrière %.2f", fz, rz))
		local wb = rz - fz
		local cfgFront, cfgRear, cf, cr = 0, 0, 0, 0
		for _, w in pairs(CONFIG.Wheels) do
			if w.Front then
				cfgFront += w.Position[3]
				cf += 1
			else
				cfgRear += w.Position[3]
				cr += 1
			end
		end
		local want = math.abs(cfgRear / cr - cfgFront / cf) * spm
		check(math.abs(wb - want) / want < 0.01, "échelle (empattement)",
			fmt("%.2f studs mesurés, %.2f attendus (%.3f m × %.3f studs/m)", wb, want, want / spm, spm))
	else
		rec("fail", "empattement", "pivots de roues introuvables")
	end
	local lights = CONFIG.Lights or {}
	if lights.headlight_l and lights.taillight_l then
		local h = v3(lights.headlight_l) * spm -- repère de VehicleRoot
		local t = v3(lights.taillight_l) * spm
		check(h.Z < t.Z, "phares devant les feux arrière", fmt("z phare %.2f, z feu %.2f (repère du véhicule)", h.Z, t.Z))
	end
	-- emprise : la géométrie visible doit tenir dans les bornes du véhicule
	local lo, hi = v3(CONFIG.Bounds.Min) * spm, v3(CONFIG.Bounds.Max) * spm
	local outside = 0
	for _, p in ipairs(found) do
		local lp = root.CFrame:PointToObjectSpace(p.Position)
		if lp.X < lo.X - 0.5 or lp.X > hi.X + 0.5 or lp.Y < lo.Y - 0.5 or lp.Y > hi.Y + 0.5 or lp.Z < lo.Z - 0.5 or lp.Z > hi.Z + 0.5 then
			outside += 1
		end
	end
	check(outside == 0, "pièces dans l'emprise du véhicule", fmt("%d pièce(s) hors des bornes (+0,5 stud)", outside))
	local seat = model:FindFirstChild("DriverSeat", true)
	check(seat ~= nil and seat:IsA("Seat"), "DriverSeat", seat and seat:GetFullName() or "absent")
	-- posé au sol : bas des roues sur la surface située dessous
	local lowest = math.huge
	for _, w in pairs(CONFIG.Wheels or {}) do
		lowest = math.min(lowest, (w.Position[2] - (w.Radius or 0.35)) * spm)
	end
	if lowest < math.huge then
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { model }
		local hit = workspace:Raycast(root.Position + Vector3.new(0, 2, 0), Vector3.new(0, -200, 0), params)
		if hit then
			local gap = (root.Position.Y + lowest) - hit.Position.Y
			check(math.abs(gap) < 0.2, "posé au sol", fmt("bas des roues à %+.2f stud de %s", gap, hit.Instance.Name), "warn")
		else
			rec("warn", "posé au sol", "aucune surface sous le véhicule")
		end
	end
end

function groups.wheels()
	if not root then
		return
	end
	for bone, w in pairs(CONFIG.Wheels or {}) do
		local pv = pivotOf(bone)
		if not pv then
			rec("fail", bone, "pivot absent")
		else
			local want = root.CFrame:PointToWorldSpace(v3(w.Position) * spm)
			local err = (pv.Position - want).Magnitude
			local lp = root.CFrame:PointToObjectSpace(pv.Position)
			local sideOk = (w.Left and lp.X < 0) or (not w.Left and lp.X > 0)
			-- la géométrie de la roue entoure son pivot
			local geo = partsWhere(function(p)
				return p:GetAttribute("Owner") == bone
			end)
			local cen, n = Vector3.zero, 0
			for _, p in ipairs(geo) do
				cen += p.Position
				n += 1
			end
			local geoErr = n > 0 and ((cen / n) - pv.Position).Magnitude or math.huge
			check(err < 0.05 and sideOk and geoErr < (w.Radius or 0.35) * spm,
				bone .. " en place",
				fmt("pivot à %.3f stud de la config, côté %s, %d pièce(s) dont le centre est à %.2f stud du pivot",
					err, lp.X < 0 and "gauche" or "droit", n, geoErr))
			check(motorOf(bone) ~= nil, bone .. " Motor6D", motorOf(bone) and "présent" or "absent")
		end
	end
end

function groups.collision()
	local col = CONFIG.Collision or {}
	if col.Source ~= "gta" then
		rec("warn", "hitbox fidèle", "pas de collision GTA dans ce véhicule : hitbox = boîte englobante")
		return
	end
	local pieces = partsWhere(function(p)
		return p:GetAttribute("Kind") == "collision"
	end)
	local wheelsCol = {}
	local folder = model:FindFirstChild("Collision")
	for _, d in ipairs(folder and folder:GetDescendants() or {}) do
		if d:IsA("BasePart") and d:GetAttribute("Kind") == "collision_wheel" then
			table.insert(wheelsCol, d)
		end
	end
	check(#pieces == (col.Pieces or -1), "morceaux de collision", fmt("%d/%d", #pieces, col.Pieces or 0))
	local nWheels = 0
	for _ in pairs(col.Wheels or {}) do
		nWheels += 1
	end
	check(#wheelsCol == nWheels, "roues de collision", fmt("%d/%d cylindres", #wheelsCol, nWheels))
	local bad, fid, unwelded = 0, {}, {}
	for _, p in ipairs(pieces) do
		if not (p.CanCollide and p.CanQuery and p.CanTouch and p.Transparency >= 1) then
			bad += 1
		end
		local f = tostring(p.CollisionFidelity):gsub("Enum.CollisionFidelity.", "")
		fid[f] = (fid[f] or 0) + 1
		local owner = p:GetAttribute("Owner")
		local want = owner == CONFIG.RootBone and root or pivotOf(owner)
		local w = p:FindFirstChildOfClass("WeldConstraint")
		if not (w and w.Part0 == want and w.Part1 == p) then
			table.insert(unwelded, p.Name)
		end
	end
	check(bad == 0, "collision invisible, solide et interrogeable", fmt("%d pièce(s) mal réglée(s)", bad))
	local fl = {}
	for k, n in pairs(fid) do
		table.insert(fl, k .. " " .. n)
	end
	table.sort(fl)
	check((fid.Default or 0) == 0 and (fid.Box or 0) == 0, "précision de collision", table.concat(fl, ", "))
	check(#unwelded == 0, "collision soudée à son os (portes, capot, coffre)",
		#unwelded > 0 and ("mal soudées : " .. table.concat(unwelded, ", ")) or "ok")
	local hb = model:FindFirstChild("Hitbox")
	check(hb ~= nil and not hb.CanCollide and not hb.CanQuery, "boîte englobante neutralisée",
		hb and fmt("CanCollide %s, CanQuery %s", tostring(hb.CanCollide), tostring(hb.CanQuery)) or "absente")

	-- fidélité : rayons depuis les 6 faces de la boîte englobante, vers l'intérieur
	local visual = partsWhere(function(p)
		return p:GetAttribute("Kind") ~= "collision" and p.Transparency < 1
	end)
	local saved = {}
	for _, p in ipairs(visual) do
		saved[p] = p.CanQuery
		p.CanQuery = true
	end
	local hbQuery = hb and hb.CanQuery
	if hb then
		hb.CanQuery = true
	end
	local function params(list)
		local rp = RaycastParams.new()
		rp.FilterType = Enum.RaycastFilterType.Include
		rp.FilterDescendantsInstances = list
		return rp
	end
	local colAll = table.clone(pieces)
	for _, w in ipairs(wheelsCol) do
		table.insert(colAll, w)
	end
	local pV, pC, pB = params(visual), params(colAll), params(hb and { hb } or {})
	local lo, hi = v3(CONFIG.Bounds.Min) * spm, v3(CONFIG.Bounds.Max) * spm
	local tol = 0.15 * spm -- 15 cm : marge GTA (4 cm) + approximation de la collision des pièces visibles
	local faces = {
		{ axis = 1, sign = -1 }, { axis = 1, sign = 1 }, { axis = 2, sign = -1 }, { axis = 2, sign = 1 },
		{ axis = 3, sign = -1 }, { axis = 3, sign = 1 },
	}
	local stats = { col = { agree = 0, small = 0, big = 0 }, box = { agree = 0, small = 0, big = 0 } }
	local nV = 0
	local N = 9
	for _, f in ipairs(faces) do
		local a1, a2 = (f.axis % 3) + 1, ((f.axis + 1) % 3) + 1
		for i = 1, N do
			for j = 1, N do
				local pt = { 0, 0, 0 }
				pt[a1] = lo[({ "X", "Y", "Z" })[a1]] + (hi - lo)[({ "X", "Y", "Z" })[a1]] * (i - 0.5) / N
				pt[a2] = lo[({ "X", "Y", "Z" })[a2]] + (hi - lo)[({ "X", "Y", "Z" })[a2]] * (j - 0.5) / N
				local edge = f.sign > 0 and hi[({ "X", "Y", "Z" })[f.axis]] or lo[({ "X", "Y", "Z" })[f.axis]]
				pt[f.axis] = edge + f.sign * 2
				local dir = { 0, 0, 0 }
				dir[f.axis] = -f.sign * ((hi - lo)[({ "X", "Y", "Z" })[f.axis]] + 4)
				local o = root.CFrame:PointToWorldSpace(Vector3.new(pt[1], pt[2], pt[3]))
				local d = root.CFrame:VectorToWorldSpace(Vector3.new(dir[1], dir[2], dir[3]))
				local hv = workspace:Raycast(o, d, pV)
				if hv then
					nV += 1
					for key, rp in pairs({ col = pC, box = pB }) do
						local h = workspace:Raycast(o, d, rp)
						local s = stats[key]
						if not h or h.Distance > hv.Distance + tol then
							s.small += 1 -- la hitbox laisse passer ce que l'on voit
						elseif h.Distance < hv.Distance - tol then
							s.big += 1 -- la hitbox arrête avant la carrosserie
						else
							s.agree += 1
						end
					end
				end
			end
		end
	end
	for p, q in pairs(saved) do
		p.CanQuery = q
	end
	if hb then
		hb.CanQuery = hbQuery
	end
	if nV == 0 then
		rec("fail", "hitbox fidèle à la carrosserie", "aucun rayon n'a touché la carrosserie visible")
		return
	end
	local function pct(n)
		return math.floor(n / nV * 100 + 0.5)
	end
	local c, b = stats.col, stats.box
	check(c.agree / nV >= 0.8, "hitbox fidèle à la carrosserie",
		fmt("%d %% des %d rayons à moins de %.2f stud (ancienne boîte : %d %%) ; trop large %d %%, trop juste %d %% (boîte : %d %% / %d %%)",
			pct(c.agree), nV, tol, pct(b.agree), pct(c.big), pct(c.small), pct(b.big), pct(b.small)))

	-- passages de roues : la coque ne doit rien occuper sous le haut d'une roue comprimée au maximum
	-- (VehicleCollision). Sinon une roue qui monte sur un obstacle le fait toucher à la coque, dans le
	-- passage de roue : véhicule posé « sur rien » ou bloqué sans contact visible (m422, 2026-11-12).
	local hull = pieces
	local hd = CONFIG.Handling or {}
	local upper = (hd.SuspensionUpperLimit or 0.1) + (hd.SuspensionRaise or 0)
	local blocked = {}
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Include
	rp.FilterDescendantsInstances = hull
	for bone, w in pairs(CONFIG.Wheels or {}) do
		local pos = v3(w.Position)
		local worst = nil
		for _, fx in ipairs({ -0.35, 0, 0.35 }) do
			for _, fz in ipairs({ -0.6, -0.3, 0, 0.3, 0.6 }) do
				-- dessus du pneu (profil rond) à cet endroit, roue comprimée au maximum, moins 1 cm de tolérance
				local top = (pos.Y + upper + w.Radius * math.sqrt(1 - fz * fz) - 0.01) * spm
				local lp = Vector3.new(pos.X + fx * w.Width, 0, pos.Z + fz * w.Radius) * spm
				local o = root.CFrame:PointToWorldSpace(Vector3.new(lp.X, pos.Y * spm - 3 * spm, lp.Z))
				local r = workspace:Raycast(o, root.CFrame.UpVector * (6 * spm), rp)
				if r then
					local y = root.CFrame:PointToObjectSpace(r.Position).Y
					if y < top and (worst == nil or top - y > worst) then
						worst = top - y
					end
				end
			end
		end
		if worst then
			table.insert(blocked, fmt("%s (coque à %.0f cm sous le dessus du pneu)", bone, worst / spm * 100))
		end
	end
	check(#blocked == 0, "passages de roues dégagés", #blocked == 0 and "les 4 roues peuvent monter sans toucher la coque"
		or table.concat(blocked, ", "))
end

function groups.access()
	local seatsFolder = model:FindFirstChild("Seats")
	local seats = {}
	for _, s in ipairs(seatsFolder and seatsFolder:GetChildren() or {}) do
		if s:IsA("Seat") or s:IsA("VehicleSeat") then
			table.insert(seats, s)
		end
	end
	check(#seats > 0 and model:FindFirstChild("DriverSeat", true) ~= nil, "sièges", fmt("%d place(s), dont DriverSeat", #seats))
	local lo, hi = v3(CONFIG.Bounds.Min) * spm, v3(CONFIG.Bounds.Max) * spm
	for _, seat in ipairs(seats) do
		local a = root and root:FindFirstChild("Enter_" .. seat.Name)
		local prompt = a and a:FindFirstChildOfClass("ProximityPrompt")
		if not prompt then
			rec("fail", "invite " .. seat.Name, "absente (Enter_" .. seat.Name .. ")")
		else
			local lp = root.CFrame:PointToObjectSpace(a.WorldPosition)
			local side = seat:GetAttribute("Side")
			local outside = lp.X < lo.X or lp.X > hi.X
			local rightSide = side ~= nil and ((side < 0) == (lp.X < 0))
			local wantText = seat.Name == "DriverSeat" and "Conduire" or "Monter"
			check(prompt.KeyboardKeyCode == Enum.KeyCode.F and prompt.GamepadKeyCode == Enum.KeyCode.ButtonY
				and prompt.ActionText == wantText and outside and rightSide,
				"invite " .. seat.Name,
				fmt("« %s » %s / %s, %s, côté %s, portière %s", prompt.ActionText, prompt.KeyboardKeyCode.Name,
					prompt.GamepadKeyCode.Name, outside and "dehors" or "DANS la carrosserie",
					tostring(side), tostring(seat:GetAttribute("Door"))))
		end
		local look = seat.CFrame.LookVector:Dot(root.CFrame.LookVector)
		check(look > 0.99, "siège " .. seat.Name .. " tourné vers l'avant", fmt("%.3f", look))
	end
	-- tout attachment (invites, lumières, sons) doit être sur le véhicule : un WorldPosition réglé
	-- avant le parent le projette des milliers de studs plus loin (défaut corrigé le 2026-11-11)
	local far = {}
	local margin = 1 * spm
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Attachment") then
			local lp = root.CFrame:PointToObjectSpace(d.WorldPosition)
			if lp.X < lo.X - margin or lp.X > hi.X + margin or lp.Y < lo.Y - margin or lp.Y > hi.Y + margin
				or lp.Z < lo.Z - margin or lp.Z > hi.Z + margin then
				table.insert(far, d.Name)
			end
		end
	end
	check(#far == 0, "invites, lumières et sons placés sur le véhicule",
		#far > 0 and ("hors du véhicule : " .. table.concat(far, ", ", 1, math.min(#far, 8))) or "ok")
	local rp = root and root:FindFirstChild("RecoverPrompt")
	check(rp ~= nil and rp:FindFirstChildOfClass("ProximityPrompt") ~= nil, "invite « Remettre sur ses roues »", rp and "présente" or "absente")
	check(model:GetAttribute("Locked") ~= nil and model:GetAttribute("ParkAnchorDelay") ~= nil, "attributs Locked / ParkAnchorDelay",
		fmt("Locked %s, ParkAnchorDelay %s", tostring(model:GetAttribute("Locked")), tostring(model:GetAttribute("ParkAnchorDelay"))))
end

-- ------------------------------------------------------------------ scénarios serveur (Play)
local function playContext(name)
	if context ~= "server" then
		rec("skip", name, "scénario serveur : lancer en Play, execute_luau Server")
		return nil
	end
	local Players = game:GetService("Players")
	local player = opts.player or Players:GetPlayers()[1]
	local char = player and player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then
		rec("skip", name, "aucun joueur avec un personnage")
		return nil
	end
	local ok, Access = pcall(require, ReplicatedStorage.FiveMVehicles.VehicleAccess)
	if not ok then
		rec("fail", name, "VehicleAccess : " .. tostring(Access))
		return nil
	end
	return Access, player, char, hum
end

local function collisionParts()
	local out = {}
	local f = model:FindFirstChild("Collision")
	for _, d in ipairs(f and f:GetDescendants() or {}) do
		if d:IsA("BasePart") and d.CanCollide then
			table.insert(out, d)
		end
	end
	local hb = model:FindFirstChild("Hitbox")
	if hb and hb.CanCollide then
		table.insert(out, hb)
	end
	return out
end

local function overlapsVehicle(part, list)
	local op = OverlapParams.new()
	op.FilterType = Enum.RaycastFilterType.Include
	op.FilterDescendantsInstances = list
	op.CollisionGroup = "Default"
	return #workspace:GetPartsInPart(part, op) > 0
end

function groups.seats_play()
	local Access, player, char, hum = playContext("seats_play")
	if not Access then
		return
	end
	local list = collisionParts()
	local seatsFolder = model:FindFirstChild("Seats")
	for _, seat in ipairs(seatsFolder and seatsFolder:GetChildren() or {}) do
		if not (seat:IsA("Seat") or seat:IsA("VehicleSeat")) or (opts.seat and seat.Name ~= opts.seat) then
			continue
		end
		local a = root:FindFirstChild("Enter_" .. seat.Name)
		local prompt = a and a:FindFirstChildOfClass("ProximityPrompt")
		local door = seat:GetAttribute("Door")
		-- le joueur se tient à l'invite, comme s'il venait d'appuyer sur F
		if hum.SeatPart then
			Access.Exit(player)
			task.wait(0.3)
		end
		char:PivotTo(CFrame.new(a.WorldPosition + Vector3.new(0, 1, 0)))
		task.wait(0.2)
		local doorMax = 0
		local conn = door and model:GetAttributeChangedSignal("Door_" .. door):Connect(function()
			doorMax = math.max(doorMax, model:GetAttribute("Door_" .. door) or 0)
		end)
		local okEnter, why = Access.Enter(player, model, seat.Name, prompt)
		task.wait(0.4)
		local seated = seat.Occupant == hum
		local hrp = char:FindFirstChild("HumanoidRootPart")
		local facing = hrp and hrp.CFrame.LookVector:Dot(root.CFrame.LookVector) or 0
		-- tête sous le toit, jambes au-dessus du plancher : mesuré contre la carrosserie VISIBLE
		-- (la collision GTA est un volume plein : un passager y est toujours « dedans »)
		local visual = partsWhere(function(p)
			return p:GetAttribute("Kind") ~= "collision" and p.Transparency < 1 and not p:GetAttribute("LightRole")
		end)
		local savedQ = {}
		for _, p in ipairs(visual) do
			savedQ[p] = p.CanQuery
			p.CanQuery = true
		end
		local rpv = RaycastParams.new()
		rpv.FilterType = Enum.RaycastFilterType.Include
		rpv.FilterDescendantsInstances = visual
		local head = char:FindFirstChild("Head")
		local headRoom = math.huge
		if head then
			local up = workspace:Raycast(head.Position, Vector3.new(0, 10, 0), rpv)
			headRoom = up and (up.Position.Y - (head.Position.Y + head.Size.Y / 2)) or math.huge
		end
		local legRoom = math.huge
		for _, n in ipairs({ "Left Leg", "Right Leg", "LeftLowerLeg", "RightLowerLeg", "LeftFoot", "RightFoot" }) do
			local leg = char:FindFirstChild(n)
			if leg then
				-- point le plus bas de la pièce (jambes à l'horizontale une fois assis), rayon depuis son centre
				local bottom = math.huge
				for _, sx in ipairs({ -1, 1 }) do
					for _, sy in ipairs({ -1, 1 }) do
						for _, sz in ipairs({ -1, 1 }) do
							bottom = math.min(bottom, (leg.CFrame * CFrame.new(leg.Size * Vector3.new(sx, sy, sz) / 2)).Position.Y)
						end
					end
				end
				local down = workspace:Raycast(leg.Position, Vector3.new(0, -10, 0), rpv)
				if down then
					legRoom = math.min(legRoom, bottom - down.Position.Y)
				end
			end
		end
		for p, q in pairs(savedQ) do
			p.CanQuery = q
		end
		local hidden = prompt ~= nil and prompt.Enabled == false
		local group = hrp and hrp.CollisionGroup or "?"
		-- échelle conseillée pour que la tête passe avec 0,25 stud de marge : la hauteur utile au-dessus
		-- de l'assise grandit avec l'échelle du véhicule, pas l'avatar
		local advice = ""
		if head and headRoom < 0.25 and headRoom ~= math.huge then
			local span = (head.Position.Y + head.Size.Y / 2) - (seat.Position.Y + seat.Size.Y / 2)
			if span > 0.5 then
				local factor = (span + 0.25) / math.max(span + headRoom, 0.1)
				advice = fmt(" ; pour cet avatar : échelle ×%.2f (--studs-per-meter %.2f)", factor, spm * factor)
			end
		end
		check(headRoom > -0.05 and legRoom > -0.15, seat.Name .. " : tête sous le toit, jambes au-dessus du plancher",
			fmt("garde au toit %s, aux pieds %s (studs ; négatif = traverse)%s",
				headRoom == math.huge and "aucun toit trouvé" or fmt("%+.2f", headRoom),
				legRoom == math.huge and "?" or fmt("%+.2f", legRoom), advice), "warn")
		check(hidden, seat.Name .. " : invite masquée pendant l'occupation", prompt and tostring(prompt.Enabled) or "absente")
		check(group == Access.OccupantGroup, seat.Name .. " : occupant sans collision avec le véhicule", group)
		if seat.Name == "DriverSeat" then
			check(model:GetAttribute("Engine") == true, "moteur démarré à la montée du conducteur", tostring(model:GetAttribute("Engine")))
		end
		-- descendre
		local side = seat:GetAttribute("Side") or 1
		local okExit, where = Access.Exit(player)
		task.wait(0.6) -- le client se pose lui-même (PlaceAt), puis réplique
		local lp = hrp and root.CFrame:PointToObjectSpace(hrp.Position) or Vector3.zero
		local rp = RaycastParams.new()
		rp.FilterType = Enum.RaycastFilterType.Exclude
		rp.FilterDescendantsInstances = { char }
		local below = hrp and workspace:Raycast(hrp.Position, Vector3.new(0, -12, 0), rp)
		local feetGap = below and (hrp.Position.Y - below.Position.Y) or math.huge
		local inBody = false
		for _, p in ipairs(char:GetChildren()) do
			if p:IsA("BasePart") and overlapsVehicle(p, list) then
				inBody = true
			end
		end
		check(okExit and seat.Occupant == nil and hum.SeatPart == nil, seat.Name .. " : descendre", okExit and tostring(where) or "refusé")
		check(where == "door" and (side < 0) == (lp.X < 0), seat.Name .. " : posé côté portière",
			fmt("%s, x local %.1f (côté attendu %d)", tostring(where), lp.X, side))
		check(feetGap < 6 and not inBody and below and not below.Instance:IsDescendantOf(model), seat.Name .. " : au sol, hors du véhicule",
			fmt("%.2f stud au-dessus de %s, %s", feetGap, below and below.Instance.Name or "rien", inBody and "DANS la collision" or "libre"))
		if door then
			task.wait(Access.DoorCloseDelay + Access.DoorOpenTime + 0.3)
			check(doorMax >= 1 and (model:GetAttribute("Door_" .. door) or 0) == 0, seat.Name .. " : portière ouverte puis refermée",
				fmt("%s : max %.1f, fin %.1f", door, doorMax, model:GetAttribute("Door_" .. door) or 0))
		end
		if conn then
			conn:Disconnect()
		end
		task.wait(Access.OccupantGrace + 0.1)
		check(hrp and hrp.CollisionGroup ~= Access.OccupantGroup, seat.Name .. " : collision rendue après la descente", hrp and hrp.CollisionGroup or "?")
	end
end

function groups.lock_play()
	local Access, player, char = playContext("lock_play")
	if not Access then
		return
	end
	local a = root:FindFirstChild("Enter_DriverSeat")
	local prompt = a and a:FindFirstChildOfClass("ProximityPrompt")
	char:PivotTo(CFrame.new(a.WorldPosition + Vector3.new(0, 1, 0)))
	Access.SetLocked(model, true)
	task.wait(0.2)
	local ok, why = Access.Enter(player, model, "DriverSeat", prompt)
	check(prompt.Enabled == false and not ok and why == "locked", "verrouillé : invite masquée, montée refusée",
		fmt("invite %s, montée %s (%s)", tostring(prompt.Enabled), tostring(ok), tostring(why)))
	Access.SetLocked(model, false)
	task.wait(0.2)
	check(prompt.Enabled == true, "déverrouillé : invite de retour", tostring(prompt.Enabled))
end

function groups.park_play()
	local Access, player, char, hum = playContext("park_play")
	if not Access then
		return
	end
	local delay0 = model:GetAttribute("ParkAnchorDelay")
	model:SetAttribute("ParkAnchorDelay", 1.5)
	local a = root:FindFirstChild("Enter_DriverSeat")
	char:PivotTo(CFrame.new(a.WorldPosition + Vector3.new(0, 1, 0)))
	task.wait(0.2)
	Access.Enter(player, model, "DriverSeat", a:FindFirstChildOfClass("ProximityPrompt"))
	task.wait(0.5)
	check(root.Anchored == false and model:GetAttribute("Parked") == false, "conducteur à bord : véhicule libéré",
		fmt("Anchored %s, Parked %s", tostring(root.Anchored), tostring(model:GetAttribute("Parked"))))
	Access.Exit(player)
	local t0 = os.clock()
	while not root.Anchored and os.clock() - t0 < 6 do
		task.wait(0.1)
	end
	check(root.Anchored and model:GetAttribute("Parked") == true, "sans conducteur : ancré après le délai",
		fmt("ancré après %.1f s (délai 1,5 s)", os.clock() - t0))
	model:SetAttribute("ParkAnchorDelay", delay0)
end

function groups.flip_play()
	local Access, player, char = playContext("flip_play")
	if not Access then
		return
	end
	local home = model:GetPivot()
	local anchored0 = root.Anchored
	root.Anchored = true
	model:PivotTo(home * CFrame.new(0, 3 * spm, 0) * CFrame.Angles(0, 0, math.pi))
	local t0 = os.clock()
	while model:GetAttribute("Flipped") ~= true and os.clock() - t0 < 5 do
		task.wait(0.1)
	end
	local flippedAfter = os.clock() - t0
	local rprompt = root:FindFirstChild("RecoverPrompt") and root.RecoverPrompt:FindFirstChildOfClass("ProximityPrompt")
	local enterP = root:FindFirstChild("Enter_DriverSeat") and root.Enter_DriverSeat:FindFirstChildOfClass("ProximityPrompt")
	task.wait(0.2)
	check(model:GetAttribute("Flipped") == true and flippedAfter >= 1.8, "retourné détecté après ~2 s", fmt("%.1f s", flippedAfter))
	check(rprompt and rprompt.Enabled and enterP and not enterP.Enabled, "invite de remise affichée, montée masquée",
		fmt("remise %s, montée %s", tostring(rprompt and rprompt.Enabled), tostring(enterP and enterP.Enabled)))
	char:PivotTo(CFrame.new(root.Position + root.CFrame.RightVector * 6 + Vector3.new(0, 4, 0)))
	task.wait(0.2)
	local ok, why = Access.Recover(player, model)
	task.wait(0.3)
	local up = root.CFrame.UpVector.Y
	-- au sol : bas des roues sur la surface dessous
	local lowest = math.huge
	for _, w in pairs(CONFIG.Wheels or {}) do
		lowest = math.min(lowest, (w.Position[2] - (w.Radius or 0.35)) * spm)
	end
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { model, char }
	local hit = workspace:Raycast(root.Position + Vector3.new(0, 2, 0), Vector3.new(0, -60, 0), rp)
	local gap = hit and (root.Position.Y + lowest - hit.Position.Y) or math.huge
	check(ok and up > 0.99 and math.abs(gap) < 0.3, "remis sur ses roues",
		ok and fmt("UpVector.Y %.3f, roues à %+.2f stud du sol", up, gap) or ("refusé : " .. tostring(why)))
	-- second retournement aussitôt : la remise doit être refusée (délai RecoverCooldown)
	model:PivotTo(model:GetPivot() * CFrame.Angles(0, 0, math.pi))
	local again, why2 = Access.Recover(player, model)
	check(not again and why2 == "cooldown", "délai entre deux remises", fmt("%s (%s)", tostring(again), tostring(why2)))
	model:PivotTo(home)
	root.Anchored = anchored0
	model:SetAttribute("Flipped", false)
end

function groups.void_play()
	local Access = playContext("void_play")
	if not Access then
		return
	end
	local home = model:GetPivot()
	local anchored0 = root.Anchored
	local count0 = 0
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			count0 += 1
		end
	end
	local n0 = model:GetAttribute("VoidRecoveries") or 0
	-- position sûre = position actuelle (au sol) : on laisse VehicleAccess l'enregistrer
	root.Anchored = true
	task.wait(0.6)
	root.Anchored = false
	local floor = workspace.FallenPartsDestroyHeight + (model:GetAttribute("VoidMargin") or 60)
	model:PivotTo(home - home.Position + Vector3.new(home.X, floor - 20, home.Z))
	local t0 = os.clock()
	while (model:GetAttribute("VoidRecoveries") or 0) == n0 and os.clock() - t0 < 3 do
		task.wait()
	end
	local after = os.clock() - t0
	task.wait(0.3)
	local count1 = 0
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			count1 += 1
		end
	end
	local back = (model:GetPivot().Position - home.Position).Magnitude
	check((model:GetAttribute("VoidRecoveries") or 0) == n0 + 1 and back < 3 and root.CFrame.UpVector.Y > 0.95,
		"tombé dans le vide : remis à sa position sûre", fmt("%.2f s, %.2f studs de la position sûre, UpVector.Y %.2f", after, back, root.CFrame.UpVector.Y))
	check(count1 == count0 and model.Parent ~= nil, "aucune pièce détruite", fmt("%d / %d pièces", count1, count0))
	model:PivotTo(home)
	root.AssemblyLinearVelocity, root.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
	root.Anchored = anchored0
end

-- Corps de l'occupant adapté à l'habitacle (VehicleSeatFit) : joueur local assis dans ce véhicule
function groups.fit_play()
	if context ~= "client" then
		rec("skip", "fit_play", "scénario client : lancer en Play, execute_luau Client, joueur assis")
		return
	end
	local okF, Fit = pcall(require, ReplicatedStorage.FiveMVehicles:FindFirstChild("VehicleSeatFit"))
	if not okF or not Fit then
		rec("fail", "fit_play", "VehicleSeatFit absent du runtime")
		return
	end
	local g = Fit.Grid(model)
	if not g then
		local c = CONFIG.Cabin
		rec(c and c.Open and "warn" or "skip", "fit_play", c and c.Open and "habitacle ouvert : pas d'adaptation" or "pas de grille d'habitacle (conversion sans --seat-fit)")
		return
	end
	local char = game:GetService("Players").LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.SeatPart
	if not seat or not seat:IsDescendantOf(model) then
		rec("skip", "fit_play", "le joueur local n'est pas assis dans ce véhicule")
		return
	end
	local t0 = os.clock()
	while (char:GetAttribute("F2RFitResult") == nil or char:GetAttribute("F2RFitResult") == "running") and os.clock() - t0 < 10 do
		task.wait(0.1)
	end
	local res = tostring(char:GetAttribute("F2RFitResult"))
	local pts = Fit.Sample(char, root, g.spm)
	local bad = Fit.CountBad(g, pts)
	check(bad == 0, "corps dans l'habitacle (" .. seat.Name .. ")", fmt("%d point(s) hors habitacle sur %d ; résultat %s", bad, #pts, res))
	-- posé : 6 cm plus bas, le corps entrerait dans le coussin ou le plancher (sinon il flotte)
	local below = 0
	for _, p in ipairs(pts) do
		if Fit.IsBad(g, p - Vector3.new(0, 0.06, 0)) then
			below += 1
		end
	end
	check(below > 0, "posé sur le siège (pas en l'air)", fmt("6 cm plus bas : %d point(s) dans le coussin / le plancher", below))
	local sc = {}
	for _, n in ipairs({ "BodyHeightScale", "BodyWidthScale", "BodyDepthScale", "HeadScale" }) do
		local v = hum:FindFirstChild(n)
		if v then
			table.insert(sc, fmt("%s %.2f", n, v.Value))
		end
	end
	check(true, "échelles appliquées", table.concat(sc, ", ") .. " ; F2RFit = " .. tostring(hum:GetAttribute("F2RFit")))
end

function groups.drive_play()
	if context ~= "client" then
		rec("skip", "drive_play", "scénario client : lancer en Play, execute_luau Client, joueur au volant")
		return
	end
	local okD, Drive = pcall(require, ReplicatedStorage.FiveMVehicles.VehicleDrive)
	if not okD then
		rec("fail", "drive_play", "VehicleDrive : " .. tostring(Drive))
		return
	end
	local a = Drive.Get()
	if not a or a.car ~= model then
		rec("skip", "drive_play", "le joueur local ne conduit pas ce véhicule")
		return
	end
	check(true, "moteur de conduite actif", "pas : " .. tostring(Drive.StepMode))
	local function sample()
		local o = a.out
		return o and o.speed or 0, o and o.gear or 0, o and o.rpm or 0, o and o.clutch or 1
	end
	Drive.SetOverride({ Throttle = 1, Brake = 0, Steer = 0, Handbrake = false })
	local t0, maxGear, rpmErr, n = os.clock(), 0, 0, 0
	local t100
	while os.clock() - t0 < 3 do
		task.wait()
		local v, g, rpm, clutch = sample()
		maxGear = math.max(maxGear, g)
		if not t100 and v * 3.6 >= 100 then
			t100 = os.clock() - t0
		end
		if g >= 1 and clutch >= 1 and v > 3 then
			local ratio = a.sim.P.ratios[math.clamp(g, 1, a.sim.P.nGears)]
			local expect = v / (a.sim.P.flatVel / ratio)
			rpmErr = math.max(rpmErr, math.abs(rpm - math.max(expect, 0.2)))
			n += 1
		end
	end
	local v3 = sample()
	check(v3 > 5, "accélère (3 s plein gaz)", fmt("%.1f km/h, rapport max %d%s", v3 * 3.6, maxGear,
		t100 and fmt(", 0-100 en %.1f s", t100) or ""))
	check(n > 0 and rpmErr < 0.25, "régime cohérent avec la vitesse et le rapport",
		fmt("écart max %.2f (régime normalisé) sur %d échantillons", rpmErr, n))
	local tel = model:GetAttribute("Gear")
	check(tel ~= nil and tel >= 1, "rapport publié (attribut Gear)", tostring(tel))
	Drive.SetOverride({ Throttle = 0, Brake = 1, Steer = 0, Handbrake = false })
	local tb = os.clock()
	local stopT
	while os.clock() - tb < 8 do
		task.wait()
		local v = sample()
		if math.abs(v) < 0.3 then
			stopT = os.clock() - tb
			break
		end
	end
	Drive.SetOverride({ Throttle = 0, Brake = 0, Steer = 0 })
	task.wait(0.3)
	Drive.SetOverride(nil)
	check(stopT ~= nil, "s'arrête au freinage", stopT and fmt("arrêt en %.2f s depuis %.1f km/h", stopT, v3 * 3.6) or "pas arrêté en 8 s")
	local up = root.CFrame.UpVector.Y
	local grounded = 0
	local out = a.out
	for i in ipairs(a.sim.P.wheels) do
		if out and out.wheels[i] and out.wheels[i].Fz > 0 then
			grounded += 1
		end
	end
	check(up > 0.95 and grounded >= 3, "reste droit et sur ses roues", fmt("UpVector.Y %.3f, %d roue(s) au sol", up, grounded))
end

function groups.sounds()
	local folder = model:FindFirstChild("Sounds", true)
	if not folder then
		rec("fail", "Sounds", "attachment Sounds absent")
		return
	end
	local empty, total, list = 0, 0, {}
	for _, s in ipairs(folder:GetChildren()) do
		if s:IsA("Sound") then
			total += 1
			if s.SoundId == "" then
				empty += 1
				table.insert(list, s.Name)
			end
		end
	end
	check(total > 0 and empty == 0, "SoundId renseignés", fmt("%d/%d%s", total - empty, total, empty > 0 and (" ; vides : " .. table.concat(list, ", ")) or ""))
	local loops = (CONFIG.Audio and CONFIG.Audio.EngineLoops) or {}
	local missingLoops = 0
	for _, l in ipairs(loops) do
		if not folder:FindFirstChild(l.Name) then
			missingLoops += 1
		end
	end
	check(#loops > 0 and missingLoops == 0, "boucles moteur présentes", fmt("%d boucle(s), %d absente(s)", #loops, missingLoops))
	if context == "client" then
		local sounds = {}
		for _, s in ipairs(folder:GetChildren()) do
			if s:IsA("Sound") and s.SoundId ~= "" then
				table.insert(sounds, s)
			end
		end
		local failed = {}
		pcall(function()
			ContentProvider:PreloadAsync(sounds, function(id, status)
				if status ~= Enum.AssetFetchStatus.Success then
					table.insert(failed, id .. "=" .. tostring(status))
				end
			end)
		end)
		local notLoaded = 0
		for _, s in ipairs(sounds) do
			if not s.IsLoaded or s.TimeLength <= 0 then
				notLoaded += 1
			end
		end
		check(#failed == 0 and notLoaded == 0, "sons chargés (client)",
			fmt("%d/%d chargés%s", #sounds - notLoaded, #sounds, #failed > 0 and (" ; échecs : " .. table.concat(failed, ", ")) or ""))
	end
end

function groups.custom()
	local okC, Custom = pcall(freshRequire, ReplicatedStorage.FiveMVehicles.VehicleCustomization)
	if not okC then
		rec("fail", "require VehicleCustomization", tostring(Custom))
		return
	end
	local snapshot = Custom.Serialize(model)
	local opt = Custom.GetOptions(model)
	-- couleur
	local red = Color3.fromRGB(200, 10, 10)
	local paint = partsWhere(function(p)
		return p:GetAttribute("PaintLayer") == "Primary"
	end)
	local ok = pcall(Custom.SetColor, model, "Primary", red)
	local colored = 0
	for _, p in ipairs(paint) do
		if p.Color == red then
			colored += 1
		end
	end
	check(ok and #paint > 0 and colored == #paint and model:GetAttribute("Color_Primary") == red, "SetColor",
		fmt("%d/%d pièces Primary recolorées", colored, #paint))
	-- mod
	local slot, info = next(CONFIG.Mods or {})
	if slot then
		local okM, err = pcall(Custom.SetMod, model, slot, 1)
		local shown = partsWhere(function(p)
			return p:GetAttribute("ModSlot") == slot and p:GetAttribute("ModIndex") == 1
		end)
		local visible = 0
		for _, p in ipairs(shown) do
			if p.Transparency < 1 then
				visible += 1
			end
		end
		check(okM and model:GetAttribute("Mod_" .. slot) == 1 and (#shown == 0 or visible == #shown), "SetMod",
			okM and fmt("%s = 1 : %d/%d pièce(s) visibles", slot, visible, #shown) or tostring(err))
	else
		rec("skip", "SetMod", "aucun mod carcols dans ce véhicule")
	end
	-- livrée
	if (opt.LiveryCount or 0) > 0 then
		local okL, err = pcall(Custom.SetLivery, model, 1)
		check(okL and model:GetAttribute("Livery") == 1, "SetLivery", okL and "livrée 1" or tostring(err))
	else
		rec("skip", "SetLivery", "aucune livrée dans ce véhicule")
	end
	-- extra
	local extra = (CONFIG.Extras or {})[1]
	if extra then
		local okE, err = pcall(Custom.SetExtra, model, extra, false)
		local parts = partsWhere(function(p)
			return p:GetAttribute("Extra") == extra
		end)
		local hidden = 0
		for _, p in ipairs(parts) do
			if p.Transparency >= 1 then
				hidden += 1
			end
		end
		check(okE and hidden == #parts, "SetExtra", okE and fmt("extra %s masqué : %d/%d pièces", tostring(extra), hidden, #parts) or tostring(err))
	else
		rec("skip", "SetExtra", "aucun extra dans ce véhicule")
	end
	-- néons
	local pink = Color3.fromRGB(255, 0, 200)
	local okN = pcall(Custom.SetNeon, model, true, pink)
	local neonParts, lit = 0, 0
	for _, p in ipairs((model:FindFirstChild("Neons") or Instance.new("Folder")):GetChildren()) do
		if p:IsA("BasePart") then
			neonParts += 1
			if p.Transparency == 0 and p.Color == pink then
				lit += 1
			end
		end
	end
	check(okN and neonParts > 0 and lit == neonParts, "SetNeon", fmt("%d/%d bandes allumées", lit, neonParts))
	-- plaque
	local okP = pcall(Custom.SetPlate, model, "F2RTEST")
	local labels, good = 0, 0
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("TextLabel") and d.Name == "PlateText" then
			labels += 1
			if d.Text == "F2RTEST" then
				good += 1
			end
		end
	end
	check(okP and labels > 0 and good == labels, "SetPlate", fmt("%d/%d plaque(s) à jour", good, labels))
	-- sauvegarde / restauration
	local changed = Custom.Serialize(model)
	local okA, errA = pcall(Custom.Apply, model, snapshot)
	local after = Custom.Serialize(model)
	local diffs = {}
	local function same(a, b)
		if type(a) == "table" and type(b) == "table" then
			for i = 1, 4 do
				if typeof(a[i]) == "number" and typeof(b[i]) == "number" then
					if math.abs(a[i] - b[i]) > 1e-3 then
						return false
					end
				elseif a[i] ~= b[i] then
					return false
				end
			end
			return true
		end
		return a == b
	end
	for k, v in pairs(snapshot) do
		if not same(after[k], v) then
			table.insert(diffs, k)
		end
	end
	for k in pairs(after) do
		if snapshot[k] == nil then
			table.insert(diffs, k .. "(ajouté)")
		end
	end
	-- néons : doivent revenir à l'état de la sauvegarde (allumés seulement si elle dit Neon = true)
	local litAfter, neonTotal = 0, 0
	for _, p in ipairs((model:FindFirstChild("Neons") or Instance.new("Folder")):GetChildren()) do
		if p:IsA("BasePart") then
			neonTotal += 1
			if p.Transparency < 1 then
				litAfter += 1
			end
		end
	end
	local neonOk = (snapshot.Neon == true and litAfter == neonTotal) or (snapshot.Neon ~= true and litAfter == 0)
	local plateBack = true
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("TextLabel") and d.Name == "PlateText" and d.Text ~= (snapshot.PlateText or d.Text) then
			plateBack = false
		end
	end
	local colorBack = true
	for _, p in ipairs(paint) do
		if p.Color == red then
			colorBack = false
		end
	end
	check(okA and #diffs == 0 and neonOk and plateBack and colorBack, "Serialize / Apply restaure l'état",
		okA and fmt("%d clé(s) sauvées, différences : %s ; néons allumés après restauration : %d (sauvegarde : %s) ; plaque %s ; peinture %s",
			(function()
				local n = 0
				for _ in pairs(changed) do
					n += 1
				end
				return n
			end)(),
			#diffs > 0 and table.concat(diffs, ", ") or "aucune", litAfter, tostring(snapshot.Neon),
			plateBack and "restaurée" or "NON restaurée", colorBack and "restaurée" or "NON restaurée") or tostring(errA))
end

-- les groupes suivants observent le runtime client (RenderStepped) : en Play, contexte Client
local autoChecked = false
local function runtimeOrSkip(name)
	if context ~= "client" then
		rec("skip", name, "à lancer côté client pendant un Play (le runtime de rendu n'y tourne pas en " .. context .. ")")
		return nil
	end
	local okR, Runtime = pcall(require, ReplicatedStorage.FiveMVehicles.VehicleRuntime)
	if not okR then
		rec("fail", name, "require VehicleRuntime : " .. tostring(Runtime))
		return nil
	end
	-- le script client doit avoir attaché le rendu tout seul (sans l'aide de Verify)
	local auto = Runtime.Get(model)
	if not autoChecked then
		autoChecked = true
		local t0 = os.clock()
		while not auto and os.clock() - t0 < 5 do
			task.wait(0.1)
			auto = Runtime.Get(model)
		end
		check(auto ~= nil, "rendu attaché par FiveMVehiclesClient",
			auto and "ok" or "non attaché après 5 s : lumières, portes et sons inertes en jeu")
	end
	local r = auto or Runtime.Attach(model)
	if not r then
		rec("fail", name, "Runtime.Attach a échoué")
		return nil
	end
	return Runtime, r
end

local function resetAttributes()
	model:SetAttribute("Headlights", 0)
	model:SetAttribute("Brake", false)
	model:SetAttribute("Reverse", false)
	model:SetAttribute("Indicator", "Off")
	model:SetAttribute("Siren", false)
	model:SetAttribute("Engine", false)
	model:SetAttribute("Horn", false)
	model:SetAttribute("Steer", 0)
end

function groups.joints()
	local Runtime = runtimeOrSkip("joints")
	if not Runtime then
		return
	end
	resetAttributes()
	for bone in pairs(CONFIG.Hinges or {}) do
		model:SetAttribute("Door_" .. bone, 0)
	end
	task.wait(0.7) -- le runtime ouvre / ferme à 1,6 unité par seconde
	-- portes, capot, coffre
	for bone, hinge in pairs(CONFIG.Hinges or {}) do
		local pv = pivotOf(bone)
		if not pv then
			rec("fail", bone, "pivot absent")
		else
			local rest = localCF(pv)
			local want = hinge.OpenAngle or 60
			model:SetAttribute("Door_" .. bone, 1)
			local ang = 0
			local ok, frames, dt = waitFor(function()
				ang = angleBetween(rest, localCF(pv))
				return math.abs(ang - folded(want)) < 2
			end, 3)
			model:SetAttribute("Door_" .. bone, 0)
			if not ok and frames < 10 then
				rec("warn", bone .. " s'ouvre (Door_" .. bone .. " = 1)", fmt("rendu figé : %d image(s) en %.1f s (fenêtre Studio inactive ?), %.1f° mesurés", frames, dt, ang))
			else
				check(ok, bone .. " s'ouvre (Door_" .. bone .. " = 1)", fmt("%.1f° mesurés, %.0f° attendus (%.2f s, %d images)", ang, want, dt, frames))
			end
		end
	end
	task.wait(0.7)
	-- roues + volant : télémétrie de test (rotation et braquage)
	local rest = {}
	for bone in pairs(CONFIG.Wheels or {}) do
		local pv = pivotOf(bone)
		if pv then
			rest[bone] = localCF(pv)
		end
	end
	local sw = CONFIG.SteeringWheel
	local swPv = sw and pivotOf(sw.Bone)
	local swRest = swPv and localCF(swPv)
	local spin = {}
	for bone in pairs(CONFIG.Wheels or {}) do
		spin[bone] = 4
	end
	local followRest = {}
	for bone in pairs(CONFIG.WheelFollowers or {}) do
		local pv = pivotOf(bone)
		if pv then
			followRest[bone] = localCF(pv)
		end
	end
	local t0 = os.clock()
	while os.clock() - t0 < 0.4 do
		Runtime.SetTelemetry(model, { WheelSpin = spin, Steer = 1, Speed = 0 })
		task.wait()
	end
	for bone, w in pairs(CONFIG.Wheels or {}) do
		local pv = pivotOf(bone)
		if pv and rest[bone] then
			local ang = angleBetween(rest[bone], localCF(pv))
			check(ang > 5, bone .. " tourne" .. (w.Steer and " et braque" or ""), fmt("%.1f° de rotation", ang))
		end
	end
	-- étriers / suspension : suivent la roue (braquage) sans tourner avec elle
	for bone, f in pairs(CONFIG.WheelFollowers or {}) do
		local pv = pivotOf(bone)
		if not (pv and followRest[bone]) then
			check(false, bone .. " suit " .. f.Wheel, "pas de pivot (pièce soudée à la carrosserie ?)")
		else
			local rel = followRest[bone]:ToObjectSpace(localCF(pv))
			local rx, ry, rz = rel:ToEulerAnglesYXZ() -- renvoie X, Y, Z (ordre d'application Y, X, Z)
			local spinDeg = math.deg(math.max(math.abs(rx), math.abs(rz)))
			local steerDeg = math.deg(math.abs(ry))
			local w = CONFIG.Wheels and CONFIG.Wheels[f.Wheel]
			if f.Steer and w and w.Steer then
				check(spinDeg < 2 and steerDeg > 5, bone .. " braque avec " .. f.Wheel .. " sans tourner",
					fmt("braquage %.1f°, rotation parasite %.1f°", steerDeg, spinDeg))
			else
				check(spinDeg < 2 and steerDeg < 2, bone .. " ne tourne pas avec " .. f.Wheel,
					fmt("braquage %.1f°, rotation parasite %.1f°", steerDeg, spinDeg))
			end
		end
	end
	if swPv then
		local ang = angleBetween(swRest, localCF(swPv))
		local want = folded(sw.MaxAngle or 270)
		check(math.abs(ang - want) < 3, "volant tourne (Steer = 1)",
			fmt("%.1f° mesurés, %d° attendus (soit %.0f° modulo un tour)", ang, sw.MaxAngle or 270, want))
	else
		rec("warn", "volant", "pas de pivot de volant")
	end
	Runtime.SetTelemetry(model, nil)
end

function groups.lights()
	local Runtime, r = runtimeOrSkip("lights")
	if not Runtime then
		return
	end
	local byRole = {}
	for _, p in ipairs(partsWhere(function(p)
		return p:GetAttribute("LightRole") ~= nil
	end)) do
		local role = p:GetAttribute("LightRole")
		byRole[role] = byRole[role] or {}
		table.insert(byRole[role], p)
	end
	-- lumières (SpotLight / PointLight) des attachments Light_<rôle> créés par le Setup
	local lightsByRole = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Light") and d.Parent and d.Parent:IsA("Attachment") then
			local role = d.Parent:GetAttribute("LightRole")
			if role then
				lightsByRole[role] = lightsByRole[role] or {}
				table.insert(lightsByRole[role], d)
			end
		end
	end
	local function lightOn(role)
		for _, l in ipairs(lightsByRole[role] or {}) do
			if l.Enabled then
				return true
			end
		end
		return false
	end
	local function neonCount(role)
		local n = 0
		for _, p in ipairs(byRole[role] or {}) do
			if p.Material == Enum.Material.Neon then
				n += 1
			end
		end
		return n
	end
	-- équipement (VehicleLights.Rig) : chaque cône éclaire vers l'extérieur du véhicule (sinon il éclaire la
	-- carrosserie ou l'habitacle à travers les pièces), et la plaque arrière a sa lampe
	do
		local root = model.PrimaryPart
		local inward, spots, plateLamp, rearPlate = {}, 0, false, false
		for role, list in pairs(lightsByRole) do
			for _, l in ipairs(list) do
				if l:IsA("SpotLight") and role ~= "plate" and not string.find(role, "^siren") then
					spots += 1
					local a = l.Parent
					local dir = a.WorldCFrame:VectorToWorldSpace(Vector3.FromNormalId(l.Face))
					if dir:Dot(a.WorldPosition - root.Position) <= 0 then
						table.insert(inward, role)
					end
				elseif role == "plate" then
					plateLamp = true
				end
			end
		end
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("SurfaceGui") and d.Name == "Plate" and d.Parent:IsA("BasePart") then
				local n = d.Parent.CFrame:VectorToWorldSpace(Vector3.FromNormalId(d.Face))
				if n:Dot(root.CFrame.LookVector) < -0.5 then
					rearPlate = true
				end
			end
		end
		check(spots > 0 and #inward == 0, "cônes tournés vers l'extérieur",
			#inward > 0 and ("vers l'intérieur : " .. table.concat(inward, ", ")) or fmt("%d SpotLight", spots))
		if rearPlate then
			check(plateLamp, "lampe de plaque arrière", plateLamp and "ok" or "absente (VehicleLights.Rig)")
		end
	end
	resetAttributes()
	task.wait(0.4)
	local litAtRest = {}
	for role in pairs(byRole) do
		if neonCount(role) > 0 then
			table.insert(litAtRest, role)
		end
	end
	check(#litAtRest == 0, "tout éteint au repos", #litAtRest > 0 and ("allumés : " .. table.concat(litAtRest, ", ")) or "ok")
	local hasBrakeParts = byRole.brakelight_l or byRole.brakelight_r or byRole.brakelight_m
	local scenarios = {
		{ "Headlights = 1", { Headlights = 1 }, { "headlight_l", "headlight_r", "taillight_l", "taillight_r" } },
		{ "Headlights = 2", { Headlights = 2 }, { "headlight_l", "headlight_r" } },
		{ "Brake", { Brake = true }, hasBrakeParts and { "brakelight_l", "brakelight_r", "brakelight_m" } or { "taillight_l", "taillight_r" } },
		{ "Reverse", { Reverse = true }, { "reversinglight_l", "reversinglight_r" } },
		{ "Indicator = Left", { Indicator = "Left" }, { "indicator_lf", "indicator_lr" }, true },
		{ "Indicator = Right", { Indicator = "Right" }, { "indicator_rf", "indicator_rr" }, true },
		{ "Indicator = Hazard", { Indicator = "Hazard" }, { "indicator_lf", "indicator_lr", "indicator_rf", "indicator_rr" }, true },
		{ "Engine (feux de jour)", { Engine = true }, { "always_on" } },
	}
	if model:GetAttribute("HasSiren") then
		local sirenRoles = {}
		for _, p in ipairs(partsWhere(function(p)
			return p:GetAttribute("Siren") ~= nil
		end)) do
			local key = "siren:" .. tostring(p:GetAttribute("Siren"))
			if not byRole[key] then
				byRole[key] = {}
				table.insert(sirenRoles, key)
			end
			table.insert(byRole[key], p)
		end
		for role in pairs(lightsByRole) do
			if string.match(role, "^siren%d+$") and not table.find(sirenRoles, role) then
				table.insert(sirenRoles, role)
			end
		end
		table.sort(sirenRoles)
		-- sans gyrophare, la sirène fait alterner les phares (wig-wag carcols HeadLightLeft/Right)
		local sc = CONFIG.Sirens or {}
		if #sirenRoles == 0 and ((sc.HeadLightLeft or 0) ~= 0 or (sc.HeadLightRight or 0) ~= 0) then
			sirenRoles = { "headlight_l", "headlight_r" }
		end
		table.insert(scenarios, { "Siren", { Siren = true }, sirenRoles, true })
	end
	local covered = {}
	for _, sc in ipairs(scenarios) do
		local label, attrs, roles, blinks = sc[1], sc[2], sc[3], sc[4]
		resetAttributes()
		task.wait(0.2)
		for k, v in pairs(attrs) do
			model:SetAttribute(k, v)
		end
		local seen = {}
		local frames = 0
		local conn = RunService.RenderStepped:Connect(function()
			frames += 1
		end)
		local t0 = os.clock()
		repeat
			task.wait()
			local all = true
			for _, role in ipairs(roles) do
				if byRole[role] then
					if neonCount(role) == #byRole[role] then
						seen[role] = true
					elseif not seen[role] then
						all = false
					end
				elseif lightsByRole[role] then
					-- rôle sans pièce lumineuse : sa lumière doit s'allumer
					if lightOn(role) then
						seen[role] = true
					elseif not seen[role] then
						all = false
					end
				end
			end
		until (all and os.clock() - t0 > 0.05) or os.clock() - t0 > (blinks and 1.6 or 1.0)
		conn:Disconnect()
		local missing, absent, lightOnly = {}, {}, {}
		for _, role in ipairs(roles) do
			covered[role] = true
			if not byRole[role] and not lightsByRole[role] then
				table.insert(absent, role)
			elseif not seen[role] then
				table.insert(missing, role)
			elseif not byRole[role] then
				table.insert(lightOnly, role)
			end
		end
		-- une optique allumée doit être du Neon SANS texture : la texture GTA sombre éteint la lueur
		local textured = {}
		for _, role in ipairs(roles) do
			for _, p in ipairs(byRole[role] or {}) do
				if p:IsA("MeshPart") and p.Material == Enum.Material.Neon and p.TextureID ~= "" then
					table.insert(textured, p.Name)
				end
			end
		end
		if #textured > 0 then
			check(false, label .. " → optique sans texture", "Neon texturé (lueur éteinte) : " .. table.concat(textured, ", "))
		end
		local present = #roles - #absent
		if #missing > 0 and frames < 5 then
			rec("warn", label, fmt("rendu figé (%d image(s)) : non mesurable", frames))
		elseif present == 0 then
			rec("warn", label, "ni pièce ni lumière pour " .. (#roles > 0 and table.concat(roles, ", ") or "ce rôle"))
		else
			check(#missing == 0, label .. " → Neon / lumière", fmt("%d rôle(s) vérifiés%s%s%s", present - #missing,
				#missing > 0 and (" ; restés éteints : " .. table.concat(missing, ", ")) or "",
				#lightOnly > 0 and (" ; lumière seule (sans pièce) : " .. table.concat(lightOnly, ", ")) or "",
				#absent > 0 and (" ; absents : " .. table.concat(absent, ", ")) or ""))
		end
	end
	local orphans = {}
	for role in pairs(byRole) do
		if not covered[role] and not string.find(role, "^siren:") then
			table.insert(orphans, role)
		end
	end
	if #orphans > 0 then
		rec("warn", "rôles non testés", table.concat(orphans, ", "))
	end
	resetAttributes()
end

function groups.audio()
	local Runtime, r = runtimeOrSkip("audio")
	if not Runtime then
		return
	end
	resetAttributes()
	model:SetAttribute("Engine", true)
	local playing = {}
	local t0 = os.clock()
	repeat
		task.wait(0.1)
		for _, s in ipairs((model:FindFirstChild("Sounds", true) or Instance.new("Folder")):GetChildren()) do
			if s:IsA("Sound") and s.IsPlaying and s.Volume > 0.01 then
				playing[s.Name] = true
			end
		end
	until os.clock() - t0 > 1.5
	local names = {}
	for n in pairs(playing) do
		table.insert(names, n)
	end
	table.sort(names)
	check(#names > 0, "moteur audible (Engine = true)", #names > 0 and table.concat(names, ", ") or "aucun son ne joue")
	model:SetAttribute("Engine", false)
end

-- ------------------------------------------------------------------ exécution
for _, g in ipairs(opts.checks or DEFAULTS[context]) do
	currentGroup = g
	local fn = groups[g]
	if not fn then
		rec("fail", g, "groupe inconnu")
	else
		local ok, err = pcall(fn)
		if not ok then
			rec("fail", g, "erreur : " .. tostring(err))
		end
	end
end

return HttpService:JSONEncode({
	vehicle = model:GetFullName(),
	context = context,
	pass = counts.pass,
	fail = counts.fail,
	warn = counts.warn,
	skip = counts.skip,
	results = results,
})
end

return run
