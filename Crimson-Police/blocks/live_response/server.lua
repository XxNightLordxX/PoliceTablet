-- Objective block "live_response" (server half): the engine-only objective of a live crime (the live_crime

-- Objective block "live_response" (server half): the engine-only objective of a live crime (the live_crime
-- engine mission, docs/ARCHITECTURE.md §5.46 and §7.3). The suspects are real players kept by CP.Opponents (§5.45);
-- this block never touches them. Three phases: Respond (an officer reaches the reported scene or makes contact),
-- Secure the scene (officers hold it for Config.LiveCrime.secureSeconds), and one open "Detain and book the suspects"
-- that never closes and never reacts to one suspect's state: the HUD and the checklist only show the phase. Detains
-- and bookings are the server-only opp_detained / opp_booked events of CP.Opponents' proof, recorded as the shared
-- lines live_detain and live_book weighted by the suspect's share. The case ends with End case (the unit leader), the
-- time limit (completed with what was earned) or Config.LiveCrime.deadCaseSeconds after no suspect is left to work.
-- The map never follows a suspect: it shows where each free suspect was at the last report, every
-- Config.LiveCrime.lastReportedEvery seconds (0 = never).

local BLOCK = 'live_response'
local U = CP.U

local function Cfg() return Config.LiveCrime or {} end

local function Num(v, default)
    local n = tonumber(v)
    if n == nil or n ~= n then return default end
    return n
end

local function Vec(v)
    local x, y, z = U.xyz(v)
    if not x then return nil end
    return vec3(x + 0.0, y + 0.0, z + 0.0)
end

-- ============================================================================
--                                    STATE
-- ============================================================================

local function StateOf(ctx)
    local st = ctx.state
    if not st.init then
        st.init = true
        st.phase = 'respond' -- 'respond' | 'secure' | 'detain'
        st.secureS = 0 -- seconds an officer held the scene
        st.lines = { live_detain = {}, live_book = {}, peaceful_arrest = {} } -- [cid] = weight (once per suspect)
        st.reported = {} -- the last-reported points, refreshed every lastReportedEvery seconds
        st.reportAt = nil -- GetGameTimer() of the next refresh
        st.reportedAt = nil -- os.time() of the last report (the tablet's case card)
    end
    return st
end

-- The reported scene: the case's scene (the crime's coords), else the objective's or the location's start.
local function Scene(ctx)
    local view = CP.Opponents and CP.Opponents.view and CP.Opponents.view(ctx.run) or nil
    local c = view and Vec(view.scene)
    if c then return c end
    c = Vec(ctx.obj and ctx.obj.scene)
    if c then return c end
    local start = ctx.location and ctx.location.start
    return Vec(type(start) == 'table' and start.coords or start)
end

local function SceneRadius() return math.max(1.0, Num(Cfg().sceneRadius, 75.0)) end

-- Metres from the nearest active participant to coords (math.huge without one).
local function NearestOfficer(ctx, coords)
    local best = math.huge
    if not coords then return best end
    for _, src in ipairs(ctx.participants()) do
        local c = ctx.coords(src)
        if c then
            local d = U.dist(c, coords)
            if d < best then best = d end
        end
    end
    return best
end

-- Whether any suspect has been in contact (CP.Opponents' contactRange): the phase is the same for every suspect.
local function AnyContact(ctx)
    local view = CP.Opponents and CP.Opponents.view and CP.Opponents.view(ctx.run) or nil
    if not view then return false end
    for _, cid in ipairs(view.order) do
        if view.suspects[cid].contact then return true end
    end
    return false
end

-- True while a suspect can still be worked (free, cuffed or detained and not yet booked). No case = nothing left.
local function Workable(ctx)
    local view = CP.Opponents and CP.Opponents.view and CP.Opponents.view(ctx.run) or nil
    if not view then return false end
    for _, cid in ipairs(view.order) do
        local s = view.suspects[cid].state
        if s == 'free' or s == 'cuffed' or s == 'detained' then return true end
    end
    return false
end

-- ============================================================================
--                                   THE HUD
-- ============================================================================

local function Hud(ctx, st)
    local patch = { detail = CP.Lt('block.live_response.hud_' .. st.phase) }
    if st.phase == 'secure' then
        local need = math.max(0, math.floor(Num(Cfg().secureSeconds, 60)))
        patch.value, patch.max = math.min(need, math.floor(st.secureS)), need
    end
    ctx.hud(patch)
end

local function Checklist(ctx)
    local st = StateOf(ctx)
    local need = math.max(0, math.floor(Num(Cfg().secureSeconds, 60)))
    return {
        { label = CP.L('block.live_response.check_respond'), done = st.phase ~= 'respond' },
        {
            label = CP.L('block.live_response.check_secure'),
            done = st.phase == 'detain',
            value = math.min(need, math.floor(st.secureS)),
            max = need,
        },
        -- never done and never counted: it does not change with one suspect's state
        { label = CP.L('block.live_response.check_detain'), done = false },
    }
end

-- ============================================================================
--                                    PHASES
-- ============================================================================

local function Secured(ctx, st)
    st.phase = 'detain'
    ctx.award('live_scene')
    if CP.Opponents and CP.Opponents.timeline then CP.Opponents.timeline(ctx.run, { what = 'scene_secured' }) end
    Hud(ctx, st)
end

local function Responded(ctx, st)
    st.phase = 'secure'
    if CP.Opponents and CP.Opponents.timeline then CP.Opponents.timeline(ctx.run, { what = 'responded' }) end
    if Num(Cfg().secureSeconds, 60) <= 0 then return Secured(ctx, st) end
    Hud(ctx, st)
end

-- The last-reported points: each free suspect where the server saw him at the report (never followed live).
local function Report(ctx, st)
    st.reported = {}
    st.reportedAt = os.time()
    local case = CP.Opponents and CP.Opponents.caseOf and CP.Opponents.caseOf(ctx.run) or nil
    if not case then return end
    for _, cid in ipairs(case.order) do
        local rec = case.suspects[cid]
        if rec.state == 'free' and rec.src and rec.lastCoords and not rec.inInstance then
            st.reported[#st.reported + 1] = { label = rec.label, coords = Vec(rec.lastCoords) }
        end
    end
end

local function Start(ctx)
    local st = StateOf(ctx)
    Hud(ctx, st)
end

local function Tick(ctx, dt)
    local st = StateOf(ctx)
    local cfg = Cfg()
    local scene = Scene(ctx)
    local onScene = NearestOfficer(ctx, scene) <= SceneRadius()
    if st.phase == 'respond' and (onScene or AnyContact(ctx)) then Responded(ctx, st) end
    if st.phase == 'secure' and onScene then
        local before = math.floor(st.secureS)
        st.secureS = st.secureS + Num(dt, 1)
        if st.secureS >= Num(cfg.secureSeconds, 60) then
            Secured(ctx, st)
        elseif math.floor(st.secureS) ~= before then
            Hud(ctx, st)
        end
    end
    local every = math.floor(Num(cfg.lastReportedEvery, 60))
    local now = GetGameTimer()
    if every > 0 and st.phase ~= 'respond' and now >= (st.reportAt or 0) then
        st.reportAt = now + every * 1000
        Report(ctx, st)
    elseif every <= 0 then
        st.reported, st.reportedAt = {}, nil
    end
    -- the dead case: no suspect left to work (all booked, lost, left or void), for deadCaseSeconds
    if Workable(ctx) then
        st.deadSince = nil
    else
        st.deadSince = st.deadSince or now
        if now - st.deadSince >= math.max(0, Num(cfg.deadCaseSeconds, 30)) * 1000 then
            if not st.deadNoted and CP.Opponents and CP.Opponents.timeline then
                st.deadNoted = true
                CP.Opponents.timeline(ctx.run, { what = 'dead_case' })
            end
            ctx.complete({ reason = 'dead_case' })
        end
    end
end

-- A detain or a booking: the shared line once per suspect, weighted by his share (0 = an AFK catch: no line).
local function Line(ctx, st, id, ev)
    if type(ev.cid) ~= 'string' or st.lines[id][ev.cid] ~= nil then return true end
    local weight = U.clamp(Num(ev.share, 1), 0, 1)
    st.lines[id][ev.cid] = weight
    if weight > 0 then
        ctx.award(id, { weight = weight })
        -- one live catch per suspect detained, for every active participant (the live_catches Rank by tab)
        if id == 'live_detain' and CP.Runs and CP.Runs.noteStat then
            CP.Runs.noteStat(ctx.run, nil, 'live_catches', 1)
        end
    end
    return true
end

-- Config.FeatureRewards.surrender: the officer who talked the suspect down (an officer of this run, never
-- the suspect), once per run and suspect. A suspect who gave himself up by his own command pays nobody.
local function PayTalkDown(run, suspectCid, by)
    local FR = CP.FeatureRewards
    if not (FR and FR.enabled and FR.enabled('surrender')) or type(run) ~= 'table' or run.test then return false end
    by = math.tointeger(tonumber(by))
    if not by or by <= 0 or type(run.participants) ~= 'table' then return false end
    local p = run.participants[by]
    local cid = type(p) == 'table' and p.citizenid or nil
    if type(cid) ~= 'string' or cid == suspectCid then return false end
    -- an officer of the run shares a connection or PC with a suspect (rs_linked_accounts): no pay
    local AC = CP.AntiCheat
    if AC and AC.flaggedWith then
        local okF, linked = pcall(AC.flaggedWith, run, 'rs_linked_accounts')
        if okF and linked == true then return false end
    end
    return FR.payLater('surrender', cid, { key = ('%s:%s'):format(tostring(run.id), suspectCid) })
end

-- A detain of a suspect who surrendered and was not hit since (CP.Opponents.peaceful): the shared
-- peaceful_arrest line, weighted by his share, and a timeline line naming who talked him down.
local function Peaceful(ctx, st, ev)
    if type(ev.cid) ~= 'string' or st.lines.peaceful_arrest[ev.cid] ~= nil then return end
    local O = CP.Opponents
    if not (O and O.peaceful) then return end
    local ok, by = O.peaceful(ctx.run, ev.cid)
    local weight = U.clamp(Num(ev.share, 1), 0, 1)
    if not ok or weight <= 0 then return end
    st.lines.peaceful_arrest[ev.cid] = weight
    ctx.award('peaceful_arrest', { weight = weight })
    if O.timeline then O.timeline(ctx.run, { what = 'peaceful_arrest', label = ev.label, by = by }) end
    PayTalkDown(ctx.run, ev.cid, by)
end

local function OnEvent(ctx, src, ev)
    local st = StateOf(ctx)
    if src == nil then
        -- CP.Opponents' server-only events (a client's opp_* is refused before it gets here)
        if ev.type == 'opp_detained' then
            Line(ctx, st, 'live_detain', ev)
            Peaceful(ctx, st, ev)
            return true
        end
        if ev.type == 'opp_booked' then return Line(ctx, st, 'live_book', ev) end
        return true
    end
    if ev.type == 'end_case' then
        if not ctx.isHost(src) then return false, 'not_host' end
        if CP.Opponents and CP.Opponents.timeline then
            CP.Opponents.timeline(ctx.run, { what = 'end_case', src = src })
        end
        ctx.complete({ reason = 'end_case' })
        return true
    end
    return false, 'unknown_event'
end

-- Metres from the scene or the nearest last-known suspect position (server-side only), for the presence check.
local function Presence(ctx, src, coords)
    coords = coords or ctx.coords(src)
    if not coords then return math.huge end
    local best = math.huge
    local scene = Scene(ctx)
    if scene then best = math.max(0, U.dist(coords, scene) - SceneRadius()) end
    local case = CP.Opponents and CP.Opponents.caseOf and CP.Opponents.caseOf(ctx.run) or nil
    for _, cid in ipairs(case and case.order or {}) do
        local rec = case.suspects[cid]
        if rec.lastCoords then
            local d = U.dist(coords, rec.lastCoords)
            if d < best then best = d end
        end
    end
    return best
end

local function Marker(ctx)
    local st = StateOf(ctx)
    local scene = Scene(ctx)
    if st.phase == 'respond' then
        if not scene then return nil end
        return {
            kind = 'point',
            key = 'scene',
            look = 'scene',
            coords = scene,
            label = CP.L('block.live_response.blip_scene'),
        }
    end
    local targets = {}
    if scene then
        targets[1] = { key = 'scene', coords = scene, look = 'scene', label = CP.L('block.live_response.blip_scene') }
    end
    for _, r in ipairs(st.reported) do
        targets[#targets + 1] = {
            key = 'last:' .. r.label,
            coords = r.coords,
            look = 'searchArea',
            label = CP.L('block.live_response.blip_last', { label = r.label }),
        }
    end
    return { kind = 'targets', route = false, targets = targets }
end

-- The officers' case card (Active Mission): the phase, the secure seconds and when the last-reported points were
-- taken, with their labels only. Never a suspect's state or a position: it reads the same as the HUD and the map.
local function CaseView(ctx)
    local st = StateOf(ctx)
    local need = math.max(0, math.floor(Num(Cfg().secureSeconds, 60)))
    local labels = {}
    for _, r in ipairs(st.reported) do labels[#labels + 1] = r.label end
    local every = math.floor(Num(Cfg().lastReportedEvery, 60))
    local nextS = nil
    if every > 0 and st.phase ~= 'respond' and st.reportAt then
        nextS = math.max(0, math.ceil((st.reportAt - GetGameTimer()) / 1000))
    end
    return {
        phase = st.phase,
        secureS = math.min(need, math.floor(st.secureS)),
        secureNeed = need,
        reported = labels,
        reportedAgoS = st.reportedAt and math.max(0, os.time() - st.reportedAt) or nil,
        nextReportS = nextS,
        reportsOn = every > 0,
    }
end

CP.Blocks.register(BLOCK, {
    -- only the live_crime engine mission uses it: the mission loader and the Mission Builder refuse it in a file
    engineOnly = true,
    defaults = function(obj) return obj end,
    validate = function() return true end,
    armedCount = function() return 0 end,
    prepare = function(ctx) StateOf(ctx) end,
    start = Start,
    tick = Tick,
    onEvent = OnEvent,
    -- the time limit ends a real case with what was earned, never as a failure
    onTimeout = function() return 'completed' end,
    presence = Presence,
    marker = Marker,
    checklist = Checklist,
    caseView = CaseView,
    stop = function(ctx) StateOf(ctx).stopped = true end,
})
