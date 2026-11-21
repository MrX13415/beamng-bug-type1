-- Radio mouse-wheel interaction.
-- Owns knob geometry and camera-ray hit testing; the radio controller owns radio state.

local M = {}

local misc = require("vehicles/bug/lua/misc")

local WHEEL_HIT_RADIUS = 0.11

local KNOBS = {
  volume = vec3(0.0608, -0.1280, -0.0635),
  tune = vec3(-0.0758, -0.1280, -0.0635),
}

local function nodeWorldPos(nodeName)
  local nodeId = misc.getNodeIDbyName(nodeName)
  if not nodeId then return nil end
  return vec3(obj:getPosition()) + vec3(obj:getNodePosition(nodeId))
end

local function getFrame()
  local a = nodeWorldPos("dsh")
  local b = nodeWorldPos("dshl")
  local c = nodeWorldPos("dsh2")
  if not a or not b or not c then return nil end

  local ex = (b - a):normalized()
  local ey = c - a
  ey = (ey - ex * ey:dot(ex)):normalized()
  local ez = ex:cross(ey)

  return {origin = a, ex = ex, ey = ey, ez = ez}
end

local function knobWorldPos(localPos)
  local f = getFrame()
  if not f then return nil end
  return f.origin + f.ex * localPos.x + f.ey * localPos.y + f.ez * localPos.z
end

local function geCall(fn, cmd)
  misc.geCall("bug_doorDrag", cmd, fn)
end

local function wheel(value)
  if not value or value == 0 then return end
  local steps = value > 0 and 1 or -1
  geCall("wheelRay", string.format("bug_doorDrag.wheelRay(%d, %d, 'vehicle.radioWheelRay')", obj:getId(), steps))
end

local function wheelRay(steps, px, py, pz, dx, dy, dz)
  local origin = vec3(px, py, pz)
  local direction = vec3(dx, dy, dz):normalized()

  local bestKind, bestDistance = nil, WHEEL_HIT_RADIUS
  for kind, localPos in pairs(KNOBS) do
    local center = knobWorldPos(localPos)
    if center then
      local t = (center - origin):dot(direction)
      if t > 0.05 and t < 3 then
        local distance = (origin + direction * t - center):length()
        if distance < bestDistance then
          bestKind, bestDistance = kind, distance
        end
      end
    end
  end

  if not bestKind then return end
  geCall("wheelHide", "bug_doorDrag.wheelHide(0.6)")

  local radio = controller.getControllerSafe("radio")
  if not radio then return end
  if bestKind == "volume" then
    radio.volumeAxis(steps)
  else
    radio.tuneAxis(steps)
  end
end

M.wheel = wheel
M.wheelRay = wheelRay

return M
