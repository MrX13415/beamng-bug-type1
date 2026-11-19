-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Interior controls: interior light button, ash tray, heater valve and vents, the switch board (beacon, siren,
-- underglow, extra lights, nitrous), the hazard switch click the glovebox and the owner's manual in it.
-- Moved unchanged from vehicle.lua; the interaction actions still call vehicle.* (vehicle.lua forwards here).
-- vehicle.lua calls setup / update / reset (not game hooks on purpose: this file is also auto-loaded as a
-- vehicle extension, and the order is kept as before).

local M = {}

local misc = require("vehicles/bug/lua/misc")
local animation = require("vehicles/bug/lua/lib/animation")

local getControllerState = misc.getControllerState
local toggle = misc.toggle

local NodeNameSoundSFX = "dsh"
local nodeSFX = nil

local lightMessageLookup = {
  [0] = "ui.bug.interior.light.off",
  [1] = "ui.bug.interior.light.on",
}
local heatingValveMessageLookup = {
  [0] = "ui.bug.interior.heating.off",
  [1] = "ui.bug.interior.heating.on",
}

local hazardEnabled = 0

local function playSFX(soundname)
  if not nodeSFX then return end
  misc.playSound(soundname, nodeSFX)
end

local function handleHazard()
  local state = electrics.values.hazard_enabled
  if hazardEnabled ~= state then
    playSFX(state and "event:>Vehicle>Interior>Light>FIPA_On" or "event:>Vehicle>Interior>Light>FIPA_Off")
  end
  hazardEnabled = state
end

local function toggleInteriorLight()
  local lightstate = electrics.values.interiorlightbutton > 0 and 0 or 1
  electrics.values.interiorlightbutton = lightstate
  guihooks.message({txt = lightMessageLookup[lightstate], context = {}}, 4, "vehicle.interiorlights", "lightGarageG21")
end

local function toggleAshTray()
  toggle('ashtraystate')
end

local function setHeatingVent(vent, state)
  electrics.values['heating_vent' .. vent] = state
end

local function toggleHeatingVent(vent)
  toggle('heating_vent' .. vent)
end

local function toggleHeatingValve()
  toggle('heating_valve')
  local state = electrics.values.heating_valve or 0
  setHeatingVent("FL", state)
  setHeatingVent("FR", state)
  setHeatingVent("RL", state)
  setHeatingVent("RR", state)

  guihooks.message({txt = heatingValveMessageLookup[state], context = {}}, 4, "vehicle.heatingvalve", "temperatureL")
end

local function toggleSwitchBoard(name)
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
    playSFX(snd)
  end
end

local function toggleGlovebox(noAnimation)
  local isOpen = getControllerState('gloveboxCoupler') > 0
  if not noAnimation and not isOpen then
    animation.start("glovebox_knob")
  else
    controller.getControllerSafe('gloveboxCoupler').toggleGroup()
  end
end

-- Owner's manual in the glovebox (trigger ownerManual, bug.interior.dashboard.things.jbeam). Opens the manual
-- screen through the GE extension bug_manual (lua/ge/extensions/bug/manual.lua). The book is only reachable while
-- the glovebox is open; without a lid (no gloveboxCoupler) it always is. The trigger is behind the closed lid, so
-- a click there does nothing.
local function openManual()
  if controller.getController('gloveboxCoupler') and getControllerState('gloveboxCoupler') == 0 then
    log('D', 'bug.manual', 'owner\'s manual clicked, but the glovebox is shut')
    return
  end
  log('I', 'bug.manual', 'owner\'s manual clicked, opening it')

  -- the Herbie chapter is only shown on cars with the personality part (lua/hrb/hrb.lua)
  local hrbModule = rawget(_G, "hrb")
  local personality = hrbModule and hrbModule.isEnabled and hrbModule.isEnabled() or false

  misc.geCall("bug_manual", "bug_manual.open(" .. obj:getId() .. ", " .. tostring(personality) .. ")")  -- version check in misc.geCall
end

-- called from vehicle.onInit
local function setup()
  electrics.values.interiorlightstate = 0
  electrics.values.interiorlightbutton = 0
  electrics.values.ashtraystate = 0
  electrics.values.heating_valve = 0

  hazardEnabled = electrics.values.hazard_enabled or 0

  nodeSFX = misc.getNodeIDbyName(NodeNameSoundSFX)

  animation.setup('glovebox_knob', {
    {  0,   0},
    { 10, 0.8},
    { 20, 1.0},
    { 30, 0.4},
    { 40,   0}
  },{
    { 15, function() toggleGlovebox(true) end }
  })
end

-- called from vehicle.updateGFX
local function update(dt)
  handleHazard()
end

-- called from vehicle.onReset
local function reset()
  hazardEnabled = electrics.values.hazard_enabled or 0
end

M.setup               = setup
M.update              = update
M.reset               = reset

M.toggleInteriorLight = toggleInteriorLight
M.toggleAshTray       = toggleAshTray
M.toggleSwitchBoard   = toggleSwitchBoard
M.toggleGlovebox      = toggleGlovebox
M.openManual          = openManual
M.toggleHeatingValve  = toggleHeatingValve
M.toggleHeatingVent   = toggleHeatingVent
M.setHeatingVent      = setHeatingVent

return M
