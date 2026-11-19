-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- The car's interactors, vehicle side (driven by vehicle.lua: setup / update).
--
-- An interactor is something on the car the player can point at and use. Each part lists its own in its jbeam:
--
--   "interactors": [
--     ["id", "nodeRef:", "nodeX:", "nodeY:", "mesh"],
--     {"dae":"Carburettor.dae"},
--     ["engineBayWork", "e6l", "e6r", "e5l", "engine_highlight", {"action":"engineBayWork", "when":"workModeAvailable"}],
--   ],
--
--   id         unique on the car; the work mode's hotspots use it too (lib/workmode.lua)
--   nodes      origin, x direction, y direction: the interactor moves and turns with these three nodes
--   mesh       its highlight shell: a mesh <part>_highlight with the material bug_highlight, a little larger than
--              the part (made in Blender, or by build/py/importdae.py), installed like the part (a flexbody, or a
--              prop with the part's row if the part moves). It is hidden; GE shows it while the interactor is
--              pointed at, and picks the interactor by its triangles.
--   options (all optional except dae):
--     dae      the DAE file with the mesh (the end of its file name, so it is also found as "AW-…" in the lore-free
--              build); usually set once for all rows with a {"dae":…} line above them
--     action   an action of actions_*.interaction.json (in the part's actionsEnabled): left mouse button down runs
--              its onDown (or onChange with 1), up its onUp (or onChange with 0)
--     mode     "play" (default: driving, walking) or "workmode" (only in the work mode at the engine bay)
--     when     a condition from CONDITIONS below: the interactor only exists while it is true
--     prop     the jbeam prop (its mesh name) whose turn and move the picking follows; default: the shell itself
--              if it is a prop
--     pick     {"x", "y", "z", "r"}: an extra sphere that also picks it (car coordinates at rest, m), for small parts
--     pickMesh false: picked only by the sphere
--     group    interactors with the same group light up together when one of them is pointed at
--     tool, label  for the work mode's tool bar (no tool: it can only be pointed at)
--
-- At spawn the list goes to the GE extension bug_interact (picking, highlight, input), with the rest positions of
-- the nodes and the names of all highlight shells on the car (GE hides them); GE reads the node positions itself
-- every frame. After that only changes are sent (a prop turned or moved the part, a condition switched it on or
-- off), and only while GE says a camera is near the car (watched).

local M = {}

local misc = require("vehicles/bug/lua/misc")
local workmode = require("vehicles/bug/lua/lib/workmode")

-- conditions an interactor can be limited to (option "when"); add new ones here
local CONDITIONS = {
  workModeAvailable = function() return workmode.available() end,
}

local EPS_DEG = 0.05      -- deg  smaller turns of a part aren't sent
local EPS_M   = 0.00005   -- m    nor smaller moves

local HL_SUFFIX = "_highlight"

local items = {}          -- {id, mesh, dae, frame, pick, pickMesh, mode, action, tool, label, group, when, prop}
local shells = {}         -- names of all highlight shells installed on the car
local frames = {}         -- key "cid,cid,cid" → {cids, rest}
local sent = {}           -- id → the state GE has
local watched = false

local function jbeamPos(cid)
  local p = v.data.nodes[cid].pos
  return vec3(p.x, p.y, p.z)
end

local function t3(q) return {x = q.x, y = q.y, z = q.z} end

-- the prop whose mesh is this one (the game may rename a prop's mesh when it loads it: the jbeam name is then in
-- originalMesh)
local function findProp(mesh)
  for _, p in pairs(v.data.props or {}) do
    if (p.originalMesh or p.mesh) == mesh then return p end
  end
  return nil
end

-- a prop's axes, as the game sets them up (jbeam/sections/meshs.lua): x = ref → idX and y = ref → idY, not
-- normalized (a translation of 1 moves by that whole node vector), z = y × x normalized (meters). It turns about one
-- of them (the one its rotation is on).
local function propSetup(p, id)
  local o = jbeamPos(tonumber(p.idRef))
  local ax, ay = jbeamPos(tonumber(p.idX)) - o, jbeamPos(tonumber(p.idY)) - o
  local az = ay:cross(ax):normalized()
  local r = p.rotation or {}
  local axes = {x = ax:normalized(), y = ay:normalized(), z = az}
  local comp, n = "x", 0
  for _, c in ipairs({"x", "y", "z"}) do
    if (r[c] or 0) ~= 0 then comp, n = c, n + 1 end
  end
  if n > 1 then
    log('W', 'bug.interactors', 'prop of ' .. tostring(id) .. ' turns about more than one axis: its picking only follows the ' .. comp .. ' turn')
  end
  return {p = p, ax = ax, ay = ay, az = az, comp = comp, axis = axes[comp]}
end

-- where the prop has turned and moved its mesh now, the same way the game moves props (value = clamp(electrics
-- value · multiplier, min, max) + offset; rotation and translation times value, plus the base rotation; rotations
-- are in radians once loaded): degrees about the axis, and the shift in car coordinates
local function propPose(pr)
  local p = pr.p
  local val = (electrics.values[p.func] or 0) * (p.multiplier or 1)
  val = math.min(math.max(val, p.min or -math.huge), p.max or math.huge) + (p.offset or 0)
  local r, t, br = p.rotation or {}, p.translation or {}, p.baseRotation or {}
  local c = pr.comp
  return math.deg((r[c] or 0) * val + (br[c] or 0)),
    pr.ax * ((t.x or 0) * val) + pr.ay * ((t.y or 0) * val) + pr.az * ((t.z or 0) * val)
end

-- what GE needs to know of an interactor now
local function stateOf(it)
  local s = {enabled = true}
  if it.when then
    local cond = CONDITIONS[it.when]
    s.enabled = cond ~= nil and cond() and true or false
  end
  if it.prop then
    local deg, shift = propPose(it.prop)
    s.angle, s.axis, s.offset = deg, t3(it.prop.axis), t3(shift)
  end
  return s
end

local function changed(a, b)
  if not a then return true end
  if a.enabled ~= b.enabled then return true end
  if b.angle and math.abs((a.angle or 0) - b.angle) > EPS_DEG then return true end
  local o1, o2 = a.offset, b.offset
  if o2 and (math.abs(o1.x - o2.x) > EPS_M or math.abs(o1.y - o2.y) > EPS_M or math.abs(o1.z - o2.z) > EPS_M) then return true end
  return false
end

-- sends the whole list to GE (at spawn, and when GE asks after its Lua was reloaded)
local function register()
  if #items == 0 and #shells == 0 then return end
  local list = {}
  sent = {}
  for _, it in ipairs(items) do
    local s = stateOf(it)
    sent[it.id] = s
    list[#list + 1] = {id = it.id, mesh = it.mesh, dae = it.dae, frame = it.frame, pick = it.pick,
                       pickMesh = it.pickMesh, mode = it.mode, action = it.action, tool = it.tool, label = it.label,
                       group = it.group, enabled = s.enabled, angle = s.angle, axis = s.axis, offset = s.offset}
  end
  misc.geCall("bug_interact", "bug_interact.register(" .. obj:getId() .. ", "
    .. serialize({frames = frames, items = list, shells = shells}) .. ")")
end

-- every highlight shell installed on the car (flexbodies and props named …_highlight)
local function findShells()
  local list, seen = {}, {}
  local function add(mesh)
    if type(mesh) == "string" and mesh:sub(-#HL_SUFFIX) == HL_SUFFIX and not seen[mesh] then
      seen[mesh] = true
      list[#list + 1] = mesh
    end
  end
  for _, fb in pairs(v.data.flexbodies or {}) do add(fb.mesh) end
  for _, p in pairs(v.data.props or {}) do add(p.originalMesh or p.mesh) end
  return list
end

-- reads the interactors of the installed parts (jbeam section "interactors") and sends them to GE
local function setup()
  items, frames, sent, watched = {}, {}, {}, false
  shells = findShells()
  for _, row in pairs(v.data.interactors or {}) do
    -- the game moves a jbeam row's "id" to "name" when it reads the section (jbeam/tableSchema.lua)
    local id = type(row) == "table" and (row.name or row.id) or nil
    if id then
      local a, b, c = row.nodeRef, row.nodeX, row.nodeY
      if not (a and b and c) then
        log('W', 'bug.interactors', 'interactor ' .. tostring(id) .. ': its three nodes are missing')
      elseif type(row.mesh) ~= "string" or not row.dae then
        log('W', 'bug.interactors', 'interactor ' .. tostring(id) .. ': no highlight mesh or no dae')
      else
        local key = a .. "," .. b .. "," .. c
        frames[key] = frames[key] or {cids = {a, b, c}, rest = {t3(jbeamPos(a)), t3(jbeamPos(b)), t3(jbeamPos(c))}}
        local it = {id = id, mesh = row.mesh, dae = row.dae, frame = key, pick = row.pick,
                    pickMesh = row.pickMesh ~= false, mode = row.mode, action = row.action, tool = row.tool,
                    label = row.label, group = row.group, when = row.when}
        if row.when and not CONDITIONS[row.when] then
          log('W', 'bug.interactors', 'interactor ' .. tostring(id) .. ': unknown condition ' .. tostring(row.when) .. ' (it stays off)')
        end
        local p = findProp(row.prop or row.mesh)
        if p then
          it.prop = propSetup(p, id)
        elseif row.prop then
          log('W', 'bug.interactors', 'interactor ' .. tostring(id) .. ': prop ' .. tostring(row.prop) .. ' not found, its picking won\'t move')
        end
        items[#items + 1] = it
      end
    end
  end
  log('D', 'bug.interactors', string.format('%d interactors and %d highlight shells in the installed parts', #items, #shells))
  register()
end

-- every frame: the changes since the last send, while watched. Work mode interactors only while the work mode is
-- on (the throttle lever moves all the time while driving): they are sent afresh when it starts.
local function update(dt)
  if not watched or #items == 0 then return end
  local changes = nil
  local wm = workmode.isActive()
  for _, it in ipairs(items) do
    local s = (it.mode ~= "workmode" or wm) and stateOf(it) or nil
    if not s then
      sent[it.id] = nil
    elseif changed(sent[it.id], s) then
      sent[it.id] = s
      changes = changes or {}
      changes[it.id] = s
    end
  end
  if changes then
    obj:queueGameEngineLua("if bug_interact then bug_interact.update(" .. obj:getId() .. ", " .. serialize(changes) .. ") end")
  end
end

-- GE: a camera is near the car (send changes) or not any more
local function setWatched(on)
  watched = on and true or false
  if watched then sent = {} end   -- the next update sends everything as it is now
end

M.setup      = setup
M.update     = update
M.register   = register
M.setWatched = setWatched

return M
