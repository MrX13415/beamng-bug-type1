-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- v1.0
-- by MrX13415

local M = {}
local updateTimer = 2   -- Make sure the first call is immediately

local thrusters = {}
local gearboxFriction = nil
local inWater = 0
local wasInWater = false
local debug = true

local avToRPM = 9.549296596425384
local engine = nil
local gearbox = nil

local function dump(engine)
  if engine ~= nil then
    --guihooks.graph({"Load", engine.engineLoad, 1.5}, {"DynamicFriction", engine.dynamicFriction, 1.5}, {"Friction", engine.friction, 1.5})

    local tkeys = {}
    for k in pairs(engine) do table.insert(tkeys, k) end
    table.sort(tkeys)
    local i = 0
    for _, k in ipairs(tkeys) do 
      local v = engine[k]
      if type(v) ~= "table" and type(v) ~= "function" then
        i = i + 1
        if i > 0 and i < 150 then
          print(tostring(k) ..  " = " .. tostring(v))
        end
      end
    end
    for k,v in pairs(engine) do
    end
  end
end

local function endswith(text, suffix)
  return string.sub(text, -#suffix) == suffix
end

local function updateThrusters()
  if v.data.thrusters == nil then return end
  
  -- load thrusters ...
  if #thrusters == 0 then
    for index, thruster in pairs(v.data.thrusters) do
      if endswith(thruster.partPath, "/bug_water_thrusters") then
        local t = {}
        t.id = thruster.id2
        t.factor = thruster.factor
        thrusters[index] = t
      end
    end
  end
  
  -- debug
  local graphdata = {}


  local rpm = 0
  if gearbox ~= nil then
    rpm = gearbox.outputAV1 + avToRPM
  end

  local factorMod = rpm / 100 / 4
  local running = electrics.values.running and 1 or 0
  
  -- Adjust the thruster power based in gearbox RPM
  for index, thruster in pairs(v.data.thrusters) do
    local t = thrusters[index]
    if t ~= nil then
      local w = obj:inWater(t.id)
      inWater = w and 1.0 or inWater

      local f = t.factor * factorMod
      f = f * inWater * running
      thruster.factor = f
      
      -- debug
      table.insert(graphdata, {"Thruster #" .. tostring(t.id) .." Factor", thruster.factor, 10000})
    end
  end

  -- "Fake" gearbox load from water 
  if gearbox then
    if not gearboxFriction then
      gearboxFriction = gearbox.friction
    end

    if gearboxFriction and wasInWater ~= (inWater > 0.1) then
      if inWater > 0.5 then
        gearbox.friction = 40
      else
        gearbox.friction = gearboxFriction
      end
    end

    -- debug
    table.insert(graphdata, {"Gearbox Friction", gearbox.friction, 100})
  end
  
  -- Basic "rev limiter" in case the engine does not have one
  if engine ~= nil and inWater > 0.5 then
    local engineAV = engine.outputAV1
    if engineAV > engine.maxAV and not engine.hasRevLimiter then
      local throttleAdjust = math.min(math.max((engineAV - engine.maxAV * 1.02) / (engine.maxAV * 0.03), 0), 1)
      electrics.values.throttle = math.min(math.max(engine.throttle - throttleAdjust, 0), 1)
    end
  end
  
  table.insert(graphdata, {"In Water", inWater, 1})
  wasInWater = inWater > 0.1
  if inWater > 0 then inWater = math.max(inWater - 0.02, 0) end 

  -- debug
  if debug then guihooks.graph(unpack(graphdata)) end
end

local function updateGFX(dt)
  updateThrusters()
end

local function onInit(jbeamData)
end

local function onReset()
  engine = powertrain.getDevice("mainEngine")
  gearbox = powertrain.getDevice("gearbox")
end

M.onInit    = onInit
M.onReset   = onReset
M.updateGFX = updateGFX
M.onPlayersChanged = onPlayersChanged

-- public interface

return M
