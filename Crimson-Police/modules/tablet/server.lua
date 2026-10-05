-- CP.Tablet (server): sessions for the three UIs, toasts, live pushes, the Admin UI opener and the department logo
-- checks.

CP.Tablet = CP.Tablet or {}
local T = CP.Tablet
local TAG = 'tablet'

local UIS = { officer = true, supervisor = true, admin = true }
local KINDS = { info = true, success = true, warning = true, error = true }
local PERIODS = { 'weekly', 'monthly', 'season', 'alltime' }
local FILTER_EXTRAS = { 'unit', 'cross', 'department' }
local DEFAULT_THEME = {
    primary = '#a4161a',
    accent = '#e5383b',
    background = '#0b090a',
    surface = '#161a1d',
    text = '#f5f3f4',
}
local THEME_KEYS = { 'primary', 'accent', 'background', 'surface' }
local VIA = { command = true, keybind = true, item = true, export = true, desk = true, dispatch = true }
local AVATAR_KINDS = { initials = true, preset = true, url = true }
local DEFAULT_APPEARANCE = 'department'

local DESK_MARGIN = 2.0           -- metres around a desk box the server still accepts
local NAV_CACHE_S = 5             -- a src's badge counts are built again at most this often
local REVIEW_CACHE_S = 30         -- the Review Queue count reads the database: at most this often per src
local NAV_PUSH_DELAY_MS = 1000    -- pushes of one burst (a claim window, a unit change) become one 'nav' push
local NAV_WATCH_S = 600           -- 'nav' pushes go to a src that asked for its counts within this time
-- pushes that can change a badge; each one schedules a 'nav' push to that src
local NAV_TOPICS = { unit = true, invites = true, calls = true, profile = true, rewards = true, run = true }
-- way -> the Config.Tablet.access switch that allows it (export is always on)
local WAY_SWITCH = { command = 'command', keybind = 'keybind', dispatch = 'keybind', item = 'item', desk = 'desk' }

local missingLogo = {}         -- deptKey -> true when logos/<file> is not in the resource
local logoFailedWarned = {}    -- deptKey -> true once the NUI failure was reported
local themeWarned = {}
local lastWay = {}             -- src -> { via, desk } of the last session that passed the access checks
local navCache = {}            -- src -> { at, counts }
local reviewCache = {}         -- src -> { at, n }
local navWatch = {}            -- src -> os.time() of the last getNavCounts
local navPending = {}          -- src -> true while a 'nav' push is scheduled
local navExtra = {}            -- key -> { fn = fn(src, officer) -> number, adminOnly } (T.registerNavCount)
local navExtraOrder = {}

local function ToSrc(src)
    local n = tonumber(src)
    if not n then return nil end
    n = math.tointeger(n)
    if not n or n <= 0 then return nil end
    return n
end

-- A guarded call into another module: false when it is missing or fails, else true and its results.
local function Call(modName, fnName, ...)
    local m = CP[modName]
    if type(m) ~= 'table' or type(m[fnName]) ~= 'function' then return false end
    local res = table.pack(pcall(m[fnName], ...))
    if not res[1] then
        CP.err(TAG, 'CP.%s.%s failed: %s', modName, fnName, tostring(res[2]))
        return false
    end
    return true, table.unpack(res, 2, res.n)
end

-- ============================================================================
--                                TABLET ACCESS
-- ============================================================================
-- SPEC Tablet access: every way ends here. A way that is switched off is refused, a desk needs the player in
-- its box (server coordinates) and their department, and requireItem needs the item for every way but a desk.

local function AccessCfg()
    local t = Config.Tablet or {}
    return type(t.access) == 'table' and t.access or {}
end

local function TabletItem()
    local item = Config.Tablet and Config.Tablet.item
    if type(item) ~= 'string' or item == '' then return nil end
    return item
end

-- The desk at index i of Config.Tablet.desks, or nil.
function T.desk(i)
    local desks = Config.Tablet and Config.Tablet.desks
    i = math.tointeger(tonumber(i) or -1)
    if type(desks) ~= 'table' or not i or i < 1 then return nil end
    local d = desks[i]
    if type(d) ~= 'table' or type(d.coords) ~= 'vector3' and type(d.coords) ~= 'table' then return nil end
    return d
end

function T.deskAllows(desk, deptKey)
    if type(desk) ~= 'table' then return false end
    if type(desk.departments) ~= 'table' or next(desk.departments) == nil then return true end
    for _, k in ipairs(desk.departments) do
        if k == deptKey then return true end
    end
    return false
end

-- true when coords lie in the desk's box grown by margin metres (rotation = the box heading in degrees).
function T.inDeskBox(desk, coords, margin)
    if type(desk) ~= 'table' or not desk.coords or not coords then return false end
    margin = margin or DESK_MARGIN
    local c, size = desk.coords, desk.size or { x = 1.0, y = 1.0, z = 1.0 }
    local dx, dy, dz = coords.x - c.x, coords.y - c.y, (coords.z or 0.0) - (c.z or 0.0)
    local r = math.rad(tonumber(desk.rotation) or 0.0)
    local lx = dx * math.cos(r) + dy * math.sin(r)
    local ly = -dx * math.sin(r) + dy * math.cos(r)
    return math.abs(lx) <= (size.x or 1.0) / 2 + margin and math.abs(ly) <= (size.y or 1.0) / 2 + margin
        and math.abs(dz) <= (size.z or 1.0) / 2 + margin
end

-- The tablet item count of src through ox_inventory (nil when the lookup fails).
local function ItemCount(src, item)
    if GetResourceState('ox_inventory') ~= 'started' then return nil end
    local ok, res = pcall(function() return exports.ox_inventory:Search(src, 'count', item) end)
    if not ok then
        CP.warn(TAG, 'ox_inventory Search for %s failed: %s', item, tostring(res))
        return nil
    end
    return tonumber(ok and res)
end

function T.hasTabletItem(src)
    local item = TabletItem()
    if not item then return false end
    local n = ItemCount(src, item)
    return n ~= nil and n > 0
end

local function InArena(src)
    local ok, v = Call('Alerts', 'inArena', src)
    return ok and v == true
end

-- true, or false and an error key. officer is CP.Access.getOfficer's (department, duty and suspensions checked).
function T.checkAccess(src, officer, via, deskIndex)
    local access = AccessCfg()
    local switch = WAY_SWITCH[via]
    if switch and access[switch] == false then return false, 'err.access_off' end
    if via == 'item' and not TabletItem() then return false, 'err.access_off' end
    if InArena(src) then return false, 'err.in_arena' end
    if via == 'desk' then
        local desk = T.desk(deskIndex)
        if not desk then return false, 'err.not_at_desk' end
        if not T.deskAllows(desk, officer and officer.department) then return false, 'err.desk_department' end
        local ped = GetPlayerPed(src)
        if not ped or ped == 0 then return false, 'err.not_at_desk' end
        if not T.inDeskBox(desk, GetEntityCoords(ped), DESK_MARGIN) then return false, 'err.not_at_desk' end
        return true
    end
    if access.requireItem == true then
        -- a failed lookup counts as no item, only while the item is required
        if not T.hasTabletItem(src) then return false, 'err.no_tablet_item' end
    end
    return true
end

-- ============================================================================
--                                SESSION PARTS
-- ============================================================================

local function adminTheme()
    local cfg = type(Config.AdminTheme) == 'table' and Config.AdminTheme or {}
    local out = {}
    for _, k in ipairs(THEME_KEYS) do
        if CP.U.isHexColour(cfg[k]) then
            out[k] = cfg[k]:lower()
        else
            out[k] = DEFAULT_THEME[k]
            if not themeWarned[k] then
                themeWarned[k] = true
                CP.warn(TAG, 'Config.AdminTheme.%s is not a 6-digit hex colour; using the Crimson-Police default %s', k,
                    DEFAULT_THEME[k])
            end
        end
    end
    if CP.U.isHexColour(cfg.text) then
        out.text = cfg.text:lower()
    else
        out.text = CP.U.contrastText(out.background)
        if cfg.text ~= nil and not themeWarned.text then
            themeWarned.text = true
            CP.warn(TAG, 'Config.AdminTheme.text is not a 6-digit hex colour; picked %s for contrast', out.text)
        end
    end
    return out
end

local function missionTypes()
    local list = {}
    if type(Config.MissionTypes) == 'table' then
        for key, t in pairs(Config.MissionTypes) do
            if type(key) == 'string' and type(t) == 'table' then
                list[#list + 1] = {
                    key = key,
                    label = type(t.label) == 'string' and t.label or key,
                    points = tonumber(t.points) or 0,
                }
            end
        end
    end
    table.sort(list, function(a, b)
        if a.points ~= b.points then return a.points < b.points end
        return a.key < b.key
    end)
    return list
end

-- Tier labels come from CP.Scaling.label (the one place that names tiers), the locale as a fallback.
local function TierLabel(name)
    if CP.Scaling and type(CP.Scaling.label) == 'function' then
        local ok, label = pcall(CP.Scaling.label, name)
        if ok and type(label) == 'string' and label ~= '' then return label end
    end
    return CP.L('tier.' .. name)
end

local function NumOr(v, default)
    local n = tonumber(v)
    if n == nil or n ~= n then return default end
    return n
end

-- Accents of a department theme (theme.personalAccents): '#rrggbb' or { colour, level }.
local function Accents(deptKey)
    local d = deptKey and Config.Departments and Config.Departments[deptKey]
    local list = type(d) == 'table' and type(d.theme) == 'table' and d.theme.personalAccents or nil
    local out = {}
    for _, a in ipairs(type(list) == 'table' and list or {}) do
        local colour = type(a) == 'table' and a.colour or a
        if CP.U.isHexColour(colour) then
            out[#out + 1] = { colour = colour:lower(), level = type(a) == 'table' and tonumber(a.level) or nil }
        end
    end
    return out
end

local function ProfileConfig(deptKey)
    local p = Config.Profile or {}
    local presets = {}
    for _, e in ipairs(type(p.avatarPresets) == 'table' and p.avatarPresets or {}) do
        if type(e) == 'table' and type(e.id) == 'string' then
            presets[#presets + 1] = { id = e.id, level = tonumber(e.level) }
        end
    end
    local scale = type(p.uiScale) == 'table' and p.uiScale or {}
    local appearances = {}
    for _, a in ipairs(type(p.appearances) == 'table' and p.appearances or { DEFAULT_APPEARANCE }) do
        if type(a) == 'string' then appearances[#appearances + 1] = a end
    end
    return {
        bioMax = math.floor(NumOr(p.bioMax, 280)),
        bioLines = math.floor(NumOr(p.bioLines, 3)),
        presets = presets,
        urls = type(p.avatarUrls) == 'table' and p.avatarUrls.enabled == true or false,
        appearances = appearances,
        accents = Accents(deptKey),
        uiScale = { NumOr(scale[1], 0.85), NumOr(scale[2], 1.25), NumOr(scale[3], 1.0) },
    }
end

-- The parity-plus parts of Session.config (web/src/shared/types.ts). English is the only language shipped.
local function ExtraConfig(deptKey)
    local mc = Config.MissionCalls or {}
    local areas = {}
    for _, a in ipairs(type(mc.areas) == 'table' and mc.areas or {}) do
        if type(a) == 'table' and type(a.key) == 'string' then
            areas[#areas + 1] = { key = a.key, label = type(a.label) == 'string' and a.label or a.key }
        end
    end
    local metrics = {}
    local lb = Config.Leaderboard or {}
    for _, m in ipairs(type(lb.metrics) == 'table' and lb.metrics or { 'points' }) do
        if type(m) == 'string' then metrics[#metrics + 1] = m end
    end
    local kinds = {}
    local cm = Config.Commendations or {}
    if cm.enabled ~= false then
        for _, k in ipairs(type(cm.kinds) == 'table' and cm.kinds or {}) do
            if type(k) == 'string' then kinds[#kinds + 1] = k end
        end
    end
    local fmt = Config.Format or {}
    return {
        dispatch = { enabled = mc.enabled ~= false, areas = areas },
        leaderboardMetrics = metrics,
        profile = ProfileConfig(deptKey),
        commendationKinds = kinds,
        rewards = { enabled = Config.Rewards and Config.Rewards.enabled == true or false },
        format = {
            currency = type(fmt.currency) == 'string' and fmt.currency or '$',
            currencyAfter = fmt.currencyAfter == true,
        },
    }
end

local function Initials(name)
    local out = {}
    for word in tostring(name or ''):gmatch('[^%s]+') do
        if #out < 2 then out[#out + 1] = word:sub(1, 1):upper() end
    end
    return #out > 0 and table.concat(out) or '?'
end

-- The officer's cp_officers row: XP, avatar and look (one read; nil when there is none yet).
local function ReadProfile(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return nil end
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
    local ok, row = pcall(MySQL.single.await, [[
        SELECT xp, avatar_kind, avatar_value, avatar_status, appearance, accent, ui_scale, calls_muted
        FROM cp_officers WHERE citizenid = ?
    ]], { citizenid })
    if not ok then
        CP.err(TAG, 'reading the profile of %s failed: %s', citizenid, tostring(row))
        return nil
    end
    return type(row) == 'table' and row or nil
end

local function LevelOf(xp)
    if CP.Scoring and CP.Scoring.xpLevel then
        local ok, lv = pcall(CP.Scoring.xpLevel, xp)
        if ok and type(lv) == 'table' then
            return {
                n = tonumber(lv.n) or 1,
                label = lv.label or '',
                badge = lv.badge or 'grey',
                xp = math.floor(NumOr(xp, 0)),
                levelXp = tonumber(lv.levelXp) or 0,
                nextLevelXp = tonumber(lv.nextLevelXp),
                prestige = tonumber(lv.prestige) or 0,
            }
        end
    end
    return {
        n = 1,
        label = '',
        badge = 'grey',
        xp = math.floor(NumOr(xp, 0)),
        levelXp = 0,
        nextLevelXp = nil,
        prestige = 0,
    }
end

-- The picture everyone sees: an approved link or a preset, else the initials; frame = the level badge.
local function AvatarOf(officer, row, level)
    local kind = row and AVATAR_KINDS[row.avatar_kind] and row.avatar_kind or 'initials'
    local value = row and type(row.avatar_value) == 'string' and row.avatar_value ~= '' and row.avatar_value or nil
    if kind == 'url' and not (value and row.avatar_status == 'approved') then kind, value = 'initials', nil end
    if kind == 'preset' and not value then kind = 'initials' end
    if kind == 'initials' then value = nil end
    return { kind = kind, value = value, initials = Initials(officer and officer.name), frame = level.badge }
end

local function PrefsOf(row)
    local p = Config.Profile or {}
    local scale = type(p.uiScale) == 'table' and p.uiScale or {}
    local lo, hi, default = NumOr(scale[1], 0.85), NumOr(scale[2], 1.25), NumOr(scale[3], 1.0)
    local uiScale = row and tonumber(row.ui_scale) or default
    if uiScale < lo or uiScale > hi then uiScale = default end
    return {
        appearance = row and type(row.appearance) == 'string' and row.appearance or DEFAULT_APPEARANCE,
        accent = row and CP.U.isHexColour(row.accent) and row.accent:lower() or nil,
        uiScale = uiScale,
        callsMuted = row ~= nil and CP.U.truthy(row.calls_muted) or false,
    }
end

local function SessionConfig()
    local types = missionTypes()
    local depts = {}
    for _, d in ipairs(CP.Access.departments()) do
        depts[#depts + 1] = { key = d.key, label = d.label, short = d.short, primary = d.theme.primary }
    end
    local tiers = {}
    if type(Config.Scaling) == 'table' then
        for _, row in ipairs(Config.Scaling) do
            if type(row) == 'table' and type(row.tier) == 'string' then
                tiers[#tiers + 1] = { name = row.tier, label = TierLabel(row.tier) }
            end
        end
    end
    local filters = { 'overall' }
    for _, t in ipairs(types) do filters[#filters + 1] = t.key end
    for _, f in ipairs(FILTER_EXTRAS) do filters[#filters + 1] = f end
    local periods = {}
    for i, p in ipairs(PERIODS) do periods[i] = p end
    return {
        missionTypes = types,
        departments = depts,
        tiers = tiers,
        maxRecalcs = tonumber(Config.Route and Config.Route.maxRecalcs) or 0,
        disputeWindowHours = tonumber(Config.Disputes and Config.Disputes.windowHours) or 0,
        periods = periods,
        filters = filters,
    }
end

local function SessionLogo(dept)
    if not dept or type(dept.logo) ~= 'table' or not dept.logo.url then return nil end
    if missingLogo[dept.key] then return nil end
    local l = dept.logo
    return { url = l.url, watermark = l.watermark, opacity = l.opacity, size = l.size, grayscale = l.grayscale }
end

local function SessionOfficer(o, row)
    local level = LevelOf(row and row.xp or 0)
    return {
        avatar = AvatarOf(o, row, level),
        level = level,
        citizenid = o.citizenid,
        name = o.name,
        department = o.department,
        departmentLabel = o.departmentLabel,
        departmentShort = o.departmentShort,
        rank = o.rank,
        callsign = o.callsign,
        gradeLevel = o.gradeLevel,
    }
end

-- How the tablet was opened: args.via (an unknown way is the command), or, for a later request of the same
-- tablet (switchUi, refreshSession) that names none, the way of the session that passed last.
local function WayOf(src, args)
    local via = VIA[args.via] and args.via or nil
    local desk = math.tointeger(tonumber(args.desk) or -1)
    if not via and args.via == nil and lastWay[src] then return lastWay[src].via, lastWay[src].desk end
    via = via or 'command'
    return via, (via == 'desk' and desk and desk > 0) and desk or nil
end

-- The Session (§9.2) for 'ui', or nil and an error key. May yield. args: { via, desk } (how it was opened).
local function BuildSession(src, ui, args)
    if not CP.Access then return nil, 'err.internal' end
    local isAdmin = CP.Access.isAdmin(src)
    local officer, officerErr = CP.Access.getOfficer(src)
    local roles = {
        officer = officer ~= nil,
        -- Supervisor is the job grade only (SPEC Roles); admins use the Admin UI.
        supervisor = officer ~= nil and officer.isSupervisor == true,
        admin = isAdmin,
    }
    if ui == 'officer' then
        if not officer then return nil, officerErr or 'err.not_police' end
    elseif ui == 'supervisor' then
        if not officer then return nil, officerErr or 'err.not_police' end
        if not roles.supervisor then return nil, 'err.not_supervisor' end
    elseif ui == 'admin' then
        if not isAdmin then return nil, 'err.not_admin' end
    else
        return nil, 'err.invalid_ui'
    end
    args = type(args) == 'table' and args or {}
    local via, desk = WayOf(src, args)
    -- the silent session only refreshes the HUD theme at login: it opens nothing
    if ui ~= 'admin' and args.silent ~= true then
        local okWay, wayErr = T.checkAccess(src, officer, via, desk)
        if not okWay then return nil, wayErr end
        lastWay[src] = { via = via, desk = desk }
        -- an open tablet asks for its badges: 'nav' pushes go to it from now on
        navWatch[src] = os.time()
    end

    local theme, logo
    if ui == 'admin' then
        theme = adminTheme()
    else
        local dept = CP.Access.department(officer.department)
        theme = dept and dept.theme or CP.U.copy(DEFAULT_THEME)
        logo = SessionLogo(dept)
    end
    local actions = {}
    if CP.Permissions and CP.Permissions.actionsFor then actions = CP.Permissions.actionsFor(src) end
    local title = Config.Tablet and Config.Tablet.title
    local row = officer and ReadProfile(officer.citizenid) or nil
    local config = SessionConfig()
    for k, v in pairs(ExtraConfig(officer and officer.department)) do config[k] = v end
    return {
        ui = ui,
        title = type(title) == 'string' and title ~= '' and title or 'Crimson-Police',
        roles = roles,
        officer = officer and SessionOfficer(officer, row) or nil,
        theme = theme,
        logo = logo,
        actions = actions,
        locale = CP.Locale.all(),
        config = config,
        prefs = PrefsOf(row),
        access = { via = via, desk = desk },
        maintenance = CP.Maintenance and CP.Maintenance.view and CP.Maintenance.view() or nil,
        serverTime = os.time(),
    }
end

CP.Net.callback('getSession', function(src, args)
    if args ~= nil and type(args) ~= 'table' then return nil, 'err.invalid_payload' end
    local ui = args and args.ui
    if ui == nil then ui = 'officer' end
    if type(ui) ~= 'string' or not UIS[ui] then return nil, 'err.invalid_ui' end
    local session, errKey = BuildSession(src, ui, args)
    if not session then
        CP.log(TAG, 'getSession %s for %s refused: %s', ui, tostring(src), tostring(errKey))
        return nil, errKey
    end
    if ui ~= 'admin' and not (args and args.silent == true) then
        CreateThread(function() CP.Access.refreshOfficerRow(src) end)
    end
    return session
end, { rate = 4 })

-- Admin UI → Departments: the ways, the mission desks and each department's personal accents (TabletAccessView).
CP.Net.callback('admin:getTabletAccess', function(src)
    if not (CP.Access and CP.Access.isAdmin(src)) then return nil, 'err.not_admin' end
    local access = AccessCfg()
    local ways = {}
    for _, k in ipairs({ 'command', 'keybind', 'item', 'desk', 'requireItem' }) do
        ways[k] = k == 'requireItem' and access[k] == true or access[k] ~= false
    end
    local desks = {}
    for i, d in ipairs(type(Config.Tablet and Config.Tablet.desks) == 'table' and Config.Tablet.desks or {}) do
        if type(d) == 'table' and d.coords then
            local size = d.size or { x = 1.0, y = 1.0, z = 1.0 }
            desks[#desks + 1] = {
                index = i,
                label = type(d.label) == 'string' and d.label or ('#%d'):format(i),
                coords = { x = d.coords.x, y = d.coords.y, z = d.coords.z },
                size = { x = size.x, y = size.y, z = size.z },
                rotation = tonumber(d.rotation) or 0.0,
                departments = type(d.departments) == 'table' and CP.U.copy(d.departments) or nil,
                prop = type(d.prop) == 'string' and d.prop or nil,
            }
        end
    end
    local accents = {}
    for _, dept in ipairs(CP.Access.departments()) do accents[dept.key] = Accents(dept.key) end
    local cfg = ProfileConfig(nil)
    return {
        ways = ways,
        item = TabletItem(),
        deskDistance = tonumber(Config.Tablet and Config.Tablet.deskDistance) or 3.0,
        desks = desks,
        accents = accents,
        appearances = cfg.appearances,
    }
end, { rate = 3 })

-- ============================================================================
--                                CLIENT HELPERS
-- ============================================================================

function T.notify(src, kind, key, vars, opts)
    local n = ToSrc(src)
    if not n or type(key) ~= 'string' or key == '' then return false end
    if not KINDS[kind] then kind = 'info' end
    if type(opts) ~= 'table' then opts = {} end
    local duration = tonumber(opts.duration)
    TriggerClientEvent(CP.e('client:notify'), n, {
        kind = kind,
        key = key,
        vars = type(vars) == 'table' and CP.U.serialize(vars) or nil,
        title = type(opts.title) == 'string' and opts.title ~= '' and opts.title or nil,
        duration = duration and math.floor(duration) or nil,
    })
    return true
end

function T.notifyMany(srcs, kind, key, vars)
    if type(srcs) ~= 'table' then return 0 end
    local seen, sent = {}, 0
    for _, src in ipairs(srcs) do
        local n = ToSrc(src)
        if n and not seen[n] then
            seen[n] = true
            if T.notify(n, kind, key, vars) then sent = sent + 1 end
        end
    end
    return sent
end

local ScheduleNav

function T.push(src, topic, data)
    local n = ToSrc(src)
    if not n or type(topic) ~= 'string' or topic == '' then return false end
    TriggerClientEvent(CP.e('client:push'), n, topic, CP.U.serialize(data))
    if NAV_TOPICS[topic] then ScheduleNav(n) end
    return true
end

-- Every online admin (CP.Access.isAdmin), never anyone else: admin data stays with admins.
local function OnlineAdmins()
    local out = {}
    if not (CP.Access and CP.Access.isAdmin) then return out end
    for _, s in ipairs(GetPlayers and GetPlayers() or {}) do
        local n = ToSrc(s)
        if n and CP.Access.isAdmin(n) then out[#out + 1] = n end
    end
    return out
end
T.onlineAdmins = OnlineAdmins

-- A push to admin players only (the adminjob progress, admin screens). Returns how many got it.
function T.pushAdmins(topic, data)
    if type(topic) ~= 'string' or topic == '' then return 0 end
    local n = 0
    for _, src in ipairs(OnlineAdmins()) do
        if T.push(src, topic, data) then n = n + 1 end
    end
    return n
end

-- A toast to every online admin.
function T.notifyAdmins(kind, key, vars)
    return T.notifyMany(OnlineAdmins(), kind, key, vars)
end

-- ============================================================================
--                             SIDEBAR BADGE COUNTS
-- ============================================================================
-- NavCounts (web/src/shared/types.ts). Every count comes from its module's own cache through a guarded call: a
-- missing module gives 0. The Review Queue count is the only one that reads the database (30 s per src).

local function Count(ok, v)
    if not ok then return 0 end
    if type(v) == 'table' then return #v end
    local n = math.tointeger(tonumber(v) or 0) or 0
    return n > 0 and n or 0
end

local function InviteCount(src)
    local ok, n = Call('Units', 'invitesFor', src)
    if ok then return Count(true, n) end
    local okV, view = Call('Units', 'view', src)
    if not okV or type(view) ~= 'table' or type(view.invites) ~= 'table' then return 0 end
    local c = 0
    for _, inv in ipairs(view.invites) do
        if (tonumber(inv.expiresIn) or 0) > 0 then c = c + 1 end
    end
    return c
end

local function Can(src, action)
    local ok, yes = Call('Permissions', 'can', src, action)
    return ok and yes == true
end

local function ReviewCount(src, officer)
    if not officer or not officer.isSupervisor then return 0 end
    local now = os.time()
    local c = reviewCache[src]
    if c and now - c.at < REVIEW_CACHE_S then return c.n end
    local n = 0
    if Can(src, 'reviewFlagged') then
        n = n + Count(Call('Admin', 'flaggedRows', officer.department, officer.citizenid))
    end
    if Can(src, 'handleDisputes') then n = n + Count(Call('Disputes', 'forSupervisor', src)) end
    if Can(src, 'reviewProfiles') then n = n + Count(Call('Profile', 'queue', officer.department)) end
    reviewCache[src] = { at = now, n = n }
    return n
end

-- A sidebar count another module owns: fn(src, officer|nil) -> number. opts.adminOnly = the count goes to admin
-- players only (adminReview, adminDisputes, adminPayments, adminLive), never to an officer or supervisor.
function T.registerNavCount(key, fn, opts)
    if type(key) ~= 'string' or not key:match('^[%a][%w_]*$') or type(fn) ~= 'function' then return false end
    if not navExtra[key] then navExtraOrder[#navExtraOrder + 1] = key end
    navExtra[key] = { fn = fn, adminOnly = type(opts) == 'table' and opts.adminOnly == true }
    return true
end

local function ExtraCounts(counts, n, officer)
    if #navExtraOrder == 0 then return end
    local admin = nil
    for _, key in ipairs(navExtraOrder) do
        local e = navExtra[key]
        if e.adminOnly then
            if admin == nil then admin = CP.Access and CP.Access.isAdmin and CP.Access.isAdmin(n) == true end
            if admin then
                local ok, v = pcall(e.fn, n, officer)
                counts[key] = Count(ok, v)
            end
        elseif officer then
            local ok, v = pcall(e.fn, n, officer)
            counts[key] = Count(ok, v)
        end
    end
end

-- A count of another module changed for src: the counts are pushed again.
function T.navChanged(src)
    local n = ToSrc(src)
    if n then ScheduleNav(n) end
end

function T.navCounts(src)
    local counts = { invites = 0, calls = 0, review = 0, commendations = 0, rewards = 0, onRun = false }
    local n = ToSrc(src)
    if not n then return counts end
    local now = os.time()
    local c = navCache[n]
    if c and now - c.at < NAV_CACHE_S then return c.counts end
    local okO, officer = Call('Access', 'getOfficer', n)
    officer = okO and type(officer) == 'table' and officer or nil
    ExtraCounts(counts, n, officer)
    if officer then
        counts.invites = InviteCount(n)
        counts.calls = Count(Call('MissionCalls', 'claimableCount', n))
        counts.review = ReviewCount(n, officer)
        counts.commendations = Count(Call('Profile', 'newCommendations', officer.citizenid))
        counts.rewards = Count(Call('Rewards', 'lockerCount', officer.citizenid))
        local okR, run = Call('Runs', 'getBySrc', n)
        counts.onRun = okR and run ~= nil
    end
    navCache[n] = { at = now, counts = counts }
    return counts
end

-- A push that may change a badge: the counts are built again and pushed once, a second later.
ScheduleNav = function(src)
    navCache[src] = nil
    local watched = navWatch[src]
    if not watched or os.time() - watched > NAV_WATCH_S or navPending[src] then return end
    navPending[src] = true
    SetTimeout(NAV_PUSH_DELAY_MS, function()
        navPending[src] = nil
        if not navWatch[src] then return end
        T.push(src, 'nav', T.navCounts(src))
    end)
end

CP.Net.callback('getNavCounts', function(src)
    navWatch[src] = os.time()
    return T.navCounts(src)
end, { rate = 4 })

-- requireItem: the client saw the item leave the inventory. The server checks again and closes the tablet.
RegisterNetEvent(CP.e('server:tabletItemGone'), function()
    local src = source
    if AccessCfg().requireItem ~= true then return end
    -- each report asks ox_inventory: a flood of them is dropped
    if not CP.Net.rateOk(src, 'tablet:itemGone', 2, 1000) then return end
    local way = lastWay[src]
    if way and way.via == 'desk' then return end
    if T.hasTabletItem(src) then return end
    CP.log(TAG, 'tablet item gone for %d: closing the tablet', src)
    TriggerClientEvent(CP.e('client:closeTablet'), src, 'err.no_tablet_item')
end)

local function OpenAdminNow(src)
    local session, errKey = BuildSession(src, 'admin')
    if not session then
        T.notify(src, 'error', errKey or 'err.not_admin')
        return false, errKey or 'err.not_admin'
    end
    TriggerClientEvent(CP.e('client:openAdmin'), src, session)
    CP.log(TAG, 'Admin UI opened for %d', src)
    return true
end

function T.openAdmin(src)
    local n = ToSrc(src)
    if not n then
        CP.warn(TAG, 'the Admin UI can only be opened in game')
        return false, 'err.not_in_game'
    end
    if coroutine.isyieldable() then return OpenAdminNow(n) end
    CreateThread(function() OpenAdminNow(n) end)
    return true
end

-- ============================================================================
--                                    LOGOS
-- ============================================================================

CP.Net.action('server:logoFailed', function(src, payload)
    local deptKey, url
    if type(payload) == 'string' then
        deptKey = payload
    elseif type(payload) == 'table' then
        if type(payload.department) == 'string' then deptKey = payload.department end
        if type(payload.url) == 'string' then url = payload.url:sub(1, 512) end
    else
        return false, 'err.invalid_payload'
    end
    if deptKey and #deptKey > 32 then return false, 'err.invalid_payload' end
    local dept = deptKey and CP.Access.department(deptKey) or nil
    if not dept and url then
        for _, d in ipairs(CP.Access.departments()) do
            if d.logo and d.logo.url == url then dept = d break end
        end
    end
    if not dept then return false, 'err.unknown_department' end
    if not logoFailedWarned[dept.key] then
        logoFailedWarned[dept.key] = true
        CP.warn(TAG,
            'Department %s: the tablet could not load its logo %s (reported by player %d). Check %s; the tablet shows no watermark for it.',
            dept.key, tostring(dept.logo and dept.logo.url), src,
            dept.logo and dept.logo.file and ('logos/' .. dept.logo.file) or 'logo.url in Config.Departments')
    end
    return true
end, { rate = 2 })

-- Check every file-based logo once at start (at runtime, when CP.Access is loaded).
CreateThread(function()
    if not CP.Access then
        CP.err(TAG, 'modules/access is missing: the tablet cannot build sessions')
        return
    end
    local warnedFile = {}
    for _, dept in ipairs(CP.Access.departments()) do
        local file = dept.logo and dept.logo.file
        if file then
            local data = LoadResourceFile(CP.resource, 'logos/' .. file)
            if not data or data == '' then
                missingLogo[dept.key] = true
                if not warnedFile[file] then
                    warnedFile[file] = true
                    CP.warn(TAG,
                        'Department %s: logos/%s is missing; its tablet shows no logo or watermark until the file is added and the resource restarted',
                        dept.key, file)
                end
            end
        end
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    lastWay[src], navCache[src], reviewCache[src], navWatch[src], navPending[src] = nil, nil, nil, nil, nil
end)
