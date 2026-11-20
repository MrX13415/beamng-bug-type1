-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Openings of the cabin: doors, windows, vent windows, roof and broken glass. 10 times a second it works out how
-- open the cabin is and sets from that:
--   - electrics opendoor_L / opendoor_R / opendoors, vehicleopenL / vehicleopenR / vehicleopen;
--   - the interior light (on with an open door or the button, see lib/interior.lua);
--   - the extra air leak of broken glass (lib/cabinair.lua);
--   - the cabin sound filter (core_sounds.cabinFilterStrength).
-- Moved unchanged from vehicle.lua. vehicle.lua calls setup / update / reset (they are not game hooks on purpose:
-- this file is also auto-loaded as a vehicle extension, and the order is kept as before).

local M = {}

local misc = require("vehicles/bug/lua/misc")
local cabinair = require("vehicles/bug/lua/lib/cabinair")

local getControllerState = misc.getControllerState

local openingUpdateTimer = 0

local cabinFilterTimer = 2
local cabinFilterCoef = 1

local parts = {
  ventL    = {broken = false, deformGroup = "ventglass_FL_break"},
  ventR    = {broken = false, deformGroup = "ventglass_FR_break"},
  windowFL = {broken = false, deformGroup = "doorglass_FL_break"},
  windowFR = {broken = false, deformGroup = "doorglass_FR_break"},
  windowRL = {broken = false, deformGroup = "sidewindow_RL_break"},
  windowRR = {broken = false, deformGroup = "sidewindow_RR_break"},
  windowR  = {broken = false, deformGroup = "rearwindow_break"},
  windshield = {broken = false, deformGroup = "windshield_break"},
  ragtop   = {broken = false, name = "ragtopF", cid = nil},
}

local function updatePartBroken(part)
  if part.broken then return true end
  if #part.deformGroup == 0 then return part.broken end

  local group = beamstate.deformGroupDamage[part.deformGroup]
  if group and group.eventCount > 0 then
    part.broken = true
  elseif not group and next(beamstate.deformGroupDamage) ~= nil then
    -- no beam has this deform group: the glass part isn't installed, the opening is open (cabin air leak)
    part.broken = true
  end
  return part.broken
end
local function updatePartBrokenBeam(part)
  if part.broken then return true end
  if part.cid then
    part.broken = obj:beamIsBroken(part.cid)
  end
  return part.broken
end
local function checkPartsBroken()
  updatePartBroken(parts.ventL)
  updatePartBroken(parts.ventR)
  updatePartBroken(parts.windowFL)
  updatePartBroken(parts.windowFR)
  updatePartBroken(parts.windowRL)
  updatePartBroken(parts.windowRR)
  updatePartBroken(parts.windowR)
  updatePartBroken(parts.windshield)

  updatePartBrokenBeam(parts.ragtop)
end
local function resetParts()
  parts.ventL.broken = false
  parts.ventR.broken = false
  parts.windowFL.broken = false
  parts.windowFR.broken = false
  parts.windowRL.broken = false
  parts.windowRR.broken = false
  parts.windowR.broken = false
  parts.windshield.broken = false
  parts.ragtop.broken = false
end

local function setCabinFilterCoef(newCabinFilterCoef)
  cabinFilterCoef = newCabinFilterCoef
end

local function updateCabinFilter()
  if not playerInfo.firstPlayerSeated then return end

  obj:queueGameEngineLua(string.format([[
    local newCoef = %f
    if core_sounds.cabinFilterStrength ~= newCoef then
      core_sounds.cabinFilterStrength = newCoef
      --log("D", "", "[Bug] CabinFilterCoef: " .. core_sounds.cabinFilterStrength)
    end
  ]], clamp(cabinFilterCoef, 0, 1)))
end

local function setCabinFilter(open)
  local minFactor = 1 - 1 / v.data.sounds.cabinFilterCoef * 0.15 -- Keep at least 15%
  local openCurve = 1 - (open*1.3)/(open+0.3) * minFactor

  setCabinFilterCoef( math.abs(openCurve * v.data.sounds.cabinFilterCoef) )
end

local function updateInteriorlight(doors)
  local lightstate = electrics.values.interiorlightbutton > 0 or doors > 0
  electrics.values.interiorlightstate = lightstate and 1 or 0
end

local function updateOpenings()
  checkPartsBroken()

  local doorL = getControllerState('door_FL_coupler')
  local doorR = getControllerState('door_FR_coupler')
  local doors = clamp((doorL + doorR) / 2, 0, 3)

  electrics.values["opendoor_L"] = doorL
  electrics.values["opendoor_R"] = doorR
  electrics.values["opendoors"] = doors

  updateInteriorlight(doors)

  local brokenWindowL = (parts.windowFL.broken and 1) or (parts.windowRL.broken and 1) or (parts.windowR.broken and 1) or (parts.windshield.broken and 1) or 0
  local brokenWindowR = (parts.windowFR.broken and 1) or (parts.windowRR.broken and 1) or (parts.windowR.broken and 1) or (parts.windshield.broken and 1) or 0
  local ventFL = math.max(parts.ventL.broken and 1 or 0, electrics.values["doorventFL_state"] or 0)
  local ventFR = math.max(parts.ventR.broken and 1 or 0, electrics.values["doorventFR_state"] or 0)
  local windowFL = math.max(brokenWindowL, electrics.values["windowFL_state"] or 0)
  local windowFR = math.max(brokenWindowR, electrics.values["windowFR_state"] or 0)
  --local windows = clamp((windowFL + windowFR) / 2, 0, 1)

  local ragtop = math.max(parts.ragtop.broken and 1 or 0, electrics.values.ragtop_state or 0)

  -- broken glass lets the cabin air out (cabin pressure when slamming a door, see lib/cabinair.lua)
  cabinair.setExtraLeak(
      (parts.windowFL.broken and 0.25 or 0) + (parts.windowFR.broken and 0.25 or 0)
    + (parts.ventL.broken and 0.03 or 0)    + (parts.ventR.broken and 0.03 or 0)
    + (parts.windowRL.broken and 0.2 or 0)  + (parts.windowRR.broken and 0.2 or 0)
    + (parts.windowR.broken and 0.3 or 0)
    + (parts.windshield.broken and 0.4 or 0)  -- was missing: a broken windshield left the cabin air-tight
    + (parts.ragtop.broken and 1.0 or 0))

  local openL = clamp(doorL + (windowFL * 0.75) + (ventFL * 0.1) + (ragtop * 0.5), 0, 1)
  local openR = clamp(doorR + (windowFR * 0.75) + (ventFR * 0.1) + (ragtop * 0.5), 0, 1)
  local open = math.max(openL, openR)

  electrics.values["vehicleopenL"] = openL
  electrics.values["vehicleopenR"] = openR
  electrics.values["vehicleopen"] = open

  setCabinFilter(open)

  return open
end

-- called from vehicle.onInit: find the roof's break beam
local function setup()
  for _, b in pairs(v.data.beams) do
    if b.breakGroup == parts.ragtop.name then
      parts.ragtop.cid = b.cid
      break
    end
  end
end

-- called from vehicle.updateGFX
local function update(dt)
  openingUpdateTimer = openingUpdateTimer + dt
  -- update rate: 10 fps (0.100 == 100ms)
  if openingUpdateTimer > 0.100 then
    openingUpdateTimer = 0
    updateOpenings()
  end

  cabinFilterTimer = cabinFilterTimer + dt
  -- update rate: 10 fps (0.1 == 100ms)
  if cabinFilterTimer > 0.1 then
    cabinFilterTimer = 0
    updateCabinFilter()
  end
end

-- called from vehicle.onReset
local function reset()
  resetParts()
end

M.setup  = setup
M.update = update
M.reset  = reset

return M
