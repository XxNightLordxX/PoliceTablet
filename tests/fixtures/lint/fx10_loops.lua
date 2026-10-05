-- Loops for tools/lua_flow.py (lint rule FX10), read by tests/freeze_spec.lua. Never loaded: each loop line ends
-- with the verdict it must get (expect HIT / bounded / pure / ok).

local m, deadline, x, done, n, ped = 1, 2, 3, false, 4, 5

local function WaitALittle() Wait(10) end

local function WaitSometimes(a)
    if a then Wait(0) end
end

local function Loaded() return HasModelLoaded(m) end

local function Step() n = n - 1 end

CreateThread(function()
    while not HasModelLoaded(m) do -- expect HIT
        RequestModel(m)
    end
    while GetGameTimer() < deadline do -- expect HIT
        if x then Wait(0) end
    end
    while true do -- expect HIT
        if IsControlJustPressed(0, 38) then break end
    end
    while true do -- expect ok
        Wait(0)
    end
    while not IsScreenFadedOut() do -- expect ok
        Wait(0)
    end
    while not IsScreenFadedOut() and GetGameTimer() < deadline do -- expect ok
        Citizen.Wait(0)
    end
    repeat -- expect HIT
        RequestModel(m)
    until HasModelLoaded(m)
    while not IsPedArmed(ped, 6) do -- expect ok
        WaitALittle()
    end
    while not IsPedArmed(ped, 6) do -- expect HIT
        WaitSometimes(x)
    end
    while not IsPedArmed(ped, 6) do -- expect ok
        pcall(function() Wait(0) end)
    end
    while not IsPedArmed(ped, 6) do -- expect HIT
        if x then break end
    end
    while IsPedArmed(ped, 6) do -- expect ok
        if x then Wait(0) else return end
    end
    while not done and IsPedArmed(ped, 6) do -- expect HIT
        lib.progressBar({ duration = 1000 })
    end
    while not Loaded() do -- expect HIT
        RequestModel(m)
    end
    while not IsPedArmed(ped, 6) do -- expect HIT
        if x then goto continue end
        Wait(0)
        ::continue::
    end
    local obj = GetClosestObjectOfType(0.0, 0.0, 0.0, 2.0, m, false, false, false)
    while obj and DoesEntityExist(obj) do -- expect HIT
        DeleteObject(obj)
        obj = GetClosestObjectOfType(0.0, 0.0, 0.0, 2.0, m, false, false, false)
    end
    local e = GetClosestObjectOfType(0.0, 0.0, 0.0, 2.0, m, false, false, false)
    while e ~= 0 do -- expect HIT
        DeleteEntity(e)
        e = GetClosestObjectOfType(0.0, 0.0, 0.0, 2.0, m, false, false, false)
    end
    local tries = 5
    while tries > 0 and DoesEntityExist(obj) do -- expect bounded
        DeleteObject(obj)
        tries = tries - 1
    end
    local t = { 1 }
    for _, v in ipairs(t) do -- expect HIT
        t[#t + 1] = v
    end
    while n > 0 do -- expect pure
        Step()
    end
    local d, step = 0, 5.0
    while d < GetGpsBlipRouteLength() do -- expect bounded
        d = d + step
    end
    while GetGameTimer() < deadline do -- expect ok
        if HasModelLoaded(m) then break end
        Wait(100)
    end
end)
