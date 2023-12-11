-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Lua Radio for the VW Beetle mod.
-- v2.2
-- by MrX13415 (2023-11-18)

-- Please give credit when using this :)


local M = {}

-- The local stations folder expects subfolders with the following name schema, containing one or more MP3 or WAV files.
-- Schema: 'nnn.n <name>' or 'nnn.n-<name>' or 'nnn.n_<name>'
-- i.e '97.5 K-DST'
local LocalStationsFolder = "settings/vehicles/bug/radio"
local TracksCacheFile = "settings/vehicles/bug/radio/cache.json"
-- Station mods need an empty JBeam part with slotType descripted in "SlotTypeRadioStation" (see below),
-- with an additional field "song" containing the relative audio file path in the "information" section.
local ModStationsFolder = "/vehicles/bug"

-- Sound events
local RadioSnowSFX = "vehicles/bug/components/sounds/radio/radio-snow.ogg"
local PresetUseSFX = "event:>Vehicle>Interior>Light>AU3_On"
local PresetSetSFX = "event:>Vehicle>Interior>Light>AU3_Off"
local RadioOnSFX = "event:>Vehicle>Interior>Light>AU5_AC_Dial_On"
local RadioOffSFX = "event:>Vehicle>Interior>Light>AU5_AC_Dial_Off"

-- Parts
local PartRadio = "bug_radio"
local PartInteriorOnlyMode = "bug_radio_mode_interior"
local PartOutput3D = "bug_radio_output_3D"
local SlotTypeRadioStation = "bug_radio_station"

-- Nodes
local NodeNameDriver = "driver"
local NodeNameSoundSFX = "dsh"
local NodeNameSpeaker = "speaker"

-- Defaults
local frequencyMin = 87.5	-- Mhz  Lower frequency limit
local frequencyMax = 108	-- Mhz  Upper frequency limit
local frequencyGrid = 0.2	-- Mhz  Frequency tolerance

-- Globals
local radio = nil
local output3D = false

-- Local ---------------------------------------------

local function playSound(soundname, nodeId, volume, pitch)
	sounds.playSoundOnceAtNode(soundname, nodeId, volume or 1, pitch or 1, 0, 0)
end

-- Class: SoundObj -----------------------------------

local SoundObj = {}
SoundObj.__index = SoundObj

function SoundObj:new(node, volume)
	local self = setmetatable({}, SoundObj)

	self.obj = nil
	self.nodeId = getNodeIDbyName(node)
	self.volume = volume or 1

	return self
end

function SoundObj:load(filepath, loop)

	sfxDescription = loop and "AudioMusicLoop2D" or "AudioMusic2D"
	if output3D then 
		sfxDescription = loop and "AudioMusicLoop3D" or "AudioMusic3D"
	end

	if self.nodeId then
		if self.obj then
			obj:stopSFX(self.obj)
			obj:deleteSFXSource(self.obj)
		end
		if not filepath then return end
		local name = string.gsub(filepath, "/", ":")

		-- Note: The sfx description value here does nothing when using sounds defined as material in a json file.
		--       We are using the relative file paths here instead.
		self.obj = obj:createSFXSource(filepath, sfxDescription, name, self.nodeId or 0)
		-- Note:
		-- obj:createSFXSource			-- Not reseted
		-- obj:createSFXSource2			-- Gets reset on vehicle restore/reset

		--if sound then
		  --sound:setTransform(obj:getTransform())
		  --sound:setParameter("distance_vehicle", 10000)
		  --sound:setVolume(1)
		  --sound:play(-1)
		--end
	end
	if self.obj then
		obj:playSFX(self.obj)
		self:setVolume(self.volume)
	end
end

function SoundObj:play()
	if self.obj == nil then return end
	if not obj:isPlayingSFX(self.obj) then obj:playSFX(self.obj) end
end

function SoundObj:setVolume(volume)
	if self.obj == nil then return end
	self.volume = volume
	self:play() -- There seems to be an issue where a track randomly stop playing.
	obj:setVolume(self.obj, volume)
end


-- Class: Station ------------------------------------

local Station = {}
Station.__index = Station

function Station:new(freq, name, shuffle)
	local self = setmetatable({}, Station)
	
	self.mod = false
	self.builtIn = false

	self.frequency = math.min(math.max(freq, frequencyMin), frequencyMax)
	self.name = name or ""
	
	self.shuffle = true
	if shuffle ~= nil then self.shuffle = shuffle end

	self.tracks = {}
	self.elapsed = 0
	self.trackIndex = 1
	self.trackIndexLast = 0
	self.volumeMod = 1

	self.speaker = SoundObj:new(NodeNameSpeaker, 0)	-- Muted by default 

	return self
end

function Station:match(freq)
	if freq == nil then return 0 end
	local d = frequencyGrid - math.abs(self.frequency - freq)
	local d = math.min(math.max( 1 / frequencyGrid * d, 0), 1) 
	-- Assume match if >90%
	if d > 0.9 then d = 1 end
	-- Assume no match if <10%
	if d < 0.1 then d = 0 end
	return d
end

function Station:is(freq)
	return self:match(freq) > 0
end
 
function Station:track()
	return self.tracks[self.trackIndex]
end

function Station:setTrack(index)
	if index > #self.tracks then index = 1 end
	if index < 1 then index = #self.tracks end

	self.trackIndex = index
	self.elapsed = 0
end

function Station:shuffleTracks(t)
	if not self.shuffle then return false end
	if #self.tracks <= 1 then return false end

	math.randomseed(os.time())
	for i = #self.tracks, 2, -1 do
		local j = math.random(i)
		self.tracks[i], self.tracks[j] = self.tracks[j], self.tracks[i]
	end

	return true
end

function Station:setTrackRandom()
	math.randomseed(os.time())
	self:setTrack(math.random(1, #self.tracks))
end

function Station:playTrack()
	local track = self:track()
	if track == nil then return end

	local loop = #self.tracks == 1
	self.speaker:load(track.path, loop, track.volume)
	self:showInfo()
end

function Station:update(dt)
	-- Track changed?
	if self.trackIndex ~= self.trackIndexLast then
		self.trackIndexLast = self.trackIndex
		self:playTrack()
	end

	local track = self:track()
	if track == nil then return end		-- no tracks?

	-- update current track timer  ...
	self.elapsed = self.elapsed + dt
	if self.elapsed < track.duration then return end

	-- Track ended. Select next track ...
	self:setTrack(self.trackIndex + 1)
end

function Station:setVolume(volume)
	self.speaker:setVolume(volume)
end

function Station:showInfo(force)
	if not force and self.speaker.volume <= 0 then return end

	local track = self:track()
	print("[Bug:Radio] Station " ..tostring(self.frequency).. "MHz '" ..self.name.. "'")
	if #track.name > 0 then
		print("[Bug:Radio]  > #" ..tostring(self.trackIndex).. " " ..media.toTimeStr(self.elapsed).. "/" ..media.toTimeStr(track.duration).. " '" ..track.name.. "' (" ..track.type.. ")")
	end

	local msg = "Radio: " ..tostring(self.frequency).. "MHz - " ..self.name
	if track and #track.name > 0 then
		msg = msg .. "\n"
		if #self.tracks > 1 then
			 msg = msg .. "#" ..tostring(self.trackIndex).. " "
		end
		if track.duration > 0 then
			if self.elapsed > 3 then
				msg = msg ..media.toTimeStr(self.elapsed).. "/"
			end
			msg = msg ..media.toTimeStr(track.duration) .. " - "
		end
		msg = msg ..tostring(track.name)
	end

	guihooks.message({txt = msg, context = {}}, 8, "bug.radio.trackinfo")
end

-- Class: Radio --------------------------------------

local Radio = {}
Radio.__index = Radio

function Radio:new()
	local self = setmetatable({}, Radio)

	self.updateTimer = 0
	self.workerCoroutine = nil
	---------

	-- car states
	self.hasOpening = false
	self.engineRunning = electrics.values.running
	self.ignitionLevel = electrics.values.ignitionLevel

	-- modes
	self.interiorOnly = false
	self.open = 0
	
	self.installed = false
	self.power = false
	self.state = false
	self.button = false
	self.interruptTime = 0
	
	self.stations = {}
	self.stationIndex = 0

	self.freqLast = 0
	self.frequency = 0

	self.tuneDirection = 0
	self.tuning = false
	self.tuneNext = false
	self.tuneTimer = 0

	self.presetBtn = 0
	self.presetBtnTimer = 0
	self.presets = {
		[1] = {frequency = frequencyMin, user = false},
		[2] = {frequency = frequencyMin, user = false},
		[3] = {frequency = frequencyMin, user = false},
		[4] = {frequency = frequencyMin, user = false},
		[5] = {frequency = frequencyMin, user = false}
	}

	self.volume = 0
	self.volume2D = 1							-- Default volume for 2D mode. Use "Music slider" in game options to adjust.
	self.volume3D = 0.6							-- Default volume reduced by 40% in 3D mode as it is a lot louder compared to 2D.
	self.defaultVolumeModifier = 1				-- No boost or reduction
	self.exteriorClosedVolumeModifier = 0.1		-- Interor only mode: Very silent when everything is closed.
	self.exteriorOpenVolumeModifier = 1			-- Interor only mode: No boost or reduction as the cabin filter is modified directly now. (= 0.8	-- Reduce volume by 20% to boost interior volume due to the cabin filter.)
	
	self.userVolume = 0.3						-- Default user volume at 30%
	self.userVolumeDirection = 0

	self.nodeDriver = getNodeIDbyName(NodeNameDriver)
	self.nodeSFX = getNodeIDbyName(NodeNameSoundSFX)

	self.speaker = SoundObj:new(NodeNameSpeaker)

	electrics.values.radio_state = 0
	electrics.values.radio_volume = 0
	self:updateNeedle()
	self:updateButtons()

	return self
end

function Radio:initalize()
	self.installed = false
	
	-- Determine if a radio is installed ...
	for _,part in pairs(v.data.activeParts) do
		-- print(part.partName .. "  " .. part.slotType)
		if string.find(part.partName, PartRadio) then
			self.installed = true
		end
		
		-- part settings
		if part.partName == PartInteriorOnlyMode then
			self.interiorOnly = true
		end
		if part.partName == PartOutput3D then
			output3D = true
		end
		
		-- No longer used
		---- radio station
		--if part.slotType == SlotTypeRadioStation then
		--	local i = part.information
		--end
	end

	if not self.installed then return end
		
	self.power = electrics.values.ignitionLevel > 0
	self.open = electrics.values["vehicleopen"] or 0

	log("D", "", "[Bug:Radio] Initialized")
	log("D", "", "[Bug:Radio]    driver:   " .. (self.nodeDriver or 0) .. " (" .. NodeNameDriver .. ")")
	log("D", "", "[Bug:Radio]    sfx:      " .. (self.nodeSFX or 0) .. " (" .. NodeNameSoundSFX .. ")")
	log("D", "", "[Bug:Radio]    speaker:  " .. (self.speaker.nodeId or 0) .. " (" .. NodeNameSpeaker .. ")")
	log("D", "", "[Bug:Radio]    power:    " .. (self.power and "Yes" or "No"))
	log("D", "", "[Bug:Radio]    open:     " .. (self.hasOpening and ("Yes ("..tostring(self.open * 100).."%)") or "No"))
	log("D", "", "[Bug:Radio]    3D:       " .. (output3D and "Yes" or "No"))
	log("D", "", "[Bug:Radio]    interior: " .. (self.interiorOnly and "Yes" or "No"))

	-- load default static SFX as loop ...
	self.speaker:load(RadioSnowSFX, true)

	self:load()
	self:loadStations()
	self:setState()
end

function Radio:isOn()
	return self.power and self.state
end

function Radio:load()
	local d = storage.data().radio or {}
	self:setFrequency(d.frequency or 0)
	self.userVolume = math.min(math.max(d.volume or self.userVolume, 0), 1)
	
	for index,p in pairs(self.presets) do
		if d.presets and d.presets[tostring(index)] then 
			p.frequency = d.presets[tostring(index)]
			p.user = true
		end
	end
end

function Radio:save()
	local d = storage.data()
	d.radio = {}
	d.radio.frequency = self.frequency
	d.radio.volume = self.userVolume
	d.radio.presets = {}
	for index,p in pairs(self.presets) do
		if p.user then d.radio.presets[tostring(index)] = p.frequency end
	end
end

function Radio:reset()	
	print("[Bug:Radio] Reset to default settings.")
	
	self.frequency = 0
	self.userVolume = 0.3
	for _,p in pairs(self.presets) do
		p.frequency = frequencyMin
		p.user = false
	end	
	self:save()	

	self:initalize()
end

function Radio:toggleState()
	self.state = not self.state
	self:setState()
end

function Radio:setState(enabled)
	if self.installed == false then
		self.state = false
		print("[Bug:Radio] State: No radio installed")
		return
	end

	if enabled ~= nil then
		self.state = enabled
	else
		self.state = self.state
	end

	if self.state ~= self.button then self:playStateSFX() end
	self.button = self.state

	if self.state and self.power then
		electrics.values.radio_state = 1
		electrics.values.radio_volume = math.max(self.userVolume, 0.05) -- Ensure min. volume when on

		local v = string.format("%.0f%%", self.userVolume * 100)
		print("[Bug:Radio] State: On (Volume "..v..")")
		guihooks.message({txt = "Radio: On (Volume "..v..")", context = {}}, 4, "bug.radio")

		self:updateVolume()
		local s = self:station()
		if s then s:showInfo(true) end

	elseif self.state then
		electrics.values.radio_state = 0
		electrics.values.radio_volume = math.max(self.userVolume, 0.05) -- Ensure min. volume when on

		print("[Bug:Radio] State: On (No power)")
		guihooks.message({txt = "Radio: On (No power)", context = {}}, 4, "bug.radio")

		self:updateVolume(0)
	else
		electrics.values.radio_state = 0
		electrics.values.radio_volume = 0

		print("[Bug:Radio] State: Off")
		guihooks.message({txt = "Radio: Off", context = {}}, 4, "bug.radio")

		self:updateVolume(0)
	end

	if self.workerCoroutine ~= nil then
		print("[Bug:Radio] Loading stations. Please wait...")
		guihooks.message({txt = "Radio: Loading stations. Please wait...", context = {}}, 4, "bug.radio")
	end
end

function Radio:unloadStations()
	for _, s in pairs(self.stations) do
		s.speaker:load(nil)
	end
	if #self.stations > 0 then 
		print("[Bug:Radio] All stations unloaded.")
	end
end

function Radio:getFileInfo(file)
	local dir, name, ext = path.splitWithoutExt(file)

	local f = {}
	f.path = file
	f.name = name
	f.ext = ext
	f.dir = string.sub(dir, 1, #dir - 1)  -- remove trailing /

	-- Determine the radio frequency from the parent dir
	-- Expected format: /nnn.n name or /nnn.n-name or /nnn.n_name
	-- A '=' directly after the frequency plays all tracks in sequence.
	-- i.e "../97.5= K-DST/..."
	local a, b, c, d  = string.match(f.dir, "[/]([0-9][0-9][0-9]?)[.]([0-9])([=]?)[- _\t]*([^/]*)")
	f.station = {}
	f.station.shuffle = not c or c ~= "="
	f.station.name = d or ""
	f.frequency = a and b and a + (b / 10) or 0

	return f
end

function Radio:loadStations()
	if self.installed == false then return end

	self:setState(false)
	self.workerCoroutine = coroutine.create(function()
		return self:loadStationsTask()
	end)
end

function Radio:findModStations()
	local mods = {}

	local jbeamFiles = FS:findFiles(ModStationsFolder, "*.jbeam", -1, true, false)
	for _, filepath in pairs(jbeamFiles) do
		local fileData = jsonReadFile(filepath)
		if fileData then
			for partName, part in pairs(fileData) do
				if part.slotType == SlotTypeRadioStation then
					table.insert(mods, part.information)
				end
			end
		end
	end

	return mods
end

function Radio:updateWorker(dt)

	if self.workerCoroutine == nil then return end
	if coroutine.status(self.workerCoroutine) == "dead" then
		self.workerCoroutine = nil
		return
	end

	local ok, info = coroutine.resume(self.workerCoroutine)

	if ok and info then 
		if info.index then
			local msg = "Radio: Loading tracks ... "..string.format("%.0f%%", 100/info.count*info.index).."\nTrack "..info.index.."/"..info.count.. " "..tostring(#self.stations).." Stations"
			guihooks.message({txt = msg, context = {}}, 1, "bug.radio.loadstations")
		else
			local msg = "Radio: Loading completed\n" ..tostring(#self.stations).. " Stations, " ..(info.tracks).." Tracks "
			guihooks.message({txt = msg, context = {}}, 4, "bug.radio.loadstations")
		end
	end
end

function Radio:loadStationsTask()
	if self.installed == false then return end

	storage.suspend(true)
	media.cacheLoad(TracksCacheFile)

	-- Find local sound files ...
	local localFiles = FS:findFiles(LocalStationsFolder, '*.mp3\t*.wav', -1, true, false)
	-- Find mod stations jbeam files ...
	local modStations = self:findModStations()

	local trackCount = #localFiles + #modStations
	local trackIndex = 0
	local trackError = 0
	local updateTime = os.clock()
	local startTime = os.clock()

	local updateMsg = function()
		trackIndex = trackIndex + 1

		local t = os.clock() - updateTime
		-- at least 40fps (0.025 = 25ms)
		if t < 0.025 then return false end
		updateTime = os.clock()
		return true
	end

	self:unloadStations()
	self.stations = {}

	-- load local files ...
	for _, filepath in pairs(localFiles) do
		local data = self:addTrackLocal(filepath)
		if not data then trackError = trackError + 1 end

		if updateMsg() then
			if data and not data.cache then
				coroutine.yield({ index=trackIndex, count=trackCount })
			end
		end
	end

	-- load mod stations ...
	for _, partInformation in pairs(modStations) do
		self:addTrackMod(partInformation)

		if updateMsg() then
			coroutine.yield({ index=trackIndex, count=trackCount })
		end
	end

	table.sort(self.stations, function(a, b)
		return a.frequency < b.frequency
	end)

	log("D", "", "[Bug:Radio] Stations:")
	local presetIndex = 1
	for index, s in pairs(self.stations) do

		-- Shuffle tracks if enabled ...
		local shuffle = s:shuffleTracks()
		-- Set random track for each station ...
		s:setTrackRandom()
		-- Fill preset buttons with user defined and mod stations ...
		if not s.builtIn and self.presets[presetIndex] and not self.presets[presetIndex].user then
			self.presets[presetIndex].frequency = s.frequency
			presetIndex = presetIndex + 1
		end
		
		log("D", "", "[Bug:Radio]    " ..tostring(s.frequency).. "MHz '" ..s.name.. "'" .. (shuffle and " (randomized)" or ""))
		for i,track in pairs(s.tracks) do
			if #track.name > 0 then
				local m = i == s.trackIndex and " > " or "   "
				log("D", "", "[Bug:Radio]    " ..m.. "#" ..tostring(i).. " " ..media.toTimeStr(track.duration).. " '" ..track.name.. "' (" ..track.type.. ")")
			end
		end
	end

	for index, s in pairs(self.stations) do
		-- Fill rest of preset buttons with built in stations ...
		if s.builtIn and self.presets[presetIndex] and not self.presets[presetIndex].user then
			self.presets[presetIndex].frequency = s.frequency
			presetIndex = presetIndex + 1
		end
	end

	if self:findStation(self.frequency) then
		-- Set default station ...
		self:setStationRandom()
	end

	storage.suspend(false)
	media.cacheSave(TracksCacheFile)
	local totalTime = os.clock() - startTime

	print("[Bug:Radio] Loading stations completed in " ..media.toTimeStr(totalTime).. " (" ..tostring(#self.stations).. " Stations, " ..(trackCount-trackError).." Tracks)")
	return { time=totalTime, tracks=trackCount-trackError }
end

function Radio:station(index)
	return self.stations[index or self.stationIndex]
end

function Radio:findStation(freq)
	for i, s in pairs(self.stations) do
		if s:is(freq or self.frequency) then return i end
	end
	return 0
end

function Radio:addStation(freq, name, shuffle)
	local s = self:station(self:findStation(freq))
	if s then return s, false end

	s = Station:new(freq, name, shuffle)
	table.insert(self.stations, s)
	
	return s, true
end

function Radio:setStation(index)
	if self:station(index) then
		self.stationIndex = index
		self:setFrequency(self:station().frequency)
	end
end

function Radio:setStationRandom()
	math.randomseed(os.time())
	self:setStation(math.random(1, #self.stations))
end

function Radio:setFrequency(frequency)
	self.frequency = math.min(math.max(frequency or self.frequency, frequencyMin), frequencyMax)
	self:updateNeedle()
end

function Radio:randomFrequency(index)
	-- Using a fixed seed here, to have the stations on the same freuqencay 
	-- for everyone, when the same mods are installed.
	math.randomseed(0x627567) -- ASCII "bug"
	local f = 0
	for i = 1,(index or 1) do
		f = math.random(frequencyMin*10,frequencyMax*10)/10
	end
	return f
end

function Radio:nextEmptyFrequency()	
	for index = 1,100 do -- try 100 times ...
		local f = self:randomFrequency(index)
		if self:findStation(f) == 0 then return f end
	end
	return 0
end

function Radio:addTrack(frequency, stationName, shuffle, filepath, name, trackDuration, trackType)
	local s, isNew = self:addStation(frequency, stationName, shuffle)
	if s == nil then return nil, false end

	local track = {}
	track.path = filepath
	track.name = name or ""
	track.duration = trackDuration or 0
	track.type = trackType or "built-in"

	table.insert(s.tracks, track)

	return s, isNew
end

function Radio:addTrackMod(partInformation)
	local i = partInformation
	if not i then return end
	if not i.song then return end

	local s, isNew = self:addTrack(self:nextEmptyFrequency(), i.name, false, i.song, i.songName)
	if s and isNew then
		s.mod = true
		s.builtIn = i.builtIn or false
		s.volumeMod = i.volume or 1
	end
end

function Radio:addTrackLocal(filepath)
	local data = media.getAudioData(filepath)
	if data == nil or data.duration <= 0 then
		log("W", "", "[Bug:Radio] Unsupported file: " ..filepath)
		return nil
	end	-- unsupported file format

	-- Duration is determined when the file played first
	local file = self:getFileInfo(filepath)
	self:addTrack(file.frequency, file.station.name, file.station.shuffle, filepath, file.name, data.duration, data.type)

	return data
end

function Radio:tune(frequency)
	if not frequency then
		if not self:station() then return end
		self:setFrequency(self:station().frequency)
	end

	self:setFrequency(frequency)
	self.tuneDirection = 0
	self.tuneTimer = 0
	self.tuneNext = false
end

function Radio:tuneDown(value)
	if not self.tuneNext and self.tuneDirection > 0 then return end -- already tuning right
	if self.tuneDirection == 0 then self.tuneTimer = 0 end

	self.tuneNext = value == nil	
	self.tuneDirection = (value or 1) * -1	
end
function Radio:tuneUp(value)
	if not self.tuneNext and self.tuneDirection < 0 then return end -- already tuning left
	if self.tuneDirection == 0 then self.tuneTimer = 0 end

	self.tuneNext = value == nil
	self.tuneDirection = (value or 1)
end

function Radio:tunePreset(index)
	if not self.presets[index] or self.presets[index].frequency == 0 then return end
	self:updateButtons(index, false)
	self:tune(self.presets[index].frequency)
end

function Radio:setPreset(index)
	if not self.presets[index] then return end
	local s = self:station()
	self:updateButtons(index, true)
	self.presets[index].frequency = s and s.frequency or self.frequency
	self.presets[index].user = true
end

function Radio:prevTrack()
	local s = self:station()
	if s then s:setTrack(s.trackIndex - 1) end
end

function Radio:nextTrack()
	local s = self:station()
	if s then s:setTrack(s.trackIndex + 1) end
end

function Radio:setTrack(index)
	local s = self:station()
	if s then s:setTrack(index) end
end

function Radio:showInfo()
	local s = self:station()
	if s then s:showInfo() end
end

function Radio:volumeUp(value)
	if value ~= nil then
		self.userVolumeDirection = value
		return
	end

	if not self.state then
		self:setState(true)
		if self.userVolume >= 0.05 then return end
	end
	self:setVolume(self.userVolume + 0.05)
end

function Radio:volumeDown(value)
	if value ~= nil then
		self.userVolumeDirection = value * -1
		return
	end

	if not self.state then
		self:setState(true)
		return
	end

	-- NOTE: (Lua 5.1) When the volume is 0.1 and gets reduced further, the value might be 2.7755575615629e-17 or similar
	-- For unknown reason, "self.userVolume <= 0.05" returns (wrongly) false while with 0.0500001 it returns true.
	if self.userVolume <= 0.0500001 then
		self.userVolume = 0
		if noState then return end
		self:setState(false)
		return
	end
	self:setVolume(self.userVolume - 0.05)
end

function Radio:setVolume(value)
	if value then
		-- Min volume is 5% when turned on ...
		self.userVolume = math.min(math.max(value, self.state and 0.05 or 0), 1)
		
		electrics.values.radio_volume = self.userVolume
		
		local v = string.format("%.0f%%", self.userVolume * 100)
		print("[Bug:Radio] Volume " ..v.. " (" ..tostring(self.userVolume).. ")")

		guihooks.message({txt = "Radio: Volume "..v, context = {}}, 4, "bug.radio")
	end
end

function Radio:playKnobSFX(set)
	playSound("event:>Vehicle>Interior>Handbrake_Ratchet>Ratchet_05_Ratchet", self.nodeSFX, 0.15, 0.8)
	-- Alternative SFX:
	--playSound("event:>Vehicle>Interior>Handbrake_Ratchet>Ratchet_03_Ratchet", self.nodeSFX)
end

function Radio:playPresetSFX(set)
	playSound(not set and PresetUseSFX or PresetSetSFX, self.nodeSFX)
end

function Radio:playStateSFX()
	playSound(self.state and RadioOnSFX or RadioOffSFX, self.nodeSFX)
end

function Radio:volumeAtRangeDistance(volume, distance)
	local v =  volume / ((distance*0.6) + 1)
	v = math.min(math.max(v, 0.0), volume);  -- clamp
	--print("v: " .. volume .. " / d: " .. distance .. " = v: " .. v)
	return v
end

function Radio:interrupt(time)
	-- interrupt only when in "ON" state ...
	if self.state == false then return end
	self.interruptTime = time
end

function Radio:updateNeedle()
	electrics.values.radio_needle = 1 / (frequencyMax - frequencyMin) * (self.frequency - frequencyMin)
end

function Radio:updateButtons(index, set)
	index = index or 0
	set = set or false

	self.presetBtn = index * (not set and 1 or -1)
	self.presetBtnTimer = 0
	
	local b = math.abs(self.presetBtn)
	for i = 1,5 do
		if i == b then
			self:playPresetSFX(set)
			electrics.values["radio_buttons"..i] = not set and 1 or -1
		else 
			electrics.values["radio_buttons"..i] = 0
		end
	end
end

function Radio:updateControls(dt)
	if self.presetBtn ~= 0 then
		self.presetBtnTimer = self.presetBtnTimer + dt
		if (self.presetBtnTimer > 0.4) then
			self:updateButtons()
		end
	end

	-- Chaning volume?
	if self.userVolumeDirection ~= 0 then
		self:setVolume(self.userVolume + (0.05 * self.userVolumeDirection))
	end

	-- Tuning in either direction?
	if self.tuneDirection ~= 0 then
		self.tuneTimer = self.tuneTimer + dt

		local step = 0.05
		-- tune faster after 800ms ...
		if self.tuneTimer > 0.8 then step = 0.08 end
		-- tune ven more faster after 1100ms ...
		if self.tuneTimer > 1.6 then step = 0.11 end
		if self.tuneNext then step = 0.2 end

		self:setFrequency(self.frequency + (step * self.tuneDirection))
		self.tuning = true

	elseif self.tuning and self:isOn() then
		self.tuneTimer = self.tuneTimer + dt

		-- tune to best frequency for current station when not tuning for more then 1200ms
		if self.tuneTimer >= 1.2 then
			self.tuning = false
			self:tune() 
			return
		end
	end
end

function Radio:updateVolume(volume)
	volume = volume or self.volume	
	local station = self:station()
	
	-- Update station volume based on frequency match ...
	local match = 0 	-- 1 = 100%
	
	if station ~= nil then 
		match = station:match(self.frequency)
		station:setVolume(volume * match)
	end

	-- static SFX volume ...
	self.speaker:setVolume(volume * (match < 1 and 1 or 0))
end

function Radio:updateStations(dt)
	-- Update all station tracks ...
	for _, s in pairs(self.stations) do
		s:update(dt)
	end

	-- Frequency changed?
	if self.frequency == self.freqLast then
		self:updateVolume()
		return
	end

	print("[Bug:Radio] Frequency " .. tostring(self.frequency) .. " Mhz")
	self.freqLast = self.frequency
	local index = self:findStation()

	-- Station changed?
	if index ~= self.stationIndex then
		-- Mute previous station
		local s = self:station()
		if s then s:setVolume(0) end

		-- Select new station
		self.stationIndex = index

		if self.tuneNext then
			self:tune()
			self.freqLast = self.frequency
		end
	end

	self:updateVolume()

	local s = self:station()
	if s then
		s:showInfo()
	end
end

function Radio:updateRadio(dt)
	if self.installed == false then return end

	self:updateControls(dt)
	self:save()

	if self.state == false then return end
	if self.workerCoroutine then return end

	local lastPower = self.power
	self.power = electrics.values.ignitionLevel > 0

	if self.power == false then
		if lastPower then self:setState() end
		return
	end

	if self.power == false then return end
	if not lastPower then self:setState() end
	
	-- The camera position seems to "lag behind" when the ground speed increases.
	-- This is not perfect but the hundredths of the ground speed seems to negate the lag quiet well.
	local camFactor = obj:getGroundSpeed() / 100
	local camPos = vec3(obj:getCameraPosition())
	
	-- Determine speaker node, driver node and camera position ...
	local vehPos = vec3(obj:getPosition())
	local driverPos = vehPos + vec3(obj:getNodePosition(self.nodeDriver))
	local speakerPos = vehPos + vec3(obj:getNodePosition(self.speaker.nodeId))

	-- Determine the relative position of the camera and if it's on the left or right side of the vehicle
	local camDelta = (camPos - vehPos):normalized()
	local camRefX = camDelta:cross(obj:getDirectionVector()):normalized().z

	local distance = (camPos:distance(vehPos) - camFactor)
	-- When the distance from the "driver" camera to the player camera
	-- is 0.6 or less, the interior sound filter is active.
	local interior = (camPos:distance(driverPos) - camFactor) < 0.6

	-- Determine cam side in %
	local camL = clamp((1.0/-1.2) * camRefX + 0.6, 0, 1)
	local camR = clamp((1.0/1.2) * camRefX + 0.6, 0, 1)

	-- Determine how much open in % the car is depending on the cam position
	-- When the car is open on one side, its at least 20% open at the closed side.
	local oL = math.max(0.2, camL) * (electrics.values["vehicleopenL"] or 0)
	local oR = math.max(0.2, camR) * (electrics.values["vehicleopenR"] or 0)
	local open = clamp(oL + oR, 0, 1)
	open = (open*1.3)/(open+0.3)	-- Apply open curve. (See also "vehicle.lua" line 180)

	local volumeModifier = self.defaultVolumeModifier

	-- Outside the "interior" sphere and interior only mode
	if interior == false and self.interiorOnly then
		local delta = self.exteriorClosedVolumeModifier - self.exteriorOpenVolumeModifier
		delta = delta * math.abs(1 - open)

		volumeModifier = self.exteriorOpenVolumeModifier + delta
	end

	if output3D then
		self.volume = self.volume3D * volumeModifier * self.userVolume
	else
		self.volume = self.volume2D * volumeModifier * self.userVolume
	end

	local s = self:station()
	if s then self.volume = self.volume * (s.volumeMod or 1) end

	if interior == true or self.interiorOnly then
		self.volume = self:volumeAtRangeDistance(self.volume, distance)
	end

	-- Simulate radio interrupt on engine start ...
	if not lastPower or electrics.values.ignitionLevel == 3 then
		self:interrupt(0.5)
	end

	self.ignitionLevel = electrics.values.ignitionLevel
	if (self.softstate == false) then return end

	-- Handle interrupts ...
	if self.interruptTime > 0 then
		self.interruptTime = self.interruptTime - dt
		self.volume = 0
	end
	if self.interruptTime < 0 then self.interruptTime = 0 end

	self:updateStations(dt)

	-- What is color and texture for?
	--obj:setVolumePitchCT(radioSongLoop, volume, 1, 0, 0.8)
end

function Radio:update(dt)	
	self:updateWorker(dt)

	self.updateTimer = self.updateTimer + dt
	-- update every rate: 15 fps (0.066 == 66ms)
	if self.updateTimer > 0.066 then
		self:updateRadio(self.updateTimer)
		self.updateTimer = 0
	end
end

-- Local ---------------------------------------------

local function onInit()
	radio = Radio:new()
	radio:initalize()
end

local function onReset()
	-- interrupt the radio for 1 second on vehicle reset ...
	radio:interrupt(1)
end

local function updateGFX(dt)
	radio:update(dt)
end

local function toggle() radio:toggleState() end
local function unload() radio:unloadStations() end
local function load() radio:loadStations() end
local function info() radio:showInfo() end
local function reset() radio:reset() end

local function volume(volume) radio:setVolume(volume) end
local function prevTrack() radio:prevTrack() end
local function nextTrack() radio:nextTrack() end
local function setTrack(index) radio:setTrack(index) end

local function tune(frequency) radio:tune(frequency) end
local function tuneDown(value) radio:tuneDown(value) end
local function tuneUp(value) radio:tuneUp(value) end
local function tunePreset(index) radio:tunePreset(index) end
local function setPreset(index) radio:setPreset(index) end

local function volumeDown(value) radio:volumeDown(value) end
local function volumeUp(value) radio:volumeUp(value) end

local function setState(enabled) radio:setState(enabled) end

-- public interface
M.onInit       = onInit
M.onReset      = onReset
M.updateGFX    = updateGFX

M.toggle       = toggle
M.setState     = setState
M.unload       = unload
M.load         = load
M.info         = info
M.reset        = reset

M.volume       = volume
M.prevTrack    = prevTrack
M.nextTrack    = nextTrack
M.setTrack     = setTrack

M.tune         = tune
M.tuneDown     = tuneDown
M.tuneUp       = tuneUp
M.tunePreset   = tunePreset
M.setPreset    = setPreset

M.volumeDown   = volumeDown
M.volumeUp     = volumeUp

return M
