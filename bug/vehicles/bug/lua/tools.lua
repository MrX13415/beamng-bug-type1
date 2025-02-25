-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- v1.0
-- by MrX13415

local M = {}

-- core_vehicles.spawnNewVehicle("bug", {config = "vehicles/bug/bug.1200.auto.pc"});
-- core_vehicles.spawnNewVehicle("bug", {config = "vehicles/bug/bug.1200.eu.hardtop.pc"});
-- core_vehicles.spawnNewVehicle("bug", {config = "vehicles/bug/bug.1200.eu.ragtop.pc"});
-- core_vehicles.spawnNewVehicle("bug", {config = "vehicles/bug/bug.1200.us.hardtop.pc"});
-- core_vehicles.spawnNewVehicle("bug", {config = "vehicles/bug/bug.1200.us.ragtop.pc"});
-- core_vehicles.spawnNewVehicle("bug", {config = "vehicles/bug/bug.1600.auto.pc"});
-- core_vehicles.spawnNewVehicle("bug", {config = "vehicles/bug/bug.1600.eu.hardtop.pc"});
-- core_vehicles.spawnNewVehicle("bug", {config = "vehicles/bug/bug.1600.eu.ragtop.pc"});
-- core_vehicles.spawnNewVehicle("bug", {config = "vehicles/bug/bug.1600.us.hardtop.pc"});
-- core_vehicles.spawnNewVehicle("bug", {config = "vehicles/bug/bug.1600.us.ragtop.pc"});
-- core_vehicles.spawnNewVehicle("bug", {config = "vehicles/bug/bug.antarctica.pc"});
-- core_vehicles.spawnNewVehicle("bug", {config = "vehicles/bug/bug.barebone.pc"});
-- core_vehicles.spawnNewVehicle("bug", {config = "vehicles/bug/bug.black.pc"});
-- core_vehicles.spawnNewVehicle("bug", {config = "vehicles/bug/bug.camping.pc"});
-- core_vehicles.spawnNewVehicle("bug", {config = "vehicles/bug/bug.diesel.pc"});
-- core_vehicles.spawnNewVehicle("bug", {config = "vehicles/bug/bug.herbie.fully-loaded.pc"});
-- core_vehicles.spawnNewVehicle("bug", {config = "vehicles/bug/bug.herbie.goes-bananas-rusty.pc"});
-- core_vehicles.spawnNewVehicle("bug", {config = "vehicles/bug/bug.herbie.goes-to-monte-carlo.pc"});
-- core_vehicles.spawnNewVehicle("bug", {config = "vehicles/bug/bug.herbie.the-love-bug-1997.pc"});
-- core_vehicles.spawnNewVehicle("bug", {config = "vehicles/bug/bug.herbie.the-love-bug.pc"});
-- core_vehicles.spawnNewVehicle("bug", {config = "vehicles/bug/bug.luxury.pc"});
-- core_vehicles.spawnNewVehicle("bug", {config = "vehicles/bug/bug.offroad.pc"});
-- core_vehicles.spawnNewVehicle("bug", {config = "vehicles/bug/bug.oldrusted.pc"});
-- core_vehicles.spawnNewVehicle("bug", {config = "vehicles/bug/bug.oldrusted.restored.pc"});
-- core_vehicles.spawnNewVehicle("bug", {config = "vehicles/bug/bug.pedeboi.pc"});
-- core_vehicles.spawnNewVehicle("bug", {config = "vehicles/bug/bug.police.pc"});
-- core_vehicles.spawnNewVehicle("bug", {config = "vehicles/bug/bug.polizei.pc"});
-- core_vehicles.spawnNewVehicle("bug", {config = "vehicles/bug/bug.tuned.pc"});

local function getConfigName(fn)
    return string.match(fn, "([^./]*).pc")
end

local function getConfigPaths()
    return FS:findFiles(v.vehicleDirectory, '*.pc', 0, true, false)
end

local function findConfig(str)
    for _,fn in ipairs(getConfigPaths()) do
        local name = getConfigName(fn)
        if name and name:lower():find(str:lower()) then return name end
    end
    return nil
end

local function listConfigs()
    for _,config in ipairs(getConfigPaths()) do
        print(getConfigName(config))
    end
end

local function spawnConfig(name)
    local model = "bug"
    local config = nil

    if type(name) == "number" then
        config = getConfigName(getConfigPaths()[name+1])
    elseif type(name) == "string" then
        config = findConfig(name)
    end
    if not config then
        print("config not found!")
        return
    end

    obj:queueGameEngineLua(string.format([[
        local model, config = "%s","%s.pc"
        core_vehicles.spawnNewVehicle(model, {config = config})
    ]], model, config))
end

-- public interface
M.listConfigs = listConfigs
M.spawnConfig = spawnConfig

return M