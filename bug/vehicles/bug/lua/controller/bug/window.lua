-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- by MrX13415

local M = {}

local updateTimer = 2   -- Make sure the first call is immediately
local value = 0
local speed = 0.013
local direction = 0
local directionLast = 0
local name = "window"

local sfxNode = nil
local sfxEvent = nil
local sfxVolume = 0.7
local sfx = nil

-- common
local function round(num, numDecimalPlaces)
  local mult = 10^(numDecimalPlaces or 0)
  return math.floor(num * mult + 0.5) / mult
end


local function createSFX(event, node)
  local soundNode = getNodeIDbyName(node)
  local sound = obj:createSFXSource2(event, "AudioClosestLoop3D", "windowroll", soundNode, 0)
  if sound then obj:setVolume(sound, sfxVolume) end
  return sound
end

local function updateWindow(dt)
  directionLast = direction
  direction = electrics.values[name .. "_input"] or 0

  if direction ~= directionLast then
    if sfxEvent and sfxNode then
      sfx = sfx or createSFX(sfxEvent, sfxNode)
    end
    if sfx then 
      obj:cutSFX(sfx)
      if direction ~= 0 then
        obj:playSFX(sfx) 
      end
    end
  end

  value = value + (speed * direction)
  -- window is fully closed
  if value <= 0 then
     value = 0
     if sfx then obj:cutSFX(sfx) end
  end
  -- window is fully open
  if value >= 1 then
    value = 1
    if sfx then obj:cutSFX(sfx) end
  end

  electrics.values[name .. "_state"] = value

  --print("window: " .. value)
end

local function updateGFX(dt)
  updateTimer = updateTimer + dt
	-- update rate: 30 fps (0.033 == 33ms)
	if updateTimer < 0.033 then return end

  updateWindow(updateTimer)

  updateTimer = 0
end

local function onReset()
  value = electrics.values[name .. "_state"]
  log("D", "", "[Bug:Window] ".. name.. ": " .. tostring(value*100) .. "% open")
end

local function onInit(jbeamData)
  name = jbeamData.name or name
  speed = jbeamData.speed or speed
  sfxNode = jbeamData.sfxNode
  sfxEvent = jbeamData.sfx
  value = jbeamData.state or 0
  electrics.values[name .. "_state"] = value
  log("D", "", "[Bug:Window] ".. name.. ": Initialized " .. tostring(value*100) .. "% open")
end

local function open(value)
  electrics.values[name .. "_input"] = (value or 1)
end

local function close(value)
  electrics.values[name .. "_input"] = (value or 1) * -1
end

M.init      = onInit
M.reset     = onReset
M.updateGFX = updateGFX

-- Public Interface
-- Console: controller.getController('windowFL').open()
M.open = open
M.close = close

return M
