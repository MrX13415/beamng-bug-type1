-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Door handle interaction: hold + drag the outside handle to swing the door by hand.
--
-- The trigger only reports press (1) / release (0). While a handle is held, the GE extension
-- "bug_doorDrag" (lua/ge/extensions/bug/doorDrag.lua) sends the point under the mouse cursor
-- (on a horizontal plane at handle height) every frame via setTarget(). Here the handle
-- (nodes d9/d6) is pulled towards that point with a capped spring-damper force, so the
-- hinge, check-strap brake and stop all still act on the door.
--
-- A short press without moving counts as a click; a double click (onClick callback) opens/closes
-- the door automatically. (The door_FL/door_FR input actions still toggle with a single press.)
-- The inside handle of an open door uses the same press/release logic (vehicle.doorInterior); the door
-- is always pulled at the rear edge, so the hand moves the door the same way from inside and outside.

local M = {}

local misc = require("vehicles/bug/lua/misc")

-- Tuning
local DRAG_SPRING     = 400   -- N/m    pull towards the cursor point
local DRAG_DAMP       = 40    -- N s/m  damping of the handle motion
local DRAG_DAMP_RELATIVE = false -- true: damp only relative to the cursor target's motion (more momentum,
                                 -- but the door flew open too fast in game)
local TARGET_VEL_TAU  = 0.05  -- s      smoothing of the cursor target's velocity
local TARGET_VEL_MAX  = 6     -- m/s
local PLANE_MAX_GAIN  = 4     -- cursor spot far from the hinge: its sideways motion moves the grab point as far
                              -- (gain = spot distance / grab radius, up to this)
local DRAG_MAX_FORCE  = 150   -- N      cap, below what it takes to force the door past the stop
local CLICK_MAX_TIME  = 0.25  -- s      shorter press ...
local CLICK_MAX_MOVE  = 0.03  -- m      ... with less cursor travel = click
local HANDLE_Z        = 0.86  -- m      handle height (mesh), used to weight d9 (z 0.95) / d6 (z 0.60)
local DOUBLE_CLICK_TIME = 0.4 -- s      max time between two clicks for a double click
local SEAL_ZONE       = 0.023 -- m     door opening (rear edge) below which the seal is (nearly) in contact
local HINGE_FRICTION  = 6     -- N      dry (Coulomb) hinge friction at the handle: a slow door stops and stays put
local DOOR_MASS_EFF   = 6     -- kg     effective door mass at the handle (stiction: never push more than it takes to stop)
--local DRAG_ARC        = true -- old: arc / spot / hand models below, none felt right in game yet
local DRAG_ARC        = false  -- the handle follows the cursor along its swing arc (screen-space closest point);
                              -- false = old: cursor ray hit on a horizontal plane at handle height. From the
                              -- other seat that plane is seen at a grazing angle and the door is very hard to steer
local ARC_MIN         = math.rad(-2)  -- swing range searched for the cursor (0 = closed)
--local ARC_MAX         = math.rad(95) -- old: past the stop (~83 deg), the drag kept ramming the door into it
local ARC_MAX         = math.rad(80)
local ARC_STEP        = math.rad(1)
local DRAG_MODEL      = "hand" -- "hand": mouse = hand at the grab point (below); "spot": door points at the cursor
                               -- spot at grab height (old, opened too fast and closed badly); "arc": screen arc only
local HAND_DEPTH_GAIN = 1.5   -- dragging down also pulls the hand towards the camera (up pushes it away), m per m
local PLANE_MIN_RADIUS = 0.15 -- m    cursor spot this close to the hinge: angle undefined, use the arc instead
local ARC_MIN_SENS    = 0.35  -- rad of view angle per rad of door swing, at least: seen from the other seat the
                              -- arc is very compressed on screen, so the cursor motion along it is amplified
local DRAG_SEAL_MAX_CLOSE = 13 -- N    max closing drag force there: below the seal force at the latch point (~24 N),
                                --        so the door can't be pressed shut slowly by hand, only swung shut

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

local doors = {}   -- per door id ("FL"/"FR")
local onClick = nil
local clock = 0     -- s, running time for double click detection

local function sideSuffix(id) return id == "FL" and "l" or "r" end
local function couplerName(id) return "door_" .. id .. "_coupler" end

local function isLatched(id)
  local c = controller.getController(couplerName(id))
  if not c then return false end
  local s = c.getGroupState()
  return s == "attached" or s == "desyncedAttached"
end

local function getDoor(id)
  local d = doors[id]
  if d then return d end
  local sfx = sideSuffix(id)
  local top = misc.getNodeIDbyName("d9" .. sfx)
  local mid = misc.getNodeIDbyName("d6" .. sfx)
  local other = misc.getNodeIDbyName("d9" .. (sfx == "l" and "r" or "l"))
  local hinge = misc.getNodeIDbyName("dh1" .. sfx)
  local hinge2 = misc.getNodeIDbyName("dh2" .. sfx)
  local latch = misc.getNodeIDbyName("q14" .. sfx)  -- body side latch node (B-pillar)
  if not top or not mid then return nil end
  -- weight the two rear-edge nodes so their mix sits at handle height
  local zTop, zMid = v.data.nodes[top].pos.z, v.data.nodes[mid].pos.z
  local wTop = clamp((HANDLE_Z - zMid) / (zTop - zMid), 0, 1)
  -- door opening at the rear edge is measured with the latch-node -> d9 distance:
  -- near closed, d9 moves (almost) along x, so the distance grows by |dx|/L0 per m of opening
  local L0, G = nil, nil
  if latch then
    local pl, pt = v.data.nodes[latch].pos, v.data.nodes[top].pos
    L0 = math.sqrt((pt.x - pl.x)^2 + (pt.y - pl.y)^2 + (pt.z - pl.z)^2)
    G = math.max(math.abs(pt.x - pl.x) / L0, 0.1)
  end
  -- swing arc: closed handle direction relative to the latch node (angle around the hinge axis), and the
  -- sign of the opening rotation (handle moves outwards)
  local arcDelta, arcSign = nil, nil
  if latch and hinge2 then
    local function P(cid) local q = v.data.nodes[cid].pos; return vec3(q.x, q.y, q.z) end
    local h1 = P(hinge)
    local axis = (P(hinge2) - h1):normalized()
    local hp = P(top) * wTop + P(mid) * (1 - wTop)
    local r = hp - h1; r = r - axis * r:dot(axis)
    local q = P(latch) - h1; q = q - axis * q:dot(axis)
    arcDelta = math.atan2(axis:dot(q:cross(r)), q:dot(r))
    local t = axis:cross(r)
    arcSign = (t.x * hp.x > 0) and 1 or -1
  end
  d = {top = top, mid = mid, other = other, hinge = hinge, hinge2 = hinge2, latch = latch, L0 = L0, G = G, wTop = wTop, wMid = 1 - wTop,
       arcDelta = arcDelta, arcSign = arcSign,
       active = false, dragging = false, pressTime = 0, target = nil, offset = nil, start = nil,
       pushTime = 0, pushForce = 0, lastClick = -1}
  doors[id] = d
  return d
end

local function nodeWorldPos(cid)
  return obj:getPosition() + obj:getNodePosition(cid)
end

local function handlePos(d)
  return nodeWorldPos(d.top) * d.wTop + nodeWorldPos(d.mid) * d.wMid
end

local function handleVel(d)
  return (obj:getNodeVelocityVector(d.top) * d.wTop + obj:getNodeVelocityVector(d.mid) * d.wMid) - obj:getVelocity()
end

local function applyHandleForce(d, f, dt)
  obj:applyForceVectorTime(d.top, f * d.wTop, dt)
  obj:applyForceVectorTime(d.mid, f * d.wMid, dt)
end

-- Horizontal direction in which the door opens at the handle (tangent of the swing, pointing outwards)
local function openDirection(d)
  local p = handlePos(d)
  local r = p - nodeWorldPos(d.hinge)
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
  if not d or not d.latch then return nil, nil end
  local rel = nodeWorldPos(d.top) - nodeWorldPos(d.latch)
  local len = rel:length()
  local relV = obj:getNodeVelocityVector(d.top) - obj:getNodeVelocityVector(d.latch)
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
  obj:applyForceVector(d.top, fv * d.wTop)
  obj:applyForceVector(d.mid, fv * d.wMid)
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
  obj:applyForceVector(d.top, fv * d.wTop)
  obj:applyForceVector(d.mid, fv * d.wMid)
end

-- opening angle of the door (rad, 0 = closed, + = open), measured at the handle around the hinge axis
local function getAngle(id)
  local d = getDoor(id)
  if not d or not d.arcDelta then return nil end
  local h1 = nodeWorldPos(d.hinge)
  local axis = (nodeWorldPos(d.hinge2) - h1):normalized()
  local r = handlePos(d) - h1
  r = r - axis * r:dot(axis)
  local q = nodeWorldPos(d.latch) - h1
  q = (q - axis * q:dot(axis)):normalized()
  local e1 = q * math.cos(d.arcDelta) + axis:cross(q) * math.sin(d.arcDelta)
  local e2 = axis:cross(e1)
  return d.arcSign * math.atan2(r:dot(e2), r:dot(e1)), r:length()
end

-- swing an unlatched door to the given opening angle (rad) with a capped spring-damper at the handle;
-- hinge friction, check strap and stop still act. Ends at the angle, on a drag or after SWING_TIMEOUT.
local function swingTo(id, angle)
  local d = getDoor(id)
  if not d or not d.arcDelta then return end
  d.swingTarget, d.swingTime = angle, SWING_TIMEOUT
end

-- bug_doorDrag call; loading and the version check are in misc.geCall (version table there)
local function geCall(cmd)
  misc.geCall("bug_doorDrag", cmd)
end

-- trigger press (value 1) / release (value 0) on the outside handle
local function drag(id, value)
  local d = getDoor(id)
  if not d then return end

  if value and value > 0 then
    if d.active then return end
    local p = handlePos(d)
    d.active, d.dragging, d.pressTime = true, false, 0
    d.target, d.offset, d.start = nil, nil, p
    d.uOffset, d.uCursorStart, d.grabR, d.grabH = nil, nil, nil, nil
    d.lastTarget, d.targetVel = nil, nil
    d.prevRayO, d.prevRayD = nil, nil
    if DRAG_ARC and d.arcDelta then
      geCall(string.format("bug_doorDrag.startRay(%d, %q, 'vehicle.doorDragRay')", obj:getId(), id))
    else
      geCall(string.format("bug_doorDrag.start(%d, %q, %f)", obj:getId(), id, p.z))
    end
  else
    if not d.active then return end
    local wasClick = not d.dragging and d.pressTime <= CLICK_MAX_TIME
    d.active, d.dragging, d.target = false, false, nil
    geCall(string.format("bug_doorDrag.stop(%d, %q)", obj:getId(), id))
    geCall(string.format("bug_doorDrag.stopRay(%d, %q, 'vehicle.doorDragRay')", obj:getId(), id))
    if wasClick then
      if clock - d.lastClick <= DOUBLE_CLICK_TIME then
        d.lastClick = -1
        if onClick then onClick(id) end
      else
        d.lastClick = clock
      end
    end
  end
end

-- called every frame by the GE extension with the cursor point (world space, at handle height)
local function setTarget(id, x, y, z)
  local d = doors[id]
  if not d or not d.active then return end
  local cursor = vec3(x, y, z)
  if not d.offset then
    -- keep the grab point where it is: the door must not jump to the cursor on the first frame
    d.offset = d.start - cursor
    d.cursorStart = cursor
  end
  d.target = cursor + d.offset
  if not d.dragging and (cursor - d.cursorStart):length() > CLICK_MAX_MOVE then
    d.dragging = true
  end
end

-- the car's frame (origin, right, forward, up): the previous cursor ray is kept in it, so the car moving between two
-- frames doesn't count as hand motion (at speed it moved the hand by decimetres per frame, always towards the front)
local function carFrame()
  local f = obj:getDirectionVector():normalized()
  local r = f:cross(obj:getDirectionVectorUp()):normalized()
  return obj:getPosition(), r, f, r:cross(f)
end
local function toCar(w, o, r, f, u) if o then w = w - o end return vec3(w:dot(r), w:dot(f), w:dot(u)) end
local function fromCar(l, o, r, f, u) local w = r * l.x + f * l.y + u * l.z; return o and (w + o) or w end

-- called every frame by the GE extension with the cursor ray (DRAG_ARC):
-- the target is the point of the handle's swing arc (circle around the hinge axis at handle height) that is
-- closest to the cursor on screen, so the door can be steered from any viewing angle, also from the other seat
local function setRay(id, px, py, pz, dx, dy, dz)
  local d = doors[id]
  if not d or not d.active or not d.arcDelta then return end
  local O, dir = vec3(px, py, pz), vec3(dx, dy, dz):normalized()

  local h1 = nodeWorldPos(d.hinge)
  local axis = (nodeWorldPos(d.hinge2) - h1):normalized()
  local p = handlePos(d)
  local c = h1 + axis * (p - h1):dot(axis)
  local r = p - c
  local R = r:length()
  if R < 0.1 then return end
  -- closed handle direction: latch direction rotated by arcDelta around the axis
  local q = nodeWorldPos(d.latch) - h1
  q = (q - axis * q:dot(axis)):normalized()
  local e1 = q * math.cos(d.arcDelta) + axis:cross(q) * math.sin(d.arcDelta)
  local e2 = axis:cross(e1)
  local sg = d.arcSign
  local function arcPoint(u) local a = sg * u; return c + (e1 * math.cos(a) + e2 * math.sin(a)) * R end

  -- the cursor is matched against the arc of the point that was grabbed (e.g. the inside handle, ~0.3 m from
  -- the hinge), not the arc of the rear edge: seen from the seat the two arcs move differently on screen, and
  -- matching the wrong one swapped the drag direction. The grab point is where the cursor ray first hits the
  -- door plane (hinge axis + handle); the door is still pulled at the rear edge.
  if not d.grabR then
    local nrm = axis:cross(r):normalized()
    local dn = dir:dot(nrm)
    local g = nil
    if math.abs(dn) > 0.05 then
      local t = (h1 - O):dot(nrm) / dn
      if t > 0 then g = O + dir * t end
    end
    if g then
      local gh = (g - h1):dot(axis)
      local gr = g - h1 - axis * gh
      d.grabR = math.max(0.15, math.min(R, gr:length()))
      d.grabH = gh
    else
      d.grabR, d.grabH = R, (p - h1):dot(axis)
    end
  end
  local cg = h1 + axis * d.grabH
  local function grabPoint(u) local a = sg * u; return cg + (e1 * math.cos(a) + e2 * math.sin(a)) * d.grabR end

  -- opening angle of the handle now, and of the arc point closest to the cursor direction
  local uCur = sg * math.atan2(r:dot(e2), r:dot(e1))
  local bestU, bestScore = 0, -2
  local u = ARC_MIN
  while u <= ARC_MAX do
    local score = (grabPoint(u) - O):normalized():dot(dir)
    if score > bestScore then bestU, bestScore = u, score end
    u = u + ARC_STEP
  end
  -- refine around the best sample
  local lo, hi = math.max(ARC_MIN, bestU - ARC_STEP), math.min(ARC_MAX, bestU + ARC_STEP)
  for _ = 1, 12 do
    local m1, m2 = lo + (hi - lo) / 3, hi - (hi - lo) / 3
    if (grabPoint(m1) - O):normalized():dot(dir) > (grabPoint(m2) - O):normalized():dot(dir) then hi = m2 else lo = m1 end
  end
  local uCursor = (lo + hi) / 2

  -- Primary: the door turns to point (seen along the hinge axis, i.e. from above) at the spot where the cursor
  -- ray crosses the grab height. Pulling the cursor in towards the cabin closes the door from any direction
  -- (towards the seat or towards the footwell), pushing it outwards opens it. Even when that spot runs far
  -- away (shallow view from the other seat) its direction from the hinge stays steady.
  local uPlane, gLen = nil, nil
  local dnA = dir:dot(axis)
  if math.abs(dnA) > 1e-3 then
    local t = (cg - O):dot(axis) / dnA
    if t > 0 and t < 30 then
      local g = O + dir * t - cg
      gLen = g:length()
      if gLen > PLANE_MIN_RADIUS then uPlane = sg * math.atan2(g:dot(e2), g:dot(e1)) end
    end
  end

  if not d.uOffset then
    -- keep the grab point where it is: the door must not jump to the cursor on the first frame
    d.uOffset = uCur          -- target opening angle
    d.uCursorStart = uCursor  -- previous cursor angle (arc)
    d.uPlanePrev = uPlane     -- previous cursor angle (plane)
    d.uMoved = 0
  end

  -- "hand" model: the cursor moves a hand at the grab point. Its motion on the plane facing the camera
  -- (through the grab point) is taken 1:1; dragging down also pulls the hand towards the camera and up
  -- pushes it away (from inside, closing moves the handle along the line of sight, which no screen
  -- direction shows). Only the part of the hand motion along the door's swing moves the door. Simulated
  -- from both seats: 5 cm down closes 8-15 deg, 5 cm up opens as much, at any door angle; dragging down-left
  -- or down-right closes too.
  local duHand = nil
  local fo, fr, ff, fu = carFrame()
  if DRAG_MODEL == "hand" and d.prevRayO then
    -- last frame's ray where it is now, moved along with the car
    local prevO, prevD = fromCar(d.prevRayO, fo, fr, ff, fu), fromCar(d.prevRayD, nil, fr, ff, fu)
    local G = grabPoint(d.uOffset)
    local vw = (G - O):normalized()
    local function hitOnPlane(o, dr)
      local dn = dr:dot(vw)
      if dn < 0.05 then return nil end
      return o + dr * ((G - o):dot(vw) / dn)
    end
    local h0, h1p = hitOnPlane(prevO, prevD), hitOnPlane(O, dir)
    if h0 and h1p then
      local upv = vec3(0, 0, 1)
      upv = upv - vw * upv:dot(vw)
      if upv:length() > 1e-3 then
        upv = upv:normalized()
        local dp = h1p - h0
        local hand = dp + vw * (dp:dot(upv) * HAND_DEPTH_GAIN)
        local tOpen = axis:cross(G - cg) * sg
        if tOpen:length() > 1e-3 then
          duHand = hand:dot(tOpen:normalized()) / d.grabR
        end
      end
    end
  end
  d.prevRayO, d.prevRayD = toCar(O, fo, fr, ff, fu), toCar(dir, nil, fr, ff, fu)

  local du
  if DRAG_MODEL == "hand" then
    du = duHand or 0
  elseif uPlane and d.uPlanePrev then
    du = uPlane - d.uPlanePrev
    du = (du + math.pi) % (2 * math.pi) - math.pi
    -- like a hand: the grab point moves sideways as far as the cursor spot does (a far spot sweeps a small
    -- angle, which made the door react less the further the cursor was from the handle)
    --du = du -- old: angle only
    du = du * math.max(1, math.min(PLANE_MAX_GAIN, gLen / d.grabR))
  else
    -- fallback (cursor above the grab height): the cursor's motion along the arc on screen,
    -- amplified where the arc looks compressed
    du = uCursor - d.uCursorStart
    local a, b = grabPoint(d.uOffset) - O, grabPoint(d.uOffset + 0.02) - O
    local sens = math.acos(math.max(-1, math.min(1, a:normalized():dot(b:normalized())))) / 0.02
    du = du * math.min(4, math.max(1, ARC_MIN_SENS / math.max(sens, 1e-3)))
  end
  d.uCursorStart = uCursor
  d.uPlanePrev = uPlane
  d.uOffset = math.max(ARC_MIN, math.min(ARC_MAX, d.uOffset + du))
  d.target = arcPoint(d.uOffset)
  d.uMoved = d.uMoved + math.abs(du) * d.grabR
  if not d.dragging and d.uMoved > CLICK_MAX_MOVE then
    d.dragging = true
  end
end

-- push the door open like the old latch spring did (automatic opening: click / keyboard / controller)
local function push(id, force, duration)
  local d = getDoor(id)
  if not d then return end
  d.pushForce, d.pushTime = force, duration
end

-- airflow on an open, unlatched door while driving (see AIR_DENSITY ff.)
local function applyWind(id, dt)
  local d = getDoor(id)
  if not d or isLatched(id) then return end
  local vf = obj:getVelocity():dot(obj:getDirectionVector())   -- forward speed, m/s
  if math.abs(vf) < WIND_MIN_SPEED then return end
  local a = getAngle(id)
  if not a or a <= 0 then return end
  -- Cn of a flat plate: rises quickly at small angles, ~DOOR_CN_MAX across the flow
  local cn = DOOR_CN_MAX * math.sqrt(math.sin(math.min(a, math.pi / 2)))
  local f = 0.5 * AIR_DENSITY * vf * vf * DOOR_AREA * cn * DOOR_CP
  applyHandleForce(d, openDirection(d) * (vf > 0 and -f or f), dt)
end

local function updateGFX(dt)
  clock = clock + dt
  applyWind("FL", dt)
  applyWind("FR", dt)
  for id, d in pairs(doors) do
    if d.pushTime > 0 then
      d.pushTime = d.pushTime - dt
      if not isLatched(id) then
        applyHandleForce(d, openDirection(d) * d.pushForce, dt)
      end
    end

    if d.swingTarget then
      d.swingTime = d.swingTime - dt
      local a, R = getAngle(id)
      if d.active or d.swingTime <= 0 or not a then
        d.swingTarget = nil  -- the hand took over, or the door is stuck
      elseif not isLatched(id) then
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

    if d.active then
      d.pressTime = d.pressTime + dt
      if not d.dragging and d.pressTime > CLICK_MAX_TIME then
        d.dragging = true   -- held long enough: manual mode even without moving yet
      end
      -- a latched door can't be dragged; press the push button first (like the real car)
      if d.dragging and d.target and not isLatched(id) then
        local err = d.target - handlePos(d)
        err.z = 0
        local vel = handleVel(d)
        vel.z = 0
        -- velocity of the cursor target (relative to the car, smoothed): the damping only acts on the
        -- difference, so a quick pull carries the door along instead of braking it (momentum to latch it)
        if d.lastTarget then
          local vT = (d.target - d.lastTarget) / math.max(dt, 1e-3) - obj:getVelocity()
          vT.z = 0
          local k = math.min(1, dt / TARGET_VEL_TAU)
          d.targetVel = d.targetVel and (d.targetVel + (vT - d.targetVel) * k) or vT * k
          local l = d.targetVel:length()
          if l > TARGET_VEL_MAX then d.targetVel = d.targetVel * (TARGET_VEL_MAX / l) end
        end
        d.lastTarget = vec3(d.target.x, d.target.y, d.target.z)
        local vRel = vel - (d.targetVel or vec3(0, 0, 0))
        --local f = err * DRAG_SPRING - vel * DRAG_DAMP -- old: braked the door by its full speed (120 N at 3 m/s)
        if not DRAG_DAMP_RELATIVE then vRel = vel end
        local f = err * DRAG_SPRING - vRel * DRAG_DAMP
        local len = f:length()
        if len > DRAG_MAX_FORCE then f = f * (DRAG_MAX_FORCE / len) end
        -- near the seal the hand can't press the door shut slowly: limit the closing component
        local s = getOpening(id)
        if s and s < SEAL_ZONE then
          local dir = openDirection(d)
          local along = f:dot(dir)
          if along < -DRAG_SEAL_MAX_CLOSE then f = f + dir * (-DRAG_SEAL_MAX_CLOSE - along) end
        end
        applyHandleForce(d, f, dt)
      end
    end
  end
end

local function onReset()
  for id, d in pairs(doors) do
    if d.active then
      geCall(string.format("bug_doorDrag.stop(%d, %q)", obj:getId(), id))
      geCall(string.format("bug_doorDrag.stopRay(%d, %q, 'vehicle.doorDragRay')", obj:getId(), id))
    end
  end
  doors = {}
end

local function setClickHandler(fn) onClick = fn end

M.drag            = drag
M.setTarget       = setTarget
M.setRay          = setRay
M.push            = push
M.swingTo         = swingTo
M.getAngle        = getAngle
M.isLatched       = isLatched
M.getOpening      = getOpening
M.applyOpenForce  = applyOpenForce
M.applyOpenForceStep = applyOpenForceStep
M.hingeFrictionStep = hingeFrictionStep
M.setClickHandler = setClickHandler
M.updateGFX       = updateGFX
M.onReset         = onReset

return M
