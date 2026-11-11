--!nonstrict
-- FiveMVehicles/VehicleDynamics (ModuleScript, pur : aucune Instance, aucun service)
-- Simulation de conduite façon GTA V à partir de VehicleConfig.Handling (handling.meta converti).
-- Tout est calculé en grandeurs SPÉCIFIQUES (m/s² = N/kg, m, m/s, rad/s) : la masse du modèle Roblox
-- n'intervient jamais ; le contrôleur (VehicleDrive) multiplie par AssemblyMass et StudsPerMeter à la frontière.
--
--   local Dyn = require(FiveMVehicles.VehicleDynamics)
--   local sim = Dyn.new(cfg, comLocalMeters, tuningOverrides)  -- cfg = require(car.VehicleConfig)
--   local out = Dyn.step(sim, inputs, contacts, dt, ctx)        -- voir le format plus bas
--
-- Repère local (celui de VehicleRoot, en mètres) : x droite, y haut, z arrière (l'avant est -z).
-- Formules : reports/Physique véhicules GTA V Roblox.md (moteur à régime normalisé 0,2 → 1, couple plat
-- jusqu'à 0,8 puis 60 % au rupteur, vitesse d'un rapport = DriveMaxFlatVel / rapport, embrayage 0,1 → 1 au
-- taux ClutchChangeRate, paires de biais (2b, 2(1−b)), traînée k·v², pneus Max / Min / Lateral).
-- Les lois encore inconnues sont des RÉGLAGES (Dyn.Tuning) : à caler sur des traces FiveM.

local Dyn = {}

-- ------------------------------------------------------------------ réglages (constantes à caler)
Dyn.Tuning = {
	KMu = 0.6, -- échelle de TractionCurveMax/Min en « g » (le jeu annonce ≈ g, valeurs d'origine 2,0–2,6)
	PeakFactor = 0.5, -- pic latéral = TractionCurveLateral × PeakFactor (litige 0,5 / 1,0)
	KappaPeak = 0.12, -- glissement longitudinal du pic (champ absent de GTA V)
	Falloff = 1.5, -- largeur (en multiples du pic) de la descente de Max vers Min
	VMin = 1.0, -- m/s : plancher de vitesse pour les glissements (anti-tremblement)
	KSpring = 1.0, -- k = SuspensionForce × biais × g / course × KSpring (hypothèse)
	BumpK = 400, -- m/s² par m au-delà de la butée de compression
	DampVMax = 1.0, -- m/s : vitesse d'amortisseur plafonnée (clapets haute vitesse, souplesse du pneu).
	--                 Sans plafond, une bordure de 15 cm à 20 km/h (5,4 m/s en une image) fait décoller l'avant.
	KArb = 1.0, -- anti-roulis : kA = AntiRollBarForce × biais × g / course × KArb (loi inconnue)
	IwRel = 0.25, -- inertie de roue + transmission, spécifique : Iw = IwRel × r² / 4 (1,5 mesuré trop lourd :
	-- la roue accélérait au rythme de la voiture et le pneu restait sous son pic, 0,26 g au lieu de ~0,6 g)
	UpshiftRpm = 0.93, -- montée de rapport (régime normalisé)
	DownshiftRpm = 0.45, -- descente de rapport (régime sous lequel on rétrograde)
	DownshiftMargin = 0.85, -- et seulement si le rapport inférieur resterait sous UpshiftRpm × marge (anti-pompage :
	-- après une montée 1→2 le régime tombe à 0,93 × 1,949 / 3,333 ≈ 0,54, mesuré)
	ReverseHold = 0.25, -- s à l'arrêt, frein maintenu, avant de passer la marche arrière
	ShiftLockout = 0.35, -- s minimum entre deux passages automatiques
	EngineBrakeG = 0.08, -- frein moteur (en g) au rupteur, gaz relâchés (proportionnel au régime)
	LowSpeedFade = 8, -- m/s : vitesse où la perte d'adhérence au démarrage (burnout) disparaît
	SteerFade = 28, -- m/s : vitesse où le braquage atteint son minimum
	SteerMinPct = 0.3, -- braquage minimal (fraction de SteeringLock) à haute vitesse
	SteerPeakGain = 1.6, -- le braquage à haute vitesse ne descend pas sous PeakGain × angle de dérive du pic
	CounterSteer = 0, -- aide au contre-braquage (rad par rad de dérive du véhicule) ; 0 = désactivée
	AbsSlip = 0.18, -- ABS : glissement au-delà duquel le frein est relâché
	AbsRelease = 0.35, -- ABS : fraction du freinage gardée quand il relâche
	HandbrakeGripRear = 0.75, -- adhérence latérale arrière frein à main serré (dérapage)
	AirPitch = 4, -- contrôle en l'air (rad/s² par unité d'entrée), tangage
	AirRoll = 3, -- contrôle en l'air, roulis
	AirDamp = 1.5, -- amortissement angulaire en l'air
	RightingK = 6, -- couple de redressement doux (rad/s² à 90°), véhicule couché et lent
	RightingSpeed = 3, -- m/s : au-dessus, pas de redressement
	GyrationSq = 1.6, -- m² : rayon de giration² nominal pour convertir accélérations angulaires en couples spécifiques
	SubSteps = 8, -- sous-pas internes (roues, embrayage, régime) ; stabilité : raideur du glissement × pas < 2
	CurbBoost = 0, -- gain de régime par compression (effet « curb boost » du jeu) ; 0 = désactivé
}

-- Rapports par défaut lus en mémoire dans le jeu (dernier rapport toujours 0,9). >= 7 rapports : étagement
-- inconnu, interpolé géométriquement entre 3,333 et 0,9 (à mesurer).
local DEFAULT_RATIOS = {
	[1] = { 0.9 },
	[2] = { 3.33, 0.9 },
	[3] = { 3.33, 1.565, 0.9 },
	[4] = { 3.33, 1.826, 1.222, 0.9 },
	[5] = { 3.33, 1.934, 1.358, 1.054, 0.9 },
	[6] = { 3.333, 1.949, 1.392, 1.095, 0.946, 0.9 },
}
local function ratiosFor(n)
	n = math.clamp(math.floor(n), 1, 10)
	if DEFAULT_RATIOS[n] then
		return table.clone(DEFAULT_RATIOS[n])
	end
	local t = {}
	for i = 1, n do
		t[i] = 3.333 * (0.9 / 3.333) ^ ((i - 1) / (n - 1))
	end
	return t
end

local MATERIAL_GRIP = { -- adhérence relative du sol (inspirée de materials.dat), 1 = route
	Asphalt = 1, Concrete = 1, Plastic = 1, SmoothPlastic = 1, Brick = 0.95, Cobblestone = 0.9, Pavement = 1,
	Wood = 0.9, WoodPlanks = 0.9, Metal = 0.9, DiamondPlate = 0.9, CorrodedMetal = 0.9, Slate = 0.95, Granite = 0.95,
	Basalt = 0.95, Rock = 0.9, Limestone = 0.9, Sandstone = 0.85, Grass = 0.7, LeafyGrass = 0.7, Ground = 0.75,
	Mud = 0.55, Sand = 0.55, Snow = 0.45, Glacier = 0.3, Ice = 0.2, Salt = 0.6, Fabric = 0.8, Foil = 0.8,
}
function Dyn.MaterialGrip(materialName)
	return MATERIAL_GRIP[materialName] or 0.9
end

local function sign(x)
	return x > 0 and 1 or (x < 0 and -1 or 0)
end

-- ------------------------------------------------------------------ paramètres + état
function Dyn.new(cfg, comLocal, overrides)
	local T = table.clone(Dyn.Tuning)
	for k, v in pairs(cfg.DriveTuning or {}) do
		T[k] = v
	end
	for k, v in pairs(overrides or {}) do
		T[k] = v
	end
	local h = cfg.Handling or {}
	local P = { T = T }
	P.g = h.GravityMs2 or 9.8
	P.gearbox = h.Gearbox or "auto"
	P.driveForce = h.DriveForce or 0.2
	P.flatVel = h.DriveMaxFlatVelMs or ((h.MaxFlatVelKmh or 140) / 3.6 * 1.2)
	P.initialFlatVel = h.MaxFlatVelMs or (P.flatVel / 1.2)
	P.nGears = (P.gearbox == "electric") and 1 or math.clamp(h.Gears or 5, 1, 10)
	P.ratios = (P.gearbox == "electric") and { 0.9 } or ratiosFor(P.nGears)
	P.reverseRatio = P.ratios[1]
	P.clutchUp = math.max(h.ClutchChangeRateUp or 1.0, 0.1)
	P.clutchDown = math.max(h.ClutchChangeRateDown or 1.0, 0.1)
	P.driveInertia = h.DriveInertia or 1
	local df, dr = h.DriveFront, h.DriveRear -- 2b / 2(1−b), seuils 0,1 / 0,9 déjà appliqués par l'export
	if df == nil then
		local b = h.DriveBiasFront or 0
		df, dr = (b < 0.1 and 0) or (b > 0.9 and 2) or 2 * b, (b < 0.1 and 2) or (b > 0.9 and 0) or 2 * (1 - b)
	end
	P.driveShareF, P.driveShareR = df / 2, dr / 2 -- fractions du couple total (somme 1)
	P.brake = h.BrakeForce or 0.8
	P.brakeF, P.brakeR = h.BrakeFront or 1, h.BrakeRear or 1
	P.handbrake = h.HandBrakeForce or 0.7
	P.muMax = (h.TractionCurveMax or 2) * T.KMu
	P.muMin = (h.TractionCurveMin or 1.8) * T.KMu
	P.alphaPeak = math.max((h.TractionCurveLateralRad or math.rad(h.TractionCurveLateralDeg or 22.5)) * T.PeakFactor, math.rad(3))
	P.tracF, P.tracR = h.TractionFront or 1, h.TractionRear or 1
	P.lossMult = h.TractionLossMult or 1
	P.lowSpeedLoss = h.LowSpeedTractionLossMult or 1
	P.rally = false
	for _, n in ipairs((h.Flags and h.Flags.Handling and h.Flags.Handling.Names) or {}) do
		if n == "HAS_RALLY_TYRES" then
			P.rally = true
		elseif n == "FREEWHEEL_NO_GAS" then
			P.freewheel = true
		elseif n == "CVT" then
			P.cvt = true
		end
	end
	for _, n in ipairs((h.Flags and h.Flags.Model and h.Flags.Model.Names) or {}) do
		if n == "ABS_STD" or n == "ABS_ALT_STD" or n == "ABS_OPTION" then
			P.abs = true
		end
	end
	for _, n in ipairs((h.CarHandling and h.CarHandling.AdvancedFlags and h.CarHandling.AdvancedFlags.Names) or {}) do
		if n == "HARD_REV_LIMIT" or n == "CF_HARD_REV_LIMIT" then
			P.hardRev = true
		end
	end
	-- suspension
	P.upper = h.SuspensionUpperLimit or 0.1
	P.lower = h.SuspensionLowerLimit or -0.15
	P.raise = h.SuspensionRaise or 0
	P.travel = math.max(P.upper - P.lower, 0.05)
	local sf = h.SuspensionForce or 2
	P.suspF, P.suspR = h.SuspensionFront or 1, h.SuspensionRear or 1
	P.kF = sf * P.suspF * P.g / P.travel * T.KSpring
	P.kR = sf * P.suspR * P.g / P.travel * T.KSpring
	P.zetaComp = 2 * (h.SuspensionCompDamp or sf / 2) / sf
	P.zetaReb = 2 * (h.SuspensionReboundDamp or sf / 2) / sf
	P.arbF = (h.AntiRollBarForce or 0) * (h.AntiRollFront or 1) * P.g / P.travel * T.KArb
	P.arbR = (h.AntiRollBarForce or 0) * (h.AntiRollRear or 1) * P.g / P.travel * T.KArb
	P.rcF, P.rcR = h.RollCentreHeightFront or 0, h.RollCentreHeightRear or 0
	-- aéro, direction
	P.dragK = h.DragAccelCoeff or ((h.DragCoeff or 10) * 1e-4)
	P.dfMod = h.DownforceModifier or 0
	P.steerLock = h.SteeringLockRad or math.rad(h.SteeringLockDeg or 35)

	-- roues : position de repos (m, repère local), rayon, rôle
	local wheels = {}
	for bone, w in pairs(cfg.Wheels or {}) do
		table.insert(wheels, {
			bone = bone,
			rest = Vector3.new(w.Position[1], w.Position[2], w.Position[3]),
			radius = math.max(w.Radius or 0.33, 0.1),
			front = w.Front == true,
			left = w.Left == true,
			steer = w.Steer == true,
		})
	end
	table.sort(wheels, function(a, b)
		return a.bone < b.bone
	end)
	local nF, nR = 0, 0
	for _, w in ipairs(wheels) do
		if w.front then
			nF += 1
		else
			nR += 1
		end
	end
	-- répartition statique de la charge selon le centre de gravité (le long de z)
	comLocal = comLocal or Vector3.zero
	local zF, zR = 0, 0
	for _, w in ipairs(wheels) do
		if w.front then
			zF += w.rest.Z / math.max(nF, 1)
		else
			zR += w.rest.Z / math.max(nR, 1)
		end
	end
	local base = math.max(zR - zF, 0.5)
	local fracF = math.clamp((zR - comLocal.Z) / base, 0.15, 0.85)
	for _, w in ipairs(wheels) do
		w.load = P.g * (w.front and fracF / math.max(nF, 1) or (1 - fracF) / math.max(nR, 1)) -- N spécifique au repos
		w.massFrac = w.load / P.g
		w.k = w.front and P.kF or P.kR
		w.driveShare = (w.front and P.driveShareF / math.max(nF, 1)) or (P.driveShareR / math.max(nR, 1))
		w.brakeBias = w.front and P.brakeF or P.brakeR
		w.trac = w.front and P.tracF or P.tracR
		w.rc = w.front and P.rcF or P.rcR
		w.Iw = T.IwRel * w.radius * w.radius / 4
		w.x0 = -P.lower -- compression au repos (depuis la détente maximale)
	end
	P.wheels = wheels
	P.nDriven = 0
	for _, w in ipairs(wheels) do
		if w.driveShare > 0 then
			P.nDriven += 1
		end
	end

	local S = {
		rpm = 0.2, gear = 1, clutch = 1, shiftDir = 0, lastShift = -1, time = 0,
		reverseTimer = 0, steerAngle = 0, lock = P.steerLock,
		omega = {}, x = {}, slip = {},
	}
	for i, w in ipairs(wheels) do
		S.omega[i] = 0
		S.x[i] = w.x0
		S.slip[i] = 0
	end
	return { P = P, S = S, T = T }
end

-- Remet l'état dynamique au repos (roues arrêtées, ralenti, 1re) : après un téléport, une remise sur
-- les roues ou une chute rattrapée, sinon les roues lancées en l'air relancent le véhicule.
function Dyn.reset(sim)
	local S, P = sim.S, sim.P
	S.rpm, S.gear, S.clutch, S.shiftDir, S.reverseTimer = 0.2, 1, 1, 0, 0
	for i, w in ipairs(P.wheels) do
		S.omega[i] = 0
		S.x[i] = w.x0
		S.slip[i] = 0
	end
end

-- ------------------------------------------------------------------ morceaux du modèle
local function torqueCurve(rpm, gear)
	if gear == 1 or rpm <= 0.8 then
		return 1
	end
	return math.max(1 - 2 * (rpm - 0.8), 0.6) -- 1 -> 0,6 entre 0,8 et 1,0
end

local function muOf(P, s)
	if P.rally then
		return P.muMin + (P.muMax - P.muMin) * math.min(s, 1)
	end
	if s <= 1 then
		return P.muMax
	end
	local t = math.min((s - 1) / P.T.Falloff, 1)
	return P.muMax + (P.muMin - P.muMax) * t
end

local function gearRatio(P, S, vf)
	if S.gear < 0 then
		return P.reverseRatio
	end
	if P.cvt then -- 5,0 au départ, 0,9 à 90 % de la vitesse plate
		local t = math.clamp(math.abs(vf) / (0.9 * P.initialFlatVel), 0, 1)
		return 5 + (0.9 - 5) * t
	end
	return P.ratios[math.clamp(S.gear, 1, P.nGears)]
end

local function shift(S, newGear, dir)
	S.gear, S.shiftDir, S.clutch, S.lastShift = newGear, dir, 0.1, S.time
end

-- downforce (« WDV ») ajoutée à l'adhérence de chaque roue, en g
local function wdv(P, v)
	if P.dfMod <= 1 then
		return 0.035
	end
	if P.dfMod <= 100 then
		local t = math.clamp(v / (0.9 * P.initialFlatVel), 0, 1)
		return P.dfMod * 0.035 * t * t
	end
	local t = math.clamp((v / P.initialFlatVel - 0.4) / 0.5, 0, 1)
	return (P.dfMod / 100) * 0.035 * (0.3 + 0.56 * t)
end

-- ------------------------------------------------------------------ pas de simulation
--[[
inputs : { Throttle 0..1, Brake 0..1, Steer -1..1, Handbrake bool, Engine bool, GearUp bool, GearDown bool }
contacts[i] (même ordre que sim.P.wheels) :
  { grounded, x (m, compression depuis la détente max), xdot (m/s, + = se comprime), vLong, vLat (m/s, repère roue :
    avant / droite), grip (adhérence du sol 0..1) }
ctx : { vBody (Vector3 m/s, repère local), wBody (Vector3 rad/s, local), up (haut du monde exprimé en local) }
renvoie out :
  wheels[i] = { Fz, Fx, Fy (m/s², repère roue : haut / avant / droite), steer (rad), point (Vector3 m, local) }
  body = Vector3 (m/s², local) : traînée ; torque = Vector3 (couple spécifique m²/s², local) : aides
  rpm (0,2..1), gear (-1 = arrière), clutch, speed (m/s, + avant), omega[i], travel[i] (m, + = vers le haut),
  lock (rad), steerAngle (rad), reverse (bool)
]]
function Dyn.step(sim, inp, contacts, dt, ctx)
	local P, S, T = sim.P, sim.S, sim.T
	dt = math.clamp(dt, 1 / 480, 1 / 15)
	S.time += dt
	local vBody = ctx.vBody or Vector3.zero
	local vf = -vBody.Z -- vitesse vers l'avant
	local speed = vBody.Magnitude
	local engineOn = inp.Engine ~= false

	-- marche arrière façon GTA : à l'arrêt, frein maintenu -> arrière ; en arrière, « frein » accélère
	local throttle, brake = inp.Throttle or 0, inp.Brake or 0
	if S.gear >= 1 then
		if brake > 0.1 and throttle < 0.05 and vf < 0.8 then
			S.reverseTimer += dt
			if S.reverseTimer >= T.ReverseHold then
				S.gear, S.clutch, S.reverseTimer = -1, 1, 0
			end
		else
			S.reverseTimer = 0
		end
	else
		if throttle > 0.1 and brake < 0.05 and vf > -0.8 then
			S.reverseTimer += dt
			if S.reverseTimer >= T.ReverseHold * 0.5 then
				S.gear, S.clutch, S.reverseTimer = 1, 1, 0
			end
		else
			S.reverseTimer = 0
		end
	end
	local driveIn, brakeIn
	if S.gear < 0 then
		driveIn, brakeIn = brake, throttle
	else
		driveIn, brakeIn = throttle, brake
	end
	if not engineOn then
		driveIn = 0
	end

	-- rapports manuels (impulsions)
	if inp.GearUp and S.gear >= 1 and S.gear < P.nGears then
		shift(S, S.gear + 1, 1)
	elseif inp.GearDown and S.gear > 1 then
		shift(S, S.gear - 1, -1)
	end

	-- direction : braquage réduit avec la vitesse
	local target = math.max(P.alphaPeak * T.SteerPeakGain, P.steerLock * T.SteerMinPct)
	local lock = P.steerLock + (math.min(target, P.steerLock) - P.steerLock) * math.clamp(math.abs(vf) / T.SteerFade, 0, 1)
	local beta = (math.abs(vf) > 2) and math.atan2(vBody.X, math.abs(vf)) or 0
	S.lock = lock
	S.steerAngle = math.clamp(-(inp.Steer or 0) * lock + T.CounterSteer * beta, -P.steerLock, P.steerLock)

	-- suspension -> charges normales
	local N = {}
	for i, w in ipairs(P.wheels) do
		local c = contacts[i]
		if c and c.grounded then
			local x, xdot = c.x, c.xdot
			local mc = w.massFrac
			local zeta = (xdot > 0) and P.zetaComp or P.zetaReb
			local cd = zeta * 2 * math.sqrt(w.k * mc)
			cd = cd / (1 + cd * dt / mc) -- amortisseur semi-implicite
			local F = w.load + w.k * (x - w.x0) + cd * math.clamp(xdot, -T.DampVMax, T.DampVMax)
			if x > P.travel then
				F += T.BumpK * (x - P.travel)
			end
			N[i] = math.max(F, 0)
			S.x[i] = x
		else
			N[i] = 0
			S.x[i] = 0
		end
	end
	-- anti-roulis par essieu
	for _, front in ipairs({ true, false }) do
		local l, r
		for i, w in ipairs(P.wheels) do
			if w.front == front then
				if w.left then
					l = l or i
				else
					r = r or i
				end
			end
		end
		if l and r and N[l] > 0 and N[r] > 0 then
			local kA = front and P.arbF or P.arbR
			local dF = kA * (S.x[l] - S.x[r])
			N[l] = math.max(N[l] + dF, 0)
			N[r] = math.max(N[r] - dF, 0)
		end
	end

	-- aides : perte d'adhérence au démarrage, déportance
	local lowF = (driveIn > 0.3) and math.clamp(1 - speed / T.LowSpeedFade, 0, 1) or 0
	local lowGrip = 1 / (1 + P.lowSpeedLoss * lowF)
	local extraGrip = wdv(P, speed) * P.g

	-- à l'arrêt sans gaz ni frein, le véhicule se tient (ne roule pas tout seul en pente), comme dans le jeu
	local hold = (driveIn < 0.05 and math.abs(vf) < 0.6) and 0.5 or 0

	-- sous-pas : régime, embrayage, roues, pneus
	local nSub = math.max(1, T.SubSteps)
	local h = dt / nSub
	local sumFx, sumFy = {}, {}
	for i in ipairs(P.wheels) do
		sumFx[i], sumFy[i] = 0, 0
	end
	for _ = 1, nSub do
		-- vitesse périphérique moyenne des roues motrices
		local drivenSpeed, nd = 0, 0
		for i, w in ipairs(P.wheels) do
			if w.driveShare > 0 then
				drivenSpeed += math.abs(S.omega[i]) * w.radius
				nd += 1
			end
		end
		drivenSpeed = nd > 0 and drivenSpeed / nd or math.abs(vf)
		local ratio = gearRatio(P, S, vf)
		local gearTop = P.flatVel / math.abs(ratio)
		if S.clutch < 1 then
			S.clutch = math.min(1, S.clutch + ((S.shiftDir >= 0) and P.clutchUp or P.clutchDown) * h)
		end
		local thr = (S.clutch < 1) and 0 or driveIn
		local free = math.clamp(S.rpm + (2 * thr - 1) * 2 * P.driveInertia * h, 0.2, 1)
		local wheelRpm = drivenSpeed / gearTop
		S.rpm = math.clamp(math.max(0.2, wheelRpm * S.clutch + free * (1 - S.clutch)), 0.2, 1.05)
		if not engineOn then
			S.rpm = math.max(wheelRpm, 0)
		end
		local cut = 1
		if S.rpm >= 1 then
			if P.hardRev then
				cut = 0
			elseif S.gear == P.nGears and not P.cvt then
				S.clutch = math.min(S.clutch, 0.1) -- le jeu laisse retomber l'embrayage au rupteur
			end
		end
		-- boîte automatique
		if P.gearbox ~= "manual" and not P.cvt and S.clutch >= 1 and S.gear >= 1 and S.time - S.lastShift > T.ShiftLockout then
			if S.rpm > T.UpshiftRpm and S.gear < P.nGears and driveIn > 0.05 then
				shift(S, S.gear + 1, 1)
			elseif S.gear > 1 and S.rpm < T.DownshiftRpm
				and S.rpm * P.ratios[S.gear - 1] / ratio < T.UpshiftRpm * T.DownshiftMargin then
				shift(S, S.gear - 1, -1)
			end
		end
		local dir = (S.gear < 0) and -1 or 1
		local aDrive = P.driveForce * math.abs(ratio) * torqueCurve(S.rpm, S.gear) * thr * S.clutch * cut * P.g * dir
		-- frein moteur, gaz relâchés, embrayé (sauf FREEWHEEL_NO_GAS)
		local engBrake = (not P.freewheel and thr < 0.05 and S.clutch >= 1 and engineOn) and T.EngineBrakeG * P.g * (S.rpm - 0.2) / 0.8 or 0

		for i, w in ipairs(P.wheels) do
			local c = contacts[i] or { grounded = false, vLong = 0, vLat = 0, grip = 1 }
			local vLong, vLat = c.vLong or 0, c.vLat or 0
			local aW = aDrive * w.driveShare
			-- « g par roue » × biais d'essieu (2b) : BrakeForce = 1 demande ≈ 4 g en tout ; la roue bloque dès que
			-- BrakeForce > adhérence / 4 (règle connue du jeu), l'ABS relâche alors
			local brakeA = P.brake * math.max(brakeIn, hold) * w.brakeBias * P.g
			local hand = inp.Handbrake and not w.front
			if hand then
				brakeA += P.handbrake * P.g
			end
			if w.driveShare > 0 and engBrake > 0 then
				brakeA += engBrake * w.driveShare
			end
			local omega = S.omega[i]
			local Fx, Fy = 0, 0
			if c.grounded and N[i] > 0 then
				local vRef = math.max(math.abs(vLong), T.VMin)
				local kappa = (omega * w.radius - vLong) / vRef
				local alpha = math.atan2(vLat, vRef)
				local sk, sa = kappa / T.KappaPeak, alpha / P.alphaPeak
				local s = math.sqrt(sk * sk + sa * sa)
				S.slip[i] = s
				local grip = 1 - (1 - (c.grip or 1)) * P.lossMult
				local fmax = (N[i] * muOf(P, s) * w.trac * (w.driveShare > 0 and lowGrip or 1) + extraGrip * w.massFrac * 4) * grip
				if s > 1e-6 then
					local F = fmax * math.min(s, 1)
					Fx = F * sk / s
					Fy = -F * sa / s
				end
				if hand then
					Fy *= T.HandbrakeGripRear
				end
				-- à basse vitesse, ne jamais renvoyer plus que la vitesse latérale à annuler (pas de tremblement)
				local kill = math.abs(vLat) * w.massFrac / dt
				if math.abs(Fy) > kill then
					Fy = sign(Fy) * kill
				end
				-- ABS
				if P.abs and brakeIn > 0 and not hand and kappa < -T.AbsSlip then
					brakeA *= T.AbsRelease
				end
				-- roue : couple moteur, réaction du sol, frein (qui ne peut pas inverser ω)
				local wDrive = (aW - Fx) * w.radius / w.Iw
				local slipBefore = omega * w.radius - vLong
				local o = omega + wDrive * h
				local dB = brakeA * w.radius / w.Iw * h
				if math.abs(o) <= dB then
					o = 0
				else
					o -= sign(o) * dB
				end
				-- pas de dépassement du roulement libre (stabilité des sous-pas)
				if aW == 0 and brakeA == 0 then
					o = vLong / w.radius
				elseif sign(o * w.radius - vLong) ~= sign(slipBefore) and slipBefore ~= 0 and aW * sign(slipBefore) <= 0 then
					o = vLong / w.radius
				end
				S.omega[i] = o
			else
				-- en l'air : la roue tourne librement (moteur), se freine, perd lentement sa vitesse
				local o = omega + (aW * w.radius / w.Iw - 0.5 * omega) * h
				local dB = brakeA * w.radius / w.Iw * h
				if math.abs(o) <= dB then
					o = 0
				else
					o -= sign(o) * dB
				end
				S.omega[i] = o
				S.slip[i] = 0
			end
			sumFx[i] += Fx
			sumFy[i] += Fy
		end
	end

	-- sorties
	local out = {
		wheels = {}, omega = {}, travel = {}, rpm = S.rpm, gear = S.gear, clutch = S.clutch,
		speed = vf, lock = lock, steerAngle = S.steerAngle, reverse = S.gear < 0,
	}
	for i, w in ipairs(P.wheels) do
		local x = S.x[i]
		local wheelCenter = w.rest + Vector3.new(0, P.upper + P.raise - (P.travel - x), 0)
		local contactY = wheelCenter.Y - w.radius
		out.wheels[i] = {
			Fz = N[i],
			Fx = sumFx[i] / nSub,
			Fy = sumFy[i] / nSub,
			steer = w.steer and S.steerAngle or 0,
			point = Vector3.new(wheelCenter.X, contactY, wheelCenter.Z), -- contact (charge normale)
			lateralPoint = Vector3.new(wheelCenter.X, contactY + w.rc, wheelCenter.Z), -- centre de roulis
		}
		out.omega[i] = S.omega[i]
		out.travel[i] = (contacts[i] and contacts[i].grounded) and (x - w.x0) or (-w.x0)
	end
	-- traînée (omnidirectionnelle, au centre de gravité)
	out.body = -vBody * (P.dragK * speed)
	-- aides angulaires (couples spécifiques, repère local)
	local torque = Vector3.zero
	local grounded = 0
	for i in ipairs(P.wheels) do
		if contacts[i] and contacts[i].grounded then
			grounded += 1
		end
	end
	local w = ctx.wBody or Vector3.zero
	if grounded == 0 then
		-- en l'air : tangage aux gaz / frein, roulis à la direction, amorti
		local pitch = ((inp.Brake or 0) - (inp.Throttle or 0)) * T.AirPitch -- W pique du nez, S le relève
		local roll = -(inp.Steer or 0) * T.AirRoll
		torque += (Vector3.new(pitch, 0, roll) - w * T.AirDamp) * T.GyrationSq
	end
	local up = ctx.up or Vector3.yAxis
	if up.Y < 0.7 and speed < T.RightingSpeed and grounded < #P.wheels then
		-- couché ou presque : couple doux vers la position droite
		local axis = Vector3.yAxis:Cross(up)
		torque += (axis * T.RightingK - w * 1.0) * T.GyrationSq
	end
	out.torque = torque
	return out
end

-- Vitesse de pointe théorique (m/s) : là où la poussée du dernier rapport égale la traînée (sans adhérence).
function Dyn.PredictTopSpeed(sim)
	local P = sim.P
	local ratio = P.ratios[P.nGears]
	local gearTop = P.flatVel / ratio
	local best = 0
	for i = 1, 400 do
		local v = gearTop * 1.1 * i / 400
		local rpm = v / gearTop
		local a = P.driveForce * ratio * torqueCurve(rpm, P.nGears) * P.g
		if P.hardRev and rpm >= 1 then
			a = 0
		end
		if a >= P.dragK * v * v then
			best = v
		end
	end
	return best
end

return Dyn
