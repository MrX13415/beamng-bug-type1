-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Car condition subsystem: idle stability and stalling. Plain Lua, see bug/condition/core.lua.
--
-- BeamNG's engine never stalls from a low idle: its idle controller holds whatever idle speed is set. Here the engine
-- dies when its real speed, smoothed, stays below the stall speed for STALL_TIME while the driver gives no throttle.
--
-- Stall speed = STALL_RPM, plus a cold term (oil temperature), plus the effect
-- stallRpmAdd that other subsystems add from their conditions (e.g. a clogged idle jet). New causes of a poor idle
-- only add to stallRpmAdd; this file doesn't change.
--
-- The engine's own condition also comes in through the real speed it reaches: more friction (BeamNG wear, damage)
-- makes the idle controller fall short of the set idle speed, and a rough idle (idleRPMRoughness) makes it sag.
--
-- Live state only (not saved, reset on a vehicle reset):
--   smoothRpm   rpm, low-passed engine speed
--   belowTime   s, how long the smoothed speed has been below the stall speed
--   running     the engine turned on its own (starter off, above RUNNING_RPM) since the ignition came on; only a
--               running engine stalls, not one with the key on that was never started
--   stallNow    a stall happened this tick: effect ignitionCut until the ignition is off
--
-- Inputs (filled by the glue): rpm, throttle (driver, 0 … 1), oilTempC, ignitionOn, cranking.

local effects = require("bug/condition/effects")

local M = {}

M.name = "idle"

M.STALL_RPM = 480              -- rpm   warm engine
M.STALL_COLD_EXTRA = 200       -- rpm   added at an oil temperature of 0 °C, none from 60 °C up
M.STALL_TIME = 0.6             -- s
M.STALL_THROTTLE = 0.05        --       driver throttle above this: no stall
M.SMOOTHING = 0.3              -- s     time constant of the speed filter
M.RUNNING_RPM = 200            -- rpm   above this (starter off) the engine turns on its own: it counts as running

local function fresh()
  return { smoothRpm = nil, belowTime = 0, running = false, stallNow = false }
end

function M.defaults(cfg) return fresh() end
function M.load(saved, cfg) return fresh() end
function M.save(state) return nil end

function M.reset(model, state)
  local f = fresh()
  for k in pairs(state) do state[k] = nil end
  for k, v in pairs(f) do state[k] = v end
end

-- the speed below which the engine dies, rpm
function M.stallRpm(fx, oilTempC)
  local cold = 0
  if oilTempC then cold = M.STALL_COLD_EXTRA * math.max(0, math.min(1, (60 - oilTempC) / 60)) end
  return M.STALL_RPM + cold + (fx and fx.stallRpmAdd or 0)
end

function M.update(model, state, dt, inputs)
  if state.stallNow and not inputs.ignitionOn then state.stallNow = false end
  if not inputs.ignitionOn or inputs.cranking or not inputs.rpm then
    state.smoothRpm, state.belowTime = nil, 0
    if not inputs.ignitionOn then state.running = false end
    return
  end

  local rpm = math.abs(inputs.rpm)
  state.smoothRpm = state.smoothRpm and (state.smoothRpm + (rpm - state.smoothRpm) * math.min(1, dt / M.SMOOTHING)) or rpm
  local limit = M.stallRpm(model.fx, inputs.oilTempC)
  state.limit = limit  -- for diagnostics

  if state.smoothRpm > M.RUNNING_RPM then state.running = true end
  if not state.running or (inputs.throttle or 0) > M.STALL_THROTTLE or state.smoothRpm >= limit then
    state.belowTime = 0
    return
  end
  state.belowTime = state.belowTime + dt
  if state.belowTime >= M.STALL_TIME then
    state.stallNow = true
    state.running = false
    state.belowTime = 0
    state.stalledAtRpm = state.smoothRpm
  end
end

function M.effects(model, state, out)
  if state.stallNow then effects.add(out, "ignitionCut", true) end
end

function M.diagnostics(state)
  return { rpm = state.smoothRpm, stallRpm = state.limit, running = state.running }
end

return M
