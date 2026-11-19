-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Folding roof (ragtop): the latch handle and its lock. The roof motion itself is the controller
-- controller/bug/ragtop.lua, which calls back through vehicle.ragtopPrimeHandle / vehicle.ragtopSetHandle.
-- Moved unchanged from vehicle.lua; vehicle.lua forwards the public functions and calls setup.

local M = {}

local animation = require("vehicles/bug/lua/lib/animation")

local ragtop = {}
ragtop.VALUE = 0
ragtop.Locked = true

local function isRagtopOpen()
  return electrics.values.ragtop_state > 0
end
local function ragtopPrimeHandle(state)
  if state then
    animation.start("ragtop_handle", 1)
  else
    animation.startWait("ragtop_handle", -1, function()
      return electrics.values.ragtop_state == 0
    end)
  end
end
local function ragtopSetHandle(state)
  if state then
    electrics.values.anim__ragtop_handle = 1
    ragtop.Locked = false
  else
    electrics.values.anim__ragtop_handle = 0
    ragtop.Locked = true
  end
end
local function ragtopOpen(VALUE)
  ragtop.VALUE = VALUE or ragtop.VALUE
  if ragtop.Locked then
    ragtopPrimeHandle(true)
    return
  else
    controller.getControllerSafe('ragtop').open(ragtop.VALUE)
  end
end
local function ragtopClose(VALUE)
  if VALUE == 0 and not ragtop.Locked then
    ragtopPrimeHandle(false)
  end
  controller.getControllerSafe('ragtop').close(VALUE)
end

-- called from vehicle.onInit
local function setup()
  animation.setup('ragtop_handle', {
    {  0,   0},
    { 30, 1.0}
  },{
    -- Only when opening
    {  20, function() ragtop.Locked = false; ragtopOpen() end },
    -- Only when closing
    { -20, function() ragtop.Locked = true end },
  })
end

M.setup             = setup

M.isRagtopOpen      = isRagtopOpen
M.ragtopOpen        = ragtopOpen
M.ragtopClose       = ragtopClose
M.ragtopPrimeHandle = ragtopPrimeHandle
M.ragtopSetHandle   = ragtopSetHandle

return M
