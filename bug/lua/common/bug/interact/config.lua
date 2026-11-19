-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- How the car's interactors behave: the one place to tune them for every part (plain Lua, required as
-- "bug/interact/config").
--
-- An interactor is something on the car the player can point at and use: a handle, a knob, the carburettor. Each
-- part lists its own in its jbeam (section "interactors", read by vehicles/bug/lua/lib/interactors.lua); the GE
-- extension bug_interact picks them with the cursor ray, shows their highlight shells and runs their action.
-- What is the same for all of them lives here.

local M = {}

-- how far along the cursor ray (from the camera) an interactor reacts, m, by where the camera is
M.reach = {
  seated  = 1.5,   -- driver / passenger camera
  onFoot  = 3,     -- walking (the game's own trigger distance on foot)
  outside = 8,     -- every other camera (orbit, chase, free, …)
}

-- the car tells GE how its interactors move (props) and which are available only while a camera is this close to
-- it (m from the vehicle's position); further away nothing is sent
M.watchDistance = 15

-- the highlight of a hovered interactor: its shell (<part>_highlight in the DAE) is shown with this opacity. Its
-- color and glow are the material's: bug_highlight in vehicles/bug/components/common/highlight.materials.json.
M.highlight = {
  alpha = 0.45,                 -- 0 = invisible … 1 = opaque
  -- pulsing: the opacity goes smoothly (sine) from alpha to pulse.alpha and back, hz times per second.
  -- enabled = false keeps it steady at alpha.
  pulse = {
    enabled = true,
    hz = 0.8,                   -- pulses per second (0.5 = one every 2 s)
    alpha = 0.18,               -- the other end of the pulse
  },
}

-- tooltip: the game's own trigger tooltip shows the interactor's action title, near the interactor's center
M.tooltip = true

return M
