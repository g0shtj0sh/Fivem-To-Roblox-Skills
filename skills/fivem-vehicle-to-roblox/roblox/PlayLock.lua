--!nonstrict
--[[
	PlayLock.lua — tour de rôle pour le mode Play quand plusieurs agents travaillent dans le même Studio.

	Studio n'a qu'une session Play : un agent qui la lance ou l'arrête pendant les essais d'un autre
	fausse ses mesures. Conversion, upload et installation (Edit) restent en parallèle ; seuls les
	essais en Play passent un par un.

	Le verrou est un attribut de ServerStorage (édition) : F2R_PlayLock = "<propriétaire>",
	F2R_PlayLockAt = os.time() de la prise / du dernier renouvellement. Chaque appel est exécuté sans
	yield, donc atomique vis-à-vis des autres scripts execute_luau.

	Usage (execute_luau, mode Edit, AVANT start_stop_play) :
		local L = require(game.ReplicatedStorage.rbxts_include.F2R_Transfer.PlayLock)
		return L.acquire("<nom>-<id aléatoire>")   -- { ok = true } ou { ok = false, owner, age, waitHint }
	Si ok = false : attendre ~waitHint secondes et redemander. Ne JAMAIS lancer le Play sans ok = true.
	Pendant les essais longs : L.renew(owner) toutes les quelques minutes.
	Après start_stop_play(is_start = false) : L.release(owner).
	Un verrou non renouvelé depuis TTL secondes (agent planté) est repris automatiquement.
]]
local ServerStorage = game:GetService("ServerStorage")

local L = {}
L.TTL = 600

local function state()
	return ServerStorage:GetAttribute("F2R_PlayLock"), ServerStorage:GetAttribute("F2R_PlayLockAt") or 0
end

function L.status()
	local owner, at = state()
	return { owner = owner, age = owner and (os.time() - at) or nil, ttl = L.TTL }
end

function L.acquire(owner, ttl)
	assert(type(owner) == "string" and owner ~= "", "propriétaire requis")
	ttl = ttl or L.TTL
	local cur, at = state()
	local age = os.time() - at
	if cur == nil or cur == owner or age > ttl then
		ServerStorage:SetAttribute("F2R_PlayLock", owner)
		ServerStorage:SetAttribute("F2R_PlayLockAt", os.time())
		return { ok = true, owner = owner, tookOverFrom = (cur ~= nil and cur ~= owner) and cur or nil }
	end
	return { ok = false, owner = cur, age = age, waitHint = 20 }
end

function L.renew(owner)
	local cur = state()
	if cur ~= owner then
		return { ok = false, owner = cur }
	end
	ServerStorage:SetAttribute("F2R_PlayLockAt", os.time())
	return { ok = true }
end

function L.release(owner)
	local cur = state()
	if cur == owner then
		ServerStorage:SetAttribute("F2R_PlayLock", nil)
		ServerStorage:SetAttribute("F2R_PlayLockAt", nil)
		return { ok = true }
	end
	return { ok = false, owner = cur }
end

return L
