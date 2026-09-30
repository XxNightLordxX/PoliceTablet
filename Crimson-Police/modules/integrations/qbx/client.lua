-- CP.Qbx (client): the only client code that talks to qbx_core.

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

local function AddListener(kind, fn)
    if type(fn) ~= 'function' then
        CP.warn(TAG, 'a %s listener must be a function (got %s)', kind, type(fn))
        return
    end
    local list = listeners[kind]
    list[#list + 1] = fn
end

local function Emit(kind, ...)
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

function Q.onJobUpdate(fn) AddListener('job', fn) end
function Q.onDutyChange(fn) AddListener('duty', fn) end
function Q.onUnload(fn) AddListener('unload', fn) end
function Q.onLoaded(fn) AddListener('loaded', fn) end

RegisterNetEvent('QBCore:Client:OnJobUpdate', function(job)
    if type(job) ~= 'table' then
        local pd = Q.getPlayerData()
        job = pd.job
    end
    if type(job) ~= 'table' then return end
    CP.log(TAG, 'OnJobUpdate -> %s (on duty %s)', tostring(job.name), tostring(job.onduty))
    Emit('job', job)
end)

RegisterNetEvent('qbx_core:client:onGroupUpdate', function(groupName, grade)
    -- Fires for gangs too; PlayerData.jobs syncs just before, a short wait is harmless.
    Wait(100)
    local pd = Q.getPlayerData()
    if type(pd.job) ~= 'table' then return end
    CP.log(TAG, 'onGroupUpdate %s -> %s; active job %s', tostring(groupName), tostring(grade), tostring(pd.job.name))
    Emit('job', pd.job)
end)

RegisterNetEvent('QBCore:Client:SetDuty', function(onDuty)
    CP.log(TAG, 'SetDuty -> %s', tostring(onDuty))
    Emit('duty', onDuty == true)
end)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    CP.log(TAG, 'OnPlayerUnload')
    Emit('unload')
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    CP.log(TAG, 'OnPlayerLoaded')
    Emit('loaded')
end)
