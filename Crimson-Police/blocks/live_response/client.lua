-- Objective block "live_response" (client half, step V12): the live_crime engine mission's objective. The server half

local BLOCK = 'live_response'
local RADIAL_ID = 'crimson-police:live_end_case'

local active = nil   -- { ctx, radial } of the current objective on this client

local function RemoveRadial()
    if active and active.radial then
        active.radial = false
        pcall(lib.removeRadialItem, RADIAL_ID)
    end
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
        active = { ctx = ctx, radial = false }
        SyncRadial()
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
            active = nil
        end
    end,
})

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    RemoveRadial()
    active = nil
end)
