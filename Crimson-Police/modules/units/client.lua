-- CP.Units (client): the invite cue, the ready check toast and the crimsonpolice_ready key mapping.

CP.Units = CP.Units or {}
local Units = CP.Units

local CUE_MIN_GAP_MS = 3000          -- at most one sound per 3 s (several invites at once)
local SOUND_NAME = 'Text_Arrive_Tone'
local SOUND_SET = 'Phone_SoundSet_Default'
local READY_KEY = 'crimsonpolice_ready'
local LABEL_MAX = 64

local lastCueAt = nil
local pendingCheck = nil             -- { typeLabel, expiresAt (game timer ms) } while a ready check waits for us

function Units.lastInviteAt()
    return lastCueAt
end

function Units.pendingReadyCheck()
    if pendingCheck and GetGameTimer() >= pendingCheck.expiresAt then pendingCheck = nil end
    return pendingCheck
end

RegisterNetEvent(CP.e('client:push'), function(topic, data)
    if topic ~= 'unit' or type(data) ~= 'table' or data.invited ~= true then return end
    local now = GetGameTimer()
    if lastCueAt and now - lastCueAt < CUE_MIN_GAP_MS then return end
    lastCueAt = now
    PlaySoundFrontend(-1, SOUND_NAME, SOUND_SET, true)
end)

-- ============================================================================
--                                 READY CHECK
-- ============================================================================
-- The server asks every unit member "Ready for <type>?" (the type only, never the mission); nil clears it.

RegisterNetEvent(CP.e('client:readyCheck'), function(data)
    if type(data) ~= 'table' then
        pendingCheck = nil
        return
    end
    local label = type(data.typeLabel) == 'string' and data.typeLabel:sub(1, LABEL_MAX) or ''
    local seconds = math.max(1, math.floor(tonumber(data.expiresIn) or 20))
    local leader = type(data.leaderName) == 'string' and data.leaderName:sub(1, LABEL_MAX) or '?'
    pendingCheck = { typeLabel = label, expiresAt = GetGameTimer() + seconds * 1000 }
    PlaySoundFrontend(-1, SOUND_NAME, SOUND_SET, true)
    if not (CP.Tablet and CP.Tablet.notify) then return end
    CP.Tablet.notify('info', CP.L('unit.ready.toast', { type = label, leader = leader, seconds = seconds }), {
        title = CP.L('unit.ready.toast_title', { type = label }),
        duration = seconds * 1000,
    })
end)

-- The key answers Ready (no reply id: the result comes back as the unit push and the toasts).
RegisterCommand(READY_KEY, function()
    if not Units.pendingReadyCheck() then return end
    pendingCheck = nil
    TriggerServerEvent(CP.e('server:unitReady'), { accepted = true })
end, false)

CreateThread(function()
    local key = Config.Tablet and Config.Tablet.readyKey
    if type(key) ~= 'string' then key = '' end
    RegisterKeyMapping(READY_KEY, CP.L('unit.ready.keybind_label'), 'keyboard', key)
end)
