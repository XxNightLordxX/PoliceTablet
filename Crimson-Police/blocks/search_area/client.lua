--[[ blocks/search_area/client.lua · objective block "search_area" (client half)

  What it does (while the objective is current on this participant's client)
    - the search circle as a radius blip with a centre blip, redrawn whenever the server shrinks it;
      blips for clues not yet checked and for fugitives on the run (none of these with Radio Silence);
    - an ox_target sphere zone on every clue not yet checked (option crimson-police:check_clue, label by
      clue kind); selecting it reports 'clue_start', runs lib.progressBar(clueProgress) and reports
      'clue'; a marker over each clue not yet checked (DrawMarker only within MARKER_RANGE, otherwise
      Wait(750));
    - 'stunned' reports for fugitives seen stunned (IsPedBeingStunned); the server re-checks distances;
    - a HUD line (ctx.hudDetail): enter the area, clues checked and circle size, escape countdown, and
      "stay close" while this player is within givesUp.close.distance of a fugitive on the run;
    - on the run host only: CP.Npc.apply once it has control of each fugitive and the witness, then
      the task for its cp state: idle (hiding) -> 'cower', fleeing -> 'flee', and on first sight (new
      host) surrendered -> 'kneel', cuffed -> 'cuffed'; the witness stands at its spot
      (TaskStartScenarioInPlace). The "Cuff suspect" target is CP.Npc's (enableCuff).

  Objective fields read: clueProgress.label / duration, givesUp.close, runDistance (ctx.obj).
  Evidence sent: { type = 'clue_start', clue }, { type = 'clue', clue }, { type = 'stunned', netId }
  Server data (update): { kind = 'state', circle = { x, y, z, r, n }, clues = { { i, x, y, z, kind, model,
    netId, status } }, fugitives = { { netId, state } }, checked, clueTotal, arrests, neutralised, total,
    entered, escaping }
]]

local BLOCK = 'search_area'
local U = CP.U

local OPTION       = 'crimson-police:check_clue'
local FAST_MS      = 250
local SLOW_MS      = 1000
local WATCH_RANGE  = 40.0
local REPORT_MS    = 1500
local CONTROL_MS   = 250
local MARKER_RANGE = 150.0
local CLUE_RANGE   = 2.5
local SEARCH_ANIM  = { dict = 'amb@prop_human_bum_bin@idle_b', clip = 'idle_d' }
local TALK_ANIM    = { dict = 'missfbi3_party_d', clip = 'stand_talk_loop_a_male1' }
local WITNESS_SCENARIO = 'WORLD_HUMAN_STAND_MOBILE'

local active = {}

local function keyOf(ctx) return tostring(ctx.runId) .. ':' .. tostring(ctx.index) end

local function S_of(ctx)
    local k = keyOf(ctx)
    local S = active[k]
    if not S then
        S = { key = k, data = {}, clues = {}, fugitives = {}, zones = {}, blips = {}, applied = {}, tasked = {},
            lastReport = {}, alive = true }
        active[k] = S
    end
    S.ctx = ctx
    return S
end

local function isHost(S)
    if S.isHost ~= nil then return S.isHost end
    return S.ctx.isHost == true
end

local function entityFor(netId)
    if not netId or not NetworkDoesNetworkIdExist(netId) then return nil end
    local e = NetworkGetEntityFromNetworkId(netId)
    if e and e ~= 0 and DoesEntityExist(e) then return e end
    return nil
end

local function bagOf(ent)
    local st = Entity(ent).state
    return st and st.cp or nil
end

local function clueVec(cl) return vector3(cl.x + 0.0, cl.y + 0.0, cl.z + 0.0) end

local function clueLabel(cl)
    if cl.kind == 'witness' then return CP.L('block.search_area.target_witness') end
    local model = tostring(cl.model or '')
    if model:find('bag') then return CP.L('block.search_area.target_bag') end
    if model:find('phone') then return CP.L('block.search_area.target_phone') end
    return CP.L('block.search_area.target_clue')
end

-- ── Blips ───────────────────────────────────────────────────────────────────
local function dropBlip(S, k)
    local b = S.blips[k]
    if not b then return end
    if DoesBlipExist(b.id) then RemoveBlip(b.id) end
    S.blips[k] = nil
end

local function nameBlip(id, label)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(label)
    EndTextCommandSetBlipName(id)
end

local function drawCircle(S)
    local c = S.data.circle
    dropBlip(S, 'circle')
    dropBlip(S, 'center')
    S.circleKey = nil
    if not c or S.ctx.radioSilence then return end
    local area = AddBlipForRadius(c.x + 0.0, c.y + 0.0, c.z + 0.0, c.r + 0.0)
    SetBlipColour(area, 1)
    SetBlipAlpha(area, 90)
    S.blips.circle = { id = area }
    local mid = AddBlipForCoord(c.x + 0.0, c.y + 0.0, c.z + 0.0)
    SetBlipSprite(mid, 1)
    SetBlipColour(mid, 1)
    SetBlipScale(mid, 0.6)
    nameBlip(mid, CP.L('block.search_area.blip_area', { radius = math.floor(c.r + 0.5) }))
    S.blips.center = { id = mid }
    S.circleKey = ('%d:%d'):format(c.n or 0, math.floor(c.r))
end

local function ensureCoordBlip(S, k, v, label)
    if S.blips[k] then return end
    local id = AddBlipForCoord(v.x, v.y, v.z)
    SetBlipSprite(id, 1)
    SetBlipColour(id, 5)
    SetBlipScale(id, 0.6)
    SetBlipAsShortRange(id, true)
    nameBlip(id, label)
    S.blips[k] = { id = id }
end

local function ensureEntityBlip(S, k, ent, label)
    local b = S.blips[k]
    if b and b.ent == ent and DoesBlipExist(b.id) then return end
    dropBlip(S, k)
    local id = AddBlipForEntity(ent)
    SetBlipSprite(id, 1)
    SetBlipColour(id, 1)
    SetBlipScale(id, 0.7)
    nameBlip(id, label)
    S.blips[k] = { id = id, ent = ent }
end

-- ── Clues ───────────────────────────────────────────────────────────────────
local function checkClue(S, cl)
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

local function dropZone(S, i)
    local id = S.zones[i]
    if not id then return end
    S.zones[i] = nil
    pcall(function() exports.ox_target:removeZone(id) end)
end

local function ensureZone(S, cl)
    if S.zones[cl.i] then return end
    S.zones[cl.i] = exports.ox_target:addSphereZone({
        coords = clueVec(cl),
        radius = 1.2,
        debug = false,
        name = 'crimson-police:clue:' .. S.key .. ':' .. tostring(cl.i),
        options = { {
            name = OPTION,
            label = clueLabel(cl),
            icon = cl.kind == 'witness' and 'fas fa-comments' or 'fas fa-magnifying-glass',
            distance = CLUE_RANGE,
            canInteract = function()
                local now = S.clues[cl.i]
                return S.alive and S.current and not S.busy and now ~= nil and now.status == 'pending'
            end,
            onSelect = function() CreateThread(function() checkClue(S, S.clues[cl.i] or cl) end) end,
        } },
    })
end

local function syncClues(S)
    for i, cl in pairs(S.clues) do
        if cl.status == 'pending' and S.current then
            ensureZone(S, cl)
            if not S.ctx.radioSilence then
                ensureCoordBlip(S, 'c' .. i, clueVec(cl), CP.L('block.search_area.blip_clue'))
            end
        else
            dropZone(S, i)
            dropBlip(S, 'c' .. i)
        end
    end
end

local function markerLoop(S)
    if S.drawing then return end
    S.drawing = true
    CreateThread(function()
        while S.alive and S.current do
            local pos = GetEntityCoords(PlayerPedId())
            local drew = false
            for _, cl in pairs(S.clues) do
                if cl.status == 'pending' then
                    local v = clueVec(cl)
                    if #(pos - v) <= MARKER_RANGE then
                        DrawMarker(2, v.x, v.y, v.z + 1.0, 0.0, 0.0, 0.0, 180.0, 0.0, 0.0,
                            0.3, 0.3, 0.3, 240, 200, 40, 180, true, true, 2, false, nil, nil, false)
                        drew = true
                    end
                end
            end
            Wait(drew and 0 or 750)
        end
        S.drawing = false
    end)
end

-- ── Host AI and reports ─────────────────────────────────────────────────────
local function hostPed(S, net, ent, state, witness)
    local fresh = false
    if S.applied[net] ~= ent then
        if not S.ctx.control(ent, CONTROL_MS) then return end
        local bag = bagOf(ent)
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

local function reportOnce(S, kind, netId)
    local k = kind .. ':' .. tostring(netId)
    local t = GetGameTimer()
    local last = S.lastReport[k]
    if last and t - last < REPORT_MS then return end
    S.lastReport[k] = t
    S.ctx.report({ type = kind, netId = netId })
end

local function setHint(S, text)
    if S.hint == text then return end
    S.hint = text
    S.ctx.hudDetail(text)
end

local function hudText(S, close)
    local d = S.data
    if d.escaping then return CP.L('block.search_area.hud_escaping', { seconds = d.escaping }) end
    if close then return CP.L('block.search_area.hint_close') end
    if not d.entered then return CP.L('block.search_area.hud_enter') end
    local r = d.circle and math.floor(d.circle.r + 0.5) or 0
    if (d.checked or 0) < (d.clueTotal or 0) then
        return CP.L('block.search_area.hud_search', { checked = d.checked or 0, total = d.clueTotal or 0, radius = r })
    end
    return CP.L('block.search_area.hud_find', { done = d.neutralised or 0, total = d.total or 0, radius = r })
end

local function loop(S)
    if S.looping then return end
    S.looping = true
    CreateThread(function()
        while S.alive do
            local fast = false
            if S.current then
                local ctx = S.ctx
                local gu = ctx.obj.givesUp or {}
                local myPos = GetEntityCoords(PlayerPedId())
                local host = isHost(S)
                local close = false
                local c = S.data.circle
                local key = c and ('%d:%d'):format(c.n or 0, math.floor(c.r)) or nil
                if key ~= S.circleKey and not ctx.radioSilence then drawCircle(S) end
                syncClues(S)
                if host then
                    for _, cl in pairs(S.clues) do
                        if cl.kind == 'witness' and cl.netId then
                            local e = entityFor(cl.netId)
                            if e and not IsPedDeadOrDying(e, true) then hostPed(S, cl.netId, e, 'idle', true) end
                        end
                    end
                end
                for _, f in ipairs(S.fugitives) do
                    local ent = entityFor(f.netId)
                    local k = 'f' .. tostring(f.netId)
                    if ent then
                        local state = (bagOf(ent) or {}).state or f.state
                        if host and state ~= 'dead' then hostPed(S, f.netId, ent, state, false) end
                        local d = #(GetEntityCoords(ent) - myPos)
                        if state == 'fleeing' or state == 'idle' then
                            if d <= WATCH_RANGE then
                                fast = true
                                if IsPedBeingStunned(ent, 0) then reportOnce(S, 'stunned', f.netId) end
                            end
                            if state == 'fleeing' and type(gu.close) == 'table' and d <= (tonumber(gu.close.distance) or 0) then
                                close = true
                            end
                        end
                        if not ctx.radioSilence and (state == 'fleeing' or state == 'surrendered') then
                            ensureEntityBlip(S, k, ent, CP.L('block.search_area.blip_fugitive'))
                        else
                            dropBlip(S, k)
                        end
                    else
                        dropBlip(S, k)
                    end
                end
                setHint(S, hudText(S, close))
            end
            Wait(fast and FAST_MS or SLOW_MS)
        end
        S.looping = false
    end)
end

local function cleanup(S)
    S.alive = false
    S.current = false
    for i in pairs(S.zones) do dropZone(S, i) end
    for k in pairs(S.blips) do dropBlip(S, k) end
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
        loop(S)
        markerLoop(S)
    end,

    update = function(ctx, data)
        local S = S_of(ctx)
        if type(data) ~= 'table' or data.kind ~= 'state' then return end
        S.data = data
        local clues = {}
        for _, cl in ipairs(data.clues or {}) do clues[cl.i] = cl end
        for i in pairs(S.clues) do
            if not clues[i] then
                dropZone(S, i)
                dropBlip(S, 'c' .. i)
            end
        end
        S.clues = clues
        S.fugitives = data.fugitives or {}
        local keep = {}
        for _, f in ipairs(S.fugitives) do keep['f' .. tostring(f.netId)] = true end
        for k in pairs(S.blips) do
            if k:sub(1, 1) == 'f' and not keep[k] then dropBlip(S, k) end
        end
    end,

    hostChanged = function(ctx, isHost)
        local S = S_of(ctx)
        S.isHost = isHost == true
        S.applied = {}
        S.tasked = {}
    end,

    stop = function(ctx)
        local S = active[keyOf(ctx)]
        if S then cleanup(S) end
    end,
})

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, S in pairs(active) do cleanup(S) end
end)
