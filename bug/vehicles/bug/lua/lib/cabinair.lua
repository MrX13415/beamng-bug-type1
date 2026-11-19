-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Cabin air pressure for the Bug's (famously air-tight) cabin.
--
-- Door seal: a short, firm rubber seal that only touches the last ~1.8 cm before the latch (rear edge),
-- damped more while springing out than while closing. When the latch releases, the compressed seal kicks
-- the door out and the hinge friction stops it in the leaned position (~2.8 cm / ~1.8 degrees), where the
-- seal no longer touches. So a door that is pushed in slowly stalls just short of the latch and stays there
-- when released, instead of being pushed back out. The seal is modelled
-- here, with the same door opening measure as the air, so seal contact and air gap always match.
--
-- Once a door is on its seal, closing it further squeezes the cabin air. The overpressure pushes on every door that is not latched,
-- and air escapes through the leaks: a small base leak, open side/vent windows, the ragtop, broken glass
-- (setExtraLeak) and the gap of any door that is open past its seal contact.
--
-- That gives:
--   * other door open     -> its gap leaks, no pressure: a light swing closes the door
--   * other door leaned   -> the pressure pushes it off its seal and it swings open a bit, which relieves
--                            the pressure; closing is a bit harder
--   * other door closed   -> (windows up) the air is trapped: the door needs a real slam to latch,
--                            otherwise the air pushes it back and it settles in the leaned position
--
-- Runs every physics step (the last centimetres of a slam take only a few milliseconds), but does
-- nothing while both doors are latched.

local M = {}

local doordrag = require("vehicles/bug/lua/lib/doordrag")

-- Model (tuned with a 1-DOF simulation of both doors)
local P0        = 101325   -- Pa   ambient pressure (isothermal compression)
local RHO       = 1.2      -- kg/m^3
local V_CABIN   = 1.2      -- m^3  effective cabin air volume (cabin minus seats/trim)
local A_DOOR    = 0.8      -- m^2  door area
local A_SWEPT   = 0.5 * A_DOOR -- m^3 per m of rear-edge travel (the door pivots at its front edge)
local F_LEVER   = 0.5      -- pressure force on the door, expressed at the handle (rear edge)
local CD        = 0.6      -- discharge coefficient of the leaks
local A_BASE    = 0.004    -- m^2  base leak (body seams, heater/defrost ducts)
local A_WINDOW  = 0.25     -- m^2  fully open door window
local A_VENT    = 0.03     -- m^2  open vent window
local A_RAGTOP  = 1.0      -- m^2  open ragtop
local A_MISSING = 1.0      -- m^2  door part missing / broken off
local SEAL_S    = 0.018    -- m    seal contact (rear edge opening)
local SEAL_K    = 3000     -- N/m  seal stiffness at the handle
local SEAL_C_IN = 10       -- N s/m seal damping while the door closes (rubber barely slows a slam)
local SEAL_C_OUT= 85       -- N s/m seal damping while it springs back out (sets how far the latch release pops the door)
local VAC_MIN   = -30      -- Pa   the seal lips let air in easily: no real suction when a door opens
local C_RECOIL  = 800      -- N s/m extra damping while overpressure pushes a door back out (a failed slam
                           --       settles in the leaned position instead of being thrown open)
local GAP_LEN   = 0.8      -- m    effective gap per m of door opening beyond the seal contact (the door overlaps the
                           --      frame flange, so the air is already squeezed through a narrow gap before the seal touches)

local DOORS = {"FL", "FR"}

local pressure = 0         -- Pa, overpressure in the cabin
local extraLeak = 0        -- m^2, set by the vehicle (broken glass)
local hookEnabled = false
local freeDoors, openings, rates = {}, {}, {}   -- reused every physics step (no garbage)

local function windowLeak()
  local e = electrics.values
  return A_WINDOW * ((e.windowFL_state or 0) + (e.windowFR_state or 0))
       + A_VENT   * ((e.doorventFL_state or 0) + (e.doorventFR_state or 0))
       + A_RAGTOP * (e.ragtop_state or 0)
end

local function onPhysicsStep(dt)
  -- gather the doors that can move
  local leak = A_BASE + extraLeak + windowLeak()
  local dV = 0
  local free, nFree = nil, 0
  for _, id in ipairs(DOORS) do
    if not doordrag.isLatched(id) then
      local s, sdot = doordrag.getOpening(id)
      if not s then
        leak = leak + A_MISSING
      else
        leak = leak + math.max(0, s - SEAL_S) * GAP_LEN
        dV = dV + A_SWEPT * sdot   -- opening a door makes the cabin bigger
        free = freeDoors
        nFree = nFree + 1
        freeDoors[nFree], openings[nFree], rates[nFree] = id, s, sdot
      end
    end
  end

  -- dry hinge friction on the doors that can swing (part of the door physics, needs the physics step too)
  if free then
    for i = 1, nFree do doordrag.hingeFrictionStep(freeDoors[i], dt) end
  end

  if not free then
    -- all doors latched: whatever was left equalizes through the leaks, no forces needed
    pressure = 0
    return
  end

  -- implicit step: p = a - k*sign(p)*sqrt|p|, with a = p_old - (P0/V)*dV*dt and k from the orifice flow
  local a = pressure - (P0 / V_CABIN) * dV * dt
  local k = (P0 / V_CABIN) * dt * CD * leak * math.sqrt(2 / RHO)
  local u = (-k + math.sqrt(k * k + 4 * math.abs(a))) * 0.5
  pressure = math.max((a >= 0 and 1 or -1) * u * u, VAC_MIN)

  local fAir = pressure * A_DOOR * F_LEVER
  for i = 1, nFree do
    local id = freeDoors[i]
    -- seal: spring + direction dependent damping while the door is within the seal contact
    local s, sdot = openings[i], rates[i]
    local f = fAir
    if s < SEAL_S then
      f = f + SEAL_K * (SEAL_S - s) - (sdot > 0 and SEAL_C_OUT or SEAL_C_IN) * sdot
    end
    if pressure > 0 and sdot > 0 then
      f = f - C_RECOIL * sdot
    end
    if math.abs(f) > 0.01 then
      doordrag.applyOpenForceStep(id, f)
    end
  end
end

local function enableHook()
  if hookEnabled then return end
  hookEnabled = true
  enablePhysicsStepHook()
end

local function updateGFX(dt)
  enableHook()
  electrics.values.bug_cabin_pressure = pressure
end

local function onReset()
  pressure = 0
end

-- additional leak area (m^2), e.g. broken windows
local function setExtraLeak(area) extraLeak = math.max(0, area or 0) end
local function getPressure() return pressure end

M.onPhysicsStep = onPhysicsStep
M.updateGFX     = updateGFX
M.onReset       = onReset
M.setExtraLeak  = setExtraLeak
M.getPressure   = getPressure

return M
