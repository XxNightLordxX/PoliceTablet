-- modules/storage/server.lua · CP.Storage: where Crimson-Police keeps its data (Config.Database).
--
--   Config.Database.enabled = true   MySQL/MariaDB through oxmysql, exactly as before (nothing here runs).
--   Config.Database.enabled = false  database off: this file replaces the MySQL global of this resource with
--                                    CP.Storage.MemSQL.shim before any other module can query, and every cp_ table
--                                    lives as documents in the saves folder (modules/storage/memsql.lua).
--                                    The modules keep their SQL; the migrations build the same tables.
--
-- Public API (server)
--   CP.Storage.mode() -> 'database' | 'files'
--   CP.Storage.name() -> 'database' | 'saves folder' (for console text: "the %s")
--   CP.Storage.folder() -> the saves folder's full path (files mode) or nil
--   CP.Storage.describe() -> one line for the start-up log
--   CP.Storage.loadError() -> why the saves folder could not be used, or nil
--   CP.Storage.hasSavedData() -> true when Config.Database.folder holds saves (a _tables.json), in either mode
--   CP.Storage.realMySQL   oxmysql's MySQL table (files mode): the one read-only lookup of another
--                          resource's table (sc-dispatch's mdt_dispatch, Hard rule 15) still goes there
--   CP.Storage.db          the CP.Storage.MemSQL engine (files mode)
--   CP.Storage.MemSQL      the engine's code (modules/storage/memsql.lua); this module's one global table holds both
--
-- fxmanifest loads memsql.lua and this file right after @oxmysql/lib/MySQL.lua and before every other server
-- module. The modules/**/server.lua glob matches this file a second time; that load returns at once.
-- FiveM resource KVP is not used anywhere. On FXServer a resource may only write inside resource folders (its
-- Lua file sandbox): the saves folder is a folder inside Crimson-Police, 'saves' unless Config.Database.folder
-- names another one.

if CP.Storage and CP.Storage._installed then return end
CP.Storage = CP.Storage or {}
local S = CP.Storage
S._installed = true

local TAG = 'storage'
local mode = 'database'
local folderPath = nil
local loadError = nil

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

local function trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end

local function isAbsolute(p)
    return p:match('^/') ~= nil or p:match('^%a:[/\\]') ~= nil or p:match('^[/\\][/\\]') ~= nil
end

-- A folder FXServer's sandbox is unlikely to let this resource write: a full path (unless it is inside the
-- resource) or one that goes up with '..'.
local function outsideResource(dir)
    if ('/' .. dir .. '/'):find('[/\\]%.%.[/\\]') then return true end
    local root = GetResourcePath and tostring(GetResourcePath(GetCurrentResourceName()) or '') or ''
    root = root:gsub('\\', '/'):gsub('/+$', '')
    local d = dir:gsub('\\', '/')
    return isAbsolute(dir) and (root == '' or d:sub(1, #root + 1) ~= root .. '/')
end

-- Config.Database.folder: relative to the resource folder ('saves'), or an absolute path.
local function resolveFolder(folder)
    folder = type(folder) == 'string' and trim(folder) or ''
    if folder == '' then folder = 'saves' end
    folder = folder:gsub('[/\\]+$', '')
    if isAbsolute(folder) then return folder end
    local root = GetResourcePath and GetResourcePath(GetCurrentResourceName()) or '.'
    root = tostring(root):gsub('[/\\]+$', '')
    return root .. '/' .. folder
end

-- Without the io library (never the case on a normal FXServer) files go through Load/SaveResourceFile,
-- which only reach a folder inside the resource and cannot rename or delete: an emptied file stands for
-- a removed one.
local function useResourceFiles(dir)
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
local function canWrite(dir)
    local fs = CP.Storage.MemSQL.fs
    local probe = dir .. '/.cp-write-test'
    local ok, err = fs.write(probe, 'ok')
    if not ok then return false, tostring(err or 'cannot write') end
    fs.remove(probe)
    return true
end

-- The folder, created when it is missing: os.createdir on FXServer (its sandbox refuses os.execute),
-- mkdir elsewhere. Returns true, or false and the reason.
local function ensureFolder(dir)
    local ok, err = canWrite(dir)
    if ok then return true end
    if os and os.createdir then
        pcall(os.createdir, dir)
    elseif os and os.execute then
        local windows = package and package.config and package.config:sub(1, 1) == '\\'
        local cmd
        if windows then
            cmd = ('mkdir "%s"'):format((dir:gsub('/', '\\')))
        else
            cmd = ("mkdir -p '%s'"):format((dir:gsub("'", "'\\''")))
        end
        pcall(os.execute, cmd)
    end
    local ok2, err2 = canWrite(dir)
    if ok2 then return true end
    return false, err2 or err
end

function S.hasSavedData()
    local M = CP.Storage.MemSQL
    if not M then return false end
    local cfg = type(Config) == 'table' and type(Config.Database) == 'table' and Config.Database or {}
    return M.fs.exists(resolveFolder(cfg.folder) .. '/_tables.json') == true
end

local function install()
    local cfg = type(Config) == 'table' and type(Config.Database) == 'table' and Config.Database or {}
    if cfg.enabled ~= false then
        mode = 'database'
        return
    end
    mode = 'files'
    S.realMySQL = type(MySQL) == 'table' and MySQL or nil
    folderPath = resolveFolder(cfg.folder)
    if not io then useResourceFiles(folderPath) end
    local db = CP.Storage.MemSQL.new({ store = CP.Storage.MemSQL.folderStore(folderPath) })
    S.db = db
    -- a long SELECT (a board over a big season) gives the server its turn every 4 ms instead of holding the
    -- server thread for the whole query (with the database, oxmysql's await yields the same way)
    local wait = (Citizen and Citizen.Wait) or Wait
    if type(wait) == 'function' then db.slice = { wait = wait, ms = 4 } end
    local okDir, whyNot = ensureFolder(folderPath)
    if not okDir then
        if outsideResource(folderPath) then
            loadError = ("the saves folder %s cannot be written (%s). FXServer only lets a resource write inside resource folders: set Config.Database.folder to a folder inside Crimson-Police (the default is 'saves'), or give Crimson-Police write access to another resource with add_filesystem_permission"):format(folderPath, whyNot)
        else
            loadError = ('the saves folder %s cannot be written (%s): create it inside the Crimson-Police folder, make sure the server may write to it, and restart'):format(folderPath, whyNot)
        end
    else
        local ok, err = pcall(db.load, db)
        if not ok then
            loadError = ('the saves folder %s could not be read: %s'):format(folderPath, tostring(err))
        elseif not db.store.loadedTables then
            -- a new saves folder: nothing comes over from the database by itself
            local cmd = type(Config) == 'table' and type(Config.Tablet) == 'table' and Config.Tablet.adminCommand or 'CrimsonPoliceAdmin'
            CP.warn(TAG, 'the saves folder %s is new, so Crimson-Police starts with no data. Nothing is copied from your database by itself: to bring your data over, run "%s storage copy database-to-files" in the server console once the resource has started, then restart Crimson-Police.', folderPath, tostring(cmd))
        end
    end
    if loadError then
        CP.err(TAG, '%s', loadError)
        CP.err(TAG, 'Crimson-Police will not start until this is fixed; nothing in the saves folder was changed.')
        db:fail(loadError)
    end
    MySQL = CP.Storage.MemSQL.shim(db, { realMySQL = S.realMySQL, resource = CP.resource or GetCurrentResourceName() })
end

install()
