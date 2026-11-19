-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Game-engine side of the owner's manual in the glovebox (extension name: bug_manual).
--
-- A click on the book in the open glovebox (trigger ownerManual) runs vehicle.openManual, which loads this
-- extension and calls open(). open() switches the UI to the route "bug.manual". The route is registered by
-- the Vue mod in ui/ui-vue/mods/bug_manual (index.js) when the UI loads; the page itself is BugManual.vue.
--
-- While the manual is open the game keeps running (it is not paused), the HUD apps are hidden and the mouse
-- belongs to the UI. Esc / the close button go back to the route the player came from (normally "play").

local M = {}

-- bumped on every change: the vehicle reloads this extension when an older version is still loaded
M.version = 3

local ROUTE_NAME = "bug.manual"  -- must match the route name in ui/ui-vue/mods/bug_manual/index.js
--local PAUSE_WHILE_READING = true  -- old: paused the simulation while the manual was open (route onEnter / onLeave)

local returnRoute = nil   -- route to go back to when the manual is closed
local state = {
  vehicleId   = nil,
  personality = false,    -- true: show the Herbie chapter (car has the personality part)
  page        = 0,        -- last open page spread, so the book opens where the player left it
}

local function router() return extensions.ui_router end

local function currentRouteName()
  local r = router()
  local entry = r and r.getCurrent and r.getCurrent()
  return entry and entry.request and entry.request.name or nil
end

-- called by the vehicle (vehicle.openManual)
local function open(vehicleId, personality)
  local r = router()
  if not r then
    log('E', 'bug_manual', 'ui_router not available, cannot open the owner\'s manual')
    return
  end

  local current = currentRouteName()
  if current == ROUTE_NAME then return end  -- already open
  log('I', 'bug_manual', 'opening the owner\'s manual from route ' .. tostring(current) .. ' (vehicle ' .. tostring(vehicleId) .. ')')

  if state.vehicleId ~= vehicleId then state.page = 0 end  -- a different car opens on the cover
  state.vehicleId   = vehicleId
  state.personality = personality == true
  returnRoute = current or "play"

  local res = r.navigate(ROUTE_NAME)
  if type(res) == "table" and res.result == false then
    -- most likely the Vue mod didn't register its route (UI mods failed to load)
    log('W', 'bug_manual', 'Could not open the owner\'s manual: ' .. tostring(res.reason))
    ui_message("Owner's manual could not be opened (" .. tostring(res.reason) .. ")", 5, "bug.manual")
  end
end

-- called by the UI (close button) and as the back action
local function close()
  if currentRouteName() ~= ROUTE_NAME then return end
  local target = returnRoute or "play"
  returnRoute = nil
  local res = router().navigate(target)
  if type(res) == "table" and res.result == false and target ~= "play" then
    router().navigate("play")
  end
end

-- read by the UI when the page opens
local function getState()
  return state
end

-- the UI reports the open page spread
local function setPage(page)
  state.page = tonumber(page) or 0
end

-- the vehicle that owns the open manual was removed or replaced: close the book
local function onVehicleDestroyed(vid)
  if vid == state.vehicleId then close() end
end

M.open                = open
M.close               = close
M.getState            = getState
M.setPage             = setPage
M.onVehicleDestroyed  = onVehicleDestroyed

return M
