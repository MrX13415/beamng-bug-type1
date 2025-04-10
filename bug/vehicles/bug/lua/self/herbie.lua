-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
--M.type = "auxiliary"

local playerTrustDefault = 0
local playerTrustMax = 500
local playerTrustMin = -150

local enabled = false
local herbieEngine = false
local power = nil

local playerTrust = playerTrustDefault
local trustDirection = 0
local herbieMood = ""
local emojiTimer = 0

local defaultTorqueGraph = {}
local minTorqueGraph = {}
local maxTorqueGraph = {}

local beamCount = 0
local curBrokenBeams = 0
local nilCheck = true
local c1_bB = nil --> treated as old
local c2_bB = nil --> treated as current
local c3_bB = nil --> in process
local c4_bB = nil --> in process

local vState = {}
vState.driving = false;
vState.steering = false;
vState.wheelie = false;

local steeringCooldown = 100 -- 7
local current_steering = 0
local noCrashCounter = 0
local hardCrashCounter = 0
local noCrashCheckpoint = 400 -- 28

local wheelieInput = 0
local wheelieTimer = 0

local wheelieCounter = 0
local wheelieAwardCounter = 0
local wheelieCheckpoint = 30 -- 2


local driftingCounter = 0
local driftingCheckpoint = 65 -- 3
local jumpingCounter = 0
local jumpingAwardSum = 0
local jumpingAwardCounter = 0
local jumpingCheckpoint = 10


-- common

function message(message)
	print("[Bug:Herbie] " .. message)
end

function round(num, numDecimalPlaces)
	local mult = 10^(numDecimalPlaces or 0)
	return math.floor(num * mult + 0.5) / mult
end

local function loadcvs(f)
	local state = 1
	local r = function ()
		if state == 1 then state = 2 return "return {" end
		if state == 2 then
			local l = f:read()
			if l then return "{ "..l.." }," else state = 3 return "}" end
		end
		if state == 3 then return nil end
	end
	return assert(load(r))()
end

function getNodeIDbyName(nodename)
	for i, node in pairs (v.data.nodes) do
		if node.name == nodename then
			nodeID = node.cid
		end
	end
	return nodeID
end


-- main

local function getTrustEmoji(s)
	s = s or 0

	if playerTrust < -100 then return "😡" end
	if playerTrust < -40 then return "😠" end

	if playerTrust < playerTrustDefault then
		if s == -3 then return "😵" end
		if s == -2 then return "😤" end
		if s == -1 then return "😑" end
		if s == 1 then return "😌" end
		if s == 2 then return "🙂" end
		return "😞"
	end

	if s == -3 then return "😱" end
	if s == -2 then return "😨" end
	if s == -1 then return "😯" end
	if s == 1 then return "😁" end
	if s == 2 then return "🤩" end

	if playerTrust >= 400 then return "🥰" end
	if playerTrust >= 330 then return "😊" end
	if playerTrust >= 100 then return "😄" end
	return "🙂"
end

local function hasPower() return electrics.values.ignitionLevel > 0 end
local function isEnabled() return enabled end
local function isHerbieEngine() return herbieEngine end
local function getPlayerTrust() return playerTrust end
local function IsExcited() return getPlayerTrust() >= 330 end
local function isAngry() return getPlayerTrust() <= -20 end
local function state() return vState end

local function beamCount()
	local i,beam
	for i, beam in pairs(v.data.beams) do
		obj:setBeamSpringDamp(beam.cid, beam.beamSpring or -1, beam.beamDamp or -1, beam.springExpansion or -1, beam.dampExpansion or -1)
	end
	
	--clear old cache
	beamCount = 0
	
	for k,beam in pairs(v.data.beams) do
		beamCount = beamCount + 1
	end
end

local function getBrakeEvents()
	local i,beam
	for i, beam in pairs (v.data.beams) do
		obj:setBeamSpringDamp(beam.cid, beam.beamSpring or -1, beam.beamDamp or -1, beam.springExpansion or -1, beam.dampExpansion or -1)
	end
	
	local brokenBeams = 0
	
	-- count broken beams
	for k,beam in pairs(v.data.beams) do
		if obj:beamIsBroken(beam.cid) then
			local node = v.data.nodes[beam.id1]

			local isHubCap = (beam.breakGroup ~= nil and string.find(tostring(beam.breakGroup), "hubcap")) or node.hubcapRadius ~= nil
			--print(tostring(beam.id1) .. " " .. tostring(beam.breakGroup) .. " " .. tostring(node.hubcapRadius) .. " isHubCap: " .. tostring(isHubCap))
			if not isHubCap then
				brokenBeams = brokenBeams + 1
			end
		end
	end
	
	
	-- build cache
	if c4_bB == nil then 
		c4_bB = brokenBeams
	
	elseif c3_bB == nil then
		c3_bB = c4_bB
		c4_bB = brokenBeams
		
	elseif c2_bB == nil then
		c2_bB = c3_bB
		c3_bB = c4_bB
		c4_bB = brokenBeams
	
	else
		c1_bB = c2_bB
		c2_bB = c3_bB
		c3_bB = c4_bB
		c4_bB = brokenBeams
	end
	
	-- do the maths
	if c1_bB ~= nil then
		curBrokenBeams = c2_bB - c1_bB
	else
		curBrokenBeams = 0
	end
end

local function loadCurrentTrust()
	local herbie = storage.data().herbie or {}
	playerTrust = herbie.trust or playerTrustDefault
end
local function writeCurrentTrust()
	local d = storage.data()
	d.herbie = {}
	d.herbie.trust = playerTrust
end


local function getMaxMinDefaultTorqueCurves()
	local graph_file = io.open("vehicles/bug/lua/self/data/dynamic_torque_graph.csv")
	local data = loadcvs(graph_file)
	
	for i,graph in pairs(data) do
		if i == 1 then
			maxTorqueGraph = graph
		elseif i == 3 then
			minTorqueGraph = graph
		else
			defaultTorqueGraph = graph
		end
	end

	-- TODO: This feature needs a rewrite to better archive the goal as since upate 0.30 there is an issue where engine just locks up.

	-- Amplify the original min torque curve by a factor of 3 because, 
	-- the friction of the engine is higher then it was before. 
	-- This prevents the engine to lock up when on min. trust.
	for i,v in pairs(minTorqueGraph) do
		minTorqueGraph[i] = minTorqueGraph[i] * 3
	end
	-- The default torque curve has the same issue, amplify it by a factor of 1.5.
	for i,v in pairs(defaultTorqueGraph) do
		defaultTorqueGraph[i] = defaultTorqueGraph[i] * 3
	end
end
local function createNewTorqueCurve()	
	writeCurrentTrust()
	
	local newTorqueCurve = {}
	
	local torqueAmplifier = 0.0
	
	if playerTrust >= playerTrustMax then
		torqueAmplifier = 1.0
		message("100% Trust (max)")
		
		newTorqueCurve = maxTorqueGraph
	
	elseif playerTrustMax > playerTrust and playerTrust > 0 then
		torqueAmplifier = playerTrust / playerTrustMax
		message(tostring(math.floor(torqueAmplifier * 100)) .. "% Trust")
		
		for i,_ in pairs(defaultTorqueGraph) do
			newTorqueCurve[i] = defaultTorqueGraph[i] + ((maxTorqueGraph[i] - defaultTorqueGraph[i]) * torqueAmplifier)
		end
		--dumpToFile("vehicles/bug/curves_cache/" .. tostring(torqueAmplifier * 100) .. ".json", newTorqueCurve)
		
	elseif playerTrustMin < playerTrust and playerTrust < 0 then
		torqueAmplifier = playerTrust / playerTrustMin
		message(tostring(math.floor(torqueAmplifier * -100)) .. "% Trust")
		
		for i,_ in pairs(defaultTorqueGraph) do
			newTorqueCurve[i] = defaultTorqueGraph[i] - ((defaultTorqueGraph[i] - minTorqueGraph[i]) * torqueAmplifier)
		end
		--dumpToFile("vehicles/bug/curves_cache/-" .. tostring(torqueAmplifier * 100) .. ".json", newTorqueCurve)
		
	elseif playerTrust <= playerTrustMin then
		torqueAmplifier = -1.0
		message("-100% Trust (min)")
		
		newTorqueCurve = minTorqueGraph
		
		-- limit playerTrust
		playerTrust = playerTrustMin
		
	else
		message("0% Trust (default)")
		newTorqueCurve = defaultTorqueGraph
	end
	
	return newTorqueCurve
end


local function setNewTorqueCurve()
	if not herbieEngine then return end

	local newTorqueCurve = createNewTorqueCurve()	
	local engine = powertrain.getDevice("mainEngine")
	
	--[[newTorqueList = {}
	newPowerList = {}
	for i, value in pairs(engine.torqueData.curves[engine.torqueData.finalCurveName].torque) do
		table.insert(newTorqueList, value * multiplier)
	end
	for i, value in pairs(engine.torqueData.curves[engine.torqueData.finalCurveName].power) do
		table.insert(newPowerList, value * multiplier)
	end
	
	engine.torqueData.curves[engine.torqueData.finalCurveName].torque = newTorqueList
	engine.torqueData.curves[engine.torqueData.finalCurveName].power = newPowerList
	
	engine:sendTorqueData(engine.torqueData.curves[engine.torqueData.finalCurveName])]]--

	local editTorqueList = engine.torqueCurve
	
	for i, value in pairs(editTorqueList) do
		if i == 0 then
			-- nothing
		else
			editTorqueList[i] = newTorqueCurve[i]
		end
	end
	
	engine.torqueCurve = editTorqueList	
end


local function setThermals()
	local engine = powertrain.getDevice("mainEngine")
	local temperature_midpoint = 100
	local temperature_lowpoint = 50
	local temperature_highpoint = 150
	
	if playerTrust > 0 then
		local substractor = (temperature_midpoint - temperature_lowpoint) * (playerTrust / playerTrustMax)
		engine.thermals.coolantTemperature = temperature_midpoint - substractor
		engine.thermals.oilTemperature = temperature_midpoint - substractor
	else
		local additor = (temperature_highpoint - temperature_midpoint) * (playerTrust / playerTrustMin)
		engine.thermals.coolantTemperature = temperature_midpoint + additor
		engine.thermals.oilTemperature = temperature_midpoint + additor
	end
end

local function eventMessage(name, trustDiff, severity, minor)
	-- Clamp min/max
	playerTrust = math.min(math.max(playerTrust, playerTrustMin), playerTrustMax)
	minor = minor or false

	local lastDirection = trustDirection
	local arrow = " "
	local emoji = getTrustEmoji()
	
	local m = "Event: "..tostring(name).." | Trust: "..tostring(playerTrust)
	if playerTrust >= playerTrustMax then 
		m = m .. " MAX"
	elseif playerTrust <= playerTrustMin then 
		m = m .. " MIN"
	else
		if trustDiff > 0 then 
			trustDirection = 1
			arrow = " ↑ "
			m = m .. " ( +"..tostring(trustDiff).." )" 
		end
		if trustDiff < 0 then 
			trustDirection = -1
			arrow = " ↓ "
			m = m .. " ( "..tostring(trustDiff).." )" 
		end
	end
	m = m .. " " .. emoji

	if herbieMood ~= emoji or lastDirection ~= trustDirection then
		emojiTimer = 10
	end

	local msg = "Trust" ..arrow..	"(" ..tostring(name).. ")"
	if emojiTimer > 0 then
		msg = getTrustEmoji(severity) .. " " .. msg
		minor = false
	end
	herbieMood = emoji

	if minor then return end
	guihooks.message({txt = "Herbie: " .. msg, context = {}}, 2, "herbie")
	message(m)
end

local function playerBehaviourValuation()
	local lastTrust = playerTrust

	-- sensor for time without crashing (while driving + steering) / intensity of crash
	getBrakeEvents()
	if curBrokenBeams < 3 then
		if vState.driving and vState.steering then
			noCrashCounter = noCrashCounter + 1
			hardCrashCounter = hardCrashCounter + 1
			if noCrashCounter >= noCrashCheckpoint then 
				if playerTrust < 0 then
					playerTrust = playerTrust + 4
					noCrashCounter = 0
					setNewTorqueCurve()
				else
					playerTrust = playerTrust + 2
					noCrashCounter = 0
					setNewTorqueCurve()
				end

				eventMessage("No crash", playerTrust-lastTrust, 1, true)
			end
		end
		
	elseif curBrokenBeams > 35 then
		if hardCrashCounter > 4 then
			playHornSound("bug_sadhorn2", 50, 0.8)
		end
		
		noCrashCounter = 0
		hardCrashCounter = 0
		if playerTrust > 5 then
			playerTrust = round(playerTrust * 0.1) - 30
		else
			playerTrust = round(playerTrust - curBrokenBeams * 2)
		end
		
		eventMessage("Hard crash", playerTrust-lastTrust, -3)
		setNewTorqueCurve()

	elseif curBrokenBeams < 18 then
		noCrashCounter = 0
		if curBrokenBeams > 5 then
			curBrokenBeams = round(curBrokenBeams * 1)
		end
		playerTrust = round(playerTrust - curBrokenBeams)

		eventMessage("Small crash", playerTrust-lastTrust, -1)
		setNewTorqueCurve()		

	else
		if hardCrashCounter > 4 then
			playHornSound("bug_sadhorn2",50, 1 - 0.0005 * math.abs((playerTrust - playerTrustMax)))
		end
		
		hardCrashCounter = 0
		noCrashCounter = 0
		playerTrust = round(playerTrust - curBrokenBeams * ((curBrokenBeams*4)/18))
		
		eventMessage("Medium crash", playerTrust-lastTrust, -2)
		setNewTorqueCurve()

	end
	
	-- sensor for wheelie time (while driving + steering)
	if vState.driving and vState.steering then
		if electrics.values.wheelie_state > 0.2 then
			wheelieCounter = wheelieCounter + 1
			if wheelieCounter >= wheelieCheckpoint then
				wheelieAwardCounter = wheelieAwardCounter + 1
				-- only 4 awards possible
				if wheelieAwardCounter < 5 then
					playerTrust = playerTrust + 1
					wheelieCounter = 0
					eventMessage("Wheelie", playerTrust-lastTrust, 1)
				end
				
			end
		else
			wheelieCounter = 0
			wheelieAwardCounter = 0
		end
	end
	
	-- sensor for drifting time (while steering)
	for wi, wd in pairs(wheels.wheels) do
		-- called for each wheel
		if wd.lastSlip > 3.0 then
			driftingCounter = driftingCounter + 1
			if driftingCounter >= driftingCheckpoint then
				playerTrust = playerTrust + 1
				driftingCounter = 0
				
				eventMessage("Drift", playerTrust-lastTrust, 1)
				setNewTorqueCurve()
			end
		else
			driftingCounter = 0
		end
	end
	
	-- sensor for jumping time
	if electrics.values.airspeed > 10 and electrics.values.wheelspeed > 0.1 then
		local inAir1 = false
		local inAir2 = false
		local inAir3 = false
		local inAir4 = false
		for wi, wd in pairs(wheels.wheels) do
			if wd.lastSlip == 0 and not inAir1 and not inAir2 and not inAir3 and not inAir4 then
				inAir1 = true
			elseif wd.lastSlip == 0 and inAir1 and not inAir2 and not inAir3 and not inAir4 then
				inAir2 = true
			elseif wd.lastSlip == 0 and inAir1 and inAir2 and not inAir3 and not inAir4 then
				inAir3 = true
			elseif wd.lastSlip == 0 and inAir1 and inAir2 and inAir3 and not inAir4 then
				inAir4 = true
			else
				inAir1 = false
				inAir2 = false
				inAir3 = false
				inAir4 = false
			end
		end
		if inAir1 and inAir2 and inAir3 and inAir4 then
			jumpingCounter = jumpingCounter + 1
			if jumpingCounter >= jumpingCheckpoint then
				jumpingAwardCounter = jumpingAwardCounter + 1
				-- only 15 awards possible
				if jumpingAwardCounter < 16 then
					if jumpingAwardCounter == 1 and noCrashCounter > 7 and hardCrashCounter > 30 then
						jumpingAwardSum = jumpingAwardSum + 7
						playerTrust = playerTrust + 7
					else
					jumpingAwardSum = jumpingAwardSum + jumpingAwardCounter
					playerTrust = playerTrust + jumpingAwardCounter
					end
					
					jumpingCounter = 0
					
					eventMessage("Jump", playerTrust-lastTrust, 2)
					setNewTorqueCurve()
				end
			end
		else
			jumpingAwardSum = 0
			jumpingCounter = 0
			jumpingAwardCounter = 0
		end
	end
end


local function checkIfJumpCheat(jumpingAwSum,jumpingAwCounter)
	if jumpingAwCounter > 0 then
		local lastTrust = playerTrust

		local jumpCheatCorrection = round(jumpingAwSum - (jumpingAwSum / jumpingAwCounter)) + 4
		playerTrust = playerTrust - jumpCheatCorrection

		eventMessage("Incomplete Jump", playerTrust-lastTrust, 0)
		setNewTorqueCurve()
	end
end

local function updateWheelie(dt)
	if electrics.values.wheelie_state > 0 then
		wheelieTimer = wheelieTimer + dt
		if wheelieTimer > 0.3 then -- hold wheelie for at least 300ms
			electrics.values.wheelie_state = wheelieInput
		end
	end
end

local function updateGFX(dt)
	updateWheelie(dt)

	if not enabled then return end
	if not playerInfo.firstPlayerSeated then return end

	-- Consider driving only after a certain speed
	vState.driving = false
	if electrics.values.wheelspeed > 2 then vState.driving = true end
	
	-- Check if steering
	if electrics.values.steering == current_steering then
		if steeringCooldown > 0 then
			steeringCooldown = steeringCooldown - 1
		else
			vState.steering = false
		end
	else
		vState.steering = true
		steeringCooldown = 100
	end

	playerBehaviourValuation()
	setThermals()

	if emojiTimer > 0 then
		emojiTimer = emojiTimer - dt
	end

	local _power = hasPower()
	if power ~= _power and _power == true then
		herbieMood = getTrustEmoji()
		guihooks.message({txt = "Herbie: " .. herbieMood, context = {}}, 2, "herbie")	
	end
	power = _power
end

local function onReset()
	electrics.values.wheelie_state = 0

	-- Is herbie?
	if not enabled then	return end

	loadCurrentTrust()
	getMaxMinDefaultTorqueCurves()
	setNewTorqueCurve()
	setThermals()
	checkIfJumpCheat(jumpingAwardSum, jumpingAwardCounter)
	
	jumpingAwardSum = 0
	jumpingAwardCounter = 0
end

local function onInit(jbeamData)
	enabled = false
	for _,part in pairs(v.data.activePartsData) do
		if part.partName == "bug_herbie_personality" then enabled = true end
		if part.partName == "bug_engine_1.8_herbie" then herbieEngine = true end
	end
	if not enabled then return end

	message("Herbie Personality Initialized")
	message("    herbie engine: " .. (herbieEngine and "Yes" or "No"))
end


local function init()
	--valid state?

	--getMaxMinDefaultTorqueCurves()
	--setNewTorqueCurve()
end

local function setTrust(value)
	value = math.min(math.max(value or playerTrustDefault, playerTrustMin), playerTrustMax)
	playerTrust = value
	writeCurrentTrust()
	onReset()
end

-- Open the console and switch the command focus to the current vehicle (using the drop-down on the left)
-- Enter "herbie.reset()" and hit execute.
local function resetTrust()
	set()
	message("Player trust reseted!")
	guihooks.message({txt = "Herbie: Trust reseted. " .. getTrustEmoji(), context = {}}, 2, "herbie")
end

local function setHappy()
	setTrust(playerTrustMax)
	guihooks.message({txt = "Herbie: " .. getTrustEmoji(), context = {}}, 2, "herbie")
end

local function wheelie(value)
	wheelieInput = value > 0 and 1 or 0	-- Ensure 1 or 0 only

	local wheelieState = electrics.values.wheelie_state or 0

	if wheelieState == 0 and wheelieInput == 1 then 
		wheelieTimer = 0
		electrics.values.wheelie_state = wheelieInput
	end
end

-- events
M.onInit    = onInit
M.onReset   = onReset
M.updateGFX = updateGFX
M.sendState = sendState

-- public interface
M.message        = message
M.hasPower       = hasPower
M.isEnabled      = isEnabled
M.isHerbieEngine = isHerbieEngine
M.getPlayerTrust = getPlayerTrust
M.IsExcited      = IsExcited
M.isAngry        = isAngry
M.state          = state

M.resetTrust = resetTrust
M.setTrust   = setTrust
M.setHappy   = setHappy
M.wheelie    = wheelie

return M
