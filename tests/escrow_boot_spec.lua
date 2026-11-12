-- The resource starts on an escrowed (Tebex) build. FiveM asset escrow encrypts every .lua file escrow_ignore does

-- The resource starts on an escrowed (Tebex) build. FiveM asset escrow encrypts every .lua file escrow_ignore does
-- not list: FXServer runs those scripts, but LoadResourceFile of one gives ciphertext. Here every such file of
-- Crimson-Police reads back as garbage through LoadResourceFile while every server script, then every client
-- script, loads in fxmanifest order (CreateThread deferred to the next tick, as FXServer does). The resource must
-- still start: the migrations run, every built-in mission is registered, Settings reads its config files, and no
-- file of the resource ever asks for an escrowed .lua file. Runs in every storage mode (tests/run.lua --storage=).

local H = dofile('tests/harness.lua')

local SEALED = 'FXAP\0\1\2 sealed by asset escrow \255\254'

-- every LoadResourceFile of this resource's escrowed .lua files (path list) and every warning or error line it prints
local sealedReads, problems = {}, {}
local function Seal()
    local real = _G.LoadResourceFile
    _G.LoadResourceFile = function(res, path)
        if (res == nil or res == GetCurrentResourceName()) and not H.escrowIgnored(path) then
            sealedReads[#sealedReads + 1] = tostring(path)
            return SEALED
        end
        return real(res, path)
    end
end

local realPrint = print
_G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, ' ')
    if line:find('^%^[13]%[crimson%-police') then problems[#problems + 1] = line end
    -- the resource's own lines stay out of the output (E2E_VERBOSE=1 shows them), the spec's results stay visible
    if os.getenv('E2E_VERBOSE') or not line:find('crimson%-police') then realPrint(line) end
end

-- natives and other resources' exports the start does not need answer nil (FXServer and those resources would
-- answer; nothing here depends on the answer)
local function Nop() return nil end
H.onUndefinedGlobal(function(k)
    -- a native's name (GetEntityCoords), never a table of the resource or the stack (CP, Config, MySQL)
    if type(k) == 'string' and k ~= 'MySQL' and k:match('^%u%l+%u') then return Nop end
    return nil
end)
setmetatable(H.exportsMock, {
    __index = function(t, res)
        local m = setmetatable({}, {
            __index = function() return Nop end,
        })
        rawset(t, res, m)
        return m
    end,
})

-- one manifest script list loaded as FXServer runs it: each file in order, then the threads they started
local function LoadList(key, skip)
    local failed, n = {}, 0
    local realCreate = _G.CreateThread
    local deferred = {}
    _G.CreateThread = function(fn) deferred[#deferred + 1] = fn end
    _G.Citizen.CreateThread = _G.CreateThread
    for _, rel in ipairs(H.manifestScripts(key)) do
        if not rel:match('^config/') and not (skip and skip[rel]) then
            n = n + 1
            local ok, err = pcall(H.load, rel)
            if not ok then failed[#failed + 1] = rel .. ': ' .. tostring(err) end
        end
    end
    _G.CreateThread = realCreate
    _G.Citizen.CreateThread = realCreate
    for _, fn in ipairs(deferred) do realCreate(fn) end
    return n, failed
end

-- ============================================================================
--                      THE ESCROWED SET (fxmanifest.lua)
-- ============================================================================

do
    local all, sealed = 0, 0
    local p = io.popen('cd "' .. H.root .. '" && find . -name "*.lua" -not -path "./web/node_modules/*"')
    for line in p:lines() do
        all = all + 1
        if not H.escrowIgnored(line:gsub('^%./', '')) then sealed = sealed + 1 end
    end
    p:close()
    H.ok(sealed > 100 and sealed < all, ('escrow seals %d of the %d .lua files'):format(sealed, all))
    H.eq(H.escrowIgnored('modules/system/migrations.lua'), false, 'escrow seals modules/system/migrations.lua')
    H.eq(H.escrowIgnored('config/config.lua'), true, 'escrow leaves config/config.lua readable')
    H.eq(H.escrowIgnored('missions/builtin/beat_patrol.lua'), true, 'escrow leaves the built-in missions readable')
    H.eq(H.escrowIgnored('missions/custom/a/b.lua'), true, 'escrow leaves the missions made in game readable')
    H.eq(H.escrowIgnored('sql/migrations/001_init.sql'), true, 'escrow encrypts .lua files only')
end

-- ============================================================================
--                              THE SERVER STARTS
-- ============================================================================

H.boot({ side = 'server' })
Seal()
-- the harness has already loaded the saves folder engine in files mode (as fxmanifest does, first)
local skip = (CP.Storage and CP.Storage.MemSQL) and { ['modules/system/memsql.lua'] = true } or nil
local n, failed = LoadList('server_scripts', skip)
H.ok(n >= 60, 'every server script loads (' .. n .. ')')
H.eq(table.concat(failed, '; '), '', 'no server script fails to load')
H.step(0)
for _ = 1, 10 do H.step(1000) end

H.ok(CP.Migrations.started(), 'the migrations ran: the resource started')
H.eq(CP.Migrations.failed(), nil, 'no migration failed')
do
    local f = assert(io.open(H.root .. 'missions/builtin/index.lua', 'r'))
    local src = f:read('a')
    f:close()
    local missing, ids = {}, 0
    for id in src:gmatch('\'([%w_]+)\'') do
        ids = ids + 1
        if not CP.Missions.get(id) then missing[#missing + 1] = id end
    end
    H.ok(ids >= 10, 'missions/builtin/index.lua lists the built-in missions (' .. ids .. ')')
    H.eq(table.concat(missing, ', '), '', 'every built-in mission is registered')
end

-- the backup and restore table list (Admin UI → System) comes from the migrations runner, never from its source
CP.Sysadmin._resetSchema()
local schema = CP.Sysadmin.schema()
H.ok(schema ~= nil and #schema.order >= 20,
    'the backup schema has every cp_ table (' .. #(schema and schema.order or {}) .. ')')
do
    -- without CP.Migrations.status the list is empty and says so: it never reads modules/system/migrations.lua
    local status = CP.Migrations.status
    CP.Migrations.status = nil
    CP.Sysadmin._resetSchema()
    local bare = CP.Sysadmin.schema()
    CP.Migrations.status = status
    CP.Sysadmin._resetSchema()
    H.eq(bare and #bare.order, 0, 'without the migrations runner the backup schema is empty')
    local said = false
    for _, line in ipairs(problems) do
        if line:find('the migrations list is not available', 1, true) then said = true end
    end
    H.ok(said, 'and the server console says why')
end

local unread = {}
for _, line in ipairs(problems) do
    if line:find('could not be read', 1, true) then unread[#unread + 1] = line end
end
H.eq(table.concat(unread, ' | '), '', 'Settings reads config.lua and blocks.lua (no "could not be read")')
H.eq(table.concat(sealedReads, ', '), '', 'the server reads no escrowed .lua file')

-- ============================================================================
--                              THE CLIENT STARTS
-- ============================================================================

-- a separate game: the client builds its own CP (the server's tables stay on the server)
sealedReads, problems = {}, {}
_G.CP = nil
H.boot({ side = 'client' })
Seal()
_G.PlayerId = function() return 0 end
_G.GetPlayerServerId = function() return 1 end
_G.LocalPlayer = { state = {} }
n, failed = LoadList('client_scripts')
H.ok(n >= 30, 'every client script loads (' .. n .. ')')
H.eq(table.concat(failed, '; '), '', 'no client script fails to load')
H.step(0)
H.advance(60000, 1000)
H.ok(CP.Access ~= nil and CP.BlockKit ~= nil, 'the client modules are up')
H.eq(table.concat(sealedReads, ', '), '', 'the client reads no escrowed .lua file')

_G.print = realPrint
return H
