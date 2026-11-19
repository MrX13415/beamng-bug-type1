-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Car store, vehicle side: every car has its own identity and its own save record.
-- v2 (v1.2 by MrX13415 kept one file for all Bugs)
--
-- Identity
--   - car id: 32 hex digits (128 bit), random, made when a car is saved the first time. It names the record file:
--     settings/bug/cars/<carId>.json.
--   - Which car a spawned vehicle is, is decided by a binding key, looked up in settings/bug/cars/index.json
--     (binding → car id):
--       "config:<config file>"   now: every vehicle config is its own car (two vehicles of the same config at the
--                                same time share it);
--     and without changing this file's callers:
--       spawn options can name the car directly (additionalVehicleData.bugCarId, read from v.config), e.g. a second
--       car of the same config, or a career vehicle ("career:<inventoryId>" bindings, set up by a career module).
--
-- Record
--   { version, carId, binding, createdAt, lastSaved,
--     condition = <car condition model save, see carcondition.lua>,   -- registered with addSection
--     data      = { radio = … },                                       -- settings of features, storage.data()
--     events    = { {t, type, data}, … } }                              -- append-only history (see event)
--
-- Saving: within a second after a change (markDirty), and every SAVE_INTERVAL while the car is one the player has
-- used (seated in it, or changed something on it in the work mode), so traffic copies of a config don't write.
-- A vehicle reset (R) changes nothing here: conditions are kept.
--
-- The first record of each car takes over the radio settings from the old shared file (settings/vehicles/bug/data.json,
-- v1), which is left as it is. Other owners can take over their part of it too (legacyData, only for a new car).

local M = {}

local RECORD_VERSION = 2
local DIR = "settings/bug/cars/"
local INDEX_FILE = DIR .. "index.json"
local SAVE_INTERVAL = 30     -- s
local DIRTY_DELAY = 1        -- s   a change is saved this long after it

local record = nil           -- this car's record (loaded on first use)
local recordFile = nil
local pendingIndex = nil     -- {index, binding}: a new car's binding, written to the index with its first save
local parkedSeconds = nil    -- wall-clock seconds between the last save and this load (nil: new car)
local isNewCar = false
local sections = {}          -- name → function returning the section's table (called on save)
local saveTimer = 0
local dirtyTimer = nil
local saveSuspended = false
local used = false           -- the player sat in the car or changed something on it

-- ---- identity -------------------------------------------------------------------------------------------------

local function newCarId()
  local parts = {}
  local mix = (os.time() * 1000 + math.floor(os.clock() * 1e6) + obj:getId() * 7919) % 4294967296
  for i = 1, 4 do
    local r = math.random(0, 4294967295)
    parts[i] = string.format("%08x", bit.band(bit.bxor(r, mix * i), 0xffffffff) % 4294967296)
  end
  return table.concat(parts)
end

local function bindingKey()
  local cfg = v.config or {}
  local extra = cfg.additionalVehicleData
  if type(extra) == "table" and type(extra.bugCarId) == "string" and extra.bugCarId:match("^%x+$") then
    return "car:" .. extra.bugCarId, extra.bugCarId
  end
  local file = cfg.partConfigFilename
  if type(file) ~= "string" or file == "" then
    log("W", "bug.storage", "vehicle config file unknown: all such Bugs share one car record")
    file = "unknown"
  end
  return "config:" .. file, nil
end

local function legacyData()
  local d = jsonReadFile("settings" .. v.vehicleDirectory .. "data.json")
  return type(d) == "table" and d or nil
end

-- ---- record ---------------------------------------------------------------------------------------------------

-- the game's file writer creates missing folders itself (vehicle Lua has no FS:directoryCreate)
local function writeJson(file, value)
  return jsonWriteFile(file, value, true)
end

local function newRecord(carId, binding)
  local now = os.time()
  local rec = { version = RECORD_VERSION, carId = carId, binding = binding, createdAt = now, lastSaved = now,
                condition = nil, data = {}, events = {} }
  local old = legacyData()
  if old and type(old.radio) == "table" then rec.data.radio = old.radio end
  table.insert(rec.events, { t = now, type = "created", data = { binding = binding, fromLegacy = old ~= nil } })
  return rec
end

local function load()
  local binding, directId = bindingKey()
  local index = jsonReadFile(INDEX_FILE)
  if type(index) ~= "table" or type(index.bindings) ~= "table" then index = { version = 1, bindings = {} } end

  local carId = directId or index.bindings[binding]
  local rec = carId and jsonReadFile(DIR .. carId .. ".json") or nil
  if type(rec) == "table" and rec.carId == carId then
    parkedSeconds = rec.lastSaved and math.max(0, os.time() - rec.lastSaved) or nil
    rec.data = rec.data or {}
    rec.events = rec.events or {}
  else
    carId = carId or newCarId()
    rec = newRecord(carId, binding)
    parkedSeconds = nil
    isNewCar = true
    if not directId then pendingIndex = { binding = binding, carId = carId } end
    log("I", "bug.storage", "new car " .. carId .. " for " .. binding)
  end
  record = rec
  recordFile = DIR .. carId .. ".json"
  log("D", "bug.storage", "car " .. carId .. " (" .. binding .. ")" ..
    (parkedSeconds and string.format(", stood %.0f s", parkedSeconds) or ""))
end

local function getRecord()
  if not record then load() end
  return record
end

local function saveNow()
  local rec = getRecord()
  for name, provider in pairs(sections) do
    local ok, value = pcall(provider)
    if ok then rec[name] = value else log("E", "bug.storage", "section " .. name .. " failed to save: " .. tostring(value)) end
  end
  rec.lastSaved = os.time()
  rec.version = RECORD_VERSION
  dirtyTimer = nil
  local ok = writeJson(recordFile, rec)
  if ok and pendingIndex then
    -- read again just before writing: another Bug may have added its binding since this one loaded
    local index = jsonReadFile(INDEX_FILE)
    if type(index) ~= "table" or type(index.bindings) ~= "table" then index = { version = 1, bindings = {} } end
    index.bindings[pendingIndex.binding] = pendingIndex.carId
    writeJson(INDEX_FILE, index)
    pendingIndex = nil
  end
  return ok
end

-- a failing save is logged, never allowed to stop the car (an error in updateGFX disables the vehicle)
local function save()
  local ok, result = pcall(saveNow)
  if not ok then
    dirtyTimer = nil
    log("E", "bug.storage", "saving the car record failed: " .. tostring(result))
    return false
  end
  return result
end

-- ---- API ------------------------------------------------------------------------------------------------------

-- settings of features (radio …): a table inside the record, kept between sessions
local function data() return getRecord().data end

local function carId() return getRecord().carId end

-- a part of the record that another module owns: provider() returns its table when the record is saved
local function addSection(name, provider) sections[name] = provider end
-- the saved value of a section (nil for a new car), for the owner to load from
local function section(name) return getRecord()[name] end

-- true if this car's record was made in this session (no save of it existed)
local function isNew() getRecord() return isNewCar end
-- the old shared file of v1, for a new car to take over values from (nil if there is none)
local function getLegacyData() return legacyData() end

-- wall-clock seconds the car stood since its last save (nil: new car)
local function getParkedSeconds() getRecord() return parkedSeconds end

-- the player changed something on this car: save soon
local function markDirty()
  used = true
  dirtyTimer = dirtyTimer or DIRTY_DELAY
end

-- something changed that should be saved soon, but it is not by itself a reason to save a car the player never used
-- (e.g. a traffic car switching its lights on)
local function touch()
  dirtyTimer = dirtyTimer or DIRTY_DELAY
end

-- appends to the car's history (not a reason by itself to save a car the player never used). coalesce (s): a same-type event younger than this is updated instead (e.g. the
-- notches of one turn of a screw become one event)
local function event(eventType, eventData, coalesce)
  local events = getRecord().events
  local now = os.time()
  local last = events[#events]
  if coalesce and last and last.type == eventType and now - last.t <= coalesce then
    last.t, last.data = now, eventData
  else
    table.insert(events, { t = now, type = eventType, data = eventData })
  end
  touch()   -- saved soon, but only if the car is one the player uses (see updateGFX)
end

-- the newest event of a type, or nil
local function lastEvent(eventType)
  local events = getRecord().events
  for i = #events, 1, -1 do
    if events[i].type == eventType then return events[i] end
  end
  return nil
end

local function suspend(value) saveSuspended = value end

-- ---- hooks (auto-loaded vehicle extension) --------------------------------------------------------------------

local function updateGFX(dt)
  if playerInfo.firstPlayerSeated then used = true end
  if saveSuspended or not used then return end
  if dirtyTimer then
    dirtyTimer = dirtyTimer - dt
    if dirtyTimer <= 0 then save() saveTimer = 0 return end
  end
  saveTimer = saveTimer + dt
  if saveTimer >= SAVE_INTERVAL then
    saveTimer = 0
    save()
  end
end

M.updateGFX = updateGFX

M.data             = data
M.carId            = carId
M.addSection       = addSection
M.section          = section
M.getParkedSeconds = getParkedSeconds
M.isNew            = isNew
M.legacyData       = getLegacyData
M.markDirty        = markDirty
M.touch            = touch
M.event            = event
M.lastEvent        = lastEvent
M.save             = save
M.suspend          = suspend

return M
