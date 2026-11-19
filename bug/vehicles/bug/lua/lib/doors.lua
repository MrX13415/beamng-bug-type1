-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Front doors: latch (coupler), push button and handle animations, the right door lock, the inside handle
-- and getting in / out with the enter / exit key (F).
-- The public functions are exported by vehicles/bug/lua/vehicle.lua (the actions call vehicle.<name>).
-- Hand dragging and the door physics helpers are in lib/doordrag.lua, the seal and cabin air in lib/cabinair.lua.
-- Like the other files in lua/, the game loads this file as a vehicle extension, so updateGFX and onReset are
-- called by the game (don't call them from vehicle.lua as well: the lock animation would run twice per frame).
-- require() returns the same module table, so vehicle.lua shares its state. setupDoors() is called by vehicle.onInit.
-- Don't name a function M.init: the extension loader treats "init" as the deprecated name of onExtensionLoaded,
-- renames it, sets M.init to nil and runs it at load time (vehicle.onInit then failed: "attempt to call field 'init'").

local M = {}

local misc = require("vehicles/bug/lua/misc")
local animation = require("vehicles/bug/lua/lib/animation")
local doordrag = require("vehicles/bug/lua/lib/doordrag")

local function doorControllerName(id)
  return 'door_'..id..'_coupler'
end
local function isDoorOpen(id)
  if id == nil then
    return isDoorOpen("FL") or isDoorOpen("FR")
  else
    return misc.getControllerState(doorControllerName(id)) > 0
  end
end
local function setDoor(open, id)
  if id == nil then
    setDoor(open, "FL")
    setDoor(open, "FR")
  elseif isDoorOpen(id) ~= open then
    misc.setControllerState(doorControllerName(id), open)
  end
end
local function toggleDoor(id, interior)
  controller.getControllerSafe(doorControllerName(id)).toggleGroup()
end
-- What the push-button animation does when it reaches its key frame:
--   "open": release the latch and swing the door open (click on the handle, keyboard, controller)
--   "pop":  only release the latch, the door pops ajar (click on the push button)
--   "wide": release the latch and swing the door wide open (getting in / out with F, EXIT_DOOR_ANGLE)
local doorButtonMode = {}
local DOOR_OPEN_PUSH_FORCE    = 30   -- N  (the latch spring used to push with 30 N for 0.5 s)
local DOOR_OPEN_PUSH_DURATION = 0.5  -- s
--local EXIT_DOOR_ANGLE         = 75   -- old: too wide
--local EXIT_DOOR_ANGLE         = 45   -- old: not wide enough
local EXIT_DOOR_ANGLE         = 60   -- deg  getting in / out with F: the door swings this far (stop at ~83)
local EXIT_DOOR_MIN_OPEN      = 15   -- deg  an open door at least this wide is wide enough (only an ajar one swings)

local function onDoorButtonKeyframe(id)
  local mode = doorButtonMode[id] or "open"
  doorButtonMode[id] = nil
  if isDoorOpen(id) then return end
  toggleDoor(id) -- releases the latch; the coupler itself only pops the door ajar now
  if mode == "open" then
    doordrag.push(id, DOOR_OPEN_PUSH_FORCE, DOOR_OPEN_PUSH_DURATION)
  elseif mode == "wide" then
    doordrag.swingTo(id, math.rad(EXIT_DOOR_ANGLE))
  end
end

-- Door lock (right door only, like the real car): the inside handle is turned forward ~50 degrees.
-- A locked door can't be opened from outside (push button and handle do nothing); the inside handle
-- (and the keyboard action) unlocks it and opens it.
local DOOR_LOCK_ANGLE  = 50   -- deg  inside handle rotation when locked
local DOOR_HANDLE_PULL = 30   -- deg  inside handle rotation of the open animation (prop anim__doorFR_handle)
local DOOR_LOCK_SPEED  = 5    -- 1/s  handle turning speed (lock position per second)
local doorLockable = {FR = true}
local doorLocked = {}
local doorLockAnim = {}

local function isDoorLocked(id) return doorLocked[id] == true end
local function setDoorLock(id, locked)
  if not doorLockable[id] then return end
  doorLocked[id] = locked and true or nil
end
local function toggleDoorLock(id)
  if isDoorOpen(id) then return end  -- the lock only works on a closed (latched) door
  setDoorLock(id, not isDoorLocked(id))
end

-- inside handle prop: open animation minus the lock rotation (turns the other way)
local function updateDoorLocks(dt)
  for id in pairs(doorLockable) do
    local target = doorLocked[id] and 1 or 0
    local a = doorLockAnim[id] or 0
    a = a + clamp(target - a, -DOOR_LOCK_SPEED * dt, DOOR_LOCK_SPEED * dt)
    doorLockAnim[id] = a
    electrics.values["anim__door" .. id .. "_handle_lock"] =
      (electrics.values["anim__door" .. id .. "_handle"] or 0) - a * DOOR_LOCK_ANGLE / DOOR_HANDLE_PULL
  end
end

local function toggleDoorHandle(id)
  if not isDoorOpen(id) then
    setDoorLock(id, false)  -- pulling the inside handle unlocks the door
    doorButtonMode[id] = "open"
    animation.start("door"..id.."_handle")
  else
    toggleDoor(id)
  end
end

-- outside push button: release the latch only
local function pressDoorButton(id)
  if isDoorLocked(id) and not isDoorOpen(id) then return end  -- locked: the button doesn't move
  doorButtonMode[id] = "pop"
  animation.start("door"..id.."_handle")
end

-- outside handle: press/release from the trigger; a quick click opens/closes automatically,
-- holding and moving drags the door by hand (see lib/doordrag.lua)
local function doorDrag(id, value)
  doordrag.drag(id, value)
end
local function doorDragTarget(id, x, y, z)
  doordrag.setTarget(id, x, y, z)
end
local function doorDragRay(id, px, py, pz, dx, dy, dz)
  doordrag.setRay(id, px, py, pz, dx, dy, dz)
end

-- outside handle double-click: a locked door stays shut
local function onOutsideHandleClick(id)
  if isDoorLocked(id) and not isDoorOpen(id) then return end
  toggleDoorHandle(id)
end

-- getting in / out with the enter / exit key (F): the GE extension bug_exitDoor (lua/ge/extensions/bug/exitDoor.lua)
-- opens the door on the player's side first and lets the player in / out after a moment
local function registerExitDoor()
  misc.geCall("bug_exitDoor", "bug_exitDoor.register(" .. obj:getId() .. ")")  -- version check in misc.geCall
end
local function exitDoorOpen(id)
  if isDoorOpen(id) then
    local a = doordrag.getAngle(id)
    --if a and a < math.rad(EXIT_DOOR_ANGLE - 5) then -- old: also swung a door the player had opened by hand
    if a and a < math.rad(EXIT_DOOR_MIN_OPEN) then
      doordrag.swingTo(id, math.rad(EXIT_DOOR_ANGLE))  -- only ajar (leaned on the seal): swing it open
    else
      obj:queueGameEngineLua("if bug_exitDoor then bug_exitDoor.doorAlreadyOpen(" .. obj:getId() .. ") end")
    end
    return
  end
  if doorButtonMode[id] then return end  -- the handle animation is already running
  --toggleDoorHandle(id)  -- old: opened only as far as a click on the handle
  setDoorLock(id, false)
  doorButtonMode[id] = "wide"  -- the key frame releases the latch and swings the door wide open
  animation.start("door"..id.."_handle")
end
local function exitDoorClose(id)
  if isDoorOpen(id) then toggleDoor(id) end  -- pull it shut with the coupler, like the double-click
end

-- inside handle (trigger press 1 / release 0):
--   latched door: a click opens it like before (handle animation + swing open)
--   open door:    it is not closed by a single click any more; press/release goes to the drag logic,
--                 so a double-click closes it automatically and hold + drag swings it by hand
local doorInteriorPress = {}
local function doorInterior(id, value)
  if value and value > 0 then
    if doorInteriorPress[id] then return end
    if not isDoorOpen(id) and isDoorLocked(id) then
      -- locked: a click only turns the handle back to its normal position; the next click (or the second
      -- click of a double-click) opens the door
      doorInteriorPress[id] = "unlock"
      setDoorLock(id, false)
    elseif not isDoorOpen(id) then
      doorInteriorPress[id] = "open"
      if not doorButtonMode[id] then toggleDoorHandle(id) end  -- ignore clicks while the handle animation runs
    else
      doorInteriorPress[id] = "drag"
      doordrag.drag(id, 1)
    end
  else
    if doorInteriorPress[id] == "drag" then doordrag.drag(id, 0) end
    doorInteriorPress[id] = nil
  end
end

-- the game dropped the held trigger without a release (e.g. UI under the cursor): end the drag
local function dragLost(id)
  doordrag.drag(id, 0)
  doorInteriorPress[id] = nil
end

-- from vehicle.onInit (after the animations library is set up)
local function setupDoors()
  --doordrag.setClickHandler(toggleDoorHandle) -- old: ignored the door lock
  doordrag.setClickHandler(onOutsideHandleClick)
  registerExitDoor()

  animation.setup('doorFL_handle', {
    {  0,   0},
    { 20, 0.8},
    { 40, 1.0},
    { 60, 0.4},
    { 80,   0}
  },{
    { 35, function() onDoorButtonKeyframe('FL') end }
  })
  animation.setup('doorFR_handle', {
    {  0,   0},
    { 20, 0.4},
    { 40, 1.0},
    { 60, 0.2},
    { 80,   0}
  },{
    { 35, function() onDoorButtonKeyframe('FR') end }
  })
end

local function updateGFX(dt)
  updateDoorLocks(dt)
end

local function onReset()
  doorInteriorPress = {}
  doorLocked = {}
end

M.setupDoors = setupDoors
M.updateGFX = updateGFX
M.onReset   = onReset

M.doorControllerName = doorControllerName
M.isDoorOpen         = isDoorOpen
M.setDoor            = setDoor
M.toggleDoor         = toggleDoor
M.toggleDoorHandle   = toggleDoorHandle
M.pressDoorButton    = pressDoorButton
M.doorDrag           = doorDrag
M.doorDragTarget     = doorDragTarget
M.doorDragRay        = doorDragRay
M.doorInterior       = doorInterior
M.isDoorLocked       = isDoorLocked
M.setDoorLock        = setDoorLock
M.toggleDoorLock     = toggleDoorLock
M.exitDoorOpen       = exitDoorOpen
M.exitDoorClose      = exitDoorClose
M.dragLost           = dragLost

return M
