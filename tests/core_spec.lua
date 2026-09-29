-- tests/core_spec.lua · the core slice: integrations (qbx, sc-dispatch, sc-ambulance, Renewed-Banking),
-- access, permissions and the tablet (server and client). Every SQL statement of these modules runs here
-- against MariaDB cp_test (mdt_dispatch comes from tests/fixtures/core/mdt_dispatch.sql).
local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
Config.Debug = true   -- run every CP.log format string too

-- ── console capture: Crimson-Police lines are recorded, everything else printed ──
local logs = {}
local realPrint = print
_G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, ' ')
    if line:find('[crimson-police', 1, true) then logs[#logs + 1] = line return end
    realPrint(line)
end
local function countLogs(needle)
    local n = 0
    for _, l in ipairs(logs) do if l:find(needle, 1, true) then n = n + 1 end end
    return n
end

-- ── natives and exports the spec controls ──────────────────────────────────
local stopped = {}
_G.GetResourceState = function(name) return stopped[name] and 'stopped' or 'started' end
local exported = {}
getmetatable(exports).__call = function(_, name, fn) exported[name] = fn end
local netEvents = {}
do
    local realRegister = RegisterNetEvent
    _G.RegisterNetEvent = function(name, fn) netEvents[name] = true return realRegister(name, fn) end
end
local realGetPlayerName = GetPlayerName
_G.GetPlayerName = function(src) if tonumber(src) == 99 then return nil end return realGetPlayerName(src) end

local function lastEvent(name)
    local list = H.findEvents(name)
    return list[#list]
end

-- ── departments under test (valid, broken and duplicate entries) ────────────
Config.Departments = {
    sast = {
        label = 'San Andreas State Troopers', short = 'SAST', jobs = { 'sast' }, supervisorGrade = 3, societyAccount = 'sast',
        theme = { primary = '#1f4e8c', accent = '#f2c230', background = '#0d1522', surface = '#152235' },
        logo = { file = 'sast.png', watermark = true, opacity = 0.08, size = 0.6, grayscale = false },
    },
    fib = {
        label = 'Federal Investigation Bureau', short = 'FIB', jobs = { 'fib' }, supervisorGrade = 3, societyAccount = 'fib',
        theme = { primary = '#1c2541', accent = '#c9a227', background = '#0b0c10', surface = '#1a1b24' },
        logo = { file = 'fib.png', watermark = true, opacity = 0.08, size = 0.6, grayscale = false },
    },
    bcso = {
        label = "Blaine County Sheriff's Office", short = 'BCSO', jobs = 'bcso', supervisorGrade = 2,
        theme = { primary = 'red', accent = '#12345', background = '#F5F5F5', surface = '#ffffff', text = 'nope' },
        logo = { file = 'bcso.png', opacity = 0.5, size = -1, grayscale = true },
    },
    lspd = {
        label = 'Los Santos Police Department', short = 'LSPD', jobs = { 'police' },
        theme = { primary = '#123456', accent = '#654321', background = '#000000', surface = '#111111', text = '#EEEEEE' },
        logo = { url = 'https://example.com/lspd.png', opacity = -2, watermark = false },
    },
    zdup = {
        label = 'Duplicate', short = 'DUP', jobs = { 'sast', 'dupjob' }, supervisorGrade = 1,
        theme = { primary = '#123456', accent = '#654321', background = '#000000', surface = '#111111' },
        logo = { url = 'http://insecure.example.com/x.png' },
    },
    ['bad key!'] = { label = 'Bad' },
}

-- ── qbx_core mock ───────────────────────────────────────────────────────────
local qbxPlayers = {}
local moneyCalls = {}
local function addPlayer(src, cid, first, last, job, level, gradeName, onduty, callsign, jobs)
    local p = {
        PlayerData = {
            source = src, citizenid = cid,
            charinfo = { firstname = first, lastname = last },
            job = { name = job, label = job:upper(), type = 'leo', onduty = onduty, grade = { name = gradeName, level = level } },
            jobs = jobs or { [job] = level },
            metadata = { callsign = callsign, isdead = false, inlaststand = false },
        },
    }
    p.Functions = {
        AddMoney = function(account, amount, reason)
            moneyCalls[#moneyCalls + 1] = { src = src, account = account, amount = amount, reason = reason }
            return p.moneyResult ~= false
        end,
    }
    qbxPlayers[src] = p
    H.players[src] = H.players[src] or { coords = vec3(src * 10.0, 0.0, 0.0) }
    return p
end

addPlayer(1, 'CPT00001', 'John', 'Doe', 'sast', 3, 'Sergeant', true, '2L-14')
addPlayer(2, 'CPT00002', 'Jane', 'Roe', 'fib', 1, 'Agent', true, 'NO CALLSIGN')
addPlayer(3, 'CPT00003', 'Off', 'Duty', 'sast', 1, 'Trooper', false, '3A-1')
addPlayer(4, 'CPT00004', 'Mo', 'Chanic', 'mechanic', 0, 'Worker', true, nil, { mechanic = 0, sast = 2 })
addPlayer(5, 'CPT00005', 'Ada', 'Min', 'mechanic', 0, 'Worker', true, nil)
addPlayer(6, 'CPT00006', 'Em', 'Ess', 'ambulance', 2, 'Paramedic', true, nil)
addPlayer(7, 'CPT00007', ('N'):rep(40), ('M'):rep(40), 'bcso', 2, nil, true, ('C'):rep(40))
addPlayer(8, 'CPT00008', 'Sus', 'Pended', 'sast', 1, 'Trooper', true, '8X')
addPlayer(9, 'CPT00009', 'Cp', 'Suspend', 'sast', 1, 'Trooper', true, '9X')
addPlayer(10, 'CPT00010', 'Admin', 'Trooper', 'sast', 1, 'Trooper', true, '  10A  ')
addPlayer(11, 'CPT00011', 'Los', 'Santos', 'police', 4, 'Lieutenant', true, 'L-1')
H.players[5].ace = { ['crimsonpolice.admin'] = true }
H.players[10].ace = { ['crimsonpolice.admin'] = true }

H.exportsMock.qbx_core = {
    GetPlayer = function(src) return qbxPlayers[tonumber(src)] end,
    GetPlayerByCitizenId = function(cid)
        for _, p in pairs(qbxPlayers) do if p.PlayerData.citizenid == cid then return p end end
        return nil
    end,
    GetQBPlayers = function() return qbxPlayers end,
    GetJobs = function()
        return { bcso = { label = 'BCSO', grades = { [0] = { name = 'Cadet' }, [2] = { name = 'Deputy' } } } }
    end,
}

-- ── sc-dispatch, sc-ambulance, Renewed-Banking mocks ────────────────────────
local cleared = {}
H.exportsMock['sc-dispatch'] = {
    IsPlayerSuspended = function(cid, job) return cid == 'CPT00008' and job == 'sast' end,
    ClearNotification = function(uid, jobs) cleared[#cleared + 1] = { uid = uid, jobs = jobs } return true end,
}
local doctorExport = 0
H.exportsMock['sc-ambulance'] = { GetDoctorCount = function() return doctorExport end }
local transactions = {}
H.exportsMock['Renewed-Banking'] = {
    handleTransaction = function(account, title, amount, message, issuer, receiver, transType, transId)
        transactions[#transactions + 1] = { account = account, title = title, amount = amount, message = message,
            issuer = issuer, receiver = receiver, transType = transType, transId = transId }
        if account == 'bad' then return nil end
        return { trans_id = transId }
    end,
    removeAccountMoney = function(account, amount) return account == 'sast' and amount <= 1000 end,
    getAccountMoney = function(account) if account == 'sast' then return 5000 end return false end,
}

-- ── load the slice ──────────────────────────────────────────────────────────
H.load('modules/integrations/qbx/server.lua')
H.load('modules/integrations/sc_dispatch/server.lua')
H.load('modules/integrations/sc_ambulance/server.lua')
H.load('modules/integrations/renewed_banking/server.lua')
H.load('modules/access/server.lua')
H.load('modules/permissions/server.lua')
H.load('modules/tablet/server.lua')

-- ════════════════════════════════════════════════════════════════════════════
-- CP.Qbx (server)
-- ════════════════════════════════════════════════════════════════════════════
do
    local info = CP.Qbx.getInfo(1)
    H.eq(info.citizenid, 'CPT00001', 'getInfo citizenid')
    H.eq(info.name, 'John Doe', 'getInfo name')
    H.eq(info.job.name, 'sast', 'job name')
    H.eq(info.job.gradeLevel, 3, 'grade level')
    H.eq(info.job.gradeName, 'Sergeant', 'grade name')
    H.eq(info.job.onduty, true, 'on duty')
    H.eq(info.callsign, '2L-14', 'callsign')
    H.eq(info.isDead, false, 'isDead')
    H.eq(CP.Qbx.getInfo(2).callsign, nil, "'NO CALLSIGN' is no callsign")
    H.eq(CP.Qbx.getInfo(10).callsign, '10A', 'callsign trimmed')
    H.eq(CP.Qbx.getInfo(7).job.gradeName, 'Deputy', 'grade name from the job definition')
    H.eq(CP.Qbx.getInfo(42), nil, 'unknown player')
    H.eq(CP.Qbx.getInfo('abc'), nil, 'non-numeric src')
    H.eq(CP.Qbx.getInfo(-1), nil, 'negative src')
    H.eq(CP.Qbx.getByCitizenId('CPT00002'), 2, 'getByCitizenId')
    H.eq(CP.Qbx.getByCitizenId('cpt00002'), nil, 'citizenid match is exact')
    local online = CP.Qbx.getOnlinePlayers()
    H.eq(#online, 11, 'online players')
    H.eq(online[1], 1, 'sorted')
    H.eq(online[11], 11, 'sorted last')
    H.ok(CP.Qbx.getJobs().bcso ~= nil, 'getJobs')

    -- addMoney: (moneyType, amount, reason), rounded half up, 0 never reaches qbx
    H.eq(CP.Qbx.addMoney(1, 'bank', 12.5, 'crimson-police-mission'), true, 'addMoney ok')
    H.eq(moneyCalls[1].amount, 13, 'rounded half up')
    H.eq(moneyCalls[1].account, 'bank', 'money type first')
    H.eq(moneyCalls[1].reason, 'crimson-police-mission', 'reason passed')
    H.eq(CP.Qbx.addMoney(1, 'bank', 0), true, '0 is a no-op success')
    H.eq(#moneyCalls, 1, '0 did not call AddMoney')
    H.eq(CP.Qbx.addMoney(1, 'bank', -5), false, 'negative refused')
    H.eq(CP.Qbx.addMoney(1, 'bank', 0 / 0), false, 'NaN refused')
    H.eq(CP.Qbx.addMoney(1, '', 5), false, 'account required')
    H.eq(CP.Qbx.addMoney(42, 'bank', 5), false, 'offline player')
    qbxPlayers[1].moneyResult = false
    local okF, whyF = CP.Qbx.addMoney(1, 'bank', 5)
    H.eq(okF, false, 'AddMoney false is passed on')
    H.eq(whyF, nil, 'a plain refusal has no reason (the caller may put the row back to pending)')
    qbxPlayers[1].moneyResult = nil
    -- AddMoney raised: false, 'error' (the balance may have changed: CP.Cash never retries such a row)
    do
        local realAdd = qbxPlayers[1].Functions.AddMoney
        qbxPlayers[1].Functions.AddMoney = function() error('qbx exploded') end
        local okE, whyE = CP.Qbx.addMoney(1, 'bank', 5)
        H.eq(okE, false, 'AddMoney exception -> false')
        H.eq(whyE, 'error', "AddMoney exception -> 'error'")
        qbxPlayers[1].Functions.AddMoney = realAdd
    end
    -- a true half-dollar rounds up (CP.U.round): $350 x 1.15 = $402.50 -> $403
    local nMoney = #moneyCalls
    H.eq(CP.Qbx.addMoney(1, 'bank', 350 * 1.15), true, 'addMoney with a float half')
    H.eq(moneyCalls[nMoney + 1] and moneyCalls[nMoney + 1].amount, 403, 'addMoney rounds a true half up')

    H.eq(CP.Qbx.isDowned(1), false, 'not downed')
    qbxPlayers[1].PlayerData.metadata.inlaststand = true
    H.eq(CP.Qbx.isDowned(1), true, 'last stand is downed')
    qbxPlayers[1].PlayerData.metadata.inlaststand = false
    qbxPlayers[1].PlayerData.metadata.isdead = true
    H.eq(CP.Qbx.isDowned(1), true, 'dead is downed')
    qbxPlayers[1].PlayerData.metadata.isdead = 1
    H.eq(CP.Qbx.isDowned(1), false, 'only a real true counts')
    qbxPlayers[1].PlayerData.metadata.isdead = false

    -- qbx server events are server-local: never registered as net events
    for _, name in ipairs({ 'QBCore:Server:SetDuty', 'QBCore:Server:PlayerLoaded', 'QBCore:Server:OnJobUpdate',
        'QBCore:Server:OnPlayerUnload', 'qbx_core:server:onGroupUpdate' }) do
        H.ok(H.handlers[name] and #H.handlers[name] > 0, name .. ' has a handler')
        H.eq(netEvents[name], nil, name .. ' is not a net event')
    end

    -- listeners
    local duty, loaded, jobs, unloads, groups = {}, {}, {}, {}, {}
    CP.Qbx.onDutyChange(function(src, d) duty[#duty + 1] = { src = src, duty = d } end)
    CP.Qbx.onPlayerLoaded(function(src) loaded[#loaded + 1] = src end)
    CP.Qbx.onJobChange(function(src, job) jobs[#jobs + 1] = { src = src, job = job } end)
    CP.Qbx.onPlayerUnload(function(src) unloads[#unloads + 1] = src end)
    CP.Qbx.onGroupUpdate(function(src) groups[#groups + 1] = src end)
    CP.Qbx.onDutyChange(function() error('listener errors are contained') end)

    TriggerEvent('QBCore:Server:SetDuty', 1, true)
    H.eq(duty[#duty].duty, true, 'SetDuty true (live on duty)')
    TriggerEvent('QBCore:Server:SetDuty', 3, true)
    H.eq(duty[#duty].duty, false, 'stale SetDuty true re-read as off duty')
    TriggerEvent('QBCore:Server:SetDuty', 1, false)
    H.eq(duty[#duty].duty, false, 'SetDuty false passed on directly')
    H.ok(countLogs('listener errors are contained') >= 1, 'a failing listener is logged')
    TriggerEvent('QBCore:Server:PlayerLoaded', qbxPlayers[2])
    H.eq(loaded[#loaded], 2, 'PlayerLoaded src from the player object')
    TriggerEvent('QBCore:Server:PlayerLoaded', 'junk')
    H.eq(#loaded, 1, 'junk PlayerLoaded ignored')
    TriggerEvent('QBCore:Server:OnJobUpdate', 1, { name = 'ignored' })
    H.eq(jobs[#jobs].job.name, 'sast', 'job read live, normalised')
    H.eq(jobs[#jobs].job.gradeLevel, 3, 'normalised job has gradeLevel')
    TriggerEvent('QBCore:Server:OnPlayerUnload', 4)
    H.eq(unloads[#unloads], 4, 'unload')
    TriggerEvent('qbx_core:server:onGroupUpdate', 5, 'ballas', nil)
    H.eq(groups[#groups], 5, 'group update')
    TriggerEvent('QBCore:Server:SetDuty', 'x', false)
    H.eq(#duty, 3, 'invalid src ignored')

    -- qbx_core:server:onSetMetaData (key, oldValue, value, source): server-local, filtered by key
    H.ok(H.handlers['qbx_core:server:onSetMetaData'] and #H.handlers['qbx_core:server:onSetMetaData'] > 0, 'onSetMetaData has a handler')
    H.eq(netEvents['qbx_core:server:onSetMetaData'], nil, 'onSetMetaData is not a net event')
    local metas, allMetas = {}, {}
    CP.Qbx.onMetaDataChange(function(src, key, old, new) metas[#metas + 1] = { src = src, key = key, old = old, new = new } end, { 'isdead', 'inlaststand' })
    CP.Qbx.onMetaDataChange(function(src, key) allMetas[#allMetas + 1] = { src = src, key = key } end)
    CP.Qbx.onMetaDataChange('not a function')
    TriggerEvent('qbx_core:server:onSetMetaData', 'isdead', false, true, 3)
    H.eq(#metas, 1, 'metadata listener called')
    H.eq(metas[1] and metas[1].src, 3, 'metadata listener src (the 4th argument)')
    H.eq(metas[1] and metas[1].key, 'isdead', 'metadata key')
    H.eq(metas[1] and metas[1].old, false, 'metadata old value')
    H.eq(metas[1] and metas[1].new, true, 'metadata new value')
    TriggerEvent('qbx_core:server:onSetMetaData', 'hunger', 50, 49, 3)
    H.eq(#metas, 1, 'a filtered listener skips other keys')
    H.eq(#allMetas, 2, 'an unfiltered listener gets every key')
    TriggerEvent('qbx_core:server:onSetMetaData', 'isdead', false, true, 'x')
    TriggerEvent('qbx_core:server:onSetMetaData', 42, false, true, 3)
    H.eq(#metas, 1, 'invalid src or key ignored')

    stopped.qbx_core = true
    H.eq(CP.Qbx.getInfo(1), nil, 'qbx_core stopped: no info')
    H.eq(#CP.Qbx.getOnlinePlayers(), 0, 'qbx_core stopped: nobody online')
    stopped.qbx_core = nil
end

-- ════════════════════════════════════════════════════════════════════════════
-- CP.Dispatch
-- ════════════════════════════════════════════════════════════════════════════
do
    local D = CP.Dispatch
    H.eq(D.available(), true, 'sc-dispatch available')
    H.eq(D.normalizeCallId(123), '123', 'number')
    H.eq(D.normalizeCallId('123'), '123', 'numeric string')
    H.eq(D.normalizeCallId(123.0), '123', 'float')
    H.eq(D.normalizeCallId('123.0'), '123', 'float string')
    H.eq(D.normalizeCallId('shots_1_2'), 'shots_1_2', 'string unchanged')
    H.eq(D.normalizeCallId('npccall-1-2'), 'npccall-1-2', 'npc id unchanged')
    H.eq(D.normalizeCallId(nil), '', 'nil')
    H.eq(D.normalizeCallId(12.5), '12.5', 'non-integer number')

    H.eq(D.isSuspended('CPT00008', 'sast'), true, 'dispatch suspension')
    H.eq(D.isSuspended('CPT00008', 'fib'), false, 'per job')
    H.eq(D.isSuspended('', 'sast'), false, 'no citizenid')

    local f = assert(io.open('tests/fixtures/core/mdt_dispatch.sql', 'r'))
    H.sql(f:read('a'))
    f:close()
    H.eq(D.lookupActiveCall(1), '1', 'row id number')
    H.eq(D.lookupActiveCall('1'), '1', 'row id string')
    H.eq(D.lookupActiveCall(1.0), '1', 'row id float')
    H.eq(D.lookupActiveCall('shots_12_1790000000'), 'shots_12_1790000000', 'unique id')
    H.eq(D.lookupActiveCall(4), '4', 'NULL unique_id -> row id')
    H.eq(D.lookupActiveCall(6), '6', "'' unique_id -> row id")
    H.eq(D.lookupActiveCall(5), nil, 'inactive call')
    H.eq(D.lookupActiveCall('5'), nil, 'inactive call (string)')
    H.eq(D.lookupActiveCall('npccall-3-1790000000'), 'npccall-3-1790000000', 'npc call row is returned for the caller to classify')
    H.eq(D.lookupActiveCall('nope'), nil, 'unknown call')
    H.eq(D.lookupActiveCall(nil), nil, 'nil id')
    H.eq(D.lookupActiveCall(('x'):rep(70)), nil, 'too long')
    H.sql('RENAME TABLE mdt_dispatch TO mdt_dispatch_off')
    H.eq(D.lookupActiveCall(1), nil, 'query error -> nil')
    H.ok(countLogs('mdt_dispatch lookup failed') == 1, 'query error logged')
    H.sql('RENAME TABLE mdt_dispatch_off TO mdt_dispatch')
    stopped['sc-dispatch'] = true
    H.eq(D.lookupActiveCall(1), nil, 'sc-dispatch stopped -> nil')
    H.eq(D.isSuspended('CPT00008', 'sast'), false, 'sc-dispatch stopped -> not suspended')
    H.eq(D.clearNotification('shots_12_1790000000'), false, 'sc-dispatch stopped -> no clear')
    stopped['sc-dispatch'] = nil

    H.eq(D.clearNotification('shots_12_1790000000'), true, 'clear string id')
    H.eq(cleared[1].uid, 'shots_12_1790000000', 'cleared id')
    H.eq(cleared[1].jobs[1], 'police', 'default jobs')
    H.eq(D.clearNotification('playerdown_12_1790000000', { 'police', 'ambulance', 5 }), true, 'clear with jobs')
    H.eq(#cleared[2].jobs, 2, 'invalid job entries dropped')
    H.eq(D.clearNotification(12), false, 'numeric id refused')
    H.eq(D.clearNotification('12'), false, 'digit-only string refused')
    H.eq(D.clearNotification(''), false, 'empty refused')
    H.eq(#cleared, 2, 'refused ids never reach sc-dispatch')

    -- listeners: net events for client-originated ones, callClearedByOfficer server-local only
    H.eq(netEvents['sc-dispatch:server:ToggleResponding'], true, 'ToggleResponding is a net event')
    H.eq(netEvents['sc-dispatch:server:ShotsFired'], true, 'ShotsFired is a net event')
    H.eq(netEvents['sc-dispatch:server:PlayerDown'], true, 'PlayerDown is a net event')
    H.eq(netEvents['sc-dispatch:server:PlayerDead'], true, 'PlayerDead is a net event')
    H.eq(netEvents['sc-dispatch:server:callClearedByOfficer'], nil, 'callClearedByOfficer is not a net event')
    local responding, clearedCalls, restarts, shots, downs, deads = {}, {}, 0, {}, {}, {}
    D.onResponding(function(src, callId, isResponding) responding[#responding + 1] = { src = src, callId = callId, r = isResponding } end)
    D.onCallCleared(function(callId) clearedCalls[#clearedCalls + 1] = callId end)
    D.onDispatchRestart(function() restarts = restarts + 1 end)
    D.onShotsFired(function(src, data, at) shots[#shots + 1] = { src = src, data = data, at = at } end)
    D.onPlayerDown(function(src, data, at) downs[#downs + 1] = { src = src, data = data, at = at } end)
    D.onPlayerDead(function(src, data, at) deads[#deads + 1] = { src = src, data = data, at = at } end)

    H.fire('sc-dispatch:server:ToggleResponding', 12, 'police_1_1790000000', true)
    H.eq(responding[1].src, 12, 'responding src captured')
    H.eq(responding[1].callId, 'police_1_1790000000', 'callId passed')
    H.eq(responding[1].r, true, 'isResponding')
    H.fire('sc-dispatch:server:ToggleResponding', 12, 77, nil)
    H.eq(responding[2].r, false, 'falsy isResponding -> false')
    H.eq(responding[2].callId, 77, 'numeric callId kept')
    H.fire('sc-dispatch:server:ToggleResponding', 12, { 'table' }, true)
    H.fire('sc-dispatch:server:ToggleResponding', 12, ('x'):rep(80), true)
    H.fire('sc-dispatch:server:ToggleResponding', 0, 'abc', true)
    H.eq(#responding, 2, 'invalid payloads and senders ignored')
    for i = 1, 10 do H.fire('sc-dispatch:server:ToggleResponding', 13, 'c' .. i, true) end
    H.eq(#responding, 8, 'rate limited to 6 per second per player')

    TriggerEvent('sc-dispatch:server:callClearedByOfficer', 'police_1_1790000000')
    TriggerEvent('sc-dispatch:server:callClearedByOfficer', nil)
    H.eq(#clearedCalls, 1, 'call cleared listener')
    TriggerEvent('onResourceStart', 'sc-dispatch')
    TriggerEvent('onResourceStop', 'sc-dispatch')
    TriggerEvent('onResourceStart', 'something-else')
    H.eq(restarts, 2, 'sc-dispatch start/stop -> restart listeners')

    H.fire('sc-dispatch:server:ShotsFired', 14, { coords = vec3(1.0, 2.0, 3.0), street = 'Main St', zone = 'DOWNT', evil = 'x' })
    H.eq(shots[1].src, 14, 'shots src')
    H.eq(shots[1].at, H.time, 'receivedAt = os.time() at arrival')
    H.eq(shots[1].data.street, 'Main St', 'street kept')
    H.eq(shots[1].data.evil, nil, 'unknown fields dropped')
    H.near(shots[1].data.coords.y, 2.0, 1e-9, 'coords kept')
    H.fire('sc-dispatch:server:ShotsFired', 14, { street = 'no coords' })
    H.fire('sc-dispatch:server:ShotsFired', 14, 'junk')
    H.eq(#shots, 1, 'no coords -> no event (sc-dispatch makes no call either)')
    H.fire('sc-dispatch:server:PlayerDown', 15, { coords = { x = 1, y = 2, z = 3 }, street = 'A / B', sex = 'male' })
    H.eq(downs[1].data.sex, 'male', 'player down')
    H.near(downs[1].data.coords.x, 1.0, 1e-9, 'table coords become a vector')
    H.fire('sc-dispatch:server:PlayerDead', 16, { coords = vec3(0.0, 0.0, 0.0) })
    H.eq(deads[1].src, 16, 'player dead')
end

-- ════════════════════════════════════════════════════════════════════════════
-- CP.Ambulance (server)
-- ════════════════════════════════════════════════════════════════════════════
do
    local A = CP.Ambulance
    doctorExport = 3
    H.eq(A.doctorCount(), 1, 'export 3 but 1 on-duty ambulance player -> 1')
    doctorExport = 0
    H.eq(A.doctorCount(), 0, 'export 0 -> 0')
    doctorExport = 2
    qbxPlayers[6].PlayerData.job.onduty = false
    H.eq(A.doctorCount(), 0, 'inflated export with nobody on duty -> 0')
    qbxPlayers[6].PlayerData.job.onduty = true
    doctorExport = '1'
    H.eq(A.doctorCount(), 1, 'numeric string export')
    stopped['sc-ambulance'] = true
    local before = countLogs('sc-ambulance is not started')
    H.eq(A.doctorCount(), 0, 'not started -> 0')
    H.eq(A.doctorCount(), 0, 'not started -> 0 again')
    H.eq(countLogs('sc-ambulance is not started') - before, 1, 'one error log')
    H.eq(A.revive(1), false, 'no revive while sc-ambulance is stopped')
    stopped['sc-ambulance'] = nil
    H.reset()
    H.eq(A.revive(1), true, 'revive')
    local ev = lastEvent('hospital:client:Revive')
    H.eq(ev and ev.target, 1, 'revive targets exactly that player')
    H.eq(ev and #ev.args, 0, 'revive has no payload')
    H.eq(A.revive(-1), false, 'never -1')
    H.eq(A.revive(0), false, 'never 0')
    H.eq(A.revive('x'), false, 'numeric only')
    H.eq(A.revive(1.5), false, 'integer only')
    H.eq(A.revive(99), false, 'not connected')
    H.eq(#H.findEvents('hospital:client:Revive'), 1, 'refused revives send nothing')

    -- CRIMSON_ARENA rule 3: never revive an in-arena player (Crimson-Arena revives its own)
    CP.Alerts = { inArena = function(src) return src == 1 end }
    local refusedBefore = countLogs('revive refused for player 1')
    H.eq(A.revive(1), false, 'in-arena player is not revived')
    H.eq(countLogs('revive refused for player 1') - refusedBefore, 1, 'in-arena refusal logged')
    H.eq(A.revive(2), true, 'players outside the arena are still revived')
    CP.Alerts = { inArena = function() error('alerts broken') end }
    H.eq(A.revive(2), false, 'an inArena error refuses the revive (fail closed)')
    CP.Alerts = nil
    H.eq(#H.findEvents('hospital:client:Revive'), 2, 'only the revive outside the arena was sent')
    H.eq(lastEvent('hospital:client:Revive').target, 2, 'revive target outside the arena')
end

-- ════════════════════════════════════════════════════════════════════════════
-- CP.Banking
-- ════════════════════════════════════════════════════════════════════════════
do
    local B = CP.Banking
    H.eq(B.recordDeposit('CPT00001', 499.5, "Mission payout: Gang's \\Hideout", 'San Andreas State Troopers', "John O'Doe", 'CP-uuid-CPT00001'), true, 'deposit')
    local t = transactions[1]
    H.eq(t.account, 'CPT00001', 'account first')
    H.eq(t.title, 'Crimson-Police', 'title')
    H.eq(t.amount, 500, 'amount rounded, a number')
    H.eq(math.type(t.amount), 'integer', 'integer amount')
    H.eq(t.message, 'Mission payout: Gangs Hideout', "' and \\ removed from the message")
    H.eq(t.issuer, 'San Andreas State Troopers', 'issuer')
    H.eq(t.receiver, "John O'Doe", 'receiver untouched')
    H.eq(t.transType, 'deposit', 'type')
    H.eq(t.transId, 'CP-uuid-CPT00001', 'transaction id')
    H.eq(B.recordSocietyWithdraw('sast', 500, 'Mission payout: X', 'San Andreas State Troopers', 'John Doe', 'CP-uuid-CPT00001'), true, 'society withdraw entry')
    H.eq(transactions[2].transType, 'withdraw', 'withdraw type')
    H.eq(B.recordDeposit('CPT00001', 0, 'x', 'a', 'b', 'id'), true, '$0 is not recorded')
    H.eq(#transactions, 2, '$0 never reaches Renewed-Banking')
    H.eq(B.recordDeposit('CPT00001', 10, 'x', nil, nil, nil), true, 'nil issuer/receiver become strings')
    H.eq(transactions[3].issuer, '', 'issuer never nil')
    H.eq(transactions[3].transId, nil, 'transId optional')
    -- long text is cut without splitting a UTF-8 character
    H.eq(B.recordDeposit('CPT00001', 10, ('m'):rep(199) .. 'é', 'x', ('r'):rep(98) .. '€', nil), true, 'long texts')
    local tl = transactions[#transactions]
    H.eq(#tl.message, 199, 'message cut before the split character')
    H.ok(utf8.len(tl.message) ~= nil, 'message stays valid UTF-8')
    H.eq(#tl.receiver, 98, 'receiver cut before the split character')
    H.ok(utf8.len(tl.receiver) ~= nil, 'receiver stays valid UTF-8')
    H.eq(B.recordDeposit('bad', 10, 'x', 'a', 'b'), false, 'rejected arguments -> false')
    H.eq(B.recordDeposit(nil, 10, 'x', 'a', 'b'), false, 'account required')
    H.eq(B.recordDeposit('CPT00001', -1, 'x', 'a', 'b'), false, 'negative refused')
    H.eq(B.withdrawSociety('sast', 800), true, 'withdraw covered')
    H.eq(B.withdrawSociety('sast', 5000), false, 'withdraw not covered')
    H.eq(B.withdrawSociety('nope', 5), false, 'unknown account')
    H.eq(B.withdrawSociety('sast', 0), true, '0 needs no withdrawal')
    H.eq(B.societyBalance('sast'), 5000, 'balance')
    H.eq(B.societyBalance('nope'), nil, 'unknown account -> nil')
    stopped['Renewed-Banking'] = true
    H.eq(B.recordDeposit('CPT00001', 10, 'x', 'a', 'b'), false, 'stopped -> false')
    H.eq(B.withdrawSociety('sast', 5), false, 'stopped -> false')
    H.eq(B.societyBalance('sast'), nil, 'stopped -> nil')
    stopped['Renewed-Banking'] = nil
end

-- ════════════════════════════════════════════════════════════════════════════
-- CP.Access (server)
-- ════════════════════════════════════════════════════════════════════════════
do
    local A = CP.Access
    -- departments
    local list = A.departments()
    H.eq(#list, 5, 'five valid departments (bad key ignored)')
    H.eq(list[1].key, 'bcso', 'sorted by key')
    H.eq(list[5].key, 'zdup', 'sorted by key (last)')
    local sast = A.department('sast')
    H.eq(sast.label, 'San Andreas State Troopers', 'label')
    H.eq(sast.theme.text, '#ffffff', 'text picked for contrast')
    H.eq(sast.theme.primary, '#1f4e8c', 'primary kept')
    H.eq(sast.logo.url, 'https://cfx-nui-Crimson-Police/logos/sast.png', 'logo url from file')
    H.eq(sast.logo.opacity, 0.08, 'opacity')
    H.eq(sast.logo.size, 0.6, 'size')
    H.eq(sast.logo.watermark, true, 'watermark')
    H.eq(sast.supervisorGrade, 3, 'supervisor grade')
    local bcso = A.department('bcso')
    H.eq(bcso.theme.primary, '#a4161a', 'invalid primary -> default')
    H.eq(bcso.theme.accent, '#e5383b', 'invalid accent -> default')
    H.eq(bcso.theme.background, '#f5f5f5', 'hex lower-cased')
    H.eq(bcso.theme.text, '#111111', 'invalid text -> contrast pick')
    H.eq(bcso.logo.opacity, 0.25, 'opacity clamped to 0.25')
    H.eq(bcso.logo.size, 0.6, 'invalid size -> 0.6')
    H.eq(bcso.logo.grayscale, true, 'grayscale')
    H.eq(bcso.jobs[1], 'bcso', 'a single job string is accepted')
    H.eq(bcso.societyAccount, 'bcso', 'society account defaults to the first job')
    local lspd = A.department('lspd')
    H.eq(lspd.logo.url, 'https://example.com/lspd.png', 'https url')
    H.eq(lspd.logo.file, nil, 'no file for a url logo')
    H.eq(lspd.logo.opacity, 0.0, 'opacity clamped to 0')
    H.eq(lspd.logo.watermark, false, 'watermark off')
    H.eq(lspd.theme.text, '#eeeeee', 'explicit text kept')
    H.eq(lspd.supervisorGrade, 1000, 'no supervisorGrade -> nobody is a supervisor')
    H.eq(A.department('zdup').logo.url, nil, 'http url refused')
    H.eq(A.department('nope'), nil, 'unknown department')
    H.eq(A.departmentForJob('sast'), 'sast', 'job -> department (first key wins a duplicate)')
    H.eq(A.departmentForJob('dupjob'), 'zdup', 'second job of a department')
    H.eq(A.departmentForJob('police'), 'lspd', 'police job')
    H.eq(A.departmentForJob('mechanic'), nil, 'not a department job')
    H.eq(A.departmentForJob(nil), nil, 'nil job')
    sast.theme.primary = '#000000'
    H.eq(A.department('sast').theme.primary, '#1f4e8c', 'department() returns a copy')

    H.eq(countLogs('theme.primary is "red"'), 1, 'bad primary warned')
    H.eq(countLogs('theme.accent is "#12345"'), 1, 'bad accent warned')
    H.eq(countLogs('theme.text is "nope"'), 1, 'bad text warned')
    H.eq(countLogs('logo.opacity 0.5'), 1, 'opacity warned')
    H.eq(countLogs('logo.url must be a direct https://'), 1, 'http url warned')
    H.eq(countLogs('supervisorGrade must be a Qbox grade level'), 1, 'missing grade warned')
    H.eq(countLogs('Qbox job sast is listed in departments'), 1, 'duplicate job warned')
    H.eq(countLogs('must be letters, digits or _'), 1, 'bad key warned')
    local warnedBefore = countLogs('[crimson-police:access]')
    A.departments()
    local copy = {}
    for k, v in pairs(Config.Departments) do copy[k] = v end
    Config.Departments = copy   -- a rebuild with the same content warns nothing new
    A.departments()
    H.eq(countLogs('[crimson-police:access]'), warnedBefore, 'one warning per bad key, ever')
    H.eq(countLogs('logos/bcso.png is missing'), 1, 'missing logo file warned once at start')

    -- roles and officers
    H.eq(A.isAdmin(5), true, 'ace admin')
    H.eq(A.isAdmin(1), false, 'not admin')
    H.eq(A.isAdmin(0), true, 'console is admin')
    H.eq(A.isAdmin(-3), false, 'negative src')
    local o = A.getOfficer(1)
    H.eq(o.citizenid, 'CPT00001', 'officer citizenid')
    H.eq(o.department, 'sast', 'officer department')
    H.eq(o.departmentLabel, 'San Andreas State Troopers', 'officer department label')
    H.eq(o.departmentShort, 'SAST', 'officer short')
    H.eq(o.job, 'sast', 'officer job')
    H.eq(o.rank, 'Sergeant', 'officer rank')
    H.eq(o.gradeLevel, 3, 'officer grade')
    H.eq(o.callsign, '2L-14', 'officer callsign')
    H.eq(o.isSupervisor, true, 'grade 3 >= supervisorGrade 3')
    H.eq(o.isAdmin, false, 'officer not admin')
    H.eq(o.onduty, true, 'officer on duty')
    local fibAgent = A.getOfficer(2)
    H.eq(fibAgent.isSupervisor, false, 'grade 1 is not a supervisor')
    H.eq(fibAgent.callsign, nil, 'no callsign')
    local long = A.getOfficer(7)
    H.eq(#long.callsign, 32, 'callsign clipped to 32')
    H.eq(#long.name, 64, 'name clipped to 64')
    H.eq(long.isSupervisor, true, 'bcso grade 2 >= 2')
    local off, offErr = A.getOfficer(3)
    H.eq(off, nil, 'off duty is no officer')
    H.eq(offErr, 'err.not_on_duty', 'off duty error')
    local _, secondJobErr = A.getOfficer(4)
    H.eq(secondJobErr, 'err.not_police', 'a department job held as a second job gives no access')
    local _, adminErr = A.getOfficer(5)
    H.eq(adminErr, 'err.not_police', 'admin without a police job is no officer')
    local _, dispErr = A.getOfficer(8)
    H.eq(dispErr, 'err.suspended_dispatch', 'sc-dispatch suspension')
    local _, noneErr = A.getOfficer(42)
    H.eq(noneErr, 'err.not_police', 'no character')
    H.eq(A.getOfficer(10).isAdmin, true, 'officer who is also an admin')
    H.eq(A.isSupervisor(1), true, 'isSupervisor')
    H.eq(A.isSupervisor(2), false, 'isSupervisor false')
    H.eq(A.isSupervisor(3), false, 'off duty supervisor-grade check fails')
    H.eq(A.role(5), 'admin', 'role admin')
    H.eq(A.role(1), 'supervisor', 'role supervisor')
    H.eq(A.role(2), 'officer', 'role officer')
    H.eq(A.role(4), nil, 'role none')

    -- recheck
    H.eq(A.recheck(1, 'sast'), true, 'recheck ok')
    local ok, why = A.recheck(1, 'fib')
    H.eq(ok, false, 'job differs')
    H.eq(why, 'job_change', 'job_change')
    ok, why = A.recheck(3, 'sast')
    H.eq(why, 'off_duty', 'off_duty')
    ok, why = A.recheck(4, 'mechanic')
    H.eq(why, 'job_change', 'job outside every department is a job change')
    ok, why = A.recheck(8, 'sast')
    H.eq(why, 'suspended', 'dispatch suspended')
    H.eq(A.recheck(42, 'sast'), true, 'no character: left to the disconnect path')

    -- suspensions (cp_officers.suspended_until)
    H.sql('DELETE FROM cp_officers')
    H.eq(A.isSuspended('CPT00009'), false, 'not suspended (query)')
    H.reset()
    local okS, errS = A.suspend('CPT00009', 7, 0, 'test')
    H.eq(okS, true, 'suspend')
    H.eq(errS, nil, 'no error')
    local row = H.sql('SELECT UNIX_TIMESTAMP(suspended_until) AS ts FROM cp_officers WHERE citizenid = ?', { 'CPT00009' })[1]
    H.eq(row and row.ts, H.time + 7 * 86400, 'suspended_until written')
    local s, untilTs = A.isSuspended('CPT00009')
    H.eq(s, true, 'suspended (cache)')
    H.eq(untilTs, H.time + 7 * 86400, 'until')
    H.time = H.time + 20   -- cache expired: read from the database
    s, untilTs = A.isSuspended('CPT00009')
    H.eq(s, true, 'suspended (database)')
    H.eq(untilTs, H.time - 20 + 7 * 86400, 'until from the database')
    local _, suspErr = A.getOfficer(9)
    H.eq(suspErr, 'err.suspended', 'suspended officer refused')
    ok, why = A.recheck(9, 'sast')
    H.eq(why, 'suspended', 'recheck suspended')
    local note = lastEvent('crimson-police:client:notify')
    H.eq(note and note.target, 9, 'suspended officer told')
    H.eq(note and note.args[1].key, 'access.suspended_notice', 'suspension notice')
    H.eq(note and note.args[1].vars.days, 7, 'days in the notice')
    H.eq(select(2, A.suspend('CPT00009', 1, 1, 'supervisor tries')), 'err.no_permission', 'supervisors cannot suspend')
    H.eq(A.suspend('CPT00009', 0, 5, 'lifted by admin'), true, 'admin lifts it')
    H.eq(A.isSuspended('CPT00009'), false, 'lifted')
    H.eq(H.sql('SELECT suspended_until FROM cp_officers WHERE citizenid = ?', { 'CPT00009' })[1].suspended_until, nil, 'suspended_until cleared')
    H.ok(A.getOfficer(9) ~= nil, 'officer again')
    H.eq(lastEvent('crimson-police:client:notify').args[1].key, 'access.unsuspended_notice', 'lift notice')
    H.eq(A.suspend('NOBODY01', 3, 0, 'offline'), true, 'suspend an unknown citizenid (row created)')
    H.eq(H.sql('SELECT COUNT(*) AS n FROM cp_officers WHERE citizenid = ?', { 'NOBODY01' })[1].n, 1, 'row created')
    H.eq(A.suspend('NOBODY01', 5, 0, 'longer'), true, 'suspend again (upsert)')
    H.eq(H.sql('SELECT UNIX_TIMESTAMP(suspended_until) AS ts FROM cp_officers WHERE citizenid = ?', { 'NOBODY01' })[1].ts, H.time + 5 * 86400, 'upsert updated')
    H.eq(select(2, A.suspend('', 1)), 'err.invalid_citizenid', 'empty citizenid')
    H.eq(select(2, A.suspend('A B', 1)), 'err.invalid_citizenid', 'bad citizenid')
    H.eq(select(2, A.suspend(nil, 1)), 'err.invalid_citizenid', 'nil citizenid')
    H.eq(select(2, A.suspend('CPT00009', -1)), 'err.invalid_days', 'negative days')
    H.eq(select(2, A.suspend('CPT00009', 1.5)), 'err.invalid_days', 'fractional days')
    H.eq(select(2, A.suspend('CPT00009', 4000)), 'err.invalid_days', 'too many days')
    H.eq(select(2, A.suspend('CPT00009', 'x')), 'err.invalid_days', 'days not a number')

    -- refreshOfficerRow (upsert with clipped values, '' -> NULL)
    H.eq(A.refreshOfficerRow(1), true, 'refresh officer 1')
    local r1 = H.sql('SELECT callsign, rank_label, display_name, department FROM cp_officers WHERE citizenid = ?', { 'CPT00001' })[1]
    H.eq(r1.callsign, '2L-14', 'stored callsign')
    H.eq(r1.rank_label, 'Sergeant', 'stored rank')
    H.eq(r1.display_name, 'John Doe', 'stored name')
    H.eq(r1.department, 'sast', 'stored department')
    H.eq(A.refreshOfficerRow(2), true, 'refresh officer 2')
    H.eq(H.sql('SELECT callsign FROM cp_officers WHERE citizenid = ?', { 'CPT00002' })[1].callsign, nil, 'no callsign -> NULL')
    H.eq(A.refreshOfficerRow(7), true, 'refresh officer 7')
    local r7 = H.sql('SELECT callsign, rank_label, display_name FROM cp_officers WHERE citizenid = ?', { 'CPT00007' })[1]
    H.eq(#r7.callsign, 32, 'callsign clipped in the row')
    H.eq(#r7.display_name, 64, 'name clipped in the row')
    H.eq(r7.rank_label, 'Deputy', 'rank from the job definition')
    H.eq(A.refreshOfficerRow(3), true, 'off-duty officers are refreshed too')
    H.eq(A.refreshOfficerRow(4), false, 'civilians get no row')
    H.eq(H.sql('SELECT COUNT(*) AS n FROM cp_officers WHERE citizenid = ?', { 'CPT00004' })[1].n, 0, 'no civilian row')
    qbxPlayers[1].PlayerData.metadata.callsign = '2L-99'
    A.refreshOfficerRow(1)
    H.eq(H.sql('SELECT callsign FROM cp_officers WHERE citizenid = ?', { 'CPT00001' })[1].callsign, '2L-99', 'upsert updates the callsign')
    qbxPlayers[1].PlayerData.metadata.callsign = '2L-14'

    -- A multi-byte character at the column limit is dropped whole: oxmysql talks utf8mb4 and strict mode
    -- rejects half a character (the harness's mysql client is latin1, so these writes switch to utf8mb4;
    -- the saves folder engine of files mode is utf8mb4 already and takes no SET NAMES).
    local realUpdate = MySQL.update.await
    if H.storage ~= 'files' then
        MySQL.update.await = function(sql, params) return realUpdate('SET NAMES utf8mb4; ' .. sql, params) end
    end
    H.ok(not pcall(H.sql, "SET NAMES utf8mb4; INSERT INTO cp_officers (citizenid, display_name) VALUES ('UTFCTRL1', ?)",
        { ('a'):rep(63) .. '\195' }), 'control: strict mode rejects a name cut inside a character')
    addPlayer(20, 'CPT00020', ('a'):rep(62), 'é', 'sast', 1, ('R'):rep(39) .. '€', true, ('C'):rep(31) .. 'ñ')
    local u = A.getOfficer(20)
    H.eq(#u.name, 63, 'name cut before the split é')
    H.ok(utf8.len(u.name) ~= nil, 'officer name stays valid UTF-8')
    H.eq(#u.callsign, 31, 'callsign cut before the split ñ')
    H.eq(#u.rank, 39, 'rank cut before the split €')
    H.eq(A.refreshOfficerRow(20), true, 'row with multi-byte text at the limits is written')
    local r20 = H.sql('SET NAMES utf8mb4; SELECT callsign, rank_label, display_name FROM cp_officers WHERE citizenid = ?', { 'CPT00020' })[1]
    H.eq(r20 and r20.display_name, ('a'):rep(62) .. ' ', 'stored name')
    H.eq(r20 and r20.callsign, ('C'):rep(31), 'stored callsign')
    H.eq(r20 and r20.rank_label, ('R'):rep(39), 'stored rank')
    qbxPlayers[20].PlayerData.charinfo = { firstname = 'José', lastname = 'Núñez' }
    H.eq(A.getOfficer(20).name, 'José Núñez', 'short multi-byte names are kept whole')
    H.eq(A.refreshOfficerRow(20), true, 'short multi-byte name written')
    H.eq(H.sql('SET NAMES utf8mb4; SELECT display_name FROM cp_officers WHERE citizenid = ?', { 'CPT00020' })[1].display_name,
        'José Núñez', 'multi-byte name stored')
    MySQL.update.await = realUpdate
    qbxPlayers[20] = nil
    H.sql("DELETE FROM cp_officers WHERE citizenid IN ('CPT00020', 'UTFCTRL1')")

    -- GetDepartment export
    H.eq(exported.GetDepartment(1), 'sast', 'export GetDepartment')
    H.eq(exported.GetDepartment(3), 'sast', 'GetDepartment ignores duty')
    H.eq(exported.GetDepartment(4), nil, 'GetDepartment none')
    H.eq(exported.GetDepartment('x'), nil, 'GetDepartment bad src')
end

-- ════════════════════════════════════════════════════════════════════════════
-- CP.Permissions
-- ════════════════════════════════════════════════════════════════════════════
do
    local P = CP.Permissions
    H.sql('DELETE FROM cp_mission_runs')
    local insertRun = "INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason, points_base) VALUES (?, 'patrol', 'beat_patrol', ?, 'sast', 'completed', 'completed', 60)"
    H.sql(insertRun, { '11111111-1111-4111-8111-111111111111', 'CPT00001' })
    H.sql(insertRun, { '22222222-2222-4222-8222-222222222222', 'CPT00005' })
    local runA, runB = '11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222'

    H.eq(P.can(5, 'suspend'), true, 'admin: admin-only action')
    H.eq(P.can(5, 'forceRecall'), true, 'admin: supervisor action')
    H.eq(P.can(5, 'builderRollback'), true, 'admin: supervisor action switched off for supervisors')
    H.eq(P.can(0, 'reloadMissions'), true, 'console')
    H.eq(P.can(1, 'forceRecall'), true, 'supervisor: switched on')
    local ok, err = P.can(1, 'builderRollback')
    H.eq(ok, false, 'supervisor: switched off')
    H.eq(err, 'err.no_permission', 'no permission key')
    H.eq(P.can(1, 'suspend'), false, 'supervisor: admin-only')
    H.eq(P.can(1, 'openAdmin'), false, 'supervisor: openAdmin is admin-only')
    H.eq(P.can(1, 'viewMissionList'), true, 'supervisor: mission list')
    H.eq(P.can(2, 'viewMissionList'), false, 'officer: no mission list')
    H.eq(P.can(2, 'forceRecall'), false, 'officer refused')
    H.eq(P.can(3, 'forceRecall'), false, 'off-duty supervisor-grade refused')
    H.eq(P.can(1, nil), false, 'no action')
    H.eq(P.can(1, 'somethingUnknown'), false, 'unknown supervisor action')
    Config.Permissions.supervisor.forceRecall = false
    H.eq(P.can(1, 'forceRecall'), false, 'config read at call time')
    Config.Permissions.supervisor.forceRecall = true
    Config.Permissions.supervisor.suspend = true
    H.eq(P.can(1, 'suspend'), false, 'admin-only whatever the config says')
    Config.Permissions.supervisor.suspend = nil

    ok, err = P.can(1, 'reviewFlagged', { runUuid = runA })
    H.eq(ok, false, 'own run refused')
    H.eq(err, 'err.own_run', 'own run key')
    H.eq(P.can(2, 'reviewFlagged', { runUuid = runA }), false, 'officer still refused')
    H.eq(P.can(5, 'reviewFlagged', { runUuid = runA }), true, 'admin reviews a run they were not on')
    ok, err = P.can(5, 'voidAnyRun', { runUuid = runB })
    H.eq(err, 'err.own_run', 'admins cannot review their own run either')
    H.eq(P.can(1, 'forceRecall', { runUuid = runA }), true, 'own-run rule only for review actions')
    ok, err = P.can(1, 'reviewFlagged', { department = 'fib' })
    H.eq(err, 'err.other_department', 'other department refused')
    H.eq(P.can(1, 'reviewFlagged', { departments = { 'fib', 'sast' } }), true, 'department list')
    H.eq(P.can(1, 'reviewFlagged', { departments = { sast = true } }), true, 'department set')
    H.eq(P.can(5, 'reviewFlagged', { department = 'fib' }), true, 'admins cover every department')

    H.eq(P.tookPart('CPT00001', runA), true, 'tookPart')
    H.eq(P.tookPart('CPT00002', runA), false, 'did not take part')
    H.eq(P.tookPart('CPT00001', 'bad uuid!'), false, 'invalid uuid')
    H.eq(P.canReviewRun(0, runA), true, 'console reviews')
    H.eq(select(2, P.canReviewRun(1, 'bad uuid!')), 'err.invalid_run', 'invalid run')
    H.eq(select(2, P.canReviewRun(1, runA)), 'err.own_run', 'canReviewRun own run')
    H.eq(P.canReviewRun(2, runA), true, 'canReviewRun other run')
    H.eq(P.canReviewRun(42, runA), true, 'no character')

    local adminActions = P.actionsFor(5)
    local set = {}
    for _, a in ipairs(adminActions) do set[a] = true end
    H.ok(set.suspend and set.forceRecall and set.builderRollback and set.viewMissionList and set.openAdmin, 'admin actions')
    local sorted = true
    for i = 2, #adminActions do if adminActions[i - 1] > adminActions[i] then sorted = false end end
    H.ok(sorted, 'actions sorted')
    local supActions = {}
    for _, a in ipairs(P.actionsFor(1)) do supActions[a] = true end
    H.ok(supActions.forceRecall and supActions.viewMissionList and supActions.setTypePayout, 'supervisor actions')
    H.ok(not supActions.builderRollback and not supActions.suspend, 'supervisor never gets switched-off or admin-only actions')
    H.eq(#P.actionsFor(2), 0, 'officer has no actions')
    H.eq(#P.actionsFor(4), 0, 'civilian has no actions')
end

-- ════════════════════════════════════════════════════════════════════════════
-- CP.Tablet (server)
-- ════════════════════════════════════════════════════════════════════════════
do
    local function session(src, args)
        H.clockMs = H.clockMs + 300
        return H.callback('crimson-police:getSession', src, args)
    end
    local res = session(1, { ui = 'officer' })
    H.eq(res.ok, true, 'officer session')
    local s = res.data
    H.eq(s.ui, 'officer', 'ui')
    H.eq(s.title, 'Crimson-Police', 'title')
    H.eq(s.roles.officer, true, 'role officer')
    H.eq(s.roles.supervisor, true, 'role supervisor')
    H.eq(s.roles.admin, false, 'role admin')
    H.eq(s.officer.citizenid, 'CPT00001', 'officer citizenid')
    H.eq(s.officer.departmentLabel, 'San Andreas State Troopers', 'header label')
    H.eq(s.officer.departmentShort, 'SAST', 'header tag')
    H.eq(s.officer.rank, 'Sergeant', 'header rank')
    H.eq(s.officer.callsign, '2L-14', 'header callsign')
    H.eq(s.officer.gradeLevel, 3, 'grade level')
    H.eq(s.officer.src, nil, 'session officer has the §9.2 fields only')
    H.eq(s.theme.primary, '#1f4e8c', 'department theme')
    H.eq(s.theme.text, '#ffffff', 'auto text')
    H.eq(s.logo.url, 'https://cfx-nui-Crimson-Police/logos/sast.png', 'logo url')
    H.eq(s.logo.opacity, 0.08, 'logo opacity')
    H.eq(s.logo.file, nil, 'logo has the §9.2 fields only')
    H.ok(type(s.actions) == 'table' and #s.actions > 0, 'actions')
    H.eq(type(s.locale), 'table', 'locale')
    H.eq(s.serverTime, H.time, 'server time')
    local c = s.config
    H.eq(#c.missionTypes, 4, 'mission types')
    H.eq(c.missionTypes[1].key, 'patrol', 'patrol first (by points)')
    H.eq(c.missionTypes[1].points, 60, 'points')
    H.eq(c.missionTypes[4].key, 'tactical', 'tactical last')
    H.eq(c.missionTypes[2].label, 'Training', 'label')
    H.eq(#c.departments, 5, 'departments')
    H.eq(c.departments[1].key, 'bcso', 'departments sorted')
    H.eq(c.departments[1].primary, '#a4161a', 'department primary (sanitised)')
    H.eq(#c.tiers, 5, 'tiers')
    H.eq(c.tiers[1].name, 'standard', 'tier name')
    H.eq(c.tiers[1].label, CP.L('tier.standard'), 'tier label from the locale')
    H.eq(c.maxRecalcs, 2, 'maxRecalcs')
    H.eq(c.disputeWindowHours, 48, 'dispute window')
    H.eq(table.concat(c.periods, ','), 'weekly,monthly,season,alltime', 'periods')
    H.eq(table.concat(c.filters, ','), 'overall,patrol,training,investigation,tactical,unit,cross,department', 'filters')

    -- opening the Officer UI refreshes the stored callsign; the silent theme fetch does not
    qbxPlayers[1].PlayerData.metadata.callsign = '2L-15'
    session(1, { ui = 'officer' })
    H.eq(H.sql('SELECT callsign FROM cp_officers WHERE citizenid = ?', { 'CPT00001' })[1].callsign, '2L-15', 'refreshed on open')
    qbxPlayers[1].PlayerData.metadata.callsign = '2L-16'
    session(1, { ui = 'officer', silent = true })
    H.eq(H.sql('SELECT callsign FROM cp_officers WHERE citizenid = ?', { 'CPT00001' })[1].callsign, '2L-15', 'silent fetch does not refresh')
    qbxPlayers[1].PlayerData.metadata.callsign = '2L-14'

    H.eq(session(1).data.ui, 'officer', 'no args -> officer')
    H.eq(session(1, { ui = 'supervisor' }).data.ui, 'supervisor', 'supervisor session')
    H.eq(session(2, { ui = 'supervisor' }).error, 'err.not_supervisor', 'grade too low')
    H.eq(CP.Access.isSupervisor(10), false, 'player 10 is an admin below supervisorGrade')
    H.eq(session(10, { ui = 'supervisor' }).error, 'err.not_supervisor',
        'the admin ace does not open the Supervisor UI below supervisorGrade (grade only; admins use the Admin UI)')
    local adminOfficer = session(10, { ui = 'officer' })
    H.eq(adminOfficer.data.roles.supervisor, false, 'no Supervisor switch for an admin below supervisorGrade')
    H.eq(adminOfficer.data.roles.admin, true, 'the admin role is still reported')
    H.eq(session(3, { ui = 'officer' }).error, 'err.not_on_duty', 'off duty')
    H.eq(session(3, { ui = 'supervisor' }).error, 'err.not_on_duty', 'off duty supervisor UI')
    H.eq(session(4, { ui = 'officer' }).error, 'err.not_police', 'second job')
    H.eq(session(8, { ui = 'officer' }).error, 'err.suspended_dispatch', 'dispatch suspended')
    H.eq(session(1, { ui = 'nope' }).error, 'err.invalid_ui', 'unknown ui')
    H.eq(session(1, 'officer').error, 'err.invalid_payload', 'args must be a table')

    local admin = session(5, { ui = 'admin' })
    H.eq(admin.ok, true, 'admin session for a non-police admin')
    H.eq(admin.data.officer, nil, 'no officer')
    H.eq(admin.data.logo, nil, 'no logo')
    H.eq(admin.data.theme.primary, Config.AdminTheme.primary, 'admin theme')
    H.eq(admin.data.theme.text, Config.AdminTheme.text, 'admin text')
    H.eq(admin.data.roles.admin, true, 'admin role')
    H.eq(admin.data.roles.officer, false, 'not an officer')
    H.ok(#admin.data.actions > 10, 'admin actions')
    qbxPlayers[5].PlayerData.job.onduty = false
    H.eq(session(5, { ui = 'admin' }).ok, true, 'admin UI off duty')
    qbxPlayers[5].PlayerData.job.onduty = true
    H.eq(session(1, { ui = 'admin' }).error, 'err.not_admin', 'officers cannot open the Admin UI')
    H.eq(session(10, { ui = 'admin' }).data.officer.citizenid, 'CPT00010', 'admin session carries the officer when they are one')

    local bcsoS = session(7, { ui = 'officer' }).data
    H.eq(bcsoS.logo, nil, 'missing logo file -> no logo')
    H.eq(bcsoS.theme.primary, '#a4161a', 'fallback theme colour')
    local lspdS = session(11, { ui = 'officer' }).data
    H.eq(lspdS.logo.url, 'https://example.com/lspd.png', 'url logo')
    H.eq(lspdS.logo.watermark, false, 'watermark flag')
    H.eq(lspdS.roles.supervisor, false, 'no supervisorGrade -> not a supervisor')

    -- rate limit (4 per second per player)
    local limited = false
    for _ = 1, 6 do
        local r = H.callback('crimson-police:getSession', 2, { ui = 'officer' })
        if r.error == 'err.rate_limited' then limited = true end
    end
    H.ok(limited, 'getSession is rate limited')

    -- notify / notifyMany / push
    H.reset()
    H.eq(CP.Tablet.notify(1, 'success', 'some.key', { n = 2, at = vec3(1.0, 2.0, 3.0) }, { title = 'some.title', duration = 3000 }), true, 'notify')
    local n = lastEvent('crimson-police:client:notify')
    H.eq(n.target, 1, 'notify target')
    H.eq(n.args[1].kind, 'success', 'kind')
    H.eq(n.args[1].key, 'some.key', 'key')
    H.eq(n.args[1].vars.n, 2, 'vars')
    H.eq(getmetatable(n.args[1].vars.at), nil, 'vectors serialised')
    H.eq(n.args[1].title, 'some.title', 'title key')
    H.eq(n.args[1].duration, 3000, 'duration')
    CP.Tablet.notify(1, 'weird', 'k')
    H.eq(lastEvent('crimson-police:client:notify').args[1].kind, 'info', 'unknown kind -> info')
    H.eq(CP.Tablet.notify(0, 'info', 'k'), false, 'console gets no toast')
    H.eq(CP.Tablet.notify(-1, 'info', 'k'), false, 'no broadcast')
    H.eq(CP.Tablet.notify(1, 'info', nil), false, 'key required')
    H.reset()
    H.eq(CP.Tablet.notifyMany({ 1, 1, 2, 'x', 3 }, 'warning', 'k'), 3, 'notifyMany dedupes')
    H.eq(#H.findEvents('crimson-police:client:notify'), 3, 'three toasts')
    H.eq(CP.Tablet.push(1, 'run', { runId = 'r', at = vec3(1.0, 1.0, 1.0) }), true, 'push')
    local p = lastEvent('crimson-police:client:push')
    H.eq(p.args[1], 'run', 'push topic')
    H.eq(p.args[2].runId, 'r', 'push data')
    H.eq(CP.Tablet.push(1, nil, {}), false, 'topic required')

    -- openAdmin
    H.reset()
    H.eq(CP.Tablet.openAdmin(5), true, 'openAdmin (async outside a thread)')
    local oa = lastEvent('crimson-police:client:openAdmin')
    H.eq(oa and oa.target, 5, 'openAdmin target')
    H.eq(oa and oa.args[1].ui, 'admin', 'admin session sent')
    local r1, r2
    local co = coroutine.create(function() r1, r2 = CP.Tablet.openAdmin(1) end)
    coroutine.resume(co)
    H.eq(r1, false, 'non-admin refused')
    H.eq(r2, 'err.not_admin', 'not admin key')
    H.eq(lastEvent('crimson-police:client:notify').args[1].key, 'err.not_admin', 'told why')
    local c1, c2 = CP.Tablet.openAdmin(0)
    H.eq(c1, false, 'console cannot open a UI')
    H.eq(c2, 'err.not_in_game', 'console key')

    -- server:logoFailed (one warning per department)
    H.eq(netEvents['crimson-police:server:logoFailed'], true, 'logoFailed action registered')
    H.reset()
    H.fire('crimson-police:server:logoFailed', 1, 'sast', 'r1')
    local reply = lastEvent('crimson-police:client:actionResult')
    H.eq(reply.args[1], 'r1', 'reply id')
    H.eq(reply.args[2], true, 'logoFailed ok')
    H.eq(countLogs('Department sast: the tablet could not load its logo'), 1, 'warned')
    H.fire('crimson-police:server:logoFailed', 2, { department = 'sast', url = 'x' }, 'r2')
    H.eq(countLogs('Department sast: the tablet could not load its logo'), 1, 'warned once per department')
    H.fire('crimson-police:server:logoFailed', 3, { url = 'https://example.com/lspd.png' }, 'r3')
    H.eq(lastEvent('crimson-police:client:actionResult').args[2], true, 'matched by url')
    H.eq(countLogs('Department lspd: the tablet could not load its logo'), 1, 'lspd warned')
    H.fire('crimson-police:server:logoFailed', 4, 'nope', 'r4')
    H.eq(lastEvent('crimson-police:client:actionResult').args[3], 'err.unknown_department', 'unknown department')
    H.fire('crimson-police:server:logoFailed', 5, 12, 'r5')
    H.eq(lastEvent('crimson-police:client:actionResult').args[3], 'err.invalid_payload', 'bad payload')
end

-- ════════════════════════════════════════════════════════════════════════════
-- CP.Access.onLost (fired from the qbx events)
-- ════════════════════════════════════════════════════════════════════════════
do
    local lost = {}
    CP.Access.onLost(function(src, reason) lost[#lost + 1] = { src = src, reason = reason } end)
    local function lastLost() return lost[#lost] end

    qbxPlayers[1].PlayerData.job.onduty = false
    TriggerEvent('QBCore:Server:SetDuty', 1, false)
    H.eq(lastLost() and lastLost().src, 1, 'off duty fires onLost')
    H.eq(lastLost() and lastLost().reason, 'off_duty', 'off_duty')
    qbxPlayers[1].PlayerData.job.onduty = true
    TriggerEvent('QBCore:Server:SetDuty', 1, true)
    H.eq(#lost, 1, 'going on duty fires nothing')

    qbxPlayers[2].PlayerData.job = { name = 'sast', label = 'SAST', onduty = true, grade = { name = 'Trooper', level = 1 } }
    TriggerEvent('QBCore:Server:OnJobUpdate', 2, qbxPlayers[2].PlayerData.job)
    H.eq(lastLost().src, 2, 'job switch fires onLost')
    H.eq(lastLost().reason, 'job_change', 'fib -> sast is a job change')
    H.eq(H.sql('SELECT department FROM cp_officers WHERE citizenid = ?', { 'CPT00002' })[1].department, 'sast', 'row refreshed on job change')
    TriggerEvent('QBCore:Server:OnJobUpdate', 2, qbxPlayers[2].PlayerData.job)
    H.eq(#lost, 2, 'same job again: nothing (grade change or definition edit)')

    qbxPlayers[7].PlayerData.job = { name = 'unemployed', label = 'Civilian', onduty = false, grade = { name = 'Freelancer', level = 0 } }
    TriggerEvent('qbx_core:server:onGroupUpdate', 7, 'bcso', nil)
    H.eq(lastLost().src, 7, 'removing the active job fires onLost')
    H.eq(lastLost().reason, 'job_change', 'job_change')

    TriggerEvent('QBCore:Server:SetDuty', 4, false)
    H.eq(#lost, 3, 'civilians fire nothing')

    TriggerEvent('QBCore:Server:OnPlayerUnload', 11)
    qbxPlayers[11].PlayerData.job.onduty = false
    TriggerEvent('QBCore:Server:SetDuty', 11, false)
    H.eq(#lost, 3, 'unloaded characters are forgotten until they load again')
    TriggerEvent('QBCore:Server:PlayerLoaded', qbxPlayers[11])
    qbxPlayers[11].PlayerData.job.onduty = true
    TriggerEvent('QBCore:Server:SetDuty', 11, true)
    qbxPlayers[11].PlayerData.job.onduty = false
    TriggerEvent('QBCore:Server:SetDuty', 11, false)
    H.eq(lastLost().src, 11, 'known again after PlayerLoaded')

    -- a lookup racing the job-switch event must not hide the signal
    qbxPlayers[10].PlayerData.job = { name = 'fib', label = 'FIB', onduty = true, grade = { name = 'Agent', level = 1 } }
    H.ok(CP.Access.getOfficer(10) ~= nil, 'lookup between the switch and its event')
    TriggerEvent('QBCore:Server:OnJobUpdate', 10, qbxPlayers[10].PlayerData.job)
    H.eq(lastLost().src, 10, 'job change still reported')
    H.eq(lastLost().reason, 'job_change', 'job_change after a racing lookup')

    H.eq(CP.Access.suspend('CPT00003', 2, 0, 'auto'), true, 'suspend an online officer')
    H.eq(lastLost().src, 3, 'a new suspension fires onLost')
    H.eq(lastLost().reason, 'suspended', 'suspended')
    CP.Access.suspend('CPT00003', 0, 0, 'lift')
end

print = realPrint

-- ════════════════════════════════════════════════════════════════════════════
-- Client side: CP.Qbx, CP.Ambulance, CP.Access and CP.Tablet
-- ════════════════════════════════════════════════════════════════════════════
H.handlers, H.callbacks, H.commands, H.events = {}, {}, {}, {}
CP, Config = nil, nil
H.boot({ side = 'client' })
Config.Debug = true
_G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, ' ')
    if line:find('[crimson-police', 1, true) then logs[#logs + 1] = line return end
    realPrint(line)
end
_G.GetResourceState = function(name) return stopped[name] and 'stopped' or 'started' end
local clientExports = {}
getmetatable(exports).__call = function(_, name, fn) clientExports[name] = fn end

local nui, focus, nuiCb, keymaps = {}, {}, {}, {}
_G.SendNUIMessage = function(m) nui[#nui + 1] = m end
_G.SetNuiFocus = function(a, b) focus[#focus + 1] = { a, b } end
_G.RegisterNUICallback = function(name, fn) nuiCb[name] = fn end
_G.RegisterKeyMapping = function(cmd, desc, dev, key) keymaps[#keymaps + 1] = { cmd = cmd, desc = desc, dev = dev, key = key } end
_G.PlayerPedId = function() return 42 end
_G.GetEntityCoords = function() return vec3(1.0, 2.0, 3.0) end
_G.IsModelInCdimage = function() return true end
_G.RequestModel = function() end
_G.HasModelLoaded = function() return true end
_G.SetModelAsNoLongerNeeded = function() end
local objects, nextObj, created = {}, 1000, 0
_G.CreateObject = function(model, x, y, z, net)
    nextObj = nextObj + 1
    created = created + 1
    objects[nextObj] = { model = model, net = net }
    return nextObj
end
_G.DoesEntityExist = function(e) return objects[e] ~= nil end
_G.DeleteEntity = function(e) objects[e] = nil end
_G.DetachEntity = function() end
_G.SetEntityAsMissionEntity = function() end
_G.SetEntityCollision = function() end
local attached = {}
_G.AttachEntityToEntity = function(obj, ped, bone) attached[#attached + 1] = { obj = obj, ped = ped, bone = bone } end
_G.GetPedBoneIndex = function(_, bone) return bone end
_G.RequestAnimDict = function() end
_G.HasAnimDictLoaded = function() return true end
_G.RemoveAnimDict = function() end
local anims, playing = {}, false
_G.TaskPlayAnim = function(_, dict, clip, _, _, _, flag) anims[#anims + 1] = { dict = dict, clip = clip, flag = flag } playing = true end
_G.IsEntityPlayingAnim = function() return playing end
_G.StopAnimTask = function() playing = false end
_G.IsEntityDead = function() return false end
_G.LocalPlayer = { state = { isLoggedIn = true } }
_G.PlayerId = function() return 0 end
_G.GetPlayerServerId = function() return 7 end
local bagHandlers = {}
_G.AddStateBagChangeHandler = function(key, bag, fn) bagHandlers[#bagHandlers + 1] = { key = key, bag = bag, fn = fn } end
local progressActive, progressCancels = false, 0
lib.progressActive = function() return progressActive end
lib.cancelProgress = function()
    if not progressActive then error('No progress bar is active') end
    progressActive = false
    progressCancels = progressCancels + 1
end
-- a Crimson-Police progress bar (blocks, npc cuff): goes through this resource's lib.progressBar
local cpBarDone
lib.progressBar = function()
    progressActive = true
    while progressActive do Wait(50) end
    return false
end
_G.GetStreetNameAtCoord = function() return 777, 0 end
_G.GetStreetNameFromHashKey = function(h) if h == 777 then return 'Main St' end return '' end

local clientPD = { job = { name = 'sast', onduty = true, grade = { level = 3, name = 'Sergeant' } } }
H.exportsMock.qbx_core = { GetPlayerData = function() return clientPD end }

local function officerSession(ui)
    return {
        ok = true,
        data = {
            ui = ui, title = 'Crimson-Police',
            roles = { officer = true, supervisor = true, admin = false },
            officer = { citizenid = 'CPT00001', name = 'John Doe', department = 'sast', departmentLabel = 'San Andreas State Troopers',
                departmentShort = 'SAST', rank = 'Sergeant', callsign = '2L-14', gradeLevel = 3 },
            theme = { primary = '#1f4e8c', accent = '#f2c230', background = '#0d1522', surface = '#152235', text = '#ffffff' },
            logo = { url = 'https://cfx-nui-Crimson-Police/logos/sast.png', watermark = true, opacity = 0.08, size = 0.6, grayscale = false },
            actions = {}, locale = {}, config = {}, serverTime = 1,
        },
    }
end
local sessionReply = { officer = officerSession('officer'), supervisor = officerSession('supervisor') }
local callbackCalls = {}
lib.callback.await = function(name, _, args)
    callbackCalls[#callbackCalls + 1] = { name = name, args = args }
    if name == 'crimson-police:getSession' then return sessionReply[(args and args.ui) or 'officer'] end
    return { ok = true, data = { echo = args } }
end

local function lastNui(kind)
    for i = #nui, 1, -1 do if nui[i].type == kind then return nui[i] end end
    return nil
end
local function countNui(kind)
    local n = 0
    for _, m in ipairs(nui) do if m.type == kind then n = n + 1 end end
    return n
end
local function propCount()
    local n = 0
    for _ in pairs(objects) do n = n + 1 end
    return n
end
local function tick(ms) H.advance(ms or 600, 50) end

H.load('modules/integrations/qbx/client.lua')
H.load('modules/integrations/sc_ambulance/client.lua')
H.load('modules/access/client.lua')
H.load('modules/tablet/client.lua')

-- CP.Qbx (client)
do
    H.eq(CP.Qbx.getPlayerData().job.name, 'sast', 'getPlayerData')
    LocalPlayer.state.isLoggedIn = false
    H.eq(CP.Qbx.getPlayerData().job, nil, 'logged out -> {}')
    LocalPlayer.state.isLoggedIn = true
    local jobs, duties, unloads, loads = {}, {}, 0, 0
    CP.Qbx.onJobUpdate(function(job) jobs[#jobs + 1] = job end)
    CP.Qbx.onDutyChange(function(d) duties[#duties + 1] = d end)
    CP.Qbx.onUnload(function() unloads = unloads + 1 end)
    CP.Qbx.onLoaded(function() loads = loads + 1 end)
    H.fire('QBCore:Client:OnJobUpdate', nil, { name = 'fib', onduty = true })
    H.eq(jobs[#jobs].name, 'fib', 'client job update')
    H.fire('qbx_core:client:onGroupUpdate', nil, 'sast', nil)
    tick(200)
    H.eq(jobs[#jobs].name, 'sast', 'group update re-reads PlayerData.job')
    H.fire('QBCore:Client:SetDuty', nil, 'yes')
    H.eq(duties[#duties], false, 'only true is on duty')
    H.fire('QBCore:Client:OnPlayerUnload', nil)
    H.fire('QBCore:Client:OnPlayerLoaded', nil)
    H.eq(unloads, 1, 'unload listener')
    H.eq(loads, 1, 'loaded listener')
    tick(2000)   -- let the tablet's debounced theme refreshes from these events run
end

-- CP.Ambulance (client)
do
    H.reset()
    H.eq(CP.Ambulance.sendEMSRequest(), true, 'EMS request sent')
    local ev = H.findEvents('hospital:server:EMSDownAlert')[1]
    H.eq(ev and ev.args[1], 'Main St', 'street name sent')
    H.eq(CP.Ambulance.sendEMSRequest(), false, 'duplicate within 5 s refused')
    H.clockMs = H.clockMs + 5100
    H.eq(CP.Ambulance.sendEMSRequest(), true, 'again after 5 s')
    stopped['sc-ambulance'] = true
    H.clockMs = H.clockMs + 5100
    H.eq(CP.Ambulance.sendEMSRequest(), false, 'sc-ambulance stopped')
    stopped['sc-ambulance'] = nil
    H.eq(#H.findEvents('hospital:server:EMSDownAlert'), 2, 'two requests in total')
    -- Crimson-Arena's value (no source): sc-ambulance would drop it, and the debounce is not used up
    H.clockMs = H.clockMs + 5100
    LocalPlayer.state.crimsonArena = { active = true, matchId = 'm1' }
    H.eq(CP.Ambulance.sendEMSRequest(), false, 'no EMS request while Crimson-Arena owns the player')
    LocalPlayer.state.crimsonArena = { active = true, source = 'crimson-police' }
    H.eq(CP.Ambulance.sendEMSRequest(), true, 'our own flag does not block the request (downed clears it first anyway)')
    LocalPlayer.state.crimsonArena = nil
    H.eq(#H.findEvents('hospital:server:EMSDownAlert'), 3, 'three requests in total')
end

-- CP.Tablet (client)
do
    local T = CP.Tablet
    H.ok(H.commands.CrimsonPolice ~= nil, '/CrimsonPolice registered')
    H.ok(H.commands.crimsonpolice_tablet ~= nil, 'key mapping command registered')
    H.eq(keymaps[1] and keymaps[1].cmd, 'crimsonpolice_tablet', 'key mapping name uses the crimsonpolice_ prefix')
    H.eq(keymaps[1] and keymaps[1].key, '', "Config.Tablet.keybind '' = unbound by default")
    H.eq(keymaps[1] and keymaps[1].dev, 'keyboard', 'keyboard mapping')

    -- theme at login (silent session fetch)
    local themeMsg = lastNui('theme')
    H.ok(themeMsg ~= nil, 'theme sent after load')
    H.eq(themeMsg and themeMsg.theme.primary, '#1f4e8c', 'department theme')
    H.eq(type(themeMsg and themeMsg.locale), 'table', 'locale sent with the theme')
    local silentCall
    for _, c in ipairs(callbackCalls) do if c.args and c.args.silent then silentCall = c end end
    H.ok(silentCall ~= nil and silentCall.args.ui == 'officer', 'theme fetch is a silent officer session')
    H.eq(CP.Access.current().departmentShort, 'SAST', 'access client keeps the officer')

    -- open with the command, prop and animation, close via NUI
    H.clockMs = H.clockMs + 1000
    H.commands.CrimsonPolice.fn()
    H.eq(T.isOpen(), true, 'opened')
    local open = lastNui('open')
    H.eq(open.ui, 'officer', 'officer UI')
    H.eq(open.session.officer.callsign, '2L-14', 'session sent')
    H.eq(focus[#focus][1], true, 'focus taken')
    H.eq(focus[#focus][2], true, 'cursor')
    H.eq(propCount(), 1, 'tablet prop created')
    H.eq(objects[nextObj].model, joaat('prop_cs_tablet'), 'Config.Tablet.prop')
    H.eq(objects[nextObj].net, false, 'the prop is a local object (CRIMSON_ARENA rule 8)')
    H.eq(attached[#attached].bone, 60309, 'attached to the hand bone')
    H.eq(anims[#anims].dict, 'amb@code_human_in_bus_passenger_idles@female@tablet@base', 'tablet animation')
    H.eq(anims[#anims].flag, 49, 'upper body loop')
    local animCount = #anims
    tick(1100)
    H.eq(#anims, animCount, 'animation still playing: not restarted')
    playing = false
    tick(1100)
    H.eq(#anims, animCount + 1, 'animation re-applied while open')
    H.eq(CP.Access.current().callsign, '2L-14', 'access current()')
    H.eq(CP.Access.department().key, 'sast', 'access department()')
    H.eq(CP.Access.roles().supervisor, true, 'access roles()')

    local closeReply
    nuiCb.close({}, function(r) closeReply = r end)
    H.eq(closeReply.ok, true, 'close reply')
    H.eq(T.isOpen(), false, 'closed')
    H.eq(focus[#focus][1], false, 'focus released')
    H.eq(lastNui('close') ~= nil, true, 'close message')
    H.eq(propCount(), 0, 'prop removed on close')
    H.eq(playing, false, 'animation stopped')
    local focusCalls = #focus
    H.eq(T.close(), false, 'closing a closed UI')
    H.eq(#focus, focusCalls, 'closing a closed UI never touches the NUI focus')
    tick(1100)

    -- the command toggles
    H.clockMs = H.clockMs + 1000
    H.commands.crimsonpolice_tablet.fn()
    H.eq(T.isOpen(), true, 'key mapping opens')
    H.clockMs = H.clockMs + 1000
    H.commands.crimsonpolice_tablet.fn()
    H.eq(T.isOpen(), false, 'key mapping closes again')
    tick(1100)

    -- refused open -> toast with the translated error
    sessionReply.officer = { ok = false, error = 'err.not_on_duty' }
    H.clockMs = H.clockMs + 1000
    H.commands.CrimsonPolice.fn()
    H.eq(T.isOpen(), false, 'refused')
    local toast = lastNui('notify')
    H.eq(toast.notification.kind, 'error', 'error toast')
    H.eq(toast.notification.text, CP.L('err.not_on_duty'), 'translated error')
    H.eq(propCount(), 0, 'no prop when refused')
    sessionReply.officer = officerSession('officer')

    -- server toasts
    H.fire('crimson-police:client:notify', nil, { kind = 'success', key = 'some.key', vars = { n = 2 }, title = 'some.title', duration = 1234 })
    toast = lastNui('notify')
    H.eq(toast.notification.text, CP.L('some.key', { n = 2 }), 'server toast translated')
    H.eq(toast.notification.title, CP.L('some.title'), 'title translated')
    H.eq(toast.notification.duration, 1234, 'duration')
    local before = countNui('notify')
    H.fire('crimson-police:client:notify', nil, { kind = 'info' })
    H.fire('crimson-police:client:notify', nil, 'junk')
    H.eq(countNui('notify'), before, 'invalid toasts ignored')
    H.fire('crimson-police:client:notify', nil, { kind = 'bogus', key = 'k' })
    H.eq(lastNui('notify').notification.kind, 'info', 'unknown kind -> info')
    H.eq(lastNui('notify').notification.duration, 5000, 'default duration')
    T.notify('warning', 'plain text')
    H.eq(lastNui('notify').notification.duration, 7000, 'warning default duration')

    -- push, hud, result, overlay
    H.fire('crimson-police:client:push', nil, 'run', { runId = 'x' })
    H.eq(lastNui('push').topic, 'run', 'push topic')
    H.eq(lastNui('push').data.runId, 'x', 'push data')
    T.hud({ runId = 'r1', phase = 'route', timer = { remaining = 5, paused = false }, test = false })
    H.eq(lastNui('hud').hud.runId, 'r1', 'hud')
    T.hud({ phase = 'objectives' })
    H.eq(lastNui('hud').hud.runId, 'r1', 'hud merged')
    H.eq(lastNui('hud').hud.phase, 'objectives', 'hud patched')
    T.hud({ timer = false, test = false })
    H.eq(lastNui('hud').hud.timer, nil, 'false clears a nullable field')
    H.eq(lastNui('hud').hud.test, false, 'false kept for booleans')
    T.hud(nil)
    H.eq(lastNui('hud').hud, nil, 'hud(nil) hides it')
    T.hud({ runId = 'r2' })
    H.eq(lastNui('hud').hud.phase, nil, 'fresh state after hud(nil)')
    T.hud(nil)
    T.result({ runId = 'r1', result = 'completed' })
    H.eq(lastNui('result').result.result, 'completed', 'result')
    T.overlay({ kind = 'fade', text = 'Picked up' })
    H.eq(lastNui('overlay').overlay.kind, 'fade', 'overlay')
    T.overlay(nil)
    H.eq(lastNui('overlay').overlay, nil, 'overlay hidden')
    T.send({ type = 'custom', at = vec3(1.0, 2.0, 3.0) })
    H.eq(getmetatable(nui[#nui].at), nil, 'send serialises vectors')

    -- ready resends the theme and the HUD
    T.hud({ runId = 'r3' })
    local readyReply
    nuiCb.ready({}, function(r) readyReply = r end)
    H.eq(readyReply.ok, true, 'ready reply')
    H.eq(nui[#nui].type, 'hud', 'ready resends the hud')
    H.eq(nui[#nui - 1].type, 'theme', 'ready resends the theme')
    T.hud(nil)

    -- NUI client actions
    T.registerClientAction('echo', function(payload) return true, { got = payload } end)
    T.registerClientAction('refuse', function() return false, 'err.refused' end)
    T.registerClientAction('boom', function() error('boom') end)
    local reply
    nuiCb.client({ name = 'echo', payload = 5 }, function(r) reply = r end)
    H.eq(reply.ok, true, 'client action ok')
    H.eq(reply.data.got, 5, 'client action data')
    nuiCb.client({ name = 'refuse' }, function(r) reply = r end)
    H.eq(reply.error, 'err.refused', 'client action error key')
    nuiCb.client({ name = 'boom' }, function(r) reply = r end)
    H.eq(reply.error, 'err.internal', 'client action crash contained')
    nuiCb.client({ name = 'missing' }, function(r) reply = r end)
    H.eq(reply.error, 'err.unknown_action', 'unknown client action')
    nuiCb.client({ name = 'bad name!' }, function(r) reply = r end)
    H.eq(reply.error, 'err.invalid_payload', 'invalid name')
    nuiCb.client('junk', function(r) reply = r end)
    H.eq(reply.error, 'err.invalid_payload', 'invalid body')

    -- built-in logoFailed -> server:logoFailed
    H.reset()
    reply = nil
    nuiCb.client({ name = 'logoFailed', payload = { department = 'sast', url = 'u' } }, function(r) reply = r end)
    local sent = H.findEvents('crimson-police:server:logoFailed')[1]
    H.ok(sent ~= nil, 'forwarded to the server')
    H.eq(sent and sent.args[1].department, 'sast', 'payload forwarded')
    H.fire('crimson-police:client:actionResult', nil, sent.args[2], true, nil)
    tick(100)
    H.eq(reply and reply.ok, true, 'logoFailed reply')

    -- request / action bridge
    nuiCb.request({ name = 'getBoard', args = { period = 'weekly' } }, function(r) reply = r end)
    H.eq(callbackCalls[#callbackCalls].name, 'crimson-police:getBoard', 'request -> ox_lib callback')
    H.eq(reply.data.echo.period, 'weekly', 'request reply')
    nuiCb.request({ name = 'getProfile', args = 'CPT00002' }, function(r) reply = r end)
    H.eq(callbackCalls[#callbackCalls].args, 'CPT00002', 'non-table args passed through')
    nuiCb.request({ name = nil }, function(r) reply = r end)
    H.eq(reply.error, 'err.invalid_payload', 'request needs a name')
    nuiCb.action({ name = 'acceptType', payload = 'patrol' }, function(r) reply = r end)
    H.eq(reply.error, 'err.invalid_payload', 'actions must be server:*')
    H.reset()
    reply = nil
    nuiCb.action({ name = 'server:acceptType', payload = 'patrol' }, function(r) reply = r end)
    local act = H.findEvents('crimson-police:server:acceptType')[1]
    H.eq(act and act.args[1], 'patrol', 'action payload')
    H.fire('crimson-police:client:actionResult', nil, act.args[2], false, 'err.on_call')
    tick(100)
    H.eq(reply and reply.error, 'err.on_call', 'action error reply')

    -- switchUi
    H.clockMs = H.clockMs + 1000
    H.commands.CrimsonPolice.fn()
    H.eq(propCount(), 1, 'open with prop')
    nuiCb.switchUi({ ui = 'supervisor' }, function(r) reply = r end)
    H.eq(reply.ok, true, 'switchUi ok')
    H.eq(reply.data.ui, 'supervisor', 'switchUi returns the session')
    H.eq(lastNui('open').ui, 'supervisor', 're-opened as supervisor')
    H.eq(propCount(), 1, 'prop kept when switching officer <-> supervisor')
    H.eq(created, 3, 'no second prop created')
    nuiCb.switchUi({ ui = 'boss' }, function(r) reply = r end)
    H.eq(reply.error, 'err.invalid_ui', 'switchUi invalid ui')
    sessionReply.admin = { ok = false, error = 'err.not_admin' }
    nuiCb.switchUi({ ui = 'admin' }, function(r) reply = r end)
    H.eq(reply.error, 'err.not_admin', 'switchUi refused')
    H.eq(lastNui('open').ui, 'supervisor', 'still supervisor')

    -- duty loss closes the Officer/Supervisor UI
    H.fire('QBCore:Client:SetDuty', nil, false)
    H.eq(T.isOpen(), false, 'closed on duty loss')
    H.eq(propCount(), 0, 'prop removed')
    H.eq(CP.Access.current(), nil, 'access cleared off duty')
    tick(2000)

    -- a job switch away from the opening job closes it
    H.clockMs = H.clockMs + 1000
    H.commands.CrimsonPolice.fn()
    H.eq(T.isOpen(), true, 'open again')
    H.fire('QBCore:Client:OnJobUpdate', nil, { name = 'sast', onduty = true, grade = { level = 4 } })
    H.eq(T.isOpen(), true, 'grade change keeps it open')
    H.fire('QBCore:Client:OnJobUpdate', nil, { name = 'fib', onduty = true })
    H.eq(T.isOpen(), false, 'job switch closes it')
    tick(2000)

    -- removing the active job (only onGroupUpdate fires)
    H.clockMs = H.clockMs + 1000
    H.commands.CrimsonPolice.fn()
    clientPD.job = { name = 'unemployed', onduty = false }
    H.fire('qbx_core:client:onGroupUpdate', nil, 'sast', nil)
    tick(200)
    H.eq(T.isOpen(), false, 'job removal closes it')
    clientPD.job = { name = 'sast', onduty = true, grade = { level = 3, name = 'Sergeant' } }
    tick(2000)

    -- Admin UI: opened by the server, no prop, survives duty loss, closes on unload
    H.fire('crimson-police:client:openAdmin', nil, { ui = 'admin', title = 'Crimson-Police', roles = { admin = true }, theme = {}, actions = {} })
    H.eq(T.isOpen(), true, 'admin UI open')
    H.eq(lastNui('open').ui, 'admin', 'admin ui')
    H.eq(propCount(), 0, 'no prop for the Admin UI')
    H.fire('crimson-police:client:openAdmin', nil, { ui = 'officer' })
    H.eq(lastNui('open').ui, 'admin', 'openAdmin only accepts admin sessions')
    H.fire('QBCore:Client:SetDuty', nil, false)
    H.eq(T.isOpen(), true, 'admin UI stays open off duty')
    T.hud({ runId = 'r9' })
    H.fire('QBCore:Client:OnPlayerUnload', nil)
    H.eq(T.isOpen(), false, 'unload closes every UI')
    H.eq(lastNui('hud').hud, nil, 'unload clears the HUD')
    H.eq(lastNui('theme').theme.primary, '#a4161a', 'default theme after unload')
    H.eq(CP.Access.current(), nil, 'access cleared on unload')
    tick(2000)
    -- a character unload with no Crimson-Police UI open leaves the NUI focus alone (another resource's
    -- UI, e.g. the character selection, may hold it)
    local focusBeforeUnload = #focus
    H.fire('QBCore:Client:OnPlayerUnload', nil)
    tick(100)
    H.eq(#focus, focusBeforeUnload, 'unload with the tablet closed never releases the focus')
    tick(2000)

    -- exports: OpenTablet and the ox_inventory item
    H.clockMs = H.clockMs + 1000
    H.eq(clientExports.OpenTablet(), true, 'OpenTablet export')
    H.eq(T.isOpen(), true, 'OpenTablet opens through getSession')
    T.close()
    tick(1100)
    clientExports.useTablet({ name = 'crimson_police_tablet' })
    H.eq(T.isOpen(), false, 'item ignored while Config.Tablet.item is false')
    Config.Tablet.item = 'crimson_police_tablet'
    clientExports.useTablet({ name = 'other_item' })
    H.eq(T.isOpen(), false, 'other items ignored')
    clientExports.useTablet({ name = 'crimson_police_tablet' }, 3)
    H.eq(T.isOpen(), true, 'tablet item opens the Officer UI')

    -- Crimson-Arena (CRIMSON_ARENA rule 8)
    H.eq(#bagHandlers, 1, 'one crimsonArena change handler')
    H.eq(bagHandlers[1] and bagHandlers[1].key, 'crimsonArena', 'handler key')
    H.eq(bagHandlers[1] and bagHandlers[1].bag, 'player:7', 'only the local player bag')
    local arenaHandler = bagHandlers[1].fn
    arenaHandler('player:7', 'crimsonArena', { active = true, source = 'crimson-police' })
    arenaHandler('player:7', 'crimsonArena', nil)
    arenaHandler('player:7', 'crimsonArena', { active = false, matchId = 'm0' })
    tick(100)
    H.eq(T.isOpen(), true, 'our own flag, nil and inactive values keep the tablet open')
    T.hud({ runId = 'r10', phase = 'objectives' })
    T.overlay({ kind = 'fade', text = 'x' })
    CP.Runs = { current = function() return { id = 'r10' } end }
    H.eq(T.cpProgressActive(), false, 'no Crimson-Police progress bar yet')
    CreateThread(function() cpBarDone = lib.progressBar({ duration = 5000 }) end)
    H.eq(T.cpProgressActive(), true, 'lib.progressBar is counted as a Crimson-Police bar')
    local focusBefore = #focus
    arenaHandler('player:7', 'crimsonArena', { active = true, matchId = 'm1' })
    H.eq(T.isOpen(), true, 'the change handler only queues the work')
    tick(100)
    H.eq(T.isOpen(), false, 'Crimson-Arena placing the player closes the tablet')
    H.eq(propCount(), 0, 'prop deleted')
    H.eq(playing, false, 'animation stopped')
    H.eq(#focus, focusBefore + 1, 'the open UI released its own focus once')
    H.eq(focus[#focus][1], false, 'focus released')
    H.eq(lastNui('hud').hud, nil, 'HUD hidden')
    H.eq(lastNui('overlay').overlay, nil, 'overlay hidden')
    H.eq(progressCancels, 1, "the Crimson-Police progress bar is cancelled")
    tick(100)
    H.eq(cpBarDone, false, 'the cancelled bar returned false')
    H.eq(T.cpProgressActive(), false, 'the bar is no longer counted once it returned')
    -- another resource's progress bar (lib.progressActive() is resource-wide) is never cancelled,
    -- even during a Crimson-Police run
    progressActive = true
    arenaHandler('player:7', 'crimsonArena', { active = true, matchId = 'm1' })
    tick(100)
    H.eq(progressCancels, 1, "a foreign resource's progress bar is left alone")
    H.eq(progressActive, true, 'the foreign bar still runs')
    progressActive = false

    -- nothing opens while the local value is foreign
    LocalPlayer.state.crimsonArena = { active = true, matchId = 'm1' }
    local sessionCalls = #callbackCalls
    H.clockMs = H.clockMs + 1000
    H.commands.CrimsonPolice.fn()
    H.eq(T.isOpen(), false, 'command refused in the arena')
    H.eq(lastNui('notify').notification.text, CP.L('err.in_arena'), 'err.in_arena toast')
    H.clockMs = H.clockMs + 1000
    H.commands.crimsonpolice_tablet.fn()
    H.eq(T.isOpen(), false, 'key mapping refused in the arena')
    clientExports.OpenTablet()
    H.eq(T.isOpen(), false, 'OpenTablet refused in the arena')
    clientExports.useTablet({ name = 'crimson_police_tablet' })
    H.eq(T.isOpen(), false, 'tablet item refused in the arena')
    H.eq(#callbackCalls, sessionCalls, 'no session is even requested')
    nuiCb.switchUi({ ui = 'officer' }, function(r) reply = r end)
    H.eq(reply.error, 'err.in_arena', 'switchUi refused in the arena')
    H.fire('crimson-police:client:openAdmin', nil, { ui = 'admin', title = 'Crimson-Police', roles = { admin = true }, theme = {}, actions = {} })
    H.eq(T.isOpen(), false, 'Admin UI refused in the arena')
    focusBefore = #focus
    arenaHandler('player:7', 'crimsonArena', { active = true, matchId = 'm1' })
    tick(100)
    H.eq(#focus, focusBefore, 'a foreign value with nothing open never touches the focus')
    H.eq(progressCancels, 1, 'no progress bar running -> nothing cancelled')

    -- placed while the session request was on its way
    LocalPlayer.state.crimsonArena = nil
    local realAwait = lib.callback.await
    lib.callback.await = function(name, delay, args)
        LocalPlayer.state.crimsonArena = { active = true, matchId = 'm2' }
        return realAwait(name, delay, args)
    end
    H.clockMs = H.clockMs + 1000
    H.commands.CrimsonPolice.fn()
    H.eq(T.isOpen(), false, 'a session that arrives after the placement does not open')
    lib.callback.await = realAwait

    -- back from the arena: the tablet opens again
    LocalPlayer.state.crimsonArena = nil
    CP.Runs = nil
    H.clockMs = H.clockMs + 1000
    H.commands.CrimsonPolice.fn()
    H.eq(T.isOpen(), true, 'opens again after leaving the arena')
    H.eq(propCount(), 1, 'with its prop')

    -- resource stop cleans up
    TriggerEvent('onResourceStop', 'Crimson-Police')
    H.eq(focus[#focus][1], false, 'focus released on stop')
    H.eq(propCount(), 0, 'prop removed on stop')
    tick(1100)
end

print = realPrint
return H
