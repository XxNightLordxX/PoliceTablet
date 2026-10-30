-- CP.Twists (shared): the twists of a run (Armored Hostiles, Time Crunch, Radio Silence) that the officers choose when
-- they take a mission (PLAN M8b). Which twists a run carries, and what a set of them adds together
-- (Config.Events.twists, capped by Config.Events.twistMaxPoints and twistMaxCash). Pure Lua: no natives.

CP.Twists = CP.Twists or {}
local Twists = CP.Twists

-- Every twist, in the order the tablet offers them, the run lists them and the result card scores them.
Twists.ORDER = { 'armored_hostiles', 'time_crunch', 'radio_silence' }
local RANK = {}
for i, key in ipairs(Twists.ORDER) do RANK[key] = i end

-- The shipped rewards, for a twist that Config.Events.twists leaves out.
local DEFAULTS = {
    armored_hostiles = { points = 0.25, cash = 1.25 },
    time_crunch = { points = 0.20, cash = 1.20 },
    radio_silence = { points = 0.25, cash = 1.25 },
}
local DEFAULT_MAX_POINTS = 0.70
local DEFAULT_MAX_CASH = 1.95

local function Num(v, default)
    local n = tonumber(v)
    if n == nil or n ~= n then return default end
    return n
end

local function Events()
    return type(Config) == 'table' and type(Config.Events) == 'table' and Config.Events or {}
end

function Twists.known(key)
    return type(key) == 'string' and RANK[key] ~= nil
end

-- One twist's settings: { enabled, points = the share of P it adds (0 = none), cash = its cash multiplier (1.0 =
-- none) }, or nil for an unknown key.
function Twists.cfg(key)
    if not Twists.known(key) then return nil end
    local all = type(Events().twists) == 'table' and Events().twists or {}
    local c = type(all[key]) == 'table' and all[key] or {}
    local d = DEFAULTS[key]
    return {
        enabled = c.enabled ~= false,
        points = math.max(0, Num(c.points, d.points)),
        cash = math.max(1.0, Num(c.cash, d.cash)),
    }
end

-- The known keys of a list, each once, in ORDER.
function Twists.sorted(list)
    local seen, out = {}, {}
    for _, key in ipairs(type(list) == 'table' and list or {}) do
        if Twists.known(key) and not seen[key] then
            seen[key] = true
            out[#out + 1] = key
        end
    end
    table.sort(out, function(a, b) return RANK[a] < RANK[b] end)
    return out
end

-- The twists of a run, or of the client:start payload: its modifiers list. A run that names one modifier only (made
-- before the list existed) has that one.
function Twists.of(holder)
    if type(holder) ~= 'table' then return {} end
    if type(holder.modifiers) == 'table' and #holder.modifiers > 0 then return Twists.sorted(holder.modifiers) end
    if Twists.known(holder.modifier) then return { holder.modifier } end
    return {}
end

function Twists.has(holder, key)
    for _, k in ipairs(Twists.of(holder)) do
        if k == key then return true end
    end
    return false
end

-- The caps of stacked twists: points = the most they add together (a share of P), cash = the highest multiplier
-- they give together.
function Twists.caps()
    local ev = Events()
    return {
        points = math.max(0, Num(ev.twistMaxPoints, DEFAULT_MAX_POINTS)),
        cash = math.max(1.0, Num(ev.twistMaxCash, DEFAULT_MAX_CASH)),
    }
end

-- What a set of twists adds together: points (a share of P: the shares add up), cash (a multiplier: the
-- multipliers multiply), both stopped at the caps, and lines (each twist's share of the points after the cap, in
-- ORDER: the result card's bonus lines). scale (optional): { [twist] = x its cash } (a department's twistCash
-- Mission control, step P16); points never change and the cash cap still applies.
function Twists.bonus(list, scale)
    local caps = Twists.caps()
    local left, cash, lines = caps.points, 1.0, {}
    scale = type(scale) == 'table' and scale or {}
    for _, key in ipairs(Twists.sorted(list)) do
        local c = Twists.cfg(key)
        local share = math.max(0, math.min(c.points, left))
        left = left - share
        lines[#lines + 1] = { key = key, points = share }
        cash = cash * c.cash * math.max(1.0, Num(scale[key], 1.0))
    end
    return { points = caps.points - left, cash = math.min(cash, caps.cash), lines = lines }
end

-- The twist cash scale a run carries (run.controls.twistCash, read at the accept, step P16), or nil: never on test
-- runs, Cross-Department runs or the Weekly Boss.
function Twists.scaleOf(run)
    if type(run) ~= 'table' or run.test or run.operationId or run.isBoss then return nil end
    local c = type(run.controls) == 'table' and run.controls.twistCash or nil
    return type(c) == 'table' and c or nil
end
