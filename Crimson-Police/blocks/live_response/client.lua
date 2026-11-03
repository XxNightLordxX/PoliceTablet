-- Objective block "live_response" (client half): the live_crime engine mission's objective. The server half

-- Objective block "live_response" (client half): the live_crime engine mission's objective. The server half
-- decides everything from server facts (CP.Opponents); this half only offers the unit leader "End case" in the ox_lib
-- radial menu while the objective runs, with a confirm. The map pointer (the scene, then the last-reported points)
-- is CP.Markers' own, from the server's marker.

local BLOCK = 'live_response'
local RADIAL_ID = 'crimson-police:live_end_case'
local TALK_ID = 'crimson-police:live_talk_down'   -- Talk them down, for every officer of the case

local active = nil   -- { ctx, radial, talk } of the current objective on this client

local function RemoveRadial()
    if active and active.radial then
        active.radial = false
        pcall(lib.removeRadialItem, RADIAL_ID)
    end
end

-- Config.RealSuspects.surrender, behind Config.LiveCrime.enabled (the server checks it again on every use).
local function TalkOn()
    local rs = type(Config.RealSuspects) == 'table' and Config.RealSuspects or {}
    local s = type(rs.surrender) == 'table' and rs.surrender or {}
    return type(Config.LiveCrime) == 'table' and Config.LiveCrime.enabled == true and s.enabled ~= false
end

local function RemoveTalk()
    if active and active.talk then
        active.talk = false
        pcall(lib.removeRadialItem, TALK_ID)
    end
end

local function AddTalk()
    if not active or active.talk or not TalkOn() then return end
    active.talk = true
    pcall(lib.addRadialItem, {
        id = TALK_ID,
        icon = 'comments',
        label = CP.L('block.live_response.talk_radial'),
        onSelect = function() TriggerServerEvent(CP.e('server:liveTalkDown')) end,
    })
end

local function EndCase()
    local cur = active
    if not cur or not cur.ctx.isHost then return end
    local answer = lib.alertDialog({
        header = CP.L('block.live_response.end_title'),
        content = CP.L('block.live_response.end_confirm'),
        centered = true,
        cancel = true,
    })
    if answer == 'confirm' and active == cur then cur.ctx.report({ type = 'end_case' }) end
end

local function SyncRadial()
    if not active then return end
    local want = active.ctx.isHost == true
    if want and not active.radial then
        active.radial = true
        pcall(lib.addRadialItem, {
            id = RADIAL_ID,
            icon = 'flag-checkered',
            label = CP.L('block.live_response.end_radial'),
            onSelect = function() CreateThread(EndCase) end,
        })
    elseif not want then
        RemoveRadial()
    end
end

CP.Blocks.register(BLOCK, {
    prepare = function() end,

    start = function(ctx)
        RemoveRadial()
        RemoveTalk()
        active = { ctx = ctx, radial = false, talk = false }
        SyncRadial()
        AddTalk()
    end,

    update = function() end,

    hostChanged = function(ctx, isHost)
        if not active or active.ctx ~= ctx then return end
        ctx.isHost = isHost == true
        SyncRadial()
    end,

    stop = function(ctx)
        if active and active.ctx == ctx then
            RemoveRadial()
            RemoveTalk()
            active = nil
        end
    end,
})

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    RemoveRadial()
    RemoveTalk()
    active = nil
end)
