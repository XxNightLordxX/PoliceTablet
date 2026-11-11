-- CP.Training (server): the guided tours of the tablets (Config.Training). The tablet holds the steps

-- CP.Training (server): the guided tours of the tablets (Config.Training). The tablet holds the steps
-- (web/src/shared/tour/tours.ts); the server keeps which tour each character finished, and in which version, in
-- cp_tours (one row per citizenid: JSON {"<tour>": <version>}), answers the /crimsonhelp command with the tour of the
-- player's role and lets an admin reset a character's tours (Admin UI -> Officers).

CP.Training = CP.Training or {}
local Tr = CP.Training
local U = CP.U
local TAG = 'training'

-- Every tour and its version now: the highest 'since' of its steps in web/src/shared/tour/tours.ts (a walk checks
-- that both say the same). A step added later gets the next version, and only the new steps show to a character
-- who finished an older one.
Tr.TOURS = { officer = 1, supervisor = 1, admin = 1, criminal = 1 }
Tr.ORDER = { 'officer', 'supervisor', 'admin', 'criminal' }

local COMMAND_GAP_MS = 2000      -- one /crimsonhelp per player this often

local function Call(modName, fnName, ...) return CP.Call(TAG, modName, fnName, ...) end

local function Cfg() return type(Config.Training) == 'table' and Config.Training or {} end

-- Config.Training.enabled (shipped true).
function Tr.enabled() return Cfg().enabled ~= false end

-- What the tablets need: { enabled, autoStart = { [tour] = bool }, allowSkip, checklist }.
function Tr.config()
    local cfg = Cfg()
    local auto = type(cfg.autoStart) == 'table' and cfg.autoStart or {}
    local out = {}
    for _, id in ipairs(Tr.ORDER) do out[id] = auto[id] ~= false end
    return {
        enabled = Tr.enabled(),
        autoStart = out,
        allowSkip = cfg.allowSkip ~= false,
        checklist = cfg.setupChecklist ~= false,
    }
end

local function CitizenOf(src)
    local n = U.toSrc(src)
    if not n or n <= 0 then return nil end
    local ok, info = Call('Qbx', 'getInfo', n)
    if ok and type(info) == 'table' and type(info.citizenid) == 'string' and info.citizenid ~= '' then
        return info.citizenid
    end
    return nil
end

-- ============================================================================
--                                   STORAGE
-- ============================================================================

-- The tours a character finished: { [tour] = version } (only known tours, whole numbers); {} when none or unreadable.
function Tr.seen(citizenid)
    if not CP.ValidCid(citizenid) then return {} end
    CP.Db()
    local ok, row = pcall(MySQL.single.await, 'SELECT seen FROM cp_tours WHERE citizenid = ?', { citizenid })
    if not ok then
        CP.err(TAG, 'reading the tours of %s failed: %s', citizenid, tostring(row))
        return {}
    end
    local raw = type(row) == 'table' and row.seen or nil
    local t = type(raw) == 'table' and raw or nil
    if type(raw) == 'string' and raw ~= '' then
        local okJ, v = pcall(json.decode, raw)
        t = okJ and type(v) == 'table' and v or nil
    end
    local out = {}
    for id in pairs(Tr.TOURS) do
        local v = t and math.tointeger(tonumber(t[id]))
        if v and v > 0 then out[id] = v end
    end
    return out
end

local function Write(citizenid, seen)
    local text = next(seen) ~= nil and json.encode(seen) or nil
    local ok, err = pcall(MySQL.update.await, [[INSERT INTO cp_tours (citizenid, seen, updated_at) VALUES (?, ?, NOW())
        ON DUPLICATE KEY UPDATE seen = VALUES(seen), updated_at = VALUES(updated_at)]], { citizenid, text })
    if not ok then CP.err(TAG, 'saving the tours of %s failed: %s', citizenid, tostring(err)) end
    return ok
end

-- Saves that the character finished a tour in that version (never lower than one saved before). true | false, errKey.
function Tr.markDone(citizenid, tour, version)
    if not CP.ValidCid(citizenid) then return false, 'err.invalid_citizenid' end
    local top = type(tour) == 'string' and Tr.TOURS[tour] or nil
    if not top then return false, 'err.invalid_payload' end
    local v = math.tointeger(tonumber(version))
    if not v or v < 1 then return false, 'err.invalid_payload' end
    v = math.min(v, top)
    local seen = Tr.seen(citizenid)
    if (seen[tour] or 0) >= v then return true end
    seen[tour] = v
    if not Write(citizenid, seen) then return false, 'err.internal' end
    CP.log(TAG, '%s finished the %s tour (version %d)', citizenid, tour, v)
    return true
end

-- Forgets every tour of the character, so each starts again on its next open. Returns true and how many were saved.
function Tr.reset(citizenid)
    if not CP.ValidCid(citizenid) then return false, 'err.invalid_citizenid' end
    local had = U.count(Tr.seen(citizenid))
    CP.Db()
    local ok, err = pcall(MySQL.update.await, 'DELETE FROM cp_tours WHERE citizenid = ?', { citizenid })
    if not ok then
        CP.err(TAG, 'resetting the tours of %s failed: %s', citizenid, tostring(err))
        return false, 'err.internal'
    end
    return true, had
end

-- ============================================================================
--                                  ROLE TOUR
-- ============================================================================

-- The tours this player may take now: officer (on duty), supervisor (Supervisor UI), admin, criminal (the criminal
-- tablet), as a set.
function Tr.allowed(src)
    local out = {}
    local okA, admin = Call('Access', 'isAdmin', src)
    admin = okA and admin == true
    local okO, officer = Call('Access', 'getOfficer', src)
    if okO and type(officer) == 'table' then
        out.officer = true
        -- as the tablet session: the job grade, or an admin's extra grant of a supervisor power
        local okP, actions = Call('Permissions', 'actionsFor', src)
        local granted = not admin and okP and type(actions) == 'table' and #actions > 0
        if officer.isSupervisor == true or granted then out.supervisor = true end
    end
    if admin then out.admin = true end
    local okC, crim = Call('CrimTab', 'canUse', src)
    if okC and crim == true then out.criminal = true end
    return out
end

-- The tour /crimsonhelp opens: the asked one when the player may take it, else the one of his role (a supervisor's,
-- an officer's, an admin's, then the criminal tablet's). tour | nil, errKey.
function Tr.roleTour(src, asked)
    if not Tr.enabled() then return nil, 'err.training_off' end
    local allowed = Tr.allowed(src)
    if type(asked) == 'string' and asked ~= '' then
        asked = asked:lower()
        if not Tr.TOURS[asked] then return nil, 'err.training_unknown' end
        if not allowed[asked] then return nil, 'err.training_not_yours' end
        return asked
    end
    for _, id in ipairs({ 'supervisor', 'officer', 'admin', 'criminal' }) do
        if allowed[id] then return id end
    end
    return nil, 'err.training_none'
end

-- ============================================================================
--                                     NET
-- ============================================================================

-- training:get: { enabled, autoStart, allowSkip, seen, versions, setupPending } for the open tablet. Any player
-- with a character may ask (the criminal tablet has no officer).
CP.Net.callback('training:get', function(src)
    local cid = CitizenOf(src)
    if not cid then return nil, 'err.training_not_loaded' end
    local out = Tr.config()
    out.seen = Tr.seen(cid)
    out.versions = U.copy(Tr.TOURS)
    -- an admin who still has the First-start setup on Home takes the Admin tour from its last page instead
    local okA, admin = Call('Access', 'isAdmin', src)
    local okS, pending = Call('Setup', 'pending')
    out.setupPending = okA and admin == true and okS and pending == true or false
    return out
end, { rate = 4 })

-- server:training:done { tour, version }: the player finished the tour (or chose Don't show again).
CP.Net.action('server:training:done', function(src, p)
    if not Tr.enabled() then return false, 'err.training_off' end
    if type(p) ~= 'table' then return false, 'err.invalid_payload' end
    local cid = CitizenOf(src)
    if not cid then return false, 'err.training_not_loaded' end
    local ok, err = Tr.markDone(cid, p.tour, p.version)
    if not ok then return false, err end
    return true, { seen = Tr.seen(cid) }
end, { rate = 4 })

local Kit = CP.AdminKit
if Kit and Kit.action then
    -- Admin UI -> Officers: every tour of the character starts again on his next open.
    Kit.action('server:admin:resetTours', 'officerRecords', function(ctx)
        local cid = ctx.payload.citizenid
        local ok, had = Tr.reset(cid)
        if not ok then return false, had end
        ctx.audit('toursReset', cid, tostring(had), '0')
        return true, { citizenid = cid, cleared = had }
    end, { reason = true })
end

-- /crimsonhelp [tour]: the client opens that tablet and starts its tour.
local lastCommand = {}
local function OnCommand(src, args)
    if type(src) ~= 'number' or src <= 0 then return end
    local now = GetGameTimer()
    if lastCommand[src] and now - lastCommand[src] < COMMAND_GAP_MS then return end
    lastCommand[src] = now
    local asked = type(args) == 'table' and type(args[1]) == 'string' and args[1]:sub(1, 16) or nil
    local tour, err = Tr.roleTour(src, asked)
    if not tour then
        CP.Tablet.notify(src, 'error', err)
        return
    end
    if tour == 'admin' then
        local okO, opened = Call('Tablet', 'openAdmin', src)
        if not (okO and opened) then return end
    end
    TriggerClientEvent(CP.e('client:startTour'), src, tour)
end
Tr._onCommand = OnCommand

local command = Cfg().command
if type(command) == 'string' and command:match('^%a[%w_%-]*$') then
    RegisterCommand(command, function(src, args) OnCommand(src, args) end, false)
end

AddEventHandler('playerDropped', function() lastCommand[source] = nil end)
