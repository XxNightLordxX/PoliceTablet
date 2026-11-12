-- Loop census (docs/dev/LOOPS.md "Loop census"): every Lua file of Crimson-Police that starts a thread

-- Loop census (docs/dev/LOOPS.md "Loop census"): every Lua file of Crimson-Police that starts a thread
-- (CreateThread) or runs a `while true do`, and every web/src file that sets a timer (setTimeout, setInterval) or asks
-- for an animation frame, has a census row in docs/dev/LOOPS.md with the same counts. A new loop, or a removed one, fails
-- here until its row is written (and its five questions answered in the tables above the census).
-- CP_LOOP_CENSUS_PRINT=1 prints the rows the code needs.

local H = dofile('tests/harness.lua')

local function ReadAll(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return s
end

local function Blank(s) return (s:gsub('[^\n]', ' ')) end

-- Lua code without comments and string contents (as tests/frame_loops_spec.lua)
local function LuaCode(text)
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

-- TypeScript without // and /* */ comments (a // inside a string is rare in web/src and would only hide a count)
local function TsCode(text)
    text = text:gsub('/%*.-%*/', Blank)
    return (text:gsub('([^:])//[^\n]*', '%1'))
end

local function Count(code, pattern)
    local n = 0
    for _ in code:gmatch(pattern) do n = n + 1 end
    return n
end

local function Files(dir, find)
    local list = {}
    local p = assert(io.popen(('cd \'%s\' && find %s -type f | LC_ALL=C sort'):format(H.root, find)))
    for line in p:lines() do list[#list + 1] = (line:gsub('^%./', '')) end
    p:close()
    return list
end

-- ============================================================================
--                              WHAT THE CODE HAS
-- ============================================================================

local code = {}   -- [rel] = { a, b }
for _, rel in ipairs(Files(H.root, '. -name \'*.lua\' -not -path \'./web/*\'')) do
    local text = LuaCode(ReadAll(H.root .. rel) or '')
    local threads = Count(text, '%f[%w_]CreateThread%f[^%w_]')
    local forever = Count(text, '%f[%w_]while%s+true%s+do%f[^%w_]')
    if threads + forever > 0 then code[rel] = { threads, forever } end
end
local webFiles = Files(
    H.root,
    'web/src \\( -name \'*.ts\' -o -name \'*.tsx\' \\) -not -path \'web/src/mocks/*\''
        .. ' -not -name \'*.walk.ts\' -not -name \'*.test.ts\''
)
for _, rel in ipairs(webFiles) do
    local text = TsCode(ReadAll(H.root .. rel) or '')
    local timers = Count(text, '%f[%w_]setTimeout%s*%(') + Count(text, '%f[%w_]setInterval%s*%(')
    local frames = Count(text, '%f[%w_]requestAnimationFrame%s*%(')
    if timers + frames > 0 then code[rel] = { timers, frames } end
end
H.ok(code['modules/runs/runs.lua'] ~= nil and code['web/src/shared/hooks.ts'] ~= nil, 'the scan finds the code')

-- ============================================================================
--                              WHAT THE DOCS SAY
-- ============================================================================

local doc = ReadAll(H.root .. '../docs/dev/LOOPS.md') or ''
local census = doc:match('\n## Loop census.-\n(.*)$') or ''
H.ok(census ~= '', 'docs/dev/LOOPS.md has its "Loop census" section')
local rows = {}
for line in census:gmatch('[^\n]+') do
    local rel, a, b = line:match('^|%s*`([^`]+)`%s*|%s*(%d+)%s*|%s*(%d+)%s*|')
    if rel then
        H.ok(rows[rel] == nil, rel .. ': one census row')
        rows[rel] = { tonumber(a), tonumber(b) }
    end
end

-- ============================================================================
--                                    CHECKS
-- ============================================================================

local names = {}
for rel in pairs(code) do names[#names + 1] = rel end
table.sort(names)
if os.getenv('CP_LOOP_CENSUS_PRINT') then
    for _, rel in ipairs(names) do print(('| `%s` | %d | %d |'):format(rel, code[rel][1], code[rel][2])) end
end
for _, rel in ipairs(names) do
    local want, row = code[rel], rows[rel]
    H.ok(row ~= nil, rel .. ': has a census row in docs/dev/LOOPS.md')
    if row then
        H.ok(row[1] == want[1] and row[2] == want[2],
            ('%s: the census row says %d / %d, the code has %d / %d'):format(rel, row[1], row[2], want[1], want[2]))
    end
end
for rel in pairs(rows) do
    H.ok(code[rel] ~= nil, rel .. ': its census row names a file that still has a loop or timer')
end

-- the scan itself: comments and strings do not count, a real call does
do
    local probe = 'CreateThread(f) -- CreateThread(g)\nprint(\'while true do\')\nwhile true do Wait(1) end\n'
    local text = LuaCode(probe)
    H.eq(Count(text, '%f[%w_]CreateThread%f[^%w_]'), 1, 'probe: one CreateThread')
    H.eq(Count(text, '%f[%w_]while%s+true%s+do%f[^%w_]'), 1, 'probe: one while true')
    local ts = TsCode('setTimeout(a, 1); // setTimeout(b)\n/* setInterval(c) */ requestAnimationFrame(d);\n')
    H.eq(Count(ts, '%f[%w_]setTimeout%s*%('), 1, 'probe: one setTimeout')
    H.eq(Count(ts, '%f[%w_]setInterval%s*%('), 0, 'probe: a commented setInterval does not count')
end

return H
