-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Work mode at the engine bay, vehicle side (proof of concept).
--
-- With the engine lid open, a click on the carburettor (interactor engineBayWork, part bug_intake) starts the work
-- mode. The GE extension bug_worktop (lua/ge/extensions/bug/worktop.lua) then takes over the camera, shows the
-- mouse cursor and the tool bar (ui/ui-vue/mods/bug_worktop), and handles the mouse wheel.
--
-- This side owns the car's geometry and state:
--   - while the mode is active it sends the camera focus point, the nodes that bound the view and the hotspots'
--     values (the idle speed, the lever's opening) to GE (30 Hz). The hotspots themselves (idle screw, throttle
--     lever) are interactors of the carburettor part (jbeam section "interactors", lib/interactors.lua): picking and
--     highlight are done by the GE extension bug_interact, the same way as for the click that starts this mode;
--   - the GE side calls turn(hotspot, steps) when the wheel is scrolled over a hotspot, and drag(hotspot, opening)
--     while a hotspot is dragged with the left mouse button (nil when it is let go);
--   - the idle screw of the Solex carburettor: turning it changes its condition in the engine model (lib/carburettor.lua),
--     which sets the idle speed; stalling at a too-low idle is also the engine model's job;
--   - Ctrl+R in the work mode reloads the car (GE side) and the work mode stays open: the reloaded car gets
--     resume(session) from GE, opens its engine lid (it comes back shut and locked), enters the work mode again
--     and tags its state with the session, so GE can tell its states from the old car's last ones;
--   - the throttle lever: dragging it holds it open by hand (carburettor.setHandThrottle), and the engine gets that
--     opening as its throttle; let go, it springs back.
-- The focus and the lever's drag geometry are defined in car coordinates (+x left, -y front) and follow the engine
-- through a frame of 3 engine nodes (the same e5 / e6 nodes exist on every engine variant).
--
-- This file keeps no conditions of the car, only the work mode's own geometry. Proof of concept: the engine model
-- isn't saved yet (a respawn starts at the factory idle setting again).

local M = {}

local misc = require("vehicles/bug/lua/misc")
local lids = require("vehicles/bug/lua/lib/lids")
local carburettor = require("vehicles/bug/lua/lib/carburettor")

local LID_MIN_DEG      = 35          -- deg   engine lid must be open at least this far to start the work mode
local SEND_INTERVAL    = 1 / 30      -- s     hotspot / focus update to GE while active
local FRAME_NODES      = {"e6l", "e6r", "e5l"}   -- origin, x direction, y direction (engine top, carb side)

-- camera focus: center of the carburettor body mesh (engine/Carburettor.dae, carb_body bounds)
local FOCUS = vec3(0.015, 1.578, 0.682)

-- nodes that bound the camera's orbit (GE side, bug_worktop): the body edges of the engine bay opening (top
-- left / right, bottom right / left) and the engine lid (hinge left / right, bottom edge). The camera stays in
-- front of the opening and the lid must not come between it and the carburettor. Missing nodes (other body,
-- no lid) just drop that limit.
local VIEW_NODES = {openTL = "br2ll", openTR = "br2rr", openBR = "br5rr", openBL = "br5ll",
                    lidHingeL = "th1l", lidHingeR = "th1r", lidEnd = "t4"}

-- hotspots: the work mode's interactors (ids, tools and labels in the carburettor part's jbeam; label text:
-- ui/ui-vue/mods/bug_worktop):
--   idleScrew      Solex 28 PICT idle speed (throttle stop) screw: mouse wheel with the screwdriver (turn below)
--   throttleLever  the upper arm of the throttle lever: drag it with the left mouse button to open the throttle by
--                  hand (bug_worktop sends the opening, see drag below); let go and it springs back
--   chokeScrewTop / Left / Right  the three screws of the automatic choke cover's retaining ring: mouse wheel with
--                  the screwdriver, a quarter turn per notch (wheel down = loosen)
--   chokeCover     the automatic choke's cover: mouse wheel by hand, 1° per notch (wheel up = richer). It only turns
--                  while all three ring screws are loose; the hotspot's value says so.
-- A hotspot's value for the tool bar is a string, or {key, n} for a text the UI translates (Worktop.vue).
-- For the drag, GE gets the lever's shaft and the arm's closed position (car coordinates here, sent in world space).
local LEVER_PIVOT = vec3(0.0705, 1.6118, 0.6457)  -- throttle shaft (carb_throttle_lever origin)
local LEVER_TOP   = vec3(0.0672, 1.6510, 0.7098)  -- center of the lever's upper arm, lever closed
local LEVER_MESH  = "carb_throttle_lever"

-- idle screw: one wheel notch = 1/8 turn; screwing in (wheel up) raises the idle speed. The screw's position is a
-- condition of the carburettor in the engine model (bug/condition/subsystems/carburettor), changed through lib/carburettor.lua.
local TURNS_PER_NOTCH = 1 / 8
local CHOKE_SCREW_TURNS_PER_NOTCH = 1 / 4
local CHOKE_COVER_DEG_PER_NOTCH = 1
local CHOKE_SCREWS = {chokeScrewTop = "top", chokeScrewLeft = "left", chokeScrewRight = "right"}

-- coming back after a reload (resume): open the engine lid after this delay (the physics settle first), and ask
-- again if it isn't open far enough after the retry time
local RESUME_LID_DELAY = 0.3         -- s
local RESUME_LID_RETRY = 4           -- s

local active = false
local sendTimer = 0
local session = nil       -- GE's reload session while coming back after a reload (sent with every state), else nil
local resumeTime = nil    -- s since resume() while waiting for the engine lid, else nil
local resumeLidAt = 0     -- resumeTime at which the lid is asked to open next
local frameCids = nil     -- {origin, x, y} node cids
local viewCids = nil      -- name → node cid of VIEW_NODES (the ones that exist)
local localPts = {}       -- name → {x, y, z} coordinates in the node frame
local toLocal = nil       -- car coordinates → node frame coordinates (set up once per spawn)
local leverDeg = nil      -- degrees the lever turns about the car's x axis at full opening (from its prop)

local function nodeWorldPos(cid) return obj:getPosition() + obj:getNodePosition(cid) end
local function jbeamPos(cid) local p = v.data.nodes[cid].pos; return vec3(p.x, p.y, p.z) end

local function frame(a, b, c)
  local ex = (b - a):normalized()
  local ey = (c - a)
  ey = (ey - ex * ey:dot(ex)):normalized()
  return ex, ey, ex:cross(ey)
end

-- node frame and the local coordinates of the focus and the lever's drag geometry (once per spawn)
local function setupGeometry()
  if frameCids then return frameCids ~= false end
  local cids = {}
  for i, name in ipairs(FRAME_NODES) do
    cids[i] = misc.getNodeIDbyName(name)
    if not cids[i] then
      log('W', 'bug.workmode', 'engine node ' .. name .. ' not found, work mode unavailable')
      frameCids = false
      return false
    end
  end
  local a = jbeamPos(cids[1])
  local ex, ey, ez = frame(a, jbeamPos(cids[2]), jbeamPos(cids[3]))
  toLocal = function(p) local r = p - a; return {r:dot(ex), r:dot(ey), r:dot(ez)} end
  localPts.focus = toLocal(FOCUS)
  localPts.leverPivot = toLocal(LEVER_PIVOT)
  localPts.leverAxis  = toLocal(LEVER_PIVOT + vec3(0.05, 0, 0))
  localPts.leverRest  = toLocal(LEVER_TOP)
  -- the drag turns the lever as its prop does: same angle at full opening
  -- (the game may rename a prop's mesh when it loads it, p.mesh; the jbeam name is then in p.originalMesh. It also
  -- turns the prop's rotation from degrees into radians)
  leverDeg = -75
  for _, p in pairs(v.data.props or {}) do
    local mesh = p.originalMesh or p.mesh
    if mesh == LEVER_MESH and p.rotation and p.rotation.x then leverDeg = math.deg(p.rotation.x) end
  end
  frameCids = cids
  viewCids = {}
  for key, name in pairs(VIEW_NODES) do viewCids[key] = misc.getNodeIDbyName(name) end
  return true
end

local function worldPoints()
  local a = nodeWorldPos(frameCids[1])
  local ex, ey, ez = frame(a, nodeWorldPos(frameCids[2]), nodeWorldPos(frameCids[3]))
  local function toWorld(l) return a + ex * l[1] + ey * l[2] + ez * l[3] end
  local out = {}
  for name, l in pairs(localPts) do out[name] = toWorld(l) end
  return out
end

-- ---- idle screw -------------------------------------------------------------------------------------------------

local function hotspotValue(id)
  if id == "idleScrew" then
    local rpm = carburettor.idleTargetRpm()
    return rpm and string.format("%d rpm", math.floor(rpm + 0.5)) or nil
  elseif id == "throttleLever" then
    return string.format("%d %%", math.floor(carburettor.leverOpening() * 100 + 0.5))
  elseif CHOKE_SCREWS[id] then
    local turns = carburettor.chokeScrewTurns(CHOKE_SCREWS[id])
    if turns <= 0 then return {key = "screwTight"} end
    return {key = "screwOut", n = string.format("%.2f", turns)}
  elseif id == "chokeCover" then
    if not carburettor.chokeCoverLoose() then return {key = "coverClamped"} end
    return {key = "coverDeg", n = string.format("%+d", math.floor(carburettor.chokeCoverDeg() + 0.5))}
  end
  return nil
end

-- ---- GE link ----------------------------------------------------------------------------------------------------

local function sendState()
  local pts = worldPoints()
  local function t(q) return {x = q.x, y = q.y, z = q.z} end
  local dir, up = obj:getDirectionVector(), obj:getDirectionVectorUp()
  -- the hotspots' values for the tool bar; the lever's drag geometry: the shaft (pivot, a point along its axis), the
  -- arm's closed position and the angle at full opening (+ = right-handed about the axis)
  local hs = {
    idleScrew = {value = hotspotValue("idleScrew")},
    chokeCover = {value = hotspotValue("chokeCover")},
    throttleLever = {value = hotspotValue("throttleLever"),
                     drag = {pivot = t(pts.leverPivot), axis = t(pts.leverAxis), rest = t(pts.leverRest), deg = leverDeg}},
  }
  for id in pairs(CHOKE_SCREWS) do hs[id] = {value = hotspotValue(id)} end
  local view = {}
  for key, cid in pairs(viewCids) do
    local q = nodeWorldPos(cid)
    view[key] = {x = q.x, y = q.y, z = q.z}
  end
  local f = pts.focus
  local state = {
    focus = {x = f.x, y = f.y, z = f.z},
    dir = {x = dir.x, y = dir.y, z = dir.z},
    up = {x = up.x, y = up.y, z = up.z},
    lidDeg = lids.openAngle("engine"),
    hotspots = hs,
    view = view,
    session = session,
  }
  obj:queueGameEngineLua("if bug_worktop then bug_worktop.onState(" .. obj:getId() .. ", " .. serialize(state) .. ") end")
end

-- the work mode can start: a single carburettor and the engine lid open far enough (or no lid); the carburettor's
-- interactor (engineBayWork, condition workModeAvailable in lib/interactors.lua) only reacts then
local function available()
  local lid = lids.openAngle("engine")
  return (lid == nil or lid >= LID_MIN_DEG) and carburettor.isInstalled()
end

-- click on the carburettor (action engineBayWork, via vehicle.workMode)
local function request()
  if active then return end
  local lid = lids.openAngle("engine")
  if lid and lid < LID_MIN_DEG then
    log('D', 'bug.workmode', string.format('engine lid only %.0f deg open, work mode needs %d', lid, LID_MIN_DEG))
    return
  end
  if not carburettor.isInstalled() then
    log('D', 'bug.workmode', 'no single carburettor installed, work mode unavailable')
    return
  end
  if not setupGeometry() then return end

  active = true
  sendTimer = 0
  log('I', 'bug.workmode', 'entering work mode')
  misc.geCall("bug_worktop", "bug_worktop.enter(" .. obj:getId() .. ")")  -- loads the GE extension if needed
  sendState()  -- queued after enter, so the extension exists when it arrives
end

-- the GE side left the work mode (Esc, camera change, vehicle switch, lid closed)
local function exit()
  resumeTime = nil
  if not active then session = nil return end
  active = false
  session = nil
  carburettor.setHandThrottle(nil)   -- the hand lets go of the lever
  log('I', 'bug.workmode', 'left work mode')
end

-- GE kept the work mode open while this car was reloaded (Ctrl+R) and asks it to come back (repeatedly, until a
-- state with this session arrives). The car before the reload still answers while it exists: it is active and
-- ignores it.
local function resume(s)
  if active or session == s then return end
  if not carburettor.isInstalled() then
    log('W', 'bug.workmode', 'reloaded without a single carburettor: no work mode to come back to')
    return
  end
  session = s
  resumeTime, resumeLidAt = 0, RESUME_LID_DELAY
  log('I', 'bug.workmode', 'reloaded in work mode: opening the engine lid to come back')
end

-- while resuming: open the engine lid, enter the work mode once it is open far enough
local function updateResume(dt)
  resumeTime = resumeTime + dt
  local lid = lids.openAngle("engine")
  if resumeTime >= RESUME_LID_DELAY and (lid == nil or lid >= LID_MIN_DEG) then
    resumeTime = nil
    request()
  elseif resumeTime >= resumeLidAt then
    resumeLidAt = resumeTime + RESUME_LID_RETRY
    lids.openAuto("engine")
  end
end

-- left mouse drag on a hotspot (from GE): opening 0 … 1 while held, nil when let go
local function drag(id, opening)
  if not active then return end
  if id == "throttleLever" then carburettor.setHandThrottle(opening) end
end

-- mouse wheel over a hotspot (from GE); steps > 0 = wheel up
local function turn(id, steps)
  if not active then return end
  if id == "idleScrew" then
    if carburettor.turnIdleScrew(steps * TURNS_PER_NOTCH) then
      -- log('D', 'bug.workmode', string.format('idle screw %+d -> %d rpm', steps, math.floor((carburettor.idleTargetRpm() or 0) + 0.5)))  -- diagnosis
    end
  elseif CHOKE_SCREWS[id] then
    carburettor.turnChokeScrew(CHOKE_SCREWS[id], -steps * CHOKE_SCREW_TURNS_PER_NOTCH)   -- wheel up = in (tighter)
  elseif id == "chokeCover" then
    carburettor.turnChokeCover(steps * CHOKE_COVER_DEG_PER_NOTCH)
  end
  sendState()
end

-- game hooks (this file is auto-loaded as a vehicle extension; vehicle.lua doesn't drive it)
local function updateGFX(dt)
  if resumeTime and not active then updateResume(dt) return end
  if not active then return end
  sendTimer = sendTimer + dt
  if sendTimer >= SEND_INTERVAL then
    sendTimer = 0
    sendState()
  end
end

M.updateGFX = updateGFX

M.request   = request
M.isActive  = function() return active end
M.available = available
M.exit      = exit
M.resume  = resume
M.turn    = turn
M.drag    = drag

return M
