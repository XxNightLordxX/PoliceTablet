-- tests/builder_server_spec.lua · modules/builder/server.lua (slice builder_server).
--
-- Covers the guardrails, unit conversion, the Lua export (golden text of the spec's custom example and a
-- round trip through the RegisterMission sandbox), versions, edit locks and every SQL statement of the
-- module on MariaDB, archive/restore/rollback files and the reload (hand edit) conflict logic.
-- Mission files are written to a temporary folder missions/custom/test_builder_<n>/ that is removed at
-- the end, whatever happens. The spec uses its own database (cp_test_builder_server).

local H = dofile('tests/harness.lua')
H.db = 'cp_test_builder_server'
H.resetDatabase()
H.boot({ side = 'server' })

local U = CP.U
local cjson = require('cjson')

-- ── locale: every part merged, served as en.json (block reasons come translated) ─────
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

-- ── the locale part of this slice has every key the module uses ──────────────
do
    local f = io.open(H.root .. 'locales/parts/builder_server.json', 'r')
    local part = cjson.decode(f:read('a'))
    f:close()
    local src = io.open(H.root .. 'modules/builder/server.lua', 'r'):read('a')
    local missing = {}
    for key in src:gmatch("'(err%.[%w_]+)'") do if not part[key] then missing[#missing + 1] = key end end
    for key in src:gmatch("'(builder%.[%w_%.]+)'") do
        if not key:match('%.$') and not part[key] then missing[#missing + 1] = key end
    end
    for _, b in ipairs({ 'hostile_waves', 'escort', 'pursuit', 'checkpoint_route', 'interact_points', 'skill_check',
        'protect_rescue', 'flee_arrest', 'search_area' }) do
        if not part['builder.block.' .. b] then missing[#missing + 1] = 'builder.block.' .. b end
    end
    H.eq(table.concat(missing, ', '), '', 'every locale key used by modules/builder/server.lua is in builder_server.json')
    -- keys shared with other parts carry the same text
    local p = io.popen('ls ' .. H.root .. 'locales/parts/*.json')
    local clash = {}
    for file in p:lines() do
        if not file:find('builder_server.json', 1, true) then
            local other = cjson.decode(io.open(file, 'r'):read('a'))
            for k, v in pairs(part) do
                if other[k] ~= nil and other[k] ~= v then clash[#clash + 1] = k .. ' (' .. file:match('[^/]+$') .. ')' end
            end
        end
    end
    p:close()
    H.eq(table.concat(clash, ', '), '', 'shared locale keys have identical text')
end

-- ── temporary export folder ─────────────────────────────────────────────────
local TMP = ('missions/custom/test_builder_%d/'):format(os.clock() * 1e6 // 1 + math.random(1, 1e6))
os.execute(('mkdir -p %s%sarchived'):format(H.root, TMP))
Config.Builder.exportPath = TMP
_G.GetResourcePath = function() return H.root:sub(1, -2) end

local function fileExists(rel)
    local f = io.open(H.root .. rel, 'r')
    if f then f:close(); return true end
    return false
end
local function readRel(rel)
    local f = io.open(H.root .. rel, 'r')
    if not f then return nil end
    local s = f:read('a'); f:close(); return s
end
local function writeRel(rel, s)
    local f = assert(io.open(H.root .. rel, 'w')); f:write(s); f:close()
end

-- deep equality (numbers by value, so 60 == 60.0)
local function deq(a, b, path)
    path = path or ''
    if type(a) ~= type(b) then return false, path .. ' type ' .. type(a) .. ' vs ' .. type(b) end
    if type(a) ~= 'table' then
        if a == b then return true end
        return false, path .. ' ' .. tostring(a) .. ' vs ' .. tostring(b)
    end
    for k, v in pairs(a) do
        local ok, why = deq(v, b[k], path .. '.' .. tostring(k))
        if not ok then return false, why end
    end
    for k in pairs(b) do
        if a[k] == nil then return false, path .. '.' .. tostring(k) .. ' missing on the left' end
    end
    return true
end
local function plain(v) return cjson.decode(cjson.encode(U.serialize(v))) end

local function body()
    -- ── stubs of other modules ──────────────────────────────────────────────
    local players = {
        [1] = { citizenid = 'SUP00001', name = 'John Doe', rank = 'Sergeant', dept = 'sast', short = 'SAST', grade = 3, sup = true },
        [2] = { citizenid = 'SUP00002', name = 'Jane Roe', rank = 'Lieutenant', dept = 'fib', short = 'FIB', grade = 4, sup = true },
        [3] = { citizenid = 'ADM00001', name = 'Ada Admin', admin = true },
        [4] = { citizenid = 'OFF00001', name = 'Otto Officer', rank = 'Trooper', dept = 'sast', short = 'SAST', grade = 1 },
    }
    CP.Access = {
        isAdmin = function(src) return src == 0 or (players[src] ~= nil and players[src].admin == true) end,
        isSupervisor = function(src) return players[src] ~= nil and players[src].sup == true end,
        getOfficer = function(src)
            local p = players[src]
            if not p or not p.dept then return nil, 'err.not_police' end
            return { src = src, citizenid = p.citizenid, name = p.name, department = p.dept, departmentShort = p.short,
                rank = p.rank, gradeLevel = p.grade, isSupervisor = p.sup == true, isAdmin = p.admin == true, onduty = true }
        end,
        departmentForJob = function() return nil end,
        department = function() return nil end,
        role = function(src) return players[src] and (players[src].admin and 'admin' or 'supervisor') or nil end,
    }
    CP.Qbx = {
        getInfo = function(src)
            local p = players[src]
            if not p then return nil end
            return { src = src, citizenid = p.citizenid, name = p.name, job = { name = 'unemployed', gradeName = 'Freelancer' } }
        end,
        getByCitizenId = function(cid)
            for src, p in pairs(players) do if p.citizenid == cid then return src end end
            return nil
        end,
        onPlayerUnload = function(fn) CP.Qbx._unload = fn end,
    }
    local audits, pushes, notes, drafts = {}, {}, {}, {}
    CP.Admin = { audit = function(actor, role, category, action, target, old, new, reason)
        audits[#audits + 1] = { actor = actor, role = role, category = category, action = action, target = target, old = old, new = new, reason = reason }
    end }
    CP.Tablet = {
        push = function(src, topic, data) pushes[#pushes + 1] = { src = src, topic = topic, data = data } end,
        notify = function(src, kind, key, vars) notes[#notes + 1] = { src = src, kind = kind, key = key, vars = vars } end,
    }
    local testingOk = true
    CP.Testing = { startDraft = function(src, def, opts)
        drafts[#drafts + 1] = { src = src, def = def, opts = opts }
        if not testingOk then return false, 'err.in_arena' end
        -- as modules/testing: the data names the location that runs ('random' picks one)
        return true, { runId = 'run-' .. #drafts, missionId = def.id, locationIndex = opts.location == 'random' and 3 or opts.location,
            tier = opts.tier, testers = 1 }
    end }
    local inArena = {}
    CP.Alerts = { inArena = function(src) return inArena[src] == true end }
    CP.Npc = CP.Npc or { setState = function() end, getState = function() end, rollSurrender = function() return false end,
        enableCuff = function() end, onDeath = function() end, onDamaged = function() end }

    H.load('modules/scaling/server.lua')
    H.load('modules/permissions/server.lua')
    for _, b in ipairs({ 'checkpoint_route', 'interact_points', 'skill_check', 'hostile_waves', 'protect_rescue',
        'flee_arrest', 'pursuit', 'escort', 'search_area' }) do
        local ok, err = pcall(H.load, 'blocks/' .. b .. '/server.lua')
        if not ok then print('  (block ' .. b .. ' did not load: ' .. tostring(err) .. ')') end
    end
    H.sql('DELETE FROM cp_custom_missions')
    H.sql('DELETE FROM cp_officers')
    H.sql("INSERT INTO cp_officers (citizenid, display_name, department) VALUES ('SUP00001', 'John Doe', 'sast'), ('SUP00002', 'Jane Roe', 'fib')")
    H.load('modules/builder/server.lua')
    H.load('modules/missions/server.lua')
    H.step(10)   -- CP.Missions.loadAll (built-ins + CP.Builder.loadPublished)
    local B = CP.Builder
    H.ok(CP.Missions.get('gang_shootout') ~= nil or CP.Missions.list()[1] ~= nil, 'built-in missions loaded next to the builder')

    -- ── helpers: actions and callbacks through CP.Net ───────────────────────
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
        return H.sql('SELECT id, status, published_version, draft_version, draft_tested, file_path, edited_in_code, locked_by, created_by, updated_by, mission_type, draft_definition, published_definition FROM cp_custom_missions WHERE id = ?', { id })[1]
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

    -- ── a valid builder definition ──────────────────────────────────────────
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
            label = 'Dockside Raid', description = 'A smuggling crew is unloading at the docks.',
            type = 'tactical', departments = {}, minOfficers = 2, maxOfficers = 4, difficulty = 3,
            timeLimit = 720, startTimeout = 600, cooldown = 1200, vehiclePenalties = false,
            locations = { location(1), location(2), location(3) },
            objectives = {
                { block = 'hostile_waves', label = 'Clear the dock', minSeconds = 45, presenceRange = 150,
                  waves = { 7, 6 }, weapons = { 'WEAPON_PISTOL', 'WEAPON_SMG' }, accuracy = 30, armour = 10,
                  surrender = { belowHealth = 0.25, chance = 30 } },
                { block = 'interact_points', label = 'Seize the shipment', minSeconds = 6, presenceRange = 150,
                  points = 'evidence', progress = { label = 'Seizing crates', duration = 6 } },
            },
            scaling = { 'objectives.1.waves' },
            items = { { name = 'radio', count = 1 } },
            bonuses = { { id = 'no_participant_downed', pct = 10 }, { id = 'hostile_arrested', points = 5 } },
            penalties = {},
        }
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
        H.eq(d.payout, nil, 'payout stripped'); H.eq(d.cashBase, nil, 'cashBase stripped')
        H.eq(d.source, nil, 'loader field stripped'); H.eq(d._file, nil, '_file stripped')
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
        H.eq(r1, nil, 'too large refused'); H.eq(r2, 'err.builder_too_large', 'too large error key')
        H.eq(select(2, B.sanitize('nope')), 'err.invalid_payload', 'non-table refused')
        local bad = B.sanitize({ label = 'x', n = 0 / 0, big = 1e12, ['bad key'] = 1, [5] = 2 }, 'custom_x')
        H.eq(bad.n, nil, 'NaN dropped'); H.eq(bad.big, nil, 'huge number dropped'); H.eq(bad['bad key'], nil, 'bad key dropped')
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
        if path then H.ok(errorAt(errors, path) ~= nil, label .. ' at ' .. path .. ' (got: ' .. keysOf(errors) .. ')') end
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
    check('start missing', function(d) d.locations[2].start = nil end, 'builder.error.start_missing', 'locations.2.start')
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
    check('weapon outside the allowed list (block validate)', function(d) d.objectives[1].weapons = { 'WEAPON_RPG' } end, nil, 'objectives.1')
    check('ped outside the allowed list (block validate)', function(d) d.objectives[1].peds = { 'mp_m_freemode_01' } end, nil, 'objectives.1')
    check('block range (accuracy 90)', function(d) d.objectives[1].accuracy = 90 end, nil, 'objectives.1')
    check('required points missing', function(d) d.locations[2].evidence = nil end, 'builder.error.point_missing', 'locations.2.evidence')
    check('min seconds 0', function(d) d.objectives[2].minSeconds = 0 end, 'builder.error.min_seconds', 'objectives.2.minSeconds')
    check('min seconds over the time limit', function(d) d.objectives[1].minSeconds = 700; d.objectives[2].minSeconds = 100 end,
        'builder.error.min_seconds_total')
    check('presence range', function(d) d.objectives[1].presenceRange = 20 end, 'builder.error.presence_range')
    check('unknown block', function(d) d.objectives[3] = { block = 'traffic_stop', label = 'x', minSeconds = 5 } end,
        'builder.error.unknown_block', 'objectives.3.block')
    check('no objectives', function(d) d.objectives = {} end, 'builder.error.no_objectives')
    check('seven blocks', function(d)
        for i = 3, 7 do d.objectives[i] = U.deepcopy(d.objectives[2]) end
    end, 'builder.error.max_blocks')
    check('flat bonus over 50', function(d) d.bonuses[2].points = 60 end, 'builder.error.bonus_cap_points', 'bonuses.2.points')
    check('pct bonus over 25%', function(d) d.bonuses[1].pct = 30 end, 'builder.error.bonus_cap_pct', 'bonuses.1.pct')
    check('penalty over 50', function(d) d.penalties = { { id = 'hard_ram', points = -60 } } end, 'builder.error.bonus_cap_points')
    check('unknown bonus', function(d) d.bonuses[3] = { id = 'racer_detained', points = 30 } end, 'builder.error.bonus_unknown')
    check('penalty listed as a bonus', function(d) d.bonuses[3] = { id = 'wrong_log', points = -5 } end, 'builder.error.bonus_sign')
    check('bonus needs its block', function(d) d.bonuses[3] = { id = 'suspect_alive', points = 15 } end, 'builder.error.bonus_block')
    check('duplicate bonus', function(d) d.bonuses[3] = { id = 'hostile_arrested', points = 5 } end, 'builder.error.bonus_duplicate')
    for _, name in ipairs({ 'armour', 'bandage', 'ammo-9', 'Ammo-rifle', 'WEAPON_PISTOL', 'weapon_knife' }) do
        check('item ' .. name, function(d) d.items = { { name = name, count = 1 } } end, 'builder.error.item_forbidden', 'items.1.name')
    end
    check('item count', function(d) d.items[1].count = 0 end, 'builder.error.item_count')
    check('item name', function(d) d.items[1].name = 'bad name!' end, 'builder.error.item_name')
    check('scaling path outside the objectives', function(d) d.scaling = { 'objectives.9.waves' } end, 'builder.error.scaling_path')
    check('scaling a text field', function(d) d.scaling = { 'objectives.2.points' } end, 'builder.error.scaling_value')
    check('scaling max', function(d) d.scaling = { { path = 'objectives.1.waves', max = -1 } } end, 'builder.error.scaling_max')
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
        H.ok(hasError(errors, 'builder.error.route_gap'), 'open route start and end under 300 m apart: ' .. keysOf(errors))
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
        H.eq(f.bonuses[2].points, 5, 'flat bonus points'); H.eq(f.bonuses[2].each, true, 'each from Config.Bonuses')
        local back = B.fromFileUnits(f)
        local ok, why = deq(plain(back), plain(good))
        H.ok(ok, 'file units -> builder units round trip: ' .. tostring(why))
        local io_ = { block = 'interact_points', roll = { outcomes = { { id = 'a', chance = 75, followUp = { label = 'x', duration = 2.5 } }, { id = 'b', chance = 25 } } } }
        local fa = B.toFileUnits({ objectives = { io_ } })
        H.near(fa.objectives[1].roll.outcomes[1].chance, 0.75, 1e-12, 'roll outcome chances (wildcard path)')
        H.eq(fa.objectives[1].roll.outcomes[1].followUp.duration, 2500, 'follow-up seconds -> ms (wildcard path)')
        local fl = B.toFileUnits({ objectives = { { block = 'flee_arrest', responses = { surrender = 50, flee = 30, fight = 20 }, armedShare = 40, knock = { duration = 3 } } } })
        H.near(fl.objectives[1].responses.flee, 0.30, 1e-12, 'flee_arrest responses'); H.near(fl.objectives[1].armedShare, 0.4, 1e-12, 'armedShare')
        H.eq(fl.objectives[1].knock.duration, 3000, 'knock seconds -> ms')
        local pr = B.toFileUnits({ objectives = { { block = 'protect_rescue', freeTime = 6 }, { block = 'pursuit', footFlee = 20, arrest = { duration = 3 } } } })
        H.eq(pr.objectives[1].freeTime, 6000, 'freeTime seconds -> ms')
        H.near(pr.objectives[2].footFlee, 0.2, 1e-12, 'footFlee percent -> fraction'); H.eq(pr.objectives[2].arrest.duration, 3000, 'arrest ms')
    end

    -- ══ Lua export: golden text of the spec's custom example ════════════════
    do
        local z3 = { x = 0.0, y = 0.0, z = 0.0 }
        local example = {
            id = 'custom_dockside_raid', label = 'Dockside Raid',
            description = 'A smuggling crew is unloading at the docks. Clear the dock and seize the shipment.',
            type = 'tactical', departments = {}, minOfficers = 2, maxOfficers = 4, difficulty = 3, timeLimit = 720,
            vehiclePenalties = false, startTimeout = 600, cooldown = 1200,
            locations = { { label = 'Dock 1', start = { coords = z3, radius = 60 },
                spawns = { { x = 0.0, y = 0.0, z = 0.0, w = 0.0 } }, evidence = { z3 } } },
            objectives = {
                { block = 'hostile_waves', label = 'Clear the dock', minSeconds = 45, waves = { 6, 6 },
                  weapons = { 'WEAPON_PISTOL', 'WEAPON_SMG' }, accuracy = 30, armour = 10 },
                { block = 'interact_points', label = 'Seize the shipment', minSeconds = 6, points = 'evidence',
                  progress = { label = 'Seizing crates', duration = 6 } },
            },
            scaling = { 'objectives.1.waves' }, items = {},
            bonuses = { { id = 'no_participant_downed', pct = 10 } }, penalties = {},
        }
        local at = os.time({ year = 2026, month = 9, day = 28, hour = 5, min = 40, sec = 0 })
        local text = B.exportLua(example, { version = 3, publisher = 'Sgt. J. Doe (SAST, citizenid ABC12345)', at = at })
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
            "  id           = 'custom_dockside_raid',",
            "  label        = 'Dockside Raid',",
            "  description  = 'A smuggling crew is unloading at the docks. Clear the dock and seize the shipment.',",
            "  type         = 'tactical',",
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
            "      label    = 'Dock 1',",
            '      start    = { coords = vec3(0.0, 0.0, 0.0), radius = 60.0 },',
            '      spawns   = { vec4(0.0, 0.0, 0.0, 0.0) },',
            '      evidence = { vec3(0.0, 0.0, 0.0) },',
            '    },',
            '  },',
            '',
            '  objectives = {',
            "    { block = 'hostile_waves', label = 'Clear the dock', minSeconds = 45, waves = { 6, 6 },",
            "      weapons = { 'WEAPON_PISTOL', 'WEAPON_SMG' }, accuracy = 30, armour = 10 },",
            "    { block = 'interact_points', label = 'Seize the shipment', minSeconds = 6, points = 'evidence',",
            "      progress = { label = 'Seizing crates', duration = 6000 } },",
            '  },',
            '',
            "  scaling   = { 'objectives.1.waves' },",
            '  items     = {},',
            "  bonuses   = { { id = 'no_participant_downed', pctOfPoints = 0.10 } },",
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
                if a[i] ~= b[i] then print(('  line %d\n    got:      %s\n    expected: %s'):format(i, tostring(a[i]), tostring(b[i]))) end
            end
        end
        local parsed = B.parse(text, 'example.lua')
        H.ok(parsed ~= nil, 'the export loads through the RegisterMission sandbox')
        local ok, why = deq(plain(B.fromFileUnits(parsed)), plain(example))
        H.ok(ok, 'the export loads back to an equal definition: ' .. tostring(why))
    end

    -- the full valid definition round-trips too (many points, lists broken over lines, strings with quotes)
    do
        local d = U.deepcopy(good)
        d.description = "It's a \"raid\"\nwith two lines and a backslash \\ and ]] inside"
        d.locations[1].label = "O'Neil's Dock"
        d.locations[1].route = { points = { { x = 1.5, y = 2.25, z = 3.0 }, { x = 900.0, y = 2.0, z = 3.0 } }, stops = { { at = 1, wait = 20 } } }
        d.objectives[2].roll = { outcomes = { { id = 'crate', chance = 75, followUp = { label = 'Open', duration = 2.5 } }, { id = 'empty', chance = 25 } } }
        d.penalties = { { id = 'hard_ram', points = -10 } }
        local text = B.exportLua(d, { version = 7, publisher = 'Admin ]] Name\nX', at = os.time() })
        H.ok(text:find("-- empty = every department", 1, true) ~= nil, 'departments comment')
        H.ok(text:find('chance = 0.30', 1, true) ~= nil, 'chances written with two decimals')
        H.ok(text:find('chance = 0.75', 1, true) ~= nil, 'roll chances written with two decimals')
        H.ok(text:find('duration = 2500', 1, true) ~= nil, 'follow-up duration in ms')
        H.ok(text:find('vec4(-559.0, -1505.0, 21.5, 90.0)', 1, true) ~= nil, 'vec4 literal with heading')
        H.ok(text:find('pctOfPoints = 0.10', 1, true) ~= nil, 'pctOfPoints two decimals')
        H.ok(text:find("{ id = 'hard_ram', points = -10, each = true }", 1, true) ~= nil, 'penalty with each')
        H.ok(text:find('payout', 1, true) == nil or text:find('the payout comes from the Payouts screens', 1, true) ~= nil, 'no payout field')
        local header = text:sub(1, text:find(']]', 1, true) + 1)
        H.ok(not header:sub(1, -3):find(']]', 1, true), 'a ]] in the publisher cannot close the header early')
        for line in text:gmatch('[^\n]+') do
            if #line > 120 and not line:find('description') then H.ok(false, 'long line in the export: ' .. line) break end
        end
        local parsed, err = B.parse(text, 'full.lua')
        H.ok(parsed ~= nil, 'the full export loads: ' .. tostring(err))
        local ok, why = deq(plain(B.fromFileUnits(parsed)), plain(d))
        H.ok(ok, 'the full export round-trips: ' .. tostring(why))
        H.eq(parsed.description, d.description, 'strings with quotes, newlines and backslashes survive')
    end

    -- ══ actions: create, lock, save, versions ═══════════════════════════════
    local ok, data = act(1, 'create', { type = 'tactical', label = 'Dockside Raid' })
    H.ok(ok, 'create: ' .. tostring(data))
    local id = ok and data.id or 'custom_dockside_raid'
    H.eq(id, 'custom_dockside_raid', 'id = custom_ + slug of the label')
    H.eq(data.record.status, 'draft', 'new mission is a draft')
    H.eq(data.record.lock and data.record.lock.mine, true, 'the creator holds the lock')
    local r = row(id)
    H.eq(r.status, 'draft', 'row status draft'); H.eq(r.draft_version, 1, 'draft version 1')
    H.eq(r.locked_by, 'SUP00001', 'locked by the creator'); H.eq(r.created_by, 'SUP00001', 'created_by')
    H.eq(lastAudit().action, 'create', 'create audited'); H.eq(lastAudit().category, 'builder', 'category builder')
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
        H.ok(fooled and okRace and race.id == 'custom_dockside_raid_3', 'an id clash on insert moves on to the next free id: ' .. tostring(race and race.id))
        H.eq(row('custom_dockside_raid').created_by, 'SUP00001', 'the existing mission is untouched')
        act(1, 'discardDraft', { id = 'custom_dockside_raid_3' })
        H.eq(row('custom_dockside_raid_3'), nil, 'race copy discarded')
    end
    H.eq(select(2, act(1, 'create', { type = 'traffic' })), 'err.builder_bad_type', 'unknown mission type')
    H.eq(select(2, act(4, 'create', { type = 'patrol' })), 'err.no_permission', 'officers cannot build')
    local okDef, defaultData = act(3, 'create', { type = 'patrol' })
    H.ok(okDef and defaultData.id:match('^custom_new_patrol_mission'), 'default label -> id ' .. tostring(defaultData and defaultData.id))

    -- someone else's mission
    H.eq(select(2, act(2, 'lock', { id = id })), 'err.no_permission', 'builderEditAny off: no editing others')
    Config.Permissions.supervisor.builderEditAny = true
    H.eq(select(2, act(2, 'lock', { id = id })), 'err.builder_locked', 'locked by someone else')
    H.eq(select(2, act(2, 'save', { id = id, definition = validDef() })), 'err.builder_locked', 'save refused while locked')
    Config.Permissions.supervisor.builderEditAny = false
    H.eq(select(2, act(1, 'lock', { id = 'gang_shootout' })), 'err.builder_read_only', 'built-ins are read-only')
    H.eq(select(2, act(1, 'lock', { id = 'nope_x' })), 'err.builder_unknown_mission', 'unknown mission')
    H.eq(select(2, act(1, 'lock', { id = "x'; DROP" })), 'err.invalid_payload', 'bad id refused')

    -- save
    local okS, saved = act(1, 'save', { id = id, definition = validDef() })
    H.ok(okS, 'save: ' .. tostring(saved))
    H.eq(saved.valid, true, 'saved draft is valid (' .. keysOf(saved.errors or {}) .. ')')
    H.eq(saved.version, 1, 'draft version stays 1')
    H.eq(lastAudit().action, 'save', 'save audited')
    local okBad, savedBad = act(1, 'save', { id = id, definition = (function() local d = validDef(); d.timeLimit = 60; return d end)() })
    H.ok(okBad and savedBad.valid == false and hasError(savedBad.errors, 'builder.error.time_limit'), 'an invalid draft is stored and reported')
    act(1, 'save', { id = id, definition = validDef() })

    -- validate (stored draft, or a definition in the payload) and unlock
    do
        local okV, v = act(1, 'validate', { id = id })
        H.ok(okV and v.valid == true and v.armed == 13 and v.requiredTier == 'heavy' and v.maxHostiles == 40, 'validate the stored draft')
        local d = validDef(); d.payout = 500; d.items = { { name = 'bandage', count = 2 } }
        local okV2, v2 = act(2, 'validate', { id = id, definition = d })
        H.ok(okV2 and v2.valid == false and hasError(v2.errors, 'builder.error.payout_field')
            and hasError(v2.errors, 'builder.error.item_forbidden'), 'validate a payload definition (read-only, any builder)')
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
        H.ok(okR and res.id == 'custom_harbour_sweep' and res.previousId == 'custom_dockside_raid_2', 'save renames an unpublished draft')
        H.eq(row('custom_dockside_raid_2'), nil, 'old id gone')
        H.ok(row('custom_harbour_sweep') ~= nil, 'new id stored')
    end

    -- lists and records
    do
        local okL, list = cb(1, 'builder:list', {})
        H.ok(okL and #list.missions >= 3, 'builder:list returns the custom missions')
        local e
        for _, m in ipairs(list.missions) do if m.id == id then e = m end end
        H.ok(e ~= nil, 'our mission is listed')
        H.eq(e.status, 'draft', 'list status'); H.eq(e.owner.name, 'John Doe', 'owner name from cp_officers')
        H.eq(e.lock.mine, true, 'lock mine'); H.eq(e.can.publish, true, 'owner may publish'); H.eq(e.requiredTier, 'heavy', 'required tier')
        H.ok(#list.builtins > 0 and list.builtins[1].readOnly == true, 'built-ins listed read-only')
        local okL2, list2 = cb(2, 'builder:list', {})
        for _, m in ipairs(list2.missions) do if m.id == id then e = m end end
        H.eq(e.can.edit, false, 'not editable by another supervisor'); H.eq(e.lock.mine, false, 'lock shown to others')
        H.eq(e.lock.name, 'John Doe', 'lock holder name')
        local okG, rec = cb(1, 'builder:get', { id = id })
        H.ok(okG and rec.definition.label == 'Dockside Raid' and #rec.errors == 0, 'builder:get returns the draft with its errors')
        H.eq(rec.armed, 13, 'record armed count')
        local okB, bi = cb(1, 'builder:get', { id = 'gang_shootout' })
        if CP.Missions.get('gang_shootout') then
            H.ok(okB and bi.readOnly == true and bi.source == 'builtin', 'built-in record is read-only')
            H.ok(okB and bi.definition.objectives[1].surrender == nil or type(bi.definition.objectives[1].surrender.chance) == 'number',
                'built-in shown in builder units')
        end
        local okC, conf = cb(1, 'builder:config', {})
        H.ok(okC and conf.maxHostiles == 40 and conf.bonusCap.pct == 25 and conf.bonusCap.points == 50, 'builder:config caps')
        H.ok(okC and #conf.noBuildZones == #Config.Builder.noBuildZones and conf.noBuildZones[1].coords.x ~= nil, 'no-build zones as plain vectors')
        local pctB
        for _, bo in ipairs(conf.bonuses) do if bo.id == 'no_participant_downed' then pctB = bo end end
        H.ok(pctB and pctB.kind == 'pct' and pctB.value == 10, 'bonus list in whole percent')
        H.eq(conf.percentFields.hostile_waves[1], 'surrender.chance', 'percent fields listed')
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
    H.ok(okT and tdata.tier == 'heavy' and tdata.requiredTier == 'heavy', 'test at the required tier by default: ' .. tostring(tdata))
    H.eq(tdata.location, 2, 'the test reply names its location')
    do
        local okR, rdata = act(1, 'test', { id = id, location = 'random' })
        H.ok(okR and rdata.location == 3, 'a random location test replies with the location CP.Testing picked (the tester records it)')
        H.eq(drafts[#drafts].opts.location, 'random', 'CP.Testing still gets random')
        act(1, 'test', { id = id, location = 2 })
    end
    local started = drafts[#drafts]
    H.ok(started and started.opts.tier == 'heavy' and started.opts.location == 2 and started.opts.useStartRoute == false, 'CP.Testing.startDraft options')
    H.ok(started and started.def.id == id and started.def.source == 'custom', 'the draft is normalised for the test run')
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
        local d = validDef(); d.objectives[1].accuracy = 31
        act(1, 'save', { id = id, definition = d })
        H.eq(U.truthy(row(id).draft_tested), false, 'a stored change resets draft_tested')
        act(1, 'save', { id = id, definition = validDef() })
        act(1, 'test', { id = id })
        local d2 = validDef(); d2.objectives[1].accuracy = 32
        act(1, 'autosave', { id = id, definition = d2 })
        H.eq(B.onDraftTested(id, 1, 'heavy', true, 1), false, 'a draft changed during the test does not count')
        act(1, 'save', { id = id, definition = validDef() })
        act(1, 'test', { id = id })
        H.eq(B.onDraftTested(id, 1, 'critical', true, 1), true, 'a pass at a higher tier counts')
    end

    Config.Permissions.supervisor.builderPublish = false
    H.eq(select(2, act(1, 'publish', { id = id })), 'err.no_permission', 'builderPublish off')
    Config.Permissions.supervisor.builderPublish = true
    local okP, pub = act(1, 'publish', { id = id })
    H.ok(okP, 'publish: ' .. tostring(pub))
    H.eq(pub.version, 1, 'published version 1'); H.eq(pub.filePath, TMP .. id .. '.lua', 'file path'); H.eq(pub.backup, nil, 'no backup for v1')
    r = row(id)
    H.eq(r.status, 'published', 'status published'); H.eq(r.published_version, 1, 'published_version')
    H.eq(r.draft_version, nil, 'draft consumed'); H.eq(r.draft_definition, nil, 'draft cleared'); H.eq(r.locked_by, nil, 'lock released')
    local text1 = readRel(TMP .. id .. '.lua')
    H.ok(text1 and text1:find('  version:   1', 1, true) and text1:find('published: .- by Sergeant John Doe %(SAST, citizenid SUP00001%)'),
        'header names version and publisher')
    H.ok(text1 and text1:find('Edit this file, then run: /CrimsonPoliceAdmin reload', 1, true), 'header tells developers how to reload')
    local pubDef = cjson.decode(r.published_definition)
    H.eq(pubDef._file.hash, U.hashHex(text1), 'published_definition keeps the file hash')
    H.eq(pubDef.label, 'Dockside Raid', 'published_definition is the builder copy')
    local m = CP.Missions.get(id)
    H.ok(m and m.source == 'custom' and m.version == 1 and m.status == 'published', 'registered in CP.Missions without a restart')
    H.ok(m and m.defHash == U.hashHex(text1), 'defHash is the file hash')
    local inPool = false
    for _, d in ipairs(CP.Missions.byType('tactical')) do if d.id == id then inPool = true end end
    H.ok(inPool, 'the published mission joins its type pool')
    H.eq(lastAudit().action, 'publish', 'publish audited')
    local pushed = false
    for _, p in ipairs(pushes) do if p.topic == 'builder' and p.data.event == 'published' and p.data.id == id then pushed = true end end
    H.ok(pushed, 'builder push to viewers')

    -- edit the published mission: draft v2 while v1 stays live
    do
        local d = validDef(); d.objectives[1].accuracy = 35
        local okE, e = act(1, 'save', { id = id, definition = d })
        H.ok(okE and e.version == 2, 'editing a published mission works on draft v2')
        H.eq(CP.Missions.get(id).objectives[1].accuracy, 30, 'v1 stays live')
        H.eq(select(2, act(1, 'publish', { id = id })), 'err.builder_not_tested', 'v2 needs its own test')
        act(1, 'test', { id = id })
        H.eq(B.onDraftTested(id, 2, 'heavy', true, 1), true, 'v2 tested')
        local okP2, pub2 = act(1, 'publish', { id = id })
        H.ok(okP2 and pub2.version == 2 and pub2.backup == TMP .. id .. '.v1.lua.bak', 'v2 published, v1 kept as .bak')
        H.eq(readRel(TMP .. id .. '.v1.lua.bak'), text1, 'the .bak is the previous file')
        H.eq(CP.Missions.get(id).objectives[1].accuracy, 35, 'v2 live')
        H.eq(CP.Missions.get(id).version, 2, 'version 2 registered')
    end

    -- rollback (admin; supervisors only with builderRollback)
    H.eq(select(2, act(1, 'rollback', { id = id })), 'err.no_permission', 'builderRollback off for supervisors')
    do
        local okRb, rb = act(3, 'rollback', { id = id })
        H.ok(okRb and rb.version == 3 and rb.fromVersion == 1, 'rollback restores v1 as v3: ' .. tostring(rb))
        H.eq(CP.Missions.get(id).objectives[1].accuracy, 30, 'v1 content live again')
        H.ok(fileExists(TMP .. id .. '.v2.lua.bak'), 'v2 kept as .bak')
        r = row(id)
        H.eq(r.published_version, 3, 'published_version 3'); H.eq(r.updated_by, 'ADM00001', 'updated_by the admin')
        H.eq(lastAudit().action, 'rollback', 'rollback audited'); H.eq(lastAudit().role, 'admin', 'admin role')
        local t3 = readRel(TMP .. id .. '.lua')
        H.ok(t3:find('published: .- by Freelancer Ada Admin %(admin, citizenid ADM00001%)'), 'rollback header names the admin')
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
        local d = validDef(); d.objectives[1].accuracy = 44
        H.eq(select(2, act(1, 'autosave', { id = id, definition = d })), 'err.builder_locked', 'after a break the old editor cannot autosave')
        H.eq(select(2, act(1, 'save', { id = id, definition = d })), 'err.builder_locked', 'nor save')
        H.eq(row(id).locked_by, nil, 'the broken lock stays free')
        H.ok(not tostring(row(id).draft_definition):find('"accuracy":44', 1, true), 'the old editor did not overwrite the draft')
        -- their autosaves keep them a viewer, so the next lock break reaches their screen
        local pushAt = #pushes
        act(3, 'lock', { id = id })
        act(3, 'breakLock', { id = id })
        local reached = false
        for i = pushAt + 1, #pushes do
            if pushes[i].src == 1 and pushes[i].topic == 'builder' and pushes[i].data.event == 'lockBroken' then reached = true end
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
        local okAr, ar = act(1, 'archive', { id = id })
        H.ok(okAr and ar.filePath == TMP .. 'archived/' .. id .. '.lua', 'archive moves the file')
        H.ok(fileExists(TMP .. 'archived/' .. id .. '.lua') and not fileExists(TMP .. id .. '.lua'), 'file in archived/ only')
        H.eq(CP.Missions.get(id), nil, 'unregistered from its pool')
        H.eq(row(id).status, 'archived', 'status archived')
        H.eq(select(2, act(1, 'archive', { id = id })), 'err.builder_not_published', 'archive twice refused')
        H.eq(select(2, act(1, 'lock', { id = id })), 'err.builder_read_only', 'archived missions are not edited')
        local okRs, rs = act(1, 'restore', { id = id })
        H.ok(okRs and rs.filePath == TMP .. id .. '.lua' and fileExists(TMP .. id .. '.lua'), 'restore moves it back')
        H.ok(not fileExists(TMP .. 'archived/' .. id .. '.lua'), 'archived copy removed')
        H.ok(CP.Missions.get(id) and CP.Missions.get(id).version == 3, 'restored mission registered again')
        H.eq(lastAudit().action, 'restore', 'restore audited')
    end

    -- discard
    do
        H.eq(select(2, act(1, 'discardDraft', { id = id })), 'err.builder_no_draft', 'nothing to discard')
        local d = validDef(); d.label = 'Dockside Raid'; d.objectives[1].accuracy = 40
        act(1, 'save', { id = id, definition = d })
        local okD, dd = act(1, 'discardDraft', { id = id })
        H.ok(okD and dd.deleted == false, 'discarding the draft of a published mission keeps the mission')
        r = row(id)
        H.eq(r.draft_definition, nil, 'draft gone'); H.eq(r.published_version, 3, 'published version kept')
        local okD2, dd2 = act(1, 'discardDraft', { id = 'custom_harbour_sweep' })
        H.ok(okD2 and dd2.deleted == true and row('custom_harbour_sweep') == nil, 'a never-published draft is deleted')
    end

    -- duplicate
    do
        local okDu, du = act(1, 'duplicate', { id = id })
        H.ok(okDu and du.id == 'custom_dockside_raid_copy' and du.record.definition.label == 'Dockside Raid (copy)', 'duplicate a custom mission')
        H.eq(row(du.id).created_by, 'SUP00001', 'the copy belongs to the duplicator')
        if CP.Missions.get('gang_shootout') then
            local okDb, db = act(2, 'duplicate', { id = 'gang_shootout' })
            H.ok(okDb and db.record.source == 'custom' and db.record.definition.type == 'tactical', 'duplicate a built-in')
            local copy = db.record.definition
            for _, e in ipairs(copy.bonuses) do H.ok(Config.Bonuses[e.id] ~= nil, 'copy keeps standard bonuses only: ' .. e.id) end
            H.ok(type(copy.objectives[1].surrender) ~= 'table' or copy.objectives[1].surrender.chance >= 1, 'copy in builder units (percent)')
        end
    end

    -- ══ reload: hand edits, conflicts, rejects, missing files ═══════════════
    local path = TMP .. id .. '.lua'
    do
        local summary = B.onReload()
        H.eq(#summary.edited, 0, 'nothing edited yet'); H.ok(summary.unchanged >= 1, 'unchanged files counted')
        -- a developer edits the file: new label, accuracy and a payout line
        local text = readRel(path)
        local edited = text:gsub("label        = 'Dockside Raid'", "label        = 'Dockside Raid (code)'", 1)
            :gsub('accuracy = 30', 'accuracy = 28', 1)
            :gsub("  type         = 'tactical',", "  type         = 'tactical',\n  payout       = 99999,", 1)
        writeRel(path, edited)
        local s = B.onReload()
        H.eq(#s.edited, 1, 'the hand edit is accepted'); H.eq(s.edited[1] and s.edited[1].version, 4, 'saved as version 4')
        r = row(id)
        H.eq(r.published_version, 4, 'published_version 4'); H.eq(U.truthy(r.edited_in_code), true, 'marked edited in code')
        local stored = cjson.decode(r.published_definition)
        H.eq(stored.label, 'Dockside Raid (code)', 'published copy follows the file')
        H.eq(stored.payout, nil, 'the payout field is ignored')
        H.eq(stored.objectives[1].accuracy, 28, 'edited value stored')
        local now = readRel(path)
        H.ok(now:find('  version:   4', 1, true) and now:find('  edited:    ', 1, true), 'header version updated and marked edited')
        H.ok(now:find('payout       = 99999', 1, true) ~= nil, 'the developer file itself is kept')
        H.eq(stored._file.hash, U.hashHex(now), 'new file hash stored')
        H.ok(fileExists(TMP .. id .. '.v3.lua.bak'), 'previous version kept as .bak')
        H.eq(lastAudit().action, 'codeEdit', 'code edit audited')
        H.eq(#B.onReload().edited, 0, 'a second reload changes nothing')
        local defs = B.loadPublished()
        local found
        for _, d in ipairs(defs) do if d.id == id then found = d end end
        H.ok(found and found.editedInCode == true and found.version == 4 and found.payout == nil, 'loadPublished serves the edited file')
        H.ok(found and found.filePath == path and found.defHash == U.hashHex(now) and found.source == 'custom', 'loader fields')
    end
    do
        -- conflict: the builder draft AND the file changed since the last publish
        local d = validDef(); d.label = 'Dockside Raid (code)'; d.objectives[1].accuracy = 44
        act(1, 'save', { id = id, definition = d })
        writeRel(path, readRel(path):gsub('armour = 10', 'armour = 12', 1))
        H.reset()
        local s = B.onReload()
        H.eq(#s.conflicts, 1, 'conflict detected'); H.eq(#s.edited, 1, 'the file wins')
        H.ok(fileExists(TMP .. id .. '.draft.lua.bak'), 'draft saved as <id>.draft.lua.bak')
        local bak = B.parse(readRel(TMP .. id .. '.draft.lua.bak'), 'draft.bak')
        H.ok(bak and bak.objectives[1].accuracy == 44, 'the .draft.lua.bak holds the draft')
        r = row(id)
        H.eq(r.draft_definition, nil, 'draft cleared'); H.eq(r.published_version, 5, 'file saved as version 5')
        H.eq(cjson.decode(r.published_definition).objectives[1].armour, 12, 'file content published')
        local conflictAudit = false
        for _, a in ipairs(audits) do if a.action == 'codeEditConflict' and a.target == id then conflictAudit = true end end
        H.ok(conflictAudit, 'conflict audited')
        local told = H.findEvents('crimson-police:client:builder')
        H.ok(#told == 1 and told[1].args[1].event == 'reloaded', 'the editor is told the draft was replaced')
    end
    do
        -- an edit that breaks the guardrails is not used; the published version stays live
        local before = readRel(path)
        writeRel(path, before:gsub("'WEAPON_SMG'", "'WEAPON_RPG'", 1))
        local s = B.onReload()
        H.eq(#s.rejected, 1, 'guardrail-breaking edit rejected'); H.eq(row(id).published_version, 5, 'version unchanged')
        local defs = B.loadPublished()
        local found
        for _, d in ipairs(defs) do if d.id == id then found = d end end
        H.ok(found and found.objectives[1].weapons[2] == 'WEAPON_SMG', 'the last published version stays live')
        writeRel(path, 'RegisterMission({ id = ')
        H.eq(#B.onReload().rejected, 1, 'a file that does not load is rejected')
        writeRel(path, before)
        H.eq(#B.onReload().edited, 0, 'restoring the file makes it current again')
    end
    do
        -- a missing file is rewritten from the database
        os.remove(H.root .. path)
        local defs = B.loadPublished()
        H.ok(fileExists(path), 'missing file rewritten')
        local found
        for _, d in ipairs(defs) do if d.id == id then found = d end end
        H.ok(found and found.version == 5, 'rewritten mission loads')
        local re = B.parse(readRel(path), path)
        H.ok(re and re.id == id and re.objectives[1].armour == 12, 'rewritten from published_definition')
        H.eq(cjson.decode(row(id).published_definition)._file.hash, U.hashHex(readRel(path)), 'hash of the rewritten file stored')
    end
    do
        -- a row without a hash baseline takes the file on disk as its baseline
        local r0 = row(id)
        local stored = cjson.decode(r0.published_definition)
        stored._file = nil
        H.sql('UPDATE cp_custom_missions SET published_definition = ? WHERE id = ?', { cjson.encode(stored), id })
        local s = B.onReload()
        H.eq(#s.edited, 0, 'no baseline: nothing counted as edited')
        H.eq(cjson.decode(row(id).published_definition)._file.hash, U.hashHex(readRel(path)), 'baseline stored')
    end

    -- the missions registry uses loadPublished on a full reload
    do
        local summary = CP.Missions.reload()
        H.ok(summary.custom >= 1 and CP.Missions.get(id) ~= nil, 'CP.Missions.reload loads the custom mission from its file')
        H.ok(summary.builder and summary.builder.checked >= 1, 'reload summary carries the builder summary')
    end

    -- the builder switch
    Config.Builder.enabled = false
    H.eq(select(2, act(1, 'save', { id = id, definition = validDef() })), 'err.builder_disabled', 'Config.Builder.enabled = false')
    Config.Builder.enabled = true
end

local okBody, errBody = pcall(body)
os.execute(('rm -rf %s%s'):format(H.root, TMP))
H.ok(okBody, 'spec body ran: ' .. tostring(errBody))
H.ok(not fileExists(TMP), 'temporary mission folder removed')

return H
