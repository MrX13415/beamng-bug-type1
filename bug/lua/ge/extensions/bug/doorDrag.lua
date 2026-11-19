-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Game-engine side of dragging parts of the Bug with the mouse (extension name: bug_doorDrag; it started with
-- the door handles). Loaded on demand by the vehicle (misc.geCall) while a dragged part is held.
-- start(): every frame it intersects the mouse cursor ray with a horizontal plane at handle height and sends that
-- point to the vehicle (vehicle.doorDragTarget), which pulls the handle towards it.
-- startRay(): sends the cursor ray itself to a vehicle function (lids, horn ring, window cranks: the vehicle
-- intersects it with the plane the part moves in).
-- If the game drops the held trigger without a release, the vehicle gets vehicle.dragLost(id, kind).

local M = {}

-- bumped on every change: the vehicle reloads this extension when an older version is still loaded
M.version = 8

local drags = {} -- key "vehId/doorId" -> {vehId, doorId, z} or {vehId, doorId, rayCmd}

local function key(vehId, doorId) return tostring(vehId) .. "/" .. tostring(doorId) end

local function start(vehId, doorId, z)
  drags[key(vehId, doorId)] = {vehId = vehId, doorId = doorId, z = z}
end

-- send the raw cursor ray to vehicle function rayCmd(id, px, py, pz, dx, dy, dz) every frame
-- (door drags and window cranks of the same door can't share a key: the key includes rayCmd)
local CRANK_CMD = "vehicle.windowCrankRay"
local function startRay(vehId, id, rayCmd)
  drags[key(vehId, (rayCmd or CRANK_CMD) .. ":" .. id)] = {vehId = vehId, doorId = id, rayCmd = rayCmd or CRANK_CMD}
end

local function stopRay(vehId, id, rayCmd)
  drags[key(vehId, (rayCmd or CRANK_CMD) .. ":" .. id)] = nil
end

local function stop(vehId, doorId)
  drags[key(vehId, doorId)] = nil
end

-- While dragging, the trigger tooltip is hidden: when the cursor moved over it, the UI took the mouse and
-- core_vehicleTriggers dropped the held trigger, which ended the drag. The tooltip is drawn while
-- state.hoveredHitPosScreen01 is set; that is only refreshed while hovering, not while a trigger is held.
-- If the held trigger is dropped anyway (other UI under the cursor), the vehicle gets dragLost() so the
-- drag doesn't stay stuck without a release.
local LOST_FRAMES = 3
local lostFrames = 0

local function hideTooltip()
  local vt = core_vehicleTriggers
  if vt and vt.state then vt.state.hoveredHitPosScreen01 = nil end
end

local function checkHeldTrigger()
  local vt = core_vehicleTriggers
  if not (vt and vt.state and vt.state.currentlyUsedTriggers) then return end
  if vt.state.currentlyUsedTriggers[0] then lostFrames = 0 return end
  lostFrames = lostFrames + 1
  if lostFrames < LOST_FRAMES then return end
  lostFrames = 0
  for k, d in pairs(drags) do
    local veh = be:getObjectByID(d.vehId)
    if veh then veh:queueLuaCommand(string.format("vehicle.dragLost(%q, %q)", d.doorId, d.rayCmd == CRANK_CMD and "crank" or "door")) end
    drags[k] = nil
  end
end

-- Tooltip while scrolling a crank: the cursor still hovers the trigger, so core_vehicleTriggers keeps
-- refreshing it. It only re-sends the tooltip stream when it changes, so an empty tooltip sent after it each
-- frame stays. When scrolling stops, hoveredHitPosScreen01 is cleared once: that makes core_vehicleTriggers
-- send its tooltip again on its next refresh.
local TOOLTIP_STREAM = "vehicleTriggerCrosshairTarget"
local emptyTooltip = {}
local wheelHideTime = 0

local function wheelHide(duration)
  wheelHideTime = math.max(wheelHideTime, duration or 0.6)
end

local function updateWheelHide(dt)
  if wheelHideTime <= 0 then return end
  wheelHideTime = wheelHideTime - (dt or 0)
  if wheelHideTime <= 0 then
    wheelHideTime = 0
    hideTooltip()   -- forces the tooltip to be sent again (it is shown again on the next refresh)
  end
end

local function onUpdate(dtReal)
  updateWheelHide(dtReal)
  if next(drags) == nil then lostFrames = 0 return end
  hideTooltip()
  checkHeldTrigger()
  if next(drags) == nil then return end

  local ray = getCameraMouseRay()
  if not ray then return end
  local pos, dir = ray.pos, ray.dir

  for k, d in pairs(drags) do
    local veh = be:getObjectByID(d.vehId)
    if not veh then
      drags[k] = nil
    elseif d.rayCmd then
      veh:queueLuaCommand(string.format("%s(%q, %f, %f, %f, %f, %f, %f)", d.rayCmd, d.doorId, pos.x, pos.y, pos.z, dir.x, dir.y, dir.z))
    elseif math.abs(dir.z) > 1e-4 then
      local t = (d.z - pos.z) / dir.z
      -- only in front of the camera and not absurdly far away (ray nearly parallel to the plane)
      if t > 0 and t < 50 then
        local p = pos + dir * t
        veh:queueLuaCommand(string.format("vehicle.doorDragTarget(%q, %f, %f, %f)", d.doorId, p.x, p.y, p.z))
      end
    end
  end
end

-- While a drag is active, other triggers must not light up when the cursor passes over them.
-- core_vehicleTriggers sets these engine flags every onUpdate; onPreRender runs after that, before the frame
-- is drawn. HIDE_ALL_WHILE_DRAGGING also hides the held trigger's own highlight (use it if proximity
-- rendering alone doesn't stop the others from lighting up).
local HIDE_ALL_WHILE_DRAGGING = false

-- one-off: send the current cursor ray to vehicle function cmd(steps, px, py, pz, dx, dy, dz) (mouse wheel on a crank)
local function wheelRay(vehId, steps, cmd)
  log("D", "bug_doorDrag", "mouse wheel (binding) " .. tostring(steps))
  local veh = be:getObjectByID(vehId)
  local ray = getCameraMouseRay()
  if not veh or not ray then return end
  local pos, dir = ray.pos, ray.dir
  veh:queueLuaCommand(string.format("%s(%d, %f, %f, %f, %f, %f, %f)", cmd, steps, pos.x, pos.y, pos.z, dir.x, dir.y, dir.z))
end

local function onPreRender()
  if wheelHideTime > 0 then guihooks.triggerStream(TOOLTIP_STREAM, emptyTooltip) end
  if next(drags) == nil then return end
  hideTooltip()
  if not VehicleTrigger then return end
  VehicleTrigger.proximityRenderingEnabled = false
  if HIDE_ALL_WHILE_DRAGGING then VehicleTrigger.renderingEnabled = false end
end

local function onVehicleDestroyed(vehId)
  for k, d in pairs(drags) do
    if d.vehId == vehId then drags[k] = nil end
  end
end

M.start              = start
M.startRay           = startRay
M.wheelRay           = wheelRay
M.wheelHide          = wheelHide
M.stop               = stop
M.stopRay            = stopRay
M.onUpdate           = onUpdate
M.onPreRender        = onPreRender
M.onVehicleDestroyed = onVehicleDestroyed

return M
