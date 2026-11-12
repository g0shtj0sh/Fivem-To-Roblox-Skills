--[[
    vehicle-telemetry / server.lua

    Role : point d'entree HTTP local, et ecriture des traces en JSON.

    Le serveur FiveM sert du HTTP sur son propre port, a l'adresse
    http://<endpoint>/<nom de la ressource>/<chemin>. On s'en sert pour piloter
    la campagne de mesures depuis l'exterieur du jeu (script, terminal), sans
    avoir a taper quoi que ce soit dans la console ni dans le chat.

    Routes :
      GET  /status              etat courant (essai en cours, derniers resultats)
      GET  /tests               liste des essais disponibles
      POST /run                 {"test":"accel","params":{...},"label":"accel_1"}
      GET  /result?id=<label>   renvoie la trace JSON enregistree
      GET  /results             liste des traces enregistrees
      POST /stop                interrompt l'essai en cours
      POST /probe               {"points":[{"x":..,"y":..,"h":..,"len":..}]} sondage de terrain
      POST /curbscan            recherche d'une marche (bordure) devant un point

    Les traces vont dans le dossier de la ressource, sous out/<label>.json.
]]

local RESOURCE <const> = GetCurrentResourceName()

local state = {
    busy = false,
    test = nil,
    label = nil,
    startedAt = 0,
    progress = nil,
    lastError = nil,
    results = {},        -- label -> { rows, meta }
    pending = {},        -- label -> { samples = {}, meta = {} }
    probe = nil,
}

local function json_response(res, obj, code)
    res.writeHead(code or 200, { ['Content-Type'] = 'application/json; charset=utf-8' })
    res.send(json.encode(obj))
end

-- ----------------------------------------------------------------- clients

--- Renvoie l'id du premier joueur connecte (campagne a un seul joueur).
local function firstPlayer()
    local ps = GetPlayers()
    return ps and ps[1] or nil
end

-- ------------------------------------------------------- reception client

RegisterNetEvent('vt:begin', function(label, meta)
    local src = source
    state.pending[label] = { samples = {}, meta = meta, src = src }
    state.busy = true
    state.label = label
    state.test = meta and meta.test or nil
    state.startedAt = os.time()
    state.lastError = nil
    print(('[vehicle-telemetry] debut « %s » (%s)'):format(label, meta and meta.test or '?'))
end)

--- Les echantillons arrivent par paquets : un evenement par image saturerait
--- la file reseau, et un seul evenement pour 2 000 images serait trop gros.
RegisterNetEvent('vt:chunk', function(label, rows)
    local p = state.pending[label]
    if not p then return end
    local dst = p.samples
    for i = 1, #rows do
        dst[#dst + 1] = rows[i]
    end
    state.progress = #dst
end)

RegisterNetEvent('vt:done', function(label, summary, err)
    local p = state.pending[label]
    state.busy = false
    state.progress = nil
    if not p then
        state.lastError = err or 'essai inconnu : ' .. tostring(label)
        return
    end
    state.pending[label] = nil

    if err then
        state.lastError = err
        print(('[vehicle-telemetry] ECHEC « %s » : %s'):format(label, err))
        return
    end

    local doc = {
        label = label,
        meta = p.meta,
        summary = summary,
        sampleCount = #p.samples,
        samples = p.samples,
    }
    local ok = SaveResourceFile(RESOURCE, 'out/' .. label .. '.json', json.encode(doc), -1)
    state.results[label] = {
        sampleCount = #p.samples,
        summary = summary,
        saved = ok and true or false,
        at = os.time(),
    }
    print(('[vehicle-telemetry] « %s » : %d echantillons, enregistre=%s')
        :format(label, #p.samples, tostring(ok and true or false)))
end)

RegisterNetEvent('vt:probeResult', function(data)
    state.probe = data
    state.busy = false
end)

RegisterNetEvent('vt:progress', function(label, info)
    state.progress = info
end)

-- --------------------------------------------------------------- routes

local function handleRun(body, res)
    local data = json.decode(body or '{}') or {}
    if state.busy then
        return json_response(res, { error = 'un essai est deja en cours', label = state.label }, 409)
    end
    local target = firstPlayer()
    if not target then
        return json_response(res, { error = 'aucun joueur connecte' }, 503)
    end
    local label = data.label or (tostring(data.test or 'test') .. '_' .. tostring(os.time()))
    state.busy = true
    state.label = label
    state.test = data.test
    state.lastError = nil
    TriggerClientEvent('vt:run', target, label, data.test, data.params or {})
    json_response(res, { ok = true, label = label, test = data.test, player = target })
end

local function handleProbe(body, res, kind)
    local data = json.decode(body or '{}') or {}
    local target = firstPlayer()
    if not target then
        return json_response(res, { error = 'aucun joueur connecte' }, 503)
    end
    state.probe = nil
    TriggerClientEvent(kind == 'curb' and 'vt:curbscan' or 'vt:probe', target, data)
    -- la reponse arrive par evenement : on attend un court instant
    CreateThread(function()
        local t0 = GetGameTimer()
        while state.probe == nil and GetGameTimer() - t0 < 20000 do
            Wait(50)
        end
        if state.probe == nil then
            json_response(res, { error = 'pas de reponse du client' }, 504)
        else
            json_response(res, { ok = true, data = state.probe })
        end
    end)
end

SetHttpHandler(function(req, res)
    local path = (req.path or '/'):gsub('%?.*$', '')
    local query = (req.path or ''):match('%?(.*)$') or ''

    if req.method == 'POST' then
        req.setDataHandler(function(body)
            if path == '/run' then
                handleRun(body, res)
            elseif path == '/stop' then
                local target = firstPlayer()
                if target then TriggerClientEvent('vt:stop', target) end
                state.busy = false
                json_response(res, { ok = true })
            elseif path == '/probe' then
                handleProbe(body, res, 'probe')
            elseif path == '/curbscan' then
                handleProbe(body, res, 'curb')
            else
                json_response(res, { error = 'route inconnue : ' .. path }, 404)
            end
        end)
        return
    end

    if path == '/status' then
        return json_response(res, {
            busy = state.busy,
            test = state.test,
            label = state.label,
            progress = state.progress,
            lastError = state.lastError,
            players = GetPlayers(),
            resultCount = (function() local n = 0 for _ in pairs(state.results) do n = n + 1 end return n end)(),
        })
    end

    if path == '/results' then
        return json_response(res, state.results)
    end

    if path == '/result' then
        local id = query:match('id=([^&]+)')
        if not id then return json_response(res, { error = 'parametre id manquant' }, 400) end
        local data = LoadResourceFile(RESOURCE, 'out/' .. id .. '.json')
        if not data then return json_response(res, { error = 'trace inconnue : ' .. id }, 404) end
        res.writeHead(200, { ['Content-Type'] = 'application/json; charset=utf-8' })
        return res.send(data)
    end

    if path == '/tests' then
        return json_response(res, {
            'accel', 'brake', 'handbrake', 'corner', 'reverse', 'curb', 'hill',
            'coast', 'stepsteer', 'slalom', 'handling', 'raw', 'surfscan', 'roadscan', 'heightprobe',
            'modelprobe', 'buildstep', 'clearstep', 'hillprobe',
        })
    end

    return json_response(res, {
        name = 'vehicle-telemetry',
        routes = { '/status', '/tests', '/results', '/result?id=', 'POST /run', 'POST /stop', 'POST /probe', 'POST /curbscan' },
    })
end)

print('[vehicle-telemetry] pret — HTTP sur /' .. RESOURCE .. '/')
