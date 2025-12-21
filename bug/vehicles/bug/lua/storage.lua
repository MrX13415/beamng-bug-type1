-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- v1.1
-- by MrX13415

local M = {}

local filepath = ""

local saveTimer = 0
local saveSuspended = false
local loaded = false
local _data = {}

-- common

local function load(file)
	filepath = file or filepath
	_data = jsonReadFile(filepath)
	loaded = true
	log("D", "", "[Bug:Storage] Loaded")

	if _data ~= nil then return true end
	_data = {}
	return false
end

local function save()
	if not playerInfo.firstPlayerSeated then return end
	log("D", "", "[Bug:Storage] Saved")
	return jsonWriteFile(filepath, _data, true)
end

local function updateGFX(dt)
	saveTimer = saveTimer + dt

	-- Speedo is no longer saved here and the metrics are used from the game directly.
	-- Only "player trust" is saved currently. Therefore, no need to save frequently.
	-- Save rate: Once per minute
	if saveTimer >= 60 then
		saveTimer = 0
		if not saveSuspended then
			 save()
		end
	end
end

local function onReset()
	load("settings"..v.vehicleDirectory.."data.json")
end

local function data()
	if not loaded then 
		load()
	end
	return _data
end

local function suspend(value)
	saveSuspended = value
end

M.onReset   = onReset
M.updateGFX = updateGFX

M.data      = data

M.suspend   = suspend

return M
