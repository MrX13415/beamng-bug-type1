-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- v1.0
-- by MrX13415

local M = {}

local ignitionLevel = -1

local function updateGFX(dt)
  local lvl = electrics.values.ignitionLevel
  if lvl == 1 then
    if ignitionLevel == 0 then
      electrics.setIgnitionLevel(2)
    elseif ignitionLevel == 2 then
      electrics.setIgnitionLevel(0)
    end
  end
  ignitionLevel = electrics.values.ignitionLevel
end

local function onInit(jbeamData)
  ignitionLevel = -1
end

local function onReset()
  ignitionLevel = -1
end

M.init      = onInit
M.reset     = onReset
M.updateGFX = updateGFX

return M
