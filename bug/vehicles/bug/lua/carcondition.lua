-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Car condition model glue, vehicle side.
--
-- The car condition model (plain Lua in lua/common/bug/condition/, required as "bug/condition/...") holds every
-- condition of this car: engine, electrics, later rust, … and the personality of a car that has one. This file owns the car's model
-- instance and keeps no conditions of its own:
--   - created on first use (whoever needs it first: this file's hooks, the work mode, hrb.lua), loaded from the car's
--     record in the store (lib/storage.lua, section "condition"), then the wall-clock time the car stood since its
--     last save is simulated (each subsystem's offline(), scaled by the "standing-time simulation" setting, off at
--     realism 0) and written to the car's history as a "stood" event;
--   - saved with the record (the store calls the section provider);
--   - every frame: fills the inputs from the game (engine speed, throttle, oil and engine block temperature, ignition,
--     starter), runs
--     the model's fixed ticks, and hands the merged effects to bug/condition/effects, the only code that writes the
--     BeamNG engine;
--   - a vehicle reset (R) resets only the live state; the conditions stay;
--   - every frame, before the model: the carburettor's moving parts (lib/carburettor.lua update);
--   - other code changes a condition through the owning module (lib/carburettor.lua for the work mode, which calls
--     refreshEffects when the change must show at once) or reads / writes its subsystem's slice
--     (getModel():state(name), e.g. hrb.lua and "personality"), and calls storage.markDirty().
--   - a subsystem with REQUIRES_PART is only added when that part is installed, so other cars' records don't get
--     its slice. A slice saved earlier for a part that is removed now stays in the record (core keeps it).
--
-- UI concept for the "Service" tab: collects what the model will show and sends it to the GE extension bug_service,
-- which hands it to the pause-menu tab "Service" (ui/ui-vue/mods/bug_service):
--   - the settings from the Tuning category "Service" (jbeam section bugEngineModel);
--   - live values (battery: its charge is the model's, see controller/bug/battery.lua; oil pressure, temperatures,
--     odometers);
--   - the standing time applied on load, from the car's history;
--   - the model's diagnostics.

local M = {}

local misc = require("vehicles/bug/lua/misc")
local storage = require("vehicles/bug/lua/lib/storage")
local carburettor = require("vehicles/bug/lua/lib/carburettor")   -- the carburettor's moving parts (vehicle side)
local conditionCore = require("bug/condition/core")
local batteryModel = require("bug/condition/subsystems/battery")
local personalityModel = require("bug/condition/subsystems/personality")
local carburettorModel = require("bug/condition/subsystems/carburettor")
local idleModel = require("bug/condition/subsystems/idle")
local effects = require("bug/condition/effects")

local PUSH_INTERVAL = 1.0     -- s, snapshot to GE (the pause menu reads the last one, so a paused sim still shows data)

local cfg = {}
local pushTimer = PUSH_INTERVAL

local model = nil    -- this car's condition model (see getModel)
local base = nil     -- the engine's jbeam values the effects are relative to ({idleRPM}), read once
local RPM_TO_AV = math.pi / 30

local function readSettings()
  local d = v.data.bugEngineModel or {}
  local batteryJbeam = v.data.battery or {}
  cfg = {
    realism      = tonumber(d.realism) or 2,
    faultRate    = tonumber(d.faultRate) or 1,
    parkedSim    = tonumber(d.parkedSim) or 1,
    -- shown charge of a new car: the battery part's own start charge (per config, e.g. a rusted car starts low),
    -- else the Service setting
    startBattery = tonumber(batteryJbeam.charge) or tonumber(d.startBattery) or 1,
    -- the battery's size, for what a load left on drains while the car stands
    batteryCapacityAh = tonumber(batteryJbeam.capacity) or 0,
    batteryVoltage    = tonumber(batteryJbeam.voltage) or 12,
    startOilKm   = tonumber(d.startOilKm) or 0,
  }
  cfg.realism = math.floor(cfg.realism + 0.5)
end

local function envTemperatureC()
  local ok, k = pcall(function() return obj:getEnvTemperature() end)
  if ok and type(k) == "number" then return k - 273.15 end
  return nil
end

-- the standing time applied on load, from the car's history (nil for a new car)
local function parkedInfo()
  local ev = storage.lastEvent("stood")
  if not ev then return {} end
  local d = ev.data or {}
  return {
    lastSeen = ev.t - (d.seconds or 0),
    seconds  = d.seconds,
    preview  = {
      simulatedSeconds = d.simulatedSeconds,
      tempC            = d.tempC,
      chargeBefore     = d.chargeBefore,
      chargeAfter      = d.chargeAfter,
    },
  }
end

local function partOdometers()
  local result = { root = nil, parts = {} }
  pcall(function() result.root = partCondition.getRootPartOdometerValue() end)
  local ok, conds = pcall(partCondition.getConditions)
  if ok and type(conds) == "table" then
    for partId, c in pairs(conds) do
      local id = tostring(partId)
      if type(c) == "table" and (id:find("engine") or id:find("battery") or id:find("oil")) then
        table.insert(result.parts, { id = id, odometer = c.odometer })
      end
    end
    table.sort(result.parts, function(a, b) return a.id < b.id end)
  else
    result.note = "no part conditions (normal in freeroam)"
  end
  return result
end

local function snapshot()
  local e = electrics.values
  local bat = controller.getController("battery")
  local battery = nil
  if bat then
    battery = {
      charge   = bat.getChargeRatio and bat.getChargeRatio() or nil,
      voltage  = bat.getVoltage and bat.getVoltage() or nil,
      current  = bat.getCurrent and bat.getCurrent() or nil,
      charging = bat.isCharging and bat.isCharging() or false,
    }
  end

  return {
    vehicleId = obj:getId(),
    settings  = cfg,
    live = {
      ignitionLevel = e.ignitionLevel,
      rpm           = e.rpm,
      oilTempC      = e.oiltemp,
      engineTempC   = e.watertemp,
      oilPressure   = e.oilpressure,
      generatorLow  = e.generatorPower_low,
      odometerM     = e.odometer,
    },
    battery = battery,
    parked = parkedInfo(),
    odometers = partOdometers(),
    carId = storage.carId(),
    condition = model and model:diagnostics() or nil,
    wallClock = os.time(),
  }
end

local function push()
  local data = snapshot()
  obj:queueGameEngineLua("if bug_service then bug_service.onState(" .. serialize(data) .. ") end")
end

-- ---- live model ------------------------------------------------------------------------------------------------

local function engineDevice()
  local e = powertrain.getDevice("mainEngine")
  if e and e.type == "combustionEngine" then return e end
  return nil
end

-- subsystems in update order; a new one is added here (and to the tests)
local SUBSYSTEMS = { batteryModel, carburettorModel, idleModel, personalityModel }

local function hasPart(partName)
  for _, part in pairs(v.data.activePartsData or {}) do
    if part.partName == partName then return true end
  end
  return false
end

local function newModel()
  local m = conditionCore.new({ cfg = cfg, seed = os.time() })
  for _, sub in ipairs(SUBSYSTEMS) do
    if not sub.REQUIRES_PART or hasPart(sub.REQUIRES_PART) then m:add(sub) end
  end
  return m
end

-- Records saved during development on 2026-11-17 had the personality slice under its old name and on every car. A car
-- with the personality part gets it renamed, every other car loses it.
local OLD_PERSONALITY_SLICE = "herbie"
local function migrateCondition(cond)
  local subs = type(cond) == "table" and cond.subsystems
  if type(subs) ~= "table" or subs[OLD_PERSONALITY_SLICE] == nil then return cond end
  if subs.personality == nil and hasPart(personalityModel.REQUIRES_PART) then
    subs.personality = subs[OLD_PERSONALITY_SLICE]
  end
  subs[OLD_PERSONALITY_SLICE] = nil
  storage.markDirty()
  return cond
end

-- a new car with a personality takes its trust over from the old shared file (v1 kept one value for all Bugs)
local function takeOverLegacy(m)
  if not storage.isNew() or not m:state("personality") then return end
  local old = storage.legacyData()
  local trust = type(old) == "table" and type(old.herbie) == "table" and old.herbie.trust
  if type(trust) == "number" then
    local st = m:state("personality")
    st.trust = trust
    personalityModel.clampTrust(st)
  end
end

-- this car's model: created and loaded on first use, then the standing time is simulated
local function getModel()
  if model then return model end
  readSettings()
  model = newModel()
  model:load(migrateCondition(storage.section("condition")))
  takeOverLegacy(model)
  storage.addSection("condition", function() return model:save() end)

  local parked = storage.getParkedSeconds()
  if parked and parked > 0 then
    local simulated = parked * cfg.parkedSim * (cfg.realism > 0 and 1 or 0)
    local tempC = envTemperatureC() or 20
    local battery = model:state("battery")
    local chargeBefore = batteryModel.shownFromCharge(battery.charge)
    model:offline(simulated, { tempC = tempC })
    -- shown charge, like the battery's live value in the Service tab
    storage.event("stood", { seconds = parked, simulatedSeconds = simulated, tempC = tempC,
                             standbyLoadW = battery.standbyLoadW,
                             chargeBefore = chargeBefore, chargeAfter = batteryModel.shownFromCharge(battery.charge) })
  end
  model.fx = model:effects()
  return model
end

local function inputsFrom(engine)
  return {
    rpm        = (engine.outputAV1 or 0) / RPM_TO_AV,
    -- how far the throttle is open: the carburettor's lever (driver or a hand in the work mode), else the driver
    throttle   = electrics.values.carbThrottle or electrics.values.throttle or 0,
    oilTempC   = engine.thermals and engine.thermals.oilTemperature or nil,
    engineTempC = engine.thermals and engine.thermals.engineBlockTemperature or nil,
    ignitionOn = (engine.ignitionCoef or 0) > 0 and not engine.isDisabled,
    cranking   = (engine.starterEngagedCoef or 0) > 0,
  }
end

local function updateModel(dt)
  local engine = engineDevice()
  if not engine then return end
  local model = getModel()
  if not base then base = { idleRPM = engine.idleRPM } end
  model:update(dt, inputsFrom(engine))
  local fx = model.fx
  if fx.ignitionCut and (engine.ignitionCoef or 0) > 0 then
    local idle = model:state("idle")
    log('I', 'bug.carCondition', string.format('engine stalled at %.0f rpm (stall speed %.0f rpm, idle set to %.0f rpm)',
      idle.stalledAtRpm or 0, idle.limit or 0, effects.idleRpm(fx, base)))
  end
  effects.apply(fx, engine, base)
end

-- recomputes the effects from the conditions and applies them now, for a condition that changed between the model's
-- ticks and must show at once (lib/carburettor.lua turnIdleScrew: the idle speed follows the screw)
local function refreshEffects()
  local m = getModel()
  m.fx = m:effects()
  local engine = engineDevice()
  if engine and base then effects.apply(m.fx, engine, base) end
end

-- the idle speed the engine is set to now, rpm (nil before the engine is known)
local function idleTargetRpm()
  if not base then return nil end
  return effects.idleRpm(getModel():effects(), base)
end

local function onInit()
  getModel()
  misc.geCall("bug_service", "bug_service.register(" .. obj:getId() .. ")")  -- version check in misc.geCall
end

local function onReset()
  if model then model:reset() end   -- live state only: the screw stays where it was turned
end

local function updateGFX(dt)
  carburettor.update(dt, getModel())   -- its lever is the engine's throttle: before the model reads it
  updateModel(dt)

  pushTimer = pushTimer + dt
  if pushTimer >= PUSH_INTERVAL then
    pushTimer = 0
    push()
  end
end

M.onInit    = onInit
M.onReset   = onReset
M.updateGFX = updateGFX
M.push      = push

M.getModel      = getModel
M.idleTargetRpm = idleTargetRpm
M.refreshEffects = refreshEffects

return M
