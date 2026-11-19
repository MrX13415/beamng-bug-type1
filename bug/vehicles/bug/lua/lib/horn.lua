-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Horn ring on the steering wheel (mesh bug_steeringwheel_horn, prop of the OEM steering wheels).
--
-- The horn sounds while the left mouse button is held on the horn ring: on the half ring or on the
-- left / right end of the cross bar. A click on the center of the wheel (emblem, middle of the bar) or
-- anywhere else inside the ring does nothing.
--
-- The triggers can't turn with the steering wheel (they are fixed to the steer nodes), so there is a
-- circle of small spheres at the radius of the horn ring all the way round (hornRing_0 .. 11 in
-- bug.interior.dashboard.steeringwheels.jbeam). On a press, the GE extension "bug_doorDrag" sends the
-- mouse cursor ray (startRay); here it is intersected with the plane of the horn ring, turned back by the
-- current steering wheel angle and checked against the ring's shape.
--
-- While the horn sounds, the ring tilts a little into the wheel on the side where it is pushed and springs
-- back on release. A prop only has one rotation, which the steering prop already uses. So while the ring is
-- tilted, its prop is switched to the electrics value bug_hornRingTilt (= 1) and its rotation is set every
-- frame to "steering turn, then tilt", converted to the prop's Euler order. The mesh's origin is the center
-- of the logo (Bug.Props.dae), so the ring tilts about the logo.
--
-- The game's own horn (H key, electrics.horn) tilts the ring as if its right end was pressed.

local M = {}

local misc = require("vehicles/bug/lua/misc")

-- Steering wheel pose from the mesh (Bug.Props.dae, node bug_steeringwheel), in vehicle coordinates
-- (bug_steeringwheel_horn has the same axes, its origin is 0.057 m further along AXIS at the logo). X / Y span the wheel plane at steering angle 0, AXIS points to the driver.
-- The half ring is on the +Y side (the lower half of the wheel), the cross bar along X.
local CENTER = vec3(0.2671823, -0.4863214, 0.875788)
local AXIS_X = vec3(1, 0, 0)
local AXIS_Y = vec3(0, 0.4539908, -0.8910064)
local AXIS   = vec3(0, 0.8910064, 0.4539908)
local NODES  = {"steer2", "steer3", "steer1"}   -- same nodes as the steering prop

-- Shape of the horn ring (mesh coordinates: ring r 0.110 .. 0.123 m, 0.109 .. 0.128 m in front of the wheel
-- origin; the bar is 0.058 m wide and reaches r 0.123 m)
local RING_HEIGHT  = 0.115  -- m  plane the cursor ray is intersected with (distance along AXIS)
local HIT_R_MIN    = 0.095  -- m  closer to the center: no horn (emblem, middle of the bar)
local HIT_R_MAX    = 0.140  -- m  further out: no horn (spokes / rim)
local HIT_BAR_HALF = 0.035  -- m  the ring side (+Y) counts, and on the other side this far from the bar (its ends)
local STEER_SIGN   = 1      -- electrics.values.steering > 0 turns the wheel counter-clockwise seen by the driver
                            -- (to the left). Set to -1 if the horn reacts where the ring was before turning.

-- Push animation
local TILT_DEG      = 2.5   -- deg  tilt of the pressed ring (about 5 mm at the ring's edge)
local TILT_TIME     = 0.04  -- s    time constant pressing in
local RETURN_TIME   = 0.07  -- s    time constant springing back
--local TILT_SIGN     = 1 -- old: in game a press at the bottom of the ring tilted the bottom out, towards the driver
local TILT_SIGN     = -1    -- flip if the ring tilts out towards the driver instead of into the wheel
                            -- (with TILT_MIRROR -1 as well, only the up / down direction is flipped: checked in game)
--local TILT_MIRROR   = 1 -- old: with TILT_SIGN -1, a press at the left / right end tilted that end out
local TILT_MIRROR   = -1    -- flip if the ring tilts in on the opposite side (left / right swapped)
local PROP_MESH     = "bug_steeringwheel_horn"
local TILT_ELECTRIC = "bug_hornRingTilt"
local KEY_PHI       = math.pi -- rad  where the game's horn (H key) presses the ring: its right end (mesh -X)

local frameL = nil  -- wheel pose in the steer node frame (spawn positions), so it follows the body
local pressed = false
local decided = false
local hornOn = false
local tilt = 0          -- deg, current
local tiltPhi = 0       -- rad, pushed position on the wheel (wheel frame, as in the mesh)
local tiltProp = nil    -- {prop, func, rotation, unit} while the prop is taken over

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

local function toLocal(vv, ex, ey, ez) return {vv:dot(ex), vv:dot(ey), vv:dot(ez)} end
local function fromLocal(l, ex, ey, ez) return ex * l[1] + ey * l[2] + ez * l[3] end

local function getFrame()
  if frameL then return frameL end
  local cids, p = {}, {}
  for i, n in ipairs(NODES) do
    cids[i] = misc.getNodeIDbyName(n)
    if not cids[i] then return nil end
    local q = v.data.nodes[cids[i]].pos
    p[i] = vec3(q.x, q.y, q.z)
  end
  local ex, ey, ez = frame(p[1], p[2], p[3])
  frameL = {cids = cids,
            center = toLocal(CENTER - p[1], ex, ey, ez),
            x = toLocal(AXIS_X, ex, ey, ez), y = toLocal(AXIS_Y, ex, ey, ez), axis = toLocal(AXIS, ex, ey, ez)}
  return frameL
end

local function setHorn(state)
  if hornOn == state then return end
  hornOn = state
  electrics.horn(state)
end

-- bug_doorDrag call (startRay / stopRay exist since version 8); loading and the version check are in misc.geCall
local function geCall(cmd)
  misc.geCall("bug_doorDrag", cmd, "startRay")
end

local function release()
  if pressed then
    geCall(string.format("bug_doorDrag.stopRay(%d, 'horn', 'vehicle.hornRingRay')", obj:getId()))
  end
  pressed, decided = false, false
  setHorn(false)
end

-- trigger press (1) / release (0)
local function press(value)
  if value and value > 0 then
    if pressed then return end
    pressed, decided = true, false
    geCall(string.format("bug_doorDrag.startRay(%d, 'horn', 'vehicle.hornRingRay')", obj:getId()))
  else
    release()
  end
end

-- is the cursor ray on the horn ring?
local function hitsRing(pos, dir)
  local f = getFrame()
  if not f then return false end
  local a = nodeWorldPos(f.cids[1])
  local ex, ey, ez = frame(a, nodeWorldPos(f.cids[2]), nodeWorldPos(f.cids[3]))
  local axis = fromLocal(f.axis, ex, ey, ez):normalized()
  local wx   = fromLocal(f.x, ex, ey, ez):normalized()
  local wy   = fromLocal(f.y, ex, ey, ez):normalized()
  local planePoint = a + fromLocal(f.center, ex, ey, ez) + axis * RING_HEIGHT

  local denom = dir:dot(axis)
  if math.abs(denom) < 1e-4 then return false end
  local t = (planePoint - pos):dot(axis) / denom
  if t <= 0 then return false end
  local d = pos + dir * t - planePoint
  local px, py = d:dot(wx), d:dot(wy)
  local r = math.sqrt(px * px + py * py)
  if r < HIT_R_MIN or r > HIT_R_MAX then return false end

  -- turn back by the steering wheel angle: position on the wheel as it is in the mesh
  local phi = math.atan2(py, px) - STEER_SIGN * math.rad(electrics.values.steering or 0)
  if r * math.sin(phi) < -HIT_BAR_HALF then return false end
  return true, phi
end

-- cursor ray from bug_doorDrag (every frame while held); only the first one decides
local function setRay(id, px, py, pz, dx, dy, dz)
  if not pressed or decided then return end
  decided = true
  local hit, phi = hitsRing(vec3(px, py, pz), vec3(dx, dy, dz):normalized())
  if hit then
    tiltPhi = phi
    setHorn(true)
  end
end

----------------------------------------------------------------------------------------------------
-- push animation

local function findProp()
  local props = v.data.props
  if not props then return nil end
  for _, prop in pairs(props) do
    if type(prop) == "table" and (prop.mesh == PROP_MESH or prop.originalMesh == PROP_MESH) then return prop end
  end
  return nil
end

-- take the prop over from the steering value / give it back
local function takeProp()
  if tiltProp then return tiltProp end
  local prop = findProp()
  if not prop or not prop.rotation or prop.func ~= "steering" then return nil end
  local r = prop.rotation
  -- the jbeam rotation is {"z":1} (per degree of steering); the game may hold it in radians or degrees
  local unit = math.abs(r.z or 0) > 0.5 and 180 / math.pi or 1
  tiltProp = {prop = prop, func = prop.func, rx = r.x, ry = r.y, rz = r.z, unit = unit, perDeg = r.z or 0}
  prop.func = TILT_ELECTRIC
  return tiltProp
end

local function releaseProp()
  if not tiltProp then return end
  local prop, r = tiltProp.prop, tiltProp.prop.rotation
  r.x, r.y, r.z = tiltProp.rx, tiltProp.ry, tiltProp.rz
  prop.func = tiltProp.func
  tiltProp = nil
end

-- 3x3 matrices as {{..},{..},{..}}
local function matMul(a, b)
  local m = {}
  for i = 1, 3 do
    m[i] = {}
    for j = 1, 3 do m[i][j] = a[i][1] * b[1][j] + a[i][2] * b[2][j] + a[i][3] * b[3][j] end
  end
  return m
end
local function rotZ(t) local c, s = math.cos(t), math.sin(t) return {{c, -s, 0}, {s, c, 0}, {0, 0, 1}} end
local function rotAxis(x, y, z, t) -- unit axis
  local c, s = math.cos(t), math.sin(t)
  local k = 1 - c
  return {{c + x * x * k,     x * y * k - z * s, x * z * k + y * s},
          {y * x * k + z * s, c + y * y * k,     y * z * k - x * s},
          {z * x * k - y * s, z * y * k + x * s, c + z * z * k}}
end

-- prop rotation (radians) for: steering turn, then the tilt in the wheel's own frame.
-- The game applies a prop's rotation as "-X -Z -Y intrinsic" (jbeam/sections/meshs.lua): M = Rx(-rx) Rz(-rz) Ry(-ry).
-- Its axes are taken as X = mesh X, Z = the turning axis of the wheel; a positive rz turns the wheel like
-- a positive steering value, i.e. about +AXIS by STEER_SIGN, so Z = -STEER_SIGN * AXIS and Y = Z x X.
local function tiltRotation(steerDeg, tiltDeg, phi)
  local sg = STEER_SIGN
  -- pushed point and the driver direction in the prop's axes (wheel at rest)
  local ux, uy = TILT_MIRROR * math.cos(phi), -sg * math.sin(phi)
  local ax, ay, az = 0, 0, -sg
  -- axis that moves the pushed point away from the driver: AXIS x u
  local wx, wy, wz = ay * 0 - az * uy, az * ux - ax * 0, ax * uy - ay * ux
  local wl = math.sqrt(wx * wx + wy * wy + wz * wz)
  if wl < 1e-9 then return 0, 0, math.rad(steerDeg) end
  local d = matMul(rotZ(-math.rad(steerDeg)), rotAxis(wx / wl, wy / wl, wz / wl, TILT_SIGN * math.rad(tiltDeg)))
  -- d = Rx(a) Rz(c) Ry(b). Of the two solutions take the one with c next to the steering angle (the wheel
  -- turns past +-90 deg), so a and b stay small tilts and nothing jumps when the prop is given back.
  local s = -math.rad(steerDeg)
  local c = math.asin(math.max(-1, math.min(1, -d[1][2])))
  if math.cos(s) < 0 then c = math.pi - c end
  c = c + 2 * math.pi * math.floor((s - c) / (2 * math.pi) + 0.5)
  local sc = math.cos(c) < 0 and -1 or 1
  local a = math.atan2(sc * d[3][2], sc * d[2][2])
  local b = math.atan2(sc * d[1][3], sc * d[1][1])
  return -a, -b, -c
end

local function approach(cur, target, dt)
  local tc = math.abs(target) > math.abs(cur) and TILT_TIME or RETURN_TIME
  return cur + (target - cur) * math.min(1, dt / tc)
end

local function update(dt)
  -- the game's horn (H key) without our mouse press: the ring tilts as if pressed at its right end
  local h = electrics.values.horn
  local keyHorn = (h == true or (type(h) == "number" and h > 0)) and not hornOn
  if keyHorn then tiltPhi = KEY_PHI end
  local tiltTarget = (hornOn or keyHorn) and TILT_DEG or 0
  if tilt == tiltTarget and not tiltProp then return end
  tilt = approach(tilt, tiltTarget, dt)
  if tiltTarget == 0 and tilt < 0.02 then
    tilt = 0
    releaseProp()
    return
  end
  local tp = takeProp()
  if not tp then return end
  electrics.values[TILT_ELECTRIC] = 1
  -- steering part exactly as the steering prop does it (rotation per degree * steering), the tilt on top
  local steer = (electrics.values.steering or 0) * (tp.perDeg / math.rad(1)) / tp.unit
  local rx, ry, rz = tiltRotation(steer, tilt, tiltPhi)
  local r = tp.prop.rotation
  r.x, r.y, r.z = rx * tp.unit, ry * tp.unit, rz * tp.unit
end

-- the game dropped the held trigger without a release
local function dragLost()
  release()
end

local function onReset()
  pressed, decided = false, false
  if hornOn then setHorn(false) end
  tilt = 0
  tiltProp = nil   -- the props are reset from the jbeam data
end

M.press    = press
M.setRay   = setRay
M.dragLost = dragLost
M.onReset  = onReset
M.update   = update   -- called from vehicle.updateGFX (not named updateGFX: the extension loader would call it too)

return M
