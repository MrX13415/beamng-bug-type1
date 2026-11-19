-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Car condition subsystem: carburettor (Solex 28 PICT). Plain Lua, see bug/condition/core.lua.
--
-- Conditions (saved):
--   idleScrewTurns  turns of the idle speed (throttle stop) screw from the factory setting, + = screwed in. Set by
--                   the work mode (turnIdleScrew). More turns open the throttle a little at idle: higher idle speed.
--   idleJetClog     0 … 1, how far the idle jet is clogged (varnish from old fuel, dirt). Nothing changes it yet; it
--                   is here as the first wear condition of the carburettor. A clogged idle jet leans the idle
--                   mixture: the engine needs a higher speed to keep running.
--   chokeScrews     {top, left, right}: turns each screw of the choke cover's retaining ring is out from tight
--                   (0 = tight … CHOKE_SCREW_MAX). Set by the work mode (turnChokeScrew).
--   chokeCoverDeg   degrees the automatic choke's cover is turned from the factory mark, + = richer (the bimetal
--                   spring holds the choke flap shut up to a higher temperature). It only turns while the ring is
--                   loose (all three screws out at least CHOKE_SCREW_LOOSE turns, turnChokeCover).
--
-- Live state (not saved, cleared by a vehicle reset):
--   lever           0 … 1, how far the throttle lever (and so the throttle plate) is open. The engine gets this as
--                   its throttle, so the lever is what really opens the carburettor.
--   leverVel        1/s, its speed
--   leverAcc        s, time not yet simulated (the lever runs in fixed sub-steps, see stepLever)
--   hand            0 … 1 or nil: the opening a hand holds the lever at (work mode: dragging the lever), nil = let go
--   chokeTempC      °C, the choke's bimetal spring; nil until the first tick, which starts it at the engine's
--                   temperature
--   engineTempC     °C, the engine's temperature of the last tick (for the mixture it needs)
--   ringTime        s, clock of the loose retaining ring's rattle (stepRing)
--   ringShake       0 … 1, how hard the engine shakes it (1 = running)
--   ringKick        -1 … 1, the ring's twitch after the cover was turned (sign = the turn's direction), dies away
--
-- The lever: the accelerator cable and a hand can only pull it open. When they let go, the return spring pulls it
-- back against the idle stop: a spring with preload and some friction, and the lever bounces a little off the stop.
--
-- The automatic choke: a bimetal spring in the cover holds the choke flap shut when it is cold. An electric heater
-- (on with the ignition) and the engine warm it, and the flap opens (chokeClosure). The flap's linkage also sets
-- the stepped cam, which holds the throttle a little open: fast idle (FAST_IDLE_RPM at a shut flap). The engine
-- needs a richer mixture while it is cold (mixtureNeed, from the engine block's temperature, which warms faster than
-- the oil). A flap that opens too early
-- (cover turned lean) or stays shut too long (turned rich) makes the idle poor: the stall speed rises with the
-- difference beyond CHOKE_TOLERANCE. The real cam only drops onto its step when the throttle is blipped; here fast
-- idle follows the flap directly.
--
-- The retaining ring clamps the cover. Loosened screws let it go: at each screw it can lift off its seat up to the
-- screw head (ringPose), and with all three loose it drops by the play of its holes. It rests part way out (the
-- cover's gasket pushes it) and rattles while the engine runs. Turning the cover only twitches it a little, and it
-- settles back without swinging.

local effects = require("bug/condition/effects")

local M = {}

M.name = "carburettor"

M.IDLE_RPM_PER_TURN = 120      -- rpm per turn of the idle screw (one mouse wheel notch is 1/8 turn: 15 rpm)
M.IDLE_SCREW_MIN = -3.75       -- turns: screw fully out (450 rpm below the factory idle; the throttle is closed)
M.IDLE_SCREW_MAX = 4.5         -- turns: screw fully in (540 rpm above)
local CLOG_STALL_RPM = 300     -- rpm   added to the stall speed by a fully clogged idle jet

-- return spring and lever: opening'' = -OMEGA² · (opening + PRELOAD) - 2 · DAMPING · OMEGA · opening'
M.LEVER_OMEGA = 18             -- 1/s   stiffness of the return spring (full throttle to closed in about 0.08 s)
M.LEVER_PRELOAD = 0.3          --       the spring's tension at the stop, as an opening
M.LEVER_DAMPING = 0.25         --       friction of the shaft and the linkage, part of critical
M.LEVER_BOUNCE = 0.3           --       speed kept when the lever hits the idle stop
M.LEVER_BOUNCE_MIN = 0.5       -- 1/s   slower than this it stays on the stop
M.LEVER_STEP = 1 / 240         -- s     fixed sub-step

-- choke cover and its retaining ring
M.CHOKE_SCREWS = { "top", "left", "right" }
M.CHOKE_SCREW_MAX = 4          -- turns out from tight (they can't be taken out yet)
M.CHOKE_SCREW_PITCH = 0.0007   -- m per turn (M4)
M.CHOKE_SCREW_SNUG = 0.25      -- turns: up to this the screw still clamps the ring (no play)
M.CHOKE_SCREW_LOOSE = 0.5      -- turns: every screw out at least this far → the cover turns
M.CHOKE_COVER_MAX = 20         -- deg either way from the factory mark
M.RING_REST = 0.6              --       where the loose ring rests between its seat (0) and the screw heads (1)
M.RING_RATTLE = 0.35           --       its rattle either way while the engine runs, same scale
M.RING_HOLE_PLAY = 0.0003      -- m     it drops this far once all three screws are loose
M.RING_KICK = 0.08             --       a cover turn twitches the ring this far, same scale (dragged along a little)
M.RING_KICK_TIME = 0.12        -- s     time constant in which it settles back, without swinging

-- automatic choke
M.CHOKE_OPEN_C = 60            -- °C    bimetal temperature at which the flap is fully open (factory mark)
M.CHOKE_SPAN_C = 45            -- K     from shut to open (shut at 15 °C and below)
M.CHOKE_C_PER_DEG = 1.5        -- K     one degree of cover turn (richer) moves the opening temperature up this far
M.CHOKE_HEATER_C = 60          -- K     the heater warms the bimetal this far above the engine with the ignition on
M.CHOKE_HEAT_TAU = 150         -- s     time constant towards that with the ignition on (open after ~3 min at 20 °C)
M.CHOKE_COOL_TAU = 600         -- s     cooling towards the engine's temperature with the ignition off
M.FAST_IDLE_RPM = 400          -- rpm   added at a shut flap
M.MIXTURE_WARM_C = 50          -- °C    engine block temperature from which the engine needs no extra fuel
M.CHOKE_TOLERANCE = 0.25       --       difference between the flap and what the engine needs that it doesn't mind
M.CHOKE_LEAN_STALL = 500       -- rpm   added to the stall speed per unit of flap too far open (too lean)
M.CHOKE_RICH_STALL = 300       -- rpm   … per unit of flap too far shut (too rich)

local function clamp01(x) return math.max(0, math.min(1, x)) end
local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end

local function live(state)
  state.lever, state.leverVel, state.leverAcc, state.hand = 0, 0, 0, nil
  state.chokeTempC, state.engineTempC = nil, nil
  state.ringTime, state.ringKick, state.ringShake = 0, 0, 0
end

local function tightScrews() return { top = 0, left = 0, right = 0 } end

function M.defaults(cfg)
  local st = { idleScrewTurns = 0, idleJetClog = 0, chokeScrews = tightScrews(), chokeCoverDeg = 0 }
  live(st)
  return st
end

function M.load(saved, cfg)
  local st = M.defaults(cfg)
  if type(saved.idleScrewTurns) == "number" then
    st.idleScrewTurns = clamp(saved.idleScrewTurns, M.IDLE_SCREW_MIN, M.IDLE_SCREW_MAX)
  end
  if type(saved.idleJetClog) == "number" then st.idleJetClog = clamp01(saved.idleJetClog) end
  if type(saved.chokeScrews) == "table" then
    for _, id in ipairs(M.CHOKE_SCREWS) do
      local t = saved.chokeScrews[id]
      if type(t) == "number" then st.chokeScrews[id] = clamp(t, 0, M.CHOKE_SCREW_MAX) end
    end
  end
  if type(saved.chokeCoverDeg) == "number" then
    st.chokeCoverDeg = clamp(saved.chokeCoverDeg, -M.CHOKE_COVER_MAX, M.CHOKE_COVER_MAX)
  end
  return st
end

function M.save(state)
  local s = state.chokeScrews
  return { idleScrewTurns = state.idleScrewTurns, idleJetClog = state.idleJetClog,
           chokeScrews = { top = s.top, left = s.left, right = s.right }, chokeCoverDeg = state.chokeCoverDeg }
end

function M.reset(model, state) live(state) end

-- turns the idle screw by `turns` (+ = in); returns true if it moved
function M.turnIdleScrew(state, turns)
  local before = state.idleScrewTurns
  state.idleScrewTurns = math.max(M.IDLE_SCREW_MIN, math.min(M.IDLE_SCREW_MAX, before + turns))
  return state.idleScrewTurns ~= before
end

-- a hand holds the lever at `opening` (0 … 1); nil lets it go
function M.setHand(state, opening)
  state.hand = type(opening) == "number" and clamp01(opening) or nil
end

-- moves the lever for `dt` seconds; cable = how far the accelerator cable pulls it (the driver's throttle, 0 … 1).
-- Returns the opening. Called every frame by the glue; runs in fixed sub-steps, so the motion doesn't depend on the
-- frame rate.
function M.stepLever(state, dt, cable)
  local pull = math.max(clamp01(cable or 0), state.hand or 0)
  if pull > state.lever or (pull == state.lever and state.leverVel <= 0) then
    -- pulled open (the cable doesn't stretch): the lever follows at once. Resting on the stop counts too, but
    -- not a lever bouncing up off it.
    state.leverVel = 0
    state.lever = pull
    state.leverAcc = 0
    return state.lever
  end
  local h = M.LEVER_STEP
  local w = M.LEVER_OMEGA
  state.leverAcc = math.min((state.leverAcc or 0) + (dt or 0), 0.25)
  while state.leverAcc >= h do
    state.leverAcc = state.leverAcc - h
    local a = -w * w * (state.lever + M.LEVER_PRELOAD) - 2 * M.LEVER_DAMPING * w * state.leverVel
    state.leverVel = state.leverVel + a * h
    state.lever = state.lever + state.leverVel * h
    if state.lever <= pull then
      if pull <= 0 and state.leverVel < -M.LEVER_BOUNCE_MIN then
        state.lever = 0                                  -- off the idle stop
        state.leverVel = -state.leverVel * M.LEVER_BOUNCE
      else
        state.lever = pull                               -- on the stop, or caught by the cable / hand
        state.leverVel = 0
        state.leverAcc = 0
        break
      end
    end
  end
  return state.lever
end

-- ---- choke cover and retaining ring ----------------------------------------------------------------------------

-- turns a screw of the retaining ring by `turns` (+ = out, looser); returns true if it moved
function M.turnChokeScrew(state, id, turns)
  local s = state.chokeScrews
  if s[id] == nil then return false end
  local before = s[id]
  s[id] = clamp(before + turns, 0, M.CHOKE_SCREW_MAX)
  return s[id] ~= before
end

-- the ring no longer clamps the cover: every screw is out far enough
function M.coverLoose(state)
  for _, id in ipairs(M.CHOKE_SCREWS) do
    if state.chokeScrews[id] < M.CHOKE_SCREW_LOOSE then return false end
  end
  return true
end

-- turns the choke cover by `deg` (+ = richer) if the ring lets it; returns true if it moved
function M.turnChokeCover(state, deg)
  if not M.coverLoose(state) then return false end
  local before = state.chokeCoverDeg
  state.chokeCoverDeg = clamp(before + deg, -M.CHOKE_COVER_MAX, M.CHOKE_COVER_MAX)
  if state.chokeCoverDeg == before then return false end
  state.ringKick = deg > 0 and 1 or -1   -- the cover drags the loose ring along a little: it twitches
  return true
end

-- how far a screw lets the ring lift at its place, m (0 while it still clamps)
function M.screwPlay(state, id)
  return math.max(0, (state.chokeScrews[id] or 0) - M.CHOKE_SCREW_SNUG) * M.CHOKE_SCREW_PITCH
end

-- moves the loose ring's rattle on: dt in s, shake 0 … 1 (1 = the engine runs). Called every frame by the glue.
function M.stepRing(state, dt, shake)
  state.ringTime = ((state.ringTime or 0) + (dt or 0)) % 1000
  state.ringKick = (state.ringKick or 0) * math.exp(-(dt or 0) / M.RING_KICK_TIME)
  state.ringShake = clamp01(shake or 0)
end

-- the ring's pose now: lift off its seat at each screw (m, outward along the choke's axis) and how far it has
-- dropped (m, down within its holes)
local RATTLE_HZ = { top = { 9.1, 13.7 }, left = { 7.3, 11.9 }, right = { 8.2, 15.3 } }
function M.ringPose(state)
  local t = state.ringTime or 0
  local amp = M.RING_RATTLE * (state.ringShake or 0)
  local kick = M.RING_KICK * (state.ringKick or 0)
  local lift, minPlay = {}, math.huge
  for i, id in ipairs(M.CHOKE_SCREWS) do
    local play = M.screwPlay(state, id)
    local f = RATTLE_HZ[id]
    local wobble = 0.6 * math.sin(2 * math.pi * f[1] * t + i) + 0.4 * math.sin(2 * math.pi * f[2] * t + 2 * i)
    -- the twitch tips the ring: out at the top screw, in at the other two (or the other way round)
    local twitch = kick * (id == "top" and 1 or -0.5)
    lift[id] = play * clamp01(M.RING_REST + amp * wobble + twitch)
    minPlay = math.min(minPlay, play)
  end
  local drop = M.RING_HOLE_PLAY * clamp01(minPlay / M.RING_HOLE_PLAY)
  return lift, drop
end

-- ---- automatic choke -------------------------------------------------------------------------------------------

-- 0 = flap open … 1 = shut, from the bimetal's temperature and the cover's turn
function M.chokeClosure(state)
  if not state.chokeTempC then return 0 end
  local openC = M.CHOKE_OPEN_C + (state.chokeCoverDeg or 0) * M.CHOKE_C_PER_DEG
  return clamp01((openC - state.chokeTempC) / M.CHOKE_SPAN_C)
end

-- 0 … 1, how much extra fuel the engine needs at this engine temperature (1 at 0 °C)
function M.mixtureNeed(engineTempC)
  if not engineTempC then return 0 end
  return clamp01((M.MIXTURE_WARM_C - engineTempC) / M.MIXTURE_WARM_C)
end

-- inputs: engineTempC (engine block; the oil temperature if the glue has none), ignitionOn
function M.update(model, state, dt, inputs)
  local engine = inputs.engineTempC or inputs.oilTempC
  state.engineTempC = engine
  if not engine then return end
  if not state.chokeTempC then state.chokeTempC = engine end   -- the car stood: the choke is as warm as the engine
  local target, tau = engine, M.CHOKE_COOL_TAU
  if inputs.ignitionOn then target, tau = engine + M.CHOKE_HEATER_C, M.CHOKE_HEAT_TAU end
  state.chokeTempC = state.chokeTempC + (target - state.chokeTempC) * math.min(1, dt / tau)
end

function M.effects(model, state, out)
  effects.add(out, "idleRpmAdd", state.idleScrewTurns * M.IDLE_RPM_PER_TURN)
  effects.add(out, "stallRpmAdd", state.idleJetClog * CLOG_STALL_RPM)
  local closure = M.chokeClosure(state)
  effects.add(out, "idleRpmAdd", closure * M.FAST_IDLE_RPM)
  if state.engineTempC then
    local diff = closure - M.mixtureNeed(state.engineTempC)
    local lean = math.max(0, -diff - M.CHOKE_TOLERANCE)
    local rich = math.max(0, diff - M.CHOKE_TOLERANCE)
    effects.add(out, "stallRpmAdd", lean * M.CHOKE_LEAN_STALL + rich * M.CHOKE_RICH_STALL)
  end
end

function M.diagnostics(state)
  return { idleScrewTurns = state.idleScrewTurns, idleJetClog = state.idleJetClog, lever = state.lever,
           chokeScrews = state.chokeScrews, chokeCoverDeg = state.chokeCoverDeg, chokeTempC = state.chokeTempC,
           choke = M.chokeClosure(state) }
end

return M
