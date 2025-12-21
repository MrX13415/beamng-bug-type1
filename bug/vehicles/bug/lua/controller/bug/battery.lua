-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- by MrX13415

local M = {}

local power = require("power")

local toUnit = power.toUnit

local broken = false
local breakTiggerBeam = nil

local systemVoltage = 12       -- V
local voltageRange = 10.5       -- %
local voltageNominal = 29.76    -- %

local capacity = 0              -- mAh
local charge = 0                -- mAh
local selfDischarge = 0         -- mAh

local resistanceMin = 0.005     -- Ohm
local resistanceMax = 4         -- Ohm
local resistanceCharge = 0.05   -- Ohm

local C = 0   -- h
local k = 0

local powers = {}
local powerLoad = 0       -- W
local powerGenerator = 0  -- W
local powerOutput = 0     -- W

local voltage = 0         -- V
local current = 0         -- A
local resistance = 0      -- Ohm
local chargingRate = 0    -- Ah 

local notifyCallbacks = {}

local function addNotify(notifyFunc)
  table.insert(notifyCallbacks, notifyFunc)
end

local function ratioFrom(x)
  return math.log10(x * 0.9 + 0.1) + 1
end
local function ratioTo(y)
  return (math.pow(10, y - 1) - 0.1) / 0.9
end

local function getSystemVoltage() return systemVoltage end
local function getVoltage() return voltage end

local function getCapcity() return capacity end
local function getCharge() return charge end
local function getRatio()
  if capacity < 1 or broken then return 0 end
  return charge / capacity
end

local function getChargeRatio()
  return ratioTo(getRatio())
end
local function setChargeRatio(ratio)
  ratio = clamp(ratio, 0, 1)
  charge = capacity * ratioFrom(ratio)
end

local function isBroken() return broken end
local function isEmpty() return getRatio() < 0.00001 end
local function isFull() return charge >= capacity end
local function isCharging() return not isFull() and current > 0 end

local function getCurrent() return current end
local function getChargingCurrent(inCurrent)
  if inCurrent < 0 then return 0 end
  local chargeCurrent = inCurrent*1000 * 5 * (1 - math.pow(getRatio(),2))
  return math.min(chargeCurrent, inCurrent)
end

local function clearPower()
  powers = {}
end
local function addPower(name, power)
  powers[name] = (powers[name] or 0) + power
end
local function setPower(name, power)
  powers[name] = power
end
local function setPowerGenerator(power)
  powerGenerator = power
end
local function getPower(name)
  if name then return powers[name] end
  return powerLoad
end
local function getPowerOutput()
  return powerOutput
end
local function getPowerRatio()
  local output = getPowerOutput()
  local power = getPower()

  if power == 0 then return 0 end
  return output / power
end

local function getEstimatedTime()
  if isCharging() then
    return (capacity - charge) / math.abs(current) * 60
  end

  local estimateP = C * math.pow((charge)/(math.abs(current) * C), k) * 60
  local estimate = charge / math.abs(chargingRate) * 60
  return math.min(estimateP, estimate)
end

local function beamBroken(id, energy)
  if id ~= breakTiggerBeam then return end
  broken = true
end

local function calcVoltage(ratio)
  -- Determin charge voltage
  local vRange = systemVoltage * (voltageRange/100)
  local vMin = systemVoltage - (voltageNominal/100)
  return vMin + (vRange * ratio)
end

local function onUpdateGFX(dt)

  for _,notifyFunc in ipairs(notifyCallbacks) do
    notifyFunc(M)
  end

  local time = dt / 3600 -- hours

  -- Get current charge voltage
  local ratio = getRatio()
  voltage = calcVoltage(ratio)

  -- Update total power load
  powerLoad = 0   -- in W
  for name,p in pairs(powers) do
    powerLoad = powerLoad + p
    if p > 0 then
      --log("D", "", "[Bug:Battery]   "..tostring(name).." " .. tostring(toUnit(p, "W")))
    end
  end


  -- Total power draw
  local loadCurrent = voltage > 0 and (powerLoad / voltage) or 0  -- in A

  -- Total generator current
  local genCurrent = voltage > 0 and (powerGenerator / voltage) or 0  -- in A
  genCurrent = math.min(genCurrent, loadCurrent + getChargingCurrent(genCurrent))

  -- Total battery current
  local needCurrent = genCurrent - loadCurrent

  if needCurrent > 0 then
    resistance = resistanceCharge
  else
    -- (4-0,005)((1-𝑥-0,25)^4 )+0,005
    resistance = (resistanceMax - resistanceMin) * math.pow(1-ratio-0.25, 4) + resistanceMin
  end

  -- Determine voltage drop by resistance
  local voltageDrop = math.max(needCurrent * resistance, -voltage)
  voltage = voltage + voltageDrop

  -- Determine actuall current due to voltage drop
  local currentLimit = voltage / resistance * ratio * 0.8
  current = math.max(needCurrent, -currentLimit)

  local currentRatio = 0
  if needCurrent > 0 or needCurrent < 0 then
    currentRatio = math.min(1.0, current / needCurrent)
  end
  powerOutput = powerLoad * currentRatio
  
  --log("D", "", "[Bug:Battery] "..toUnit(voltage, "V").." (".. tostring(toUnit(voltage - voltageDrop, "V"))..") "..tostring(toUnit(current, "A")).." ("..tostring(toUnit(needCurrent, "A"))..") "..tostring(toUnit(powerOutput, "W")).." ("..tostring(toUnit(powerLoad, "W"))..") "..tostring(toUnit(resistance, "Ohm")))


  if current > 0 and isFull() then
    current = 0
  end
  if current < 0 and isEmpty() then
    current = 0
  end

  local rate = current * 1000 * time  -- in mA
  
  -- Include self discharge rate
  if rate <= 0 then 
    rate = math.min(rate, -selfDischarge * time)
  end

  -- Update battery capacity
  charge = clamp(charge + rate, 0, capacity)
  -- Update charging rate
  chargingRate = rate / time

  --log("D", "", "[Bug:Battery] "..toUnit(voltage, "V").." "..string.format("%.1f%%", getChargeRatio()*100).." "..toUnit(charge/1000,"",1000).."/"..toUnit(capacity/1000,"Ah",1000).." Load:" .. tostring(toUnit(current / 1000, "A")) .. " (Rate: " .. tostring(power.toUnit(rate / 1000, "Ah")) .. ")")

  electrics.values.ampere = needCurrent
  electrics.values.voltage = voltage
end

local function onInit(jbeamData)
  broken = false
  local beamTrigger = jbeamData.breakTriggerBeam or ""
  for _, v in pairs(v.data.beams) do
    if v.name and v.name == beamTrigger then
      breakTiggerBeam = v.cid
      break
    end
  end

  systemVoltage = jbeamData.voltage or systemVoltage
  
  capacity = (jbeamData.capacity or 0) * 1000  -- A to mA
  charge = capacity * ratioFrom(jbeamData.charge or 1)
  selfDischarge = (jbeamData.selfDischarge or 0) * 1000  -- Ah to mAh

  resistanceMin = jbeamData.resistanceMin or resistanceMin
  resistanceMax = jbeamData.resistanceMax or resistanceMax

  C = jbeamData.C or C
  k = jbeamData.k or k

  log("D", "", "[Bug:Battery] "..toUnit(systemVoltage, "V").." "..tostring(getChargeRatio()*100).."% "..tostring(charge).."/"..tostring(capacity).."mAh (C"..tostring(C)..", "..tostring(k)..")")
end

M.init                = onInit
M.updateGFX           = onUpdateGFX
M.beamBroken          = beamBroken

-- Public Interface
-- Console: controller.getController('battery').setChargeRatio(0.5)
M.getSystemVoltage    = getSystemVoltage
M.getVoltage          = getVoltage
M.getCapcity          = getCapcity
M.getCharge           = getCharge
M.getChargeRatio      = getChargeRatio
M.setChargeRatio      = setChargeRatio

M.isBroken            = isBroken
M.isEmpty             = isEmpty
M.isFull              = isFull
M.isCharging          = isCharging
M.getCurrent          = getCurrent
M.getChargingCurrent  = getChargingCurrent

M.clearPower          = clearPower
M.getPower            = getPower
M.setPower            = setPower
M.addPower            = addPower
M.setPowerGenerator   = setPowerGenerator
M.getPowerOutput      = getPowerOutput
M.getPowerRatio       = getPowerRatio

M.getEstimatedTime    = getEstimatedTime

M.addNotify           = addNotify

return M
