-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local hrb = require("vehicles/bug/lua/hrb/hrb")

local updateTimer = 0
local enabled = false

--pVehID = -1
--local selfID = -1
local pPos = vec3()
local inVeh = true
local inAI = false

local messageLookup = {
  [0] = "ui.bug.hrb.follow.off",
  [1] = "ui.bug.hrb.follow.on",
  [2] = "ui.bug.hrb.follow.active",
}

  -- TODO: Ensure doors are closed before driving off
  -- TODO: Organize the herbie files.

local function setAIfollow(follow)
  if inAI == follow then return end
  inAI = follow

  if inAI then
    ai.setState({mode="follow", extAggression=0.1}) --, targetObjectID=pVehID
  else 
    ai.setState({mode="disabled"}) 
  end
end

local function update()
  if not enabled or not hrb.isEnabled() then
    setAIfollow(false) -- Ensure the AI is disabled
    return
  end

  if inVeh ~= playerInfo.firstPlayerSeated then
    inVeh = playerInfo.firstPlayerSeated

    if inVeh then
      print('[Bug:Follow] Player stepped into vehicle')
    else
      print('[Bug:Follow] Player stepped out of vehicle')
      -- TODO: How can we send UI messages when not in this vehicle? (This does not work)
      guihooks.message({txt = messageLookup[2], context = {}}, 2, "hrb.follow")

      -- ai:setTargetObjectID(pVehID)
      -- ai:startFollowing()
    end

    setAIfollow(not inVeh)
  end
 
  -- Get player position
  --[[if not inVeh then
    obj:queueGameEngineLua(
      "local ppos = be:getObjectByID("..pVehID.."):getPosition();"..
      "be:getObjectByID("..selfID.."):queueLuaCommand("..
        "'pPos = vec3('..ppos.x..','..ppos.y..','..ppos.z..')')"
    )
    -- print(tostring(pPos))
  end]]--
end

local function enable(enable)
  if not hrb.isEnabled() then return end
  enabled = enable
  guihooks.message({txt = messageLookup[enabled and 1 or 0], context = {}}, 2, "hrb.follow")
end

local function toggle()
  enable(not enabled)
end

local function updateGFX(dt)
  updateTimer = updateTimer + dt
  -- update rate: 10 fps (0.1 == 100ms)
  if updateTimer > 0.1 then 
    updateTimer = 0
    update()
  end
end

local function onInit(jbeamData)
 -- ID no longer required, but leave this for reference on how to obtain it
 -- local selfID = obj:getID()
 -- obj:queueGameEngineLua("be:getObjectByID("..selfID.."):queueLuaCommand('pVehID = '..be:getPlayerVehicleID(0))")
end

local function onReset()
end

-- public interface
M.onInit    = onInit
M.onReset   = onReset
M.updateGFX = updateGFX

M.enable    = enable
M.toggle    = toggle

return M
