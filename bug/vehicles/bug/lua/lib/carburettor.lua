-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- The carburettor, vehicle side: its moving parts and what other code may do to it.
--
-- Its conditions and physics are in the car condition model (bug/condition/subsystems/carburettor, plain Lua): the
-- idle screw, the idle jet, the throttle lever with its return spring. This file holds no state of the car: it reads
-- and writes the carburettor's slice of the model (carcondition.getModel():state("carburettor")) and shows it on
-- the car:
--   - update(dt), every frame, driven by carcondition.lua before the model runs (the model's fixed tick is too
--     coarse for moving parts):
--       carbThrottle  how far the throttle lever is open. The single carburettor part makes the engine read it as
--                     its throttle (mainEngine.electricsThrottleName), and the lever, pump rod and return spring
--                     follow it. The accelerator cable (the driver's throttle) and a hand in the work mode pull the
--                     lever open; it springs back by itself (stepLever in the model).
--       carbIdleScrew the idle screw's turns, for its mesh
--       carbChoke     the automatic choke's flap (0 open … 1 shut), for the stepped cam and the operating lever
--       carbChokeCover the choke cover's degrees from the factory mark, for its mesh
--       carbChokeScrewTop / Left / Right  turns each screw of the cover's retaining ring is out, for their meshes
--       carbChokeRing 1: the retaining ring's prop, whose pose is set here (updateRing)
--       the arcs of the accelerator pump rod and the throttle cable (updateLinkage)
--   - for the work mode (lib/workmode.lua): isInstalled, setHandThrottle, leverOpening, turnIdleScrew,
--     idleTargetRpm, turnChokeScrew, chokeScrewTurns, turnChokeCover, chokeCoverDeg, chokeCoverLoose.
--
-- Like every file in lua/, the game loads it as a vehicle extension too; it exports no game hook names, so only
-- carcondition.lua drives it.

local M = {}

local storage = require("vehicles/bug/lua/lib/storage")
local carburettorModel = require("bug/condition/subsystems/carburettor")

local BODY_MESH = "carb_body"     -- flexbody of the single Solex carburettor (bug_intake, bug_intake_D)
local SCREW_EVENT_COALESCE = 10   -- s, the notches of one adjustment become one event in the car's history

-- carcondition.lua requires this file, so it is required here only when it's needed (no require loop)
local function carcondition() return require("vehicles/bug/lua/carcondition") end

local function slice(model)
  return (model or carcondition().getModel()):state("carburettor")
end

-- ---- parts hanging on the throttle lever --------------------------------------------------------------------------

-- The accelerator pump rod (prop carb_accelerator_rod) hangs on the pump arm 1 cm below the throttle shaft, and the
-- throttle cable (prop carb_throttle_cable) is clamped to the lever's lower arm: the point where each hangs goes
-- round the shaft with the lever while the part keeps its direction (it moves, it doesn't turn). A prop only moves
-- along one fixed direction (translation × value), so every frame its translation is set to "where the arc puts
-- that point now, divided by the value": the game's props.lua multiplies prop.translation by the value every frame
-- (lib/horn.lua sets its ring's prop data per frame the same way). The angle is the lever prop's own (rotation × its
-- clamped value), so the parts and the lever always agree. Prop translations are in the prop's axes: x = idRef →
-- idX and y = idRef → idY as whole node vectors, z = y × x normalized (meters), as the game's
-- jbeam/sections/meshs.lua sets them up. The jbeam's own translations only go straight to the arc's end point.
local LEVER_MESH = "carb_throttle_lever"
local SHAFT = vec3(0.07052425, 1.611764, 0.6456638)   -- the lever's origin in engine/Carburettor.dae
-- where each part hangs on the lever, minus the shaft (car coordinates at rest)
local FOLLOWERS = {
  carb_accelerator_rod = vec3(-0.01262395, 1.612181, 0.6357272) - SHAFT,   -- the rod's origin
  carb_throttle_cable  = vec3(0.0626, 1.6250, 0.6283) - SHAFT,             -- the middle of the cable's clamp
}
local linkage = nil   -- {lever = prop data, parts = {{prop, arm, toProp}}}, false = not installed

local function propValue(p)   -- a prop's value as props.lua uses it
  local val = (electrics.values[p.func] or 0) * (p.multiplier or 1)
  return math.min(math.max(val, p.min or 0), p.max or 100) + (p.offset or 0)
end

-- car offset → the prop's translation units (inverse of the matrix with columns ax, ay, az)
local function propUnits(p)
  local function pos(cid) local q = v.data.nodes[tonumber(cid)].pos; return vec3(q.x, q.y, q.z) end
  local o = pos(p.idRef)
  local ax, ay = pos(p.idX) - o, pos(p.idY) - o
  local az = ay:cross(ax):normalized()
  local yz, zx, xy = ay:cross(az), az:cross(ax), ax:cross(ay)
  local det = ax:dot(yz)
  return function(d) return d:dot(yz) / det, d:dot(zx) / det, d:dot(xy) / det end
end

local function findLinkage()
  local lever, parts = nil, {}
  for _, p in pairs(v.data.props or {}) do
    local mesh = p.originalMesh or p.mesh     -- the game may rename a prop's mesh when it loads it
    if mesh == LEVER_MESH then
      lever = p
    elseif FOLLOWERS[mesh] and p.translation then
      parts[#parts + 1] = {prop = p, arm = FOLLOWERS[mesh], toProp = propUnits(p)}
    end
  end
  if not (lever and lever.rotation and #parts > 0) then return false end
  return {lever = lever, parts = parts}
end

local function updateLinkage()
  if linkage == nil then linkage = findLinkage() end
  if not linkage then return end
  local th = (linkage.lever.rotation.x or 0) * propValue(linkage.lever)   -- radians once loaded, right-handed about x
  local c, s = math.cos(th), math.sin(th)
  for _, part in ipairs(linkage.parts) do
    local r = part.arm
    local offset = vec3(0, r.y * c - r.z * s - r.y, r.y * s + r.z * c - r.z)
    local val, t = propValue(part.prop), part.prop.translation
    if math.abs(val) < 1e-4 then
      t.x, t.y, t.z = 0, 0, 0
    else
      local x, y, z = part.toProp(offset)
      t.x, t.y, t.z = x / val, y / val, z / val
    end
  end
end

-- ---- the choke cover's retaining ring ---------------------------------------------------------------------------

-- The ring is held by three screws. The model says how far it has lifted off its seat at each screw (outward along
-- the choke's axis, which is the car's x axis; outward is -x on this side of the carburettor) and how far it has
-- dropped in its holes (ringPose). Three lifts define a plane: the ring moves out by the plane's lift at its centre
-- and tilts by the plane's slope, about its own origin (its pivot, the choke's axis). A prop can only turn and move
-- by fixed amounts times its value, so its rotation (radians, as the game keeps it once loaded) and translation are
-- set here every frame with the value 1, as for the pump rod. Rotations are right-handed about the prop's axes:
-- y = e2r → e4r (up), z = y × x (to the rear). A lift that grows to the rear (+y) is a turn about up (y), one that
-- grows upwards (+z) a turn the other way about the rear axis (z). The tilts are a few degrees at most, so their order
-- doesn't matter. The throttle lever shows that a turn about the prop's x axis is right-handed in car coordinates; for y
-- and z that is assumed (RING_TILT flips one if the ring tilts into its seat instead of out of it in game).
local RING_MESH = "carb_choke_retaining_ring"
local RING_ORIGIN = vec3(-0.0458, 1.6087, 0.7220)   -- in engine/Carburettor.dae
local RING_SCREWS = {                                -- the screws' axes (y, z), car coordinates (their origins)
  top   = {1.6089, 0.7494},
  left  = {1.6320, 0.7086},
  right = {1.5873, 0.7063},
}
local RING_TILT = {y = 1, z = 1}                     -- direction of the turns about the prop's y and z axes
local RING_SHAKE_RPM = 300                           -- rpm: above this the engine runs and shakes the loose ring
local ring = nil   -- {prop, toProp, inv = 3×3 inverse of the screws' plane rows}, false = not installed

local function inverse3(m)
  local a, b, c = m[1][1], m[1][2], m[1][3]
  local d, e, f = m[2][1], m[2][2], m[2][3]
  local g, h, i = m[3][1], m[3][2], m[3][3]
  local A, B, C = e * i - f * h, -(d * i - f * g), d * h - e * g
  local det = a * A + b * B + c * C
  return {
    {A / det, -(b * i - c * h) / det, (b * f - c * e) / det},
    {B / det, (a * i - c * g) / det, -(a * f - c * d) / det},
    {C / det, -(a * h - b * g) / det, (a * e - b * d) / det},
  }
end

local function findRing()
  for _, p in pairs(v.data.props or {}) do
    if (p.originalMesh or p.mesh) == RING_MESH and p.rotation and p.translation then
      -- lift = l0 + gy · (y - y0) + gz · (z - z0) through the three screws
      local rows = {}
      for i, id in ipairs(carburettorModel.CHOKE_SCREWS) do
        local q = RING_SCREWS[id]
        rows[i] = {1, q[1] - RING_ORIGIN.y, q[2] - RING_ORIGIN.z}
      end
      return {prop = p, toProp = propUnits(p), inv = inverse3(rows)}
    end
  end
  return false
end

local function updateRing(carb, dt)
  electrics.values.carbChokeRing = 1
  if ring == nil then ring = findRing() end
  if not ring then return end
  carburettorModel.stepRing(carb, dt, (electrics.values.rpm or 0) > RING_SHAKE_RPM and 1 or 0)
  local lift, drop = carburettorModel.ringPose(carb)
  local l = {}
  for i, id in ipairs(carburettorModel.CHOKE_SCREWS) do l[i] = lift[id] end
  local inv = ring.inv
  local l0 = inv[1][1] * l[1] + inv[1][2] * l[2] + inv[1][3] * l[3]
  local gy = inv[2][1] * l[1] + inv[2][2] * l[2] + inv[2][3] * l[3]
  local gz = inv[3][1] * l[1] + inv[3][2] * l[2] + inv[3][3] * l[3]
  local r, t = ring.prop.rotation, ring.prop.translation
  -- outward is -x: a point moves by -lift, so a slope gy along y is a turn of gy about up, gz along z one of -gz
  -- about the rear axis
  r.x, r.y, r.z = 0, RING_TILT.y * gy, -RING_TILT.z * gz
  local x, y, z = ring.toProp(vec3(-l0, 0, -drop))
  t.x, t.y, t.z = x, y, z
end

-- ---- every frame ------------------------------------------------------------------------------------------------

-- driven by carcondition.lua with this car's model, before the model runs
local function update(dt, model)
  local carb = slice(model)
  if not carb then return end
  electrics.values.carbThrottle = carburettorModel.stepLever(carb, dt, electrics.values.throttle or 0)
  electrics.values.carbIdleScrew = carb.idleScrewTurns
  electrics.values.carbChoke = carburettorModel.chokeClosure(carb)
  electrics.values.carbChokeCover = carb.chokeCoverDeg
  electrics.values.carbChokeScrewTop = carb.chokeScrews.top
  electrics.values.carbChokeScrewLeft = carb.chokeScrews.left
  electrics.values.carbChokeScrewRight = carb.chokeScrews.right
  updateLinkage()
  updateRing(carb, dt)
end

-- ---- for the work mode ------------------------------------------------------------------------------------------

-- the single carburettor is installed (the dual carburettors have no work mode yet)
local function isInstalled()
  for _, fb in pairs(v.data.flexbodies or {}) do
    if fb.mesh == BODY_MESH then return true end
  end
  return false
end

-- a hand holds the throttle lever at `opening` (0 … 1), nil lets it go
local function setHandThrottle(opening)
  local carb = slice()
  if carb then carburettorModel.setHand(carb, opening) end
end

-- how far the throttle lever is open now (0 … 1)
local function leverOpening()
  local carb = slice()
  return carb and carb.lever or 0
end

-- turns the idle screw (+ = in), returns true if it moved
local function turnIdleScrew(turns)
  local carb = slice()
  if not carb then return false end
  local moved = carburettorModel.turnIdleScrew(carb, turns)
  if moved then
    storage.markDirty()
    storage.event("adjust", { part = "carburettor", idleScrewTurns = carb.idleScrewTurns }, SCREW_EVENT_COALESCE)
    carcondition().refreshEffects()   -- the idle speed follows at once, not only on the model's next tick
  end
  return moved
end

-- the idle speed the engine is set to now, rpm (nil before the engine is known)
local function idleTargetRpm() return carcondition().idleTargetRpm() end

-- turns a screw of the choke cover's retaining ring (id: top, left, right; + = out), returns true if it moved
local function turnChokeScrew(id, turns)
  local carb = slice()
  if not carb then return false end
  local moved = carburettorModel.turnChokeScrew(carb, id, turns)
  if moved then
    storage.markDirty()
    storage.event("adjust", { part = "carburettor", chokeScrew = id, turns = carb.chokeScrews[id] }, SCREW_EVENT_COALESCE)
  end
  return moved
end

-- turns out of a ring screw (0 = tight)
local function chokeScrewTurns(id)
  local carb = slice()
  return carb and carb.chokeScrews[id] or 0
end

-- turns the choke cover (+ = richer), returns true if it moved (it is clamped while a ring screw is tight)
local function turnChokeCover(deg)
  local carb = slice()
  if not carb then return false end
  local moved = carburettorModel.turnChokeCover(carb, deg)
  if moved then
    storage.markDirty()
    storage.event("adjust", { part = "carburettor", chokeCoverDeg = carb.chokeCoverDeg }, SCREW_EVENT_COALESCE)
    carcondition().refreshEffects()   -- fast idle follows at once
  end
  return moved
end

-- the choke cover's degrees from the factory mark, and whether the ring lets it turn
local function chokeCoverDeg()
  local carb = slice()
  return carb and carb.chokeCoverDeg or 0
end
local function chokeCoverLoose()
  local carb = slice()
  return carb ~= nil and carburettorModel.coverLoose(carb)
end

M.update          = update
M.isInstalled     = isInstalled
M.setHandThrottle = setHandThrottle
M.leverOpening    = leverOpening
M.turnIdleScrew   = turnIdleScrew
M.idleTargetRpm   = idleTargetRpm
M.turnChokeScrew  = turnChokeScrew
M.chokeScrewTurns = chokeScrewTurns
M.turnChokeCover  = turnChokeCover
M.chokeCoverDeg   = chokeCoverDeg
M.chokeCoverLoose = chokeCoverLoose

return M
