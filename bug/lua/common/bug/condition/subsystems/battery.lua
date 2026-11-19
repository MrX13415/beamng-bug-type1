-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Car condition subsystem: battery. Plain Lua, see bug/condition/core.lua.
--
-- State:
--   charge        stored charge / capacity (0 … 1, linear in Ah). It is the battery's only charge: the battery
--                 controller (vehicles/bug/lua/controller/bug/battery.lua) reads and writes this field every frame
--                 while the car is driven, the standing time drains it here (offline), and it is saved with the car.
--   standbyLoadW  what the car draws when it is left as it is now (lights, ignition, radio … left on; 0 while the
--                 engine runs, since a running engine means the driver is still there). Written by the controller,
--                 saved, and drained during the standing time, so a car left with its lights on is flat later.
--                 Smoothed over a few seconds, so a blinking turn signal counts as its average.
--   standbyLoadNotedW  live only: the standby load when a save was last asked for (see setStandbyLoad)
--
-- The standing time needs the battery's size: cfg.batteryCapacityAh and cfg.batteryVoltage (from the battery part).
--
-- The charge shown to the player ("shown", the jbeam start value, the Service tab) is a log curve of the stored
-- charge, so a battery reads empty well before its last Ah is gone. shownFromCharge / chargeFromShown convert.

local M = {}

M.name = "battery"

-- lead-acid self-discharge: ~3 % per month at 20 °C, doubling every 10 K (common rule of thumb)
local SELF_DISCHARGE_20C = 0.03 / (30 * 86400)  -- 1/s
local DOUBLING_K = 10                            -- K

local function clamp01(x) return math.max(0, math.min(1, x)) end

-- shown charge (0 … 1) → stored charge (0 … 1)
function M.chargeFromShown(shown)
  return clamp01(math.log10(clamp01(shown) * 0.9 + 0.1) + 1)
end

-- stored charge (0 … 1) → shown charge (0 … 1)
function M.shownFromCharge(charge)
  return clamp01((10 ^ (clamp01(charge) - 1) - 0.1) / 0.9)
end

-- self-discharge rate at a temperature, 1/s
function M.selfDischargeRate(tempC)
  return SELF_DISCHARGE_20C * 2 ^ (((tempC or 20) - 20) / DOUBLING_K)
end

-- cfg.startBattery: shown charge of a new car
function M.defaults(cfg)
  return { charge = M.chargeFromShown(cfg.startBattery or 1), standbyLoadW = 0 }
end

function M.load(saved, cfg)
  local st = M.defaults(cfg)
  if type(saved.charge) == "number" then st.charge = clamp01(saved.charge) end
  if type(saved.standbyLoadW) == "number" then st.standbyLoadW = math.max(0, saved.standbyLoadW) end
  return st
end

-- a load in W as a fraction of the capacity per second (0 without a known battery size)
function M.loadRate(cfg, watts)
  local ah, volts = cfg.batteryCapacityAh or 0, cfg.batteryVoltage or 12
  if ah <= 0 or volts <= 0 or not watts or watts <= 0 then return 0 end
  return watts / (volts * ah * 3600)
end

-- dQ/dt = −k(T)·Q − a  (self-discharge k, load a), closed form:
--   Q(t) = (Q0 + a/k) · exp(−k·t) − a/k, and 0 once it is empty
function M.offline(model, state, seconds, env)
  local k = M.selfDischargeRate(env.tempC)
  local a = M.loadRate(model.cfg, state.standbyLoadW)
  state.charge = clamp01((state.charge + a / k) * math.exp(-k * seconds) - a / k)
end

local STANDBY_SMOOTHING = 3     -- s
local STANDBY_SAVE_STEP = 5     -- W, a change this large is worth a save

-- the controller's current load if the car was left now, W, once per frame; returns true when the smoothed value
-- moved far enough since the last time to be saved
function M.setStandbyLoad(state, watts, dt)
  watts = math.max(0, watts or 0)
  local cur = state.standbyLoadW or 0
  state.standbyLoadW = cur + (watts - cur) * math.min(1, (dt or 0) / STANDBY_SMOOTHING)
  if watts == 0 and state.standbyLoadW < 0.05 then state.standbyLoadW = 0 end
  if math.abs(state.standbyLoadW - (state.standbyLoadNotedW or 0)) > STANDBY_SAVE_STEP then
    state.standbyLoadNotedW = state.standbyLoadW
    return true
  end
  return false
end

function M.save(state)
  return { charge = state.charge, standbyLoadW = state.standbyLoadW }
end

-- stored charge, clamped (the battery controller and repair jobs write through this)
function M.setCharge(state, charge)
  if type(charge) == "number" then state.charge = clamp01(charge) end
end

function M.diagnostics(state)
  return { charge = state.charge, shown = M.shownFromCharge(state.charge), standbyLoadW = state.standbyLoadW }
end

return M
