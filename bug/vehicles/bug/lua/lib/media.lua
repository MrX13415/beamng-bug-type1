-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Library to determine the track duration of various audio files.
-- Supported formats: WAV, MP3, OGG, OPUS, FLAC
-- v1.1	
-- by MrX13415 (2026-05-04)

-- Please give credit when using this :)

-- 1.1	Add support for OGG, OPUS and FLAC files.


local M = {}


--------------------------------------------------
-- Cache

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
	local cache = jsonReadFile(path)
	if not cache then
		cacheA = {}
		return false
	end

	cacheA = cache 
	log("D", "", "[Bug:Media] Cache loaded")
	return true
end

local function cacheSave(path)
	log("D", "", "[Bug:Media] Cache Saved")
	return jsonWriteFile(path, cacheB, true)
end


--------------------------------------------------
-- Common

-- Max 4 bytes
local function numberLE(bytes, index, count)
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
-- Max 4 bytes
local function numberBE(bytes, index, count)
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

local function shortLE(bytes, index) return numberLE(bytes, index, 2) end
local function intLE(bytes, index) return numberLE(bytes, index, 4) end
local function int24LE(bytes, index) return numberLE(bytes, index, 3) end

local function shortBE(bytes, index) return numberBE(bytes, index, 2) end
local function intBE(bytes, index) return numberBE(bytes, index, 4) end
local function int24BE(bytes, index) return numberBE(bytes, index, 3) end


local function str(bytes, index, count)
	local i = index or 1
	local c = i + (count or 1) -1
	return bytes:sub(i, c)
end

local mt = getmetatable("")
mt.__index["numberLE"] = numberLE
mt.__index["shortLE"]  = shortLE
mt.__index["int24LE"]  = int24LE
mt.__index["intLE"]    = intLE
mt.__index["numberBE"] = numberBE
mt.__index["shortBE"]  = shortBE
mt.__index["int24BE"]  = int24BE
mt.__index["intBE"]    = intBE
mt.__index["str"]      = str


--------------------------------------------------
-- WAV

local function waveChunk(stream)
	local bytes = stream:read(8)

	local chunk = {}
	chunk.id = bytes:str(1, 4)
	chunk.size = bytes:intLE(5)
	return chunk
end

local function readWave(stream, data)
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

local function decodeSyncSafe(v)
	-- Google for "mp3 safe sync integer"
	return bit.band(v, 0x7F) + bit.rshift(bit.band(v, 0x7F00), 1) + bit.rshift(bit.band(v, 0x7F0000), 2) + bit.rshift(bit.band(v, 0x7F000000), 3)
end

local function mp3FindFrameOffset(bytes, offset)
	for o=(offset or 0),#bytes-4 do -- a frame has at least 4 bytes
		-- Find frame sync bytes indicating a frame section: Check 11 bits, 0x7FF
		if bytes:byte(o+1) ~= 0xFF or bit.band(bytes:byte(o+2), 0xE0) ~= 0xE0 then 
		else
			return o
		end
	end
	return -1
end

local function mp3Frame(bytes, offset)
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

local function readMP3(stream, data)
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
				estimated = true
			end
		end

		deltaTime = os.clock() - startTime
	until(frame == nil or deltaTime > 0.4)	-- Timeout after 1000ms

	-- Timed out. A big file?
	if frame then
		data.duration = estimatedDuration
		data.estimated = true

		log('W', 'media', "[Bug:Media] MP3 reading has timed out ("..(deltaTime*1000).."ms). Is the file corrupted? Using estimated duration. (" ..data.size.." bytes , " ..data.file.. ")")
	end

	return data
end


--------------------------------------------------
-- OGG

local oggHeaderType = {
 [0x01] = "Continuation",
 [0x02] = "BeginOfStream",
 [0x04] = "EndOfStream"
}

local function oggSetupHeader(self)
	if not self:IsSetupHeader() then return nil end

	local setup = {}
	setup.version = self.data:intLE(8)
	setup.channels = self.data:byte(12)
	setup.samplerate = self.data:intLE(13)
	-- ... more fields available, but not needed for duration calculation

	return setup
end
local function oggCommentHeader(self)
	if not self:IsCommentHeader() then return nil end
	
	local comments = {}
	local vendorLength = self.data:intLE(8)
	local vendorString = self.data:sub(12, 12 + vendorLength -1)

	local commentListLength = self.data:intLE(12 + vendorLength)
	local offset = 12 + vendorLength + 4
	for i=1, commentListLength do
		local commentLength = self.data:intLE(offset)
		local commentString = self.data:sub(offset + 4, offset + 4 + commentLength -1)
		offset = offset + 4 + commentLength
		table.insert(comments, commentString)
	end

	return comments
end

local function oggPage(bytes, offset)
	if not bytes then return nil end

	local page = {}

	page.magic = bytes:str(offset, 4)		-- "OggS"
	if page.magic ~= "OggS" then return nil end

	page.version = bytes:byte(offset+4)		-- u8
	
	local headerFlags = bytes:byte(offset+5)
	page.headerType = {}
	page.headerType.Continuation = (bit.band(headerFlags, 0x01) > 0)
	page.headerType.BeginOfStream = (bit.band(headerFlags, 0x02) > 0)
	page.headerType.EndOfStream = (bit.band(headerFlags, 0x04) > 0)

	page.granulePosition = bytes:intLE(offset+6)			-- u64
	page.bitstreamSerialNumber = bytes:intLE(offset+14)		-- u32
	page.pageSequenceNumber = bytes:intLE(offset+18)		-- u32
	page.checksum = bytes:intLE(offset+22)					-- u32
	
	page.pageSegments = bytes:byte(offset+26)				-- u8
	page.segmentTable = {}
	for i=1, page.pageSegments do
		page.segmentTable[i] = bytes:byte(offset+26+i)		-- u8
	end

	-- read raw data segments
	local dataSegments = {}
	local dataOffset = offset + 27 + page.pageSegments
	for i=1, page.pageSegments do
		dataSegments[i] = bytes:sub(dataOffset, dataOffset + page.segmentTable[i] - 1)	-- SegmentData
		dataOffset = dataOffset + page.segmentTable[i]
	end

	-- reconstruct packets from segments
	page.packets = {}	
	local packetData = {}
	
	for i = 1, page.pageSegments do
		local seg = dataSegments[i]
		table.insert(packetData, seg)

		-- packet end
		if #seg < 255 or i == page.pageSegments then
			local packet = {}
			packet.data = table.concat(packetData)
			
			-- Setup helper functions to identify packet types
			packet.IsSetupHeader 	= function(self) return self.data:byte(1) == 0x01 and self.data:sub(2, 7) == "vorbis" end
			packet.IsCommentHeader 	= function(self) return self.data:byte(1) == 0x03 and self.data:sub(2, 7) == "vorbis" end
			packet.IsAudioHeader 	= function(self) return self.data:byte(1) == 0x05 and self.data:sub(2, 7) == "vorbis" end
			
			table.insert(page.packets, packet)
			packetData = {}
		end
	end
	
	page.size = 27 + page.pageSegments + dataOffset - (offset + 27 + page.pageSegments)	-- Total size of page
	return page
end

local function readOGG(stream, data)
	stream:seek("set", 0) -- go to file begin
	
	-- Read and verify OGG header
	local bytes = stream:read(10)
	if bytes:str(1, 4) ~= "OggS" then return nil end
	stream:seek("set", 0) -- go back begin
	
	data.type = "ogg"
	data.duration = 0
	data.estimated = false

	local totalFrameSize = data.size - stream:seek()	
	local startTime = os.clock()
	local deltaTime = 0

	local page = nil
	local init = false

	local setup = nil
	local comments = {}
	local granulePosition = 0

	bytes = stream:read(1024*1024)
	local block = 1
	local size = 0
	local offset = 1
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
		page = oggPage(bytes, offset)

		--log("D","", ">> Block #"..tostring(block).." b "..tostring(bytes and #bytes or 0) .. " o "..tostring(offset) .." s "..tostring(size) .. " = " .. tostring((bytes and #bytes or 0) - (offset + size)) .. " " .. tostring(page))

		if page then
			init = true
			size = page.size

			granulePosition = math.max(granulePosition, page.granulePosition)

			for i=1, #page.packets do
				local packet = page.packets[i]

				if packet:IsSetupHeader() then
				 	setup = oggSetupHeader(packet)
				elseif packet:IsCommentHeader() then
					table.insert(comments, oggCommentHeader(packet))
				end
			end
		end

		deltaTime = os.clock() - startTime
	until(page == nil or deltaTime > 0.4)	-- Timeout after 1000ms

	-- Determine duration from granule position and sample rate
	if granulePosition > 0 then
		data.duration = granulePosition / (setup and setup.samplerate or 44100)	-- in seconds
		data.estimated = true
	end

	if setup then
		log("D","media", "            Setup: version " ..tostring(setup.version).. " channels " ..tostring(setup.channels).. " samplerate " ..tostring(setup.samplerate))
	end
	for i=1, #comments do
		log("D","media", "            Comment: #" .. tostring(i) .. ": " .. tostring(table.concat(comments[i], ", ")))
	end

	-- Timed out. A big file?
	if page then
		log('W', 'media', "[Bug:Media] OGG reading has timed out ("..(deltaTime*1000).."ms). Is the file corrupted? Using estimated duration. (" ..data.size.." bytes , " ..data.file.. ")")
	end

	return data
end


--------------------------------------------------
-- FLAC

local flacBlockTypes = {
 [0] = "StreamInfo",
 [1] = "Padding",
 [2] = "Application",
 [3] = "SeekTable",
 [4] = "VorbisComment",
 [5] = "CueSheet",
 [6] = "Picture"
}

local function flacMetadataBlock(bytes, offset)
	if not bytes then return nil end

	-- header is 4 bytes long
	local block = {}
	local idbyte = bytes:byte(offset)
	block.lastBlock = (bit.band(idbyte, 0x80) > 0)	-- 1 bit
	block.type = bit.band(idbyte, 0x7F)				-- 7 bits
	block.size = 4 + bytes:int24BE(offset+1)		-- 24 bits
	--log("D","", "FLAC Metadata Block: type " .. tostring(block.type) .. " (" .. tostring(flacBlockTypes[block.type] or "unknown") .. ") size: " .. tostring(block.size) .. " bytes, last: " .. tostring(block.lastBlock) .. ")")

	if block.lastBlock then return block end

	if block.type == 0 then	-- StreamInfo
		block.streaminfo = {}

		-- The minimum and maximum block size (in samples) used in the stream.
		-- (Minimum blocksize == maximum blocksize) implies a fixed-blocksize stream.
		block.streaminfo.minBlockSize = bytes:shortBE(offset+4)		-- 16 bits
		block.streaminfo.maxBlockSize = bytes:shortBE(offset+6)		-- 16 bits

		-- The minimum and maximum frame size (in bytes) used in the stream. May be 0 to imply the  value is not known.
		block.streaminfo.minFrameSize = bytes:int24BE(offset+8)		-- 24 bits
		block.streaminfo.maxFrameSize = bytes:int24BE(offset+11)	-- 24 bits

		-- Note: Lua's bit library is limited to 32-bit operations, so we need to read
		-- the 64-bit value as two separate 32-bit values to avoid losing the upper bits
		local flagsHigh = bytes:intBE(offset+14)		-- First 32 bits
		local flagsLow = bytes:intBE(offset+18)			-- Last 32 bits

        -- Sample rate in Hz. Though 20 bits are available, the maximum sample rate is limited 
		-- by the structure of frame headers to 655350Hz. Also, a value of 0 is invalid.
		-- The sample rate occupies bits 0-19 (top 20 bits) of the high 32-bit word
		block.streaminfo.sampleRate 	= bit.rshift(flagsHigh, 12)		-- 20 bits (shift right by 12 to get top 20 bits of 32-bit value)
		
		-- Number of channels. FLAC supports from 1 to 8 channels
		-- Channels occupy bits 20-22, which are bits 9-11 in the high word (after the 20-bit sample rate)
		block.streaminfo.channels 		= bit.rshift(bit.band(flagsHigh, 0x00000E00), 9) + 1	-- 3 bits
		
		-- Bits per sample. FLAC supports from 4 to 32 bits per sample. 
		--Currently the reference encoder and decoders only support up to 24 bits per sample.
		-- Bits per sample occupy bits 23-27, which are bits 4-8 in the high word
		block.streaminfo.bitsPerSample 	= bit.rshift(bit.band(flagsHigh, 0x000001F0), 4) + 1	-- 5 bits
		
		-- Total samples in stream. 'Samples' means inter-channel sample, i.e. one second of 44.1Khz 
		-- audio will have 44100 samples regardless of the number of channels. A value of zero here 
		-- means the number of total samples is unknown.
		-- Total samples occupy bits 28-63 (36 bits total): 4 bits from high word + all 32 bits from low word
		local totalSamplesHigh = bit.band(flagsHigh, 0x0000000F)	-- Lower 4 bits of high word
		block.streaminfo.totalSamples 	= totalSamplesHigh * 0x100000000 + flagsLow		-- Combine: (high << 32) + low
		
		-- MD5 signature of the unencoded audiodata. This allows the decoder todetermine if an error 
		-- exists in the audio data even when the error does not result in an invalid bitstream.
		-- MD5 signature: offset+34, 16 bytes long

		--log("D","media", "            StreamInfo: minBlockSize " .. tostring(block.streaminfo.minBlockSize) .. " samples, maxBlockSize " .. tostring(block.streaminfo.maxBlockSize) .. " samples, minFrameSize " .. tostring(block.streaminfo.minFrameSize) .. " bytes, maxFrameSize " .. tostring(block.streaminfo.maxFrameSize) .. " bytes, sampleRate " .. tostring(block.streaminfo.sampleRate) .. " Hz, channels " .. tostring(block.streaminfo.channels) .. ", bitsPerSample " .. tostring(block.streaminfo.bitsPerSample) .. ", totalSamples " .. tostring(block.streaminfo.totalSamples))

		-- Calculate duration from total samples and sample rate
        block.streaminfo.duration = block.streaminfo.totalSamples / block.streaminfo.sampleRate	-- in seconds
	end

	return block
end

local function readFLAC(stream, data)
	stream:seek("set", 0) -- go to file begin
	
	-- Read and verify FLAC header
	local bytes = stream:read(4)
	if bytes:str(1, 4) ~= "fLaC" then return nil end
	
	data.type = "flac"
	data.duration = 0
	data.estimated = false

	local totalFrameSize = data.size - stream:seek()	
	local startTime = os.clock()
	local deltaTime = 0

	local metadata = nil
	local init = false

	bytes = stream:read(1024*1024)
	local block = 1
	local size = 0
	local offset = 1
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
		-- read next metadata ...
		metadata = flacMetadataBlock(bytes, offset)

		--log("D","", ">> Block #"..tostring(block).." b "..tostring(bytes and #bytes or 0) .. " o "..tostring(offset) .." s "..tostring(size) .. " = " .. tostring((bytes and #bytes or 0) - (offset + size)) .. " " .. tostring(page))

		if metadata then
			init = true
			size = metadata.size

			if metadata.streaminfo then
				data.duration = metadata.streaminfo.duration
				data.estimated = true
				metadata = nil	-- We have all needed information, stop reading further metadata blocks ...
			end
		end

		deltaTime = os.clock() - startTime
	until(metadata == nil or deltaTime > 0.4)	-- Timeout after 1000ms

	-- Timed out. A big file?
	if metadata then
		log('W', 'media', "[Bug:Media] FLAC reading has timed out ("..(deltaTime*1000).."ms). Is the file corrupted? Using estimated duration. (" ..data.size.." bytes , " ..data.file.. ")")
	end

	return data
end


--------------------------------------------------
-- Common

local formats = {
	{ ext = "wav" , read = readWave },
	{ ext = "mp3" , read = readMP3 },
	{ ext = "ogg" , read = readOGG },
	{ ext = "opus", read = readOGG },
	{ ext = "flac", read = readFLAC }
}

local function getFormatFilter()
	local filter = ""
	for i=1, #formats do
		filter = filter .. "*." .. formats[i].ext .. "\t"
	end
	return filter
end

local function readAudioData(stream, file)
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
		--log("D","media", "[Bug:Media] Cache hit: " .. tostring(data.duration) .. "s for " ..  tostring(file))
		return data
	end

	stream:seek("set", 0) -- go to file begin

	for i=1, #formats do
		local format = formats[i]
		if ext == format.ext then
			data = format.read(stream, data)
			-- if data then  log("D","media", "[Bug:Media] Read: " .. tostring(data.duration) .. "s for " ..  tostring(file))
			-- else          log("W","media", "[Bug:Media] Failed to read media file: " .. tostring(file))  end
			return data
		end
	end

	return nil
end

--------------------------------------------------
-- Public

local function toTimeStr(seconds)
	if seconds < 1 then
		return string.format("%dms", seconds*1000)
	end

	local h = math.floor(seconds / 60 / 60)
	local m = math.floor(seconds / 60 - h*60)
	local s = math.floor(seconds - h*60*60 - m*60)
	return h > 0 and string.format("%d:%02d:%02d", h, m, s) or string.format("%d:%02d", m, s) 
end

local function getAudioData(file)
	if not file then return nil end
	if not FS:fileExists(file) then return nil end

	-- Note: file and path related functions can't handle multiple dots (..)
	--       i.e. "Myfile...mp3" won't be found!

	local stream = io.open(file, "rb")
	if not stream then return nil end
	local data = readAudioData(stream, file)
	stream:close()
	if data then cacheSet(data) end

	return data
end

M.toTimeStr         = toTimeStr
M.getAudioData      = getAudioData
M.getFormatFilter   = getFormatFilter

M.cacheLoad         = cacheLoad
M.cacheSave         = cacheSave

return M

