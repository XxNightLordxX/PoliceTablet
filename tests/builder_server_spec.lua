-- Modules/builder/server.lua (slice builder_server).

local H = dofile('tests/harness.lua')
H.db = (os.getenv('CP_TEST_DB') or 'cp_test') .. '_builder_server'   -- per run: parallel runs never share it
H.resetDatabase()
H.boot({ side = 'server' })

local U = CP.U
local cjson = require('cjson')

-- ============================================================================
--                                    LOCALE
-- ============================================================================
-- Every part merged, served as en.json (block reasons come translated).

local merged = {}
do
    local p = io.popen('ls ' .. H.root .. 'locales/parts/*.json 2>/dev/null')
    for file in p:lines() do
        local f = io.open(file, 'r')
        local ok, data = pcall(cjson.decode, f:read('a'))
        f:close()
        if ok and type(data) == 'table' then for k, v in pairs(data) do merged[k] = v end end
    end
    p:close()
end
local mergedText = cjson.encode(merged)
local realLoad = LoadResourceFile
LoadResourceFile = function(res, path)
    if path == 'locales/en.json' then return mergedText end
    return realLoad(res, path)
end
H.load('shared/locale.lua')

-- ============================================================================
--         THE LOCALE PART OF THIS SLICE HAS EVERY KEY THE MODULE USES
-- ============================================================================

do
    local f = io.open(H.root .. 'locales/parts/builder_server.json', 'r')
    local part = cjson.decode(f:read('a'))
    f:close()
    local src = io.open(H.root .. 'modules/builder/server.lua', 'r'):read('a')
    local missing = {}
    for key in src:gmatch('\'(err%.[%w_]+)\'') do if not part[key] then missing[#missing + 1] = key end end
    for key in src:gmatch('\'(builder%.[%w_%.]+)\'') do
        if not key:match('%.$') and not part[key] then missing[#missing + 1] = key end
    end
    for _, b in ipairs({
        'hostile_waves',
        'escort',
        'pursuit',
        'checkpoint_route',
        'interact_points',
        'skill_check',
        'protect_rescue',
        'flee_arrest',
        'search_area',
    }) do
        if not part['builder.block.' .. b] then missing[#missing + 1] = 'builder.block.' .. b end
    end
    H.eq(table.concat(missing, ', '), '',
        'every locale key used by modules/builder/server.lua is in builder_server.json')
    -- keys shared with other parts carry the same text
    local p = io.popen('ls ' .. H.root .. 'locales/parts/*.json')
    local clash = {}
    for file in p:lines() do
        if not file:find('builder_server.json', 1, true) then
            local other = cjson.decode(io.open(file, 'r'):read('a'))
            for k, v in pairs(part) do
                if other[k] ~= nil and other[k] ~= v then
                    clash[#clash + 1] = k .. ' (' .. file:match('[^/]+$') .. ')'
                end
            end
        end
    end
    p:close()
    H.eq(table.concat(clash, ', '), '', 'shared locale keys have identical text')
end

-- ============================================================================
--                           TEMPORARY EXPORT FOLDER
-- ============================================================================
-- Not created here: the builder must create a missing export folder and its archived/ itself (a fresh
-- clone has neither, and SaveResourceFile does not create folders).
local TMP = ('missions/custom/test_builder_%d/'):format(os.clock() * 1e6 // 1 + math.random(1, 1e6))
Config.Builder.exportPath = TMP
-- The test gate is off as shipped (testing is optional); most checks below are about the gate itself, so it is on
-- until the "testing is optional" block switches it back off.
Config.Builder.requireTestToPublish = true
_G.GetResourcePath = function() return H.root:sub(1, -2) end

local function FileExists(rel)
    local f = io.open(H.root .. rel, 'r')
    if f then f:close(); return true end
    return false
end
local function ReadRel(rel)
    local f = io.open(H.root .. rel, 'r')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return s
end
local function WriteRel(rel, s)
    local f = assert(io.open(H.root .. rel, 'w'))
    f:write(s)
    f:close()
end

-- deep equality (numbers by value, so 60 == 60.0)
local function Deq(a, b, path)
    path = path or ''
    if type(a) ~= type(b) then return false, path .. ' type ' .. type(a) .. ' vs ' .. type(b) end
    if type(a) ~= 'table' then
        if a == b then return true end
        return false, path .. ' ' .. tostring(a) .. ' vs ' .. tostring(b)
    end
    for k, v in pairs(a) do
        local ok, why = Deq(v, b[k], path .. '.' .. tostring(k))
        if not ok then return false, why end
    end
    for k in pairs(b) do
        if a[k] == nil then return false, path .. '.' .. tostring(k) .. ' missing on the left' end
    end
    return true
end
local function Plain(v) return cjson.decode(cjson.encode(U.serialize(v))) end

local function Body()
    -- ---- STUBS OF OTHER MODULES --------------------------------------------
    local players = {
        [1] = {
            citizenid = 'SUP00001',
            name = 'John Doe',
            rank = 'Sergeant',
            dept = 'sast',
            short = 'SAST',
            grade = 3,
            sup = true,
        },
        [2] = {
            citizenid = 'SUP00002',
            name = 'Jane Roe',
            rank = 'Lieutenant',
            dept = 'fib',
            short = 'FIB',
            grade = 4,
            sup = true,
        },
        [3] = { citizenid = 'ADM00001', name = 'Ada Admin', admin = true },
        [4] = {
            citizenid = 'OFF00001',
            name = 'Otto Officer',
            rank = 'Trooper',
            dept = 'sast',
            short = 'SAST',
            grade = 1,
        },
    }
    CP.Access = {
        isAdmin = function(src) return src == 0 or (players[src] ~= nil and players[src].admin == true) end,
        isSupervisor = function(src) return players[src] ~= nil and players[src].sup == true end,
        getOfficer = function(src)
            local p = players[src]
            if not p or not p.dept then return nil, 'err.not_police' end
            return {
                src = src,
                citizenid = p.citizenid,
                name = p.name,
                department = p.dept,
                departmentShort = p.short,
                rank = p.rank,
                gradeLevel = p.grade,
                isSupervisor = p.sup == true,
                isAdmin = p.admin == true,
                onduty = true,
            }
        end,
        departmentForJob = function() return nil end,
        department = function() return nil end,
        role = function(src) return players[src] and (players[src].admin and 'admin' or 'supervisor') or nil end,
    }
    CP.Qbx = {
        getInfo = function(src)
            local p = players[src]
            if not p then return nil end
            return {
                src = src,
                citizenid = p.citizenid,
                name = p.name,
                job = { name = 'unemployed', gradeName = 'Freelancer' },
            }
        end,
        getByCitizenId = function(cid)
            for src, p in pairs(players) do if p.citizenid == cid then return src end end
            return nil
        end,
        onPlayerUnload = function(fn) CP.Qbx._unload = fn end,
    }
    local audits, pushes, notes, drafts = {}, {}, {}, {}
    CP.Admin = {
        audit = function(actor, role, category, action, target, old, new, reason)
            audits[#audits + 1] = {
                actor = actor,
                role = role,
                category = category,
                action = action,
                target = target,
                old = old,
                new = new,
                reason = reason,
            }
        end,
    }
    CP.Tablet = {
        push = function(src, topic, data) pushes[#pushes + 1] = { src = src, topic = topic, data = data } end,
        notify = function(src, kind, key, vars)
            notes[#notes + 1] = { src = src, kind = kind, key = key, vars = vars }
        end,
    }
    local testingOk = true
    CP.Testing = {
        startDraft = function(src, def, opts)
            drafts[#drafts + 1] = { src = src, def = def, opts = opts }
            if not testingOk then return false, 'err.in_arena' end
            -- as modules/testing: the data names the location that runs ('random' picks one)
            return true,
                {
                    runId = 'run-' .. #drafts,
                    missionId = def.id,
                    locationIndex = opts.location == 'random' and 3 or opts.location,
                    tier = opts.tier,
                    testers = 1,
                }
        end,
    }
    local inArena = {}
    CP.Alerts = {
        inArena = function(src) return inArena[src] == true end,
    }
    CP.Npc = CP.Npc
        or {
            setState = function() end,
            getState = function() end,
            rollSurrender = function() return false end,
            enableCuff = function() end,
            onDeath = function() end,
            onDamaged = function() end,
        }

    H.load('modules/scaling/server.lua')
    H.load('modules/permissions/server.lua')
    for _, b in ipairs({
        'checkpoint_route',
        'interact_points',
        'skill_check',
        'hostile_waves',
        'protect_rescue',
        'flee_arrest',
        'pursuit',
        'escort',
        'search_area',
        'field_contact',
        'process_scene',
    }) do
        local ok, err = pcall(H.load, 'blocks/' .. b .. '/server.lua')
        if not ok then print('  (block ' .. b .. ' did not load: ' .. tostring(err) .. ')') end
    end
    H.sql('DELETE FROM cp_custom_missions')
    H.sql('DELETE FROM cp_officers')
    H.sql(
        'INSERT INTO cp_officers (citizenid, display_name, department) VALUES (\'SUP00001\', \'John Doe\', \'sast\'), (\'SUP00002\', \'Jane Roe\', \'fib\')')
    H.load('modules/builder/server.lua')
    H.load('modules/missions/server.lua')
    H.step(10)   -- CP.Missions.loadAll (built-ins + CP.Builder.loadPublished)
    local B = CP.Builder
    do
        local function isDir(rel)
            local ok, r = pcall(os.rename, H.root .. rel, H.root .. rel)
            return ok and r == true
        end
        H.ok(isDir(TMP) and isDir(TMP .. 'archived'),
            'the builder creates a missing export folder and archived/ at start')
        H.ok(FileExists('missions/custom/.gitkeep') and FileExists('missions/custom/archived/.gitkeep'),
            'missions/custom/ and archived/ ship with a .gitkeep so a clone has them')
        -- as on a Linux FXServer: os.rename answers inverted, os.execute is refused, os.createdir makes one folder
        local realRename, realExecute, realErr = os.rename, os.execute, CP.err
        local alarms = 0
        os.rename = function(a, b)
            local ok = realRename(a, b)
            if ok then return nil, 'inverted' end
            return true
        end
        os.execute = function() return nil, 'Permission denied' end
        os.createdir = function(p) return realExecute(('mkdir \'%s\' 2>/dev/null'):format(p)) end
        CP.err = function(tag, fmt, ...)
            if tostring(fmt):find('could not be created', 1, true) then alarms = alarms + 1 end
            return realErr(tag, fmt, ...)
        end
        local okFx, errFx = pcall(function()
            H.ok(B.ensureExportDirs(), 'FXServer: the existing export folders are found')
            H.eq(alarms, 0, 'FXServer: no false "could not be created" error for folders that exist')
            realExecute(('rm -rf \'%s%s\''):format(H.root, TMP))
            H.ok(B.ensureExportDirs(), 'FXServer: the missing export folders are created')
            local function onDisk(rel) return realRename(H.root .. rel, H.root .. rel) == true end
            H.ok(onDisk(TMP) and onDisk(TMP .. 'archived'), 'FXServer: they are on disk (os.createdir)')
        end)
        os.rename, os.execute, os.createdir, CP.err = realRename, realExecute, nil, realErr
        H.ok(okFx, 'FXServer folder checks ran: ' .. tostring(errFx))
        if not isDir(TMP .. 'archived') then os.execute(('mkdir -p \'%s%sarchived\''):format(H.root, TMP)) end
    end
    H.ok(CP.Missions.get('gang_shootout') ~= nil or CP.Missions.list()[1] ~= nil,
        'built-in missions loaded next to the builder')

    -- ---- HELPERS: actions and callbacks through CP.Net ---------------------
    local reqN = 0
    local function act(src, name, payload)
        reqN = reqN + 1
        local reqId = 'q' .. reqN
        H.clockMs = H.clockMs + 6000      -- past every per-action rate limit
        H.fire('crimson-police:server:builder:' .. name, src, payload, reqId)
        for i = #H.events, 1, -1 do
            local e = H.events[i]
            if e.name == 'crimson-police:client:actionResult' and e.args[1] == reqId then
                return e.args[2], e.args[3]
            end
        end
        error('no reply for ' .. name)
    end
    local function cb(src, name, args)
        H.clockMs = H.clockMs + 2000
        local res = H.callback('crimson-police:' .. name, src, args)
        return res.ok, res.ok and res.data or res.error
    end
    local function row(id)
        return H.sql(
            'SELECT id, status, published_version, draft_version, draft_tested, file_path, edited_in_code, locked_by, created_by, updated_by, mission_type, draft_definition, published_definition FROM cp_custom_missions WHERE id = ?',
            { id })[1]
    end
    local function lastAudit() return audits[#audits] end
    local function hasError(errors, key)
        for _, e in ipairs(errors) do if e.key == key then return true end end
        return false
    end
    local function errorAt(errors, path)
        for _, e in ipairs(errors) do if e.path == path then return e end end
        return nil
    end
    local function keysOf(errors)
        local out = {}
        for _, e in ipairs(errors) do out[#out + 1] = tostring(e.key or e.message) end
        return table.concat(out, ' | ')
    end

    -- ---- A VALID BUILDER DEFINITION ----------------------------------------
    local function location(i)
        local x, y = -1200.0 + i * 600.0, -1500.0 - i * 50.0
        local spawns = {}
        for s = 1, 11 do spawns[s] = { x = x + 40.0 + s, y = y + 45.0, z = 21.5, w = 90.0 } end
        return {
            label = 'Dock ' .. i,
            start = { coords = { x = x, y = y, z = 21.0 }, radius = 60 },
            spawns = spawns,
            evidence = { { x = x + 50.0, y = y + 10.0, z = 21.2 }, { x = x + 52.5, y = y + 12.25, z = 21.2 } },
        }
    end
    local function validDef()
        return {
            label = 'Dockside Raid',
            description = 'A smuggling crew is unloading at the docks.',
            type = 'tactical',
            departments = {},
            minOfficers = 2,
            maxOfficers = 4,
            difficulty = 3,
            timeLimit = 720,
            startTimeout = 600,
            cooldown = 1200,
            vehiclePenalties = false,
            locations = { location(1), location(2), location(3) },
            objectives = {
                {
                    block = 'hostile_waves',
                    label = 'Clear the dock',
                    minSeconds = 45,
                    presenceRange = 150,
                    waves = { 7, 6 },
                    weapons = { 'WEAPON_PISTOL', 'WEAPON_SMG' },
                    accuracy = 30,
                    armour = 10,
                    surrender = { belowHealth = 0.25, chance = 30 },
                },
                {
                    block = 'interact_points',
                    label = 'Seize the shipment',
                    minSeconds = 6,
                    presenceRange = 150,
                    points = 'evidence',
                    progress = { label = 'Seizing crates', duration = 6 },
                },
            },
            scaling = { 'objectives.1.waves' },
            items = { { name = 'radio', count = 1 } },
            bonuses = { { id = 'no_participant_downed', pct = 10 }, { id = 'hostile_arrested', points = 5 } },
            penalties = {},
        }
    end

    -- ══ pure: customBonusFields (duplicates of built-ins) ═════════════════════
    do
        local d = {
            objectives = {
                { block = 'flee_arrest', aliveBonus = { id = 'suspect_alive', points = 15 } },
                { block = 'flee_arrest', aliveBonus = { id = 'inmate_alive', points = 10, each = true } },
                { block = 'hostile_waves', boss = { model = 'x', aliveBonus = { id = 'kingpin_alive', points = 50 } } },
                { block = 'hostile_waves', boss = { model = 'x', aliveBonus = { id = 'boss_down', points = 50 } } },
                {
                    block = 'pursuit',
                    ramPenaltyId = 'ram',
                    detainBonus = 'racer_detained',
                    allDetainedBonus = 'hostile_arrested',
                    fastStop = { id = 'fast_x', seconds = 600 },
                },
                { block = 'interact_points', fastBonus = { id = 'devices_found_fast', seconds = 120 } },
                { block = 'interact_points', fastBonus = { id = 'correct_log', seconds = 120 } },
            },
        }
        B.customBonusFields(d)
        local o = d.objectives
        H.eq(o[1].aliveBonus.id, 'suspect_alive', 'strip: a standard alive bonus id is kept')
        H.eq(o[1].aliveBonus.points, nil, 'strip: its points dropped')
        H.eq(o[2].aliveBonus, nil, 'strip: a built-in-only alive bonus is dropped (block default)')
        H.eq(o[3].boss.aliveBonus.id, 'kingpin_alive', 'strip: kingpin_alive kept')
        H.eq(o[3].boss.aliveBonus.points, nil, 'strip: boss points dropped')
        H.eq(o[4].boss.aliveBonus, nil, 'strip: an unknown boss bonus is dropped')
        H.eq(o[5].ramPenaltyId, nil, 'strip: ram id outside Config.Bonuses dropped (default hard_ram)')
        H.eq(o[5].detainBonus, nil, 'strip: racer_detained dropped (the block default comes back)')
        H.eq(o[5].allDetainedBonus, 'hostile_arrested', 'strip: a standard id is kept')
        H.eq(o[5].fastStop.id, nil, 'strip: fast stop id dropped')
        H.eq(o[5].fastStop.seconds, 120, 'strip: fast stop at most 120 s')
        H.eq(o[6].fastBonus, nil, 'strip: a built-in-only fast bonus is dropped')
        H.eq(o[7].fastBonus.id, 'correct_log', 'strip: a standard fast bonus is kept')
    end

    -- ══ pure: slug, sanitize ════════════════════════════════════════════════
    H.eq(B.slug('Dockside Raid'), 'dockside_raid', 'slug')
    H.eq(B.slug('  --Warehouse #12: Night!! '), 'warehouse_12_night', 'slug strips punctuation')
    H.eq(B.slug(''), 'mission', 'empty slug')
    H.ok(#B.slug(('long name '):rep(10)) <= 30, 'slug length capped')

    do
        local raw = validDef()
        raw.payout = 5000
        raw.cashBase = 10
        raw.source = 'builtin'
        raw._file = { hash = 'x' }
        raw.locations[1].start.coords = { x = 1.23456, y = -2.005, z = 3.999 }
        raw.objectives[1].surrender.chance = 30.4
        raw.objectives[2].progress.duration = 6.0004
        raw.bonuses = { { id = 'no_participant_downed' }, { id = 'hostile_arrested' } }
        raw.penalties = { { id = 'hard_ram', points = 10 } }
        raw.departments = { sast = true, fib = true }
        local d, err, info = B.sanitize(raw, 'custom_x')
        H.ok(d ~= nil, 'sanitize accepts a definition: ' .. tostring(err))
        H.ok(info.payout, 'sanitize reports a payout field')
        H.eq(d.payout, nil, 'payout stripped')
        H.eq(d.cashBase, nil, 'cashBase stripped')
        H.eq(d.source, nil, 'loader field stripped')
        H.eq(d._file, nil, '_file stripped')
        H.eq(d.id, 'custom_x', 'id from the row')
        H.eq(d.locations[1].start.coords.x, 1.23, 'vector rounded to 2 decimals (x)')
        H.eq(d.locations[1].start.coords.z, 4.0, 'vector rounded to 2 decimals (z)')
        H.eq(d.objectives[1].surrender.chance, 30, 'chance rounded to whole percent')
        H.eq(d.objectives[2].progress.duration, 6.0, 'seconds rounded to ms')
        H.eq(d.bonuses[1].pct, 10, 'pct bonus value filled from config')
        H.eq(d.bonuses[2].points, 5, 'flat bonus value filled from config')
        H.eq(d.penalties[1].points, -10, 'penalty points are negative')
        H.eq(table.concat(d.departments, ','), 'fib,sast', 'department map to sorted list')
        local huge = { label = 'x', objectives = {} }
        local node = huge
        for _ = 1, 15 do node.next = {}; node = node.next end
        local tooDeep = B.sanitize(huge, 'custom_x')
        H.eq(tooDeep, nil, 'too deep definitions are refused')
        local big = { label = 'x', locations = {} }
        for i = 1, 25000 do big.locations[i] = 1 end
        local r1, r2 = B.sanitize(big, 'custom_x')
        H.eq(r1, nil, 'too large refused')
        H.eq(r2, 'err.builder_too_large', 'too large error key')
        H.eq(select(2, B.sanitize('nope')), 'err.invalid_payload', 'non-table refused')
        local bad = B.sanitize({ label = 'x', n = 0 / 0, big = 1e12, ['bad key'] = 1, [5] = 2 }, 'custom_x')
        H.eq(bad.n, nil, 'NaN dropped')
        H.eq(bad.big, nil, 'huge number dropped')
        H.eq(bad['bad key'], nil, 'bad key dropped')
    end

    -- ══ guardrails ══════════════════════════════════════════════════════════
    local good = B.sanitize(validDef(), 'custom_dockside_raid')
    do
        local errors, info = B.validate(good, { publish = true })
        H.eq(keysOf(errors), '', 'the valid definition passes every guardrail')
        H.eq(info.armed, 13, 'armed NPCs counted with block armedCount')
        H.eq(info.requiredTier, 'heavy', 'maxOfficers 4 needs a Heavy test')
    end
    local function check(label, mutate, key, path)
        local d = U.deepcopy(good)
        mutate(d)
        local errors = B.validate(d)
        if key then
            H.ok(hasError(errors, key), label .. ' -> ' .. key .. ' (got: ' .. keysOf(errors) .. ')')
        end
        if path then
            H.ok(errorAt(errors, path) ~= nil, label .. ' at ' .. path .. ' (got: ' .. keysOf(errors) .. ')')
        end
        return errors
    end
    check('no type', function(d) d.type = nil end, 'builder.error.type_required', 'type')
    check('unknown type', function(d) d.type = 'traffic' end, 'builder.error.type_required')
    do
        local d = U.deepcopy(good)
        local errors = B.validate(d, { raw = { payout = 10 } })
        H.ok(hasError(errors, 'builder.error.payout_field'), 'a payout field in the input is refused')
        d.basePay = 20
        H.ok(hasError(B.validate(d), 'builder.error.payout_field'), 'a payout field in the definition is refused')
    end
    do
        -- payout fields below the top level (hard rule: no payout fields in mission files)
        local raw = validDef()
        raw.objectives[1].payout = 99999
        raw.locations[1].reward = 5000
        local d = B.sanitize(raw, 'custom_x')
        H.ok(hasError(B.validate(d, { raw = raw }), 'builder.error.payout_field'),
            'a payout field inside an objective or a location is refused')
        local nested = U.deepcopy(good)
        nested.objectives[2].progress.money = 10
        H.ok(hasError(B.validate(nested), 'builder.error.payout_field'), 'and refused inside the definition itself')
        H.ok(d.objectives[1].payout == nil and d.locations[1].reward == nil, 'nested payout fields are stripped')
        local text = B.exportLua(d, { version = 1, publisher = 'x', at = os.time() })
        H.ok(not text:find('payout =', 1, true) and not text:find('reward', 1, true),
            'the mission file carries no nested payout field')
    end
    check('time limit under 2 min', function(d) d.timeLimit = 100 end, 'builder.error.time_limit', 'timeLimit')
    check('time limit over 20 min', function(d) d.timeLimit = 1260 end, 'builder.error.time_limit')
    check('start timeout', function(d) d.startTimeout = 60 end, 'builder.error.start_timeout')
    check('cooldown', function(d) d.cooldown = 4000 end, 'builder.error.cooldown')
    check('officers', function(d) d.minOfficers = 3; d.maxOfficers = 2 end, 'builder.error.officers')
    check('officers over 4', function(d) d.maxOfficers = 5 end, 'builder.error.officers')
    check('difficulty', function(d) d.difficulty = 4 end, 'builder.error.difficulty')
    check('department', function(d) d.departments = { 'lspd' } end, 'builder.error.departments')
    check('label', function(d) d.label = '   ' end, 'builder.error.label')
    check('label too long', function(d) d.label = ('x'):rep(65) end, 'builder.error.label')
    check('vehicle penalties', function(d) d.vehiclePenalties = 'yes' end, 'builder.error.vehicle_penalties')
    check('two locations', function(d) d.locations[3] = nil end, 'builder.error.min_locations', 'locations')
    check('locations 50 m apart', function(d)
        d.locations[2] = U.deepcopy(d.locations[1])
        d.locations[2].start.coords.x = d.locations[1].start.coords.x + 50
    end, 'builder.error.location_gap', 'locations.2.start')
    check('start missing', function(d)
        d.locations[2].start = nil
    end, 'builder.error.start_missing', 'locations.2.start')
    check('start radius', function(d) d.locations[1].start.radius = 5 end, 'builder.error.start_radius')
    check('spawn 20 m from the start', function(d)
        local s = d.locations[1].start.coords
        d.locations[1].spawns[3] = { x = s.x + 20, y = s.y, z = s.z, w = 0 }
    end, 'builder.error.spawn_start', 'locations.1.spawns')
    check('evidence close to the start is fine (not a spawn key)', function(d)
        local s = d.locations[1].start.coords
        d.locations[1].evidence[1] = { x = s.x + 5, y = s.y, z = s.z }
    end, nil)
    do
        local d = U.deepcopy(good)
        local s = d.locations[1].start.coords
        d.locations[1].evidence[1] = { x = s.x + 5, y = s.y, z = s.z }
        H.eq(keysOf(B.validate(d)), '', 'marker points may be near the start')
    end
    check('spawn in a no-build zone', function(d)
        d.locations[2].spawns[1] = { x = 470.63, y = -974.11, z = 30.18, w = 0 }
    end, 'builder.error.point_zone', 'locations.2.spawns')
    check('Crimson-Arena lobby is a no-build zone', function(d)
        d.locations[3].evidence[1] = { x = -282.01, y = -2030.46, z = 30.15 }
    end, 'builder.error.point_zone', 'locations.3.evidence')
    check('start inside a zone', function(d)
        d.locations[1].start.coords = { x = 2344.43, y = 2565.06, z = 46.67 }
    end, 'builder.error.point_zone', 'locations.1.start')
    check('point in the air', function(d) d.locations[1].evidence[2].z = 5000 end, 'builder.error.point_coords')
    check('point off the map', function(d) d.locations[1].evidence[2].x = 40000 end, 'builder.error.point_coords')
    check('armed budget over 40', function(d)
        d.objectives[1].waves = { 15, 15, 12 }
        for li = 1, 3 do
            for s = 12, 23 do
                local c = d.locations[li].start.coords
                d.locations[li].spawns[s] = { x = c.x + 40 + s, y = c.y + 60, z = c.z, w = 0 }
            end
        end
    end, 'builder.error.armed_budget', 'objectives')
    check('weapon outside the allowed list (block validate)', function(d)
        d.objectives[1].weapons = { 'WEAPON_RPG' }
    end, nil, 'objectives.1')
    check('ped outside the allowed list (block validate)', function(d)
        d.objectives[1].peds = { 'mp_m_freemode_01' }
    end, nil, 'objectives.1')
    check('block range (accuracy 90)', function(d) d.objectives[1].accuracy = 90 end, nil, 'objectives.1')
    -- objective-level bonus values from the definition never pass for a custom mission (block validate)
    do
        local d = U.deepcopy(good)
        d.objectives[1].boss = { model = 'g_m_y_lost_01' }
        H.eq(errorAt(B.validate(d), 'objectives.1'), nil, 'a boss with the block\'s own kingpin_alive passes')
    end
    check('boss bonus with its own points (block validate)', function(d)
        d.objectives[1].boss = { model = 'g_m_y_lost_01', aliveBonus = { id = 'kingpin_alive', points = 5000 } }
    end, nil, 'objectives.1')
    check('boss bonus id outside Config.Bonuses (block validate)', function(d)
        d.objectives[1].boss = { model = 'g_m_y_lost_01', aliveBonus = { id = 'boss_down', points = 40 } }
    end, nil, 'objectives.1')
    check('fast bonus id outside Config.Bonuses (block validate)', function(d)
        d.objectives[2].fastBonus = { id = 'crates_fast', seconds = 60 }
    end, nil, 'objectives.2')
    check('required points missing', function(d)
        d.locations[2].evidence = nil
    end, 'builder.error.point_missing', 'locations.2.evidence')
    check('min seconds 0', function(d)
        d.objectives[2].minSeconds = 0
    end, 'builder.error.min_seconds', 'objectives.2.minSeconds')
    check('min seconds over the time limit', function(d)
        d.objectives[1].minSeconds = 700
        d.objectives[2].minSeconds = 100
    end, 'builder.error.min_seconds_total')
    check('presence range', function(d) d.objectives[1].presenceRange = 20 end, 'builder.error.presence_range')
    check('unknown block', function(d)
        d.objectives[3] = { block = 'traffic_stop', label = 'x', minSeconds = 5 }
    end, 'builder.error.unknown_block', 'objectives.3.block')
    check('no objectives', function(d) d.objectives = {} end, 'builder.error.no_objectives')
    check('seven blocks', function(d)
        for i = 3, 7 do d.objectives[i] = U.deepcopy(d.objectives[2]) end
    end, 'builder.error.max_blocks')
    check('flat bonus over 50', function(d)
        d.bonuses[2].points = 60
    end, 'builder.error.bonus_cap_points', 'bonuses.2.points')
    check('pct bonus over 25%', function(d) d.bonuses[1].pct = 30 end, 'builder.error.bonus_cap_pct', 'bonuses.1.pct')
    check('penalty over 50', function(d)
        d.penalties = { { id = 'hard_ram', points = -60 } }
    end, 'builder.error.bonus_cap_points')
    check('unknown bonus', function(d)
        d.bonuses[3] = { id = 'racer_detained', points = 30 }
    end, 'builder.error.bonus_unknown')
    check('penalty listed as a bonus', function(d)
        d.bonuses[3] = { id = 'wrong_log', points = -5 }
    end, 'builder.error.bonus_sign')
    check('bonus needs its block', function(d)
        d.bonuses[3] = { id = 'suspect_alive', points = 15 }
    end, 'builder.error.bonus_block')
    check('duplicate bonus', function(d)
        d.bonuses[3] = { id = 'hostile_arrested', points = 5 }
    end, 'builder.error.bonus_duplicate')
    for _, name in ipairs({
        'armour',
        'bandage',
        'ammo-9',
        'Ammo-rifle',
        'WEAPON_PISTOL',
        'weapon_knife',
        'money',
        'Black_Money',
    }) do
        check('item ' .. name, function(d)
            d.items = { { name = name, count = 1 } }
        end, 'builder.error.item_forbidden', 'items.1.name')
    end
    check('item count', function(d) d.items[1].count = 0 end, 'builder.error.item_count')
    check('item name', function(d) d.items[1].name = 'bad name!' end, 'builder.error.item_name')
    check('scaling path outside the objectives', function(d)
        d.scaling = { 'objectives.9.waves' }
    end, 'builder.error.scaling_path')
    check('scaling a text field', function(d) d.scaling = { 'objectives.2.points' } end, 'builder.error.scaling_field')
    check('scaling an allowed count that is not a number', function(d)
        d.objectives[2].count = 'two'
        d.scaling = { 'objectives.2.count' }
    end, 'builder.error.scaling_value')
    check('scaling max', function(d)
        d.scaling = { { path = 'objectives.1.waves', max = -1 } }
    end, 'builder.error.scaling_max')
    -- only counts marked "scales" may scale (accuracy, armour, timers, penalties... never do)
    for _, path in ipairs({
        'objectives.1.accuracy',
        'objectives.1.armour',
        'objectives.1.minSeconds',
        'objectives.1.presenceRange',
        'objectives.1.surrender.chance',
        'objectives.2.progress.duration',
    }) do
        check('scaling ' .. path, function(d) d.scaling = { path } end, 'builder.error.scaling_field')
    end
    for _, m in ipairs({
        'armored_truck_escort',
        'bomb_disposal',
        'gang_shootout',
        'manhunt',
        'prison_break',
        'stolen_vehicle_takedown',
        'street_race_bust',
        'warrant_service',
    }) do
        local def = CP.Missions.get(m)
        if def then
            for _, entry in ipairs(def.scaling or {}) do
                local path = type(entry) == 'string' and entry or entry.path
                local blk = def.objectives[tonumber(path:match('^objectives%.(%d+)'))].block
                H.ok((B.SCALABLE_FIELDS[blk] or {})[path:match('^objectives%.%d+%.(.+)$')] == true,
                    'built-in scaling path is an allowed count: ' .. m .. ' ' .. path)
            end
        end
    end
    do
        local d = U.deepcopy(good)
        d.scaling = { { path = 'objectives.1.waves', max = 12 } }
        H.eq(keysOf(B.validate(d)), '', 'scaling { path, max } accepted')
    end

    -- road routes (a recorded route stored in a location key)
    local function route(len, loop)
        local pts, n = {}, math.floor(len / 100)
        for i = 0, n do pts[#pts + 1] = { x = 3000.0 + i * 100.0, y = 500.0, z = 30.0 } end
        if loop then pts[#pts + 1] = { x = 3000.0, y = 520.0, z = 30.0 } end
        return { points = pts }
    end
    local function withRoute(r)
        local d = U.deepcopy(good)
        for li = 1, 3 do d.locations[li].route = U.deepcopy(r) end
        return B.validate(d)
    end
    H.eq(keysOf(withRoute(route(2000))), '', 'a 2 km open route passes')
    H.ok(hasError(withRoute(route(500)), 'builder.error.route_length'), 'a 0.5 km route is too short')
    H.ok(hasError(withRoute(route(9000)), 'builder.error.route_length'), 'a 9 km route is too long')
    do
        local r = route(1000)
        r.points[#r.points] = { x = 3000.0, y = 700.0, z = 30.0 }
        r.points[#r.points - 1] = { x = 3100.0, y = 650.0, z = 30.0 }
        local errors = withRoute(r)
        H.ok(hasError(errors, 'builder.error.route_gap'),
            'open route start and end under 300 m apart: ' .. keysOf(errors))
    end
    do
        local r = route(1200, true)
        r.loop = true
        H.eq(keysOf(withRoute(r)), '', 'a closed race loop passes')
        r.points[#r.points] = { x = 3000.0, y = 700.0, z = 30.0 }
        H.ok(hasError(withRoute(r), 'builder.error.route_loop'), 'a loop must end within 50 m of its start')
    end
    do
        local r = route(2000)
        r.points[5] = { x = 470.0, y = -974.0, z = 30.0 }
        H.ok(hasError(withRoute(r), 'builder.error.point_zone'), 'a waypoint in a no-build zone is refused')
        local r2 = route(2000)
        r2.stops = { { at = 3, wait = 20 } }
        H.eq(keysOf(withRoute(r2)), '', 'route stops within range pass')
        r2.stops = { { at = 3, wait = 5 } }
        H.ok(hasError(withRoute(r2), 'builder.error.route_stops'), 'stop wait under 10 s is refused')
        r2.stops = { { at = 99, wait = 20 } }
        H.ok(hasError(withRoute(r2), 'builder.error.route_stops'), 'stop index outside the route is refused')
    end

    -- ══ unit conversion ═════════════════════════════════════════════════════
    do
        local f = B.toFileUnits(good)
        H.near(f.objectives[1].surrender.chance, 0.30, 1e-12, 'chance percent -> fraction')
        H.eq(f.objectives[1].surrender.belowHealth, 0.25, 'health share stays a fraction')
        H.eq(f.objectives[2].progress.duration, 6000, 'progress seconds -> ms')
        H.near(f.bonuses[1].pctOfPoints, 0.10, 1e-12, 'pct bonus -> pctOfPoints')
        H.eq(f.bonuses[2].points, 5, 'flat bonus points')
        H.eq(f.bonuses[2].each, true, 'each from Config.Bonuses')
        local back = B.fromFileUnits(f)
        local ok, why = Deq(Plain(back), Plain(good))
        H.ok(ok, 'file units -> builder units round trip: ' .. tostring(why))
        local io_ = {
            block = 'interact_points',
            roll = {
                outcomes = {
                    { id = 'a', chance = 75, followUp = { label = 'x', duration = 2.5 } },
                    { id = 'b', chance = 25 },
                },
            },
        }
        local fa = B.toFileUnits({ objectives = { io_ } })
        H.near(fa.objectives[1].roll.outcomes[1].chance, 0.75, 1e-12, 'roll outcome chances (wildcard path)')
        H.eq(fa.objectives[1].roll.outcomes[1].followUp.duration, 2500, 'follow-up seconds -> ms (wildcard path)')
        local fl = B.toFileUnits({
            objectives = {
                {
                    block = 'flee_arrest',
                    responses = { surrender = 50, flee = 30, fight = 20 },
                    armedShare = 40,
                    knock = { duration = 3 },
                },
            },
        })
        H.near(fl.objectives[1].responses.flee, 0.30, 1e-12, 'flee_arrest responses')
        H.near(fl.objectives[1].armedShare, 0.4, 1e-12, 'armedShare')
        H.eq(fl.objectives[1].knock.duration, 3000, 'knock seconds -> ms')
        local pr = B.toFileUnits({
            objectives = {
                { block = 'protect_rescue', freeTime = 6 },
                { block = 'pursuit', footFlee = 20, arrest = { duration = 3 } },
            },
        })
        H.eq(pr.objectives[1].freeTime, 6000, 'freeTime seconds -> ms')
        H.near(pr.objectives[2].footFlee, 0.2, 1e-12, 'footFlee percent -> fraction')
        H.eq(pr.objectives[2].arrest.duration, 3000, 'arrest ms')
    end

    -- ══ parity-plus: field_contact and process_scene drafts ═════════════════
    local function withScene(d)
        for _, loc in ipairs(d.locations) do
            local c = loc.start.coords
            loc.car = { x = c.x + 45.0, y = c.y + 50.0, z = 21.5, w = 180.0 }
            loc.peopleSpots = {
                { x = c.x + 48.0, y = c.y + 52.0, z = 21.5, w = 90.0 },
                { x = c.x + 50.0, y = c.y + 54.0, z = 21.5, w = 90.0 },
                { x = c.x + 52.0, y = c.y + 56.0, z = 21.5, w = 90.0 },
            }
            loc.fleeTo = { x = c.x + 120.0, y = c.y + 60.0, z = 21.5 }
            loc.scene = { x = c.x + 40.0, y = c.y + 40.0, z = 21.2 }
            loc.coroner = { x = c.x + 90.0, y = c.y + 70.0, z = 21.5, w = 0.0 }
        end
        d.objectives[3] = {
            block = 'field_contact',
            label = 'Question the loiterers',
            minSeconds = 30,
            presenceRange = 150,
            mode = 'scene',
            people = 3,
            cars = 1,
            profileSet = 'scene',
            approach = 25,
            probableCause = true,
            custody = 'cuff',
            returning = { chance = 25, max = 1 },
            escapeFails = true,
            bestPoints = 10,
            car = 'car',
            peopleSpots = 'peopleSpots',
            fleeTo = 'fleeTo',
        }
        d.objectives[4] = {
            block = 'process_scene',
            label = 'Process the scene',
            minSeconds = 5,
            presenceRange = 150,
            scene = 'scene',
            coroner = 'coroner',
            bodies = 4,
            tag = { duration = 5 },
            bag = { duration = 6 },
            release = { duration = 8 },
            aliveBonus = { id = 'all_taken_alive' },
        }
        return d
    end
    do
        local d = B.sanitize(withScene(validDef()), 'custom_dockside_raid')
        local errors, info = B.validate(d, { publish = true })
        H.eq(keysOf(errors), '', 'a draft with field_contact and process_scene passes every guardrail')
        H.eq(info.armed, 16, 'field_contact scene people count against the armed budget (13 + 3)')
        local over = U.deepcopy(d)
        over.objectives[1].waves = { 20, 18 } -- 38 + 3 people > 40, 38 alone fits
        H.ok(hasError(B.validate(over), 'builder.error.armed_budget'),
            'the armed budget includes the field_contact people')
        over.objectives[3] = nil
        over.objectives[4] = nil
        H.ok(not hasError(B.validate(over), 'builder.error.armed_budget'), 'the same waves alone fit the budget')
        -- a reward-like field on the new blocks is refused (payout stripped, points hints stripped)
        local raw = withScene(validDef())
        raw.objectives[3].payout = 500
        raw.objectives[4].aliveBonus = { id = 'all_taken_alive', points = 999 }
        raw.objectives[3].allCorrect = { id = 'all_correct', points = 99 }
        local clean, _, sinfo = B.sanitize(raw, 'custom_dockside_raid')
        H.ok(sinfo.payout, 'a payout on a field_contact objective is reported')
        H.eq(clean.objectives[3].payout, nil, 'the field_contact payout is stripped')
        B.customBonusFields(clean)
        H.eq(clean.objectives[4].aliveBonus.points, nil, 'process_scene aliveBonus points are stripped')
        H.eq(clean.objectives[4].aliveBonus.id, 'all_taken_alive', 'process_scene keeps the bonus id')
        H.eq(clean.objectives[3].allCorrect.points, nil, 'field_contact allCorrect points are stripped')
        local sk = { objectives = { { block = 'skill_check', onFail = { setback = { penalty = 'free_money' } } } } }
        B.customBonusFields(sk)
        H.eq(sk.objectives[1].onFail.setback.penalty, nil,
            'a skill_check setback penalty outside Config.Bonuses is dropped')
        -- units: process_scene seconds, parity percents, and a Lua export round trip
        local f = B.toFileUnits(d)
        H.eq(f.objectives[4].tag.duration, 5000, 'process_scene tag seconds -> ms')
        H.eq(f.objectives[4].release.duration, 8000, 'process_scene release seconds -> ms')
        H.near(f.objectives[3].returning.chance, 0.25, 1e-12, 'field_contact returning percent -> fraction')
        local back = B.fromFileUnits(f)
        local ok, why = Deq(Plain(back), Plain(d))
        H.ok(ok, 'field_contact / process_scene units round trip: ' .. tostring(why))
        local text = B.exportLua(d, { version = 1, publisher = 'x', at = os.time() })
        local parsed = B.parse(text, '@scene_export')
        H.ok(parsed ~= nil, 'the export with the new blocks parses back')
        if parsed then
            local okP, whyP = Deq(Plain(B.fromFileUnits(parsed)), Plain(d))
            H.ok(okP, 'Lua export -> parse -> builder units round trip: ' .. tostring(whyP))
        end
        local pu = B.toFileUnits({
            objectives = {
                {
                    block = 'pursuit',
                    responses = { yield = 25, flee = 65, fight = 10 },
                    driveBy = 50,
                    observe = { kinds = { pace = 60, follow = 40 } },
                },
                {
                    block = 'interact_points',
                    finds = { chance = 60 },
                    together = { soloProgress = 8 },
                    hidden = { action = { duration = 4 } },
                },
                { block = 'skill_check', onFail = { setback = { duration = 10 } } },
                { block = 'flee_arrest', feint = 20, demeanour = { compliant = 50, runner = 50 } },
                { block = 'hostile_waves', behaviour = { hold = 30, balanced = 40, push = 30 } },
            },
        })
        local o = pu.objectives
        H.near(o[1].responses.flee, 0.65, 1e-12, 'pursuit responses percent -> fraction')
        H.near(o[1].driveBy, 0.5, 1e-12, 'pursuit driveBy percent -> fraction')
        H.near(o[1].observe.kinds.follow, 0.4, 1e-12, 'pursuit observe kinds percent -> fraction')
        H.near(o[2].finds.chance, 0.6, 1e-12, 'interact_points finds percent -> fraction')
        H.eq(o[2].together.soloProgress, 8000, 'together.soloProgress seconds -> ms')
        H.eq(o[2].hidden.action.duration, 4000, 'hidden.action seconds -> ms')
        H.eq(o[3].onFail.setback.duration, 10000, 'skill_check setback seconds -> ms')
        H.near(o[4].feint, 0.2, 1e-12, 'flee_arrest feint percent -> fraction')
        H.near(o[4].demeanour.runner, 0.5, 1e-12, 'flee_arrest demeanour percent -> fraction')
        H.near(o[5].behaviour.push, 0.3, 1e-12, 'hostile_waves behaviour percent -> fraction')
    end

    -- ══ Lua export: golden text of the spec's custom example ════════════════
    do
        local z3 = { x = 0.0, y = 0.0, z = 0.0 }
        local example = {
            id = 'custom_dockside_raid',
            label = 'Dockside Raid',
            description = 'A smuggling crew is unloading at the docks. Clear the dock and seize the shipment.',
            type = 'tactical',
            departments = {},
            minOfficers = 2,
            maxOfficers = 4,
            difficulty = 3,
            timeLimit = 720,
            vehiclePenalties = false,
            startTimeout = 600,
            cooldown = 1200,
            locations = {
                {
                    label = 'Dock 1',
                    start = { coords = z3, radius = 60 },
                    spawns = { { x = 0.0, y = 0.0, z = 0.0, w = 0.0 } },
                    evidence = { z3 },
                },
            },
            objectives = {
                {
                    block = 'hostile_waves',
                    label = 'Clear the dock',
                    minSeconds = 45,
                    waves = { 6, 6 },
                    weapons = { 'WEAPON_PISTOL', 'WEAPON_SMG' },
                    accuracy = 30,
                    armour = 10,
                },
                {
                    block = 'interact_points',
                    label = 'Seize the shipment',
                    minSeconds = 6,
                    points = 'evidence',
                    progress = { label = 'Seizing crates', duration = 6 },
                },
            },
            scaling = { 'objectives.1.waves' },
            items = {},
            bonuses = { { id = 'no_participant_downed', pct = 10 } },
            penalties = {},
        }
        local at = os.time({ year = 2026, month = 9, day = 28, hour = 5, min = 40, sec = 0 })
        local text = B.exportLua(example,
            { version = 3, publisher = 'Sgt. J. Doe (SAST, citizenid ABC12345)', at = at })
        local expected = table.concat({
            '--[[ Crimson-Police · custom mission (written by the Mission Builder)',
            '  id:        custom_dockside_raid',
            '  version:   3',
            '  type:      tactical   -- the payout comes from the Payouts screens, never from this file',
            '  published: 2026-09-28 05:40 by Sgt. J. Doe (SAST, citizenid ABC12345)',
            '  Edit this file, then run: /CrimsonPoliceAdmin reload',
            ']]',
            '',
            'RegisterMission({',
            '  id           = \'custom_dockside_raid\',',
            '  label        = \'Dockside Raid\',',
            '  description  = \'A smuggling crew is unloading at the docks. Clear the dock and seize the shipment.\',',
            '  type         = \'tactical\',',
            '  departments  = {},             -- empty = every department',
            '  minOfficers  = 2,',
            '  maxOfficers  = 4,',
            '  difficulty   = 3,',
            '  timeLimit    = 720,',
            '  vehiclePenalties = false,',
            '  startTimeout = 600,',
            '  cooldown     = 1200,',
            '',
            '  locations = {',
            '    {',
            '      label    = \'Dock 1\',',
            '      start    = { coords = vec3(0.0, 0.0, 0.0), radius = 60.0 },',
            '      spawns   = { vec4(0.0, 0.0, 0.0, 0.0) },',
            '      evidence = { vec3(0.0, 0.0, 0.0) },',
            '    },',
            '  },',
            '',
            '  objectives = {',
            '    { block = \'hostile_waves\', label = \'Clear the dock\', minSeconds = 45, waves = { 6, 6 },',
            '      weapons = { \'WEAPON_PISTOL\', \'WEAPON_SMG\' }, accuracy = 30, armour = 10 },',
            '    { block = \'interact_points\', label = \'Seize the shipment\', minSeconds = 6, points = \'evidence\',',
            '      progress = { label = \'Seizing crates\', duration = 6000 } },',
            '  },',
            '',
            '  scaling   = { \'objectives.1.waves\' },',
            '  items     = {},',
            '  bonuses   = { { id = \'no_participant_downed\', pctOfPoints = 0.10 } },',
            '  penalties = {},',
            '})',
            '',
        }, '\n')
        H.eq(text, expected, 'the export is the spec example, line for line')
        if text ~= expected then
            local a, b = {}, {}
            for l in (text .. '\n'):gmatch('(.-)\n') do a[#a + 1] = l end
            for l in (expected .. '\n'):gmatch('(.-)\n') do b[#b + 1] = l end
            for i = 1, math.max(#a, #b) do
                if a[i] ~= b[i] then
                    print(('  line %d\n    got:      %s\n    expected: %s'):format(i, tostring(a[i]), tostring(b[i])))
                end
            end
        end
        local parsed = B.parse(text, 'example.lua')
        H.ok(parsed ~= nil, 'the export loads through the RegisterMission sandbox')
        local ok, why = Deq(Plain(B.fromFileUnits(parsed)), Plain(example))
        H.ok(ok, 'the export loads back to an equal definition: ' .. tostring(why))
    end

    -- the full valid definition round-trips too (many points, lists broken over lines, strings with quotes)
    do
        local d = U.deepcopy(good)
        d.description = 'It\'s a "raid"\nwith two lines and a backslash \\ and ]] inside'
        d.locations[1].label = 'O\'Neil\'s Dock'
        d.locations[1].route = {
            points = { { x = 1.5, y = 2.25, z = 3.0 }, { x = 900.0, y = 2.0, z = 3.0 } },
            stops = { { at = 1, wait = 20 } },
        }
        d.objectives[2].roll = {
            outcomes = {
                { id = 'crate', chance = 75, followUp = { label = 'Open', duration = 2.5 } },
                { id = 'empty', chance = 25 },
            },
        }
        d.penalties = { { id = 'hard_ram', points = -10 } }
        local text = B.exportLua(d, { version = 7, publisher = 'Admin ]] Name\nX', at = os.time() })
        H.ok(text:find('-- empty = every department', 1, true) ~= nil, 'departments comment')
        H.ok(text:find('chance = 0.30', 1, true) ~= nil, 'chances written with two decimals')
        H.ok(text:find('chance = 0.75', 1, true) ~= nil, 'roll chances written with two decimals')
        H.ok(text:find('duration = 2500', 1, true) ~= nil, 'follow-up duration in ms')
        H.ok(text:find('vec4(-559.0, -1505.0, 21.5, 90.0)', 1, true) ~= nil, 'vec4 literal with heading')
        H.ok(text:find('pctOfPoints = 0.10', 1, true) ~= nil, 'pctOfPoints two decimals')
        H.ok(text:find('{ id = \'hard_ram\', points = -10, each = true }', 1, true) ~= nil, 'penalty with each')
        H.ok(
            text:find('payout', 1, true) == nil
                or text:find('the payout comes from the Payouts screens', 1, true) ~= nil,
            'no payout field'
        )
        local header = text:sub(1, text:find(']]', 1, true) + 1)
        H.ok(not header:sub(1, -3):find(']]', 1, true), 'a ]] in the publisher cannot close the header early')
        for line in text:gmatch('[^\n]+') do
            if #line > 120 and not line:find('description') then
                H.ok(false, 'long line in the export: ' .. line)
                break
            end
        end
        local parsed, err = B.parse(text, 'full.lua')
        H.ok(parsed ~= nil, 'the full export loads: ' .. tostring(err))
        local ok, why = Deq(Plain(B.fromFileUnits(parsed)), Plain(d))
        H.ok(ok, 'the full export round-trips: ' .. tostring(why))
        H.eq(parsed.description, d.description, 'strings with quotes, newlines and backslashes survive')
    end
    do
        -- a character name may hold any characters: ]]] or ]]]] cannot close the header comment either
        local text = B.exportLua(good, { version = 2, publisher = 'Sergeant John ]]] Doe ]]]] (SAST)', at = os.time() })
        local parsed, err = B.parse(text, 'brackets.lua')
        H.ok(parsed ~= nil, 'a publisher with ]]] loads back: ' .. tostring(err))
        H.eq(text:find(']]', 1, true), text:find('\n]]\n', 1, true) + 1, 'the header closes on its own ]] line')
    end

    -- ══ actions: create, lock, save, versions ═══════════════════════════════
    local ok, data = act(1, 'create', { type = 'tactical', label = 'Dockside Raid' })
    H.ok(ok, 'create: ' .. tostring(data))
    local id = ok and data.id or 'custom_dockside_raid'
    H.eq(id, 'custom_dockside_raid', 'id = custom_ + slug of the label')
    H.eq(data.record.status, 'draft', 'new mission is a draft')
    H.eq(data.record.lock and data.record.lock.mine, true, 'the creator holds the lock')
    local r = row(id)
    H.eq(r.status, 'draft', 'row status draft')
    H.eq(r.draft_version, 1, 'draft version 1')
    H.eq(r.locked_by, 'SUP00001', 'locked by the creator')
    H.eq(r.created_by, 'SUP00001', 'created_by')
    H.eq(lastAudit().action, 'create', 'create audited')
    H.eq(lastAudit().category, 'builder', 'category builder')
    local ok2, data2 = act(1, 'create', { type = 'tactical', label = 'Dockside Raid' })
    H.ok(ok2 and data2.id == 'custom_dockside_raid_2', 'a second mission with the same label gets _2')
    do
        -- a race: the id looks free, but another create took it first -> INSERT IGNORE inserts nothing, next id
        local realScalar = MySQL.scalar.await
        local fooled = false
        MySQL.scalar.await = function(sql, params)
            if not fooled and sql:find('AS taken', 1, true) then fooled = true; return nil end
            return realScalar(sql, params)
        end
        local okRace, race = act(1, 'create', { type = 'tactical', label = 'Dockside Raid' })
        MySQL.scalar.await = realScalar
        H.ok(fooled and okRace and race.id == 'custom_dockside_raid_3',
            'an id clash on insert moves on to the next free id: ' .. tostring(race and race.id))
        H.eq(row('custom_dockside_raid').created_by, 'SUP00001', 'the existing mission is untouched')
        act(1, 'discardDraft', { id = 'custom_dockside_raid_3' })
        H.eq(row('custom_dockside_raid_3'), nil, 'race copy discarded')
    end
    H.eq(select(2, act(1, 'create', { type = 'traffic' })), 'err.builder_bad_type', 'unknown mission type')
    H.eq(select(2, act(4, 'create', { type = 'patrol' })), 'err.no_permission', 'officers cannot build')
    local okDef, defaultData = act(3, 'create', { type = 'patrol' })
    H.ok(okDef and defaultData.id:match('^custom_new_patrol_mission'),
        'default label -> id ' .. tostring(defaultData and defaultData.id))
    do
        -- text limits count characters (as the builder UI and the messages do) and never cut one in two: the
        -- database refuses a cut UTF-8 character
        local okU, u = act(1, 'create', { type = 'tactical', label = ('€'):rep(70) })
        H.ok(okU, 'a long label of 3-byte characters creates a mission: ' .. tostring(okU or u))
        local label = okU and u.record.definition.label or ''
        H.ok(utf8.len(label) == 64, 'clipped to 64 whole characters (' .. tostring(utf8.len(label)) .. ')')
        local d = validDef()
        d.label = ('Ж'):rep(40)
        d.description = ('字'):rep(600)
        local okD, sd = act(1, 'save', { id = okU and u.id or 'custom_mission', definition = d })
        H.ok(okD, 'a long description of 3-byte characters saves: ' .. tostring(okD or sd))
        H.ok(okD and sd.valid,
            'a 40-character label is within the 64-character limit (' .. keysOf(okD and sd.errors or {}) .. ')')
        local stored = okD and cjson.decode(row(sd.id).draft_definition) or {}
        H.eq(utf8.len(stored.description or ''), 500, 'the description is clipped to 500 whole characters')
        local long = U.deepcopy(good)
        long.label = ('Ж'):rep(65)
        H.ok(hasError(B.validate(long), 'builder.error.label'), 'a 65-character label is too long')
        if okD then act(1, 'discardDraft', { id = sd.id }) end
    end

    -- someone else's mission
    H.eq(select(2, act(2, 'lock', { id = id })), 'err.no_permission', 'builderEditAny off: no editing others')
    Config.Permissions.supervisor.builderEditAny = true
    H.eq(select(2, act(2, 'lock', { id = id })), 'err.builder_locked', 'locked by someone else')
    H.eq(select(2, act(2, 'save', { id = id, definition = validDef() })), 'err.builder_locked',
        'save refused while locked')
    Config.Permissions.supervisor.builderEditAny = false
    H.eq(select(2, act(1, 'lock', { id = 'gang_shootout' })), 'err.builder_read_only', 'built-ins are read-only')
    H.eq(select(2, act(1, 'lock', { id = 'nope_x' })), 'err.builder_unknown_mission', 'unknown mission')
    H.eq(select(2, act(1, 'lock', { id = 'x\'; DROP' })), 'err.invalid_payload', 'bad id refused')

    -- save
    local okS, saved = act(1, 'save', { id = id, definition = validDef() })
    H.ok(okS, 'save: ' .. tostring(saved))
    H.eq(saved.valid, true, 'saved draft is valid (' .. keysOf(saved.errors or {}) .. ')')
    H.eq(saved.version, 1, 'draft version stays 1')
    H.eq(lastAudit().action, 'save', 'save audited')
    local okBad, savedBad = act(1, 'save', {
        id = id,
        definition = (function() local d = validDef(); d.timeLimit = 60; return d end)(),
    })
    H.ok(okBad and savedBad.valid == false and hasError(savedBad.errors, 'builder.error.time_limit'),
        'an invalid draft is stored and reported')
    act(1, 'save', { id = id, definition = validDef() })

    -- validate (stored draft, or a definition in the payload) and unlock
    do
        local okV, v = act(1, 'validate', { id = id })
        H.ok(okV and v.valid == true and v.armed == 13 and v.requiredTier == 'heavy' and v.maxHostiles == 40,
            'validate the stored draft')
        local d = validDef()
        d.payout = 500
        d.items = { { name = 'bandage', count = 2 } }
        local okV2, v2 = act(2, 'validate', { id = id, definition = d })
        H.ok(
            okV2 and v2.valid == false and hasError(v2.errors, 'builder.error.payout_field')
                and hasError(v2.errors, 'builder.error.item_forbidden'),
            'validate a payload definition (read-only, any builder)'
        )
        H.ok((act(1, 'unlock', { id = id })), 'unlock')
        H.eq(row(id).locked_by, nil, 'unlock clears the own lock')
        local okL, lk = act(1, 'lock', { id = id })
        H.ok(okL and lk.lock and lk.lock.mine and lk.lock.name == 'John Doe', 'lock again')
        act(2, 'unlock', { id = id })
        H.eq(row(id).locked_by, 'SUP00001', 'unlock never clears someone else\'s lock')
    end

    -- autosave throttle and lock renewal
    H.sql('UPDATE cp_custom_missions SET locked_until = NOW() + INTERVAL 1 MINUTE WHERE id = ?', { id })
    local okA, auto = act(1, 'autosave', { id = id, definition = validDef() })
    H.ok(okA and auto.lock and auto.lock.secondsLeft > 25 * 60, 'autosave renews the lock for editLockMinutes')
    H.fire('crimson-police:server:builder:autosave', 1, { id = id, definition = validDef() }, 'fast')
    local fast = H.findEvents('crimson-police:client:actionResult')
    H.eq(fast[#fast].args[3], 'err.rate_limited', 'autosave at most every 5 s')

    -- rename of a never-published draft on save
    do
        local d = validDef()
        d.label = 'Harbour Sweep'
        local okR, res = act(1, 'save', { id = 'custom_dockside_raid_2', definition = d })
        H.ok(okR and res.id == 'custom_harbour_sweep' and res.previousId == 'custom_dockside_raid_2',
            'save renames an unpublished draft')
        H.eq(row('custom_dockside_raid_2'), nil, 'old id gone')
        H.ok(row('custom_harbour_sweep') ~= nil, 'new id stored')
    end

    -- lists and records
    do
        local okL, list = cb(1, 'builder:list', {})
        H.ok(okL and #list.missions >= 2, 'builder:list returns the custom missions')
        local adminDraft = false
        for _, m in ipairs(list.missions) do if m.id == defaultData.id then adminDraft = true end end
        H.ok(not adminDraft, 'the admin\'s unpublished draft is not in a supervisor\'s list')
        local e
        for _, m in ipairs(list.missions) do if m.id == id then e = m end end
        H.ok(e ~= nil, 'our mission is listed')
        H.eq(e.status, 'draft', 'list status')
        H.eq(e.owner.name, 'John Doe', 'owner name from cp_officers')
        H.eq(e.lock.mine, true, 'lock mine')
        H.eq(e.can.publish, true, 'owner may publish')
        H.eq(e.requiredTier, 'heavy', 'required tier')
        H.ok(#list.builtins > 0 and list.builtins[1].readOnly == true, 'built-ins listed read-only')
        -- SPEC Supervisor UI: "their drafts plus published missions": someone else's never-published draft is hidden
        local okL2, list2 = cb(2, 'builder:list', {})
        local seen2 = false
        for _, m in ipairs(list2.missions) do if m.id == id then seen2 = true end end
        H.ok(okL2 and not seen2, 'another supervisor\'s unpublished draft is not listed')
        H.eq(select(2, cb(2, 'builder:get', { id = id })), 'err.builder_unknown_mission',
            'builder:get hides another supervisor\'s draft')
        H.eq(select(2, act(2, 'duplicate', { id = id })), 'err.builder_unknown_mission',
            'an unseen draft cannot be duplicated')
        Config.Permissions.supervisor.builderEditAny = true
        e = nil
        local _, list3 = cb(2, 'builder:list', {})
        for _, m in ipairs(list3.missions) do if m.id == id then e = m end end
        H.ok(e ~= nil, 'builderEditAny lists other people\'s drafts')
        H.eq(e.lock.mine, false, 'lock shown to others')
        H.eq(e.lock.name, 'John Doe', 'lock holder name')
        H.ok((cb(2, 'builder:get', { id = id })), 'builderEditAny may open the draft')
        Config.Permissions.supervisor.builderEditAny = false
        local okAdm, listAdm = cb(3, 'builder:list', {})
        local seenAdm = false
        for _, m in ipairs(listAdm and listAdm.missions or {}) do if m.id == id then seenAdm = true end end
        H.ok(okAdm and seenAdm, 'admins see every draft')
        local okG, rec = cb(1, 'builder:get', { id = id })
        H.ok(okG and rec.definition.label == 'Dockside Raid' and #rec.errors == 0,
            'builder:get returns the draft with its errors')
        H.eq(rec.armed, 13, 'record armed count')
        local okB, bi = cb(1, 'builder:get', { id = 'gang_shootout' })
        if CP.Missions.get('gang_shootout') then
            H.ok(okB and bi.readOnly == true and bi.source == 'builtin', 'built-in record is read-only')
            H.ok(
                okB and bi.definition.objectives[1].surrender == nil
                    or type(bi.definition.objectives[1].surrender.chance) == 'number',
                'built-in shown in builder units'
            )
        end
        local okC, conf = cb(1, 'builder:config', {})
        H.ok(okC and conf.maxHostiles == 40 and conf.bonusCap.pct == 25 and conf.bonusCap.points == 50,
            'builder:config caps')
        H.ok(okC and #conf.noBuildZones == #Config.Builder.noBuildZones and conf.noBuildZones[1].coords.x ~= nil,
            'no-build zones as plain vectors')
        local pctB
        for _, bo in ipairs(conf.bonuses) do if bo.id == 'no_participant_downed' then pctB = bo end end
        H.ok(pctB and pctB.kind == 'pct' and pctB.value == 10, 'bonus list in whole percent')
        H.eq(conf.percentFields.hostile_waves[1], 'surrender.chance', 'percent fields listed')
        local listed = {}
        for _, b in ipairs(conf.blockList or {}) do listed[b.id] = b end
        H.ok(listed.field_contact and listed.field_contact.available and listed.field_contact.minSeconds == 30,
            'builder:config lists field_contact (min 30 s)')
        H.ok(listed.process_scene and listed.process_scene.available and listed.process_scene.minSeconds == 5,
            'builder:config lists process_scene (min 5 s)')
        H.ok(
            listed.field_contact and listed.field_contact.presenceRange and listed.field_contact.presenceRange[1] == 50
                and listed.field_contact.presenceRange[2] == 800,
            'field_contact presence range 50-800'
        )
        H.ok(conf.blocks.field_contact.people[1] == 1 and conf.blocks.field_contact.people[2] == 4,
            'field_contact people range 1-4')
        H.ok(conf.blocks.process_scene.bodies[1] == 0 and conf.blocks.process_scene.bodies[2] == 8,
            'process_scene bodies range 0-8')
        H.eq(conf.secondsFields.process_scene[1], 'tag.duration', 'process_scene seconds fields listed')
        H.eq(select(2, cb(4, 'builder:list', {})), 'err.no_permission', 'officers get no list')
    end

    -- ══ test runs and publish ═══════════════════════════════════════════════
    H.eq(select(2, act(1, 'publish', { id = id })), 'err.builder_not_tested', 'publish needs a passed test')
    inArena[1] = true
    H.eq(select(2, act(1, 'test', { id = id })), 'err.in_arena', 'no test runs from the arena')
    inArena[1] = nil
    H.eq(select(2, act(1, 'test', { id = id, tier = 'mega' })), 'err.builder_bad_tier', 'unknown tier')
    H.eq(select(2, act(1, 'test', { id = id, location = 9 })), 'err.builder_bad_location', 'unknown location')
    local okT, tdata = act(1, 'test', { id = id, location = 2 })
    H.ok(okT and tdata.tier == 'heavy' and tdata.requiredTier == 'heavy',
        'test at the required tier by default: ' .. tostring(tdata))
    H.eq(tdata.location, 2, 'the test reply names its location')
    do
        local okR, rdata = act(1, 'test', { id = id, location = 'random' })
        H.ok(okR and rdata.location == 3,
            'a random location test replies with the location CP.Testing picked (the tester records it)')
        H.eq(drafts[#drafts].opts.location, 'random', 'CP.Testing still gets random')
        act(1, 'test', { id = id, location = 2 })
    end
    local started = drafts[#drafts]
    H.ok(
        started and started.opts.tier == 'heavy' and started.opts.location == 2 and started.opts.useStartRoute == false,
        'CP.Testing.startDraft options')
    H.ok(started and started.def.id == id and started.def.source == 'custom',
        'the draft is normalised for the test run')
    H.near(started and started.def.objectives[1].surrender.chance or 0, 0.30, 1e-9, 'test run gets file units')
    H.eq(started and started.def.objectives[2].progress.duration, 6000, 'test run gets milliseconds')
    H.eq(lastAudit().action, 'test', 'test start audited')
    H.eq(B.onDraftTested(id, 1, 'standard', true, 1), false, 'a pass at a lower tier does not count')
    H.eq(notes[#notes].key, 'builder.test_wrong_tier', 'tester told why')
    H.eq(B.onDraftTested(id, 1, 'heavy', false, 1), false, 'a failed test does not count')
    H.eq(lastAudit().action, 'testFailed', 'failed test audited')
    H.eq(B.onDraftTested(id, 2, 'heavy', true, 1), false, 'an outdated version does not count')
    H.eq(B.onDraftTested(id, 1, 'heavy', true, 1), true, 'a pass at the required tier marks the draft tested')
    H.eq(U.truthy(row(id).draft_tested), true, 'draft_tested = 1')
    -- a changed draft resets the flag
    do
        local d = validDef()
        d.objectives[1].accuracy = 31
        act(1, 'save', { id = id, definition = d })
        H.eq(U.truthy(row(id).draft_tested), false, 'a stored change resets draft_tested')
        act(1, 'save', { id = id, definition = validDef() })
        act(1, 'test', { id = id })
        local d2 = validDef()
        d2.objectives[1].accuracy = 32
        act(1, 'autosave', { id = id, definition = d2 })
        H.eq(B.onDraftTested(id, 1, 'heavy', true, 1), false, 'a draft changed during the test does not count')
        act(1, 'save', { id = id, definition = validDef() })
        act(1, 'test', { id = id })
        H.eq(B.onDraftTested(id, 1, 'critical', true, 1), true, 'a pass at a higher tier counts')
    end
    -- a test run keeps the item rules: a saved draft with bad items never reaches CP.Testing
    do
        local before = #drafts
        for _, items in ipairs({
            { { name = 'radio', count = 1000000000 } },
            { { name = 'money', count = 50 } },
            { { name = 'black_money', count = 1 } },
            { { name = 'weapon_pistol', count = 1 } },
        }) do
            local d = validDef()
            d.items = items
            act(1, 'save', { id = id, definition = d })
            H.eq(select(2, act(1, 'test', { id = id })), 'err.builder_invalid',
                'a test run refuses the item ' .. items[1].name .. ' x' .. items[1].count)
        end
        local d = validDef()
        d.items = {}
        for i = 1, 11 do d.items[i] = { name = 'radio', count = 1 } end
        act(1, 'save', { id = id, definition = d })
        H.eq(select(2, act(1, 'test', { id = id })), 'err.builder_invalid', 'a test run refuses more than 10 items')
        H.eq(#drafts, before, 'no test run started with bad items')
        act(1, 'save', { id = id, definition = validDef() })
        act(1, 'test', { id = id })
        H.eq(#drafts, before + 1, 'the fixed draft tests again')
        H.eq(B.onDraftTested(id, 1, 'critical', true, 1), true, 'and passes again')
    end

    Config.Permissions.supervisor.builderPublish = false
    H.eq(select(2, act(1, 'publish', { id = id })), 'err.no_permission', 'builderPublish off')
    Config.Permissions.supervisor.builderPublish = true
    local okP, pub = act(1, 'publish', { id = id })
    H.ok(okP, 'publish: ' .. tostring(pub))
    H.eq(pub.version, 1, 'published version 1')
    H.eq(pub.filePath, TMP .. id .. '.lua', 'file path')
    H.eq(pub.backup, nil, 'no backup for v1')
    r = row(id)
    H.eq(r.status, 'published', 'status published')
    H.eq(r.published_version, 1, 'published_version')
    H.eq(r.draft_version, nil, 'draft consumed')
    H.eq(r.draft_definition, nil, 'draft cleared')
    H.eq(r.locked_by, nil, 'lock released')
    local text1 = ReadRel(TMP .. id .. '.lua')
    H.ok(
        text1 and text1:find('  version:   1', 1, true)
            and text1:find('published: .- by Sergeant John Doe %(SAST, citizenid SUP00001%)'),
        'header names version and publisher'
    )
    H.ok(text1 and text1:find('Edit this file, then run: /CrimsonPoliceAdmin reload', 1, true),
        'header tells developers how to reload')
    local pubDef = cjson.decode(r.published_definition)
    H.eq(pubDef._file.hash, U.hashHex(text1), 'published_definition keeps the file hash')
    H.eq(pubDef.label, 'Dockside Raid', 'published_definition is the builder copy')
    local m = CP.Missions.get(id)
    H.ok(m and m.source == 'custom' and m.version == 1 and m.status == 'published',
        'registered in CP.Missions without a restart')
    H.ok(m and m.defHash == U.hashHex(text1), 'defHash is the file hash')
    local inPool = false
    for _, d in ipairs(CP.Missions.byType('tactical')) do if d.id == id then inPool = true end end
    H.ok(inPool, 'the published mission joins its type pool')
    do
        local okL, l = cb(2, 'builder:list', {})
        local e
        for _, m in ipairs(okL and l.missions or {}) do if m.id == id then e = m end end
        H.ok(e ~= nil and e.can.edit == false, 'a published mission is listed for other supervisors (read-only)')
        H.ok((cb(2, 'builder:get', { id = id })), 'and can be opened by them')
    end
    H.eq(lastAudit().action, 'publish', 'publish audited')
    local pushed = false
    for _, p in ipairs(pushes) do
        if p.topic == 'builder' and p.data.event == 'published' and p.data.id == id then pushed = true end
    end
    H.ok(pushed, 'builder push to viewers')

    -- edit the published mission: draft v2 while v1 stays live
    do
        local d = validDef()
        d.objectives[1].accuracy = 35
        local okE, e = act(1, 'save', { id = id, definition = d })
        H.ok(okE and e.version == 2, 'editing a published mission works on draft v2')
        H.eq(CP.Missions.get(id).objectives[1].accuracy, 30, 'v1 stays live')
        H.eq(select(2, act(1, 'publish', { id = id })), 'err.builder_not_tested', 'v2 needs its own test')
        act(1, 'test', { id = id })
        H.eq(B.onDraftTested(id, 2, 'heavy', true, 1), true, 'v2 tested')
        local okP2, pub2 = act(1, 'publish', { id = id })
        H.ok(okP2 and pub2.version == 2 and pub2.backup == TMP .. id .. '.v1.lua.bak', 'v2 published, v1 kept as .bak')
        H.eq(ReadRel(TMP .. id .. '.v1.lua.bak'), text1, 'the .bak is the previous file')
        H.eq(CP.Missions.get(id).objectives[1].accuracy, 35, 'v2 live')
        H.eq(CP.Missions.get(id).version, 2, 'version 2 registered')
    end

    -- rollback (admin; supervisors only with builderRollback)
    H.eq(select(2, act(1, 'rollback', { id = id })), 'err.no_permission', 'builderRollback off for supervisors')
    do
        local okRb, rb = act(3, 'rollback', { id = id })
        H.ok(okRb and rb.version == 3 and rb.fromVersion == 1, 'rollback restores v1 as v3: ' .. tostring(rb))
        H.eq(CP.Missions.get(id).objectives[1].accuracy, 30, 'v1 content live again')
        H.ok(FileExists(TMP .. id .. '.v2.lua.bak'), 'v2 kept as .bak')
        r = row(id)
        H.eq(r.published_version, 3, 'published_version 3')
        H.eq(r.updated_by, 'ADM00001', 'updated_by the admin')
        H.eq(lastAudit().action, 'rollback', 'rollback audited')
        H.eq(lastAudit().role, 'admin', 'admin role')
        local t3 = ReadRel(TMP .. id .. '.lua')
        H.ok(t3:find('published: .- by Freelancer Ada Admin %(admin, citizenid ADM00001%)'),
            'rollback header names the admin')
    end

    -- lock breaking
    do
        act(1, 'lock', { id = id })
        H.eq(select(2, act(2, 'breakLock', { id = id })), 'err.no_permission', 'breakEditLock off for supervisors')
        H.reset()
        local okBr, br = act(3, 'breakLock', { id = id })
        H.ok(okBr and br.previous and br.previous.citizenid == 'SUP00001', 'admin breaks the lock')
        H.eq(row(id).locked_by, nil, 'lock cleared')
        local told = H.findEvents('crimson-police:client:builder')
        H.ok(#told == 1 and told[1].target == 1 and told[1].args[1].event == 'lockBroken', 'the editor client is told')
        H.eq(notes[#notes].key, 'builder.lock_broken', 'the editor gets a toast')
        H.eq(told[1].args[1].by, 'Ada Admin', 'the editor client is told who broke the lock')
        H.eq(lastAudit().action, 'breakLock', 'lock break audited')
        -- the old editor's autosave does not silently take the free lock back (it would overwrite the breaker's work)
        H.clockMs = H.clockMs + 16 * 60 * 1000   -- src 1 last opened the builder long ago (no longer a viewer by list/get)
        local d = validDef()
        d.objectives[1].accuracy = 44
        H.eq(select(2, act(1, 'autosave', { id = id, definition = d })), 'err.builder_locked',
            'after a break the old editor cannot autosave')
        H.eq(select(2, act(1, 'save', { id = id, definition = d })), 'err.builder_locked', 'nor save')
        H.eq(row(id).locked_by, nil, 'the broken lock stays free')
        H.ok(not tostring(row(id).draft_definition):find('"accuracy":44', 1, true),
            'the old editor did not overwrite the draft')
        -- their autosaves keep them a viewer, so the next lock break reaches their screen
        local pushAt = #pushes
        act(3, 'lock', { id = id })
        act(3, 'breakLock', { id = id })
        local reached = false
        for i = pushAt + 1, #pushes do
            if pushes[i].src == 1 and pushes[i].topic == 'builder' and pushes[i].data.event == 'lockBroken' then
                reached = true
            end
        end
        H.ok(reached, 'an editor who only autosaves still gets builder pushes')
        -- an explicit lock takes the mission back
        H.ok((act(1, 'lock', { id = id })), 'the old editor may take the lock back explicitly')
        H.ok((act(1, 'autosave', { id = id, definition = validDef() })), 'and autosave again')
        H.ok((act(1, 'discardDraft', { id = id })), 'the test draft is discarded again')
        H.eq(row(id).locked_by, nil, 'discarding releases the lock')
        -- expired locks can be taken
        act(1, 'lock', { id = id })
        H.sql('UPDATE cp_custom_missions SET locked_until = NOW() - INTERVAL 1 MINUTE WHERE id = ?', { id })
        Config.Permissions.supervisor.builderEditAny = true
        H.ok((act(2, 'lock', { id = id })), 'an expired lock can be taken by another editor')
        H.eq(row(id).locked_by, 'SUP00002', 'new lock holder')
        Config.Permissions.supervisor.builderEditAny = false
        -- a dropped player releases their locks
        H.fire('playerDropped', 2)
        H.step(10)
        H.eq(row(id).locked_by, nil, 'locks released when the holder drops')
        act(1, 'lock', { id = id })
        CP.Qbx._unload(1)
        H.step(10)
        H.eq(row(id).locked_by, nil, 'locks released on character unload')
    end

    -- archive and restore
    do
        H.eq(select(2, act(1, 'restore', { id = id })), 'err.builder_not_archived', 'restore needs an archived mission')
        -- a tested draft is left over when the mission is archived
        local leftover = validDef()
        leftover.objectives[1].accuracy = 38
        act(1, 'save', { id = id, definition = leftover })
        local okLt, lt = act(1, 'test', { id = id })
        H.ok(okLt and B.onDraftTested(id, lt.version, lt.tier, true, 1, drafts[#drafts].def.defHash),
            'the leftover draft passed its test')
        os.execute(('rm -rf \'%s%sarchived\''):format(H.root, TMP)) -- archived/ went missing after start
        local okAr, ar = act(1, 'archive', { id = id })
        H.ok(okAr and ar.filePath == TMP .. 'archived/' .. id .. '.lua', 'archive moves the file')
        H.ok(FileExists(TMP .. 'archived/' .. id .. '.lua') and not FileExists(TMP .. id .. '.lua'),
            'file in archived/ only')
        H.eq(CP.Missions.get(id), nil, 'unregistered from its pool')
        H.eq(row(id).status, 'archived', 'status archived')
        H.eq(select(2, act(1, 'archive', { id = id })), 'err.builder_not_published', 'archive twice refused')
        H.eq(select(2, act(1, 'lock', { id = id })), 'err.builder_read_only', 'archived missions are not edited')
        -- publishing that draft would restore the mission without builderArchive
        Config.Permissions.supervisor.builderArchive = false
        H.eq(select(2, act(1, 'restore', { id = id })), 'err.no_permission', 'restore needs builderArchive')
        local okLs, ls = cb(1, 'builder:list', {})
        local entry
        for _, e in ipairs(okLs and ls.missions or {}) do if e.id == id then entry = e end end
        H.ok(entry and entry.hasDraft and entry.can.publish == false, 'an archived mission offers no publish')
        H.eq(select(2, act(1, 'publish', { id = id })), 'err.builder_read_only',
            'the leftover draft of an archived mission is not published')
        H.eq(row(id).status, 'archived', 'the mission stays archived')
        H.eq(CP.Missions.get(id), nil, 'and out of its pool')
        Config.Permissions.supervisor.builderArchive = true
        local okRs, rs = act(1, 'restore', { id = id })
        H.ok(okRs and rs.filePath == TMP .. id .. '.lua' and FileExists(TMP .. id .. '.lua'), 'restore moves it back')
        H.ok(not FileExists(TMP .. 'archived/' .. id .. '.lua'), 'archived copy removed')
        H.ok(CP.Missions.get(id) and CP.Missions.get(id).version == 3, 'restored mission registered again')
        H.eq(lastAudit().action, 'restore', 'restore audited')
        H.ok((act(1, 'discardDraft', { id = id })), 'the leftover draft is discarded')
    end

    -- discard
    do
        H.eq(select(2, act(1, 'discardDraft', { id = id })), 'err.builder_no_draft', 'nothing to discard')
        local d = validDef()
        d.label = 'Dockside Raid'
        d.objectives[1].accuracy = 40
        act(1, 'save', { id = id, definition = d })
        local okD, dd = act(1, 'discardDraft', { id = id })
        H.ok(okD and dd.deleted == false, 'discarding the draft of a published mission keeps the mission')
        r = row(id)
        H.eq(r.draft_definition, nil, 'draft gone')
        H.eq(r.published_version, 3, 'published version kept')
        local okD2, dd2 = act(1, 'discardDraft', { id = 'custom_harbour_sweep' })
        H.ok(okD2 and dd2.deleted == true and row('custom_harbour_sweep') == nil, 'a never-published draft is deleted')
    end

    -- duplicate
    do
        local okDu, du = act(1, 'duplicate', { id = id })
        H.ok(okDu and du.id == 'custom_dockside_raid_copy' and du.record.definition.label == 'Dockside Raid (copy)',
            'duplicate a custom mission')
        H.eq(row(du.id).created_by, 'SUP00001', 'the copy belongs to the duplicator')
        if CP.Missions.get('gang_shootout') then
            local okDb, db = act(2, 'duplicate', { id = 'gang_shootout' })
            H.ok(okDb and db.record.source == 'custom' and db.record.definition.type == 'tactical',
                'duplicate a built-in')
            local copy = db.record.definition
            for _, e in ipairs(copy.bonuses) do
                H.ok(Config.Bonuses[e.id] ~= nil, 'copy keeps standard bonuses only: ' .. e.id)
            end
            -- objective-level bonus ids and values of built-ins are dropped from the copy (block defaults apply)
            for _, m in ipairs({
                'warrant_service',
                'prison_break',
                'bomb_disposal',
                'pursuit_sim',
                'weekly_boss_kingpin',
            }) do
                if CP.Missions.get(m) then
                    local okM, dm = act(2, 'duplicate', { id = m })
                    H.ok(okM, 'duplicate ' .. m)
                    for i, o in ipairs(okM and dm.record.definition.objectives or {}) do
                        local tag = m .. ' objective ' .. i
                        if type(o.aliveBonus) == 'table' then
                            H.eq(o.aliveBonus.points, nil, tag .. ': no aliveBonus.points in the copy')
                            H.ok(Config.Bonuses[o.aliveBonus.id] ~= nil, tag .. ': aliveBonus id is standard')
                        end
                        if type(o.boss) == 'table' and type(o.boss.aliveBonus) == 'table' then
                            H.eq(o.boss.aliveBonus.points, nil, tag .. ': no boss bonus points in the copy')
                        end
                        if o.fastBonus ~= nil then
                            H.ok(Config.Bonuses[o.fastBonus.id] ~= nil, tag .. ': fast bonus id is standard')
                        end
                        if type(o.ramPenaltyId) == 'string' then
                            H.ok(Config.Bonuses[o.ramPenaltyId] ~= nil, tag .. ': ram id is standard')
                        end
                    end
                end
            end
            H.ok(type(copy.objectives[1].surrender) ~= 'table' or copy.objectives[1].surrender.chance >= 1,
                'copy in builder units (percent)')
            -- a Builder duplicate of every parity-plus mission (and the retrofits) passes every guardrail
            for _, m in ipairs({
                'parking_patrol',
                'traffic_enforcement',
                'suspicious_activity',
                'drug_lab_raid',
                'gang_hideout_raid',
                'stolen_vehicle_takedown',
                'warrant_service',
                'gang_shootout',
            }) do
                local okM, dm = act(2, 'duplicate', { id = m })
                H.ok(okM, 'duplicate ' .. m .. ': ' .. tostring(okM or dm))
                if okM then
                    local d = B.sanitize(dm.record.definition, dm.id)
                    local errors = B.validate(d, { publish = true })
                    H.eq(keysOf(errors), '', 'the duplicate of ' .. m .. ' passes every guardrail')
                end
            end
        end
    end

    -- ══ reload: hand edits, conflicts, rejects, missing files ═══════════════
    local path = TMP .. id .. '.lua'
    do
        local summary = B.onReload()
        H.eq(#summary.edited, 0, 'nothing edited yet')
        H.ok(summary.unchanged >= 1, 'unchanged files counted')
        -- a developer edits the file: new label, accuracy and a payout line
        local text = ReadRel(path)
        local edited = text:gsub('label        = \'Dockside Raid\'', 'label        = \'Dockside Raid (code)\'', 1)
            :gsub('accuracy = 30', 'accuracy = 28, payout = 777', 1)
            :gsub('  type         = \'tactical\',', '  type         = \'tactical\',\n  payout       = 99999,', 1)
        WriteRel(path, edited)
        local s = B.onReload()
        H.eq(#s.edited, 1, 'the hand edit is accepted')
        H.eq(s.edited[1] and s.edited[1].version, 4, 'saved as version 4')
        r = row(id)
        H.eq(r.published_version, 4, 'published_version 4')
        H.eq(U.truthy(r.edited_in_code), true, 'marked edited in code')
        local stored = cjson.decode(r.published_definition)
        H.eq(stored.label, 'Dockside Raid (code)', 'published copy follows the file')
        H.eq(stored.payout, nil, 'the payout field is ignored')
        H.eq(stored.objectives[1].payout, nil, 'a payout field inside an objective is ignored too')
        H.eq(stored.objectives[1].accuracy, 28, 'edited value stored')
        local now = ReadRel(path)
        H.ok(now:find('  version:   4', 1, true) and now:find('  edited:    ', 1, true),
            'header version updated and marked edited')
        H.ok(now:find('payout       = 99999', 1, true) ~= nil, 'the developer file itself is kept')
        H.eq(stored._file.hash, U.hashHex(now), 'new file hash stored')
        H.ok(FileExists(TMP .. id .. '.v3.lua.bak'), 'previous version kept as .bak')
        H.eq(lastAudit().action, 'codeEdit', 'code edit audited')
        H.eq(#B.onReload().edited, 0, 'a second reload changes nothing')
        local defs = B.loadPublished()
        local found
        for _, d in ipairs(defs) do if d.id == id then found = d end end
        H.ok(found and found.editedInCode == true and found.version == 4 and found.payout == nil,
            'loadPublished serves the edited file')
        H.eq(found and found.objectives[1].payout, nil, 'without the nested payout field')
        H.ok(found and found.filePath == path and found.defHash == U.hashHex(now) and found.source == 'custom',
            'loader fields')
    end
    do
        -- conflict: the builder draft AND the file changed since the last publish
        local d = validDef()
        d.label = 'Dockside Raid (code)'
        d.objectives[1].accuracy = 44
        act(1, 'save', { id = id, definition = d })
        WriteRel(path, ReadRel(path):gsub('armour = 10', 'armour = 12', 1))
        H.reset()
        local s = B.onReload()
        H.eq(#s.conflicts, 1, 'conflict detected')
        H.eq(#s.edited, 1, 'the file wins')
        H.ok(FileExists(TMP .. id .. '.draft.lua.bak'), 'draft saved as <id>.draft.lua.bak')
        local bak = B.parse(ReadRel(TMP .. id .. '.draft.lua.bak'), 'draft.bak')
        H.ok(bak and bak.objectives[1].accuracy == 44, 'the .draft.lua.bak holds the draft')
        r = row(id)
        H.eq(r.draft_definition, nil, 'draft cleared')
        H.eq(r.published_version, 5, 'file saved as version 5')
        H.eq(cjson.decode(r.published_definition).objectives[1].armour, 12, 'file content published')
        local conflictAudit = false
        for _, a in ipairs(audits) do
            if a.action == 'codeEditConflict' and a.target == id then conflictAudit = true end
        end
        H.ok(conflictAudit, 'conflict audited')
        local told = H.findEvents('crimson-police:client:builder')
        H.ok(#told == 1 and told[1].args[1].event == 'reloaded', 'the editor is told the draft was replaced')
    end
    do
        -- an edit that breaks the guardrails is not used; the published version stays live
        local before = ReadRel(path)
        WriteRel(path, before:gsub('\'WEAPON_SMG\'', '\'WEAPON_RPG\'', 1))
        local s = B.onReload()
        H.eq(#s.rejected, 1, 'guardrail-breaking edit rejected')
        H.eq(row(id).published_version, 5, 'version unchanged')
        local defs = B.loadPublished()
        local found
        for _, d in ipairs(defs) do if d.id == id then found = d end end
        H.ok(found and found.objectives[1].weapons[2] == 'WEAPON_SMG', 'the last published version stays live')
        WriteRel(path, 'RegisterMission({ id = ')
        H.eq(#B.onReload().rejected, 1, 'a file that does not load is rejected')
        WriteRel(path, before)
        H.eq(#B.onReload().edited, 0, 'restoring the file makes it current again')
    end
    do
        -- a missing file is rewritten from the database
        os.remove(H.root .. path)
        local defs = B.loadPublished()
        H.ok(FileExists(path), 'missing file rewritten')
        local found
        for _, d in ipairs(defs) do if d.id == id then found = d end end
        H.ok(found and found.version == 5, 'rewritten mission loads')
        local re = B.parse(ReadRel(path), path)
        H.ok(re and re.id == id and re.objectives[1].armour == 12, 'rewritten from published_definition')
        H.eq(cjson.decode(row(id).published_definition)._file.hash, U.hashHex(ReadRel(path)),
            'hash of the rewritten file stored')
    end
    do
        -- a row without a hash baseline takes the file on disk as its baseline
        local r0 = row(id)
        local stored = cjson.decode(r0.published_definition)
        stored._file = nil
        H.sql('UPDATE cp_custom_missions SET published_definition = ? WHERE id = ?', { cjson.encode(stored), id })
        local s = B.onReload()
        H.eq(#s.edited, 0, 'no baseline: nothing counted as edited')
        H.eq(cjson.decode(row(id).published_definition)._file.hash, U.hashHex(ReadRel(path)), 'baseline stored')
    end

    -- the missions registry uses loadPublished on a full reload
    do
        local summary = CP.Missions.reload()
        H.ok(summary.custom >= 1 and CP.Missions.get(id) ~= nil,
            'CP.Missions.reload loads the custom mission from its file')
        H.ok(summary.builder and summary.builder.checked >= 1, 'reload summary carries the builder summary')
    end
    do
        -- the file itself goes live, not the rounded builder copy: an edit the loader refuses is not accepted
        local before = ReadRel(path)
        local edited, n = before:gsub('duration = 6000', 'duration = 30000.4', 1)
        H.eq(n, 1, 'the file has the progress duration to edit')
        WriteRel(path, edited)
        local summary = CP.Missions.reload()
        local s = summary.builder or {}
        H.ok(#(s.edited or {}) == 0 and #(s.rejected or {}) == 1,
            'an edit that rounds into range but does not load as written is rejected')
        H.eq(row(id).published_version, 5, 'no new version for it')
        H.ok(CP.Missions.get(id) and CP.Missions.get(id).version == 5, 'the last published version stays live')
        WriteRel(path, before)
        H.eq(#B.onReload().edited, 0, 'restoring the file makes it current again')
    end

    -- ══ a test result only counts for the draft content that ran ═══════════
    do
        local function labelled(label)
            local d = validDef()
            d.label = label
            return d
        end
        local function lastHash() return drafts[#drafts].def.defHash end
        -- an id freed by a rename and taken again by a new mission: its test results stay with it
        local okA, a = act(1, 'create', { type = 'tactical', label = 'Pier Watch' })
        H.eq(okA and a.id, 'custom_pier_watch', 'a draft to rename')
        local okRn, rn = act(1, 'save', { id = 'custom_pier_watch', definition = labelled('Quay Patrol') })
        H.eq(okRn and rn.id, 'custom_quay_patrol', 'renamed on save')
        local okB, b = act(1, 'create', { type = 'tactical', label = 'Pier Watch' })
        H.eq(okB and b.id, 'custom_pier_watch', 'the freed id is taken by a new mission')
        act(1, 'save', { id = 'custom_pier_watch', definition = labelled('Pier Watch') })
        local okT, t = act(1, 'test', { id = 'custom_pier_watch' })
        H.eq(okT and B.onDraftTested('custom_pier_watch', t.version, t.tier, true, 1, lastHash()), true,
            'the new mission\'s pass counts')
        H.eq(U.truthy(row('custom_pier_watch').draft_tested), true, 'the mission that ran is marked tested')
        H.eq(U.truthy(row('custom_quay_patrol').draft_tested), false, 'the renamed mission is not')
        H.eq(select(2, act(1, 'publish', { id = 'custom_quay_patrol' })), 'err.builder_not_tested',
            'the renamed mission cannot be published untested')
        -- renamed away and back: its tests still count
        act(1, 'create', { type = 'tactical', label = 'Alpha Run' })
        act(1, 'save', { id = 'custom_alpha_run', definition = labelled('Bravo Run') })
        local okBack, back = act(1, 'save', { id = 'custom_bravo_run', definition = labelled('Alpha Run') })
        H.eq(okBack and back.id, 'custom_alpha_run', 'renamed back')
        local okT2, t2 = act(1, 'test', { id = 'custom_alpha_run' })
        H.eq(okT2 and B.onDraftTested('custom_alpha_run', t2.version, t2.tier, true, 1, lastHash()), true,
            'a draft renamed back to its old id records its pass')
        H.eq(U.truthy(row('custom_alpha_run').draft_tested), true, 'and is marked tested')

        -- an older test's pass does not count for content saved after it
        local okC, c = act(1, 'create', { type = 'tactical', label = 'Canal Sweep' })
        local cid = okC and c.id or 'custom_canal_sweep'
        act(1, 'save', { id = cid, definition = labelled('Canal Sweep') })
        act(1, 'test', { id = cid, location = 1 })
        local hashA = lastHash()
        local changed = labelled('Canal Sweep')
        changed.objectives[1].accuracy = 33
        act(1, 'save', { id = cid, definition = changed })
        act(1, 'test', { id = cid, location = 2 })
        local hashB = lastHash()
        H.eq(B.onDraftTested(cid, 1, 'heavy', false, 1, hashB), false, 'the test of the current content failed')
        H.eq(B.onDraftTested(cid, 1, 'heavy', true, 1, hashA), false,
            'the pass of a test that ran older content does not count')
        H.eq(notes[#notes].key, 'builder.test_outdated', 'the tester is told the test is outdated')
        H.eq(U.truthy(row(cid).draft_tested), false, 'the current content stays untested')
        H.eq(select(2, act(1, 'publish', { id = cid })), 'err.builder_not_tested', 'and cannot be published')
        H.eq(B.onDraftTested(cid, 1, 'heavy', true, 1, hashB), true, 'the pass of the current content counts')
        H.ok((act(1, 'publish', { id = cid })), 'published as v1')

        -- a discarded draft's test does not count for the next draft of the same version number
        local v2 = labelled('Canal Sweep')
        v2.objectives[1].accuracy = 34
        act(1, 'save', { id = cid, definition = v2 })
        act(1, 'test', { id = cid })
        local hashOld = lastHash()
        act(1, 'discardDraft', { id = cid })
        local v2b = labelled('Canal Sweep')
        v2b.objectives[1].accuracy = 36
        local okV2, saved2 = act(1, 'save', { id = cid, definition = v2b })
        H.eq(okV2 and saved2.version, 2, 'the new draft is version 2 again')
        H.eq(B.onDraftTested(cid, 2, 'heavy', true, 1, hashOld), false,
            'the discarded draft\'s pass does not count for the new draft')
        H.eq(B.onDraftTested(cid, 2, 'heavy', true, 1), false, 'nor a pass without a started test of this content')
        H.eq(U.truthy(row(cid).draft_tested), false, 'the new draft stays untested')

        -- a save while the result is recorded (the audit yields) is not marked tested
        act(1, 'test', { id = cid })
        local hashNow = lastHash()
        local realAudit = CP.Admin.audit
        CP.Admin.audit = function(...)
            CP.Admin.audit = realAudit
            realAudit(...)
            local during = labelled('Canal Sweep')
            during.objectives[1].accuracy = 37
            act(1, 'autosave', { id = cid, definition = during })
        end
        H.eq(B.onDraftTested(cid, 2, 'heavy', true, 1, hashNow), false,
            'content saved while the pass was recorded does not count')
        CP.Admin.audit = realAudit
        H.eq(U.truthy(row(cid).draft_tested), false, 'the content saved meanwhile stays untested')
        H.ok(tostring(row(cid).draft_definition):find('"accuracy":37', 1, true) ~= nil, 'that save was stored')
    end

    -- ══ testing is optional (requireTestToPublish = false, as shipped) ══════════
    do
        local function labelled(label)
            local d = validDef()
            d.label = label
            return d
        end
        Config.Builder.requireTestToPublish = false
        local okC, c = act(1, 'create', { type = 'tactical', label = 'Harbour Sweep' })
        local hid = okC and c.id or 'custom_harbour_sweep'
        act(1, 'save', { id = hid, definition = labelled('Harbour Sweep') })
        local okCfg, conf = cb(1, 'builder:config', {})
        H.ok(okCfg and conf.requireTestToPublish == false, 'the builder is told testing is optional')
        local okL, list = cb(1, 'builder:list', {})
        local entry = nil
        for _, e in ipairs(okL and list.missions or {}) do if e.id == hid then entry = e end end
        H.ok(entry and entry.can.publish == true and entry.draftTested == false and entry.needsTest == false,
            'an untested draft can be published')
        local okP, pub = act(1, 'publish', { id = hid })
        H.ok(okP and pub.version == 1, 'a supervisor publishes without a test')
        H.eq(lastAudit().action, 'publishUntested', 'audited as published without a test')
        H.ok(CP.Missions.get(hid) ~= nil, 'and it is in its pool at once')

        -- the owner switches the gate on: supervisors need a test, admins never do
        Config.Builder.requireTestToPublish = true
        local okC2, c2 = act(1, 'create', { type = 'tactical', label = 'Harbour Sweep Two' })
        local sid = okC2 and c2.id or 'custom_harbour_sweep_two'
        act(1, 'save', { id = sid, definition = labelled('Harbour Sweep Two') })
        H.eq(select(2, act(1, 'publish', { id = sid })), 'err.builder_not_tested', 'the gate holds for supervisors')
        local okL2, list2 = cb(1, 'builder:list', {})
        local entry2 = nil
        for _, e in ipairs(okL2 and list2.missions or {}) do if e.id == sid then entry2 = e end end
        H.ok(entry2 and entry2.needsTest == true, 'and the list says the draft waits for a test')
        local okCfgS, confS = cb(1, 'builder:config', {})
        H.ok(okCfgS and confS.requireTestToPublish == true, 'and the supervisor\'s builder says so')
        local okC3, c3 = act(3, 'create', { type = 'tactical', label = 'Harbour Sweep Three' })
        local aid = okC3 and c3.id or 'custom_harbour_sweep_three'
        act(3, 'save', { id = aid, definition = labelled('Harbour Sweep Three') })
        local okCfgA, confA = cb(3, 'builder:config', {})
        H.ok(okCfgA and confA.requireTestToPublish == false, 'an admin\'s builder never asks for a test')
        local okPA = act(3, 'publish', { id = aid })
        H.ok(okPA, 'an admin publishes an untested draft with the gate on')
        Config.Builder.requireTestToPublish = false
    end

    -- the builder switch
    Config.Builder.enabled = false
    H.eq(select(2, act(1, 'save', { id = id, definition = validDef() })), 'err.builder_disabled',
        'Config.Builder.enabled = false')
    Config.Builder.enabled = true
end

local okBody, errBody = pcall(Body)
os.execute(('rm -rf %s%s'):format(H.root, TMP))
H.ok(okBody, 'spec body ran: ' .. tostring(errBody))
H.ok(not FileExists(TMP), 'temporary mission folder removed')

-- Under tests/run.lua (CP_TEST_DB set) the per-run database is dropped; a direct run keeps it for inspection.
if os.getenv('CP_TEST_DB') then os.execute(('mysql -uroot -e "DROP DATABASE IF EXISTS %s;"'):format(H.db)) end
return H
