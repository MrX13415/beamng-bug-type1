-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Window crank interaction (inside door panel).
--
--   * click + hold, then circle the mouse around the crank: the crank follows the cursor and the window
--     moves with it. The turning direction decides up or down (2200 degrees of crank = full travel,
--     same as the crank prop anim__windowFX_state).
--   * double-click: the old click behaviour on the second click (a quick click rolls the window fully
--     open / closed, holding it rolls the window down while held). With shift (or the middle mouse button)
--     the second click goes the other way (holding rolls the window up).
--
-- The trigger only reports press (1) / release (0). While the crank is held, the GE extension
-- "bug_doorDrag" (lua/ge/extensions/bug/doorDrag.lua) sends the mouse cursor ray every frame
-- (setRay); here it is intersected with the plane of the crank and turned into a crank angle.

local M = {}

local misc = require("vehicles/bug/lua/misc")

-- Tuning
local CRANK_DEG_FULL    = 2200  -- deg    crank rotation for the full window travel (prop anim__windowFX_state)
local CRANK_FLIP        = 1     -- set to -1 if the crank turns against the mouse in game
local CLICK_MAX_TIME    = 0.25  -- s      shorter press ...
local CLICK_MAX_ANGLE   = math.rad(20) -- ... with less turning = click
local DOUBLE_CLICK_TIME = 0.4   -- s      max time between two clicks
local MIN_RADIUS        = 0.012 -- m      ignore the cursor right at the crank axis (angle undefined)
local KNOB_OFFSET       = 0.036 -- m      the knob turns in a plane this far in front of the crank pivot (towards the cabin)
--local WHEEL_STEP_DEG    = 90 -- old: far too much per step
local WHEEL_STEP_DEG    = 15    -- deg    crank rotation per mouse wheel step, about one wheel notch (up = window down)
local WHEEL_SPEED_DEG   = 720   -- deg/s  how fast the crank works off the wheel steps
local WHEEL_HIT_RADIUS  = 0.11  -- m      the cursor ray must pass this close to the knob circle's center
local CRANK_FOLLOW      = 25    -- 1/s    how quickly the crank turns to point at the cursor (smoothing)
local CRANK_MAX_SPEED   = math.rad(1440) -- rad/s  fastest hand cranking (4 turns per second)

-- Crank pivot and axis from the mesh (Bug.Interior.dae, nodes bug_door_FX_window_handle).
-- The axis points from the door into the cabin. openSign: direction of the window opening around that axis,
-- checked in game (the right crank with +1 turned against the mouse, the left one with -1 is right).
local CRANKS = {
  FL = {pivot = vec3( 0.569455, -0.433496, 0.854318), axis = vec3(-0.990236, 0.083219, -0.111835),
        nodes = {"d14l", "d8l", "d11l"}, openSign = -1},
  FR = {pivot = vec3(-0.569455, -0.433496, 0.854318), axis = vec3( 0.990236, 0.083219, -0.111835),
        --nodes = {"d14r", "d8r", "d11r"}, openSign = 1}, -- old: turned against the mouse in game
        nodes = {"d14r", "d8r", "d11r"}, openSign = -1},
}

local cranks = {}   -- runtime state per id
local clock = 0

local function nodeWorldPos(cid)
  return obj:getPosition() + obj:getNodePosition(cid)
end

-- orthonormal frame from three points
local function frame(a, b, c)
  local ex = (b - a):normalized()
  local ey = (c - a)
  ey = (ey - ex * ey:dot(ex)):normalized()
  return ex, ey, ex:cross(ey)
end

local function getCrank(id)
  local k = cranks[id]
  if k then return k end
  local def = CRANKS[id]
  if not def then return nil end
  local cids = {}
  for i, n in ipairs(def.nodes) do
    cids[i] = misc.getNodeIDbyName(n)
    if not cids[i] then return nil end
  end
  -- express pivot and axis in the door's node frame (spawn positions), so they follow the door
  local p = {}
  for i = 1, 3 do local q = v.data.nodes[cids[i]].pos; p[i] = vec3(q.x, q.y, q.z) end
  local ex, ey, ez = frame(p[1], p[2], p[3])
  -- the cursor is measured around the center of the knob's circle, not the pivot at the panel: seen from the
  -- seat the circle is almost edge-on, and the 3.6 cm offset made the crank race one way and lag the other
  --local rp, ax = def.pivot - p[1], def.axis:normalized() -- old
  local ax = def.axis:normalized()
  local rp = def.pivot + ax * KNOB_OFFSET - p[1]
  k = {cids = cids, openSign = def.openSign,
       pivotL = {rp:dot(ex), rp:dot(ey), rp:dot(ez)},
       axisL  = {ax:dot(ex), ax:dot(ey), ax:dot(ez)},
       mode = nil, angle = nil, target = nil, value = 0, turned = 0, pressTime = 0, lastClick = -1}
  cranks[id] = k
  return k
end

-- current pivot and axis in world space
local function crankPose(k)
  local a = nodeWorldPos(k.cids[1])
  local ex, ey, ez = frame(a, nodeWorldPos(k.cids[2]), nodeWorldPos(k.cids[3]))
  local pivot = a + ex * k.pivotL[1] + ey * k.pivotL[2] + ez * k.pivotL[3]
  local axis = (ex * k.axisL[1] + ey * k.axisL[2] + ez * k.axisL[3]):normalized()
  return pivot, axis
end

local function windowController(id)
  return controller.getController("window" .. id)
end

-- fn: the bug_doorDrag function that is called (skipped if the extension doesn't have it).
-- Loading and the version check are in misc.geCall.
local function geCall(fn, cmd)
  misc.geCall("bug_doorDrag", cmd, fn)
end

-- trigger press (1) / release (0); reverse = shift / middle mouse button
local function press(id, value, reverse)
  local k = getCrank(id)
  local wc = windowController(id)
  if not k or not wc then return end

  if value and value > 0 then
    if k.mode then return end
    if clock - k.lastClick <= DOUBLE_CLICK_TIME then
      -- second click: old behaviour (quick click = roll fully open/closed, hold = roll while held)
      k.lastClick = -1
      k.mode = reverse and "close" or "open"
      wc[k.mode](1)
    else
      k.mode, k.angle, k.target, k.turned, k.pressTime = "crank", nil, nil, 0, 0
      k.wheelPending, k.wheelActive = 0, false   -- a drag takes over from the wheel
      k.value = electrics.values["window" .. id .. "_state"] or 0
      if wc.crankStart then wc.crankStart() end
      geCall("startRay", string.format("bug_doorDrag.startRay(%d, %q, 'vehicle.windowCrankRay')", obj:getId(), id))
    end
  else
    local mode = k.mode
    if not mode then return end
    k.mode = nil
    if mode == "crank" then
      geCall("stopRay", string.format("bug_doorDrag.stopRay(%d, %q)", obj:getId(), id))
      if wc.crankStop then wc.crankStop() end
      if k.pressTime <= CLICK_MAX_TIME and math.abs(k.turned) <= CLICK_MAX_ANGLE then
        k.lastClick = clock
      end
    else
      wc[mode](0)
    end
  end
end

-- cursor ray from the GE extension, every frame while the crank is held.
-- The crank points at the cursor as the player sees it: the cursor and the crank circle are both
-- projected onto the view plane through the pivot (perpendicular to the line of sight), and the crank
-- angle is the one whose (elliptical) projection points at the cursor. So the crank follows the cursor
-- evenly from any viewing angle and at any distance; updateGFX turns it there smoothly.
local function setRay(id, px, py, pz, dx, dy, dz)
  local k = cranks[id]
  if not k or k.mode ~= "crank" then return end

  local pivot, axis = crankPose(k)
  local pos, dir = vec3(px, py, pz), vec3(dx, dy, dz)

  -- crank plane basis: angle 0 = up, counterclockwise seen from inside the cabin
  local up = vec3(0, 0, 1)
  local e1 = (up - axis * up:dot(axis)):normalized()
  local e2 = axis:cross(e1)

  -- view plane through the pivot
  local view = pivot - pos
  if view:length() < 1e-3 then return end
  view = view:normalized()
  local denom = dir:dot(view)
  if denom < 0.1 then return end
  local c = pos + dir * ((pivot - pos):dot(view) / denom) - pivot
  if c:length() < MIN_RADIUS then return end
  local u = up - view * up:dot(view)
  if u:length() < 1e-3 then u = e1 - view * e1:dot(view) end
  u = u:normalized()
  local w = view:cross(u)

  -- projected crank basis A = [e1' e2'], solve A * (cos, sin) ~ cursor
  local a1, b1 = e1:dot(u), e1:dot(w)
  local a2, b2 = e2:dot(u), e2:dot(w)
  local cx, cy = c:dot(u), c:dot(w)
  local det = a1 * b2 - a2 * b1
  local angle
  if math.abs(det) > 0.05 then
    angle = math.atan2((a1 * cy - b1 * cx) / det, (b2 * cx - a2 * cy) / det)
  else
    -- looking (almost) along the crank plane: use the cursor's hit point on the crank plane
    local dn = dir:dot(axis)
    if math.abs(dn) < 1e-3 then return end
    local r = pos + dir * ((pivot - pos):dot(axis) / dn) - pivot
    angle = math.atan2(r:dot(e2), r:dot(e1))
  end
  k.target = angle
end

--[[ old: angle of the cursor's hit point on the crank plane, applied as a change of angle. Very uneven
--   seen at a slant (the crank plane is seen almost edge-on from the seat) and only near the crank.
local function setRay(id, px, py, pz, dx, dy, dz)
  local k = cranks[id]
  if not k or k.mode ~= "crank" then return end
  local wc = windowController(id)
  if not wc or not wc.crank then return end

  local pivot, axis = crankPose(k)
  local pos, dir = vec3(px, py, pz), vec3(dx, dy, dz)
  local denom = dir:dot(axis)
  if math.abs(denom) < 0.05 then return end   -- looking along the crank plane
  local t = (pivot - pos):dot(axis) / denom
  if t <= 0 then return end
  local r = pos + dir * t - pivot
  r = r - axis * r:dot(axis)
  if r:length() < MIN_RADIUS or r:length() > 0.5 then return end

  -- angle around the axis (counterclockwise seen from inside the cabin)
  local up = vec3(0, 0, 1)
  local e1 = up - axis * up:dot(axis)
  e1 = e1:normalized()
  local e2 = axis:cross(e1)
  local angle = math.atan2(r:dot(e2), r:dot(e1))

  if k.angle then
    local d = angle - k.angle
    if d > math.pi then d = d - 2 * math.pi elseif d < -math.pi then d = d + 2 * math.pi end
    k.turned = k.turned + d
    wc.crank(CRANK_FLIP * k.openSign * d / math.rad(CRANK_DEG_FULL))
  end
  k.angle = angle
end
--]]

-- turn the crank towards the cursor direction (smoothed, limited to a hand's speed and to the window travel)
local function turnCrank(id, k, dt)
  if not k.target then return end
  if not k.angle then k.angle = k.target return end   -- grabbed: start where the cursor is, no jump
  local wc = windowController(id)
  if not wc or not wc.crank then return end

  local d = k.target - k.angle
  d = (d + math.pi) % (2 * math.pi) - math.pi
  local step = d * math.min(1, CRANK_FOLLOW * dt)
  step = math.max(-CRANK_MAX_SPEED * dt, math.min(CRANK_MAX_SPEED * dt, step))
  if step == 0 then return end

  -- the window stops at its ends, and so does the crank
  local dv = CRANK_FLIP * k.openSign * step / math.rad(CRANK_DEG_FULL)
  local nv = math.max(0, math.min(1, k.value + dv))
  step = step * (nv - k.value) / dv
  wc.crank(nv - k.value)
  k.value = nv
  k.angle = k.angle + step
  k.turned = k.turned + step
end

-- Mouse wheel: the vehicle input action windowCrankWheel (inputmaps/mouse.vehicle.json, zaxis) calls wheel();
-- the GE extension answers with the cursor ray (wheelRay), and the crank under the cursor is turned.
local function wheel(value)
  log("D", "Bug:WindowCrank", "wheel action value " .. tostring(value))
  if not value or value == 0 then return end
  local steps = value > 0 and 1 or -1
  geCall("wheelRay", string.format("bug_doorDrag.wheelRay(%d, %d, 'vehicle.windowCrankWheelRay')", obj:getId(), steps))
end

local function wheelRay(steps, px, py, pz, dx, dy, dz)
  local O, dir = vec3(px, py, pz), vec3(dx, dy, dz):normalized()
  local bestId, bestDist = nil, WHEEL_HIT_RADIUS
  for id in pairs(CRANKS) do
    local k = getCrank(id)
    if k then
      local center = crankPose(k)
      local t = (center - O):dot(dir)
      if t > 0.05 and t < 3 then
        local dist = (O + dir * t - center):length()
        if dist < bestDist then bestId, bestDist = id, dist end
      end
    end
  end
  if not bestId then
    log("D", "Bug:WindowCrank", "wheel: cursor not on a crank")
    return
  end
  log("D", "Bug:WindowCrank", "wheel: crank " .. bestId .. " " .. tostring(steps))
  -- hide the hover tooltip while scrolling the crank
  geCall("wheelHide", "bug_doorDrag.wheelHide(0.6)")
  local k = cranks[bestId]
  if k.mode then return end   -- being clicked / dragged
  -- wheel up = crank forward = window down (opens)
  local v0 = electrics.values["window" .. bestId .. "_state"] or 0
  local pending = (k.wheelPending or 0) + steps * WHEEL_STEP_DEG / CRANK_DEG_FULL
  k.wheelPending = math.max(-v0, math.min(1 - v0, pending))
end

-- work off the wheel steps smoothly through the controller's crank mode
local function turnWheel(id, k, dt)
  local wc = windowController(id)
  if not wc or not wc.crank then k.wheelPending = 0 return end
  if math.abs(k.wheelPending) < 1e-5 then
    k.wheelPending = 0
    if k.wheelActive then
      k.wheelActive = false
      if wc.crankStop then wc.crankStop() end
    end
    return
  end
  if not k.wheelActive then
    k.wheelActive = true
    if wc.crankStart then wc.crankStart() end
  end
  local maxStep = WHEEL_SPEED_DEG / CRANK_DEG_FULL * dt
  local step = math.max(-maxStep, math.min(maxStep, k.wheelPending))
  wc.crank(step)
  k.wheelPending = k.wheelPending - step
end

local function updateGFX(dt)
  clock = clock + dt
  for id, k in pairs(cranks) do
    if k.mode == "crank" then
      k.pressTime = k.pressTime + dt
      turnCrank(id, k, dt)
    elseif k.wheelPending and (k.wheelPending ~= 0 or k.wheelActive) then
      turnWheel(id, k, dt)
    end
  end
end

local function onReset()
  for id, k in pairs(cranks) do
    if k.mode == "crank" then geCall("stopRay", string.format("bug_doorDrag.stopRay(%d, %q)", obj:getId(), id)) end
  end
  cranks = {}
end

M.press     = press
M.setRay    = setRay
M.wheel     = wheel
M.wheelRay  = wheelRay
M.updateGFX = updateGFX
M.onReset   = onReset

return M
