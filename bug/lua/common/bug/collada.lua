-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Reads meshes from the text of a Collada file (.dae), plain Lua (required as "bug/collada"; the caller reads the
-- file). Made for the mod's own DAEs as build/py/importdae.py writes them: a flat list of nodes, each with one
-- <matrix> and one <instance_geometry>, triangles only. Other files may not read correctly.
--
--   local meshes = collada.read(text, {carb_idle_screw_highlight = true})
--   meshes.carb_idle_screw_highlight = {
--     tris  = {x, y, z, x, y, z, x, y, z, …},  -- every triangle's three corners, the node's matrix applied (car
--                                              -- coordinates for the mod's meshes)
--     pivot = {x = …, y = …, z = …},           -- the node's origin (a prop turns about it)
--     box   = {x0, y0, z0, x1, y1, z1},        -- bounds of tris
--   }
-- Meshes that aren't in the file are missing from the result.

local M = {}

local function numbers(s)
  local t = {}
  for n in s:gmatch("%S+") do t[#t + 1] = tonumber(n) end
  return t
end

-- the text of the element <tag id="id" …> … </tag>
local function element(text, tag, id)
  local s = text:find("<" .. tag .. "[^>]-id=\"" .. id:gsub("%p", "%%%0") .. "\"")
  if not s then return nil end
  local e = text:find("</" .. tag .. ">", s, true)
  return e and text:sub(s, e - 1) or nil
end

local function floatArray(geo, sourceId)
  local src = element(geo, "source", sourceId)
  local arr = src and src:match("<float_array[^>]*>([^<]*)</float_array>")
  return arr and numbers(arr) or nil
end

-- triangles of one geometry: flat x, y, z per corner, in the mesh's own coordinates
local function geometryTris(geo)
  local vid = geo:match("<vertices[^>]-id=\"([^\"]+)\"")
  local vblock = vid and element(geo, "vertices", vid)
  local pid = vblock and vblock:match("semantic=\"POSITION\"[^>]-source=\"#([^\"]+)\"")
  if not pid then
    pid = vblock and vblock:match("source=\"#([^\"]+)\"[^>]-semantic=\"POSITION\"")
  end
  local pos = pid and floatArray(geo, pid)
  if not pos then return nil end
  local out = {}
  for body in geo:gmatch("<triangles[^>]*>(.-)</triangles>") do
    local stride, voff = 0, 0
    for input in body:gmatch("<input[^>]*>") do
      local off = tonumber(input:match("offset=\"(%d+)\"") or "0")
      if off + 1 > stride then stride = off + 1 end
      if input:find("semantic=\"VERTEX\"", 1, true) then voff = off end
    end
    local p = body:match("<p>([^<]*)</p>")
    if p then
      local idx = numbers(p)
      for k = 1, #idx, stride do
        local vi = idx[k + voff] * 3
        out[#out + 1] = pos[vi + 1]
        out[#out + 1] = pos[vi + 2]
        out[#out + 1] = pos[vi + 3]
      end
    end
  end
  return out
end

-- wanted: set of node names
function M.read(text, wanted)
  local result = {}
  for attrs, body in text:gmatch("<node([^>]*)>(.-)</node>") do
    local name = attrs:match("name=\"([^\"]+)\"")
    if name and wanted[name] then
      local m = numbers(body:match("<matrix[^>]*>([^<]*)</matrix>") or "1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1")
      local gid = body:match("<instance_geometry[^>]-url=\"#([^\"]+)\"")
      local geo = gid and element(text, "geometry", gid)
      local t = geo and geometryTris(geo)
      if t then
        local x0, y0, z0, x1, y1, z1 = math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge
        for i = 1, #t - 2, 3 do
          local x, y, z = t[i], t[i + 1], t[i + 2]
          x, y, z = m[1] * x + m[2] * y + m[3] * z + m[4], m[5] * x + m[6] * y + m[7] * z + m[8],
                    m[9] * x + m[10] * y + m[11] * z + m[12]
          t[i], t[i + 1], t[i + 2] = x, y, z
          if x < x0 then x0 = x end
          if y < y0 then y0 = y end
          if z < z0 then z0 = z end
          if x > x1 then x1 = x end
          if y > y1 then y1 = y end
          if z > z1 then z1 = z end
        end
        result[name] = {tris = t, pivot = {x = m[4], y = m[8], z = m[12]}, box = {x0, y0, z0, x1, y1, z1}}
      end
    end
  end
  return result
end

return M
