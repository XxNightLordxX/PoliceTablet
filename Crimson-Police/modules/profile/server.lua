-- CP.Profile (server): pictures, bio and look of an officer, profile reports, commendations and profile moderation.
-- Commendations carry no points and no cash; nothing here writes cp_mission_runs, XP, goals, badges or boards.

CP.Profile = CP.Profile or {}
local Profile = CP.Profile
local U = CP.U
local TAG = 'profile'

local DAY_S = 86400
local NEWS_CACHE_S = 60              -- the Home commendation news is read again at most this often
local MAX_REASON = 255               -- moderation, revoke and handle reasons
local MAX_URL = 255                  -- avatar_value / avatar_pending
local QUEUE_LIMIT = 100              -- items per kind in the Review Queue → Profiles tab
local LIST_LIMIT = 50                -- commendations shown on a profile
local AVATAR_KINDS = { initials = true, preset = true, url = true }
local REPORT_REASONS = { picture = true, bio = true, other = true }
local IMAGE_EXTS = { png = true, jpg = true, jpeg = true, webp = true }

local urlSubmits = {}    -- urlSubmits[citizenid] = { day = dayStart, n = link submissions that day }
local news = {}          -- news[citizenid] = { at, n, list } (the Home extras: read from cache only)
local banned = nil       -- { words = { lower-case entry }, source = Config.Profile.bannedWords table }

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function Num(v, d)
    local n = tonumber(v)
    if n == nil or n ~= n then return d end
    return n
end

local function Int(v) return math.floor(Num(v, 0) + 0.0) end

local function Cfg() return type(Config.Profile) == 'table' and Config.Profile or {} end

local function CommendCfg() return type(Config.Commendations) == 'table' and Config.Commendations or {} end

local function Db()
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
end

local function Has(mod, fn) return type(CP[mod]) == 'table' and type(CP[mod][fn]) == 'function' end

-- pcall a module function; returns ok, results...
local function Call(mod, fn, ...)
    if not Has(mod, fn) then return false end
    local res = table.pack(pcall(CP[mod][fn], ...))
    if not res[1] then
        CP.err(TAG, 'CP.%s.%s failed: %s', mod, fn, tostring(res[2]))
        return false
    end
    return true, table.unpack(res, 2, res.n)
end

local function Now() return os.time() end

local function DayStart(ts)
    ts = ts or Now()
    if Has('Schedule', 'dayStart') then return CP.Schedule.dayStart(ts) end
    local t = os.date('*t', ts)
    return os.time({ year = t.year, month = t.month, day = t.day, hour = 0, min = 0, sec = 0 })
end

local function ValidCitizenId(v)
    return type(v) == 'string' and #v >= 1 and #v <= 50 and v:match('^[%w_%-]+$') ~= nil
end

local function ValidRunUuid(v)
    return type(v) == 'string' and #v >= 1 and #v <= 36 and v:match('^[%w%-]+$') ~= nil
end

local function NonEmpty(s)
    if type(s) ~= 'string' then return nil end
    s = U.trim(s)
    if s == '' then return nil end
    return s
end

-- Plain text from a player: control characters removed (a newline kept when allowed), CRLF made LF, trimmed.
local function CleanText(s, keepNewlines)
    if type(s) ~= 'string' then return nil end
    s = s:gsub('\r\n', '\n'):gsub('\r', '\n')
    if keepNewlines then
        s = s:gsub('[%z\1-\9\11-\31\127]', '')
    else
        s = s:gsub('[%z\1-\31\127]', ' ')
    end
    return U.trim(s)
end

local function CharLen(s) return utf8.len(s) or #s end

local function Reason(v)
    local s = CleanText(v, false)
    if not s or s == '' then return nil, 'err.reason_required' end
    if CharLen(s) > MAX_REASON then return nil, 'err.reason_too_long' end
    return s
end

local function Initials(name)
    local out = {}
    for word in tostring(name or ''):gmatch('[^%s]+') do
        if #out < 2 then out[#out + 1] = word:sub(1, 1):upper() end
    end
    return #out > 0 and table.concat(out) or '?'
end

-- A callsign's first two letters or digits ("2L-11" -> "2L"), for officers who hide their name.
local function CallsignInitials(callsign)
    local s = tostring(callsign or ''):gsub('[^%w]', '')
    if s == '' then return '?' end
    return s:sub(1, 2):upper()
end

local function Audit(src, category, action, target, old, new, reason)
    if not Has('Admin', 'audit') then return end
    Call('Admin', 'audit', src, nil, category, action, target, old, new, reason)
end

local function Notify(citizenid, kind, key, vars)
    local ok, src = Call('Qbx', 'getByCitizenId', citizenid)
    if ok and src and Has('Tablet', 'notify') then Call('Tablet', 'notify', src, kind, key, vars) end
    return ok and src or nil
end

local function PushProfile(citizenid)
    local ok, src = Call('Qbx', 'getByCitizenId', citizenid)
    if ok and src and Has('Tablet', 'push') then Call('Tablet', 'push', src, 'profile', { citizenid = citizenid }) end
end

local function InvalidateBoards()
    if Has('Leaderboard', 'invalidate') then Call('Leaderboard', 'invalidate') end
end

local function LevelOf(xp)
    local ok, lv = Call('Scoring', 'xpLevel', Int(xp))
    if ok and type(lv) == 'table' then
        return {
            n = Int(lv.n or 1),
            label = tostring(lv.label or ''),
            badge = tostring(lv.badge or 'grey'),
            xp = Int(xp),
            levelXp = Int(lv.levelXp),
            nextLevelXp = tonumber(lv.nextLevelXp),
            prestige = Int(lv.prestige),
        }
    end
    return { n = 1, label = '', badge = 'grey', xp = Int(xp), levelXp = 0, nextLevelXp = nil, prestige = 0 }
end

-- ============================================================================
--                                 OFFICER ROW
-- ============================================================================

local ROW_SQL = [[
SELECT citizenid, display_name, callsign, rank_label, department, xp, hide_name, bio, bio_pending, avatar_kind,
  avatar_value, avatar_pending, avatar_status, appearance, accent, ui_scale, language, calls_muted,
  UNIX_TIMESTAMP(profile_updated_at) AS updated_ts
FROM cp_officers WHERE citizenid = ?]]

local function ReadRow(citizenid)
    if not ValidCitizenId(citizenid) then return nil end
    Db()
    local ok, row = pcall(MySQL.single.await, ROW_SQL, { citizenid })
    if not ok then
        CP.err(TAG, 'reading the profile of %s failed: %s', citizenid, tostring(row))
        return nil
    end
    return type(row) == 'table' and row or nil
end

-- Makes sure the officer has a cp_officers row before an UPDATE (an officer who never finished a run has none).
local function EnsureRow(officer)
    MySQL.update.await([[INSERT IGNORE INTO cp_officers (citizenid, callsign, display_name, department)
        VALUES (?, NULLIF(?, ''), ?, ?)]], {
        officer.citizenid,
        U.clip(officer.callsign or '', 32),
        U.clip(officer.name or '', 64),
        officer.department,
    })
end

-- UPDATE cp_officers SET <fields> WHERE citizenid = ? (fields: list of { column, value } or { column, sql = expr }).
local function WriteFields(citizenid, fields)
    if #fields == 0 then return true end
    local sets, params = {}, {}
    for _, f in ipairs(fields) do
        if f.sql then
            sets[#sets + 1] = ('%s = %s'):format(f[1], f.sql)
            if f.param ~= nil then params[#params + 1] = f.param end
        elseif f[2] == nil then
            sets[#sets + 1] = ('%s = NULL'):format(f[1])
        else
            sets[#sets + 1] = ('%s = ?'):format(f[1])
            params[#params + 1] = f[2]
        end
    end
    params[#params + 1] = citizenid
    local ok, err = pcall(MySQL.update.await,
        ('UPDATE cp_officers SET %s WHERE citizenid = ?'):format(table.concat(sets, ', ')), params)
    if not ok then
        CP.err(TAG, 'saving the profile of %s failed: %s', citizenid, tostring(err))
        return false
    end
    return true
end

-- ============================================================================
--                                   AVATARS
-- ============================================================================

-- The picture everyone sees, from a cp_officers row: an approved link or a preset, else the initials. A hidden
-- name shows the callsign's initials and never the picture (opts.own = the viewer is the officer).
function Profile.avatarOf(row, opts)
    row = type(row) == 'table' and row or {}
    opts = type(opts) == 'table' and opts or {}
    local level = LevelOf(row.xp)
    if U.truthy(row.hide_name) and not opts.own then
        return { kind = 'initials', value = nil, initials = CallsignInitials(row.callsign), frame = level.badge }
    end
    local kind = AVATAR_KINDS[row.avatar_kind] and row.avatar_kind or 'initials'
    -- avatar_value only ever holds an approved link or a preset id: a link waiting for approval is in
    -- avatar_pending, so a pending or rejected new link leaves the old picture in place.
    local value = type(row.avatar_value) == 'string' and row.avatar_value ~= '' and row.avatar_value or nil
    if kind == 'url' and not value then kind = 'initials' end
    if kind == 'preset' and not value then kind = 'initials' end
    if kind == 'initials' then value = nil end
    return {
        kind = kind,
        value = value,
        initials = Initials(NonEmpty(row.display_name) or row.callsign),
        frame = level.badge,
    }
end

local function ViewerCid(viewerSrc)
    if viewerSrc == nil then return nil end
    local ok, o = Call('Access', 'getOfficer', viewerSrc)
    if ok and type(o) == 'table' then return o.citizenid end
    local ok2, info = Call('Qbx', 'getInfo', viewerSrc)
    if ok2 and type(info) == 'table' then return info.citizenid end
    return nil
end

function Profile.avatarFor(citizenid, viewerSrc)
    local row = ReadRow(citizenid) or { citizenid = citizenid }
    return Profile.avatarOf(row, { own = viewerSrc ~= nil and ViewerCid(viewerSrc) == citizenid })
end

-- The preset list: { id = { level = n|nil } }.
local function Presets()
    local out = {}
    for _, e in ipairs(type(Cfg().avatarPresets) == 'table' and Cfg().avatarPresets or {}) do
        if type(e) == 'table' and type(e.id) == 'string' and e.id ~= '' then
            out[e.id] = { level = tonumber(e.level) }
        end
    end
    return out
end

local function UrlCfg() return type(Cfg().avatarUrls) == 'table' and Cfg().avatarUrls or {} end

-- The link rules: https, an allowed host (exact), at most 255 characters, a path ending in an image extension (a
-- query string is allowed and ignored for that check) and no spaces, quotes or angle brackets.
function Profile.validateUrl(url)
    if type(url) ~= 'string' or url == '' then return false, 'err.avatar_url_invalid' end
    if #url > MAX_URL then return false, 'err.avatar_url_too_long' end
    if url:find('[%s"\'`<>\\%c]') then return false, 'err.avatar_url_invalid' end
    local host, rest = url:match('^https://([^/?#]+)(/[^?#]*)')
    if not host then return false, 'err.avatar_url_https' end
    host = host:lower()
    local allowed = false
    for _, h in ipairs(type(UrlCfg().hosts) == 'table' and UrlCfg().hosts or {}) do
        if type(h) == 'string' and h:lower() == host then allowed = true end
    end
    if not allowed then return false, 'err.avatar_url_host' end
    local ext = rest:match('%.([%w]+)$')
    if not ext or not IMAGE_EXTS[ext:lower()] then return false, 'err.avatar_url_ext' end
    return true
end

local function UrlsLeft(citizenid)
    local perDay = math.max(0, Int(UrlCfg().perDay or 3))
    local s = urlSubmits[citizenid]
    if not s or s.day ~= DayStart() then return perDay end
    return math.max(0, perDay - s.n)
end

local function CountUrl(citizenid)
    local day = DayStart()
    local s = urlSubmits[citizenid]
    if not s or s.day ~= day then s = { day = day, n = 0 }; urlSubmits[citizenid] = s end
    s.n = s.n + 1
end

-- ============================================================================
--                                     BIO
-- ============================================================================

local function EscapePattern(s) return (s:gsub('[%^%$%(%)%%%.%[%]%*%+%-%?]', '%%%0')) end

local function LoadBannedWords()
    local cfg = Cfg()
    local list = {}
    for _, w in ipairs(type(cfg.bannedWords) == 'table' and cfg.bannedWords or {}) do
        if type(w) == 'string' and U.trim(w) ~= '' then list[#list + 1] = U.trim(w):lower() end
    end
    local file = cfg.bannedWordsFile
    if type(file) == 'string' and file ~= '' then
        local text = LoadResourceFile(GetCurrentResourceName(), file)
        if type(text) == 'string' then
            for line in text:gmatch('[^\n]+') do
                line = U.trim(line:gsub('\r', ''))
                if line ~= '' and line:sub(1, 1) ~= '#' then list[#list + 1] = line:lower() end
            end
        else
            CP.warn(TAG, 'Config.Profile.bannedWordsFile %s was not found: only Config.Profile.bannedWords is used',
                file)
        end
    end
    local patterns = {}
    for _, w in ipairs(list) do patterns[#patterns + 1] = '%f[%w]' .. EscapePattern(w) .. '%f[%W]' end
    banned = { patterns = patterns, source = cfg.bannedWords, file = file }
end

function Profile._reloadBannedWords() banned = nil end

-- True when the text holds a banned word or phrase (whole words, any case).
function Profile.hasBannedWord(text)
    local cfg = Cfg()
    if not banned or banned.source ~= cfg.bannedWords or banned.file ~= cfg.bannedWordsFile then LoadBannedWords() end
    local lower = tostring(text or ''):lower()
    for _, p in ipairs(banned.patterns) do
        if lower:find(p) then return true end
    end
    return false
end

-- A bio as saved: nil for "no bio", or the cleaned text; or false and an error key.
function Profile.validateBio(text)
    if text == false or text == '' then return nil end
    if type(text) ~= 'string' then return false, 'err.invalid_payload' end
    local s = CleanText(text, true)
    s = s:gsub('[ \t]+\n', '\n'):gsub('\n[ \t]+', '\n')
    if s == '' then return nil end
    if CharLen(s) > math.max(1, Int(Cfg().bioMax or 280)) then return false, 'err.bio_too_long' end
    local lines = 1
    for _ in s:gmatch('\n') do lines = lines + 1 end
    if lines > math.max(1, Int(Cfg().bioLines or 3)) then return false, 'err.bio_lines' end
    if Profile.hasBannedWord(s) then return false, 'err.bio_banned' end
    return s
end

-- ============================================================================
--                                     LOOK
-- ============================================================================

local function DeptAccents(deptKey)
    local d = type(Config.Departments) == 'table' and deptKey and Config.Departments[deptKey] or nil
    local list = type(d) == 'table' and type(d.theme) == 'table' and d.theme.personalAccents or nil
    local out = {}
    for _, a in ipairs(type(list) == 'table' and list or {}) do
        local colour = type(a) == 'table' and a.colour or a
        if U.isHexColour(colour) then
            out[#out + 1] = { colour = colour:lower(), level = type(a) == 'table' and tonumber(a.level) or nil }
        end
    end
    return out
end

local function ScaleRange()
    local s = type(Cfg().uiScale) == 'table' and Cfg().uiScale or {}
    return Num(s[1], 0.85), Num(s[2], 1.25), Num(s[3], 1.0)
end

function Profile.prefsFor(citizenid)
    local row = ReadRow(citizenid)
    local lo, hi, default = ScaleRange()
    local scale = row and tonumber(row.ui_scale) or default
    if scale < lo or scale > hi then scale = default end
    local appearances = type(Cfg().appearances) == 'table' and Cfg().appearances or { 'department' }
    return {
        appearance = row and type(row.appearance) == 'string' and row.appearance or tostring(appearances[1]),
        accent = row and U.isHexColour(row.accent) and row.accent:lower() or nil,
        uiScale = scale,
        language = row and type(row.language) == 'string' and row.language or nil,
        callsMuted = row ~= nil and U.truthy(row.calls_muted) or false,
    }
end

function Profile.languageFor(citizenid)
    local row = ReadRow(citizenid)
    return row and type(row.language) == 'string' and row.language ~= '' and row.language or nil
end

-- ============================================================================
--                              server:profile:set
-- ============================================================================

local function NextEditIn(row)
    local cooldown = math.max(0, Int(Cfg().editCooldown or 300))
    local last = row and Int(row.updated_ts) or 0
    if last <= 0 then return 0 end
    return math.max(0, last + cooldown - Now())
end

local function AvatarChange(officer, row, avatar, level)
    if type(avatar) ~= 'table' or not AVATAR_KINDS[avatar.kind] then return nil, 'err.invalid_payload' end
    if avatar.kind == 'initials' then
        return {
            { 'avatar_kind', 'initials' },
            { 'avatar_value', nil },
            { 'avatar_pending', nil },
            { 'avatar_status', 'none' },
        }
    end
    if avatar.kind == 'preset' then
        local p = type(avatar.value) == 'string' and Presets()[avatar.value] or nil
        if not p then return nil, 'err.avatar_preset' end
        if p.level and level.n < p.level then return nil, 'err.avatar_locked' end
        return {
            { 'avatar_kind', 'preset' },
            { 'avatar_value', avatar.value },
            { 'avatar_pending', nil },
            { 'avatar_status', 'none' },
        }
    end
    if UrlCfg().enabled ~= true then return nil, 'err.avatar_urls_off' end
    local okUrl, urlErr = Profile.validateUrl(avatar.value)
    if not okUrl then return nil, urlErr end
    if UrlsLeft(officer.citizenid) <= 0 then return nil, 'err.avatar_url_limit' end
    if UrlCfg().requireApproval ~= false then
        return { { 'avatar_pending', avatar.value }, { 'avatar_status', 'pending' } }, nil, true
    end
    return {
        { 'avatar_kind', 'url' },
        { 'avatar_value', avatar.value },
        { 'avatar_pending', nil },
        { 'avatar_status', 'approved' },
    },
        nil,
        false
end

local function LookChanges(officer, payload, level)
    local fields = {}
    if payload.appearance ~= nil then
        local ok = false
        for _, a in ipairs(type(Cfg().appearances) == 'table' and Cfg().appearances or {}) do
            if a == payload.appearance then ok = true end
        end
        if not ok then return nil, 'err.appearance_invalid' end
        fields[#fields + 1] = { 'appearance', payload.appearance }
    end
    if payload.accent ~= nil then
        if payload.accent == false or payload.accent == '' then
            fields[#fields + 1] = { 'accent', nil }
        else
            if not U.isHexColour(payload.accent) then return nil, 'err.accent_invalid' end
            local want, found = payload.accent:lower(), nil
            for _, a in ipairs(DeptAccents(officer.department)) do
                if a.colour == want then found = a end
            end
            if not found then return nil, 'err.accent_invalid' end
            if found.level and level.n < found.level then return nil, 'err.accent_locked' end
            fields[#fields + 1] = { 'accent', want }
        end
    end
    if payload.uiScale ~= nil then
        local n = tonumber(payload.uiScale)
        if not n or n ~= n then return nil, 'err.invalid_payload' end
        local lo, hi = ScaleRange()
        n = math.min(hi, math.max(lo, n))
        fields[#fields + 1] = { 'ui_scale', math.floor(n * 100 + 0.5) / 100 }
    end
    if payload.language ~= nil then
        -- English is the only language shipped: a language can only be cleared (the server language).
        if payload.language ~= false and payload.language ~= '' then return nil, 'err.language_invalid' end
        fields[#fields + 1] = { 'language', nil }
    end
    if payload.callsMuted ~= nil then
        if type(payload.callsMuted) ~= 'boolean' then return nil, 'err.invalid_payload' end
        fields[#fields + 1] = { 'calls_muted', payload.callsMuted and 1 or 0 }
    end
    return fields
end

-- Saves the officer's own profile. Returns true, { pending = { avatar, bio } } or false, errKey.
function Profile.set(officer, payload)
    if type(payload) ~= 'table' then return false, 'err.invalid_payload' end
    Db()
    local row = ReadRow(officer.citizenid)
    local level = LevelOf(row and row.xp or 0)
    local fields, err = LookChanges(officer, payload, level)
    if not fields then return false, err end
    local content = payload.bio ~= nil or payload.avatar ~= nil
    if content and NextEditIn(row) > 0 then return false, 'err.profile_cooldown' end
    local pending = { avatar = false, bio = false }
    local urlSubmitted = false
    if payload.avatar ~= nil then
        local av, avErr, isPending = AvatarChange(officer, row, payload.avatar, level)
        if not av then return false, avErr end
        for _, f in ipairs(av) do fields[#fields + 1] = f end
        pending.avatar = isPending == true
        urlSubmitted = payload.avatar.kind == 'url'
    end
    if payload.bio ~= nil then
        local bio, bioErr = Profile.validateBio(payload.bio)
        if bio == false then return false, bioErr end
        if bio == nil then
            fields[#fields + 1] = { 'bio', nil }
            fields[#fields + 1] = { 'bio_pending', nil }
        elseif Cfg().bioRequiresApproval == true then
            fields[#fields + 1] = { 'bio_pending', bio }
            pending.bio = true
        else
            fields[#fields + 1] = { 'bio', bio }
            fields[#fields + 1] = { 'bio_pending', nil }
        end
    end
    if content then fields[#fields + 1] = { 'profile_updated_at', sql = 'FROM_UNIXTIME(?)', param = Now() } end
    if #fields == 0 then return true, { pending = pending } end
    EnsureRow(officer)
    if not WriteFields(officer.citizenid, fields) then return false, 'err.internal' end
    if urlSubmitted then CountUrl(officer.citizenid) end
    if payload.callsMuted ~= nil and CP.MissionCalls and CP.MissionCalls._forgetMuted then
        CP.MissionCalls._forgetMuted(officer.citizenid)
    end
    if payload.avatar ~= nil then InvalidateBoards() end
    CP.log(TAG, '%s saved their profile', officer.citizenid)
    PushProfile(officer.citizenid)
    return true, { pending = pending }
end

-- getProfileEdit: what the Edit profile dialog shows.
function Profile.editView(officer)
    local row = ReadRow(officer.citizenid) or {}
    local level = LevelOf(row.xp)
    local pending = nil
    if row.avatar_status == 'pending' and NonEmpty(row.avatar_pending) then
        pending = { value = row.avatar_pending, status = 'pending' }
    elseif row.avatar_status == 'rejected' then
        pending = { value = '', status = 'rejected' }
    end
    return {
        bio = NonEmpty(row.bio),
        bioPending = NonEmpty(row.bio_pending),
        avatar = Profile.avatarOf(row, { own = true }),
        pending = pending,
        prefs = Profile.prefsFor(officer.citizenid),
        urlsLeftToday = UrlsLeft(officer.citizenid),
        nextEditIn = NextEditIn(row),
        level = level,
    }
end

-- ============================================================================
--                               PROFILE REPORTS
-- ============================================================================

local function ReportCfg() return type(Cfg().reports) == 'table' and Cfg().reports or {} end

function Profile.report(src, citizenid, reason, note)
    local officer, errKey = CP.Access.getOfficer(src)
    if not officer then return false, errKey or 'err.not_police' end
    if not ValidCitizenId(citizenid) then return false, 'err.invalid_citizenid' end
    if not REPORT_REASONS[reason] then return false, 'err.invalid_payload' end
    if citizenid == officer.citizenid then return false, 'err.report_self' end
    local text = nil
    if note ~= nil then
        text = CleanText(note, false)
        if not text then return false, 'err.invalid_payload' end
        if CharLen(text) > math.max(1, Int(ReportCfg().reasonMax or 140)) then return false, 'err.report_too_long' end
        if text == '' then text = nil end
    end
    Db()
    local target = ReadRow(citizenid)
    if not target then return false, 'err.unknown_officer' end
    local day = DayStart()
    local counts = MySQL.single.await([[
        SELECT COUNT(*) AS total, SUM(CASE WHEN citizenid = ? THEN 1 ELSE 0 END) AS same
        FROM cp_profile_reports WHERE reporter = ? AND created_at >= FROM_UNIXTIME(?)
    ]], { citizenid, officer.citizenid, day }) or {}
    if Int(counts.same) > 0 then return false, 'err.report_duplicate' end
    if Int(counts.total) >= math.max(0, Int(ReportCfg().perDay or 3)) then return false, 'err.report_limit' end
    local dept = NonEmpty(target.department) or officer.department
    local id = MySQL.insert.await(
        [[INSERT INTO cp_profile_reports (citizenid, reporter, reason, note, department, created_at)
        VALUES (?, ?, ?, ?, ?, FROM_UNIXTIME(?))]], { citizenid, officer.citizenid, reason, text, dept, Now() })
    if not id then return false, 'err.internal' end
    Audit(src, 'audit', 'profileReport', citizenid, nil, reason, text)
    CP.log(TAG, 'profile report %s on %s', tostring(id), citizenid)
    return true, { id = Int(id) }
end

-- ============================================================================
--                                COMMENDATIONS
-- ============================================================================

local COMMEND_SQL = [[
SELECT c.id, c.kind, c.citation, c.run_uuid, c.issued_by, c.revoked, c.revoke_reason, UNIX_TIMESTAMP(c.created_at) AS ts,
  o.display_name AS by_name, o.rank_label AS by_rank, o.callsign AS by_callsign, o.hide_name AS by_hidden
FROM cp_commendations c
LEFT JOIN cp_officers o ON o.citizenid = c.issued_by
WHERE c.citizenid = ? %s
ORDER BY c.created_at DESC, c.id DESC
LIMIT ?]]

local function KindLabel(kind)
    local key = 'profile.commend.kind.' .. tostring(kind)
    if CP.Locale and CP.Locale.has and CP.Locale.has(key) then return CP.L(key) end
    return tostring(kind)
end

-- The issuer as a profile shows them: an issuer who hides their name is shown by callsign, without a rank
-- (staff see the name).
local function CommendationRow(r, staff)
    local hidden = not staff and U.truthy(r.by_hidden)
    local by = r.issued_by == 'console' and CP.L('profile.commend.console')
        or (hidden and (NonEmpty(r.by_callsign) or CP.L('common.unknown')))
        or (NonEmpty(r.by_name) or CP.L('common.unknown'))
    local out = {
        id = Int(r.id),
        kind = tostring(r.kind),
        citation = tostring(r.citation),
        by = by,
        byRank = not hidden and NonEmpty(r.by_rank) or nil,
        at = Int(r.ts),
        runUuid = NonEmpty(r.run_uuid),
        revoked = U.truthy(r.revoked),
    }
    if staff then
        out.issuedBy = tostring(r.issued_by)
        out.revokeReason = NonEmpty(r.revoke_reason)
    end
    return out
end

-- viewer: a citizenid; each row then says whether that viewer issued it (mine), so the issuer can revoke it.
local function ReadCommendations(citizenid, staff, viewer)
    if not ValidCitizenId(citizenid) then return {} end
    Db()
    local rows = MySQL.query.await(COMMEND_SQL:format(staff and '' or 'AND c.revoked = 0'), { citizenid, LIST_LIMIT })
        or {}
    local out = {}
    for _, r in ipairs(rows) do
        local c = CommendationRow(r, staff)
        if viewer then c.mine = tostring(r.issued_by) == viewer end
        out[#out + 1] = c
    end
    return out
end

-- Active commendations, newest first (opts.staff: revoked ones too, with the issuer and revoke reason;
-- opts.viewer: a citizenid, marks the ones that viewer issued).
function Profile.commendations(citizenid, opts)
    opts = type(opts) == 'table' and opts or {}
    return ReadCommendations(citizenid, opts.staff == true, ValidCitizenId(opts.viewer) and opts.viewer or nil)
end

local function RefreshNews(citizenid)
    local days = math.max(0, Int(CommendCfg().announceDays or 7))
    local since = Now() - days * DAY_S
    local list = {}
    for _, c in ipairs(ReadCommendations(citizenid, false)) do
        if c.at >= since then list[#list + 1] = c end
    end
    news[citizenid] = { at = Now(), n = #list, list = list }
    return news[citizenid]
end

-- Commendations of the last announceDays days (the Home announcement and the sidebar badge).
function Profile.newCommendations(citizenid)
    if not ValidCitizenId(citizenid) then return 0 end
    local c = news[citizenid]
    if not c or Now() - c.at >= NEWS_CACHE_S then c = RefreshNews(citizenid) end
    return c.n
end

local function IssuerRole(src)
    if tonumber(src) == 0 then return 'admin' end
    if CP.Access.isAdmin(src) then return 'admin' end
    return 'supervisor'
end

-- Gives a commendation. role 'supervisor' or 'admin' (the caller has checked the permission).
function Profile.commend(src, role, payload)
    local cfg = CommendCfg()
    if cfg.enabled == false then return false, 'err.commendations_off' end
    if type(payload) ~= 'table' then return false, 'err.invalid_payload' end
    local cid, kind, runUuid = payload.citizenid, payload.kind, payload.runUuid
    if not ValidCitizenId(cid) then return false, 'err.invalid_citizenid' end
    local kindOk = false
    for _, k in ipairs(type(cfg.kinds) == 'table' and cfg.kinds or {}) do
        if k == kind then kindOk = true end
    end
    if not kindOk then return false, 'err.commend_kind' end
    local citation = CleanText(payload.citation, false)
    local lim = type(cfg.citation) == 'table' and cfg.citation or {}
    if not citation or CharLen(citation) < Int(lim[1] or 10) then return false, 'err.citation_short' end
    if CharLen(citation) > math.min(255, Int(lim[2] or 255)) then return false, 'err.citation_long' end
    if runUuid ~= nil and runUuid ~= '' and not ValidRunUuid(runUuid) then return false, 'err.invalid_run' end
    if runUuid == '' then runUuid = nil end
    Db()
    local issuer = 'console'
    local issuerDept = nil
    if tonumber(src) ~= 0 then
        local officer = CP.Access.getOfficer(src)
        if officer then
            issuer, issuerDept = officer.citizenid, officer.department
        else
            local ok, info = Call('Qbx', 'getInfo', src)
            if not (ok and type(info) == 'table' and info.citizenid) then return false, 'err.no_permission' end
            issuer = info.citizenid
        end
    end
    if issuer == cid then return false, 'err.commend_self' end
    local target = ReadRow(cid)
    if not target then return false, 'err.unknown_officer' end
    local dept = NonEmpty(target.department)
    if role == 'supervisor' then
        if cfg.crossDepartment ~= true and dept ~= issuerDept then return false, 'err.commend_other_dept' end
        local today = MySQL.scalar.await(
            'SELECT COUNT(*) AS n FROM cp_commendations WHERE issued_by = ? AND created_at >= FROM_UNIXTIME(?)',
            { issuer, DayStart() })
        if Int(today) >= math.max(0, Int(cfg.perSupervisorPerDay or 3)) then return false, 'err.commend_limit' end
    end
    if runUuid then
        if Has('Permissions', 'tookPart') and CP.Permissions.tookPart(issuer, runUuid) then
            return false, 'err.commend_own_run'
        end
        if not (Has('Permissions', 'tookPart') and CP.Permissions.tookPart(cid, runUuid)) then
            return false, 'err.commend_run'
        end
    end
    local cooldown = math.max(0, Int(cfg.sameKindCooldownDays or 7)) * DAY_S
    if cooldown > 0 then
        local recent = MySQL.scalar.await([[SELECT COUNT(*) AS n FROM cp_commendations
            WHERE citizenid = ? AND kind = ? AND revoked = 0 AND created_at >= FROM_UNIXTIME(?)]],
            { cid, kind, Now() - cooldown })
        if Int(recent) > 0 then return false, 'err.commend_recent' end
    end
    local id = MySQL.insert.await([[INSERT INTO cp_commendations
        (citizenid, kind, citation, run_uuid, department, issued_by, issuer_role, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, FROM_UNIXTIME(?))]],
        { cid, kind, citation, runUuid, dept or issuerDept or '', issuer, role, Now() })
    if not id then return false, 'err.internal' end
    Audit(src, 'audit', 'commend', cid, nil, kind, citation)
    RefreshNews(cid)
    Notify(cid, 'success', 'profile.commend.received', { kind = KindLabel(kind) })
    PushProfile(cid)
    if cfg.announce == true and Has('Admin', 'webhook') then
        local name = (U.truthy(target.hide_name) and NonEmpty(target.callsign)) or NonEmpty(target.display_name) or cid
        Call('Admin', 'webhook', 'board', CP.L('profile.commend.webhook_title', { kind = KindLabel(kind) }),
            CP.L('profile.commend.webhook_desc', { name = name, citation = citation }))
    end
    CP.log(TAG, 'commendation %s (%s) for %s by %s', tostring(id), kind, cid, issuer)
    return true, { id = Int(id) }
end

function Profile.revoke(src, role, payload)
    if type(payload) ~= 'table' then return false, 'err.invalid_payload' end
    local id = math.tointeger(tonumber(payload.id))
    if not id or id < 1 then return false, 'err.invalid_payload' end
    local reason, rErr = Reason(payload.reason)
    if not reason then return false, rErr end
    Db()
    local row = MySQL.single.await('SELECT id, citizenid, kind, issued_by, revoked FROM cp_commendations WHERE id = ?',
        { id })
    if not row then return false, 'err.commend_not_found' end
    if U.truthy(row.revoked) then return false, 'err.commend_revoked' end
    if role ~= 'admin' then
        local officer = CP.Access.getOfficer(src)
        if not officer or officer.citizenid ~= row.issued_by then return false, 'err.not_issuer' end
    end
    local actor = 'console'
    if tonumber(src) ~= 0 then
        local o = CP.Access.getOfficer(src)
        local ok, info = Call('Qbx', 'getInfo', src)
        actor = (o and o.citizenid) or (ok and type(info) == 'table' and info.citizenid) or ('player:%d'):format(src)
    end
    local changed = MySQL.update.await([[UPDATE cp_commendations SET revoked = 1, revoked_by = ?, revoke_reason = ?,
        revoked_at = FROM_UNIXTIME(?) WHERE id = ? AND revoked = 0]], { actor, reason, Now(), id })
    if Int(changed) <= 0 then return false, 'err.commend_revoked' end
    Audit(src, 'audit', 'revokeCommendation', tostring(row.citizenid), tostring(row.kind), 'revoked', reason)
    RefreshNews(tostring(row.citizenid))
    PushProfile(tostring(row.citizenid))
    return true, { id = id }
end

-- ============================================================================
--                                  MODERATION
-- ============================================================================

-- The officer a supervisor may moderate: same department (and never themselves); admins anyone but themselves.
local function ModerationTarget(src, role, citizenid)
    if not ValidCitizenId(citizenid) then return nil, 'err.invalid_citizenid' end
    local row = ReadRow(citizenid)
    if not row then return nil, 'err.unknown_officer' end
    if tonumber(src) ~= 0 then
        local officer = CP.Access.getOfficer(src)
        if officer and officer.citizenid == citizenid then return nil, 'err.own_profile' end
        if role ~= 'admin' then
            if not officer then return nil, 'err.no_permission' end
            if officer.department ~= NonEmpty(row.department) then return nil, 'err.profile_other_dept' end
        end
    end
    return row
end

function Profile.review(src, role, payload)
    if type(payload) ~= 'table' then return false, 'err.invalid_payload' end
    local decision, what = payload.decision, payload.what or 'avatar'
    if decision ~= 'approve' and decision ~= 'reject' then return false, 'err.invalid_payload' end
    if what ~= 'avatar' and what ~= 'bio' then return false, 'err.invalid_payload' end
    local reason, rErr = Reason(payload.reason)
    if not reason then return false, rErr end
    Db()
    local row, err = ModerationTarget(src, role, payload.citizenid)
    if not row then return false, err end
    local cid = tostring(row.citizenid)
    local reviewer = tonumber(src) == 0 and 'console' or (ViewerCid(src) or ('player:%d'):format(src))
    local changed
    if what == 'avatar' then
        local link = NonEmpty(row.avatar_pending)
        if row.avatar_status ~= 'pending' or not link then return false, 'err.nothing_pending' end
        if decision == 'approve' then
            changed = MySQL.update.await(
                [[UPDATE cp_officers SET avatar_kind = 'url', avatar_value = ?, avatar_pending = NULL,
                avatar_status = 'approved', avatar_reviewed_by = ? WHERE citizenid = ? AND avatar_status = 'pending' AND avatar_pending = ?]],
                { link, U.clip(reviewer, 50), cid, link })
        else
            changed = MySQL.update.await([[UPDATE cp_officers SET avatar_pending = NULL, avatar_status = 'rejected',
                avatar_reviewed_by = ? WHERE citizenid = ? AND avatar_status = 'pending' AND avatar_pending = ?]],
                { U.clip(reviewer, 50), cid, link })
        end
    else
        local bio = NonEmpty(row.bio_pending)
        if not bio then return false, 'err.nothing_pending' end
        if decision == 'approve' then
            changed = MySQL.update.await(
                'UPDATE cp_officers SET bio = bio_pending, bio_pending = NULL WHERE citizenid = ? AND bio_pending = ?',
                { cid, bio })
        else
            changed = MySQL.update.await(
                'UPDATE cp_officers SET bio_pending = NULL WHERE citizenid = ? AND bio_pending = ?', { cid, bio })
        end
    end
    if Int(changed) <= 0 then return false, 'err.nothing_pending' end
    Audit(src, 'audit', what == 'avatar' and 'reviewAvatar' or 'reviewBio', cid, 'pending', decision, reason)
    Notify(cid, decision == 'approve' and 'success' or 'warning', ('profile.review.%s_%s'):format(what, decision))
    PushProfile(cid)
    InvalidateBoards()
    return true, { citizenid = cid, decision = decision }
end

local function ClearFields(what)
    if what == 'bio' then return { { 'bio', nil }, { 'bio_pending', nil } } end
    return {
        { 'avatar_kind', 'initials' },
        { 'avatar_value', nil },
        { 'avatar_pending', nil },
        { 'avatar_status', 'none' },
    }
end

function Profile.clear(src, role, payload)
    if type(payload) ~= 'table' then return false, 'err.invalid_payload' end
    local what = payload.what
    if what ~= 'bio' and what ~= 'avatar' then return false, 'err.invalid_payload' end
    local reason, rErr = Reason(payload.reason)
    if not reason then return false, rErr end
    Db()
    local row, err = ModerationTarget(src, role, payload.citizenid)
    if not row then return false, err end
    local cid = tostring(row.citizenid)
    if not WriteFields(cid, ClearFields(what)) then return false, 'err.internal' end
    Audit(src, 'audit', what == 'bio' and 'clearBio' or 'clearAvatar', cid, nil, 'cleared', reason)
    Notify(cid, 'warning', ('profile.review.%s_cleared'):format(what))
    PushProfile(cid)
    InvalidateBoards()
    return true, { citizenid = cid, what = what }
end

function Profile.handleReport(src, role, payload)
    if type(payload) ~= 'table' then return false, 'err.invalid_payload' end
    local id = math.tointeger(tonumber(payload.id))
    if not id or id < 1 then return false, 'err.invalid_payload' end
    local decision = payload.decision
    if decision ~= 'clear' and decision ~= 'dismiss' then return false, 'err.invalid_payload' end
    local reason, rErr = Reason(payload.reason)
    if not reason then return false, rErr end
    Db()
    local rep = MySQL.single.await(
        'SELECT id, citizenid, reason, department, status FROM cp_profile_reports WHERE id = ?', { id })
    if not rep then return false, 'err.report_not_found' end
    if rep.status ~= 'open' then return false, 'err.report_handled' end
    local officer = tonumber(src) ~= 0 and CP.Access.getOfficer(src) or nil
    if role ~= 'admin' and (not officer or officer.department ~= rep.department) then
        return false, 'err.profile_other_dept'
    end
    if officer and officer.citizenid == rep.citizenid then return false, 'err.own_profile' end
    local handler = tonumber(src) == 0 and 'console' or (ViewerCid(src) or ('player:%d'):format(src))
    local changed = MySQL.update.await(
        [[UPDATE cp_profile_reports SET status = ?, handled_by = ?, handled_at = FROM_UNIXTIME(?)
        WHERE id = ? AND status = 'open']],
        { decision == 'clear' and 'cleared' or 'dismissed', U.clip(handler, 50), Now(), id })
    if Int(changed) <= 0 then return false, 'err.report_handled' end
    local cid = tostring(rep.citizenid)
    if decision == 'clear' and (rep.reason == 'picture' or rep.reason == 'bio') then
        WriteFields(cid, ClearFields(rep.reason == 'bio' and 'bio' or 'avatar'))
        Notify(cid, 'warning', ('profile.review.%s_cleared'):format(rep.reason == 'bio' and 'bio' or 'avatar'))
        PushProfile(cid)
        InvalidateBoards()
    end
    Audit(src, 'audit', decision == 'clear' and 'clearReport' or 'dismissReport', cid, tostring(rep.reason), decision,
        reason)
    return true, { id = id, decision = decision }
end

-- ============================================================================
--                                 REVIEW QUEUE
-- ============================================================================

local function DeptShort(key)
    local d = type(Config.Departments) == 'table' and key and Config.Departments[key] or nil
    return type(d) == 'table' and tostring(d.short or key:upper()) or (type(key) == 'string' and key:upper() or '')
end

local function QueueItem(kind, r, extra)
    local item = {
        kind = kind,
        id = nil,
        citizenid = tostring(r.citizenid),
        name = NonEmpty(r.display_name) or CP.L('common.unknown'),
        callsign = NonEmpty(r.callsign),
        departmentShort = DeptShort(NonEmpty(r.department)),
        url = nil,
        text = nil,
        reason = nil,
        submittedAt = Int(r.updated_ts),
    }
    for k, v in pairs(extra) do item[k] = v end
    return item
end

-- The Profiles tab: pending pictures, pending bios and open reports of one department (nil = every department).
function Profile.queue(dept)
    Db()
    local items = {}
    local where, params = '', {}
    if dept then where, params = 'AND department = ?', { dept } end
    local pendingParams = U.copy(params)
    pendingParams[#pendingParams + 1] = QUEUE_LIMIT
    for _, r in
        ipairs(MySQL.query.await(
            ([[SELECT citizenid, display_name, callsign, department, avatar_pending, bio,
        bio_pending, UNIX_TIMESTAMP(profile_updated_at) AS updated_ts FROM cp_officers
        WHERE ((avatar_status = 'pending' AND avatar_pending IS NOT NULL) OR bio_pending IS NOT NULL) %s
        ORDER BY profile_updated_at ASC, citizenid ASC LIMIT ?]]):format(where),
            pendingParams
        ) or {})
    do
        if NonEmpty(r.avatar_pending) then items[#items + 1] = QueueItem('avatar', r, { url = r.avatar_pending }) end
        if NonEmpty(r.bio_pending) then
            items[#items + 1] = QueueItem('bio', r, { text = r.bio_pending, current = NonEmpty(r.bio) })
        end
    end
    local repWhere = dept and 'AND p.department = ?' or ''
    local repParams = U.copy(params)
    repParams[#repParams + 1] = QUEUE_LIMIT
    for _, r in
        ipairs(
            MySQL.query.await(
                ([[SELECT p.id, p.citizenid, p.reason, p.note, p.department,
        UNIX_TIMESTAMP(p.created_at) AS created_ts, o.display_name, o.callsign, o.bio, o.avatar_kind, o.avatar_value
        FROM cp_profile_reports p LEFT JOIN cp_officers o ON o.citizenid = p.citizenid
        WHERE p.status = 'open' %s ORDER BY p.created_at ASC, p.id ASC LIMIT ?]]):format(repWhere),
                repParams
            ) or {}
        )
    do
        items[#items + 1] = QueueItem('report', r, {
            id = Int(r.id),
            -- the live picture and bio as everyone sees them now (an approved link can change at its host)
            url = r.avatar_kind == 'url' and NonEmpty(r.avatar_value) or nil,
            text = NonEmpty(r.bio),
            reason = tostring(r.reason),
            note = NonEmpty(r.note),
            submittedAt = Int(r.created_ts),
        })
    end
    return items
end

-- ============================================================================
--                               ADMIN · OFFICERS
-- ============================================================================

-- admin:getOfficerProfile: the public profile plus what only staff see (pending picture and bio, every
-- commendation with revoked ones, open reports, the service record).
function Profile.adminView(citizenid)
    if not ValidCitizenId(citizenid) then return nil, 'err.invalid_citizenid' end
    local row = ReadRow(citizenid)
    if not row then return nil, 'err.unknown_officer' end
    local base = nil
    if Has('Leaderboard', 'profile') then
        local ok, p = Call('Leaderboard', 'profile', { citizenid = '' }, citizenid, { staff = true })
        if ok and type(p) == 'table' then base = p end
    end
    base = base or { citizenid = citizenid, name = NonEmpty(row.display_name) or citizenid }
    base.realName = NonEmpty(row.display_name) or CP.L('common.unknown')
    base.bio = NonEmpty(row.bio)
    base.bioPending = NonEmpty(row.bio_pending)
    base.avatar = Profile.avatarOf(row, { own = true })
    base.pendingAvatar = row.avatar_status == 'pending' and NonEmpty(row.avatar_pending) or nil
    base.avatarStatus = tostring(row.avatar_status or 'none')
    base.commendations = ReadCommendations(citizenid, true)
    local reports = {}
    for _, r in
        ipairs(
            MySQL.query.await([[SELECT id, reason, note, UNIX_TIMESTAMP(created_at) AS created_ts
        FROM cp_profile_reports WHERE citizenid = ? AND status = 'open' ORDER BY created_at ASC, id ASC LIMIT ?]],
                { citizenid, QUEUE_LIMIT }) or {}
        )
    do
        reports[#reports + 1] = {
            id = Int(r.id),
            reason = tostring(r.reason),
            note = NonEmpty(r.note),
            at = Int(r.created_ts),
        }
    end
    base.reports = reports
    return base
end

-- ============================================================================
--                                 NET HANDLERS
-- ============================================================================

CP.Net.callback('getProfileEdit', function(src)
    local officer, errKey = CP.Access.getOfficer(src)
    if not officer then return nil, errKey end
    return Profile.editView(officer)
end)

CP.Net.action('server:profile:set', function(src, payload)
    local officer, errKey = CP.Access.getOfficer(src)
    if not officer then return false, errKey end
    return Profile.set(officer, payload)
end, { rate = 2 })

CP.Net.action('server:profile:report', function(src, payload)
    if type(payload) ~= 'table' then return false, 'err.invalid_payload' end
    return Profile.report(src, payload.citizenid, payload.reason, payload.note)
end, { rate = 1 })

-- Supervisor handlers check the permission first (ARCHITECTURE §0.7), then the payload.
local function SupAction(permission, fn)
    return function(src, payload)
        local ok, errKey = CP.Permissions.can(src, permission)
        if not ok then return false, errKey or 'err.no_permission' end
        return fn(src, 'supervisor', payload)
    end
end

local function AdminAction(fn)
    return function(src, payload)
        local ok, errKey = CP.Permissions.can(src, 'openAdmin')
        if not ok then return false, errKey or 'err.no_permission' end
        return fn(src, 'admin', payload)
    end
end

CP.Net.action('server:sup:commend', SupAction('issueCommendation', Profile.commend), { rate = 2 })
CP.Net.action('server:admin:commend', AdminAction(Profile.commend), { rate = 2 })
CP.Net.action('server:sup:revokeCommendation', SupAction('issueCommendation', Profile.revoke), { rate = 2 })
CP.Net.action('server:admin:revokeCommendation', AdminAction(Profile.revoke), { rate = 2 })
CP.Net.action('server:sup:reviewAvatar', SupAction('reviewProfiles', Profile.review), { rate = 4 })
CP.Net.action('server:admin:reviewAvatar', AdminAction(Profile.review), { rate = 4 })
CP.Net.action('server:sup:clearProfile', SupAction('reviewProfiles', Profile.clear), { rate = 4 })
CP.Net.action('server:admin:clearProfile', AdminAction(Profile.clear), { rate = 4 })
CP.Net.action('server:sup:handleReport', SupAction('reviewProfiles', Profile.handleReport), { rate = 4 })
CP.Net.action('server:admin:handleReport', AdminAction(Profile.handleReport), { rate = 4 })

CP.Net.callback('sup:getProfileQueue', function(src, args)
    local ok, errKey = CP.Permissions.can(src, 'reviewProfiles')
    if not ok then return nil, errKey or 'err.no_permission' end
    if args ~= nil and type(args) ~= 'table' then return nil, 'err.invalid_payload' end
    local officer = CP.Access.getOfficer(src)
    local dept = officer and officer.department or nil
    if CP.Access.isAdmin(src) then
        local wanted = args and args.department
        dept = (type(wanted) == 'string' and wanted ~= '') and wanted or (officer and dept or nil)
    end
    if not dept and not CP.Access.isAdmin(src) then return nil, 'err.not_police' end
    return Profile.queue(dept)
end)

CP.Net.callback('admin:getOfficerProfile', function(src, args)
    local ok, errKey = CP.Permissions.can(src, 'openAdmin')
    if not ok then return nil, errKey or 'err.no_permission' end
    if type(args) ~= 'table' then return nil, 'err.invalid_payload' end
    return Profile.adminView(args.citizenid)
end)

-- ============================================================================
--                                    HOOKS
-- ============================================================================

-- Home: "Commended for Valor by ..." for announceDays days. Read from the cache only (the hook may not yield);
-- a missing entry is loaded in a thread for the next Home refresh.
local function HomeExtras(citizenid, _, extras)
    if type(extras) ~= 'table' or not ValidCitizenId(citizenid) then return end
    local c = news[citizenid]
    if not c or Now() - c.at >= NEWS_CACHE_S then
        CreateThread(function()
            local ok, err = pcall(RefreshNews, citizenid)
            if not ok then CP.err(TAG, 'commendation news of %s failed: %s', citizenid, tostring(err)) end
        end)
    end
    if not c then return end
    extras.commendations = c.n
    extras.news = extras.news or {}
    for _, e in ipairs(c.list) do
        extras.news[#extras.news + 1] = {
            kind = 'commendation',
            text = CP.L('profile.commend.news', { kind = KindLabel(e.kind), by = e.by }),
            at = e.at,
        }
    end
end

if CP.Hooks and CP.Hooks.on then
    CP.Hooks.on('home:extras', HomeExtras)
    CP.Hooks.on('officer:loaded', function(src)
        local ok, info = Call('Qbx', 'getInfo', src)
        if ok and type(info) == 'table' and ValidCitizenId(info.citizenid) then RefreshNews(info.citizenid) end
    end)
end

-- Test hooks (not part of the contract).
Profile._resetCaches = function()
    urlSubmits, news, banned = {}, {}, nil
end
Profile._news = function(citizenid) return news[citizenid] end

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    urlSubmits, news = {}, {}
end)
