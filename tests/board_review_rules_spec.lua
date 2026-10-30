-- Department leaderboard visibility and stricter review rules (step P14): the boards Mission control (names or

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
Config.Debug = false

local realPrint = print
_G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, ' ')
    if line:find('[crimson-police', 1, true) then return end
    realPrint(line)
end
_G.GetConvar = function(_, default) return default end
_G.PerformHttpRequest = function() end

Config.Departments = {
    sast = { label = 'San Andreas State Troopers', short = 'SAST', jobs = { 'sast' }, supervisorGrade = 3 },
    fib = { label = 'Federal Investigation Bureau', short = 'FIB', jobs = { 'fib' }, supervisorGrade = 3 },
}
Config.Leaderboard.metrics = { 'points', 'missions', 'arrests', 'judgement' }

-- ============================================================================
--                                    STUBS
-- ============================================================================

local defs, values = {}, {}
CP.DeptControls = {
    register = function(key, def)
        defs[key] = def
        return true
    end,
    get = function(dept, key)
        local v = values[dept] and values[dept][key]
        if v ~= nil then return v end
        return defs[key] and defs[key].configValue() or nil
    end,
}

local officers = {
    [2] = { citizenid = 'SUP00002', name = 'Sam Super', department = 'sast', callsign = 'S-2' },
    [3] = { citizenid = 'SUP00003', name = 'Sue Second', department = 'sast', callsign = 'S-3' },
    [4] = { citizenid = 'SUP00004', name = 'Fay Fib', department = 'fib', callsign = 'F-4' },
    [5] = { citizenid = 'OFF00005', name = 'Fred Fib', department = 'fib', callsign = 'F-5' },
    [6] = { citizenid = 'OFF00006', name = 'Olly Sast', department = 'sast', callsign = 'S-6' },
}
local admins = { [1] = true }
CP.Access = {
    getOfficer = function(src) return officers[tonumber(src)] end,
    isAdmin = function(src) return admins[tonumber(src)] == true end,
    licenseOf = function(cid) return 'license:' .. tostring(cid) end,
}
CP.Qbx = {
    getInfo = function(src)
        local o = officers[tonumber(src)]
        return o and { citizenid = o.citizenid } or (admins[tonumber(src)] and { citizenid = 'ADM00001' }) or nil
    end,
}
CP.Permissions = {
    can = function() return true end,
    canReviewRun = function() return true end,
}

H.load('modules/leaderboard/server.lua')
H.load('modules/reviewrules/server.lua')
H.load('modules/admin/server.lua')
local LB, RR, Admin = CP.Leaderboard, CP.ReviewRules, CP.Admin

-- ============================================================================
--                                SHIPPED CONFIG
-- ============================================================================

local MC = Config.MissionControls
H.ok(MC.controls.boards.on == false and MC.controls.reviewRules.on == false, 'both controls ship off')
H.ok(defs.boards and defs.boards.kind == 'map' and defs.boards.bounded == false, 'boards: an unbounded map control')
H.ok(defs.reviewRules and defs.reviewRules.kind == 'map', 'reviewRules: a map control')
H.eq(defs.boards.relaxes(), false, 'boards never relaxes: it applies to the supervisor who set it too')
H.eq(defs.reviewRules.relaxes(), false, 'reviewRules is stricter only')
H.ok(LB.hidesNamesFrom('sast', 'fib') == false, 'with the config value other departments see names')
H.eq(table.concat(LB.boardMetrics('sast'), ','), 'points,missions,arrests,judgement', 'and every Rank by tab')

-- ============================================================================
--                                    BOARDS
-- ============================================================================

H.eq(LB._cleanBoards({ showToOthers = false, metrics = { 'arrests' } }, true).metrics[1], 'points',
    'points always stays')
H.eq(LB._cleanBoards({ showToOthers = false, metrics = { 'calls' } }, true), nil,
    'a tab the config does not offer is refused')
H.eq(LB._cleanBoards({ showToOthers = 'no' }, true), nil, 'showToOthers is true or false')
H.eq(#LB._cleanBoards({ showToOthers = true, metrics = { 'calls', 'arrests' } }, false).metrics, 2,
    'a saved value keeps only the tabs still offered')

values.sast = { boards = { showToOthers = false, metrics = { 'points', 'arrests' } } }
local sastRow = {
    citizenid = 'OFF00006',
    name = 'Olly Sast',
    callsign = 'S-6',
    department = 'sast',
    hideName = false,
    avatarRow = { display_name = 'Olly Sast', callsign = 'S-6', hide_name = 0 },
}
local fibViewer = officers[5]
local shown = LB._shownTo(sastRow, fibViewer.department)
H.eq(LB.publicName(shown), 'S-6', 'an FIB viewer sees the SAST officer\'s callsign')
H.ok(LB.publicName(shown) ~= 'Olly Sast', 'not his name')
H.eq(shown.avatarRow.hide_name, 1, 'and no picture of him')
H.eq(sastRow.hideName, false, 'the cached board entry is not changed')
H.eq(LB.publicName(LB._shownTo(sastRow, 'sast')), 'Olly Sast', 'a SAST viewer still sees the name')
H.eq(LB.hidesNamesFrom('fib', 'sast'), false, 'FIB officers keep their names')
H.eq(table.concat(LB.boardMetrics('sast'), ','), 'points,arrests', 'SAST officers see Points and Arrests')
H.eq(table.concat(LB.boardMetrics('fib'), ','), 'points,missions,arrests,judgement', 'FIB keeps every tab')

local res = H.callback('crimson-police:getBoard', 6, { period = 'weekly', metric = 'missions' })
H.eq(res.error, 'err.invalid_metric', 'a SAST officer cannot open a tab his department hides')

-- ============================================================================
--                                 REVIEW RULES
-- ============================================================================

H.eq(RR._clean({ secondVoid = true, adminOnlyKinds = { 'nope' } }, true), nil, 'an unknown flag kind is refused')
H.eq(RR._clean({ secondVoid = true, extra = 1 }, true), nil, 'an unknown field is refused')

local rows = {
    [10] = {
        id = 10,
        run_uuid = 'run-10',
        citizenid = 'OFF00006',
        department = 'sast',
        mission_type = 'traffic',
        mission_id = 'stop',
        flagged = true,
        voided = false,
        flag_reason = 'too_fast',
        state = 'completed',
    },
    [11] = {
        id = 11,
        run_uuid = 'run-11',
        citizenid = 'OFF00006',
        department = 'sast',
        mission_type = 'traffic',
        mission_id = 'stop',
        flagged = true,
        voided = false,
        flag_reason = 'rs_vdm',
        state = 'completed',
    },
}
Admin.getRow = function(id) return rows[id] end
local voided = {}
local audits = {}
Admin.audit = function(_, _, _, action, target) audits[#audits + 1] = action .. ' ' .. tostring(target) end
CP.Scoring = {
    onRowVoided = function(id) voided[#voided + 1] = id end,
}
_G.MySQL.update.await = function(sql, params)
    if sql:find('SET voided = 1', 1, true) then return 1 end
    return 0
end

values.sast.reviewRules = { secondVoid = true, adminOnlyKinds = { 'rs_vdm' } }
local ok, data = Admin.voidFlagged(2, 10, 'Teleported')
H.ok(ok == true and data.pending == true, 'one SAST sergeant\'s Void only marks the row pending')
H.eq(#voided, 0, 'nothing is voided yet')
H.eq(audits[#audits], 'voidPending #10 OFF00006', 'the pending Void is audited')
H.eq(RR.pendingOf(10).name, 'Sam Super', 'the queue shows who voided first')
ok, data = Admin.voidFlagged(2, 10, 'Again')
H.eq(data, 'err.void_second_needed', 'the same sergeant cannot confirm his own Void')
ok, data = Admin.voidFlagged(4, 10, 'FIB')
H.eq(data, 'err.void_second_dept', 'an FIB sergeant cannot confirm a SAST Void')
ok = Admin.voidFlagged(3, 10, 'Confirmed')
H.eq(ok, true, 'a second SAST sergeant confirms it')
H.eq(voided[1], 10, 'and the row is voided')
H.eq(RR.pendingOf(10), nil, 'nothing waits any more')

ok, data = Admin.voidFlagged(2, 11, 'VDM')
H.eq(data, 'err.review_admin_only', 'a supervisor cannot void a flag kind SAST hands to admins')
ok, data = Admin.approveFlagged(2, 11, 'VDM')
H.eq(data, 'err.review_admin_only', 'nor approve it')
ok = Admin.voidFlagged(1, 11, 'Admin')
H.eq(ok, true, 'an admin voids it at once (never bound by the rules)')
H.eq(voided[2], 11, 'voided')

-- the supervisors' queue: the admin-only kind is not in it, the other flagged row is
rows[11].voided = false
_G.MySQL.query.await = function(sql)
    if sql:find('FROM cp_mission_runs r', 1, true) then
        return {
            { id = 12, run_uuid = 'run-12', citizenid = 'OFF00006', department = 'sast', flag_reason = 'too_fast' },
            { id = 13, run_uuid = 'run-13', citizenid = 'OFF00006', department = 'sast', flag_reason = 'rs_vdm' },
        }
    end
    return {}
end
local function Ids(list)
    local out = {}
    for _, r in ipairs(list) do out[#out + 1] = tostring(r.rowId) end
    return table.concat(out, ',')
end
H.eq(Ids(Admin.flaggedRows('sast', 'SUP00002')), '12', 'the admin-only kind is not in the SAST queue')
H.eq(Ids(Admin.flaggedRows('sast', 'SUP00002', true)), '12,13', 'an admin\'s queue keeps it')
H.eq(Ids(Admin.flaggedRows(nil, 'ADM00001')), '12,13', 'and so does Admin -> Leaderboards')

values.sast.reviewRules = nil
RR._reset()
ok, data = Admin.voidFlagged(2, 10, 'Off')
H.ok(ok == true and (data or {}).pending == nil, 'with the config value one supervisor\'s Void voids at once')

return H
