-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Frunk lid (front hood) and engine lid (rear): click / drag / double-click on the outside handle.
--
--   frunk:  the interior pull handle releases the main latch and the safety catch together (vehicle.lua,
--           toolgeHoodRelease): the lid pops up into the leaned position on its rubber buffers. Then hold + drag on
--           the outside handle swings the lid to any position, a double-click opens or closes it automatically.
--           (A click on the outside handle still releases the catch if it is latched on its own.)
--           The hinge springs are over-center: above half open (FRUNK_MID_FRACTION) they push the lid fully open,
--           below it the lid sinks shut on its own, damped, and stays on the rubber buffers (pop-open beams)
--           without latching. Only a lid that comes down with momentum (thrown or slammed) gets through the buffers
--           to the latch.
--   engine: click on the locked lid turns the handle into the open position: stiff for the first HANDLE_SLOW_DEG,
--           then the spring in the handle snaps it round, and at the end the latch releases. After that hold +
--           drag on the handle swings the lid (drag up to open), a double-click opens / closes it automatically.
--           Its hinge springs are weaker than the frunk's (ENGINE_*): above the over-center point (60 % open) they
--           hold it open, so the first 40 % of closing has spring resistance; let go below it, it falls shut by
--           itself, harder than the frunk. A speed limit and a weaker hand (ENGINE_DRAG_MAX_FORCE) keep it from
--           being thrown into the apron. Closing never locks it (trunkCoupler is a manualClose coupler now): the handle stays
--           in the open position until it is clicked again with the lid shut, then it turns back and locks the lid
--           (the coupler pulls it onto the latch). The keyboard action closes and locks it.
--
-- Dragging: while the handle is held, the GE extension bug_doorDrag sends the cursor ray every frame (startRay,
-- the same as the window cranks and the horn ring). The cursor motion moves a target angle on the lid's swing
-- arc and the handle is pulled towards it with a capped spring-damper along the swing, so the hinge, the struts
-- and the stops still act. How the cursor moves the target (setRay):
--   * the cursor motion is measured on the plane through the handle facing the camera (the "hand"),
--   * where the swing is clearly visible on screen and opening moves the handle up on screen, the target follows
--     the cursor along the swing 1:1 (also sideways: from the side, dragging backwards opens the engine lid),
--   * where the swing points (almost) straight at the camera, or opening even moves the handle down on screen
--     (e.g. looking steeply down at the engine lid handle from behind: it first swings towards the camera), the
--     swing's direction on screen is ignored and the hand's up / down motion moves the lid: drag up = open (both
--     lids' handles move upwards over their whole swing). In between the two are blended.
--
-- Like the other files in lua/, the game loads this file as a vehicle extension: updateGFX and onReset are called
-- by the game. vehicle.lua exports press / setRay / toggle (require() returns the same module table).

local M = {}

local misc = require("vehicles/bug/lua/misc")

-- Drag (both lids)
local DRAG_SPRING      = 600   -- N/m    pull towards the target along the swing (error measured at the handle)
local DRAG_DAMP        = 40    -- N s/m  damping, relative to the target's own speed: a quick pull carries the lid on
local DRAG_MAX_FORCE   = 200   -- N      cap
local TARGET_VEL_TAU   = 0.05  -- s      smoothing of the target's speed
local TARGET_LEAD      = math.rad(25) -- the target never runs further than this ahead of / behind the lid
local DU_MAX           = 0.2   -- rad    max target change per frame
local CLICK_MAX_TIME   = 0.25  -- s      shorter press ...
local CLICK_MAX_MOVE   = 0.03  -- m      ... with less hand travel = click
local DOUBLE_CLICK_TIME = 0.4  -- s
local SCREEN_MIN       = 0.3   -- swing visible on screen at least this much (1 = side on, 0 = end on): follow 1:1 above
local BLEND_HI         = 0.5   -- swing visibility above this: the screen direction counts fully ...
local BLEND_LO         = 0.2   -- ... below this not at all: only the hand's up / down motion (up = open)
local UP_AGREE         = 0.5   -- cos of the angle between opening on screen and screen up: the screen direction counts
                               -- fully above this, not at all at 0 or below (opening moves the handle down on screen)
local NEAR_CLOSED_GAP  = 0.035 -- m      lid this close to shut (at the handle) ...
local NEAR_CLOSED_MAX_CLOSE = 40 -- N    ... the hand pushes it shut with at most this: it can't be pressed onto the
                                 --        latch slowly through the buffers, only slammed (momentum)

-- Automatic open / close (double-click, keyboard)
local AUTO_OPEN_SPEED  = 0.8   -- m/s    at the handle
local AUTO_CLOSE_SPEED = 1.2   -- m/s    at the handle, fast enough to get through the buffers onto the latch
local AUTO_GAIN        = 300   -- N per m/s
local AUTO_MAX_FORCE   = 300   -- N
local AUTO_TIMEOUT     = 3     -- s      give up (lid blocked)
local AUTO_TOGGLE_DEG  = 10    -- deg    double-click on a lid open less than this opens it, otherwise closes it
local PENDING_OPEN_TIME = 2.5  -- s      double-click on a latched lid: open it as soon as the latch is released

-- Hinge springs (over-center). The physical gas struts of both lids are removed in the jbeams; here the net
-- torque (springs + weight) is set directly: the lid's weight is cancelled with its real node masses and positions
-- every frame (also on a slope), and T_OPEN above / T_CLOSE below the over-center point act instead. The damper
-- only acts on a lid nobody holds. A lid let go faster than the throw speed (either way) gets only the weak
-- throw damper until it settles: thrown open it swings up fast and bounces at the stop a few times, thrown shut it
-- keeps its momentum. A lid thrown open that doesn't make it over the over-center point gets the normal damper
-- again as soon as it turns back, and a lid thrown shut as soon as it stops or bounces off the buffers.
local FRUNK_FULL_DEG     = 55    -- deg    fully open (limiter beams h2rr/h2ll-bf8, computed from the jbeam)
local FRUNK_MID_FRACTION = 0.5   -- over-center point as a fraction of fully open
local FRUNK_T_OPEN       = 40    -- N m    net opening torque above the over-center point (~30 N at the handle)
local FRUNK_T_CLOSE      = 30    -- N m    net closing torque below it (~25 N at the handle)
local FRUNK_T_WIDTH      = math.rad(3) -- smooth change over the over-center point
local FRUNK_DAMP         = 100   -- N m s/rad  damper of the free lid: it sinks shut at ~0.3 rad/s (~0.4 m/s at the
                                 --        handle), too slow to get through the buffers onto the latch
local FRUNK_THROW_SPEED  = 0.8   -- m/s    released faster than this (at the handle): throw damper only. Closing, it
                                 --        slams (simulated: from 5-15 deg it then latches; damped it stays on the buffers)
--local FRUNK_THROW_DAMP   = 0   -- old: thrown open, the lid got the full damper and rose slowly
local FRUNK_THROW_DAMP   = 15    -- N m s/rad  after a throw: the lid swings against the stop a few times, then settles
-- engine lid (I ~1.5 kg m^2, handle 0.61 m from the hinge). Old gas struts: too strong to close by hand, fast
-- opening with an overshoot at the stop, heavily damped. Simulated in 1D: let go below the over-center point it
-- hits the buffers at ~0.9 m/s (frunk: ~0.4), thrown shut at most ~1.2 m/s; unlocking pops it < 1 deg open
local ENGINE_FULL_DEG    = 105   -- deg    fully open (limiter beams t2rr/t2ll-br3, computed from the jbeam)
--local ENGINE_MID_DEG     = 30  -- old
local ENGINE_MID_FRACTION = 0.6  -- over-center point: closing has spring resistance for the first 40 %
--local ENGINE_T_OPEN      = 8   -- old
local ENGINE_T_OPEN      = 6     -- N m    above it (~10 N at the handle): holds it open
--local ENGINE_T_CLOSE     = 6   -- old
local ENGINE_T_CLOSE     = 10    -- N m    below it (~16 N at the handle): falls shut
local ENGINE_T_WIDTH     = math.rad(4)
--local ENGINE_DAMP        = 12  -- old
local ENGINE_DAMP        = 6     -- N m s/rad  weaker than the frunk's: it falls shut at ~0.9 m/s at the handle
local ENGINE_THROW_SPEED = 0.6   -- m/s    let go faster than this: throw damper only
local ENGINE_THROW_DAMP  = 4     -- N m s/rad
local ENGINE_SPEED_LIMIT = 1.2   -- m/s    closing faster than this at the handle (not held) ...
local ENGINE_SPEED_DAMP  = 40    -- N s/m  ... is braked this hard above it: it can't be thrown into the apron
--local ENGINE_DRAG_MAX_FORCE = DRAG_MAX_FORCE -- old: 200 N swung the light lid far too hard
local ENGINE_DRAG_MAX_FORCE = 90 -- N      hand force cap on the engine lid
local THROW_SETTLE_SPEED = 0.05  -- m/s    after a throw, slower than this ...
local THROW_SETTLE_TIME  = 0.4   -- s      ... for this long: settled, normal damper again
local ENGINE_LOCK_MAX_DEG = 4    -- deg    lid at most this open: a click on the handle locks it
local ENGINE_LOCK_WAIT   = 1.5   -- s      the coupler pulls the lid onto the latch; not latched by then: give up

-- Seats ("lids" without a latch): the front seat backrests (fold forward) of the generic front seats
-- (bug.interior.seats.generics.jbeam). Hover lights up the backrest, hold + drag swings it, double-click folds /
-- unfolds it, a single click does nothing. It swings freely between stop beams (is<ID>1i/1o - is<ID>5i/5o); like the
-- lids its weight is cancelled and an over-center torque acts: below the tipping point it falls back upright, above
-- it it goes to the folded stop. The constant closing torque also holds it upright against braking / bumps. The hand
-- may drag it in any screen direction (screenFree), the light part gets a weaker hand and automatic push.
-- The seat's backrest hydro (input seat<ID>backrest) is the lock: while nobody sits on the seat its beams are slack
-- (spring 0), so the hinge is free; while someone sits there (the game's occupant system says so) it is stiff again
-- and holds the backrest upright, and the backrest can't be dragged or folded (see the seat lock below).
local SEAT_FRONT_FULL_DEG  = 42   -- deg    backrest folded forward (stop beams is<ID>1-is<ID>5, 0.295 m shorter)
local SEAT_FRONT_MID_FRACTION = 0.5 -- tipping point (~ where its weight would tip it forward)
local SEAT_FRONT_T_OPEN    = 6    -- N m    above it: falls forward onto the stop
local SEAT_FRONT_T_CLOSE   = 20   -- N m    below it: falls back upright (more than its weight's torque at 1 g)
local SEAT_FRONT_DAMP      = 15   -- N m s/rad  (I ~1 kg m^2, top of the backrest 0.67 m from the pivot)
local SEAT_T_WIDTH         = math.rad(3)
local SEAT_THROW_SPEED     = 0.8  -- m/s
local SEAT_THROW_DAMP      = 3    -- N m s/rad
local SEAT_DRAG_MAX_FORCE  = 90   -- N
local SEAT_DRAG_SPRING     = 1500 -- N/m    short levers: with the lids' 600 the hand lagged far behind against the closing torque
local SEAT_DRAG_DAMP       = 120  -- N s/m  with the lids' 40 the light seats wobbled around the hand (damping ratio ~0.25)
local SEAT_AUTO_GAIN       = 150  -- N per m/s  (300 would make the light parts jitter at the graphics frame rate)
local SEAT_AUTO_MAX_FORCE  = 90   -- N
local SEAT_AUTO_CLOSE_SPEED = 0.6 -- m/s    at the drag point: no slam onto the stop

-- Engine lid handle (prop anim__trunk: 0 = closed, 1 = open position, HANDLE_FULL_DEG)
local HANDLE_FULL_DEG    = 180   -- deg    prop rotation at 1 (trunk_handle, bug.body.trunk.jbeam)
local HANDLE_SLOW_DEG    = 15    -- deg    stiff part of the turn ...
local HANDLE_SLOW_TIME   = 0.35  -- s      ... takes this long
local HANDLE_SNAP_TIME   = 0.09  -- s      the rest snaps round (accelerating, the handle's spring)
local HANDLE_RETURN_TIME = 0.15  -- s      turning back when the lid latches
local HANDLE_LOCK_TIME   = 0.25  -- s      turning back to lock (click on the closed, unlocked lid)

local LIDS = {
  frunk = {
    hinge = {"h8l", "h8r"}, ref = "bf2",       -- ref: body node at the latch, sets the closed angle
    handle = {{"h4", 0.5}, {"h5", 0.5}},       -- handle force nodes (handle mesh at y -1.795, z 0.505)
    couplers = {"hoodCatchCoupler", "hoodLatchCoupler"}, -- [1] is released by the outside handle
    breakGroups = {"hoodhinge_L", "hoodhinge_R"},
    massNodes = {"h1rrr","h1rr","h1r","h1l","h1ll","h1lll","h2rr","h2r","h2l","h2ll","h3rr","h3r","h3","h3l","h3ll",
                 "h4rr","h4r","h4","h4l","h4ll","h5r","h5","h5l","h6","h7r","h7l","h7ar","h7al","h9"},
    springs = {mid = math.rad(FRUNK_FULL_DEG * FRUNK_MID_FRACTION), tOpen = FRUNK_T_OPEN, tClose = FRUNK_T_CLOSE,
               width = FRUNK_T_WIDTH, damp = FRUNK_DAMP, throw = FRUNK_THROW_SPEED, throwDamp = FRUNK_THROW_DAMP},
    slowCloseCap = true,                       -- the hand can't press it onto the latch slowly (NEAR_CLOSED_*)
    maxDeg = FRUNK_FULL_DEG + 3,
    autoOpenDeg = FRUNK_FULL_DEG * FRUNK_MID_FRACTION + 8, -- past the over-center point, the springs do the rest
  },
  engine = {
    hinge = {"th1l", "th1r"}, ref = "br5",
    handle = {{"t4", 0.6}, {"t6", 0.4}},       -- handle mesh at y 1.969, z 0.405
    couplers = {"trunkCoupler"},
    breakGroups = {"trunkhinge_L", "trunkhinge_R"},
    massNodes = {"t1ll","t1l","t1","t1r","t1rr","t2ll","t2l","t2","t2r","t2rr","t3l","t3","t3r","t4","t5","t6"},
    springs = {mid = math.rad(ENGINE_FULL_DEG * ENGINE_MID_FRACTION), tOpen = ENGINE_T_OPEN, tClose = ENGINE_T_CLOSE,
               width = ENGINE_T_WIDTH, damp = ENGINE_DAMP, throw = ENGINE_THROW_SPEED, throwDamp = ENGINE_THROW_DAMP,
               speedLimit = ENGINE_SPEED_LIMIT, speedDamp = ENGINE_SPEED_DAMP},
    dragMaxForce = ENGINE_DRAG_MAX_FORCE,
    turnHandle = "anim__trunk",
    manualLock = true,                         -- closing doesn't lock it, a click on the handle does
    maxDeg = 110,
    autoOpenDeg = ENGINE_FULL_DEG * ENGINE_MID_FRACTION + 10, -- past the over-center point, the springs do the rest
  },
}

local function frontSeat(s)
  return {
    hinge = {"is" .. s .. "4i", "is" .. s .. "4o"}, ref = "is" .. s .. "1i",   -- pivot / front cushion node
    handle = {{"is" .. s .. "5i", 0.5}, {"is" .. s .. "5o", 0.5}},           -- top of the backrest
    couplers = {}, breakGroups = {},
    massNodes = {"is" .. s .. "5i", "is" .. s .. "5o", "is" .. s .. "6i", "is" .. s .. "6o"},
    lock = "seat" .. s .. "backrest", seatId = s,  -- backrest hydro input, seat id of the game's occupant system
    springs = {mid = math.rad(SEAT_FRONT_FULL_DEG * SEAT_FRONT_MID_FRACTION), tOpen = SEAT_FRONT_T_OPEN,
               tClose = SEAT_FRONT_T_CLOSE, width = SEAT_T_WIDTH, damp = SEAT_FRONT_DAMP,
               throw = SEAT_THROW_SPEED, throwDamp = SEAT_THROW_DAMP},
    dragMaxForce = SEAT_DRAG_MAX_FORCE, dragSpring = SEAT_DRAG_SPRING, dragDamp = SEAT_DRAG_DAMP, autoGain = SEAT_AUTO_GAIN, autoMaxForce = SEAT_AUTO_MAX_FORCE,
    autoCloseSpeed = SEAT_AUTO_CLOSE_SPEED, screenFree = true,
    maxDeg = 50,
    autoOpenDeg = SEAT_FRONT_FULL_DEG * SEAT_FRONT_MID_FRACTION + 8,
  }
end
LIDS.seatFL = frontSeat("FL")
LIDS.seatFR = frontSeat("FR")

local lids = {}     -- per id: state table, or false if the lid isn't there
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

local function getLid(id)
  local d = lids[id]
  if d ~= nil then return d or nil end
  local cfg = LIDS[id]
  if not cfg then return nil end
  local h1, h2 = misc.getNodeIDbyName(cfg.hinge[1]), misc.getNodeIDbyName(cfg.hinge[2])
  local ref = misc.getNodeIDbyName(cfg.ref)
  local handle = {}
  for _, hw in ipairs(cfg.handle) do
    local cid = misc.getNodeIDbyName(hw[1])
    if cid then handle[#handle + 1] = {cid = cid, w = hw[2]} end
  end
  if not h1 or not h2 or not ref or #handle == 0 then lids[id] = false return nil end
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
  local sg = (axis0:cross(r0).z > 0) and 1 or -1

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
       auto = nil, pendingOpen = nil, thrown = false,
       handleValue = 0, turning = false, turnTime = 0}
  lids[id] = d
  return d
end

local function isLatched(d)
  for _, name in ipairs(d.cfg.couplers) do
    local c = controller.getController(name)
    if c then
      local s = c.getGroupState()
      if s == "attached" or s == "desyncedAttached" then return true end
    end
  end
  return false
end

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
-- hinge axis, arc center and the arc's base vectors (closed direction e1, e2 = axis x e1)
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

local function applyHandleForce(d, f, dt)
  for _, h in ipairs(d.handle) do obj:applyForceVectorTime(h.cid, f * h.w, dt) end
end

local function arcPoint(d, u, c, e1, e2, R)
  local a = d.sg * u
  return c + (e1 * math.cos(a) + e2 * math.sin(a)) * R
end

local RAY_CMD = "vehicle.lidDragRay"
-- bug_doorDrag call; loading and the version check are in misc.geCall
local function geCall(cmd)
  misc.geCall("bug_doorDrag", cmd)
end
local function startRay(d)
  if d.rayOn then return end
  d.rayOn = true
  geCall(string.format("bug_doorDrag.startRay(%d, %q, %q)", obj:getId(), d.id, RAY_CMD))
end
local function stopRay(d)
  if not d.rayOn then return end
  d.rayOn = false
  geCall(string.format("bug_doorDrag.stopRay(%d, %q, %q)", obj:getId(), d.id, RAY_CMD))
end

-- net torque of springs + weight (N m, + = opening) at opening angle theta
local function netTorque(sp, theta)
  local T = theta > sp.mid and sp.tOpen or sp.tClose
  local x = (theta - sp.mid) / sp.width
  local e = math.exp(-2 * math.abs(x))
  return T * (x >= 0 and 1 or -1) * (1 - e) / (1 + e)   -- T * tanh(x)
end

-- torque of the lid's weight around the hinge (N m, + = opening)
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

-- Engine lid handle: start turning it into the open position (releases the latch at the end)
local function startTurn(d)
  if not d.cfg.turnHandle or d.turning then return end
  local hSlow = HANDLE_SLOW_DEG / HANDLE_FULL_DEG
  local h = d.handleValue
  -- continue from where the handle is
  if h < hSlow then
    d.turnTime = HANDLE_SLOW_TIME * h / hSlow
  else
    d.turnTime = HANDLE_SLOW_TIME + HANDLE_SNAP_TIME * math.sqrt(math.min(1, (h - hSlow) / (1 - hSlow)))
  end
  d.turning = true
end

local function releaseLatch(d)
  local c = controller.getController(d.cfg.couplers[1])
  if not c then return end
  local s = c.getGroupState()
  if s == "attached" or s == "desyncedAttached" then c.toggleGroup() end
end

-- Engine lid: lock the closed lid (click on the handle): the handle turns back, then the coupler is asked to
-- latch (it pulls the lid onto the latch, with an automatic close push as well). manualClose coupler: if the lid
-- doesn't reach the latch, the coupler would stay armed and latch by itself later, so it is detached again.
local function startLock(d)
  if not d.cfg.manualLock or d.turning or d.locking or d.lockWait then return end
  d.locking = true
  d.pendingOpen = nil
end

local function requestLatch(d)
  local c = controller.getController(d.cfg.couplers[1])
  if c then c.tryAttachGroupImpulse() end
  startAuto(d, "close")
  d.lockWait = ENGINE_LOCK_WAIT
end

local function lockFailed(d)
  local c = controller.getController(d.cfg.couplers[1])
  if c and c.getGroupState() == "autoCoupling" then obj:detachCoupler(d.ref, 0) end
  d.auto = nil
end

local function updateHandle(d, dt, latched)
  if not d.cfg.turnHandle then return end
  local h = d.handleValue
  if d.locking then
    h = math.max(0, h - dt / HANDLE_LOCK_TIME)
    if h <= 0 then
      d.locking = false
      requestLatch(d)
    end
  elseif d.lockWait then
    d.lockWait = d.lockWait - dt
    if latched then
      d.lockWait = nil
    elseif d.lockWait <= 0 then
      d.lockWait = nil
      lockFailed(d)   -- the handle turns back into the open position below (next frame)
    end
  elseif d.turning then
    d.turnTime = d.turnTime + dt
    local hSlow = HANDLE_SLOW_DEG / HANDLE_FULL_DEG
    if d.turnTime < HANDLE_SLOW_TIME then
      h = hSlow * d.turnTime / HANDLE_SLOW_TIME
    else
      local k = (d.turnTime - HANDLE_SLOW_TIME) / HANDLE_SNAP_TIME
      if k >= 1 then
        h = 1
        d.turning = false
        d.holdOpen = 0.3   -- the coupler reports the release a moment later: don't turn back meanwhile
        releaseLatch(d)
      else
        h = hSlow + (1 - hSlow) * k * k
      end
    end
  elseif d.holdOpen then
    d.holdOpen = d.holdOpen - dt
    if d.holdOpen <= 0 or not latched then d.holdOpen = nil end
  elseif latched then
    h = math.max(0, h - dt / HANDLE_RETURN_TIME)   -- latched again: the handle turns back
  else
    h = math.min(1, h + dt / HANDLE_RETURN_TIME)   -- released some other way: handle in the open position
  end
  d.handleValue = h
  electrics.values[d.cfg.turnHandle] = h
end

-- single click on the handle
local function onClick(d)
  if d.cfg.manualLock and not isLatched(d) then
    -- engine lid shut but unlocked: lock it, after the double-click time (a double-click opens it instead)
    local theta = geom(d)
    if theta and theta < math.rad(ENGINE_LOCK_MAX_DEG) and not d.turning then d.lockPending = DOUBLE_CLICK_TIME end
    return
  end
  if d.id == "frunk" then
    local catch = controller.getController(d.cfg.couplers[1])
    if catch then
      local s = catch.getGroupState()
      if s == "attached" or s == "desyncedAttached" then
        -- like the game's hoodCatch action: the interior pull handle must have released the main latch first
        catch.toggleGroupConditional({{d.cfg.couplers[2], "attached", "vehicle.advancedCouplerControl.releaseHoodFirstInterior"}})
      end
    end
  elseif isLatched(d) then
    startTurn(d)
  end
end

local function autoToggle(d)
  d.lockPending = nil
  if d.locking or d.lockWait then
    -- double-click while locking: open instead
    d.locking = false
    if d.lockWait then d.lockWait = nil; lockFailed(d) end
  end
  if isLatched(d) or d.turning then
    if d.cfg.turnHandle then startTurn(d) end
    d.pendingOpen = PENDING_OPEN_TIME   -- open as soon as the latch is released (first click released it / turns the handle)
    return
  end
  local theta = geom(d)
  if not theta then return end
  startAuto(d, theta < math.rad(AUTO_TOGGLE_DEG) and "open" or "close")
end

-- Seat lock: the backrest hydro of a generic front seat (beams is<ID>1i - is<ID>5i and is<ID>1o - is<ID>5o, input
-- seat<ID>backrest). Nobody on the seat: its beams are slack (spring and damping 0), the backrest swings freely as a
-- "lid". Someone sits down: the input goes to upright, and once the hydro has moved there its spring and damping are
-- restored, so it holds the backrest upright against braking and the occupant; dragging and folding are blocked.
-- Who sits where comes from the game's occupant system (GE gameplay_seatOccupants.getSeats), asked twice a second
-- (the mass of the occupant's nodes is no use for it: an empty seat's occupant wanders between 5 and over 10 kg).
-- The occupant's body (which stays on the seat, invisible, even when it is empty) is attached to the cushion and the
-- seat frame only, not to the backrest (bug.interior.seats.generics.jbeam), so it doesn't hold the backrest.
-- The input also works the other way round: when something else sets it (the seat's toggle action, getting out of a
-- rear seat folds the front backrest), the backrest folds / unfolds automatically; once it has settled the input is
-- set to match (1 = folded, 0 = upright), so the toggle always does the opposite of what is seen.
local SEAT_POLL_TIME   = 0.5    -- s    how often GE is asked which seats are occupied
local SEAT_LOCK_DELAY  = 1.0    -- s    from setting the input to upright until the hydro is stiff again (its rate
                                --      is 1 per second: it is back at upright by then)
local seatLocks = {}            -- id -> {elec, beams, locked, lockTimer, elecSeen}, or false (not a seat)
local occupiedSeats = {}        -- seat id of the occupant system ("FL", "FR", …) -> true, from GE
local seatPollTime = 0

-- GE answers the poll with this: the occupied seats of this car, e.g. {"FL"}
local function setOccupiedSeats(list)
  occupiedSeats = {}
  for _, seatId in ipairs(list or {}) do occupiedSeats[seatId] = true end
end

-- asks GE which seats of this car are occupied (the answer comes back through setOccupiedSeats)
local function pollOccupiedSeats(dt)
  seatPollTime = seatPollTime - dt
  if seatPollTime > 0 then return end
  seatPollTime = SEAT_POLL_TIME
  local id = obj:getId()
  obj:queueGameEngineLua(string.format(
    "local so = gameplay_seatOccupants; local veh = getObjectByID(%d); "
    .. "if so and so.getSeats and veh then local t = {}; "
    .. "for _, s in ipairs(so.getSeats(%d) or {}) do if s.occupied and s.seatId then t[#t + 1] = string.format('%%q', s.seatId) end end; "
    .. "veh:queueLuaCommand('if lids and lids.setOccupiedSeats then lids.setOccupiedSeats({' .. table.concat(t, ',') .. '}) end') end",
    id, id))
end

local function seatLockOf(id)
  local sl = seatLocks[id]
  if sl ~= nil then return sl or nil end
  local cfg = LIDS[id]
  if not cfg or not cfg.lock then seatLocks[id] = false return nil end
  sl = {elec = cfg.lock, beams = {}, locked = true, lockTimer = 0}
  for _, h in pairs(v.data.hydros or {}) do
    if h.inputSource == cfg.lock and h.beamCID then
      local b = v.data.beams[h.beamCID]
      sl.beams[#sl.beams + 1] = {cid = h.beamCID, spring = b and b.beamSpring or 0, damp = b and b.beamDamp or 0}
    end
  end
  if #sl.beams == 0 then
    log('W', 'bug.lids', 'seat ' .. id .. ': no backrest hydro with input ' .. cfg.lock .. ', it stays rigid')
    seatLocks[id] = false
    return nil
  end
  seatLocks[id] = sl
  return sl
end

local function setSeatStiff(sl, stiff)
  for _, b in ipairs(sl.beams) do
    obj:setBeamSpringDamp(b.cid, stiff and b.spring or 0, stiff and b.damp or 0, -1, -1)
  end
end

local function seatLocked(id)
  local sl = seatLocks[id]
  return sl and sl.locked or false
end

-- every frame for a seat: true while it is locked (the lid physics is skipped then, the hydro holds it)
local function updateSeatLock(id, d, dt)
  local sl = seatLockOf(id)
  if not sl then return false end
  local e = electrics.values[sl.elec] or 0

  if occupiedSeats[d.cfg.seatId] then
    if not sl.locked then                     -- someone sat down: back to upright, then stiff
      log('D', 'bug.lids', 'seat ' .. id .. ' locked (occupied)')
      sl.locked, sl.lockTimer = true, SEAT_LOCK_DELAY
      if d.active then stopRay(d) end
      d.active, d.dragging, d.auto, d.pendingOpen = false, false, nil, nil
    end
    electrics.values[sl.elec] = 0
    sl.elecSeen = 0
    if sl.lockTimer > 0 then
      sl.lockTimer = sl.lockTimer - dt
      if sl.lockTimer <= 0 then setSeatStiff(sl, true) end
    end
    return true
  end

  if sl.locked then                           -- empty (again): slack hydro, free hinge
    log('D', 'bug.lids', 'seat ' .. id .. ' free (nobody on it)')
    sl.locked, sl.lockTimer, sl.elecSeen = false, 0, e
    setSeatStiff(sl, false)
  end
  local theta = geom(d)
  if not theta then return false end
  local folded = theta > d.cfg.springs.mid
  if e ~= sl.elecSeen then                    -- set from outside: fold / unfold
    sl.elecSeen = e
    if (e > 0) ~= folded and not d.active then startAuto(d, e > 0 and "open" or "close") end
  elseif not d.active and not d.auto then     -- settled: the input follows the backrest
    local want = folded and 1 or 0
    if want ~= e then electrics.values[sl.elec], sl.elecSeen = want, want end
  end
  return false
end

-- trigger press (value 1) / release (value 0) on the handle
local function press(id, value)
  local d = getLid(id)
  if not d or seatLocked(id) then return end
  if value and value > 0 then
    if d.active then return end
    d.active, d.dragging, d.pressTime, d.moved = true, false, 0, 0
    d.uTarget, d.prevO, d.prevD, d.lastU, d.targetOmega = nil, nil, nil, nil, 0
    d.thrown = false
    if not isLatched(d) and not isBroken(d) then startRay(d) end
  else
    if not d.active then return end
    local wasClick = not d.dragging and d.pressTime <= CLICK_MAX_TIME
    d.active, d.dragging = false, false
    stopRay(d)
    -- let go fast (either way): only the throw damper until it settles (frunk thrown shut: slams onto the latch)
    if d.cfg.springs and not isLatched(d) then
      local theta, R, t = geom(d)
      if theta then
        local vt = handleSpeed(d, t)
        if math.abs(vt) > d.cfg.springs.throw then d.thrown, d.settleTime = (vt > 0 and 1 or -1), 0 end
      end
    end
    if wasClick then
      if clock - d.lastClick <= DOUBLE_CLICK_TIME then
        d.lastClick = -1
        autoToggle(d)
      else
        d.lastClick = clock
        onClick(d)
      end
    end
  end
end

-- keyboard (engine lid: the "trunk" action): locked = turn the handle and open; open = close and lock;
-- shut but unlocked = lock
local function toggle(id)
  local d = getLid(id)
  if not d or seatLocked(id) then return end
  if isLatched(d) then
    if d.id == "frunk" then
      onClick(d)
    else
      startTurn(d)
    end
    d.pendingOpen = PENDING_OPEN_TIME
  elseif d.cfg.manualLock then
    local theta = geom(d)
    if not theta then return end
    if theta < math.rad(ENGINE_LOCK_MAX_DEG) then
      startLock(d)
    else
      startAuto(d, "close")
      d.lockAfterClose = true
    end
  else
    autoToggle(d)
  end
end

-- open automatically (getting out from a rear seat folds the front backrest forward), if it isn't open already
local function open(id)
  local d = getLid(id)
  if not d or seatLocked(id) or isLatched(d) or d.active then return end
  local theta = geom(d)
  if theta and theta < d.autoOpenRad then startAuto(d, "open") end
end

-- called every frame by the GE extension with the cursor ray while the handle is held
local function setRay(id, px, py, pz, dx, dy, dz)
  local d = lids[id]
  if not d or not d.active then return end
  local O, dir = vec3(px, py, pz), vec3(dx, dy, dz):normalized()
  local theta, R, _, axis, c, e1, e2 = geom(d)
  if not theta then return end
  if not d.uTarget then d.uTarget = theta end

  if d.prevO then
    -- hand: cursor motion on the plane through the target point, facing the camera
    local P = arcPoint(d, d.uTarget, c, e1, e2, R)
    local vw = (P - O):normalized()
    local function hit(o, dr)
      local dn = dr:dot(vw)
      if dn < 0.05 then return nil end
      return o + dr * ((P - o):dot(vw) / dn)
    end
    local h0, h1 = hit(d.prevO, d.prevD), hit(O, dir)
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
        -- screenFree (seats): the up / down motion moves it the way its (small) motion on screen goes (end on: up = open)
        if d.cfg.screenFree and s > 0.05 and cUp < 0 then duUp = -duUp end
      end
      -- weight of the screen direction (1 - w: up / down motion); lids: only where opening moves the handle up on
      -- screen, seats (screenFree): any direction, e.g. a backrest seen from the side folds sideways on screen
      local w = clamp((s - BLEND_LO) / (BLEND_HI - BLEND_LO), 0, 1) * (d.cfg.screenFree and 1 or clamp(cUp / UP_AGREE, 0, 1))
      local du = clamp(duScreen * w + duUp * (1 - w), -DU_MAX, DU_MAX)
      local u = clamp(d.uTarget + du, math.rad(-2), d.maxRad)
      u = clamp(u, theta - TARGET_LEAD, theta + TARGET_LEAD)
      d.moved = d.moved + math.abs(u - d.uTarget) * R
      d.uTarget = u
      if not d.dragging and d.moved > CLICK_MAX_MOVE then d.dragging = true end
    end
  end
  d.prevO, d.prevD = O, dir
end

local function dragLost(id)
  press(id, 0)
end

local function updateLid(d, dt)
  local latched = isLatched(d)
  updateHandle(d, dt, latched)

  if d.lockPending then
    d.lockPending = d.lockPending - dt
    if d.active or latched then
      d.lockPending = nil
    elseif d.lockPending <= 0 then
      d.lockPending = nil
      startLock(d)
    end
  end

  if d.pendingOpen then
    d.pendingOpen = d.pendingOpen - dt
    if d.pendingOpen <= 0 or d.active then
      d.pendingOpen = nil
    elseif not latched and not d.turning then
      d.pendingOpen = nil
      startAuto(d, "open")
    end
  end

  if d.active then
    d.pressTime = d.pressTime + dt
    if not d.dragging and d.pressTime > CLICK_MAX_TIME then d.dragging = true end
    -- the latch was released while the handle is held (frunk catch): start dragging now
    if not latched and not d.rayOn and not isBroken(d) then startRay(d) end
  end

  if latched or isBroken(d) then
    d.auto, d.thrown, d.lockAfterClose = nil, false, nil
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
      d.thrown = false   -- thrown shut: stopped or bounced off the buffers
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
    -- a lid that doesn't lock when shut (engine lid) stops at the buffers; the lock pushes until it latches
    -- (seats have no latch at all: stop at their closed stop)
    local shut = (d.cfg.manualLock or not d.cfg.couplers[1]) and not d.lockWait and theta < math.rad(1)
    if d.active or d.auto.time <= 0 or (d.auto.mode == "open" and theta >= d.autoOpenRad)
       or (d.auto.mode == "close" and shut) then
      if d.lockAfterClose and shut then startLock(d) end
      d.auto, d.lockAfterClose = nil, nil
    else
      local vTarget = d.auto.mode == "open" and AUTO_OPEN_SPEED or -(d.cfg.autoCloseSpeed or AUTO_CLOSE_SPEED)
      local fMax = d.cfg.autoMaxForce or AUTO_MAX_FORCE
      f = f + clamp((vTarget - vt) * (d.cfg.autoGain or AUTO_GAIN), -fMax, fMax)
    end
  end

  -- hand
  if d.active and d.dragging and d.uTarget then
    if d.lastU then
      local k = math.min(1, dt / TARGET_VEL_TAU)
      d.targetOmega = d.targetOmega + ((d.uTarget - d.lastU) / math.max(dt, 1e-3) - d.targetOmega) * k
    end
    d.lastU = d.uTarget
    local fh = (d.uTarget - theta) * R * (d.cfg.dragSpring or DRAG_SPRING) - (vt - d.targetOmega * R) * (d.cfg.dragDamp or DRAG_DAMP)
    local fMax = d.cfg.dragMaxForce or DRAG_MAX_FORCE
    fh = clamp(fh, -fMax, fMax)
    if d.cfg.slowCloseCap and theta * R < NEAR_CLOSED_GAP then fh = math.max(fh, -NEAR_CLOSED_MAX_CLOSE) end
    f = f + fh
  end

  if math.abs(f) > 0.01 then applyHandleForce(d, t * f, dt) end
end

local function updateGFX(dt)
  clock = clock + dt
  pollOccupiedSeats(dt)
  for id in pairs(LIDS) do
    local d = getLid(id)
    if d and not updateSeatLock(id, d, dt) then updateLid(d, dt) end
  end
end

local function onReset()
  for _, d in pairs(lids) do
    if d then stopRay(d) end
  end
  lids = {}
  seatLocks = {}   -- the reset restored the hydros' springs from the jbeam: stiff, like a new lock
end

local function isLid(id) return LIDS[id] ~= nil end

M.press     = press
M.setRay    = setRay
M.toggle    = toggle
M.open      = open
M.dragLost  = dragLost
M.isLid     = isLid
M.updateGFX = updateGFX
M.setOccupiedSeats = setOccupiedSeats   -- from GE (pollOccupiedSeats)
M.onReset   = onReset

return M
