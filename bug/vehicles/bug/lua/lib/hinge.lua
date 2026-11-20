-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Hinged parts moved by hand: a part (lid, backrest, cushion, door, ...) that swings on a hinge between two stop beams.
-- Knows nothing about a particular part: the feature modules (lib/lids.lua, lib/doorswing.lua, ...) register their
-- parts with a config
-- (node names, springs, limits) and optional hooks for their own logic (latches, locks, handles).
--
--   * Swing geometry from the hinge nodes, the handle nodes and a reference node on the fixed side (closed angle).
--   * Hinge springs (over-center): the part's weight is cancelled with its real node masses and positions every
--     frame (also on a slope); instead a net torque tOpen above / tClose below the over-center point acts, so below
--     it the part falls shut, above it it goes to the open stop. A damper acts on a part nobody holds. A part let go
--     faster than the throw speed (either way) gets only the weak throw damper until it settles: thrown open it
--     swings up fast and bounces at the stop a few times, thrown shut it keeps its momentum. A part thrown open that
--     doesn't make it over the over-center point gets the normal damper again as soon as it turns back, and a part
--     thrown shut as soon as it stops or bounces off the stop.
--   * Hand: hold + drag on the handle trigger. While it is held, the GE extension bug_doorDrag sends the cursor ray
--     every frame (the same as the doors, window cranks and the horn ring). The cursor motion moves a target angle
--     on the swing arc and the handle is pulled towards it with a capped spring-damper along the swing, so the hinge
--     and the stops still act. How the cursor moves the target (setRay):
--       - the cursor motion is measured on the plane through the handle facing the camera (the "hand"),
--       - where the swing is clearly visible on screen and opening moves the handle up on screen, the target follows
--         the cursor along the swing 1:1 (also sideways: from the side, dragging backwards opens the engine lid),
--       - where the swing points (almost) straight at the camera, or opening even moves the handle down on screen,
--         the swing's direction on screen is ignored and the hand's up / down motion moves the part: drag up = open.
--         In between the two are blended. screenFree parts follow the screen direction in any direction.
--       - the previous ray is kept in the car's frame, so the car moving between two frames isn't hand motion.
--     dragPlane parts (the doors) are dragged differently: the GE extension sends the cursor's point on a
--     horizontal plane at handle height (setTarget), and the handle is pulled towards that point (kept at the
--     offset it had when the cursor first came in) with a capped horizontal spring-damper.
--   * Double-click: automatic open / close (pushed at a set speed until it is open / shut or gives up).
--
-- Config of a part (hinge.register(id, cfg)):
--   hinge = {node, node}, ref = node (fixed side, sets the closed angle), handle = {{node, weight}, ...},
--   massNodes = {...} (weight cancellation), breakGroups = {...} (a broken hinge: the part is left alone),
--   springs = {mid, tOpen, tClose, width, damp, throw, throwDamp [, speedLimit, speedDamp]} (rad, N m, N m s/rad,
--   m/s, N s/m), maxDeg (the hand's target range), autoOpenDeg (automatic open stops here),
--   optional: dragMaxForce, dragSpring, dragDamp, autoGain, autoMaxForce, autoOpenSpeed, autoCloseSpeed,
--   screenFree, slowCloseCap = {gap, maxClose [, opening]} (near shut the hand pushes it shut with at most maxClose
--   N; opening(d) measures how far it is open in m, default: the arc length at the handle),
--   opensOutward (opening moves the handle away from the car's centre line; default: upwards),
--   dragPlane (drag on the horizontal plane at handle height, see above; dragSpring / dragDamp / dragMaxForce then
--   act on that plane), rayCmd (vehicle function the GE extension sends the cursor ray to, default lidDragRay).
-- Hooks (cfg.hooks, all optional):
--   init(d)              new state table d (also after a reset)
--   held(d)              true while the part is held shut (latched): no drag, no physics
--   blocked(d)           true: press / toggle / open are ignored
--   update(d, dt, held)  every frame before the physics; return true to skip the physics this frame
--   click(d)             single click on the handle
--   doubleClick(d)       double-click; return true if handled (else: automatic open / close)
--   closeStop(d, theta)  the automatic close is done (default: less than 1 deg open)
--   autoEnd(d, shut)     the automatic open / close ended
--
-- The game loads this file as a vehicle extension: updateGFX and onReset are called by the game for all parts.

local M = {}

local misc = require("vehicles/bug/lua/misc")

-- Defaults (a part's config may override some, see above)
local DRAG_SPRING      = 600   -- N/m    pull towards the target along the swing (error measured at the handle)
local DRAG_DAMP        = 40    -- N s/m  damping, relative to the target's own speed: a quick pull carries the part on
local DRAG_MAX_FORCE   = 200   -- N      cap
local TARGET_VEL_TAU   = 0.05  -- s      smoothing of the target's speed
local TARGET_LEAD      = math.rad(25) -- the target never runs further than this ahead of / behind the part
local DU_MAX           = 0.2   -- rad    max target change per frame
local CLICK_MAX_TIME   = 0.25  -- s      shorter press ...
local CLICK_MAX_MOVE   = 0.03  -- m      ... with less hand travel = click
local DOUBLE_CLICK_TIME = 0.4  -- s
local SCREEN_MIN       = 0.3   -- swing visible on screen at least this much (1 = side on, 0 = end on): follow 1:1 above
local BLEND_HI         = 0.5   -- swing visibility above this: the screen direction counts fully ...
local BLEND_LO         = 0.2   -- ... below this not at all: only the hand's up / down motion (up = open)
local UP_AGREE         = 0.5   -- cos of the angle between opening on screen and screen up: the screen direction counts
                               -- fully above this, not at all at 0 or below (opening moves the handle down on screen)
local AUTO_OPEN_SPEED  = 0.8   -- m/s    at the handle
local AUTO_CLOSE_SPEED = 1.2   -- m/s    at the handle
local AUTO_GAIN        = 300   -- N per m/s
local AUTO_MAX_FORCE   = 300   -- N
local AUTO_TIMEOUT     = 3     -- s      give up (part blocked)
local AUTO_TOGGLE_DEG  = 10    -- deg    double-click on a part open less than this opens it, otherwise closes it
local THROW_SETTLE_SPEED = 0.05 -- m/s   after a throw, slower than this ...
local THROW_SETTLE_TIME  = 0.4  -- s     ... for this long: settled, normal damper again

local PARTS = {}    -- id -> config (hinge.register)
local parts = {}    -- id -> state table, or false if the part isn't on the car
local clock = 0

local function nodeWorldPos(cid) return obj:getPosition() + obj:getNodePosition(cid) end
local function jbeamPos(cid) local p = v.data.nodes[cid].pos; return vec3(p.x, p.y, p.z) end

local function inBreakGroup(beam, groups)
  local bg = beam.breakGroup
  if type(bg) == "string" then return groups[bg] end
  if type(bg) == "table" then
    for _, g in pairs(bg) do if groups[g] then return true end end
  end
  return false
end

local function hook(d, name, ...)
  local h = d.cfg.hooks and d.cfg.hooks[name]
  if h then return h(d, ...) end
  return nil
end

local function getPart(id)
  local d = parts[id]
  if d ~= nil then return d or nil end
  local cfg = PARTS[id]
  if not cfg then return nil end
  local h1, h2 = misc.getNodeIDbyName(cfg.hinge[1]), misc.getNodeIDbyName(cfg.hinge[2])
  local ref = misc.getNodeIDbyName(cfg.ref)
  local handle = {}
  for _, hw in ipairs(cfg.handle) do
    local cid = misc.getNodeIDbyName(hw[1])
    if cid then handle[#handle + 1] = {cid = cid, w = hw[2]} end
  end
  if not h1 or not h2 or not ref or #handle == 0 then parts[id] = false return nil end
  local wSum = 0
  for _, h in ipairs(handle) do wSum = wSum + h.w end
  for _, h in ipairs(handle) do h.w = h.w / wSum end

  -- closed geometry from the jbeam: closed handle direction relative to the ref node (angle around the hinge
  -- axis) and the sign of the opening rotation (the handle moves upwards)
  local a0 = jbeamPos(h1)
  local axis0 = (jbeamPos(h2) - a0):normalized()
  local hp0 = vec3(0, 0, 0)
  for _, h in ipairs(handle) do hp0 = hp0 + jbeamPos(h.cid) * h.w end
  local r0 = hp0 - a0; r0 = r0 - axis0 * r0:dot(axis0)
  local q0 = jbeamPos(ref) - a0; q0 = q0 - axis0 * q0:dot(axis0)
  local arcDelta = math.atan2(axis0:dot(q0:cross(r0)), q0:dot(r0))
  local t0 = axis0:cross(r0)
  local sg
  if cfg.opensOutward then
    sg = (t0.x * hp0.x > 0) and 1 or -1   -- the handle moves away from the centre line (x = 0)
  else
    sg = (t0.z > 0) and 1 or -1           -- the handle moves upwards
  end

  local massCids, massW = {}, {}
  for _, name in ipairs(cfg.massNodes or {}) do
    local cid = misc.getNodeIDbyName(name)
    if cid then massCids[#massCids + 1] = cid; massW[#massW + 1] = obj:getNodeMass(cid) end
  end

  local groups, breakCids = {}, {}
  for _, g in ipairs(cfg.breakGroups or {}) do groups[g] = true end
  for _, b in pairs(v.data.beams) do
    if b.cid and inBreakGroup(b, groups) then breakCids[#breakCids + 1] = b.cid end
  end

  d = {id = id, cfg = cfg, h1 = h1, h2 = h2, ref = ref, handle = handle, arcDelta = arcDelta, sg = sg,
       massCids = massCids, massW = massW, breakCids = breakCids, broken = false,
       maxRad = math.rad(cfg.maxDeg), autoOpenRad = math.rad(cfg.autoOpenDeg),
       active = false, dragging = false, pressTime = 0, moved = 0, rayOn = false, lastClick = -1,
       uTarget = nil, prevO = nil, prevD = nil, lastU = nil, targetOmega = 0,
       planeStart = nil, planeOffset = nil, planeTarget = nil, cursorStart = nil,
       auto = nil, thrown = false, settleTime = 0}
  parts[id] = d
  hook(d, "init")
  return d
end

local function isHeld(d) return hook(d, "held") or false end
local function isBlocked(d) return hook(d, "blocked") or false end

local function isBroken(d)
  if d.broken then return true end
  for _, cid in ipairs(d.breakCids) do
    if obj:beamIsBroken(cid) then d.broken = true return true end
  end
  return false
end

local function handlePos(d)
  local p = vec3(0, 0, 0)
  for _, h in ipairs(d.handle) do p = p + nodeWorldPos(h.cid) * h.w end
  return p
end

-- live swing geometry: opening angle (rad, 0 = closed), handle radius, unit opening direction at the handle,
-- hinge axis, arc center and the arc's base vectors (closed direction e1, e2 = axis x e1), hinge node position
local function geom(d)
  local a = nodeWorldPos(d.h1)
  local axis = (nodeWorldPos(d.h2) - a):normalized()
  local hp = handlePos(d)
  local c = a + axis * (hp - a):dot(axis)
  local r = hp - c
  local R = r:length()
  if R < 0.05 then return nil end
  local q = nodeWorldPos(d.ref) - a
  q = (q - axis * q:dot(axis)):normalized()
  local e1 = q * math.cos(d.arcDelta) + axis:cross(q) * math.sin(d.arcDelta)
  local e2 = axis:cross(e1)
  local theta = d.sg * math.atan2(r:dot(e2), r:dot(e1))
  local t = axis:cross(r) * (d.sg / R)
  return theta, R, t, axis, c, e1, e2, a
end

-- handle speed along the opening direction (m/s), relative to the hinge
local function handleSpeed(d, t)
  local vel = vec3(0, 0, 0)
  for _, h in ipairs(d.handle) do vel = vel + obj:getNodeVelocityVector(h.cid) * h.w end
  vel = vel - (obj:getNodeVelocityVector(d.h1) + obj:getNodeVelocityVector(d.h2)) * 0.5
  return vel:dot(t)
end

-- handle velocity relative to the car (plane drag)
local function handleVelCar(d)
  local vel = vec3(0, 0, 0)
  for _, h in ipairs(d.handle) do vel = vel + obj:getNodeVelocityVector(h.cid) * h.w end
  return vel - obj:getVelocity()
end

local function applyHandleForce(d, f, dt)
  for _, h in ipairs(d.handle) do obj:applyForceVectorTime(h.cid, f * h.w, dt) end
end

local function arcPoint(d, u, c, e1, e2, R)
  local a = d.sg * u
  return c + (e1 * math.cos(a) + e2 * math.sin(a)) * R
end

-- the cursor ray comes in through vehicle.lidDragRay (vehicle.lua forwards it to setRay), unless the part names
-- another vehicle function (rayCmd); dragPlane parts get the cursor point through vehicle.doorDragTarget (setTarget),
-- the command the GE extension sends for its plane drags
local RAY_CMD = "vehicle.lidDragRay"
-- bug_doorDrag call; loading and the version check are in misc.geCall
local function geCall(cmd)
  misc.geCall("bug_doorDrag", cmd)
end
local function startRay(d)
  if d.rayOn then return end
  d.rayOn = true
  if d.cfg.dragPlane then
    -- the grab point: the handle where it is now; the cursor's first point sets the offset (setTarget)
    d.planeStart, d.planeOffset, d.planeTarget, d.cursorStart = handlePos(d), nil, nil, nil
    geCall(string.format("bug_doorDrag.start(%d, %q, %f)", obj:getId(), d.id, d.planeStart.z))
  else
    geCall(string.format("bug_doorDrag.startRay(%d, %q, %q)", obj:getId(), d.id, d.cfg.rayCmd or RAY_CMD))
  end
end
local function stopRay(d)
  if not d.rayOn then return end
  d.rayOn = false
  if d.cfg.dragPlane then
    geCall(string.format("bug_doorDrag.stop(%d, %q)", obj:getId(), d.id))
  else
    geCall(string.format("bug_doorDrag.stopRay(%d, %q, %q)", obj:getId(), d.id, d.cfg.rayCmd or RAY_CMD))
  end
end

-- net torque of springs + weight (N m, + = opening) at opening angle theta
local function netTorque(sp, theta)
  local T = theta > sp.mid and sp.tOpen or sp.tClose
  local x = (theta - sp.mid) / sp.width
  local e = math.exp(-2 * math.abs(x))
  return T * (x >= 0 and 1 or -1) * (1 - e) / (1 + e)   -- T * tanh(x)
end

-- torque of the part's weight around the hinge (N m, + = opening)
local function weightTorque(d, axis, a)
  local g = vec3(0, 0, obj:getGravity())
  local tau = 0
  for i, cid in ipairs(d.massCids) do
    tau = tau + axis:dot((nodeWorldPos(cid) - a):cross(g * d.massW[i]))
  end
  return tau * d.sg
end

local function startAuto(d, mode)
  d.auto = {mode = mode, time = AUTO_TIMEOUT}
  d.thrown = false
end

-- automatic open / close, by the angle
local function autoToggle(d)
  local theta = geom(d)
  if not theta then return end
  startAuto(d, theta < math.rad(AUTO_TOGGLE_DEG) and "open" or "close")
end

-- trigger press (value 1) / release (value 0) on the handle
local function press(id, value)
  local d = getPart(id)
  if not d or isBlocked(d) then return end
  if value and value > 0 then
    if d.active then return end
    d.active, d.dragging, d.pressTime, d.moved = true, false, 0, 0
    d.uTarget, d.prevO, d.prevD, d.lastU, d.targetOmega = nil, nil, nil, nil, 0
    d.planeOffset, d.planeTarget, d.cursorStart = nil, nil, nil
    d.thrown = false
    -- a plane drag starts on a held (latched) part too: cursor motion then still makes it a drag, not a click
    if (d.cfg.dragPlane or not isHeld(d)) and not isBroken(d) then startRay(d) end
  else
    if not d.active then return end
    local wasClick = not d.dragging and d.pressTime <= CLICK_MAX_TIME
    d.active, d.dragging = false, false
    stopRay(d)
    -- let go fast (either way): only the throw damper until it settles (thrown shut: slams onto the latch)
    if d.cfg.springs and not isHeld(d) then
      local theta, R, t = geom(d)
      if theta then
        local vt = handleSpeed(d, t)
        if math.abs(vt) > d.cfg.springs.throw then d.thrown, d.settleTime = (vt > 0 and 1 or -1), 0 end
      end
    end
    if wasClick then
      if clock - d.lastClick <= DOUBLE_CLICK_TIME then
        d.lastClick = -1
        if not hook(d, "doubleClick") then autoToggle(d) end
      else
        d.lastClick = clock
        hook(d, "click")
      end
    end
  end
end

-- automatic open / close without a trigger (keyboard)
local function toggle(id)
  local d = getPart(id)
  if not d or isBlocked(d) or isHeld(d) then return end
  autoToggle(d)
end

-- open automatically, if it isn't open already
local function open(id)
  local d = getPart(id)
  if not d or isBlocked(d) or isHeld(d) or d.active then return end
  local theta = geom(d)
  if theta and theta < d.autoOpenRad then startAuto(d, "open") end
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

-- called every frame by the GE extension with the cursor ray while the handle is held
local function setRay(id, px, py, pz, dx, dy, dz)
  local d = parts[id]
  if not d or not d.active or d.cfg.dragPlane then return end
  local O, dir = vec3(px, py, pz), vec3(dx, dy, dz):normalized()
  local theta, R, _, axis, c, e1, e2 = geom(d)
  if not theta then return end
  if not d.uTarget then d.uTarget = theta end
  local fo, fr, ff, fu = carFrame()

  if d.prevO then
    -- last frame's ray where it is now, moved along with the car
    local prevO, prevD = fromCar(d.prevO, fo, fr, ff, fu), fromCar(d.prevD, nil, fr, ff, fu)
    -- hand: cursor motion on the plane through the target point, facing the camera
    local P = arcPoint(d, d.uTarget, c, e1, e2, R)
    local vw = (P - O):normalized()
    local function hit(o, dr)
      local dn = dr:dot(vw)
      if dn < 0.05 then return nil end
      return o + dr * ((P - o):dot(vw) / dn)
    end
    local h0, h1 = hit(prevO, prevD), hit(O, dir)
    if h0 and h1 then
      local dp = h1 - h0
      -- swing direction at the target and how much of it shows on screen
      local t = axis:cross(P - c) * (d.sg / R)
      local ts = t - vw * t:dot(vw)
      local s = ts:length()
      local duScreen = dp:dot(ts) / (R * math.max(s * s, SCREEN_MIN * SCREEN_MIN))
      local up = vec3(0, 0, 1)
      up = up - vw * up:dot(vw)
      local duUp, cUp = 0, 0
      if up:length() > 1e-3 then
        up = up:normalized()
        duUp = dp:dot(up) / R
        if s > 1e-3 then cUp = ts:dot(up) / s end
        -- screenFree: the up / down motion moves it the way its (small) motion on screen goes (end on: up = open)
        if d.cfg.screenFree and s > 0.05 and cUp < 0 then duUp = -duUp end
      end
      -- weight of the screen direction (1 - w: up / down motion); only where opening moves the handle up on
      -- screen, screenFree parts: any direction (e.g. a backrest seen from the side folds sideways on screen)
      local w = clamp((s - BLEND_LO) / (BLEND_HI - BLEND_LO), 0, 1) * (d.cfg.screenFree and 1 or clamp(cUp / UP_AGREE, 0, 1))
      local du = clamp(duScreen * w + duUp * (1 - w), -DU_MAX, DU_MAX)
      local u = clamp(d.uTarget + du, math.rad(-2), d.maxRad)
      u = clamp(u, theta - TARGET_LEAD, theta + TARGET_LEAD)
      d.moved = d.moved + math.abs(u - d.uTarget) * R
      d.uTarget = u
      if not d.dragging and d.moved > CLICK_MAX_MOVE then d.dragging = true end
    end
  end
  d.prevO, d.prevD = toCar(O, fo, fr, ff, fu), toCar(dir, nil, fr, ff, fu)
end

-- called every frame by the GE extension with the cursor's point on the plane at handle height (dragPlane parts)
local function setTarget(id, x, y, z)
  local d = parts[id]
  if not d or not d.active or not d.cfg.dragPlane or not d.planeStart then return end
  local cursor = vec3(x, y, z)
  if not d.planeOffset then
    -- keep the grab point where it is: the part must not jump to the cursor on the first frame
    d.planeOffset = d.planeStart - cursor
    d.cursorStart = cursor
  end
  d.planeTarget = cursor + d.planeOffset
  if not d.dragging and (cursor - d.cursorStart):length() > CLICK_MAX_MOVE then d.dragging = true end
end

-- plane drag: the handle is pulled towards the target point, horizontally (the hinge, the stops and the jbeam's own
-- door physics still act)
local function planeHand(d, dt, theta, R, t)
  local err = d.planeTarget - handlePos(d)
  err.z = 0
  local vel = handleVelCar(d)
  vel.z = 0
  local f = err * (d.cfg.dragSpring or DRAG_SPRING) - vel * (d.cfg.dragDamp or DRAG_DAMP)
  local fMax = d.cfg.dragMaxForce or DRAG_MAX_FORCE
  local len = f:length()
  if len > fMax then f = f * (fMax / len) end
  -- near shut the hand can't press it shut slowly: limit the closing component
  local cap = d.cfg.slowCloseCap
  if cap then
    local gap
    if cap.opening then gap = cap.opening(d) else gap = theta * R end
    if gap and gap < cap.gap then
      local dir = vec3(t.x, t.y, 0)
      if dir:length() > 1e-3 then
        dir = dir:normalized()
        local along = f:dot(dir)
        if along < -cap.maxClose then f = f + dir * (-cap.maxClose - along) end
      end
    end
  end
  applyHandleForce(d, f, dt)
end

local function dragLost(id)
  press(id, 0)
end

local function updatePart(d, dt)
  local held = isHeld(d)
  if hook(d, "update", dt, held) then return end

  if d.active then
    d.pressTime = d.pressTime + dt
    if not d.dragging and d.pressTime > CLICK_MAX_TIME then d.dragging = true end
    -- released while the handle is held (e.g. the frunk's catch): start dragging now
    if not held and not d.rayOn and not isBroken(d) then startRay(d) end
  end

  if held or isBroken(d) then
    if d.auto then hook(d, "autoEnd", false) end
    d.auto, d.thrown = nil, false
    if d.broken then stopRay(d) end
    return
  end

  local theta, R, t, axis, _, _, _, a = geom(d)
  if not theta then return end
  local vt = handleSpeed(d, t)
  local f = 0

  -- hinge springs + damper
  local sp = d.cfg.springs
  if sp then
    local tau = netTorque(sp, theta) - weightTorque(d, axis, a)
    if d.thrown == -1 and vt > -THROW_SETTLE_SPEED then
      d.thrown = false   -- thrown shut: stopped or bounced off the stop
    elseif d.thrown == 1 and theta < sp.mid and vt < THROW_SETTLE_SPEED then
      d.thrown = false   -- thrown open but not over the over-center point: falls back damped (no slam)
    elseif d.thrown then
      d.settleTime = math.abs(vt) < THROW_SETTLE_SPEED and d.settleTime + dt or 0
      if d.settleTime > THROW_SETTLE_TIME then d.thrown = false end
    end
    if not d.active and not d.auto then
      tau = tau - (d.thrown and sp.throwDamp or sp.damp) * vt / R
      -- speed limit when closing (engine lid)
      if sp.speedLimit and -vt > sp.speedLimit then tau = tau + sp.speedDamp * (-vt - sp.speedLimit) * R end
    end
    f = f + tau / R
  end

  -- automatic open / close
  if d.auto then
    d.auto.time = d.auto.time - dt
    local shut = hook(d, "closeStop", theta)
    if shut == nil then shut = theta < math.rad(1) end
    if d.active or d.auto.time <= 0 or (d.auto.mode == "open" and theta >= d.autoOpenRad)
       or (d.auto.mode == "close" and shut) then
      hook(d, "autoEnd", shut)
      d.auto = nil
    else
      local vTarget = d.auto.mode == "open" and (d.cfg.autoOpenSpeed or AUTO_OPEN_SPEED)
                      or -(d.cfg.autoCloseSpeed or AUTO_CLOSE_SPEED)
      local fMax = d.cfg.autoMaxForce or AUTO_MAX_FORCE
      f = f + clamp((vTarget - vt) * (d.cfg.autoGain or AUTO_GAIN), -fMax, fMax)
    end
  end

  -- hand
  if d.cfg.dragPlane then
    if d.active and d.dragging and d.planeTarget then planeHand(d, dt, theta, R, t) end
  elseif d.active and d.dragging and d.uTarget then
    if d.lastU then
      local k = math.min(1, dt / TARGET_VEL_TAU)
      d.targetOmega = d.targetOmega + ((d.uTarget - d.lastU) / math.max(dt, 1e-3) - d.targetOmega) * k
    end
    d.lastU = d.uTarget
    local fh = (d.uTarget - theta) * R * (d.cfg.dragSpring or DRAG_SPRING)
               - (vt - d.targetOmega * R) * (d.cfg.dragDamp or DRAG_DAMP)
    local fMax = d.cfg.dragMaxForce or DRAG_MAX_FORCE
    fh = clamp(fh, -fMax, fMax)
    local cap = d.cfg.slowCloseCap
    if cap and theta * R < cap.gap then fh = math.max(fh, -cap.maxClose) end
    f = f + fh
  end

  if math.abs(f) > 0.01 then applyHandleForce(d, t * f, dt) end
end

-- a feature module registers its part (see the config and hooks at the top)
local function register(id, cfg)
  PARTS[id] = cfg
  parts[id] = nil
end

local function updateGFX(dt)
  clock = clock + dt
  for id in pairs(PARTS) do
    local d = getPart(id)
    if d then updatePart(d, dt) end
  end
end

local function onReset()
  for _, d in pairs(parts) do
    if d then stopRay(d) end
  end
  parts = {}
end

local function isPart(id) return PARTS[id] ~= nil end

M.DOUBLE_CLICK_TIME = DOUBLE_CLICK_TIME
M.register   = register
M.get        = getPart
M.geom       = geom
M.isBroken   = isBroken
M.startAuto  = startAuto
M.autoToggle = autoToggle
M.press      = press
M.toggle     = toggle
M.open       = open
M.setRay     = setRay
M.setTarget  = setTarget
M.dragLost   = dragLost
M.isPart     = isPart
M.updateGFX  = updateGFX
M.onReset    = onReset

return M
