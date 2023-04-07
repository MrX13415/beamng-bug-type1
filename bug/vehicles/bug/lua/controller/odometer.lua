-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- v1.1
-- by MrX13415

local M = {}
local digits = 11               -- 11 digits. Support for up to 99.999.999 km
local unit = "meter"            -- Default mode
local unitMiles = 0.000621371   -- DO NOT CHANGE!
local updateTimer = 2           -- Make sure the first call is immediately
local lastMileage = 0           -- in meters
local mileage = 0               -- in meters

-- common
function round(num, numDecimalPlaces)
  local mult = 10^(numDecimalPlaces or 0)
  return math.floor(num * mult + 0.5) / mult
end

local function writeCurrentTrust()
	local d = storage.data()
	d.herbie = {}
	d.herbie.trust = playerTrust
end

local function load()
  local odometer = storage.data().odometer or {}
  lastMileage = odometer.mileage or 0
  lastMileage = math.max(lastMileage, 0)  -- Ensure positive value
end

local function save()
	local d = storage.data()
	d.odometer = {}
	d.odometer.mileage = mileage
end

local function set(value)
  odometer.mileage = value
  load()
  print("[Bug:Odometer] Set: " .. lastMileage)
end

local function updateOdometer(dt)
  local odometer = electrics.values.odometer
  mileage = round(lastMileage + odometer, 1) -- total mileage in meters

  local distance = mileage
  local offset = 1
  if unit == "miles" then
    distance = round(distance * unitMiles, 3)
    offset = 1000
  end

  local lastAngle = 0
  local lastOverflow = false

  -- calculate the angle for each digits.
  for index = 1, digits do
    -- calulate the multiplier for this digit ...
    --   10 ^ 2 = 100 | 36 / 100 = 0.36
    local mul = 36 / 10 ^ (index - 1)

    -- calculate the raw angle ...
    --   500m * 0.36 = 180°
    local raw = math.floor(distance * offset * mul % 360)  -- raw angle

    local overflow = raw > 324
    local angle = raw

    if index > 4 then
      angle = raw - (raw % 36)  -- limt angle to 36° steps for digit of 10km and above
      if lastOverflow then
        angle = angle + (lastAngle - 324) 
      end
    end

    lastOverflow = overflow
    lastAngle = angle

    -- write value for props ...
    electrics.values["odometerdigit"..index] = angle

    -- DEBUG:
    --if index == 4 then print("[Bug:Odometer] --") end
    --local digit = math.floor(angle / 36)
    --print("[Bug:Odometer] #" .. index ..": ".. digit .." | ".. angle .. "° (".. raw .."°) " .. (overflow and "overflow" or ""))
  end

  -- DEBUG:
  --print("[Bug:Odometer] Mileage: " .. distance .. " " .. unit .. " Odometer: " .. odometer)
  updateTimer = 0
  save()
end

local function updateGFX(dt)
  updateTimer = updateTimer + dt

	-- update rate: 10 fps (0.1 == 100ms)
	if updateTimer >= 0.1 then 
    updateOdometer(updateTimer)
  end
end

local function onReset()
	save()
  -- Disabled: milage no longer set to zero on vehicle reset
  --lastMileage = mileage
end

local function onInit(jbeamData)
  for index = 1, digits do
    electrics.values["odometerdigit"..index] = 0
  end

  -- Determine selected unit ...
  if jbeamData.unit then
    if string.sub(jbeamData.unit, 1, 2) == "im" then
      unit = "miles"
    end
  end

  load()

  print("[Bug:Odometer] Initialized")
  print("[Bug:Odometer]    mileage: " .. lastMileage)
  print("[Bug:Odometer]    unit:    " .. unit)
end

M.init      = onInit
M.reset     = onReset
M.updateGFX = updateGFX

-- Console: controller.getController('odometer').set(0)
M.set       = set

return M
