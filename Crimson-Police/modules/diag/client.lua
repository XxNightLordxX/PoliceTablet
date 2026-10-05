-- CP.Diag (client): the F8 command CrimsonPoliceState prints what holds the screen, the camera, the controls and the
-- NUI focus right now, and which part of it is Crimson-Police's; `CrimsonPoliceState unstick` undoes only ours.

CP.Diag = CP.Diag or {}
local Diag = CP.Diag
local TAG = 'diag'
local COMMAND = 'CrimsonPoliceState'

-- A native this client build may not have (or that raises) reads as unknown, never as an error.
local function Try(fn, ...)
    if type(fn) ~= 'function' then return nil end
    local ok, v = pcall(fn, ...)
    if ok then return v end
    return nil
end

local function YesNo(v)
    if v == nil then return '?' end
    return v and 'yes' or 'no'
end

local function Screen()
    if Try(IsScreenFadedOut) then return 'faded out (black)' end
    if Try(IsScreenFadingOut) then return 'fading out' end
    if Try(IsScreenFadingIn) then return 'fading in' end
    return 'faded in'
end

-- ============================================================================
--                                  THE STATE
-- ============================================================================

function Diag.state()
    local ped = PlayerPedId()
    local pd = CP.Qbx and CP.Qbx.getPlayerData and CP.Qbx.getPlayerData() or {}
    local md = type(pd) == 'table' and type(pd.metadata) == 'table' and pd.metadata or {}
    local run = CP.Runs and CP.Runs.current and CP.Runs.current() or nil
    local cam = Try(GetRenderingCam)
    return {
        screen = Screen(),
        nuiFocus = Try(IsNuiFocused),
        nuiKeepInput = Try(IsNuiFocusKeepingInput),
        tabletOpen = CP.Tablet and CP.Tablet.isOpen and CP.Tablet.isOpen() == true or false,
        panel = CP.Tablet and CP.Tablet.panelFocusOwner and CP.Tablet.panelFocusOwner() or nil,
        pickup = CP.Downed and CP.Downed.busy and CP.Downed.busy() == true or false,
        run = type(run) == 'table' and run.id or nil,
        scriptCam = cam ~= nil and cam ~= -1,
        playerControl = Try(IsPlayerControlOn, PlayerId()),
        frozen = Try(IsEntityPositionFrozen, ped),
        dead = Try(IsEntityDead, ped),
        lastStand = md.inlaststand == true,
        metaDead = md.isdead == true,
        inVehicle = Try(IsPedInAnyVehicle, ped, false),
        pauseMenu = Try(IsPauseMenuActive),
    }
end

-- What in the state is not Crimson-Police's, in plain words (the owner sends this line back).
local function Others(s)
    local out = {}
    if s.nuiFocus and not s.tabletOpen and not s.panel then
        out[#out + 1] = 'the NUI focus belongs to another resource'
    end
    if s.screen ~= 'faded in' and not s.pickup then out[#out + 1] = 'the fade is not Crimson-Police\'s' end
    if s.scriptCam then out[#out + 1] = 'a scripted camera renders (Crimson-Police has none)' end
    if s.playerControl == false then out[#out + 1] = 'player control is off (Crimson-Police never turns it off)' end
    if s.frozen then out[#out + 1] = 'the player is frozen (Crimson-Police never freezes the player)' end
    if s.lastStand or s.metaDead then out[#out + 1] = 'sc-ambulance still counts the player as down' end
    return out
end

local function Print(s)
    local lines = {
        ('screen %s, NUI focus %s (keep input %s), scripted camera %s, pause menu %s'):format(s.screen,
            YesNo(s.nuiFocus), YesNo(s.nuiKeepInput), YesNo(s.scriptCam), YesNo(s.pauseMenu)),
        ('player: control %s, frozen %s, dead %s, last stand %s, metadata dead %s, in a vehicle %s'):format(
            YesNo(s.playerControl), YesNo(s.frozen), YesNo(s.dead), YesNo(s.lastStand), YesNo(s.metaDead),
            YesNo(s.inVehicle)),
        ('Crimson-Police: tablet %s, panel focus %s, pick-up %s, run %s'):format(s.tabletOpen and 'open' or 'closed',
            tostring(s.panel or 'none'), s.pickup and 'running' or 'idle', tostring(s.run or 'none')),
    }
    local others = Others(s)
    lines[#lines + 1] = #others > 0 and ('not ours: ' .. table.concat(others, '; ')) or 'nothing stuck'
    for _, l in ipairs(lines) do print(('[crimson-police:%s] %s'):format(TAG, l)) end
    return lines
end

-- Only what Crimson-Police holds: the tablet (and its NUI focus), a panel's focus, a pick-up fade left over.
function Diag.unstick()
    if CP.Tablet and CP.Tablet.isOpen and CP.Tablet.isOpen() then CP.Tablet.close() end
    local owner = CP.Tablet and CP.Tablet.panelFocusOwner and CP.Tablet.panelFocusOwner()
    if owner then CP.Tablet.panelFocus(owner, false) end
    if CP.Downed and CP.Downed.restore then CP.Downed.restore('unstick') end
    CP.log(TAG, 'Crimson-Police\'s own screen, focus and overlay released')
end

-- Admin UI → Officers → Support: an admin released this player's screen, or asked what holds it (server events;
-- only the server sends them, and only Crimson-Police's own focus, camera and freeze are touched).
RegisterNetEvent(CP.e('client:diagUnstick'), function()
    Diag.unstick()
    CP.log(TAG, 'an admin released Crimson-Police\'s screen')
end)

RegisterNetEvent(CP.e('client:diagState'), function(token)
    if type(token) ~= 'string' or #token > 64 then return end
    TriggerServerEvent(CP.e('server:diagState'), token, Diag.state())
end)

RegisterCommand(COMMAND, function(_, args)
    if type(args) == 'table' and args[1] == 'unstick' then Diag.unstick() end
    Print(Diag.state())
end, false)
