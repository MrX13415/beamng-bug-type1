-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Front doors: their couplers (door_FL_coupler / door_FR_coupler) and the outside handles, which open a closed
-- door at a key frame of their animation.
-- Moved unchanged from vehicle.lua; vehicle.lua forwards the public functions and calls setupDoors.

local M = {}

local misc = require("vehicles/bug/lua/misc")
local animation = require("vehicles/bug/lua/lib/animation")

local getControllerState = misc.getControllerState
local setControllerState = misc.setControllerState

local function doorControllerName(id)
  return 'door_'..id..'_coupler'
end

-- id "FL" / "FR"; without an id: is any front door open
local function isDoorOpen(id)
  if id == nil then
    return isDoorOpen("FL") or isDoorOpen("FR")
  else
    return getControllerState(doorControllerName(id)) > 0
  end
end

-- open / close a door (both without an id)
local function setDoor(open, id)
  if id == nil then
    setDoor(open, "FL")
    setDoor(open, "FR")
  elseif isDoorOpen(id) ~= open then
    setControllerState(doorControllerName(id), open)
  end
end

local function toggleDoor(id, interior)
  controller.getControllerSafe(doorControllerName(id)).toggleGroup()
end

-- outside handle: a closed door opens at the handle animation's key frame, an open one closes right away
local function toggleDoorHandle(id)
  if not isDoorOpen(id) then
    animation.start("door"..id.."_handle")
  else
    toggleDoor(id)
  end
end

-- called from vehicle.onInit
local function setupDoors()
  animation.setup('doorFL_handle', {
    {  0,   0},
    { 20, 0.8},
    { 40, 1.0},
    { 60, 0.4},
    { 80,   0}
  },{
    { 35, function() toggleDoor('FL') end }
  })
  animation.setup('doorFR_handle', {
    {  0,   0},
    { 20, 0.4},
    { 40, 1.0},
    { 60, 0.2},
    { 80,   0}
  },{
    { 35, function() toggleDoor('FR') end }
  })
end

M.setupDoors         = setupDoors
M.doorControllerName = doorControllerName
M.isDoorOpen         = isDoorOpen
M.setDoor            = setDoor
M.toggleDoor         = toggleDoor
M.toggleDoorHandle   = toggleDoorHandle

return M
