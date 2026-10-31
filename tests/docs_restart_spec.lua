-- Step C14: the docs say what an ox_inventory restart does while Crimson-Police runs, and match the code: the
-- swapItems hook is dropped and registered again 1 s after ox_inventory starts. The README's option rows give the
-- unit of each number.

local H = dofile('tests/harness.lua')

local function ReadRepo(rel)
    local f = io.open(H.root .. '../' .. rel, 'r')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return s
end

local function Has(s, needle) return type(s) == 'string' and s:find(needle, 1, true) ~= nil end

local readme = ReadRepo('README.md')
local notes = ReadRepo('docs/FILE_NOTES.md')
local runs = ReadRepo('Crimson-Police/modules/runs/server.lua')
H.ok(readme ~= nil and notes ~= nil and runs ~= nil, 'README, FILE_NOTES and the run engine are readable')

-- The code the docs describe.
local handler = runs
    and runs:match(
        'AddEventHandler%(\'onResourceStart\', function%(resource%)%s*\n'
            .. '%s*if resource ~= \'ox_inventory\' then return end(.-)\nend%)'
    )
H.ok(handler ~= nil, 'the run engine listens for ox_inventory starting')
H.ok(Has(handler, 'itemHookId = nil'), 'the old hook is forgotten')
H.ok(Has(handler, 'SetTimeout(1000, RegisterItemHook)'), 'and registered again 1 s later')

-- README: its own section in Troubleshooting, linked from the contents.
H.ok(Has(readme, '### 11.9 Restarting ox_inventory while Crimson-Police runs'), 'README 11.9 exists')
H.ok(Has(readme, '(#119-restarting-ox_inventory-while-crimson-police-runs)'), 'and is in the contents')
H.ok(Has(readme, 'The lock on mission items is registered again about 1 s after ox_inventory starts'),
    'the hook row matches the code')
H.ok(Has(readme, 'You do not need to restart Crimson-Police after `restart ox_inventory`.'),
    'it says no Crimson-Police restart is needed')

-- FILE_NOTES: the run engine's entry says the same.
H.ok(Has(notes, 'the hook is registered again 1 s later'), 'FILE_NOTES: the hook comes back 1 s later')
H.ok(Has(notes, 'items to take back are kept'), 'FILE_NOTES: what happens while ox_inventory is stopped')

-- Units on the README option rows.
for _, needle in ipairs({
    '`sprintSeconds` (10 s)',
    '`jogSeconds` (12 s)',
    '`walkSeconds` (8 s)',
    '`saveTurnMs` (4 ms)',
    '`panelKeyGuardMs` (300 ms:',
}) do
    H.ok(Has(readme, needle), 'README states the unit: ' .. needle)
end

return H
