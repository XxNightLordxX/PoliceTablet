-- Identity: one player's characters under license: AND license2:, as Qbox really stores them. qbx_core main (1.24.0)

local H = dofile('tests/harness.lua')

local realPrint = print
_G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, ' ')
    if not line:find('crimson%-police') then realPrint(line) end
end

H.boot({ side = 'server', realLocale = true })
_G.GetConvar = function(_, default) return default end
_G.PerformHttpRequest = function() end

local LIC = 'license:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1'     -- the admin's license: identifier
local LIC2 = 'license2:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb2'   -- the admin's license2: identifier
local LIC7 = 'license:7777777777777777777777777777777777777777'
H.players[1] = {
    ace = { ['crimsonpolice.admin'] = true },
    coords = vec3(0.0, 0.0, 0.0),
    identifiers = { LIC2, LIC, 'fivem:1001' },   -- license2: listed first
}
H.players[7] = { ace = {}, coords = vec3(0.0, 0.0, 0.0), identifiers = { LIC7 } }

-- Qbox's players table (qbx_core.sql, the columns Crimson-Police reads) and users table (server/storage/players.lua)
H.sql('DROP TABLE IF EXISTS players')
H.sql([[CREATE TABLE players (id int NOT NULL AUTO_INCREMENT, userId int UNSIGNED DEFAULT NULL,
    citizenid varchar(50) NOT NULL, cid int DEFAULT NULL, license varchar(255) NOT NULL, name varchar(255) NOT NULL,
    PRIMARY KEY (citizenid), KEY id (id), KEY license (license))]])
H.sql('DROP TABLE IF EXISTS users')
H.sql([[CREATE TABLE users (userId int UNSIGNED NOT NULL AUTO_INCREMENT, username varchar(255) DEFAULT NULL,
    license varchar(50) DEFAULT NULL, license2 varchar(50) DEFAULT NULL, fivem varchar(20) DEFAULT NULL,
    discord varchar(30) DEFAULT NULL, PRIMARY KEY (userId))]])
-- ADMOLD01: made on QBCore (players.license = license:...); ADMQBX01: made on Qbox (license2 first); OFF00007 and
-- the admin's deleted and re-created characters OLDCHR01 (license:) and NEWCHR01 (license2:)
H.sql([[INSERT INTO players (userId, citizenid, cid, license, name) VALUES (1, 'ADMOLD01', 1, ?, 'x'),
    (1, 'ADMQBX01', 2, ?, 'x'), (2, 'OFF00007', 1, ?, 'y'), (1, 'OLDCHR01', 3, ?, 'x'), (1, 'NEWCHR01', 4, ?, 'x')]],
    { LIC, LIC2, LIC7, LIC, LIC2 })
H.sql(
    'INSERT INTO users (userId, username, license, license2, fivem) VALUES (1, \'Ada\', ?, ?, \'fivem:1001\'), '
        .. '(2, \'Olly\', ?, NULL, NULL)',
    { LIC, LIC2, LIC7 }
)

-- qbx_core stand-in: PlayerData.license is the loaded character's players.license (CheckPlayerData keeps it)
local loaded = { [7] = 'OFF00007' }   -- the admin is in the character menu: no character loaded yet
local function PlayerOf(src)
    local cid = loaded[src]
    if not cid then return nil end
    local row = H.sql('SELECT license FROM players WHERE citizenid = ?', { cid })[1]
    return {
        PlayerData = {
            source = src,
            citizenid = cid,
            license = row.license,
            charinfo = { firstname = 'P', lastname = tostring(src) },
            job = { name = 'sast', label = 'SAST', onduty = true, type = 'leo', grade = { name = 'Chief', level = 4 } },
            metadata = { callsign = 'A-' .. src },
            money = { bank = 1000, cash = 0 },
        },
        Functions = {
            AddMoney = function() return true end,
            RemoveMoney = function() return true end,
        },
    }
end
H.exportsMock.qbx_core = {
    GetPlayer = function(src) return PlayerOf(tonumber(src)) end,
    GetPlayerByCitizenId = function(cid)
        for src, c in pairs(loaded) do
            if c == cid then return PlayerOf(src) end
        end
        return nil
    end,
    GetQBPlayers = function()
        local out = {}
        for src in pairs(loaded) do out[src] = PlayerOf(src) end
        return out
    end,
    GetJobs = function()
        return {
            sast = {
                label = 'SAST',
                type = 'leo',
                grades = { [0] = { name = 'Cadet' }, [4] = { name = 'Chief', isboss = true } },
            },
        }
    end,
}
CP.Missions = {
    reload = function() end,
    get = function() return nil end,
}
CP.Banking = {
    societyBalance = function() return 0 end,
    recordDeposit = function() return true end,
}

for _, t in ipairs({
    'cp_audit',
    'cp_settings',
    'cp_settings_history',
    'cp_admin_jobs',
    'cp_admin_requests',
    'cp_officers',
    'cp_mission_runs',
    'cp_item_rewards',
}) do
    H.sql('DELETE FROM ' .. t)
end
for _, m in ipairs({
    'modules/integrations/qbx/server.lua',
    'modules/permissions/server.lua',
    'modules/access/server.lua',
    'modules/admin/server.lua',
    'modules/adminkit/server.lua',
    'modules/confighealth/server.lua',
    'modules/settings/server.lua',
    'modules/tablet/server.lua',
    'modules/cash/server.lua',
    'modules/payouts/server.lua',
    'modules/payments/server.lua',
    'modules/schedule/server.lua',
}) do
    H.load(m)
end
H.step(0)
local Kit, A, Q = CP.AdminKit, CP.Access, CP.Qbx

-- A character login or switch, with the events qbx_core sends (Logout: OnPlayerUnload; Login: PlayerLoaded).
local function LoadCharacter(src, cid)
    if loaded[src] then TriggerEvent('QBCore:Server:OnPlayerUnload', src) end
    loaded[src] = cid
    TriggerEvent('QBCore:Server:PlayerLoaded', PlayerOf(src))
end

local function Async(fn)
    local out, done = nil, false
    CreateThread(function()
        out = table.pack(fn())
        done = true
    end)
    local n = 0
    while not done and n < 500 do
        H.advance(20)
        n = n + 1
    end
    return table.unpack(out or {}, 1, out and out.n or 0)
end

local function Sorted(list)
    local copy = {}
    for i, v in ipairs(list or {}) do copy[i] = v end
    table.sort(copy)
    return table.concat(copy, ',')
end

-- ============================================================================
--                     1. THE LICENSES OF AN ONLINE PLAYER
-- ============================================================================

do
    H.eq(Async(function() return A.licenseOfSrc(1) end), LIC,
        'no character loaded: the license: identifier, never the license2: one listed before it')
    H.eq(Sorted(Async(function() return A.licensesOfSrc(1) end)), Sorted({ LIC, LIC2 }), 'both licenses of the player')
    LoadCharacter(1, 'ADMQBX01')
    H.eq(Async(function() return A.licenseOfSrc(1) end), LIC2, 'a Qbox character loaded: its own players.license')
    H.eq(Sorted(Async(function() return A.licensesOfSrc(1) end)), Sorted({ LIC, LIC2 }), 'still both, no repeats')
    H.eq(#Async(function() return A.licensesOfSrc(0) end), 0, 'the console has none')
end

-- ============================================================================
--              2. THE S GUARD: EVERY CHARACTER OF EITHER LICENSE
-- ============================================================================

do
    -- the admin opened the tablet on the old character once (cp_officers.license = its PlayerData.license)
    LoadCharacter(1, 'ADMOLD01')
    A.refreshOfficerRow(1)
    LoadCharacter(1, 'ADMQBX01')
    A.refreshOfficerRow(1)
    A.refreshOfficerRow(7)
    local rows = H.sql('SELECT citizenid, license FROM cp_officers ORDER BY citizenid')
    H.ok(#rows == 3 and rows[1].license == LIC and rows[2].license == LIC2,
        'cp_officers keeps each character\'s license')

    local mine = Async(function() return A.selfCitizenids(1) end) or {}
    H.eq(mine[1], 'ADMQBX01', 'the current character first')
    H.eq(Sorted(mine), 'ADMOLD01,ADMQBX01,NEWCHR01,OLDCHR01',
        'every character qbx_core lets this player log into is the admin\'s own')
    H.eq(Async(function() return Kit.isSelf(1, 'ADMOLD01', true) end), true,
        'the admin\'s QBCore-era character (license:) is the admin')
    H.eq(Async(function() return Kit.isSelf(1, 'OFF00007', true) end), false, 'another player\'s character is not')
end

local reqSeq, ridSeq = 0, 700
local function Act(name, src, payload)
    H.clockMs = H.clockMs + 1100
    reqSeq = reqSeq + 1
    local reqId = 'v' .. reqSeq
    H.fire('crimson-police:' .. name, src, payload, reqId)
    for _ = 1, 200 do
        for i = #H.events, 1, -1 do
            local e = H.events[i]
            if e.name == 'crimson-police:client:actionResult' and e.args[1] == reqId then
                return e.args[2], e.args[3]
            end
        end
        H.advance(20)
    end
    return nil, 'no reply'
end
local function Rid()
    ridSeq = ridSeq + 1
    return ('%08x-0000-4000-8000-%012x'):format(ridSeq, 9)
end

do
    Config.Cash.allowManualCash = true
    local _, e = Act('server:admin:manualCash', 1,
        { citizenid = 'ADMQBX01', amount = 100, reason = 'x', requestId = Rid() })
    H.eq(e, 'err.self_target', 'manual cash: the current character is refused')
    _, e = Act('server:admin:manualCash', 1, { citizenid = 'ADMOLD01', amount = 100, reason = 'x', requestId = Rid() })
    H.eq(e, 'err.self_target', 'and the admin\'s character stored under the other license')
    H.eq(H.sql('SELECT COUNT(*) AS n FROM cp_mission_runs WHERE mission_id = \'manual_cash\'')[1].n + 0, 0,
        'no payment row was written')
    Config.Cash.allowManualCash = false
end

-- ============================================================================
--              3. ONE PLAYER'S TWO LICENSES (Qbox's users table)
-- ============================================================================

do
    H.eq(Sorted(Async(function() return Q.userLicenses(LIC) end)), Sorted({ LIC, LIC2 }),
        'the users row of license: also has license2:')
    H.eq(Sorted(Async(function() return Q.userLicenses(LIC2) end)), Sorted({ LIC, LIC2 }), 'and the other way round')
    H.eq(Sorted(Async(function() return Q.userLicenses(LIC7) end)), LIC7, 'a player with one license')
    H.eq(Async(function() return A.sameUser(LIC, LIC2) end), true,
        'a record move between OLDCHR01 (license:) and NEWCHR01 (license2:) is one player\'s')
    H.eq(Async(function() return A.sameUser(LIC, LIC7) end), false, 'two players are not')
    H.sql('DROP TABLE users')
    H.eq(Sorted(Async(function() return Q.userLicenses(LIC) end)), LIC, 'a qbx_core without a users table: just itself')
    H.eq(Async(function() return A.sameUser(LIC, LIC2) end), false, 'and the licenses are not matched')
end

H.sql('DROP TABLE IF EXISTS players')
return H
