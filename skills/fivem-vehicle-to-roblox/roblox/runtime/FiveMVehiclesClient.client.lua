--!nonstrict
-- FiveMVehiclesClient (LocalScript, StarterPlayerScripts)
-- Rend tous les véhicules convertis (lumières, sons, roues, portes) et, quand le joueur
-- est au volant, active les contrôles et envoie ses actions / sa télémétrie au serveur.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")

local folder = ReplicatedStorage:WaitForChild("FiveMVehicles")
local Runtime = require(folder:WaitForChild("VehicleRuntime"))
local Input = require(folder:WaitForChild("VehicleInput"))
local Drive = require(folder:WaitForChild("VehicleDrive"))
local SeatFit = require(folder:WaitForChild("VehicleSeatFit"))
local Dashboard = require(folder:WaitForChild("VehicleDashboard"))
local Pose = require(folder:WaitForChild("VehiclePose"))
Pose.Start() -- posture des occupants de tous les véhicules (sur chaque client)
require(folder:WaitForChild("VehicleCamera")).Start() -- caméra de l'occupant local, vues façon Assetto Corsa (V)
require(folder:WaitForChild("VehicleMirror")).Start() -- rétroviseur virtuel en haut de l'écran (B)
-- combiné d'instruments vivant (VehicleConfig.ClusterScreen) ; absent d'un ancien runtime : ignoré
local screenModule = folder:WaitForChild("VehicleScreen", 5)
if screenModule then
	require(screenModule).Start()
end
-- portières / capot / coffre : Alt gauche maintenu + clic, comme ox_target sur FiveM (invites gardées au tactile / manette)
local targetModule = folder:WaitForChild("VehicleTarget", 10)
if targetModule then
	require(targetModule).Start()
end
local remote = folder:WaitForChild("VehicleEvent")
local telemetry = folder:WaitForChild("VehicleTelemetry")

local TAG = "FiveMVehicle"
local player = Players.LocalPlayer
local driving = nil -- modèle conduit par le joueur local
local occupying = nil

-- Attache le rendu à un véhicule. Le modèle peut arriver avant ses enfants (réplication,
-- streaming) : Runtime.Attach renvoie alors nil. On réessaie jusqu'à ce que VehicleRoot et
-- VehicleConfig soient là (observé le 2026-11-10 : une seule tentative au démarrage laissait un
-- véhicule sans lumières, portes ni sons).
local function attach(m)
	task.spawn(function()
		local deadline = os.clock() + 30
		while m.Parent ~= nil and os.clock() < deadline do
			if Runtime.Get(m) then
				return
			end
			if m.PrimaryPart and m:FindFirstChild("VehicleConfig") and Runtime.Attach(m) then
				return
			end
			task.wait(0.25)
		end
		if m.Parent ~= nil then
			warn("[FiveMVehicles] rendu non attaché à " .. m:GetFullName() .. " (VehicleRoot ou VehicleConfig absent)")
		end
	end)
end

-- Néons : nappe au sol dessinée (VehicleCustomization.BuildNeonGlow) atténuée de jour, comme dans GTA V où les néons
-- se devinent à peine en plein soleil (2026-11-18). Nuit (20 h – 5 h) : pleine ; jour (9 h – 17 h) : DayVisibility.
local NEON_DAY_VISIBILITY = 0.3
local function neonVisibility()
	local t = game:GetService("Lighting").ClockTime
	local function ramp(a, b, x)
		return math.clamp((x - a) / (b - a), 0, 1)
	end
	local day = math.min(ramp(5, 9, t), 1 - ramp(17, 20, t)) -- 0 la nuit, 1 en plein jour
	return 1 - (1 - NEON_DAY_VISIBILITY) * day
end
task.spawn(function()
	local lastVis
	while true do
		local vis = neonVisibility()
		for _, m in ipairs(CollectionService:GetTagged(TAG)) do
			local plate = m:FindFirstChild("NeonGlow")
			local gui = plate and plate:FindFirstChild("Glow")
			if gui and (gui.Enabled or vis ~= lastVis) then
				for _, img in ipairs(gui:GetChildren()) do
					local base = img:IsA("ImageLabel") and img:GetAttribute("BaseTransparency")
					if base then
						-- le grand ovale diffus fait « tache » de jour : atténué deux fois plus
						local v = img.Name == "Oval" and vis * vis or vis
						img.ImageTransparency = 1 - (1 - base) * v
					end
				end
			end
		end
		lastVis = vis
		task.wait(1)
	end
end)

if not game:IsLoaded() then
	game.Loaded:Wait()
end
for _, m in ipairs(CollectionService:GetTagged(TAG)) do
	attach(m)
end
CollectionService:GetInstanceAddedSignal(TAG):Connect(attach)
CollectionService:GetInstanceRemovedSignal(TAG):Connect(Runtime.Detach)

local function set(key, value)
	if not driving then
		return
	end
	driving:SetAttribute(key, value) -- retour visuel immédiat, le serveur confirme
	remote:FireServer(driving, "Set", key, value)
end

Input.Action.Event:Connect(function(name, value)
	local m = driving
	if not m then
		return
	end
	if name == "Horn" then
		set("Horn", value == true)
	elseif name == "Headlights" then
		set("Headlights", ((m:GetAttribute("Headlights") or 0) + 1) % 3)
	elseif name == "IndicatorLeft" then
		set("Indicator", m:GetAttribute("Indicator") == "Left" and "Off" or "Left")
	elseif name == "IndicatorRight" then
		set("Indicator", m:GetAttribute("Indicator") == "Right" and "Off" or "Right")
	elseif name == "Hazard" then
		set("Indicator", m:GetAttribute("Indicator") == "Hazard" and "Off" or "Hazard")
	elseif name == "Siren" and m:GetAttribute("HasSiren") then
		set("Siren", not m:GetAttribute("Siren"))
	elseif name == "SirenTone" and m:GetAttribute("HasSiren") then
		local order = { "wail", "yelp", "priority", "off" }
		local cur = table.find(order, m:GetAttribute("SirenSound") or "wail") or 1
		set("SirenSound", order[cur % #order + 1])
	elseif name == "Engine" then
		set("Engine", not m:GetAttribute("Engine"))
	elseif name == "ParkingBrake" then
		set("ParkingBrake", m:GetAttribute("ParkingBrake") ~= true)
	elseif name == "InteriorLight" then
		set("InteriorLight", not m:GetAttribute("InteriorLight"))
	elseif name == "Cruise" then
		Drive.ToggleCruise("cruise")
	elseif name == "Limiter" then
		Drive.ToggleCruise("limit")
	elseif name == "Windows" then
		-- vitres avant : toutes deux baissées ou toutes deux montées (vitres cassées ignorées par le serveur)
		local front, seen = {}, {}
		for _, d in ipairs(m:GetDescendants()) do
			local bone = d:IsA("BasePart") and d:GetAttribute("Kind") == "glass" and d:GetAttribute("Window")
			if bone and not seen[bone] and string.match(bone, "_[lr]f$") then
				seen[bone] = true
				table.insert(front, bone)
			end
		end
		local anyUp = false
		for _, bone in ipairs(front) do
			if m:GetAttribute("WindowDown_" .. bone) ~= true then
				anyUp = true
			end
		end
		for _, bone in ipairs(front) do
			remote:FireServer(m, "Window", bone, anyUp)
		end
	end
	-- "GearUp", "GearDown", "LookBack"... : à écouter par ton moteur physique via Input.Action
end)

-- Invites du véhicule où l'on est assis : toutes masquées localement (« Conduire / Monter », et aussi
-- portières, capot, coffre : à bord, GTA n'en montre aucune, et l'invite du capot flottait devant le pare-brise
-- à la première personne). Le serveur tient la vérité : Available pour monter, Flipped pour la remise sur roues ;
-- les autres invites reprennent l'état qu'elles avaient.
local promptConns = {}
local promptWas = setmetatable({}, { __mode = "k" })
local function vehiclePrompts(model)
	local out = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("ProximityPrompt") then
			table.insert(out, d)
		end
	end
	return out
end
local function setPromptsHidden(model, hidden)
	for _, c in ipairs(promptConns) do
		c:Disconnect()
	end
	table.clear(promptConns)
	if not model then
		return
	end
	for _, prompt in ipairs(vehiclePrompts(model)) do
		if hidden and promptWas[prompt] == nil then
			promptWas[prompt] = prompt.Enabled
		end
		local function apply()
			if hidden then
				prompt.Enabled = false
			elseif prompt:GetAttribute("SeatName") then
				prompt.Enabled = prompt:GetAttribute("Available") ~= false
			elseif prompt:GetAttribute("Recover") then
				prompt.Enabled = model:GetAttribute("Flipped") == true
			elseif promptWas[prompt] ~= nil then
				prompt.Enabled = promptWas[prompt]
			end
			if not hidden then
				promptWas[prompt] = nil
			end
		end
		apply()
		if hidden then
			table.insert(promptConns, prompt:GetAttributeChangedSignal("Available"):Connect(apply))
			table.insert(promptConns, prompt:GetPropertyChangedSignal("Enabled"):Connect(function()
				if prompt.Enabled then
					prompt.Enabled = false
				end
			end))
		end
	end
end

-- Descendre (F / Y / bouton tactile) et remettre sur ses roues (X / croix bas), pour tout occupant.
local function bindOccupantActions(model)
	ContextActionService:BindActionAtPriority("F2R_Exit", function(_, state)
		if state == Enum.UserInputState.Begin then
			remote:FireServer(model, "Exit")
		end
		return Enum.ContextActionResult.Sink
	end, true, Enum.ContextActionPriority.High.Value, Enum.KeyCode.F, Enum.KeyCode.ButtonY)
	ContextActionService:SetTitle("F2R_Exit", "Descendre")
	ContextActionService:BindActionAtPriority("F2R_Recover", function(_, state)
		if state == Enum.UserInputState.Begin and model:GetAttribute("Flipped") == true then
			remote:FireServer(model, "Recover")
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.X, Enum.KeyCode.DPadDown)
end
local function unbindOccupantActions()
	ContextActionService:UnbindAction("F2R_Exit")
	ContextActionService:UnbindAction("F2R_Recover")
end

-- Descente : le serveur choisit où poser le personnage ; le client, qui possède sa physique, s'y place.
remote.OnClientEvent:Connect(function(kind, cf)
	if kind ~= "PlaceAt" or typeof(cf) ~= "CFrame" then
		return
	end
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end
	if hum.Sit then
		hum.Sit = false
	end
	for _ = 1, 3 do -- quelques images : le temps que la soudure du siège disparaisse ici aussi
		char:PivotTo(cf)
		local hrp = char:FindFirstChild("HumanoidRootPart")
		if hrp then
			hrp.AssemblyLinearVelocity = Vector3.zero
		end
		task.wait()
	end
	hum:ChangeState(Enum.HumanoidStateType.GettingUp)
end)

local function onSeated(active, seat)
	local model = nil
	if active and seat then
		for _, m in ipairs(CollectionService:GetTagged(TAG)) do
			if seat:IsDescendantOf(m) then
				model = m
				break
			end
		end
	end
	if occupying and occupying ~= model then
		local r = Runtime.Get(occupying)
		if r then
			r.IsLocalOccupant = false
			r.LocalOverride = nil
		end
	end
	if occupying ~= model then
		if occupying then
			setPromptsHidden(occupying, false)
		end
		unbindOccupantActions()
	end
	occupying = model
	if model then
		local r = Runtime.Attach(model)
		if r then
			r.IsLocalOccupant = true
		end
		setPromptsHidden(model, true)
		bindOccupantActions(model)
		-- corps adapté à l'habitacle (bras dans la portière, tête dans le pavillon)
		task.spawn(SeatFit.RunClient, model, seat, remote)
	end
	if model and seat.Name == "DriverSeat" then
		driving = model
		Input.Enable()
		-- moteur de conduite (désactivable : attribut UseBuiltinDrive = false pour brancher son propre châssis)
		if model:GetAttribute("UseBuiltinDrive") ~= false then
			Drive.Start(model)
		end
		-- compteur de vitesse (désactivable : attribut BuiltinSpeedometer = false, cf. VehicleDashboard)
		Dashboard.Start(model)
	else
		Drive.Stop()
		Dashboard.Stop()
		if driving then
			set("Horn", false)
		end
		driving = nil
		Input.Disable()
	end
end

local function hookCharacter(char)
	Dashboard.Stop() -- réapparition : plus au volant
	local hum = char:WaitForChild("Humanoid")
	hum.Seated:Connect(onSeated)
	if hum.SeatPart then
		onSeated(true, hum.SeatPart)
	end
end
if player.Character then
	task.spawn(hookCharacter, player.Character)
end
player.CharacterAdded:Connect(hookCharacter)

-- Entrées locales -> rendu immédiat + télémétrie 10 Hz vers le serveur
local TyreFx = require(folder:WaitForChild("VehicleTyreFx"))
local sendAcc = 0
local tyrePeak = {} -- intensité max de chaque roue depuis le dernier envoi (un patinage bref n'est pas perdu)
local brakeHeld = false
local cancelArmed, cancelFor = false, nil
RunService.Heartbeat:Connect(function(dt)
	local m = driving
	if not m then
		return
	end
	local r = Runtime.Get(m)
	local c = Input.Controls
	local st = r and r.State or {}
	local speed = st.Speed or 0
	-- feux stop : pédale de frein enfoncée tant qu'on ne recule pas ; feux de recul en marche arrière
	local brake = c.Brake > 0.1 and speed > -0.5
	local reverse = (st.Gear ~= nil and st.Gear < 0) or speed < -0.5
	if r then
		r.LocalOverride = { Steer = c.Steer, Throttle = c.Throttle, Brake = brake, Reverse = reverse }
	end
	local tele = r and r.Telemetry
	for bone, k in pairs((tele and tele.TyreFx) or {}) do
		tyrePeak[bone] = math.max(tyrePeak[bone] or 0, k)
	end
	brakeHeld = brakeHeld or brake -- un coup de frein plus court qu'un envoi reste visible des autres
	-- clignotant qui s'éteint tout seul après le virage, comme sur une vraie voiture : volant tourné du côté du
	-- clignotant (> 35 %), puis revenu presque au centre
	local ind = m:GetAttribute("Indicator")
	local dir = (ind == "Left" and -1) or (ind == "Right" and 1) or 0
	if dir == 0 or ind ~= cancelFor then
		cancelArmed, cancelFor = false, ind
	end
	if dir ~= 0 then
		if c.Steer * dir > 0.35 then
			cancelArmed = true
		elseif cancelArmed and c.Steer * dir < 0.08 then
			cancelArmed = false
			set("Indicator", "Off")
		end
	end
	sendAcc += dt
	if sendAcc >= 0.1 then
		sendAcc = 0
		local packed = r and TyreFx.Pack(tyrePeak, TyreFx.Bones(r.Config)) or 0
		table.clear(tyrePeak)
		-- braquage EFFECTIF des roues en fraction de la butée mécanique (le moteur de conduite le réduit avec la
		-- vitesse) : envoyer la touche brute faisait voir aux autres des roues braquées à fond (audit 2026-11-16)
		local hd = (r and r.Config.Handling) or {}
		local mech = hd.SteeringLockRad or math.rad(hd.SteeringLockDeg or 35)
		local steerEff = (st.Steer or c.Steer) * (st.WheelSteer or mech) / math.max(mech, 1e-3)
		-- accélérateur effectif (télémétrie : S en marche arrière), pour que les autres entendent la même charge
		-- roues qui ne tournent PAS à la vitesse de la voiture (burn, patinage, roues bloquées) : vitesse de surface
		-- moyenne des roues avant / arrière (m/s), sinon nil — les autres joueurs voient les roues patiner
		-- (avant le 2026-11-16 ils les voyaient immobiles pendant un burn : « je voyais pas qu'il faisait un burnout »)
		local spinF, spinR
		local wheels = r and r.Config.Wheels
		if tele and tele.WheelSpin and wheels then
			local sf, nf, sr, nr = 0, 0, 0, 0
			for bone, w in pairs(wheels) do
				local om = tele.WheelSpin[bone]
				if om then
					local v = om * (w.Radius or 0.33)
					if w.Front then
						sf += v
						nf += 1
					else
						sr += v
						nr += 1
					end
				end
			end
			local ground = st.Speed or 0
			local f, rr = nf > 0 and sf / nf or ground, nr > 0 and sr / nr or ground
			if math.abs(f - ground) > 2 or math.abs(rr - ground) > 2 then
				spinF, spinR = f, rr
			end
		end
		telemetry:FireServer(m, st.Rpm or 0, st.Throttle or c.Throttle, steerEff, brakeHeld, reverse, st.Gear, packed, spinF, spinR)
		brakeHeld = false
	end
end)
