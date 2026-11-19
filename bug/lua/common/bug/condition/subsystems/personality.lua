-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Car condition subsystem: the car's personality. Plain Lua, see bug/condition/core.lua.
--
-- Conditions (saved):
--   trust   how much the car trusts the player, TRUST_MIN … TRUST_MAX. Earned and lost by the personality script
--           (vehicles/bug/lua/hrb/hrb.lua: crashes, jumps, drifts …), which reads and writes it here.
--
-- Only cars with the personality part have this subsystem (REQUIRES_PART; the glue adds it only then), so only
-- their records have the slice. Names in here stay neutral: the lore-free build rewrites lore words in string
-- literals but doesn't rename files.

local M = {}

M.name = "personality"
M.REQUIRES_PART = "bug_hrb_personality"

M.TRUST_DEFAULT = 0
M.TRUST_MAX = 500
M.TRUST_MIN = -150

function M.defaults(cfg)
  return { trust = M.TRUST_DEFAULT }
end

function M.clampTrust(state)
  state.trust = math.max(M.TRUST_MIN, math.min(M.TRUST_MAX, state.trust or M.TRUST_DEFAULT))
  return state.trust
end

function M.load(saved, cfg)
  local state = M.defaults(cfg)
  if type(saved) == "table" and type(saved.trust) == "number" then state.trust = saved.trust end
  M.clampTrust(state)
  return state
end

function M.diagnostics(state)
  return { trust = state.trust }
end

return M
