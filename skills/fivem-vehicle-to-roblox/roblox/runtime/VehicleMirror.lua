--!nonstrict
--[[
	VehicleMirror (ModuleScript, ReplicatedStorage.FiveMVehicles) — rétroviseur virtuel façon Assetto Corsa : un
	rectangle en haut au centre de l'écran qui montre ce qu'il y a derrière le véhicule de l'occupant local.

		local Mirror = require(ReplicatedStorage.FiveMVehicles.VehicleMirror)
		Mirror.Start()               -- FiveMVehiclesClient l'appelle une fois
		Mirror.SetEnabled(false)     -- ou Mirror.Toggle() ; touche B (bouton « Rétro » sur mobile)
		Mirror.Changed:Connect(function(enabled) end)

	Roblox ne sait pas afficher le monde une deuxième fois : le rétro est un ViewportFrame qui contient des COPIES.
	- les véhicules derrière (tag FiveMVehicle, à moins de Range studs) : leurs plus grosses pièces visibles
	  (MaxPartsPerVehicle), déplacées à chaque image (WorldModel:BulkMoveTo) ;
	- le décor : les pièces du Workspace dans une boîte derrière le véhicule (DecorRange × DecorWidth), copiées une fois
	  et gardées tant qu'elles restent dans la zone ; MaxDecorParts au plus, NewPerRefresh nouvelles par rafraîchissement
	  (pas de pic) ;
	- le terrain ne se copie pas : il est relevé derrière le véhicule sur une grille (TerrainCell studs) et rendu en
	  dalles à sa hauteur et à la couleur de sa matière (route, herbe…) ; un sol de la couleur de ce qu'il y a sous le
	  véhicule sert de fond ;
	- ciel, lumière ambiante et soleil repris de Lighting.
	Effet miroir (Mirrored) : le monde copié ET la caméra du rétro sont reflétés (x → −x), ce qui inverse gauche et
	droite comme un vrai rétroviseur ; chaque objet garde sa forme (une voiture n'est pas retournée).
	Coût mesuré : voir references/roblox-integration.md (« Rétroviseur »).
]]
local Players = game:GetService("Players")
local ContextActionService = game:GetService("ContextActionService")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local Mirror = {}
Mirror.Tag = "FiveMVehicle"
Mirror.Enabled = true
Mirror.Mirrored = true
Mirror.Key = Enum.KeyCode.B
Mirror.Size = UDim2.fromScale(0.27, 0.12) -- largeur relative à l'écran ; la hauteur suit Aspect
Mirror.Aspect = 4 -- largeur / hauteur (rétro d'Assetto Corsa ≈ 4:1)
Mirror.Top = 6 -- px sous la barre du haut
Mirror.Fov = 28 -- degrés (vertical)
Mirror.Range = 400 -- studs : véhicules montrés
Mirror.MaxPartsPerVehicle = 70
Mirror.DecorRange = 260 -- studs derrière le véhicule
Mirror.DecorWidth = 140 -- studs de large
Mirror.DecorHeight = 90
Mirror.MaxDecorParts = 1200
Mirror.NewPerRefresh = 120
Mirror.MinPartSize = 1.5 -- studs : plus petit côté le plus long d'une pièce de décor copiée
Mirror.Refresh = 0.4 -- s entre deux relevés du décor
Mirror.TerrainCell = 10 -- studs : maille du relevé du terrain (0 = pas de relevé)

local changed = Instance.new("BindableEvent")
Mirror.Changed = changed.Event

local player = Players.LocalPlayer
local gui, frame, vp, world, cam, ground
local decor = {} -- source -> clone
local decorCount = 0
local proxies = {} -- model -> { parts = { {src, clone} } }
local lastRefresh = 0
local tiles = {} -- dalles du relevé de terrain (réutilisées)
local stats = { decor = 0, vehicles = 0, parts = 0, ms = 0 }

local function occupied()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.SeatPart
	local model = seat and seat.Parent and seat.Parent.Name == "Seats" and seat.Parent.Parent
	if model and CollectionService:HasTag(model, Mirror.Tag) and model.PrimaryPart then
		return model
	end
	return nil
end

-- reflet x → −x (repère monde) : position et orientation (M·R·M reste une rotation)
local function reflect(cf)
	if not Mirror.Mirrored then
		return cf
	end
	local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
	return CFrame.new(-x, y, z, r00, -r01, -r02, -r10, r11, r12, -r20, r21, r22)
end

local function stripClone(src)
	local ok, c = pcall(function()
		local wasArchivable = src.Archivable
		src.Archivable = true
		local clone = src:Clone()
		src.Archivable = wasArchivable
		return clone
	end)
	if not ok or not c then
		return nil
	end
	for _, d in ipairs(c:GetChildren()) do
		if not (d:IsA("SurfaceAppearance") or d:IsA("Decal") or d:IsA("Texture") or d:IsA("SpecialMesh")) then
			d:Destroy()
		end
	end
	c.Anchored = true
	c.CanCollide, c.CanQuery, c.CanTouch, c.CastShadow = false, false, false, false
	return c
end

local function build()
	if gui then
		return
	end
	gui = Instance.new("ScreenGui")
	gui.Name = "F2R_Mirror"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 5
	gui.Enabled = false
	frame = Instance.new("Frame")
	frame.Name = "Mirror"
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Position = UDim2.new(0.5, 0, 0, Mirror.Top)
	frame.Size = Mirror.Size
	frame.BackgroundColor3 = Color3.fromRGB(10, 10, 12)
	frame.BorderSizePixel = 0
	frame.Parent = gui
	local ar = Instance.new("UIAspectRatioConstraint")
	ar.AspectRatio = Mirror.Aspect
	ar.Parent = frame
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(15, 15, 18)
	stroke.Transparency = 0.1
	stroke.Parent = frame
	vp = Instance.new("ViewportFrame")
	vp.Name = "View"
	vp.Size = UDim2.fromScale(1, 1)
	vp.BackgroundColor3 = Color3.fromRGB(150, 185, 225)
	vp.BorderSizePixel = 0
	vp.Parent = frame
	local c2 = corner:Clone()
	c2.Parent = vp
	world = Instance.new("WorldModel")
	world.Parent = vp
	cam = Instance.new("Camera")
	cam.FieldOfView = Mirror.Fov
	cam.Parent = vp
	vp.CurrentCamera = cam
	ground = Instance.new("Part")
	ground.Name = "Ground"
	ground.Anchored = true
	ground.Size = Vector3.new(4000, 1, 4000)
	ground.Material = Enum.Material.SmoothPlastic
	ground.Color = Color3.fromRGB(70, 72, 75)
	ground.Parent = world
	gui.Parent = player:WaitForChild("PlayerGui")
end

local function clearAll()
	for _, t in ipairs(tiles) do
		t.Parent = nil
	end
	for _, c in pairs(decor) do
		c:Destroy()
	end
	table.clear(decor)
	decorCount = 0
	for _, p in pairs(proxies) do
		for _, e in ipairs(p.parts) do
			e[2]:Destroy()
		end
	end
	table.clear(proxies)
end

local function vehicleOf(inst)
	local m = inst:FindFirstAncestorOfClass("Model")
	while m do
		if CollectionService:HasTag(m, Mirror.Tag) then
			return m
		end
		m = m:FindFirstAncestorOfClass("Model")
	end
	return nil
end

-- ------------------------------------------------------------------ décor
local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Exclude
local function refreshDecor(model)
	local cf = model.PrimaryPart.CFrame
	local back = -Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z).Unit
	local center = cf.Position + back * (Mirror.DecorRange / 2 - 10)
	local boxCf = CFrame.lookAt(center, center + back)
	local exclude = { model }
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then
			table.insert(exclude, p.Character)
		end
	end
	for _, v in ipairs(CollectionService:GetTagged(Mirror.Tag)) do
		table.insert(exclude, v)
	end
	overlap.FilterDescendantsInstances = exclude
	local size = Vector3.new(Mirror.DecorWidth, Mirror.DecorHeight, Mirror.DecorRange)
	local found = Workspace:GetPartBoundsInBox(boxCf, size, overlap)
	local keep = {}
	local fresh = {}
	for _, p in ipairs(found) do
		if p.Transparency < 0.95 and not p:IsA("Terrain") then
			local s = p.Size
			if math.max(s.X, s.Y, s.Z) >= Mirror.MinPartSize and not vehicleOf(p) then
				keep[p] = true
				if not decor[p] then
					table.insert(fresh, p)
				end
			end
		end
	end
	-- sortis de la zone (avec une marge : ils restent tant qu'ils sont dans une zone 1,3 × plus grande)
	for src, clone in pairs(decor) do
		if not keep[src] then
			local rel = boxCf:PointToObjectSpace(src.Position)
			if not src.Parent or math.abs(rel.X) > size.X * 0.65 or math.abs(rel.Z) > size.Z * 0.65 then
				clone:Destroy()
				decor[src] = nil
				decorCount -= 1
			end
		end
	end
	-- les plus gros d'abord, sans dépasser le budget
	table.sort(fresh, function(a, b)
		return a.Size.Magnitude > b.Size.Magnitude
	end)
	local added = 0
	for _, src in ipairs(fresh) do
		if decorCount >= Mirror.MaxDecorParts or added >= Mirror.NewPerRefresh then
			break
		end
		local c = stripClone(src)
		if c then
			c.CFrame = reflect(src.CFrame)
			c.Parent = world
			decor[src] = c
			decorCount += 1
			added += 1
		end
	end
	stats.decor = decorCount
end

-- ------------------------------------------------------------------ véhicules
local function proxyOf(v)
	local p = proxies[v]
	if p then
		return p
	end
	local cand = {}
	for _, d in ipairs(v:GetDescendants()) do
		if d:IsA("BasePart") and d.Transparency < 0.95 and not d:FindFirstAncestorOfClass("Accessory") then
			local char = d:FindFirstAncestorOfClass("Model")
			if not (char and char:FindFirstChildOfClass("Humanoid")) then
				table.insert(cand, d)
			end
		end
	end
	table.sort(cand, function(a, b)
		return a.Size.Magnitude > b.Size.Magnitude
	end)
	p = { parts = {} }
	for i = 1, math.min(#cand, Mirror.MaxPartsPerVehicle) do
		local c = stripClone(cand[i])
		if c then
			c.Parent = world
			table.insert(p.parts, { cand[i], c })
		end
	end
	proxies[v] = p
	return p
end

local moveParts, moveCFrames = {}, {}
local function updateVehicles(model)
	local here = model.PrimaryPart.Position
	local live = {}
	for _, v in ipairs(CollectionService:GetTagged(Mirror.Tag)) do
		if v ~= model and v:IsA("Model") and v.PrimaryPart and v:IsDescendantOf(Workspace)
			and (v.PrimaryPart.Position - here).Magnitude < Mirror.Range then
			live[v] = true
		end
	end
	for v, p in pairs(proxies) do
		if not live[v] then
			for _, e in ipairs(p.parts) do
				e[2]:Destroy()
			end
			proxies[v] = nil
		end
	end
	table.clear(moveParts)
	table.clear(moveCFrames)
	local nv = 0
	for v in pairs(live) do
		nv += 1
		for _, e in ipairs(proxyOf(v).parts) do
			local src, clone = e[1], e[2]
			if src.Parent then
				table.insert(moveParts, clone)
				table.insert(moveCFrames, reflect(src.CFrame))
				clone.Transparency = math.max(src.Transparency, src.LocalTransparencyModifier)
			end
		end
	end
	if #moveParts > 0 then
		world:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
	stats.vehicles = nv
	stats.parts = #moveParts
end

-- ------------------------------------------------------------------ terrain (relevé en dalles)
local terrainParams = RaycastParams.new()
terrainParams.FilterType = Enum.RaycastFilterType.Include
local matColor = {}
local function terrainColor(mat)
	local c = matColor[mat]
	if not c then
		local ok, col = pcall(function()
			return Workspace.Terrain:GetMaterialColor(mat)
		end)
		c = ok and col or Color3.fromRGB(90, 90, 90)
		matColor[mat] = c
	end
	return c
end
local function refreshTerrain(model)
	local cell = Mirror.TerrainCell
	if not cell or cell <= 0 then
		return
	end
	terrainParams.FilterDescendantsInstances = { Workspace.Terrain }
	local cf = model.PrimaryPart.CFrame
	local fwd = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z).Unit
	local right = fwd:Cross(Vector3.yAxis)
	local origin = cf.Position
	local nx = math.floor(Mirror.DecorWidth / cell)
	local nz = math.floor(Mirror.DecorRange / cell)
	local used = 0
	for iz = 0, nz - 1 do
		for ix = 0, nx - 1 do
			local p = origin - fwd * ((iz + 0.5) * cell - cell) + right * ((ix + 0.5) * cell - nx * cell / 2)
			local hit = Workspace:Raycast(p + Vector3.new(0, 60, 0), Vector3.new(0, -140, 0), terrainParams)
			if hit and hit.Material ~= Enum.Material.Water then
				used += 1
				local t = tiles[used]
				if not t then
					t = Instance.new("Part")
					t.Anchored = true
					t.CanCollide, t.CanQuery, t.CanTouch, t.CastShadow = false, false, false, false
					t.Material = Enum.Material.SmoothPlastic
					t.Size = Vector3.new(cell + 0.2, 0.4, cell + 0.2)
					tiles[used] = t
				end
				t.Color = terrainColor(hit.Material)
				local up = hit.Normal
				local look = (fwd - up * fwd:Dot(up)).Unit
				t.CFrame = reflect(CFrame.lookAt(hit.Position - up * 0.2, hit.Position - up * 0.2 + look, up))
				t.Parent = world
			end
		end
	end
	for i = used + 1, #tiles do
		tiles[i].Parent = nil
	end
	stats.tiles = used
end

-- ------------------------------------------------------------------ ciel, sol, lumière
local function skyColor()
	local h = Lighting.ClockTime
	local day = math.clamp(math.sin((h - 6) / 12 * math.pi) * 1.6, 0, 1) -- 0 la nuit, 1 en journée
	local dayC, nightC = Color3.fromRGB(150, 185, 225), Color3.fromRGB(14, 17, 28)
	return nightC:Lerp(dayC, day)
end

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
local function refreshGround(model)
	groundParams.FilterDescendantsInstances = { model }
	local pos = model.PrimaryPart.Position
	local hit = Workspace:Raycast(pos + Vector3.new(0, 4, 0), Vector3.new(0, -40, 0), groundParams)
	if hit then
		if hit.Instance:IsA("Terrain") then
			local ok, c = pcall(function()
				return Workspace.Terrain:GetMaterialColor(hit.Material)
			end)
			ground.Color = ok and c or ground.Color
			ground.Material = hit.Material
		else
			ground.Color = hit.Instance.Color
			ground.Material = hit.Instance.Material
		end
		ground.CFrame = reflect(CFrame.new(Vector3.new(pos.X, hit.Position.Y - 0.55, pos.Z)))
	end
	vp.BackgroundColor3 = skyColor()
	vp.Ambient = Lighting.OutdoorAmbient:Lerp(Color3.new(1, 1, 1), 0.15)
	vp.LightColor = Color3.new(1, 1, 1):Lerp(skyColor(), 0.3)
	local sun = Lighting:GetSunDirection()
	vp.LightDirection = -(Mirror.Mirrored and Vector3.new(-sun.X, sun.Y, sun.Z) or sun)
end

-- ------------------------------------------------------------------ caméra du rétro
local cfgCache = setmetatable({}, { __mode = "k" })
local function mirrorPoint(model)
	local c = cfgCache[model]
	if c == nil then
		local m = model:FindFirstChild("VehicleConfig")
		local ok, cfg = pcall(function()
			return require(m)
		end)
		c = false
		if ok and type(cfg) == "table" and cfg.Bounds then
			local spm = cfg.StudsPerMeter or 3.571
			local seatZ = 0
			for _, s in ipairs(cfg.Seats or {}) do
				if s.Driver and s.Position then
					seatZ = s.Position[3]
				end
			end
			c = Vector3.new(0, cfg.Bounds.Max[2] + 0.12, seatZ) * spm
		end
		cfgCache[model] = c
	end
	if c then
		return c
	end
	local size = model:GetExtentsSize()
	return Vector3.new(0, size.Y / 2 + 0.5, 0)
end

local function placeCamera(model)
	local cf = model.PrimaryPart.CFrame
	local p = cf:PointToWorldSpace(mirrorPoint(model))
	local back = -cf.LookVector
	local view = CFrame.lookAt(p, p + back, cf.UpVector) * CFrame.Angles(-math.rad(3), 0, 0)
	cam.CFrame = reflect(view)
end

function Mirror.SetEnabled(on)
	on = on == true
	if Mirror.Enabled == on then
		return
	end
	Mirror.Enabled = on
	if not on then
		clearAll()
		if gui then
			gui.Enabled = false
		end
	end
	changed:Fire(on)
end

function Mirror.Toggle()
	Mirror.SetEnabled(not Mirror.Enabled)
	return Mirror.Enabled
end

function Mirror.Stats()
	return table.clone(stats)
end

local started = false
function Mirror.Start()
	if started then
		return
	end
	started = true
	local bound = false
	local function act(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			Mirror.Toggle()
		end
		return Enum.ContextActionResult.Sink
	end
	local current
	RunService:BindToRenderStep("F2R_VehicleMirror", Enum.RenderPriority.Camera.Value + 3, function()
		local model = occupied()
		if model and not bound then
			ContextActionService:BindAction("F2R_Mirror", act, true, Mirror.Key)
			ContextActionService:SetTitle("F2R_Mirror", "Rétro")
			bound = true
		elseif not model and bound then
			ContextActionService:UnbindAction("F2R_Mirror")
			bound = false
		end
		if not model or not Mirror.Enabled then
			if gui and gui.Enabled then
				gui.Enabled = false
			end
			if current then
				clearAll()
				current = nil
			end
			return
		end
		local t0 = os.clock()
		build()
		if current ~= model then
			clearAll()
			current = model
			lastRefresh = 0
		end
		gui.Enabled = true
		if os.clock() - lastRefresh > Mirror.Refresh then
			lastRefresh = os.clock()
			refreshDecor(model)
			refreshTerrain(model)
			refreshGround(model)
		end
		updateVehicles(model)
		placeCamera(model)
		stats.ms = stats.ms * 0.9 + (os.clock() - t0) * 1000 * 0.1
	end)
end

return Mirror
