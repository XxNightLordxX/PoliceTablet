-- CP.Opponents surrender (server, step RP1): a real suspect of a live case gives himself up, by his own command or

CP.Opponents = CP.Opponents or {}
local Opp = CP.Opponents
local TAG = 'opponents'

local DONE = { lost = true, left = true, void = true }

local asks = {}                   -- [citizenid] = { token, untilMs, by (officer src | nil), runId }: one open question
local talkAt = {}                 -- [officer src] = { [citizenid] = GetGameTimer() of his last Talk them down }
local registered = nil            -- the command name once registered (RegisterCommand cannot be undone: restart)
local errorAt = {}

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function Cfg()
    local rs = type(Config.RealSuspects) == 'table' and Config.RealSuspects or {}
    return type(rs.surrender) == 'table' and rs.surrender or {}
end

local function Num(v, default)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return default end
    return v
end

local function LogError(key, fmt, ...)
    local now = os.time()
    if errorAt[key] and now - errorAt[key] < 60 then return end
    errorAt[key] = now
    CP.err(TAG, fmt, ...)
end

-- On while live crimes are on and the surrender block is not switched off (it ships on).
local function Enabled()
    return type(Config.LiveCrime) == 'table' and Config.LiveCrime.enabled == true and Cfg().enabled ~= false
end

local function Bucket(src)
    if type(GetPlayerRoutingBucket) ~= 'function' then return 0 end
    local ok, b = pcall(GetPlayerRoutingBucket, src)
    if not ok then return 0 end
    return tonumber(b) or 0
end

local function ServerCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    return GetEntityCoords(ped)
end

local function Notify(src, kind, key, vars)
    if not (CP.Tablet and CP.Tablet.notify) then return end
    local ok, err = pcall(CP.Tablet.notify, src, kind, key, vars)
    if not ok then LogError('notify', 'CP.Tablet.notify failed: %s', tostring(err)) end
end

-- The active participants of the case's run with their server positions (the main bucket only).
local function Officers(case)
    local out = {}
    local run = case.run
    if type(run) ~= 'table' or type(run.order) ~= 'table' or type(run.participants) ~= 'table' then return out end
    for _, src in ipairs(run.order) do
        local p = run.participants[src]
        if type(p) == 'table' and p.status == 'active' and Bucket(src) == 0 then
            local c = ServerCoords(src)
            if c then out[#out + 1] = { src = src, coords = c } end
        end
    end
    return out
end

local function NotifyOfficers(case, kind, key, vars)
    for _, o in ipairs(Officers(case)) do Notify(o.src, kind, key, vars) end
end

-- The open live case src works as an active participant, or nil.
local function OfficerCase(src)
    for _, e in ipairs(Opp.cases and Opp.cases() or {}) do
        local case = e.case
        local run = case.run
        if e.open and case.kind == 'live' and type(run) == 'table' and run.state ~= 'ended' then
            local p = type(run.participants) == 'table' and run.participants[src] or nil
            if type(p) == 'table' and p.status == 'active' then return case end
        end
    end
    return nil
end

local function Active(rec)
    local s = rec.surrender
    return type(s) == 'table' and s.ended == nil
end

-- A free suspect who can give himself up now: online, in the main bucket, not down.
local function CanSurrender(rec)
    return rec.state == 'free' and rec.src ~= nil and not rec.down and not rec.inInstance and not Active(rec)
end

-- ============================================================================
--                         THE QUESTION AND THE ANSWER
-- ============================================================================

-- The yes/no pop-up on the suspect's game: by = the officer who talks him down, nil for his own command.
local function Ask(case, rec, by)
    local seconds = math.floor(math.max(5, math.min(60, Num(Cfg().askSeconds, 20))))
    local token = CP.U.uuid()
    asks[rec.cid] = { token = token, untilMs = GetGameTimer() + seconds * 1000, by = by, runId = case.runId }
    TriggerClientEvent(CP.e('client:liveSurrenderAsk'), rec.src, {
        token = token,
        seconds = seconds,
        talk = by ~= nil,
    })
    return true
end

local function Pending(cid)
    local a = asks[cid]
    if a and GetGameTimer() > a.untilMs then
        asks[cid] = nil
        a = nil
    end
    return a
end

-- Metres from coords to the nearest officer of the case (math.huge without one).
local function NearestOfficer(case, coords)
    local best = math.huge
    for _, o in ipairs(Officers(case)) do
        local d = CP.U.dist(o.coords, coords)
        if d < best then best = d end
    end
    return best
end

local function Apply(case, rec, coords, by)
    rec.surrender = { at = GetGameTimer(), coords = coords, by = by }
    Opp.timeline(case.run, { what = 'surrendered', label = rec.label, src = rec.src, by = by })
    CP.log(TAG, 'run %s suspect %s surrendered%s', tostring(case.runId), rec.label, by and (' to ' .. by) or '')
    Notify(rec.src, 'success', 'livecrime.surrender.done')
    NotifyOfficers(case, 'success', 'livecrime.surrender.officers', { label = rec.label })
end

-- The suspect's command (or a test): his own surrender question. -> true | false, err (a locale key).
function Opp.surrenderCommand(src)
    if not Enabled() then return false, 'livecrime.surrender.off' end
    local case, rec = Opp.bySrc(src)
    if not case or case.kind ~= 'live' or rec.state ~= 'free' then return false, 'livecrime.surrender.not_wanted' end
    if Active(rec) then return false, 'livecrime.surrender.already' end
    if rec.down or rec.inInstance or Bucket(src) ~= 0 then return false, 'livecrime.surrender.cannot' end
    if Pending(rec.cid) then return false, 'livecrime.surrender.pending' end
    return Ask(case, rec, nil)
end

-- An officer's Talk them down: the nearest free suspect of his live case within talkRange is asked. -> true, label |
-- false, err.
function Opp.talkDown(src)
    if not Enabled() then return false, 'livecrime.surrender.off' end
    local case = OfficerCase(src)
    if not case then return false, 'livecrime.talk.no_case' end
    local me = Bucket(src) == 0 and ServerCoords(src) or nil
    if not me then return false, 'livecrime.talk.none' end
    local range = Num(Cfg().talkRange, 15.0)
    local best, bestD = nil, math.huge
    for _, cid in ipairs(case.order) do
        local rec = case.suspects[cid]
        if CanSurrender(rec) and Bucket(rec.src) == 0 then
            local c = ServerCoords(rec.src)
            local d = c and CP.U.dist(me, c) or math.huge
            if d <= range and d < bestD then best, bestD = rec, d end
        end
    end
    if not best then return false, 'livecrime.talk.none' end
    if Pending(best.cid) then return false, 'livecrime.talk.busy' end
    local now = GetGameTimer()
    local mine = talkAt[src] or {}
    talkAt[src] = mine
    local wait = math.max(0, Num(Cfg().talkCooldown, 30)) * 1000
    if mine[best.cid] and now - mine[best.cid] < wait then
        return false, 'livecrime.talk.cooldown'
    end
    mine[best.cid] = now
    Ask(case, best, src)
    Opp.timeline(case.run, { what = 'talk_down', label = best.label, src = best.src, by = src })
    return true, best.label
end

-- The suspect's answer (server:liveSurrender): the token of his open question, then the checks again. -> true |
-- false, err.
function Opp.surrenderAnswer(src, token, yes)
    local case, rec = Opp.bySrc(src)
    if not rec then return false, 'unknown' end
    local a = asks[rec.cid]
    if not a or a.token ~= token or a.runId ~= case.runId then return false, 'unknown' end
    asks[rec.cid] = nil
    if yes ~= true then
        if a.by then
            Opp.timeline(case.run, { what = 'talk_refused', label = rec.label, src = rec.src, by = a.by })
            Notify(a.by, 'info', 'livecrime.talk.refused', { label = rec.label })
        end
        return false, 'declined'
    end
    if GetGameTimer() > a.untilMs then return false, 'livecrime.surrender.expired' end
    if not Enabled() then return false, 'livecrime.surrender.off' end
    if case.kind ~= 'live' or not CanSurrender(rec) or Bucket(src) ~= 0 then
        return false, 'livecrime.surrender.cannot'
    end
    local coords = ServerCoords(src)
    if not coords then return false, 'livecrime.surrender.cannot' end
    if NearestOfficer(case, coords) > Num(Cfg().surrenderRange, 50.0) then
        return false, 'livecrime.surrender.no_officer'
    end
    Apply(case, rec, coords, a.by)
    return true
end

-- Whether a suspect's detain is a peaceful arrest: he surrendered, the surrender still held when he was cuffed (the
-- cuff came after it), he was not detained by a leave and no officer hit him since he gave up. -> bool, by.
function Opp.peaceful(run, cid)
    local case = Opp.caseOf(run)
    local rec = case and type(cid) == 'string' and case.suspects[cid] or nil
    if not rec or case.kind ~= 'live' or not Active(rec) or rec.byLeave then return false end
    local s = rec.surrender
    if not rec.cuffedAt or rec.cuffedAt < s.at then return false end
    if rec.lastHitAt and rec.lastHitAt >= s.at then return false end
    return true, s.by
end

-- ============================================================================
--                         THE WATCH PASS (V4's onTick)
-- ============================================================================

local function End(case, rec, why)
    rec.surrender.ended = why
    Opp.timeline(case.run, { what = 'surrender_ended', label = rec.label, src = rec.src, why = why })
    if rec.src then Notify(rec.src, 'warning', 'livecrime.surrender.ended_' .. why) end
    NotifyOfficers(case, 'warning', 'livecrime.surrender.ended_officers', { label = rec.label })
end

-- A surrender that holds no longer while he is still free: he broke out of the cuffs, moved off, drew a weapon or
-- nobody cuffed him within holdSeconds.
local function Check(case, rec, now)
    local s = rec.surrender
    if DONE[rec.state] then
        s.ended = rec.state
        return
    end
    if rec.state ~= 'free' then return end
    local cfg = Cfg()
    local rs = Config.RealSuspects or {}
    local armedMs = math.max(0, Num(rs.armedMemory, 15)) * 1000
    if rec.cuffedAt and rec.cuffedAt >= s.at then
        End(case, rec, 'released')
    elseif rec.armedUntil and rec.armedUntil - armedMs > s.at then
        End(case, rec, 'armed')
    elseif rec.lastCoords and s.coords and CP.U.dist(rec.lastCoords, s.coords) > Num(cfg.breakRange, 10.0) then
        End(case, rec, 'moved')
    elseif now - s.at > math.max(1, Num(cfg.holdSeconds, 120)) * 1000 then
        End(case, rec, 'lapsed')
    end
end

-- The officers' prompt: an officer of the case within talkRange of a free suspect who has not surrendered is told,
-- once per officer and suspect, that he can talk him down (never a position: the suspect is in sight there).
local function Hints(case, officers)
    local range = Num(Cfg().talkRange, 15.0)
    for _, cid in ipairs(case.order) do
        local rec = case.suspects[cid]
        if CanSurrender(rec) and rec.lastCoords then
            for _, o in ipairs(officers) do
                rec.talkHinted = rec.talkHinted or {}
                if not rec.talkHinted[o.src] and CP.U.dist(o.coords, rec.lastCoords) <= range then
                    rec.talkHinted[o.src] = true
                    Notify(o.src, 'info', 'livecrime.talk.hint', { label = rec.label })
                end
            end
        end
    end
end

local function Tick(case, now)
    if case.kind ~= 'live' then return end
    for _, cid in ipairs(case.order) do
        if Opp.caseOf(case.runId) ~= case then return end
        local rec = case.suspects[cid]
        if Active(rec) then Check(case, rec, now) end
    end
    if Enabled() then Hints(case, Officers(case)) end
end

-- ============================================================================
--                            COMMAND AND NET EVENTS
-- ============================================================================

local function Register()
    if registered or not Enabled() then return end
    local cmd = Cfg().command
    cmd = type(cmd) == 'string' and cmd:match('^%a[%w_%-]*$') or 'surrender'
    registered = cmd
    RegisterCommand(cmd, function(source)
        local src = math.tointeger(tonumber(source))
        if not src or src <= 0 then return end
        if CP.Net and CP.Net.rateOk and not CP.Net.rateOk(src, 'livecrime:surrender', 2, 3000) then return end
        local ok, err = Opp.surrenderCommand(src)
        if not ok then Notify(src, 'error', err) end
    end, false)
end
Opp.registerSurrender = Register

RegisterNetEvent(CP.e('server:liveSurrender'), function(token, yes)
    local src = math.tointeger(tonumber(source))
    if not src or src <= 0 then return end
    if CP.Net and CP.Net.rateOk and not CP.Net.rateOk(src, 'livecrime:surrender_answer', 3, 1000) then return end
    if type(token) ~= 'string' or #token > 64 then return end
    local ok, err = Opp.surrenderAnswer(src, token, yes == true)
    if not ok and err ~= 'unknown' and err ~= 'declined' then Notify(src, 'error', err) end
end)

RegisterNetEvent(CP.e('server:liveTalkDown'), function()
    local src = math.tointeger(tonumber(source))
    if not src or src <= 0 then return end
    if CP.Net and CP.Net.rateOk and not CP.Net.rateOk(src, 'livecrime:talk', 2, 2000) then return end
    local ok, res = Opp.talkDown(src)
    if ok then
        Notify(src, 'info', 'livecrime.talk.asked', { label = res })
    else
        Notify(src, 'error', res)
    end
end)

AddEventHandler('playerDropped', function()
    local src = math.tointeger(tonumber(source))
    if src then talkAt[src] = nil end
end)

CreateThread(function()
    Wait(0)
    Register()
    if CP.Hooks and CP.Hooks.on then
        CP.Hooks.on('settings:changed', Register)
        CP.Hooks.on('run:ended', function(run)
            local runId = type(run) == 'table' and run.id or nil
            for cid, a in pairs(asks) do
                if a.runId == runId then asks[cid] = nil end
            end
        end)
    end
    if Opp.onTick then
        Opp.onTick(Tick)
    else
        CP.err(TAG, 'modules/opponents is missing: surrenders never lapse')
    end
end)
