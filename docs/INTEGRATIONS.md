# Crimson-Police · verified integration facts

Every fact below was checked against the uploaded copies of the dependency resources (file:line evidence).
Implementers of `modules/integrations/*` (and anyone relying on them) must follow the **Implication** lines.
Where a fact says the spec is wrong or incomplete, this file wins over the spec Appendix.

## sc-multijob

### Holding jobs: PlayerData.jobs shape and the 5-job limit  _(spec claim: partial)_

- **Spec claim:** A player holds up to 5 jobs in PlayerData.jobs; PlayerData.job is the active one
- **Evidence:** sc-multijob/config.lua:3-5; sc-multijob/client/client.lua:25-44; sc-multijob/server/server.lua:34; qbx_core server/player.lua:6, :314-319; qbx_core types.lua:41; qbx_core server/player.lua:281-291
- **Implication:** PlayerData.jobs maps job name to grade level, e.g. { police = 3, sast = 1 }. It is keyed by name, it is not an array, and it never contains 'unemployed'. Config.MaxJobs is never read by any code in sc-multijob. The real limit is the qbx convar qbx:max_jobs_per_player, which defaults to 1 and only becomes 5 if server.cfg sets it. Crimson-Police must not hard-code 5 and must never grant access from PlayerData.jobs. Access comes only from PlayerData.job.name (the active job), which is exactly what the spec's 'holding sast as a second job gives no access' test checks.

```lua
config.lua:
-- Maximum number of jobs a player can hold at once
-- NOTE: You must also set this in server.cfg: set qbx:max_jobs_per_player 5
Config.MaxJobs = 5

client.lua:26: for jobName, gradeLevel in pairs(playerData.jobs) do
server.lua:34: if not player.PlayerData.jobs[jobName] then

qbx_core server/player.lua:6: local maxJobsPerPlayer = GetConvarInt('qbx:max_jobs_per_player', 1)
qbx_core types.lua:41: ---@field jobs table<string, integer>
qbx_core AddPlayerToJob: if jobName == 'unemployed' then return false, { code = 'unemployed', ... }
```

### Shape of the active job (PlayerData.job)

- **Spec claim:** PlayerData.job is the active one (job.name, job.label, job.grade.level, job.grade.name, job.onduty, job.type)
- **Evidence:** qbx_core server/player.lua:217-231 (toPlayerJob); sc-multijob/server/server.lua:16, :44; sc-multijob/html/script.js:60-74
- **Implication:** Read the rank from job.grade.name and the level from job.grade.level (an integer), duty from job.onduty (a boolean) and department type from job.type (police is 'leo' in qbx's default shared/jobs.lua). This same table is the second argument of QBCore:Server:OnJobUpdate.

```lua
return {
    name = jobName,
    label = job.label,
    isboss = job.grades[grade].isboss or false,
    bankAuth = job.grades[grade].bankAuth or false,
    onduty = job.defaultDuty or false,
    payment = job.grades[grade].payment or 0,
    type = job.type,
    grade = {
        name = job.grades[grade].name,
        level = grade
    }
}
```

### switchJob calls exports.qbx_core:SetPlayerPrimaryJob

- **Spec claim:** sc-multijob:server:switchJob calls exports.qbx_core:SetPlayerPrimaryJob
- **Evidence:** sc-multijob/server/server.lua:24-69; sc-multijob/client/client.lua:125-130
- **Implication:** The export is called as (citizenid, jobName), with citizenid first and the job name lower-cased. A switch to the job that is already active is refused before qbx_core is called, so every successful switch changes job.name. sc-multijob fires no event of its own after the switch; it only sends ox_lib:notify to the client. Crimson-Police must detect the switch through qbx_core's events (see the next fact), never through sc-multijob's net event, which is an unvalidated client request.

```lua
RegisterNetEvent('sc-multijob:server:switchJob', function(jobName)
    local src = source
    local player = getPlayer(src)          -- exports.qbx_core:GetPlayer(src)
    if not player then return end
    if type(jobName) ~= 'string' or jobName == '' then return end
    jobName = jobName:lower()
    if not player.PlayerData.jobs[jobName] then ... notify 'You don\'t have that job.' return end
    if player.PlayerData.job.name == jobName then ... notify 'This is already your active job.' return end
    local success, err = exports.qbx_core:SetPlayerPrimaryJob(player.PlayerData.citizenid, jobName)
    ...
end)
```

### Events qbx_core fires when SetPlayerPrimaryJob succeeds (the switch)

- **Spec claim:** (Focus) Which qbx_core events fire on a switch: QBCore:Client:OnJobUpdate, qbx_core:client:onGroupUpdate, QBCore:Server:OnJobUpdate and so on
- **Evidence:** qbx_core server/player.lua:238-271, :1140-1145 (UpdatePlayerData)
- **Implication:** On a successful online switch, these fire in this order: (1) the server-local QBCore:Player:SetPlayerData(PlayerData), plus the same event to the client; (2) the server-local QBCore:Server:OnJobUpdate(src, newJob); (3) the client event QBCore:Client:OnJobUpdate(newJob). qbx_core:server:onGroupUpdate and qbx_core:client:onGroupUpdate do not fire on a switch; they fire only when a job is added or removed. QBCore:Server:SetDuty and QBCore:Client:SetDuty do not fire either. The payload holds only the new job, with no old job, so Crimson-Police must store each participant's job name when they join the run and compare it with job.name. PlayerData is already updated when the event fires, so exports.qbx_core:GetPlayer(src).PlayerData.job inside the handler is the new job.

```lua
function SetPlayerPrimaryJob(citizenid, jobName)
    local player = getLoadedOrOfflinePlayer(citizenid)
    ...
    local grade = jobName == 'unemployed' and 0 or player.PlayerData.jobs[jobName]
    ...
    player.PlayerData.job = toPlayerJob(jobName, job, grade)
    if player.Offline then
        SaveOffline(player.PlayerData)
    else
        Save(player.PlayerData.source)
        UpdatePlayerData(player.PlayerData.source)   -- TriggerEvent('QBCore:Player:SetPlayerData', player.PlayerData) + TriggerClientEvent(same, src, PlayerData)
        TriggerEvent('QBCore:Server:OnJobUpdate', player.PlayerData.source, player.PlayerData.job)
        TriggerClientEvent('QBCore:Client:OnJobUpdate', player.PlayerData.source, player.PlayerData.job)
    end
    return true
end
```

### Server event for detecting an active-job switch or duty change immediately  _(spec claim: partial)_

- **Spec claim:** (Focus) What server-side event can Crimson-Police listen to in order to detect an active-job switch or duty change immediately? The spec says: re-check on every objective and every 10 s (Config.AntiCheat.jobRecheck), and use QBCore:Server:SetDuty for off duty.
- **Evidence:** qbx_core server/player.lua:266 (OnJobUpdate), :205 (SetDuty), :326/:373 (onGroupUpdate); spec.md:2577 lists only QBCore:Server:SetDuty and QBCore:Server:PlayerLoaded as server events; spec.md:222, :829 require job_change and off_duty
- **Implication:** The spec's Appendix leaves out QBCore:Server:OnJobUpdate, which is the immediate server-side signal for a job switch (arguments: src, job table). Add it next to QBCore:Server:SetDuty and keep the 10-second jobRecheck as a backstop. All three are server-local events (TriggerEvent), so register them with AddEventHandler. Never use RegisterNetEvent for them: that would let any client send a spoofed QBCore:Server:OnJobUpdate or QBCore:Server:SetDuty to Crimson-Police. Also listen to qbx_core:server:onGroupUpdate, because removing the active job changes the job to unemployed without firing OnJobUpdate (see the removeJob fact). The server-local QBCore:Player:SetPlayerData(PlayerData) fires on every data change, money and metadata included, so it would also catch everything, but it is very frequent. Use it only with a cheap per-source comparison of job.name and job.onduty, or not at all.

```lua
-- recommended, in modules/integrations/ (server)
AddEventHandler('QBCore:Server:OnJobUpdate', function(src, job) --[[ job.name ~= participant.jobName -> Abandoned 'job_change'; else if not job.onduty -> 'off_duty' ]] end)
AddEventHandler('QBCore:Server:SetDuty', function(src, onDuty) --[[ re-read exports.qbx_core:GetPlayer(src).PlayerData.job.onduty ]] end)
AddEventHandler('qbx_core:server:onGroupUpdate', function(src, groupName, grade) --[[ grade == nil means removed; re-check the active job ]] end)
```

### Duty is silently reset to defaultDuty on a switch or grade change  _(spec claim: partial)_

- **Spec claim:** (Implied) Going off duty mid-run is detected through QBCore:Server:SetDuty (src, onDuty)
- **Evidence:** qbx_core server/player.lua:223 (onduty = job.defaultDuty or false), :259; qbx_core shared/jobs.lua:15-18 (police defaultDuty = true); qbx_core server/player.lua:330-332 (AddPlayerToJob on the primary job calls SetPlayerPrimaryJob again)
- **Implication:** SetPlayerPrimaryJob rebuilds the job table, so onduty becomes the job definition's defaultDuty without any QBCore:Server:SetDuty event. For example, switching to police makes the player on duty if the server's jobs.lua has defaultDuty = true (it does upstream). A grade change on the active job (AddPlayerToJob, as sc-dispatch's boss menu does at sc-dispatch/server/main.lua:4404-4409) fires QBCore:Server:OnJobUpdate with the SAME job.name and may flip onduty. In the OnJobUpdate handler: same name means not a job_change, so check job.onduty and treat false as off_duty. Do not rely on the SetDuty event alone to find off-duty officers.

```lua
onduty = job.defaultDuty or false,
...
if player.PlayerData.job.name == jobName then
    SetPlayerPrimaryJob(citizenid, jobName)
end
```

### toggleDuty calls exports.qbx_core:SetJobDuty

- **Spec claim:** sc-multijob:server:toggleDuty calls exports.qbx_core:SetJobDuty
- **Evidence:** sc-multijob/server/server.lua:9-18; sc-multijob/config.lua:11; sc-multijob/client/client.lua:120-123
- **Implication:** The export is called as (src, boolean), with the server id first (not the citizenid). There is no argument, no job-type check and no suspension check: it toggles duty for whatever job is active. The enforcement happens elsewhere; sc-police and sc-ambulance handlers on QBCore:Server:SetDuty force suspended officers back off duty. The toggle is enabled because DisableDutyToggle = false.

```lua
RegisterNetEvent('sc-multijob:server:toggleDuty', function()
    local src = source
    local player = getPlayer(src)
    if not player then return end
    if Config.DisableDutyToggle then return end
    local currentDuty = player.PlayerData.job.onduty
    exports.qbx_core:SetJobDuty(src, not currentDuty)
end)
-- config.lua: Config.DisableDutyToggle = false
```

### Events and payload fired by SetJobDuty

- **Spec claim:** Event QBCore:Server:SetDuty (src, onDuty), server: going off duty mid-run removes the officer as Abandoned (off_duty); client QBCore:Client:SetDuty (onDuty)
- **Evidence:** qbx_core server/player.lua:196-209; consumers at sc-police/server/main.lua:1277-1288 and sc-ambulance/server/main.lua:978-988
- **Implication:** The handler signature is function(src, onDuty) with a real boolean. It fires even when the value does not change, so the handler must be idempotent. Pitfall: sc-police and sc-ambulance call SetJobDuty(false) from inside their own SetDuty handler, and TriggerEvent is synchronous. When a suspended officer goes on duty, Crimson-Police can therefore receive (src,false) and then a stale (src,true), depending on the order resources start. Act on onDuty == false directly, but for any on-duty logic re-read exports.qbx_core:GetPlayer(src).PlayerData.job.onduty; the server-side PlayerData is already changed before the event fires.

```lua
function SetJobDuty(identifier, onDuty)
    local player = resolvePlayer(identifier)
    if not player then return end
    player.PlayerData.job.onduty = not not onDuty
    if player.Offline then return end
    TriggerEvent('QBCore:Server:SetDuty', player.PlayerData.source, player.PlayerData.job.onduty)
    TriggerClientEvent('QBCore:Client:SetDuty', player.PlayerData.source, player.PlayerData.job.onduty)
    UpdatePlayerData(identifier)
end
-- sc-police: AddEventHandler('QBCore:Server:SetDuty', function(src, onDuty) if not onDuty then return end ... pcall(function() Player.Functions.SetJobDuty(false) end) ...
```

### removeJob and RemovePlayerFromJob: removing the active job fires no OnJobUpdate

- **Spec claim:** (Not in spec) sc-multijob also exposes a remove-job action
- **Evidence:** sc-multijob/server/server.lua:75-120 (no check that the job is not the active one); sc-multijob/html/script.js:111-118 (the UI only hides the active job); qbx_core server/player.lua:344-378
- **Implication:** The server event does not stop a player from removing their active job; only the NUI hides that button, and a crafted NUI POST or TriggerServerEvent gets through. When it happens, PlayerData.job becomes unemployed and only QBCore:Player:SetPlayerData and qbx_core:server:onGroupUpdate(src, jobName) with grade nil fire. QBCore:Server:OnJobUpdate and SetDuty do not. Crimson-Police must handle qbx_core:server:onGroupUpdate by re-reading GetPlayer(src).PlayerData.job.name, or rely on the 10-second recheck, to catch this job_change.

```lua
sc-multijob: local success, err = exports.qbx_core:RemovePlayerFromJob(player.PlayerData.citizenid, jobName)

qbx_core:
if player.PlayerData.job.name == jobName then
    local job = GetJob('unemployed')
    player.PlayerData.job = toPlayerJob('unemployed', job, 0)
    savePlayer(player)
end
if not player.Offline then
    SetPlayerData(player.PlayerData.source, 'jobs', player.PlayerData.jobs)
    TriggerEvent('qbx_core:server:onGroupUpdate', player.PlayerData.source, jobName)
    TriggerClientEvent('qbx_core:client:onGroupUpdate', player.PlayerData.source, jobName)
end
```

### The onGroupUpdate event (client and server)

- **Spec claim:** qbx_core:client:onGroupUpdate (client): refresh the tablet when the job changes
- **Evidence:** qbx_core server/player.lua:326-327 (added), :373-374 (removed), :536-537 and :592-593 (gangs); sc-multijob/client/client.lua:155-159
- **Implication:** Payloads are server (src, groupName, grade|nil) and client (groupName, grade|nil). The same event is used for jobs and for gangs and carries no type field, so never assume groupName is a job; just re-read PlayerData. It does not fire on a plain primary switch. On the client, PlayerData is already synced when it arrives (UpdatePlayerData runs first); sc-multijob waits 100 ms anyway.

```lua
TriggerEvent('qbx_core:server:onGroupUpdate', player.PlayerData.source, jobName, grade)
TriggerClientEvent('qbx_core:client:onGroupUpdate', player.PlayerData.source, jobName, grade)
-- removal: (source, jobName) with grade nil
-- sc-multijob client: RegisterNetEvent('qbx_core:client:onGroupUpdate', function() Wait(100) refreshMenu() end)
```

### Client events sc-multijob listens to (the model for the tablet's client)

- **Spec claim:** Events QBCore:Client:OnJobUpdate, QBCore:Client:SetDuty (onDuty), qbx_core:client:onGroupUpdate, QBCore:Client:OnPlayerUnload (client): refresh or close the tablet when the job, duty or character changes
- **Evidence:** sc-multijob/client/client.lua:81-95, :143-164; qbx_core server/player.lua:205-208, :265-267, :746
- **Implication:** On the client, QBCore:Client:SetDuty(onDuty) arrives BEFORE the QBCore:Player:SetPlayerData update, because SetJobDuty sends SetDuty and then calls UpdatePlayerData. exports.qbx_core:GetPlayerData().job.onduty is therefore stale inside that handler: use the onDuty argument, as sc-multijob does. QBCore:Client:OnJobUpdate(job) arrives after SetPlayerData, so GetPlayerData() is fresh there. Also listen to QBCore:Player:SetPlayerData (this sc-multijob client handler is not in the spec list) if the tablet should refresh on any data change. Client events are for the UI only; decisions about ending a run stay on the server.

```lua
RegisterNetEvent('QBCore:Client:OnJobUpdate', function() refreshMenu() end)
RegisterNetEvent('QBCore:Client:SetDuty', function(onDuty) refreshMenu(onDuty) end)
RegisterNetEvent('QBCore:Player:SetPlayerData', function() refreshMenu() end)
RegisterNetEvent('qbx_core:client:onGroupUpdate', function() Wait(100) refreshMenu() end)
RegisterNetEvent('QBCore:Client:OnPlayerUnload', function() closeMenu() end)
--- @param dutyOverride boolean|nil  when provided, forces the current job's onduty
---        state in the payload instead of relying on (possibly stale) cached PlayerData
```

### Exports and events of sc-multijob

- **Spec claim:** Exports: none; do not trigger its events
- **Evidence:** grep over sc-multijob: no exports(...) call; server/server.lua:9, :24, :75 are the only RegisterNetEvent calls; client/client.lua:121, :127, :134 are the only TriggerServerEvent calls; fxmanifest.lua:31 dependency 'qbx_core'
- **Implication:** Crimson-Police has nothing to call in sc-multijob. It must not TriggerServerEvent any sc-multijob:server:* event and must not add handlers for them: they are client-originated and unvalidated, and fire before success is known. All detection goes through qbx_core events and exports.qbx_core:GetPlayer(src). sc-multijob loads @oxmysql/lib/MySQL.lua but runs no queries and has no database tables.

```lua
RegisterNetEvent('sc-multijob:server:toggleDuty', function() ... end)
RegisterNetEvent('sc-multijob:server:switchJob', function(jobName) ... end)
RegisterNetEvent('sc-multijob:server:removeJob', function(jobName) ... end)
-- NUI callbacks: 'close', 'toggleDuty', 'switchJob' {jobName}, 'removeJob' {jobName}
-- command: /multijob (Config.Command), key F9 (Config.Keybind)
```

### Similarly named events that are NOT player job changes

- **Spec claim:** (Focus) Which qbx_core events fire on a switch
- **Evidence:** qbx_core server/groups.lua:150-157; qbx_core server/player.lua:986-1026
- **Implication:** qbx_core:server:onJobUpdate and qbx_core:client:onJobUpdate (lower-case, qbx_core: prefix) fire when a job DEFINITION is created or changed, with arguments (jobName, jobDefinition) sent to everyone. Do not use them to detect a player switch. When one fires, qbx_core itself re-fires QBCore:Server:OnJobUpdate(src, playerData.job) for every player whose active job is that job (player.lua:1022). An OnJobUpdate with an unchanged job.name can therefore also mean the job definition was edited.

```lua
TriggerEvent('qbx_core:server:onJobUpdate', name, jobs[name])
TriggerClientEvent('qbx_core:client:onJobUpdate', -1, name, jobs[name])
```

### Logout and character switch

- **Spec claim:** QBCore:Client:OnPlayerUnload (client): close the tablet when the character changes
- **Evidence:** qbx_core server/player.lua:737-747; sc-multijob/client/client.lua:162-164
- **Implication:** A character logout does not fire playerDropped. On the server, also AddEventHandler('QBCore:Server:OnPlayerUnload', function(src) ... end) to end that participant's run (disconnected) and clear their crimsonArena flag. It is a server-local event, so use AddEventHandler.

```lua
TriggerClientEvent('QBCore:Client:OnPlayerUnload', source)
TriggerEvent('QBCore:Server:OnPlayerUnload', source)
```

### Other findings

- The qbx_core source was NOT among the uploaded resources. Every qbx_core behaviour above (event names, argument order, the defaultDuty reset, RemovePlayerFromJob not firing OnJobUpdate) was checked against upstream Qbox-project/qbx_core main v1.24.0 (commit f0553b6, 2026-09-26), cloned to /tmp/claude-0/-home-user-PoliceTablet/c9b2f5e1-32ec-5436-a1db-2a78c5b9aa69/scratchpad/ref/qbx_core. The installed version may differ, so the handlers should be defensive, and the 10-second jobRecheck plus the per-objective recheck must stay as the authoritative backstop.
- Spec gap: the Appendix's qbx_core table lists no server event for job switches. Add 'Event QBCore:Server:OnJobUpdate (src, job): server: a switched active job removes the officer as Abandoned (job_change)' and 'Event qbx_core:server:onGroupUpdate (src, groupName, grade|nil): server: re-check the active job, since removing the active job changes it to unemployed without OnJobUpdate'.
- Security: QBCore:Server:OnJobUpdate, QBCore:Server:SetDuty, qbx_core:server:onGroupUpdate, QBCore:Server:OnPlayerUnload, QBCore:Server:PlayerLoaded and QBCore:Player:SetPlayerData are server-local events (TriggerEvent). Register them only with AddEventHandler. Net-event safety is per resource, so if Crimson-Police used RegisterNetEvent for any of them, a client could send a spoofed event, e.g. faking off duty to get a free abandon, or faking job data.
- Event ordering on a switch (server side): QBCore:Player:SetPlayerData(PlayerData), then QBCore:Server:OnJobUpdate(src, job). No SetDuty event fires even though onduty is reset to job.defaultDuty. On a duty toggle: QBCore:Server:SetDuty(src, onduty), then QBCore:Player:SetPlayerData. PlayerData is already updated before either event fires.
- Re-entrancy: sc-police (server/main.lua:1277) and sc-ambulance (server/main.lua:978) call SetJobDuty(false) inside their QBCore:Server:SetDuty handlers for suspended officers. Because TriggerEvent is synchronous across resources, the Crimson-Police handler can see (src,false) and then a stale (src,true). Always re-read exports.qbx_core:GetPlayer(src).PlayerData.job.onduty before acting on an on-duty transition.
- sc-multijob's switchJob validates against PlayerData.jobs, and 'unemployed' is never in that table, so sc-multijob cannot switch anyone to unemployed. Removing the active job through removeJob does make the player unemployed, but that path fires no OnJobUpdate.
- qbx_core's shared ForceJobDefaultDutyAtLogin = true (qbx_core shared/main.lua:2) sets duty to the job's defaultDuty at login. Upstream police has defaultDuty = true, so a police officer can load in already on duty without any SetDuty event. Crimson-Police should read job.onduty at PlayerLoaded and when the tablet opens, and never assume a player starts off duty.
- There is also a qbx_core net event QBCore:ToggleDuty (qbx_core server/events.lua:237-248) that toggles duty through player.Functions.SetJobDuty, so duty can change outside sc-multijob. The same QBCore:Server:SetDuty event covers it.
- The client module @qbx_core/modules/playerdata.lua (which can be added to shared_scripts or client_scripts) keeps QBX.PlayerData up to date from QBCore:Player:SetPlayerData and clears it on QBCore:Client:OnPlayerUnload. It is an alternative to calling exports.qbx_core:GetPlayerData() repeatedly in the tablet's client, and it is a Qbox-native API.
- sc-multijob has no server-side state, no database tables (it loads oxmysql but runs no queries), no state bags and no exports. Nothing in it can interfere with Crimson-Police. It sends its own ox_lib:notify messages ('Switched to <jobName>' and others) to the player's client.

## qbx_core-usage

### exports.qbx_core:GetPlayer(src) (server)

- **Spec claim:** exports.qbx_core:GetPlayer(src) returns the Qbox player object: PlayerData.citizenid, charinfo.firstname and lastname, job.name, job.label, job.grade.level, job.grade.name, job.onduty, job.type, metadata.callsign, metadata.isdead, metadata.inlaststand
- **Evidence:** src/sc-multijob/sc-multijob/server/server.lua:1-3,16,34,44,53; src/sc-npcpolice/sc-npcpolice/server/sv_main.lua:18-21,28-33; src/sc-ambulance/sc-ambulance/server/framework.lua:16-22; src/Renewed-Banking/Renewed-Banking/server/framework.lua:56-64,78-92; ref/qbx_core/server/functions.lua:86-94; ref/qbx_core/types.lua:35-43
- **Implication:** Call exports.qbx_core:GetPlayer(src) with the numeric server id (a non-numeric string is treated as an identifier such as license, not a citizenid). It returns nil for a player who has not loaded a character or has logged out, so nil-check every call. All fields live under player.PlayerData.*, for example player.PlayerData.job.name, not player.job.name. An export returns a marshalled snapshot, so do not cache the player object: call GetPlayer again for every check (duty, job, downed poll, payouts).

```lua
local function getPlayer(src)
    return exports.qbx_core:GetPlayer(src)
end
...
local currentDuty = player.PlayerData.job.onduty

-- qbx_core impl:
function GetPlayer(source)
    if tonumber(source) ~= nil then
        return QBX.Players[tonumber(source)]
    else
        return QBX.Players[GetSource(source)]
    end
end
exports('GetPlayer', GetPlayer)
```

### PlayerData field shapes

- **Spec claim:** PlayerData.citizenid, charinfo.firstname/lastname, job.name, job.label, job.grade.level, job.grade.name, job.onduty, job.type, metadata.callsign, metadata.isdead, metadata.inlaststand
- **Evidence:** ref/qbx_core/types.lua:40-43 (PlayerData.jobs/gangs/source), 127-140 (PlayerEntity), 151-161 (charinfo), 163-172 (metadata), 193-201 (PlayerJob); ref/qbx_core/server/player.lua:217-231 (toPlayerJob); src/Renewed-Banking/.../server/framework.lua:80,88,162; src/sc-dispatch/.../server/main.lua:279-289,1133-1137; src/sc-police/.../server/main.lua:161,176-179
- **Implication:** Read these paths: PlayerData.citizenid (string), PlayerData.source (number, online only), PlayerData.charinfo.firstname and .lastname (build the character name as firstname..' '..lastname), PlayerData.job.name, .label, .type (may be nil for jobs without a type), .onduty (boolean), .isboss, .grade.level (integer), .grade.name (string), and PlayerData.jobs = { [jobName] = gradeInteger } for every job held. job.grade is always a table {name, level} in Qbox, never a number, although sc-dispatch defensively handles both.

```lua
-- PlayerJob built by qbx_core:
return {
    name = jobName,
    label = job.label,
    isboss = job.grades[grade].isboss or false,
    bankAuth = job.grades[grade].bankAuth or false,
    onduty = job.defaultDuty or false,
    payment = job.grades[grade].payment or 0,
    type = job.type,
    grade = { name = job.grades[grade].name, level = grade }
}
-- types.lua: ---@field jobs table<string, integer>  ---@field source? Source present if player is online
-- Renewed-Banking name: ("%s %s"):format(Player.PlayerData.charinfo.firstname, Player.PlayerData.charinfo.lastname)
```

### job.grade.level supervisor check / job.grade.name rank

- **Spec claim:** job.grade.level is compared with supervisorGrade; job.grade.name is the rank shown
- **Evidence:** src/sc-dispatch/.../server/main.lua:521,532,548,566,5205 (grade.level gates), 1137,1166,5818 (grade.name as rank); src/sc-dispatch/.../client/main.lua:310-312; src/Renewed-Banking/.../server/framework.lua:162; ref/qbx_core/types.lua:201
- **Implication:** Supervisor check: (player.PlayerData.job.grade and player.PlayerData.job.grade.level or 0) >= dept.supervisorGrade, with integer comparison and no tostring. Rank label: player.PlayerData.job.grade.name, falling back to 'Unknown'. A promotion through AddPlayerToJob on the primary job fires QBCore:Client:OnJobUpdate and QBCore:Server:OnJobUpdate but no SetDuty event (see the job-switch fact), so refresh stored rank and supervisor state on OnJobUpdate as well as on PlayerLoaded.

```lua
local lvl = (Player.PlayerData.job.grade and Player.PlayerData.job.grade.level) or 0
...
return Player.PlayerData.job.grade.level >= minGrade
...
grade = player.PlayerData.job.grade.name
local submitterRank = (pd.job.grade and pd.job.grade.name) or 'Unknown'
```

### job.type = 'leo' for police jobs  _(spec claim: partial)_

- **Spec claim:** Config.DispatchIntegration.PoliceJobs = { 'fib', 'sast', 'police', 'bcso' }; police jobs have job.type = 'leo'
- **Evidence:** src/sc-police/sc-police/config.lua:24 (PoliceJobs), 494-497 (comment: Config.Stations 'gated by job.type == 'leo', which the fib job shares'); src/sc-police/.../server/main.lua:161,1283; ref/qbx_core/shared/jobs.lua:15-17,45-47,75-77 (police, bcso and sasp are type 'leo'; there is NO 'fib' and NO 'sast' in the reference jobs.lua)
- **Implication:** The server's own qbx_core/shared/jobs.lua was not uploaded. The reference qbx_core names the state police 'sasp', not 'sast', and has no 'fib'. Gate department membership on job.name against Config.Departments, never on job.type == 'leo' alone. Treat job.type as informational, and tell the owner in the checklist that fib and sast must exist in jobs.lua. Police jobs default to defaultDuty = true, so switching into one puts the officer on duty with no SetDuty event.

```lua
PoliceJobs = {  'fib', 'sast', 'police', 'bcso' },
...
if job.type ~= 'leo' and job.name ~= 'police' then return end
-- ref qbx_core jobs.lua:
['police'] = { label = 'LSPD', type = 'leo', defaultDuty = true, ... }
['bcso']   = { label = 'BCSO', type = 'leo', defaultDuty = true, ... }
['sasp']   = { label = 'SASP', type = 'leo', defaultDuty = true, ... }
```

### metadata.callsign (read-only)

- **Spec claim:** /callsign <name> saves metadata.callsign with SetMetaData; Crimson-Police only reads it
- **Evidence:** src/sc-police/.../server/commands.lua:201-208 (/callsign); src/sc-dispatch/.../server/main.lua:4428-4430 (hire also sets callsign), 4431-4438 (offline hire writes JSON_SET '$.callsign'), 663, 743, 1135; src/sc-police/.../server/main.lua:134,179; ref/qbx_core/server/player.lua:667 (default value)
- **Implication:** Read player.PlayerData.metadata.callsign. Treat nil, '' (a /callsign with no args stores table.concat({}, ' ') = '') and qbx_core's default 'NO CALLSIGN' as having no callsign. The value is free text of any length, so trim or clip it before storing and HTML-escape it in the NUI. Callsigns also change through sc-dispatch hiring, so refresh the stored copy on PlayerLoaded, as the spec says, and also at run start. Never call SetMetaData. The callsign command in sc-police uses the QBCore object: do not copy it.

```lua
AddCommand('callsign', ..., function(source, args)
    local Player = QBCore.Functions.GetPlayer(src)
    if Player then
        Player.Functions.SetMetaData('callsign', table.concat(args, ' '))
...
-- qbx_core default:
playerData.metadata.callsign = playerData.metadata.callsign or 'NO CALLSIGN'
-- readers:
local callsign = player.PlayerData.metadata.callsign or ''
label = v.PlayerData.metadata['callsign'] or v.PlayerData.job.name
```

### metadata.isdead / metadata.inlaststand (downed check)

- **Spec claim:** Downed = ped dead, or metadata.isdead or inlaststand true (same check sc-dispatch and sc-ambulance use); server polls every 2 s
- **Evidence:** src/sc-dispatch/.../client/main.lua:4147-4152 (IsPlayerIncapacitated), 3938-3942; src/sc-ambulance/.../server/main.lua:295 (EMSDownAlert guard), 370-384 (SetDeathStatus/SetLaststandStatus); src/sc-ambulance/.../server/grandma.lua:28-29; src/sc-ambulance/.../client/deathscreen.lua:373-386; ref/qbx_core/server/player.lua:648-649 (defaults false), 1211-1222 (onSetMetaData events and canUseWeapons state)
- **Implication:** Server downed check: local md = player.PlayerData.metadata; downed = md.isdead == true or md.inlaststand == true, optionally also GetEntityHealth(GetPlayerPed(src)) <= 0. Both keys default to false in Qbox. sc-ambulance sets them from client net events, so they are client-reported and can lag by a network round trip. The 2 s poll is fine. Optionally add AddEventHandler('qbx_core:server:onSetMetaData', function(key, old, value, src)) for instant detection. Note the argument order: key, oldValue, newValue, then source LAST, and only for key == 'isdead' or 'inlaststand'. The sc-ambulance qbx_medical_compat IsDead and IsLaststand exports are NOT loaded, because that file is not in sc-ambulance's fxmanifest.

```lua
local function IsPlayerIncapacitated()
    local pd = QBCore.Functions.GetPlayerData()
    local md = pd and pd.metadata or {}
    if md.isdead or md.inlaststand then return true end
    return IsEntityDead(PlayerPedId())
end
-- server (sc-ambulance):
if not Player.PlayerData.metadata['inlaststand'] and not Player.PlayerData.metadata['isdead'] then return end
-- how they get set (client-sent net events, no validation):
RegisterNetEvent('hospital:server:SetDeathStatus', function(isDead) ... Player.Functions.SetMetaData('isdead', isDead)
RegisterNetEvent('hospital:server:SetLaststandStatus', function(bool) ... Player.Functions.SetMetaData('inlaststand', bool)
-- qbx_core SetMetadata fires:
TriggerClientEvent('qbx_core:client:onSetMetaData', src, metadata, oldValue, value)
TriggerEvent('qbx_core:server:onSetMetaData', metadata, oldValue, value, player.PlayerData.source)
```

### exports.qbx_core:GetPlayerByCitizenId(citizenid)

- **Spec claim:** Find online officers for invites and payouts
- **Evidence:** src/sc-ambulance/.../server/framework.lua:25-31; src/Renewed-Banking/.../server/framework.lua:66-76; src/sc-dispatch/.../server/main.lua:6690-6698; ref/qbx_core/server/functions.lua:98-110; ref/qbx_core/config/server.lua:26-29 (citizenid = lib.string.random('A.......'))
- **Implication:** This lookup covers ONLINE players only: nil means offline, so set cash_status = 'pending' and pay on the next PlayerLoaded. The match is exact and case-sensitive (==). Store the citizenid exactly as read from PlayerData, and upper() any citizenid typed into the admin UI, as Renewed-Banking does. To reach the client, use target.PlayerData.source.

```lua
elseif Framework == 'qbx' then
    identifier = identifier:upper()
    return exports.qbx_core:GetPlayerByCitizenId(identifier)
...
local target = exports.qbx_core:GetPlayerByCitizenId(citizenId)
if target then
    TriggerClientEvent('QBCore:Notify', target.PlayerData.source, ...)
-- impl: if player and player.PlayerData.citizenid == citizenid then return player end  (exact == match)
```

### exports.qbx_core:GetQBPlayers()

- **Spec claim:** Every online player, e.g. to notify on-duty officers of a Cross-Department launch (a Qbox export, despite its name)
- **Evidence:** src/sc-npcpolice/.../server/sv_main.lua:23-26,36-44; src/sc-ambulance/.../server/framework.lua:34-40; ref/qbx_core/server/functions.lua:143-147 (returns QBX.Players), 154-185 (GetDutyCountJob / GetDutyCountType exports)
- **Implication:** The result is a MAP keyed by server id, not an array: iterate with pairs(), never ipairs or #. Use p.PlayerData.source for the id. Each call marshals every online player's full PlayerData across the export boundary, so do not call it in per-tick or per-second loops. Call it on events such as a Cross-Department launch, or cache on-duty sources yourself. Qbox also exports GetDutyCountJob(jobName) and GetDutyCountType(type), which return count, sources, but the spec restricts Crimson-Police to the listed calls.

```lua
local function GetFwPlayers()
    if isQBox then return exports.qbx_core:GetQBPlayers() end
...
for _, p in pairs(GetFwPlayers()) do
    if p and p.PlayerData.job and PoliceJobsSet[p.PlayerData.job.name] and p.PlayerData.job.onduty then
        cops[#cops + 1] = p.PlayerData.source
    end
end
-- impl:
function GetQBPlayers() return QBX.Players end
exports('GetQBPlayers', GetQBPlayers)
```

### exports.qbx_core:GetJobs() (server and client)

- **Spec claim:** Job labels and grade names for the UIs
- **Evidence:** src/sc-multijob/.../client/client.lua:11-13,26-36; src/Renewed-Banking/.../server/framework.lua:22,50,184; ref/qbx_core/server/groups.lua:321-325; ref/qbx_core/client/groups.lua:5-9,34-44; ref/qbx_core/types.lua:65-68,82-83
- **Implication:** Shape: jobs[jobName] = { label, type, defaultDuty, offDutyPay, grades = { [0] = { name, payment, isboss?, bankAuth? }, ... } }. Grades use INTEGER keys starting at 0, so index grades[player.PlayerData.job.grade.level] with a number. Renewed-Banking and sc-dispatch also try tostring keys for QBCore compatibility, which Qbox does not need. Before sending grades to the React NUI, convert to an array of { level, name }: json-encoding a Lua table with keys 0..n gives an object with string keys, and a job whose grades start at 1 would encode as a shifted array. The client-side qbx_core:client:onJobUpdate(jobName, jobDef) is the JOB DEFINITION changing. It is different from QBCore:Client:OnJobUpdate, the player's job changing: do not confuse them.

```lua
local allJobs = exports.qbx_core:GetJobs()
for jobName, gradeLevel in pairs(playerData.jobs) do
    local jobDef = allJobs[jobName]
    label = jobDef.label or jobName
    if jobDef.grades and jobDef.grades[gradeLevel] then
        gradeLabel = jobDef.grades[gradeLevel].name
    end
end
-- types: Job = { label, type?, defaultDuty, offDutyPay, grades = table<integer, {name, payment, isboss?, bankAuth?}> }
-- client cache refresh: RegisterNetEvent('qbx_core:client:onJobUpdate', function(jobName, job) jobs[jobName] = job end)
```

### player.Functions.AddMoney(moneyType, amount, reason)

- **Spec claim:** Cash payouts: player.Functions.AddMoney(Config.Cash.account, amount, 'crimson-police-mission'); account 'bank' by default
- **Evidence:** src/sc-npcpolice/.../server/sv_main.lua:305-309,321-325 (same pattern with exports.qbx_core:GetPlayer); src/sc-npcpolice/.../config.lua:28-33; src/Renewed-Banking/.../server/framework.lua:110-113; ref/qbx_core/server/player.lua:849-851 (method), 1305-1313 (validateMoneyAmount), 1320-1356 (AddMoney); ref/qbx_core/config/server.lua:4-9 (moneyTypes cash/bank/crypto)
- **Implication:** Argument order is (moneyType, amount, reason): the money type comes FIRST. This is the reverse of Renewed-Banking's internal AddMoney(Player, Amount, Type, comment) wrapper; do not copy that wrapper. The call RETURNS a boolean, so check it. On false, do not write 'paid', and do not call handleTransaction. Pass an already-rounded integer amount, math.floor(x + 0.5), matching Qbox's rounding. Skip the call when the amount is 0 (it would return true and log a $0 AddMoney). Config.Cash.account must be a key of qbx_core moneyTypes ('cash', 'bank' or 'crypto'). Qbox also exports exports.qbx_core:AddMoney(identifier, moneyType, amount, reason), where the identifier may be a citizenid string and works for offline players through SaveOffline, but the spec's pending-until-login design uses the player method.

```lua
local Player = GetFwPlayer(src)  -- exports.qbx_core:GetPlayer(src)
if Player then
    Player.Functions.AddMoney(Config.Rewards.Account, Config.Rewards.Arrest, 'npc-booking')
end
-- impl:
function self.Functions.AddMoney(moneytype, amount, reason)
    return AddMoney(self.PlayerData.source, moneytype, amount, reason)
end
-- AddMoney: validAmount = qbx.math.round(tonumber(amount)) (math.floor(x+0.5)); rejects nil/NaN/inf/negative;
-- returns false if not player.PlayerData.money[moneyType] or an 'addMoney' event hook blocks it; returns true on success
```

### exports.qbx_core:GetPlayerData() (client)

- **Spec claim:** Current job, rank, duty and metadata for the tablet
- **Evidence:** src/sc-multijob/.../client/client.lua:7-9,17-21; src/sc-npcpolice/.../client/cl_utils.lua:16-23; ref/qbx_core/client/functions.lua:41-45; ref/qbx_core/client/main.lua:4 (QBX.PlayerData = {}); ref/qbx_core/client/events.lua:26-30; ref/qbx_core/modules/playerdata.lua:1-13
- **Implication:** Before a character loads, the export returns an EMPTY TABLE {}, not nil, so `if not pd then` is not enough (sc-multijob's check has this bug). Guard with `if not pd or not pd.job then`. PlayerData is refreshed by the QBCore:Player:SetPlayerData net event, so re-call the export whenever you need fresh data rather than caching it. Alternatively, lib.load('@qbx_core.modules.playerdata') gives an auto-updating QBX.PlayerData. The client copy is display-only: the server must re-check everything through GetPlayer.

```lua
local ok, data = pcall(function()
    if UsingQBox() then return exports.qbx_core:GetPlayerData() end
    ...
end)
if not ok or not data or not data.job then return false end
return PoliceJobsSet[data.job.name] == true and data.job.onduty == true
-- impl:
function GetPlayerData() return QBX.PlayerData end   -- QBX.PlayerData = {} before login
```

### Event QBCore:Server:SetDuty (src, onDuty)  _(spec claim: partial)_

- **Spec claim:** Going off duty mid-run removes the officer as Abandoned (off_duty); sc-police forces suspended officers off duty through QBCore:Server:SetDuty
- **Evidence:** ref/qbx_core/server/player.lua:196-210 (SetJobDuty fires it); src/sc-police/.../server/main.lua:1253-1287; src/sc-ambulance/.../server/main.lua:954-989; src/sc-multijob/.../server/server.lua:9-18 (toggle through exports.qbx_core:SetJobDuty); ref/qbx_core/server/events.lua:239-250 (QBCore:ToggleDuty); ref/qbx_core/server/player.lua:238-270 (SetPlayerPrimaryJob does NOT fire SetDuty)
- **Implication:** This is a server-LOCAL event (TriggerEvent), so register it with AddEventHandler, NEVER RegisterNetEvent, or clients could spoof it. The arguments are (src:number, onDuty:boolean), and PlayerData.job.onduty is already updated when it fires. sc-police does not trigger SetDuty directly: it listens and calls Player.Functions.SetJobDuty(false), which re-fires QBCore:Server:SetDuty(src, false) from inside the first dispatch. Crimson-Police may therefore get (src, true) immediately followed by (src, false), in either handler order. Make the handler idempotent and treat exports.qbx_core:GetPlayer(src).PlayerData.job.onduty as the truth, not the argument. SetDuty does NOT fire on a job switch (SetPlayerPrimaryJob resets onduty to job.defaultDuty silently) or when the primary job is removed, so also listen to QBCore:Server:OnJobUpdate (see below) as well as the 10 s recheck.

```lua
function SetJobDuty(identifier, onDuty)
    local player = resolvePlayer(identifier)
    if not player then return end
    player.PlayerData.job.onduty = not not onDuty
    if player.Offline then return end
    TriggerEvent('QBCore:Server:SetDuty', player.PlayerData.source, player.PlayerData.job.onduty)
    TriggerClientEvent('QBCore:Client:SetDuty', player.PlayerData.source, player.PlayerData.job.onduty)
    UpdatePlayerData(identifier)
end
-- sc-police listener (uses QBCore object):
AddEventHandler('QBCore:Server:SetDuty', function(src, onDuty)
    if not onDuty then return end
    local Player = QBCore.Functions.GetPlayer(src)
    ...
    if IsSuspendedFor(Player.PlayerData.citizenid, job.name) then
        pcall(function() Player.Functions.SetJobDuty(false) end)
```

### Event QBCore:Server:PlayerLoaded (player)

- **Spec claim:** Pays pending cash and refreshes the stored callsign and rank
- **Evidence:** src/Renewed-Banking/.../server/framework.lua:218-221; ref/qbx_core/server/player.lua:969-980 (TriggerEvent('QBCore:Server:PlayerLoaded', self)); ref/qbx_core/server/events.lua:189-201 (the DIFFERENT net event QBCore:Server:OnPlayerLoaded); src/Renewed-Banking/.../server/main.lua:156-176 (UpdatePlayerAccount async), 247-284 (handleTransaction needs cachedPlayers[account])
- **Implication:** Register it with AddEventHandler (server-local). The single argument is the player object: use player.PlayerData.citizenid and player.PlayerData.source. Do NOT use the similarly named QBCore:Server:OnPlayerLoaded: that is a client-triggered NET event and spoofable. RACE: Renewed-Banking fills cachedPlayers[cid] ASYNCHRONOUSLY in its own PlayerLoaded handler. If Crimson-Police calls handleTransaction(citizenid, ...) synchronously, it prints invalid_account and silently records nothing, yet still returns a transaction table, so its return value cannot confirm success. Do the pending payout in a CreateThread after a delay, for example Wait(5000), and re-fetch exports.qbx_core:GetPlayer(src) first. At this moment Player(src).state.isLoggedIn is still false and the ped may not be spawned yet.

```lua
AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    local cid = Player.PlayerData.citizenid
    UpdatePlayerAccount(cid)
end)
-- qbx_core (end of CreatePlayer):
QBX.Players[self.PlayerData.source] = self
...
UpdatePlayerData(self.PlayerData.source)
Player(self.PlayerData.source).state:set('loadInventory', true, true)
TriggerEvent('QBCore:Server:PlayerLoaded', self)
-- Renewed-Banking handleTransaction for a personal account:
elseif cachedPlayers[account] then ... else print(locale("invalid_account", account)) end
return transaction
```

### Event QBCore:Client:OnJobUpdate (job)

- **Spec claim:** Refresh or close the tablet when the job changes
- **Evidence:** ref/qbx_core/server/player.lua:262-267 (SetPlayerPrimaryJob), 329-331 (AddPlayerToJob on primary calls SetPlayerPrimaryJob), 1025-1027 (job definition update); src/sc-multijob/.../client/client.lua:143-145; src/sc-police/.../client/main.lua:135-142; src/sc-ambulance/.../client/job.lua:155-172; src/sc-dispatch/.../client/main.lua:3251-3287
- **Implication:** Use RegisterNetEvent('QBCore:Client:OnJobUpdate', function(job) ... end). The argument is the full PlayerJob table (name, label, type, onduty, grade = {name, level}, ...). It fires on a multijob switch and on a grade change of the primary job. On a switch, job.onduty is reset to the new job's defaultDuty. PlayerData is updated before it fires, so GetPlayerData() inside the handler is fresh. It does NOT fire when RemovePlayerFromJob drops the player's primary job to unemployed: only qbx_core:client:onGroupUpdate fires then. The server-side twin, QBCore:Server:OnJobUpdate(src, job), is not in the spec but is the reliable server hook for an immediate 'job changed' abandon.

```lua
-- qbx_core:
Save(player.PlayerData.source)
UpdatePlayerData(player.PlayerData.source)
TriggerEvent('QBCore:Server:OnJobUpdate', player.PlayerData.source, player.PlayerData.job)
TriggerClientEvent('QBCore:Client:OnJobUpdate', player.PlayerData.source, player.PlayerData.job)
-- consumer:
RegisterNetEvent('QBCore:Client:OnJobUpdate', function(JobInfo)
    PlayerJob = JobInfo
    if JobInfo.type == 'leo' and JobInfo.onduty then ...
```

### Event QBCore:Client:SetDuty (onDuty)

- **Spec claim:** Refresh or close the tablet when duty changes
- **Evidence:** ref/qbx_core/server/player.lua:205-208 (SetDuty is sent BEFORE UpdatePlayerData); src/sc-multijob/.../client/client.lua:81-95,147-149; src/sc-police/.../client/main.lua:144-151; src/sc-dispatch/.../client/main.lua:3289-3301,3902-3910; src/sc-ambulance/.../client/job.lua:215-224
- **Implication:** Use RegisterNetEvent('QBCore:Client:SetDuty', function(onDuty) ... end). The only argument is a boolean. qbx_core sends it BEFORE QBCore:Player:SetPlayerData, so exports.qbx_core:GetPlayerData().job.onduty is still STALE inside the handler. Use the onDuty argument, as sc-multijob does, and close the tablet when onDuty == false.

```lua
RegisterNetEvent('QBCore:Client:SetDuty', function(onDuty)
    refreshMenu(onDuty)
end)
--- @param dutyOverride boolean|nil  when provided, forces the current job's onduty
---        state in the payload instead of relying on (possibly stale) cached PlayerData
if dutyOverride ~= nil and data.currentJob then
    data.currentJob.onduty = dutyOverride
end
```

### Event qbx_core:client:onGroupUpdate

- **Spec claim:** Refresh or close the tablet when the job changes (group membership)
- **Evidence:** src/sc-multijob/.../client/client.lua:155-159; ref/qbx_core/server/player.lua:323-327 (add job), 370-374 (remove job), 533-537 and 589-593 (gangs)
- **Implication:** The client arguments are (groupName, grade), and grade is nil when the group was REMOVED. It fires for GANGS too, with a gang name, so do not assume the name is a job. It is the only event when the primary job is removed (the player becomes unemployed without OnJobUpdate), so re-read GetPlayerData().job in the handler and close the tablet if the active job is no longer a department job. PlayerData is set just before, and a Wait(100) as sc-multijob uses is harmless. The server twin is qbx_core:server:onGroupUpdate(src, groupName, grade|nil), fired with TriggerEvent, so use AddEventHandler.

```lua
RegisterNetEvent('qbx_core:client:onGroupUpdate', function()
    -- Small delay to let PlayerData.jobs sync first
    Wait(100)
    refreshMenu()
end)
-- qbx_core:
TriggerEvent('qbx_core:server:onGroupUpdate', player.PlayerData.source, jobName, grade)
TriggerClientEvent('qbx_core:client:onGroupUpdate', player.PlayerData.source, jobName, grade)
-- on removal: TriggerClientEvent('qbx_core:client:onGroupUpdate', player.PlayerData.source, jobName)  -- grade nil
```

### Event QBCore:Client:OnPlayerUnload

- **Spec claim:** Close the tablet when the character changes
- **Evidence:** src/sc-multijob/.../client/client.lua:161-164; src/sc-police/.../client/main.lua:122-133; src/Renewed-Banking/.../client/framework.lua:44-46; ref/qbx_core/server/player.lua:738-758 (Logout); ref/qbx_core/modules/playerdata.lua:6-9
- **Implication:** Use RegisterNetEvent. It carries no arguments. Close the NUI, release SetNuiFocus(false, false), delete the tablet prop, and clear client mission state. It fires only on a character logout or switch, never on disconnect.

```lua
RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    closeMenu()
end)
-- qbx_core Logout:
TriggerClientEvent('QBCore:Client:OnPlayerUnload', source)
TriggerEvent('QBCore:Server:OnPlayerUnload', source)
Wait(200)
QBX.UnregisterPlayer(source)
QBX.Players[source] = nil
...
TriggerClientEvent('qbx_core:client:playerLoggedOut', source)
TriggerEvent('qbx_core:server:playerLoggedOut', source)
```

### Event QBCore:Server:OnPlayerUnload (source) - not in spec  _(spec claim: partial)_

- **Spec claim:** (focus item) server-side unload handling
- **Evidence:** Not used by any uploaded SC resource or Renewed-Banking (grep found nothing); ref/qbx_core/server/player.lua:749-750 (fired by Logout); ref/qbx_core/server/events.lua:205-207 (qbx_core's own handler sets isLoggedIn false), 38-57 (playerDropped does NOT fire it)
- **Implication:** Add AddEventHandler('QBCore:Server:OnPlayerUnload', function(src) ... end) so a character switch mid-run removes the officer (Abandoned) and clears responding and state-bag flags. When it fires, GetPlayer(src) still returns the old character, because unregistering happens after Wait(200). Handle playerDropped separately: qbx_core fires no unload event on disconnect.

```lua
TriggerClientEvent('QBCore:Client:OnPlayerUnload', source)
TriggerEvent('QBCore:Server:OnPlayerUnload', source)
-- qbx_core playerDropped handler: saves, then QBX.UnregisterPlayer(src); QBX.Players[src] = nil  (no OnPlayerUnload event)
```

### qbx_core:server:playerLoaded  _(spec claim: not_found)_

- **Spec claim:** (focus item) qbx_core:server:playerLoaded event
- **Evidence:** No occurrence in src/** or in ref/qbx_core/** (grep for 'qbx_core:server:playerLoaded' and 'qbx_core:client:playerLoaded' returned nothing). Only QBCore:Server:PlayerLoaded (ref/qbx_core/server/player.lua:979) and qbx_core:server:playerLoggedOut (player.lua:757) exist.
- **Implication:** Do not listen for qbx_core:server:playerLoaded: it does not exist in this qbx_core (v1.24.0). Use AddEventHandler('QBCore:Server:PlayerLoaded', function(player)). If you use qbx_core:server:playerLoggedOut(src), GetPlayer(src) is already nil, so rely on cached data.

```lua
TriggerEvent('QBCore:Server:PlayerLoaded', self)   -- the only server 'loaded' event
TriggerEvent('qbx_core:server:playerLoggedOut', source)  -- fires after QBX.Players[source] = nil
```

### playerDropped (server)

- **Spec claim:** playerDropped removes the player's responding entries
- **Evidence:** ref/qbx_core/server/events.lua:38-57; src/sc-dispatch/.../server/main.lua:237,1009,6850,7492; src/sc-npcpolice/.../server/sv_main.lua:340
- **Implication:** The dropped player's id is the global `source` (capture it with local src = source at the top), and reason is the argument. qbx_core removes the player in its own playerDropped handler, and handler order across resources is not guaranteed, so exports.qbx_core:GetPlayer(src) may already be nil. Keep a server-side map src -> { citizenid, name, dept } filled at PlayerLoaded or run join, and use it on drop.

```lua
AddEventHandler('playerDropped', function(reason)
    local src = source
    ...
    if not QBX.Players[src] then return end
    ...
    player.Functions.Save()
    QBX.Player_Buckets[player.PlayerData.license] = nil
    QBX.UnregisterPlayer(src)
    QBX.Players[src] = nil
end)
```

### sc-multijob: SetPlayerPrimaryJob / SetJobDuty / PlayerData.jobs  _(spec claim: partial)_

- **Spec claim:** A player holds up to 5 jobs in PlayerData.jobs; PlayerData.job is the active one. sc-multijob:server:switchJob calls exports.qbx_core:SetPlayerPrimaryJob; sc-multijob:server:toggleDuty calls exports.qbx_core:SetJobDuty; no exports
- **Evidence:** src/sc-multijob/.../server/server.lua:9-18,24-69,75-120; src/sc-multijob/.../config.lua:3-5; src/sc-multijob/.../client/client.lua:25-44; ref/qbx_core/server/player.lua:6 (maxJobsPerPlayer = GetConvarInt('qbx:max_jobs_per_player', 1)), 238-270, 314-319
- **Implication:** The 5-job limit comes from the convar qbx:max_jobs_per_player, which defaults to 1 in qbx_core, not from sc-multijob. Do not hardcode 5. Iterate PlayerData.jobs with pairs(): it maps name to integer grade. Job switches fire only QBCore:Server:OnJobUpdate and QBCore:Client:OnJobUpdate, never SetDuty. The new job's onduty = defaultDuty, which is true for police jobs, so an officer switching back into police is instantly on duty. Removing the active job fires only onGroupUpdate. sc-multijob has no exports: never trigger its sc-multijob:server:* events.

```lua
exports.qbx_core:SetJobDuty(src, not currentDuty)
local success, err = exports.qbx_core:SetPlayerPrimaryJob(player.PlayerData.citizenid, jobName)
local success, err = exports.qbx_core:RemovePlayerFromJob(player.PlayerData.citizenid, jobName)
-- config.lua:
-- NOTE: You must also set this in server.cfg: set qbx:max_jobs_per_player 5
Config.MaxJobs = 5
-- PlayerData.jobs = { [jobName] = gradeLevel }
```

### QBCore core object usage (patterns NOT to copy)

- **Spec claim:** Hard rule 2: no exports['qb-core']:GetCoreObject(), no QBCore.Functions, no qb-core dependency
- **Evidence:** GetCoreObject: sc-police server/{main,commands,interactions,evidence,registration,vehicle,fibstation,prisonlife,prison,armory,objects}.lua line 1-10, client/{main,tracker,evidencelocker,objects,evidence}.lua; sc-ambulance server/{framework,main,xray,narcan,insurance,blood,escort,defib,surgery,mri}.lua:1-7 and most client files; sc-dispatch server/main.lua:8, client/main.lua:8; sc-npcpolice server/sv_main.lua:10 and client/cl_utils.lua:19 (qb fallback only); Renewed-Banking server/framework.lua:10 (qb branch only). qb-core dependency: sc-police/fxmanifest.lua:66-70, sc-dispatch/fxmanifest.lua:48-51. '@qb-core/shared/locale.lua': sc-dispatch/fxmanifest.lua:12, sc-ambulance/fxmanifest.lua:12
- **Implication:** Do NOT copy any code from sc-police, sc-ambulance or sc-dispatch as-is: they are built on the qbx_core qb-core bridge (qbx_core fxmanifest has provide 'qb-core'). Clean Qbox-native templates: sc-multijob (all of it), the isQBox branches of sc-npcpolice, and the 'qbx' branches of Renewed-Banking. Translations: QBCore.Functions.GetPlayer -> exports.qbx_core:GetPlayer; GetQBPlayers -> exports.qbx_core:GetQBPlayers; client GetPlayerData -> exports.qbx_core:GetPlayerData(); QBCore.Shared.Jobs -> exports.qbx_core:GetJobs(); CreateCallback/TriggerCallback -> lib.callback.register/lib.callback.await; QBCore.Commands.Add -> lib.addCommand or RegisterCommand; QBCore:Notify -> Crimson-Police's own NUI. Do not list qb-core in dependencies and do not include @qb-core/* files.

```lua
local QBCore = exports['qb-core']:GetCoreObject()
local Player = QBCore.Functions.GetPlayer(src)
QBCore.Functions.GetQBPlayers()
QBCore.Functions.GetPlayerData()
QBCore.Functions.CreateCallback('police:GetDutyPlayers', ...)
QBCore.Functions.TriggerCallback('QBCore:Server:SpawnVehicle', ...)
QBCore.Commands.Add('recalcdoctors', ...)
QBCore.Shared.Jobs[job].label
exports['qb-core']:DrawText(...) / KeyPressed() / HideText()
TriggerClientEvent('QBCore:Notify', src, msg, 'error')
TriggerServerEvent('QBCore:ToggleDuty')
dependencies { 'qb-core', ... }
shared_scripts { '@qb-core/shared/locale.lua', ... }
```

### Admin permission / HasPermission

- **Spec claim:** Admin = ace crimsonpolice.admin
- **Evidence:** src/sc-npcpolice/.../server/sv_main.lua:45-53; ref/qbx_core/server/functions.lua:347-361 (HasPermission is IsPlayerAceAllowed and marked @deprecated)
- **Implication:** Use IsPlayerAceAllowed(src, 'crimsonpolice.admin') directly, since Qbox's HasPermission is deprecated and is only that ACE check. Console source 0 is not a player: handle it explicitly for /CrimsonPoliceAdmin run from the console.

```lua
if isQBox then return exports.qbx_core:HasPermission(src, 'admin') end
-- impl:
function HasPermission(source, permission)
    if type(permission) == 'string' then
        if IsPlayerAceAllowed(source, permission) then return true end
...
---@deprecated use IsPlayerAceAllowed
exports('HasPermission', HasPermission)
```

### isLoggedIn state bag

- **Spec claim:** (focus) readiness check
- **Evidence:** ref/qbx_core/server/events.lua:186-201,205-207; src/sc-dispatch/.../client/main.lua:456,522; src/Renewed-Banking/.../client/framework.lua:4,12-14; src/sc-police/.../client/evidence.lua:636
- **Implication:** On the client, gate tablet opening on LocalPlayer.state.isLoggedIn == true, as well as pd.job existing. Renewed-Banking's AddStateBagChangeHandler('isLoggedIn', nil, ...) fires for EVERY player's bag. If you copy it, filter with bagName == ('player:%s'):format(GetPlayerServerId(PlayerId())). qbx_core sets it true when the client sends QBCore:Server:OnPlayerLoaded, which is after the server's QBCore:Server:PlayerLoaded.

```lua
-- `if LocalPlayer.state.isLoggedIn then` for the client side
-- `if Player(source).state.isLoggedIn then` for the server side
while not (LocalPlayer.state and LocalPlayer.state.isLoggedIn) do Wait(1000) end
AddStateBagChangeHandler('isLoggedIn', nil, function(_, _, value) FullyLoaded = value end)
```

### lib.callback (ox_lib)

- **Spec claim:** ox_lib used through standard APIs
- **Evidence:** src/sc-police/.../server/fibstation.lua:85-110; src/sc-police/.../client/fibstation.lua:65,80,103; src/Renewed-Banking/.../server/main.lua:323-345; src/Renewed-Banking/.../client/main.lua:19,39,88; ref/qbx_core/server/events.lua:197-199 (server->client await)
- **Implication:** Client call: lib.callback.await(name, false, ...args). The second parameter is the delay/rate-limit, pass false; it is not an argument. Server handler: function(source, ...args) return value end. Server to client: lib.callback.await(name, targetSrc, ...). Name them 'crimson-police:server:<action>' and re-check permissions inside every handler, because the source is trusted but the args are not. Requires '@ox_lib/init.lua' in shared_scripts, as sc-police and Renewed-Banking have.

```lua
-- server
lib.callback.register('sc-police:fibLocker:getFolders', function(source, lockerType, cabinet)
    if not LockerAccess(source, lockerType) then return nil end
    return MySQL.query.await(...) or {}
end)
-- client
local folders = lib.callback.await('sc-police:fibLocker:getFolders', false, lockerType, cabinet)
-- async form
lib.callback('renewed-banking:server:initalizeBanking', false, function(accounts) ... end)
-- server -> client
lib.callback.await('qbx_core:client:setHealth', src, player.PlayerData.metadata.health or 200)
```

### lib.progressBar (ox_lib)

- **Spec claim:** ox_lib progress bar during missions (e.g. 5 s 'Cuff suspect')
- **Evidence:** src/sc-npcpolice/.../client/cl_interact.lua:15-29; src/sc-police/.../client/interactions.lua:121-131; src/sc-police/.../client/prisonbreak.lua:68; src/Renewed-Banking/.../client/main.lua:3
- **Implication:** lib.progressBar(opts) blocks and returns true when it completes and false when cancelled. The options are duration in ms, label, useWhileDead = false, canCancel = true, disable = { move, car, combat }, and anim = { dict, clip }. Only send the objective event when it returns true. The server must still enforce minSeconds and presenceRange, because the client result is not trusted.

```lua
return lib.progressBar({ duration = ms, label = label, useWhileDead = false, canCancel = true,
    disable = { move = true, car = true, combat = true } })
...
if lib.progressBar({
    duration = 5000,
    label = 'Impounding Vehicle...',
    useWhileDead = false,
    canCancel = true,
    disable = { move = true, car = true, combat = true },
    anim = { dict = 'missheistdockssetup1clipboard@base', clip = 'base' }
}) then
    TriggerServerEvent(...)
else
    -- cancelled
end
```

### lib.skillCheck (ox_lib)

- **Spec claim:** Bomb defuse: 4 ox_lib skill checks (easy, medium, medium, hard); a miss takes 30 s off; 2 misses in a row on one device sets it off
- **Evidence:** src/sc-police/.../client/prisonbreak.lua:52; src/sc-police/.../client/evidence.lua:1306-1315; src/sc-police/.../config.lua:55-61; src/sc-ambulance/.../client/surgery.lua:231 (exports.ox_lib:skillCheck form)
- **Implication:** lib.skillCheck(difficulty, inputs) returns a boolean. The difficulty is a string or an array of 'easy', 'medium' or 'hard'; inputs is an array of key strings. A single call with an array runs the checks in sequence and returns false at the first miss without saying which stage failed. For the defuse rules, where each miss costs 30 s and two misses in a row set the device off, call lib.skillCheck once PER STAGE in a loop and report each miss to the server. Use the lib.* form with @ox_lib/init.lua, not exports.ox_lib:skillCheck.

```lua
success = lib.skillCheck({'easy', 'easy', 'medium', 'medium', 'hard'}, {'w', 'a', 's', 'd'})
...
local ok = lib.skillCheck(difficulty, mg.Keys or { 'w', 'a', 's', 'd' })
-- config: Blood = { 'easy', 'easy', 'medium' }, Keys = { 'w', 'a', 's', 'd' }
local passed = exports.ox_lib:skillCheck(stage.skillCheck, Config.Surgery.SkillCheck.Keys)
```

### ox_target addLocalEntity / removeLocalEntity

- **Spec claim:** ox_target for mission props, doors and NPCs; options only for participants
- **Evidence:** src/Renewed-Banking/.../client/main.lua:110-160; src/sc-ambulance/.../client/grandma.lua:96-109,162; src/sc-police/.../client/prisonlife.lua:22-25
- **Implication:** addLocalEntity(entityHandle, optionsArray). Each option has a unique name, icon, label, optional distance, canInteract(entity, distance, coords, name, bone) and onSelect(data), or event. Remove with removeLocalEntity(entity, {names}). The upload only shows these calls on LOCAL client-created peds. Crimson-Police NPCs are networked, created server-side (spec 1519), so the entity handle is per-client and changes when the ped streams out and back in. Either re-add on stream-in, or use ox_target's net-id API addEntity(netId, options) (standard ox_target API, not shown in the uploads). Prefix names with 'crimson_police_' and gate canInteract on the local participant state (the options appear only for participants), then re-validate on the server.

```lua
exports.ox_target:addLocalEntity(self.ped, {
    { name = 'renewed_banking_openui', event = 'Renewed-Banking:client:openBankUI', icon = 'fas fa-money-check',
      label = locale('view_bank'),
      canInteract = function(_, distance) return distance < 4.5 end },
})
exports.ox_target:removeLocalEntity(self.ped, {'renewed_banking_accountmng', 'renewed_banking_debitcard', 'renewed_banking_openui'})
-- sc-ambulance:
exports.ox_target:addLocalEntity(ped, {{ name = 'sc_ambulance_grandma_' .. id, icon = 'fas fa-hand-holding-medical', label = label,
    distance = distance, canInteract = function() return playerGang == grandma.gang end,
    onSelect = function() TriggerServerEvent('sc-ambulance:server:GrandmaRevive', id) end }})
```

### ox_target addBoxZone / addSphereZone / removeZone

- **Spec claim:** ox_target zones on doors and scene markers
- **Evidence:** src/sc-police/.../client/evidencelocker.lua:93-112,426-431; src/sc-police/.../client/job.lua:167-185; src/sc-police/.../client/fibstation.lua:165-175; src/sc-ambulance/.../client/target.lua:26-32,59-64
- **Implication:** addSphereZone takes { coords = vec3, radius, debug, options }. addBoxZone takes { coords = vec3, size = vec3(x, y, z), rotation = heading in degrees, debug, options }. Both RETURN a zone id: store it per run and call exports.ox_target:removeZone(id), wrapped in pcall as sc-police does, when the objective, run or resource ends. Otherwise zones leak across runs. An option's groups filter is a map { [jobName] = minGrade } (sc-ambulance target.lua: groups = { [opt.job] = 0 }), but participant gating should use canInteract.

```lua
local zoneId = exports.ox_target:addSphereZone({
    coords = coords,
    radius = 1.5,
    debug = Config.Debug,
    options = {
        { name = zoneName .. '_access', icon = 'fas fa-box-archive', label = 'Evidence Locker',
          onSelect = function() TriggerEvent('sc-police:client:OpenEvidenceLocker') end,
          canInteract = function() return IsLeoJob() and IsOnDuty() end },
    },
})
evidenceLockerZoneIds[i] = zoneId
...
pcall(function() exports.ox_target:removeZone(zoneId) end)
-- box:
exports.ox_target:addBoxZone({ coords = coords, size = size or vec3(1.5, 1.5, 2.0), rotation = 0, debug = Config.Debug, options = options })
```

### ox_inventory AddItem / RemoveItem / counts (server)

- **Spec claim:** Mission items given at start and removed at end through ox_inventory
- **Evidence:** src/sc-ambulance/.../server/framework.lua:51-88 (wrapper shows real arg order); src/Renewed-Banking/.../server/main.lua:14,88; src/sc-police/.../server/evidence.lua:522-525,1697; src/sc-police/.../server/prisonlife.lua:82,95-96; src/sc-dispatch/.../server/main.lua:4900
- **Implication:** The ARGUMENT ORDER is (inventory, itemName, count, metadata, slot): metadata comes BEFORE slot. The QBCore Player.Functions.AddItem(item, amount, slot, info) order is different; do not copy it. AddItem returns success, response: check success and handle an inventory-full failure, as sc-dispatch logs it. Tag mission items with metadata, for example { crimson_run = run_uuid }, then remove them with RemoveItem(src, name, count, { crimson_run = run_uuid }). Only the mission copies are removed, which depends on ox_inventory's documented metadata matching (not shown in the uploads). Use GetItemCount(src, name) or Search(src, 'count', name) for counts.

```lua
return exports.ox_inventory:AddItem(source, itemName, amount, info, slot)       -- (inv, item, count, metadata, slot)
return exports.ox_inventory:RemoveItem(source, itemName, amount, nil, slot)     -- (inv, item, count, metadata, slot)
local success, response = exports.ox_inventory:AddItem(src, Config.debitCard.item, 1, metadata)
local count = exports.ox_inventory:GetItemCount(source, itemName)
local count = exports.ox_inventory:Search(src, 'count', 'prison_credit')
local slots = exports.ox_inventory:Search(source, 'slots', Config.debitCard.item)
```

### Tablet usable item (optional) via exports.qbx_core:CreateUseableItem  _(spec claim: partial)_

- **Spec claim:** Config item = ox_inventory item name that also opens the tablet, or false
- **Evidence:** src/sc-ambulance/.../server/framework.lua:42-49; ref/qbx_core/server/functions.lua:263-278
- **Implication:** Qbox exposes exports.qbx_core:CreateUseableItem(itemName, function(source, item) ... end), which only stores the callback in QBX.UsableItems. Whether ox_inventory invokes it depends on ox_inventory's qbx bridge (not in the uploads). The alternative is ox_inventory's own item definition (client export or server hook). Register it only when Config.Tablet.item ~= false, and still re-check on-duty and department on the server before opening.

```lua
exports.qbx_core:CreateUseableItem(itemName, callback)
-- impl:
function CreateUseableItem(item, data)
    QBX.UsableItems[item] = data
end
exports('CreateUseableItem', CreateUseableItem)
```

### Notifications used by these resources (do not copy)

- **Spec claim:** All notifications are Crimson-Police's own NUI; no ox_lib notifications
- **Evidence:** src/sc-multijob/.../server/server.lua:35-39; src/sc-npcpolice/.../client/cl_utils.lua:25-35 (exports.qbx_core:Notify); src/Renewed-Banking/.../server/framework.lua:200-202; src/sc-ambulance/.../server/framework.lua:166-175
- **Implication:** Do not use ox_lib:notify, lib.notify, exports.qbx_core:Notify or QBCore:Notify for Crimson-Police messages. Route every message through Crimson-Police's own NUI event, for example TriggerClientEvent('crimson-police:client:notify', src, {...}).

```lua
TriggerClientEvent('ox_lib:notify', src, { title = 'MultiJob', description = 'You don\'t have that job.', type = 'error' })
exports.qbx_core:Notify(msg, ntype)
TriggerClientEvent('QBCore:Notify', source, message, type)
```

### Other findings

- A real qbx_core source (v1.24.0) is at /tmp/claude-0/-home-user-PoliceTablet/c9b2f5e1-32ec-5436-a1db-2a78c5b9aa69/scratchpad/ref/qbx_core. I used it to verify every event payload and ordering; the uploaded SC resources alone do not show them. Key files: server/player.lua, server/functions.lua, server/events.lua, client/events.lua, client/groups.lua, types.lua.
- qbx_core fires the QBCore:* events itself, confirming the spec: QBCore:Server:SetDuty and QBCore:Client:SetDuty (player.lua:205-206), QBCore:Server:OnJobUpdate and QBCore:Client:OnJobUpdate (player.lua:266-267, 1026-1027), QBCore:Server:PlayerLoaded (player.lua:979), and QBCore:Client:OnPlayerUnload and QBCore:Server:OnPlayerUnload (player.lua:749-750). Server-side ones use TriggerEvent, so register them with AddEventHandler only. Client-side ones use TriggerClientEvent, so use RegisterNetEvent. QBCore:Client:OnPlayerLoaded is a client-local TriggerEvent (client/character.lua:280).
- NAME TRAP: 'QBCore:Server:OnPlayerLoaded' (with 'On') is a client-to-server NET event and spoofable (server/events.lua:189). 'QBCore:Server:PlayerLoaded' (no 'On') is the trusted server-local event whose argument is the player object. Only use the latter for pending payouts.
- Duty gaps: SetJobDuty is the ONLY path that fires QBCore:Server:SetDuty. Job switches (SetPlayerPrimaryJob), promotions through AddPlayerToJob on the primary job, and job removal (RemovePlayerFromJob) change job.onduty without SetDuty: onduty resets to job.defaultDuty, which is true for police jobs. Add AddEventHandler('QBCore:Server:OnJobUpdate', function(src, job)) and AddEventHandler('qbx_core:server:onGroupUpdate', function(src, groupName, grade)) as immediate triggers for the job recheck, in addition to the 10 s Config.AntiCheat.jobRecheck.
- Re-entrancy: sc-police's and sc-ambulance's QBCore:Server:SetDuty handlers call Player.Functions.SetJobDuty(false) inside the event when the officer is suspended in sc-dispatch. That fires a nested QBCore:Server:SetDuty(src, false). Crimson-Police's handler must be idempotent and should read the live PlayerData.job.onduty rather than trust the argument.
- Client staleness: QBCore:Client:SetDuty is sent before QBCore:Player:SetPlayerData (player.lua:205-208), so use the onDuty argument, not GetPlayerData().job.onduty, in that handler. OnJobUpdate and onGroupUpdate are sent after PlayerData updates.
- Renewed-Banking race: its QBCore:Server:PlayerLoaded handler fills cachedPlayers[citizenid] asynchronously (server/main.lua:156-176). handleTransaction on a personal account that is not cached yet just prints 'invalid_account' and still returns a transaction table (main.lua:268-283). Delay the pending-cash handleTransaction by a few seconds after PlayerLoaded, and do not treat its return value as success. It also returns nil (print) when any argument has the wrong type: amount must be a number, and account, title, message, issuer, receiver, type and transID must be strings.
- Renewed-Banking removeAccountMoney(account, amount) returns false both when the account is unknown and when funds are short (main.lua:350-364). getAccountMoney returns false for an unknown account (main.lua:286-292). Its internal AddMoney wrapper has order (Player, Amount, Type, comment), which is the reverse of Qbox's player.Functions.AddMoney(moneyType, amount, reason).
- player.Functions.AddMoney returns boolean (player.lua:849-851, 1320-1356). It rounds with math.floor(x + 0.5); rejects nil, NaN, infinity and negative amounts; rejects unknown money types (valid: cash, bank, crypto); and can be blocked by an 'addMoney' event hook. It logs amounts over 100000 with a role tag. Never set cash_status = 'paid' unless it returned true.
- Default metadata.callsign is the string 'NO CALLSIGN' (player.lua:667), not nil. isdead and inlaststand default to false (player.lua:648-649). sc-ambulance sets isdead and inlaststand from unvalidated client net events (hospital:server:SetDeathStatus and hospital:server:SetLaststandStatus, server/main.lua:370-384), so they are client-reported.
- GetPlayerData() on the client returns {} before login (client/main.lua:4), not nil. sc-multijob's `if not playerData then` guard is insufficient; check pd.job.
- GetQBPlayers() returns QBX.Players, a map keyed by source. Iterate with pairs(). Each export call copies all players' data, so avoid it in hot loops.
- The server's real qbx_core/shared/jobs.lua was not uploaded. The reference default has police, bcso and sasp (type 'leo') but no 'fib' and no 'sast'. sc-police and sc-dispatch config expect fib and sast, so the owner's jobs.lua must define them. Gate on job.name from Config.Departments, not on job.type alone.
- Max jobs per player comes from the convar qbx:max_jobs_per_player, which defaults to 1 in qbx_core (player.lua:6). sc-multijob's Config.MaxJobs = 5 only works if server.cfg sets `set qbx:max_jobs_per_player 5`.
- sc-ambulance's client/qbx_medical_compat.lua and server/qbx_medical_compat.lua (IsDead and IsLaststand exports) are NOT in its fxmanifest, so those exports do not exist at runtime. Read metadata directly.
- In sc-dispatch server/main.lua, 'Player' is shadowed by local QBCore player objects, so it aliases the global as StateBagPlayer = Player (line 14). If Crimson-Police names a local variable 'Player', Player(src).state:set('crimsonArena', ...) breaks. Name player objects 'player' (lowercase) or 'qbxPlayer'.
- Qbox-native reference code to copy from: all of sc-multijob; the isQBox branches in sc-npcpolice server/sv_main.lua:18-44 and client/cl_utils.lua:16-23; the 'qbx' branches in Renewed-Banking server/framework.lua. Everything in sc-police, sc-ambulance and sc-dispatch uses exports['qb-core']:GetCoreObject() and QBCore.Functions. sc-police and sc-dispatch also list qb-core as a dependency, and sc-dispatch and sc-ambulance include '@qb-core/shared/locale.lua'. Do NOT copy these patterns.
- The uploads show no server-side QBCore:Server:OnPlayerUnload handler, but qbx_core fires it on character logout (player.lua:750), and GetPlayer(src) still works inside it. playerDropped fires no unload event, and qbx_core clears QBX.Players[src] in its own playerDropped handler. Cache src -> citizenid yourself for drop handling.
- qbx_core:server:onSetMetaData has argument order (key, oldValue, newValue, source), with source LAST (player.lua:1212). The client version is (key, oldValue, newValue). It could replace or augment the 2 s downed poll.
- No files were modified. git status in /home/user/PoliceTablet shows only pre-existing untracked Crimson-Police/, docs/ and tests/.

## sc-dispatch

### crimsonArena state bag: how sc-dispatch reads it (IsInCrimsonArena / IsInCombatSafeZone)

- **Spec claim:** With Config.Integrations.CrimsonArena = true, sc-dispatch's IsInCombatSafeZone() skips shots-fired, person-down and person-dead calls while LocalPlayer.state.crimsonArena.active is true. Crimson-Police sets it with Player(src).state:set('crimsonArena', { active = true, source = 'crimson-police' }, true)
- **Evidence:** client/main.lua:135-155; config.lua:24-34 (CrimsonArena = true at line 33)
- **Implication:** The check is CLIENT-SIDE ONLY (LocalPlayer.state), so the bag MUST be set with replicated = true: Player(src).state:set('crimsonArena', { active = true, source = 'crimson-police' }, true). The value MUST be a table: sc-dispatch does `arena.active` without a type check, so setting a plain boolean `true` would throw 'attempt to index a boolean value' inside the shots-fired and down-detection threads and break them. Only `active` is read; the `source` key is ignored by sc-dispatch, so it is safe for Crimson-Police's own ownership check (only clear when state.crimsonArena and state.crimsonArena.source == 'crimson-police'). Clear with Player(src).state:set('crimsonArena', nil, true). No server-side handler in sc-dispatch reads the bag.

```lua
function IsInCrimsonArena()
    if not (Config.Integrations and Config.Integrations.CrimsonArena) then return false end
    local arena = LocalPlayer.state.crimsonArena
    if arena and arena.active then return true end
    if GetResourceState('Crimson-Arena') ~= 'started' then return false end
    local ok, result = pcall(function()
        return exports['Crimson-Arena']:IsInArena()
    end)
    return ok and result == true
end

function IsInCombatSafeZone()
    return IsInPaintball() or IsInCrimsonArena()
end
```

### Every place IsInCombatSafeZone is checked

- **Spec claim:** Flag suppresses shots-fired, person-down and person-dead calls
- **Evidence:** client/main.lua:3427 (shots fired), 3953 (person down / laststand), 3969 (person dead), 4007 (G-key EMS help request 'mydispatch:requestEMS'). grep finds no other uses; the panic button (client/main.lua:3140-3230) and all server handlers do NOT check it
- **Implication:** While flagged, a participant creates no shots_, playerdown_, playerdead_ or emshelp_ call from their own client. panic_ calls (Y key or /panic) are NOT suppressed and are still created while flagged, so Config.Calls.ownRunCallPrefixes must keep 'panic_'. Because the check happens on the client at send time, a call can still slip through in the short window before the replicated bag reaches the client, or from a modified client. That is why the server backstop is needed.

```lua
-- 3424-3427
local function TriggerShotsFiredAlert()
    local config = Config.Dispatch and Config.Dispatch.ShotsFired
    if not config or not config.Enabled then return end
    if IsInCombatSafeZone() then return end
-- 3953
            if downConfig and downConfig.Enabled and not IsInCombatSafeZone() then
-- 3969
            if deadConfig and deadConfig.Enabled and not IsInCombatSafeZone() then
-- 4007
            if IsControlJustPressed(0, 47) and not calledForHelp and not IsInCombatSafeZone() then
```

### Person-down/dead detection: edge trigger and current config (disabled)  _(spec claim: partial)_

- **Spec claim:** sc-dispatch creates playerdown_<src>_<time> and playerdead_<src>_<time> calls (backstop clears them)
- **Evidence:** client/main.lua:3917-3990; config.lua:172-175 (PlayerDown.Enabled = false, AlertJobs = { 'ambulance'}), config.lua:197-199 (PlayerDead.Enabled = false, AlertJobs = { 'ambulance'}); server/main.lua:3243-3244 and 3270-3271 (server returns if not Enabled); server/main.lua:3200-3201 (mydispatch:requestEMS is gated by PlayerDown.Enabled too)
- **Implication:** In the uploaded config, PlayerDown and PlayerDead are both Enabled = false. The client thread exits, and the server handlers for PlayerDown, PlayerDead and mydispatch:requestEMS return early, so sc-dispatch currently never creates playerdown_, playerdead_ or emshelp_ calls. Still build the PlayerDown and PlayerDead backstop (harmless, and needed if the owner turns these on). Edge trigger: wasInLaststand/wasDead is set to true BEFORE the safe-zone check. If a participant goes down while flagged, sc-dispatch will not send a playerdown alert for that down episode even after Crimson-Police removes the flag, so the plan to 'remove flag, then send hospital:server:EMSDownAlert' does not produce a duplicate sc-dispatch call. However, if the officer later goes from laststand to dead after the flag is removed, a playerdead alert CAN fire (when enabled). sc-dispatch's down check uses only PlayerData.metadata.inlaststand and metadata.isdead (via GetPlayerData on the client), not ped death.

```lua
if (not downConfig or not downConfig.Enabled) and (not deadConfig or not deadConfig.Enabled) then 
        DebugPrint(' Player down/death detection DISABLED')
        return 
    end
...
        if isLastStand and not wasInLaststand and not isMetaDead then
            wasInLaststand = true

            if downConfig and downConfig.Enabled and not IsInCombatSafeZone() then
                local info = exports['sc-dispatch']:GetPlayerInfo()
                TriggerServerEvent('sc-dispatch:server:PlayerDown', {
                    coords = info.coords,
                    street = info.street,
                    sex = info.sex
                })
```

### sc-dispatch:server:ToggleResponding: server handler, args, validation

- **Spec claim:** Net event sc-dispatch:server:ToggleResponding (callId, isResponding); a second read-only handler can be added
- **Evidence:** server/main.lua:899-990
- **Implication:** It is a real net event, so Crimson-Police adds its own handler: RegisterNetEvent('sc-dispatch:server:ToggleResponding', function(callId, isResponding) local src = source ... end). It MUST be RegisterNetEvent, not AddEventHandler: FiveM only delivers client-originated events to handlers in resources that registered the name as a net event. Capture `source` into a local on the first line, before any MySQL await or Wait, because `source` changes after a yield. Argument order is (callId, isResponding). callId may be a Lua number (row id), a numeric string ("123") or a unique_id string. isResponding is a boolean from all three sc-dispatch senders; test it with `if isResponding then`. sc-dispatch does NO validation (no job, duty, call-exists or received-the-call check), so Crimson-Police's mdt_dispatch lookup is the only guard. Both handlers run independently; Crimson-Police cannot and must not block sc-dispatch's handler. EMS and fire players also send this event.

```lua
RegisterNetEvent('sc-dispatch:server:ToggleResponding', function(callId, isResponding)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    
    -- Convert callId to string for consistent comparison
    local callIdStr = tostring(callId)
    ...
    if not RespondingOfficers[callIdStr] then
        RespondingOfficers[callIdStr] = {}
    end
    if isResponding then
        RespondingOfficers[callIdStr][src] = true
    ...
    else
        RespondingOfficers[callIdStr][src] = nil
    end
```

### Who sends ToggleResponding and with what callId

- **Spec claim:** sc-dispatch's client sends it when an officer responds, when a dispatcher assigns them (AutoResponding = true) and when they are detached
- **Evidence:** client/main.lua:2994-3014 (NUI 'toggleResponding'; html/index.html:847-866 respondToCall toggles call.isResponding; F10 panel key WaypointKey 'G' sends dispatchPanelRespond, client/main.lua:3062-3068); client/main.lua:2305-2320 (AssignedToCall); client/main.lua:2277-2282 (DetachedFromCall); server/main.lua:7039-7084 (DispatcherAssign), 7125-7180 (DispatcherAssignAll), 7376-7400 (DispatcherDetach)
- **Implication:** Exactly three senders: (1) the officer's own F10-panel toggle, which sends true and a second press sends false, with callId = the panel entry id: the unique_id string, or the integer row id for calls without one; (2) a dispatcher assignment, which sends true, with callId taken from the console (built from the mdt_dispatch.unique_id column, so usually a string, e.g. '123' for a numeric call); (3) a dispatcher detach, which sends false, with callId = a string key. The MDT tablet (html/police/script.js) has no responding control. html/dispatch/script.js is not in fxmanifest `files` and its 'respond' only sets a waypoint. The client NEVER sends ToggleResponding(false) when a call is cleared, so entries must be expired or re-checked.

```lua
-- responder toggle (NUI)
        TriggerServerEvent('sc-dispatch:server:ToggleResponding', data.callId, data.responding)
-- dispatcher assignment
    if info.autoResponding and info.callId ~= nil then
        TriggerServerEvent('sc-dispatch:server:ToggleResponding', info.callId, true)
    end
-- dispatcher detach
    TriggerServerEvent('sc-dispatch:server:ToggleResponding', info.callId, false)
-- server side of detach passes the RespondingOfficers key (a string)
    for callIdStr, officers in pairs(RespondingOfficers) do
        if officers[unitSrc] then callId = callIdStr break end
    end
    TriggerClientEvent('sc-dispatch:client:DetachedFromCall', unitSrc, { callId = callId, dispatcher = ... })
```

### AutoResponding / dispatcher assignment (single and ALL-UNITS)

- **Spec claim:** When a dispatcher assigns an officer, AutoResponding = true makes the assigned client send ToggleResponding
- **Evidence:** config.lua:1175 (AutoResponding = true); server/main.lua:7070-7079 and 7160-7169; client/main.lua:2318-2320
- **Implication:** Crimson-Police does not need to listen to sc-dispatch:client:AssignedToCall; the ToggleResponding(callId, true) covers assignment. If a server owner sets Config.DispatcherMode.AutoResponding = false, assignments no longer send ToggleResponding and Crimson-Police will not see them; list this in the owner checklist. sc-mdt:server:DispatcherAssignAll sends AssignedToCall (allCall = true) to EVERY on-duty unit in UnitPositions whose type matches the call's department and who is not already responding, so an ALL-UNITS call ends the run of every police participant on duty at once (expected, per the spec's real-calls-first rule).

```lua
TriggerClientEvent('sc-dispatch:client:AssignedToCall', unitSrc, {
        callId = callId,
        title = row[1].type or 'Dispatch Call',
        street = row[1].street or '',
        message = row[1].message or '',
        coords = coords,
        dispatcher = Dispatcher and GetPlayerFullName(Dispatcher) or 'Dispatch',
        autoWaypoint = Config.DispatcherMode.AutoWaypoint ~= false,
        autoResponding = Config.DispatcherMode.AutoResponding ~= false,
    })
```

### How callId maps to unique_id vs row id

- **Spec claim:** callId is the call's unique_id when it has one, otherwise its row id
- **Evidence:** server/main.lua:2888-2911 (client id selection and unique_id persistence), 2914-2926 (buildDispatch id), 2598-2600 (GetPoliceDispatch replaces id by unique_id), 6993-6994 (dispatcher console cid), 3015 (return value)
- **Implication:** For calls created without data.unique_id (numeric calls), sc-dispatch writes the row id as a STRING into mdt_dispatch.unique_id (e.g. '123'). The same call can therefore arrive as the number 123 (a live broadcast in the F10 panel) or the string '123' (console assignment, detach, DB-loaded lists). Normalize every incoming id before using it as a map key: `local n = tonumber(callId); local key = (n and n == math.floor(n)) and ('%d'):format(n) or tostring(callId)`. This also guards against a JSON-decoded float giving '123.0'. Better still, use the canonical key returned by the DB lookup: row.unique_id if it is non-empty, otherwise tostring(row.id). ems_dispatch and fire_dispatch have their own independent row ids, so a numeric id is only meaningful per table.

```lua
local policeClientId = data.unique_id or insertId
        local emsClientId = data.unique_id or emsInsertId
        local fireClientId = data.unique_id or fireInsertId
...
        if insertId then
            pcall(function() MySQL.update('UPDATE mdt_dispatch SET unique_id = ? WHERE id = ?', { tostring(policeClientId), insertId }) end)
        end
...
            if c.unique_id and c.unique_id ~= '' then c.id = c.unique_id end   -- GetPoliceDispatch
...
            local cid = (c.unique_id and c.unique_id ~= '') and c.unique_id or c.id   -- dispatcher console
```

### mdt_dispatch table schema (sql/schema-qbox.sql) and the unique_id column  _(spec claim: partial)_

- **Spec claim:** Table mdt_dispatch has id, unique_id, active; read-only lookup SELECT unique_id FROM mdt_dispatch WHERE (id = ? OR unique_id = ?) AND active = 1
- **Evidence:** sql/schema-qbox.sql:171-184 (no unique_id column); server/main.lua:416-421 (runtime migration adds it); server/main.lua:424-425 (all rows set inactive on sc-dispatch start)
- **Implication:** unique_id (VARCHAR(64) NULL) is NOT in schema-qbox.sql; sc-dispatch adds it when it starts. The spec's query fails with 'Unknown column' on a DB where sc-dispatch has never started, so: ensure sc-dispatch starts before Crimson-Police (server.cfg order plus a dependency), and wrap the lookup in pcall, treating an error as 'not a real call' and logging it. `active` is TINYINT(1); oxmysql returns it as a Lua boolean if selected, so filter in SQL (`active = 1`). The `responders` column is never written by the code; responding state is NOT in the DB. Legacy rows may have unique_id NULL, so SELECT both `id, unique_id`.

```lua
CREATE TABLE `mdt_dispatch` (
    `id` INT AUTO_INCREMENT PRIMARY KEY,
    `type` VARCHAR(50) NOT NULL,
    `message` TEXT,
    `coords` TEXT,
    `street` VARCHAR(255),
    `caller` VARCHAR(100),
    `priority` INT DEFAULT 2,
    `responders` LONGTEXT,
    `active` TINYINT(1) DEFAULT 1,
    `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX `idx_active` (`active`),
    INDEX `idx_priority` (`priority`)
) ENGINE=InnoDB ...;
-- added at runtime by sc-dispatch onResourceStart:
        pcall(function() MySQL.query.await('ALTER TABLE `mdt_dispatch` ADD COLUMN `unique_id` VARCHAR(64) NULL') end)
        pcall(function() MySQL.query.await('CREATE INDEX `idx_mdt_dispatch_uid` ON `mdt_dispatch` (`unique_id`)') end)
```

### Real/active call lookup query and parameter order

- **Spec claim:** SELECT unique_id FROM mdt_dispatch WHERE (id = ? OR unique_id = ?) AND active = 1, with the number and the string form of callId
- **Evidence:** server/main.lua:7050-7051 (sc-dispatch's own identical lookup, placeholders in the opposite order)
- **Implication:** Use: MySQL.query.await('SELECT id, unique_id FROM mdt_dispatch WHERE (id = ? OR unique_id = ?) AND active = 1 LIMIT 1', { tonumber(callId) or 0, normalizedString }). The parameter order must match the placeholder order: number first for `id = ?`, string second for `unique_id = ?`. Use `or 0` (as sc-dispatch does), not nil. Because MySQL casts a non-numeric string to 0 when comparing it with an INT, never pass the raw string as the id parameter. Only mdt_dispatch is checked. An EMS-only call (e.g. playerdown_ with AlertJobs {'ambulance'}) lives only in ems_dispatch, so it is correctly ignored for police.

```lua
local cidStr, cidNum = tostring(callId), tonumber(callId) or 0
    local row = MySQL.query.await('SELECT coords, type, message, street FROM mdt_dispatch WHERE (unique_id = ? OR id = ?) AND active = 1 LIMIT 1', { cidStr, cidNum })
```

### sc-dispatch:server:callClearedByOfficer

- **Spec claim:** Event sc-dispatch:server:callClearedByOfficer (callId): remove that call from the responding map
- **Evidence:** server/main.lua:3293-3304 (ManualClearCall), 3307-3318 and 3320-3331 (client-triggered ClearNotification net events), 7184-7191 (DispatcherClearCall)
- **Implication:** It is a SERVER-LOCAL event (TriggerEvent), with one argument: callId, in whatever form the clearer had (number or string). Listen with AddEventHandler('sc-dispatch:server:callClearedByOfficer', function(callId) ... end), NOT RegisterNetEvent, or any client could fire it to lift their own 'On a call' block. It means the call was cleared for everyone, so remove every officer's entry for the normalized key. It is NOT fired by the exports['sc-dispatch']:ClearNotification export itself, by the 5-minute auto-clear (ScheduleDispatchClear), by /cleardispatch, by /clearalldispatches, or by an sc-dispatch restart. Crimson-Police's own backstop ClearNotification calls therefore fire no event either.

```lua
RegisterNetEvent('sc-dispatch:server:ManualClearCall', function(callId)
    ...
    exports['sc-dispatch']:ClearNotification(callId, nil)
    TriggerEvent('sc-dispatch:server:callClearedByOfficer', callId)
end)
...
    if isClientCall then TriggerEvent('sc-dispatch:server:callClearedByOfficer', uniqueId) end
...
    exports['sc-dispatch']:ClearNotification(callId, nil)
    TriggerEvent('sc-dispatch:server:callClearedByOfficer', callId) -- releases sc-witness scene, etc.
```

### Server-side responding state storage

- **Spec claim:** (focus) how sc-dispatch stores responding state
- **Evidence:** server/main.lua:32 (declaration), 1001-1006 (ClearRespondingForCall), 1009-1030 (playerDropped cleanup), 1064 (auto-clear cleanup), 430-431 (reset on start); no export exposes it
- **Implication:** The map is a file-local Lua table: not exported, not in GlobalState or state bags, not in the DB. Crimson-Police must keep its own map, e.g. responding[src][key] = { since = os.time(), real = true }. An officer can be responding to several calls at once (sc-dispatch never un-responds a previous call), so key the map per call. sc-dispatch clears its map on auto-clear, playerDropped and resource start, but NOT on ClearNotification or ManualClearCall; do not rely on mirroring its behaviour.

```lua
local RespondingOfficers = {} -- { [callId] = { [source] = true, ... } }
...
local function ClearRespondingForCall(callId)
    local callIdStr = tostring(callId)
    RespondingOfficers[callIdStr] = nil
    CallReporters[callIdStr] = nil
    CallHelpNotified[callIdStr] = nil
end
```

### Auto-clear (no event) and sc-dispatch restart

- **Spec claim:** Auto-cleared calls fire no event, so a responding entry expires 20 minutes after the last ToggleResponding
- **Evidence:** config.lua:41-42 (AutoClear = true, AutoClearTime = 5); server/main.lua:1036-1110 (ScheduleDispatchClear: UPDATE ... SET active = 0, ClearRespondingForCall, PoliceDispatchCleared broadcast; no TriggerEvent); server/main.lua:424-434 (onResourceStart: UPDATE mdt_dispatch SET active = 0 WHERE active = 1; RespondingOfficers = {})
- **Implication:** Every sc-dispatch call auto-deactivates in mdt_dispatch after 5 minutes, with no server event. The 20-minute respondingExpiry is a valid fallback, but for faster and more accurate 'On a call' release, re-run the active lookup for the officer's live entries when they try to accept a mission and drop any entry whose call is no longer active. Also add AddEventHandler('onResourceStart'/'onResourceStop', function(res) if res == 'sc-dispatch' then wipe the responding map end end), because an sc-dispatch restart deactivates all calls silently.

```lua
local sql = 'UPDATE ' .. tableName .. ' SET active = 0 WHERE (id = ? OR unique_id = ?) AND active = 1'
...
    -- Clear police dispatches
    MySQL.update('UPDATE mdt_dispatch SET active = 0 WHERE active = 1')
...
    RespondingOfficers = {}
```

### exports['sc-dispatch']:ClearNotification(uniqueId, jobTable): signature and jobTable semantics

- **Spec claim:** ClearNotification('shots_<src>_<time>', { 'police' }) clears the call; any job list containing police clears the call for every job in Config.Police.AllowedJobs, which lists sast, fib and bcso
- **Evidence:** server/main.lua:3021-3108; config.lua:278
- **Implication:** Signature: (uniqueId, jobTable); returns true, or false when uniqueId is nil. The DB rows in mdt_dispatch, ems_dispatch AND fire_dispatch are deactivated REGARDLESS of jobTable; jobTable only chooses which on-duty clients get the 'cleared' broadcast. { 'police' } sets clearPolice, so the broadcast reaches on-duty players whose job is in Config.Police.AllowedJobs = { 'police', 'sheriff', 'fib', 'ranger', 'sasp', 'bcso', 'sast', 'k9' }, plus FIB (who always get it). { 'police', 'ambulance' } also reaches Config.EMS.AllowedJobs = { 'ambulance' }. Passing nil reaches all police and EMS jobs (sc-dispatch's own ManualClearCall does this). It uses MySQL.update.await, so call it from inside an event handler or CreateThread, wrapped in pcall. ALWAYS pass the string id (e.g. 'shots_12_1759050000'), never a number: a numeric id would also deactivate an unrelated ems_dispatch or fire_dispatch row with the same row id. It does NOT fire callClearedByOfficer and does NOT touch sc-dispatch's RespondingOfficers. Clearing a non-existent id is harmless (0 rows updated; clients ignore an unknown id).

```lua
exports('ClearNotification', function(uniqueId, jobTable)
    if not uniqueId then return false end
    CallReporters[tostring(uniqueId)] = nil
    CallHelpNotified[tostring(uniqueId)] = nil
    MySQL.update.await('UPDATE mdt_dispatch SET active = 0 WHERE id = ? OR unique_id = ?', { uniqueId, tostring(uniqueId) })
    MySQL.update.await('UPDATE ems_dispatch SET active = 0 WHERE id = ? OR unique_id = ?', { uniqueId, tostring(uniqueId) })
    pcall(function() MySQL.update.await('UPDATE fire_dispatch SET active = 0 WHERE id = ? OR unique_id = ?', { uniqueId, tostring(uniqueId) }) end)
    local players = QBCore.Functions.GetQBPlayers()
    for _, player in pairs(players) do
        if player and player.PlayerData.job.onduty then
            ...
            if jobTable then
                local clearPolice = false
                local clearEMS = false
                for _, job in ipairs(jobTable) do
                    for _, p in ipairs(Config.Police.AllowedJobs) do if job == p then clearPolice = true break end end
                    for _, e in ipairs(Config.EMS.AllowedJobs) do if job == e then clearEMS = true break end end
                    if string.find(job, 'police') or string.find(job, 'sheriff') or string.find(job, 'leo') then clearPolice = true end
                    if string.find(job, 'ambulance') or string.find(job, 'ems') or string.find(job, 'hospital') then clearEMS = true end
                end
                ...
                if clearPolice and (isPlayerPolice or isPlayerFIB) then
                    TriggerClientEvent('sc-mdt:client:PoliceDispatchCleared', player.PlayerData.source, uniqueId)
                end
                if clearEMS and isPlayerEMS then
                    TriggerClientEvent('sc-mdt:client:EMSDispatchCleared', player.PlayerData.source, uniqueId)
                end
            else  -- nil jobTable: every Config.Police.AllowedJobs and Config.EMS.AllowedJobs player
            ...
    return true
end)
```

### AddNotification unique_id formats (shots_, panic_, emshelp_, playerdown_, playerdead_)

- **Spec claim:** shots_, panic_, emshelp_, playerdown_ and playerdead_ followed by <src>_<time> (sc-dispatch)
- **Evidence:** server/main.lua:3145 (panic_), 3171 (shots_), 3203 (emshelp_), 3245 (playerdown_), 3272 (playerdead_); also 4798 and 4812 (admin test commands use tostring(math.random(1000000, 9999999))); calls without unique_id use the row id (2893)
- **Implication:** src is the numeric server id and os.time() is integer epoch SECONDS, so ids look like 'shots_12_1759050000'. Build them the same way: ('shots_%d_%d'):format(src, t). For own-run prefix matching use plain find: `id:find(prefix .. src .. '_', 1, true) == 1`. The trailing underscore keeps 'playerdown_1_' from matching 'playerdown_12_'. For 'npccall-' do NOT use an unescaped Lua pattern ('-' is a magic character): use `id:sub(1, 8) == 'npccall-'` or `id:find('npccall-', 1, true) == 1`. The emshelp_ event is 'mydispatch:requestEMS' (not sc-dispatch-prefixed). panic_ requires the sender to be on duty (server/main.lua:3143).

```lua
local uniqueId = 'panic_' .. src .. '_' .. os.time()
    local uniqueId = 'shots_' .. src .. '_' .. os.time()
    local uniqueId = 'emshelp_' .. src .. '_' .. os.time()
    local uniqueId = 'playerdown_' .. src .. '_' .. os.time()
    local uniqueId = 'playerdead_' .. src .. '_' .. os.time()
```

### sc-dispatch:server:ShotsFired payload, server handler and timing of the id  _(spec claim: partial)_

- **Spec claim:** Net event sc-dispatch:server:ShotsFired (data: coords, street, zone); sc-dispatch names the call shots_<src>_<os.time()>; wait 1 second and clear for the current and the previous second
- **Evidence:** client/main.lua:3483-3487 (payload), 3459-3478 (zone/street); server/main.lua:3152-3193
- **Implication:** Payload keys are coords (vector3), street and zone. The server does NOT check job, duty or the crimsonArena flag. The id is built synchronously with no yield before os.time(), in the same frame the net event is dispatched to every resource. Crimson-Police's RegisterNetEvent handler must do `local src = source; local t = os.time()` FIRST, then Wait(Config.Alerts.backstopDelay * 1000), then ClearNotification(('shots_%d_%d'):format(src, t), { 'police' }) and the same for t - 1. The spec's 'current and previous second' is only correct if 'current' is captured BEFORE the wait; os.time() after a 1-second Wait would be t+1. Handler order across resources is not guaranteed (sc-dispatch may run after Crimson-Police and cross a second boundary), so also clear t + 1; a surplus clear is harmless. For the 300 m check, use the server-side ped position (GetEntityCoords(GetPlayerPed(src))) rather than data.coords (client-supplied; the stored call coords may be replaced by house coords). The unique_id column is written by a non-awaited MySQL.update after the insert; the 1-second wait covers this in practice.

```lua
-- client
    TriggerServerEvent('sc-dispatch:server:ShotsFired', {
        coords = coords,          -- GetEntityCoords(playerPed) (vector3)
        street = streetName,      -- 'Street & Crossing'
        zone = zoneName           -- GetNameOfZone(x, y, z) code, e.g. 'DOWNT' (not a label)
    })
-- server
RegisterNetEvent('sc-dispatch:server:ShotsFired', function(data)
    local src = source
    if not data or not data.coords then return end
    local config = Config.Dispatch and Config.Dispatch.ShotsFired
    if not config or not config.Enabled then return end
    local dispatchCoords = data.coords
    if GetResourceState('sc-houserobbery') == 'started' then
        local ok, houseCoords = pcall(function()
            return exports['sc-houserobbery']:GetPlayerHouseCoords(src)
        end)
        if ok and houseCoords then dispatchCoords = houseCoords end
    end
    local uniqueId = 'shots_' .. src .. '_' .. os.time()
    local dispatchData = { job_table = config.AlertJobs or { 'police' }, ..., unique_id = uniqueId }
    exports['sc-dispatch']:AddNotification(dispatchData)
end)
```

### sc-dispatch:server:PlayerDown / PlayerDead payloads and ids  _(spec claim: partial)_

- **Spec claim:** Net events sc-dispatch:server:PlayerDown and sc-dispatch:server:PlayerDead (data); ids playerdown_<src>_<time> / playerdead_<src>_<time>; clear with { 'police', 'ambulance' } if the sender still carries the flag
- **Evidence:** client/main.lua:3955-3959 and 3971-3975 (payload); client/main.lua:3314-3352 (GetPlayerInfo); server/main.lua:3238-3262 (PlayerDown), 3265-3289 (PlayerDead); config.lua:174-175, 198-199
- **Implication:** Payload is { coords = vector3, street = 'A / B' (slash from GetPlayerInfo), sex = 'male'|'female'|'Unknown' }. The ids use the same seconds rule as ShotsFired: capture t = os.time() before the wait and clear t-1, t and t+1. With the uploaded config, both AlertJobs are { 'ambulance' } and both types are Enabled = false, so the server returns before creating a call (the backstop is currently a no-op but correct). { 'police', 'ambulance' } broadcasts the clear to police and EMS jobs; the DB rows are cleared in every table regardless. Check the flag server-side with Player(src).state.crimsonArena (and .source == 'crimson-police') at receipt time, before the wait.

```lua
TriggerServerEvent('sc-dispatch:server:PlayerDown', {
                    coords = info.coords,
                    street = info.street,
                    sex = info.sex
                })
-- server
RegisterNetEvent('sc-dispatch:server:PlayerDown', function(data)
    local src = source
    if not data or not data.coords then return end
    local config = Config.Dispatch and Config.Dispatch.PlayerDown
    if not config or not config.Enabled then return end
    local uniqueId = 'playerdown_' .. src .. '_' .. os.time()
    ...
    exports['sc-dispatch']:AddNotification({
        job_table = config.AlertJobs or { 'ambulance', 'doctor' },
        ...
        unique_id = uniqueId,
        caller_source = src,
    })
end)
-- PlayerDead: same shape, uniqueId = 'playerdead_' .. src .. '_' .. os.time(), job_table = config.AlertJobs or { 'ambulance', 'doctor', 'police' }
```

### Shots-fired exemption for on-duty police/bcso/fib and AlertJobs

- **Spec claim:** Outside Crimson-Police, sc-dispatch only skips shots-fired calls for on-duty police, bcso and fib, and alerts the jobs in Config.Dispatch.ShotsFired.AlertJobs (which include sast and fib)
- **Evidence:** client/main.lua:3429-3439 (exemption inside TriggerShotsFiredAlert); config.lua:125 (AlertJobs), 123 (Cooldown = 15), 124 (AreaRadius = 150.0), 146 (IgnoreSuppressed = false), 148-162 (ExcludedWeapons)
- **Implication:** Hard-coded job names, client side, only when job.onduty is truthy. sast, sasp, sheriff, ranger and k9 are NOT exempt, which confirms the spec note. The server-owner edit for SAST belongs in client/main.lua TriggerShotsFiredAlert at line 3433. Other built-in skips: excluded weapons (stungun, flare, pepper spray, hunting and marksman rifles, etc.), excluded zones, and a 15-second per-area cooldown on a 150 m grid. Note that 'trooper' is in AlertJobs but not in Config.Police.AllowedJobs, so ClearNotification with { 'police' } will not broadcast the clear to a 'trooper' job; this only matters if that job exists.

```lua
-- Do not generate automatic shots-fired calls for on-duty law enforcement
    local Player = QBCore.Functions.GetPlayerData()
    if Player and Player.job and Player.job.onduty then
        local jobName = Player.job.name
        if jobName == 'police' or jobName == 'bcso' or jobName == 'fib' then
            ...
            return
        end
    end
-- config.lua:125
        AlertJobs = { 'police', 'sheriff', 'trooper', 'sasp', 'bcso', 'sast', 'fib', 'k9' }, -- Jobs to alert
```

### exports['sc-dispatch']:IsPlayerSuspended(citizenid, jobname)

- **Spec claim:** exports['sc-dispatch']:IsPlayerSuspended(citizenid, jobname): refuse suspended officers
- **Evidence:** server/main.lua:5281-5293; sql/fib_ia_gtf.sql:15-35 (fib_suspensions: status 'Active' or 'Lifted', job = internal job name); server/main.lua:5320-5327 (sc-dispatch's own callback passes the current job)
- **Implication:** Arguments are (citizenid, jobname), in that order; it returns a plain boolean. jobname is optional: pass player.PlayerData.job.name to check a suspension in the active job only, or nil or '' to refuse a suspension in ANY job. Suspensions are per job, with no expiry column. It FAILS OPEN (returns false) on any DB error, e.g. if fib_ia_gtf.sql was never imported, so log it if you need certainty. It is synchronous (MySQL.scalar.await): call it from an event handler, callback or thread, wrapped in pcall, and with GetResourceState('sc-dispatch') == 'started'.

```lua
exports('IsPlayerSuspended', function(citizenid, jobname)
    if not citizenid then return false end
    local id
    local ok = pcall(function()
        if jobname and jobname ~= '' then
            id = MySQL.scalar.await('SELECT id FROM fib_suspensions WHERE citizenid = ? AND job = ? AND status = ? LIMIT 1', { citizenid, jobname, 'Active' })
        else
            id = MySQL.scalar.await('SELECT id FROM fib_suspensions WHERE citizenid = ? AND status = ? LIMIT 1', { citizenid, 'Active' })
        end
    end)
    if not ok then return false end
    return id ~= nil
end)
```

### Config.Integrations.CrimsonArena

- **Spec claim:** Config.Integrations.CrimsonArena = true (already set)
- **Evidence:** config.lua:24-34
- **Implication:** No change needed. If the owner sets it to false, IsInCrimsonArena() returns false immediately and the flag stops suppressing anything; then only the backstop works (shots within 300 m). Add this to the owner checklist and optionally print a startup warning (Crimson-Police cannot read sc-dispatch's Config, so it can only document it).

```lua
Config.Integrations = {
    PugPaintball = false,
    CrimsonArena = true,
}
```

### Config.Police.AllowedJobs (and EMS / FIB lists)

- **Spec claim:** Config.Police.AllowedJobs already lists sast, fib and bcso
- **Evidence:** config.lua:277-279 (Police), 302-303 (EMS), 481-482 (FIB)
- **Implication:** Every Crimson-Police department job (sast, fib, bcso, police) receives police calls and ClearNotification broadcasts. ClearNotification and AddNotification match by job NAME in AllowedJobs only; job.type 'leo' is not enough for them (AllowedJobTypes is used only in IsPoliceJob access checks). A new department job must be added to AllowedJobs by the owner.

```lua
Config.Police = {
    AllowedJobs = { 'police', 'sheriff', 'fib', 'ranger', 'sasp', 'bcso', 'sast', 'k9' },
    AllowedJobTypes = { 'leo', 'police' },
...
Config.EMS = {
    AllowedJobs = { 'ambulance'},
...
Config.FIB = {
    AllowedJobs = { 'fib' },
```

### Config.Roster.CommandGrade

- **Spec claim:** Config.Roster.CommandGrade = 4: grade 4 and up count as command staff in SC-Dispatch
- **Evidence:** config.lua:707-711; server/main.lua:3747-3762 (HasBossAccess)
- **Implication:** This is informational only; Crimson-Police uses its own supervisorGrade. The rule is job.grade.level >= 4, OR job.isboss, OR the grade marked isboss in shared jobs, with per-job overrides (fire = 5). Documentation should say 'grade 4 and up, or any boss grade'.

```lua
CommandGrade = 4,
    CommandGradeOverrides = {
        -- police = 4,
        fire = 5,   -- Lieutenant and up manage the fire roster
    },
...
local function HasBossAccess(Player, job)
    local playerJob = Player.PlayerData.job
    if not playerJob or playerJob.name ~= job then return false end
    local gradeLevel = playerJob.grade and playerJob.grade.level or 0
    local requiredGrade = (Config.Roster and Config.Roster.CommandGradeOverrides and Config.Roster.CommandGradeOverrides[job])
        or (Config.Roster and Config.Roster.CommandGrade)
        or BossGrades[job] or 4
    if playerJob.isboss == true then return true end
    ...
    return gradeLevel >= requiredGrade
end
```

### Adding a second handler: net vs local events

- **Spec claim:** (focus) whether ToggleResponding is a net event so a second handler can be added
- **Evidence:** server/main.lua:899 (RegisterNetEvent ToggleResponding), 3152 (RegisterNetEvent ShotsFired), 3238 (RegisterNetEvent PlayerDown), 3265 (RegisterNetEvent PlayerDead), 3303/3317/3330/7189 (TriggerEvent callClearedByOfficer, local)
- **Implication:** In modules/integrations/sc_dispatch/: use RegisterNetEvent(name, handler) for ToggleResponding, ShotsFired, PlayerDown and PlayerDead (these come from clients; an AddEventHandler alone does not receive net-sourced events in FiveM). Use AddEventHandler only for callClearedByOfficer (server-local). Never TriggerServerEvent or TriggerEvent any of these yourself.

```lua
RegisterNetEvent('sc-dispatch:server:ToggleResponding', function(callId, isResponding)
RegisterNetEvent('sc-dispatch:server:ShotsFired', function(data)
RegisterNetEvent('sc-dispatch:server:PlayerDown', function(data)
RegisterNetEvent('sc-dispatch:server:PlayerDead', function(data)
    TriggerEvent('sc-dispatch:server:callClearedByOfficer', callId)
```

### exports['sc-dispatch']:AddNotification(data)

- **Spec claim:** Do not use: missions never create dispatch calls
- **Evidence:** server/main.lua:2815-3018
- **Implication:** Do not call it. For reference, it returns data.unique_id or the row id. It also fires the internal event 'sc-dispatch:server:witnessForward' (sc-witness NPC witnesses), so any call it creates can spawn witnesses. The EMS request for a downed participant goes through sc-ambulance's hospital:server:EMSDownAlert, not this export.

```lua
exports('AddNotification', function(data)
    if not data then return nil end
    local jobTable = data.job_table or {}
    ...
        return data.unique_id or mainInsertId
    end
    return nil
end)
```

### sc-dispatch:client:AssignedToCall (info)

- **Spec claim:** Not needed: the assigned officer's client also sends ToggleResponding
- **Evidence:** client/main.lua:2305-2320; server/main.lua:7070-7079, 7160-7169
- **Implication:** Confirmed; no listener needed while AutoResponding is true. info = { callId, title, street, message, coords, dispatcher, autoWaypoint, autoResponding, allCall? }.

```lua
RegisterNetEvent('sc-dispatch:client:AssignedToCall', function(info)
    if type(info) ~= 'table' then return end
    ...
    if info.autoResponding and info.callId ~= nil then
        TriggerServerEvent('sc-dispatch:server:ToggleResponding', info.callId, true)
    end
```

### Other findings

- DISCREPANCY (schema): sql/schema-qbox.sql defines mdt_dispatch WITHOUT a unique_id column. sc-dispatch adds `unique_id VARCHAR(64) NULL` plus index idx_mdt_dispatch_uid at runtime in its onResourceStart (server/main.lua:416-421). Crimson-Police's lookup must run only after sc-dispatch has started at least once; wrap it in pcall and treat an error as 'not a real call'.
- DISCREPANCY (config): Config.Dispatch.PlayerDown.Enabled = false and Config.Dispatch.PlayerDead.Enabled = false (config.lua:174, 198), with AlertJobs = { 'ambulance'} for both. sc-dispatch therefore currently creates NO playerdown_, playerdead_ or emshelp_ calls (mydispatch:requestEMS is also gated by PlayerDown.Enabled, server/main.lua:3200-3201). The spec wording implies they are live; the backstop for them is dormant but should still be built.
- DISCREPANCY (timing): for the 'current and previous second' clear to work, capture `local t = os.time()` at the very top of Crimson-Police's ShotsFired/PlayerDown/PlayerDead handler, BEFORE Wait(backstopDelay*1000). os.time() taken after the wait is one second late. Because cross-resource handler order is not guaranteed, clear t-1, t and t+1 (surplus clears are harmless: 0 rows, unknown-id broadcast ignored by clients).
- SECURITY: sc-dispatch's ToggleResponding does no validation at all (server/main.lua:899-903). Any client can TriggerServerEvent('sc-dispatch:server:ToggleResponding', <any active real call id>, true). The mdt_dispatch active check only proves the call exists, not that the officer was dispatched to it, so a player can still claim a free 'real_call' abandon on any live call. Mitigations inside the spec: require the sender to be an on-duty police-job participant, log every free abandon with the call id to the audit log, and apply the 60-second un-mark rule. Consider flagging repeated free abandons for supervisor review.
- SECURITY: register callClearedByOfficer with AddEventHandler ONLY. If Crimson-Police used RegisterNetEvent for it, clients could fire it to lift their own 'On a call' block.
- GOTCHA: callClearedByOfficer is NOT fired by the ClearNotification export, the 5-minute auto-clear (Config.Dispatch.AutoClear = true, AutoClearTime = 5), /cleardispatch, /clearalldispatches, or an sc-dispatch restart (which sets every mdt_dispatch row active = 0 and resets its own RespondingOfficers). Handle onResourceStart/onResourceStop for 'sc-dispatch' by wiping the responding map. Consider re-checking `SELECT 1 FROM mdt_dispatch WHERE (id = ? OR unique_id = ?) AND active = 1` for the officer's live entries on each accept attempt, so 'On a call' clears within about 5 minutes instead of waiting for the 20-minute expiry.
- GOTCHA: the same numeric call can arrive as number 123 (live F10 panel entry) or string '123' (dispatcher console / detach / DB-loaded list), because AddNotification writes tostring(rowId) into unique_id. Normalize: `local n = tonumber(id); key = (n and n == math.floor(n)) and ('%d'):format(n) or tostring(id)`, or better, key by the DB row's unique_id (fallback tostring(row.id)).
- GOTCHA: ClearNotification deactivates rows in mdt_dispatch, ems_dispatch AND fire_dispatch by `id = ? OR unique_id = ?`. Passing a NUMBER would also deactivate an unrelated EMS or fire row with the same numeric id. Crimson-Police must only ever pass its own string ids (shots_/playerdown_/playerdead_ with src and time).
- GOTCHA: ClearNotification and IsPlayerSuspended use MySQL.*.await internally. Call them only from inside event handlers, callbacks or CreateThread, never at file scope, and wrap them in pcall with a GetResourceState('sc-dispatch') == 'started' guard.
- GOTCHA: the ClearNotification broadcast only reaches players with job.onduty = true, and only jobs listed in Config.Police.AllowedJobs, Config.EMS.AllowedJobs or Config.FIB.AllowedJobs (fire always gets a fire clear). A job that only matches by job.type 'leo' does not get it.
- GOTCHA: the dispatcher console for a 'dispatch' job (dept 'both') can drag a police unit onto an EMS call via sc-mdt:server:DispatcherAssign, which does not check department. The callId is then an ems_dispatch id. A string id like playerdown_… is absent from mdt_dispatch and is correctly ignored. A bare numeric EMS row id could collide with an unrelated police row id in mdt_dispatch. This is a rare edge case; accept it or also require the matched row's type/title to be non-empty.
- GOTCHA: DispatcherAssignAll (an 'ALL UNITS RESPOND' call) sends an auto-responding assignment to every on-duty unit of the call's department that is not already responding, so every police participant's run ends at once (expected behaviour).
- GOTCHA: panic_ calls are never suppressed by the crimsonArena flag (TriggerPanicButton, client/main.lua:3140+, has no IsInCombatSafeZone check; the server requires only job.onduty). That is correct: officers can still press the panic button during a mission. Keep 'panic_' in ownRunCallPrefixes so a partner's panic does not end the other partners' runs.
- GOTCHA: sc-dispatch's client down detection edge-triggers (wasInLaststand/wasDead are set before the safe-zone check). If a participant goes down while flagged, no sc-dispatch playerdown alert will fire for that down episode even after the flag is removed, so no duplicate with the EMSDownAlert. A later transition to dead after flag removal can still produce playerdead_ (when enabled).
- GOTCHA: the crimsonArena value must be a table with an `active` field. sc-dispatch indexes `arena.active` without a type check (client/main.lua:142-143), so setting a boolean would throw every time a flagged player fires, breaking shots-fired detection for them.
- INFO: sc-dispatch falls back to exports['Crimson-Arena']:IsInArena() when the bag is not active and a resource named 'Crimson-Arena' is started. That resource is separate from Crimson-Police; Crimson-Police must not remove a crimsonArena bag whose source is not 'crimson-police'.
- INFO: sc-dispatch keeps its responding state only in the file-local `RespondingOfficers = { [callIdStr] = { [src] = true } }` (server/main.lua:32). It has no export, no state bag and no DB column; mdt_dispatch.responders is never written. Crimson-Police must keep its own map, and an officer can be responding to several calls at once.
- INFO: sc-dispatch's ShotsFired server handler may replace the call coords with exports['sc-houserobbery']:GetPlayerHouseCoords(src) when that resource runs. Do the 300 m backstop radius check with the server ped position GetEntityCoords(GetPlayerPed(src)), not data.coords (client-supplied).
- INFO: sc-dispatch's WitnessForwarding Ignore list includes 'shots fired' and '10%-71' (config.lua:1409-1415), so shots-fired calls never spawn sc-witness witnesses. A config comment says sc-witness detects gunfire itself; any 911 calls it makes would have non-shots_ ids and are outside sc-dispatch's crimsonArena check (sc-witness is not in the allowed stack; just be aware).
- INFO: the bridges/ folder (ps-dispatch, cd_dispatch, etc.) contains optional separate resources that call AddNotification without a unique_id and without any crimsonArena check. If a server installs them, calls from other scripts get numeric row ids and are not suppressed by the flag.
- INFO: sc-dispatch server code uses `exports['qb-core']:GetCoreObject()` (Qbox qb-core compat) and aliases `local StateBagPlayer = Player` because handlers shadow `Player`. In Crimson-Police, never name a local `Player` in a scope that also calls Player(src).state.
- INFO: in the F10 panel the respond toggle key is WaypointKey = 'G' (config.lua:55). Pressing it again un-marks responding and sends ToggleResponding(callId, false), which is the path the 60-second dodge rule must catch.

## sc-npcpolice

### NPC call unique_id format

- **Spec claim:** Appendix sc-npcpolice 'Call ids': unique_id = ('npccall-%d-%d'):format(nextCallId, os.time()), so every NPC call id starts with npccall-. Appendix sc-dispatch 'Call id formats': npccall-<n>-<time> (sc-npcpolice).
- **Evidence:** sc-npcpolice/server/sv_main.lua:60 (local nextCallId = 0), :145 (nextCallId = nextCallId + 1), :156 (dispatchUid)
- **Implication:** Example id: 'npccall-3-1790000000'. Separators are HYPHENS (not underscores like shots_/playerdown_). There is no player server id inside it, so none of Config.Calls.ownRunCallPrefixes ('playerdown_', 'playerdead_', 'emsdown_', 'emshelp_', 'panic_') can ever match an NPC call. nextCallId is in-memory and resets to 0 on every sc-npcpolice restart (ids like 'npccall-1-<t>' recur with a different time), so never parse or key anything on the <n> part; only prefix-match Config.Calls.npcCallPrefix = 'npccall-'.

```lua
local nextCallId = 0
...
nextCallId = nextCallId + 1
local call = {
    id = nextCallId,
    ...
    createdAt = os.time(),
    dispatchUid = ('npccall-%d-%d'):format(nextCallId, os.time()),
    ...
}
```

### How NPC calls are created in sc-dispatch (AddNotification payload)

- **Spec claim:** Created through sc-dispatch's AddNotification with unique_id = the npccall- id.
- **Evidence:** sc-npcpolice/server/sv_main.lua:161-191; config.lua:12 (Config.DispatchJobs); sc-dispatch/server/main.lua:2815 (export), :2864-2868 (INSERT mdt_dispatch), :2893 (policeClientId), :2904 (UPDATE unique_id), :3015 (return)
- **Implication:** Because job_table contains police jobs (and no EMS job), every NPC call is an mdt_dispatch row only (never ems_dispatch) with active = 1 and unique_id = 'npccall-N-T' (VARCHAR(64), sc-dispatch/server/main.lua:418). No 'street', 'radio' or 'caller_source' fields are sent (street stored as ''), caller = 'Dispatch AI'. sc-npcpolice ignores AddNotification's return value. Crimson-Police must never call AddNotification itself (spec) and gets nothing from this payload except the id.

```lua
local dispatchOk, dispatchErr = pcall(function()
    exports['sc-dispatch']:AddNotification({
        job_table = Config.DispatchJobs,
        coords = { x = coords.x, y = coords.y, z = coords.z },
        title = d.title,
        message = msg,
        caller = 'Dispatch AI',
        priority = d.priority or 2,
        sound = 1,
        flash = d.flash or 0,
        unique_id = call.dispatchUid,
        blip = {
            sprite = d.blip.sprite,
            scale = d.blip.scale or 1.0,
            colour = d.blip.colour or 1,
            flashes = (d.flash or 0) == 1,
            text = d.blip.text or d.title,
            time = Config.Generation.CallTimeout,
        },
    })
end)
-- config.lua:12
Config.DispatchJobs = { 'police', 'sheriff', 'sast', 'bcso', 'fib' }
-- sc-dispatch/server/main.lua:2893 / :2904
local policeClientId = data.unique_id or insertId
pcall(function() MySQL.update('UPDATE mdt_dispatch SET unique_id = ? WHERE id = ?', { tostring(policeClientId), insertId }) end)
```

### mdt_dispatch lookup does NOT distinguish NPC calls  _(spec claim: partial)_

- **Spec claim:** Appendix sc-dispatch: confirm a call is real and active with SELECT unique_id FROM mdt_dispatch WHERE (id = ? OR unique_id = ?) AND active = 1.
- **Evidence:** sc-dispatch/server/main.lua:2864-2868 (INSERT ... active = 1), :2904 (unique_id update); sc-dispatch/server/main.lua:7050 (tonumber(callId) or 0 pattern)
- **Implication:** An NPC call IS an active mdt_dispatch row for its first minutes, so the 'real and active' lookup alone would wrongly confirm it as real. Order of checks in modules/calls: (1) idStr = tostring(callId); if it starts with 'npccall-' -> ignore, do NOT add a responding entry, do NOT end the run; (2) otherwise run the lookup with params { tonumber(callId) or 0, idStr } (do NOT pass a bare nil from tonumber('npccall-..'/'shots_..') into the oxmysql param array - use 'or 0' exactly as sc-dispatch does); (3) ALSO re-check the returned row's unique_id against the 'npccall-' prefix, because a (faked) numeric row id of an NPC call row would match via id = ? and return unique_id 'npccall-...'. The unique_id UPDATE in AddNotification is fire-and-forget (not awaited), so step (1) must not depend on the DB.

```lua
INSERT INTO mdt_dispatch (type, message, coords, street, caller, priority, active, created_at)
VALUES (?, ?, ?, ?, ?, ?, 1, NOW())
...
local cidStr, cidNum = tostring(callId), tonumber(callId) or 0
local row = MySQL.query.await('SELECT coords, type, message, street FROM mdt_dispatch WHERE (unique_id = ? OR id = ?) AND active = 1 LIMIT 1', { cidStr, cidNum })
```

### Officers responding to NPC calls fire ToggleResponding with the npccall- id

- **Spec claim:** Spec 'Real calls': Crimson-Police listens read-only to sc-dispatch:server:ToggleResponding (callId, isResponding); ids starting with npccall- are SC-NPCPolice calls. Appendix: callId is the call's unique_id when it has one, otherwise its row id.
- **Evidence:** sc-npcpolice: no ToggleResponding anywhere (grep of all its Lua). sc-dispatch/server/main.lua:2893+2976 (live alert id = unique_id), :2600 (DB-loaded list c.id = c.unique_id), :6995 (dispatcher console cid = unique_id), :7070-7079 (AssignedToCall callId = callId, autoResponding); sc-dispatch/client/main.lua:2281, :2319, :3014; sc-dispatch/html/index.html:860-864; sc-dispatch/server/main.lua:899 (handler)
- **Implication:** sc-npcpolice itself never sends ToggleResponding; sc-dispatch's own client sends it for NPC calls exactly like any other call, with callId = the Lua STRING 'npccall-N-T' (from the respond button, dispatcher assign with AutoResponding, and dispatcher detach). Register a second handler with RegisterNetEvent('sc-dispatch:server:ToggleResponding', function(callId, isResponding) ... end), read `source`, and do tostring(callId) before any comparison (real calls without unique_id arrive as a NUMBER row id). Prefix test must be plain, e.g. idStr:sub(1, #Config.Calls.npcCallPrefix) == Config.Calls.npcCallPrefix or idStr:find(prefix, 1, true) == 1. Do NOT use idStr:find('npccall-') / :match('^npccall-') unescaped: '-' is a Lua pattern quantifier ('l-' = lazy zero-or-more 'l'), so 'npccall-' would also match 'npccal...' and, unanchored, anywhere in the string. For npccall ids: no run end, no free abandon, no 'On a call' entry, and isResponding=false must not trigger the 60-second real_call_cancelled rule.

```lua
-- sc-dispatch/server/main.lua:899
RegisterNetEvent('sc-dispatch:server:ToggleResponding', function(callId, isResponding)
    local src = source
    ...
    local callIdStr = tostring(callId)
-- client/main.lua:3014 (NUI respond button; JS sends callId: call.id)
TriggerServerEvent('sc-dispatch:server:ToggleResponding', data.callId, data.responding)
-- client/main.lua:2319 (dispatcher assignment)
if info.autoResponding and info.callId ~= nil then
    TriggerServerEvent('sc-dispatch:server:ToggleResponding', info.callId, true)
end
-- client/main.lua:2281 (dispatcher detach)
TriggerServerEvent('sc-dispatch:server:ToggleResponding', info.callId, false)
-- server/main.lua:2600
if c.unique_id and c.unique_id ~= '' then c.id = c.unique_id end
```

### NPC call clearing fires no Crimson-Police-visible event (auto-clear race)

- **Spec claim:** Appendix sc-dispatch: callClearedByOfficer (callId) removes the call from the responding map; auto-cleared calls fire no event, so entries expire after Config.Calls.respondingExpiry (1200 s).
- **Evidence:** sc-npcpolice/server/sv_main.lua:82-91 (ClearCall), :239-252 (12-min sweeper), :387-393 (onResourceStop); config.lua:22 (CallTimeout = 12); sc-dispatch/config.lua:41-42 (AutoClear = true, AutoClearTime = 5); sc-dispatch/server/main.lua:3021-3030 (ClearNotification export has no TriggerEvent), :3292-3303 and :7185-7190 (manual/dispatcher clears DO fire callClearedByOfficer)
- **Implication:** When sc-npcpolice resolves/expires a call it uses the ClearNotification export directly, which fires NO sc-dispatch:server:callClearedByOfficer. sc-dispatch also auto-clears the mdt_dispatch row after 5 minutes (before sc-npcpolice's own 12-minute CallTimeout), again with no event. Only an officer's ManualClearCall or a dispatcher's DispatcherClearCall fires callClearedByOfficer, and then with the string 'npccall-N-T'. Therefore: never insert npccall ids into the responding map (otherwise the officer would be stuck 'On a call' for 20 minutes); the callClearedByOfficer handler must tolerate unknown/npccall ids (tostring + no-op when absent). Do not rely on the active flag to classify: an NPC call may be active (first 5 min) or inactive (5-12 min) while officers still toggle responding on it; the prefix alone decides.

```lua
local function ClearCall(call, reason)
    if not activeCalls[call.id] then return end
    activeCalls[call.id] = nil
    activeCount = activeCount - 1
    pcall(function()
        exports['sc-dispatch']:ClearNotification(call.dispatchUid, Config.DispatchJobs)
    end)
    TriggerClientEvent('sc-npcpolice:client:endCall', -1, call.id, reason)
    ...
end
-- sc-dispatch/config.lua
AutoClear = true,
AutoClearTime = 5,
```

### Rewards

- **Spec claim:** SC-NPCPolice pays for its own calls; Crimson-Police never scores or pays them.
- **Evidence:** sc-npcpolice/server/sv_main.lua:296-311 (npcBooked), :313-328 (ticketIssued); config.lua:28-33
- **Implication:** sc-npcpolice pays $250 bank per NPC booked (capped at the call's npcCount) and $150 per speeding ticket, directly via Qbox AddMoney with reasons 'npc-booking' / 'npc-speeding-ticket'; it does not call Renewed-Banking. Crimson-Police must not score, pay, or count these toward Config.Cash.dailyCap (compute the cap only from Crimson-Police's own cp_mission_runs.cash_paid). No hook is needed.

```lua
Config.Rewards = {
    Enabled = true,
    Account = 'bank',
    Arrest = 250,
    Ticket = 150,
}
...
Player.Functions.AddMoney(Config.Rewards.Account, Config.Rewards.Arrest, 'npc-booking')
...
Player.Functions.AddMoney(Config.Rewards.Account, Config.Rewards.Ticket, 'npc-speeding-ticket')
```

### Crimson-Police never calls/triggers/edits sc-npcpolice

- **Spec claim:** Crimson-Police never calls, triggers or edits SC-NPCPolice; it only reads call ids. Dependencies table: 'Nothing is called'.
- **Evidence:** sc-npcpolice has no exports( anywhere; fxmanifest.lua:26-28 (only dependency 'sc-dispatch'); events at sv_main.lua:257, 268, 288, 297, 313, 331, 351; client events cl_main.lua:7, 11, 17, 26, 36, cl_utils.lua:37; commands sv_main.lua:362, 377
- **Implication:** There is nothing to call (no exports) and Crimson-Police must not trigger any sc-npcpolice:* event or run its commands from code. No dependency on sc-npcpolice in Crimson-Police's fxmanifest; everything works whether sc-npcpolice is started or not (only the 'npccall-' string constant is shared).

```lua
-- server net events (do NOT trigger):
'sc-npcpolice:server:claimSpawn', 'sc-npcpolice:server:spawned', 'sc-npcpolice:server:spawnFailed',
'sc-npcpolice:server:npcBooked', 'sc-npcpolice:server:ticketIssued', 'sc-npcpolice:server:resolveCall',
'sc-npcpolice:server:requestCalls'
-- client events it broadcasts: 'sc-npcpolice:client:newCall', 'sc-npcpolice:client:syncCalls', 'sc-npcpolice:client:callActive', 'sc-npcpolice:client:spawnScenario', 'sc-npcpolice:client:endCall', 'sc-npcpolice:client:notify'
RegisterCommand('npccall', ...)   -- admin
RegisterCommand('npccalls', ...)  -- admin
```

### Which jobs sc-npcpolice treats as police / alerts

- **Spec claim:** (Context) Crimson-Police's police jobs are { 'fib', 'sast', 'police', 'bcso' } (Appendix sc-police).
- **Evidence:** sc-npcpolice/config.lua:9, :12; sv_main.lua:28-43 (IsCop, GetOnDutyCops); cl_utils.lua:16-23 (NPC.IsCop); README.md:81-82 (outdated)
- **Implication:** Every Crimson-Police department (fib, sast, police, bcso) receives NPC calls and counts as an on-duty cop for sc-npcpolice (scene hosting, cuffing, booking, rewards), including while on a Crimson-Police run. README.md lists 'sasp' and DispatchJobs {'police','sheriff'} - that README is stale; the config.lua values above are what runs.

```lua
Config.PoliceJobs = { 'police', 'sheriff', 'bcso', 'lspd', 'sast', 'fib' }
Config.DispatchJobs = { 'police', 'sheriff', 'sast', 'bcso', 'fib' }
...
return PoliceJobsSet[data.job.name] == true and data.job.onduty == true
```

### Entity state bags on sc-npcpolice NPCs (key collision risk)  _(spec claim: not_found)_

- **Spec claim:** Not in spec. (Spec: Crimson-Police uses its own ox_target 'Cuff suspect' for NPCs.)
- **Evidence:** sc-npcpolice/client/cl_utils.lua:83-85, :102, :116-125; cl_interact.lua:8-11, :157-176 (FindTarget), :115-134 (BookPed -> npcBooked), :270-298 (abandon cleanup); cl_scenarios.lua:570, :588
- **Implication:** Crimson-Police must NEVER use the entity state bag keys 'npccall' or 'npcstatus' on its own peds/vehicles (use a namespaced key such as 'crimsonPolice'/'cpMission'). If it did, sc-npcpolice's E/G prompts ('[E] Arrest suspect', escort, book at Mission Row 460.5,-990.0,30.7 within 20 m) would attach to Crimson-Police NPCs, and booking would fire sc-npcpolice:server:npcBooked(callId), which pays $250 if the numeric value collides with a live sc-npcpolice call id. Conversely Crimson-Police may READ Entity(ped).state.npccall ~= nil to recognise sc-npcpolice NPCs and exclude them (see next facts).

```lua
local st = Entity(ped).state
st:set('npccall', callId, true)
st:set('npcstatus', 'hostile', true)
...
Entity(veh).state:set('npccall', callId, true)
-- cl_interact.lua FindTarget
local callId = GetCallId(ped)   -- Entity(ped).state.npccall
if callId then
    local status = NPC.GetStatus(ped)   -- Entity(ped).state.npcstatus
    if status == 'surrendered' or status == 'arrestable' or status == 'ticketable' or status == 'cuffed' then
```

### sc-npcpolice relationship groups hate every player  _(spec claim: not_found)_

- **Spec claim:** Mission card rule: hostiles use their own relationship group, hostile only to participants.
- **Evidence:** sc-npcpolice/client/cl_utils.lua:55-68; cl_scenarios.lua:153-154, :186-187, :444
- **Implication:** Do not name Crimson-Police's group NPCCALL_HOSTILE/NPCCALL_RIVAL or reuse those hashes. Use a distinct group (e.g. 'CRIMSON_POLICE_HOSTILE'). sc-npcpolice NPCs are hostile to every player in the PLAYER group, i.e. also to Crimson-Police participants, independent of Crimson-Police's settings.

```lua
local HOSTILE_GROUP = joaat('NPCCALL_HOSTILE')
local RIVAL_GROUP = joaat('NPCCALL_RIVAL')
CreateThread(function()
    AddRelationshipGroup('NPCCALL_HOSTILE')
    AddRelationshipGroup('NPCCALL_RIVAL')
    SetRelationshipBetweenGroups(5, HOSTILE_GROUP, RIVAL_GROUP)
    SetRelationshipBetweenGroups(5, RIVAL_GROUP, HOSTILE_GROUP)
    SetRelationshipBetweenGroups(5, HOSTILE_GROUP, joaat('PLAYER'))
    SetRelationshipBetweenGroups(5, RIVAL_GROUP, joaat('PLAYER'))
end)
```

### Automatic scene spawning near mission participants  _(spec claim: not_found)_

- **Spec claim:** Not in spec.
- **Evidence:** sc-npcpolice/client/cl_main.lua:45-73; sv_main.lua:95-128 (PickLocation, MinSpawnGap), :256-266 (claimSpawn); config.lua:16-25, :227-322 (location lists)
- **Implication:** Any on-duty cop's client (including a Crimson-Police participant who never responded) that comes within 220 m of a pending NPC call automatically becomes its host and spawns armed networked NPCs (shootouts: 5-10 gang peds with pistols/SMGs, combat radius up to 120 m). Up to 3 such calls can be live at fixed locations (e.g. Grove Street 70.05,-1913.12; stores; bars; traffic nodes). Crimson-Police mission logic must therefore: count objectives ('neutralise every hostile', waves, surrenders, arrests) only for peds carrying Crimson-Police's own state bag key, never by scanning all hostile/armed/mission peds; and any Crimson-Police cleanup/traffic-block that deletes peds or vehicles by pool scan must skip entities with Entity(ent).state.npccall ~= nil (they are SetEntityAsMissionEntity + networked). A participant downed by an sc-npcpolice NPC is still handled by Crimson-Police's normal downed flow.

```lua
if hasPending and NPC.IsCop() then
    ...
    if dist < Config.Generation.SpawnDistance then
        call.state = 'claiming'
        TriggerServerEvent('sc-npcpolice:server:claimSpawn', call.id)
-- config.lua
SpawnDistance = 220.0,
MinSpawnGap = 120.0,
CallTimeout = 12,
MaxActiveCalls = 3,
```

### Classify by id prefix only, never by title/priority

- **Spec claim:** Spec: 'The call id shows where a call came from: ids starting with npccall- are SC-NPCPolice calls, and every other call is real.'
- **Evidence:** sc-npcpolice/config.lua:68-77 (shootout dispatch title/priority), :80-221 (other titles); sv_main.lua:172-175
- **Implication:** NPC calls look exactly like real ones in mdt_dispatch (type '10-71 - Shots Fired', priority 1, etc.). The only reliable discriminator is the unique_id prefix 'npccall-'. Do not use type/message/caller columns for classification. They are also NOT sc-dispatch shots-fired calls (id is not shots_<src>_<time>), so the ShotsFired backstop/ClearNotification logic must never touch them.

```lua
dispatch = {
    title = '10-71 - Shots Fired',
    ...
    priority = 1, flash = 1,
    blip = { sprite = 110, colour = 1, scale = 1.2, text = 'Shots Fired - Group' },
},
-- other titles: '10-11 - Traffic Violation', '10-55 - Intoxicated Driver', '10-16 - Stolen Vehicle', '10-31 - Robbery In Progress', '10-66 - Suspicious Activity', '10-66 - Suspect Fleeing On Foot', '10-80 - Vehicle Failing To Stop', '10-10 - Fight In Progress'
caller = 'Dispatch AI',
```

### Other findings

- No discrepancies between the Appendix's three sc-npcpolice rows and the source: the id format ('npccall-%d-%d'):format(nextCallId, os.time()) (sv_main.lua:156), creation via exports['sc-dispatch']:AddNotification with unique_id (sv_main.lua:169-187), self-paid rewards (sv_main.lua:305-310, 321-326) and the absence of any export are all confirmed. The one gap is the Appendix's mdt_dispatch 'real and active' lookup: on its own it CONFIRMS NPC calls as active, so the npccall- prefix check must run first and also be applied to the unique_id the lookup returns.
- Recommended server-side classifier (modules/calls): local idStr = tostring(callId); local p = Config.Calls.npcCallPrefix; if idStr:sub(1, #p) == p then return 'npc' end; local row = MySQL.single.await('SELECT unique_id FROM mdt_dispatch WHERE (id = ? OR unique_id = ?) AND active = 1 LIMIT 1', { tonumber(callId) or 0, idStr }); if not row then return 'unknown' end; local uid = row.unique_id and tostring(row.unique_id) or idStr; if uid:sub(1, #p) == p then return 'npc' end; then apply the ownRunCallPrefixes rule to uid; else 'real'. Key the responding map by uid (the canonical client id) so callClearedByOfficer(uid) removes it.
- ToggleResponding callId types: string for any call with a unique_id (npccall-N-T, shots_<src>_<t>, playerdown_<src>_<t>, ...), Lua number for calls without one (row id). The same handler receives both; always tostring() before comparing or using as a table key (sc-dispatch itself keys RespondingOfficers by tostring(callId)).
- sc-npcpolice never triggers sc-dispatch:server:ToggleResponding, callClearedByOfficer, ShotsFired, PlayerDown or PlayerDead. Its only sc-dispatch calls are the AddNotification export (sv_main.lua:169) and the ClearNotification export (sv_main.lua:87 and :391 on resource stop), both server-side exports that fire no events. callClearedByOfficer with an 'npccall-' id only occurs when an officer or dispatcher clears the call manually in sc-dispatch (sc-dispatch/server/main.lua:3303, :7189).
- Timing mismatch: sc-dispatch auto-clears every call after Config.Dispatch.AutoClearTime = 5 minutes (sc-dispatch/config.lua:42), while sc-npcpolice keeps the scene for Config.Generation.CallTimeout = 12 minutes (config.lua:22). Officers may still toggle responding on an NPC call whose mdt_dispatch row is already inactive, and sc-npcpolice's later ClearNotification is a harmless no-op. Classification must not depend on the active state.
- sc-npcpolice has no knowledge of the crimsonArena state bag and does not check Crimson-Police runs in any way. It keeps generating calls every 7-15 minutes (Config.Generation.IntervalMin/Max) at up to 3 at once, and sends every alert to all on-duty fib/sast/police/bcso officers, including participants who are mid-run. That is expected. Participants may respond to NPC calls, and doing so must not end their run.
- Cuffed sc-npcpolice NPCs stay in the world after their call ends, until they are booked or despawn after being left more than 300 m from every player for 5 minutes (cl_interact.lua:270-298). Free NPCs have their 'npccall' state bag set to nil and become ambient peds (cl_scenarios.lua:570, :588). A pool scan by Crimson-Police can therefore meet sc-npcpolice peds with state.npccall ~= nil well after the call has cleared.
- sc-npcpolice's interaction loop draws 3D text and reads the E (38) and G (47) keys whenever a player is within 4.5 m of one of its surrendered, arrestable, ticketable or cuffed NPCs (cl_interact.lua:157-253). It only reacts to peds that carry state.npccall, so it will not conflict with Crimson-Police's ox_target 'Cuff suspect' as long as Crimson-Police never sets the 'npccall' key.
- Manual acceptance testing (for humans, not Crimson-Police code): an admin can create a real NPC call from the server console with /npccall <shootout|speeding|drunkdriver|stolenvehicle|pursuit|footchase|robbery|drugdeal|barfight> (sv_main.lua:362-375). A forced call skips minCops and cooldown, but it still needs at least 1 on-duty cop and a location 120 m or more from every on-duty cop (sv_main.lua:140-143). /npccalls off pauses automatic generation (sv_main.lua:377-385). Responding to that call in sc-dispatch should send ToggleResponding('npccall-N-T', true), which must not end the run (spec acceptance line 2407).
- README.md is out of date compared with config.lua: the README lists PoliceJobs with 'sasp' and DispatchJobs = { 'police', 'sheriff' }, but the config that runs uses 'sast' and { 'police', 'sheriff', 'sast', 'bcso', 'fib' }. Rely on config.lua.
- sc-npcpolice's fxmanifest (fxmanifest.lua:11-28) loads neither ox_lib nor oxmysql and has no SQL tables, so Crimson-Police has no database table of sc-npcpolice's to read. The only persistent trace of an NPC call is its mdt_dispatch row (unique_id VARCHAR(64), sc-dispatch/server/main.lua:418). A typical id is about 21 characters long.

## sc-ambulance

### GetDoctorCount export: signature and return  _(spec claim: partial)_

- **Spec claim:** exports['sc-ambulance']:GetDoctorCount() | Server | On-duty ambulance players; 0 means no EMS, so a downed participant is picked up (spec.md:2639, 874)
- **Evidence:** server/main.lua:899 (export); server/main.lua:11-13 (state); server/main.lua:407-443 (AddDoctor/RemoveDoctor/playerDropped); server/main.lua:902-922 (RecalculateDoctorCount); server/main.lua:943-948 (recalc on start); client/job.lua:155-224 (clients report duty)
- **Implication:** Call with NO arguments on the server: local n = exports['sc-ambulance']:GetDoctorCount(). It returns a plain Lua number (integer >= 0). It is NOT a live count. It is a counter that clients update themselves by sending hospital:server:AddDoctor('ambulance') and hospital:server:RemoveDoctor('ambulance') when an 'ambulance'-job player loads in on duty, toggles duty or changes job. The server also decrements it on playerDropped and rebuilds it from live data only on resource start (after Wait(2000)) and on the admin command /recalcdoctors. Only job.name == 'ambulance' counts; other EMS job names or job.type 'ems' do not. The server never checks the sender's job in AddDoctor, so the count can be inflated or go stale. Treat 0 as 'no EMS', as the spec says. Wrap the call in pcall and check GetResourceState('sc-ambulance') == 'started' first. If sc-ambulance is not started, hospital:client:Revive has no handler either, so a pick-up would not revive anyone. Optional hardening that stays within the Appendix's listed calls: count exports.qbx_core:GetQBPlayers() entries with job.name == 'ambulance' and job.onduty. This is exactly what sc-ambulance's own hospital:GetDoctors callback (server/main.lua:723-732) and RecalculateDoctorCount do.

```lua
local doctorCount = 0
local Doctors = {}
...
RegisterNetEvent('hospital:server:AddDoctor', function(job)
	if job == 'ambulance' then
		local src = source
		if not Doctors[src] then
			doctorCount = doctorCount + 1
			Doctors[src] = true
		end
		TriggerClientEvent('hospital:client:SetDoctorCount', -1, doctorCount)
	end
end)
...
exports('GetDoctorCount', function() return doctorCount end)
```

### RecalculateDoctorCount export (exists, do not spam)

- **Spec claim:** Not in spec
- **Evidence:** server/main.lua:902-922, 925-930
- **Implication:** Do not call it on each downed check. Every call prints to the server console and broadcasts to every client. The Appendix does not list it, so Crimson-Police should not use it.

```lua
local function RecalculateDoctorCount()
	...
	TriggerClientEvent('hospital:client:SetDoctorCount', -1, doctorCount)
	print('[sc-ambulance] Doctor count recalculated: ' .. oldCount .. ' -> ' .. doctorCount)
	return doctorCount
end
exports('RecalculateDoctorCount', RecalculateDoctorCount)
```

### hospital:client:Revive: args and behaviour

- **Spec claim:** Client event hospital:client:Revive | Server → client | TriggerClientEvent('hospital:client:Revive', src) revives a picked-up officer (spec.md:2640, 874)
- **Evidence:** client/main.lua:585-621 (main handler); client/deathscreen.lua:443-446 (second handler: clears screen effects); client/laststand.lua:58-159 (SetLaststand global); client/main.lua:1 and fxmanifest.lua client_scripts (both files loaded)
- **Implication:** Call it with no payload: TriggerClientEvent('hospital:client:Revive', src), where src is one validated numeric server id. Never pass -1, which would revive every player, and never pass nil. The handler takes no arguments. It resurrects the ped where it stands and does NOT teleport, so Crimson-Police must move the officer to the drop-off itself. The spec's client:pickup flow already does this: fade, server triggers the revive, client moves to the drop-off, fade in. Moving after the revive is the safest order. It heals to 200, clears injuries and bleeding (ResetAll), relieves stress and unlocks the inventory (OnDeadStateChange(false)). The client then sends SetDeathStatus(false) and SetLaststandStatus(false), so server metadata clears one network round-trip later, not instantly. It never bills, never touches the inventory and never shows the respawn-memory text (that needs wasHospitalRespawn). The resurrect branch only runs if sc-ambulance's client globals isDead or InLaststand are already true. Trigger the pick-up only after the server sees metadata.isdead or metadata.inlaststand true; the 15 s pickupDelay after metadata detection covers this. deathscreen.lua registers a second handler for the same event that only clears the blur and audio effects after Wait(100).

```lua
RegisterNetEvent('hospital:client:Revive', function()
    local player = PlayerPedId()

    if isDead or InLaststand then
        local pos = GetEntityCoords(player, true)
        NetworkResurrectLocalPlayer(pos.x, pos.y, pos.z, GetEntityHeading(player), true, false)
        isDead = false
        SetEntityInvincible(player, false)
        SetLaststand(false)
    end
    OnDeadStateChange(false)

    if isInHospitalBed then
        loadAnimDict(inBedDict)
        TaskPlayAnim(player, inBedDict, inBedAnim, 8.0, 1.0, -1, 1, 0, 0, 0, 0)
        SetEntityInvincible(player, true)
        canLeaveBed = true
    end

    TriggerServerEvent('hospital:server:RestoreWeaponDamage')
    SetEntityMaxHealth(player, 200)
    SetEntityHealth(player, 200)
    ClearPedBloodDamage(player)
    SetPlayerSprint(PlayerId(), true)
    ResetAll()
    ResetPedMovementClipset(player, 0.0)
    TriggerServerEvent('hud:server:RelieveStress', 100)
    TriggerServerEvent('hospital:server:SetDeathStatus', false)
    TriggerServerEvent('hospital:server:SetLaststandStatus', false)
    emsNotified = false
    QBCore.Functions.Notify(Lang:t('info.healthy'))
    ...
end)
```

### Name collision: hospital:client:Revive vs hospital:client:RevivePlayer / HelpPerson / TargetRevive

- **Spec claim:** Spec only names hospital:client:Revive (safe) and hospital:server:RevivePlayer (never trigger)
- **Evidence:** client/job.lua:265-294 (hospital:client:RevivePlayer), client/job.lua:385-409 (sc-ambulance:client:TargetRevive), client/laststand.lua:195-214 (hospital:client:HelpPerson)
- **Implication:** Use the exact string 'hospital:client:Revive' and nothing longer. 'hospital:client:RevivePlayer', 'sc-ambulance:client:TargetRevive' and 'hospital:client:HelpPerson' each make the receiving client send hospital:server:RevivePlayer. HelpPerson does this with no first-aid check, so an officer without firstaid would be permanently banned. Never trigger any of these three.

```lua
RegisterNetEvent('hospital:client:HelpPerson', function(targetId)
    ...Progressbar('hospital_revive', ..., math.random(30000, 60000), ...
    }, {}, {}, function() -- Done
        ClearPedTasks(ped)
        QBCore.Functions.Notify(Lang:t('success.revived'), 'success')
        TriggerServerEvent('hospital:server:RevivePlayer', targetId)
    end, ...)
end)

RegisterNetEvent('hospital:client:RevivePlayer', function()
    local hasItem = QBCore.Functions.HasItem('firstaid')
    if hasItem then ... TriggerServerEvent('hospital:server:RevivePlayer', playerId) ...
```

### SC-Ambulance's own server code revives the same way

- **Spec claim:** SC-Ambulance's own server code revives players the same way (spec.md:2640)
- **Evidence:** server/main.lua:24 (txAdmin heal), server/main.lua:456 and 463 (RevivePlayer), server/main.lua:818 and 823 (/revive admin command), server/grandma.lua:43
- **Implication:** Confirmed. Crimson-Police uses the same one-argument TriggerClientEvent call from its server-side modules/integrations wrapper. No money moves in the client handler. The costs in those server paths (firstaid item, $5000 oldMan fee, $7000 grandma) are charged by the callers, not by the event.

```lua
TriggerClientEvent('hospital:client:Revive', eventData.id)            -- main.lua:24
TriggerClientEvent('hospital:client:Revive', Patient.PlayerData.source) -- main.lua:463
TriggerClientEvent('hospital:client:Revive', Player.PlayerData.source)  -- main.lua:818
TriggerClientEvent('hospital:client:Revive', src)                       -- grandma.lua:43
```

### hospital:server:EMSDownAlert: args and gating conditions

- **Spec claim:** Net event hospital:server:EMSDownAlert (street) | Client → server | Sent from the downed officer's own client after their flag is removed; SC-Ambulance creates an emsdown_<src>_<time> call for EMS through sc-dispatch. It ignores flagged players and players who are not down (spec.md:2641, 876)
- **Evidence:** server/main.lua:262-273 (IsArenaAlertSuppressed), server/main.lua:289-334 (handler); config.lua:21-27 (MDTIntegration.Enabled = true)
- **Implication:** It takes exactly one argument, street (a string; nil becomes ''). The handler uses `source` for the patient's identity, coordinates, metadata check and call id, so it MUST be sent from the downed officer's own client: TriggerServerEvent('hospital:server:EMSDownAlert', street). A server-side TriggerEvent would carry the wrong source. The handler silently returns when any of these holds: (1) the crimsonArena flag is still active server-side; (2) the Crimson-Arena resource is started and its ShouldSuppressAlert(src) returns true; (3) Config.MDTIntegration.Enabled is not true (it is true, config.lua:22); (4) the player object is missing; (5) neither metadata.inlaststand nor metadata.isdead is truthy. Required order: the server clears the flag first (server state updates at once), then sends crimson-police client:requestEMS, then the client sends EMSDownAlert. Compute street exactly as sc-ambulance does: local pos = GetEntityCoords(PlayerPedId()); local street = GetStreetNameFromHashKey(GetStreetNameAtCoord(pos.x, pos.y, pos.z)) (client/laststand.lua:115, client/dead.lua:230). There is no server-side cooldown, and every call creates a new dispatch call, so send it exactly once per downed participant. The client does not need to check that sc-dispatch is running: if the export fails, the server falls back to a plain hospital:client:ambulanceAlert to on-duty 'ambulance' players (server/main.lua:320-333).

```lua
RegisterNetEvent('hospital:server:EMSDownAlert', function(street)
	local src = source
	if IsArenaAlertSuppressed(src) then return end
	if not (Config.MDTIntegration and Config.MDTIntegration.Enabled) then return end
	local Player = QBCore.Functions.GetPlayer(src)
	if not Player then return end
	if not Player.PlayerData.metadata['inlaststand'] and not Player.PlayerData.metadata['isdead'] then return end
	local coords = GetEntityCoords(GetPlayerPed(src))
	...
```

### EMSDownAlert dispatch payload and emsdown_ id format

- **Spec claim:** Call id format emsdown_<src>_<time> (sc-ambulance) (spec.md:2609); Config.Calls.ownRunCallPrefixes includes 'emsdown_' (spec.md:1743)
- **Evidence:** server/main.lua:300-322
- **Implication:** The id is the literal 'emsdown_' followed by the server id as a decimal integer, '_', and os.time() in server epoch seconds, e.g. 'emsdown_12_1727520000'. Match the own-run prefix as '^emsdown_' .. src .. '_'. The call goes to EMS jobs only, not police, so police normally never respond to it. Keep 'emsdown_' in ownRunCallPrefixes anyway. Crimson-Police must never clear this call: it is the permitted EMS request (Hard rule exception, spec.md:37).

```lua
local dispatchData = {
	job_table = { 'ambulance', 'ems', 'doctor', 'hospital' },
	coords = { x = coords.x, y = coords.y, z = coords.z },
	street = street or '',
	title = '10-52 - Person Down',
	message = 'Civilian down and requesting medical assistance - ' .. patientSex .. ' victim',
	priority = 2,
	sound = 1,
	flash = 0,
	blip = { sprite = 153, scale = 1.2, colour = 3, flashes = false, text = '10-52 - Person Down' },
	unique_id = 'emsdown_' .. src .. '_' .. os.time(),
	caller_source = src,
}
local success, err = pcall(function()
	exports['sc-dispatch']:AddNotification(dispatchData)
end)
```

### crimsonArena state bag: server-side check

- **Spec claim:** State bag crimsonArena | Both | With Config.ArenaIntegration.Enabled = true (already set), SC-Ambulance sends no automatic person-down alert for flagged players (spec.md:2642). Crimson-Police sets it with Player(src).state:set('crimsonArena', { active = true, source = 'crimson-police' }, true)
- **Evidence:** server/main.lua:258-273; used at server/main.lua:277 (ambulanceAlert) and 291 (EMSDownAlert)
- **Implication:** The key is 'crimsonArena' (camelCase, not configurable). The value must be a table whose .active is the boolean true; the server compares with == true, so 1 or 'true' does not count. The spec's value { active = true, source = 'crimson-police' } matches. To clear it, set the key to nil with Player(src).state:set('crimsonArena', nil, true), and only when state.crimsonArena.source == 'crimson-police'. The server check covers hospital:server:ambulanceAlert and hospital:server:EMSDownAlert. While the flag is on, even Crimson-Police's own EMS request is dropped, which is why the flag must be removed before requestEMS. Edge case: if a resource named 'Crimson-Arena' is started and its ShouldSuppressAlert(src) returns true, EMSDownAlert is dropped even after Crimson-Police has cleared its flag.

```lua
local function IsArenaAlertSuppressed(src)
	local cfg = Config.ArenaIntegration
	if cfg and cfg.Enabled == false then return false end

	local ok, state = pcall(function() return Player(src).state.crimsonArena end)
	if ok and state and state.active == true then return true end

	local res = (cfg and cfg.Resource) or 'Crimson-Arena'
	if GetResourceState(res) ~= 'started' then return false end
	local okE, suppress = pcall(function() return exports[res]:ShouldSuppressAlert(src) end)
	return okE and suppress == true
end
```

### crimsonArena state bag: client-side check and what it suppresses

- **Spec claim:** SC-Ambulance skips person-down or dead alerts for flagged players (spec.md:862)
- **Evidence:** client/laststand.lua:15-28 (ArenaSuppressEMSAlert), client/laststand.lua:107-120 (auto alert on going down), client/dead.lua:69-73 (death alert), client/dead.lua:224-236 (G key)
- **Implication:** The client reads LocalPlayer.state.crimsonArena, so the flag MUST be set with replicate = true (third argument true). While flagged, the client skips the automatic EMS alert on entering last stand, the death alert and the manual G request. Duplicate-call risk: sc-ambulance decides on the automatic alert in the same frame it sends SetLaststandStatus(true). If Crimson-Police clears the flag only after the server sees metadata.inlaststand or metadata.isdead true (never on ped death alone), sc-ambulance's automatic alert has already been skipped, and Crimson-Police's single EMSDownAlert is the only call. After the flag is cleared, the officer can still press G themselves (only once LaststandTime <= Config.MinimumRevive), which can create a second emsdown_ call. That is sc-ambulance's normal behaviour.

```lua
function ArenaSuppressEMSAlert()
    local cfg = Config.ArenaIntegration
    if cfg and cfg.Enabled == false then return false end
    local arena = LocalPlayer.state.crimsonArena
    if arena and arena.active then return true end
    local res = (cfg and cfg.Resource) or 'Crimson-Arena'
    if GetResourceState(res) ~= 'started' then return false end
    local ok, result = pcall(function() return exports[res]:IsInArena() end)
    return ok and result == true
end
...
TriggerServerEvent('hospital:server:SetLaststandStatus', true)
if not skipAlert and not ArenaSuppressEMSAlert() then
    if Config.MDTIntegration and Config.MDTIntegration.Enabled and GetResourceState('sc-dispatch') == 'started' then
        local street = GetStreetNameFromHashKey(GetStreetNameAtCoord(pos.x, pos.y, pos.z))
        TriggerServerEvent('hospital:server:EMSDownAlert', street)
    else
        TriggerServerEvent('hospital:server:ambulanceAlert', Lang:t('info.civ_down'))
    end
end
```

### Config.ArenaIntegration values

- **Spec claim:** Config.ArenaIntegration.Enabled = true (already set) (spec.md:2642, 2547)
- **Evidence:** config.lua:37-40
- **Implication:** Confirmed. Both checks only disable suppression when Enabled == false; nil still counts as enabled. Resource 'Crimson-Arena' is a separate optional resource name and is not Crimson-Police. Do NOT name the new resource 'Crimson-Arena', and do not export ShouldSuppressAlert or IsInArena, otherwise sc-ambulance would call those exports.

```lua
Config.ArenaIntegration = {
    Enabled = true,
    Resource = 'Crimson-Arena',        -- resource name of the arena script
}
```

### hospital:server:RevivePlayer ban logic

- **Spec claim:** Net event hospital:server:RevivePlayer | — | Never trigger it: SC-Ambulance bans any sender who is not EMS and carries no first aid (spec.md:2643, 878, 73)
- **Evidence:** server/main.lua:445-479; framework.lua:52-60 (HasItem, qbox uses ox_inventory GetItemCount)
- **Implication:** Never trigger it, from client or server. A ban happens when playerId is an online player, the sender's job.name is not 'ambulance' (on or off duty) and the sender has no 'firstaid' item. The ban is a row in the bans table with expire 2147483647 plus DropPlayer. Police officers are not 'ambulance', so any officer without firstaid who sends it is banned for good. With firstaid it still consumes the item, and isOldMan = true takes $5000 cash. A server-side TriggerEvent would error (the sender Player is nil). Always use TriggerClientEvent('hospital:client:Revive', src) instead.

```lua
RegisterNetEvent('hospital:server:RevivePlayer', function(playerId, isOldMan)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	local Patient = QBCore.Functions.GetPlayer(playerId)
	local oldMan = isOldMan or false
	if Patient then
		if Player.PlayerData.job.name == 'ambulance' or HasItem(src, 'firstaid', 1) then
			if oldMan then
				if Player.Functions.RemoveMoney('cash', 5000, 'revived-player') then ... end
			else
				RemoveItem(src, 'firstaid', 1)
				TriggerItemBox(src, 'firstaid', 'remove')
				TriggerClientEvent('hospital:client:Revive', Patient.PlayerData.source)
			end
		else
			MySQL.insert('INSERT INTO bans (name, license, discord, ip, reason, expire, bannedby) VALUES (?, ?, ?, ?, ?, ?, ?)', {
				GetPlayerName(src), QBCore.Functions.GetIdentifier(src, 'license'), QBCore.Functions.GetIdentifier(src, 'discord'), QBCore.Functions.GetIdentifier(src, 'ip'),
				'Trying to revive theirselves or other players', 2147483647, 'qb-ambulancejob'
			})
			...
			DropPlayer(src, 'You were permanently banned by the server for: Exploiting')
		end
	end
end)
```

### Other sc-ambulance events that bill or penalise the sender

- **Spec claim:** Spec: Crimson-Police's pick-up is free; never trigger RevivePlayer
- **Evidence:** server/main.lua:196-202 (SendToBed bills), 204-256 (RespawnAtHospital bills, optional wipe), 684-700 (prisonCheckin bills), 67-146 (BillPlayer); server/grandma.lua:9-48 ($7000); server/insurance.lua:72-98 (PurchaseInsurance charges); client/main.lua:694-723 (hospital:client:RespawnAtHospital sends server respawn); client/main.lua:651-653 (hospital:client:KillPlayer)
- **Implication:** Crimson-Police must trigger none of these server events: hospital:server:SendToBed, hospital:server:RespawnAtHospital, sc-ambulance:server:prisonCheckin, sc-ambulance:server:GrandmaRevive, sc-ambulance:server:PurchaseInsurance, hospital:server:RevivePlayer. It must trigger none of these client events either: hospital:client:RespawnAtHospital (leads to a billed respawn), hospital:client:SendToBed, hospital:client:KillPlayer. Each charges money or harms the player, and would break 'no hospital bill'. Crimson-Police must also never send hospital:server:SetDeathStatus or hospital:server:SetLaststandStatus itself. They write metadata.isdead and metadata.inlaststand without validation (server/main.lua:370-384), and hospital:client:Revive already clears both.

```lua
RegisterNetEvent('hospital:server:SendToBed', function(bedId, isRevive, hospitalIndex)
	...
	BillPlayer(src, Player, Config.BillCost, 'respawned-at-hospital', Config.Locations['hospital'][hospitalIndex]['name'])
end)
RegisterNetEvent('hospital:server:RespawnAtHospital', function(hospitalIndex) ... BillPlayer(...) ... end)
RegisterNetEvent('sc-ambulance:server:prisonCheckin', function() ... BillPlayer(src, Player, Config.BillCost, 'prison-medical', 'Jail Medical') ... end)
if Player.Functions.RemoveMoney(account, price, 'grandma-heal') then TriggerClientEvent('hospital:client:Revive', src) ... -- grandma.lua:42
```

### Metadata keys that mean downed and how they are written

- **Spec claim:** Server checks metadata.isdead and metadata.inlaststand every 2 seconds; Downed = the ped is dead, or metadata isdead or inlaststand is true (the same check sc-dispatch and sc-ambulance use) (spec.md:872, 2581)
- **Evidence:** server/main.lua:370-384 (writers); server/main.lua:295 (EMSDownAlert check); server/grandma.lua:29, server/stretcher.lua:48, server/escort.lua:65, server/defib.lua:83 (readers); client/deathscreen.lua:373-386; client/dead.lua:19; client/laststand.lua:112, 158
- **Implication:** The keys are exactly 'isdead' and 'inlaststand', all lowercase, holding boolean values. Read them from exports.qbx_core:GetPlayer(src).PlayerData.metadata.isdead and .inlaststand. sc-ambulance's server tests truthiness; its client deathscreen compares == true. Use `meta.isdead == true or meta.inlaststand == true`. Normally at most one is true: bleeding out goes from last stand (inlaststand true, isdead false) to dead (inlaststand false, isdead true), both writes sent in the same frame. Other keys: 'ishandcuffed' (escort), 'isLEO' (EMS billing discount flag, camelCase), 'armor'. None of them mean downed.

```lua
RegisterNetEvent('hospital:server:SetDeathStatus', function(isDead)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	if Player then
		Player.Functions.SetMetaData('isdead', isDead)
	end
end)
RegisterNetEvent('hospital:server:SetLaststandStatus', function(bool)
	...
		Player.Functions.SetMetaData('inlaststand', bool)
end)
-- reader:
if not Player.PlayerData.metadata['inlaststand'] and not Player.PlayerData.metadata['isdead'] then return end
```

### 'Ped is dead' is NOT a reliable signal with sc-ambulance  _(spec claim: partial)_

- **Spec claim:** Downed = the ped is dead, or the player's metadata has isdead or inlaststand set to true (spec.md:2581)
- **Evidence:** client/laststand.lua:58-105 (resurrect, then health 150 in last stand); client/dead.lua:15-68 (resurrect, then invincible at max health when 'dead')
- **Implication:** sc-ambulance resurrects the ped both for last stand (health 150, writhe animation) and for 'dead' (invincible, max health, dead animation). IsEntityDead or GetEntityHealth <= 0 is therefore true only for about 1-6 s between the real GTA death and the resurrect in SetLaststand, and briefly again when killed while in last stand. Use metadata as the main downed signal. A health-based check would miss a downed officer. Metadata inlaststand becomes true only after Wait(1000) plus up to 5 s of settling. Start the 15 s pickupDelay and any flag removal from metadata detection, not from ped death.

```lua
-- laststand.lua
Wait(1000)
local settleTimeout = GetGameTimer() + 5000
while not isOnStretcher and (GetEntitySpeed(ped) > 0.5 or IsPedRagdoll(ped)) do
    if GetGameTimer() > settleTimeout then break end
    Wait(10)
end
...
NetworkResurrectLocalPlayer(pos.x, pos.y, pos.z + 0.5, heading, true, false)
SetEntityHealth(ped, 150)
...
InLaststand = true
-- dead.lua OnDeath
NetworkResurrectLocalPlayer(pos.x, pos.y, pos.z + 0.5, heading, true, false)
SetEntityInvincible(player, true)
SetEntityHealth(player, GetEntityMaxHealth(player))
```

### Downed timers in sc-ambulance's normal EMS flow

- **Spec claim:** EMS on duty: the officer stays down and follows SC-Ambulance's normal flow (spec.md:876)
- **Evidence:** config.lua:145-153; client/laststand.lua:121-151; client/dead.lua:78-108, 211-236
- **Implication:** Last stand lasts 400 s. The G request (control 47) shows only once LaststandTime <= 300 and only in last stand, never when fully dead. Bleeding out leads to 'dead' for 400 s, after which sc-ambulance forces a billed hospital respawn automatically (ShowRespawnKey = false). Crimson-Police sends its EMSDownAlert right after detection, without waiting for the G window; the server accepts it because metadata already says down. Nothing more is needed from Crimson-Police. If EMS never arrives, sc-ambulance's own billed respawn eventually happens; that is sc-ambulance's behaviour, not Crimson-Police's pick-up.

```lua
Config.DeathTime = 400
Config.ShowRespawnKey = false
Config.ReviveInterval = 400
Config.MinimumRevive = 300
...
if not Config.ShowRespawnKey then
    if not isInHospitalBed then
        TriggerEvent('hospital:client:RespawnAtHospital')
        break
    end
```

### Check-in point coordinates (default drop-offs)

- **Spec claim:** Check-in points: Pillbox (308.19, -595.35, 43.29) and Paleto (-254.54, 6331.78, 32.43): the default drop-offs in Config.Downed.dropOffs (spec.md:2644, 1760-1763)
- **Evidence:** config.lua:467-470 (checking); config.lua:536-572 (hospital locations); client/main.lua:895-913 (check-in target zone)
- **Implication:** The coordinates match exactly. They are vector3 values with no heading, so choose a heading yourself or leave the current one. The z values are ped-centre heights (Pillbox floor is about 42.28), so SetEntityCoords(ped, x, y, z) works directly. Each point is the centre of sc-ambulance's check-in desk target zone (3.5 x 2 box, heading -72), so a dropped-off officer stands at the desk. Copy the values into Config.Downed.dropOffs rather than reading sc-ambulance's Config, which is not exported. Separately, Config.RespawnAtNearestHospital = false (config.lua:142) means sc-ambulance's own respawns always go to Pillbox.

```lua
['checking'] = {
    vector3(308.19, -595.35, 43.29),
    vector3(-254.54, 6331.78, 32.43), -- paleto
},
...
['hospital'] = {
    { ['name'] = Lang:t('info.pb_hospital'), ['location'] = vector3(308.36, -595.25, 43.28), ... },
    { ['name'] = Lang:t('info.paleto_hospital'), ['location'] = vector3(-254.54, 6331.78, 32.43), ... },
},
```

### Hospital respawn: billing and inventory

- **Spec claim:** SC-Ambulance's own hospital respawn bills the player and keeps their inventory (WipeInventoryOnRespawn = false); Crimson-Police's pick-up is free (spec.md:2645)
- **Evidence:** config.lua:141 (WipeInventoryOnRespawn = false); config.lua:173-187 (Billing); server/main.lua:67-146 (BillPlayer); server/main.lua:232-255 (respawn bills)
- **Implication:** Confirmed. A respawn bills $2000 from the bank, pays it into the 'ambulance' Renewed-Banking account, and sends a phone email. The bill is 50% off when an EMS has set metadata.isLEO, and $0 with valid insurance. Crimson-Police's pick-up uses only hospital:client:Revive, which never calls BillPlayer, so it is free. Do not route the pick-up through RespawnAtHospital or SendToBed.

```lua
Config.WipeInventoryOnRespawn = false
Config.Billing = {
    Enabled = true,
    CheckInCost = 2000,
    InsuranceCoversAll = true,
    InsuranceDiscount = 80,
    SendBillToBank = true,
    HospitalAccount = 'ambulance',
    SendBillEmail = true,
    LEOEnabled = true,
    LEODiscount = 50,
    LEOJob = 'ambulance',
}
Config.BillCost = Config.Billing.CheckInCost
```

### qbx_medical compatibility exports are NOT loaded

- **Spec claim:** Spec uses only GetDoctorCount + hospital:client:Revive
- **Evidence:** fxmanifest.lua:17-49 (client_scripts/server_scripts lists omit qbx_medical_compat.lua); server/qbx_medical_compat.lua:14-67 and client/qbx_medical_compat.lua:70-115 define exports that never register
- **Implication:** exports['sc-ambulance'] has no Revive, Heal, IsDead, IsLaststand, SetDead or SetLaststand, on either side; calling them errors. The fxmanifest has no provide 'qbx_medical', so do not call exports.qbx_medical either. The only sc-ambulance server exports are GetDoctorCount, RecalculateDoctorCount, AddDrug, GetDrugsInSystem, ClearDrugs, GetBloodRecordByDNA and MatchDNA. The only client exports are StartDeathScreen, StopDeathScreen, IsDeathScreenActive and PainKillerLoop.

```lua
server_scripts {
	'@oxmysql/lib/MySQL.lua',
	'server/framework.lua',
	'server/main.lua',
	'server/xray.lua', ... 'server/surgery.lua',
}  -- no 'server/qbx_medical_compat.lua'
```

### Character unload clears downed metadata

- **Spec claim:** Spec: tablet closes/refreshes on QBCore:Client:OnPlayerUnload
- **Evidence:** client/main.lua:759-774; client/job.lua:175-207 (restores downed state on load from metadata)
- **Implication:** A downed officer who logs out to character select (not a disconnect) has isdead and inlaststand set to false. Crimson-Police must not read that as 'recovered'. By then their run has already ended as downed or they are removed on unload, so do not re-evaluate them. A disconnect (playerDropped) does not clear metadata, so the officer loads back in downed (client/job.lua:192-197). A pending pick-up must be cancelled on playerDropped and on unload.

```lua
RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    local ped = PlayerPedId()
    TriggerServerEvent('hospital:server:SetDeathStatus', false)
    TriggerServerEvent('hospital:server:SetLaststandStatus', false)
    ...
```

### Other findings

- The only ban anywhere in sc-ambulance is in hospital:server:RevivePlayer (server/main.lua:466-476). No other server event bans or kicks (grep of server/ and client/ for bans, DropPlayer, kick).
- Name trap: 'hospital:client:Revive' is safe. 'hospital:client:RevivePlayer' (client/job.lua:265), 'hospital:client:HelpPerson' (client/laststand.lua:195) and 'sc-ambulance:client:TargetRevive' (client/job.lua:385) all make the client send hospital:server:RevivePlayer and can get the officer banned. HelpPerson has no firstaid check at all.
- hospital:client:Revive has two client handlers: client/main.lua:585 does the revive and client/deathscreen.lua:443 clears the screen effects. Both are in the fxmanifest, and nothing else is needed.
- After a pick-up the revive clears metadata one round-trip later (the client sends SetDeathStatus(false) and SetLaststandStatus(false)), so the 2 s downed checker may still see the officer as down for one tick. Mark the participant as picked up so the pick-up or requestEMS never fires twice.
- Revive order for client:pickup: fade out, TriggerClientEvent('hospital:client:Revive', src) from the server, then the client runs SetEntityCoords to the nearest drop-off and fades in. The revive resurrects the ped in place, and a ped left in a vehicle is placed at the vehicle's coordinates. If the officer is being escorted (escort.lua lets job.type 'leo' and 'ems' escort downed players) or is on a stretcher, detach (DetachEntity) before moving them.
- Hospital:server:EMSDownAlert has no rate limit on the server; every call makes a new emsdown_<src>_<os.time()> dispatch call. Send it once per downed participant and only after the server has cleared the Crimson-Police flag and still sees metadata isdead or inlaststand as true.
- The crimsonArena flag also suppresses sc-ambulance's hospital:server:ambulanceAlert. It does NOT suppress hospital:server:SendDoctorAlert (the check-in desk doctor call, unique_id 'doctoralert_' .. src .. '_' .. os.time(), job_table EMS only; server/main.lua:481-557) or the /311 command. 'doctoralert_' is a further sc-ambulance call-id prefix that the spec's list of call id formats does not include. It only appears when a player uses the check-in desk while at least Config.MinimalDoctors = 3 doctors are available.
- The sc-ambulance client handles the G request on control 47 (client/dead.lua:224), with the text 'PRESS [G] TO REQUEST HELP' (locales/en.lua:35). The spec's 'same request as pressing G' is accurate: TriggerServerEvent('hospital:server:EMSDownAlert', street).
- Do not name the new resource 'Crimson-Arena' and do not export ShouldSuppressAlert or IsInArena. sc-ambulance calls those exports on the resource named in Config.ArenaIntegration.Resource = 'Crimson-Arena' (config.lua:39).
- Latent bug in sc-ambulance: DebugPrint calls itself (server/main.lua:6-10, server/framework.lua:9-13), causing a stack overflow if Config.Debug = true. In EMSDownAlert that would stop the fallback alert from running when sc-dispatch fails (server/main.lua:326). Keep sc-ambulance's Config.Debug = false (config.lua:14). Server owners should know this; Crimson-Police cannot fix it because edits are banned.
- sc-ambulance internally uses exports['qb-core']:GetCoreObject() (the qbx_core bridge) and QBCore.Functions. That is sc-ambulance's own business. Crimson-Police must still use only exports.qbx_core per Hard rule 2 and must not copy sc-ambulance's patterns.
- hospital:server:AddDoctor does not check the sender's job (server/main.lua:407-418), so a malicious client can inflate GetDoctorCount. At worst a downed officer is not picked up by an NPC unit and falls back to sc-ambulance's normal EMS flow and billed respawn. Cross-check with a live count of exports.qbx_core:GetQBPlayers() entries (job.name == 'ambulance' and job.onduty) if you want to be robust.
- If sc-ambulance is not started, hospital:client:Revive has no handler and the pick-up does not revive, and exports['sc-ambulance']:GetDoctorCount() errors. Wrap the export in pcall and check GetResourceState('sc-ambulance') == 'started', and log an error. Do not bridge to another medical resource (Hard rule 11).
- The Config.MDTIntegration.DisableDefaultAlerts = true setting (config.lua:26) means sc-ambulance never sends the plain death alert (client/dead.lua:71). The only automatic alert is EMSDownAlert, sent on entering last stand (client/laststand.lua:113-120), and the flag suppresses it.
- Config.Death.DisableInventoryWhenDead and DisableInventoryInLaststand = true (config.lua:132-133): a downed officer's ox_inventory is locked through LocalPlayer.state invBusy (client/deadstate.lua:14). The revive unlocks it through OnDeadStateChange(false). Mission items cannot be used while down.
- The spec's 'bans any sender who is not EMS' should be read as: job.name ~= 'ambulance' (on or off duty) AND no 'firstaid' item (ox_inventory GetItemCount(src,'firstaid') < 1 on qbox, server/framework.lua:52-60). The target playerId must also be an online player for the ban branch to run.

## sc-police

### Police job list (Config.DispatchIntegration.PoliceJobs)

- **Spec claim:** Config.DispatchIntegration.PoliceJobs = { 'fib', 'sast', 'police', 'bcso' }
- **Evidence:** config.lua:19-29 (line 24); same list reused at config.lua:746 (Config.GPSTracker.Permissions.AllowedJobs); used as job_table in server/main.lua:79 and server/commands.lua:29
- **Implication:** The four job names are exactly the lowercase strings 'fib', 'sast', 'police', 'bcso'. Config.Departments[*].jobs must use these literal names (sast -> { 'sast' }, fib -> { 'fib' }, bcso -> { 'bcso' }). Crimson-Police must NOT read sc-police's Config at runtime (it is sc-police's shared Config global, not exported); hard-code/duplicate the names in Crimson-Police's own config. Other job names sc-police references in places: 'sheriff' (client/evidencelocker.lua:23, /911 job_table), 'trooper'/'ranger' (client/evidence.lua:273-274), 'sadot' (server/commands.lua:499), 'tow', 'judge', 'lawyer' — none are police departments for Crimson-Police.

```lua
Config.DispatchIntegration = {
    Enabled = true,
    Resource = 'sc-dispatch',
    SendPoliceAlerts = true,
    SendRadarAlerts = true,
    PoliceJobs = {  'fib', 'sast', 'police', 'bcso' },
    UseQBPhoneFallback = true,
    UseNativeNotifications = true,
}
```

### job.type = 'leo'  _(spec claim: partial)_

- **Spec claim:** police jobs have job.type = 'leo'
- **Evidence:** sc-police does not define jobs (no jobs file/SQL; job definitions live in qbx_core). It gates nearly everything on job.type == 'leo': server/commands.lua:62,102,130,144,152,180; server/main.lua:32,161,176,223,1283; client/main.lua:73-75. config.lua:493-496 comment states the fib job shares type 'leo'.
- **Implication:** sc-police only works if sast/fib/bcso/police have type = 'leo' in qbx_core's shared jobs; that is an assumption about the server's qbx_core jobs, not something sc-police sets. Crimson-Police must decide department membership by job.name matched against Config.Departments[*].jobs (not by job.type), and may use job.type == 'leo' only as an extra sanity check. Note several sc-police checks use `job.type == 'leo' or job.name == 'police'`, so a 'police' job with a non-leo type still partially works in sc-police.

```lua
-- client/main.lua:73
function IsLeoJob()
    return PlayerJob.type == 'leo'
end

-- config.lua:493-496
-- A fully self-contained station for the federal 'fib' job. It deliberately
-- does NOT use Config.Stations (those are gated by job.type == 'leo', which the
-- fib job shares, so every LEO would inherit them).
```

### Ranks / grade structure  _(spec claim: partial)_

- **Spec claim:** job.grade.name is the rank shown on the tablet, job.grade.level is compared with supervisorGrade; Crimson-Police never changes grades
- **Evidence:** sc-police only ever reads job.grade.level (numeric): server/commands.lua:62,102 (Config.LicenseRank), server/main.lua:223 (>= 2), server/main.lua:550, server/armory.lua:13-70, client/armory.lua:40, client/job.lua:412,442, client/fibstation.lua:220,376. grep for grade.name returns nothing: sc-police never reads or sets grade.name and never changes grades. Grade labels exist only as comments in config.lua:305-439.
- **Implication:** Grades are numeric levels 0..11 for police-type jobs (armoury shops 'PoliceArmory_0'..'PoliceArmory_11') and 0..6 for FIB ('FIBArmory_0'..'FIBArmory_6'). Use `player.PlayerData.job.grade.level` (a number) for the supervisorGrade comparison and `player.PlayerData.job.grade.name` for the displayed rank; grade names come only from qbx_core jobs, not from sc-police. Pitfall: by sc-police's comments grade 3 = 'Corporal' and grade 4 = 'Sergeant'; the spec default supervisorGrade = 3 would therefore open the Supervisor UI to Corporals, while sc-dispatch's CommandGrade = 4 (Sergeant). Server owners should confirm against their real qbx_core grades. Never call SetJob/SetJobGrade or anything that changes grades.

```lua
-- config.lua Config.Armory.Weapons keys and comments:
[0] = { -- Probie/Recruit
[1] = { -- Trooper/Officer/Deputy
[2] = { -- Senior Trooper/Officer/Deputy
[3] = { -- Corporal
[4] = { -- Sergeant
[5] = { -- Lieutenant
[6] = { -- Captain
[7] = { -- Major 
[8] = { -- Lt. Colonel / Asst Chief
[9] = { -- Colonel / Chief
[10] = { -- Colonel / Chief
[11] = { -- Colonel / Chief

Config.LicenseRank = 2   -- config.lua:47
-- server/commands.lua:62
if not Player or Player.PlayerData.job.type ~= 'leo' or Player.PlayerData.job.grade.level < Config.LicenseRank then
-- server/main.lua:223
if v and v.PlayerData.job.type == 'leo' and v.PlayerData.job.grade.level >= 2 then
-- FIB armoury: Config.FIBStation.Armory.Weapons keys [0]..[6] (config.lua:581-675); FIB garage grades [0] and [3] (config.lua:564-572, garage Enabled = false)
```

### /callsign command and metadata key

- **Spec claim:** /callsign <name> saves metadata.callsign with SetMetaData; Crimson-Police only reads it
- **Evidence:** server/commands.lua:201-208; AddCommand wrapper server/commands.lua:15-23 (Config.Framework = 'qbox' at config.lua:9 -> plain RegisterCommand); readers server/main.lua:134 and :179
- **Implication:** Read it as `player.PlayerData.metadata.callsign` (key is exactly 'callsign', lowercase). It is a free-form string: all args joined with a single space, no job check (any player can set it), no length limit, no sanitising, and `/callsign` with no args stores '' (empty string). It may also be nil or the qbx_core default for players who never ran it (qbx_core's default metadata callsign is usually 'NO CALLSIGN' — not in this source, unverified). Crimson-Police must: treat nil and '' as 'no callsign' and show a fallback; HTML-escape it in all NUI (never use innerHTML/v-html); truncate to 32 characters (string.sub(cs, 1, 32)) before writing to cp_officers.callsign VARCHAR(32) or the insert can fail in strict SQL mode. Never call SetMetaData('callsign', ...).

```lua
AddCommand('callsign', Lang:t('commands.callsign'), { { name = 'name', help = Lang:t('info.callsign_name') } }, false, function(source, args)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if Player then
        Player.Functions.SetMetaData('callsign', table.concat(args, ' '))
        TriggerClientEvent('QBCore:Notify', src, 'Callsign set to: ' .. table.concat(args, ' '), 'success')
    end
end)

-- wrapper in qbox mode:
if Config.Framework == 'qbox' then
    RegisterCommand(name, function(source, args)
        callback(source, args)
    end, restricted)

-- readers:
label = v.PlayerData.metadata['callsign'] or v.PlayerData.job.name,   -- server/main.lua:134
label = v.PlayerData.metadata['callsign'],                           -- server/main.lua:179
```

### Duty toggle mechanism

- **Spec claim:** Standard Qbox duty (job.onduty)
- **Evidence:** client/job.lua:30-45 (RequestToggleDuty), client/job.lua:753-797 (duty zones on Config.Locations.duty, canInteract IsLeoJob), client/job.lua:1132-1134 (police:client:ToggleDuty), client/fibstation.lua:257-266 (FIB duty uses the same event); on-duty reads everywhere use PlayerData.job.onduty
- **Implication:** sc-police has no duty state of its own; it fires qbx_core's own 'QBCore:ToggleDuty' net event, so duty lives only in qbx_core's `PlayerData.job.onduty` (boolean). Crimson-Police reads `player.PlayerData.job.onduty` (server) / `exports.qbx_core:GetPlayerData().job.onduty` (client) and listens for 'QBCore:Server:SetDuty' (src, onDuty) and 'QBCore:Client:SetDuty' (duty). It must never trigger 'QBCore:ToggleDuty' or 'police:client:ToggleDuty' itself. Any leo-type job (including fib) can toggle duty at any MRPD/BCSO/SASP duty point, since canInteract is IsLeoJob() only.

```lua
local function RequestToggleDuty()
    local pd = QBCore.Functions.GetPlayerData()
    local onDuty = pd and pd.job and pd.job.onduty
    if not onDuty and GetResourceState('sc-dispatch') == 'started' then
        local jobName = pd and pd.job and pd.job.name
        QBCore.Functions.TriggerCallback('sc-dispatch:server:IsSuspended', function(suspended)
            if suspended then
                QBCore.Functions.Notify('You are currently suspended and cannot go on duty. Contact FIB Internal Affairs.', 'error')
            else
                TriggerServerEvent('QBCore:ToggleDuty')
            end
        end, jobName)
    else
        TriggerServerEvent('QBCore:ToggleDuty')
    end
end
```

### Suspension forced off-duty  _(spec claim: partial)_

- **Spec claim:** sc-police forces suspended officers off duty through QBCore:Server:SetDuty
- **Evidence:** server/main.lua:1250-1288 (listener); client pre-check client/job.lua:30-45
- **Implication:** The wording is slightly off: sc-police LISTENS to the server-local event 'QBCore:Server:SetDuty' (args: src, onDuty) and, when onDuty is true and sc-dispatch reports a suspension, forces the officer off with `Player.Functions.SetJobDuty(false)`. It does not trigger QBCore:Server:SetDuty itself. Consequences for Crimson-Police: (1) a suspended officer produces SetDuty(src, true) quickly followed by SetDuty(src, false) (qbx_core's SetJobDuty fires the event again — qbx_core behaviour, not in this source); handler order between resources is undefined, so never treat SetDuty(true) as proof of being on duty — re-read player.PlayerData.job.onduty at action time. (2) The check runs only when going ON duty; an officer suspended mid-shift stays on duty as far as sc-police is concerned, so Crimson-Police must itself call `exports['sc-dispatch']:IsPlayerSuspended(player.PlayerData.citizenid, player.PlayerData.job.name)` (citizenid first, job NAME second, truthy result) on every accept, wrapped in pcall and guarded by GetResourceState('sc-dispatch') == 'started'. (3) Crimson's own off-duty handler (Abandoned 'off_duty') should key on onDuty == false from this event.

```lua
local function IsSuspendedFor(citizenid, jobname)
    if GetResourceState('sc-dispatch') ~= 'started' then return false end
    local suspended = false
    pcall(function()
        suspended = exports['sc-dispatch']:IsPlayerSuspended(citizenid, jobname)
    end)
    return suspended == true
end

AddEventHandler('QBCore:Server:SetDuty', function(src, onDuty)
    if not onDuty then return end
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local job = Player.PlayerData.job
    -- Only enforce for police-managed (LEO) jobs handled by this resource.
    if job.type ~= 'leo' and job.name ~= 'police' then return end
    if IsSuspendedFor(Player.PlayerData.citizenid, job.name) then
        pcall(function() Player.Functions.SetJobDuty(false) end)
        TriggerClientEvent('QBCore:Notify', src, GetDutyBlockMessage(), 'error')
    end
end)
```

### Duty point: Mission Row PD

- **Spec claim:** Mission Row PD (470.63, -974.11, 30.18)
- **Evidence:** config.lua:938-942
- **Implication:** Exact value vec3(470.6327, -974.1052, 30.1840); the spec's rounded value is fine. The duty zone is an ox_target box of 1.5 x 1.5 x 2 (client/job.lua:757-760). Other MRPD points (blip, impound 443.8,-1019.86; heli pad 449.68,-982.18,43.69; mugshot, vehicle return 454.45,-1018.04) are all within 54 m of this point, so they are inside the 120 m no-build zone.

```lua
['MRPD'] = {
    label = 'Mission Row PD',
    blip = vector4(428.23, -984.28, 29.76, 3.5),
    duty = vec3(470.6327, -974.1052, 30.1840),
```

### Duty point: Sandy Shores BCSO

- **Spec claim:** Sandy Shores BCSO (1833.06, 3679.32, 33.19)
- **Evidence:** config.lua:986-990
- **Implication:** Exact match. Station key is 'BCSO', label 'BCSO'. All BCSO points are within about 25 m (inside the 80 m zone). Note: SASP's trash point is misconfigured in sc-police at vec3(1810.3, 3666.69, 33.58) (config.lua:1037), which is in Sandy Shores about 26 m from the BCSO duty point, so it is also covered.

```lua
['BCSO'] = {
    label = 'BCSO',
    blip = vec4(1834.0, 3675.78, 33.19, 178.51),
    duty = vec3(1833.06, 3679.32, 33.19),
```

### Duty point: SASP

- **Spec claim:** SASP (1560.38, 815.76, 76.21)
- **Evidence:** config.lua:1020-1024
- **Implication:** Exact match. SASP vehicle spawn (1556.44, 800.27), return (1553.61, 802.34), impound (1545.69, 801.19) and heli (1559.93, 816.35, 89.65) are all within 21 m (inside the 80 m zone).

```lua
['SASP'] = {
    label = 'SASP',
    blip = vec4(1560.38, 815.76, 76.21, 62.37),
    duty = vec3(1560.38, 815.76, 76.21),
```

### Duty point: FIB HQ  _(spec claim: no)_

- **Spec claim:** FIB HQ duty point (466.76, -947.90, 37.25)
- **Evidence:** config.lua:505-524: (466.76, -947.9, 37.25) is Config.FIBStation.Blip.Coords (map blip), NOT the duty point. The FIB duty point is Config.FIBStation.Duty.Coords = vec3(469.5532, -961.8162, 38.4442), used at client/fibstation.lua:257-266. config.lua:503-504 says every FIB coordinate is a RANDOM PLACEHOLDER to be moved later.
- **Implication:** Correct the spec/appendix: the FIB duty point is (469.55, -961.82, 38.44); (466.76, -947.90, 37.25) is the FIB HQ blip. Both sit next to MRPD (duty 14.9 m and blip 27.4 m from 470.63,-974.11), so the combined 'Mission Row PD and FIB HQ' no-build zone (radius 120) still covers them, and so do the FIB stash, armoury and IA/GTF lockers (all within 30 m). Because sc-police marks these as placeholders that 'will be moved to the real FIB building later', the default no-build zone may stop covering FIB once the server owner moves them; say so in the server owner checklist. The FIB garage (128.40, -770.20) is 398 m away but has Enabled = false.

```lua
Config.FIBStation = {
    Enabled = true,
    JobName = 'fib',
    Blip = {
        Enabled = true,
        Coords  = vec3(466.76, -947.9, 37.25),
        ...
        Label   = 'FIB Headquarters',
    },
    Duty = {
        Coords = vec3(469.5532, -961.8162, 38.4442),
        Size   = vec3(1.5, 1.5, 2.0),
    },
```

### No-build zones cover stations

- **Spec claim:** the default no-build zones cover them
- **Evidence:** Distances computed from the config.lua:938-1051 and 505-575 coordinates to spec noBuildZones (spec.md:1950-1957)
- **Implication:** With the current sc-police values every enabled station point is inside the spec's default zones (3D and 2D). Use 2D (xy) distance for the no-build test so the MRPD heli pad (z 43.69) and FIB floors (z ~38) don't matter.

```lua
MRPD duty 0.0 m | FIB duty 14.9 m | FIB blip 27.4 m | FIB armory 29.0 m | MRPD impound 53.1 m (zone r=120)
BCSO duty 0.0 m | BCSO mugshot 25.0 m (r=80)
SASP duty 0.0 m | SASP impound 20.7 m (r=80)
```

### GetCurrentCops export

- **Spec claim:** Export GetCurrentCops() exists on the server; Crimson-Police does not need it
- **Evidence:** server/main.lua:157-166 (function), server/main.lua:1245 (export)
- **Implication:** exports['sc-police']:GetCurrentCops() takes no args and returns an integer count of on-duty leo-type players of ALL departments (it is not per-department). Crimson-Police does not need it and, per Hard rules, has no activation requirement, so don't call it. NEVER call exports['sc-police']:SendDispatchAlert(data) or SendPoliceDispatch(src, title, message, coords, priority, blipData): both create SC-Dispatch calls, which the 'NPCs only / no mission alerts' rule forbids. Client export GetCopCount (client/main.lua:25) is buggy (it reads a global copCount while the real value is a later `local copCount` at client/main.lua:181), so it always returns 0; don't use it.

```lua
local function GetCurrentCops()
    local amount = 0
    local players = QBCore.Functions.GetQBPlayers()
    for _, v in pairs(players) do
        if v and v.PlayerData.job.type == 'leo' and v.PlayerData.job.onduty then
            amount = amount + 1
        end
    end
    return amount
end
...
exports('GetCurrentCops', GetCurrentCops)
exports('SendDispatchAlert', SendDispatchAlert)
exports('SendPoliceDispatch', SendPoliceDispatch)
```

### NPC arrests / sc-police cuffing and jail events to never call

- **Spec claim:** Crimson-Police uses its own ox_target 'Cuff suspect' action for NPCs, never sc-police's player cuffing or jail
- **Evidence:** server/interactions.lua:56-93 (police:server:CuffPlayer), :95-124 (UncuffPlayer), :263-274 and server/main.lua:391-397 (SetHandcuffStatus, registered twice), :277-321 (Escort/UnEscort), :323+ (KidnapPlayer), :349 (PutPlayerInVehicle), :385 (SetPlayerOutVehicle), :410 (TakeOutVehicle); client/interactions.lua:578,610,644,741,782 (CuffPlayerSoft, CuffPlayer, GetEscorted, GetCuffed, GetUncuffed); server/commands.lua:248-282 (police:server:JailPlayer), :284-310 (/unjail); server/main.lua:1009-1014 (handcuffs usable item); client/interactions.lua:1367 (targets are addGlobalPlayer only)
- **Implication:** Never trigger any police:server:* / police:client:* cuff, escort, kidnap, vehicle, jail or search event, never call TriggerClientEvent('police:client:GetCuffed'...), never set metadata 'ishandcuffed' or state 'invBusy', and never run /cuff, /sc, /escort, /jail, /unjail. These all target PLAYERS (server ids, GetClosestPlayer). sc-police's ox_target options are registered with addGlobalPlayer only, so Crimson-Police's NPC 'Cuff suspect' option (use exports.ox_target:addLocalEntity(netIdOrEntity, ...) on mission peds, or addGlobalPed with a canInteract that checks a Crimson-Police entity state) will not collide. Use option names prefixed 'crimson-police:' and not 'police_*'. Pitfall: using the 'handcuffs' ITEM (ox_inventory use) runs police:client:CuffPlayerSoft, which cuffs the closest PLAYER within 1.5 m, possibly a partner officer. So the NPC cuff flow must be an ox_target action that does not use or consume that item; if it requires the item, only check it with exports.ox_inventory:Search(src, 'count', 'handcuffs').

```lua
RegisterNetEvent('police:server:CuffPlayer', function(playerId, isSoftcuff) ... TriggerClientEvent('police:client:GetCuffed', playerId, src, isSoftcuff)
RegisterNetEvent('police:server:UncuffPlayer', function(playerId)
RegisterNetEvent('police:server:SetHandcuffStatus', function(status)  -- sets sender's metadata.ishandcuffed + Player(src).state.invBusy
RegisterNetEvent('police:server:EscortPlayer', function(playerId)
RegisterNetEvent('police:server:JailPlayer', function(targetId, jailTime)  -- sets injail/criminalrecord, fires sc-prison:client:SendToJail, prison:client:SendToJail, exports.qbx_prison:Jail

QBCore.Functions.CreateUseableItem('handcuffs', function(source)
    ...
    TriggerClientEvent('police:client:CuffPlayerSoft', src)
end)

exports.ox_target:addGlobalPlayer({ { name = 'police_cuff', label = 'Handcuff', ... }, { name = 'police_uncuff', label = 'Remove Cuffs' }, { name = 'police_escort' }, { name = 'police_unescort' }, { name = 'police_frisk' }, { name = 'police_search' }, { name = 'police_put_vehicle' }, { name = 'police_out_vehicle' }, { name = 'police_fingerprint' }, { name = 'police_gsr' }, { name = 'police_collect_dna' }, ... })
```

### Prison files loaded by fxmanifest

- **Spec claim:** sc-police's prison files are not loaded by its fxmanifest
- **Evidence:** fxmanifest.lua:16-42 lists client_scripts main, job, interactions, evidence, evidencelocker, objects, camera, tracker, armory, registration, fibstation, and server_scripts upload.js, main, commands, interactions, evidence, vehicle, objects, armory, registration, fibstation. client/prison.lua, client/prisonlife.lua, client/prisonbreak.lua, server/prison.lua and server/prisonlife.lua exist on disk but are NOT listed.
- **Implication:** No sc-police prison events (prison:server:*, prison:client:*), prison alarms or prison dispatch calls ('prison_<time>' ids) run. Crimson-Police's Prison Break must not rely on or trigger any prison:* event. If a real prison resource is installed separately (sc-prison/qb-prison/qbx_prison, see README.md:18), that is outside sc-police.

```lua
client_scripts {
    'client/main.lua',
    'client/job.lua',
    'client/interactions.lua',
    'client/evidence.lua',
    'client/evidencelocker.lua',
    'client/objects.lua',
    'client/camera.lua',
    'client/tracker.lua',
    'client/armory.lua',
    'client/registration.lua',
    'client/fibstation.lua',
}
server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/upload.js',
    'server/main.lua',
    'server/commands.lua',
    'server/interactions.lua',
    'server/evidence.lua',
    'server/vehicle.lua',
    'server/objects.lua',
    'server/armory.lua',
    'server/registration.lua',
    'server/fibstation.lua',
}
```

### Prison middle point (Config.Prison.Locations.middle)  _(spec claim: not_found)_

- **Spec claim:** Server owner checklist (spec.md:2551): SC-Police treats anyone within 200 m of Config.Prison.Locations.middle in its prison config as inside the prison
- **Evidence:** Config.Prison is never defined: config.lua (1305 lines) has no Config.Prison block, and `grep -rn "Prison\s*="` finds nothing. It is only referenced in the unloaded files: server/prison.lua:157,181,230-233,247 and client/prisonbreak.lua:114-115,228-230. The spec's Bolingbroke zone value (1768.73, 2570.43, 44.73) matches sc-ambulance/config.lua:254 CheckInLocation, not any sc-police value.
- **Implication:** The 200 m 2D rule exists only in dead code, and this copy of sc-police has no middle coordinate. Crimson-Police cannot read it (and must not try: Config.Prison is nil, so indexing it errors). Keep the Bolingbroke no-build zone as Crimson-Police's own config value. Reword the checklist: point the owner at their actual prison resource's middle point (for reference, stock qb-prison uses vector4(1693.33, 2569.51, 45.55, 123.5); that is not in this source and is unverified). The 2D distance test should be the one Crimson-Police uses.

```lua
-- server/prison.lua:230-233 (NOT loaded)
local middle = vec2(Config.Prison.Locations.middle.x, Config.Prison.Locations.middle.y)
-- Check player is outside prison area
if #(coords.xy - middle) < 200 then

-- client/prisonbreak.lua:228-230 (NOT loaded)
local middle = Config.Prison.Locations.middle
if #(pos.xy - vec2(middle.x, middle.y)) > 200 and inJail then
```

### How sc-police accesses the framework

- **Spec claim:** (focus) exports.qbx_core vs qb-core
- **Evidence:** Every server and client file uses the QBCore bridge: server/main.lua:4, server/commands.lua:4, server/interactions.lua:4, server/objects.lua:1, server/evidence.lua:4, server/vehicle.lua:1, server/registration.lua:7, server/fibstation.lua:10, client/main.lua:4 (global QBCore). fxmanifest.lua:59-63 lists dependency 'qb-core'. grep for exports.qbx_core / exports['qbx_core'] finds 0 uses (only a comment at server/main.lua:1253).
- **Implication:** sc-police works on Qbox through qbx_core's qb-core compatibility layer. Crimson-Police must NOT copy this pattern (Hard rule 2): use exports.qbx_core:GetPlayer(src), exports.qbx_core:GetPlayerData() and so on, and don't list qb-core as a dependency. The only sc-police server exports that exist are GetCurrentCops, SendDispatchAlert, SendPoliceDispatch, evidence exports (GetPlayerGSR, SetPlayerGSR, GetPlayerStatus, GetAll*, InvalidateSerialCache, CreateFingerprint) and ox_inventory item exports (UseGSRCloth, UseGSRTestKit, useBobbyPin, UseEvidenceCleanup, openMoneybag). Crimson-Police needs none of them. The resource also answers to exports['qb-policejob'] (provides).

```lua
local QBCore = exports['qb-core']:GetCoreObject()   -- server files
QBCore = exports['qb-core']:GetCoreObject()         -- client/main.lua:4 (global)

dependencies {
    'qb-core',
    'ox_lib',
    'oxmysql',
}
provides {
    'qb-policejob',
}
```

### Dispatch call ids created by sc-police

- **Spec claim:** (context for Real calls) every non-npccall- id is a real call
- **Evidence:** server/main.lua:94, server/commands.lua:43, server/commands.lua:600, server/prison.lua:66 (not loaded), server/evidence.lua:2042 (SuspiciousDispatch, disabled by config.lua:855-858)
- **Implication:** sc-police's calls use the prefixes police_, police_cmd_ and 911_ followed by <src>_<time>. None start with npccall-, so responding to them correctly counts as a real call and ends the run. None of them are in Config.Calls.ownRunCallPrefixes (shots_/panic_/emshelp_/playerdown_/playerdead_), so don't add them. Note /911's job_table is { 'police', 'sheriff' }, not PoliceJobs.

```lua
unique_id = 'police_' .. src .. '_' .. os.time()        -- SendPoliceDispatch (police:server:policeAlert etc.)
unique_id = 'police_cmd_' .. src .. '_' .. os.time()    -- commands.lua SendToDispatch
unique_id = '911_' .. src .. '_' .. os.time()           -- /911, job_table = { 'police', 'sheriff' }
unique_id = 'prison_' .. os.time()                       -- prison.lua (not loaded)
```

### Client job/duty events sc-police also listens to

- **Spec claim:** Events QBCore:Client:OnJobUpdate, QBCore:Client:SetDuty (onDuty), QBCore:Client:OnPlayerUnload
- **Evidence:** client/main.lua:100 (OnPlayerLoaded), :123 (OnPlayerUnload), :135 (OnJobUpdate(JobInfo)), :143 (SetDuty(duty)); client/fibstation.lua:411-421; client/tracker.lua:282
- **Implication:** The payloads are confirmed: OnJobUpdate passes the job table (name, type, onduty, grade.level and so on), and SetDuty passes a boolean. Crimson-Police can register its own handlers for the same events (several handlers per event are fine) and must not trigger them.

```lua
RegisterNetEvent('QBCore:Client:OnJobUpdate', function(JobInfo)
    PlayerJob = JobInfo
...
RegisterNetEvent('QBCore:Client:SetDuty', function(duty)
    onDuty = duty
```

### Other findings

- Commands sc-police registers (in qbox mode with plain RegisterCommand; restricted=true means ACE 'command.<name>'): grantlicense, revokelicense, takedrivinglicense, spikestrip, pobject, cuff, sc, escort, callsign, frisk, seizecash, jail (only if Config.EnableJailCommand, currently false), unjail, clearcasings, clearblood, takedna (registered twice), depot, imp, cam, paytow, paylawyer, 911, fixcuffs, resetcuffs; client: returnpolicevehicle. Crimson-Police's /CrimsonPolice and /CrimsonPoliceAdmin do not clash.
- Kick trap: server/vehicle.lua:333-338 'police:server:TakeOutImpound'(plate, garage) calls DropPlayer(src, 'Attempted exploit abuse') when the sender is more than 10 m from Config.Locations.impound[garage]. Never trigger any police:server:* event.
- Evidence side effect: client/evidence.lua:810-862 makes every armed player who shoots (IsPedShooting, any non-whitelisted weapon, no job or state-bag exemption) send evidence:server:CreateCasing, CreateBulletHole and CreateBulletFragment and set GSR (evidence:server:SetGSR true, 15-minute decay). client/evidence.lua:877-917 also drops blood when players are hurt. Mission combat will therefore leave sc-police casings, bullet holes, fragments and blood in the world, and GSR on officers. These are not dispatch alerts, so no Hard rule is broken, but the crimsonArena flag does NOT suppress them. Crimson-Police must not try to clear them (no evidence:server:Clear* calls, since that edits sc-police state); mention it in the SOP or owner checklist if needed.
- sc-police sets Player(src).state.invBusy and metadata.ishandcuffed when a player is cuffed (server/interactions.lua:263-274). Crimson-Police must not write invBusy. If it wants to block a mission action for a cuffed officer, it may read player.PlayerData.metadata.ishandcuffed (read-only).
- Suspension messages: sc-police calls exports['sc-dispatch']:GetDutyBlockMessage() and, if it exists, GetArmouryBlockMessage(). The client pre-check uses the QBCore callback 'sc-dispatch:server:IsSuspended' with the job name. Crimson-Police should use only exports['sc-dispatch']:IsPlayerSuspended(citizenid, jobname) server-side, as the appendix lists, wrapped in pcall with a GetResourceState check the way sc-police does it (server/main.lua:1257-1264).
- sc-police's SetDuty guard only applies to `job.type == 'leo' or job.name == 'police'` and is skipped entirely if sc-dispatch is not started, so Crimson-Police's own suspension check must not depend on sc-police.
- sc-multijob changes duty through exports.qbx_core:SetJobDuty, which (in qbx_core, not in this source) fires QBCore:Server:SetDuty. sc-police's suspension listener therefore also catches multijob duty toggles; Crimson-Police's off_duty abandon handler will receive those events as well.
- Config.Framework = 'qbox' and Config.TargetResource = 'ox_target' (config.lua:9-12). sc-police registers its duty, stash and armoury zones as ox_target box zones of 1.5x1.5x2 on the Config.Locations points, and its player options with addGlobalPlayer. Crimson-Police's ox_target options on NPC entities or its own zones won't overlap unless a mission marker is placed at a station, which the no-build zones prevent.
- Config.MugshotWebhook in config.lua:188 contains a live-looking Discord webhook URL. This is a data-hygiene note only; Crimson-Police must not reuse it.
- Station keys in Config.Stations are 'MRPD', 'BCSO' and 'SASP' (config.lua:938, 986, 1020); FIB is separate in Config.FIBStation. There is no Paleto, Vespucci or Davis station, so the spec's four duty locations are the full set.
- Unverified outside this source (qbx_core not provided): qbx_core's QBCore:ToggleDuty handler and Player.Functions.SetJobDuty fire TriggerEvent('QBCore:Server:SetDuty', src, onduty) and TriggerClientEvent('QBCore:Client:SetDuty', src, onduty), and the default metadata.callsign is 'NO CALLSIGN'. Check these against the server's qbx_core copy.

## Renewed-Banking v2.1.4

### handleTransaction: parameter order

- **Spec claim:** exports['Renewed-Banking']:handleTransaction(account, title, amount, message, issuer, receiver, type, transID), server side
- **Evidence:** server/main.lua:248-284; README.md:33-41
- **Implication:** Call exactly: exports['Renewed-Banking']:handleTransaction(account, title, amount, message, issuer, receiver, transType, transID). Server-only export (registered in a server_script). The first 7 arguments are required, and each must have the right Lua type: account, title, message, issuer, receiver and transType must be strings; amount must be a Lua number, NOT a string (tostring(amount) fails the check). transID is optional but must be a string if you pass it. Build it as ('CP-%s-%s'):format(run_uuid, citizenid). Empty strings pass the checks (not '' is false), but never pass nil for issuer or receiver: resolve the department label and the character name first.

```lua
local function handleTransaction(account, title, amount, message, issuer, receiver, transType, transID)
    if not account or Type(account) ~= 'string' then return print(locale("err_trans_account", account)) end
    if not title or Type(title) ~= 'string' then return print(locale("err_trans_title", title)) end
    if not amount or Type(amount) ~= 'number' then return print(locale("err_trans_amount", amount)) end
    if not message or Type(message) ~= 'string' then return print(locale("err_trans_message", message)) end
    if not issuer or Type(issuer) ~= 'string' then return print(locale("err_trans_issuer", issuer)) end
    if not receiver or Type(receiver) ~= 'string' then return print(locale("err_trans_receiver", receiver)) end
    if not transType or Type(transType) ~= 'string' then return print(locale("err_trans_type", transType)) end
    if transID and Type(transID) ~= 'string' then return print(locale("err_trans_transID", transID)) end
    ...
end exports("handleTransaction", handleTransaction)
```

### handleTransaction: what it inserts (record shape)

- **Spec claim:** Records the payout in the bank history
- **Evidence:** server/main.lua:258-267
- **Implication:** One entry per call, with these fields: trans_id, title, amount, trans_type, receiver, message, issuer, time (epoch seconds). The entry is PREPENDED (table.insert(..., 1, transaction)) to an in-memory array. Then the WHOLE array is JSON-encoded and written into one longtext column. No row is created per transaction. With the spec's call, the entry is: title='Crimson-Police', message='Mission payout: <mission label>', issuer=<department label>, receiver=<character name>, trans_type='deposit'. The UI prints trans_type:upper() and styles only 'withdraw' as red. Any other value, including 'deposit', gets the deposit style. So always pass exactly 'deposit' or 'withdraw', in lowercase.

```lua
local transaction = {
    trans_id = transID or genTransactionID(),
    title = title,
    amount = amount,
    trans_type = transType,
    receiver = receiver,
    message = sanitizeMessage(message),
    issuer = issuer,
    time = os.time()
}
```

### handleTransaction: where it writes (personal vs society)  _(spec claim: partial)_

- **Spec claim:** account = citizenid (personal) or the society account
- **Evidence:** server/main.lua:268-282
- **Implication:** Society or shared accounts (keys of cachedAccounts, e.g. 'sast', 'fib') write to bank_accounts_new.transactions. Personal accounts write to player_transactions.transactions, NOT bank_accounts_new, and ONLY IF cachedPlayers[citizenid] is already loaded. An offline player, or one whose RB cache is not loaded yet, gets NO history entry: RB just prints 'Account not found (<cid>)'. Pass the citizenid exactly as in Player.PlayerData.citizenid, with its case unchanged. The DB write is fire-and-forget (MySQL.prepare, not awaited).

```lua
if cachedAccounts[account] then
    table.insert(cachedAccounts[account].transactions, 1, transaction)
    local transactions = json.encode(cachedAccounts[account].transactions)
    MySQL.prepare("INSERT INTO bank_accounts_new (id, transactions) VALUES (?, ?) ON DUPLICATE KEY UPDATE transactions = ?",{
        account, transactions, transactions
    })
elseif cachedPlayers[account] then
    table.insert(cachedPlayers[account].transactions, 1, transaction)
    local transactions = json.encode(cachedPlayers[account].transactions)
    MySQL.prepare("INSERT INTO player_transactions (id, transactions) VALUES (?, ?) ON DUPLICATE KEY UPDATE transactions = ?", {
        account, transactions, transactions
    })
else
    print(locale("invalid_account", account))
end
return transaction
```

### handleTransaction: return value  _(spec claim: partial)_

- **Spec claim:** (spec does not say; Crimson-Police may be tempted to use it as a success flag)
- **Evidence:** server/main.lua:249-256 (return print(...) => nil); server/main.lua:280-283 (returns transaction even when the account is unknown); README.md:43-51
- **Implication:** It returns nil only when an argument fails the type checks. Otherwise it ALWAYS returns the transaction table (trans_id, title, amount, trans_type, receiver, message, issuer, time), EVEN WHEN NOTHING WAS STORED because the account was not found. A truthy return does not mean the entry was saved. Use the return only to detect bad arguments (if not tx then log 'invalid args'). To confirm the personal account is loaded, see the getAccountTransactions extra finding.

```lua
else
    print(locale("invalid_account", account))
end
return transaction
```

### handleTransaction: must transID be unique?  _(spec claim: partial)_

- **Spec claim:** transID = CP-<run_uuid>-<citizenid>, used as the anti-double-payment reference and for a manual check
- **Evidence:** server/main.lua:256,259 (no uniqueness check); server/main.lua:413-414, 429-430, 441-442, 457-458 (RB reuses one trans_id on both sides of a transfer); web/public/build/bundle.js (minified, single line): transaction list is a Svelte keyed each: `c=t[2].transactions.filter(t[9]);const r=t=>t[10].trans_id;...o.set(a,s[e]=Bt(a,n))`
- **Implication:** RB never enforces uniqueness: there is no DB constraint, because the ID lives inside a JSON array, and a second call with the same transID just adds a duplicate entry. RB CANNOT be used for idempotency. Crimson-Police's own cash_status claim (UPDATE ... SET cash_status='paying' WHERE ... IN ('none','held','pending')) is the only double-pay guard. Reusing the same transID on the personal 'deposit' and the society 'withdraw' matches RB's own transfer pattern, and those are two different account lists. Never write the same transID twice into the SAME account: the NUI keys its list by trans_id, and duplicate keys in a production Svelte keyed-each can drop or garble rows. No length limit applies (it is stored in longtext JSON).

```lua
trans_id = transID or genTransactionID(),
-- RB's own society->player transfer:
local transaction = handleTransaction(data.fromAccount, ("%s / %s"):format(cachedAccounts[data.fromAccount].name, data.fromAccount), amount, data.comment, cachedAccounts[data.fromAccount].name, plyName, "withdraw")
handleTransaction(data.stateid, ("%s / %s"):format(cachedAccounts[data.fromAccount].name, data.fromAccount), amount, data.comment, cachedAccounts[data.fromAccount].name, plyName, "deposit", transaction.trans_id)
```

### handleTransaction: message sanitization  _(spec claim: partial)_

- **Spec claim:** message = 'Mission payout: <mission label>'
- **Evidence:** server/main.lua:239-245, 264
- **Implication:** The message field ONLY (not title, issuer or receiver) has every ' doubled and every \ doubled, and it is stored that way. The UI shows it literally, so a label like "Gang's Hideout" shows as "Gang''s Hideout". Strip or replace apostrophes and backslashes in the mission label before building the message, e.g. label:gsub("['\\]", ''), or use a typographic ’. Character names in receiver are not changed.

```lua
local function sanitizeMessage(message)
    if type(message) ~= "string" then
        message = tostring(message)
    end
    message = message:gsub("'", "''"):gsub("\\", "\\\\")
    return message
end
```

### removeAccountMoney: signature and return values

- **Spec claim:** exports['Renewed-Banking']:removeAccountMoney(account, amount); society source only; returns false when the account cannot cover it
- **Evidence:** server/main.lua:350-364; README.md:65-69
- **Implication:** Returns true on success. Returns false when the account does not exist OR when balance < amount; a balance exactly equal to the amount succeeds. Both false cases mean 'unfunded' to Crimson-Police, so the two reasons cannot be told apart from the return value. The amount is NOT validated: a nil amount raises a Lua error ('attempt to compare nil with number'), which surfaces as an export error in Crimson-Police, and a negative amount ADDS money. Always pass a positive integer, and wrap the call in pcall. Skip the call entirely when the amount is 0: RB would return true and a later handleTransaction would log a $0 entry. There is no yield between the check and the subtraction, so it is race-safe within the server. The DB update (UPDATE bank_accounts_new SET amount = ? WHERE id = ?) is async and not awaited (main.lua:295-297). It records NO transaction: Crimson-Police must call handleTransaction(societyAccount, ..., 'withdraw', transID) itself. It works ONLY on society or shared accounts (cachedAccounts); removeAccountMoney(citizenid, x) returns false.

```lua
function RemoveAccountMoney(account, amount)
    if not cachedAccounts[account] then
        print(locale("invalid_account", account))
        return false
    end
    if cachedAccounts[account].amount < amount then
        print(locale("broke_account", account, amount))
        return false
    end

    cachedAccounts[account].amount -= amount
    updateBalance(account)
    return true
end
exports('removeAccountMoney', RemoveAccountMoney)
```

### getAccountMoney

- **Spec claim:** exports['Renewed-Banking']:getAccountMoney(account) returns the society balance shown in the Admin UI
- **Evidence:** server/main.lua:286-293; README.md:54-57
- **Implication:** Returns the cached balance (a number, possibly 0) or false when the account is missing. Nothing is printed, because of an RB bug (locale() is called without print). Show 'Account not found' for false, and do not show $0. Test with `if bal == false` or `type(bal) ~= 'number'`, NOT `if not bal`; that particular check is fine because 0 is truthy in Lua, but keep the intent clear. It only covers society or shared accounts. For a citizenid it returns false: personal balances come from Qbox (player.PlayerData.money.bank).

```lua
function GetAccountMoney(account)
    if not cachedAccounts[account] then
        locale("invalid_account", account)
        return false
    end
    return cachedAccounts[account].amount
end
exports('getAccountMoney', GetAccountMoney)
```

### addAccountMoney

- **Spec claim:** (not in the spec's Appendix; focus item)
- **Evidence:** server/main.lua:299-308; README.md:59-63
- **Implication:** exports['Renewed-Banking']:addAccountMoney(account, amount) returns true, or false when the society account is missing. The amount is not validated: a nil amount errors on arithmetic. It records no transaction. It works only on society or shared accounts and CANNOT pay a player: addAccountMoney(citizenid, x) returns false. The spec never lists it. It is the only way to refund a society withdrawal when the later player.Functions.AddMoney step fails, e.g. the player dropped between the claim and the payment (see extraFindings).

```lua
function AddAccountMoney(account, amount)
    if not cachedAccounts[account] then
        locale("invalid_account", account)
        return false
    end
    cachedAccounts[account].amount += amount
    updateBalance(account)
    return true
end
exports('addAccountMoney', AddAccountMoney)
```

### Personal balance: Renewed-Banking reads Qbox money; the deposit is player.Functions.AddMoney('bank', ...)

- **Spec claim:** Renewed-Banking reads Qbox money, so the deposit itself is player.Functions.AddMoney('bank', …); handleTransaction only records it in the bank history
- **Evidence:** server/framework.lua:94-100 (GetFunds), 110-113 (AddMoney), 122-128 (RemoveMoney); server/main.lua:183-190 (getBankData uses funds.bank); main.lua:337, 427, 455 (RB itself pays players with AddMoney(Player, amount, 'bank', comment))
- **Implication:** Personal bank money lives ONLY in Qbox PlayerData.money.bank. RB has no personal balance column: player_transactions only holds history. Pay with player.Functions.AddMoney(Config.Cash.account, amount, 'crimson-police-mission'), where player = exports.qbx_core:GetPlayer(src); the argument order (moneyType, amount, reason) is the same one RB uses. RB does NOT record any history for money added this way (it has no money-change listener), so Crimson-Police must call handleTransaction(citizenid, ...) itself. The RB UI reads the balance live when the bank opens.

```lua
function GetFunds(Player)
    if Framework == 'qb' or Framework == 'qbx' then
        local funds = {
            cash = Player.PlayerData.money.cash,
            bank = Player.PlayerData.money.bank
        }
        return funds
...
function AddMoney(Player, Amount, Type, comment)
    if Framework == 'qb' or Framework == 'qbx' then
        Player.Functions.AddMoney(Type, Amount, comment)
```

### Framework: qbx_core vs qb-core

- **Spec claim:** qbx_core (Qbox APIs only, as used by ... Renewed-Banking)
- **Evidence:** server/framework.lua:1, 21-31, 56-76; client/framework.lua:1
- **Implication:** qbx_core is detected before qb-core, so on Qbox RB uses exports.qbx_core:GetPlayer, GetPlayerByCitizenId, GetJobs and GetGangs, plus the player-object methods Player.Functions.AddMoney, RemoveMoney and GetMoney. It never calls the QBCore core object on Qbox. RB stops itself if no framework is detected. The qb-core branch (QBCore = exports['qb-core']:GetCoreObject()) exists but is not used on Qbox. Its qb-management compatibility exports are also registered on qbx (framework.lua:26-31), but Crimson-Police must not use them (Hard rules).

```lua
local Framework = GetResourceState('es_extended') == 'started' and 'esx' or GetResourceState('qbx_core') == 'started' and 'qbx' or GetResourceState('qb-core') == 'started' and 'qb' or 'Unknown'
...
elseif Framework == 'qbx' then
    Jobs = exports.qbx_core:GetJobs()
    Gangs = exports.qbx_core:GetGangs()
...
elseif Framework == 'qbx' then
    return exports.qbx_core:GetPlayer(source)
...
    identifier = identifier:upper()
    return exports.qbx_core:GetPlayerByCitizenId(identifier)
```

### QBCore:Server:PlayerLoaded event payload

- **Spec claim:** Event QBCore:Server:PlayerLoaded (player) pays pending cash
- **Evidence:** server/framework.lua:218-221
- **Implication:** It is a server-local event (AddEventHandler, not RegisterNetEvent), and its argument is the Qbox player object, which has .PlayerData.citizenid. RB uses the SAME event to load the personal history cache: UpdatePlayerAccount runs two async MySQL queries before cachedPlayers[cid] exists (main.lua:156-176). If Crimson-Police's PlayerLoaded handler pays pending cash and calls handleTransaction(citizenid, ...) at once, the RB cache may not exist yet. The entry is then silently dropped (RB prints 'Account not found'), although the money itself still arrives through AddMoney. Delay the pending-payout step in a CreateThread with Wait(3000 to 5000), and check again that the player is still online, before calling handleTransaction.

```lua
AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    local cid = Player.PlayerData.citizenid
    UpdatePlayerAccount(cid)
end)
```

### Society accounts: how they are created and existence semantics

- **Spec claim:** societyAccount = 'sast' / 'fib' (Config.Departments); if removeAccountMoney returns false, pay $0 and mark unfunded
- **Evidence:** server/main.lua:97-154 (startup load and auto-create), 469-488 (player-created accounts), 655-722 (GetJobAccount / CreateJobAccount exports)
- **Implication:** When RB starts, a society account is created automatically, with a balance of 0, for EVERY job and gang returned by exports.qbx_core:GetJobs() and GetGangs(). The account id is the job name itself (e.g. 'sast', 'fib', 'police', 'bcso'). So societyAccount must equal the Qbox job name, unless an account with that id was made another way: a player-created account (createNewAccount) or the CreateJobAccount export. A new society account starts at $0: with Config.Cash.source='society', every payout is 'unfunded' until someone deposits into it. Jobs added to qbx_core at runtime get no account until RB restarts. All lookups are against the in-memory cachedAccounts, which is empty for about 500 ms plus one query after RB (re)starts. During that window getAccountMoney, removeAccountMoney and addAccountMoney all return false. A missing account returns false, never nil and never an error.

```lua
CreateThread(function()
    Wait(500)
    ...
    local accounts = MySQL.query.await('SELECT * FROM bank_accounts_new', {})
    ... cachedAccounts[job] = { id = job, type = locale("org"), name = GetSocietyLabel(job), frozen = v.isFrozen == 1, amount = v.amount, transactions = json.decode(v.transactions), auth = {}, creator = v.creator }
    local jobs, gangs = GetFrameworkGroups()
    ...
    for job in pairs(jobs) do
        if not cachedAccounts[job] then
            addCachedAccount(job)   -- amount = 0, INSERT INTO bank_accounts_new (...) VALUES (?, ?, ?, ?, ?, NULL)
        end
    end
    for gang in pairs(gangs) do ... end
```

### Table shapes: bank_accounts_new and player_transactions (there is no 'transactions' table)  _(spec claim: partial)_

- **Spec claim:** (focus: bank_accounts_new / transactions table shapes; spec's Admin UI manual check looks up 'the Renewed-Banking history (transaction id CP-<run_uuid>-<citizenid>)')
- **Evidence:** Renewed-Banking.sql:1-16; server/main.lua:832-837
- **Implication:** There is no per-transaction table. History is a JSON array in a longtext `transactions` column, newest first. Society or shared accounts are rows of bank_accounts_new (id = account name, amount = integer balance). Personal history is in player_transactions (id = citizenid) and has no balance. For the Admin UI manual check of a stuck 'paying' row, look in player_transactions (personal) and bank_accounts_new (society), not a 'transactions' table. Either read the JSON with oxmysql inside modules/integrations/renewed_banking/, e.g. SELECT transactions FROM player_transactions WHERE id = ?, then json.decode and search for trans_id == 'CP-<uuid>-<cid>', or LIKE '%CP-<uuid>-<cid>%'. Or, for an online player, use the getAccountTransactions export (see extraFindings). The DB copy can lag the in-memory copy (writes are async). Since amount is int(11), always pass integer amounts, e.g. math.floor(x + 0.5), which returns a Lua 5.4 integer.

```lua
CREATE TABLE IF NOT EXISTS `bank_accounts_new` (
  `id` varchar(50) NOT NULL,
  `amount` int(11) DEFAULT 0,
  `transactions` longtext DEFAULT '[]',
  `auth` longtext DEFAULT '[]',
  `isFrozen` int(11) DEFAULT 0,
  `creator` varchar(50) DEFAULT NULL,
  PRIMARY KEY (`id`)
);

CREATE TABLE IF NOT EXISTS `player_transactions` (
  `id` varchar(50) NOT NULL,
  `isFrozen` int(11) DEFAULT 0,
  `transactions` longtext DEFAULT '[]',
  PRIMARY KEY (`id`)
);
```

### Recommended exact payout calls (derived from source conventions)

- **Spec claim:** handleTransaction(citizenid, 'Crimson-Police', amount, 'Mission payout: <mission label>', '<department label>', '<character name>', 'deposit', 'CP-<run_uuid>-<citizenid>'); with society source also record a 'withdraw' on the department's account
- **Evidence:** server/main.lua:248, 341, 425-430 (RB's own convention: issuer = paying side's name, receiver = receiving character's name; withdraw on the society, deposit on the player, same trans_id)
- **Implication:** These calls follow RB's own transfer pattern exactly. charName should be built like RB's GetCharacterName: ('%s %s'):format(PlayerData.charinfo.firstname, PlayerData.charinfo.lastname) (framework.lua:78-81). safeLabel is the mission label with ' and \ removed. The spec says the personal entry is only 'for bank payments'. Whether the society 'withdraw' entry should also be written when Config.Cash.account='cash' is not said; the source allows either (withdraw entries on society accounts do not depend on the player's cache).

```lua
local RB = exports['Renewed-Banking']
local txId = ('CP-%s-%s'):format(runUuid, citizenid)
-- society source only, before AddMoney:
if Config.Cash.source == 'society' then
  local ok = RB:removeAccountMoney(dept.societyAccount, amount)  -- false => unfunded
end
player.Functions.AddMoney(Config.Cash.account, amount, 'crimson-police-mission')
if Config.Cash.account == 'bank' then
  RB:handleTransaction(citizenid, 'Crimson-Police', amount, ('Mission payout: %s'):format(safeLabel), dept.label, charName, 'deposit', txId)
end
if Config.Cash.source == 'society' then
  RB:handleTransaction(dept.societyAccount, 'Crimson-Police', amount, ('Mission payout: %s'):format(safeLabel), dept.label, charName, 'withdraw', txId)
end
```

### Other findings

- Export names are case-sensitive and lowerCamel: 'handleTransaction', 'getAccountMoney', 'addAccountMoney', 'removeAccountMoney', 'getAccountTransactions', 'addAccountMember', 'removeAccountMember', 'changeAccountName'. The two job-account exports are PascalCase: 'GetJobAccount' and 'CreateJobAccount' (server/main.lua:284,293,308,364,653,664,722,744,777,788). The global Lua functions are named GetAccountMoney, AddAccountMoney and RemoveAccountMoney, but they are exported under the lowerCamel names.
- The resource MUST be named exactly 'Renewed-Banking'; otherwise it errors and stops itself (server/main.lua:99-101). exports['Renewed-Banking'] is therefore stable. While RB is stopped or restarting, export calls throw 'No such export'. Wrap every RB call in pcall, and/or check GetResourceState('Renewed-Banking') == 'started', inside modules/integrations/renewed_banking/.
- Society refund gap: with source='society', the spec does removeAccountMoney and then player.Functions.AddMoney. If the player object is gone at that moment (they dropped after the claim), the society has already been debited. The only way to return the money is exports['Renewed-Banking']:addAccountMoney(societyAccount, amount), which the spec's Appendix does not list. Either re-fetch the player immediately before removeAccountMoney, or add addAccountMoney to the allowed calls for a refund path.
- Optional probe for the personal history cache: exports['Renewed-Banking']:getAccountTransactions(citizenid) returns the account's transaction array, or false (and prints 'Account not found') when neither cachedAccounts nor cachedPlayers has the key (server/main.lua:779-788). It can confirm the personal cache is loaded before handleTransaction, and it can serve the Admin UI manual check for online players by searching for trans_id. Caveat: the WHOLE history array is copied across the export boundary. It is also NOT in the spec's allowed-call list, so it needs a spec decision.
- Personal cache population points (cachedPlayers[cid]): RB's own QBCore:Server:PlayerLoaded handler (framework.lua:218-221); RB's onResourceStart, for all online players, after Wait(250) (framework.lua:243-254); and opening the bank UI (main.lua:182). For a normally online player who loaded after RB started, the cache exists. The race only matters at the moment a player loads in (the pending-cash payout).
- Ensure order: RB loads cachedAccounts in a thread after Wait(500) plus an awaited SELECT (main.lua:97-154). Crimson-Police should `ensure Renewed-Banking` before itself. It should also treat false from getAccountMoney or removeAccountMoney during the first seconds after an RB restart as 'unavailable', not as a real empty account; for payouts, 'unfunded' is still the safe result.
- removeAccountMoney, addAccountMoney and getAccountMoney ignore the account's frozen flag, and do not check bankAuth or any permissions. Any server-side caller can move society money. Keep these calls strictly server-side, behind Crimson-Police's own claim logic.
- Society accounts appear in the RB UI only to grades that have `bankAuth = true` in the Qbox job grade (framework.lua:181-188; README.md:82-83). The server owner must set bankAuth on the sast and fib grades that may view or fund the account. Any player can also transfer money INTO a society account by typing its id ('sast') as the target in a transfer (main.lua:438-442). Worth a line in the Server owner checklist when source='society'.
- RB records NO history when Qbox money changes outside RB. There is no money-change listener; the only RB-created entries come from its own deposit, withdraw and transfer callbacks. So without Crimson-Police's handleTransaction call, a payout would be invisible in the bank history.
- Transaction arrays are never trimmed, and each handleTransaction re-encodes and rewrites the entire array (main.lua:269-279). This is fine at mission-payout frequency, but do not call handleTransaction in loops, or for $0 amounts.
- The UI (web/public/build/bundle.js) renders title, issuer, receiver and message as text nodes, so there is no HTML injection risk. The amount is formatted with toLocaleString(currency) and time as relative time from epoch seconds. trans_type is upper-cased; only the exact string 'withdraw' gets the red styling.
- RB provides 'qb-management' and 'esx_society' (fxmanifest.lua:36-37), and on qbx it registers qb-management compatibility exports (GetAccount, AddMoney, RemoveMoney, GetGangAccount, AddGangMoney, RemoveGangMoney; framework.lua:26-31). Crimson-Police must not use those names; use only exports['Renewed-Banking'].
- RB's fxmanifest declares dependency 'ox_inventory' and requires '@ox_lib/init.lua' and '@oxmysql/lib/MySQL.lua'. These are all already in Crimson-Police's allowed stack, so there is no conflict.
- No ban, anti-cheat or kick triggers exist in Renewed-Banking's server code. Its only net events (issueDebitCard, createNewAccount, getPlayerAccounts, member management, deleteAccount, changeAccountName) and lib callbacks (deposit, withdraw, transfer, initalizeBanking, hasValidDebitCard) are player-UI flows. Crimson-Police must never trigger them: they are client-originated and not part of the integration.
