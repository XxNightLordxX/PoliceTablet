-- The mission file reader (CP.U.parseMissionFile, shared/utils.lua): mission files are data, read and never run.

local H = dofile('tests/harness.lua')
local X = dofile('tests/fixtures/admin_missions/boot.lua')(H, 'mission_reader')
local U = CP.U
local B = CP.Builder
local VMT = getmetatable(vec3(0, 0, 0))

-- ============================================================================
--                          0. FXSERVER'S DEBUG TABLE
-- ============================================================================

do
    local keys = {}
    for k in pairs(debug) do keys[#keys + 1] = k end
    table.sort(keys)
    H.eq(table.concat(keys, ' '), table.concat(H.FX_DEBUG, ' '), 'the resource sees FXServer\'s five debug functions')
    H.eq(debug.sethook, nil, 'no debug.sethook, as on FXServer')
    H.eq(debug.gethook, nil, 'no debug.gethook either')
    H.eq(require('debug'), debug, 'require(\'debug\') gives the same table')
    H.eq(type(H.debug.sethook), 'function', 'the specs\' own tools keep the full library (H.debug)')
    local help = io.popen('python3 ' .. H.root .. '../tools/lint_fivem.py --help 2>&1')
    local text = help:read('a')
    help:close()
    H.ok(text:find('FX11 debug-sandbox', 1, true) ~= nil, 'lint-fivem flags any other debug function (FX11)')
end

-- ============================================================================
--                       1. EVERY BUILT-IN LOADS AT START
-- ============================================================================

local function Printed(text)
    for _, l in ipairs(X.lines) do if l:find(text, 1, true) then return l end end
    return nil
end

local indexText = X.read('missions/builtin/index.lua')
local okIndex, ids = U.readMissionReturn(indexText, 'missions/builtin/index.lua')
H.ok(okIndex and type(ids) == 'table' and #ids == 19,
    'index.lua is read as data: ' .. tostring(okIndex and #ids or ids))
ids = okIndex and ids or {}

do
    H.ok(Printed('missions loaded: 19 built-in (0 edited), 0 custom, 0 rejected') ~= nil,
        'the start line: 19 built-in (0 edited), 0 custom, 0 rejected')
    H.eq(Printed('cannot limit a mission file'), nil, 'no "this server cannot limit a mission file" warning')
    local sum = CP.Missions.loadSummary()
    H.eq(sum and #sum.failed, 0, 'the load result lists no rejected file')
    for _, id in ipairs(ids) do
        local def = CP.Missions.get(id)
        local start = def and def.locations and def.locations[1] and def.locations[1].start
        H.ok(def ~= nil and def.source == 'builtin', id .. ' is loaded and can be drawn')
        H.ok(start and getmetatable(start.coords) == VMT, id .. ': its start is a real vector')
    end
    H.ok(CP.Missions.parse(X.read('missions/builtin/beat_patrol.lua'), '@missions/builtin/beat_patrol.lua') ~= nil,
        'CP.Missions.parse (CP.Testing, the Builder) reads a shipped file')
end

-- ============================================================================
--             2. EVERY SHIPPED FILE READS EXACTLY AS LUA READS IT
-- ============================================================================

-- a and b are the same value: types, math types (integer or float), the sign of a zero, vectors, every key
local function Same(a, b, path, diffs)
    if type(a) ~= type(b) then
        diffs[#diffs + 1] = ('%s: %s vs %s'):format(path, type(a), type(b))
        return
    end
    if type(a) ~= 'table' then
        local zero = a == 0 and b == 0 and (1 / a) ~= (1 / b)
        if a ~= b or math.type(a) ~= math.type(b) or zero then
            diffs[#diffs + 1] = ('%s: %s (%s) vs %s (%s)'):format(path, tostring(a), tostring(math.type(a)),
                tostring(b), tostring(math.type(b)))
        end
        return
    end
    if getmetatable(a) ~= getmetatable(b) then diffs[#diffs + 1] = path .. ': a vector and a table' end
    for k, v in pairs(a) do Same(v, b[k], path .. '.' .. tostring(k), diffs) end
    for k in pairs(b) do if a[k] == nil then diffs[#diffs + 1] = path .. '.' .. tostring(k) .. ': extra' end end
end

-- Lua's own reading of a TRUSTED text (shipped, or written by this spec): the reference only. The resource never
-- runs mission text.
local function ByLua(text)
    local got = {}
    local env = {
        RegisterMission = function(t) got[#got + 1] = t end,
        vec3 = vec3,
        vec4 = vec4,
        vector3 = vector3,
        vector4 = vector4,
    }
    if text:sub(1, 3) == '\239\187\191' then text = text:sub(4) end
    local chunk = assert(load(text, '=reference', 't', env))
    chunk()
    return got[1], #got
end

do
    local list = assert(load(indexText, '=index', 't', {}))()
    local diffs = {}
    Same(list, ids, 'index', diffs)
    H.eq(#diffs, 0, 'index.lua: the same list as Lua reads ' .. table.concat(diffs, '; '))
    for _, id in ipairs(ids) do
        local path = 'missions/builtin/' .. id .. '.lua'
        local text = X.read(path)
        local def, err = U.parseMissionFile(text, path)
        H.ok(def and def.id == id, path .. ' reads: ' .. tostring(err))
        local d = {}
        if def then Same(ByLua(text), def, id, d) end
        H.eq(#d, 0, path .. ': the same values as Lua reads ' .. table.concat(d, '; '):sub(1, 400))
    end
end

-- ============================================================================
--             3. THE LAYOUTS THE BUILDER WRITES READ BACK EXACTLY
-- ============================================================================
-- Every built-in, as Edit in Builder opens it (B.shippedOf), written the way Publish writes it: as an edited
-- built-in (missions/custom/overrides/<id>.lua) and as a custom mission (missions/custom/<id>.lua).

do
    local n = 0
    for _, id in ipairs(ids) do
        local shipped = B.shippedOf(id)
        H.ok(shipped and type(shipped.raw) == 'table' and shipped.raw.id == id,
            id .. ': Edit in Builder reads the shipped file')
        if shipped then
            local def = B.sanitize(B.fromFileUnits(shipped.raw), id)
            local carry = {
                top = U.serialize(shipped.raw),
                bonuses = U.serialize(shipped.raw.bonuses or {}),
                penalties = U.serialize(shipped.raw.penalties or {}),
            }
            for _, meta in ipairs({
                { version = 3, publisher = 'Sgt. O\'Neil "Ace" (LSPD)', override = true, carry = carry },
                { version = 7, publisher = 'console', edited = 'by hand ]] --' },
            }) do
                local text = B.exportLua(def, meta)
                local path = (meta.override and 'missions/custom/overrides/' or 'missions/custom/') .. id .. '.lua'
                local parsed, perr = B.parse(text, path)
                local d = {}
                if parsed then Same(ByLua(text), parsed, id, d) else d[1] = tostring(perr) end
                H.eq(#d, 0,
                    path .. ' (as the Builder writes it) reads back exactly: ' .. table.concat(d, '; '):sub(1, 400))
                n = n + 1
            end
        end
    end
    H.eq(n, 38, 'every built-in in both Builder layouts')
end

-- ============================================================================
--                      4. EVERY LUA FORM OF A PLAIN VALUE
-- ============================================================================

local function Read(text) return U.parseMissionFile(text, 'forms.lua') end

local function Value(src)
    local def, err = Read('RegisterMission({ v = ' .. src .. ' })')
    if not def then return nil, err end
    return def.v
end

do
    local forms = {
        -- strings: every escape of Lua 5.4
        { [['a\'b"c']], 'a\'b"c' },
        { [["\a\b\f\n\r\t\v\\\"\'"]], '\a\b\f\n\r\t\v\\"\'' },
        { [['\65\066\0067\255\0']], 'AB\0067\255\0' },
        { [['\x41\xfF\x00']], 'A\255\0' },
        {
            [['\u{48}\u{20AC}\u{10FFFF}\u{7FFFFFFF}\u{0000000041}']],
            'H\226\130\172\244\143\191\191\253\191\191\191\191\191A',
        },
        { '\'a\\z   \n\r\n  b\'', 'ab' },
        { '\'a\\\r\nb\\\nc\\\n\rd\'', 'a\nb\nc\nd' },
        { '[[\nfirst line break skipped]]', 'first line break skipped' },
        { '[==[\r\nx]]y]=]z]==]', 'x]]y]=]z' },
        { '[[a\r\nb\n\rc\rd\n\ne]]', 'a\nb\nc\nd\n\ne' },
        { '[[a\n\n\rb]]', 'a\n\nb' },
        { '[[a\r\r\nb]]', 'a\n\nb' },
        { '"caf\195\169 \226\130\172"', 'caf\195\169 \226\130\172' },
        -- numbers: integers, floats, hexadecimal, exponents, signs
        { '42', 42 },
        { '-42', -42 },
        { '- -7', 7 },
        { '3.0', 3.0 },
        { '-0.0', -0.0 },
        { '.5', 0.5 },
        { '5.', 5.0 },
        { '1e3', 1000.0 },
        { '2.5E-2', 0.025 },
        { '0x1F', 31 },
        { '0XfF', 255 },
        { '0x1p4', 16.0 },
        { '0xA.8p1', 21.0 },
        { '9223372036854775807', math.maxinteger },
        { '9223372036854775808', 9223372036854775808.0 },
        { '-0x8000000000000000', math.mininteger },
        { '0xffffffffffffffffff', -1 },
        { '1e999', math.huge },
        -- the rest
        { 'true', true },
        { 'false', false },
    }
    for _, f in ipairs(forms) do
        local got, err = Value(f[1])
        local d = {}
        Same(f[2], got, 'v', d)
        H.ok(err == nil and #d == 0,
            ('%s reads as Lua reads it: %s'):format(f[1]:gsub('[\r\n]', '|'), tostring(err or table.concat(d, '; '))))
        local ref = ByLua('RegisterMission({ v = ' .. f[1] .. ' })').v
        local d2 = {}
        Same(ref, got, 'v', d2)
        H.eq(#d2, 0, f[1]:gsub('[\r\n]', '|') .. ': and the same as Lua\'s own reading ' .. table.concat(d2, '; '))
    end

    local def = Read(table.concat({
        '\239\187\191-- a byte order mark (Windows editors) is skipped',
        '--[==[ a long',
        'comment ]==]',
        'RegisterMission { -- the call without ( )',
        '  id = \'forms\', ["with space"] = 1, [2] = \'two\', [true] = \'yes\', [1.5] = \'half\';',
        '  \'first\',',
        '  vec3 = 1, vector4 = 2, RegisterMission = 3, _x9 = nil, maybe = nil,',
        '  a = vec3(1, -2.5, 0x10), b = vector3(1.0, 2.0, 3.0), c = vec4(1, 2, 3, 4), d = vector4(-1, -2, -3, -4),',
        '  nested = { { { list = { 1, 2, 3, } } } },',
        '};',
    }, '\r\n'))
    H.ok(def ~= nil, 'a file in every form reads')
    def = def or {}
    H.eq(def.id, 'forms', 'name = value')
    H.eq(def['with space'], 1, '[\'text\'] = value')
    H.eq(def[1], 'first', 'a list entry')
    H.eq(def[2], 'two', '[2] = value')
    H.eq(def[true], 'yes', '[true] = value')
    H.eq(def[1.5], 'half', '[1.5] = value')
    H.eq(def.vec3, 1, 'a key may be called vec3')
    H.eq(def.vector4, 2, 'or vector4')
    H.eq(def.RegisterMission, 3, 'or RegisterMission')
    H.ok(getmetatable(def.a) == VMT and def.a.x == 1 and def.a.y == -2.5 and def.a.z == 16 and def.a.w == nil,
        'vec3(...) is the server\'s vector')
    H.ok(getmetatable(def.b) == VMT and def.b.z == 3.0, 'vector3(...) too')
    H.ok(getmetatable(def.c) == VMT and def.c.w == 4, 'vec4(...) has its w')
    H.ok(getmetatable(def.d) == VMT and def.d.w == -4, 'vector4(...) too')
    H.eq(def.nested and def.nested[1][1].list[3], 3, 'nested tables with a trailing comma')
    local refDef = ByLua(table.concat({ 'RegisterMission { [1.5] = 1, x = nil, nil, 2 }' }))
    local d = {}
    Same(refDef, Read('RegisterMission { [1.5] = 1, x = nil, nil, 2 }'), 'nils', d)
    H.eq(#d, 0, 'nil values leave no key, as in Lua ' .. table.concat(d, '; '))
end

-- ============================================================================
--          5. RANDOM DATA, WRITTEN SEVERAL WAYS, READ AS LUA READS IT
-- ============================================================================

local rng = U.rng(20261014)
local function RandString()
    local out = {}
    for _ = 1, rng:int(0, 12) do out[#out + 1] = string.char(rng:int(0, 255)) end
    return table.concat(out)
end
local function RandNumber()
    local k = rng:int(1, 7)
    if k == 1 then return rng:int(-100000, 100000) end
    if k == 2 then return rng:int(-100000, 100000) / 100 end
    if k == 3 then return rng:int(0, 1000) + 0.0 end
    if k == 4 then return math.maxinteger - rng:int(0, 3) end
    if k == 5 then return rng:int(1, 1000) * 1e-7 end
    if k == 6 then return math.mininteger + rng:int(0, 3) end
    return -0.0
end
local function RandValue(depth)
    local k = rng:int(1, depth > 4 and 5 or 7)
    if k == 1 then return RandString() end
    if k == 2 or k == 3 then return RandNumber() end
    if k == 4 then return rng:int(0, 1) == 1 end
    if k == 5 then return vec3(RandNumber() + 0.0, RandNumber() + 0.0, RandNumber() + 0.0) end
    local t = {}
    for i = 1, rng:int(0, 4) do t[i] = RandValue(depth + 1) end
    for _ = 1, rng:int(0, 4) do t['k' .. rng:int(1, 50)] = RandValue(depth + 1) end
    if rng:int(1, 4) == 1 then t[RandString()] = RandValue(depth + 1) end
    return t
end
local BREAKS = { '\n', '\r\n', '\n\r', '\r', '\n\n\r', '\r\r\n' }
local Write
local function Str(s, style)
    if style == 1 then return ('%q'):format(s) end
    if style == 2 then
        return '\'' .. s:gsub('[%c\\\'\128-\255]', function(c) return ('\\%03d'):format(c:byte()) end) .. '\''
    end
    if style == 3 then
        return '"' .. s:gsub('[%c\\"\128-\255]', function(c) return ('\\x%02X'):format(c:byte()) end) .. '"'
    end
    if not s:find('[\r\n%]]') then return '[==[' .. BREAKS[rng:int(1, #BREAKS)] .. s .. ']==]' end
    return ('%q'):format(s)
end
Write = function(v, style)
    local t = type(v)
    if t == 'string' then return Str(v, style) end
    if t == 'number' then
        if math.type(v) == 'integer' then
            if v == math.mininteger then return '-0x8000000000000000' end
            return ('%d'):format(v)
        end
        if v == 0 and 1 / v < 0 then return '-0.0' end
        return (('%.17g'):format(v):gsub('^(%-?%d+)$', '%1.0'))
    end
    if t == 'boolean' then return tostring(v) end
    if getmetatable(v) == VMT then return ('vec3(%s, %s, %s)'):format(Write(v.x), Write(v.y), Write(v.z)) end
    local parts = {}
    for i = 1, #v do parts[#parts + 1] = Write(v[i], style) end
    for k, x in pairs(v) do
        if not (math.type(k) == 'integer' and k >= 1 and k <= #v) then
            local key = (type(k) == 'string' and k:match('^k%d+$')) and k or ('[ ' .. Write(k, style) .. ' ]')
            parts[#parts + 1] = key .. ' = ' .. Write(x, style)
        end
    end
    local sep = ({ ', ', ';\n', ' , ', ',\r\n  -- note\r\n' })[style]
    return '{' .. table.concat(parts, sep) .. ((style == 2 and #parts > 0) and ',' or '') .. '}'
end

do
    local bad, n = {}, 0
    for i = 1, 400 do
        local value = RandValue(1)
        if type(value) ~= 'table' or getmetatable(value) then value = { value } end
        local style = (i % 4) + 1
        local text = ('--[[ header %d ]]\n-- a comment\nRegisterMission(%s)\n'):format(i, Write(value, style))
        local def, err = U.parseMissionFile(text, 'fuzz.lua')
        n = n + 1
        if not def then
            bad[#bad + 1] = 'refused: ' .. tostring(err)
        else
            local d = {}
            Same(ByLua(text), def, 'v', d)
            if #d > 0 then bad[#bad + 1] = table.concat(d, '; ') end
        end
    end
    H.eq(#bad, 0, ('%d random files read exactly as Lua reads them %s'):format(n, table.concat(bad, ' | '):sub(1, 600)))
end

-- ============================================================================
--       6. TEXT THAT IS NOT PLAIN DATA IS REFUSED AT ONCE, WITH ITS LINE
-- ============================================================================

local function Globals()
    local g = {}
    for k in pairs(_G) do g[k] = true end
    return g
end

do
    local before = Globals()
    local refused = {
        -- code of any kind
        { 'while true do end\nRegisterMission({ id = "x" })', 1, 'while' },
        { 'RegisterMission({ id = ("x"):rep(2^31) })', 1, '(' },
        { 'RegisterMission({ id = string.rep("x", 2^31) })', 1, 'string' },
        { 'local s = "x" for i = 1, 40 do s = s .. s end RegisterMission({ id = s })', 1, 'local' },
        { 'RegisterMission({ id = ("a"):rep(30000):find(".-.-.-.-.-.-.-.-b") })', 1, '(' },
        { 'RegisterMission(setmetatable({}, { __index = function() while true do end end }))', 1, 'setmetatable' },
        { 'RegisterMission({\n  id = "x",\n  f = function() end,\n})', 3, 'function' },
        { 'RegisterMission({ id = "x" .. "y" })', 1, '.' },
        { 'RegisterMission({\n\n  timeLimit = 10 * 60,\n})', 3, '*' },
        { 'RegisterMission({ id = x })', 1, 'x' },
        { 'RegisterMission({ id = os.exit(1) })', 1, 'os' },
        { 'getmetatable("").__index = {} RegisterMission({ id = "x" })', 1, 'getmetatable' },
        { 'RegisterMission({ id = "x" })\ncollectgarbage("stop")', 2, 'collectgarbage' },
        { 'RegisterMission({ id = "x" }) return', 1, 'return' },
        { 'RegisterMission({ id = -"5" })', 1, '"5"' },
        { 'RegisterMission({ id = "x", c = { [{}] = 1 } })', 1, nil },
        -- CfxLua's own syntax (FACTS L7), which lua5.4 cannot even parse
        { 'RegisterMission({ id = `joaat` })', 1, '`' },
        { 'RegisterMission({ id = 3 /* c comment */ })', 1, '/' },
        { 'RegisterMission({ id = t?.x })', 1, 't' },
        { 'RegisterMission({ id = "x" })\na += 1', 2, 'a' },
        { 'local a, b in t\nRegisterMission({ id = "x" })', 1, 'local' },
        { 'RegisterMission({ .a, .b })', 1, '.' },
        { 'RegisterMission({ id = each(t) })', 1, 'each' },
        -- not a mission file
        { 'RegisterMission({ id = "x", c = vec3(1, 2) })', 1, ')' },
        { 'RegisterMission({ id = "x", c = vec3(1, 2, 3, 4) })', 1, ',' },
        { 'RegisterMission({ id = "x", c = vec3("1", 2, 3) })', 1, '"1"' },
        { 'RegisterMission({ id = "x", c = vec2(1, 2) })', 1, 'vec2' },
        { 'RegisterMission({ id = "x", c = vec3 })', 1, '}' },
        { 'RegisterMission({\n  id = "x",\n  id = "y",\n})', 3, nil },
        { 'RegisterMission({ [1] = "a", "b" })', 1, nil },
        { 'RegisterMission({ id = nil, id = 2 })', 1, nil },
        { 'RegisterMission({ id = "x" ', 1, '<eof>' },
        { 'RegisterMission({ id = [[ unfinished })', 1, '[[' },
        { 'RegisterMission({ id = "x" }) --[[ unfinished', 1, '[[' },
        { 'RegisterMission({ id = "x\n" })', 1, '"x' },
        { 'RegisterMission({ id = "\\q" })', 1, '\\q' },
        { 'RegisterMission({ id = "\\300" })', 1, '\\300' },
        { 'RegisterMission({ id = "\\xZZ" })', 1, '\\xZZ' },
        { 'RegisterMission({ id = "\\u{80000000}" })', 1, '\\u{80000000}' },
        { 'RegisterMission({ id = "x" }, 2)', 1, ',' },
        { 'RegisterMission({ [nil] = 1 })', 1, nil },
        { 'RegisterMission({ id = 0x })', 1, '0x' },
        { 'RegisterMission({ id = 1e })', 1, '1e' },
        { 'RegisterMission({ id = 3x })', 1, '3x' },
        { 'RegisterMission({ id = 1..2 })', 1, '1..2' },
        { 'RegisterMission({ id = inf })', 1, 'inf' },
        { 'RegisterMission({ end = 1 })', 1, 'end' },
        { 'RegisterMission({ true = 1 })', 1, '=' },
        { 'RegisterMission({ , })', 1, ',' },
        { 'RegisterMission { id = "x" } { id = "y" }', 1, '{' },
        { '\n\n\nRegisterMission {\n  id = "\\195\\169" .. \'x\',\n}', 5, '.' },
        { '#!/bin/lua\nRegisterMission({})', 1, '#' },
        { 'RegisterMission({ id = "x" })\0', 1, '<\\0>' },
        { 'return { id = "x" }', 1, 'return' },
        { string.rep('{', 100000), 1, '{' },
        { 'RegisterMission(' .. string.rep('{', 100000) .. ')', 1, '{' },
        { 'RegisterMission({ ' .. string.rep('x', 5000) .. ' })', 1, string.rep('x', 40) .. '...' },
    }
    for i, c in ipairs(refused) do
        local text, line, near = c[1], c[2], c[3]
        local t0 = os.clock()
        local def, err = U.parseMissionFile(text, 'import.lua')
        local s = os.clock() - t0
        err = tostring(err)
        local where = ('import.lua:%d:'):format(line)
        H.ok(def == nil and err:find(where, 1, true) ~= nil and s < 1,
            ('refused %d in %.3f s at line %d: %s'):format(i, s, line, err:sub(1, 160)))
        if near then H.ok(err:find('near \'' .. near, 1, true) ~= nil, ('refused %d near \'%s\''):format(i, near)) end
        H.ok(#err < 400, ('refused %d: the message stays short (%d bytes)'):format(i, #err))
    end
    for _, c in ipairs({
        { 'RegisterMission({ id = "x" }); RegisterMission({ id = "y" })', 'exactly one call is allowed' },
        { 'RegisterMission("x")', 'RegisterMission expects a table' },
        { 'RegisterMission()', 'RegisterMission expects a table' },
        { 'RegisterMission(nil)', 'RegisterMission expects a table' },
        { 'RegisterMission(vec3(1, 2, 3))', 'RegisterMission expects a table' },
        { '-- only a comment\n;;', 'never calls RegisterMission' },
        { '', 'the file is empty' },
    }) do
        local def, err = U.parseMissionFile(c[1], 'import.lua')
        H.ok(def == nil and tostring(err):find(c[2], 1, true) ~= nil, 'refused: ' .. tostring(err))
    end
    H.eq(U.parseMissionFile(nil, 'x.lua'), nil, 'no text: refused')
    H.eq(U.parseMissionFile(42, 'x.lua'), nil, 'a number: refused')
    local okR, errR = U.readMissionReturn('return { \'a\' }\nprint("x")', 'index.lua')
    H.ok(okR == nil and tostring(errR):find('index.lua:2:', 1, true) ~= nil, 'index.lua: nothing may follow the list')
    local okR2, errR2 = U.readMissionReturn('local t = {} return t', 'index.lua')
    H.ok(okR2 == nil and tostring(errR2):find('index.lua:1:', 1, true) ~= nil, 'index.lua: no code either')

    H.eq(('abc'):find('b', 1, true), 2, 'string methods untouched')
    H.eq(getmetatable('').__index, string, 'the string metatable is untouched')
    H.eq(collectgarbage('isrunning'), true, 'the GC still runs')
    local added = {}
    for k in pairs(_G) do if not before[k] then added[#added + 1] = tostring(k) end end
    H.eq(#added, 0, 'no global was made: ' .. table.concat(added, ', '))
end

-- ============================================================================
--                    7. BOUNDED: SIZE, VALUES, DEPTH, TIME
-- ============================================================================

do
    local lim = U.missionFileLimits
    H.ok(lim and lim.bytes >= 22 * 23070 and lim.values >= 5 * 20000 and lim.depth >= 3 * 10,
        'the caps sit far above every shipped file and the Builder\'s own limits')
    local huge = 'RegisterMission({ id = "' .. string.rep('x', lim.bytes) .. '" })'
    local t0 = os.clock()
    local def, err = U.parseMissionFile(huge, 'big.lua')
    H.ok(def == nil and tostring(err):find('larger than ' .. lim.bytes .. ' bytes', 1, true) and os.clock() - t0 < 0.1,
        'text over the size cap is not read at all: ' .. tostring(err))

    local many = 'RegisterMission({ ' .. string.rep('1,', lim.values) .. ' })'
    t0 = os.clock()
    def, err = U.parseMissionFile(many, 'many.lua')
    H.ok(def == nil and tostring(err):find('more than ' .. lim.values .. ' values', 1, true) and os.clock() - t0 < 2,
        ('more values than the cap: refused in %.2f s: %s'):format(os.clock() - t0, tostring(err)))

    local deep = 'RegisterMission(' .. string.rep('{', lim.depth) .. string.rep('}', lim.depth) .. ')'
    H.ok(U.parseMissionFile(deep, 'deep.lua') ~= nil, ('%d tables deep reads'):format(lim.depth))
    local deeper = 'RegisterMission(' .. string.rep('{', lim.depth + 1) .. string.rep('}', lim.depth + 1) .. ')'
    def, err = U.parseMissionFile(deeper, 'deep.lua')
    H.ok(def == nil and tostring(err):find('nested more than ' .. lim.depth, 1, true), 'one deeper is refused')

    local parts = {}
    for i = 1, 20000 do parts[i] = ('vec3(%d.25, -%d.5, 30.0)'):format(i, i) end
    local text = 'RegisterMission({ id = "big", points = { ' .. table.concat(parts, ', ') .. ' } })'
    H.ok(#text < lim.bytes, 'precondition: under the size cap (' .. #text .. ' bytes)')
    t0 = os.clock()
    def = U.parseMissionFile(text, 'big.lua')
    local s = os.clock() - t0
    H.ok(def and #def.points == 20000 and def.points[20000].y == -20000.5, '20,000 vectors read')
    H.ok(s < 2, ('%d bytes read in %.3f s'):format(#text, s))
    local comments = string.rep('--[[ c\n]]', 40000) .. string.rep('-- x\r\n', 40000) .. 'RegisterMission({ id = "c" })'
    t0 = os.clock()
    def = U.parseMissionFile(comments, 'comments.lua')
    H.ok(def and def.id == 'c' and os.clock() - t0 < 2,
        ('%d bytes of comments read in %.3f s'):format(#comments, os.clock() - t0))
    def, err = U.parseMissionFile(comments .. '\nx', 'comments.lua')
    H.ok(def == nil and tostring(err):find('comments.lua:' .. (2 * 40000 + 2) .. ':', 1, true),
        'the line count after them is right: ' .. tostring(err))
end

-- ============================================================================
--                              8. A REFUSED FILE
-- ============================================================================
-- THE CONSOLE AND THE ADMIN UI LOAD RESULT NAME THE LINE.

do
    local ID = 'bomb_disposal'
    local PATH = 'missions/builtin/' .. ID .. '.lua'
    local good = X.read(PATH)
    local lines = {}
    for l in (good .. '\n'):gmatch('(.-)\n') do lines[#lines + 1] = l end
    local at
    for i, l in ipairs(lines) do
        if l:match('^%s*timeLimit%s*=') then
            at = i
            lines[i] = l:gsub('=%s*[^,]+', '= 10 * 60', 1)
            break
        end
    end
    H.ok(at ~= nil, 'precondition: ' .. PATH .. ' has a timeLimit line')
    local broken = table.concat(lines, '\n')
    local realLoad = LoadResourceFile
    _G.LoadResourceFile = function(res, path)
        if path == PATH then return broken end
        return realLoad(res, path)
    end
    local first = #X.lines
    local sum = CP.Missions.reload()
    local failed
    for _, f in ipairs(sum.failed or {}) do if f.id == ID then failed = f end end
    local where = ('%s:%d:'):format(PATH, at or 0)
    H.ok(failed and tostring(failed.error):find(where, 1, true) ~= nil,
        'the load result names the file and the line: ' .. tostring(failed and failed.error))
    local warned, counted = false, false
    for i = first + 1, #X.lines do
        local l = X.lines[i]
        if l:find(where, 1, true) and l:find(ID, 1, true) then warned = true end
        if l:find('missions loaded: 18 built-in (0 edited), 0 custom, 1 rejected', 1, true) then counted = true end
    end
    H.ok(warned, 'the console line names the file and the line')
    H.ok(counted, 'the start line counts it: 18 built-in, 1 rejected')
    local view = X.cb('admin:getMissionLoad', 5, {})
    local shown
    for _, f in ipairs(view and view.failed or {}) do if f.id == ID then shown = f.error end end
    H.ok(shown and tostring(shown):find(where, 1, true) ~= nil,
        'Admin UI -> Missions -> Load result shows it: ' .. tostring(shown))
    local plain
    for _, f in ipairs(view and view.failed or {}) do if f.id == ID then plain = f.reason end end
    H.eq(plain, CP.L('missions.reason.unreadable'), 'and the catalog\'s plain reason: a typo or code in the file')
    _G.LoadResourceFile = realLoad
    sum = CP.Missions.reload()
    H.eq(#(sum.failed or {}), 0, 'the file fixed: nothing rejected')
    H.ok(CP.Missions.get(ID) ~= nil, ID .. ' plays again')
end

-- ============================================================================
--                   9. THE REFUSAL TEXTS IN PLAIN WORDS (A6)
-- ============================================================================
-- The catalog greys a file that did not load and gives this reason; Show the problem keeps the raw text.

do
    local cases = {
        { 'timeLimit must be 60 to 3600 seconds', 'missions.reason.time_limit', 'Time limit must be 1 to 60 minutes.' },
        {
            'startTimeout must be 60 to 3600 seconds',
            'missions.reason.start_timeout',
            'The time to start must be 1 to 60 minutes.',
        },
        { 'cooldown must be 0 to 86400 seconds', 'missions.reason.cooldown', 'Cooldown must be 0 to 24 hours.' },
        { 'label is missing', 'missions.reason.label', 'The mission has no name.' },
        {
            'type "heist" is not a key of Config.MissionTypes',
            'missions.reason.type',
            'The mission type "heist" does not exist on this server.',
        },
        {
            'minOfficers/maxOfficers must be whole numbers with 1 <= min <= max <= 4',
            'missions.reason.officers',
            'Officers must be whole numbers from 1 to 4, the minimum not above the maximum.',
        },
        { 'difficulty must be 1 to 3 stars', 'missions.reason.difficulty', 'Difficulty must be 1 to 3 stars.' },
        {
            'quietPatrol must be true or false',
            'missions.reason.on_off',
            'quietPatrol must be on or off (true or false).',
        },
        {
            'location 2 has no start = { coords = vec3(...), radius = n }',
            'missions.reason.no_start',
            'Location 2 has no start point.',
        },
        {
            'location 3 (Docks): start is inside the no-build zone "Mission Row PD"',
            'missions.reason.no_build',
            'Location 3 (Docks) is inside the no-build zone "Mission Row PD".',
        },
        {
            'objective 1 uses unknown block "fly"',
            'missions.reason.unknown_block',
            'Objective 1 uses the block "fly", which this server does not have.',
        },
        {
            'objective 2 (arrest), location 1 (Docks): too many peds',
            'missions.reason.objective_location',
            'Objective 2 (arrest) at location 1: too many peds',
        },
        { 'file not found', 'missions.reason.no_file', 'The mission file is missing.' },
        {
            'its id "a" does not match the file name',
            'missions.reason.id_mismatch',
            'The id inside the file ("a") does not match the file name.',
        },
        {
            'another mission already uses this id',
            'missions.reason.duplicate',
            'Another mission already uses this id.',
        },
        {
            '@missions/custom/x.lua:7: a function is not data',
            'missions.reason.unreadable',
            'The file has a typo or code in it, so it cannot be read as mission data.',
        },
        {
            'something new',
            'missions.reason.other',
            'The mission loader refused this file. Show the problem has the details.',
        },
    }
    for _, c in ipairs(cases) do
        H.ok(CP.Locale.has(c[2]), c[2] .. ' is a locale key')
        H.eq(CP.Missions.plainReason(c[1]), c[3], c[1] .. ' -> ' .. c[2])
    end
end

X.cleanup()
return H
