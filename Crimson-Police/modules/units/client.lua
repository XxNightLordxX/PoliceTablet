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

local lastCueAt = nil

function Units.lastInviteAt()
    return lastCueAt
end

RegisterNetEvent(CP.e('client:push'), function(topic, data)
    if topic ~= 'unit' or type(data) ~= 'table' or data.invited ~= true then return end
    local now = GetGameTimer()
    if lastCueAt and now - lastCueAt < CUE_MIN_GAP_MS then return end
    lastCueAt = now
    PlaySoundFrontend(-1, SOUND_NAME, SOUND_SET, true)
end)
