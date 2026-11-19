-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- WORK MODE CAMERA (Bug mod, proof of concept)
-- Looks at the engine bay of a Bug while the work mode is active (GE extension bug_worktop). Global and hidden,
-- like the game's partFocus camera: it never appears in the camera cycle, bug_worktop switches to it and back.
-- The game loads every file in lua/ge/extensions/core/cameraModes/ as a camera mode (core/camera.lua).
--
-- bug_worktop owns the view: it applies the orbit (right mouse button) and zoom (mouse wheel) input and keeps the
-- camera outside the car. This camera only places itself there, relative to the car's heading, and eases the
-- view a little so the engine's idle shake and the jumps back inside the limits stay smooth.

local C = {}
C.__index = C

function C:init()
  self.isGlobal = true
  self.hidden = true

  self.fov = 45
  self.followRate = 12     -- 1/s smoothing of the focus point (the engine shakes a little at idle)
  self.viewRate = 14       -- 1/s smoothing of yaw / pitch / distance
  self.currentFocus = nil
  self.currentView = nil   -- {yaw, pitch, dist}
end

function C:setCustomData(data)
  -- snap to the new target; the global camera transition blends the view
  self.currentFocus = nil
  self.currentView = nil
end

function C:reset()
  self.currentFocus = nil
  self.currentView = nil
end

function C:update(data)
  data.res.collisionCompatible = false  -- the camera sits close to the open engine bay

  local dt = math.min(data.dt or 0, 0.1)
  local driver = extensions.bug_worktop
  if not driver then return false end
  -- read here, not in the driver's onUpdate: the game's mouse look input (MoveManager) is reset right after the
  -- camera update
  local focus, fwd, up, yaw, pitch, dist = driver.getCameraTarget(dt)
  if not focus then return false end  -- false: the game drops this camera and falls back to the normal one

  local k = math.min(1, dt * self.followRate)
  if not self.currentFocus then
    self.currentFocus = vec3(focus)
  else
    self.currentFocus = self.currentFocus + (focus - self.currentFocus) * k
  end
  local cv = self.currentView
  if not cv then
    cv = {yaw = yaw, pitch = pitch, dist = dist}
    self.currentView = cv
  else
    local kv = math.min(1, dt * self.viewRate)
    cv.yaw = cv.yaw + (yaw - cv.yaw) * kv
    cv.pitch = cv.pitch + (pitch - cv.pitch) * kv
    cv.dist = cv.dist + (dist - cv.dist) * kv
  end

  -- car axes: rear = -forward, left (+x in jbeam coordinates) = up x forward
  local left = up:cross(fwd)
  local y, p = math.rad(cv.yaw), math.rad(cv.pitch)
  local dir = (-fwd * math.cos(y) + left * math.sin(y)) * math.cos(p) + up * math.sin(p)
  local camPos = self.currentFocus + dir * cv.dist

  data.res.pos = camPos
  data.res.rot = quatFromDir(self.currentFocus - camPos, up)
  data.res.fov = self.fov

  return driver.isActive()
end

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
