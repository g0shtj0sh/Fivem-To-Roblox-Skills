--!nonstrict
--[[
	Installe ou met à jour les modules runtime FiveMVehicles dans la place ouverte
	(ReplicatedStorage.FiveMVehicles, ServerScriptService.FiveMVehiclesServer,
	StarterPlayerScripts.FiveMVehiclesClient). Une fois par place : le Setup compact
	d'un véhicule (studio/<nom>_Setup.studio.lua) vérifie seulement la version.
	Généré par fivem-vehicle-to-roblox — ne pas éditer à la main.
]]
local RUNTIME_VERSION = __RUNTIME_VERSION__
local SOURCES = __RUNTIME_SOURCES__

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local folder = ReplicatedStorage:FindFirstChild("FiveMVehicles") or Instance.new("Folder")
folder.Name = "FiveMVehicles"
folder.Parent = ReplicatedStorage
local previous = folder:GetAttribute("RuntimeVersion")

local function upsert(parent, className, name, source)
	local obj = parent:FindFirstChild(name)
	if obj and obj.ClassName ~= className then
		obj:Destroy()
		obj = nil
	end
	obj = obj or Instance.new(className)
	obj.Name = name
	if source then
		obj.Source = source
	end
	obj.Parent = parent
	return obj
end

upsert(folder, "ModuleScript", "VehicleRuntime", SOURCES.VehicleRuntime)
upsert(folder, "ModuleScript", "VehicleCustomization", SOURCES.VehicleCustomization)
upsert(folder, "ModuleScript", "VehicleInput", SOURCES.VehicleInput)
upsert(folder, "ModuleScript", "VehicleAccess", SOURCES.VehicleAccess)
upsert(folder, "ModuleScript", "VehicleDynamics", SOURCES.VehicleDynamics)
upsert(folder, "ModuleScript", "VehicleDrive", SOURCES.VehicleDrive)
upsert(folder, "ModuleScript", "VehicleSeatFit", SOURCES.VehicleSeatFit)
upsert(folder, "ModuleScript", "VehicleLights", SOURCES.VehicleLights)
upsert(folder, "ModuleScript", "VehicleCollision", SOURCES.VehicleCollision)
upsert(folder, "ModuleScript", "VehicleDashboard", SOURCES.VehicleDashboard)
upsert(folder, "ModuleScript", "VehiclePose", SOURCES.VehiclePose)
upsert(folder, "ModuleScript", "VehicleCamera", SOURCES.VehicleCamera)
upsert(folder, "ModuleScript", "VehicleTyreFx", SOURCES.VehicleTyreFx)
upsert(folder, "ModuleScript", "VehicleBackfire", SOURCES.VehicleBackfire)
upsert(folder, "RemoteEvent", "VehicleEvent")
if not folder:FindFirstChild("VehicleTelemetry") then
	local ok = pcall(function()
		upsert(folder, "UnreliableRemoteEvent", "VehicleTelemetry")
	end)
	if not ok then
		upsert(folder, "RemoteEvent", "VehicleTelemetry")
	end
end
upsert(ServerScriptService, "Script", "FiveMVehiclesServer", SOURCES.Server)
upsert(StarterPlayer:WaitForChild("StarterPlayerScripts"), "LocalScript", "FiveMVehiclesClient", SOURCES.Client)
folder:SetAttribute("RuntimeVersion", RUNTIME_VERSION)

return { ok = true, runtimeVersion = RUNTIME_VERSION, previous = previous }
