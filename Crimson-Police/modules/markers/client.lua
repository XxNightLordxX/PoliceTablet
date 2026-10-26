-- CP.Markers (client): the current objective on this officer's map, one pointer (a blip, or a circle with its centre)
-- and at most one GPS line to it, cleared at every objective stop and run end (docs/ARCHITECTURE.md §5.44).

CP.Markers = CP.Markers or {}
local M = CP.Markers
local TAG = 'markers'

local TICK_MS = 1000                -- how often the pointer is checked: streaming, nearest target, line on or off
local SWITCH_SHARE = 0.75           -- the line moves to another target only when that one is 25 % closer
local POINTER_PRIORITY = 12         -- drawn above the missions' detail blips
local LAST_KNOWN_RADIUS = 200.0     -- metres: Radio Silence's last-known circle round a moving target
local MAX_TARGETS = 32
local DEFAULT_LOOK = { sprite = 162, colour = 5, scale = 0.9 } -- kinds.objective as shipped
local KINDS = { point = true, area = true, targets = true }
local MODES = { none = true, area = true, full = true }
-- What Radio Silence 'area' still shows: circles and single points, never a GPS line or a person's or car's blip.
local SILENT_SHOWS = {
    start = true,
    checkpoint = true,
    searchArea = true,
    fightArea = true,
    destination = true,
    safePoint = true,
    scene = true,
    point = true,
    device = true,
    objective = true,
    prisonerVan = true,
    towTruck = true,
}
-- What every mode shows: the drive to the start and the service vehicles coming to the officer.
local ALWAYS_SHOWN = { start = true, prisonerVan = true, towTruck = true }
local SERVICE_LABELS = { prisonerVan = 'markers.prisoner_van', towTruck = 'markers.tow_truck' }
local FIELDS = { 'adoptKey', 'look', 'variant', 'label', 'number', 'coords', 'radius', 'netId', 'moving' }

local cur = nil         -- { runId, index, ctx, routeMode = 'on'|'off'|'block', elements = { [id] = el }, order }
local adopted = {}      -- [key] = a block's own blip it handed over (M.adopt)
local services = {}     -- [key] = el: a prisoner van or tow truck (M.service)
local routeBlip = nil   -- the only blip with SetBlipRoute(true)
local routeColour = nil -- the line colour routeBlip got
local loopOn = false

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function Cfg() return type(Config.Markers) == 'table' and Config.Markers or {} end

local function Int(v)
    local n = tonumber(v)
    return n and math.tointeger(n) or nil
end

local function Text(v)
    if type(v) == 'string' and v ~= '' then return v end
    return nil
end

local function Key(k)
    if type(k) == 'number' then
        local i = math.tointeger(k)
        return i and tostring(i) or tostring(k)
    end
    return Text(k)
end

local function Coords(v)
    local t = type(v)
    if t ~= 'vector3' and t ~= 'vector4' and t ~= 'table' then return nil end
    local x = tonumber(v.x or (t == 'table' and v[1] or nil))
    local y = tonumber(v.y or (t == 'table' and v[2] or nil))
    if not x or not y then return nil end
    local z = tonumber(v.z or (t == 'table' and v[3] or nil)) or 0.0
    return { x = x + 0.0, y = y + 0.0, z = z + 0.0 }
end

local function Seconds(key, default)
    local n = tonumber(Cfg()[key])
    if not n then return default end
    return math.max(0, n)
end

local function AreaAlpha() return CP.U.clamp(Int(Cfg().areaAlpha) or 80, 0, 255) end

local function NameBlip(blip, label)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(label)
    EndTextCommandSetBlipName(blip)
end

-- sprite, colour and scale of a Config.Markers.kinds entry; variant picks bossScale, nextScale, followUpColour or
-- setbackColour when the kind has one.
local function Look(kind, variant)
    local kinds = type(Cfg().kinds) == 'table' and Cfg().kinds or {}
    local k = kinds[kind]
    if type(k) ~= 'table' then k = type(kinds.objective) == 'table' and kinds.objective or DEFAULT_LOOK end
    local sprite = Int(k.sprite) or DEFAULT_LOOK.sprite
    local colour = Int(k.colour) or DEFAULT_LOOK.colour
    local scale = tonumber(k.scale) or DEFAULT_LOOK.scale
    if variant == 'boss' and tonumber(k.bossScale) then scale = tonumber(k.bossScale) end
    if variant == 'next' and tonumber(k.nextScale) then scale = tonumber(k.nextScale) end
    if variant == 'followUp' and Int(k.followUpColour) then colour = Int(k.followUpColour) end
    if variant == 'setback' and Int(k.setbackColour) then colour = Int(k.setbackColour) end
    return sprite, colour, scale + 0.0
end

local function Exists(blip) return blip ~= nil and blip ~= 0 and DoesBlipExist(blip) end

local function Streamed(netId)
    if not netId or not NetworkDoesNetworkIdExist(netId) then return nil end
    local ent = NetworkGetEntityFromNetworkId(netId)
    if ent and ent ~= 0 and DoesEntityExist(ent) then return ent end
    return nil
end

local function MyPos() return GetEntityCoords(PlayerPedId()) end

local function Silent(ctx)
    if type(ctx) ~= 'table' then ctx = cur and cur.ctx end
    return type(ctx) == 'table' and ctx.radioSilence == true
end

local function Mode()
    local m = Cfg().radioSilence
    return MODES[m] and m or 'area'
end

-- ============================================================================
--                                   THE LINE
-- ============================================================================

local function RouteOff()
    if Exists(routeBlip) then SetBlipRoute(routeBlip, false) end
    routeBlip, routeColour = nil, nil
end

local function RouteOn(blip)
    local colour = CP.U.clamp(Int(Cfg().routeColour) or 5, 0, 85)
    if routeBlip ~= blip then
        RouteOff()
        SetBlipRoute(blip, true)
        routeBlip = blip
    end
    if routeColour ~= colour then
        SetBlipRouteColour(blip, colour)
        routeColour = colour
    end
end

-- Every blip leaves through here: its line goes off first (BLIPS_FINAL R10).
local function Remove(blip)
    if not blip then return end
    if blip == routeBlip then RouteOff() end
    if Exists(blip) then RemoveBlip(blip) end
end

-- ============================================================================
--                                   ELEMENTS
-- ============================================================================
-- One thing the pointer shows: a point, an area's centre (with its circle) or a target.
-- el = { id, adoptKey, look, variant, label, number, coords, radius, netId, moving, service,
--        own (our blip), ownEnt (its entity; nil = a coord blip), at (coords it was put at), circle, circleKey,
--        known, knownAt (Radio Silence's last-known circle), shown (the pointer blip now), emphasised, flashed }

local function DropOwn(el)
    Remove(el.own)
    el.own, el.ownEnt, el.at = nil, nil, nil
end

local function DropCircle(el)
    Remove(el.circle)
    el.circle, el.circleKey = nil, nil
end

local function DropKnown(el)
    Remove(el.known)
    el.known, el.knownAt = nil, nil
end

local function Drop(el)
    DropOwn(el)
    DropCircle(el)
    DropKnown(el)
    if el.shown == routeBlip then RouteOff() end
    el.shown = nil
end

local function LabelOf(el)
    return el.label or (el.service and SERVICE_LABELS[el.look] and CP.L(SERVICE_LABELS[el.look]))
        or CP.L('markers.objective')
end

-- A new pointer blip: above the detail blips, flashing once (SET_BLIP_FLASH_TIMER, BLIPS_FINAL R5).
local function Emphasise(el, blip)
    if el.service or el.emphasised == blip then return end
    el.emphasised = blip
    SetBlipPriority(blip, POINTER_PRIORITY)
    if el.flashed then return end
    el.flashed = true
    local s = Seconds('flashSeconds', 5)
    if s > 0 then
        SetBlipFlashes(blip, true)
        SetBlipFlashTimer(blip, math.floor(s * 1000))
    end
end

local function EnsureCircle(el)
    if not el.radius then return DropCircle(el) end
    local c = el.coords
    local key = ('%.1f:%.1f:%.1f:%s'):format(c.x, c.y, el.radius, tostring(el.look))
    if el.circleKey == key and Exists(el.circle) then return end
    DropCircle(el)
    local _, colour = Look(el.look, el.variant)
    local blip = AddBlipForRadius(c.x, c.y, c.z, el.radius + 0.0)
    if not blip or blip == 0 then return end
    SetBlipColour(blip, colour)
    SetBlipAlpha(blip, AreaAlpha())
    el.circle, el.circleKey = blip, key
end

-- Radio Silence 'area' with radioSilenceLastKnown > 0: a circle round where a moving target was, moved this often.
local function LastKnown(el, on)
    if not on then return DropKnown(el) end
    local ent = el.netId and Streamed(el.netId)
    local pos = ent and Coords(GetEntityCoords(ent)) or el.coords
    if not pos then return DropKnown(el) end
    local now = GetGameTimer()
    if Exists(el.known) then
        if now - (el.knownAt or 0) >= Seconds('radioSilenceLastKnown', 0) * 1000 then
            SetBlipCoords(el.known, pos.x, pos.y, pos.z)
            el.knownAt = now
        end
        return
    end
    local _, colour = Look(el.look, el.variant)
    local blip = AddBlipForRadius(pos.x, pos.y, pos.z, LAST_KNOWN_RADIUS)
    if not blip or blip == 0 then return end
    SetBlipColour(blip, colour)
    SetBlipAlpha(blip, AreaAlpha())
    NameBlip(blip, CP.L('markers.last_known'))
    el.known, el.knownAt = blip, now
end

-- What this element shows now: the block's own blip when it handed one over, else our blip on the entity while this
-- game streams it, else our blip at the server's position (BLIPS_FINAL R1, R7).
local function Place(el)
    local cfg = Cfg()
    local hide
    if el.service then
        hide = cfg.serviceVehicles == false
    else
        -- Radio Silence 'area' puts no blip on a person or a car: a target followed by its net id is hidden whatever
        -- its look (a target without one gets 'objective'), so it shows only the optional last-known circle
        hide = cfg.enabled == false or M.hidden(cur and cur.ctx, el.look)
            or (el.netId ~= nil and not ALWAYS_SHOWN[el.look] and Silent() and Mode() == 'area')
    end
    local lastKnown = not el.service and el.moving and hide and cfg.enabled ~= false and Silent() and Mode() == 'area'
        and Seconds('radioSilenceLastKnown', 0) > 0
    LastKnown(el, lastKnown)
    if hide then
        DropOwn(el)
        DropCircle(el)
        if el.shown == routeBlip then RouteOff() end
        el.shown = nil
        return
    end
    local a = not el.service and el.adoptKey and adopted[el.adoptKey] or nil
    if a and not Exists(a) then
        adopted[el.adoptKey] = nil
        a = nil
    end
    if a then
        -- the block draws this target (and an area's circle) itself
        DropOwn(el)
        DropCircle(el)
        el.shown = a
        return Emphasise(el, a)
    end
    local ent = el.netId and Streamed(el.netId)
    if ent then
        if not (el.ownEnt == ent and Exists(el.own)) then
            DropOwn(el)
            el.own, el.ownEnt = AddBlipForEntity(ent), ent
            M.style(el.own, el.look, LabelOf(el), el)
        end
    elseif el.coords and (not el.netId or cfg.farTargets ~= false) then
        local c = el.coords
        if el.ownEnt == nil and Exists(el.own) then
            if el.at ~= c then SetBlipCoords(el.own, c.x, c.y, c.z) end
        else
            DropOwn(el)
            el.own = AddBlipForCoord(c.x, c.y, c.z)
            M.style(el.own, el.look, LabelOf(el), el)
        end
        el.at = c
    else
        DropOwn(el)
    end
    if not Exists(el.own) then el.own = nil end
    if el.own and el.radius then EnsureCircle(el) else DropCircle(el) end
    if el.shown ~= el.own and el.shown == routeBlip then RouteOff() end
    el.shown = el.own
    if el.own then Emphasise(el, el.own) end
end

local function Where(el)
    local p = Exists(el.shown) and Coords(GetBlipCoords(el.shown)) or nil
    if p and (p.x ~= 0.0 or p.y ~= 0.0) then return p end
    return el.coords
end

-- The line goes on ONE blip: the point or the area's centre, or this officer's nearest target (switching only when
-- another one is 25 % closer); off near it, inside the circle, and whenever M.canRoute says no.
local function PickRoute()
    if not cur or cur.routeMode ~= 'on' or not M.canRoute(cur.ctx) then return RouteOff() end
    local me = MyPos()
    local best, bestD, held, heldD = nil, nil, nil, nil
    for _, id in ipairs(cur.order) do
        local el = cur.elements[id]
        if el and Exists(el.shown) then
            local d = CP.U.dist2d(me, Where(el))
            if el.shown == routeBlip then held, heldD = el, d end
            if not bestD or d < bestD then best, bestD = el, d end
        end
    end
    if held and best ~= held and bestD >= heldD * SWITCH_SHARE then best, bestD = held, heldD end
    if not best or bestD == math.huge then return RouteOff() end
    local off = best.radius or math.max(0, tonumber(Cfg().routeOffWithin) or 40.0)
    if bestD <= off then return RouteOff() end
    RouteOn(best.shown)
end

local function Tick()
    if cur then
        for _, id in ipairs(cur.order) do Place(cur.elements[id]) end
        PickRoute()
    end
    for _, el in pairs(services) do Place(el) end
end

local function HasWork() return (cur ~= nil and #cur.order > 0) or next(services) ~= nil end

-- One loop at a time, only while there is something on the map; it ends by itself once cleared.
local function StartLoop()
    if loopOn or not HasWork() then return end
    loopOn = true
    CreateThread(function()
        while HasWork() do
            Wait(TICK_MS)
            if not HasWork() then break end
            local ok, err = pcall(Tick)
            if not ok then CP.err(TAG, 'marker check failed: %s', tostring(err)) end
        end
        loopOn = false
    end)
end

-- ============================================================================
--                                  THE MARKER
-- ============================================================================
-- m = { kind = 'point'|'area'|'targets', look, label, key, number, coords, radius, route = true|false|'block',
--       targets = { { key, netId, x, y, z, look, label, variant, number } } } (docs/ARCHITECTURE.md §5.44)

local function Build(m)
    local list = {}
    if m.kind == 'point' or m.kind == 'area' then
        local c = Coords(m.coords)
        local r = m.kind == 'area' and tonumber(m.radius) or nil
        if c then
            list[1] = {
                id = m.kind,
                adoptKey = Key(m.key),
                look = Text(m.look) or (r and r > 0 and 'searchArea' or 'objective'),
                label = Text(m.label),
                number = Int(m.number),
                coords = c,
                radius = r and r > 0 and r + 0.0 or nil,
            }
        end
    elseif m.kind == 'targets' and type(m.targets) == 'table' then
        for i, t in ipairs(m.targets) do
            if #list >= MAX_TARGETS then break end
            if type(t) == 'table' then
                local netId = Int(t.netId)
                if netId and netId <= 0 then netId = nil end
                local key = Key(t.key) or (netId and tostring(netId)) or nil
                local c = Coords(t) or Coords(t.coords)
                if netId or c then
                    list[#list + 1] = {
                        id = 't:' .. (key or tostring(i)),
                        adoptKey = key,
                        look = Text(t.look) or 'objective',
                        variant = Text(t.variant),
                        label = Text(t.label) or Text(m.label),
                        number = Int(t.number),
                        coords = c,
                        netId = netId,
                        moving = true,
                    }
                end
            end
        end
    end
    return list
end

-- Keep what stays (its blip, line and flash), move what moved, drop what went (BLIPS_FINAL R8).
local function Reconcile(list)
    local keep = {}
    for _, n in ipairs(list) do keep[n.id] = n end
    for id, el in pairs(cur.elements) do
        if not keep[id] then
            Drop(el)
            cur.elements[id] = nil
        end
    end
    cur.order = {}
    for _, n in ipairs(list) do
        local el = cur.elements[n.id]
        if el then
            if el.look ~= n.look or el.label ~= n.label or el.variant ~= n.variant or el.number ~= n.number then
                DropOwn(el)
            end
            for _, f in ipairs(FIELDS) do el[f] = n[f] end
        else
            cur.elements[n.id] = n
        end
        cur.order[#cur.order + 1] = n.id
    end
end

local function DropMarker()
    if not cur then return end
    for _, el in pairs(cur.elements) do Drop(el) end
    cur.elements, cur.order = {}, {}
    RouteOff()
end

local function Apply(m)
    if type(m) ~= 'table' or not KINDS[m.kind] then m = {} end
    cur.routeMode = (m.route == 'block' and 'block') or (m.route == false and 'off') or 'on'
    Reconcile(Build(m))
    Tick()
    StartLoop()
end

-- ============================================================================
--                                  PUBLIC API
-- ============================================================================

-- The pointer of objective index (its block's client ctx gives Radio Silence); nil m = none yet.
function M.set(runId, index, m, ctx)
    index = math.tointeger(tonumber(index) or -1)
    if type(runId) ~= 'string' or not index or index < 1 then return false end
    DropMarker()
    cur = { runId = runId, index = index, ctx = type(ctx) == 'table' and ctx or nil, elements = {}, order = {} }
    Apply(m)
    return true
end

-- New positions or a new shape for the same objective (client:marker); another objective's is a set.
function M.update(runId, index, m, ctx)
    index = math.tointeger(tonumber(index) or -1)
    if not cur or cur.runId ~= runId or cur.index ~= index then return M.set(runId, index, m, ctx) end
    if type(ctx) == 'table' then cur.ctx = ctx end
    Apply(m)
    return true
end

-- Everything off the map: the pointer, its line, the blips blocks handed over (handed back with their line off).
-- With runId / index: only when the pointer is that objective's.
function M.clear(runId, index)
    if runId ~= nil and (not cur or cur.runId ~= runId) then return false end
    if index ~= nil and (not cur or cur.index ~= math.tointeger(tonumber(index) or -1)) then return false end
    DropMarker()
    for k, blip in pairs(adopted) do
        if blip == routeBlip then RouteOff() end
        adopted[k] = nil
    end
    RouteOff()
    cur = nil
    return true
end

-- A block hands over the blip it draws for target key (a net id or a point index): that blip is the pointer, and
-- CP.Markers draws no second icon for it.
function M.adopt(key, blip)
    key = Key(key)
    if not key or not Exists(blip) then return false end
    local old = adopted[key]
    if old and old ~= blip and old == routeBlip then RouteOff() end
    adopted[key] = blip
    if cur then Tick() end
    return true
end

-- The block takes it back (before it removes it): its line goes off, and CP.Markers draws the target again.
function M.release(key)
    key = Key(key)
    if not key or not adopted[key] then return false end
    if adopted[key] == routeBlip then RouteOff() end
    adopted[key] = nil
    if cur then Tick() end
    return true
end

-- A prisoner van or tow truck coming to this officer (kinds prisonerVan, towTruck): spec = { netId, coords, kind,
-- label }, nil = remove. Shown in every Radio Silence mode while Config.Markers.serviceVehicles is on; never routed.
function M.service(key, spec)
    key = Key(key)
    if not key then return false end
    local el = services[key]
    if spec == nil or spec == false then
        if el then
            Drop(el)
            services[key] = nil
        end
        return true
    end
    if type(spec) ~= 'table' then return false end
    local netId = Int(spec.netId)
    if netId and netId <= 0 then netId = nil end
    local n = {
        id = 's:' .. key,
        look = Text(spec.kind) or 'prisonerVan',
        label = Text(spec.label),
        coords = Coords(spec.coords),
        netId = netId,
        moving = true,
        service = true,
    }
    if el then
        if el.look ~= n.look or el.label ~= n.label then DropOwn(el) end
        for _, f in ipairs(FIELDS) do el[f] = n[f] end
    else
        el = n
        services[key] = el
    end
    Place(el)
    StartLoop()
    return true
end

-- True when Radio Silence hides kind (a Config.Markers.kinds key, or 'route' for a GPS line) for ctx's run (the
-- current pointer's when ctx is nil): 'none' hides everything but the start and service vehicles, 'area' keeps
-- circles and single points without a line, 'full' hides nothing (Config.Markers.radioSilence, BLIPS_FINAL R9).
function M.hidden(ctx, kind)
    if not Silent(ctx) or ALWAYS_SHOWN[kind] then return false end
    local mode = Mode()
    if mode == 'full' then return false end
    if mode == 'area' then return kind == 'route' or not SILENT_SHOWS[kind] end
    return true
end

-- May a Crimson-Police GPS line show now? Not while the drive to the start is on (CP.Route samples the start's line
-- from the blip route first), not while the officer has a waypoint of his own, not under Radio Silence, not when
-- Config.Markers says no (BLIPS_FINAL R2: one line per officer).
function M.canRoute(ctx)
    local cfg = Cfg()
    if cfg.enabled == false or cfg.route == false or M.hidden(ctx, 'route') then return false end
    local r = CP.Route and CP.Route.current and CP.Route.current()
    if r and not r.arrived then return false end
    if IsWaypointActive() then return false end
    return true
end

-- The look of kind (Config.Markers.kinds) and the settings every objective blip gets: short range, legend category,
-- a name, a number. opts = { variant = 'boss'|'next'|'followUp'|'setback', number = n }.
function M.style(blip, kind, label, opts)
    if not Exists(blip) then return false end
    opts = type(opts) == 'table' and opts or {}
    local sprite, colour, scale = Look(kind, opts.variant)
    SetBlipSprite(blip, sprite)
    SetBlipColour(blip, colour)
    SetBlipScale(blip, scale)
    SetBlipAsShortRange(blip, Cfg().shortRange == true)
    SetBlipCategory(blip, Int(Cfg().category) or 2)
    local n = Int(opts.number)
    if n and n >= 0 then ShowNumberOnBlip(blip, n) end
    if Text(label) then NameBlip(blip, label) end
    return true
end

-- ============================================================================
--                                RESOURCE STOP
-- ============================================================================

AddEventHandler('onResourceStop', function(res)
    if res ~= CP.resource then return end
    M.clear()
    for key in pairs(services) do M.service(key, nil) end
end)
