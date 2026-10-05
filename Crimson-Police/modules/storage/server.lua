-- CP.Storage: where Crimson-Police keeps its data (Config.Database).

if CP.Storage and CP.Storage._installed then return end
CP.Storage = CP.Storage or {}
local S = CP.Storage
S._installed = true

local TAG = 'storage'
local KVP_MODE = 'cp_storage_mode'       -- 'database' | 'files': the storage switched to in Admin UI → System
local KVP_FOLDER = 'cp_storage_folder'   -- the saves folder that switch named (relative, under saves)
local mode = 'database'
local folderPath = nil
local loadError = nil
local override = nil                     -- { mode, folder } while the in-game choice is used

function S.mode() return mode end
function S.name() return mode == 'files' and 'saves folder' or 'database' end
function S.folder() return folderPath end
function S.loadError() return loadError end

function S.describe()
    if mode == 'files' then
        return ('database off, data saved as files in the saves folder %s'):format(tostring(folderPath))
    end
    return 'MySQL/MariaDB through oxmysql'
end

local function Trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end

-- A saves folder an admin may name in game: relative, inside the resource, under saves (no '..', no full path).
function S.validFolder(f)
    if type(f) ~= 'string' or #f == 0 or #f > 64 then return false end
    if f:find('..', 1, true) or f:find('//', 1, true) or f:find('\\', 1, true) then return false end
    return f:match('^saves[%w_%-/]*$') ~= nil and f:sub(-1) ~= '/'
end

-- The storage to use: config.lua's Config.Database, or the in-game switch when one is saved (the server's KVP is
-- outside the storage, where the settings live). Returns { enabled, folder }, and { mode, folder } for an override.
function S.effective(cfg, kvp)
    cfg = type(cfg) == 'table' and cfg or {}
    local m = type(kvp) == 'function' and kvp(KVP_MODE) or nil
    if m ~= 'files' and m ~= 'database' then return { enabled = cfg.enabled ~= false, folder = cfg.folder }, nil end
    local folder = kvp(KVP_FOLDER)
    if not S.validFolder(folder) then folder = cfg.folder end
    return { enabled = m == 'database', folder = folder }, { mode = m, folder = folder }
end

function S.override() return override end
S.KVP_MODE, S.KVP_FOLDER = KVP_MODE, KVP_FOLDER

local function ReadKvp(key)
    if type(GetResourceKvpString) ~= 'function' then return nil end
    local ok, v = pcall(GetResourceKvpString, key)
    if ok and type(v) == 'string' and v ~= '' then return v end
    return nil
end

local function IsAbsolute(p)
    return p:match('^/') ~= nil or p:match('^%a:[/\\]') ~= nil or p:match('^[/\\][/\\]') ~= nil
end

-- A folder FXServer's sandbox is unlikely to let this resource write: a full path (unless it is inside the
-- resource) or one that goes up with '..'.
local function OutsideResource(dir)
    if ('/' .. dir .. '/'):find('[/\\]%.%.[/\\]') then return true end
    local root = GetResourcePath and tostring(GetResourcePath(GetCurrentResourceName()) or '') or ''
    root = root:gsub('\\', '/'):gsub('/+$', '')
    local d = dir:gsub('\\', '/')
    return IsAbsolute(dir) and (root == '' or d:sub(1, #root + 1) ~= root .. '/')
end

-- Config.Database.folder: relative to the resource folder ('saves'), or an absolute path.
local function ResolveFolder(folder)
    folder = type(folder) == 'string' and Trim(folder) or ''
    if folder == '' then folder = 'saves' end
    folder = folder:gsub('[/\\]+$', '')
    if IsAbsolute(folder) then return folder end
    local root = GetResourcePath and GetResourcePath(GetCurrentResourceName()) or '.'
    root = tostring(root):gsub('[/\\]+$', '')
    return root .. '/' .. folder
end

-- Without the io library (never the case on a normal FXServer) files go through Load/SaveResourceFile,
-- which only reach a folder inside the resource and cannot rename or delete: an emptied file stands for
-- a removed one.
local function UseResourceFiles(dir)
    local res = GetCurrentResourceName()
    local root = tostring(GetResourcePath and GetResourcePath(res) or ''):gsub('[/\\]+$', '')
    local function rel(path)
        if root ~= '' and path:sub(1, #root + 1) == root .. '/' then return path:sub(#root + 2) end
        return path
    end
    local fs = CP.Storage.MemSQL.fs
    fs.read = function(path)
        local s = LoadResourceFile(res, rel(path))
        if s == nil or s == '' then return nil end
        return s
    end
    fs.write = function(path, data)
        if SaveResourceFile(res, rel(path), data, #data) then return true end
        return nil, 'SaveResourceFile failed'
    end
    fs.exists = function(path) return fs.read(path) ~= nil end
    fs.remove = function(path) SaveResourceFile(res, rel(path), '', 0); return true end
    fs.rename = function(a, b)
        local s = fs.read(a)
        if s == nil then return nil, 'missing' end
        local ok, err = fs.write(b, s)
        if not ok then return nil, err end
        fs.remove(a)
        return true
    end
    return dir
end

-- true, or false and the reason
local function CanWrite(dir)
    local fs = CP.Storage.MemSQL.fs
    local probe = dir .. '/.cp-write-test'
    local ok, err = fs.write(probe, 'ok')
    if not ok then return false, tostring(err or 'cannot write') end
    fs.remove(probe)
    return true
end

-- The folder, created when it is missing: os.createdir on FXServer (its sandbox refuses os.execute),
-- mkdir elsewhere. Returns true, or false and the reason.
local function EnsureFolder(dir)
    local ok, err = CanWrite(dir)
    if ok then return true end
    if os and os.createdir then
        pcall(os.createdir, dir)
    elseif os and os.execute then
        local windows = package and package.config and package.config:sub(1, 1) == '\\'
        local cmd
        if windows then
            cmd = ('mkdir "%s"'):format((dir:gsub('/', '\\')))
        else
            cmd = ('mkdir -p \'%s\''):format((dir:gsub('\'', '\'\\\'\'')))
        end
        pcall(os.execute, cmd)
    end
    local ok2, err2 = CanWrite(dir)
    if ok2 then return true end
    return false, err2 or err
end

-- The real database's answer to "does it hold Crimson-Police data?": true, false, or nil when it cannot tell.
local function DatabaseHasData(real)
    if type(real) ~= 'table' or type(real.scalar) ~= 'table' or type(real.scalar.await) ~= 'function' then
        return nil
    end
    local ok, n = pcall(real.scalar.await, 'SELECT COUNT(*) FROM cp_schema_migrations')
    if ok then return (tonumber(n) or 0) > 0 end
    -- no such table: Crimson-Police never ran with the database on
    local msg = tostring(n):lower()
    if msg:find('doesn\'t exist', 1, true) or msg:find('no such table', 1, true) then return false end
    return nil
end

-- A new saves folder: nothing comes over from the database by itself. When the database holds Crimson-Police data
-- (the database was switched off) the copy command is named; on a first install one calm line says the folder was
-- made. The database is asked once oxmysql is connected.
local function AnnounceNewFolder()
    local path, real = folderPath, S.realMySQL
    CreateThread(function()
        if type(real) == 'table' and real.ready then
            local p = promise.new()
            real.ready(function() p:resolve(true) end)
            Citizen.Await(p)
        end
        if DatabaseHasData(real) == false then
            print(('[crimson-police] first start with the database off: created the saves folder %s'):format(path))
            return
        end
        local cmd = type(Config) == 'table' and type(Config.Tablet) == 'table' and Config.Tablet.adminCommand
            or 'CrimsonPoliceAdmin'
        CP.warn(TAG,
            'the saves folder %s is new, so Crimson-Police starts with no data. Nothing is copied from your database by itself: to bring your data over, run "%s storage copy database-to-files" in the server console once the resource has started, then restart Crimson-Police.',
            path, tostring(cmd))
    end)
end

function S.hasSavedData()
    local M = CP.Storage.MemSQL
    if not M then return false end
    local cfg = type(Config) == 'table' and type(Config.Database) == 'table' and Config.Database or {}
    return M.fs.exists(ResolveFolder(cfg.folder) .. '/_tables.json') == true
end

local function Install()
    local cfg = type(Config) == 'table' and type(Config.Database) == 'table' and Config.Database or {}
    local eff, ov = S.effective(cfg, ReadKvp)
    if ov and type(Config) == 'table' then
        override = ov
        Config.Database = Config.Database or {}
        Config.Database.enabled, Config.Database.folder = eff.enabled, eff.folder
        cfg = Config.Database
        print(
            ('[crimson-police] storage: the storage switched to in Admin UI → System is used (%s%s), not config.lua\'s Config.Database. "CrimsonPoliceAdmin storagemode reset" in the server console goes back to config.lua\'s.'):format(
                ov.mode == 'files' and 'saves folder ' or 'database',
                ov.mode == 'files' and tostring(eff.folder or 'saves') or ''))
    end
    if cfg.enabled ~= false then
        mode = 'database'
        return
    end
    mode = 'files'
    S.realMySQL = type(MySQL) == 'table' and MySQL or nil
    folderPath = ResolveFolder(cfg.folder)
    if not io then UseResourceFiles(folderPath) end
    local db = CP.Storage.MemSQL.new({ store = CP.Storage.MemSQL.folderStore(folderPath) })
    S.db = db
    -- a long SELECT (a board over a big season) gives the server its turn every 4 ms instead of holding the
    -- server thread for the whole query (with the database, oxmysql's await yields the same way)
    local wait = (Citizen and Citizen.Wait) or Wait
    if type(wait) == 'function' then db.slice = { wait = wait, ms = 4 } end
    local okDir, whyNot = EnsureFolder(folderPath)
    if not okDir then
        if OutsideResource(folderPath) then
            loadError = ('the saves folder %s cannot be written (%s). FXServer only lets a resource write inside resource folders: set Config.Database.folder to a folder inside Crimson-Police (the default is \'saves\'), or give Crimson-Police write access to another resource with add_filesystem_permission'):format(
                folderPath, whyNot)
        else
            loadError = ('the saves folder %s cannot be written (%s): create it inside the Crimson-Police folder, make sure the server may write to it, and restart'):format(
                folderPath, whyNot)
        end
    else
        local ok, err = pcall(db.load, db)
        if not ok then
            loadError = ('the saves folder %s could not be read: %s'):format(folderPath, tostring(err))
        elseif not db.store.loadedTables then
            AnnounceNewFolder()
        end
    end
    if loadError then
        CP.err(TAG, '%s', loadError)
        CP.err(TAG, 'Crimson-Police will not start until this is fixed; nothing in the saves folder was changed.')
        db:fail(loadError)
    end
    MySQL = CP.Storage.MemSQL.shim(db, { realMySQL = S.realMySQL, resource = CP.resource or GetCurrentResourceName() })
end

Install()
