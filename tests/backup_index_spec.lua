-- Backups: saves/_backups/index.json and each <name>.manifest.json are written through the storage engine's
-- atomic writer (.tmp, then a rename), so a full disk keeps the old index; a missing or unreadable index.json is
-- rebuilt from the manifests in the backup folder instead of listing no backups.

local H = dofile('tests/harness.lua')

H.boot({ side = 'server', realLocale = true })
if not (CP.Storage and CP.Storage.MemSQL) then H.load('modules/system/memsql.lua') end
for _, m in ipairs({
    'modules/permissions/server.lua',
    'modules/access/server.lua',
    'modules/admin/server.lua',
    'modules/adminkit/server.lua',
    'modules/settings/server.lua',
    'modules/sysadmin/server.lua',
}) do
    H.load(m)
end

local Sys = CP.Sysadmin
local FS = CP.Storage.MemSQL.fs

-- an in-memory disk in place of the real file calls (the engine's writer uses this same table)
local disk, full = {}, false
local real = {}
for _, k in ipairs({ 'read', 'write', 'exists', 'rename', 'remove', 'list' }) do real[k] = FS[k] end
FS.read = function(path) return disk[path] end
FS.write = function(path, data)
    if full then
        disk[path] = '' -- io.open 'wb' empties the file before the write fails
        return nil, 'No space left on device'
    end
    disk[path] = data
    return true
end
FS.exists = function(path) return disk[path] ~= nil end
FS.rename = function(a, b)
    if disk[a] == nil then return nil, 'no such file' end
    disk[b], disk[a] = disk[a], nil
    return true
end
FS.remove = function(path)
    disk[path] = nil
    return true
end
FS.list = function(dir)
    local names = {}
    for path in pairs(disk) do
        local name = path:sub(#dir + 2)
        if path:sub(1, #dir + 1) == dir .. '/' and not name:find('/', 1, true) then names[#names + 1] = name end
    end
    table.sort(names)
    return names
end

local root = tostring(GetResourcePath and GetResourcePath(CP.resource) or '.'):gsub('[/\\]+$', '')
local dir = root .. '/saves/_backups'
local function Entry(name, at)
    return { name = name, kind = 'manual', createdAt = at, by = 'console', rows = 1, bytes = 9 }
end

-- a failed index write keeps the old index
do
    disk = {}
    full = false
    local okA = Sys._saveIndex({ Entry('20260101-000000-manual', 1), Entry('20260102-000000-manual', 2) })
    H.ok(okA, 'the index is saved')
    H.eq(#Sys._index(), 2, 'two backups listed')
    full = true
    local okB = Sys._saveIndex({ Entry('20260101-000000-manual', 1) })
    full = false
    H.ok(not okB, 'the failed save is reported')
    H.eq(#Sys._index(), 2, 'the old index is still there')
    H.eq(disk[dir .. '/index.json.tmp'], nil, 'no .tmp is left behind')
end

-- a missing index is rebuilt from the manifests
do
    disk = {}
    for i, name in ipairs({ '20260103-000000-daily', '20260101-000000-manual' }) do
        local m = Entry(name, 10 - i)
        m.kind = name:match('%-(%a+)$')
        m.files = { { path = 'logos/a.png', file = name .. '.f1.bin', bytes = 3 } }
        disk[dir .. '/' .. name .. '.manifest.json'] = json.encode(m)
    end
    disk[dir .. '/20260101-000000-manual.t.cp_audit.json'] = '[]'
    local list = Sys._index()
    H.eq(#list, 2, 'both backups are listed again')
    H.eq(list[1].name, '20260101-000000-manual', 'oldest first')
    H.eq(list[2].kind, 'daily', 'kind comes from the manifest')
    H.eq(list[1].files, 1, 'file count comes from the manifest')
    H.ok(type(disk[dir .. '/index.json']) == 'string' and #json.decode(disk[dir .. '/index.json']) == 2,
        'the rebuilt index is saved')
    disk[dir .. '/index.json'] = '' -- an emptied index is unreadable too
    H.eq(#Sys._index(), 2, 'an empty index.json is rebuilt as well')
end

for k, f in pairs(real) do FS[k] = f end
return H
