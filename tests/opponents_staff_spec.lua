-- CP.Opponents staff: the server-only case data admins read (names fixed when a line is written, the

-- CP.Opponents staff: the server-only case data admins read (names fixed when a line is written, the
-- timeline as lines, the flag lines, the ledger), Config.RealSuspects.casesKept, the admin callbacks and the three
-- tools (block a pair, exclude a player, suspend an officer), and the self rule over suspects (P.tookPart). Plain
-- Lua with stubs: qbx_core's exports, CP.AdminKit and the pair writers are mocked; nothing reads the database.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
_G.GetConvar = function(_, default) return default end
_G.PerformHttpRequest = function() end

local function Copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = Copy(x) end
    return setmetatable(out, getmetatable(v))
end

local players = {}
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
local function Load(src, cid, first)
    H.players[src] = H.players[src] or { ace = {}, coords = vec3(src * 100.0, 0.0, 30.0) }
    players[src] = {
        PlayerData = {
            source = src,
            citizenid = cid,
            license = 'license:' .. cid:lower(),
            charinfo = { firstname = first, lastname = 'Test' },
            job = { name = 'unemployed', label = 'Civilian', onduty = false, grade = { level = 0 } },
            metadata = { ishandcuffed = false, isdead = false, inlaststand = false, injail = 0 },
        },
    }
    TriggerEvent('QBCore:Server:PlayerLoaded', Copy(players[src]))
end

-- CP.AdminKit: the registrations are kept and called directly; the self rule and the audit are recorded.
local cbs, acts, audits, writes = {}, {}, {}, {}
local selfRuns, selfCids = {}, {}
CP.AdminKit = {
    callback = function(name, key, fn, opts) cbs[name] = { key = key, fn = fn, opts = opts } end,
    action = function(name, key, fn, opts) acts[name] = { key = key, fn = fn, opts = opts } end,
    selfRun = function(_, runId) return selfRuns[runId] == true end,
    isSelf = function(_, cid) return selfCids[cid] == true end,
}
CP.Runs = {
    dispatch = function() return true end,
}
CP.AntiCheat = {
    note = function() return true end,
    flag = function() return true end,
}
H.load('modules/integrations/qbx/server.lua')
H.load('modules/opponents/server.lua')
H.load('modules/opponents/staff/server.lua')
H.step(0)
local Opp = CP.Opponents
local RS = Config.RealSuspects
for _, kind in ipairs({ 'block', 'exclude', 'suspend' }) do
    Opp[kind] = function(...)
        writes[#writes + 1] = { kind, ... }
        return true, os.time() + 86400
    end
end

local function NewRun(id, officers)
    local run = { id = id, missionId = 'live_crime', seed = 7, state = 'in_progress', participants = {}, order = {} }
    for _, o in ipairs(officers) do
        run.order[#run.order + 1] = o.src
        run.participants[o.src] = {
            src = o.src,
            citizenid = o.cid,
            name = o.name,
            callsign = o.callsign,
            status = 'active',
        }
    end
    return run
end

Load(1, 'OFF00001', 'Ada')
Load(2, 'CRIM0001', 'Bo')
Load(5, 'OUT00001', 'Cy')

-- ============================================================================
--                  1. THE CASE DATA (names fixed at the line)
-- ============================================================================

local R1 = NewRun('run-0001', { { src = 1, cid = 'OFF00001', name = 'Ada Test', callsign = '1-A-1' } })
do
    H.eq(RS.casesKept, 16, 'casesKept ships 16 (the closed cases kept before V17)')
    local case = Opp.open(R1, { kind = 'live', members = { 'CRIM0001' } })
    H.ok(case ~= nil, 'a live case opened')
    local label = case.suspects.CRIM0001.label
    Opp.timeline(R1, { what = 'cuff_attempt', label = label, src = 2, by = 1 })
    Opp.timeline(R1, { what = 'cuffed_by_outsider', label = label, src = 2, by = 5 })
    Opp.timeline(R1, { what = 'rs_unarmed_shot', label = label, src = 2, by = 1, detail = 'shot once' })
    Opp.note(R1, 'rs_combat_log', 'left within 20 s', 'CRIM0001')
    case.ledger[#case.ledger + 1] = {
        t = os.time(),
        dir = 'officer',
        from = 1,
        to = 2,
        cid = 'CRIM0001',
        label = label,
        weapon = 453432689,
        n = 2,
        state = 'free',
        down = false,
        rules = { 'rs_unarmed_shot' },
    }
    -- server id 5 is someone else after a drop: the line keeps who it was
    players[5] = nil
    Load(5, 'NEW00005', 'Di')

    local view = Opp.staffCase('run-0001')
    H.ok(view ~= nil and view.open == true and view.kind == 'live', 'staffCase: the open case')
    H.eq(view.suspects[1].citizenid, 'CRIM0001', 'staff see the suspect\'s citizenid')
    H.eq(view.suspects[1].name, 'Bo Test', 'and his name, read at the open')
    H.eq(view.officers[1].name, 'Ada Test', 'the officers by name')
    local byWhat = {}
    for _, l in ipairs(view.lines) do byWhat[l.what] = l end
    H.eq(byWhat.cuff_attempt.text, ('Ada Test (OFF00001) cuffed suspect %s'):format(label), 'a line reads as text')
    H.eq(byWhat.cuffed_by_outsider.by.citizenid, 'OUT00001',
        'a server id is named as it was when the line was written (not the player who has it now)')
    H.eq(byWhat.suspect.who.name, 'Bo Test', 'the open line names the suspect')
    H.eq(#view.flagLines, 2, 'flag lines: the officer flag and the suspect note')
    local flag, note = nil, nil
    for _, l in ipairs(view.flagLines) do
        if l.flag then flag = l end
        if l.note then note = l end
    end
    H.ok(
        flag and flag.kind == 'rs_unarmed_shot' and flag.text:find('never seen armed', 1, true)
            and flag.text:find('shot once', 1, true),
        'the flag line: its flag text and the detail'
    )
    H.ok(note and note.kind == 'rs_combat_log' and note.text:find('left within 20 s', 1, true), 'the note line')
    H.eq(view.ledger[1].officer.citizenid, 'OFF00001', 'the ledger names the officer')
    H.eq(view.ledger[1].n, 2, 'with the hits')
    H.eq(view.flags, 1, 'one officer flag counted')
    H.eq(view.notes, 1, 'one note counted')
    for _, s in ipairs(view.suspects) do H.eq(s.trail, nil, 'no position is answered') end

    local list = Opp.staffCases()
    H.ok(#list == 1 and list[1].runId == 'run-0001' and list[1].open == true, 'staffCases lists the open case')
    H.eq(Opp.wasSuspect('CRIM0001', 'run-0001'), true, 'wasSuspect: a suspect of the open case')
    H.eq(Opp.wasSuspect('OFF00001', 'run-0001'), false, 'not the officer')
end

-- ============================================================================
--                        2. CASES KEPT AFTER THE CLOSE
-- ============================================================================

do
    Opp.close(R1)
    local view = Opp.staffCase('run-0001')
    H.ok(view ~= nil and view.open == false and view.closedAt ~= nil, 'a closed case is still there for staff')
    H.eq(Opp.wasSuspect('CRIM0001', 'run-0001'), true, 'and its suspect still counts as one')
    RS.casesKept = 1
    local R2 = NewRun('run-0002', { { src = 1, cid = 'OFF00001', name = 'Ada Test' } })
    Opp.open(R2, { kind = 'live', members = { 'CRIM0001' } })
    Opp.close(R2)
    H.eq(Opp.staffCase('run-0001'), nil, 'casesKept = 1: the older closed case is gone')
    H.ok(Opp.staffCase('run-0002') ~= nil, 'the newest is kept')
    RS.casesKept = 16
end

-- ============================================================================
--                     3. THE ADMIN CALLBACKS AND THE TOOLS
-- ============================================================================

do
    for _, name in ipairs({ 'admin:getRsCases', 'admin:getRsCase', 'admin:getRsPairs' }) do
        H.eq(cbs[name] and cbs[name].key, 'antiFarmOverride', name .. ': an admin callback (antiFarmOverride)')
    end
    for _, name in ipairs({ 'server:admin:rsBlockPair', 'server:admin:rsExclude', 'server:admin:rsSuspend' }) do
        H.ok(acts[name] and acts[name].key == 'antiFarmOverride' and acts[name].opts.reason == true,
            name .. ': an admin action with a reason')
    end
    local ctx = { src = 9, args = { runUuid = 'run-0002' } }
    local view = cbs['admin:getRsCase'].fn(ctx)
    H.ok(type(view) == 'table' and view.runId == 'run-0002', 'getRsCase answers the case')
    selfRuns['run-0002'] = true
    local none, err = cbs['admin:getRsCase'].fn(ctx)
    H.ok(none == nil and err == 'err.own_run', 'a case of the admin\'s own character (officer or suspect) is refused')
    local list = cbs['admin:getRsCases'].fn({ src = 9, args = {} })
    H.ok(list.enabled == false and list.cases[1].own == true, 'the list marks his own case; the features ship off')
    selfRuns['run-0002'] = nil
    H.eq(select(2, cbs['admin:getRsCase'].fn({ src = 9, args = { runUuid = 'bad id!' } })), 'err.invalid_run',
        'a bad run id')

    local function Act(name, payload)
        return acts[name].fn({
            src = 9,
            payload = payload,
            actor = 'admin',
            audit = function(...) audits[#audits + 1] = { ... } end,
        })
    end
    local ok, e = Act('server:admin:rsExclude', { citizenid = 'CRIM0001', days = 7 })
    H.ok(ok == false and e == 'err.rs_off', 'the tools are refused while both features are off')
    H.eq(#writes, 0, 'and write nothing')
    Config.LiveCrime.enabled = true
    ok, e = Act('server:admin:rsBlockPair', { officer = 'OFF00001', suspect = 'CRIM0001', days = 0 })
    H.ok(ok == false and e == 'err.rs_invalid_days', '0 days is refused')
    H.ok(CP.L('err.rs_invalid_days'):find('above 0', 1, true) ~= nil, 'Z10: and the text no longer says 0 is allowed')
    selfCids.CRIM0001 = true
    ok, e = Act('server:admin:rsBlockPair', { officer = 'OFF00001', suspect = 'CRIM0001', days = 3 })
    H.ok(ok == false and e == 'err.self_target', 'a block naming one of the admin\'s own characters is refused')
    selfCids.CRIM0001 = nil
    ok = Act('server:admin:rsBlockPair', { officer = 'OFF00001', suspect = 'CRIM0001', days = 3 })
    H.ok(
        ok == true and writes[1][1] == 'block' and writes[1][2] == 'OFF00001' and writes[1][3] == 'CRIM0001'
            and writes[1][4] == 3,
        'a block writes the pair for 3 days'
    )
    H.eq(audits[1][1], 'rsBlockPair', 'and is audited')
    ok = Act('server:admin:rsSuspend', { citizenid = 'OFF00001', days = 1 })
    H.ok(ok == true and writes[2][1] == 'suspend', 'suspend an officer')
    ok = Act('server:admin:rsExclude', { citizenid = 'CRIM0001', days = 30 })
    H.ok(ok == true and writes[3][1] == 'exclude', 'exclude a player')
    local who = acts['server:admin:rsExclude'].opts.self({ citizenid = 'CRIM0001' })
    H.eq(who.citizenid, 'CRIM0001', 'exclude and suspend run AdminKit\'s self rule on the citizenid')
    Config.LiveCrime.enabled = false
end

-- ============================================================================
--                     3b. VOLUNTEER CASES FOR STAFF (V26)
-- ============================================================================

do
    local R3 = NewRun('run-0003', { { src = 1, cid = 'OFF00001', name = 'Ada Test' } })
    local case = Opp.open(R3, { kind = 'volunteer', members = { 'CRIM0001' } })
    H.ok(case ~= nil and case.kind == 'volunteer', 'a volunteer case opened')
    local asked = {}
    CP.Volunteers = {
        staffView = function(runId, c)
            asked[#asked + 1] = runId
            return { role = 'runner', mode = 'players_only', phase = 'travel', engaged = false, case = c }
        end,
        staffList = function() return { { citizenid = 'VOL00001', roles = { 'runner' }, strikes = 1 } } end,
    }
    local line = nil
    for _, l in ipairs(Opp.staffCases()) do
        if l.runId == 'run-0003' then line = l end
    end
    H.eq(line and line.volunteer and line.volunteer.role, 'runner', 'a volunteer case line carries the role played')
    H.eq(line and line.volunteer and line.volunteer.phase, 'travel', '...and the phase')
    local view = Opp.staffCase('run-0003')
    H.eq(view and view.volunteer and view.volunteer.mode, 'players_only', 'the case view carries the mode')
    H.eq(asked[1], 'run-0003', 'asked by run id')
    for _, l in ipairs(Opp.staffCases()) do
        if l.kind == 'live' then H.eq(l.volunteer, nil, 'a live case has no volunteer part') end
    end
    local list = cbs['admin:getRsCases'].fn({ src = 9, args = {} })
    H.eq(#list.listed, 0, 'volunteers off (as shipped): no list of volunteers')
    Config.Volunteers.enabled = true
    list = cbs['admin:getRsCases'].fn({ src = 9, args = {} })
    H.eq(list.listed[1] and list.listed[1].citizenid, 'VOL00001', 'volunteers on: staff see who is on the list')
    H.eq(list.listed[1] and list.listed[1].strikes, 1, '...with his strikes')
    Config.Volunteers.enabled = false
    CP.Volunteers.staffView = function() error('boom') end
    view = Opp.staffCase('run-0003')
    H.ok(view ~= nil and view.volunteer == nil, 'a failing volunteer view leaves the case readable')
    CP.Volunteers = nil
    Opp.close(R3)
end

-- ============================================================================
--                                    3c. F2
-- ============================================================================
-- LIFT EARLY, CLEAR STRIKES, NAMES AND WEAPON NAMES.

do
    local function Act(name, payload)
        return acts[name].fn({
            src = 9,
            payload = payload,
            actor = 'admin',
            audit = function(...) audits[#audits + 1] = { ... } end,
        })
    end
    -- lift: an admin action with a reason, audited, refused on an unknown row and on his own characters
    local lifted = {}
    Opp.lift = function(kind, officer, suspect)
        lifted[#lifted + 1] = { kind, officer, suspect }
        if suspect == 'GONE0001' then return false, 'no_row' end
        return true, os.time() + 86400
    end
    H.ok(
        acts['server:admin:rsLift'] and acts['server:admin:rsLift'].key == 'antiFarmOverride'
            and acts['server:admin:rsLift'].opts.reason == true,
        'rsLift: an admin action with a reason'
    )
    local ok, e = Act('server:admin:rsLift', { kind = 'exclude', suspect = 'CRIM0001' })
    H.ok(ok == false and e == 'err.rs_off', 'lift is refused while both features are off')
    Config.LiveCrime.enabled = true
    local nAudit = #audits
    ok = Act('server:admin:rsLift', { kind = 'block', officer = 'OFF00001', suspect = 'CRIM0001' })
    H.ok(ok == true and lifted[1][1] == 'block' and lifted[1][2] == 'OFF00001' and lifted[1][3] == 'CRIM0001',
        'a pair block is lifted')
    H.eq(audits[nAudit + 1] and audits[nAudit + 1][1], 'rsLift', 'and audited')
    ok = Act('server:admin:rsLift', { kind = 'suspend', officer = 'OFF00001', suspect = 'CRIM0001' })
    H.ok(ok == true and lifted[2][2] == 'OFF00001' and lifted[2][3] == nil, 'a suspension names only the officer')
    ok, e = Act('server:admin:rsLift', { kind = 'exclude', suspect = 'GONE0001' })
    H.ok(ok == false and e == 'err.rs_no_row', 'a row that is not running: err.rs_no_row')
    ok, e = Act('server:admin:rsLift', { kind = 'ban', suspect = 'CRIM0001' })
    H.ok(ok == false and e == 'err.rs_no_row', 'an unknown kind: err.rs_no_row')
    ok, e = Act('server:admin:rsLift', { kind = 'exclude', suspect = 'bad id!' })
    H.ok(ok == false and e == 'err.invalid_citizenid', 'a bad citizenid')
    selfCids.CRIM0001 = true
    ok, e = Act('server:admin:rsLift', { kind = 'exclude', suspect = 'CRIM0001' })
    H.ok(ok == false and e == 'err.self_target', 'never one of the admin\'s own characters')
    selfCids.CRIM0001 = nil
    H.eq(Config.RealSuspects.staffLift, true, 'staffLift ships true')
    Config.RealSuspects.staffLift = false
    ok, e = Act('server:admin:rsLift', { kind = 'exclude', suspect = 'CRIM0001' })
    H.ok(ok == false and e == 'err.rs_lift_off', 'staffLift = false: lifting is refused')
    H.eq(cbs['admin:getRsPairs'].fn({ src = 9, args = {} }).lift, false, 'and the screen offers no Lift')
    Config.RealSuspects.staffLift = true
    Config.LiveCrime.enabled = false

    -- clear strikes: volunteers on, a reason, audited, nothing to clear refused
    local cleared = {}
    CP.Volunteers = {
        clearStrikes = function(cid)
            cleared[#cleared + 1] = cid
            if cid == 'VOL00009' then return false, 'no_row' end
            return true, { strikes = 2 }
        end,
        staffList = function() return { { citizenid = 'OFF00001', roles = { 'runner' }, strikes = 2 } } end,
    }
    ok, e = Act('server:admin:rsClearStrikes', { citizenid = 'VOL00001' })
    H.ok(ok == false and e == 'err.rs_off' and #cleared == 0, 'clear strikes is refused while volunteers are off')
    Config.Volunteers.enabled = true
    H.eq(Config.Volunteers.staffClearStrikes, true, 'staffClearStrikes ships true')
    H.ok(acts['server:admin:rsClearStrikes'].opts.reason == true, 'rsClearStrikes needs a reason')
    nAudit = #audits
    ok = Act('server:admin:rsClearStrikes', { citizenid = 'VOL00001' })
    H.ok(ok == true and cleared[1] == 'VOL00001', 'a volunteer\'s strikes are cleared')
    H.eq(audits[nAudit + 1] and audits[nAudit + 1][1], 'rsClearStrikes', 'and audited')
    ok, e = Act('server:admin:rsClearStrikes', { citizenid = 'VOL00009' })
    H.ok(ok == false and e == 'err.rs_no_strikes', 'nothing to clear: err.rs_no_strikes')
    H.eq(acts['server:admin:rsClearStrikes'].opts.self({ citizenid = 'VOL00001' }).citizenid, 'VOL00001',
        'the self rule runs on the citizenid')
    local list = cbs['admin:getRsCases'].fn({ src = 9, args = {} })
    H.eq(list.clearStrikes, true, 'the Volunteers tab offers Clear strikes')
    H.eq(list.listed[1].name, 'Ada Test', 'a listed volunteer with no name gets his character name')
    Config.Volunteers.staffClearStrikes = false
    ok, e = Act('server:admin:rsClearStrikes', { citizenid = 'VOL00001' })
    H.ok(ok == false and e == 'err.rs_clear_off', 'staffClearStrikes = false: refused')
    Config.Volunteers.staffClearStrikes = true
    Config.Volunteers.enabled = false
    CP.Volunteers = nil

    -- names: one batched lookup per screen load (online from the cache, offline from Qbox's players table, then
    -- cp_officers), never a query per row
    H.sql('DROP TABLE IF EXISTS players')
    H.sql([[CREATE TABLE players (citizenid varchar(50) NOT NULL, license varchar(255) NOT NULL,
        charinfo longtext DEFAULT NULL, PRIMARY KEY (citizenid))]])
    H.sql([[INSERT INTO players (citizenid, license, charinfo) VALUES ('OFFL0001', 'license:l1', ?),
        ('OFFL0002', 'license:l2', ?)]],
        { '{"firstname":"Lee","lastname":"Long"}', '{"firstname":"Mo","lastname":"Moss"}' })
    H.sql('DELETE FROM cp_officers WHERE citizenid = \'OFFC0001\'')
    H.sql('INSERT INTO cp_officers (citizenid, department, display_name) VALUES (\'OFFC0001\', \'sast\', \'Cee Kay\')')
    Opp.pairStats = function()
        local out = {}
        for i = 1, 30 do
            out[i] = {
                officer = i % 2 == 0 and 'OFF00001' or 'OFFC0001',
                suspect = i % 3 == 0 and 'OFFL0001' or 'OFFL0002',
                cases = 1,
                scored = 0,
                lastAt = os.time(),
                kinds = { 'live' },
            }
        end
        return out, nil
    end
    Opp.adminRows = function() return { { kind = 'exclude', suspect = 'NONAME01', untilAt = os.time() + 60 } } end
    local counted = {}
    local function Wrap(db)
        if type(db) ~= 'table' or type(db.query) ~= 'table' then return nil end
        local real = db.query.await
        db.query.await = function(sql, ...)
            counted[#counted + 1] = sql
            return real(sql, ...)
        end
        return function() db.query.await = real end
    end
    local undoA = Wrap(MySQL)
    local undoB = CP.Storage and CP.Storage.realMySQL ~= MySQL and Wrap(CP.Storage.realMySQL) or nil
    local data = cbs['admin:getRsPairs'].fn({ src = 9, args = {} })
    if undoA then undoA() end
    if undoB then undoB() end
    local players, officers = 0, 0
    for _, sql in ipairs(counted) do
        if sql:find('FROM players', 1, true) then players = players + 1 end
        if sql:find('FROM cp_officers', 1, true) then officers = officers + 1 end
    end
    H.eq(data.names.OFF00001, 'Ada Test', 'an online character: his name from the cache')
    H.eq(data.names.OFFL0001, 'Lee Long', 'an offline character: his name from Qbox\'s players table')
    H.eq(data.names.OFFL0002, 'Mo Moss', 'every offline one')
    H.eq(data.names.OFFC0001, 'Cee Kay', 'else the officer name Crimson-Police keeps')
    H.eq(data.names.NONAME01, nil, 'a citizenid with no name stays a citizenid')
    H.eq(players, 1, '30 pair lines: one players-table statement')
    H.eq(officers, 1, 'and one cp_officers statement')
    H.eq(data.lift, true, 'the running rows can be lifted (staffLift ships true)')
    H.eq(Config.RealSuspects.staffNames, true, 'staffNames ships true')
    Config.RealSuspects.staffNames = false
    data = cbs['admin:getRsPairs'].fn({ src = 9, args = {} })
    H.eq(next(data.names), nil, 'staffNames = false: citizen IDs only')
    Config.RealSuspects.staffNames = true
    Opp.pairStats, Opp.adminRows = nil, nil
    H.sql('DROP TABLE IF EXISTS players')
    H.sql('DELETE FROM cp_officers WHERE citizenid = \'OFFC0001\'')

    -- weapon names: the common GTA weapons by their real hash (signed or unsigned), the hash for the rest
    local fake = _G.joaat
    _G.joaat = function(name)
        local h = 0
        name = tostring(name):lower()
        for i = 1, #name do
            h = (h + name:byte(i)) & 0xFFFFFFFF
            h = (h + (h << 10)) & 0xFFFFFFFF
            h = h ~ (h >> 6)
        end
        h = (h + (h << 3)) & 0xFFFFFFFF
        h = h ~ (h >> 11)
        return (h + (h << 15)) & 0xFFFFFFFF
    end
    H.load('shared/weapons.lua')
    _G.joaat = fake
    local W = CP.Weapons
    H.eq(W.label(453432689), 'Pistol', 'WEAPON_PISTOL by its hash')
    H.eq(W.label(1593441988), 'Combat Pistol', 'WEAPON_COMBATPISTOL')
    H.eq(W.label(-1569615261), 'Fists', 'a signed hash reads the same (WEAPON_UNARMED)')
    H.eq(W.label(12345), nil, 'an unknown hash has no name')
    H.eq(W.text(12345), '#12345', 'and reads as its hash')
    local R5 = NewRun('run-0005', { { src = 1, cid = 'OFF00001', name = 'Ada Test' } })
    local case = Opp.open(R5, { kind = 'live', members = { 'CRIM0001' } })
    case.ledger[#case.ledger + 1] = {
        t = os.time(),
        dir = 'officer',
        from = 1,
        to = 2,
        cid = 'CRIM0001',
        label = case.suspects.CRIM0001.label,
        weapon = 1593441988,
        n = 1,
    }
    case.ledger[#case.ledger + 1] = {
        t = os.time(),
        dir = 'officer',
        from = 1,
        to = 2,
        cid = 'CRIM0001',
        label = case.suspects.CRIM0001.label,
        weapon = 777,
        n = 1,
    }
    local view = Opp.staffCase('run-0005')
    H.eq(view.ledger[1].weaponName, 'Combat Pistol', 'the damage ledger names the weapon')
    H.ok(view.ledger[2].weaponName == nil and view.ledger[2].weapon == 777, 'an unknown weapon keeps its hash')
    H.eq(Config.RealSuspects.weaponNames, true, 'weaponNames ships true')
    Config.RealSuspects.weaponNames = false
    H.eq(Opp.staffCase('run-0005').ledger[1].weaponName, nil, 'weaponNames = false: the raw hash only')
    Config.RealSuspects.weaponNames = true
    Opp.close(R5)
end

-- ============================================================================
--                 4. THE SELF RULE OVER SUSPECTS (P.tookPart)
-- ============================================================================

do
    H.load('modules/permissions/server.lua')
    local P = CP.Permissions
    local answer = true
    Opp.suspectOfRun = function() return answer end
    H.eq(P.tookPart('CRIM0001', 'run-0002', true), true, 'asSuspect: a suspect of the run took part')
    answer = nil
    H.eq(P.tookPart('CRIM0001', 'run-0002', true), true, 'a lookup that cannot answer fails closed')
    Opp.suspectOfRun = function() error('boom') end
    H.eq(P.tookPart('CRIM0001', 'run-0002', true), true, 'and so does one that throws')
end

return H
