-- Frame loops read cache.ped (skill check K19): every while loop that can wait 0 ms in the block clients, the run
-- client and the builder client reads the player's ped from ox_lib's cache, not PlayerPedId() each frame.

local H = dofile('tests/harness.lua')

local function ReadAll(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return s
end

-- ============================================================================
--                                     CODE
-- ============================================================================
-- Comments and string contents are blanked first (newlines kept), as in tests/globals_lint_spec.lua.

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

-- Every while loop of the code, condition and body: { line, text }. Blocks are counted by their keywords (function,
-- do, then and repeat open one; end and until close one; elseif closes the then before it).
local OPENS = { ['function'] = true, ['do'] = true, ['then'] = true, ['repeat'] = true }
local function WhileLoops(code)
    local loops, stack, pending = {}, {}, nil
    for pos, word in code:gmatch('()%f[%w_]([%a_][%w_]*)') do
        if word == 'while' then
            pending = pos
        elseif OPENS[word] then
            stack[#stack + 1] = { from = word == 'do' and pending or nil }
            if word == 'do' then pending = nil end
        elseif word == 'end' or word == 'until' or word == 'elseif' then
            local top = table.remove(stack)
            if top and top.from then
                loops[#loops + 1] = { LineAt(code, top.from), code:sub(top.from, pos + #word - 1) }
            end
        end
    end
    return loops, #stack
end

-- A loop that can wait 0 ms: Wait(0), a sleep set to 0, or Wait(x and 0 or n).
local function FrameLoop(text)
    return text:find('Wait%(%s*0%s*%)') or text:find('sleep%s*=%s*0%f[^%w_.]') or text:find('Wait%([^()]-and%s+0%s+or')
end

-- ============================================================================
--                                    CHECKS
-- ============================================================================

-- the files, and how many of their frame loops read cache.ped
local FILES = {
    ['blocks/flee_arrest/client.lua'] = 1,
    ['blocks/protect_rescue/client.lua'] = 1,
    ['blocks/escort/client.lua'] = 1,
    ['blocks/process_scene/client.lua'] = 1,
    ['blocks/search_area/client.lua'] = 1,
    ['blocks/skill_check/client.lua'] = 1,
    ['blocks/interact_points/client.lua'] = 1,
    ['blocks/checkpoint_route/client.lua'] = 1,
    ['modules/runs/client.lua'] = 1,
    -- placement, recording, the drive test's approach, clear, drive and stop loops
    ['modules/builder/client.lua'] = 6,
}

local names = {}
for rel in pairs(FILES) do names[#names + 1] = rel end
table.sort(names)
for _, rel in ipairs(names) do
    local text = ReadAll(H.root .. rel)
    H.ok(text ~= nil, rel .. ' is read')
    local loops, open = WhileLoops(CodeOnly(text or ''))
    H.eq(open, 0, rel .. ': every block is closed (the scan read the whole file)')
    local frames, cached = 0, 0
    for _, loop in ipairs(loops) do
        local line, body = loop[1], loop[2]
        if FrameLoop(body) then
            frames = frames + 1
            H.ok(not body:find('%f[%w_]PlayerPedId%s*%('),
                ('%s:%d: the frame loop reads cache.ped, not PlayerPedId()'):format(rel, line))
            if body:find('%f[%w_]cache%.ped%f[^%w_]') then cached = cached + 1 end
        end
    end
    H.ok(frames >= 1, ('%s: its frame loops are found (%d)'):format(rel, frames))
    H.ok(cached >= FILES[rel], ('%s: %d frame loops read cache.ped (at least %d)'):format(rel, cached, FILES[rel]))
end

-- the scan itself: nested loops, elseif, repeat and functions inside a loop, comments and strings
do
    local probe = table.concat({
        'while a do',                                        -- 1: frame loop (its inner loop waits 0)
        '    if b then x() elseif c then y() else z() end',
        '    local f = function() return PlayerPedId() end',
        '    while d do Wait(0) end',                        -- 4
        '    repeat Wait(10) until e',
        'end',
        'while g do Wait(500) local p = PlayerPedId() end',  -- 7: not a frame loop
        '-- while h do Wait(0) end',
        'print(\'while i do Wait(0) end\')',
        'while j do local sleep = 0 Wait(sleep) end',        -- 10
        'while k do Wait(drew and 0 or 750) end',            -- 11
        'while l do local sleep = 0.5 Wait(sleep) end',      -- 12: not a frame loop
    }, '\n')
    local loops, open = WhileLoops(CodeOnly(probe))
    local lines, frames = {}, {}
    for _, loop in ipairs(loops) do
        lines[#lines + 1] = loop[1]
        if FrameLoop(loop[2]) then frames[#frames + 1] = loop[1] end
    end
    table.sort(lines)
    table.sort(frames)
    H.eq(open, 0, 'the probe closes every block')
    H.eq(table.concat(lines, ','), '1,4,7,10,11,12', 'the scan finds every while loop and none in a comment or string')
    H.eq(table.concat(frames, ','), '1,4,10,11', 'the frame loops are the ones that can wait 0 ms')
end

return H
