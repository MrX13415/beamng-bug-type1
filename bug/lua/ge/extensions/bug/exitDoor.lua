-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Game-engine side of "open the door before getting in or out" (extension name: bug_exitDoor).
-- Loaded by the vehicle (vehicles/bug/lua/vehicle.lua, onInit), which registers itself here.
--
-- The game's enter / exit key (F, action toggleWalkingMode) calls gameplay_walk.toggleWalkingMode(player).
-- This extension wraps that function. When the player gets out of a registered Bug, or gets in while
-- walking up to one:
--   1. the door on the player's side opens (vehicle.exitDoorOpen: handle animation + swing open),
--   2. after OPEN_WAIT seconds the game's own exit / entry runs (the original toggleWalkingMode),
--   3. the door stays open (CLOSE_AFTER_EXIT / CLOSE_AFTER_ENTER switch on closing it after CLOSE_WAIT).
-- If the door is already open, the player gets in / out at once.
-- Pressing F again while waiting goes at once. Other vehicles, a paused game and a player who isn't
-- allowed to get out (driving too fast) go straight to the game's own function.

local M = {}

-- bumped on every change: the vehicle reloads this extension when an older version is still loaded
M.version = 8

--local OPEN_WAIT        = 1.2   -- old: for the short handle-click opening
--local OPEN_WAIT        = 1.8   -- old: for the swing to 75 deg
--local OPEN_WAIT        = 1.5   -- old: for the swing to 45 deg
local OPEN_WAIT        = 1.7   -- s  F -> getting in / out (latch releases after ~0.6 s, then the door swings to 60 deg)
--local CLOSE_AFTER_EXIT = true  -- old: closed the door behind the player
local CLOSE_AFTER_EXIT  = false -- pull the door shut again after getting out
local CLOSE_AFTER_ENTER = false -- pull the door shut again after getting in
local CLOSE_WAIT        = 1.0   -- s  getting in / out -> door closing

-- getting out from a passenger seat. The Bug has no occupant slots, so the game's seat system doesn't know
-- the seat (getSeatExitData returns nil) and the driver's door was always used. The seat comes from the
-- active onboard camera instead. From a rear seat the front seat on that side folds its backrest forward and
-- slides all the way forward (vehicle.exitSeatForward) while the door opens.
local SEAT_CAMS = {
  ["onboard.rider"]            = {door = "FR"},
  ["onboard.rider.back.left"]  = {door = "FL", rear = true},
  ["onboard.rider.back.right"] = {door = "FR", rear = true},
}
local OPEN_WAIT_REAR    = 2.2   -- s  F -> getting out from a rear seat (the front seat needs time to fold / slide)

-- where the player stands after getting out. The game puts the player outside the car's current bounding
-- box, which the wide open door makes much wider: the player ended up at the outer edge of the door.
-- Instead the spot is in the door opening, just behind the door's rear edge (wherever the door is), a little
-- outside the body. The game's free-spot search treated the open door as in the way and moved the player in
-- front of the door, so for this spot only static objects are checked (other vehicles: see spotBlocked).
local OWN_EXIT_SPOT     = true  -- false: the game's own exit spot
--local EXIT_SPOT_FRAC    = 0.65  -- old: fixed point between hinge and B-pillar; the game moved the player in front of the door
--local EXIT_SPOT_OUT     = 0.55
local EXIT_BEHIND_EDGE  = 0.30  -- m  behind the door's rear edge (d9), towards the rear of the car
local EXIT_MAX_BEHIND   = 0.15  -- m  but at most this far behind the B-pillar (body latch node q14)
local EXIT_SPOT_OUT     = 0.45  -- m  outside the latch node (body side at the B-pillar)

-- The walker (a small physics vehicle) appears right next to the open door and bumped into it, which dented
-- the door. It is a ghost (no collision with other vehicles, obj:setGhostEnabled, as the game does after an
-- instability) until it is clear of the door, or at most GHOST_MAX_TIME.
local GHOST_WALKER      = true
local GHOST_CLEAR       = 0.6   -- m  horizontal distance from the door (hinge dh1 -> rear edge d9) to end it
local GHOST_MAX_TIME    = 6     -- s

local registered = {}   -- vehId -> true
local ghosts     = {}   -- list of {uniId, vehId, door, t}
local pending    = {}   -- player -> {player, vehId, door, t, enter}
local closing    = {}   -- list of {vehId, door, t}

local orig      -- the game's gameplay_walk.toggleWalkingMode
local wrapper

local function isPaused()
  return simTimeAuthority and simTimeAuthority.getPause and simTimeAuthority.getPause()
end

-- door on the side the player gets out: from the seat's exit point if the seat system knows it,
-- otherwise the driver's door (left, or right for a right-hand-door camera).
-- Getting in: the side of the vehicle the walking player stands on (sidePos).
local function pickDoor(veh, vehId, player, sidePos)
  if not sidePos and core_camera and core_camera.getActiveCamName then
    local seat = SEAT_CAMS[core_camera.getActiveCamName(player) or ""]
    if seat then return seat.door, seat.rear end
  end
  local exitPos = sidePos
  if not exitPos and gameplay_seatOccupants and gameplay_seatOccupants.getSeatExitData then
    local ok, p = pcall(gameplay_seatOccupants.getSeatExitData, player, vehId)
    if ok then exitPos = p end
  end
  if exitPos then
    local vd = core_vehicle_manager.getVehicleData(vehId)
    local refNodes = vd and vd.vdata and vd.vdata.refNodes and vd.vdata.refNodes[0]
    if refNodes and refNodes.ref and refNodes.left then
      local ref  = veh:getNodePosition(refNodes.ref)
      local left = (veh:getNodePosition(refNodes.left) - ref):normalized()
      local side = (vec3(exitPos) - (veh:getPosition() + ref)):dot(left)
      return side >= 0 and "FL" or "FR"
    end
  end
  local _, _, rightHandDoor = core_camera.getDriverData(veh)
  return rightHandDoor and "FR" or "FL"
end

local nodeCids = {}  -- vehId -> {name -> cid}
local function nodeCid(vehId, name)
  local t = nodeCids[vehId]
  if not t then
    t = {}
    local vd = core_vehicle_manager.getVehicleData(vehId)
    local nodes = vd and vd.vdata and vd.vdata.nodes
    if nodes then
      for _, n in pairs(nodes) do
        if n.name then t[n.name] = n.cid end
      end
    end
    nodeCids[vehId] = t
  end
  return t[name]
end

-- exit spot in the door opening, facing the car; nil if the nodes aren't there.
-- Measured from the body latch node q14 (B-pillar): "rear" = hinge -> latch direction, "out" = sideways.
local function exitSpot(veh, vehId, door)
  local sfx = door == "FL" and "l" or "r"
  local hinge, latch, edge = nodeCid(vehId, "dh1" .. sfx), nodeCid(vehId, "q14" .. sfx), nodeCid(vehId, "d9" .. sfx)
  local vd = core_vehicle_manager.getVehicleData(vehId)
  local refNodes = vd and vd.vdata and vd.vdata.refNodes and vd.vdata.refNodes[0]
  if not hinge or not latch or not edge or not refNodes or not refNodes.ref or not refNodes.left then return nil end

  local vpos = veh:getPosition()
  local ref  = veh:getNodePosition(refNodes.ref)
  local left = (veh:getNodePosition(refNodes.left) - ref):normalized()
  local out  = sfx == "l" and left or -left        -- outwards on the door's side
  local h = vpos + veh:getNodePosition(hinge)
  local q = vpos + veh:getNodePosition(latch)
  local e = vpos + veh:getNodePosition(edge)       -- door rear edge, top
  local rear = q - h
  rear = rear - out * rear:dot(out)
  rear.z = 0
  if rear:length() < 1e-3 then return nil end
  rear = rear:normalized()

  local along = math.min((e - q):dot(rear) + EXIT_BEHIND_EDGE, EXIT_MAX_BEHIND)
  local p = q + rear * along + out * EXIT_SPOT_OUT

  local front = -out
  front.z = 0
  return p, quatFromDir(front:normalized(), vec3(0, 0, 1))
end

-- another vehicle (not this Bug, not a walker) close to the spot: use the game's own placement then
local function spotBlocked(pos, vehId)
  for i = 0, be:getObjectCount() - 1 do
    local o = be:getObject(i)
    if o and o:getId() ~= vehId and not (o.getJBeamFilename and o:getJBeamFilename() == "unicycle") then
      local box = o:getWorldBox()
      local c, ext = box:getCenter(), box:getExtents() / 2
      if math.abs(pos.x - c.x) < ext.x + 0.4 and math.abs(pos.y - c.y) < ext.y + 0.4
         and math.abs(pos.z - c.z) < ext.z + 1 then
        return true
      end
    end
  end
  return false
end

-- the game's exit, at our spot. While it runs, spawn.safeTeleport only checks static objects (not this Bug,
-- whose open door made the game move the player in front of it).
local function exitAt(player, pos, rot)
  local safeTeleport = spawn and spawn.safeTeleport
  if safeTeleport then
    spawn.safeTeleport = function(veh, p, r, checkOnlyStatics, ...)
      return safeTeleport(veh, p, r, true, ...)
    end
  end
  local ok, err = pcall(gameplay_walk.setWalkingMode, true, pos, rot, nil, player)
  if safeTeleport then spawn.safeTeleport = safeTeleport end
  if not ok then log("E", "bug_exitDoor", tostring(err)) end
end

local function vehicleInFrontId(player)
  local walk = gameplay_walk
  local veh = walk and walk.getVehicleInFront and walk.getVehicleInFront(player)
  return veh and veh:getId()
end

local function runExit(job)
  if not orig then return end
  if job.enter then
    -- walked away from the Bug meanwhile, or already in a vehicle: leave it (the door stays open)
    if not gameplay_walk.isWalking(job.player) or vehicleInFrontId(job.player) ~= job.vehId then return end
  elseif be:getPlayerVehicleID(job.player) ~= job.vehId then
    return  -- switched vehicle meanwhile
  end
  --orig(job.player) -- old: the game's exit spot, outside the open door
  local pos, rot
  if OWN_EXIT_SPOT and not job.enter and not multiplayer_vehicleSync and gameplay_walk.setWalkingMode then
    local veh = be:getObjectByID(job.vehId)
    if veh then pos, rot = exitSpot(veh, job.vehId, job.door) end
  end
  if pos and spotBlocked(pos, job.vehId) then pos = nil end
  if pos then
    exitAt(job.player, pos, rot)
  else
    orig(job.player)
  end
  if GHOST_WALKER and not job.enter then
    local uni = gameplay_walk.getCurrentUnicycle and gameplay_walk.getCurrentUnicycle(job.player)
    if uni then
      be:queueObjectFastLua(uni:getId(), "obj:setGhostEnabled(true)")
      table.insert(ghosts, {uniId = uni:getId(), vehId = job.vehId, door = job.door, t = 0})
    end
  end
  local close = job.enter and CLOSE_AFTER_ENTER or (not job.enter and CLOSE_AFTER_EXIT)
  if close and not job.noClose then
    table.insert(closing, {vehId = job.vehId, door = job.door, t = CLOSE_WAIT})
  end
end

wrapper = function(player)
  local p = player or 0
  if not orig then return end
  if p < 0 then return orig(player) end

  local job = pending[p]
  if job then  -- F again while the door opens: get out now
    pending[p] = nil
    return runExit(job)
  end

  local walk = gameplay_walk
  if not walk or isPaused() then return orig(player) end

  local enter = walk.isWalking(p)
  local vehId, sidePos
  if enter then
    -- walking: the vehicle the game would put the player in
    vehId = vehicleInFrontId(p)
    local unicycle = walk.getCurrentUnicycle and walk.getCurrentUnicycle(p)
    sidePos = unicycle and vec3(unicycle:getPosition())
    if not vehId or not sidePos or (walk.canSetWalkingMode and not walk.canSetWalkingMode(false, nil, p)) then
      return orig(player)
    end
  else
    vehId = be:getPlayerVehicleID(p)
    if walk.canSetWalkingMode and not walk.canSetWalkingMode(true, nil, p) then return orig(player) end
  end
  if not registered[vehId] then return orig(player) end
  local veh = be:getObjectByID(vehId)
  if not veh then return orig(player) end

  local door, rear = pickDoor(veh, vehId, p, sidePos)
  local wait = rear and OPEN_WAIT_REAR or OPEN_WAIT
  pending[p] = {player = p, vehId = vehId, door = door, t = wait, enter = enter, minWait = rear and wait - OPEN_WAIT or 0}
  if rear then veh:queueLuaCommand(string.format("vehicle.exitSeatForward(%q)", door)) end
  veh:queueLuaCommand(string.format("vehicle.exitDoorOpen(%q)", door))
end

local function patch()
  local walk = gameplay_walk
  if not walk or walk.toggleWalkingMode == wrapper then return end
  orig = walk.toggleWalkingMode
  walk.toggleWalkingMode = wrapper
end

local function unpatch()
  local walk = gameplay_walk
  if walk and orig and walk.toggleWalkingMode == wrapper then walk.toggleWalkingMode = orig end
end

-- vehicle -> here, from onInit
local function register(vehId)
  registered[vehId] = true
  nodeCids[vehId] = nil  -- respawned / other parts: node ids may have changed
  patch()
end

-- vehicle -> here: the door was already open, so get out at once (from a rear seat: once the front seat
-- has moved, minWait) and leave it open
local function doorAlreadyOpen(vehId)
  for _, job in pairs(pending) do
    if job.vehId == vehId then job.t, job.noClose = math.min(job.t, job.minWait or 0), true end
  end
end

-- horizontal distance from point p to the door (segment hinge -> rear edge); nil if the nodes are missing
local function doorDistance(vehId, door, p)
  local veh = be:getObjectByID(vehId)
  if not veh then return nil end
  local sfx = door == "FL" and "l" or "r"
  local hinge, edge = nodeCid(vehId, "dh1" .. sfx), nodeCid(vehId, "d9" .. sfx)
  if not hinge or not edge then return nil end
  local a = veh:getPosition() + veh:getNodePosition(hinge)
  local b = veh:getPosition() + veh:getNodePosition(edge)
  a.z, b.z = 0, 0
  local q = vec3(p.x, p.y, 0)
  local ab = b - a
  local t = ab:squaredLength() > 1e-6 and clamp((q - a):dot(ab) / ab:squaredLength(), 0, 1) or 0
  return (q - (a + ab * t)):length()
end

local function updateGhosts(dt)
  for i = #ghosts, 1, -1 do
    local g = ghosts[i]
    g.t = g.t + dt
    local uni = be:getObjectByID(g.uniId)
    local done = not uni or g.t >= GHOST_MAX_TIME
    if not done then
      local dist = doorDistance(g.vehId, g.door, uni:getPosition())
      done = dist == nil or dist > GHOST_CLEAR
    end
    if done then
      table.remove(ghosts, i)
      if uni then be:queueObjectFastLua(g.uniId, "obj:setGhostEnabled(false)") end
    end
  end
end

local function onUpdate(dtReal, dtSim)
  updateGhosts(dtSim or dtReal)
  if next(registered) == nil then return end
  patch()  -- gameplay_walk may have been reloaded

  for p, job in pairs(pending) do
    job.t = job.t - (dtSim or dtReal)
    if job.t <= 0 then
      pending[p] = nil
      runExit(job)
    end
  end

  for i = #closing, 1, -1 do
    local c = closing[i]
    c.t = c.t - (dtSim or dtReal)
    if c.t <= 0 then
      table.remove(closing, i)
      local veh = be:getObjectByID(c.vehId)
      if veh then veh:queueLuaCommand(string.format("vehicle.exitDoorClose(%q)", c.door)) end
    end
  end
end

local function onVehicleDestroyed(vehId)
  registered[vehId] = nil
  nodeCids[vehId] = nil
  for p, job in pairs(pending) do
    if job.vehId == vehId then pending[p] = nil end
  end
  for i = #closing, 1, -1 do
    if closing[i].vehId == vehId then table.remove(closing, i) end
  end
end

-- after a reload (version bump) the table is empty: pick up the Bugs that are already spawned
local function onExtensionLoaded()
  for i = 0, be:getObjectCount() - 1 do
    local veh = be:getObject(i)
    if veh and veh.getJBeamFilename and veh:getJBeamFilename() == "bug" then registered[veh:getId()] = true end
  end
end

local function onExtensionUnloaded()
  unpatch()
end

M.register            = register
M.doorAlreadyOpen     = doorAlreadyOpen
M.onUpdate            = onUpdate
M.onVehicleDestroyed  = onVehicleDestroyed
M.onExtensionLoaded   = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

return M
