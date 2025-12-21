-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- v1.0
-- by MrX13415

local M = {}

local updateTime = 2 -- Force immediate update on start
local animations = {}
local animationsActive = {}
local animationsWait = {}

local function isActionInRange(value, min, max)
  if min > max then
    min, max = max, min
  end
  return value == nil or value >= min and value < max
end

local function getValue(name)
  return electrics.values["anim__"..name]
end

local function setValue(name, value)
  electrics.values["anim__"..name] = value
end

local function get(name)
  return animations[name]
end

local function isActive(name)
  return animationsActive[name] ~= nil
end

local function getActiveData(name)
  return animationsActive[name]
end

local function runAction(name, index)
  local anim = animations[name]
  if anim == nil or anim.actions == nil then return end

  local action = anim.actions[index or 1]
  if action == nil then return end
  
  local actionFunc = action[2]
  if actionFunc ~= nil then
    actionFunc()
  end
end

-- Options are expected as a table.<br/>
-- Supported options are:<br/>
-- invert=true|false    - Animation is inverted for negative direction
-- speed=0.016          - The target duration per animation step in ms.
local function setup(name, curve, actions, options)
  local c = createCurve(curve or {0, 1}) -- Default curve: linear
  animations[name] = {
    curve = c,
    updateTime = 2,  -- Force immediate update on start
    actions = actions,
    options = options or {}
  }
end

local function start(name, direction)
  if animationsActive[name] ~= nil then
    return
  end

  local anim = animations[name]
  if anim == nil then
    log("D", "", "[Bug:Animation] Animation '" .. name .. "' not found!")
    return
  end

  local direction = (direction and direction < 0) and -1 or 1
  local startValue = anim.curve[direction < 0 and #anim.curve or 0]

  animationsActive[name] = {
    index = 0,
    direction = direction,
    value = startValue,
    smoother = newTemporalSmoothing(6, 6, 0, startValue)
  }
end

local function startWait(name, direction, condition)
  animationsWait[name] = { direction, condition }
end

local function updateAnimations(dt)
  -- Start waiting animations
  for name, waitData in pairs(animationsWait) do
    local direction = waitData[1]
    local conditionFunc = waitData[2]
    if conditionFunc() then
      start(name, direction)
      animationsWait[name] = nil
    end
  end

  -- Update active animations
  for name, data in pairs(animationsActive) do
    local anim = animations[name]
    
    local index = data.index
    local dir = data.direction
    local invert = dir < 0 and (anim.options.invert or false)
    
    local tm = math.ceil(dt / (anim.options.speed or 0.016)) -- ms
    local nextIndex = index + (dir * tm)

    local pos = math.max(0, math.min(#anim.curve, math.abs(index)))
    if invert then
      pos = #anim.curve - pos
    end

    for i, action in pairs(anim.actions or {}) do
      -- Checkin index here, to allow different actions for each direcion
      if isActionInRange(action[1], index, nextIndex) then
        --print("[Bug:Animation] " .. name .. ": Action " ..tostring(i))
        local actionFunc = action[2]
        if actionFunc ~= nil then
          actionFunc()
        end
      end
    end

    local value = anim.curve[pos]
    if dir < 0 and not invert then
      value = 1 - value
    end

    data.index = nextIndex
    data.value = value
    --print("[Bug:Animation] anim__" .. name .. ": ["..tostring(pos)..(dir < 0 and " - 1" or " + 1").."] = " .. tostring(value))

    if (invert and pos <= 0) or (not invert and pos >= #anim.curve) then
      setValue(name, value)
      animationsActive[name] = nil
    end
  end
end

local function updateAnimationValues(dt)
  for name, data in pairs(animationsActive) do
    local v = data.value
    if data.smoother ~= nil and data.value ~= nil then
      v = data.smoother:get(v, dt)
    end
    setValue(name, v)
  end
end

local function updateGFX(dt)
  updateTime = updateTime + dt
  -- update rate: 60 fps (0.016 == 16ms)
  if updateTime >= 0.016 then
    updateAnimations(updateTime)
    updateTime = 0
  end

  updateAnimationValues(dt)
end

local function onReset()
  animationsActive = {}
  animationsWait = {}
end

M.onReset   = onReset
M.updateGFX = updateGFX

-- public interface
M.setup           = setup
M.start           = start
M.startWait       = startWait
M.get             = get
M.isActive        = isActive
M.getActiveData   = getActiveData
M.runAction       = runAction
M.getValue        = getValue
M.setValue        = setValue

return M
