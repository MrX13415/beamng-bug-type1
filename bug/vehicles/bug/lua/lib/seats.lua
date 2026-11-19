-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Front seats: sliding them with the handle (seatFL_position / seatFR_position) and making room when someone gets
-- out of a rear seat.
-- Moved unchanged from vehicle.lua; vehicle.lua forwards the public functions and calls setup.

local M = {}

local animation = require("vehicles/bug/lua/lib/animation")

local moveSeatData = {
  seatId = "",
  value = 0,
  min = 0,
  max = 0
}
local function applyMoveSeat()
  local var = moveSeatData.seatId.."_position"
  local pos = electrics.values[var] or 0

  pos = math.min(moveSeatData.max or 1, math.max(moveSeatData.min or 0, pos + moveSeatData.value))
  electrics.values[var] = pos

  local uival = tostring(pos)
  local txt = "ui.bug.interior.seatpos."..pos
  guihooks.message({txt = txt, context = {value=uival}}, 4, "bug.seat", "seatArrowInLeft")

  print("[Bug:Seat] Position " .. tostring(pos))

end

local function moveSeat(seatId, val, min, max)
  moveSeatData.seatId = seatId
  moveSeatData.value = val
  moveSeatData.min = min
  moveSeatData.max = max
  animation.start(seatId.."_handle")
end

-- getting out from a rear seat with F (bug_exitDoor): the front seat on the door's side ("FL" / "FR") folds
-- its backrest forward (backrest hydro seatFLbackrest / seatFRbackrest = 1, like the seat's toggle action) and
-- slides all the way forward (seatFL_position = 3, with the handle animation, like the "move seat forward" action)
local EXIT_SEAT_SLIDE = true  -- false: only fold the backrest
local function exitSeatForward(id)
  local seatId = "seat" .. id
  electrics.values[seatId .. "backrest"] = 1
  if EXIT_SEAT_SLIDE and (electrics.values[seatId .. "_position"] or 0) < 3 then
    moveSeat(seatId, 6, -3, 3)  -- clamped to the forward end (+3)
  end
end

-- called from vehicle.onInit
local function setup()
  animation.setup('seatFL_handle', {
    {  0,   0},
    { 20, 0.6},
    { 30, 1.0},
    { 60, 1.0},
    { 70, 0.5},
    { 80,   0}
  },{
    { 40, function() applyMoveSeat() end }
  })
  animation.setup('seatFR_handle', {
    {  0,   0},
    { 20, 0.6},
    { 30, 1.0},
    { 60, 1.0},
    { 70, 0.5},
    { 80,   0}
  },{
    { 40, function() applyMoveSeat() end }
  })
end

M.setup           = setup
M.moveSeat        = moveSeat
M.exitSeatForward = exitSeatForward

return M
