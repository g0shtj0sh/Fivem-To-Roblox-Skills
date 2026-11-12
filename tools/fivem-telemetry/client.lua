--[[
    vehicle-telemetry / client.lua

    Conduit le vehicule TOUT SEUL en imposant les entrees a chaque image, et
    enregistre l'etat complet du vehicule image par image.

    Les essais reprennent exactement ceux du banc Roblox (roblox/DriveBench.lua)
    pour que les deux colonnes de chiffres soient comparables : memes consignes,
    memes durees, meme tenue de ligne en ligne droite.

    Entrees imposees (controls GTA) :
      71 INPUT_VEH_ACCELERATE   0..1
      72 INPUT_VEH_BRAKE        0..1
      59 INPUT_VEH_MOVE_LR     -1..1   (mesure : +1 = DROITE, voir applyInputs)
      76 INPUT_VEH_HANDBRAKE    0..1

    Convention : steer +1 = DROITE, identique au banc Roblox.
]]

local CTL <const> = { accel = 71, brake = 72, steer = 59, handbrake = 76 }

-- Controles neutralises pendant un essai : le joueur ne doit pas pouvoir
-- perturber la mesure, ni sortir du vehicule.
-- Controles neutralises : TOUT sauf la conduite.
-- Les quatre controles de conduite ne doivent PAS etre desactives : sur ce build,
-- DisableControlAction masque aussi la valeur injectee par SetControlNormal, et le
-- vehicule ne recoit plus rien (mesure : thrOff reste a 0, regime 0,20, rapport 0).
-- Le joueur est de toute facon sans effet, puisqu'on reecrit la valeur chaque image.
local BLOCKED <const> = {
    75,                        -- sortir du vehicule
    21, 22, 23, 24, 25, 257,   -- sprint / saut / entrer / tir
    80, 82, 85, 86,            -- radio / klaxon
    73,                        -- cabrer / acrobaties
    99, 100,                   -- changement de vue
}

local running = false
local abortFlag = false
local cur = { throttle = 0.0, brake = 0.0, steer = 0.0, handbrake = false }

local function r(x, n)
    if x == nil then return nil end
    local m = 10 ^ (n or 3)
    return math.floor(x * m + 0.5) / m
end

-- ------------------------------------------------------------------ entrees

--- Impose les entrees courantes pour l'image en cours.
local function applyInputs()
    for i = 1, #BLOCKED do
        DisableControlAction(0, BLOCKED[i], true)
    end
    SetControlNormal(0, CTL.accel, cur.throttle + 0.0)
    SetControlNormal(0, CTL.brake, cur.brake + 0.0)
    -- Mesure (essai « raw ») : sur le control 59, +1 donne un angle de roue
    -- NEGATIF et fait DECROITRE le cap. Or dans GTA le cap croit vers la gauche
    -- (0 = nord, 90 = ouest) : un cap qui decroit, c'est donc un virage a DROITE.
    -- La convention est la meme que celle du banc Roblox (+1 = droite) : rien a
    -- inverser ici.
    SetControlNormal(0, CTL.steer, cur.steer + 0.0)
    SetControlNormal(0, CTL.handbrake, cur.handbrake and 1.0 or 0.0)
end

--- Boucle d'entrees : tourne pendant toute la duree d'un essai.
CreateThread(function()
    while true do
        if running then
            applyInputs()
            Wait(0)
        else
            Wait(100)
        end
    end
end)

-- -------------------------------------------------------------- echantillon

local COLUMNS <const> = {
    't', 'dt', 'thr', 'brk', 'str', 'hb',
    'speed', 'vLat', 'vFwd', 'vUp',
    'px', 'py', 'pz',
    'pitch', 'roll', 'heading',
    'wx', 'wy', 'wz',
    'rpm', 'gear', 'nextGear', 'highGear', 'clutch', 'thrOff', 'steerAngle',
    'wheelsOnGround', 'onAllWheels', 'heightAbove', 'dashSpeed', 'accel',
    -- par roue 0..3 : vitesse, compression, braquage, traction, puissance, frein,
    -- vitesse de rotation, materiau du sol
    'w0spd', 'w0sus', 'w0str', 'w0trc', 'w0pow', 'w0brk', 'w0rot', 'w0mat',
    'w1spd', 'w1sus', 'w1str', 'w1trc', 'w1pow', 'w1brk', 'w1rot', 'w1mat',
    'w2spd', 'w2sus', 'w2str', 'w2trc', 'w2pow', 'w2brk', 'w2rot', 'w2mat',
    'w3spd', 'w3sus', 'w3str', 'w3trc', 'w3pow', 'w3brk', 'w3rot', 'w3mat',
}

local t0 = 0
local nWheels = 4

--- Ce build n'expose pas GetVehicleNumberOfWheelsTouchingSurface : on compte les
--- roues dont le materiau du sol est renseigne (0 = aucun contact).
local function wheelsOnGround(veh)
    local n = 0
    for i = 0, nWheels - 1 do
        local m = GetVehicleWheelSurfaceMaterial(veh, i)
        if m and m ~= 0 and m ~= -1 then n = n + 1 end
    end
    return n
end

local function sample(veh)
    local pos = GetEntityCoords(veh)
    local rot = GetEntityRotation(veh, 2)          -- x = tangage, y = roulis, z = cap
    local rv = GetEntityRotationVelocity(veh)       -- rad/s, repere monde
    local sv = GetEntitySpeedVector(veh, true)      -- repere vehicule : x droite, y avant, z haut

    local row = {
        r(GetGameTimer() - t0, 0), r(GetFrameTime(), 5),
        r(cur.throttle, 3), r(cur.brake, 3), r(cur.steer, 3), cur.handbrake and 1 or 0,
        r(GetEntitySpeed(veh), 4), r(sv.x, 4), r(sv.y, 4), r(sv.z, 4),
        r(pos.x, 3), r(pos.y, 3), r(pos.z, 3),
        r(rot.x, 3), r(rot.y, 3), r(rot.z, 3),
        r(rv.x, 4), r(rv.y, 4), r(rv.z, 4),
        r(GetVehicleCurrentRpm(veh), 4), GetVehicleCurrentGear(veh),
        GetVehicleNextGear(veh), GetVehicleHighGear(veh),
        r(GetVehicleClutch(veh), 4), r(GetVehicleThrottleOffset(veh), 4),
        r(GetVehicleSteeringAngle(veh), 3),
        wheelsOnGround(veh), IsVehicleOnAllWheels(veh) and 1 or 0,
        r(GetEntityHeightAboveGround(veh), 3),
        r(GetVehicleDashboardSpeed(veh), 3), r(GetVehicleAcceleration(veh), 4),
    }

    for i = 0, 3 do
        row[#row + 1] = r(GetVehicleWheelSpeed(veh, i), 4)
        row[#row + 1] = r(GetVehicleWheelSuspensionCompression(veh, i), 5)
        row[#row + 1] = r(GetVehicleWheelSteeringAngle(veh, i), 4)
        row[#row + 1] = r(GetVehicleWheelTractionVectorLength(veh, i), 4)
        row[#row + 1] = r(GetVehicleWheelPower(veh, i), 3)
        row[#row + 1] = r(GetVehicleWheelBrakePressure(veh, i), 4)
        row[#row + 1] = r(GetVehicleWheelRotationSpeed(veh, i), 4)
        row[#row + 1] = GetVehicleWheelSurfaceMaterial(veh, i)
    end
    return row
end

-- -------------------------------------------------------------- handling

local HANDLING_FLOATS <const> = {
    'fMass', 'fInitialDragCoeff', 'fPercentSubmerged', 'fDriveBiasFront',
    'fInitialDriveForce', 'fDriveInertia', 'fClutchChangeRateScaleUpShift',
    'fClutchChangeRateScaleDownShift', 'fInitialDriveMaxFlatVel',
    'fBrakeForce', 'fBrakeBiasFront', 'fHandBrakeForce',
    'fSteeringLock', 'fTractionCurveMax', 'fTractionCurveMin',
    'fTractionCurveLateral', 'fTractionSpringDeltaMax', 'fLowSpeedTractionLossMult',
    'fCamberStiffnesss', 'fTractionBiasFront', 'fTractionLossMult',
    'fSuspensionReboundDamp', 'fSuspensionCompDamp', 'fSuspensionForce',
    'fSuspensionUpperLimit', 'fSuspensionLowerLimit', 'fSuspensionRaise',
    'fSuspensionBiasFront', 'fAntiRollBarForce', 'fAntiRollBarBiasFront',
    'fRollCentreHeightFront', 'fRollCentreHeightRear',
    'fCollisionDamageMult', 'fWeaponDamageMult', 'fDeformationDamageMult',
    'fEngineDamageMult', 'fPetrolTankVolume', 'fOilVolume',
    'fSeatOffsetDistX', 'fSeatOffsetDistY', 'fSeatOffsetDistZ',
}
local HANDLING_INTS <const> = { 'nInitialDriveGears', 'nMonetaryValue', 'strModelFlags', 'strHandlingFlags', 'strDamageFlags' }
local HANDLING_VECS <const> = { 'vecCentreOfMassOffset', 'vecInertiaMultiplier' }

local function readHandling(veh)
    local h = { floats = {}, ints = {}, vectors = {} }
    for _, k in ipairs(HANDLING_FLOATS) do
        local ok, v = pcall(GetVehicleHandlingFloat, veh, 'CHandlingData', k)
        if ok then h.floats[k] = r(v, 5) end
    end
    for _, k in ipairs(HANDLING_INTS) do
        local ok, v = pcall(GetVehicleHandlingInt, veh, 'CHandlingData', k)
        if ok then h.ints[k] = v end
    end
    for _, k in ipairs(HANDLING_VECS) do
        local ok, v = pcall(GetVehicleHandlingVector, veh, 'CHandlingData', k)
        if ok and v then h.vectors[k] = { r(v.x, 5), r(v.y, 5), r(v.z, 5) } end
    end
    return h
end

-- ------------------------------------------------------------- environnement

local function prepareWorld()
    SetWeatherTypeNowPersist('EXTRASUNNY')
    SetWeatherTypePersist('EXTRASUNNY')
    NetworkOverrideClockTime(12, 0, 0)
    SetRainLevel(0.0)
    SetWindSpeed(0.0)
end

CreateThread(function()
    while true do
        -- Pas de trafic ni de pietons : ils fausseraient les essais.
        SetVehicleDensityMultiplierThisFrame(0.0)
        SetRandomVehicleDensityMultiplierThisFrame(0.0)
        SetParkedVehicleDensityMultiplierThisFrame(0.0)
        SetPedDensityMultiplierThisFrame(0.0)
        SetScenarioPedDensityMultiplierThisFrame(0.0, 0.0)
        if running then
            SetPlayerWantedLevel(PlayerId(), 0, false)
            SetPlayerWantedLevelNow(PlayerId(), false)
        end
        Wait(0)
    end
end)

-- --------------------------------------------------------------- utilitaires

local function veh()
    local ped = PlayerPedId()
    local v = GetVehiclePedIsIn(ped, false)
    if v == 0 then return nil, 'le joueur n est pas dans un vehicule' end
    if GetPedInVehicleSeat(v, -1) ~= ped then return nil, 'le joueur n est pas au volant' end
    return v
end

local function speedKmh(v) return GetEntitySpeed(v) * 3.6 end

--- Vitesse signee dans l'axe du vehicule (m/s, + vers l'avant).
local function fwdSpeed(v)
    return GetEntitySpeedVector(v, true).y
end

local line = nil   -- { pos = vec3, fwd = vec3, right = vec3 }

local function setLine(v)
    local p = GetEntityCoords(v)
    local f = GetEntityForwardVector(v)
    line = {
        px = p.x, py = p.y,
        fx = f.x, fy = f.y,
        rx = f.y, ry = -f.x,    -- vecteur droite = forward tourne de -90 deg
    }
end

--- Tenue de ligne : corrige l'ecart lateral et le cap, comme un conducteur.
--- Sans elle une dissymetrie minime fait deriver sur un tres grand rayon.
local function lineSteer(v)
    if not line then return 0.0 end
    local p = GetEntityCoords(v)
    local f = GetEntityForwardVector(v)
    local dx, dy = p.x - line.px, p.y - line.py
    local off = dx * line.rx + dy * line.ry                 -- m a droite de la ligne
    local heading = math.atan(f.x * line.rx + f.y * line.ry,
                              f.x * line.fx + f.y * line.fy) -- rad, + = vers la droite
    local s = -(off * 0.15 + heading * 3.0)
    return math.max(-0.4, math.min(0.4, s))
end

local samples = {}
local pendingRows = {}

local function record(v)
    pendingRows[#pendingRows + 1] = sample(v)
    samples[#samples + 1] = true
end

local CHUNK <const> = 250
local curLabel = nil

local function flush(force)
    if #pendingRows == 0 then return end
    if force or #pendingRows >= CHUNK then
        TriggerServerEvent('vt:chunk', curLabel, pendingRows)
        pendingRows = {}
    end
end

--- Boucle centrale : pose les entrees, avance d'une image, enregistre.
--- `inputs` est une table fixe ou une fonction (v) -> table (regulateurs).
--- `each(t, v)` peut renvoyer true pour arreter. `keepLine` branche la tenue de ligne.
local function hold(v, inputs, seconds, each, keepLine)
    local start = GetGameTimer()
    while (GetGameTimer() - start) / 1000.0 < seconds do
        if abortFlag then return false end
        local i = type(inputs) == 'function' and inputs(v) or inputs
        cur.throttle = i.throttle or 0.0
        cur.brake = i.brake or 0.0
        cur.handbrake = i.handbrake or false
        cur.steer = keepLine and lineSteer(v) or (i.steer or 0.0)
        Wait(0)
        record(v)
        flush(false)
        if each then
            local t = (GetGameTimer() - start) / 1000.0
            if each(t, v) then return true end
        end
    end
    return true
end

--- Immobilise le vehicule. Frein maintenu a l'arret = marche arriere dans GTA :
--- en marche arriere, c'est l'accelerateur qui freine.
local function settle(v, seconds)
    local start = GetGameTimer()
    while (GetGameTimer() - start) / 1000.0 < (seconds or 6) do
        if abortFlag then return end
        if fwdSpeed(v) < -0.5 then
            cur.throttle, cur.brake, cur.handbrake, cur.steer = 1.0, 0.0, false, 0.0
        else
            cur.throttle, cur.brake, cur.handbrake, cur.steer = 0.0, 1.0, false, 0.0
        end
        Wait(0)
        if math.abs(fwdSpeed(v)) < 0.2 then break end
    end
    cur.throttle, cur.brake, cur.handbrake, cur.steer = 0.0, 0.0, false, 0.0
    Wait(300)
end

--- Repare, remet a plat, moteur tournant, a l'arret, au point de depart.
local function resetAt(v, x, y, z, heading)
    SetEntityCoordsNoOffset(v, x + 0.0, y + 0.0, z + 0.0, false, false, false)
    SetEntityHeading(v, heading + 0.0)
    SetEntityVelocity(v, 0.0, 0.0, 0.0)
    SetEntityRotation(v, 0.0, 0.0, heading + 0.0, 2, true)
    SetVehicleOnGroundProperly(v)
    SetVehicleFixed(v)
    SetVehicleDeformationFixed(v)
    SetVehicleEngineOn(v, true, true, false)
    SetVehicleEngineHealth(v, 1000.0)
    SetVehicleFuelLevel(v, 100.0)
    SetVehicleDirtLevel(v, 0.0)
    SetVehicleUndriveable(v, false)
    Wait(600)
    SetEntityVelocity(v, 0.0, 0.0, 0.0)
    Wait(400)
end

-- ------------------------------------------------------------------ essais

local Tests = {}

--- Plein gaz : 0-60, 0-100, vitesse de pointe, passages de rapports.
function Tests.accel(v, p)
    local maxSeconds = p.seconds or 30
    settle(v)
    setLine(v)
    local res = { shifts = {} }
    local p0 = GetEntityCoords(v)
    local lastGear = GetVehicleCurrentGear(v)
    local lastV, lastT, plateau = 0.0, GetGameTimer(), 0

    hold(v, { throttle = 1.0 }, maxSeconds, function(t)
        local kmh = speedKmh(v)
        if not res.t60 and kmh >= 60 then res.t60 = r(t, 3) end
        if not res.t100 and kmh >= 100 then res.t100 = r(t, 3) end
        if not res.t150 and kmh >= 150 then res.t150 = r(t, 3) end
        local g = GetVehicleCurrentGear(v)
        if g ~= lastGear then
            res.shifts[#res.shifts + 1] = {
                from = lastGear, to = g, kmh = r(kmh, 1),
                rpm = r(GetVehicleCurrentRpm(v), 3), t = r(t, 3),
            }
            lastGear = g
        end
        res.vmax = math.max(res.vmax or 0, r(kmh, 2))
        if GetGameTimer() - lastT >= 2000 then
            plateau = (kmh - lastV < 0.3) and (plateau + 1) or 0
            lastV, lastT = kmh, GetGameTimer()
            if plateau >= 1 and kmh > 30 then
                res.plateauAt = r(t, 2)
                return true
            end
        end
        return false
    end, true)

    local p1 = GetEntityCoords(v)
    res.distance = r(#(p1 - p0), 2)
    res.endGear = GetVehicleCurrentGear(v)
    settle(v)
    return res
end

--- Freinage depuis `fromKmh`. Au frein a main, aucune correction de volant :
--- c'est justement le lacet qu'on veut mesurer.
local function brakeTest(v, p, handbrake)
    local from = p.fromKmh or (handbrake and 60 or 100)
    settle(v)
    setLine(v)
    hold(v, { throttle = 1.0 }, 60, function() return speedKmh(v) >= from end, true)

    local p0 = GetEntityCoords(v)
    local v0 = fwdSpeed(v)
    local res = { from = r(speedKmh(v), 2), handbrake = handbrake and true or false }
    local inputs = handbrake and { handbrake = true } or { brake = 1.0 }
    hold(v, inputs, 20, function(t)
        local wz = GetEntityRotationVelocity(v).z
        res.maxYaw = math.max(res.maxYaw or 0, math.abs(wz) * 180.0 / math.pi)
        res.maxRoll = math.max(res.maxRoll or 0, math.abs(GetEntityRotation(v, 2).y))
        if GetEntitySpeed(v) < 0.3 then
            res.time = r(t, 3)
            return true
        end
        return false
    end, not handbrake)

    res.distance = r(#(GetEntityCoords(v) - p0), 2)
    res.maxYaw = r(res.maxYaw, 2)
    res.maxRoll = r(res.maxRoll, 2)
    if res.time and res.time > 0 then res.decelG = r(v0 / res.time / 9.81, 3) end
    settle(v)
    return res
end

function Tests.brake(v, p) return brakeTest(v, p, false) end
function Tests.handbrake(v, p) return brakeTest(v, p, true) end

--- Virage plein braquage a vitesse tenue : roulis, lacet, derive, acceleration laterale.
function Tests.corner(v, p)
    local kmh = p.kmh or 40
    local steer = p.steer or 1.0
    local seconds = p.seconds or 4
    settle(v)
    setLine(v)
    hold(v, { throttle = 1.0 }, 60, function() return speedKmh(v) >= kmh end, true)

    local res = { kmh = kmh, steer = steer }
    local p0 = GetEntityCoords(v)
    -- memoire d'une image pour l'acceleration laterale : en repere tournant a_lat = d(vLat)/dt - wz*vFwd.
    -- Le terme -wz*vFwd seul ne vaut qu'en regime ETABLI ; il surevalue de 9 a 11 % un virage pris en
    -- transitoire (mesure : virage 80, slalom). Voir tools/drive-compare/analyze.luau.
    -- Ici la derivee porte sur UNE image (l'analyseur, lui, centre sur deux) : le bruit gonfle le maximum
    -- de 0,1 a 2,2 % sur les traces, contre 8 a 15 % d'erreur enlevee. La premiere image retombe sur
    -- -wz*vFwd, faute de precedente.
    local prevLat, prevT = nil, nil
    hold(v, function()
        local err = kmh / 3.6 - fwdSpeed(v)
        return { throttle = math.max(0.0, math.min(1.0, 0.4 + err * 0.4)), steer = steer }
    end, seconds, function()
        local rot = GetEntityRotation(v, 2)
        local sv = GetEntitySpeedVector(v, true)
        local wz = GetEntityRotationVelocity(v).z
        local now = GetGameTimer()
        local dLat = nil
        if prevLat and prevT and now > prevT then
            dLat = (sv.x - prevLat) / ((now - prevT) / 1000.0)
        end
        prevLat, prevT = sv.x, now
        res.maxRoll = math.max(res.maxRoll or 0, math.abs(rot.y))
        res.maxYawRate = math.max(res.maxYawRate or 0, math.abs(wz) * 180.0 / math.pi)
        res.minWheels = math.min(res.minWheels or 4, wheelsOnGround(v))
        if math.abs(sv.y) > 2 then
            res.maxSlip = math.max(res.maxSlip or 0,
                math.abs(math.deg(math.atan(sv.x, math.abs(sv.y)))))
            res.maxLatG = math.max(res.maxLatG or 0,
                math.abs((dLat or 0.0) - wz * sv.y) / 9.81)
        end
        return false
    end, false)

    res.endSpeed = r(speedKmh(v), 2)
    res.maxRoll = r(res.maxRoll, 3)
    res.maxYawRate = r(res.maxYawRate, 2)
    res.maxSlip = r(res.maxSlip, 2)
    res.maxLatG = r(res.maxLatG, 3)
    -- rayon moyen sur la portion stabilisee : v / lacet
    if res.maxYawRate and res.maxYawRate > 1 then
        res.radiusAtMaxYaw = r((kmh / 3.6) / math.rad(res.maxYawRate), 2)
    end
    res.displacement = r(#(GetEntityCoords(v) - p0), 2)
    settle(v)
    return res
end

--- Marche arriere : frein maintenu a l'arret.
function Tests.reverse(v, p)
    local seconds = p.seconds or 4
    settle(v)
    setLine(v)
    local res = {}
    local p0 = GetEntityCoords(v)
    hold(v, { brake = 1.0 }, seconds, function()
        res.minSpeed = math.min(res.minSpeed or 0, fwdSpeed(v) * 3.6)
        res.gear = GetVehicleCurrentGear(v)
        return false
    end, false)
    res.minSpeed = r(res.minSpeed, 2)
    res.distance = r(#(GetEntityCoords(v) - p0), 2)
    settle(v)
    return res
end

local function cruise(v, kmh)
    local err = kmh / 3.6 - fwdSpeed(v)
    if err < -1.5 then
        return 0.0, math.max(0.0, math.min(1.0, -err * 0.3))
    end
    return math.max(0.0, math.min(1.0, 0.25 + err * 0.5)), 0.0
end

--- Bordure prise de face a vitesse tenue : tangage, roues en l'air, vitesse perdue.
function Tests.curb(v, p)
    local kmh = p.kmh or 20
    local untilMeters = p.untilMeters or 160
    settle(v)
    setLine(v)
    local res = { kmh = kmh, maxPitch = 0, maxRoll = 0, minWheels = 4, airborneFrames = 0 }
    local p0 = GetEntityCoords(v)
    local lastV = nil
    hold(v, function()
        local th, br = cruise(v, kmh)
        return { throttle = th, brake = br }
    end, p.seconds or 60, function()
        local pos = GetEntityCoords(v)
        local dist = #(pos - p0)
        if speedKmh(v) > kmh * 0.9 then res.reachedAt = res.reachedAt or r(dist, 2) end
        if res.reachedAt then
            local rot = GetEntityRotation(v, 2)
            res.maxPitch = math.max(res.maxPitch, math.abs(rot.x))
            res.maxRoll = math.max(res.maxRoll, math.abs(rot.y))
            local n = wheelsOnGround(v)
            res.minWheels = math.min(res.minWheels, n)
            if n == 0 then res.airborneFrames = res.airborneFrames + 1 end
            local sp = fwdSpeed(v)
            if lastV then res.maxDrop = math.max(res.maxDrop or 0, (lastV - sp) * 3.6) end
            lastV = sp
        end
        return dist >= untilMeters
    end, true)
    res.maxPitch = r(res.maxPitch, 3)
    res.maxRoll = r(res.maxRoll, 3)
    res.maxDrop = r(res.maxDrop, 3)
    res.endSpeed = r(speedKmh(v), 2)
    res.distance = r(#(GetEntityCoords(v) - p0), 2)
    settle(v)
    return res
end

--- Cote : monter, s'arreter dans la pente, frein a main 1,5 s, tout relacher 2 s,
--- puis plein gaz 4 s.
--- Poussee maximale a pente et vitesse imposees : monte a vitesse tenue jusqu'au seuil de
--- pente, puis plein gaz sur une fenetre courte. Avec `minPitch` = 0 et un depart a plat, c'est
--- la reference sur le plat, a la meme vitesse et au meme rapport.
function Tests.thrust(v, p)
    local kmh = p.kmh or 40
    local minPitch = p.minPitch or 0.0
    local window = p.window or 0.6
    if p.start then
        resetAt(v, p.start.x, p.start.y, p.start.z, p.start.h)
    end
    settle(v)
    setLine(v)
    -- mise en vitesse, puis tenue jusqu'au seuil de pente
    local atteint = false
    hold(v, function()
        local th, br = cruise(v, kmh)
        return { throttle = th, brake = br }
    end, p.climbSeconds or 40, function()
        if math.abs(GetEntityRotation(v, 2).x) >= minPitch
            and math.abs(speedKmh(v) - kmh) < 3.0 then
            atteint = true
            return true
        end
        return false
    end, true)

    local res = {
        kmh = kmh, minPitch = minPitch, window = window, reached = atteint,
        entrySpeed = r(speedKmh(v), 2), entryPitch = r(GetEntityRotation(v, 2).x, 3),
        entryGear = GetVehicleCurrentGear(v), entryRpm = r(GetVehicleCurrentRpm(v), 4),
    }
    local p0 = GetEntityCoords(v)
    -- plein gaz, fenetre courte : la trace contient tout, l'analyse se fait hors jeu
    local n, srpm, sgear = 0, 0.0, 0
    hold(v, { throttle = 1.0 }, window, function()
        n = n + 1
        srpm = srpm + GetVehicleCurrentRpm(v)
        sgear = math.max(sgear, GetVehicleCurrentGear(v))
        return false
    end, true)
    local p1 = GetEntityCoords(v)
    res.exitSpeed = r(speedKmh(v), 2)
    res.exitPitch = r(GetEntityRotation(v, 2).x, 3)
    res.gear = sgear
    res.rpm = (n > 0) and r(srpm / n, 4) or nil
    res.dist = r(#(p1 - p0), 3)
    res.dz = r(p1.z - p0.z, 3)
    -- pente de la TRAJECTOIRE sur la fenetre (ne depend pas de l'assiette)
    local dh = math.sqrt((p1.x - p0.x) ^ 2 + (p1.y - p0.y) ^ 2)
    res.slopePct = (dh > 0.5) and r(100.0 * (p1.z - p0.z) / dh, 3) or nil
    -- acceleration moyenne sur la fenetre, le long de la pente
    res.accel = r((res.exitSpeed - res.entrySpeed) / 3.6 / window, 4)
    settle(v)
    return res
end

function Tests.hill(v, p)
    local kmh = p.kmh or 20
    local minPitch = p.minPitch or 5
    settle(v)
    setLine(v)
    local res = { kmh = kmh }
    local slope = 0
    hold(v, function()
        local th, br = cruise(v, kmh)
        return { throttle = th, brake = br }
    end, p.climbSeconds or 40, function()
        slope = (math.abs(GetEntityRotation(v, 2).x) > minPitch) and (slope + 1) or 0
        return slope >= 20
    end, true)

    res.pitch = r(GetEntityRotation(v, 2).x, 3)
    if math.abs(res.pitch) < minPitch then
        res.error = 'pente non atteinte'
        settle(v)
        return res
    end

    hold(v, { brake = 1.0 }, 6, function() return math.abs(fwdSpeed(v)) < 0.1 end, true)
    -- La pente ou le vehicule s'immobilise n'est pas tout a fait celle du
    -- declenchement : c'est elle qui compte pour le frein a main, le recul et
    -- le demarrage en cote.
    res.pitchStopped = r(GetEntityRotation(v, 2).x, 3)
    res.gradeStopped = r(math.tan(math.rad(res.pitchStopped)) * 100.0, 2)
    local pA = GetEntityCoords(v)
    hold(v, { handbrake = true }, 1.5, nil, true)
    res.creepHandbrake = r(#(GetEntityCoords(v) - pA), 4)

    local pB = GetEntityCoords(v)
    res.minSpeedReleased = 0
    hold(v, {}, 2, function()
        res.minSpeedReleased = math.min(res.minSpeedReleased, fwdSpeed(v) * 3.6)
        return false
    end, true)
    res.rollbackReleased = r(#(GetEntityCoords(v) - pB), 4)
    res.minSpeedReleased = r(res.minSpeedReleased, 3)

    local pC = GetEntityCoords(v)
    res.minSpeedLaunch = 0
    hold(v, { throttle = 1.0 }, 4, function()
        res.minSpeedLaunch = math.min(res.minSpeedLaunch, fwdSpeed(v) * 3.6)
        res.launchSpeed = r(speedKmh(v), 2)
        return false
    end, true)
    res.launchDistance = r(#(GetEntityCoords(v) - pC), 3)
    res.launchGear = GetVehicleCurrentGear(v)
    res.minSpeedLaunch = r(res.minSpeedLaunch, 3)
    settle(v)
    return res
end

--- Roue libre : on lance a `fromKmh` puis on relache tout. Donne la trainee
--- (aerodynamique + frein moteur + roulement) en fonction de la vitesse.
function Tests.coast(v, p)
    local from = p.fromKmh or 150
    settle(v)
    setLine(v)
    hold(v, { throttle = 1.0 }, 90, function() return speedKmh(v) >= from end, true)
    local res = { from = r(speedKmh(v), 2), marks = {} }
    local p0 = GetEntityCoords(v)
    local marks = { 140, 120, 100, 80, 60, 40, 20 }
    local mi = 1
    hold(v, {}, p.seconds or 60, function(t)
        local kmh = speedKmh(v)
        while mi <= #marks and kmh <= marks[mi] do
            res.marks[#res.marks + 1] = { kmh = marks[mi], t = r(t, 3),
                                          dist = r(#(GetEntityCoords(v) - p0), 2) }
            mi = mi + 1
        end
        return kmh <= (p.toKmh or 20)
    end, true)
    res.endSpeed = r(speedKmh(v), 2)
    res.distance = r(#(GetEntityCoords(v) - p0), 2)
    settle(v)
    return res
end

--- Creneau de braquage : vitesse stabilisee, puis braquage brusque maintenu.
function Tests.stepsteer(v, p)
    local kmh = p.kmh or 60
    local steer = p.steer or 0.5
    settle(v)
    setLine(v)
    hold(v, { throttle = 1.0 }, 60, function() return speedKmh(v) >= kmh end, true)
    -- 1 s de stabilisation en ligne droite avant le creneau
    hold(v, function()
        local th, br = cruise(v, kmh)
        return { throttle = th, brake = br }
    end, 1.0, nil, true)

    local res = { kmh = kmh, steer = steer, entrySpeed = r(speedKmh(v), 2) }
    local tStep = GetGameTimer()
    hold(v, function()
        local th, br = cruise(v, kmh)
        return { throttle = th, brake = br, steer = steer }
    end, p.seconds or 4, function(t)
        local wz = math.abs(GetEntityRotationVelocity(v).z) * 180.0 / math.pi
        local rollNow = math.abs(GetEntityRotation(v, 2).y)
        res.maxYawRate = math.max(res.maxYawRate or 0, wz)
        res.maxRoll = math.max(res.maxRoll or 0, rollNow)
        -- temps de reponse : 90 % du lacet maximal observe
        if res.maxYawRate and wz >= 0.9 * res.maxYawRate then
            res.tTo90 = r((GetGameTimer() - tStep) / 1000.0, 3)
        end
        return false
    end, false)
    res.maxYawRate = r(res.maxYawRate, 2)
    res.maxRoll = r(res.maxRoll, 3)
    res.endSpeed = r(speedKmh(v), 2)
    settle(v)
    return res
end

--- Direction a consigne constante, en creneaux alternes.
---
--- Mesure la loi de braquage : combien de degres de roue pour une consigne
--- donnee, a une vitesse donnee. C'est la grandeur a caler (fade en vitesse),
--- et elle separe deux defauts qu'un virage confond : une roue qui braque trop,
--- et un pneu qui repond trop fort au braquage.
---
--- Le braquage de roue se stabilise en ~0,9 s (mesure sur les traces du
--- creneau). On alterne donc des phases de `phase` secondes, la premiere de
--- moitie : le cap decrit un triangle centre sur zero, donc la derive laterale
--- reste de quelques metres. Indispensable ici, le tablier plat ne faisant que
--- 14 m de large.
function Tests.steerfade(v, p)
    local kmh = p.kmh or 60
    local steer = p.steer or 0.5
    local phase = p.phase or 1.0
    local cycles = p.cycles or 5
    local tail = p.tail or 0.25            -- duree du plateau lu en fin de phase
    settle(v)
    setLine(v)
    hold(v, { throttle = 1.0 }, 60, function() return speedKmh(v) >= kmh end, true)
    -- 1 s de ligne droite stabilisee avant le premier creneau
    hold(v, function()
        local th, br = cruise(v, kmh)
        return { throttle = th, brake = br }
    end, 1.0, nil, true)

    local res = { kmh = kmh, steer = steer, phase = phase, cycles = cycles,
                  entrySpeed = r(speedKmh(v), 2), plateaus = {} }
    local sign = 1.0
    for k = 1, cycles do
        local dur = (k == 1) and (phase * 0.5) or phase
        local n, sw, syaw, skmh, sslip, sroll, slat = 0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0
        local minWheels = 4
        hold(v, function()
            local th, br = cruise(v, kmh)
            return { throttle = th, brake = br, steer = steer * sign }
        end, dur, function(t)
            if t < dur - tail then return false end
            local sv = GetEntitySpeedVector(v, true)
            n = n + 1
            sw = sw + math.abs(0.5 * (GetVehicleWheelSteeringAngle(v, 0)
                                    + GetVehicleWheelSteeringAngle(v, 1)))
            syaw = syaw + math.abs(GetEntityRotationVelocity(v).z)
            skmh = skmh + speedKmh(v)
            sroll = sroll + math.abs(GetEntityRotation(v, 2).y)
            slat = slat + math.abs(sv.x)
            if math.abs(sv.y) > 1.0 then
                sslip = sslip + math.abs(math.deg(math.atan(sv.x, math.abs(sv.y))))
            end
            minWheels = math.min(minWheels, wheelsOnGround(v))
            return false
        end, false)
        -- la premiere phase, de moitie, n'est qu'une mise en place : non lue
        if k > 1 and n > 0 then
            res.plateaus[#res.plateaus + 1] = {
                dir = sign, n = n,
                wheelDeg = r(math.deg(sw / n), 3),
                yawRate = r(math.deg(syaw / n), 2),
                kmh = r(skmh / n, 2),
                slip = r(sslip / n, 2),
                roll = r(sroll / n, 3),
                vLat = r(slat / n, 3),
                minWheels = minWheels,
            }
        end
        sign = -sign
    end
    hold(v, function()
        local th, br = cruise(v, kmh)
        return { throttle = th, brake = br }
    end, 0.8, nil, true)
    res.endSpeed = r(speedKmh(v), 2)
    settle(v)
    return res
end

--- Slalom sinusoidal : braquage sinus d'amplitude et de periode donnees.
--- Cercle a consigne CONSTANTE et vitesse tenue : separe la derive de la vitesse.
---
--- Le virage 80 ne pouvait pas identifier la reduction du braquage en glisse : la vitesse
--- tombe, la derive monte et le temps avance ENSEMBLE, donc n'importe quelle fonction
--- decroissante colle. Ici le regulateur tient la vitesse et la consigne est fixe : on
--- balaye l'une a l'autre fixee, et la derive s'etablit a une valeur qui ne depend plus du
--- temps. Il faut un carre plat (voir Tests.gridprobe), pas un couloir.
---
--- Rend le plateau lu en fin de cercle, et la suite des moyennes par demi-seconde pour
--- verifier HORS JEU que le regime etait bien etabli, plutot que de le supposer.
function Tests.skidpad(v, p)
    local kmh = p.kmh or 60
    local steer = p.steer or 1.0
    local spin = p.spin or 8.0          -- duree du cercle
    local tail = p.tail or 1.5          -- duree du plateau lu, en fin de cercle
    local heading = p.h or 0.0
    local cx, cy, cz = p.x + 0.0, p.y + 0.0, p.z + 0.0
    local A, B = p.axleFront or 1.38, p.axleRear or 1.41

    resetAt(v, cx, cy, cz, heading)
    hold(v, { throttle = 1.0 }, 40, function() return speedKmh(v) >= kmh end, true)
    -- tenue de ligne jusqu'au POINT de declenchement, s'il est donne : place sur le bord du
    -- disque plat, un cercle de rayon R y est inscrit exactement quel que soit R (la distance
    -- du centre du disque au centre du cercle vaut |R - Rdisque|, donc |R-Rd| + R = Rd).
    -- Sans tx/ty, on tourne des que la vitesse est atteinte.
    local tx, ty = p.tx, p.ty
    local reached = (tx == nil or ty == nil)
    hold(v, function()
        local th, br = cruise(v, kmh)
        return { throttle = th, brake = br }
    end, p.approach or 12.0, function()
        if reached then return true end
        local pos = GetEntityCoords(v)
        local hh = math.rad(GetEntityHeading(v))
        local fx, fy = -math.sin(hh), math.cos(hh)
        -- on a passe le point quand sa projection sur l'avant devient negative
        if (tx - pos.x) * fx + (ty - pos.y) * fy <= 0.0 then
            reached = true
            return true
        end
        return false
    end, true)

    local turn0 = GetEntityCoords(v)
    local res = {
        kmh = kmh, steer = steer,
        effective = r(math.max(0.0, (math.abs(steer) - 0.25) / 0.75), 4),
        entrySpeed = r(speedKmh(v), 2),
        turnStart = { r(turn0.x, 2), r(turn0.y, 2), r(turn0.z, 3) },
        turnPointReached = reached,
        buckets = {},
        bucketColumns = { 't', 'wheelDeg', 'beta', 'yawRate', 'kmh', 'latG', 'distTurn' },
    }
    local n, sw, sbeta, syaw, skmh, slat, stf, stre, sroll = 0, 0, 0, 0, 0, 0, 0, 0, 0
    local minWheels, maxDist, zMin, zMax = 4, 0.0, 1e9, -1e9
    local bn, bw, bbeta, byaw, bkmh, blat, bdist, bIdx = 0, 0, 0, 0, 0, 0, 0, 0
    local prevLat, prevT = nil, nil

    hold(v, function()
        local th, br = cruise(v, kmh)
        return { throttle = th, brake = br, steer = steer }
    end, spin, function(t)
        local sv = GetEntitySpeedVector(v, true)
        local wz = GetEntityRotationVelocity(v).z
        local vf = sv.y
        local now = GetGameTimer()
        -- acceleration laterale : d(vLat)/dt - wz*vFwd ; le terme wz*vFwd seul ne vaut qu'etabli
        local lat
        if prevLat and prevT and now > prevT then
            lat = math.abs((sv.x - prevLat) / ((now - prevT) / 1000.0) - wz * vf) / 9.81
        else
            lat = math.abs(wz * vf) / 9.81
        end
        prevLat, prevT = sv.x, now

        local wheel = math.deg(0.5 * (GetVehicleWheelSteeringAngle(v, 0)
                                    + GetVehicleWheelSteeringAngle(v, 1)))
        local beta = (math.abs(vf) > 2.0) and math.deg(math.atan(sv.x, math.abs(vf))) or 0.0
        local pos = GetEntityCoords(v)
        local dist = #(pos - turn0)
        maxDist = math.max(maxDist, dist)
        zMin, zMax = math.min(zMin, pos.z), math.max(zMax, pos.z)
        minWheels = math.min(minWheels, wheelsOnGround(v))

        bn = bn + 1
        bw, bbeta, byaw = bw + wheel, bbeta + beta, byaw + math.deg(wz)
        bkmh, blat, bdist = bkmh + speedKmh(v), blat + lat, bdist + dist
        if t >= (bIdx + 1) * 0.5 then
            res.buckets[#res.buckets + 1] = {
                r((bIdx + 1) * 0.5, 2), r(bw / bn, 3), r(bbeta / bn, 3), r(byaw / bn, 2),
                r(bkmh / bn, 2), r(blat / bn, 3), r(bdist / bn, 2),
            }
            bIdx = bIdx + 1
            bn, bw, bbeta, byaw, bkmh, blat, bdist = 0, 0, 0, 0, 0, 0, 0
        end

        if t >= spin - tail then
            n = n + 1
            sw = sw + wheel
            sbeta = sbeta + beta
            syaw = syaw + math.deg(wz)
            skmh = skmh + speedKmh(v)
            slat = slat + lat
            sroll = sroll + math.abs(GetEntityRotation(v, 2).y)
            if math.abs(vf) > 2.0 then
                -- derives des pneus : vitesse laterale a l'essieu avant = vLat - a*wz
                local thF = -math.deg(math.atan(sv.x - A * wz, math.abs(vf)))
                local thR = -math.deg(math.atan(sv.x + B * wz, math.abs(vf)))
                stf = stf + math.abs(wheel - thF)
                stre = stre + math.abs(thR)
            end
        end
        return false
    end, false)

    if n > 0 then
        res.plateau = {
            n = n,
            wheelDeg = r(sw / n, 3), beta = r(sbeta / n, 3), yawRate = r(syaw / n, 2),
            kmh = r(skmh / n, 2), latG = r(slat / n, 3), roll = r(sroll / n, 3),
            tyreFront = r(stf / n, 3), tyreRear = r(stre / n, 3),
        }
        local yawRad = math.rad(math.abs(syaw / n))
        if yawRad > 1e-4 then res.plateau.radius = r((skmh / n) / 3.6 / yawRad, 3) end
    end
    res.maxDistFromTurn = r(maxDist, 2)
    res.zSpan = r(zMax - zMin, 3)
    res.minWheels = minWheels
    res.endSpeed = r(speedKmh(v), 2)
    settle(v)
    return res
end

function Tests.slalom(v, p)
    local kmh = p.kmh or 60
    local amp = p.amplitude or 0.5
    local period = p.period or 2.0
    settle(v)
    setLine(v)
    hold(v, { throttle = 1.0 }, 60, function() return speedKmh(v) >= kmh end, true)

    local res = { kmh = kmh, amplitude = amp, period = period }
    local start = GetGameTimer()
    hold(v, function()
        local t = (GetGameTimer() - start) / 1000.0
        local th, br = cruise(v, kmh)
        return { throttle = th, brake = br, steer = amp * math.sin(2 * math.pi * t / period) }
    end, p.seconds or 12, function()
        local rot = GetEntityRotation(v, 2)
        local sv = GetEntitySpeedVector(v, true)
        res.maxRoll = math.max(res.maxRoll or 0, math.abs(rot.y))
        res.maxYawRate = math.max(res.maxYawRate or 0,
            math.abs(GetEntityRotationVelocity(v).z) * 180.0 / math.pi)
        if math.abs(sv.y) > 2 then
            res.maxSlip = math.max(res.maxSlip or 0,
                math.abs(math.deg(math.atan(sv.x, math.abs(sv.y)))))
        end
        res.minWheels = math.min(res.minWheels or 4, wheelsOnGround(v))
        return false
    end, false)
    res.maxRoll = r(res.maxRoll, 3)
    res.maxYawRate = r(res.maxYawRate, 2)
    res.maxSlip = r(res.maxSlip, 2)
    res.endSpeed = r(speedKmh(v), 2)
    settle(v)
    return res
end

--- Releve du sol le long d'une ligne : on pose le vehicule tous les `step`
--- metres et on lit la hauteur, le materiau sous la roue et l'assiette.
--- Sert a trouver une piste bien plate, et a reperer une bordure.
function Tests.surfscan(v, p)
    local h = math.rad(p.h or 0.0)
    local fx, fy = -math.sin(h), math.cos(h)
    local x0 = p.x or GetEntityCoords(v).x
    local y0 = p.y or GetEntityCoords(v).y
    local z0 = p.z or GetEntityCoords(v).z
    local step = p.step or 10.0
    local len = p.len or 1200.0
    local out = {}
    local d = 0.0
    while d <= len do
        if abortFlag then break end
        local x, y = x0 + fx * d, y0 + fy * d
        SetEntityCoordsNoOffset(v, x, y, z0 + 1.0, false, false, false)
        SetEntityVelocity(v, 0.0, 0.0, 0.0)
        SetEntityRotation(v, 0.0, 0.0, p.h or 0.0, 2, true)
        -- Sans collision chargee, SetVehicleOnGroundProperly ne fait rien : le
        -- vehicule garde l'assiette imposee et le releve est faux (assiette
        -- exactement nulle sur des kilometres). On attend donc le streaming.
        RequestCollisionAtCoord(x, y, z0)
        local tw = GetGameTimer()
        local loaded = false
        while GetGameTimer() - tw < (p.collisionMs or 2000) do
            RequestCollisionAtCoord(x, y, z0)
            Wait(50)
            if HasCollisionLoadedAroundEntity(v) then loaded = true break end
        end
        SetVehicleOnGroundProperly(v)
        Wait(p.settleMs or 120)
        local pos = GetEntityCoords(v)
        local rot = GetEntityRotation(v, 2)
        -- HasCollisionLoadedAroundEntity peut dire oui alors que le sol SOUS le
        -- vehicule n'est pas la : le vehicule reste alors a la hauteur imposee,
        -- assiette exactement nulle, et le releve est faux. Le seul test sur
        -- lequel on peut compter : au moins une roue touche un materiau.
        local m0 = GetVehicleWheelSurfaceMaterial(v, 0)
        local m2 = GetVehicleWheelSurfaceMaterial(v, 2)
        local grounded = (m0 ~= 0 and m0 ~= -1) or (m2 ~= 0 and m2 ~= -1)
        out[#out + 1] = {
            r(d, 1), grounded and r(pos.z, 3) or nil,
            m0, m2, r(rot.x, 2), r(rot.y, 2),
            (loaded and grounded) and 1 or 0,
        }
        d = d + step
    end
    return { columns = { 'd', 'z', 'matAvG', 'matArG', 'pitch', 'roll', 'collision' }, profile = out }
end

--- Hauteur EXACTE du sol le long d'une ligne, par rayons verticaux.
---
--- Poser le vehicule et lire sa hauteur ne marche pas pour chercher une bordure :
--- une marche de 15 cm sous une caisse de 2 m de large donne une rampe etalee, pas
--- une marche. Ici on amene le vehicule au centre de la zone (pour que la collision
--- soit chargee), puis on tire un rayon vertical tous les `step` metres.
function Tests.heightprobe(v, p)
    local cx, cy, cz = p.x + 0.0, p.y + 0.0, (p.z or 20.0) + 0.0
    -- amener le vehicule sur zone et attendre la collision
    SetEntityCoordsNoOffset(v, cx, cy, cz + 2.0, false, false, false)
    SetEntityVelocity(v, 0.0, 0.0, 0.0)
    RequestCollisionAtCoord(cx, cy, cz)
    local tw = GetGameTimer()
    while GetGameTimer() - tw < (p.collisionMs or 4000) do
        RequestCollisionAtCoord(cx, cy, cz)
        Wait(50)
        if HasCollisionLoadedAroundEntity(v) then break end
    end
    SetVehicleOnGroundProperly(v)
    Wait(300)
    local base = GetEntityCoords(v)

    local h = math.rad(p.h or 0.0)
    local fx, fy = -math.sin(h), math.cos(h)
    local step = p.step or 0.1
    local half = p.half or 12.0
    local out = {}
    local d = -half
    while d <= half do
        local x, y = cx + fx * d, cy + fy * d
        local probe = StartExpensiveSynchronousShapeTestLosProbe(
            x, y, base.z + 6.0, x, y, base.z - 6.0, 1, v, 7)
        local _, hit, pos = GetShapeTestResult(probe)
        out[#out + 1] = { r(d, 2), (hit == 1 or hit == true) and r(pos.z, 4) or nil }
        d = d + step
    end
    return { center = { r(cx, 2), r(cy, 2), r(base.z, 3) }, h = p.h or 0.0,
             columns = { 'offset', 'zSol' }, profile = out }
end

--- Profil en long d'une route, pour chercher une cote d'une pente donnee.
---
--- On prend le noeud routier le plus proche, puis on tire des rayons verticaux
--- LE LONG de la route : la pente se lit directement sur le profil, sans avoir
--- a y conduire. Reposer le vehicule ne marcherait pas, la collision n'etant
--- chargee qu'autour de lui.
--- Releve du sol sur une GRILLE carree, pour trouver une zone plate assez large.
--- heightprobe ne donne qu'un profil en long : il avait laisse croire que le tablier etait
--- plat alors que ses bords ne sont pas paralleles a l'axe. Ici on ajuste un PLAN
--- z = a + b*dx + c*dy sur toute la grille et on rend le residu, qui est le vrai critere de
--- platitude : une pente reguliere ne gene pas un cercle, une bosse si.
function Tests.gridprobe(v, p)
    local cx, cy, cz = p.x + 0.0, p.y + 0.0, (p.z or 20.0) + 0.0
    SetEntityCoordsNoOffset(v, cx, cy, cz + 2.0, false, false, false)
    SetEntityVelocity(v, 0.0, 0.0, 0.0)
    local tw = GetGameTimer()
    while GetGameTimer() - tw < (p.collisionMs or 4000) do
        RequestCollisionAtCoord(cx, cy, cz)
        Wait(50)
        if HasCollisionLoadedAroundEntity(v) then break end
    end
    SetVehicleOnGroundProperly(v)
    Wait(300)
    local base = GetEntityCoords(v)

    local half = p.half or 30.0
    local step = p.step or 2.0
    local pts, miss, k = {}, 0, 0
    local dy = -half
    while dy <= half + 1e-9 do
        local dx = -half
        while dx <= half + 1e-9 do
            local x, y = cx + dx, cy + dy
            local probe = StartExpensiveSynchronousShapeTestLosProbe(
                x, y, base.z + 8.0, x, y, base.z - 8.0, 1, v, 7)
            local _, hit, pos = GetShapeTestResult(probe)
            if hit == 1 or hit == true then
                pts[#pts + 1] = { dx, dy, pos.z }
            else
                miss = miss + 1
            end
            k = k + 1
            if k % 120 == 0 then Wait(0) end
            dx = dx + step
        end
        dy = dy + step
    end

    local N = #pts
    local res = { center = { r(cx, 2), r(cy, 2), r(base.z, 3) }, half = half, step = step,
                  probes = k, hits = N, misses = miss }
    if N >= 8 then
        -- plan des moindres carres ; la grille etant symetrique, le systeme normal se decouple
        local Sz, Sxx, Syy, Sxz, Syz = 0, 0, 0, 0, 0
        for _, q in ipairs(pts) do
            Sz = Sz + q[3]
            Sxx = Sxx + q[1] * q[1]
            Syy = Syy + q[2] * q[2]
            Sxz = Sxz + q[1] * q[3]
            Syz = Syz + q[2] * q[3]
        end
        local a = Sz / N
        local b = (Sxx > 1e-9) and (Sxz / Sxx) or 0.0
        local c = (Syy > 1e-9) and (Syz / Syy) or 0.0
        local rmax, rsum, zlo, zhi = 0.0, 0.0, 1e9, -1e9
        for _, q in ipairs(pts) do
            local e = math.abs(q[3] - (a + b * q[1] + c * q[2]))
            rmax = math.max(rmax, e)
            rsum = rsum + e
            zlo = math.min(zlo, q[3])
            zhi = math.max(zhi, q[3])
        end
        res.plane = { z0 = r(a, 4), slopeX = r(b, 5), slopeY = r(c, 5) }
        res.slopePct = r(100.0 * math.sqrt(b * b + c * c), 3)
        res.residMax = r(rmax, 4)
        res.residMean = r(rsum / N, 4)
        res.zSpan = r(zhi - zlo, 3)
        -- plus grand rayon, centre sur le centre, ou le residu reste sous le seuil
        local tol = p.tol or 0.03
        local best = 0.0
        for rad = step, half, step do
            local ok = true
            for _, q in ipairs(pts) do
                local d = math.sqrt(q[1] * q[1] + q[2] * q[2])
                if d <= rad + 1e-9 and math.abs(q[3] - (a + b * q[1] + c * q[2])) > tol then
                    ok = false
                    break
                end
            end
            if ok then best = rad else break end
        end
        res.flatRadius = r(best, 2)
        res.tol = tol
    end
    if p.profile then
        res.columns = { 'dx', 'dy', 'zSol' }
        res.grid = pts
    end
    return res
end

function Tests.hillprobe(v, p)
    local cx, cy, cz = p.x + 0.0, p.y + 0.0, (p.z or 20.0) + 0.0
    SetEntityCoordsNoOffset(v, cx, cy, cz + 2.0, false, false, false)
    SetEntityVelocity(v, 0.0, 0.0, 0.0)
    local tw = GetGameTimer()
    while GetGameTimer() - tw < (p.collisionMs or 5000) do
        RequestCollisionAtCoord(cx, cy, cz)
        Wait(50)
        if HasCollisionLoadedAroundEntity(v) then break end
    end
    SetVehicleOnGroundProperly(v)
    Wait(300)

    local ok, node, nh = GetClosestVehicleNodeWithHeading(cx, cy, cz, 1, 3.0, 0)
    if not ok then return { error = 'aucun noeud routier pres de ce point' } end
    local hRoad = (p.h ~= nil) and (p.h + 0.0) or (nh + 0.0)
    local hr = math.rad(hRoad)
    local fx, fy = -math.sin(hr), math.cos(hr)
    local half, step = p.half or 60.0, p.step or 1.0
    local out, d = {}, -half
    while d <= half do
        local x, y = node.x + fx * d, node.y + fy * d
        local probe = StartExpensiveSynchronousShapeTestLosProbe(
            x, y, node.z + 60.0, x, y, node.z - 60.0, 1, v, 7)
        local _, hit, pos = GetShapeTestResult(probe)
        out[#out + 1] = { r(d, 1), (hit == 1 or hit == true) and r(pos.z, 3) or nil }
        d = d + step
    end
    return { node = { r(node.x, 2), r(node.y, 2), r(node.z, 2) }, roadHeading = r(hRoad, 1),
             columns = { 'offset', 'zSol' }, profile = out }
end

--- Obstacle calibre : on CONSTRUIT la marche de l'essai de bordure.
---
--- Les bordures de rue sont PARALLELES a la chaussee : pour les aborder de face
--- il faut traverser la rue, ce qui ne laisse qu'une demi-chaussee d'elan, 7 m
--- environ. On ne peut pas y arriver a 60 km/h. On construit donc la marche :
--- un prop parallelepipedique enfonce dans le terrain de facon que sa face
--- superieure soit exactement `height` metres au-dessus du sol, pose au bout
--- d'une ligne droite validee. La marche obtenue est ensuite RELEVEE au rayon
--- vertical, pour verifier sa hauteur reelle avant de mesurer quoi que ce soit.

local stepObjects = {}

--- Hauteur du sol sous (x, y). flags : 1 = terrain seul, 17 = terrain + objets.
local function groundZ(v, x, y, zHint, flags)
    local probe = StartExpensiveSynchronousShapeTestLosProbe(
        x, y, zHint + 8.0, x, y, zHint - 8.0, flags or 1, v, 7)
    local _, hit, pos = GetShapeTestResult(probe)
    if hit == 1 or hit == true then return pos.z end
    return nil
end

local function clearStepObjects()
    local n = 0
    for _, obj in ipairs(stepObjects) do
        if DoesEntityExist(obj) then
            SetEntityAsMissionEntity(obj, true, true)
            DeleteEntity(obj)
            n = n + 1
        end
    end
    stepObjects = {}
    return n
end

--- Retire la marche construite.
function Tests.clearstep(v, p)
    return { deleted = clearStepObjects() }
end

--- Validite et encombrement d'une liste de modeles, pour choisir le prop.
function Tests.modelprobe(v, p)
    local out = {}
    for _, name in ipairs(p.models or {}) do
        local hash = GetHashKey(name)
        local inCd = IsModelInCdimage(hash)
        local row = { name, inCd and 1 or 0, IsModelValid(hash) and 1 or 0 }
        if inCd then
            RequestModel(hash)
            local tw = GetGameTimer()
            while not HasModelLoaded(hash) and GetGameTimer() - tw < 3000 do Wait(20) end
            if HasModelLoaded(hash) then
                local mn, mx = GetModelDimensions(hash)
                row[4], row[5], row[6] = r(mx.x - mn.x, 2), r(mx.y - mn.y, 2), r(mx.z - mn.z, 2)
                row[7], row[8] = r(mn.z, 3), r(mx.z, 3)
                SetModelAsNoLongerNeeded(hash)
            end
        end
        out[#out + 1] = row
    end
    return { columns = { 'modele', 'dansCdimage', 'valide', 'dimX', 'dimY', 'dimZ', 'minZ', 'maxZ' },
             models = out }
end

--- Construit la marche et en renvoie la coupe mesuree au rayon vertical.
function Tests.buildstep(v, p)
    clearStepObjects()
    local model = p.model or 'prop_container_01a'
    local hash = GetHashKey(model)
    if not IsModelInCdimage(hash) then return { error = 'modele absent : ' .. model } end
    RequestModel(hash)
    local tw = GetGameTimer()
    while not HasModelLoaded(hash) and GetGameTimer() - tw < 10000 do Wait(20) end
    if not HasModelLoaded(hash) then return { error = 'modele non charge : ' .. model } end

    local mn, mx = GetModelDimensions(hash)
    local dimX, dimY = mx.x - mn.x, mx.y - mn.y
    -- Le grand cote va DANS le sens de la marche : le vehicule reste assez
    -- longtemps sur le dessus pour que la suspension se stabilise avant la
    -- redescente. Le petit cote sert de pas lateral entre les exemplaires.
    local alongIsY = dimY >= dimX
    local heading = (p.h or 0.0) + (alongIsY and 0.0 or 90.0)
    local lateral = alongIsY and dimX or dimY

    local cx, cy = p.x + 0.0, p.y + 0.0
    local zHint = (p.z or 20.0) + 0.0
    -- amener le vehicule sur zone, sinon la collision du terrain n'est pas la
    SetEntityCoordsNoOffset(v, cx, cy, zHint + 2.0, false, false, false)
    SetEntityVelocity(v, 0.0, 0.0, 0.0)
    local tw2 = GetGameTimer()
    while GetGameTimer() - tw2 < (p.collisionMs or 4000) do
        RequestCollisionAtCoord(cx, cy, zHint)
        Wait(50)
        if HasCollisionLoadedAroundEntity(v) then break end
    end
    SetVehicleOnGroundProperly(v)
    Wait(300)

    local height = p.height or 0.15
    local count = p.count or 3
    local hr = math.rad(p.h or 0.0)
    local rx, ry = math.cos(hr), math.sin(hr)          -- vecteur lateral (droite)
    local fx, fy = -math.sin(hr), math.cos(hr)          -- sens de la marche
    local placed = {}
    local halfN = (count - 1) / 2.0
    for i = 0, count - 1 do
        local off = (i - halfN) * (lateral - (p.overlap or 0.05))
        local x, y = cx + rx * off, cy + ry * off
        local gz = groundZ(v, x, y, zHint, 1)
        if gz then
            local z = gz + height - mx.z
            local obj = CreateObject(hash, x, y, z, false, false, false)
            SetEntityHeading(obj, heading)
            FreezeEntityPosition(obj, true)
            SetEntityCollision(obj, true, true)
            SetEntityInvincible(obj, true)
            stepObjects[#stepObjects + 1] = obj
            placed[#placed + 1] = { r(off, 2), r(x, 2), r(y, 2), r(gz, 3), r(z, 3) }
        end
    end
    SetModelAsNoLongerNeeded(hash)
    Wait(500)

    -- coupe de verification dans le sens de la marche, objets inclus
    local prof, half, step = {}, p.half or 20.0, p.step or 0.25
    local d = -half
    while d <= half do
        local x, y = cx + fx * d, cy + fy * d
        local z = groundZ(v, x, y, zHint, 17)
        prof[#prof + 1] = { r(d, 2), z and r(z, 4) or nil }
        d = d + step
    end
    return { model = model, heading = r(heading, 1), alongIsY = alongIsY and 1 or 0,
             dim = { r(dimX, 2), r(dimY, 2), r(mx.z - mn.z, 2) }, maxZ = r(mx.z, 3),
             targetHeight = height, placed = placed,
             columns = { 'offset', 'zSol' }, profile = prof }
end

--- Releve en travers d'une route : on trouve le noeud routier le plus proche,
--- puis on echantillonne perpendiculairement a la route. C'est ainsi qu'on
--- repere un trottoir (marche nette de 10 a 20 cm) plutot qu'une rampe.
function Tests.roadscan(v, p)
    local sx, sy, sz = p.x + 0.0, p.y + 0.0, (p.z or 20.0) + 0.0
    local ok, node, heading = GetClosestVehicleNodeWithHeading(sx, sy, sz, 1, 3.0, 0)
    if not ok then
        return { error = 'aucun noeud routier pres de ce point' }
    end
    local hRoad = heading + 0.0
    -- perpendiculaire a la route
    local hPerp = math.rad(hRoad + 90.0)
    local fx, fy = -math.sin(hPerp), math.cos(hPerp)
    local step = p.step or 0.2
    local half = p.half or 14.0
    local out = {}
    local d = -half
    while d <= half do
        if abortFlag then break end
        local x, y = node.x + fx * d, node.y + fy * d
        SetEntityCoordsNoOffset(v, x, y, node.z + 1.5, false, false, false)
        SetEntityVelocity(v, 0.0, 0.0, 0.0)
        SetEntityRotation(v, 0.0, 0.0, hRoad, 2, true)
        RequestCollisionAtCoord(x, y, node.z)
        local tw = GetGameTimer()
        while GetGameTimer() - tw < (p.collisionMs or 1200) do
            Wait(40)
            if HasCollisionLoadedAroundEntity(v) then break end
        end
        SetVehicleOnGroundProperly(v)
        Wait(p.settleMs or 80)
        local m0 = GetVehicleWheelSurfaceMaterial(v, 0)
        local grounded = (m0 ~= 0 and m0 ~= -1)
        local pos = GetEntityCoords(v)
        out[#out + 1] = { r(d, 2), grounded and r(pos.z, 3) or nil, m0, grounded and 1 or 0 }
        d = d + step
    end
    return {
        node = { r(node.x, 2), r(node.y, 2), r(node.z, 2) },
        roadHeading = r(hRoad, 1),
        columns = { 'offset', 'z', 'materiau', 'valide' },
        profile = out,
    }
end

--- Essai brut : entrees constantes, pour diagnostiquer (signe du braquage,
--- tenue de cap sans correction, etc.).
function Tests.raw(v, p)
    if p.settle ~= false then settle(v) end
    setLine(v)
    local res = {}
    local p0 = GetEntityCoords(v)
    local h0 = GetEntityHeading(v)
    hold(v, {
        throttle = p.throttle or 0.0,
        brake = p.brake or 0.0,
        steer = p.steer or 0.0,
        handbrake = p.handbrake or false,
    }, p.seconds or 5, function()
        res.maxSteerAngle = math.max(res.maxSteerAngle or -999, GetVehicleSteeringAngle(v))
        res.minSteerAngle = math.min(res.minSteerAngle or 999, GetVehicleSteeringAngle(v))
        res.maxSpeed = math.max(res.maxSpeed or 0, speedKmh(v))
        return false
    end, p.keepLine == true)
    local h1 = GetEntityHeading(v)
    res.headingStart = r(h0, 2)
    res.headingEnd = r(h1, 2)
    res.headingDelta = r(((h1 - h0 + 540) % 360) - 180, 2)
    res.distance = r(#(GetEntityCoords(v) - p0), 2)
    res.endSpeed = r(speedKmh(v), 2)
    res.maxSteerAngle = r(res.maxSteerAngle, 2)
    res.minSteerAngle = r(res.minSteerAngle, 2)
    if p.settleAfter ~= false then settle(v) end
    return res
end

--- Relevé du handling seul, sans conduire.
function Tests.handling(v)
    return { note = 'valeurs de handling uniquement' }
end

-- ------------------------------------------------------------------ pilote

local function runTest(label, testName, params)
    local v, err = veh()
    if not v then return nil, err end

    prepareWorld()
    nWheels = math.max(1, math.min(10, GetVehicleNumberOfWheels(v)))
    curLabel = label
    samples, pendingRows = {}, {}
    t0 = GetGameTimer()
    abortFlag = false
    running = true

    local meta = {
        test = testName,
        params = params,
        model = GetEntityModel(v),
        modelName = GetDisplayNameFromVehicleModel(GetEntityModel(v)),
        plate = GetVehicleNumberPlateText(v),
        wheels = GetVehicleNumberOfWheels(v),
        handling = readHandling(v),
        gameBuild = GetGameBuildNumber and GetGameBuildNumber() or 0,
        columns = COLUMNS,
        startedAt = GetGameTimer(),
    }

    if params.start then
        resetAt(v, params.start.x, params.start.y, params.start.z, params.start.h or 0.0)
    else
        SetVehicleFixed(v)
        SetVehicleEngineOn(v, true, true, false)
    end

    TriggerServerEvent('vt:begin', label, meta)

    local fn = Tests[testName]
    if not fn then
        running = false
        return nil, 'essai inconnu : ' .. tostring(testName)
    end

    local ok, res = pcall(fn, v, params or {})
    running = false
    cur.throttle, cur.brake, cur.handbrake, cur.steer = 0.0, 0.0, false, 0.0
    flush(true)

    if not ok then return nil, tostring(res) end
    if abortFlag then return nil, 'essai interrompu' end
    return res
end

RegisterNetEvent('vt:run', function(label, testName, params)
    CreateThread(function()
        local res, err = runTest(label, testName, params or {})
        flush(true)
        TriggerServerEvent('vt:done', label, res, err)
        if err then
            print('[vehicle-telemetry] ' .. tostring(err))
        end
    end)
end)

RegisterNetEvent('vt:stop', function()
    abortFlag = true
    running = false
    cur.throttle, cur.brake, cur.handbrake, cur.steer = 0.0, 0.0, false, 0.0
end)

-- ------------------------------------------------------- sondage de terrain

--- Mesure la planeite d'une ligne droite : hauteur du sol tous les `step` metres.
RegisterNetEvent('vt:probe', function(data)
    CreateThread(function()
        local out = {}
        for _, pt in ipairs(data.points or {}) do
            local step = pt.step or 10.0
            local len = pt.len or 1000.0
            local h = math.rad(pt.h or 0.0)
            local fx, fy = -math.sin(h), math.cos(h)
            local zs, miss = {}, 0
            local d = 0.0
            while d <= len do
                local x, y = pt.x + fx * d, pt.y + fy * d
                local ok, gz = GetGroundZFor_3dCoord(x + 0.0, y + 0.0, (pt.z or 100.0) + 0.0, false)
                if ok then zs[#zs + 1] = { r(d, 1), r(gz, 3) } else miss = miss + 1 end
                d = d + step
            end
            local zmin, zmax = nil, nil
            for _, s in ipairs(zs) do
                zmin = math.min(zmin or s[2], s[2])
                zmax = math.max(zmax or s[2], s[2])
            end
            out[#out + 1] = {
                x = pt.x, y = pt.y, h = pt.h, len = len,
                samples = #zs, missing = miss,
                zmin = zmin, zmax = zmax,
                spread = (zmin and zmax) and r(zmax - zmin, 3) or nil,
                profile = pt.profile and zs or nil,
            }
        end
        TriggerServerEvent('vt:probeResult', { kind = 'probe', results = out })
    end)
end)

--- Cherche une marche (bordure de trottoir) le long d'une ligne.
RegisterNetEvent('vt:curbscan', function(data)
    CreateThread(function()
        local pt = data
        local step = pt.step or 0.25
        local len = pt.len or 60.0
        local h = math.rad(pt.h or 0.0)
        local fx, fy = -math.sin(h), math.cos(h)
        local steps, prev = {}, nil
        local d = 0.0
        while d <= len do
            local x, y = pt.x + fx * d, pt.y + fy * d
            local ok, gz = GetGroundZFor_3dCoord(x + 0.0, y + 0.0, (pt.z or 100.0) + 0.0, false)
            if ok then
                if prev and math.abs(gz - prev) >= (pt.minStep or 0.08) then
                    steps[#steps + 1] = { d = r(d, 2), dz = r(gz - prev, 3), z = r(gz, 3) }
                end
                prev = gz
            end
            d = d + step
        end
        TriggerServerEvent('vt:probeResult', { kind = 'curbscan', steps = steps })
    end)
end)

print('[vehicle-telemetry] client pret')
