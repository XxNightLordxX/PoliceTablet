-- CP.MissionCalls (client): the new-call toast and tone, and telling the server when the tablet closes (the
-- Dispatch screen data is only built for open tablets).

CP.MissionCalls = CP.MissionCalls or {}
local MC = CP.MissionCalls

local SOUND_NAME = 'Event_Message_Purple'
local SOUND_SET = 'GTAO_FM_Events_Soundset'
local CUE_MIN_GAP_MS = 4000          -- at most one tone per 4 s (several calls at once)
local WATCH_POLL_MS = 1000

local lastCueAt = nil
local wasOpen = false

local function Foreign(v)
    return type(v) == 'table' and v.active == true and v.source ~= 'crimson-police'
end

-- docs/CRIMSON_ARENA.md: no Crimson-Police cue while the player is in the arena.
local function InArena()
    local ok, v = pcall(function() return LocalPlayer.state.crimsonArena end)
    return ok and Foreign(v)
end

local function OnRun()
    return CP.Runs ~= nil and CP.Runs.current ~= nil and CP.Runs.current() ~= nil
end

function MC.lastCueAt()
    return lastCueAt
end

-- The server only sends this to officers who could claim the call and have not muted call alerts; the client
-- drops it on a run or in the arena as well.
RegisterNetEvent(CP.e('client:missionCall'), function(call)
    if type(call) ~= 'table' or type(call.code) ~= 'string' then return end
    if OnRun() or InArena() then return end
    local area = type(call.areaLabel) == 'string' and call.areaLabel or CP.L('mc.county_wide')
    local text = CP.L(call.paged and 'mc.toast.paged' or 'mc.toast.new', {
        code = call.code,
        type = tostring(call.typeLabel or ''),
        priority = tostring(call.priority or ''),
        area = area,
    })
    if CP.Tablet and CP.Tablet.notify then
        CP.Tablet.notify('info', text, { title = CP.L('mc.toast.new_title') })
    end
    local now = GetGameTimer()
    if lastCueAt and now - lastCueAt < CUE_MIN_GAP_MS then return end
    lastCueAt = now
    PlaySoundFrontend(-1, SOUND_NAME, SOUND_SET, true)
end)

CreateThread(function()
    while true do
        Wait(WATCH_POLL_MS)
        local open = CP.Tablet ~= nil and CP.Tablet.isOpen ~= nil and CP.Tablet.isOpen() == true
        if wasOpen and not open then TriggerServerEvent(CP.e('server:mcWatch'), false) end
        wasOpen = open
    end
end)
