-- Results for other scripts: the server-only event crimson-police:server:liveCrimeEnded when a live case
-- ends (Config.RealPlayers.liveCrime.endEvent) and the read-only export GetAvailablePolice
-- (CP.LiveCrime.availablePolice, Config.RealPlayers.liveCrime.availablePolice). Plain Lua with stubs.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
Config.Debug = false
_G.GetConvar = function(_, default) return default end
_G.PerformHttpRequest = function() end

-- ============================================================================
--                                    STUBS
-- ============================================================================

local opp = { outcomes = {}, case = nil }
CP.Opponents = {
    close = function() return opp.outcomes, opp.case end,
    recordPairs = function(_, rows) return #rows end,
    checkPairFlags = function() return {} end,
    timeline = function() return true end,
}
local onMission = {}      -- [src] = true
CP.Runs = {
    get = function() return nil end,
    isOnMission = function(src) return onMission[src] == true end,
}
local jobs = {}           -- [src] = { name, onduty }
CP.Qbx = {
    getInfo = function(src)
        local j = jobs[src]
        if not j then return nil end
        return { citizenid = 'C' .. src, name = 'P' .. src, job = { name = j.name, onduty = j.onduty } }
    end,
    getOnlinePlayers = function()
        local out = {}
        for src in pairs(jobs) do out[#out + 1] = src end
        table.sort(out)
        return out
    end,
}
CP.Access = {
    departmentForJob = function(job)
        if job == 'police' then return 'lspd' end
        if job == 'sheriff' then return 'bcso' end
        return nil
    end,
}

H.load('modules/realplayers/livecrime.lua')
local LC = CP.LiveCrime

local EVENT = CP.e('server:liveCrimeEnded')
local function Sent()
    local out = {}
    for _, e in ipairs(H.events) do
        if e.kind == 'local' and e.name == EVENT then out[#out + 1] = e.args[1] end
    end
    return out
end

local CRIME = {
    crimeKey = 'crimson-contracts:7_1',
    res = 'crimson-contracts',
    uid = '7_1',
    id = 7,
    key = 'drug_lab_raid',
    suspects = { A = true, B = true },
}
local realGet = LC.get
LC.get = function(key) if key == CRIME.crimeKey then return CRIME end return realGet(key) end

local function Run(id)
    return {
        id = id,
        state = 'ended',
        live = { crimeKey = CRIME.crimeKey, title = 'Shots', street = 'Seaview Rd', suspects = 2 },
        participants = {
            [1] = { src = 1, citizenid = 'OF1', arrived = true },
            [2] = { src = 2, citizenid = 'OF2', arrived = true },
        },
    }
end

-- ============================================================================
--                              THE SHIPPED CONFIG
-- ============================================================================

do
    H.eq(Config.RealPlayers.liveCrime.enabled, false, 'live crimes ship off: no case, so no end event')
    H.eq(Config.RealPlayers.liveCrime.endEvent, true, 'endEvent ships true (behind enabled)')
    H.eq(Config.RealPlayers.liveCrime.availablePolice, 'idle', 'availablePolice ships idle')
    H.eq(LC.availablePolice(), nil, 'the export answers nil while live crimes are off')
end

-- ============================================================================
--                          THE END EVENT (run:ended)
-- ============================================================================

do
    H.events = {}
    opp.case = { order = { 'A', 'B' }, suspects = { A = { share = 1 }, B = { share = 1 } } }
    opp.outcomes = { A = 'booked', B = 'nonsense' }
    local run = Run('V19-1')
    CP.Hooks.fire('run:ended', run, 'completed', 'completed')
    local sent = Sent()
    H.eq(#sent, 1, 'a live case that ends sends liveCrimeEnded once')
    local p = sent[1] or {}
    H.eq(p.resource, 'crimson-contracts', '...naming the reporting script')
    H.eq(p.uid, '7_1', '...its uid')
    H.eq(p.id, 7, '...its contract id')
    H.eq(p.key, 'drug_lab_raid', '...and contract key')
    H.eq(p.result, 'completed', '...how the run ended')
    H.eq(p.reason, 'completed', '...and why')
    H.eq(p.suspects and p.suspects.A, 'booked', 'each suspect\'s outcome by citizenid')
    H.eq(p.suspects and p.suspects.B, 'got_away', 'an unknown outcome reads got_away')
    H.eq(p.caught, 1, 'caught counts detained and booked suspects')
    H.eq(p.officers, 2, 'officers counts the case\'s officers')
    H.eq(p.coords, nil, 'no position in the payload')

    CP.Hooks.fire('run:ended', run, 'completed', 'completed')
    H.eq(#Sent(), 1, 'never twice for one run')

    -- the crime record was pruned: the names come from run.live
    H.events = {}
    local run2 = Run('V19-2')
    run2.live.crimeKey = 'my-heists:99_5'
    CP.Hooks.fire('run:ended', run2, 'failed', 'timeout')
    local p2 = Sent()[1] or {}
    H.eq(p2.resource, 'my-heists', 'a pruned crime: the resource from the crime key')
    H.eq(p2.uid, '99_5', '...and its uid')

    -- endEvent = false: nothing
    H.events = {}
    Config.RealPlayers.liveCrime.endEvent = false
    CP.Hooks.fire('run:ended', Run('V19-3'), 'completed', 'completed')
    H.eq(#Sent(), 0, 'endEvent = false: no event')
    Config.RealPlayers.liveCrime.endEvent = true

    -- an NPC mission: nothing
    H.events = {}
    CP.Hooks.fire('run:ended', { id = 'NPC', participants = {} }, 'completed', 'completed')
    H.eq(#Sent(), 0, 'an NPC mission sends no event')
end

-- ============================================================================
--                        THE EXPORT GetAvailablePolice
-- ============================================================================

do
    jobs = {
        [1] = { name = 'police', onduty = true },
        [2] = { name = 'police', onduty = true },
        [3] = { name = 'sheriff', onduty = true },
        [4] = { name = 'police', onduty = false },
        [5] = { name = 'mechanic', onduty = true },
    }
    onMission = { [2] = true }
    Config.RealPlayers.liveCrime.enabled = true
    local total, byDept = LC.availablePolice()
    H.eq(total, 2, 'idle: on-duty officers on no mission')
    H.eq(byDept.lspd, 1, '...per department')
    H.eq(byDept.bcso, 1, '...per department (2)')
    Config.RealPlayers.liveCrime.availablePolice = 'duty'
    H.eq((LC.availablePolice()), 3, 'duty: every on-duty officer, on a mission or not')
    Config.RealPlayers.liveCrime.availablePolice = 'idle'
    Config.RealPlayers.liveCrime.enabled = false
    local f = io.open('Crimson-Police/modules/realplayers/livecrime.lua', 'r')
    local src = f and f:read('a') or ''
    if f then f:close() end
    H.ok(src:find('exports(\'GetAvailablePolice\'', 1, true) ~= nil, 'the export is registered')
end

return H
