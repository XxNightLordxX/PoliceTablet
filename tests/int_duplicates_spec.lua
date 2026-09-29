-- Every built-in mission can be duplicated into a custom mission that passes the Mission Builder guardrails and can be
-- published after its test.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })

local U = CP.U
local cjson = require('cjson')

-- ============================================================================
--                                   CONSOLE
-- ============================================================================
-- Keep the module log lines out of the test output.

local realPrint = print
_G.print = function(...)
    local line = table.concat((function(...)
        local t = {}
        for i = 1, select('#', ...) do t[i] = tostring((select(i, ...))) end
        return t
    end)(...), ' ')
    if line:find('crimson%-police') then return end
    realPrint(line)
end

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
--                           TEMPORARY EXPORT FOLDER
-- ============================================================================

local TMP = ('missions/custom/test_dup_%d/'):format(os.clock() * 1e6 // 1 + math.random(1, 1e6))
Config.Builder.exportPath = TMP
_G.GetResourcePath = function() return H.root:sub(1, -2) end

local function FileExists(rel)
    local f = io.open(H.root .. rel, 'r')
    if f then f:close(); return true end
    return false
end

local BUILTINS = assert(load(LoadResourceFile('Crimson-Police', 'missions/builtin/index.lua'), '@index', 't', {}))()

local function Body()
    -- ---- STUBS OF THE MODULES OUTSIDE THE BUILDER --------------------------
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
    }
    CP.Access = {
        isAdmin = function(src) return src == 0 end,
        isSupervisor = function(src) return players[src] ~= nil and players[src].sup == true end,
        getOfficer = function(src)
            local p = players[src]
            if not p then return nil, 'err.not_police' end
            return {
                src = src,
                citizenid = p.citizenid,
                name = p.name,
                department = p.dept,
                departmentShort = p.short,
                rank = p.rank,
                gradeLevel = p.grade,
                isSupervisor = true,
                isAdmin = false,
                onduty = true,
            }
        end,
        departmentForJob = function() return nil end,
        department = function() return nil end,
        role = function(src) return players[src] and 'supervisor' or nil end,
    }
    CP.Qbx = {
        getInfo = function(src)
            local p = players[src]
            if not p then return nil end
            return { src = src, citizenid = p.citizenid, name = p.name, job = { name = 'sast', gradeName = p.rank } }
        end,
        getByCitizenId = function(cid)
            for src, p in pairs(players) do if p.citizenid == cid then return src end end
            return nil
        end,
        onPlayerUnload = function() end,
    }
    CP.Admin = { audit = function() end }
    CP.Tablet = { push = function() end, notify = function() end }
    local started = {}
    CP.Testing = {
        startDraft = function(src, def, opts)
            started[#started + 1] = { src = src, def = def, opts = opts }
            return true,
                {
                    runId = 'run-' .. #started,
                    missionId = def.id,
                    locationIndex = opts.location,
                    tier = opts.tier,
                    testers = 1,
                }
        end,
    }
    CP.Alerts = {
        inArena = function() return false end,
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
    }) do
        H.load('blocks/' .. b .. '/server.lua')
    end
    H.sql('DELETE FROM cp_custom_missions')
    H.sql('DELETE FROM cp_officers WHERE citizenid = \'SUP00001\'')
    H.sql('INSERT INTO cp_officers (citizenid, display_name, department) VALUES (\'SUP00001\', \'John Doe\', \'sast\')')
    H.load('modules/builder/server.lua')
    H.load('modules/missions/server.lua')
    H.step(10)   -- CP.Missions.loadAll (built-ins + CP.Builder.loadPublished)
    local B = CP.Builder

    -- the real loader loaded every built-in file
    for _, id in ipairs(BUILTINS) do
        local def = CP.Missions.get(id)
        H.ok(def ~= nil and def.source == 'builtin', id .. ': loaded by the real loader as a built-in')
    end
    H.eq(#BUILTINS, 14, 'fourteen built-in missions')

    -- ---- HELPERS: actions through CP.Net -----------------------------------
    local reqN = 0
    local function act(name, payload)
        reqN = reqN + 1
        local reqId = 'q' .. reqN
        H.clockMs = H.clockMs + 6000      -- past every per-action rate limit
        H.fire('crimson-police:server:builder:' .. name, 1, payload, reqId)
        for i = #H.events, 1, -1 do
            local e = H.events[i]
            if e.name == 'crimson-police:client:actionResult' and e.args[1] == reqId then
                return e.args[2], e.args[3]
            end
        end
        error('no reply for ' .. name)
    end
    local function messages(errors)
        local out = {}
        for _, e in ipairs(errors or {}) do out[#out + 1] = tostring(e.path) .. ': ' .. tostring(e.message or e.key) end
        return table.concat(out, ' | ')
    end
    local function row(id)
        return H.sql(
            'SELECT id, status, published_version, draft_version, draft_tested, file_path, draft_definition FROM cp_custom_missions WHERE id = ?',
            { id })[1]
    end

    -- ---- EVERY BUILT-IN: duplicate -> validate -> save -> test -> passed -> publish ----
    local published = 0
    local publishedIds = {}
    for _, source in ipairs(BUILTINS) do
        local tag = 'duplicate of ' .. source
        local okDu, du = act('duplicate', { id = source })
        H.ok(okDu and type(du) == 'table' and type(du.id) == 'string',
            tag .. ': server:builder:duplicate (' .. tostring(okDu and '' or du) .. ')')
        if okDu then
            local id = du.id
            local rec = du.record
            H.eq(rec.source, 'custom', tag .. ': the copy is a custom mission')
            H.eq(messages(rec.errors), '', tag .. ': the new draft has no guardrail errors')
            -- the stored draft exactly as the builder saved it (JSON in cp_custom_missions)
            local draft = cjson.decode(row(id).draft_definition)
            local errors = B.validate(draft, { publish = true })
            H.eq(messages(errors), '', tag .. ': B.validate(publish = true) passes')
            -- the builder UI saves the record it was given, then asks for the publish validation
            local okS, saved = act('save', { id = id, definition = rec.definition })
            H.ok(okS and saved.valid == true,
                tag .. ': server:builder:save says valid (' .. messages(okS and saved.errors or {}) .. ')')
            id = okS and saved.id or id
            local okV, val = act('validate', { id = id })
            H.ok(
                okV and val.valid == true,
                tag .. ': server:builder:validate (publish checks) says valid (' .. messages(okV and val.errors or {})
                    .. ')'
            )
            -- test at the tier maxOfficers reaches, pass it, publish
            local okT, test = act('test', { id = id })
            H.ok(okT and type(test) == 'table' and test.tier == test.requiredTier,
                tag .. ': test run started at the required tier (' .. tostring(okT and '' or test) .. ')')
            if okT then
                H.eq(B.onDraftTested(id, test.version, test.tier, true, 1), true,
                    tag .. ': a passed test marks the draft tested')
                local okP, pub = act('publish', { id = id })
                H.ok(okP and type(pub) == 'table' and pub.version == 1,
                    tag .. ': published as version 1 (' .. tostring(okP and '' or pub) .. ')')
                if okP then
                    published = published + 1
                    publishedIds[source] = id
                    H.ok(FileExists(pub.filePath), tag .. ': mission file written')
                    local live = CP.Missions.get(id)
                    H.ok(live ~= nil and live.source == 'custom' and live.status == 'published',
                        tag .. ': registered as a published custom mission')
                    local r = row(id)
                    H.ok(r.status == 'published' and r.published_version == 1, tag .. ': row published')
                    -- the written file loads back through the builder's own reload check untouched
                    local text = LoadResourceFile('Crimson-Police', pub.filePath)
                    local parsed = B.parse(text, pub.filePath)
                    local back = parsed and B.sanitize(B.fromFileUnits(parsed), id)
                    H.eq(messages(back and B.validate(back, { publish = true }) or { { message = 'does not load' } }),
                        '', tag .. ': the published file passes the guardrails again (reload)')
                end
            end
        end
    end
    H.eq(published, 14, 'all 14 built-in missions duplicated, tested and published')
    H.eq(#B.onReload().rejected, 0, 'a reload rejects none of the published copies')

    -- ---- A CUSTOM MISSION PUBLISHED BEFORE THE RENAME (policeVehicle) keeps loading, silently ----
    do
        local id = publishedIds.beat_patrol
        local r = H.sql('SELECT file_path, published_definition FROM cp_custom_missions WHERE id = ?', { id })[1]
        local text = LoadResourceFile('Crimson-Police', r.file_path)
        H.ok(text:find('vehicleRequired = true', 1, true) ~= nil and text:find('policeVehicle', 1, true) == nil,
            'the builder writes vehicleRequired, never policeVehicle')
        -- the file and the stored copy as they were published with the old name
        local old = text:gsub('vehicleRequired = true', 'policeVehicle = false', 1)
        SaveResourceFile('Crimson-Police', r.file_path, old, -1)
        local stored = cjson.decode(r.published_definition)
        stored.objectives[1].vehicleRequired = nil
        stored.objectives[1].policeVehicle = false
        stored._file.hash = U.hashHex(old)
        H.sql('UPDATE cp_custom_missions SET published_definition = ? WHERE id = ?', { cjson.encode(stored), id })
        local warned = {}
        local realWarn = CP.warn
        CP.warn = function(tag, msg, ...)
            local ok, line = pcall(string.format, tostring(msg), ...)
            warned[#warned + 1] = ok and line or tostring(msg)
            return realWarn(tag, msg, ...)
        end
        local summary = CP.Missions.reload()
        CP.warn = realWarn
        H.eq(#summary.builder.edited + #summary.builder.rejected, 0, 'the old file is neither a hand edit nor rejected')
        local live = CP.Missions.get(id)
        H.ok(live ~= nil and live.objectives[1].vehicleRequired == false and live.objectives[1].policeVehicle == nil,
            'loaded: policeVehicle = false is read as vehicleRequired = false')
        local noisy = 0
        for _, line in ipairs(warned) do
            if line:find(id, 1, true) or line:find('policeVehicle', 1, true)
                or line:find('vehicleRequired', 1, true) then
                noisy = noisy + 1
            end
        end
        H.eq(noisy, 0, 'no warning about the old name (' .. table.concat(warned, ' | ') .. ')')
        -- the builder shows it with the new name, and a copy is written with the new name
        local res = H.callback('crimson-police:builder:get', 1, { id = id })
        local rec = res and res.ok and res.data
        H.ok(
            rec and rec.definition.objectives[1].vehicleRequired == false
                and rec.definition.objectives[1].policeVehicle == nil,
            'builder:get shows vehicleRequired = false'
        )
        H.ok(rec and rec.publishedDefinition.objectives[1].vehicleRequired == false, 'the published copy too')
        H.eq(#(rec and rec.errors or { 1 }), 0, 'no guardrail error for the old name')
        local okC, copy = act('duplicate', { id = id })
        local cobj = okC and copy.record.definition.objectives[1]
        H.ok(cobj and cobj.vehicleRequired == false and cobj.policeVehicle == nil, 'its copy uses vehicleRequired')
        local draft = okC and cjson.decode(row(copy.id).draft_definition)
        H.ok(draft and draft.objectives[1].vehicleRequired == false and draft.objectives[1].policeVehicle == nil,
            'the stored copy uses vehicleRequired')
        local lua = okC and B.exportLua(draft, { version = 1, publisher = 'test', at = 0 }) or ''
        H.ok(lua:find('vehicleRequired = false', 1, true) ~= nil and lua:find('policeVehicle', 1, true) == nil,
            'exported with vehicleRequired')
        -- an old draft saved from an outdated tablet is stored with the new name
        local d = U.deepcopy(copy.record.definition)
        d.objectives[1].vehicleRequired = nil
        d.objectives[1].policeVehicle = true
        local okS, saved = act('save', { id = copy.id, definition = d })
        local after = okS and cjson.decode(row(saved.id).draft_definition)
        H.ok(after and after.objectives[1].vehicleRequired == true and after.objectives[1].policeVehicle == nil,
            'a saved policeVehicle is stored as vehicleRequired')
    end

    -- ---- THE START RADIUS OF A search_area MISSION FOLLOWS ITS SEARCH CIRCLE ----
    do
        local okDu, du = act('duplicate', { id = 'manhunt' })
        local d = okDu and du.record.definition
        H.ok(d and d.locations[1].start.radius == 600,
            'the Manhunt copy keeps its 600 m search circle as the start radius')
        local function startErrors(def)
            local out = {}
            for _, e in ipairs(B.validate(def)) do
                if e.key == 'builder.error.start_radius' or e.key == 'builder.error.start_radius_search' then
                    out[#out + 1] = e
                end
            end
            return out
        end
        H.eq(#startErrors(d), 0, 'start radius 600 = startRadius 600: no start-radius error')
        local c = U.deepcopy(d)
        c.locations[2].start.radius = 150
        local e = startErrors(c)
        H.ok(#e == 1 and e[1].path == 'locations.2.start.radius' and e[1].key == 'builder.error.start_radius_search',
            'a start radius other than the search circle is refused at that location')
        c = U.deepcopy(d)
        for _, loc in ipairs(c.locations) do loc.start.radius = 800 end
        c.objectives[1].startRadius = 800
        c.objectives[1].shrinkTo = { 300, 150, 50 }
        H.eq(#startErrors(c), 0, 'start radius and search circle 800 m: allowed (200-1000)')
        c = U.deepcopy(d)
        for _, loc in ipairs(c.locations) do loc.start.radius = 1200 end
        c.objectives[1].startRadius = 1200
        e = startErrors(c)
        H.ok(#e >= 1 and e[1].vars and e[1].vars.min == 200 and e[1].vars.max == 1000,
            'a search circle over 1000 m is refused with the search_area range (' .. messages(e) .. ')')
        -- the default search circle (no startRadius in the objective) counts as 600
        c = U.deepcopy(d)
        c.objectives[1].startRadius = nil
        H.eq(#startErrors(c), 0, 'no startRadius in the objective: the block default 600 is the search circle')
        -- a mission without a search_area keeps the 20-150 m start marker
        local okG, g = act('duplicate', { id = 'gang_shootout' })
        local gd = okG and U.deepcopy(g.record.definition)
        gd.locations[1].start.radius = 600
        e = startErrors(gd)
        H.ok(#e == 1 and e[1].key == 'builder.error.start_radius' and e[1].vars.max == 150,
            'no search_area: a 600 m start radius is still refused (20-150 m)')
        -- builder:config tells the UI both ranges
        local res = H.callback('crimson-police:builder:config', 1)
        local cfg = res and res.ok and res.data
        H.ok(cfg and cfg.startRadius[1] == 20 and cfg.startRadius[2] == 150, 'builder:config: the start-marker range')
        H.ok(cfg and cfg.blocks.search_area.startRadius[1] == 200 and cfg.blocks.search_area.startRadius[2] == 1000,
            'builder:config: the search circle range comes with the blocks')
    end

    -- ---- THE BUILDER UI SHOWS AND ENFORCES THE SAME START RADIUS (static checks of web/src/builder) ----
    do
        local function src(rel)
            local f = io.open(H.root .. 'web/src/builder/' .. rel, 'r')
            if not f then return '' end
            local text = f:read('a')
            f:close()
            return text
        end
        local schema, steps, editor, apply =
            src('schema.ts'), src('steps/StepLocations.tsx'), src('useDraftEditor.ts'), src('applyResult.ts')
        H.ok(
            schema:find('o.block === \'search_area\'', 1, true)
                and schema:find('rangeOf(cfg, \'search_area\', \'startRadius\', [200, 1000, 600])', 1, true),
            'schema.ts: the search circle is the first search_area objective, with the search_area range'
        )
        H.ok(
            steps:find('radiusRange={startRadiusRange(cfg, def)}', 1, true)
                and steps:find('disabled={ro || !!search}', 1, true),
            'Locations step: the start radius shows the search circle and is locked to it'
        )
        H.ok(
            editor:find('syncStartRadius(next, configRef.current, cur)', 1, true)
                and editor:find('startRadiusRange(config, d)', 1, true),
            'editor: every edit keeps the start radii on the search circle; placing a start uses its radius'
        )
        H.ok(apply:find('startRadiusRange(cfg, input)', 1, true), 'placement results are clamped to the same range')
        H.ok(editor:find('syncStartRadius(d, configRef.current)', 1, true),
            'editor: opening an editable draft saved before the rule puts its start radii on the search circle')
    end

    -- ---- THE PUBLISHED COPIES USE ONLY THE BUILDER'S ALLOWED LISTS (none of them needed an exception) ----
    do
        local allowed = Config.Builder.allowed
        local function inList(list, v) return U.contains(list, v) end
        for _, m in ipairs({ 's_m_y_prisoner_01', 's_m_y_prismuscl_01', 'g_m_m_armboss_01' }) do
            H.ok(inList(allowed.peds, m), m .. ' is in Config.Builder.allowed.peds')
        end
        -- the builder's pickers show a name for every allowed model and weapon (builder.name.<value>)
        for _, listKey in ipairs({ 'peds', 'weapons', 'vehicles', 'escortVehicles' }) do
            for _, v in ipairs(allowed[listKey] or {}) do
                H.ok(type(merged['builder.name.' .. v:lower()]) == 'string',
                    ('builder.name.%s (allowed.%s) has a display name'):format(v:lower(), listKey))
            end
        end
    end
end

local okBody, errBody = pcall(Body)
H.sql('DELETE FROM cp_custom_missions')
H.sql('DELETE FROM cp_officers WHERE citizenid = \'SUP00001\'')
os.execute(('rm -rf %s%s'):format(H.root, TMP))
H.ok(okBody, 'spec body ran: ' .. tostring(errBody))
H.ok(not FileExists(TMP), 'temporary mission folder removed')

return H
