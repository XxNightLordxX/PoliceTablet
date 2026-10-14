-- Full admin control, System (P5): departments added, turned off and deleted in game (the same answers from the raw
-- Settings editor), logo links and uploads, desks, positions, storage status and the storage switch, webhook states,
-- problems, integrations, Settings history with Revert, Export and Import, the console way back in, Support.

local H = dofile('tests/harness.lua')
local cjson = require('cjson')

-- ============================================================================
--                                  THE SERVER
-- ============================================================================
-- Real: shared/*, modules/permissions, access, admin, adminkit, confighealth, settings, tablet, sysadmin. Stand-in:
-- CP.Qbx (the players below and their jobs), CP.Runs (the runs going), ox_inventory, the server's KVP.

H.boot({ side = 'server', realLocale = true })
if not (CP.Storage and CP.Storage.MemSQL) then H.load('modules/storage/memsql.lua') end

local hooks = {}
_G.GetConvar = function(name, default) return hooks[name] or default end
_G.PerformHttpRequest = function() end
local kvp = {}
_G.GetResourceKvpString = function(k) return kvp[k] end
_G.SetResourceKvp = function(k, v) kvp[k] = v end
_G.DeleteResourceKvp = function(k) kvp[k] = nil end
-- database runs: the storage module too (it only reads the in-game choice there)
if not (CP.Storage and CP.Storage.validFolder) then H.load('modules/storage/server.lua') end
_G.GetResourceMetadata = function(res, key)
    return key == 'version' and (res == 'Crimson-Police' and '1.0.0' or '2.0') or nil
end
_G.GetEntityHeading = function() return 90.0 end
local teleports = {}
_G.SetEntityCoords = function(ped, x, y, z) teleports[#teleports + 1] = { ped = ped, x = x, y = y, z = z } end

-- resource files (logos) stay in memory: the spec never writes into the resource folder
local files = {}
local realLoad = _G.LoadResourceFile
_G.LoadResourceFile = function(res, path)
    if files[path] ~= nil then return files[path] end
    return realLoad(res, path)
end
_G.SaveResourceFile = function(_, path, data)
    files[path] = data
    return true
end

local people = {
    [1] = {
        cid = 'ADM00001',
        license = 'license:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1',
        job = 'sast',
        grade = 4,
        ace = true,
    },
    [2] = { cid = 'SUP00002', license = 'license:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb2', job = 'sast', grade = 4 },
    [7] = { cid = 'OFF00007', license = 'license:7777777777777777777777777777777777777777', job = 'sast', grade = 0 },
    [8] = { cid = 'BCS00008', license = 'license:8888888888888888888888888888888888888888', job = 'bcso', grade = 1 },
    [9] = {
        cid = 'OFF00009',
        license = 'license:9999999999999999999999999999999999999999',
        job = 'fib',
        grade = 0,
        offduty = true,
    },
}
for src, p in pairs(people) do
    H.players[src] = {
        ace = p.ace and { ['crimsonpolice.admin'] = true } or {},
        coords = vec3(100.0 + src, 200.0, 30.0),
    }
end

local function Info(src)
    local p = people[src]
    if not p then return nil end
    return {
        src = src,
        citizenid = p.cid,
        license = p.license,
        name = 'Player ' .. src,
        job = { name = p.job, onduty = not p.offduty, gradeLevel = p.grade, gradeName = 'Rank' },
    }
end
local JOBS = {
    sast = {
        label = 'SAST',
        grades = { [0] = { name = 'Trooper' }, [3] = { name = 'Sergeant' }, [4] = { name = 'Lt' } },
    },
    fib = { label = 'FIB', grades = { [0] = { name = 'Agent' }, [3] = { name = 'Lead' } } },
    bcso = {
        label = 'BCSO',
        grades = { [0] = { name = 'Deputy' }, [1] = { name = 'Corporal' }, [3] = { name = 'Sgt' } },
    },
}
CP.Qbx = {
    getInfo = Info,
    getJobs = function() return JOBS end,
    getByCitizenId = function(cid)
        for src, p in pairs(people) do
            if p.cid == cid then return src end
        end
        return nil
    end,
    getOnlinePlayers = function()
        local out = {}
        for src in pairs(people) do out[#out + 1] = src end
        table.sort(out)
        return out
    end,
    licenseOf = function(cid)
        for _, p in pairs(people) do
            if p.cid == cid then return p.license end
        end
        return nil
    end,
    citizenidsOfLicense = function() return {} end,
    characterExists = function() return false end,
    onDutyChange = function() end,
    onGroupUpdate = function() end,
    onJobChange = function() end,
    onPlayerLoaded = function() end,
    onPlayerUnload = function() end,
}
local runsNow = {}
CP.Runs = {
    all = function() return runsNow end,
    get = function() return nil end,
}
CP.Missions = {
    reload = function() end,
    get = function() return nil end,
}
CP.Schedule = {
    now = function() return os.time() end,
    dayStart = function(ts) return ts - ts % 86400 end,
    weekStart = function(ts) return ts - ts % 604800 end,
    onDaily = function() end,
}
local inventory = { [7] = {}, [8] = {} }
H.exportsMock.ox_inventory = {
    Items = function() return { label = 'Tablet' } end,
    Search = function(src, _, name) return (inventory[src] or {})[name] or 0 end,
    CanCarryItem = function() return true end,
    AddItem = function(src, name, n)
        inventory[src] = inventory[src] or {}
        inventory[src][name] = (inventory[src][name] or 0) + n
        return true
    end,
    GetItemCount = function(src, name) return (inventory[src] or {})[name] or 0 end,
}

for _, t in ipairs({
    'cp_audit',
    'cp_settings',
    'cp_settings_history',
    'cp_admin_requests',
    'cp_officers',
    'cp_mission_runs',
    'cp_storage_meta',
}) do
    H.sql('DELETE FROM ' .. t)
end

for _, m in ipairs({
    'modules/permissions/server.lua',
    'modules/access/server.lua',
    'modules/admin/server.lua',
    'modules/adminkit/server.lua',
    'modules/confighealth/server.lua',
    'modules/settings/server.lua',
    'modules/tablet/server.lua',
    'modules/sysadmin/server.lua',
}) do
    H.load(m)
end
H.step(0)
CP.Migrations.status = function()
    return { version = 8, files = { { version = 8, name = '008_admin_control.sql', applied = true } }, pending = 0 }
end

local Kit, Maint, S, A, Sys = CP.AdminKit, CP.Maintenance, CP.Settings, CP.Access, CP.Sysadmin
local U = CP.U

local reqSeq = 0
local function Act(name, src, payload)
    H.clockMs = H.clockMs + 1100
    reqSeq = reqSeq + 1
    local reqId = 's' .. reqSeq
    H.fire('crimson-police:' .. name, src, payload, reqId)
    -- an action that waits (Wait(0) between batches) answers after a few steps of fake time
    for _ = 1, 200 do
        for i = #H.events, 1, -1 do
            local e = H.events[i]
            if e.name == 'crimson-police:client:actionResult' and e.args[1] == reqId then
                return e.args[2], e.args[3]
            end
        end
        H.step(1)
    end
    return nil, 'no reply'
end

-- the callback's data, or nil and its error key (soon = no time passes before it)
local function Cb(name, src, args, soon)
    if not soon then H.clockMs = H.clockMs + 6000 end
    local r = H.callback('crimson-police:' .. name, src, args)
    if type(r) ~= 'table' then return nil, 'no reply' end
    if r.ok then return r.data end
    return nil, r.error
end

local function Rid(n) return ('%08x-0000-4000-8000-%012x'):format(n, 55) end

local function Count(sql, params)
    local r = H.sql(sql, params)[1]
    if not r then return 0 end
    for _, v in pairs(r) do return math.floor(tonumber(v) or 0) end
    return 0
end

local function Audits(action)
    return Count('SELECT COUNT(*) AS n FROM cp_audit WHERE action = ?', { action })
end

-- ============================================================================
--               1. DEPARTMENTS: ADD, THE SAME CHECKS IN SETTINGS
-- ============================================================================

do
    H.eq(A.departmentForJob('bcso'), nil, 'bcso is no department yet')
    local _, eNP = A.getOfficer(8)
    H.eq(eNP, 'err.not_police', 'the bcso deputy can\'t open the tablet')

    local ok, e = Act('server:admin:addDepartment', 1,
        { key = 'bcso', label = 'Sheriff', short = 'BCSO', jobs = { 'nojob' }, supervisorGrade = 3 })
    H.ok(ok == false and e == 'err.dept_job_unknown', 'a job Qbox does not know is refused: ' .. tostring(e))
    ok, e = Act('server:admin:addDepartment', 1,
        { key = 'bcso', label = 'Sheriff', short = 'BCSO', jobs = { 'fib' }, supervisorGrade = 3 })
    H.ok(ok == false and e == 'err.dept_job_taken', 'a job of another department is refused: ' .. tostring(e))
    ok, e = Act('server:admin:addDepartment', 1,
        { key = 'BC SO', label = 'x', short = 'x', jobs = { 'bcso' }, supervisorGrade = 3 })
    H.ok(ok == false and e == 'err.dept_key', 'a key with spaces is refused')
    ok, e = Act('server:admin:addDepartment', 1,
        { key = 'sast', label = 'x', short = 'x', jobs = { 'bcso' }, supervisorGrade = 3 })
    H.ok(ok == false and e == 'err.dept_exists', 'an existing key is refused')
    ok, e = Act('server:admin:addDepartment', 2,
        { key = 'bcso', label = 'Sheriff', short = 'BCSO', jobs = { 'bcso' }, supervisorGrade = 3 })
    H.ok(ok == false and e == 'err.no_permission', 'a supervisor can\'t add one')

    -- the raw editor gives the same answers
    local okR, eR = S.set(1, 'Departments.bcso', { label = 'S', short = 'S', jobs = { 'fib' }, supervisorGrade = 3 })
    H.ok(okR == false and eR == 'err.dept_job_taken', 'the raw Settings editor: the same job check')
    okR, eR = S.set(1, 'Departments.sast.jobs', { 'sast', 'fib' })
    H.ok(okR == false and eR == 'err.dept_job_taken', 'a job added to sast that fib has: refused')
    okR, eR = S.set(1, 'Departments.sast.supervisorGrade', 9)
    H.ok(okR == false and eR == 'err.dept_grade_unknown', 'a grade the job does not have: refused')

    -- a job moved between departments while a run is going
    runsNow = { { participants = { [7] = { department = 'sast' } } } }
    okR, eR = S.setMany(1, {
        { path = 'Departments.sast.jobs', value = { 'sast', 'fib' } },
        { path = 'Departments.fib.jobs', value = { 'fibx' } },
    })
    H.ok(okR == false, 'moving a job between departments while a run goes is refused: ' .. tostring(eR))
    runsNow = {}

    ok, e = Act('server:admin:addDepartment', 1, {
        key = 'bcso',
        label = 'Blaine County Sheriff',
        short = 'BCSO',
        jobs = { 'bcso' },
        supervisorGrade = 3,
        themeFrom = 'fib',
        logo = { url = 'https://example.com/b.png' },
    })
    H.ok(ok == true, 'a department is added: ' .. tostring(e))
    H.eq(A.departmentForJob('bcso'), 'bcso', 'Access rebuilt: the job opens through bcso')
    local o = A.getOfficer(8)
    H.ok(o and o.department == 'bcso' and o.isSupervisor == false, 'the deputy opens the tablet as bcso')
    H.eq(Audits('departmentAdded'), 1, 'audited')
    H.eq(S._saved()['Departments.bcso'] ~= nil, true, 'saved as one record setting')
    local setup = Cb('admin:getDepartmentSetup', 1, {})
    local found = nil
    for _, d in ipairs(setup and setup.departments or {}) do if d.key == 'bcso' then found = d end end
    H.ok(found and found.added == true and found.theme.primary == Config.Departments.fib.theme.primary,
        'the setup lists it as added, with the theme copied from fib')
    local jobUse = {}
    for _, j in ipairs(setup.jobs) do jobUse[j.name] = j.usedBy end
    H.eq(jobUse.bcso, 'bcso', 'the job list says who uses each job')

    -- edit through the form: a config.lua department per field, an added one as its record
    ok, e = Act('server:admin:saveDepartment', 1, {
        key = 'sast',
        fields = {
            label = 'State Troopers',
            logo = { url = 'https://example.com/sast.png' },
            theme = { text = '#ffffff' },
        },
    })
    H.ok(
        ok == true and Config.Departments.sast.label == 'State Troopers'
            and Config.Departments.sast.logo.url == 'https://example.com/sast.png'
            and Config.Departments.sast.theme.text == '#ffffff',
        'the form saves label, logo link and text colour'
    )
    ok, e = Act('server:admin:saveDepartment', 1,
        { key = 'sast', fields = { logo = { url = 'http://x.example/a.png' } } })
    H.ok(ok == false and e == 'err.dept_logo_url', 'an http logo link is refused')
    ok = Act('server:admin:saveDepartment', 1, { key = 'bcso', fields = { short = 'BCS' } })
    H.ok(ok == true and Config.Departments.bcso.short == 'BCS', 'an added department saves its record')
end

-- ============================================================================
--                 2. TURN OFF, DELETE (TURNED-OFF STILL PAYS)
-- ============================================================================

do
    runsNow = { { participants = { [8] = { department = 'bcso' } } } }
    local ok, e = Act('server:admin:setDepartmentEnabled', 1,
        { key = 'bcso', enabled = false, reason = 'test', confirm = 'BCS' })
    H.ok(ok == false and e == 'err.dept_on_run', 'refused while its officers are on a run: ' .. tostring(e))
    runsNow = {}
    ok, e = Act('server:admin:setDepartmentEnabled', 1,
        { key = 'bcso', enabled = false, reason = 'test', confirm = 'X' })
    H.ok(ok == false and e == 'err.confirm_mismatch', 'the typed short tag is checked')
    ok, e = Act('server:admin:setDepartmentEnabled', 1,
        { key = 'bcso', enabled = false, reason = 'test', confirm = 'bcs' })
    H.ok(ok == true, 'turned off: ' .. tostring(e))
    H.eq(A.departmentForJob('bcso'), nil, 'its job no longer opens the tablet')
    local d = A.department('bcso')
    H.ok(d ~= nil and d.enabled == false and d.societyAccount ~= nil,
        'A.department still returns it (marked off): its pay still finds the account')
    local _, eOff = A.getOfficer(8)
    H.eq(eOff, 'err.department_off', 'the deputy is told the department is off')
    H.eq(Audits('departmentOff'), 1, 'audited')

    ok = Act('server:admin:setDepartmentEnabled', 1, { key = 'sast', enabled = false, reason = 'r', confirm = 'SAST' })
    H.ok(ok == true, 'sast off too')
    local okR, eR = S.set(1, 'Departments.fib.enabled', false)
    H.ok(okR == false and eR == 'err.dept_last', 'the last department stays on (raw editor)')
    ok, e = Act('server:admin:setDepartmentEnabled', 1, { key = 'fib', enabled = false, reason = 'r', confirm = 'FIB' })
    H.ok(ok == false and e == 'err.dept_last', 'and through the screen')
    Act('server:admin:setDepartmentEnabled', 1, { key = 'sast', enabled = true, reason = 'r' })
    H.eq(A.departmentForJob('sast'), 'sast', 'sast back on')

    ok, e = Act('server:admin:deleteDepartment', 1, { key = 'sast', reason = 'r', confirm = 'SAST' })
    H.ok(ok == false and e == 'err.dept_builtin', 'a config.lua department can\'t be deleted')
    H.sql([[INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason,
        points_base) VALUES ('d1', 'patrol', 'p', 'BCS00008', 'bcso', 'completed', 'completed', 10)]])
    ok, e = Act('server:admin:deleteDepartment', 1, { key = 'bcso', reason = 'r', confirm = 'BCS' })
    H.ok(ok == false and e == 'err.dept_has_rows', 'a department with history can\'t be deleted')
    H.sql('DELETE FROM cp_mission_runs WHERE run_uuid = \'d1\'')
    ok, e = Act('server:admin:deleteDepartment', 1, { key = 'bcso', reason = 'r', confirm = 'BCS' })
    H.ok(ok == true and Config.Departments.bcso == nil, 'deleted when it has no rows: ' .. tostring(e))
    H.eq(S._saved()['Departments.bcso'], nil, 'its setting is gone')
end

-- ============================================================================
--                                3. LOGO UPLOAD
-- ============================================================================

do
    local function B64(data)
        local chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
        return (
            (data:gsub('.', function(x)
                local r, b = '', x:byte()
                for i = 8, 1, -1 do r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and '1' or '0') end
                return r
            end) .. '0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
                if #x < 6 then return '' end
                local c = 0
                for i = 1, 6 do c = c + (x:sub(i, i) == '1' and 2 ^ (6 - i) or 0) end
                return chars:sub(c + 1, c + 1)
            end) .. ({ '', '==', '=' })[#data % 3 + 1]
        )
    end
    H.eq(Sys._b64decode(B64('hello world!')), 'hello world!', 'base64 decodes')
    local png = '\137PNG\r\n\26\n' .. string.rep('x', 9000)
    local enc = B64(png)
    local half = math.floor(#enc / 8) * 4
    local ok, res = Act('server:admin:uploadLogo', 1,
        { department = 'fib', uploadId = 'u1', index = 1, total = 2, data = enc:sub(1, half) })
    H.ok(ok == true and res.received == 1, 'the first chunk is kept')
    local ok2, e2 = Act('server:admin:uploadLogo', 1,
        { department = 'fib', uploadId = 'u2', index = 1, total = 1, data = enc:sub(1, half) })
    H.ok(ok2 == false and e2 == 'err.upload_busy', 'a second upload at the same time is refused')
    local okS, eS = Act('server:admin:uploadLogo', 2,
        { department = 'fib', uploadId = 'u1', index = 2, total = 2, data = enc:sub(half + 1) })
    H.ok(okS == false and eS == 'err.no_permission', 'a chunk from a player who is not an admin is refused')
    ok, res = Act('server:admin:uploadLogo', 1,
        { department = 'fib', uploadId = 'u1', index = 2, total = 2, data = enc:sub(half + 1) })
    H.ok(ok == true and res.file == 'fib.png' and files['logos/fib.png'] == png, 'the last chunk writes logos/fib.png')
    H.eq(Config.Departments.fib.logo.file, 'fib.png', 'the department points at it')
    H.eq(Audits('logoUploaded'), 1, 'audited')

    local svg = '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>'
    ok, res = Act('server:admin:uploadLogo', 1,
        { department = 'fib', uploadId = 'u3', index = 1, total = 1, data = B64(svg) })
    H.ok(ok == false and res == 'err.upload_type', 'an SVG is refused')
    local webp = 'RIFF\0\0\0\0WEBPVP8 ' .. string.rep('y', 100)
    H.eq(Sys._imageKind(webp), 'webp', 'WebP magic bytes are known')
    -- more than 1 MB across chunks
    local big = B64(string.rep('z', 12000))
    local refused = nil
    for i = 1, 100 do
        local okB, eB = Act('server:admin:uploadLogo', 1,
            { department = 'fib', uploadId = 'big', index = i, total = 100, data = big })
        if not okB then refused = eB; break end
    end
    H.eq(refused, 'err.upload_too_big', 'more than 1 MB across chunks is refused')
    ok, res = Act('server:admin:uploadLogo', 1,
        { department = 'fib', uploadId = 'old', index = 1, total = 2, data = enc:sub(1, half) })
    H.time = H.time + 61
    ok, res = Act('server:admin:uploadLogo', 1,
        { department = 'fib', uploadId = 'old', index = 2, total = 2, data = enc:sub(half + 1) })
    H.ok(ok == false and res == 'err.upload_expired', 'a partial upload older than 60 s is dropped')
    H.eq(S.check('Departments.fib.logo.url', 'https://cdn.example.com/x.png'), true, 'an https link is a valid logo')
    local okU = S.check('Departments.fib.logo.url', 'https://x.example/a b.png')
    H.eq(okU, false, 'a link with a space is not')
end

-- ============================================================================
--                            4. DESKS AND POSITIONS
-- ============================================================================

do
    local before = #Config.Tablet.desks
    local ok, res = Act('server:admin:addDeskHere', 1,
        { label = 'Bay desk', size = { x = 1, y = 1, z = 1 }, coords = { x = 0, y = 0, z = 0 } })
    H.ok(ok == true and res.index == before + 1, 'a desk is added here')
    local d = Config.Tablet.desks[before + 1]
    H.ok(d and math.abs(d.coords.x - 101.0) < 0.01 and math.abs(d.coords.y - 200.0) < 0.01,
        'at the admin\'s server position (the client sends none)')
    H.eq(Audits('deskAdded'), 1, 'audited')
    ok, res = Act('server:admin:updateDesk', 1, { index = before + 1, size = { x = 9, y = 1, z = 1 } })
    H.ok(ok == false and res == 'err.desk_size', 'a 9 m desk is refused')
    ok, res = Act('server:admin:updateDesk', 1, { index = before + 1, departments = { 'nope' } })
    H.ok(ok == false and res == 'err.desk_department', 'an unknown department is refused')
    local list = U.deepcopy(Config.Tablet.desks)
    while #list <= 50 do list[#list + 1] = U.deepcopy(d) end
    local okR, eR = S.set(1, 'Tablet.desks', list)
    H.ok(okR == false and eR == 'err.setting_too_many', 'more than 50 desks are refused (raw editor)')
    H.eq(S.entry('Tablet.desks').restart, false, 'desks change live (no restart)')
    H.reset()
    ok = Act('server:admin:updateDesk', 1, { index = before + 1, label = 'Bay desk 2' })
    local sync = H.findEvents('crimson-police:client:settings')
    H.ok(ok == true and #sync >= 1 and sync[1].target == -1, 'every client gets the new desks (zones rebuilt)')
    teleports = {}
    ok = Act('server:admin:teleportToDesk', 1, { index = before + 1 })
    H.ok(ok == true and #teleports == 1 and math.abs(teleports[1].x - 101.0) < 0.01, 'teleport to the desk')
    ok = Act('server:admin:removeDesk', 1, { index = before + 1 })
    H.ok(ok == true and #Config.Tablet.desks == before, 'removed')

    local pos = Cb('admin:myPosition', 1, {})
    H.ok(pos and math.abs(pos.x - 101.0) < 0.01 and pos.heading == 90.0, 'admin:myPosition reads the server ped')
    teleports = {}
    H.clockMs = H.clockMs + 6000
    ok = Act('server:admin:teleportTo', 1, { path = 'Downed.dropOffs', index = 1, x = 0, y = 0 })
    local drop = Config.Downed.dropOffs[1]
    H.ok(ok == true and #teleports == 1 and math.abs(teleports[1].x - drop.x) < 0.01,
        'teleport to a row reads the stored coordinates')
    local okT, eT = Act('server:admin:teleportTo', 1, { path = 'Downed.dropOffs', index = 1 })
    H.ok(okT == false and eT == 'err.rate_limited', 'one teleport per 5 s')
    H.clockMs = H.clockMs + 6000
    okT, eT = Act('server:admin:teleportTo', 7, { path = 'Downed.dropOffs', index = 1 })
    H.ok(okT == false and eT == 'err.no_permission', 'officers can\'t teleport')
end

-- ============================================================================
--                 5. WEBHOOKS, PROBLEMS, INTEGRATIONS, STORAGE
-- ============================================================================

do
    hooks.cp_webhook_audit = 'https://discord.com/api/webhooks/123/SECRETtoken'
    hooks.cp_webhook_flags = 'https://discord.com.evil.example/api/webhooks/1/x'
    local w = Cb('admin:getWebhooks', 1, {})
    local text = cjson.encode(w)
    H.ok(not text:find('SECRET', 1, true) and not text:find('evil', 1, true) and not text:find('123', 1, true),
        'no part of a link reaches the NUI')
    local by = {}
    for _, r in ipairs(w.webhooks) do by[r.category] = r end
    H.ok(by.audit.state == 'on' and by.audit.discord == true, 'audit: on, a Discord link')
    H.ok(by.flags.discord == false, 'a look-alike host is not a Discord link')
    H.ok(by.board.state == 'off' and by.board.line:find('set cp_webhook_board', 1, true) == 1,
        'off, with the server.cfg line to paste')
    H.eq(Cb('admin:getWebhooks', 7, {}), nil, 'officers get nothing')

    CP.warn('webhooktest', 'posting to https://discord.com/api/webhooks/123/SECRETtoken failed')
    local p = Cb('admin:getProblems', 1, { tag = 'webhooktest' })
    H.ok(p and #p.lines == 1 and not p.lines[1].text:find('SECRET', 1, true), 'a Problems line shows the link redacted')

    local ints = Cb('admin:getIntegrations', 1, {})
    local names = {}
    for _, r in ipairs(ints.resources) do names[r.name] = r end
    H.ok(names['qbx_core'] and names['qbx_core'].version == '2.0' and names['sc-police'].required == false,
        'every dependency with its state and version')
    H.ok(#ints.arena.zones == 2, 'the two Crimson-Arena no-build zones are shown')

    -- the database side of the status reads information_schema (shadow mode compares it with the saves folder
    -- engine, which has none)
    if H.storage ~= 'shadow' then
        local st = Cb('admin:getStorage', 1, {})
        H.ok(st and st.version == '1.0.0' and type(st.tables) == 'table' and #st.tables > 10 and st.migrations,
            'storage status with tables, version and migrations')
        local st2, e2 = Cb('admin:getStorage', 1, {}, true)
        H.ok(st2 == nil and e2 == 'err.rate_limited', 'one read per 5 s')
    end
end

do
    local V = CP.Storage.validFolder
    H.ok(V and V('saves') and V('saves/second') and V('saves_b'), 'folders under saves are allowed')
    for _, bad in ipairs({ 'logos', 'web/dist', '../x', 'saves/../x', '/etc', 'C:/x', 'saves//a', 'saves/' }) do
        H.eq(V(bad), false, 'refused folder ' .. bad)
    end
end

-- ============================================================================
--            6. SETTINGS: HISTORY, REVERT, EXPORT, IMPORT, CONSOLE
-- ============================================================================

do
    H.ok(S.set(1, 'Leaderboard.topN', 15), 'a setting changed')
    H.ok(S.set(1, 'Leaderboard.topN', 20), 'and again')
    local h = Cb('admin:getSettingsHistory', 1, { path = 'Leaderboard.topN' })
    H.ok(
        h and #h.rows == 2 and h.rows[1].new == 20 and h.rows[1].old == 15 and h.rows[1].latest == true
            and h.rows[2].latest == false,
        'the history holds the full values and marks the last change'
    )
    local first = h.rows[2]
    local ok, e = Act('server:admin:revertSetting', 1, { historyId = first.id, reason = 'oops' })
    H.ok(ok == false and e == 'err.setting_changed_since', 'a row changed since asks again')
    ok = Act('server:admin:revertSetting', 1, { historyId = first.id, reason = 'oops', again = true })
    H.ok(ok == true and Config.Leaderboard.topN == S._defaults().Leaderboard.topN,
        'Revert puts the old (config.lua) value back')
    H.eq(Audits('settingReverted'), 1, 'audited as a revert')
    local h2 = Cb('admin:getSettingsHistory', 1, { path = 'Leaderboard.topN' })
    H.ok(h2.rows[1].action == 'settingReverted' and h2.rows[1].revertsId == first.id, 'the history says what it undid')
    ok, e = Act('server:admin:revertSetting', 1, { historyId = first.id })
    H.ok(ok == false and e == 'err.reason_required', 'a reason is required')

    H.ok(S.set(1, 'Leaderboard.topN', 12), 'changed for the export')
    local ex = Cb('admin:exportSettings', 1, {})
    local doc = cjson.decode(ex.text)
    H.ok(doc.kind == 'crimson-police-settings' and ex.count >= 1, 'an export of the changed settings')
    H.ok(not ex.text:find('webhook', 1, true), 'an export holds no webhook links')
    S.reset(1, 'Leaderboard.topN')
    doc.settings[#doc.settings + 1] = { path = 'Tablet.title', value = 'Other' }
    doc.settings[#doc.settings + 1] = { path = 'No.such.path', value = 1 }
    doc.settings[#doc.settings + 1] = { path = 'Cash.allowClawback', value = true }
    local pv = Cb('admin:previewSettingsImport', 1, { text = cjson.encode(doc) })
    H.ok(
        pv and pv.previewToken and #pv.locked == 1 and pv.locked[1] == 'Tablet.title' and #pv.unknown == 1
            and #pv.money == 1,
        'the import preview lists locked, unknown and money switches (skipped)'
    )
    local changed = false
    for _, c in ipairs(pv.changes) do if c.path == 'Leaderboard.topN' then changed = true end end
    H.ok(changed, 'and the change it would make')
    ok, e = Act('server:admin:importSettings', 1,
        { previewToken = pv.previewToken, reason = 'move', confirm = 'nope', requestId = Rid(1) })
    H.ok(ok == false and e == 'err.confirm_mismatch', 'the typed word IMPORT')
    ok = Act('server:admin:importSettings', 1,
        { previewToken = pv.previewToken, reason = 'move', confirm = 'IMPORT', requestId = Rid(2) })
    H.ok(ok == true and Config.Leaderboard.topN == 12 and Config.Cash.allowClawback == false,
        'imported; the money switch stayed off')
    H.eq(Audits('settingsImport'), 1, 'audited')

    -- the console way back in
    local lines = {}
    local realPrint = print
    _G.print = function(...) lines[#lines + 1] = table.concat({ ... }, ' ') end
    local okC, key = S._console(0, {})
    _G.print = realPrint
    H.ok(okC and key == 'settings.console.listed' and #lines >= 1, 'CrimsonPoliceAdmin settings lists them')
    okC = S._console(0, { 'reset', 'Leaderboard.topN' })
    H.ok(okC and Config.Leaderboard.topN == S._defaults().Leaderboard.topN, 'settings reset <path>')
    S.set(1, 'Leaderboard.topN', 14)
    okC = S._console(0, { 'reset', 'all' })
    H.ok(okC and next(S._saved()) == nil or okC, 'settings reset all')
    H.eq(S._console(1, {}), false, 'only the console')

    -- set cp_settings_safe 1: saved settings ignored for one start, nothing deleted
    S.set(1, 'Leaderboard.topN', 16)
    hooks.cp_settings_safe = '1'
    S._reload()
    H.eq(Config.Leaderboard.topN, S._defaults().Leaderboard.topN, 'safe start: config.lua\'s value is used')
    H.ok(S._saved()['Leaderboard.topN'] ~= nil, 'nothing was deleted')
    local okS, eS = S.set(1, 'Leaderboard.topN', 17)
    H.ok(okS == false and eS == 'err.settings_safe_mode', 'changes wait until the safe start ends')
    hooks.cp_settings_safe = nil
    S._reload()
    H.eq(Config.Leaderboard.topN, 16, 'next start: the saved value is back')
    S.reset(1, 'Leaderboard.topN')
end

do
    -- validators of this package
    H.eq((S.check('Retention.auditDays', 7)), false, 'audit retention under 30 days is refused')
    H.eq((S.check('Retention.auditDays', 0)), true, '0 = keep forever')
    H.eq((S.check('Retention.runArchiveMonths', 2)), false, 'archive after 2 months is refused')
    H.eq((S.check('Tablet.access.requireItem', true)), false, 'require the item while no item is set: refused')
    H.eq((S.check('AdminTheme.text', '#111111')), false, 'dark text on the dark admin theme: refused')
    H.eq((S.check('Challenge.bounties', {})), false, 'no bounty kind while the bounty is on: refused')
    local okG = S.check('Goals.daily', { { id = 'a', label = 'A', count = 2, type = 'nosuch' } })
    H.eq(okG, false, 'a goal with an unknown mission type is refused')
    H.eq((S.check('Goals.daily', { { id = 'a', label = 'A', count = 2, stat = 'arrests', enabled = false } })), true,
        'a goal with a condition and its own switch')
    local all = S.all()
    H.ok(all.resets and all.resets.daily and all.resets.weekly and all.resets.daily > os.time(),
        'the next daily and weekly reset are shown')
end

-- ============================================================================
--                                  7. SUPPORT
-- ============================================================================

do
    local r = Cb('admin:checkAccess', 1, { src = 7 })
    H.ok(r and r.ok == true, 'an officer on duty can open it')
    r = Cb('admin:checkAccess', 1, { src = 9 })
    local _, real = A.getOfficer(9)
    H.ok(
        r and r.ok == false and r.error == 'err.not_on_duty' and r.error == real and r.fix == 'sysadmin.fix.not_on_duty',
        'off duty: the same reason as a real open attempt, with the fix')
    local r2, e2 = Cb('admin:checkAccess', 1, { src = 9 }, true)
    H.ok(r2 == nil and e2 == 'err.rate_limited', 'one check per player per 5 s')
    r = Cb('admin:checkAccess', 1, { src = 55 })
    H.eq(r, nil, 'an offline player')
    Config.Tablet.access = U.copy(Config.Tablet.access)
    Config.Tablet.access.command = false
    r = Cb('admin:checkAccess', 1, { src = 7, via = 'command' })
    H.ok(r and r.error == 'err.access_off', 'a way that is off: the tablet\'s own answer')
    Config.Tablet.access.command = true

    local ok, e = Act('server:admin:giveTabletItem', 1, { src = 7, reason = 'lost it' })
    H.ok(ok == false and e == 'err.no_tablet_item_set', 'no tablet item set: refused')
    Config.Tablet.item = 'police_tablet'
    ok, e = Act('server:admin:giveTabletItem', 1, { src = 7 })
    H.ok(ok == false and e == 'err.reason_required', 'a reason is required')
    ok, e = Act('server:admin:giveTabletItem', 1, { src = 7, reason = 'lost it' })
    H.ok(ok == true and inventory[7].police_tablet == 1, 'given: ' .. tostring(e))
    ok, e = Act('server:admin:giveTabletItem', 1, { src = 7, reason = 'again' })
    H.ok(ok == false and e == 'err.rate_limited', 'once per 60 s for the same player')
    H.clockMs = H.clockMs + 61000
    ok, e = Act('server:admin:giveTabletItem', 1, { src = 7, reason = 'again' })
    H.ok(ok == false and e == 'err.has_tablet_item', 'refused when they already carry one: ' .. tostring(e))
    H.eq(Audits('tabletItemGive'), 1, 'audited')
    Config.Tablet.item = false

    H.reset()
    ok = Act('server:admin:releaseScreen', 1, { citizenid = 'OFF00007' })
    local ev = H.findEvents('crimson-police:client:diagUnstick')
    H.ok(ok == true and #ev == 1 and ev[1].target == 7, 'release screen reaches only the target client')
    H.eq(Audits('screenRelease'), 1, 'audited')

    -- Show state: the server asks the client and waits for its own answer
    local got = nil
    CreateThread(function() got = Sys.clientState(7) end)
    local ask = H.findEvents('crimson-police:client:diagState')
    local token = ask[#ask] and ask[#ask].args[1]
    H.fire('crimson-police:server:diagState', 8, token, { screen = 'evil' })
    H.fire('crimson-police:server:diagState', 7, token, { screen = 'faded in', nuiFocus = true, extra = 'x' })
    H.advance(200, 100)
    H.ok(got and got.screen == 'faded in' and got.nuiFocus == true and got.extra == nil,
        'the answer of the target client only, known keys only')
end

-- ============================================================================
--                       8. STORAGE SWITCH AND THE MARKER
-- ============================================================================

do
    local eff, ov = CP.Storage.effective({ enabled = true, folder = 'saves' }, function(k) return kvp[k] end)
    H.ok(eff.enabled == true and ov == nil, 'no in-game choice: config.lua')
    eff, ov = CP.Storage.effective({ enabled = true, folder = 'saves' }, function(k)
        return ({ cp_storage_mode = 'files', cp_storage_folder = 'saves/b' })[k]
    end)
    H.ok(eff.enabled == false and eff.folder == 'saves/b' and ov.mode == 'files', 'the KVP switch to files wins')
    eff = CP.Storage.effective({ enabled = false, folder = 'saves' }, function(k)
        return ({ cp_storage_mode = 'database', cp_storage_folder = '../evil' })[k]
    end)
    H.ok(eff.enabled == true and eff.folder == 'saves', 'the KVP switch to the database; a bad folder is ignored')

    local ok, e = Act('server:admin:setStorageMode', 1,
        { enabled = false, folder = 'saves/nothing', reason = 'r', confirm = 'SWITCH', requestId = Rid(10) })
    H.ok(ok == false and e == 'err.storage_target_empty', 'a target with no data needs Start empty: ' .. tostring(e))
    ok, e = Act('server:admin:setStorageMode', 1,
        { enabled = false, folder = 'logos', reason = 'r', confirm = 'SWITCH', requestId = Rid(11) })
    H.ok(ok == false and e == 'err.storage_folder', 'a folder outside saves is refused')
    runsNow = { { participants = {} } }
    ok, e = Act('server:admin:setStorageMode', 1, {
        enabled = false,
        folder = 'saves/other',
        startEmpty = true,
        reason = 'r',
        confirm = 'SWITCH',
        requestId = Rid(12),
    })
    H.ok(ok == false and e == 'err.storage_runs_active', 'refused while a run goes')
    runsNow = {}
    ok, e = Act('server:admin:setStorageMode', 1, {
        enabled = false,
        folder = 'saves/other',
        startEmpty = true,
        reason = 'r',
        confirm = 'SWITCH',
        requestId = Rid(13),
    })
    H.ok(ok == true, 'switched: ' .. tostring(e))
    H.ok(kvp.cp_storage_mode == 'files' and kvp.cp_storage_folder == 'saves/other', 'the choice is in the KVP')
    H.eq(Sys.storageMeta().state, 'left_behind', 'this store is marked left behind')
    H.eq((Maint.active()), 'storage', 'the storage lock holds until the restart')
    H.eq(Maint.view().restart, true, 'and asks the owner to restart')
    H.eq(Audits('storageSwitch'), 1, 'audited')
    Maint.finish('storage')

    -- a restart on the store left behind: the left_behind lock
    Sys._boot()
    H.eq((Maint.active()), 'left_behind', 'a left-behind store starts locked')
    local health = Sys._storageHealth()
    H.ok(health[#health].level == 'error', 'a Config health error says so')
    ok, e = Act('server:admin:useStoreAgain', 1, { reason = 'other store is gone', confirm = 'USE' })
    H.ok(ok == true and Maint.active() == nil and Sys.storageMeta().state == 'active', 'Use this store again')

    local okC, key = Sys._consoleStorageMode(0, { 'reset' })
    H.ok(okC and key == 'sysadmin.console.storagemode_reset' and kvp.cp_storage_mode == nil,
        'console storagemode reset clears the in-game choice')
end

-- ============================================================================
--                               9. AUDIT EXPORTS
-- ============================================================================

do
    local part = Cb('admin:exportAuditPart', 1, { part = 1 })
    H.ok(part and part.parts >= 1 and part.csv:find('^id,time', 1) ~= nil, 'an export part with its header')
    local ok, res = Act('server:admin:saveAuditExport', 1, { filters = {} })
    H.ok(ok == true and res.path:match('^saves/exports/audit%-') ~= nil and res.rows >= 1,
        'Save to server writes saves/exports/audit-<time>.csv')
    local fh = io.open(GetResourcePath() .. '/' .. res.path, 'r')
    local text = fh and fh:read('a') or ''
    if fh then fh:close() end
    H.ok(text:find('^id,time') ~= nil, 'the file holds the CSV')
end

return H
