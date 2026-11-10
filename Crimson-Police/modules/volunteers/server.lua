-- CP.Volunteers (server): the volunteer list behind Config.Volunteers.command (default /crimsonheat). A

-- CP.Volunteers (server): the volunteer list behind Config.Volunteers.command (default /crimsonheat). A
-- player who is not on police duty agrees to the rules, picks the suspects he will play and stays on the list for
-- Config.Volunteers.windowMinutes; he renews, changes his picks or stops from the same command. The server decides
-- everything: who may volunteer (CP.Opponents.eligible, an admin's exclusion, strikes), when the window ends and why.
-- No matching here: later steps read CP.Volunteers.list() and give strikes with CP.Volunteers.strike().

CP.Volunteers = CP.Volunteers or {}
local V = CP.Volunteers
local TAG = 'volunteers'

local ROLES = { 'runner', 'driver', 'fugitive' }   -- the suspects a volunteer can play (§7.3 volunteerSlot roles)
local SWEEP_MS = 30000                             -- the window and duty check, only while someone volunteers
local AFK_KEY = 'volunteers'                       -- CP.Opponents.sampleCrew key: AFK samples of every volunteer

local listed = {}       -- [citizenid] = { cid, src, who, name, roles = { [role] = true }, since, untilAt } (os.time)
local cidOf = {}        -- [server id] = citizenid of a listed volunteer
local whoOf = {}        -- [citizenid] = the player key strikes are kept under (his license, else 'cid:<citizenid>')
local strikesOf = {}    -- [who] = { os.time(), ... } strikes within strikeHours
local blockedUntil = {} -- [who] = os.time() the strikes block ends
local sweep = { on = false, token = 0 }
local reserved = {} -- [holder: a run id or a pending accept's token] = citizenid of the volunteer it counts on
local slotCache = setmetatable({}, { __mode = 'k' }) -- [mission definition] = { [location index] = slot | false }

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function Cfg() return Config.Volunteers or {} end

local function On() return Cfg().enabled == true end

local function Num(v, default, lo, hi)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then v = default end
    if lo and v < lo then v = lo end
    if hi and v > hi then v = hi end
    return v
end

local function WindowSeconds() return math.floor(Num(Cfg().windowMinutes, 60, 1, 1440) * 60) end

local function MaxStrikes() return math.floor(Num(Cfg().strikes, 3, 1, 100)) end

local function Note(src, kind, key, vars)
    if src then TriggerClientEvent(CP.e('client:volunteerNote'), src, kind, key, vars) end
end

local function WhoOf(info)
    if type(info.license) == 'string' and info.license ~= '' then return info.license end
    return 'cid:' .. tostring(info.citizenid)
end

-- The roles picked, in ROLES order -> { [role] = true } or nil when none is valid.
local function RolesOf(v)
    if type(v) ~= 'table' then return nil end
    local out, any = {}, false
    for _, role in ipairs(ROLES) do
        if v[role] == true then out[role], any = true, true end
    end
    return any and out or nil
end

local function RoleList(roles)
    local out = {}
    for _, role in ipairs(ROLES) do
        if roles and roles[role] then out[#out + 1] = role end
    end
    return out
end

-- Strikes still inside strikeHours (older ones dropped) -> the count.
local function StrikeCount(who, now)
    local list = strikesOf[who]
    if not list then return 0 end
    local since = now - math.floor(Num(Cfg().strikeHours, 24, 1, 8760) * 3600)
    local kept = {}
    for _, at in ipairs(list) do
        if at > since then kept[#kept + 1] = at end
    end
    strikesOf[who] = #kept > 0 and kept or nil
    return #kept
end

local function BlockedAt(who, now)
    local t = blockedUntil[who]
    if t and t > now then return t end
    blockedUntil[who] = nil
    return nil
end

-- ============================================================================
--                         SAVED STRIKES (cp_pvp_pairs)
-- ============================================================================
-- Each strike is a vol_strike row and each strikes block a vol_block row of cp_pvp_pairs (the player key in
-- suspect_license), written when it happens and read back once at the start, so a restart keeps them. Only while
-- volunteers are on and Config.Volunteers.saveStrikes is not false. The list itself stays memory only.

local saved = { loaded = false, loading = false }

local function SaveOn() return On() and Cfg().saveStrikes ~= false end

local function DbReady()
    if not (CP.Migrations and CP.Migrations.ready) then return true end
    local ok = pcall(CP.Migrations.ready)
    return ok
end

local function StrikeSeconds() return math.floor(Num(Cfg().strikeHours, 24, 1, 8760) * 3600) end

local SAVE_ROW = [[INSERT INTO cp_pvp_pairs (kind, officer_citizenid, suspect_citizenid, suspect_license, until_at,
    created_at) VALUES (?, '', ?, ?, FROM_UNIXTIME(?), FROM_UNIXTIME(?))]]

-- A strike (blockUntil nil) or the block it led to (its strikes are removed), in a thread.
local function SaveStrike(cid, who, at, blockUntil)
    if not SaveOn() then return end
    CreateThread(function()
        if not DbReady() then return end
        local ok, err
        if blockUntil then
            ok, err = pcall(MySQL.update.await,
                'DELETE FROM cp_pvp_pairs WHERE kind = \'vol_strike\' AND suspect_license = ?', { who })
            if ok then ok, err = pcall(MySQL.insert.await, SAVE_ROW, { 'vol_block', cid, who, blockUntil, at }) end
        else
            ok, err = pcall(MySQL.insert.await, SAVE_ROW, { 'vol_strike', cid, who, at + StrikeSeconds(), at })
        end
        if not ok then CP.err(TAG, 'saving the strike of %s failed: %s', cid, tostring(err)) end
    end)
end

-- Strikes past strikeHours and blocks that ran out (the start and once a day).
local function PruneStrikes(now)
    if not DbReady() then return end
    local ok, err = pcall(MySQL.update.await,
        'DELETE FROM cp_pvp_pairs WHERE kind = \'vol_strike\' AND created_at <= FROM_UNIXTIME(?)',
        { now - StrikeSeconds() })
    if ok then
        ok, err = pcall(MySQL.update.await,
            'DELETE FROM cp_pvp_pairs WHERE kind = \'vol_block\' AND until_at <= FROM_UNIXTIME(?)', { now })
    end
    if not ok then CP.err(TAG, 'the strikes clean-up failed: %s', tostring(err)) end
end

local function LoadStrikes(now)
    local ok, rows = pcall(MySQL.query.await, [[SELECT kind, suspect_license, UNIX_TIMESTAMP(created_at) AS created_ts,
        UNIX_TIMESTAMP(until_at) AS until_ts FROM cp_pvp_pairs WHERE kind IN ('vol_strike', 'vol_block')]])
    if not ok then
        CP.err(TAG, 'reading the saved strikes failed: %s', tostring(rows))
        return false
    end
    local n = 0
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do
        local who = r.suspect_license
        local at, untilAt = math.floor(Num(r.created_ts, 0)), math.floor(Num(r.until_ts, 0))
        if type(who) == 'string' and who ~= '' then
            if r.kind == 'vol_strike' and at > now - StrikeSeconds() then
                local list = strikesOf[who] or {}
                list[#list + 1] = at
                table.sort(list)
                strikesOf[who] = list
                n = n + 1
            elseif r.kind == 'vol_block' and untilAt > now and untilAt > (blockedUntil[who] or 0) then
                blockedUntil[who] = untilAt
                n = n + 1
            end
        end
    end
    if n > 0 then CP.log(TAG, '%d saved strike(s) and block(s) read back', n) end
    return true
end

-- Once, the first time saving is on (the start, or an admin turning volunteers on in Settings).
local function StartStrikes()
    if saved.loaded or saved.loading or not SaveOn() then return end
    saved.loading = true
    CreateThread(function()
        if DbReady() then
            local now = os.time()
            PruneStrikes(now)
            saved.loaded = LoadStrikes(now)
        end
        saved.loading = false
    end)
end

-- ============================================================================
--                                   THE LIST
-- ============================================================================

local function DeptDuty(info)
    local job = info and info.job
    if type(job) ~= 'table' or job.onduty ~= true or type(job.name) ~= 'string' or not CP.Access then return false end
    if CP.Access.departmentForJob and CP.Access.departmentForJob(job.name) then return true end
    return CP.Access.offDepartmentForJob ~= nil and CP.Access.offDepartmentForJob(job.name) ~= nil
end

-- Takes the volunteer off the list. why: stopped, expired, on_duty, excluded, strikes, disabled, left. Everyone but
-- one who left is told why.
local function End(cid, why)
    local v = listed[cid]
    if not v then return false end
    listed[cid] = nil
    if v.src and cidOf[v.src] == cid then cidOf[v.src] = nil end
    for holder, held in pairs(reserved) do
        if held == cid then reserved[holder] = nil end
    end
    if CP.Opponents and CP.Opponents.unsampleCrew then pcall(CP.Opponents.unsampleCrew, AFK_KEY, { cid }) end
    if why ~= 'left' then Note(v.src, why == 'stopped' and 'inform' or 'warning', 'volunteer.ended.' .. why) end
    CP.log(TAG, '%s stopped volunteering (%s)', cid, why)
    return true
end

local function Sweep()
    local now = os.time()
    for cid, v in pairs(listed) do
        if not On() then
            End(cid, 'disabled')
        elseif now >= v.untilAt and not (V.matchOf and V.matchOf(cid)) then
            End(cid, 'expired')  -- never while he plays a suspect: the window ends after the case
        elseif CP.Opponents and CP.Opponents.excluded and CP.Opponents.excluded(cid) then
            End(cid, 'excluded')
        elseif BlockedAt(v.who, now) then
            End(cid, 'strikes')
        elseif DeptDuty(CP.Qbx and CP.Qbx.getInfo and v.src and CP.Qbx.getInfo(v.src)) then
            End(cid, 'on_duty')
        end
    end
end

local function StartSweep()
    if sweep.on then return end
    sweep.on = true
    sweep.token = sweep.token + 1
    local token = sweep.token
    CreateThread(function()
        while sweep.token == token and next(listed) ~= nil do
            Wait(CP.Perf.ms(SWEEP_MS))
            if sweep.token ~= token then return end
            local ok, err = pcall(Sweep)
            if not ok then CP.err(TAG, 'the volunteer check failed: ' .. tostring(err)) end
        end
        if sweep.token == token then sweep.on = false end
    end)
end

-- ============================================================================
--                                   THE API
-- ============================================================================

-- Whether src may volunteer now -> ok, reason, info, untilAt. Reasons: off, not_loaded, the CP.Opponents.eligible
-- reasons (in_case, instance, arena_flag, on_duty, job_hop, afk, admin, excluded), excluded (an admin's Exclude),
-- blocked (strikes; untilAt = when the block ends).
function V.check(src)
    if not On() then return false, 'off' end
    local n = CP.U.toSrc(src)
    local info = n and CP.Qbx and CP.Qbx.getInfo and CP.Qbx.getInfo(n) or nil
    if type(info) ~= 'table' or type(info.citizenid) ~= 'string' or info.citizenid == '' then
        return false, 'not_loaded'
    end
    local Opp = CP.Opponents
    if Opp and Opp.eligible then
        local ok, why = Opp.eligible(n)
        if not ok then return false, why or 'not_loaded', info end
    end
    if Opp and Opp.excluded and Opp.excluded(info.citizenid) then return false, 'excluded', info end
    local now = os.time()
    local untilAt = BlockedAt(WhoOf(info), now) or BlockedAt('cid:' .. info.citizenid, now)
    if untilAt then return false, 'blocked', info, untilAt end
    return true, nil, info
end

-- Puts src on the list for windowMinutes -> true, untilAt | false, reason.
function V.join(src, roles)
    local n = CP.U.toSrc(src)
    local ok, why, info, untilAt = V.check(n)
    if not ok then return false, why, untilAt end
    local cid = info.citizenid
    if listed[cid] then return false, 'already' end
    local picked = RolesOf(roles)
    if not picked then return false, 'no_role' end
    local now = os.time()
    local old = cidOf[n]
    if old and old ~= cid then End(old, 'left') end
    local who = WhoOf(info)
    whoOf[cid] = who
    listed[cid] = {
        cid = cid,
        src = n,
        who = who,
        name = info.name,
        roles = picked,
        since = now,
        untilAt = now + WindowSeconds(),
    }
    cidOf[n] = cid
    if CP.Opponents and CP.Opponents.sampleCrew then pcall(CP.Opponents.sampleCrew, AFK_KEY, { cid }) end
    StartSweep()
    CP.log(TAG, '%s volunteers (%s)', cid, table.concat(RoleList(picked), ', '))
    return true, listed[cid].untilAt
end

-- A fresh window from now, after the same checks as joining -> true, untilAt | false, reason.
function V.renew(src)
    local n = CP.U.toSrc(src)
    local cid = n and cidOf[n]
    local v = cid and listed[cid]
    if not v then return false, 'not_listed' end
    local ok, why, _, untilAt = V.check(n)
    if not ok then return false, why, untilAt end
    v.untilAt = os.time() + WindowSeconds()
    return true, v.untilAt
end

-- Changes the suspects a volunteer plays -> true | false, reason.
function V.setRoles(src, roles)
    local n = CP.U.toSrc(src)
    local v = n and cidOf[n] and listed[cidOf[n]]
    if not v then return false, 'not_listed' end
    local picked = RolesOf(roles)
    if not picked then return false, 'no_role' end
    v.roles = picked
    return true
end

-- The volunteer stops himself -> true | false, 'not_listed'.
function V.stop(src)
    local n = CP.U.toSrc(src)
    local cid = n and cidOf[n]
    if not cid or not listed[cid] then return false, 'not_listed' end
    End(cid, 'stopped')
    return true
end

-- A strike for this citizenid (later steps: a no-show, walking away from a case he said yes to). Reaching
-- Config.Volunteers.strikes within strikeHours blocks the player for blockHours and ends his listing.
-- -> count, blockedUntil|nil.
function V.strike(cid, why)
    if type(cid) ~= 'string' or cid == '' then return 0 end
    local who = whoOf[cid] or ('cid:' .. cid)
    local now = os.time()
    local list = strikesOf[who] or {}
    list[#list + 1] = now
    strikesOf[who] = list
    local count = StrikeCount(who, now)
    local v = listed[cid]
    CP.log(TAG, 'strike %d for %s (%s)', count, cid, tostring(why))
    if count >= MaxStrikes() then
        strikesOf[who] = nil
        local untilAt = now + math.floor(Num(Cfg().blockHours, 24, 1, 8760) * 3600)
        blockedUntil[who] = untilAt
        SaveStrike(cid, who, now, untilAt)
        for other, entry in pairs(listed) do
            if entry.who == who then End(other, 'strikes') end
        end
        return count, untilAt
    end
    SaveStrike(cid, who, now, nil)
    if v then Note(v.src, 'warning', 'volunteer.strike', { count = count, max = MaxStrikes() }) end
    return count, nil
end

function V.isListed(cid) return listed[cid] ~= nil end

-- The citizenid of the listed volunteer at server id src, or nil (for the volunteer's answer and cancel).
function V.cidBySrc(src)
    local n = CP.U.toSrc(src)
    return n and cidOf[n] or nil
end

-- Every volunteer on the list, as copies: { cid, src, name, roles = { role, ... }, since, untilAt }.
function V.list()
    local out = {}
    for cid, v in pairs(listed) do
        out[#out + 1] = {
            cid = cid,
            src = v.src,
            name = v.name,
            roles = RoleList(v.roles),
            since = v.since,
            untilAt = v.untilAt,
        }
    end
    table.sort(out, function(a, b) return a.since < b.since or (a.since == b.since and a.cid < b.cid) end)
    return out
end

-- Strikes within strikeHours of this citizenid's player.
function V.strikes(cid)
    return StrikeCount(whoOf[cid] or ('cid:' .. tostring(cid)), os.time())
end

-- An admin clears this citizenid's player's strikes and strike block: memory at once, the saved rows in a
-- thread. The player key is his license (the one he volunteered under, else Qbox's players table).
-- -> true, { strikes, blockedUntil } | false, 'no_row'.
function V.clearStrikes(cid)
    if type(cid) ~= 'string' or cid == '' then return false, 'no_row' end
    local keys, seen = {}, {}
    local function add(who)
        if type(who) == 'string' and who ~= '' and not seen[who] then
            seen[who] = true
            keys[#keys + 1] = who
        end
    end
    add(whoOf[cid])
    if not whoOf[cid] and CP.Qbx and CP.Qbx.licenseOf then add(CP.Qbx.licenseOf(cid)) end
    add('cid:' .. cid)
    local now, count, blocked = os.time(), 0, nil
    for _, who in ipairs(keys) do
        count = count + StrikeCount(who, now)
        local untilAt = BlockedAt(who, now)
        if untilAt and untilAt > (blocked or 0) then blocked = untilAt end
    end
    if count == 0 and not blocked then return false, 'no_row' end
    for _, who in ipairs(keys) do
        strikesOf[who], blockedUntil[who] = nil, nil
    end
    CreateThread(function()
        if not DbReady() then return end
        for _, who in ipairs(keys) do
            local ok, err = pcall(MySQL.update.await,
                'DELETE FROM cp_pvp_pairs WHERE kind IN (\'vol_strike\', \'vol_block\') AND suspect_license = ?',
                { who })
            if not ok then CP.err(TAG, 'clearing the saved strikes of %s failed: %s', cid, tostring(err)) end
        end
    end)
    CP.log(TAG, 'strikes of %s cleared (%d strike(s)%s)', cid, count, blocked and ', a block' or '')
    return true, { strikes = count, blockedUntil = blocked }
end

-- His strikes and block for the criminal tablet's History: { strikes = { expiresAt (os.time), ... } oldest first,
-- blockedUntil = os.time() or nil, strikeHours }. Every key of his player (license and citizenid), like clearStrikes.
function V.strikeInfo(cid)
    local out = { strikes = {}, strikeHours = math.floor(Num(Cfg().strikeHours, 24, 1, 8760)) }
    if type(cid) ~= 'string' or cid == '' then return out end
    local now, seen = os.time(), {}
    for _, who in ipairs({ whoOf[cid], 'cid:' .. cid }) do
        if not seen[who] then
            seen[who] = true
            StrikeCount(who, now)
            for _, at in ipairs(strikesOf[who] or {}) do out.strikes[#out.strikes + 1] = at + StrikeSeconds() end
            local untilAt = BlockedAt(who, now)
            if untilAt and untilAt > (out.blockedUntil or 0) then out.blockedUntil = untilAt end
        end
    end
    table.sort(out.strikes)
    return out
end

-- What the criminal tablet's Home shows: { listed, untilAt, roles = { role, ... }, windowMinutes, maxStrikes }.
function V.listingOf(src)
    local n = CP.U.toSrc(src)
    local cid = n and cidOf[n]
    local v = cid and listed[cid]
    return {
        listed = v ~= nil,
        untilAt = v and v.untilAt or nil,
        roles = v and RoleList(v.roles) or {},
        windowMinutes = math.floor(WindowSeconds() / 60),
        maxStrikes = MaxStrikes(),
    }
end

V.roles = ROLES
V.endListing = End
V._sweep = Sweep

-- ============================================================================
--                        MODES, SLOTS AND AVAILABILITY
-- ============================================================================
-- Who plays a mission's suspect a volunteer can play: Config.Volunteers.missionModes (by mission id), else modes (by
-- mission type), else 'npc'. A mission can take a volunteer when one of its objectives' blocks offers a slot
-- (volunteerSlot, §7.3) at that location. Matching and the pop-up are in modules/volunteers/match; here CP.Draw only asks who is free.

local MODES = { npc = true, players_when_available = true, players_only = true }
V.modes = { 'npc', 'players_when_available', 'players_only' }

local function ModeValue(v) return type(v) == 'string' and MODES[v] and v or nil end

-- The mode of a mission definition: 'npc' while enabled is off and for the Weekly Boss; a value that is no mode
-- counts as 'npc' (the start-up check names it).
function V.modeOf(def)
    if not On() or type(def) ~= 'table' or def.isBoss then return 'npc' end
    local c = Cfg()
    local byMission = type(c.missionModes) == 'table' and c.missionModes or {}
    if byMission[def.id] ~= nil then return ModeValue(byMission[def.id]) or 'npc' end
    local byType = type(c.modes) == 'table' and c.modes or {}
    return ModeValue(byType[def.type]) or 'npc'
end

local function RoleOk(role)
    for _, r in ipairs(ROLES) do
        if r == role then return true end
    end
    return false
end

-- The slot of location #index: the first objective whose block's volunteerSlot(obj, mission, location) answers a
-- table with a role a volunteer can pick -> a copy with obj = the objective's number, or nil. Cached per definition.
local function SlotAt(def, index)
    local locs = type(def) == 'table' and type(def.locations) == 'table' and def.locations or {}
    local location = locs[index]
    if type(location) ~= 'table' or type(def.objectives) ~= 'table' then return nil end
    local byIndex = slotCache[def]
    if not byIndex then
        byIndex = {}
        slotCache[def] = byIndex
    end
    if byIndex[index] ~= nil then return byIndex[index] or nil end
    local found = false
    for i, obj in ipairs(def.objectives) do
        local impl = type(obj) == 'table' and CP.Blocks and CP.Blocks.get and CP.Blocks.get(obj.block) or nil
        if impl and type(impl.volunteerSlot) == 'function' then
            local ok, slot = pcall(impl.volunteerSlot, obj, def, location)
            if not ok then
                CP.err(TAG, '%s volunteerSlot failed for %s: %s', tostring(obj.block), tostring(def.id), tostring(slot))
            elseif type(slot) == 'table' and RoleOk(slot.role) then
                found = CP.U.copy(slot)
                found.obj = i
                break
            end
        end
    end
    byIndex[index] = found
    return found or nil
end

-- The slot of location #index (a copy), or nil when nobody but the NPC can play that location's suspect.
function V.slotOf(def, index)
    local slot = SlotAt(def, math.tointeger(tonumber(index) or 0) or 0)
    return slot and CP.U.copy(slot) or nil
end

-- The roles the mission's locations offer -> { [role] = true }, and the set of location indices with no slot.
function V.slotRoles(def)
    local roles, none = {}, {}
    local locs = type(def) == 'table' and type(def.locations) == 'table' and def.locations or {}
    for i = 1, #locs do
        local slot = SlotAt(def, i)
        if slot then roles[slot.role] = true else none[i] = true end
    end
    return roles, none
end

-- Whether any location of the mission has a slot.
function V.canTake(def) return next((V.slotRoles(def))) ~= nil end

-- Volunteers on the list who play one of roles (a set; nil = any) and are not held by an accept, oldest first ->
-- { citizenid, ... }. Empty while enabled is off.
function V.available(roles)
    local out = {}
    if not On() then return out end
    local held = {}
    for _, cid in pairs(reserved) do held[cid] = true end
    local now = os.time()
    for _, v in ipairs(V.list()) do
        local fits = roles == nil
        for _, role in ipairs(v.roles) do
            if roles and roles[role] then fits = true end
        end
        -- a window that has ended counts at once, not only at the next sweep (30 s x loopScale)
        if fits and not held[v.cid] and now < (v.untilAt or 0) then out[#out + 1] = v.cid end
    end
    return out
end

-- The draw's gate for one mission: true, or false and why ('real_suspect': a 'players_only' mission for a unit that
-- did not tick "Real suspect OK"; 'no_slot': nobody but the NPC can play it; 'no_volunteer': nobody who fits is free).
-- realOk: the unit ticked "Real suspect OK". Only 'players_only' ever closes a mission.
function V.drawGate(def, realOk)
    if V.modeOf(def) ~= 'players_only' then return true end
    if realOk ~= true then return false, 'real_suspect' end
    local roles = V.slotRoles(def)
    if next(roles) == nil then return false, 'no_slot' end
    if #V.available(roles) == 0 then return false, 'no_volunteer' end
    return true
end

-- What a Mission Board card says about real suspects, from the card's pool (drawn with "Real suspect OK" ticked):
-- nil when no mission of it plays a volunteer, else { required = every mission needs the tick, available = how
-- many volunteers who fit are free }.
function V.cardInfo(list)
    local roles, any, required = {}, false, true
    for _, def in ipairs(type(list) == 'table' and list or {}) do
        local mode = V.modeOf(def)
        local own = V.slotRoles(def)
        if mode ~= 'npc' and next(own) ~= nil then
            any = true
            for r in pairs(own) do roles[r] = true end
        end
        if mode ~= 'players_only' then required = false end
    end
    if not any then return nil end
    return { required = required, available = #V.available(roles) }
end

-- Holds a volunteer who fits location #index's slot for holder (a 'players_only' accept), so another unit cannot
-- count on him too -> citizenid | nil. He must still pass check (on duty, AFK, in a case ...).
function V.reserve(holder, def, index)
    if holder == nil or not On() then return nil end
    local slot = SlotAt(def, math.tointeger(tonumber(index) or 0) or 0)
    if not slot then return nil end
    for _, cid in ipairs(V.available({ [slot.role] = true })) do
        local v = listed[cid]
        if v and V.check(v.src) then
            reserved[holder] = cid
            CP.log(TAG, '%s held for %s (%s)', cid, tostring(holder), slot.role)
            return cid
        end
    end
    return nil
end

-- Holds this volunteer for holder (the run that asks him), so nobody else asks or counts on him meanwhile.
function V.hold(holder, cid)
    if holder == nil or not listed[cid] then return false end
    reserved[holder] = cid
    return true
end

-- The hold moves from a pending accept's token to its run id.
function V.rekey(old, new)
    if old == nil or new == nil or reserved[old] == nil then return false end
    reserved[new], reserved[old] = reserved[old], nil
    return true
end

function V.release(holder)
    if holder == nil or reserved[holder] == nil then return false end
    reserved[holder] = nil
    return true
end

-- The citizenid held for holder (a run id), or nil.
function V.reservedFor(holder) return holder ~= nil and reserved[holder] or nil end

-- A run that ends lets its volunteer go.
CP.Hooks.on('run:ended', function(run)
    if type(run) == 'table' then V.release(run.id) end
end)

-- The start-up check (Admin UI -> Permissions -> Config health, and the console once): modes that name no mission
-- type or mission, values that are no mode, and a mode other than 'npc' on missions none of whose blocks offers a
-- slot (they keep playing the NPC; a 'players_only' one is never offered).
local function ModesHealth()
    local out = {}
    local function Line(level, key, vars, fix)
        out[#out + 1] = { level = level, text = CP.L(key, vars), fix = fix }
    end
    if not On() then
        Line('ok', 'health.volunteers.off')
        return out
    end
    local c = Cfg()
    local types = type(Config.MissionTypes) == 'table' and Config.MissionTypes or {}
    local all = CP.Missions and CP.Missions.list and CP.Missions.list() or {}
    local function Check(map, fix, known, missionsOf)
        local keys = {}
        for k in pairs(type(map) == 'table' and map or {}) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local mode = map[k]
            if not known(k) then
                Line('warn', 'health.volunteers.unknown', { key = k }, fix)
            elseif not ModeValue(mode) then
                Line('warn', 'health.volunteers.bad_mode', { key = k, mode = tostring(mode) }, fix)
            elseif mode ~= 'npc' then
                local any = false
                for _, def in ipairs(missionsOf(k)) do
                    if V.modeOf(def) == mode and V.canTake(def) then any = true end
                end
                if not any then
                    local which = mode == 'players_only' and 'health.volunteers.no_slot_only'
                        or 'health.volunteers.no_slot'
                    Line('warn', which, { key = k }, fix)
                end
            end
        end
    end
    Check(c.modes, 'Volunteers.modes', function(k) return type(types[k]) == 'table' end, function(k)
        local list = {}
        for _, def in ipairs(all) do
            if type(def) == 'table' and def.type == k and not def.isBoss then list[#list + 1] = def end
        end
        return list
    end)
    Check(c.missionModes, 'Volunteers.missionModes', function(k)
        return CP.Missions and CP.Missions.get and CP.Missions.get(k) ~= nil
    end, function(k) return { CP.Missions.get(k) } end)
    local n = 0
    for _, def in ipairs(all) do
        if type(def) == 'table' and V.modeOf(def) ~= 'npc' and V.canTake(def) then n = n + 1 end
    end
    table.insert(out, 1, { level = 'ok', text = CP.L('health.volunteers.ok', { n = n }) })
    return out
end
V._modesHealth = ModesHealth

CreateThread(function()
    if CP.ConfigHealth and CP.ConfigHealth.register then CP.ConfigHealth.register('volunteers', ModesHealth) end
end)

-- ============================================================================
--                             THE COMMAND'S EVENT
-- ============================================================================

-- What the command's menu shows: on the list (minutes left and his picks) or the start (the window and strikes).
local function MenuOf(src, info)
    local cid = cidOf[src]
    local v = cid and listed[cid]
    local strikes = V.strikes(cid or info.citizenid)
    if v then
        local m = V.matchOf and V.matchOf(cid) or nil
        return {
            active = true,
            minutesLeft = math.max(1, math.ceil((v.untilAt - os.time()) / 60)),
            roles = RoleList(v.roles),
            strikes = strikes,
            maxStrikes = MaxStrikes(),
            -- the suspect he plays now (Cancel this case), never the run or where it is
            case = m and m.phase ~= 'asking' and { phase = m.phase, role = m.role } or nil,
        }
    end
    return {
        active = false,
        minutes = math.floor(WindowSeconds() / 60),
        roles = ROLES,
        strikes = strikes,
        maxStrikes = MaxStrikes(),
    }
end

local REFUSAL = {
    off = true,
    not_loaded = true,
    in_case = true,
    instance = true,
    arena_flag = true,
    on_duty = true,
    job_hop = true,
    afk = true,
    admin = true,
    excluded = true,
    blocked = true,
    already = true,
    no_role = true,
    not_listed = true,
    no_case = true,
}

local function Refused(src, why, untilAt)
    local key = REFUSAL[why] and ('volunteer.refused.' .. why) or 'volunteer.refused.other'
    local vars = untilAt and { hours = math.max(1, math.ceil((untilAt - os.time()) / 3600)) } or nil
    Note(src, 'error', key, vars)
end

-- The volunteer.refused.* text of a refusal reason (the criminal tablet), 'volunteer.refused.other' for any other.
function V.refusalKey(why) return REFUSAL[why] and ('volunteer.refused.' .. why) or 'volunteer.refused.other' end

local ACTIONS = {
    open = function(src)
        if not On() then return Refused(src, 'off') end
        -- Config.CriminalTablet.replaceCommand: the criminal tablet instead of this menu, for a player who may use it
        if CP.CrimTab and CP.CrimTab.replacesCommand and CP.CrimTab.replacesCommand(src) then
            return TriggerClientEvent(CP.e('client:crimtabOpen'), src)
        end
        local listedCid = cidOf[src]
        if listedCid and listed[listedCid] then
            return TriggerClientEvent(CP.e('client:volunteerMenu'), src, MenuOf(src, { citizenid = listedCid }))
        end
        local ok, why, info, untilAt = V.check(src)
        if not ok then return Refused(src, why, untilAt) end
        TriggerClientEvent(CP.e('client:volunteerMenu'), src, MenuOf(src, info))
    end,
    join = function(src, data)
        local ok, res, untilAt = V.join(src, type(data) == 'table' and data.roles or nil)
        if not ok then return Refused(src, res, untilAt) end
        Note(src, 'success', 'volunteer.started', { minutes = math.floor(WindowSeconds() / 60) })
    end,
    renew = function(src)
        local ok, res, untilAt = V.renew(src)
        if not ok then return Refused(src, res, untilAt) end
        Note(src, 'success', 'volunteer.renewed', { minutes = math.floor(WindowSeconds() / 60) })
    end,
    roles = function(src, data)
        local ok, res = V.setRoles(src, type(data) == 'table' and data.roles or nil)
        if not ok then return Refused(src, res) end
        Note(src, 'success', 'volunteer.roles_saved')
    end,
    stop = function(src)
        if V.cancelCase then
            V.cancelCase(src)
        end -- stopping while he plays a suspect cancels that case first
        local ok, res = V.stop(src)
        if not ok then return Refused(src, res) end
    end,
}

RegisterNetEvent(CP.e('server:volunteer'), function(action, data)
    local src = CP.U.toSrc(source)
    if not src then return end
    if CP.Net and CP.Net.rateOk and not CP.Net.rateOk(src, 'volunteer', 4, 2000) then return end
    local fn = type(action) == 'string' and (ACTIONS[action] or (V.matchActions or {})[action]) or nil
    if not fn then return end
    local ok, err = pcall(fn, src, data)
    if not ok then CP.err(TAG, ('volunteer action %s failed: %s'):format(action, tostring(err))) end
end)

-- ============================================================================
--                                   THE ENDS
-- ============================================================================

local function Gone(src)
    src = CP.U.toSrc(src)
    local cid = src and cidOf[src]
    if cid then End(cid, 'left') end
end

AddEventHandler('playerDropped', function() Gone(source) end)

CP.Hooks.on('settings:changed', function()
    if On() then return StartStrikes() end
    for cid in pairs(listed) do End(cid, 'disabled') end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    listed, cidOf, reserved = {}, {}, {}
    saved.loaded, saved.loading = false, false
    sweep.token = sweep.token + 1
    sweep.on = false
end)

CreateThread(function()
    Wait(0)
    if CP.Schedule and CP.Schedule.onDaily then
        CP.Schedule.onDaily(function()
            if SaveOn() then CreateThread(function() PruneStrikes(os.time()) end) end
        end)
    end
    StartStrikes()
    local Q = CP.Qbx
    if not (Q and Q.onPlayerUnload and Q.onDutyChange and Q.onJobChange) then return end
    Q.onPlayerUnload(Gone)
    local function Duty(src, job)
        src = CP.U.toSrc(src)
        local cid = src and cidOf[src]
        if not cid then return end
        if DeptDuty(job and { job = job } or Q.getInfo(src)) then End(cid, 'on_duty') end
    end
    Q.onDutyChange(function(src, onDuty) if onDuty then Duty(src) end end)
    Q.onJobChange(function(src, job) Duty(src, type(job) == 'table' and job or nil) end)
end)
