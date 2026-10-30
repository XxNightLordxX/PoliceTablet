-- The Mission Board's officer options (My options -> Mission Board, saved with the character): favourite types first,
-- types folded away, accept in one click. Type cards only: the server still checks every accept and draws at random.

local Defs = CP.OptionDefs

-- The Config.MissionTypes keys in the board's order (points, then key), asked at every call so a new type works.
local function TypeKeys()
    local types = type(Config) == 'table' and type(Config.MissionTypes) == 'table' and Config.MissionTypes or {}
    local keys = {}
    for k, v in pairs(types) do
        if type(k) == 'string' and type(v) == 'table' then keys[#keys + 1] = k end
    end
    table.sort(keys, function(a, b)
        local pa, pb = tonumber(types[a].points) or 0, tonumber(types[b].points) or 0
        if pa ~= pb then return pa < pb end
        return a < b
    end)
    return keys
end

-- A hiddenTypes list may not hide every mission type: the board always keeps one type to accept.
local function NotAll(list)
    local offered = TypeKeys()
    if #offered == 0 then return nil end
    local hidden = {}
    for _, k in ipairs(type(list) == 'table' and list or {}) do hidden[k] = true end
    for _, k in ipairs(offered) do
        if not hidden[k] then return nil end
    end
    return 'err.option_hide_all'
end

Defs.add('favouriteTypes', { kind = 'list', values = TypeKeys, default = {}, group = 'board', order = 10 })
Defs.add('hiddenTypes', { kind = 'list', values = TypeKeys, default = {}, guard = NotAll, group = 'board', order = 20 })
Defs.add('skipAcceptConfirm', { kind = 'bool', default = false, group = 'board', order = 30 })
