-- Server yes/no answers for tools/lint_fivem.py rule FX12, read by tests/foundation_spec.lua (run as a server script
-- with `--files server`). Never loaded: each line that must be a hit ends with "expect FX12" after two dashes.

local function Direct(e)
    local a = DoesEntityExist(e) == true                             -- expect FX12
    local b = DoesEntityExist(e) ~= true                             -- expect FX12
    local c = true == IsPlayerAceAllowed(e, 'command')               -- expect FX12
    local d = StateBagHasKey(('entity:%d'):format(e), 'cp') == true  -- expect FX12
    return a, b, c, d
end

local function Multiline(e, longArgumentNumberOne, longArgumentNumberTwo, longArgumentNumberThree)
    return IsPlayerAceAllowed(
        e,
        ('%s.%s.%s.%s'):format(longArgumentNumberOne, longArgumentNumberTwo, longArgumentNumberThree, 'command')
    ) == true -- expect FX12
end

local function ThroughALocal(e)
    local found = DoesEntityExist(e)
    local frozen = IsEntityPositionFrozen(e)
    local a = found == true     -- expect FX12
    return a, frozen ~= true    -- expect FX12
end

local function Right(e)
    local a = DoesEntityExist(e) and 1 or 2
    local b = not DoesEntityExist(e)
    local c = DoesEntityExist(e) == false
    local d = DoesEntityExist(e) ~= false
    local f = DoesEntityExist(e) == 1
    local found = DoesEntityExist(e)
    local g = found == true or found == 1
    local both = DoesEntityExist(e) and IsPedHandcuffed(e)
    local h = both == true
    local t = {}
    t.found = DoesEntityExist(e)
    local i = GetEntityModel(e) == true
    return a, b, c, d, f, g, h, t, i
end

local function Shadowed()
    local DoesPlayerExist = function() return true end
    return DoesPlayerExist() == true
end

return Direct, Multiline, ThroughALocal, Right, Shadowed
