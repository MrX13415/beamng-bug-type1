-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- The car's interactors, game-engine side (extension name: bug_interact).
--
-- An interactor is something on the car the player can point at and use (a handle, a knob, the carburettor). Each
-- part lists its own in its jbeam, section "interactors"; the car (vehicles/bug/lua/lib/interactors.lua) sends them
-- here once when it spawns: highlight mesh, the three nodes it moves with, its action, mode and pick sphere, and the
-- names of all highlight shells on the car. After that the car only sends what changes (a prop turned it, a
-- condition switched it on or off), and only while a camera is near it (watched). The node positions are read here
-- every frame (veh:getNodePosition), so nothing is streamed.
--
-- Highlight: every interactor has a shell in the car's DAE (<part>_highlight, material bug_highlight, a little larger
-- than the part), installed like the part, so the game draws it where the part is, deformed and moved by its prop.
-- The shells are hidden (veh:setMeshAlpha 0) and a lit one is shown with the config's alpha, pulsing if enabled;
-- several can be lit at once (draw, and the option group). Color and glow are the material's
-- (vehicles/bug/components/common/highlight.materials.json).
--
-- Picking: an interactor is picked by its shell's triangles (read from the DAE with bug/collada, posed like its
-- prop): what lights up is exactly what can be hit. An optional pick sphere makes small parts easier to hit. How far
-- it reacts and the highlight's alpha are in lua/common/bug/interact/config.lua.
--
-- Modes: "play" interactors are handled here while driving or walking: hovered by the cursor ray (or the screen
-- centre in the game's crosshair mode, same rules as core_vehicleTriggers), lit up, the game's tooltip shows the
-- action's title, and the left mouse button runs the action (actions_*.interaction.json: onDown on press, onUp on
-- release). "workmode" interactors are only picked by the work mode (bug_worktop, through pick / draw / get).
--
-- Next to the game's triggers: the closer one along the ray wins. While one of ours is hovered, the game's trigger
-- highlight and tooltip are switched off (onPreRender, after core_vehicleTriggers.onUpdate) and its click goes to
-- us: core_vehicleTriggers.onActionEvent is wrapped (the input actions triggerAction0…2 call it by name), because
-- its action maps can be above ours. While the game holds a trigger (a door drag), ours aren't picked.

local M = {}

-- bumped on every change: the vehicle reloads this extension when an older version is still loaded
M.version = 4

-- require keeps a module until the game engine Lua restarts: when this extension is reloaded (a newer version), the
-- config and the reader are read again too, else an older config without the new fields stays in use
package.loaded["bug/interact/config"] = nil
package.loaded["bug/collada"] = nil
local config = require("bug/interact/config")
local collada = require("bug/collada")

local ACTION_MAP = "BugInteract"     -- must match the actionMap in core/input/actions/bug_interact.json
local ACTIONS_FILE = "/lua/ge/extensions/core/input/actions/bug_interact.json"
local USE_ACTION = "bugInteractUse"  -- left mouse button (settings/inputmaps/mouse_bugInteract.json)
local TOOLTIP_STREAM = "vehicleTriggerCrosshairTarget"  -- the game's trigger tooltip
local WATCH_INTERVAL = 0.25          -- s

local cars = {}        -- vehicle id → {items = {id → item}, frames = {key → frame}, meshes = {name → mesh data},
                       -- shells = {name}, alpha = {name → alpha set}, lit = {name → true}, watched = bool}
local daeCache = {}    -- DAE path → {mesh name → mesh data or false (not in the file)}
local frameNo = 0      -- counts GE frames: node frames are computed once per frame
local hover = nil      -- {vehId, id} of the hovered "play" interactor
local held = nil       -- {vehId, id} pressed with the left mouse button, until it is let go
local mapPushed = false
local inputReloadRequested = false
local tooltipShown = false
local watchTimer = 0

-- ---- meshes -------------------------------------------------------------------------------------------------------

-- the DAE whose file name ends with `suffix` in the car's folder ("AW-Carburettor.dae" in the lore-free build)
local function findDae(veh, suffix)
  local dir = "/vehicles/" .. tostring(veh.JBeam) .. "/"
  local low = suffix:lower()
  for _, f in ipairs(FS:findFiles(dir, "*.dae", -1, true, false) or {}) do
    if f:lower():sub(-#low) == low then return f end
  end
  return nil
end

-- adds the bounding sphere for the quick test before the triangles
local function prepare(m)
  local b = m.box
  m.cx, m.cy, m.cz = (b[1] + b[4]) * 0.5, (b[2] + b[5]) * 0.5, (b[3] + b[6]) * 0.5
  local r2, t = 0, m.tris
  for i = 1, #t - 2, 3 do
    local dx, dy, dz = t[i] - m.cx, t[i + 1] - m.cy, t[i + 2] - m.cz
    local d2 = dx * dx + dy * dy + dz * dz
    if d2 > r2 then r2 = d2 end
  end
  m.r = math.sqrt(r2) + 0.001
  return m
end

-- reads the interactors' meshes from their DAEs (each file once; a mesh read before is kept)
local function loadMeshes(veh, car)
  local byDae = {}
  for _, item in pairs(car.items) do
    byDae[item.dae] = byDae[item.dae] or {}
    byDae[item.dae][item.mesh] = true
  end
  for dae, names in pairs(byDae) do
    local path = findDae(veh, dae)
    local cache = path and daeCache[path] or {}
    if path then daeCache[path] = cache end
    local missing = {}
    for name in pairs(names) do
      if cache[name] == nil then missing[name] = true end
    end
    if path and next(missing) then
      local text = readFile(path)
      local found = text and collada.read(text, missing) or {}
      for name in pairs(missing) do cache[name] = found[name] and prepare(found[name]) or false end
    end
    for name in pairs(names) do
      car.meshes[name] = cache[name] or nil
      if not cache[name] then
        log('E', 'bug_interact', 'highlight mesh ' .. name .. ' not found' .. (path and (' in ' .. path) or (': no DAE *' .. dae)))
      end
    end
  end
end

local function getMesh(car, item)
  return car.meshes[item.mesh]
end

-- ---- node frames --------------------------------------------------------------------------------------------------

local function basis(a, b, c)
  local ex = (b - a):normalized()
  local ey = c - a
  ey = (ey - ex * ey:dot(ex)):normalized()
  return ex, ey, ex:cross(ey)
end

local function v3(t) return vec3(t.x or t[1] or 0, t.y or t[2] or 0, t.z or t[3] or 0) end

-- car coordinates → world for one node frame, this frame: world = o + x·px + y·py + z·pz. The three nodes at rest
-- (jbeam positions, sent by the car) and now give the turn and move of everything that hangs on them.
local function carFrame(veh, car, key)
  local f = car.frames[key]
  if not f then return nil end
  if f.no == frameNo then return f.out end
  f.no = frameNo
  if not f.restBasis then
    local a, b, c = v3(f.rest[1]), v3(f.rest[2]), v3(f.rest[3])
    local ex, ey, ez = basis(a, b, c)
    f.restBasis = {a = a, ex = ex, ey = ey, ez = ez}
  end
  local r = f.restBasis
  local vp = veh:getPosition()
  local an = vp + veh:getNodePosition(f.cids[1])
  local exn, eyn, ezn = basis(an, vp + veh:getNodePosition(f.cids[2]), vp + veh:getNodePosition(f.cids[3]))
  local function dir(u) return exn * u:dot(r.ex) + eyn * u:dot(r.ey) + ezn * u:dot(r.ez) end
  local X, Y, Z = dir(vec3(1, 0, 0)), dir(vec3(0, 1, 0)), dir(vec3(0, 0, 1))
  f.out = {o = an - (X * r.a.x + Y * r.a.y + Z * r.a.z), x = X, y = Y, z = Z}
  return f.out
end

-- ---- pose (the part turned about its pivot, then moved, like its prop) -----------------------------------------------

-- turns (x, y, z) about the unit axis k by the angle with cos c and sin s (Rodrigues)
local function turn(x, y, z, kx, ky, kz, c, s)
  local d = (kx * x + ky * y + kz * z) * (1 - c)
  return x * c + (ky * z - kz * y) * s + kx * d,
         y * c + (kz * x - kx * z) * s + ky * d,
         z * c + (kx * y - ky * x) * s + kz * d
end

-- a point of the part at rest (car coordinates) → where it is now (car coordinates)
local function posed(item, mesh, x, y, z)
  if item.angle and item.angle ~= 0 then
    local a = math.rad(item.angle)
    local k = item.axis or {x = 1, y = 0, z = 0}
    local p = mesh and mesh.pivot or {x = 0, y = 0, z = 0}
    local rx, ry, rz = turn(x - p.x, y - p.y, z - p.z, k.x, k.y, k.z, math.cos(a), math.sin(a))
    x, y, z = rx + p.x, ry + p.y, rz + p.z
  end
  local o = item.offset
  if o then x, y, z = x + o.x, y + o.y, z + o.z end
  return x, y, z
end

-- ---- picking ------------------------------------------------------------------------------------------------------

-- distance along the ray (unit direction) to the sphere, nil if missed; 0 if the ray starts inside it
local function raySphere(px, py, pz, dx, dy, dz, cx, cy, cz, r)
  local ox, oy, oz = px - cx, py - cy, pz - cz
  local b = ox * dx + oy * dy + oz * dz
  local c = ox * ox + oy * oy + oz * oz - r * r
  local disc = b * b - c
  if disc < 0 then return nil end
  local s = math.sqrt(disc)
  if -b + s < 0 then return nil end
  return math.max(-b - s, 0)
end

-- closest triangle hit along the ray (Möller–Trumbore), nil if none
local function rayTris(t, px, py, pz, dx, dy, dz, maxT)
  local best = maxT
  local found = false
  for i = 1, #t - 8, 9 do
    local ax, ay, az = t[i], t[i + 1], t[i + 2]
    local e1x, e1y, e1z = t[i + 3] - ax, t[i + 4] - ay, t[i + 5] - az
    local e2x, e2y, e2z = t[i + 6] - ax, t[i + 7] - ay, t[i + 8] - az
    local hx, hy, hz = dy * e2z - dz * e2y, dz * e2x - dx * e2z, dx * e2y - dy * e2x
    local a = e1x * hx + e1y * hy + e1z * hz
    if a > 1e-14 or a < -1e-14 then
      local f = 1 / a
      local sx, sy, sz = px - ax, py - ay, pz - az
      local u = f * (sx * hx + sy * hy + sz * hz)
      if u >= 0 and u <= 1 then
        local qx, qy, qz = sy * e1z - sz * e1y, sz * e1x - sx * e1z, sx * e1y - sy * e1x
        local v = f * (dx * qx + dy * qy + dz * qz)
        if v >= 0 and u + v <= 1 then
          local tt = f * (e2x * qx + e2y * qy + e2z * qz)
          if tt > 0 and tt < best then best, found = tt, true end
        end
      end
    end
  end
  return found and best or nil
end

-- distance along the ray (world, unit direction) to the interactor, nil if missed or further than maxT
local function hitItem(veh, car, item, ro, rd, maxT)
  local f = carFrame(veh, car, item.frame)
  if not f then return nil end
  local mesh = getMesh(car, item)
  -- the ray in car coordinates (the frame's axes are orthonormal), then the part's turn and move taken back, so it
  -- can be tested against the part at rest
  local q = ro - f.o
  local px, py, pz = q:dot(f.x), q:dot(f.y), q:dot(f.z)
  local dx, dy, dz = rd:dot(f.x), rd:dot(f.y), rd:dot(f.z)
  local o = item.offset
  if o then px, py, pz = px - o.x, py - o.y, pz - o.z end
  if item.angle and item.angle ~= 0 then
    local a = -math.rad(item.angle)
    local k = item.axis or {x = 1, y = 0, z = 0}
    local c, s = math.cos(a), math.sin(a)
    local pv = mesh and mesh.pivot or {x = 0, y = 0, z = 0}
    local rx, ry, rz = turn(px - pv.x, py - pv.y, pz - pv.z, k.x, k.y, k.z, c, s)
    px, py, pz = rx + pv.x, ry + pv.y, rz + pv.z
    dx, dy, dz = turn(dx, dy, dz, k.x, k.y, k.z, c, s)
  end
  local best = nil
  local s = item.pick
  if s then
    local t = raySphere(px, py, pz, dx, dy, dz, s.x, s.y, s.z, s.r)
    if t and t <= maxT then best = t end
  end
  if mesh and item.pickMesh and raySphere(px, py, pz, dx, dy, dz, mesh.cx, mesh.cy, mesh.cz, mesh.r) then
    local t = rayTris(mesh.tris, px, py, pz, dx, dy, dz, best or maxT)
    if t then best = t end
  end
  return best
end

-- the closest interactor of this mode on the car hit by the ray (pos, dir: world), within maxT m: id, distance
local function pick(vehId, ray, mode, maxT)
  local car = cars[vehId]
  local veh = car and getObjectByID(vehId)
  if not veh or not ray then return nil end
  local ro, rd = vec3(ray.pos), vec3(ray.dir):normalized()
  local bestId, bestT = nil, maxT or math.huge
  for id, item in pairs(car.items) do
    if item.enabled and item.mode == (mode or "play") then
      local t = hitItem(veh, car, item, ro, rd, bestT)
      if t and t < bestT then bestId, bestT = id, t end
    end
  end
  return bestId, bestId and bestT or nil
end

-- ---- highlight (the shells' alpha) ------------------------------------------------------------------------------

-- lights the interactor up this frame (and the others of its group); false if it can't
local function draw(vehId, id)
  local car = cars[vehId]
  local item = car and car.items[id]
  if not item or not car.meshes[item.mesh] then return false end
  car.lit[item.mesh] = true
  if item.group then
    for _, other in pairs(car.items) do
      if other.group == item.group and other.mode == item.mode and other.enabled then car.lit[other.mesh] = true end
    end
  end
  return true
end

-- the alpha of a lit shell now: the config's, between alpha and pulse.alpha if it pulses (smooth sine)
local clock = os.clockhp or os.clock
local DEFAULT_ALPHA = 0.45
local function litAlpha()
  local h = config.highlight or {}
  local a = h.alpha or DEFAULT_ALPHA
  local p = h.pulse
  if not (p and p.enabled and p.alpha and (p.hz or 0) > 0) then return a end
  local f = 0.5 - 0.5 * math.cos(2 * math.pi * p.hz * clock())   -- 0 at alpha, 1 at pulse.alpha
  return a + (p.alpha - a) * f
end

local function setAlpha(veh, car, name, a)
  if car.alpha[name] == a then return end
  car.alpha[name] = a
  veh:setMeshAlpha(a, name, false)
end

-- once per frame, after everyone had the chance to draw: lit shells shown, all others hidden
local function applyHighlights()
  local a = nil
  for vehId, car in pairs(cars) do
    local veh = getObjectByID(vehId)
    if veh then
      for name, shown in pairs(car.alpha) do
        if shown > 0 and not car.lit[name] then setAlpha(veh, car, name, 0) end
      end
      for name in pairs(car.lit) do
        a = a or litAlpha()
        setAlpha(veh, car, name, a)
      end
    end
    table.clear(car.lit)
  end
end

local function hideAll(vehId, car)
  local veh = getObjectByID(vehId)
  if not veh then return end
  for _, name in ipairs(car.shells) do
    car.alpha[name] = 0
    veh:setMeshAlpha(0, name, false)
  end
end

-- where the interactor's middle is now, world (for the tooltip)
local function center(vehId, id)
  local car = cars[vehId]
  local item = car and car.items[id]
  local veh = item and getObjectByID(vehId)
  local f = veh and carFrame(veh, car, item.frame)
  if not f then return nil end
  local mesh = getMesh(car, item)
  local x, y, z
  if mesh then x, y, z = mesh.cx, mesh.cy, mesh.cz
  elseif item.pick then x, y, z = item.pick.x, item.pick.y, item.pick.z
  else return nil end
  x, y, z = posed(item, mesh, x, y, z)
  return f.o + f.x * x + f.y * y + f.z * z
end

local function get(vehId, id)
  local car = cars[vehId]
  return car and car.items[id] or nil
end

-- ---- registration (from the car) ----------------------------------------------------------------------------------

local function applyState(item, s)
  if s.enabled ~= nil then item.enabled = s.enabled end
  if s.angle ~= nil then item.angle = s.angle end
  if s.axis ~= nil then item.axis = s.axis end
  if s.offset ~= nil then item.offset = s.offset end
end

-- data = {frames = {key → {cids = {a, b, c}, rest = {{x, y, z}, …}}}, items = {{id, mesh, dae, frame, pick,
-- pickMesh, mode, action, tool, label, group, enabled, angle, axis, offset}, …}, shells = {name, …}}
local function register(vehId, data)
  local car = {items = {}, frames = {}, meshes = {}, shells = data.shells or {}, alpha = {}, lit = {}, watched = false}
  for key, f in pairs(data.frames or {}) do car.frames[key] = {cids = f.cids, rest = f.rest} end
  local n = 0
  for _, d in ipairs(data.items or {}) do
    local item = {id = d.id, mesh = d.mesh, dae = d.dae, frame = d.frame, pick = d.pick, pickMesh = d.pickMesh ~= false,
                  mode = d.mode or "play", action = d.action, tool = d.tool, label = d.label, group = d.group,
                  enabled = true}
    applyState(item, d)
    car.items[d.id] = item
    n = n + 1
  end
  local old = cars[vehId]
  cars[vehId] = car
  hideAll(vehId, car)
  local veh = getObjectByID(vehId)
  if veh then loadMeshes(veh, car) end
  if hover and hover.vehId == vehId then hover = nil end
  log('I', 'bug_interact', string.format('%d interactors on vehicle %d%s', n, vehId, old and ' (registered again)' or ''))
  watchTimer = 0   -- tell the car right away whether it is watched
end

-- changes = {id → {enabled, angle, axis, offset}}
local function update(vehId, changes)
  local car = cars[vehId]
  if not car then return end
  for id, s in pairs(changes or {}) do
    local item = car.items[id]
    if item then applyState(item, s) end
  end
end

local function unregister(vehId)
  cars[vehId] = nil
  if hover and hover.vehId == vehId then hover = nil end
  if held and held.vehId == vehId then held = nil end
end

-- ---- watching (which cars send their changes) ---------------------------------------------------------------------

local function workmodeActive()
  return bug_worktop and bug_worktop.isActive and bug_worktop.isActive() or false
end

local function updateWatch(dt)
  watchTimer = watchTimer - dt
  if watchTimer > 0 then return end
  watchTimer = WATCH_INTERVAL
  local cam = core_camera and core_camera.getPosition()
  if not cam then return end
  for vehId, car in pairs(cars) do
    local veh = getObjectByID(vehId)
    if not veh then
      unregister(vehId)
    else
      local watched = (cam - veh:getPosition()):length() < config.watchDistance or workmodeActive()
      if watched ~= car.watched then
        car.watched = watched
        veh:queueLuaCommand("if vehicle and vehicle.interactorsWatched then vehicle.interactorsWatched(" .. tostring(watched) .. ") end")
      end
    end
  end
end

-- ---- input --------------------------------------------------------------------------------------------------------

local function actionMapExists() return scenetree.findObject(ACTION_MAP .. "ActionMap") ~= nil end

-- the game may have read the action files before the mod was mounted (see bug_worktop): read them again
local function ensureInputActions()
  if inputReloadRequested or actionMapExists() then return end
  inputReloadRequested = true
  log('I', 'bug_interact', 'interactor input actions not loaded yet: reloading the input actions and bindings')
  if core_input_actions and core_input_actions.onFileChanged then core_input_actions.onFileChanged(ACTIONS_FILE) end
  if core_input_bindings and core_input_bindings.onFileChanged then core_input_bindings.onFileChanged(ACTIONS_FILE) end
end

-- pushed while a "play" interactor is hovered or held, so the left mouse button reaches it
local function setMap(on)
  if on == mapPushed then return end
  if on then
    if not actionMapExists() then ensureInputActions() return end
    pushActionMapHighestPriority(ACTION_MAP)
  else
    popActionMap(ACTION_MAP)
  end
  mapPushed = on
end

-- runs the interactor's action (value 1 = pressed, 0 = let go), the way the game runs a trigger's action
local function runAction(h, value)
  local item = get(h.vehId, h.id)
  if not item or not item.action then return end
  local vd = core_vehicle_manager.getVehicleData(h.vehId)
  local action = vd and vd.vdata and vd.vdata.inputActions and vd.vdata.inputActions[item.action]
  if not action then
    log('W', 'bug_interact', 'action ' .. tostring(item.action) .. ' of interactor ' .. tostring(h.id) .. ' not found (actionsEnabled of its part?)')
    return
  end
  core_input_actions.executeCommand(action, value, h.vehId, 0, h.id)
end

-- left mouse button (action bugInteractUse, or the game's triggerAction0 while ours is hovered)
local function onUse(value)
  if (value or 0) > 0.5 then
    if held or not hover then return end
    held = {vehId = hover.vehId, id = hover.id}
    runAction(held, 1)
  elseif held then
    local h = held
    held = nil
    runAction(h, 0)
    if not hover then setMap(false) end
  end
end

-- the game's trigger clicks: while ours is hovered or held they are ours
local gameActionEvent = nil
local function actionEvent(actionNumber, inputValue, player)
  if (player or 0) == 0 and (hover or held) then
    if actionNumber == 0 then onUse(inputValue) end
    return true
  end
  return gameActionEvent(actionNumber, inputValue, player)
end

local function wrapActionEvent()
  local vt = core_vehicleTriggers
  if not vt or not vt.onActionEvent or vt.onActionEvent == actionEvent then return end
  gameActionEvent = vt.onActionEvent
  vt.onActionEvent = actionEvent
end

local function unwrapActionEvent()
  local vt = core_vehicleTriggers
  if vt and vt.onActionEvent == actionEvent and gameActionEvent then vt.onActionEvent = gameActionEvent end
  gameActionEvent = nil
end

-- ---- hover (mode "play") ------------------------------------------------------------------------------------------

local function reachNow()
  local cam = core_camera and core_camera.getActiveCamName and core_camera.getActiveCamName(0) or ""
  if cam == "driver" or cam:find("^occupant%.") then return config.reach.seated end
  if gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking() then return config.reach.onFoot end
  return config.reach.outside
end

-- the ray the game's triggers use now (cursor or screen centre), nil when they can't be used
local function playRay(st)
  if st.useCursorCoordinates then
    local r = getCameraMouseRay()
    return r and {pos = vec3(r.pos), dir = vec3(r.dir)} or nil
  end
  if not st.canUseVehicleTriggerCrosshair or st.crosshairTimedOut then return nil end
  return {pos = core_camera.getPosition(), dir = core_camera.getForward()}
end

local function findHover()
  if workmodeActive() then return nil end
  local st = core_vehicleTriggers and core_vehicleTriggers.state
  if not st or not st.allowInteraction then return nil end
  if st.currentlyUsedTriggers and st.currentlyUsedTriggers[0] then return nil end   -- the game holds a trigger
  local ray = playRay(st)
  if not ray then return nil end
  local reach = reachNow()
  local best, bestT = nil, reach
  for vehId, car in pairs(cars) do
    local veh = car.watched and getObjectByID(vehId)
    if veh and (veh:getPosition() - ray.pos):length() < reach + 5 then
      local id, t = pick(vehId, ray, "play", bestT)
      if id and t < bestT then best, bestT = {vehId = vehId, id = id}, t end
    end
  end
  -- a game trigger closer along the same ray wins
  if best then
    local g = be:triggerRaycastClosest(bestT, st.useCursorCoordinates)
    if g and g.v ~= nil and g.t ~= nil then return nil end
  end
  return best
end

-- ---- tooltip ------------------------------------------------------------------------------------------------------

local function toScreen01(p)
  local canvas = scenetree.findObject("Canvas")
  local w, h
  if canvas and canvas.getWindowClientSizeXY then w, h = canvas:getWindowClientSizeXY() end
  local fov = core_camera.getFovRad and core_camera.getFovRad()
  if not (w and h and h > 0 and fov and fov > 0) then return nil end
  local q = p - core_camera.getPosition()
  local depth = q:dot(core_camera.getForward())
  if depth <= 0 then return nil end
  local halfTan = math.tan(fov * 0.5)
  local nx = q:dot(core_camera.getRight()) / (depth * halfTan * (w / h))
  local ny = q:dot(core_camera.getUp()) / (depth * halfTan)
  return (nx + 1) * 0.5, (1 - ny) * 0.5
end

local function actionTitle(h)
  local item = get(h.vehId, h.id)
  local vd = item and item.action and core_vehicle_manager.getVehicleData(h.vehId)
  local action = vd and vd.vdata and vd.vdata.inputActions and vd.vdata.inputActions[item.action]
  if not action or not action.title then return nil end
  return _tr and _tr(action.title) or action.title
end

-- where the interactor is on screen (0…1): the corners of its box (the highlight mesh's bounds, posed like the part)
local function screenBounds(vehId, id)
  local car = cars[vehId]
  local item = car and car.items[id]
  local veh = item and getObjectByID(vehId)
  local f = veh and carFrame(veh, car, item.frame)
  local mesh = f and getMesh(car, item)
  if not mesh then return nil end
  local b = mesh.box
  local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
  for _, x in ipairs({b[1], b[4]}) do
    for _, y in ipairs({b[2], b[5]}) do
      for _, z in ipairs({b[3], b[6]}) do
        local px, py, pz = posed(item, mesh, x, y, z)
        local sx, sy = toScreen01(f.o + f.x * px + f.y * py + f.z * pz)
        if sx then
          minX, maxX, minY, maxY = math.min(minX, sx), math.max(maxX, sx), math.min(minY, sy), math.max(maxY, sy)
        end
      end
    end
  end
  if minX > maxX then return nil end
  return {minX = minX, maxX = maxX, minY = minY, maxY = maxY, centerX = (minX + maxX) * 0.5, centerY = (minY + maxY) * 0.5}
end

-- The label goes beside the part, not on it, the way the game places its trigger labels
-- (core/vehicle/triggerLabelPlacement.lua): below a part in the middle of the screen, else on the side with the most
-- room. On the part it was under the cursor: the UI took the mouse, which switches the interaction off, the label
-- went away, the mouse came back, and so on (flicker).
local LABEL_OFFSET = "0.6em"
local function labelPlacement(b)
  local side
  if b.minX >= 0.15 and b.maxX <= 0.85 and b.minY >= 0.15 and b.maxY <= 0.85 then
    side = "bottom"
  else
    local room = {right = 1 - b.maxX, left = b.minX, top = b.minY, bottom = 1 - b.maxY}
    side = "right"
    for _, s in ipairs({"left", "top", "bottom"}) do
      if room[s] > room[side] then side = s end
    end
  end
  local x, y, tx, ty
  if side == "right" then x, y, tx, ty = b.maxX, b.centerY, LABEL_OFFSET, "-50%"
  elseif side == "left" then x, y, tx, ty = b.minX, b.centerY, "calc(-100% - " .. LABEL_OFFSET .. ")", "-50%"
  elseif side == "top" then x, y, tx, ty = b.centerX, b.minY, "-50%", "calc(-100% - " .. LABEL_OFFSET .. ")"
  else x, y, tx, ty = b.centerX, b.maxY, "-50%", LABEL_OFFSET end
  return clamp(x, 0, 1), clamp(y, 0, 1), tx, ty, side
end

local function round4(v) return v and math.floor(v * 10000 + 0.5) / 10000 or nil end

local function showTooltip(h)
  local payload = {action0 = actionTitle(h), bindingAction0 = USE_ACTION}
  local b = screenBounds(h.vehId, h.id)
  if b then
    payload.x, payload.y = round4(b.centerX), round4(b.centerY)
    payload.labelX, payload.labelY, payload.labelTx, payload.labelTy, payload.labelSide = labelPlacement(b)
    payload.labelX, payload.labelY = round4(payload.labelX), round4(payload.labelY)
    payload.boundsMinX, payload.boundsMaxX = round4(b.minX), round4(b.maxX)
    payload.boundsMinY, payload.boundsMaxY = round4(b.minY), round4(b.maxY)
    payload.boundsCenterX, payload.boundsCenterY = round4(b.centerX), round4(b.centerY)
  else
    local p = center(h.vehId, h.id)
    if p then
      local x, y = toScreen01(p)
      payload.x, payload.y = round4(x), round4(y)
    end
  end
  guihooks.triggerStream(TOOLTIP_STREAM, payload)
  tooltipShown = true
end

local function hideTooltip()
  if not tooltipShown then return end
  tooltipShown = false
  guihooks.triggerStream(TOOLTIP_STREAM, {})
  -- core_vehicleTriggers only sends its tooltip on changes: this makes it send it again
  local st = core_vehicleTriggers and core_vehicleTriggers.state
  if st then st.hoveredHitPosScreen01 = nil end
end

-- ---- per frame ----------------------------------------------------------------------------------------------------

local function onUpdate(dtReal)
  frameNo = frameNo + 1
  updateWatch(dtReal or 0)
  wrapActionEvent()

  hover = findHover()
  -- The game hides an idle mouse cursor after a few seconds, and its trigger system then counts the cursor as gone
  -- (state.cursorVisible), which switches the interaction off: the highlight vanished after 3 s. For its own hovered
  -- trigger it keeps these flags set (updateMouseInteractionState); it doesn't know ours, so they are kept set here.
  if hover or held then
    local st = core_vehicleTriggers and core_vehicleTriggers.state
    if st then st.cursorVisible, st.cursorVisibility = true, true end
  end
  if held and not get(held.vehId, held.id) then held = nil end
  -- the click on the carburettor starts the work mode, whose action map then takes the mouse button: the release
  -- never arrives here, so the interactor is let go now
  if held and workmodeActive() then
    local h = held
    held = nil
    runAction(h, 0)
  end
  setMap(hover ~= nil or held ~= nil)

  local lit = held or hover
  if lit then draw(lit.vehId, lit.id) end
end

local function onPreRender()
  applyHighlights()
  local lit = held or hover
  if not lit then hideTooltip() return end
  if VehicleTrigger then VehicleTrigger.renderingEnabled = false end   -- the game's trigger further along the ray
  if config.tooltip then showTooltip(lit) end
end

local function onVehicleDestroyed(vehId)
  unregister(vehId)
end

local function onExtensionLoaded()
  ensureInputActions()
  wrapActionEvent()
  -- after a reload of this extension (or of the game engine Lua) the cars must send their interactors again
  be:queueAllObjectLua("if vehicle and vehicle.interactorsRegister then vehicle.interactorsRegister() end")
end

local function onExtensionUnloaded()
  for vehId, car in pairs(cars) do hideAll(vehId, car) end
  unwrapActionEvent()
  if mapPushed then popActionMap(ACTION_MAP) end
  mapPushed = false
  hideTooltip()
end

M.register   = register
M.update     = update
M.unregister = unregister
M.pick       = pick
M.draw       = draw
M.get        = get
M.onUse      = onUse

M.onUpdate            = onUpdate
M.onPreRender         = onPreRender
M.onVehicleDestroyed  = onVehicleDestroyed
M.onExtensionLoaded   = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

return M
