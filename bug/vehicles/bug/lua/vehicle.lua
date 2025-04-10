-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- v1.1
-- by MrX13415

local M = {}
M.version = "24"
M.versionDate = "2025-04-09"

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

local function isDoorLOpen() 
  return getControllerState('door_FL_coupler') > 0
end
local function isDoorROpen() 
  return getControllerState('door_FR_coupler') > 0
end
local function isDoorsOpen() 
  return isDoorLOpen() or isDoorROpen()
end
local function setDoorL(open) 
  setControllerState('door_FL_coupler', open)
end
local function setDoorR(open) 
  setControllerState('door_FL_coupler', open)
end
local function closeDoors()
  if isDoorLOpen() then setDoorL(false) end
  if isDoorROpen() then setDoorR(false) end
end

local function updateInteriorlight(doors)
  local lightstate = electrics.values.interiorlightstate > 0 or doors > 0
  electrics.values.interiorlight = lightstate and 1 or 0
end

local function animateElectrics(name, speed)
  -- Smooth ignition animation
  local lvl = electrics.values[name] or 0
  local anim = electrics.values[name .. "_anim"] or 0

  local diff = math.abs(lvl - math.floor(anim))
  local speedCoef = clamp(diff / (1/speed), speed, speed * 5)

  local direction = lvl > anim and 1 or -1
  local new = lvl
  if math.abs(lvl - anim) > 0.01 then
    new = anim + speedCoef * direction
    if direction > 0 then new = clamp(new, anim, lvl) end
    if direction < 0 then new = clamp(new, lvl, anim) end
  end

  --print(tostring(lvl) .. " a " .. tostring(anim) .. " d " .. tostring(diff) .. " n " .. tostring(new) .. " s " .. tostring(speedCoef))
  electrics.values[name .. "_anim"] = new
end

local function updateAnimations()
  animateElectrics("ignitionLevel", 0.04)
  animateElectrics("ashtray", 0.03)
  animateElectrics("parkingbrake", 0.05)

  animateElectrics("gascap", 0.03)
  animateElectrics("fuelcap", 0.25)
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
  
  local ragtop = math.max(parts.ragtop.broken and 1 or 0, electrics.values["ragtop_state"] or 0) 

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

local function handleHazard()
  local state = electrics.values.hazard_enabled
  if hazardEnabled ~= state then
    playSound(state and "event:>Vehicle>Interior>Light>FIPA_On" or "event:>Vehicle>Interior>Light>FIPA_Off")
  end
  hazardEnabled = state
end

local function updateGFX(dt)
  -- debugUpdate(dt)

  handleHazard()
  updateAnimations()
  
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
  electrics.values.interiorlight = 0
  electrics.values.interiorlightstate = 0
  electrics.values.ashtray = 0
  electrics.values.ashtraystate = 0
  electrics.values.wipersstate = 0

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

  --debugCheckNodes()
  
  --dTShow = {}
  --dTRounds = 0
end

local function onReset()
  print("[Bug] Version " ..M.version.. " - " ..M.versionDate)
  ----------------------------------------

  hazardEnabled = electrics.values.hazard_enabled
  resetParts()

  --dTShow = {}
  --dTRounds = 0
end

local function onPlayersChanged()
end

local function toggleInteriorLight() 
  local lightstate = electrics.values.interiorlightstate > 0 and 0 or 1
  electrics.values.interiorlightstate = lightstate
  guihooks.message({txt = lightMessageLookup[lightstate], context = {}}, 4, "vehicle.interiorlights")
end

local function toggleAshTray()
  local state = electrics.values["ashtraystate"] or 0
  state = state > 0 and 0 or 1
  electrics.values["ashtraystate"] = state 
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
    state = electrics.values.underglow
  elseif name == "extlight" then
    electrics.values.extlight = 1 - (electrics.values.extlight or 0)
    state = electrics.values.extlight
  end

  if state ~= nil then
    playSound(state and "event:>Vehicle>Interior>Light>PETE_On" or "event:>Vehicle>Interior>Light>PETE_Off")
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



M.onInit    = onInit
M.onReset   = onReset
M.updateGFX = updateGFX
M.onPlayersChanged = onPlayersChanged

-- public interface
M.device              = device

M.hasPower            = hasPower

M.toggle              = toggle
M.toggleInteriorLight = toggleInteriorLight
M.toggleAshTray       = toggleAshTray
M.toogleSwitchBoard   = toogleSwitchBoard

M.isDoorLOpen         = isDoorLOpen
M.isDoorROpen         = isDoorROpen
M.isDoorsOpen         = isDoorsOpen
M.setDoorL            = setDoorL
M.setDoorR            = setDoorR
M.closeDoors          = closeDoors

return M
