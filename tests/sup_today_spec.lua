-- Supervisor UI -> Department, today at a glance (UI4): the sup:getToday answer and its permission.

-- Supervisor UI -> Department, today at a glance (UI4): sup:getToday answers the department's officers on duty, its
-- runs going (as Live Missions lists them: every run not ended with an officer of the department on it) and the
-- viewer's Mission controls used today (each control with a day count, use capped at it); an admin with no department
-- sees every department; refused without viewMissionList. Plain Lua: modules/suptoday with stand-ins.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })

-- 1 = an LSPD supervisor, 2 = an admin with no department, 3 = an officer (no viewMissionList)
local officers = {
    [1] = { citizenid = 'SUP00001', department = 'lspd' },
    [3] = { citizenid = 'OFF00003', department = 'lspd' },
}
CP.Access = {
    getOfficer = function(src) return officers[src] end,
    isAdmin = function(src) return src == 2 end,
}
CP.Permissions = {
    can = function(src, key)
        if key ~= 'viewMissionList' then return false, 'err.no_permission' end
        if src == 3 then return false, 'err.no_permission' end
        return true
    end,
}
CP.Admin = {
    onDutyCounts = function() return { lspd = 4, bcso = 2 } end,
}
CP.Runs = {
    all = function()
        return {
            { state = 'in_progress', participants = { [7] = { department = 'lspd' } } },
            { state = 'accepted', participants = { [8] = { department = 'bcso' }, [9] = { department = 'lspd' } } },
            { state = 'ended', participants = { [10] = { department = 'lspd' } } },
            { state = 'in_progress', participants = { [11] = { department = 'bcso' } } },
        }
    end,
}
local mineAsked
CP.DeptControls = {
    mine = function(src)
        mineAsked = src
        return {
            controls = {
                { key = 'awardPoints', kind = 'action', perDay = 5, usedToday = 2 },
                { key = 'missionBan', kind = 'action', perDay = 2, usedToday = 9 },
                { key = 'payBoost', kind = 'value' },
            },
        }
    end,
}

H.load('modules/suptoday/server.lua')

local function Cb(src)
    H.clockMs = (H.clockMs or 0) + 6000
    local r = H.callback('crimson-police:sup:getToday', src, {})
    if type(r) ~= 'table' then return nil, 'no reply' end
    if r.ok then return r.data end
    return nil, r.error
end

do -- a supervisor: his own department only
    local d = Cb(1)
    H.ok(d ~= nil, 'a supervisor reads today at a glance')
    H.eq(d.onDuty, 4, 'officers on duty: his department\'s count')
    H.eq(d.running, 2, 'runs going: those with an officer of his department, an ended run left out')
    H.eq(mineAsked, 1, 'controls: his own (CP.DeptControls.mine)')
    H.eq(d.controls.counted, 2, 'controls with a day count')
    H.eq(d.controls.perDay, 7, 'their day counts summed')
    H.eq(d.controls.used, 4, 'today\'s uses summed, each capped at its day count')
end

do -- an admin with no department: every department, as Live Missions
    local d = Cb(2)
    H.eq(d.onDuty, 6, 'every department on duty')
    H.eq(d.running, 3, 'every run going')
end

do -- refused without viewMissionList
    local d, err = Cb(3)
    H.eq(d, nil, 'an officer gets nothing')
    H.eq(err, 'err.no_permission', 'with the reason')
end

do -- a failing module counts 0
    CP.Runs.all = function() error('boom') end
    CP.DeptControls.mine = function() return nil, 'err.no_permission' end
    local d = Cb(1)
    H.ok(d.running == 0 and d.controls.counted == 0 and d.onDuty == 4, 'the rest still answers')
end

return H
