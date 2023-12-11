-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- v1.1
-- by MrX13415

local M = {}
local updateTimer = 2   -- Make sure the first call is immediately
local openingUpdateTimer = 2   -- Make sure the first call is immediately

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

local cabinFilterCoef = 1

local wipersSpeed1 = 0.02   -- 833ms (60fps)
local wipersSpeed2 = 0.021  -- 793ms (60fps)
local wipersSpeed3 = 0.023  -- 757ms (60fps)
local wipersBreak1 = 120    -- 2 sec. (60fps)
local wipersBreak2 = 30     -- 0.5 sec. (60fps)
local wipersBreak3 = 0      -- 0 sec.
local wipersValue = 0
local wipersBreak = 0
local wipersDirection = 1
local wipersStateDirection = 1
local wipersSfxNode = "wi1"
local wipersSfxEvent = "vehicles/bug/components/sounds/common/windshild-wipers.wav"
local wipersSfxVolume = 0.31
local wipersSfx = nil
local wipersMessageLookup = {
  [0] = "Wipers: Off",
  [1] = "Wipers: Level 1",
  [2] = "Wipers: Level 2",
  [3] = "Wipers: Level 3"
}

local lightMessageLookup = {
  [0] = "Interior Light: Off",
  [1] = "Interior Light: On",
}


local function hasPower() return electrics.values.ignitionLevel > 0 end

local function createSFX(event, node, eventID)
  local soundNode = getNodeIDbyName(node)
  local sound = obj:createSFXSource2(event, "AudioClosestLoop3D", eventID, soundNode, 0)
  return sound
end

local function playSound(soundname)
  sounds.playSoundOnceAtNode(soundname, nodeSFX, 1, 1, 0, 0)
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
  if not playerInfo.firstPlayerSeated then return end

  if cabinFilterCoef ~= newCabinFilterCoef then
    cabinFilterCoef = newCabinFilterCoef

    obj:queueGameEngineLua(string.format([[
      core_sounds.cabinFilterStrength = %f
      log("D", "", "[Bug] CabinFilterCoef: " .. core_sounds.cabinFilterStrength)
    ]], clamp(cabinFilterCoef, 0, 1)))
  end
end

local function updateCabinFilter(open)
  local minFactor = 1 - 1 / v.data.sounds.cabinFilterCoef * 0.15 -- Keep at least 15%
  local openCurve = 1 - (open*1.3)/(open+0.3) * minFactor 

  setCabinFilterCoef( math.abs(openCurve * v.data.sounds.cabinFilterCoef) )
end

local function getControllerState(name)
  local result = 0

  local controller = controller.getControllerSafe(name)
  if not controller then return result end
  local state = controller.getGroupState()

  result = 1
  if state == 'attached' then result = 0 end
  if state == 'desyncedAttached' then result = 0 end
  if state == 'broken' then result = 1 end
  
  return result
end
local function setControllerState(name, state)
  if state then
    controller.getControllerSafe(name).detachGroup()
  else
    controller.getControllerSafe(name).tryAttachGroupImpulse()
  end
end

local function isDoorLOpen() 
  return getControllerState('doorLCoupler') > 0
end
local function isDoorROpen() 
  return getControllerState('doorRCoupler') > 0
end
local function isDoorsOpen() 
  return isDoorLOpen() or isDoorROpen()
end
local function setDoorL(open) 
  setControllerState('doorLCoupler', open)
end
local function setDoorR(open) 
  setControllerState('doorLCoupler', open)
end
local function closeDoors()
  if isDoorLOpen() then setDoorL(false) end
  if isDoorROpen() then setDoorR(false) end
end

local function updateElectrics()

  local running = electrics.values.engineRunning > 0

  local oil = electrics.values["oilpressure"] or 0    -- PSI
  local oildefault = 42

  if running and (oil < oildefault) then
    oil = oil + 0.6
  end
  if not running and (oil > 0) then
    oil = oil - 1
  end
  oil = math.max(math.min(oil, oildefault), 0)

  electrics.values["oilpressure"] = oil

  -----------------------------------------------------

  local ampere = 0   -- A

  -- Stuff can be on ...
  if electrics.values.ignitionLevel > 0 then
    ampere = ampere - 2 -- A

    -- headlights
    if electrics.values.lights_state > 0 then
      ampere = ampere - 10
    end
    if electrics.values.lights_state > 1 then
      ampere = ampere - 3
    end

    if electrics.values.wipersstate > 0 then
      ampere = ampere - 4
    end
    if electrics.values.wipersstate > 1 then
      ampere = ampere - 2
    end

    -- radio 
    if electrics.values.radio_state > 0 then
      ampere = ampere - 7
    end
  end
  -- Ignition
  if electrics.values.ignitionLevel == 3 then
    ampere = ampere - 25 -- A
  end
  -- Engine runngin
  if running and electrics.values.ignitionLevel > 1 then
    ampere = ampere + 30 -- A
    ampere = math.min(ampere, 17)
  end
  
  electrics.values["ampere"] = ampere

  -----------------------------------------------------

  local amp_sm = electrics.values["ampere_smooth"] or 0

  if amp_sm < ampere then
    amp_sm = math.min(amp_sm + 0.6, ampere)
  elseif amp_sm > ampere then
    amp_sm = math.max(amp_sm - 0.6, ampere)
  end

  electrics.values["ampere_smooth"] = amp_sm
end

local function updateInteriorlight(doors)
  local lightstate = electrics.values["interiorlightstate"] or 0
  lightstate = lightstate > 0 or doors > 0

  electrics.values["interiorlight"] = lightstate
end

local function updateAshTray()
  local delta = 0.05
  if electrics.values["ashtraystate"] < 0.5 then 
    delta = delta * -1 
  end
  electrics.values["ashtray"] = clamp(electrics.values["ashtray"] + delta, 0, 1)
end

local function updateWipers()
  local state = electrics.values["wipersstate"] or 0

  if not hasPower() then
    if wipersSfx then obj:cutSFX(wipersSfx) end
    return 
  end

  if wipersBreak > 0 then
    if wipersSfx then obj:cutSFX(wipersSfx) end
    wipersBreak = wipersBreak - 1
    return
  end

  if state > 0 or wipersValue > 0 then
    local s = wipersSpeed3
    if state < 2 then s = wipersSpeed1
    elseif state < 3 then s = wipersSpeed2 
    end
    
    wipersSfx = wipersSfx or createSFX(wipersSfxEvent, wipersSfxNode, "wipers")
    if wipersSfx then 
      obj:playSFX(wipersSfx) 
      local sfxLength = 2100                     -- ms
      local wiperDuration = 1000 / (60 * s) * 2  -- ms [1sec / (60fps * wiperSpeed) * 2]
      local sfxMod = 1 / wiperDuration * sfxLength
      obj:setVolumePitchCT(wipersSfx, wipersSfxVolume, sfxMod, 1, 1)
    end

    wipersValue = wipersValue + (s * wipersDirection)

    if wipersValue >= 1 then
       wipersDirection = -1 
       wipersValue = 1
    end

    if wipersValue <= 0 then
      wipersDirection = 1
      wipersValue = 0
      if state < 2 then wipersBreak = wipersBreak1
      elseif state < 3 then wipersBreak = wipersBreak2
      else wipersBreak = wipersBreak3
      end
      if wipersSfx then obj:cutSFX(wipersSfx) end
    end
  end

  electrics.values["wipers"] = wipersValue
end

local function updateParts()
  updateAshTray()
  updateWipers()
  updateElectrics()
end

local function updateOpenings()
  checkPartsBroken()

  local doorL = getControllerState('doorLCoupler')
  local doorR = getControllerState('doorRCoupler')
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

  updateCabinFilter(open)

  return open
end

function debugCheckNodes()
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

local function updateGFX(dt)
  -- debugUpdate(dt)

  updateTimer = updateTimer + dt
	-- update rate: 60 fps (0.016 == 16ms)
	if updateTimer > 0.016 then 
    updateTimer = 0
    updateParts()
  end  
  
  openingUpdateTimer = openingUpdateTimer + dt
	-- update rate: 10 fps (0.100 == 100ms)  
	if openingUpdateTimer > 0.100 then 
    openingUpdateTimer = 0
    updateOpenings()
  end
end

local function onInit(jbeamData)
  electrics.values["interiorlight"] = 0
  electrics.values["interiorlightstate"] = 0
  electrics.values["ashtray"] = 0
  electrics.values["ashtraystate"] = 0
  electrics.values["wipersstate"] = 0

  electrics.values["ampere"] = 0
  electrics.values["ampere_smooth"] = 0
  electrics.values["oilpressure"] = 0

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
  print("[Bug] Version 21 - 2023-12-11")
  ----------------------------------------

  resetParts()

  --dTShow = {}
  --dTRounds = 0
end

local function onPlayersChanged()
end

local function toggleInteriorLight()  
  local lightstate = electrics.values["interiorlightstate"] or 0
  lightstate = lightstate > 0 and 0 or 1
  electrics.values["interiorlightstate"] = lightstate
  guihooks.message({txt = lightMessageLookup[lightstate], context = {}}, 4, "vehicle.interiorlights")
end

local function toggleAshTray()
  local state = electrics.values["ashtraystate"] or 0
  state = state > 0 and 0 or 1
  electrics.values["ashtraystate"] = state 
end

local function toggleWipers()
  local state = electrics.values["wipersstate"] or 0
  if state <= 0 then wipersStateDirection = 1 end
  if state >= 3 then 
    wipersStateDirection = -1
  end
  playSound(state > 0 and "event:>Vehicle>Interior>Light>FIPA_On" or "event:>Vehicle>Interior>Light>FIPA_Off")
  state = state + wipersStateDirection
  electrics.values["wipersstate"] = state
  guihooks.message({txt = wipersMessageLookup[state], context = {}}, 4, "vehicle.wipers")
end

local function wipersUp()
  local state = electrics.values["wipersstate"] or 0
  if state < 3 then
    state = state + 1
    playSound("event:>Vehicle>Interior>Light>FIPA_On")
  end
  electrics.values["wipersstate"] = state
  guihooks.message({txt = wipersMessageLookup[state], context = {}}, 4, "vehicle.wipers")
end

local function wipersDown()
  local state = electrics.values["wipersstate"] or 0
  if state > 0 then 
    state = state - 1
    playSound("event:>Vehicle>Interior>Light>FIPA_Off")
  end
  electrics.values["wipersstate"] = state
  guihooks.message({txt = wipersMessageLookup[state], context = {}}, 4, "vehicle.wipers")
end

local function toggle(var)
  if var == "" then return end
  local state = electrics.values[var] or 0
  state = state > 0 and 0 or 1
  --print(tostring(var) .. " " .. tostring(state))
  electrics.values[var] = state
end



M.onInit    = onInit
M.onReset   = onReset
M.updateGFX = updateGFX
M.onPlayersChanged = onPlayersChanged

-- public interface
M.hasPower            = hasPower

M.toggle              = toggle
M.toggleInteriorLight = toggleInteriorLight
M.toggleAshTray       = toggleAshTray
M.toggleWipers        = toggleWipers
M.wipersUp            = wipersUp
M.wipersDown          = wipersDown

M.isDoorLOpen         = isDoorLOpen
M.isDoorROpen         = isDoorROpen
M.isDoorsOpen         = isDoorsOpen
M.setDoorL            = setDoorL
M.setDoorR            = setDoorR
M.closeDoors          = closeDoors

return M
