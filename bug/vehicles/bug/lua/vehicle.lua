-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Vehicle kernel: the entry points of the car's features.
-- by MrX13415
--
-- The interaction actions (actions_*.interaction.json), the GE extensions and other modules call vehicle.* .
-- This file only forwards them to the feature modules in lib/ and drives the modules that have no game hooks
-- of their own (setup / update / reset, in a fixed order):
--   lib/interior.lua   interior light, ash tray, heater, switch board, hazard click, glovebox
--   lib/body.lua       frunk release, engine lid latch / handle, fuel and gas caps, foglight cover
--   lib/roof.lua       folding roof handle and lock
--   lib/seats.lua      sliding the front seats, making room when getting out of the back
--   lib/openings.lua   how open the cabin is: interior light, cabin sound filter
--   lib/doors.lua, lib/doordrag.lua, lib/windowcrank.lua: the doors (latch, push buttons, handles, the right door's
--                      lock, dragging them by hand, getting in / out with F) and the window cranks
--     (doors.lua gets updateGFX / onReset from the game itself, as a vehicle extension)
--   lib/hinge.lua      parts swinging on a hinge, moved by hand (springs, dragging, double-click); gets updateGFX /
--                      onReset from the game itself, as a vehicle extension
--   lib/lids.lua       the frunk and engine lids on lib/hinge.lua: latches, the engine lid's handle and locking
-- New features go into their own lib/ module; only the entry points the actions need are added here.

local M = {}

local misc = require("vehicles/bug/lua/misc")
local doors = require("vehicles/bug/lua/lib/doors")  -- also loaded as a vehicle extension: gets updateGFX / onReset itself
local windowcrank = require("vehicles/bug/lua/lib/windowcrank")
local hinge = require("vehicles/bug/lua/lib/hinge")  -- also loaded as a vehicle extension: gets updateGFX / onReset itself
local lids = require("vehicles/bug/lua/lib/lids")
local interior = require("vehicles/bug/lua/lib/interior")
local body = require("vehicles/bug/lua/lib/body")
local roof = require("vehicles/bug/lua/lib/roof")
local seats = require("vehicles/bug/lua/lib/seats")
local openings = require("vehicles/bug/lua/lib/openings")


local function hasPower() return electrics.values.ignitionLevel > 0 end

local function device(name)
  return controller.getController(name)
end

-- the game dropped a held trigger without a release (e.g. UI under the cursor), sent by the GE extension
-- bug_doorDrag: the feature that drags the part `id` ends its drag (kind "crank" for window cranks, else "door")
local function dragLost(id, kind)
  if kind == "crank" then
    windowcrank.press(id, 0)
  elseif hinge.isPart(id) then
    hinge.dragLost(id)
  else
    doors.dragLost(id)
  end
end

-- window crank: press/release from the trigger (reverse = shift / middle mouse), cursor ray from GE
local function windowCrank(id, value, reverse)
  windowcrank.press(id, value, reverse)
end
local function windowCrankRay(id, px, py, pz, dx, dy, dz)
  windowcrank.setRay(id, px, py, pz, dx, dy, dz)
end
-- mouse wheel over a crank (action windowCrankWheel, bound to the mouse wheel in inputmaps/mouse.vehicle.json)
local function windowCrankWheel(value)
  windowcrank.wheel(value)
end
local function windowCrankWheelRay(steps, px, py, pz, dx, dy, dz)
  windowcrank.wheelRay(steps, px, py, pz, dx, dy, dz)
end

-- frunk / engine lid handles ("frunk" / "engine"): press/release from the trigger (lib/lids.lua); the cursor ray from
-- GE goes to every hinged part (lib/hinge.lua)
local function lidHandle(id, value)
  lids.press(id, value)
end
local function lidDragRay(id, px, py, pz, dx, dy, dz)
  hinge.setRay(id, px, py, pz, dx, dy, dz)
end


local function updateGFX(dt)
  interior.update(dt)   -- hazard switch click
  body.update(dt)       -- foglight cover
  openings.update(dt)   -- 10 Hz: openings, interior light; cabin sound filter
end

local function onInit(jbeamData)
  interior.setup()      -- interior electrics, hazard state, sound node, glovebox knob animation
  electrics.values.wipersstate = 0
  electrics.values.usdm_signal_L = 0
  electrics.values.usdm_signal_R = 0

  doors.setupDoors()    -- door handle animations, click handler, get in / out with F
  openings.setup()      -- the roof's break beam
  body.setup()          -- foglight cover, frunk release, fuel / gas cap animations
  roof.setup()          -- roof handle animation
  seats.setup()         -- seat slide handle animations

  --tools.checkNodes()  -- debug: mirrored nodes (was debugCheckNodes here)
end

local function onReset()
  interior.reset()      -- hazard state
  openings.reset()      -- broken glass / roof flags
end

local function onPlayersChanged()
end


M.onInit    = onInit
M.onReset   = onReset
M.updateGFX = updateGFX
M.onPlayersChanged = onPlayersChanged

-- public interface
M.device                  = device

M.hasPower                = hasPower

M.toggle                  = misc.toggle

-- interior: lib/interior.lua
M.toggleInteriorLight     = interior.toggleInteriorLight
M.toggleAshTray           = interior.toggleAshTray
M.toggleSwitchBoard       = interior.toggleSwitchBoard
M.toggleGlovebox          = interior.toggleGlovebox
M.toggleHeatingValve      = interior.toggleHeatingValve
M.toggleHeatingVent       = interior.toggleHeatingVent
M.setHeatingVent          = interior.setHeatingVent

-- body: lib/body.lua
M.toggleGascap            = body.toggleGascap
M.toggleFuelcap           = body.toggleFuelcap
M.toolgeHoodRelease       = body.toolgeHoodRelease
M.toogleHoodReleaseHandle = body.toogleHoodReleaseHandle
M.isTrunkOpen             = body.isTrunkOpen
M.toggleTrunk             = body.toggleTrunk
M.toggleTrunkHandle       = body.toggleTrunkHandle

-- seats: lib/seats.lua
M.moveSeat                = seats.moveSeat
M.exitSeatForward         = seats.exitSeatForward

-- doors: lib/doors.lua
M.doorControllerName      = doors.doorControllerName
M.isDoorOpen              = doors.isDoorOpen
M.setDoor                 = doors.setDoor
M.toggleDoor              = doors.toggleDoor
M.toggleDoorHandle        = doors.toggleDoorHandle
M.pressDoorButton         = doors.pressDoorButton
M.doorDrag                = doors.doorDrag
M.doorDragTarget          = doors.doorDragTarget
M.doorDragRay             = doors.doorDragRay
M.doorInterior            = doors.doorInterior
M.isDoorLocked            = doors.isDoorLocked
M.setDoorLock             = doors.setDoorLock
M.toggleDoorLock          = doors.toggleDoorLock
M.exitDoorOpen            = doors.exitDoorOpen
M.exitDoorClose           = doors.exitDoorClose

M.windowCrank             = windowCrank
M.windowCrankRay          = windowCrankRay
M.windowCrankWheel        = windowCrankWheel
M.windowCrankWheelRay     = windowCrankWheelRay
M.dragLost                = dragLost
M.lidHandle               = lidHandle
M.lidDragRay              = lidDragRay

-- roof: lib/roof.lua
M.isRagtopOpen            = roof.isRagtopOpen
M.ragtopOpen              = roof.ragtopOpen
M.ragtopClose             = roof.ragtopClose
M.ragtopPrimeHandle       = roof.ragtopPrimeHandle
M.ragtopSetHandle         = roof.ragtopSetHandle

return M
