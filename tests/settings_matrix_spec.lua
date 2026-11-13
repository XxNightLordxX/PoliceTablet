-- Every switch of the Settings screen on the whole server: the world of tests/workflows_full_spec.lua (every
-- server file of fxmanifest loaded as in game, the owner's scripts running, database off: the saves folder, as
-- shipped), booted on the shipped config with no section of that spec run (CP_WF_WORLD).

-- Every switch of the Settings screen on the whole server: the world of tests/workflows_full_spec.lua (every
-- server file of fxmanifest loaded as in game, the owner's scripts running, database off: the saves folder, as
-- shipped), booted on the shipped config with no section of that spec run (CP_WF_WORLD).
--   1. Each boolean setting alone: every boolean entry that needs no restart is flipped through CP.Settings.set (the
--      Admin UI's own path, confirm 'ENABLE' for the money switches), the loops run 3 s, then it is reset. No error
--      line ('^1[') and no new Config health line that is not ok, and only the documented refusals.
--   2. Every switch on together: every shipped-off boolean (Testing.* left out) on at once, then the admin, officer
--      and supervisor screens open, an EVOC run is driven to its pay and a 2-officer unit accepts tactical.
-- docs/dev/WORKFLOWS.md "Every switch" says what each run turns on.

_G.CP_WF_WORLD = 'matrix'
local W = dofile('tests/workflows_full_spec.lua')
_G.CP_WF_WORLD = nil
local H, CID, PD = W.H, W.CID, W.PD
local U = CP.U

-- the error lines (CP.err prints '^1[crimson-police:<tag>]'; a Lua error in a thread prints SCRIPT ERROR)
local errorLines = {}
do
    local inner = _G.print
    _G.print = function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        local line = table.concat(parts, ' ')
        if line:find('^%^1%[') or line:find('SCRIPT ERROR', 1, true) then errorLines[#errorLines + 1] = line end
        return inner(...)
    end
end
local function Drain()
    local out = errorLines
    errorLines = {}
    return out
end

-- the gaps of the test world a switched-on path reaches (as in tests/fuzz_net_spec.lua): Qbox's metadata and gangs,
-- ox_inventory's item hook
H.exportsMock.qbx_core.GetMetadata = function(src, key)
    local pd = type(src) == 'number' and PD[src]
    if not pd then return false end
    return pd.metadata[key]
end
H.exportsMock.qbx_core.GetGangs = function() return {} end
H.exportsMock.ox_inventory.registerHook = function() return 1 end
H.exportsMock.ox_inventory.removeHooks = function() end

local S = CP.Settings
local schema = S._schema()
local function Health()
    local out = {}
    local ok, lines = pcall(CP.ConfigHealth.run)
    if not ok then return nil, tostring(lines) end
    for _, l in ipairs(lines) do
        if l.level ~= 'ok' then out[tostring(l.check) .. ':' .. tostring(l.text)] = l.level end
    end
    return out
end
-- the refusals by design (docs/dev/WORKFLOWS.md "Every switch"): a locked entry, a code fact and the item guard
local REFUSALS = {
    ['err.setting_locked'] = true,
    ['err.require_item_none'] = true,
}

W.Secs(5)
Drain()   -- the boot's own lines are the world's, not a switch's
local baseHealth, eBase = Health()
H.ok(baseHealth ~= nil, 'the Config health check runs: ' .. tostring(eBase))
baseHealth = baseHealth or {}

-- ============================================================================
--                        1. EACH BOOLEAN SETTING ALONE
-- ============================================================================

do
    local flipped, refused, bad = 0, 0, {}
    for _, e in ipairs(schema.list) do
        if e.kind == 'boolean' and not e.restart then
            local cur = U.getPath(Config, e.path)
            if cur == nil then cur = e.default end
            if type(cur) == 'boolean' then
                local okS, ok, err = pcall(S.set, 0, e.path, not cur, nil, { confirm = 'ENABLE', reason = 'matrix' })
                if not okS then
                    bad[#bad + 1] = e.path .. ' raised: ' .. tostring(ok)
                elseif not ok then
                    refused = refused + 1
                    if not REFUSALS[err] then bad[#bad + 1] = e.path .. ' refused: ' .. tostring(err) end
                else
                    flipped = flipped + 1
                    W.Secs(3)
                    local now, eH = Health()
                    if not now then bad[#bad + 1] = e.path .. ' health raised: ' .. eH end
                    for k, level in pairs(now or {}) do
                        if not baseHealth[k] then
                            bad[#bad + 1] = ('%s=%s health %s %s'):format(e.path, tostring(not cur), level, k)
                        end
                    end
                    for _, l in ipairs(Drain()) do
                        bad[#bad + 1] = ('%s=%s: %s'):format(e.path, tostring(not cur), l)
                    end
                    S.reset(0, e.path, { reason = 'matrix' })
                    W.Secs(1)
                    H.eq(U.getPath(Config, e.path), cur, e.path .. ': the reset puts it back')
                    for _, l in ipairs(Drain()) do bad[#bad + 1] = ('%s reset: %s'):format(e.path, l) end
                end
            end
        end
    end
    H.ok(flipped >= 200, ('each switch alone: %d flipped, %d refused by design'):format(flipped, refused))
    H.eq(#bad, 0, 'no switch alone raises, prints an error line or adds a health line: ' .. table.concat(bad, ' | '))
end

-- ============================================================================
--                         2. EVERY SWITCH ON TOGETHER
-- ============================================================================

do
    local on, bad = 0, {}
    for _, e in ipairs(schema.list) do
        if e.kind == 'boolean' and not e.restart and not e.path:find('^Testing%.') then
            if U.getPath(Config, e.path) == false then
                local ok, err = S.set(0, e.path, true, nil, { confirm = 'ENABLE', reason = 'matrix all on' })
                if ok then
                    on = on + 1
                elseif not REFUSALS[err] then
                    bad[#bad + 1] = e.path .. ' refused: ' .. tostring(err)
                end
            end
        end
    end
    Config.Events.modifierChance = 0    -- no random twist: the pay below is exact
    H.ok(on >= 80, ('every switch on: %d switched on'):format(on))
    W.Secs(5)
    for _, l in ipairs(Drain()) do bad[#bad + 1] = 'switching on: ' .. l end

    for _, name in ipairs({
        'admin:getSettings',
        'admin:getHome',
        'admin:getPayments',
        'admin:getRestrictions',
        'admin:getMissionControls',
    }) do
        local r, why = W.Cb(name, 5)
        H.ok(type(r) == 'table', ('all on: %s opens: %s'):format(name, tostring(why)))
    end
    for _, src in ipairs({ 1, 2, 3, 4, 6, 7 }) do
        local r, why = W.Cb('getSession', src, { ui = 'officer' })
        H.ok(type(r) == 'table', ('all on: the Officer UI opens for %s: %s'):format(CID[src], tostring(why)))
    end
    for _, src in ipairs({ 3, 4 }) do
        local r, why = W.Cb('getSession', src, { ui = 'supervisor' })
        H.ok(type(r) == 'table', ('all on: the Supervisor UI opens for %s: %s'):format(CID[src], tostring(why)))
    end

    -- one paid mission: EVOC ($350) to the end
    W.Place(1, vec3(-1100.0, -2900.0, 13.9))
    local run = W.Accept(1, 'training', { 'pursuit_sim', 'stolen_vehicle_takedown' })
    H.ok(run and run.missionId == 'evoc_course', 'all on: EVOC accepted')
    if run then
        local veh = W.TakeWheel(1, run)
        local mark = #H.events
        W.DriveCheckpoints(1, run, veh, 1, nil, 2)
        H.eq(run.state, 'ended', 'all on: EVOC ends')
        local result = W.RunEnded(1, mark)
        H.eq(result and result.cash and result.cash.amount, 350, 'all on: EVOC pays $350')
        local row = W.Rows('run_uuid = ?', { run.id })[1] or {}
        H.ok(row.state == 'completed' and row.cash_status == 'paid',
            ('all on: the row is completed and paid (%s, %s)'):format(tostring(row.state), tostring(row.cash_status)))
    end
    W.Secs(30)

    -- a 2-officer unit accepts tactical
    W.Place(6, vec3(1200.0, 1000.0, 100.0))
    W.Place(7, vec3(1204.0, 1000.0, 100.0))
    W.FormUnit(6, 7)
    local ok = W.Act('server:acceptType', 6, 'tactical')
    H.eq(ok, true, 'all on: the unit accepts tactical')
    local tr = CP.Runs.getBySrc(6)
    H.ok(tr ~= nil and tr.missionType == 'tactical', 'all on: a tactical run for the unit')
    W.Secs(30)
    for _, l in ipairs(Drain()) do bad[#bad + 1] = 'all on: ' .. l end
    H.eq(#bad, 0, 'every switch on: no error line: ' .. table.concat(bad, ' | '))
end

return H
