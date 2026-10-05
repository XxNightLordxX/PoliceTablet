-- The world of tests/admin_live_spec.lua and tests/admin_runctl_spec.lua: the real permissions, access, admin, adminkit,
-- tablet, schedule, scaling, events, units, runs and livectl modules, stand-ins for the rest (Qbox, the Mission Board,
-- scoring, cash, operations, the downed follow-up) and a one-objective mission whose block spawns one object.

return function(H)
    local W = { log = {} }
    local function Rec(k, v)
        W.log[k] = W.log[k] or {}
        W.log[k][#W.log[k] + 1] = v
    end
    W.rec = Rec
    function W.count(k) return W.log[k] and #W.log[k] or 0 end

    -- ---- CONSOLE -----------------------------------------------------------
    local realPrint = print
    W.realPrint = realPrint
    _G.print = function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        local line = table.concat(parts, ' ')
        if not line:find('crimson%-police') then realPrint(line) end
    end

    -- ---- ENTITIES (OneSync) ------------------------------------------------
    local ents, nextHandle, nextNet = {}, 5000, 7000
    local netToEnt = {}
    W.ents = ents
    local function NewEnt(kind, model, x, y, z)
        nextHandle, nextNet = nextHandle + 1, nextNet + 1
        ents[nextHandle] = {
            kind = kind,
            model = model,
            coords = vec3(x, y, z),
            exists = true,
            health = 200,
            net = nextNet,
            type = kind == 'ped' and 1 or (kind == 'vehicle' and 2 or 3),
        }
        netToEnt[nextNet] = nextHandle
        return nextHandle
    end
    _G.CreatePed = function(_, model, x, y, z) return NewEnt('ped', model, x, y, z) end
    _G.CreateVehicleServerSetter = function(model, _, x, y, z) return NewEnt('vehicle', model, x, y, z) end
    _G.CreateObjectNoOffset = function(model, x, y, z) return NewEnt('object', model, x, y, z) end
    _G.DoesEntityExist = function(e)
        if ents[e] then return ents[e].exists end
        return (tonumber(e) or 0) > 0
    end
    _G.DeleteEntity = function(e) if ents[e] then ents[e].exists = false end end
    _G.NetworkGetNetworkIdFromEntity = function(e) return ents[e] and ents[e].net or 0 end
    _G.NetworkGetEntityFromNetworkId = function(n) return netToEnt[n] or 0 end
    _G.NetworkGetEntityOwner = function() return 0 end
    _G.GetEntityHealth = function(e) return ents[e] and ents[e].health or 200 end
    _G.GetEntityModel = function(e) return ents[e] and ents[e].model or 0 end
    _G.GetEntityType = function(e) return ents[e] and ents[e].type or 0 end
    _G.GetVehicleEngineHealth = function() return 1000.0 end
    _G.GetVehicleBodyHealth = function() return 1000.0 end
    _G.IsPedAPlayer = function(e) return ents[e] == nil end
    _G.SetEntityHeading = function() end
    _G.FreezeEntityPosition = function() end
    _G.SetVehicleNumberPlateText = function() end
    _G.GetPlayerRoutingBucket = function() return 0 end
    local baseCoords = _G.GetEntityCoords
    _G.GetEntityCoords = function(e)
        if ents[e] then return ents[e].coords end
        return baseCoords(e)
    end
    local bags = {}
    _G.Entity = function(e)
        local b = bags[e]
        if not b then b = {}; bags[e] = b end
        return {
            state = setmetatable({
                set = function(_, k, v) b[k] = v end,
            }, { __index = b }),
        }
    end

    -- ---- PLAYERS (QBOX) ----------------------------------------------------
    W.LIC1 = 'license:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1'
    W.people = {
        [1] = { cid = 'ADM00001', license = W.LIC1, job = 'sast', grade = 4, ace = true, name = 'Ada Admin' },
        [2] = { cid = 'SUP00002', license = 'license:b2', job = 'sast', grade = 4, name = 'Sam Super' },
        [3] = { cid = 'ADM00003', license = 'license:c3', job = 'fib', grade = 1, ace = true, name = 'Cal Admin' },
        [7] = { cid = 'OFF00007', license = 'license:d7', job = 'sast', grade = 0, name = 'Olive Seven' },
        [8] = { cid = 'OFF00008', license = 'license:e8', job = 'fib', grade = 0, name = 'Otto Eight' },
        [9] = { cid = 'OFF00009', license = 'license:f9', job = 'sast', grade = 0, name = 'Nina Nine' },
    }
    W.qboxLicense = { ALT00001 = W.LIC1 }   -- a second character of admin 1 that never opened the tablet
    W.downed = {}
    for src, p in pairs(W.people) do
        H.players[src] = { ace = p.ace and { ['crimsonpolice.admin'] = true } or {}, coords = vec3(100.0, 100.0, 30.0) }
    end
    local function Info(src)
        local p = W.people[src]
        if not p then return nil end
        return {
            src = src,
            citizenid = p.cid,
            license = p.license,
            name = p.name,
            callsign = 'C-' .. src,
            job = { name = p.job, onduty = true, gradeLevel = p.grade, gradeName = 'Rank' },
        }
    end
    CP.Qbx = {
        getInfo = Info,
        getByCitizenId = function(cid)
            for src, p in pairs(W.people) do
                if p.cid == cid and not p.offline then return src end
            end
            return nil
        end,
        getOnlinePlayers = function()
            local out = {}
            for src, p in pairs(W.people) do if not p.offline then out[#out + 1] = src end end
            table.sort(out)
            return out
        end,
        licenseOf = function(cid)
            for _, p in pairs(W.people) do if p.cid == cid then return p.license end end
            return W.qboxLicense[cid]
        end,
        citizenidsOfLicense = function(lic)
            local out = {}
            for cid, l in pairs(W.qboxLicense) do if l == lic then out[#out + 1] = cid end end
            return out
        end,
        characterExists = function(cid) return W.qboxLicense[cid] ~= nil end,
        isDowned = function(src) return W.downed[src] == true end,
        onDutyChange = function() end,
        onGroupUpdate = function() end,
        onJobChange = function() end,
        onPlayerLoaded = function() end,
        onPlayerUnload = function() end,
        onMetaDataChange = function() end,
    }

    -- ---- THE MISSION -------------------------------------------------------
    W.DEF = {
        id = 'live_test_mission',
        label = 'Live Test Mission',
        type = 'patrol',
        difficulty = 1,
        timeLimit = 600,
        cooldown = 1800,
        minOfficers = 1,
        maxOfficers = 4,
        locations = { { label = 'Here', start = { coords = vec3(100.0, 100.0, 30.0), radius = 30.0 } } },
        objectives = { { block = 'live_stub', label = 'Hold the area' } },
    }
    W.BOSS = {
        id = 'weekly_boss_kingpin',
        label = 'The Kingpin',
        type = 'tactical',
        isBoss = true,
        timeLimit = 900,
        cooldown = 0,
        minOfficers = 1,
        maxOfficers = 4,
        locations = W.DEF.locations,
        objectives = W.DEF.objectives,
    }
    CP.Blocks.register('live_stub', {
        id = 'live_stub',
        prepare = function(ctx)
            ctx.state.prop = ctx.spawnObject({ model = 'prop_box', coords = vec3(101.0, 101.0, 30.0) })
        end,
        start = function() end,
        stop = function(ctx) Rec('block.stop', ctx.run.id) end,
    })
    CP.Missions = {
        get = function(id)
            if id == W.DEF.id then return W.DEF end
            if id == W.BOSS.id then return W.BOSS end
            return nil
        end,
        all = function() return { W.DEF, W.BOSS } end,
        isEnabled = function() return true end,
        reload = function() end,
    }

    -- ---- STAND-INS FOR THE MODULES OUTSIDE THE GROUP -----------------------
    W.board = nil
    CP.Draw = {
        reserve = function(runId) Rec('draw.reserve', runId) return true end,
        release = function(runId) Rec('draw.release', runId) return true end,
        boardCards = function(src)
            Rec('draw.board', src)
            return W.board
        end,
    }
    CP.Route = {
        begin = function() end,
        stop = function(_, src) Rec('route.stop', src) end,
        status = function() return { status = 'arrived', recalcsLeft = 2, distance = 0 } end,
    }
    CP.Alerts = {
        set = function() end,
        clear = function(src) Rec('alerts.clear', src) end,
        forget = function() end,
        hold = function() end,
        has = function() return false end,
        inArena = function() return false end,
        foreignClearedAt = {},
    }
    CP.Payouts = {
        baseFor = function() return 800 end,
    }
    CP.Scoring = {
        P = function() return 200 end,
        isFirstRunSinceDuty = function() return false end,
        compute = function(run, p, result)
            Rec('scoring.limit', run.timeLimit)
            return {
                P = run.pointsBase,
                bonuses = {},
                penalties = {},
                subtotal = 0,
                mTeam = 1,
                mCross = 1,
                mStreak = 1,
                capped = false,
                tod = false,
                final = result == 'completed' and 200 or 0,
            }
        end,
        onRowCounted = function() end,
        streak = function() return { days = 0, graceLeft = 0 } end,
    }
    W.cashToday = {}
    CP.Cash = {
        compute = function() return 800, { B = 800, mTier = 1, mMod = 1, amount = 800 } end,
        pay = function(rowId) Rec('cash.pay', rowId) end,
        paidToday = function(cid) return W.cashToday[cid] or 0 end,
    }
    CP.Goals = { onRunCompleted = function() end }
    CP.Leaderboard = { invalidate = function() end }
    CP.Challenge = {
        currentSeason = function() return nil end,
    }
    CP.AntiCheat = {
        checkEvent = function() return true end,
        flag = function() end,
        presenceOk = function() return true end,
        onNpcKilled = function() end,
    }
    CP.Calls = {
        isOnCall = function() return false end,
    }
    W.op = nil
    CP.Operations = {
        isLocked = function() return false end,
        active = function() return W.op end,
        onRunEnded = function(run, state) Rec('ops.ended', { run.id, state }) end,
        cancel = function(src, reason)
            Rec('ops.cancel', { src, reason })
            local cur = W.op
            W.op = nil
            local run = CP.Runs.get(cur.runId)
            for _, s in ipairs(CP.Runs.activeSrcs(run)) do CP.Runs.removeParticipant(run, s, 'cancelled') end
            return true, { id = cur.id }
        end,
    }
    CP.Testing = {
        onRunEnded = function(run, state) Rec('testing.ended', { run.id, state }) end,
    }
    CP.Downed = {
        handle = function(run, src)
            Rec('downed.handle', src)
            CP.Runs.removeParticipant(run, src, 'downed', { keepFlag = true })
            return true
        end,
        isPending = function() return false end,
    }

    -- ---- THE REAL MODULES --------------------------------------------------
    for _, t in ipairs({ 'cp_audit', 'cp_admin_requests', 'cp_officers', 'cp_mission_runs', 'cp_mission_runs_archive' }) do
        H.sql('DELETE FROM ' .. t)
    end
    for _, m in ipairs({
        'modules/permissions/server.lua',
        'modules/access/server.lua',
        'modules/admin/server.lua',
        'modules/adminkit/server.lua',
        'modules/tablet/server.lua',
        'modules/schedule/server.lua',
        'modules/scaling/server.lua',
        'modules/events/server.lua',
        'modules/units/server.lua',
        'modules/runs/server.lua',
        'modules/livectl/server.lua',
    }) do
        H.load(m)
    end
    H.step(0)

    -- every officer has a cp_officers row (the tablet writes it at the first open)
    for _, p in pairs(W.people) do
        H.sql('INSERT INTO cp_officers (citizenid, department, license) VALUES (?, ?, ?)', { p.cid, p.job, p.license })
    end

    -- ---- CALLS -------------------------------------------------------------
    local seq = 0
    function W.act(name, src, payload)
        H.clockMs = H.clockMs + 3100
        seq = seq + 1
        local reqId = 'r' .. seq
        H.fire('crimson-police:' .. name, src, payload, reqId)
        for i = #H.events, 1, -1 do
            local e = H.events[i]
            if e.name == 'crimson-police:client:actionResult' and e.args[1] == reqId then
                return e.args[2], e.args[3]
            end
        end
        return nil, 'no reply'
    end
    function W.cb(name, src, args)
        H.clockMs = H.clockMs + 1100
        return H.callback('crimson-police:' .. name, src, args)
    end

    -- A live run of the test mission for these srcs (accepted; W.start puts it in progress).
    function W.newRun(srcs, opts)
        opts = opts or {}
        local run, err = CP.Runs.create({
            mission = opts.mission or W.DEF,
            locationIndex = 1,
            missionType = opts.missionType or (opts.mission or W.DEF).type,
            members = srcs,
            leaderSrc = srcs[1],
            test = opts.test,
            operationId = opts.operationId,
            isBoss = opts.isBoss,
        })
        return run, err
    end
    function W.start(run)
        for _, src in ipairs(CP.Runs.activeSrcs(run)) do CP.Runs.markArrived(run, src) end
    end

    -- A saved row: { cid, type, id, reason, state, ts, voided, uuid }
    local rowSeq = 0
    function W.row(r)
        rowSeq = rowSeq + 1
        local uuid = r.uuid or ('%08x-1111-4000-8000-%012x'):format(rowSeq, 3)
        H.sql(
            [[INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason,
            points_base, voided, created_at) VALUES (?, ?, ?, ?, 'sast', ?, ?, 100, ?, FROM_UNIXTIME(?))]], {
                uuid,
                r.type or 'patrol',
                r.id or W.DEF.id,
                r.cid,
                r.state or 'completed',
                r.reason or 'completed',
                r.voided and 1 or 0,
                r.ts or os.time(),
            })
        return uuid
    end

    function W.audits(action)
        return H.sql(
            'SELECT actor, category, action, target, old_value, new_value, reason FROM cp_audit WHERE action = ? ORDER BY id',
            { action })
    end

    function W.toasts(src, key)
        local n = 0
        for _, e in ipairs(H.events) do
            if e.name == 'crimson-police:client:notify' and e.target == src and type(e.args[1]) == 'table'
                and e.args[1].key == key then
                n = n + 1
            end
        end
        return n
    end

    return W
end
