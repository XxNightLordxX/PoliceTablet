-- The client halves of live cases and tours, driven with edge payloads: the pop-ups, the radial and the tours.

-- The client halves of live cases and tours, driven with edge payloads: the join and surrender pop-ups
-- (modules/realplayers/client/livecrime.lua), the End case and Talk them down radial items
-- (blocks/live_response/client.lua) and the tour landing (modules/access/client/training.lua). The server specs
-- (live_join_spec, live_surrender_spec, training_spec) check what the server sends; this spec checks what the client
-- does with it and what it sends back.

local H = dofile('tests/harness.lua')
H.boot({ side = 'client', realLocale = true })

-- ox_lib's alertDialog as in game: one dialog at a time, the calling thread waits until it closes. close(answer)
-- answers the oldest one showing; closeAlertDialog (the timeout) answers it with nil.
local dialogs = {}
lib.alertDialog = function(opts)
    local d = { opts = opts, co = coroutine.running() }
    dialogs[#dialogs + 1] = d
    return coroutine.yield()
end
local function Showing()
    local n = 0
    for _, d in ipairs(dialogs) do if not d.done then n = n + 1 end end
    return n
end
local function Close(answer)
    for _, d in ipairs(dialogs) do
        if not d.done then
            d.done = true
            local ok, err = coroutine.resume(d.co, answer)
            if not ok then error(err, 0) end
            return d
        end
    end
end
lib.closeAlertDialog = function() Close(nil) end
local radial = {}
lib.addRadialItem = function(item) radial[item.id] = item end
lib.removeRadialItem = function(id) radial[id] = nil end

local function Sent(name)
    local out = {}
    for _, e in ipairs(H.events) do
        if e.kind == 'server' and e.name == 'crimson-police:' .. name then out[#out + 1] = e.args end
    end
    return out
end
local function Reset()
    while Showing() > 0 do Close('cancel') end
    H.events = {}
    dialogs = {}
end

H.load('modules/realplayers/client/livecrime.lua')
local OFFER, ASK = 'crimson-police:client:liveJoinOffer', 'crimson-police:client:liveSurrenderAsk'

-- ============================================================================
--                       1. THE JOIN POP-UP: BAD PAYLOADS
-- ============================================================================

do
    for _, bad in ipairs({
        false,
        'x',
        42,
        {},
        { runId = 'A' },
        { token = 't' },
        { runId = 1, token = 't' },
        { runId = 'A', token = {} },
        { runId = ('r'):rep(65), token = 't' },
        { runId = 'A', token = ('t'):rep(65) },
    }) do
        H.fire(OFFER, nil, bad)
    end
    H.fire(OFFER, nil, nil)
    H.eq(#dialogs, 0, 'a nil, non-table or broken offer shows no pop-up')
    H.eq(#Sent('server:liveJoin'), 0, '...and sends nothing')
end

-- seconds: negative, NaN, huge, inf and a string all show a pop-up that closes by itself within 5..120 s
for _, secs in ipairs({ -10, 0 / 0, 1e300, math.huge, -math.huge, 'soon', 2.7 }) do
    Reset()
    H.fire(OFFER, nil, { runId = 'S', token = 'tS', seconds = secs, title = 7, street = {} })
    H.eq(Showing(), 1, ('seconds %s: the pop-up shows'):format(tostring(secs)))
    H.ok(dialogs[1] and dialogs[1].opts.content:find('-', 1, true) ~= nil,
        'a title or street that is not text reads as empty or -')
    H.advance(121000, 1000)
    H.eq(Showing(), 0, ('seconds %s: it closes by itself within 120 s'):format(tostring(secs)))
    local s = Sent('server:liveJoin')
    H.ok(#s == 1 and s[1][1] == 'S' and s[1][2] == 'tS' and s[1][3] == false, '...and answers no once')
end

-- ============================================================================
--                   2. TWO OFFERS IN A ROW (TWO LIVE CASES)
-- ============================================================================

do
    Reset()
    H.fire(OFFER, nil, { runId = 'A', token = 'tA', seconds = 30 })
    H.fire(OFFER, nil, { runId = 'B', token = 'tB', seconds = 30 })
    H.eq(Showing(), 1, 'one pop-up at a time')
    H.advance(2000, 1000)
    Close('cancel')
    local s = Sent('server:liveJoin')
    H.ok(#s == 1 and s[1][1] == 'A' and s[1][3] == false, 'A answered no')
    H.eq(Showing(), 1, 'the second offer shows once the first pop-up closes')
    H.ok(dialogs[2] ~= nil, 'B was shown')
    Close('confirm')
    s = Sent('server:liveJoin')
    H.ok(#s == 2 and s[2][1] == 'B' and s[2][2] == 'tB' and s[2][3] == true, 'B answered yes with its own token')

    -- the same offer twice (a resend) stays one pop-up and one answer
    Reset()
    H.fire(OFFER, nil, { runId = 'A', token = 'tA', seconds = 30 })
    H.fire(OFFER, nil, { runId = 'A', token = 'tA', seconds = 30 })
    Close('cancel')
    H.eq(Showing(), 0, 'the same offer twice: one pop-up')
    H.eq(#Sent('server:liveJoin'), 1, '...and one answer')

    -- three offers: only the newest waits
    Reset()
    H.fire(OFFER, nil, { runId = 'A', token = 'tA', seconds = 30 })
    H.fire(OFFER, nil, { runId = 'B', token = 'tB', seconds = 30 })
    H.fire(OFFER, nil, { runId = 'C', token = 'tC', seconds = 30 })
    Close('cancel')
    H.ok(dialogs[2] ~= nil and Showing() == 1, 'after A, one more pop-up')
    Close('confirm')
    s = Sent('server:liveJoin')
    H.ok(#s == 2 and s[2][1] == 'C', 'the newest offer (C) is the one that waited')

    -- a waiting offer that ran out is dropped, not shown late
    Reset()
    H.fire(OFFER, nil, { runId = 'A', token = 'tA', seconds = 30 })
    H.fire(OFFER, nil, { runId = 'B', token = 'tB', seconds = 10 })
    H.advance(31000, 1000)
    H.eq(Showing(), 0, 'B ran out while A showed: nothing shows after A')
    s = Sent('server:liveJoin')
    H.ok(#s == 1 and s[1][1] == 'A', '...and only A was answered')
end

-- ============================================================================
--                          3. THE SURRENDER QUESTION
-- ============================================================================

do
    Reset()
    for _, bad in ipairs({ false, 'x', {}, { token = 5 } }) do H.fire(ASK, nil, bad) end
    H.fire(ASK, nil, nil)
    H.eq(#dialogs, 0, 'a broken surrender question shows nothing')

    H.fire(ASK, nil, { token = 'q1', seconds = 0 / 0, talk = true })
    H.eq(Showing(), 1, 'the question shows')
    H.fire(ASK, nil, { token = 'q2' })
    H.eq(Showing(), 1, 'a second question while one shows: still one pop-up')
    -- a join offer while the question shows waits for it (never two dialogs at once)
    H.fire(OFFER, nil, { runId = 'A', token = 'tA', seconds = 30 })
    H.eq(Showing(), 1, 'a join offer while the question shows: still one pop-up')
    Close('confirm')
    local s = Sent('server:liveSurrender')
    H.ok(#s == 1 and s[1][1] == 'q1' and s[1][2] == true, 'the question answered yes with its token')
    H.eq(Showing(), 1, 'the join offer shows after the question')
    Close('cancel')
    H.eq(#Sent('server:liveJoin'), 1, '...and is answered')

    Reset()
    H.fire(ASK, nil, { token = 'q3', seconds = -5 })
    H.advance(6000, 1000)
    H.eq(Showing(), 0, 'a negative time: the question still closes by itself (5 s)')
    s = Sent('server:liveSurrender')
    H.ok(#s == 1 and s[1][2] == false, '...answered no')
end

-- ============================================================================
--                    4. A RESOURCE STOP WITH A POP-UP OPEN
-- ============================================================================

do
    Reset()
    H.fire(OFFER, nil, { runId = 'A', token = 'tA', seconds = 30 })
    H.fire(OFFER, nil, { runId = 'B', token = 'tB', seconds = 30 })
    H.fire('onResourceStop', nil, 'some-other-resource')
    H.eq(Showing(), 1, 'another resource stopping leaves the pop-up')
    H.fire('onResourceStop', nil, 'Crimson-Police')
    H.eq(Showing(), 0, 'its own stop closes the pop-up')
    H.eq(Showing(), 0, '...and the waiting offer does not show after it')
end

-- ============================================================================
--                   5. END CASE AND TALK THEM DOWN (RADIAL)
-- ============================================================================

do
    Reset()
    H.load('blocks/_kit/client.lua')
    H.load('blocks/live_response/client.lua')
    local B = CP.Blocks.get('live_response')
    H.ok(B and B.start and B.stop and B.hostChanged, 'the live_response client half is registered')
    local reports = {}
    local ctx = {
        isHost = false,
        report = function(r) reports[#reports + 1] = r end,
    }
    B.start(ctx)
    H.eq(radial['crimson-police:live_end_case'], nil, 'not the host: no End case')
    B.hostChanged(ctx, true)
    H.ok(radial['crimson-police:live_end_case'] ~= nil, 'made host: End case added')
    B.hostChanged(ctx, true)
    B.hostChanged({ isHost = true }, false)
    H.ok(radial['crimson-police:live_end_case'] ~= nil, 'another objective\'s host change is ignored')
    radial['crimson-police:live_end_case'].onSelect()
    H.eq(Showing(), 1, 'End case asks first')
    Close('cancel')
    H.eq(#reports, 0, 'cancel: nothing reported')
    radial['crimson-police:live_end_case'].onSelect()
    B.hostChanged(ctx, 'yes')
    H.eq(radial['crimson-police:live_end_case'], nil, 'host lost (any value but true): End case removed')
    Close('confirm')
    H.eq(#reports, 0, 'no longer host when it was confirmed: nothing reported')
    B.hostChanged(ctx, true)
    radial['crimson-police:live_end_case'].onSelect()
    Close('confirm')
    H.ok(#reports == 1 and reports[1].type == 'end_case', 'the host confirms: end_case reported')
    B.stop({})
    H.ok(radial['crimson-police:live_end_case'] ~= nil, 'stop of another objective leaves the items')
    B.stop(ctx)
    H.eq(radial['crimson-police:live_end_case'], nil, 'stop removes End case')
    H.eq(radial['crimson-police:live_talk_down'], nil, '...and Talk them down')
    B.start(ctx)
    H.fire('onResourceStop', nil, 'Crimson-Police')
    H.eq(radial['crimson-police:live_end_case'], nil, 'the resource stop removes the radial items')
end

-- ============================================================================
--                             6. THE TOUR LANDING
-- ============================================================================

do
    local opened, sent, crim = {}, {}, {}
    CP.Tablet = CP.Tablet or {}
    local ui = nil
    CP.Tablet.openUi = function() return ui end
    CP.Tablet.open = function(which) opened[#opened + 1] = which; return which ~= 'supervisor' end
    CP.Tablet.send = function(msg) sent[#sent + 1] = msg end
    CP.CrimTab = {
        open = function() crim[#crim + 1] = true; return true end,
    }
    H.load('modules/access/client/training.lua')
    local TOUR = 'crimson-police:client:startTour'
    for _, bad in ipairs({ false, 5, {}, ('o'):rep(17), 'nonsense', '' }) do H.fire(TOUR, nil, bad) end
    H.fire(TOUR, nil, nil)
    H.eq(#sent, 0, 'an unknown, overlong or non-text tour sends nothing to the page')
    H.eq(#opened + #crim, 0, '...and opens no tablet')
    H.fire(TOUR, nil, 'officer')
    H.ok(#opened == 1 and sent[1] and sent[1].tour == 'officer', 'officer: the tablet opens and the tour starts')
    ui = 'officer'
    H.fire(TOUR, nil, 'officer')
    H.ok(#opened == 1 and #sent == 2, 'the tablet already open: no second open, the tour starts')
    ui = nil
    H.fire(TOUR, nil, 'supervisor')
    H.eq(#sent, 2, 'the tablet could not open: no tour')
    H.fire(TOUR, nil, 'criminal')
    H.ok(#crim == 1 and sent[3] and sent[3].tour == 'criminal', 'criminal: the criminal tablet')
    CP.CrimTab = nil
    H.fire(TOUR, nil, 'criminal')
    H.eq(#sent, 3, 'no criminal tablet loaded: no tour')
    H.fire(TOUR, nil, 'run')
    H.fire(TOUR, nil, 'admin')
    H.ok(#sent == 5 and #opened == 2, 'run and admin: no tablet opened here, the tour is sent')
end

return H
