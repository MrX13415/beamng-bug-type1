-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Common functions library.
-- by MrX13415

local M = {}


-- Math

local function round(num, numDecimalPlaces)
	local mult = 10^(numDecimalPlaces or 0)
	return math.floor(num * mult + 0.5) / mult
end


-- Translation

-- TODO: Make a better interface which don't
--       require hardcoded translations keys here.
local translationCache = {
  ["ui.bug.batteryinfo.time.seconds"]   = "seconds",
  ["ui.bug.batteryinfo.time.minutes"]   = "minutes",
  ["ui.bug.batteryinfo.time.hours"]     = "hours",
  ["ui.bug.batteryinfo.time.days"]      = "days",
  ["ui.bug.batteryinfo.time.weeks"]     = "weeks",
  ["ui.bug.batteryinfo.time.months"]    = "months",
  ["ui.bug.batteryinfo.time.years"]     = "years",
	["ui.bug.hrb.event.crash.no"]         = "No crash",
  ["ui.bug.hrb.event.crash.small"]      = "Small crash",
  ["ui.bug.hrb.event.crash.medium"]     = "Medium crash",
  ["ui.bug.hrb.event.crash.hard"]       = "Hard crash",
  ["ui.bug.hrb.event.wheelie"]          = "Wheelie",
  ["ui.bug.hrb.event.drift"]            = "Drift",
  ["ui.bug.hrb.event.jump"]             = "Jump",
  ["ui.bug.hrb.event.jump.incomplete"]  = "Incomplete Jump",
}

local function translate(key)
    if translationCache[key] then
        return translationCache[key]
    end
    log("W", "", "[Bug] Missing translation for key: "..key)
    return key
end

function OnTranslationCallback(key, result)
  translationCache[key] = result
end
local function loadTranslationCache(key)
  for key, _ in pairs(translationCache) do
    obj:queueGameEngineLua(string.format([[
      local key = "%s"
      local result = core_locales.translate(key)
      be:getPlayerVehicle(0):queueLuaCommand('OnTranslationCallback("'..key..'","'..tostring(result)..'")')
    ]], key))
  end
end


-- JBeam

local function getNodeIDbyName(nodename)
	local nodeID = nil
	for i, node in pairs (v.data.nodes) do
		if node.name == nodename then
			nodeID = node.cid
		end
	end
	return nodeID
end


-- Sound

local function createSFX(event, node, eventID)
  local soundNode = getNodeIDbyName(node)
  local sound = obj:createSFXSource2(event, "AudioClosestLoop3D", eventID, soundNode, 0)
  return sound
end

local function playSound(soundname, nodeSFX)
  sounds.playSoundOnceAtNode(soundname, nodeSFX, 1, 1, 0, 0)
end


-- String conversion

local function toUnit(value, unit, m, d)
  local u = ""
  m = m or 1

  if math.abs(value) ~= 0 then
    d = d or 1
    if math.abs(value) < m then
      u = "m"
      value = value * 1000
    end
    if math.abs(value) < m then
      u = "u"
      value = value * 1000
    end
    if math.abs(value) < m then
      u = "n"
      value = value * 1000
    end
  end

  if not unit or #unit == 0 then
    u = ""
  else
    u = u .. unit
  end

  d = d or 0
  return string.format("%."..tostring(d).."f"..u, value)
end
local function toTime(value, useTranslation)
  local u = "minutes"
  local d = 0
  local v = value

  if value == 0 then
    d = 0
  elseif value < 1.5 then
    u = "seconds"
    d = 0
    value = value * 60
  else
    if value > (3 * 60) then
      u = "hours"
      d = 1
      value = value / 60

      if value > 48 then
        u = "days"
        d = 1
        value = value / 24

        if value > 14 then
          u = "weeks"
          d = 1
          value = value / 7

          if value > 8 then
            u = "months"
            d = 1
            value = value / 4

            if value > 24 then
              u = "years"
              d = 1
              value = value / 12
            end
          end
        end
      end
    end
  end
  
  if useTranslation then
    u = translate("ui.bug.batteryinfo.time."..u) or u
  end

  --if value ~= v then
  --  u = string.format(u.." (%.2f minutes)", v)
  --end
  return string.format("%."..tostring(d).."f "..u, value)
end
local function executeLua(cmd)
  local cmd = "local r = "..cmd.."; return r"
  local f = assert(load(cmd))
  return f()
end


-- Initialization

local function onInit()
  loadTranslationCache()
end


M.onInit    = onInit


-- Public interface
M.round           = round

M.translate       = translate
M.getNodeIDbyName = getNodeIDbyName

M.createSFX       = createSFX
M.playSound       = playSound

M.toUnit          = toUnit
M.toTime          = toTime
M.executeLua      = executeLua

return M
