-- tests/int_core_spec.lua · integration of the core group (integrations, access, permissions, tablet) with
-- the modules that call it: CP.Banking.depositSociety (CP.Cash's society refund), the live-run own-run check
-- of CP.Permissions.canReviewRun, the session tier labels from CP.Scaling.label, and on the client the one
-- NUI path of the mission HUD / result screen (modules/runs/client.lua -> CP.Tablet -> SendNUIMessage),
-- the HUD kept off screen while Crimson-Arena owns the player (CRIMSON_ARENA rule 8) and the panel focus
-- helper CP.Tablet.panelFocus that modules/testing's test-control panel needs.
local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })

local realPrint = print
_G.print = function(...)
    local line = table.concat((function(...)
        local t = {}
        for i = 1, select('#', ...) do t[#t + 1] = tostring((select(i, ...))) end
        return t
    end)(...), ' ')
    if line:find('[crimson-police', 1, true) then return end
    realPrint(line)
end

local stopped = {}
_G.GetResourceState = function(name) return stopped[name] and 'stopped' or 'started' end

-- ════════════════════════════════════════════════════════════════════════════
-- Server
-- ════════════════════════════════════════════════════════════════════════════
local isAdmin = {}
CP.Access = {
    departments = function() return { { key = 'sast', label = 'San Andreas State Troopers', short = 'SAST', theme = { primary = '#1f4e8c' }, logo = {} } } end,
    department = function(key)
        if key ~= 'sast' then return nil end
        return { key = 'sast', label = 'San Andreas State Troopers', short = 'SAST',
            theme = { primary = '#1f4e8c', accent = '#f2c230', background = '#0d1522', surface = '#152235', text = '#ffffff' }, logo = {} }
    end,
    getOfficer = function(src)
        return { src = src, citizenid = 'CID' .. src, name = 'Officer ' .. src, department = 'sast',
            departmentLabel = 'San Andreas State Troopers', departmentShort = 'SAST', rank = 'Sergeant', gradeLevel = 3,
            onduty = true, isSupervisor = true, isAdmin = isAdmin[src] == true }
    end,
    isAdmin = function(src) return src == 0 or isAdmin[src] == true end,
    isSupervisor = function() return true end,
    refreshOfficerRow = function() return true end,
}

local rbCalls = {}
local rbReply = true
H.exportsMock['Renewed-Banking'] = {
    addAccountMoney = function(account, amount)
        rbCalls[#rbCalls + 1] = { account = account, amount = amount }
        if rbReply == 'error' then error('attempt to perform arithmetic on a nil value') end
        return rbReply
    end,
}

H.load('modules/integrations/renewed_banking/server.lua')
H.load('modules/permissions/server.lua')
H.load('modules/tablet/server.lua')

-- CP.Banking.depositSociety (economy request: the refund path of a society-funded payout)
do
    local B = CP.Banking
    H.eq(type(B.depositSociety), 'function', 'depositSociety exists (CP.Cash uses it when present)')
    H.eq(B.depositSociety('sast', 1250), true, 'refund accepted')
    H.eq(rbCalls[1] and rbCalls[1].account, 'sast', 'addAccountMoney: the society account')
    H.eq(rbCalls[1] and rbCalls[1].amount, 1250, 'addAccountMoney: the amount')
    H.eq(B.depositSociety('sast', 99.5), true, 'fractional amount')
    H.eq(rbCalls[2] and rbCalls[2].amount, 100, 'rounded half up like every Banking amount')
    local n = #rbCalls
    H.eq(B.depositSociety('sast', 0), true, '$0 is nothing to move')
    H.eq(#rbCalls, n, '$0 never reaches Renewed-Banking')
    for _, bad in ipairs({ -5, 0 / 0, math.huge, 'abc' }) do
        H.eq(B.depositSociety('sast', bad), false, 'invalid amount refused: ' .. tostring(bad))
    end
    H.eq(B.depositSociety('', 10), false, 'empty account refused')
    H.eq(B.depositSociety(nil, 10), false, 'missing account refused')
    H.eq(#rbCalls, n, 'refused calls send nothing (a nil amount would raise inside addAccountMoney)')
    rbReply = false
    H.eq(B.depositSociety('ABC12345', 10), false, 'Renewed-Banking refuses (a citizenid, an unknown account)')
    rbReply = 'error'
    H.eq(B.depositSociety('sast', 10), false, 'an error inside Renewed-Banking returns false, never raises')
    rbReply = true
    stopped['Renewed-Banking'] = true
    n = #rbCalls
    H.eq(B.depositSociety('sast', 10), false, 'Renewed-Banking stopped')
    H.eq(#rbCalls, n, 'nothing sent while it is stopped')
    stopped['Renewed-Banking'] = nil
end

-- CP.Permissions.canReviewRun: a partner still on the live run has no row yet (oversight request)
do
    local P = CP.Permissions
    local RUN = 'int-core-live-run-1'
    H.sql('DELETE FROM cp_mission_runs WHERE run_uuid = ?', { RUN })
    local infos = { [1] = { citizenid = 'CIDA' }, [2] = { citizenid = 'CIDB' }, [3] = { citizenid = 'CIDC' } }
    CP.Qbx = { getInfo = function(src) return infos[src] end }
    local live = { id = RUN, participants = {
        [11] = { citizenid = 'CIDA', status = 'active' },
        [12] = { citizenid = 'CIDB', status = 'left' },
    } }
    CP.Runs = { get = function(id) if id == RUN then return live end return nil end }
    H.eq(select(2, P.canReviewRun(1, RUN)), 'err.own_run', 'an active participant of the live run cannot review it')
    H.eq(select(2, P.canReviewRun(2, RUN)), 'err.own_run', 'a participant who already left cannot review it either')
    H.eq(P.canReviewRun(3, RUN), true, 'someone else can')
    H.eq(P.canReviewRun(0, RUN), true, 'the console can')
    isAdmin[1] = true
    H.eq(select(2, P.can(1, 'reviewFlagged', { runUuid = RUN })), 'err.own_run', 'can(): the own-run rule applies to admins too')
    H.eq(P.can(1, 'reviewFlagged'), true, 'admin without a run context')
    isAdmin[1] = nil
    -- the engine is broken or the run is gone: the row lookup still decides
    CP.Runs = { get = function() error('runs broken') end }
    H.eq(P.canReviewRun(1, RUN), true, 'CP.Runs.get failing: no row -> may review')
    H.sql([[INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason,
        points_base) VALUES (?, 'patrol', 'beat_patrol', 'CIDA', 'sast', 'completed', 'completed', 60)]], { RUN })
    H.eq(select(2, P.canReviewRun(1, RUN)), 'err.own_run', 'CP.Runs.get failing: the row still says own run')
    CP.Runs = nil
    H.eq(select(2, P.canReviewRun(1, RUN)), 'err.own_run', 'without CP.Runs the row decides')
    H.eq(P.canReviewRun(3, RUN), true, 'without CP.Runs others still review')
    H.sql('DELETE FROM cp_mission_runs WHERE run_uuid = ?', { RUN })
end

-- Session tiers labelled by CP.Scaling.label (engine_a request)
do
    local function session()
        H.clockMs = H.clockMs + 1000
        return H.callback('crimson-police:getSession', 5, { ui = 'officer', silent = true })
    end
    CP.Scaling = { label = function(name) return 'Scaled ' .. tostring(name) end }
    local res = session()
    H.eq(res and res.ok, true, 'officer session')
    local tiers = res and res.data and res.data.config.tiers or {}
    H.eq(#tiers, #Config.Scaling, 'one tier per Config.Scaling row')
    H.eq(tiers[1] and tiers[1].name, Config.Scaling[1].tier, 'tier name')
    H.eq(tiers[1] and tiers[1].label, 'Scaled ' .. Config.Scaling[1].tier, 'tier label from CP.Scaling.label')
    CP.Scaling = { label = function() error('scaling broken') end }
    res = session()
    H.eq(res.data.config.tiers[1].label, CP.L('tier.' .. Config.Scaling[1].tier), 'locale fallback when CP.Scaling.label fails')
    CP.Scaling = nil
    res = session()
    H.eq(res.data.config.tiers[1].label, CP.L('tier.' .. Config.Scaling[1].tier), 'locale fallback without CP.Scaling')
end

-- ════════════════════════════════════════════════════════════════════════════
-- Client: runs client -> CP.Tablet -> NUI, the arena guard and the panel focus
-- ════════════════════════════════════════════════════════════════════════════
H.handlers, H.callbacks, H.commands, H.events = {}, {}, {}, {}
CP, Config = nil, nil
H.boot({ side = 'client' })
_G.GetResourceState = function(name) return stopped[name] and 'stopped' or 'started' end

local nui, focus, nuiCb = {}, {}, {}
_G.SendNUIMessage = function(m) nui[#nui + 1] = m end
_G.SetNuiFocus = function(a, b) focus[#focus + 1] = { a, b } end
_G.RegisterNUICallback = function(name, fn) nuiCb[name] = fn end
_G.RegisterKeyMapping = function() end
_G.PlayerPedId = function() return 42 end
_G.PlayerId = function() return 0 end
_G.GetPlayerServerId = function() return 7 end
_G.GetEntityCoords = function() return vec3(1.0, 2.0, 3.0) end
_G.IsModelInCdimage = function() return true end
_G.RequestModel = function() end
_G.HasModelLoaded = function() return true end
_G.SetModelAsNoLongerNeeded = function() end
local objects, nextObj = {}, 1000
_G.CreateObject = function(model) nextObj = nextObj + 1; objects[nextObj] = model; return nextObj end
_G.DoesEntityExist = function(e) return objects[e] ~= nil end
_G.DeleteEntity = function(e) objects[e] = nil end
_G.DetachEntity = function() end
_G.SetEntityAsMissionEntity = function() end
_G.SetEntityCollision = function() end
_G.AttachEntityToEntity = function() end
_G.GetPedBoneIndex = function(_, bone) return bone end
_G.RequestAnimDict = function() end
_G.HasAnimDictLoaded = function() return true end
_G.RemoveAnimDict = function() end
local playing = false
_G.TaskPlayAnim = function() playing = true end
_G.IsEntityPlayingAnim = function() return playing end
_G.StopAnimTask = function() playing = false end
_G.IsEntityDead = function() return false end
_G.GetVehiclePedIsIn = function() return 0 end
_G.GetPedInVehicleSeat = function() return 0 end
_G.NetworkGetEntityIsNetworked = function() return false end
_G.IsVehicleSirenOn = function() return false end
_G.IsPedArmed = function() return false end
_G.IsPedShooting = function() return false end
_G.GetStreetNameAtCoord = function() return 0, 0 end
_G.GetStreetNameFromHashKey = function() return '' end
_G.GetNameOfZone = function() return '' end
_G.GetLabelText = function() return '' end
_G.SetNewWaypoint = function() end
_G.DoesBlipExist = function() return false end
_G.RemoveBlip = function() end
_G.LocalPlayer = { state = { isLoggedIn = true } }
local bagHandlers = {}
_G.AddStateBagChangeHandler = function(key, bag, fn) bagHandlers[#bagHandlers + 1] = { key = key, bag = bag, fn = fn } end
lib.progressActive = function() return false end
lib.cancelProgress = function() end

local clientPD = { job = { name = 'sast', onduty = true, grade = { level = 3, name = 'Sergeant' } } }
H.exportsMock.qbx_core = { GetPlayerData = function() return clientPD end }
local awaitHook = nil
lib.callback.await = function(name, _, args)
    if awaitHook then awaitHook(name, args) end
    if name == 'crimson-police:getSession' then
        return { ok = true, data = {
            ui = (args and args.ui) or 'officer', title = 'Crimson-Police',
            roles = { officer = true, supervisor = true, admin = false },
            officer = { citizenid = 'CID7', name = 'John Doe', department = 'sast', departmentLabel = 'SAST', departmentShort = 'SAST', rank = 'Sergeant', gradeLevel = 3 },
            theme = { primary = '#1f4e8c', accent = '#f2c230', background = '#0d1522', surface = '#152235', text = '#ffffff' },
            actions = {}, locale = {}, config = {}, serverTime = 1,
        } }
    end
    return { ok = true, data = {} }
end

local routeLog = {}
CP.Route = {
    begin = function(runId) routeLog[#routeLog + 1] = { 'begin', runId } end,
    stop = function() routeLog[#routeLog + 1] = { 'stop' } end,
}
CP.Blocks.register('int_core_block', { prepare = function() end, start = function() end, stop = function() end })

H.load('modules/integrations/qbx/client.lua')
H.load('modules/tablet/client.lua')
H.load('modules/runs/client.lua')
local T = CP.Tablet
local function tick(ms) H.advance(ms or 600, 50) end
tick(3000)   -- theme refresh, client action registration

local function nuiOf(kind, from)
    local out = {}
    for i = (from or 0) + 1, #nui do if nui[i].type == kind then out[#out + 1] = nui[i] end end
    return out
end
local function lastNui(kind)
    for i = #nui, 1, -1 do if nui[i].type == kind then return nui[i] end end
    return nil
end
local arenaHandler = bagHandlers[1] and bagHandlers[1].fn
local function setArena(value)
    arenaHandler('player:7', 'crimsonArena', value)   -- FiveM calls the handler before the value is set
    LocalPlayer.state.crimsonArena = value
    tick(100)
end

local function startRun(runId)
    H.fire('crimson-police:client:start', nil, runId, {
        missionId = 'beat_patrol', mission = { id = 'beat_patrol', label = 'Beat Patrol', objectives = { { block = 'int_core_block', label = 'A' } } },
        locationIndex = 1, location = { label = 'L', start = { coords = vec3(10.0, 20.0, 30.0), radius = 10.0 } },
        start = { coords = vec3(10.0, 20.0, 30.0), radius = 10.0 }, expectedTier = 'standard', seed = 1, host = 7,
        startRoute = true, startTimeout = 600, isBoss = false,
        participants = { { src = 7, name = 'John Doe', status = 'active', arrived = false } },
    })
end
local function breakdown(runId)
    return { runId = runId, missionLabel = 'Beat Patrol', missionType = 'patrol', result = 'completed', endReason = 'completed',
        test = false, tier = 'standard', payTier = 'standard', participants = 1, departments = 1, durationS = 100,
        points = { P = 100, bonuses = {}, penalties = {}, subtotal = 100, mTeam = 1, mCross = 1, mStreak = 1, capped = false, tod = false, final = 100 },
        cash = { B = 800, mTier = 1, mMod = 1, amount = 800, status = 'paid' } }
end

-- exactly one path: modules/runs/client.lua handles client:hud / client:runEnded, the tablet forwards to the NUI
do
    H.ok(arenaHandler ~= nil, 'the tablet watches the local crimsonArena value')
    H.eq(#(H.handlers['crimson-police:client:hud'] or {}), 1, 'one client:hud handler (the run engine), none in the tablet')
    H.eq(#(H.handlers['crimson-police:client:runEnded'] or {}), 1, 'one client:runEnded handler among the tablet and the run engine')
    local src = (LoadResourceFile('Crimson-Police', 'modules/tablet/client.lua') or '')
    local code = src:gsub('%-%-[^\n]*', '')
    H.eq(code:find("client:hud", 1, true), nil, 'the tablet code never registers client:hud')
    H.eq(code:find("client:runEnded", 1, true), nil, 'the tablet code never registers client:runEnded')

    local n0 = #nui
    startRun('run-a')
    local huds = nuiOf('hud', n0)
    H.ok(#huds >= 1, 'client:start reaches the NUI as a hud message')
    H.eq(huds[#huds].hud and huds[#huds].hud.phase, 'route', 'route phase on the NUI')
    H.eq(huds[#huds].hud and huds[#huds].hud.runId, 'run-a', 'the HUD belongs to the run')

    local n1 = #nui
    H.fire('crimson-police:client:hud', nil, 'run-a', { detail = 'Hold still: 6 s' })
    huds = nuiOf('hud', n1)
    H.eq(#huds, 1, 'one server HUD patch = exactly one NUI hud message')
    H.eq(huds[1] and huds[1].hud.detail, 'Hold still: 6 s', 'the patch is merged into the full HUD state')
    H.eq(huds[1] and huds[1].hud.phase, 'route', 'the full state is sent, not only the patch')
    H.fire('crimson-police:client:hud', nil, 'other-run', { detail = 'x' })
    H.eq(#nuiOf('hud', n1), 1, 'a patch of another run never reaches the NUI')

    local n2 = #nui
    H.fire('crimson-police:client:runEnded', nil, 'run-a', 'completed', 'completed', breakdown('run-a'))
    local results = nuiOf('result', n2)
    H.eq(#results, 1, 'client:runEnded = exactly one NUI result message')
    H.eq(results[1] and results[1].result.runId, 'run-a', 'the RunResult is forwarded as it is')
    local ended = lastNui('hud')
    H.eq(ended.hud and ended.hud.phase, 'ended', 'the ended HUD')
    H.ok(ended.hud and ended.hud.message and ended.hud.message.text ~= nil, 'with the end message')
    H.eq(ended.hud and ended.hud.timer, nil, 'timer cleared (false in Lua = cleared)')
    tick(12500)
    local hidden = lastNui('hud')
    H.eq(hidden.hud, nil, 'the ended HUD hides itself (hud(nil) -> { type = hud } without state)')
    H.eq(CP.Runs.current(), nil, 'no local run any more')

    -- a silent removal (nil breakdown) cleans up without a result screen
    startRun('run-b')
    local n3 = #nui
    H.fire('crimson-police:client:runEnded', nil, 'run-b', 'abandoned', 'quit', nil)
    H.eq(#nuiOf('result', n3), 0, 'no result screen without a breakdown')
    tick(12500)
end

-- CRIMSON_ARENA rule 8: the run engine's later HUD patches stay off screen while the value is foreign
do
    startRun('run-c')
    T.overlay({ kind = 'fade', text = 'x' })
    setArena({ active = true, matchId = 'm1' })
    H.eq(lastNui('hud').hud, nil, 'placement hides the HUD')
    H.eq(lastNui('overlay').overlay, nil, 'placement hides the overlay')
    local n0 = #nui
    H.fire('crimson-police:client:hud', nil, 'run-c', { detail = 'still running' })
    T.overlay({ kind = 'fade', text = 'y' })
    H.fire('crimson-police:client:runEnded', nil, 'run-c', 'abandoned', 'quit', nil)
    local shown = 0
    for _, m in ipairs(nuiOf('hud', n0)) do if m.hud ~= nil then shown = shown + 1 end end
    H.eq(shown, 0, 'no HUD reaches the NUI while Crimson-Arena owns the player (not even the ended HUD)')
    local ov = 0
    for _, m in ipairs(nuiOf('overlay', n0)) do if m.overlay ~= nil then ov = ov + 1 end end
    H.eq(ov, 0, 'no overlay reaches the NUI either')
    local n1 = #nui
    nuiCb.ready({}, function() end)
    local readyHud = 0
    for _, m in ipairs(nuiOf('hud', n1)) do if m.hud ~= nil then readyHud = readyHud + 1 end end
    H.eq(readyHud, 0, 'a NUI reload (ready) does not bring it back while foreign')
    -- our own flag or an inactive value is not foreign: nothing changes yet
    local n2 = #nui
    setArena({ active = true, matchId = 'm2' })
    H.eq(#nuiOf('hud', n2) > 0 and lastNui('hud').hud or nil, nil, 'a new match keeps it hidden')
    -- Crimson-Arena lets the player go within the ended HUD's 12 s: what is still set is shown again
    local n3 = #nui
    setArena(nil)
    local back = nuiOf('hud', n3)
    H.eq(#back, 1, 'the kept HUD is shown again once the value is gone')
    H.eq(back[1] and back[1].hud and back[1].hud.phase, 'ended', '...the ended HUD of the run they left')
    local ovBack = nuiOf('overlay', n3)
    H.eq(ovBack[1] and ovBack[1].overlay and ovBack[1].overlay.text, 'y', 'the kept overlay too')
    T.overlay(nil)
    tick(12500)
    H.eq(lastNui('hud').hud, nil, 'and it still hides itself afterwards')
    local n4 = #nui
    setArena({ active = true, source = 'crimson-police' })
    setArena(nil)
    H.eq(#nuiOf('hud', n4), 0, 'values that are not foreign never resend anything')
    -- a HUD hidden by hud(nil) while foreign stays hidden afterwards
    setArena({ active = true, matchId = 'm3' })
    T.hud({ runId = 'x', phase = 'route' })
    T.hud(nil)
    local n5 = #nui
    setArena(nil)
    local after = 0
    for _, m in ipairs(nuiOf('hud', n5)) do if m.hud ~= nil then after = after + 1 end end
    H.eq(after, 0, 'a HUD that was hidden meanwhile is not resurrected')
end

-- CP.Tablet.panelFocus: the NUI focus helper for the test-control panel (modules/testing)
do
    local f0 = #focus
    H.eq(T.panelFocus('testing', true), true, 'the panel takes the focus')
    H.eq(#focus, f0 + 1, 'one SetNuiFocus')
    H.eq(focus[#focus][1], true, 'focus on')
    H.eq(focus[#focus][2], true, 'with the cursor')
    H.eq(T.panelFocusOwner(), 'testing', 'owner recorded')
    H.eq(T.panelFocus('testing', true), true, 'idempotent for the owner')
    H.eq(#focus, f0 + 1, 'no second SetNuiFocus')
    H.eq(T.panelFocus('other', true), false, 'another panel cannot take it')
    H.eq(T.panelFocus('other', false), false, 'another panel cannot release it')
    H.eq(#focus, f0 + 1, 'refused calls never touch the focus')
    H.eq(T.panelFocus('testing', false), true, 'the owner releases it')
    H.eq(#focus, f0 + 2, 'one release')
    H.eq(focus[#focus][1], false, 'focus off')
    H.eq(T.panelFocusOwner(), nil, 'no owner')
    H.eq(T.panelFocus('testing', false), false, 'nothing to release')
    H.eq(#focus, f0 + 2, 'a release without the focus never touches it (rule 8: never unconditionally)')
    H.eq(T.panelFocus('', true), false, 'an owner name is required')
    H.eq(T.panelFocus(nil, true), false, 'an owner name is required (nil)')

    -- never while a tablet UI is open or opening
    H.clockMs = H.clockMs + 1000
    H.commands.CrimsonPolice.fn()
    H.eq(T.isOpen(), true, 'tablet open')
    local f1 = #focus
    H.eq(T.panelFocus('testing', true), false, 'refused while the tablet is open')
    H.eq(#focus, f1, 'the tablet keeps its focus')
    T.close()
    H.eq(#focus, f1 + 1, 'the tablet releases its own focus')
    local during = nil
    awaitHook = function(name) if name == 'crimson-police:getSession' then during = T.panelFocus('testing', true) end end
    H.clockMs = H.clockMs + 1000
    H.commands.CrimsonPolice.fn()
    awaitHook = nil
    H.eq(during, false, 'refused while the tablet is opening (session on its way)')
    H.eq(T.isOpen(), true, 'the tablet opened')
    T.close()

    -- the tablet takes it over, and its close releases it once
    tick(1100)
    H.eq(T.panelFocus('testing', true), true, 'panel focus again')
    H.clockMs = H.clockMs + 1000
    H.commands.CrimsonPolice.fn()
    H.eq(T.isOpen(), true, 'the tablet opens over the panel')
    H.eq(T.panelFocusOwner(), nil, 'the panel lost the focus to the tablet')
    local f2 = #focus
    T.close()
    H.eq(#focus, f2 + 1, 'closing the tablet releases the focus once')
    H.eq(T.panelFocus('testing', false), false, 'the old owner has nothing to release')
    H.eq(#focus, f2 + 1, 'and never releases it again')

    -- a panel holding the focus while the tablet is closed keeps it when something closes the tablet
    tick(1100)
    H.eq(T.panelFocus('testing', true), true, 'panel focus')
    local f3 = #focus
    T.close()
    H.eq(#focus, f3, 'closing a tablet that is not open leaves the panel focus alone')
    H.eq(T.panelFocusOwner(), 'testing', 'still the owner')

    -- Crimson-Arena places the player: released once; refused while foreign
    setArena({ active = true, matchId = 'm4' })
    H.eq(T.panelFocusOwner(), nil, 'placement releases the panel focus')
    H.eq(#focus, f3 + 1, 'exactly one release')
    H.eq(focus[#focus][1], false, 'focus off')
    H.eq(T.panelFocus('testing', true), false, 'refused while the value is foreign')
    H.eq(#focus, f3 + 1, 'no focus taken in the arena')
    setArena(nil)

    -- character unload releases it
    H.eq(T.panelFocus('testing', true), true, 'panel focus')
    local f4 = #focus
    H.fire('QBCore:Client:OnPlayerUnload', nil)
    tick(100)
    H.eq(T.panelFocusOwner(), nil, 'unload releases the panel focus')
    H.eq(#focus, f4 + 1, 'exactly one release on unload')
    H.fire('QBCore:Client:OnPlayerUnload', nil)
    tick(100)
    H.eq(#focus, f4 + 1, 'an unload with nothing open never touches the focus')
    tick(2000)

    -- resource stop releases it
    H.eq(T.panelFocus('testing', true), true, 'panel focus')
    local f5 = #focus
    TriggerEvent('onResourceStop', 'Crimson-Police')
    H.eq(#focus, f5 + 1, 'resource stop releases the panel focus')
    H.eq(focus[#focus][1], false, 'focus off on stop')
    H.eq(T.panelFocusOwner(), nil, 'no owner after the stop')
end

print = realPrint
return H
