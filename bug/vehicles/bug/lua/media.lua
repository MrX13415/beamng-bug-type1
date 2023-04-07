-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Library to determine the track duration of WAV and MP3 files.
-- v1.0
-- by MrX13415

-- Please give credit when using this :)


local M = {}


--------------------------------------------------
-- Cache

local cacheLoaded = false
local cacheA = {}
local cacheB = {}

local function cacheGet(data)
	if cacheA[data.file] == nil then return 0 end
	if cacheA[data.file].size ~= data.size then return 0 end
	if cacheA[data.file].duration <= 0 then return 0 end
	return cacheA[data.file].duration
end

local function cacheSet(data)
	if data == nil or data.duration <= 0 then return end 
	cacheB[data.file] = {}
	cacheB[data.file].size = data.size
	cacheB[data.file].duration = data.duration
end

local function cacheLoad(path)
	cacheA = jsonReadFile(path)
	log("D", "", "[Bug:Media] Cache loaded")
	cacheLoaded = true

	if cacheA ~= nil then return true end
	cacheA = {}
	return false
end

local function cacheSave(path)
	log("D", "", "[Bug:Media] Cache Saved")
	return jsonWriteFile(path, cacheB, true)
end


--------------------------------------------------
-- Common

function numberLE(bytes, index, count)
	if bytes == nil then return 0 end
	local i = index or 1
	local c = i + (count or 1) -1

	-- little endian, unsigned
	local v = 0
	for b=c,i,-1 do
		v = bit.lshift(v, 8) + bytes:byte(b)
	end
	return v
end

function numberBE(bytes, index, count)
	if bytes == nil then return 0 end
	local i = index or 1
	local c = i + (count or 1) -1

	-- big endian, unsigned
	local v = 0
	for b=i,c do
		v = bit.lshift(v, 8) + bytes:byte(b)
	end
	return v
end

function shortLE(bytes, index) return numberLE(bytes, index, 2) end
function intLE(bytes, index) return numberLE(bytes, index, 4) end

function shortBE(bytes, index) return numberBE(bytes, index, 2) end
function intBE(bytes, index) return numberBE(bytes, index, 4) end


function str(bytes, index, count)
	local i = index or 1
	local c = i + (count or 1) -1
	return bytes:sub(i, c)
end

local mt = getmetatable("")
mt.__index["numberLE"] = numberLE
mt.__index["shortLE"]  = shortLE
mt.__index["intLE"]    = intLE
mt.__index["numberBE"] = numberBE
mt.__index["shortBE"]  = shortBE
mt.__index["intBE"]    = intBE
mt.__index["str"]      = str


--------------------------------------------------
-- WAV

function waveChunk(stream)
	local bytes = stream:read(8)

	local chunk = {}
	chunk.id = bytes:str(1, 4)
	chunk.size = bytes:intLE(5)
	return chunk
end

function readWave(stream, data)
	stream:seek("set", 0) -- go to file begin

	local bytes = stream:read(12)

	-- Verify RIFF header
	if bytes:str(1, 4) ~= "RIFF" then return nil end
	-- byte 5-8: ContentLength
	if bytes:str(9, 4) ~= "WAVE" then return nil end

	data.type = "wav"
	data.duration = 0

	local channels = 0
	local samplerate = 0
	local bits = 0
	local samples = 0

	-- Read all chunks ...
	local ok = 0
	while(ok < 2)
	do
		local c = waveChunk(stream)
		if c.id == nil then break end

		--log("D","", "   Chunck: " .. c.id .. " size: " .. tostring(c.size))
		
		if c.id == "fmt " then
			bytes = stream:read(16)

			-- byte 1-2: compression
			channels = bytes:shortLE(3)
			samplerate = bytes:intLE(5)
			-- byte 9-12: avgBytesPerSec
			-- byte 13-14: blockAlign
			bits =  bytes:shortLE(15)

			c.size = c.size - 16 -- 16 bytes already read
			ok = ok + 1
		end
		
		if c.id == "data" then
			samples = c.size
			ok = ok + 1
		end

		-- All needed informations found, abort reading ...
		if ok >= 2 then break end

		-- Skip to next chunk ...
		stream:seek("cur", c.size)
	end

	data.duration = samples / (samplerate * channels * bits / 8) -- in seconds

	--print(tostring(channels).. " channel, "  ..tostring(bits).. " bit, " ..tostring(samplerate).. " Hz")

	return data
end


--------------------------------------------------
-- MP3

local mp3Versions = {
 [0] = 25,	-- 2.5
 [1] = 0,	-- reserved
 [2] = 20,  -- 2.0
 [3] = 10,  -- 1.0
}
local mp3Layers = {
 [0] = 0,	-- reserved
 [1] = 3,	-- Layer III
 [2] = 2,	-- Layer II
 [3] = 1,	-- Layer I
}
local mp3Bitrates = {
 [11] = { 0,32,64,96,128,160,192,224,256,288,320,352,384,416,448 }, -- V1L1
 [12] = { 0,32,48,56, 64, 80, 96,112,128,160,192,224,256,320,384 }, -- V1L2
 [13] = { 0,32,40,48, 56, 64, 80, 96,112,128,160,192,224,256,320 }, -- V1L3
 [21] = { 0,32,48,56, 64, 80, 96,112,128,144,160,176,192,224,256 }, -- V2L1
 [22] = { 0, 8,16,24, 32, 40, 48, 56, 64, 80, 96,112,128,144,160 }, -- V2L2
 [23] = { 0, 8,16,24, 32, 40, 48, 56, 64, 80, 96,112,128,144,160 }  -- V2L3
}
local mp3Samplerates = {
 [10] = { 44100,48000,32000 },
 [20] = { 22050,24000,16000 },
 [25] = { 11025,12000, 8000 }
}
local mp3Samples = {
	[10] = { [1] = 384, [2] = 1152, [3] = 1152, }, -- MPEGv1,     Layers 1,2,3
	[20] = { [1] = 384, [2] = 1152, [3] =  576, }  -- MPEGv2/2.5, Layers 1,2,3
}

function decodeSyncSafe(v)
	-- Google for "mp3 safe sync integer"
	return bit.band(v, 0x7F) + bit.rshift(bit.band(v, 0x7F00), 1) + bit.rshift(bit.band(v, 0x7F0000), 2) + bit.rshift(bit.band(v, 0x7F000000), 3)
end

function mp3FindFrameOffset(bytes, offset)
	for o=(offset or 0),#bytes-4 do -- a frame has at least 4 bytes
		-- Find frame sync bytes indicating a frame section: Check 11 bits, 0x7FF
		if bytes:byte(o+1) ~= 0xFF or bit.band(bytes:byte(o+2), 0xE0) ~= 0xE0 then 
		else
			return o
		end
	end
	return -1
end

function mp3Frame(bytes, offset)
	if not bytes then return nil end

	-- find next frame on current offset ...
	local o = mp3FindFrameOffset(bytes, offset)
	if o < 0 then return nil end
	
	local frame = {}
	local flags
	
	-- The frame header is 4 bytes long

	-- Read the last 5 bits of byte 2 ...
	flags = bit.band(bytes:byte(o+2), 0x1F)
	local version = mp3Versions[ bit.rshift(bit.band(flags, 0x18), 3) ]		-- MPEG Audio version ID
	local layer = mp3Layers[ bit.rshift(bit.band(flags, 0x06), 1) ] 		-- MPEG Layer
	local protectionBit = bit.band(flags, 0x01)

	local majorVer = version > 10 and 20 or 10

	flags = bytes:byte(o+3)
	frame.bitrate = mp3Bitrates[ majorVer + layer ]
	frame.bitrate = frame.bitrate and frame.bitrate[ bit.rshift(bit.band(flags, 0xF0), 4) +1 ] or 0

	frame.samplerate = mp3Samplerates[ version ]
	frame.samplerate = frame.samplerate and frame.samplerate[ bit.rshift(bit.band(flags, 0x0C), 2) +1 ] or 0
	
	local paddingBit = bit.rshift(bit.band(flags, 0x02), 1)
	
	-- byte o+4: Channel Mode
	
	-- Calculate frame size ...
	local padding = 0
	frame.size = 0
	if layer == 1 then -- Layer I
		if paddingBit == 1 then padding = 4 end
		frame.size = math.floor( ((12 * frame.bitrate * 1000 / frame.samplerate) + padding) * 4 )
	else	-- Layer II, Layer III
		if paddingBit == 1 then padding = 1 end
		frame.size = math.floor( ((144 * frame.bitrate * 1000) / frame.samplerate) + padding )
	end
	
	if frame.size == 0 then
		frame.error = "size"
		return nil
	end

	frame.samples = mp3Samples[ majorVer ]
	frame.samples = frame.samples and frame.samples[ layer ] or 0

	frame.duration = (frame.samplerate > 0 and frame.samples > 0) and (frame.samples / frame.samplerate) or 0

	--print("v" ..tostring(version).. " layer " ..tostring(layer).. " " ..tostring(frame.samplerate).. " Hz " ..tostring(frame.bitrate).. " kbit (protection:" ..tostring(protectionBit).. " padding:"..tostring(paddingBit).. ")")	
	--print("duration: " ..tostring(frame.duration).. " (size: " ..tostring(frame.size).. " samples: " ..tostring(frame.samples).. ")")

	return frame
end

function readMP3(stream, data)
	stream:seek("set", 0) -- go to file begin
	
	-- Read and skip ID3v2 header
	local bytes = stream:read(10)
	if bytes:str(1, 3) == "ID3" then
		-- byte 4-5: Version
		local flags = bytes:byte(6)
		local flagFooterPresent = bit.band(flags, 0x10) > 0
		local tagSize = decodeSyncSafe(bytes:intBE(7))
		--log("D", "", "TagSize: " .. tagSize)

		stream:seek("cur", tagSize)	-- Skip Tag
		if flagFooterPresent then stream:seek("cur", 10) end	-- Skip Footer
	else
		stream:seek("set", 0) -- go back begin
	end
	
	data.type = "mp3"
	data.duration = 0
	data.estimated = false

	local totalFrameSize = data.size - stream:seek()	
	local estimatedDuration = 0		-- For CBR files
	local estimated = false

	local startTime = os.clock()
	local deltaTime = 0

	local frame = nil
	local init = false

	bytes = stream:read(1024*1024)
	local block = 1
	local size = 0
	local offset = mp3FindFrameOffset(bytes)
	local lastOff = 0
	if offset < 0 then return nil end

	repeat
		-- end of current memory block reached ...
		if offset + size >= #bytes then
			local nextBlock = stream:read(1024*1024)
			
			local remaining = #bytes - offset
			if remaining > 0 then
				-- keep partial bytes from last block ...
				bytes = bytes:sub(#bytes-remaining+1, #bytes)
				if nextBlock then bytes = bytes .. nextBlock end
			else
				bytes = nil
			end

			offset = 0
			block = block + 1
		end
		
		-- go to next frame ...
		offset = offset + size
		-- read next frame ...
		frame = mp3Frame(bytes, offset)

		--log("D","", ">> Block #"..tostring(block).." b "..tostring(bytes and #bytes or 0) .. " o "..tostring(offset) .." s "..tostring(size) .. " = " .. tostring((bytes and #bytes or 0) - (offset + size)) .. " " .. tostring(frame))

		if frame then
			init = true
			size = frame.size

			data.duration = data.duration + frame.duration
		
			-- Calculate estimated duration (only works for CBR MP3)
			if not estimated then
				local kbps = (frame.bitrate*1000)/8
				estimatedDuration = totalFrameSize / kbps
				estimated = turned
			end
		end

		deltaTime = os.clock() - startTime
	until(frame == nil or deltaTime > 0.4)	-- Timeout after 1000ms

	-- Timed out. A big file?
	if frame then
		data.duration = estimatedDuration
		data.estimated = true

		log('W', 'media', "MP3 reading has timed out ("..(deltaTime*1000).."ms). Is the file corrupted? Using estimated duration. (" ..data.size.." bytes , " ..data.file.. ")")
	end

	return data
end


--------------------------------------------------
-- Common

function readAudioData(stream, file)
	local dir, name, ext = path.splitWithoutExt(file)

	local data = {}
	data.path = dir
	data.file = name.."."..ext
	data.type = ext
	data.size = stream:seek("end")	-- determine file size
	data.duration = 0
	data.cache = false

	data.duration = cacheGet(data)
	if data.duration > 0 then
		data.cache = true
		return data
	end
	
	stream:seek("set", 0) -- go to file begin

	if ext == "wav" then return readWave(stream, data) end
	if ext == "mp3" then return readMP3(stream, data) end
	return nil
end

--------------------------------------------------
-- Public

function toTimeStr(seconds)
	if seconds < 1 then
		return string.format("%dms", seconds*1000)
	end

	local h = math.floor(seconds / 60 / 60)
	local m = math.floor(seconds / 60 - h*60)
	local s = math.floor(seconds - h*60*60 - m*60)
	return h > 0 and string.format("%d:%02d:%02d", h, m, s) or string.format("%d:%02d", m, s) 
end

function getAudioData(file)
	if not file then return nil end
	if not FS:fileExists(file) then return nil end

	-- Note: file and path related functions can't handle multiple dots (..)
	--       i.e. "Myfile...mp3" won't be found!

	local stream = io.open(file, "rb")
	local data = readAudioData(stream, file)
	stream:close()

	if data then cacheSet(data) end

	return data
end

M.toTimeStr         = toTimeStr
M.getAudioData      = getAudioData

M.cacheLoad         = cacheLoad
M.cacheSave         = cacheSave

return M

