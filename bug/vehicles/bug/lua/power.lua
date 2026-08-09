-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Library to simulate a power system, allowing parts to draw power.
-- v1.0
-- by MrX13415

local M = {}

local misc = require("vehicles/bug/lua/misc")

local updateTimer = 2     -- Make sure the first call is immediately
local ammeterSmoother = newExponentialSmoothing(50)
local voltmeterSmoother = newExponentialSmoothing(50)

local battery = nil
local canPower = false

local enginePower = 0           -- W  | Power required for the ignition system, spark plugs etc.
local engineBasePower = 0.5     -- W  | Base power to account for LEDs and the whole electric system.
local engineIdleRPM = 0
local starterPower = 0

local powerParts = {}
--local powerValues = {}
--local ignoreIgnition = {}

local toUnit = misc.toUnit
local toTime = misc.toTime
local executeLua = misc.executeLua

local function isEngineRunning() return electrics.values.rpm > engineIdleRPM end
local function isPowerOn() return electrics.values.ignitionLevel > 0 end
local function isIgnitionOn() return electrics.values.ignitionLevel > 1 end

-- local function calculateBatteryEstimate(chargeCurrent, batteryRate)
--   local capacity = batteryCapacity
--   if chargeCurrent > 0 then
--     capacity = batteryMaxCapacity - capacity
--     return capacity / math.abs(batteryRate) * 60
--   end

--   local estimated = batteryC * math.pow((capacity)/(math.abs(chargeCurrent) * batteryC), batteryK) * 60
--   local trueEst = capacity / math.abs(batteryRate) * 60
--   return math.min(estimated, trueEst)
-- end

local function calculatePower(p)
  -- Determine if this device is active
  if p.trigger then
    local state = executeLua(p.trigger)
    if type(state) == "number" then state = state > 0 end
    if not state then return 0 end
  end

  local power = p.power
  -- Apply ratio function if any
  if p.ratio then
    power = executeLua(p.ratio)
  end

  return power
end

local function calculateTotalPower()
  local total = 0

  if battery then battery.clearPower() end
  
  --log("D", "", "[Bug:Power] " .. tostring(#powerParts) .. " items")
  for _,part in pairs(powerParts) do
    local power = calculatePower(part)

    --log("D", "", "[Bug:Power]   " .. item.partPath .. ": "  .. tostring(round(power)) .. "W")
    if battery then battery.addPower(part.partPath, power) end
    total = total + power
  end

  local power = 0
  if isPowerOn() then power = power + engineBasePower end
  if isIgnitionOn() then power = power + enginePower end
  --log("D", "", "[Bug:Power]   Engine: "  .. tostring(round(power)) .. "W")
  if battery then battery.setPower("engine", power) end
  total = total + power
 
  return total
end

local function smoothValues()
  electrics.values.ammeter = ammeterSmoother:get(electrics.values.ampere)
  electrics.values.voltmeter = voltmeterSmoother:get(electrics.values.voltage)
end

-- See updateElectricsWithIgnitionLevelEuropean() in Game lua.
-- These system is no longer needed, as of 0.34
--local function updateElectrics()
--  local values = electrics.values
--  local noPower = not canPower
--  
--  for pwr, value in pairs(powerValues) do
--    local v = values[value]
--
--    local wired = isPowerOn()
--    for _, ignore in pairs(ignoreIgnition) do
--      if value == ignore then
--        wired = true
--        break
--      end
--    end
--
--    if noPower or not wired then
--      if type(v) == "number" then v = 0
--      elseif type(v) == "boolean" then v = false
--      end
--    end
--    values[pwr] = v
--    --print(tostring(canPower) .. " | "..pwr.."="..value.." ("..tostring(values[pwr]).."="..tostring(values[value])..")")
--  end
--
--  if noPower then
--    electrics.set_warn_signal(false)
--  end
--
--  if noPower or isPowerOn() == false then
--    electrics.set_lightbar_signal(0)
--  end
--end


local function onBattery(battery)
  local powerRatio = battery.getPowerRatio()
  local powerOn = (electrics.values.ignitionLevel > 0) and 1 or 0
  canPower = powerRatio >= 0.95
  
  electrics.values.powerRatio = powerRatio
  electrics.values.powerAvailable = canPower and 1 or 0
  electrics.values.powerOn = electrics.values.powerAvailable * powerOn
  electrics.values.powerOnRatio = powerOn * powerRatio

  -- obsolete as of 0.34
  --updateElectrics()
end


local function update()
  if not battery then return end

  local totalPower = calculateTotalPower() -- W
  local generatorPower = engine and engine.getPowerGenerator() or 0  -- W
  battery.setPowerGenerator(generatorPower)

  local batteryCharge = battery.getCharge()
  local estimated = battery.getEstimatedTime()

  --log("D", "", "[Bug:Power] Power: " .. tostring(toUnit(totalPower, "W")))
  --log("D", "", "[Bug:Power] Battery: " .. tostring(toUnit(batteryCharge / 1000, "Ah", 1000)))
  --log("D", "", "[Bug:Power]   Remaining: " .. tostring(toTime(estimated)))
end

local function updateGFX(dt)
  updateTimer = updateTimer + dt
	-- update rate: 4 fps (0.25 == 250ms)
	if updateTimer > 0.25 then
    update()
    updateTimer = 0
  end
  smoothValues()
end

local function _replaceCmd(cmd, power)
  if not cmd then return nil end
  cmd = cmd:gsub("POWER", tostring(power))
  return cmd
end

local function onInit()
  electrics.values.ammeter = 0
  electrics.values.powerRatio = 1
  electrics.values.powerAvailable = 1
  electrics.values.powerOn = (electrics.values.ignitionLevel > 0) and 1 or 0
  electrics.values.powerOnRatio = 1

  -- Ensure all electrics values are initialized
  electrics.values.lowbeam = 0
  electrics.values.highbeam = 0
  electrics.values.lowhighbeam = 0
  electrics.values.brake = 0
  electrics.values.signal_L = 0
  electrics.values.signal_R = 0
  electrics.values.lightbar = 0
  electrics.values.lowhighbeam = 0
  electrics.values.oilpressure_low = 0
  electrics.values.oil = 0
  electrics.values.regeneration = 0
  electrics.values.generatorPower_low = 0
  electrics.values.checkengine = false
  electrics.values.radio_state = 0
  electrics.values.hazard = 0
  electrics.values.fog = 0
  electrics.values.interiorlightstate = 0
  electrics.values.underglow = 0

  --writeFile("debug/powertrain.mainEngine.json", dump(engine, 0, 2))
  --dumpFile("powertrain.mainEngine", engine)

  -- Battery
  battery = controller.getControllerSafe('battery')
  if battery then
    battery.addNotify(onBattery)
  end

  -- Engine
  if v.data.mainEngine then
    local e = v.data.mainEngine

    enginePower = enginePower > 0 and enginePower or e.enginePower
    engineBasePower = engineBasePower > 0 and engineBasePower or e.engineBasePower
    engineIdleRPM = engineIdleRPM > 0 and engineIdleRPM or math.max(0, e.idleRPM - (e.idleRPMRoughness or 100))
    starterPower = starterPower > 0 and starterPower or e.starterPower
    --generatorCurrent = generatorCurrent > 0 and generatorCurrent or e.generatorCurrent

    log("D", "", "[Bug:Power] Engine:")
    log("D", "", "[Bug:Power]   Idle RPM: "..tostring(engineIdleRPM))
    log("D", "", "[Bug:Power]   Power: "..tostring(toUnit(enginePower, "W")))
    log("D", "", "[Bug:Power]   Base Power: "..tostring(toUnit(engineBasePower, "W")))
    log("D", "", "[Bug:Power]   StarterPower: "..tostring(toUnit(starterPower, "W")))
    --log("D", "", "[Bug:Power]   Generator: "..tostring(toUnit(generatorCurrent, "A")))
  end

  -- Power Consumers
  if v.data.electricPower then
    for _,item in pairs(v.data.electricPower) do
      local p = {}
      p.partPath = item.partPath
      p.power = item.power or 0
      p.trigger = _replaceCmd(item.trigger, item.power)
      p.ratio = _replaceCmd(item.ratio, item.power)
      -- obsolete as of 0.34
      --if item.ignoreIgnition then
      --  table.insert(ignoreIgnition, item.ignoreIgnition)
      --end
      table.insert(powerParts, p)
    end
    table.sort(powerParts, function(a, b)
      return a.partPath < b.partPath
    end)
  end

  -- obsolete as of 0.34
  --if v.data.glowMap then
  --  local triggers = {}
  --  for mat, gm in sortedPairs(v.data.glowMap) do
  --    if type(gm.simpleFunction) == "string" then
  --      table.insert(triggers, gm.simpleFunction)
  --    elseif type(gm.simpleFunction) == "table" then
  --      for fk, fc in pairs(gm.simpleFunction) do
  --        table.insert(triggers, fk)
  --      end
  --    end
  --  end
  --
  --  for _, value in pairs(triggers) do
  --    if string.len(value) > 7 then
  --      if string.sub(value, 0, 7) == "power__" then
  --        powerValues[value] = string.sub(value, 8)
  --      end
  --    end
  --  end
  --end

  log("D", "", "[Bug:Power] Consumers:")
  for _,p in pairs(powerParts) do
    local s = ""
    if p.trigger then s = s.."trigger: '"..tostring(p.trigger).."'" end
    if p.ratio then s = s.."; ratio: '"..tostring(p.ratio).."'" end
    log("D", "", "[Bug:Power]   "..tostring(toUnit(p.power, "W")).." "..p.partPath.." {"..s.."}")
  end
end

local function onReset()
  electrics.values.ammeter = 0
end

local function showBatteryStatus()
  local b = battery
  if not b then
    log("I", "", "[Bug:Battery] (No Battery)")
    guihooks.message({txt = "ui.bug.batteryinfo.nobattery", context = {}}, 5, "bug.power.batterystatus", "charge")

  elseif b.isBroken() then
    log("I", "", "[Bug:Battery] (Ruined)")
    guihooks.message({txt = "ui.bug.batteryinfo.ruined", context = {}}, 5, "bug.power.batterystatus", "charge")

  else
    local ratio     = string.format("%.0f", b.getChargeRatio()*100)
    local charge    = toUnit(b.getCharge()/1000,"",1000,0)
    local capacity  = toUnit(b.getCapcity()/1000,"Ah",1000,0)
    local voltage   = toUnit(b.getVoltage(),"V",1,1)
    local time      = b.getEstimatedTime()
    local timestr   = toTime(time, false) -- no translation

    local msg = ""
    msg = msg .. ratio .. "% " .. charge.."/"..capacity.." " .. voltage .."\n"
    if b.isCharging() then msg = msg .. "Recharged in " else msg = msg .. "Discharged in " end
    msg = msg .. time
    msg = msg .. "\nPower: "..tostring(toUnit(b.getPowerOutput(), "W"))
    log("I", "", "[Bug:Battery] " .. msg)


    timestr    = toTime(time, true) -- with translation
    local uimsg = b.isCharging() 
        and "ui.bug.batteryinfo.message.recharge" 
        or "ui.bug.batteryinfo.message.discharge"
    guihooks.message({txt = uimsg, context = {ratio=ratio, charge=charge, capacity=capacity, voltage=voltage, time=timestr}}, 5, "bug.power.batterystatus", "charge")
  end
end


M.onInit    = onInit
M.onReset   = onReset
M.updateGFX = updateGFX

M.toUnit = toUnit
M.toTime = toTime

-- public interface
M.batteryStatus = showBatteryStatus


return M
