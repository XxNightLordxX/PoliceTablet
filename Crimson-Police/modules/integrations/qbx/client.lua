-- modules/integrations/qbx/client.lua · CP.Qbx (client): the only client code that talks to qbx_core.
--
-- Owns exports.qbx_core:GetPlayerData() and the qbx_core client events the tablet reacts to. These
-- client events are for the UI only; every decision about runs, roles and access stays on the server.
--
-- Public API (docs/ARCHITECTURE.md §5.1)
--   CP.Qbx.getPlayerData() -> PlayerData
--       A fresh copy from qbx_core every call ({} before a character is loaded or after logout, so
--       test 'pd.job', never just 'pd'). Display only: the server re-checks everything.
--   CP.Qbx.onJobUpdate(fn(job))
--       QBCore:Client:OnJobUpdate (job switch, grade change; PlayerData is already fresh), and
--       qbx_core:client:onGroupUpdate (a job or gang was added or removed: removing the active job
--       makes it 'unemployed' without an OnJobUpdate), which fires with the re-read PlayerData.job.
--   CP.Qbx.onDutyChange(fn(onDuty))
--       QBCore:Client:SetDuty. The boolean argument is passed on: PlayerData.job.onduty is still
--       stale inside that event (qbx_core sends SetDuty before the PlayerData update).
--   CP.Qbx.onUnload(fn())    QBCore:Client:OnPlayerUnload (character logout or switch; not on disconnect)
--   CP.Qbx.onLoaded(fn())    QBCore:Client:OnPlayerLoaded
-- Listeners run in their own thread; errors are caught and logged.

CP.Qbx = CP.Qbx or {}
local Q = CP.Qbx
local TAG = 'qbx'

local listeners = { job = {}, duty = {}, unload = {}, loaded = {} }

function Q.getPlayerData()
    if GetResourceState('qbx_core') ~= 'started' then return {} end
    local st = LocalPlayer and LocalPlayer.state
    if st and st.isLoggedIn == false then return {} end
    local ok, pd = pcall(function() return exports.qbx_core:GetPlayerData() end)
    if not ok then
        CP.err(TAG, 'exports.qbx_core:GetPlayerData failed: %s', tostring(pd))
        return {}
    end
    if type(pd) ~= 'table' then return {} end
    return pd
end

local function addListener(kind, fn)
    if type(fn) ~= 'function' then
        CP.warn(TAG, 'a %s listener must be a function (got %s)', kind, type(fn))
        return
    end
    local list = listeners[kind]
    list[#list + 1] = fn
end

local function emit(kind, ...)
    local list = listeners[kind]
    if #list == 0 then return end
    local args = table.pack(...)
    for i = 1, #list do
        local fn = list[i]
        CreateThread(function()
            local ok, err = pcall(fn, table.unpack(args, 1, args.n))
            if not ok then CP.err(TAG, '%s listener failed: %s', kind, tostring(err)) end
        end)
    end
end

function Q.onJobUpdate(fn) addListener('job', fn) end
function Q.onDutyChange(fn) addListener('duty', fn) end
function Q.onUnload(fn) addListener('unload', fn) end
function Q.onLoaded(fn) addListener('loaded', fn) end

RegisterNetEvent('QBCore:Client:OnJobUpdate', function(job)
    if type(job) ~= 'table' then
        local pd = Q.getPlayerData()
        job = pd.job
    end
    if type(job) ~= 'table' then return end
    CP.log(TAG, 'OnJobUpdate -> %s (on duty %s)', tostring(job.name), tostring(job.onduty))
    emit('job', job)
end)

RegisterNetEvent('qbx_core:client:onGroupUpdate', function(groupName, grade)
    -- Fires for gangs too; PlayerData.jobs syncs just before, a short wait is harmless.
    Wait(100)
    local pd = Q.getPlayerData()
    if type(pd.job) ~= 'table' then return end
    CP.log(TAG, 'onGroupUpdate %s -> %s; active job %s', tostring(groupName), tostring(grade), tostring(pd.job.name))
    emit('job', pd.job)
end)

RegisterNetEvent('QBCore:Client:SetDuty', function(onDuty)
    CP.log(TAG, 'SetDuty -> %s', tostring(onDuty))
    emit('duty', onDuty == true)
end)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    CP.log(TAG, 'OnPlayerUnload')
    emit('unload')
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    CP.log(TAG, 'OnPlayerLoaded')
    emit('loaded')
end)
