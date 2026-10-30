-- CP.Qbx's player info cache (Config.Limits.playerInfoCacheMs) and the online list kept by qbx_core's events: how many
-- times Qbox's exports are called, and that every change event makes the next answer fresh. Also the downed poll's
-- CP.Qbx.isDowned, which reads two metadata keys (GetMetadata) instead of a copy of the whole Player.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })

-- ============================================================================
--                                qbx_core MOCK
-- ============================================================================
-- Like FXServer, every export answer and every TriggerEvent argument is a copy (msgpack), never qbx_core's own table.

local function Copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = Copy(x) end
    return out
end

local players = {}
local function AddPlayer(src, cid, job, onduty)
    players[src] = {
        PlayerData = {
            source = src,
            citizenid = cid,
            charinfo = { firstname = 'First' .. src, lastname = 'Last' },
            job = { name = job, label = job:upper(), onduty = onduty, grade = { name = 'Grade', level = 1 } },
            metadata = { callsign = 'C-' .. src, isdead = false, inlaststand = false },
        },
    }
    H.players[src] = H.players[src] or { coords = vec3(src * 10.0, 0.0, 0.0) }
end
for src = 1, 6 do AddPlayer(src, ('CQC%05d'):format(src), src % 2 == 0 and 'police' or 'mechanic', true) end
AddPlayer(7, 'CQC00007', 'police', false)   -- in character selection: Qbox has no Player for it yet
local loaded7 = players[7]
players[7] = nil

local calls = { GetPlayer = 0, GetQBPlayers = 0, GetMetadata = 0 }
local metadataIds = {}   -- type of the identifier -> GetMetadata calls with it
H.exportsMock.qbx_core = {
    -- qbx_core server/player.lua GetMetadata: a number is an online source; a string is a citizenid, which qbx_core
    -- looks up in its players table when that character is offline (GetOfflinePlayer)
    GetMetadata = function(id, key)
        calls.GetMetadata = calls.GetMetadata + 1
        metadataIds[type(id)] = (metadataIds[type(id)] or 0) + 1
        if type(key) ~= 'string' then return nil end
        local p = type(id) == 'number' and players[id] or nil
        return p and Copy(p.PlayerData.metadata[key])
    end,
    GetPlayer = function(src)
        calls.GetPlayer = calls.GetPlayer + 1
        return Copy(players[tonumber(src)])
    end,
    GetQBPlayers = function()
        calls.GetQBPlayers = calls.GetQBPlayers + 1
        return Copy(players)
    end,
    GetPlayerByCitizenId = function() return nil end,
    GetJobs = function() return {} end,
}

-- What qbx_core sends after it changed a player's data (UpdatePlayerData).
local function SetPlayerData(src) TriggerEvent('QBCore:Player:SetPlayerData', Copy(players[src].PlayerData)) end

local function Joined(list) return table.concat(list, ',') end

H.load('modules/integrations/qbx/server.lua')
local Q = CP.Qbx

-- ============================================================================
--                     START: ONE COPY OF THE PLAYERS LIST
-- ============================================================================

do
    H.eq(Config.Limits.playerInfoCacheMs, 1000, 'shipped: one second')
    H.eq(calls.GetQBPlayers, 1, 'the list is read once at start')
    H.eq(Joined(Q.getOnlinePlayers()), '1,2,3,4,5,6', 'every loaded character, in order')
    H.eq(calls.GetQBPlayers, 1, 'a call after start reads nothing again')
end

-- ============================================================================
--                   (a) MANY READS IN ONE SECOND, ONE EXPORT
-- ============================================================================

do
    calls.GetPlayer = 0
    local last
    for _ = 1, 10 do last = Q.getInfo(5) end
    H.eq(calls.GetPlayer, 1, '10 reads of one player within a second: 1 GetPlayer (it was 10)')
    H.eq(last.citizenid, 'CQC00005', 'the cached answer is the player')
    H.eq(last.job.name, 'mechanic', 'with the job')
    H.eq(last.callsign, 'C-5', 'and the callsign')
    H.eq(Q.getInfo('5').citizenid, 'CQC00005', 'a string src is the same player')
    H.eq(calls.GetPlayer, 1, 'and the same entry')

    -- a loop over every player (IdleUnits, Units.view, OnDutyCounts...) twice in one second
    calls.GetPlayer = 0
    for _ = 1, 2 do
        for _, src in ipairs(Q.getOnlinePlayers()) do Q.getInfo(src) end
    end
    H.eq(calls.GetPlayer, 5, 'two loops over 6 players: one GetPlayer each for the 5 not read yet')

    -- nobody: never cached, Qbox is asked each time (as before)
    calls.GetPlayer = 0
    H.eq(Q.getInfo(42), nil, 'unknown player')
    H.eq(Q.getInfo(42), nil, 'still unknown')
    H.eq(calls.GetPlayer, 2, 'a nil answer is not cached')
    H.eq(Q.getInfo('x'), nil, 'a bad src')
    H.eq(Q.getInfo(-1), nil, 'a negative src')
    H.eq(calls.GetPlayer, 2, 'a bad src never reaches Qbox')
end

-- ============================================================================
--                     (f) A CALLER'S CHANGES STAY ITS OWN
-- ============================================================================

do
    local a = Q.getInfo(5)
    a.name = 'changed'
    a.job.name = 'changed'
    a.job.onduty = false
    a.extra = true
    local b = Q.getInfo(5)
    H.eq(b.name, 'First5 Last', 'a changed name does not reach the next answer')
    H.eq(b.job.name, 'mechanic', 'nor a changed job name')
    H.eq(b.job.onduty, true, 'nor a changed duty')
    H.eq(b.extra, nil, 'nor an added field')
    H.ok(a ~= b and a.job ~= b.job, 'each answer is its own table')
end

-- ============================================================================
--                 (b) (d) EVERY CHANGE EVENT CLEARS THE ENTRY
-- ============================================================================

do
    -- OnJobUpdate: qbx_core's SetJob has changed PlayerData first; the handler re-reads it once
    Q.getInfo(5)
    calls.GetPlayer = 0
    players[5].PlayerData.job = {
        name = 'police',
        label = 'POLICE',
        onduty = true,
        grade = { name = 'Officer', level = 2 },
    }
    TriggerEvent('QBCore:Server:OnJobUpdate', 5, Copy(players[5].PlayerData.job))
    local info = Q.getInfo(5)
    H.eq(info.job.name, 'police', 'OnJobUpdate: the new job at once')
    H.eq(info.job.gradeLevel, 2, 'and its grade')
    H.eq(calls.GetPlayer, 1, 'OnJobUpdate: one fresh read (the handler\'s), reused after it')
    H.eq(Q.knownJob(5), 'police', 'the job map follows')

    -- SetPlayerData (qbx_core's UpdatePlayerData: a name, a job set with SetPlayerData('job', ...), ...)
    players[5].PlayerData.charinfo.firstname = 'Renamed'
    SetPlayerData(5)
    calls.GetPlayer = 0
    H.eq(Q.getInfo(5).firstname, 'Renamed', 'SetPlayerData: the next read is fresh')
    H.eq(calls.GetPlayer, 1, 'SetPlayerData: one fresh read')
    -- a payload with no job still clears the player (only its job feeds the job map)
    players[5].PlayerData.charinfo.firstname = 'Again'
    TriggerEvent('QBCore:Player:SetPlayerData', { source = 5 })
    H.eq(Q.getInfo(5).firstname, 'Again', 'SetPlayerData without a job: still fresh')
    H.eq(Q.knownJob(5), 'police', 'and the job map keeps the job')

    -- onSetMetaData: the callsign, with no metadata listener registered (the early return comes after the clear)
    players[5].PlayerData.metadata.callsign = 'NEW-5'
    TriggerEvent('qbx_core:server:onSetMetaData', 'callsign', 'C-5', 'NEW-5', 5)
    calls.GetPlayer = 0
    H.eq(Q.getInfo(5).callsign, 'NEW-5', 'onSetMetaData: the new callsign at once')
    H.eq(calls.GetPlayer, 1, 'onSetMetaData: one fresh read')
    players[5].PlayerData.metadata.isdead = true
    TriggerEvent('qbx_core:server:onSetMetaData', 'isdead', false, true, 5)
    H.eq(Q.getInfo(5).isDead, true, 'onSetMetaData: down at once')

    -- SetDuty off: the next read is fresh; SetDuty on: the handler re-reads it, the next read reuses that
    players[5].PlayerData.job.onduty = false
    TriggerEvent('QBCore:Server:SetDuty', 5, false)
    calls.GetPlayer = 0
    H.eq(Q.getInfo(5).job.onduty, false, 'SetDuty off: off duty at once')
    H.eq(calls.GetPlayer, 1, 'SetDuty off: one fresh read')
    players[5].PlayerData.job.onduty = true
    calls.GetPlayer = 0
    TriggerEvent('QBCore:Server:SetDuty', 5, true)
    H.eq(Q.getInfo(5).job.onduty, true, 'SetDuty on: on duty at once')
    H.eq(calls.GetPlayer, 1, 'SetDuty on: the handler\'s fresh read, reused after it')

    -- onGroupUpdate: removing the active job makes it 'unemployed' with no OnJobUpdate
    players[5].PlayerData.job = { name = 'unemployed', label = 'Civilian', onduty = false, grade = { level = 0 } }
    TriggerEvent('qbx_core:server:onGroupUpdate', 5, 'police', nil)
    H.eq(Q.getInfo(5).job.name, 'unemployed', 'onGroupUpdate: the job is read again')

    -- OnPlayerUnload, then PlayerLoaded with another character on the same src
    Q.getInfo(3)
    TriggerEvent('QBCore:Server:OnPlayerUnload', 3)
    players[3] = nil
    H.eq(Q.getInfo(3), nil, 'OnPlayerUnload: no stale info')
    AddPlayer(3, 'CQC00033', 'police', true)
    TriggerEvent('QBCore:Server:PlayerLoaded', Copy(players[3]))
    H.eq(Q.getInfo(3).citizenid, 'CQC00033', 'PlayerLoaded: the new character at once')
    -- a character switch inside the second: PlayerLoaded alone also clears the entry
    players[3].PlayerData.citizenid = 'CQC00034'
    TriggerEvent('QBCore:Server:PlayerLoaded', Copy(players[3]))
    H.eq(Q.getInfo(3).citizenid, 'CQC00034', 'PlayerLoaded clears the entry')

    -- playerDropped
    Q.getInfo(2)
    players[2] = nil
    H.fire('playerDropped', 2)
    H.eq(Q.getInfo(2), nil, 'playerDropped: no stale info')
    AddPlayer(2, 'CQC00002', 'police', true)
    TriggerEvent('QBCore:Server:PlayerLoaded', Copy(players[2]))

    -- qbx_core stops: nothing is answered from the cache
    Q.getInfo(1)
    TriggerEvent('onResourceStop', 'qbx_core')
    calls.GetPlayer = 0
    local realState = GetResourceState
    _G.GetResourceState = function(name) if name == 'qbx_core' then return 'stopped' end return realState(name) end
    H.eq(Q.getInfo(1), nil, 'qbx_core stopped: no info')
    _G.GetResourceState = realState
    TriggerEvent('onResourceStart', 'qbx_core')
    H.eq(Q.getInfo(1).citizenid, 'CQC00001', 'qbx_core started again: read again')
    H.eq(calls.GetPlayer, 1, 'one fresh read')
end

-- ============================================================================
--                            (c) THE ENTRY RUNS OUT
-- ============================================================================

do
    Q.getInfo(6)
    calls.GetPlayer = 0
    H.advance(900)
    Q.getInfo(6)
    H.eq(calls.GetPlayer, 0, '900 ms later: still the cached answer')
    H.advance(200)
    players[6].PlayerData.metadata.callsign = 'QUIET-6'   -- a change no event reports: seen once the entry runs out
    H.eq(Q.getInfo(6).callsign, 'QUIET-6', 'past 1000 ms: read again')
    H.eq(calls.GetPlayer, 1, 'one fresh read')

    Config.Limits.playerInfoCacheMs = 5000
    calls.GetPlayer = 0
    H.advance(1500)
    Q.getInfo(6)
    H.eq(calls.GetPlayer, 0, 'a longer setting keeps the answer longer')
    Config.Limits.playerInfoCacheMs = 1000
end

-- ============================================================================
--                    (e) THE ONLINE LIST IS KEPT BY EVENTS
-- ============================================================================

do
    H.advance(61000)   -- start from a fresh read
    Q.getOnlinePlayers()
    calls.GetQBPlayers = 0

    players[7] = loaded7
    TriggerEvent('QBCore:Server:PlayerLoaded', Copy(players[7]))
    H.eq(Joined(Q.getOnlinePlayers()), '1,2,3,4,5,6,7', 'PlayerLoaded adds the player')
    TriggerEvent('QBCore:Server:OnPlayerUnload', 3)
    players[3] = nil
    H.eq(Joined(Q.getOnlinePlayers()), '1,2,4,5,6,7', 'OnPlayerUnload removes the player')
    H.fire('playerDropped', 4)
    players[4] = nil
    H.eq(Joined(Q.getOnlinePlayers()), '1,2,5,6,7', 'playerDropped removes the player')
    H.eq(calls.GetQBPlayers, 0, 'load, unload and drop: no GetQBPlayers copy')

    local list = Q.getOnlinePlayers()
    list[1] = 999
    list[#list + 1] = 1000
    H.eq(Joined(Q.getOnlinePlayers()), '1,2,5,6,7', 'a caller\'s change to the list stays its own')

    -- a player Qbox has that no event reported shows after the 60 s full read
    AddPlayer(9, 'CQC00009', 'police', true)
    H.advance(30000)
    H.eq(Joined(Q.getOnlinePlayers()), '1,2,5,6,7', '30 s later: the event-kept list')
    H.eq(calls.GetQBPlayers, 0, 'still no copy')
    H.advance(31000)
    H.eq(Joined(Q.getOnlinePlayers()), '1,2,5,6,7,9', 'over 60 s later: Qbox\'s whole list is read again')
    H.eq(calls.GetQBPlayers, 1, 'one copy')
    H.eq(Q.knownJob(9), 'police', 'and that read seeds the job map')

    -- qbx_core starts: the whole list is read again at once
    TriggerEvent('onResourceStart', 'qbx_core')
    H.eq(calls.GetQBPlayers, 2, 'qbx_core start: one copy')

    -- a failed copy answers nobody and tries again on the next call
    local realList = H.exportsMock.qbx_core.GetQBPlayers
    H.exportsMock.qbx_core.GetQBPlayers = function() error('qbx_core busy') end
    TriggerEvent('onResourceStop', 'qbx_core')
    H.eq(#Q.getOnlinePlayers(), 0, 'a failed copy: nobody')
    H.exportsMock.qbx_core.GetQBPlayers = realList
    H.eq(Joined(Q.getOnlinePlayers()), '1,2,5,6,7,9', 'the next call reads it again')
end

-- ============================================================================
--                   (g) playerInfoCacheMs = 0: OLD BEHAVIOUR
-- ============================================================================

do
    Config.Limits.playerInfoCacheMs = 0
    calls.GetPlayer = 0
    for _ = 1, 10 do Q.getInfo(5) end
    H.eq(calls.GetPlayer, 10, 'off: every read asks Qbox')

    -- the list: read every second and again after each load, unload or drop (as before)
    H.advance(1000)
    Q.getOnlinePlayers()
    calls.GetQBPlayers = 0
    Q.getOnlinePlayers()
    H.eq(calls.GetQBPlayers, 0, 'off: the list is kept for one second')
    H.advance(1000)
    Q.getOnlinePlayers()
    H.eq(calls.GetQBPlayers, 1, 'off: after one second it is read again')
    AddPlayer(3, 'CQC00003', 'police', true)
    TriggerEvent('QBCore:Server:PlayerLoaded', Copy(players[3]))
    H.eq(Joined(Q.getOnlinePlayers()), '1,2,3,5,6,7,9', 'off: a load is seen')
    H.eq(calls.GetQBPlayers, 2, 'off: a load makes the next call read the whole list')

    Config.Limits.playerInfoCacheMs = nil
    calls.GetPlayer = 0
    for _ = 1, 3 do Q.getInfo(5) end
    H.eq(calls.GetPlayer, 1, 'no setting: one second')
    Config.Limits.playerInfoCacheMs = 1000
end

-- ============================================================================
--           (h) THE DOWNED POLL: TWO METADATA READS, NO PLAYER COPY
-- ============================================================================
-- modules/downed/server.lua asks CP.Qbx.isDowned about every active participant every Config.Downed.checkEvery s.

do
    local run = { id = 'r-downed', state = 'active', participants = {} }
    for src = 101, 140 do
        AddPlayer(src, ('CQC%05d'):format(src), 'police', true)
        run.participants[src] = { status = 'active', citizenid = players[src].PlayerData.citizenid }
    end
    local removed = {}
    CP.Runs = {
        all = function() return { run } end,
        getBySrc = function(src) return run.participants[src] and run or nil end,
        removeParticipant = function(r, src, reason)
            local p = r.participants[src]
            p.status, p.endReason = 'left', reason
            removed[#removed + 1] = { src = src, reason = reason }
        end,
    }
    H.load('modules/downed/server.lua')
    H.step(0)   -- its thread registers its listeners, then waits for the first poll
    local every = Config.Downed.checkEvery * 1000
    H.eq(every, 2000, 'shipped: a poll every 2 s')

    -- (a) nobody down: 10 polls over 40 participants copy no Player (it was 400 GetPlayer)
    calls.GetPlayer, calls.GetMetadata = 0, 0
    for _ = 1, 10 do H.step(every) end
    H.eq(calls.GetPlayer, 0, '10 polls x 40 participants: 0 GetPlayer (it was 400)')
    H.eq(calls.GetMetadata, 800, 'each poll reads isdead and inlaststand of each participant')
    H.eq(#removed, 0, 'nobody is down')

    -- (b) last stand, then dead: the next poll removes them as downed, as before
    players[105].PlayerData.metadata.inlaststand = true
    H.step(every - 1)
    H.eq(#removed, 0, 'last stand: nothing before the poll')
    H.step(1)
    H.eq(removed[1] and removed[1].src, 105, 'last stand: removed by the next poll')
    H.eq(removed[1] and removed[1].reason, 'downed', 'last stand: as downed')
    players[106].PlayerData.metadata.isdead = true
    H.step(every)
    H.eq(removed[2] and removed[2].src, 106, 'dead: removed by the next poll')
    H.eq(removed[2] and removed[2].reason, 'downed', 'dead: as downed')
    H.eq(#removed, 2, 'only the downed participants')

    -- (c) a Qbox without GetMetadata: the first call raises, then the whole Player is read, with the same answers
    local getMetadata = H.exportsMock.qbx_core.GetMetadata
    H.exportsMock.qbx_core.GetMetadata = nil
    calls.GetPlayer = 0
    H.eq(Q.isDowned(101), false, 'no export: not downed')
    H.eq(calls.GetPlayer, 1, 'no export: read from the Player')
    H.eq(Q.isDowned(105), true, 'no export: last stand is downed')
    H.eq(Q.isDowned(106), true, 'no export: dead is downed')
    players[107].PlayerData.metadata.isdead = 1
    H.eq(Q.isDowned(107), false, 'no export: only a real true counts')
    players[107].PlayerData.metadata.isdead = false
    players[108].PlayerData.metadata.inlaststand = true
    H.step(every)
    H.eq(removed[3] and removed[3].src, 108, 'no export: the next poll removes them')
    H.eq(removed[3] and removed[3].reason, 'downed', 'no export: as downed')
    H.exportsMock.qbx_core.GetMetadata = getMetadata
    calls.GetPlayer, calls.GetMetadata = 0, 0
    H.eq(Q.isDowned(105), true, 'remembered: last stand')
    H.eq(calls.GetMetadata, 0, 'remembered: GetMetadata is not tried again')
    H.eq(calls.GetPlayer, 1, 'remembered: the Player is read')
    TriggerEvent('onResourceStart', 'qbx_core')
    calls.GetPlayer = 0
    H.eq(Q.isDowned(105), true, 'qbx_core started again: last stand')
    H.eq(calls.GetMetadata, 2, 'qbx_core started again: GetMetadata is used again')
    H.eq(calls.GetPlayer, 0, 'qbx_core started again: no Player copy')

    -- (d) only a number reaches GetMetadata: qbx_core would look a citizenid string up in its players table
    calls.GetMetadata = 0
    H.eq(Q.isDowned('CQC00105'), false, 'a citizenid is not a source')
    H.eq(calls.GetMetadata, 0, 'a citizenid never reaches GetMetadata')
    H.eq(Q.isDowned('105'), true, 'a numeric string is source 105')
    H.eq(metadataIds.string, nil, 'GetMetadata was only ever given a number')
    H.ok((metadataIds.number or 0) > 800, 'GetMetadata was given numbers')
end

return H
