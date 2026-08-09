-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Simple clock controller for an analog clock.
-- v1.0
-- by MrX13415

local M = {}
local updateTimer = 2   -- Make sure the first call is immediately

local function updateClock(dt)
  local time = os.date("*t")

  -- 24h to 12h
  local hour = time.hour
  if hour > 12 then hour = hour - 12 end 
  
  local s = time.sec + 1
  local h = (hour * 60) + time.min
  local m = (time.min * 60) + time.sec

  electrics.values["clockh"] = ((360 / 720) * h) or 0
  electrics.values["clockmin"] = ((360 / 3600) * m) or 0
  electrics.values["clocksec"] = ((360 / 60) * s) or 0
end

local function updateGFX(dt)
  updateTimer = updateTimer + dt
	-- update rate: 1 fps (1.0 == 1000ms)
	if updateTimer < 1 then return end

  updateClock(updateTimer)

  updateTimer = 0
end

local function onInit(jbeamData)
  log("D", "", "[Bug:Clock] Initialized")
  
  electrics.values["clockh"] = 0
  electrics.values["clockmin"] = 0
  electrics.values["clocksec"] = 0
end

M.init      = onInit
M.updateGFX = updateGFX

return M
