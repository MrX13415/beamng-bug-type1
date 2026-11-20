-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- How the front doors swing: the doors as parts of lib/hinge.lua, plus what only the doors have.
--
-- lib/hinge.lua does the hand: hold + drag on the outside handle (or the inside handle of an open door) pulls the
-- door with the cursor, a short press without moving counts as a click, a double-click calls the click handler
-- (lib/doors.lua: opens / closes the door, a locked door stays shut). The doors use its plane drag (dragPlane): the
-- GE extension bug_doorDrag sends the cursor's point on a horizontal plane at handle height, and the handle (nodes
-- d9 / d6) is pulled towards it with a capped spring-damper, so the hinge, check-strap brake and stop of the jbeam
-- still act. The doors have no Lua hinge springs: their hinge, check strap and stop are beams.
-- This file registers both doors there (in setup, the handle weights come from the jbeam) and adds through the
-- hooks: the latch (coupler) holds the door, the push of the old latch spring, swinging to an angle (getting in /
-- out with F) and the airflow while driving. lib/cabinair.lua uses the helpers for the seal and the cabin air
-- (opening at the rear edge, hinge friction, forces inside a physics step).
-- The door_FL / door_FR input actions still toggle with a single press (lib/doors.lua).

local M = {}

local misc = require("vehicles/bug/lua/misc")
local hinge = require("vehicles/bug/lua/lib/hinge")

-- Tuning
local DRAG_SPRING     = 400   -- N/m    pull towards the cursor point
local DRAG_DAMP       = 40    -- N s/m  damping of the handle motion
local DRAG_MAX_FORCE  = 150   -- N      cap, below what it takes to force the door past the stop
local HANDLE_Z        = 0.86  -- m      handle height (mesh), used to weight d9 (z 0.95) / d6 (z 0.60)
local SEAL_ZONE       = 0.023 -- m     door opening (rear edge) below which the seal is (nearly) in contact
local HINGE_FRICTION  = 6     -- N      dry (Coulomb) hinge friction at the handle: a slow door stops and stays put
local DOOR_MASS_EFF   = 6     -- kg     effective door mass at the handle (stiction: never push more than it takes to stop)
local ARC_MAX         = 80    -- deg    the hand's target range (past the stop at ~83 deg the drag kept ramming it)
local DRAG_SEAL_MAX_CLOSE = 13 -- N    max closing drag force there: below the seal force at the latch point (~24 N),
                                --        so the door can't be pressed shut slowly by hand, only swung shut
-- The earlier experimental ray drag models of the doors ("arc", "spot", "hand"; DRAG_ARC) are in the git history
-- of lib/doordrag.lua; the plane drag is the one that is used.

-- swing to an angle (getting in / out with F: the door opens wide, see swingTo)
--local SWING_SPRING    = 120   -- old: near the target the pull fell below the hinge friction (6 N), door stopped short
local SWING_SPRING    = 250   -- N/m    pull towards the target angle (error measured at the handle)
--local SWING_DAMP      = 30    -- old: too little for the stronger spring (overshoot)
local SWING_DAMP      = 50    -- N s/m  damping of the handle speed (top speed about SWING_MAX_FORCE / SWING_DAMP)
local SWING_MAX_FORCE = 70    -- N      cap
local SWING_DONE      = math.rad(3) -- close enough ...
local SWING_DONE_VEL  = 0.15  -- m/s    ... and slow enough: stop pulling
local SWING_TIMEOUT   = 3     -- s      give up (door blocked)
-- Airflow on an open door while driving: the door is hinged at its front edge, so the air pushes it shut (reversing:
-- open). Flat plate in the flow: q * A * Cn, q = rho / 2 * v^2, Cn growing with the opening angle; at the handle
-- with the center of pressure halfway along the door. At 50 km/h a door open 30 deg takes ~40 N at the handle, at
-- 100 km/h ~150 N (the hand's cap DRAG_MAX_FORCE: it only cracks open). The game's own drag on the door's triangles
-- (dragCoef 20 in the jbeam, like the stock cars) is much weaker; this comes on top.
local AIR_DENSITY     = 1.2   -- kg/m^3
local DOOR_AREA       = 0.85  -- m^2    door with window
local DOOR_CN_MAX     = 1.1   --        normal force coefficient of a flat plate across the flow (90 deg)
local DOOR_CP         = 0.5   --        center of pressure / handle radius
local WIND_MIN_SPEED  = 1     -- m/s    slower: no wind force

local DOOR_IDS = {"FL", "FR"}
local onClick = nil

local function sideSuffix(id) return id == "FL" and "l" or "r" end
local function couplerName(id) return "door_" .. id .. "_coupler" end

local function isLatched(id)
  local c = controller.getController(couplerName(id))
  if not c then return false end
  local s = c.getGroupState()
  return s == "attached" or s == "desyncedAttached"
end

local function nodeWorldPos(cid)
  return obj:getPosition() + obj:getNodePosition(cid)
end

-- the door's hinge part (nil if the door isn't on the car)
local function getDoor(id)
  return hinge.get(id)
end

local function handlePos(d)
  local p = vec3(0, 0, 0)
  for _, h in ipairs(d.handle) do p = p + nodeWorldPos(h.cid) * h.w end
  return p
end

local function handleVel(d)
  local vel = vec3(0, 0, 0)
  for _, h in ipairs(d.handle) do vel = vel + obj:getNodeVelocityVector(h.cid) * h.w end
  return vel - obj:getVelocity()
end

local function applyHandleForce(d, f, dt)
  for _, h in ipairs(d.handle) do obj:applyForceVectorTime(h.cid, f * h.w, dt) end
end

-- Horizontal direction in which the door opens at the handle (tangent of the swing, pointing outwards)
local function openDirection(d)
  local p = handlePos(d)
  local r = p - nodeWorldPos(d.h1)
  r.z = 0
  local t = vec3(-r.y, r.x, 0)
  if d.other then
    local outward = p - nodeWorldPos(d.other)
    outward.z = 0
    if t:dot(outward) < 0 then t = -t end
  end
  return t:normalized()
end

-- Door opening at the rear edge (m, 0 = closed) and its rate (m/s, + = opening)
local function getOpening(id)
  local d = getDoor(id)
  if not d or not d.L0 then return nil, nil end
  local rel = nodeWorldPos(d.top) - nodeWorldPos(d.ref)
  local len = rel:length()
  local relV = obj:getNodeVelocityVector(d.top) - obj:getNodeVelocityVector(d.ref)
  return (len - d.L0) / d.G, (len > 1e-6 and relV:dot(rel) / len or 0) / d.G
end

-- Force along the door's swing at the handle (N, + = opening)
local function applyOpenForce(id, f, dt)
  local d = getDoor(id)
  if not d then return end
  applyHandleForce(d, openDirection(d) * f, dt)
end

-- Same, for use inside a physics step (force acts for this step only)
local function applyOpenForceStep(id, f)
  local d = getDoor(id)
  if not d then return end
  local fv = openDirection(d) * f
  for _, h in ipairs(d.handle) do obj:applyForceVector(h.cid, fv * h.w) end
end

-- Dry hinge friction for one physics step: opposes the swing with a constant force, but never more than
-- it takes to stop the door within this step, so a (nearly) resting door stays where it is (stiction).
local function hingeFrictionStep(id, dt)
  local d = getDoor(id)
  if not d or dt <= 0 then return end
  local dir = openDirection(d)
  local vel = handleVel(d):dot(dir)
  local f = math.min(HINGE_FRICTION, DOOR_MASS_EFF * math.abs(vel) / dt)
  if f <= 0 then return end
  local fv = dir * (vel > 0 and -f or f)
  for _, h in ipairs(d.handle) do obj:applyForceVector(h.cid, fv * h.w) end
end

-- opening angle of the door (rad, 0 = closed, + = open) and the handle's distance from the hinge axis
local function getAngle(id)
  local d = getDoor(id)
  if not d then return nil end
  local theta, R = hinge.geom(d)
  return theta, R
end

-- swing an unlatched door to the given opening angle (rad) with a capped spring-damper at the handle;
-- hinge friction, check strap and stop still act. Ends at the angle, on a drag or after SWING_TIMEOUT.
local function swingTo(id, angle)
  local d = getDoor(id)
  if not d then return end
  d.swingTarget, d.swingTime = angle, SWING_TIMEOUT
end

-- push the door open like the old latch spring did (automatic opening: click / keyboard / controller)
local function push(id, force, duration)
  local d = getDoor(id)
  if not d then return end
  d.pushForce, d.pushTime = force, duration
end

-- airflow on an open, unlatched door while driving (see AIR_DENSITY ff.)
local function applyWind(d, dt)
  local vf = obj:getVelocity():dot(obj:getDirectionVector())   -- forward speed, m/s
  if math.abs(vf) < WIND_MIN_SPEED then return end
  local a = hinge.geom(d)
  if not a or a <= 0 then return end
  -- Cn of a flat plate: rises quickly at small angles, ~DOOR_CN_MAX across the flow
  local cn = DOOR_CN_MAX * math.sqrt(math.sin(math.min(a, math.pi / 2)))
  local f = 0.5 * AIR_DENSITY * vf * vf * DOOR_AREA * cn * DOOR_CP
  applyHandleForce(d, openDirection(d) * (vf > 0 and -f or f), dt)
end

-- hooks (lib/hinge.lua) --------------------------------------------------------------------------------------

local function onInit(d)
  local sfx = sideSuffix(d.id)
  d.top = misc.getNodeIDbyName("d9" .. sfx)
  d.other = misc.getNodeIDbyName("d9" .. (sfx == "l" and "r" or "l"))
  -- door opening at the rear edge is measured with the latch node (ref) -> d9 distance:
  -- near closed, d9 moves (almost) along x, so the distance grows by |dx|/L0 per m of opening
  if d.top then
    local pl, pt = v.data.nodes[d.ref].pos, v.data.nodes[d.top].pos
    d.L0 = math.sqrt((pt.x - pl.x)^2 + (pt.y - pl.y)^2 + (pt.z - pl.z)^2)
    d.G = math.max(math.abs(pt.x - pl.x) / d.L0, 0.1)
  end
  d.pushTime, d.pushForce = 0, 0
  d.swingTarget, d.swingTime = nil, 0
end

local function onHeld(d) return isLatched(d.id) end

-- double-click on the handle: the click handler opens / closes the door
local function onDoubleClick(d)
  if onClick then onClick(d.id) end
  return true
end

-- every frame before the hand: airflow, the push, swinging to an angle (all only on an unlatched door)
local function onUpdate(d, dt, latched)
  if latched then
    d.pushTime = math.max(0, d.pushTime - dt)
    if d.swingTarget then
      d.swingTime = d.swingTime - dt
      if d.active or d.swingTime <= 0 then d.swingTarget = nil end
    end
    return
  end

  applyWind(d, dt)

  if d.pushTime > 0 then
    d.pushTime = d.pushTime - dt
    applyHandleForce(d, openDirection(d) * d.pushForce, dt)
  end

  if d.swingTarget then
    d.swingTime = d.swingTime - dt
    local a, R = hinge.geom(d)
    if d.active or d.swingTime <= 0 or not a then
      d.swingTarget = nil  -- the hand took over, or the door is stuck
    else
      local dir = openDirection(d)
      local vel = handleVel(d):dot(dir)
      local err = d.swingTarget - a
      if math.abs(err) < SWING_DONE and math.abs(vel) < SWING_DONE_VEL then
        d.swingTarget = nil
      else
        local f = clamp(err * R * SWING_SPRING - vel * SWING_DAMP, -SWING_MAX_FORCE, SWING_MAX_FORCE)
        applyHandleForce(d, dir * f, dt)
      end
    end
  end
end

local HOOKS = {init = onInit, held = onHeld, update = onUpdate, doubleClick = onDoubleClick}

local function sealOpening(d)
  return (getOpening(d.id))
end

-- register both doors (vehicle.onInit through doors.setupDoors: the handle weights come from the jbeam)
local function setup()
  for _, id in ipairs(DOOR_IDS) do
    local sfx = sideSuffix(id)
    local top = misc.getNodeIDbyName("d9" .. sfx)
    local mid = misc.getNodeIDbyName("d6" .. sfx)
    if top and mid then
      -- weight the two rear-edge nodes so their mix sits at handle height
      local zTop, zMid = v.data.nodes[top].pos.z, v.data.nodes[mid].pos.z
      local wTop = clamp((HANDLE_Z - zMid) / (zTop - zMid), 0, 1)
      hinge.register(id, {
        hinge = {"dh1" .. sfx, "dh2" .. sfx}, ref = "q14" .. sfx,   -- ref: body side latch node (B-pillar)
        handle = {{"d9" .. sfx, wTop}, {"d6" .. sfx, 1 - wTop}},
        opensOutward = true,
        dragPlane = true,
        dragSpring = DRAG_SPRING, dragDamp = DRAG_DAMP, dragMaxForce = DRAG_MAX_FORCE,
        slowCloseCap = {gap = SEAL_ZONE, maxClose = DRAG_SEAL_MAX_CLOSE, opening = sealOpening},
        maxDeg = ARC_MAX,
        autoOpenDeg = ARC_MAX,   -- unused: the doors don't use the automatic open / close (swingTo instead)
        hooks = HOOKS,
      })
    end
  end
end

local function isDoor(id) return id == "FL" or id == "FR" end

-- trigger press (value 1) / release (value 0) on a handle
local function drag(id, value)
  hinge.press(id, value)
end

local function setClickHandler(fn) onClick = fn end

M.setup           = setup
M.isDoor          = isDoor
M.drag            = drag
M.setTarget       = hinge.setTarget
M.push            = push
M.swingTo         = swingTo
M.getAngle        = getAngle
M.isLatched       = isLatched
M.getOpening      = getOpening
M.applyOpenForce  = applyOpenForce
M.applyOpenForceStep = applyOpenForceStep
M.hingeFrictionStep = hingeFrictionStep
M.setClickHandler = setClickHandler

return M
