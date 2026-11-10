-- The live_response block: the engine-only objective of a live crime. Its three phases (Respond, Secure

-- The live_response block: the engine-only objective of a live crime. Its three phases (Respond, Secure
-- the scene, one open Detain and book), a HUD and checklist that never change with one suspect's state, the
-- weighted detain and booking lines (CP.Runs.award opts.weight, read to two decimals by scoring), End case, the time
-- limit, the dead-case end, presence and the last-reported points; the mission loader and the Mission Builder refuse
-- the block. Plain Lua with a stubbed CP.Opponents: no database.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
Config.Debug = false

-- ============================================================================
--                                    STUBS
-- ============================================================================

local case = nil       -- CP.Opponents' case of the run (only what the block reads)
local timeline = {}
CP.Opponents = {
    caseOf = function() return case end,
    view = function()
        if not case then return nil end
        local out = { scene = case.scene, order = {}, suspects = {} }
        for i, cid in ipairs(case.order) do
            local r = case.suspects[cid]
            out.order[i] = cid
            out.suspects[cid] = { cid = cid, label = r.label, state = r.state, contact = r.contactAt ~= nil }
        end
        return out
    end,
    timeline = function(_, entry) timeline[#timeline + 1] = entry.what return true end,
}

local function Case()
    case = {
        scene = vec3(1000.0, 1000.0, 30.0),
        order = { 'CA', 'CB' },
        suspects = {
            CA = { cid = 'CA', label = 'A', state = 'free', src = 11, lastCoords = vec3(1200.0, 1000.0, 30.0) },
            CB = { cid = 'CB', label = 'B', state = 'free', src = 12, lastCoords = vec3(1000.0, 1300.0, 30.0) },
        },
    }
    return case
end

H.load('blocks/live_response/server.lua')
local B = CP.Blocks.get('live_response')

local officer = { [1] = vec3(0.0, 0.0, 30.0), [2] = vec3(0.0, 0.0, 30.0) }
local function Ctx()
    local ctx = {
        run = { id = 'LR1' },
        index = 1,
        obj = { block = 'live_response' },
        location = { start = { coords = vec3(0.0, 0.0, 30.0) } },
        state = {},
        huds = {},
        awards = {},
        completed = nil,
    }
    ctx.hud = function(patch) ctx.huds[#ctx.huds + 1] = patch end
    ctx.award = function(id, opts) ctx.awards[#ctx.awards + 1] = { id = id, opts = opts or {} } return true end
    ctx.complete = function(data) ctx.completed = data or {} return true end
    ctx.participants = function() return { 1, 2 } end
    ctx.coords = function(src) return officer[src] end
    ctx.isHost = function(src) return src == 1 end
    return ctx
end
local function Detail(ctx) local h = ctx.huds[#ctx.huds] return h and CP.L(h.detail.key, h.detail.vars) end
local function Lines(ctx, id)
    local out = {}
    for _, a in ipairs(ctx.awards) do if a.id == id then out[#out + 1] = a end end
    return out
end
local function Checklist(ctx)
    local parts = {}
    for _, c in ipairs(B.checklist(ctx)) do parts[#parts + 1] = c.label .. '=' .. tostring(c.done) end
    return table.concat(parts, ',')
end

-- ============================================================================
--                         SHIPPED CONFIG AND THE BLOCK
-- ============================================================================

do
    local lc = Config.RealPlayers.liveCrime
    H.eq(lc.enabled, false, 'live crimes ship off: no live case ever starts')
    H.eq(lc.sceneRadius, 75.0, 'sceneRadius ships 75 m')
    H.eq(lc.secureSeconds, 60, 'secureSeconds ships 60 s')
    H.eq(lc.lastReportedEvery, 60, 'lastReportedEvery ships 60 s')
    H.eq(lc.deadCaseSeconds, 30, 'deadCaseSeconds ships 30 s')
    for id, value in pairs({ live_scene = 0.25, live_detain = 0.50, live_book = 0.25, peaceful_arrest = 0.15 }) do
        local b = Config.Bonuses[id] or {}
        H.eq(b.kind, 'pct', id .. ' is a share of P')
        H.eq(b.value, value, id .. ' ships ' .. value)
        H.eq(b.engineOnly, true, id .. ' is engine-only (never in a mission file or the builder)')
    end
    H.ok(B ~= nil and B.engineOnly == true, 'live_response is registered engine-only')
    H.eq(B.onTimeout(), 'completed', 'the time limit completes a live case with what was earned')
end

-- ============================================================================
--               PHASES, HUD AND CHECKLIST (no per-suspect state)
-- ============================================================================

do
    Case()
    timeline = {}
    local ctx = Ctx()
    B.prepare(ctx)
    B.start(ctx)
    H.eq(Detail(ctx), 'Respond to the reported scene', 'phase 1: Respond')
    local m = B.marker(ctx)
    H.eq(m.kind, 'point', 'while responding: the reported scene as a point')
    H.eq(m.coords.x, 1000.0, 'the case scene (the crime) is the point, not a suspect')
    B.tick(ctx, 1)
    H.eq(ctx.state.phase, 'respond', 'far from the scene: still responding')

    officer[1] = vec3(1010.0, 1000.0, 30.0)
    B.tick(ctx, 1)
    H.eq(ctx.state.phase, 'secure', 'an officer at the scene: phase 2')
    H.eq(Detail(ctx), 'Secure the scene', 'the HUD says Secure the scene')
    H.eq(Checklist(ctx), 'Respond=true,Secure the scene=false,Detain and book the suspects=false', 'checklist')

    -- the last-reported points: the free suspects where the server saw them at the report, refreshed only later
    m = B.marker(ctx)
    H.eq(m.kind, 'targets', 'after Respond: the scene and the last-reported points')
    H.eq(m.route, false, 'no GPS line to a suspect')
    H.eq(#m.targets, 3, 'the scene and two last-reported points')
    H.eq(m.targets[2].label, 'Suspect A: last reported', 'named by label only')
    case.suspects.CA.lastCoords = vec3(1500.0, 1000.0, 30.0)
    H.advance(10000)
    B.tick(ctx, 1)
    H.eq(B.marker(ctx).targets[2].coords.x, 1200.0, 'never followed live: the point waits for the next report')
    H.advance(60000)
    B.tick(ctx, 1)
    H.eq(B.marker(ctx).targets[2].coords.x, 1500.0, 'the next report moves it')

    -- one suspect's state never changes the HUD or the checklist
    local before, huds = Checklist(ctx), #ctx.huds
    case.suspects.CA.state = 'cuffed'
    H.eq(Checklist(ctx), before, 'a cuffed suspect does not change the checklist')
    B.onEvent(ctx, nil, { type = 'opp_cuffed', cid = 'CA', label = 'A' })
    H.eq(#ctx.huds, huds, 'nor the HUD')

    for _ = 1, 60 do B.tick(ctx, 1) end
    H.eq(ctx.state.phase, 'detain', 'held the scene for secureSeconds: phase 3')
    H.eq(#Lines(ctx, 'live_scene'), 1, 'live_scene once')
    H.eq(Detail(ctx), 'Detain and book the suspects', 'the HUD says Detain and book the suspects')
    local last = ctx.huds[#ctx.huds]
    H.ok(last.value == false and last.max == false, 'Z9: the detain HUD removes the secure bar (no stale 60/60)')
    H.eq(Checklist(ctx), 'Respond=true,Secure the scene=true,Detain and book the suspects=false',
        'the Detain and book line stays open')
    H.eq(table.concat(timeline, ','), 'responded,scene_secured', 'the staff timeline has both phases')
    officer[1] = vec3(0.0, 0.0, 30.0)
end

-- ============================================================================
--          WEIGHTED DETAIN AND BOOKING LINES, END CASE, THE DEAD CASE
-- ============================================================================

do
    Case()
    timeline = {}
    local ctx = Ctx()
    B.prepare(ctx)
    B.start(ctx)
    H.ok(B.onEvent(ctx, nil, { type = 'opp_detained', cid = 'CA', label = 'A', share = 0.5 }), 'a detain is taken')
    B.onEvent(ctx, nil, { type = 'opp_detained', cid = 'CA', label = 'A', share = 1 })
    local d = Lines(ctx, 'live_detain')
    H.eq(#d, 1, 'one detain line per suspect')
    H.eq(d[1].opts.weight, 0.5, 'weighted by his share (cuffed while down)')
    H.eq(d[1].opts.src, nil, 'a shared line')
    B.onEvent(ctx, nil, { type = 'opp_detained', cid = 'CB', label = 'B', share = 0 })
    H.eq(#Lines(ctx, 'live_detain'), 1, 'an AFK catch (share 0) records no line')
    B.onEvent(ctx, nil, { type = 'opp_booked', cid = 'CA', label = 'A', share = 0.5 })
    H.eq(Lines(ctx, 'live_book')[1].opts.weight, 0.5, 'the booking line carries the same share')
    H.eq(#Lines(ctx, 'peaceful_arrest'), 0, 'no surrender module answer: no peaceful arrest line')
    -- Z8B: a suspect at maxCatchesPerSuspectDay when the case opened (CP.LiveCrime run.liveCapped) scores no line
    do
        local c8 = Ctx()
        c8.run.liveCapped = { CA = true }
        B.prepare(c8)
        B.start(c8)
        B.onEvent(c8, nil, { type = 'opp_detained', cid = 'CA', label = 'A', share = 1 })
        B.onEvent(c8, nil, { type = 'opp_detained', cid = 'CB', label = 'B', share = 1 })
        H.eq(#Lines(c8, 'live_detain'), 1, 'Z8B: the capped suspect gives no detain line, the other one does')
    end

    -- RP1: a detain CP.Opponents.peaceful calls peaceful scores the shared peaceful_arrest line (x his share) once,
    -- and the staff timeline names who talked him down
    local peaceful = { CB = 2 }
    CP.Opponents.peaceful = function(_, cid) return peaceful[cid] ~= nil, peaceful[cid] end
    local entries = {}
    local plainTimeline = CP.Opponents.timeline
    CP.Opponents.timeline = function(run, entry)
        entries[#entries + 1] = entry
        return plainTimeline(run, entry)
    end
    -- step G3: the officer who talked him down is paid once (Config.FeatureRewards.surrender; its own spec pays it)
    local frPaid = {}
    CP.FeatureRewards = {
        enabled = function(f) return f == 'surrender' end,
        payLater = function(feature, cid, opts)
            frPaid[#frPaid + 1] = { feature = feature, cid = cid, key = opts.key }
            return true
        end,
    }
    ctx.run.participants = { [1] = { citizenid = 'LR_OFF1' }, [2] = { citizenid = 'LR_OFF2' } }
    B.onEvent(ctx, nil, { type = 'opp_detained', cid = 'CB', label = 'B', share = 0.5 })
    B.onEvent(ctx, nil, { type = 'opp_detained', cid = 'CB', label = 'B', share = 0.5 })
    H.eq(#frPaid, 0, 'Z8B: nothing is paid at the detain')
    CP.Hooks.fire('run:ended', ctx.run, 'completed', 'completed')
    H.ok(#frPaid == 1 and frPaid[1].feature == 'surrender' and frPaid[1].cid == 'LR_OFF2' and frPaid[1].key == 'LR1:CB',
        'G3: the officer who talked him down is paid once per run and suspect, at the run\'s end')
    -- Z8B: an abandoned (cancelled, voided) run, a flagged run and a flagged officer pay no talk-down
    for _, case8 in ipairs({
        { state = 'abandoned', why = 'an abandoned run' },
        { state = 'completed', runFlag = true, why = 'a flagged run' },
        { state = 'completed', pFlag = true, why = 'a flagged officer' },
    }) do
        frPaid = {}
        local run8 = {
            id = 'LR8',
            flagged = case8.runFlag and { reason = 'x' } or nil,
            participants = { [2] = { citizenid = 'LR_OFF2', flagged = case8.pFlag and { reason = 'x' } or nil } },
        }
        B.onEvent({
            run = run8,
            state = {},
            award = function() return true end,
            hud = ctx.hud,
        }, nil, { type = 'opp_detained', cid = 'CB', label = 'B', share = 1 })
        H.eq(run8.talkDowns and run8.talkDowns.CB, 2, 'Z8B: the talk-down is noted (' .. case8.why .. ')')
        CP.Hooks.fire('run:ended', run8, case8.state, 'x')
        H.eq(#frPaid, 0, 'Z8B: ' .. case8.why .. ' pays no talk-down')
    end
    CP.FeatureRewards = nil
    local p = Lines(ctx, 'peaceful_arrest')
    H.eq(#p, 1, 'a peaceful detain: one peaceful_arrest line per suspect')
    H.eq(p[1].opts.weight, 0.5, 'weighted by his share')
    H.eq(p[1].opts.src, nil, 'shared by the unit')
    local pl = entries[#entries]
    H.ok(pl and pl.what == 'peaceful_arrest' and pl.by == 2 and pl.label == 'B', 'the timeline names officer 2')
    -- step Z2: a run with rs_linked_accounts (an officer shares a connection or PC with a suspect) pays no talk-down
    do
        local savedAC, paidZ = CP.AntiCheat, {}
        CP.AntiCheat = {
            flaggedWith = function(_, reason) return reason == 'rs_linked_accounts' end,
        }
        CP.FeatureRewards = {
            enabled = function(f) return f == 'surrender' end,
            payLater = function(feature, cid) paidZ[#paidZ + 1] = { feature = feature, cid = cid } return true end,
        }
        peaceful.CZ = 2
        B.onEvent(ctx, nil, { type = 'opp_detained', cid = 'CZ', label = 'Z', share = 1 })
        CP.Hooks.fire('run:ended', ctx.run, 'completed', 'completed')
        H.eq(#paidZ, 0, 'Z2: a linked-accounts run pays no talk-down')
        CP.AntiCheat, CP.FeatureRewards = savedAC, nil
    end
    CP.Opponents.peaceful, CP.Opponents.timeline = nil, plainTimeline
    local ok, why = B.onEvent(ctx, 2, { type = 'end_case' })
    H.ok(ok == false and why == 'not_host', 'End case: only the unit leader')
    H.eq(ctx.completed, nil, 'a partner cannot end the case')
    H.ok(B.onEvent(ctx, 1, { type = 'end_case' }), 'the unit leader ends the case')
    H.eq(ctx.completed and ctx.completed.reason, 'end_case', 'End case completes the objective')
    H.eq((B.onEvent(ctx, 1, { type = 'bogus' })), false, 'other client evidence is refused')

    -- the dead case: no suspect left to work for deadCaseSeconds
    Case()
    ctx = Ctx()
    B.prepare(ctx)
    B.start(ctx)
    case.suspects.CA.state = 'booked'
    case.suspects.CB.state = 'detained'
    B.tick(ctx, 1)
    H.eq(ctx.completed, nil, 'a detained suspect can still be booked: the case stays open')
    case.suspects.CB.state = 'lost'
    B.tick(ctx, 1)
    H.advance(29000)
    B.tick(ctx, 1)
    H.eq(ctx.completed, nil, 'not before deadCaseSeconds')
    H.advance(1000)
    B.tick(ctx, 1)
    H.eq(ctx.completed and ctx.completed.reason, 'dead_case', 'then the dead case ends')

    -- presence: the scene (its radius counts as on it) or a suspect's last server position
    officer[2] = vec3(1050.0, 1000.0, 30.0)
    H.eq(B.presence(ctx, 2), 0, 'inside the scene radius: present')
    H.eq(B.presence(ctx, nil, vec3(1200.0, 1010.0, 30.0)), 10.0, 'near a suspect\'s last position')
    officer[2] = vec3(0.0, 0.0, 30.0)

    -- lastReportedEvery = 0: no suspect point at all
    Config.RealPlayers.liveCrime.lastReportedEvery = 0
    Case()
    ctx = Ctx()
    B.prepare(ctx)
    B.start(ctx)
    officer[1] = vec3(1000.0, 1000.0, 30.0)
    B.tick(ctx, 1)
    H.eq(#B.marker(ctx).targets, 1, 'only the scene')
    Config.RealPlayers.liveCrime.lastReportedEvery = 60
    officer[1] = vec3(0.0, 0.0, 30.0)
end

-- ============================================================================
--                 CP.Runs.award opts.weight AND THE SCORE LINE
-- ============================================================================

do
    H.load('modules/runs/server.lua')
    local run = {
        id = 'W1',
        state = 'in_progress',
        participants = { [1] = { score = {}, status = 'active' } },
        score = { shared = {}, values = {}, kinds = {} },
    }
    H.ok(CP.Runs.award(run, 'live_detain', { weight = 0.5 }), 'a weighted line')
    CP.Runs.award(run, 'live_detain', { weight = 1 })
    H.eq(run.score.shared.live_detain, 1.5, 'counted as a part of one occurrence')
    H.eq(CP.Runs.award(run, 'live_detain', { weight = 0 }), false, 'weight 0 records nothing')
    CP.Runs.award(run, 'hostile_arrested', { count = 2 })
    H.eq(run.score.shared.hostile_arrested, 2, 'no weight: whole occurrences as before')

    H.load('modules/scaling/server.lua')
    H.load('modules/progression/scoring.lua')
    local p = { src = 1, department = 'sast', status = 'active', score = {}, vehicle = { seen = false } }
    local srun = {
        id = 2,
        missionType = 'investigation',
        mission = { type = 'investigation', points = 100 },
        pointsBase = 100,
        payTier = { tier = 'standard', points = 1.0, cash = 1.0 },
        participants = { [1] = p },
        order = { 1 },
        shared = {},
        score = { shared = { live_detain = 1.5 }, values = {}, kinds = { live_detain = 'bonus' } },
        startedAt = os.time() - 300,
    }
    local b = CP.Scoring.compute(srun, p, 'completed', { durationS = 300, departments = 1 })
    local line = nil
    for _, l in ipairs(b.bonuses or {}) do if l.id == 'live_detain' then line = l end end
    H.ok(line ~= nil, 'the weighted line is scored')
    H.eq(line and line.points, math.floor(0.5 * b.P * 1.5 + 0.5), 'live_detain: 50% of P x 1.5')
end

-- ============================================================================
--                      ENGINE-ONLY: THE LOADER REFUSES IT
-- ============================================================================

do
    H.load('modules/missions/server.lua')
    local def = {
        id = 'lr_file',
        label = 'Live file',
        type = 'investigation',
        timeLimit = 900,
        locations = { { label = 'Here', start = { coords = vec3(0.0, 0.0, 30.0), radius = 30.0 } } },
        objectives = { { block = 'live_response' } },
    }
    local out, err = CP.Missions.normalize(def, { quiet = true })
    H.eq(out, nil, 'a mission file with live_response is refused')
    H.eq(err, 'objective 1 uses engine-only block "live_response"', 'and says why')
    H.eq(CP.Missions.plainReason(err),
        'Objective 1 uses the block "live_response", which only the server\'s own ' .. 'live cases use.',
        'in plain words')
    local _, err2 = CP.Missions.normalize(def, { quiet = true, engine = true })
    H.ok(err2 == nil or not tostring(err2):find('engine%-only'), 'the engine itself may build it')
end

-- Z10: a suspect detained or booked before In progress (no opp_* event then) scores when the block starts
do
    Case()
    timeline = {}
    case.suspects.CA.state = 'booked'
    case.suspects.CA.share = 1
    case.suspects.CB.state = 'detained'
    case.suspects.CB.share = 0.5
    local ctx = Ctx()
    B.prepare(ctx)
    B.start(ctx)
    H.eq(#Lines(ctx, 'live_detain'), 2, 'Z10: both early detains score at the start')
    H.eq(#Lines(ctx, 'live_book'), 1, 'Z10: the early booking scores at the start')
    H.eq(Lines(ctx, 'live_detain')[2].opts.weight, 0.5, 'Z10: with the suspect\'s share')
    B.onEvent(ctx, nil, { type = 'opp_booked', cid = 'CA', share = 1 })
    H.eq(#Lines(ctx, 'live_book'), 1, 'Z10: a later event for the same suspect scores nothing twice')
end

return H
