-- Easy to understand (step WF2, docs/WORKFLOWS.md): every error an officer or a supervisor meets on the common
-- workflows (accept, unit, Dispatch, the run, Review Queue, the supervisor dialogs) says what went wrong and what to do
-- next, in the merged locales/en.json and in every locales/parts file that carries the key. Plain Lua, no stubs.

local H = dofile('tests/harness.lua')
local cjson = require('cjson')

local function Read(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return s
end

-- The keys: the err.* texts the Officer and Supervisor workflows show that used to end without a next step.
local KEYS = {
    'err.already_on_run',
    'err.busy',
    'err.invalid_mission',
    'err.invalid_payload',
    'err.invalid_run',
    'err.mc_gone',
    'err.mc_not_open',
    'err.mc_taken_by',
    'err.mc_excluded',
    'err.mc_unknown_area',
    'err.member_on_call',
    'err.member_on_run',
    'err.member_unavailable',
    'err.no_members',
    'err.no_permission',
    'err.no_response',
    'err.not_on_run',
    'err.on_call',
    'err.op_not_enough',
    'err.op_active',
    'err.op_reason_required',
    'err.reason_required',
    'err.refused',
    'err.run_not_active',
    'err.timeout',
    'err.unit_full',
    'err.unit_gone',
    'err.unit_invite_expired',
    'err.unit_invite_locked',
    'err.unit_locked',
    'err.unit_no_invite',
    'err.unit_none',
    'err.unit_not_leader',
    'err.unit_target_on_run',
    'err.unit_target_unavailable',
    'err.unknown_mission',
    'err.happy_hour_running',
    'err.mission_ban_none',
}

-- A next step: a text that is itself the instruction ("Enter a reason ..."), a second sentence, or a clause after a
-- colon or a comma ("..., so there is nothing to lift").
local function HasNextStep(text)
    if type(text) ~= 'string' then return false end
    if text:find('^Enter ') or text:find('^Pick ') then return true end
    local first = text:find('[%.:!?] %u') or text:find(', so ', 1, true)
    return first ~= nil
end

local en = cjson.decode((assert(Read(H.root .. 'locales/en.json'), 'locales/en.json exists')))
for _, k in ipairs(KEYS) do
    H.ok(HasNextStep(en[k]), k .. ' says what to do next (' .. tostring(en[k]) .. ')')
end

-- each parts file that carries one of the keys has the same text as the merged file
local parts = io.popen('ls ' .. H.root .. 'locales/parts/*.json')
local seen = 0
for path in parts:lines() do
    local d = cjson.decode((assert(Read(path), path)))
    for _, k in ipairs(KEYS) do
        if d[k] ~= nil then
            seen = seen + 1
            H.eq(d[k], en[k], path:match('[^/]+$') .. ': ' .. k .. ' matches locales/en.json')
        end
    end
end
parts:close()
H.ok(seen >= #KEYS, 'every key is in a locales/parts file')

return H
