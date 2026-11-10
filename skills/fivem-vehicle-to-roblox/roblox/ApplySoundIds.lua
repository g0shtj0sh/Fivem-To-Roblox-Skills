--!nonstrict
--[[
	ApplySoundIds.lua — renseigne les SoundId d'un véhicule déjà installé, sans le réinstaller.
	Chaque Sound créé par le Setup porte l'attribut SourceFile (ex. "engine_on_1.wav").

	Entrées (execute_luau) :
		_G.F2R_TARGET    : le Model du véhicule (défaut : premier modèle tagué FiveMVehicle)
		_G.F2R_SOUND_IDS : table { ["engine_on_1.wav"] = "rbxassetid://123", ... }
		                   ou le texte JSON de sounds/sound_ids.json
	Renvoie { set = n, missing = { fichiers sans id } }.
]]
local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")

local model = _G.F2R_TARGET
local ids = _G.F2R_SOUND_IDS
_G.F2R_TARGET, _G.F2R_SOUND_IDS = nil, nil
if type(ids) == "string" then
	ids = HttpService:JSONDecode(ids)
end
assert(type(ids) == "table", "_G.F2R_SOUND_IDS manquant")
if not model then
	for _, m in ipairs(CollectionService:GetTagged("FiveMVehicle")) do
		if m:IsDescendantOf(workspace) then
			model = m
			break
		end
	end
end
assert(model, "véhicule introuvable")

local set, missing = 0, {}
for _, s in ipairs(model:GetDescendants()) do
	if s:IsA("Sound") then
		local file = s:GetAttribute("SourceFile")
		local id = file and ids[file]
		if id then
			if type(id) == "number" or string.match(tostring(id), "^%d+$") then
				id = "rbxassetid://" .. tostring(id)
			end
			s.SoundId = id
			set += 1
		elseif file then
			table.insert(missing, file)
		end
	end
end
return { set = set, missing = missing }
