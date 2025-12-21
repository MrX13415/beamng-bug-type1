-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local _name = "Volkswagen Type 1 \"Beetle\""
local _version = 26
local _versionDate = "2025-12-12"
local _variantID = "VW"

 -- Minimum required BeamNG.drive version
local _gameVersion = 37

local function name() return _name end
local function version() return _version end
local function versionDate() return _versionDate end
local function variantID() return _variantID end


local function gameVersionError(beamng_version)
    local msgTitle = "Outdated BeamNG.drive Version for Mod: " .. _name
    local msgText = "This mod requires a newer version of BeamNG.drive to function properly. Please update to at least BeamNG.drive 0." .. _gameVersion .. "."
    local suffix = " Current Version: 0." .. tostring(beamng_version)
    log("E", "", "[Bug] " .. msgTitle ..": ".. msgText..suffix)

    guihooks.trigger("toastrMsg", {type="error", title=msgTitle, msg=msgText, config={closeButton=true, timeOut=0, extendedTimeOut=0}})
end

local function variantWarn(ids)
    local msgTitle = "Mod Conflict: " .. _name
    local msgText = "Both brand variants of this mod are active! Please enable only one variant at a time to avoid issues."
    local suffix = ids and (" Active IDs: " .. table.concat(ids, ", ")) or ""
    log("W", "", "[Bug] " .. msgTitle ..": ".. msgText..suffix)

    guihooks.trigger("toastrMsg", {type="warning", title=msgTitle, msg=msgText, config={closeButton=true, timeOut=0, extendedTimeOut=0}})
end

local function getActiveVariantIDs()
    local files = FS:findFiles(v.vehicleDirectory, 'VariantID-*.json', 0, true, false)

    local ids = {}
    for _, filepath in pairs(files) do
        local data = jsonReadFile(filepath)
        if data and data.variantID then
            table.insert(ids, data.variantID)
        end
    end

    return ids
end

local function checkVaraintIDs()
    local ids = getActiveVariantIDs()
    for _,id in ipairs(ids) do
        if id ~= variantID() then
            variantWarn(ids)
            return
        end
    end
end

local function printVersionLine()
    print("[Bug] " .. name() .. " by MrX13415 (Original by VertexsStyle)")
    print("[Bug] Variant '" .. variantID().. "' Version " ..tostring(version()).. " - " .. versionDate())
end


function GameVersionCallback(beamng_version)
    local major = tonumber(string.match(beamng_version or "", "^%d+%.(%d+)"))
    if major == nil or major < _gameVersion then
        gameVersionError(beamng_version)
    end
end
local function checkGameVersion()
  obj:queueGameEngineLua([[
    be:getPlayerVehicle(0):queueLuaCommand('GameVersionCallback("'..beamng_version..'")')
  ]])
end

local function onInit(jbeamData)
    checkVaraintIDs()
end
local function onExtensionLoaded(jbeamData)
    printVersionLine()
    checkGameVersion()
end

M.onExtensionLoaded = onExtensionLoaded
M.onInit            = onInit

M.name        = name
M.version     = version
M.versionDate = versionDate
M.variantID   = variantID

M.printVersionLine = printVersionLine

return M
