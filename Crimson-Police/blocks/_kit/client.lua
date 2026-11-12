-- The objective blocks' client kit (CP.BlockKit): what every block client did with its own copy of the code.

--   states(fresh, cleanup)  one state per run and objective; the resource-stop cleanup of every block is here
--   onStop(fn)              a block with no states (live_response) cleans up on resource stop through the kit
--   entity(netId)           the entity of a net id, or nil when it is not in this game
--   bag(ent)                the entity's 'cp' state bag, or nil (never raises on a gone entity)
--   vec3(v)                 any x/y/z shape as a vector3, or nil
--   point(t)                a mission file's { x, y, z } as a vector3, a missing coordinate 0
--   text(s)                 a locale key's text, other text as written, nil for no text
--   progress(opts, what)    lib.progressBar that never raises: true only when the bar ran to its end
--   cancelProgress()        stops this player's progress bar, if one runs
--   markers(ctx, S, source) the one marker loop of a run: per frame while any of its markers is in range, the
--                           shortest far wait of its markers (scaled by Config.Performance.loopScale) otherwise
--
-- Loaded before every block client (fxmanifest.lua); each block keeps only its own logic.

local U = CP.U

local Kit = {}
CP.BlockKit = Kit

-- ============================================================================
--                                    STATES
-- ============================================================================

local lists = {}   -- every block's states and cleanup: { active, cleanup }
local stops = {}   -- the onStop functions

-- fresh(ctx) returns a new state's table (its own fields); cleanup(S) ends one state and is also run for every
-- started state when the resource stops. Each state knows its key, its run (runKey) and the latest ctx.
function Kit.states(fresh, cleanup)
    local K = { active = {} }
    lists[#lists + 1] = { active = K.active, cleanup = cleanup }

    function K.key(ctx) return tostring(ctx.runId) .. ':' .. tostring(ctx.index) end

    -- the state of this objective, or nil
    function K.find(ctx) return K.active[K.key(ctx)] end

    -- the state of this objective, made on first use; making one drops the states other runs left behind (late
    -- snapshots after a stop)
    function K.of(ctx)
        local k = K.key(ctx)
        local S = K.active[k]
        if not S then
            local run = tostring(ctx.runId)
            for key, old in pairs(K.active) do
                if old.runKey ~= run and not old.alive then K.active[key] = nil end
            end
            S = fresh(ctx)
            S.key, S.runKey = k, run
            K.active[k] = S
        end
        S.ctx = ctx
        return S
    end

    -- forget a state (its cleanup calls this last)
    function K.drop(S)
        if K.active[S.key] == S then K.active[S.key] = nil end
    end

    return K
end

function Kit.onStop(fn) stops[#stops + 1] = fn end

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, list in ipairs(lists) do
        for _, S in pairs(list.active) do
            if S.alive then list.cleanup(S) end
        end
    end
    for _, fn in ipairs(stops) do fn() end
end)

-- ============================================================================
--                                   HELPERS
-- ============================================================================

function Kit.entity(netId)
    if not netId or not NetworkDoesNetworkIdExist(netId) then return nil end
    local e = NetworkGetEntityFromNetworkId(netId)
    if e and e ~= 0 and DoesEntityExist(e) then return e end
    return nil
end

function Kit.bag(ent)
    local ok, v = pcall(function() return Entity(ent).state.cp end)
    if ok and type(v) == 'table' then return v end
    return nil
end

function Kit.vec3(v)
    local x, y, z = U.xyz(v)
    if not x then return nil end
    return vector3(x + 0.0, y + 0.0, z + 0.0)
end

function Kit.point(t)
    return vector3((t.x or 0.0) + 0.0, (t.y or 0.0) + 0.0, (t.z or 0.0) + 0.0)
end

function Kit.text(s)
    if type(s) ~= 'string' or s == '' then return nil end
    if CP.Locale.has(s) then return CP.L(s) end
    return s
end

-- ox_lib raises when an animation fails to load: the bar then counts as cancelled (logged under what), so the
-- block's busy flag is always cleared after it.
function Kit.progress(opts, what)
    local ok, done = pcall(lib.progressBar, opts)
    if not ok then CP.warn('blocks', '%s bar failed: %s', tostring(what), tostring(done)) end
    return ok and done == true
end

function Kit.cancelProgress()
    if lib.progressActive and lib.progressActive() then pcall(lib.cancelProgress) end
end

-- ============================================================================
--                                 MARKER LOOP
-- ============================================================================
-- One loop per run draws the markers of every objective of that run. A source is
--   { range = metres, far = ms, keep = function(S) -> drawing still wanted, draw = function(S, pos, rangeSq) -> drew }
-- keep is asked every pass (false: the source is dropped); draw gets the player's position and the source's range
-- squared, capped by Config.Performance.markerRange, and returns true when it drew a marker in range. markers()
-- again for the same state replaces its source (a new token, a new range).

local runs = {}   -- [runKey] = { list of { S, source } }

local function MarkerLoop(run, list)
    CreateThread(function()
        while #list > 0 do
            local pos = GetEntityCoords(cache.ped)
            local drew, far = false, nil
            for i = #list, 1, -1 do
                local e = list[i]
                local src = e.source
                if e.S.alive and src.keep(e.S) then
                    if src.draw(e.S, pos, CP.Perf.rangeSq(src.rangeSq)) then drew = true end
                    if not far or src.far < far then far = src.far end
                else
                    e.S.kitMarker = nil
                    table.remove(list, i)
                end
            end
            if #list == 0 then break end
            Wait(drew and 0 or CP.Perf.ms(far))
        end
        if runs[run] == list then runs[run] = nil end
    end)
end

function Kit.markers(ctx, S, source)
    source.rangeSq = (source.range or 0.0) * (source.range or 0.0)
    source.far = source.far or 1500
    if S.kitMarker then
        S.kitMarker.source = source
        return
    end
    local run = tostring(ctx.runId)
    local list = runs[run]
    local start = list == nil
    if start then
        list = {}
        runs[run] = list
    end
    local e = { S = S, source = source }
    S.kitMarker = e
    list[#list + 1] = e
    if start then MarkerLoop(run, list) end
end
