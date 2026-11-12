-- Globals lint (skill check K20): no server or shared script names a local, loop variable or parameter source
-- (the event global; RegisterCommand's own signature aside), and no script writes the global _ or source.

local H = dofile('tests/harness.lua')

local function ReadAll(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return s
end

local function Shell(cmd)
    local p = io.popen(cmd .. ' 2>&1')
    local out = p:read('a')
    local ok = p:close()
    return ok, out
end

-- ============================================================================
--                                    FILES
-- ============================================================================
-- The scripts as fxmanifest.lua loads them: a plain path, dir/*.lua or dir/**/name (** is any folders, or none).

local function GlobPatterns(glob)
    local function conv(g)
        local p = g:gsub('[%^%$%(%)%%%.%[%]%+%-%?]', '%%%0')
        p = p:gsub('%*%*/', '\1'):gsub('%*', '[^/]*'):gsub('\1', '.+/')
        return '^' .. p .. '$'
    end
    local out = { conv(glob) }
    if glob:find('**/', 1, true) then out[2] = conv((glob:gsub('%*%*/', ''))) end
    return out
end

local allLua = {}
do
    local ok, out = Shell(('cd \'%s\' && find . -name \'*.lua\' -not -path \'*/node_modules/*\' | sort'):format(H.root))
    H.ok(ok, 'the resource folder lists')
    for line in out:gmatch('[^\n]+') do allLua[#allLua + 1] = (line:gsub('^%./', '')) end
end

local manifest = ReadAll(H.root .. 'fxmanifest.lua') or ''
local function Scripts(key)
    local out, seen = {}, {}
    for block in manifest:gmatch(key .. '%s*(%b{})') do
        for entry in block:gsub('%-%-[^\n]*', ''):gmatch('[\'"]([^\'"]+)[\'"]') do
            if entry:sub(1, 1) ~= '@' then
                local n = 0
                for _, pat in ipairs(GlobPatterns(entry)) do
                    for _, rel in ipairs(allLua) do
                        if rel:match(pat) then
                            n = n + 1
                            if not seen[rel] then
                                seen[rel] = true
                                out[#out + 1] = rel
                            end
                        end
                    end
                end
                H.ok(n > 0, ('%s entry %s matches a file'):format(key, entry))
            end
        end
    end
    return out
end

local serverSide = {}
for _, rel in ipairs(Scripts('shared_scripts')) do serverSide[#serverSide + 1] = rel end
for _, rel in ipairs(Scripts('server_scripts')) do serverSide[#serverSide + 1] = rel end
local clientSide = Scripts('client_scripts')
H.ok(#serverSide >= 40, ('the server and shared scripts are found (%d)'):format(#serverSide))
H.ok(#clientSide >= 20, ('the client scripts are found (%d)'):format(#clientSide))

-- ============================================================================
--                                    SOURCE
-- ============================================================================
-- Comments and string contents are blanked first (newlines kept, so positions keep their line numbers).

local function Blank(s) return (s:gsub('[^\n]', ' ')) end

local function CodeOnly(text)
    local out, i, n = {}, 1, #text
    while i <= n do
        local k = text:find('[%-%[\'"]', i) or (n + 1)
        out[#out + 1] = text:sub(i, k - 1)
        i = k
        local c = text:sub(i, i)
        local long = text:match('^%-%-%[(=*)%[', i) or text:match('^%[(=*)%[', i)
        if long then
            local open = text:sub(i, i + 1) == '--' and ('--[' .. long .. '[') or ('[' .. long .. '[')
            local close = ']' .. long .. ']'
            local e = text:find(close, i + #open, true) or n
            out[#out + 1] = Blank(text:sub(i, e + #close - 1))
            i = e + #close
        elseif text:sub(i, i + 1) == '--' then
            local e = text:find('\n', i, true) or (n + 1)
            out[#out + 1] = Blank(text:sub(i, e - 1))
            i = e
        elseif c == '\'' or c == '"' then
            local j = i + 1
            while j <= n and text:sub(j, j) ~= c and text:sub(j, j) ~= '\n' do
                j = j + (text:sub(j, j) == '\\' and 2 or 1)
            end
            out[#out + 1] = c .. Blank(text:sub(i + 1, j - 1)) .. c
            i = j + 1
        elseif i <= n then
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

local function LineAt(text, pos)
    local _, k = text:sub(1, pos):gsub('\n', '')
    return k + 1
end

local NAME = '%f[%w_]source%f[^%w_]'

-- Every place in one file's code that names a local, loop variable or parameter source: { line, what }.
local function SourceHits(code)
    local hits = {}
    for pos, names in code:gmatch('()%f[%w_]local%s+([%a_][%w_ \t,]*)') do
        if names:find(NAME) then hits[#hits + 1] = { LineAt(code, pos), 'local' } end
    end
    for pos, names in code:gmatch('()%f[%w_]for%s+([%a_][%w_ \t,]-)%f[%w_]in%f[^%w_]') do
        if names:find(NAME) then hits[#hits + 1] = { LineAt(code, pos), 'loop variable' } end
    end
    for pos, name in code:gmatch('()%f[%w_]for%s+([%a_][%w_]*)%s*=') do
        if name == 'source' then hits[#hits + 1] = { LineAt(code, pos), 'loop variable' } end
    end
    for pos, params in code:gmatch('()%f[%w_]function%s*[%w_.:]*%s*(%b())') do
        if params:find(NAME) then
            local before = code:sub(math.max(1, pos - 200), pos - 1):match('[^\n]*$')
            if not before:find('RegisterCommand%s*%(') then hits[#hits + 1] = { LineAt(code, pos), 'parameter' } end
        end
    end
    table.sort(hits, function(a, b) return a[1] < b[1] end)
    return hits
end

local shadowed = {}
for _, rel in ipairs(serverSide) do
    local text = ReadAll(H.root .. rel)
    if H.ok(text ~= nil, rel .. ' reads') then
        for _, h in ipairs(SourceHits(CodeOnly(text))) do
            shadowed[#shadowed + 1] = ('%s:%d (%s)'):format(rel, h[1], h[2])
        end
    end
end
H.eq(#shadowed, 0, 'no server or shared script shadows source: ' .. table.concat(shadowed, ', '))

-- ============================================================================
--                                GLOBAL WRITES
-- ============================================================================
-- luac5.4 -l -l lists every global write as SETTABUP ... ; _ENV "name".

local function GlobalWrites(listing)
    local out = {}
    for line in (listing .. '\n'):gmatch('([^\n]*)\n') do
        local at = line:match('%[(%d+)%]%s+SETTABUP%s')
        local name = at and (line .. ' '):match('; _ENV "([%w_]+)"%s')
        if name == '_' or name == 'source' then out[#out + 1] = { tonumber(at), name } end
    end
    return out
end

local haveLuac = Shell('command -v luac5.4')
if H.ok(haveLuac, 'luac5.4 is installed (the gate\'s syntax step needs it too)') then
    local written = {}
    local every = {}
    for _, rel in ipairs(serverSide) do every[#every + 1] = rel end
    for _, rel in ipairs(clientSide) do every[#every + 1] = rel end
    for _, rel in ipairs(every) do
        local ok, out = Shell(('luac5.4 -p -l -l \'%s%s\''):format(H.root, rel))
        if H.ok(ok, rel .. ' lists with luac5.4') then
            for _, w in ipairs(GlobalWrites(out)) do written[#written + 1] = ('%s:%d (%s)'):format(rel, w[1], w[2]) end
        end
    end
    H.eq(#written, 0, 'no script writes the global _ or source: ' .. table.concat(written, ', '))

    -- the lint itself: the old banned-words line is found, a local _ is not
    local _, probe = Shell(
        'printf \'%s\\n\' \'local function f() return 1, 2, 3 end\' \'local w\' \'_, _, w = f()\''
            .. ' \'local _, x = f()\' | luac5.4 -p -l -l -'
    )
    local hits = GlobalWrites(probe)
    H.eq(#hits, 2, 'a global _ write is found once per _ (and a local _ is not)')
    H.eq(hits[1] and hits[1][1], 3, 'the write is found on its line')
end

-- the lint itself: every kind of source name is found; RegisterCommand, comments, strings and fields are not
do
    local probe = table.concat({
        'local source = 1',
        'local a, source<const> = 1, 2',
        'for _, source in ipairs(t) do end',
        'for source = 1, 2 do end',
        'local function F(x, source) end',
        'CP.Net.action(\'x\', function(',
        '    src, source)',
        'end)',
        'RegisterCommand(name, function(source, args) end, false)',
        '-- local source = 2',
        'print(\'local source = 3\', "function(source)")',
        '--[[ local source',
        ']] local sourceName, c = t.source, cache.source',
        'local x = source',
    }, '\n')
    local lines = {}
    for _, h in ipairs(SourceHits(CodeOnly(probe))) do lines[#lines + 1] = h[1] end
    H.eq(table.concat(lines, ','), '1,2,3,4,5,6', 'the source lint finds lines 1-6 of the probe and nothing else')
end

return H
