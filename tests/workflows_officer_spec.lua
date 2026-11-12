-- WF5A: every officer workflow, extensively (the owner: "do extensive workflow testing on everything").

-- WF5A: every officer workflow, extensively (the owner: "do extensive workflow testing on everything").
-- Every workflow and every action an officer can take, driven start to finish on the REAL server side of
-- Crimson-Police: the world of tests/workflows_full_spec.lua (every server file of fxmanifest loaded as in game, the
-- owner's scripts running, database off: the saves folder, as shipped), booted on the shipped config with no
-- section of that spec run (CP_WF_WORLD). Each part runs on the shipped config first, then with the switches on that
-- the admin turns on through the Admin UI's own Settings action, with a `restart Crimson-Police` and a player drop and
-- reconnect in the middle, and every refusal an officer can meet (no permission, wrong department, caps reached,
-- feature off, maintenance lock). docs/dev/WORKFLOWS.md lists each workflow with its section here.
--   1. Duty and the tablet: the command, the key, a desk, the item; off duty, not police.
--   2. Mission Board: accept for every built-in mission (every block) to the result card, points, cash and items.
--   3. Twists and goals.
--   4. Refusals of an accept: not police, wrong department, caps, feature off, maintenance lock.
--   5. A unit: form, invite, ready, promote, kick, leave, disband, cancel an invite; its refusals.
--   6. Dispatch: claim, decline, a pushed mission, their refusals.
--   7. Cross-Department join and its refusals.
--   8. The Me screen (profile, leaderboard, challenge) and My options, with a restart and a drop.
--   9. Field training as the rookie.
--  10. Downed, abandon, off duty and logout mid-run; a drop in each block the other specs leave out.

_G.CP_WF_WORLD = 'officer'
local W = dofile('tests/workflows_full_spec.lua')
_G.CP_WF_WORLD = nil
local H, CID, PD = W.H, W.CID, W.PD
local Act, Cb, Secs, Place, Setting = W.Act, W.Cb, W.Secs, W.Place, W.Setting

-- Every other mission of the type is off, so the type draws missionId.
local function OnlyMission(typeKey, missionId)
    local off = {}
    for _, def in ipairs(CP.Missions.byType(typeKey)) do
        if def.id ~= missionId then off[#off + 1] = def.id end
    end
    return off
end
-- The run of missionId accepted from the Mission Board (every other mission of its type off for the draw only).
local function AcceptOnly(src, typeKey, missionId)
    local run = W.Accept(src, typeKey, OnlyMission(typeKey, missionId))
    Config.DisabledMissions = {}
    return run
end
-- Every cooldown and the hourly cap of the runs before are over.
local function Later() H.time = H.time + 3700 end
local function Open(src, args)
    args = args or {}
    args.ui = args.ui or 'officer'
    args.via = args.via or 'command'
    return Cb('getSession', src, args)
end
local function Leave(src)
    local run = CP.Runs.getBySrc(src)
    if run then Act('server:abandon', src, run.id) end
    if CP.Units.unitOf(src) then Act('server:teamLeave', src) end
end
-- One objective done: its block's own completion (ctx.complete) after the objective's minimum time. The blocks'
-- evidence for each step is driven by tests/blocks_{a,b,c}_spec.lua and the block specs; here the run's lifecycle,
-- the result card and the pay are what count.
local function FinishObjective(run, i)
    local o = run.objectives[i]
    if o and o.status == 'done' then
        return true
    end -- the block finished it by itself (nothing left to do)
    if not o or run.objectiveIndex ~= i then return false end
    local waited = (H.clockMs - (o.startedAtMs or H.clockMs)) / 1000
    local minS = (o.obj and o.obj.minSeconds or 0) + 1
    if waited < minS then Secs(math.ceil(minS - waited)) end
    return CP.Runs.objectiveComplete(run, i, {}) or o.status == 'done'
end
-- A checkpoint route (objective 1) driven at a steady pace: every checkpoint reached no faster than 40 m/s, the
-- whole course over at least minS seconds (the last checkpoint ends the objective).
local function DriveSteady(src, run, veh, minS)
    local st = run.objectives[1].state
    local per = math.ceil(((minS or 0) + 4) / math.max(1, #st.points))
    for k = 1, #st.points do
        local c, at = st.points[k], H.players[src].coords
        local far = math.sqrt((c.x - at.x) ^ 2 + (c.y - at.y) ^ 2 + (c.z - at.z) ^ 2)
        Secs(math.max(per - 3, math.ceil(far / 40.0), 1))
        Place(src, c)
        W.ents[veh].coords = H.players[src].coords
        Secs(3)
        W.Objective(src, run, 1, W.CheckpointEv(k, veh))
    end
    Secs(2)
end
-- The crew goes to c at a steady 40 m/s (never faster than Config.AntiCheat.maxSpeed between two events).
local function MoveTo(crew, c)
    local far = 0
    for _, src in ipairs(crew) do
        local at = H.players[src].coords
        far = math.max(far, math.sqrt((c.x - at.x) ^ 2 + (c.y - at.y) ^ 2 + (c.z - at.z) ^ 2))
    end
    if far > 40.0 then Secs(math.ceil(far / 40.0)) end
    for _, src in ipairs(crew) do Place(src, c) end
end
-- interact_points worked for real: each pending point reached by the whole crew, held for its progress time and
-- checked by each of them (a together point needs them all); a follow-up is done the same way.
local function WorkPoints(run, i, crew)
    local o = run.objectives[i]
    local st = o.state or {}
    local hold = (tonumber(o.obj and o.obj.progress and o.obj.progress.duration) or 0) / 1000 + 2
    for k, p in ipairs(st.points or {}) do
        if run.state ~= 'in_progress' or run.objectiveIndex ~= i then return end
        for _, step in ipairs({ 'interact', 'followup' }) do
            if p.status == (step == 'interact' and 'pending' or 'followup') then
                MoveTo(crew, p.coords)
                Secs(math.ceil(hold))
                for _, src in ipairs(crew) do W.Objective(src, run, i, { type = step, point = k }) end
                Secs(1)
            end
        end
    end
end
-- hostile_waves worked for real: the crew at the scene, every live hostile of objective i taken down by the lead.
local function WorkWaves(run, i, crew)
    local at = run.location and run.location.start and run.location.start.coords
    if at then MoveTo(crew, at) end
    -- the last hostile down before the objective's minimum time would be a too fast finish (held for review)
    local o = run.objectives[i]
    local minS = (o.obj and o.obj.minSeconds or 0) + 2
    local waited = (H.clockMs - (o.startedAtMs or H.clockMs)) / 1000
    if waited < minS then Secs(math.ceil(minS - waited)) end
    local t = 0
    while run.state == 'in_progress' and run.objectiveIndex == i and t < 400 do
        for _, e in ipairs(CP.Runs.entitiesFor(run, { obj = i, kind = 'ped', alive = true })) do
            local x = W.ents[e.entity]
            if x and x.exists and x.health > 0 then
                x.killer = crew[1] * 100
                x.health = 0
            end
        end
        Secs(3)
        t = t + 3
    end
end
-- Objective i worked: by its real evidence where this spec has it (a checkpoint route driven, every point checked,
-- every hostile down), then (or for the other blocks) its block's own completion after its minimum time.
local function Work(run, i, crew)
    local o = run.objectives[i]
    local block = o and o.obj and o.obj.block
    if block == 'checkpoint_route' and i == 1 then
        DriveSteady(crew[1], run, W.TakeWheel(crew[1], run), o.obj.minSeconds)
    elseif block == 'interact_points' then
        WorkPoints(run, i, crew)
    elseif block == 'hostile_waves' then
        WorkWaves(run, i, crew)
    end
    return FinishObjective(run, i)
end
local function Errs(list)
    local s = {}
    for _, e in ipairs(list) do s[#s + 1] = tostring(e) end
    return table.concat(s, ', ')
end
local function RunRow(runId, cid)
    return H.sql('SELECT state, end_reason, cash_paid FROM cp_mission_runs WHERE run_uuid = ? AND citizenid = ?',
        { runId, cid })[1] or {}
end

local AT = vec3(-300.0, -1400.0, 30.0)

-- ============================================================================
--                1. DUTY AND THE TABLET (SHIPPED CONFIG FIRST)
-- ============================================================================

do
    H.eq(Config.Database.enabled, W.ON_DB,
        W.ON_DB and 'database on (MariaDB)' or 'shipped: database off (the saves folder)')
    H.eq(Config.Rewards.enabled, false, 'shipped: item rewards off')
    H.eq(Config.Tablet.item, false, 'shipped: no tablet item')
    H.eq(Config.Tablet.access.requireItem, false, 'shipped: the item is never required')

    -- the command and the key open the Officer UI; the item way is off while no item is set
    local s, why = Open(1, { via = 'command' })
    H.eq(s and s.access and s.access.via, 'command', 'tablet: /CrimsonPolice opens the Officer UI: ' .. tostring(why))
    s, why = Open(1, { via = 'keybind' })
    H.eq(s and s.access and s.access.via, 'keybind', 'tablet: the key opens it: ' .. tostring(why))
    s, why = Open(1, { via = 'item' })
    H.eq(why, 'err.access_off', 'tablet: no item set: the item way is refused')

    -- a desk: at it, it opens; a step away, it is refused
    local desk = Config.Tablet.desks[1]
    Place(1, desk.coords)
    s, why = Open(1, { via = 'desk', desk = 1 })
    H.eq(s and s.access and s.access.via, 'desk', 'desk: at the Mission Row desk it opens: ' .. tostring(why))
    Place(1, AT)
    s, why = Open(1, { via = 'desk', desk = 1 })
    H.eq(why, 'err.not_at_desk', 'desk: away from it: refused')
    s, why = Open(1, { via = 'desk', desk = 99 })
    H.eq(why, 'err.not_at_desk', 'desk: an unknown desk: refused')

    -- off duty, not police, a supervisor tablet for an officer
    PD[1].job.onduty = false
    TriggerEvent('QBCore:Server:SetDuty', 1, false)
    Secs(2)
    s, why = Open(1)
    H.eq(why, 'err.not_on_duty', 'duty: off duty: the Officer UI is refused')
    local ok, err = Act('server:acceptType', 1, 'patrol')
    H.eq(ok, false, 'duty: off duty: no accept (' .. tostring(err) .. ')')
    PD[1].job.onduty = true
    TriggerEvent('QBCore:Server:SetDuty', 1, true)
    Secs(2)
    s, why = Open(1)
    H.ok(s ~= nil, 'duty: back on duty: it opens again: ' .. tostring(why))
    s, why = Open(5)
    H.eq(why, 'err.not_police', 'tablet: a civilian (the admin, not police): refused')
    s, why = Open(1, { ui = 'supervisor' })
    H.eq(why, 'err.not_supervisor', 'tablet: an officer cannot open the Supervisor UI')
    H.ok(Open(3, { ui = 'supervisor' }) ~= nil, 'tablet: the supervisor opens his')
end

-- ============================================================================
--                            2a. THE SHIPPED CONFIG
-- ============================================================================
-- A BEAT PATROL TO THE PAY, NO ITEM.

do
    Place(1, AT)
    local types = Cb('getMissionTypes', 1)
    local keys = {}
    for _, c in ipairs(types and types.cards or {}) do keys[c.key] = c end
    for _, k in ipairs({ 'patrol', 'training', 'investigation', 'tactical' }) do
        H.ok(keys[k] ~= nil, 'board: the Mission Board shows ' .. k)
        H.eq(keys[k] and keys[k].cash and keys[k].cash[1], Config.MissionTypes[k].payout,
            'board: ...with its payout ' .. k)
    end
    local mark, money0, items0 = #H.events, #W.addMoney, #W.addItem
    local run = AcceptOnly(1, 'patrol', 'beat_patrol')
    H.eq(run and run.missionId, 'beat_patrol', 'shipped: Beat Patrol drawn')
    local veh = W.TakeWheel(1, run)
    W.DriveCheckpoints(1, run, veh)
    Secs(3)
    H.eq(run.state, 'ended', 'shipped: every checkpoint driven: the run ends')
    local card = W.RunEnded(1, mark)
    H.eq(card and card.result, 'completed', 'shipped: the result card says Completed')
    local row = W.Rows('run_uuid = ?', { run.id })[1] or {}
    H.eq(row.state, 'completed', 'shipped: the row is Completed')
    H.eq(card and card.points and card.points.final, row.final_points, 'shipped: the card shows the row\'s points')
    H.eq(card and card.cash and card.cash.paid, 250, 'shipped: the card shows $250')
    H.eq(#W.addMoney, money0 + 1, 'shipped: paid once')
    H.eq(W.addMoney[#W.addMoney].amount, 250, 'shipped: ...$250')
    H.eq(#W.addItem, items0, 'shipped: item rewards off: no item')
    H.eq(W.Xp(CID[1]), row.final_points, 'shipped: the XP is the row\'s points')
    local ok, err = Act('server:acceptType', 1, 'patrol')
    H.eq(ok, true, 'shipped: no type cooldown after a completed run: ' .. tostring(err))
    Leave(1)
end

-- ============================================================================
--                     2b. THE ADMIN TURNS THE SWITCHES ON
-- ============================================================================

do
    local pool = { chance = 1.0, rolls = 1, pool = { { item = 'water', count = 1, weight = 1, value = 20 } } }
    for _, c in ipairs({
        { 'Rewards.enabled', true },
        { 'Rewards.byType', { patrol = pool, training = pool, investigation = pool, tactical = pool } },
        { 'Permissions.supervisor.missionControls', true },
        { 'Tablet.item', 'police_tablet' },
        { 'Recognition.fieldTraining.enabled', true },
        { 'Recognition.fieldTraining.requireTrainerFor', { 'tactical' } },
    }) do
        local ok, err = Setting(c[1], c[2])
        H.eq(ok, true, ('settings: %s saved: %s'):format(c[1], tostring(err)))
    end
    local controls = CP.U.copy(Config.MissionControls.controls)
    for _, c in pairs(controls) do c.on = true end
    local ok, err = Setting('MissionControls.controls', controls)
    H.eq(ok, true, 'settings: every Mission control on: ' .. tostring(err))

    -- the item way now opens it; with the item required, the other ways need it in the pockets
    local s, why = Open(1, { via = 'item' })
    H.eq(s and s.access and s.access.via, 'item', 'item: using the tablet item opens it: ' .. tostring(why))
    ok, err = Setting('Tablet.access.requireItem', true)
    H.eq(ok, true, 'item: the admin requires the item: ' .. tostring(err))
    s, why = Open(1)
    H.eq(why, 'err.no_tablet_item', 'item: no item: /CrimsonPolice is refused')
    ok, err = Act('server:acceptType', 1, 'patrol')
    H.eq(err, 'err.no_tablet_item', 'item: ...and an accept too')
    local inv = H.exportsMock.ox_inventory
    local search = inv.Search
    inv.Search = function(_, kind, item) return (kind == 'count' and item == 'police_tablet') and 1 or {} end
    H.ok(Open(1) ~= nil, 'item: with the item in his pockets it opens')
    inv.Search = search
    local desk = Config.Tablet.desks[1]
    Place(1, desk.coords)
    H.ok(Open(1, { via = 'desk', desk = 1 }) ~= nil, 'item: a desk never needs it')
    ok, err = Setting('Tablet.access.requireItem', false)
    H.eq(ok, true, 'item: not required again: ' .. tostring(err))
    ok, err = Setting('Tablet.access.command', false)
    H.eq(ok, true, 'ways: the admin turns the command off: ' .. tostring(err))
    s, why = Open(1, { via = 'command' })
    H.eq(why, 'err.access_off', 'ways: /CrimsonPolice refused while it is off')
    Setting('Tablet.access.command', true)

    -- a desk for FIB only: a SAST officer is refused there
    local desks = CP.U.copy(Config.Tablet.desks)
    desks[1].departments = { 'fib' }
    ok, err = Setting('Tablet.desks', desks)
    H.eq(ok, true, 'desk: the admin gives desk 1 to FIB: ' .. tostring(err))
    s, why = Open(1, { via = 'desk', desk = 1 })
    H.eq(why, 'err.desk_department', 'desk: a SAST officer at the FIB desk: refused')
    Place(2, desk.coords)
    H.ok(Open(2, { via = 'desk', desk = 1 }) ~= nil, 'desk: the FIB agent opens it')
    desks[1].departments = nil
    Setting('Tablet.desks', desks)
    Place(1, AT)
    Place(2, AT)

    W.Restart()
    H.eq(Config.Tablet.item, 'police_tablet', 'restart: the tablet item kept')
    H.eq(Config.Rewards.enabled, true, 'restart: item rewards still on')
    H.ok(Open(1, { via = 'item' }) ~= nil, 'restart: the item way still opens it')
    W.Drop(1)
    W.Reconnect(1)
    H.ok(Open(1) ~= nil, 'reconnect: the officer opens the Officer UI again')
end

-- ============================================================================
--  2c. EVERY BUILT-IN MISSION FROM THE BOARD TO THE RESULT CARD (EVERY BLOCK)
-- ============================================================================
-- The unit is as small as the mission allows (minOfficers). Weekly Boss: tests/workflows_full_spec.lua (3).

local blocksSeen = {}
local function PlayMission(typeKey, def, crew)
    Later()
    local lead = crew[1]
    for k, src in ipairs(crew) do Place(src, vec3(AT.x + k * 2.0, AT.y, AT.z)) end
    for k = 2, #crew do W.FormUnit(lead, crew[k]) end
    local mark, xp0 = #H.events, W.Xp(CID[lead])
    local paid0, items0 = select(2, W.Paid(CID[lead])), W.ItemsGiven(lead, 'water')
    Config.DisabledMissions = OnlyMission(typeKey, def.id)
    local ok, err = Act('server:acceptType', lead, typeKey)
    Config.DisabledMissions = {}
    H.eq(ok, true, ('every: %s accepted: %s'):format(def.id, tostring(err)))
    local run = CP.Runs.getBySrc(lead)
    H.eq(run and run.missionId, def.id, ('every: %s drawn'):format(def.id))
    if not run then
        for _, src in ipairs(crew) do Leave(src) end
        return
    end
    for _, src in ipairs(crew) do W.Arrive(run, src) end
    Secs(3)
    H.eq(run.state, 'in_progress', ('every: %s in progress'):format(def.id))
    H.ok(type(Cb('getRun', lead)) == 'table', ('every: %s: Active Mission shows the run'):format(def.id))
    for i = 1, #run.objectives do
        local o = run.objectives[i]
        local block = o.obj and (o.obj.block or o.obj.type) or '?'
        blocksSeen[block] = true
        local done = Work(run, i, crew)
        H.eq(done, true, ('every: %s objective %d (%s) done'):format(def.id, i, block))
        if not done then break end
    end
    Secs(3)
    H.eq(run.state, 'ended', ('every: %s ended'):format(def.id))
    local card = W.RunEnded(lead, mark)
    H.eq(card and card.result, 'completed', ('every: %s: the result card says Completed'):format(def.id))
    local row = W.Rows('run_uuid = ? AND citizenid = ?', { run.id, CID[lead] })[1] or {}
    H.eq(row.state, 'completed', ('every: %s: the row is Completed'):format(def.id))
    H.eq(row.mission_type, typeKey, ('every: %s: the row has its type'):format(def.id))
    H.ok((tonumber(row.final_points) or 0) > 0, ('every: %s: points earned'):format(def.id))
    H.eq(card and card.points and card.points.final, row.final_points,
        ('every: %s: the card shows the row\'s points'):format(def.id))
    H.eq(W.Xp(CID[lead]) - xp0, row.final_points, ('every: %s: the XP grew by them'):format(def.id))
    local cash = tonumber(row.cash_paid) or 0
    H.eq(row.flagged == true or tonumber(row.flagged) == 1, false, ('every: %s: not held for review (%s)'):format(
        def.id,
        tostring((CP.U.jsonField(row.breakdown) or {}).flagged and CP.U.jsonField(row.breakdown).flagged.reason)))
    H.ok(cash >= Config.MissionTypes[typeKey].payout,
        ('every: %s: paid at least the %s payout ($%d)'):format(def.id, typeKey, cash))
    H.eq(card and card.cash and card.cash.paid, cash, ('every: %s: the card shows the cash'):format(def.id))
    H.eq(select(2, W.Paid(CID[lead])) - paid0, cash, ('every: %s: the bank got it once'):format(def.id))
    H.eq(W.ItemsGiven(lead, 'water') - items0, 1, ('every: %s: the item reward given'):format(def.id))
    for k = 2, #crew do
        local r = RunRow(run.id, CID[crew[k]])
        H.eq(r.state, 'completed', ('every: %s: the partner\'s row is Completed'):format(def.id))
    end
    H.ok(CP.Runs.cooldowns(CID[lead]).missions[def.id] ~= nil, ('every: %s: on its cooldown'):format(def.id))
    for _, src in ipairs(crew) do Leave(src) end
end

do
    local count = 0
    for _, typeKey in ipairs({ 'patrol', 'training', 'investigation', 'tactical' }) do
        for _, def in ipairs(CP.Missions.byType(typeKey)) do
            if def.id ~= 'weekly_boss_kingpin' then
                local crew = { 1 }
                if (def.minOfficers or 1) >= 2 then crew = { 1, 6 } end
                PlayMission(typeKey, def, crew)
                count = count + 1
            end
        end
    end
    H.ok(count >= 18, 'every: every built-in mission played (' .. count .. ')')
    local missing = {}
    for _, b in ipairs({
        'checkpoint_route',
        'interact_points',
        'field_contact',
        'pursuit',
        'search_area',
        'flee_arrest',
        'process_scene',
        'escort',
        'skill_check',
        'hostile_waves',
        'protect_rescue',
    }) do
        if not blocksSeen[b] then missing[#missing + 1] = b end
    end
    H.eq(Errs(missing), '', 'every: every mission block was worked')
end

-- ============================================================================
--                            2d. THE REWARDS LOCKER
-- ============================================================================
-- NO ROOM IN THE POCKETS, CLAIMED LATER.

do
    local inv = H.exportsMock.ox_inventory
    local canCarry = inv.CanCarryItem
    inv.CanCarryItem = function() return false end
    Later()
    Place(1, AT)
    local items0 = W.ItemsGiven(1, 'water')
    local run = AcceptOnly(1, 'training', 'evoc_course')
    if run then
        W.Arrive(run, 1)
        Secs(3)
        Work(run, 1, { 1 })
        Secs(3)
    end
    H.eq(W.ItemsGiven(1, 'water'), items0, 'locker: no room: the item is not given')
    local locker = Cb('getRewardsLocker', 1)
    local pending
    for _, r in ipairs(locker and locker.rows or {}) do if r.status == 'pending' then pending = r end end
    H.ok(pending ~= nil, 'locker: ...it waits in his Rewards locker')
    local ok, err = Act('server:rewards:claim', 1, { id = pending and pending.id })
    H.eq(ok, false, 'locker: still no room: the claim is refused (' .. tostring(err) .. ')')
    ok, err = Act('server:rewards:claim', 6, { id = pending and pending.id })
    H.eq(err, 'err.reward_not_found', 'locker: another officer cannot claim it')
    W.Restart()
    W.Drop(1)
    W.Reconnect(1)
    locker = Cb('getRewardsLocker', 1)
    local again
    for _, r in ipairs(locker and locker.rows or {}) do if pending and r.id == pending.id then again = r end end
    H.eq(again and again.status, 'pending', 'restart and reconnect: still in the locker')
    inv.CanCarryItem = canCarry
    -- the claim, or the locker's own delivery at his login (officer:loaded) once there is room
    ok, err = Act('server:rewards:claim', 1, { id = pending and pending.id })
    H.ok(ok == true or err == 'err.reward_not_claimable', 'locker: room again: claimed: ' .. tostring(err))
    H.eq(W.ItemsGiven(1, 'water'), items0 + 1, 'locker: ...given once')
    ok, err = Act('server:rewards:claim', 1, { id = pending and pending.id })
    H.eq(err, 'err.reward_not_claimable', 'locker: a second claim is refused')
    H.eq(W.ItemsGiven(1, 'water'), items0 + 1, 'locker: ...still given once')
end

-- ============================================================================
--                             3. TWISTS AND GOALS
-- ============================================================================

do
    Later()
    Place(1, AT)
    local mark = #H.events
    Config.DisabledMissions = OnlyMission('training', 'evoc_course')
    local ok, err = Act('server:acceptType', 1, { missionType = 'training', twists = { 'time_crunch' } })
    Config.DisabledMissions = {}
    H.eq(ok, true, 'twist: EVOC accepted with Time Crunch: ' .. tostring(err))
    local run = CP.Runs.getBySrc(1)
    local has = false
    for _, t in ipairs(run and run.modifiers or {}) do if t == 'time_crunch' then has = true end end
    H.ok(has, 'twist: the run carries Time Crunch')
    if run then
        -- a quarter less time: the steady drive still makes it
        DriveSteady(1, run, W.TakeWheel(1, run), run.objectives[1].obj.minSeconds)
        Secs(3)
        local card = W.RunEnded(1, mark)
        H.eq(
            card and card.result,
            'completed',
            'twist: completed (' .. tostring(card and card.endReason) .. ', ' .. tostring(run.mission.timeLimit)
                .. ' s, ' .. #run.objectives[1].state.points .. ' points)'
        )
        local row = W.Rows('run_uuid = ?', { run.id })[1] or {}
        H.ok((tonumber(row.cash_paid) or 0) > Config.MissionTypes.training.payout,
            'twist: the twist raised the pay (' .. tostring(row.cash_paid) .. ')')
        H.ok(next(card and card.twists or {}) ~= nil, 'twist: the result card lists it')
    end
    Leave(1)
    Later()
    ok, err = Act('server:acceptType', 1, { missionType = 'training', twists = { 'no_such_twist' } })
    H.eq(ok, false, 'twist: an unknown twist is refused (' .. tostring(err) .. ')')
    Leave(1)

    -- goals: Home shows the daily and weekly goals
    local home = Cb('getHome', 1)
    H.ok(home and home.goals and home.goals.daily ~= nil, 'goals: Home shows the daily goal')
    H.ok(home and home.goals and home.goals.weekly ~= nil, 'goals: ...and the weekly goal')
end

-- ============================================================================
--                           4. REFUSALS OF AN ACCEPT
-- ============================================================================

do
    Later()
    Place(1, AT)
    Place(2, AT)
    -- no permission
    local ok, err = Act('server:acceptType', 5, 'patrol')
    H.eq(err, 'err.not_police', 'refuse: a civilian cannot accept')
    ok, err = Act('server:acceptType', 1, 'no_such_type')
    H.eq(err, 'err.invalid_type', 'refuse: an unknown type')

    -- wrong department: the SAST supervisor switches Investigation off for SAST; FIB still runs it
    ok, err = Act('server:sup:setMissionControl', 3,
        { key = 'types', value = { investigation = false }, reason = 'WF5A', requestId = W.RequestId() })
    H.eq(ok, true, 'refuse: SAST switches Investigation off: ' .. tostring(err))
    ok, err = Act('server:acceptType', 1, 'investigation')
    H.eq(err, 'err.type_off_department', 'refuse: a SAST officer cannot accept it')
    ok, err = Act('server:acceptType', 2, 'investigation')
    H.eq(ok, true, 'refuse: the FIB agent can: ' .. tostring(err))
    Leave(2)
    ok, err = Act('server:sup:setMissionControl', 1,
        { key = 'types', value = { patrol = false }, reason = 'WF5A', requestId = W.RequestId() })
    H.eq(ok, false, 'refuse: an officer cannot change a Mission control (' .. tostring(err) .. ')')
    H.time = H.time + 301                          -- Z14: a reset waits for the change wait like a set
    ok, err = Act('server:sup:resetMissionControl', 3, { key = 'types', reason = 'WF5A', requestId = W.RequestId() })
    H.eq(ok, true, 'refuse: reset to config.lua: ' .. tostring(err))

    -- caps: the hourly cap, the type's daily limit
    ok, err = Setting('Limits.maxCompletionsHour', 1)
    H.eq(ok, true, 'caps: the hourly cap set to 1: ' .. tostring(err))
    local run = AcceptOnly(1, 'training', 'evoc_course')
    if run then
        local veh = W.TakeWheel(1, run)
        DriveSteady(1, run, veh, run.objectives[1].obj.minSeconds)
        Secs(3)
    end
    ok, err = Act('server:acceptType', 1, 'patrol')
    H.eq(err, 'err.hourly_cap', 'caps: one completed run this hour: the next one is refused')
    Setting('Limits.maxCompletionsHour', 8)
    ok, err = Setting('MissionTypes.training.dailyLimit', 1)
    H.eq(ok, true, 'caps: Training limited to one a day: ' .. tostring(err))
    ok, err = Act('server:acceptType', 1, 'training')
    H.eq(err, 'err.type_daily_cap', 'caps: a second Training today is refused')
    ok, err = Setting('MissionTypes.training.dailyLimit', 0)
    H.eq(ok, true, 'caps: no daily limit again: ' .. tostring(err))
    Leave(1)

    -- a mission ban
    ok, err = Act('server:sup:missionBan', 3,
        { citizenid = CID[1], hours = 1, reason = 'WF5A', requestId = W.RequestId() })
    H.eq(ok, true, 'ban: the supervisor bars the officer for an hour: ' .. tostring(err))
    ok, err = Act('server:acceptType', 1, 'patrol')
    H.eq(err, 'err.mission_banned', 'ban: his accept is refused')
    ok, err = Act('server:restriction', 3, { op = 'lift', kind = 'missionBan', citizenid = CID[1], reason = 'WF5A' })
    H.eq(ok, true, 'ban: lifted: ' .. tostring(err))

    -- feature off: My options switched off for everyone
    ok, err = Setting('OfficerOptions.enabled', false)
    H.eq(ok, true, 'feature: My options off: ' .. tostring(err))
    ok, err = Act('server:options:set', 1, { skipAcceptConfirm = true })
    H.eq(err, 'err.option_locked', 'feature: an option change is refused')
    Setting('OfficerOptions.enabled', true)

    -- the maintenance lock (a restore or a storage copy): no new run until the restart
    CP.Maintenance.begin('restore', { by = 'WF5A' })
    ok, err = Act('server:acceptType', 1, 'patrol')
    H.eq(err, 'err.maintenance', 'maintenance: an accept is refused while it holds')
    H.ok(Open(1) ~= nil, 'maintenance: the tablet still opens')
    CP.Maintenance.finish('restore')
    Later()
    ok, err = Act('server:acceptType', 1, 'patrol')
    H.eq(ok, true, 'maintenance: over: accepted again: ' .. tostring(err))
    Leave(1)
end

-- ============================================================================
--                                  5. A UNIT
-- ============================================================================

do
    Later()
    for k, src in ipairs({ 1, 2, 6, 7 }) do Place(src, vec3(AT.x + k, AT.y, AT.z)) end
    -- invite, decline, invite again, accept
    local ok, data = Act('server:unitInvite', 1, 6)
    H.eq(ok, true, 'unit: Ada invites Cleo: ' .. tostring(data))
    ok, data = Act('server:unitRespond', 6, { accepted = false, unitId = type(data) == 'table' and data.unitId or nil })
    H.eq(ok, true, 'unit: Cleo declines: ' .. tostring(data))
    H.eq(CP.Units.unitOf(6), nil, 'unit: ...and is in no unit')
    ok, data = Act('server:unitInvite', 1, 5)
    H.eq(ok, false, 'unit: a civilian cannot be invited (' .. tostring(data) .. ')')
    ok, data = Act('server:unitInvite', 5, 1)
    H.eq(ok, false, 'unit: a civilian cannot invite (' .. tostring(data) .. ')')
    W.FormUnit(1, 6)
    W.FormUnit(1, 2)
    -- cancel an invite
    ok, data = Act('server:unitInvite', 1, 7)
    H.eq(ok, true, 'unit: Dan invited: ' .. tostring(data))
    ok, data = Act('server:unitCancelInvite', 1, 7)
    H.eq(ok, true, 'unit: ...the invite taken back: ' .. tostring(data))
    ok, data = Act('server:unitRespond', 7, { accepted = true })
    H.eq(ok, false, 'unit: Dan can no longer accept it (' .. tostring(data) .. ')')
    local u = CP.Units.unitOf(6)
    H.eq(u and #u.members, 3, 'unit: three in the unit')
    H.ok(type(Cb('getUnit', 6)) == 'table', 'unit: the Unit screen opens for a member')

    -- a member cannot accept, kick or promote
    ok, data = Act('server:acceptType', 6, 'patrol')
    H.eq(data, 'err.not_leader', 'unit: a member cannot accept a mission')
    ok, data = Act('server:unitKick', 6, 2)
    H.eq(ok, false, 'unit: a member cannot remove one (' .. tostring(data) .. ')')
    ok, data = Act('server:unitPromote', 6, 2)
    H.eq(ok, false, 'unit: a member cannot hand the lead over (' .. tostring(data) .. ')')

    -- the ready check: one No and nothing starts; all Ready and it starts
    W.SetAutoReady(false)
    local mark = #H.events
    Act('server:acceptType', 1, 'patrol')
    Secs(1)
    H.ok(#W.ClientEvents('crimson-police:client:readyCheck', 6, mark) > 0, 'ready: Cleo is asked')
    Act('server:unitReady', 6, { accepted = false })
    Secs(3)
    H.eq(CP.Runs.getBySrc(1), nil, 'ready: one No: no run')
    H.eq(CP.Runs.onCooldown(CID[1], 'patrol'), false, 'ready: ...and no cooldown')
    W.SetAutoReady(true)
    Later()
    local run = AcceptOnly(1, 'tactical', 'gang_shootout')
    H.eq(run and #CP.Runs.activeSrcs(run), 3, 'ready: all Ready: the three are on the run')
    ok, data = Act('server:unitKick', 1, 2)
    H.eq(ok, false, 'unit: no kick while the unit is on a run (' .. tostring(data) .. ')')
    for _, src in ipairs({ 1, 2, 6 }) do
        local r = CP.Runs.getBySrc(src)
        if r then Act('server:abandon', src, r.id) end
    end

    -- promote, kick by the new leader
    ok, data = Act('server:unitPromote', 1, 6)
    H.eq(ok, true, 'unit: the lead handed to Cleo: ' .. tostring(data))
    ok, data = Act('server:unitKick', 1, 2)
    H.eq(ok, false, 'unit: the old leader cannot remove one (' .. tostring(data) .. ')')
    ok, data = Act('server:unitKick', 6, 2)
    H.eq(ok, true, 'unit: the new leader removes Ben: ' .. tostring(data))
    H.eq(CP.Units.unitOf(2), nil, 'unit: ...he is in no unit')
    ok, data = Act('server:unitInvite', 6, 2)
    H.eq(ok, false, 'unit: a removed officer cannot be invited again at once (' .. tostring(data) .. ')')

    -- a member drops while the ready check asks him: nothing starts, the unit is free again
    for _, src in ipairs({ 1, 6 }) do if CP.Units.unitOf(src) then Act('server:teamLeave', src) end end
    W.SetAutoReady(false)
    Later()
    W.FormUnit(6, 1)
    mark = #H.events
    Act('server:acceptType', 6, 'patrol')
    Secs(1)
    H.ok(#W.ClientEvents('crimson-police:client:readyCheck', 1, mark) > 0, 'ready: Ada is asked')
    W.Drop(1)
    Secs(3)
    H.eq(CP.Runs.getBySrc(6), nil, 'ready: the asked member dropped: no run')
    H.eq(CP.Runs.onCooldown(CID[6], 'patrol'), false, 'ready: ...and no cooldown for the leader')
    u = CP.Units.unitOf(6)
    H.ok(u == nil or not u.locked, 'ready: the unit is not left locked')
    W.Reconnect(1)
    W.SetAutoReady(true)
    if CP.Units.unitOf(6) then Act('server:teamLeave', 6) end
    if CP.Units.unitOf(1) then Act('server:teamLeave', 1) end

    -- the leader drops while his unit is asked: nothing starts for the member
    W.SetAutoReady(false)
    W.FormUnit(1, 6)
    mark = #H.events
    Act('server:acceptType', 1, 'patrol')
    Secs(1)
    W.Drop(1)
    Secs(3)
    H.eq(CP.Runs.getBySrc(6), nil, 'ready: the leader dropped during the ready check: no run for Cleo')
    u = CP.Units.unitOf(6)
    H.ok(u == nil or not u.locked, 'ready: ...and her unit is not left locked')
    if u then
        local okA, errA = Act('server:acceptType', 6, 'patrol')
        H.eq(okA, true, 'ready: she can accept again: ' .. tostring(errA))
        Leave(6)
    end
    W.Reconnect(1)
    W.SetAutoReady(true)
    if CP.Units.unitOf(6) then Act('server:teamLeave', 6) end

    -- the unit is full at Config.Limits.maxUnitSize; an invite runs out after its time
    for k, src in ipairs({ 1, 2, 6, 7, 3 }) do Place(src, vec3(AT.x + k, AT.y, AT.z)) end
    W.FormUnit(1, 2)
    W.FormUnit(1, 6)
    W.FormUnit(1, 7)
    ok, data = Act('server:unitInvite', 1, 3)
    H.eq(ok, false, 'unit: four is full: a fifth cannot be invited (' .. tostring(data) .. ')')
    Act('server:teamLeave', 7)
    ok, data = Act('server:unitInvite', 1, 7)
    H.eq(ok, true, 'unit: room again: Dan invited: ' .. tostring(data))
    Secs((Config.Units.inviteTtl or 120) + 5)
    ok, data = Act('server:unitRespond', 7, { accepted = true })
    H.eq(ok, false, 'unit: an invite past its time cannot be accepted (' .. tostring(data) .. ')')
    for _, src in ipairs({ 2, 6, 1 }) do if CP.Units.unitOf(src) then Act('server:teamLeave', src) end end

    -- the restart: units live in memory
    W.Restart()
    H.eq(CP.Units.unitOf(1), nil, 'restart: the unit is gone')
    W.FormUnit(1, 6)
    W.FormUnit(1, 7)
    -- the leader drops: the lead passes on; back, he is in no unit
    W.Drop(1)
    u = CP.Units.unitOf(6)
    H.ok(u ~= nil and u.leader ~= 1, 'drop: the lead passes on')
    W.Reconnect(1)
    H.eq(CP.Units.unitOf(1), nil, 'reconnect: Ada is in no unit')
    local leader = u and u.leader or 6
    ok, data = Act('server:unitDisband', leader)
    H.eq(ok, true, 'unit: the leader disbands it: ' .. tostring(data))
    H.eq(CP.Units.unitOf(6), nil, 'unit: Cleo is in no unit')
    H.eq(CP.Units.unitOf(7), nil, 'unit: Dan is in no unit')
    W.FormUnit(1, 6)
    Act('server:teamLeave', 6)
    H.eq(CP.Units.unitOf(6), nil, 'unit: Leave: in no unit')
    H.eq(CP.Units.unitOf(1), nil, 'unit: a unit of one dissolves')
    ok, data = Act('server:unitKick', 1, 6)
    H.eq(ok, false, 'unit: not in a unit: no kick (' .. tostring(data) .. ')')
end

-- ============================================================================
--                                 6. DISPATCH
-- ============================================================================

do
    Later()
    Place(1, vec3(400.0, -980.0, 30.0))
    Place(6, vec3(402.0, -980.0, 30.0))
    -- an officer without the grant cannot post a call; the supervisor posts one
    local ok, data = Act('server:sup:mcPost', 1, { type = 'patrol', area = 'south_ls' })
    H.eq(ok, false, 'dispatch: an officer cannot post a call (' .. tostring(data) .. ')')
    ok, data = Act('server:sup:mcPost', 3, { type = 'patrol', area = 'south_ls' })
    H.eq(ok, true, 'dispatch: the supervisor posts a call: ' .. tostring(data))
    local callId = type(data) == 'table' and data.id or nil
    local listed
    for _, c in ipairs((Cb('getMissionCalls', 1) or {}).calls or {}) do if c.id == callId then listed = c end end
    H.ok(listed ~= nil, 'dispatch: Dispatch lists it')

    W.FormUnit(1, 6)
    ok, data = Act('server:answerMissionCall', 6, { callId = callId })
    H.eq(ok, false, 'dispatch: a member cannot claim (' .. tostring(data) .. ')')
    ok, data = Act('server:answerMissionCall', 1, { callId = 999999 })
    H.eq(ok, false, 'dispatch: an unknown call (' .. tostring(data) .. ')')
    ok, data = Act('server:answerMissionCall', 1, { callId = callId })
    H.eq(ok, true, 'dispatch: the leader claims it: ' .. tostring(data))
    Secs(6)
    local run = CP.Runs.getBySrc(1)
    H.ok(run ~= nil, 'dispatch: the claim starts the run')
    H.ok(run ~= nil and CP.Runs.getBySrc(6) == run, 'dispatch: the partner is on it')
    Place(7, vec3(404.0, -980.0, 30.0))
    ok, data = Act('server:answerMissionCall', 7, { callId = callId })
    H.eq(ok, false, 'dispatch: a claimed call cannot be claimed again (' .. tostring(data) .. ')')
    for _, src in ipairs({ 1, 6 }) do
        local r = CP.Runs.getBySrc(src)
        if r then Act('server:abandon', src, r.id) end
    end

    -- a mission pushed to the unit: declined, the reply carries the fresh Dispatch view
    Later()
    for _, src in ipairs({ 1, 6 }) do
        Act('server:admin:clearCooldowns', 5,
            { citizenid = CID[src], scope = 'all', reason = 'WF5A', requestId = W.RequestId() })
    end
    if not CP.Units.unitOf(6) then W.FormUnit(1, 6) end
    ok, data = Act('server:sup:mcPost', 3, { type = 'patrol', leaderSrc = 1, missionId = 'traffic_enforcement' })
    H.eq(ok, true, 'push: the supervisor pushes Traffic Enforcement to the unit: ' .. tostring(data))
    local pushed = type(data) == 'table' and data.id or nil
    ok, data = Act('server:answerMissionCall', 6, { callId = pushed, answer = 'decline' })
    H.eq(ok, false, 'push: a member cannot decline it (' .. tostring(data) .. ')')
    ok, data = Act('server:answerMissionCall', 1, { callId = pushed, answer = 'decline' })
    H.eq(ok, true, 'push: the leader declines it: ' .. tostring(data))
    local view = type(data) == 'table' and data.view or nil
    H.ok(type(view) == 'table', 'push: the reply carries Dispatch')
    local still
    for _, c in ipairs(view and view.calls or {}) do if c.id == pushed then still = c end end
    H.eq(still, nil, 'push: ...without the declined push')
    H.eq(CP.Runs.getBySrc(1), nil, 'push: no run')

    -- another push accepted; a restart ends its run and it is not offered again
    ok, data = Act('server:sup:mcPost', 3, { type = 'patrol', leaderSrc = 1, missionId = 'street_race_bust' })
    H.eq(ok, true, 'push: another push: ' .. tostring(data))
    pushed = type(data) == 'table' and data.id or nil
    ok, data = Act('server:answerMissionCall', 1, { callId = pushed })
    H.eq(ok, true, 'push: the unit accepts it: ' .. tostring(data))
    Secs(3)
    run = CP.Runs.getBySrc(1)
    H.eq(run and run.missionId, 'street_race_bust', 'push: the pushed mission, no draw')
    W.Restart()
    H.eq(CP.Runs.getBySrc(1), nil, 'restart: the pushed run is gone')
    local again
    for _, c in ipairs((CP.MissionCalls.list(1) or {}).calls or {}) do if c.id == pushed then again = c end end
    H.eq(again, nil, 'restart: the push is not offered again')
end

-- ============================================================================
--                           7. CROSS-DEPARTMENT JOIN
-- ============================================================================

do
    Later()
    local ok, data = Act('server:joinOperation', 1, 1)
    H.eq(ok, false, 'op: nothing to join (' .. tostring(data) .. ')')
    ok, data = Act('server:admin:opLaunch', 5, { missionId = 'gang_shootout', skipCooldown = true, reason = 'WF5A' })
    H.eq(ok, true, 'op: an operation is launched: ' .. tostring(data))
    local opId = type(data) == 'table' and data.id or nil
    ok, data = Act('server:joinOperation', 5, opId)
    H.eq(ok, false, 'op: a civilian cannot join (' .. tostring(data) .. ')')
    -- a banned officer cannot join
    ok, data = Act('server:sup:missionBan', 3,
        { citizenid = CID[6], hours = 1, reason = 'WF5A', requestId = W.RequestId() })
    H.eq(ok, true, 'op: Cleo is barred from missions: ' .. tostring(data))
    ok, data = Act('server:joinOperation', 6, opId)
    H.eq(data, 'err.mission_banned', 'op: a barred officer cannot join')
    ok, data = Act('server:restriction', 3, { op = 'lift', kind = 'missionBan', citizenid = CID[6], reason = 'WF5A' })
    H.eq(ok, true, 'op: the ban lifted: ' .. tostring(data))
    ok, data = Act('server:joinOperation', 1, opId)
    H.eq(ok, true, 'op: Ada joins: ' .. tostring(data))
    ok, data = Act('server:joinOperation', 1, opId)
    H.eq(data, 'err.op_already_joined', 'op: joining twice is refused')
    H.eq((CP.Operations.boardCard(1) or {}).joinedByMe, true, 'op: the board card says she joined')
    ok, data = Act('server:acceptType', 6, 'patrol')
    H.eq(data, 'err.operation_locked', 'op: while it is joining, other accepts wait')
    ok, data = Act('server:teamLeave', 1, { team = 'operation' })
    H.eq(ok, true, 'op: Ada leaves it: ' .. tostring(data))
    H.eq((CP.Operations.boardCard(1) or {}).joinedByMe, false, 'op: ...off the join list')
    ok, data = Act('server:joinOperation', 1, opId)
    H.eq(ok, true, 'op: Ada joins again: ' .. tostring(data))
    W.Drop(1)
    H.eq((CP.Operations.boardCard(6) or {}).joined, 0, 'drop: off the join list')
    W.Reconnect(1)
    W.Restart()
    H.eq(CP.Operations.active(), nil, 'restart: the operation is cancelled')
end

-- ============================================================================
--               8. THE ME SCREEN AND MY OPTIONS (RESTART, DROP)
-- ============================================================================

do
    local prof = Cb('getProfile', 1, {})
    H.ok(prof and (prof.xp or 0) > 0, 'me: the profile shows his XP')
    H.eq(prof and prof.own, true, 'me: ...as his own')
    local other = Cb('getProfile', 6, { citizenid = CID[1] })
    H.ok(other ~= nil and other.own ~= true, 'me: another officer opens his profile')
    H.ok(type(Cb('getProfileEdit', 1)) == 'table', 'me: Edit profile opens')
    local none, noneErr = Cb('getProfile', 1, { citizenid = 'NOBODY99' })
    H.eq(none, nil, 'me: an unknown officer has no profile (' .. tostring(noneErr) .. ')')
    local okR, errR = Act('server:profile:report', 6, { citizenid = CID[1], reason = 'bio', note = 'WF5A' })
    H.eq(okR, true, 'me: Cleo reports a profile to the supervisors: ' .. tostring(errR))
    okR, errR = Act('server:profile:report', 6, { citizenid = CID[1], reason = 'bio' })
    H.eq(errR, 'err.report_duplicate', 'me: the same profile twice in a day is refused')
    okR, errR = Act('server:profile:report', 6, { citizenid = CID[6], reason = 'bio' })
    H.eq(errR, 'err.report_self', 'me: never her own')
    local ok, data = Act('server:profile:set', 1, { bio = 'Steady hands.' })
    H.eq(ok, true, 'me: the bio is saved: ' .. tostring(data))
    ok, data = Act('server:profile:set', 1, { bio = 'Again at once.' })
    H.eq(data, 'err.profile_cooldown', 'me: a second edit at once is refused')
    ok, data = Act('server:profile:set', 5, { bio = 'x' })
    H.eq(ok, false, 'me: a civilian has no profile to edit (' .. tostring(data) .. ')')

    local board = Cb('getBoard', 1, { metric = 'points', period = 'weekly' })
    H.ok(board ~= nil and board.me ~= nil and (board.me.runs or 0) > 0, 'me: the leaderboard counts his runs')
    ok, data = Act('server:setHideName', 1, { hideName = true })
    H.eq(ok, true, 'me: Hide my name: ' .. tostring(data))
    local seen
    for _, r in ipairs((Cb('getBoard', 6, { metric = 'points', period = 'weekly' }) or {}).rows or {}) do
        if r.citizenid == CID[1] or r.callsign == PD[1].metadata.callsign then seen = r end
    end
    H.ok(seen ~= nil, 'me: Cleo sees Ada on the leaderboard')
    H.ok(seen ~= nil and seen.name ~= 'Ada Trooper',
        'me: ...by her callsign, not her name (' .. tostring(seen and seen.name) .. ')')
    ok, data = Act('server:setHideName', 1, { hideName = 'yes' })
    H.eq(data, 'err.invalid_payload', 'me: a wrong value is refused')
    local ch = Cb('getChallenge', 1, {})
    H.eq(ch and ch.myDepartment, 'sast', 'me: the challenge shows his department')

    ok, data = Act('server:options:set', 1, { skipAcceptConfirm = true, favouriteTypes = { 'patrol' } })
    H.eq(ok, true, 'options: two options saved: ' .. tostring(data))
    ok, data = Act('server:options:set', 1, { hudSide = 'left' })
    H.eq(data, 'err.invalid_payload', 'options: a local option is never saved on the server')
    ok, data = Act('server:options:set', 1, { openOn = 'nowhere' })
    H.eq(data, 'err.option_value', 'options: a wrong value is refused')
    ok, data = Act('server:options:set', 1, {})
    H.eq(data, 'err.invalid_payload', 'options: an empty change is refused')

    -- Dispatch -> call pop-ups for his favourite types only: a Patrol call pops up, an Investigation call stays on the
    -- list
    Later()
    Place(1, vec3(400.0, -980.0, 30.0))
    ok, data = Act('server:options:set', 1, { callAlerts = 'favourites' })
    H.eq(ok, true, 'options: call pop-ups for favourites only: ' .. tostring(data))
    local function PopsUp(typeKey)
        Later()                                    -- the supervisor's wait between two posts
        local mark = #H.events
        local okP, dataP = Act('server:sup:mcPost', 3, { type = typeKey, area = 'south_ls' })
        H.eq(okP, true, ('options: the supervisor posts a %s call: %s'):format(typeKey, tostring(dataP)))
        Secs(2)
        return #W.ClientEvents('crimson-police:client:missionCall', 1, mark) > 0
    end
    H.eq(PopsUp('patrol'), true, 'options: a call of his favourite type pops up')
    H.eq(PopsUp('investigation'), false, 'options: another type shows on Dispatch with no pop-up')
    ok, data = Act('server:profile:set', 1, { callsMuted = true })
    H.eq(ok, true, 'options: every call pop-up muted: ' .. tostring(data))
    H.eq(PopsUp('patrol'), false, 'options: muted: not even his favourite type pops up')
    Act('server:profile:set', 1, { callsMuted = false })
    Act('server:options:set', 1, { callAlerts = 'all' })

    W.Restart()
    local s = Open(1)
    H.eq(s and s.options and s.options.skipAcceptConfirm, true, 'restart: his options kept')
    prof = Cb('getProfile', 1, {})
    H.eq(prof and prof.hideName, true, 'restart: Hide my name kept')
    W.Drop(1)
    W.Reconnect(1)
    H.ok(type(Cb('getOptions', 1)) == 'table', 'reconnect: My options opens')
    s = Open(1)
    H.eq(s and s.options and s.options.skipAcceptConfirm, true, 'reconnect: ...still as he set them')
    Act('server:setHideName', 1, { hideName = false })
end

-- ============================================================================
--                       9. FIELD TRAINING AS THE ROOKIE
-- ============================================================================

do
    Later()
    Place(7, AT)
    Place(3, vec3(AT.x + 2.0, AT.y, AT.z))
    H.ok(Open(7) ~= nil and Open(3) ~= nil, 'fto: the rookie and the trainer open their tablets')
    local ok, data = Act('server:sup:ftoPair', 3, { rookie = CID[7], trainer = CID[3] })
    H.eq(ok, true, 'fto: the supervisor pairs Dan with himself: ' .. tostring(data))
    H.ok(type(Cb('fto:getMine', 7)) == 'table', 'fto: the rookie sees his training')
    ok, data = Act('server:acceptType', 7, 'tactical')
    H.eq(ok, false, 'fto: a rookie alone cannot take Tactical (' .. tostring(data) .. ')')
    ok, data = Act('server:fto:signOff', 7, { rookie = CID[7], task = 'patrol' })
    H.eq(ok, false, 'fto: a rookie cannot sign himself off (' .. tostring(data) .. ')')
    W.FormUnit(7, 3)
    ok, data = Act('server:acceptType', 7, 'tactical')
    H.eq(ok, true, 'fto: with his trainer in the unit he can: ' .. tostring(data))
    local run = CP.Runs.getBySrc(7)
    W.Drop(7)
    H.eq(CP.Runs.getBySrc(7), nil, 'drop: the rookie is off the run')
    W.Reconnect(7)
    H.ok(type(Cb('fto:getMine', 7)) == 'table', 'reconnect: still in training')
    if run and CP.Runs.getBySrc(3) then Act('server:abandon', 3, run.id) end
    Leave(3)
    Leave(7)
end

-- ============================================================================
--  10. DOWNED, ABANDON, OFF DUTY, LOGOUT MID-RUN; A DROP IN THE OTHER BLOCKS
-- ============================================================================

local function StartSolo(src, typeKey, missionId, upTo)
    Later()
    Place(src, AT)
    local run = AcceptOnly(src, typeKey, missionId)
    if not run then return nil end
    W.Arrive(run, src)
    Secs(3)
    for i = 1, (upTo or 1) - 1 do FinishObjective(run, i) end
    return run
end

do
    -- abandon: the row is Abandoned, no cash, the type on the abandon cooldown
    local run = StartSolo(1, 'patrol', 'business_check')
    H.eq(run and run.state, 'in_progress', 'abandon: in progress')
    local paid0 = #W.addMoney
    local ok, data = Act('server:abandon', 1, run and run.id)
    H.eq(ok, true, 'abandon: pressed: ' .. tostring(data))
    local r = RunRow(run and run.id, CID[1])
    H.eq(r.state, 'abandoned', 'abandon: the row is Abandoned')
    H.eq(#W.addMoney, paid0, 'abandon: no cash')
    H.ok(CP.Runs.onCooldown(CID[1], 'patrol') ~= false, 'abandon: the type on its cooldown')
    ok, data = Act('server:abandon', 1, run and run.id)
    H.eq(ok, false, 'abandon: twice is refused (' .. tostring(data) .. ')')
    ok, data = Act('server:abandon', 6, 'nope')
    H.eq(ok, false, 'abandon: a run he is not on (' .. tostring(data) .. ')')

    -- off duty in progress: Abandoned, off_duty
    run = StartSolo(1, 'training', 'evoc_course')
    PD[1].job.onduty = false
    TriggerEvent('QBCore:Server:SetDuty', 1, false)
    Secs(3)
    H.eq(CP.Runs.getBySrc(1), nil, 'off duty: off the run')
    r = RunRow(run and run.id, CID[1])
    H.eq(r.state, 'abandoned', 'off duty: Abandoned')
    H.eq(r.end_reason, 'off_duty', 'off duty: ...off_duty')
    H.eq(tonumber(r.cash_paid) or 0, 0, 'off duty: no cash')
    PD[1].job.onduty = true
    TriggerEvent('QBCore:Server:SetDuty', 1, true)
    Secs(2)

    -- logout (character unload) in progress: Failed, no cash; back, on no run
    run = StartSolo(6, 'investigation', 'manhunt')
    local pd = PD[6]
    PD[6] = nil
    TriggerEvent('QBCore:Server:OnPlayerUnload', 6)
    Secs(3)
    H.eq(CP.Runs.getBySrc(6), nil, 'logout: off the run')
    r = RunRow(run and run.id, CID[6])
    H.eq(r.state, 'failed', 'logout: Failed')
    H.eq(tonumber(r.cash_paid) or 0, 0, 'logout: no cash')
    PD[6] = pd
    TriggerEvent('QBCore:Server:PlayerLoaded', W.QbxPlayer(6))
    Secs(2)
    H.eq(CP.Runs.getBySrc(6), nil, 'logout: back, on no run')
    H.ok(Open(6) ~= nil, 'logout: back, the tablet opens')

    -- a drop in each block tests/workflows_full_spec.lua (13) leaves out
    for _, c in ipairs({
        { 'investigation', 'manhunt', 1 },             -- search_area
        { 'tactical', 'prison_break', 1 },             -- flee_arrest
        { 'tactical', 'bomb_disposal', 2 },            -- skill_check
        { 'tactical', 'hostage_rescue', 2 },           -- protect_rescue
        { 'training', 'evoc_course', 1 },              -- checkpoint_route
    }) do
        run = StartSolo(1, c[1], c[2], c[3])
        H.eq(run and run.objectiveIndex, c[3], ('drop: %s on objective %d'):format(c[2], c[3]))
        local money1 = #W.addMoney
        W.Drop(1)
        H.eq(CP.Runs.getBySrc(1), nil, ('drop: %s: off the run'):format(c[2]))
        r = RunRow(run and run.id, CID[1])
        H.eq(r.state, 'failed', ('drop: %s: Failed'):format(c[2]))
        H.eq(#W.addMoney, money1, ('drop: %s: no cash'):format(c[2]))
        W.Reconnect(1)
        H.eq(CP.Runs.getBySrc(1), nil, ('reconnect: %s: on no run'):format(c[2]))
    end

    -- the escort with a unit: the partner drops, the run goes on for the leader
    Later()
    Place(1, AT)
    Place(6, vec3(AT.x + 2.0, AT.y, AT.z))
    W.FormUnit(1, 6)
    run = AcceptOnly(1, 'tactical', 'armored_truck_escort')
    if run then
        W.Arrive(run, 1)
        W.Arrive(run, 6)
        Secs(3)
        W.Drop(6)
        H.eq(CP.Runs.getBySrc(6), nil, 'drop: escort: the partner is off the run')
        H.eq(run.state, 'in_progress', 'drop: escort: it goes on for the leader')
        W.Reconnect(6)
        H.eq(CP.Runs.getBySrc(6), nil, 'reconnect: escort: the partner is on no run')
        Leave(1)
    end

    -- a unit on a run: a member abandons (his row Abandoned, the run goes on), then the leader abandons (the run
    -- goes on for the one left, who is the leader now); another accept while on a run is refused
    Later()
    for k, src in ipairs({ 1, 6, 2 }) do Place(src, vec3(AT.x + k, AT.y, AT.z)) end
    W.FormUnit(1, 6)
    W.FormUnit(1, 2)
    run = AcceptOnly(1, 'tactical', 'gang_shootout')
    if run then
        for _, src in ipairs({ 1, 6, 2 }) do W.Arrive(run, src) end
        Secs(3)
        local okA, errA = Act('server:acceptType', 1, 'patrol')
        H.eq(okA, false, 'unit run: a second accept while on a run is refused (' .. tostring(errA) .. ')')
        okA, errA = Act('server:abandon', 2, run.id)
        H.eq(okA, true, 'unit run: Ben abandons: ' .. tostring(errA))
        H.eq(RunRow(run.id, CID[2]).state, 'abandoned', 'unit run: ...his row Abandoned')
        H.eq(run.state, 'in_progress', 'unit run: the run goes on')
        okA, errA = Act('server:abandon', 1, run.id)
        H.eq(okA, true, 'unit run: the leader abandons: ' .. tostring(errA))
        H.eq(run.state, 'in_progress', 'unit run: the run goes on for Cleo')
        H.eq(CP.Runs.getBySrc(6), run, 'unit run: Cleo is still on it')
        -- the last one goes off duty: the run ends, his row Abandoned (off duty)
        PD[6].job.onduty = false
        TriggerEvent('QBCore:Server:SetDuty', 6, false)
        Secs(3)
        H.eq(run.state, 'ended', 'unit run: the last one off duty: the run ends')
        H.eq(RunRow(run.id, CID[6]).end_reason, 'off_duty', 'unit run: ...his row says off duty')
        H.eq(CP.Units.unitOf(6), nil, 'unit run: off duty: out of the unit')
        PD[6].job.onduty = true
        TriggerEvent('QBCore:Server:SetDuty', 6, true)
        Secs(2)
    end
    for _, src in ipairs({ 1, 6, 2 }) do Leave(src) end

    -- a job change mid-run: off the run, his row Abandoned
    run = StartSolo(7, 'investigation', 'suspicious_activity')
    if run then
        PD[7].job.name = 'unemployed'
        TriggerEvent('QBCore:Server:OnJobUpdate', 7, PD[7].job)
        Secs(12)
        H.eq(CP.Runs.getBySrc(7), nil, 'job change: off the run')
        local jr = RunRow(run.id, CID[7])
        H.eq(jr.state, 'abandoned', 'job change: Abandoned (' .. tostring(jr.end_reason) .. ')')
        H.eq(tonumber(jr.cash_paid) or 0, 0, 'job change: no cash')
        PD[7].job.name = 'sast'
        TriggerEvent('QBCore:Server:OnJobUpdate', 7, PD[7].job)
        Secs(2)
        H.ok(Open(7) ~= nil, 'job change: back in the job, the tablet opens')
    end

    -- downed mid-run with the switches on: one Downed row, nothing more
    run = StartSolo(7, 'patrol', 'street_race_bust')
    if run then
        PD[7].metadata.isdead = true
        Secs(3)
        H.eq(CP.Runs.getBySrc(7), nil, 'downed: off the run')
        local rows = W.Rows('run_uuid = ? AND citizenid = ?', { run.id, CID[7] })
        H.eq(#rows, 1, 'downed: one row')
        H.eq((rows[1] or {}).state, 'failed', 'downed: ...Failed')
        PD[7].metadata.isdead = false
        Secs(20)
        H.eq(#W.Rows('run_uuid = ? AND citizenid = ?', { run.id, CID[7] }), 1, 'downed: still one row')
    end
end

_G.print = W.realPrint

return H
