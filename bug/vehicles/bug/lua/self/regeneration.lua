-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

-- these are defined in C, do not change the values
local NORMALTYPE = 0
local NODE_FIXED = 1
local NONCOLLIDABLE = 2
local BEAM_ANISOTROPIC = 1
local BEAM_BOUNDED = 2
local BEAM_PRESSURED = 3
local BEAM_LBEAM = 4
local BEAM_HYDRO = 6
local BEAM_SUPPORT = 7

local regenEnabled = false
local doCheck = false
local checkRate = 10    -- seconds
local regenRate = 0.025
local repairErrorMargin = 0.0015
local regenTime = 0

local regenBeamStates = {}
local regenBeamCache = {}

local count = 0
local total = 0
local progress = 0
local cancelled = false
local ready = false
local updateTimer = 2   -- Make sure the first call is immediately
local blinkTimer = 0
local blinkState = false
local sitTightTimer = 0
local maxSitTight = 60 -- 1 min.

local state = {}

-- names must be lower case!
local partBlacklist = {
  "driveshaft",
  "coilover",
  "suspension",
  "steering",
  "swaybar",
  "brake",
  "spring",
  "wheel",
  "bug_rearrack_luggage",
  "bug_roof_rack_luggage"
}

local function isPartEnabled()
	for _,part in pairs(v.data.activeParts) do
		if part.partName == "bug_herbie_regeneration" then return true end
	end
  return false
end

local function stop()
  if not ready then return end

  regenEnabled = false
  doCheck = false
  cancelled = true
  M.sendState()
end

local function getBeamPartOrigin(beam, getEndNode)
  local partOrigin = nil
  if not getEndNode then
    partOrigin = v.data.nodes[beam.id1].partOrigin
  else
    partOrigin = v.data.nodes[beam.id2].partOrigin
  end
  return partOrigin or ""
end

local function validRegenPart(partName)
  for _,key in pairs(partBlacklist) do
    if string.find(partName:lower(), key) then return false end
  end
  return true
end

local function start()
  if not ready then return end
  if regenEnabled then return end
  cancelled = false

  --reset beam states
  regenBeamStates = {}
  regenBeamCache = {}
  regenTime = 0
  sitTightTimer = 0

  --build the cache
  for k,beam in pairs(v.data.beams) do
    
    if beam.beamType ~= NORMALTYPE then goto next end
    if obj:beamIsBroken(beam.cid) then goto next end

    local part1 = getBeamPartOrigin(beam,false)
    local part2 = getBeamPartOrigin(beam,true)

    if part1 ~= part2 then goto next end
    if not validRegenPart(part1) or not validRegenPart(part2) then goto next end

    --get beam length, check if this is a 'weird' beam?
    local currentLengthRatio = obj:getBeamLengthRefRatio(beam.cid)
    if currentLengthRatio < 0.001 then goto next end

    --check if this is a 0 length beam
    local currentLength = obj:getBeamLength(beam.cid)
    if currentLength < 0.001 then goto next end

    --add to cache
    table.insert(regenBeamCache, beam)

    ::next::
  end

  --finally, flag for regen
  regenEnabled = true
end

local function doRegen(dt, check)
  if not ready then return end

  local timeScaledRate = (regenRate * bullettime.get()) * dt
  count = 0
  total = 0

  for k,beam in pairs(regenBeamCache) do
    total = total + 1

    local currentLengthRatio = obj:getBeamLengthRefRatio(beam.cid)
    local currentLength = obj:getBeamLength(beam.cid)
    --mark as repaired when to small ratio or length
    if currentLengthRatio < 0.001 or currentLength < 0.001 then
      regenBeamStates[beam.cid] = true
      count = count + 1
      goto next
    end

    --change length if we need to
    local targetLength = (currentLength / currentLengthRatio)
    local remainingLengthChange = math.abs(targetLength - currentLength)
    local lengthScaledRate = math.min(timeScaledRate / targetLength, math.abs(1 - currentLengthRatio))

    local repairedVal = math.max(repairErrorMargin, repairErrorMargin * (regenTime / 30))

    --are we done repairing this beam?
    if currentLengthRatio == 0 or remainingLengthChange < repairedVal then
      regenBeamStates[beam.cid] = true
      count = count + 1
      goto next
    end

    --repair this beam!
    if currentLength < targetLength then
      obj:setBeamLengthRefRatio(beam.cid,currentLengthRatio + lengthScaledRate)
    else
      obj:setBeamLengthRefRatio(beam.cid,currentLengthRatio - lengthScaledRate)
    end

    --Debug:
    --if progress > 0.99 then
    --  local nodes = v.data.nodes[beam.id1].name .. "," .. v.data.nodes[beam.id2].name
    --  local beamType = beam.beamType or 0
    --  local name = tostring(getBeamPartOrigin(beam,false)) .. "->" .. tostring(getBeamPartOrigin(beam,true))
    --  print("[Bug:Regeneration] " .. tostring(name) .. ": " .. nodes .. " " .. tostring(beamType) .. " | " .. tostring(remainingLengthChange) .. " | " .. tostring(currentLength) .. " / " .. tostring(targetLength) .. " 1:" .. tostring(currentLengthRatio))
    --end

    ::next::
  end

  progress = count / total

  -- Just stop when are a stuck at nearly completion.
  if count == total or sitTightTimer >= maxSitTight then
    count = total
    regenEnabled = false
    if not doCheck then M.sendState() end
    doCheck = false
    material.reset()
    return
  end

  doCheck = false
  M.sendState()
end

local function onInit(jbeamData)
  electrics.values.regeneration = false
end

local function onReset()
  regenEnabled = false
  cancelled = false
  regenTime = 0

  regenBeamStates = {}
  regenBeamCache = {}
end

local function updateGFX(dt)
  if not ready and isPartEnabled() then
    M.sendState("Initialize ...")
    M.sendState("   check rate: " .. tostring(checkRate) .. "s")
    M.sendState("Ready")
    ready = true
  end
  if not ready then return end

  updateTimer = updateTimer + dt

  if not regenEnabled then
    blinkState = false
    electrics.values.regeneration = false
    if updateTimer >= checkRate then
      M.sendState("Check vehicle condition ...", "D")
      doCheck = true
      start()
      updateTimer = 0
    end
    return
  end

  -- blick LED update rate: 1 fps (1.0 == 1000ms)
  blinkTimer = blinkTimer + dt
  if blinkState and blinkTimer >= 0.08 then
    blinkState = not blinkState 
    blinkTimer = 0
  elseif not blinkState and blinkTimer >= 0.4 then
    blinkState = not blinkState 
    blinkTimer = 0
  end
  electrics.values.regeneration = blinkState

  doRegen(dt, false)

  regenTime = regenTime + dt
  if (progress > 0.99) then
    sitTightTimer = sitTightTimer + dt
  end
end


local function sendState(forceStatusText, severity)
  state.progress = progress
  state.enabled = regenEnabled
 
  local fastOutput = true

  if forceStatusText ~= nil then
    state.status = forceStatusText
    state.severity = severity or "I"
  elseif regenEnabled then
    fastOutput = false
    local niceProgress = math.floor(progress * 10000) / 100
    state.status = "Regeneration in progress... " .. tostring(niceProgress) .. "%"
    state.severity = "I"
    if progress > 0.99 then
      local sitTightWaitSec = math.floor(maxSitTight - sitTightTimer)
      state.status = state.status .. " (Sit tight for max " .. tostring(sitTightWaitSec) .. "s)"
    end
  elseif cancelled then
    state.status = "Regeneration cancelled."
    state.severity = "I"
  else
    state.status = "Regeneration complete!"
    state.severity = "I"
  end

  	-- update rate: 1 fps (1.0 == 1000ms)
	if fastOutput or updateTimer >= 1 then
    log(state.severity or "I", "", "[Bug:Regeneration] " .. state.status)
    updateTimer = 0
  end

  if not playerInfo.firstPlayerSeated then return end
  --guihooks.trigger('BeamRegeneratorState', state)
end

-- public interface
M.regenerate = regenerate
M.cancelRegenerate = cancelRegenerate

M.onInit    = onInit
M.onReset   = onReset
M.updateGFX = updateGFX
M.sendState = sendState

return M
