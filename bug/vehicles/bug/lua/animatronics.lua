-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt


-- particleIDs:
-- 1,9: 					sparks
-- 2-6,8,81,18: 			dirt, mud, dust
-- 7: 						dark smoke
-- 13: 						black & white splinter
-- 16: 						pebble / stones
-- 17,81:					swirling dust
-- 20,24,60:				steam
-- 21:						swirling dirt & grass
-- 23:						swirling water
-- 25-31:					fire
-- 32-39:					smoke
-- 35-52:					swirling smoke
-- 63-67:					explosion
-- 68:						backfire
-- 70-72:					exhaust



local M = {}

local hoppTimer = 0
local hoppSleep = 0.4	-- Sleep for 400ms on init/reset
local hoppCount = math.random(3,10)		--
local hoppL = 0
local hoppR = 0
local hoppSoundTimer = 0
local hoppSoundTrashhold = 1
local horn_node = 0

local backfireHoppTimer = 0
local backfireHoppSleep = 0
local backfireHoppL = 0
local backfireHoppR = 0
local backfire_ticks = math.random(2,8)
local backfire_pause = math.random(15,50)
local backfire_wait = 0
local backfire_sound_played = false
local backfire_nodeL = {0, 0}
local backfire_nodeR = {0, 0}

-- MAIN

function playHornSound(soundname,volume,pitch)
	sounds.playSoundOnceAtNode(soundname, horn_node, volume, pitch, 0, 0)
end

local function excitedHopping(dt)
	-- Do hopping?
	local hopp = herbie.isEnabled() and herbie.getPlayerTrust() >= 330
	hopp = hopp and herbie.hasPower() and not herbie.state().driving

	if not hopp then 
		electrics.values.hoppFL = 0
		electrics.values.hoppFR = 0
		return
	end

	hoppSoundTimer = hoppSoundTimer + dt
	hoppTimer = hoppTimer + dt

	-- Hopp duration is quarter the current jump height.
	-- i.e. 80% hop height / 4 = 400ms duration
	if hoppTimer > (hoppL / 4) then electrics.values.hoppFL = 0 end
	if hoppTimer > (hoppR / 4) then electrics.values.hoppFR = 0 end

	-- Wait until next hopp ...
	if hoppTimer < hoppSleep then return end
	hoppTimer = 0

	-- play horn sound max once a second
	if hoppSoundTimer > hoppSoundTrashhold then
		if math.random(0,1) == 1 then playHornSound("bug_requesting1", 4, 1)
		else playHornSound("bug_requesting2", 4, 1) end
		hoppSoundTimer = 0
		hoppSoundTrashhold = math.random() + math.random(1,20)
	end

	-- next hopp ...
	hoppL = math.random(10,100) / 100				-- Random hopp height 10-100 %
	hoppR = math.random(10,100) / 100				-- Random hopp height 10-100 %

	hoppCount = hoppCount - 1
	if hoppCount <= 0 then							-- New hopp series.
		hoppCount = math.random(3,10)				-- Random number of hopps in the next series.
		hoppSleep = math.random(50,1000) / 100		-- Random delay before the next series starts. 0.5-10s
	else
		hoppSleep = math.random(20,200) / 100		-- Random delay between hopps in the same series. 0.2-2s
	end

	electrics.values.hoppFL = hoppL
	electrics.values.hoppFR = hoppR

	--herbie.message("Hopp (F): #" .. tostring(hoppCount) .. " | " .. tostring(hoppSleep) .. "s L: " ..tostring(hoppL*100).. "% " ..tostring(hoppL/4*1000).. "ms R: " ..tostring(hoppR*100).. "% " ..tostring(hoppR/4*1000).. "ms")
end

local function excitedBurnouts()
end

local function angryHopping(dt)
	-- Do hopping?
	local hopp = herbie.isEnabled() and herbie.getPlayerTrust() <= -40
	hopp = hopp and herbie.hasPower()
	hopp = hopp and electrics.values.wheelspeed <= 7.2 and electrics.values.airspeed <= 7.2

	if not hopp then 
		electrics.values.hoppRL = 0
		electrics.values.hoppRR = 0
		return
	end

	backfireHoppTimer = backfireHoppTimer + dt

	-- Hopp duration is quarter the current jump height.
	-- i.e. 80% hop height / 4 = 400ms duration
	if backfireHoppTimer > (backfireHoppL / 4) then electrics.values.hoppRL = 0 end
	if backfireHoppTimer > (backfireHoppR / 4) then electrics.values.hoppRR = 0 end

	-- Wait until next hopp ...
	if backfireHoppTimer >= backfireHoppSleep then 
		backfireHoppTimer = 0
		
		backfireHoppL = math.random(40,100) / 100		-- Random hopp height 40-80 %
		backfireHoppR = math.random(40,100) / 100		-- Random hopp height 40-80 %
		
		backfireHoppSleep = math.random(20,80) / 100			-- Random delay between hopps in the same series. 0.2-0.8s
		
		electrics.values.hoppRL = backfireHoppL
		electrics.values.hoppRR = backfireHoppR

		--herbie.message("Hopp (R): " .. tostring(backfireHoppSleep) .. "s L: " ..tostring(backfireHoppL*100).. "% " ..tostring(backfireHoppL/4*1000).. "ms R: " ..tostring(backfireHoppR*100).. "% " ..tostring(backfireHoppR/4*1000).. "ms")
	end
end

local function angryBackfires(dt)
	-- Do backfires?
	local backfires = herbie.isEnabled() and herbie.getPlayerTrust() <= -40
	backfires = backfires and herbie.hasPower()
	backfires = backfires and electrics.values.wheelspeed <= 7.2 and electrics.values.airspeed <= 7.2

	if not backfires then return end

	if backfire_ticks > 0 then
		if backfire_ticks == 4 then
			-- small pause
			backfire_ticks = backfire_ticks - 1

		elseif backfire_wait > 0 then
			-- wait before explosion to sync with sound
			backfire_wait = backfire_wait - 1

		elseif not backfire_sound_played then
			local sfxCount = 7
			local soundIndex = math.random(1, sfxCount)

			local soundNode = backfire_nodeL[0]
			if math.random(1,2) == 2 then soundNode = backfire_nodeR[0] end

			sounds.playSoundOnceAtNode("bug_backfire"..tostring(soundIndex), soundNode, 4, 1-math.random(0,5)*0.01, 0, 0)
			if soundIndex == 4 then 
				sounds.playSoundOnceAtNode("bug_backfire1", soundNode, 4, 1-math.random(0,5)*0.01, 0, 0)
			end
			backfire_wait = soundIndex >= sfxCount and 10 or 0
						
			backfire_sound_played = true
		
		else
			local expl_force = 2*electrics.values.wheelspeed-10
			if expl_force >= 0 then
				--print(electrics.values.wheelspeed)
				expl_force = 10/(electrics.values.wheelspeed+1)
			end
			
			if math.abs(expl_force) >= 0.5 then
				if math.random(0,2) == 1 then
					--LEFT
					obj:addParticleByNodes(backfire_nodeL[0], backfire_nodeL[1], -math.abs(expl_force), 68, 0.01, 10)
					obj:addParticleByNodes(backfire_nodeL[0], backfire_nodeL[1], -4, 40, 0.01, 2)
					obj:addParticleByNodes(backfire_nodeL[0], backfire_nodeL[1], -math.abs(expl_force), 63, 0.05, 10)
					--obj:addParticleByNodes(backfire_nodeL[0], backfire_nodeL[1], -math.abs(expl_force), 64, 0.02, 10)
					--obj:addParticleByNodes(backfire_nodeL[0], backfire_nodeL[1], -math.abs(expl_force), 65, 0.02, 10)
				end
				if math.random(0,2) == 1 then 
					--RIGHT
					obj:addParticleByNodes(backfire_nodeR[0], backfire_nodeR[1], -math.abs(expl_force), 68, 0.01, 10)
					obj:addParticleByNodes(backfire_nodeR[0], backfire_nodeR[1], -4, 40, 0.2, 2)
					obj:addParticleByNodes(backfire_nodeR[0], backfire_nodeR[1], -math.abs(expl_force), 63, 0.05, 10)
					--obj:addParticleByNodes(backfire_nodeR[0], backfire_nodeR[1], -math.abs(expl_force), 64, 0.02, 10)
					--obj:addParticleByNodes(backfire_nodeR[0], backfire_nodeR[1], -math.abs(expl_force), 67, 0.02, 10)
				end
			end
			backfire_ticks = backfire_ticks - 1
		end
	
	elseif backfire_ticks < 1 and backfire_pause > 0 then
		backfire_pause = backfire_pause - 1
		
	else
		backfire_wait = 0
		backfire_sound_played = false
		backfire_ticks = math.random(3,10)
		backfire_pause = math.random(15,75) 
	end
end

local function onReset()
	hoppTimer = 0
	hoppSleep = 0.7	-- Sleep for 700ms on init/reset
	math.randomseed(os.time())
end	
	
local function updateGFX(dt)
	if not herbie.isEnabled() then return end

	excitedHopping(dt)
	angryHopping(dt)
	angryBackfires(dt)
end


local function onInit()
	math.randomseed(os.time())

	-- Init hopp sounds node
	horn_node = getNodeIDbyName("fb1")

	-- Init backfire nodes
	backfire_nodeL[0] = getNodeIDbyName("ex0l")
	backfire_nodeL[1] = getNodeIDbyName("ex1l")
	backfire_nodeR[0] = getNodeIDbyName("ex0r")
	backfire_nodeR[1] = getNodeIDbyName("ex1r")
end

-- public interface
M.onInit     = onInit
M.onReset    = onReset
M.updateGFX  = updateGFX

return M