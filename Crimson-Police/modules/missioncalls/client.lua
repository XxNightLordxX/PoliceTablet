-- CP.MissionCalls (client): the new-call toast and tone. The tablet's own close (server:tabletClosed, modules/tablet)
-- tells the server to stop the Dispatch screen data.

CP.MissionCalls = CP.MissionCalls or {}
local MC = CP.MissionCalls

local SOUND_NAME = 'Event_Message_Purple'
local SOUND_SET = 'GTAO_FM_Events_Soundset'

local CUE_MIN_GAP_MS = 4000          -- at most one tone per 4 s (several calls at once)

-- The tone, unless the officer turned the mission call tone off on this PC (My options -> Sounds).
local function Tone()
    if CP.Options and CP.Options.sound then return CP.Options.sound('calls', SOUND_NAME, SOUND_SET, true) end
    PlaySoundFrontend(-1, SOUND_NAME, SOUND_SET, true)
end

local lastCueAt = nil

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
    -- step O11: "F6 opens Dispatch" when the Dispatch key is bound and the officer keeps the key hints on
    local key = CP.Options and CP.Options.keyHint and CP.Options.keyHint('crimsonpolice_dispatch')
    if key then text = text .. ' ' .. CP.L('mc.toast.dispatch_key', { key = key }) end
    if CP.Tablet and CP.Tablet.notify then
        CP.Tablet.notify('info', text, { title = CP.L('mc.toast.new_title') })
    end
    local now = GetGameTimer()
    if lastCueAt and now - lastCueAt < CUE_MIN_GAP_MS then return end
    lastCueAt = now
    Tone()
end)
