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
    DELETE = 178,
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
    178,
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
        ver = 0,        -- grows on every change to what waypoints() returns or to the stops (the draw cache key)
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
    self.ver = self.ver + 1
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
    if count < n then self.ver = self.ver + 1 end
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
    self.ver = self.ver + 1
    return true
end

-- The recorded waypoints and the stops on interior waypoints (a stop on the first or last one is dropped).
function Recorder:finish()
    local n = #self.samples
    if n > 0 then Keep(self, n) end
    self.ver = self.ver + 1
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

-- Metres an armed spawn point keeps from the start (ctx.armed with ctx.startRadius, the start circle): the circle plus
-- ctx.spawnMargin, never less than ctx.minFromStart; nil for any other point.
function B.armedKeepOut(ctx)
    if not (type(ctx) == 'table' and ctx.armed and IsNum(ctx.startRadius)) then return nil end
    return math.max(tonumber(ctx.minFromStart) or 0, ctx.startRadius + (tonumber(ctx.spawnMargin) or 0))
end

-- Metres the placement tool aims within to pick a placed point (Delete, Backspace).
B.AIM_PICK_RANGE = 1.5

-- Index of the placed point nearest to the aimed spot (2D, the point as stored), within range metres; nil when none.
function B.aimedPoint(points, spot, range)
    if type(points) ~= 'table' or type(spot) ~= 'table' or not spot.hit then return nil end
    range = tonumber(range) or B.AIM_PICK_RANGE
    local best, bestD = nil, range
    for i, p in ipairs(points) do
        local d = U.dist2d(spot, p)
        if d <= bestD then best, bestD = i, d end
    end
    return best
end

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
    -- armed spawns (shootout, boss, ambush and pursuit cars, door associates): outside the start circle plus
    -- Config.Builder.spawnMargin, 2D (the server's CP.Builder.armedKeepOut)
    local armedMin = B.armedKeepOut(ctx)
    if armedMin and ctx.start and U.dist2d(at, ctx.start) < armedMin then
        return false, 'builder.place.reason.armed', { min = math.floor(armedMin + 0.5) }
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
    for _, f in ipairs({ 'heading', 'multiple', 'spawn', 'armed', 'streets' }) do
        if p[f] ~= nil and type(p[f]) ~= 'boolean' then return nil, 'err.invalid_payload' end
    end
    o.streets = p.streets == true          -- kerb spots: the result names the street at each point
    o.heading = p.heading == true and o.kind ~= 'area' and o.kind ~= 'start'
    o.multiple = p.multiple == true and o.kind ~= 'start'
    o.spawn = p.spawn == true
    o.armed = o.spawn and p.armed == true  -- armed spawns keep outside the start circle plus the margin
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
    if p.startRadius ~= nil then
        if not (IsNum(p.startRadius) and p.startRadius >= 0 and p.startRadius <= 2000) then
            return nil, 'err.invalid_payload'
        end
        o.startRadius = p.startRadius
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

-- Metres every point of this key keeps from the start (the circle drawn as a zone); nil when the key has no start rule.
local function KeepOutOf(o)
    if not (o.spawn and o.start) then return nil end
    local bc = BuilderCfg()
    local floor = tonumber(bc.minSpawnFromStart) or 30.0
    -- an armed key shows its real keep-out: the start circle plus the margin
    return B.armedKeepOut({
        armed = o.armed,
        startRadius = o.startRadius,
        minFromStart = floor,
        spawnMargin = tonumber(bc.spawnMargin) or 40.0,
    }) or floor
end

local function PlacementOverlay(tool, st, ok, reasonKey, vars)
    local o = tool.opts
    local keepOut = KeepOutOf(o)
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
        keepOut = keepOut and math.floor(keepOut + 0.5) or false,
        armed = o.armed == true,
        aimed = st.aimed or false,
    }
end

local function RefreshAreaZones(tool, st)
    local o = tool.opts
    RemoveZones(tool)
    if o.kind == 'start' or o.kind == 'area' then
        for _, p in ipairs(st.points) do AddZone(tool, p, st.radius) end
    end
    local keepOut = KeepOutOf(o)
    if keepOut then AddZone(tool, o.start, keepOut) end
end

local function DrawPlaced(tool, st, pos)
    local o = tool.opts
    for i, p in ipairs(st.points) do
        if U.dist(pos, p) < POINT_DRAW_RANGE then
            local baseZ = p.z
            if o.kind == 'ped' then baseZ = p.z - PED_HEIGHT end
            -- the point under the aim (Delete removes it) is drawn red
            local c = st.aimed == i and COLOURS.bad or COLOURS.point
            Marker(0, p.x, p.y, baseZ + 1.4, 0.35, 0.35, 0.35, c, 200)
            Marker(25, p.x, p.y, baseZ + 0.05, 1.0, 1.0, 1.0, c, 150)
            if o.heading and p.w then HeadingLine({ x = p.x, y = p.y, z = baseZ }, p.w, 1.4, c) end
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

-- The B.checkSpot rules of a placement (parsePlace options), with the points placed so far.
local function PlaceCtx(o, points)
    local bc = BuilderCfg()
    return {
        kind = o.kind,
        points = points,
        multiple = o.multiple,
        max = o.max,
        zones = bc.noBuildZones or {},
        spawn = o.spawn,
        start = o.start,
        minFromStart = tonumber(bc.minSpawnFromStart) or 30.0,
        armed = o.armed,
        startRadius = o.startRadius,
        spawnMargin = tonumber(bc.spawnMargin) or 40.0,
        otherStarts = o.otherStarts,
        minLocationGap = tonumber(bc.minLocationGap) or 100.0,
        minGap = o.minGap,
        maxDistance = MAX_PLACE_DISTANCE,
    }
end

local function RunPlacement(tool)
    local o = tool.opts
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
    local ctx = PlaceCtx(o, st.points)
    local function finish(cancelled)
        local r = NewResult(tool, cancelled)
        -- a cancelled tool (X, the tablet, an interruption) hands back the points it was given, unchanged
        local pts = st.points
        if cancelled then
            pts = {}
            for i, p in ipairs(o.points) do pts[i] = p end
        end
        r.points = pts
        if o.kind == 'start' or o.kind == 'area' then
            r.radius = Round2(cancelled and (o.radius or 0.0) or st.radius)
        end
        if o.streets then r.streets = StreetsOf(pts) end
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
        local ped = cache.ped
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
        st.aimed = B.aimedPoint(st.points, spot)

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
        -- Delete removes the point under the aim; Backspace too, else the last point
        local del, back = Pressed(C.DELETE), Pressed(C.BACK)
        if del or back then
            local idx = st.aimed or (back and #st.points > 0 and #st.points) or nil
            if idx then
                table.remove(st.points, idx)
                st.aimed = nil
                RefreshAreaZones(tool, st)
                Sound(true)
            else
                Sound(false)
            end
        end
        if Pressed(C.X) then return finish(true) end
        if Pressed(C.ENTER, C.ENTER_ALT) then return finish(false) end
        if now - st.overlayAt >= OVERLAY_MS then
            st.overlayAt = now
            Overlay(PlacementOverlay(tool, st, ok, reasonKey, vars))
        end
        Wait(0)
    end
end

-- ============================================================================
--                        USE MY POSITION (builderHere)
-- ============================================================================
-- Ms a capsule probe of the spot may take before builderHere answers.
local HERE_PROBE_MS = 500

-- Lift and capsule size of a vehicle model (as the ghost measures it); the defaults when the model is unknown.
local function VehicleDims(name)
    local hash = joaat(name)
    if IsModelInCdimage(hash) and IsModelAVehicle(hash) then
        local mn, mx = GetModelDimensions(hash)
        if mn and mx then
            local height = mx.z - mn.z
            local midZ = math.max(0.6, height / 2.0 + 0.15)
            return {
                lift = Clamp(-mn.z, 0.2, 1.5),
                half = math.max(0.5, (mx.y - mn.y) / 2.0),
                midZ = midZ,
                r = Clamp(math.min((mx.x - mn.x) / 2.0 * 0.8, 1.0), 0.3, midZ - 0.2),
            }
        end
    end
    return { lift = 0.5, half = 2.3, r = 0.8, midZ = 1.0 }
end

-- Config.Builder.useMyPosition: the spot where the player stands, or his vehicle is, checked like an aimed spot
-- (B.checkSpot) and stored at the height the placement tool stores. Answers { ok, reason, point, result } at once:
-- result is a placement result with the point added (multiple) or set; the tablet stays open.
local function Here(o)
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    local ent = veh ~= 0 and veh or ped
    local pos = GetEntityCoords(ent)
    local heading = NormHeading(GetEntityHeading(ent))
    local found, gz = GetGroundZFor_3dCoord(pos.x, pos.y, pos.z + 1.0, false)
    local groundZ = (found == true or found == 1) and gz or nil
    local baseZ = groundZ or pos.z
    local spot = { hit = true, x = pos.x, y = pos.y, z = baseZ, groundZ = groundZ, distance = 0.0 }
    local swimming = IsEntityInWater(ent)
    spot.water = swimming == true or swimming == 1 or InWater(pos.x, pos.y, baseZ, groundZ)
    local dims = o.kind == 'vehicle' and VehicleDims(o.model or DefaultModel('vehicle')) or nil
    local storeZ = baseZ
    if o.kind == 'ped' then storeZ = baseZ + PED_HEIGHT elseif o.kind == 'vehicle' then storeZ = baseZ + dims.lift end
    spot.stored = RoundVec({ x = pos.x, y = pos.y, z = storeZ })
    if o.kind == 'ped' or o.kind == 'vehicle' then
        -- the player's own vehicle is not in the way of the point it stands on
        local probe = StartProbe(o.kind, pos.x, pos.y, baseZ, heading, dims, ent)
        local deadline = GetGameTimer() + HERE_PROBE_MS
        while probe do
            local status, blockedHit = GetShapeTestResult(probe)
            if status == 2 then
                spot.blocked = blockedHit == 1 or blockedHit == true
                break
            end
            if status == 0 or GetGameTimer() >= deadline then break end
            Wait(0)
        end
    end
    local ok, reasonKey, vars = B.checkSpot(spot, PlaceCtx(o, o.points))
    local point = RoundVec({ x = pos.x, y = pos.y, z = storeZ }, o.heading, heading)
    local reply = { ok = ok == true, reason = (not ok and reasonKey) and CP.L(reasonKey, vars) or false, point = point }
    if not ok then return reply end
    local pts = {}
    if o.multiple then
        for i, p in ipairs(o.points) do pts[i] = p end
    end
    pts[#pts + 1] = point
    local r = NewResult({ kind = 'placement', opts = o }, false)
    r.points = pts
    if o.kind == 'start' or o.kind == 'area' then r.radius = Round2(o.radius or 0.0) end
    if o.streets then r.streets = StreetsOf(pts) end
    reply.result = r
    return reply
end

-- ============================================================================
--                  FILL THE POINTS FOR ME (builderAutoPoints)
-- ============================================================================
-- Config.Builder.autoFill: the client proposes a key's spawn points on a ring around the start, beyond its keep-out.
local AUTO_TRIES_PER_POINT = 12             -- spots tried for each point asked for
local AUTO_MAX_TRIES = 240                  -- and never more than this in one fill
local AUTO_MIN_GAP = 3.0                    -- metres between two proposed points of a key with no spacing rule
local AUTO_NEAR = 250.0                     -- metres: the player stands this close to the anchor (the game only has
                                            -- the ground and the paths near him)
local AUTO_MS = 20000                       -- a fill stops looking after this long
local AUTO_PED_FLAGS = 4 + 8                -- GetSafeCoordForPed: no navmesh inside a building, none in water
local AUTO_RING = { 15.0, 80.0 }            -- Config.Builder.autoFillRing when it is missing or broken

-- Inner and outer metres from the anchor that a fill tries spots at: the key's keep-out (the start circle plus the
-- margin for armed spawns, minSpawnFromStart for other spawns, the start circle for any other key) plus
-- Config.Builder.autoFillRing.
function B.autoRing(o, ring)
    ring = type(ring) == 'table' and ring or AUTO_RING
    local near, far = tonumber(ring[1]) or AUTO_RING[1], tonumber(ring[2]) or AUTO_RING[2]
    near = math.max(0.0, near)
    if far < near then far = near end
    local keepOut = KeepOutOf(o) or tonumber(o.startRadius) or 0.0
    return keepOut + near, keepOut + far
end

-- The pure fill: up to count new points for the placement options o (B.parsePlace, with o.start), each one a spot
-- on the ring (B.autoRing) that deps.snap puts on safe ground, that deps.probe (CP.Spawn.probe's answer) finds ok or
-- snaps onto the ground, and that passes B.checkSpot with the points already there and the ones proposed before it
-- (no-build zones, the keep-out, the spacing: the key's minGap, else AUTO_MIN_GAP). deps = { snap(kind, x, y, z) ->
-- { x, y, z (the ground), h? } or nil, probe(kind, x, y, z, h) -> { status, z, groundZ, normalZ, wall }, lift (the
-- stored height over the ground), random() -> [0, 1), ring, timeUp() -> true to stop }. Returns { added (the new
-- points, in order), points (the old ones and the new), tries, dropped }.
function B.autoFill(o, count, deps)
    deps = deps or {}
    local anchor = o.anchor or o.start
    local points = {}
    for i, p in ipairs(o.points or {}) do points[i] = p end
    local out = { added = {}, points = points, tries = 0, dropped = 0 }
    if not anchor then return out end
    local want = math.min(math.max(0, math.floor(tonumber(count) or 0)), (o.max or MAX_POINTS) - #points)
    local inner, outer = B.autoRing(o, deps.ring)
    local ctx = PlaceCtx(o, points)
    ctx.multiple = true
    ctx.maxDistance = nil
    if not (IsNum(ctx.minGap) and ctx.minGap > 0) then ctx.minGap = AUTO_MIN_GAP end
    local random = deps.random or math.random
    local lift = tonumber(deps.lift) or 0.0
    local face = o.start or anchor
    local maxTries = math.min(AUTO_MAX_TRIES, want * AUTO_TRIES_PER_POINT)
    local turn = random() * 360.0
    while #out.added < want and out.tries < maxTries do
        out.tries = out.tries + 1
        -- the golden angle spreads the tries round the ring; the distance is even over the ring's area
        local a = math.rad(turn + out.tries * 137.508 + random() * 20.0)
        local d = math.sqrt(inner * inner + (outer * outer - inner * inner) * random())
        local spot = nil
        local s = deps.snap and deps.snap(o.kind, anchor.x - math.sin(a) * d, anchor.y + math.cos(a) * d, anchor.z)
        if s and IsNum(s.x) and IsNum(s.y) and IsNum(s.z) then
            local h = (o.kind == 'vehicle' and IsNum(s.h)) and s.h or headingOf(s, face)
            local storeZ = s.z + lift
            local pr = deps.probe and deps.probe(o.kind, s.x, s.y, storeZ, h) or nil
            if pr and (pr.status == 'ok' or pr.status == 'snap') then
                if pr.status == 'snap' and IsNum(pr.z) then storeZ = pr.z end
                local gz = IsNum(pr.groundZ) and pr.groundZ or s.z
                spot = {
                    hit = true,
                    x = s.x,
                    y = s.y,
                    z = gz,
                    groundZ = gz,
                    normalZ = pr.normalZ,
                    distance = 0.0,
                    water = pr.water == true,
                    blocked = pr.wall == true,
                    stored = RoundVec({ x = s.x, y = s.y, z = storeZ }),
                    h = h,
                }
            end
        end
        if spot and B.checkSpot(spot, ctx) then
            local p = RoundVec(spot.stored, o.heading, spot.h)
            points[#points + 1] = p
            out.added[#out.added + 1] = p
        else
            out.dropped = out.dropped + 1
        end
        if deps.timeUp and deps.timeUp() then break end
    end
    return out
end

-- The game's side of a fill: a ped spot on the navmesh near it (GetSafeCoordForPed), a vehicle spot at the side of
-- the nearest road (its node's heading), each on the ground there.
local function AutoSnap(kind, x, y, z)
    local found, gz = GetGroundZFor_3dCoord(x + 0.0, y + 0.0, z + 50.0, false)
    local baseZ = (found == true or found == 1) and gz or z
    local sx, sy, sz, h
    if kind == 'vehicle' then
        local ok, node, nodeH = GetClosestVehicleNodeWithHeading(x + 0.0, y + 0.0, baseZ + 0.0, 1, 3.0, 0)
        if not (ok == true or ok == 1) or not node then return nil end
        sx, sy, sz, h = node.x, node.y, node.z, nodeH
        local side, at = GetPointOnRoadSide(node.x, node.y, node.z, -1)
        if (side == true or side == 1) and at then sx, sy, sz = at.x, at.y, at.z end
    else
        local ok, at = GetSafeCoordForPed(x + 0.0, y + 0.0, baseZ + 1.0, true, AUTO_PED_FLAGS)
        if not (ok == true or ok == 1) or not at then return nil end
        sx, sy, sz = at.x, at.y, at.z
    end
    local onGround, groundZ = GetGroundZFor_3dCoord(sx + 0.0, sy + 0.0, sz + 2.0, false)
    return { x = sx, y = sy, z = (onGround == true or onGround == 1) and groundZ or sz, h = h }
end

local autoBusy = false

-- builderAutoPoints: { ok, reason, wanted, proposed, result }. proposed: the new points; result: a placement result
-- with the points already there and the proposed ones, the screen applies it only when the builder keeps them.
local function AutoPoints(o, count)
    local reply = { ok = false, reason = false, wanted = count, proposed = {} }
    local anchor = o.anchor or o.start
    local pos = GetEntityCoords(PlayerPedId())
    if U.dist2d(pos, anchor) > AUTO_NEAR then
        reply.reason = CP.L('builder.auto.too_far', { m = math.floor(AUTO_NEAR) })
        return reply
    end
    local bc = BuilderCfg()
    local model = o.model or DefaultModel(o.kind)
    local lift = o.kind == 'vehicle' and VehicleDims(model).lift or PED_HEIGHT
    local Spawn = CP.Spawn
    local deadline = GetGameTimer() + AUTO_MS
    local filled = B.autoFill(o, count, {
        ring = bc.autoFillRing,
        lift = lift,
        snap = AutoSnap,
        probe = function(kind, x, y, z, h)
            if not (Spawn and Spawn.probe) then return { status = 'ok' } end
            return Spawn.probe(kind, x, y, z, h, model)
        end,
        timeUp = function() return GetGameTimer() >= deadline end,
    })
    CP.log(TAG, 'fill of %s location %d key %s: %d of %d points, %d spots tried, %d dropped', o.missionId, o.location,
        o.key, #filled.added, count, filled.tries, filled.dropped)
    reply.proposed = filled.added
    if #filled.added == 0 then
        reply.reason = CP.L('builder.auto.none')
        return reply
    end
    reply.ok = true
    if #filled.added < count then
        reply.reason = CP.L('builder.auto.short', { n = #filled.added, want = count })
    end
    local r = NewResult({ kind = 'placement', opts = o }, false)
    r.points = filled.points
    if o.streets then r.streets = StreetsOf(filled.points) end
    reply.result = r
    return reply
end

-- The builderAutoPoints payload: the builderPlace one (a ped or vehicle key with many points and a start), with
-- count (points to add) and an optional anchor (the ring's centre, the start when missing).
function B.parseAutoPoints(p)
    local o, err = B.parsePlace(p)
    if not o then return nil, err end
    if (o.kind ~= 'ped' and o.kind ~= 'vehicle') or not o.multiple then return nil, 'err.invalid_payload' end
    if not (IsInt(p.count) and p.count >= 1 and p.count <= MAX_POINTS) then return nil, 'err.invalid_payload' end
    if p.anchor ~= nil then
        o.anchor = VecOf(p.anchor)
        if not o.anchor then return nil, 'err.invalid_payload' end
        o.anchor.w = nil
    end
    if not o.start then return nil, 'err.builder_auto_start' end
    return o, p.count
end

-- ============================================================================
--              MOVE THE WHOLE LOCATION HERE (builderCheckPoints)
-- ============================================================================
-- "Move the whole location here" (Config.Builder.useMyPosition): the start goes where the player stands (builderHere)
-- and every point of the location moves by the same offset. This action moves the points, puts each one back on the
-- ground there and checks it again; the screen lists the ones that fail.
local MOVE_MS = 20000                       -- the check stops looking after this long
local MOVE_MAX_KEYS = 40                    -- point lists one location may send
local MOVE_GROUND_OVER = 3.0                -- metres over the moved point the ground is looked for first
local MOVE_GROUND_HIGH = 50.0               -- then from this high (the new place lies higher)
local MOVE_REASON = {                       -- CP.Spawn.probe statuses, in the placement tool's words
    in_water = 'builder.place.reason.water',
    in_wall = 'builder.place.reason.blocked',
    no_ground = 'builder.place.reason.not_ground',
    underground = 'builder.place.reason.not_ground',
    floating = 'builder.place.reason.not_ground',
    interior_not_loaded = 'builder.move.reason.interior',
}

-- The pure move and check. o = { start, startRadius, offset, keys = { { key, kind, model, heading, spawn, armed,
-- minGap, route, points } } } (B.parseCheckPoints). Every point of every key moves by o.offset. A route (a path the
-- mission travels along) only moves. Any other point is put on the ground there (deps.ground(x, y, z) -> the ground
-- z or nil; stored deps.lift(kind, model) over it, a marker on it), judged by deps.probe (CP.Spawn.probe's answer: ok,
-- or snap onto the ground) and B.checkSpot with the key's points checked before it (no-build zones, water, ground,
-- room, the keep-out, the spacing). deps.timeUp() -> true leaves the points not yet checked as failed. Returns
-- { keys = { { key, points, failed = { { index, reasonKey, vars } }, checked } }, moved, failed }.
function B.checkPoints(o, deps)
    deps = deps or {}
    local d = o.offset
    local out = { keys = {}, moved = 0, failed = 0 }
    local late = false
    for _, k in ipairs(o.keys) do
        local res = { key = k.key, points = {}, failed = {}, checked = not k.route }
        local ctx = PlaceCtx({
            kind = k.kind,
            multiple = true,
            spawn = k.spawn,
            start = o.start,
            armed = k.armed,
            startRadius = o.startRadius,
            minGap = k.minGap,
            otherStarts = {},
        }, {})
        ctx.max, ctx.maxDistance = nil, nil
        local lift = deps.lift and deps.lift(k.kind, k.model) or 0.0
        for i, p in ipairs(k.points) do
            local x, y, z = p.x + d.x, p.y + d.y, p.z + d.z
            local moved = { x = x, y = y, z = z, w = p.w }
            local reasonKey, vars = nil, nil
            if not k.route then
                late = late or (deps.timeUp and deps.timeUp()) == true
                local gz = (not late and deps.ground) and deps.ground(x, y, z) or nil
                if late then
                    reasonKey = 'builder.move.reason.time'
                elseif not IsNum(gz) then
                    reasonKey = 'builder.place.reason.not_ground'
                else
                    local storeZ = gz + ((k.kind == 'ped' or k.kind == 'vehicle') and lift or 0.0)
                    moved.z = storeZ
                    local pr = deps.probe and deps.probe(k.kind, x, y, storeZ, p.w or 0.0, k.model) or { status = 'ok' }
                    if pr.status == 'ok' or pr.status == 'snap' then
                        if pr.status == 'snap' and IsNum(pr.z) then moved.z = pr.z end
                        local ground = IsNum(pr.groundZ) and pr.groundZ or gz
                        local spot = {
                            hit = true,
                            x = x,
                            y = y,
                            z = ground,
                            groundZ = ground,
                            normalZ = pr.normalZ,
                            distance = 0.0,
                            water = pr.water == true,
                            blocked = pr.wall == true,
                            stored = { x = x, y = y, z = moved.z },
                        }
                        local ok, key, v = B.checkSpot(spot, ctx)
                        if not ok then reasonKey, vars = key, v end
                    else
                        reasonKey = MOVE_REASON[pr.status] or 'builder.place.reason.not_ground'
                    end
                end
            end
            local stored = RoundVec(moved, moved.w ~= nil, moved.w)
            res.points[i] = stored
            if reasonKey then
                res.failed[#res.failed + 1] = { index = i, reasonKey = reasonKey, vars = vars }
            elseif not k.route then
                ctx.points[#ctx.points + 1] = stored
            end
        end
        out.moved = out.moved + #res.points
        out.failed = out.failed + #res.failed
        out.keys[#out.keys + 1] = res
    end
    return out
end

-- The builderCheckPoints payload: { missionId, location, ui?, start (where the start is now), startRadius?,
-- offset (how far it moved), keys = { { key, kind, model?, heading?, spawn?, armed?, minGap?, route?, points } } }.
function B.parseCheckPoints(p)
    if type(p) ~= 'table' then return nil, 'err.invalid_payload' end
    local o = Common({ missionId = p.missionId, location = p.location, key = 'start', ui = p.ui })
    if not o then return nil, 'err.invalid_payload' end
    o.start = VecOf(p.start)
    o.offset = VecOf(p.offset)
    if not (o.start and o.offset) then return nil, 'err.invalid_payload' end
    o.start.w, o.offset.w = nil, nil
    if p.startRadius ~= nil then
        if not (IsNum(p.startRadius) and p.startRadius >= 0 and p.startRadius <= 2000) then
            return nil, 'err.invalid_payload'
        end
        o.startRadius = p.startRadius
    end
    if type(p.keys) ~= 'table' or #p.keys > MOVE_MAX_KEYS then return nil, 'err.invalid_payload' end
    o.keys = {}
    for i, k in ipairs(p.keys) do
        if type(k) ~= 'table' or not ValidKey(k.key) then return nil, 'err.invalid_payload' end
        local route = k.route == true
        local kind = k.kind
        if not route and not KINDS[kind] then return nil, 'err.invalid_payload' end
        if k.model ~= nil and (type(k.model) ~= 'string' or #k.model > 64 or not k.model:match(MODEL_PATTERN)) then
            return nil, 'err.invalid_payload'
        end
        if k.minGap ~= nil and not (IsNum(k.minGap) and k.minGap >= 0 and k.minGap <= 2000) then
            return nil, 'err.invalid_payload'
        end
        local points = VecList(k.points, route and MAX_ROUTE_POINTS or MAX_POINTS)
        if not points then return nil, 'err.invalid_payload' end
        o.keys[i] = {
            key = k.key,
            kind = route and 'marker' or kind,
            model = k.model,
            spawn = k.spawn == true,
            armed = k.spawn == true and k.armed == true,
            minGap = k.minGap,
            route = route,
            points = points,
        }
    end
    return o
end

local moveBusy = false

-- The game's side of a move: the ground under the moved point (from a little over it, else from high over it).
local function MoveGround(x, y, z)
    RequestCollisionAtCoord(x + 0.0, y + 0.0, z + 0.0)
    for _, over in ipairs({ MOVE_GROUND_OVER, MOVE_GROUND_HIGH }) do
        local found, gz = GetGroundZFor_3dCoord(x + 0.0, y + 0.0, z + over, false)
        if (found == true or found == 1) and IsNum(gz) then return gz end
    end
    return nil
end

-- builderCheckPoints: { ok, reason, moved, failed, keys = { { key, points, failed = { { index, reason } }, checked } } }.
-- reason: why nothing was checked (the player is far from the start), in words, else false.
local function CheckPoints(o)
    local reply = { ok = false, reason = false, moved = 0, failed = 0, keys = {} }
    local pos = GetEntityCoords(PlayerPedId())
    if U.dist2d(pos, o.start) > AUTO_NEAR then
        reply.reason = CP.L('builder.auto.too_far', { m = math.floor(AUTO_NEAR) })
        return reply
    end
    local Spawn = CP.Spawn
    local deadline = GetGameTimer() + MOVE_MS
    local r = B.checkPoints(o, {
        ground = MoveGround,
        lift = function(kind, model)
            if kind == 'vehicle' then return VehicleDims(model or DefaultModel('vehicle')).lift end
            return PED_HEIGHT
        end,
        probe = function(kind, x, y, z, h, model)
            if not (Spawn and Spawn.probe) then return { status = 'ok' } end
            local m = kind == 'vehicle' and (model or DefaultModel('vehicle')) or model
            return Spawn.probe(kind, x, y, z, h, m)
        end,
        timeUp = function() return GetGameTimer() >= deadline end,
    })
    for _, k in ipairs(r.keys) do
        for _, f in ipairs(k.failed) do
            f.reason = CP.L(f.reasonKey, f.vars)
            f.reasonKey, f.vars = nil, nil
        end
    end
    CP.log(TAG, 'move of %s location %d: %d points moved, %d need a new spot', o.missionId, o.location, r.moved,
        r.failed)
    reply.ok, reply.moved, reply.failed, reply.keys = true, r.moved, r.failed, r.keys
    return reply
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
            local road = IsPointOnRoad(pos.x, pos.y, pos.z, veh)
            onRoad = road == true or road == 1
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
    -- rec:waypoints() builds a new list: it is rebuilt only when the recording changed (rec.ver), not every frame
    local wpsCache, wpsVer = {}, -1
    local function waypoints()
        if rec.ver ~= wpsVer then wpsCache, wpsVer = rec:waypoints(), rec.ver end
        return wpsCache
    end
    local function buildOverlay(now)
        local wps = waypoints()
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
        local ped = cache.ped
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
            local wps = waypoints()
            local px, py, pz = pos.x, pos.y, pos.z
            local r2 = POINT_DRAW_RANGE * POINT_DRAW_RANGE
            local rc = COLOURS.route
            for i = 1, #wps do
                local p = wps[i]
                local dx, dy, dz = p.x - px, p.y - py, p.z - pz
                if dx * dx + dy * dy + dz * dz < r2 then
                    Marker(28, p.x, p.y, p.z + 0.5, 0.6, 0.6, 0.6, rc, 170)
                    if i > 1 then
                        local q = wps[i - 1]
                        DrawLine(q.x, q.y, q.z + 0.5, p.x, p.y, p.z + 0.5, rc[1], rc[2], rc[3], 200)
                    end
                end
            end
            for _, s in ipairs(rec.stops) do
                local p = wps[s.at]
                if p then
                    local dx, dy, dz = p.x - px, p.y - py, p.z - pz
                    if dx * dx + dy * dy + dz * dz < r2 then
                        Marker(1, p.x, p.y, p.z - 0.5, 4.0, 4.0, 1.5, COLOURS.start, 110)
                    end
                end
            end
            for _, p in ipairs(st.rejectedSamples) do
                local dx, dy, dz = p.x - px, p.y - py, p.z - pz
                if dx * dx + dy * dy + dz * dz < r2 then
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
                local pedNow = cache.ped
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
    local failedSet = {}    -- [i] = true for every waypoint in failed (drawRoute reads it every frame)
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
    -- Runs every frame: squared distances and plain numbers, no new tables (up to MAX_ROUTE_POINTS points).
    local r2 = (POINT_DRAW_RANGE * 2) * (POINT_DRAW_RANGE * 2)
    local function drawRoute(pos, current)
        local px, py, pz = pos.x, pos.y, pos.z
        for i = 1, n do
            local p = pts[i]
            local dx, dy, dz = p.x - px, p.y - py, p.z - pz
            if dx * dx + dy * dy + dz * dz < r2 then
                local c = failedSet[i] and COLOURS.failed or (i < current and COLOURS.done or COLOURS.route)
                Marker(28, p.x, p.y, p.z + 0.5, 0.7, 0.7, 0.7, c, 180)
                if i > 1 then
                    local q = pts[i - 1]
                    DrawLine(q.x, q.y, q.z + 0.5, p.x, p.y, p.z + 0.5, c[1], c[2], c[3], 200)
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
            local d = U.dist2d(GetEntityCoords(cache.ped), pts[1])
            if d <= APPROACH_RADIUS then break end
            st.waiting, st.distance = 'approach', math.floor(d + 0.5)
            show(now)
            Wait(0)
        end
        SetWaypointOff()
        tool.waypointSet = false
    end
    -- 2. keep the spawn point clear
    while U.dist(GetEntityCoords(cache.ped), pts[1]) < CLEAR_RADIUS do
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
                for j = i, n do
                    failed[#failed + 1] = j
                    failedSet[j] = true
                end
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
                failedSet[i] = true
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
            drawRoute(GetEntityCoords(cache.ped), i)
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
                drawRoute(GetEntityCoords(cache.ped), i + 1)
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
--                           TELEPORT TO A POINT (B8)
-- ============================================================================
-- "Teleport" on the Locations step: the screen names the point ({ missionId, location, key, index }), the server
-- checks who may (Config.Builder.teleport, admins or a Config.Permissions.builderTeleport grant), audits it and sends
-- the stored coordinates back (client:builder:teleport); only an answer to the request under way is used. He is
-- put on the ground there as the test teleport does (fade, freeze, collision, ground find, unfreeze).
do
    local pending = nil   -- { missionId, location, key, index, coords? } while a request waits for its answer
    local moving = nil    -- { ent, frozen } during the move: a resource stop undoes the freeze and the fade

    local function GroundZ(x, y, z)
        for _, probe in ipairs({ 2.0, 25.0, 100.0 }) do
            for _ = 1, 10 do
                RequestCollisionAtCoord(x, y, z)
                local found, gz = GetGroundZFor_3dCoord(x, y, z + probe, false)
                if found and type(gz) == 'number' then return gz end
                Wait(50)
            end
        end
        return z
    end

    local function MoveTo(c)
        local ped = PlayerPedId()
        local veh = GetVehiclePedIsIn(ped, false)
        local ent = ped
        if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped then ent = veh end
        local mine = { ent = ent, frozen = false }
        moving = mine
        DoScreenFadeOut(300)
        local deadline = GetGameTimer() + 1500
        while not IsScreenFadedOut() and GetGameTimer() < deadline do Wait(0) end
        local ok, err = pcall(function()
            -- Crimson-Arena rule 13: checked again right before every move (the fade took time)
            if InForeignArena() then error('in_arena', 0) end
            FreezeEntityPosition(ent, true)
            mine.frozen = true
            SetEntityCoords(ent, c.x, c.y, c.z + 1.0, false, false, false, false)
            local gz = GroundZ(c.x, c.y, c.z)
            if InForeignArena() then error('in_arena', 0) end
            SetEntityCoords(ent, c.x, c.y, gz, false, false, false, false)
        end)
        -- the arena owns a ped it took meanwhile: leave its freeze to Crimson-Arena
        if mine.frozen and not (err == 'in_arena' and ent == ped) then FreezeEntityPosition(ent, false) end
        DoScreenFadeIn(300)
        if moving == mine then moving = nil end
        if ok then return true end
        if err == 'in_arena' then return false, 'err.in_arena' end
        CP.err(TAG, 'teleport failed: %s', tostring(err))
        return false, 'err.builder_teleport_failed'
    end

    -- The client action builderTeleport. Returns ok, data | errKey.
    function B.teleport(payload)
        if BuilderCfg().teleport == false then return false, 'err.builder_teleport_off' end
        local p = type(payload) == 'table' and payload or {}
        local li, index = math.tointeger(p.location), math.tointeger(p.index)
        if type(p.missionId) ~= 'string' or #p.missionId > 64 or not li or not index or type(p.key) ~= 'string'
            or #p.key > 40 then
            return false, 'err.invalid_payload'
        end
        local why = Refusal()
        if why then return false, why end
        if pending or moving then return false, 'err.builder_busy' end
        local mine = { missionId = p.missionId, location = li, key = p.key, index = index }
        pending = mine
        local res = CP.Net.action('server:builder:teleport',
            { missionId = mine.missionId, location = li, key = mine.key, index = index })
        -- the coordinates come in their own event, sent just before the answer
        local deadline = GetGameTimer() + 1000
        while type(res) == 'table' and res.ok and not mine.coords and GetGameTimer() < deadline do Wait(0) end
        if pending == mine then pending = nil end
        if type(res) ~= 'table' then return false, 'err.no_response' end
        if not res.ok then return false, res.error end
        if not mine.coords then return false, 'err.builder_teleport_failed' end
        why = Refusal()
        if why then return false, why end
        local ok, err = MoveTo(mine.coords)
        if not ok then return false, err end
        return true, { missionId = mine.missionId, location = li, key = mine.key, index = index }
    end

    -- Only the answer to the request under way is used; anything else is dropped.
    RegisterNetEvent(CP.e('client:builder:teleport'), function(data)
        local mine = pending
        if not mine or type(data) ~= 'table' or type(data.coords) ~= 'table' then return end
        if data.missionId ~= mine.missionId or data.location ~= mine.location or data.key ~= mine.key
            or data.index ~= mine.index then
            return
        end
        local x, y, z = tonumber(data.coords.x), tonumber(data.coords.y), tonumber(data.coords.z)
        if not (x and y and z) then return end
        mine.coords = { x = x + 0.0, y = y + 0.0, z = z + 0.0 }
    end)

    AddEventHandler('onResourceStop', function(res)
        if res ~= CP.resource or not moving then return end
        if moving.frozen then FreezeEntityPosition(moving.ent, false) end
        DoScreenFadeIn(0)
    end)
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
    T.registerClientAction('builderHere', function(payload)
        if BuilderCfg().useMyPosition == false then return false, 'err.builder_here_off' end
        local o, err = B.parsePlace(payload)
        if not o then return false, err end
        local why = Refusal()
        if why then return false, why end
        return true, Here(o)
    end)
    T.registerClientAction('builderAutoPoints', function(payload)
        if BuilderCfg().autoFill == false then return false, 'err.builder_auto_off' end
        local o, count = B.parseAutoPoints(payload)
        if not o then return false, count end
        local why = Refusal()
        if why then return false, why end
        if autoBusy or moveBusy then return false, 'err.builder_busy' end
        autoBusy = true
        local ok, reply = pcall(AutoPoints, o, count)
        autoBusy = false
        if not ok then
            CP.err(TAG, 'fill failed: %s', tostring(reply))
            return false, 'err.internal'
        end
        return true, reply
    end)
    T.registerClientAction('builderCheckPoints', function(payload)
        if BuilderCfg().useMyPosition == false then return false, 'err.builder_here_off' end
        local o, err = B.parseCheckPoints(payload)
        if not o then return false, err end
        local why = Refusal()
        if why then return false, why end
        if moveBusy or autoBusy then return false, 'err.builder_busy' end
        moveBusy = true
        local ok, reply = pcall(CheckPoints, o)
        moveBusy = false
        if not ok then
            CP.err(TAG, 'move check failed: %s', tostring(reply))
            return false, 'err.internal'
        end
        return true, reply
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
    T.registerClientAction('builderTeleport', B.teleport)
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
