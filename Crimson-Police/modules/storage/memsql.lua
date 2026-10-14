-- CP.Storage.MemSQL: the SQL engine and the saves folder behind "database off" (Config.Database.enabled = false).
-- fxmanifest loads it before every other server module; it only defines functions. modules/storage/server.lua decides
-- whether it is used.

CP = CP or {}
CP.Storage = CP.Storage or {}   -- the storage module's one global table (modules/storage/server.lua fills in the rest)
CP.Storage.MemSQL = {}
local M = CP.Storage.MemSQL

local sbyte, schar, sfind, sformat, sgsub, slower, smatch, ssub, supper, spack, sgmatch =
    string.byte,
    string.char,
    string.find,
    string.format,
    string.gsub,
    string.lower,
    string.match,
    string.sub,
    string.upper,
    string.pack,
    string.gmatch
local srep = string.rep
local concat, tsort, tremove, tinsert = table.concat, table.sort, table.remove, table.insert
local mtype, mtointeger, mfloor, mabs, mmax, mmin, mhuge =
    math.type, math.tointeger, math.floor, math.abs, math.max, math.min, math.huge
local MININT, MAXINT = math.mininteger, math.maxinteger
local utf8len, utf8char = utf8.len, utf8.char
local type, tostring, tonumber, pairs, ipairs, pcall, error, setmetatable, next, select, rawequal =
    type, tostring, tonumber, pairs, ipairs, pcall, error, setmetatable, next, select, rawequal

local DBNAME = 'saves'   -- shown where MariaDB would name the database in an error message

local function Fail(msg) error(msg, 0) end
local function Unsupported(what) error('the saves folder engine (files mode) does not support ' .. what, 0) end
M.unsupportedPrefix = 'the saves folder engine (files mode) does not support '

local function Warn(msg)
    if CP.warn then CP.warn('storage', '%s', msg) else print('[crimson-police:storage] ' .. msg) end
end

-- ============================================================================
--                     1. VALUES, NUMBERS, TIME, COLLATION
-- ============================================================================
-- Runtime values: nil = NULL; integers (INT family, TINYINT(1), booleans 1/0, DATETIME and DATE as unix
-- seconds); DECIMAL(p,s) as an integer scaled by 10^s (the scale is part of the static type); DOUBLE as a
-- float; text, ENUM and JSON as strings.

local POW10 = {}
do
    local p = 1
    for i = 0, 18 do POW10[i] = p; p = p * 10 end
end
local DECFMT = {}
for s = 1, 18 do DECFMT[s] = { '%d.%0' .. s .. 'd', '-%d.%0' .. s .. 'd' } end

local function FmtDec(v, s)
    if s == 0 then return sformat('%d', v) end
    local p, f = POW10[s], DECFMT[s]
    if v < 0 then v = -v; return sformat(f[2], v // p, v % p) end
    return sformat(f[1], v // p, v % p)
end

-- '12.345' -> 12345, 3 (nil when it is not a plain decimal or has more than 18 digits)
local function DecFromText(text)
    local sign, ip, fp = smatch(text, '^%s*([-+]?)(%d*)%.?(%d*)%s*$')
    if not sign or (ip == '' and fp == '') or #ip + #fp > 18 then return nil end
    local v = mtointeger(tonumber((ip == '' and '0' or ip) .. fp))
    if not v then return nil end
    if sign == '-' then v = -v end
    return v, #fp
end

-- Shortest text that reads back as the same float (what JavaScript, and so oxmysql, would send).
local function ShortFloat(x)
    for p = 15, 17 do
        local s = sformat('%.' .. p .. 'g', x)
        if tonumber(s) == x then return s end
    end
    return sformat('%.17g', x)
end

local FmtDouble, Gcvt
do
    -- The digits of a double the way MariaDB's dtoa gives them: digits (no leading or trailing zeros; '0' for 0) and
    -- decpt, the place of the decimal point (0.05 -> '5', -1; 120 -> '12', 3).
    --   dtoaShort(x): the shortest digits that read back as x (dtoa mode 0).
    --   dtoaSig(x, n): at most n significant digits, the shortest when those are enough (mode 4).
    --   dtoaFix(x, n): rounded to n digits after the point, the shortest when that is enough (mode 5; '' when
    --   nothing is left).
    local function SciDigits(e)
        local d1, rest, ex = smatch(e, '^%-?(%d)%.?(%d*)e([-+]%d+)$')
        local digits = sgsub(d1 .. rest, '0+$', '')
        if digits == '' then return '0', 1 end
        return digits, tonumber(ex) + 1
    end
    local function DtoaShort(x)
        if x == 0 then return '0', 1 end
        -- 15 digits hold every shorter answer too, except for subnormal numbers (fewer digits of precision)
        for p = mabs(x) < 2.3e-308 and 0 or 14, 15 do
            local s = sformat('%.' .. p .. 'e', x)
            if tonumber(s) == x then return SciDigits(s) end
        end
        return SciDigits(sformat('%.16e', x))
    end
    local function DtoaSig(x, n)
        local d, p = DtoaShort(x)
        if #d <= n or x == 0 then return d, p end
        if n < 1 then n = 1 end
        return SciDigits(sformat('%.' .. (n - 1) .. 'e', x))
    end
    local function DtoaFix(x, n)
        local d, p = DtoaShort(x)
        if #d - p <= n or x == 0 then return d, p end
        if n < 0 then n = 0 end
        local s = sformat('%.' .. n .. 'f', mabs(x))
        local ip, fp = smatch(s, '^(%d+)%.?(%d*)$')
        local all = sgsub(ip .. fp, '^0+', '')
        local lead = #ip + #fp - #all          -- zeros dropped at the front
        local digits = sgsub(all, '0+$', '')
        if digits == '' then return '', 0 end
        return digits, #ip - lead
    end

    local MAX_DECPT_F = 15 -- DBL_DIG: MariaDB's my_gcvt uses the e format beyond this

    -- A double as MariaDB's text for it (my_gcvt with room to spare): 0.00001, 100, 1.5e15, 1e-16.
    FmtDouble = function(x)
        if x ~= x then return 'nan' end
        if x == mhuge then return 'inf' elseif x == -mhuge then return '-inf' end
        if x == 0 then return 1 / x < 0 and '-0' or '0' end
        local i = mtointeger(x)
        if i and mabs(x) < 1e15 then return sformat('%d', i) end
        local d, p = DtoaShort(x)
        local len = #d
        local sign = x < 0 and '-' or ''
        if p >= -MAX_DECPT_F + 1 and (p <= MAX_DECPT_F or len > p) then
            if p <= 0 then return sign .. '0.' .. srep('0', -p) .. d end
            if p < len then return sign .. ssub(d, 1, p) .. '.' .. ssub(d, p + 1) end
            return sign .. d .. srep('0', p - len)
        end
        local e = p - 1
        return sign .. ssub(d, 1, 1) .. (len > 1 and ('.' .. ssub(d, 2)) or '') .. 'e' .. (e < 0 and '-' or '')
            .. mabs(e)
    end

    -- A double in at most width characters, as MariaDB stores one in a VARCHAR(width) (my_gcvt): the most
    -- significant digits that fit, in the f format or the e format. Returns the text and whether even that did not fit.
    Gcvt = function(x, width)
        if x ~= x or x == mhuge or x == -mhuge then return '0', true end
        local full = width
        local neg = x < 0 or (x == 0 and 1 / x < 0)
        if x < 0 then width = width - 1 end
        local d, p = DtoaSig(x, width)
        local len = #d
        local expLen = 1 + ((p >= 101 or p <= -99) and 1 or 0) + ((p >= 11 or p <= -9) and 1 or 0)
        local need = p <= 0 and (len - p + 2) or ((p > 0 and p < len) and (len + 1) or p)
        local haveSpace = need <= width
        local forceE = p <= 0 and width <= 2 - p and width >= 3 + expLen
        local err = false
        local out
        if (haveSpace or ((p <= width and (p >= -1 or (p == -2 and (len > 1 or not forceE)))) and not forceE))
            and (not haveSpace or (p >= -MAX_DECPT_F + 1 and (p <= MAX_DECPT_F or len > p))) then
            local w = width - ((p < len) and 1 or 0) - (p <= 0 and (1 - p) or 0)
            if w < len then
                if w < p then err = true; w = p end
                d, p = DtoaFix(x, w - p)
                len = #d
            end
            if len == 0 then return '0', err end
            if p <= 0 then
                out = '0.' .. srep('0', -p) .. d
            elseif p < len then
                out = ssub(d, 1, p) .. '.' .. ssub(d, p + 1)
            else
                out = d .. srep('0', p - len)
            end
        else
            local e, eneg = p - 1, false
            local w = width
            if e < 0 then e = -e; w = w - 1; eneg = true end
            w = w - 1 - expLen
            if len > 1 then w = w - 1 end
            if w <= 0 then err = true; w = 0 end
            if w < len then
                d, p = DtoaSig(x, w)
                len = #d
                e = p - 1
                if e < 0 then e = -e end
            end
            out = ssub(d, 1, 1) .. (len > 1 and ('.' .. ssub(d, 2)) or '') .. 'e' .. (eneg and '-' or '') .. e
        end
        out = (neg and '-' or '') .. out
        if #out > full then out = ssub(out, 1, full) end
        return out, err
    end
end

-- a * b for scaled decimals; a DECIMAL beyond 18 digits (MariaDB goes to 65) is refused instead of wrapping around
local function DecMul(a, b)
    local r = a * b
    if b ~= 0 and r // b ~= a then   -- (a wrapped product never divides back)
        Unsupported('DECIMAL values of more than 18 digits')
    end
    return r
end

-- Rescale a scaled decimal, rounding half away from zero when decimals are dropped.
local function Rescale(v, from, to)
    if from == to then return v end
    if to > from then return DecMul(v, POW10[to - from]) end
    local p = POW10[from - to]
    local neg = v < 0
    if neg then v = -v end
    local q, r = v // p, v % p
    if r * 2 >= p then q = q + 1 end
    return neg and -q or q
end

local function FloatToDec(x, s)
    local y = x * POW10[s]
    if y >= 0 then return mfloor(y + 0.5) end
    return -mfloor(-y + 0.5)
end

local function RoundHalfEven(x)
    local f = mfloor(x)
    local d = x - f
    if d > 0.5 then return f + 1 elseif d < 0.5 then return f end
    if f % 2 == 0 then return f end
    return f + 1
end

-- MariaDB's string -> number conversion: the leading numeric part, else 0 (a double).
local function StrToNum(s)
    local num = smatch(s, '^%s*([-+]?%d+%.?%d*[eE][-+]?%d+)') or smatch(s, '^%s*([-+]?%.%d+[eE][-+]?%d+)')
        or smatch(s, '^%s*([-+]?%d+%.?%d*)') or smatch(s, '^%s*([-+]?%.%d+)')
    if not num then return 0.0 end
    if sbyte(num, 1) == 43 then num = ssub(num, 2) end
    local v = tonumber(num)
    if not v then return 0.0 end
    return v + 0.0
end

-- ============================================================================
--             TIME (unix seconds, the FXServer's local time zone)
-- ============================================================================

local function FmtDT(t) return os.date('%Y-%m-%d %H:%M:%S', t) end
local function FmtDate(t) return os.date('%Y-%m-%d', t) end

local Midnight, ParseDT, DateFormat, StrTime, NumTime
do
    local MIDC, midN = {}, 0
    Midnight = function(t)
        local b = t // 900 -- every time zone offset is a multiple of 15 minutes
        local m = MIDC[b]
        if m then return m end
        local d = os.date('*t', t)
        m = os.time({ year = d.year, month = d.month, day = d.day, hour = 0, min = 0, sec = 0 })
        midN = midN + 1
        if midN > 20000 then MIDC, midN = {}, 0 end
        MIDC[b] = m
        return m
    end

    local DIM = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    local function DaysIn(mo, y)
        if mo == 2 and y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0) then return 29 end
        return DIM[mo]
    end
    local SPACEB = { [32] = true, [9] = true, [10] = true, [11] = true, [12] = true, [13] = true }
    local function IsDig(c) return c ~= nil and c >= 48 and c <= 57 end
    local function IsPunct(c)
        return c ~= nil
            and ((c >= 33 and c <= 47) or (c >= 58 and c <= 64) or (c >= 91 and c <= 96) or (c >= 123 and c <= 126))
    end

    -- A date/time from its parts: unix seconds, status, isDate, hasTime (see strTime).
    local function TimeOf(y, mo, d, h, mi, se, frac, isDate, status)
        if y > 9999 or mo > 12 or d > 31 or h > 23 or mi > 59 or se > 59 then return nil, 'bad' end
        if mo ~= 0 and d ~= 0 and d > DaysIn(mo, y) then return nil, 'bad' end
        local hasTime = h ~= 0 or mi ~= 0 or se ~= 0 or frac
        if mo == 0 or d == 0 or y < 1000 then return nil, 'zero', isDate, hasTime end
        return os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = se }), status, isDate, hasTime
    end

    -- MariaDB's reading of a text as a date or date and time (str_to_datetime_or_date, sql-common/my_time.c):
    -- 'YYYY-MM-DD[ HH:MM:SS[.ffffff]]' with any punctuation between the parts, one or two digit parts, a two digit
    -- year (70-99 -> 19xx, else 20xx), a T or spaces before the time, the time cut short ('2026-09-01 10'), and
    -- digits only ([YY]YYMMDD[[T]hhmmss[.ffffff]]). Returns unix seconds (local time) or nil, and a status:
    --   nil clean; 'cut' something after the value was left out (a warning: an error in strict mode); 'note' more
    --   than 6 digits of fraction dropped; 'bad' not a date (MariaDB: an error, with IGNORE the zero date); 'zero' a
    --   zero date, a zero month or day, or a year before 1000 (MariaDB keeps those; the engine cannot hold them).
    -- Also isDate (only the date was given) and hasTime (a time or fraction that is not zero).
    StrTime = function(s)
        local a, z = 1, #s
        while a <= z and SPACEB[sbyte(s, a)] do a = a + 1 end
        while z >= a and SPACEB[sbyte(s, z)] do z = z - 1 end
        if a > z or sbyte(s, a) == 45 then return nil, 'bad' end
        local f1, f2, f3, f4, f5, f6 = 0, 0, 0, 0, 0, 0
        local nf, i, warn = 0, a, false
        -- one part: digits up to limit (inclusive) -> true (none at the end is fine), false when no digit is there
        local function num(k, limit)
            if i > z then return true end
            if not IsDig(sbyte(s, i)) then return false end
            local j = i + 1
            while j <= limit and IsDig(sbyte(s, j)) do j = j + 1 end
            local v = j - i > 9 and 999999999 or tonumber(ssub(s, i, j - 1))
            if k == 1 then
                f1 = v
            elseif k == 2 then
                f2 = v
            elseif k == 3 then
                f3 = v
            elseif k == 4 then
                f4 = v
            elseif k == 5 then
                f5 = v
            else
                f6 = v
            end
            i = j
            nf = nf + 1
            return true
        end
        local function punct()
            if i > z then return true end
            if IsPunct(sbyte(s, i)) then i = i + 1; return true end
            return false
        end
        local function sep()
            if i > z then return true end
            local c = sbyte(s, i)
            if c == 84 or IsPunct(c) then i = i + 1; return true end
            if not SPACEB[c] then return false end
            repeat
                i = i + 1
            until i > z or not SPACEB[sbyte(s, i)]
            return true
        end
        local p = a
        while p <= z and IsDig(sbyte(s, p)) do p = p + 1 end
        local digits = p - a
        if p <= z and sbyte(s, p) == 84 then
            p = p + 1
            local q = p
            while p <= z and IsDig(sbyte(s, p)) do p = p + 1 end
            digits = digits + p - q
        end
        if p <= z and sbyte(s, p) == 46 and digits >= 12 then
            p = p + 1
            while p <= z and IsDig(sbyte(s, p)) do p = p + 1 end
        end
        local yearLen
        if p > z then
            yearLen = (digits == 4 or digits == 8 or digits >= 14) and 4 or 2
            local ok = num(1, mmin(z, i + yearLen - 1)) and num(2, mmin(z, i + 1)) and num(3, mmin(z, i + 1))
            if ok then
                if i <= z and sbyte(s, i) == 84 then i = i + 1 end
                ok = num(4, mmin(z, i + 1)) and num(5, mmin(z, i + 1)) and num(6, mmin(z, i + 1))
            end
            if not ok then warn = true end
        else
            local start = i
            if not num(1, z) then warn = true end
            yearLen = i - start
            if
                not warn
                and not (
                    punct()
                    and num(2, z)
                    and punct()
                    and num(3, z)
                    and sep()
                    and num(4, z)
                    and punct()
                    and num(5, z)
                    and punct()
                    and num(6, z)
                )
            then
                warn = true
            end
        end
        if nf < 3 then return nil, 'bad' end
        local frac, note = false, false
        if not warn and i <= z and sbyte(s, i) == 46 then
            i = i + 1
            if i <= z and not IsDig(sbyte(s, i)) then
                warn = true
            else
                local q = i
                while i <= z and i < q + 6 and IsDig(sbyte(s, i)) do i = i + 1 end
                if sfind(ssub(s, q, i - 1), '[1-9]') then frac = true end
                local r = i
                while i <= z and IsDig(sbyte(s, i)) do i = i + 1 end
                if i > r then note = true end
            end
        end
        local notZero = f1 ~= 0 or f2 ~= 0 or f3 ~= 0 or f4 ~= 0 or f5 ~= 0 or f6 ~= 0 or frac
        if yearLen == 2 and notZero then f1 = f1 + (f1 < 70 and 2000 or 1900) end
        local status = (warn or i <= z) and 'cut' or (note and 'note') or nil
        if not notZero then return nil, 'zero', nf <= 3, false end
        return TimeOf(f1, f2, f3, f4, f5, f6, frac, nf <= 3, status)
    end

    -- MariaDB's reading of a number as a date (number_to_datetime): YYYYMMDD, YYMMDD, YYYYMMDDhhmmss, YYMMDDhhmmss;
    -- hasFrac: the number had a fraction (dropped; a note when only a date was given). Returns like strTime.
    NumTime = function(nr, hasFrac)
        if nr < 0 then return nil, 'bad' end
        if nr == 0 then return nil, 'zero', true, hasFrac end
        local isDate = true
        if nr >= 10000101000000 then
            isDate = false
        elseif nr < 101 then
            return nil, 'bad'
        elseif nr <= 691231 then
            nr = (nr + 20000000) * 1000000
        elseif nr < 700101 then
            return nil, 'bad'
        elseif nr <= 991231 then
            nr = (nr + 19000000) * 1000000
        elseif nr <= 99991231 then
            nr = nr * 1000000
        elseif nr < 101000000 then
            return nil, 'bad'
        else
            isDate = false
            if nr <= 691231235959 then
                nr = nr + 20000000000000
            elseif nr < 700101000000 then
                return nil, 'bad'
            elseif nr <= 991231235959 then
                nr = nr + 19000000000000
            end
        end
        local p1, p2 = nr // 1000000, nr % 1000000
        return TimeOf(p1 // 10000, (p1 % 10000) // 100, p1 % 100, p2 // 10000, (p2 % 10000) // 100, p2 % 100, hasFrac,
            isDate, (isDate and hasFrac) and 'note' or nil)
    end

    -- A text as a date and time for comparisons and date functions: unix seconds, or nil when MariaDB would not
    -- read a date there (or reads one the engine cannot hold).
    ParseDT = function(s)
        local y, mo, d, h, mi, se = smatch(s, '^(%d%d%d%d)%-(%d%d)%-(%d%d) (%d%d):(%d%d):(%d%d)$')
        if not y then
            y, mo, d = smatch(s, '^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
            h, mi, se = '0', '0', '0'
        end
        if y then
            y, mo, d, h, mi, se = tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(se)
            if y >= 1000 and mo >= 1 and mo <= 12 and d >= 1 and d <= DaysIn(mo, y) and h <= 23 and mi <= 59
                and se <= 59 then
                return os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = se })
            end
        end
        return (StrTime(s))
    end
    M.strTime, M.numTime = StrTime, NumTime

    local MONTHS = {
        'January',
        'February',
        'March',
        'April',
        'May',
        'June',
        'July',
        'August',
        'September',
        'October',
        'November',
        'December',
    }
    local DAYS = { 'Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday' }
    DateFormat = function(t, fmt)
        local d = os.date('*t', t)
        return (
            sgsub(fmt, '%%(.)', function(c)
                if c == 'Y' then
                    return sformat('%04d', d.year)
                elseif c == 'y' then
                    return sformat('%02d', d.year % 100)
                elseif c == 'm' then
                    return sformat('%02d', d.month)
                elseif c == 'c' then
                    return tostring(d.month)
                elseif c == 'd' then
                    return sformat('%02d', d.day)
                elseif c == 'e' then
                    return tostring(d.day)
                elseif c == 'H' then
                    return sformat('%02d', d.hour)
                elseif c == 'k' then
                    return tostring(d.hour)
                elseif c == 'h' or c == 'I' then
                    return sformat('%02d', (d.hour + 11) % 12 + 1)
                elseif c == 'l' then
                    return tostring((d.hour + 11) % 12 + 1)
                elseif c == 'i' then
                    return sformat('%02d', d.min)
                elseif c == 's' or c == 'S' then
                    return sformat('%02d', d.sec)
                elseif c == 'p' then
                    return d.hour < 12 and 'AM' or 'PM'
                elseif c == 'T' then
                    return sformat('%02d:%02d:%02d', d.hour, d.min, d.sec)
                elseif c == 'r' then
                    return sformat('%02d:%02d:%02d %s', (d.hour + 11) % 12 + 1, d.min, d.sec,
                        d.hour < 12 and 'AM' or 'PM')
                elseif c == 'j' then
                    return sformat('%03d', d.yday)
                elseif c == 'M' then
                    return MONTHS[d.month]
                elseif c == 'b' then
                    return ssub(MONTHS[d.month], 1, 3)
                elseif c == 'W' then
                    return DAYS[d.wday]
                elseif c == 'a' then
                    return ssub(DAYS[d.wday], 1, 3)
                elseif c == 'w' then
                    return tostring(d.wday - 1)
                elseif c == 'f' then
                    return '000000'
                end
                return c
            end)
        )
    end
end

-- ============================================================================
--                              utf8mb4_general_ci
-- ============================================================================
-- Each character compares by one weight, MariaDB's own: the runs below were read from MariaDB 10.11 with
-- WEIGHT_STRING(... COLLATE utf8mb4_general_ci) and LOWER() over every code point of the Basic Multilingual Plane
-- (tools/gen_collation.py; tests/memsql_spec.lua checks every one against MariaDB again). A run
-- "first,count,stride,value,step" (hex) gives code point first + i*stride the value value + i*step; a code
-- point not listed weighs itself (and LOWER() keeps it). ASCII: a-z weigh as A-Z. Characters beyond U+FFFF all
-- weigh U+FFFD. Keys are the weights as UTF-8, so plain byte order is weight order; trailing spaces are ignored
-- (PAD SPACE: see ciOrderKey for ordering).
local CiFold, CiKey, CiOrderKey, BinOrderKey, LowerText
do
    local GENERAL_CI_RUNS = [[
b5,1,1,39c,0 c0,6,1,41,0 c7,1,1,43,0 c8,4,1,45,0 cc,4,1,49,0 d1,2,1,4e,1 d3,4,1,4f,0 d9,4,1,55,0
dd,1,1,59,0 df,1,1,53,0 e0,6,1,41,0 e6,1,1,c6,0 e7,1,1,43,0 e8,4,1,45,0 ec,4,1,49,0 f0,1,1,d0,0
f1,2,1,4e,1 f3,4,1,4f,0 f8,1,1,d8,0 f9,4,1,55,0 fd,1,1,59,0 fe,1,1,de,0 ff,1,1,59,0 100,6,1,41,0
106,8,1,43,0 10e,2,1,44,0 111,1,1,110,0 112,a,1,45,0 11c,8,1,47,0 124,2,1,48,0 127,1,1,126,0 128,a,1,49,0
133,1,1,132,0 134,2,1,4a,0 136,2,1,4b,0 139,6,1,4c,0 140,2,2,13f,2 143,6,1,4e,0 14b,1,1,14a,0 14c,6,1,4f,0
153,1,1,152,0 154,6,1,52,0 15a,8,1,53,0 162,4,1,54,0 167,1,1,166,0 168,c,1,55,0 174,2,1,57,0 176,3,1,59,0
179,6,1,5a,0 17f,1,1,53,0 183,2,2,182,2 188,1,1,187,0 18c,1,1,18b,0 192,1,1,191,0 195,1,1,1f6,0 199,1,1,198,0
1a0,2,1,4f,0 1a3,2,2,1a2,2 1a8,1,1,1a7,0 1ad,1,1,1ac,0 1af,2,1,55,0 1b4,2,2,1b3,2 1b9,1,1,1b8,0 1bd,1,1,1bc,0
1bf,1,1,1f7,0 1c5,2,1,1c4,0 1c8,2,1,1c7,0 1cb,2,1,1ca,0 1cd,2,1,41,0 1cf,2,1,49,0 1d1,2,1,4f,0 1d3,a,1,55,0
1dd,1,1,18e,0 1de,4,1,41,0 1e2,2,1,c6,0 1e5,1,1,1e4,0 1e6,2,1,47,0 1e8,2,1,4b,0 1ea,4,1,4f,0 1ee,2,1,1b7,0
1f0,1,1,4a,0 1f2,2,1,1f1,0 1f4,2,1,47,0 1f8,2,1,4e,0 1fa,2,1,41,0 1fc,2,1,c6,0 1fe,2,1,d8,0 200,4,1,41,0
204,4,1,45,0 208,4,1,49,0 20c,4,1,4f,0 210,4,1,52,0 214,4,1,55,0 218,2,1,53,0 21a,2,1,54,0 21d,1,1,21c,0
21e,2,1,48,0 223,2,2,222,2 226,2,1,41,0 228,2,1,45,0 22a,8,1,4f,0 232,2,1,59,0 253,1,1,181,0 254,1,1,186,0
256,2,1,189,1 259,2,2,18f,1 260,1,1,193,0 263,1,1,194,0 268,1,1,197,0 269,1,1,196,0 26f,1,1,19c,0 272,1,1,19d,0
275,1,1,19f,0 280,1,1,1a6,0 283,1,1,1a9,0 288,1,1,1ae,0 28a,2,1,1b1,1 292,1,1,1b7,0 345,1,1,399,0 386,1,1,391,0
388,1,1,395,0 389,1,1,397,0 38a,1,1,399,0 38c,1,1,39f,0 38e,1,1,3a5,0 38f,1,1,3a9,0 390,1,1,399,0 3aa,1,1,399,0
3ab,1,1,3a5,0 3ac,1,1,391,0 3ad,1,1,395,0 3ae,1,1,397,0 3af,1,1,399,0 3b0,1,1,3a5,0 3b1,11,1,391,1 3c2,2,1,3a3,0
3c4,6,1,3a4,1 3ca,1,1,399,0 3cb,1,1,3a5,0 3cc,1,1,39f,0 3cd,1,1,3a5,0 3ce,1,1,3a9,0 3d0,1,1,392,0 3d1,1,1,398,0
3d3,2,1,3d2,0 3d5,1,1,3a6,0 3d6,1,1,3a0,0 3db,b,2,3da,2 3f0,1,1,39a,0 3f1,1,1,3a1,0 3f2,1,1,3a3,0 400,2,1,415,0
403,1,1,413,0 407,1,1,406,0 40c,1,1,41a,0 40d,1,1,418,0 40e,1,1,423,0 430,20,1,410,1 450,2,1,415,0 452,1,1,402,0
453,1,1,413,0 454,3,1,404,1 457,1,1,406,0 458,4,1,408,1 45c,1,1,41a,0 45d,1,1,418,0 45e,1,1,423,0 45f,1,1,40f,0
461,b,2,460,2 476,2,1,474,0 479,5,2,478,2 48d,1a,2,48c,2 4c1,2,1,416,0 4c4,1,1,4c3,0 4c8,1,1,4c7,0 4cc,1,1,4cb,0
4d0,4,1,410,0 4d5,1,1,4d4,0 4d6,2,1,415,0 4d9,3,1,4d8,0 4dc,2,1,416,0 4de,2,1,417,0 4e1,1,1,4e0,0 4e2,4,1,418,0
4e6,2,1,41e,0 4e9,3,1,4e8,0 4ec,2,1,42d,0 4ee,6,1,423,0 4f4,2,1,427,0 4f8,2,1,42b,0 561,26,1,531,1 1e00,2,1,41,0
1e02,6,1,42,0 1e08,2,1,43,0 1e0a,a,1,44,0 1e14,a,1,45,0 1e1e,2,1,46,0 1e20,2,1,47,0 1e22,a,1,48,0 1e2c,4,1,49,0
1e30,6,1,4b,0 1e36,8,1,4c,0 1e3e,6,1,4d,0 1e44,8,1,4e,0 1e4c,8,1,4f,0 1e54,4,1,50,0 1e58,8,1,52,0 1e60,a,1,53,0
1e6a,8,1,54,0 1e72,a,1,55,0 1e7c,4,1,56,0 1e80,a,1,57,0 1e8a,4,1,58,0 1e8e,2,1,59,0 1e90,6,1,5a,0 1e96,1,1,48,0
1e97,1,1,54,0 1e98,1,1,57,0 1e99,1,1,59,0 1e9b,1,1,53,0 1ea0,18,1,41,0 1eb8,10,1,45,0 1ec8,4,1,49,0 1ecc,18,1,4f,0
1ee4,e,1,55,0 1ef2,8,1,59,0 1f00,10,1,391,0 1f10,6,1,395,0 1f18,6,1,395,0 1f20,10,1,397,0 1f30,10,1,399,0 1f40,6,1,39f,0
1f48,6,1,39f,0 1f50,8,1,3a5,0 1f59,4,2,3a5,0 1f60,10,1,3a9,0 1f70,1,1,391,0 1f71,1,1,1fbb,0 1f72,1,1,395,0 1f73,1,1,1fc9,0
1f74,1,1,397,0 1f75,1,1,1fcb,0 1f76,1,1,399,0 1f77,1,1,1fdb,0 1f78,1,1,39f,0 1f79,1,1,1ff9,0 1f7a,1,1,3a5,0 1f7b,1,1,1feb,0
1f7c,1,1,3a9,0 1f7d,1,1,1ffb,0 1f80,10,1,391,0 1f90,10,1,397,0 1fa0,10,1,3a9,0 1fb0,5,1,391,0 1fb6,5,1,391,0 1fbc,1,1,391,0
1fbe,1,1,399,0 1fc2,3,1,397,0 1fc6,2,1,397,0 1fc8,2,2,395,2 1fcc,1,1,397,0 1fd0,3,1,399,0 1fd6,5,1,399,0 1fe0,3,1,3a5,0
1fe4,2,1,3a1,0 1fe6,5,1,3a5,0 1fec,1,1,3a1,0 1ff2,3,1,3a9,0 1ff6,2,1,3a9,0 1ff8,1,1,39f,0 1ffa,2,2,3a9,0 2170,10,1,2160,1
24d0,1a,1,24b6,1 ff41,1a,1,ff21,1
]]
    local LOWER_RUNS = [[
c0,17,1,e0,1 d8,7,1,f8,1 100,18,2,101,2 130,1,1,69,0 132,3,2,133,2 139,8,2,13a,2 14a,17,2,14b,2 178,1,1,ff,0
179,3,2,17a,2 181,1,1,253,0 182,2,2,183,2 186,1,1,254,0 187,1,1,188,0 189,2,1,256,1 18b,1,1,18c,0 18e,1,1,1dd,0
18f,1,1,259,0 190,1,1,25b,0 191,1,1,192,0 193,1,1,260,0 194,1,1,263,0 196,1,1,269,0 197,1,1,268,0 198,1,1,199,0
19c,1,1,26f,0 19d,1,1,272,0 19f,1,1,275,0 1a0,3,2,1a1,2 1a6,1,1,280,0 1a7,1,1,1a8,0 1a9,1,1,283,0 1ac,1,1,1ad,0
1ae,1,1,288,0 1af,1,1,1b0,0 1b1,2,1,28a,1 1b3,2,2,1b4,2 1b7,1,1,292,0 1b8,1,1,1b9,0 1bc,1,1,1bd,0 1c4,2,1,1c6,0
1c7,2,1,1c9,0 1ca,2,1,1cc,0 1cd,8,2,1ce,2 1de,9,2,1df,2 1f1,2,1,1f3,0 1f4,1,1,1f5,0 1f6,1,1,195,0 1f7,1,1,1bf,0
1f8,14,2,1f9,2 222,9,2,223,2 386,2,2,3ac,1 389,2,1,3ae,1 38c,2,2,3cc,1 38f,1,1,3ce,0 391,11,1,3b1,1 3a3,9,1,3c3,1
3da,b,2,3db,2 400,10,1,450,1 410,20,1,430,1 460,11,2,461,2 48c,1a,2,48d,2 4c1,2,2,4c2,2 4c7,1,1,4c8,0 4cb,1,1,4cc,0
4d0,13,2,4d1,2 4f8,1,1,4f9,0 531,26,1,561,1 1e00,4b,2,1e01,2 1ea0,2d,2,1ea1,2 1f08,8,1,1f00,1 1f18,6,1,1f10,1 1f28,8,1,1f20,1
1f38,8,1,1f30,1 1f48,6,1,1f40,1 1f59,4,2,1f51,2 1f68,8,1,1f60,1 1f88,8,1,1f80,1 1f98,8,1,1f90,1 1fa8,8,1,1fa0,1 1fb8,2,1,1fb0,1
1fba,2,1,1f70,1 1fbc,1,1,1fb3,0 1fc8,4,1,1f72,1 1fcc,1,1,1fc3,0 1fd8,2,1,1fd0,1 1fda,2,1,1f76,1 1fe8,2,1,1fe0,1 1fea,2,1,1f7a,1
1fec,1,1,1fe5,0 1ff8,2,1,1f78,1 1ffa,2,1,1f7c,1 1ffc,1,1,1ff3,0 2126,1,1,3c9,0 212a,1,1,6b,0 212b,1,1,e5,0 2160,10,1,2170,1
24b6,1a,1,24d0,1 ff21,1a,1,ff41,1
]]
    local UPPER_ASCII = {}
    for c = 97, 122 do UPPER_ASCII[schar(c)] = schar(c - 32) end
    local LOWER_ASCII = {}
    for c = 65, 90 do LOWER_ASCII[schar(c)] = schar(c + 32) end
    local function RunTable(runs)
        local map = {}
        for first, count, stride, value, step in sgmatch(runs, '(%x+),(%x+),(%x+),(%x+),(%x+)') do
            first, count, stride = tonumber(first, 16), tonumber(count, 16), tonumber(stride, 16)
            value, step = tonumber(value, 16), tonumber(step, 16)
            for i = 0, count - 1 do map[utf8char(first + i * stride)] = utf8char(value + i * step) end
        end
        return map
    end
    local CI_MB = RunTable(GENERAL_CI_RUNS)
    local LOWER_MB = RunTable(LOWER_RUNS)

    CiFold = function(s)
        if sfind(s, '[\128-\255]') then
            s = sgsub(s, '[\240-\244][\128-\191][\128-\191][\128-\191]', '\239\191\189')
            s = sgsub(s, '[\194-\239][\128-\191]+', CI_MB)
        end
        if sfind(s, '[a-z]') then s = sgsub(s, '[a-z]', UPPER_ASCII) end
        return s
    end

    local CIK, cikN = {}, 0
    CiKey = function(s)
        local k = CIK[s]
        if k then return k end
        k = CiFold(s)
        if sbyte(k, -1) == 32 then k = smatch(k, '^(.-) +$') end
        cikN = cikN + 1
        if cikN > 50000 then CIK, cikN = {}, 0 end
        CIK[s] = k
        return k
    end
    M.ciKey = CiKey

    -- The key for ordering (ORDER BY, MIN / MAX, < and >): PAD SPACE compares as if the shorter text went on with
    -- spaces, so 'Bob' sorts after 'Bob<tab>Smith' (a tab is below a space). As byte order: every run of spaces is
    -- written as a space, then 1 when the character after it is below a space (the run length ascending), 3 when it
    -- is above (the run length descending), then that character; the end of the text is a space and 2 (it compares
    -- like endless spaces). Equal texts keep equal keys.
    local CIO, cioN = {}, 0
    local function SpaceRun(sp, c)
        local n = #sp
        if n > 65535 then n = 65535 end
        if sbyte(c) < 32 then return ' \1' .. spack('>I2', n) .. c end
        return ' \3' .. spack('>I2', 65535 - n) .. c
    end
    local function PadOrder(k)
        if sfind(k, ' ', 1, true) then k = sgsub(k, '( +)(.)', SpaceRun) end
        return k .. ' \2'
    end
    -- utf8mb4_bin (JSON function results) is PAD SPACE too: its ordering key
    BinOrderKey = function(v)
        if sbyte(v, -1) == 32 then v = smatch(v, '^(.-) +$') end
        return PadOrder(v)
    end
    CiOrderKey = function(s)
        local k = CIO[s]
        if k then return k end
        k = PadOrder(CiKey(s))
        cioN = cioN + 1
        if cioN > 50000 then CIO, cioN = {}, 0 end
        CIO[s] = k
        return k
    end
    M.ciOrderKey = CiOrderKey

    LowerText = function(s)
        s = sgsub(s, '[A-Z]', LOWER_ASCII)
        if sfind(s, '[\194-\239]') then s = sgsub(s, '[\194-\239][\128-\191]+', LOWER_MB) end
        return s
    end
    M.lowerText = LowerText
end

-- "\xC3" style dump of the first invalid bytes (MariaDB's Incorrect string value message).
local function BadBytes(s, at)
    local out = {}
    for i = at, mmin(#s, at + 3) do out[#out + 1] = sformat('\\x%02X', sbyte(s, i)) end
    return concat(out)
end

-- ============================================================================
--                                      ═
-- ============================================================================
-- 2. JSON (MariaDB's JSON functions work on text; this keeps member order and the text of every
--    string and number exactly, and prints the result like MariaDB: {"a": 1, "b": [1, 2]})

-- ============================================================================
--                                      ═
-- ============================================================================

local JTRUE, JFALSE, JNULL, Jskip, JstrEnd, Jvalue, Jparse, Jvalid, JvalidStrict, Jtext, JstrDecode, JstrEncode, JfindKey, Jlua, Jpath, Jwalk, Jcollect, Jcontains, JmemoGet, JmemoPut
do
    local JERR = setmetatable({}, {
        __tostring = function() return 'invalid JSON' end,
    })
    local function Jfail() error(JERR, 0) end
    JTRUE, JFALSE, JNULL = { t = 'true' }, { t = 'false' }, { t = 'null' }

    Jskip = function(s, i)
        local b = sbyte(s, i)
        if b == 32 or b == 9 or b == 10 or b == 13 then return sfind(s, '[^ \t\r\n]', i) or (#s + 1) end
        if b == nil and i > #s + 1 then return #s + 1 end
        return i
    end

    local JSTRICT = false -- true: plain RFC 8259 JSON only (what the saves folder embeds in its documents)
    JstrEnd = function(s, i)
        local j = i + 1
        while true do
            local k = sfind(s, '["\\\0-\31]', j)
            if not k then Jfail() end
            local c = sbyte(s, k)
            if c == 34 then return k end
            if c ~= 92 then Jfail() end
            -- MariaDB's json_lib: \uXXXX (a high surrogate only with its low one), or \ and any other printable character
            local e = sbyte(s, k + 1)
            if e == 117 then
                local h = smatch(s, '^%x%x%x%x', k + 2)
                if not h then Jfail() end
                local cp = tonumber(h, 16)
                if cp >= 0xD800 and cp <= 0xDBFF then
                    local lo = smatch(s, '^\\u(%x%x%x%x)', k + 6)
                    lo = lo and tonumber(lo, 16)
                    if not lo or lo < 0xDC00 or lo > 0xDFFF then Jfail() end
                    j = k + 12
                elseif cp >= 0xDC00 and cp <= 0xDFFF then
                    Jfail()
                else
                    j = k + 6
                end
            elseif e == nil or e < 32 then
                Jfail()
            elseif JSTRICT
                and not (e == 34 or e == 92 or e == 47 or e == 98 or e == 102 or e == 110 or e == 114 or e == 116) then
                Jfail()
            else
                j = k + 2
            end
        end
    end

    Jvalue = function(s, i)
        i = Jskip(s, i)
        local c = sbyte(s, i)
        if c == 123 then
            local keys, vals, n = {}, {}, 0
            i = Jskip(s, i + 1)
            if sbyte(s, i) == 125 then return { t = 'o', k = keys, v = vals, n = 0 }, i + 1 end
            while true do
                if sbyte(s, i) ~= 34 then Jfail() end
                local e = JstrEnd(s, i)
                n = n + 1
                keys[n] = ssub(s, i, e)
                i = Jskip(s, e + 1)
                if sbyte(s, i) ~= 58 then Jfail() end
                local v
                v, i = Jvalue(s, i + 1)
                vals[n] = v
                i = Jskip(s, i)
                c = sbyte(s, i)
                if c == 44 then
                    i = Jskip(s, i + 1)
                elseif c == 125 then
                    return { t = 'o', k = keys, v = vals, n = n }, i + 1
                else
                    Jfail()
                end
            end
        elseif c == 91 then
            local items, n = {}, 0
            i = Jskip(s, i + 1)
            if sbyte(s, i) == 93 then return { t = 'a', v = items, n = 0 }, i + 1 end
            while true do
                local v
                v, i = Jvalue(s, i)
                n = n + 1
                items[n] = v
                i = Jskip(s, i)
                c = sbyte(s, i)
                if c == 44 then
                    i = i + 1
                elseif c == 93 then
                    return { t = 'a', v = items, n = n }, i + 1
                else
                    Jfail()
                end
            end
        elseif c == 34 then
            local e = JstrEnd(s, i)
            return { t = 's', r = ssub(s, i, e) }, e + 1
        elseif c == 116 then
            if ssub(s, i, i + 3) == 'true' then return JTRUE, i + 4 end
        elseif c == 102 then
            if ssub(s, i, i + 4) == 'false' then return JFALSE, i + 5 end
        elseif c == 110 then
            if ssub(s, i, i + 3) == 'null' then return JNULL, i + 4 end
        elseif c == 45 or (c and c >= 48 and c <= 57) then
            local _, b = sfind(s, '^%-?%d+', i)
            if b then
                local lead = sbyte(s, i) == 45 and i + 1 or i
                if sbyte(s, lead) == 48 and b > lead then Jfail() end
                local _, b2 = sfind(s, JSTRICT and '^%.%d+' or '^%.%d*', b + 1) -- MariaDB also takes 5. and 5.e3
                if b2 then b = b2 end
                local _, b3 = sfind(s, '^[eE][-+]?%d+', b + 1)
                if b3 then b = b3 end
                return { t = 'n', r = ssub(s, i, b) }, b + 1
            end
        end
        Jfail()
    end

    -- Whole text -> node, or nil when it is not valid JSON.
    Jparse = function(s)
        if type(s) ~= 'string' then return nil end
        local ok, node, i = pcall(Jvalue, s, 1)
        if not ok then
            if node == JERR then return nil end
            return nil
        end
        if Jskip(s, i) <= #s then return nil end
        return node
    end
    M.jparse = Jparse

    -- Is s valid JSON? The same grammar as jvalue (and the same answer), without building nodes: every value is
    -- checked in place. Used where a text only has to be checked (storing into a JSON column, JSON_VALID, saving).
    local JcheckValue
    JcheckValue = function(s, i)
        i = Jskip(s, i)
        local c = sbyte(s, i)
        if c == 123 then
            i = Jskip(s, i + 1)
            if sbyte(s, i) == 125 then return i + 1 end
            while true do
                if sbyte(s, i) ~= 34 then Jfail() end
                i = Jskip(s, JstrEnd(s, i) + 1)
                if sbyte(s, i) ~= 58 then Jfail() end
                i = Jskip(s, JcheckValue(s, i + 1))
                c = sbyte(s, i)
                if c == 44 then
                    i = Jskip(s, i + 1)
                elseif c == 125 then
                    return i + 1
                else
                    Jfail()
                end
            end
        elseif c == 91 then
            i = Jskip(s, i + 1)
            if sbyte(s, i) == 93 then return i + 1 end
            while true do
                i = Jskip(s, JcheckValue(s, i))
                c = sbyte(s, i)
                if c == 44 then
                    i = i + 1
                elseif c == 93 then
                    return i + 1
                else
                    Jfail()
                end
            end
        elseif c == 34 then
            return JstrEnd(s, i) + 1
        elseif c == 116 then
            if ssub(s, i, i + 3) == 'true' then return i + 4 end
        elseif c == 102 then
            if ssub(s, i, i + 4) == 'false' then return i + 5 end
        elseif c == 110 then
            if ssub(s, i, i + 3) == 'null' then return i + 4 end
        elseif c == 45 or (c and c >= 48 and c <= 57) then
            local _, b = sfind(s, '^%-?%d+', i)
            if b then
                local lead = sbyte(s, i) == 45 and i + 1 or i
                if sbyte(s, lead) == 48 and b > lead then Jfail() end
                local _, b2 = sfind(s, JSTRICT and '^%.%d+' or '^%.%d*', b + 1) -- MariaDB also takes 5. and 5.e3
                if b2 then b = b2 end
                local _, b3 = sfind(s, '^[eE][-+]?%d+', b + 1)
                if b3 then b = b3 end
                return b + 1
            end
        end
        Jfail()
    end

    Jvalid = function(s)
        if type(s) ~= 'string' then return false end
        local ok, i = pcall(JcheckValue, s, 1)
        if not ok then return false end
        return Jskip(s, i) > #s
    end
    M.jvalid = Jvalid
    -- Is s JSON that any JSON reader takes (no 5. numbers, no \q escapes)?
    JvalidStrict = function(s)
        JSTRICT = true
        local ok = Jvalid(s)
        JSTRICT = false
        return ok
    end

    local function Jser(node, out, n, sep, colon)
        local t = node.t
        if t == 'o' then
            if node.n == 0 then n = n + 1; out[n] = '{}'; return n end
            n = n + 1
            out[n] = '{'
            local ks, vs = node.k, node.v
            for i = 1, node.n do
                if i > 1 then n = n + 1; out[n] = sep end
                n = n + 1
                out[n] = ks[i]
                n = n + 1
                out[n] = colon
                n = Jser(vs[i], out, n, sep, colon)
            end
            n = n + 1
            out[n] = '}'
            return n
        elseif t == 'a' then
            if node.n == 0 then n = n + 1; out[n] = '[]'; return n end
            n = n + 1
            out[n] = '['
            local vs = node.v
            for i = 1, node.n do
                if i > 1 then n = n + 1; out[n] = sep end
                n = Jser(vs[i], out, n, sep, colon)
            end
            n = n + 1
            out[n] = ']'
            return n
        elseif t == 's' or t == 'n' then
            n = n + 1
            out[n] = node.r
            return n
        end
        n = n + 1
        out[n] = t
        return n
    end

    -- MariaDB's formatting (JSON_SET, JSON_REMOVE, JSON_EXTRACT output).
    Jtext = function(node)
        local out = {}
        local n = Jser(node, out, 0, ', ', ': ')
        return concat(out, '', 1, n)
    end
    M.jtext = Jtext

    local function Jcompact(node)
        local out = {}
        local n = Jser(node, out, 0, ',', ':')
        return concat(out, '', 1, n)
    end
    M.jcompact = Jcompact

    do
        local JESC = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
        JstrDecode = function(raw)
            local body = ssub(raw, 2, -2)
            if not sfind(body, '\\', 1, true) then return body end
            local out, n, i = {}, 0, 1
            while true do
                local k = sfind(body, '\\', i, true)
                if not k then n = n + 1; out[n] = ssub(body, i); break end
                n = n + 1
                out[n] = ssub(body, i, k - 1)
                local e = ssub(body, k + 1, k + 1)
                if e == 'u' then
                    local cp = tonumber(ssub(body, k + 2, k + 5), 16) or 63
                    i = k + 6
                    if cp >= 0xD800 and cp <= 0xDBFF and ssub(body, i, i + 1) == '\\u' then
                        local lo = tonumber(ssub(body, i + 2, i + 5), 16)
                        if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                            i = i + 6
                        end
                    end
                    n = n + 1
                    out[n] = utf8char(cp)
                else
                    n = n + 1
                    out[n] = JESC[e] or e
                    i = k + 2
                end
            end
            return concat(out)
        end
        M.jstrDecode = JstrDecode
    end

    do
        local JENC = {
            ['"'] = '\\"',
            ['\\'] = '\\\\',
            ['\n'] = '\\n',
            ['\r'] = '\\r',
            ['\t'] = '\\t',
            ['\b'] = '\\b',
            ['\f'] = '\\f',
        }
        for c = 0, 31 do
            local ch = schar(c)
            if not JENC[ch] then JENC[ch] = sformat('\\u%04X', c) end
        end
        JstrEncode = function(s)
            if not sfind(s, '["\\\0-\31]') then return '"' .. s .. '"' end
            return '"' .. sgsub(s, '["\\\0-\31]', JENC) .. '"'
        end
        M.jstrEncode = JstrEncode
    end

    local function Jkey(raw)
        if sfind(raw, '\\', 1, true) then return JstrDecode(raw) end
        return ssub(raw, 2, -2)
    end

    JfindKey = function(node, key)
        local ks = node.k
        for i = 1, node.n do
            if Jkey(ks[i]) == key then return i end
        end
        return nil
    end

    -- Node -> plain Lua value (for our own metadata files).
    Jlua = function(node)
        local t = node.t
        if t == 'o' then
            local o = {}
            for i = 1, node.n do o[Jkey(node.k[i])] = Jlua(node.v[i]) end
            return o
        elseif t == 'a' then
            local a = {}
            for i = 1, node.n do a[i] = Jlua(node.v[i]) end
            return a
        elseif t == 's' then
            return JstrDecode(node.r)
        elseif t == 'n' then
            return mtointeger(tonumber(node.r)) or tonumber(node.r)
        elseif t == 'true' then
            return true
        elseif t == 'false' then
            return false
        end
        return nil
    end

    do
        local PATHC = {}
        Jpath = function(p)
            local c = PATHC[p]
            if c then return c end
            if type(p) ~= 'string' or sbyte(p, 1) ~= 36 then
                Fail(sformat('Invalid JSON path expression. The error is around character position 1.'))
            end
            local steps, i, len, wild = {}, 2, #p, false
            while i <= len do
                local ch = sbyte(p, i)
                if ch == 46 then
                    if sbyte(p, i + 1) == 34 then
                        local ok, e = pcall(JstrEnd, p, i + 1)
                        if not ok then
                            Fail('Invalid JSON path expression. The error is around character position ' .. i .. '.')
                        end
                        steps[#steps + 1] = { key = JstrDecode(ssub(p, i + 1, e)) }
                        i = e + 1
                    elseif sbyte(p, i + 1) == 42 then
                        Unsupported('the .* wildcard in JSON paths')
                    elseif sbyte(p, i + 1) == 36 then
                        Unsupported('JSON paths with $ inside')
                    else
                        local a, b = sfind(p, '^[%w_$]+', i + 1)
                        if not a then
                            Fail('Invalid JSON path expression. The error is around character position ' .. i .. '.')
                        end
                        steps[#steps + 1] = { key = ssub(p, a, b) }
                        i = b + 1
                    end
                elseif ch == 91 then
                    local a, b, inner = sfind(p, '^%[%s*([%d%*]+)%s*%]', i)
                    if not a then
                        Fail('Invalid JSON path expression. The error is around character position ' .. i .. '.')
                    end
                    if inner == '*' then
                        steps[#steps + 1] = { any = true }
                        wild = true
                    else
                        local n = tonumber(inner)
                        if not n then
                            Fail('Invalid JSON path expression. The error is around character position ' .. i .. '.')
                        end
                        steps[#steps + 1] = { idx = n }
                    end
                    i = b + 1
                elseif ch == 32 then
                    i = i + 1
                elseif ch == 42 and sbyte(p, i + 1) == 42 then
                    Unsupported('the ** wildcard in JSON paths')
                else
                    Fail('Invalid JSON path expression. The error is around character position ' .. i .. '.')
                end
            end
            c = { steps = steps, wild = wild, n = #steps }
            PATHC[p] = c
            return c
        end
    end

    -- One path step; [0] of a value that is no array is the value itself (MariaDB, like MySQL, wraps it in an array).
    local function Jstep(node, st)
        if st.key then
            if node.t ~= 'o' then return nil end
            local i = JfindKey(node, st.key)
            return i and node.v[i] or nil
        end
        if node.t ~= 'a' then return st.idx == 0 and node or nil end
        return node.v[st.idx + 1]
    end

    Jwalk = function(node, steps, from, to)
        for i = from, to do
            node = Jstep(node, steps[i])
            if not node then return nil end
        end
        return node
    end

    Jcollect = function(node, steps, i, out)
        if i > #steps then out[#out + 1] = node; return end
        local st = steps[i]
        if st.any then
            if node.t == 'a' then
                for j = 1, node.n do Jcollect(node.v[j], steps, i + 1, out) end
            end
            return
        end
        local nx = Jstep(node, st)
        if nx then Jcollect(nx, steps, i + 1, out) end
    end

    local function JscalarEq(a, b)
        if a.t ~= b.t then return false end
        if a.t == 'n' then return tonumber(a.r) == tonumber(b.r) end
        if a.t == 's' then return JstrDecode(a.r) == JstrDecode(b.r) end
        return true
    end

    Jcontains = function(a, b)
        if a.t == 'a' then
            if b.t == 'a' then
                for i = 1, b.n do
                    if not Jcontains(a, b.v[i]) then return false end
                end
                return true
            end
            for i = 1, a.n do
                if Jcontains(a.v[i], b) then return true end
            end
            return false
        elseif a.t == 'o' then
            if b.t ~= 'o' then return false end
            for i = 1, b.n do
                local j = JfindKey(a, Jkey(b.k[i]))
                if not j or not Jcontains(a.v[j], b.v[i]) then return false end
            end
            return true
        end
        if b.t == 'o' or b.t == 'a' then return false end
        return JscalarEq(a, b)
    end

    -- Results of the read-only JSON functions for a (path, document) pair: the same breakdown text is read
    -- again and again (badges, goals), so its answers are kept (bounded; the text itself is the key).
    local JMEMO, jmemoN = {}, 0
    JmemoGet = function(fnKey, path, text)
        local byPath = JMEMO[fnKey .. path]
        if not byPath then return nil end
        return byPath[text]
    end
    JmemoPut = function(fnKey, path, text, value)
        local key = fnKey .. path
        local byPath = JMEMO[key]
        if not byPath then byPath = {}; JMEMO[key] = byPath end
        jmemoN = jmemoN + 1
        if jmemoN > 20000 then
            JMEMO, jmemoN = {}, 1
            byPath = {}
            JMEMO[key] = byPath
        end
        byPath[text] = value
    end
end

-- ============================================================================
--                           3. TOKENIZER AND PARSER
-- ============================================================================

local AGG = { COUNT = true, SUM = true, MAX = true, MIN = true, GROUP_CONCAT = true, AVG = true }
local Parse
do
    local function SyntaxError(sql, p)
        local near = ssub(sql, p or 1, (p or 1) + 60)
        Fail(sformat(
            'You have an error in your SQL syntax; check the manual that corresponds to your MariaDB server version for the right syntax to use near \'%s\' at line 1',
            near))
    end

    local STR_ESC = { n = '\n', t = '\t', r = '\r', b = '\b', ['0'] = '\0', Z = '\26', ['%'] = '\\%', _ = '\\_' }

    local function Tokenize(sql)
        local toks, n, i, len, np = {}, 0, 1, #sql, 0
        while true do
            i = sfind(sql, '[^ \t\r\n\f\v]', i)
            if not i then break end
            local c = sbyte(sql, i)
            if c == 45 and sbyte(sql, i + 1) == 45 then
                local e = sfind(sql, '\n', i, true)
                if not e then break end
                i = e + 1
            elseif c == 35 then
                local e = sfind(sql, '\n', i, true)
                if not e then break end
                i = e + 1
            elseif c == 47 and sbyte(sql, i + 1) == 42 then
                local _, e = sfind(sql, '*/', i + 2, true)
                if not e then SyntaxError(sql, i) end
                i = e + 1
            elseif c == 39 or c == 34 then
                local q, qs = c, schar(c)
                local pat = c == 39 and '[\'\\]' or '["\\]'
                local j, buf, bn = i + 1, {}, 0
                while true do
                    local k = sfind(sql, pat, j)
                    if not k then SyntaxError(sql, i) end
                    bn = bn + 1
                    buf[bn] = ssub(sql, j, k - 1)
                    if sbyte(sql, k) == 92 then
                        local e = ssub(sql, k + 1, k + 1)
                        bn = bn + 1
                        buf[bn] = STR_ESC[e] or e
                        j = k + 2
                    elseif sbyte(sql, k + 1) == q then
                        bn = bn + 1
                        buf[bn] = qs
                        j = k + 2
                    else
                        j = k + 1
                        break
                    end
                end
                n = n + 1
                toks[n] = { t = 'str', v = concat(buf, '', 1, bn), p = i }
                i = j
            elseif c == 63 then
                np = np + 1
                n = n + 1
                toks[n] = { t = 'param', v = np, p = i }
                i = i + 1
            elseif (c >= 48 and c <= 57) or (c == 46 and sfind(sql, '^%.%d', i)) then
                local _, b = sfind(sql, '^%d*%.?%d*', i)
                local _, e2 = sfind(sql, '^[eE][-+]?%d+', b + 1)
                if e2 then b = e2 end
                if sfind(sql, '^[%a_]', b + 1) then SyntaxError(sql, i) end
                n = n + 1
                toks[n] = { t = 'num', v = ssub(sql, i, b), p = i }
                i = b + 1
            elseif c == 96 then
                local e = sfind(sql, '`', i + 1, true)
                if not e then SyntaxError(sql, i) end
                local w = ssub(sql, i + 1, e - 1)
                n = n + 1
                toks[n] = { t = 'id', v = w, u = supper(w), l = slower(w), quoted = true, p = i }
                i = e + 1
            elseif (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95 or c >= 128 then
                local _, b = sfind(sql, '^[%w_$\128-\255]+', i)
                local w = ssub(sql, i, b)
                n = n + 1
                toks[n] = { t = 'id', v = w, u = supper(w), l = slower(w), p = i }
                i = b + 1
            else
                local two = ssub(sql, i, i + 1)
                if ssub(sql, i, i + 2) == '<=>' then
                    Unsupported('the <=> operator')
                elseif two == '<>' or two == '!=' or two == '<=' or two == '>=' then
                    n = n + 1
                    toks[n] = { t = 'op', v = two == '!=' and '<>' or two, p = i }
                    i = i + 2
                elseif two == '||' or two == '&&' then
                    Unsupported('the ' .. two .. ' operator')
                else
                    local ch = schar(c)
                    if sfind('=<>+-*/%(),.;', ch, 1, true) then
                        n = n + 1
                        toks[n] = { t = 'op', v = ch, p = i }
                        i = i + 1
                    else
                        SyntaxError(sql, i)
                    end
                end
            end
        end
        n = n + 1
        toks[n] = { t = 'eof', p = len + 1 }
        return toks, np
    end

    local RESERVED = {}
    for w in
        ([[SELECT FROM WHERE GROUP ORDER BY LIMIT OFFSET JOIN LEFT RIGHT INNER OUTER CROSS NATURAL ON USING UNION
    ALL AND OR NOT AS SET VALUES VALUE INTO HAVING WHEN THEN ELSE END IS NULL IN LIKE BETWEEN CASE DUPLICATE KEY
    UPDATE ASC DESC SEPARATOR FOR INTERVAL EXISTS DISTINCT IGNORE STRAIGHT_JOIN WITH WINDOW DIV MOD XOR REGEXP
    RLIKE ESCAPE DUAL LOCK]]):gmatch('%S+')
    do
        RESERVED[w] = true
    end

    Parse = function(sql)
        local toks, np = Tokenize(sql)
        local pos = 1
        local tables, tlist = {}, {}

        local function tok() return toks[pos] end
        local function err(t) SyntaxError(sql, (t or toks[pos]).p) end
        local function isKw(t, k) return t.t == 'id' and not t.quoted and t.u == k end
        local function kw(k)
            local t = toks[pos]
            if t.t == 'id' and not t.quoted and t.u == k then pos = pos + 1; return true end
            return false
        end
        local function needKw(k) if not kw(k) then err() end end
        local function op(o)
            local t = toks[pos]
            if t.t == 'op' and t.v == o then pos = pos + 1; return true end
            return false
        end
        local function needOp(o) if not op(o) then err() end end
        local function ident()
            local t = toks[pos]
            if t.t ~= 'id' then err(t) end
            pos = pos + 1
            return t
        end
        local function tableName()
            local t = ident()
            if toks[pos].t == 'op' and toks[pos].v == '.' then Unsupported('database-qualified table names') end
            local name = t.v
            if not tables[name] then tables[name] = true; tlist[#tlist + 1] = name end
            return name
        end
        local function aliasOpt()
            if kw('AS') then return ident().v end
            local t = toks[pos]
            if t.t == 'id' and (t.quoted or not RESERVED[t.u]) then pos = pos + 1; return t.v end
            return nil
        end

        local parseExpr, parseSelectStmt

        local function parseCall(nameTok)
            local name = nameTok.u
            pos = pos + 1 -- '('
            local node = { k = 'fn', name = name, args = {}, p = nameTok.p }
            if name == 'VALUES' then
                local c = ident()
                needOp(')')
                return { k = 'values', name = c.l, text = c.v }
            end
            if name == 'TIMESTAMPDIFF' then
                node.unit = ident().u
                needOp(',')
                node.args[1] = parseExpr()
                needOp(',')
                node.args[2] = parseExpr()
                needOp(')')
                return node
            end
            if AGG[name] then
                if kw('DISTINCT') then Unsupported(name .. '(DISTINCT ...)') end
                if name == 'COUNT' and op('*') then
                    node.star = true
                    needOp(')')
                    return node
                end
            end
            if not op(')') then
                repeat
                    node.args[#node.args + 1] = parseExpr()
                until not op(',')
                if name == 'GROUP_CONCAT' then
                    if kw('ORDER') then
                        needKw('BY')
                        node.order = {}
                        repeat
                            local e = parseExpr()
                            local desc = false
                            if kw('DESC') then desc = true else kw('ASC') end
                            node.order[#node.order + 1] = { e = e, desc = desc }
                        until not op(',')
                    end
                    if kw('SEPARATOR') then
                        local t = tok()
                        if t.t ~= 'str' then err(t) end
                        pos = pos + 1
                        node.sep = t.v
                    end
                end
                needOp(')')
            end
            return node
        end

        local function parseCase()
            local node = { k = 'case', whens = {} }
            if not isKw(tok(), 'WHEN') then node.base = parseExpr() end
            while kw('WHEN') do
                local c = parseExpr()
                needKw('THEN')
                node.whens[#node.whens + 1] = { c = c, v = parseExpr() }
            end
            if #node.whens == 0 then err() end
            if kw('ELSE') then node.els = parseExpr() end
            needKw('END')
            return node
        end

        local function parsePrimary()
            local t = toks[pos]
            local tt = t.t
            if tt == 'num' then
                pos = pos + 1
                return { k = 'num', text = t.v }
            elseif tt == 'str' then
                pos = pos + 1
                return { k = 'str', v = t.v }
            elseif tt == 'param' then
                pos = pos + 1
                return { k = 'param', i = t.v }
            elseif tt == 'op' then
                if t.v == '(' then
                    pos = pos + 1
                    if isKw(tok(), 'SELECT') then
                        local sub = parseSelectStmt()
                        needOp(')')
                        return { k = 'subq', sub = sub }
                    end
                    local e = parseExpr()
                    if op(',') then Unsupported('row constructors') end
                    needOp(')')
                    return e
                end
                err(t)
            elseif tt == 'id' then
                local u = t.u
                local nx = toks[pos + 1]
                if not t.quoted then
                    if u == 'NULL' then pos = pos + 1; return { k = 'null' } end
                    if u == 'TRUE' then pos = pos + 1; return { k = 'num', text = '1', bool = true } end
                    if u == 'FALSE' then pos = pos + 1; return { k = 'num', text = '0', bool = true } end
                    if u == 'CASE' then pos = pos + 1; return parseCase() end
                    if u == 'EXISTS' then
                        pos = pos + 1
                        needOp('(')
                        local sub = parseSelectStmt()
                        needOp(')')
                        return { k = 'exists', sub = sub }
                    end
                    if u == 'INTERVAL' then Unsupported('INTERVAL outside "date + INTERVAL n unit"') end
                    if (u == 'CURRENT_TIMESTAMP' or u == 'LOCALTIMESTAMP') and not (nx.t == 'op' and nx.v == '(') then
                        pos = pos + 1
                        return { k = 'fn', name = 'NOW', args = {} }
                    end
                    if u == 'BINARY' or u == 'COLLATE' then Unsupported(u) end
                end
                if nx.t == 'op' and nx.v == '(' and not t.quoted then
                    pos = pos + 1
                    return parseCall(t)
                end
                pos = pos + 1
                if toks[pos].t == 'op' and toks[pos].v == '.' then
                    pos = pos + 1
                    local c = toks[pos]
                    if c.t == 'op' and c.v == '*' then Unsupported('alias.* outside the select list') end
                    c = ident()
                    return { k = 'col', q = t.v, name = c.l, text = c.v }
                end
                return { k = 'col', name = t.l, text = t.v }
            end
            err(t)
        end

        local function parseUnary()
            if op('-') then
                local t = toks[pos]
                if t.t == 'num' then
                    pos = pos + 1
                    return { k = 'num', text = '-' .. t.v }
                end
                return { k = 'neg', e = parseUnary() }
            end
            if op('+') then return parseUnary() end
            return parsePrimary()
        end

        local function parseMul()
            local a = parseUnary()
            while true do
                local t = toks[pos]
                if t.t == 'op' and (t.v == '*' or t.v == '/' or t.v == '%') then
                    pos = pos + 1
                    a = { k = 'arith', op = t.v, a = a, b = parseUnary() }
                elseif isKw(t, 'DIV') or isKw(t, 'MOD') then
                    Unsupported(t.u)
                else
                    return a
                end
            end
        end

        local function parseAdd()
            local a = parseMul()
            while true do
                local t = toks[pos]
                if t.t == 'op' and (t.v == '+' or t.v == '-') then
                    pos = pos + 1
                    if kw('INTERVAL') then
                        local n = parseMul()
                        local unit = ident().u
                        a = { k = 'interval', base = a, n = n, unit = unit, sign = t.v == '+' and 1 or -1 }
                    else
                        a = { k = 'arith', op = t.v, a = a, b = parseMul() }
                    end
                else
                    return a
                end
            end
        end

        local CMP = { ['='] = true, ['<>'] = true, ['<'] = true, ['<='] = true, ['>'] = true, ['>='] = true }
        local function parsePredicate()
            local a = parseAdd()
            while true do
                local t = toks[pos]
                if t.t == 'op' and CMP[t.v] then
                    pos = pos + 1
                    if isKw(tok(), 'ANY') or isKw(tok(), 'ALL') or isKw(tok(), 'SOME') then
                        Unsupported('ANY/ALL comparisons')
                    end
                    a = { k = 'cmp', op = t.v, a = a, b = parseAdd() }
                elseif isKw(t, 'IS') then
                    pos = pos + 1
                    local neg = kw('NOT')
                    if kw('NULL') then
                        a = { k = 'isnull', e = a, neg = neg }
                    else
                        Unsupported('IS TRUE / IS FALSE / IS UNKNOWN')
                    end
                else
                    local neg = false
                    local save = pos
                    if isKw(t, 'NOT') then
                        local n2 = toks[pos + 1]
                        if isKw(n2, 'IN') or isKw(n2, 'LIKE') or isKw(n2, 'BETWEEN') or isKw(n2, 'REGEXP') then
                            pos = pos + 1
                            neg = true
                            t = toks[pos]
                        else
                            return a
                        end
                    end
                    if isKw(t, 'IN') then
                        pos = pos + 1
                        needOp('(')
                        if isKw(tok(), 'SELECT') then
                            local sub = parseSelectStmt()
                            needOp(')')
                            a = { k = 'insub', e = a, sub = sub, neg = neg }
                        else
                            local list = {}
                            repeat
                                list[#list + 1] = parseExpr()
                            until not op(',')
                            needOp(')')
                            a = { k = 'inlist', e = a, list = list, neg = neg }
                        end
                    elseif isKw(t, 'LIKE') then
                        pos = pos + 1
                        local b = parseAdd()
                        if isKw(tok(), 'ESCAPE') then Unsupported('LIKE ... ESCAPE') end
                        a = { k = 'like', a = a, b = b, neg = neg }
                    elseif isKw(t, 'BETWEEN') then
                        Unsupported('BETWEEN')
                    elseif isKw(t, 'REGEXP') or isKw(t, 'RLIKE') then
                        Unsupported('REGEXP')
                    else
                        pos = save
                        return a
                    end
                end
            end
        end

        local function parseNot()
            if kw('NOT') then return { k = 'not', e = parseNot() } end
            return parsePredicate()
        end

        local function parseAnd()
            local a = parseNot()
            if not isKw(tok(), 'AND') then return a end
            local list = { a }
            while kw('AND') do list[#list + 1] = parseNot() end
            return { k = 'and', list = list }
        end

        parseExpr = function()
            local a = parseAnd()
            if isKw(tok(), 'XOR') then Unsupported('XOR') end
            if not isKw(tok(), 'OR') then return a end
            local list = { a }
            while kw('OR') do list[#list + 1] = parseAnd() end
            return { k = 'or', list = list }
        end

        local function parseSource()
            if op('(') then
                if not isKw(tok(), 'SELECT') then Unsupported('parenthesised joins') end
                local sub = parseSelectStmt()
                needOp(')')
                local alias = aliasOpt()
                if not alias then Fail('Every derived table must have its own alias') end
                return { k = 'derived', sub = sub, alias = alias }
            end
            local name = tableName()
            return { k = 'table', name = name, alias = aliasOpt() }
        end

        local function parseFrom()
            local list = { { src = parseSource() } }
            while true do
                local kind
                if op(',') then Unsupported('comma joins') end
                if kw('LEFT') then
                    kw('OUTER')
                    needKw('JOIN')
                    kind = 'left'
                elseif kw('INNER') then
                    needKw('JOIN')
                    kind = 'inner'
                elseif kw('JOIN') then
                    kind = 'inner'
                elseif isKw(tok(), 'RIGHT') or isKw(tok(), 'CROSS') or isKw(tok(), 'NATURAL')
                    or isKw(tok(), 'STRAIGHT_JOIN') or isKw(tok(), 'FULL') then
                    Unsupported(tok().u .. ' JOIN')
                else
                    return list
                end
                local src = parseSource()
                if isKw(tok(), 'USING') then Unsupported('JOIN ... USING') end
                needKw('ON')
                list[#list + 1] = { src = src, kind = kind, on = parseExpr() }
            end
        end

        local function parseLimitValue()
            local t = tok()
            if t.t == 'num' and smatch(t.v, '^%d+$') then pos = pos + 1; return { k = 'num', text = t.v } end
            if t.t == 'param' then pos = pos + 1; return { k = 'param', i = t.v } end
            err(t)
        end

        local function parseSelectCore()
            local s0 = pos
            needKw('SELECT')
            local node = { k = 'select', items = {} }
            if kw('DISTINCT') then node.distinct = true else kw('ALL') end
            if isKw(tok(), 'SQL_CALC_FOUND_ROWS') or isKw(tok(), 'HIGH_PRIORITY') then Unsupported(tok().u) end
            repeat
                local t = tok()
                if t.t == 'op' and t.v == '*' then
                    pos = pos + 1
                    node.items[#node.items + 1] = { star = true }
                elseif t.t == 'id' and toks[pos + 1].t == 'op' and toks[pos + 1].v == '.' and toks[pos + 2].t == 'op'
                    and toks[pos + 2].v == '*' then
                    pos = pos + 3
                    node.items[#node.items + 1] = { star = true, q = t.v }
                else
                    local p1 = tok().p
                    local e = parseExpr()
                    local p2 = tok().p
                    local item = { e = e, text = (sgsub(ssub(sql, p1, p2 - 1), '%s+$', '')) }
                    if kw('AS') then
                        local a = tok()
                        if a.t == 'id' or a.t == 'str' then pos = pos + 1; item.alias = a.v else err(a) end
                    else
                        local a = tok()
                        if a.t == 'id' and (a.quoted or not RESERVED[a.u]) then pos = pos + 1; item.alias = a.v end
                    end
                    node.items[#node.items + 1] = item
                end
            until not op(',')
            if kw('FROM') then
                if kw('DUAL') then node.from = nil else node.from = parseFrom() end
            end
            if kw('WHERE') then node.where = parseExpr() end
            if kw('GROUP') then
                needKw('BY')
                node.group = {}
                repeat
                    node.group[#node.group + 1] = parseExpr()
                    if kw('DESC') or kw('ASC') then Unsupported('GROUP BY ... ASC/DESC') end
                until not op(',')
                if kw('WITH') then Unsupported('WITH ROLLUP') end
            end
            if isKw(tok(), 'HAVING') then Unsupported('HAVING') end
            if isKw(tok(), 'WINDOW') then Unsupported('window functions') end
            if kw('ORDER') then
                needKw('BY')
                node.order = {}
                repeat
                    local e = parseExpr()
                    local desc = false
                    if kw('DESC') then desc = true else kw('ASC') end
                    node.order[#node.order + 1] = { e = e, desc = desc }
                until not op(',')
            end
            if kw('LIMIT') then
                local a = parseLimitValue()
                if op(',') then
                    node.offset = a
                    node.limit = parseLimitValue()
                else
                    node.limit = a
                    if kw('OFFSET') then node.offset = parseLimitValue() end
                end
            end
            if isKw(tok(), 'FOR') or isKw(tok(), 'LOCK') then Unsupported('locking reads') end
            if isKw(tok(), 'INTO') then Unsupported('SELECT ... INTO') end
            node.p = toks[s0].p
            return node
        end

        parseSelectStmt = function()
            if isKw(tok(), 'WITH') then Unsupported('WITH (common table expressions)') end
            local first = parseSelectCore()
            if not isKw(tok(), 'UNION') then return first end
            local parts = { first }
            while kw('UNION') do
                if not kw('ALL') then Unsupported('UNION without ALL') end
                parts[#parts + 1] = parseSelectCore()
            end
            for _, p in ipairs(parts) do
                if p.order or p.limit then Unsupported('ORDER BY / LIMIT on a UNION') end
            end
            return { k = 'union', parts = parts }
        end

        local function parseColumnDef()
            local nameTok = ident()
            local cd = { name = nameTok.v }
            local tt = ident()
            local ty = tt.u
            if ty == 'INTEGER' then ty = 'INT' end
            cd.type = ty
            if ty == 'INT' or ty == 'TINYINT' or ty == 'SMALLINT' or ty == 'MEDIUMINT' or ty == 'BIGINT' then
                if op('(') then
                    local w = tok()
                    if w.t ~= 'num' then err(w) end
                    pos = pos + 1
                    cd.width = tonumber(w.v)
                    needOp(')')
                end
                if kw('UNSIGNED') then cd.unsigned = true end
                if kw('ZEROFILL') then Unsupported('ZEROFILL') end
            elseif ty == 'VARCHAR' or ty == 'CHAR' then
                if ty == 'CHAR' then Unsupported('CHAR columns') end
                needOp('(')
                local w = tok()
                if w.t ~= 'num' then err(w) end
                pos = pos + 1
                cd.len = tonumber(w.v)
                needOp(')')
            elseif ty == 'DECIMAL' or ty == 'NUMERIC' then
                cd.type = 'DECIMAL'
                cd.prec, cd.scale = 10, 0
                if op('(') then
                    local w = tok()
                    if w.t ~= 'num' then err(w) end
                    pos = pos + 1
                    cd.prec = tonumber(w.v)
                    if op(',') then
                        local s = tok()
                        if s.t ~= 'num' then err(s) end
                        pos = pos + 1
                        cd.scale = tonumber(s.v)
                    end
                    needOp(')')
                end
                if cd.prec > 18 or cd.scale > cd.prec then Unsupported('DECIMAL wider than 18 digits') end
            elseif ty == 'ENUM' then
                needOp('(')
                cd.members = {}
                repeat
                    local s = tok()
                    if s.t ~= 'str' then err(s) end
                    pos = pos + 1
                    cd.members[#cd.members + 1] = s.v
                until not op(',')
                needOp(')')
            elseif ty == 'DATETIME' or ty == 'DATE' or ty == 'JSON' then
                if op('(') then Unsupported('fractional seconds') end
            else
                Unsupported('the column type ' .. tt.v)
            end
            while true do
                if kw('NOT') then
                    needKw('NULL')
                    cd.notnull = true
                elseif kw('NULL') then
                    cd.notnull = false
                elseif kw('DEFAULT') then
                    local t = tok()
                    if t.t == 'num' then
                        pos = pos + 1
                        cd.default = { k = 'num', text = t.v }
                    elseif t.t == 'op' and t.v == '-' and toks[pos + 1].t == 'num' then
                        pos = pos + 2
                        cd.default = { k = 'num', text = '-' .. toks[pos - 1].v }
                    elseif t.t == 'str' then
                        pos = pos + 1
                        cd.default = { k = 'str', v = t.v }
                    elseif isKw(t, 'NULL') then
                        pos = pos + 1
                        cd.default = { k = 'null' }
                    elseif isKw(t, 'CURRENT_TIMESTAMP') or isKw(t, 'NOW') then
                        pos = pos + 1
                        if op('(') then needOp(')') end
                        cd.default = { k = 'now' }
                    else
                        Unsupported('this DEFAULT value')
                    end
                elseif kw('ON') then
                    needKw('UPDATE')
                    if not (kw('CURRENT_TIMESTAMP') or kw('NOW')) then err() end
                    if op('(') then needOp(')') end
                    cd.onupdate = true
                elseif kw('AUTO_INCREMENT') then
                    cd.autoinc = true
                elseif kw('PRIMARY') then
                    needKw('KEY')
                    cd.pk = true
                elseif kw('UNIQUE') then
                    if not kw('KEY') then kw('INDEX') end
                    cd.unique = true
                elseif kw('KEY') then
                    cd.pk = true
                elseif kw('COMMENT') then
                    local s = tok()
                    if s.t ~= 'str' then err(s) end
                    pos = pos + 1
                elseif isKw(tok(), 'COLLATE') or isKw(tok(), 'CHARACTER') or isKw(tok(), 'CHARSET') then
                    Unsupported('column collations and character sets')
                elseif isKw(tok(), 'CHECK') or isKw(tok(), 'REFERENCES') or isKw(tok(), 'GENERATED')
                    or isKw(tok(), 'AS') then
                    Unsupported(tok().u .. ' in column definitions')
                else
                    break
                end
            end
            return cd
        end

        local function parseKeyCols()
            needOp('(')
            local cols = {}
            repeat
                cols[#cols + 1] = ident().v
                if op('(') then Unsupported('prefix indexes') end
                if kw('ASC') or kw('DESC') then end
            until not op(',')
            needOp(')')
            return cols
        end

        local function ifNotExists()
            if not kw('IF') then return false end
            needKw('NOT')
            needKw('EXISTS')
            return true
        end

        local function parseCreate()
            needKw('TABLE')
            local node = { k = 'create' }
            if kw('IF') then
                needKw('NOT')
                needKw('EXISTS')
                node.ifnot = true
            end
            node.table = tableName()
            if kw('LIKE') then
                node.like = tableName()
                return node
            end
            needOp('(')
            if kw('LIKE') then
                node.like = tableName()
                needOp(')')
                return node
            end
            node.cols, node.keys = {}, {}
            repeat
                local t = tok()
                if isKw(t, 'PRIMARY') then
                    pos = pos + 1
                    needKw('KEY')
                    node.keys[#node.keys + 1] = { kind = 'pk', cols = parseKeyCols() }
                elseif isKw(t, 'UNIQUE') then
                    pos = pos + 1
                    if not kw('KEY') then kw('INDEX') end
                    local name
                    if tok().t == 'id' then name = ident().v end
                    node.keys[#node.keys + 1] = { kind = 'unique', name = name, cols = parseKeyCols() }
                elseif isKw(t, 'KEY') or isKw(t, 'INDEX') then
                    pos = pos + 1
                    local name
                    if tok().t == 'id' then name = ident().v end
                    node.keys[#node.keys + 1] = { kind = 'index', name = name, cols = parseKeyCols() }
                elseif isKw(t, 'CONSTRAINT') or isKw(t, 'FOREIGN') or isKw(t, 'CHECK') or isKw(t, 'FULLTEXT')
                    or isKw(t, 'SPATIAL') then
                    Unsupported(t.u .. ' in CREATE TABLE')
                else
                    node.cols[#node.cols + 1] = parseColumnDef()
                end
            until not op(',')
            needOp(')')
            if tok().t ~= 'eof' and not (tok().t == 'op' and tok().v == ';') then
                Unsupported('table options in CREATE TABLE')
            end
            return node
        end

        local function parseStatement()
            local t = tok()
            if isKw(t, 'SELECT') or isKw(t, 'WITH') then
                local s = parseSelectStmt()
                s.stmt = 'select'
                return s
            end
            if isKw(t, 'INSERT') then
                pos = pos + 1
                local node = { k = 'insert', stmt = 'insert' }
                if kw('IGNORE') then node.ignore = true end
                if isKw(tok(), 'LOW_PRIORITY') or isKw(tok(), 'DELAYED') or isKw(tok(), 'HIGH_PRIORITY') then
                    Unsupported(tok().u)
                end
                kw('INTO')
                node.table = tableName()
                if op('(') then
                    if isKw(tok(), 'SELECT') then Unsupported('INSERT INTO t (SELECT ...)') end
                    node.cols = {}
                    repeat
                        node.cols[#node.cols + 1] = ident()
                    until not op(',')
                    needOp(')')
                end
                if kw('VALUES') or kw('VALUE') then
                    node.values = {}
                    repeat
                        needOp('(')
                        local row = {}
                        if not op(')') then
                            repeat
                                row[#row + 1] = parseExpr()
                            until not op(',')
                            needOp(')')
                        end
                        node.values[#node.values + 1] = row
                    until not op(',')
                elseif isKw(tok(), 'SELECT') then
                    node.select = parseSelectStmt()
                elseif isKw(tok(), 'SET') then
                    Unsupported('INSERT ... SET')
                else
                    err()
                end
                if kw('ON') then
                    needKw('DUPLICATE')
                    needKw('KEY')
                    needKw('UPDATE')
                    node.odku = {}
                    repeat
                        local c = ident()
                        local q
                        if op('.') then q = c.v; c = ident() end
                        needOp('=')
                        node.odku[#node.odku + 1] = { q = q, name = c.l, text = c.v, e = parseExpr() }
                    until not op(',')
                end
                if isKw(tok(), 'RETURNING') then Unsupported('RETURNING') end
                return node
            end
            if isKw(t, 'UPDATE') then
                pos = pos + 1
                local node = { k = 'update', stmt = 'update' }
                if kw('IGNORE') then node.ignore = true end
                if isKw(tok(), 'LOW_PRIORITY') then Unsupported('LOW_PRIORITY') end
                node.table = tableName()
                node.alias = aliasOpt()
                if isKw(tok(), 'JOIN') or isKw(tok(), 'INNER') or isKw(tok(), 'LEFT')
                    or (tok().t == 'op' and tok().v == ',') then
                    Unsupported('multi-table UPDATE')
                end
                needKw('SET')
                node.sets = {}
                repeat
                    local c = ident()
                    local q
                    if op('.') then q = c.v; c = ident() end
                    needOp('=')
                    node.sets[#node.sets + 1] = { q = q, name = c.l, text = c.v, e = parseExpr() }
                until not op(',')
                if kw('WHERE') then node.where = parseExpr() end
                if isKw(tok(), 'ORDER') or isKw(tok(), 'LIMIT') then Unsupported('UPDATE ... ORDER BY / LIMIT') end
                return node
            end
            if isKw(t, 'DELETE') then
                pos = pos + 1
                local node = { k = 'delete', stmt = 'delete' }
                if isKw(tok(), 'IGNORE') or isKw(tok(), 'QUICK') or isKw(tok(), 'LOW_PRIORITY') then
                    Unsupported('DELETE ' .. tok().u)
                end
                if kw('FROM') then
                    node.table = tableName()
                    node.alias = aliasOpt()
                    if isKw(tok(), 'USING') or isKw(tok(), 'JOIN') or isKw(tok(), 'INNER') or isKw(tok(), 'LEFT') then
                        Unsupported('this DELETE form')
                    end
                    if kw('WHERE') then node.where = parseExpr() end
                    if isKw(tok(), 'ORDER') or isKw(tok(), 'LIMIT') then Unsupported('DELETE ... ORDER BY / LIMIT') end
                    return node
                end
                node.targets = {}
                repeat
                    local a = ident().v
                    if op('.') then needOp('*') end
                    node.targets[#node.targets + 1] = a
                until not op(',')
                needKw('FROM')
                node.from = parseFrom()
                if kw('WHERE') then node.where = parseExpr() end
                node.multi = true
                return node
            end
            if isKw(t, 'CREATE') then
                pos = pos + 1
                if isKw(tok(), 'TEMPORARY') or isKw(tok(), 'OR') then Unsupported('CREATE ' .. tok().u) end
                -- CREATE [UNIQUE] INDEX [IF NOT EXISTS] name ON t (cols): an ALTER TABLE ... ADD INDEX
                local unique = kw('UNIQUE')
                if kw('INDEX') then
                    local spec = { kind = unique and 'unique' or 'index', ifnot = ifNotExists() }
                    spec.name = ident().v
                    needKw('ON')
                    local node = { k = 'alter', stmt = 'ddl', table = tableName(), specs = { spec } }
                    spec.cols = parseKeyCols()
                    return node
                end
                if unique then err() end
                if not isKw(tok(), 'TABLE') then Unsupported('CREATE ' .. (tok().u or '?')) end
                local node = parseCreate()
                node.stmt = 'ddl'
                return node
            end
            if isKw(t, 'ALTER') then
                -- ALTER TABLE t ADD [COLUMN] [IF NOT EXISTS] col [FIRST | AFTER c] | ADD {INDEX|KEY} [IF NOT EXISTS] [name]
                -- (cols) | ADD UNIQUE [INDEX|KEY] [IF NOT EXISTS] [name] (cols), several separated by commas: what the
                -- SPEC's database upgrades may do (they only add)
                pos = pos + 1
                needKw('TABLE')
                local node = { k = 'alter', stmt = 'ddl', specs = {} }
                node.table = tableName()
                repeat
                    if not kw('ADD') then Unsupported('ALTER TABLE forms other than ADD') end
                    local spec
                    local u = tok().u
                    if u == 'INDEX' or u == 'KEY' or u == 'UNIQUE' then
                        pos = pos + 1
                        spec = { kind = u == 'UNIQUE' and 'unique' or 'index' }
                        if u == 'UNIQUE' and not kw('KEY') then kw('INDEX') end
                        spec.ifnot = ifNotExists()
                        if tok().t == 'id' then spec.name = ident().v end
                        spec.cols = parseKeyCols()
                    elseif u == 'PRIMARY' or u == 'CONSTRAINT' or u == 'FOREIGN' or u == 'FULLTEXT' or u == 'SPATIAL'
                        or u == 'CHECK' then
                        Unsupported('ALTER TABLE ... ADD ' .. u)
                    else
                        kw('COLUMN')
                        if tok().t == 'op' and tok().v == '(' then Unsupported('ADD COLUMN (several columns)') end
                        spec = { kind = 'col', ifnot = ifNotExists() }
                        spec.col = parseColumnDef()
                        if kw('FIRST') then
                            spec.first = true
                        elseif kw('AFTER') then
                            spec.after = ident()
                        end
                    end
                    node.specs[#node.specs + 1] = spec
                until not op(',')
                return node
            end
            Unsupported('the statement "' .. ssub(sql, t.p, t.p + 30) .. '"')
        end

        local node = parseStatement()
        op(';')
        if tok().t ~= 'eof' then err() end
        node.np = np
        node.tables = tlist
        return node
    end
end

M.parse = Parse

-- ============================================================================
--                     4. TYPES, COMPARISON AND EXPRESSIONS
-- ============================================================================

local T_INT = { t = 'int' }
local T_BOOL1 = { t = 'int', bool1 = true }      -- a TINYINT(1) column read directly (oxmysql: boolean)
local T_BOOLP = { t = 'int', boolp = true }      -- a boolean: TRUE / FALSE, a comparison, AND / OR / NOT, IS NULL,
                                                 -- LIKE, IN, EXISTS, JSON_VALID, JSON_CONTAINS, a boolean parameter
                                                 -- (JSON_SET stores true / false for it; MariaDB's type_handler_bool)
local T_DBL = { t = 'dbl' }
local T_STR = { t = 'str' }                      -- utf8mb4_general_ci text
local T_BIN = { t = 'str', bin = true }          -- binary-collated text (JSON function results)
local T_JSON = { t = 'str', bin = true, json = true }
-- JSON function results (MariaDB's is_json_type): compared with text by their content (a JSON string without its
-- quotes and escapes); JSON_EXTRACT's also read as numbers from the value ("12" -> 12, true -> 1). They keep the
-- collation of their document: binary for a JSON column, utf8mb4_general_ci for a text ('..._CI').
local JTY = {
    fun = { t = 'str', bin = true, json = true, jfun = true },                  -- JSON_SET, JSON_REMOVE
    ext = { t = 'str', bin = true, json = true, jfun = true, jext = true },     -- JSON_EXTRACT
    raw = { t = 'str', bin = true, json = true, jext = true },                  -- JSON_EXTRACT compared as its text
    funci = { t = 'str', json = true, jfun = true },
    extci = { t = 'str', json = true, jfun = true, jext = true },
    rawci = { t = 'str', json = true, jext = true },
    jsonci = { t = 'str', json = true },
}
local T_DT = { t = 'dt' }
local T_DATE = { t = 'date' }
local T_NULL = { t = 'null' }
local DECT = {}
local function T_DEC(s)
    local t = DECT[s]
    if not t then t = { t = 'dec', s = s }; DECT[s] = t end
    return t
end
M.T = { INT = T_INT, STR = T_STR, DEC = T_DEC }

local function IsNumT(ty) local t = ty.t; return t == 'int' or t == 'dec' or t == 'dbl' end
local function IsTimeT(ty) return ty.t == 'dt' or ty.t == 'date' end

-- Merge the types of CASE / IF / COALESCE branches and UNION columns.
local function MergeT(a, b)
    -- a TINYINT(1) column is a boolean to oxmysql only when read directly (COALESCE(flag), a UNION with NULL: numbers)
    if a.t == 'null' then return b == T_BOOL1 and T_INT or b end
    if b.t == 'null' then return a == T_BOOL1 and T_INT or a end
    local at, bt = a.t, b.t
    if at == 'int' and bt == 'int' then return (a == T_BOOLP and b == T_BOOLP) and T_BOOLP or T_INT end
    if IsNumT(a) and IsNumT(b) then
        if at == 'dbl' or bt == 'dbl' then return T_DBL end
        return T_DEC(mmax(at == 'dec' and a.s or 0, bt == 'dec' and b.s or 0))
    end
    if IsTimeT(a) and IsTimeT(b) then return (at == 'dt' or bt == 'dt') and T_DT or T_DATE end
    if at == 'str' and bt == 'str' then
        if a.json and b.json then return T_JSON end
        if a.bin or b.bin then return T_BIN end
        return T_STR
    end
    return T_STR
end

local function ToStr(v, ty)
    local t = ty.t
    if t == 'str' then return v end
    if t == 'int' then return sformat('%d', v) end
    if t == 'dec' then return FmtDec(v, ty.s) end
    if t == 'dbl' then return FmtDouble(v) end
    if t == 'dt' then return FmtDT(v) end
    if t == 'date' then return FmtDate(v) end
    return tostring(v)
end

-- The number MariaDB reads from a JSON_EXTRACT value: a string's or number's leading number, true 1, else 0.
local function JextNum(v)
    local c = sbyte(v, 1)
    if c == 34 then return StrToNum(ssub(v, 2, -2)) end
    if c == 116 then return 1.0 end
    if c == 45 or (c and c >= 48 and c <= 57) then return StrToNum(v) end
    return 0.0
end

local function ToDouble(v, ty)
    local t = ty.t
    if t == 'int' then return v + 0.0 end
    if t == 'dec' then return v / POW10[ty.s] end
    if t == 'dbl' then return v end
    if t == 'str' then
        local e = ty.enum
        if e then return (e[v] or 0) + 0.0 end
        if ty.jext then return JextNum(v) end
        return StrToNum(v)
    end
    Unsupported('using a date/time value as a number')
end

-- Converter from one static type to another (nil when the value can be used as is).
local function Converter(from, to)
    if from == to or from.t == 'null' or to.t == 'null' then return nil end
    local ft, tt = from.t, to.t
    if tt == 'int' then
        if ft == 'int' then return nil end
    elseif tt == 'dec' then
        if ft == 'int' then
            local p = POW10[to.s]
            return function(v) return v and DecMul(v, p) end
        elseif ft == 'dec' then
            if from.s == to.s then return nil end
            local fs, ts = from.s, to.s
            return function(v) return v and Rescale(v, fs, ts) end
        end
    elseif tt == 'dbl' then
        if ft == 'int' or ft == 'dec' or ft == 'dbl' or ft == 'str' then
            return function(v) return v and ToDouble(v, from) end
        end
    elseif tt == 'dt' then
        if ft == 'date' then return nil end
        if ft == 'str' then return function(v) return v and ParseDT(v) end end
    elseif tt == 'date' then
        if ft == 'dt' then return function(v) return v and Midnight(v) end end
    elseif tt == 'str' then
        if ft == 'str' then return nil end
        return function(v) return v and ToStr(v, from) end
    end
    return nil
end

-- A text's number: the number it starts with (MariaDB's rule), or for an ENUM the member's number (1 = the
-- first member, the empty value 0), as MariaDB reads an ENUM in a number context (e + 0, e < 2, e = 2, SUM(e)).
local function StrNumOf(ty)
    local e = ty.enum
    if e then return function(v) return (e[v] or 0) + 0.0 end end
    if ty.jext then return JextNum end
    return StrToNum
end

local function TruthFn(ty)
    if ty.t == 'str' then
        local num = StrNumOf(ty)
        return function(v) if v == nil then return nil end return num(v) ~= 0 end
    end
    return function(v) if v == nil then return nil end return v ~= 0 end
end

-- Comparison class for two static types:
--   'int' plain Lua comparison (integers, DATETIME/DATE seconds), 'dec' scaled decimals, 'dbl' doubles,
--   'ci' collated text, 'bin' binary text, 'dts' date/time against text, 'null' always NULL.
local function CmpClass(a, b)
    local at, bt = a.t, b.t
    if at == 'null' or bt == 'null' then return 'null' end
    if at == 'str' and bt == 'str' then
        if a.jfun or b.jfun then return (a.bin or b.bin) and 'json' or 'jsonci' end
        return (a.bin or b.bin) and 'bin' or 'ci'
    end
    if IsTimeT(a) and IsTimeT(b) then
        if at == bt then return 'int' end
        return 'dtd'
    end
    if IsTimeT(a) or IsTimeT(b) then
        local other = IsTimeT(a) and b or a
        if other.t == 'str' then return 'dts' end
        Unsupported('comparing a DATETIME with a number')
    end
    if at == 'int' and bt == 'int' then return 'int' end
    if (at == 'int' or at == 'dec') and (bt == 'int' or bt == 'dec') then return 'dec' end
    return 'dbl'
end

-- utf8mb4_bin (the collation of JSON function results) pads with spaces: 'a' = 'a  '
local function PadKey(v)
    if sbyte(v, -1) == 32 then return (smatch(v, '^(.-) +$')) end
    return v
end
-- A JSON function result compared with text (MariaDB's compare_json_str): a JSON string by its content
local function JsonContent(v)
    if sbyte(v, 1) == 34 then
        local ok, e = pcall(JstrEnd, v, 1)
        if ok then return JstrDecode(ssub(v, 1, e)) end
    end
    return v
end

-- Normalisers: value -> comparable Lua value for the class (per side).
local function NormFor(cls, ty, otherTy, ordering)
    if cls == 'int' then return nil end
    if cls == 'bin' then return ordering and BinOrderKey or PadKey end
    if cls == 'ci' then return ordering and CiOrderKey or CiKey end
    if cls == 'dec' then
        local s = mmax(ty.t == 'dec' and ty.s or 0, otherTy.t == 'dec' and otherTy.s or 0)
        local mine = ty.t == 'dec' and ty.s or 0
        if mine == s then return nil end
        local p = POW10[s - mine]
        return function(v) return DecMul(v, p) end
    end
    if cls == 'dbl' then
        return function(v) return ToDouble(v, ty) end
    end
    if cls == 'dts' then
        if ty.t == 'str' then return ParseDT end
        return nil
    end
    if cls == 'dtd' then
        return nil
    end
    return nil
end

local CMPOPS = {
    ['='] = function(a, b) return a == b end,
    ['<>'] = function(a, b) return a ~= b end,
    ['<'] = function(a, b) return a < b end,
    ['<='] = function(a, b) return a <= b end,
    ['>'] = function(a, b) return a > b end,
    ['>='] = function(a, b) return a >= b end,
}

local function CompileCompare(opname, fa, ta, fb, tb)
    local cls = CmpClass(ta, tb)
    if cls == 'null' then return function() return nil end end
    local test = CMPOPS[opname]
    if cls == 'ci' and (opname == '=' or opname == '<>') then
        local want = opname == '='
        return function(f)
            local a = fa(f)
            if a == nil then return nil end
            local b = fb(f)
            if b == nil then return nil end
            local eq = a == b or CiKey(a) == CiKey(b)
            if eq == want then return 1 end
            return 0
        end
    end
    if cls == 'dtd' then
        -- DATETIME against DATE: compare the DATE as its midnight (both are seconds already)
        cls = 'int'
    end
    if cls == 'json' or cls == 'jsonci' then
        -- the first JSON function result is read for its content, the other side is text as it is; then the
        -- collation (binary with trailing spaces ignored, or utf8mb4_general_ci)
        local ordering = opname ~= '=' and opname ~= '<>'
        local key = cls == 'json' and (ordering and BinOrderKey or PadKey) or (ordering and CiOrderKey or CiKey)
        local na = ta.jfun and function(v) return key(JsonContent(v)) end or key
        local nb = (not ta.jfun) and function(v) return key(JsonContent(v)) end or key
        return function(f)
            local a = fa(f)
            if a == nil then return nil end
            local b = fb(f)
            if b == nil then return nil end
            if test(na(a), nb(b)) then return 1 end
            return 0
        end
    end
    local ordering = opname ~= '=' and opname ~= '<>'
    local na, nb = NormFor(cls, ta, tb, ordering), NormFor(cls, tb, ta, ordering)
    if not na and not nb then
        return function(f)
            local a = fa(f)
            if a == nil then return nil end
            local b = fb(f)
            if b == nil then return nil end
            if test(a, b) then return 1 end
            return 0
        end
    end
    return function(f)
        local a = fa(f)
        if a == nil then return nil end
        local b = fb(f)
        if b == nil then return nil end
        if na then a = na(a) if a == nil then return nil end end
        if nb then b = nb(b) if b == nil then return nil end end
        if test(a, b) then return 1 end
        return 0
    end
end

-- Equality key for hash lookups: the column's type and the probe's type must compare in class
-- 'int', 'ci' or 'bin'; returns a function probe -> key, or nil when an index cannot be used.
local function IDENT(v) return v end
local function KeyNormForLookup(colTy, probeTy)
    local ok, cls = pcall(CmpClass, colTy, probeTy)
    if not ok then return nil end
    if cls == 'int' then
        if colTy.t == 'date' and probeTy.t ~= 'date' then return nil end
        return IDENT
    end
    if cls == 'ci' then return CiKey end
    if cls == 'bin' then return IDENT end
    return nil
end

-- The key a stored value has in a hash index of its column.
local function IndexNorm(ty)
    if ty.t == 'str' and not ty.bin then return CiKey end
    return nil
end

-- The sort key of a value for ORDER BY: an ENUM sorts by member number, text by collation with PAD SPACE.
local function OrderNorm(ty)
    local e = ty.enum
    if e then return function(v) return e[v] or 0 end end
    if ty.t == 'str' then return ty.bin and BinOrderKey or CiOrderKey end
    return nil
end

local LikeMatcher
do
    local LIKEC, likeN = {}, 0
    local UTF8CH = '[%z\1-\127\194-\244][\128-\191]*'
    LikeMatcher = function(pat, bin)
        local key = (bin and 'b' or 'c') .. pat
        local lp = LIKEC[key]
        if lp then return lp end
        local src = bin and pat or CiFold(pat)
        local out, i, n = { '^' }, 1, #src
        while i <= n do
            local c = ssub(src, i, i)
            if c == '\\' and i < n then
                local _, e = sfind(src, UTF8CH, i + 1)
                local ch = ssub(src, i + 1, e)
                out[#out + 1] = (sgsub(ch, '[%^%$%(%)%%%.%[%]%*%+%-%?]', '%%%0'))
                i = e + 1
            elseif c == '%' then
                out[#out + 1] = '.-'
                i = i + 1
            elseif c == '_' then
                out[#out + 1] = UTF8CH
                i = i + 1
            else
                out[#out + 1] = (sgsub(c, '[%^%$%(%)%%%.%[%]%*%+%-%?]', '%%%0'))
                i = i + 1
            end
        end
        out[#out + 1] = '$'
        lp = concat(out)
        likeN = likeN + 1
        if likeN > 2000 then LIKEC, likeN = {}, 0 end
        LIKEC[key] = lp
        return lp
    end
end

local EMPTY = {}

-- What a compiled reader computes, for the fused row code of aggregates (section 5b): META[fn] describes fn
-- when it is a literal, a column, a column compared with a literal or parameter, a numeric AND / OR, IS NULL or
-- a one-branch CASE. Anything else is called as it is.
local META = setmetatable({}, { __mode = 'k' })
local FuseUpdaters, FusePreds, FuseGroupKey -- section 5b

-- A literal's reader, remembered so CASE can return the value itself (CONSTV[fn] = { value }).
local CONSTV = setmetatable({}, { __mode = 'k' })
local function ConstFn(v)
    local fn = function() return v end
    CONSTV[fn] = { v }
    META[fn] = { k = 'const', v = v }
    return fn
end

-- ============================================================================
--                                      ═
-- ============================================================================
-- 5. Compiler: expressions and queries become closures over frames
--    A frame f holds one row per FROM source (f[i]; false for a NULL-extended LEFT JOIN row),
--    f.up is the outer frame of a correlated subquery and f.aggs the finished aggregates of a group.

-- ============================================================================
--                                      ═
-- ============================================================================

local CompileQuery -- forward: (ast, parentScope, C) -> plan

local function ResolveCol(sc, q, name)
    local depth, s = 0, sc
    while s do
        local found, fsi, fci
        for si = 1, #s.srcs do
            local src = s.srcs[si]
            if q == nil or src.alias == q then
                local ci = src.cols[name]
                if ci then
                    if found and q == nil then
                        Fail(sformat('Column \'%s\' in %s is ambiguous', name, sc.clause or 'SELECT'))
                    end
                    found, fsi, fci = src, si, ci
                    if q then break end
                end
            end
        end
        if found then
            if depth > 0 then
                -- every scope between here and s depends on the outer row; the one directly inside s
                -- remembers the highest source of s it reads, so it runs after that source is bound
                local m = sc
                for _ = 1, depth do
                    m.correlated = true
                    if m.parent == s then m.outerMax = mmax(m.outerMax or 0, fsi) end
                    m = m.parent
                end
            end
            return depth, fsi, fci, found
        end
        s = s.parent
        depth = depth + 1
    end
    return nil
end

local function ColReader(depth, si, ci)
    if depth == 0 then
        local fn = function(f) local r = f[si] if r then return r[ci] end return nil end
        META[fn] = { k = 'col', si = si, ci = ci }
        return fn
    elseif depth == 1 then
        return function(f) local r = f.up[si] if r then return r[ci] end return nil end
    elseif depth == 2 then
        return function(f) local r = f.up.up[si] if r then return r[ci] end return nil end
    end
    return function(f)
        for _ = 1, depth do f = f.up end
        local r = f[si]
        if r then return r[ci] end
        return nil
    end
end

local Cx -- forward: (node, sc) -> fn, type, maxSource, colInfo

-- Sort comparator over key slots base+1 .. base+nk (NULL first ascending, last descending), ties by seqIdx.
local function MakeComparator(nk, desc, base, seqIdx)
    if nk == 1 then
        local i1, d1 = base + 1, desc[1]
        return function(a, b)
            local x, y = a[i1], b[i1]
            if x ~= y then
                if x == nil then return not d1 end
                if y == nil then return d1 end
                if d1 then return x > y end
                return x < y
            end
            return a[seqIdx] < b[seqIdx]
        end
    end
    if nk == 2 then
        local i1, d1, i2, d2 = base + 1, desc[1], base + 2, desc[2]
        return function(a, b)
            local x, y = a[i1], b[i1]
            if x ~= y then
                if x == nil then return not d1 end
                if y == nil then return d1 end
                if d1 then return x > y end
                return x < y
            end
            x, y = a[i2], b[i2]
            if x ~= y then
                if x == nil then return not d2 end
                if y == nil then return d2 end
                if d2 then return x > y end
                return x < y
            end
            return a[seqIdx] < b[seqIdx]
        end
    end
    return function(a, b)
        for j = 1, nk do
            local x, y = a[base + j], b[base + j]
            if x ~= y then
                if x == nil then return not desc[j] end
                if y == nil then return desc[j] end
                if desc[j] then return x > y end
                return x < y
            end
        end
        return a[seqIdx] < b[seqIdx]
    end
end

local AsText
do
    local function SubPlan(sub, sc)
        local plan = CompileQuery(sub, sc, sc.C)
        return plan
    end

    -- Run a subquery plan once per statement when it does not depend on the outer row.
    local function SubRunner(plan, C)
        if plan.correlated then
            return function(f, limit) return plan.run(f, limit) end
        end
        local gen, rows, n = -1, nil, 0
        local rt = C.rt
        return function(_, limit)
            if gen ~= rt.gen then
                rows, n = plan.run(nil, nil)
                gen = rt.gen
            end
            return rows, n
        end
    end

    local function NumResultType(ta, tb, op)
        if ta.t == 'null' or tb.t == 'null' then return T_NULL end
        if IsTimeT(ta) or IsTimeT(tb) then Unsupported('arithmetic on DATETIME values without INTERVAL') end
        local na = ta.t == 'str' and T_DBL or ta
        local nb = tb.t == 'str' and T_DBL or tb
        if na.t == 'dbl' or nb.t == 'dbl' then return T_DBL, na, nb end
        if na.t == 'int' and nb.t == 'int' then return T_INT, na, nb end
        local sa, sb = na.t == 'dec' and na.s or 0, nb.t == 'dec' and nb.s or 0
        if op == '*' then
            if sa + sb > 18 then return T_DBL, na, nb end
            return T_DEC(sa + sb), na, nb
        end
        return T_DEC(mmax(sa, sb)), na, nb
    end

    -- MariaDB's text of an expression in an error message ("BIGINT value is out of range in '<text>'"): columns as
    -- `db`.`table or alias`.`column`, a parameter as the literal oxmysql sends, operators with MariaDB's parentheses.
    local ExprText
    do
        local PREC = { ['+'] = 1, ['-'] = 1, ['*'] = 2 }
        ExprText = function(node, sc)
            local k = node.k
            if k == 'num' then return node.text end
            if k == 'str' then return '\'' .. sgsub(node.v, '[\\\']', '\\%0') .. '\'' end
            if k == 'null' then return 'NULL' end
            if k == 'param' then
                local v = sc.C.rt.P[node.i]
                if v == nil then return 'NULL' end
                if type(v) == 'string' then return '\'' .. sgsub(v, '[\\\']', '\\%0') .. '\'' end
                if mtype(v) == 'integer' then return sformat('%d', v) end
                return ShortFloat(v)
            end
            if k == 'col' then
                local s = sc
                while s do
                    for _, src in ipairs(s.srcs) do
                        if node.q == nil or src.alias == node.q then
                            local ci = src.cols[node.name]
                            if ci then
                                return sformat('`%s`.`%s`.`%s`', DBNAME, src.alias,
                                    src.names and src.names[ci] or node.text)
                            end
                        end
                    end
                    s = s.parent
                end
                return '`' .. node.text .. '`'
            end
            if k == 'neg' then
                local inner = ExprText(node.e, sc)
                if node.e.k == 'arith' then inner = '(' .. inner .. ')' end
                return '-' .. inner
            end
            if k == 'arith' then
                local p = PREC[node.op] or 1
                local a, b = ExprText(node.a, sc), ExprText(node.b, sc)
                if node.a.k == 'arith' and (PREC[node.a.op] or 1) < p then a = '(' .. a .. ')' end
                if node.b.k == 'arith' and (PREC[node.b.op] or 1) <= p then b = '(' .. b .. ')' end
                return a .. ' ' .. node.op .. ' ' .. b
            end
            if k == 'fn' then
                local parts = {}
                for i, a in ipairs(node.args or {}) do parts[i] = ExprText(a, sc) end
                return slower(node.name) .. '(' .. concat(parts, ',') .. ')'
            end
            if k == 'cmp' then return ExprText(node.a, sc) .. ' ' .. node.op .. ' ' .. ExprText(node.b, sc) end
            return '...'
        end
    end
    -- Integer arithmetic stops where MariaDB's does (error 1690) instead of wrapping around; a SUM past 18 digits
    -- (MariaDB sums in DECIMAL(65)) is refused.
    local function OutOfRange(node, sc) Fail(sformat('BIGINT value is out of range in \'%s\'', ExprText(node, sc))) end
    function M.sumTooBig() Unsupported('DECIMAL values of more than 18 digits') end

    local function CompileArith(node, sc)
        local fa, ta, ma = Cx(node.a, sc)
        local fb, tb, mb = Cx(node.b, sc)
        local op = node.op
        local mx = mmax(ma, mb)
        if op == '/' or op == '%' then Unsupported('the ' .. op .. ' operator') end
        local rt, na, nb = NumResultType(ta, tb, op)
        -- NULL in arithmetic makes a DOUBLE NULL (MariaDB: it matters where the type does, as in a UNION)
        if rt.t == 'null' then return function() return nil end, T_DBL, mx end
        if rt.t == 'dbl' then
            local ca, cb = ta, tb
            if op == '+' then
                return function(f)
                    local a = fa(f)
                    if a == nil then return nil end
                    local b = fb(f)
                    if b == nil then return nil end
                    return ToDouble(a, ca) + ToDouble(b, cb)
                end,
                    T_DBL,
                    mx
            elseif op == '-' then
                return function(f)
                    local a = fa(f)
                    if a == nil then return nil end
                    local b = fb(f)
                    if b == nil then return nil end
                    return ToDouble(a, ca) - ToDouble(b, cb)
                end,
                    T_DBL,
                    mx
            end
            return function(f)
                local a = fa(f)
                if a == nil then return nil end
                local b = fb(f)
                if b == nil then return nil end
                return ToDouble(a, ca) * ToDouble(b, cb)
            end,
                T_DBL,
                mx
        end
        if rt.t == 'int' then
            -- a wrapped sum has the sign of neither operand, a wrapped difference differs from a in sign while b
            -- does too, a wrapped product does not divide back (and -1 * MININT is the one product that looks right)
            if op == '+' then
                return function(f)
                    local a = fa(f)
                    if a == nil then return nil end
                    local b = fb(f)
                    if b == nil then return nil end
                    local r = a + b
                    if (a ~ r) & (b ~ r) < 0 then OutOfRange(node, sc) end
                    return r
                end,
                    T_INT,
                    mx
            elseif op == '-' then
                return function(f)
                    local a = fa(f)
                    if a == nil then return nil end
                    local b = fb(f)
                    if b == nil then return nil end
                    local r = a - b
                    if (a ~ b) & (a ~ r) < 0 then OutOfRange(node, sc) end
                    return r
                end,
                    T_INT,
                    mx
            end
            return function(f)
                local a = fa(f)
                if a == nil then return nil end
                local b = fb(f)
                if b == nil then return nil end
                local r = a * b
                if a ~= 0 and (r // a ~= b or (a == -1 and b == MININT)) then OutOfRange(node, sc) end
                return r
            end,
                T_INT,
                mx
        end
        -- DECIMAL (more than 18 digits are refused, as in decMul)
        local sa, sb = na.t == 'dec' and na.s or 0, nb.t == 'dec' and nb.s or 0
        if op == '*' then
            return function(f)
                local a = fa(f)
                if a == nil then return nil end
                local b = fb(f)
                if b == nil then return nil end
                return DecMul(a, b)
            end,
                rt,
                mx
        end
        local s = rt.s
        local pa, pb = POW10[s - sa], POW10[s - sb]
        if op == '+' then
            return function(f)
                local a = fa(f)
                if a == nil then return nil end
                local b = fb(f)
                if b == nil then return nil end
                a, b = DecMul(a, pa), DecMul(b, pb)
                local r = a + b
                if (a ~ r) & (b ~ r) < 0 then Unsupported('DECIMAL values of more than 18 digits') end
                return r
            end,
                rt,
                mx
        end
        return function(f)
            local a = fa(f)
            if a == nil then return nil end
            local b = fb(f)
            if b == nil then return nil end
            a, b = DecMul(a, pa), DecMul(b, pb)
            local r = a - b
            if (a ~ b) & (a ~ r) < 0 then Unsupported('DECIMAL values of more than 18 digits') end
            return r
        end,
            rt,
            mx
    end

    -- column <op> literal / parameter, the shape of almost every WHERE and CASE condition: the column is read
    -- and compared in one closure (integers, DATETIME seconds and text; other classes use compileCompare).
    local FLIP = { ['='] = '=', ['<>'] = '<>', ['<'] = '>', ['>'] = '<', ['<='] = '>=', ['>='] = '<=' }
    local function FastCompare(node, sc, ca, ta, cb, tb)
        local op = node.op
        local colInfo, cty, other, oty = ca, ta, node.b, tb
        if not colInfo then colInfo, cty, other, oty, op = cb, tb, node.a, ta, FLIP[op] end
        if not colInfo then return nil end
        local ok = other.k
        if ok ~= 'num' and ok ~= 'str' and ok ~= 'param' then return nil end
        local okCls, cls = pcall(CmpClass, cty, oty)
        if not okCls or (cls ~= 'int' and cls ~= 'ci') then return nil end
        local si, ci = colInfo.si, colInfo.ci
        local P, pi = sc.C.rt.P, other.k == 'param' and other.i or nil
        local K
        if not pi then
            local kf = Cx(other, sc)
            K = kf()
            if K == nil then return nil end
        end
        local test = CMPOPS[op]
        if cls == 'ci' then
            if op ~= '=' and op ~= '<>' then return nil end
            local want = op == '=' and 1 or 0
            local other0 = 1 - want
            if pi then
                local fn = function(f)
                    local r = f[si]
                    if not r then return nil end
                    local a = r[ci]
                    if a == nil then return nil end
                    local b = P[pi]
                    if b == nil then return nil end
                    if a == b or CiKey(a) == CiKey(b) then return want end
                    return other0
                end
                META[fn] = { k = 'cip', si = si, ci = ci, P = P, pi = pi, want = want }
                return fn
            end
            local KK = CiKey(K)
            local memo, mn = {}, 0 -- answer per stored text (a column holds few distinct texts)
            local fn = function(f)
                local r = f[si]
                if not r then return nil end
                local a = r[ci]
                if a == nil then return nil end
                if a == K then return want end
                local m = memo[a]
                if m == nil then
                    if CiKey(a) == KK then m = want else m = other0 end
                    mn = mn + 1
                    if mn > 4096 then memo, mn = {}, 0 end
                    memo[a] = m
                end
                return m
            end
            META[fn] = { k = 'cik', si = si, ci = ci, K = K, KK = KK, want = want }
            return fn
        end
        local fn
        if pi then
            if op == '=' then
                fn = function(f)
                    local r = f[si]
                    if not r then return nil end
                    local a = r[ci]
                    if a == nil then return nil end
                    local b = P[pi]
                    if b == nil then return nil end
                    if a == b then return 1 end
                    return 0
                end
            else
                fn = function(f)
                    local r = f[si]
                    if not r then return nil end
                    local a = r[ci]
                    if a == nil then return nil end
                    local b = P[pi]
                    if b == nil then return nil end
                    if test(a, b) then return 1 end
                    return 0
                end
            end
            META[fn] = { k = 'cmpp', si = si, ci = ci, op = op, P = P, pi = pi }
            return fn
        end
        if op == '=' then
            fn = function(f)
                local r = f[si]
                if not r then return nil end
                local a = r[ci]
                if a == nil then return nil end
                if a == K then return 1 end
                return 0
            end
        elseif op == '<>' then
            fn = function(f)
                local r = f[si]
                if not r then return nil end
                local a = r[ci]
                if a == nil then return nil end
                if a ~= K then return 1 end
                return 0
            end
        else
            fn = function(f)
                local r = f[si]
                if not r then return nil end
                local a = r[ci]
                if a == nil then return nil end
                if test(a, K) then return 1 end
                return 0
            end
        end
        META[fn] = { k = 'cmpk', si = si, ci = ci, op = op, K = K }
        return fn
    end

    local AndOrNumeric -- forward: (fns, n, isAnd) -> fn
    local function AndOr(node, sc, isAnd)
        local fns, truths, n, mx = {}, {}, #node.list, 0
        local numeric = true
        for i = 1, n do
            local fn, ty, m = Cx(node.list[i], sc)
            fns[i] = fn
            truths[i] = TruthFn(ty)
            if ty.t == 'str' then numeric = false end
            if m > mx then mx = m end
        end
        if numeric then
            -- every operand is 1/0/NULL or a number: no text-to-number truth test needed
            local fn = AndOrNumeric(fns, n, isAnd)
            META[fn] = { k = isAnd and 'and' or 'or', list = fns }
            return fn, T_BOOLP, mx
        end
        if isAnd then
            return function(f)
                local unknown = false
                for i = 1, n do
                    local t = truths[i](fns[i](f))
                    if t == false then return 0 end
                    if t == nil then unknown = true end
                end
                if unknown then return nil end
                return 1
            end,
                T_BOOLP,
                mx
        end
        return function(f)
            local unknown = false
            for i = 1, n do
                local t = truths[i](fns[i](f))
                if t == true then return 1 end
                if t == nil then unknown = true end
            end
            if unknown then return nil end
            return 0
        end,
            T_BOOLP,
            mx
    end

    -- AND / OR of 1/0/NULL (or numeric) operands.
    AndOrNumeric = function(fns, n, isAnd)
        do
            if isAnd then
                if n == 2 then
                    local f1, f2 = fns[1], fns[2]
                    return function(f)
                        local a = f1(f)
                        if a == 0 then return 0 end
                        local b = f2(f)
                        if b == 0 then return 0 end
                        if a == nil or b == nil then return nil end
                        return 1
                    end
                end
                if n == 3 then
                    local f1, f2, f3 = fns[1], fns[2], fns[3]
                    return function(f)
                        local a = f1(f)
                        if a == 0 then return 0 end
                        local b = f2(f)
                        if b == 0 then return 0 end
                        local c = f3(f)
                        if c == 0 then return 0 end
                        if a == nil or b == nil or c == nil then return nil end
                        return 1
                    end
                end
                if n == 4 then
                    local f1, f2, f3, f4 = fns[1], fns[2], fns[3], fns[4]
                    return function(f)
                        local a = f1(f)
                        if a == 0 then return 0 end
                        local b = f2(f)
                        if b == 0 then return 0 end
                        local c = f3(f)
                        if c == 0 then return 0 end
                        local d = f4(f)
                        if d == 0 then return 0 end
                        if a == nil or b == nil or c == nil or d == nil then return nil end
                        return 1
                    end
                end
                return function(f)
                    local unknown = false
                    for i = 1, n do
                        local v = fns[i](f)
                        if v == nil then unknown = true elseif v == 0 then return 0 end
                    end
                    if unknown then return nil end
                    return 1
                end
            end
            return function(f)
                local unknown = false
                for i = 1, n do
                    local v = fns[i](f)
                    if v == nil then unknown = true elseif v ~= 0 then return 1 end
                end
                if unknown then return nil end
                return 0
            end
        end
    end

    -- Merge branch types and build per-branch converters.
    local function Unify(types)
        local t = T_NULL
        for i = 1, #types do t = MergeT(t, types[i]) end
        local convs = {}
        for i = 1, #types do convs[i] = Converter(types[i], t) or false end
        return t, convs
    end

    local function CompileCase(node, sc)
        local mx = 0
        local conds, vals, vtypes, rawConds = {}, {}, {}, {}
        local baseFn, baseTy
        if node.base then
            local m
            baseFn, baseTy, m = Cx(node.base, sc)
            if m > mx then mx = m end
            -- CASE x WHEN compares a JSON function result as the text it is (MariaDB's cmp_item, not compare_json_str)
            if baseTy.jfun then
                baseTy = baseTy.bin and (baseTy.jext and JTY.raw or T_JSON) or (baseTy.jext and JTY.rawci or JTY.jsonci)
            end
        end
        for i, w in ipairs(node.whens) do
            local cf, ct, m1 = Cx(w.c, sc)
            if baseFn then
                cf = CompileCompare('=', baseFn, baseTy, cf, ct)
                ct = T_INT
            end
            if ct.t == 'str' then
                local tf = TruthFn(ct)
                conds[i] = function(f) return tf(cf(f)) == true end
            else
                conds[i] = function(f) local v = cf(f); return v ~= nil and v ~= 0 end
                rawConds[i] = cf
            end
            local vf, vt, m2 = Cx(w.v, sc)
            vals[i], vtypes[i] = vf, vt
            mx = mmax(mx, m1, m2)
        end
        local ef, et
        local n = #conds
        if node.els then
            local m
            ef, et, m = Cx(node.els, sc)
            vtypes[n + 1] = et
            if m > mx then mx = m end
        end
        local rty, convs = Unify(vtypes)
        for i = 1, n do
            local cv, vf = convs[i], vals[i]
            if cv then
                if CONSTV[vf] then
                    vals[i] = ConstFn(cv(CONSTV[vf][1]))
                else
                    vals[i] = function(f) return cv(vf(f)) end
                end
            end
        end
        if ef and convs[n + 1] then
            local cv, e0 = convs[n + 1], ef
            if CONSTV[e0] then
                ef = ConstFn(cv(CONSTV[e0][1]))
            else
                ef = function(f) return cv(e0(f)) end
            end
        end
        if n == 1 and rawConds[1] then
            -- the common SUM(CASE WHEN <condition> THEN x ELSE y END): one function, literal branches inline
            local cf1, v1 = rawConds[1], vals[1]
            local k1, ke = CONSTV[v1], ef and CONSTV[ef] or nil
            if not ef then ke = { nil } end
            local fn
            if k1 and ke then
                local a, b = k1[1], ke[1]
                fn = function(f)
                    local v = cf1(f)
                    if v ~= nil and v ~= 0 then return a end
                    return b
                end
            elseif ke then
                local b = ke[1]
                fn = function(f)
                    local v = cf1(f)
                    if v ~= nil and v ~= 0 then return v1(f) end
                    return b
                end
            else
                fn = function(f)
                    local v = cf1(f)
                    if v ~= nil and v ~= 0 then return v1(f) end
                    return ef(f)
                end
            end
            META[fn] = { k = 'case1', c = cf1, a = v1, b = ef }
            return fn, rty, mx
        end
        if n == 1 then
            local c1, v1 = conds[1], vals[1]
            if ef then
                return function(f)
                    if c1(f) then return v1(f) end
                    return ef(f)
                end,
                    rty,
                    mx
            end
            return function(f)
                if c1(f) then return v1(f) end
                return nil
            end,
                rty,
                mx
        end
        return function(f)
            for i = 1, n do
                if conds[i](f) then return vals[i](f) end
            end
            if ef then return ef(f) end
            return nil
        end,
            rty,
            mx
    end

    local function CompileInList(node, sc)
        local fe, te, mx = Cx(node.e, sc)
        local items, n = {}, #node.list
        if te.jfun then
            if n == 1 then
                -- MariaDB makes x IN (a) x = a, which reads a JSON function result for its content
                local fa, ta, ma = Cx(node.list[1], sc)
                local eq = CompileCompare(node.neg and '<>' or '=', fe, te, fa, ta)
                return eq, T_BOOLP, mmax(mx, ma)
            end
            -- a longer list compares the JSON text as it is
            te = te.bin and (te.jext and JTY.raw or T_JSON) or (te.jext and JTY.rawci or JTY.jsonci)
        end
        local allConst = true
        local itypes = {}
        for i = 1, n do
            local fi, ti, mi = Cx(node.list[i], sc)
            items[i] = { fn = fi, ty = ti }
            itypes[i] = ti
            if mi > mx then mx = mi end
            if mi ~= 0 or node.list[i].k == 'subq' then allConst = false end
        end
        local neg = node.neg
        -- Fast path: a text or integer operand against literals/parameters of the same class.
        local cls
        for i = 1, n do
            local c = CmpClass(te, itypes[i])
            if cls == nil then cls = c elseif cls ~= c then cls = false end
        end
        if allConst and (cls == 'ci' or cls == 'int' or cls == 'bin') then
            local rt = sc.C.rt
            local gen, set, hasNull = -1, nil, false
            local norm = (cls == 'ci' and CiKey) or (cls == 'bin' and PadKey) or nil
            local memo, mn = {}, 0 -- answer per operand value for this list (text keys: one ciKey per text)
            local yes, no = neg and 0 or 1, neg and 1 or 0
            local fn
            fn = function(f)
                if gen ~= rt.gen then
                    local s2, hn = {}, false
                    for i = 1, n do
                        local v = items[i].fn(f)
                        if v == nil then
                            hn = true
                        else
                            s2[norm and norm(v) or v] = true
                        end
                    end
                    gen = rt.gen
                    -- the same list as before (literals): the answers stay
                    local same = set ~= nil and hn == hasNull
                    if same then
                        for k2 in pairs(s2) do if not set[k2] then same = false break end end
                        if same then for k2 in pairs(set) do if not s2[k2] then same = false break end end end
                    end
                    if not same then memo, mn = {}, 0 end
                    set, hasNull = s2, hn
                end
                local v = fe(f)
                if v == nil then return nil end
                local m = memo[v]
                if m ~= nil then return m end
                if set[norm and norm(v) or v] then m = yes elseif hasNull then m = false else m = no end
                if v == v then
                    mn = mn + 1
                    if mn > 4096 then memo, mn = {}, 0 end
                    memo[v] = m
                end
                if m == false then return nil end
                return m
            end
            -- a column against literals only: the same list on the same column is one comparison for the fused code
            local mc = META[fe]
            if mc and mc.k == 'col' then
                local parts = { 'in', mc.si, mc.ci, neg and 'n' or 'y', cls }
                local lits = true
                for i = 1, n do
                    local cv = CONSTV[items[i].fn]
                    if not cv then lits = false; break end
                    local v = cv[1]
                    parts[#parts + 1] = v == nil and 'N' or ((mtype(v) or type(v)) .. ':' .. tostring(v))
                end
                if lits then META[fn] = { k = 'inlistk', key = concat(parts, '\1') } end
            end
            return fn, T_BOOLP, mx, { inList = true, cls = cls, items = items, n = n }
        end
        local cmps = {}
        for i = 1, n do cmps[i] = CompileCompare('=', fe, te, items[i].fn, items[i].ty) end
        return function(f)
            local unknown = false
            for i = 1, n do
                local r = cmps[i](f)
                if r == 1 then return neg and 0 or 1 end
                if r == nil then unknown = true end
            end
            if unknown then return nil end
            return neg and 1 or 0
        end,
            T_BOOLP,
            mx
    end

    local function CompileInSub(node, sc)
        local fe, te, mx = Cx(node.e, sc)
        local plan = SubPlan(node.sub, sc)
        if #plan.cols ~= 1 then Fail('Operand should contain 1 column(s)') end
        if (plan.outerMax or 0) > mx then mx = plan.outerMax end
        local st = plan.types[1]
        local cls = CmpClass(te, st)
        local run = SubRunner(plan, sc.C)
        local neg = node.neg
        if cls == 'null' then
            -- NULL IN (empty set) is 0, NULL IN (anything else) is NULL
            return function(f)
                local _, rn = run(f, 1)
                if rn == 0 then return neg and 1 or 0 end
                return nil
            end,
                T_BOOLP,
                mx
        end
        if not plan.correlated and (cls == 'ci' or cls == 'int' or cls == 'bin') then
            local rt = sc.C.rt
            local gen, set, hasNull = -1, nil, false
            local norm = cls == 'ci' and CiKey or nil
            return function(f)
                if gen ~= rt.gen then
                    local rows, rn = run(f)
                    set, hasNull = {}, false
                    for i = 1, rn do
                        local v = rows[i][1]
                        if v == nil then hasNull = true else set[norm and norm(v) or v] = true end
                    end
                    gen = rt.gen
                end
                local v = fe(f)
                if v == nil then
                    if next(set) == nil and not hasNull then return neg and 1 or 0 end
                    return nil
                end
                if set[norm and norm(v) or v] then return neg and 0 or 1 end
                if hasNull then return nil end
                return neg and 1 or 0
            end,
                T_BOOLP,
                mx
        end
        local cur = { nil }
        local cmp = CompileCompare('=', fe, te, function() return cur[1] end, st)
        return function(f)
            local rows, rn = run(f)
            local unknown = false
            for i = 1, rn do
                cur[1] = rows[i][1]
                local r = cmp(f)
                if r == 1 then return neg and 0 or 1 end
                if r == nil then unknown = true end
            end
            if rn == 0 then return neg and 1 or 0 end
            if unknown then return nil end
            return neg and 1 or 0
        end,
            T_BOOLP,
            mx
    end

    local function CompileLike(node, sc)
        local fa, ta, ma = Cx(node.a, sc)
        local fb, tb, mb = Cx(node.b, sc)
        local bin = (ta.t == 'str' and ta.bin) or (tb.t == 'str' and tb.bin)
        local neg = node.neg
        local ca = ta.t ~= 'str' and ta or nil
        local cb = tb.t ~= 'str' and tb or nil
        if ta.t == 'null' or tb.t == 'null' then return function() return nil end, T_BOOLP, mmax(ma, mb) end
        return function(f)
            local a = fa(f)
            if a == nil then return nil end
            local b = fb(f)
            if b == nil then return nil end
            if ca then a = ToStr(a, ca) end
            if cb then b = ToStr(b, cb) end
            local m = sfind(bin and a or CiFold(a), LikeMatcher(b, bin)) ~= nil
            if m ~= neg then return 1 end
            return 0
        end,
            T_BOOLP,
            mmax(ma, mb)
    end

    local function ArgsOf(node, sc, want)
        local fns, tys, mx = {}, {}, 0
        for i, a in ipairs(node.args) do
            local f, t, m = Cx(a, sc)
            fns[i], tys[i] = f, t
            if m > mx then mx = m end
        end
        if want and #fns ~= want then
            Fail(sformat('Incorrect parameter count in the call to native function \'%s\'', node.name))
        end
        return fns, tys, mx
    end

    local function JsonNodeFrom(v, ty)
        if v == nil then return JNULL end
        if ty.boolp then return v ~= 0 and JTRUE or JFALSE end
        local t = ty.t
        if ty.json then
            local n = Jparse(v)
            if n then return n end
            return { t = 's', r = JstrEncode(v) }
        end
        if t == 'int' then return { t = 'n', r = sformat('%d', v) } end
        if t == 'dec' then return { t = 'n', r = FmtDec(v, ty.s) } end
        if t == 'dbl' then return { t = 'n', r = FmtDouble(v) } end
        if t == 'dt' then return { t = 's', r = JstrEncode(FmtDT(v)) } end
        if t == 'date' then return { t = 's', r = JstrEncode(FmtDate(v)) } end
        return { t = 's', r = JstrEncode(v) }
    end

    AsText = function(v, ty)
        if ty.t == 'str' then return v end
        return ToStr(v, ty)
    end

    local FUNCS = {}

    FUNCS.COALESCE = function(node, sc)
        local fns, tys, mx = ArgsOf(node, sc)
        if #fns == 0 then Fail('Incorrect parameter count in the call to native function \'COALESCE\'') end
        local rty, convs = Unify(tys)
        local n = #fns
        for i = 1, n do
            local cv, fn = convs[i], fns[i]
            if cv then fns[i] = function(f) return cv(fn(f)) end end
        end
        return function(f)
            for i = 1, n do
                local v = fns[i](f)
                if v ~= nil then return v end
            end
            return nil
        end,
            rty,
            mx
    end

    FUNCS.IFNULL = function(node, sc)
        if #node.args ~= 2 then Fail('Incorrect parameter count in the call to native function \'IFNULL\'') end
        return FUNCS.COALESCE(node, sc)
    end

    FUNCS.NULLIF = function(node, sc)
        local fns, tys, mx = ArgsOf(node, sc, 2)
        local fa, ta = fns[1], tys[1]
        local eq = CompileCompare('=', fa, ta, fns[2], tys[2])
        return function(f)
            local a = fa(f)
            if a == nil then return nil end
            if eq(f) == 1 then return nil end
            return a
        end,
            ta == T_BOOL1 and T_INT or ta,
            mx
    end

    FUNCS.IF = function(node, sc)
        local fns, tys, mx = ArgsOf(node, sc, 3)
        local truth = TruthFn(tys[1])
        local rty, convs = Unify({ tys[2], tys[3] })
        if rty.t == 'null' then
            rty = T_STR
        end -- IF(c, NULL, NULL) is text in MariaDB
        local fa, fb, fc = fns[1], fns[2], fns[3]
        local ca, cb = convs[1], convs[2]
        return function(f)
            if truth(fa(f)) == true then
                local v = fb(f)
                if ca then v = ca(v) end
                return v
            end
            local v = fc(f)
            if cb then v = cb(v) end
            return v
        end,
            rty,
            mx
    end

    -- The type GREATEST / LEAST compare in and answer with (MariaDB's aggregate_for_min_max): text with text is text,
    -- whole numbers with whole numbers are whole, a date or time wins over anything else, whole numbers with decimals
    -- are decimal, and any other mix (text with a number, a DOUBLE, NULL with a number) is DOUBLE.
    local function MinmaxT(types)
        local r
        for _, ty in ipairs(types) do
            if not r then
                r = ty
            else
                local a = r.t == 'null' and 'str' or r.t
                local b = ty.t == 'null' and 'str' or ty.t
                local ta, tb = a == 'dt' or a == 'date', b == 'dt' or b == 'date'
                if a == 'str' and b == 'str' then
                    r = MergeT(r, ty)
                elseif a == 'int' and b == 'int' then
                    r = (r == T_BOOLP and ty == T_BOOLP) and T_BOOLP or T_INT
                elseif ta or tb then
                    if ta and tb then
                        r = (a == 'dt' or b == 'dt') and T_DT or T_DATE
                    elseif tb then
                        r = ty
                    end
                elseif (a == 'int' or a == 'dec') and (b == 'int' or b == 'dec') then
                    r = T_DEC(mmax(a == 'dec' and r.s or 0, b == 'dec' and ty.s or 0))
                else
                    r = T_DBL
                end
            end
        end
        return r
    end

    local function MinmaxFn(name, greater)
        return function(node, sc)
            local fns, tys, mx = ArgsOf(node, sc)
            if #fns < 2 then Fail(sformat('Incorrect parameter count in the call to native function \'%s\'', name)) end
            local rty = MinmaxT(tys)
            local n = #fns
            for i = 1, n do
                local from, fn = tys[i], fns[i]
                if IsTimeT(rty) and from.t ~= 'null' and not IsTimeT(from) and from.t ~= 'str' then
                    Unsupported(name .. ' of a date and a number')
                end
                local cv = Converter(from, rty)
                if cv then fns[i] = function(f) return cv(fn(f)) end end
            end
            local norm = (rty.t == 'str' and not rty.bin) and CiOrderKey or nil
            return function(f)
                local best, bk
                for i = 1, n do
                    local v = fns[i](f)
                    if v == nil then return nil end
                    local k = norm and norm(v) or v
                    if best == nil or (greater and k > bk) or (not greater and k < bk) then best, bk = v, k end
                end
                return best
            end,
                rty,
                mx
        end
    end
    FUNCS.GREATEST = MinmaxFn('GREATEST', true)
    FUNCS.LEAST = MinmaxFn('LEAST', false)

    FUNCS.ROUND = function(node, sc)
        local fns, tys, mx = ArgsOf(node, sc)
        if #fns == 2 then
            if node.args[2].k ~= 'num' or tonumber(node.args[2].text) ~= 0 then
                Unsupported('ROUND(x, d) with d other than 0')
            end
        elseif #fns ~= 1 then
            Fail('Incorrect parameter count in the call to native function \'ROUND\'')
        end
        local fa, ta = fns[1], tys[1]
        if ta.t == 'int' then return fa, T_INT, mx end
        if ta.t == 'dec' then
            local s = ta.s
            return function(f) local v = fa(f) if v == nil then return nil end return Rescale(v, s, 0) end,
                T_DEC(0),
                mx
        end
        if ta.t == 'null' then return fa, T_DBL, mx end
        return function(f)
            local v = fa(f)
            if v == nil then return nil end
            return RoundHalfEven(ToDouble(v, ta)) + 0.0
        end,
            T_DBL,
            mx
    end

    FUNCS.DATE = function(node, sc)
        local fns, tys, mx = ArgsOf(node, sc, 1)
        local fa, ta = fns[1], tys[1]
        if ta.t == 'dt' then
            return function(f) local v = fa(f) if v == nil then return nil end return Midnight(v) end,
                T_DATE,
                mx
        end
        if ta.t == 'date' then return fa, T_DATE, mx end
        if ta.t == 'str' then
            return function(f)
                local v = fa(f)
                if v == nil then return nil end
                local t = ParseDT(v)
                return t and Midnight(t)
            end,
                T_DATE,
                mx
        end
        if ta.t == 'null' then return fa, T_DATE, mx end
        Unsupported('DATE() of a number')
    end

    FUNCS.DATE_FORMAT = function(node, sc)
        local fns, tys, mx = ArgsOf(node, sc, 2)
        local fa, ta, ff, tf = fns[1], tys[1], fns[2], tys[2]
        local conv
        if ta.t == 'str' then
            conv = ParseDT
        elseif not IsTimeT(ta) and ta.t ~= 'null' then
            Unsupported('DATE_FORMAT of a number')
        end
        return function(f)
            local v = fa(f)
            if v == nil then return nil end
            if conv then v = conv(v) if v == nil then return nil end end
            local fmt = ff(f)
            if fmt == nil then return nil end
            return DateFormat(v, AsText(fmt, tf))
        end,
            T_STR,
            mx
    end

    FUNCS.UNIX_TIMESTAMP = function(node, sc)
        local rt = sc.C.rt
        if #node.args == 0 then return function() return rt.now end, T_INT, 0 end
        local fns, tys, mx = ArgsOf(node, sc, 1)
        local fa, ta = fns[1], tys[1]
        if IsTimeT(ta) then return fa, T_INT, mx end
        if ta.t == 'str' then
            return function(f) local v = fa(f) if v == nil then return nil end return ParseDT(v) end,
                T_INT,
                mx
        end
        if ta.t == 'null' then return fa, T_NULL, mx end
        Unsupported('UNIX_TIMESTAMP of a number')
    end

    FUNCS.FROM_UNIXTIME = function(node, sc)
        local fns, tys, mx = ArgsOf(node, sc)
        if #fns ~= 1 then Unsupported('FROM_UNIXTIME with a format') end
        local fa, ta = fns[1], tys[1]
        if ta.t == 'null' then return fa, T_DT, mx end
        return function(f)
            local v = fa(f)
            if v == nil then return nil end
            if ta.t ~= 'int' then
                v = ToDouble(v, ta)
                v = mtointeger(mfloor(v))
                if not v then return nil end
            end
            if v < 0 then return nil end
            return v
        end,
            T_DT,
            mx
    end

    FUNCS.NOW = function(node, sc)
        if #node.args > 0 then Unsupported('NOW(precision)') end
        local rt = sc.C.rt
        return function() return rt.now end, T_DT, 0
    end
    FUNCS.CURRENT_TIMESTAMP = FUNCS.NOW
    FUNCS.LOCALTIMESTAMP = FUNCS.NOW

    local UNIT_SECONDS = { SECOND = 1, MINUTE = 60, HOUR = 3600 }

    FUNCS.TIMESTAMPDIFF = function(node, sc)
        local per = UNIT_SECONDS[node.unit] or (node.unit == 'DAY' and 86400) or (node.unit == 'WEEK' and 604800)
        if not per then Unsupported('TIMESTAMPDIFF(' .. tostring(node.unit) .. ', ...)') end
        local fns, tys, mx = ArgsOf(node, sc, 2)
        local fa, fb = fns[1], fns[2]
        local ca = tys[1].t == 'str' and ParseDT or nil
        local cb = tys[2].t == 'str' and ParseDT or nil
        return function(f)
            local a = fa(f)
            if a == nil then return nil end
            local b = fb(f)
            if b == nil then return nil end
            if ca then a = ca(a) if not a then return nil end end
            if cb then b = cb(b) if not b then return nil end end
            local d = b - a
            if d >= 0 then return d // per end
            return -(-d // per)
        end,
            T_INT,
            mx
    end

    FUNCS.SUBSTRING_INDEX = function(node, sc)
        -- SUBSTRING_INDEX(GROUP_CONCAT(x ORDER BY ... SEPARATOR 'c'), 'c', 1) with a one-character separator is the
        -- first x in that order (cut at its own first 'c'): the aggregate keeps only that one (no list, no sort)
        local a1, a2, a3 = node.args and node.args[1], node.args and node.args[2], node.args and node.args[3]
        if a1 and a2 and a3 and #node.args == 3 and a1.k == 'fn' and a1.name == 'GROUP_CONCAT' and not a1.star
            and a1.order and #a1.order > 0 and a2.k == 'str' and a3.k == 'num' and a3.text == '1'
            and #(a1.sep or ',') == 1 and a2.v == (a1.sep or ',') then
            a1.firstOnly = true
        end
        local fns, tys, mx = ArgsOf(node, sc, 3)
        local fs, fd, fc = fns[1], fns[2], fns[3]
        local ts, td, tc = tys[1], tys[2], tys[3]
        return function(f)
            local s, d, c = fs(f), fd(f), fc(f)
            if s == nil or d == nil or c == nil then return nil end
            s, d = AsText(s, ts), AsText(d, td)
            c = tc.t == 'int' and c or mtointeger(mfloor(ToDouble(c, tc))) or 0
            if c == 0 or d == '' then return '' end
            if c > 0 then
                local pos, found = 1, 0
                while true do
                    local a, b = sfind(s, d, pos, true)
                    if not a then return s end
                    found = found + 1
                    if found == c then return ssub(s, 1, a - 1) end
                    pos = b + 1
                end
            end
            local starts = {}
            local pos = 1
            while true do
                local a, b = sfind(s, d, pos, true)
                if not a then break end
                starts[#starts + 1] = { a, b }
                pos = b + 1
            end
            local k = #starts + c + 1
            if k < 1 then return s end
            return ssub(s, starts[k][2] + 1)
        end,
            ((ts.t == 'str' and ts.bin) or (td.t == 'str' and td.bin)) and T_BIN or T_STR,
            mx
    end

    FUNCS.CHAR_LENGTH = function(node, sc)
        local fns, tys, mx = ArgsOf(node, sc, 1)
        local fa, ta = fns[1], tys[1]
        return function(f)
            local v = fa(f)
            if v == nil then return nil end
            v = AsText(v, ta)
            return utf8len(v) or #v
        end,
            T_INT,
            mx
    end
    FUNCS.CHARACTER_LENGTH = FUNCS.CHAR_LENGTH

    FUNCS.LOWER = function(node, sc)
        local fns, tys, mx = ArgsOf(node, sc, 1)
        local fa, ta = fns[1], tys[1]
        return function(f)
            local v = fa(f)
            if v == nil then return nil end
            return LowerText(AsText(v, ta))
        end,
            (ta.t == 'str' and ta.bin) and T_BIN or T_STR,
            mx
    end
    FUNCS.LCASE = FUNCS.LOWER

    FUNCS.UUID = function(node, sc)
        ArgsOf(node, sc, 0)
        return function()
            local r = {}
            for i = 1, 16 do r[i] = math.random(0, 255) end
            r[7] = (r[7] & 0x0F) | 0x10
            r[9] = (r[9] & 0x3F) | 0x80
            return sformat('%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x', table.unpack(r))
        end,
            T_STR,
            0
    end

    local function JsonArg(fn, ty)
        return function(f)
            local v = fn(f)
            if v == nil then return nil end
            return AsText(v, ty)
        end
    end

    FUNCS.JSON_VALID = function(node, sc)
        local fns, tys, mx = ArgsOf(node, sc, 1)
        local fa = JsonArg(fns[1], tys[1])
        return function(f)
            local v = fa(f)
            if v == nil then return nil end
            return Jvalid(v) and 1 or 0
        end,
            T_BOOLP,
            mx
    end

    local function PathArg(node, fns, tys, i)
        local fn, ty = fns[i], tys[i]
        return function(f)
            local p = fn(f)
            if p == nil then return nil end
            return Jpath(AsText(p, ty))
        end
    end

    -- root with the value at steps[1..k] replaced by node (the path exists)
    local function Jreplace(root, steps, k, node)
        if k == 0 then return node end
        local container = Jwalk(root, steps, 1, k - 1)
        local st = steps[k]
        if st.key then
            container.v[JfindKey(container, st.key)] = node
        elseif container.t == 'a' then
            container.v[st.idx + 1] = node
        else
            return Jreplace(root, steps, k - 1, node)
        end
        return root
    end

    FUNCS.JSON_SET = function(node, sc)
        local fns, tys, mx = ArgsOf(node, sc)
        local n = #fns
        if n < 3 or n % 2 == 0 then Fail('Incorrect parameter count in the call to native function \'JSON_SET\'') end
        local fdoc = JsonArg(fns[1], tys[1])
        local paths, vals = {}, {}
        for i = 2, n, 2 do
            paths[#paths + 1] = PathArg(node, fns, tys, i)
            local vf, vt = fns[i + 1], tys[i + 1]
            vals[#vals + 1] = function(f) return JsonNodeFrom(vf(f), vt) end
        end
        local np = #paths
        return function(f)
            local doc = fdoc(f)
            if doc == nil then return nil end
            local root = Jparse(doc)
            if not root then return nil end
            for i = 1, np do
                local path = paths[i](f)
                if path == nil then return nil end
                if path.wild then Fail('Wildcards or range in JSON path not allowed') end
                local val = vals[i](f)
                local steps, sn = path.steps, path.n
                if sn == 0 then
                    root = val
                else
                    local parent = Jwalk(root, steps, 1, sn - 1)
                    if parent then
                        local last = steps[sn]
                        if last.key then
                            if parent.t == 'o' then
                                local j = JfindKey(parent, last.key)
                                if j then
                                    parent.v[j] = val
                                else
                                    parent.n = parent.n + 1
                                    parent.k[parent.n] = JstrEncode(last.key)
                                    parent.v[parent.n] = val
                                end
                            end
                        elseif parent.t == 'a' then
                            if last.idx < parent.n then
                                parent.v[last.idx + 1] = val
                            else
                                parent.n = parent.n + 1
                                parent.v[parent.n] = val
                            end
                        else
                            -- a value that is no array is a one-element array: [0] is the value itself, a later index
                            -- makes it the array [value, new]
                            root = Jreplace(root, steps, sn - 1,
                                last.idx == 0 and val or { t = 'a', v = { parent, val }, n = 2 })
                        end
                    end
                end
            end
            return Jtext(root)
        end,
            tys[1].bin and JTY.fun or JTY.funci,
            mx
    end

    FUNCS.JSON_REMOVE = function(node, sc)
        local fns, tys, mx = ArgsOf(node, sc)
        local n = #fns
        if n < 2 then Fail('Incorrect parameter count in the call to native function \'JSON_REMOVE\'') end
        local fdoc = JsonArg(fns[1], tys[1])
        local paths = {}
        for i = 2, n do paths[#paths + 1] = PathArg(node, fns, tys, i) end
        return function(f)
            local doc = fdoc(f)
            if doc == nil then return nil end
            local root = Jparse(doc)
            if not root then return nil end
            for i = 1, #paths do
                local path = paths[i](f)
                if path == nil then return nil end
                if path.wild then return nil end
                if path.n == 0 then Fail('Wildcards or range in JSON path not allowed') end
                local parent = Jwalk(root, path.steps, 1, path.n - 1)
                local last = path.steps[path.n]
                if parent then
                    if last.key and parent.t == 'o' then
                        local j = JfindKey(parent, last.key)
                        if j then
                            tremove(parent.k, j)
                            tremove(parent.v, j)
                            parent.n = parent.n - 1
                        end
                    elseif last.idx and parent.t == 'a' and last.idx < parent.n then
                        tremove(parent.v, last.idx + 1)
                        parent.n = parent.n - 1
                    end
                end
            end
            return Jtext(root)
        end,
            tys[1].bin and JTY.fun or JTY.funci,
            mx
    end

    FUNCS.JSON_EXTRACT = function(node, sc)
        local fns, tys, mx = ArgsOf(node, sc)
        if #fns ~= 2 then Unsupported('JSON_EXTRACT with several paths') end
        local fdoc = JsonArg(fns[1], tys[1])
        local fpath = PathArg(node, fns, tys, 2)
        local ftext = fns[2]
        return function(f)
            local doc = fdoc(f)
            if doc == nil then return nil end
            local path = fpath(f)
            if path == nil then return nil end
            local ptext = ftext(f)
            local memo = JmemoGet('x', ptext, doc)
            if memo ~= nil then return memo or nil end
            local root = Jparse(doc)
            local res
            if root then
                if path.wild then
                    local out = {}
                    Jcollect(root, path.steps, 1, out)
                    if #out > 0 then res = Jtext({ t = 'a', v = out, n = #out }) end
                else
                    local v = Jwalk(root, path.steps, 1, path.n)
                    if v then res = Jtext(v) end
                end
            end
            JmemoPut('x', ptext, doc, res or false)
            return res
        end,
            tys[1].bin and JTY.ext or JTY.extci,
            mx
    end

    FUNCS.JSON_UNQUOTE = function(node, sc)
        local fns, tys, mx = ArgsOf(node, sc, 1)
        local fa = JsonArg(fns[1], tys[1])
        return function(f)
            local v = fa(f)
            if v == nil then return nil end
            if #v >= 2 and sbyte(v, 1) == 34 and sbyte(v, -1) == 34 then
                local okEnd, e = pcall(JstrEnd, v, 1)
                if okEnd and e == #v then return JstrDecode(v) end
            end
            return v
        end,
            T_BIN,
            mx
    end

    FUNCS.JSON_VALUE = function(node, sc)
        local fns, tys, mx = ArgsOf(node, sc, 2)
        local fdoc = JsonArg(fns[1], tys[1])
        local fpath = PathArg(node, fns, tys, 2)
        local ftext = fns[2]
        local function value(doc, path)
            local root = Jparse(doc)
            if not root then return nil end
            local v
            if path.wild then
                local out = {}
                Jcollect(root, path.steps, 1, out)
                v = out[1]
            else
                v = Jwalk(root, path.steps, 1, path.n)
            end
            if not v then return nil end
            local t = v.t
            if t == 's' then return JstrDecode(v.r) end
            if t == 'n' then return v.r end
            if t == 'true' then return '1' end
            if t == 'false' then return '0' end
            return nil
        end
        return function(f)
            local doc = fdoc(f)
            if doc == nil then return nil end
            local path = fpath(f)
            if path == nil then return nil end
            local ptext = ftext(f)
            local memo = JmemoGet('v', ptext, doc)
            if memo ~= nil then return memo or nil end
            local res = value(doc, path)
            JmemoPut('v', ptext, doc, res or false)
            return res
        end,
            tys[1].bin and T_BIN or T_STR,
            mx -- the document's collation, like MariaDB's
    end

    FUNCS.JSON_CONTAINS = function(node, sc)
        local fns, tys, mx = ArgsOf(node, sc)
        if #fns ~= 2 then Unsupported('JSON_CONTAINS with a path') end
        local fa = JsonArg(fns[1], tys[1])
        local fb = JsonArg(fns[2], tys[2])
        return function(f)
            local a = fa(f)
            if a == nil then return nil end
            local b = fb(f)
            if b == nil then return nil end
            local memo = JmemoGet('c', b, a)
            if memo ~= nil then return memo or nil end
            local na, nb = Jparse(a), Jparse(b)
            local res = false
            if na and nb then res = Jcontains(na, nb) and 1 or 0 end
            JmemoPut('c', b, a, res)
            return res or nil
        end,
            T_BOOLP,
            mx
    end

    FUNCS.JSON_TYPE = function(node, sc)
        local fns, tys, mx = ArgsOf(node, sc, 1)
        local fa = JsonArg(fns[1], tys[1])
        return function(f)
            local v = fa(f)
            if v == nil then return nil end
            local n = Jparse(v)
            if not n then Fail('Syntax error in JSON text in argument 1 to function \'json_type\'') end
            local t = n.t
            if t == 'o' then return 'OBJECT' end
            if t == 'a' then return 'ARRAY' end
            if t == 's' then return 'STRING' end
            -- MariaDB: DOUBLE only with a fraction part (1e3 is an INTEGER)
            if t == 'n' then return sfind(n.r, '.', 1, true) and 'DOUBLE' or 'INTEGER' end
            if t == 'true' or t == 'false' then return 'BOOLEAN' end
            return 'NULL'
        end,
            T_STR,
            mx
    end

    -- Aggregates are compiled into slot readers; the scan fills f.aggs.
    local function CompileAgg(node, sc)
        local A = sc.agg
        if not A or sc.inAgg then Fail('Invalid use of group function') end
        local name = node.name
        if name == 'AVG' then Unsupported('AVG') end
        local def = { name = name }
        sc.inAgg = true
        local mx = 0
        if node.star then
            def.star = true
        else
            if #node.args ~= 1 then
                sc.inAgg = false
                if name == 'GROUP_CONCAT' then Unsupported('GROUP_CONCAT with several expressions') end
                Fail(sformat('Incorrect parameter count in the call to native function \'%s\'', name))
            end
            local m
            def.arg, def.aty, m = Cx(node.args[1], sc)
            mx = m
            if name == 'GROUP_CONCAT' then
                def.sep = node.sep or ','
                -- MariaDB sorts GROUP_CONCAT's rows in a tree whose comparison reads the stored key values without
                -- their NULL flags (a NULL key sorts as 0, '' or the zero date) and, on a full tie, puts the newer
                -- row first (it never answers "equal", so duplicates stay): the same here.
                def.order = {}
                for i, o in ipairs(node.order or {}) do
                    local of, ot = Cx(o.e, sc)
                    local zero = 0
                    local norm = IndexNorm(ot) and CiOrderKey or nil
                    if ot.t == 'str' then
                        zero = norm and norm('') or ''
                    elseif ot.t == 'dt' or ot.t == 'date' then
                        zero = MININT
                    end
                    def.order[i] = { fn = of, norm = norm, desc = o.desc, zero = zero }
                end
                local nord = #def.order
                if nord > 0 then
                    local ord = def.order
                    def.cmp = function(a, b)
                        for j = 1, nord do
                            local x, y = a[j + 1], b[j + 1]
                            if x ~= y then
                                if ord[j].desc then return x > y end
                                return x < y
                            end
                        end
                        return a.seq > b.seq
                    end
                    def.first = node.firstOnly == true
                end
            end
        end
        sc.inAgg = false
        local rty
        if name == 'COUNT' then
            rty = T_INT
        elseif name == 'SUM' then
            local at = def.aty.t
            if at == 'int' then
                rty = T_DEC(0)
            elseif at == 'dec' then
                rty = T_DEC(def.aty.s)
            elseif at == 'null' then
                rty = T_NULL
            elseif at == 'dbl' or at == 'str' then
                rty = T_DBL
            else
                Unsupported('SUM of a DATETIME')
            end
        elseif name == 'MAX' or name == 'MIN' then
            rty = def.aty
            if rty == T_BOOL1 or rty == T_BOOLP then rty = T_INT end
        else
            rty = T_STR
        end
        def.rty = rty
        local slot = #A + 1
        A[slot] = def
        return function(f) return f.aggs[slot] end, rty, 0
    end

    Cx = function(node, sc)
        local k = node.k
        if k == 'num' then
            local text = node.text
            if sfind(text, '[eE]') then
                local v = tonumber(text) * 1.0 -- (* 1.0 keeps -0e0 negative)
                return ConstFn(v), T_DBL, 0
            end
            if sfind(text, '.', 1, true) then
                local v, s = DecFromText(text)
                if not v then
                    local d = tonumber(text) + 0.0
                    return ConstFn(d), T_DBL, 0
                end
                return ConstFn(v), T_DEC(s), 0
            end
            local v = mtointeger(tonumber(text))
            if not v then
                local d = tonumber(text) + 0.0
                return ConstFn(d), T_DBL, 0
            end
            return ConstFn(v), node.bool and T_BOOLP or T_INT, 0
        elseif k == 'str' then
            return ConstFn(node.v), T_STR, 0
        elseif k == 'null' then
            return ConstFn(nil), T_NULL, 0
        elseif k == 'param' then
            local i, P = node.i, sc.C.rt.P
            return function() return P[i] end, sc.C.ptypes[i] or T_NULL, 0
        elseif k == 'col' then
            local depth, si, ci, src = ResolveCol(sc, node.q, node.name)
            if not depth then
                local alias = sc.aliasCols and node.q == nil and sc.aliasCols[node.name]
                if alias then return alias(sc) end
                Fail(sformat('Unknown column \'%s\' in \'%s\'', node.q and (node.q .. '.' .. node.text) or node.text,
                    sc.clause or 'SELECT'))
            end
            return ColReader(depth, si, ci),
                src.types[ci],
                depth == 0 and si or 0,
                depth == 0 and { si = si, ci = ci, src = src } or nil
        elseif k == 'neg' then
            local fa, ta, mx = Cx(node.e, sc)
            if ta.t == 'null' then return fa, T_DBL, mx end
            if ta.t == 'str' then
                local num = StrNumOf(ta)
                return function(f) local v = fa(f) if v == nil then return nil end return -num(v) end,
                    T_DBL,
                    mx
            end
            if IsTimeT(ta) then Unsupported('negating a DATETIME') end
            if ta.t == 'dbl' then
                return function(f) local v = fa(f) if v == nil then return nil end return -v end,
                    ta,
                    mx
            end
            return function(f)
                local v = fa(f)
                if v == nil then return nil end
                if v == MININT then
                    if ta.t == 'dec' then Unsupported('DECIMAL values of more than 18 digits') end
                    OutOfRange(node, sc)
                end
                return -v
            end,
                ta == T_BOOL1 and T_INT or ta,
                mx
        elseif k == 'not' then
            local fa, ta, mx = Cx(node.e, sc)
            local truth = TruthFn(ta)
            return function(f)
                local t = truth(fa(f))
                if t == nil then return nil end
                if t then return 0 end
                return 1
            end,
                T_BOOLP,
                mx
        elseif k == 'and' then
            return AndOr(node, sc, true)
        elseif k == 'or' then
            return AndOr(node, sc, false)
        elseif k == 'cmp' then
            local fa, ta, ma, ca = Cx(node.a, sc)
            local fb, tb, mb, cb = Cx(node.b, sc)
            local fast = FastCompare(node, sc, ca, ta, cb, tb)
            if fast then return fast, T_BOOLP, mmax(ma, mb) end
            return CompileCompare(node.op, fa, ta, fb, tb), T_BOOLP, mmax(ma, mb)
        elseif k == 'arith' then
            return CompileArith(node, sc)
        elseif k == 'isnull' then
            local fa, _, mx = Cx(node.e, sc)
            local fn
            if node.neg then
                fn = function(f) if fa(f) == nil then return 0 end return 1 end
            else
                fn = function(f) if fa(f) == nil then return 1 end return 0 end
            end
            META[fn] = { k = 'isnull', e = fa, neg = node.neg and true or false }
            return fn, T_BOOLP, mx
        elseif k == 'inlist' then
            return CompileInList(node, sc)
        elseif k == 'insub' then
            return CompileInSub(node, sc)
        elseif k == 'like' then
            return CompileLike(node, sc)
        elseif k == 'exists' then
            local plan = SubPlan(node.sub, sc)
            local run = SubRunner(plan, sc.C)
            return function(f)
                local _, n = run(f, 1)
                if n > 0 then return 1 end
                return 0
            end,
                T_BOOLP,
                plan.outerMax or 0
        elseif k == 'subq' then
            local plan = SubPlan(node.sub, sc)
            if #plan.cols ~= 1 then Fail('Operand should contain 1 column(s)') end
            local run = SubRunner(plan, sc.C)
            return function(f)
                local rows, n = run(f, 2)
                if n == 0 then return nil end
                if n > 1 then Fail('Subquery returns more than 1 row') end
                return rows[1][1]
            end,
                plan.types[1] == T_BOOL1 and T_INT or plan.types[1],
                plan.outerMax or 0
        elseif k == 'case' then
            return CompileCase(node, sc)
        elseif k == 'interval' then
            local per = UNIT_SECONDS[node.unit]
            if not per then Unsupported('INTERVAL ... ' .. tostring(node.unit)) end
            local fb, tb, mb = Cx(node.base, sc)
            local fnn, tn, mn = Cx(node.n, sc)
            local sign = node.sign
            local cb = tb.t == 'str' and ParseDT or nil
            if tb.t ~= 'str' and not IsTimeT(tb) and tb.t ~= 'null' then
                Unsupported('INTERVAL arithmetic on a number')
            end
            return function(f)
                local b = fb(f)
                if b == nil then return nil end
                if cb then b = cb(b) if not b then return nil end end
                local n = fnn(f)
                if n == nil then return nil end
                if tn.t ~= 'int' then
                    local d = ToDouble(n, tn)
                    n = d >= 0 and mfloor(d + 0.5) or -mfloor(-d + 0.5)
                    n = mtointeger(n) or 0
                end
                return b + sign * n * per
            end,
                T_DT,
                mmax(mb, mn)
        elseif k == 'fn' then
            local name = node.name
            if AGG[name] then return CompileAgg(node, sc) end
            local impl = FUNCS[name]
            if not impl then Unsupported('the function ' .. name .. '()') end
            return impl(node, sc)
        elseif k == 'values' then
            local vals = sc.valuesCols
            if not vals then Fail('Unknown column \'' .. node.text .. '\' in \'' .. (sc.clause or 'SELECT') .. '\'') end
            local ci = vals.index[node.name]
            if not ci then Fail(sformat('Unknown column \'%s\' in \'%s\'', node.text, sc.clause or 'SELECT')) end
            local rt = sc.C.rt
            return function() return rt.vals[ci] end, vals.types[ci], 0
        end
        Unsupported('the expression ' .. tostring(k))
    end
end

local PREDRAW = setmetatable({}, { __mode = 'k' })   -- a numeric filter's reader (for fusePreds)
local function PredOf(fn, ty)
    if ty.t == 'str' then
        local num = StrNumOf(ty)
        return function(f) local v = fn(f); return v ~= nil and num(v) ~= 0 end
    end
    local pred = function(f) local v = fn(f); return v ~= nil and v ~= 0 end
    PREDRAW[pred] = fn
    return pred
end

-- All filters of one scan level as one function (checked in order, stops at the first false).
local function AllOf(preds)
    local n = #preds
    if n <= 1 then return preds end
    if n == 2 then
        local p1, p2 = preds[1], preds[2]
        return {
            function(f) return p1(f) and p2(f) end,
        }
    end
    return {
        function(f)
            for i = 1, n do
                if not preds[i](f) then return false end
            end
            return true
        end,
    }
end

local function FlattenAnd(node, out)
    if node.k == 'and' then
        for _, c in ipairs(node.list) do FlattenAnd(c, out) end
    else
        out[#out + 1] = node
    end
    return out
end

local function HasAgg(node)
    if type(node) ~= 'table' then return false end
    if node.k == 'fn' and AGG[node.name] then return true end
    if node.k == 'subq' or node.k == 'exists' or node.k == 'insub' then
        return node.e ~= nil and HasAgg(node.e)
    end
    for key, v in pairs(node) do
        if key ~= 'sub' and type(v) == 'table' and HasAgg(v) then return true end
    end
    return false
end

-- ============================================================================
--                                 QUERY PLANS
-- ============================================================================
-- plan.run(upFrame, limit) -> rows (arrays of values in column order), count
-- plan.cols (names), plan.types, plan.correlated

-- Candidate rows for one FROM source (a hash lookup when a usable equality exists, else every row).
local function MakeCandidates(S, lookup, C)
    local rt = C.rt
    if S.kind == 'derived' then
        local plan = S.plan
        local gen, rows, n = -1, nil, 0
        local hash
        local function materialize()
            if gen ~= rt.gen then
                rows, n = plan.run(nil, nil)
                gen = rt.gen
                hash = nil
            end
        end
        if lookup then
            local keyFn, norm, ci, colNorm = lookup.keyFn, lookup.norm, lookup.ci, lookup.colNorm
            return function(f)
                materialize()
                if not hash then
                    hash = {}
                    for i = 1, n do
                        local r = rows[i]
                        local v = r[ci]
                        if v ~= nil then
                            local key = colNorm and colNorm(v) or v
                            local b = hash[key]
                            if not b then b = {}; hash[key] = b end
                            b[#b + 1] = r
                        end
                    end
                end
                local v = keyFn(f)
                if v == nil then return EMPTY, 0 end
                local key = norm(v)
                if key == nil then return EMPTY, 0 end
                local b = hash[key]
                if not b then return EMPTY, 0 end
                return b, #b
            end
        end
        return function()
            materialize()
            return rows, n
        end
    end
    local t = S.t
    if lookup then
        local keyFn, norm, ci = lookup.keyFn, lookup.norm, lookup.ci
        if lookup.unique then
            local buf = {}
            return function(f)
                local v = keyFn(f)
                if v == nil then return EMPTY, 0 end
                local key = norm(v)
                if key == nil then return EMPTY, 0 end
                local r = t.pkMap[key]
                if not r then return EMPTY, 0 end
                buf[1] = r
                return buf, 1
            end
        end
        if lookup.list then
            local items, n = lookup.items, lookup.n
            return function(f)
                local idx = t.idx[ci]
                local seen, out = {}, {}
                for i = 1, n do
                    local v = items[i].fn(f)
                    if v ~= nil then
                        local key = norm(v)
                        if key ~= nil then
                            if lookup.pkList then
                                local r = t.pkMap[key]
                                if r and not seen[r] then seen[r] = true; out[#out + 1] = r end
                            else
                                local b = idx.map[key]
                                if b then
                                    for j = 1, #b do
                                        local r = b[j]
                                        if not seen[r] then seen[r] = true; out[#out + 1] = r end
                                    end
                                end
                            end
                        end
                    end
                end
                if #out > 1 then tsort(out, function(a, b) return a.k < b.k end) end
                return out, #out
            end
        end
        return function(f)
            local v = keyFn(f)
            if v == nil then return EMPTY, 0 end
            local key = norm(v)
            if key == nil then return EMPTY, 0 end
            local b = t.idx[ci].map[key]
            if not b then return EMPTY, 0 end
            return b, #b
        end
    end
    return function()
        local rows = t.rows
        return rows, #rows
    end
end

-- Pick a hash lookup for source si from its equality conjuncts (only columns of si against values that
-- are known before si is scanned).
local function ChooseLookup(si, S, conjs, sc)
    local best
    for _, c in ipairs(conjs) do
        local node = c.node
        if node.k == 'cmp' and node.op == '=' then
            for side = 1, 2 do
                local colNode = side == 1 and node.a or node.b
                local other = side == 1 and node.b or node.a
                if colNode.k == 'col' then
                    local depth, csi, ci = ResolveCol(sc, colNode.q, colNode.name)
                    if depth == 0 and csi == si then
                        local ofn, oty, om = Cx(other, sc)
                        if om < si then
                            local cty = S.types[ci]
                            local norm = KeyNormForLookup(cty, oty)
                            if norm then
                                local cand
                                if S.kind == 'table' then
                                    local t = S.t
                                    if t.pk and #t.pk == 1 and t.pk[1] == ci then
                                        cand = { unique = true, score = 3 }
                                    elseif t.idx[ci] then
                                        cand = { score = 2 }
                                    end
                                else
                                    cand = { score = 1, colNorm = IndexNorm(cty) }
                                end
                                if cand and (not best or cand.score > best.score) then
                                    cand.keyFn, cand.norm, cand.ci = ofn, norm, ci
                                    best = cand
                                end
                            end
                        end
                    end
                end
            end
        elseif node.k == 'inlist' and not node.neg and node.e.k == 'col' and S.kind == 'table' then
            local depth, csi, ci = ResolveCol(sc, node.e.q, node.e.name)
            if depth == 0 and csi == si then
                local t = S.t
                local isPk = t.pk and #t.pk == 1 and t.pk[1] == ci
                if isPk or t.idx[ci] then
                    local items, ok, norm = {}, true, nil
                    local cty = S.types[ci]
                    for i, it in ipairs(node.list) do
                        local ofn, oty, om = Cx(it, sc)
                        if om ~= 0 or it.k == 'subq' then ok = false; break end
                        local nm = KeyNormForLookup(cty, oty)
                        if not nm or (norm and nm ~= norm) then ok = false; break end
                        norm = norm or nm
                        items[i] = { fn = ofn }
                    end
                    if ok and norm and (not best or best.score < 2) then
                        best = {
                            list = true,
                            pkList = isPk,
                            items = items,
                            n = #items,
                            norm = norm,
                            ci = ci,
                            score = 2,
                        }
                    end
                end
            end
        end
    end
    return best
end

-- A long SELECT gives the server its turn every few milliseconds (DB:exec, slicing): SL.on while such a
-- SELECT runs; every row a scan reads counts, and every 256 rows SL.step() looks at the clock.
M.slicing = { on = false, n = 0 }
local function BuildScan(levels, nsrc)
    local SL = M.slicing
    local runners = {}
    for si = nsrc, 1, -1 do
        local L = levels[si]
        local nextRun = runners[si + 1]
        local preds, np = L.preds, #L.preds
        local ons, no = L.ons, #L.ons
        local left = L.left
        local cands = L.cands
        if not left and no == 0 and np <= 1 and not nextRun then
            -- the common last (or only) source: one filter at most, no join condition
            local p1 = preds[1]
            if p1 then
                runners[si] = function(f, emit)
                    local arr, cnt = cands(f)
                    for i = 1, cnt do
                        if SL.on then local n = SL.n + 1; SL.n = n if n >= 256 then SL.step() end end
                        local row = arr[i]
                        if not row.dead then
                            f[si] = row
                            if p1(f) and emit(f) then return true end
                        end
                    end
                    return false
                end
            else
                runners[si] = function(f, emit)
                    local arr, cnt = cands(f)
                    for i = 1, cnt do
                        if SL.on then local n = SL.n + 1; SL.n = n if n >= 256 then SL.step() end end
                        local row = arr[i]
                        if not row.dead then
                            f[si] = row
                            if emit(f) then return true end
                        end
                    end
                    return false
                end
            end
        else
            runners[si] = function(f, emit)
                local arr, cnt = cands(f)
                local matched = false
                for i = 1, cnt do
                    if SL.on then local n = SL.n + 1; SL.n = n if n >= 256 then SL.step() end end
                    local row = arr[i]
                    if not row.dead then
                        f[si] = row
                        local ok = true
                        for j = 1, no do
                            if not ons[j](f) then ok = false; break end
                        end
                        if ok then
                            matched = true
                            for j = 1, np do
                                if not preds[j](f) then ok = false; break end
                            end
                            if ok then
                                local stop
                                if nextRun then stop = nextRun(f, emit) else stop = emit(f) end
                                if stop then return true end
                            end
                        end
                    end
                end
                if left and not matched then
                    f[si] = false
                    local ok = true
                    for j = 1, np do
                        if not preds[j](f) then ok = false; break end
                    end
                    if ok then
                        local stop
                        if nextRun then stop = nextRun(f, emit) else stop = emit(f) end
                        if stop then return true end
                    end
                end
                return false
            end
        end
    end
    return runners[1]
end

-- Sources, WHERE/ON placement and lookups shared by SELECT, UPDATE and DELETE.
local function PlanSources(sc, fromList, where, C)
    local srcs = sc.srcs
    local aliases = {}
    for i, item in ipairs(fromList) do
        local src = item.src
        local S
        if src.k == 'table' then
            local t = C.db.tables[src.name]
            if not t then Fail(sformat('Table \'%s.%s\' doesn\'t exist', DBNAME, src.name)) end
            C.used[t] = true
            S = {
                kind = 'table',
                t = t,
                alias = src.alias or src.name,
                cols = t.colIndex,
                types = t.types,
                names = t.colNames,
            }
        else
            local sub = CompileQuery(src.sub, nil, C)
            local cols = {}
            for ci, name in ipairs(sub.cols) do
                local l = slower(name)
                if cols[l] == nil then cols[l] = ci end
            end
            S = { kind = 'derived', plan = sub, alias = src.alias, cols = cols, types = sub.types, names = sub.cols }
        end
        if aliases[S.alias] then Fail(sformat('Not unique table/alias: \'%s\'', S.alias)) end
        aliases[S.alias] = true
        srcs[i] = S
    end
    local nsrc = #srcs
    local levels = {}
    for i = 1, nsrc do
        levels[i] = { preds = {}, ons = {}, conjs = {}, onConjs = {}, left = fromList[i].kind == 'left' }
    end
    local constPreds = {}
    -- ON conditions
    for i = 2, nsrc do
        local on = fromList[i].on
        if on then
            sc.clause = 'ON'
            for _, c in ipairs(FlattenAnd(on, {})) do
                local fn, ty, mx = Cx(c, sc)
                if mx > i then Fail('Unknown column in \'ON\'') end
                local pred = PredOf(fn, ty)
                if levels[i].left then
                    levels[i].ons[#levels[i].ons + 1] = pred
                    levels[i].onConjs[#levels[i].onConjs + 1] = { node = c }
                else
                    local lv = mmax(mx, 1)
                    levels[lv].preds[#levels[lv].preds + 1] = pred
                    levels[lv].conjs[#levels[lv].conjs + 1] = { node = c }
                end
            end
        end
    end
    if where then
        sc.clause = 'WHERE'
        for _, c in ipairs(FlattenAnd(where, {})) do
            if HasAgg(c) then Fail('Invalid use of group function') end
            local fn, ty, mx = Cx(c, sc)
            local pred = PredOf(fn, ty)
            if mx == 0 and nsrc > 0 then
                constPreds[#constPreds + 1] = pred
            else
                local lv = mmax(mx, 1)
                if nsrc == 0 then
                    constPreds[#constPreds + 1] = pred
                else
                    levels[lv].preds[#levels[lv].preds + 1] = pred
                    if not levels[lv].left then levels[lv].conjs[#levels[lv].conjs + 1] = { node = c } end
                end
            end
        end
    end
    sc.clause = 'SELECT'
    for i = 1, nsrc do
        local L = levels[i]
        local conjs = L.left and L.onConjs or L.conjs
        local lookup = ChooseLookup(i, srcs[i], conjs, sc)
        L.cands = MakeCandidates(srcs[i], lookup, C)
        L.preds = FusePreds(L.preds) or AllOf(L.preds)
    end
    local scan = nsrc > 0 and BuildScan(levels, nsrc) or nil
    return scan, constPreds, nsrc
end

local NULLK = {}
local NANK = {}   -- a NaN group value (a NaN cannot be a table key)

-- ============================================================================
--                                      ═
-- ============================================================================
-- 5b. Fused row code: the per-row work of an aggregate query (every aggregate's argument, CASE, AND / OR,
--     column comparisons) generated as one Lua function from the META descriptions of the compiled readers,
--     so a 50,000-row board does not pay a closure call per operator. The generated code computes exactly
--     what the readers compute (it is built from the same descriptions, NULL logic included); a reader
--     without a description is called as it is.

-- ============================================================================
--                                      ═
-- ============================================================================

do
    local OPSRC = { ['='] = '==', ['<>'] = '~=', ['<'] = '<', ['<='] = '<=', ['>'] = '>', ['>='] = '>=' }
    local MAXNODES = 400

    local Gen = {}
    Gen.__index = Gen

    -- pre: lines before the function (memo tables); pro: the function's first lines, where every column read and
    -- every column-against-literal / parameter comparison is computed once (they cannot fail and have no effect, so
    -- computing them up front changes nothing but the number of times they run).
    local function NewGen()
        return setmetatable({
            lines = {},
            ups = {},
            upIdx = {},
            nv = 0,
            nodes = 0,
            pre = {},
            pro = {},
            cols = {},
            rows = {},
            leaves = {},
            nlocals = 0,
        }, Gen)
    end

    -- The local holding column ci of source si for this row (nil for a NULL-extended row).
    function Gen:col(si, ci)
        local name = sformat('c%d_%d', si, ci)
        if not self.cols[name] then
            self.cols[name] = true
            if not self.rows[si] then
                self.rows[si] = true
                self.pro[#self.pro + 1] = sformat('local r%d = f[%d]', si, si)
                self.nlocals = self.nlocals + 1
            end
            self.pro[#self.pro + 1] = sformat('local %s; if r%d then %s = r%d[%d] end', name, si, name, si, ci)
            self.nlocals = self.nlocals + 1
        end
        return name
    end

    -- A comparison computed once in the prologue: key identifies it, code(var) returns its line.
    function Gen:leaf(key, code)
        local v = self.leaves[key]
        if v then return v end
        v = 'l' .. self.nlocals
        self.nlocals = self.nlocals + 1
        self.leaves[key] = v
        self.pro[#self.pro + 1] = 'local ' .. v .. '; ' .. code(v)
        return v
    end

    -- An upvalue of the generated function holding v (functions, tables, texts, floats, big integers).
    function Gen:up(v)
        local name = self.upIdx[v]
        if name then return name end
        name = 'u' .. (#self.ups + 1)
        self.ups[#self.ups + 1] = v
        self.upIdx[v] = name
        return name
    end

    function Gen:var()
        self.nv = self.nv + 1
        return 'v' .. self.nv
    end

    function Gen:emit(line) self.lines[#self.lines + 1] = line end

    function Gen:lit(v)
        if v == nil then return 'nil' end
        if mtype(v) == 'integer' and v > -1000000000000 and v < 1000000000000 then
            return '(' .. sformat('%d', v) .. ')'
        end
        if v ~= v then return nil end
        return self:up(v)
    end

    -- Code computing fn(f) into a new local; returns its name (or a literal).
    function Gen:expr(fn)
        self.nodes = self.nodes + 1
        local m = META[fn]
        if m and self.nodes > MAXNODES then m = nil end
        local k = m and m.k
        if k == 'const' then
            local l = self:lit(m.v)
            if l then return l end
        elseif k == 'col' then
            return self:col(m.si, m.ci)
        elseif k == 'cmpk' then
            local K = self:lit(m.K)
            if K then
                local a = self:col(m.si, m.ci)
                return self:leaf('k' .. a .. m.op .. K, function(v)
                    return sformat('if %s ~= nil then if %s %s %s then %s = 1 else %s = 0 end end', a, a, OPSRC[m.op],
                        K, v, v)
                end)
            end
        elseif k == 'cmpp' then
            local a = self:col(m.si, m.ci)
            local P = self:up(m.P)
            return self:leaf('p' .. a .. m.op .. P .. m.pi, function(v)
                return sformat(
                    'if %s ~= nil then local b = %s[%d]; if b ~= nil then if %s %s b then %s = 1 else %s = 0 end end end',
                    a, P, m.pi, a, OPSRC[m.op], v, v)
            end)
        elseif k == 'cik' then
            local a = self:col(m.si, m.ci)
            local K, KK, ck = self:up(m.K), self:up(m.KK), self:up(CiKey)
            return self:leaf('c' .. a .. K .. m.want, function(v)
                local memo, count = self:var(), self:var()
                self.pre[#self.pre + 1] = sformat('local %s, %s = {}, 0', memo, count)
                return sformat(
                    'if %s ~= nil then if %s == %s then %s = %d else local mm = %s[%s]; if mm == nil then if %s(%s) == %s then mm = %d else mm = %d end; %s = %s + 1; if %s > 4096 then %s = {}; %s = 0 end; %s[%s] = mm end; %s = mm end end',
                    a, a, K, v, m.want, memo, a, ck, a, KK, m.want, 1 - m.want, count, count, count, memo, count, memo,
                    a, v)
            end)
        elseif k == 'cip' then
            local a = self:col(m.si, m.ci)
            local P, ck = self:up(m.P), self:up(CiKey)
            return self:leaf('q' .. a .. P .. m.pi .. m.want, function(v)
                return sformat(
                    'if %s ~= nil then local b = %s[%d]; if b ~= nil then if %s == b or %s(%s) == %s(b) then %s = %d else %s = %d end end end',
                    a, P, m.pi, a, ck, a, ck, v, m.want, v, 1 - m.want)
            end)
        elseif k == 'inlistk' then
            local u = self:up(fn)
            return self:leaf(m.key, function(v) return sformat('%s = %s(f)', v, u) end)
        elseif k == 'and' or k == 'or' then
            local v = self:var()
            local isAnd = k == 'and'
            self:emit(sformat('local %s = %d', v, isAnd and 1 or 0))
            local open = 0
            for _, c in ipairs(m.list) do
                local cv = self:expr(c)
                if isAnd then
                    self:emit(sformat('if %s == 0 then %s = 0 else if %s == nil then %s = nil end', cv, v, cv, v))
                else
                    self:emit(sformat('if %s ~= nil and %s ~= 0 then %s = 1 else if %s == nil then %s = nil end', cv,
                        cv, v, cv, v))
                end
                open = open + 1
            end
            self:emit(srep('end ', open))
            return v
        elseif k == 'isnull' then
            local ev = self:expr(m.e)
            local v = self:var()
            self:emit(sformat('local %s; if %s == nil then %s = %d else %s = %d end', v, ev, v, m.neg and 0 or 1, v,
                m.neg and 1 or 0))
            return v
        elseif k == 'case1' then
            local v = self:var()
            self:emit('local ' .. v)
            local cv = self:expr(m.c)
            self:emit(sformat('if %s ~= nil and %s ~= 0 then', cv, cv))
            local av = self:expr(m.a)
            self:emit(sformat('%s = %s else', v, av))
            local bv = m.b and self:expr(m.b) or 'nil'
            self:emit(sformat('%s = %s end', v, bv))
            return v
        end
        local v = self:var()
        self:emit(sformat('local %s = %s(f)', v, self:up(fn)))
        return v
    end

    function Gen:build(header, body)
        if #self.ups + #self.pre * 2 > 180 or self.nlocals > 120 then return nil end
        local src = { 'local U = ...' }
        for i = 1, #self.ups do src[#src + 1] = sformat('local u%d = U[%d]', i, i) end
        for _, l in ipairs(self.pre) do src[#src + 1] = l end
        src[#src + 1] = header
        for _, l in ipairs(self.pro) do src[#src + 1] = l end
        for _, l in ipairs(body) do src[#src + 1] = l end
        src[#src + 1] = 'end'
        local text = concat(src, '\n')
        if M.onFused then M.onFused(text) end
        local chunk = load(text, '=memsql fused', 't', {})
        if not chunk then return nil end
        local ok, fn = pcall(chunk, self.ups)
        if not ok or type(fn) ~= 'function' then return nil end
        return fn
    end

    -- The filters of one scan level as one function (each checked in order, the first false stops), or nil.
    FusePreds = function(preds)
        local n = #preds
        if n == 0 then return nil end
        local any = false
        for i = 1, n do
            local raw = PREDRAW[preds[i]]
            if not raw then return nil end
            if META[raw] then any = true end
        end
        if not any then return nil end
        local g = NewGen()
        local body = {}
        for i = 1, n do
            g.lines = {}
            local v = g:expr(PREDRAW[preds[i]])
            for _, l in ipairs(g.lines) do body[#body + 1] = l end
            body[#body + 1] = sformat('if %s == nil or %s == 0 then return false end', v, v)
        end
        body[#body + 1] = 'return true'
        local fn = g:build('return function(f)', body)
        if not fn then return nil end
        return { fn }
    end

    -- The group of a row: (f, groups, newGroup) -> group, the GROUP BY values computed inline (NULL -> NULLK, a NaN
    -- -> NANK, text by its collation key), one map level per value; or nil.
    FuseGroupKey = function(gfns, gnorms, ng)
        local any = false
        for i = 1, ng do if META[gfns[i]] then any = true end end
        if not any then return nil end
        local g = NewGen()
        local nullk, nank = g:up(NULLK), g:up(NANK)
        for i = 1, ng do
            local v = g:expr(gfns[i])
            local k = 'k' .. i
            g:emit(sformat('local %s = %s', k, v))
            if gnorms[i] then
                g:emit(sformat('if %s == nil then %s = %s else %s = %s(%s) end', k, k, nullk, k, g:up(gnorms[i]), k))
            else
                g:emit(
                    sformat('if %s == nil then %s = %s elseif %s ~= %s then %s = %s end', k, k, nullk, k, k, k, nank))
            end
        end
        if ng == 1 then
            g:emit('local grp = groups[k1]')
            g:emit('if not grp then grp = newGroup(f, k1) end')
        else
            g:emit('local node = groups')
            for i = 1, ng - 1 do
                g:emit(sformat('local n%d = node[k%d]; if not n%d then n%d = {}; node[k%d] = n%d end; node = n%d', i, i,
                    i, i, i, i, i))
            end
            g:emit(sformat('local grp = node[k%d]', ng))
            g:emit(sformat('if not grp then grp = newGroup(f, nil); node[k%d] = grp end', ng))
        end
        g:emit('return grp')
        return g:build('return function(f, groups, newGroup)', g.lines)
    end

    -- One function (acc, f) running every aggregate's update for a row, or nil (then the updaters run one by one).
    FuseUpdaters = function(aggs, updaters)
        local n = #aggs
        if n == 0 then return nil end
        local g = NewGen()
        local body = {}
        local fusedAny = false
        for s = 1, n do
            local a = aggs[s]
            g.lines = {}
            local name = a.name
            if a.star then
                g:emit(sformat('acc[%d] = acc[%d] + 1', s, s))
            elseif name == 'COUNT' and META[a.arg] then
                local x = g:expr(a.arg)
                g:emit(sformat('if %s ~= nil then acc[%d] = acc[%d] + 1 end', x, s, s))
                fusedAny = true
            elseif name == 'SUM' and a.aty.t ~= 'str' and META[a.arg] then
                local x = g:expr(a.arg)
                if a.aty.t == 'int' or a.aty.t == 'dec' then
                    -- MariaDB sums in DECIMAL(65): past 18 digits the engine refuses instead of wrapping around
                    g:emit(sformat(
                        'if %s ~= nil then local c = acc[%d]; if c == nil then acc[%d] = %s else local r = c + %s; if (c ~ r) & (%s ~ r) < 0 then %s() end acc[%d] = r end end',
                        x, s, s, x, x, x, g:up(M.sumTooBig), s))
                else
                    g:emit(sformat(
                        'if %s ~= nil then local c = acc[%d]; if c == nil then acc[%d] = %s else acc[%d] = c + %s end end',
                        x, s, s, x, s, x))
                end
                fusedAny = true
            elseif (name == 'MAX' or name == 'MIN') and not (a.aty.t == 'str' and not a.aty.bin) and META[a.arg] then
                local x = g:expr(a.arg)
                g:emit(sformat('if %s ~= nil then local c = acc[%d]; if c == nil or %s %s c then acc[%d] = %s end end',
                    x, s, x, name == 'MAX' and '>' or '<', s, x))
                fusedAny = true
            else
                g:emit(sformat('%s(acc, f)', g:up(updaters[s])))
            end
            body[#body + 1] = 'do'
            for _, l in ipairs(g.lines) do body[#body + 1] = l end
            body[#body + 1] = 'end'
        end
        if not fusedAny then return nil end
        return g:build('return function(acc, f)', body)
    end
end

local function GroupKeyFn(fns, norms, n)
    if n == 1 then
        local fn, norm = fns[1], norms[1]
        return function(f)
            local v = fn(f)
            if v == nil then return NULLK end
            if norm then return norm(v) end
            if v ~= v then return NANK end
            return v
        end
    end
    return function(f)
        local parts = {}
        for i = 1, n do
            local v = fns[i](f)
            if v == nil then
                parts[i] = '\1'
            else
                if norms[i] then v = norms[i](v) end
                if mtype(v) == 'integer' then
                    parts[i] = 'i' .. sformat('%d', v)
                elseif type(v) == 'number' then
                    parts[i] = 'f' .. sformat('%.17g', v)
                else
                    parts[i] = 's' .. v
                end
            end
        end
        return concat(parts, '\0')
    end
end

local function CompileSelect(ast, parentSc, C)
    local sc = { C = C, parent = parentSc, srcs = {}, clause = 'SELECT' }
    local plan = { sc = sc }
    local scan, constPreds, nsrc = PlanSources(sc, ast.from or {}, ast.where, C)

    local isAgg = ast.group ~= nil
    if not isAgg then
        for _, it in ipairs(ast.items) do if it.e and HasAgg(it.e) then isAgg = true break end end
    end
    if not isAgg and ast.order then
        for _, o in ipairs(ast.order) do if HasAgg(o.e) then isAgg = true break end end
    end

    -- select list
    local aggList = isAgg and {} or nil
    local itemFns, itemTypes, names, itemNodes = {}, {}, {}, {}
    sc.agg = aggList
    for _, it in ipairs(ast.items) do
        if it.star then
            local any = false
            for si, S in ipairs(sc.srcs) do
                if it.q == nil or S.alias == it.q then
                    any = true
                    for ci, name in ipairs(S.names) do
                        itemFns[#itemFns + 1] = ColReader(0, si, ci)
                        itemTypes[#itemTypes + 1] = S.types[ci]
                        names[#names + 1] = name
                    end
                end
            end
            if not any then Fail(it.q and sformat('Unknown table \'%s\'', it.q) or 'No tables used') end
        else
            local fn, ty = Cx(it.e, sc)
            itemFns[#itemFns + 1] = fn
            itemTypes[#itemTypes + 1] = ty
            local name = it.alias
            if not name then
                if it.e.k == 'col' then name = it.e.text else name = it.text end
            end
            names[#names + 1] = name
            itemNodes[#itemFns] = it
        end
    end
    local ni = #itemFns
    local aliasIndex = {}
    for i = 1, ni do
        local it = itemNodes[i]
        if it and it.alias then
            local l = slower(it.alias)
            if aliasIndex[l] == nil then aliasIndex[l] = i end
        end
    end

    -- GROUP BY (row context; a bare name that is no column may name a select alias)
    local gfns, gnorms, ng = {}, {}, 0
    if ast.group then
        sc.agg = nil
        sc.clause = 'GROUP BY'
        for _, g in ipairs(ast.group) do
            local node = g
            if g.k == 'col' and g.q == nil and not ResolveCol(sc, nil, g.name) then
                local i = aliasIndex[g.name]
                if not i then Fail(sformat('Unknown column \'%s\' in \'GROUP BY\'', g.text)) end
                node = itemNodes[i].e
                if HasAgg(node) then Fail('Can\'t group on \'' .. g.text .. '\'') end
            elseif g.k == 'num' and smatch(g.text, '^%d+$') then
                local i = tonumber(g.text)
                if not itemNodes[i] then Fail(sformat('Unknown column \'%s\' in \'GROUP BY\'', g.text)) end
                node = itemNodes[i].e
            end
            local fn, ty = Cx(node, sc)
            ng = ng + 1
            gfns[ng] = fn
            gnorms[ng] = ty.enum and OrderNorm(ty) or IndexNorm(ty) -- GROUP BY: an ENUM by member number, text by collation
        end
        sc.clause = 'SELECT'
        sc.agg = aggList
    end

    -- ORDER BY (a bare name that is a select alias uses that value)
    local keyFns, keyDesc, nk = {}, {}, 0
    if ast.order then
        sc.clause = 'ORDER BY'
        for _, o in ipairs(ast.order) do
            local e = o.e
            local fn
            if e.k == 'col' and e.q == nil and aliasIndex[e.name] then
                local i = aliasIndex[e.name]
                local norm = OrderNorm(itemTypes[i])
                fn = function(_, out)
                    local v = out[i]
                    if v ~= nil and norm then return norm(v) end
                    return v
                end
            elseif e.k == 'num' and smatch(e.text, '^%d+$') then
                local i = tonumber(e.text)
                if i < 1 or i > ni then Fail(sformat('Unknown column \'%s\' in \'ORDER BY\'', e.text)) end
                local norm = OrderNorm(itemTypes[i])
                fn = function(_, out)
                    local v = out[i]
                    if v ~= nil and norm then return norm(v) end
                    return v
                end
            else
                local efn, ety = Cx(e, sc)
                local norm = OrderNorm(ety)
                if norm then
                    fn = function(f) local v = efn(f) if v ~= nil then return norm(v) end return nil end
                else
                    fn = function(f) return efn(f) end
                end
            end
            nk = nk + 1
            keyFns[nk] = fn
            keyDesc[nk] = o.desc
        end
        sc.clause = 'SELECT'
    end
    sc.agg = nil

    local limitFn, offsetFn
    local rt = C.rt
    local function limitValue(node)
        if not node then return nil end
        if node.k == 'num' then
            local v = mtointeger(tonumber(node.text))
            return function() return v end
        end
        local i = node.i
        local ty = C.ptypes[i]
        return function()
            local v = rt.P[i]
            if ty ~= T_INT or v == nil or v < 0 then
                Fail('Incorrect arguments to LIMIT')
            end
            return v
        end
    end
    limitFn, offsetFn = limitValue(ast.limit), limitValue(ast.offset)

    local distinct = ast.distinct
    local dnorms = {}
    for i = 1, ni do dnorms[i] = IndexNorm(itemTypes[i]) end
    local seqIdx = ni + nk + 1
    local cmp = nk > 0 and MakeComparator(nk, keyDesc, ni, seqIdx) or nil
    local gkey = ng > 0 and GroupKeyFn(gfns, gnorms, ng) or nil
    local naggs = aggList and #aggList or 0

    local function finishRows(rows, n)
        if cmp and n > 1 then tsort(rows, cmp) end
        local off = offsetFn and offsetFn() or 0
        local lim = limitFn and limitFn() or nil
        if off > 0 or (lim and lim < n) then
            local out, m = {}, 0
            local last = n
            if lim then last = mmin(n, off + lim) end
            for i = off + 1, last do m = m + 1; out[m] = rows[i] end
            return out, m
        end
        return rows, n
    end

    local function distinctKey(out)
        local parts = {}
        for i = 1, ni do
            local v = out[i]
            if v == nil then
                parts[i] = '\1'
            else
                if dnorms[i] then v = dnorms[i](v) end
                if mtype(v) == 'integer' then
                    parts[i] = 'i' .. sformat('%d', v)
                elseif type(v) == 'number' then
                    parts[i] = 'f' .. sformat('%.17g', v)
                else
                    parts[i] = 's' .. v
                end
            end
        end
        return concat(parts, '\0')
    end

    local function project(f, rows, n, seen)
        local out = {}
        for i = 1, ni do out[i] = itemFns[i](f) end
        if seen then
            local key = distinctKey(out)
            if seen[key] then return n end
            seen[key] = true
        end
        for j = 1, nk do out[ni + j] = keyFns[j](f, out) end
        n = n + 1
        out[seqIdx] = n
        rows[n] = out
        return n
    end

    if not isAgg then
        plan.run = function(up, limitHint)
            local f = { up = up }
            for i = 1, #constPreds do
                if not constPreds[i](f) then return {}, 0 end
            end
            local rows, n = {}, 0
            local seen = distinct and {} or nil
            local stopAt
            if not cmp then
                local lim = limitFn and limitFn() or nil
                if lim then stopAt = (offsetFn and offsetFn() or 0) + lim end
                if limitHint and (not stopAt or limitHint < stopAt) then stopAt = limitHint end
                if stopAt == 0 then return {}, 0 end
            end
            if nsrc == 0 then
                n = project(f, rows, n, seen)
            else
                scan(f, function(fr)
                    n = project(fr, rows, n, seen)
                    if stopAt and n >= stopAt then return true end
                    return false
                end)
            end
            return finishRows(rows, n)
        end
    else
        local aggs = aggList
        -- one small function per aggregate: acc[s] is its running value
        local updaters = {}
        for s = 1, naggs do
            local a = aggs[s]
            local name, arg = a.name, a.arg
            if a.star then
                updaters[s] = function(acc) acc[s] = acc[s] + 1 end
            elseif name == 'COUNT' then
                updaters[s] = function(acc, fr) if arg(fr) ~= nil then acc[s] = acc[s] + 1 end end
            elseif name == 'SUM' then
                if a.aty.t == 'str' then
                    local num = StrNumOf(a.aty)
                    updaters[s] = function(acc, fr)
                        local v = arg(fr)
                        if v ~= nil then
                            v = num(v)
                            local c = acc[s]
                            if c == nil then acc[s] = v else acc[s] = c + v end
                        end
                    end
                elseif a.aty.t == 'int' or a.aty.t == 'dec' then
                    updaters[s] = function(acc, fr)
                        local v = arg(fr)
                        if v ~= nil then
                            local c = acc[s]
                            if c == nil then
                                acc[s] = v
                            else
                                local r = c + v
                                if (c ~ r) & (v ~ r) < 0 then M.sumTooBig() end
                                acc[s] = r
                            end
                        end
                    end
                else
                    updaters[s] = function(acc, fr)
                        local v = arg(fr)
                        if v ~= nil then
                            local c = acc[s]
                            if c == nil then acc[s] = v else acc[s] = c + v end
                        end
                    end
                end
            elseif name == 'MAX' or name == 'MIN' then
                local isMax = name == 'MAX'
                if a.aty.t == 'str' and not a.aty.bin then
                    local keys = {}
                    updaters[s] = function(acc, fr)
                        local v = arg(fr)
                        if v ~= nil then
                            local cur = acc[s]
                            local kv = CiOrderKey(v)
                            if cur == nil then
                                acc[s] = v
                                keys[acc] = kv
                            else
                                local kc = keys[acc]
                                if (isMax and kv > kc) or (not isMax and kv < kc) then acc[s] = v; keys[acc] = kv end
                            end
                        end
                    end
                elseif isMax then
                    updaters[s] = function(acc, fr)
                        local v = arg(fr)
                        if v ~= nil then
                            local cur = acc[s]
                            if cur == nil or v > cur then acc[s] = v end
                        end
                    end
                else
                    updaters[s] = function(acc, fr)
                        local v = arg(fr)
                        if v ~= nil then
                            local cur = acc[s]
                            if cur == nil or v < cur then acc[s] = v end
                        end
                    end
                end
            elseif a.first then
                -- GROUP_CONCAT whose first value is all that is read: keep the value that sorts first, by the same
                -- order as the full list (NULL keys as their zero value, the newer row first on a full tie)
                local ord = a.order
                local nord = #ord
                updaters[s] = function(acc, fr)
                    local v = arg(fr)
                    if v == nil then return end
                    local best = acc[s]
                    if not best then
                        best = { v }
                        for j = 1, nord do
                            local o = ord[j]
                            local kv = o.fn(fr)
                            if kv == nil then kv = o.zero elseif o.norm then kv = o.norm(kv) end
                            best[j + 1] = kv
                        end
                        acc[s] = best
                        return
                    end
                    for j = 1, nord do
                        local o = ord[j]
                        local x = o.fn(fr)
                        if x == nil then x = o.zero elseif o.norm then x = o.norm(x) end
                        local y = best[j + 1]
                        if x ~= y then
                            local before
                            if o.desc then before = x > y else before = x < y end
                            if before then
                                best[1] = v
                                best[j + 1] = x
                                for jj = j + 1, nord do
                                    local o2 = ord[jj]
                                    local x2 = o2.fn(fr)
                                    if x2 == nil then x2 = o2.zero elseif o2.norm then x2 = o2.norm(x2) end
                                    best[jj + 1] = x2
                                end
                            end
                            return
                        end
                    end
                    -- a full tie: the newer row sorts first
                    best[1] = v
                end
            else
                local ord = a.order
                local nord = #ord
                updaters[s] = function(acc, fr)
                    local v = arg(fr)
                    if v ~= nil then
                        local list = acc[s]
                        local e = { v }
                        for j = 1, nord do
                            local o = ord[j]
                            local kv = o.fn(fr)
                            if kv == nil then kv = o.zero elseif o.norm then kv = o.norm(kv) end
                            e[j + 1] = kv
                        end
                        local m = #list + 1
                        e.seq = m
                        list[m] = e
                    end
                end
            end
        end
        local fused = FuseUpdaters(aggs, updaters)
        plan.fused = fused ~= nil
        local groupOf = ng > 0 and FuseGroupKey(gfns, gnorms, ng) or nil
        plan.run = function(up)
            local f = { up = up }
            local ok = true
            for i = 1, #constPreds do
                if not constPreds[i](f) then ok = false; break end
            end
            local groups, order, ngroups = {}, {}, 0
            local function newGroup(fr, key)
                local rep = { up = up }
                for i = 1, nsrc do rep[i] = fr[i] end
                local acc = {}
                for s = 1, naggs do
                    local a = aggs[s]
                    if a.name == 'COUNT' then
                        acc[s] = 0
                    elseif a.name == 'GROUP_CONCAT' then
                        acc[s] = (not a.first) and {} or false
                    end
                end
                local g = { rep = rep, acc = acc }
                if gkey then
                    local gk = {}
                    for i = 1, ng do
                        local v = gfns[i](fr)
                        if v ~= nil and gnorms[i] then v = gnorms[i](v) end
                        gk[i] = v
                    end
                    g.gk = gk
                end
                ngroups = ngroups + 1
                order[ngroups] = g
                g.seq = ngroups
                if key ~= nil then groups[key] = g end
                return g
            end
            local single
            local function emit(fr)
                local g
                if groupOf then
                    g = groupOf(fr, groups, newGroup)
                elseif ng > 1 then
                    -- several GROUP BY values: a tree of maps, one level per value (no key text per row)
                    local node = groups
                    for i = 1, ng do
                        local v = gfns[i](fr)
                        if v == nil then
                            v = NULLK
                        else
                            local norm = gnorms[i]
                            if norm then v = norm(v) elseif v ~= v then v = NANK end
                        end
                        if i == ng then
                            g = node[v]
                            if not g then g = newGroup(fr, nil); node[v] = g end
                        else
                            local nx = node[v]
                            if not nx then nx = {}; node[v] = nx end
                            node = nx
                        end
                    end
                elseif gkey then
                    local key = gkey(fr)
                    g = groups[key]
                    if not g then g = newGroup(fr, key) end
                else
                    g = single
                    if not g then g = newGroup(fr, nil); single = g end
                end
                local acc = g.acc
                if fused then fused(acc, fr) else for s = 1, naggs do updaters[s](acc, fr) end end
                return false
            end
            if ok then
                if nsrc == 0 then emit(f) else scan(f, emit) end
            end
            if not gkey and ngroups == 0 then
                newGroup({ up = up }, nil)
            end
            -- implicit GROUP BY order (MariaDB sorts groups when there is no ORDER BY)
            if gkey and not cmp and ngroups > 1 then
                tsort(order, function(a, b)
                    for i = 1, ng do
                        local x, y = a.gk[i], b.gk[i]
                        if x ~= y then
                            if x == nil then return true end
                            if y == nil then return false end
                            return x < y
                        end
                    end
                    return a.seq < b.seq
                end)
            end
            local rows, n = {}, 0
            local seen = distinct and {} or nil
            for gi = 1, ngroups do
                local g = order[gi]
                local fin = {}
                for s = 1, naggs do
                    local a = aggs[s]
                    local v = g.acc[s]
                    if a.first then
                        if not v then
                            v = nil
                        else
                            v = AsText(v[1], a.aty)
                            if #v > 1048576 then v = ssub(v, 1, 1048576) end
                        end
                    elseif a.name == 'GROUP_CONCAT' then
                        if #v == 0 then
                            v = nil
                        else
                            if a.cmp and #v > 1 then tsort(v, a.cmp) end
                            local parts = {}
                            for j = 1, #v do parts[j] = AsText(v[j][1], a.aty) end
                            v = concat(parts, a.sep)
                            if #v > 1048576 then v = ssub(v, 1, 1048576) end
                        end
                    elseif a.name == 'SUM' and v ~= nil and a.rty.t == 'dbl' then
                        v = v + 0.0
                    end
                    fin[s] = v
                end
                g.rep.aggs = fin
                n = project(g.rep, rows, n, seen)
            end
            return finishRows(rows, n)
        end
    end
    plan.cols, plan.types = names, itemTypes
    plan.correlated = sc.correlated or false
    plan.outerMax = sc.outerMax or 0
    return plan
end

local function CompileUnion(ast, parentSc, C)
    local parts = {}
    for i, p in ipairs(ast.parts) do parts[i] = CompileSelect(p, parentSc, C) end
    local nc = #parts[1].cols
    for i = 2, #parts do
        if #parts[i].cols ~= nc then Fail('The used SELECT statements have a different number of columns') end
    end
    local types, convs = {}, {}
    for c = 1, nc do
        local t = T_NULL
        for i = 1, #parts do t = MergeT(t, parts[i].types[c]) end
        types[c] = t
    end
    for i = 1, #parts do
        convs[i] = {}
        for c = 1, nc do convs[i][c] = Converter(parts[i].types[c], types[c]) or false end
    end
    local correlated, outerMax = false, 0
    for i = 1, #parts do
        if parts[i].correlated then correlated = true end
        if (parts[i].outerMax or 0) > outerMax then outerMax = parts[i].outerMax end
    end
    return {
        cols = parts[1].cols,
        types = types,
        correlated = correlated,
        outerMax = outerMax,
        run = function(up, limitHint)
            local rows, n = {}, 0
            for i = 1, #parts do
                local r, m = parts[i].run(up, nil)
                local cv = convs[i]
                for j = 1, m do
                    local src = r[j]
                    local out = {}
                    for c = 1, nc do
                        local v = src[c]
                        if cv[c] and v ~= nil then v = cv[c](v) end
                        out[c] = v
                    end
                    n = n + 1
                    rows[n] = out
                    if limitHint and n >= limitHint then return rows, n end
                end
            end
            return rows, n
        end,
    }
end

CompileQuery = function(ast, parentSc, C)
    if ast.k == 'union' then return CompileUnion(ast, parentSc, C) end
    return CompileSelect(ast, parentSc, C)
end

-- ============================================================================
--                                      ═
-- ============================================================================
-- 6. Tables, rows and indexes
--    t.rows is kept in primary key order (row.k is the sort key); t.pkMap maps the normalised key to the
--    row; t.idx[ci] is a hash index (value -> rows in key order) on the first column of each KEY, of a
--    composite PRIMARY KEY and of each UNIQUE KEY. Rows are replaced, never edited, so a row object that
--    was saved to a document still holds exactly what was saved.

-- ============================================================================
--                                      ═
-- ============================================================================

local function ColTypeOf(col)
    local k = col.kind
    if k == 'int' then return (col.type == 'TINYINT' and col.width == 1) and T_BOOL1 or T_INT end
    if k == 'dec' then return T_DEC(col.scale) end
    if k == 'json' then return T_JSON end
    if k == 'dt' then return T_DT end
    if k == 'enum' then return col.enumTy end
    if k == 'date' then return T_DATE end
    return T_STR
end

local INT_RANGE = {
    TINYINT = { -128, 127, 255 },
    SMALLINT = { -32768, 32767, 65535 },
    MEDIUMINT = { -8388608, 8388607, 16777215 },
    INT = { -2147483648, 2147483647, 4294967295 },
    BIGINT = { MININT, MAXINT, MAXINT },
}

local function SortableInt(v) return spack('>j', v ~ MININT) end

local function PkKeyOf(t, row)
    local pk = t.pk
    if not pk then return nil end
    if #pk == 1 then
        local v = row[pk[1]]
        if t.pkNorm then return t.pkNorm(v) end
        return v
    end
    local parts = {}
    for i, ci in ipairs(pk) do
        local v = row[ci]
        local norm = t.normOf[ci]
        if norm then parts[i] = norm(v) else parts[i] = sformat('%d', v) end
    end
    return concat(parts, '\0')
end

local function SortKeyOf(t, row)
    local pk = t.pk
    if not pk then
        t.seq = t.seq + 1
        return t.seq
    end
    if #pk == 1 then
        local v = row[pk[1]]
        if t.pkNorm then return t.pkNorm(v) end
        return v
    end
    local parts = {}
    for i, ci in ipairs(pk) do
        local v = row[ci]
        local norm = t.normOf[ci]
        if norm then parts[i] = norm(v) .. '\0' else parts[i] = SortableInt(v) end
    end
    return concat(parts)
end

local function UniqueKeyOf(t, u, row)
    local parts = {}
    for i, ci in ipairs(u.cols) do
        local v = row[ci]
        if v == nil then return nil end
        local norm = t.normOf[ci]
        if norm then
            parts[i] = norm(v)
        elseif mtype(v) == 'integer' then
            parts[i] = sformat('%d', v)
        else
            parts[i] = tostring(v)
        end
    end
    return concat(parts, '\0')
end

-- binary search for the first position whose key is >= k
local function LowerBound(arr, k)
    local lo, hi = 1, #arr + 1
    while lo < hi do
        local mid = (lo + hi) // 2
        if arr[mid].k < k then lo = mid + 1 else hi = mid end
    end
    return lo
end

local function SortedInsert(arr, row)
    local n = #arr
    if n == 0 or arr[n].k < row.k then arr[n + 1] = row; return end
    local p = LowerBound(arr, row.k)
    while arr[p] and arr[p].k == row.k do p = p + 1 end
    tinsert(arr, p, row)
end

local function SortedRemove(arr, row)
    local p = LowerBound(arr, row.k)
    while arr[p] and arr[p].k == row.k do
        if arr[p] == row then tremove(arr, p); return true end
        p = p + 1
    end
    for i = 1, #arr do
        if arr[i] == row then tremove(arr, i); return true end
    end
    return false
end

local function SortedReplace(arr, old, new)
    local p = LowerBound(arr, old.k)
    while arr[p] and arr[p].k == old.k do
        if arr[p] == old then arr[p] = new; return true end
        p = p + 1
    end
    return false
end

local function IdxAdd(t, row)
    for ci, ix in pairs(t.idx) do
        local v = row[ci]
        if v ~= nil then
            local key = ix.norm and ix.norm(v) or v
            local b = ix.map[key]
            if not b then b = {}; ix.map[key] = b end
            SortedInsert(b, row)
        end
    end
end

local function IdxRemove(t, row)
    for ci, ix in pairs(t.idx) do
        local v = row[ci]
        if v ~= nil then
            local key = ix.norm and ix.norm(v) or v
            local b = ix.map[key]
            if b then
                SortedRemove(b, row)
                if #b == 0 then ix.map[key] = nil end
            end
        end
    end
end

local function MapsAdd(t, row)
    if t.pk then t.pkMap[PkKeyOf(t, row)] = row end
    for _, u in ipairs(t.uniques) do
        local key = UniqueKeyOf(t, u, row)
        if key then u.map[key] = row end
    end
    IdxAdd(t, row)
end

local function MapsRemove(t, row)
    if t.pk then
        local key = PkKeyOf(t, row)
        if t.pkMap[key] == row then t.pkMap[key] = nil end
    end
    for _, u in ipairs(t.uniques) do
        local key = UniqueKeyOf(t, u, row)
        if key and u.map[key] == row then u.map[key] = nil end
    end
    IdxRemove(t, row)
end

local function RebuildMaps(t)
    t.pkMap = {}
    for _, u in ipairs(t.uniques) do u.map = {} end
    for _, ix in pairs(t.idx) do ix.map = {} end
    for _, row in ipairs(t.rows) do
        if not row.dead then MapsAdd(t, row) end
    end
end

local DB = {}
DB.__index = DB

function DB:_log(op, t, a, b)
    local log = self.log
    if not log then return end
    local n = log.n + 1
    log.n = n
    log[n] = { op = op, t = t, a = a, b = b }
end

function DB:_rowInsert(t, row)
    row.k = SortKeyOf(t, row)
    SortedInsert(t.rows, row)
    MapsAdd(t, row)
    self:_log('ins', t, nil, row)
end

-- movedTo: the row that takes this one's place under another key (an UPDATE of the primary key)
function DB:_rowDelete(t, row, movedTo)
    row.dead = true
    MapsRemove(t, row)
    t.needCompact = true
    self.compactList[t] = true
    self:_log('del', t, row, movedTo)
end

-- Same primary key: swap the row object in place.
function DB:_rowReplace(t, old, new)
    new.k = old.k
    SortedReplace(t.rows, old, new)
    MapsRemove(t, old)
    MapsAdd(t, new)
    self:_log('rep', t, old, new)
end

function DB:_compact()
    for t in pairs(self.compactList) do
        if t.needCompact then
            local rows, out, n = t.rows, {}, 0
            for i = 1, #rows do
                local r = rows[i]
                if not r.dead then n = n + 1; out[n] = r end
            end
            t.rows = out
            t.needCompact = false
        end
    end
    self.compactList = {}
end

function DB:_rollback(log)
    for i = log.n, 1, -1 do
        local e = log[i]
        local op, t = e.op, e.t
        if op == 'ins' then
            e.b.dead = true
            MapsRemove(t, e.b)
            t.needCompact = true
            self.compactList[t] = true
        elseif op == 'del' then
            e.a.dead = nil
            MapsAdd(t, e.a)
            if not SortedReplace(t.rows, e.a, e.a) then SortedInsert(t.rows, e.a) end
        elseif op == 'rep' then
            SortedReplace(t.rows, e.b, e.a)
            MapsRemove(t, e.b)
            MapsAdd(t, e.a)
        elseif op == 'ai' then
            if not e.b then t.nextId = e.a end
        elseif op == 'create' then
            self.tables[t.name] = nil
            for j = #self.order, 1, -1 do
                if self.order[j] == t then tremove(self.order, j) end
            end
        elseif op == 'alter' then
            local ci, n = e.a, t.ncols
            for _, r in ipairs(t.rows) do
                for i = ci, n - 1 do r[i] = r[i + 1] end
                r[n] = nil
            end
            self:_removeColumn(t, ci)
        elseif op == 'keys' then
            t.keyDefs = e.a
            finishTable(t)
            RebuildMaps(t)
        end
    end
end

-- Build a table from a parsed CREATE TABLE (or a copy of another table's definition).
local function ColFromDef(cd)
    local col = {
        name = cd.name,
        lname = slower(cd.name),
        type = cd.type,
        width = cd.width,
        unsigned = cd.unsigned,
        len = cd.len,
        prec = cd.prec,
        scale = cd.scale,
        members = cd.members,
        notnull = cd.notnull == true,
        autoinc = cd.autoinc,
        onUpdateNow = cd.onupdate,
        defDef = cd.default,
    }
    local ty = cd.type
    if INT_RANGE[ty] then
        col.kind = 'int'
        local r = INT_RANGE[ty]
        if cd.unsigned then col.min, col.max = 0, r[3] else col.min, col.max = r[1], r[2] end
    elseif ty == 'DECIMAL' then
        col.kind = 'dec'
    elseif ty == 'VARCHAR' then
        col.kind = 'str'
    elseif ty == 'ENUM' then
        col.kind = 'enum'
        col.enumKey = {}
        local idx = { [''] = 0 }
        for i, m in ipairs(cd.members) do
            local key = CiKey(m)
            if col.enumKey[key] == nil then col.enumKey[key] = m end
            col.members[i] = m
            if idx[m] == nil then idx[m] = i end
        end
        -- text to MariaDB, except in number contexts and ORDER BY / GROUP BY order: the member's number
        col.enumTy = { t = 'str', enum = idx, members = col.members }
    elseif ty == 'JSON' then
        col.kind = 'json'
    elseif ty == 'DATETIME' then
        col.kind = 'dt'
    elseif ty == 'DATE' then
        col.kind = 'date'
    end
    col.ty = ColTypeOf(col)
    return col
end

local function ColTypeText(col)
    local ty = col.type
    if col.kind == 'int' then
        local s = ty
        if col.width then s = s .. '(' .. col.width .. ')' end
        if col.unsigned then s = s .. ' UNSIGNED' end
        return s
    elseif ty == 'VARCHAR' then
        return 'VARCHAR(' .. col.len .. ')'
    elseif ty == 'DECIMAL' then
        return 'DECIMAL(' .. col.prec .. ',' .. col.scale .. ')'
    elseif ty == 'ENUM' then
        local m = {}
        for i, s in ipairs(col.members) do m[i] = '\'' .. sgsub(s, '\'', '\'\'') .. '\'' end
        return 'ENUM(' .. concat(m, ',') .. ')'
    end
    return ty
end

local function SqlQuote(s) return '\'' .. sgsub(sgsub(s, '\\', '\\\\'), '\'', '\'\'') .. '\'' end

-- CREATE TABLE text for _tables.json (parsed back with the same parser on load).
local function RenderCreate(t)
    local parts = {}
    for _, col in ipairs(t.cols) do
        local s = col.name .. ' ' .. ColTypeText(col)
        if col.notnull then s = s .. ' NOT NULL' else s = s .. ' NULL' end
        local d = col.defDef
        if d then
            if d.k == 'now' then
                s = s .. ' DEFAULT CURRENT_TIMESTAMP'
            elseif d.k == 'null' then
                s = s .. ' DEFAULT NULL'
            elseif d.k == 'num' then
                s = s .. ' DEFAULT ' .. d.text
            else
                s = s .. ' DEFAULT ' .. SqlQuote(d.v)
            end
        end
        if col.onUpdateNow then s = s .. ' ON UPDATE CURRENT_TIMESTAMP' end
        if col.autoinc then s = s .. ' AUTO_INCREMENT' end
        parts[#parts + 1] = s
    end
    for _, key in ipairs(t.keyDefs) do
        local cols = concat(key.cols, ', ')
        if key.kind == 'pk' then
            parts[#parts + 1] = 'PRIMARY KEY (' .. cols .. ')'
        elseif key.kind == 'unique' then
            parts[#parts + 1] = 'UNIQUE KEY ' .. (key.name and (key.name .. ' ') or '') .. '(' .. cols .. ')'
        else
            parts[#parts + 1] = 'KEY ' .. (key.name and (key.name .. ' ') or '') .. '(' .. cols .. ')'
        end
    end
    return 'CREATE TABLE ' .. t.name .. ' (' .. concat(parts, ', ') .. ')'
end
M.renderCreate = RenderCreate

-- The value a NOT NULL column without a default gets in the rows it is added to (ALTER TABLE ... ADD COLUMN);
-- nil for DATETIME / DATE (MariaDB's zero date, which the engine cannot hold).
local function ImplicitDefault(col)
    local k = col.kind
    if k == 'int' or k == 'dec' then return 0 end
    if k == 'dt' or k == 'date' then return nil end
    if k == 'enum' then return col.members[1] end
    return ''
end

local Coercer             -- forward
local STORE = { n = 0 }   -- section 7: warnings and notes of the statement being run, store helpers

local function FinishTable(t)
    t.colIndex, t.types, t.colNames, t.normOf = {}, {}, {}, {}
    t.jsonCis = nil
    for ci, col in ipairs(t.cols) do
        t.colIndex[col.lname] = ci
        t.types[ci] = col.ty
        t.colNames[ci] = col.name
        t.normOf[ci] = IndexNorm(col.ty)
    end
    t.ncols = #t.cols
    t.autoCol = nil
    for ci, col in ipairs(t.cols) do if col.autoinc then t.autoCol = ci end end
    t.pk, t.uniques, t.idx = nil, {}, {}
    local function colIdx(name)
        local ci = t.colIndex[slower(name)]
        if not ci then Fail(sformat('Key column \'%s\' doesn\'t exist in table', name)) end
        return ci
    end
    local function addIdx(ci)
        local col = t.cols[ci]
        if col.kind == 'dt' or col.kind == 'date' then return end
        if not t.idx[ci] then t.idx[ci] = { map = {}, norm = t.normOf[ci] } end
    end
    for _, key in ipairs(t.keyDefs) do
        local cis = {}
        for i, name in ipairs(key.cols) do cis[i] = colIdx(name) end
        if key.kind == 'pk' then
            if t.pk then Fail('Multiple primary key defined') end
            t.pk = cis
            for _, ci in ipairs(cis) do t.cols[ci].notnull = true end
            if #cis > 1 then addIdx(cis[1]) end
        elseif key.kind == 'unique' then
            t.uniques[#t.uniques + 1] = { cols = cis, name = key.name or t.cols[cis[1]].name, map = {} }
            addIdx(cis[1])
        else
            addIdx(cis[1])
        end
    end
    if t.autoCol and not (t.pk and t.pk[1] == t.autoCol) then
        local keyed = false
        for _, u in ipairs(t.uniques) do if u.cols[1] == t.autoCol then keyed = true end end
        if not keyed and not t.idx[t.autoCol] then
            Fail('Incorrect table definition; there can be only one auto column and it must be defined as a key')
        end
    end
    t.pkNorm = (t.pk and #t.pk == 1) and t.normOf[t.pk[1]] or nil
    t.pkIntRange = t.pk and #t.pk == 1 and t.cols[t.pk[1]].kind == 'int' or false
    for ci, col in ipairs(t.cols) do
        local d = col.defDef
        col.defaultNow, col.default = false, nil
        if d then
            if d.k == 'now' then
                if col.kind ~= 'dt' then Fail(sformat('Invalid default value for \'%s\'', col.name)) end
                col.defaultNow = true
            elseif d.k == 'null' then
                if col.notnull then Fail(sformat('Invalid default value for \'%s\'', col.name)) end
            else
                local lit = d.k == 'num' and d.text or d.v
                local lty = T_STR
                local v = lit
                if d.k == 'num' then
                    local dv, s = DecFromText(lit)
                    if dv and s > 0 then
                        v, lty = dv, T_DEC(s)
                    elseif mtointeger(tonumber(lit)) then
                        v, lty = mtointeger(tonumber(lit)), T_INT
                    else
                        v, lty = tonumber(lit) + 0.0, T_DBL
                    end
                end
                local ok, res = pcall(Coercer(t, col, lty), v, 1, false)
                if not ok then Fail(sformat('Invalid default value for \'%s\'', col.name)) end
                col.default = res
            end
        end
        local _ = ci
    end
    return t
end

local function NewTable(name, colDefs, keyDefs)
    local t = { name = name, cols = {}, keyDefs = {}, rows = {}, pkMap = {}, nextId = 1, seq = 0 }
    local seen = {}
    for _, cd in ipairs(colDefs) do
        local l = slower(cd.name)
        if seen[l] then Fail(sformat('Duplicate column name \'%s\'', cd.name)) end
        seen[l] = true
        local col = ColFromDef(cd)
        t.cols[#t.cols + 1] = col
        if cd.pk then t.keyDefs[#t.keyDefs + 1] = { kind = 'pk', cols = { cd.name } } end
        if cd.unique then t.keyDefs[#t.keyDefs + 1] = { kind = 'unique', name = cd.name, cols = { cd.name } } end
    end
    for _, k in ipairs(keyDefs or {}) do t.keyDefs[#t.keyDefs + 1] = { kind = k.kind, name = k.name, cols = k.cols } end
    return FinishTable(t)
end

-- ============================================================================
--                                      ═
-- ============================================================================
-- 7. Storing values (MariaDB's Field::store under STRICT_TRANS_TABLES, the server default)
--    A value that has to change to fit its column is an error, or with IGNORE a warning and the changed value
--    (the number that starts a text, 0, the text cut to the column's length, the largest value of the column,
--    the ENUM's empty value). A few changes are only notes, never an error: trailing spaces left out, decimals
--    rounded away, the time of a DATETIME stored in a DATE, fraction digits past the sixth. STORE.n counts the
--    warnings and notes of the statement being run (its warningStatus). MariaDB's zero dates (0000-00-00,
--    a zero month or day, which IGNORE stores for a bad date) are refused as unsupported.

-- ============================================================================
--                                      ═
-- ============================================================================

do
    local function ColRef(t, col) return sformat('`%s`.`%s`.`%s`', DBNAME, t.name, col.name) end
    -- a value in an error message: MariaDB (ErrConvString) shows 128 bytes, a longer one as 125 bytes of whole
    -- characters and '...'
    local function ErrText(v)
        if #v <= 128 then return v end
        local cut = 125
        while cut > 0 and (sbyte(v, cut + 1) or 0) >= 128 and (sbyte(v, cut + 1) or 0) < 192 do cut = cut - 1 end
        return ssub(v, 1, cut) .. '...'
    end
    local function Note() STORE.n = STORE.n + 1 end
    local function WarnOr(ign, msg)
        if not ign then Fail(msg) end
        STORE.n = STORE.n + 1
    end
    -- A zero date is refused when the row is written (STORE.refuse), not when it is made: a row that a CHECK or a
    -- duplicate key leaves out never needed one.
    local function ZeroDate(text)
        if not STORE.zero then STORE.zero = text end
        return 0
    end
    STORE.refuse = function()
        local z = STORE.zero
        if z then
            STORE.zero = nil
            Unsupported(
                sformat('storing \'%s\': a zero date, a date with a zero month or day, or a year before 1000', z))
        end
    end

    -- The value a NOT NULL column gets for NULL with IGNORE (MariaDB's Field::reset: 0, '', the ENUM's empty value).
    STORE.reset = function(col)
        local k = col.kind
        if k == 'int' or k == 'dec' then return 0 end
        if k == 'dt' or k == 'date' then return ZeroDate('0000-00-00') end
        return ''
    end

    -- A DATETIME / DATE as the number MariaDB makes of it (YYYYMMDDhhmmss, YYYYMMDD).
    local function TimeNumber(v, vt)
        local d = os.date('*t', v)
        local n = d.year * 10000 + d.month * 100 + d.day
        if vt == 'date' then return n end
        return n * 1000000 + d.hour * 10000 + d.min * 100 + d.sec
    end

    -- ---- NUMBERS IN TEXT, THE WAY A COLUMN STORES THEM ---------------------
    -- MariaDB reads the number at the start of a text (my_strntoull10rnd, str2my_decimal): spaces, a sign, digits
    -- with one dot, and an exponent when digits follow the e. numScan -> digits (the dot left out, nil when there are
    -- none), the power of ten they are scaled by, negative?, the position after the number.
    local function NumScan(s)
        local i = sfind(s, '[^ \t\n\v\f\r]')
        if not i then return nil, 0, false, #s + 1 end
        local c = sbyte(s, i)
        local neg = c == 45
        if neg or c == 43 then i = i + 1 end
        local ip = smatch(s, '^%d*', i)
        local j = i + #ip
        local fp = ''
        if sbyte(s, j) == 46 then
            fp = smatch(s, '^%d*', j + 1)
            j = j + 1 + #fp
        end
        if ip == '' and fp == '' then return nil, 0, neg, i end
        local shift = -#fp
        local ex = smatch(s, '^[eE]([-+]?%d+)', j)
        if ex then
            j = j + 1 + #ex
            local e = tonumber(ex)
            if e > 9999 then e = 9999 elseif e < -9999 then e = -9999 end
            shift = shift + e
        end
        return ip .. fp, shift, neg, j
    end

    -- digits * 10^shift rounded half up to a whole number (nil when it does not fit a 64-bit integer).
    local function IntOfDigits(digits, shift)
        digits = sgsub(digits, '^0+', '')
        if digits == '' then return 0 end
        if shift >= 0 then
            if #digits + shift > 19 then return nil end
            return mtointeger(tonumber(digits .. srep('0', shift)))
        end
        local k = -shift
        if k > #digits then return 0 end
        local keep = ssub(digits, 1, #digits - k)
        local v = keep == '' and 0 or mtointeger(tonumber(keep))
        if not v then return nil end
        if sbyte(digits, #digits - k + 1) >= 53 then v = v + 1 end
        return v
    end

    -- digits * 10^shift as a decimal with s decimals (scaled, rounded half up): value (nil when it needs more than
    -- 18 digits) and whether non-zero digits were rounded away.
    local function DecOfDigits(digits, shift, s)
        digits = sgsub(digits, '^0+', '')
        if digits == '' then return 0, false end
        local sh = shift + s
        if sh >= 0 then
            if #digits + sh > 18 then return nil, false end
            return mtointeger(tonumber(digits .. srep('0', sh))), false
        end
        local k = -sh
        if k > #digits then return 0, true end
        local keep, dropped = ssub(digits, 1, #digits - k), ssub(digits, #digits - k + 1)
        if #keep > 18 then return nil, true end
        local v = keep == '' and 0 or mtointeger(tonumber(keep))
        if sbyte(dropped, 1) >= 53 then v = v + 1 end
        return v, sfind(dropped, '[1-9]') ~= nil
    end

    -- the rest of a text after its number: nothing, only spaces (a note) or more (Data truncated)
    local function Tail(s, stop, ign, rn, name)
        if stop > #s then return end
        if sfind(s, '^[ \t\n\v\f\r]*$', stop) then Note(); return end
        WarnOr(ign, sformat('Data truncated for column \'%s\' at row %d', name, rn))
    end

    Coercer = function(t, col, ty)
        local kind, name = col.kind, col.name
        local vt = ty.t
        if vt == 'null' then return function() return nil end end
        local function outOfRange(rn) return sformat('Out of range value for column \'%s\' at row %d', name, rn) end
        if kind == 'int' then
            local lo, hi = col.min, col.max
            local function range(x, rn, ign)
                if x < lo then WarnOr(ign, outOfRange(rn)); return lo, true end
                if x > hi then WarnOr(ign, outOfRange(rn)); return hi, true end
                return x, false
            end
            if vt == 'int' then
                return function(v, rn, ign) if v == nil then return nil end return (range(v, rn, ign)) end
            elseif vt == 'dec' then
                local s = ty.s
                return function(v, rn, ign)
                    if v == nil then return nil end
                    return (range(Rescale(v, s, 0), rn, ign))
                end
            elseif vt == 'dbl' then
                return function(v, rn, ign)
                    if v == nil then return nil end
                    local r = v == v and RoundHalfEven(v) or 0
                    if r < lo then WarnOr(ign, outOfRange(rn)); return lo end
                    if r > hi then WarnOr(ign, outOfRange(rn)); return hi end
                    return mtointeger(r)
                end
            elseif vt == 'dt' or vt == 'date' then
                return function(v, rn, ign)
                    if v == nil then return nil end
                    return (range(TimeNumber(v, vt), rn, ign))
                end
            end
            return function(v, rn, ign)
                if v == nil then return nil end
                local digits, shift, neg, stop = NumScan(v)
                local x = 0
                if digits then
                    x = IntOfDigits(digits, shift)
                    if not x then x = neg and MININT or MAXINT elseif neg then x = -x end
                end
                local y, clamped = range(x, rn, ign)
                if clamped then return y end
                if not digits then
                    WarnOr(ign, sformat('Incorrect integer value: \'%s\' for column %s at row %d', ErrText(v),
                        ColRef(t, col), rn))
                    return 0
                end
                Tail(v, stop, ign, rn, name)
                return y
            end
        elseif kind == 'dec' then
            local s, prec = col.scale, col.prec
            local limit, whole = POW10[prec], POW10[prec - s]
            -- x: the scaled value (nil: too large for any column), lost: digits rounded away
            local function store(x, lost, neg, rn, ign)
                if x == nil or x >= limit or x <= -limit then
                    WarnOr(ign, outOfRange(rn))
                    return neg and -(limit - 1) or (limit - 1)
                end
                if lost then Note() end
                return x
            end
            local function ofDigits(digits, shift, neg)
                local x, lost = DecOfDigits(digits, shift, s)
                if x and neg then x = -x end
                return x, lost
            end
            if vt == 'int' then
                return function(v, rn, ign)
                    if v == nil then return nil end
                    if v >= whole or v <= -whole then return store(nil, false, v < 0, rn, ign) end
                    return v * POW10[s]
                end
            elseif vt == 'dec' then
                local s0 = ty.s
                return function(v, rn, ign)
                    if v == nil then return nil end
                    local lost = false
                    if s0 > s then
                        lost = v % POW10[s0 - s] ~= 0
                    elseif s0 < s and (v >= POW10[mmin(18, prec - s + s0)] or v <= -POW10[mmin(18, prec - s + s0)]) then
                        return store(nil, false, v < 0, rn, ign)
                    end
                    return store(Rescale(v, s0, s), lost, v < 0, rn, ign)
                end
            elseif vt == 'dbl' then
                return function(v, rn, ign)
                    if v == nil then return nil end
                    if v ~= v or v == mhuge or v == -mhuge then return store(nil, false, v < 0, rn, ign) end
                    local digits, shift, neg = NumScan(FmtDouble(v))
                    local x, lost = ofDigits(digits, shift, neg)
                    return store(x, lost, neg, rn, ign)
                end
            elseif vt == 'dt' or vt == 'date' then
                return function(v, rn, ign)
                    if v == nil then return nil end
                    local n = TimeNumber(v, vt)
                    if n >= whole then return store(nil, false, false, rn, ign) end
                    return n * POW10[s]
                end
            end
            return function(v, rn, ign)
                if v == nil then return nil end
                local digits, shift, neg, stop = NumScan(v)
                if not digits then
                    WarnOr(ign, sformat('Incorrect decimal value: \'%s\' for column %s at row %d', ErrText(v),
                        ColRef(t, col), rn))
                    return 0
                end
                local x, lost = ofDigits(digits, shift, neg)
                Tail(v, stop, ign, rn, name)
                return store(x, lost, neg, rn, ign)
            end
        elseif kind == 'str' then
            local len = col.len
            return function(v, rn, ign)
                if v == nil then return nil end
                local s
                if vt == 'str' then
                    s = v
                elseif vt == 'dbl' then
                    local err
                    s, err = Gcvt(v, len)
                    if err then WarnOr(ign, sformat('Data too long for column \'%s\' at row %d', name, rn)) end
                else
                    s = ToStr(v, ty)
                end
                local n, bad = utf8len(s)
                if not n then
                    Fail(sformat('Incorrect string value: \'%s\' for column %s at row %d', BadBytes(s, bad),
                        ColRef(t, col), rn))
                end
                if n > len then
                    local cut = ssub(s, 1, utf8.offset(s, len + 1) - 1)
                    if sfind(s, '^ *$', #cut + 1) then
                        Note()
                    else
                        WarnOr(ign, sformat('Data too long for column \'%s\' at row %d', name, rn))
                    end
                    s = cut
                end
                return s
            end
        elseif kind == 'enum' then
            -- Field_enum::store: a member (case-insensitive, trailing spaces ignored), or the text of a member's
            -- number (1 = the first; 0 = the empty value); numbers are member numbers, a fraction cut off.
            local members, enumKey, count = col.members, col.enumKey, #col.members
            local function bad(rn, ign)
                WarnOr(ign, sformat('Data truncated for column \'%s\' at row %d', name, rn))
                return ''
            end
            local function byIndex(i, rn, ign)
                if i == nil or i < 1 or i > count then return bad(rn, ign) end
                return members[i]
            end
            -- an ENUM with the same members is copied as it is (MariaDB copies the member number), the empty value too
            local same = ty.members and #ty.members == count
            if same then
                for i = 1, count do if ty.members[i] ~= members[i] then same = false end end
            end
            if same then return function(v) return v end end
            if vt == 'int' then
                return function(v, rn, ign) if v == nil then return nil end return byIndex(v, rn, ign) end
            elseif vt == 'dec' then
                local p = POW10[ty.s]
                return function(v, rn, ign)
                    if v == nil then return nil end
                    local i = v >= 0 and v // p or -(-v // p)
                    return byIndex(i, rn, ign)
                end
            elseif vt == 'dbl' then
                return function(v, rn, ign)
                    if v == nil then return nil end
                    local i = v == v and mtointeger(v >= 0 and mfloor(v) or -mfloor(-v)) or nil
                    return byIndex(i, rn, ign)
                end
            end
            return function(v, rn, ign)
                if v == nil then return nil end
                local s = vt == 'str' and v or ToStr(v, ty)
                local m = enumKey[CiKey(s)]
                if m then return m end
                s = smatch(s, '^(.-) *$')
                if #s < 6 then
                    local sign, digits = smatch(s, '^[ \t\n\v\f\r]*([-+]?)(%d+)$')
                    if digits then
                        local i = tonumber(digits)
                        if sign == '-' and i ~= 0 then return bad(rn, ign) end
                        if i == 0 then return '' end
                        return byIndex(i, rn, ign)
                    end
                end
                return bad(rn, ign)
            end
        elseif kind == 'json' then
            -- the JSON_VALID check is the row's CHECK constraint (STORE.checkRow), after every column is stored
            return function(v, rn)
                if v == nil then return nil end
                local s = vt == 'str' and v or ToStr(v, ty)
                local n, bad = utf8len(s)
                if not n then
                    Fail(sformat('Incorrect string value: \'%s\' for column %s at row %d', BadBytes(s, bad),
                        ColRef(t, col), rn))
                end
                return s
            end
        elseif kind == 'dt' or kind == 'date' then
            local isDate = kind == 'date'
            local what = isDate and 'date' or 'datetime'
            return function(v, rn, ign)
                if v == nil then return nil end
                local x, status, dateOnly, hasTime
                if vt == 'dt' then
                    x, hasTime = v, isDate and v ~= Midnight(v)
                elseif vt == 'date' then
                    x = v
                elseif vt == 'str' then
                    x, status, dateOnly, hasTime = StrTime(v)
                elseif vt == 'int' then
                    x, status, dateOnly, hasTime = NumTime(v, false)
                elseif vt == 'dec' then
                    if v < 0 then
                        status = 'bad'
                    else
                        local p = POW10[ty.s]
                        x, status, dateOnly, hasTime = NumTime(v // p, v % p ~= 0)
                    end
                elseif vt == 'dbl' then
                    if v ~= v or v < 0 or v >= 1e19 then
                        status = 'bad'
                    else
                        local w = mfloor(v)
                        x, status, dateOnly, hasTime = NumTime(mtointeger(w), v > w)
                    end
                end
                if status == 'bad' then
                    WarnOr(ign, sformat('Incorrect %s value: \'%s\' for column %s at row %d', what,
                        ErrText(ToStr(v, ty)), ColRef(t, col), rn))
                    return ZeroDate('0000-00-00')
                end
                if status == 'zero' then return ZeroDate(ToStr(v, ty)) end
                if status == 'cut' then
                    WarnOr(ign, sformat('Incorrect %s value: \'%s\' for column %s at row %d', what,
                        ErrText(ToStr(v, ty)), ColRef(t, col), rn))
                elseif status == 'note' or (isDate and hasTime) then
                    Note()
                end
                if isDate then x = Midnight(x) end
                return x
            end
        end
        Unsupported('the column type of ' .. name)
    end

    -- The row's CHECK constraints: every JSON column holds valid JSON (MariaDB: CHECK (JSON_VALID(col))). Returns nil
    -- when the row passes, else the error text.
    STORE.checkRow = function(t, row, only)
        local jc = t.jsonCis
        if not jc then
            jc = {}
            for ci, col in ipairs(t.cols) do if col.kind == 'json' then jc[#jc + 1] = ci end end
            t.jsonCis = jc
        end
        for k = 1, #jc do
            local ci = jc[k]
            local v = row[ci]
            if v ~= nil and (not only or only[ci]) and not Jvalid(v) then
                return sformat('CONSTRAINT `%s.%s` failed for `%s`.`%s`', t.name, t.cols[ci].name, DBNAME, t.name)
            end
        end
        return nil
    end
end

-- ============================================================================
--                                8. STATEMENTS
-- ============================================================================

local WriteResult, CompileInsert, CompileUpdate, CompileDelete
do
    local function RowCopy(row, n)
        local r = {}
        for i = 1, n do r[i] = row[i] end
        return r
    end

    local function RowsDiffer(a, b, n)
        for i = 1, n do
            if not rawequal(a[i], b[i]) and a[i] ~= b[i] then return true end
        end
        return false
    end

    local function DupEntryText(t, row, cols)
        local parts = {}
        for i, ci in ipairs(cols) do
            local v = row[ci]
            parts[i] = v == nil and 'NULL' or ToStr(v, t.types[ci])
        end
        local s = concat(parts, '-')
        -- MariaDB shows 64 bytes of the key, a longer one as 61 bytes of whole characters and '...'
        if #s > 64 then
            local cut = 61
            while cut > 0 and (sbyte(s, cut + 1) or 0) >= 128 and (sbyte(s, cut + 1) or 0) < 192 do cut = cut - 1 end
            s = ssub(s, 1, cut) .. '...'
        end
        return s
    end
    M.dupEntryText = DupEntryText

    -- The row already holding row's primary or unique key (and the key's name), if any.
    local function FindDuplicate(t, row, except)
        if t.pk then
            local r = t.pkMap[PkKeyOf(t, row)]
            if r and r ~= except then return r, 'PRIMARY', t.pk end
        end
        for _, u in ipairs(t.uniques) do
            local key = UniqueKeyOf(t, u, row)
            if key then
                local r = u.map[key]
                if r and r ~= except then return r, u.name, u.cols end
            end
        end
        return nil
    end

    WriteResult = function(affected, changed, insertId, info, warnings)
        return {
            kind = 'write',
            affected = affected,
            changed = changed or 0,
            insertId = insertId or 0,
            info = info or '',
            warnings = warnings or 0,
        }
    end

    CompileInsert = function(ast, C)
        local db = C.db
        local t = db.tables[ast.table]
        if not t then Fail(sformat('Table \'%s.%s\' doesn\'t exist', DBNAME, ast.table)) end
        C.used[t] = true
        local targets = {}
        if ast.cols then
            local seen = {}
            for i, tk in ipairs(ast.cols) do
                local ci = t.colIndex[tk.l]
                if not ci then Fail(sformat('Unknown column \'%s\' in \'INSERT INTO\'', tk.v)) end
                if seen[ci] then Fail(sformat('Column \'%s\' specified twice', tk.v)) end
                seen[ci] = true
                targets[i] = ci
            end
        else
            for ci = 1, t.ncols do targets[ci] = ci end
        end
        local nt = #targets
        local rt = C.rt
        local source -- function() -> list of value arrays, count, types
        if ast.values then
            -- MariaDB lets VALUES read columns of the row being built (not used by Crimson-Police): a column of the
            -- table is refused as unsupported here, any other name is MariaDB's unknown column in 'VALUES'
            local esc = {
                C = C,
                srcs = {},
                clause = 'VALUES',
                aliasCols = setmetatable({}, {
                    __index = function(_, name)
                        if t.colIndex[name] then
                            return function() Unsupported('a column of the row in INSERT ... VALUES') end
                        end
                        return nil
                    end,
                }),
            }
            local rowsF, rowTypes = {}, {}
            for r, vals in ipairs(ast.values) do
                if #vals ~= nt then Fail(sformat('Column count doesn\'t match value count at row %d', r)) end
                local fns, tys = {}, {}
                for i, e in ipairs(vals) do
                    if HasAgg(e) then Fail('Invalid use of group function') end
                    fns[i], tys[i] = Cx(e, esc)
                end
                rowsF[r], rowTypes[r] = fns, tys
            end
            local coercers = {}
            for r = 1, #rowsF do
                coercers[r] = {}
                for i = 1, nt do coercers[r][i] = Coercer(t, t.cols[targets[i]], rowTypes[r][i]) end
            end
            source = function()
                local f = {}
                local out = {}
                for r = 1, #rowsF do
                    local fns = rowsF[r]
                    local vals = {}
                    for i = 1, nt do vals[i] = fns[i](f) end
                    out[r] = vals
                end
                return out, #rowsF, coercers, rowTypes
            end
        else
            local plan = CompileQuery(ast.select, nil, C)
            if #plan.cols ~= nt then Fail('Column count doesn\'t match value count at row 1') end
            local co = {}
            for i = 1, nt do co[i] = Coercer(t, t.cols[targets[i]], plan.types[i]) end
            source = function()
                local rows, n = plan.run(nil, nil)
                local cs = {}
                for r = 1, n do cs[r] = co end
                return rows, n, cs, nil
            end
        end
        -- ON DUPLICATE KEY UPDATE
        local odku
        if ast.odku then
            local sc = {
                C = C,
                srcs = {
                    {
                        kind = 'table',
                        t = t,
                        alias = ast.table,
                        cols = t.colIndex,
                        types = t.types,
                        names = t.colNames,
                    },
                },
                clause = 'SET',
            }
            sc.valuesCols = { index = t.colIndex, types = t.types }
            odku = {}
            for i, s in ipairs(ast.odku) do
                if s.q and s.q ~= ast.table then Fail(sformat('Unknown column \'%s.%s\' in \'SET\'', s.q, s.text)) end
                local ci = t.colIndex[s.name]
                if not ci then Fail(sformat('Unknown column \'%s\' in \'SET\'', s.text)) end
                local fn, ty = Cx(s.e, sc)
                odku[i] = { ci = ci, fn = fn, co = Coercer(t, t.cols[ci], ty) }
            end
        end
        local ignore = ast.ignore
        local cols = t.cols
        local fromSelect = ast.select ~= nil
        -- AUTO_INCREMENT the way MariaDB (handler::update_auto_increment) and InnoDB (innodb_autoinc_lock_mode = 1)
        -- hand ids out:
        --   * ids are reserved in intervals when the last one runs out. The server asks for one id per row of an
        --     INSERT ... VALUES at its first interval, otherwise 1, 2, 4, 8 ... (up to 65535); InnoDB reserves that many,
        --     or, in the middle of a statement, as many rows as it still expects (its count of rows goes down by one
        --     per row written). Its counter moves past the whole interval at once; unused ids are lost.
        --   * a row that is not inserted (IGNORE duplicate, ON DUPLICATE KEY UPDATE) gives the id back: the next id
        --     returns to what it was before that row.
        --   * an explicit id moves the next id past it, and InnoDB's counter too once the row is written (for INSERT
        --     ... SELECT also when it is a duplicate). Counters never move back, not even when the statement fails.
        --   * the insert id reported is the first generated id of an inserted row; without one, the id of the last row
        --     handled when a row was inserted or changed, else 0.
        local estimation = fromSelect and 0 or #(ast.values or EMPTY)
        -- columns left out that have no default: MariaDB checks them once for the statement, before any row
        local given, noDefault = {}, {}
        for i = 1, nt do given[targets[i]] = true end
        for ci, col in ipairs(cols) do
            if not given[ci] and col.notnull and not col.autoinc and not col.defaultNow and col.default == nil
                and col.kind ~= 'enum' then
                noDefault[#noDefault + 1] = col
            end
        end
        -- a CHECK constraint that fails skips the row with IGNORE, except in a one-row INSERT ... VALUES
        local checkIgnores = ignore and not (ast.values and #ast.values == 1)
        return function()
            STORE.n = 0
            if #noDefault > 0 then
                if not ignore then Fail(sformat('Field \'%s\' doesn\'t have a default value', noDefault[1].name)) end
                STORE.n = STORE.n + #noDefault
            end
            local now = rt.now
            local rows, n, coercersByRow = source()
            local affected, inserted, dups, records = 0, 0, 0, 0
            local copied, touched = 0, 0
            local firstId, lastAc
            local resNext, resLast, intervals = nil, nil, 0  -- the server's next id and the end of its interval
            local nAuto, lastValue = 0, 0                    -- InnoDB's expected rows and the end of its reservation
            local ac = t.autoCol
            for r = 1, n do
                local vals = rows[r]
                local co = coercersByRow[r]
                local row = {}
                STORE.zero = nil
                for i = 1, nt do
                    local ci = targets[i]
                    local col = cols[ci]
                    local v = co[i](vals[i], r, ignore)
                    if v == nil and col.notnull and not col.autoinc then
                        if not ignore then Fail(sformat('Column \'%s\' cannot be null', col.name)) end
                        STORE.n = STORE.n + 1
                        v = STORE.reset(col)
                    end
                    row[ci] = v
                end
                for ci = 1, t.ncols do
                    local col = cols[ci]
                    if not given[ci] and not col.autoinc then
                        if col.defaultNow then
                            row[ci] = now
                        elseif col.default ~= nil then
                            row[ci] = col.default
                        elseif col.notnull then
                            row[ci] = col.kind == 'enum' and col.members[1] or STORE.reset(col)
                        end
                    end
                end
                local bad = STORE.checkRow(t, row)
                if bad then
                    if not checkIgnores then Fail(bad) end
                    STORE.n = STORE.n + 1
                    goto nextRow
                end
                records = records + 1
                do
                    local generated = false
                    local prevNext = resNext
                    if ac then
                        local v = row[ac]
                        if v == nil or v == 0 then
                            if not resNext or resNext > resLast then
                                local nb
                                if intervals == 0 and estimation > 0 then
                                    nb = estimation
                                else
                                    nb = intervals < 16 and (1 << intervals) or 65535
                                    if nb > 65535 then nb = 65535 end
                                end
                                local first = resNext or 0
                                if nAuto == 0 then
                                    nAuto = nb
                                    if first < t.nextId then first = t.nextId end
                                elseif lastValue == 0 then
                                    if first < t.nextId then first = t.nextId end
                                end
                                lastValue = first + nAuto
                                resNext, resLast = first, first + nAuto - 1
                                intervals = intervals + 1
                                if lastValue > t.nextId then
                                    db:_log('ai', t, t.nextId, true)
                                    t.nextId = lastValue
                                end
                            end
                            local id = resNext
                            local col = cols[ac]
                            if id > col.max then
                                Fail(sformat('Out of range value for column \'%s\' at row %d', col.name, r))
                            end
                            resNext = id + 1
                            row[ac] = id
                            generated = true
                        elseif resNext and v >= resNext then
                            resNext = v + 1
                        end
                        if nAuto > 0 then nAuto = nAuto - 1 end
                    end
                    local existing = FindDuplicate(t, row)
                    if existing then
                        if odku then
                            rt.vals = row
                            local new = RowCopy(existing, t.ncols)
                            local f = { new }
                            local assigned = {}
                            STORE.zero = nil
                            for _, s in ipairs(odku) do
                                local col = cols[s.ci]
                                local v = s.co(s.fn(f), r, ignore)
                                if v == nil and col.notnull then
                                    if not ignore then Fail(sformat('Column \'%s\' cannot be null', col.name)) end
                                    STORE.n = STORE.n + 1
                                    v = STORE.reset(col)
                                end
                                new[s.ci] = v
                                assigned[s.ci] = true
                            end
                            touched = touched + 1
                            local skipped = false
                            if RowsDiffer(existing, new, t.ncols) then
                                for ci, col in ipairs(cols) do
                                    if col.onUpdateNow and not assigned[ci] then new[ci] = now end
                                end
                                local bad = STORE.checkRow(t, new, assigned)
                                local other, keyName, keyCols
                                if not bad then other, keyName, keyCols = FindDuplicate(t, new, existing) end
                                if bad or other then
                                    -- IGNORE: the row stays as it was (a warning); a duplicate still counts as handled, a
                                    -- failing CHECK not even that
                                    if not ignore then
                                        Fail(
                                            bad
                                                or sformat('Duplicate entry \'%s\' for key \'%s\'',
                                                    DupEntryText(t, new, keyCols), keyName)
                                        )
                                    end
                                    STORE.n = STORE.n + 1
                                    skipped = true
                                    if bad then touched = touched - 1 else affected = affected + 1 end
                                else
                                    STORE.refuse()
                                    if PkKeyOf(t, new) ~= PkKeyOf(t, existing) then
                                        db:_rowDelete(t, existing, new)
                                        db:_rowInsert(t, new)
                                    else
                                        db:_rowReplace(t, existing, new)
                                    end
                                    -- the AUTO_INCREMENT column set at or past the counter moves it on (as UPDATE does)
                                    if ac and assigned[ac] and new[ac] and new[ac] >= t.nextId and new[ac] < MAXINT then
                                        db:_log('ai', t, t.nextId, true)
                                        t.nextId = new[ac] + 1
                                    end
                                    affected = affected + 2
                                    copied = copied + 1
                                end
                            else
                                affected = affected + 1
                            end
                            if ac then
                                if not skipped then lastAc = new[ac] end
                                if assigned[ac] and not skipped then
                                    if resNext and new[ac] and new[ac] >= resNext then resNext = new[ac] + 1 end
                                else
                                    resNext = prevNext or (generated and row[ac]) or nil
                                end
                                if fromSelect and row[ac] and row[ac] >= t.nextId then
                                    db:_log('ai', t, t.nextId, true)
                                    t.nextId = row[ac] + 1
                                end
                            end
                            rt.vals = nil
                        elseif ignore then
                            dups = dups + 1
                            STORE.n = STORE.n + 1
                            if ac then
                                local id = row[ac]
                                lastAc = id
                                resNext = prevNext or (generated and id) or nil
                                if fromSelect and id and id >= t.nextId then
                                    db:_log('ai', t, t.nextId, true)
                                    t.nextId = id + 1
                                end
                            end
                        else
                            local _, keyName, keyCols = FindDuplicate(t, row)
                            Fail(
                                sformat('Duplicate entry \'%s\' for key \'%s\'', DupEntryText(t, row, keyCols), keyName))
                        end
                    else
                        if ac then
                            local id = row[ac]
                            if not generated and id >= lastValue and id >= t.nextId then
                                db:_log('ai', t, t.nextId, true)
                                t.nextId = id + 1
                            end
                            if generated and not firstId then firstId = id end
                            lastAc = id
                        end
                        STORE.refuse()
                        db:_rowInsert(t, row)
                        affected = affected + 1
                        inserted = inserted + 1
                        copied = copied + 1
                    end
                end
                ::nextRow::
            end
            local warnings = STORE.n
            local insertId = firstId
            if not insertId then insertId = (copied > 0 and lastAc) or 0 end
            local info = ''
            if n > 1 or fromSelect then
                -- Records: rows not skipped by a CHECK; Duplicates: rows not inserted (IGNORE), or duplicates handled by
                -- ON DUPLICATE KEY UPDATE
                info = sformat('Records: %d  Duplicates: %d  Warnings: %d', records,
                    ignore and (records - copied) or (dups + touched), warnings)
            end
            return WriteResult(affected, 0, insertId, info, warnings)
        end
    end

    -- ---- "Impossible WHERE" ------------------------------------------------
    -- MariaDB answers an UPDATE whose WHERE it proves false before reading any row without the "Rows matched" info
    -- (mysql_update: remove_eq_conds, then the range optimizer). It proves it when a condition is constant and not
    -- true, when a NOT NULL column (not a date) is tested IS NULL, and when the conditions on one column of any key
    -- (every column of every index, the key's first column or not) leave no value: col = / <> / < / <= / > / >= a
    -- constant, IN / NOT IN (constants), IS [NOT] NULL, and OR / AND of those on the same column. Columns of no key
    -- are not looked at. Returns a function run with the statement's parameters -> true when MariaDB would find the
    -- WHERE impossible, or nil.
    local ImpossibleWhere
    do
        local CONSTK = {
            num = true,
            str = true,
            null = true,
            param = true,
            neg = true,
            ['not'] = true,
            ['and'] = true,
            ['or'] = true,
            cmp = true,
            arith = true,
            isnull = true,
            inlist = true,
        }
        local function IsConst(node)
            if not CONSTK[node.k] then return false end
            for _, key in ipairs({ 'e', 'a', 'b' }) do
                local c = node[key]
                if type(c) == 'table' and c.k and not IsConst(c) then return false end
            end
            for _, key in ipairs({ 'list' }) do
                for _, c in ipairs(node[key] or EMPTY) do
                    if not IsConst(c) then return false end
                end
            end
            return true
        end

        -- sets of values of one column: { null = bool, ivs = { { lo, loInc, hi, hiInc } } } (nil bound = unbounded)
        local function SAll() return { null = true, ivs = { { nil, false, nil, false } } } end
        local function SEmpty() return { null = false, ivs = {} } end
        local function SNull() return { null = true, ivs = {} } end
        local function SNotNull() return { null = false, ivs = { { nil, false, nil, false } } } end
        local function LessLo(a, ai, b, bi) -- is lower bound a (inclusive ai) below b?
            if a == nil then return b ~= nil end
            if b == nil then return false end
            if a ~= b then return a < b end
            return ai and not bi
        end
        local function IvIntersect(x, y)
            local lo, loInc, hi, hiInc = x[1], x[2], x[3], x[4]
            if y[1] ~= nil and (lo == nil or y[1] > lo or (y[1] == lo and not y[2])) then lo, loInc = y[1], y[2] end
            if y[3] ~= nil and (hi == nil or y[3] < hi or (y[3] == hi and not y[4])) then hi, hiInc = y[3], y[4] end
            if lo ~= nil and hi ~= nil and (lo > hi or (lo == hi and not (loInc and hiInc))) then return nil end
            return { lo, loInc, hi, hiInc }
        end
        local function SIntersect(a, b)
            local out = { null = a.null and b.null, ivs = {} }
            for _, x in ipairs(a.ivs) do
                for _, y in ipairs(b.ivs) do
                    local z = IvIntersect(x, y)
                    if z then out.ivs[#out.ivs + 1] = z end
                end
            end
            return out
        end
        local function SUnion(a, b)
            local out = { null = a.null or b.null, ivs = {} }
            for _, x in ipairs(a.ivs) do out.ivs[#out.ivs + 1] = x end
            for _, y in ipairs(b.ivs) do out.ivs[#out.ivs + 1] = y end
            return out
        end
        local function SIsEmpty(a) return not a.null and #a.ivs == 0 end
        local function SCmp(op, v)
            if v == nil then return SEmpty() end
            if op == '=' then return { null = false, ivs = { { v, true, v, true } } } end
            if op == '<>' then return { null = false, ivs = { { nil, false, v, false }, { v, false, nil, false } } } end
            if op == '<' then return { null = false, ivs = { { nil, false, v, false } } } end
            if op == '<=' then return { null = false, ivs = { { nil, false, v, true } } } end
            if op == '>' then return { null = false, ivs = { { v, false, nil, false } } } end
            if op == '>=' then return { null = false, ivs = { { v, true, nil, false } } } end
            return SAll()
        end
        local _ = LessLo

        ImpossibleWhere = function(where, t, sc, alias)
            if not where then return nil end
            local keyCol = {}
            for _, key in ipairs(t.keyDefs) do
                for _, name in ipairs(key.cols) do
                    local ci = t.colIndex[slower(name)]
                    if ci then keyCol[ci] = true end
                end
            end
            local function colOf(node)
                if node.k ~= 'col' or (node.q and node.q ~= alias) then return nil end
                return t.colIndex[node.name]
            end
            -- value normaliser for a column and a constant's type, or nil when the range analysis is skipped
            local function normFor(ci, cty)
                local ty = t.types[ci]
                if ty.t == 'int' and cty.t == 'int' then return function(v) return v end end
                if ty.t == 'int' and cty.t == 'str' then
                    -- a text that is a plain whole number is that number; any other text is left to the rows
                    return function(v)
                        local d = smatch(v, '^%s*([-+]?%d+)%s*$')
                        return d and mtointeger(tonumber(d)) or false
                    end
                end
                if ty.t == 'str' and not ty.bin and cty.t == 'str' then return function(v) return CiOrderKey(v) end end
                if (ty.t == 'dt' or ty.t == 'date') and (cty.t == 'dt' or cty.t == 'date') then
                    return function(v) return v end
                end
                if ty.t == 'dt' and cty.t == 'str' then return function(v) return ParseDT(v) or false end end
                return nil
            end
            local FLIP = {
                ['<'] = '>',
                ['>'] = '<',
                ['<='] = '>=',
                ['>='] = '<=',
                ['='] = '=',
                ['<>'] = '<>',
                ['!='] = '<>',
            }
            -- node -> ci, function() -> set ; or nil
            local range
            range = function(node)
                local k = node.k
                if k == 'cmp' then
                    local op = node.op == '!=' and '<>' or node.op
                    local ci, other = colOf(node.a), node.b
                    if not ci then ci, other, op = colOf(node.b), node.a, FLIP[op] end
                    if not ci or not keyCol[ci] or not op or not IsConst(other) then return nil end
                    local fn, ty = Cx(other, sc)
                    local norm = ty.t == 'null'
                            and function() return nil end
                        or normFor(ci, ty)
                    if not norm then return nil end
                    return ci,
                        function()
                            local v = fn({})
                            if v == nil then return SEmpty() end
                            v = norm(v)
                            if v == false then return SAll() end
                            return SCmp(op, v)
                        end
                elseif k == 'inlist' then
                    local ci = colOf(node.e)
                    if not ci or not keyCol[ci] then return nil end
                    local items = {}
                    for i, it in ipairs(node.list) do
                        if not IsConst(it) then return nil end
                        local fn, ty = Cx(it, sc)
                        local norm = ty.t == 'null'
                                and function() return nil end
                            or normFor(ci, ty)
                        if not norm then return nil end
                        items[i] = { fn = fn, norm = norm }
                    end
                    local neg = node.neg
                    return ci,
                        function()
                            local set = SEmpty()
                            local vals, hasNull = {}, false
                            for _, it in ipairs(items) do
                                local v = it.fn({})
                                if v == nil then
                                    hasNull = true
                                else
                                    v = it.norm(v)
                                    if v == false then return SAll() end
                                    vals[#vals + 1] = v
                                end
                            end
                            if not neg then
                                for _, v in ipairs(vals) do set = SUnion(set, SCmp('=', v)) end
                                return set
                            end
                            if hasNull then return SAll() end
                            set = SNotNull()
                            for _, v in ipairs(vals) do set = SIntersect(set, SCmp('<>', v)) end
                            return set
                        end
                elseif k == 'isnull' then
                    local ci = colOf(node.e)
                    if not ci or not keyCol[ci] then return nil end
                    if node.neg then return ci, SNotNull end
                    return ci, SNull
                elseif k == 'or' or k == 'and' then
                    local ci0, fns = nil, {}
                    for i, c in ipairs(node.list) do
                        local ci, fn = range(c)
                        if not ci or (ci0 and ci ~= ci0) then return nil end
                        ci0, fns[i] = ci, fn
                    end
                    local isOr = k == 'or'
                    return ci0,
                        function()
                            local set = fns[1]()
                            for i = 2, #fns do
                                if isOr then set = SUnion(set, fns[i]()) else set = SIntersect(set, fns[i]()) end
                            end
                            return set
                        end
                end
                return nil
            end
            local consts, nullTests, ranges = {}, false, {}
            local any = false
            for _, c in ipairs(FlattenAnd(where, {})) do
                if IsConst(c) then
                    local fn, ty = Cx(c, sc)
                    consts[#consts + 1] = PredOf(fn, ty)
                    any = true
                elseif c.k == 'isnull' and not c.neg then
                    local ci = colOf(c.e)
                    local col = ci and t.cols[ci]
                    if col and col.notnull and col.kind ~= 'dt' and col.kind ~= 'date' then
                        nullTests = true
                        any = true
                    end
                end
                local ci, fn = range(c)
                if ci then
                    ranges[ci] = ranges[ci] or {}
                    ranges[ci][#ranges[ci] + 1] = fn
                    any = true
                end
            end
            if not any then return nil end
            return function()
                if nullTests then return true end
                for _, p in ipairs(consts) do
                    if not p({}) then return true end
                end
                for _, list in pairs(ranges) do
                    local set = SAll()
                    for _, fn in ipairs(list) do
                        set = SIntersect(set, fn())
                        if SIsEmpty(set) then return true end
                    end
                end
                return false
            end
        end
    end

    CompileUpdate = function(ast, C)
        local db = C.db
        local t = db.tables[ast.table]
        if not t then Fail(sformat('Table \'%s.%s\' doesn\'t exist', DBNAME, ast.table)) end
        C.used[t] = true
        local alias = ast.alias or ast.table
        local sc = { C = C, srcs = {}, clause = 'SELECT' }
        local scan, consts = PlanSources(sc, { { src = { k = 'table', name = ast.table, alias = alias } } }, ast.where,
            C)
        sc.clause = 'SET'
        local sets = {}
        for i, s in ipairs(ast.sets) do
            if s.q and s.q ~= alias then Fail(sformat('Unknown column \'%s.%s\' in \'SET\'', s.q, s.text)) end
            local ci = t.colIndex[s.name]
            if not ci then Fail(sformat('Unknown column \'%s\' in \'SET\'', s.text)) end
            if HasAgg(s.e) then Fail('Invalid use of group function') end
            local fn, ty = Cx(s.e, sc)
            sets[i] = { ci = ci, fn = fn, co = Coercer(t, t.cols[ci], ty) }
        end
        local ignore = ast.ignore
        local cols = t.cols
        local rt = C.rt
        sc.clause = 'WHERE'
        local impossible = ImpossibleWhere(ast.where, t, sc, alias)
        sc.clause = 'SET'
        return function()
            STORE.n = 0
            if impossible and impossible() then return WriteResult(0, 0, 0, '') end
            local now = rt.now
            local list, n = {}, 0
            local f = {}
            local ok = true
            for i = 1, #consts do if not consts[i](f) then ok = false break end end
            if ok then
                scan(f, function(fr) n = n + 1; list[n] = fr[1]; return false end)
            end
            local matched, changed, seen = 0, 0, 0
            local g = {}
            for r = 1, n do
                local old = list[r]
                if not old.dead then
                    seen = seen + 1
                    matched = matched + 1
                    local new = RowCopy(old, t.ncols)
                    g[1] = new
                    local assigned = {}
                    STORE.zero = nil
                    for _, s in ipairs(sets) do
                        local col = cols[s.ci]
                        local v = s.co(s.fn(g), seen, ignore)
                        if v == nil and col.notnull then
                            if not ignore then Fail(sformat('Column \'%s\' cannot be null', col.name)) end
                            STORE.n = STORE.n + 1
                            v = STORE.reset(col)
                        end
                        new[s.ci] = v
                        assigned[s.ci] = true
                    end
                    if RowsDiffer(old, new, t.ncols) then
                        for ci, col in ipairs(cols) do
                            if col.onUpdateNow and not assigned[ci] then new[ci] = now end
                        end
                        -- a failing CHECK: an error, with IGNORE a warning and the row is left out (not even matched)
                        local bad = STORE.checkRow(t, new, assigned)
                        local other, keyName, keyCols
                        if not bad then other, keyName, keyCols = FindDuplicate(t, new, old) end
                        if bad then
                            if not ignore then Fail(bad) end
                            STORE.n = STORE.n + 1
                            matched = matched - 1
                        elseif other then
                            if not ignore then
                                Fail(sformat('Duplicate entry \'%s\' for key \'%s\'', DupEntryText(t, new, keyCols),
                                    keyName))
                            end
                        else
                            STORE.refuse()
                            if t.pk and PkKeyOf(t, new) ~= PkKeyOf(t, old) then
                                db:_rowDelete(t, old, new)
                                db:_rowInsert(t, new)
                            else
                                db:_rowReplace(t, old, new)
                            end
                            -- InnoDB (MariaDB 10.2.4+): an AUTO_INCREMENT column set at or past the counter moves it on
                            -- (and stays moved when a later row fails the statement)
                            local ac = t.autoCol
                            if ac and assigned[ac] and new[ac] and new[ac] >= t.nextId and new[ac] < MAXINT then
                                db:_log('ai', t, t.nextId, true)
                                t.nextId = new[ac] + 1
                            end
                            changed = changed + 1
                        end
                    end
                end
            end
            return WriteResult(matched, changed, 0,
                sformat('Rows matched: %d  Changed: %d  Warnings: %d', matched, changed, STORE.n), STORE.n)
        end
    end

    CompileDelete = function(ast, C)
        local db = C.db
        if not ast.multi then
            local t = db.tables[ast.table]
            if not t then Fail(sformat('Table \'%s.%s\' doesn\'t exist', DBNAME, ast.table)) end
            C.used[t] = true
            local sc = { C = C, srcs = {}, clause = 'SELECT' }
            local scan, consts = PlanSources(sc,
                { { src = { k = 'table', name = ast.table, alias = ast.alias or ast.table } } }, ast.where, C)
            return function()
                local list, n = {}, 0
                local f = {}
                for i = 1, #consts do if not consts[i](f) then return WriteResult(0, 0, 0, '') end end
                scan(f, function(fr) n = n + 1; list[n] = fr[1]; return false end)
                local count = 0
                for i = 1, n do
                    local r = list[i]
                    if not r.dead then db:_rowDelete(t, r); count = count + 1 end
                end
                return WriteResult(count, 0, 0, '')
            end
        end
        local sc = { C = C, srcs = {}, clause = 'SELECT' }
        local scan, consts, nsrc = PlanSources(sc, ast.from, ast.where, C)
        local targets = {}
        for _, a in ipairs(ast.targets) do
            local found
            for si = 1, nsrc do
                if sc.srcs[si].alias == a then found = si end
            end
            if not found then Fail(sformat('Unknown table \'%s\' in MULTI DELETE', a)) end
            if sc.srcs[found].kind ~= 'table' then
                Fail(sformat('The target table %s of the DELETE is not updatable', a))
            end
            targets[#targets + 1] = found
        end
        return function()
            local f = {}
            for i = 1, #consts do if not consts[i](f) then return WriteResult(0, 0, 0, '') end end
            local seen, lists = {}, {}
            for _, si in ipairs(targets) do lists[si] = {} end
            scan(f, function(fr)
                for _, si in ipairs(targets) do
                    local r = fr[si]
                    if r and not seen[r] then seen[r] = true; lists[si][#lists[si] + 1] = r end
                end
                return false
            end)
            local count = 0
            for _, si in ipairs(targets) do
                local t = sc.srcs[si].t
                for _, r in ipairs(lists[si]) do
                    if not r.dead then db:_rowDelete(t, r); count = count + 1 end
                end
            end
            return WriteResult(count, 0, 0, '')
        end
    end

    function DB:_removeColumn(t, ci)
        tremove(t.cols, ci)
        FinishTable(t)
        RebuildMaps(t)
    end

    function DB:_createTable(ast, noLog)
        local name = ast.table
        if self.tables[name] then
            if ast.ifnot then return WriteResult(0, 0, 0, '', 1) end
            Fail(sformat('Table \'%s\' already exists', name))
        end
        local t
        if ast.like then
            local src = self.tables[ast.like]
            if not src then Fail(sformat('Table \'%s.%s\' doesn\'t exist', DBNAME, ast.like)) end
            local defs = {}
            for i, col in ipairs(src.cols) do
                defs[i] = {
                    name = col.name,
                    type = col.type,
                    width = col.width,
                    unsigned = col.unsigned,
                    len = col.len,
                    prec = col.prec,
                    scale = col.scale,
                    members = col.members and { table.unpack(col.members) } or nil,
                    notnull = col.notnull,
                    autoinc = col.autoinc,
                    onupdate = col.onUpdateNow,
                    default = col.defDef,
                }
            end
            local keys = {}
            for i, k in ipairs(src.keyDefs) do
                keys[i] = { kind = k.kind, name = k.name, cols = { table.unpack(k.cols) } }
            end
            t = NewTable(name, defs, keys)
        else
            t = NewTable(name, ast.cols, ast.keys)
        end
        self.tables[name] = t
        self.order[#self.order + 1] = t
        if not noLog then self:_log('create', t) end
        return WriteResult(0, 0, 0, '')
    end

    -- ALTER TABLE ... ADD (columns, indexes) and CREATE INDEX. Every change of the statement or none (MariaDB
    -- rebuilds the table in one go); IF NOT EXISTS on something that exists is a note, as in MariaDB.
    function DB:_alter(ast)
        local t = self.tables[ast.table]
        if not t then Fail(sformat('Table \'%s.%s\' doesn\'t exist', DBNAME, ast.table)) end
        local notes = 0
        for _, spec in ipairs(ast.specs) do
            if spec.kind == 'col' then
                local cd = spec.col
                if t.colIndex[slower(cd.name)] then
                    if not spec.ifnot then Fail(sformat('Duplicate column name \'%s\'', cd.name)) end
                    notes = notes + 1
                else
                    if cd.pk or cd.unique or cd.autoinc then Unsupported('ADD COLUMN with a key') end
                    local pos = t.ncols + 1
                    if spec.first then
                        pos = 1
                    elseif spec.after then
                        local ci = t.colIndex[spec.after.l]
                        if not ci then Fail(sformat('Unknown column \'%s\' in \'%s\'', spec.after.v, t.name)) end
                        pos = ci + 1
                    end
                    local col = ColFromDef(cd)
                    local keep = t.cols
                    local cols = {}
                    for i = 1, pos - 1 do cols[i] = keep[i] end
                    cols[pos] = col
                    for i = pos, #keep do cols[i + 1] = keep[i] end
                    t.cols = cols
                    local ok, err = pcall(FinishTable, t)
                    if not ok then
                        t.cols = keep
                        FinishTable(t)
                        RebuildMaps(t)
                        error(err, 0)
                    end
                    local v
                    if col.defaultNow then
                        v = self.now or os.time()
                    elseif col.default ~= nil then
                        v = col.default
                    elseif col.notnull then
                        v = ImplicitDefault(col)
                        if v == nil and #t.rows > 0 then
                            -- MariaDB fills the rows with the zero date, which the engine cannot hold
                            t.cols = keep
                            FinishTable(t)
                            RebuildMaps(t)
                            Unsupported(sformat(
                                'storing \'%s\': a zero date, a date with a zero month or day, or a year before 1000',
                                col.kind == 'date' and '0000-00-00' or '0000-00-00 00:00:00'))
                        end
                    end
                    local n = t.ncols - 1
                    for _, r in ipairs(t.rows) do
                        for i = n, pos, -1 do r[i + 1] = r[i] end
                        r[pos] = v
                    end
                    RebuildMaps(t)
                    self:_log('alter', t, pos)
                end
            else
                local name = spec.name
                for _, cname in ipairs(spec.cols) do
                    if not t.colIndex[slower(cname)] then
                        Fail(sformat('Key column \'%s\' doesn\'t exist in table', cname))
                    end
                end
                local taken = { primary = true }
                for _, k in ipairs(t.keyDefs) do
                    if k.kind == 'pk' then
                        taken.primary = true
                    else
                        taken[slower(k.name or t.cols[t.colIndex[slower(k.cols[1])]].name)] = true
                    end
                end
                if name and taken[slower(name)] then
                    if not spec.ifnot then Fail(sformat('Duplicate key name \'%s\'', name)) end
                    notes = notes + 1
                else
                    if not name then
                        -- MariaDB names it after its first column: a, then a_2, a_3 ...
                        local base = t.cols[t.colIndex[slower(spec.cols[1])]].name
                        name = base
                        local i = 1
                        while taken[slower(name)] do i = i + 1; name = base .. '_' .. i end
                    end
                    local before = {}
                    for i, k in ipairs(t.keyDefs) do before[i] = k end
                    local cols = {}
                    for i, cname in ipairs(spec.cols) do cols[i] = t.cols[t.colIndex[slower(cname)]].name end
                    t.keyDefs[#t.keyDefs + 1] = { kind = spec.kind, name = name, cols = cols }
                    FinishTable(t)
                    if spec.kind == 'unique' then
                        local u = t.uniques[#t.uniques]
                        local seen = {}
                        for _, r in ipairs(t.rows) do
                            local key = UniqueKeyOf(t, u, r)
                            if key then
                                if seen[key] then
                                    local text = DupEntryText(t, r, u.cols)
                                    t.keyDefs = before
                                    FinishTable(t)
                                    RebuildMaps(t)
                                    Fail(sformat('Duplicate entry \'%s\' for key \'%s\'', text, name))
                                end
                                seen[key] = true
                            end
                        end
                    end
                    RebuildMaps(t)
                    self:_log('keys', t, before)
                end
            end
        end
        return WriteResult(0, 0, 0, sformat('Records: 0  Duplicates: 0  Warnings: %d', notes), notes)
    end
end

-- ============================================================================
--                                ENGINE OBJECT
-- ============================================================================

local PTYPE = { n = T_NULL, i = T_INT, f = T_DBL, s = T_STR, b = T_BOOLP }

local function BindParams(np, params, P)
    local sig = {}
    for i = 1, np do
        local v = params and params[i]
        local tv = type(v)
        if v == nil then
            P[i] = nil
            sig[i] = 'n'
        elseif tv == 'number' then
            local iv = mtointeger(v)
            if iv then
                P[i] = iv
                sig[i] = 'i'
            elseif v ~= v or v == mhuge or v == -mhuge then
                Fail('Incorrect parameter: not a finite number')
            else
                local dv, ds = DecFromText(ShortFloat(v))
                if dv and ds <= 18 then
                    P[i] = dv
                    sig[i] = 'd' .. ds
                else
                    P[i] = v
                    sig[i] = 'f'
                end
            end
        elseif tv == 'string' then
            P[i] = v
            sig[i] = 's'
        elseif tv == 'boolean' then
            P[i] = v and 1 or 0
            sig[i] = 'b'
        else
            Fail('a query parameter must be a string, number, boolean or nil in files mode (got a ' .. tv .. ')')
        end
    end
    return concat(sig, ',')
end

local function SigTypes(sig)
    local out = {}
    local i = 0
    for code in (sig .. ','):gmatch('([^,]*),') do
        i = i + 1
        if code ~= '' then
            if sbyte(code, 1) == 100 then
                out[i] = T_DEC(tonumber(ssub(code, 2)))
            else
                out[i] = PTYPE[code]
            end
        end
    end
    return out
end

function M.new(opts)
    opts = opts or {}
    local db = setmetatable({ tables = {}, order = {}, parsed = {}, nparsed = 0, compactList = {}, store = opts.store },
        DB)
    return db
end

function DB:parse(sql)
    local ast = self.parsed[sql]
    if ast then return ast end
    ast = Parse(sql)
    ast.plans = {}
    -- oxmysql's count of placeholders (parseArguments: /\?(?!\?)/g, every '?' not followed by another '?')
    local q = 0
    for pos in sgmatch(sql, '()%?') do
        if sbyte(sql, pos + 1) ~= 63 then q = q + 1 end
    end
    ast.qcount = q
    self.nparsed = self.nparsed + 1
    if self.nparsed > 2000 then self.parsed, self.nparsed = {}, 1 end
    self.parsed[sql] = ast
    return ast
end

-- Which store serves a statement: 'engine' (Crimson-Police tables) or 'foreign' (another resource's).
function DB:route(sql, isOwn)
    local ast = self:parse(sql)
    local r = ast.route
    if r then return r, ast end
    local own, foreign = 0, 0
    for _, name in ipairs(ast.tables) do
        if isOwn(name) then own = own + 1 else foreign = foreign + 1 end
    end
    if foreign == 0 then
        r = 'engine'
    elseif own > 0 then
        r = 'mixed'
    elseif ast.stmt ~= 'select' then
        r = 'foreign-write'
    else
        r = 'foreign'
    end
    ast.route = r
    return r, ast
end

function DB:_plan(ast, params)
    local P = {}
    local sig = BindParams(ast.np, params, P)
    local plan = ast.plans[sig]
    if not plan then
        local rt = { P = {}, gen = 0, now = 0 }
        local C = { db = self, rt = rt, ptypes = SigTypes(sig), used = {} }
        local stmt = ast.stmt
        if stmt == 'select' then
            local q = CompileQuery(ast, nil, C)
            plan = { kind = 'select', q = q }
        elseif stmt == 'insert' then
            plan = { kind = 'write', exec = CompileInsert(ast, C) }
        elseif stmt == 'update' then
            plan = { kind = 'write', exec = CompileUpdate(ast, C) }
        elseif stmt == 'delete' then
            plan = { kind = 'write', exec = CompileDelete(ast, C) }
        else
            plan = { kind = 'ddl' }
        end
        plan.rt = rt
        plan.used = C.used
        plan.epoch = self.epoch
        if stmt ~= 'ddl' then ast.plans[sig] = plan end
    end
    local rtP = plan.rt.P
    for i = 1, ast.np do rtP[i] = P[i] end
    return plan
end

-- Run one statement. Returns { kind = 'rows', cols, types, rows, n } or
-- { kind = 'write', affected, changed, insertId, info, warnings }.
-- db.slice = { wait = Citizen.Wait, ms = 4 } (set by CP.Storage on a server): a SELECT run from a thread gives
-- the server its turn (wait(0)) whenever it has run ms milliseconds, instead of holding the server thread for the
-- whole query (with the database, oxmysql's await yields the same way). Meanwhile every other statement waits for
-- it (DB:exec), so each statement still sees and leaves the tables whole.
local nowClock = (os.microtime and function() return os.microtime() / 1e6 end) or os.clock
function DB:_selectSliced(plan, slice)
    local SL = M.slicing
    local wait, budget = slice.wait, (slice.ms or 4) / 1000
    local function step()
        SL.n = 0
        if nowClock() - SL.t >= budget then
            SL.on = false
            wait(0)
            SL.on, SL.step, SL.n, SL.t = true, step, 0, nowClock()
        end
    end
    self.busy = true
    SL.on, SL.step, SL.n, SL.t = true, step, 0, nowClock()
    local ok, rows, n = pcall(plan.q.run, nil, nil)
    SL.on = false
    self.busy = false
    if not ok then error(rows, 0) end
    return rows, n
end

function DB:exec(sql, params)
    if self.broken then Fail(self.broken) end
    if type(sql) ~= 'string' then Fail('the query must be a string') end
    if self.busy then
        -- a sliced SELECT of another thread is between two turns: wait for it
        local wait = self.slice and self.slice.wait
        if not (wait and coroutine.isyieldable()) then
            Fail('the saves folder is answering another query: run this one from a thread (CreateThread)')
        end
        while self.busy do wait(0) end
    end
    local ast = self:parse(sql)
    local plan = self:_plan(ast, params)
    local rt = plan.rt
    rt.now = os.time()
    rt.gen = rt.gen + 1
    if plan.kind == 'select' then
        local slice = self.slice
        local rows, n
        if slice and slice.wait and (slice.ms or 4) > 0 and not M.slicing.on and coroutine.isyieldable() then
            rows, n = self:_selectSliced(plan, slice)
        else
            rows, n = plan.q.run(nil, nil)
        end
        return { kind = 'rows', cols = plan.q.cols, types = plan.q.types, rows = rows, n = n }
    end
    local log = { n = 0 }
    self.log = log
    local ok, res = pcall(function()
        if plan.kind == 'write' then return plan.exec() end
        if ast.k == 'create' then return self:_createTable(ast) end
        if ast.k == 'alter' then return self:_alter(ast) end
        Unsupported('this statement')
    end)
    self.log = nil
    if not ok then
        self:_rollback(log)
        self:_compact()
        -- AUTO_INCREMENT ids the failed statement took stay taken (InnoDB): save the counters
        if self.store then
            local kept = { n = 0 }
            for i = 1, log.n do
                if log[i].op == 'ai' and log[i].b then kept.n = kept.n + 1; kept[kept.n] = log[i] end
            end
            if kept.n > 0 and not pcall(self.store.commit, self.store, self, kept) then
                pcall(self.store.restore, self.store, self, kept)
            end
        end
        error(res, 0)
    end
    self:_compact()
    if ast.stmt == 'ddl' and log.n > 0 then
        -- a new or changed table: cached plans may point at the old definition
        for _, a in pairs(self.parsed) do a.plans = {} end
    end
    if log.n > 0 and self.store then
        local okS, errS = pcall(self.store.commit, self.store, self, log)
        if not okS then
            -- undone in memory, and the documents this save already changed are written back (Store:restore)
            self:_rollback(log)
            self:_compact()
            local okR, restored = pcall(self.store.restore, self.store, self, log)
            if ast.stmt == 'ddl' then for _, a in pairs(self.parsed) do a.plans = {} end end
            if okR and restored then
                Fail('Crimson-Police could not write to the saves folder, so the change was undone: ' .. tostring(errS))
            end
            Fail(
                'Crimson-Police could not write to the saves folder, so the change was undone; the saves folder may hold part of it until the next save that works: '
                    .. tostring(errS)
            )
        end
    end
    return res
end

-- Load tables and rows from the store (at start-up).
function DB:load()
    if self.store then self.store:load(self) end
    return self
end

-- Stop every statement with this message (a saves folder that could not be loaded).
function DB:fail(msg) self.broken = msg end

-- A table created without a statement (loading): definition from its CREATE TABLE text.
function DB:_defineTable(createSql)
    local ast = Parse(createSql)
    if ast.k ~= 'create' then Fail('not a CREATE TABLE statement: ' .. ssub(createSql, 1, 60)) end
    ast.ifnot = false
    self:_createTable(ast, true)
    return self.tables[ast.table]
end

-- Bulk-add loaded rows (already typed) to a table and rebuild its indexes. Returns the duplicates dropped.
function DB:_loadRows(t, rows)
    local n = #rows
    local sorted = true
    local prev
    for i = 1, n do
        local row = rows[i]
        local k = SortKeyOf(t, row)
        row.k = k
        if prev ~= nil and not (prev < k) then sorted = false end
        prev = k
    end
    if not sorted then tsort(rows, function(a, b) return a.k < b.k end) end
    local out, m, dup = {}, 0, 0
    local pkMap = {}
    local pk = t.pk
    for i = 1, n do
        local row = rows[i]
        if pk then
            local key = PkKeyOf(t, row)
            if pkMap[key] then
                dup = dup + 1
            else
                pkMap[key] = row
                m = m + 1
                out[m] = row
            end
        else
            m = m + 1
            out[m] = row
        end
    end
    t.rows = out
    t.pkMap = pkMap
    for _, u in ipairs(t.uniques) do u.map = {} end
    for _, ix in pairs(t.idx) do ix.map = {} end
    local uniques = t.uniques
    for ci, ix in pairs(t.idx) do
        local map, norm = ix.map, ix.norm
        for i = 1, m do
            local row = out[i]
            local v = row[ci]
            if v ~= nil then
                local key = norm and norm(v) or v
                local bucket = map[key]
                if not bucket then bucket = {}; map[key] = bucket end
                bucket[#bucket + 1] = row
            end
        end
    end
    if #uniques > 0 then
        for i = 1, m do
            local row = out[i]
            for _, u in ipairs(uniques) do
                local key = UniqueKeyOf(t, u, row)
                if key then u.map[key] = row end
            end
        end
    end
    if t.autoCol then
        local maxId, ac = 0, t.autoCol
        for i = 1, m do
            local v = out[i][ac]
            if v and v > maxId then maxId = v end
        end
        if t.nextId <= maxId then t.nextId = maxId + 1 end
    end
    return dup
end

-- Run fn(db) with the write-through paused (each statement still atomic in memory), then save every table
-- in one go: a bulk import writes each document once instead of once per statement. Not used by the modules.
function DB:bulk(fn)
    local store = self.store
    self.store = nil
    local ok, err = pcall(fn, self)
    self.store = store
    if store then store:rewrite(self) end
    if not ok then error(err, 0) end
end

function DB:tableNames()
    local out = {}
    for i, t in ipairs(self.order) do out[i] = t.name end
    return out
end

do
    -- ---- 9. OXMYSQL TYPING AND THE MySQL DROP-IN ---------------------------
    local function BIGINT(v)
        if v > 9007199254740991 or v < -9007199254740991 then return sformat('%d', v) end
        return v
    end

    local function OutConv(ty)
        if ty.bool1 then
            -- oxmysql: '0' -> false, '1' -> true, any other TINYINT(1) value stays a number
            return function(v)
                if v == 0 then return false elseif v == 1 then return true end
                return v
            end
        end
        if ty.t == 'dec' then local s = ty.s return function(v) return FmtDec(v, s) end end
        if ty.t == 'dt' or ty.t == 'date' then return function(v) return v * 1000 end end
        -- a DOUBLE reaches Lua as a JavaScript number: a whole one becomes a Lua integer on the way (FiveM's msgpack)
        if ty.t == 'dbl' then
            return function(v)
                local i = mtointeger(v)
                if i and i > -9007199254740992 and i < 9007199254740992 then return i end
                return v
            end
        end
        -- a BIGINT beyond JavaScript's exact integers comes as text (mysql2 supportBigNumbers)
        if ty.t == 'int' then return BIGINT end
        return nil
    end

    -- Engine rows -> what oxmysql hands to Lua (NULL columns are missing keys).
    function M.luaRows(res)
        local cols, types, rows = res.cols, res.types, res.rows
        local nc = #cols
        local conv = {}
        for c = 1, nc do conv[c] = OutConv(types[c]) or false end
        local out = {}
        for i = 1, res.n do
            local r, o = rows[i], {}
            for c = 1, nc do
                local v = r[c]
                if v ~= nil then
                    local cv = conv[c]
                    if cv then v = cv(v) end
                end
                o[cols[c]] = v
            end
            out[i] = o
        end
        return out
    end

    function M.writeTable(res)
        return {
            fieldCount = 0,
            affectedRows = res.affected,
            insertId = res.insertId,
            info = res.info,
            serverStatus = 2,
            warningStatus = res.warnings or 0,
            changedRows = res.changed,
        }
    end

    -- What each MySQL.<kind> returns for an engine result (oxmysql parseResponse).
    function M.result(kind, res)
        if kind == 'query' then
            if res.kind == 'rows' then return M.luaRows(res) end
            return M.writeTable(res)
        elseif kind == 'single' then
            if res.kind ~= 'rows' or res.n == 0 then return nil end
            return M.luaRows({ cols = res.cols, types = res.types, rows = { res.rows[1] }, n = 1 })[1]
        elseif kind == 'scalar' then
            if res.kind ~= 'rows' or res.n == 0 then return nil end
            local v = res.rows[1][1]
            if v == nil then return nil end
            local cv = OutConv(res.types[1])
            if cv then v = cv(v) end
            return v
        elseif kind == 'insert' then
            if res.kind ~= 'write' then return nil end
            return res.insertId
        elseif kind == 'update' then
            if res.kind ~= 'write' then return nil end
            return res.affected
        end
        return nil
    end

    local function ParamsJson(params, n)
        local out = {}
        for i = 1, n do
            local v = params and params[i]
            local t = type(v)
            if v == nil then
                out[i] = 'null'
            elseif t == 'number' then
                out[i] = mtointeger(v) and sformat('%d', mtointeger(v)) or ShortFloat(v)
            elseif t == 'boolean' then
                out[i] = v and 'true' or 'false'
            elseif t == 'string' then
                out[i] = JstrEncode(v)
            else
                out[i] = JstrEncode(tostring(v))
            end
        end
        return '[' .. concat(out, ',') .. ']'
    end

    -- oxmysql's error text: "<resource> was unable to execute a query!\nQuery: ...\n[params]\n<message>"
    function M.errorText(resource, sql, params, msg, np)
        local n = np or 0
        if params then
            for k in pairs(params) do if mtype(k) == 'integer' and k > n then n = k end end
        end
        return sformat('%s was unable to execute a query!\nQuery: %s\n%s\n%s', resource, sql, ParamsJson(params, n),
            tostring(msg))
    end

    local SHIM_KINDS = { 'query', 'single', 'scalar', 'insert', 'update' }

    -- opts: realMySQL (oxmysql's MySQL table, for other resources' tables), resource (name for error text),
    -- isOwnTable(name) (default: name starts with cp_), onForeignUnavailable(sql) (called once).
    function M.shim(db, opts)
        opts = opts or {}
        local resource = opts.resource or (GetCurrentResourceName and GetCurrentResourceName()) or 'Crimson-Police'
        local isOwn = opts.isOwnTable or function(name) return ssub(name, 1, 3) == 'cp_' end
        local warned = false
        local shim = {}

        local function realReady()
            local real = opts.realMySQL
            if type(real) ~= 'table' then return nil end
            if GetResourceState and GetResourceState('oxmysql') ~= 'started' then return nil end
            return real
        end

        local function run(kind, sql, params)
            if type(sql) ~= 'string' then
                error(sformat('First argument expected string, received \'%s\'', tostring(sql)), 3)
            end
            if params ~= nil and type(params) ~= 'table' then
                error(sformat('Second argument expected table or function, received \'%s\'', tostring(params)), 3)
            end
            local okR, route, ast = pcall(db.route, db, sql, isOwn)
            if not okR then error(M.errorText(resource, sql, params, route), 0) end
            if route == 'foreign' then
                local real = realReady()
                if not real then
                    if not warned then
                        warned = true
                        Warn(sformat(
                            'oxmysql is not running, so \'%s\' (another resource\'s table) cannot be read; the answer is empty until oxmysql starts',
                            ssub(sql, 1, 120)))
                        if opts.onForeignUnavailable then pcall(opts.onForeignUnavailable, sql) end
                    end
                    return nil
                end
                return real[kind].await(sql, params)
            elseif route == 'mixed' then
                error(M.errorText(
                    resource,
                    sql,
                    params,
                    'files mode cannot join Crimson-Police tables with another resource\'s tables'
                ), 0)
            elseif route == 'foreign-write' then
                error(M.errorText(resource, sql, params, 'Crimson-Police never writes to another resource\'s tables'),
                    0)
            end
            -- oxmysql refuses more parameters than placeholders, but only when the query has placeholders at all
            if params and ast.qcount > 0 and #params > ast.qcount then
                error(sformat(
                    '%s was unable to execute a query!\nQuery: %s\nExpected %d parameters, but received %d.',
                    resource,
                    sql,
                    ast.qcount,
                    #params
                ), 0)
            end
            local ok, res = pcall(db.exec, db, sql, params)
            if not ok then error(M.errorText(resource, sql, params, res, ast.np), 0) end
            return M.result(kind, res)
        end
        shim._run = run

        for _, kind in ipairs(SHIM_KINDS) do
            local method = { method = kind }
            method.await = function(sql, params)
                if type(params) == 'function' then params = nil end
                return run(kind, sql, params)
            end
            setmetatable(method, {
                __call = function(_, sql, params, cb)
                    if type(params) == 'function' then cb, params = params, nil end
                    local function go()
                        local ok, res = pcall(run, kind, sql, params)
                        if not ok then
                            print('^1' .. tostring(res) .. '^7')
                            return
                        end
                        if cb then cb(res) end
                    end
                    if Citizen and Citizen.CreateThreadNow then
                        Citizen.CreateThreadNow(go)
                    elseif CreateThread then
                        CreateThread(go)
                    else
                        go()
                    end
                end,
            })
            shim[kind] = method
        end

        shim.ready = setmetatable({
            await = function() return true end,
        }, {
            __call = function(_, cb)
                if type(cb) ~= 'function' then return end
                if Citizen and Citizen.CreateThreadNow then Citizen.CreateThreadNow(cb) else cb() end
            end,
        })

        return setmetatable(shim, {
            __index = function(_, key)
                error(
                    sformat('MySQL.%s is not available in files mode (Config.Database.enabled = false)', tostring(key)),
                    2)
            end,
        })
    end
end

do
    -- ---- 10. THE SAVES FOLDER ----------------------------------------------
    local DOC_ROWS = 500

    local FS = {}
    M.fs = FS -- tests replace these to simulate crashes and failing disks

    function FS.read(path)
        local f = io.open(path, 'rb')
        if not f then return nil end
        local s = f:read('a')
        f:close()
        return s
    end

    function FS.write(path, data)
        local f, err = io.open(path, 'wb')
        if not f then return nil, err end
        local ok, werr = f:write(data)
        if not ok then f:close(); return nil, werr end
        local okF, ferr = f:flush()
        if not okF then f:close(); return nil, ferr end
        local okC, cerr = f:close()
        if not okC then return nil, cerr end
        return true
    end

    function FS.exists(path)
        local f = io.open(path, 'rb')
        if f then f:close(); return true end
        return false
    end

    -- os.rename as it is. What its answer means is decided per saves folder (Store:_probeRename): FXServer's Linux
    -- build reports a rename that worked as failed and one that failed as done (its LocalDevice::RenameFile returns
    -- rename() != 0), Windows and plain Lua report it as it is.
    function FS.rename(a, b) return os.rename(a, b) end
    function FS.remove(path) return os.remove(path) end

    -- The names in a folder, or nil when this runtime cannot list one (FXServer: io.readdir, or its io.popen that
    -- only lists folders; plain Lua: ls / dir).
    function FS.list(dir)
        local h
        if io.readdir then h = io.readdir(dir) end
        if not h and io.popen then
            local windows = package and package.config and ssub(package.config, 1, 1) == '\\'
            local ok, p = pcall(
                io.popen,
                windows and ('dir /b /a "' .. sgsub(dir, '/', '\\') .. '" 2>nul')
                    or ('ls -A "' .. dir .. '" 2>/dev/null')
            )
            if ok then h = p end
        end
        if not h then return nil end
        local names = {}
        for name in h:lines() do names[#names + 1] = name end
        h:close()
        return names
    end

    local ReplaceFile, RecoverFile, InstallTmp
    do
        -- A rename of a to b (a exists) as it really went: true, or nil and the error.
        local function RenameFile(st, a, b)
            local ok, err = FS.rename(a, b)
            local mode = st and st.renames or 'check'
            if mode == 'normal' then
                if ok then return true end
                return nil, err
            elseif mode == 'inverted' then
                if ok then return nil, sformat('%s -> %s: the rename did not happen', a, b) end
                return true
            end
            if FS.exists(b) and not FS.exists(a) then return true end
            return nil, err or sformat('%s -> %s: the rename did not happen', a, b)
        end

        -- Put <path>.tmp (already written) in the place of path without ever leaving path half-written. Where a rename
        -- cannot replace a file (Windows): old -> .bak, tmp -> path, .bak removed; the store remembers that after the
        -- first time and skips the rename that cannot work.
        InstallTmp = function(st, path)
            local tmp, bak = path .. '.tmp', path .. '.bak'
            if not (st and st.noReplace) then
                if RenameFile(st, tmp, path) then return true end
            end
            local had = FS.exists(path)
            if had then
                if not RenameFile(st, path, bak) then
                    FS.remove(bak) -- a .bak left by an interrupted save
                    local okB, errB = RenameFile(st, path, bak)
                    if not okB then
                        FS.remove(tmp)
                        return nil, sformat('cannot rename %s: %s', path, tostring(errB))
                    end
                end
            end
            local okT, errT = RenameFile(st, tmp, path)
            if not okT then
                if had then RenameFile(st, bak, path) end
                FS.remove(tmp)
                return nil, sformat('cannot rename %s: %s', tmp, tostring(errT))
            end
            if had then
                FS.remove(bak)
                if st then st.noReplace = true end
            end
            return true
        end

        -- Replace a file without ever leaving it half-written.
        ReplaceFile = function(st, path, data)
            local tmp = path .. '.tmp'
            local ok, err = FS.write(tmp, data)
            if not ok then
                FS.remove(tmp)
                return nil, sformat('cannot write %s: %s', tmp, tostring(err))
            end
            return InstallTmp(st, path)
        end
        M.replaceFile = function(path, data) return ReplaceFile(nil, path, data) end

        -- Before reading a document: a leftover .tmp is dropped, a .bak without its document is restored.
        RecoverFile = function(st, path)
            local bak, tmp = path .. '.bak', path .. '.tmp'
            if FS.exists(bak) then
                if FS.exists(path) then FS.remove(bak) else RenameFile(st, bak, path) end
            end
            if FS.exists(tmp) then FS.remove(tmp) end
        end
    end

    local function Fnv1a(s)
        local h = 2166136261
        for i = 1, #s do
            h = ((h ~ sbyte(s, i)) * 16777619) & 0xFFFFFFFF
        end
        return h
    end

    local function Log2floor(n)
        local l = 0
        while (1 << (l + 1)) <= n do l = l + 1 end
        return l
    end

    -- Linear hashing: bucket (0-based) of hash h among n buckets.
    local function BucketOf(h, n)
        local L = Log2floor(n)
        local b = h % (1 << (L + 1))
        if b >= n then b = h % (1 << L) end
        return b
    end

    -- Digits of an integer as %d writes it.
    local function IntLen(v)
        local n = 0
        if v < 0 then n = 1; v = -v end
        if v < 100000 then
            if v < 10 then
                return n + 1
            elseif v < 100 then
                return n + 2
            elseif v < 1000 then
                return n + 3
            elseif v < 10000 then
                return n + 4
            end
            return n + 5
        end
        if v < 10000000000 then
            if v < 1000000 then
                return n + 6
            elseif v < 10000000 then
                return n + 7
            elseif v < 100000000 then
                return n + 8
            elseif v < 1000000000 then
                return n + 9
            end
            return n + 10
        end
        return n + #sformat('%d', v)
    end

    -- A DATE in a document is its calendar day, "YYYY-MM-DD" (MariaDB's DATE does not depend on a time zone: a saves
    -- folder moved to a server in another zone keeps its days). In memory it is the unix time of that day's local
    -- midnight, as everywhere in the engine.
    local DayOf
    do
        local DAYC, dayN = {}, 0
        DayOf = function(text)
            local v = DAYC[text]
            if v then return v end
            local y, mo, d = smatch(text, '^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
            if not y then return nil end
            y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
            if y < 1000 or mo < 1 or mo > 12 or d < 1 or d > 31 then return nil end
            v = os.time({ year = y, month = mo, day = d, hour = 0, min = 0, sec = 0 })
            dayN = dayN + 1
            if dayN > 20000 then DAYC, dayN = {}, 0 end
            DAYC[text] = v
            return v
        end
    end

    -- How a value is written in a document.
    local function EncodeValue(col, v)
        if v == nil then return 'null' end
        local k = col.kind
        if k == 'int' or k == 'dt' then return sformat('%d', v) end
        if k == 'date' then return '"' .. FmtDate(v) .. '"' end
        if k == 'dec' then return FmtDec(v, col.scale) end
        if k == 'json' then
            local b1, b2 = sbyte(v, 1), sbyte(v, -1)
            if ((b1 == 123 and b2 == 125) or (b1 == 91 and b2 == 93)) and not sfind(v, '[\r\n]')
                and JvalidStrict(v) then
                return v
            end
            return JstrEncode(v)
        end
        return JstrEncode(v)
    end

    local function EncodeRow(t, row)
        local parts, cols = {}, t.cols
        for ci = 1, t.ncols do parts[ci] = EncodeValue(cols[ci], row[ci]) end
        return '[' .. concat(parts, ',') .. ']'
    end

    local Store = {}
    Store.__index = Store

    -- dir: the saves folder. opts.docRows (default 500) is the most rows one document holds.
    function M.folderStore(dir, opts)
        opts = opts or {}
        dir = sgsub(dir, '[/\\]+$', '')
        return setmetatable({
            dir = dir,
            docRows = opts.docRows or DOC_ROWS,
            inline = opts.inline or { cp_schema_migrations = true },
            ts = {},
            loaded = false,
            layoutDirty = false,
            removals = {},
            stats = { writes = 0, bytes = 0, removes = 0 },
            gains = {},
            away = {},
            lnDocs = {},
            renames = nil,
            missing = {},
        }, Store)
    end

    function Store:path(name) return self.dir .. '/' .. name end

    function Store:docName(ts, d)
        if d == 0 then return ts.file .. '.json' end
        return ts.file .. '_' .. d .. '.json'
    end

    function Store:_state(t)
        local ts = self.ts[t.name]
        if ts then return ts end
        ts = {
            t = t,
            file = ssub(t.name, 1, 3) == 'cp_' and ssub(t.name, 4) or t.name,
            mode = 'single',
            n = 1,
            maxDoc = 0,
            docs = {},
            counts = {},
            onDisk = {},
            dirty = {},
            inline = self.inline[t.name] or false,
            savedNext = nil,
        }
        ts.range = t.pkIntRange
        self.ts[t.name] = ts
        return ts
    end

    function Store:_header(ts)
        local t = ts.t
        local names = {}
        for i, col in ipairs(t.cols) do names[i] = JstrEncode(col.name) end
        return '{"table":' .. JstrEncode(t.name) .. ',"columns":[' .. concat(names, ',') .. '],"rows":['
    end

    function Store:_hash(ts, row)
        local key = PkKeyOf(ts.t, row)
        if key == nil then return 0 end
        if type(key) == 'number' then key = sformat('%d', key) end
        return Fnv1a(key)
    end

    function Store:_docOf(ts, row)
        if ts.mode == 'single' then return 0 end
        if ts.mode == 'range' then
            local id = row[ts.t.pk[1]]
            local d = (id - 1) // self.docRows + 1
            if d < 1 then d = 1 end
            return d
        end
        return BucketOf(self:_hash(ts, row), ts.n) + 1
    end

    function Store:_add(ts, row)
        local d = self:_docOf(ts, row)
        row.d = d
        local set = ts.docs[d]
        if not set then set = {}; ts.docs[d] = set; ts.counts[d] = 0 end
        set[row] = true
        ts.counts[d] = ts.counts[d] + 1
        ts.dirty[d] = true
        if ts.mode == 'range' and d > ts.maxDoc then ts.maxDoc = d; self.layoutDirty = true end
    end

    function Store:_remove(ts, row)
        local d = row.d
        local set = d and ts.docs[d]
        if set and set[row] then
            set[row] = nil
            ts.counts[d] = ts.counts[d] - 1
            ts.dirty[d] = true
        end
    end

    -- Re-address every row of a table (a layout change): every document is written again.
    function Store:_reassign(ts)
        ts.docs, ts.counts = {}, {}
        for d in pairs(ts.onDisk) do ts.dirty[d] = true end
        for _, row in ipairs(ts.t.rows) do self:_add(ts, row) end
    end

    -- Document membership from the rows in memory, nothing marked for saving (after a failed save is undone).
    function Store:_rebuildDocs(ts)
        ts.docs, ts.counts = {}, {}
        for _, row in ipairs(ts.t.rows) do
            local d = self:_docOf(ts, row)
            row.d = d
            local set = ts.docs[d]
            if not set then set = {}; ts.docs[d] = set; ts.counts[d] = 0 end
            set[row] = true
            ts.counts[d] = ts.counts[d] + 1
        end
    end

    function Store._maxIdOf(t)
        local rows = t.rows
        local r = rows[#rows]
        if not r then return 0 end
        return r[t.autoCol] or 0
    end

    -- After a statement: grow the layout when a document passed docRows rows (one split per statement).
    function Store:_maybeSplit(ts)
        local t, limit = ts.t, self.docRows
        if ts.inline or not t.pk then return end
        if ts.mode == 'single' then
            if ts.range then
                local rows = t.rows
                local last = rows[#rows]
                if last and last[t.pk[1]] > limit then
                    ts.mode = 'range'
                    ts.maxDoc = 0
                    if ts.onDisk[0] then self.removals[#self.removals + 1] = { ts = ts, d = 0 } end
                    self:_reassign(ts)
                    ts.dirty[0] = nil
                    self.layoutDirty = true
                end
            elseif #t.rows > limit then
                ts.mode = 'hash'
                ts.n = 2
                if ts.onDisk[0] then self.removals[#self.removals + 1] = { ts = ts, d = 0 } end
                self:_reassign(ts)
                ts.dirty[0] = nil
                self.layoutDirty = true
            end
            return
        end
        if ts.mode == 'hash' then
            local n = ts.n
            local L = Log2floor(n)
            local s = n - (1 << L)
            local over = false
            for b = s, (1 << L) - 1 do
                if (ts.counts[b + 1] or 0) > limit then over = true; break end
            end
            if over then
                local newB = n -- bucket index n (document n + 1) takes half of bucket s
                ts.n = n + 1
                local set = ts.docs[s + 1] or {}
                local moving = {}
                for row in pairs(set) do
                    if BucketOf(self:_hash(ts, row), ts.n) == newB then moving[#moving + 1] = row end
                end
                for _, row in ipairs(moving) do
                    self:_remove(ts, row)
                    self:_add(ts, row)
                end
                ts.dirty[s + 1] = true
                ts.dirty[newB + 1] = true
                self.layoutDirty = true
            end
        end
    end

    -- Rows of one document in key order (plus extra rows: the old copies of rows moving to another document).
    function Store:_docRows(ts, d, extra)
        local t = ts.t
        local out
        if ts.mode == 'single' then
            out = t.rows
        elseif ts.mode == 'range' then
            local lo, hi = (d - 1) * self.docRows + 1, d * self.docRows
            local rows = t.rows
            out = {}
            local p = d == 1 and 1 or LowerBound(rows, lo)
            while rows[p] and rows[p].k <= hi do
                local r = rows[p]
                if r.d == d then out[#out + 1] = r end
                p = p + 1
            end
        else
            out = {}
            for r in pairs(ts.docs[d] or {}) do out[#out + 1] = r end
            tsort(out, function(a, b) return a.k < b.k end)
        end
        if extra then
            local all = {}
            for i = 1, #out do all[i] = out[i] end
            for _, r in ipairs(extra) do all[#all + 1] = r end
            tsort(all, function(a, b) return a.k < b.k end)
            return all
        end
        return out
    end

    function Store:_docText(ts, d, extra)
        local rows = self:_docRows(ts, d, extra)
        local t = ts.t
        local lines = {}
        for i = 1, #rows do
            local r = rows[i]
            local ln = r.ln
            if not ln then ln = EncodeRow(t, r); r.ln = ln end
            lines[i] = ln
        end
        if #lines == 0 then return self:_header(ts) .. '\n]}\n' end
        return self:_header(ts) .. '\n' .. concat(lines, ',\n') .. '\n]}\n'
    end

    -- Row lines stay cached (row.ln) for the documents saved last; an older document's rows drop theirs.
    function Store:_touchLn(ts, d)
        local list = self.lnDocs
        for i = #list, 1, -1 do
            if list[i].ts == ts and list[i].d == d then tremove(list, i); break end
        end
        list[#list + 1] = { ts = ts, d = d }
        while #list > 16 do -- (16 documents keep their row lines cached for the next save)
            local old = tremove(list, 1)
            if self.ts[old.ts.t.name] == old.ts then
                for _, r in ipairs(self:_docRows(old.ts, old.d)) do r.ln = nil end
            end
        end
    end

    -- An emptied document of a split table is removed, except the newest range document (it holds the ids that
    -- come next, so a missing one is noticed) and hash buckets (they stay, empty).
    function Store:_mayRemove(ts, d)
        if ts.mode == 'range' then return d ~= ts.maxDoc end
        return false
    end

    -- savedLayouts: write the layouts that are already on disk (used when only a counter must be saved
    -- before the documents), not the ones this statement is about to create.
    function Store:_tablesText(db, savedLayouts)
        local lines = {}
        local migrations = 'null'
        for _, t in ipairs(db.order) do
            local ts = self:_state(t)
            local L = ts
            if savedLayouts then L = ts.saved or { mode = 'single', n = 1, maxDoc = 0 } end
            local layout
            if L.mode == 'single' then
                layout = '{"mode":"single"}'
            elseif L.mode == 'range' then
                layout = sformat('{"mode":"range","rows":%d,"docs":%d}', self.docRows, L.maxDoc)
            else
                layout = sformat('{"mode":"hash","rows":%d,"n":%d}', self.docRows, L.n)
            end
            local nextId = t.autoCol and sformat(',"next":%d', t.nextId) or ''
            local entry = '{"name":' .. JstrEncode(t.name) .. ',"file":'
                .. JstrEncode(ts.inline and '_tables.json' or (ts.file .. '.json')) .. nextId .. ',"layout":' .. layout
                .. ',"sql":' .. JstrEncode(RenderCreate(t)) .. '}'
            lines[#lines + 1] = entry
            if ts.inline then
                local rl = {}
                for i, r in ipairs(t.rows) do rl[i] = EncodeRow(t, r) end
                local names = {}
                for i, col in ipairs(t.cols) do names[i] = JstrEncode(col.name) end
                migrations = '{"table":' .. JstrEncode(t.name) .. ',"columns":[' .. concat(names, ',') .. '],"rows":['
                    .. (#rl > 0 and ('\n' .. concat(rl, ',\n') .. '\n') or '') .. ']}'
            end
        end
        return '{"format":1,"about":"Crimson-Police saves (Config.Database.enabled = false). Keep this folder, back it up, do not edit while the server runs.",\n"tables":[\n'
            .. concat(lines, ',\n') .. '\n],\n"migrations":' .. migrations .. '}\n'
    end

    -- What saving _tables.json means for the store's state.
    function Store:_tablesSaved(db, savedLayouts, text)
        for _, t in ipairs(db.order) do
            local ts = self:_state(t)
            ts.savedNext = t.nextId
            if not savedLayouts then ts.saved = { mode = ts.mode, n = ts.n, maxDoc = ts.maxDoc } end
        end
        self.counterDirty = false
        if not savedLayouts then self.layoutDirty = false end
        self.stats.writes = self.stats.writes + 1
        self.stats.bytes = self.stats.bytes + #text
    end

    function Store:_writeTables(db, savedLayouts)
        local text = self:_tablesText(db, savedLayouts)
        local ok, err = ReplaceFile(self, self:path('_tables.json'), text)
        if not ok then return nil, err end
        self:_tablesSaved(db, savedLayouts, text)
        return true
    end

    -- One save. First every changed document (and _tables.json when a layout or a counter changed) is written as
    -- <name>.tmp: a failure there (a full disk) leaves every saved document as it was. Then the .tmp files take the
    -- documents' places, in an order where a crash in between never loses a saved row: _tables.json first when it
    -- only saves a counter the rows can no longer tell; documents that are new on disk; documents that receive rows
    -- (a row whose key moved is in its new document before it leaves its old one: at worst it is there twice, and
    -- a document that also gives rows to another one is first saved with both); the other documents; _tables.json;
    -- the documents to remove. self.done lists what has happened, for Store:restore.
    function Store:flush(db)
        local list = {}
        for _, t in ipairs(db.order) do
            local ts = self:_state(t)
            if not ts.inline then
                local g = self.gains[ts]
                for d in pairs(ts.dirty) do
                    list[#list + 1] = { ts = ts, d = d, new = not ts.onDisk[d], gain = (g and g[d]) and true or false }
                end
            else
                if next(ts.dirty) then self.layoutDirty = true end
            end
        end
        tsort(list, function(a, b)
            if a.new ~= b.new then return a.new end
            if a.gain ~= b.gain then return a.gain end
            if a.ts.file ~= b.ts.file then return a.ts.file < b.ts.file end
            return a.d < b.d
        end)
        local steps = {}
        for _, e in ipairs(list) do
            local ts, d = e.ts, e.d
            local count = ts.mode == 'single' and #ts.t.rows or (ts.counts[d] or 0)
            if count == 0 and ts.mode ~= 'single' and self:_mayRemove(ts, d) then
                if ts.onDisk[d] then steps[#steps + 1] = { kind = 'rm', ts = ts, d = d } else ts.dirty[d] = nil end
            else
                local away = e.gain and self.away[ts] and self.away[ts][d]
                steps[#steps + 1] = {
                    kind = 'doc',
                    ts = ts,
                    d = d,
                    path = self:path(self:docName(ts, d)),
                    text = self:_docText(ts, d, away),
                    final = away and true or nil,
                }
                self:_touchLn(ts, d)
            end
        end
        local tpath = self:path('_tables.json')
        local tablesFirst, tablesLast
        if self.counterDirty then
            tablesFirst = self:_tablesText(db, true)
            if self.layoutDirty then tablesLast = true end
        elseif self.layoutDirty then
            tablesLast = self:_tablesText(db)
        end
        local done = {}
        self.done = done

        -- 1. every .tmp
        local written = {}
        local function writeTmp(path, text)
            local ok, err = FS.write(path .. '.tmp', text)
            if not ok then
                FS.remove(path .. '.tmp')
                for _, p in ipairs(written) do FS.remove(p .. '.tmp') end
                Fail(sformat('cannot write %s.tmp: %s', path, tostring(err)))
            end
            written[#written + 1] = path
        end
        if tablesFirst then
            writeTmp(tpath, tablesFirst)
        elseif type(tablesLast) == 'string' then
            writeTmp(tpath, tablesLast)
        end
        for _, s in ipairs(steps) do
            if s.kind == 'doc' then writeTmp(s.path, s.text) end
        end

        -- 2. into place
        local pending = {}
        for _, p in ipairs(written) do pending[p] = true end
        local function stop(err)
            for p in pairs(pending) do FS.remove(p .. '.tmp') end
            Fail(err)
        end
        local function install(path)
            local ok, err = InstallTmp(self, path)
            pending[path] = nil
            if not ok then stop(err) end
        end
        -- (every step is listed in done before it is tried: Store:restore writes it back whether or not it happened)
        if tablesFirst then
            done[#done + 1] = { kind = 'tables' }
            install(tpath)
            self:_tablesSaved(db, true, tablesFirst)
        end
        for _, s in ipairs(steps) do
            local ts, d = s.ts, s.d
            done[#done + 1] = { kind = 'doc', ts = ts, d = d }
            if s.kind == 'rm' then
                -- (an emptied document that stays would bring its rows back at the next start)
                local rpath = self:path(self:docName(ts, d))
                local okR, errR = FS.remove(rpath)
                if not okR and FS.exists(rpath) then stop(sformat('cannot remove %s: %s', rpath, tostring(errR))) end
                ts.onDisk[d] = nil
                ts.dirty[d] = nil
                self.stats.removes = self.stats.removes + 1
            else
                install(s.path)
                ts.onDisk[d] = true
                if not s.final then ts.dirty[d] = nil end
                self.stats.writes = self.stats.writes + 1
                self.stats.bytes = self.stats.bytes + #s.text
            end
        end
        if type(tablesLast) == 'string' and not tablesFirst then
            done[#done + 1] = { kind = 'tables' }
            install(tpath)
            self:_tablesSaved(db, false, tablesLast)
        end
        -- 3. documents saved with rows that were moving out, now without them; _tables.json after a counter-only save
        for _, s in ipairs(steps) do
            if s.final then
                local text = self:_docText(s.ts, s.d)
                local ok, err = ReplaceFile(self, s.path, text)
                if not ok then Fail(err) end
                s.ts.dirty[s.d] = nil
                self.stats.writes = self.stats.writes + 1
                self.stats.bytes = self.stats.bytes + #text
            end
        end
        if tablesFirst and tablesLast then
            local ok, err = self:_writeTables(db)
            if not ok then Fail(err) end
        end
        for _, t in ipairs(db.order) do
            local ts = self:_state(t)
            if ts.inline then ts.dirty = {} end
        end
        self.gains, self.away = {}, {}
        if #self.removals > 0 then
            for _, r in ipairs(self.removals) do
                if r.ts.onDisk[r.d] and not r.ts.dirty[r.d] then
                    local keep = (r.ts.mode == 'single' and r.d == 0)
                    if not keep then
                        FS.remove(self:path(self:docName(r.ts, r.d)))
                        r.ts.onDisk[r.d] = nil
                        self.stats.removes = self.stats.removes + 1
                    end
                end
            end
            self.removals = {}
        end
        self.done = nil
    end

    -- The store's state for the tables a statement touches, so a failed save can be undone (Store:restore).
    function Store:_snapshot(log)
        local snap = {
            ts = {},
            layoutDirty = self.layoutDirty,
            counterDirty = self.counterDirty,
            noted = {},
            tablesExisted = self.loadedTables or self.savedOnce or false,
        }
        local removals = {}
        for i, r in ipairs(self.removals) do removals[i] = r end
        snap.removals = removals
        for i = 1, log.n do
            local t = log[i].t
            if not snap.noted[t] then
                snap.noted[t] = true
                local ts = self.ts[t.name]
                if ts and ts.t == t then
                    local onDisk, dirty = {}, {}
                    for d in pairs(ts.onDisk) do onDisk[d] = true end
                    for d in pairs(ts.dirty) do dirty[d] = true end
                    snap.ts[t.name] = {
                        ts = ts,
                        mode = ts.mode,
                        n = ts.n,
                        maxDoc = ts.maxDoc,
                        saved = ts.saved,
                        savedNext = ts.savedNext,
                        onDisk = onDisk,
                        dirty = dirty,
                    }
                end
            end
        end
        return snap
    end

    -- Apply one statement's change log, then write through.
    function Store:commit(db, log)
        local snap = self:_snapshot(log)
        self.snap = snap
        local moves = {}
        for i = 1, log.n do
            local e = log[i]
            local op, t = e.op, e.t
            if op == 'create' then
                local ts = self:_state(t)
                if not self.loadedTables and not ts.inline then
                    if FS.exists(self:path(self:docName(ts, 0))) or FS.exists(self:path(self:docName(ts, 1))) then
                        Fail(sformat(
                            '%s already exists in the saves folder but _tables.json does not list it: restore _tables.json from a backup before starting',
                            self:docName(ts, 0)))
                    end
                end
                ts.dirty[0] = true
                self.layoutDirty = true
            elseif op == 'alter' then
                local ts = self:_state(t)
                for _, r in ipairs(t.rows) do r.ln = nil end
                for d in pairs(ts.onDisk) do ts.dirty[d] = true end
                if ts.mode == 'single' then ts.dirty[0] = true end
                self.layoutDirty = true
            elseif op == 'keys' then
                self.layoutDirty = true
            elseif op == 'ins' then
                local ts = self:_state(t)
                self:_add(ts, e.b)
                local g = self.gains[ts]
                if not g then g = {}; self.gains[ts] = g end
                g[e.b.d] = true
            elseif op == 'del' then
                local ts = self:_state(t)
                self:_remove(ts, e.a)
                if e.b then moves[#moves + 1] = { ts = ts, from = e.a.d, row = e.a, to = e.b } end
            elseif op == 'rep' then
                local ts = self:_state(t)
                local from = e.a.d
                self:_remove(ts, e.a)
                self:_add(ts, e.b)
                if e.b.d ~= from then
                    local g = self.gains[ts]
                    if not g then g = {}; self.gains[ts] = g end
                    g[e.b.d] = true
                    moves[#moves + 1] = { ts = ts, from = from, row = e.a, to = e.b }
                end
            end
        end
        -- rows whose key moved them to another document: their old document keeps them until the new one is saved
        for _, m in ipairs(moves) do
            local to = m.to.d
            if to and to ~= m.from and m.from then
                local a = self.away[m.ts]
                if not a then a = {}; self.away[m.ts] = a end
                local list = a[m.from]
                if not list then list = {}; a[m.from] = list end
                list[#list + 1] = m.row
            end
        end
        for t in pairs(snap.noted) do
            local ts = self:_state(t)
            if ts.inline then
                if next(ts.dirty) then self.layoutDirty = true end
            else
                if ts.mode == 'single' and next(ts.dirty) then
                    ts.dirty = { [0] = true }
                end
                self:_maybeSplit(ts)
            end
            if t.autoCol and t.nextId ~= ts.savedNext and t.nextId > Store._maxIdOf(t) + 1 then
                self.counterDirty = true
            end
        end
        self:flush(db)
        self.savedOnce = true
        self.snap = nil
    end

    -- After a failed save (the statement is already undone in memory): the store's state as before the statement,
    -- and every file the save already changed written again from memory (a new document removed). Returns true
    -- when the saves folder is as before the statement; false when that failed too: what could not be written back
    -- stays marked and is written at the next save.
    function Store:restore(db, log)
        local snap, done = self.snap, self.done or {}
        self.snap, self.done = nil, nil
        self.gains, self.away = {}, {}
        if not snap then return true end
        self.layoutDirty, self.counterDirty = snap.layoutDirty, snap.counterDirty
        self.removals = snap.removals
        local altered = {}
        for i = 1, log.n do if log[i].op == 'alter' then altered[log[i].t] = true end end
        for t in pairs(snap.noted) do
            local s = snap.ts[t.name]
            local ts = self.ts[t.name]
            if db.tables[t.name] ~= t then
                -- a table the statement created: gone again
                if ts and ts.t == t then self.ts[t.name] = nil end
            else
                if s then
                    ts = s.ts
                    ts.mode, ts.n, ts.maxDoc, ts.saved, ts.savedNext = s.mode, s.n, s.maxDoc, s.saved, s.savedNext
                    ts.onDisk, ts.dirty = s.onDisk, s.dirty
                else
                    ts = self:_state(t)
                end
                if altered[t] then for _, r in ipairs(t.rows) do r.ln = nil end end
                if not ts.inline then self:_rebuildDocs(ts) end
            end
        end
        local ok = true
        local tablesDone = false
        for _, step in ipairs(done) do
            if step.kind == 'tables' then
                tablesDone = true
            elseif snap.noted[step.ts.t] then
                local t = step.ts.t
                local ts = self.ts[t.name]
                local path = self:path(self:docName(step.ts, step.d))
                if ts and ts.t == t and ts.onDisk[step.d] and not ts.inline then
                    self:_touchLn(ts, step.d)
                    local okW = ReplaceFile(self, path, self:_docText(ts, step.d))
                    if not okW then ok = false; ts.dirty[step.d] = true end
                else
                    FS.remove(path)
                    if FS.exists(path) then
                        ok = false
                        if ts and ts.t == t then self.removals[#self.removals + 1] = { ts = ts, d = step.d } end
                    end
                end
            end
        end
        if tablesDone then
            if snap.tablesExisted then
                local okT = self:_writeTables(db)
                if not okT then ok = false; self.layoutDirty = true end
            else
                FS.remove(self:path('_tables.json'))
            end
        end
        return ok
    end

    -- Every table re-addressed, split to its layout and written (after DB:bulk).
    function Store:rewrite(db)
        for _, t in ipairs(db.order) do
            local ts = self:_state(t)
            if ts.inline then
                self.layoutDirty = true
            else
                self:_reassign(ts)
                if ts.mode == 'single' then ts.dirty = { [0] = true } end
                for _ = 1, #t.rows + 2 do
                    local n, mode = ts.n, ts.mode
                    self:_maybeSplit(ts)
                    if ts.n == n and ts.mode == mode then break end
                end
            end
        end
        self.layoutDirty = true
        self:flush(db)
        self.savedOnce = true
    end

    -- ---- LOADING -----------------------------------------------------------
    local jsonNullValue
    local function IsNullJ(v)
        if v == nil then return true end
        local tv = type(v)
        if tv == 'userdata' or tv == 'function' then return true end
        if jsonNullValue ~= nil and rawequal(v, jsonNullValue) then return true end
        return false
    end

    local function FromJsonValue(col, v, where)
        if IsNullJ(v) then return nil end
        local k = col.kind
        if k == 'date' then
            if type(v) == 'string' then
                local day = DayOf(v)
                if not day then Fail(where .. ': a date (YYYY-MM-DD) was expected for ' .. col.name) end
                return day
            end
            -- (an older document: unix seconds)
            local x = type(v) == 'number' and (mtointeger(v) or mtointeger(mfloor(v))) or nil
            if not x then Fail(where .. ': a date (YYYY-MM-DD) was expected for ' .. col.name) end
            return x
        end
        if k == 'int' or k == 'dt' then
            local x = type(v) == 'number' and (mtointeger(v) or mtointeger(mfloor(v))) or nil
            if not x then Fail(where .. ': a number was expected for ' .. col.name) end
            return x
        elseif k == 'dec' then
            if type(v) ~= 'number' then Fail(where .. ': a number was expected for ' .. col.name) end
            local dv, ds = DecFromText(sformat('%.' .. col.scale .. 'f', v))
            if not dv then return FloatToDec(v, col.scale) end
            return Rescale(dv, ds, col.scale)
        end
        if type(v) == 'string' then return v end
        if type(v) == 'number' then return mtointeger(v) and sformat('%d', v) or FmtDouble(v) end
        if type(v) == 'boolean' then return v and '1' or '0' end
        Fail(where .. ': unexpected value for ' .. col.name)
    end

    -- A row line parsed with the order-keeping parser (slow, exact): values and raw texts.
    local function ParseLineSlow(line, cols, map, ndoc, where)
        local i = Jskip(line, 1)
        if sbyte(line, i) ~= 91 then Fail(where .. ': a row must be a JSON array') end
        i = Jskip(line, i + 1)
        local row = {}
        local j = 0
        if sbyte(line, i) == 93 then
            if ndoc ~= 0 then Fail(sformat('%s: the row has 0 values for %d columns', where, ndoc)) end
            return row
        end
        while true do
            local s = i
            local ok, node, e = pcall(Jvalue, line, i)
            if not ok then Fail(where .. ': invalid JSON') end
            j = j + 1
            local ci = map[j]
            if ci then
                local col = cols[ci]
                local t = node.t
                if t == 'null' then
                    row[ci] = nil
                elseif col.kind == 'json' and (t == 'o' or t == 'a') then
                    row[ci] = ssub(line, s, e - 1)
                elseif t == 's' then
                    row[ci] = FromJsonValue(col, JstrDecode(node.r), where)
                elseif t == 'n' then
                    if col.kind == 'dec' then
                        local dv, ds = DecFromText(node.r)
                        row[ci] = dv and Rescale(dv, ds, col.scale) or FloatToDec(tonumber(node.r), col.scale)
                    else
                        row[ci] = FromJsonValue(col, tonumber(node.r), where)
                    end
                elseif t == 'true' or t == 'false' then
                    row[ci] = t == 'true' and 1 or 0
                else
                    row[ci] = Jtext(node)
                end
            end
            i = Jskip(line, e)
            local c = sbyte(line, i)
            if c == 44 then
                i = Jskip(line, i + 1)
            elseif c == 93 then
                break
            else
                Fail(where .. ': invalid JSON')
            end
        end
        if j ~= ndoc then Fail(sformat('%s: the row has %d values for %d columns', where, j, ndoc)) end
        return row
    end

    -- A document in another layout (reformatted by an editor, all on one line): the same document in the engine's
    -- layout (header line, one row per line), or nil when it is not a valid document. Every value keeps the text it
    -- has in the document, except one that the editor spread over several lines (written compactly).
    function Store._relayout(text)
        local node = Jparse(text)
        if not node or node.t ~= 'o' then return nil end
        local ok, res = pcall(function()
            local i = Jskip(text, 1)
            i = Jskip(text, i + 1)
            local head, lines = {}, nil
            local function sep(close)
                i = Jskip(text, i)
                local c = sbyte(text, i)
                if c == 44 then i = Jskip(text, i + 1); return false end
                if c == close then i = i + 1; return true end
                error('layout', 0)
            end
            if sbyte(text, i) == 125 then return nil end
            while true do
                if sbyte(text, i) ~= 34 then return nil end
                local ke = JstrEnd(text, i)
                local key = ssub(text, i, ke)
                i = Jskip(text, ke + 1)
                if sbyte(text, i) ~= 58 then return nil end
                i = Jskip(text, i + 1)
                if JstrDecode(key) == 'rows' then
                    if sbyte(text, i) ~= 91 then return nil end
                    lines = {}
                    i = Jskip(text, i + 1)
                    if sbyte(text, i) == 93 then
                        i = i + 1
                    else
                        repeat
                            if sbyte(text, i) ~= 91 then return nil end
                            local vals = {}
                            i = Jskip(text, i + 1)
                            if sbyte(text, i) == 93 then
                                i = i + 1
                            else
                                repeat
                                    local s0 = i
                                    local v, e = Jvalue(text, i)
                                    local raw = ssub(text, s0, e - 1)
                                    if sfind(raw, '[\r\n]') then raw = M.jcompact(v) end
                                    vals[#vals + 1] = raw
                                    i = e
                                until sep(93)
                            end
                            lines[#lines + 1] = '[' .. concat(vals, ',') .. ']'
                        until sep(93)
                    end
                else
                    local v, e = Jvalue(text, i)
                    head[#head + 1] = key .. ':' .. M.jcompact(v)
                    i = e
                end
                if sep(125) then break end
            end
            if not lines then return nil end
            return '{' .. concat(head, ',') .. ',"rows":[\n' .. concat(lines, ',\n') .. (#lines > 0 and '\n' or '')
                .. ']}\n'
        end)
        if not ok then return nil end
        return res
    end

    -- Read one document: rows appended to `into` (row.from = d). Returns true when the document was there.
    function Store:_readDoc(t, name, d, into, probe)
        local path = self:path(name)
        RecoverFile(self, path)
        local text = FS.read(path)
        if not text then return false end
        if ssub(text, 1, 3) == '\239\187\191' then
            text = ssub(text, 4)
        end -- a byte order mark (Windows Notepad)
        if probe and self:_owner(text) ~= t.name then return false end
        local where = 'saves/' .. name
        local nl = sfind(text, '\n', 1, true)
        local head = nl and Jparse(ssub(text, 1, nl - 1) .. ']}')
        if not head or head.t ~= 'o' or not JfindKey(head, 'columns') then
            -- not the engine's layout: the whole document, if it is still a valid one
            local again = Store._relayout(text)
            if not again then
                if not nl then Fail(where .. ' is not a Crimson-Police document') end
                Fail(where .. ': the first line is not a document header')
            end
            text = again
            nl = sfind(text, '\n', 1, true)
            head = Jparse(ssub(text, 1, nl - 1) .. ']}')
            if not head or head.t ~= 'o' then Fail(where .. ': the first line is not a document header') end
            where = where .. ' (read as reformatted JSON)'
        end
        head = Jlua(head)
        if head.table ~= t.name then
            Fail(sformat('%s belongs to table %s, not %s', where, tostring(head.table), t.name))
        end
        if type(head.columns) ~= 'table' then Fail(where .. ': the first line is not a document header') end
        local map, cols, ndoc = {}, t.cols, #head.columns
        local simple = true
        local jsonCols = 0
        for j, cname in ipairs(head.columns) do
            local ci = type(cname) == 'string' and t.colIndex[slower(cname)] or nil
            if not ci then
                Warn(sformat('%s has a column %s that the table no longer has; it is ignored', where, tostring(cname)))
                simple = false
            else
                map[j] = ci
                if cols[ci].kind == 'json' then jsonCols = jsonCols + 1 end
            end
        end
        -- table columns the document does not have (a column added while the server was down mid-save)
        local missing = {}
        do
            local have = {}
            for j = 1, ndoc do if map[j] then have[map[j]] = true end end
            for ci, col in ipairs(cols) do
                if not have[ci] then
                    local v = col.default
                    if v == nil and col.defaultNow then v = os.time() end
                    if v == nil and col.notnull then
                        v = ImplicitDefault(col)
                        if v == nil then
                            v = false
                        end -- a DATETIME / DATE: no value (checked below if there are rows)
                    end
                    missing[#missing + 1] = { ci = ci, v = v }
                end
            end
        end
        local notnull = {}
        for ci, col in ipairs(cols) do if col.notnull then notnull[#notnull + 1] = ci end end
        local nnn = #notnull
        local decode = type(json) == 'table' and json.decode or nil
        jsonNullValue = type(json) == 'table' and rawget(json, 'null') or nil
        local nullv = jsonNullValue
        -- per document column: 1 integer/DATETIME, 2 DECIMAL, 3 text/ENUM, 4 JSON, 5 DATE
        local kinds, scales, cis = {}, {}, {}
        local decLimit = {}
        for j = 1, ndoc do
            local ci = map[j]
            cis[j] = ci
            if ci then
                local k = cols[ci].kind
                if k == 'int' or k == 'dt' then
                    kinds[j] = 1
                elseif k == 'dec' then
                    kinds[j] = 2
                    scales[j] = cols[ci].scale
                    decLimit[j] = 9.0e15 / POW10[cols[ci].scale]
                elseif k == 'json' then
                    kinds[j] = 4
                elseif k == 'date' then
                    kinds[j] = 5
                else
                    kinds[j] = 3
                end
            end
        end
        local jsonAt, njson = {}, 0
        for j = 1, ndoc do
            if kinds[j] == 4 then njson = njson + 1; jsonAt[njson] = j end
        end
        local nmissing = #missing
        local from = nmissing > 0 and -1 or d
        local pos = nl + 1
        local lineNo = 1
        local len = #text
        local EXACT = 9007199254740992 -- 2^53: a double past it may have lost digits (the line is read again exactly)
        while pos <= len do
            local e = sfind(text, '\n', pos, true) or (len + 1)
            local line = ssub(text, pos, e - 1)
            pos = e + 1
            lineNo = lineNo + 1
            if sbyte(line, -1) == 13 then line = ssub(line, 1, -2) end
            if line == ']}' then break end
            if line ~= '' then
                if sbyte(line, -1) == 44 then line = ssub(line, 1, -2) end
                local row
                local vals
                local cut = false
                if decode and simple and njson == 1 then
                    -- One JSON column embedded as JSON (a run's breakdown): the values before and after it are decoded
                    -- on their own and its text is kept as it is, so it is never decoded into tables. The cut is tried
                    -- at the first ",{" / ",[" and the last "}," / "]," of the line; it only counts when both sides decode
                    -- to exactly the columns they should hold (a cut inside a text value never does: that text would be
                    -- left open). Otherwise the whole line is decoded below.
                    local J = jsonAt[1]
                    local s1
                    if J == 1 then
                        s1 = 2
                    else
                        s1 = sfind(line, ',[%[{]', 2)
                        if s1 then s1 = s1 + 1 end
                    end
                    local e1 = #line - 1
                    if J < ndoc then
                        -- the last closing bracket before the row's own ']' (looked for near the end first: the values
                        -- after the JSON column are short)
                        e1 = sfind(line, '[%]}][^%]}]*%]$', mmax(s1 or 2, #line - 96))
                        if not e1 and s1 and #line - 96 > s1 then e1 = sfind(line, '[%]}][^%]}]*%]$', s1) end
                        if e1 and sbyte(line, e1 + 1) ~= 44 then e1 = nil end
                    end
                    if s1 and e1 and s1 < e1 then
                        local b1, b2 = sbyte(line, s1), sbyte(line, e1)
                        if (b1 == 123 and b2 == 125) or (b1 == 91 and b2 == 93) then
                            local okP, pre = true, EMPTY
                            if J > 1 then okP, pre = pcall(decode, ssub(line, 1, s1 - 2) .. ']') end
                            local okS, suf = true, EMPTY
                            if J < ndoc then okS, suf = pcall(decode, '[' .. ssub(line, e1 + 2)) end
                            if okP and okS and type(pre) == 'table' and type(suf) == 'table' and #pre == J - 1
                                and #suf == ndoc - J then
                                -- pre holds columns 1 .. J-1 already; the rest is appended to it
                                vals = pre
                                if J == 1 then vals = {} end
                                vals[J] = ssub(line, s1, e1)
                                for j = J + 1, ndoc do vals[j] = suf[j - J] end
                                cut = true
                            end
                        end
                    end
                end
                if not vals and decode and simple then
                    local ok, res = pcall(decode, line)
                    -- as many values as columns, or the exact reader says what is wrong with the line
                    if ok and type(res) == 'table' and #res == ndoc then vals = res end
                end
                if vals then
                    row = {}
                    -- a JSON column embedded as JSON comes back as a table: its exact text is cut out of the line,
                    -- between the other values, whose written length is known
                    local rawAt, nraw = nil, 0
                    if not cut then
                        for j = 1, njson do
                            local jj = jsonAt[j]
                            local jv = vals[jj]
                            if type(jv) == 'table' and not (nullv ~= nil and jv == nullv) then
                                rawAt, nraw = jj, nraw + 1
                            end
                        end
                    end
                    local total, before = 0, 0
                    local measure = nraw == 1
                    for j = 1, ndoc do
                        local v = vals[j]
                        local k = kinds[j]
                        if k == 1 then
                            local x = mtointeger(v)
                            if x then
                                if mtype(v) == 'float' and (x >= EXACT or x <= -EXACT) then row = nil; break end
                                row[cis[j]] = x
                                if measure then total = total + IntLen(x) + 1 end
                            elseif v == nil or v == nullv or type(v) == 'userdata' or type(v) == 'function' then
                                total = total + 5
                            else
                                -- not a whole number, or one a double cannot hold: the exact reader decides
                                row = nil
                                break
                            end
                        elseif j == rawAt then
                            before = total
                        elseif k == 5 and type(v) == 'string' then
                            local day = DayOf(v)
                            if not day then row = nil; break end
                            row[cis[j]] = day
                            if measure then total = total + #v + 3 end
                        elseif type(v) == 'string' and k ~= 2 then
                            row[cis[j]] = v
                            if measure then
                                if sfind(v, '["\\\0-\31]') then
                                    total = total + #JstrEncode(v) + 1
                                else
                                    total = total + #v + 3
                                end
                            end
                        elseif v == nil or v == nullv or type(v) == 'userdata' or type(v) == 'function' then
                            total = total + 5
                        elseif k == 2 then
                            if type(v) ~= 'number' or v >= decLimit[j] or v <= -decLimit[j] then row = nil; break end
                            local x = FloatToDec(v, scales[j])
                            row[cis[j]] = x
                            if measure then total = total + #FmtDec(x, scales[j]) + 1 end
                        elseif k == 3 or k == 5 then
                            local x = FromJsonValue(cols[cis[j]], v, where .. ' line ' .. lineNo)
                            row[cis[j]] = x
                            if measure then total = total + #EncodeValue(cols[cis[j]], x) + 1 end
                        end
                    end
                    if row and nraw == 1 then
                        local s, e2 = 2 + before, #line - 1 - (total - before)
                        local b1, b2 = sbyte(line, s), sbyte(line, e2)
                        if (b1 == 123 and b2 == 125) or (b1 == 91 and b2 == 93) then
                            row[cis[rawAt]] = ssub(line, s, e2)
                        else
                            row = nil
                        end
                    elseif nraw > 1 then
                        row = nil
                    end
                end
                if not row then row = ParseLineSlow(line, cols, map, ndoc, where .. ' line ' .. lineNo) end
                for m = 1, nmissing do
                    local v = missing[m].v
                    if v == false then
                        Fail(sformat(
                            '%s line %d: the document has no column %s, which cannot be empty: restore the document from a backup',
                            where, lineNo, cols[missing[m].ci].name))
                    end
                    row[missing[m].ci] = v
                end
                for m = 1, nnn do
                    if row[notnull[m]] == nil then
                        Fail(sformat('%s line %d: %s is null, but it cannot be', where, lineNo, cols[notnull[m]].name))
                    end
                end
                row.from = from
                into[#into + 1] = row
            end
        end
        return true
    end

    -- The table a document belongs to (from its first line, or the whole document), or nil.
    function Store:_owner(text)
        if ssub(text, 1, 3) == '\239\187\191' then text = ssub(text, 4) end
        local nl = sfind(text, '\n', 1, true)
        local head = nl and Jparse(ssub(text, 1, nl - 1) .. ']}')
        if not head or head.t ~= 'o' then head = Jparse(text) end
        if not head or head.t ~= 'o' then return nil end
        local i = JfindKey(head, 'table')
        if not i or head.v[i].t ~= 's' then return nil end
        return JstrDecode(head.v[i].r)
    end

    -- How this runtime's os.rename answers (see FS.rename): 'normal', 'inverted', or 'check' (decided by the files).
    function Store:_probeRename()
        local a, b = self:path('.cp-rename-test'), self:path('.cp-rename-test2')
        self.renames = 'check'
        if FS.exists(b) then FS.remove(b) end
        if not FS.write(a, 'ok') then return end
        local ok = FS.rename(a, b)
        local moved = FS.exists(b) and not FS.exists(a)
        if moved then self.renames = ok and 'normal' or 'inverted' end
        FS.remove(a)
        FS.remove(b)
    end

    function Store:load(db)
        self:_probeRename()
        -- .tmp files are left only by a save that was cut off: none of them is a saved document
        for _, name in ipairs(FS.list(self.dir) or {}) do
            if ssub(name, -4) == '.tmp' then FS.remove(self:path(name)) end
        end
        local tpath = self:path('_tables.json')
        RecoverFile(self, tpath)
        local text = FS.read(tpath)
        self.loadedTables = text ~= nil
        if not text then
            self.loaded = true
            return
        end
        if ssub(text, 1, 3) == '\239\187\191' then text = ssub(text, 4) end
        local node = Jparse(text)
        if not node or node.t ~= 'o' then Fail('saves/_tables.json is not valid JSON') end
        local meta = Jlua(node)
        local repair = false
        for _, entry in ipairs(meta.tables or {}) do
            local t = db:_defineTable(entry.sql)
            local ts = self:_state(t)
            local layout = entry.layout or { mode = 'single' }
            if t.autoCol and entry.next then t.nextId = mmax(1, entry.next) end
            ts.savedNext = entry.next
            local found = {}
            local minNext -- ids a missing document may have used are never handed out again
            if ts.inline then
                local m = meta.migrations
                if m and m.table == t.name then
                    local map = {}
                    for j, name in ipairs(m.columns or {}) do map[j] = t.colIndex[slower(name)] end
                    for _, vals in ipairs(m.rows or {}) do
                        local row = {}
                        for j = 1, #(m.columns or {}) do
                            local ci = map[j]
                            if ci then row[ci] = FromJsonValue(t.cols[ci], vals[j], 'saves/_tables.json') end
                        end
                        row.from = 0
                        found[#found + 1] = row
                    end
                end
            else
                ts.mode = layout.mode or 'single'
                local zero = self:docName(ts, 0)
                if ts.mode == 'single' then
                    ts.saved = { mode = 'single', n = 1, maxDoc = 0 }
                    if not self:_readDoc(t, zero, 0, found) then
                        self.missing[#self.missing + 1] = zero
                        Warn(sformat(
                            'saves/%s is missing: %s starts empty. To get its rows back, stop the server, put the file back from a backup and start again.',
                            zero, t.name))
                        if ts.range and t.autoCol then minNext = self.docRows + 1 end
                    end
                    -- numbered documents of an unfinished split are not part of this layout
                    local k = 1
                    while true do
                        RecoverFile(self, self:path(self:docName(ts, k)))
                        local okText = FS.read(self:path(self:docName(ts, k)))
                        if not okText or self:_owner(okText) ~= t.name then break end
                        self.removals[#self.removals + 1] = { ts = ts, d = k, orphan = true }
                        ts.onDisk[k] = true
                        k = k + 1
                    end
                    ts.onDisk[0] = FS.exists(self:path(zero)) or nil
                else
                    if ts.mode == 'hash' then ts.n = mmax(2, tonumber(layout.n) or 2) end
                    if ts.mode == 'range' then ts.maxDoc = tonumber(layout.docs) or 0 end
                    ts.saved = { mode = ts.mode, n = ts.n, maxDoc = ts.maxDoc }
                    local last = ts.mode == 'hash' and ts.n or ts.maxDoc
                    for d = 1, last do
                        local name = self:docName(ts, d)
                        if self:_readDoc(t, name, d, found) then
                            ts.onDisk[d] = true
                        elseif ts.mode == 'hash' or d == last then
                            -- hash buckets and the newest range document always stay (emptied ones too)
                            self.missing[#self.missing + 1] = name
                            if ts.mode == 'range' then
                                Warn(sformat(
                                    'saves/%s is missing: the rows of %s with ids %d to %d start empty, and those ids are not used again. To get them back, stop the server, put the file back from a backup and start again.',
                                    name, t.name, (d - 1) * self.docRows + 1, d * self.docRows))
                                minNext = d * self.docRows + 1
                            else
                                Warn(sformat(
                                    'saves/%s is missing: the rows of %s in it start empty. To get them back, stop the server, put the file back from a backup and start again.',
                                    name, t.name))
                            end
                        end
                    end
                    -- documents written by a statement whose _tables.json update never happened
                    local d = last + 1
                    while self:_readDoc(t, self:docName(ts, d), d, found, true) do
                        ts.onDisk[d] = true
                        if ts.mode == 'range' then
                            ts.maxDoc = d
                            repair = true
                            minNext = nil
                        else
                            self.removals[#self.removals + 1] = { ts = ts, d = d, orphan = true }
                        end
                        d = d + 1
                    end
                    RecoverFile(self, self:path(zero))
                    local zeroText = FS.read(self:path(zero))
                    if zeroText and self:_owner(zeroText) == t.name then
                        ts.onDisk[0] = true
                        self.removals[#self.removals + 1] = { ts = ts, d = 0, orphan = true }
                    end
                end
            end
            -- the same key twice: in two documents it is an interrupted save (keep the copy from the document the
            -- key belongs to); in one document it is damage
            local rows = found
            if t.pk then
                local byKey, posOf = {}, {}
                rows = {}
                for _, row in ipairs(found) do
                    local key = PkKeyOf(t, row)
                    local prev = byKey[key]
                    if prev then
                        if prev.from == row.from and not ts.inline then
                            Fail(sformat('saves/%s has the key \'%s\' twice: remove one of the two rows',
                                self:docName(ts, mmax(row.from, 0)), M.dupEntryText(t, row, t.pk)))
                        end
                        local want = self:_docOf(ts, row)
                        if row.from == want and prev.from ~= want then
                            rows[posOf[key]] = row
                            byKey[key] = row
                        end
                        repair = true
                    else
                        rows[#rows + 1] = row
                        posOf[key] = #rows
                        byKey[key] = row
                    end
                end
            end
            -- a UNIQUE key twice is damage too
            for _, u in ipairs(t.uniques) do
                local seen = {}
                for _, row in ipairs(rows) do
                    local key = UniqueKeyOf(t, u, row)
                    if key then
                        if seen[key] then
                            Fail(sformat('saves/%s: two rows have the same %s \'%s\': remove one of them',
                                self:docName(ts, mmax(row.from, 0)), u.name, M.dupEntryText(t, row, u.cols)))
                        end
                        seen[key] = true
                    end
                end
            end
            db:_loadRows(t, rows)
            if minNext and t.autoCol and t.nextId < minNext then
                t.nextId = minNext
                repair = true
            end
            if not ts.inline then
                for _, row in ipairs(t.rows) do
                    local d = self:_docOf(ts, row)
                    row.d = d
                    local set = ts.docs[d]
                    if not set then set = {}; ts.docs[d] = set; ts.counts[d] = 0 end
                    set[row] = true
                    ts.counts[d] = ts.counts[d] + 1
                    if row.from ~= d then ts.dirty[d] = true; repair = true end
                    row.from = nil
                end
            else
                for _, row in ipairs(t.rows) do row.from = nil end
            end
            if t.autoCol and t.nextId ~= ts.savedNext then repair = true end
        end
        self.loaded = true
        if repair or #self.removals > 0 then
            self.layoutDirty = self.layoutDirty or repair
            self:flush(db)
        end
    end

    -- Bytes and documents in the folder for one table (for reports and tests).
    function Store:sizeOf(tableName)
        local ts = self.ts[tableName]
        if not ts then return 0, 0 end
        local bytes, docs = 0, 0
        for d in pairs(ts.onDisk) do
            local s = FS.read(self:path(self:docName(ts, d)))
            if s then bytes = bytes + #s; docs = docs + 1 end
        end
        return bytes, docs
    end

    M.encodeRow = EncodeRow
    M.bucketOf = BucketOf
    M.DOC_ROWS = DOC_ROWS
end

return M
