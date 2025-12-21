-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- by MrX13415

local M = {}

--M.dependencies = {'animation'}

local updateTimer = 2   -- Make sure the first call is immediately
local openingUpdateTimer = 2   -- Make sure the first call is immediately

local cabinFilterTimer = 2
local cabinFilterCoef = 1

local NodeNameSoundSFX = "dsh"
local nodeSFX = nil

local parts = {
  ventL    = {broken = false, deformGroup = "ventglass_FL_break"},
  ventR    = {broken = false, deformGroup = "ventglass_FR_break"},
  windowFL = {broken = false, deformGroup = "doorglass_FL_break"},
  windowFR = {broken = false, deformGroup = "doorglass_FR_break"},
  windowRL = {broken = false, deformGroup = "sidewindow_RL_break"},
  windowRR = {broken = false, deformGroup = "sidewindow_RR_break"},
  windowR  = {broken = false, deformGroup = "rearwindow_break"},
  ragtop   = {broken = false, name = "ragtopF", cid = nil},
}

local lightMessageLookup = {
  [0] = "Interior Light: Off",
  [1] = "Interior Light: On",
}

local hazardEnabled = false
local foglightstate = 0

local function hasPower() return electrics.values.ignitionLevel > 0 end

local function createSFX(event, node, eventID)
  local soundNode = getNodeIDbyName(node)
  local sound = obj:createSFXSource2(event, "AudioClosestLoop3D", eventID, soundNode, 0)
  return sound
end

local function playSound(soundname)
  sounds.playSoundOnceAtNode(soundname, getNodeIDbyName(nodeSFX), 1, 1, 0, 0)
end

local function updatePartBroken(part)
  if part.broken then return true end
  if #part.deformGroup == 0 then return part.broken end

  local group = beamstate.deformGroupDamage[part.deformGroup]
  if group and group.eventCount > 0 then 
    part.broken = true
  end
  return part.broken
end
local function updatePartBrokenBeam(part)
  if part.broken then return true end
  if part.cid then    
    part.broken = obj:beamIsBroken(part.cid)
  end
  return part.broken
end
local function checkPartsBroken()
  updatePartBroken(parts.ventL)
  updatePartBroken(parts.ventR)
  updatePartBroken(parts.windowFL)
  updatePartBroken(parts.windowFR)
  updatePartBroken(parts.windowRL)
  updatePartBroken(parts.windowRR)
  updatePartBroken(parts.windowR)

  updatePartBrokenBeam(parts.ragtop)
end
local function resetParts()
  parts.ventL.broken = false
  parts.ventR.broken = false
  parts.windowFL.broken = false
  parts.windowFR.broken = false
  parts.windowRL.broken = false
  parts.windowRR.broken = false
  parts.windowR.broken = false
  parts.ragtop.broken = false
end

local function setCabinFilterCoef(newCabinFilterCoef)
  cabinFilterCoef = newCabinFilterCoef
end

local function updateCabinFilter()
  if not playerInfo.firstPlayerSeated then return end

  obj:queueGameEngineLua(string.format([[
    local newCoef = %f
    if core_sounds.cabinFilterStrength ~= newCoef then
      core_sounds.cabinFilterStrength = newCoef
      log("D", "", "[Bug] CabinFilterCoef: " .. core_sounds.cabinFilterStrength)
    end
  ]], clamp(cabinFilterCoef, 0, 1)))  
end

local function setCabinFilter(open)
  local minFactor = 1 - 1 / v.data.sounds.cabinFilterCoef * 0.15 -- Keep at least 15%
  local openCurve = 1 - (open*1.3)/(open+0.3) * minFactor 

  setCabinFilterCoef( math.abs(openCurve * v.data.sounds.cabinFilterCoef) )
end

local function getControllerState(name)
  local result = 0

  local controller = controller.getController(name)
  if not controller then return result end
  local state = controller.getGroupState()

  result = 1
  if state == 'attached' then result = 0 end
  if state == 'desyncedAttached' then result = 0 end
  if state == 'broken' then result = 1 end
  
  return result
end
local function setControllerState(name, state)
  local controller = controller.getController(name)
  if not controller then return end

  if state then
    controller.detachGroup()
  else
    controller.tryAttachGroupImpulse()
  end
end

local function updateInteriorlight(doors)
  local lightstate = electrics.values.interiorlightbutton > 0 or doors > 0
  electrics.values.interiorlightstate = lightstate and 1 or 0
end

local function updateOpenings()
  checkPartsBroken()

  local doorL = getControllerState('door_FL_coupler')
  local doorR = getControllerState('door_FR_coupler')
  local doors = clamp((doorL + doorR) / 2, 0, 3)

  electrics.values["opendoor_L"] = doorL
  electrics.values["opendoor_R"] = doorR
  electrics.values["opendoors"] = doors

  updateInteriorlight(doors)

  local brokenWindowL = (parts.windowFL.broken and 1) or (parts.windowRL.broken and 1) or (parts.windowR.broken and 1) or 0
  local brokenWindowR = (parts.windowFR.broken and 1) or (parts.windowRR.broken and 1) or (parts.windowR.broken and 1) or 0
  local ventFL = math.max(parts.ventL.broken and 1 or 0, electrics.values["doorventFL_state"] or 0)
  local ventFR = math.max(parts.ventR.broken and 1 or 0, electrics.values["doorventFR_state"] or 0)
  local windowFL = math.max(brokenWindowL, electrics.values["windowFL_state"] or 0)
  local windowFR = math.max(brokenWindowR, electrics.values["windowFR_state"] or 0) 
  --local windows = clamp((windowFL + windowFR) / 2, 0, 1)
  
  local ragtop = math.max(parts.ragtop.broken and 1 or 0, electrics.values.ragtop_state or 0) 

  local openL = clamp(doorL + (windowFL * 0.75) + (ventFL * 0.1) + (ragtop * 0.5), 0, 1)
  local openR = clamp(doorR + (windowFR * 0.75) + (ventFR * 0.1) + (ragtop * 0.5), 0, 1)
  local open = math.max(openL, openR)

  electrics.values["vehicleopenL"] = openL
  electrics.values["vehicleopenR"] = openR
  electrics.values["vehicleopen"] = open

  setCabinFilter(open)

  return open
end

local function debugCheckNodes()
  for i,node in pairs(v.data.nodes) do
    if node.pos.x > 0 then -- On left side ...

      local m = {}
      local w = true
      for i,n in pairs(v.data.nodes) do
        -- On right side ...
        if n.pos.x < 0 and math.abs(node.pos.x) == math.abs(n.pos.x) and node.pos.y == n.pos.y and node.pos.z == n.pos.z then
          table.insert(m, n)
        end
      end

      if #m > 1 then
        log("W","", "Multiple: " .. tostring(node.cid) .. " '" .. tostring(node.name) .. "' weight: " .. tostring(node.nodeWeight) .. " pos: " .. tostring(node.pos))
        for i,n in pairs(m) do
          log("W","", "           - " .. tostring(n.cid) .. " '" .. tostring(n.name) .. "' weight: " .. tostring(n.nodeWeight) .. " pos: " .. tostring(n.pos))
        end

      elseif #m > 0 then
        for i,n in pairs(m) do
          if node.nodeWeight ~= n.nodeWeight then
            log("W","", "Weight: " .. tostring(node.cid) .. " '" .. tostring(node.name) .. "' weight: " .. tostring(node.nodeWeight) .. " pos: " .. tostring(node.pos))
            log("W","", "         - " .. tostring(n.cid) .. " '" .. tostring(n.name) .. "' weight: " .. tostring(n.nodeWeight) .. " pos: " .. tostring(n.pos))
          end
        end
      else
        log("W","", "No match: " .. tostring(node.cid) .. " '" .. tostring(node.name) .. "' weight: " .. tostring(node.nodeWeight) .. " pos: " .. tostring(node.pos))
      end
    end
  end
end

-- -- Lists recantly changed values in "electrics.values":
-- local debugTable = {}
-- local dTShow = {}
-- local dTRounds = 10
-- function debugUpdate(dt)
-- 	print("------------------------------" .. dTRounds)
-- 	if dTRounds < 10 then
-- 		dTRounds = dTRounds + 1
-- 	end
-- 	for k,v in pairs(electrics.values) do
-- 		local o = true
-- 		if debugTable[k] ~= nil then
-- 			dT_v = debugTable[k]
-- 			if (dT_v == v) then o = false end
-- 		end
-- 		debugTable[k] = v
-- 		if dTRounds < 10 then
-- 			o = false
-- 		else
-- 			if o or dTShow[k] ~= nil then
-- 				dTShow[k] = true
-- 				print(tostring(k) .. ": " .. tostring(v))
-- 			end
-- 		end
-- 	end
-- end


local function doorControllerName(id)
  return 'door_'..id..'_coupler'
end
local function isDoorOpen(id)
  if id == nil then
    return isDoorOpen("FL") or isDoorOpen("FR")
  else
    return getControllerState(doorControllerName(id)) > 0
  end
end
local function setDoor(open, id)
  if id == nil then
    setDoor(open, "FL")
    setDoor(open, "FR")
  elseif isDoorOpen(id) ~= open then
    setControllerState(doorControllerName(id), open)
  end
end
local function toggleDoor(id, interior)
  controller.getControllerSafe(doorControllerName(id)).toggleGroup()
end
local function toggleDoorHandle(id)
  if not isDoorOpen(id) then
    animation.start("door"..id.."_handle")
  else
    toggleDoor(id)
  end
end

local function toolgeHoodRelease()
  controller.getControllerSafe('hoodLatchCoupler').toggleGroup()
end
local function toogleHoodReleaseHandle()
  animation.start("hood_release")
end

local function isTrunkOpen()
  return getControllerState('trunkCoupler') > 0
end
local function toggleTrunk()
  controller.getControllerSafe('trunkCoupler').toggleGroup()
end
local function toggleTrunkHandle()
  if isTrunkOpen() then
    toggleTrunk()
    animation.startWait("trunk", -1, function() return not isTrunkOpen() end)
  else
    animation.start("trunk", 1)
  end
end


local ragtop = {}
ragtop.VALUE = 0
ragtop.Locked = true

local function isRagtopOpen()
  return electrics.values.ragtop_state > 0
end
local function ragtopOpen(VALUE)
  ragtop.VALUE = VALUE or ragtop.VALUE
  if ragtop.Locked then
    animation.start("ragtop_handle", 1)
    return
  else
    controller.getControllerSafe('ragtop').open(ragtop.VALUE)
  end
end
local function ragtopClose(VALUE)
  if VALUE == 0 and not ragtop.Locked then
    animation.startWait("ragtop_handle", -1, function()
      return electrics.values.ragtop_state == 0
    end)
  end
  controller.getControllerSafe('ragtop').close(VALUE)
end
local function ragtopSetHandle(state)
  if state then
    electrics.values.anim__ragtop_handle = 1
    ragtop.Locked = false
  else
    electrics.values.anim__ragtop_handle = 0
    ragtop.Locked = true
  end
end

local function handleHazard()
  local state = electrics.values.hazard_enabled
  if hazardEnabled ~= state then
    playSound(state and "event:>Vehicle>Interior>Light>FIPA_On" or "event:>Vehicle>Interior>Light>FIPA_Off")
  end
  hazardEnabled = state
end


local moveSeatData = {
  seatId = "",
  value = 0,
  min = 0,
  max = 0
}
local function applyMoveSeat()
  local var = moveSeatData.seatId.."_position"
  local pos = electrics.values[var] or 0
  
  pos = math.min(moveSeatData.max or 1, math.max(moveSeatData.min or 0, pos + moveSeatData.value))
  electrics.values[var] = pos

  local uival = tostring(pos)
  if pos == moveSeatData.max then uival = uival .. " (Max)" end
  if pos == moveSeatData.min then uival = uival .. " (Min)" end
	guihooks.message({txt = "Seat Position " .. uival, context = {}}, 4, "bug.seat")

  print("[Bug:Seat] Position " .. tostring(pos))

end

local function moveSeat(seatId, val, min, max)
  moveSeatData.seatId = seatId
  moveSeatData.value = val
  moveSeatData.min = min
  moveSeatData.max = max
  animation.start(seatId.."_handle")
end

local function toggle(var)
  if var == "" then return nil end
  local state = electrics.values[var] or 0
  state = state > 0 and 0 or 1
  --print(tostring(var) .. " " .. tostring(state))
  electrics.values[var] = state
  return state
end

local function toggleGascap()
  local state = toggle('gascap')
  animation.start("gascap", state == 0 and -1 or 1)
end

local function toggleFuelcap()
  local state = toggle('fuelcap')
  animation.start("fuelcap", state == 0 and -1 or 1)
end

local function toggleInteriorLight() 
  local lightstate = electrics.values.interiorlightbutton > 0 and 0 or 1
  electrics.values.interiorlightbutton = lightstate
  guihooks.message({txt = lightMessageLookup[lightstate], context = {}}, 4, "vehicle.interiorlights")
end

local function toggleAshTray()
  toggle('ashtraystate')
end

local function toogleSwitchBoard(name)
  if electrics.values.ignitionLevel == 0 then return end
  local state = nil

  if name == "beacon" then
    local v = electrics.values.lightbar > 0 and 0 or 1
    electrics.set_lightbar_signal(v)
    if electrics.values.lightbar ~= v then
      state = electrics.values.lightbar > v
    end
  elseif name == "siren" then
    local v = electrics.values.lightbar < 2 and 2 or 1
    electrics.set_lightbar_signal(v)
    if electrics.values.lightbar ~= v then
      state = electrics.values.lightbar > v
    end
  elseif name == "underglown" then
    electrics.values.underglow = 1 - (electrics.values.underglow or 0)
    state = electrics.values.underglow > 0
  elseif name == "extlight" then
    electrics.values.extlight = 1 - (electrics.values.extlight or 0)
    state = electrics.values.extlight > 0
  elseif name == "nitrousoxide" then
    for _,v in pairs(controller.getControllersByType('nitrousOxideInjection')) do
      v.toggleActive()
    end
    state = electrics.values.nitrousOxideArm > 0
  end

  if state ~= nil then
    local snd = state and "event:>Vehicle>Interior>Light>PETE_On" or "event:>Vehicle>Interior>Light>PETE_Off"
    playSound(snd)
  end
end


local function toggle(var)
  if var == "" then return end
  local state = electrics.values[var] or 0
  state = state > 0 and 0 or 1
  --print(tostring(var) .. " " .. tostring(state))
  electrics.values[var] = state
end

local function device(name)
  return controller.getController(name)
end



local function updateGFX(dt)
  -- debugUpdate(dt)

  handleHazard()

  -- When the foglight cover is installed (bug_foglightcover_light ~= nil)
  -- and the foglight was off and is turned on, remove the cover.
  if electrics.values.bug_foglightcover_light ~= nil and foglightstate == 0 and (electrics.values.power__bug_foglight or 0) > 0 then
      electrics.values.foglightcoverstate = 1
  end
  foglightstate = electrics.values.power__bug_foglight or 0
  
  
  openingUpdateTimer = openingUpdateTimer + dt
	-- update rate: 10 fps (0.100 == 100ms)
	if openingUpdateTimer > 0.100 then
    openingUpdateTimer = 0
    updateOpenings()
  end

  cabinFilterTimer = cabinFilterTimer + dt
	-- update rate: 10 fps (0.1 == 100ms)
	if cabinFilterTimer > 0.1 then 
    cabinFilterTimer = 0
    updateCabinFilter()
  end  
end

local function onInit(jbeamData)
  electrics.values.interiorlightstate = 0
  electrics.values.interiorlightbutton = 0
  electrics.values.ashtraystate = 0
  electrics.values.wipersstate = 0
  electrics.values.foglightcoverstate = 0

  electrics.values.usdm_signal_L = 0
  electrics.values.usdm_signal_R = 0

  hazardEnabled = electrics.values.hazard_enabled

	nodeSFX = getNodeIDbyName(NodeNameSoundSFX)

  for _, b in pairs(v.data.beams) do
    if b.breakGroup == parts.ragtop.name then
      parts.ragtop.cid = b.cid
      break
    end
  end

  animation.setup('doorFL_handle', {
    {  0,   0},
    { 20, 0.8},
    { 40, 1.0},
    { 60, 0.4},
    { 80,   0}
  },{
    { 35, function() toggleDoor('FL') end }
  })
  animation.setup('doorFR_handle', {
    {  0,   0},
    { 20, 0.4},
    { 40, 1.0},
    { 60, 0.2},
    { 80,   0}
  },{
    { 35, function() toggleDoor('FR') end }
  })
  animation.setup('hood_release', {
    {  0,   0},
    { 30, 0.6},
    { 40, 1.0},
    { 50, 1.0},
    { 60, 0.5},
    { 80,   0}
  },{
    { 35, function() toolgeHoodRelease() end },
  })
  animation.setup('trunk', {
    {  0,   0},
    { 20, 0.2},
    { 40, 0.4},
    { 60, 0.6},
    { 80, 1.0}
  },{
    -- Only when opening the trunk
    { 70, function() toggleTrunk() end },
  })

  animation.setup('ragtop_handle', {
    {  0,   0},
    { 30, 1.0}
  },{
    -- Only when opening
    {  20, function() ragtop.Locked = false; ragtopOpen() end },
    -- Only when closing
    { -20, function() ragtop.Locked = true end },
  })

  
  animation.setup('fuelcap', {
    {  0,   0},
    {  5, 0.7},
    { 20, 1.0}
  },{
    {   5, function() sounds.playSoundOnceAtNode("SFX_bug_gascap_open", getNodeIDbyName("ft1l"), 1, 1, 0, 0) end },
    { -15, function() sounds.playSoundOnceAtNode("SFX_bug_gascap_close", getNodeIDbyName("ft1l"), 1, 1, 0, 0) end },
  },{invert = true})
  animation.setup('gascap', {
    {  0,   0},
    { 10, 0.2},
    { 80, 1.0}
  },{
    {  10, function() sounds.playSoundOnceAtNode("SFX_bug_gascap_open", getNodeIDbyName("h7br"), 1, 1, 0, 0) end },
    { -70, function() sounds.playSoundOnceAtNode("SFX_bug_gascap_close", getNodeIDbyName("h7br"), 1, 1, 0, 0) end },
  },{invert = true})


  animation.setup('seatFL_handle', {
    {  0,   0},
    { 20, 0.6},
    { 30, 1.0},
    { 60, 1.0},
    { 70, 0.5},
    { 80,   0}
  },{
    { 40, function() applyMoveSeat() end }
  })
  animation.setup('seatFR_handle', {
    {  0,   0},
    { 20, 0.6},
    { 30, 1.0},
    { 60, 1.0},
    { 70, 0.5},
    { 80,   0}
  },{
    { 40, function() applyMoveSeat() end }
  })

  --debugCheckNodes()
  
  --dTShow = {}
  --dTRounds = 0
end

local function onReset()
  hazardEnabled = electrics.values.hazard_enabled
  resetParts()

  --dTShow = {}
  --dTRounds = 0
end

local function onPlayersChanged()
end


M.onInit    = onInit
M.onReset   = onReset
M.updateGFX = updateGFX
M.onPlayersChanged = onPlayersChanged

-- public interface
M.device                  = device

M.hasPower                = hasPower

M.toggle                  = toggle
M.toggleGascap            = toggleGascap
M.toggleFuelcap           = toggleFuelcap
M.toggleInteriorLight     = toggleInteriorLight
M.toggleAshTray           = toggleAshTray
M.toogleSwitchBoard       = toogleSwitchBoard

M.moveSeat                = moveSeat

M.doorControllerName      = doorControllerName
M.isDoorOpen              = isDoorOpen
M.setDoor                 = setDoor
M.toggleDoor              = toggleDoor
M.toggleDoorHandle        = toggleDoorHandle

M.toolgeHoodRelease       = toolgeHoodRelease
M.toogleHoodReleaseHandle = toogleHoodReleaseHandle

M.isTrunkOpen             = isTrunkOpen
M.toggleTrunk             = toggleTrunk
M.toggleTrunkHandle       = toggleTrunkHandle

M.isRagtopOpen            = isRagtopOpen
M.ragtopOpen              = ragtopOpen
M.ragtopClose             = ragtopClose
M.ragtopSetHandle         = ragtopSetHandle

return M
