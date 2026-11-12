-- The capability inventory against its baseline: nothing Crimson-Police can do may disappear unnoticed.

-- The capability inventory against its baseline: nothing Crimson-Police can do may disappear unnoticed.
-- tools/capability_inventory.lua lists every command, event, callback, NUI callback, export, admin action (with its
-- permission key), setting, feature switch and Config key from the running resource (both sides) and the shipped
-- config; tests/capability_baseline.txt is that list as committed. A line of the baseline that is gone fails here,
-- whatever else changed with it (its README row, its client sender). A new line passes and is named, with the command
-- that adds it to the baseline. docs/dev/TESTING.md "Capability inventory".

local H = dofile('tests/harness.lua')

_G.CP_INVENTORY_LIB = true
local Inv = dofile('tools/capability_inventory.lua')
_G.CP_INVENTORY_LIB = nil

local function Lines(path)
    local out = {}
    local f = io.open(path, 'r')
    if not f then return nil end
    for line in f:lines() do
        if line ~= '' and line:sub(1, 1) ~= '#' then out[#out + 1] = line end
    end
    f:close()
    return out
end

local base = Lines(Inv.baseline)
H.ok(base ~= nil and #base > 1000, 'tests/capability_baseline.txt is there: ' .. tostring(base and #base))
base = base or {}

local ok, now = pcall(Inv.inventory)
H.ok(ok, 'the inventory builds: ' .. (ok and '' or tostring(now)))
now = ok and now or {}

local have = {}
for _, l in ipairs(now) do have[l] = true end
local had = {}
for _, l in ipairs(base) do had[l] = true end

-- every kind is there on its side (an empty list means the inventory itself broke)
local kinds = {}
for _, l in ipairs(now) do
    local k = l:match('^(%S+ %S+) ')
    kinds[k] = (kinds[k] or 0) + 1
end
for _, k in ipairs({
    'command server',
    'event server',
    'callback server',
    'export server',
    'action server',
    'setting server',
    'feature server',
    'command client',
    'event client',
    'export client',
    'nui client',
    'config shared',
}) do
    H.ok((kinds[k] or 0) > 0, ('the inventory lists %s (%d)'):format(k, kinds[k] or 0))
end

local gone = {}
for _, l in ipairs(base) do
    if not have[l] then gone[#gone + 1] = l end
end
H.eq(#gone, 0, ('nothing of the baseline is gone (%d of %d lines missing):\n  %s'):format(#gone, #base,
    table.concat(gone, '\n  ', 1, math.min(#gone, 40))))

local added = {}
for _, l in ipairs(now) do
    if not had[l] then added[#added + 1] = l end
end
if #added > 0 then
    print((
        'REPORT %d capabilities are not in the baseline yet; once they are meant to stay, run '
        .. 'lua5.4 tools/capability_inventory.lua --write and commit tests/capability_baseline.txt:'
    ):format(#added))
    for i = 1, math.min(#added, 40) do print('REPORT   + ' .. added[i]) end
end
H.ok(#now >= #base - #gone, ('the inventory holds %d lines'):format(#now))

return H
