-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Car condition model core.
--
-- Plain Lua on purpose. It lives in lua/common/ (not in vehicles/bug/lua/, where the game would load every file
-- as a vehicle extension and call its hooks itself). It is loaded with require("bug/condition/core") from the vehicle
-- side, from the GE side, and from plain LuaJIT outside the game (build/lua/condition_test.lua). So:
--   - no game calls in here (no obj, v, electrics, log, os.time): the glue code passes everything in;
--   - one model instance per car (the GE side may hold several);
--   - the model runs at a fixed tick, never at the frame rate, so the same inputs give the same result anywhere;
--   - every random draw comes from a named, seeded stream (model:random(name)), never from math.random.
--
-- State lives in the model, never in a subsystem module. A subsystem is a set of functions that read its slice of
-- the state (model:state(name)), simulate, and write the result back into that slice. So every condition of the car
-- (a screw's position, a battery's charge, a stall timer) is in one place: it can be saved, shown, edited by a job in
-- the work mode, and later replayed. Other code (glue, work mode, UI) changes a condition through the owning
-- subsystem's functions, passing the slice in.
--
-- Subsystem contract (all functions optional):
--   name                                   unique key, also the key of its slice in the save
--   REQUIRES_PART                          the glue adds the subsystem only if this jbeam part is installed
--   defaults(cfg)            -> state      state of a new car, from the settings / jbeam config
--   load(saved, cfg)         -> state      state from a save (default: saved as is, missing keys from defaults)
--   save(state)              -> table|nil  what goes into the save (default: state as is; nil: nothing, live only)
--   reset(model, state)                    vehicle reset (R): reset the live part of the state, keep the conditions
--   offline(model, state, seconds, env)    the time the car stood, in closed form or with large steps
--   update(model, state, dt, inputs)       one fixed tick of live simulation. model.fx holds the merged effects of
--                                          the previous tick (so a subsystem can react to the others' conditions)
--   effects(model, state, out)             adds modifiers to the effect table with effects.add (bug/condition/effects)
--   diagnostics(state)       -> table      values for the Service tab / debug view

local effects = require("bug/condition/effects")

local M = {}

M.TICK = 0.1           -- s, fixed model step (10 Hz)
M.MAX_TICKS = 50       -- per update call, so a long frame (loading, pause) can't stall the game

-- ---- random streams -------------------------------------------------------------------------------------------
-- Park–Miller minimal standard generator. Exact in double precision (16807 · 2^31 < 2^53), so it gives the same
-- numbers in LuaJIT and in plain Lua 5.1 on any machine, so a run can be replayed and checked.

local MODULUS = 2147483647

local function hashString(s)
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) % MODULUS end
  return h
end

local function newStream(seed, name)
  local x = (math.floor(seed) % MODULUS + hashString(name)) % MODULUS
  if x <= 0 then x = x + MODULUS - 1 end
  return function()
    x = (x * 16807) % MODULUS
    return x / MODULUS   -- (0, 1)
  end
end

-- ---- model ----------------------------------------------------------------------------------------------------

local Model = {}
Model.__index = Model

-- opts.seed: number. For now the glue seeds from the clock.
-- opts.cfg: settings (realism, faultRate, parkedSim, start state …)
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    cfg = opts.cfg or {},
    seed = opts.seed or 1,
    subsystems = {},     -- in registration order; offline() and update() run in this order
    states = {},         -- name → state
    otherSlices = {},    -- saved slices of subsystems this model doesn't have (e.g. a part removed for now): kept
    streams = {},        -- name → generator
    accumulator = 0,
    ticks = 0,           -- fixed ticks run since creation (sim time = ticks · TICK)
    fx = {},             -- merged effects of the last tick (see update)
  }, Model)
end

function Model:random(streamName)
  local s = self.streams[streamName]
  if not s then
    s = newStream(self.seed, streamName)
    self.streams[streamName] = s
  end
  return s()
end

function Model:add(subsystem)
  assert(type(subsystem) == "table" and subsystem.name, "subsystem needs a name")
  assert(not self.states[subsystem.name], "subsystem added twice: " .. subsystem.name)
  table.insert(self.subsystems, subsystem)
  self.states[subsystem.name] = subsystem.defaults and subsystem.defaults(self.cfg) or {}
  return self
end

function Model:state(name)
  return self.states[name]
end

-- saved: { version, subsystems = { name → slice } }
function Model:load(saved)
  local slices = type(saved) == "table" and type(saved.subsystems) == "table" and saved.subsystems or {}
  self.otherSlices = {}
  for name, slice in pairs(slices) do
    if not self.states[name] then self.otherSlices[name] = slice end
  end
  for _, sub in ipairs(self.subsystems) do
    local slice = slices[sub.name]
    if slice ~= nil then
      if sub.load then
        self.states[sub.name] = sub.load(slice, self.cfg)
      else
        local st = sub.defaults and sub.defaults(self.cfg) or {}
        for k, v in pairs(slice) do st[k] = v end
        self.states[sub.name] = st
      end
    end
  end
end

function Model:save()
  local out = { version = 1, subsystems = {} }
  for name, slice in pairs(self.otherSlices) do out.subsystems[name] = slice end
  for _, sub in ipairs(self.subsystems) do
    local st = self.states[sub.name]
    if sub.save then
      out.subsystems[sub.name] = sub.save(st)  -- nil: live-only subsystem, nothing saved
    else
      out.subsystems[sub.name] = st
    end
  end
  return out
end

-- vehicle reset (R): live state back to its start, conditions kept
function Model:reset()
  self.accumulator = 0
  for _, sub in ipairs(self.subsystems) do
    if sub.reset then sub.reset(self, self.states[sub.name]) end
  end
  self.fx = self:effects()
end

-- the time the car stood; env: { tempC = … }
function Model:offline(seconds, env)
  if not seconds or seconds <= 0 then return end
  for _, sub in ipairs(self.subsystems) do
    if sub.offline then sub.offline(self, self.states[sub.name], seconds, env or {}) end
  end
end

-- live: called with the frame dt; runs as many fixed ticks as fit. inputs: table filled by the glue code.
function Model:update(dt, inputs)
  self.accumulator = self.accumulator + dt
  local n = 0
  while self.accumulator >= M.TICK and n < M.MAX_TICKS do
    self.accumulator = self.accumulator - M.TICK
    n = n + 1
    self.ticks = self.ticks + 1
    self.fx = self:effects()
    for _, sub in ipairs(self.subsystems) do
      if sub.update then sub.update(self, self.states[sub.name], M.TICK, inputs or {}) end
    end
  end
  if n == M.MAX_TICKS then self.accumulator = 0 end  -- drop the backlog instead of catching up forever
  if n > 0 then self.fx = self:effects() end           -- what the glue applies now
  return n
end

-- merged effect table of the current state (keys and merge rules: bug/condition/effects.lua)
function Model:effects()
  local out = {}
  for _, sub in ipairs(self.subsystems) do
    if sub.effects then sub.effects(self, self.states[sub.name], out) end
  end
  return out
end

function Model:diagnostics()
  local out = {}
  for _, sub in ipairs(self.subsystems) do
    out[sub.name] = sub.diagnostics and sub.diagnostics(self.states[sub.name]) or self.states[sub.name]
  end
  return out
end

M.hashString = hashString  -- exposed for tests

return M
