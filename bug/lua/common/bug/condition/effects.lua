-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Car condition effects. Plain Lua, see bug/condition/core.lua.
--
-- Effects are recomputed from the state on every tick and never saved. Several subsystems may touch the same key;
-- add() merges them by the key's rule. apply() is the only place that writes the BeamNG engine: the glue passes the
-- combustion engine device in. A new effect = one line in KEYS and, if it drives the engine, a few lines in apply().

local M = {}

-- key → merge rule ("add": sum, "mul": product, "max": largest, "or": any true)
local KEYS = {
  idleRpmAdd  = "add",  -- rpm   added to the engine's jbeam idle speed (idle screw, choke / fast-idle cam)
  stallRpmAdd = "add",  -- rpm   added to the lowest speed the engine keeps running at (rough mixture, wear, …)
  ignitionCut = "or",   -- bool  the engine dies now (a stall); the key stays on and the starter restarts it
}
M.KEYS = KEYS

local IDLE_RPM_FLOOR = 100  -- rpm, the idle speed handed to BeamNG never goes below this

function M.add(out, key, value)
  local rule = KEYS[key]
  assert(rule, "unknown engine model effect: " .. tostring(key))
  local cur = out[key]
  if cur == nil then
    out[key] = value
  elseif rule == "add" then
    out[key] = cur + value
  elseif rule == "mul" then
    out[key] = cur * value
  elseif rule == "max" then
    out[key] = math.max(cur, value)
  elseif rule == "or" then
    out[key] = cur or value
  end
end

-- the engine's idle speed from the base (jbeam) idle speed and the effects, rpm
function M.idleRpm(fx, base)
  return math.max(IDLE_RPM_FLOOR, (base.idleRPM or 0) + (fx.idleRpmAdd or 0))
end

-- writes the effects into the BeamNG combustion engine device. base: values the engine had from jbeam
-- ({idleRPM = …}), read by the glue once at spawn so the effects stay relative to them.
function M.apply(fx, engine, base)
  if not engine or not base then return end
  engine.idleAV = M.idleRpm(fx, base) * math.pi / 30   -- BeamNG reads it every frame
  if fx.ignitionCut and (engine.ignitionCoef or 0) > 0 and engine.setIgnition then
    engine:setIgnition(0)
  end
end

return M
