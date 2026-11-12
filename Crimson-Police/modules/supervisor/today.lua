-- CP.SupToday (server): Supervisor UI -> Department, today at a glance (sup:getToday, UI4).

-- CP.SupToday (server): Supervisor UI -> Department, today at a glance (sup:getToday): the department's officers on
-- duty, its runs going (as Live Missions lists them) and the viewer's Mission controls used today (CP.DeptControls.mine).
-- The Review Queue count is the sidebar's (getNavCounts). Read only; viewMissionList, as the Officers tab.

CP.SupToday = CP.SupToday or {}
local ST = CP.SupToday
local TAG = 'suptoday'

local function Call(modName, fnName, ...) return CP.Call(TAG, modName, fnName, ...) end

-- A whole count of at least 0 (anything else = 0).
local function Count(v)
    local n = tonumber(v)
    if not n or n ~= n or n < 0 or n == math.huge then return 0 end
    return math.floor(n)
end

-- A run not ended with an officer of dept on it (nil dept = every run: an admin with no department, as Live Missions).
local function Involves(run, dept)
    if type(run) ~= 'table' or run.state == 'ended' then return false end
    if not dept then return true end
    for _, p in pairs(type(run.participants) == 'table' and run.participants or {}) do
        if type(p) == 'table' and p.department == dept then return true end
    end
    return false
end

-- The viewer's Mission controls today: how many have a day count, the uses of today and the day counts summed.
local function Controls(src)
    local ok, mine = Call('DeptControls', 'mine', src)
    local out = { counted = 0, used = 0, perDay = 0 }
    local list = ok and type(mine) == 'table' and type(mine.controls) == 'table' and mine.controls or {}
    for _, c in ipairs(list) do
        local perDay = Count(type(c) == 'table' and c.perDay)
        if perDay > 0 then
            out.counted = out.counted + 1
            out.perDay = out.perDay + perDay
            out.used = out.used + math.min(Count(c.usedToday), perDay)
        end
    end
    return out
end

-- { onDuty, running, controls = { counted, used, perDay } }, or nil, errKey.
function ST.today(src)
    local can, errKey = CP.can(src, 'viewMissionList')
    if not can then return nil, errKey end
    local okO, officer = Call('Access', 'getOfficer', src)
    local dept = okO and type(officer) == 'table' and officer.department or nil
    local okA, admin = Call('Access', 'isAdmin', src)
    if not dept and not (okA and admin == true) then return nil, 'err.no_permission' end
    local okD, counts = Call('Admin', 'onDutyCounts')
    counts = okD and type(counts) == 'table' and counts or {}
    local onDuty = 0
    if dept then
        onDuty = Count(counts[dept])
    else
        for _, n in pairs(counts) do onDuty = onDuty + Count(n) end
    end
    local okR, runs = Call('Runs', 'all')
    local running = 0
    for _, run in ipairs(okR and type(runs) == 'table' and runs or {}) do
        if Involves(run, dept) then running = running + 1 end
    end
    return { onDuty = onDuty, running = running, controls = Controls(src) }
end

CP.Net.callback('sup:getToday', function(src) return ST.today(src) end, { rate = 3 })
