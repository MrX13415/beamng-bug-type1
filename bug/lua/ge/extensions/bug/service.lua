-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- "Service" / "Wartung" pause-menu tab, concept. Game-engine side (extension: bug_service).
-- The tab is about this one car: its condition, service history and the settings of the engine model.
--
-- - Every Bug registers itself on spawn (vehicles/bug/lua/carcondition.lua → register(vehicleId)).
-- - While the player's vehicle is a Bug, a pause-menu tab "Service" ("Wartung") is shown. It uses the game's mod API for the
--   pause menu (ui_pause_actions.registerModTab / registerModButton, see ui/ui-vue/mods/README.md in the game).
--   Its cards are the Vue components in ui/ui-vue/mods/bug_service/.
-- - The vehicle pushes a snapshot once a second (onState). The UI reads the last one with getState(), so the
--   tab shows data even while the pause menu has the simulation paused.
-- - setSettings() writes Tuning variables through the game's config code, to test that our own UI can change
--   the same values as the Tuning tab (the car is respawned with the new value).

local M = {}

-- bumped on every change: the vehicle reloads this extension when an older version is still loaded
M.version = 3

local TAB_ID = "bug_service"
local MOD_PATH = "/ui/ui-vue/mods/bug_service/"
-- labels are translation keys (bug/locales/translations/*/bug.translation.json), translated with _tr when registered
local BUTTONS = {
  { id = "bug_service_condition", label = "ui.bug.service.condition",   icon = "engine",     component = "Condition.vue" },
  { id = "bug_service_book",      label = "ui.bug.service.serviceBook", icon = "bookOpened", component = "ServiceBook.vue" },
  { id = "bug_service_settings",  label = "ui.bug.service.settings",    icon = "settings",   component = "Settings.vue" },
}

local bugs = {}          -- vehicleId → true for every spawned Bug
local states = {}        -- vehicleId → last snapshot
local tabShown = false

local function pauseActions() return rawget(_G, "ui_pause_actions") end

local function showTab(show)
  local pa = pauseActions()
  if not pa or show == tabShown then return end
  if show then
    pa.unregisterModTab("bug_engine")  -- tab id of the first concept version, may still be registered in a running game
    pa.registerModTab({ id = TAB_ID, label = _tr("ui.bug.service.tab"), icon = "wrench", card2ComponentName = MOD_PATH .. "ServiceSide.vue" })
    for _, b in ipairs(BUTTONS) do
      pa.registerModButton({ id = b.id, tabId = TAB_ID, label = _tr(b.label), icon = b.icon, componentName = MOD_PATH .. b.component })
    end
  else
    pa.unregisterModTab(TAB_ID)
  end
  tabShown = show
end

local function playerVehicleId()
  local veh = getPlayerVehicle(0)
  return veh and veh:getId() or nil
end

local function refreshTab()
  local vid = playerVehicleId()
  showTab(vid ~= nil and bugs[vid] == true)
end

-- called by every Bug on spawn
local function register(vehicleId)
  bugs[vehicleId] = true
  refreshTab()
end

-- called by the vehicle once a second
local function onState(data)
  if type(data) == "table" and data.vehicleId then
    states[data.vehicleId] = data
  end
end

-- read by the UI: snapshot of the player's vehicle (or nil)
local function getState()
  local vid = playerVehicleId()
  return vid and states[vid] or nil
end

-- the UI changes engine-model settings: same path as the Tuning tab (core_vehicle_partmgmt.setConfigVars).
-- values are raw jbeam values (e.g. 0..1, not the 0..100 % shown). All in one call, so the car respawns once.
local ALLOWED = { ["$bugEmRealism"] = true, ["$bugEmFaultRate"] = true, ["$bugEmParkedSim"] = true,
                  ["$bugEmStartBattery"] = true, ["$bugEmStartOilKm"] = true }
local function setSettings(values)
  local partmgmt = rawget(_G, "core_vehicle_partmgmt")
  if type(values) ~= "table" or not partmgmt then return false end
  local vars = {}
  for name, value in pairs(values) do
    if ALLOWED[name] and type(value) == "number" then vars[name] = value end
  end
  if next(vars) == nil then return false end
  log('I', 'bug_service', 'setting tuning vars ' .. dumps(vars))
  partmgmt.setConfigVars(vars, true)
  return true
end

local function onVehicleSwitched()
  refreshTab()
end

local function onVehicleDestroyed(vid)
  bugs[vid] = nil
  states[vid] = nil
  refreshTab()
end

local function onExtensionUnloaded()
  showTab(false)
end

M.register            = register
M.onState             = onState
M.getState            = getState
M.setSettings         = setSettings
M.onVehicleSwitched   = onVehicleSwitched
M.onVehicleDestroyed  = onVehicleDestroyed
M.onExtensionUnloaded = onExtensionUnloaded

return M
