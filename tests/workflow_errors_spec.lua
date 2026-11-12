-- Easy to understand (docs/dev/WORKFLOWS.md): every error an officer, a supervisor or an admin meets on

-- Easy to understand (docs/dev/WORKFLOWS.md): every error an officer, a supervisor or an admin meets on
-- the common workflows (accept, unit, Dispatch, the run, Review Queue, the supervisor dialogs; Backups, Storage copy,
-- Corrections, Settings) says what went wrong and what to do next, in the merged locales/en.json and in every
-- locales/parts file that carries the key. Every err.* text of the merged file is also a full sentence (never an id), and every one the
-- player can act on says what to do; NOTHING_TO_DO lists the few where nobody can (a feature switched off). Plain Lua.

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
    -- step WF3: the Admin workflows (Backups, Storage copy, Corrections, Settings)
    'err.backup_protected',
    'err.backup_unknown',
    'err.confirm_mismatch',
    'err.not_left_behind',
    'err.storage_same',
    'err.export_write',
    'err.already_voided',
    'err.not_voided',
    'err.nothing_to_void',
    'err.row_not_found',
    'err.invalid_row',
    'err.not_participant',
    'err.officer_not_retired',
    'err.officer_retired',
    'err.adjust_daily_limit',
    'err.batch_restored',
    'err.batch_unknown',
    'err.once_a_day',
    'err.setting_check',
    'err.setting_json',
    'err.history_unknown',
    'err.import_format',
    'err.import_nothing',
    'err.setting_required',
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

-- Every err.* text (FX2): a full sentence that says what went wrong, never just an id, and, where the player can act,
-- what to do. A text says what to do when it starts with an instruction, has a second sentence, or a clause after a
-- colon, a semicolon or ", so". NOTHING_TO_DO holds the texts where the player has nothing to do (a feature
-- switched off, nothing waiting).
local NOTHING_TO_DO = {
    ['err.bounty_disabled'] = true,
    ['err.builder_disabled'] = true,
    ['err.commendations_off'] = true,
    ['err.crimtab_off'] = true,
    ['err.dispute_final'] = true,
    ['err.fto_off'] = true,
    ['err.live_case_off'] = true,
    ['err.live_join_off'] = true,
    ['err.mc_disabled'] = true,
    ['err.nothing_pending'] = true,
    ['err.op_disabled'] = true,
    ['err.op_none'] = true,
    ['err.rewards_off'] = true,
    ['err.training_off'] = true,
    ['err.unit_ready_none'] = true,
}
local VERB_LIST = [[
Enter Pick Stand Load Detain Reach Open Restore Tick Keep Close Finish Place Drive Wait Try Ask
Use Add Turn Set Choose Type Remove Move Go Refresh Get Switch Fill Give Make Check Select Save
Start End Leave Name Write Lower Raise Run Join Put Shorten Upload Test Take Publish Archive
Clear Contact Read Retry Approve Reload Rename Follow Fix Unretire Look Let Edit Plant Accept
]]
local VERBS = {}
for w in VERB_LIST:gmatch('%a+') do
    VERBS[w] = true
end

local function FullSentence(key, text)
    if type(text) ~= 'string' or text == key or text:find('err.', 1, true) then return false end
    local words = 0
    for _ in text:gmatch('%S+') do words = words + 1 end
    return words >= 3 and text:find('^[%u%d"\'{(]') ~= nil and text:find('[%.!?]$') ~= nil
end

local function SaysWhatToDo(text)
    if VERBS[text:match('^(%a+)') or ''] then return true end
    return text:find('[%.!?] %S') ~= nil or text:find('[:;] %S') ~= nil or text:find(', so ', 1, true) ~= nil
end

local errKeys = {}
for k in pairs(en) do
    if k:find('^err%.') then errKeys[#errKeys + 1] = k end
end
table.sort(errKeys)
H.ok(#errKeys >= 600, 'every err.* text is checked (' .. #errKeys .. ')')
local notFull, noStep = {}, {}
for _, k in ipairs(errKeys) do
    if not FullSentence(k, en[k]) then notFull[#notFull + 1] = k .. ' = ' .. tostring(en[k]) end
    if not NOTHING_TO_DO[k] and not SaysWhatToDo(en[k] or '') then
        noStep[#noStep + 1] = k .. ' = ' .. tostring(en[k])
    end
end
H.eq(table.concat(notFull, '\n'), '', 'every err.* text is a full sentence, not just an id')
H.eq(table.concat(noStep, '\n'), '', 'every err.* text the player can act on says what to do')
for k in pairs(NOTHING_TO_DO) do
    H.ok(en[k] ~= nil, k .. ' (nothing to do) still exists')
end

return H
