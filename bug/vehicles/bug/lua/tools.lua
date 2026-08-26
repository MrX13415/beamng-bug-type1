-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Tool to list and spawn vehicle configs, as well as list input actions for testing purposes.
-- v1.0
-- by MrX13415 (2025-07-25)

local M = {}

local spawnConfigsTimer = 0
local spawnConfigs = {}

local function getConfigName(fn)
    return string.match(fn, "([^./]*).pc")
end

local function getConfigPaths()
    return FS:findFiles(v.vehicleDirectory, '*.pc', 0, true, false)
end

local function isInternal(name)
    return name:lower():find("bug_") == 1
end


local function getConfigs(includeCustom)
    includeCustom = includeCustom or false
    local configlist = {}
    for index,config in ipairs(getConfigPaths()) do
        local name = getConfigName(config)
        if name and includeCustom or isInternal(name) then
            table.insert(configlist, name)
        end
    end
    return configlist
end

local function findConfig(str, includeCustom)
    includeCustom = includeCustom or false
    for _,config in ipairs(getConfigs(includeCustom)) do
        if config:lower():find(str:lower()) then 
          return config
        end
    end
    return nil
end


local function listConfigs(includeCustom)
    includeCustom = includeCustom or false
    for index,config in ipairs(getConfigs(includeCustom)) do
        print(tostring(index-1)..": "..config)
    end
end


local function doSpawnConfig(config)
    local model = "bug"
    if not config then return end

    print("Spawning config: " .. config)
    obj:queueGameEngineLua(string.format([[
        local model, config = "%s","%s.pc"
        core_vehicles.spawnNewVehicle(model, {config = config})
    ]], model, config))
end

local function doSpawnConfigNext(dt)
    if #spawnConfigs == 0 then return end

    spawnConfigsTimer = spawnConfigsTimer + dt
    -- update rate: 1 fps (1.000 == 1000ms)
    if spawnConfigsTimer > 1.000 then
        spawnConfigsTimer = 0
        
        local config = spawnConfigs[1]
        table.remove(spawnConfigs, 1)
    
        doSpawnConfig(config)
    end
end

local function addSpawnConfig(config)
    if not config then return end
    table.insert(spawnConfigs, config)
end

local function spawnConfig(name)
    local model = "bug"
    local config = nil

    if not name then
        print("No config name or index provided!")
        return
    end

    -- "All" will only spawn internal configs.
    if name:lower() == "all" then
        spawnConfigs = {}
        print("Spawning " .. tostring(#getConfigs(false)) .. " configs...")
        for _,config in ipairs(getConfigs(false)) do
            addSpawnConfig(config)
        end
        return
    end 
    
    if type(name) == "number" then
        config = getConfigName(getConfigPaths()[name+1])
    elseif type(name) == "string" then
        config = findConfig(name)
    end
    if not config then
        print("config not found!")
        return
    end

    addSpawnConfig(config)
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

local function help()
    print("Available commands:")
    print("  listConfigs() - List all available vehicle configs")
    print("  spawnConfig(<name>|<index>) - Spawn a vehicle with the specified config name or index")
    print("  listInputActions() - List all input actions for testing purposes")
    print("  help() - Show this help message")
end

local function updateGFX(dt)
    doSpawnConfigNext(dt)
end

-------- DEBUG --------
function Dump(o, level, max)
  level = level or 0
  max = max or -1
  if max >= 0 and level > max then return "/*...*/" end

  local indent = string.rep("  ",level) or ""
  if type(o) == 'table' then
    local s = '{\n'
    for k,v in pairs(o) do
      if type(k) ~= 'string' then k = '['..tostring(k)..']' end
      s = s .. indent .. '  "'..k..'": ' .. Dump(v, level + 1, max) .. ',\n'
    end
    return s .. indent .. '}'
  elseif type(o) == 'number' and o ~= math.huge then
    return tostring(o)
  else
    return '"'..tostring(o)..'"'
  end
end
function DumpFile(name,data)
  writeFile("debug/"..name..".json", Dump(data))
end
function DumpFiles(name,data,n)
  n = n or ""
  local s = ""
  for k,v in pairs(data) do
    if type(v) == 'table' then
      writeFile("debug/"..name.."."..n..k..".json", Dump(v))
    else
      s = s..Dump(v)
    end 
  end
  writeFile("debug/"..name..".json", s)
end
-----------------------

M.updateGFX = updateGFX

-- public interface
M.help = help
M.listConfigs = listConfigs
M.spawnConfig = spawnConfig
M.listInputActions = listInputActions

---DEBUG---
M.Dump = Dump
M.DumpFile = DumpFile
M.DumpFiles = DumpFiles
-----------

return M