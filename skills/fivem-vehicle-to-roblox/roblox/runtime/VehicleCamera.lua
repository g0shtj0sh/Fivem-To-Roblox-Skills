--!nonstrict
--[[
	VehicleCamera (ModuleScript, ReplicatedStorage.FiveMVehicles) — caméra de l'occupant local, façon GTA V.

		local Camera = require(ReplicatedStorage.FiveMVehicles.VehicleCamera)
		Camera.Start()   -- FiveMVehiclesClient l'appelle une fois

	Vue extérieure : la caméra de Roblox, pivot sur l'œil du conducteur (Humanoid.CameraOffset).
	Vue à la première personne (« POV » de GTA) : une caméra à nous, posée sur l'œil GTA du siège
	(VehiclePose.EyeWorld : os du siège + PovCameraOffset de vehicles.meta), qui :
	- tourne AVEC le véhicule (le regard est un cap et une inclinaison relatifs à l'habitacle) ;
	- ne fait pas le tour complet : cap borné à ±YawMax, inclinaison entre −PitchDown et +PitchUp ;
	- revient d'elle-même vers l'avant quand on roule sans toucher à la vue (RecenterDelay) ;
	- regarde derrière tant que « regarder derrière » est tenu (C, R3 manette : la même touche que GTA) ;
	- ne montre que les avant-bras et les mains du personnage (posés sur le volant par VehiclePose), pas le corps.

	Entrer / sortir : V (bouton « Vue » à l'écran sur mobile) bascule, comme la touche « vue » de GTA ; zoomer
	jusqu'au bout (molette, pincement) entre aussi en vue intérieure, et reculer la molette en sort. Un jeu en LockFirstPerson reste en vue
	intérieure dans le véhicule.

	Les bornes de GTA ne sont pas documentées (DEFAULT_POV_CAMERA_LOOKAROUND_MID, dans les métadonnées de caméra du
	jeu) : YawMax, PitchUp, PitchDown et le recentrage sont posés à l'œil, à mesurer dans FiveM.
	Réglages : attribut `PovCamera = false` sur le véhicule pour garder la caméra de Roblox.
]]
local Players = game:GetService("Players")
local ContextActionService = game:GetService("ContextActionService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local Pose = require(script.Parent:WaitForChild("VehiclePose"))

local Camera = {}
Camera.Tag = "FiveMVehicle"
Camera.YawMax = 110 -- degrés de part et d'autre de l'avant
Camera.PitchUp = 30 -- degrés
Camera.PitchDown = 45 -- degrés
Camera.StartPitch = 4 -- degrés vers le bas à l'ouverture de la vue (route et compteurs)
Camera.RecenterDelay = 1.5 -- s sans toucher à la vue avant de revenir vers l'avant
Camera.RecenterRate = 2.5 -- 1/s (retour exponentiel)
Camera.RecenterSpeed = 3 -- m/s : en dessous, la vue reste où on l'a laissée (à l'arrêt, on regarde autour)
Camera.ToggleKey = Enum.KeyCode.V -- et un bouton « Vue » à l'écran sur mobile (ContextActionService)
Camera.LookBackKeys = { Enum.KeyCode.C, Enum.KeyCode.ButtonR3 }
Camera.ExitZoom = 12 -- studs : distance de la vue extérieure en sortant de la vue intérieure
-- pièces du personnage visibles en vue intérieure (R6 : aucune, ses bras sont d'un bloc depuis l'épaule)
Camera.Visible = { LeftLowerArm = 0.55, RightLowerArm = 0.55, LeftHand = 0.75, RightHand = 0.75 } -- et leur finesse

local player = Players.LocalPlayer
local state = {
	pov = false,
	yaw = 0,
	pitch = 0,
	lastLook = 0,
	offsetHum = nil,
	touches = {},
}

local function occupied()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.SeatPart
	local model = seat and seat.Parent and seat.Parent.Name == "Seats" and seat.Parent.Parent
	if model and CollectionService:HasTag(model, Camera.Tag) and model.PrimaryPart and hum.RootPart then
		return model, seat, hum, char
	end
	return nil
end

local function enabled(model, seat)
	return model:GetAttribute("PovCamera") ~= false and Pose.EyeWorld(model, seat) ~= nil
end

local function anyDown(keys)
	for _, k in ipairs(keys) do
		if UserInputService:IsKeyDown(k) then
			return true
		end
	end
	for _, pad in ipairs(UserInputService:GetConnectedGamepads()) do
		for _, k in ipairs(keys) do
			if UserInputService:IsGamepadButtonDown(pad, k) then
				return true
			end
		end
	end
	return false
end

-- Bras de la vue intérieure : les VRAIS avant-bras et mains, amincis sur ce client seulement (une taille changée
-- par un client ne se réplique pas : les autres joueurs voient l'avatar tel quel). Des copies locales perdaient
-- la texture du vêtement (appliquée au personnage) et sortaient grises. Avec un avatar large, les avant-bras
-- bouchaient le volant (demande de l'utilisateur, 2026-11-13). Tailles d'origine rendues à la sortie ; une mise
-- à l'échelle du serveur (VehicleSeatFit) pendant la vue est reprise comme nouvelle taille d'origine.
local thinned = {} -- part -> { orig = Vector3, set = Vector3 }
local function restoreArms()
	for part, t in pairs(thinned) do
		if part.Parent and part.Size == t.set then
			part.Size = t.orig
		end
	end
	table.clear(thinned)
end
local function thinArms(char)
	for name, thin in pairs(Camera.Visible) do
		local part = char:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			local t = thinned[part]
			if not t or part.Size ~= t.set then
				local orig = part.Size
				-- l'axe long d'un membre R15 est Y : on n'amincit que X et Z
				local set = Vector3.new(orig.X * thin, orig.Y, orig.Z * thin)
				thinned[part] = { orig = orig, set = set }
				part.Size = set
			end
		end
	end
end

local function setBody(char, pov)
	for _, p in ipairs(char:GetDescendants()) do
		if p:IsA("BasePart") then
			local isLimb = p.Parent == char and Camera.Visible[p.Name] ~= nil
			p.LocalTransparencyModifier = (pov and not isLimb) and 1 or 0
		end
	end
	if pov then
		thinArms(char)
	else
		restoreArms()
	end
end

local function enter()
	-- comme GTA : la vue intérieure s'ouvre face à la route, quel que soit l'endroit où regardait la caméra extérieure
	-- (en reprenant ce regard, on entrait la tête tournée vers la portière, cap borné à 110 °)
	state.pov = true
	state.lastLook = os.clock()
	state.yaw = 0
	state.pitch = -math.rad(Camera.StartPitch)
	Workspace.CurrentCamera.CameraType = Enum.CameraType.Scriptable
end

local function exit(char, zoomOut)
	if not state.pov then
		return
	end
	state.pov = false
	local cam = Workspace.CurrentCamera
	cam.CameraType = Enum.CameraType.Custom
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		cam.CameraSubject = hum
	end
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
	if char then
		setBody(char, false)
	end
	if zoomOut and player.CameraMode ~= Enum.CameraMode.LockFirstPerson then
		-- la caméra de Roblox reprend au plus près : on l'éloigne une image par la distance minimale
		local was = player.CameraMinZoomDistance
		player.CameraMinZoomDistance = math.min(Camera.ExitZoom, player.CameraMaxZoomDistance)
		task.delay(0.1, function()
			player.CameraMinZoomDistance = was
		end)
	end
end

-- Décalage de caméra du Humanoid qui met le pivot de la vue extérieure sur l'œil du conducteur. La caméra de
-- Roblox suit HumanoidRootPart + (0, 1,5 + (taille Y − 2)/2, 0) (R15 mis à l'échelle ; R6 : 1,5) + CameraOffset,
-- dans le repère de HumanoidRootPart (CameraModule, BaseCamera:GetSubjectPosition).
local function setOffset(hum, eye)
	local hrp = hum.RootPart
	local h = (hum.RigType == Enum.HumanoidRigType.R15 and hum.AutomaticScalingEnabled) and (1.5 + (hrp.Size.Y - 2) / 2)
		or 1.5
	hum.CameraOffset = hrp.CFrame:VectorToObjectSpace(eye - hrp.Position) - Vector3.new(0, h, 0)
	state.offsetHum = hum
end

local function look(dYaw, dPitch)
	state.yaw = math.clamp(state.yaw + dYaw, -math.rad(Camera.YawMax), math.rad(Camera.YawMax))
	state.pitch = math.clamp(state.pitch + dPitch, -math.rad(Camera.PitchDown), math.rad(Camera.PitchUp))
	state.lastLook = os.clock()
end

-- tourner la vue intérieure (radians, bornés) : entrée des scripts et des essais
function Camera.Look(dYaw, dPitch)
	look(dYaw, dPitch or 0)
end
function Camera.IsPov()
	return state.pov
end

local started = false
function Camera.Start()
	if started then
		return
	end
	started = true

	local function toggle(_, inputState)
		if inputState ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		local model, seat, _, char = occupied()
		if model and enabled(model, seat) then
			if state.pov then
				if player.CameraMode ~= Enum.CameraMode.LockFirstPerson then
					exit(char, true)
				end
			else
				enter()
			end
		end
		return Enum.ContextActionResult.Sink
	end
	local bound = false
	local function bindToggle(on)
		if on and not bound then
			ContextActionService:BindAction("F2R_View", toggle, true, Camera.ToggleKey)
			ContextActionService:SetTitle("F2R_View", "Vue")
		elseif not on and bound then
			ContextActionService:UnbindAction("F2R_View")
		end
		bound = on
	end

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		local model, seat = occupied()
		if not model or not enabled(model, seat) then
			return
		end
		if input.UserInputType == Enum.UserInputType.Touch then
			state.touches[input] = true
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		state.touches[input] = nil
	end)
	UserInputService.InputChanged:Connect(function(input, processed)
		if not state.pov then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseWheel and not processed then
			if input.Position.Z < 0 and player.CameraMode ~= Enum.CameraMode.LockFirstPerson then
				local _, _, _, char = occupied()
				exit(char, true)
			end
		elseif input.UserInputType == Enum.UserInputType.Touch and state.touches[input] then
			-- même sensibilité que la caméra tactile de Roblox (≈ 0,0045 rad par pixel)
			look(-input.Delta.X * 0.0045, -input.Delta.Y * 0.0045)
		end
	end)

	RunService:BindToRenderStep("F2R_VehicleCamera", Enum.RenderPriority.Camera.Value + 1, function(dt)
		local model, seat, hum, char = occupied()
		bindToggle(model ~= nil and enabled(model, seat))
		if not model or not enabled(model, seat) then
			if state.pov then
				exit(player.Character, false)
			end
			if state.offsetHum then
				if state.offsetHum.Parent then
					state.offsetHum.CameraOffset = Vector3.zero
				end
				state.offsetHum = nil
			end
			return
		end
		local eye = Pose.EyeWorld(model, seat)
		setOffset(hum, eye)
		local cam = Workspace.CurrentCamera

		if not state.pov then
			-- la caméra de Roblox est arrivée à la première personne (molette, LockFirstPerson) : on prend la main
			local firstPerson = (cam.CFrame.Position - cam.Focus.Position).Magnitude < 1
			if firstPerson or player.CameraMode == Enum.CameraMode.LockFirstPerson then
				enter()
			else
				return
			end
		end

		cam.CameraType = Enum.CameraType.Scriptable
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = false
		-- souris (sensibilité de la caméra de Roblox : 0,002π / 0,0015π rad par pixel × réglage du joueur)
		local sens = UserSettings():GetService("UserGameSettings").MouseSensitivity
		local d = UserInputService:GetMouseDelta()
		if d.Magnitude > 0 then
			look(-d.X * 0.002 * math.pi * sens, -d.Y * 0.0015 * math.pi * sens)
		end
		-- manette : stick droit
		for _, pad in ipairs(UserInputService:GetConnectedGamepads()) do
			for _, st in ipairs(UserInputService:GetGamepadState(pad)) do
				if st.KeyCode == Enum.KeyCode.Thumbstick2 and st.Position.Magnitude > 0.2 then
					look(-st.Position.X * 4 * dt, st.Position.Y * 3 * dt)
				end
			end
		end
		-- retour vers l'avant quand on roule sans toucher à la vue
		local speed = model.PrimaryPart.AssemblyLinearVelocity.Magnitude / 3.571
		if os.clock() - state.lastLook > Camera.RecenterDelay and speed > Camera.RecenterSpeed then
			local k = 1 - math.exp(-Camera.RecenterRate * dt)
			state.yaw -= state.yaw * k
			state.pitch += (-math.rad(Camera.StartPitch) - state.pitch) * k
		end
		local yaw = anyDown(Camera.LookBackKeys) and math.pi or state.yaw
		local cf = CFrame.new(eye) * model.PrimaryPart.CFrame.Rotation * CFrame.Angles(0, yaw, 0) * CFrame.Angles(state.pitch, 0, 0)
		cam.CFrame = cf
		cam.Focus = cf
		setBody(char, true)
	end)
end

return Camera
