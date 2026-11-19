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


-- Coupler controllers (doors, trunk, glovebox): 0 = attached (closed), 1 = detached / broken (open)
local function getControllerState(name)
  local result = 0

  local controller = controller.getController(name)
  if not controller then return result end
  local state = controller.getGroupState()

  result = 1
  if state == 'attached' then result = 0 end
  if state == 'desyncedAttached' then result = 0 end
  if state == 'broken' then result = 1 end

  return result
end
local function setControllerState(name, state)
  local controller = controller.getController(name)
  if not controller then return end

  if state then
    controller.detachGroup()
  else
    controller.tryAttachGroupImpulse()
  end
end


-- Electrics

-- flips an electrics value between 0 and 1 and returns the new value (nil for an empty name)
local function toggle(var)
  if var == "" then return nil end
  local state = electrics.values[var] or 0
  state = state > 0 and 0 or 1
  --print(tostring(var) .. " " .. tostring(state))
  electrics.values[var] = state
  return state
end


-- GE extensions of the mod

-- Every GE extension in lua/ge/extensions/bug/ and its M.version. Bump the number here (only here) together with
-- M.version in the extension: the vehicle Lua is reloaded with each spawn, a GE extension is not, so an older
-- version that is still loaded gets reloaded.
local GE_VERSIONS = {
  bug_doorDrag = 8,
  bug_exitDoor = 8,
}

-- Load the GE extension `ext` (reload it if an older version is loaded) and run the GE Lua statement `cmd` there.
-- `guard` (optional): name of a function the extension must have, otherwise `cmd` is skipped.
local function geCall(ext, cmd, guard)
  local version = GE_VERSIONS[ext]
  if not version then
    log('E', 'bug.misc', 'geCall: unknown GE extension ' .. tostring(ext) .. ' (add it to GE_VERSIONS)')
    version = 0
  end
  local cond = guard and (ext .. " and " .. ext .. "." .. guard) or ext
  obj:queueGameEngineLua("extensions.load('" .. ext .. "'); "
    .. "if " .. ext .. " and (" .. ext .. ".version or 0) < " .. version .. " then extensions.reload('" .. ext .. "') end; "
    .. (cmd and ("if " .. cond .. " then " .. cmd .. " end") or ""))
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

M.getControllerState = getControllerState
M.setControllerState = setControllerState

M.geCall          = geCall
M.toggle          = toggle

return M
