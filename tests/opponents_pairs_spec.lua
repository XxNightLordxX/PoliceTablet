-- CP.Opponents identity and pairs (step V7): the self rule (characters, licenses, linked accounts), the duty maps,

local H = dofile('tests/harness.lua')

local DAY = 86400
local LIC = 'license:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1'   -- officer A's license: identifier
local LIC2 = 'license2:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa2'  -- officer A's license2 (his users row), not connected
local LICB = 'license:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb1'
local LICC = 'license:cccccccccccccccccccccccccccccccccccccccc1'
local LICD = 'license:dddddddddddddddddddddddddddddddddddddddd1'
local LICE = 'license:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee1'
local A, B, C, D, E = 'OFFA0001', 'CRIMB001', 'CRIMC001', 'OFFD0001', 'CRIME001'

local function Copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = Copy(x) end
    return setmetatable(out, getmetatable(v))
end

-- ============================================================================
--                       qbx_core, QBOX'S TABLES, PLAYERS
-- ============================================================================

local players = {}   -- [src] = a loaded character's Player ({ PlayerData = ... }), kept across restarts
local function Character(src, cid, license, job, onduty, coords)
    H.players[src] = H.players[src] or { ace = {}, identifiers = { license } }
    H.players[src].coords = coords or H.players[src].coords or vec3(src * 1000.0, 0.0, 30.0)
    players[src] = {
        PlayerData = {
            source = src,
            citizenid = cid,
            license = license,
            charinfo = { firstname = 'First' .. src, lastname = 'Last' },
            job = {
                name = job or 'unemployed',
                label = job or 'Civilian',
                onduty = onduty == true,
                grade = { level = 1 },
            },
            metadata = { ishandcuffed = false, isdead = false, inlaststand = false, injail = 0 },
        },
    }
end

H.sql('DROP TABLE IF EXISTS players')
H.sql([[CREATE TABLE players (id int NOT NULL AUTO_INCREMENT, userId int UNSIGNED DEFAULT NULL,
    citizenid varchar(50) NOT NULL, cid int DEFAULT NULL, license varchar(255) NOT NULL, name varchar(255) NOT NULL,
    PRIMARY KEY (citizenid), KEY id (id), KEY license (license))]])
H.sql('DROP TABLE IF EXISTS users')
H.sql([[CREATE TABLE users (userId int UNSIGNED NOT NULL AUTO_INCREMENT, username varchar(255) DEFAULT NULL,
    license varchar(50) DEFAULT NULL, license2 varchar(50) DEFAULT NULL, fivem varchar(20) DEFAULT NULL,
    discord varchar(30) DEFAULT NULL, PRIMARY KEY (userId))]])
-- officer A: OFFA0001 (his own), OFFA0002 (another character, same license:), OFFA0003 (made on Qbox under his
-- license2:, which is not among his identifiers this session); the others one character each
H.sql([[INSERT INTO players (userId, citizenid, cid, license, name) VALUES (1, 'OFFA0001', 1, ?, 'a'),
    (1, 'OFFA0002', 2, ?, 'a'), (1, 'OFFA0003', 3, ?, 'a'), (2, 'CRIMB001', 1, ?, 'b'), (3, 'CRIMC001', 1, ?, 'c'),
    (4, 'OFFD0001', 1, ?, 'd'), (5, 'CRIME001', 1, ?, 'e'), (5, 'CRIME002', 2, ?, 'e')]],
    { LIC, LIC, LIC2, LICB, LICC, LICD, LICE, LICE })
H.sql([[INSERT INTO users (userId, username, license, license2) VALUES (1, 'Ada', ?, ?), (2, 'Bo', ?, NULL),
    (3, 'Cy', ?, NULL), (4, 'Di', ?, NULL), (5, 'Ed', ?, NULL)]], { LIC, LIC2, LICB, LICC, LICD, LICE })
for _, t in ipairs({ 'cp_pvp_pairs', 'cp_officers', 'cp_audit' }) do H.sql('DELETE FROM ' .. t) end

-- ============================================================================
--                         ONE START OF CRIMSON-POLICE
-- ============================================================================
-- Every database statement of the modules is counted (MySQL and, with the database off, the real oxmysql the Qbox
-- lookups use).

-- The players (vec3 exists once H.boot has run): the first start only.
local function Fixtures()
    Character(1, A, LIC, 'sast', true, vec3(0.0, 0.0, 30.0))
    Character(2, B, LICB)
    Character(3, C, LICC)
    Character(4, D, LICD, 'sast', true, vec3(5000.0, 0.0, 30.0))
    Character(5, E, LICE, nil, nil, vec3(-5000.0, 0.0, 30.0))
    H.players[1].identifiers = { LIC, 'discord:900', 'fivem:900', 'ip:10.0.0.1' }
    H.players[1].tokens = { '3:aaaa', '4:aaaa' }
    H.players[2].identifiers = { LICB, 'discord:200', 'fivem:200', 'ip:10.0.0.2' }
    H.players[2].tokens = { '3:bbbb' }
end

local stmts = {}
local function Proxy(db)
    if type(db) ~= 'table' then return db end
    local out = {}
    for _, kind in ipairs({ 'query', 'single', 'scalar', 'insert', 'update' }) do
        local real = db[kind]
        if type(real) == 'table' and type(real.await) == 'function' then
            out[kind] = setmetatable({
                await = function(sql, ...)
                    stmts[#stmts + 1] = tostring(sql)
                    return real.await(sql, ...)
                end,
            }, { __index = real })
        end
    end
    return setmetatable(out, { __index = db })
end
local function Statements(pattern)
    local n = 0
    for _, s in ipairs(stmts) do if pattern == nil or s:find(pattern) then n = n + 1 end end
    return n
end

local flags, audits = {}, {}
local featureOn = false   -- Config.LiveCrime.enabled after each start (config.lua ships it off)
local function Boot(pairsFirst)
    H.boot({ side = 'server', realLocale = true })
    _G.GetConvar = function(_, default) return default end
    _G.PerformHttpRequest = function() end
    if not players[1] then Fixtures() end
    _G.MySQL = Proxy(_G.MySQL)
    if CP.Storage and CP.Storage.realMySQL then CP.Storage.realMySQL = Proxy(CP.Storage.realMySQL) end
    H.exportsMock.qbx_core = {
        GetPlayer = function(src) return Copy(players[tonumber(src)]) end,
        GetPlayerByCitizenId = function(cid)
            for _, p in pairs(players) do
                if p.PlayerData.citizenid == cid then return Copy(p) end
            end
            return nil
        end,
        GetQBPlayers = function() return Copy(players) end,
        GetJobs = function() return {} end,
    }
    CP.Admin = {
        audit = function(...) audits[#audits + 1] = { ... } end,
    }
    CP.Runs = {
        dispatch = function() return true end,
    }
    CP.AntiCheat = H.realAntiCheat()
    local realFlag = CP.AntiCheat.flag
    CP.AntiCheat.flag = function(...)
        flags[#flags + 1] = { ... }
        return realFlag(...)
    end
    -- the real access module without its qbx listeners (they write officer rows on every load)
    CP.Qbx = {
        onDutyChange = function() end,
        onGroupUpdate = function() end,
        onJobChange = function() end,
        onPlayerLoaded = function() end,
        onPlayerUnload = function() end,
        getOnlinePlayers = function() return {} end,
    }
    H.load('modules/access/server.lua')
    CP.Qbx = nil
    H.load('modules/integrations/qbx/server.lua')
    H.load('modules/schedule/server.lua')
    -- fxmanifest's globs load the two files in no fixed order: both orders work
    if pairsFirst then H.load('modules/opponents/pairs/server.lua') end
    H.load('modules/opponents/server.lua')
    if not pairsFirst then H.load('modules/opponents/pairs/server.lua') end
    Config.LiveCrime.enabled = featureOn
    H.step(0)
    return CP.Opponents
end

local function Restart(pairsFirst)
    H.advance(1000)   -- the writes in their threads finish first
    H.restart()
    return Boot(pairsFirst)
end

local function Rows(kind)
    return H.sql('SELECT kind, officer_citizenid, suspect_citizenid, scored FROM cp_pvp_pairs WHERE kind = ?', { kind })
end

local bootAt = H.time
local Opp = Boot(false)
local RS = Config.RealSuspects

-- ============================================================================
--                       1. THE SELF RULE (Opp.selfBlock)
-- ============================================================================

do
    H.eq(Config.LiveCrime.enabled, false, 'live crimes ship off')
    H.eq(table.concat(RS.identityMatch.block, ','), 'license,license2,discord,fivem,steam,xbl,live',
        'identityMatch.block ships the account kinds')
    H.eq(table.concat(RS.identityMatch.flag, ','), 'ip,token', 'identityMatch.flag ships ip and token')

    stmts = {}
    local blocked, kind, fl = Opp.selfBlock(1, { A })
    H.ok(blocked == true and kind == 'own_character' and #fl == 0, 'the same character -> own_character')
    H.eq(Statements('FROM cp_officers WHERE license'), 1, 'the first call reads his characters (one license)')
    blocked, kind = Opp.selfBlock(1, { B, 'OFFA0002' })
    H.ok(blocked == true and kind == 'own_character',
        'another character of the same license (offline, in a crew) -> own_character')
    blocked, kind = Opp.selfBlock(1, { 'OFFA0003' })
    H.ok(blocked == true and kind == 'own_license',
        'a character under his license2: (his users row, not connected now) -> own_license')
    blocked, kind = Opp.selfBlock(1, { 'GHOST001' })
    H.ok(blocked == true and kind == 'own_license', 'a suspect whose license is not known -> refused (own_license)')

    stmts = {}
    local n0 = Statements()
    blocked, kind, fl = Opp.selfBlock(1, { B })
    H.ok(blocked == false and kind == nil and #fl == 0, 'another player with nothing shared: allowed, no flag')
    H.eq(Statements() - n0, 0, 'a cache hit with an online suspect runs no database statement at all')
    H.eq(Statements('FROM cp_officers WHERE license'), 0, 'and the cp_officers query ran once in all')
    blocked = Opp.selfBlock(1, { [B] = 2 })
    H.eq(blocked, false, 'a map { [cid] = src } works too')

    H.players[2].identifiers = { LICB, 'discord:900', 'fivem:200', 'ip:10.0.0.2' }
    local match
    blocked, kind, fl, match = Opp.selfBlock(1, { B })
    H.ok(blocked == true and kind == 'linked_account', 'the same discord identifier -> linked_account')
    H.ok(match and match.cid == B and match.kinds[1] == 'discord', 'the match names the suspect and the kind only')
    RS.identityMatch.block = { 'license', 'license2', 'fivem', 'steam', 'xbl', 'live' }
    H.eq((Opp.selfBlock(1, { B })), false, 'with discord left out of identityMatch.block it is allowed')
    RS.identityMatch.block = { 'license', 'license2', 'discord', 'fivem', 'steam', 'xbl', 'live' }

    -- whole strings grouped by kind: license:<x> never matches license2:<x>
    H.players[1].identifiers = { 'license2:abcdef0123456789', LIC, 'discord:900', 'fivem:900', 'ip:10.0.0.1' }
    H.players[2].identifiers = { 'license:abcdef0123456789', LICB, 'discord:200', 'fivem:200', 'ip:10.0.0.2' }
    blocked, kind = Opp.selfBlock(1, { B })
    H.ok(blocked == false and kind == nil, '\'license:a\' vs \'license2:a\' -> not blocked')
    H.players[1].identifiers = { LIC, 'discord:900', 'fivem:900', 'ip:10.0.0.1' }
    H.players[2].identifiers = { LICB, 'discord:200', 'fivem:200', 'ip:10.0.0.1' }

    blocked, kind, fl, match = Opp.selfBlock(1, { B })
    H.ok(blocked == false and fl[1] == 'rs_linked_accounts' and #fl == 1, 'the same ip -> allowed and flagged')
    H.ok(match and match.cid == B and match.kinds[1] == 'ip', 'the flag names the kind (ip), never the address')
    H.players[2].identifiers = { LICB, 'discord:200', 'fivem:200', 'ip:10.0.0.2' }
    H.players[2].tokens = { '9:zzzz', '4:aaaa' }
    blocked, _, fl, match = Opp.selfBlock(1, { B })
    H.ok(blocked == false and fl[1] == 'rs_linked_accounts' and match.kinds[1] == 'token',
        'the same hardware token (GetPlayerToken) -> allowed and flagged')
    H.players[2].tokens = { '3:bbbb' }

    for _, a in ipairs(audits) do
        for _, v in ipairs(a) do
            H.ok(type(v) ~= 'string' or not v:find('10.0.0', 1, true), 'no identifier is ever audited')
        end
    end

    -- SameUserStrict: an unknown license refuses (critic 2 #22)
    H.eq(Opp.sameUserStrict(nil, LIC), true, 'SameUserStrict(nil, x) refuses')
    H.eq(Opp.sameUserStrict(LIC, ''), true, 'SameUserStrict(x, \'\') refuses')
    H.eq(Opp.sameUserStrict(LIC, LIC2), true, 'license: and license2: of one users row are one player')
    H.eq(Opp.sameUserStrict(LIC, LICB), false, 'two players are not')

    -- a character switch reads his characters again
    stmts = {}
    TriggerEvent('QBCore:Server:OnPlayerUnload', 1)
    Character(1, 'OFFA0002', LIC, 'sast', true)
    TriggerEvent('QBCore:Server:PlayerLoaded', Copy(players[1]))
    H.step(0)
    blocked, kind = Opp.selfBlock(1, { A })
    H.ok(blocked == true and kind == 'own_character', 'after a switch his first character is still his own')
    H.eq(Statements('FROM cp_officers WHERE license'), 1, 'and the switch cleared the cache: one new read')
    Opp.selfBlock(1, { B })
    H.eq(Statements('FROM cp_officers WHERE license'), 1, 'then cached again')
    TriggerEvent('QBCore:Server:OnPlayerUnload', 1)
    Character(1, A, LIC, 'sast', true)
    TriggerEvent('QBCore:Server:PlayerLoaded', Copy(players[1]))
    H.step(0)
    H.eq(#H.sql('SELECT id FROM cp_pvp_pairs'), 0, 'with the features off nothing was written to the ledger')
end

-- ============================================================================
--                            2. CASES AND THE CAPS
-- ============================================================================

featureOn = true
Config.LiveCrime.enabled = true

local runSeq = 0
local cidOfSrc = { [1] = A, [4] = D }
local function NewRun(officers)
    runSeq = runSeq + 1
    local run = {
        id = ('pair-run-%04d'):format(runSeq),
        missionId = 'live_crime',
        seed = 77 + runSeq,
        state = 'in_progress',
        order = {},
        participants = {},
        objectiveIndex = 1,
    }
    for _, src in ipairs(officers) do
        run.order[#run.order + 1] = src
        run.participants[src] = { src = src, citizenid = cidOfSrc[src], status = 'active', score = {} }
    end
    return run
end

-- Seconds of the case: the server clock and the game timer move together.
local function Pass(seconds)
    H.time = H.time + seconds
    H.advance(seconds * 1000, 1000)
end

-- A whole case: open, fn(run, case) plays it, the run ends, the pairs are recorded and checked (as V14 / V22b do).
local function Case(officers, suspects, opts)
    opts = opts or {}
    local run = NewRun(officers)
    local case = Opp.open(run, { kind = 'live', index = 1, members = suspects })
    if opts.play then opts.play(run, case) end
    CP.Hooks.fire('run:ended', run)
    local rows = {}
    for _, src in ipairs(officers) do
        for _, cid in ipairs(suspects) do
            rows[#rows + 1] = {
                officer = cidOfSrc[src],
                suspect = cid,
                scored = opts.scored ~= false,
                outcome = opts.outcome,
            }
        end
    end
    local kept = Opp.recordPairs(run, rows)
    return run, case, Opp.checkPairFlags(run), kept
end

do
    local run, case, _, kept = Case({ 1 }, { B }, {
        play = function() Pass(60) end,
    })
    H.ok(case ~= nil and kept == 1, 'a case of officer A and suspect B: one ledger row')
    H.eq(Opp.recordPairs(run, { { officer = A, suspect = B, scored = true } }), 0, 'the same row twice is kept once')
    H.eq(Opp.lastSuspectAt(B), H.time, 'lastSuspectAt: the case closed with him as a suspect')
    H.advance(1000)
    local r = Rows('live')
    H.ok(#r == 1 and r[1].officer_citizenid == A and r[1].suspect_citizenid == B, 'written to cp_pvp_pairs')
    local full = H.sql('SELECT run_uuid, officer_license, suspect_license, until_at FROM cp_pvp_pairs WHERE kind = ?',
        { 'live' })[1]
    H.ok(
        full.run_uuid == run.id and full.officer_license == LIC and full.suspect_license == LICB
            and full.until_at == nil,
        'with the run, both licenses and no until_at'
    )

    local ok, why = Opp.pairOk(A, B)
    H.ok(ok == false and why == 'pair_cooldown', 'pairOk: false right after a scored case of the pair')
    H.eq((Opp.pairOk(D, B)), true, 'another officer may still score on him')
    H.time = H.time + 23 * 3600
    H.eq((Opp.pairOk(A, B)), false, 'still false 23 h later (pairCooldownHours 24)')
    H.time = H.time + 3601
    H.eq((Opp.pairOk(A, B)), true, 'true after 24 h')

    Case({ 1 }, { C }, {
        scored = false,
        play = function() Pass(60) end,
    })
    ok, why = Opp.pairOk(A, C)
    H.ok(ok == false and why == 'suspect_cooldown', 'a case that scored nothing: suspectCooldownMinutes')
    H.time = H.time + 31 * 60
    H.eq((Opp.pairOk(A, C)), true, 'true 31 minutes later')
end

-- the day caps: a fresh day (Config.Time.resetHour)
local dayStart
do
    dayStart = CP.Schedule.dayStart(H.time) + DAY
    H.time = dayStart + 3600
    H.eq(Opp.suspectDayCount(B), 0, 'yesterday\'s catch is not today\'s')
    Case({ 1, 4 }, { B }, {
        play = function() Pass(60) end,
    })
    H.eq(Opp.suspectDayCount(B), 1, 'one case with two officers is one catch of the suspect')
    Case({ 4 }, { B }, {
        play = function() Pass(60) end,
    })
    H.eq(Opp.suspectDayCount(B), 2, 'two cases: 2 (maxCatchesPerSuspectDay ships 2)')
    H.eq(RS.maxCatchesPerSuspectDay, 2, 'maxCatchesPerSuspectDay ships 2')
    Case({ 4 }, { B }, {
        scored = false,
        play = function() Pass(60) end,
    })
    H.eq(Opp.suspectDayCount(B), 2, 'a case that scored nothing is not a catch')
    Case({ 4 }, { C }, {
        scored = false,
        outcome = 'gone',
        play = function() Pass(10) end,
    })
    H.eq(Opp.officerDayCount(D, 'live'), 3, 'officerDayCount: his 3 live cases today, not the one nobody reached')
    H.eq(Opp.officerDayCount(D, 'volunteer'), 0, 'and no volunteer case')
    H.eq(Opp.officerDayCount(D), 3, 'both kinds: 3')
    H.eq(Opp.officerDayCount(A), 1, 'officer A: 1 today')
    H.eq((Opp.pairOk(D, C)), true, 'a case nobody reached (outcome gone) is no case together: no cooldown')
end

-- ============================================================================
--                        3. A RESTART KEEPS THE LEDGER
-- ============================================================================

do
    local lastB = Opp.lastSuspectAt(B)
    stmts = {}
    Opp = Restart(true)
    local n = 0
    for _, s in ipairs(stmts) do if s:find('cp_pvp_pairs', 1, true) then n = n + 1 end end
    H.eq(n, 6, 'the start pruned the ledger (4 statements) and read it (2), in its own thread')
    H.ok(Opp ~= nil and Opp.pairOk ~= nil, 'started again (the pairs file loaded before the core)')
    H.eq(Opp.suspectDayCount(B), 2, 'the suspect\'s catches today are read back')
    H.eq(Opp.officerDayCount(D, 'live'), 3, 'and the officer\'s cases (outcome gone still left out)')
    local ok, why = Opp.pairOk(D, B)
    H.ok(ok == false and why == 'pair_cooldown', 'the pair cooldown still holds after the restart')
    H.eq(Opp.lastSuspectAt(B), lastB, 'lastSuspectAt is read from the ledger')
    H.eq(Opp.dutySince(A), H.time, 'an officer on duty when the resource started: since the start')
    stmts = {}
    Opp.pairOk(A, B)
    Opp.suspectDayCount(B)
    Opp.officerDayCount(D, 'live')
    Opp.excluded(B)
    Opp.suspended(D)
    H.eq(Statements(), 0, 'every cap is a memory lookup (no database statement)')
end

-- ============================================================================
--                        4. THE PAIR-REPEAT FLAG (C27)
-- ============================================================================

local function Flagged(run)
    local out = {}
    for _, f in ipairs(flags) do
        if f[1] == run and f[3] == 'rs_pair_repeat' then out[#out + 1] = f end
    end
    return out
end

-- no second sign: armed, detained after 2 minutes, a 10 minute case
local function Plain(run)
    Opp.noteArmed(E)
    Pass(120)
    Opp.setState(run, E, 'detained')
    Pass(480)
end

do
    H.time = H.time + 2 * 3600
    local run1, _, f1 = Case({ 1 }, { E }, { play = Plain })
    H.eq(#f1, 0, 'the first case of a pair never flags')
    local run2, _, f2 = Case({ 1 }, { E }, { play = Plain })
    H.ok(#f2 == 0 and #Flagged(run2) == 0, 'the second case of the pair without a second sign does not flag')
    local run3, _, f3 = Case({ 1 }, { E }, {
        play = function(run)
            Opp.noteArmed(E)
            Pass(30)
            Opp.setState(run, E, 'detained')
            Pass(570)
        end,
    })
    H.ok(#f3 == 1 and f3[1] == A, 'the third case with a detain 30 s after the start flags rs_pair_repeat')
    local fl = Flagged(run3)[1]
    H.ok(fl and fl[2] == 1 and run3.participants[1].flagged and run3.participants[1].flagged.reason == 'rs_pair_repeat',
        'on that officer (his own points only)')
    H.eq(run3.flagged, nil, 'never the whole run')
    H.ok(
        fl and tostring(fl[4]):find('3 cases', 1, true) and tostring(fl[4]):find('30 s after the case started', 1, true),
        'the detail says how often and which sign: ' .. tostring(fl and fl[4]))
    H.eq(#Flagged(run1), 0, 'the first run stays unflagged')

    -- a second sign on a new pair: never by itself
    local run4, _, f4 = Case({ 4 }, { E }, {
        play = function(run)
            Pass(20)
            Opp.setState(run, E, 'detained')
            Pass(40)
        end,
    })
    H.ok(#f4 == 0 and #Flagged(run4) == 0, 'a fast, short case of a new pair alone does not flag')

    -- by license: the same player as another character
    TriggerEvent('QBCore:Server:OnPlayerUnload', 5)
    Character(5, 'CRIME002', LICE)
    TriggerEvent('QBCore:Server:PlayerLoaded', Copy(players[5]))
    H.step(0)
    local run5, _, f5 = Case({ 4 }, { 'CRIME002' }, {
        play = function()
            Opp.noteArmed('CRIME002')
            Pass(90)
        end,
    })
    H.ok(#f5 == 1 and f5[1] == D, 'the same suspect player on another character (by license) and a 90 s case flags')
    H.ok(tostring(Flagged(run5)[1] and Flagged(run5)[1][4]):find('only 90 s', 1, true) ~= nil, 'the short-case sign')
    TriggerEvent('QBCore:Server:OnPlayerUnload', 5)
    Character(5, E, LICE)
    TriggerEvent('QBCore:Server:PlayerLoaded', Copy(players[5]))
    H.step(0)

    -- never armed and still after contact (officer A next to him), against never armed and running
    H.players[5].coords = vec3(20.0, 0.0, 30.0)
    local run6, _, f6 = Case({ 1 }, { E }, {
        play = function(run)
            Pass(120)
            Opp.setState(run, E, 'detained')
            Pass(480)
        end,
    })
    H.ok(#f6 == 1, 'never armed and he moved under 30 m after contact: flagged')
    H.ok(tostring(Flagged(run6)[1] and Flagged(run6)[1][4]):find('never armed', 1, true) ~= nil,
        'the no-resistance sign')
    local run7, _, f7 = Case({ 1 }, { E }, {
        play = function(run)
            Pass(5)
            for i = 1, 40 do
                H.players[5].coords = vec3(20.0 + i * 5.0, 0.0, 30.0)
                Pass(1)
            end
            Pass(30)
            Opp.setState(run, E, 'detained')
            Pass(530)
        end,
    })
    H.ok(#f7 == 0 and #Flagged(run7) == 0, 'never armed but he ran 200 m after contact: no flag')
    H.players[5].coords = vec3(-5000.0, 0.0, 30.0)
end

-- ============================================================================
--                   5. ADMIN BLOCKS, EXCLUSIONS, SUSPENSIONS
-- ============================================================================

do
    H.time = H.time + 3 * DAY   -- every cooldown above is over
    H.eq((Opp.pairOk(A, C)), true, 'no block yet')
    local ok, untilAt = Opp.block(A, C, 1)
    H.ok(ok == true and untilAt == H.time + DAY, 'Opp.block for 1 day')
    local okP, why = Opp.pairOk(A, C)
    H.ok(okP == false and why == 'blocked', 'pairOk: blocked')
    H.ok(Opp.exclude(C, 2) and Opp.excluded(C), 'Opp.exclude: he is excluded')
    H.ok(Opp.suspend(D, 3) and Opp.suspended(D), 'Opp.suspend: the officer is suspended')
    H.ok(not Opp.excluded(B) and not Opp.suspended(A), 'nobody else')
    local bad, err = Opp.block(A, A, 1)
    H.ok(bad == false and err == 'invalid_citizenid', 'a block of an officer with himself is refused')
    bad, err = Opp.exclude(C, 0)
    H.ok(bad == false and err == 'invalid_days', '0 days is refused')
    bad, err = Opp.suspend('bad cid', 1)
    H.ok(bad == false and err == 'invalid_citizenid', 'a bad citizenid is refused')

    Opp = Restart(false)
    H.eq((Opp.pairOk(A, C)), false, 'the block holds after a restart')
    H.ok(Opp.excluded(C) and Opp.suspended(D), 'and so do the exclusion and the suspension')
    H.time = H.time + DAY + 1
    H.eq((Opp.pairOk(A, C)), true, 'the block ends at its until_at')
    H.ok(Opp.excluded(C) and Opp.suspended(D), 'the longer ones go on')
    H.time = H.time + DAY
    H.ok(not Opp.excluded(C) and Opp.suspended(D), 'the exclusion ends at its until_at')
    H.time = H.time + DAY
    H.ok(not Opp.suspended(D), 'the suspension ends at its until_at')
end

-- ============================================================================
--                        6. RETENTION (the daily pass)
-- ============================================================================

do
    -- the next daily reset (CP.Schedule's own 30 s check fires the daily listeners below)
    H.time = CP.Schedule.dayStart(H.time) + DAY + 60
    local now = H.time
    H.sql('DELETE FROM cp_pvp_pairs')
    H.sql(
        [[INSERT INTO cp_pvp_pairs (kind, run_uuid, officer_citizenid, suspect_citizenid, scored, until_at, created_at)
        VALUES ('live', 'old-run', ?, ?, 1, NULL, FROM_UNIXTIME(?)),
        ('volunteer', 'old-vol', ?, ?, 0, NULL, FROM_UNIXTIME(?)),
        ('duty_off', NULL, ?, '', 0, NULL, FROM_UNIXTIME(?)),
        ('live', 'new-run', ?, ?, 1, NULL, FROM_UNIXTIME(?)),
        ('block', NULL, ?, ?, 0, FROM_UNIXTIME(?), FROM_UNIXTIME(?)),
        ('exclude', NULL, '', ?, 0, FROM_UNIXTIME(?), FROM_UNIXTIME(?))]], {
            A,
            B,
            now - 31 * DAY,
            A,
            B,
            now - 40 * DAY,
            D,
            now - 31 * DAY,
            A,
            B,
            now - 29 * DAY,
            A,
            C,
            now + 5 * DAY,
            now - 40 * DAY,
            C,
            now - 60,
            now - 3 * DAY,
        })
    H.eq(Config.RealSuspects.pairLedgerDays, 30, 'pairLedgerDays ships 30')
    H.advance(31000, 1000)
    local left = {}
    for _, r in ipairs(H.sql('SELECT kind, run_uuid FROM cp_pvp_pairs ORDER BY id')) do
        left[#left + 1] = r.kind .. (r.run_uuid and (':' .. r.run_uuid) or '')
    end
    H.eq(table.concat(left, ','), 'live:new-run,block',
        'the daily pass deletes case and duty_off rows older than 30 days and the expired exclusion, keeps the block')
end

-- ============================================================================
--                     7. THE DUTY MAPS (job hops, restart)
-- ============================================================================

do
    local before = #Rows('duty_off')
    players[4].PlayerData.job.onduty = false
    TriggerEvent('QBCore:Server:SetDuty', 4, false)
    H.step(0)
    local offAt = H.time
    H.eq(Opp.lastPoliceAt(D), offAt, 'lastPoliceAt: he left duty now')
    H.advance(1000)
    H.eq(#Rows('duty_off'), before + 1, 'a duty_off ledger row')
    local ok, why = Opp.eligible(4)
    H.ok(ok == false and why == 'job_hop', 'Opp.eligible: no suspect within jobHopMinutes of police duty')

    Opp = Restart(false)
    H.eq(Opp.lastPoliceAt(D), offAt, 'lastPoliceAt survives a restart through its duty_off row')
    ok, why = Opp.eligible(4)
    H.ok(ok == false and why == 'job_hop', 'and the job-hop rule still holds')
    H.time = H.time + 31 * 60
    H.eq((Opp.eligible(4)), true, 'after jobHopMinutes he may be a suspect')

    players[4].PlayerData.job.onduty = true
    TriggerEvent('QBCore:Server:SetDuty', 4, true)
    H.step(0)
    H.eq(Opp.dutySince(D), H.time, 'back on duty: dutySince is now')
    H.ok(Opp.dutySince(A) < H.time, 'officer A: on duty since the start')

    -- off duty, then out of the department job: leaving the job counts too
    players[4].PlayerData.job.onduty = false
    TriggerEvent('QBCore:Server:SetDuty', 4, false)
    H.step(0)
    H.time = H.time + 60
    players[4].PlayerData.job = { name = 'unemployed', label = 'Civilian', onduty = false, grade = { level = 0 } }
    TriggerEvent('QBCore:Server:OnJobUpdate', 4, players[4].PlayerData.job)
    H.step(0)
    H.eq(Opp.lastPoliceAt(D), H.time, 'leaving the department job (off duty): lastPoliceAt now')

    -- with both features off a duty change is kept in memory only
    Config.LiveCrime.enabled = false
    H.time = H.time + 60
    players[1].PlayerData.job.onduty = false
    TriggerEvent('QBCore:Server:SetDuty', 1, false)
    H.step(0)
    H.advance(1000)
    H.eq(Opp.lastPoliceAt(A), H.time, 'features off: the memory map still follows duty')
    H.eq(#H.sql('SELECT id FROM cp_pvp_pairs WHERE kind = \'duty_off\' AND officer_citizenid = ?', { A }), 0,
        'but no ledger row is written')
    H.ok(bootAt <= H.time, 'the clock only moved forward')
end

H.sql('DROP TABLE IF EXISTS players')
H.sql('DROP TABLE IF EXISTS users')
return H
