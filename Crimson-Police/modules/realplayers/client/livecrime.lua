-- CP.LiveCrime (client): the pop-up that asks an officer to join a live case as backup. The server decides

-- CP.LiveCrime (client): the pop-up that asks an officer to join a live case as backup. The server decides
-- who is asked (a response to the crime's call, the scene, a cuff on a suspect) and checks the answer again; this
-- side only shows the question and sends yes or no with the offer's token. The same for a suspect's
-- surrender question (his own command, or an officer's Talk them down).

local open = nil   -- the offer whose pop-up is showing: { runId, token }
local asked = nil  -- the surrender question showing: { token }
-- the newest offer that came while another pop-up was showing: { offer, untilMs }. It shows once that pop-up closes,
-- while it has not run out (two live cases at once: the second offer is not lost).
local waiting = nil
local Show

local function Answer(offer, yes)
    TriggerServerEvent(CP.e('server:liveJoin'), offer.runId, offer.token, yes == true)
end

-- The offer's seconds as the server sent them, kept between 5 and 120 (a broken number reads as 30).
local function Seconds(v, default)
    local n = tonumber(v)
    if not n or n ~= n or n == math.huge or n == -math.huge then n = default end
    return math.floor(math.min(120, math.max(5, n)))
end

-- The waiting offer, once no pop-up shows, with the time it has left (at least 5 s, else it is dropped).
local function ShowWaiting()
    local w = waiting
    if not w or open or asked then return end
    waiting = nil
    local left = (w.untilMs - GetGameTimer()) // 1000
    if left < 5 then return end
    Show(w.offer, left)
end

Show = function(offer, seconds)
    open = { runId = offer.runId, token = offer.token }
    local mine = open
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
        ShowWaiting()
    end)
end

RegisterNetEvent(CP.e('client:liveJoinOffer'), function(offer)
    if type(offer) ~= 'table' or type(offer.runId) ~= 'string' or type(offer.token) ~= 'string' then return end
    if #offer.runId > 64 or #offer.token > 64 then return end
    local seconds = Seconds(offer.seconds, 30)
    if open or asked then
        -- the same case again (a newer token) or another case: only the newest offer waits
        if not (open and open.runId == offer.runId and open.token == offer.token) then
            waiting = { offer = offer, untilMs = GetGameTimer() + seconds * 1000 }
        end
        return
    end
    Show(offer, seconds)
end)

RegisterNetEvent(CP.e('client:liveSurrenderAsk'), function(q)
    if type(q) ~= 'table' or type(q.token) ~= 'string' then return end
    if asked or open then return end
    asked = { token = q.token }
    local mine = asked
    local seconds = Seconds(q.seconds, 20)
    SetTimeout(seconds * 1000, function()
        if asked == mine then pcall(lib.closeAlertDialog) end
    end)
    CreateThread(function()
        local which = q.talk == true and 'talk' or 'self'
        local answer = lib.alertDialog({
            header = CP.L('livecrime.surrender.ask_title_' .. which),
            content = CP.L('livecrime.surrender.ask_content_' .. which),
            centered = true,
            cancel = true,
        })
        if asked == mine then asked = nil end
        TriggerServerEvent(CP.e('server:liveSurrender'), mine.token, answer == 'confirm')
        ShowWaiting()
    end)
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() or not (open or asked) then return end
    open, asked, waiting = nil, nil, nil
    pcall(lib.closeAlertDialog)
end)
