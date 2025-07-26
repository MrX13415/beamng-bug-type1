-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- v1.0
-- by MrX13415

local M = {}

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
    for index,config in ipairs(getConfigPaths()) do
        print(tostring(index-1)..": "..getConfigName(config))
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

    print("Spawning config: " .. config)

    obj:queueGameEngineLua(string.format([[
        local model, config = "%s","%s.pc"
        core_vehicles.spawnNewVehicle(model, {config = config})
    ]], model, config))
end


local function listInputActions()
    print("Input Actions:")

    local actions = {}
    for name,_ in pairs(v.data.inputActions) do
        table.insert(actions, name)
    end

    table.sort(actions)

    for _,name in pairs(actions) do
        print("  "..name)
    end
end

-- public interface
M.listConfigs = listConfigs
M.spawnConfig = spawnConfig
M.listInputActions = listInputActions

return M