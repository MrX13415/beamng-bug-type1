-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Body: frunk release (interior pull handle), engine lid latch and handle, fuel / gas caps, foglight cover.
-- Moved unchanged from vehicle.lua; the interaction actions still call vehicle.* (vehicle.lua forwards here).
-- vehicle.lua calls setup / update (not game hooks on purpose: this file is also auto-loaded as a vehicle
-- extension, and the order is kept as before).

local M = {}

local misc = require("vehicles/bug/lua/misc")
local animation = require("vehicles/bug/lua/lib/animation")

local getControllerState = misc.getControllerState
local toggle = misc.toggle

local foglightstate = 0

-- interior pull handle (key frame of the hood_release animation): releases the frunk's main latch
local function toolgeHoodRelease()
  controller.getControllerSafe('hoodLatchCoupler').toggleGroup()
end
local function toogleHoodReleaseHandle()
  animation.start("hood_release")
end

local function isTrunkOpen()
  return getControllerState('trunkCoupler') > 0
end
local function toggleTrunk()
  controller.getControllerSafe('trunkCoupler').toggleGroup()
end
-- engine lid handle: open = close the lid (the handle turns back once it is latched), closed = turn the handle,
-- which releases the latch (key frame of the trunk animation)
local function toggleTrunkHandle()
  if isTrunkOpen() then
    toggleTrunk()
    animation.startWait("trunk", -1, function() return not isTrunkOpen() end)
  else
    animation.start("trunk", 1)
  end
end

local function toggleGascap()
  local state = toggle('gascap')
  animation.start("gascap", state == 0 and -1 or 1)
end

local function toggleFuelcap()
  local state = toggle('fuelcap')
  animation.start("fuelcap", state == 0 and -1 or 1)
end

-- called from vehicle.onInit
local function setup()
  electrics.values.foglightcoverstate = 0

  animation.setup('hood_release', {
    {  0,   0},
    { 30, 0.6},
    { 40, 1.0},
    { 50, 1.0},
    { 60, 0.5},
    { 80,   0}
  },{
    { 35, function() toolgeHoodRelease() end },
  })
  animation.setup('trunk', {
    {  0,   0},
    { 20, 0.2},
    { 40, 0.4},
    { 60, 0.6},
    { 80, 1.0}
  },{
    -- Only when opening the trunk
    { 70, function() toggleTrunk() end },
  })

  animation.setup('fuelcap', {
    {  0,   0},
    {  5, 0.7},
    { 20, 1.0}
  },{
    {   5, function() sounds.playSoundOnceAtNode("SFX_bug_gascap_open", misc.getNodeIDbyName("ft1l"), 1, 1, 0, 0) end },
    { -15, function() sounds.playSoundOnceAtNode("SFX_bug_gascap_close", misc.getNodeIDbyName("ft1l"), 1, 1, 0, 0) end },
  },{invert = true})
  animation.setup('gascap', {
    {  0,   0},
    { 10, 0.2},
    { 80, 1.0}
  },{
    {  10, function() sounds.playSoundOnceAtNode("SFX_bug_gascap_open", misc.getNodeIDbyName("h7br"), 1, 1, 0, 0) end },
    { -70, function() sounds.playSoundOnceAtNode("SFX_bug_gascap_close", misc.getNodeIDbyName("h7br"), 1, 1, 0, 0) end },
  },{invert = true})
end

-- called from vehicle.updateGFX
local function update(dt)
  -- When the foglight cover is installed (bug_foglightcover_light ~= nil)
  -- and the foglight was off and is turned on, remove the cover.
  if electrics.values.bug_foglightcover_light ~= nil and foglightstate == 0 and (electrics.values.power__bug_foglight or 0) > 0 then
      electrics.values.foglightcoverstate = 1
  end
  foglightstate = electrics.values.power__bug_foglight or 0
end

M.setup                   = setup
M.update                  = update

M.toolgeHoodRelease       = toolgeHoodRelease
M.toogleHoodReleaseHandle = toogleHoodReleaseHandle
M.isTrunkOpen             = isTrunkOpen
M.toggleTrunk             = toggleTrunk
M.toggleTrunkHandle       = toggleTrunkHandle
M.toggleGascap            = toggleGascap
M.toggleFuelcap           = toggleFuelcap

return M
