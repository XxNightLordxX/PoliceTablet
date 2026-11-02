-- CP.Units (client): the invite cue, the ready check toast and the crimsonpolice_ready key mapping.

-- modules/units/client.lua · CP.Units (client): the invite cue.
--
-- Units live on the server (modules/units/server.lua). The Unit screen (NUI) lists members, invites
-- and the invite picker, and every answer goes through the tablet (server:unitRespond). This half only
-- makes an incoming invite noticeable while the tablet is closed: the server's toast
-- (CP.Tablet.notify 'unit.invite_received', rendered by modules/tablet) is paired with a short frontend
-- sound when the 'unit' push for this player carries { invited = true }. Nothing is created in the game
-- world, so there is nothing to clean up on resource stop.
--
-- Public API (client)
--   CP.Units.lastInviteAt() -> GetGameTimer() of the last invite cue, or nil
-- Events handled: crimson-police:client:push (topic 'unit' only; the tablet module forwards every push
-- to the NUI itself, this handler never touches the NUI).

CP.Units = CP.Units or {}
local Units = CP.Units

local CUE_MIN_GAP_MS = 3000          -- at most one sound per 3 s (several invites at once)
local SOUND_NAME = 'Text_Arrive_Tone'
local SOUND_SET = 'Phone_SoundSet_Default'

local READY_KEY = 'crimsonpolice_ready'
local LABEL_MAX = 64
local SETTINGS_WAIT_MS = 10000       -- the key waits this long at most for the settings changed in game

-- The tone, unless the officer turned the unit tone off on this PC (My options -> Sounds).
local function Tone()
    if CP.Options and CP.Options.sound then return CP.Options.sound('unit', SOUND_NAME, SOUND_SET, true) end
    PlaySoundFrontend(-1, SOUND_NAME, SOUND_SET, true)
end

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
    Tone()
end)

-- ============================================================================
--                                 READY CHECK
-- ============================================================================
-- The server asks every unit member "Ready for <type>?" (the type only, never the mission); nil clears it.

local AUTO_READY_INPUT_MS = 60000   -- Auto-Ready answers only after game input within this long

-- Auto-Ready (My options -> Unit): on, not in the pause menu and at the keys. The server still checks the
-- department, the option and the distance to the leader; an answer it does not count leaves the banner asking.
function Units.autoReadyNow()
    if not (CP.Options and CP.Options.get and CP.Options.get('autoReady') == true) then return false end
    if IsPauseMenuActive() then return false end
    return CP.Options.activeWithin ~= nil and CP.Options.activeWithin(AUTO_READY_INPUT_MS)
end

RegisterNetEvent(CP.e('client:readyCheck'), function(data)
    if type(data) ~= 'table' then
        pendingCheck = nil
        return
    end
    local label = type(data.typeLabel) == 'string' and data.typeLabel:sub(1, LABEL_MAX) or ''
    local seconds = math.max(1, math.floor(tonumber(data.expiresIn) or 20))
    local leader = type(data.leaderName) == 'string' and data.leaderName:sub(1, LABEL_MAX) or '?'
    -- the twists the leader chose: named in the toast
    local names = {}
    for _, t in ipairs(type(data.twists) == 'table' and data.twists or {}) do
        if type(t) == 'table' and type(t.label) == 'string' and #names < 3 then
            names[#names + 1] = t.label:sub(1, LABEL_MAX)
        end
    end
    pendingCheck = { typeLabel = label, expiresAt = GetGameTimer() + seconds * 1000 }
    Tone()
    if Units.autoReadyNow() then TriggerServerEvent(CP.e('server:unitReady'), { accepted = true, auto = true }) end
    if not (CP.Tablet and CP.Tablet.notify) then return end
    local vars = { type = label, leader = leader, seconds = seconds, twists = table.concat(names, ', ') }
    -- a live case: the LIVE line names the reported crime and its suspect count, as a red toast
    local live = type(data.live) == 'table' and data.live or nil
    if live then
        vars.title = type(live.title) == 'string' and live.title:sub(1, LABEL_MAX) or label
        vars.street = type(live.street) == 'string' and live.street:sub(1, LABEL_MAX) or '-'
        vars.n = math.max(1, math.floor(tonumber(live.suspects) or 1))
        CP.Tablet.notify('error', CP.L('unit.ready.toast_live', vars), {
            title = CP.L('unit.ready.toast_live_title'),
            duration = seconds * 1000,
        })
        return
    end
    CP.Tablet.notify('info', CP.L(#names > 0 and 'unit.ready.toast_twists' or 'unit.ready.toast', vars), {
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
    if CP.Settings and CP.Settings.ready then CP.Settings.ready(SETTINGS_WAIT_MS) end
    local key = Config.Tablet and Config.Tablet.readyKey
    if type(key) ~= 'string' then key = '' end
    RegisterKeyMapping(READY_KEY, CP.L('unit.ready.keybind_label'), 'keyboard', key)
end)
