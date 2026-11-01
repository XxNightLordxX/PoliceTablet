-- CP.LiveCrime (client, step V15): the pop-up that asks an officer to join a live case as backup. The server decides
-- who is asked (a response to the crime's call, the scene, a cuff on a suspect) and checks the answer again; this
-- side only shows the question and sends yes or no with the offer's token.

local open = nil   -- the offer whose pop-up is showing: { runId, token }

local function Answer(offer, yes)
    TriggerServerEvent(CP.e('server:liveJoin'), offer.runId, offer.token, yes == true)
end

RegisterNetEvent(CP.e('client:liveJoinOffer'), function(offer)
    if type(offer) ~= 'table' or type(offer.runId) ~= 'string' or type(offer.token) ~= 'string' then return end
    if open then return end
    open = { runId = offer.runId, token = offer.token }
    local mine = open
    local seconds = math.max(5, math.floor(tonumber(offer.seconds) or 30))
    -- the dialog closes by itself when the offer runs out (the server refuses a late yes anyway)
    SetTimeout(seconds * 1000, function()
        if open == mine then pcall(lib.closeAlertDialog) end
    end)
    CreateThread(function()
        local answer = lib.alertDialog({
            header = CP.L('livecrime.join.title'),
            content = CP.L('livecrime.join.content', {
                title = type(offer.title) == 'string' and offer.title or '',
                street = type(offer.street) == 'string' and offer.street or '-',
            }),
            centered = true,
            cancel = true,
        })
        if open == mine then open = nil end
        Answer(mine, answer == 'confirm')
    end)
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() or not open then return end
    open = nil
    pcall(lib.closeAlertDialog)
end)
