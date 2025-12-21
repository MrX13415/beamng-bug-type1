-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- by MrX13415

local M = {}

local updateTimer = 2   -- Make sure the first call is immediately
local value = 0
local speed = 0.01
local direction = 0
local directionLast = 0
local targetValue = -1

local sfxNode = ""
local sfxEvent = "vehicles/bug/components/sounds/common/ragtop-move.ogg"
local sfxVolume = 0.31
local sfx = nil

local materialTimer = 0
local switches = {}
local beams = {}
local state = 0

local bar1BeamName = "ragtopState1"
local bar2BeamName = "ragtopState2"
local matVisible = "bug_ragtop_fabric"
local matHidden = "invis"

local shortPressTime = 0.15 -- seconds
local buttonTimer = 0
local buttonState = 0

-- common
local function createSFX(event, node)
  local soundNode = getNodeIDbyName(node)
  local sound = obj:createSFXSource2(event, "AudioClosestLoop3D", "ragtopmove", soundNode, 0)
  if sound then obj:setVolume(sound, sfxVolume) end
  return sound
end

local function getBeams(name)
  local list = beams[name]
  if list ~= nil then return list end
  
  list = {}
  for i, beam in pairs(v.data.beams) do
    if beam.name == name then
    table.insert(list, beam)
    end
  end
  
  beams[name] = list
  return list
end

local function getBeamCurLengthRefRatio(name)
  local length = 0
  for _, beam in pairs(getBeams(name)) do
    local l = obj:getBeamCurLengthRefRatio(beam.cid)
    length = math.max(l, length)
  end
  return length
end

local function getSwitchableMaterial(matName, flexbodyMesh)
  local switchName = tostring(matName) .. "|" .. tostring(flexbodyMesh)

  if switches[switchName] == nil then
    local sw = obj:getSwitchableMaterial(matName, matName, flexbodyMesh)
    switches[switchName] = sw
    --debug: log('I', "material.init", "Created materialSwitch '"..switchName.."' [" .. tostring(sw) .. "] for material " .. tostring(matName) .. " on mesh " .. tostring(flexbodyMesh))
  end

  return switches[switchName]
end

local function switchMaterial(sw, newMat)
  if sw ~= nil then 
    if newMat == nil then
      obj:resetMaterials(sw)
    else
      -- WARNING: The materials used here must be assigned to any mesh or else the game will crash!
      obj:switchMaterial(sw, newMat)
    end
  end
end

local function updateMaterial(dt)
	-- update rate: 10 fps (0.100 == 100ms)
	if materialTimer < 0.100 then return end

  local bar1 = getBeamCurLengthRefRatio(bar1BeamName)
  local bar2 = getBeamCurLengthRefRatio(bar2BeamName)
  --print("Beams: " .. tostring(bar1) .. " length " .. tostring(bar2))

  local lastState = state
  state = 0                             -- Fully closed
  if bar1 <= 0.77 then state = 1 end   -- 1st bar moved
  if bar2 <= 0.87 then state = 2 end   -- 2nd bar also moved

  if state == lastState then return end

  -- The material used here is the original assigned material
  local swF = getSwitchableMaterial(matVisible, "bug_body_roof_ragtop_fabric")
  local swA = getSwitchableMaterial(matHidden,  "bug_body_roof_ragtop_fabric.a")
  local swB = getSwitchableMaterial(matHidden,  "bug_body_roof_ragtop_fabric.b")
  
  local sw1 = getSwitchableMaterial(matHidden,  "bug_body_roof_ragtop_fabric.1")
  local sw2 = getSwitchableMaterial(matHidden,  "bug_body_roof_ragtop_fabric.2")

  if state == 0 then
    -- Reset all to default material
    switchMaterial(swF)
    switchMaterial(swA)
    switchMaterial(swB)

    switchMaterial(sw1)
    switchMaterial(sw2)

  elseif state == 1 then
    switchMaterial(swF, matHidden)
    switchMaterial(swA, matVisible)
    switchMaterial(swB)

    switchMaterial(sw1, matVisible)
    switchMaterial(sw2)

  elseif state == 2 then
    switchMaterial(swF, matHidden)
    switchMaterial(swA, matHidden)
    switchMaterial(swB, matVisible)

    switchMaterial(sw1, matVisible)
    switchMaterial(sw2, matVisible)

  end
end

local function updateRagtop(dt)
  directionLast = direction
  direction = electrics.values.ragtop_input or 0

  if direction ~= directionLast then
    sfx = sfx or createSFX(sfxEvent, sfxNode)
    if sfx then 
      obj:cutSFX(sfx)
      if direction ~= 0 then
        obj:playSFX(sfx) 
      end
    end
  end

  value = value + (speed * direction)
  -- ragtop is fully closed
  if value <= 0 then
     value = 0
     if sfx then obj:cutSFX(sfx) end
  end
  -- ragtop is fully open
  if value >= 1 then
    value = 1
    if sfx then obj:cutSFX(sfx) end
  end

  electrics.values.ragtop_state = value
  --print("ragtop: " .. value)

  updateMaterial()

  -- Auto open
  if targetValue >= 0 and (
    (direction > 0 and value >= targetValue) or
    (direction < 0 and value <= targetValue)
  ) then
    electrics.values.ragtop_input = 0
    targetValue = -1
  end
end

local function set(state)
  if value == state then return end
  targetValue = state
  electrics.values.ragtop_input = (state > value) and 1 or -1
end

local function onButton(value, open)
  buttonState = value

  -- holding
  if buttonState ~= 0 then return end

  local shortPress = buttonTimer < shortPressTime
  buttonTimer = 0
  if not shortPress then return end

  log("D", "", "[Bug:Ragtop] Short press")
  set(open and 0.7 or 0) -- 70% open
end

local function open(value)
  electrics.values.ragtop_input = value
  onButton(value, true)
end

local function close(value)
  electrics.values.ragtop_input = value * -1
  onButton(value, false)
end

local function updateGFX(dt)
  updateTimer = updateTimer + dt
  materialTimer = materialTimer + dt

  if buttonState == 1 then
    buttonTimer = buttonTimer + dt
  end

	-- update rate: 40 fps (0.025 == 25ms)
	if updateTimer < 0.025 then return end

  updateRagtop(updateTimer)

  updateTimer = 0
end

local function onReset()
  value = electrics.values.ragtop_state
  log("D", "", "[Bug:Ragtop] " .. tostring(value*100) .. "% open")
end

local function onInit(jbeamData)
  electrics.values.ragtop_state = 0
  electrics.values.ragtop_input = 0
  sfxNode = jbeamData.node or ""

  value = (jbeamData.state or 0)
  electrics.values.ragtop_state = value
  if value > 0 then
    vehicle.ragtopSetHandle(true)
  end

  log("D", "", "[Bug:Ragtop] Initialized " .. tostring(value*100) .. "% open")
end

M.init      = onInit
M.reset     = onReset
M.updateGFX = updateGFX

-- Public Interface
-- Console: controller.getController('ragtop').open()
M.set = set
M.open = open
M.close = close

return M
