-- Objective block "field_contact" (client half): blips for the contacts still open, and the aim and stun reports
-- that make a running person give up. Police actions are ox_target options of modules/npc (the cp bag).

local BLOCK = 'field_contact'
local U = CP.U

local FAST_MS = 250
local SLOW_MS = 1000
local WATCH_RANGE = 40.0
local AIM_RANGE = 10.0
local REPORT_MS = 1500

local active = {}

local function KeyOf(ctx) return tostring(ctx.runId) .. ':' .. tostring(ctx.index) end

local function S_of(ctx)
    local k = KeyOf(ctx)
    local S = active[k]
    if not S then
        S = { key = k, contacts = {}, blips = {}, lastReport = {}, alive = true }
        active[k] = S
    end
    S.ctx = ctx
    return S
end

local function EntityFor(netId)
    if not netId or not NetworkDoesNetworkIdExist(netId) then return nil end
    local e = NetworkGetEntityFromNetworkId(netId)
    if e and e ~= 0 and DoesEntityExist(e) then return e end
    return nil
end

local function BagOf(ent)
    local ok, v = pcall(function() return Entity(ent).state.cp end)
    if ok and type(v) == 'table' then return v end
    return nil
end

-- ============================================================================
--                                    BLIPS
-- ============================================================================

local function DropBlip(S, k)
    local b = S.blips[k]
    if not b then return end
    if DoesBlipExist(b.id) then RemoveBlip(b.id) end
    S.blips[k] = nil
end

local function EnsureBlip(S, info, ent)
    if not S.alive then return end
    local b = S.blips[info.netId]
    if b and b.ent == ent and DoesBlipExist(b.id) then return end
    DropBlip(S, info.netId)
    local id = AddBlipForEntity(ent)
    SetBlipSprite(id, info.kind == 'vehicle' and 225 or 1)
    SetBlipColour(id, 5)
    SetBlipScale(id, info.kind == 'vehicle' and 0.6 or 0.55)
    SetBlipAsShortRange(id, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(CP.L('block.field_contact.blip', { label = info.label }))
    EndTextCommandSetBlipName(id)
    S.blips[info.netId] = { id = id, ent = ent }
end

-- ============================================================================
--                               REPORTS AND LOOP
-- ============================================================================

local function ReportOnce(S, kind, netId)
    local k = kind .. ':' .. tostring(netId)
    local t = GetGameTimer()
    if S.lastReport[k] and t - S.lastReport[k] < REPORT_MS then return end
    S.lastReport[k] = t
    S.ctx.report({ type = kind, netId = netId })
end

local function Loop(S)
    if S.looping then return end
    S.looping = true
    CreateThread(function()
        while S.alive do
            local fast = false
            if S.current then
                local me = PlayerPedId()
                local pos = GetEntityCoords(me)
                for _, info in ipairs(S.contacts) do
                    local ent = EntityFor(info.netId)
                    if ent and not info.done then
                        if not S.ctx.radioSilence then EnsureBlip(S, info, ent) end
                        local bag = BagOf(ent)
                        local state = bag and bag.state
                        if info.kind == 'person' and (state == 'fleeing' or state == 'idle' or state == 'hostile') then
                            local d = U.dist(pos, GetEntityCoords(ent))
                            if d <= WATCH_RANGE then
                                fast = true
                                if IsPedBeingStunned(ent, 0) then ReportOnce(S, 'stunned', info.netId) end
                                if
                                    state ~= 'hostile'
                                    and d <= AIM_RANGE
                                    and (
                                        IsPlayerFreeAimingAtEntity(PlayerId(), ent)
                                        or IsPlayerTargettingEntity(PlayerId(), ent)
                                    )
                                then
                                    ReportOnce(S, 'aim', info.netId)
                                end
                            end
                        end
                    else
                        DropBlip(S, info.netId)
                    end
                end
                if S.escaping then
                    S.ctx.hudDetail(CP.L('block.field_contact.escaping', { seconds = S.escaping }))
                    S.hinted = true
                elseif S.hinted then
                    S.hinted = false
                    S.ctx.hudDetail(nil)
                end
            end
            Wait(fast and FAST_MS or SLOW_MS)
        end
        S.looping = false
    end)
end

local function Cleanup(S)
    S.alive = false
    S.current = false
    for k in pairs(S.blips) do DropBlip(S, k) end
    if S.hinted then S.ctx.hudDetail(nil) end
    active[S.key] = nil
end

CP.Blocks.register(BLOCK, {
    prepare = function(ctx) S_of(ctx) end,

    start = function(ctx)
        local S = S_of(ctx)
        S.alive = true
        S.current = true
        Loop(S)
    end,

    update = function(ctx, data)
        local S = S_of(ctx)
        if type(data) ~= 'table' then return end
        if type(data.contacts) == 'table' then
            local keep = {}
            for _, info in ipairs(data.contacts) do if not info.done then keep[info.netId] = true end end
            for k in pairs(S.blips) do if not keep[k] then DropBlip(S, k) end end
            S.contacts = data.contacts
        end
        S.escaping = data.escaping
    end,

    -- a car and its people handed over by a pursuit: nothing to set up here, the loop reads the new list
    adopt = function(ctx) S_of(ctx) end,
    release = function(ctx, netId)
        local S = active[KeyOf(ctx)]
        if S then DropBlip(S, netId) end
    end,

    hostChanged = function(ctx, isHost)
        local S = S_of(ctx)
        S.isHost = isHost == true
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
