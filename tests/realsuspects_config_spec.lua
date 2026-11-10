-- Police vs real criminal players, (the owner's decision of 2026-10-26, "Build all 3 but options in the
-- config.lua"): the two master switches ship off and show in Admin UI → Settings, and the docs record the decision
-- without rewording RT1's start-route text.

local H = dofile('tests/harness.lua')

local function ReadRepo(rel)
    local f = io.open(H.root .. '../' .. rel, 'r')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return s
end

-- The bullet of a section that starts with "- <first words>" (one line in docs/dev/SPEC.md).
local function Bullet(text, first)
    for line in (text or ''):gmatch('[^\n]+') do
        if line:sub(1, #first + 2) == '- ' .. first then return line end
    end
    return nil
end

local function Has(s, needle) return type(s) == 'string' and s:find(needle, 1, true) ~= nil end

-- ============================================================================
--                      THE SWITCHES (config.lua, shipped)
-- ============================================================================

H.boot({ side = 'server', realLocale = true })
_G.GetConvar = function(_, default) return default end
_G.PerformHttpRequest = function() end
H.players[1] = { ace = { ['crimsonpolice.admin'] = true } }
CP.Access = {
    isAdmin = function(src) return src == 0 or src == 1 end,
    isSupervisor = function() return false end,
    getOfficer = function() return nil, 'err.not_police' end,
}
CP.Qbx = {
    getInfo = function(src) return { citizenid = ('RSC%05d'):format(src), name = 'Admin ' .. src } end,
}
CP.Tablet = { push = function() end }
CP.Runs = {
    all = function() return {} end,
}
CP.Missions = {
    reload = function() end,
    get = function() return nil end,
}
H.load('modules/permissions/server.lua')
H.load('modules/admin/server.lua')
H.load('modules/confighealth/server.lua')
H.load('modules/settings/server.lua')
H.step(0)
local S = CP.Settings

do
    H.eq(type(Config.LiveCrime), 'table', 'Config.LiveCrime exists')
    H.eq(type(Config.Volunteers), 'table', 'Config.Volunteers exists')
    H.eq(Config.LiveCrime and Config.LiveCrime.enabled, false, 'live crimes ship off')
    H.eq(Config.Volunteers and Config.Volunteers.enabled, false, 'volunteer suspects ship off')
end

-- ============================================================================
--                     ADMIN UI → SETTINGS (from the file)
-- ============================================================================

do
    local sc = S._schema()
    local order, byKey = {}, {}
    for i, sec in ipairs(sc.sections) do
        order[sec.key] = i
        byKey[sec.key] = sec
    end
    H.ok(order.live_crimes ~= nil and order.volunteer_suspects ~= nil, 'the two banners are Settings sections')
    H.ok(
        (order.police_actions_and_custody or 0) < (order.real_suspects or 0)
            and (order.real_suspects or 0) < (order.live_crimes or 0)
            and (order.live_crimes or 0) < (order.volunteer_suspects or 0),
        'in Part 3 (Player vs police): after the NPC sections, Real suspects, then live crimes, then volunteers'
    )
    H.eq((byKey.live_crimes or {}).title, 'Live crimes (option A)', 'the live crimes title')
    H.eq((byKey.volunteer_suspects or {}).title, 'Volunteer suspects (options B and C)', 'the volunteers title')

    local function Section(key, group)
        local sec = byKey[key] or { groups = {} }
        for _, g in ipairs(sec.groups) do
            if g.path == group then
                local paths = {}
                for _, e in ipairs(g.settings) do paths[#paths + 1] = e.path end
                return g, paths
            end
        end
        return nil, {}
    end
    local g, paths = Section('live_crimes', 'LiveCrime')
    H.ok(g ~= nil and Has(g.desc, 'Crimson-Contracts reports once its police alert goes out'),
        'the comment under the banner describes Live crimes')
    H.ok(CP.U.contains(paths, 'LiveCrime.enabled'), 'its switch is in the group')
    g, paths = Section('volunteer_suspects', 'Volunteers')
    H.ok(g ~= nil and Has(g.desc, 'while every mode is \'npc\''), 'the comment under the banner describes Volunteers')
    H.ok(CP.U.contains(paths, 'Volunteers.enabled'), 'its switch is in the group')

    for path, desc in pairs({
        ['LiveCrime.enabled'] = 'true = reported crimes become LIVE calls on the Dispatch screen',
        ['Volunteers.enabled'] = 'true = players can volunteer with the command below',
    }) do
        local e = S.entry(path) or {}
        H.eq(e.kind, 'boolean', path .. ' is a switch')
        H.eq(e.default, false, path .. ' is off in config.lua')
        H.ok(type(e.desc) == 'string' and e.desc ~= '', path .. ' has a description')
        H.eq(e.desc, desc, path .. ': its trailing comment is the description')
        H.ok(not e.restart and not e.money, path .. ' needs no restart and is not a money switch')
    end

    -- V20: the command, the window and strikes, each with its own description and bounds
    for path, want in pairs({
        ['Volunteers.command'] = { 'crimsonheat', true },
        ['Volunteers.windowMinutes'] = { 60, false },
        ['Volunteers.strikes'] = { 3, false },
        ['Volunteers.strikeHours'] = { 24, false },
        ['Volunteers.blockHours'] = { 24, false },
        ['Volunteers.saveStrikes'] = { true, false },
        ['Volunteers.staffClearStrikes'] = { true, false },   -- F2
    }) do
        local e = S.entry(path) or {}
        H.eq(e.default, want[1], path .. ' ships ' .. tostring(want[1]))
        H.ok(type(e.desc) == 'string' and e.desc ~= '', path .. ' has a description')
        H.eq(e.restart == true, want[2], path .. (want[2] and ' needs a restart' or ' applies live'))
    end
    H.ok(not S.check('Volunteers.windowMinutes', 5), 'a window under 10 minutes is refused')
    H.ok(not S.check('Volunteers.command', 'crimson heat'), 'a command with a space is refused')

    -- RP1: surrender and Talk them down, each key with its config.lua comment as the description
    local sw = S.entry('RealSuspects.surrender.enabled') or {}
    H.eq(sw.kind, 'boolean', 'RealSuspects.surrender.enabled is a switch')
    H.eq(sw.desc, 'true = the surrender command and Talk them down work in live cases',
        'its comment is its description')
    H.ok(not sw.restart and not sw.money, 'the surrender switch applies live and is not a money switch')
    local sc = S.entry('RealSuspects.surrender.command') or {}
    H.eq(sc.default, 'surrender', 'the surrender command ships /surrender')
    H.eq(sc.restart, true, 'a new command name needs a restart (RegisterCommand cannot be undone)')
    H.ok(not S.check('RealSuspects.surrender.command', 'give up'), 'a command with a space is refused')
    for path, bad in pairs({
        ['RealSuspects.surrender.talkRange'] = 100,
        ['RealSuspects.surrender.surrenderRange'] = 1,
        ['RealSuspects.surrender.askSeconds'] = 1,
        ['RealSuspects.surrender.talkCooldown'] = 1,
        ['RealSuspects.surrender.holdSeconds'] = 5,
        ['RealSuspects.surrender.breakRange'] = 500,
    }) do
        local e = S.entry(path) or {}
        H.ok(type(e.desc) == 'string' and e.desc ~= '', path .. ' has a description')
        H.ok(not S.check(path, bad), path .. ' refuses ' .. bad)
        H.ok((S.check(path, e.default)), path .. ' takes its shipped value')
    end
end

-- ============================================================================
--                       CONFIG.REALSUSPECTS IN SETTINGS
-- ============================================================================
-- Step V4, its first keys.

do
    local sc = S._schema()
    local order = {}
    for i, sec in ipairs(sc.sections) do order[sec.key] = i end
    H.ok(
        order.real_suspects ~= nil and (order.dispatch or 0) < order.real_suspects
            and order.real_suspects < (order.live_crimes or 0),
        'Real suspects is a section between Dispatch and Live crimes'
    )
    local leave = S.entry('RealSuspects.onLeave') or {}
    H.eq(leave.kind, 'enum', 'onLeave is a pick')
    H.eq(leave.default, 'void', 'onLeave ships void')
    H.eq(table.concat(leave.tpl and leave.tpl.options or {}, ','), 'void,caught,escaped',
        'onLeave: void, caught or escaped')
    H.ok(Has(leave.desc, 'When a suspect leaves') and Has(leave.desc, 'never holds the officers\' points'),
        'onLeave: the group line and its comment are the description')
    for _, v in ipairs({ 'void', 'caught', 'escaped' }) do
        H.ok((S.check('RealSuspects.onLeave', v)), 'onLeave ' .. v)
    end
    local okBad, errBad = S.check('RealSuspects.onLeave', 'jail')
    H.ok(okBad == false and errBad == 'err.setting_option', 'onLeave refuses anything else')
    local zones = S.entry('RealSuspects.noStartZones') or {}
    H.eq(zones.kind, 'rows', 'noStartZones is a list of zones (label, coords, radius)')
    H.eq(#(Config.RealSuspects.noStartZones or {}), 4, 'Pillbox, Paleto medical and the two Crimson-Arena areas')
    H.eq((S.entry('RealSuspects.excludeAdmins') or {}).kind, 'boolean', 'excludeAdmins is a switch')
    H.eq((S.entry('RealSuspects.excludeAdmins') or {}).money, nil, 'and not a money switch')
    for path, value in pairs({
        excludeAce = 'crimsonpolice.realsuspect.exclude',
        excludeAdmins = true,
        jobHopMinutes = 30,
        afkSeconds = 300,
        afkSampleEvery = 15,
        contactRange = 100.0,
        disconnectGrace = 120,
        reconnectNoticeMinutes = 30,
        evadeWindow = 120,
        timelineMax = 300,
        casesKept = 16,
        saveCases = true,
        adminScreen = true,
        staffLift = true,     -- F2
        staffNames = true,    -- F2
        weaponNames = true,   -- F2
    }) do
        local e = S.entry('RealSuspects.' .. path) or {}
        H.eq(e.default, value, 'RealSuspects.' .. path .. ' ships ' .. tostring(value))
        H.ok(type(e.desc) == 'string' and #e.desc > 10, 'RealSuspects.' .. path .. ' has a description')
    end
    -- Each description is its own key's comment, word for word: a comment that runs on to a second line never sits
    -- directly above the next key, where Settings would read it as that key's description too.
    for path, desc in pairs({
        excludeAce = 'Who can be a suspect: players with this ace (server.cfg) are never suspects',
        excludeAdmins = 'true = Crimson-Police admins (Config.AdminAce / Config.QboxAdmins) are never suspects either',
        jobHopMinutes = 'A character can\'t be a suspect within this many minutes of police duty, and can\'t take a '
            .. 'case within this many minutes of being a suspect',
        afkSeconds = 'Seconds with no movement and no camera turn = AFK: never a suspect, and a suspect cuffed while '
            .. 'AFK scores nothing',
        afkSampleEvery = 'seconds between AFK samples (only suspects, volunteers and reported crews)',
        noStartZones = 'a player standing here can\'t become a suspect',
        contactRange = 'metres: an officer this close to a suspect has made contact',
        onLeave = 'When a suspect leaves (logs off, switches character, enters Crimson-Arena or another instance): '
            .. '\'void\' = he counts for nobody; \'caught\' = it counts as a detain for the officers; \'escaped\' = '
            .. 'it counts as getting away. Staff always get a note, and it never holds the officers\' points',
        disconnectGrace = 'seconds a suspect who lost connection may come back and stay in the case',
        reconnectNoticeMinutes = 'minutes: officers are told when a suspect who left cuffed is back this soon',
        evadeWindow = 'The staff note says "left soon after contact" when he left within this many seconds of it',
        ['trail.every'] = 'seconds between points',
        ['trail.max'] = 'points kept per suspect',
        timelineMax = 'timeline entries kept per case',
        casesKept = 'Closed cases staff can still open in the Admin UI (their timeline, damage ledger and flags), the '
            .. 'newest ones; open cases are always there',
        saveCases = 'true = the kept closed cases are saved (the database or the saves folder), so a restart keeps '
            .. 'them (none older than pairLedgerDays); false = memory only, a restart starts the list again',
        -- F2: the staff tools
        staffLift = 'true = admins can lift a pair block, an exclusion or a suspension early from that screen (with '
            .. 'a reason, in the audit log); false = each one runs to its end date',
        staffNames = 'true = pair statistics, the running blocks and the case lists on that screen show character '
            .. 'names next to citizen IDs (one name lookup per screen load); false = citizen IDs only',
        weaponNames = 'true = the damage ledger on that screen names the weapon (Combat Pistol); false = the raw '
            .. 'weapon hash',
        -- V5: the proof
        cuffPairWindow = 'Proof the server checks before anything scores: seconds between the officer\'s sc-police '
            .. 'cuff and the suspect\'s cuffed state',
        cuffRange = 'metres between them at the cuff (sc-police allows 2.5; the rest is lag)',
        custodyHoldSeconds = 'seconds the cuffs must hold before a detain counts',
        breakFreeSeconds = 'Seconds: free this soon after the cuff = he won sc-police\'s cuff-break game (fair, once '
            .. 'per case and not in the first 2 s); later, with no officer uncuff and no bobby pin, it is a self-uncuff: it '
            .. 'counts as detained and staff get a note',
        rescueRange = 'Metres: a friend\'s successful bobby pin frees him with no note when that friend stood this '
            .. 'close for 2 s or more (once per case)',
        neutralisedShare = 'a suspect cuffed while down (whoever downed him) counts this share of a detain',
        jailRange = 'metres between officer and suspect at the jail (sc-police allows 5)',
        minJailTime = 'a booking needs at least this sentence (sc-police counts months)',
        jailTimeMax = 'longer sentences are recorded as this',
        bookingZones = 'A booking counts only inside one of these ({} = anywhere): sc-police\'s station duty points '
            .. 'and the prison; check them on your MLOs',
        spawnProtectSeconds = 'Seconds after a hospital respawn he can\'t be detained for points (unless officers '
            .. 'were with him when he went down)',
        earlyRespawnSeconds = 'Seconds; keep equal to sc-ambulance\'s Config.DeathTime: a respawn sooner voids him and staff '
            .. 'get a note',
        -- V6: officer conduct
        lessLethal = 'Officer conduct: these weapons are never a "shot" (a hit with one on a suspect who was never '
            .. 'armed costs nothing)',
        armedMemory = 'seconds a suspect counts as armed after the server saw a gun in his hands',
        downGrace = 'seconds after he goes down before a hit counts as hitting a downed person',
        damageLogMax = 'weapon hits between officers and suspects kept per case',
        -- V7: anti-farm
        ['identityMatch.block'] = 'same account = refused',
        ['identityMatch.flag'] = 'same connection or PC = allowed but flagged (families share them)',
        pairCooldownHours = 'One scored case of the same suspect per officer in this many hours (live crimes and '
            .. 'volunteers together)',
        maxCatchesPerSuspectDay = 'a suspect is worth points this many times a day, server-wide',
        suspectCooldownMinutes = 'After a case, the same officers score nothing on that suspect for this many minutes',
        ['pairFlag.count'] = 'cases of the same pair (matched by license)',
        ['pairFlag.days'] = 'within this many days',
        fastCatchSeconds = 'seconds: a detain this soon after the case started is a warning sign',
        pairLedgerDays = 'days the pair ledger keeps case rows (admin blocks stay until they expire)',
    }) do
        H.eq((S.entry('RealSuspects.' .. path) or {}).desc, desc, 'RealSuspects.' .. path .. ': its own comment')
    end
    local trailGroup = nil
    for _, sec in ipairs(sc.sections) do
        for _, g in ipairs(sec.key == 'real_suspects' and sec.groups or {}) do
            if g.path == 'RealSuspects.trail' then trailGroup = g end
        end
    end
    H.eq(trailGroup and trailGroup.desc, 'position trail kept for review', 'the trail group: its own comment')
    -- V7: the anti-farm groups and values
    local groups = {}
    for _, sec in ipairs(sc.sections) do
        for _, g in ipairs(sec.key == 'real_suspects' and sec.groups or {}) do groups[g.path] = g end
    end
    H.eq(
        (groups['RealSuspects.identityMatch'] or {}).desc,
        'Anti-farm (admins only): nobody can take a case against one of his own characters or licenses, and the '
            .. 'identifiers of both players are compared live, never stored or shown',
        'the identityMatch group: its own comment'
    )
    H.ok(Has((groups['RealSuspects.pairFlag'] or {}).desc, 'with a second warning sign'),
        'the pairFlag group names the second warning sign')
    for path, value in pairs({
        pairCooldownHours = 24,
        maxCatchesPerSuspectDay = 2,
        suspectCooldownMinutes = 30,
        ['pairFlag.count'] = 2,
        ['pairFlag.days'] = 7,
        fastCatchSeconds = 60,
        pairLedgerDays = 30,
    }) do
        H.eq((S.entry('RealSuspects.' .. path) or {}).default, value, 'RealSuspects.' .. path .. ' ships ' .. value)
    end
    local block = S.entry('RealSuspects.identityMatch.block') or {}
    H.eq(block.kind, 'list', 'identityMatch.block is a list')
    H.eq(table.concat(block.default or {}, ','), 'license,license2,discord,fivem,steam,xbl,live',
        'identityMatch.block ships the account kinds')
    H.eq(table.concat((S.entry('RealSuspects.identityMatch.flag') or {}).default or {}, ','), 'ip,token',
        'identityMatch.flag ships ip and token')
    H.ok((S.check('RealSuspects.identityMatch.block', { 'license', 'ip' })), 'any identifier kind may block')
    H.ok((S.check('RealSuspects.identityMatch.flag', {})), 'an empty flag list is allowed (nothing flags)')
    H.eq((S.check('RealSuspects.identityMatch.block', { 'email' })), false, 'an unknown kind is refused')
    H.eq((S.check('RealSuspects.identityMatch.flag', { 'ip', 'ip' })), false, 'a kind twice is refused')
    H.eq((S.check('RealSuspects.pairFlag.days', 0)), false, 'pairFlag.days 0 is refused')
    H.eq((S.check('RealSuspects.pairLedgerDays', 400)), false, 'pairLedgerDays above a year is refused')
    H.eq((S.check('RealSuspects.maxCatchesPerSuspectDay', 0)), false, 'maxCatchesPerSuspectDay 0 is refused')
    H.ok((S.check('RealSuspects.pairCooldownHours', 0)), 'pairCooldownHours 0 (no pair cooldown) is allowed')
    for _, path in ipairs({ 'pairCooldownHours', 'pairFlag.days', 'pairLedgerDays', 'identityMatch.block' }) do
        local e = S.entry('RealSuspects.' .. path) or {}
        H.ok(not e.restart and not e.money, 'RealSuspects.' .. path .. ' needs no restart and is not a money switch')
    end
    H.eq(Config.RealSuspects.trail.every, 5, 'a trail point every 5 s')
    H.eq(Config.RealSuspects.trail.max, 360, 'at most 360 points')
    local okZero = S.check('RealSuspects.trail.every', 0)
    H.eq(okZero, false, 'a trail point every 0 s is refused')
    -- V5: the booking zones are zone rows ({} allowed: anywhere), the share is 0..1
    local booking = S.entry('RealSuspects.bookingZones') or {}
    H.eq(booking.kind, 'rows', 'bookingZones is a list of zones (label, coords, radius)')
    H.ok((S.check('RealSuspects.bookingZones', {})), 'bookingZones {} (anywhere) is allowed')
    H.eq((S.check('RealSuspects.neutralisedShare', 1.5)), false, 'neutralisedShare above 1 is refused')
    H.ok((S.check('RealSuspects.neutralisedShare', 0.25)), 'neutralisedShare 0.25 is allowed')
    H.eq((S.check('RealSuspects.custodyHoldSeconds', 0)), false, 'a custody hold of 0 s is refused')
    -- V6: the less-lethal weapons are a list of weapon names, the numbers have ranges
    local less = S.entry('RealSuspects.lessLethal') or {}
    H.eq(less.kind, 'list', 'lessLethal is a list')
    H.ok((S.check('RealSuspects.lessLethal', { 'WEAPON_STUNGUN', 'WEAPON_BATON_X' })), 'weapon names are allowed')
    H.ok((S.check('RealSuspects.lessLethal', {})), 'an empty list is allowed (every weapon is a shot)')
    H.eq((S.check('RealSuspects.lessLethal', { 'stungun' })), false, 'a name that is not WEAPON_* is refused')
    H.eq((S.check('RealSuspects.damageLogMax', 0)), false, 'damageLogMax 0 is refused')
    H.eq((S.check('RealSuspects.downGrace', 120)), false, 'downGrace above a minute is refused')
    H.ok((S.check('RealSuspects.armedMemory', 30)), 'armedMemory 30 s is allowed')
    for id, desc in pairs({
        rs_unarmed_shot = 'penalty: shot a real suspect who was never armed',
        rs_ran_over = 'penalty: ran a real suspect over on foot',
    }) do
        local e = S.entry('Bonuses.' .. id .. '.value') or {}
        H.eq(e.default, -0.25, 'Bonuses.' .. id .. ' ships -0.25')
        H.ok((S.check('Bonuses.' .. id .. '.value', -0.5)), 'Bonuses.' .. id .. ': another penalty share is allowed')
        H.eq((S.check('Bonuses.' .. id .. '.value', 0.25)), false, 'Bonuses.' .. id .. ': a bonus is refused')
        local group = nil
        for _, sec in ipairs(sc.sections) do
            for _, g in ipairs(sec.groups) do if g.path == 'Bonuses.' .. id then group = g end end
        end
        H.eq(group and group.desc, desc, 'Bonuses.' .. id .. ': its comment is the description in Settings')
    end
    -- V9: the NPC-mission rules for cases with a real suspect, each a pick between the rule for real players
    -- (shipped) and the NPC rule; LiveCrime.requireRoute an on/off gameplay rule like Route.required
    for path, want in pairs({
        officerAlerts = { 'normal', 'normal,silenced' },
        routeEnds = { 'first_contact', 'first_contact,start' },
        downed = { 'keep_earned', 'keep_earned,failed' },
        outsideCuff = { 'assist', 'assist,stopped' },     -- V15 (critic C11)
    }) do
        local e = S.entry('RealSuspects.' .. path) or {}
        H.eq(e.kind, 'enum', 'RealSuspects.' .. path .. ' is a pick')
        H.eq(e.default, want[1], 'RealSuspects.' .. path .. ' ships ' .. want[1])
        H.eq(table.concat(e.tpl and e.tpl.options or {}, ','), want[2], 'RealSuspects.' .. path .. ': ' .. want[2])
        H.eq((S.check('RealSuspects.' .. path, 'off')), false, 'RealSuspects.' .. path .. ' refuses anything else')
        H.ok(not e.restart and not e.money, 'RealSuspects.' .. path .. ' needs no restart and is not a money switch')
    end
    for path, desc in pairs({
        officerAlerts = 'The NPC-mission rules that do not fit a fight with a real player (each can be set back). '
            .. '\'normal\' = an officer\'s own shots-fired, person-down and EMS calls go out like any officer\'s, so '
            .. 'backup can come; \'silenced\' = the NPC-mission rule (no alerts)',
        routeEnds = '\'first_contact\' = an officer who gets near a suspect (contactRange) counts as arrived and his '
            .. 'route check stops; \'start\' = the NPC-mission rule (only the mission start counts)',
        downed = '\'keep_earned\' = a downed officer leaves with what he earned so far and no type cooldown; '
            .. '\'failed\' = the NPC-mission rule (his run is Failed)',
        outsideCuff = 'An on-duty officer outside the case who cuffs a suspect: \'assist\' = it counts as the case\'s '
            .. 'cuff while an officer of the case is within contactRange of the suspect (else the suspect counts for '
            .. 'nobody); \'stopped\' = the suspect always counts for nobody, like a jail by someone outside the case',
        downedPickupDelay = 'Seconds down, with no EMS on duty, before the pick-up (keep equal to sc-ambulance\'s '
            .. 'Config.DeathTime; NPC missions use Config.Downed.pickupDelay)',
        npcCombat = 'false = no NPC-combat headshot protection or damage cut for officers once a real suspect is in '
            .. 'the case; true = they keep Config.NpcCombat\'s officer settings',
    }) do
        H.eq((S.entry('RealSuspects.' .. path) or {}).desc, desc, 'RealSuspects.' .. path .. ': its own comment')
    end
    H.eq((S.entry('RealSuspects.downedPickupDelay') or {}).default, 400, 'downedPickupDelay ships 400 s')
    H.eq((S.check('RealSuspects.downedPickupDelay', 0)), false, 'a pick-up delay of 0 s is refused')
    H.ok((S.check('RealSuspects.downedPickupDelay', 600)), 'a pick-up delay above Downed.pickupDelay\'s 120 is allowed')
    H.eq((S.entry('RealSuspects.npcCombat') or {}).kind, 'boolean', 'npcCombat is a switch')
    local rr = S.entry('LiveCrime.requireRoute') or {}
    H.eq(rr.kind, 'boolean', 'LiveCrime.requireRoute is an on/off setting')
    H.eq(rr.default, false, 'LiveCrime.requireRoute ships false')
    H.eq(
        rr.desc,
        'false = officers on a live case may leave the GPS route to chase; true = the normal route rule '
            .. '(Config.Route.required)',
        'LiveCrime.requireRoute: its own comment'
    )
    H.ok(not rr.restart and not rr.money, 'LiveCrime.requireRoute needs no restart and is not a money switch')

    -- V10: the intake's keys; types is one setting (an open table) whose values are mission types or false
    for path, desc in pairs({
        sources = 'the only scripts allowed to report a crime',
        types = 'which crimes become LIVE calls, and the mission type whose points they use',
        suspectRadius = 'crew members further than this from the crime at the alert are not suspects',
        -- V11: the LIVE call
        offerTime = 'seconds a LIVE call stays open before it lapses (the crime\'s end lapses it too)',
        maxLiveRuns = 'LIVE calls and live cases at once; a crime past this gets no LIVE call',
        -- V12: the live case (the live_response block)
        sceneRadius = 'The live case (officers who claimed a LIVE call): Respond, Secure the scene, then Detain and '
            .. 'book the suspects. Metres around the reported place that count as being at the scene',
        secureSeconds = 'seconds officers must hold the scene to secure it (0 = reaching it is enough)',
        lastReportedEvery = 'Seconds between the "last reported" map points of suspects still free (never a live '
            .. 'position; 0 = no points)',
        deadCaseSeconds = 'Seconds a case stays open once no suspect is left to work (all booked, lost, left or void) '
            .. 'before it ends',
        -- V13: live scoring (the cash and items money switches: live_scoring_spec)
        linesOnly = 'Points of a live case: true = only its live lines (scene secured, each detain and booking x the '
            .. 'suspect\'s share) and its conduct penalties; false = the mission type\'s points plus those lines, like '
            .. 'a mission',
        tier = 'Which team sets a live case\'s tier (the points and cash multiplier of Config.Scaling): \'crew\' = the '
            .. 'number of suspects at the alert; \'officers\' = the officers on the case, like a mission',
        typeOfTheDay = 'true = a live case of today\'s Type of the Day gets its points multiplier too',
        goals = 'true = live cases count for the officers\' daily and weekly goals',
        challenge = 'true = live cases count for the department challenge and the weekly bounty',
        -- V14: the claim
        caseTime = 'seconds a live case lasts at most; it then ends with the points earned',
        readyCheck = 'true = a unit of 2+ answers the ready check before its live case opens, like a mission; false = '
            .. 'the case opens at once (a real crime does not wait)',
        typeCooldown = 'true = an officer with a type cooldown (he abandoned a mission of that type) can\'t claim a '
            .. 'LIVE call of that type, and leaving a live case early starts that cooldown; false = live cases ignore '
            .. 'type cooldowns',
        duringOperation = 'true = LIVE calls can still be claimed while a Cross-Department Mission runs (its lock stops '
            .. 'missions only); false = the Cross-Department lock stops live cases too',
        -- V15: backup joins the case
        backup = 'Backup: true = an on-duty officer on no mission who marks himself responding to the crime\'s own '
            .. 'SC-Dispatch call, reaches the scene or cuffs a suspect gets a pop-up to join the live case; false = '
            .. 'only the unit that claimed the LIVE call works the case',
        maxOfficers = 'officers on one live case at most (the unit that claimed it counts)',
        joinOfferSeconds = 'seconds the join pop-up waits for an answer',
        -- V16: the officers' tablet
        caseCard = 'The officers\' tablet: true = a LIVE line on the unit\'s ready check and a case card on Active '
            .. 'Mission (the three steps, the suspect count and when the "last reported" points were taken; never a '
            .. 'suspect\'s state or a live position); false = the case shows like any mission',
        resultOutcomes = 'true = the result card lists each suspect\'s outcome by label (Suspect A: booked, Suspect '
            .. 'B: got away) once the case is over; false = no outcomes on the result card',
        -- V19: results for other scripts
        endEvent = 'Results for other scripts: true = when a live case ends, Crimson-Police sends the server-only '
            .. 'event crimson-police:server:liveCrimeEnded (the crime, how the case ended and each suspect\'s '
            .. 'outcome); false = no event',
        availablePolice = 'Who the export GetAvailablePolice counts: \'idle\' = on-duty officers on no mission (they '
            .. 'could answer a crime now); \'duty\' = every on-duty officer. The export answers nil while enabled is '
            .. 'false',
    }) do
        local e = S.entry('LiveCrime.' .. path) or {}
        H.eq(e.desc, desc, 'LiveCrime.' .. path .. ': its own comment')
        H.ok(not e.restart and not e.money, 'LiveCrime.' .. path .. ' needs no restart and is not a money switch')
    end
    H.eq(S.entry('LiveCrime.types.warehouse_burglary'), nil, 'LiveCrime.types is edited as a whole')
    H.ok((S.check('LiveCrime.types', { warehouse_burglary = 'tactical', atm_robbery = false, my_heist = 'patrol' })),
        'LiveCrime.types takes mission types and false, for any contract key')
    local okT, errT = S.check('LiveCrime.types', { warehouse_burglary = 'heist' })
    H.ok(okT == false and errT == 'err.setting_live_type', 'LiveCrime.types refuses a value that is not a mission type')
    H.eq((S.check('LiveCrime.types', { warehouse_burglary = true })), false, 'LiveCrime.types refuses true')
    H.eq((S.entry('LiveCrime.sources') or {}).kind, 'list', 'LiveCrime.sources is a list')
    H.ok((S.check('LiveCrime.sources', { 'crimson-contracts', 'my_heists' })), 'LiveCrime.sources takes resource names')
    H.eq((S.check('LiveCrime.sources', { 'bad name!' })), false, 'LiveCrime.sources refuses other text')
    H.eq((S.check('LiveCrime.suspectRadius', 5000.0)), false, 'suspectRadius stays within 10-2000 m')
    H.eq((S.check('LiveCrime.offerTime', 10)), false, 'offerTime stays within 30-3600 s')
    H.eq((S.check('LiveCrime.maxLiveRuns', 0)), false, 'maxLiveRuns stays within 1-20')
    H.ok((S.check('LiveCrime.maxLiveRuns', 5)), 'maxLiveRuns 5 is allowed')
    H.eq((S.check('LiveCrime.sceneRadius', 5)), false, 'sceneRadius stays within 10-500 m')
    H.eq((S.check('LiveCrime.secureSeconds', 1000)), false, 'secureSeconds stays within 0-900 s')
    H.ok((S.check('LiveCrime.lastReportedEvery', 0)), 'lastReportedEvery 0 (no points) is allowed')
    H.eq((S.check('LiveCrime.deadCaseSeconds', 1)), false, 'deadCaseSeconds stays within 5-600 s')
    H.eq((S.check('LiveCrime.caseTime', 30)), false, 'caseTime stays within 60-3600 s')
    H.ok((S.check('LiveCrime.caseTime', 3600)), 'caseTime 3600 is allowed')
    H.eq((S.check('LiveCrime.maxOfficers', 0)), false, 'maxOfficers stays within 1-16')
    H.eq((S.check('LiveCrime.maxOfficers', 17)), false, 'maxOfficers stays within 1-16 (17)')
    H.eq((S.check('LiveCrime.joinOfferSeconds', 5)), false, 'joinOfferSeconds stays within 10-120 s')
    H.ok((S.check('LiveCrime.joinOfferSeconds', 60)), 'joinOfferSeconds 60 is allowed')
    H.eq((S.entry('LiveCrime.backup') or {}).kind, 'boolean', 'LiveCrime.backup is an on/off setting')
    for _, k in ipairs({ 'caseCard', 'resultOutcomes' }) do
        H.eq((S.entry('LiveCrime.' .. k) or {}).kind, 'boolean', 'LiveCrime.' .. k .. ' is an on/off setting (V16)')
        H.eq(Config.LiveCrime[k], true, 'LiveCrime.' .. k .. ' ships on (behind enabled = false)')
    end
    H.eq((S.entry('LiveCrime.availablePolice') or {}).kind, 'enum', 'LiveCrime.availablePolice is a choice (V19)')
    H.eq((S.check('LiveCrime.availablePolice', 'all')), false, 'availablePolice takes only idle or duty')
    H.eq((S.entry('LiveCrime.endEvent') or {}).kind, 'boolean', 'LiveCrime.endEvent is an on/off setting (V19)')
    local vEnd = S.entry('Volunteers.endEvent') or {}
    H.eq(vEnd.kind, 'boolean', 'Volunteers.endEvent is an on/off setting (V26)')
    H.eq(
        vEnd.desc,
        'Results for other scripts: true = when a mission a volunteer said yes to ends, Crimson-Police '
            .. 'sends the server-only event crimson-police:server:volunteerEnded (the mission, the suspect he played, how '
            .. 'it ended and his outcome, by his citizenid; another script can reward him); false = no event',
        'Volunteers.endEvent: its own comment'
    )
    H.ok(not vEnd.restart and not vEnd.money, 'Volunteers.endEvent needs no restart and is not a money switch')
    for _, k in ipairs({ 'readyCheck', 'typeCooldown', 'duringOperation' }) do
        H.eq((S.entry('LiveCrime.' .. k) or {}).kind, 'boolean', 'LiveCrime.' .. k .. ' is an on/off setting')
    end
    for id, desc in pairs({
        live_scene = 'live case: secured the scene',
        live_detain = 'live case: per suspect detained (x his share)',
        live_book = 'live case: per suspect booked (x his share)',
    }) do
        local group = nil
        for _, sec in ipairs(S._schema().sections) do
            for _, g in ipairs(sec.groups) do if g.path == 'Bonuses.' .. id then group = g end end
        end
        H.eq(group and group.desc, desc, 'Bonuses.' .. id .. ': its comment is the description in Settings')
    end
end

-- ============================================================================
--                         THE DOCS RECORD THE DECISION
-- ============================================================================

do
    local readme = ReadRepo('README.md')
    -- README 5.2 (what ships off): live crimes and volunteers are switches that ship off; the route switch ships on
    local ships = readme and readme:match('### 5%.2 What ships off.-\n## ') or ''
    local off, on = ships:match('%*%*Ships off%*%*(.-)%*%*Ships on%*%*(.*)')
    H.ok(Has(off, '`Config.LiveCrime.enabled`') and Has(off, '`Config.Volunteers.enabled`'),
        'README 5.2 lists live crimes and volunteers as shipping off')
    H.ok(Has(on, '`Config.Route.required`'), 'README 5.2 lists the start route switch as shipping on')

    local spec = ReadRepo('docs/dev/SPEC.md')
    H.ok(spec ~= nil, 'docs/dev/SPEC.md is readable')
    local route = Bullet(spec, 'Route to the start:')
    local switches = Bullet(spec, 'Rule switches:')
    -- RT1's sentences, word for word
    H.ok(Has(
        route,
        'The owner may switch this rule off (Config.Route.required = false): the route is still shown and '
            .. 'checked for arrival, but leaving it never ends a run.'
    ), 'Route to the start keeps RT1\'s Config.Route.required text')
    H.ok(Has(
        switches,
        'Hard rule 17 (the start route) is the one exception: the owner made it switchable with '
            .. 'Config.Route.required (see that rule).'
    ), 'Rule switches keeps RT1\'s Config.Route.required text')
    H.ok(Has(route, 'Config.LiveCrime.requireRoute (shipped false) replaces Config.Route.required'),
        'Route to the start names the live-crime route option')
    H.ok(Has(route, 'Volunteer-suspect missions follow Config.Route.required.'), 'and the volunteers\' rule')
    H.ok(Has(switches, 'Config.LiveCrime.requireRoute sets the start-route rule for live crimes (shipped false)'),
        'Rule switches names the live-crime route option')
    H.ok(Has(switches, 'For NPC missions rules 15, 16 and 18 stay on.'), 'the NPC rules stay on')
    H.ok(Has(Bullet(spec, 'NPCs only:'), 'except live crimes (Config.LiveCrime) and volunteer suspects'),
        'NPCs only names the two exceptions')
    H.ok(Has(Bullet(spec, 'Real calls first:'), 'There are exactly three exceptions'), 'Real calls first: three')
    H.ok(Has(Bullet(spec, 'Mission choice:'), 'Only five exceptions exist'), 'Mission choice: five (step P19 push)')

    local arch = ReadRepo('docs/dev/ARCHITECTURE.md')
    for _, head in ipairs({
        '### 5.45 CP.Opponents',
        '### 5.46 CP.LiveCrime',
        '### 5.47 CP.Volunteers',
        '### 7.3 The `live_response` block',
    }) do
        H.ok(Has(arch, '\n' .. head), 'ARCHITECTURE has the stub ' .. head)
    end
end

return H
