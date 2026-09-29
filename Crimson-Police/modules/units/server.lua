-- CP.Units (server): units of 2-4 officers from any department.

CP.Units = CP.Units or {}
local Units = CP.Units
local TAG = 'units'

local INVITE_TTL = 120        -- seconds an invite stays open before it expires
local SWEEP_MS = 2000         -- invite expiry / lock safety-net sweep
local LOCK_GRACE = 30         -- seconds a lock is kept without any member on a run before the sweep lifts it
local INVITE_TOAST_MS = 10000

local units = {}              -- id -> unit
local unitIdBySrc = {}        -- src -> unit id
local nextId = 0

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function ToSrc(v)
    local n = tonumber(v)
    if not n then return nil end
    n = math.tointeger(n)
    if not n or n <= 0 then return nil end
    return n
end

local function Call(modName, fnName, ...)
    local m = CP[modName]
    if type(m) ~= 'table' or type(m[fnName]) ~= 'function' then return false end
    local res = table.pack(pcall(m[fnName], ...))
    if not res[1] then
        CP.err(TAG, 'CP.%s.%s failed: %s', modName, fnName, tostring(res[2]))
        return false
    end
    return true, table.unpack(res, 2, res.n)
end

local function MaxSize()
    local n = math.tointeger(tonumber(Config.Limits and Config.Limits.maxUnitSize) or 4) or 4
    if n < 2 then n = 2 end
    return n
end

local function GetOfficer(src)
    if not (CP.Access and CP.Access.getOfficer) then return nil, 'err.not_police' end
    local ok, officer, errKey = Call('Access', 'getOfficer', src)
    if not ok then return nil, 'err.internal' end
    return officer, errKey
end

-- The run src is an active participant of, if any.
local function RunOf(src)
    local ok, run = Call('Runs', 'getBySrc', src)
    if ok and type(run) == 'table' then return run end
    return nil
end

local function OnRun(src)
    if RunOf(src) then return true end
    local ok, on = Call('Runs', 'isOnMission', src)
    return ok and on == true
end

-- A normal run (the kind a unit accepts): not a Cross-Department Mission, not a test run.
local function IsUnitRun(run)
    return type(run) == 'table' and run.operationId == nil and run.test == nil
end

local function InArena(src)
    local ok, v = Call('Alerts', 'inArena', src)
    return ok and v == true
end

local function Notify(src, kind, key, vars, opts)
    Call('Tablet', 'notify', src, kind, key, vars, opts)
end

local function Push(src, topic, data)
    Call('Tablet', 'push', src, topic, data)
end

local function InfoOf(officer)
    return {
        name = CP.U.clip(officer.name or '?', 64),
        callsign = officer.callsign and CP.U.clip(officer.callsign, 32) or nil,
        rank = officer.rank or '',
        departmentShort = officer.departmentShort or '',
        department = officer.department,
    }
end

local function IndexOf(list, v)
    for i = 1, #list do
        if list[i] == v then return i end
    end
    return nil
end

local function Resolve(ref)
    if type(ref) == 'table' then
        local id = ref.id
        if id and units[id] == ref then return ref end
        return nil
    end
    local id = math.tointeger(tonumber(ref))
    return id and units[id] or nil
end

local function PendingCount(unit, now)
    local n = 0
    for _, exp in pairs(unit.invites) do
        if exp > now then n = n + 1 end
    end
    return n
end

-- Push 'unit' to every member and invitee (plus extra srcs), 'board' to members. invitedSrc (optional)
-- gets its 'unit' push with invited = true (the units client plays the invite cue on it).
local function PushUnit(unit, extra, invitedSrc)
    local sent = {}
    local id = unit and unit.id or false
    if unit then
        for _, m in ipairs(unit.members) do
            if not sent[m] then
                sent[m] = true
                Push(m, 'unit', { unitId = id })
                Push(m, 'board', { unit = true })
            end
        end
        for target in pairs(unit.invites) do
            if not sent[target] then
                sent[target] = true
                Push(target, 'unit', { unitId = id, invited = target == invitedSrc or nil })
            end
        end
    end
    if type(extra) == 'table' then
        for _, s in ipairs(extra) do
            if not sent[s] then
                sent[s] = true
                Push(s, 'unit', { unitId = false })
                Push(s, 'board', { unit = true })
            end
        end
    end
end

local function NewUnit(leaderSrc, leaderInfo)
    nextId = nextId + 1
    local unit = {
        id = nextId,
        leader = leaderSrc,
        members = { leaderSrc },
        invites = {},
        inviteFrom = {},
        info = { [leaderSrc] = leaderInfo },
        joinedAt = { [leaderSrc] = os.time() },
        locked = false,
        lockedAt = nil,
        createdAt = os.time(),
    }
    units[unit.id] = unit
    unitIdBySrc[leaderSrc] = unit.id
    CP.log(TAG, 'unit %d formed by %d', unit.id, leaderSrc)
    return unit
end

-- Withdraw every pending invite of the unit (invitees are told unless silent). Returns the invitees.
local function WithdrawInvites(unit, silent)
    local out = {}
    for target in pairs(unit.invites) do out[#out + 1] = target end
    table.sort(out)
    for _, target in ipairs(out) do
        local from = unit.inviteFrom[target]
        unit.invites[target] = nil
        unit.inviteFrom[target] = nil
        if not silent then
            Notify(target, 'info', 'unit.invite_withdrawn', { name = from and from.name or '?' })
        end
    end
    return out
end

-- opts = { silentMembers = bool, silentInvitees = bool }
local function Dissolve(unit, opts)
    if units[unit.id] ~= unit then return end
    opts = opts or {}
    local invitees = WithdrawInvites(unit, opts.silentInvitees == true)
    local members = unit.members
    units[unit.id] = nil
    for _, m in ipairs(members) do
        if unitIdBySrc[m] == unit.id then unitIdBySrc[m] = nil end
        if not opts.silentMembers then Notify(m, 'info', 'unit.dissolved') end
    end
    unit.members = {}
    CP.log(TAG, 'unit %d dissolved', unit.id)
    local extra = {}
    for _, m in ipairs(members) do extra[#extra + 1] = m end
    for _, t in ipairs(invitees) do extra[#extra + 1] = t end
    PushUnit(nil, extra)
end

-- Toast to the member who left / to the others, by reason.
local LEFT_SELF = { left = 'unit.you_left', lost = 'unit.removed_lost' }
local LEFT_OTHERS = {
    left = 'unit.member_left',
    moved = 'unit.member_left',
    lost = 'unit.member_lost',
    disconnected = 'unit.member_disconnected',
}

-- Take one member out (leader succession, dissolve with one member left). Never touches runs.
local function RemoveMember(unit, src, reason, silent)
    local i = IndexOf(unit.members, src)
    if not i then return false end
    local info = unit.info[src]
    local name = info and info.name or ('#' .. src)
    table.remove(unit.members, i)
    unit.info[src] = nil
    unit.joinedAt[src] = nil
    if unitIdBySrc[src] == unit.id then unitIdBySrc[src] = nil end
    CP.log(TAG, 'unit %d: %d removed (%s), %d left', unit.id, src, tostring(reason), #unit.members)
    if not silent and LEFT_SELF[reason] then Notify(src, 'info', LEFT_SELF[reason]) end

    if #unit.members <= 1 then
        -- A unit left with one member dissolves (its pending invites with it).
        local last = unit.members[1]
        if last and not silent then Notify(last, 'info', 'unit.dissolved_after', { name = name }) end
        Dissolve(unit, { silentMembers = true, silentInvitees = silent })
        PushUnit(nil, { src })
        return true
    end

    if unit.leader == src then
        -- The longest-standing member takes over.
        unit.leader = unit.members[1]
        local newInfo = unit.info[unit.leader]
        if not silent then
            for _, m in ipairs(unit.members) do
                Notify(m, 'info', m == unit.leader and 'unit.you_lead' or 'unit.new_leader',
                    { name = newInfo and newInfo.name or '?' })
            end
        end
    end
    if not silent then
        local key = LEFT_OTHERS[reason] or 'unit.member_left'
        for _, m in ipairs(unit.members) do Notify(m, 'info', key, { name = name }) end
    end
    PushUnit(unit, { src })
    return true
end

-- Cancel every pending invite sent to src (all units but exceptUnitId). Forming units left without
-- invites dissolve. notifyKey: toast to whoever sent the invite (nil = none).
local function DropInvitesTo(src, exceptUnitId, notifyKey)
    local touched = {}
    for id, unit in pairs(units) do
        if id ~= exceptUnitId and unit.invites[src] then
            local from = unit.inviteFrom[src]
            unit.invites[src] = nil
            unit.inviteFrom[src] = nil
            touched[#touched + 1] = unit
            if notifyKey and from and from.src and IndexOf(unit.members, from.src) then
                Notify(from.src, 'info', notifyKey, { name = from.targetName or ('#' .. src) })
            end
        end
    end
    for _, unit in ipairs(touched) do
        if #unit.members <= 1 and next(unit.invites) == nil then
            Dissolve(unit, { silentMembers = true, silentInvitees = true })
        else
            PushUnit(unit)
        end
    end
    if #touched > 0 then Push(src, 'unit', { unitId = unitIdBySrc[src] or false }) end
end

-- ============================================================================
--                                  PUBLIC API
-- ============================================================================

function Units.unitOf(src)
    src = ToSrc(src)
    local id = src and unitIdBySrc[src]
    return id and units[id] or nil
end

function Units.members(src)
    src = ToSrc(src)
    local unit = Units.unitOf(src)
    if not unit then return src and { src } or {} end
    local out = {}
    for i, m in ipairs(unit.members) do out[i] = m end
    return out
end

function Units.isLeader(src)
    src = ToSrc(src)
    if not src then return false end
    local unit = Units.unitOf(src)
    if not unit then return true end
    return unit.leader == src
end

function Units.lock(ref)
    local unit = Resolve(ref)
    if not unit then return false end
    unit.locked = true
    unit.lockedAt = os.time()
    -- Invites close now: the draw depends on the unit's size and every member's cooldowns.
    local invitees = WithdrawInvites(unit, false)
    if #unit.members <= 1 then
        -- A forming unit (just its leader) is not a unit: the leader goes solo.
        Dissolve(unit, { silentMembers = true, silentInvitees = true })
        PushUnit(nil, invitees)
        return true
    end
    PushUnit(unit, invitees)
    CP.log(TAG, 'unit %d locked', unit.id)
    return true
end

function Units.unlock(ref)
    local unit = Resolve(ref)
    if not unit or not unit.locked then return false end
    for _, m in ipairs(unit.members) do
        local run = RunOf(m)
        if run and IsUnitRun(run) then
            CP.log(TAG, 'unit %d stays locked: %d is still on run %s', unit.id, m, tostring(run.id))
            return false
        end
    end
    unit.locked = false
    unit.lockedAt = nil
    PushUnit(unit)
    CP.log(TAG, 'unit %d unlocked', unit.id)
    return true
end

function Units.remove(src, opts)
    src = ToSrc(src)
    if not src then return false end
    opts = type(opts) == 'table' and opts or {}
    local reason = opts.reason or 'left'
    local removed = false
    local unit = Units.unitOf(src)
    if unit then removed = RemoveMember(unit, src, reason, opts.silent == true) end
    DropInvitesTo(src, nil, (reason == 'disconnected' or reason == 'lost') and 'unit.invite_cancelled' or nil)
    return removed
end

-- ============================================================================
--                                   INVITES
-- ============================================================================

local function Invite(src, target)
    local me, errKey = GetOfficer(src)
    if not me then return false, errKey or 'err.not_police' end
    if target == src then return false, 'err.unit_invite_self' end
    -- ARCHITECTURE §0.14 / CRIMSON_ARENA.md: in-arena players take no part in invites.
    if InArena(src) then return false, 'err.in_arena' end
    if OnRun(src) then return false, 'err.unit_on_run' end

    local them = GetOfficer(target)
    if not them then return false, 'err.unit_target_unavailable' end
    if OnRun(target) then return false, 'err.unit_target_on_run' end
    if InArena(target) then return false, 'err.unit_target_unavailable' end

    -- No yields below: the state checks and the change happen together.
    local now = os.time()
    local max = MaxSize()
    local unit = Units.unitOf(src)
    if unit then
        if unit.locked then return false, 'err.unit_locked' end
        if IndexOf(unit.members, target) then return false, 'err.unit_already_member' end
        local exp = unit.invites[target]
        if exp and exp > now then return false, 'err.unit_already_invited' end
        if #unit.members + PendingCount(unit, now) >= max then return false, 'err.unit_full' end
    end
    local theirs = Units.unitOf(target)
    if theirs and #theirs.members >= max then return false, 'err.unit_target_in_full_unit' end

    if not unit then unit = NewUnit(src, InfoOf(me)) else unit.info[src] = InfoOf(me) end
    unit.invites[target] = now + INVITE_TTL
    unit.inviteFrom[target] = {
        src = src,
        name = CP.U.clip(me.name or '?', 64),
        callsign = me.callsign and CP.U.clip(me.callsign, 32) or nil,
        departmentShort = me.departmentShort or '',
        targetName = CP.U.clip(them.name or '?', 64),
    }
    Notify(target, 'info', 'unit.invite_received', {
        name = me.name or '?',
        callsign = me.callsign or CP.L('unit.no_callsign'),
        department = me.departmentShort or '',
        seconds = INVITE_TTL,
    }, { title = 'unit.invite_title', duration = INVITE_TOAST_MS })
    PushUnit(unit, nil, target)
    CP.log(TAG, 'unit %d: %d invited %d', unit.id, src, target)
    return true, { unitId = unit.id, expiresIn = INVITE_TTL }
end

-- The invite src answers: the one of unitId, or the newest one.
local function FindInvite(src, unitId)
    local now = os.time()
    if unitId then
        local unit = units[unitId]
        if unit and unit.invites[src] then return unit, unit.invites[src] <= now end
        return nil
    end
    local best, bestExp = nil, -1
    for _, unit in pairs(units) do
        local exp = unit.invites[src]
        if exp and exp > now and exp > bestExp then best, bestExp = unit, exp end
    end
    return best, false
end

local function Respond(src, accepted, unitId)
    local me, errKey = GetOfficer(src)
    if not me then return false, errKey or 'err.not_police' end

    local unit, expired = FindInvite(src, unitId)
    if not unit then return false, 'err.unit_no_invite' end
    local from = unit.inviteFrom[src]
    if expired then
        unit.invites[src] = nil
        unit.inviteFrom[src] = nil
        if #unit.members <= 1 and next(unit.invites) == nil then
            Dissolve(unit, { silentMembers = true, silentInvitees = true })
        else
            PushUnit(unit)
        end
        Push(src, 'unit', { unitId = unitIdBySrc[src] or false })
        return false, 'err.unit_invite_expired'
    end

    if not accepted then
        unit.invites[src] = nil
        unit.inviteFrom[src] = nil
        if from and from.src then Notify(from.src, 'info', 'unit.invite_declined', { name = me.name or '?' }) end
        if #unit.members <= 1 and next(unit.invites) == nil then
            Dissolve(unit, { silentMembers = true, silentInvitees = true })
        else
            PushUnit(unit)
        end
        Push(src, 'unit', { unitId = unitIdBySrc[src] or false })
        return true, { unitId = nil, accepted = false }
    end

    if InArena(src) then return false, 'err.in_arena' end
    if OnRun(src) then return false, 'err.already_on_run' end
    if IndexOf(unit.members, src) then return false, 'err.unit_already_member' end
    if unit.locked then return false, 'err.unit_invite_locked' end
    if #unit.members >= MaxSize() then return false, 'err.unit_full' end

    -- Leave the current unit first (not on a run, checked above).
    local old = Units.unitOf(src)
    if old and old ~= unit then
        RemoveMember(old, src, 'moved', false)
        if units[unit.id] ~= unit then return false, 'err.unit_gone' end
    end

    unit.invites[src] = nil
    unit.inviteFrom[src] = nil
    unit.members[#unit.members + 1] = src
    unit.info[src] = InfoOf(me)
    unit.joinedAt[src] = os.time()
    unitIdBySrc[src] = unit.id
    -- Joining a unit declines the other invites waiting for this officer.
    DropInvitesTo(src, unit.id, nil)

    local leaderInfo = unit.info[unit.leader]
    for _, m in ipairs(unit.members) do
        if m == src then
            Notify(m, 'success', 'unit.joined', { name = leaderInfo and leaderInfo.name or '?' })
        else
            Notify(m, 'success', 'unit.member_joined', { name = me.name or '?' })
        end
    end
    PushUnit(unit)
    CP.log(TAG, 'unit %d: %d joined (%d members)', unit.id, src, #unit.members)
    return true, { unitId = unit.id, accepted = true }
end

local function Leave(src)
    local _, errKey = GetOfficer(src)
    local unit = Units.unitOf(src)
    if not unit then
        if errKey then return false, errKey end
        return false, 'err.unit_none'
    end
    local abandoned = false
    local run = RunOf(src)
    if run and IsUnitRun(run) and unit.locked then
        -- Leaving the unit mid-run abandons that run (type cooldown); the run continues for the rest.
        if CP.Runs and CP.Runs.removeParticipant then
            local ok = Call('Runs', 'removeParticipant', run, src, 'quit')
            abandoned = ok
        end
    end
    unit = Units.unitOf(src)
    if unit then RemoveMember(unit, src, 'left', false) end
    return true, { left = true, abandoned = abandoned }
end

-- ============================================================================
--                           VIEW (callback getUnit)
-- ============================================================================

local function SortPeople(list)
    table.sort(list, function(a, b)
        if a.departmentShort ~= b.departmentShort then
            return tostring(a.departmentShort) < tostring(b.departmentShort)
        end
        if a.name ~= b.name then return tostring(a.name) < tostring(b.name) end
        return (a.src or 0) < (b.src or 0)
    end)
end

local function OnlinePlayers()
    local ok, list = Call('Qbx', 'getOnlinePlayers')
    if ok and type(list) == 'table' then return list end
    local out = {}
    if GetPlayers then
        for _, s in ipairs(GetPlayers()) do
            local n = ToSrc(s)
            if n then out[#out + 1] = n end
        end
    end
    return out
end

-- Cheap pre-check without waiting on the database: an on-duty player whose active job is in a department.
local function MaybeOfficer(src)
    if not (CP.Qbx and CP.Qbx.getInfo and CP.Access and CP.Access.departmentForJob) then return true end
    local ok, info = Call('Qbx', 'getInfo', src)
    if not ok or type(info) ~= 'table' or type(info.job) ~= 'table' or not info.job.onduty then return false end
    local okD, dept = Call('Access', 'departmentForJob', info.job.name)
    return okD and dept ~= nil
end

function Units.view(src)
    src = ToSrc(src)
    local me, errKey = GetOfficer(src)
    if not me then return nil, errKey or 'err.not_police' end
    local now = os.time()
    local max = MaxSize()
    local unit = Units.unitOf(src)
    local meOnRun = OnRun(src)

    local view = {
        me = src,
        maxSize = max,
        onRun = meOnRun,
        inviteTtl = INVITE_TTL,
        unit = nil,
        invites = {},
        invitable = {},
        canInvite = false,
        inviteBlocked = nil,
    }

    if unit then
        local members = {}
        for _, m in ipairs(unit.members) do
            local o = (m == src) and me or GetOfficer(m)
            if o then unit.info[m] = InfoOf(o) end
            local info = unit.info[m] or { name = '#' .. m, rank = '', departmentShort = '' }
            members[#members + 1] = {
                src = m,
                name = info.name,
                callsign = info.callsign,
                rank = info.rank or '',
                departmentShort = info.departmentShort or '',
                isLeader = m == unit.leader,
                available = o ~= nil,
            }
        end
        local pending = {}
        for target, exp in pairs(unit.invites) do
            if exp > now then
                local o = GetOfficer(target)
                pending[#pending + 1] = {
                    src = target,
                    name = o and o.name or ('#' .. target),
                    callsign = o and o.callsign or nil,
                    departmentShort = o and o.departmentShort or '',
                    expiresIn = exp - now,
                }
            end
        end
        SortPeople(pending)
        -- Units changed while the view was built (getOfficer can wait on the database).
        if units[unit.id] == unit then
            view.unit = {
                id = unit.id,
                leader = unit.leader,
                locked = unit.locked == true,
                size = #unit.members,
                members = members,
                pending = pending,
            }
        end
    end

    for id, u in pairs(units) do
        local exp = u.invites[src]
        if exp and exp > now then
            local from = u.inviteFrom[src] or {}
            view.invites[#view.invites + 1] = {
                unitId = id,
                from = from.name or '?',
                fromCallsign = from.callsign,
                departmentShort = from.departmentShort or '',
                expiresIn = exp - now,
                size = #u.members,
            }
        end
    end
    table.sort(view.invites, function(a, b) return a.expiresIn > b.expiresIn end)

    local liveUnit = view.unit and unit or nil
    if meOnRun then
        view.inviteBlocked = 'unit.blocked_on_run'
    elseif liveUnit and liveUnit.locked then
        view.inviteBlocked = 'unit.blocked_locked'
    elseif liveUnit and #liveUnit.members + PendingCount(liveUnit, now) >= max then
        view.inviteBlocked = 'unit.blocked_full'
    else
        view.canInvite = true
    end

    if view.canInvite then
        local skip = { [src] = true }
        if liveUnit then
            for _, m in ipairs(liveUnit.members) do skip[m] = true end
            for target, exp in pairs(liveUnit.invites) do
                if exp > now then skip[target] = true end
            end
        end
        for _, p in ipairs(OnlinePlayers()) do
            p = ToSrc(p)
            if p and not skip[p] and MaybeOfficer(p) then
                local o = GetOfficer(p)
                if o and not OnRun(p) and not InArena(p) then
                    local theirs = Units.unitOf(p)
                    if not theirs or #theirs.members < max then
                        view.invitable[#view.invitable + 1] = {
                            src = p,
                            name = o.name or ('#' .. p),
                            callsign = o.callsign,
                            rank = o.rank or '',
                            departmentShort = o.departmentShort or '',
                            inUnit = theirs ~= nil,
                        }
                    end
                end
            end
        end
        SortPeople(view.invitable)
    end
    return view
end

-- ============================================================================
--                                     NET
-- ============================================================================

local function ParseTarget(payload)
    if type(payload) == 'table' then payload = payload.targetSrc or payload.target or payload.src end
    if type(payload) ~= 'number' and type(payload) ~= 'string' then return nil end
    if type(payload) == 'string' and #payload > 8 then return nil end
    return ToSrc(payload)
end

CP.Net.action('server:unitInvite', function(src, payload)
    local target = ParseTarget(payload)
    if not target then return false, 'err.invalid_payload' end
    if not CP.Net.rateOk(src, 'units:invite', 6, 10000) then return false, 'err.rate_limited' end
    return Invite(src, target)
end, { rate = 3 })

CP.Net.action('server:unitRespond', function(src, payload)
    local accepted, unitId
    if type(payload) == 'boolean' then
        accepted = payload
    elseif type(payload) == 'table' then
        if type(payload.accepted) ~= 'boolean' then return false, 'err.invalid_payload' end
        accepted = payload.accepted
        if payload.unitId ~= nil then
            unitId = math.tointeger(tonumber(payload.unitId))
            if not unitId or unitId <= 0 then return false, 'err.invalid_payload' end
        end
    else
        return false, 'err.invalid_payload'
    end
    return Respond(src, accepted, unitId)
end, { rate = 3 })

CP.Net.action('server:unitLeave', function(src)
    return Leave(src)
end, { rate = 2 })

CP.Net.callback('getUnit', function(src)
    return Units.view(src)
end, { rate = 4 })

-- ============================================================================
--              CLEANUP: disconnect, character unload, lost access
-- ============================================================================

AddEventHandler('playerDropped', function()
    local src = source
    Units.remove(src, { reason = 'disconnected' })
end)

-- ============================================================================
--                 SWEEP: invite expiry and the lock safety net
-- ============================================================================

function Units._sweep()
    local now = os.time()
    local list = {}
    for _, unit in pairs(units) do list[#list + 1] = unit end
    for _, unit in ipairs(list) do
        if units[unit.id] == unit then
            local expired = {}
            for target, exp in pairs(unit.invites) do
                if exp <= now then expired[#expired + 1] = target end
            end
            table.sort(expired)
            for _, target in ipairs(expired) do
                local from = unit.inviteFrom[target]
                unit.invites[target] = nil
                unit.inviteFrom[target] = nil
                Notify(target, 'info', 'unit.invite_expired_you', { name = from and from.name or '?' })
                if from and from.src and IndexOf(unit.members, from.src) then
                    Notify(from.src, 'info', 'unit.invite_expired',
                        { name = from.targetName or ('#' .. target), seconds = INVITE_TTL })
                end
                Push(target, 'unit', { unitId = unitIdBySrc[target] or false })
            end
            if #expired > 0 then
                if #unit.members <= 1 and next(unit.invites) == nil then
                    Dissolve(unit, { silentMembers = true, silentInvitees = true })
                else
                    PushUnit(unit)
                end
            end
            if units[unit.id] == unit and unit.locked and unit.lockedAt and now - unit.lockedAt >= LOCK_GRACE
                and CP.Runs and CP.Runs.getBySrc then
                local busy = false
                for _, m in ipairs(unit.members) do
                    local run = RunOf(m)
                    if run and IsUnitRun(run) then busy = true; break end
                end
                if not busy then
                    CP.log(TAG, 'unit %d: no member on a run, lifting the lock', unit.id)
                    Units.unlock(unit)
                end
            end
        end
    end
end

CreateThread(function()
    Wait(0)
    if CP.Qbx and CP.Qbx.onPlayerUnload then
        CP.Qbx.onPlayerUnload(function(src)
            Units.remove(src, { reason = 'disconnected' })
        end)
    end
    if CP.Access and CP.Access.onLost then
        CP.Access.onLost(function(src)
            Units.remove(src, { reason = 'lost' })
        end)
    end
    while true do
        Wait(SWEEP_MS)
        local ok, err = pcall(Units._sweep)
        if not ok then CP.err(TAG, 'sweep failed: %s', tostring(err)) end
    end
end)

-- Test hook (tests/teams_spec.lua): the constant and a reset of all state.
Units._INVITE_TTL = INVITE_TTL
Units._LOCK_GRACE = LOCK_GRACE
function Units._reset()
    units, unitIdBySrc, nextId = {}, {}, 0
end
