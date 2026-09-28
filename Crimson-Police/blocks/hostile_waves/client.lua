--[[ blocks/hostile_waves/client.lua · objective block "hostile_waves" (client half)

  What it does
    While the objective is current on this participant's client:
    - blocks NPC traffic within obj.blockTraffic metres of location.start.coords, area-limited only
      (AddRoadNodeSpeedZone + SetRoadsInArea for that box + one ClearAreaOfVehicles in the radius),
      restored in stop (RemoveRoadNodeSpeedZone, SetRoadsBackToOriginal) (ARCHITECTURE §0.14);
    - red entity blips on hostiles that are not neutralised (none with Radio Silence);
    - a HUD line (ctx.hudDetail) when a surrendered hostile is close enough to cuff;
    - on the run host only: CP.Npc.apply + the task for the current cp state once the host has control
      of each hostile (again after hostChanged), and one 'low_health' report per hostile whose health
      drops under surrender.belowHealth (boss: boss.surrender.belowHealth).
    The "Cuff suspect" target itself is CP.Npc's (enableCuff). No networked entity is created here.

  Objective fields read: blockTraffic, behaviour, surrender.belowHealth / .chance,
    boss.label / boss.surrender (ctx.obj, scaled copy); location.start.coords.
  Evidence sent: { type = 'low_health', netId } (host only, once per hostile)
  Server data (update): { peds = { { netId, role, state, wave } }, wave, waves }
]]

local BLOCK = 'hostile_waves'
local U = CP.U

local LOOP_MS     = 500      -- AI / blip refresh while current
local HINT_RANGE  = 20.0     -- metres: "cuff them" hint for a surrendered hostile this close
local CONTROL_MS  = 250      -- control request timeout per hostile
local TRAFFIC_Z   = 100.0    -- half height of the SetRoadsInArea box

local active = {}            -- [runId:index] = S

local function keyOf(ctx) return tostring(ctx.runId) .. ':' .. tostring(ctx.index) end

local function S_of(ctx)
    local k = keyOf(ctx)
    local S = active[k]
    if not S then
        S = { key = k, peds = {}, blips = {}, applied = {}, reported = {}, alive = true }
        active[k] = S
    end
    S.ctx = ctx
    return S
end

local function isHost(S)
    if S.isHost ~= nil then return S.isHost end
    return S.ctx.isHost == true
end

local function pedFor(netId)
    if not netId or not NetworkDoesNetworkIdExist(netId) then return nil end
    local e = NetworkGetEntityFromNetworkId(netId)
    if e and e ~= 0 and DoesEntityExist(e) then return e end
    return nil
end

local function bagOf(ent)
    local st = Entity(ent).state
    return st and st.cp or nil
end

-- ── Traffic (area-limited, restored on stop) ────────────────────────────────
local function blockTraffic(S)
    if S.traffic then return end
    local ctx = S.ctx
    local r = tonumber(ctx.obj.blockTraffic) or 0
    local c = ctx.location and ctx.location.start and ctx.location.start.coords
    local x, y, z = U.xyz(c)
    if r <= 0 or not x then return end
    local t = { x1 = x - r, y1 = y - r, z1 = z - TRAFFIC_Z, x2 = x + r, y2 = y + r, z2 = z + TRAFFIC_Z }
    t.zone = AddRoadNodeSpeedZone(x + 0.0, y + 0.0, z + 0.0, r + 0.0, 0.0, false)
    SetRoadsInArea(t.x1, t.y1, t.z1, t.x2, t.y2, t.z2, false, false)
    ClearAreaOfVehicles(x + 0.0, y + 0.0, z + 0.0, r + 0.0, false, false, false, false, false, false, 0)
    S.traffic = t
end

local function restoreTraffic(S)
    local t = S.traffic
    if not t then return end
    S.traffic = nil
    if t.zone then RemoveRoadNodeSpeedZone(t.zone) end
    SetRoadsBackToOriginal(t.x1, t.y1, t.z1, t.x2, t.y2, t.z2, false)
end

-- ── Blips ───────────────────────────────────────────────────────────────────
local function removeBlip(S, netId)
    local b = S.blips[netId]
    if not b then return end
    if DoesBlipExist(b.id) then RemoveBlip(b.id) end
    S.blips[netId] = nil
end

local function ensureBlip(S, netId, ent, boss)
    local b = S.blips[netId]
    if b and b.ent == ent and DoesBlipExist(b.id) then return end
    removeBlip(S, netId)
    local id = AddBlipForEntity(ent)
    SetBlipSprite(id, 1)
    SetBlipColour(id, 1)
    SetBlipScale(id, boss and 0.9 or 0.6)
    SetBlipAsShortRange(id, true)
    BeginTextCommandSetBlipName('STRING')
    local label = CP.L('block.hostile_waves.blip_hostile')
    if boss then label = (S.ctx.obj.boss and S.ctx.obj.boss.label) or CP.L('block.hostile_waves.boss_label') end
    AddTextComponentSubstringPlayerName(label)
    EndTextCommandSetBlipName(id)
    S.blips[netId] = { id = id, ent = ent }
end

local function setHint(S, text)
    if S.hint == text then return end
    S.hint = text
    S.ctx.hudDetail(text)
end

-- ── Host AI ─────────────────────────────────────────────────────────────────
local function healthRatio(ent)
    local hp = GetEntityHealth(ent)
    local max = GetEntityMaxHealth(ent)
    if hp <= 0 then return nil end
    if max > 100 then return (hp - 100) / (max - 100) end
    return hp / math.max(max, 1)
end

local function hostAi(S, info, ent, state, bag)
    local ctx = S.ctx
    if S.applied[info.netId] ~= ent then
        if not ctx.control(ent, CONTROL_MS) then return end
        local cfg = (bag and bag.cfg) or {}
        CP.Npc.apply(ent, cfg)
        S.applied[info.netId] = ent
        -- first sight or new host: task for the current state (later changes: CP.Npc's bag handler)
        if state == 'hostile' then
            CP.Npc.task(ent, 'combat', { behaviour = cfg.behaviour or ctx.obj.behaviour })
        elseif state == 'surrendered' then
            CP.Npc.task(ent, 'kneel', {})
        elseif state == 'cuffed' then
            CP.Npc.task(ent, 'cuffed', {})
        end
    end
    if state == 'hostile' and not S.reported[info.netId] then
        local s = ctx.obj.surrender or {}
        if info.role == 'boss' and type(ctx.obj.boss) == 'table' and type(ctx.obj.boss.surrender) == 'table' then
            s = ctx.obj.boss.surrender
        end
        if (tonumber(s.chance) or 0) > 0 then
            local ratio = healthRatio(ent)
            if ratio and ratio > 0 and ratio < (tonumber(s.belowHealth) or 0) then
                S.reported[info.netId] = true
                ctx.report({ type = 'low_health', netId = info.netId })
            end
        end
    end
end

local function loop(S)
    if S.looping then return end
    S.looping = true
    CreateThread(function()
        while S.alive do
            if S.current then
                local ctx = S.ctx
                local me = GetEntityCoords(PlayerPedId())
                local hint = false
                for _, info in ipairs(S.peds) do
                    local ent = pedFor(info.netId)
                    if ent then
                        local bag = bagOf(ent)
                        local state = (bag and bag.state) or info.state
                        if isHost(S) then hostAi(S, info, ent, state, bag) end
                        if state == 'hostile' or state == 'surrendered' then
                            if not ctx.radioSilence then ensureBlip(S, info.netId, ent, info.role == 'boss') end
                            if state == 'surrendered' and U.dist(me, GetEntityCoords(ent)) <= HINT_RANGE then hint = true end
                        else
                            removeBlip(S, info.netId)
                        end
                    else
                        removeBlip(S, info.netId)
                    end
                end
                setHint(S, hint and CP.L('block.hostile_waves.hint_cuff') or nil)
            end
            Wait(LOOP_MS)
        end
        S.looping = false
    end)
end

local function cleanup(S)
    S.alive = false
    S.current = false
    for netId in pairs(S.blips) do removeBlip(S, netId) end
    restoreTraffic(S)
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
        blockTraffic(S)
        loop(S)
    end,

    update = function(ctx, data)
        local S = S_of(ctx)
        if type(data) ~= 'table' or type(data.peds) ~= 'table' then return end
        local keep = {}
        for _, info in ipairs(data.peds) do keep[info.netId] = true end
        for netId in pairs(S.blips) do
            if not keep[netId] then removeBlip(S, netId) end
        end
        S.peds = data.peds
    end,

    hostChanged = function(ctx, isHost)
        local S = S_of(ctx)
        S.isHost = isHost == true
        S.applied = {}
        S.reported = {}
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
