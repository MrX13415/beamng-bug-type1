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
--   lib/workmode.lua   work mode at the engine bay (camera, cursor and tools are in the GE extension bug_worktop)
--   lib/interactors.lua the parts the player can point at and use (jbeam section "interactors", GE extension
--                      bug_interact): sent to GE at spawn, then their moves and conditions
--   lib/lids.lua       dragging the frunk and engine lids (gets updateGFX / onReset from the game itself, as a
--                      vehicle extension)
-- New features go into their own lib/ module; only the entry points the actions need are added here.

local M = {}

local misc = require("vehicles/bug/lua/misc")
local doors = require("vehicles/bug/lua/lib/doors")
local lids = require("vehicles/bug/lua/lib/lids")    -- also loaded as a vehicle extension: gets updateGFX / onReset itself
local workmode = require("vehicles/bug/lua/lib/workmode")  -- also loaded as a vehicle extension: gets updateGFX / onReset itself
local interactors = require("vehicles/bug/lua/lib/interactors")
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
  if lids.isLid(id) then
    lids.dragLost(id)
  end
end

-- frunk / engine lid handles ("frunk" / "engine"): press/release from the trigger, cursor ray from GE (lib/lids.lua)
local function lidHandle(id, value)
  lids.press(id, value)
end
local function lidDragRay(id, px, py, pz, dx, dy, dz)
  lids.setRay(id, px, py, pz, dx, dy, dz)
end


local function updateGFX(dt)
  interior.update(dt)   -- hazard switch click
  body.update(dt)       -- foglight cover
  openings.update(dt)   -- 10 Hz: openings, interior light; cabin sound filter
  interactors.update(dt) -- while a camera is near: the interactors' moves and conditions to GE
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
  interactors.setup()   -- the installed parts' interactors to GE (bug_interact)

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

-- doors: lib/doors.lua
M.doorControllerName      = doors.doorControllerName
M.isDoorOpen              = doors.isDoorOpen
M.setDoor                 = doors.setDoor
M.toggleDoor              = doors.toggleDoor
M.toggleDoorHandle        = doors.toggleDoorHandle

M.dragLost                = dragLost
M.lidHandle               = lidHandle
M.lidDragRay              = lidDragRay

-- work mode at the engine bay: lib/workmode.lua (workMode from the trigger, workTurn / workDrag / workExit /
-- workResume from bug_worktop)
M.workMode                = workmode.request
M.workTurn                = workmode.turn
M.workExit                = workmode.exit
M.workDrag                = workmode.drag
M.workResume              = workmode.resume

-- interactors (lib/interactors.lua), from bug_interact: a camera is near the car or not; send them all again
M.interactorsWatched      = interactors.setWatched
M.interactorsRegister     = interactors.register

-- roof: lib/roof.lua
M.isRagtopOpen            = roof.isRagtopOpen
M.ragtopOpen              = roof.ragtopOpen
M.ragtopClose             = roof.ragtopClose
M.ragtopPrimeHandle       = roof.ragtopPrimeHandle
M.ragtopSetHandle         = roof.ragtopSetHandle

return M
