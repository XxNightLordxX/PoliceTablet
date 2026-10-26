-- Objective block "search_area" (client half)

local BLOCK = 'search_area'
local U = CP.U

local OPTION = 'crimson-police:check_clue'
local FAST_MS = 250
local SLOW_MS = 1000
local WATCH_RANGE = 40.0
local REPORT_MS = 1500
local CONTROL_MS = 250
local MARKER_RANGE = 150.0
local CLUE_RANGE = 2.5
local GAVE_UP_SCALE = 0.6       -- a fugitive who gave up: kinds.suspect a size smaller
local SEARCH_ANIM = { dict = 'amb@prop_human_bum_bin@idle_b', clip = 'idle_d' }
local TALK_ANIM = { dict = 'missfbi3_party_d', clip = 'stand_talk_loop_a_male1' }
local WITNESS_SCENARIO = 'WORLD_HUMAN_STAND_MOBILE'

local active = {}

local function KeyOf(ctx) return tostring(ctx.runId) .. ':' .. tostring(ctx.index) end

local function S_of(ctx)
    local k = KeyOf(ctx)
    local S = active[k]
    if not S then
        S = {
            key = k,
            data = {},
            clues = {},
            fugitives = {},
            zones = {},
            blips = {},
            applied = {},
            tasked = {},
            lost = {},
            lastReport = {},
            alive = true,
        }
        active[k] = S
    end
    S.ctx = ctx
    return S
end

local function IsHost(S)
    if S.isHost ~= nil then return S.isHost end
    return S.ctx.isHost == true
end

local function EntityFor(netId)
    if not netId or not NetworkDoesNetworkIdExist(netId) then return nil end
    local e = NetworkGetEntityFromNetworkId(netId)
    if e and e ~= 0 and DoesEntityExist(e) then return e end
    return nil
end

local function BagOf(ent)
    local st = Entity(ent).state
    return st and st.cp or nil
end

local function ClueVec(cl) return vector3(cl.x + 0.0, cl.y + 0.0, cl.z + 0.0) end

local function ClueLabel(cl)
    if cl.kind == 'witness' then return CP.L('block.search_area.target_witness') end
    local model = tostring(cl.model or '')
    if model:find('bag') then return CP.L('block.search_area.target_bag') end
    if model:find('phone') then return CP.L('block.search_area.target_phone') end
    return CP.L('block.search_area.target_clue')
end

-- ============================================================================
--                                    BLIPS
-- ============================================================================

-- A blip handed to the objective pointer (CP.Markers) is taken back first, so its GPS line goes off before it goes
-- (BLIPS_FINAL R10).
local function Gone(b)
    if b.key then CP.Markers.release(b.key, b.id) end
    if DoesBlipExist(b.id) then RemoveBlip(b.id) end
end

local function DropBlip(S, k)
    local b = S.blips[k]
    if not b then return end
    S.blips[k] = nil
    Gone(b)
end

-- The circle in Config.Markers.kinds.searchArea (yellow, Config.Markers.areaAlpha) and its centre blip, handed to the
-- objective pointer under key 'center', the key the server's pointer names the circle by: it IS the pointer (the GPS
-- line on it until the officer is inside). A shrunk circle's new centre is handed over before the old one goes, so the
-- line moves straight to it.
local function DrawCircle(S)
    local c = S.data.circle
    local was = { S.blips.circle, S.blips.center }
    S.blips.circle, S.blips.center, S.circleKey = nil, nil, nil
    if c and not S.ctx.radioSilence then
        local area = AddBlipForRadius(c.x + 0.0, c.y + 0.0, c.z + 0.0, c.r + 0.0)
        CP.Markers.styleArea(area, 'searchArea')
        S.blips.circle = { id = area }
        local mid = AddBlipForCoord(c.x + 0.0, c.y + 0.0, c.z + 0.0)
        CP.Markers.style(mid, 'searchArea', CP.L('block.search_area.blip_area', { radius = math.floor(c.r + 0.5) }))
        S.blips.center = { id = mid, key = 'center' }
        CP.Markers.adopt('center', mid)
        S.circleKey = ('%d:%d'):format(c.n or 0, math.floor(c.r))
    end
    for _, b in pairs(was) do Gone(b) end
end

-- A clue's numbered blip (Config.Markers.kinds.clue), handed to the objective pointer under key 'c<n>' (the server's
-- pointer names each clue still to check by it, so the officer's line goes to his nearest once inside the circle).
local function EnsureClueBlip(S, cl)
    local k = 'c' .. cl.i
    if S.blips[k] then return end
    local v = ClueVec(cl)
    local id = AddBlipForCoord(v.x, v.y, v.z)
    CP.Markers.style(id, 'clue', CP.L('block.search_area.blip_clue'), { number = cl.i })
    S.blips[k] = { id = id, key = k }
    CP.Markers.adopt(k, id)
end

-- A fugitive's blip in its Config.Markers.kinds look: kinds.fleeing (orange) while he runs, kinds.suspect a size
-- smaller (0.6, as flee_arrest) once he gave up, restyled in place when that changes. Handed to the objective pointer
-- under his net id: it IS the pointer, and CP.Markers shows the same look from the server's position once he is too
-- far away for this game (BLIPS_FINAL R1, R3, R7).
local function EnsureFugitiveBlip(S, netId, ent, state)
    local k = 'f' .. tostring(netId)
    local look = state == 'fleeing' and 'fleeing' or 'suspect'
    local b = S.blips[k]
    if b and b.ent == ent and DoesBlipExist(b.id) then
        if b.look ~= look then
            CP.Markers.style(b.id, look)
            if look == 'suspect' then SetBlipScale(b.id, GAVE_UP_SCALE) end
            b.look = look
        end
        return
    end
    DropBlip(S, k)
    local id = AddBlipForEntity(ent)
    CP.Markers.style(id, look, CP.L('block.search_area.blip_fugitive'))
    if look == 'suspect' then SetBlipScale(id, GAVE_UP_SCALE) end
    S.blips[k] = { id = id, ent = ent, look = look, key = netId }
    CP.Markers.adopt(netId, id)
end

-- ============================================================================
--                                    CLUES
-- ============================================================================

local function CheckClue(S, cl)
    if S.busy then return end
    S.busy = true
    local ctx = S.ctx
    local p = ctx.obj.clueProgress or {}
    ctx.report({ type = 'clue_start', clue = cl.i })
    local done = lib.progressBar({
        duration = tonumber(p.duration) or 4000,
        label = p.label or CP.L('block.search_area.clue_progress'),
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, car = true, combat = true },
        anim = cl.kind == 'witness' and TALK_ANIM or SEARCH_ANIM,
    })
    if done and S.alive and S.current and S.clues[cl.i] and S.clues[cl.i].status == 'pending' then
        ctx.report({ type = 'clue', clue = cl.i })
    end
    S.busy = false
end

local function DropZone(S, i)
    local id = S.zones[i]
    if not id then return end
    S.zones[i] = nil
    pcall(function() exports.ox_target:removeZone(id) end)
end

local function EnsureZone(S, cl)
    if S.zones[cl.i] then return end
    S.zones[cl.i] = exports.ox_target:addSphereZone({
        coords = ClueVec(cl),
        radius = 1.2,
        debug = false,
        name = 'crimson-police:clue:' .. S.key .. ':' .. tostring(cl.i),
        options = {
            {
                name = OPTION,
                label = ClueLabel(cl),
                icon = cl.kind == 'witness' and 'fas fa-comments' or 'fas fa-magnifying-glass',
                distance = CLUE_RANGE,
                -- a clue appears once an officer is near it (Config.Spawning): nothing to check before it is there
                canInteract = function()
                    local now = S.clues[cl.i]
                    return S.alive and S.current and not S.busy and now ~= nil and now.status == 'pending'
                        and now.netId ~= nil
                end,
                onSelect = function() CreateThread(function() CheckClue(S, S.clues[cl.i] or cl) end) end,
            },
        },
    })
end

local function SyncClues(S)
    for i, cl in pairs(S.clues) do
        if cl.status == 'pending' and S.current then
            EnsureZone(S, cl)
            if not S.ctx.radioSilence then EnsureClueBlip(S, cl) end
        else
            DropZone(S, i)
            DropBlip(S, 'c' .. i)
        end
    end
end

local function MarkerLoop(S)
    if S.drawing then return end
    S.drawing = true
    CreateThread(function()
        while S.alive and S.current do
            local pos = GetEntityCoords(PlayerPedId())
            local drew = false
            for _, cl in pairs(S.clues) do
                if cl.status == 'pending' then
                    local v = ClueVec(cl)
                    if #(pos - v) <= MARKER_RANGE then
                        DrawMarker(2, v.x, v.y, v.z + 1.0, 0.0, 0.0, 0.0, 180.0, 0.0, 0.0, 0.3, 0.3, 0.3, 240, 200, 40,
                            180, true, true, 2, false, nil, nil, false)
                        drew = true
                    end
                end
            end
            Wait(drew and 0 or 750)
        end
        S.drawing = false
    end)
end

-- ============================================================================
--                             HOST AI AND REPORTS
-- ============================================================================
-- Control of a run ped before anything is done to it (ctx.control returns at once when this client
-- already owns it). regained = another client owned it since the last check: re-apply and re-task.
local function Own(S, net, ent)
    if not (S.alive and S.current) then return false, false end
    if NetworkHasControlOfEntity(ent) then
        local regained = S.lost[net] == true
        S.lost[net] = nil
        return true, regained
    end
    if not S.ctx.control(ent, CONTROL_MS) then
        S.lost[net] = true
        return false, false
    end
    S.lost[net] = nil
    -- ctx.control waits for the hand-over: the objective may have stopped meanwhile
    if not (S.alive and S.current) then return false, false end
    return true, true
end

local function HostPed(S, net, ent, state, witness)
    local fresh = false
    local owned, regained = Own(S, net, ent)
    if not owned then return end
    if S.applied[net] ~= ent or regained then
        local bag = BagOf(ent)
        CP.Npc.apply(ent, (bag and bag.cfg) or {})
        S.applied[net] = ent
        S.tasked[net] = nil
        fresh = true
    end
    if witness then
        if fresh then
            SetBlockingOfNonTemporaryEvents(ent, true)
            TaskStartScenarioInPlace(ent, WITNESS_SCENARIO, 0, true)
        end
        return
    end
    if S.tasked[net] == state then return end
    if state == 'idle' then
        SetBlockingOfNonTemporaryEvents(ent, true)
        CP.Npc.task(ent, 'cower', {})
    elseif state == 'fleeing' then
        CP.Npc.task(ent, 'flee', {})
    elseif fresh and state == 'surrendered' then
        CP.Npc.task(ent, 'kneel', {})
    elseif fresh and state == 'cuffed' then
        CP.Npc.task(ent, 'cuffed', {})
    end
    S.tasked[net] = state
end

local function ReportOnce(S, kind, netId)
    local k = kind .. ':' .. tostring(netId)
    local t = GetGameTimer()
    local last = S.lastReport[k]
    if last and t - last < REPORT_MS then return end
    S.lastReport[k] = t
    S.ctx.report({ type = kind, netId = netId })
end

local function SetHint(S, text)
    if S.hint == text then return end
    S.hint = text
    S.ctx.hudDetail(text)
end

local function HudText(S, close)
    local d = S.data
    if d.escaping then return CP.L('block.search_area.hud_escaping', { seconds = d.escaping }) end
    if close then return CP.L('block.search_area.hint_close') end
    if not d.entered then return CP.L('block.search_area.hud_enter') end
    local r = d.circle and math.floor(d.circle.r + 0.5) or 0
    -- a lost clue (the witness killed, a prop gone) counts as handled: only a pending one is left to check
    local pending = 0
    for _, cl in pairs(S.clues) do
        if cl.status == 'pending' then pending = pending + 1 end
    end
    if pending > 0 then
        return CP.L('block.search_area.hud_search', { checked = d.checked or 0, total = d.clueTotal or 0, radius = r })
    end
    return CP.L('block.search_area.hud_find', { done = d.neutralised or 0, total = d.total or 0, radius = r })
end

local function Loop(S)
    if S.looping then return end
    S.looping = true
    CreateThread(function()
        while S.alive do
            local fast = false
            if S.current then
                local ctx = S.ctx
                local gu = ctx.obj.givesUp or {}
                local myPos = GetEntityCoords(PlayerPedId())
                local host = IsHost(S)
                local close = false
                local c = S.data.circle
                local key = c and ('%d:%d'):format(c.n or 0, math.floor(c.r)) or nil
                if key ~= S.circleKey and not ctx.radioSilence then DrawCircle(S) end
                SyncClues(S)
                if host then
                    for _, cl in pairs(S.clues) do
                        if cl.kind == 'witness' and cl.netId then
                            local e = EntityFor(cl.netId)
                            if e and not IsPedDeadOrDying(e, true) then HostPed(S, cl.netId, e, 'idle', true) end
                        end
                    end
                end
                for _, f in ipairs(S.fugitives) do
                    local ent = EntityFor(f.netId)
                    local k = 'f' .. tostring(f.netId)
                    if ent then
                        local state = (BagOf(ent) or {}).state or f.state
                        if host and state ~= 'dead' then HostPed(S, f.netId, ent, state, false) end
                        -- HostPed waits for control (ctx.control yields): a stop meanwhile has already cleaned up
                        if not (S.alive and S.current) then break end
                        local d = #(GetEntityCoords(ent) - myPos)
                        if state == 'fleeing' or state == 'idle' then
                            if d <= WATCH_RANGE then
                                fast = true
                                if IsPedBeingStunned(ent, 0) then ReportOnce(S, 'stunned', f.netId) end
                            end
                            if state == 'fleeing' and type(gu.close) == 'table'
                                and d <= (tonumber(gu.close.distance) or 0) then
                                close = true
                            end
                        end
                        if not ctx.radioSilence and (state == 'fleeing' or state == 'surrendered') then
                            EnsureFugitiveBlip(S, f.netId, ent, state)
                        else
                            DropBlip(S, k)
                        end
                    else
                        DropBlip(S, k)
                    end
                end
                if S.alive and S.current then SetHint(S, HudText(S, close)) end
            end
            Wait(fast and FAST_MS or SLOW_MS)
        end
        S.looping = false
    end)
end

local function Cleanup(S)
    S.alive = false
    S.current = false
    -- a clue check still running would otherwise keep the player frozen in its progress bar
    if S.busy and lib.progressActive and lib.progressActive() then pcall(lib.cancelProgress) end
    for i in pairs(S.zones) do DropZone(S, i) end
    for k in pairs(S.blips) do DropBlip(S, k) end
    if S.hint then
        S.hint = nil
        S.ctx.hudDetail(nil)
    end
    active[S.key] = nil
end

CP.Blocks.register(BLOCK, {
    prepare = function(ctx)
        S_of(ctx)
    end,

    start = function(ctx)
        local S = S_of(ctx)
        S.alive = true
        S.current = true
        Loop(S)
        MarkerLoop(S)
    end,

    update = function(ctx, data)
        local S = S_of(ctx)
        if type(data) ~= 'table' or data.kind ~= 'state' then return end
        S.data = data
        local clues = {}
        for _, cl in ipairs(data.clues or {}) do clues[cl.i] = cl end
        for i, old in pairs(S.clues) do
            local new = clues[i]
            -- gone, or a different clue under the same number (test restart): drop its zone and blip
            if not new or new.x ~= old.x or new.y ~= old.y or new.z ~= old.z or new.netId ~= old.netId then
                DropZone(S, i)
                DropBlip(S, 'c' .. i)
            end
        end
        S.clues = clues
        S.fugitives = data.fugitives or {}
        local keep = {}
        for _, f in ipairs(S.fugitives) do keep['f' .. tostring(f.netId)] = true end
        for k in pairs(S.blips) do
            if k:sub(1, 1) == 'f' and not keep[k] then DropBlip(S, k) end
        end
    end,

    hostChanged = function(ctx, isHost)
        local S = S_of(ctx)
        S.isHost = isHost == true
        S.applied = {}
        S.tasked = {}
        S.lost = {}
    end,

    stop = function(ctx)
        local S = active[KeyOf(ctx)]
        if S then Cleanup(S) end
    end,
})

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, S in pairs(active) do Cleanup(S) end
end)
