-- Vehicle motion and suspension telemetry helper for the Bug.
--
-- Archived diagnostic module; BeamNG does not auto-load it from this path.
-- To use it, install it temporarily in the vehicle Lua root and remove it after.
-- Its repeatable test drives throttle and clutch and can move the vehicle.
-- Sampling is performed from the physics-step hook, not the graphics update.

local M = {}

local sampleRateHz = 250
local sampleInterval = 1 / sampleRateHz
local sampleCapacity = 8192 -- About 32.8 simulation seconds at 250 Hz.
local eventCapacity = 1024
local inputDeadzone = 0.02
local steeringDeadzone = 8 -- Steering electrics are reported in degrees.

local trackedNodeNames = {
  "fh1l", "fs1l", "fh1r", "fs1r", -- front shock endpoints
  "fh2l", "fh2r",                   -- upper hub / suspension points
  "fx1l", "fx1r", "fx2l", "fx2r", -- front subframe corner points
  "fx1", "fx2", "fx0",              -- subframe center and rigidifier points
  "f1ml", "f1mr", "f1tml", "f1tmr", -- lower/upper front frame-rail anchors
  "f2l", "f2r", "f2tm",            -- chassis references
  -- Generic seat lower pan (1/2), upper backrest (5/9), and rail base (7/8).
  "isFL1o", "isFL1i", "isFL2o", "isFL2i", "isFL5o", "isFL5i", "isFL9",
  "isFL7o", "isFL7i", "isFL8o", "isFL8i",
  "isFR1o", "isFR1i", "isFR2o", "isFR2i", "isFR5o", "isFR5i", "isFR9",
  "isFR7o", "isFR7i", "isFR8o", "isFR8i",
  -- Occupant lower torso (1/2), upper torso (3/4), and head (5/6).
  "ocpFL1", "ocpFL2l", "ocpFL2r", "ocpFL3", "ocpFL4l", "ocpFL4r", "ocpFL5", "ocpFL6",
  "ocpFR1", "ocpFR2l", "ocpFR2r", "ocpFR3", "ocpFR4l", "ocpFR4r", "ocpFR5", "ocpFR6",
  -- Generic occupant camera bases (bref*) and torso-tracking refs (ref*).
  "ocpFLbref", "ocpFLbrefL", "ocpFLbrefB", "ocpFLref", "ocpFLrefL", "ocpFLrefB",
  "ocpFRbref", "ocpFRbrefL", "ocpFRbrefB", "ocpFRref", "ocpFRrefL", "ocpFRrefB",
  "e1l", "e1r", "e5l", "e5r",       -- rear engine-block / upper mount nodes
  "f5l", "f5r", "f6ml", "f6mr",    -- engine-mount receiving frame nodes
  "f6tml", "f6tmr", "f7ml", "f7mr", "f7tml", "f7tmr",
  "tra1", "tra2l", "tra2r",          -- transaxle and transmission mount nodes
  "rh1l", "rh1r", "rh2l", "rh2r",  -- rear trailing-arm / hub nodes
  "rh4l", "rh4r", "rh5l", "rh5r",  -- rear shock and hub reference nodes
  "bs1l", "bs1r", "bx1l", "bx1r",  -- rear shock towers / subframe nodes
  "bx2l", "bx2r",                      -- rear torsion-bar support nodes
  "bi2", "bi2l", "bi2r", "bi3", "bi3l", "bi3r", -- rear body nodes at shock-tower region
  "br3l", "br3r", "br4l", "br4r",  -- lower/rear body references
  "br6l", "br6r", "br7",              -- rear body / bumper-plane references
  "fw1l", "fw1ll", "fw1r", "fw1rr", -- wheel hub points
}

local nodeCids = {}
local nodeColumnStarts = {}
local shockBeamCids = {FL = {}, FR = {}}
local shockBeamColumnStarts = {FL = {}, FR = {}}
local headers = {}
local samples = {}
local sampleCount = 0
local nextSampleIndex = 1
local inputEvents = {}
local inputEventCount = 0
local nextInputEventIndex = 1
local previousInputs = nil
local elapsedSimulationTime = 0
local sampleAccumulator = 0
local lastSampleTime = nil
local initialized = false
local physicsHookEnabled = false
local missingNodes = {}
local repeatableTest = nil
local updateRepeatableTest
local neutralizeTestInputs

-- Uses BeamNG's direct vehicle input filter (2) so every run gets identical
-- input values and simulation-time intervals. The launch can move the vehicle.
local repeatableTestProfile = {
  {time = 0, name = "baseline_start", inputs = {steering = 0, throttle = 0, brake = 0, clutch = 0}},
  {time = 5, name = "clutch_prep", inputs = {clutch = 0.17}},
  {time = 6.5, name = "throttle_touch", inputs = {throttle = 0.03}},
  {time = 6.7, name = "full_throttle", inputs = {throttle = 1}},
  {time = 8.85, name = "clutch_release", inputs = {clutch = 0.02}},
  {time = 11.85, name = "throttle_release", inputs = {throttle = 0}},
  {time = 21.85, name = "coast_complete", inputs = {}},
  {time = 26.85, name = "test_complete", inputs = {steering = 0, throttle = 0, brake = 0, clutch = 0}, finish = true},
}

local scalarHeaders = {
  "sim_time_s",
  "sample_dt_s",
  "vehicle_speed_mps",
  "steering_input",
  "throttle_input",
  "brake_input",
  "clutch_input",
  "shock_FL_length_m",
  "shock_FL_extension_speed_mps",
  "shock_FR_length_m",
  "shock_FR_extension_speed_mps",
}

local function safeNumber(value)
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
    return ""
  end
  return value
end

local function vectorComponent(vector, key)
  if not vector then return "" end
  return safeNumber(vector[key])
end

local function resetSamples()
  samples = {}
  sampleCount = 0
  nextSampleIndex = 1
  inputEvents = {}
  inputEventCount = 0
  nextInputEventIndex = 1
  previousInputs = nil
  elapsedSimulationTime = 0
  sampleAccumulator = 0
  lastSampleTime = nil
end

local function addInputEvent(name, previousValue, value, speed)
  local event = inputEvents[nextInputEventIndex]
  if not event then
    event = {}
    inputEvents[nextInputEventIndex] = event
  end

  event.time = elapsedSimulationTime
  event.name = name
  event.previousValue = safeNumber(previousValue)
  event.value = safeNumber(value)
  event.speed = safeNumber(speed)

  nextInputEventIndex = nextInputEventIndex % eventCapacity + 1
  inputEventCount = math.min(inputEventCount + 1, eventCapacity)
end

local function getSteeringDirection(value)
  if type(value) ~= "number" or math.abs(value) <= steeringDeadzone then
    return 0
  end
  return value < 0 and -1 or 1
end

local function recordInputEvents(inputValues, speed)
  local current = {
    steering = type(inputValues.steering) == "number" and inputValues.steering or 0,
    throttle = type(inputValues.throttle) == "number" and inputValues.throttle or 0,
    brake = type(inputValues.brake) == "number" and inputValues.brake or 0,
    clutch = type(inputValues.clutch) == "number" and inputValues.clutch or 0,
  }

  if not previousInputs then
    previousInputs = current
    return
  end

  for _, name in ipairs({"throttle", "brake", "clutch"}) do
    local wasActive = previousInputs[name] > inputDeadzone
    local isActive = current[name] > inputDeadzone
    if wasActive ~= isActive then
      addInputEvent(name .. (isActive and "_pressed" or "_released"), previousInputs[name], current[name], speed)
    end
  end

  local previousDirection = getSteeringDirection(previousInputs.steering)
  local currentDirection = getSteeringDirection(current.steering)
  if previousDirection ~= currentDirection then
    if currentDirection == 0 then
      addInputEvent("steering_centered", previousInputs.steering, current.steering, speed)
    elseif previousDirection == 0 then
      addInputEvent(currentDirection < 0 and "steering_left_start" or "steering_right_start", previousInputs.steering, current.steering, speed)
    else
      addInputEvent(currentDirection < 0 and "steering_reversal_left" or "steering_reversal_right", previousInputs.steering, current.steering, speed)
    end
  end

  previousInputs = current
end

local function findNodeCids()
  nodeCids = {}
  missingNodes = {}

  for _, node in pairs(v.data.nodes) do
    if node.name then
      nodeCids[node.name] = node.cid
    end
  end

  for _, name in ipairs(trackedNodeNames) do
    local isOptionalSeatVariant = name:match("^isF[LR]%d") or name:match("^ocpF[LR]")
    if nodeCids[name] == nil and not isOptionalSeatVariant then
      table.insert(missingNodes, name)
    end
  end
end

local function findShockBeamCids()
  shockBeamCids = {FL = {}, FR = {}}

  for _, beam in pairs(v.data.beams) do
    local node1 = v.data.nodes[beam.id1]
    local node2 = v.data.nodes[beam.id2]
    if node1 and node2 then
      local name1 = node1.name
      local name2 = node2.name
      if (name1 == "fh1l" and name2 == "fs1l") or (name1 == "fs1l" and name2 == "fh1l") then
        table.insert(shockBeamCids.FL, beam.cid)
      elseif (name1 == "fh1r" and name2 == "fs1r") or (name1 == "fs1r" and name2 == "fh1r") then
        table.insert(shockBeamCids.FR, beam.cid)
      end
    end
  end

  table.sort(shockBeamCids.FL)
  table.sort(shockBeamCids.FR)
end

local function buildHeaders()
  headers = {}
  nodeColumnStarts = {}
  shockBeamColumnStarts = {FL = {}, FR = {}}

  for _, name in ipairs(scalarHeaders) do
    table.insert(headers, name)
  end

  for _, name in ipairs(trackedNodeNames) do
    if nodeCids[name] ~= nil then
      nodeColumnStarts[name] = #headers + 1
      table.insert(headers, name .. "_ref_x_m")
      table.insert(headers, name .. "_ref_y_m")
      table.insert(headers, name .. "_ref_z_m")
      table.insert(headers, name .. "_vel_x_mps")
      table.insert(headers, name .. "_vel_y_mps")
      table.insert(headers, name .. "_vel_z_mps")
    end
  end

  for _, cid in ipairs(shockBeamCids.FL) do
    shockBeamColumnStarts.FL[cid] = #headers + 1
    table.insert(headers, "shock_FL_beam_" .. tostring(cid) .. "_length_m")
  end
  for _, cid in ipairs(shockBeamCids.FR) do
    shockBeamColumnStarts.FR[cid] = #headers + 1
    table.insert(headers, "shock_FR_beam_" .. tostring(cid) .. "_length_m")
  end
end

local function getNodeVector(row, name, offset)
  local start = nodeColumnStarts[name]
  if not start then return nil end
  return row[start + offset], row[start + offset + 1], row[start + offset + 2]
end

local function getShockMetrics(row, lowerName, upperName)
  local lx, ly, lz = getNodeVector(row, lowerName, 0)
  local lvx, lvy, lvz = getNodeVector(row, lowerName, 3)
  local ux, uy, uz = getNodeVector(row, upperName, 0)
  local uvx, uvy, uvz = getNodeVector(row, upperName, 3)

  if type(lx) ~= "number" or type(ly) ~= "number" or type(lz) ~= "number"
    or type(ux) ~= "number" or type(uy) ~= "number" or type(uz) ~= "number"
    or type(lvx) ~= "number" or type(lvy) ~= "number" or type(lvz) ~= "number"
    or type(uvx) ~= "number" or type(uvy) ~= "number" or type(uvz) ~= "number" then
    return "", ""
  end

  local dx, dy, dz = ux - lx, uy - ly, uz - lz
  local length = math.sqrt(dx * dx + dy * dy + dz * dz)
  if length <= 1e-9 then return length, "" end

  local dvx, dvy, dvz = uvx - lvx, uvy - lvy, uvz - lvz
  local extensionSpeed = (dx * dvx + dy * dvy + dz * dvz) / length
  return length, extensionSpeed
end

local function appendSample()
  local row = samples[nextSampleIndex]
  if not row then
    row = {}
    samples[nextSampleIndex] = row
  end

  local sampleDt = lastSampleTime and (elapsedSimulationTime - lastSampleTime) or 0
  lastSampleTime = elapsedSimulationTime

  local vehicleVelocity = obj:getVelocity()
  local speed = vehicleVelocity and vehicleVelocity:length() or ""
  local inputValues = electrics and electrics.values or {}
  recordInputEvents(inputValues, speed)

  row[1] = elapsedSimulationTime
  row[2] = sampleDt
  row[3] = safeNumber(speed)
  row[4] = safeNumber(inputValues.steering)
  row[5] = safeNumber(inputValues.throttle)
  row[6] = safeNumber(inputValues.brake)
  row[7] = safeNumber(inputValues.clutch)

  for _, name in ipairs(trackedNodeNames) do
    local start = nodeColumnStarts[name]
    local cid = nodeCids[name]
    if start and cid ~= nil then
      local position = obj:getNodePosition(cid)
      local velocity = obj:getNodeVelocityVector(cid)
      row[start] = vectorComponent(position, "x")
      row[start + 1] = vectorComponent(position, "y")
      row[start + 2] = vectorComponent(position, "z")
      row[start + 3] = vectorComponent(velocity, "x")
      row[start + 4] = vectorComponent(velocity, "y")
      row[start + 5] = vectorComponent(velocity, "z")
    end
  end

  local shockFLLength, shockFLSpeed = getShockMetrics(row, "fh1l", "fs1l")
  local shockFRLength, shockFRSpeed = getShockMetrics(row, "fh1r", "fs1r")
  row[8] = safeNumber(shockFLLength)
  row[9] = safeNumber(shockFLSpeed)
  row[10] = safeNumber(shockFRLength)
  row[11] = safeNumber(shockFRSpeed)

  for _, cid in ipairs(shockBeamCids.FL) do
    row[shockBeamColumnStarts.FL[cid]] = safeNumber(obj:getBeamLength(cid))
  end
  for _, cid in ipairs(shockBeamCids.FR) do
    row[shockBeamColumnStarts.FR[cid]] = safeNumber(obj:getBeamLength(cid))
  end

  nextSampleIndex = nextSampleIndex % sampleCapacity + 1
  sampleCount = math.min(sampleCount + 1, sampleCapacity)
end

local function initialize()
  if not v or not v.data then
    initialized = false
    return
  end

  findNodeCids()
  findShockBeamCids()
  buildHeaders()
  resetSamples()
  initialized = true

  if #missingNodes > 0 then
    log("W", "suspensionDebug", "Missing tracked nodes: " .. table.concat(missingNodes, ", "))
  end
end

local function onPhysicsStep(dt)
  if not initialized or type(dt) ~= "number" or dt <= 0 then return end

  elapsedSimulationTime = elapsedSimulationTime + dt
  if updateRepeatableTest then updateRepeatableTest(dt) end
  sampleAccumulator = sampleAccumulator + dt
  if sampleAccumulator >= sampleInterval then
    sampleAccumulator = sampleAccumulator % sampleInterval
    appendSample()
  end
end

local function onReset()
  if repeatableTest and neutralizeTestInputs then neutralizeTestInputs() end
  repeatableTest = nil
  resetSamples()
end

local function clearBuffer()
  if repeatableTest then
    return false, "cannot clear telemetry while a repeatable test is running"
  end

  resetSamples()
  print("[Bug:Debug] Suspension telemetry buffer cleared")
  return true
end

local function markEvent(name)
  if type(name) ~= "string" or name == "" then
    return false, "event name must be a non-empty string"
  end

  local vehicleVelocity = obj:getVelocity()
  local speed = vehicleVelocity and vehicleVelocity:length() or ""
  addInputEvent("marker:" .. name, "", "", speed)
  return true
end

local function tryEnablePhysicsHook()
  if physicsHookEnabled or not rawget(_G, "controller") then return end

  local enablePhysicsHook = _G and _G["enablePhysicsStepHook"]
  if type(enablePhysicsHook) == "function" then
    enablePhysicsHook()
    physicsHookEnabled = true
  else
    log("W", "suspensionDebug", "Physics-step hook is unavailable; telemetry will not be sampled")
  end
end

local function onExtensionLoaded()
  initialize()
end

local function updateGFX()
  -- onExtensionLoaded runs before the vehicle controller is initialized.
  -- The first graphics update occurs after startup, so it is safe to enable
  -- physics-step callbacks here.
  tryEnablePhysicsHook()
end

local function valueToCsv(value)
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
    return ""
  end
  return string.format("%.9g", value)
end

local function getCSV()
  local lines = {table.concat(headers, ",")}
  local firstIndex = sampleCount == sampleCapacity and nextSampleIndex or 1

  for offset = 0, sampleCount - 1 do
    local index = (firstIndex + offset - 1) % sampleCapacity + 1
    local row = samples[index]
    local values = {}
    for column = 1, #headers do
      values[column] = valueToCsv(row and row[column])
    end
    lines[#lines + 1] = table.concat(values, ",")
  end

  return table.concat(lines, "\n") .. "\n"
end

local function csvText(value)
  local text = tostring(value or "")
  return '"' .. text:gsub('"', '""') .. '"'
end

local function getEventsCSV()
  local lines = {"sim_time_s,event,previous_value,value,vehicle_speed_mps"}
  local firstIndex = inputEventCount == eventCapacity and nextInputEventIndex or 1

  for offset = 0, inputEventCount - 1 do
    local index = (firstIndex + offset - 1) % eventCapacity + 1
    local event = inputEvents[index]
    lines[#lines + 1] = table.concat({
      valueToCsv(event.time),
      csvText(event.name),
      valueToCsv(event.previousValue),
      valueToCsv(event.value),
      valueToCsv(event.speed),
    }, ",")
  end

  return table.concat(lines, "\n") .. "\n"
end

local function writeCSV(path)
  path = path or "debug/suspensionTelemetry.csv"
  if type(writeFile) ~= "function" then
    return false, "writeFile is not available in this vehicle Lua context"
  end

  local ok, result = pcall(writeFile, path, getCSV())

  if ok then print("[Bug:Debug] Suspension telemetry written to " .. path)
  else print("[Bug:Debug] Failed to write suspension telemetry to " .. path .. ": " .. tostring(result))
  end

  if not ok then return false, result end
  return result ~= false, path
end

local function writeEventsCSV(path)
  path = path or "debug/suspensionInputEvents.csv"
  if type(writeFile) ~= "function" then
    return false, "writeFile is not available in this vehicle Lua context"
  end

  local ok, result = pcall(writeFile, path, getEventsCSV())
  if ok then print("[Bug:Debug] Suspension input events written to " .. path)
  else print("[Bug:Debug] Failed to write suspension input events to " .. path .. ": " .. tostring(result))
  end

  if not ok then return false, result end
  return result ~= false, path
end

local testInputOrder = {"steering", "throttle", "brake", "clutch"}

local function applyTestInputs(values)
  local inputModule = rawget(_G, "input")
  if type(inputModule) ~= "table" or type(inputModule.event) ~= "function" then
    return false, "vehicle input.event API is unavailable"
  end

  for _, name in ipairs(testInputOrder) do
    local value = values[name]
    if value ~= nil then
      local ok, err = pcall(inputModule.event, name, value, 2) -- FILTER_DIRECT
      if not ok then return false, tostring(err) end
    end
  end
  return true
end

neutralizeTestInputs = function()
  applyTestInputs({steering = 0, throttle = 0, brake = 0, clutch = 0})
end

local function writeTestExports(label, suffix)
  local base = "debug/suspensionTelemetry_" .. label .. (suffix or "")
  writeCSV(base .. ".csv")
  writeEventsCSV("debug/suspensionInputEvents_" .. label .. (suffix or "") .. ".csv")
end

local function startRepeatableTest(label)
  if repeatableTest then return false, "a repeatable test is already running" end
  if not initialized then return false, "suspension telemetry is not initialized" end
  local inputModule = rawget(_G, "input")
  if type(inputModule) ~= "table" or type(inputModule.event) ~= "function" then
    return false, "vehicle input.event API is unavailable"
  end

  local vehicleVelocity = obj:getVelocity()
  local speed = vehicleVelocity and vehicleVelocity:length() or math.huge
  if speed < 1.2 or speed > 2.0 then
    return false, "vehicle must be rolling slowly at 1.2-2.0 m/s (target about 1.6 m/s) before starting"
  end

  label = tostring(label or "run")
  label = label:gsub("[^%w_%-]", "_"):sub(1, 32)
  if label == "" then label = "run" end

  resetSamples()
  repeatableTest = {label = label, elapsed = 0, nextStep = 2}
  local ok, err = applyTestInputs(repeatableTestProfile[1].inputs)
  if not ok then
    repeatableTest = nil
    return false, err
  end

  markEvent("test_" .. label .. "_started")
  markEvent("test_" .. label .. "_" .. repeatableTestProfile[1].name)
  print("[Bug:Debug] Repeatable test '" .. label .. "' started. Keep the vehicle on a clear, straight test area and do not touch the controls.")
  return true, label
end

local function stopRepeatableTest(reason)
  if not repeatableTest then return false, "no repeatable test is running" end

  local label = repeatableTest.label
  neutralizeTestInputs()
  markEvent("test_" .. label .. "_stopped_" .. tostring(reason or "manual"))
  repeatableTest = nil
  writeTestExports(label, "_partial")
  print("[Bug:Debug] Repeatable test stopped; partial capture exported for '" .. label .. "'.")
  return true
end

updateRepeatableTest = function(dt)
  if not repeatableTest then return end

  repeatableTest.elapsed = repeatableTest.elapsed + dt
  while repeatableTest do
    local step = repeatableTestProfile[repeatableTest.nextStep]
    if not step or repeatableTest.elapsed < step.time then break end

    local label = repeatableTest.label
    local ok, err = applyTestInputs(step.inputs)
    if not ok then
      print("[Bug:Debug] Repeatable test input failed: " .. tostring(err))
      stopRepeatableTest("input_error")
      return
    end

    markEvent("test_" .. label .. "_" .. step.name)
    repeatableTest.nextStep = repeatableTest.nextStep + 1
    if step.finish then
      neutralizeTestInputs()
      repeatableTest = nil
      writeTestExports(label)
      print("[Bug:Debug] Repeatable test '" .. label .. "' complete; telemetry and event CSVs exported.")
      return
    end
  end
end

local function getStatus()
  local availableNodes = {}
  for _, name in ipairs(trackedNodeNames) do
    if nodeCids[name] ~= nil then
      table.insert(availableNodes, name)
    end
  end

  return {
    initialized = initialized,
    sampleRateHz = sampleRateHz,
    sampleCount = sampleCount,
    capacity = sampleCapacity,
    bufferedSimulationSeconds = sampleCount * sampleInterval,
    inputEventCount = inputEventCount,
    inputEventCapacity = eventCapacity,
    testActive = repeatableTest ~= nil,
    testLabel = repeatableTest and repeatableTest.label or nil,
    testElapsed = repeatableTest and repeatableTest.elapsed or nil,
    testDuration = repeatableTestProfile[#repeatableTestProfile].time,
    trackedNodes = availableNodes,
    missingNodes = missingNodes,
    shockBeamCountFL = #shockBeamCids.FL,
    shockBeamCountFR = #shockBeamCids.FR,
  }
end

local function printStatus()
    local status = getStatus()
    print("[Bug:Debug] Suspension Status:")
    print("  Initialized: " .. tostring(status.initialized))
    print("  Sample Rate (Hz): " .. tostring(status.sampleRateHz))
    print("  Sample Count: " .. tostring(status.sampleCount))
    print("  Capacity: " .. tostring(status.capacity))
    print("  Buffered Simulation Seconds: " .. tostring(status.bufferedSimulationSeconds))
    print("  Input Event Count: " .. tostring(status.inputEventCount))
    print("  Input Event Capacity: " .. tostring(status.inputEventCapacity))
    print("  Repeatable Test Active: " .. tostring(status.testActive))
    if status.testActive then
      print("  Repeatable Test: " .. tostring(status.testLabel) .. " at " .. string.format("%.2f", status.testElapsed) .. " / " .. string.format("%.2f", status.testDuration) .. " s")
    end
    print("  Tracked Nodes: " .. table.concat(status.trackedNodes, ", "))
    print("  Missing Nodes: " .. table.concat(status.missingNodes, ", "))
    print("  Shock Beam Count (FL): " .. tostring(status.shockBeamCountFL))
    print("  Shock Beam Count (FR): " .. tostring(status.shockBeamCountFR)) 
end

M.onInit = initialize
M.onExtensionLoaded = onExtensionLoaded
M.onReset = onReset
M.onPhysicsStep = onPhysicsStep
M.updateGFX = updateGFX

M.getCSV = getCSV
M.writeCSV = writeCSV
M.getEventsCSV = getEventsCSV
M.writeEventsCSV = writeEventsCSV
M.getStatus = getStatus
M.printStatus = printStatus
M.clearBuffer = clearBuffer
M.markEvent = markEvent
M.startRepeatableTest = startRepeatableTest
M.stopRepeatableTest = stopRepeatableTest

return M