-- CP.Sysadmin (server): Admin UI → System (storage, backups, webhooks, problems, integrations), Departments (add, turn
-- off, delete, logos, desks), Settings positions and Officers → Support (check access, tablet item, stuck screen).

CP.Sysadmin = CP.Sysadmin or {}
local Sys = CP.Sysadmin
local U = CP.U
local Kit = CP.AdminKit
local Maint = CP.Maintenance
local TAG = 'sysadmin'

local BACKUP_DIR = 'saves/_backups'       -- inside the resource; never in fxmanifest files (never served)
local EXPORT_DIR = 'saves/exports'
local BACKUP_PAGE = 1000                  -- rows per read of a table with an integer AUTO_INCREMENT key
local INSERT_BATCH = 50                   -- rows per INSERT when a backup is put back
local AUDIT_PART = 5000                   -- rows per audit export part
local AUDIT_SAVE_MAX = 100000             -- rows one Save to server writes
local UPLOAD_MAX = 1048576                -- bytes of one logo
local UPLOAD_CHUNK = 16384                -- base64 characters per chunk
local UPLOAD_TTL = 60                     -- seconds an unfinished upload is kept
local STATE_WAIT_MS = 3000                -- how long Show state waits for the player's client
local DEPT_KEY = '^[a-z0-9_]+$'
local MIGRATIONS_TABLE = 'cp_schema_migrations'

-- Tables a restore never replaces: the audit trail, the settings history, the storage marker, request ids, jobs and
-- the department funding ledger (money only moves forward).
local KEEP_TABLES = {
    cp_audit = true,
    cp_settings_history = true,
    cp_schema_migrations = true,
    cp_storage_meta = true,
    cp_admin_requests = true,
    cp_admin_jobs = true,
    cp_dept_funding = true,
}
-- cp_settings rows a restore keeps as they are now: the money switches and limits, AdminControl, the audit retention.
local KEEP_SETTINGS = {
    'AdminControl.',
    'Cash.allow',
    'Cash.restoreForfeited',
    'Cash.addFundsMax',
    'Cash.manualDailyLimit',
    'Rewards.allowTakeBack',
    'Retention.auditDays',
}

local REQUIRED_RESOURCES = {
    'oxmysql',
    'ox_lib',
    'qbx_core',
    'ox_target',
    'ox_inventory',
    'sc-dispatch',
    'sc-ambulance',
    'Renewed-Banking',
}
local OPTIONAL_RESOURCES = { 'sc-police', 'sc-npcpolice', 'sc-multijob', 'Crimson-Arena' }
local CHECKLIST = {
    'sysadmin.checklist.dispatch_jobs',
    'sysadmin.checklist.police_jobs',
    'sysadmin.checklist.ambulance',
    'sysadmin.checklist.banking',
    'sysadmin.checklist.item',
    'sysadmin.checklist.arena',
}

local schemaCache = nil
local uploads = {}          -- src -> { id, key, chunks, n, total, bytes, at }
local statePending = {}     -- token -> { src, state }

-- ============================================================================
--                                SMALL HELPERS
-- ============================================================================

local function Has(modName, fnName)
    local m = CP[modName]
    return type(m) == 'table' and type(m[fnName]) == 'function'
end

local function Call(modName, fnName, ...)
    if not Has(modName, fnName) then return false, nil end
    local res = table.pack(pcall(CP[modName][fnName], ...))
    if not res[1] then
        CP.err(TAG, 'CP.%s.%s failed: %s', modName, fnName, tostring(res[2]))
        return false, nil
    end
    return true, table.unpack(res, 2, res.n)
end

local function Db()
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
end

local function Int(v) return math.tointeger(tonumber(v) or 0) or 0 end

local function Now()
    if CP.Schedule and CP.Schedule.now then return CP.Schedule.now() end
    return os.time()
end

local function QuoteName(name) return '`' .. name .. '`' end

local function Fs()
    local M = CP.Storage and CP.Storage.MemSQL
    return type(M) == 'table' and M.fs or nil
end

local function Root()
    local root = tostring(GetResourcePath and GetResourcePath(CP.resource) or '.')
    return (root:gsub('[/\\]+$', ''))
end

-- A saves folder setting as a full path (relative = inside the resource).
local function FolderPath(folder)
    folder = type(folder) == 'string' and U.trim(folder) or 'saves'
    if folder == '' then folder = 'saves' end
    folder = folder:gsub('[/\\]+$', '')
    if folder:match('^/') or folder:match('^%a:[/\\]') then return folder end
    return Root() .. '/' .. folder
end

-- A folder inside the resource the server can write to, created when missing: os.createdir on FXServer (its
-- sandbox refuses os.execute), mkdir elsewhere. true when it can be written.
local function EnsureDir(rel)
    local fs = Fs()
    if not fs then return false end
    local dir = Root() .. '/' .. rel
    local probe = dir .. '/.cp-write-test'
    local function canWrite()
        local ok, res = pcall(fs.write, probe, 'ok')
        if not ok or not res then return false end
        pcall(fs.remove, probe)
        return true
    end
    if canWrite() then return true end
    if os and os.createdir then
        local path = Root()
        for part in rel:gmatch('[^/]+') do
            path = path .. '/' .. part
            pcall(os.createdir, path)
        end
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
    return canWrite()
end

local function ReadJson(path)
    local fs = Fs()
    local text = fs and fs.read(path) or nil
    if type(text) ~= 'string' or text == '' then return nil end
    local ok, v = pcall(json.decode, text)
    if ok then return v end
    return nil
end

local function WriteJson(path, v)
    local fs = Fs()
    if not fs then return false end
    local ok, text = pcall(json.encode, v)
    if not ok then return false end
    local okW, res = pcall(fs.write, path, text)
    return okW and res == true, #text
end

local function SrcOf(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return nil end
    local ok, s = Call('Qbx', 'getByCitizenId', citizenid)
    s = ok and math.tointeger(tonumber(s)) or nil
    if not s or s <= 0 then return nil end
    return s
end

-- The online player a Support action names: { src } or { citizenid }.
local function TargetOf(p)
    local s = math.tointeger(tonumber(p.src) or -1)
    if s and s > 0 then
        local ok, info = Call('Qbx', 'getInfo', s)
        if ok and type(info) == 'table' then return s, info end
        return nil
    end
    s = SrcOf(p.citizenid)
    if not s then return nil end
    local ok, info = Call('Qbx', 'getInfo', s)
    if ok and type(info) == 'table' then return s, info end
    return nil
end

local function RunsGoing()
    local n = 0
    local okR, list = Call('Runs', 'all')
    if okR and type(list) == 'table' then n = #list end
    local okO, op = Call('Operations', 'active')
    if okO and op ~= nil then n = n + 1 end
    return n
end

local function PedOf(src)
    local ped = GetPlayerPed and GetPlayerPed(src) or 0
    if not ped or ped == 0 then return nil end
    return ped
end

local function Teleport(src, c)
    local ped = PedOf(src)
    if not ped or type(c) ~= 'table' and type(c) ~= 'vector3' then return false end
    SetEntityCoords(ped, (tonumber(c.x) or 0) + 0.0, (tonumber(c.y) or 0) + 0.0, (tonumber(c.z) or 0) + 0.0, false,
        false, false, false)
    return true
end

-- ============================================================================
--                                    SCHEMA
-- ============================================================================
-- Every Crimson-Police table and column as this version's migrations build them (an in-memory saves folder engine
-- runs them once), so a backup reads and writes the same columns with the database on or off.

local function MigrationNames()
    if Has('Migrations', 'status') then
        local ok, st = Call('Migrations', 'status')
        if ok and type(st) == 'table' and type(st.files) == 'table' and #st.files > 0 then
            local out = {}
            for _, f in ipairs(st.files) do out[#out + 1] = f.name end
            return out
        end
    end
    local src = LoadResourceFile(CP.resource, 'modules/migrations/server.lua') or ''
    local body = src:match('local FILES = (%b{})') or ''
    local out = {}
    for name in body:gmatch('\'([^\']+%.sql)\'') do out[#out + 1] = name end
    return out
end

local function Split(sql)
    if Has('Migrations', '_split') then return CP.Migrations._split(sql) end
    local statements, current = {}, {}
    for line in (sql .. '\n'):gmatch('(.-)\r?\n') do
        local code = line:gsub('%-%-.*$', '')
        if code:match('%S') then
            current[#current + 1] = code
            if code:match(';%s*$') then
                statements[#statements + 1] = (table.concat(current, '\n'):gsub(';%s*$', ''))
                current = {}
            end
        end
    end
    local rest = table.concat(current, '\n')
    if rest:match('%S') then statements[#statements + 1] = rest end
    return statements
end

-- { order = { name }, tables = { [name] = { name, cols = { column }, kinds = { [column] = 'dt'|'date'|'bool'|'val' },
-- keyset = AUTO_INCREMENT primary key column | nil } } }
function Sys.schema()
    if schemaCache then return schemaCache end
    local M = CP.Storage and CP.Storage.MemSQL
    if type(M) ~= 'table' then return nil end
    local engine = M.new({})
    for _, name in ipairs(MigrationNames()) do
        local sql = LoadResourceFile(CP.resource, 'sql/migrations/' .. name)
        for _, stmt in ipairs(sql and Split(sql) or {}) do
            local ok, err = pcall(engine.exec, engine, stmt)
            if not ok and not tostring(err):find('already exists', 1, true) then
                CP.warn(TAG, 'schema: %s: %s', name, tostring(err))
            end
        end
    end
    local out = { order = {}, tables = {} }
    for _, name in ipairs(engine:tableNames()) do
        local t = engine.tables[name]
        if t and name:sub(1, 3) == 'cp_' then
            local info = { name = name, cols = {}, kinds = {} }
            for _, col in ipairs(t.cols) do
                local kind = 'val'
                if col.kind == 'dt' then
                    kind = 'dt'
                elseif col.kind == 'date' then
                    kind = 'date'
                elseif tostring(col.type):upper() == 'TINYINT' and col.width == 1 then
                    kind = 'bool'
                end
                info.cols[#info.cols + 1] = col.name
                info.kinds[col.name] = kind
            end
            if t.autoCol and type(t.pk) == 'table' and #t.pk == 1 and t.pk[1] == t.autoCol then
                info.keyset = t.cols[t.autoCol].name
            end
            out.order[#out.order + 1] = name
            out.tables[name] = info
        end
    end
    schemaCache = out
    return out
end

-- ============================================================================
--                           READING AND WRITING ROWS
-- ============================================================================
-- db: an oxmysql-shaped object (MySQL, CP.Storage.realMySQL, or a shim over a saves folder engine).

local function SelectList(info)
    local list = {}
    for _, c in ipairs(info.cols) do
        local q, kind = QuoteName(c), info.kinds[c]
        if kind == 'dt' then
            list[#list + 1] = 'UNIX_TIMESTAMP(' .. q .. ') AS ' .. q
        elseif kind == 'date' then
            list[#list + 1] = 'DATE_FORMAT(' .. q .. ', \'%Y-%m-%d\') AS ' .. q
        else
            list[#list + 1] = q
        end
    end
    return 'SELECT ' .. table.concat(list, ', ') .. ' FROM ' .. QuoteName(info.name)
end

local function Clean(row, info)
    local out = {}
    for _, c in ipairs(info.cols) do
        local v, kind = row[c], info.kinds[c]
        if v ~= nil then
            if kind == 'dt' then
                v = math.tointeger(tonumber(v)) or math.floor(tonumber(v) or 0)
            elseif kind == 'bool' then
                if v == true then v = 1 elseif v == false then v = 0 else v = Int(v) end
            elseif type(v) == 'boolean' then
                v = v and 1 or 0
            elseif type(v) == 'table' then
                v = json.encode(v)
            end
            out[c] = v
        end
    end
    return out
end

local function Query(db, sql, params)
    local res = db.query.await(sql, params or {})
    return type(res) == 'table' and res or {}
end

-- Every row of one table (in pages along an integer AUTO_INCREMENT key, else in one read). where: optional filter.
local function ReadRows(db, info, where, params)
    local base = SelectList(info)
    local out = {}
    if info.keyset and not where then
        local key = QuoteName(info.keyset)
        local function firstFrom(lo)
            local sql = 'SELECT MIN(' .. key .. ') AS m FROM ' .. QuoteName(info.name)
            local r = lo and Query(db, sql .. ' WHERE ' .. key .. ' >= ?', { lo }) or Query(db, sql)
            local m = r[1] and r[1].m
            if m == nil then return nil end
            return math.tointeger(tonumber(m))
        end
        local page = base .. ' WHERE ' .. key .. ' >= ? AND ' .. key .. ' < ? ORDER BY ' .. key
        local lo = firstFrom(nil)
        while lo do
            local rows = Query(db, page, { lo, lo + BACKUP_PAGE })
            for _, r in ipairs(rows) do out[#out + 1] = Clean(r, info) end
            if #rows > 0 then lo = lo + BACKUP_PAGE else lo = firstFrom(lo) end
            Wait(0)
        end
        return out
    end
    local sql = base .. (where and (' WHERE ' .. where) or '')
    for _, r in ipairs(Query(db, sql, params)) do out[#out + 1] = Clean(r, info) end
    return out
end

-- Rows into a table, INSERT_BATCH per statement; a column the row has no value for is written as NULL.
local function InsertRows(db, info, rows)
    local cols = {}
    for _, c in ipairs(info.cols) do cols[#cols + 1] = QuoteName(c) end
    local head = 'INSERT INTO ' .. QuoteName(info.name) .. ' (' .. table.concat(cols, ', ') .. ') VALUES '
    local i = 1
    while i <= #rows do
        local last = math.min(#rows, i + INSERT_BATCH - 1)
        local tuples, params = {}, {}
        for r = i, last do
            local row, parts = rows[r], {}
            for k, c in ipairs(info.cols) do
                local v = row[c]
                if v == nil then
                    parts[k] = 'NULL'
                else
                    params[#params + 1] = v
                    parts[k] = info.kinds[c] == 'dt' and 'FROM_UNIXTIME(?)' or '?'
                end
            end
            tuples[#tuples + 1] = '(' .. table.concat(parts, ', ') .. ')'
        end
        db.query.await(head .. table.concat(tuples, ', '), params)
        i = last + 1
        Wait(0)
    end
end

local function CountRows(db, name)
    local ok, n = pcall(db.scalar.await, 'SELECT COUNT(*) FROM ' .. QuoteName(name), {})
    if not ok then return nil end
    return Int(n)
end

-- ============================================================================
--                       MONEY STATE (MOVES FORWARD ONLY)
-- ============================================================================
-- Before a restore or a forced copy replaces rows, every row that holds or held money is read by id; afterwards it
-- gets its state back (or comes back whole when the restored rows lack it). Paid stays paid, given stays given.

local MONEY_RUNS = [[cash_status IN ('paying', 'paid', 'forfeited', 'capped') OR cash_paid > 0 OR cash_reclaimed > 0]]
local MONEY_ITEMS = [[status IN ('giving', 'given', 'forfeited')]]

function Sys.moneySnapshot(db)
    local schema = Sys.schema()
    local snap = { runs = {}, items = {} }
    for _, name in ipairs({ 'cp_mission_runs', 'cp_mission_runs_archive' }) do
        local okR, rows = pcall(ReadRows, db, schema.tables[name], MONEY_RUNS)
        for _, r in ipairs(okR and rows or {}) do snap.runs[#snap.runs + 1] = { table = name, row = r } end
    end
    local okI, items = pcall(ReadRows, db, schema.tables.cp_item_rewards, MONEY_ITEMS)
    for _, r in ipairs(okI and items or {}) do snap.items[#snap.items + 1] = r end
    return snap
end

local function Exists(db, name, id)
    local ok, n = pcall(db.scalar.await, ('SELECT COUNT(*) FROM %s WHERE id = ?'):format(QuoteName(name)), { id })
    return ok and Int(n) > 0
end

-- Returns { updated, inserted } of runs and items put back.
function Sys.moneyReapply(db, snap)
    local schema = Sys.schema()
    local done = { updated = 0, inserted = 0 }
    for _, s in ipairs(snap.runs) do
        local r = s.row
        local where = nil
        if Exists(db, 'cp_mission_runs', r.id) then
            where = 'cp_mission_runs'
        elseif Exists(db, 'cp_mission_runs_archive', r.id) then
            where = 'cp_mission_runs_archive'
        end
        if where then
            db.update.await(
                ([[UPDATE %s SET cash_status = ?, cash_paid = ?, cash_reclaimed = ?, breakdown = ?
                WHERE id = ?]]):format(QuoteName(where)),
                {
                    r.cash_status,
                    Int(r.cash_paid),
                    Int(r.cash_reclaimed),
                    r.breakdown or '{}',
                    r.id,
                }
            )
            done.updated = done.updated + 1
        else
            InsertRows(db, schema.tables[s.table], { r })
            done.inserted = done.inserted + 1
        end
    end
    local items = schema.tables.cp_item_rewards
    for _, r in ipairs(snap.items) do
        if Exists(db, 'cp_item_rewards', r.id) then
            db.update.await(
                'UPDATE cp_item_rewards SET status = ?, given_at = IF(? = 0, NULL, FROM_UNIXTIME(?)) WHERE id = ?',
                { r.status, Int(r.given_at), Int(r.given_at), r.id })
            done.updated = done.updated + 1
        else
            local ok = pcall(InsertRows, db, items, { r })
            if not ok then
                db.update.await([[UPDATE cp_item_rewards SET status = ? WHERE citizenid = ? AND source = ?
                    AND source_key = ? AND item = ?]], { r.status, r.citizenid, r.source, r.source_key, r.item })
            end
            done.inserted = done.inserted + 1
        end
    end
    return done
end

-- ============================================================================
--                                   BACKUPS
-- ============================================================================
-- saves/_backups/index.json lists them; one backup is <name>.manifest.json, <name>.t.<table>.json per table and
-- <name>.f<n>.bin per file (custom and edited missions, uploaded logos, the banned-words file).

local function BackupPath(file) return Root() .. '/' .. BACKUP_DIR .. '/' .. file end

local function Index()
    local list = ReadJson(BackupPath('index.json'))
    if type(list) ~= 'table' then return {} end
    local out = {}
    for _, b in ipairs(list) do
        if type(b) == 'table' and type(b.name) == 'string' then out[#out + 1] = b end
    end
    table.sort(out, function(a, b)
        if Int(a.createdAt) ~= Int(b.createdAt) then return Int(a.createdAt) < Int(b.createdAt) end
        return a.name < b.name
    end)
    return out
end

local function SaveIndex(list) return WriteJson(BackupPath('index.json'), list) end

local function ValidName(name)
    return type(name) == 'string' and #name <= 64 and name:match('^%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-[%a%d%-]+$') ~= nil
end

-- The resource files a backup holds (each read with LoadResourceFile; a missing one is left out).
local function BackupFiles()
    local out, seen = {}, {}
    local function add(path)
        if type(path) ~= 'string' or path == '' or seen[path] or path:find('..', 1, true) then return end
        seen[path] = true
        out[#out + 1] = path
    end
    local export = type(Config.Builder) == 'table' and Config.Builder.exportPath or 'missions/custom/'
    export = type(export) == 'string' and export or 'missions/custom/'
    if export:sub(-1) ~= '/' then export = export .. '/' end
    local ok, rows = pcall(MySQL.query.await, 'SELECT id, file_path FROM cp_custom_missions', {})
    for _, r in ipairs(ok and type(rows) == 'table' and rows or {}) do
        add(r.file_path)
        local id = tostring(r.id)
        if id:match('^[%w_%-]+$') then
            for _, sub in ipairs({ '', 'archived/', 'overrides/', 'deleted/' }) do
                add(export .. sub .. id .. '.lua')
            end
        end
    end
    for key, d in pairs(type(Config.Departments) == 'table' and Config.Departments or {}) do
        local file = type(d) == 'table' and type(d.logo) == 'table' and d.logo.file or nil
        if type(file) == 'string' and file:match('^[%w_%-%.]+$') then add('logos/' .. file) end
        if type(key) == 'string' and key:match(DEPT_KEY) then
            add('logos/' .. key .. '.png')
            add('logos/' .. key .. '.webp')
        end
    end
    local banned = type(Config.Profile) == 'table' and Config.Profile.bannedWordsFile or nil
    if type(banned) == 'string' then add(banned) end
    return out
end

local function BackupName(kind)
    local base = ('%s-%s'):format(os.date('!%Y%m%d-%H%M%S', os.time()), kind)
    local fs = Fs()
    local name, n = base, 1
    while fs and fs.exists(BackupPath(name .. '.manifest.json')) do
        n = n + 1
        name = ('%s-%d'):format(base, n)
    end
    return name
end

local function ActorOf(src)
    local n = tonumber(src) or 0
    if n <= 0 then return 'console' end
    local ok, info = Call('Qbx', 'getInfo', n)
    return ok and type(info) == 'table' and info.citizenid or ('player:%d'):format(n)
end

-- Removes one backup's files and its index line.
local function RemoveBackup(name)
    local fs = Fs()
    local m = ReadJson(BackupPath(name .. '.manifest.json'))
    if fs and type(m) == 'table' then
        for _, part in ipairs(type(m.parts) == 'table' and m.parts or {}) do pcall(fs.remove, BackupPath(part)) end
        for _, f in ipairs(type(m.files) == 'table' and m.files or {}) do
            if type(f) == 'table' and type(f.file) == 'string' then pcall(fs.remove, BackupPath(f.file)) end
        end
    end
    if fs then pcall(fs.remove, BackupPath(name .. '.manifest.json')) end
    local keep = {}
    for _, b in ipairs(Index()) do if b.name ~= name then keep[#keep + 1] = b end end
    SaveIndex(keep)
end

-- The newest backup and the latest automatic one made before a restore are never removed.
local function Protected(list)
    local out = {}
    if list[#list] then out[list[#list].name] = true end
    for i = #list, 1, -1 do
        if list[i].kind == 'prerestore' then
            out[list[i].name] = true
            break
        end
    end
    return out
end
Sys._protected = Protected

local function Prune()
    local keep = math.max(1, Int(type(Config.Backups) == 'table' and Config.Backups.keep or 7))
    local list = Index()
    local protected = Protected(list)
    local removed = 0
    while #list > keep do
        local victim = nil
        for i, b in ipairs(list) do
            if not protected[b.name] then
                victim = i
                break
            end
        end
        if not victim then break end
        RemoveBackup(list[victim].name)
        table.remove(list, victim)
        removed = removed + 1
    end
    return removed
end

-- One backup of every table and file now. kind: 'manual', 'daily' or 'prerestore'. ok, BackupView | false, errKey.
function Sys.backup(src, kind)
    Db()
    local fs = Fs()
    local schema = Sys.schema()
    if not fs or not schema then return false, 'err.module_unavailable' end
    if not EnsureDir(BACKUP_DIR) then return false, 'err.backup_folder' end
    local name = BackupName(kind or 'manual')
    local manifest = {
        name = name,
        kind = kind or 'manual',
        createdAt = os.time(),
        by = ActorOf(src),
        version = GetResourceMetadata and GetResourceMetadata(CP.resource, 'version', 0) or nil,
        migration = CP.Migrations and CP.Migrations.version and CP.Migrations.version() or nil,
        storage = CP.Storage and CP.Storage.mode and CP.Storage.mode() or 'database',
        tables = {},
        parts = {},
        files = {},
        rows = 0,
        bytes = 0,
    }
    for _, tname in ipairs(schema.order) do
        if tname ~= MIGRATIONS_TABLE then
            local info = schema.tables[tname]
            local okR, rows = pcall(ReadRows, MySQL, info)
            if not okR then
                CP.err(TAG, 'backup %s: reading %s failed: %s', name, tname, tostring(rows))
                rows = nil
            end
            if rows then
                local part = ('%s.t.%s.json'):format(name, tname)
                local okW, bytes = WriteJson(BackupPath(part), rows)
                if not okW then
                    RemoveBackup(name)
                    return false, 'err.backup_write'
                end
                manifest.parts[#manifest.parts + 1] = part
                manifest.tables[tname] = #rows
                manifest.rows = manifest.rows + #rows
                manifest.bytes = manifest.bytes + (bytes or 0)
            end
        end
    end
    for i, path in ipairs(BackupFiles()) do
        local data = LoadResourceFile(CP.resource, path)
        if type(data) == 'string' and data ~= '' then
            local file = ('%s.f%d.bin'):format(name, i)
            local okW = pcall(fs.write, BackupPath(file), data)
            if okW then
                manifest.files[#manifest.files + 1] = { path = path, file = file, bytes = #data }
                manifest.bytes = manifest.bytes + #data
            end
        end
    end
    if not WriteJson(BackupPath(name .. '.manifest.json'), manifest) then
        RemoveBackup(name)
        return false, 'err.backup_write'
    end
    local list = Index()
    list[#list + 1] = {
        name = name,
        kind = manifest.kind,
        createdAt = manifest.createdAt,
        by = manifest.by,
        rows = manifest.rows,
        bytes = manifest.bytes,
        files = #manifest.files,
    }
    SaveIndex(list)
    Prune()
    CP.log(TAG, 'backup %s: %d rows, %d files', name, manifest.rows, #manifest.files)
    return true, list[#list]
end

function Sys.backups()
    local list = Index()
    local protected = Protected(list)
    local out = {}
    for i = #list, 1, -1 do
        local b = U.copy(list[i])
        b.protected = protected[b.name] == true
        out[#out + 1] = b
    end
    return out
end

local function Manifest(name)
    if not ValidName(name) then return nil end
    local m = ReadJson(BackupPath(name .. '.manifest.json'))
    if type(m) ~= 'table' or m.name ~= name then return nil end
    return m
end

local function KeepSetting(path)
    for _, p in ipairs(KEEP_SETTINGS) do
        if path:sub(1, #p) == p then return true end
    end
    return false
end

-- What a restore of this backup replaces, keeps and puts back (nothing changes).
function Sys.previewRestore(name)
    Db()
    local m = Manifest(name)
    if not m then return nil, 'err.backup_unknown' end
    local schema = Sys.schema()
    local replaced, kept = {}, {}
    for _, tname in ipairs(schema.order) do
        if KEEP_TABLES[tname] then
            kept[#kept + 1] = tname
        elseif m.tables[tname] ~= nil then
            replaced[#replaced + 1] = {
                name = tname,
                now = CountRows(MySQL, tname) or 0,
                backup = Int(m.tables[tname]),
            }
        else
            kept[#kept + 1] = tname
        end
    end
    local snap = Sys.moneySnapshot(MySQL)
    local files = {}
    for _, f in ipairs(m.files or {}) do files[#files + 1] = f.path end
    return {
        backup = {
            name = m.name,
            kind = m.kind,
            createdAt = m.createdAt,
            by = m.by,
            version = m.version,
            rows = m.rows,
        },
        replaced = replaced,
        kept = kept,
        keptSettings = KEEP_SETTINGS,
        files = files,
        moneyRuns = #snap.runs,
        moneyItems = #snap.items,
        runsGoing = RunsGoing(),
    }
end

-- Puts one backup's rows back (KEEP_TABLES and KEEP_SETTINGS stay), re-applies the money state and writes the files.
local function PutBack(m, snap)
    local schema = Sys.schema()
    for _, tname in ipairs(schema.order) do
        local info = schema.tables[tname]
        if not KEEP_TABLES[tname] and m.tables[tname] ~= nil then
            local rows = ReadJson(BackupPath(('%s.t.%s.json'):format(m.name, tname)))
            if type(rows) ~= 'table' then error(('the rows of %s are missing from the backup'):format(tname), 0) end
            if tname == 'cp_settings' then
                local keep = {}
                for _, r in ipairs(ReadRows(MySQL, info)) do
                    if KeepSetting(tostring(r.setting_key)) then keep[#keep + 1] = r end
                end
                MySQL.update.await('DELETE FROM cp_settings', {})
                local put = {}
                for _, r in ipairs(rows) do
                    if type(r) == 'table' and not KeepSetting(tostring(r.setting_key)) then put[#put + 1] = r end
                end
                for _, r in ipairs(keep) do put[#put + 1] = r end
                InsertRows(MySQL, info, put)
            else
                MySQL.update.await('DELETE FROM ' .. QuoteName(tname), {})
                InsertRows(MySQL, info, rows)
            end
        end
    end
    local money = Sys.moneyReapply(MySQL, snap)
    local fs = Fs()
    local written = 0
    for _, f in ipairs(m.files or {}) do
        local data = fs and fs.read(BackupPath(f.file)) or nil
        if type(data) == 'string' and type(f.path) == 'string' and not f.path:find('..', 1, true) then
            if SaveResourceFile(CP.resource, f.path, data, #data) then written = written + 1 end
        end
    end
    return money, written
end

-- The restore: the restore lock from the start, an automatic backup first, the money-safe put-back, one audit line,
-- then the owner restarts Crimson-Police (it never restarts itself).
function Sys.restore(src, name, reason)
    Db()
    local m = Manifest(name)
    if not m then return false, 'err.backup_unknown' end
    local running = RunsGoing()
    if running > 0 then return false, 'err.storage_runs_active' end
    local okL = Kit.lock('restore', { name = name })
    if not okL then return false, 'err.admin_busy' end
    local okM, errM = Maint.begin('restore', { by = ActorOf(src), backup = name })
    if not okM then
        Kit.unlock('restore')
        return false, errM
    end
    local okB, auto = Sys.backup(src, 'prerestore')
    if not okB then
        Maint.finish('restore')
        Kit.unlock('restore')
        return false, auto
    end
    local snap = Sys.moneySnapshot(MySQL)
    local res = table.pack(pcall(PutBack, m, snap))
    Kit.unlock('restore')
    if not res[1] then
        CP.err(TAG, 'restoring %s failed: %s. The automatic backup %s holds the data from just before.', name,
            tostring(res[2]), auto.name)
        Kit.auditSync(src, 'audit', 'backupRestoreFailed', name, nil, auto.name, reason, { critical = true })
        Maint.askRestart('restore')
        return false, 'err.restore_failed'
    end
    local money, files = res[2], res[3]
    Kit.auditSync(src, 'audit', 'backupRestored', name, auto.name,
        ('%d money rows kept, %d files'):format(money.updated + money.inserted, files), reason, { critical = true })
    Maint.askRestart('restore')
    return true, { backup = name, automatic = auto.name, money = money, files = files, restart = true }
end

function Sys.deleteBackup(name)
    if not Manifest(name) then return false, 'err.backup_unknown' end
    if Protected(Index())[name] then return false, 'err.backup_protected' end
    RemoveBackup(name)
    return true
end

-- ============================================================================
--                                   STORAGE
-- ============================================================================
-- cp_storage_meta in each store: generation (a uuid every switch writes into both) and state (active or
-- left_behind). A store a switch left behind starts with the left_behind lock: nothing is paid or changed there.

local META_UPSERT = [[INSERT INTO cp_storage_meta (meta_key, meta_value, updated_at) VALUES (?, ?, NOW())
    ON DUPLICATE KEY UPDATE meta_value = VALUES(meta_value), updated_at = VALUES(updated_at)]]

local function WriteMeta(db, generation, state)
    local ok1 = pcall(db.update.await, META_UPSERT, { 'generation', generation })
    local ok2 = pcall(db.update.await, META_UPSERT, { 'state', state })
    return ok1 and ok2
end

function Sys.storageMeta(db)
    db = db or MySQL
    local out = {}
    local ok, rows = pcall(db.query.await, 'SELECT meta_key, meta_value FROM cp_storage_meta', {})
    for _, r in ipairs(ok and type(rows) == 'table' and rows or {}) do out[tostring(r.meta_key)] = r.meta_value end
    return out
end

-- The other store as an oxmysql-shaped object: kind 'database' or 'files' (folder relative to the resource).
local function OpenStore(kind, folder)
    local mode = CP.Storage and CP.Storage.mode and CP.Storage.mode() or 'database'
    if kind == mode and (kind == 'database' or folder == (Config.Database and Config.Database.folder)) then
        return MySQL
    end
    if kind == 'database' then
        local real = CP.Storage and CP.Storage.realMySQL
        if type(real) == 'table' and type(real.query) == 'table' and GetResourceState('oxmysql') == 'started' then
            return real
        end
        return nil
    end
    local M = CP.Storage and CP.Storage.MemSQL
    if type(M) ~= 'table' then return nil end
    local dir = FolderPath(folder)
    if not M.fs.exists(dir .. '/_tables.json') then return nil end
    local engine = M.new({ store = M.folderStore(dir) })
    local ok = pcall(engine.load, engine)
    if not ok then return nil end
    return M.shim(engine, { resource = CP.resource })
end
Sys._openStore = OpenStore

local function HasData(kind, folder)
    if kind == 'files' then
        local fs = Fs()
        return fs ~= nil and fs.exists(FolderPath(folder) .. '/_tables.json')
    end
    local db = OpenStore('database')
    if not db then return false end
    local ok, n = pcall(db.scalar.await, 'SELECT COUNT(*) FROM cp_schema_migrations', {})
    return ok and Int(n) > 0
end

-- System → Storage: the facts of /CrimsonPoliceAdmin storage as data, the in-game switch, the marker, backups.
function Sys.storageView()
    local out = Has('Admin', 'storageStatus') and select(2, Call('Admin', 'storageStatus')) or {}
    out = type(out) == 'table' and out or {}
    out.override = CP.Storage and CP.Storage.override and CP.Storage.override() or nil
    local meta = Sys.storageMeta()
    out.generation, out.state = meta.generation, meta.state
    out.maintenance = Maint.view()
    out.runsGoing = RunsGoing()
    out.busy = Kit.busy() or nil
    out.backups = #Index()
    return out
end

local function SetKvp(key, v)
    if v == nil then
        if DeleteResourceKvp then DeleteResourceKvp(key) end
    elseif SetResourceKvp then
        SetResourceKvp(key, v)
    end
end

-- The switch: written to the server's KVP (read by modules/storage before Config.Database at the next start), the
-- generation marker into both stores, then the storage lock until the owner restarts.
function Sys.switchStorage(src, enabled, folder, startEmpty)
    local S = CP.Storage
    if type(enabled) ~= 'boolean' then return false, 'err.invalid_payload' end
    local kind = enabled and 'database' or 'files'
    if kind == 'files' then
        folder = type(folder) == 'string' and U.trim(folder) or 'saves'
        if folder == '' then folder = 'saves' end
        if not (S and S.validFolder and S.validFolder(folder)) then return false, 'err.storage_folder' end
    else
        folder = nil
    end
    local mode = S and S.mode and S.mode() or 'database'
    local current = Config.Database and Config.Database.folder or 'saves'
    if kind == mode and (kind == 'database' or folder == current) then return false, 'err.storage_same' end
    if RunsGoing() > 0 then return false, 'err.storage_runs_active' end
    if not HasData(kind, folder) and not startEmpty then return false, 'err.storage_target_empty' end
    local generation = U.uuid()
    local target = OpenStore(kind, folder)
    if target and target ~= MySQL then WriteMeta(target, generation, 'active') end
    if not WriteMeta(MySQL, generation, 'left_behind') then return false, 'err.internal' end
    SetKvp(S.KVP_MODE, kind)
    SetKvp(S.KVP_FOLDER, folder)
    Maint.begin('storage', { by = ActorOf(src), switch = kind })
    Maint.askRestart('storage')
    return true, { mode = kind, folder = folder, generation = generation, restart = true }
end

-- ============================================================================
--                                 DEPARTMENTS
-- ============================================================================

local function Added(key)
    return CP.Settings and CP.Settings.entry and type(key) == 'string'
        and (CP.Settings.entry('Departments.' .. key) or {}).added == true
end

local function DeptRaw(key)
    local d = type(Config.Departments) == 'table' and Config.Departments[key] or nil
    return type(d) == 'table' and d or nil
end

local function Words(list, max)
    local out = {}
    for _, v in ipairs(type(list) == 'table' and list or {}) do
        if type(v) == 'string' and U.trim(v) ~= '' then out[#out + 1] = U.trim(v) end
        if #out >= (max or 20) then break end
    end
    return out
end

-- A department record from the wizard's fields (the Settings check and the department validator check it again).
local function Record(p, base)
    local r = U.deepcopy(base or {})
    if p.label ~= nil then r.label = type(p.label) == 'string' and U.trim(p.label) or p.label end
    if p.short ~= nil then r.short = type(p.short) == 'string' and U.trim(p.short) or p.short end
    if p.jobs ~= nil then r.jobs = Words(p.jobs) end
    if p.supervisorGrade ~= nil then r.supervisorGrade = math.tointeger(tonumber(p.supervisorGrade)) end
    if p.societyAccount ~= nil then
        local acc = type(p.societyAccount) == 'string' and U.trim(p.societyAccount) or ''
        r.societyAccount = acc ~= '' and acc or nil
    end
    if type(p.theme) == 'table' then
        r.theme = type(r.theme) == 'table' and r.theme or {}
        for _, k in ipairs({ 'primary', 'accent', 'background', 'surface', 'text' }) do
            if p.theme[k] ~= nil then r.theme[k] = p.theme[k] ~= '' and p.theme[k] or nil end
        end
    end
    if type(p.logo) == 'table' then
        r.logo = type(r.logo) == 'table' and r.logo or {}
        for _, k in ipairs({ 'url', 'file', 'watermark', 'opacity', 'size', 'grayscale' }) do
            if p.logo[k] ~= nil then r.logo[k] = p.logo[k] ~= '' and p.logo[k] or nil end
        end
        if next(r.logo) == nil then r.logo = nil end
    end
    return r
end

local function Plain(v)
    if type(v) == 'vector3' or type(v) == 'vector4' then return { x = v.x, y = v.y, z = v.z, w = v.w } end
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = Plain(x) end
    return out
end

-- Departments screen: every department as it is set now, the Qbox jobs to pick from, who uses which job.
function Sys.departmentSetup()
    local deps, taken = {}, {}
    local keys = {}
    for k in pairs(type(Config.Departments) == 'table' and Config.Departments or {}) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
        local d = DeptRaw(k)
        if d then
            deps[#deps + 1] = {
                key = k,
                added = Added(k),
                enabled = d.enabled ~= false,
                label = d.label,
                short = d.short,
                jobs = Plain(d.jobs),
                supervisorGrade = d.supervisorGrade,
                societyAccount = d.societyAccount,
                theme = Plain(d.theme),
                logo = Plain(d.logo),
            }
            for _, j in ipairs(type(d.jobs) == 'table' and d.jobs or {}) do taken[j] = k end
        end
    end
    local jobs = {}
    local okJ, list = Call('Qbx', 'getJobs')
    for name, job in pairs(okJ and type(list) == 'table' and list or {}) do
        local grades = {}
        for lvl, g in pairs(type(job) == 'table' and type(job.grades) == 'table' and job.grades or {}) do
            local n = math.tointeger(tonumber(lvl))
            if n then grades[#grades + 1] = { level = n, name = type(g) == 'table' and g.name or nil } end
        end
        table.sort(grades, function(a, b) return a.level < b.level end)
        jobs[#jobs + 1] = {
            name = tostring(name),
            label = type(job) == 'table' and job.label or nil,
            grades = grades,
            usedBy = taken[name],
        }
    end
    table.sort(jobs, function(a, b) return a.name < b.name end)
    return {
        departments = deps,
        jobs = jobs,
        cashSource = Config.Cash and Config.Cash.source or 'server',
        runsGoing = RunsGoing(),
    }
end

local function DeptRows(key)
    local n = 0
    for _, q in ipairs({
        'SELECT COUNT(*) FROM cp_mission_runs WHERE department = ?',
        'SELECT COUNT(*) FROM cp_mission_runs_archive WHERE department = ?',
        'SELECT COUNT(*) FROM cp_officers WHERE department = ?',
        'SELECT COUNT(*) FROM cp_commendations WHERE department = ?',
        'SELECT COUNT(*) FROM cp_profile_reports WHERE department = ?',
        'SELECT COUNT(*) FROM cp_dept_bounties WHERE winner = ?',
        'SELECT COUNT(*) FROM cp_dept_funding WHERE department = ?',
    }) do
        local ok, c = pcall(MySQL.scalar.await, q, { key })
        if not ok then return nil end
        n = n + Int(c)
    end
    return n
end
Sys._deptRows = DeptRows

-- The officers of a department who are online (for the toast when it is turned off).
local function OnlineOf(key)
    local out = {}
    local okP, list = Call('Qbx', 'getOnlinePlayers')
    for _, s in ipairs(okP and type(list) == 'table' and list or {}) do
        local okI, info = Call('Qbx', 'getInfo', s)
        if okI and type(info) == 'table' then
            local d = DeptRaw(key)
            for _, j in ipairs(d and type(d.jobs) == 'table' and d.jobs or {}) do
                if j == info.job.name then out[#out + 1] = s end
            end
        end
    end
    return out
end

-- ============================================================================
--                                 LOGO UPLOAD
-- ============================================================================

local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local B64_INDEX = {}
for i = 1, #B64 do B64_INDEX[B64:byte(i)] = i - 1 end

-- base64 → bytes; nil for a text that is not base64.
function Sys._b64decode(s)
    if type(s) ~= 'string' then return nil end
    s = s:gsub('%s', '')
    if #s % 4 ~= 0 or s:find('[^%w%+/=]') then return nil end
    local out = {}
    for i = 1, #s, 4 do
        local a, b, c, d = s:byte(i, i + 3)
        local na, nb = B64_INDEX[a], B64_INDEX[b]
        if na == nil or nb == nil then return nil end
        local nc = c ~= 61 and B64_INDEX[c] or 0
        local nd = d ~= 61 and B64_INDEX[d] or 0
        local n = na * 262144 + nb * 4096 + nc * 64 + nd
        out[#out + 1] = string.char(n >> 16)
        if c ~= 61 then out[#out + 1] = string.char((n >> 8) & 255) end
        if d ~= 61 then out[#out + 1] = string.char(n & 255) end
    end
    return table.concat(out)
end

-- 'png' | 'webp' | nil from the first bytes (never SVG: it can carry script).
function Sys._imageKind(data)
    if type(data) ~= 'string' then return nil end
    if data:sub(1, 8) == '\137PNG\r\n\26\n' then return 'png' end
    if data:sub(1, 4) == 'RIFF' and data:sub(9, 12) == 'WEBP' then return 'webp' end
    return nil
end

local function DropStaleUploads()
    local now = os.time()
    for s, u in pairs(uploads) do
        if now - u.at > UPLOAD_TTL then uploads[s] = nil end
    end
end

-- One chunk; the last one writes logos/<key>.<png|webp> and points the department's logo.file at it.
local function UploadChunk(ctx)
    local p = ctx.payload
    DropStaleUploads()
    local key = p.department
    if type(key) ~= 'string' or not DeptRaw(key) then return false, 'err.dept_unknown' end
    local id = type(p.uploadId) == 'string' and p.uploadId:match('^[%w%-]+$') and p.uploadId or nil
    local index, total = Int(p.index), Int(p.total)
    if not id or #id > 40 or total < 1 or total > 128 or index < 1 or index > total then
        return false, 'err.invalid_payload'
    end
    if type(p.data) ~= 'string' or #p.data > UPLOAD_CHUNK then return false, 'err.upload_chunk' end
    local u = uploads[ctx.src]
    if u and u.id ~= id then return false, 'err.upload_busy' end
    if not u then
        if index ~= 1 then return false, 'err.upload_expired' end
        u = { id = id, key = key, chunks = {}, n = 0, total = total, bytes = 0, at = os.time() }
        uploads[ctx.src] = u
    end
    if u.key ~= key or u.total ~= total then return false, 'err.invalid_payload' end
    local bytes = Sys._b64decode(p.data)
    if not bytes then
        uploads[ctx.src] = nil
        return false, 'err.upload_chunk'
    end
    if not u.chunks[index] then
        u.chunks[index] = bytes
        u.n = u.n + 1
        u.bytes = u.bytes + #bytes
    end
    u.at = os.time()
    if u.bytes > UPLOAD_MAX then
        uploads[ctx.src] = nil
        return false, 'err.upload_too_big'
    end
    if u.n < u.total then return true, { received = u.n, total = u.total } end
    uploads[ctx.src] = nil
    local data = table.concat(u.chunks)
    local kind = Sys._imageKind(data)
    if not kind then return false, 'err.upload_type' end
    local file = ('%s.%s'):format(key, kind)
    if not SaveResourceFile(CP.resource, 'logos/' .. file, data, #data) then return false, 'err.upload_write' end
    local ok, err
    if Added(key) then
        local rec = Record({ logo = { file = file } }, DeptRaw(key))
        ok, err = CP.Settings.set(ctx.src, 'Departments.' .. key, rec, false, { reason = ctx.reason })
    else
        ok, err = CP.Settings.set(ctx.src, ('Departments.%s.logo.file'):format(key), file, false,
            { reason = ctx.reason })
    end
    if not ok then return false, err end
    ctx.audit('logoUploaded', key, nil, ('%s %d B'):format(file, #data))
    return true, { file = file, bytes = #data, restart = true }
end

-- ============================================================================
--                                    DESKS
-- ============================================================================

local function Desks() return U.deepcopy(type(Config.Tablet) == 'table' and Config.Tablet.desks or {}) or {} end

local function Vec(v, fallback)
    if type(v) ~= 'table' and type(v) ~= 'vector3' then return fallback end
    local x, y, z = tonumber(v.x), tonumber(v.y), tonumber(v.z)
    if not (x and y and z) then return fallback end
    return vector3(x + 0.0, y + 0.0, z + 0.0)
end

local function DeskFrom(p, base)
    local d = U.deepcopy(base or {})
    if p.label ~= nil then d.label = type(p.label) == 'string' and U.trim(p.label) or p.label end
    if p.size ~= nil then d.size = Vec(p.size, d.size) end
    if p.rotation ~= nil then d.rotation = (tonumber(p.rotation) or 0) + 0.0 end
    if p.departments ~= nil then
        local list = Words(p.departments)
        d.departments = #list > 0 and list or nil
    end
    if p.prop ~= nil then d.prop = (type(p.prop) == 'string' and p.prop ~= '') and p.prop or false end
    return d
end

local function SaveDesks(src, list, reason)
    return CP.Settings.set(src, 'Tablet.desks', list, false, { reason = reason })
end

-- The admin's own ped position (server coordinates; the client sends none).
local function MyPosition(src)
    local ped = PedOf(src)
    if not ped then return nil end
    local c = GetEntityCoords(ped)
    local h = GetEntityHeading and GetEntityHeading(ped) or 0.0
    return { x = c.x, y = c.y, z = c.z, heading = h }
end
Sys._myPosition = MyPosition

-- The coordinates of row index of a list setting (read from the stored setting, never sent by the client).
function Sys.positionOf(path, index)
    if type(path) ~= 'string' then return nil end
    local e = CP.Settings and CP.Settings.entry and CP.Settings.entry(path)
    if not e then return nil end
    local list = U.getPath(Config, path)
    local row = type(list) == 'table' and list[Int(index)] or nil
    if row == nil then return nil end
    if path == 'Tablet.desks' then return row.coords end
    local rows = e.rows
    if type(rows) ~= 'table' then return nil end
    if rows.bare then return row end
    for _, f in ipairs(rows.fields or {}) do
        if f.position and type(row) == 'table' then return row[f.key] end
    end
    return nil
end

-- ============================================================================
--                                   SUPPORT
-- ============================================================================

local function FixKey(err)
    if type(err) ~= 'string' then return nil end
    return 'sysadmin.fix.' .. err:gsub('^err%.', '')
end

function Sys.checkAccess(src, via)
    local okE, res = Call('Access', 'explain', src, via)
    if not okE or type(res) ~= 'table' then return nil, 'err.module_unavailable' end
    res.fix = FixKey(res.error)
    return res
end

local STATE_KEYS = {
    'screen',
    'nuiFocus',
    'nuiKeepInput',
    'tabletOpen',
    'panel',
    'pickup',
    'run',
    'scriptCam',
    'playerControl',
    'frozen',
    'dead',
    'lastStand',
    'metaDead',
    'inVehicle',
    'pauseMenu',
}

-- A client's Diag.state() reply: only the known keys, booleans and short texts.
local function CleanState(s)
    if type(s) ~= 'table' then return nil end
    local out = {}
    for _, k in ipairs(STATE_KEYS) do
        local v = s[k]
        if type(v) == 'boolean' then
            out[k] = v
        elseif type(v) == 'string' or type(v) == 'number' then
            out[k] = tostring(v):sub(1, 64)
        end
    end
    return out
end

RegisterNetEvent(CP.e('server:diagState'), function(token, state)
    local src = source
    local p = type(token) == 'string' and statePending[token] or nil
    if not p or p.src ~= src then return end
    p.state = CleanState(state) or {}
end)

-- Asks the player's client for Diag.state() and waits up to STATE_WAIT_MS.
function Sys.clientState(target)
    local token = U.uuid()
    statePending[token] = { src = target }
    TriggerClientEvent(CP.e('client:diagState'), target, token)
    local waited = 0
    while not statePending[token].state and waited < STATE_WAIT_MS do
        Wait(100)
        waited = waited + 100
    end
    local state = statePending[token].state
    statePending[token] = nil
    return state
end
Sys._statePending = statePending

-- ============================================================================
--                              AUDIT LOG EXPORTS
-- ============================================================================

local AUDIT_SELECT = [[SELECT a.id, a.actor, a.role, a.category, a.action, a.target, a.old_value, a.new_value, a.reason,
  UNIX_TIMESTAMP(a.created_at) AS created_ts, o.display_name
  FROM cp_audit a LEFT JOIN cp_officers o ON o.citizenid = a.actor]]

local function AuditRows(args, limit, offset)
    local where, params = CP.Admin._auditWhere(args)
    local rows = MySQL.query.await(('%s WHERE %s ORDER BY a.created_at DESC, a.id DESC LIMIT %d OFFSET %d'):format(
        AUDIT_SELECT,
        where,
        limit,
        offset
    ), params) or {}
    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = {
            id = math.tointeger(tonumber(r.id)),
            actor = r.actor,
            actorName = r.display_name,
            role = r.role,
            category = r.category,
            action = r.action,
            target = r.target,
            oldValue = r.old_value,
            newValue = r.new_value,
            reason = r.reason,
            createdAt = math.floor(tonumber(r.created_ts) or 0),
        }
    end
    return out
end

local function AuditTotal(args)
    local where, params = CP.Admin._auditWhere(args)
    local n = MySQL.scalar.await(
        ('SELECT COUNT(*) FROM cp_audit a LEFT JOIN cp_officers o ON o.citizenid = a.actor WHERE %s'):format(where),
        params)
    return Int(n)
end

-- One part of AUDIT_PART rows (export beyond the 5000 of one part).
function Sys.auditPart(args, part)
    if not (Has('Admin', '_auditWhere') and Has('Admin', '_csv')) then return nil, 'err.module_unavailable' end
    local total = AuditTotal(args)
    local parts = math.max(1, math.ceil(total / AUDIT_PART))
    part = math.max(1, math.min(parts, Int(part) > 0 and Int(part) or 1))
    local rows = AuditRows(args, AUDIT_PART, (part - 1) * AUDIT_PART)
    return { csv = CP.Admin._csv(rows), rows = #rows, part = part, parts = parts, total = total }
end

-- Save to server: every matching row (up to AUDIT_SAVE_MAX) into saves/exports/audit-<time>.csv.
function Sys.saveAudit(args)
    if not (Has('Admin', '_auditWhere') and Has('Admin', '_csv')) then return nil, 'err.module_unavailable' end
    if not EnsureDir(EXPORT_DIR) then return nil, 'err.export_folder' end
    local total = math.min(AuditTotal(args), AUDIT_SAVE_MAX)
    local chunks, n = {}, 0
    for offset = 0, math.max(0, total - 1), AUDIT_PART do
        local rows = AuditRows(args, AUDIT_PART, offset)
        local csv = CP.Admin._csv(rows)
        if offset > 0 then csv = csv:gsub('^[^\n]*\n?', '') end
        if csv ~= '' then chunks[#chunks + 1] = csv end
        n = n + #rows
        Wait(0)
    end
    local name = ('audit-%s.csv'):format(os.date('!%Y%m%d-%H%M%S', os.time()))
    local fs = Fs()
    local ok = fs and pcall(fs.write, Root() .. '/' .. EXPORT_DIR .. '/' .. name, table.concat(chunks, '\n'))
    if not ok then return nil, 'err.export_write' end
    return { path = EXPORT_DIR .. '/' .. name, rows = n, truncated = total >= AUDIT_SAVE_MAX }
end

-- ============================================================================
--                            STORAGE, BACKUPS (NET)
-- ============================================================================

Kit.callback('admin:getStorage', 'storageAdmin', function(ctx)
    if not CP.Net.rateOk(ctx.src, 'sys:storage', 1, 5000) then return nil, 'err.rate_limited' end
    return Sys.storageView()
end, { rate = 1 })

Kit.action('server:admin:storageCopy', 'storageAdmin', function(ctx)
    local p = ctx.payload
    local direction = p.direction
    if direction ~= 'database-to-files' and direction ~= 'files-to-database' then
        return false, 'err.invalid_payload'
    end
    local force = p.force == true
    if RunsGoing() > 0 then return false, 'err.storage_runs_active' end
    local okM, errM = Maint.begin('storage', { by = ActorOf(ctx.src), copy = direction })
    if not okM then return false, errM end
    local mode = CP.Storage and CP.Storage.mode and CP.Storage.mode() or 'database'
    local targetKind = direction == 'database-to-files' and 'files' or 'database'
    local folder = Config.Database and Config.Database.folder or 'saves'
    -- a forced copy over a store with data keeps that store's money state (paid stays paid)
    local snap = nil
    if force then
        local target = OpenStore(targetKind, folder)
        if target then snap = Sys.moneySnapshot(target) end
    end
    local okC, ok, key, vars = Call('Admin', 'storageCopy', ctx.src, direction, force)
    if not okC or not ok then
        Maint.finish('storage')
        return false, key or 'err.refused'
    end
    local money = nil
    if snap and (#snap.runs > 0 or #snap.items > 0) then
        local target = OpenStore(targetKind, folder)
        if target then money = Sys.moneyReapply(target, snap) end
    end
    ctx.audit('storageCopy', direction, force and 'force' or nil, vars and ('%s rows'):format(tostring(vars.rows)))
    -- the store in use changed under the running server: only a restart reads it again
    local live = targetKind == mode
    if live then Maint.askRestart('storage') else Maint.finish('storage') end
    return true, { message = key, vars = vars, money = money, restart = live }
end, {
    requestId = true,
    confirm = function(p) return p.force == true and 'REPLACE' or nil end,
    rate = 1,
})

Kit.action('server:admin:setStorageMode', 'storageAdmin', function(ctx)
    local p = ctx.payload
    local ok, res = Sys.switchStorage(ctx.src, p.enabled, p.folder, p.startEmpty == true)
    if not ok then return false, res end
    ctx.audit('storageSwitch', res.mode, nil, res.folder or 'database', { critical = true })
    return true, res
end, { reason = true, requestId = true, confirm = 'SWITCH', rate = 1 })

Kit.action('server:admin:useStoreAgain', 'storageAdmin', function(ctx)
    local kind = Maint.active()
    if kind ~= 'left_behind' then return false, 'err.not_left_behind' end
    if not WriteMeta(MySQL, U.uuid(), 'active') then return false, 'err.internal' end
    Maint.finish('left_behind')
    ctx.audit('storageUseAgain', nil, 'left_behind', 'active', { critical = true })
    return true, { state = 'active' }
end, { reason = true, confirm = 'USE', maintenance = true, rate = 1 })

Kit.callback('admin:getBackups', 'storageAdmin', function()
    return {
        backups = Sys.backups(),
        keep = Config.Backups and Config.Backups.keep or 7,
        daily = Config.Backups and Config.Backups.daily == true,
        folder = BACKUP_DIR,
    }
end, { rate = 2 })

Kit.action('server:admin:backupNow', 'storageAdmin', function(ctx)
    if not CP.Net.rateOk(ctx.src, 'sys:backup', 1, 60000) then return false, 'err.rate_limited' end
    local ok, res = Kit.withLock('backup', function() return Sys.backup(ctx.src, 'manual') end)
    if not ok then return false, res end
    ctx.audit('backupCreated', res.name, nil, ('%d rows'):format(Int(res.rows)))
    return true, res
end, { reason = 'optional', rate = 1 })

Kit.callback('admin:previewRestore', 'storageAdmin', function(ctx)
    local view, err = Sys.previewRestore(ctx.args.name)
    if not view then return nil, err end
    view.previewToken, view.expiresAt = ctx.preview('restore', { ctx.args.name }, { name = ctx.args.name })
    return view
end, { rate = 1 })

Kit.action('server:admin:restoreBackup', 'storageAdmin', function(ctx)
    local p = ctx.payload
    local okT, effect = ctx.consume(p.previewToken, 'restore', { p.name })
    if not okT then return false, effect end
    if type(effect) ~= 'table' or effect.name ~= p.name then return false, 'err.preview_stale' end
    local ok, res = Sys.restore(ctx.src, p.name, ctx.reason)
    if ok then ctx.audited = true end
    return ok, res
end, { reason = true, requestId = true, confirm = 'RESTORE', rate = 1 })

Kit.action('server:admin:deleteBackup', 'storageAdmin', function(ctx)
    local ok, err = Sys.deleteBackup(ctx.payload.name)
    if not ok then return false, err end
    ctx.audit('backupDeleted', ctx.payload.name)
    return true, { name = ctx.payload.name }
end, {
    reason = true,
    confirm = function(p) return type(p.name) == 'string' and p.name or '?' end,
    rate = 1,
})

-- ============================================================================
--                    WEBHOOKS, PROBLEMS, INTEGRATIONS (NET)
-- ============================================================================

-- Read only: on/off and the server.cfg line to paste. The link itself never reaches the NUI (not even a part).
function Sys.webhooks()
    local out = {}
    local ok, list = Call('Admin', 'webhooks')
    for _, w in ipairs(ok and type(list) == 'table' and list or {}) do
        out[#out + 1] = {
            category = w.category,
            convar = w.convar,
            state = w.state,
            discord = w.discord == true,
            line = ('set %s "https://discord.com/api/webhooks/<id>/<token>"'):format(tostring(w.convar)),
        }
    end
    return out
end

Kit.callback('admin:getWebhooks', 'openAdmin', function() return { webhooks = Sys.webhooks() } end, { rate = 2 })

Kit.callback('admin:getProblems', 'openAdmin', function(ctx)
    local a = ctx.args
    local opts = { limit = 200 }
    if type(a.tag) == 'string' and a.tag ~= '' and #a.tag <= 32 then opts.tag = a.tag end
    if a.level == 'warn' or a.level == 'error' then opts.level = a.level end
    local lines = CP.Problems and CP.Problems.list(opts) or {}
    local tags, seen = {}, {}
    for _, l in ipairs(CP.Problems and CP.Problems.list({ limit = 200 }) or {}) do
        if not seen[l.tag] then
            seen[l.tag] = true
            tags[#tags + 1] = l.tag
        end
    end
    table.sort(tags)
    return { lines = lines, total = CP.Problems and CP.Problems.total() or 0, tags = tags }
end, { rate = 2 })

local function ResourceRow(name, required)
    local state = GetResourceState and GetResourceState(name) or 'missing'
    local version = nil
    if state ~= 'missing' and GetResourceMetadata then
        local ok, v = pcall(GetResourceMetadata, name, 'version', 0)
        if ok and type(v) == 'string' and v ~= '' then version = v:sub(1, 32) end
    end
    return { name = name, state = state, version = version, required = required }
end

function Sys.integrations()
    local out = { resources = {}, checklist = CHECKLIST }
    for _, name in ipairs(REQUIRED_RESOURCES) do out.resources[#out.resources + 1] = ResourceRow(name, true) end
    for _, name in ipairs(OPTIONAL_RESOURCES) do out.resources[#out.resources + 1] = ResourceRow(name, false) end
    local arena = {
        state = GetResourceState and GetResourceState('Crimson-Arena') or 'missing',
        players = 0,
        zones = {},
    }
    local okP, list = Call('Qbx', 'getOnlinePlayers')
    for _, s in ipairs(okP and type(list) == 'table' and list or {}) do
        local okA, inArena = Call('Alerts', 'inArena', s)
        if okA and inArena then arena.players = arena.players + 1 end
    end
    for _, z in ipairs(type(Config.Builder) == 'table' and Config.Builder.noBuildZones or {}) do
        if type(z) == 'table' and type(z.label) == 'string' and z.label:find('Crimson-Arena', 1, true) then
            arena.zones[#arena.zones + 1] = { label = z.label, coords = Plain(z.coords), radius = z.radius }
        end
    end
    out.arena = arena
    return out
end

Kit.callback('admin:getIntegrations', 'openAdmin', function() return Sys.integrations() end, { rate = 2 })

-- ============================================================================
--                              DEPARTMENTS (NET)
-- ============================================================================

Kit.callback('admin:getDepartmentSetup', 'departmentsAdmin', function() return Sys.departmentSetup() end, { rate = 2 })

Kit.action('server:admin:addDepartment', 'departmentsAdmin', function(ctx)
    local p = ctx.payload
    local key = type(p.key) == 'string' and U.trim(p.key):lower() or ''
    if #key < 1 or #key > 32 or not key:match(DEPT_KEY) then return false, 'err.dept_key' end
    if DeptRaw(key) then return false, 'err.dept_exists' end
    local from = type(p.themeFrom) == 'string' and DeptRaw(p.themeFrom) or nil
    local base = {
        enabled = true,
        theme = from and U.deepcopy(from.theme)
            or { primary = '#1f4e8c', accent = '#f2c230', background = '#0d1522', surface = '#152235' },
    }
    if type(base.theme) == 'table' then base.theme.personalAccents = nil end
    local rec = Record(p, base)
    rec.enabled = true
    local ok, err = CP.Settings.set(ctx.src, 'Departments.' .. key, Plain(rec), false, { reason = ctx.reason })
    if not ok then return false, err end
    ctx.audit('departmentAdded', key, nil, rec.short)
    ctx.changed('department')
    return true, { key = key }
end, { reason = 'optional', rate = 1 })

-- The department form: a config.lua department saves one setting per field, one added in game its record.
Kit.action('server:admin:saveDepartment', 'departmentsAdmin', function(ctx)
    local p = ctx.payload
    local key = p.key
    local d = type(key) == 'string' and DeptRaw(key) or nil
    if not d then return false, 'err.dept_unknown' end
    local f = type(p.fields) == 'table' and p.fields or {}
    if Added(key) then
        local rec = Record(f, d)
        return CP.Settings.set(ctx.src, 'Departments.' .. key, Plain(rec), false, { reason = ctx.reason })
    end
    local rec = Record(f, {})
    local changes = {}
    local function put(leaf, v)
        local path = ('Departments.%s.%s'):format(key, leaf)
        if not CP.Settings.entry(path) then return end
        if v == nil then
            changes[#changes + 1] = { path = path, none = true }
        else
            changes[#changes + 1] = { path = path, value = v }
        end
    end
    for _, k in ipairs({ 'label', 'short', 'jobs', 'supervisorGrade', 'societyAccount' }) do
        if f[k] ~= nil then put(k, Plain(rec[k])) end
    end
    if type(f.theme) == 'table' then
        for _, k in ipairs({ 'primary', 'accent', 'background', 'surface', 'text' }) do
            if f.theme[k] ~= nil then put('theme.' .. k, rec.theme and rec.theme[k]) end
        end
    end
    if type(f.logo) == 'table' then
        for _, k in ipairs({ 'url', 'file', 'watermark', 'opacity', 'size', 'grayscale' }) do
            if f.logo[k] ~= nil then put('logo.' .. k, rec.logo and rec.logo[k]) end
        end
    end
    if #changes == 0 then return true, {} end
    return CP.Settings.setMany(ctx.src, changes, { reason = ctx.reason })
end, { reason = 'optional', rate = 2 })

Kit.action('server:admin:setDepartmentEnabled', 'departmentsAdmin', function(ctx)
    local p = ctx.payload
    local d = type(p.key) == 'string' and DeptRaw(p.key) or nil
    if not d then return false, 'err.dept_unknown' end
    if type(p.enabled) ~= 'boolean' then return false, 'err.invalid_payload' end
    if (d.enabled ~= false) == p.enabled then return true, { key = p.key, enabled = p.enabled } end
    local ok, err
    if Added(p.key) then
        local rec = U.deepcopy(d)
        rec.enabled = p.enabled
        ok, err = CP.Settings.set(ctx.src, 'Departments.' .. p.key, Plain(rec), false, { reason = ctx.reason })
    else
        ok, err = CP.Settings.set(ctx.src, ('Departments.%s.enabled'):format(p.key), p.enabled, false,
            { reason = ctx.reason })
    end
    if not ok then return false, err end
    ctx.audit(p.enabled and 'departmentOn' or 'departmentOff', p.key, p.enabled and 'off' or 'on',
        p.enabled and 'on' or 'off')
    if not p.enabled and CP.Tablet and CP.Tablet.notifyMany then
        pcall(CP.Tablet.notifyMany, OnlineOf(p.key), 'warning', 'sysadmin.dept_off_notice', { name = d.label })
    end
    ctx.changed('department')
    return true, { key = p.key, enabled = p.enabled }
end, {
    reason = true,
    confirm = function(p)
        if p.enabled ~= false then return nil end
        local d = type(p.key) == 'string' and DeptRaw(p.key) or nil
        return d and tostring(d.short or p.key) or '?'
    end,
    rate = 1,
})

Kit.action('server:admin:deleteDepartment', 'departmentsAdmin', function(ctx)
    local key = ctx.payload.key
    local d = type(key) == 'string' and DeptRaw(key) or nil
    if not d then return false, 'err.dept_unknown' end
    if not Added(key) then return false, 'err.dept_builtin' end
    local rows = DeptRows(key)
    if rows == nil then return false, 'err.internal' end
    if rows > 0 then return false, 'err.dept_has_rows' end
    local enabled = 0
    for k, x in pairs(Config.Departments) do
        if k ~= key and type(x) == 'table' and x.enabled ~= false then enabled = enabled + 1 end
    end
    if enabled == 0 then return false, 'err.dept_last' end
    local ok, err = CP.Settings.set(ctx.src, 'Departments.' .. key, nil, true, { reason = ctx.reason })
    if not ok then return false, err end
    ctx.audit('departmentDeleted', key, d.short)
    ctx.changed('department')
    return true, { key = key }
end, {
    reason = true,
    confirm = function(p)
        local d = type(p.key) == 'string' and DeptRaw(p.key) or nil
        return d and tostring(d.short or p.key) or '?'
    end,
    rate = 1,
})

Kit.action('server:admin:uploadLogo', 'departmentsAdmin', UploadChunk, { reason = 'optional', rate = 20 })

-- ============================================================================
--                          DESKS AND POSITIONS (NET)
-- ============================================================================

Kit.action('server:admin:addDeskHere', 'departmentsAdmin', function(ctx)
    local pos = MyPosition(ctx.src)
    if not pos then return false, 'err.no_position' end
    local p = ctx.payload
    local desk = DeskFrom(p, {
        label = 'Desk',
        size = vector3(1.2, 0.8, 1.0),
        rotation = pos.heading + 0.0,
        prop = false,
    })
    desk.coords = vector3(pos.x + 0.0, pos.y + 0.0, pos.z + 0.0)
    local list = Desks()
    list[#list + 1] = desk
    local ok, err = SaveDesks(ctx.src, list, ctx.reason)
    if not ok then return false, err end
    ctx.audit('deskAdded', desk.label, nil, ('%.1f, %.1f, %.1f'):format(pos.x, pos.y, pos.z))
    return true, { index = #list }
end, { reason = 'optional', rate = 2 })

Kit.action('server:admin:updateDesk', 'departmentsAdmin', function(ctx)
    local p = ctx.payload
    local list = Desks()
    local i = Int(p.index)
    if not list[i] then return false, 'err.desk_unknown' end
    local desk = DeskFrom(p, list[i])
    if p.moveHere == true then
        local pos = MyPosition(ctx.src)
        if not pos then return false, 'err.no_position' end
        desk.coords = vector3(pos.x + 0.0, pos.y + 0.0, pos.z + 0.0)
    end
    list[i] = desk
    local ok, err = SaveDesks(ctx.src, list, ctx.reason)
    if not ok then return false, err end
    ctx.audit('deskChanged', desk.label, nil, p.moveHere == true and 'moved' or nil)
    return true, { index = i }
end, { reason = 'optional', rate = 2 })

Kit.action('server:admin:removeDesk', 'departmentsAdmin', function(ctx)
    local list = Desks()
    local i = Int(ctx.payload.index)
    if not list[i] then return false, 'err.desk_unknown' end
    local label = list[i].label
    table.remove(list, i)
    local ok, err = SaveDesks(ctx.src, list, ctx.reason)
    if not ok then return false, err end
    ctx.audit('deskRemoved', label)
    return true, { index = i }
end, { reason = 'optional', rate = 2 })

Kit.action('server:admin:teleportToDesk', 'departmentsAdmin', function(ctx)
    if not CP.Net.rateOk(ctx.src, 'sys:teleport', 1, 5000) then return false, 'err.rate_limited' end
    local list = Desks()
    local d = list[Int(ctx.payload.index)]
    if not d then return false, 'err.desk_unknown' end
    if not Teleport(ctx.src, d.coords) then return false, 'err.no_position' end
    ctx.audit('teleport', 'Tablet.desks', nil, tostring(d.label))
    return true, {}
end, { rate = 1 })

Kit.callback('admin:myPosition', 'openAdmin', function(ctx)
    local pos = MyPosition(ctx.src)
    if not pos then return nil, 'err.no_position' end
    return pos
end, { rate = 2 })

Kit.action('server:admin:teleportTo', 'openAdmin', function(ctx)
    if not CP.Net.rateOk(ctx.src, 'sys:teleport', 1, 5000) then return false, 'err.rate_limited' end
    local p = ctx.payload
    local c = Sys.positionOf(p.path, p.index)
    if not c then return false, 'err.no_position' end
    if not Teleport(ctx.src, c) then return false, 'err.no_position' end
    ctx.audit('teleport', tostring(p.path):sub(1, 64), nil, tostring(Int(p.index)))
    return true, {}
end, { rate = 1 })

-- ============================================================================
--                                SUPPORT (NET)
-- ============================================================================

Kit.callback('admin:checkAccess', 'playerSupport', function(ctx)
    local target = TargetOf(ctx.args)
    if not target then return nil, 'err.player_offline' end
    if not Kit.targetOk('checkAccess', target, 1, 5000) then return nil, 'err.rate_limited' end
    local via = ctx.args.via
    if via ~= 'command' and via ~= 'keybind' and via ~= 'item' then via = 'command' end
    return Sys.checkAccess(target, via)
end, { rate = 2 })

Kit.action('server:admin:giveTabletItem', 'playerSupport', function(ctx)
    local target, info = TargetOf(ctx.payload)
    if not target then return false, 'err.player_offline' end
    local item = Config.Tablet and Config.Tablet.item
    if type(item) ~= 'string' or item == '' then return false, 'err.no_tablet_item_set' end
    if not Kit.targetOk('giveTabletItem', info.citizenid, 1, 60000) then return false, 'err.rate_limited' end
    local okA, inArena = Call('Alerts', 'inArena', target)
    if okA and inArena then return false, 'err.in_arena' end
    local okH, has = Call('Tablet', 'hasTabletItem', target)
    if okH and has then return false, 'err.has_tablet_item' end
    if GetResourceState('ox_inventory') ~= 'started' then return false, 'err.module_unavailable' end
    local okC, can = pcall(function() return exports.ox_inventory:CanCarryItem(target, item, 1) end)
    if not okC or not can then return false, 'err.cannot_carry' end
    local okI, added = pcall(function() return exports.ox_inventory:AddItem(target, item, 1) end)
    if not okI or not added then return false, 'err.cannot_carry' end
    ctx.audit('tabletItemGive', info.citizenid, nil, item)
    return true, { item = item }
end, { reason = true, rate = 1 })

Kit.action('server:admin:releaseScreen', 'playerSupport', function(ctx)
    local target, info = TargetOf(ctx.payload)
    if not target then return false, 'err.player_offline' end
    if not Kit.targetOk('releaseScreen', info.citizenid, 1, 10000) then return false, 'err.rate_limited' end
    TriggerClientEvent(CP.e('client:diagUnstick'), target)
    ctx.audit('screenRelease', info.citizenid)
    return true, {}
end, { rate = 1 })

Kit.callback('admin:getClientState', 'playerSupport', function(ctx)
    local target, info = TargetOf(ctx.args)
    if not target then return nil, 'err.player_offline' end
    if not Kit.targetOk('clientState', info.citizenid, 1, 5000) then return nil, 'err.rate_limited' end
    local state = Sys.clientState(target)
    if not state then return nil, 'err.client_no_answer' end
    return state
end, { rate = 1 })

-- ============================================================================
--                               AUDIT LOG (NET)
-- ============================================================================

Kit.callback('admin:exportAuditPart', 'openAdmin', function(ctx)
    if not CP.Net.rateOk(ctx.src, 'sys:auditPart', 1, 3000) then return nil, 'err.rate_limited' end
    return Sys.auditPart(ctx.args, ctx.args.part)
end, { rate = 1 })

Kit.action('server:admin:saveAuditExport', 'openAdmin', function(ctx)
    if not CP.Net.rateOk(ctx.src, 'sys:auditSave', 1, 30000) then return false, 'err.rate_limited' end
    local res, err = Sys.saveAudit(type(ctx.payload.filters) == 'table' and ctx.payload.filters or {})
    if not res then return false, err end
    ctx.audit('auditExport', res.path, nil, tostring(res.rows))
    return true, res
end, { rate = 1 })

-- ============================================================================
--                                   CONSOLE
-- ============================================================================
-- CrimsonPoliceAdmin storagemode reset: back to config.lua's Config.Database at the next start (one of the three
-- console-only controls, for when the Admin UI cannot open).

local function ConsoleStorageMode(src, args)
    if (tonumber(src) or 0) ~= 0 then return false, 'sysadmin.console.console_only' end
    if (args[1] or ''):lower() ~= 'reset' then return false, 'sysadmin.console.storagemode_usage' end
    local S = CP.Storage
    SetKvp(S.KVP_MODE, nil)
    SetKvp(S.KVP_FOLDER, nil)
    Kit.auditSync(0, 'audit', 'storageModeReset', nil, nil, nil, 'console', { critical = true })
    return true, 'sysadmin.console.storagemode_reset', { resource = CP.resource }
end
Sys._consoleStorageMode = ConsoleStorageMode

-- ============================================================================
--                                    START
-- ============================================================================

local function StorageHealth()
    local out = {}
    local ov = CP.Storage and CP.Storage.override and CP.Storage.override() or nil
    if ov then
        out[#out + 1] = {
            level = 'warn',
            text = CP.L('sysadmin.health.override', { mode = ov.mode, folder = tostring(ov.folder or '') }),
        }
    end
    if Maint.active() == 'left_behind' then
        out[#out + 1] = { level = 'error', text = CP.L('sysadmin.health.left_behind') }
    end
    if #out == 0 then out[1] = { level = 'ok', text = CP.L('sysadmin.health.storage_ok') } end
    return out
end
Sys._storageHealth = StorageHealth

function Sys._boot()
    Db()
    if Sys.storageMeta().state == 'left_behind' then
        Maint.begin('left_behind', { by = 'start' })
        CP.err(TAG, '%s', CP.L('sysadmin.console.left_behind'))
    end
end

CreateThread(function()
    if CP.ConfigHealth and CP.ConfigHealth.register then CP.ConfigHealth.register('storage', StorageHealth) end
    if CP.Admin and CP.Admin.registerSubcommand then
        CP.Admin.registerSubcommand('storagemode', ConsoleStorageMode, 'sysadmin.console.storagemode_help')
    end
    if CP.Schedule and CP.Schedule.onDaily then
        CP.Schedule.onDaily(function()
            if not (type(Config.Backups) == 'table' and Config.Backups.daily == true) then return end
            if not Kit.waitIdle(60000) then return end
            local ok, res = Kit.withLock('backup', function() return Sys.backup(0, 'daily') end)
            if not ok then CP.warn(TAG, 'the daily backup failed: %s', CP.L(tostring(res))) end
        end)
    end
    local ok, err = pcall(Sys._boot)
    if not ok then CP.err(TAG, 'reading the storage marker failed: %s', tostring(err)) end
end)

-- Test hooks (not part of the contract).
Sys._index = Index
Sys._resetSchema = function() schemaCache = nil end
Sys._uploads = function() return uploads end
