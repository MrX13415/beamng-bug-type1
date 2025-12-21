-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- by MrX13415

local M = {}

local updateTimer = 2   -- Make sure the first call is immediately

local NodeSFX = "dsh"
local NodeSFXWipers = "wi1"
local SFXOn     = "event:>Vehicle>Interior>Light>FIPA_On"
local SFXOff    = "event:>Vehicle>Interior>Light>FIPA_Off"
local SFXWipers = "vehicles/bug/components/sounds/common/windshild-wipers.ogg"
local SFXWipersVolume = 0.5
local MaxSpeedLevel = 3

local wipersSfx = nil
local wipersSpeed1 = 0.02   -- 833ms (60fps)
local wipersSpeed2 = 0.021  -- 793ms (60fps)
local wipersSpeed3 = 0.023  -- 757ms (60fps)
local wipersBreak1 = 120    -- 2 sec. (60fps)
local wipersBreak2 = 30     -- 0.5 sec. (60fps)
local wipersBreak3 = 0      -- 0 sec.
local wipersValue = 0
local wipersBreak = 0
local wipersDirection = 1
local wipersStateDirection = 1

local wipersMessageOn = "Wipers: On"
local wipersMessageLookup = {
  [0] = "Wipers: Off",
  [1] = "Wipers: Level 1",
  [2] = "Wipers: Level 2",
  [3] = "Wipers: Level 3",
}

local function hasPower() return electrics.values.ignitionLevel > 0 and electrics.values.powerAvailable > 0 end

local function createSFX(event, node, eventID)
  local soundNode = getNodeIDbyName(node)
  local sound = obj:createSFXSource2(event, "AudioClosestLoop3D", eventID, soundNode, 0)
  return sound
end

local function playSound(soundname)
  sounds.playSoundOnceAtNode(soundname, getNodeIDbyName(NodeSFX), 1, 1, 0, 0)
end

local function getMessage(state)
  if MaxSpeedLevel == 1 and state == 1 then
    return wipersMessageOn
  end
  return wipersMessageLookup[state]
end

local function updateWipers()
  local state = electrics.values["wipersstate"] or 0

  if not hasPower() then
    if wipersSfx then obj:cutSFX(wipersSfx) end
    return 
  end

  if wipersBreak > 0 then
    if wipersSfx then obj:cutSFX(wipersSfx) end
    wipersBreak = wipersBreak - 1
    return
  end

  if state > 0 or wipersValue > 0 then
    local s = wipersSpeed3
    if state < 2 then s = wipersSpeed1
    elseif state < 3 then s = wipersSpeed2 
    end
    
    if wipersValue == 0 then
      wipersSfx = wipersSfx or createSFX(SFXWipers, NodeSFXWipers, "wipers")
      if wipersSfx then 
        obj:playSFX(wipersSfx)
        local sfxLength = 2100                     -- ms
        local wiperDuration = 1000 / (60 * s) * 3  -- ms [1sec / (60fps * wiperSpeed) * 2]
        local sfxMod = 1 / wiperDuration * sfxLength
        obj:setVolumePitchCT(wipersSfx, SFXWipersVolume, sfxMod, 1, 1)
      end
    end

    wipersValue = wipersValue + (s * wipersDirection)

    if wipersValue >= 1 then
       wipersDirection = -1 
       wipersValue = 1
    end

    if wipersValue <= 0 then
      wipersDirection = 1
      wipersValue = 0
      if state < 2 then wipersBreak = wipersBreak1
      elseif state < MaxSpeedLevel then wipersBreak = wipersBreak2
      else wipersBreak = wipersBreak3
      end
    end
  end

  electrics.values["wipers"] = wipersValue
end

local function updateGFX(dt)
  updateTimer = updateTimer + dt
	-- update rate: 60 fps (0.016 == 16ms)
	if updateTimer > 0.016 then 
    updateTimer = 0
    updateWipers()
  end
end

local function onInit(jbeam)
  NodeSFX = jbeam.nodeSFX or NodeSFX
  NodeSFXWipers = jbeam.nodeSFXWipers or NodeSFXWipers
  SFXOn = jbeam.sfxOn or SFXOn
  SFXOff = jbeam.sfxOff or SFXOff
  SFXWipers = jbeam.sfxWipers or SFXWipers
  SFXWipersVolume = jbeam.sfxWipersVolume or SFXWipersVolume

  MaxSpeedLevel = math.min(math.max(jbeam.maxSpeedLevel or MaxSpeedLevel,0), 3)

  wipersSpeed1 = jbeam.wipersSpeed or wipersSpeed1
  wipersBreak1 = jbeam.wipersBreak or wipersBreak1
  
  wipersSpeed1 = math.max(jbeam.wipersSpeed1 or wipersSpeed1, 0.01)
  wipersSpeed2 = math.max(jbeam.wipersSpeed2 or wipersSpeed2, 0.01)
  wipersSpeed3 = math.max(jbeam.wipersSpeed3 or wipersSpeed3, 0.01)
  wipersBreak1 = math.max(jbeam.wipersBreak1 or wipersBreak1, 0.01)
  wipersBreak2 = math.max(jbeam.wipersBreak2 or wipersBreak2, 0.01)
  wipersBreak3 = math.max(jbeam.wipersBreak3 or wipersBreak3, 0.01)

  electrics.values["wipersstate"] = 0
end


local function toggle()
  local state = electrics.values["wipersstate"] or 0
  if state <= 0 then wipersStateDirection = 1 end
  if state >= MaxSpeedLevel then
    wipersStateDirection = -1
  end
  playSound(state > 0 and SFXOn or SFXOff)
  state = state + wipersStateDirection
  electrics.values["wipersstate"] = state
  guihooks.message({txt = getMessage(state), context = {}}, 4, "vehicle.wipers")
end

local function up()
  local state = electrics.values["wipersstate"] or 0
  if state < MaxSpeedLevel then
    state = state + 1
    playSound(SFXOn)
  end
  electrics.values["wipersstate"] = state
  guihooks.message({txt = getMessage(state), context = {}}, 4, "vehicle.wipers")
end

local function down()
  local state = electrics.values["wipersstate"] or 0
  if state > 0 then 
    state = state - 1
    playSound(SFXOff)
  end
  electrics.values["wipersstate"] = state
  guihooks.message({txt = getMessage(state), context = {}}, 4, "vehicle.wipers")
end

-- Public Interface
-- Console: controller.getController('wipers').resetData()
M.init         = onInit
M.updateGFX    = updateGFX

M.hasPower     = hasPower

M.toggle       = toggle
M.up           = up
M.down         = down


return M
