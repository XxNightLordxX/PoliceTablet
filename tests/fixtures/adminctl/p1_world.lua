-- The world of the officers-and-boards specs (tests/admin_officers_spec.lua, tests/admin_boards_spec.lua): the real
-- officers, points and boards modules of full admin control on one server, with Qbox stood in for.

return function(H)
    local W = {}
    local cjson = require('cjson')

    -- the merged locale, as locales/en.json is in game
    do
        local merged = {}
        local p = io.popen('ls ' .. H.root .. 'locales/parts/*.json')
        for file in p:lines() do
            local f = io.open(file, 'r')
            local ok, data = pcall(cjson.decode, f:read('a'))
            f:close()
            if ok and type(data) == 'table' then for k, v in pairs(data) do merged[k] = v end end
        end
        p:close()
        local all = CP.Locale.all()
        for k, v in pairs(merged) do all[k] = v end
    end

    W.lines = {}
    local realPrint = print
    W.realPrint = realPrint
    _G.print = function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        local line = table.concat(parts, ' ')
        W.lines[#W.lines + 1] = line
        if not line:find('crimson%-police') and not line:find('Crimson%-Police') then realPrint(line) end
    end

    W.convars = {}
    _G.GetConvar = function(name, default)
        local v = W.convars[name]
        if v == nil then return default end
        return v
    end
    W.posts = {}
    _G.PerformHttpRequest = function(url, cb, method, body)
        W.posts[#W.posts + 1] = { url = url, body = body }
        if cb then cb(204, '', {}) end
    end
    _G.GetPlayerRoutingBucket = function() return 0 end

    -- files the modules write (the banned-words file and its .bak) stay in memory: a spec never changes the tree
    W.files = {}
    local realLoad = _G.LoadResourceFile
    _G.SaveResourceFile = function(_, path, data)
        W.files[path] = data
        return true
    end
    _G.LoadResourceFile = function(res, path)
        if W.files[path] ~= nil then return W.files[path] end
        return realLoad(res, path)
    end

    -- ---- PLAYERS -----------------------------------------------------------

    W.LIC1 = 'license:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1'
    W.LIC9 = 'license:9999999999999999999999999999999999999999'
    W.people = {
        [1] = { cid = 'ADM00001', name = 'Ada Min', license = W.LIC1, job = 'unemployed', grade = 0, ace = true },
        [2] = { cid = 'SUP00002', name = 'Sam Super', license = 'license:b2', job = 'sast', grade = 3 },
        [3] = { cid = 'OFF00003', name = 'Olly Officer', license = 'license:c3', job = 'sast', grade = 1 },
        [4] = { cid = 'OFF00004', name = 'Fay Fed', license = 'license:d4', job = 'fib', grade = 1 },
        [5] = {
            cid = 'ADM00005',
            name = 'Eve Admin',
            license = 'license:e5',
            job = 'unemployed',
            grade = 0,
            ace = true,
        },
        [6] = { cid = 'OFF00006', name = 'Pat Partner', license = 'license:f6', job = 'sast', grade = 1 },
    }
    -- Qbox's players table: characters that are not online
    W.qbox = {
        ALT00001 = W.LIC1,     -- the admin's second character
        OLD00009 = W.LIC9,     -- a deleted character...
        NEW00009 = W.LIC9,     -- ...and the player's new one
        NEW00010 = 'license:other',
    }
    W.offline = {}
    for src, p in pairs(W.people) do
        H.players[src] = { ace = p.ace and { ['crimsonpolice.admin'] = true } or {}, coords = vec3(0.0, 0.0, 0.0) }
    end

    local function Info(src)
        local p = W.people[tonumber(src)]
        if not p or W.offline[tonumber(src)] then return nil end
        return {
            src = tonumber(src),
            citizenid = p.cid,
            license = p.license,
            name = p.name,
            callsign = ('C-%d'):format(src),
            job = {
                name = p.job,
                label = p.job,
                onduty = p.job ~= 'unemployed',
                gradeLevel = p.grade,
                gradeName = 'Rank',
            },
        }
    end
    CP.Qbx = {
        getInfo = Info,
        getByCitizenId = function(cid)
            for src, p in pairs(W.people) do
                if p.cid == cid and not W.offline[src] then return src end
            end
            return nil
        end,
        getOnlinePlayers = function()
            local out = {}
            for src in pairs(W.people) do if not W.offline[src] then out[#out + 1] = src end end
            table.sort(out)
            return out
        end,
        licenseOf = function(cid)
            for _, p in pairs(W.people) do if p.cid == cid then return p.license end end
            return W.qbox[cid]
        end,
        citizenidsOfLicense = function(lic)
            local out = {}
            for cid, l in pairs(W.qbox) do if l == lic then out[#out + 1] = cid end end
            for _, p in pairs(W.people) do if p.license == lic then out[#out + 1] = p.cid end end
            table.sort(out)
            return out
        end,
        characterExists = function(cid)
            if W.qbox[cid] then return true end
            for _, p in pairs(W.people) do if p.cid == cid then return true end end
            return false
        end,
        addMoney = function() return true end,
        onDutyChange = function() end,
        onGroupUpdate = function() end,
        onJobChange = function() end,
        onPlayerLoaded = function() end,
        onPlayerUnload = function() end,
    }

    -- who is on a run now: W.onRun[src] = { id = runUuid }
    W.onRun = {}
    CP.Runs = {
        getBySrc = function(src) return W.onRun[tonumber(src)] end,
    }

    -- ---- THE MODULES -------------------------------------------------------

    for _, m in ipairs({
        'modules/permissions/server.lua',
        'modules/access/server.lua',
        'modules/admin/server.lua',
        'modules/adminkit/server.lua',
        'modules/tablet/server.lua',
        'modules/schedule/server.lua',
        'modules/scoring/server.lua',
        'modules/leaderboard/server.lua',
        'modules/challenge/server.lua',
        'modules/disputes/server.lua',
        'modules/anticheat/server.lua',
        'modules/profile/server.lua',
        'modules/goals/server.lua',
        'modules/payouts/server.lua',
        'modules/cash/server.lua',
        'modules/corrections/server.lua',
    }) do
        H.load(m)
    end
    H.step(0)
    for _ = 1, 3 do H.step(1000) end

    -- ---- HELPERS -----------------------------------------------------------

    local reqSeq = 0
    -- A NUI action as src: ok, data|errKey (the actions that wait for a job are stepped to their answer).
    function W.act(name, src, payload)
        H.clockMs = H.clockMs + 1100   -- stay under every per-second rate limit
        reqSeq = reqSeq + 1
        local reqId = 'p1-' .. reqSeq
        local mark = #H.events
        H.fire('crimson-police:' .. name, src, payload, reqId)
        for _ = 1, 50 do
            for i = #H.events, mark + 1, -1 do
                local e = H.events[i]
                if e.name == 'crimson-police:client:actionResult' and e.args[1] == reqId then
                    return e.args[2], e.args[3]
                end
            end
            H.step(0)
        end
        return nil, 'no reply'
    end

    function W.cb(name, src, args)
        H.clockMs = H.clockMs + 1100
        return H.callback('crimson-police:' .. name, src, args)
    end

    -- The data of a callback (fails the test when it answered an error).
    function W.data(name, src, args)
        local res = W.cb(name, src, args)
        if type(res) ~= 'table' or res.ok == false then
            H.ok(false, ('%s answered %s'):format(name, cjson.encode(res or {})))
            return nil
        end
        return res.data
    end

    local n = 0
    function W.rid()
        n = n + 1
        return ('%08x-0000-4000-8000-%012x'):format(n, 4242)
    end

    -- runs fn in a server thread (the modules wait for the database there) and returns what it returned
    function W.async(fn)
        local res
        CreateThread(function() res = table.pack(fn()) end)
        for _ = 1, 20 do
            if res then break end
            H.step(0)
        end
        return table.unpack(res or {}, 1, res and res.n or 0)
    end

    -- Steps the server until no admin job holds the busy lock.
    function W.drain()
        for _ = 1, 2000 do
            if not CP.AdminKit.busy() then return true end
            H.step(0)
        end
        return false
    end

    function W.count(sql, params)
        local r = H.sql(sql, params)[1]
        if not r then return 0 end
        for _, v in pairs(r) do return math.floor(tonumber(v) or 0) end
        return 0
    end

    function W.one(sql, params) return H.sql(sql, params)[1] end

    -- sql with '?' for each value and NULL for a nil one (a parameter list never has holes)
    local function Ins(head, values)
        local marks, params = {}, {}
        for i = 1, values.n do
            if values[i] == nil then
                marks[i] = 'NULL'
            else
                marks[i] = '?'
                params[#params + 1] = values[i]
            end
        end
        return head:gsub('%$V', table.concat(marks, ', ')), params
    end
    W.ins = Ins

    local runSeq = 0
    function W.uuid()
        runSeq = runSeq + 1
        return ('%08x-1111-4000-8000-%012x'):format(runSeq, 9)
    end

    -- Inserts a run row (cp_mission_runs, or the archive with r.archive) and returns its id. r: citizenid, points,
    -- state, type, mission, department, at (unix time), cash (amount), cashStatus, uuid, flagged, voided, seasonId,
    -- operationId, xpCounted (the XP claim marker; default: counted unless flagged).
    function W.row(r)
        local t = r.archive and 'cp_mission_runs_archive' or 'cp_mission_runs'
        local bd = { cash = { amount = r.cash or 0, status = r.cashStatus or 'none' } }
        if r.xpCounted ~= false and not r.flagged then bd.xpCounted = 1 end
        if r.by then bd.by, bd.reason = r.by, r.reason end
        local sql, params = Ins((
            'INSERT INTO %s (run_uuid, operation_id, mission_type, mission_id, citizenid, '
            .. 'department, season_id, participants, state, end_reason, points_base, final_points, cash_base, '
            .. 'cash_paid, cash_status, breakdown, flagged, voided, created_at) VALUES ($V)'
        ):format(t), table.pack(r.uuid or W.uuid(), r.operationId, r.type or 'patrol', r.mission or 'beat_patrol',
            r.citizenid, r.department or 'sast', r.seasonId, r.participants or 1, r.state or 'completed',
            r.endReason or (r.state or 'completed'), math.max(0, r.points or 60), r.points or 60, r.cash or 0,
            r.cashPaid or 0, r.cashStatus or 'none', cjson.encode(bd), r.flagged and 1 or 0, r.voided and 1 or 0,
            r.at or (H.time - 3600)))
        H.sql(sql:gsub('%?%)$', 'FROM_UNIXTIME(?))'), params)
        return W.count(('SELECT MAX(id) AS n FROM %s'):format(t))
    end

    -- An officer row with the XP its rows give (or xp).
    function W.officer(cid, dept, xp, extra)
        extra = extra or {}
        local sql, params = Ins([[INSERT INTO cp_officers (citizenid, display_name, callsign, department, xp, license)
            VALUES ($V) ON DUPLICATE KEY UPDATE display_name = VALUES(display_name),
            department = VALUES(department), xp = VALUES(xp), license = VALUES(license)]],
            table.pack(cid, extra.name or cid, extra.callsign or 'C-1', dept or 'sast', xp or 0, extra.license))
        H.sql(sql, params)
    end

    function W.xp(cid) return W.count('SELECT xp AS n FROM cp_officers WHERE citizenid = ?', { cid }) end

    -- XP from the rows (what fixXp writes)
    function W.derived(cid) return (W.async(function() return CP.Scoring.derivedXp(cid) end)) end

    function W.auditCount(action, target)
        if target then
            return W.count('SELECT COUNT(*) AS n FROM cp_audit WHERE action = ? AND target = ?', { action, target })
        end
        return W.count('SELECT COUNT(*) AS n FROM cp_audit WHERE action = ?', { action })
    end

    -- every admin may open the Admin UI in these specs
    CP.Tablet.openAdmin = CP.Tablet.openAdmin or function() return true end

    -- the tablet opens for each online player (writes cp_officers.license and the officer rows)
    for src in pairs(W.people) do W.async(function() return CP.Access.refreshOfficerRow(src) end) end

    return W
end
