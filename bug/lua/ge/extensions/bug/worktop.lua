-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Work mode at the engine bay, game-engine side (extension name: bug_worktop). Proof of concept.
--
-- The car (vehicles/bug/lua/lib/workmode.lua) calls enter(vehId) after a click on the carburettor and then sends
-- the camera focus, the nodes that bound the view (world space) and the hotspots' values and drag geometry
-- (onState, 30 Hz). The hotspots are the car's interactors of mode "workmode" (jbeam section "interactors"): the
-- GE extension bug_interact picks them and lights them up, the same way as everywhere else. This extension:
--   - switches to the camera mode bugWorktop (lua/ge/extensions/core/cameraModes/bugWorktop.lua), a global
--     camera aimed at the engine bay; it overrides the walking camera and the car's camera alike, so the player
--     stays where they are (on foot or seated);
--   - owns the view: camera mode while the right mouse button is held: orbit, the mouse wheel zooms, and with the
--     middle button held too the mouse moves the camera up and down (lift: the point it looks at moves along the
--     car's up axis). The numpad does the same (4 / 6 / 8 / 2 orbit, 9 / 3 up / down, + / - zoom, 5 back to the
--     start view). The camera stays in front of the engine bay opening and the engine lid must not come between it
--     and the point it looks at (viewAllowed); the lifted point stays inside the engine bay (liftAllowed);
--   - freezes and hides the walking character while on foot;
--   - blocks camera switching, walking, vehicle switching and similar actions (action filter, like the big map);
--   - pushes the action map BugWorktop: mouse wheel, left / right / middle mouse button, the numpad, Esc and Ctrl+R
--     (lua/ge/extensions/core/input/actions/bug_worktop.json, bound in settings/inputmaps/mouse_bugWorktop.json /
--     keyboard_bugWorktop.json);
--   - opens the see-through UI route bug.worktop (ui/ui-vue/mods/bug_worktop) with the tool bar, and shows the
--     mouse cursor;
--   - switches the game's own trigger highlights and tooltips off (onPreRender): in the work mode only the
--     hotspots react;
--   - every frame: finds the hotspot under the cursor (getCameraMouseRay, bug_interact.pick), lights it up
--     (bug_interact.draw), sends the hover state to the UI;
--   - mouse wheel over a hotspot → vehicle.workTurn(id, steps) on the car; with the right button held → zoom;
--   - left mouse button held on a hotspot that can be dragged (the throttle lever) → vehicle.workDrag(id, opening)
--     while the cursor moves, vehicle.workDrag(id, nil) when it is let go.
-- Ctrl+R (bugWorktopReload) reloads the car without leaving the mode: the camera, view, tool, action map and UI
-- stay; the hotspots are off until the reloaded car is back. Seated, it is the game's own vehicle reload; on foot
-- (the player's vehicle is the walking character) the car is respawned with its config. Until a state with this
-- reload's session arrives, the car is asked every RESUME_INTERVAL to come back (vehicle.workResume): it opens its
-- engine lid and enters the work mode again. States of the old car (no session) are ignored meanwhile.
-- It leaves the mode on Esc, when the route is left, when another camera is chosen, when the player switches
-- vehicle, when the car is removed or its engine lid is closed.

local M = {}

M.dependencies = {"bug_interact"}

-- bumped on every change: the vehicle reloads this extension when an older version is still loaded
M.version = 17

local CAMERA_NAME = "bugWorktop"     -- must match the file name of the camera mode
local ROUTE_NAME = "bug.worktop"     -- must match ui/ui-vue/mods/bug_worktop/index.js
local ACTION_MAP = "BugWorktop"      -- must match the actionMap in core/input/actions/bug_worktop.json
local ACTIONS_FILE = "/lua/ge/extensions/core/input/actions/bug_worktop.json"
local FILTER_GROUP = "bugWorktopBlocked"
local TRANSITION_IN, TRANSITION_OUT = 0.8, 0.6  -- s
local LID_CLOSED_DEG = 20            -- deg  leave when the engine lid comes down below this
local UI_STATE_INTERVAL = 0.1        -- s
local STATE_TIMEOUT = 2              -- s    leave when the car stops sending (e.g. its Lua was reloaded)
local MAP_PUSH_WARN_AFTER = 3        -- s    warn when the action map still doesn't exist after this
local DEFAULT_TOOL = "screwdriver"   -- proof of concept: the only tool
local TOOLTIP_STREAM = "vehicleTriggerCrosshairTarget"  -- the game's trigger tooltip (core_vehicleTriggers)

-- view (orbit around the focus point, in the car's frame): yaw 0 = straight behind the car, + towards the car's
-- left (+x); pitch = elevation above the car's horizontal plane; lift = the point the camera looks at, moved along
-- the car's up axis from the focus the car sends (the camera moves with it)
local VIEW_DEFAULT = {yaw = 25, pitch = 42, dist = 0.75, lift = 0}  -- deg, deg, m, m
local YAW_MAX = 85                   -- deg
local PITCH_MIN, PITCH_MAX = 0, 80   -- deg
local DIST_MIN, DIST_MAX = 0.3, 1.5  -- m
local LIFT_MIN, LIFT_MAX = -0.10, 0.20  -- m
local LIFT_INSIDE = 0.03             -- m    a lifted look point stays this far inside the engine bay opening
local LIFT_PER_DEG = 0.002           -- m per degree of mouse motion (right + middle button)
local ZOOM_SLIDE_DEG = 40           -- deg  a zoom step a limit stops may turn the view this far to get past it
local KEY_DEG_PER_S = 70             -- deg/s numpad orbit
local KEY_LIFT_PER_S = 0.12          -- m/s  numpad up / down
local WHEEL_ZOOM = 0.12              -- distance fraction per wheel notch
local MOUSE_MAX_DEG_PER_S = 180      -- deg/s cap of the mouse look input (as the game's part camera)
local CURSOR_DEG_PER_PX = 0.25       -- deg per pixel when the orbit follows the cursor instead (see orbitInput)
local SEARCH_INTERVAL = 0.2          -- s    nearest allowed view: searched at most this often
local RESUME_INTERVAL = 0.5          -- s    after Ctrl+R: ask the reloaded car to come back this often
local RELOAD_TIMEOUT = 20            -- s    leave when the reloaded car isn't back by then

-- view limits (viewAllowed), from the nodes the car sends (workmode.lua VIEW_NODES)
local OPEN_MIN_HEIGHT = 0.12         -- m    camera at least this far out of the engine bay opening's plane
local OPEN_SIDE_SLOPE = 0.8          -- m/m  the allowed zone widens with the height above the opening: sides,
local OPEN_TOP_SLOPE = 0.4           --      towards the roof
local OPEN_BOTTOM_SLOPE = 1.0        --      and towards the bumper
local MIN_INCIDENCE = 0.15           -- cos of the steepest grazing angle through the opening
local EDGE_MARGIN = 0.03             -- m    the line of sight passes this far inside the opening's edges
local LID_HALF_WIDTH = 0.45          -- m    engine lid panel half width (nodes t1ll / t1rr)
local LID_PAD = 0.06                 -- m    clearance around the lid panel

local blockedActions = core_input_actionFilter.createActionTemplate({"gameCam", "freeCam", "walkingMode",
  "vehicleSwitching", "vehicleTeleporting", "vehicleMenues", "photoMode", "bigMap", "radialMenu", "radialMenuActivate",
  "vehicleTriggers", "funStuff", "aiControls", "resetPhysics", "vehicleRecovery", "couplers"},
  {"rotate_camera_hz_mouse", "rotate_camera_vt_mouse"})  -- not blocked: mouse look drives the orbit

local active = false
local vehId = nil
local state = nil              -- last snapshot from the car
local limits = nil             -- view limits derived from state.view
local stateAge = 0
local hover = nil              -- hotspot id under the cursor
local dragging = nil           -- hotspot id held with the left mouse button
local dragSent = nil           -- last opening sent while dragging
local used = nil               -- hotspot id worked on (turned / dragged): no highlight until the cursor leaves it
local tool = DEFAULT_TOOL
local routeSeen = false        -- the route was open at least once (before that, "not on the route" is the start)
local uiTimer = 0
local lastStates = {}          -- vehicle id → last snapshot (the car sends its first one right before enter())
local unicycleId = nil         -- walking character, frozen and hidden while active
local mapPushed = false
local mapWaitTime = 0
local inputReloadRequested = false
local reload = nil             -- while the car is reloaded (Ctrl+R): {session, time, askTimer}
local overBar = false          -- the cursor is over the tool bar (reported by the UI, Worktop.vue)
local pickBlocked = nil        -- why hotspot picking is off (logged when it changes), nil = it's on
local cefFocusDiffers = false  -- the game's UI focus flag disagrees with overBar (logged when it changes)
local triggersCefVisible = nil -- core_vehicleTriggers.state.cefVisible before the mode switched the triggers off

local function defaultView() return {yaw = VIEW_DEFAULT.yaw, pitch = VIEW_DEFAULT.pitch, dist = VIEW_DEFAULT.dist, lift = VIEW_DEFAULT.lift} end
local view = defaultView()
local orbitHeld = false
local panHeld = false          -- middle mouse button (moves the camera up / down while orbiting)
local keys = {}                -- numpad camera keys held: yawLeft, yawRight, pitchUp, pitchDown, liftUp, liftDown
local cursorLast = nil         -- {x, y} while orbiting
local cursorDX, cursorDY = 0, 0
local zoomSteps = 0
local searchTimer = 0
local noViewLogged = false
local stats = nil              -- orbit / zoom diagnostics of the current work mode, logged on exit

local function vec(t) return vec3(t.x, t.y, t.z) end

local function currentRouteName()
  local r = extensions.ui_router
  local entry = r and r.getCurrent and r.getCurrent()
  return entry and entry.request and entry.request.name or nil
end

-- ---- input actions ------------------------------------------------------------------------------------------------

-- The game reads the action files in lua/ge/extensions/core/input/actions/ once, before the mods are mounted, and
-- only reads them again on a file change notification, which an unpacked mod doesn't always get. Then the action
-- map BugWorktop doesn't exist and the mouse wheel does nothing. Simulating the notification makes the game read
-- the action files again and rebind all inputs (0.1 s later); the map is pushed as soon as it exists (onUpdate).
local function actionMapExists() return scenetree.findObject(ACTION_MAP .. "ActionMap") ~= nil end

local function ensureInputActions()
  if inputReloadRequested or actionMapExists() then return end
  inputReloadRequested = true
  log('I', 'bug_worktop', 'work mode input actions not loaded yet: reloading the input actions and bindings')
  if core_input_actions and core_input_actions.onFileChanged then core_input_actions.onFileChanged(ACTIONS_FILE) end
  if core_input_bindings and core_input_bindings.onFileChanged then core_input_bindings.onFileChanged(ACTIONS_FILE) end
end

-- pushed exactly once per work mode and popped on exit. pushActionMapHighestPriority() returns nothing even on
-- success, so the map's existence decides (pushing on every frame stacked it up and it stayed after the exit,
-- taking the mouse wheel and right button from the normal cameras).
local function tryPushActionMap()
  if mapPushed or not actionMapExists() then return end
  pushActionMapHighestPriority(ACTION_MAP)
  mapPushed = true
  log('I', 'bug_worktop', 'action map ' .. ACTION_MAP .. ' active')
end

-- ---- walking character, cursor, UI --------------------------------------------------------------------------------

local function setUnicycleFrozen(frozen)
  if not unicycleId then return end
  local uni = getObjectByID(unicycleId)
  if not uni then return end
  uni:queueLuaCommand("for _, c in pairs(controller.getControllersByType('playerController')) do c.setFreeze(" .. (frozen and 1 or 0) .. ") end")
  if not frozen then uni:renderViewMaskClear() end
end

-- the walking extension shows the character again when the camera changes away from the walking camera, so the
-- character is hidden every frame while active (cheap, idempotent)
local function hideUnicycle()
  local uni = unicycleId and getObjectByID(unicycleId)
  if uni then uni:hideInRenderView(0) end
end

local function getCanvas() return scenetree.findObject("Canvas") end

local function showCursor()
  lockMouse(false)
  local canvas = getCanvas()
  if canvas then canvas:setCursorVisible(true) end
end

-- a hotspot: the work mode's interactor (tool, label: bug_interact, from the car's jbeam) with its value and drag
-- geometry from the car's state, nil if there is none
local function hotspot(id)
  local hi = id and extensions.bug_interact
  local item = hi and hi.get(vehId, id)
  if not item then return nil end
  local s = state and state.hotspots and state.hotspots[id] or {}
  return {tool = item.tool, label = item.label or id, value = s.value, drag = s.drag}
end

local function sendUi()
  local h = hotspot(hover)
  guihooks.trigger("BugWorktopState", {
    active = active,
    tool = tool,
    orbiting = orbitHeld,
    hover = h and {id = hover, label = h.label, value = h.value, tool = h.tool, noUse = h.tool == nil,
                   usable = h.tool == tool or h.tool == "hand", drag = h.drag ~= nil, dragging = dragging == hover} or nil,
  })
end

-- the game's trigger tooltip is re-sent when this is cleared (core_vehicleTriggers only sends it on changes)
local function resetGameTooltip()
  local vt = core_vehicleTriggers
  if vt and vt.state then vt.state.hoveredHitPosScreen01 = nil end
end

-- ---- view limits --------------------------------------------------------------------------------------------------

-- opening: body edges of the engine bay (top left / right, bottom right / left); lid: hinge nodes and bottom edge
local function deriveLimits(s)
  local nodes = s and s.view
  if not nodes or not s.focus then return nil end
  local focus = vec(s.focus)
  local out = {}
  if nodes.openTL and nodes.openTR and nodes.openBR and nodes.openBL then
    local a, b, c, d = vec(nodes.openTL), vec(nodes.openTR), vec(nodes.openBR), vec(nodes.openBL)
    local center = (a + b + c + d) * 0.25
    local across = a - b
    local down = (c + d) * 0.5 - (a + b) * 0.5
    local hw, hh = across:length() * 0.5, down:length() * 0.5
    if hw > 0.05 and hh > 0.05 then
      local u, v = across * (0.5 / hw), down * (0.5 / hh)
      local n = u:cross(v):normalized()
      if n:dot(center - focus) < 0 then n = -n end  -- out of the engine bay
      out.open = {c = center, u = u, v = v, n = n, hw = hw, hh = hh}
    end
  end
  if nodes.lidHingeL and nodes.lidHingeR and nodes.lidEnd then
    local h1, h2 = vec(nodes.lidHingeL), vec(nodes.lidHingeR)
    local hinge = (h1 + h2) * 0.5
    local w = vec(nodes.lidEnd) - hinge
    local len = w:length()
    local u = (h1 - h2):normalized()
    if len > 0.1 then
      w = w * (1 / len)
      out.lid = {h = hinge, u = u, w = w, m = u:cross(w):normalized(), len = len}
    end
  end
  return out
end

-- does the lid panel come between the focus and the camera, or is the camera inside it
local function lidInTheWay(focus, cam, lid)
  local a0, a1 = (focus - lid.h):dot(lid.m), (cam - lid.h):dot(lid.m)
  local function onPanel(p)
    local q = p - lid.h
    local along = q:dot(lid.w)
    return math.abs(q:dot(lid.u)) <= LID_HALF_WIDTH + LID_PAD and along >= -LID_PAD and along <= lid.len + LID_PAD
  end
  if math.abs(a1) < LID_PAD and onPanel(cam) then return true end
  if a0 * a1 > 0 then return false end
  local t = a0 / (a0 - a1)
  return onPanel(focus + (cam - focus) * t)
end

-- true, or false and which limit the view breaks (for the log)
local function viewAllowed(cam, focus)
  if not limits then return true end
  local o = limits.open
  if o then
    local q = cam - o.c
    local h = q:dot(o.n)
    if h < OPEN_MIN_HEIGHT then return false, "too close to the opening" end
    if math.abs(q:dot(o.u)) > o.hw + OPEN_SIDE_SLOPE * h then return false, "too far to the side" end
    local along = q:dot(o.v)
    if along < -(o.hh + OPEN_TOP_SLOPE * h) then return false, "too far towards the roof" end
    if along > o.hh + OPEN_BOTTOM_SLOPE * h then return false, "too far towards the bumper" end
    -- the line of sight to the focus passes through the opening
    local d = (cam - focus):normalized()
    local nd = d:dot(o.n)
    if nd < MIN_INCIDENCE then return false, "grazing angle" end
    local p = focus + d * (-(focus - o.c):dot(o.n) / nd) - o.c
    if math.abs(p:dot(o.u)) > o.hw - EDGE_MARGIN or math.abs(p:dot(o.v)) > o.hh - EDGE_MARGIN then
      return false, "line of sight outside the opening"
    end
  end
  if limits.lid and lidInTheWay(focus, cam, limits.lid) then return false, "engine lid in the way" end
  return true
end

-- camera position for a view, in the car's frame (fwd / up from the car)
local function viewPos(focus, fwd, up, v)
  local yaw, pitch = math.rad(v.yaw), math.rad(v.pitch)
  local left = up:cross(fwd)
  local dir = (-fwd * math.cos(yaw) + left * math.sin(yaw)) * math.cos(pitch) + up * math.sin(pitch)
  return focus + dir * v.dist
end

-- the lifted look point stays inside the engine bay: below the opening's plane (lowering it is always fine)
local function liftAllowed(focus, up, lift)
  local o = limits and limits.open
  if not o or lift <= 0 then return true end
  return (focus + up * lift - o.c):dot(o.n) < -LIFT_INSIDE
end

-- the camera of view v and the line of sight to its (lifted) look point
local function allowed(focus, fwd, up, v)
  local lift = v.lift or 0
  if not liftAllowed(focus, up, lift) then return false, "look point out of the engine bay" end
  local look = focus + up * lift
  return viewAllowed(viewPos(look, fwd, up, v), look)
end

-- nearest allowed view to v (angles first, then distance), or nil
local function nearestAllowed(focus, fwd, up, v)
  local best, bestCost = nil, math.huge
  local cand = {}
  for _, dist in ipairs({v.dist, 0.45, 0.75, 1.1}) do
    for pitch = PITCH_MIN, PITCH_MAX, 5 do
      for yaw = -YAW_MAX, YAW_MAX, 5 do
        local cost = (yaw - v.yaw) ^ 2 + (pitch - v.pitch) ^ 2 + (100 * (dist - v.dist)) ^ 2
        if cost < bestCost then
          cand.yaw, cand.pitch, cand.dist = yaw, pitch, dist
          cand.lift = v.lift
          if allowed(focus, fwd, up, cand) then best, bestCost = {yaw = yaw, pitch = pitch, dist = dist, lift = v.lift}, cost end
        end
      end
    end
  end
  return best
end

-- ---- orbit / zoom input -------------------------------------------------------------------------------------------

-- Mouse motion while the right mouse button is held. The game's mouse look (MoveManager.yawRelative / pitchRelative, as
-- in its part camera) is used when it arrives; if it doesn't (cursor visible), the cursor's motion is used instead.
-- Returns degrees: + yaw = the camera moves to the car's left (mouse right: the view turns right), + pitch = the
-- camera moves up (mouse down: the view turns down), the same directions as the game's part camera.
local function orbitInput(dt)
  local mm = MoveManager
  local yawRel = mm and mm.yawRelative or 0
  local pitchRel = mm and mm.pitchRelative or 0
  local cdx, cdy = cursorDX, cursorDY
  cursorDX, cursorDY = 0, 0
  if not orbitHeld then return 0, 0 end
  if stats then
    stats.orbitFrames = stats.orbitFrames + 1
    if yawRel ~= 0 or pitchRel ~= 0 then stats.mouseLookFrames = stats.mouseLookFrames + 1 end
    if cdx ~= 0 or cdy ~= 0 then stats.cursorFrames = stats.cursorFrames + 1 end
  end
  if yawRel ~= 0 or pitchRel ~= 0 then
    local cap = MOUSE_MAX_DEG_PER_S * dt
    return sign(yawRel) * math.min(math.abs(yawRel * 10), cap), -sign(pitchRel) * math.min(math.abs(pitchRel * 10), cap)
  end
  return cdx * CURSOR_DEG_PER_PX, cdy * CURSOR_DEG_PER_PX
end

local function clampView(v)
  v.yaw = clamp(v.yaw, -YAW_MAX, YAW_MAX)
  v.pitch = clamp(v.pitch, PITCH_MIN, PITCH_MAX)
  v.dist = clamp(v.dist, DIST_MIN, DIST_MAX)
  v.lift = clamp(v.lift or 0, LIFT_MIN, LIFT_MAX)
  return v
end

-- numpad: held keys orbit / move at a fixed rate, in the same directions as the mouse (4 = mouse left, 8 = mouse up)
local function keyInput(dt)
  local function k(name) return keys[name] and 1 or 0 end
  return (k("yawRight") - k("yawLeft")) * KEY_DEG_PER_S * dt,
         (k("pitchDown") - k("pitchUp")) * KEY_DEG_PER_S * dt,
         (k("liftUp") - k("liftDown")) * KEY_LIFT_PER_S * dt
end

-- the allowed view at distance dist nearest to the current angles (yaw, pitch within ZOOM_SLIDE_DEG), or nil
local function slideForZoom(focus, fwd, up, dist)
  local best, bestCost = nil, math.huge
  local cand = {dist = dist, lift = view.lift}
  for dp = -ZOOM_SLIDE_DEG, ZOOM_SLIDE_DEG, 2 do
    for dy = -ZOOM_SLIDE_DEG, ZOOM_SLIDE_DEG, 2 do
      local cost = dy * dy + dp * dp
      if cost < bestCost and cost <= ZOOM_SLIDE_DEG * ZOOM_SLIDE_DEG then
        cand.yaw = clamp(view.yaw + dy, -YAW_MAX, YAW_MAX)
        cand.pitch = clamp(view.pitch + dp, PITCH_MIN, PITCH_MAX)
        if allowed(focus, fwd, up, cand) then best, bestCost = {yaw = cand.yaw, pitch = cand.pitch}, cost end
      end
    end
  end
  return best
end

-- applies this frame's input to the view, keeping it allowed: a change that would leave the allowed zone is
-- dropped (each axis on its own, so the view slides along a limit); a view that isn't allowed any more (the lid
-- moved, first frame) jumps to the nearest allowed one
local function updateView(dt, focus, fwd, up)
  local dYaw, dPitch = orbitInput(dt)
  local dLift = 0
  if panHeld and orbitHeld then
    -- right + middle button: the mouse moves the camera up / down instead of orbiting (mouse up = camera up)
    dLift = -dPitch * LIFT_PER_DEG
    dYaw, dPitch = 0, 0
  end
  local kYaw, kPitch, kLift = keyInput(dt)
  dYaw, dPitch, dLift = dYaw + kYaw, dPitch + kPitch, dLift + kLift
  local steps = zoomSteps
  zoomSteps = 0

  if dYaw ~= 0 or dPitch ~= 0 or dLift ~= 0 or steps ~= 0 then
    local try = clampView({yaw = view.yaw + dYaw, pitch = view.pitch + dPitch,
                           dist = view.dist * (1 - WHEEL_ZOOM * steps), lift = view.lift + dLift})
    if allowed(focus, fwd, up, try) then
      view = try
    else
      if stats then stats.limitHits = stats.limitHits + 1 end
      -- each axis on its own, so the view slides along a limit
      local function with(field, value)
        local v = {yaw = view.yaw, pitch = view.pitch, dist = view.dist, lift = view.lift}
        v[field] = value
        return v
      end
      if dYaw ~= 0 and allowed(focus, fwd, up, with("yaw", try.yaw)) then view.yaw = try.yaw end
      if dPitch ~= 0 and allowed(focus, fwd, up, with("pitch", try.pitch)) then view.pitch = try.pitch end
      if steps ~= 0 then
        local ok, why = allowed(focus, fwd, up, with("dist", try.dist))
        if ok then
          view.dist = try.dist
        else
          -- go as far as the limit allows (halving the step) instead of dropping the whole step
          -- first: the nearest angle at the new distance that is allowed (zooming out under the open lid tilts the
          -- view down, zooming in close to the opening tilts it up), so the wheel never just stops at a limit
          local slid = slideForZoom(focus, fwd, up, try.dist)
          if slid then
            view.yaw, view.pitch, view.dist = slid.yaw, slid.pitch, try.dist
          else
            -- else as far as the limit allows (halving the step)
            local lo, hi = view.dist, try.dist
            for _ = 1, 8 do
              local mid = (lo + hi) * 0.5
              if allowed(focus, fwd, up, with("dist", mid)) then lo = mid else hi = mid end
            end
            if allowed(focus, fwd, up, with("dist", lo)) then view.dist = lo end
          end
          log('D', 'bug_worktop', string.format('zoom %s at a limit: %s (%s; dist %.2f m, yaw %.0f, pitch %.0f, lift %.2f m)',
            steps > 0 and "in" or "out", why or "?", slid and "turned past it" or "moved up to the limit",
            view.dist, view.yaw, view.pitch, view.lift))  -- diagnosis
        end
      end
      if dLift ~= 0 and allowed(focus, fwd, up, with("lift", try.lift)) then view.lift = try.lift end
    end
  end

  searchTimer = searchTimer - dt
  if searchTimer <= 0 and not allowed(focus, fwd, up, view) then
    searchTimer = SEARCH_INTERVAL
    local best = nearestAllowed(focus, fwd, up, view)
    if stats then stats.jumps = stats.jumps + 1 end
    if best then
      view = best
      noViewLogged = false
    elseif view.lift ~= 0 then
      view.lift = 0   -- no view fits with this lift: try again with the car's own focus
    elseif not noViewLogged then
      noViewLogged = true
      log('W', 'bug_worktop', 'no camera view fits the view limits: limits ignored until one does')
    end
  end
end

-- ---- camera (called by the camera mode every frame) ---------------------------------------------------------------

-- the point to look at (the car's focus, lifted), the car's forward / up vectors and the view (yaw, pitch in
-- degrees, distance in m), or nil (the camera mode then gives up and the game falls back)
local function getCameraTarget(dt)
  if not active then return nil end
  local focus, fwd, up
  if state then
    focus, fwd, up = vec(state.focus), vec(state.dir), vec(state.up)
  else
    -- no snapshot from the car yet (first frames): aim at the car's rear until it arrives
    local veh = vehId and getObjectByID(vehId)
    if not veh then return nil end
    fwd, up = veh:getDirectionVector(), veh:getDirectionVectorUp()
    focus = veh:getPosition() - fwd * 1.6 + up * 0.7
  end
  updateView(math.min(dt or 0, 0.1), focus, fwd, up)
  return focus + up * view.lift, fwd, up, view.yaw, view.pitch, view.dist
end

-- ---- enter / exit -------------------------------------------------------------------------------------------------

-- The game's trigger system (core_vehicleTriggers) must be off in this mode, not only invisible. On foot it finds
-- triggers within 3 m of the camera, so with the camera zoomed in close it hovered the car's triggers under the
-- cursor and pushed its own action maps (VehicleInteraction0 … 2) for them. Those take the mouse buttons and wheel
-- above this mode's map, and their actions are blocked here, so clicks, zoom and even an orbit button release got
-- lost (orbit then stayed "held", which switches the hover and the highlights off), until the player walked more
-- than 3 m away. Its state.cefVisible is what the system itself uses while the UI is hidden: false makes it
-- release held triggers and pop those maps every frame. Kept false every frame (the game sets it on a UI change),
-- the value from before is put back on exit.
local function suppressGameTriggers()
  local st = core_vehicleTriggers and core_vehicleTriggers.state
  if not st then return end
  if triggersCefVisible == nil then triggersCefVisible = st.cefVisible ~= false end
  st.cefVisible = false
end

local function restoreGameTriggers()
  local st = core_vehicleTriggers and core_vehicleTriggers.state
  if st and triggersCefVisible ~= nil then st.cefVisible = triggersCefVisible end
  triggersCefVisible = nil
end

-- The game's trigger system (core_vehicleTriggers) holds a clicked trigger from mouse down until it sees the mouse
-- up. A click on a trigger that is still held when the action map BugWorktop is pushed (the carburettor was one,
-- before it became an interactor) never gets its release: that map takes the left button (bugWorktopGrab), so the trigger stayed
-- held after the mode, which keeps the cursor unlocked (no mouse look on foot) and lights up only that trigger,
-- until the player walks away. Released here the way a mouse up would (action 0, value 0).
local function releaseHeldTrigger()
  local vt = core_vehicleTriggers
  local used = vt and vt.state and vt.state.currentlyUsedTriggers
  if not (used and used[0] and vt.onActionEvent) then return end
  log('I', 'bug_worktop', 'releasing the game trigger still held by a click (' .. tostring(used[0].t) .. ')')
  vt.onActionEvent(0, 0, 0)
  used[0] = nil   -- in case the release didn't clear it
end

local exit  -- forward declaration

local function enter(id)
  if active then return end
  local veh = getObjectByID(id)
  if not veh then return end
  vehId = id
  active = true
  routeSeen = false
  hover = nil
  tool = DEFAULT_TOOL
  stateAge = 0
  used = nil
  reload = nil
  overBar, pickBlocked, cefFocusDiffers = false, nil, false
  state = lastStates[id]
  limits = deriveLimits(state)
  view = defaultView()
  panHeld, keys = false, {}
  orbitHeld, cursorLast, cursorDX, cursorDY, zoomSteps = false, nil, 0, 0, 0
  searchTimer, noViewLogged = 0, false
  stats = {orbitFrames = 0, mouseLookFrames = 0, cursorFrames = 0, limitHits = 0, jumps = 0, zoomSteps = 0}
  log('I', 'bug_worktop', 'entering work mode on vehicle ' .. tostring(id) .. (state and '' or ' (no state yet)'))

  -- walking character: freeze and hide it (the global camera overrides the walking camera; it is not restored
  -- by the game while our camera is active)
  unicycleId = nil
  if gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking() then
    local player = getPlayerVehicle(0)
    unicycleId = player and player:getId() or nil
  end
  setUnicycleFrozen(true)

  core_camera.setByName(CAMERA_NAME, false, {})
  core_camera.startCameraTransition(TRANSITION_IN)

  releaseHeldTrigger()
  suppressGameTriggers()
  core_input_actionFilter.setGroup(FILTER_GROUP, blockedActions)
  core_input_actionFilter.addAction(0, FILTER_GROUP, true)
  mapPushed, mapWaitTime = false, 0
  ensureInputActions()
  tryPushActionMap()

  local r = extensions.ui_router
  if r and r.navigate then
    local res = r.navigate(ROUTE_NAME)
    if type(res) == "table" and res.result == false then
      log('W', 'bug_worktop', 'could not open the work mode UI: ' .. tostring(res.reason))
    end
  end
  showCursor()
  sendUi()
  -- make sure the car is in the work mode too: when this extension was just reloaded (newer version), the old
  -- one's exit has told the car to leave, and that arrives right after the car entered (a no-op if it is active)
  veh:queueLuaCommand("if vehicle and vehicle.workMode then vehicle.workMode() end")
end

exit = function(reason)
  if not active then return end
  active = false
  reload = nil
  log('I', 'bug_worktop', 'leaving work mode (' .. tostring(reason) .. ')')

  -- diagnosis: orbit / zoom statistics of this work mode
  -- if stats then
  --   log('I', 'bug_worktop', string.format('view stats: orbit frames %d (mouse look %d, cursor %d), limit hits %d, jumps to an allowed view %d, zoom steps %d, last view yaw %.0f pitch %.0f dist %.2f',
  --     stats.orbitFrames, stats.mouseLookFrames, stats.cursorFrames, stats.limitHits, stats.jumps, stats.zoomSteps, view.yaw, view.pitch, view.dist))
  -- end
  if dragging then
    local veh = vehId and getObjectByID(vehId)
    if veh then veh:queueLuaCommand(string.format("vehicle.workDrag(%q, nil)", dragging)) end
    dragging, dragSent = nil, nil
  end
  if mapPushed then popActionMap(ACTION_MAP) end
  mapPushed = false
  core_input_actionFilter.addAction(0, FILTER_GROUP, false)
  releaseHeldTrigger()
  restoreGameTriggers()

  if core_camera.getActiveGlobalCameraName() == CAMERA_NAME then
    core_camera.setByName(nil)
    core_camera.startCameraTransition(TRANSITION_OUT)
  end
  setUnicycleFrozen(false)
  unicycleId = nil
  resetGameTooltip()

  local veh = vehId and getObjectByID(vehId)
  if veh then veh:queueLuaCommand("if vehicle and vehicle.workExit then vehicle.workExit() end") end

  if currentRouteName() == ROUTE_NAME then
    local r = extensions.ui_router
    if r and r.navigate then r.navigate("play") end
  end

  hover = nil
  used = nil
  state = nil
  limits = nil
  vehId = nil
  orbitHeld, panHeld, keys = false, false, {}
  sendUi()
end

-- ---- input (action map BugWorktop) --------------------------------------------------------------------------------

-- mouse wheel: with the right mouse button held (camera mode) it zooms (wheel up = in), otherwise it turns the
-- hovered hotspot if the tool in hand fits, or if it is turned by hand (tool "hand" without a drag: the choke cover)
local function onWheel(value)
  if not active or not value or value == 0 then return end
  local steps = value > 0 and 1 or -1
  -- log('D', 'bug_worktop', string.format('wheel %+d (value %s, orbit %s, pan %s, hover %s)', steps, tostring(value),
  --   tostring(orbitHeld), tostring(panHeld), tostring(hover)))  -- diagnosis
  if orbitHeld then
    zoomSteps = zoomSteps + steps
    if stats then stats.zoomSteps = stats.zoomSteps + 1 end
    return
  end
  local h = hotspot(hover)
  if h and (h.tool == tool or (h.tool == "hand" and not h.drag)) then
    local veh = getObjectByID(vehId)
    if veh then veh:queueLuaCommand(string.format("vehicle.workTurn(%q, %d)", hover, steps)) end
    used = hover   -- the highlight would cover the turning screw
  end
end

-- right mouse button: held = orbit
local function onOrbitButton(value)
  if not active then return end
  local held = (value or 0) > 0.5
  -- if held ~= orbitHeld then log('D', 'bug_worktop', 'orbit button ' .. (held and 'down' or 'up')) end  -- diagnosis
  orbitHeld = held
  cursorLast = nil
  cursorDX, cursorDY = 0, 0
  sendUi()
end

-- middle mouse button: held together with the right one = move the camera up / down
local function onPanButton(value)
  if not active then return end
  panHeld = (value or 0) > 0.5
  cursorDX, cursorDY = 0, 0
end

-- numpad camera keys (name: yawLeft, yawRight, pitchUp, pitchDown, liftUp, liftDown), held = moving
local function onCameraKey(name, value)
  if not active then return end
  keys[name] = (value or 0) > 0.5 or nil
end

-- numpad +/-: zoom one step, like the mouse wheel with the right button held (+ = in)
local function onZoomKey(steps)
  if active then zoomSteps = zoomSteps + (steps or 0) end
end

-- numpad 5: back to the start view (the nearest allowed one if the lid is in the way)
local function onCenterKey()
  if not active then return end
  view = defaultView()
  searchTimer = 0
end

-- the opening of a dragged lever under the cursor: the point of the lever's arc (its arm turned about the shaft,
-- 0 … full opening) closest to the cursor ray. Sampled along the arc, so it works from every camera angle (the
-- camera often looks nearly along the lever's plane).
local DRAG_SAMPLES = 120
local function dragOpening(d)
  local ray = getCameraMouseRay()
  if not ray or not d then return nil end
  local pivot = vec(d.pivot)
  local k = (vec(d.axis) - pivot):normalized()
  local r0 = vec(d.rest) - pivot
  local dir = vec3(ray.dir):normalized()
  local origin = vec3(ray.pos)
  local best, bestDist = nil, math.huge
  for i = 0, DRAG_SAMPLES do
    local f = i / DRAG_SAMPLES
    local th = math.rad(d.deg * f)
    local c, s = math.cos(th), math.sin(th)
    local p = pivot + r0 * c + k:cross(r0) * s + k * (k:dot(r0) * (1 - c))  -- Rodrigues, right-handed about k
    local q = p - origin
    local dist = (q - dir * q:dot(dir)):length()
    if dist < bestDist then best, bestDist = f, dist end
  end
  return best
end

-- left mouse button: held on a draggable hotspot = drag it
local function onGrab(value)
  if not active then return end
  local down = (value or 0) > 0.5
  -- log('D', 'bug_worktop', 'grab button ' .. (down and 'down' or 'up') .. ' (hover ' .. tostring(hover) .. ', dragging ' .. tostring(dragging) .. ')')  -- diagnosis
  local veh = vehId and getObjectByID(vehId)
  if down then
    local h = hotspot(hover)
    if h and h.drag and not orbitHeld then
      dragging, dragSent = hover, nil
      used = hover   -- the highlight would cover the moving lever
      sendUi()
    end
  elseif dragging then
    if veh then veh:queueLuaCommand(string.format("vehicle.workDrag(%q, nil)", dragging)) end
    dragging, dragSent = nil, nil
    sendUi()
  end
end

local function updateDrag()
  if not dragging then return end
  local h = state and state.hotspots and state.hotspots[dragging]
  local opening = h and dragOpening(h.drag)
  if not opening then return end
  if dragSent and math.abs(opening - dragSent) < 0.002 then return end
  dragSent = opening
  local veh = getObjectByID(vehId)
  if veh then veh:queueLuaCommand(string.format("vehicle.workDrag(%q, %.4f)", dragging, opening)) end
end

local function onExitKey()
  exit("Esc")
end

-- Ctrl+R: reload the car and stay in the work mode (see the top of this file)
local function onReloadKey()
  if not active or reload then return end
  local veh = getObjectByID(vehId)
  if not veh then return end
  if dragging then
    veh:queueLuaCommand(string.format("vehicle.workDrag(%q, nil)", dragging))
    dragging, dragSent = nil, nil
  end
  hover = nil
  reload = {session = math.floor(os.clock() * 1000) % 1000000000, time = 0, askTimer = 0}
  sendUi()
  if be:getPlayerVehicleID(0) == vehId then
    log('I', 'bug_worktop', 'reloading the car (seated), staying in the work mode')
    core_vehicle_manager.reloadVehicle(0)
  else
    local vd = core_vehicle_manager.getVehicleData(vehId)
    if not (vd and vd.config) then
      log('W', 'bug_worktop', 'reload: no config of the car found')
      reload = nil
      return
    end
    log('I', 'bug_worktop', 'reloading the car (on foot: respawn with its config), staying in the work mode')
    veh.autoEnterVehicle = "false"   -- the respawn would seat player 0 in it otherwise
    veh:respawn(serialize(vd.config))
  end
end

-- while reloading: ask the car to come back; true while still waiting (onUpdate then does nothing else)
local function updateReload(dt)
  if not reload then return false end
  reload.time = reload.time + dt
  if reload.time > RELOAD_TIMEOUT then exit("the car didn't come back after the reload") return true end
  reload.askTimer = reload.askTimer - dt
  if reload.askTimer <= 0 then
    reload.askTimer = RESUME_INTERVAL
    local veh = getObjectByID(vehId)
    if veh then
      veh:queueLuaCommand(string.format("if vehicle and vehicle.workResume then vehicle.workResume(%d) end", reload.session))
    end
  end
  return true
end

-- called by the UI (close button, tool selection)
local function close() exit("UI") end
local function setOverBar(over) overBar = over and true or false end
local function selectTool(name) tool = name or DEFAULT_TOOL; sendUi() end

-- ---- per frame ----------------------------------------------------------------------------------------------------

local function onState(id, s)
  lastStates[id] = s
  if not active or id ~= vehId then return end
  if reload then
    if s.session ~= reload.session then return end   -- the old car's last states
    log('I', 'bug_worktop', string.format('the car is back in the work mode after the reload (%.1f s)', reload.time))
    reload = nil
  end
  state = s
  limits = deriveLimits(s)
  stateAge = 0
end

local function setPickBlocked(reason)
  if reason == pickBlocked then return end
  pickBlocked = reason
  -- log('D', 'bug_worktop', 'hotspot picking ' .. (reason and ('off: ' .. reason) or 'on'))  -- diagnosis
end

-- The tool bar's own mouseenter / mouseleave decide whether the cursor is over it. The game's UI focus flag
-- (getCEFFocusMouse) was used before, but it could stay set after the cursor had left the bar: picking then stayed
-- off (no hover, no highlights) until something reset the UI focus. Its disagreement is still logged.
local function pickHotspot()
  if getCEFFocusMouse then
    local differs = (getCEFFocusMouse() and true or false) ~= overBar
    if differs ~= cefFocusDiffers then
      cefFocusDiffers = differs
      -- log('D', 'bug_worktop', 'game UI mouse focus ' .. tostring(getCEFFocusMouse()) .. ', cursor over the bar ' .. tostring(overBar))  -- diagnosis
    end
  end
  if orbitHeld then setPickBlocked("orbiting") return nil end
  if not state or not state.hotspots then setPickBlocked("no state from the car") return nil end
  if overBar then setPickBlocked("cursor over the tool bar") return nil end
  local ray = getCameraMouseRay()
  if not ray then setPickBlocked("no cursor ray") return nil end
  local hi = extensions.bug_interact
  if not hi then setPickBlocked("bug_interact not loaded") return nil end
  setPickBlocked(nil)
  return (hi.pick(vehId, ray, "workmode"))
end

-- cursor motion while orbiting (used when the game's mouse look doesn't arrive, see orbitInput)
local function trackCursor()
  if not orbitHeld then cursorLast = nil return end
  local canvas = getCanvas()
  if not canvas or not canvas.getCursorPosXY then return end
  local x, y = canvas:getCursorPosXY()
  if not x then return end
  if cursorLast then
    cursorDX = cursorDX + (x - cursorLast.x)
    cursorDY = cursorDY + (y - cursorLast.y)
  end
  cursorLast = {x = x, y = y}
end

local function onUpdate(dtReal)
  if not active then return end
  suppressGameTriggers()

  -- leave on the usual ways out
  local route = currentRouteName()
  if route == ROUTE_NAME then routeSeen = true
  elseif routeSeen then exit("route left: " .. tostring(route)) return end
  if updateReload(dtReal or 0) then hideUnicycle() stateAge = 0 return end
  if not getObjectByID(vehId) then exit("vehicle removed") return end
  -- a paused simulation (J) runs no vehicle Lua, so the car sends nothing: that's no reason to leave
  local paused = simTimeAuthority and simTimeAuthority.getPause and simTimeAuthority.getPause() == true
  stateAge = paused and 0 or stateAge + (dtReal or 0)
  if stateAge > STATE_TIMEOUT then exit("no state from the vehicle") return end
  if state and state.lidDeg and state.lidDeg < LID_CLOSED_DEG then exit("engine lid closed") return end

  -- the action map exists once the input reload is through
  if not mapPushed then
    tryPushActionMap()
    mapWaitTime = mapWaitTime + (dtReal or 0)
    if not mapPushed and mapWaitTime > MAP_PUSH_WARN_AFTER and mapWaitTime - (dtReal or 0) <= MAP_PUSH_WARN_AFTER then
      log('W', 'bug_worktop', 'action map ' .. ACTION_MAP .. ' still not found: mouse wheel, orbit and Esc will not work')
    end
  end

  hideUnicycle()
  trackCursor()

  local newHover = dragging or pickHotspot()  -- a dragged lever stays the hovered one
  if newHover ~= hover then
    hover = newHover
    if used ~= hover then used = nil end   -- left the part worked on: it lights up again when hovered next time
    sendUi()
  end
  updateDrag()

  -- the hovered hotspot lights up (not while it is worked on: the highlight would cover the moving part)
  if hover and hover ~= used and state then
    local hi = extensions.bug_interact
    if hi then hi.draw(vehId, hover) end
  end

  uiTimer = uiTimer + (dtReal or 0)
  if uiTimer >= UI_STATE_INTERVAL then
    uiTimer = 0
    sendUi()  -- value text of the hovered screw changes while scrolling
  end
end

-- The game's trigger system (core_vehicleTriggers) sets these engine flags in every onUpdate; onPreRender runs after
-- that, before the frame is drawn (the same as bug_doorDrag does while dragging). In the work mode none of the
-- car's normal triggers (doors, lids) light up or show a tooltip: they would offer actions that don't belong here
-- (and are blocked).
local function onPreRender()
  if not active then return end
  guihooks.triggerStream(TOOLTIP_STREAM, {})
  if not VehicleTrigger then return end
  VehicleTrigger.proximityRenderingEnabled = false
  VehicleTrigger.renderingEnabled = false
end

-- someone else chose a camera (e.g. the camera key): leave
-- (while the car is reloaded the game may reset the camera: take it back instead)
local function onGlobalCameraSet(name)
  if not active or name == CAMERA_NAME then return end
  if reload then core_camera.setByName(CAMERA_NAME, false, {}) return end
  exit("camera changed to " .. tostring(name))
end

-- (a reload switches away from the car and back, seated: ignored while the car is reloaded)
local function onVehicleSwitched()
  if active and not reload then exit("vehicle switched") end
end

local function onVehicleDestroyed(id)
  lastStates[id] = nil
  if active and id == vehId and not reload then exit("vehicle removed") end
end

local function onExtensionLoaded()
  ensureInputActions()  -- the first click on the carburettor loads this extension: get the inputs ready early
end

local function onExtensionUnloaded()
  exit("extension unloaded")
end

local function isActive() return active end

M.enter               = enter
M.exit                = exit
M.close               = close
M.setOverBar          = setOverBar
M.selectTool          = selectTool
M.onState             = onState
M.onWheel             = onWheel
M.onOrbitButton       = onOrbitButton
M.onGrab              = onGrab
M.onPanButton         = onPanButton
M.onCameraKey         = onCameraKey
M.onZoomKey           = onZoomKey
M.onCenterKey         = onCenterKey
M.onExitKey           = onExitKey
M.onReloadKey         = onReloadKey
M.getCameraTarget     = getCameraTarget
M.isActive            = isActive
M.onUpdate            = onUpdate
M.onPreRender         = onPreRender
M.onGlobalCameraSet   = onGlobalCameraSet
M.onVehicleSwitched   = onVehicleSwitched
M.onVehicleDestroyed  = onVehicleDestroyed
M.onExtensionLoaded   = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

return M
