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
--   lib/doors.lua      door couplers and the outside handles
--   lib/horn.lua       the horn ring on the steering wheel
-- New features go into their own lib/ module; only the entry points the actions need are added here.

local M = {}

local misc = require("vehicles/bug/lua/misc")
local doors = require("vehicles/bug/lua/lib/doors")
local horn = require("vehicles/bug/lua/lib/horn")
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
  if id == "horn" then
    horn.dragLost()
  end
end

-- horn ring on the steering wheel: press/release from the trigger, cursor ray from GE (lib/horn.lua)
local function hornRing(value)
  horn.press(value)
end
local function hornRingRay(id, px, py, pz, dx, dy, dz)
  horn.setRay(id, px, py, pz, dx, dy, dz)
end


local function updateGFX(dt)
  interior.update(dt)   -- hazard switch click
  horn.update(dt)
  body.update(dt)       -- foglight cover
  openings.update(dt)   -- 10 Hz: openings, interior light; cabin sound filter
end

local function onInit(jbeamData)
  interior.setup()      -- interior electrics, hazard state, sound node, glovebox knob animation
  electrics.values.wipersstate = 0
  electrics.values.usdm_signal_L = 0
  electrics.values.usdm_signal_R = 0

  doors.setupDoors()    -- door handle animations
  openings.setup()      -- the roof's break beam
  body.setup()          -- foglight cover, frunk release, fuel / gas cap animations
  roof.setup()          -- roof handle animation
  seats.setup()         -- seat slide handle animations

  --tools.checkNodes()  -- debug: mirrored nodes (was debugCheckNodes here)
end

local function onReset()
  interior.reset()      -- hazard state
  openings.reset()      -- broken glass / roof flags
  horn.onReset()
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

-- doors: lib/doors.lua
M.doorControllerName      = doors.doorControllerName
M.isDoorOpen              = doors.isDoorOpen
M.setDoor                 = doors.setDoor
M.toggleDoor              = doors.toggleDoor
M.toggleDoorHandle        = doors.toggleDoorHandle

M.dragLost                = dragLost
M.hornRing                = hornRing
M.hornRingRay             = hornRingRay

-- roof: lib/roof.lua
M.isRagtopOpen            = roof.isRagtopOpen
M.ragtopOpen              = roof.ragtopOpen
M.ragtopClose             = roof.ragtopClose
M.ragtopPrimeHandle       = roof.ragtopPrimeHandle
M.ragtopSetHandle         = roof.ragtopSetHandle

return M
