-- The generic starting config (config/examples/generic.lua): what a copy for sale ships as config/config.lua.

-- The generic starting config (config/examples/generic.lua): what a copy for sale ships as config/config.lua.
-- It holds every setting config.lua has, its departments are qbx_core's own police jobs (police, bcso, sasp), every
-- other script is 'auto', no zone names a private script, and the First-start setup is on. Both files load and pass
-- Config health against the Qbox jobs each one is built for; every value of the generic file passes its setting's own
-- check. Plain Lua: no database case (nothing here reads or writes storage).

local H = dofile('tests/harness.lua')

local GENERIC = 'config/examples/generic.lua'

-- qbx_core shared/jobs.lua: the three police jobs (type 'leo'), each Recruit 0 to Chief 4 (boss)
local LADDER = {
    [0] = { name = 'Recruit' },
    [1] = { name = 'Officer' },
    [2] = { name = 'Sergeant' },
    [3] = { name = 'Lieutenant' },
    [4] = { name = 'Chief', isboss = true },
}
local QBX_JOBS = {
    police = { label = 'LSPD', type = 'leo', grades = LADDER },
    bcso = { label = 'BCSO', type = 'leo', grades = LADDER },
    sasp = { label = 'SASP', type = 'leo', grades = LADDER },
}
-- the owner's server: its own sast and fib jobs
local OWNER_JOBS = {
    sast = { label = 'SAST', type = 'leo', grades = LADDER },
    fib = { label = 'FIB', type = 'leo', grades = LADDER },
}

-- Every path of a config table: maps are walked, lists and values are leaves.
local function Paths(t, prefix, out)
    out = out or {}
    for k, v in pairs(t) do
        local path = prefix and (prefix .. '.' .. tostring(k)) or tostring(k)
        if type(v) == 'table' and next(v) ~= nil and #v == 0 then
            Paths(v, path, out)
        else
            out[path] = true
        end
    end
    return out
end

-- The Config one file builds (with config/blocks.lua after it, as fxmanifest loads them).
local function Load(file)
    _G.Config = nil
    H.load(file)
    H.load('config/blocks.lua')
    return Config
end

H.boot({ side = 'server', realLocale = true })
_G.GetConvar = function(_, default) return default end
_G.PerformHttpRequest = function() end

-- ============================================================================
--                 EVERY SETTING OF CONFIG.LUA, GENERIC VALUES
-- ============================================================================

local owner = Paths(Load('config/config.lua'))
local generic = Paths(Load(GENERIC))
do
    local missing, extra = {}, {}
    for p in pairs(owner) do
        local own = p:match('^Departments%.') or p:find('trainerGrades', 1, true)
        if not own and not generic[p] then missing[#missing + 1] = p end
    end
    for p in pairs(generic) do
        local own = p:match('^Departments%.') or p:find('trainerGrades', 1, true)
        if not own and not owner[p] then extra[#extra + 1] = p end
    end
    table.sort(missing)
    table.sort(extra)
    H.eq(#missing, 0, 'the generic file holds every setting of config.lua; missing: ' .. table.concat(missing, ', '))
    H.eq(#extra, 0, 'and no other: ' .. table.concat(extra, ', '))
end

do
    local keys = {}
    for k in pairs(Config.Departments) do keys[#keys + 1] = k end
    table.sort(keys)
    H.eq(table.concat(keys, ','), 'bcso,police,sasp', 'the departments are qbx_core\'s police jobs')
    for _, k in ipairs(keys) do
        H.eq(table.concat(Config.Departments[k].jobs, ','), k, k .. ': its own Qbox job')
        H.eq(Config.Departments[k].supervisorGrade, 3, k .. ': supervisors from grade 3 (Lieutenant)')
    end
    for kind, v in pairs(Config.Integrations) do H.eq(v, 'auto', kind .. ': the first script running') end
    H.eq(Config.AdminUi.setupScreen, true, 'the First-start setup shows')
    H.eq(Config.AdminUi.setupDone, false, 'and is not done')
    H.eq(Config.Database.enabled, false, 'the saves folder (no database to set up first)')
    H.eq(Config.RealPlayers.liveCrime.enabled, false, 'live crimes from the private contracts script stay off')
    local f = assert(io.open('Crimson-Police/' .. GENERIC, 'r'))
    local src = f:read('a')
    f:close()
    -- code only: the comments may still name the scripts the integrations support
    local code = src:gsub('%-%-[^\n]*', '')
    H.ok(not code:find('Crimson%-Arena'), 'no zone names a private script')
    H.ok(not code:find('sast') and not code:find('fib'), 'no department or grade of the owner\'s server')
end

-- ============================================================================
--                        CONFIG HEALTH: BOTH FILES PASS
-- ============================================================================

local function Health(file, jobs)
    H.boot({ side = 'server', realLocale = true })
    _G.GetConvar = function(_, default) return default end
    _G.PerformHttpRequest = function() end
    -- the file and Settings' schema read from it, as when it is copied over config.lua
    Load(file)
    local load = _G.LoadResourceFile
    _G.LoadResourceFile = function(res, path)
        if path == 'config/config.lua' then path = file end
        return load(res, path)
    end
    -- CP.Qbx: the jobs; every other call (the job and duty listeners access.lua adds) does nothing
    CP.Qbx = setmetatable({
        getJobs = function() return jobs end,
        getInfo = function() return nil end,
        getOnlinePlayers = function() return {} end,
    }, {
        __index = function() return function() end end,
    })
    CP.ConfigHealth = nil
    CP.Access = nil
    H.load('modules/access/access.lua')
    H.load('modules/admin/confighealth.lua')
    H.load('modules/admin/settings.lua')
    _G.LoadResourceFile = load
    local errors, depts = {}, {}
    for _, item in ipairs(CP.ConfigHealth.run()) do
        if item.level == 'error' then errors[#errors + 1] = item.check .. ': ' .. item.text end
        if item.check == 'departments' then depts[#depts + 1] = item.level end
    end
    H.eq(#errors, 0, file .. ': no Config health error; ' .. table.concat(errors, ' | '))
    H.ok(#depts > 0, file .. ': every department job is checked')
    H.eq(table.concat(depts, ','):gsub('ok,?', ''), '', file .. ': each job is a Qbox job and its grade splits it')
    -- every value of the file is a value its setting accepts
    -- (all at once, as a save of every setting: a bonus's kind is checked together with its value)
    local bad, pending = {}, {}
    for _, e in ipairs(CP.Settings._schema().list) do pending[e.path] = e.default end
    for _, e in ipairs(CP.Settings._schema().list) do
        if e.default ~= nil and not e.locked then
            local ok, err = CP.Settings.check(e.path, e.default, false, { pending = pending })
            if not ok then bad[#bad + 1] = e.path .. ' (' .. tostring(err) .. ')' end
        end
    end
    H.eq(#bad, 0,
        file .. ': every value passes its setting\'s check; ' .. table.concat(bad, ', ', 1, math.min(#bad, 8)))
end

Health('config/config.lua', OWNER_JOBS)
Health(GENERIC, QBX_JOBS)

return H
