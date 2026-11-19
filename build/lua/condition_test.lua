-- Runs the car condition model outside the game (it must not need any game API).
-- From the repo root:  luajit build/lua/condition_test.lua   (plain lua 5.1 works too)

package.path = "bug/lua/common/?.lua;" .. package.path

local core = require("bug/condition/core")
local battery = require("bug/condition/subsystems/battery")

local failed = 0
local function check(name, ok, detail)
  print((ok and "ok   " or "FAIL ") .. name .. (detail and ("  (" .. detail .. ")") or ""))
  if not ok then failed = failed + 1 end
end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-9) end

-- battery: 30 days at 20 °C → 3 % self-discharge (closed form: exp(-0.03))
do
  local m = core.new({ cfg = { startBattery = 1 } }):add(battery)
  m:offline(30 * 86400, { tempC = 20 })
  check("battery 30 d at 20 °C", near(m:state("battery").charge, math.exp(-0.03)), m:state("battery").charge)

  local warm = core.new({ cfg = { startBattery = 1 } }):add(battery)
  warm:offline(30 * 86400, { tempC = 30 })
  check("battery doubles per 10 K", near(warm:state("battery").charge, math.exp(-0.06)), warm:state("battery").charge)
end

-- save / load round trip
do
  local a = core.new({ cfg = { startBattery = 0.8 } }):add(battery)
  a:offline(86400, { tempC = 15 })
  local b = core.new({ cfg = { startBattery = 1 } }):add(battery)
  b:load(a:save())
  check("save / load", near(a:state("battery").charge, b:state("battery").charge))
end

-- battery: shown ↔ stored charge, start charge, load and setCharge clamp
do
  local okRound = true
  for i = 0, 20 do
    local x = i / 20
    if not near(battery.shownFromCharge(battery.chargeFromShown(x)), x, 1e-12) then okRound = false end
  end
  check("battery: shown ↔ stored round trip", okRound)
  check("battery: half shown is more than half stored", battery.chargeFromShown(0.5) > 0.7)
  local m = core.new({ cfg = { startBattery = 0.3 } }):add(battery)
  check("battery: new car starts at the shown start charge",
    near(battery.shownFromCharge(m:state("battery").charge), 0.3, 1e-12))
  local m2 = core.new({ cfg = { startBattery = 1 } }):add(battery)
  m2:load({ subsystems = { battery = { charge = 0.42 } } })
  check("battery: saved charge wins over the start charge", m2:state("battery").charge == 0.42)
  m2:load({ subsystems = { battery = { charge = 7 } } })
  check("battery: saved charge clamped", m2:state("battery").charge == 1)
  battery.setCharge(m2:state("battery"), -3)
  check("battery: setCharge clamped", m2:state("battery").charge == 0)
  m2:state("battery").charge = 0.5
  m2:reset()
  check("battery: reset keeps the charge", m2:state("battery").charge == 0.5)
end

-- battery: a load left on drains it while the car stands
do
  local cfg = { startBattery = 1, batteryCapacityAh = 77, batteryVoltage = 12 }
  local function stood(loadW, hours)
    local m = core.new({ cfg = cfg }):add(battery)
    m:state("battery").standbyLoadW = loadW
    m:offline(hours * 3600, { tempC = 20 })
    return m:state("battery").charge
  end
  local sd = stood(0, 10)
  check("battery: no load = self-discharge only", near(sd, math.exp(-battery.selfDischargeRate(20) * 36000), 1e-12))
  local expected = 1 - 40 * 10 / (12 * 77)          -- 40 W for 10 h of 924 Wh (self-discharge is tiny here)
  check("battery: ignition left on 10 h", near(stood(40, 10), expected, 0.002), stood(40, 10))
  check("battery: left on long enough → empty, not below", stood(40, 100) == 0)
  local noSize = core.new({ cfg = { startBattery = 1 } }):add(battery)
  noSize:state("battery").standbyLoadW = 40
  noSize:offline(36000, { tempC = 20 })
  check("battery: unknown battery size → load ignored", near(noSize:state("battery").charge, sd, 1e-12))

  -- smoothing: a 2 Hz blinking 42 W signal settles near its average; saves only on real changes
  local st = battery.defaults(cfg)
  local saves = 0
  for i = 1, 60 * 20 do
    local on = math.floor(i / 15) % 2 == 0
    if battery.setStandbyLoad(st, on and 42 or 0, 1 / 60) then saves = saves + 1 end
  end
  check("battery: blinking load ≈ its average", math.abs(st.standbyLoadW - 21) < 4, st.standbyLoadW)
  check("battery: blinking load asks for few saves", saves <= 6, saves)
  check("battery: standby load saved, noted value not",
    battery.save(st).standbyLoadW == st.standbyLoadW and battery.save(st).standbyLoadNotedW == nil)
end

-- random streams: same seed and name → same numbers; different name → different numbers; in (0, 1)
do
  local m1, m2 = core.new({ seed = 42 }), core.new({ seed = 42 })
  local same, inRange = true, true
  for _ = 1, 1000 do
    local x, y = m1:random("faults"), m2:random("faults")
    if x ~= y then same = false end
    if x <= 0 or x >= 1 then inRange = false end
  end
  check("random: reproducible", same)
  check("random: in (0, 1)", inRange)
  check("random: streams differ", core.new({ seed = 42 }):random("a") ~= core.new({ seed = 42 }):random("b"))
end

-- fixed tick: the number of ticks depends on the time, not on how it is split into frames
do
  local ticksA, ticksB = 0, 0
  local subA = { name = "count", update = function() ticksA = ticksA + 1 end }
  local subB = { name = "count", update = function() ticksB = ticksB + 1 end }
  local a, b = core.new():add(subA), core.new():add(subB)
  for _ = 1, 600 do a:update(1 / 60) end   -- 10 s at 60 fps
  for _ = 1, 250 do b:update(1 / 25) end   -- 10 s at 25 fps
  check("fixed tick independent of frame rate", math.abs(ticksA - ticksB) <= 1 and math.abs(ticksA - 100) <= 1,
    ticksA .. " / " .. ticksB)
end

-- effects: merge rules, unknown keys refused
do
  local effects = require("bug/condition/effects")
  local out = {}
  effects.add(out, "idleRpmAdd", 100); effects.add(out, "idleRpmAdd", -30)
  effects.add(out, "ignitionCut", false); effects.add(out, "ignitionCut", true)
  check("effects: add rule", out.idleRpmAdd == 70)
  check("effects: or rule", out.ignitionCut == true)
  check("effects: unknown key refused", not pcall(effects.add, out, "noSuchEffect", 1))
  -- apply writes only into the engine table it is given
  local engine = { idleAV = 0, ignitionCoef = 1, setIgnition = function(self, v) self.ignitionCoef = v end }
  effects.apply({ idleRpmAdd = -150 }, engine, { idleRPM = 850 })
  check("effects: idle speed applied", near(engine.idleAV, 700 * math.pi / 30), engine.idleAV)
  check("effects: no cut without ignitionCut", engine.ignitionCoef == 1)
  effects.apply({ ignitionCut = true }, engine, { idleRPM = 850 })
  check("effects: ignitionCut stops the engine", engine.ignitionCoef == 0)
end

-- carburettor: the idle screw is a saved condition, clamped, and drives idleRpmAdd
do
  local carb = require("bug/condition/subsystems/carburettor")
  local m = core.new():add(carb)
  local st = m:state("carburettor")
  carb.turnIdleScrew(st, 1)
  check("carb: 1 turn = 120 rpm", m:effects().idleRpmAdd == 120)
  carb.turnIdleScrew(st, -100)
  check("carb: screw clamped", st.idleScrewTurns == carb.IDLE_SCREW_MIN)
  local m2 = core.new():add(carb)
  m2:load(m:save())
  check("carb: screw saved", m2:state("carburettor").idleScrewTurns == carb.IDLE_SCREW_MIN)
end

-- carburettor: the throttle lever follows the cable open at once, springs back to the idle stop when let go
-- (bouncing a little, not at once), a hand holds it, and none of it is saved
do
  local carb = require("bug/condition/subsystems/carburettor")
  local m = core.new():add(carb)
  local st = m:state("carburettor")
  check("lever: follows the cable open at once", carb.stepLever(st, 1 / 60, 1) == 1)
  local bounced, last, peak = false, 1, 0
  local closedAt = nil
  for i = 1, 240 do                                    -- 1 s in small frames, so the bounce shows
    local x = carb.stepLever(st, 1 / 240, 0)
    if x > last then bounced = true; peak = math.max(peak, x) end
    last = x
    if not closedAt and x < 0.02 then closedAt = i end
  end
  check("lever: not back in the same frame", carb.stepLever(core.new():add(carb):state("carburettor"), 0, 0) == 0
    and closedAt and closedAt >= 10, closedAt and closedAt / 240)
  check("lever: back on the stop within 0.25 s", closedAt and closedAt <= 60, closedAt and closedAt / 240)
  check("lever: bounces off the stop, a little", bounced and peak < 0.15, peak)
  check("lever: comes to rest on the stop", st.lever == 0 and st.leverVel == 0)
  -- the same in big and small frames
  local a, b = core.new():add(carb):state("carburettor"), core.new():add(carb):state("carburettor")
  carb.stepLever(a, 0, 1); carb.stepLever(b, 0, 1)
  for _ = 1, 6 do carb.stepLever(a, 1 / 120, 0) end
  for _ = 1, 2 do carb.stepLever(b, 1 / 40, 0) end
  check("lever: independent of the frame rate", near(a.lever, b.lever, 1e-9), a.lever .. " / " .. b.lever)
  carb.setHand(st, 0.4)
  check("lever: a hand holds it open", carb.stepLever(st, 1 / 60, 0) == 0.4)
  carb.setHand(st, 2)
  check("lever: hand clamped", carb.stepLever(st, 1 / 60, 0) == 1)
  check("lever: not saved", m:save().subsystems.carburettor.lever == nil and m:save().subsystems.carburettor.hand == nil)
  m:reset()
  check("lever: reset lets go", st.hand == nil and st.lever == 0)
end

-- idle: stalls only a running engine below the stall speed without throttle; other conditions raise the stall speed
do
  local carb = require("bug/condition/subsystems/carburettor")
  local idle = require("bug/condition/subsystems/idle")
  local function run(m, rpm, seconds, extra)
    local cut = false
    for _ = 1, math.floor(seconds * 60) do
      local inputs = { rpm = rpm, throttle = 0, oilTempC = 90, engineTempC = 90, ignitionOn = not cut, cranking = false }
      for k, v in pairs(extra or {}) do inputs[k] = v end
      m:update(1 / 60, inputs)
      if m.fx.ignitionCut then cut = true end
    end
    return cut
  end
  local function fresh() return core.new():add(carb):add(idle) end

  local m = fresh()
  check("idle: healthy idle never stalls", not run(m, 850, 10))
  check("idle: drops to 420 rpm → stall", run(m, 420, 2))
  local m2 = fresh()
  check("idle: not running yet → no stall (key on, engine off)", not run(m2, 0, 3))
  local m3 = fresh(); run(m3, 850, 2)
  check("idle: throttle prevents the stall", not run(m3, 420, 3, { throttle = 0.2 }))
  local m4 = fresh(); run(m4, 850, 2)
  check("idle: 520 rpm warm is fine", not run(m4, 520, 5))
  local m5 = fresh(); run(m5, 850, 2)
  check("idle: 520 rpm cold (0 °C oil) stalls", run(m5, 520, 3, { oilTempC = 0, engineTempC = 0 }))
  local m6 = fresh(); m6:state("carburettor").idleJetClog = 1; run(m6, 850, 2)
  check("idle: clogged idle jet (condition) raises the stall speed", run(m6, 700, 3))
  check("idle: live state not saved", m6:save().subsystems.idle == nil)
  m6:state("idle").belowTime = 0.5
  m6:reset()
  check("idle: reset clears live state", m6:state("idle").belowTime == 0 and m6:state("carburettor").idleJetClog == 1)
end

-- choke cover: the ring's screws loosen and tighten within their range, the cover only turns while all three are
-- loose, both are saved and clamped on load
do
  local carb = require("bug/condition/subsystems/carburettor")
  local m = core.new():add(carb)
  local st = m:state("carburettor")
  check("choke: screws tight on a new car", st.chokeScrews.top == 0 and st.chokeScrews.left == 0 and st.chokeScrews.right == 0)
  check("choke: a tight screw can't go further in", not carb.turnChokeScrew(st, "top", -0.125))
  check("choke: unknown screw", not carb.turnChokeScrew(st, "middle", 1))
  check("choke: cover clamped while tight", not carb.turnChokeCover(st, 1) and st.chokeCoverDeg == 0)
  carb.turnChokeScrew(st, "top", 1); carb.turnChokeScrew(st, "left", 1)
  check("choke: cover clamped with one screw tight", not carb.turnChokeCover(st, 1))
  carb.turnChokeScrew(st, "right", 0.5)
  check("choke: cover turns with all three loose", carb.turnChokeCover(st, 3) and st.chokeCoverDeg == 3)
  carb.turnChokeCover(st, 100)
  check("choke: cover stops at its range", st.chokeCoverDeg == carb.CHOKE_COVER_MAX)
  carb.turnChokeScrew(st, "left", 100)
  check("choke: screw stops at its range", st.chokeScrews.left == carb.CHOKE_SCREW_MAX)
  local m2 = core.new():add(carb)
  m2:load(m:save())
  local s2 = m2:state("carburettor")
  check("choke: saved", s2.chokeCoverDeg == carb.CHOKE_COVER_MAX and s2.chokeScrews.top == 1 and s2.chokeScrews.right == 0.5)
  m2:load({ subsystems = { carburettor = { chokeCoverDeg = -99, chokeScrews = { top = 9, left = -2 } } } })
  s2 = m2:state("carburettor")
  check("choke: clamped on load", s2.chokeCoverDeg == -carb.CHOKE_COVER_MAX and s2.chokeScrews.top == carb.CHOKE_SCREW_MAX
    and s2.chokeScrews.left == 0 and s2.chokeScrews.right == 0)
end

-- retaining ring: no play while the screws are snug; a loose screw lets it lift at that screw, never past the head;
-- it drops only when all three are loose; it rattles while the engine runs
do
  local carb = require("bug/condition/subsystems/carburettor")
  local st = core.new():add(carb):state("carburettor")
  local lift, drop = carb.ringPose(st)
  check("ring: tight, no play", lift.top == 0 and lift.left == 0 and lift.right == 0 and drop == 0)
  carb.turnChokeScrew(st, "top", 2)
  lift, drop = carb.ringPose(st)
  check("ring: lifts at the loose screw only", lift.top > 0 and lift.left == 0 and lift.right == 0 and drop == 0)
  carb.turnChokeScrew(st, "left", 2); carb.turnChokeScrew(st, "right", 2)
  local maxLift, moved, before = 0, false, nil
  for _ = 1, 300 do
    carb.stepRing(st, 1 / 60, 1)
    lift, drop = carb.ringPose(st)
    maxLift = math.max(maxLift, lift.top, lift.left, lift.right)
    if before and before ~= lift.top then moved = true end
    before = lift.top
  end
  check("ring: never past the screw heads", maxLift <= carb.screwPlay(st, "top") + 1e-12, maxLift)
  check("ring: rattles while the engine runs", moved)
  check("ring: drops with all three loose", near(drop, carb.RING_HOLE_PLAY))
  carb.stepRing(st, 1 / 60, 0)
  local a = carb.ringPose(st).top
  carb.stepRing(st, 1 / 60, 0)
  check("ring: rests with the engine off", near(a, carb.ringPose(st).top) and near(a, carb.screwPlay(st, "top") * carb.RING_REST))
  -- a cover turn only twitches it: a small step that settles back to rest without swinging past it
  local rest = carb.screwPlay(st, "top") * carb.RING_REST
  carb.turnChokeCover(st, 1)
  carb.stepRing(st, 0, 0)
  local first = carb.ringPose(st).top
  local swung, last = false, first
  for _ = 1, 60 do
    carb.stepRing(st, 1 / 60, 0)
    local now = carb.ringPose(st).top
    if now < rest - 1e-12 or now > last + 1e-12 then swung = true end
    last = now
  end
  check("ring: cover turn twitches it a little", first > rest and first - rest <= carb.screwPlay(st, "top") * 0.1,
    string.format("%.3f mm", (first - rest) * 1000))
  check("ring: twitch settles without swinging", not swung and near(last, rest, 1e-6))
end

-- automatic choke: shut when cold, opens as the heater warms it, the cover shifts that; fast idle follows the flap;
-- a lean setting raises the stall speed on a cold engine
do
  local carb = require("bug/condition/subsystems/carburettor")
  local function run(m, seconds, oil)
    for _ = 1, math.floor(seconds * 10) do m:update(0.1, { oilTempC = oil, engineTempC = oil, ignitionOn = true, rpm = 900 }) end
  end
  local m = core.new():add(carb)
  local st = m:state("carburettor")
  run(m, 0.1, 10)
  check("choke: shut on a cold engine", near(carb.chokeClosure(st), 1, 0.01), carb.chokeClosure(st))
  check("choke: fast idle on a cold engine", m.fx.idleRpmAdd >= carb.FAST_IDLE_RPM - 5, m.fx.idleRpmAdd)
  run(m, 300, 20)
  check("choke: open after 5 min with the ignition on", carb.chokeClosure(st) == 0, st.chokeTempC)
  check("choke: no fast idle once open", near(m.fx.idleRpmAdd, 0))
  local warm = core.new():add(carb)
  run(warm, 1, 90)
  check("choke: open on a warm engine", carb.chokeClosure(warm:state("carburettor")) == 0)
  check("choke: warm engine, no extra stall speed", near(warm.fx.stallRpmAdd, 0))

  local function at(cover, seconds)
    local mm = core.new():add(carb)
    mm:state("carburettor").chokeCoverDeg = cover
    run(mm, seconds, 15)
    return carb.chokeClosure(mm:state("carburettor")), mm.fx.stallRpmAdd
  end
  local factory, factoryStall = at(0, 60)
  local rich = at(carb.CHOKE_COVER_MAX, 60)
  local lean, leanStall = at(-carb.CHOKE_COVER_MAX, 60)
  check("choke: richer cover keeps the flap shut longer", rich > factory and factory > lean,
    string.format("%.2f / %.2f / %.2f", rich, factory, lean))
  check("choke: lean cover raises the cold stall speed", leanStall > factoryStall + 100,
    string.format("%.0f vs %.0f rpm", leanStall, factoryStall))
  m:reset()
  check("choke: reset forgets the bimetal temperature", st.chokeTempC == nil)
  check("choke: bimetal not saved", m:save().subsystems.carburettor.chokeTempC == nil)
end

-- personality: trust is a saved condition, clamped on load (also when a save has an out-of-range value)
do
  local personality = require("bug/condition/subsystems/personality")
  check("personality: needs its part", personality.REQUIRES_PART == "bug_hrb_personality")
  local m = core.new():add(personality)
  check("personality: default trust", m:state("personality").trust == personality.TRUST_DEFAULT)
  m:state("personality").trust = 321
  local m2 = core.new():add(personality)
  m2:load(m:save())
  check("personality: trust saved", m2:state("personality").trust == 321)
  local m3 = core.new():add(personality)
  m3:load({ subsystems = { personality = { trust = 99999 } } })
  check("personality: trust clamped on load", m3:state("personality").trust == personality.TRUST_MAX)
end

-- a model without a subsystem keeps that subsystem's saved slice (part removed for now) and saves it back; a model
-- never adds a slice for a subsystem it doesn't have
do
  local personality = require("bug/condition/subsystems/personality")
  local carb = require("bug/condition/subsystems/carburettor")
  local withPart = core.new():add(carb):add(personality)
  withPart:state("personality").trust = 123
  local without = core.new():add(carb)
  without:load(withPart:save())
  check("other slices: not a state", without:state("personality") == nil)
  local back = core.new():add(carb):add(personality)
  back:load(without:save())
  check("other slices: kept through a save", back:state("personality").trust == 123)
  check("other slices: none added", core.new():add(carb):save().subsystems.personality == nil)
end

print(failed == 0 and "all passed" or (failed .. " failed"))
os.exit(failed == 0 and 0 or 1)
