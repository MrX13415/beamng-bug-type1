-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt


local M = {}

local updateTimer = 0

local targetLidL = 0
local targetLidR = 0
local currentLidL = 0
local currentLidR = 0

local animationSpeed = 3.0

local function lerp(current, target, speed, dt)
    local diff = target - current
    local maxStep = speed * dt
    if math.abs(diff) <= maxStep then
        return target
    else
        return current + (diff > 0 and maxStep or -maxStep)
    end
end

local function updateGFX(dt)
    -- interpolate current values to targets
    currentLidL = lerp(currentLidL, targetLidL, animationSpeed, dt)
    currentLidR = lerp(currentLidR, targetLidR, animationSpeed, dt)
    
    -- update electrics values
    electrics.values.lid_L_animated = currentLidL
    electrics.values.lid_R_animated = currentLidR
end

local function setLidL(value)
    targetLidL = math.max(-1, math.min(1, value or 0))
end

local function setLidR(value)
    targetLidR = math.max(-1, math.min(1, value or 0))
end

local function setLidBoth(value)
    local v = math.max(-1, math.min(1, value or 0))
    targetLidL = v
    targetLidR = v
end

-- set target directly
local function setTargets(left, right)
    if left then targetLidL = math.max(-1, math.min(1, left)) end
    if right then targetLidR = math.max(-1, math.min(1, right)) end
end

local function onInit(jbeamData)
    animationSpeed = jbeamData.lidAnimationSpeed or 3.0
    
    targetLidL = 0
    targetLidR = 0
    currentLidL = 0
    currentLidR = 0
    
    electrics.values.lid_L_animated = 0
    electrics.values.lid_R_animated = 0
end

local function onReset()
    targetLidL = 0
    targetLidR = 0
    currentLidL = 0
    currentLidR = 0
    
    electrics.values.lid_L_animated = 0
    electrics.values.lid_R_animated = 0
end

-- Public interface
M.init = onInit
M.reset = onReset
M.updateGFX = updateGFX

M.setLidL = setLidL
M.setLidR = setLidR
M.setLidBoth = setLidBoth
M.setTargets = setTargets

return M
