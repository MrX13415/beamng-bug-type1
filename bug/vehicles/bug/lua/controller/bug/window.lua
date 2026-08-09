-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Controller for a hand crank window.
-- by MrX13415 & VertexStyle

local M = {}

local misc = require("vehicles/bug/lua/misc")

local name = "window"
local value = 0                       -- % 0 = fully closed, 1 = fully open
local speed = 0.013                   -- % per update

local slowingThreshold = 0.04         -- %
local slowingMinMul = 0.10            -- Don't slow down more than this (10% speed) to ensure it eventually reaches the target
local autoCloseThreshold = 0.03       -- % Auto close when below

local shortPressTime = 0.15           -- seconds
local shortPressTarget = 1.00         -- open to % on short press
local shortPressCloseThreshold = 0.05 -- % Considered closed for short press

local stuckEnabled = false            -- Enable random stuck events
local stuckChance = 0.15              -- 
local stuckDurationMin = 0.3          -- 
local stuckDurationMax = 1.2          -- 
local stuckPositionMin = 0.15         -- 
local stuckPositionMax = 0.85         -- 

------------------------------

local updateTimer = 0

local direction = 0
local directionLast = 0
local targetValue = -1

local buttonTimer = 0
local buttonState = 0

local stuckTimer = 0
local stuckState = false
local stuckDuration = 0
local stuckPause = 0.5   -- seconds

local sfxNode = nil
local sfx = {
  move = { id = "windowroll", volume = 1.0, event = nil, sound = nil },
  moveUp = { id = "windowroll_up", volume = 1.0, event = nil, sound = nil },
  moveDown = { id = "windowroll_down", volume = 1.0, event = nil, sound = nil },
  stuckStart = { id = "windowstuck_start", volume = 1.0, event = nil, sound = nil },
  stuckEnd = { id = "windowstuck_end", volume = 1.0, event = nil, sound = nil },
}

local function hasActivePart(partPath)
  for activePartPath, _ in pairs(v.data.activeParts) do
    if activePartPath == partPath then return true end
  end
  return false
end

local function initSFX(sfxtype, jbeamData)
  if not sfxtype or not jbeamData then return end
  sfxtype.event = jbeamData.event or sfxtype.event
  sfxtype.volume = jbeamData.volume or sfxtype.volume
end

local function createSFXLoop(id, event, volume)
  if not sfxNode or not event then return nil end

  local sound = obj:createSFXSource2(event, "AudioClosestLoop3D", name .. "_" .. id, misc.getNodeIDbyName(sfxNode), 0)
  if sound then obj:setVolume(sound, volume) end
  return sound
end

local function createSFXOnce(id, event, volume)
  if not sfxNode or not event then return nil end

  local sound = obj:createSFXSource2(event, "AudioClosest3D", name .. "_" .. id, misc.getNodeIDbyName(sfxNode), 0)
  if sound then obj:setVolume(sound, volume) end
  return sound
end


local function muteSFX(sfx, mute)
  if sfx.sound then obj:setVolume(sfx.sound, mute and 0 or sfx.volume) end  
end

local function stopSFX(sfx)
 if sfx.sound then obj:cutSFX(sfx.sound) end
end

local function playSFXLoop(sfx)
  if not sfx or not sfx.event then return end
  sfx.sound = sfx.sound or createSFXLoop(sfx.id, sfx.event, sfx.volume)
  if sfx.sound then    
    obj:playSFX(sfx.sound)
  end
end

local function playSFXOnce(sfx)
  if not sfx or not sfx.event then return end
  sfx.sound = sfx.sound or createSFXOnce(sfx.id, sfx.event, sfx.volume)
  if sfx.sound then
    obj:cutSFX(sfx.sound) -- Stop any existing sound before playing
    obj:playSFX(sfx.sound)
  end
end

------------------------------

local function stopMoveSFX()
  stopSFX(sfx.move)
  stopSFX(sfx.moveUp)
  stopSFX(sfx.moveDown)
end

local function muteMoveSFX(mute)
  muteSFX(sfx.move, mute)
  muteSFX(sfx.moveUp, mute)
  muteSFX(sfx.moveDown, mute)
end

local function playMoveSFX()
  if direction == directionLast then return end

  stopMoveSFX()
  if direction > 0 then
    playSFXLoop(sfx.move)
    playSFXLoop(sfx.moveDown)
  elseif direction < 0 then
    playSFXLoop(sfx.move)
    playSFXLoop(sfx.moveUp)
  end
end

local function isStuck(dt)
  if not stuckEnabled then return end

  stuckTimer = stuckTimer + dt

  -- Check if unstuck duration has passed and unstuck
  if stuckState then
    if stuckTimer >= stuckDuration then
      log("D", "", "[Bug:Window] ".. name.. ": Unstuck after " .. tostring(stuckTimer) .. " seconds")

      stuckTimer = 0
      stuckState = false
      direction = 0
      playSFXOnce(sfx.stuckEnd)
      muteMoveSFX(false)
    end

    return stuckState
  end

  -- Wait a short pause between stuck events
  if direction == 0 or stuckTimer < stuckPause then return end

  -- Chance to get stuck when moving and within the specified position range
  if value > stuckPositionMin and value < stuckPositionMax and math.random() < stuckChance then
    muteMoveSFX(true)
    playSFXOnce(sfx.stuckStart)
    stuckTimer = 0
    stuckState = true
    stuckDuration = math.random() * (stuckDurationMax - stuckDurationMin) + stuckDurationMin
    direction = 0

    log("D", "", "[Bug:Window] ".. name.. ": Stuck at " .. tostring(value*100) .. "% open for " .. tostring(stuckDuration) .. " seconds")
  end

  return stuckState
end 


local function updateWindow(dt)
  directionLast = direction
  direction = electrics.values[name .. "_input"] or 0

  if isStuck(dt) then
    return -- Don't move while stuck
  end

  -- Auto close when almost closed
  if value > 0 and value < autoCloseThreshold and direction < 1 then
    --log("D", "", "[Bug:Window] ".. name.. ": Auto closing from " .. tostring(value*100) .. "% open")
    direction = -1
    targetValue = 0
  end

  playMoveSFX();

  local directionFactor = direction
  local speedFactor = 1
  local targetDelta = targetValue >= 0 and math.abs(targetValue - value)  -- Distance to target when target is set
                    or direction > 0 and (1 - value)                      -- Distance to fully open when opening
                    or direction < 0 and value                            -- Distance to fully closed when closing
                    or 9999                                               -- No targetDelta  
  
  -- Slow down when close to target
  if targetDelta < slowingThreshold then
    speedFactor = math.max(slowingMinMul, targetDelta / slowingThreshold)
    --log("D", "", "[Bug:Window] ".. name.. ": Delta: " .. tostring(targetDelta) .. ", Speed multiplier: " .. tostring(speedFactor))
  end
  
  -- When stopping, continue a small bit to smooth out the motion instead of an abrupt stop.
  if direction == 0 and directionLast ~= 0 then
    directionFactor = directionLast
    speedFactor = 0.3  -- % 
  end

  value = value + (speed * speedFactor * directionFactor)
  -- window is fully closed
  if value <= 0 then
    value = 0
    stopMoveSFX()
  end
  -- window is fully open
  if value >= 1 then
    value = 1
    stopMoveSFX()
  end

  electrics.values[name .. "_state"] = value
  --print("window: " .. value)

  -- Auto open
  if targetValue >= 0 and (
    (direction > 0 and value >= targetValue) or
    (direction < 0 and value <= targetValue)
  ) then
    electrics.values[name .. "_input"] = 0
    targetValue = -1
  end
end

local function updateGFX(dt)
  updateTimer = updateTimer + dt

  if buttonState == 1 then
    buttonTimer = buttonTimer + dt
  end

	-- update rate: 30 fps (0.033 == 33ms)
	if updateTimer < 0.033 then return end

  updateWindow(updateTimer)

  updateTimer = 0
end

local function set(state)
  if value == state then return end
  targetValue = state
  electrics.values[name .. "_input"] = (state > value) and 1 or -1
end

local function onButton(value)
  buttonState = value

  -- holding
  if buttonState ~= 0 then return end

  local shortPress = buttonTimer < shortPressTime
  buttonTimer = 0
  if not shortPress then return end

  -- On short press, open to 70% if closed, otherwise close
  local state = electrics.values[name .. "_state"]
  local open = state < shortPressCloseThreshold
  log("D", "", "[Bug:Window] ".. name.. ": Short press: " .. tostring(state*100) .. "% open, " .. (open and "opening..." or "closing..."))

  set(open and shortPressTarget or 0) -- 70% open
end

local function open(value)
  electrics.values[name .. "_input"] = (value or 1)
  onButton(value)
end

local function close(value)
  electrics.values[name .. "_input"] = (value or 1) * -1
  onButton(value)
end

local function onReset()
  value = electrics.values[name .. "_state"]
  log("D", "", "[Bug:Window] ".. name.. ": " .. tostring(value*100) .. "% open")
end

local function onInit(jbeamData)
  name    = jbeamData.name or name
  value   = jbeamData.state or value
  speed   = jbeamData.speed or speed

  autoCloseThreshold        = jbeamData.autoCloseThreshold or autoCloseThreshold
  shortPressTarget          = jbeamData.shortPressTarget or shortPressTarget
  shortPressCloseThreshold  = jbeamData.shortPressCloseThreshold or shortPressCloseThreshold

  if type(jbeamData.stuckEnabled) == "boolean" then
    stuckEnabled = jbeamData.stuckEnabled
  elseif type(jbeamData.stuckEnabled) == "table" then
    for _, enablePart in pairs(jbeamData.stuckEnabled) do
      if hasActivePart(enablePart) then
        stuckEnabled = true
        --log("D", "", "[Bug:Window] ".. name.. ": Stuck events enabled by part: " .. tostring(enablePart))
        break
      end
    end
  end

  stuckChance               = jbeamData.stuckChance or stuckChance
  stuckDurationMin          = jbeamData.stuckDurationMin or stuckDurationMin
  stuckDurationMax          = jbeamData.stuckDurationMax or stuckDurationMax

  sfxNode = jbeamData.sfxNode
  initSFX(sfx.move, jbeamData.sfxMove)
  initSFX(sfx.moveUp, jbeamData.sfxMoveUp)
  initSFX(sfx.moveDown, jbeamData.sfxMoveDown)
  initSFX(sfx.stuckStart, jbeamData.sfxStuckStart)
  initSFX(sfx.stuckEnd, jbeamData.sfxStuckEnd)

  
  electrics.values[name .. "_state"] = value
  log("D", "", "[Bug:Window] ".. name.. ": Initialized " .. tostring(value*100) .. "% open, can stuck: " .. tostring(stuckEnabled and "Yes" or "No"))
end

M.init      = onInit
M.reset     = onReset
M.updateGFX = updateGFX

-- Public Interface
-- Console: controller.getController('windowFL').open()
M.set = set
M.open = open
M.close = close

return M
