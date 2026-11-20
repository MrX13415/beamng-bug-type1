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
-- The swinging itself (hinge springs, weight cancellation, dragging by hand with the cursor ray, double-click,
-- automatic open / close) is lib/hinge.lua; this file registers both lids there with their values and adds what
-- only the lids have through its hooks: the latches (couplers), the engine lid's turning handle and locking.
-- vehicle.lua exports press / toggle; the cursor ray goes to hinge.setRay directly.

local M = {}

local hinge = require("vehicles/bug/lua/lib/hinge")

local NEAR_CLOSED_GAP  = 0.035 -- m      frunk this close to shut (at the handle) ...
local NEAR_CLOSED_MAX_CLOSE = 40 -- N    ... the hand pushes it shut with at most this: it can't be pressed onto the
                                 --        latch slowly through the buffers, only slammed (momentum)
local PENDING_OPEN_TIME = 2.5  -- s      double-click on a latched lid: open it as soon as the latch is released

-- Hinge springs (over-center, see lib/hinge.lua). The physical gas struts of both lids are removed in the jbeams;
-- the net torque is set directly instead.
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
local ENGINE_LOCK_MAX_DEG = 4    -- deg    lid at most this open: a click on the handle locks it
local ENGINE_LOCK_WAIT   = 1.5   -- s      the coupler pulls the lid onto the latch; not latched by then: give up

-- Engine lid handle (prop anim__trunk: 0 = closed, 1 = open position, HANDLE_FULL_DEG)
local HANDLE_FULL_DEG    = 180   -- deg    prop rotation at 1 (trunk_handle, bug.body.trunk.jbeam)
local HANDLE_SLOW_DEG    = 15    -- deg    stiff part of the turn ...
local HANDLE_SLOW_TIME   = 0.35  -- s      ... takes this long
local HANDLE_SNAP_TIME   = 0.09  -- s      the rest snaps round (accelerating, the handle's spring)
local HANDLE_RETURN_TIME = 0.15  -- s      turning back when the lid latches
local HANDLE_LOCK_TIME   = 0.25  -- s      turning back to lock (click on the closed, unlocked lid)

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
  hinge.startAuto(d, "close")
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

-- hooks (lib/hinge.lua) --------------------------------------------------------------------------------------

local function onInit(d)
  d.handleValue, d.turning, d.turnTime = 0, false, 0
end

-- single click on the handle
local function onClick(d)
  if d.cfg.manualLock and not isLatched(d) then
    -- engine lid shut but unlocked: lock it, after the double-click time (a double-click opens it instead)
    local theta = hinge.geom(d)
    if theta and theta < math.rad(ENGINE_LOCK_MAX_DEG) and not d.turning then d.lockPending = hinge.DOUBLE_CLICK_TIME end
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

-- double-click: a latched lid opens as soon as the latch is released; otherwise the automatic open / close
local function onDoubleClick(d)
  d.lockPending = nil
  if d.locking or d.lockWait then
    -- double-click while locking: open instead
    d.locking = false
    if d.lockWait then d.lockWait = nil; lockFailed(d) end
  end
  if isLatched(d) or d.turning then
    if d.cfg.turnHandle then startTurn(d) end
    d.pendingOpen = PENDING_OPEN_TIME   -- open as soon as the latch is released (first click released it / turns the handle)
    return true
  end
  return false
end

-- every frame before the physics: the handle, a pending lock, a pending open
local function onUpdate(d, dt, latched)
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
      hinge.startAuto(d, "open")
    end
  end

  if latched or hinge.isBroken(d) then d.lockAfterClose = nil end
end

-- the automatic close is done: the engine lid (doesn't lock when shut) stops at the buffers, unless the lock
-- pushes it onto the latch; the frunk is pushed until it latches (or gives up)
local function closeStop(d, theta)
  return d.cfg.manualLock == true and not d.lockWait and theta < math.rad(1)
end

local function onAutoEnd(d, shut)
  if d.lockAfterClose and shut then startLock(d) end
  d.lockAfterClose = nil
end

local HOOKS = {init = onInit, held = isLatched, update = onUpdate, click = onClick, doubleClick = onDoubleClick,
               closeStop = closeStop, autoEnd = onAutoEnd}

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
    slowCloseCap = {gap = NEAR_CLOSED_GAP, maxClose = NEAR_CLOSED_MAX_CLOSE}, -- can't be pressed onto the latch slowly
    maxDeg = FRUNK_FULL_DEG + 3,
    autoOpenDeg = FRUNK_FULL_DEG * FRUNK_MID_FRACTION + 8, -- past the over-center point, the springs do the rest
    hooks = HOOKS,
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
    hooks = HOOKS,
  },
}
for id, cfg in pairs(LIDS) do hinge.register(id, cfg) end

-- keyboard (engine lid: the "trunk" action): locked = turn the handle and open; open = close and lock;
-- shut but unlocked = lock
local function toggle(id)
  local d = LIDS[id] and hinge.get(id)
  if not d then return end
  if isLatched(d) then
    if d.id == "frunk" then
      onClick(d)
    else
      startTurn(d)
    end
    d.pendingOpen = PENDING_OPEN_TIME
  elseif d.cfg.manualLock then
    local theta = hinge.geom(d)
    if not theta then return end
    if theta < math.rad(ENGINE_LOCK_MAX_DEG) then
      startLock(d)
    else
      hinge.startAuto(d, "close")
      d.lockAfterClose = true
    end
  elseif not onDoubleClick(d) then
    hinge.autoToggle(d)
  end
end

local function isLid(id) return LIDS[id] ~= nil end

M.press     = hinge.press
M.toggle    = toggle
M.isLid     = isLid

return M
