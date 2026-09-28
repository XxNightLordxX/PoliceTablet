-- modules/operations/client.lua · CP.Operations (client): the Cross-Department Mission toast.
--
-- The server (modules/operations/server.lua) sends crimson-police:client:operation to every on-duty
-- officer of every department when an operation is launched (or relaunched), when its run starts, when
-- it ends Completed and when it is cancelled. This half turns that into a Crimson-Police toast
-- (CP.Tablet.notify with translated text; the Mission Board refreshes itself from the 'board' push).
-- Nothing is created in the game world, so there is nothing to clean up on resource stop.
--
-- Public API (client)
--   CP.Operations.last() -> { state, missionLabel, id, at } | nil   the last operation event received
-- Events handled: crimson-police:client:operation (state, missionLabel, extra = { id, relaunched })

CP.Operations = CP.Operations or {}
local Ops = CP.Operations

local TOASTS = {
    launched  = { kind = 'info',    key = 'officer.op.toast_launched',  duration = 12000 },
    relaunch  = { kind = 'info',    key = 'officer.op.toast_relaunched', duration = 12000 },
    started   = { kind = 'info',    key = 'officer.op.toast_started',   duration = 7000 },
    ended     = { kind = 'success', key = 'officer.op.toast_ended',     duration = 7000 },
    cancelled = { kind = 'warning', key = 'officer.op.toast_cancelled', duration = 7000 },
}
local LABEL_MAX = 64

local last = nil

function Ops.last()
    return last
end

RegisterNetEvent(CP.e('client:operation'), function(state, missionLabel, extra)
    if type(state) ~= 'string' or not TOASTS[state] then return end
    if type(missionLabel) ~= 'string' then missionLabel = '' end
    missionLabel = missionLabel:sub(1, LABEL_MAX)
    extra = type(extra) == 'table' and extra or {}
    last = { state = state, missionLabel = missionLabel, id = tonumber(extra.id), at = GetGameTimer() }

    local toast = TOASTS[state]
    if state == 'launched' and extra.relaunched == true then toast = TOASTS.relaunch end
    if not (CP.Tablet and CP.Tablet.notify) then return end
    CP.Tablet.notify(toast.kind, CP.L(toast.key, { mission = missionLabel }), {
        title = CP.L('officer.op.toast_title'),
        duration = toast.duration,
    })
end)
