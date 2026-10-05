-- CP.Settings (server): settings an admin changes in game (Admin UI → Settings and the mission switches), saved in
-- cp_settings over the values of config/config.lua and config/blocks.lua, and sent to every client.

CP.Settings = CP.Settings or {}
local Settings = CP.Settings
local U = CP.U
local TAG = 'settings'

local MAX_DEPTH = 8             -- nesting of one value
local MAX_ITEMS = 500           -- entries of one list or map
local MAX_NODES = 5000          -- values inside one setting
local MAX_STRING = 256          -- characters of one text
local MAX_JSON = 65536          -- bytes of a JSON text sent by the editor
local MAX_ABS = 1e9             -- a number further from 0 than this is a typo
local MAX_COORD = 100000.0      -- metres: a coordinate outside the map
local HISTORY_PAGE = 25
local RELOAD_DELAY_MS = 1000    -- one missions reload after a burst of changes
local LOAD_POLL_MS = 100

local FILES = {
    { name = 'config', path = 'config/config.lua' },
    { name = 'blocks', path = 'config/blocks.lua' },
}

-- The audit actions of this module (the Settings screen's history lists these).
local ACTIONS = {
    'settingChanged',
    'settingReset',
    'settingsResetAll',
    'missionSwitch',
    'locationSwitch',
    'missionSwitchesReset',
    'moneySwitch',
}

-- These can only change in config.lua: where the settings themselves are saved, and who is an admin (an admin
-- changing them in game could hand admin to anyone or lock every admin out).
-- The tablet title and the two command names are Hard rule names (a clash with another resource's command would make
-- the Admin UI unreachable). The call-id prefixes mirror sc-npcpolice's and sc-dispatch's formats. A bonus's each,
-- block and engineOnly describe what the code does: changing them can't change it.
local LOCKED = {
    ['Database.enabled'] = 'settings.locked.database',
    ['Database.folder'] = 'settings.locked.database',
    ['AdminAce'] = 'settings.locked.admin',
    ['QboxAdmins'] = 'settings.locked.admin',
    ['Tablet.title'] = 'settings.locked.names',
    ['Tablet.command'] = 'settings.locked.names',
    ['Tablet.adminCommand'] = 'settings.locked.names',
    ['Calls.npcCallPrefix'] = 'settings.locked.call_ids',
    ['Calls.ownRunCallPrefixes'] = 'settings.locked.call_ids',
    ['Bonuses.*.each'] = 'settings.locked.code_fact',
    ['Bonuses.*.block'] = 'settings.locked.code_fact',
    ['Bonuses.*.engineOnly'] = 'settings.locked.code_fact',
}

-- Turning one of these on needs the typed word ENABLE (payload.confirm), checked here too; every change is audited
-- and posts to the audit webhook. They all ship off.
local MONEY_SWITCHES = {
    'Cash.allowUnfundedRetry',
    'Cash.allowCapTopUp',
    'Cash.allowPayAgain',
    'Cash.restoreForfeited',
    'Cash.allowAddFunds',
    'Cash.allowClawback',
    'Cash.allowManualCash',
    'Rewards.allowTakeBack',
}
local MONEY_WORD = 'ENABLE'

-- Point values: a change applies to runs that end after it, and posts a notice to the flags webhook.
local POINTS = {
    'MissionTypes.*.points',
    'Bonuses.*.value',
    'Bonuses.*.kind',
    'Scoring.*',
    'Scoring.common.*',
    'Events.todMultiplier',
    'Events.modifierPoints',
    'Events.weeklyBoss.points',
    'CrossDepartmentPoints',
    'Difficulty.pointsByStars',
    'Scaling',
    'Goals.dailyPoints',
    'Goals.weeklyPoints',
    'Challenge.bountyBonus',
    'MissionCalls.rapidResponse.pctOfP',
}

-- Read once at start (commands, key mappings, desk zones, the locale, the day and week boundaries): a change is
-- saved now and used after the next start of Crimson-Police.
local RESTART = {
    'Tablet.command',
    'Tablet.adminCommand',
    'Tablet.keybind',
    'Tablet.dispatchKey',
    'Tablet.readyKey',
    'Tablet.contactKey',
    'Tablet.desks',
    'Locale',
    'Time.resetHour',
    'Leaderboard.weekStartsOn',
}

-- Read when the mission files load: a change reloads the missions (as Admin UI → Missions → Reload does).
local RELOAD = {
    'MissionTweaks',
    'Blocks',
    'Builder.allowed',
    'Builder.noBuildZones',
    'Builder.minLocations',
    'Builder.minLocationGap',
    'Builder.maxBlocks',
    'Builder.maxHostiles',
    'Bonuses',
    'MissionTypes',
    'Departments',
    'Limits.maxUnitSize',
    'Limits.startTimeout',
    'Difficulty',
    'Decisions',
    'AntiCheat.presenceRadius',
}

-- Tables whose keys are the owner's own (mission ids, item names): one setting edited as a whole.
local OPEN = {
    'MissionTweaks',
    'DisabledLocations',
    'Labels',
    'Rewards.byType',
    'Rewards.byMission',
    'Rewards.medals',
    'Rewards.goals',
    'Rewards.levels',
    'Rewards.season',
}

local WEEKDAYS = { 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday' }
local METRICS = { 'points', 'missions', 'arrests', 'impounds', 'citations', 'rescues', 'calls', 'judgement' }
local APPEARANCES = { 'department', 'midnight', 'high_contrast', 'colourblind' }
local END_REASONS = {
    'real_call',
    'force_recall',
    'downed',
    'quit',
    'off_route',
    'start_timeout',
    'idle',
    'job_change',
    'off_duty',
    'suspended',
    'real_call_cancelled',
    'disconnected',
    'cancelled',
}

-- Known number ranges ({ min, max }); every other number keeps the sign of its config.lua value.
local RANGES = {
    ['Time.resetHour'] = { 0, 23 },
    ['Departments.*.logo.opacity'] = { 0, 0.25 },
    ['Departments.*.logo.size'] = { 0.05, 1 },
    ['Departments.*.supervisorGrade'] = { 0, 100 },
    ['Events.modifierChance'] = { 0, 1 },
    ['Events.timeCrunchCut'] = { 0, 0.9 },
    ['Events.todMultiplier'] = { 0, 10 },
    ['Events.modifierCash'] = { 0, 10 },
    ['Custody.consent.*'] = { 0, 1 },
    ['Custody.admission'] = { 0, 1 },
    ['Custody.cues.*'] = { 0, 1 },
    ['AntiCheat.presenceShare'] = { 0, 1 },
    ['Scoring.failedCredit'] = { 0, 1 },
    ['Scoring.common.fastShare'] = { 0, 1 },
    ['Scoring.scoreCap'] = { 0, 10 },
    ['CrossDepartmentPoints'] = { 0, 10 },
    ['Rewards.findBonus'] = { 0, 1 },
    ['Rewards.findBonusMax'] = { 0, 1 },
    ['Rewards.tierChance.*'] = { 0, 1 },
    ['MissionCalls.rapidResponse.pctOfP'] = { 0, 1 },
    ['MissionCalls.types.*.priority'] = { 1, 3 },
    ['MissionCalls.checkEvery'] = { 1, 600 },
    ['Limits.maxUnitSize'] = { 1, 16 },
    ['Limits.maxArmedAlive'] = { 1, 100 },
    ['Limits.maxEntities'] = { 1, 300 },
    ['Limits.maxConcurrentRuns'] = { 1, 128 },
    ['Limits.maxConcurrentTactical'] = { 0, 128 },
    ['CrossDept.minParticipants'] = { 1, 32 },
    ['CrossDept.maxParticipants'] = { 1, 32 },
    ['Testing.maxTesters'] = { 1, 32 },
    ['Downed.checkEvery'] = { 1, 10 },
    ['Route.reportEvery'] = { 1, 30 },
    ['Route.sampleEvery'] = { 5, 500 },
    ['XPCurve.growth'] = { 1, 3 },
    ['XPCurve.maxLevel'] = { 1, 500 },
    ['Profile.bioLines'] = { 1, 20 },
    ['Profile.bioMax'] = { 1, 2000 },
    ['Leaderboard.topN'] = { 1, 100 },
    ['Cash.minPayout'] = { 0, 10000000 },
    ['Cash.maxPayout'] = { 0, 10000000 },
    -- real calls, alerts, the start route and downed participants (Hard rules 15-18): numbers only, never off
    ['Calls.dodgeWindow'] = { 10, 300 },
    ['Calls.respondingExpiry'] = { 60, 7200 },
    ['Alerts.backstopRadius'] = { 50, 1000 },
    ['Alerts.backstopDelay'] = { 0, 10 },
    ['Downed.pickupDelay'] = { 5, 120 },
    ['Route.abandonAfter'] = { 10, 120 },
    ['Route.maxDeviation'] = { 30, 500 },
    ['Route.reportTimeout'] = { 5, 60 },
    ['Route.maxDrift'] = { 200, 5000 },
    -- admin control limits
    ['AdminControl.adjustConfirmAbove'] = { 1, 10000 },
    ['AdminControl.adjustDailyLimit'] = { 0, 1000000 },
    ['AdminControl.bulkMaxRows'] = { 1, 50000 },
    ['AdminControl.cooldownClearsPerDay'] = { 0, 50 },
    ['AdminControl.extraRunsMax'] = { 0, 100 },
    ['AdminControl.streakForgiveMax'] = { 0, 30 },
    ['AdminControl.runTimeAddMax'] = { 0, 3600 },
    ['Cash.addFundsMax'] = { 0, 10000000 },
    ['Cash.manualDailyLimit'] = { 0, 10000000 },
    ['Cash.lowBalanceWarn'] = { 0, 100000000 },
    ['Backups.keep'] = { 1, 100 },
}

-- Numbers that may go either way whatever config.lua has.
local SIGNED = { 'NpcDifficulty.custom.*', 'NpcDifficulty.presets.*.*' }

-- Lists of two or three numbers that are { min, max } or { min, max, default }.
local RANGE_LISTS = {
    'Blocks.*.*',
    'Payouts.supervisorRange',
    'MissionCalls.spawnEvery',
    'Npc.tellSeconds',
    'Custody.*.spawnDistance',
    'Commendations.citation',
    'Profile.uiScale',
}

-- Settings that must stay smaller than or equal to another one.
local ORDERED = {
    { 'CrossDept.minParticipants', 'CrossDept.maxParticipants' },
    { 'Cash.minPayout', 'Cash.maxPayout' },
}

local warned = {}
local validators = {}     -- { pattern, fn } (Settings.registerValidator)
local schema = nil        -- { list, byPath, sections } (built at the first request)
local saved = {}          -- [path] = { value, none, by, at, invalid } : the cp_settings rows
local applied = {}        -- [path] = { value, none } : what Config holds now
local touched = {}        -- top-level Config keys rebuilt at least once
local loaded = false
local waiting = {}        -- srcs that said hello before the settings loaded
local reloadQueued = false

-- ============================================================================
--                       THE CONFIG.LUA VALUES (DEFAULTS)
-- ============================================================================
-- config/config.lua and config/blocks.lua have loaded, nothing has changed Config yet: this copy is what
-- "default" and "reset" mean.
local DEFAULTS = U.deepcopy(Config or {})

-- ============================================================================
--                                SMALL HELPERS
-- ============================================================================

local Effective   -- the value a setting holds now (defined with the checks below)

local function WarnOnce(key, fmt, ...)
    if warned[key] then return end
    warned[key] = true
    CP.warn(TAG, fmt, ...)
end

local function Segments(path)
    local out = {}
    for part in tostring(path):gmatch('[^%.]+') do out[#out + 1] = part end
    return out
end

local function Top(path) return tostring(path):match('^[^%.]+') end

local function Parent(path) return tostring(path):match('^(.*)%.[^%.]+$') or '' end

-- Does a path match a pattern of the tables above ('*' = any one key)?
local function Matches(path, pattern)
    local a, b = Segments(path), Segments(pattern)
    if #a ~= #b then return false end
    for i = 1, #a do
        if b[i] ~= '*' and b[i] ~= a[i] then return false end
    end
    return true
end

-- The value of a pattern table (map) for a path, or nil.
local function Lookup(map, path)
    if map[path] ~= nil then return map[path] end
    for pattern, v in pairs(map) do
        if pattern:find('*', 1, true) and Matches(path, pattern) then return v end
    end
    return nil
end

local function InList(list, path)
    for _, pattern in ipairs(list) do
        if pattern == path or Matches(path, pattern) then return true end
    end
    return false
end

-- A path at or under one of the prefixes.
local function UnderAny(list, path)
    for _, prefix in ipairs(list) do
        if path == prefix or path:sub(1, #prefix + 1) == prefix .. '.' then return true end
    end
    return false
end

local function IsList(t)
    if type(t) ~= 'table' then return false end
    local n = #t
    if n == 0 then return next(t) == nil end
    local count = 0
    for k in pairs(t) do
        if math.type(k) ~= 'integer' or k < 1 or k > n then return false end
        count = count + 1
    end
    return count == n
end

-- 2, 3 or 4 for a vector (FiveM's vector types, or the tests' vector tables), else nil.
local function VecDims(v)
    local t = type(v)
    if t == 'vector2' then return 2 elseif t == 'vector3' then return 3 elseif t == 'vector4' then return 4 end
    if t == 'table' and getmetatable(v) ~= nil and type(rawget(v, 'x')) == 'number'
        and type(rawget(v, 'y')) == 'number' then
        if rawget(v, 'w') ~= nil then return 4 end
        if rawget(v, 'z') ~= nil then return 3 end
        return 2
    end
    return nil
end

local function MakeVec(dims, x, y, z, w)
    if dims == 4 then return vector4(x, y, z, w) end
    if dims == 2 then return vector2(x, y) end
    return vector3(x, y, z)
end

-- A value as JSON-safe plain data: vectors become { x, y, z, w }, map keys become text.
local function Plain(v)
    local dims = VecDims(v)
    if dims then
        local out = { x = v.x + 0.0, y = v.y + 0.0 }
        if dims >= 3 then out.z = v.z + 0.0 end
        if dims == 4 then out.w = v.w + 0.0 end
        return out
    end
    if type(v) ~= 'table' then return v end
    local out = {}
    if IsList(v) then
        for i, x in ipairs(v) do out[i] = Plain(x) end
        return out
    end
    for k, x in pairs(v) do out[tostring(k)] = Plain(x) end
    return out
end
Settings.plain = Plain

-- Deep equality (vectors by their parts, 3 == 3.0).
local function Same(a, b)
    if a == b then return true end
    local da, db = VecDims(a), VecDims(b)
    if da or db then
        if da ~= db then return false end
        return a.x == b.x and a.y == b.y and (a.z or 0) == (b.z or 0) and (a.w or 0) == (b.w or 0)
    end
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    for k, v in pairs(a) do
        if not Same(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

local function Contains(list, v)
    for _, x in ipairs(list or {}) do
        if x == v then return true end
    end
    return false
end

-- Short text of a value for the audit columns and the console.
local function Brief(v, none)
    if none or v == nil then return CP.L('settings.not_set') end
    if type(v) == 'string' then return v end
    if type(v) == 'number' then
        if math.type(v) == 'float' then return ('%g'):format(v) end
        return tostring(v)
    end
    if type(v) == 'boolean' then return tostring(v) end
    local ok, s = pcall(json.encode, Plain(v))
    return ok and s or tostring(v)
end

local function Label(key)
    local s =
        tostring(key):gsub('_', ' '):gsub('(%u)(%u%l)', '%1 %2'):gsub('(%l)(%u)', '%1 %2'):gsub('(%a)(%d)', '%1 %2')
    s = s:lower()
    return (s:gsub('^%l', string.upper))
end

-- 'SCORING, XP LEVELS AND GOALS' -> 'Scoring, XP levels and goals' (two-letter words such as XP stay capitals).
local function SentenceCase(title)
    local s = tostring(title):gsub('%a+', function(w)
        if #w <= 2 and w == w:upper() then return w end
        return w:lower()
    end)
    return (s:gsub('^%l', string.upper))
end

-- ============================================================================
--                   CONFIG FILE COMMENTS (THE DESCRIPTIONS)
-- ============================================================================
-- The two config files are read as text the first time the Settings screen asks: the comment lines right above a
-- key and the comment after it on its line are its description, and the banner above a Config.X line names its
-- section. Nothing is copied by hand, so a new key or a changed comment shows up by itself.

local function Tokenize(src)
    local toks, comments, codeLines = {}, {}, {}
    local i, n, line, lineStart = 1, #src, 1, 1
    local function skipTo(e)
        -- moves past a multi-line piece (long comment or string), counting its lines
        local from = i
        for pos in src:sub(from, e):gmatch('()\n') do
            line = line + 1
            lineStart = from + pos
        end
        i = e + 1
    end
    while i <= n do
        local c = src:sub(i, i)
        if c == '\n' then
            line = line + 1
            i = i + 1
            lineStart = i
        elseif c == ' ' or c == '\t' or c == '\r' then
            i = i + 1
        elseif c == '-' and src:sub(i + 1, i + 1) == '-' then
            local eq = src:match('^%[(=*)%[', i + 2)
            if eq then
                local _, e = src:find(']' .. eq .. ']', i + 4 + #eq, true)
                skipTo(e or n)
            else
                local e = src:find('\n', i, true) or (n + 1)
                comments[line] = { text = src:sub(i + 2, e - 1), col = i - lineStart + 1, own = not codeLines[line] }
                i = e
            end
        elseif c == '\'' or c == '"' then
            local j = i + 1
            while j <= n do
                local d = src:sub(j, j)
                if d == '\\' then
                    j = j + 2
                elseif d == c or d == '\n' then
                    break
                else
                    j = j + 1
                end
            end
            toks[#toks + 1] = { t = 'value', line = line, col = i - lineStart + 1 }
            codeLines[line] = true
            i = j + 1
        elseif c == '[' and src:match('^%[=*%[', i) then
            local eq = src:match('^%[(=*)%[', i)
            toks[#toks + 1] = { t = 'value', line = line, col = i - lineStart + 1 }
            codeLines[line] = true
            local _, e = src:find(']' .. eq .. ']', i + 2 + #eq, true)
            skipTo(e or n)
        elseif c:match('[%a_]') then
            local s, e = src:find('^[%w_]+', i)
            toks[#toks + 1] = { t = 'name', v = src:sub(s, e), line = line, col = i - lineStart + 1 }
            codeLines[line] = true
            i = e + 1
        elseif c:match('%d') or (c == '.' and src:sub(i + 1, i + 1):match('%d')) then
            local _, e = src:find('^[%w%.]+', i)
            toks[#toks + 1] = { t = 'value', line = line, col = i - lineStart + 1 }
            codeLines[line] = true
            i = e + 1
        else
            toks[#toks + 1] = { t = 'op', v = c, line = line, col = i - lineStart + 1 }
            codeLines[line] = true
            i = i + 1
        end
    end
    return toks, comments, codeLines
end

-- Every key of every Config.X = ... statement: { path, line, col, top }, in file order.
local function ParseKeys(toks)
    local keys = {}
    local p = 1
    local function isOp(t, v) return t ~= nil and t.t == 'op' and t.v == v end
    local function skipBracket(open, close)
        local depth = 0
        while toks[p] do
            local t = toks[p]
            if isOp(t, open) then
                depth = depth + 1
            elseif isOp(t, close) then
                depth = depth - 1
            end
            p = p + 1
            if depth <= 0 then return end
        end
    end
    local parseValue
    local function parseTable(path)
        p = p + 1
        while toks[p] and not isOp(toks[p], '}') do
            local t = toks[p]
            local before = p
            if t.t == 'name' and isOp(toks[p + 1], '=') and not isOp(toks[p + 2], '=') then
                local keyPath = path and (path == '' and t.v or (path .. '.' .. t.v)) or nil
                if keyPath then keys[#keys + 1] = { path = keyPath, line = t.line, col = t.col } end
                p = p + 2
                parseValue(keyPath)
            elseif isOp(t, '[') then
                skipBracket('[', ']')
                if isOp(toks[p], '=') then p = p + 1 end
                parseValue(nil)
            else
                parseValue(nil)
            end
            if isOp(toks[p], ',') or isOp(toks[p], ';') then p = p + 1 end
            if p == before then p = p + 1 end
        end
        p = p + 1
    end
    parseValue = function(path)
        local t = toks[p]
        if not t then return end
        if isOp(t, '{') then return parseTable(path) end
        if isOp(t, '-') or (t.t == 'name' and t.v == 'not') then
            p = p + 1
            return parseValue(nil)
        end
        p = p + 1
        while toks[p] do
            local s = toks[p]
            if isOp(s, '.') and toks[p + 1] and toks[p + 1].t == 'name' then
                p = p + 2
            elseif isOp(s, '(') then
                skipBracket('(', ')')
            elseif isOp(s, '[') then
                skipBracket('[', ']')
            else
                break
            end
        end
        local s = toks[p]
        local binary = s ~= nil
            and (
                (s.t == 'op' and (s.v == '+' or s.v == '*' or s.v == '/' or (s.v == '.' and isOp(toks[p + 1], '.'))))
                or (s.t == 'name' and (s.v == 'and' or s.v == 'or'))
            )
        if binary then
            p = p + ((s.v == '.') and 2 or 1)
            parseValue(nil)
        end
    end
    while toks[p] do
        local t = toks[p]
        if t.t == 'name' and t.v == 'Config' then
            local parts, q = {}, p + 1
            while isOp(toks[q], '.') and toks[q + 1] and toks[q + 1].t == 'name' do
                parts[#parts + 1] = toks[q + 1].v
                q = q + 2
            end
            if isOp(toks[q], '=') and not isOp(toks[q + 1], '=') then
                p = q + 1
                local path = table.concat(parts, '.')
                if path ~= '' then keys[#keys + 1] = { path = path, line = t.line, col = t.col, top = true } end
                parseValue(path)
            else
                p = q
            end
        else
            p = p + 1
        end
    end
    return keys
end

local function IsRule(text) return text:match('^%s*=+%s*$') ~= nil and #text >= 20 end

-- A commented-out entry (-- text = '#ffffff', -- bcso = {, -- },): never part of a description.
local function IsCode(text)
    local s = U.trim(text)
    if s:match('^[{}]') or s:match('^%-%-') then return true end
    local rest = s:match('^[%a_][%w_]*%s*=%s*(.*)$') or s:match('^%[[^%]]+%]%s*=%s*(.*)$')
    if not rest or rest:sub(1, 1) == '=' then return false end
    return rest == '' or rest:match('^[{\'"%[]') ~= nil or rest:match('^[%w_%.%-]+%s*,') ~= nil
        or rest:match('^[%w_%.%-]+%s*$') ~= nil
end

-- { [path] = { line, desc, file, section } } and the section titles in order, from one config file.
local function ReadFile(file, meta, sections)
    local src = LoadResourceFile(CP.resource, file.path)
    if type(src) ~= 'string' or src == '' then
        WarnOnce('file.' .. file.path, '%s could not be read: the Settings screen shows no descriptions from it',
            file.path)
        return
    end
    local toks, comments = Tokenize(src)
    local banner, banners = {}, {}
    local maxLine = 0
    for l in pairs(comments) do if l > maxLine then maxLine = l end end
    for l = 1, maxLine do
        local a, b, c = comments[l], comments[l + 1], comments[l + 2]
        if a and b and c and a.own and b.own and c.own and IsRule(a.text) and IsRule(c.text) and not IsRule(b.text) then
            banners[#banners + 1] = { line = l, title = U.trim(b.text) }
            banner[l], banner[l + 1], banner[l + 2] = true, true, true
        end
    end
    local firstOnLine = {}
    local keys = ParseKeys(toks)
    for _, k in ipairs(keys) do
        if not firstOnLine[k.line] then firstOnLine[k.line] = k end
    end
    local sectionOf = {}
    local function sectionAt(line)
        local title = nil
        for _, b in ipairs(banners) do
            if b.line < line then title = b.title end
        end
        if file.name == 'blocks' then return 'blocks', CP.L('settings.section.blocks') end
        if not title then return 'general', CP.L('settings.section.general') end
        local key = title:lower():gsub('%b()', ''):gsub('[^%w]+', '_'):gsub('^_+', ''):gsub('_+$', '')
        return key, SentenceCase(title)
    end
    for _, k in ipairs(keys) do
        local lines = {}
        if firstOnLine[k.line] == k then
            local l = k.line - 1
            while l >= 1 do
                local c = comments[l]
                if not c or not c.own or banner[l] or IsCode(c.text) then break end
                table.insert(lines, 1, U.trim(c.text))
                l = l - 1
            end
            local tc = comments[k.line]
            if tc and not tc.own and not IsCode(tc.text) then
                lines[#lines + 1] = U.trim(tc.text)
                local m = k.line + 1
                while comments[m] and comments[m].own and comments[m].col == tc.col and not IsCode(comments[m].text) do
                    lines[#lines + 1] = U.trim(comments[m].text)
                    m = m + 1
                end
            end
        end
        local top = Top(k.path)
        if k.top or not sectionOf[top] then
            local key, title = sectionAt(k.line)
            if k.top then sectionOf[k.path] = { key = key, title = title } end
            if not sectionOf[top] then sectionOf[top] = { key = key, title = title } end
        end
        local sec = sectionOf[top]
        if not sections.byKey[sec.key] then
            sections.byKey[sec.key] = { key = sec.key, title = sec.title, file = file.name }
            sections.order[#sections.order + 1] = sec.key
        end
        local desc = table.concat(lines, ' '):gsub('%s+', ' ')
        if not meta[k.path] then
            sections.n = sections.n + 1
            meta[k.path] = { order = sections.n, desc = desc, file = file.name, section = sec.key }
        end
    end
end

-- ============================================================================
--                       TEMPLATES (WHAT A VALUE MAY BE)
-- ============================================================================
-- A setting is checked against the shape of its config.lua value (number, text, true/false, list or table) or
-- against one of the templates below where config.lua alone cannot say (empty tables, "false or an item name").

local KIND = setmetatable({}, { __mode = 'k' })   -- template tables made here -> their kind
local function Tpl(kind, t)
    t = t or {}
    KIND[t] = kind
    return t
end
local NIL = Tpl('nil')
local ANY = Tpl('any')
local FALSE = Tpl('false')
local function Alts(...) return Tpl('alts', { alts = { ... } }) end
local function ListOf(elem, opts)
    opts = opts or {}
    return Tpl('list', { elem = elem, min = opts.min, max = opts.max, unique = opts.unique })
end
local function MapOf(value, keyPattern) return Tpl('map', { value = value, keyPattern = keyPattern }) end
local function Record(fields, required) return Tpl('record', { fields = fields, required = required or {} }) end
local function Enum(options) return Tpl('enum', { options = options }) end
local function Text(pattern, max, check) return Tpl('text', { pattern = pattern, max = max, check = check }) end
local function Num(min, max, int) return Tpl('num', { min = min, max = max, int = int }) end
local function SiblingOption(list) return Tpl('option', { list = list }) end

local ITEM_NAME = Text('^[%w_%-]+$', 64)
local ID = Text('^[%w_%-]+$', 64)
local HEX = Text('^#%x%x%x%x%x%x$', 7)

local function SafeFile(s)
    if s:find('..', 1, true) or s:sub(1, 1) == '/' then return 'err.setting_path' end
    return nil
end

local function SafeExport(s)
    if s:find('..', 1, true) or s:find('//', 1, true) then return 'err.setting_path' end
    return nil
end

-- Response chances that must add up to 100 (Blocks.pursuit.responses, Blocks.flee_arrest.responses).
local function SumOf100(v)
    local sum = 0
    for _, n in pairs(v) do sum = sum + n end
    if sum ~= 100 then return 'err.setting_sum_100' end
    return nil
end

local TWEAK = Record({
    cooldown = Num(0, 86400, true),
    timeLimit = Num(30, 86400, true),
    startTimeout = Num(30, 86400, true),
    disabledLocations = ListOf(Text(nil, 64)),
    peds = ListOf(ITEM_NAME),
    vehicles = ListOf(ITEM_NAME),
    weapons = ListOf(ITEM_NAME),
})

-- Explicit templates by path ('*' = any key). kind: what the screen edits it with.
local KNOWN = {
    ['Tablet.item'] = { tpl = Alts(FALSE, ITEM_NAME), kind = 'optionalText' },
    ['Custody.handcuffsItem'] = { tpl = Alts(FALSE, ITEM_NAME), kind = 'optionalText' },
    ['Custody.evidenceItem'] = { tpl = Alts(FALSE, ITEM_NAME), kind = 'optionalText' },
    ['Profile.bannedWordsFile'] = {
        tpl = Alts(FALSE, Text('^[%w_%-/%.]+%.txt$', 128, SafeFile)),
        kind = 'optionalText',
    },
    ['Tablet.command'] = { tpl = Text('^%a[%w_%-]*$', 32) },
    ['Tablet.adminCommand'] = { tpl = Text('^%a[%w_%-]*$', 32) },
    ['Tablet.keybind'] = { tpl = Text('^[%w_%-]*$', 32) },
    ['Tablet.dispatchKey'] = { tpl = Text('^[%w_%-]*$', 32) },
    ['Tablet.readyKey'] = { tpl = Text('^[%w_%-]*$', 32) },
    ['Tablet.contactKey'] = { tpl = Text('^[%w_%-]*$', 32) },
    ['Builder.exportPath'] = { tpl = Text('^missions/custom/[%w_%-/]*$', 128, SafeExport) },
    ['Locale'] = { tpl = Enum({ 'en' }), kind = 'enum' },
    ['DisabledMissions'] = { tpl = ListOf(ID, { unique = true }), kind = 'list', item = 'string' },
    ['DisabledLocations'] = { tpl = MapOf(ListOf(Alts(Num(1, 999, true), Text(nil, 64))), '^[%w_%-]+$') },
    ['MissionTweaks'] = { tpl = MapOf(TWEAK, '^[%w_%-]+$') },
    ['Leaderboard.weeklyBadges'] = { tpl = ListOf(Enum(METRICS), { unique = true }), kind = 'list', options = METRICS },
    ['Leaderboard.metrics'] = {
        tpl = ListOf(Enum(METRICS), { min = 1, unique = true }),
        kind = 'list',
        options = METRICS,
    },
    ['Leaderboard.weekStartsOn'] = { tpl = Enum(WEEKDAYS), kind = 'enum' },
    ['Profile.bannedWords'] = { tpl = ListOf(Text(nil, 64)), kind = 'list', item = 'string' },
    ['Profile.appearances'] = {
        tpl = ListOf(Enum(APPEARANCES), { min = 1, unique = true }),
        kind = 'list',
        options = APPEARANCES,
    },
    ['Events.weeklyBoss.days'] = { tpl = ListOf(Enum(WEEKDAYS), { unique = true }), kind = 'list', options = WEEKDAYS },
    ['Rescale.keepPayTierFor'] = {
        tpl = ListOf(Enum(END_REASONS), { unique = true }),
        kind = 'list',
        options = END_REASONS,
    },
    ['MissionTypes.*.dailyLimit'] = {
        tpl = Alts(NIL, Num(0, 1000, true)),
        kind = 'number',
        nullable = true,
        min = 0,
        max = 1000,
    },
    ['Blocks.pursuit.responses'] = {
        tpl = Record({ yield = Num(0, 100, true), flee = Num(0, 100, true), fight = Num(0, 100, true) },
            { yield = true, flee = true, fight = true }),
        check = SumOf100,
    },
    ['Blocks.flee_arrest.responses'] = {
        tpl = Record({ surrender = Num(0, 100, true), flee = Num(0, 100, true), fight = Num(0, 100, true) },
            { surrender = true, flee = true, fight = true }),
        check = SumOf100,
    },
    ['Rewards.weeklyBoss'] = { tpl = Alts(NIL, ANY), nullable = true },
    ['Rewards.byType'] = { tpl = ANY },
    ['Rewards.byMission'] = { tpl = ANY },
    ['Rewards.medals'] = { tpl = ANY },
    ['Rewards.goals'] = { tpl = ANY },
    ['Rewards.levels'] = { tpl = ANY },
    ['Rewards.season'] = { tpl = ANY },
    ['Custody.parkingRules.*'] = {
        tpl = Alts(Enum({ 'cite', 'impound' }), FALSE),
        kind = 'enum',
        options = { 'cite', 'impound' },
        allowFalse = true,
    },
    ['Cash.account'] = { tpl = Enum({ 'bank', 'cash' }), kind = 'enum' },
    ['Cash.source'] = { tpl = Enum({ 'server', 'society' }), kind = 'enum' },
    ['Units.invitePolicy'] = { tpl = Enum({ 'anyone', 'leader' }), kind = 'enum' },
    ['NpcDifficulty.preset'] = { tpl = Enum({ 'easy', 'normal', 'hard', 'custom' }), kind = 'enum' },
    ['Challenge.scoring'] = { tpl = Enum({ 'average', 'total', 'top10' }), kind = 'enum' },
    ['Departments.*.jobs'] = { tpl = ListOf(ID, { min = 1, unique = true }), kind = 'list', item = 'string' },
    ['Departments.*.theme.personalAccents'] = {
        tpl = ListOf(Alts(HEX, Record({ colour = HEX, level = Num(1, 1000, true) }, { colour = true }))),
    },
    ['Tablet.desks'] = {
        tpl = ListOf(Record({
            label = Text(nil, 64),
            coords = vector3(0.0, 0.0, 0.0),
            size = vector3(1.0, 1.0, 1.0),
            rotation = 0.0,
            departments = ListOf(ID),
            prop = Alts(FALSE, ITEM_NAME),
        }, { label = true, coords = true, size = true })),
    },
}

-- ============================================================================
--                   ROW TEMPLATES (THE SIX LISTS OF TABLES)
-- ============================================================================
-- Each row is checked field by field, and the list as a whole by its check, from the row editor and the raw editor
-- alike. rows = what the screen's row editor shows (fields, or bare for a list of points).

local MAP_X, MAP_Y, MAP_Z = { -6000.0, 6000.0 }, { -7000.0, 9000.0 }, { -500.0, 3000.0 }   -- metres
local TIERS = { 'standard', 'reinforced', 'heavy', 'major', 'critical' }
local XP_BADGES = { 'grey', 'bronze', 'silver', 'gold', 'platinum' }
local AVATAR_IDS = { 'shield', 'star', 'badge', 'dept', 'k9', 'motor', 'heli', 'swat', 'detective' }
local VEC3 = vector3(0.0, 0.0, 0.0)

local function Inside(v)
    if v == nil then return false end
    return v.x >= MAP_X[1] and v.x <= MAP_X[2] and v.y >= MAP_Y[1] and v.y <= MAP_Y[2] and (v.z or 0) >= MAP_Z[1]
        and (v.z or 0) <= MAP_Z[2]
end

local function CheckPoints(list)
    for _, v in ipairs(list) do
        if not Inside(v) then return 'err.setting_outside_map' end
    end
    return nil
end

-- The Crimson-Arena zones (docs/CRIMSON_ARENA.md item 7) may grow, never shrink, move or go.
local function CheckNoBuildZones(list)
    for _, z in ipairs(list) do
        if not Inside(z.coords) then return 'err.setting_outside_map' end
    end
    for _, d in ipairs(DEFAULTS.Builder and DEFAULTS.Builder.noBuildZones or {}) do
        if type(d) == 'table' and type(d.label) == 'string' and d.label:find('Crimson-Arena', 1, true) then
            local kept = false
            for _, z in ipairs(list) do
                if U.dist(z.coords, d.coords) < 0.5 and z.radius >= d.radius then
                    kept = true
                    break
                end
            end
            if not kept then return 'err.setting_arena_zone' end
        end
    end
    return nil
end

local function CheckAreas(list)
    local seen = {}
    for _, a in ipairs(list) do
        if seen[a.key] then return 'err.setting_duplicate' end
        seen[a.key] = true
        if not Inside(a.center) then return 'err.setting_outside_map' end
    end
    return nil
end

local function CheckScaling(rows)
    local last = 0
    for _, r in ipairs(rows) do
        if r.maxParticipants <= last then return 'err.setting_order' end
        last = r.maxParticipants
    end
    local unit = Effective and Effective('Limits.maxUnitSize')
    if type(unit) == 'number' and last < unit then return 'err.setting_scaling_last' end
    return nil
end

local function CheckXpLevels(rows)
    if rows[1].xp ~= 0 or rows[1].level ~= 1 then return 'err.setting_xp_first' end
    for i = 2, #rows do
        if rows[i].xp <= rows[i - 1].xp or rows[i].level <= rows[i - 1].level then return 'err.setting_order' end
    end
    return nil
end

local function CheckPresets(rows)
    local seen = {}
    for _, r in ipairs(rows) do
        if seen[r.id] then return 'err.setting_duplicate' end
        seen[r.id] = true
    end
    return nil
end

local function F(key, kind, extra)
    local f = { key = key, kind = kind }
    for k, v in pairs(extra or {}) do f[k] = v end
    return f
end

local ROWS = {
    ['Builder.noBuildZones'] = {
        tpl = ListOf(Record(
            { label = Text(nil, 64), coords = VEC3, radius = Num(10, 500, false) },
            { label = true, coords = true, radius = true }
        ), { max = 50 }),
        check = CheckNoBuildZones,
        rows = {
            max = 50,
            fields = {
                F('label', 'text', { max = 64 }),
                F('coords', 'vector', { size = 3, position = true }),
                F('radius', 'number', { min = 10, max = 500 }),
            },
        },
    },
    ['Downed.dropOffs'] = {
        tpl = ListOf(VEC3, { min = 1, max = 10 }),
        check = CheckPoints,
        rows = { min = 1, max = 10, bare = F(nil, 'vector', { size = 3, position = true }) },
    },
    ['MissionCalls.areas'] = {
        tpl = ListOf(Record(
            { key = Text('^[a-z0-9_]+$', 32), label = Text(nil, 40), center = VEC3 },
            { key = true, label = true, center = true }
        ), { min = 1, max = 50 }),
        check = CheckAreas,
        rows = {
            min = 1,
            max = 50,
            fields = {
                F('key', 'text', { max = 32, pattern = '^[a-z0-9_]+$' }),
                F('label', 'text', { max = 40 }),
                F('center', 'vector', { size = 3, position = true }),
            },
        },
    },
    ['Scaling'] = {
        tpl = ListOf(
            Record({
                maxParticipants = Num(1, 64, true),
                tier = Enum(TIERS),
                count = Num(0.1, 10, false),
                accuracy = Num(0, 100, true),
                armour = Num(0, 100, true),
                points = Num(0.1, 10, false),
                cash = Num(0.1, 10, false),
            }, {
                maxParticipants = true,
                tier = true,
                count = true,
                accuracy = true,
                armour = true,
                points = true,
                cash = true,
            }),
            { min = 1, max = 10 }
        ),
        check = CheckScaling,
        rows = {
            min = 1,
            max = 10,
            fields = {
                F('maxParticipants', 'number', { min = 1, max = 64, integer = true }),
                F('tier', 'enum', { options = TIERS }),
                F('count', 'number', { min = 0.1, max = 10 }),
                F('accuracy', 'number', { min = 0, max = 100, integer = true }),
                F('armour', 'number', { min = 0, max = 100, integer = true }),
                F('points', 'number', { min = 0.1, max = 10 }),
                F('cash', 'number', { min = 0.1, max = 10 }),
            },
        },
    },
    ['XPLevels'] = {
        tpl = ListOf(Record({
            label = Text(nil, 32),
            xp = Num(0, 1000000000, true),
            badge = Enum(XP_BADGES),
            level = Num(1, 1000, true),
        }, { label = true, xp = true, badge = true, level = true }), { min = 1, max = 20 }),
        check = CheckXpLevels,
        rows = {
            min = 1,
            max = 20,
            fields = {
                F('label', 'text', { max = 32 }),
                F('level', 'number', { min = 1, max = 1000, integer = true }),
                F('xp', 'number', { min = 0, integer = true }),
                F('badge', 'enum', { options = XP_BADGES }),
            },
        },
    },
    ['Profile.avatarPresets'] = {
        tpl = ListOf(Record({ id = Enum(AVATAR_IDS), level = Num(1, 1000, true) }, { id = true }),
            { min = 1, max = 50 }),
        check = CheckPresets,
        rows = {
            min = 1,
            max = 50,
            fields = {
                F('id', 'enum', { options = AVATAR_IDS }),
                F('level', 'number', { min = 1, max = 1000, integer = true, optional = true }),
            },
        },
    },
}
for path, r in pairs(ROWS) do KNOWN[path] = { tpl = r.tpl, kind = 'rows', rows = r.rows, check = r.check } end

-- ============================================================================
--                            NAMES (CONFIG.LABELS)
-- ============================================================================
-- English names for ids, over the locale's (CP.L reads them first). Only these kinds, only ids that exist.

local function ListHas(list, v)
    if type(list) ~= 'table' then return false end
    for _, x in ipairs(list) do
        if x == v then return true end
    end
    return false
end

local function ModFn(mod, fn)
    local m = CP[mod]
    if type(m) == 'table' and type(m[fn]) == 'function' then return m[fn] end
    return nil
end

local LABEL_KINDS = {
    {
        prefix = 'custody.offence.',
        known = function(id)
            local o = Effective and Effective('Custody.offences') or nil
            if type(o) ~= 'table' then o = DEFAULTS.Custody and DEFAULTS.Custody.offences or {} end
            return ListHas(o.person, id) or ListHas(o.vehicle, id)
        end,
    },
    {
        prefix = 'profile.commend.kind.',
        known = function(id)
            local kinds = Effective and Effective('Commendations.kinds') or nil
            return ListHas(kinds, id)
        end,
    },
    {
        prefix = 'badge.',
        known = function(id)
            local catalog = ModFn('Scoring', 'badgeCatalog')
            if catalog then
                local ok, list = pcall(catalog)
                if ok and type(list) == 'table' then
                    for _, b in ipairs(list) do
                        if b == id or (type(b) == 'table' and b.id == id) then return true end
                    end
                end
            end
            return false
        end,
    },
    {
        prefix = 'bonus.',
        known = function(id) return type(DEFAULTS.Bonuses) == 'table' and DEFAULTS.Bonuses[id] ~= nil end,
    },
    {
        prefix = 'penalty.',
        known = function(id) return type(DEFAULTS.Bonuses) == 'table' and DEFAULTS.Bonuses[id] ~= nil end,
    },
}

local function CheckLabels(map)
    for key, text in pairs(map) do
        local kindOk = false
        for _, kind in ipairs(LABEL_KINDS) do
            if key:sub(1, #kind.prefix) == kind.prefix then
                local id = key:sub(#kind.prefix + 1)
                if id == '' or not id:match('^[%w_%-]+$') then return 'err.setting_label_key' end
                -- an id the locale names exists too (built-in mission cards' own bonuses, the shipped badges)
                local inFile = CP.Locale and CP.Locale.inFile and CP.Locale.inFile(key)
                if not inFile and not kind.known(id) then return 'err.setting_label_unknown' end
                kindOk = true
                break
            end
        end
        if not kindOk then return 'err.setting_label_key' end
        if U.trim(text) == '' then return 'err.setting_label_text' end
        if text:find('[<>]') then return 'err.setting_label_text' end
    end
    return nil
end

KNOWN['Labels'] = { tpl = MapOf(Text(nil, 64), '^[%w_%.%-]+$'), kind = 'labels', check = CheckLabels }

-- ============================================================================
--                             BONUS KIND AND VALUE
-- ============================================================================
-- A bonus's kind changes only together with its value (one save of both): points -500..500 whole numbers, pct
-- -1..1, a bonus stays a bonus and a penalty stays a penalty.

local function BonusKindNow(path, ctx)
    local kindPath = Parent(path) .. '.kind'
    local pending = ctx and ctx.pending
    if pending and pending[kindPath] ~= nil then return pending[kindPath] end
    return Effective and Effective(kindPath) or nil
end

local function CheckBonusValue(v, path, ctx)
    local kind = BonusKindNow(path, ctx)
    local default = U.getPath(DEFAULTS, path)
    if type(default) == 'number' then
        if default > 0 and v < 0 then return 'err.setting_negative' end
        if default < 0 and v > 0 then return 'err.setting_positive' end
    end
    if kind == 'pct' then
        if v < -1 or v > 1 then return 'err.setting_range' end
        return nil, v + 0.0
    end
    local i = math.tointeger(v)
    if not i then return 'err.setting_whole' end
    if i < -500 or i > 500 then return 'err.setting_range' end
    return nil, i
end

local function CheckBonusKind(v, path, ctx)
    local valuePath = Parent(path) .. '.value'
    local pending = ctx and ctx.pending
    if not (pending and pending[valuePath] ~= nil) then return 'err.setting_kind_alone' end
    return nil
end

KNOWN['Bonuses.*.kind'] = { tpl = Enum({ 'points', 'pct' }), kind = 'enum', check = CheckBonusKind }
KNOWN['Bonuses.*.value'] = { tpl = Num(-500, 500), kind = 'number', check = CheckBonusValue, min = -500, max = 500 }

-- ============================================================================
--                           BUILT-IN MISSION TWEAKS
-- ============================================================================
-- CP.Missions checks each tweak the way the mission loader would (when it offers checkTweak), on every change made
-- in game; at start the loader applies them with its own warnings.
local function CheckTweaks(map, _, ctx)
    if ctx and ctx.boot then return nil end
    local fn = ModFn('Missions', 'checkTweak')
    if not fn then return nil end
    for id, tweak in pairs(map) do
        local ok, good, err = pcall(fn, id, tweak)
        if not ok then return 'err.setting_tweak' end
        if good == false then return err or 'err.setting_tweak' end
    end
    return nil
end
KNOWN['MissionTweaks'].check = CheckTweaks

-- ============================================================================
--                                   CHECKING
-- ============================================================================

local function Class(x)
    if VecDims(x) then return 'vector' end
    local t = type(x)
    if t == 'table' then
        if next(x) == nil then return 'empty' end
        return IsList(x) and 'list' or 'map'
    end
    return t
end

local function CheckNumber(x, r)
    if type(x) ~= 'number' or x ~= x or x == math.huge or x == -math.huge then return false, 'err.setting_number' end
    if math.abs(x) > MAX_ABS then return false, 'err.setting_range' end
    if r.int then
        local i = math.tointeger(x)
        if not i then return false, 'err.setting_whole' end
        x = i
    elseif r.int == false then
        x = x + 0.0
    end
    if r.sign == 1 and x < 0 then return false, 'err.setting_negative' end
    if r.sign == -1 and x > 0 then return false, 'err.setting_positive' end
    if r.min and x < r.min then return false, 'err.setting_range' end
    if r.max and x > r.max then return false, 'err.setting_range' end
    return true, x
end

local function CheckText(x, hex, pattern, max, check)
    if type(x) ~= 'string' then return false, 'err.setting_type' end
    if #x > (max or MAX_STRING) then return false, 'err.setting_too_long' end
    if x:find('%c') or not utf8.len(x) then return false, 'err.setting_text' end
    if hex and not U.isHexColour(x) then return false, 'err.setting_colour' end
    if pattern and not x:match(pattern) then return false, 'err.setting_text' end
    if check then
        local err = check(x)
        if err then return false, err end
    end
    return true, x
end

local function CheckVector(x, dims)
    local vx = type(x) == 'table' or VecDims(x) ~= nil
    if not vx then return false, 'err.setting_vector' end
    local parts = { 'x', 'y', 'z', 'w' }
    local vals = {}
    for i = 1, dims do
        local n = x[parts[i]]
        if type(n) ~= 'number' or n ~= n or math.abs(n) > MAX_COORD then return false, 'err.setting_vector' end
        vals[i] = n + 0.0
    end
    if type(x) == 'table' and not VecDims(x) then
        for k in pairs(x) do
            if not Contains({ 'x', 'y', 'z', 'w' }, k) then return false, 'err.setting_vector' end
        end
    end
    return true, MakeVec(dims, vals[1], vals[2], vals[3], vals[4])
end

-- Any JSON-like value (a table no template describes): finite numbers, short texts, tables of them.
local function CheckFree(x, depth, budget)
    budget.n = budget.n + 1
    if budget.n > MAX_NODES then return false, 'err.setting_too_big' end
    if depth > MAX_DEPTH then return false, 'err.setting_too_deep' end
    local t = type(x)
    if t == 'number' then return CheckNumber(x, {}) end
    if t == 'boolean' then return true, x end
    if t == 'string' then return CheckText(x) end
    if VecDims(x) then return CheckVector(x, VecDims(x)) end
    if t ~= 'table' then return false, 'err.setting_type' end
    local out, n, digits = {}, 0, true
    for k in pairs(x) do
        if not (type(k) == 'string' and k:match('^%d+$')) and math.type(k) ~= 'integer' then digits = false end
    end
    for k, v in pairs(x) do
        n = n + 1
        if n > MAX_ITEMS then return false, 'err.setting_too_many' end
        local key = k
        if digits and type(k) == 'string' then key = math.tointeger(tonumber(k)) end
        if type(key) == 'string' then
            if #key > 64 or not key:match('^[%w_%-]+$') then return false, 'err.setting_key' end
        elseif math.type(key) ~= 'integer' then
            return false, 'err.setting_key'
        end
        local ok, cv = CheckFree(v, depth + 1, budget)
        if not ok then return false, cv end
        out[key] = cv
    end
    return true, out
end

local Shape

-- A template for each element of a config.lua list: the elements' own shapes merged (tables by their keys).
local function MergeTemplates(values)
    local byClass = {}
    for _, v in ipairs(values) do
        local c = Class(v)
        if c == 'empty' then c = 'map' end
        byClass[c] = byClass[c] or {}
        local l = byClass[c]
        l[#l + 1] = v
    end
    local alts = {}
    for _, c in ipairs({ 'number', 'string', 'boolean', 'vector' }) do
        local l = byClass[c]
        if l then
            if c == 'number' then
                local int, sign = true, nil
                for _, v in ipairs(l) do
                    if math.type(v) ~= 'integer' then int = false end
                    local s = v > 0 and 1 or (v < 0 and -1 or 0)
                    if sign == nil then sign = s elseif sign ~= s then sign = 2 end
                end
                local t = Num(nil, nil, int)
                t.sign = (sign == 1 or sign == 0) and 1 or (sign == -1 and -1 or nil)
                alts[#alts + 1] = t
            elseif c == 'string' then
                local hex = true
                for _, v in ipairs(l) do if not U.isHexColour(v) then hex = false end end
                alts[#alts + 1] = hex and HEX or Text(nil, MAX_STRING)
            else
                alts[#alts + 1] = l[1]
            end
        end
    end
    if byClass.list then
        local inner = {}
        for _, v in ipairs(byClass.list) do for _, x in ipairs(v) do inner[#inner + 1] = x end end
        alts[#alts + 1] = ListOf(MergeTemplates(inner))
    end
    if byClass.map then
        local fields, required, seen = {}, {}, {}
        for i, m in ipairs(byClass.map) do
            for k, v in pairs(m) do
                seen[k] = seen[k] or {}
                local l = seen[k]
                l[#l + 1] = v
            end
            for k in pairs(required) do if m[k] == nil then required[k] = nil end end
            if i == 1 then for k in pairs(m) do required[k] = true end end
        end
        for k, l in pairs(seen) do fields[k] = MergeTemplates(l) end
        alts[#alts + 1] = Record(fields, required)
    end
    if #alts == 1 then return alts[1] end
    if #alts == 0 then return ANY end
    return Alts(table.unpack(alts))
end

Shape = function(tpl, x, depth, budget)
    depth = depth or 0
    budget = budget or { n = 0 }
    budget.n = budget.n + 1
    if budget.n > MAX_NODES then return false, 'err.setting_too_big' end
    if depth > MAX_DEPTH then return false, 'err.setting_too_deep' end
    local kind = KIND[tpl]
    if kind == 'nil' then
        if x == nil then return true, nil end
        return false, 'err.setting_type'
    elseif kind == 'false' then
        if x == false then return true, false end
        return false, 'err.setting_type'
    elseif kind == 'any' then
        if x == nil then return false, 'err.setting_type' end
        return CheckFree(x, depth, budget)
    elseif kind == 'alts' then
        -- the first alternative that fits; else the reason of one that had the right type (a range, a pattern)
        local why = 'err.setting_type'
        for _, a in ipairs(tpl.alts) do
            local ok, v = Shape(a, x, depth, budget)
            if ok then return true, v end
            if v ~= 'err.setting_type' and why == 'err.setting_type' then why = v end
        end
        return false, why
    elseif kind == 'enum' then
        if type(x) ~= 'string' then return false, 'err.setting_type' end
        if not Contains(tpl.options, x) then return false, 'err.setting_option' end
        return true, x
    elseif kind == 'option' then
        if type(x) ~= 'string' then return false, 'err.setting_type' end
        if type(tpl.list) == 'table' and not Contains(tpl.list, x) then return false, 'err.setting_option' end
        return true, x
    elseif kind == 'text' then
        return CheckText(x, false, tpl.pattern, tpl.max, tpl.check)
    elseif kind == 'num' then
        return CheckNumber(x, tpl)
    elseif kind == 'list' then
        if type(x) ~= 'table' or not IsList(x) or VecDims(x) then return false, 'err.setting_list' end
        if #x > (tpl.max or MAX_ITEMS) then return false, 'err.setting_too_many' end
        if tpl.min and #x < tpl.min then return false, 'err.setting_too_few' end
        local out = {}
        for i, el in ipairs(x) do
            local ok, v = Shape(tpl.elem, el, depth + 1, budget)
            if not ok then return false, v end
            if tpl.unique and Contains(out, v) then return false, 'err.setting_duplicate' end
            out[i] = v
        end
        return true, out
    elseif kind == 'map' then
        if type(x) ~= 'table' or VecDims(x) or (next(x) ~= nil and IsList(x)) then return false, 'err.setting_map' end
        local out, n = {}, 0
        for k, v in pairs(x) do
            n = n + 1
            if n > MAX_ITEMS then return false, 'err.setting_too_many' end
            if type(k) ~= 'string' or #k > 64 or (tpl.keyPattern and not k:match(tpl.keyPattern)) then
                return false, 'err.setting_key'
            end
            local ok, cv = Shape(tpl.value, v, depth + 1, budget)
            if not ok then return false, cv end
            out[k] = cv
        end
        return true, out
    elseif kind == 'record' then
        if type(x) ~= 'table' or VecDims(x) or (next(x) ~= nil and IsList(x)) then return false, 'err.setting_map' end
        for k in pairs(x) do
            if tpl.fields[k] == nil then return false, 'err.setting_key' end
        end
        for k in pairs(tpl.required) do
            if x[k] == nil then return false, 'err.setting_missing' end
        end
        local out = {}
        for k, ftpl in pairs(tpl.fields) do
            if x[k] ~= nil then
                local ok, v = Shape(ftpl, x[k], depth + 1, budget)
                if not ok then return false, v end
                out[k] = v
            end
        end
        return true, out
    elseif kind == 'range' then
        if type(x) ~= 'table' or not IsList(x) or #x ~= tpl.n then return false, 'err.setting_list' end
        local out = {}
        for i = 1, tpl.n do
            local ok, v = CheckNumber(x[i], { int = tpl.int, sign = tpl.sign })
            if not ok then return false, v end
            out[i] = v
        end
        if out[1] > out[2] then return false, 'err.setting_min_max' end
        if tpl.n == 3 and (out[3] < out[1] or out[3] > out[2]) then return false, 'err.setting_default_range' end
        return true, out
    end
    -- a config.lua value as the template
    local dims = VecDims(tpl)
    if dims then return CheckVector(x, dims) end
    local tt = type(tpl)
    if tt == 'number' then
        local sign = tpl > 0 and 1 or (tpl < 0 and -1 or 1)
        return CheckNumber(x, { int = math.type(tpl) == 'integer', sign = sign })
    elseif tt == 'boolean' then
        if type(x) ~= 'boolean' then return false, 'err.setting_type' end
        return true, x
    elseif tt == 'string' then
        return CheckText(x, U.isHexColour(tpl))
    elseif tt == 'table' then
        if next(tpl) == nil then return CheckFree(x, depth, budget) end
        if IsList(tpl) then
            local numeric = true
            for _, v in ipairs(tpl) do if type(v) ~= 'number' then numeric = false end end
            if numeric and (#tpl == 2 or #tpl == 3) then
                -- a fixed-size list of numbers (stars, bands): same length, each keeps its kind
                if type(x) ~= 'table' or not IsList(x) or #x ~= #tpl then return false, 'err.setting_list' end
                local out = {}
                for i = 1, #tpl do
                    local ok, v = Shape(tpl[i], x[i], depth + 1, budget)
                    if not ok then return false, v end
                    out[i] = v
                end
                return true, out
            end
            return Shape(ListOf(MergeTemplates(tpl)), x, depth, budget)
        end
        local fields, required = {}, {}
        for k, v in pairs(tpl) do
            fields[k] = v
            required[k] = true
        end
        return Shape(Record(fields, required), x, depth, budget)
    end
    return false, 'err.setting_type'
end

-- ============================================================================
--                                  THE SCHEMA
-- ============================================================================

local function RangeTemplate(path, default)
    if type(default) ~= 'table' or not IsList(default) or (#default ~= 2 and #default ~= 3) then return nil end
    if not InList(RANGE_LISTS, path) then return nil end
    local int = true
    for _, v in ipairs(default) do
        if type(v) ~= 'number' then return nil end
        if math.type(v) ~= 'integer' then int = false end
    end
    if default[1] > default[2] then return nil end
    if #default == 3 and (default[3] < default[1] or default[3] > default[2]) then return nil end
    local t = Tpl('range', { n = #default, int = int, sign = default[1] >= 0 and 1 or nil })
    return t
end

-- The template, editor kind and extra facts of one leaf.
local function Describe(path, default)
    local e = { path = path, default = default }
    local known = Lookup(KNOWN, path)
    if known then
        e.tpl = known.tpl
        e.kind = known.kind
        e.nullable = known.nullable
        e.options = known.options
        e.item = known.item
        e.allowFalse = known.allowFalse
        e.min, e.max = known.min, known.max
        e.check = known.check
        e.rows = known.rows
    end
    local range = not e.tpl and RangeTemplate(path, default) or nil
    if range then
        e.tpl = range
        e.kind = 'range'
        e.size = range.n
        e.integer = range.int
    end
    -- a Blocks entry { options = {...}, default = ... }: the default is one of the options
    local siblingOptions = nil
    if Segments(path)[1] == 'Blocks' and path:match('%.default$') then
        local opts = U.getPath(DEFAULTS, Parent(path) .. '.options')
        if type(opts) == 'table' and IsList(opts) then siblingOptions = Parent(path) .. '.options' end
    end
    if not e.tpl and siblingOptions then
        e.optionsFrom = siblingOptions
        if type(default) == 'string' then
            e.kind = 'enum'
        else
            e.kind = 'list'
        end
    end
    local r = Lookup(RANGES, path)
    if not e.tpl and r and type(default) == 'number' then
        e.tpl = Num(r[1], r[2], math.type(default) == 'integer')
        if math.type(default) ~= 'integer' then e.tpl.int = false end
        e.min, e.max = r[1], r[2]
    end
    if not e.tpl and type(default) == 'number' and InList(SIGNED, path) then
        e.tpl = Num(nil, nil, math.type(default) == 'integer')
        if math.type(default) ~= 'integer' then e.tpl.int = false end
    end
    if not e.tpl and default == nil then
        e.tpl = Alts(NIL, ANY)
        e.nullable = true
    end
    if not e.tpl then e.tpl = default end
    if not e.kind then
        local dims = VecDims(default)
        local t = type(default)
        if dims then
            e.kind = 'vector'
            e.size = dims
        elseif t == 'boolean' then
            e.kind = 'boolean'
        elseif t == 'number' then
            e.kind = 'number'
        elseif t == 'string' then
            e.kind = U.isHexColour(default) and 'colour' or 'text'
        elseif t == 'table' and IsList(default) and next(default) ~= nil then
            local first = Class(default[1])
            local same = first == 'string' or first == 'number'
            for _, v in ipairs(default) do if Class(v) ~= first then same = false end end
            if same and first == 'number' and (#default == 2 or #default == 3) then
                e.kind = 'numbers'
                e.size = #default
                e.integer = true
                for _, v in ipairs(default) do if math.type(v) ~= 'integer' then e.integer = false end end
            elseif same then
                e.kind = 'list'
                e.item = first
            else
                e.kind = 'json'
            end
        else
            e.kind = 'json'
        end
    end
    if e.kind == 'number' then
        if type(default) == 'number' then e.integer = math.type(default) == 'integer' end
        if e.min == nil and type(default) == 'number' and default >= 0 and not InList(SIGNED, path) then e.min = 0 end
        if e.max == nil and type(default) == 'number' and default < 0 and not InList(SIGNED, path) then e.max = 0 end
        if KIND[e.tpl] == 'alts' then e.integer = true end
    end
    e.locked = Lookup(LOCKED, path)
    e.restart = InList(RESTART, path) or UnderAny(RESTART, path)
    e.reload = UnderAny(RELOAD, path)
    e.points = InList(POINTS, path) or nil
    e.money = Contains(MONEY_SWITCHES, path) or nil
    return e
end

-- A table that is one setting (a list, an open map, an empty table, vectors) rather than a group of settings.
local function IsLeaf(path, v)
    if type(v) ~= 'table' or VecDims(v) then return true end
    if UnderAny(OPEN, path) or Lookup(KNOWN, path) then return true end
    if next(v) == nil or IsList(v) then return true end
    for k in pairs(v) do
        if type(k) ~= 'string' then return true end
    end
    return false
end

local function BuildSchema()
    local meta = {}
    local sections = { byKey = {}, order = {}, n = 0 }
    for _, f in ipairs(FILES) do ReadFile(f, meta, sections) end
    local list, byPath = {}, {}
    local function add(path, default)
        if byPath[path] then return end
        local e = Describe(path, default)
        local m = meta[path]
        local parts = Segments(path)
        e.key = parts[#parts]
        e.label = Label(e.key)
        e.desc = m and m.desc or ''
        e.order = m and m.order or (1e6 + #list)
        local top = Top(path)
        local tm = meta[top]
        e.section = (m and m.section) or (tm and tm.section) or 'other'
        e.group = Parent(path)
        list[#list + 1] = e
        byPath[path] = e
    end
    local function walk(path, v)
        if IsLeaf(path, v) then return add(path, v) end
        for k, x in pairs(v) do walk(path .. '.' .. k, x) end
    end
    for k, v in pairs(DEFAULTS) do
        if type(k) == 'string' then walk(k, v) end
    end
    -- keys config.lua writes as nil (dailyLimit = nil) only exist in the file
    for path in pairs(meta) do
        if not byPath[path] and U.getPath(DEFAULTS, path) == nil then
            local parent = Parent(path)
            local pv = parent ~= '' and U.getPath(DEFAULTS, parent) or DEFAULTS
            if type(pv) == 'table' and not IsList(pv) and (parent == '' or not IsLeaf(parent, pv))
                and Lookup(KNOWN, path) then
                add(path, nil)
            end
        end
    end
    -- the mission switches write these even when an older config.lua has no line for them
    if not byPath.DisabledMissions then add('DisabledMissions', {}) end
    if not byPath.DisabledLocations then add('DisabledLocations', {}) end
    table.sort(list, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.path < b.path
    end)
    local secList, secByKey = {}, {}
    for _, key in ipairs(sections.order) do
        local s = sections.byKey[key]
        local sec = { key = s.key, title = s.title, file = s.file, groups = {}, groupByPath = {} }
        secList[#secList + 1] = sec
        secByKey[key] = sec
    end
    for _, e in ipairs(list) do
        local sec = secByKey[e.section]
        if not sec then
            sec = {
                key = e.section,
                title = CP.L('settings.section.other'),
                file = 'config',
                groups = {},
                groupByPath = {},
            }
            secList[#secList + 1] = sec
            secByKey[e.section] = sec
        end
        local g = sec.groupByPath[e.group]
        if not g then
            local gm = meta[e.group]
            local labels = {}
            for _, s in ipairs(Segments(e.group)) do labels[#labels + 1] = Label(s) end
            g = { path = e.group, label = table.concat(labels, ' › '), desc = gm and gm.desc or '', settings = {} }
            sec.groupByPath[e.group] = g
            sec.groups[#sec.groups + 1] = g
        end
        g.settings[#g.settings + 1] = e
    end
    return { list = list, byPath = byPath, sections = secList }
end

local function Schema()
    if not schema then schema = BuildSchema() end
    return schema
end
Settings._schema = Schema
Settings._resetSchema = function() schema = nil end

-- The entry of a path (nil for a path that is not a setting).
function Settings.entry(path)
    if type(path) ~= 'string' or #path > 191 then return nil end
    return Schema().byPath[path]
end

-- ============================================================================
--                                  VALIDATION
-- ============================================================================

-- The value a setting would hold now (saved values win over config.lua).
Effective = function(path)
    local s = saved[path]
    if s and not s.invalid then
        if s.none then return nil end
        return s.value
    end
    return U.getPath(DEFAULTS, path)
end

-- A cross-field check another module adds (a department's jobs, desks, reward pools, tweaks): fn(path, clean, ctx)
-- -> errKey|nil, run after the template on every change (the raw editor and every structured editor alike) and on
-- every saved row at start. pattern: a path ('Rewards.byType'), '*' for any one key ('Departments.*.jobs'), or a
-- prefix that covers everything under it ('Departments'). ctx = { boot, pending = { [path] = value }, effective(path) }.
function Settings.registerValidator(pattern, fn)
    if type(pattern) ~= 'string' or pattern == '' or type(fn) ~= 'function' then return false end
    validators[#validators + 1] = { pattern = pattern, fn = fn }
    return true
end

local function ValidatorsFor(path)
    local out = {}
    for _, v in ipairs(validators) do
        if v.pattern == path or Matches(path, v.pattern) or path:sub(1, #v.pattern + 1) == v.pattern .. '.' then
            out[#out + 1] = v
        end
    end
    return out
end

-- ok, clean value (Lua: vectors, whole numbers, floats) | false, errKey. none = "not set" (nil).
-- ctx (optional) = { pending = { [path] = value } of the same save (a bonus's kind with its value), boot = true }.
function Settings.check(path, value, none, ctx)
    ctx = type(ctx) == 'table' and ctx or {}
    local e = Settings.entry(path)
    if not e then return false, 'err.setting_unknown' end
    if e.locked then return false, 'err.setting_locked' end
    if none then
        if not e.nullable then return false, 'err.setting_required' end
        return true, nil
    end
    if value == nil then return false, 'err.setting_type' end
    local tpl = e.tpl
    if e.optionsFrom then
        local opts = Effective(e.optionsFrom)
        if type(e.default) == 'table' then
            tpl = ListOf(SiblingOption(opts), { min = 1 })
        else
            tpl = SiblingOption(opts)
        end
    end
    local ok, clean = Shape(tpl, value)
    if not ok then return false, clean end
    if e.check then
        local err, fixed = e.check(clean, path, ctx)
        if err then return false, err end
        if fixed ~= nil then clean = fixed end
    end
    -- settings that stay in order with another one
    for _, pair in ipairs(ORDERED) do
        if path == pair[1] then
            local other = Effective(pair[2])
            if type(other) == 'number' and clean > other then return false, 'err.setting_order' end
        elseif path == pair[2] then
            local other = Effective(pair[1])
            if type(other) == 'number' and clean < other then return false, 'err.setting_order' end
        end
    end
    -- a Blocks options list must keep its default among the options
    if Segments(path)[1] == 'Blocks' and path:match('%.options$') and type(clean) == 'table' then
        local def = Effective(Parent(path) .. '.default')
        if type(def) == 'string' and not Contains(clean, def) then return false, 'err.setting_options_default' end
        if type(def) == 'table' then
            for _, d in ipairs(def) do
                if not Contains(clean, d) then return false, 'err.setting_options_default' end
            end
        end
    end
    -- the validators other modules registered
    local list = ValidatorsFor(path)
    if #list > 0 then
        local pending = type(ctx.pending) == 'table' and ctx.pending or {}
        local vctx = {
            boot = ctx.boot == true,
            pending = pending,
            effective = function(p)
                if pending[p] ~= nil then return pending[p] end
                return Effective(p)
            end,
        }
        for _, v in ipairs(list) do
            local okV, err = pcall(v.fn, path, clean, vctx)
            if not okV then
                CP.err(TAG, 'a validator of %s failed: %s', v.pattern, tostring(err))
                return false, 'err.setting_check'
            end
            if type(err) == 'string' and err ~= '' then return false, err end
        end
    end
    return true, clean
end

-- ============================================================================
--                                   STORAGE
-- ============================================================================

local function Encode(value, none)
    if none then return json.encode({ none = true }) end
    return json.encode({ v = Plain(value) })
end

local function ActorId(src)
    local n = tonumber(src) or 0
    if n <= 0 then return 'console' end
    local info = CP.Qbx and CP.Qbx.getInfo and CP.Qbx.getInfo(n)
    if type(info) == 'table' and type(info.citizenid) == 'string' then return info.citizenid end
    return ('player:%d'):format(n)
end

local function WriteRow(path, value, none, src)
    local ok, err = pcall(MySQL.insert.await, [[
        INSERT INTO cp_settings (setting_key, value_json, updated_by, updated_at) VALUES (?, ?, ?, NOW())
        ON DUPLICATE KEY UPDATE value_json = VALUES(value_json), updated_by = VALUES(updated_by),
          updated_at = VALUES(updated_at)
    ]], { path, Encode(value, none), ActorId(src) })
    if not ok then
        CP.err(TAG, 'saving %s failed: %s', path, tostring(err))
        return false
    end
    return true
end

local function DeleteRow(path)
    local ok, err = pcall(MySQL.update.await, 'DELETE FROM cp_settings WHERE setting_key = ?', { path })
    if not ok then
        CP.err(TAG, 'removing %s failed: %s', path, tostring(err))
        return false
    end
    return true
end

-- Every saved row, each checked again (a value config.lua no longer allows is ignored with one warning).
local function LoadRows()
    local ok, rows = pcall(MySQL.query.await,
        'SELECT setting_key, value_json, updated_by, UNIX_TIMESTAMP(updated_at) AS updated_ts FROM cp_settings')
    if not ok then
        CP.err(TAG, 'the settings changed in game could not be read: %s', tostring(rows))
        return false
    end
    saved = {}
    -- every saved value, so a bonus's kind is checked with its saved value (they are saved together)
    local pending = {}
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do
        local doc = U.jsonField(r.value_json)
        if type(doc) == 'table' and doc.v ~= nil then pending[tostring(r.setting_key)] = doc.v end
    end
    local ctx = { boot = true, pending = pending }
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do
        local path = tostring(r.setting_key)
        local doc = U.jsonField(r.value_json)
        local rec = { by = r.updated_by, at = math.floor(U.num(r.updated_ts)) }
        local okC, clean
        if type(doc) ~= 'table' then
            okC, clean = false, 'err.setting_type'
        elseif doc.none == true then
            okC, clean = Settings.check(path, nil, true, ctx)
            rec.none = true
        else
            okC, clean = Settings.check(path, doc.v, false, ctx)
        end
        if okC then
            rec.value = clean
        else
            rec.invalid = clean
            rec.raw = doc and doc.v
            WarnOnce('row.' .. path,
                'the saved setting %s was ignored (%s): config.lua\'s value is used. Change or reset it in Admin UI → Settings.',
                path, CP.L(clean))
        end
        saved[path] = rec
    end
    return true
end

-- ============================================================================
--                                   APPLYING
-- ============================================================================

local function SyncList()
    local out = {}
    for path, a in pairs(applied) do
        out[#out + 1] = a.none and { path = path, none = true } or { path = path, value = a.value }
    end
    table.sort(out, function(a, b) return a.path < b.path end)
    return out
end

local function SendTo(target)
    TriggerClientEvent(CP.e('client:settings'), target, SyncList())
end

-- Config gets config.lua's values back for every section a setting touches (now or before), then each applied
-- setting on top. A rebuilt section is a new table, so the modules' caches of it are rebuilt too.
local function Rebuild()
    local tops = {}
    for path in pairs(applied) do tops[Top(path)] = true end
    for top in pairs(touched) do tops[top] = true end
    for top in pairs(tops) do
        Config[top] = U.deepcopy(DEFAULTS[top])
        touched[top] = true
    end
    local paths = {}
    for path in pairs(applied) do paths[#paths + 1] = path end
    table.sort(paths)
    for _, path in ipairs(paths) do
        local a = applied[path]
        if a.none then
            U.setPath(Config, path, nil)
        else
            U.setPath(Config, path, U.deepcopy(a.value))
        end
    end
end

-- What a saved row means for Config right now: nil = config.lua's value.
local function Wanted(path)
    local s = saved[path]
    if not s or s.invalid then return nil end
    return { value = s.value, none = s.none }
end

-- applied follows saved; restart settings only at boot.
local function ApplyAll(atBoot)
    local paths = {}
    for path in pairs(saved) do paths[path] = true end
    for path in pairs(applied) do paths[path] = true end
    for path in pairs(paths) do
        local e = Settings.entry(path)
        if e and (atBoot or not e.restart) then applied[path] = Wanted(path) end
        if not e then applied[path] = nil end
    end
    Rebuild()
end

local function QueueReload()
    if reloadQueued then return end
    reloadQueued = true
    SetTimeout(RELOAD_DELAY_MS, function()
        reloadQueued = false
        if not (CP.Missions and CP.Missions.reload) then return end
        local ok, err = pcall(CP.Missions.reload)
        if not ok then CP.err(TAG, 'reloading the missions after a settings change failed: %s', tostring(err)) end
    end)
end

local function PushAdmins(data)
    if not (CP.Tablet and CP.Tablet.push and CP.Access and CP.Access.isAdmin) then return end
    for _, s in ipairs(GetPlayers and GetPlayers() or {}) do
        local n = tonumber(s)
        if n and CP.Access.isAdmin(n) then pcall(CP.Tablet.push, n, 'settings', data) end
    end
end

-- After any change: Config, the clients, the missions when needed, the admins' screens.
local function Changed(paths)
    ApplyAll(false)
    SendTo(-1)
    for _, path in ipairs(paths) do
        local e = Settings.entry(path)
        if e and e.reload and not e.restart then
            QueueReload()
            break
        end
    end
    PushAdmins({ paths = paths })
    CP.Hooks.fire('settings:changed', paths)
end

-- Loads the saved settings and puts them over Config. The migrations runner calls it before it reports ready, so
-- every module that waits for the database already reads them; later calls do nothing.
function Settings.boot()
    if loaded then return true end
    local ok = LoadRows()
    if ok then ApplyAll(true) end
    loaded = true
    local n = 0
    for _ in pairs(saved) do n = n + 1 end
    if n > 0 then print(('[crimson-police] %s'):format(CP.L('settings.console_loaded', { n = n }))) end
    -- the clients that asked meanwhile (with nothing read, they get config.lua's values: an empty list)
    for _, src in ipairs(waiting) do SendTo(src) end
    waiting = {}
    return ok
end

function Settings.isLoaded() return loaded end

-- Waits (up to timeoutMs) until the saved settings are loaded: start-up code that reads a setting once calls this.
function Settings.waitLoaded(timeoutMs)
    local waited = 0
    while not loaded and waited < (timeoutMs or 0) do
        Wait(LOAD_POLL_MS)
        waited = waited + LOAD_POLL_MS
    end
    return loaded
end

-- ============================================================================
--                               READING (VIEWS)
-- ============================================================================

local function Pending(e)
    if not e.restart then return false end
    local w, a = Wanted(e.path), applied[e.path]
    if w == nil and a == nil then return false end
    if w == nil or a == nil then return true end
    return w.none ~= a.none or not Same(w.value, a.value)
end

-- One SettingView (web/src/types/settings.ts).
local function View(e)
    local s = saved[e.path]
    local now = U.getPath(Config, e.path)
    local v = {
        path = e.path,
        key = e.key,
        label = e.label,
        desc = e.desc,
        kind = e.kind,
        value = Plain(now),
        isSet = now ~= nil,
        default = Plain(e.default),
        defaultSet = e.default ~= nil,
        changed = s ~= nil and not s.invalid,
        restart = e.restart or nil,
        reload = e.reload or nil,
        pending = Pending(e) or nil,
        nullable = e.nullable or nil,
        integer = e.integer,
        min = e.min,
        max = e.max,
        size = e.size,
        item = e.item,
        allowFalse = e.allowFalse or nil,
        locked = e.locked,
        by = s and s.by or nil,
        at = s and s.at or nil,
        rows = e.rows,
        points = e.points,
        money = e.money,
    }
    if e.optionsFrom then
        v.options = Plain(Effective(e.optionsFrom))
    elseif e.options then
        v.options = e.options
    elseif KIND[e.tpl] == 'enum' then
        v.options = e.tpl.options
    elseif KIND[e.tpl] == 'alts' then
        for _, a in ipairs(e.tpl.alts) do
            if KIND[a] == 'enum' then v.options = a.options end
        end
    end
    if s and s.invalid then
        v.invalid = s.invalid
        v.invalidValue = Plain(s.raw)
    end
    if v.pending then
        -- a restart setting changed since the start: what runs now (value) and what the next start uses (saved)
        if s == nil then
            v.saved, v.savedSet = Plain(e.default), e.default ~= nil
        elseif s.none then
            v.savedSet = false
        else
            v.saved, v.savedSet = Plain(s.value), true
        end
    end
    return v
end
function Settings.view(path)
    local e = Settings.entry(path)
    return e and View(e) or nil
end

local function Health()
    if not (CP.ConfigHealth and CP.ConfigHealth.run) then return {} end
    local ok, items = pcall(CP.ConfigHealth.run)
    return ok and type(items) == 'table' and items or {}
end

-- SettingsView: every section, group and setting, with the counts the screen shows.
function Settings.all()
    local out = { sections = {}, changed = 0, pending = 0, invalid = 0, total = 0 }
    for _, sec in ipairs(Schema().sections) do
        local s = { key = sec.key, title = sec.title, file = sec.file, groups = {}, changed = 0, count = 0 }
        for _, g in ipairs(sec.groups) do
            local gv = { path = g.path, label = g.label, desc = g.desc, settings = {} }
            for _, e in ipairs(g.settings) do
                local v = View(e)
                gv.settings[#gv.settings + 1] = v
                s.count = s.count + 1
                if v.changed then s.changed = s.changed + 1 end
                if v.pending then out.pending = out.pending + 1 end
                if v.invalid then out.invalid = out.invalid + 1 end
            end
            s.groups[#s.groups + 1] = gv
        end
        out.changed = out.changed + s.changed
        out.total = out.total + s.count
        out.sections[#out.sections + 1] = s
    end
    return out
end

-- ============================================================================
--                                   CHANGING
-- ============================================================================

local function Audit(src, action, target, old, new, reason, opts)
    if not (CP.Admin and CP.Admin.audit) then return end
    local n = tonumber(src) or 0
    pcall(CP.Admin.audit, n > 0 and n or 'console', n > 0 and 'admin' or 'console', 'audit', action, target, old, new,
        reason, opts)
end

local function Reply(paths)
    local views = {}
    for _, p in ipairs(paths) do views[#views + 1] = Settings.view(p) end
    local pending = 0
    for _, e in ipairs(Schema().list) do if Pending(e) then pending = pending + 1 end end
    return { settings = views, health = Health(), pending = pending }
end

local function Ident(src)
    local n = tonumber(src) or 0
    if n <= 0 or not (CP.Access and CP.Access.licenseOfSrc) then return nil end
    local ok, lic = pcall(CP.Access.licenseOfSrc, n)
    return ok and type(lic) == 'string' and lic or nil
end

-- One cp_settings_history row: the full old and new values (NULL = config.lua's), who (citizenid and license), why.
local function History(src, path, action, oldJson, newJson, opts)
    opts = opts or {}
    local ok, err = pcall(MySQL.insert.await, [[
        INSERT INTO cp_settings_history (setting_key, action, old_json, new_json, by_actor, by_ident, reason,
          reverts_id, created_at)
        VALUES (?, ?, NULLIF(?, ''), NULLIF(?, ''), ?, NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, 0), NOW())
    ]], {
        path,
        tostring(action):sub(1, 40),
        oldJson or '',
        newJson or '',
        ActorId(src),
        Ident(src) or '',
        type(opts.reason) == 'string' and opts.reason:sub(1, 255) or '',
        math.tointeger(tonumber(opts.revertsId) or 0) or 0,
    })
    if not ok then CP.err(TAG, 'the settings history of %s could not be written: %s', path, tostring(err)) end
end

local function SavedJson(s)
    if not s or s.invalid then return nil end
    return Encode(s.value, s.none)
end

-- Turning a money switch on needs the typed word (the screen asks for it; the server checks it again).
local function MoneyGuard(path, clean, none, opts)
    if not Contains(MONEY_SWITCHES, path) or none or clean ~= true or Effective(path) == true then return nil end
    local word = type(opts) == 'table' and opts.confirm or nil
    if type(word) ~= 'string' or U.trim(word):upper() ~= MONEY_WORD then return 'err.confirm_enable' end
    return nil
end

-- Writes one checked value. 'same' when nothing changes, else the change, or nil + errKey.
local function Commit(src, path, clean, none, opts)
    local e = Settings.entry(path)
    local before = Effective(path)
    local beforeNone = before == nil
    local s = saved[path]
    local isDefault
    if none then isDefault = e.default == nil else isDefault = Same(clean, e.default) end
    if s and not s.invalid and ((none and s.none) or (not none and not s.none and Same(s.value, clean))) then
        return 'same'
    end
    local oldJson = SavedJson(s)
    local noop = isDefault and not s
    if isDefault then
        if s and not DeleteRow(path) then return nil, 'err.internal' end
        saved[path] = nil
    else
        if not WriteRow(path, clean, none, src) then return nil, 'err.internal' end
        saved[path] = { value = clean, none = none or nil, by = ActorId(src), at = os.time() }
    end
    local action = opts.action or (isDefault and 'settingReset' or 'settingChanged')
    if not noop then History(src, path, action, oldJson, not isDefault and Encode(clean, none) or nil, opts) end
    return { path = path, before = before, beforeNone = beforeNone, clean = clean, none = none, isDefault = isDefault }
end

-- A point value changed: a notice to the flags webhook (the change applies to runs that end after it).
local function PointsNotice(src, path, old, new)
    if not (CP.Admin and CP.Admin.webhook) then return end
    pcall(CP.Admin.webhook, 'flags', CP.L('settings.points_notice_title'), CP.L('settings.points_notice', {
        path = path,
        old = old,
        new = new,
        by = ActorId(src),
    }))
end

-- The audit lines of one change: a money switch has its own (never dropped from the webhook queue), a point value
-- also posts a notice to the flags webhook.
local function AuditChange(src, c, opts)
    local e = Settings.entry(c.path)
    if opts.action then
        if not opts.silent then Audit(src, opts.action, opts.target, opts.old, opts.new, opts.reason) end
    elseif e and e.money then
        local on = (not c.none and c.clean == true)
        Audit(src, 'moneySwitch', c.path, c.before == true and 'on' or 'off', on and 'on' or 'off', opts.reason,
            { critical = true })
    else
        Audit(src, c.isDefault and 'settingReset' or 'settingChanged', c.path, Brief(c.before, c.beforeNone),
            Brief(c.clean, c.none), opts.reason or (#c.path > 64 and c.path or nil))
    end
    if e and e.points then PointsNotice(src, c.path, Brief(c.before, c.beforeNone), Brief(c.clean, c.none)) end
end

-- Saves one setting (admins only; the server checks everything again). Setting config.lua's value is a reset.
-- opts: { action, target, old, new, reason, silent } replace the audit line (the mission switches); { confirm }
-- carries the typed word of a money switch; { reason, revertsId } go into the settings history.
function Settings.set(src, path, value, none, opts)
    opts = opts or {}
    if not loaded then return false, 'err.settings_not_ready' end
    local okC, clean = Settings.check(path, value, none, { pending = opts.pending })
    if not okC then return false, clean end
    local errM = MoneyGuard(path, clean, none, opts)
    if errM then return false, errM end
    local c, errC = Commit(src, path, clean, none, opts)
    if not c then return false, errC end
    if c == 'same' then return true, Reply({ path }) end
    Changed({ path })
    AuditChange(src, c, opts)
    return true, Reply({ path })
end

-- Several settings saved as one change: every value is checked first (each sees the others, so a bonus's kind and
-- its value go together), then all are written. changes = { { path, value, none } }.
function Settings.setMany(src, changes, opts)
    opts = opts or {}
    if not loaded then return false, 'err.settings_not_ready' end
    if type(changes) ~= 'table' or #changes == 0 or #changes > 50 then return false, 'err.invalid_payload' end
    local pending = {}
    for _, c in ipairs(changes) do
        if type(c) ~= 'table' or type(c.path) ~= 'string' then return false, 'err.invalid_payload' end
        if pending[c.path] ~= nil then return false, 'err.setting_duplicate' end
        pending[c.path] = c.none and false or c.value
        if pending[c.path] == nil then return false, 'err.setting_type' end
    end
    local checked = {}
    for _, c in ipairs(changes) do
        local okC, clean = Settings.check(c.path, c.value, c.none == true, { pending = pending })
        if not okC then return false, clean end
        local errM = MoneyGuard(c.path, clean, c.none == true, opts)
        if errM then return false, errM end
        checked[#checked + 1] = { path = c.path, clean = clean, none = c.none == true }
    end
    local done, paths = {}, {}
    for _, c in ipairs(checked) do
        local res, errC = Commit(src, c.path, c.clean, c.none, opts)
        if not res then
            if #paths > 0 then Changed(paths) end
            return false, errC
        end
        paths[#paths + 1] = c.path
        if res ~= 'same' then done[#done + 1] = res end
    end
    if #done > 0 then Changed(paths) end
    for _, c in ipairs(done) do AuditChange(src, c, opts) end
    return true, Reply(paths)
end

-- A bonus's kind and value are reset together (one without the other could leave a value its kind can't hold).
local function ResetGroup(path)
    if Matches(path, 'Bonuses.*.kind') or Matches(path, 'Bonuses.*.value') then
        return { Parent(path) .. '.kind', Parent(path) .. '.value' }
    end
    return { path }
end

function Settings.reset(src, path, opts)
    opts = opts or {}
    if not loaded then return false, 'err.settings_not_ready' end
    local e = Settings.entry(path)
    if not e then
        -- a saved row config.lua no longer has can still be removed
        if not (saved[path] and saved[path].invalid) then return false, 'err.setting_unknown' end
    elseif e.locked and not (saved[path] and saved[path].invalid) then
        return false, 'err.setting_locked'
    end
    local paths = {}
    for _, p in ipairs(ResetGroup(path)) do
        if saved[p] then paths[#paths + 1] = p end
    end
    if #paths == 0 then return true, Reply({ path }) end
    local changes = {}
    for _, p in ipairs(paths) do
        local s = saved[p]
        local before = Effective(p)
        if not DeleteRow(p) then return false, 'err.internal' end
        saved[p] = nil
        History(src, p, opts.action or 'settingReset', SavedJson(s), nil, opts)
        changes[#changes + 1] = { path = p, s = s, before = before }
    end
    Changed(paths)
    for _, c in ipairs(changes) do
        local pe = Settings.entry(c.path)
        if opts.action then
            Audit(src, opts.action, opts.target, opts.old, opts.new, opts.reason)
        elseif pe and pe.money then
            Audit(src, 'moneySwitch', c.path, c.before == true and 'on' or 'off', pe.default == true and 'on' or 'off',
                opts.reason, { critical = true })
        else
            Audit(src, 'settingReset', c.path, c.s.invalid and Brief(c.s.raw) or Brief(c.before, c.s.none),
                Brief(pe and pe.default), opts.reason or (#c.path > 64 and c.path or nil))
        end
        if pe and pe.points and not opts.action then
            PointsNotice(src, c.path, Brief(c.before, c.s.none), Brief(pe.default, pe.default == nil))
        end
    end
    return true, Reply(paths)
end

function Settings.resetAll(src, opts)
    opts = opts or {}
    if not loaded then return false, 'err.settings_not_ready' end
    local paths = {}
    for path in pairs(saved) do
        local e = Settings.entry(path)
        if not e or not e.locked then paths[#paths + 1] = path end
    end
    table.sort(paths)
    if #paths == 0 then return true, Reply({}) end
    local old = {}
    for _, path in ipairs(paths) do old[path] = SavedJson(saved[path]) end
    local ok, err = pcall(MySQL.update.await, 'DELETE FROM cp_settings')
    if not ok then
        CP.err(TAG, 'reset all failed: %s', tostring(err))
        return false, 'err.internal'
    end
    -- a row of a locked setting is written back
    local keep = {}
    for path, s in pairs(saved) do
        if not Contains(paths, path) then
            keep[path] = s
            WriteRow(path, s.value, s.none, src)
        end
    end
    saved = keep
    for _, path in ipairs(paths) do History(src, path, 'settingsResetAll', old[path], nil, opts) end
    Changed(paths)
    Audit(src, 'settingsResetAll', nil, tostring(#paths), '0', table.concat(paths, ', '))
    return true, Reply(paths)
end

-- The settings history (cp_settings_history), newest first: { rows, page, pages, total }. opts: { path, page }.
function Settings.history(opts)
    opts = type(opts) == 'table' and opts or {}
    local where, params = '1 = 1', {}
    if type(opts.path) == 'string' and opts.path ~= '' and #opts.path <= 191 then
        where = 'setting_key = ?'
        params[1] = opts.path
    end
    local okN, total = pcall(MySQL.scalar.await, ('SELECT COUNT(*) FROM cp_settings_history WHERE %s'):format(where),
        params)
    if not okN then return nil, 'err.internal' end
    total = math.floor(U.num(total))
    local pages = math.max(1, math.ceil(total / HISTORY_PAGE))
    local page = math.tointeger(tonumber(opts.page) or 1) or 1
    if page < 1 then page = 1 end
    if page > pages then page = pages end
    local okR, rows = pcall(
        MySQL.query.await,
        ([[
        SELECT id, setting_key, action, old_json, new_json, by_actor, by_ident, reason, reverts_id,
          UNIX_TIMESTAMP(created_at) AS created_ts
        FROM cp_settings_history WHERE %s ORDER BY created_at DESC, id DESC LIMIT %d OFFSET %d]]):format(
            where,
            HISTORY_PAGE,
            (page - 1) * HISTORY_PAGE
        ),
        params
    )
    if not okR then return nil, 'err.internal' end
    local out = {}
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do
        out[#out + 1] = Settings._historyRow(r)
    end
    return { rows = out, page = page, pages = pages, total = total }
end

function Settings._historyRow(r)
    local function value(j)
        local doc = U.jsonField(j)
        if type(doc) ~= 'table' then return nil, false end
        if doc.none then return nil, true end
        return doc.v, true
    end
    local old, oldSet = value(r.old_json)
    local new, newSet = value(r.new_json)
    return {
        id = math.tointeger(tonumber(r.id)),
        path = r.setting_key,
        action = r.action,
        old = old,
        oldSaved = oldSet,
        new = new,
        newSaved = newSet,
        by = r.by_actor,
        reason = r.reason,
        revertsId = r.reverts_id ~= nil and math.tointeger(tonumber(r.reverts_id)) or nil,
        createdAt = math.floor(U.num(r.created_ts)),
    }
end

-- One history row (a Revert reads it).
function Settings.historyEntry(id)
    id = math.tointeger(tonumber(id) or 0)
    if not id or id <= 0 then return nil end
    local ok, r = pcall(MySQL.single.await, [[SELECT id, setting_key, action, old_json, new_json, by_actor, by_ident,
        reason, reverts_id, UNIX_TIMESTAMP(created_at) AS created_ts FROM cp_settings_history WHERE id = ?]], { id })
    if not ok or type(r) ~= 'table' then return nil end
    return Settings._historyRow(r)
end

-- ============================================================================
--                        MISSION AND LOCATION SWITCHES
-- ============================================================================
-- On/off for a mission is its id in Config.DisabledMissions; for a location, its label (or its number when the
-- label is not unique in that mission) in Config.DisabledLocations[missionId]. Runs already going finish.

local function LocationKey(def, index)
    local loc = type(def.locations) == 'table' and def.locations[index] or nil
    local label = type(loc) == 'table' and type(loc.label) == 'string' and U.trim(loc.label) or ''
    if label == '' then return index end
    for i, other in ipairs(def.locations) do
        if i ~= index and type(other) == 'table' and other.label == loc.label then return index end
    end
    return loc.label
end

local function LocationOff(list, def, index)
    if type(list) ~= 'table' then return false end
    local loc = type(def.locations) == 'table' and def.locations[index] or nil
    local label = type(loc) == 'table' and loc.label or nil
    for _, v in ipairs(list) do
        if v == index or (label ~= nil and v == label) then return true end
    end
    return false
end
Settings._locationOff = LocationOff

-- { on, defaultOn, changed, locations = { { index, label, on, defaultOn } }, locationsOff } for the Missions screen.
function Settings.missionView(def)
    if type(def) ~= 'table' or type(def.id) ~= 'string' then return nil end
    local off = type(Config.DisabledLocations) == 'table' and Config.DisabledLocations[def.id] or nil
    local defOff = type(DEFAULTS.DisabledLocations) == 'table' and DEFAULTS.DisabledLocations[def.id] or nil
    local view = {
        on = not Contains(Config.DisabledMissions, def.id),
        defaultOn = not Contains(DEFAULTS.DisabledMissions, def.id),
        locations = {},
        locationsOff = 0,
    }
    view.changed = view.on ~= view.defaultOn
    for i, loc in ipairs(def.locations or {}) do
        local on = not LocationOff(off, def, i)
        local defaultOn = not LocationOff(defOff, def, i)
        if not on then view.locationsOff = view.locationsOff + 1 end
        if on ~= defaultOn then view.changed = true end
        view.locations[i] = {
            index = i,
            label = type(loc) == 'table' and loc.label or ('#' .. i),
            on = on,
            defaultOn = defaultOn,
        }
    end
    return view
end

local function MissionDef(id)
    if type(id) ~= 'string' or #id > 64 then return nil end
    return CP.Missions and CP.Missions.get and CP.Missions.get(id) or nil
end

local function OnOff(b) return b and 'on' or 'off' end

function Settings.setMissionEnabled(src, id, enabled)
    if type(enabled) ~= 'boolean' then return false, 'err.invalid_payload' end
    local def = MissionDef(id)
    if not def then return false, 'err.unknown_mission' end
    local list = U.copy(Effective('DisabledMissions') or {})
    local was = not Contains(list, id)
    if was == enabled then return true, Settings.missionView(def) end
    if enabled then
        for i = #list, 1, -1 do
            if list[i] == id then table.remove(list, i) end
        end
    else
        list[#list + 1] = id
    end
    local ok, res = Settings.set(src, 'DisabledMissions', list, false, {
        action = 'missionSwitch',
        target = id,
        old = OnOff(was),
        new = OnOff(enabled),
        reason = def.label,
    })
    if not ok then return false, res end
    return true, Settings.missionView(def)
end

function Settings.setLocationEnabled(src, id, index, enabled)
    if type(enabled) ~= 'boolean' then return false, 'err.invalid_payload' end
    local def = MissionDef(id)
    if not def then return false, 'err.unknown_mission' end
    index = math.tointeger(tonumber(index) or -1)
    if not index or index < 1 or index > #(def.locations or {}) then return false, 'err.invalid_location' end
    local map = U.deepcopy(Effective('DisabledLocations') or {})
    local list = type(map[id]) == 'table' and map[id] or {}
    local was = not LocationOff(list, def, index)
    if was == enabled then return true, Settings.missionView(def) end
    local loc = def.locations[index]
    local label = type(loc) == 'table' and loc.label or nil
    if enabled then
        for i = #list, 1, -1 do
            if list[i] == index or (label ~= nil and list[i] == label) then table.remove(list, i) end
        end
    else
        list[#list + 1] = LocationKey(def, index)
    end
    map[id] = #list > 0 and list or nil
    local ok, res = Settings.set(src, 'DisabledLocations', map, false, {
        action = 'locationSwitch',
        target = ('%s #%d'):format(id, index),
        old = OnOff(was),
        new = OnOff(enabled),
        reason = label,
    })
    if not ok then return false, res end
    return true, Settings.missionView(def)
end

-- The mission and its locations back to config.lua's switches.
function Settings.resetMission(src, id)
    local def = MissionDef(id)
    if not def then return false, 'err.unknown_mission' end
    local list = U.copy(Effective('DisabledMissions') or {})
    for i = #list, 1, -1 do
        if list[i] == id then table.remove(list, i) end
    end
    if Contains(DEFAULTS.DisabledMissions, id) then list[#list + 1] = id end
    local map = U.deepcopy(Effective('DisabledLocations') or {})
    local defOff = type(DEFAULTS.DisabledLocations) == 'table' and DEFAULTS.DisabledLocations[id] or nil
    map[id] = defOff and U.deepcopy(defOff) or nil
    local audit = { action = 'missionSwitchesReset', target = id, reason = def.label }
    local ok1, r1 = Settings.set(src, 'DisabledMissions', list, false, audit)
    if not ok1 then return false, r1 end
    local ok2, r2 = Settings.set(src, 'DisabledLocations', map, false,
        { action = 'missionSwitchesReset', silent = true })
    if not ok2 then return false, r2 end
    return true, Settings.missionView(def)
end

-- ============================================================================
--                                CONFIG HEALTH
-- ============================================================================

local function HealthCheck()
    local out = {}
    local n, bad = 0, 0
    for path, s in pairs(saved) do
        n = n + 1
        if s.invalid then
            bad = bad + 1
            out[#out + 1] = {
                level = 'warn',
                text = CP.L('settings.health.invalid', { path = path, why = CP.L(s.invalid) }),
            }
        end
    end
    local pending = 0
    for _, e in ipairs(Schema().list) do if Pending(e) then pending = pending + 1 end end
    if pending > 0 then
        out[#out + 1] = {
            level = 'warn',
            text = CP.L('settings.health.pending', { n = pending, resource = CP.resource }),
        }
    end
    table.insert(out, 1, {
        level = 'ok',
        text = n > 0 and CP.L('settings.health.changed', { n = n - bad }) or CP.L('settings.health.none'),
    })
    return out
end

-- ============================================================================
--                                     NET
-- ============================================================================

local function AdminOnly(src)
    if not (CP.Permissions and CP.Permissions.can) then return false, 'err.no_permission' end
    local ok, errKey = CP.Permissions.can(src, 'openAdmin')
    if not ok then return false, errKey or 'err.no_permission' end
    return true
end

local function Payload(p) return type(p) == 'table' and p or {} end

CP.Net.callback('admin:getSettings', function(src)
    local ok, err = AdminOnly(src)
    if not ok then return nil, err end
    if not loaded then return nil, 'err.settings_not_ready' end
    return Settings.all()
end, { rate = 2 })

CP.Net.action('server:admin:setSetting', function(src, payload)
    local ok, err = AdminOnly(src)
    if not ok then return false, err end
    if not CP.Net.rateOk(src, 'settings:set', 20, 10000) then return false, 'err.rate_limited' end
    local p = Payload(payload)
    if type(p.path) ~= 'string' then return false, 'err.invalid_payload' end
    local value = p.value
    if type(p.json) == 'string' then
        if #p.json > MAX_JSON then return false, 'err.setting_too_big' end
        local okJ, decoded = pcall(json.decode, p.json)
        if not okJ or decoded == nil then return false, 'err.setting_json' end
        value = decoded
    end
    local reason = type(p.reason) == 'string' and U.trim(p.reason):sub(1, 255) or nil
    return Settings.set(src, p.path, value, p.none == true,
        { confirm = p.confirm, reason = reason ~= '' and reason or nil })
end, { rate = 6 })

-- Several settings as one save (a bonus's kind with its value): { changes = { { path, value? | json?, none? } },
-- confirm?, reason? }.
CP.Net.action('server:admin:setSettings', function(src, payload)
    local ok, err = AdminOnly(src)
    if not ok then return false, err end
    if not CP.Net.rateOk(src, 'settings:set', 20, 10000) then return false, 'err.rate_limited' end
    local p = Payload(payload)
    if type(p.changes) ~= 'table' then return false, 'err.invalid_payload' end
    local changes = {}
    for i, c in ipairs(p.changes) do
        if i > 50 or type(c) ~= 'table' or type(c.path) ~= 'string' then return false, 'err.invalid_payload' end
        local value = c.value
        if type(c.json) == 'string' then
            if #c.json > MAX_JSON then return false, 'err.setting_too_big' end
            local okJ, decoded = pcall(json.decode, c.json)
            if not okJ or decoded == nil then return false, 'err.setting_json' end
            value = decoded
        end
        changes[#changes + 1] = { path = c.path, value = value, none = c.none == true }
    end
    local reason = type(p.reason) == 'string' and U.trim(p.reason):sub(1, 255) or nil
    return Settings.setMany(src, changes, { confirm = p.confirm, reason = reason ~= '' and reason or nil })
end, { rate = 4 })

CP.Net.action('server:admin:resetSetting', function(src, payload)
    local ok, err = AdminOnly(src)
    if not ok then return false, err end
    local p = Payload(payload)
    if type(p.path) ~= 'string' then return false, 'err.invalid_payload' end
    return Settings.reset(src, p.path)
end, { rate = 6 })

CP.Net.action('server:admin:resetAllSettings', function(src)
    local ok, err = AdminOnly(src)
    if not ok then return false, err end
    if not CP.Net.rateOk(src, 'settings:resetAll', 1, 5000) then return false, 'err.rate_limited' end
    return Settings.resetAll(src)
end, { rate = 2 })

CP.Net.action('server:admin:setMissionEnabled', function(src, payload)
    local ok, err = AdminOnly(src)
    if not ok then return false, err end
    local p = Payload(payload)
    return Settings.setMissionEnabled(src, p.missionId, p.enabled)
end, { rate = 6 })

CP.Net.action('server:admin:setLocationEnabled', function(src, payload)
    local ok, err = AdminOnly(src)
    if not ok then return false, err end
    local p = Payload(payload)
    return Settings.setLocationEnabled(src, p.missionId, p.index, p.enabled)
end, { rate = 6 })

CP.Net.action('server:admin:resetMissionSwitches', function(src, payload)
    local ok, err = AdminOnly(src)
    if not ok then return false, err end
    return Settings.resetMission(src, Payload(payload).missionId)
end, { rate = 4 })

-- The settings history: the audit lines of this module, newest first (optionally of one setting).
CP.Net.callback('admin:getSettingsHistory', function(src, args)
    local ok, err = AdminOnly(src)
    if not ok then return nil, err end
    args = Payload(args)
    local marks, params = {}, {}
    for i, a in ipairs(ACTIONS) do
        marks[i] = '?'
        params[i] = a
    end
    local where = ('a.action IN (%s)'):format(table.concat(marks, ', '))
    if type(args.path) == 'string' and args.path ~= '' and #args.path <= 191 then
        where = where .. ' AND (a.target = ? OR a.reason = ?)'
        params[#params + 1] = args.path:sub(1, 64)
        params[#params + 1] = args.path
    end
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
    local okN, total = pcall(MySQL.scalar.await, ('SELECT COUNT(*) FROM cp_audit a WHERE %s'):format(where), params)
    if not okN then return nil, 'err.internal' end
    total = math.floor(U.num(total))
    local pages = math.max(1, math.ceil(total / HISTORY_PAGE))
    local page = math.tointeger(tonumber(args.page) or 1) or 1
    if page < 1 then page = 1 end
    if page > pages then page = pages end
    local q = {}
    for i, v in ipairs(params) do q[i] = v end
    q[#q + 1] = HISTORY_PAGE
    q[#q + 1] = (page - 1) * HISTORY_PAGE
    local okR, rows = pcall(
        MySQL.query.await,
        ([[
        SELECT a.id, a.actor, a.role, a.action, a.target, a.old_value, a.new_value, a.reason,
          UNIX_TIMESTAMP(a.created_at) AS created_ts, o.display_name
        FROM cp_audit a LEFT JOIN cp_officers o ON o.citizenid = a.actor
        WHERE %s ORDER BY a.created_at DESC, a.id DESC LIMIT ? OFFSET ?]]):format(where),
        q
    )
    if not okR then return nil, 'err.internal' end
    local out = {}
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do
        out[#out + 1] = {
            id = math.tointeger(tonumber(r.id)),
            actor = r.actor,
            actorName = r.display_name,
            role = r.role,
            action = r.action,
            target = r.target,
            oldValue = r.old_value,
            newValue = r.new_value,
            reason = r.reason,
            createdAt = math.floor(U.num(r.created_ts)),
        }
    end
    return { rows = out, page = page, pages = pages, total = total }
end, { rate = 3 })

-- A client that started asks for the settings (the reply waits until they are loaded).
RegisterNetEvent(CP.e('server:settingsHello'), function()
    local src = source
    if not CP.Net.rateOk(src, 'settings:hello', 2, 10000) then return end
    if loaded then return SendTo(src) end
    if #waiting < 1024 then waiting[#waiting + 1] = src end
end)

-- ============================================================================
--                                    START
-- ============================================================================

CreateThread(function()
    if CP.ConfigHealth and CP.ConfigHealth.register then CP.ConfigHealth.register('settings', HealthCheck) end
    -- the migrations runner normally loads the settings before it reports ready; this covers a runner without it
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
    if not loaded then Settings.boot() end
end)

-- Test hooks (not part of the contract).
Settings._defaults = function() return DEFAULTS end
Settings._saved = function() return saved end
Settings._applied = function() return applied end
Settings._tokenize = Tokenize
Settings._parseKeys = ParseKeys
Settings._isCode = IsCode
Settings._shape = Shape
Settings._reload = function()
    loaded = false
    saved, applied = {}, {}
    return Settings.boot()
end
