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

-- A v4-shaped id (36 characters): the first 8 hex digits are the unix time and the next 4 a counter, so two
-- restarts never hand out the same run of ids (the 32-bit generator alone walks the same cycle each time).
local uuidRng
local uuidCount = 0
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
    uuidCount = (uuidCount + 1) & 0xFFFF
    local now = math.floor(os and os.time and os.time() or 0) & 0xFFFFFFFF
    return ('%08x-%04x-4%s-%s%s-%s'):format(now, uuidCount, hex(3), variant, hex(3), hex(12))
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

-- ============================================================================
--                               FOLDERS (server)
-- ============================================================================
-- FXServer cannot make a folder on Linux: os.createdir makes it and then kills the whole server with signal 11,
-- which pcall cannot catch (LuaOS.cpp calls FindClose on an invalid handle after the mkdir, and the Linux build
-- closedir()s it). SaveResourceFile and io.open make no folders and os.execute is refused. So every folder
-- Crimson-Police writes ships with it (a .gitkeep keeps it in the download), and a missing one is reported for the
-- owner to create by hand. Only on Windows, where that FindClose just fails, is a missing folder made.

-- true on a Windows server (FXServer's os.getenv('os') answers 'Windows' or 'Linux').
function U.isWindows()
    local okE, name = pcall(os and os.getenv, 'os')
    if okE and type(name) == 'string' then return name:find('^Windows') ~= nil end
    return type(package) == 'table' and type(package.config) == 'string' and package.config:sub(1, 1) == '\\'
end

-- Something is at this path (on Linux io.open opens a folder too).
local function PathThere(path)
    local f = io and io.open(path, 'rb')
    if not f then return false end
    f:close()
    return true
end

local function ProbeWrite(dir)
    local probe = dir .. '/.cp-write-test'
    local f = io and io.open(probe, 'wb')
    if not f then return false end
    local ok = f:write('ok')
    f:close()
    if os and os.remove then os.remove(probe) end
    return ok ~= nil
end

-- A folder the server writes into: true when it can be written, else false and 'missing' or 'readonly'.
-- canWrite(dir) says whether a probe file can be written there (each caller probes through the layer it writes
-- with); the default writes and removes <dir>/.cp-write-test. On Windows the missing folders below the resource
-- folder (or below the drive for a folder outside it) are made one level per call; on Linux nothing is made.
function U.ensureFolder(dir, canWrite)
    if type(dir) ~= 'string' or dir == '' then return false, 'missing' end
    canWrite = canWrite or ProbeWrite
    dir = dir:gsub('[/\\]+$', '')
    if canWrite(dir) then return true end
    if not U.isWindows() then
        if PathThere(dir) then return false, 'readonly' end
        return false, 'missing'
    end
    local createdir = os and os.createdir
    if not createdir then return false, 'missing' end
    local root = ''
    if GetResourcePath and GetCurrentResourceName then
        local okR, r = pcall(GetResourcePath, GetCurrentResourceName())
        root = okR and type(r) == 'string' and r:gsub('[/\\]+$', '') or ''
    end
    root = root:gsub('\\', '/')
    local inside = root ~= '' and dir:gsub('\\', '/'):sub(1, #root + 1) == root .. '/'
    local path = ''
    for part, sep in dir:gmatch('([^/\\]*)([/\\]?)') do
        path = path .. part
        local below = not inside or #path > #root
        if part ~= '' and not part:match('^%a:$') and below and not PathThere(path) then
            pcall(createdir, path)
        end
        path = path .. sep
    end
    if canWrite(dir) then return true end
    return false, 'missing'
end

-- The console line for a folder U.ensureFolder refused (why = 'missing' or 'readonly').
function U.folderAdvice(dir, why)
    if why == 'readonly' then
        return ('the folder %s is there but the server cannot write to it: give the user FXServer runs as write access to it'):format(
            tostring(dir))
    end
    return ('the folder %s is missing: create it by hand (FXServer cannot create folders on Linux; Crimson-Police ships every folder it writes, so check that the whole resource folder was copied)'):format(
        tostring(dir))
end

-- ============================================================================
--                           THE MISSION FILE READER
-- ============================================================================
-- Mission files are data and are never run. Every text that becomes a mission is read here: the built-ins and
-- missions/builtin/index.lua, custom missions, edited built-ins, their backups and archived copies, and Lua text
-- pasted into the Mission Builder's import. FXServer builds its Lua without debug.sethook (LUA_SANDBOX), so a file
-- that ran could not be stopped; a file that is only read costs time and memory in proportion to its length, and
-- both are capped below.
--
-- A mission file is the layout the Mission Builder writes (and the shipped files use): comments, then one
-- RegisterMission({ ... }) call. Inside it: tables ({ a = 1, ['b c'] = 2, 3 }), strings in any Lua form ('a', "a",
-- [[a]], every escape), numbers (12, -3.5, 0x1F, 1e3), true, false, nil, and vec3 / vector3 with 3 numbers or
-- vec4 / vector4 with 4. Anything else (a variable, a sum, a function call, a loop, CfxLua's extra syntax) is
-- refused with the file name, the line and the text near it.

local MISSION_TEXT_MAX = 1048576   -- longest mission file read (bytes); the largest shipped file is 23 KB
local MISSION_VALUES_MAX = 100000  -- most values in one file (the Builder stores at most 20,000)
local MISSION_DEPTH_MAX = 32       -- deepest table nesting (the Builder stores at most 10)
local MISSION_NEAR_MAX = 40        -- longest text quoted after 'near' in a message
local NOT_DATA = 'a mission file holds only RegisterMission({ ... }) with plain values (no code, variables or sums)'
U.missionFileLimits = { bytes = MISSION_TEXT_MAX, values = MISSION_VALUES_MAX, depth = MISSION_DEPTH_MAX }

-- the text is read with these copies: a later change to the string table does not reach the reader
local byte, sub, find, match, char, concat =
    string.byte, string.sub, string.find, string.match, string.char, table.concat
local utf8char = utf8.char

local VEC_ARGS = { vec3 = 3, vector3 = 3, vec4 = 4, vector4 = 4 }
-- a character that, after a value, starts a sum, a comparison, a join, a call or an index: code, not data
local OPERATORS = {}
for c in ('+-*/%^.<>~=&|#([{:'):gmatch('.') do OPERATORS[c] = true end
local VEC_WHY = {}
for name, want in pairs(VEC_ARGS) do
    VEC_WHY[name] = ('%s takes %d numbers in ( ), like %s(%s)'):format(name, want, name,
        want == 3 and '100.0, -200.5, 30.0' or '100.0, -200.5, 30.0, 90.0')
end
-- Lua's reserved words: never a key written as name = value
local LUA_WORDS = {}
local WORDS = 'and break do else elseif end false for function goto if in local nil not or repeat return then true until while'
for w in WORDS:gmatch('%a+') do LUA_WORDS[w] = true end
-- \a \b \f \n \r \t \v \\ \" \' by the byte after the backslash
local ESCAPES = {
    [97] = '\a',
    [98] = '\b',
    [102] = '\f',
    [110] = '\n',
    [114] = '\r',
    [116] = '\t',
    [118] = '\v',
    [92] = '\\',
    [34] = '"',
    [39] = '\'',
}

local function IsNameStart(c) return c and ((c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95) end
local function IsDigit(c) return c and c >= 48 and c <= 57 end
local function IsHex(c) return c and ((c >= 48 and c <= 57) or (c >= 65 and c <= 70) or (c >= 97 and c <= 102)) end

-- The text after 'near' in a message: short, printable ASCII only.
local function Near(text)
    text = tostring(text)
    if #text > MISSION_NEAR_MAX then text = sub(text, 1, MISSION_NEAR_MAX) .. '...' end
    return (text:gsub('[^ -~]', '?'))
end

local function Fail(r, line, msg, near)
    if near ~= nil then msg = ('%s near \'%s\''):format(msg, Near(near)) end
    error({ missionText = ('%s:%d: %s'):format(r.name, line, msg) }, 0)
end

-- p is at a '\r' or '\n': the position after that line break (\r\n and \n\r count as one, as in Lua).
local function AfterBreak(s, p)
    local c, d = byte(s, p), byte(s, p + 1)
    if (d == 10 or d == 13) and d ~= c then return p + 2 end
    return p + 1
end

-- The number of line breaks in text and, when asked, the text with every line break written as '\n'.
local function LineBreaks(text, normalise)
    if not find(text, '[\r\n]') then return text, 0 end
    local parts, n, p = {}, 0, 1
    while true do
        local a = find(text, '[\r\n]', p)
        if not a then break end
        if normalise then parts[#parts + 1] = sub(text, p, a - 1) end
        n = n + 1
        p = AfterBreak(text, a)
    end
    if not normalise then return nil, n end
    parts[#parts + 1] = sub(text, p)
    return concat(parts, '\n'), n
end

-- A long bracket [==[ ... ]==] whose first '[' is at p (eq = its '=' signs): its text and the position after it.
local function LongBracket(r, p, eq, what)
    local s, line = r.s, r.line
    local open = p + #eq + 2
    local close = find(s, ']' .. eq .. ']', open, true)
    if not close then
        Fail(r, line, ('this long %s is never closed (\']%s]\' is missing)'):format(what, eq), sub(s, p, open - 1))
    end
    local body = sub(s, open, close - 1)
    local text, n = LineBreaks(body, what == 'string')
    r.line = line + n
    -- a line break right after the opening bracket is not part of the string, as in Lua
    if text and (byte(body, 1) == 10 or byte(body, 1) == 13) then text = sub(text, 2) end
    return text, close + #eq + 2
end

-- Spaces, line breaks and comments before the next token.
local function SkipSpace(r)
    local s, p = r.s, r.pos
    while true do
        local c = byte(s, p)
        if c == 10 or c == 13 then
            p = AfterBreak(s, p)
            r.line = r.line + 1
        elseif c == 32 or c == 9 or c == 11 or c == 12 then
            p = p + 1
        elseif c == 45 and byte(s, p + 1) == 45 then
            local eq = match(s, '^%[(=*)%[', p + 2)
            if eq then
                local _, after = LongBracket(r, p + 2, eq, 'comment')
                p = after
            else
                p = find(s, '[\r\n]', p + 2) or (r.n + 1)
            end
        else
            r.pos = p
            return
        end
    end
end

-- A quoted string that opens at r.pos with the quote byte q: its value (every Lua 5.4 escape).
local function ReadQuoted(r, q)
    local s, start, out = r.s, r.pos, {}
    local p = start + 1
    local stop = q == 34 and '[\\\r\n"]' or '[\\\r\n\']'
    while true do
        local a = find(s, stop, p)
        if not a then
            Fail(r, r.line, 'this text in quotes is never closed', sub(s, start, start + MISSION_NEAR_MAX))
        end
        if a > p then out[#out + 1] = sub(s, p, a - 1) end
        local c = byte(s, a)
        if c == q then
            r.pos = a + 1
            return concat(out)
        end
        if c ~= 92 then
            Fail(r, r.line, 'this text in quotes is not closed before the end of its line',
                sub(s, start, start + MISSION_NEAR_MAX))
        end
        local e = byte(s, a + 1)
        if e and ESCAPES[e] then
            out[#out + 1] = ESCAPES[e]
            p = a + 2
        elseif e == 10 or e == 13 then
            out[#out + 1] = '\n'
            p = AfterBreak(s, a + 1)
            r.line = r.line + 1
        elseif e == 120 then
            -- \xXX
            local hex = match(s, '^[0-9A-Fa-f][0-9A-Fa-f]', a + 2)
            if not hex then Fail(r, r.line, '\\x must be followed by two hexadecimal digits', sub(s, a, a + 3)) end
            out[#out + 1] = char(tonumber(hex, 16))
            p = a + 4
        elseif e == 122 then
            -- \z skips the spaces and line breaks after it
            p = a + 2
            while true do
                local d = byte(s, p)
                if d == 10 or d == 13 then
                    p = AfterBreak(s, p)
                    r.line = r.line + 1
                elseif d == 32 or d == 9 or d == 11 or d == 12 then
                    p = p + 1
                else
                    break
                end
            end
        elseif e == 117 then
            -- \u{XXX}: a UTF-8 character up to 7FFFFFFF
            local digits = match(s, '^{([0-9A-Fa-f]+)}', a + 2)
            local sig = digits and match(digits, '^0*(.*)$')
            local n = sig and #sig <= 8 and tonumber(sig ~= '' and sig or '0', 16)
            if not n or n > 0x7FFFFFFF then
                Fail(r, r.line, '\\u must be followed by {hexadecimal digits} up to 7FFFFFFF', sub(s, a, a + 12))
            end
            out[#out + 1] = utf8char(n)
            p = a + 4 + #digits
        elseif IsDigit(e) then
            -- \ddd: one to three decimal digits, up to 255
            local dec = match(s, '^[0-9][0-9]?[0-9]?', a + 1)
            local n = tonumber(dec)
            if n > 255 then Fail(r, r.line, 'a \\ddd escape must be 255 or less', '\\' .. dec) end
            out[#out + 1] = char(n)
            p = a + 1 + #dec
        else
            Fail(r, r.line, 'this \\ escape does not exist in Lua', sub(s, a, a + 1))
        end
    end
end

-- A numeral at p, cut as Lua's lexer cuts it (llex.c read_numeral) and converted by tonumber (the same
-- luaO_str2num): integers, floats, hexadecimal, exponents.
local function ReadNumeral(r, p, line)
    local s = r.s
    local q, e1, e2 = p, 69, 101
    if byte(s, p) == 48 and (byte(s, p + 1) == 120 or byte(s, p + 1) == 88) then q, e1, e2 = p + 2, 80, 112 end
    while true do
        local d = byte(s, q)
        if d == e1 or d == e2 then
            q = q + 1
            local sign = byte(s, q)
            if sign == 43 or sign == 45 then q = q + 1 end
        elseif IsHex(d) or d == 46 then
            q = q + 1
        else
            break
        end
    end
    if IsNameStart(byte(s, q)) then q = q + 1 end
    local text = sub(s, p, q - 1)
    local n = tonumber(text)
    if not n then Fail(r, line, 'this is not a number Lua can read', text) end
    r.pos = q
    return n, text
end

-- The next token: kind ('name', 'number', 'string', 'eof' or the character itself), value, text for messages, line.
local function Lex(r)
    SkipSpace(r)
    local s, p, line = r.s, r.pos, r.line
    local c = byte(s, p)
    if not c then return 'eof', nil, '<eof>', line end
    if IsNameStart(c) then
        local name = match(s, '^[A-Za-z_][A-Za-z0-9_]*', p)
        r.pos = p + #name
        return 'name', name, name, line
    end
    if IsDigit(c) or (c == 46 and IsDigit(byte(s, p + 1))) then
        local n, text = ReadNumeral(r, p, line)
        return 'number', n, text, line
    end
    -- a string's text for messages is its start position, cut from the file only when a message needs it
    if c == 34 or c == 39 then return 'string', ReadQuoted(r, c), p, line end
    if c == 91 then
        local eq = match(s, '^%[(=*)%[', p)
        if eq then
            local body, after = LongBracket(r, p, eq, 'string')
            r.pos = after
            return 'string', body, p, line
        end
    end
    r.pos = p + 1
    local ch = char(c)
    if c < 32 or c > 126 then return ch, nil, ('<\\%d>'):format(c), line end
    return ch, nil, ch, line
end

-- r.tk, r.tv, r.tt, r.tl: the current token (kind, value, text, line); one more can be looked at ahead.
local function Advance(r)
    if r.hasAhead then
        r.tk, r.tv, r.tt, r.tl = r.ak, r.av, r.at, r.al
        r.hasAhead = false
    else
        r.tk, r.tv, r.tt, r.tl = Lex(r)
    end
end

local function LookAhead(r)
    if not r.hasAhead then
        r.ak, r.av, r.at, r.al = Lex(r)
        r.hasAhead = true
    end
    return r.ak
end

local function FailHere(r, msg)
    local near = r.tt
    if type(near) == 'number' then near = sub(r.s, near, near + MISSION_NEAR_MAX) end
    Fail(r, r.tl, msg, near)
end

local function Expect(r, kind, msg)
    if r.tk ~= kind then FailHere(r, msg) end
    Advance(r)
end

local ReadValue

-- A number with any '-' signs before it.
local function ReadNumber(r)
    local negative = false
    while r.tk == '-' do
        negative = not negative
        Advance(r)
    end
    if r.tk ~= 'number' then FailHere(r, 'a number was expected here') end
    local v = r.tv
    Advance(r)
    if negative then return -v end
    return v
end

-- vec3(x, y, z) / vector3(...) / vec4(x, y, z, w) / vector4(...) of numbers: the server's own vector value.
local function ReadVec(r, name)
    local want, why, line = VEC_ARGS[name], VEC_WHY[name], r.tl
    Advance(r)
    Expect(r, '(', why)
    local args = {}
    for i = 1, want do
        if i > 1 then Expect(r, ',', why) end
        if r.tk ~= 'number' and r.tk ~= '-' then FailHere(r, why) end
        args[i] = ReadNumber(r)
    end
    Expect(r, ')', why)
    local make
    if want == 3 then make = vector3 or vec3 else make = vector4 or vec4 end
    if type(make) ~= 'function' then Fail(r, line, name .. ' is not available here') end
    -- exactly `want` arguments: CfxLua's constructors count them
    if want == 3 then return make(args[1], args[2], args[3]) end
    return make(args[1], args[2], args[3], args[4])
end

local function KeyName(key)
    if type(key) == 'string' then return ('the key \'%s\''):format(Near(key)) end
    return ('the key [%s]'):format(tostring(key))
end

-- A table constructor at the current '{'. Keys as Lua reads them (name = v, [k] = v, then 1, 2, 3 ... in order); a
-- key given twice is refused (Lua would keep the last one, so one of the two was a mistake).
local function ReadTable(r, depth)
    if depth > MISSION_DEPTH_MAX then FailHere(r, ('tables are nested more than %d deep'):format(MISSION_DEPTH_MAX)) end
    local openLine = r.tl
    Advance(r)
    local t, n, nils = {}, 0, nil
    while r.tk ~= '}' do
        local line, key, value = r.tl, nil, nil
        if r.tk == '[' then
            Advance(r)
            key = ReadValue(r, depth + 1)
            local kt = type(key)
            if kt ~= 'string' and kt ~= 'number' and kt ~= 'boolean' then
                Fail(r, line, 'a key in [ ] must be a text, a number, true or false')
            end
            Expect(r, ']', '\']\' was expected after the key')
            Expect(r, '=', '\'=\' was expected after [key]')
            value = ReadValue(r, depth + 1)
        elseif r.tk == 'name' and not LUA_WORDS[r.tv] and LookAhead(r) == '=' then
            key = r.tv
            Advance(r)
            Advance(r)
            value = ReadValue(r, depth + 1)
        else
            n = n + 1
            key = n
            value = ReadValue(r, depth + 1)
        end
        if t[key] ~= nil or (nils and nils[key]) then
            Fail(r, line, ('%s is given twice in the table that opens on line %d'):format(KeyName(key), openLine))
        end
        if value == nil then
            nils = nils or {}
            nils[key] = true
        else
            t[key] = value
        end
        if r.tk == ',' or r.tk == ';' then
            Advance(r)
        elseif OPERATORS[r.tk] then
            FailHere(r, NOT_DATA)
        elseif r.tk == 'eof' then
            FailHere(r, ('the file ends before the table that opens on line %d is closed with }'):format(openLine))
        elseif r.tk ~= '}' then
            FailHere(r, ('\',\' or \'}\' was expected (the table opens on line %d)'):format(openLine))
        end
    end
    Advance(r)
    return t
end

ReadValue = function(r, depth)
    r.values = r.values + 1
    if r.values > MISSION_VALUES_MAX then
        FailHere(r, ('the file holds more than %d values'):format(MISSION_VALUES_MAX))
    end
    local k, v = r.tk, r.tv
    if k == 'string' then
        Advance(r)
        return v
    end
    if k == 'number' or k == '-' then return ReadNumber(r) end
    if k == '{' then return ReadTable(r, depth) end
    if k == 'name' then
        if v == 'nil' then
            Advance(r)
            return nil
        end
        if v == 'true' or v == 'false' then
            Advance(r)
            return v == 'true'
        end
        if VEC_ARGS[v] then return ReadVec(r, v) end
    end
    if k == 'eof' then FailHere(r, 'the file ends too early: a \'}\' or \')\' is missing') end
    FailHere(r, NOT_DATA)
end

-- A reader over text, or nil, err, true when the text is too large to read.
local function NewReader(text, chunkName)
    local name = (tostring(chunkName or 'mission'):gsub('^@', ''))
    if type(text) ~= 'string' then return nil, name .. ': the file is not text' end
    if #text > MISSION_TEXT_MAX then
        return nil, ('%s: the file is larger than %d bytes, so it is not read'):format(name, MISSION_TEXT_MAX), true
    end
    local r = { s = text, n = #text, pos = 1, line = 1, name = name, values = 0 }
    -- a UTF-8 byte order mark (some Windows editors write one) is skipped
    if sub(text, 1, 3) == '\239\187\191' then r.pos = 4 end
    return r
end

-- fn(r) inside pcall, from the first token: its result, or nil and the reader's message (never raises).
local function Guard(r, fn)
    local ok, res = pcall(function()
        Advance(r)
        return fn(r)
    end)
    if ok then return res end
    if type(res) == 'table' and res.missionText then return nil, res.missionText end
    return nil, ('%s: the file could not be read (%s)'):format(r.name, tostring(res))
end

-- Every value passed to RegisterMission in text, in order (false for a call without a table), or nil, err,
-- tooLarge. chunkName (with or without a leading '@') starts every message, followed by the line.
function U.readMissionCalls(text, chunkName)
    local r, err, tooLarge = NewReader(text, chunkName)
    if not r then return nil, err, tooLarge end
    return Guard(r, function()
        local calls = {}
        while r.tk ~= 'eof' do
            if r.tk == ';' then
                Advance(r)
            elseif r.tk == 'name' and r.tv == 'RegisterMission' then
                Advance(r)
                local arg = false
                if r.tk == '(' then
                    Advance(r)
                    if r.tk ~= ')' then
                        arg = ReadValue(r, 1)
                        if arg == nil then arg = false end
                    end
                    Expect(r, ')', '\')\' was expected: RegisterMission takes one table')
                elseif r.tk == '{' or r.tk == 'string' then
                    arg = ReadValue(r, 1)
                else
                    FailHere(r, '\'(\' was expected after RegisterMission')
                end
                calls[#calls + 1] = arg
            else
                FailHere(r, NOT_DATA)
            end
        end
        return calls
    end)
end

-- `return <value>` (missions/builtin/index.lua), read the same way: true, value | nil, err.
function U.readMissionReturn(text, chunkName)
    local r, err = NewReader(text, chunkName)
    if not r then return nil, err end
    local value, rerr = Guard(r, function()
        if not (r.tk == 'name' and r.tv == 'return') then
            FailHere(r, 'this file must start with return and a list, like return { \'beat_patrol\' }')
        end
        Advance(r)
        local v = ReadValue(r, 1)
        if r.tk == ';' then Advance(r) end
        if r.tk ~= 'eof' then FailHere(r, 'nothing may follow the list') end
        return { v }
    end)
    if not value then return nil, rerr end
    return true, value[1]
end

-- One mission file: the table passed to its single RegisterMission call, or nil, err (the loader's messages; a
-- message from the reader names the file and the line).
function U.parseMissionFile(text, chunkName)
    if type(text) ~= 'string' or text == '' then return nil, 'the file is empty' end
    local calls, err, tooLarge = U.readMissionCalls(text, chunkName)
    if not calls then
        if tooLarge then return nil, tostring(err) end
        return nil, 'syntax error: ' .. tostring(err)
    end
    if #calls == 0 then return nil, 'the file never calls RegisterMission({ ... })' end
    if #calls > 1 then
        return nil, ('the file calls RegisterMission %d times; exactly one call is allowed'):format(#calls)
    end
    -- a table the reader built has no metatable (a vector does)
    if type(calls[1]) ~= 'table' or getmetatable(calls[1]) ~= nil then return nil, 'RegisterMission expects a table' end
    return calls[1]
end

return U
