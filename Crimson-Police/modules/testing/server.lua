-- CP.Testing (server): Admin test mode.

CP.Testing = CP.Testing or {}
local Testing = CP.Testing
local U = CP.U
local TAG = 'testing'

local INVITE_TTL = 120            -- seconds an invitation waits for an answer
local ACCEPTED_TTL = 900          -- seconds an accepted invitation waits for the start
local INVITE_PURGE = 600          -- answered/expired invitations are forgotten after this long
local PENDING_KEEP = 6 * 3600     -- ended tests waiting for a recorded result
local PENDING_MAX = 10            -- per admin
local DEBUG_EVERY_MS = 2000
local MAINTENANCE_EVERY_MS = 5000
local START_COOLDOWN_MS = 2000
local NOTE_MAX = 255
local MAX_POINTS = 240
local MAX_ROUTES = 16
local MAX_ROUTE_POINTS = 250
local MAX_ROUTE_POINTS_TOTAL = 1200
local MAX_ZONES = 24
local MAX_CANDIDATES = 128
local MAX_TARGETS = 16
local MISSION_ID = '^[%a][%w_]*$'
local CONTROLS = {
    skip = true,
    restart = true,
    pause = true,
    resume = true,
    complete = true,
    fail = true,
    ['end'] = true,
    teleport = true,
    debug = true,
}
local SKIP_LOCATION_KEYS = { label = true, start = true, medals = true }
local ROUTE_FIELDS = { 'checkpoints', 'route', 'routes', 'fleeTo' }

local invites = {}      -- inviteId -> invite
local lobbies = {}      -- adminSrc -> { missionId, missionLabel, draft, order = { inviteId, ... } }
local tests = {}        -- runId -> test meta
local byAdmin = {}      -- adminSrc -> runId of the test they started
local pending = {}      -- admin citizenid -> { entry, ... } ended tests waiting for a result (newest first)
local lastStart = {}    -- adminSrc -> GetGameTimer() of the last start attempt
local names = {}        -- citizenid -> display name seen this session
local inviteSeq = 0
local warned = {}
local dbReady = false

-- ============================================================================
--                                SMALL HELPERS
-- ============================================================================

local function WarnOnce(key, fmt, ...)
    if warned[key] then return end
    warned[key] = true
    CP.warn(TAG, fmt, ...)
end

local function ToSrc(v)
    local n = tonumber(v)
    if not n then return nil end
    n = math.tointeger(n)
    if not n or n <= 0 then return nil end
    return n
end

local function ToInt(v)
    local n = tonumber(v)
    if not n then return nil end
    return math.tointeger(n)
end

local function Num(v, default)
    local n = tonumber(v)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return default end
    return n
end

local function Has(modName, fnName)
    local m = CP[modName]
    return type(m) == 'table' and type(m[fnName]) == 'function'
end

-- Call CP.<mod>.<fn>(...) when it exists: true plus its results, or false (missing or it raised).
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

local function Db()
    if not dbReady then
        if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
        dbReady = true
    end
end

local function Online(src)
    return src ~= nil and GetPlayerName(src) ~= nil
end

local function Cfg()
    return Config.Testing or {}
end

local function MaxTesters()
    return math.max(1, math.floor(Num(Cfg().maxTesters, 8)))
end

local function IsVec(v)
    local t = type(v)
    if t == 'vector3' or t == 'vector4' then return true end
    return t == 'table' and type(v.x) == 'number' and type(v.y) == 'number' and type(v.z) == 'number'
end

local function VecTable(v)
    local x, y, z = U.xyz(v)
    if not x then return nil end
    local out = { x = x + 0.0, y = y + 0.0, z = z + 0.0 }
    if (type(v) == 'vector4' or type(v) == 'table') and type(v.w) == 'number' then out.h = v.w + 0.0 end
    return out
end

local function Notify(src, kind, key, vars)
    if src and src > 0 and Has('Tablet', 'notify') then Call('Tablet', 'notify', src, kind, key, vars) end
end

local function Push(src, topic, data)
    if src and src > 0 and Has('Tablet', 'push') then Call('Tablet', 'push', src, topic, data) end
end

local function InArena(src)
    if not src then return false end
    if not Has('Alerts', 'inArena') then
        WarnOnce('alerts', 'CP.Alerts.inArena is not available: the arena gates only check the routing bucket')
        return GetPlayerRoutingBucket ~= nil and GetPlayerRoutingBucket(src) ~= 0
    end
    local ok, res = Call('Alerts', 'inArena', src)
    return ok and res == true
end

local function OnMission(src)
    local ok, res = Call('Runs', 'isOnMission', src)
    return ok and res == true
end

local function GetRun(runId)
    if type(runId) ~= 'string' then return nil end
    local ok, run = Call('Runs', 'get', runId)
    if ok and type(run) == 'table' and run.state ~= 'ended' then return run end
    return nil
end

local function CitizenOf(src)
    local ok, info = Call('Qbx', 'getInfo', src)
    if ok and type(info) == 'table' and type(info.citizenid) == 'string' then
        if type(info.name) == 'string' and info.name ~= '' then names[info.citizenid] = info.name end
        return info.citizenid, info
    end
    return nil
end

local function PlayerName(src)
    local _, info = CitizenOf(src)
    if info and type(info.name) == 'string' and info.name ~= '' then return info.name end
    return GetPlayerName(src) or ('#' .. tostring(src))
end

local function Can(src, action)
    if not (CP.Permissions and CP.Permissions.can) then return false, 'err.no_permission' end
    local ok, allowedNow, errKey = pcall(CP.Permissions.can, src, action)
    if not ok then
        CP.err(TAG, 'CP.Permissions.can(%s) failed: %s', tostring(action), tostring(allowedNow))
        return false, 'err.no_permission'
    end
    if allowedNow then return true end
    return false, errKey or 'err.no_permission'
end

-- Clip to at most n bytes without splitting a UTF-8 character (fits VARCHAR(n) whatever the connection
-- charset); nil for invalid UTF-8.
local function ClipText(s, n)
    if not utf8.len(s) then return nil end
    if #s <= n then return s end
    local cut = n
    while cut > 0 do
        local b = s:byte(cut + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end
        cut = cut - 1
    end
    return s:sub(1, cut)
end

-- ============================================================================
--                                    TIERS
-- ============================================================================

local function TierRows()
    return type(Config.Scaling) == 'table' and Config.Scaling or {}
end

local function ValidTier(name)
    if type(name) ~= 'string' then return nil end
    name = name:lower()
    for _, row in ipairs(TierRows()) do
        if row.tier == name then return name end
    end
    return nil
end

local function TierFor(n)
    local ok, row = Call('Scaling', 'tierFor', n)
    if ok and type(row) == 'table' and row.tier then return row.tier end
    local rows = TierRows()
    for _, row in ipairs(rows) do
        if Num(row.maxParticipants, 0) >= n then return row.tier end
    end
    return rows[#rows] and rows[#rows].tier or 'standard'
end

local function TierNameOf(row)
    if type(row) == 'table' then return row.tier end
    if type(row) == 'string' then return row end
    return nil
end

local function TierLabel(name)
    return CP.L('tier.' .. tostring(name))
end

-- ============================================================================
--                                   MISSIONS
-- ============================================================================

local function IsDisabled(id)
    return U.contains(Config.DisabledMissions or {}, id)
end

local function SortedDepartmentKeys()
    local ok, list = Call('Access', 'departments')
    local out = {}
    if ok and type(list) == 'table' then
        for _, d in ipairs(list) do if type(d) == 'table' and d.key then out[#out + 1] = d.key end end
    end
    if #out == 0 then out = U.keys(Config.Departments or {}) end
    return out
end

-- A normalised definition (loader fields present), or normalise a raw one with the given status.
local function EnsureNormalized(def, status)
    if type(def) ~= 'table' then return nil, 'not a table' end
    if type(def.defHash) == 'string' and type(def.source) == 'string' and type(def.locations) == 'table' then
        return def
    end
    if not Has('Missions', 'normalize') then return nil, 'CP.Missions.normalize is not available' end
    local meta = {
        source = 'custom',
        version = def.version,
        filePath = def.filePath,
        status = status,
        defHash = type(def.defHash) == 'string' and def.defHash or nil,
        editedInCode = def.editedInCode,
    }
    local ok, d, err = pcall(CP.Missions.normalize, def, meta)
    if not ok then return nil, tostring(d) end
    if type(d) ~= 'table' then return nil, err end
    return d
end

-- Archived custom missions (ids and versions). CP.Builder has no listing hook for them yet (requested:
-- archivedDefs / getArchived); until it has, the ids and versions are read (read-only) from its
-- cp_custom_missions rows and the definitions from the archived files (CP.Missions.parse + normalize).
local function ArchivedRows(id)
    Db()
    local sql = 'SELECT id, published_version FROM cp_custom_missions WHERE status = \'archived\''
    local params = {}
    if id then
        sql = sql .. ' AND id = ?'
        params[1] = id
    end
    local ok, rows = pcall(MySQL.query.await, sql, params)
    if not ok then
        WarnOnce('archivedRows', 'reading the archived custom missions failed: %s', tostring(rows))
        return {}
    end
    return type(rows) == 'table' and rows or {}
end

local archivedCache = {}   -- id -> { hash, def } (the file only changes on archive/restore or a hand edit)

-- Archived custom missions are unregistered from CP.Missions: ask the builder, else read the file.
local function ArchivedMission(id, version)
    local ok, def = Call('Builder', 'getArchived', id)
    if ok and type(def) == 'table' then
        local d = EnsureNormalized(def, 'archived')
        if d then d.status = 'archived'; return d end
    end
    if Has('Missions', 'parse') then
        local dir = (Config.Builder and Config.Builder.exportPath) or 'missions/custom/'
        if dir:sub(-1) ~= '/' then dir = dir .. '/' end
        local path = dir .. 'archived/' .. id .. '.lua'
        local content = LoadResourceFile(CP.resource, path)
        if content and content ~= '' then
            local hash = U.hashHex(content)
            local cached = archivedCache[id]
            if cached and cached.hash == hash then
                if version ~= nil then cached.def.version = version end
                return cached.def
            end
            local okP, raw = Call('Missions', 'parse', content, '@' .. path)
            if okP and type(raw) == 'table' and raw.id == id then
                raw.defHash = hash
                raw.filePath = path
                raw.version = version or raw.version
                local d = EnsureNormalized(raw, 'archived')
                if d then
                    d.status = 'archived'
                    if d.version == nil and version ~= nil then d.version = version end
                    archivedCache[id] = { hash = hash, def = d }
                    return d
                end
            end
        end
    end
    return nil
end

local function ResolveMission(id)
    if type(id) ~= 'string' or #id > 40 or not id:match(MISSION_ID) then return nil, 'err.test_unknown_mission' end
    local ok, def = Call('Missions', 'get', id)
    if ok and type(def) == 'table' then return def end
    local version
    if not Has('Builder', 'getArchived') then
        local row = ArchivedRows(id)[1]
        version = row and tonumber(row.published_version) or nil
    end
    local arch = ArchivedMission(id, version)
    if arch then return arch end
    return nil, 'err.test_unknown_mission'
end
Testing.resolveMission = ResolveMission

local function MissionStatus(def)
    if def.status == 'archived' then return 'archived' end
    if def.status == 'draft' then return 'draft' end
    return 'published'
end

local function LocationLabel(def, index)
    local loc = type(def.locations) == 'table' and def.locations[index] or nil
    if type(loc) == 'table' and type(loc.label) == 'string' and loc.label ~= '' then return loc.label end
    return CP.L('test.location_n', { n = index })
end

-- ============================================================================
--                             PARTICIPANT RECORDS
-- ============================================================================
-- Admins need not be police: their participant record comes from CP.Qbx.getInfo with the department of
-- their active job if it belongs to one, else the first department key (sorted). job = nil marks them
-- as a non-officer participant, so CP.Runs skips duty/job re-checks for them.
local function AdminRecord(src)
    local cid, info = CitizenOf(src)
    if not cid then return nil, 'err.test_no_character' end
    local jobName = type(info.job) == 'table' and info.job.name or nil
    local deptKey
    if jobName then
        local ok, key = Call('Access', 'departmentForJob', jobName)
        if ok and type(key) == 'string' then deptKey = key end
    end
    local isDeptJob = deptKey ~= nil
    if not deptKey then deptKey = SortedDepartmentKeys()[1] end
    local dept
    if deptKey then
        local ok, d = Call('Access', 'department', deptKey)
        if ok and type(d) == 'table' then dept = d end
    end
    local cfgDept = deptKey and Config.Departments and Config.Departments[deptKey] or {}
    return {
        src = src,
        citizenid = cid,
        name = U.clip(info.name or GetPlayerName(src) or cid, 64),
        callsign = info.callsign and U.clip(info.callsign, 32) or nil,
        rank = (isDeptJob and info.job.gradeName) or CP.L('test.admin_rank'),
        gradeLevel = isDeptJob and Num(info.job.gradeLevel, 0) or 0,
        department = deptKey,
        departmentLabel = (dept and dept.label) or cfgDept.label or deptKey,
        departmentShort = (dept and dept.short) or cfgDept.short or (deptKey and deptKey:upper()) or '',
        job = nil,
        onduty = false,
        isSupervisor = false,
        isAdmin = true,
        testAdmin = true,
    }
end

-- On-duty officer (their real officer record) or admin (adminRecord). Returns record, role or nil, errKey.
local function TesterRecord(src)
    local okO, officer = Call('Access', 'getOfficer', src)
    if okO and type(officer) == 'table' and officer.citizenid then
        if officer.name then names[officer.citizenid] = officer.name end
        return officer, 'officer'
    end
    local okA, admin = Call('Access', 'isAdmin', src)
    if okA and admin == true then
        local rec, err = AdminRecord(src)
        if not rec then return nil, err end
        return rec, 'admin'
    end
    return nil, 'err.test_not_eligible'
end

local function AuditRole(src)
    if src == 0 then return 'console' end
    local ok, role = Call('Access', 'role', src)
    if ok and role == 'supervisor' then return 'supervisor' end
    return 'admin'
end

local function Audit(src, category, action, target, oldV, newV, reason)
    if not Has('Admin', 'audit') then
        WarnOnce('audit', 'CP.Admin.audit is not available: test actions are not written to the audit log')
        return
    end
    Call('Admin', 'audit', src, AuditRole(src), category, action, target and U.clip(tostring(target), 64) or nil,
        oldV and U.clip(tostring(oldV), 64) or nil, newV and U.clip(tostring(newV), 64) or nil,
        reason and U.clip(tostring(reason), 255) or nil)
end

-- ============================================================================
--                                 INVITATIONS
-- ============================================================================

local function LobbyOf(adminSrc)
    return lobbies[adminSrc]
end

local function InviteRow(inv, now)
    return {
        inviteId = inv.id,
        src = inv.target,
        name = inv.name,
        callsign = inv.callsign,
        departmentShort = inv.departmentShort,
        rank = inv.rank,
        role = inv.role,
        status = inv.status,
        expiresIn = inv.status == 'pending' and math.max(0, inv.expiresAt - now) or 0,
    }
end

local function LobbyView(adminSrc)
    local lobby = LobbyOf(adminSrc)
    local now = os.time()
    local view = {
        missionId = false,
        missionLabel = false,
        draft = false,
        invites = {},
        accepted = 0,
        maxTesters = MaxTesters(),
    }
    if not lobby then return view end
    view.missionId, view.missionLabel, view.draft = lobby.missionId, lobby.missionLabel, lobby.draft == true
    for _, id in ipairs(lobby.order) do
        local inv = invites[id]
        if inv then
            view.invites[#view.invites + 1] = InviteRow(inv, now)
            if inv.status == 'accepted' then view.accepted = view.accepted + 1 end
        end
    end
    return view
end

local function ForgetInvite(id)
    local inv = invites[id]
    if not inv then return end
    invites[id] = nil
    local lobby = lobbies[inv.admin]
    if lobby then
        for i = #lobby.order, 1, -1 do
            if lobby.order[i] == id then table.remove(lobby.order, i) end
        end
        if #lobby.order == 0 then lobbies[inv.admin] = nil end
    end
end

-- Pending/accepted invitations of a lobby that still hold a seat.
local function SeatsTaken(lobby, exceptId)
    local n = 0
    for _, id in ipairs(lobby.order) do
        local inv = invites[id]
        if inv and id ~= exceptId and (inv.status == 'pending' or inv.status == 'accepted') then n = n + 1 end
    end
    return n
end

local function AcceptedCount(lobby)
    local n = 0
    for _, id in ipairs(lobby.order) do
        local inv = invites[id]
        if inv and inv.status == 'accepted' then n = n + 1 end
    end
    return n
end

local function LobbyInviteFor(lobby, target)
    for _, id in ipairs(lobby.order) do
        local inv = invites[id]
        if inv and inv.target == target and (inv.status == 'pending' or inv.status == 'accepted') then return inv end
    end
    return nil
end

-- Expire and purge invitations; tells the people involved.
local function ExpireInvites(now)
    now = now or os.time()
    local changedAdmins, changedTargets = {}, {}
    for id, inv in pairs(invites) do
        if inv.status == 'pending' and now >= inv.expiresAt then
            inv.status = 'expired'
            inv.answeredAt = now
            changedAdmins[inv.admin] = true
            changedTargets[inv.target] = true
        elseif inv.status == 'accepted' and now >= (inv.answeredAt or now) + ACCEPTED_TTL then
            inv.status = 'expired'
            inv.answeredAt = now
            changedAdmins[inv.admin] = true
            changedTargets[inv.target] = true
        elseif inv.status ~= 'pending' and inv.status ~= 'accepted'
            and now - (inv.answeredAt or inv.createdAt) >= INVITE_PURGE then
            ForgetInvite(id)
            changedAdmins[inv.admin] = true
        end
    end
    for src in pairs(changedAdmins) do Push(src, 'invites', { test = true }) end
    for src in pairs(changedTargets) do Push(src, 'invites', { test = true }) end
end

-- Withdraw every open invitation of an admin's lobby (status 'withdrawn' or 'started').
local function CloseLobby(adminSrc, status, notifyKey)
    local lobby = lobbies[adminSrc]
    if not lobby then return end
    local now = os.time()
    for _, id in ipairs(lobby.order) do
        local inv = invites[id]
        if inv and (inv.status == 'pending' or inv.status == 'accepted') then
            local wasAccepted = inv.status == 'accepted'
            inv.status = status
            inv.answeredAt = now
            Push(inv.target, 'invites', { test = true })
            if notifyKey and wasAccepted then Notify(inv.target, 'info', notifyKey, { mission = inv.missionLabel }) end
        end
    end
    lobbies[adminSrc] = nil
    for _, id in ipairs(lobby.order) do
        local inv = invites[id]
        if inv and inv.status ~= 'pending' and inv.status ~= 'accepted' then invites[id] = nil end
    end
end

function Testing.pendingInvites(src)
    ExpireInvites()
    local list, now = {}, os.time()
    for _, inv in pairs(invites) do
        if inv.target == src and inv.status == 'pending' and now < inv.expiresAt then list[#list + 1] = inv end
    end
    table.sort(list, function(a, b) return (a.seq or 0) < (b.seq or 0) end)
    local out = {}
    for _, inv in ipairs(list) do
        out[#out + 1] = {
            inviteId = inv.id,
            missionId = inv.missionId,
            missionLabel = inv.missionLabel,
            from = inv.from,
            fromCallsign = inv.fromCallsign or false,
            expiresIn = math.max(0, inv.expiresAt - now),
        }
    end
    return out
end

function Testing.invite(adminSrc, targets, opts)
    adminSrc = ToSrc(adminSrc)
    opts = type(opts) == 'table' and opts or {}
    if not adminSrc then return false, 'err.not_in_game' end
    if Cfg().enabled == false then return false, 'err.test_disabled' end
    if type(targets) ~= 'table' or #targets > MAX_TARGETS then return false, 'err.invalid_payload' end
    if InArena(adminSrc) then return false, 'err.in_arena' end
    local missionId, missionLabel = opts.missionId, opts.missionLabel
    if opts.draft then
        if type(missionId) ~= 'string' or #missionId > 40 or not missionId:match(MISSION_ID) then
            return false, 'err.test_unknown_mission'
        end
        if type(missionLabel) ~= 'string' or missionLabel == '' then missionLabel = missionId end
        missionLabel = ClipText(missionLabel, 64) or missionId -- never cut inside a UTF-8 sequence
    else
        local def, err = ResolveMission(missionId)
        if not def then return false, err end
        missionLabel = def.label or def.id
    end
    ExpireInvites()

    local lobby = lobbies[adminSrc]
    if lobby and lobby.missionId ~= missionId then
        CloseLobby(adminSrc, 'withdrawn', 'test.invite_withdrawn')
        lobby = nil
    end
    if not lobby then
        lobby = { missionId = missionId, missionLabel = missionLabel, draft = opts.draft == true, order = {} }
        lobbies[adminSrc] = lobby
    end
    local adminCid, adminInfo = CitizenOf(adminSrc)
    local fromName = PlayerName(adminSrc)
    local fromCallsign = adminInfo and adminInfo.callsign or nil
    local skipped = {}
    local seen = {}
    for _, raw in ipairs(targets) do
        local target = ToSrc(raw)
        if not target then
            skipped[#skipped + 1] = { src = tonumber(raw) or false, error = 'err.invalid_payload' }
        elseif not seen[target] then
            seen[target] = true
            -- errKey: a locale key = skipped with that reason, false = already invited (nothing to do)
            local errKey = nil
            if target == adminSrc then
                errKey = 'err.test_invite_self'
            elseif LobbyInviteFor(lobby, target) then
                errKey = false
            elseif not Online(target) then
                errKey = 'err.test_player_offline'
            elseif SeatsTaken(lobby) >= MaxTesters() - 1 then
                errKey = 'err.test_full'
            elseif InArena(target) then
                errKey = 'err.in_arena'
            elseif OnMission(target) then
                errKey = 'err.test_player_busy'
            end
            local rec, role
            if errKey == nil then
                rec, role = TesterRecord(target)
                if not rec then errKey = role end
            end
            if errKey == nil then
                inviteSeq = inviteSeq + 1
                local now = os.time()
                local inv = {
                    id = ('ti%d'):format(inviteSeq),
                    admin = adminSrc,
                    adminCid = adminCid,
                    from = fromName,
                    fromCallsign = fromCallsign,
                    target = target,
                    name = rec.name,
                    callsign = rec.callsign,
                    departmentShort = rec.departmentShort,
                    rank = rec.rank,
                    role = role,
                    missionId = missionId,
                    missionLabel = missionLabel,
                    status = 'pending',
                    createdAt = now,
                    expiresAt = now + INVITE_TTL,
                    seq = inviteSeq,
                }
                invites[inv.id] = inv
                lobby.order[#lobby.order + 1] = inv.id
                TriggerClientEvent(CP.e('client:testInvite'), target, {
                    inviteId = inv.id,
                    missionLabel = missionLabel,
                    from = fromName,
                    expiresIn = INVITE_TTL,
                })
                Push(target, 'invites', { test = true })
                CP.log(TAG, '%d invited %d to test %s (%s)', adminSrc, target, tostring(missionId), inv.id)
            elseif errKey then
                skipped[#skipped + 1] = { src = target, error = errKey }
            end
        end
    end
    if #lobby.order == 0 then lobbies[adminSrc] = nil end
    Push(adminSrc, 'invites', { test = true })
    return true, { lobby = LobbyView(adminSrc), skipped = skipped }
end

function Testing.cancelInvites(adminSrc)
    adminSrc = ToSrc(adminSrc)
    if not adminSrc then return false, 'err.not_in_game' end
    CloseLobby(adminSrc, 'withdrawn', 'test.invite_withdrawn')
    Push(adminSrc, 'invites', { test = true })
    return true, LobbyView(adminSrc)
end

function Testing.respond(src, payload)
    src = ToSrc(src)
    if not src then return false, 'err.not_in_game' end
    if type(payload) ~= 'table' or type(payload.inviteId) ~= 'string' or #payload.inviteId > 24
        or type(payload.accepted) ~= 'boolean' then
        return false, 'err.invalid_payload'
    end
    ExpireInvites()
    local inv = invites[payload.inviteId]
    if not inv or inv.target ~= src or inv.status ~= 'pending' then return false, 'err.test_invite_gone' end
    local lobby = lobbies[inv.admin]
    if not lobby or lobby.missionId ~= inv.missionId or not Online(inv.admin) then
        inv.status = 'expired'
        inv.answeredAt = os.time()
        return false, 'err.test_invite_gone'
    end
    if not payload.accepted then
        inv.status = 'declined'
        inv.answeredAt = os.time()
        Notify(inv.admin, 'info', 'test.invite_declined',
            { name = inv.name or ('#' .. src), mission = inv.missionLabel })
        Push(inv.admin, 'invites', { test = true })
        Push(src, 'invites', { test = true })
        return true, { inviteId = inv.id, status = 'declined' }
    end
    if InArena(src) then return false, 'err.in_arena' end
    if OnMission(src) then return false, 'err.already_on_run' end
    local rec, errKey = TesterRecord(src)
    if not rec then return false, errKey end
    if AcceptedCount(lobby) >= MaxTesters() - 1 then return false, 'err.test_full' end
    inv.status = 'accepted'
    inv.answeredAt = os.time()
    inv.name, inv.callsign, inv.departmentShort, inv.rank = rec.name, rec.callsign, rec.departmentShort, rec.rank
    Notify(inv.admin, 'success', 'test.invite_accepted',
        { name = inv.name or ('#' .. src), mission = inv.missionLabel })
    Push(inv.admin, 'invites', { test = true })
    Push(src, 'invites', { test = true })
    CP.log(TAG, '%d accepted invitation %s from %d', src, inv.id, inv.admin)
    return true, { inviteId = inv.id, status = 'accepted' }
end

-- ============================================================================
--                               STARTING A TEST
-- ============================================================================

local function ReservedAt(missionId, index)
    if Config.Limits and Config.Limits.reserveLocations == false then return false end
    local ok, res = Call('Draw', 'isReserved', missionId, index)
    return ok and res == true
end

local function ResolveLocation(def, location, srcs)
    local n = type(def.locations) == 'table' and #def.locations or 0
    if n == 0 then return nil, 'err.test_invalid_location' end
    if location == nil or location == 'random' or location == '' or location == 0 then
        local seed = U.hash(('%s:%d:%d'):format(def.id, os.time(), GetGameTimer())) & 0x7FFFFFFF
        local rng = U.rng(seed)
        if Has('Draw', 'pickLocation') then
            local ok, idx = Call('Draw', 'pickLocation', def, srcs, rng)
            if ok then
                idx = math.tointeger(tonumber(idx) or -1)
                if idx and idx >= 1 and idx <= n then return idx end
                return nil, 'err.no_location'
            end
        end
        local free = {}
        for i = 1, n do
            if not ReservedAt(def.id, i) then free[#free + 1] = i end
        end
        local idx = rng:pick(free)
        if not idx then return nil, 'err.no_location' end
        return idx
    end
    local idx = math.tointeger(tonumber(location) or -1)
    if not idx or idx < 1 or idx > n then return nil, 'err.test_invalid_location' end
    if ReservedAt(def.id, idx) then return nil, 'err.test_location_busy' end
    return idx
end

local function KnownError(errKey, fallback)
    if type(errKey) == 'string' and CP.Locale and CP.Locale.has and CP.Locale.has(errKey) then return errKey end
    return fallback
end

local function ClearStale(adminSrc)
    local runId = byAdmin[adminSrc]
    if runId and not GetRun(runId) then
        byAdmin[adminSrc] = nil
        if tests[runId] then tests[runId] = nil end
        return false
    end
    return runId ~= nil
end

-- The shared start path of catalog tests and draft tests.
local function StartWith(adminSrc, def, opts, draft)
    if Cfg().enabled == false then return false, 'err.test_disabled' end
    if ClearStale(adminSrc) then return false, 'err.test_already_running' end
    if lastStart[adminSrc] and GetGameTimer() - lastStart[adminSrc] < START_COOLDOWN_MS then
        return false, 'err.busy'
    end
    if InArena(adminSrc) then return false, 'err.in_arena' end
    if OnMission(adminSrc) then return false, 'err.already_on_run' end

    local tierName = nil
    if opts.tier ~= nil and opts.tier ~= '' and opts.tier ~= 'auto' then
        tierName = ValidTier(opts.tier)
        if not tierName then return false, 'err.test_invalid_tier' end
    end
    local useStartRoute = opts.useStartRoute
    if useStartRoute == nil then useStartRoute = Cfg().useStartRoute == true end
    if type(useStartRoute) ~= 'boolean' then return false, 'err.invalid_payload' end

    local adminRec, recErr = TesterRecord(adminSrc)
    if not adminRec then return false, recErr end
    names[adminRec.citizenid] = adminRec.name

    -- Testers: accepted invitations of this admin for this mission, re-validated now.
    local testers = type(opts.testers) == 'table' and opts.testers or {}
    if #testers > MaxTesters() - 1 then return false, 'err.test_full' end
    local members, srcs, used = { adminRec }, { adminSrc }, {}
    local lobby = lobbies[adminSrc]
    for _, raw in ipairs(testers) do
        local s = ToSrc(raw)
        if not s or s == adminSrc then return false, 'err.invalid_payload' end
        if not used[s] then
            used[s] = true
            local inv = lobby and lobby.missionId == def.id and LobbyInviteFor(lobby, s) or nil
            if not inv or inv.status ~= 'accepted' then return false, 'err.test_tester_not_ready' end
            if not Online(s) then return false, 'err.test_player_offline' end
            if InArena(s) then return false, 'err.in_arena' end
            if OnMission(s) then return false, 'err.test_player_busy' end
            local rec, errKey = TesterRecord(s)
            if not rec then return false, errKey end
            members[#members + 1] = rec
            srcs[#srcs + 1] = s
        end
    end
    if #members > MaxTesters() then return false, 'err.test_full' end

    local locationIndex, locErr = ResolveLocation(def, opts.location, srcs)
    if not locationIndex then return false, locErr end

    lastStart[adminSrc] = GetGameTimer()
    local okC, run, errKey = Call('Runs', 'create', {
        mission = def,
        locationIndex = locationIndex,
        missionType = def.type,
        members = members,
        leaderSrc = adminSrc,
        isBoss = def.isBoss == true,
        test = { adminSrc = adminSrc, useStartRoute = useStartRoute, forcedTier = tierName, draft = draft == true },
    })
    if not okC then return false, 'err.test_start_failed' end
    if type(run) ~= 'table' then return false, KnownError(errKey, 'err.test_start_failed') end

    local expected = tierName or run.expectedTier or TierFor(#members)
    local meta = {
        runId = run.id,
        admin = adminSrc,
        adminCid = adminRec.citizenid,
        adminName = adminRec.name,
        missionId = def.id,
        missionLabel = def.label or def.id,
        locationIndex = locationIndex,
        locationLabel = LocationLabel(def, locationIndex),
        tier = expected,
        forcedTier = tierName,
        useStartRoute = useStartRoute,
        draft = draft == true,
        version = def.version,
        defHash = def.defHash,
        testers = #members,
        startedAt = os.time(),
        debug = false,
    }
    tests[run.id] = meta
    byAdmin[adminSrc] = run.id

    if lobby and lobby.missionId == def.id then
        for _, s in ipairs(srcs) do
            local inv = LobbyInviteFor(lobby, s)
            if inv then inv.status = 'started'; inv.answeredAt = os.time() end
        end
    end
    CloseLobby(adminSrc, 'withdrawn', 'test.invite_withdrawn')

    TriggerClientEvent(CP.e('client:test'), adminSrc, { controls = true, runId = run.id, debug = false })
    Notify(adminSrc, 'success', 'test.started',
        { mission = meta.missionLabel, location = meta.locationLabel, tier = TierLabel(expected) })
    for i = 2, #srcs do
        Notify(srcs[i], 'info', 'test.started_tester', { mission = meta.missionLabel, from = adminRec.name })
    end
    Audit(adminSrc, 'audit', draft and 'testDraft' or 'testStart', ('%s#%d'):format(def.id, locationIndex), nil,
        ('%s x%d%s'):format(expected, #members, useStartRoute and ' route' or ''), nil)
    Push(adminSrc, 'test', { state = true })
    CP.log(TAG, '%d started a %stest of %s #%d at %s with %d tester(s) (run %s)', adminSrc, draft and 'draft ' or '',
        def.id, locationIndex, tostring(expected), #members, run.id)
    return true,
        { runId = run.id, missionId = def.id, locationIndex = locationIndex, tier = expected, testers = #members }
end

local function ValidStartPayload(p)
    if type(p) ~= 'table' then return false end
    if type(p.missionId) ~= 'string' or #p.missionId > 40 then return false end
    local loc = p.location
    if loc ~= nil and loc ~= 'random' then
        local n = ToInt(loc)
        if not n or n < 1 or n > 127 then return false end
    end
    if p.tier ~= nil and (type(p.tier) ~= 'string' or #p.tier > 16) then return false end
    if p.useStartRoute ~= nil and type(p.useStartRoute) ~= 'boolean' then return false end
    if p.testers ~= nil then
        if type(p.testers) ~= 'table' or #p.testers > MAX_TARGETS then return false end
        for _, s in ipairs(p.testers) do if not ToSrc(s) then return false end end
    end
    return true
end

function Testing.start(adminSrc, opts)
    local n = tonumber(adminSrc)
    if n == 0 then return false, 'err.not_in_game' end
    adminSrc = ToSrc(adminSrc)
    if not adminSrc then return false, 'err.not_in_game' end
    local okP, errP = Can(adminSrc, 'testRun')
    if not okP then return false, errP or 'err.no_permission' end
    if not ValidStartPayload(opts) then return false, 'err.invalid_payload' end
    local def, err = ResolveMission(opts.missionId)
    if not def then return false, err end
    return StartWith(adminSrc, def, opts, false)
end

function Testing.startDraft(src, def, opts)
    local n = tonumber(src)
    if n == 0 then return false, 'err.not_in_game' end
    src = ToSrc(src)
    if not src then return false, 'err.not_in_game' end
    opts = type(opts) == 'table' and opts or {}
    local okB = Can(src, 'builderEdit')
    if not okB then
        local okT, errT = Can(src, 'testRun')
        if not okT then return false, errT or 'err.no_permission' end
    end
    -- Hard rule 7: only Admin test runs bypass the Cross-Department lock; a supervisor's draft test does not.
    local okA, isAdm = Call('Access', 'isAdmin', src)
    if not (okA and isAdm == true) then
        local okL, locked = Call('Operations', 'isLocked')
        if okL and locked == true then return false, 'err.operation_locked' end
    end
    if type(def) ~= 'table' or type(def.id) ~= 'string' or #def.id > 40 or not def.id:match(MISSION_ID) then
        return false, 'err.test_invalid_draft'
    end
    local check = {
        missionId = def.id,
        location = opts.location,
        tier = opts.tier,
        useStartRoute = opts.useStartRoute,
        testers = opts.testers,
    }
    if not ValidStartPayload(check) then return false, 'err.invalid_payload' end
    local d, reason = EnsureNormalized(def, 'draft')
    if not d then
        CP.warn(TAG, 'draft %s cannot be tested: %s', def.id, tostring(reason))
        return false, 'err.test_invalid_draft', reason
    end
    d.status = 'draft'
    if d.version == nil and tonumber(def.version) then d.version = math.floor(tonumber(def.version)) end
    return StartWith(src, d, check, true)
end

function Testing.command(src, args)
    if type(args) ~= 'table' then return false, 'err.test_bad_command' end
    local missionId = args[1]
    if type(missionId) ~= 'string' or missionId == '' then return false, 'err.test_bad_command' end
    local tier, location
    for i = 2, 3 do
        local a = args[i]
        if a ~= nil then
            local s = tostring(a):lower()
            if ValidTier(s) or s == 'auto' then
                if tier then return false, 'err.test_bad_command' end
                tier = s
            elseif s == 'random' or ToInt(s) then
                if location then return false, 'err.test_bad_command' end
                if s == 'random' then location = 'random' else location = ToInt(s) end
            else
                return false, 'err.test_bad_command'
            end
        end
    end
    if #args > 3 then return false, 'err.test_bad_command' end
    local testers = {}
    local adminSrc = ToSrc(src)
    local lobby = adminSrc and lobbies[adminSrc]
    if lobby and lobby.missionId == missionId then
        for _, id in ipairs(lobby.order) do
            local inv = invites[id]
            if inv and inv.status == 'accepted' then testers[#testers + 1] = inv.target end
        end
    end
    return Testing.start(src, {
        missionId = missionId,
        tier = tier,
        location = location,
        useStartRoute = Cfg().useStartRoute == true,
        testers = testers,
    })
end

-- ============================================================================
--                                 DEBUG STREAM
-- ============================================================================

local function CurrentObjective(run)
    local i = run.objectiveIndex or 1
    local o = run.objectives and run.objectives[i] or nil
    local obj = (o and o.obj) or (run.mission.objectives or {})[i]
    return i, o, obj
end

local function AddPoint(g, key, i, v, radius)
    if #g.points >= MAX_POINTS then return end
    local p = VecTable(v)
    if not p then return end
    p.key, p.i = key, i
    if radius then p.r = radius end
    g.points[#g.points + 1] = p
end

local function AddRoute(g, key, list, loop)
    if #g.routes >= MAX_ROUTES or type(list) ~= 'table' then return end
    local pts = {}
    g.routePoints = g.routePoints or 0
    for _, v in ipairs(list) do
        if #pts >= MAX_ROUTE_POINTS or g.routePoints >= MAX_ROUTE_POINTS_TOTAL then break end
        local p = VecTable(IsVec(v) and v or (type(v) == 'table' and v.coords) or nil)
        if p then
            pts[#pts + 1] = { x = p.x, y = p.y, z = p.z }
            g.routePoints = g.routePoints + 1
        end
    end
    if #pts > 0 then g.routes[#g.routes + 1] = { key = key, loop = loop == true, points = pts } end
end

local function AddZone(g, label, v, radius)
    if #g.zones >= MAX_ZONES then return end
    local p = VecTable(v)
    local r = Num(radius, 0)
    if not p or r <= 0 then return end
    g.zones[#g.zones + 1] = { x = p.x, y = p.y, z = p.z, r = r + 0.0, label = label }
end

local function AddValue(g, key, v, asRoute, radius)
    if IsVec(v) then return AddPoint(g, key, 1, v, radius) end
    if type(v) ~= 'table' then return end
    if type(v.points) == 'table' then return AddRoute(g, key, v.points, v.loop) end
    if IsVec(v.coords) then return AddPoint(g, key, 1, v.coords, radius) end
    local first = v[1]
    if first == nil then return end
    if IsVec(first) or (type(first) == 'table' and IsVec(first.coords)) then
        for i, item in ipairs(v) do
            AddPoint(g, key, i, IsVec(item) and item or (type(item) == 'table' and item.coords) or nil, radius)
        end
        if asRoute then AddRoute(g, key, v, false) end
    elseif type(first) == 'table' and IsVec(first[1]) then
        for i, list in ipairs(v) do AddRoute(g, ('%s#%d'):format(key, i), list, false) end
    end
end

-- Spawn points, zones/radii and route waypoints of the run's location for the debug overlay.
local function Geometry(run)
    local loc = type(run.location) == 'table' and run.location or {}
    local start = type(loc.start) == 'table' and loc.start or {}
    local g = { start = false, points = {}, routes = {}, zones = {} }
    local s = VecTable(start.coords)
    if s then g.start = { x = s.x, y = s.y, z = s.z, r = Num(start.radius, 0) + 0.0 } end
    local routeKeys = {}
    for _, o in ipairs(run.mission.objectives or {}) do
        if type(o) == 'table' then
            for _, f in ipairs(ROUTE_FIELDS) do
                if type(o[f]) == 'string' then routeKeys[o[f]] = true end
            end
        end
    end
    local _, _, obj = CurrentObjective(run)
    obj = type(obj) == 'table' and obj or {}
    local radiusFor = {}
    if type(obj.checkpoints) == 'string' then radiusFor[obj.checkpoints] = Num(obj.radius, 10.0) end
    for _, key in ipairs(U.keys(loc)) do
        if type(key) == 'string' and not SKIP_LOCATION_KEYS[key] then
            AddValue(g, key, loc[key], routeKeys[key], radiusFor[key])
        end
    end
    if run.state == 'in_progress' then
        local okA, anchor = Call('Runs', 'anchor', run)
        if okA and anchor then AddZone(g, 'presence', anchor, obj.presenceRange) end
    end
    if type(obj.safe) == 'string' then AddZone(g, 'safe', loc[obj.safe], Num(obj.safeRadius, 6.0)) end
    if type(obj.center) == 'string' then AddZone(g, 'search', loc[obj.center], obj.startRadius) end
    if type(obj.blockTraffic) == 'number' and start.coords then
        AddZone(g, 'traffic', start.coords, obj.blockTraffic)
    end
    return g
end

local function Counts(run)
    local c = {
        entities = 0,
        armedAlive = 0,
        peds = 0,
        vehicles = 0,
        objects = 0,
        dead = 0,
        maxEntities = math.floor(Num(Config.Limits and Config.Limits.maxEntities, 80)),
        maxArmedAlive = math.floor(Num(Config.Limits and Config.Limits.maxArmedAlive, 25)),
    }
    local ok, list = Call('Runs', 'entitiesFor', run, nil)
    if not ok or type(list) ~= 'table' then return c end
    for _, e in ipairs(list) do
        c.entities = c.entities + 1
        if e.kind == 'ped' then
            c.peds = c.peds + 1
        elseif e.kind == 'vehicle' then
            c.vehicles = c.vehicles + 1
        else
            c.objects = c.objects + 1
        end
        if e.dead then
            c.dead = c.dead + 1
        elseif e.armed then
            local neutral = false
            if Has('Npc', 'isNeutralised') then
                local okN, res = Call('Npc', 'isNeutralised', e.netId)
                neutral = okN and res == true
            elseif Entity and e.entity and DoesEntityExist(e.entity) then
                local bag = Entity(e.entity).state.cp
                neutral = type(bag) == 'table' and (bag.state == 'cuffed' or bag.state == 'dead')
            end
            if not neutral then c.armedAlive = c.armedAlive + 1 end
        end
    end
    return c
end

local function DebugPayload(meta, run)
    local i, o, obj = CurrentObjective(run)
    local g = meta.geom or { points = {}, routes = {}, zones = {} }
    local waypoints = 0
    for _, r in ipairs(g.routes or {}) do waypoints = waypoints + #r.points end
    local okR, remaining = Call('Runs', 'remaining', run)
    local host = run.host and run.participants and run.participants[run.host]
    return {
        runId = run.id,
        missionId = meta.missionId,
        missionLabel = meta.missionLabel,
        locationIndex = meta.locationIndex,
        locationLabel = meta.locationLabel,
        state = run.state,
        tier = TierNameOf(run.tier) or run.expectedTier or meta.tier,
        objective = type(obj) == 'table' and {
            index = i,
            total = #(run.mission.objectives or {}),
            label = obj.label or CP.L('test.objective_n', { n = i }),
            block = obj.block,
            status = o and o.status or 'pending',
        } or false,
        counts = Counts(run),
        spawnPoints = #(g.points or {}),
        waypoints = waypoints,
        zones = #(g.zones or {}),
        startRadius = g.start and g.start.r or 0,
        host = run.host or false,
        hostName = host and host.name or false,
        remaining = (okR and tonumber(remaining)) and math.floor(remaining) or false,
        paused = run.timer and run.timer.paused == true or false,
        at = os.time(),
    }
end

local function SendDebug(meta, forceGeometry)
    local run = GetRun(meta.runId)
    if not run then return false end
    local key = ('%s:%s'):format(tostring(run.state), tostring(run.objectiveIndex))
    local withGeometry = forceGeometry or key ~= meta.geomKey or meta.geom == nil
    if withGeometry then
        meta.geom = Geometry(run)
        meta.geomKey = key
    end
    local payload = DebugPayload(meta, run)
    if withGeometry then payload.geometry = meta.geom end
    TriggerClientEvent(CP.e('client:test'), meta.admin, { controls = true, runId = run.id, debug = payload })
    return true
end

-- ============================================================================
--                                   CONTROLS
-- ============================================================================

local function ControlledRun(src, payload)
    local runId = byAdmin[src]
    if type(payload.runId) == 'string' and payload.runId ~= '' and payload.runId ~= runId then
        return nil, nil, 'err.test_not_controller'
    end
    local run = GetRun(runId)
    if not run then
        ClearStale(src)
        return nil, nil, 'err.test_no_active'
    end
    if type(run.test) ~= 'table' or ToSrc(run.test.adminSrc) ~= src then return nil, nil, 'err.test_not_controller' end
    return run, tests[run.id]
end

function Testing.control(src, payload)
    src = ToSrc(src)
    if not src then return false, 'err.not_in_game' end
    if type(payload) ~= 'table' or type(payload.control) ~= 'string' or not CONTROLS[payload.control] then
        return false, 'err.invalid_payload'
    end
    if payload.runId ~= nil and (type(payload.runId) ~= 'string' or #payload.runId > 64) then
        return false, 'err.invalid_payload'
    end
    local run, meta, errKey = ControlledRun(src, payload)
    if not run then return false, errKey end
    local control = payload.control

    if control == 'skip' or control == 'restart' then
        if run.state ~= 'in_progress' then return false, 'err.test_not_in_progress' end
        local fn = control == 'skip' and 'testSkip' or 'testRestart'
        local ok, res = Call('Runs', fn, run)
        if not ok or res == false then return false, 'err.test_control_failed' end
        if meta and meta.debug then SendDebug(meta, true) end
        return true, { control = control, objectiveIndex = run.objectiveIndex, state = run.state }
    elseif control == 'pause' or control == 'resume' then
        if run.state ~= 'in_progress' or not (run.timer and run.timer.running ~= false) then
            return false, 'err.test_not_in_progress'
        end
        local paused = control == 'pause'
        local ok = Call('Runs', 'pauseTimer', run, paused)
        if not ok then return false, 'err.test_control_failed' end
        return true, { control = control, paused = paused }
    elseif control == 'complete' then
        Audit(src, 'audit', 'testControl',
            meta and ('%s#%d'):format(meta.missionId, meta.locationIndex) or run.missionId, nil, 'complete', nil)
        local ok = Call('Runs', 'endRun', run, 'completed', 'completed')
        if not ok then return false, 'err.test_control_failed' end
        return true, { control = control }
    elseif control == 'fail' or control == 'end' then
        local reasonKey = control == 'fail' and 'test.fail_forced' or 'test.ended_by_admin'
        Audit(src, 'audit', 'testControl',
            meta and ('%s#%d'):format(meta.missionId, meta.locationIndex) or run.missionId, nil, control, nil)
        if meta then meta.endedBy = control end
        local ok
        if Has('Runs', 'failRun') then
            ok = Call('Runs', 'failRun', run, reasonKey)
        else
            run.failReason = reasonKey
            ok = Call('Runs', 'endRun', run, 'failed', 'mission_failed')
        end
        if not ok then return false, 'err.test_control_failed' end
        return true, { control = control }
    elseif control == 'teleport' then
        if Cfg().allowTeleport == false then return false, 'err.test_teleport_disabled' end
        if InArena(src) then return false, 'err.in_arena' end
        local target = payload.target
        if target ~= nil and target ~= 'start' and target ~= 'objective' then return false, 'err.invalid_payload' end
        if target == nil then target = run.state == 'in_progress' and 'objective' or 'start' end
        local coords
        if target == 'start' then
            coords = run.location and run.location.start and run.location.start.coords
        else
            local ok, anchor = Call('Runs', 'anchor', run)
            coords = ok and anchor or nil
        end
        local c = VecTable(coords)
        if not c then return false, 'err.test_control_failed' end
        CP.log(TAG, '%d teleports to the %s of test %s', src, target, run.id)
        return true, { control = control, target = target, coords = { x = c.x, y = c.y, z = c.z } }
    elseif control == 'debug' then
        if Cfg().debugOverlay == false then return false, 'err.test_debug_disabled' end
        if not meta then return false, 'err.test_no_active' end
        local enabled = payload.enabled
        if enabled == nil then enabled = not meta.debug end
        if type(enabled) ~= 'boolean' then return false, 'err.invalid_payload' end
        meta.debug = enabled
        if enabled then
            SendDebug(meta, true)
        else
            meta.geom, meta.geomKey = nil, nil
            TriggerClientEvent(CP.e('client:test'), src, { controls = true, runId = run.id, debug = false })
        end
        return true, { control = control, debug = enabled }
    end
    return false, 'err.invalid_payload'
end

-- ============================================================================
--                                 RUN END HOOK
-- ============================================================================

local function AddPending(meta, entry)
    local list = pending[meta.adminCid] or {}
    pending[meta.adminCid] = list
    table.insert(list, 1, entry)
    while #list > PENDING_MAX do table.remove(list) end
end

local function FinishTest(meta, run, state, endReason)
    tests[meta.runId] = nil
    if byAdmin[meta.admin] == meta.runId then byAdmin[meta.admin] = nil end
    local tier = meta.forcedTier or (run and TierNameOf(run.tier)) or (run and run.expectedTier) or meta.tier
    if meta.adminCid then
        AddPending(meta, {
            key = meta.runId,
            runId = meta.runId,
            missionId = meta.missionId,
            missionLabel = meta.missionLabel,
            locationIndex = meta.locationIndex,
            locationLabel = meta.locationLabel,
            tier = tier,
            testers = meta.testers,
            endState = state or 'abandoned',
            endReason = endReason or 'cancelled',
            endedBy = meta.endedBy or false,
            endedAt = os.time(),
            draft = meta.draft,
            version = meta.version,
            defHash = meta.defHash,
        })
    end
    TriggerClientEvent(CP.e('client:test'), meta.admin, { controls = false, runId = meta.runId, debug = false })
    if Online(meta.admin) then
        Notify(meta.admin, 'info', 'test.ended_record', { mission = meta.missionLabel })
        Push(meta.admin, 'test', { state = true })
    end
    CP.log(TAG, 'test %s of %s ended (%s, %s)', meta.runId, meta.missionId, tostring(state), tostring(endReason))
end

function Testing.onRunEnded(run, state, endReason)
    if type(run) ~= 'table' or type(run.id) ~= 'string' then return end
    local meta = tests[run.id]
    if not meta then return end
    FinishTest(meta, run, state, endReason or run.endReason)
end

-- ============================================================================
--                              RECORDING RESULTS
-- ============================================================================

local function FindPending(cid, missionId, locationIndex, tier)
    local list = pending[cid]
    if not list then return nil end
    local now = os.time()
    for i, e in ipairs(list) do
        if now - e.endedAt <= PENDING_KEEP and e.missionId == missionId and e.locationIndex == locationIndex
            and (tier == nil or e.tier == tier) then
            return e, i
        end
    end
    return nil
end

function Testing.record(src, payload)
    src = ToSrc(src)
    if not src then return false, 'err.not_in_game' end
    if type(payload) ~= 'table' then return false, 'err.invalid_payload' end
    local missionId = payload.missionId
    if type(missionId) ~= 'string' or #missionId > 40 or not missionId:match(MISSION_ID) then
        return false, 'err.invalid_payload'
    end
    local locationIndex = math.tointeger(tonumber(payload.location) or -1)
    if not locationIndex or locationIndex < 1 or locationIndex > 127 then return false, 'err.invalid_payload' end
    local tier = nil
    if payload.tier ~= nil and payload.tier ~= '' then
        tier = ValidTier(payload.tier)
        if not tier then return false, 'err.test_invalid_tier' end
    end
    local result = payload.result
    if result ~= 'passed' and result ~= 'failed' then return false, 'err.invalid_payload' end
    local note = payload.note
    if note ~= nil and type(note) ~= 'string' then return false, 'err.invalid_payload' end
    if type(note) == 'string' then
        if #note > NOTE_MAX * 4 then return false, 'err.invalid_payload' end
        note = U.trim(note)
        if note == '' then
            note = nil
        else
            note = ClipText(note, NOTE_MAX)
            if not note then return false, 'err.invalid_payload' end
        end
    end

    local cid = CitizenOf(src)
    if not cid then return false, 'err.test_no_character' end
    local entry, idx = FindPending(cid, missionId, locationIndex, tier)
    if not entry then return false, 'err.test_not_run' end
    local okP, errP
    if entry.draft then
        okP, errP = Can(src, 'builderEdit')
        if not okP then okP, errP = Can(src, 'testRun') end
    else
        okP, errP = Can(src, 'testRun')
    end
    if not okP then return false, errP or 'err.no_permission' end

    -- Claim the entry before the insert yields, so a double click cannot record it twice.
    table.remove(pending[cid], idx)
    if #pending[cid] == 0 then pending[cid] = nil end
    local tierName = ValidTier(entry.tier) or 'standard'
    local version = tonumber(entry.version) and math.floor(tonumber(entry.version)) or nil
    Db()
    local okI, id = pcall(MySQL.insert.await, [[
        INSERT INTO cp_mission_tests (mission_id, mission_version, location_index, tier, testers, result, note, tested_by, def_hash)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]], {
        missionId,
        version,
        locationIndex,
        tierName,
        math.max(1, math.min(127, math.floor(Num(entry.testers, 1)))),
        result,
        note,
        U.clip(cid, 50),
        entry.defHash and U.clip(tostring(entry.defHash), 40) or nil,
    })
    if not okI or not id then
        CP.err(TAG, 'recording the test of %s #%d failed: %s', missionId, locationIndex, tostring(id))
        local list = pending[cid] or {}
        pending[cid] = list
        table.insert(list, 1, entry)
        return false, 'err.internal'
    end

    local name = names[cid] or PlayerName(src)
    local target = ('%s#%d'):format(missionId, locationIndex)
    Audit(src, 'audit', entry.draft and 'recordDraftTest' or 'recordTest', target, nil,
        ('%s:%s'):format(result, tierName), note)
    if Has('Admin', 'webhook') then
        Call('Admin', 'webhook', 'builder', CP.L(
            result == 'passed' and 'test.webhook_passed' or 'test.webhook_failed',
            { mission = entry.missionLabel }
        ), CP.L('test.webhook_desc', {
            mission = entry.missionLabel,
            id = missionId,
            location = entry.locationLabel,
            n = locationIndex,
            tier = TierLabel(tierName),
            testers = entry.testers,
            name = name,
        }), {
            {
                name = CP.L('test.webhook_field_version'),
                value = version and tostring(version) or CP.L('test.webhook_builtin'),
                inline = true,
            },
            {
                name = CP.L('test.webhook_field_note'),
                value = note or CP.L('test.webhook_no_note'),
                inline = false,
            },
        })
    else
        WarnOnce('webhook', 'CP.Admin.webhook is not available: test results are not posted to the builder webhook')
    end
    if entry.draft then
        if Has('Builder', 'onDraftTested') then
            Call('Builder', 'onDraftTested', missionId, version, tierName, result == 'passed', src)
        else
            WarnOnce('builder',
                'CP.Builder.onDraftTested is not available: draft test results do not reach the builder')
        end
    end
    Push(src, 'test', { state = true })
    CP.log(TAG, '%s recorded %s for %s at %s (row %s)', cid, result, target, tierName, tostring(id))
    return true,
        {
            id = id,
            missionId = missionId,
            location = locationIndex,
            tier = tierName,
            result = result,
            draft = entry.draft == true,
        }
end

-- ============================================================================
--                                    VIEWS
-- ============================================================================

local function TypeOrder()
    local list = {}
    for key, t in pairs(Config.MissionTypes or {}) do list[#list + 1] = { key = key, points = Num(t.points, 0) } end
    table.sort(list, function(a, b)
        if a.points ~= b.points then return a.points < b.points end
        return a.key < b.key
    end)
    local out = {}
    for i, t in ipairs(list) do out[t.key] = i end
    return out
end

local function TesterNameOf(cid, stored)
    if type(stored) == 'string' and stored ~= '' then return stored end
    if names[cid] then return names[cid] end
    local ok, s = Call('Qbx', 'getByCitizenId', cid)
    if ok and ToSrc(s) then
        local okI, info = Call('Qbx', 'getInfo', ToSrc(s))
        if okI and type(info) == 'table' and type(info.name) == 'string' then
            names[cid] = info.name
            return info.name
        end
    end
    return cid
end

local function AllMissions()
    local byId = {}
    local ok, all = Call('Missions', 'all')
    if ok and type(all) == 'table' then
        for id, def in pairs(all) do
            if type(def) == 'table' then byId[def.id or id] = def end
        end
    end
    local okA, archived = Call('Builder', 'archivedDefs')
    if okA and type(archived) == 'table' then
        for _, raw in ipairs(archived) do
            if type(raw) == 'table' and type(raw.id) == 'string' and not byId[raw.id] then
                local d = EnsureNormalized(raw, 'archived')
                if d then d.status = 'archived'; byId[d.id] = d end
            end
        end
    elseif not Has('Builder', 'archivedDefs') then
        -- Fallback until the builder lists them: archived rows + their archived files.
        for _, row in ipairs(ArchivedRows()) do
            local id = row.id
            if type(id) == 'string' and #id <= 40 and id:match(MISSION_ID) and not byId[id] then
                local d = ArchivedMission(id, tonumber(row.published_version))
                if d then byId[id] = d end
            end
        end
    end
    return byId
end

function Testing.list()
    Db()
    local okQ, rows = pcall(MySQL.query.await, [[
        SELECT t.id, t.mission_id, t.mission_version, t.location_index, t.tier, t.testers, t.result, t.note,
               t.tested_by, t.def_hash, UNIX_TIMESTAMP(t.created_at) AS created_ts, last.n AS tests_n,
               o.display_name
        FROM cp_mission_tests t
        JOIN (SELECT MAX(id) AS id, COUNT(*) AS n FROM cp_mission_tests GROUP BY mission_id, location_index) last
          ON last.id = t.id
        LEFT JOIN cp_officers o ON o.citizenid = t.tested_by
    ]], {})
    if not okQ then
        CP.err(TAG, 'loading the test log failed: %s', tostring(rows))
        return nil, 'err.internal'
    end
    local last = {}
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do
        local idx = math.tointeger(U.num(r.location_index, -1))
        if r.mission_id and idx then last[r.mission_id .. '#' .. idx] = r end
    end

    local order = TypeOrder()
    local activeAt = {}
    for _, meta in pairs(tests) do activeAt[meta.missionId .. '#' .. meta.locationIndex] = true end
    local totals = { missions = 0, locations = 0, passed = 0, failed = 0, untested = 0, changed = 0 }
    local list = {}
    for id, def in pairs(AllMissions()) do
        local maxOfficers = math.floor(Num(def.maxOfficers, 1))
        local m = {
            id = id,
            label = def.label or id,
            type = def.type,
            typeLabel = (Config.MissionTypes and Config.MissionTypes[def.type] and Config.MissionTypes[def.type].label)
                or tostring(def.type),
            source = def.source == 'custom' and 'custom' or 'builtin',
            status = MissionStatus(def),
            disabled = IsDisabled(id),
            isBoss = def.isBoss == true,
            version = tonumber(def.version) or false,
            minOfficers = math.floor(Num(def.minOfficers, 1)),
            maxOfficers = maxOfficers,
            maxTier = TierFor(maxOfficers),
            defHash = def.defHash or false,
            editedInCode = def.editedInCode == true,
            locations = {},
            summary = { passed = 0, failed = 0, untested = 0, changed = 0 },
        }
        for i = 1, #(def.locations or {}) do
            local r = last[id .. '#' .. i]
            local loc = {
                index = i,
                label = LocationLabel(def, i),
                reserved = ReservedAt(id, i),
                active = activeAt[id .. '#' .. i] == true,
                status = 'untested',
                last = false,
            }
            if r then
                local rVersion = tonumber(r.mission_version)
                local changed = (r.def_hash == nil or r.def_hash == '' or r.def_hash ~= def.defHash)
                    or (def.source == 'custom' and tonumber(def.version) ~= nil and rVersion ~= tonumber(def.version))
                loc.last = {
                    id = U.num(r.id),
                    result = r.result == 'passed' and 'passed' or 'failed',
                    tier = tostring(r.tier),
                    testers = U.num(r.testers, 1),
                    note = r.note or false,
                    testedBy = tostring(r.tested_by),
                    testedByName = TesterNameOf(tostring(r.tested_by), r.display_name),
                    testedAt = U.num(r.created_ts, 0),
                    version = rVersion or false,
                    changed = changed,
                    tests = U.num(r.tests_n, 1),
                }
                loc.status = changed and 'changed' or loc.last.result
            end
            m.summary[loc.status] = m.summary[loc.status] + 1
            totals[loc.status] = totals[loc.status] + 1
            totals.locations = totals.locations + 1
            m.locations[#m.locations + 1] = loc
        end
        totals.missions = totals.missions + 1
        list[#list + 1] = m
    end
    table.sort(list, function(a, b)
        local oa, ob = order[a.type] or 99, order[b.type] or 99
        if oa ~= ob then return oa < ob end
        if a.isBoss ~= b.isBoss then return not a.isBoss end
        if a.label ~= b.label then return a.label < b.label end
        return a.id < b.id
    end)
    local tiers = {}
    for _, row in ipairs(TierRows()) do
        tiers[#tiers + 1] = { name = row.tier, label = TierLabel(row.tier), maxParticipants = row.maxParticipants }
    end
    local c = Cfg()
    return {
        missions = list,
        totals = totals,
        tiers = tiers,
        config = {
            enabled = c.enabled ~= false,
            maxTesters = MaxTesters(),
            useStartRoute = c.useStartRoute == true,
            allowTeleport = c.allowTeleport ~= false,
            debugOverlay = c.debugOverlay ~= false,
        },
        serverTime = os.time(),
    }
end

function Testing.candidates(src)
    local ok, list = Call('Qbx', 'getOnlinePlayers')
    local out = {}
    if not ok or type(list) ~= 'table' then return out end
    local lobby = lobbies[src]
    for _, s in ipairs(list) do
        s = ToSrc(s)
        if s and s ~= src and #out < MAX_CANDIDATES then
            local rec, role = TesterRecord(s)
            if rec then
                local okA, isAdmin = Call('Access', 'isAdmin', s)
                local inv = lobby and LobbyInviteFor(lobby, s) or nil
                out[#out + 1] = {
                    src = s,
                    name = rec.name or ('#' .. s),
                    callsign = rec.callsign or false,
                    rank = rec.rank or false,
                    departmentShort = rec.departmentShort or false,
                    role = role,
                    admin = okA and isAdmin == true,
                    onRun = OnMission(s),
                    inArena = InArena(s),
                    invite = inv and inv.status or false,
                }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.name ~= b.name then return tostring(a.name) < tostring(b.name) end
        return a.src < b.src
    end)
    return out
end

local function ActiveView(src)
    local runId = byAdmin[src]
    local run = GetRun(runId)
    local meta = runId and tests[runId]
    if not run or not meta then return false end
    local i, o, obj = CurrentObjective(run)
    local okR, remaining = Call('Runs', 'remaining', run)
    local participants = {}
    for _, s in ipairs(run.order or {}) do
        local p = run.participants[s]
        if p then
            participants[#participants + 1] = {
                src = s,
                name = p.name or ('#' .. s),
                callsign = p.callsign or false,
                departmentShort = p.departmentShort or false,
                status = p.status,
                arrived = p.arrived == true,
            }
        end
    end
    return {
        runId = run.id,
        missionId = meta.missionId,
        missionLabel = meta.missionLabel,
        locationIndex = meta.locationIndex,
        locationLabel = meta.locationLabel,
        state = run.state,
        tier = TierNameOf(run.tier) or run.expectedTier or meta.tier,
        forcedTier = meta.forcedTier or false,
        useStartRoute = meta.useStartRoute,
        draft = meta.draft,
        startedAt = meta.startedAt,
        remaining = (okR and tonumber(remaining)) and math.floor(remaining) or false,
        paused = run.timer and run.timer.paused == true or false,
        objective = (run.state == 'in_progress' and type(obj) == 'table') and {
            index = i,
            total = #(run.mission.objectives or {}),
            label = obj.label or CP.L('test.objective_n', { n = i }),
            status = o and o.status or 'pending',
        } or false,
        participants = participants,
        debug = meta.debug == true,
        allowTeleport = Cfg().allowTeleport ~= false,
        debugOverlay = Cfg().debugOverlay ~= false,
    }
end

function Testing.state(src)
    ExpireInvites()
    local cid = CitizenOf(src)
    local list = {}
    local now = os.time()
    for _, e in ipairs((cid and pending[cid]) or {}) do
        if now - e.endedAt <= PENDING_KEEP then
            list[#list + 1] = {
                key = e.key,
                missionId = e.missionId,
                missionLabel = e.missionLabel,
                locationIndex = e.locationIndex,
                locationLabel = e.locationLabel,
                tier = e.tier,
                testers = e.testers,
                endState = e.endState,
                endReason = e.endReason,
                endedBy = e.endedBy,
                endedAt = e.endedAt,
                draft = e.draft == true,
            }
        end
    end
    return {
        lobby = LobbyView(src),
        active = ActiveView(src),
        pending = list,
        invites = Testing.pendingInvites(src),
        serverTime = now,
    }
end

-- ============================================================================
--                                     NET
-- ============================================================================

local function Allowed(src, action)
    local ok, errKey = Can(src, action)
    if not ok then return false, errKey or 'err.no_permission' end
    return true
end

CP.Net.callback('admin:getTests', function(src)
    local ok, errKey = Allowed(src, 'testRun')
    if not ok then return nil, errKey end
    return Testing.list()
end, { rate = 3 })

-- Only the caller's own lobby, test and results: admins, and Mission Builder users (their draft tests).
CP.Net.callback('test:state', function(src)
    local ok, errKey = Allowed(src, 'testRun')
    if not ok and not Can(src, 'builderEdit') then return nil, errKey end
    return Testing.state(src)
end, { rate = 4 })

CP.Net.callback('test:candidates', function(src)
    local ok, errKey = Allowed(src, 'testRun')
    if not ok then return nil, errKey end
    return Testing.candidates(src)
end, { rate = 2 })

CP.Net.callback('test:pendingInvites', function(src)
    return Testing.pendingInvites(src)
end, { rate = 4 })

CP.Net.action('server:admin:startTest', function(src, payload)
    return Testing.start(src, payload)
end, { rate = 2 })

local function RecordHandler(src, payload)
    return Testing.record(src, payload)
end
CP.Net.action('server:admin:recordTest', RecordHandler, { rate = 2 })
CP.Net.action('server:test:record', RecordHandler, { rate = 2 })

CP.Net.action('server:test:control', function(src, payload)
    return Testing.control(src, payload)
end, { rate = 4 })

CP.Net.action('server:test:invite', function(src, payload)
    local ok, errKey = Allowed(src, 'testRun')
    if not ok then return false, errKey end
    if type(payload) ~= 'table' or type(payload.missionId) ~= 'string' or #payload.missionId > 40 then
        return false, 'err.invalid_payload'
    end
    return Testing.invite(src, payload.targets, { missionId = payload.missionId })
end, { rate = 2 })

CP.Net.action('server:test:cancelInvites', function(src)
    local ok, errKey = Allowed(src, 'testRun')
    if not ok then return false, errKey end
    return Testing.cancelInvites(src)
end, { rate = 2 })

CP.Net.action('server:testRespond', function(src, payload)
    return Testing.respond(src, payload)
end, { rate = 3 })

-- ============================================================================
--                                  LIFECYCLE
-- ============================================================================

AddEventHandler('playerDropped', function()
    local src = source
    src = ToSrc(src)
    if not src then return end
    lastStart[src] = nil
    CloseLobby(src, 'withdrawn', 'test.invite_withdrawn')
    for id, inv in pairs(invites) do
        if inv.target == src and (inv.status == 'pending' or inv.status == 'accepted') then
            inv.status = 'expired'
            inv.answeredAt = os.time()
            Push(inv.admin, 'invites', { test = true })
        elseif inv.target == src then
            ForgetInvite(id)
        end
    end
    -- The admin who started a test left: end it for the testers (nothing is saved anyway).
    local runId = byAdmin[src]
    if runId then
        SetTimeout(0, function()
            local run = GetRun(runId)
            local meta = tests[runId]
            if run and meta then
                meta.endedBy = 'admin_left'
                for _, s in ipairs(run.order or {}) do
                    local p = run.participants[s]
                    if p and p.status == 'active' and s ~= src then Notify(s, 'warning', 'test.ended_admin_left') end
                end
                if Has('Runs', 'failRun') then
                    Call('Runs', 'failRun', run, 'test.ended_admin_left')
                else
                    run.failReason = 'test.ended_admin_left'
                    Call('Runs', 'endRun', run, 'failed', 'mission_failed')
                end
            end
            if tests[runId] then FinishTest(tests[runId], run, 'failed', 'mission_failed') end
            byAdmin[src] = nil
        end)
    end
end)

CreateThread(function()
    local sinceDebug, sinceMaintenance = 0, 0
    while true do
        Wait(1000)
        sinceDebug = sinceDebug + 1000
        sinceMaintenance = sinceMaintenance + 1000
        if sinceDebug >= DEBUG_EVERY_MS then
            sinceDebug = 0
            for runId, meta in pairs(tests) do
                if meta.debug then
                    local ok, res = pcall(SendDebug, meta, false)
                    if not ok then CP.err(TAG, 'debug stream of %s failed: %s', runId, tostring(res)) end
                end
            end
        end
        if sinceMaintenance >= MAINTENANCE_EVERY_MS then
            sinceMaintenance = 0
            local ok, err = pcall(ExpireInvites)
            if not ok then CP.err(TAG, 'invitation upkeep failed: %s', tostring(err)) end
            -- A test whose run vanished without the onRunEnded hook (safety net).
            for runId, meta in pairs(tests) do
                if not GetRun(runId) then FinishTest(meta, nil, 'abandoned', 'cancelled') end
            end
            local now = os.time()
            for cid, list in pairs(pending) do
                for i = #list, 1, -1 do
                    if now - list[i].endedAt > PENDING_KEEP then table.remove(list, i) end
                end
                if #list == 0 then pending[cid] = nil end
            end
        end
    end
end)

-- Test hooks (tests/testing_spec.lua only).
Testing._geometry = Geometry
Testing._counts = Counts
Testing._validTier = ValidTier
Testing._adminRecord = AdminRecord
Testing._reset = function()
    invites, lobbies, tests, byAdmin, pending, lastStart, names = {}, {}, {}, {}, {}, {}, {}
end
Testing._tests = function() return tests end
Testing._pending = function() return pending end
