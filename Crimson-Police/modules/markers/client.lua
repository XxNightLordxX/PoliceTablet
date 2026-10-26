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
local HUD_STEP_NEAR = 10 -- metres: the HUD's distance moves in these steps under 1 km (one send per change)
local HUD_STEP_FAR = 100 -- metres: and in these from 1 km (the HUD shows 1.2 km)
local WAYPOINT_SPRITE = 8 -- the map waypoint's blip (GetFirstBlipInfoId)
local WAYPOINT_MATCH = 15.0 -- metres: the waypoint is still the one Objective GPS set when it is this close to it
local GPS_FOLLOW = 50.0 -- metres: the Objective GPS waypoint moves with the pointer once it is this far off
local DEFAULT_LOOK = { sprite = 162, colour = 5, scale = 0.9 } -- kinds.objective as shipped
local SURRENDERED_SCALE = 0.6 -- kinds.suspect.surrenderedScale as shipped (an older config.lua without the key)
local KINDS = { point = true, area = true, targets = true }
local MODES = { none = true, area = true, full = true }
-- What Radio Silence 'area' still shows: circles and single points, never a GPS line or a person's or car's blip.
-- point and device are shown only by CP.Markers, one per objective (NEAREST_ONLY); a block draws neither then.
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
-- Kinds an objective has several of (Business Check's doors, Bomb Disposal's devices): under Radio Silence 'area' the
-- block draws none of its own, and CP.Markers shows only this officer's nearest from the server's pointer (BLIPS_FINAL
-- section 3: "only the nearest pending point").
local NEAREST_ONLY = { point = true, device = true }
-- What every mode shows: the drive to the start and the service vehicles coming to the officer.
local ALWAYS_SHOWN = { start = true, prisonerVan = true, towTruck = true }
local SERVICE_LABELS = { prisonerVan = 'markers.prisoner_van', towTruck = 'markers.tow_truck' }
local FIELDS = { 'adoptKey', 'look', 'variant', 'label', 'number', 'coords', 'radius', 'netId', 'moving', 'beyond' }

local cur = nil         -- { runId, index, ctx, routeMode = 'on'|'off'|'block', elements = { [id] = el }, order,
                        --   single (Radio Silence 'area': the id of the one point shown), pointed (the id of the
                        --   element the pointer leads to: the line, the HUD line and Objective GPS) }
local adopted = {}      -- [key] = a block's own blip it handed over (M.adopt)
local services = {}     -- [key] = el: a prisoner van or tow truck (M.service)
local routeBlip = nil   -- the only blip with SetBlipRoute(true)
local routeColour = nil -- the line colour routeBlip got
local loopOn = false
local hudSent = ''      -- the HUD's objective line as last sent ('' = none on the HUD)
local gps = nil         -- the waypoint Objective GPS set: { runId, index, x, y }

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
-- setbackColour when the kind has one, and 'surrendered' its surrenderedScale (0.6 when it has none).
local function Look(kind, variant)
    local kinds = type(Cfg().kinds) == 'table' and Cfg().kinds or {}
    local k = kinds[kind]
    if type(k) ~= 'table' then k = type(kinds.objective) == 'table' and kinds.objective or DEFAULT_LOOK end
    local sprite = Int(k.sprite) or DEFAULT_LOOK.sprite
    local colour = Int(k.colour) or DEFAULT_LOOK.colour
    local scale = tonumber(k.scale) or DEFAULT_LOOK.scale
    if variant == 'boss' and tonumber(k.bossScale) then scale = tonumber(k.bossScale) end
    if variant == 'next' and tonumber(k.nextScale) then scale = tonumber(k.nextScale) end
    if variant == 'surrendered' then scale = tonumber(k.surrenderedScale) or SURRENDERED_SCALE end
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

-- True while this officer still drives to the start (CP.Route, §5.12): the start keeps his only line (R2). Not once he
-- follows the action (a late partner, CP.Route.follow, PLAN M11): CP.Route has dropped the start's line by then.
local function Driving()
    local r = CP.Route and CP.Route.current and CP.Route.current()
    return r ~= nil and not r.arrived and not r.action
end

local function Silent(ctx)
    if type(ctx) ~= 'table' then ctx = cur and cur.ctx end
    return type(ctx) == 'table' and ctx.radioSilence == true
end

local function Mode()
    local m = Cfg().radioSilence
    return MODES[m] and m or 'area'
end

-- Radio Silence hides kind for ctx's run (BLIPS_FINAL R9). block: asked for a block's own blip, which under 'area'
-- also hides a NEAREST_ONLY kind (CP.Markers shows the nearest itself) and the 'next' variant (a second checkpoint).
local function Hides(ctx, kind, variant, block)
    if not Silent(ctx) or ALWAYS_SHOWN[kind] then return false end
    local mode = Mode()
    if mode == 'full' then return false end
    if mode == 'none' then return true end
    if kind == 'route' or variant == 'next' then return true end
    if block and NEAREST_ONLY[kind] then return true end
    return not SILENT_SHOWS[kind]
end

local function SilentArea() return Silent() and Mode() == 'area' end

-- True when a blip of this variant flashes for as long as it has it: a device set back (Config.Markers.setbackFlash).
local function SetbackFlash(variant) return variant == 'setback' and Cfg().setbackFlash ~= false end

-- ============================================================================
--                                   THE LINE
-- ============================================================================

local function RouteOff()
    if Exists(routeBlip) then SetBlipRoute(routeBlip, false) end
    routeBlip, routeColour = nil, nil
end

local function RouteOn(blip)
    local colour = M.routeColour()
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
-- el = { id, adoptKey, look, variant, label, number, coords, radius, netId, moving, beyond, service,
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

-- A new pointer blip: above the detail blips, flashing once (SET_BLIP_FLASH_TIMER, BLIPS_FINAL R5). carry: a block
-- just handed over its own blip for a target ours showed, so the block's blip flashes for the rest of that one flash
-- (a block draws its blips from its first snapshot, right after the pointer came up).
local function Emphasise(el, blip, carry)
    if el.service or el.emphasised == blip then return end
    el.emphasised = blip
    SetBlipPriority(blip, POINTER_PRIORITY)
    -- a device set back already flashes for as long as it is set back (M.style, Config.Markers.setbackFlash): a timed
    -- flash on top would stop it after flashSeconds
    if SetbackFlash(el.variant) then
        el.flashed = true
        return
    end
    local ms
    if not el.flashed then
        el.flashed = true
        local s = Seconds('flashSeconds', 5)
        if s <= 0 then return end
        ms = math.floor(s * 1000)
        el.flashUntil = GetGameTimer() + ms
    elseif carry and el.flashUntil then
        ms = el.flashUntil - GetGameTimer()
    end
    if ms and ms > 0 then
        SetBlipFlashes(blip, true)
        SetBlipFlashTimer(blip, ms)
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
        hide = cfg.enabled == false or Hides(cur and cur.ctx, el.look, el.variant, false)
            or (el.netId ~= nil and not ALWAYS_SHOWN[el.look] and SilentArea())
    end
    local lastKnown = not el.service and el.moving and hide and cfg.enabled ~= false and SilentArea()
        and Seconds('radioSilenceLastKnown', 0) > 0
    LastKnown(el, lastKnown)
    -- Radio Silence 'area': an objective with several points shows only the nearest (PickSingle)
    if not hide and not el.service and cur and cur.single and cur.single ~= el.id then hide = true end
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
        local carry = Exists(el.own)
        DropOwn(el)
        DropCircle(el)
        el.shown = a
        return Emphasise(el, a, carry)
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

-- What the pointer leads to, of what the map shows: the point or the area's centre, or this officer's nearest target
-- (switching only when another one is 25 % closer). A target with beyond (escort's truck) comes before the others
-- while this officer is farther than that from it, keeps it until he is within 75 % of that, and never has it closer:
-- then the others share it (the destination). Returns the element and its distance (2D), nil when nothing shows.
local function Pick()
    local me = MyPos()
    local best, bestD, held, heldD, lead, leadD = nil, nil, nil, nil, nil, nil
    for _, id in ipairs(cur.order) do
        local el = cur.elements[id]
        if el and Exists(el.shown) then
            local d = CP.U.dist2d(me, Where(el))
            if el.beyond then
                local reach = id == cur.pointed and el.beyond * SWITCH_SHARE or el.beyond
                if d > reach and (not leadD or d < leadD) then lead, leadD = el, d end
            else
                if id == cur.pointed then held, heldD = el, d end
                if not bestD or d < bestD then best, bestD = el, d end
            end
        end
    end
    if lead then
        best, bestD = lead, leadD
    elseif held and best ~= held and bestD >= heldD * SWITCH_SHARE then
        best, bestD = held, heldD
    end
    if bestD == math.huge then best, bestD = nil, nil end
    cur.pointed = best and best.id or nil
    return best, bestD
end

-- The line goes on the pointer's blip; off near it, inside the circle, and whenever M.canRoute says no.
local function Line(best, bestD)
    if not best or cur.routeMode ~= 'on' or not M.canRoute(cur.ctx) then return RouteOff() end
    local off = best.radius or math.max(0, tonumber(Cfg().routeOffWithin) or 40.0)
    if bestD <= off then return RouteOff() end
    RouteOn(best.shown)
end

-- ============================================================================
--                        THE HUD LINE AND OBJECTIVE GPS
-- ============================================================================
-- The HUD names what the pointer leads to and how far it is (Config.Markers.hudLine, PLAN M10): only what the map
-- shows (Radio Silence included), never while the officer still drives to the start, sent only when it changes.

local function SendHud(target)
    local key = target and ('%s|%d|%s'):format(target.label, target.distance, tostring(target.inside == true)) or ''
    if key == hudSent then return end
    hudSent = key
    if not (CP.Tablet and CP.Tablet.hud) then return end
    local ok, err = pcall(CP.Tablet.hud, { target = target or false })
    if not ok then CP.err(TAG, 'HUD objective line failed: %s', tostring(err)) end
end

local function HudLine(el, d)
    local cfg = Cfg()
    if not el or cfg.enabled == false or cfg.hudLine == false or Driving() then return SendHud(nil) end
    -- an area: how far to its edge, or inside it
    local inside = el.radius ~= nil and d <= el.radius
    local m = el.radius and d - el.radius or d
    local step = m < 1000 and HUD_STEP_NEAR or HUD_STEP_FAR
    local distance = inside and 0 or math.floor(m / step + 0.5) * step
    SendHud({ label = LabelOf(el), distance = math.tointeger(distance) or 0, inside = inside or nil })
end

-- True while the map waypoint is still the one Objective GPS set (the officer may have cleared it or set his own).
local function OurGps()
    if not gps or not IsWaypointActive() then return false end
    local blip = GetFirstBlipInfoId(WAYPOINT_SPRITE)
    if not blip or blip == 0 or not DoesBlipExist(blip) then return false end
    return CP.U.dist2d(GetBlipInfoIdCoord(blip), gps) <= WAYPOINT_MATCH
end

-- Objective GPS's waypoint goes with its objective: removed at the objective's stop and the run's end, unless the
-- officer put his own in its place (never touched).
local function DropGps()
    if gps and OurGps() then SetWaypointOff() end
    gps = nil
end

-- While it is ours, the waypoint follows the pointer: a moving car or suspect, the next nearest door.
local function FollowGps(el)
    if not gps then return end
    if not OurGps() then
        gps = nil
        return
    end
    if not el or M.hidden(cur.ctx, 'route') then return end
    local p = Where(el)
    if p and CP.U.dist2d(p, gps) > GPS_FOLLOW then
        SetNewWaypoint(p.x + 0.0, p.y + 0.0)
        gps.x, gps.y = p.x, p.y
    end
end

-- Radio Silence 'area' shows one point per objective: of the points still shown (no net id, a kind 'area' keeps), the
-- id of this officer's nearest, which changes only when another one is 25 % closer; nil when there is one or none.
local function PickSingle()
    if not SilentArea() or #cur.order < 2 then return nil end
    local me = MyPos()
    local best, bestD, heldD = nil, nil, nil
    for _, id in ipairs(cur.order) do
        local el = cur.elements[id]
        if el and el.coords and el.netId == nil and not Hides(cur.ctx, el.look, el.variant, false) then
            local d = CP.U.dist2d(me, el.coords)
            if id == cur.single then heldD = d end
            if not bestD or d < bestD then best, bestD = id, d end
        end
    end
    if heldD and best ~= cur.single and bestD >= heldD * SWITCH_SHARE then return cur.single end
    return best
end

local function Tick()
    if cur then
        cur.single = PickSingle()
        for _, id in ipairs(cur.order) do Place(cur.elements[id]) end
        local el, d = Pick()
        Line(el, d)
        HudLine(el, d)
        FollowGps(el)
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
--       targets = { { key, netId, x, y, z, look, label, variant, number, beyond } } } (docs/ARCHITECTURE.md §5.44)

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
                local beyond = tonumber(t.beyond)
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
                        beyond = beyond and beyond > 0 and beyond + 0.0 or nil,
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
    if gps and (gps.runId ~= runId or gps.index ~= index) then DropGps() end
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

-- Everything off the map: the pointer, its line, the blips blocks handed over (handed back with their line off), the
-- HUD's objective line and the Objective GPS waypoint while it is still ours. With runId / index: only when the
-- pointer is that objective's. Without them (the run's end, leaving it, resource stop) the run's service vehicles go
-- too (they outlive an objective's stop, never the run).
function M.clear(runId, index)
    if runId ~= nil and (not cur or cur.runId ~= runId) then return false end
    if index ~= nil and (not cur or cur.index ~= math.tointeger(tonumber(index) or -1)) then return false end
    DropMarker()
    SendHud(nil)
    DropGps()
    for k, blip in pairs(adopted) do
        if blip == routeBlip then RouteOff() end
        adopted[k] = nil
    end
    RouteOff()
    cur = nil
    if runId == nil and index == nil then
        for key, el in pairs(services) do
            Drop(el)
            services[key] = nil
        end
    end
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

-- The block takes it back (before it removes it): its line goes off, and CP.Markers draws the target again. With
-- blip: only when that is the blip handed over for key (another block's hand-over of the same key stays).
function M.release(key, blip)
    key = Key(key)
    if not key or not adopted[key] then return false end
    if blip ~= nil and adopted[key] ~= blip then return false end
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

-- True when Radio Silence hides a block's own blip of kind (a Config.Markers.kinds key, or 'route' for a GPS line)
-- for ctx's run (the current pointer's when ctx is nil); every block asks this before it draws a blip or a line.
-- 'none' hides everything but the start and service vehicles; 'area' keeps the objective's circle or its one point
-- without a line: no blips on people or cars, no second checkpoint (variant 'next'), and no points or devices of the
-- block's own (CP.Markers shows the nearest one itself); 'full' hides nothing (Config.Markers.radioSilence, BLIPS_FINAL
-- R9).
function M.hidden(ctx, kind, variant) return Hides(ctx, kind, variant, true) end

-- May a Crimson-Police GPS line show now? Not while the drive to the start is on (CP.Route samples the start's line
-- from the blip route first), not while the officer has a waypoint (his own, or the one Objective GPS set), not under
-- Radio Silence, not when Config.Markers says no (BLIPS_FINAL R2: one line per officer).
function M.canRoute(ctx)
    local cfg = Cfg()
    if cfg.enabled == false or cfg.route == false or M.hidden(ctx, 'route') then return false end
    if Driving() then return false end
    if IsWaypointActive() then return false end
    return true
end

-- Can this officer get a GPS line to the objective at all for ctx's run (Config.Markers on with its line, and Radio
-- Silence not hiding lines)? A late partner's game asks before it drops the start's line for the objective's
-- (PLAN M11); without it he keeps the start's waypoint.
function M.leads(ctx)
    local cfg = Cfg()
    return cfg.enabled ~= false and cfg.route ~= false and not M.hidden(ctx, 'route')
end

-- Objective GPS (the Active Mission screen's button, Config.Markers.objectiveGps, PLAN M10): a map waypoint on what
-- the pointer leads to. The waypoint is then the officer's one line (M.canRoute), follows a moving objective while it
-- stays ours and goes with the objective. Refused while he still drives to the start (the start keeps his line) and
-- while Radio Silence hides the objective's line. Returns ok, { label } | errKey.
function M.objectiveGps()
    local cfg = Cfg()
    if cfg.enabled == false or cfg.objectiveGps == false then return false, 'err.objective_gps_off' end
    if not cur then return false, 'err.objective_gps_none' end
    if Driving() then return false, 'err.objective_gps_start' end
    if M.hidden(cur.ctx, 'route') then return false, 'err.objective_gps_silence' end
    local el = Pick()
    local p = el and Where(el)
    if not p then return false, 'err.objective_gps_none' end
    SetNewWaypoint(p.x + 0.0, p.y + 0.0)
    gps = { runId = cur.runId, index = cur.index, x = p.x, y = p.y }
    RouteOff() -- the waypoint is his line now, at once (BLIPS_FINAL R2)
    local label = LabelOf(el)
    if CP.Tablet and CP.Tablet.notify then CP.Tablet.notify('info', CP.L('markers.gps_set', { label = label })) end
    return true, { label = label }
end

-- The colour of every Crimson-Police GPS line (Config.Markers.routeColour, 0-85), a block's own line included
-- (checkpoint_route).
function M.routeColour() return CP.U.clamp(Int(Cfg().routeColour) or 5, 0, 85) end

-- The look of kind (Config.Markers.kinds) and the settings every objective blip gets: short range, legend category,
-- a name, a number. opts = { variant = 'boss'|'next'|'followUp'|'setback'|'surrendered', number = n }. A 'setback' blip flashes from
-- now on (Config.Markers.setbackFlash); a block that restyles it to another variant stops that (SetBlipFlashes false).
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
    if SetbackFlash(opts.variant) then SetBlipFlashes(blip, true) end
    return true
end

-- The look of a block's own circle (an AddBlipForRadius blip) of kind: that kind's colour (Config.Markers.kinds) and
-- Config.Markers.areaAlpha, as CP.Markers draws its own circles.
function M.styleArea(blip, kind)
    if not Exists(blip) then return false end
    local _, colour = Look(kind)
    SetBlipColour(blip, colour)
    SetBlipAlpha(blip, AreaAlpha())
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

-- ============================================================================
--           CLIENT ACTIONS (registered once every module has loaded)
-- ============================================================================

CreateThread(function()
    Wait(0)
    if not (CP.Tablet and CP.Tablet.registerClientAction) then
        CP.err(TAG, 'modules/tablet is missing: Objective GPS is unavailable')
        return
    end
    CP.Tablet.registerClientAction('setObjectiveGps', function() return M.objectiveGps() end)
end)
