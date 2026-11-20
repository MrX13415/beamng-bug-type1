-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Seats: sliding the front seats with the handle (seatFL_position / seatFR_position), folding the front backrests by
-- hand and locking them while someone sits there.
-- vehicle.lua forwards the public functions and calls setup / update / reset.
--
-- Front seat backrests of the generic front seats (bug.interior.seats.generics.jbeam): a hinged part
-- (lib/hinge.lua) without a latch. Hover lights up the backrest, hold + drag swings it, double-click folds / unfolds
-- it, a single click does nothing. It swings freely between stop beams (is<ID>1i/1o - is<ID>5i/5o); its weight is
-- cancelled and an over-center torque acts: below the tipping point it falls back upright, above it it goes to the
-- folded stop. The constant closing torque also holds it upright against braking / bumps. The hand may drag it in any
-- screen direction (screenFree), the light part gets a weaker hand and automatic push.
-- The seat's backrest hydro (input seat<ID>backrest) is the lock: while nobody sits on the seat its beams are slack
-- (spring 0), so the hinge is free; while someone sits there (the game's occupant system says so) it is stiff again
-- and holds the backrest upright, and the backrest can't be dragged or folded (see the seat lock below).

local M = {}

local animation = require("vehicles/bug/lua/lib/animation")
local hinge = require("vehicles/bug/lua/lib/hinge")

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

-- Backrests -------------------------------------------------------------------------------------------------------

local SEAT_FRONT_FULL_DEG  = 42   -- deg    backrest folded forward (stop beams is<ID>1-is<ID>5, 0.295 m shorter)
local SEAT_FRONT_MID_FRACTION = 0.5 -- tipping point (~ where its weight would tip it forward)
local SEAT_FRONT_T_OPEN    = 6    -- N m    above it: falls forward onto the stop
local SEAT_FRONT_T_CLOSE   = 20   -- N m    below it: falls back upright (more than its weight's torque at 1 g)
local SEAT_FRONT_DAMP      = 15   -- N m s/rad  (I ~1 kg m^2, top of the backrest 0.67 m from the pivot)
local SEAT_T_WIDTH         = math.rad(3)
local SEAT_THROW_SPEED     = 0.8  -- m/s
local SEAT_THROW_DAMP      = 3    -- N m s/rad
local SEAT_DRAG_MAX_FORCE  = 90   -- N
local SEAT_DRAG_SPRING     = 1500 -- N/m    short levers: with the lids' 600 the hand lagged far behind against the closing torque
local SEAT_DRAG_DAMP       = 120  -- N s/m  with the lids' 40 the light seats wobbled around the hand (damping ratio ~0.25)
local SEAT_AUTO_GAIN       = 150  -- N per m/s  (300 would make the light parts jitter at the graphics frame rate)
local SEAT_AUTO_MAX_FORCE  = 90   -- N
local SEAT_AUTO_CLOSE_SPEED = 0.6 -- m/s    at the drag point: no slam onto the stop

local SEAT_POLL_TIME   = 0.5    -- s    how often GE is asked which seats are occupied
local SEAT_LOCK_DELAY  = 1.0    -- s    from setting the input to upright until the hydro is stiff again (its rate
                                --      is 1 per second: it is back at upright by then)
local SEATS = {}                -- hinged seat parts: id -> config
local seatLocks = {}            -- id -> {elec, beams, locked, lockTimer, elecSeen}, or false (not a seat)
local occupiedSeats = {}        -- seat id of the occupant system ("FL", "FR", …) -> true, from GE
local seatPollTime = 0

-- GE answers the poll with this: the occupied seats of this car, e.g. {"FL"}
local function setOccupiedSeats(list)
  occupiedSeats = {}
  for _, seatId in ipairs(list or {}) do occupiedSeats[seatId] = true end
end

-- asks GE which seats of this car are occupied (the answer comes back through setOccupiedSeats)
local function pollOccupiedSeats(dt)
  seatPollTime = seatPollTime - dt
  if seatPollTime > 0 then return end
  seatPollTime = SEAT_POLL_TIME
  local id = obj:getId()
  obj:queueGameEngineLua(string.format(
    "local so = gameplay_seatOccupants; local veh = getObjectByID(%d); "
    .. "if so and so.getSeats and veh then local t = {}; "
    .. "for _, s in ipairs(so.getSeats(%d) or {}) do if s.occupied and s.seatId then t[#t + 1] = string.format('%%q', s.seatId) end end; "
    .. "veh:queueLuaCommand('if seats and seats.setOccupiedSeats then seats.setOccupiedSeats({' .. table.concat(t, ',') .. '}) end') end",
    id, id))
end

local function seatLockOf(id)
  local sl = seatLocks[id]
  if sl ~= nil then return sl or nil end
  local cfg = SEATS[id]
  if not cfg or not cfg.lock then seatLocks[id] = false return nil end
  sl = {elec = cfg.lock, beams = {}, locked = true, lockTimer = 0}
  for _, h in pairs(v.data.hydros or {}) do
    if h.inputSource == cfg.lock and h.beamCID then
      local b = v.data.beams[h.beamCID]
      sl.beams[#sl.beams + 1] = {cid = h.beamCID, spring = b and b.beamSpring or 0, damp = b and b.beamDamp or 0}
    end
  end
  if #sl.beams == 0 then
    log('W', 'bug.seats', 'seat ' .. id .. ': no backrest hydro with input ' .. cfg.lock .. ', it stays rigid')
    seatLocks[id] = false
    return nil
  end
  seatLocks[id] = sl
  return sl
end

local function setSeatStiff(sl, stiff)
  for _, b in ipairs(sl.beams) do
    obj:setBeamSpringDamp(b.cid, stiff and b.spring or 0, stiff and b.damp or 0, -1, -1)
  end
end

local function seatLocked(id)
  local sl = seatLocks[id]
  return sl and sl.locked or false
end

-- hook (lib/hinge.lua): every frame for a seat; true while it is locked (the hinge physics is skipped then, the
-- hydro holds it)
local function updateSeatLock(d, dt)
  local id = d.id
  local sl = seatLockOf(id)
  if not sl then return false end
  local e = electrics.values[sl.elec] or 0

  if occupiedSeats[d.cfg.seatId] then
    if not sl.locked then                     -- someone sat down: back to upright, then stiff
      log('D', 'bug.seats', 'seat ' .. id .. ' locked (occupied)')
      sl.locked, sl.lockTimer = true, SEAT_LOCK_DELAY
      hinge.cancel(d)
    end
    electrics.values[sl.elec] = 0
    sl.elecSeen = 0
    if sl.lockTimer > 0 then
      sl.lockTimer = sl.lockTimer - dt
      if sl.lockTimer <= 0 then setSeatStiff(sl, true) end
    end
    return true
  end

  if sl.locked then                           -- empty (again): slack hydro, free hinge
    log('D', 'bug.seats', 'seat ' .. id .. ' free (nobody on it)')
    sl.locked, sl.lockTimer, sl.elecSeen = false, 0, e
    setSeatStiff(sl, false)
  end
  local theta = hinge.geom(d)
  if not theta then return false end
  local folded = theta > d.cfg.springs.mid
  if e ~= sl.elecSeen then                    -- set from outside: fold / unfold
    sl.elecSeen = e
    if (e > 0) ~= folded and not d.active then hinge.startAuto(d, e > 0 and "open" or "close") end
  elseif not d.active and not d.auto then     -- settled: the input follows the backrest
    local want = folded and 1 or 0
    if want ~= e then electrics.values[sl.elec], sl.elecSeen = want, want end
  end
  return false
end

local SEAT_HOOKS = {blocked = function(d) return seatLocked(d.id) end, update = updateSeatLock}

local function frontSeat(s)
  return {
    hinge = {"is" .. s .. "4i", "is" .. s .. "4o"}, ref = "is" .. s .. "1i",   -- pivot / front cushion node
    handle = {{"is" .. s .. "5i", 0.5}, {"is" .. s .. "5o", 0.5}},           -- top of the backrest
    breakGroups = {},
    massNodes = {"is" .. s .. "5i", "is" .. s .. "5o", "is" .. s .. "6i", "is" .. s .. "6o"},
    lock = "seat" .. s .. "backrest", seatId = s,  -- backrest hydro input, seat id of the game's occupant system
    springs = {mid = math.rad(SEAT_FRONT_FULL_DEG * SEAT_FRONT_MID_FRACTION), tOpen = SEAT_FRONT_T_OPEN,
               tClose = SEAT_FRONT_T_CLOSE, width = SEAT_T_WIDTH, damp = SEAT_FRONT_DAMP,
               throw = SEAT_THROW_SPEED, throwDamp = SEAT_THROW_DAMP},
    dragMaxForce = SEAT_DRAG_MAX_FORCE, dragSpring = SEAT_DRAG_SPRING, dragDamp = SEAT_DRAG_DAMP, autoGain = SEAT_AUTO_GAIN, autoMaxForce = SEAT_AUTO_MAX_FORCE,
    autoCloseSpeed = SEAT_AUTO_CLOSE_SPEED, screenFree = true,
    maxDeg = 50,
    autoOpenDeg = SEAT_FRONT_FULL_DEG * SEAT_FRONT_MID_FRACTION + 8,
    hooks = SEAT_HOOKS,
  }
end
SEATS.seatFL = frontSeat("FL")
SEATS.seatFR = frontSeat("FR")
for id, cfg in pairs(SEATS) do hinge.register(id, cfg) end

-- backrest trigger press (value 1) / release (value 0): hold + drag swings it, double-click folds / unfolds it;
-- nothing while someone sits there
local function fold(id, value)
  hinge.press(id, value)
end
-- fold / unfold it automatically, without a trigger
local function foldToggle(id)
  hinge.toggle(id)
end

-- called from vehicle.updateGFX / onReset
local function update(dt)
  pollOccupiedSeats(dt)
end
local function reset()
  seatLocks = {}   -- the reset restored the hydros' springs from the jbeam: stiff, like a new lock
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
M.update          = update
M.reset           = reset
M.moveSeat        = moveSeat
M.fold            = fold
M.foldToggle      = foldToggle
M.setOccupiedSeats = setOccupiedSeats   -- from GE (pollOccupiedSeats)

return M
