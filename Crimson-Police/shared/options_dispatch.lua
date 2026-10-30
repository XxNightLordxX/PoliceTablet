-- The Dispatch and opening officer options (My options -> Dispatch and Opening the tablet): claim in one click

local Defs = CP.OptionDefs

local DISPATCH_FILTERS = { 'all', 'claimable', 'near' }
local PERIODS = { 'weekly', 'monthly', 'season', 'alltime' }
local BOARD_EXTRAS = { 'unit', 'cross', 'department' }

local function Keys(t)
    local out = {}
    for k, v in pairs(type(t) == 'table' and t or {}) do
        if type(k) == 'string' and type(v) == 'table' then out[#out + 1] = k end
    end
    table.sort(out)
    return out
end

-- The filter values a screen may remember, as 'screen.part:value' (asked at every call: types and metrics change).
local function FilterValues()
    local cfg = type(Config) == 'table' and Config or {}
    local out = {}
    local function Add(prefix, list)
        for _, v in ipairs(list) do
            if type(v) == 'string' then out[#out + 1] = prefix .. v end
        end
    end
    Add('dispatch.filter:', DISPATCH_FILTERS)
    Add('leaderboard.period:', PERIODS)
    Add('leaderboard.filter:', { 'overall' })
    Add('leaderboard.filter:', Keys(cfg.MissionTypes))
    Add('leaderboard.filter:', BOARD_EXTRAS)
    Add('leaderboard.department:', Keys(cfg.Departments))
    local lb = type(cfg.Leaderboard) == 'table' and cfg.Leaderboard or {}
    Add('leaderboard.metric:', type(lb.metrics) == 'table' and lb.metrics or { 'points' })
    return out
end

Defs.add('skipClaimConfirm', { kind = 'bool', default = false, group = 'dispatch', order = 10 })
Defs.add('callAlerts',
    { kind = 'enum', values = { 'all', 'favourites' }, default = 'all', group = 'dispatch', order = 20 })
Defs.add('dispatchKeyAfterCall', { kind = 'bool', default = false, group = 'dispatch', order = 30 })
Defs.add('openOn', {
    kind = 'enum',
    values = { 'last', 'home', 'active_on_run' },
    default = 'last',
    group = 'opening',
    order = 10,
})
Defs.add('rememberFilters', { kind = 'bool', default = false, store = 'local', group = 'opening', order = 20 })
Defs.add('filters', {
    kind = 'list',
    values = FilterValues,
    default = {},
    store = 'local',
    hidden = true,
    group = 'opening',
    order = 30,
})
