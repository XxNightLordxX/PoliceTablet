-- Small helpers shared by every module (CP.U). Pure Lua 5.4: no natives except where noted, so tests can load this
-- file directly.

CP = CP or {}
CP.U = CP.U or {}
local U = CP.U

-- ============================================================================
--                                   NUMBERS
-- ============================================================================
-- Round to the nearest whole number, halves up (2.5 -> 3, -2.5 -> -2). The 1e-7 nudge makes a true half
-- that binary floating point stores a hair below .5 still round up: $350 x 1.15 = 402.49999999999994
-- (really $402.50) -> 403, the same as CP.Cash pays. Every money and count rounding goes through this.
local ROUND_NUDGE = 1e-7
function U.round(x)
    return math.floor(x + 0.5 + ROUND_NUDGE)
end

function U.clamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

function U.inRange(x, lo, hi)
    return type(x) == 'number' and x >= lo and x <= hi
end

-- ============================================================================
--                                    TABLES
-- ============================================================================

function U.copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

function U.deepcopy(v, seen)
    if type(v) ~= 'table' then return v end
    seen = seen or {}
    if seen[v] then return seen[v] end
    local out = {}
    seen[v] = out
    for k, val in pairs(v) do out[U.deepcopy(k, seen)] = U.deepcopy(val, seen) end
    return setmetatable(out, getmetatable(v))
end

function U.contains(list, value)
    if type(list) ~= 'table' then return false end
    for i = 1, #list do
        if list[i] == value then return true end
    end
    return false
end

function U.keys(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
    return out
end

function U.count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

function U.map(list, fn)
    local out = {}
    for i = 1, #list do out[i] = fn(list[i], i) end
    return out
end

function U.filter(list, fn)
    local out = {}
    for i = 1, #list do
        if fn(list[i], i) then out[#out + 1] = list[i] end
    end
    return out
end

-- Read a dotted path such as 'objectives.1.waves' (numeric parts index arrays).
function U.getPath(t, path)
    local cur = t
    for part in tostring(path):gmatch('[^%.]+') do
        if type(cur) ~= 'table' then return nil end
        local n = tonumber(part)
        cur = cur[n or part]
    end
    return cur
end

function U.setPath(t, path, value)
    local parts = {}
    for part in tostring(path):gmatch('[^%.]+') do parts[#parts + 1] = tonumber(part) or part end
    local cur = t
    for i = 1, #parts - 1 do
        local p = parts[i]
        if type(cur[p]) ~= 'table' then cur[p] = {} end
        cur = cur[p]
    end
    cur[parts[#parts]] = value
end

-- ============================================================================
--                              STRINGS AND HASHES
-- ============================================================================
-- FNV-1a 32-bit: stable seeds from strings (dates, citizenids, file contents).
function U.hash(s)
    s = tostring(s)
    local h = 2166136261
    for i = 1, #s do
        h = h ~ s:byte(i)
        h = (h * 16777619) & 0xFFFFFFFF
    end
    return h
end

function U.hashHex(s)
    return ('%08x'):format(U.hash(s))
end

function U.startsWith(s, prefix)
    return type(s) == 'string' and s:sub(1, #prefix) == prefix
end

function U.trim(s)
    return (tostring(s):gsub('^%s+', ''):gsub('%s+$', ''))
end

-- ============================================================================
--                                    RANDOM
-- ============================================================================
-- Deterministic generator (never touches math.random), so a seed gives the same
-- sequence on the server, on every client and in tests.
--   local rng = CP.U.rng(seed); rng:next() -> [0,1); rng:int(1, 6); rng:chance(0.25)
local Rng = {}
Rng.__index = Rng

function U.rng(seed)
    local s = math.floor(tonumber(seed) or 1) & 0x7FFFFFFF
    if s == 0 then s = 0x2545F491 end
    return setmetatable({ s = s }, Rng)
end

function Rng:next()
    -- xorshift32 on 32 bits
    local x = self.s
    x = x ~ ((x << 13) & 0xFFFFFFFF)
    x = x ~ (x >> 17)
    x = x ~ ((x << 5) & 0xFFFFFFFF)
    x = x & 0xFFFFFFFF
    if x == 0 then x = 0x2545F491 end
    self.s = x
    return x / 4294967296
end

function Rng:int(lo, hi)
    if hi == nil then lo, hi = 1, lo end
    if hi < lo then return lo end
    return lo + math.floor(self:next() * (hi - lo + 1))
end

function Rng:chance(p)
    return self:next() < (p or 0)
end

function Rng:pick(list)
    if not list or #list == 0 then return nil, nil end
    local i = self:int(1, #list)
    return list[i], i
end

-- Shuffle a copy of the list.
function Rng:shuffle(list)
    local out = {}
    for i = 1, #list do out[i] = list[i] end
    for i = #out, 2, -1 do
        local j = self:int(1, i)
        out[i], out[j] = out[j], out[i]
    end
    return out
end

-- Pick n distinct items (fewer if the list is shorter).
function Rng:sample(list, n)
    local s = self:shuffle(list)
    local out = {}
    for i = 1, math.min(n, #s) do out[i] = s[i] end
    return out
end

-- ============================================================================
--                                UUID (server)
-- ============================================================================

local uuidRng
function U.uuid()
    if not uuidRng then
        local seed = (os and os.time and os.time() or 0) ~ U.hash(tostring({}))
        if GetGameTimer then seed = seed ~ GetGameTimer() end
        uuidRng = U.rng(seed)
    end
    local function hex(n)
        local t = {}
        for i = 1, n do t[i] = ('%x'):format(uuidRng:int(0, 15)) end
        return table.concat(t)
    end
    local variant = ('%x'):format(8 + uuidRng:int(0, 3))
    return ('%s-%s-4%s-%s%s-%s'):format(hex(8), hex(4), hex(3), variant, hex(3), hex(12))
end

-- ============================================================================
--                                   VECTORS
-- ============================================================================
-- Accepts vector3/vector4 values or plain { x, y, z } tables.
local function Xyz(v)
    if v == nil then return nil end
    local t = type(v)
    if t == 'vector3' or t == 'vector4' or t == 'vector2' then return v.x, v.y, v.z or 0.0 end
    if t == 'table' then
        return v.x or v[1] or 0.0, v.y or v[2] or 0.0, v.z or v[3] or 0.0
    end
    return nil
end
U.xyz = Xyz

function U.dist(a, b)
    local ax, ay, az = Xyz(a)
    local bx, by, bz = Xyz(b)
    if not ax or not bx then return math.huge end
    local dx, dy, dz = ax - bx, ay - by, az - bz
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function U.dist2d(a, b)
    local ax, ay = Xyz(a)
    local bx, by = Xyz(b)
    if not ax or not bx then return math.huge end
    local dx, dy = ax - bx, ay - by
    return math.sqrt(dx * dx + dy * dy)
end

-- Shortest 2D distance from point p to the polyline pts (list of vectors).
function U.distToPolyline(p, pts)
    local px, py = Xyz(p)
    if not px or not pts or #pts == 0 then return math.huge end
    if #pts == 1 then return U.dist2d(p, pts[1]) end
    local best = math.huge
    for i = 1, #pts - 1 do
        local ax, ay = Xyz(pts[i])
        local bx, by = Xyz(pts[i + 1])
        local vx, vy = bx - ax, by - ay
        local len2 = vx * vx + vy * vy
        local t = 0.0
        if len2 > 0 then t = U.clamp(((px - ax) * vx + (py - ay) * vy) / len2, 0.0, 1.0) end
        local cx, cy = ax + t * vx, ay + t * vy
        local d = math.sqrt((px - cx) ^ 2 + (py - cy) ^ 2)
        if d < best then best = d end
    end
    return best
end

-- JSON-safe form of a vector ({ x, y, z[, w] }) and back.
function U.vecToTable(v)
    if v == nil then return nil end
    local t = type(v)
    if t == 'vector4' or (t == 'table' and v.w ~= nil) then
        return { x = v.x, y = v.y, z = v.z, w = v.w }
    end
    local x, y, z = Xyz(v)
    return { x = x, y = y, z = z }
end

function U.tableToVec(t)
    if t == nil then return nil end
    local ty = type(t)
    if ty == 'vector3' or ty == 'vector4' then return t end
    if ty ~= 'table' then return nil end
    local x, y, z = t.x or t[1], t.y or t[2], t.z or t[3]
    local w = t.w or t[4]
    if w ~= nil and vector4 then return vector4(x + 0.0, y + 0.0, z + 0.0, w + 0.0) end
    if vector3 then return vector3(x + 0.0, y + 0.0, (z or 0.0) + 0.0) end
    return { x = x, y = y, z = z, w = w }
end

-- Recursively convert every vector in a value into { x, y, z[, w] } tables (for JSON).
function U.serialize(v)
    local t = type(v)
    if t == 'vector3' or t == 'vector4' or t == 'vector2' then return U.vecToTable(v) end
    if t ~= 'table' then return v end
    local out = {}
    for k, val in pairs(v) do out[k] = U.serialize(val) end
    return out
end

-- ============================================================================
--                                 HEX COLOURS
-- ============================================================================

function U.isHexColour(s)
    return type(s) == 'string' and s:match('^#%x%x%x%x%x%x$') ~= nil
end

-- Relative luminance of a #rrggbb colour (0 = black, 1 = white).
function U.luminance(hex)
    local r, g, b =
        tonumber(hex:sub(2, 3), 16) / 255, tonumber(hex:sub(4, 5), 16) / 255, tonumber(hex:sub(6, 7), 16) / 255
    local function lin(c) return c <= 0.03928 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4 end
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
end

-- White or near-black text, whichever contrasts better with the background.
function U.contrastText(bgHex)
    if not U.isHexColour(bgHex) then return '#ffffff' end
    local L = U.luminance(bgHex)
    local whiteContrast = 1.05 / (L + 0.05)
    local darkContrast = (L + 0.05) / (U.luminance('#111111') + 0.05)
    return whiteContrast >= darkContrast and '#ffffff' or '#111111'
end

-- ============================================================================
--                            DATABASE VALUE HELPERS
-- ============================================================================
-- oxmysql may return TINYINT(1) as boolean or number and JSON as string or table.
function U.truthy(v)
    return v == true or v == 1 or v == '1' or v == 'true'
end

function U.jsonField(v)
    if type(v) == 'table' then return v end
    if type(v) ~= 'string' or v == '' then return nil end
    local ok, data = pcall(json.decode, v)
    if ok then return data end
    return nil
end

function U.num(v, default)
    return tonumber(v) or default or 0
end

-- Truncate a string to at most n bytes for fixed-size columns, never ending inside a UTF-8 character:
-- MariaDB strict mode (oxmysql connects as utf8mb4) refuses the whole row for a broken sequence (error 1366).
function U.clip(s, n)
    if s == nil then return nil end
    s = tostring(s)
    if #s <= n then return s end
    s = s:sub(1, n)
    local last = #s
    local j = last
    while j > 1 and j > last - 3 and s:byte(j) >= 0x80 and s:byte(j) < 0xC0 do j = j - 1 end
    local lead = s:byte(j)
    if lead and lead >= 0xC0 then
        local need = (lead >= 0xF0 and 4) or (lead >= 0xE0 and 3) or 2
        if last - j + 1 < need then return s:sub(1, j - 1) end
    end
    return s
end

return U
