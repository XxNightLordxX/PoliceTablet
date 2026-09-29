--[[ blocks/hostile_waves/client.lua · objective block "hostile_waves" (client half)

  What it does
    While the objective is current on this participant's client:
    - blocks NPC traffic within obj.blockTraffic metres of location.start.coords, area-limited only
      (AddRoadNodeSpeedZone + SetRoadsInArea for that box + one ClearAreaOfVehicles in the radius)
      (ARCHITECTURE §0.14). It is restored (RemoveRoadNodeSpeedZone, SetRoadsBackToOriginal) when the
      objective stops only if no later objective of the run follows; otherwise the block is held for the
      rest of the run (every objective of a run shares its location: Gang Shootout / Kingpin "Secure the
      scene", "NPC traffic is blocked within 120 m while the run is active") and restored as soon as
      CP.Runs.current() is no longer that run (run end, silent removal) or on resource stop. A later
      hostile_waves objective with the same area takes the held block over instead of adding a second;
    - red entity blips on hostiles that are not neutralised (none with Radio Silence);
    - a HUD line (ctx.hudDetail) when a surrendered hostile is close enough to cuff;
    - on the run host only: CP.Npc.apply + the task for the current cp state once the host has control
      of each hostile (again after hostChanged; retried until CP.Npc took both), and one 'low_health'
      report per hostile whose health drops under surrender.belowHealth (boss: boss.surrender.belowHealth;
      the server also polls health itself, the report only makes the roll come sooner).
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
local HOLD_POLL_MS = 500     -- how often a held traffic block checks that its run is still going

local active = {}            -- [runId:index] = S
local held = {}              -- [runId] = { traffic, ... } kept after the objective stopped (later objectives)
local watching = {}          -- [runId] = true while a thread waits for that run to end

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

-- ── Traffic (area-limited; held while later objectives of the run follow) ───
local function restoreArea(t)
    if t.zone then RemoveRoadNodeSpeedZone(t.zone) end
    SetRoadsBackToOriginal(t.x1, t.y1, t.z1, t.x2, t.y2, t.z2, false)
end

local function currentRun(runId)
    local run = CP.Runs and CP.Runs.current and CP.Runs.current() or nil
    if type(run) == 'table' and run.id == runId then return run end
    return nil
end

-- True while the run of ctx is this client's current run and has an objective after ctx.index.
local function laterObjectives(ctx)
    local run = currentRun(ctx.runId)
    if not run then return false end
    local n = type(run.objectives) == 'table' and #run.objectives or 0
    if n == 0 and type(run.mission) == 'table' and type(run.mission.objectives) == 'table' then
        n = #run.mission.objectives
    end
    return (tonumber(ctx.index) or 0) < n
end

local function releaseHeld(runId)
    local list = held[runId]
    held[runId] = nil
    for _, t in ipairs(list or {}) do restoreArea(t) end
end

local function holdTraffic(S)
    local t, runId = S.traffic, S.ctx.runId
    S.traffic = nil
    held[runId] = held[runId] or {}
    table.insert(held[runId], t)
    if watching[runId] then return end
    watching[runId] = true
    CreateThread(function()
        while held[runId] and currentRun(runId) do Wait(HOLD_POLL_MS) end
        watching[runId] = nil
        releaseHeld(runId)
    end)
end

local function blockTraffic(S)
    if S.traffic then return end
    local ctx = S.ctx
    local r = tonumber(ctx.obj.blockTraffic) or 0
    local c = ctx.location and ctx.location.start and ctx.location.start.coords
    local x, y, z = U.xyz(c)
    if r <= 0 or not x then return end
    -- an earlier objective of this run still holds the same block: take it over
    local list = held[ctx.runId]
    for i, h in ipairs(list or {}) do
        if h.cx == x and h.cy == y and h.cz == z and h.r == r then
            table.remove(list, i)
            if #list == 0 then held[ctx.runId] = nil end
            S.traffic = h
            return
        end
    end
    local t = { x1 = x - r, y1 = y - r, z1 = z - TRAFFIC_Z, x2 = x + r, y2 = y + r, z2 = z + TRAFFIC_Z,
        cx = x, cy = y, cz = z, r = r }
    t.zone = AddRoadNodeSpeedZone(x + 0.0, y + 0.0, z + 0.0, r + 0.0, 0.0, false)
    SetRoadsInArea(t.x1, t.y1, t.z1, t.x2, t.y2, t.z2, false, false)
    ClearAreaOfVehicles(x + 0.0, y + 0.0, z + 0.0, r + 0.0, false, false, false, false, false, false, 0)
    S.traffic = t
end

local function restoreTraffic(S)
    local t = S.traffic
    if not t then return end
    S.traffic = nil
    restoreArea(t)
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

-- The host must own the ped before CP.Npc.apply / CP.Npc.task do anything (OneSync hands ownership
-- to whoever is closest, often another participant): request it every time it is needed.
local function hasControl(ctx, ent)
    if NetworkHasControlOfEntity(ent) then return true end
    return ctx.control(ent, CONTROL_MS) == true
end

local FIRST_TASK = { hostile = 'combat', surrendered = 'kneel', cuffed = 'cuffed' }

local function hostAi(S, info, ent, state, bag)
    local ctx = S.ctx
    if S.applied[info.netId] ~= ent then
        if not hasControl(ctx, ent) then return end
        local cfg = (bag and bag.cfg) or {}
        if CP.Npc.apply(ent, cfg) == false then return end
        -- first sight or new host: task for the current state (later changes: CP.Npc's bag handler).
        -- Only a task that went through marks the ped as handled; otherwise the next loop retries.
        local action = FIRST_TASK[state]
        if action then
            local args = action == 'combat' and { behaviour = cfg.behaviour or ctx.obj.behaviour } or {}
            if CP.Npc.task(ent, action, args) == false then return end
        end
        S.applied[info.netId] = ent
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
        if not S then return end
        -- the objective is done but the run goes on at the same location: keep NPC traffic out
        if S.traffic and laterObjectives(ctx) then holdTraffic(S) end
        cleanup(S)
    end,
})

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, S in pairs(active) do cleanup(S) end
    for _, runId in ipairs(U.keys(held)) do releaseHeld(runId) end
end)
