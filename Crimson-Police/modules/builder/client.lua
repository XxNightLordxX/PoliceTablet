-- CP.Builder (client): the Mission Builder's in-world tools. Protocol: docs/notes/builder_protocol.md §6 (client
-- actions, results, overlays); shapes of the overlays and of the fields this client adds:
-- web/src/types/builder_client.ts; notes: docs/notes/builder_client.md.

CP.Builder = CP.Builder or {}
local B = CP.Builder
local U = CP.U
local TAG = 'builder'

-- ============================================================================
--                                  CONSTANTS
-- ============================================================================

local ID_PATTERN = '^[%w_]+$'
local KEY_PATTERN = '^[%a_][%w_]*$'
local MODEL_PATTERN = '^[%w_]+$'
local MAX_ID = 40
local MAX_KEY = 40
local MAX_POINTS = 200
local MAX_ROUTE_POINTS = 500
local MAX_LOCATIONS = 20
local MAX_LABEL = 64
local COORD_LIMIT = 20000.0
local KINDS = { ped = true, vehicle = true, marker = true, area = true, start = true }
local UIS = { supervisor = true, admin = true }

local RAY_DISTANCE = 60.0
local MAX_PLACE_DISTANCE = 50.0             -- metres from the player
local GROUND_TOLERANCE = 0.75               -- aimed surface vs ground height
local MIN_NORMAL_Z = 0.7                    -- steeper than ~45° is not ground
local PED_HEIGHT = 1.0
local START_RADIUS = { 20.0, 150.0, 60.0 }  -- the builder server's start radius range (protocol §1)
local AREA_RADIUS = { 2.0, 1000.0, 25.0 }
local AREA_STEP, AREA_FINE = 5.0, 1.0
local HEADING_STEP, HEADING_FINE = 10.0, 1.0
local PROBE_GAP_MS = 60
local OVERLAY_MS = 150
local ARENA_CHECK_MS = 250
local MESSAGE_MS = 2500
local ZONE_DRAW_RANGE = 400.0
local POINT_DRAW_RANGE = 160.0
local LABEL_RANGE = 40.0
local MAX_REJECTED_SAMPLES = 50
local DUP_DIST = 1.0
local ROAD_SURFACE_FACTOR = 4.0
local APPROACH_RADIUS = 200.0
local CLEAR_RADIUS = 6.0
local STUCK_MS = 6000
local DONE_SHOW_MS = 1500
local NO_PATH = 100000.0
local PATH_CHECKS_PER_FRAME = 4
local MODEL_TIMEOUT_MS = 5000
local DRIVER_MODEL = 's_m_m_armoured_01'
local DRIVER_FALLBACK = 'a_m_m_business_01'
local SPEED_RANGE = { 5, 250 }              -- km/h
local STOP_WAIT_MAX = 600

local STYLES = {
    careful = 786603,    -- stops for cars, peds and red lights; keeps to its lane (as CP.Npc)
    cautious = 786603,
    normal = 786475,     -- as careful, without stopping at red lights
    fast = 786492,       -- swerves around traffic instead of stopping; keeps to its lane
    reckless = 786492,   -- a test drive always keeps to its lanes
}

local COLOURS = {
    ok = { 52, 196, 124 },
    bad = { 240, 70, 77 },
    point = { 78, 161, 255 },
    start = { 245, 165, 36 },
    zone = { 240, 70, 77 },
    route = { 78, 161, 255 },
    rejected = { 240, 70, 77 },
    resume = { 245, 165, 36 },
    failed = { 240, 70, 77 },
    done = { 52, 196, 124 },
}

-- Controls (group 0). The tool reads them with IsDisabledControlJustPressed after disabling them.
local C = {
    E = 38,
    E_ALT = 51,
    HORN = 86,
    BACK = 194,
    ENTER = 191,
    ENTER_ALT = 201,
    P = 199,
    X = 73,
    WHEEL_UP = 15,
    WHEEL_DOWN = 14,
    CURSOR_UP = 241,
    CURSOR_DOWN = 242,
    SHIFT = 21,
}
-- placement: attacks, the weapon wheel and every key the tool uses
local PLACE_DISABLE = {
    14,
    15,
    16,
    17,
    24,
    37,
    38,
    47,
    51,
    58,
    69,
    70,
    73,
    86,
    92,
    99,
    100,
    140,
    141,
    142,
    177,
    191,
    194,
    199,
    201,
    241,
    242,
    257,
    261,
    262,
    263,
    264,
}
-- recording: only the tool keys (the player drives)
local RECORD_DISABLE = { 38, 51, 73, 86, 177, 194, 199 }
-- test drive: X stops it
local DRIVE_DISABLE = { 73 }
-- cancel reasons after which the tablet stays closed
local NO_REOPEN = { arena = true, unload = true, dead = true, deleted = true, run = true }

-- ============================================================================
--                             SMALL HELPERS (pure)
-- ============================================================================

local function IsNum(v) return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge end
local function IsInt(v) return IsNum(v) and math.floor(v) == v end
local function Round2(v) return math.floor(v * 100 + 0.5) / 100 end
local function Clamp(x, lo, hi) if x < lo then return lo end if x > hi then return hi end return x end
local function NormHeading(h) return ((h % 360.0) + 360.0) % 360.0 end

local function AngleDiff(a, b)
    local d = math.abs(NormHeading(a) - NormHeading(b))
    if d > 180.0 then d = 360.0 - d end
    return d
end

function B.headingOf(a, b)
    local dx, dy = b.x - a.x, b.y - a.y
    return NormHeading(math.deg(math.atan(-dx, dy)))
end
local headingOf = B.headingOf

local function HeadingDir(h)
    local r = math.rad(h)
    return -math.sin(r), math.cos(r)
end

-- A vector (vector3/vector4 or { x, y, z[, w] }) as a plain table with finite numbers, else nil.
local function VecOf(v)
    local t = type(v)
    local x, y, z, w
    if t == 'vector3' or t == 'vector4' then
        x, y, z = v.x, v.y, v.z
        if t == 'vector4' then w = v.w end
    elseif t == 'table' then
        x, y, z, w = v.x, v.y, v.z, v.w
    else
        return nil
    end
    if not (IsNum(x) and IsNum(y) and IsNum(z)) then return nil end
    if math.abs(x) > COORD_LIMIT or math.abs(y) > COORD_LIMIT or math.abs(z) > COORD_LIMIT then return nil end
    local out = { x = x + 0.0, y = y + 0.0, z = z + 0.0 }
    if w ~= nil then
        if not IsNum(w) then return nil end
        out.w = NormHeading(w + 0.0)
    end
    return out
end

local function RoundVec(p, withHeading, heading)
    local out = { x = Round2(p.x), y = Round2(p.y), z = Round2(p.z) }
    if withHeading then out.w = Round2(NormHeading(heading or p.w or 0.0)) % 360.0 end
    return out
end

local function ValidId(id) return type(id) == 'string' and #id > 0 and #id <= MAX_ID and id:match(ID_PATTERN) ~= nil end
local function ValidKey(k) return type(k) == 'string' and #k > 0 and #k <= MAX_KEY and k:match(KEY_PATTERN) ~= nil end
local function ValidLocation(v) return IsInt(v) and v >= 1 and v <= MAX_LOCATIONS end

-- Trimmed display text of at most MAX_LABEL characters (UTF-8 safe), or nil.
local function LabelOf(s)
    if type(s) ~= 'string' then return nil end
    s = U.trim(s):gsub('[%c]', ' ')
    if s == '' then return nil end
    if utf8.len(s) and utf8.len(s) > MAX_LABEL then
        s = s:sub(1, (utf8.offset(s, MAX_LABEL + 1) or (#s + 1)) - 1)
    elseif not utf8.len(s) then
        s = U.clip(s, MAX_LABEL)
    end
    return s
end

local function VecList(src, max)
    if src == nil then return {} end
    if type(src) ~= 'table' or #src > max then return nil end
    local out = {}
    for i = 1, #src do
        local v = VecOf(src[i])
        if not v then return nil end
        out[i] = v
    end
    return out
end

function B.routeLength(points)
    local len = 0.0
    for i = 2, #(points or {}) do len = len + U.dist(points[i - 1], points[i]) end
    return len
end

function B.thin(points, max)
    local n = #(points or {})
    local out = {}
    if n <= max or max < 2 then
        for i = 1, n do out[i] = points[i] end
        return out
    end
    local last = 0
    for i = 1, max do
        local idx = math.floor(1 + (i - 1) * (n - 1) / (max - 1) + 0.5)
        if idx > last then
            out[#out + 1] = points[idx]
            last = idx
        end
    end
    return out
end

function B.drivingStyle(name)
    return STYLES[name] or STYLES.normal
end

-- ============================================================================
--                          THE ROUTE RECORDER (pure)
-- ============================================================================

local Recorder = {}
Recorder.__index = Recorder

function B.newRecorder(opts)
    opts = type(opts) == 'table' and opts or {}
    return setmetatable({
        turnAngle = tonumber(opts.turnAngle) or 30.0,
        maxGap = tonumber(opts.maxGap) or 150.0,
        dupDist = tonumber(opts.dupDist) or DUP_DIST,
        samples = {},   -- snapped samples in driving order
        cum = {},       -- cumulative distance along the samples
        wps = {},       -- sample indexes kept as waypoints (ascending)
        stops = {},     -- { at = waypoint index, wait }
    }, Recorder)
end

local function Keep(self, i)
    local n = #self.wps
    if n == 0 or self.wps[n] < i then self.wps[n + 1] = i end
end

function Recorder:add(p)
    local n = #self.samples
    local s = { x = Round2(p.x), y = Round2(p.y), z = Round2(p.z) }
    if n > 0 and U.dist(s, self.samples[n]) < self.dupDist then return false end
    local k = n + 1
    self.samples[k] = s
    self.cum[k] = n > 0 and (self.cum[n] + U.dist(self.samples[n], s)) or 0.0
    if k == 1 then
        Keep(self, 1)
        return true
    end
    local last = self.wps[#self.wps]
    -- a turn: the new segment's heading against the heading leaving the last waypoint
    if k - 1 > last then
        local ref = headingOf(self.samples[last], self.samples[last + 1])
        local h = headingOf(self.samples[k - 1], s)
        if AngleDiff(h, ref) > self.turnAngle then
            Keep(self, k - 1)
            last = k - 1
        end
    end
    -- at least one waypoint every maxGap metres of road: keep the sample before the gap
    if k - 1 > last and self.cum[k] - self.cum[last] > self.maxGap then Keep(self, k - 1) end
    return true
end

function Recorder:count() return #self.samples end

function Recorder:endPoint()
    return self.samples[#self.samples]
end

-- Waypoints so far, with the current end of the recording.
function Recorder:waypoints()
    local out = {}
    for _, i in ipairs(self.wps) do out[#out + 1] = self.samples[i] end
    local n = #self.samples
    if n > 0 and (#self.wps == 0 or self.wps[#self.wps] < n) then out[#out + 1] = self.samples[n] end
    return out
end

function Recorder:length()
    return B.routeLength(self:waypoints())
end

function Recorder:undo(metres)
    local n = #self.samples
    if n <= 1 then return 0.0 end
    local total = self.cum[n]
    local target = total - (tonumber(metres) or 0)
    while #self.samples > 1 and self.cum[#self.samples] > target + 1e-6 do
        local k = #self.samples
        self.samples[k] = nil
        self.cum[k] = nil
    end
    local count = #self.samples
    while #self.wps > 0 and self.wps[#self.wps] > count do self.wps[#self.wps] = nil end
    local wpCount = #self.wps
    for i = #self.stops, 1, -1 do
        if self.stops[i].at > wpCount then table.remove(self.stops, i) end
    end
    return total - self.cum[count]
end

function Recorder:addStop(wait, max)
    local n = #self.samples
    if n < 2 then return false, 'builder.rec.stop_too_early' end
    if #self.stops >= (max or 0) then return false, 'builder.rec.stop_max' end
    Keep(self, n)
    local at = #self.wps
    for _, s in ipairs(self.stops) do
        if s.at == at then return false, 'builder.rec.stop_here' end
    end
    self.stops[#self.stops + 1] = { at = at, wait = wait }
    return true
end

-- The recorded waypoints and the stops on interior waypoints (a stop on the first or last one is dropped).
function Recorder:finish()
    local n = #self.samples
    if n > 0 then Keep(self, n) end
    local pts = {}
    for i, idx in ipairs(self.wps) do
        local s = self.samples[idx]
        pts[i] = { x = s.x, y = s.y, z = s.z }
    end
    local stops, dropped = {}, 0
    for _, s in ipairs(self.stops) do
        if s.at >= 2 and s.at < #pts then
            stops[#stops + 1] = { at = s.at, wait = s.wait }
        else
            dropped = dropped + 1
        end
    end
    return pts, stops, dropped
end

-- ============================================================================
--                           PLACEMENT CHECKS (pure)
-- ============================================================================

function B.checkSpot(spot, ctx)
    ctx = ctx or {}
    local points = ctx.points or {}
    if ctx.multiple and IsNum(ctx.max) and ctx.max > 0 and #points >= ctx.max then
        return false, 'builder.place.reason.max', { max = ctx.max }
    end
    if type(spot) ~= 'table' or not spot.hit then return false, 'builder.place.reason.no_hit' end
    if IsNum(ctx.maxDistance) and IsNum(spot.distance) and spot.distance > ctx.maxDistance then
        return false, 'builder.place.reason.far', { max = math.floor(ctx.maxDistance) }
    end
    -- the distances are the server's: from the point as it is stored (a ped 1 m above the aimed ground)
    local at = type(spot.stored) == 'table' and spot.stored or spot
    for _, z in ipairs(ctx.zones or {}) do
        if z.coords and U.dist2d(at, z.coords) <= (tonumber(z.radius) or 0) then
            return false, 'builder.place.reason.zone', { zone = tostring(z.label or '?') }
        end
    end
    if spot.water then return false, 'builder.place.reason.water' end
    local kind = ctx.kind
    if kind ~= 'marker' then
        if not IsNum(spot.groundZ) or math.abs(spot.z - spot.groundZ) > GROUND_TOLERANCE then
            return false, 'builder.place.reason.not_ground'
        end
        if IsNum(spot.normalZ) and spot.normalZ < MIN_NORMAL_Z then return false, 'builder.place.reason.steep' end
    end
    if kind == 'ped' or kind == 'vehicle' then
        if spot.blocked == nil then return false, 'builder.place.reason.checking' end
        if spot.blocked then return false, 'builder.place.reason.blocked' end
    end
    if ctx.spawn and ctx.start and IsNum(ctx.minFromStart) and U.dist(at, ctx.start) < ctx.minFromStart then
        return false, 'builder.place.reason.start', { min = math.floor(ctx.minFromStart) }
    end
    if kind == 'start' and IsNum(ctx.minLocationGap) then
        for _, s in ipairs(ctx.otherStarts or {}) do
            if U.dist2d(at, s) < ctx.minLocationGap then
                return false, 'builder.place.reason.gap', { min = math.floor(ctx.minLocationGap) }
            end
        end
    end
    if ctx.multiple and IsNum(ctx.minGap) and ctx.minGap > 0 then
        for _, p in ipairs(points) do
            if U.dist(at, p) < ctx.minGap then
                return false, 'builder.place.reason.spacing', { min = math.floor(ctx.minGap) }
            end
        end
    end
    return true
end

-- ============================================================================
--                               PAYLOADS (pure)
-- ============================================================================

local function Common(p)
    if type(p) ~= 'table' then return nil end
    if not ValidId(p.missionId) or not ValidLocation(p.location) or not ValidKey(p.key) then return nil end
    if p.ui ~= nil and not UIS[p.ui] then return nil end
    if p.label ~= nil and type(p.label) ~= 'string' then return nil end
    return {
        missionId = p.missionId,
        location = p.location,
        key = p.key,
        ui = p.ui or 'supervisor',
        label = LabelOf(p.label),
    }
end

local function InAllowed(list, name)
    for _, v in ipairs(type(list) == 'table' and list or {}) do
        if v == name then return true end
    end
    return false
end

function B.parsePlace(p)
    local o = Common(p)
    if not o then return nil, 'err.invalid_payload' end
    if not KINDS[p.kind] then return nil, 'err.invalid_payload' end
    o.kind = p.kind
    if p.model ~= nil then
        if type(p.model) ~= 'string' or #p.model > 64 or not p.model:match(MODEL_PATTERN) then
            return nil, 'err.invalid_payload'
        end
        o.model = p.model
    end
    for _, f in ipairs({ 'heading', 'multiple', 'spawn', 'streets' }) do
        if p[f] ~= nil and type(p[f]) ~= 'boolean' then return nil, 'err.invalid_payload' end
    end
    o.streets = p.streets == true   -- kerb spots: the result names the street at each point
    o.heading = p.heading == true and o.kind ~= 'area' and o.kind ~= 'start'
    o.multiple = p.multiple == true and o.kind ~= 'start'
    o.spawn = p.spawn == true
    local src = p.points
    if src == nil then src = p.existing end
    local points = VecList(src, MAX_POINTS)
    if not points then return nil, 'err.invalid_payload' end
    local min = p.min
    if min ~= nil and not (IsInt(min) and min >= 0 and min <= MAX_POINTS) then return nil, 'err.invalid_payload' end
    local max = p.max
    if max == nil then max = p.count end
    if max ~= nil and not (IsInt(max) and max >= 1 and max <= MAX_POINTS) then return nil, 'err.invalid_payload' end
    if not o.multiple then
        max = 1
        if min == nil then min = 1 end
        if #points > 1 then points = { points[#points] } end
    end
    o.min = min or 0
    o.max = max or MAX_POINTS
    if o.min > o.max then o.min = o.max end
    while #points > o.max do points[#points] = nil end
    for _, v in ipairs(points) do
        if not o.heading then v.w = nil elseif v.w == nil then v.w = 0.0 end
    end
    o.points = points
    local range = o.kind == 'start' and START_RADIUS or AREA_RADIUS
    local rMin, rMax = range[1], range[2]
    if p.radiusMin ~= nil then
        if not (IsNum(p.radiusMin) and p.radiusMin > 0 and p.radiusMin <= 2000) then
            return nil, 'err.invalid_payload'
        end
        rMin = p.radiusMin
    end
    if p.radiusMax ~= nil then
        if not (IsNum(p.radiusMax) and p.radiusMax >= rMin and p.radiusMax <= 2000) then
            return nil, 'err.invalid_payload'
        end
        rMax = p.radiusMax
    end
    if p.radius ~= nil and not (IsNum(p.radius) and p.radius > 0 and p.radius <= 2000) then
        return nil, 'err.invalid_payload'
    end
    if o.kind == 'start' or o.kind == 'area' then
        o.radius = Clamp(p.radius or range[3], rMin, rMax)
        o.radiusMin, o.radiusMax = rMin, rMax
    elseif p.radius ~= nil then
        o.showRadius = p.radius   -- a marker's circle (e.g. a search area) is only drawn, never returned
    end
    if p.start ~= nil then
        o.start = VecOf(p.start)
        if not o.start then return nil, 'err.invalid_payload' end
        o.start.w = nil
    end
    local others = VecList(p.otherStarts, MAX_LOCATIONS)
    if not others then return nil, 'err.invalid_payload' end
    o.otherStarts = others
    if p.minGap ~= nil then
        if not (IsNum(p.minGap) and p.minGap >= 0 and p.minGap <= 2000) then return nil, 'err.invalid_payload' end
        o.minGap = p.minGap
    end
    return o
end

function B.parseRecord(p)
    local o = Common(p)
    if not o then return nil, 'err.invalid_payload' end
    if p.stops ~= nil and type(p.stops) ~= 'boolean' then return nil, 'err.invalid_payload' end
    if p.loop ~= nil and type(p.loop) ~= 'boolean' then return nil, 'err.invalid_payload' end
    if p.block ~= nil and type(p.block) ~= 'string' then return nil, 'err.invalid_payload' end
    o.stops = p.stops == true
    if p.stops == nil and p.block ~= nil then o.stops = p.block == 'escort' end
    o.loop = p.loop == true
    return o
end

function B.parseTestDrive(p)
    local o = Common(p)
    if not o then return nil, 'err.invalid_payload' end
    local route = p.route
    if type(route) ~= 'table' then return nil, 'err.invalid_payload' end
    local pts = VecList(route.points, MAX_ROUTE_POINTS)
    if not pts or #pts < 2 then return nil, 'err.invalid_payload' end
    for _, v in ipairs(pts) do v.w = nil end
    o.points = pts
    o.stops = {}
    if route.stops ~= nil then
        if type(route.stops) ~= 'table' or #route.stops > MAX_ROUTE_POINTS then return nil, 'err.invalid_payload' end
        for _, s in ipairs(route.stops) do
            if type(s) ~= 'table' or not IsInt(s.at) or s.at < 1 or s.at > #pts or not IsNum(s.wait) or s.wait < 0
                or s.wait > STOP_WAIT_MAX then
                return nil, 'err.invalid_payload'
            end
            o.stops[#o.stops + 1] = { at = s.at, wait = s.wait }
        end
    end
    o.loop = route.loop == true
    local allowed = Config.Builder and Config.Builder.allowed or {}
    if type(p.vehicle) ~= 'string'
        or not (InAllowed(allowed.escortVehicles, p.vehicle) or InAllowed(allowed.vehicles, p.vehicle)) then
        return nil, 'err.builder_bad_vehicle'
    end
    o.vehicle = p.vehicle
    if not (IsNum(p.speed) and p.speed >= SPEED_RANGE[1] and p.speed <= SPEED_RANGE[2]) then
        return nil, 'err.invalid_payload'
    end
    o.speed = p.speed
    if p.style ~= nil and (type(p.style) ~= 'string' or #p.style > 20) then return nil, 'err.invalid_payload' end
    o.style = STYLES[p.style] and p.style or 'normal'
    return o
end

-- ============================================================================
--                                RUNTIME STATE
-- ============================================================================

local state = {
    tool = nil,     -- { kind, opts, cancel, noReopen, entities, zones, blips, waypointSet }
    result = nil,   -- the last result, until the NUI reads it
    seq = 0,
}

local function IsForeignArena(v)
    return type(v) == 'table' and v.active == true and v.source ~= 'crimson-police'
end

local function InForeignArena()
    local st = LocalPlayer and LocalPlayer.state
    return IsForeignArena(st and st.crimsonArena)
end

local function OnRun()
    return CP.Runs ~= nil and CP.Runs.current ~= nil and CP.Runs.current() ~= nil
end

local function BuilderCfg() return Config.Builder or {} end
local function RouteCfg() return BuilderCfg().route or {} end

local function Notify(kind, key, vars)
    if CP.Tablet and CP.Tablet.notify then CP.Tablet.notify(kind, CP.L(key, vars)) end
end

local function Overlay(o)
    if CP.Tablet and CP.Tablet.overlay then CP.Tablet.overlay(o) end
end

local function Sound(ok)
    PlaySoundFrontend(-1, ok and 'SELECT' or 'ERROR', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
end

local function LoadModel(hash)
    if not IsModelInCdimage(hash) then return false end
    RequestModel(hash)
    local deadline = GetGameTimer() + MODEL_TIMEOUT_MS
    while not HasModelLoaded(hash) do
        if GetGameTimer() > deadline then return false end
        Wait(10)
    end
    return true
end

local function deleteEntity(e)
    if e and e ~= 0 and DoesEntityExist(e) then
        SetEntityAsMissionEntity(e, true, true)
        DeleteEntity(e)
    end
end

local function RemoveZones(tool)
    for _, z in ipairs(tool.zones) do
        pcall(function() z:remove() end)
    end
    tool.zones = {}
end

local function AddZone(tool, c, r)
    if not (lib and lib.zones and lib.zones.sphere) then return end
    local ok, z = pcall(lib.zones.sphere, {
        coords = vector3(c.x + 0.0, c.y + 0.0, c.z + 0.0),
        radius = r + 0.0,
        debug = true,
        name = ('crimson-police:builder:%d'):format(#tool.zones + 1),
    })
    if ok and z then tool.zones[#tool.zones + 1] = z end
end

local function CleanupTool(tool)
    for _, e in ipairs(tool.entities) do deleteEntity(e) end
    tool.entities = {}
    RemoveZones(tool)
    for _, b in ipairs(tool.blips) do
        if DoesBlipExist(b) then RemoveBlip(b) end
    end
    tool.blips = {}
    if tool.waypointSet then
        SetWaypointOff()
        tool.waypointSet = false
    end
    Overlay(nil)
end

local function DisableControls(list)
    for i = 1, #list do DisableControlAction(0, list[i], true) end
end

local function Pressed(...)
    for i = 1, select('#', ...) do
        if IsDisabledControlJustPressed(0, (select(i, ...))) then return true end
    end
    return false
end

local function Marker(kind, x, y, z, sx, sy, sz, c, alpha)
    DrawMarker(kind, x, y, z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, sx, sy, sz, c[1], c[2], c[3], alpha, false, false, 2, false,
        nil, nil, false)
end

local function Line(a, b, c, alpha)
    DrawLine(a.x, a.y, a.z, b.x, b.y, b.z, c[1], c[2], c[3], alpha)
end

local function Text3d(x, y, z, s)
    SetDrawOrigin(x, y, z, 0)
    SetTextScale(0.0, 0.32)
    SetTextFont(4)
    SetTextCentre(true)
    SetTextOutline()
    SetTextColour(255, 255, 255, 230)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(s)
    EndTextCommandDisplayText(0.0, 0.0)
    ClearDrawOrigin()
end

local function HeadingLine(p, h, len, c)
    local fx, fy = HeadingDir(h)
    DrawLine(p.x, p.y, p.z + 0.1, p.x + fx * len, p.y + fy * len, p.z + 0.1, c[1], c[2], c[3], 220)
end

local function DrawNoBuildZones(pos)
    for _, z in ipairs(BuilderCfg().noBuildZones or {}) do
        local r = tonumber(z.radius) or 0
        if z.coords and U.dist2d(pos, z.coords) - r < ZONE_DRAW_RANGE then
            Marker(1, z.coords.x, z.coords.y, z.coords.z - 20.0, r * 2.0, r * 2.0, 60.0, COLOURS.zone, 45)
        end
    end
end

-- The point the gameplay camera aims at: hit, x, y, z, normalZ.
local function Aim(ignore)
    local cam = GetGameplayCamCoord()
    local rot = GetGameplayCamRot(2)
    local rx, rz = math.rad(rot.x), math.rad(rot.z)
    local c = math.abs(math.cos(rx))
    local dx, dy, dz = -math.sin(rz) * c, math.cos(rz) * c, math.sin(rx)
    local handle = StartExpensiveSynchronousShapeTestLosProbe(cam.x, cam.y, cam.z, cam.x + dx * RAY_DISTANCE,
        cam.y + dy * RAY_DISTANCE, cam.z + dz * RAY_DISTANCE, 1 + 16, ignore, 7)
    local _, hit, coords, normal = GetShapeTestResult(handle)
    if not (hit == 1 or hit == true) or not coords then return false end
    return true, coords.x, coords.y, coords.z, normal and normal.z or 1.0
end

local function InWater(x, y, z, groundZ)
    local hitWater = TestProbeAgainstWater(x, y, z + 2.0, x, y, z - 1.5)
    if hitWater == true or hitWater == 1 then return true end
    local found, height = GetWaterHeight(x, y, z + 2.0)
    if (found == true or found == 1) and IsNum(height) and height > (groundZ or z) + 0.1 then return true end
    return false
end

local function DefaultModel(kind)
    local allowed = BuilderCfg().allowed or {}
    if kind == 'ped' then return (allowed.peds or {})[1] or 'a_m_m_business_01' end
    return (allowed.vehicles or {})[1] or 'sultan'
end

local function NewResult(tool, cancelled)
    local o = tool.opts
    return {
        kind = tool.kind,
        missionId = o.missionId,
        location = o.location,
        key = o.key,
        cancelled = cancelled == true,
    }
end

-- The ARENA_CHECK_MS check of every tool: a foreign arena value, death or a mission run stops the tool.
local function Interrupted()
    if InForeignArena() then B.cancel('arena') return true end
    if IsEntityDead(PlayerPedId()) then B.cancel('dead') return true end
    if OnRun() then
        -- a unit member is put on the run the leader drew: the tool's controls and HUD would fight the run's
        B.cancel('run')
        Notify('warning', 'builder.tool_stopped_run')
        return true
    end
    return false
end

-- ============================================================================
--                                PLACEMENT TOOL
-- ============================================================================
-- A finished capsule probe still describes the spot when the aim moved less than this.
local function ProbeMatches(pr, x, y, z, h)
    return pr ~= nil and pr.blocked ~= nil and math.abs(pr.x - x) <= 0.35 and math.abs(pr.y - y) <= 0.35
        and math.abs(pr.z - z) <= 0.5 and AngleDiff(pr.h, h) <= 5.0
end

local function CreateGhost(tool, kind, name)
    local hash = joaat(name)
    if not IsModelInCdimage(hash) then return nil end
    if kind == 'ped' and not IsModelAPed(hash) then return nil end
    if kind == 'vehicle' and not IsModelAVehicle(hash) then return nil end
    if not LoadModel(hash) then return nil end
    local pos = GetEntityCoords(PlayerPedId())
    local ent
    if kind == 'ped' then
        ent = CreatePed(4, hash, pos.x, pos.y, pos.z - 50.0, 0.0, false, false)
    else
        ent = CreateVehicle(hash, pos.x, pos.y, pos.z - 50.0, 0.0, false, false)
    end
    if not ent or ent == 0 then
        SetModelAsNoLongerNeeded(hash)
        return nil
    end
    tool.entities[#tool.entities + 1] = ent
    SetEntityAlpha(ent, 160, false)
    SetEntityCollision(ent, false, false)
    FreezeEntityPosition(ent, true)
    SetEntityInvincible(ent, true)
    SetEntityVisible(ent, false, false)
    if kind == 'ped' then
        SetBlockingOfNonTemporaryEvents(ent, true)
        SetPedCanRagdoll(ent, false)
    else
        SetVehicleDoorsLocked(ent, 2)
        SetVehicleEngineOn(ent, false, true, true)
    end
    local dims = { lift = 0.0, half = 0.4, r = 0.32, midZ = 1.1 }
    if kind == 'vehicle' then
        local mn, mx = GetModelDimensions(hash)
        if mn and mx then
            local width = mx.x - mn.x
            local length = mx.y - mn.y
            local height = mx.z - mn.z
            dims.lift = Clamp(-mn.z, 0.2, 1.5)
            dims.half = math.max(0.5, length / 2.0)
            dims.midZ = math.max(0.6, height / 2.0 + 0.15)
            dims.r = Clamp(math.min(width / 2.0 * 0.8, 1.0), 0.3, dims.midZ - 0.2)
        else
            dims = { lift = 0.5, half = 2.3, r = 0.8, midZ = 1.0 }
        end
    end
    SetModelAsNoLongerNeeded(hash)
    return ent, dims
end

-- Capsule shape test around the volume a ped / vehicle would occupy at the spot.
local function StartProbe(kind, x, y, gz, h, dims, ignore)
    if kind == 'ped' then
        return StartShapeTestCapsule(x, y, gz + 0.45, x, y, gz + 1.7, 0.32, 1 + 2 + 16, ignore, 7)
    end
    local fx, fy = HeadingDir(h)
    local a = math.max(0.1, dims.half - dims.r)
    local zc = gz + dims.midZ
    return StartShapeTestCapsule(x + fx * a, y + fy * a, zc, x - fx * a, y - fy * a, zc, dims.r, 1 + 2 + 16, ignore, 7)
end

local function PlacementOverlay(tool, st, ok, reasonKey, vars)
    local o = tool.opts
    return {
        kind = 'placement',
        key = o.key,
        label = o.label or o.key,
        mode = o.kind,
        placed = #st.points,
        min = o.min,
        max = o.max,
        multiple = o.multiple,
        valid = ok == true,
        reason = (not ok and reasonKey) and CP.L(reasonKey, vars) or false,
        heading = o.heading and math.floor(st.heading + 0.5) % 360 or false,
        radius = (o.kind == 'start' or o.kind == 'area') and math.floor(st.radius + 0.5) or false,
    }
end

local function RefreshAreaZones(tool, st)
    local o = tool.opts
    RemoveZones(tool)
    if o.kind == 'start' or o.kind == 'area' then
        for _, p in ipairs(st.points) do AddZone(tool, p, st.radius) end
    end
    if o.spawn and o.start then AddZone(tool, o.start, tonumber(BuilderCfg().minSpawnFromStart) or 30.0) end
end

local function DrawPlaced(tool, st, pos)
    local o = tool.opts
    for i, p in ipairs(st.points) do
        if U.dist(pos, p) < POINT_DRAW_RANGE then
            local baseZ = p.z
            if o.kind == 'ped' then baseZ = p.z - PED_HEIGHT end
            Marker(0, p.x, p.y, baseZ + 1.4, 0.35, 0.35, 0.35, COLOURS.point, 200)
            Marker(25, p.x, p.y, baseZ + 0.05, 1.0, 1.0, 1.0, COLOURS.point, 150)
            if o.heading and p.w then HeadingLine({ x = p.x, y = p.y, z = baseZ }, p.w, 1.4, COLOURS.point) end
            if U.dist(pos, p) < LABEL_RANGE then Text3d(p.x, p.y, baseZ + 1.9, tostring(i)) end
        end
    end
    if o.start and U.dist(pos, o.start) < POINT_DRAW_RANGE * 2 then
        Marker(4, o.start.x, o.start.y, o.start.z + 1.5, 1.2, 1.2, 1.2, COLOURS.start, 220)
        if U.dist(pos, o.start) < LABEL_RANGE * 2 then
            Text3d(o.start.x, o.start.y, o.start.z + 2.6, CP.L('builder.place.start_label'))
        end
    end
    for _, s in ipairs(o.otherStarts) do
        if U.dist(pos, s) < POINT_DRAW_RANGE * 2 then
            Marker(4, s.x, s.y, s.z + 1.5, 1.0, 1.0, 1.0, COLOURS.bad, 180)
        end
    end
end

-- The street name at each placed point (kerb spots of field_contact's parked mode), in point order.
local function StreetsOf(points)
    local out = {}
    for i, p in ipairs(points) do
        local hash = GetStreetNameAtCoord(p.x + 0.0, p.y + 0.0, p.z + 0.0)
        local name = hash and GetStreetNameFromHashKey(hash) or ''
        out[i] = type(name) == 'string' and name or ''
    end
    return out
end

local function RunPlacement(tool)
    local o = tool.opts
    local bc = BuilderCfg()
    local st = {
        points = {},
        heading = NormHeading(GetEntityHeading(PlayerPedId())),
        radius = o.radius or 0.0,
        probe = nil,
        probeFor = nil,
        probeAt = 0,
        probed = nil,
        overlayAt = 0,
        arenaAt = 0,
    }
    for i, p in ipairs(o.points) do st.points[i] = p end
    local ghost, dims
    if o.kind == 'ped' or o.kind == 'vehicle' then
        ghost, dims = CreateGhost(tool, o.kind, o.model or DefaultModel(o.kind))
        if not dims then
            dims = o.kind == 'ped' and { lift = 0.0, half = 0.4, r = 0.32, midZ = 1.1 }
                or { lift = 0.5, half = 2.3, r = 0.8, midZ = 1.0 }
        end
    end
    RefreshAreaZones(tool, st)
    local ctx = {
        kind = o.kind,
        points = st.points,
        multiple = o.multiple,
        max = o.max,
        zones = bc.noBuildZones or {},
        spawn = o.spawn,
        start = o.start,
        minFromStart = tonumber(bc.minSpawnFromStart) or 30.0,
        otherStarts = o.otherStarts,
        minLocationGap = tonumber(bc.minLocationGap) or 100.0,
        minGap = o.minGap,
        maxDistance = MAX_PLACE_DISTANCE,
    }
    local function finish(cancelled)
        local r = NewResult(tool, cancelled)
        r.points = st.points
        if o.kind == 'start' or o.kind == 'area' then r.radius = Round2(st.radius) end
        if o.streets then r.streets = StreetsOf(st.points) end
        return r
    end
    Overlay(PlacementOverlay(tool, st, false, 'builder.place.reason.no_hit'))
    while true do
        if tool.cancel then return finish(true) end
        local now = GetGameTimer()
        if now - st.arenaAt >= ARENA_CHECK_MS then
            st.arenaAt = now
            if Interrupted() then return finish(true) end
        end
        DisableControls(PLACE_DISABLE)
        local ped = PlayerPedId()
        local pos = GetEntityCoords(ped)
        local veh = GetVehiclePedIsIn(ped, false)
        local hit, hx, hy, hz, nz = Aim(veh ~= 0 and veh or ped)
        local spot = nil
        local storeZ = nil
        if hit then
            local found, gz = GetGroundZFor_3dCoord(hx, hy, hz + 1.0, false)
            local groundZ = (found == true or found == 1) and gz or nil
            spot = {
                hit = true,
                x = hx,
                y = hy,
                z = hz,
                groundZ = groundZ,
                normalZ = nz,
                distance = U.dist(pos, { x = hx, y = hy, z = hz }),
            }
            spot.water = InWater(hx, hy, hz, groundZ)
            local baseZ = groundZ or hz
            if o.kind == 'ped' then
                storeZ = baseZ + PED_HEIGHT
            elseif o.kind == 'vehicle' then
                storeZ = baseZ + dims.lift
            elseif o.kind == 'marker' then
                storeZ = hz
            else
                storeZ = baseZ
            end
            spot.stored = RoundVec({ x = hx, y = hy, z = storeZ })
            if o.kind == 'ped' or o.kind == 'vehicle' then
                if ProbeMatches(st.probed, hx, hy, baseZ, st.heading) then
                    spot.blocked = st.probed.blocked
                elseif not st.probe and now - st.probeAt >= PROBE_GAP_MS then
                    st.probe = StartProbe(o.kind, hx, hy, baseZ, st.heading, dims, veh ~= 0 and veh or ped)
                    st.probeFor = { x = hx, y = hy, z = baseZ, h = st.heading }
                    st.probeAt = now
                end
            end
        end
        if st.probe then
            local status, blockedHit = GetShapeTestResult(st.probe)
            if status == 2 then
                st.probeFor.blocked = blockedHit == 1 or blockedHit == true
                st.probed = st.probeFor
                st.probe = nil
                if spot and spot.blocked == nil
                    and ProbeMatches(st.probed, spot.x, spot.y, spot.groundZ or spot.z, st.heading) then
                    spot.blocked = st.probed.blocked
                end
            elseif status == 0 then
                st.probe = nil
            end
        end
        local ok, reasonKey, vars = B.checkSpot(spot, ctx)

        -- ghost and drawing
        if ghost and DoesEntityExist(ghost) then
            if spot then
                SetEntityCoordsNoOffset(ghost, spot.x, spot.y, storeZ, false, false, false)
                SetEntityHeading(ghost, st.heading)
                SetEntityVisible(ghost, true, false)
            else
                SetEntityVisible(ghost, false, false)
            end
        end
        DrawNoBuildZones(pos)
        DrawPlaced(tool, st, pos)
        if spot then
            local c = ok and COLOURS.ok or COLOURS.bad
            local gz = spot.groundZ or spot.z
            if o.kind == 'start' or o.kind == 'area' then
                Marker(1, spot.x, spot.y, gz - 1.0, st.radius * 2.0, st.radius * 2.0, 3.0, c, 70)
                Marker(25, spot.x, spot.y, gz + 0.05, 2.0, 2.0, 2.0, c, 200)
            elseif o.kind == 'marker' then
                Marker(0, spot.x, spot.y, spot.z + 1.0, 0.4, 0.4, 0.4, c, 220)
                Marker(25, spot.x, spot.y, spot.z + 0.03, 0.9, 0.9, 0.9, c, 200)
                if o.showRadius then
                    Marker(1, spot.x, spot.y, spot.z - 1.0, o.showRadius * 2.0, o.showRadius * 2.0, 2.0, c, 45)
                end
            else
                local size = o.kind == 'vehicle' and math.max(3.0, dims.half * 2.2) or 1.4
                Marker(25, spot.x, spot.y, gz + 0.05, size, size, 1.0, c, 210)
            end
            if o.heading then
                HeadingLine({ x = spot.x, y = spot.y, z = gz }, st.heading, o.kind == 'vehicle' and 3.5 or 1.6, c)
            end
        end

        -- input
        local fine = IsDisabledControlPressed(0, C.SHIFT) or IsControlPressed(0, C.SHIFT)
        local dir = 0
        if Pressed(C.WHEEL_UP, C.CURSOR_UP) then dir = 1 elseif Pressed(C.WHEEL_DOWN, C.CURSOR_DOWN) then dir = -1 end
        if dir ~= 0 then
            if o.kind == 'start' or o.kind == 'area' then
                st.radius = Clamp(st.radius + dir * (fine and AREA_FINE or AREA_STEP), o.radiusMin, o.radiusMax)
                RefreshAreaZones(tool, st)
            elseif o.heading or o.kind == 'ped' or o.kind == 'vehicle' then
                st.heading = NormHeading(st.heading + dir * (fine and HEADING_FINE or HEADING_STEP))
            end
        end
        if Pressed(C.E, C.E_ALT) then
            if ok and spot then
                local p = RoundVec({ x = spot.x, y = spot.y, z = storeZ }, o.heading, st.heading)
                if o.multiple then
                    st.points[#st.points + 1] = p
                else
                    st.points = { p }
                    ctx.points = st.points
                end
                RefreshAreaZones(tool, st)
                Sound(true)
            else
                Sound(false)
            end
        end
        if Pressed(C.BACK) then
            if #st.points > 0 then
                st.points[#st.points] = nil
                RefreshAreaZones(tool, st)
                Sound(true)
            else
                Sound(false)
            end
        end
        if Pressed(C.ENTER, C.ENTER_ALT) then return finish(false) end
        if now - st.overlayAt >= OVERLAY_MS then
            st.overlayAt = now
            Overlay(PlacementOverlay(tool, st, ok, reasonKey, vars))
        end
        Wait(0)
    end
end

-- ============================================================================
--                               ROUTE RECORDING
-- ============================================================================

local function InZone(p)
    for _, z in ipairs(BuilderCfg().noBuildZones or {}) do
        if z.coords and U.dist2d(p, z.coords) <= (tonumber(z.radius) or 0) then return z end
    end
    return nil
end

local function NoPath(a, b)
    local d = CalculateTravelDistanceBetweenPoints(a.x, a.y, a.z, b.x, b.y, b.z)
    return not IsNum(d) or d >= NO_PATH
end

-- Waypoint indexes (1-based) with no road path to the next waypoint. known[i] is the check of segment i made while
-- it was driven; the others are checked now, a few per frame.
local function UnreachableOf(points, known)
    local out, calls = {}, 0
    for i = 1, #points - 1 do
        local missing = known and known[i]
        if missing == nil then
            missing = NoPath(points[i], points[i + 1])
            calls = calls + 1
            if calls % PATH_CHECKS_PER_FRAME == 0 then Wait(0) end
        end
        if missing then out[#out + 1] = i end
    end
    return out
end

local function RunRecording(tool)
    local o = tool.opts
    local r = RouteCfg()
    local esc = Config.Blocks and Config.Blocks.escort or {}
    local snapEvery = tonumber(r.snapEvery) or 25.0
    local maxOffRoad = tonumber(r.maxOffRoad) or 8.0
    local undoMetres = tonumber(r.undoMetres) or 100.0
    local maxStops = type(esc.stops) == 'table' and tonumber(esc.stops[2]) or 5
    local stopWait = type(esc.stopWait) == 'table' and tonumber(esc.stopWait[3]) or 20
    local rec = B.newRecorder({ turnAngle = tonumber(r.turnAngle) or 30.0, maxGap = tonumber(r.maxGap) or 150.0 })
    local st = {
        lastPos = nil,
        paused = false,
        resumeAt = nil,
        rejected = 0,
        rejectedSamples = {},
        offRoadUntil = 0,
        overlayAt = 0,
        arenaAt = 0,
        message = nil,
        messageUntil = 0,
        waiting = false,
        distance = false,
        seated = false,     -- in the driver seat last frame
        noPath = {},        -- [i] = segment i (waypoint i to i + 1) has no road path, checked while driven
    }
    local function say(key, vars)
        st.message = CP.L(key, vars)
        st.messageUntil = GetGameTimer() + MESSAGE_MS
    end
    -- Each new segment is checked while the player is next to it: the game streams path nodes around the player
    -- only, and CalculateTravelDistanceBetweenPoints fails (NO_PATH) where they are not loaded.
    local function checkPaths()
        local wps = rec.wps
        for i = #st.noPath + 1, #wps - 1 do st.noPath[i] = NoPath(rec.samples[wps[i]], rec.samples[wps[i + 1]]) end
    end
    local function sample(pos, veh)
        st.lastPos = pos
        local found, node = GetClosestVehicleNodeWithHeading(pos.x, pos.y, pos.z, 1, 3.0, 0)
        local d = (found == true or found == 1) and node and U.dist(node, pos) or math.huge
        local onRoad = d <= maxOffRoad
        if not onRoad and d <= maxOffRoad * ROAD_SURFACE_FACTOR then
            onRoad = IsPointOnRoad(pos.x, pos.y, pos.z, veh) == true
        end
        if not onRoad then
            st.rejected = st.rejected + 1
            if #st.rejectedSamples < MAX_REJECTED_SAMPLES then
                st.rejectedSamples[#st.rejectedSamples + 1] = {
                    x = Round2(pos.x),
                    y = Round2(pos.y),
                    z = Round2(pos.z),
                }
            end
            st.offRoadUntil = GetGameTimer() + MESSAGE_MS
            return
        end
        rec:add({ x = node.x, y = node.y, z = node.z })
    end
    local function buildOverlay(now)
        local wps = rec:waypoints()
        local first = wps[1]
        local last = wps[#wps]
        local zone = last and InZone(last) or nil
        local length = rec:length()
        return {
            kind = 'recording',
            key = o.key,
            label = o.label or o.key,
            length = math.floor(length + 0.5),
            points = #wps,
            samples = rec:count(),
            stops = #rec.stops,
            maxStops = maxStops,
            stopsEnabled = o.stops,
            paused = st.paused,
            offRoad = now < st.offRoadUntil,
            rejected = st.rejected,
            waiting = st.waiting,
            distance = st.distance,
            loop = o.loop,
            toStart = (o.loop and first and last and #wps > 2) and math.floor(U.dist2d(first, last) + 0.5) or false,
            zone = zone and tostring(zone.label) or false,
            tooLong = length > (tonumber(r.maxLength) or 8000.0),
            undoMetres = undoMetres,
            minLength = tonumber(r.minLength) or 800.0,
            maxLength = tonumber(r.maxLength) or 8000.0,
            message = (st.message and now < st.messageUntil) and st.message or false,
        }
    end
    local function finish(cancelled)
        local res = NewResult(tool, cancelled)
        local pts, stops, dropped = rec:finish()
        if #pts < 2 and not cancelled then
            res.cancelled = true
            Notify('warning', 'builder.rec.nothing')
        end
        res.route = { points = pts, stops = o.stops and stops or {} }
        if o.loop then res.route.loop = true end
        res.length = math.floor(B.routeLength(pts) + 0.5)
        res.rejected = st.rejected
        res.rejectedSamples = st.rejectedSamples
        res.droppedStops = dropped
        Overlay({
            kind = 'recording',
            key = o.key,
            label = o.label or o.key,
            length = res.length,
            points = #pts,
            samples = rec:count(),
            stops = #stops,
            maxStops = maxStops,
            stopsEnabled = o.stops,
            paused = false,
            offRoad = false,
            rejected = st.rejected,
            waiting = 'checking',
            distance = false,
            loop = o.loop,
            toStart = false,
            zone = false,
            tooLong = false,
            undoMetres = undoMetres,
            minLength = tonumber(r.minLength) or 800.0,
            maxLength = tonumber(r.maxLength) or 8000.0,
            message = CP.L('builder.rec.checking'),
        })
        res.unreachable = (#pts >= 2 and not res.cancelled) and UnreachableOf(pts, st.noPath) or {}
        return res
    end
    while true do
        if tool.cancel then return finish(true) end
        local now = GetGameTimer()
        if now - st.arenaAt >= ARENA_CHECK_MS then
            st.arenaAt = now
            if Interrupted() then return finish(true) end
        end
        DisableControls(RECORD_DISABLE)
        local ped = PlayerPedId()
        local veh = GetVehiclePedIsIn(ped, false)
        local driving = veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped
        st.waiting, st.distance = false, false
        if not driving then
            st.waiting = 'vehicle'
            st.seated = false
        else
            local pos = GetEntityCoords(veh)
            if not st.seated then
                -- back in a driver seat away from the end (walked off, another car): drive back to the end first
                st.seated = true
                local e = rec:endPoint()
                if e and not st.resumeAt and U.dist2d(pos, e) > snapEvery * 2.0 then st.resumeAt = e end
            end
            if st.resumeAt then
                local d = U.dist2d(pos, st.resumeAt)
                if d <= snapEvery then
                    st.resumeAt = nil
                    st.lastPos = pos
                else
                    st.waiting = 'return'
                    st.distance = math.floor(d + 0.5)
                end
            elseif not st.paused then
                if not st.lastPos or U.dist(pos, st.lastPos) >= snapEvery then sample(pos, veh) end
            end
            -- the recording so far, near the player
            local wps = rec:waypoints()
            for i = 1, #wps do
                local p = wps[i]
                if U.dist(pos, p) < POINT_DRAW_RANGE then
                    Marker(28, p.x, p.y, p.z + 0.5, 0.6, 0.6, 0.6, COLOURS.route, 170)
                    if i > 1 then
                        Line({ x = wps[i - 1].x, y = wps[i - 1].y, z = wps[i - 1].z + 0.5 },
                            { x = p.x, y = p.y, z = p.z + 0.5 }, COLOURS.route, 200)
                    end
                end
            end
            for _, s in ipairs(rec.stops) do
                local p = wps[s.at]
                if p and U.dist(pos, p) < POINT_DRAW_RANGE then
                    Marker(1, p.x, p.y, p.z - 0.5, 4.0, 4.0, 1.5, COLOURS.start, 110)
                end
            end
            for _, p in ipairs(st.rejectedSamples) do
                if U.dist(pos, p) < POINT_DRAW_RANGE then
                    Marker(28, p.x, p.y, p.z + 0.5, 0.5, 0.5, 0.5, COLOURS.rejected, 170)
                end
            end
            if st.resumeAt then
                Marker(1, st.resumeAt.x, st.resumeAt.y, st.resumeAt.z - 1.0, snapEvery * 2.0, snapEvery * 2.0, 4.0,
                    COLOURS.resume, 90)
            end
            if o.loop and #wps > 2 and U.dist(pos, wps[1]) < POINT_DRAW_RANGE * 2 then
                local f = wps[1]
                local lc = tonumber(r.loopClose) or 50.0
                Marker(1, f.x, f.y, f.z - 1.0, lc * 2.0, lc * 2.0, 3.0, COLOURS.ok, 70)
            end
        end
        -- keys
        if Pressed(C.E, C.E_ALT, C.HORN) then
            if not o.stops then
                say('builder.rec.stops_off')
                Sound(false)
            elseif not driving or st.resumeAt then
                say('builder.rec.stop_drive')
                Sound(false)
            else
                local okStop, why = rec:addStop(stopWait, maxStops)
                if okStop then
                    say('builder.rec.stop_added', { n = #rec.stops, wait = stopWait })
                else
                    say(why, { max = maxStops })
                end
                Sound(okStop)
            end
        end
        if Pressed(C.BACK) then
            local removed = rec:undo(undoMetres)
            if removed > 0 then
                st.resumeAt = rec:endPoint()
                st.lastPos = nil
                for i = #st.noPath, #rec.wps, -1 do st.noPath[i] = nil end
                say('builder.rec.undone', { metres = math.floor(removed + 0.5) })
                Sound(true)
            else
                say('builder.rec.nothing_to_undo')
                Sound(false)
            end
        end
        if Pressed(C.P) then
            st.paused = not st.paused
            if not st.paused then
                -- on foot too: the next driving frame must not sample away from the end
                local e = rec:endPoint()
                local pedNow = PlayerPedId()
                local vehNow = GetVehiclePedIsIn(pedNow, false)
                local here = GetEntityCoords(vehNow ~= 0 and vehNow or pedNow)
                if e and U.dist2d(here, e) > snapEvery * 2.0 then st.resumeAt = e end
                st.lastPos = nil
            end
            say(st.paused and 'builder.rec.paused_msg' or 'builder.rec.resumed_msg')
            Sound(true)
        end
        if Pressed(C.X) then return finish(false) end
        checkPaths()
        if now - st.overlayAt >= OVERLAY_MS then
            st.overlayAt = now
            Overlay(buildOverlay(now))
        end
        Wait(0)
    end
end

-- ============================================================================
--                                  TEST DRIVE
-- ============================================================================

local function RunTestDrive(tool)
    local o = tool.opts
    local pts = o.points
    local n = #pts
    local failed = {}
    local timeoutMs = math.max(5, tonumber(RouteCfg().testDriveTimeout) or 30) * 1000
    local st = {
        overlayAt = 0,
        arenaAt = 0,
        waypoint = 1,
        waiting = false,
        distance = false,
        timeLeft = false,
        stopLeft = false,
    }
    local function show(now, force, done)
        if not force and now - st.overlayAt < OVERLAY_MS then return end
        st.overlayAt = now
        Overlay({
            kind = 'testdrive',
            key = o.key,
            label = o.label or o.key,
            waypoint = st.waypoint,
            total = n,
            failed = failed,
            timeLeft = st.timeLeft,
            stopLeft = st.stopLeft,
            waiting = st.waiting,
            distance = st.distance,
            speed = o.speed,
            done = done == true,
        })
    end
    local function finish(completed, cancelled)
        local res = NewResult(tool, cancelled)
        res.completed = completed == true
        res.failed = failed
        return res
    end
    local function guard(now)
        if tool.cancel then return true end
        if now - st.arenaAt >= ARENA_CHECK_MS then
            st.arenaAt = now
            if Interrupted() then return true end
        end
        DisableControls(DRIVE_DISABLE)
        if Pressed(C.X) then
            tool.cancel = 'stopped'
            return true
        end
        return false
    end
    local function drawRoute(pos, current)
        for i = 1, n do
            local p = pts[i]
            if U.dist(pos, p) < POINT_DRAW_RANGE * 2 then
                local bad = false
                for _, f in ipairs(failed) do if f == i then bad = true end end
                local c = bad and COLOURS.failed or (i < current and COLOURS.done or COLOURS.route)
                Marker(28, p.x, p.y, p.z + 0.5, 0.7, 0.7, 0.7, c, 180)
                if i > 1 then
                    Line({ x = pts[i - 1].x, y = pts[i - 1].y, z = pts[i - 1].z + 0.5 },
                        { x = p.x, y = p.y, z = p.z + 0.5 }, c, 200)
                end
            end
        end
    end

    -- 1. get close to the route start
    if U.dist2d(GetEntityCoords(PlayerPedId()), pts[1]) > APPROACH_RADIUS then
        SetNewWaypoint(pts[1].x + 0.0, pts[1].y + 0.0)
        tool.waypointSet = true
        Notify('info', 'builder.drive.approach_toast')
        while true do
            local now = GetGameTimer()
            if guard(now) then return finish(false, true) end
            local d = U.dist2d(GetEntityCoords(PlayerPedId()), pts[1])
            if d <= APPROACH_RADIUS then break end
            st.waiting, st.distance = 'approach', math.floor(d + 0.5)
            show(now)
            Wait(0)
        end
        SetWaypointOff()
        tool.waypointSet = false
    end
    -- 2. keep the spawn point clear
    while U.dist(GetEntityCoords(PlayerPedId()), pts[1]) < CLEAR_RADIUS do
        local now = GetGameTimer()
        if guard(now) then return finish(false, true) end
        st.waiting, st.distance = 'clear', false
        show(now)
        Wait(0)
    end
    -- 3. spawn the local vehicle and driver
    st.waiting = 'spawning'
    show(GetGameTimer(), true)
    local vehHash = joaat(o.vehicle)
    if not IsModelAVehicle(vehHash) or not LoadModel(vehHash) then
        Notify('error', 'err.builder_bad_vehicle')
        return finish(false, true)
    end
    local drvHash = joaat(DRIVER_MODEL)
    if not IsModelInCdimage(drvHash) then drvHash = joaat(DRIVER_FALLBACK) end
    if not LoadModel(drvHash) then
        SetModelAsNoLongerNeeded(vehHash)
        Notify('error', 'builder.tool_failed')
        return finish(false, true)
    end
    local veh = CreateVehicle(vehHash, pts[1].x, pts[1].y, pts[1].z + 0.5, headingOf(pts[1], pts[2]), false, false)
    if not veh or veh == 0 then
        SetModelAsNoLongerNeeded(vehHash)
        SetModelAsNoLongerNeeded(drvHash)
        Notify('error', 'builder.tool_failed')
        return finish(false, true)
    end
    tool.entities[#tool.entities + 1] = veh
    SetEntityAsMissionEntity(veh, true, true)
    SetVehicleOnGroundProperly(veh)
    SetVehicleDoorsLocked(veh, 2)
    SetVehicleEngineOn(veh, true, true, false)
    local driver = CreatePedInsideVehicle(veh, 4, drvHash, -1, false, false)
    SetModelAsNoLongerNeeded(vehHash)
    SetModelAsNoLongerNeeded(drvHash)
    if not driver or driver == 0 then
        Notify('error', 'builder.tool_failed')
        return finish(false, true)
    end
    tool.entities[#tool.entities + 1] = driver
    SetEntityAsMissionEntity(driver, true, true)
    SetBlockingOfNonTemporaryEvents(driver, true)
    SetPedKeepTask(driver, true)
    SetEntityInvincible(driver, true)
    SetPedCanBeDraggedOut(driver, false)
    SetDriverAbility(driver, 1.0)
    SetDriverAggressiveness(driver, 0.3)
    local blip = AddBlipForEntity(veh)
    if blip and blip ~= 0 then
        tool.blips[#tool.blips + 1] = blip
        SetBlipSprite(blip, 225)
        SetBlipColour(blip, 3)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(CP.L('builder.drive.blip'))
        EndTextCommandSetBlipName(blip)
    end
    -- 4. drive waypoint by waypoint
    local speed = o.speed / 3.6
    local style = B.drivingStyle(o.style)
    local arrive = math.max(12.0, speed * 1.2)
    local waits = {}
    for _, s in ipairs(o.stops) do waits[s.at] = s.wait end
    st.waiting = false
    for i = 2, n do
        st.waypoint = i
        local target = pts[i]
        local last = i == n
        local radius = last and 10.0 or arrive
        TaskVehicleDriveToCoordLongrange(driver, veh, target.x, target.y, target.z, speed, style,
            last and 4.0 or radius)
        local deadline = GetGameTimer() + timeoutMs
        local slowSince = nil
        local reached = false
        while true do
            local now = GetGameTimer()
            if guard(now) then return finish(false, true) end
            if not DoesEntityExist(veh) or not DoesEntityExist(driver) or IsEntityDead(driver)
                or not IsVehicleDriveable(veh, false) then
                for j = i, n do failed[#failed + 1] = j end
                Notify('warning', 'builder.drive.wrecked')
                st.timeLeft = false
                show(now, true, true)
                return finish(false, false)
            end
            local vp = GetEntityCoords(veh)
            if U.dist2d(vp, target) <= radius then
                reached = true
                break
            end
            if now >= deadline then
                failed[#failed + 1] = i
                break
            end
            if GetEntitySpeed(veh) < 0.5 then
                slowSince = slowSince or now
                if now - slowSince >= STUCK_MS then
                    TaskVehicleDriveToCoordLongrange(driver, veh, target.x, target.y, target.z, speed, style,
                        last and 4.0 or radius)
                    slowSince = now
                end
            else
                slowSince = nil
            end
            st.timeLeft = math.max(0, math.ceil((deadline - now) / 1000))
            drawRoute(GetEntityCoords(PlayerPedId()), i)
            show(now)
            Wait(0)
        end
        local wait = waits[i]
        if reached and wait and wait > 0 and not last then
            TaskVehicleTempAction(driver, veh, 27, math.floor(wait * 1000))
            local untilMs = GetGameTimer() + wait * 1000
            while GetGameTimer() < untilMs do
                local now = GetGameTimer()
                if guard(now) then return finish(false, true) end
                st.stopLeft = math.max(0, math.ceil((untilMs - now) / 1000))
                st.timeLeft = false
                drawRoute(GetEntityCoords(PlayerPedId()), i + 1)
                show(now)
                Wait(0)
            end
            st.stopLeft = false
        end
    end
    TaskVehicleTempAction(driver, veh, 27, 3000)
    st.timeLeft, st.stopLeft = false, false
    local doneUntil = GetGameTimer() + DONE_SHOW_MS
    show(GetGameTimer(), true, true)
    while GetGameTimer() < doneUntil do
        if tool.cancel then break end
        Wait(0)
    end
    return finish(true, false)
end

-- ============================================================================
--                                TOOL LIFECYCLE
-- ============================================================================

local function Refusal()
    if BuilderCfg().enabled == false then return 'err.builder_disabled' end
    if InForeignArena() then return 'err.in_arena' end
    if state.tool then return 'err.builder_busy' end
    if IsEntityDead(PlayerPedId()) then return 'err.builder_dead' end
    if OnRun() then return 'err.builder_on_run' end
    return nil
end

local function Deliver(tool, result)
    -- also after an unload or a deletion: the cancelled result clears the NUI's "tool running" memory
    state.seq = state.seq + 1
    result.seq = state.seq
    state.result = result
    if CP.Tablet and CP.Tablet.push then
        CP.Tablet.push('builder', { event = 'clientResult', id = result.missionId, result = result })
    end
    if tool.noReopen then return end
    CreateThread(function()
        Wait(300)
        if InForeignArena() or IsEntityDead(PlayerPedId()) then return end
        if not (CP.Tablet and CP.Tablet.open) then return end
        if CP.Tablet.isOpen and CP.Tablet.isOpen() then return end
        CP.Tablet.open(tool.opts.ui or 'supervisor')
    end)
end

local function StartTool(kind, opts, runner)
    local why = Refusal()
    if why then return false, why end
    local tool = { kind = kind, opts = opts, entities = {}, zones = {}, blips = {}, waypointSet = false }
    state.tool = tool
    CP.log(TAG, '%s started for %s location %d key %s', kind, opts.missionId, opts.location, opts.key)
    CreateThread(function()
        Wait(0)
        if CP.Tablet and CP.Tablet.close then CP.Tablet.close() end
        local ok, result = pcall(runner, tool)
        CleanupTool(tool)
        if not ok or type(result) ~= 'table' then
            CP.err(TAG, '%s tool failed: %s', kind, tostring(result))
            result = NewResult(tool, true)
            if kind == 'placement' then result.points = opts.points end
            if kind == 'recording' then
                result.route = { points = {}, stops = {} }
                result.length, result.rejected, result.rejectedSamples, result.unreachable = 0, 0, {}, {}
            end
            if kind == 'testdrive' then result.completed, result.failed = false, {} end
            Notify('error', 'builder.tool_failed')
        end
        if state.tool == tool then state.tool = nil end
        CP.log(TAG, '%s ended (cancelled = %s)', kind, tostring(result.cancelled))
        Deliver(tool, result)
    end)
    return true, { started = true }
end

function B.active()
    return state.tool and state.tool.kind or nil
end

function B.cancel(reason)
    local tool = state.tool
    if not tool then return false end
    tool.cancel = reason or 'cancelled'
    if NO_REOPEN[reason] then tool.noReopen = true end
    return true
end

-- ============================================================================
--              CLIENT ACTIONS AND EVENTS (registered at runtime)
-- ============================================================================

local function RegisterActions()
    local T = CP.Tablet
    if not (T and T.registerClientAction) then
        CP.err(TAG, 'CP.Tablet.registerClientAction is missing: the Mission Builder tools are unavailable')
        return
    end
    T.registerClientAction('builderPlace', function(payload)
        local o, err = B.parsePlace(payload)
        if not o then return false, err end
        return StartTool('placement', o, RunPlacement)
    end)
    T.registerClientAction('builderRecord', function(payload)
        local o, err = B.parseRecord(payload)
        if not o then return false, err end
        return StartTool('recording', o, RunRecording)
    end)
    T.registerClientAction('builderTestDrive', function(payload)
        local o, err = B.parseTestDrive(payload)
        if not o then return false, err end
        local hash = joaat(o.vehicle)
        if not IsModelInCdimage(hash) or not IsModelAVehicle(hash) then return false, 'err.builder_bad_vehicle' end
        return StartTool('testdrive', o, RunTestDrive)
    end)
    T.registerClientAction('builderResult', function()
        local r = state.result
        state.result = nil
        return true, r
    end)
    T.registerClientAction('builderCancel', function()
        return true, { cancelled = B.cancel('ui') }
    end)
    T.registerClientAction('builderWaypoint', function(payload)
        local c = type(payload) == 'table' and VecOf(payload.coords) or nil
        if not c then return false, 'err.invalid_payload' end
        if InForeignArena() then return false, 'err.in_arena' end
        SetNewWaypoint(c.x, c.y)
        return true, { ok = true }
    end)
end

RegisterNetEvent(CP.e('client:builder'), function(data)
    if type(data) ~= 'table' or type(data.id) ~= 'string' then return end
    local ev = data.event
    if ev ~= 'lockBroken' and ev ~= 'reloaded' and ev ~= 'deleted' then return end
    local tool = state.tool
    if tool and tool.opts.missionId == data.id then
        B.cancel(ev)
        CP.log(TAG, 'the %s of %s stopped: %s', tool.kind, data.id, ev)
    end
    if ev == 'deleted' and state.result and state.result.missionId == data.id then state.result = nil end
    -- The open builder screen learns it lost the lock / the draft even when the server's 'builder' push did not
    -- reach it (it only goes to recent viewers); the screen's handlers are idempotent.
    if (ev == 'lockBroken' or ev == 'reloaded') and CP.Tablet and CP.Tablet.push then
        CP.Tablet.push('builder', { event = ev, id = data.id, by = type(data.by) == 'string' and data.by or nil })
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= CP.resource then return end
    local tool = state.tool
    if tool then
        tool.cancel = 'stop'
        tool.noReopen = true
        CleanupTool(tool)
    end
end)

CreateThread(function()
    RegisterActions()
    local bag = ('player:%d'):format(GetPlayerServerId(PlayerId()))
    AddStateBagChangeHandler('crimsonArena', bag, function(_, _, value)
        -- only queue work: the bag still holds the old value while the handler runs
        if IsForeignArena(value) then SetTimeout(0, function() B.cancel('arena') end) end
    end)
    if CP.Qbx and CP.Qbx.onUnload then
        CP.Qbx.onUnload(function()
            B.cancel('unload')
            state.result = nil
        end)
    end
end)
