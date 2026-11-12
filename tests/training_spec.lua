-- The guided tours (modules/access/training CP.Training, Config.Training): the shipped settings, a finished tour

-- The guided tours (modules/access/training CP.Training, Config.Training): the shipped settings, a finished tour
-- saved per character in cp_tours (once, never lowered, a later version re-shows only its new steps: the tablet reads
-- the version saved), training:get and server:training:done, an admin's reset, and /crimsonhelp opening the tour of
-- the player's role.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })

-- ============================================================================
--                                    STUBS
-- ============================================================================
-- 1 officer, 2 supervisor, 3 admin (no police job), 4 criminal tablet user, 5 no tablet at all, 6 not loaded

local officers = { [1] = { isSupervisor = false }, [2] = { isSupervisor = true } }
CP.Access = {
    getOfficer = function(src)
        local o = officers[src]
        if not o then return nil, 'err.not_police' end
        return { citizenid = ('TRN%05d'):format(src), department = 'sast', isSupervisor = o.isSupervisor }
    end,
    isAdmin = function(src) return src == 3 end,
}
CP.Permissions = {
    actionsFor = function() return {} end,
    can = function(src) return src == 3 end,
}
CP.CrimTab = {
    canUse = function(src) return src == 4 end,
}
CP.Qbx = {
    getInfo = function(src)
        if src == 6 then return nil end
        return { citizenid = ('TRN%05d'):format(src) }
    end,
}
CP.Setup = {
    pending = function() return false end,
}
local notes, admins = {}, {}
CP.Tablet = {
    notify = function(src, kind, key) notes[#notes + 1] = { src = src, kind = kind, key = key } end,
    openAdmin = function(src)
        admins[#admins + 1] = src
        return true
    end,
    push = function() end,
}
for src = 1, 6 do H.players[src] = { ace = {} } end
H.players[1] = { ace = { ['crimsonpolice.admin'] = true } }

H.sql('DELETE FROM cp_tours')
H.load('modules/admin/adminkit.lua')
H.load('modules/admin/admin.lua')
H.load('modules/access/training.lua')
local Tr = CP.Training

local function Tick() H.clockMs = H.clockMs + 1100 end
local function Get(src)
    Tick()
    return H.callback('crimson-police:training:get', src, {})
end
local function Done(src, payload)
    Tick()
    H.reset()
    H.fire('crimson-police:server:training:done', src, payload, 'rq')
    local ev = H.findEvents('crimson-police:client:actionResult')[1]
    if not ev then return nil, 'no reply' end
    return ev.args[2], ev.args[3]
end

-- ============================================================================
--                               SHIPPED SETTINGS
-- ============================================================================

do
    local T = Config.Training
    H.eq(T.enabled, true, 'tours ship on')
    H.eq(T.allowSkip, true, 'Skip and Don\'t show again ship on')
    H.eq(T.command, 'crimsonhelp', 'the command ships as /crimsonhelp')
    H.eq(T.setupChecklist, true, 'the Setup checklist ships on')
    for _, id in ipairs({ 'officer', 'supervisor', 'admin', 'criminal', 'run' }) do
        H.eq(T.autoStart[id], true, id .. ': starts by itself on its first open')
    end
    H.eq(T.hintSeconds, 12, 'each first run tip shows 12 s')
    H.ok(H.commands.crimsonhelp ~= nil and H.commands.crimsonhelp.restricted == false, '/crimsonhelp for everyone')
end

-- ============================================================================
--                    SAVED PER CHARACTER, ONCE, BY VERSION
-- ============================================================================

do
    local view = Get(1)
    H.ok(view and view.ok, 'training:get answers')
    H.eq(next(view.data.seen), nil, 'a new character finished no tour')
    H.eq(view.data.versions.officer, Tr.TOURS.officer, 'the versions go with it')
    H.eq(view.data.allowSkip, true, 'allowSkip goes with it')
    H.eq(Get(6).ok, false, 'a player with no character loaded gets no view')
    H.eq(view.data.versions.run, Tr.TOURS.run, 'the first run tips have a version too')
    H.eq(view.data.autoStart.run, true, 'and start by themselves')
    H.eq(view.data.hintSeconds, 12, 'each tip for hintSeconds')
    Config.Training.hintSeconds = 1
    H.eq(Get(1).data.hintSeconds, 4, 'a tip shows at least 4 s')
    Config.Training.hintSeconds = 600
    H.eq(Get(1).data.hintSeconds, 60, 'and at most 60 s')
    Config.Training.hintSeconds = 12

    local ok, res = Done(1, { tour = 'officer', version = 1 })
    H.eq(ok, true, 'the Officer tour finished')
    H.eq(res.seen.officer, 1, 'its version saved')
    H.eq(Tr.seen('TRN00001').officer, 1, 'saved for the character')
    H.eq(Get(1).data.seen.officer, 1, 'the next open reads it: the tour does not start again')
    H.eq(Get(2).data.seen.officer, nil, 'another character still has it to do')

    -- a later version: the tablet shows the steps after the saved version; a finish then saves the new one
    Tr.TOURS.officer = 2
    H.eq(Get(1).data.seen.officer, 1, 'version 2: the saved 1 stays, so only the new steps show')
    H.eq((Done(1, { tour = 'officer', version = 2 })), true, 'version 2 finished')
    H.eq(Tr.seen('TRN00001').officer, 2, 'version 2 saved')
    H.eq((Done(1, { tour = 'officer', version = 1 })), true, 'an older finish is no error')
    H.eq(Tr.seen('TRN00001').officer, 2, 'and never lowers the saved version')
    H.eq((Done(1, { tour = 'officer', version = 99 })), true, 'a version above the newest')
    H.eq(Tr.seen('TRN00001').officer, 2, 'is saved as the newest')
    Tr.TOURS.officer = 1

    local bad, err = Done(1, { tour = 'nope', version = 1 })
    H.eq(bad, false, 'an unknown tour is refused')
    H.eq(err, 'err.invalid_payload', 'as a bad payload')
    H.eq((Done(1, 'officer')), false, 'a payload that is not a table is refused')
    H.eq((Done(1, { tour = 'run', version = 1 })), true, 'the first run tips finished')
    H.eq(Tr.seen('TRN00001').run, 1, 'saved like a tour')
    H.eq((Done(4, { tour = 'criminal', version = 1 })), true, 'a criminal tablet user saves his tour too')
    H.eq(Tr.seen('TRN00004').criminal, 1, 'by his citizenid')
end

-- ============================================================================
--                                 ADMIN RESET
-- ============================================================================

do
    local res
    CreateThread(function()
        res = table.pack(CP.AdminKit.run('server:admin:resetTours', 3, { citizenid = 'TRN00001' }))
    end)
    H.eq(res[1], false, 'a reset needs a reason')
    CreateThread(function()
        res = table.pack(
            CP.AdminKit.run('server:admin:resetTours', 3, { citizenid = 'TRN00001', reason = 'New player' }))
    end)
    H.eq(res[1], true, 'an admin resets the tours of a character')
    H.eq(res[2].cleared, 2, 'and is told how many were saved')
    H.eq(next(Tr.seen('TRN00001')), nil, 'every tour starts again on his next open')
    H.eq(Tr.seen('TRN00004').criminal, 1, 'other characters keep theirs')
    local audit = H.sql('SELECT target FROM cp_audit WHERE action = \'toursReset\'')
    H.eq(#audit, 1, 'the reset is audited')
end

-- ============================================================================
--                                 /crimsonhelp
-- ============================================================================

do
    H.eq(Tr.roleTour(1), 'officer', 'an officer gets the Officer tour')
    H.eq(Tr.roleTour(2), 'supervisor', 'a supervisor gets the Supervisor tour')
    H.eq(Tr.roleTour(2, 'officer'), 'officer', 'and may ask for the Officer tour by name')
    H.eq(Tr.roleTour(3), 'admin', 'an admin with no police job gets the Admin tour')
    H.eq(Tr.roleTour(4), 'criminal', 'a criminal tablet user gets that tablet\'s tour')
    H.eq(select(2, Tr.roleTour(5)), 'err.training_none', 'no tablet: no tour')
    H.eq(select(2, Tr.roleTour(1, 'admin')), 'err.training_not_yours', 'an officer cannot ask for the Admin tour')
    H.eq(select(2, Tr.roleTour(1, 'nope')), 'err.training_unknown', 'an unknown name')
    H.eq(Tr.roleTour(1, 'run'), 'run', 'an officer may ask for the first run tips by name')
    H.eq(select(2, Tr.roleTour(4, 'run')), 'err.training_not_yours', 'not without a police job')

    local function Command(src, args)
        H.clockMs = H.clockMs + 2100
        H.reset()
        notes, admins = {}, {}
        H.commands.crimsonhelp.fn(src, args or {})
        local ev = H.findEvents('crimson-police:client:startTour')[1]
        return ev and ev.args[1] or nil
    end
    H.eq(Command(1), 'officer', '/crimsonhelp: the client opens the Officer tour')
    H.eq(Command(3), 'admin', '/crimsonhelp for an admin')
    H.eq(admins[1], 3, 'opens the Admin UI first')
    H.eq(Command(2, { 'officer' }), 'officer', '/crimsonhelp officer')
    H.eq(Command(1, { 'run' }), 'run', '/crimsonhelp run: the tips go to the NUI')
    H.eq(notes[1] and notes[1].key, 'tour.ui.run_next', 'he is told they show on his next run')
    H.eq(#admins, 0, 'no tablet opens for them')
    H.eq(Command(5), nil, 'no tour: nothing opens')
    H.eq(notes[1] and notes[1].key, 'err.training_none', 'he is told why')
    H.clockMs = H.clockMs + 2100
    H.reset()
    H.commands.crimsonhelp.fn(1, {})
    H.commands.crimsonhelp.fn(1, {})
    H.eq(#H.findEvents('crimson-police:client:startTour'), 1, 'one command per 2 s per player')

    Config.Training.enabled = false
    H.eq(select(2, Tr.roleTour(1)), 'err.training_off', 'tours off: /crimsonhelp says so')
    H.eq(Get(1).data.enabled, false, 'tours off: the tablet starts none')
    H.eq((Done(1, { tour = 'officer', version = 1 })), false, 'tours off: nothing is saved')
    Config.Training.enabled = true
end

H.sql('DELETE FROM cp_tours')
H.sql('DELETE FROM cp_audit WHERE action = \'toursReset\'')
return H
