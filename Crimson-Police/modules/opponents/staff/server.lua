-- CP.Opponents staff (server): what admins read about real-suspect cases and the three admin tools. The

-- CP.Opponents staff (server): what admins read about real-suspect cases and the three admin tools. The
-- case data here (names, citizenids, the timeline, the damage ledger, the flags and notes) is server-only: it goes
-- to an admin's Admin UI through these callbacks and never to an officer's tablet (Opp.view has no names). Reads
-- read memory (open cases and the last Config.RealSuspects.casesKept closed ones, which modules/opponents/saved
-- keeps over a restart; the pair ledger's window).
-- Nothing here runs while nobody asks; the actions are refused while both features are off.

CP.Opponents = CP.Opponents or {}
local Opp = CP.Opponents
local TAG = 'opponents'

local LINES_MAX = 5000            -- timeline lines answered at most (timelineMax is clamped to 5000 too)
local DETAIL_MAX = 255

-- The officer-conduct flags a case's timeline can hold (CP.AntiCheat.flag: an officer's points wait for review); the
-- suspect's own acts are notes (entry.note). Both are the case's flag lines.
local FLAG_LINES = {
    rs_excessive_force = true,
    rs_unarmed_shot = true,
    rs_vdm = true,
    rs_bad_seize = true,
    rs_linked_accounts = true,
    pair_repeat = 'rs_pair_repeat',
}

-- The line key of each timeline entry (opp.line.<what>); anything else reads its flag text or its code.
local LINE_KEYS = {
    suspect = true,
    offline_at_open = true,
    state = true,
    unloaded = true,
    dropped = true,
    instance = true,
    contact = true,
    closed = true,
    crime_ended = true,
    rejoined = true,
    crew_rejoined = true,
    officer = true,
    officer_joined = true,
    join_offered = true,
    join_declined = true,
    armed = true,
    down = true,
    up = true,
    cuff_attempt = true,
    outside_cuff_attempt = true,
    cuff_refused = true,
    cuffed_by_outsider = true,
    cuffed_unproven = true,
    uncuff_refused = true,
    uncuffed_by_outsider = true,
    bobby_pin = true,
    spawn_protected = true,
    spawn_protect = true,
    respawn_in_contact = true,
    jail = true,
    jail_refused = true,
    outside_jail = true,
    booking_too_short = true,
    booked_outside_station = true,
    pair_repeat = true,
    -- a volunteer suspect
    volunteer_yes = true,
    in_position = true,
    engaged = true,
    no_show = true,
    volunteer_cancel = true,
    volunteer_npc = true,
    volunteer_afk = true,            -- caught while AFK: his part is void
    volunteer_out_of_bounds = true,  -- a fugitive outside the search circle too long: void
    volunteer_on_duty = true,        -- went on police duty mid-case: void with a strike
    volunteer_early_respawn = true,  -- respawned at a hospital before the death timer: void with a strike
    -- surrender and Talk them down in a live case
    talk_down = true,
    talk_refused = true,
    surrendered = true,
    surrender_ended = true,
    peaceful_arrest = true,
}

local STATE_KEY = {
    free = 'opp.state.free',
    cuffed = 'opp.state.cuffed',
    detained = 'opp.state.detained',
    booked = 'opp.state.booked',
    lost = 'opp.state.lost',
    left = 'opp.state.left',
    void = 'opp.state.void',
}

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function ValidCid(cid)
    return type(cid) == 'string' and cid ~= '' and #cid <= 50 and cid:match('^[%w_%-]+$') ~= nil
end

local function ValidRunId(v)
    return type(v) == 'string' and #v > 0 and #v <= 36 and v:match('^[%w%-]+$') ~= nil
end

local function Cfg() return Config.RealSuspects or {} end

local function FeatureOn()
    return (type(Config.LiveCrime) == 'table' and Config.LiveCrime.enabled == true)
        or (type(Config.Volunteers) == 'table' and Config.Volunteers.enabled == true)
end

-- "Name (CITIZENID)", the citizenid alone, or nil.
local function WhoText(who)
    if type(who) ~= 'table' or not ValidCid(who.cid) then return nil end
    if type(who.name) == 'string' and who.name ~= '' then return ('%s (%s)'):format(who.name, who.cid) end
    return who.cid
end

local function Who(who)
    if type(who) ~= 'table' or not ValidCid(who.cid) then return nil end
    return { citizenid = who.cid, name = type(who.name) == 'string' and who.name or nil }
end

local function StateText(state) return state and STATE_KEY[state] and CP.L(STATE_KEY[state]) or nil end

-- A participant of the case's run by server id: { citizenid, name } (participant entries stay after a leave).
local function Officer(case, src)
    local parts = type(case.run) == 'table' and type(case.run.participants) == 'table' and case.run.participants or {}
    local p = parts[tonumber(src) or -1]
    if type(p) ~= 'table' or not ValidCid(p.citizenid) then return nil end
    return { citizenid = p.citizenid, name = type(p.name) == 'string' and p.name or nil, callsign = p.callsign }
end

-- The flag kind of a timeline entry (a conduct flag or a note), or nil.
local function FlagKind(e)
    local f = FLAG_LINES[e.what]
    if f then return f == true and e.what or f end
    if e.note then return e.what end
    return nil
end

-- One timeline entry as a staff line: { t, what, label, who, by, text, flag?, note? }.
local function Line(e)
    local who, by = WhoText(e.who), WhoText(e.byWho)
    local vars = {
        label = e.label or '-',
        who = who or '-',
        by = by or '-',
        state = StateText(e.state) or tostring(e.state or '-'),
        prev = StateText(e.prev) or tostring(e.prev or '-'),
        why = tostring(e.why or '-'),
        seconds = tostring(e.seconds or '-'),
        months = tostring(e.months or '-'),
        count = tostring(e.count or '-'),
    }
    local kind = FlagKind(e)
    local text
    if LINE_KEYS[e.what] then
        text = CP.L('opp.line.' .. e.what, vars)
    elseif kind and CP.Locale and CP.Locale.has and CP.Locale.has('flag.' .. kind) then
        text = CP.L('flag.' .. kind)
    else
        text = tostring(e.what)
    end
    if type(e.detail) == 'string' and e.detail ~= '' then text = text .. ' - ' .. CP.U.clip(e.detail, DETAIL_MAX) end
    return {
        t = e.t,
        what = e.what,
        label = e.label,
        who = Who(e.who),
        by = Who(e.byWho),
        text = text,
        flag = kind ~= nil and not e.note or nil,
        note = e.note == true or nil,
        kind = kind,
    }
end

local function Count(case)
    local out = { suspects = #case.order, detained = 0, booked = 0, flags = 0, notes = 0 }
    for _, cid in ipairs(case.order) do
        local r = case.suspects[cid]
        local o = r.outcome or r.state
        if o == 'detained' then out.detained = out.detained + 1 end
        if o == 'booked' then out.booked = out.booked + 1 end
    end
    for _, e in ipairs(case.timeline) do
        local kind = FlagKind(e)
        if kind and e.note then
            out.notes = out.notes + 1
        elseif kind then
            out.flags = out.flags + 1
        end
    end
    return out
end

local function Officers(case)
    local out = {}
    local run = case.run
    local parts = type(run) == 'table' and type(run.participants) == 'table' and run.participants or {}
    for src, p in pairs(parts) do
        if type(p) == 'table' and ValidCid(p.citizenid) then
            out[#out + 1] = {
                citizenid = p.citizenid,
                name = type(p.name) == 'string' and p.name or nil,
                callsign = p.callsign,
                status = p.status,
                src = tonumber(src),
            }
        end
    end
    table.sort(out, function(a, b) return (a.src or 0) < (b.src or 0) end)
    for _, o in ipairs(out) do o.src = nil end
    return out
end

local NAMES_CHUNK = 100   -- citizenids per cp_officers statement

-- Character names for the citizenids a staff screen shows (Config.RealSuspects.staffNames): one batched lookup
-- per screen load, never a query per row. Online characters from the player cache, the rest from Qbox's players
-- table (CP.Qbx.characterNames), then the officer names Crimson-Police keeps (cp_officers: the database or the saves
-- folder). -> { [citizenid] = name }.
local function NamesOf(cids)
    local out = {}
    if Cfg().staffNames == false then return out end
    local want, list = {}, {}
    for _, cid in ipairs(cids) do
        if ValidCid(cid) and not want[cid] then
            want[cid] = true
            list[#list + 1] = cid
        end
    end
    if #list == 0 then return out end
    if CP.Qbx and CP.Qbx.characterNames then
        local ok, names = pcall(CP.Qbx.characterNames, list)
        if ok and type(names) == 'table' then
            for cid, name in pairs(names) do
                if want[cid] and type(name) == 'string' and name ~= '' then out[cid] = name end
            end
        elseif not ok then
            CP.err(TAG, 'CP.Qbx.characterNames failed: %s', tostring(names))
        end
    end
    local rest = {}
    for _, cid in ipairs(list) do
        if not out[cid] then rest[#rest + 1] = cid end
    end
    for first = 1, #rest, NAMES_CHUNK do
        local chunk, marks = {}, {}
        for i = first, math.min(#rest, first + NAMES_CHUNK - 1) do
            chunk[#chunk + 1] = rest[i]
            marks[#marks + 1] = '?'
        end
        local ok, rows = pcall(MySQL.query.await,
            ('SELECT citizenid, display_name FROM cp_officers WHERE citizenid IN ' .. '(%s)'):format(
                table.concat(marks, ', ')
            ), chunk)
        if not ok then
            CP.err(TAG, 'reading officer names failed: %s', tostring(rows))
            break
        end
        for _, r in ipairs(type(rows) == 'table' and rows or {}) do
            if type(r.display_name) == 'string' and r.display_name ~= '' and want[r.citizenid] then
                out[r.citizenid] = r.display_name
            end
        end
    end
    return out
end
Opp.staffNames = NamesOf

-- A volunteer case's role, mode, phase, dropout and whether an officer reached him (CP.Volunteers.staffView),
-- or nil for a live case.
local function VolunteerOf(case)
    local V = CP.Volunteers
    if case.kind ~= 'volunteer' or not (V and V.staffView) then return nil end
    local ok, v = pcall(V.staffView, case.runId, case)
    if not ok then
        CP.err(TAG, 'CP.Volunteers.staffView failed: %s', tostring(v))
        return nil
    end
    return type(v) == 'table' and v or nil
end

-- ============================================================================
--                                 STAFF VIEWS
-- ============================================================================

-- One line per case: { runId, kind, open, openedAt, closedAt, missionId, suspects, detained, booked, flags, notes,
-- officers = { { citizenid, name } }, volunteer = { role, mode, phase, why, engaged } (a volunteer case) }.
function Opp.staffCases()
    local out = {}
    for _, c in ipairs(Opp.cases and Opp.cases() or {}) do
        local case = c.case
        local line = Count(case)
        line.runId = case.runId
        line.kind = case.kind
        line.open = c.open
        line.openedAt = case.openedAt
        line.closedAt = case.closedAt
        line.missionId = type(case.run) == 'table' and case.run.missionId or nil
        line.officers = Officers(case)
        line.volunteer = VolunteerOf(case)
        out[#out + 1] = line
    end
    return out
end

-- The whole case for staff, or nil: suspects with their names and citizenids, officers, the timeline as lines, the
-- flag lines, the damage ledger and the notes. No position is answered (the trail stays on the server).
function Opp.staffCase(runId)
    local case, open = nil, false
    if Opp.findCase then case, open = Opp.findCase(runId) end
    if not case then return nil end
    local opened = case.openedMs or 0
    local function Since(ms)
        if type(ms) ~= 'number' then return nil end
        return math.max(0, math.floor((ms - opened) / 1000))
    end
    local suspects = {}
    for _, cid in ipairs(case.order) do
        local r = case.suspects[cid]
        suspects[#suspects + 1] = {
            citizenid = cid,
            name = r.name,
            label = r.label,
            state = r.state,
            outcome = r.outcome,
            online = r.src ~= nil,
            share = r.share,
            everArmed = r.everArmed == true,
            afk = r.afk == true,
            down = r.down == true,
            byLeave = r.byLeave == true,
            contactS = Since(r.contactAt),
            cuffedS = Since(r.cuffedAt),
            detainedS = Since(r.detainedAt),
            bookedS = Since(r.bookedAt),
            jailTime = r.jailTime,
            notes = #(r.notes or {}),
        }
    end
    local lines, flags = {}, {}
    local first = math.max(1, #case.timeline - LINES_MAX + 1)
    for i = first, #case.timeline do
        local line = Line(case.timeline[i])
        lines[#lines + 1] = line
        if line.kind then flags[#flags + 1] = line end
    end
    local ledger = {}
    for _, e in ipairs(case.ledger or {}) do
        local officerSrc = e.dir == 'officer' and e.from or e.to
        ledger[#ledger + 1] = {
            t = e.t,
            dir = e.dir,
            officer = Officer(case, officerSrc),
            label = e.label,
            weapon = e.weapon,
            weaponName = Cfg().weaponNames ~= false and CP.Weapons and CP.Weapons.label(e.weapon) or nil,
            n = e.n,
            willKill = e.willKill == true,
            state = e.state,
            down = e.down == true,
            rules = e.rules,
        }
    end
    local out = Count(case)
    out.runId = case.runId
    out.kind = case.kind
    out.open = open
    out.openedAt = case.openedAt
    out.closedAt = case.closedAt
    out.missionId = type(case.run) == 'table' and case.run.missionId or nil
    out.crimeEnded = case.crimeEndedAt ~= nil
    out.officers = Officers(case)
    out.volunteer = VolunteerOf(case)
    out.suspects = suspects
    out.lines = lines
    out.flagLines = flags
    out.ledger = ledger
    return out
end

-- ============================================================================
--                         ADMIN CALLBACKS AND ACTIONS
-- ============================================================================
-- Admins only (CP.AdminKit, key antiFarmOverride). A case of one of the admin's own characters or accounts (an
-- officer of it, or a suspect: Kit.selfRun) is refused: err.own_run. The three tools refuse the admin's own
-- characters (err.self_target), need a reason, are audited and are refused while both features are off.

local function Days(v)
    local n = tonumber(v)
    if not n or n ~= n or n <= 0 or n > 3650 then return nil end
    return n
end

local function Answer(ok, untilOrErr)
    if not ok then return false, untilOrErr == 'invalid_days' and 'err.rs_invalid_days' or 'err.invalid_citizenid' end
    return true, untilOrErr
end

-- The cases a filter of the Cases tab keeps (as the web's filterCases): 'open' = still running, 'flagged' = with a
-- conduct flag or a suspect note, 'live' / 'volunteer' = that kind of case; anything else keeps every case. Run on
-- the server before paging (Config.AdminUi.pageSize), so a filter covers every case, not only the page shown.
local CASE_FILTERS = { open = true, flagged = true, live = true, volunteer = true }
local function FilterCases(list, filter)
    if not CASE_FILTERS[filter] then return list end
    local out = {}
    for _, c in ipairs(list) do
        local keep
        if filter == 'open' then
            keep = c.open == true
        elseif filter == 'flagged' then
            keep = (tonumber(c.flags) or 0) + (tonumber(c.notes) or 0) > 0
        else
            keep = c.kind == filter
        end
        if keep then out[#out + 1] = c end
    end
    return out
end

if CP.AdminKit and CP.AdminKit.action then
    local Kit = CP.AdminKit

    Kit.callback('admin:getRsCases', 'antiFarmOverride', function(ctx)
        local list = FilterCases(Opp.staffCases(), ctx.args.filter)
        -- Config.AdminUi.pageSize: one page of the cases, { page, pages, total } as casesPage
        local size, casesPage = Kit.pageSize and Kit.pageSize(), nil
        if size and Kit.pageOf then
            local p, pages, total
            list, p, pages, total = Kit.pageOf(list, ctx.args.page, size)
            casesPage = { page = p, pages = pages, total = total }
        end
        for _, c in ipairs(list) do c.own = Kit.selfRun(ctx.src, c.runId) == true end
        local volunteersOn = type(Config.Volunteers) == 'table' and Config.Volunteers.enabled == true
        local listed = volunteersOn and CP.Volunteers and CP.Volunteers.staffList and CP.Volunteers.staffList() or {}
        -- a name for every officer and volunteer the case line or the list has none for, in one lookup
        local missing = {}
        for _, c in ipairs(list) do
            for _, o in ipairs(c.officers or {}) do
                if not o.name then missing[#missing + 1] = o.citizenid end
            end
        end
        for _, v in ipairs(listed) do
            if not v.name then missing[#missing + 1] = v.citizenid end
        end
        local names = NamesOf(missing)
        for _, c in ipairs(list) do
            for _, o in ipairs(c.officers or {}) do o.name = o.name or names[o.citizenid] end
        end
        for _, v in ipairs(listed) do v.name = v.name or names[v.citizenid] end
        return {
            enabled = FeatureOn(),
            liveCrime = type(Config.LiveCrime) == 'table' and Config.LiveCrime.enabled == true,
            volunteers = volunteersOn,
            cases = list,
            casesPage = casesPage,
            -- the volunteers on the list now (empty while volunteers are off)
            listed = listed,
            -- the Volunteers tab offers Clear strikes (Config.Volunteers.staffClearStrikes)
            clearStrikes = volunteersOn and Config.Volunteers.staffClearStrikes ~= false,
            -- blocks, exclusions and suspensions can be lifted early (Config.RealSuspects.staffLift)
            lift = Cfg().staffLift ~= false,
            serverTime = os.time(),
        }
    end)

    Kit.callback('admin:getRsCase', 'antiFarmOverride', function(ctx)
        local runId = ctx.args.runUuid
        if not ValidRunId(runId) then return nil, 'err.invalid_run' end
        if Kit.selfRun(ctx.src, runId) then return nil, 'err.own_run' end
        local view = Opp.staffCase(runId)
        if not view then return nil, 'err.rs_no_case' end
        view.serverTime = os.time()
        return view
    end, { latent = true })

    Kit.callback('admin:getRsPairs', 'antiFarmOverride', function(ctx)
        local cid = ctx.args.citizenid
        if cid ~= nil and not ValidCid(cid) then return nil, 'err.invalid_citizenid' end
        local lines, from = {}, nil
        if Opp.pairStats then lines, from = Opp.pairStats(cid) end
        local admin = Opp.adminRows and Opp.adminRows() or {}
        -- the names of everyone the pairs and the running rows name, in one lookup
        local cids = { cid }
        for _, l in ipairs(lines) do
            cids[#cids + 1] = l.officer
            cids[#cids + 1] = l.suspect
        end
        for _, r in ipairs(admin) do
            cids[#cids + 1] = r.officer
            cids[#cids + 1] = r.suspect
        end
        local out = {
            enabled = FeatureOn(),
            pairs = lines,
            from = from,
            admin = admin,
            names = NamesOf(cids),
            -- the running rows can be lifted early (Config.RealSuspects.staffLift)
            lift = Cfg().staffLift ~= false,
            serverTime = os.time(),
        }
        if cid then
            local ex, exUntil = false, nil
            local su, suUntil = false, nil
            if Opp.excluded then ex, exUntil = Opp.excluded(cid) end
            if Opp.suspended then su, suUntil = Opp.suspended(cid) end
            out.citizenid = cid
            out.excludedUntil = ex and exUntil or nil
            out.suspendedUntil = su and suUntil or nil
        end
        return out
    end)

    Kit.action('server:admin:rsBlockPair', 'antiFarmOverride', function(ctx)
        local p = ctx.payload
        if not FeatureOn() then return false, 'err.rs_off' end
        if not ValidCid(p.officer) or not ValidCid(p.suspect) or p.officer == p.suspect then
            return false, 'err.invalid_citizenid'
        end
        local days = Days(p.days)
        if not days then return false, 'err.rs_invalid_days' end
        for _, cid in ipairs({ p.officer, p.suspect }) do
            if Kit.isSelf(ctx.src, cid) then return false, 'err.self_target' end
        end
        local ok, res = Answer(Opp.block(p.officer, p.suspect, days))
        if not ok then return false, res end
        ctx.audit('rsBlockPair', p.officer, nil,
            ('suspect %s, %s days, until %d'):format(p.suspect, tostring(days), res))
        CP.log(TAG, 'admin %s blocked the pair %s / %s for %s days', tostring(ctx.actor), p.officer, p.suspect,
            tostring(days))
        return true, { officer = p.officer, suspect = p.suspect, untilAt = res }
    end, { reason = true, targetRate = { 1, 10000, field = 'officer' } })

    Kit.action('server:admin:rsExclude', 'antiFarmOverride', function(ctx)
        local p = ctx.payload
        if not FeatureOn() then return false, 'err.rs_off' end
        if not ValidCid(p.citizenid) then return false, 'err.invalid_citizenid' end
        local days = Days(p.days)
        if not days then return false, 'err.rs_invalid_days' end
        local ok, res = Answer(Opp.exclude(p.citizenid, days))
        if not ok then return false, res end
        ctx.audit('rsExclude', p.citizenid, nil, ('%s days, until %d'):format(tostring(days), res))
        return true, { citizenid = p.citizenid, untilAt = res }
    end, {
        reason = true,
        targetRate = { 1, 10000 },
        self = function(p) return { citizenid = p.citizenid } end,
    })

    Kit.action('server:admin:rsSuspend', 'antiFarmOverride', function(ctx)
        local p = ctx.payload
        if not FeatureOn() then return false, 'err.rs_off' end
        if not ValidCid(p.citizenid) then return false, 'err.invalid_citizenid' end
        local days = Days(p.days)
        if not days then return false, 'err.rs_invalid_days' end
        local ok, res = Answer(Opp.suspend(p.citizenid, days))
        if not ok then return false, res end
        ctx.audit('rsSuspend', p.citizenid, nil, ('%s days, until %d'):format(tostring(days), res))
        return true, { citizenid = p.citizenid, untilAt = res }
    end, {
        reason = true,
        targetRate = { 1, 10000 },
        self = function(p) return { citizenid = p.citizenid } end,
    })

    -- lift a running block, exclusion or suspension early (Config.RealSuspects.staffLift). Never one that names
    -- the admin's own characters; a row that is not running (ended, already lifted, never there) is err.rs_no_row.
    local LIFT_KINDS = { block = true, exclude = true, suspend = true }
    Kit.action('server:admin:rsLift', 'antiFarmOverride', function(ctx)
        local p = ctx.payload
        if Cfg().staffLift == false then return false, 'err.rs_lift_off' end
        if not FeatureOn() then return false, 'err.rs_off' end
        if not LIFT_KINDS[p.kind] then return false, 'err.rs_no_row' end
        local officer = p.kind ~= 'exclude' and p.officer or nil
        local suspect = p.kind ~= 'suspend' and p.suspect or nil
        if (p.kind ~= 'exclude' and not ValidCid(officer)) or (p.kind ~= 'suspend' and not ValidCid(suspect)) then
            return false, 'err.invalid_citizenid'
        end
        for _, cid in ipairs({ officer or false, suspect or false }) do
            if cid and Kit.isSelf(ctx.src, cid) then return false, 'err.self_target' end
        end
        local ok, res = Opp.lift(p.kind, officer, suspect)
        if not ok then return false, res == 'invalid_citizenid' and 'err.invalid_citizenid' or 'err.rs_no_row' end
        ctx.audit('rsLift', officer or suspect, nil, ('%s lifted early%s (it ran until %d)'):format(p.kind,
            (officer and suspect) and (', suspect ' .. suspect) or '', res))
        CP.log(TAG, 'admin %s lifted the %s of %s early', tostring(ctx.actor), p.kind, tostring(officer or suspect))
        return true, { kind = p.kind, officer = officer, suspect = suspect }
    end, { reason = true })

    -- clear a volunteer's strikes and strike block (Config.Volunteers.staffClearStrikes), refused on the admin's
    -- own characters; nothing to clear is err.rs_no_strikes.
    Kit.action('server:admin:rsClearStrikes', 'antiFarmOverride', function(ctx)
        local p = ctx.payload
        local vc = type(Config.Volunteers) == 'table' and Config.Volunteers or {}
        if vc.enabled ~= true then return false, 'err.rs_off' end
        if vc.staffClearStrikes == false then return false, 'err.rs_clear_off' end
        if not ValidCid(p.citizenid) then return false, 'err.invalid_citizenid' end
        local V = CP.Volunteers
        if not (V and V.clearStrikes) then return false, 'err.rs_no_strikes' end
        local ok, res = V.clearStrikes(p.citizenid)
        if not ok then return false, 'err.rs_no_strikes' end
        ctx.audit('rsClearStrikes', p.citizenid, nil, ('%d strike(s) cleared%s'):format(res.strikes or 0,
            res.blockedUntil and (', block until ' .. res.blockedUntil .. ' lifted') or ''))
        return true, { citizenid = p.citizenid, strikes = res.strikes, blockedUntil = res.blockedUntil }
    end, {
        reason = true,
        targetRate = { 1, 10000 },
        self = function(p) return { citizenid = p.citizenid } end,
    })
end
