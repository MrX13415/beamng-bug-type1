-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- v1.0
-- by MrX13415

local M = {}

local power = require "power"

local updateTimer = 2     -- Make sure the first call is immediately

local oilCurve = nil
local oilSmoother = newExponentialSmoothing(50)

local genCurve = nil
local genSmoother = newExponentialSmoothing(50)

local battery = nil
local engine = nil

local starterTimeFactor = 1
local starterTime = 0
local starterEnabled = true

local engine_activateStarter = nil
local function onActivateStarter(device)
  if not engine then return end
  starterTimeFactor = 1
  starterTime = 0
  starterEnabled = true

  -- is battery low?
  local power = battery and not battery.isEmpty()
  engine.starterDisabled = not power
  if power and engine_activateStarter then
    engine_activateStarter(device)
  end
end

local function getPowerGenerator()
  if not engine then return 0 end
  if electrics.values.ignitionLevel < 2 then return 0 end

  local factor = 0
  if genCurve then
    local targetRPM = 5000 -- 100% output power
    local rpmRatio = clamp(math.floor(engine.outputRPM / targetRPM * 1000), 0, 2000)  -- 0-200%
    local v = math.max(0, genCurve[rpmRatio])
    if v then factor = genSmoother:get(v) or 0 end
  end
  
  local power = (v.data.mainEngine.generatorPower or 0) * factor
  return power
end

local function processOilPressure(dt)
  local psi = 0  
  if oilCurve then
    local v = oilCurve[math.floor(electrics.values.rpm)]
    if v then psi = oilSmoother:get(v) or 0 end
  end

  local oilVolume = engine.oilVolume
  local oilMass = engine.thermals.debugData.engineThermalData.oilMass
  if oilVolume < 1 then oilMass = 4 end
  if oilMass < 1 then oilMass = 4 end

  local oilRatio = oilMass / (oilVolume * 0.87) -- L to kg
  local oilTemp = electrics.values.oiltemp
  psi = psi * oilRatio * (1 - oilTemp / 1000)
  --log("D", "", "[Bug:Engine] Oil Ratio: " .. tostring(oilRatio) .. " Temp: " .. tostring(oilTemp) .. " PSI: " .. tostring(psi))
  
  local pressure = electrics.values.oilpressure
  if psi > pressure then
    pressure = pressure + 0.04
  elseif psi < pressure then
    pressure = pressure - 0.04
  end

  local genPower = getPowerGenerator()
  
  --print("Pressure: "..tostring(pressure).." PSI: "..tostring(psi))
  --print("Generator: "..tostring(genPower).." W")

  electrics.values.oilpressure = pressure
  electrics.values.oilpressure_low = electrics.values.ignitionLevel > 1 and pressure < 8

  electrics.values.generatorPower_low = electrics.values.ignitionLevel > 1 and genPower < 200 -- W
end


local totalStarterEngery = 0  --kWh
local function processEngineStarter(dt)
  local toUnit = power.toUnit

  if not battery or not engine then return end

  if engine.starterEngagedCoef > 0 and math.abs(engine.outputAV1) > 0.1 then
  else
    battery.setPower("starter", 0)
    return
  end

  local voltage = battery.getVoltage() or 0
  local spentEnergy = math.abs(engine.outputAV1) * (engine.starterTorque / 6)
  local loadCurrent = -(spentEnergy / voltage * 1000) -- W to mA
  --print(toUnit(spentEnergy).."W ".. toUnit(loadCurrent/1000, "A").." " .. toUnit(voltage, "V"))

  local power = spentEnergy
  battery.setPower("starter", power)

  -- kWh = Ah * V / 1000
  -- Ah = kWh * 1000 / V
  --local totalEngery = totalStarterEngery + spentEnergy
  --local total = totalStarterEngery * 1000 / voltage
  --log("D", "", "[Bug:Power] Starter: "..tostring(toUnit(spent / 1000), "Ah").." ("..tostring(toUnit(spentEnergy * 1000), "Wh")..") Total: "..tostring(toUnit(total / 1000)).."Ah ("..tostring(toUnit(totalStarterEngery * 1000, "Wh"))..")")
  
  if engine.starterThrottleKillTimer < 0.1 then return end

  if starterEnabled then
    starterEnabled = voltage > 0

    if starterTime == 0 then
      starterTime = engine.starterThrottleKillTimer
      starterEnabled = voltage > 5 -- min 5 Volt at beginning
    end

    local powerRatio = battery.getPowerRatio() or 1
    local factor = 0
    if powerRatio > 0 then factor = round(1 / powerRatio, 1) end
    local maxTime = starterTime * factor

    if factor > starterTimeFactor then
      engine.starterThrottleKillTimer = maxTime - engine.starterThrottleKillTimer
      starterTimeFactor = factor
    end

  else
    -- Disabled starter
    engine.starterThrottleKillTimer = 100
    engine.starterThrottleKillCoef = 0
    engine.starterEngagedCoef = 0
  end
end

local function updateGFX(dt)
  processEngineStarter(dt)
  processOilPressure(dt)
end

local function onInit()
  electrics.values.generatorPower_low = 0
  electrics.values.oilpressure = 0
  electrics.values.oilpressure_low = 0

  -- RPM
  oilCurve = createCurve({
    {    0,  0},
    {  700,  0},
    {  800, 20},
    { 6000, 50},
    { 8000, 55},
    {14000, 60}
  })

  -- 0-200%
  genCurve = createCurve({
    {    0,-0.30 },
    {  100, 0.15 },
    {  200, 0.45 },
    {  300, 0.65 },
    {  400, 0.76 },
    {  500, 0.85 },
    {  600, 0.91 },
    {  700, 0.95 },
    {  800, 0.98 },
    {  900, 0.99 },
    { 1000, 1.00 },
    { 1100, 1.01 },
    { 1200, 1.02 },
    { 1300, 1.03 },
    { 1400, 1.04 },
    { 1500, 1.05 },
    { 1600, 1.06 },
    { 1700, 1.07 },
    { 1800, 1.08 },
    { 2000, 1.10 },
  })

  battery = controller.getControllerSafe('battery')
  engine = powertrain.getDevice("mainEngine")

  if not engine then return end

  if engine_activateStarter ~= onActivateStarter then
    log("D", "", "[Bug:Engine] Override starter behaivior")
    engine_activateStarter = engine.activateStarter
    engine.activateStarter = onActivateStarter
  end
end

local function onReset()
  electrics.values.generatorPower_low = 0
  electrics.values.oilpressure = 0
  electrics.values.oilpressure_low = 0
end

M.onInit    = onInit
M.onReset   = onReset
M.updateGFX = updateGFX

M.getPowerGenerator = getPowerGenerator

return M
