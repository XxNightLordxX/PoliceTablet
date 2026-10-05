-- The real server side of Crimson-Police for the Missions and Mission Builder admin specs
-- (tests/builtin_override_spec.lua, tests/admin_missions_spec.lua): every module and block loaded in fxmanifest
-- order, the outside resources stubbed the way tests/e2e_spec.lua stubs them. Returns a table of helpers.

return function(H, name)
    H.db = (os.getenv('CP_TEST_DB') or 'cp_test') .. '_' .. name
    H.resetDatabase()
    H.boot({ side = 'server' })
    H.time = os.time({ year = 2026, month = 9, day = 23, hour = 14, min = 0, sec = 0 })
    local cjson = require('cjson')
    local X = {}

    local realPrint = print
    X.lines = {}
    _G.print = function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        local line = table.concat(parts, ' ')
        X.lines[#X.lines + 1] = line
        if os.getenv('SPEC_VERBOSE') then realPrint(line) return end
        if line:find('crimson%-police') or line:find('Crimson%-Police') then return end
        realPrint(line)
    end

    -- every locale part merged, as locales/en.json after tools/check_contracts.py --merge
    do
        local merged = {}
        local p = io.popen('ls ' .. H.root .. 'locales/parts/*.json')
        for file in p:lines() do
            local f = io.open(file, 'r')
            local ok, data = pcall(cjson.decode, f:read('a'))
            f:close()
            if ok and type(data) == 'table' then for k, v in pairs(data) do merged[k] = v end end
        end
        p:close()
        local text = cjson.encode(merged)
        local realLoad = LoadResourceFile
        LoadResourceFile = function(res, path)
            if path == 'locales/en.json' then return text end
            return realLoad(res, path)
        end
        H.load('shared/locale.lua')
        X.locale = merged
    end

    -- ---- NATIVES -----------------------------------------------------------
    local ents, nextHandle, nextNet = {}, 9000, 20000
    local netToEnt = {}
    local function NewEnt(kind, model, x, y, z, h)
        nextHandle, nextNet = nextHandle + 1, nextNet + 1
        ents[nextHandle] = {
            kind = kind,
            model = model,
            coords = vec3(x + 0.0, y + 0.0, z + 0.0),
            heading = h or 0.0,
            exists = true,
            health = kind == 'ped' and 200 or 1000,
            net = nextNet,
            type = kind == 'ped' and 1 or (kind == 'vehicle' and 2 or 3),
        }
        netToEnt[nextNet] = nextHandle
        return nextHandle
    end
    X.ents = ents
    _G.CreatePed = function(_, model, x, y, z, h) return NewEnt('ped', model, x, y, z, h) end
    _G.CreateVehicleServerSetter = function(model, _, x, y, z, h) return NewEnt('vehicle', model, x, y, z, h) end
    _G.CreateVehicle = function(model, x, y, z, h) return NewEnt('vehicle', model, x, y, z, h) end
    _G.CreateObjectNoOffset = function(model, x, y, z) return NewEnt('object', model, x, y, z) end
    _G.DoesEntityExist = function(e)
        if ents[e] then return ents[e].exists end
        return (tonumber(e) or 0) > 0
    end
    _G.DeleteEntity = function(e) if ents[e] then ents[e].exists = false end end
    _G.NetworkGetNetworkIdFromEntity = function(e) return ents[e] and ents[e].net or 0 end
    _G.NetworkGetEntityFromNetworkId = function(n) return netToEnt[n] or 0 end
    _G.NetworkGetEntityOwner = function() return 0 end
    _G.GiveWeaponToPed = function() end
    _G.SetPedArmour = function() end
    _G.GetPedArmour = function() return 0 end
    _G.GetEntityHealth = function(e) return ents[e] and ents[e].health or 200 end
    _G.GetEntityMaxHealth = function() return 200 end
    _G.GetPedMaxHealth = _G.GetEntityMaxHealth
    _G.GetEntityModel = function(e)
        return ents[e] and (type(ents[e].model) == 'number' and ents[e].model or joaat(ents[e].model)) or 0
    end
    _G.GetVehicleEngineHealth = function() return 1000.0 end
    _G.GetVehicleBodyHealth = function() return 1000.0 end
    _G.GetVehiclePetrolTankHealth = function() return 1000.0 end
    _G.GetEntityType = function(e)
        if ents[e] then return ents[e].type end
        return 0
    end
    _G.IsPedAPlayer = function(e) return ents[e] == nil end
    _G.GetPedSourceOfDeath = function() return 0 end
    _G.GetPedSourceOfDamage = function() return 0 end
    _G.GetPedCauseOfDeath = function() return 0 end
    _G.GetSelectedPedWeapon = function() return 0 end
    _G.GetVehiclePedIsIn = function() return 0 end
    _G.GetPedInVehicleSeat = function() return 0 end
    _G.SetEntityHeading = function() end
    _G.GetEntityHeading = function() return 0.0 end
    _G.SetEntityCoords = function() end
    _G.FreezeEntityPosition = function() end
    _G.SetVehicleNumberPlateText = function() end
    _G.SetVehicleDoorsLocked = function() end
    _G.SetPedIntoVehicle = function() end
    _G.GetEntitySpeed = function() return 0.0 end
    _G.WasEventCanceled = function() return false end
    _G.GetPlayerRoutingBucket = function() return 0 end
    _G.GetPlayerLastMsg = function() return 0 end
    _G.GetConvar = function(_, default) return default end
    _G.PerformHttpRequest = function() end
    _G.TriggerLatentClientEvent = function(n, target, _, ...) TriggerClientEvent(n, target, ...) end
    _G.AddStateBagChangeHandler = function() end
    X.stopResource = 0
    _G.StopResource = function() X.stopResource = X.stopResource + 1 end
    _G.GetResourcePath = function() return H.root:sub(1, -2) end
    local playerCoords = _G.GetEntityCoords
    _G.GetEntityCoords = function(e)
        if ents[e] then return ents[e].coords end
        return playerCoords(e)
    end
    local bags = {}
    _G.Entity = function(e)
        local b = bags[e]
        if not b then b = {}; bags[e] = b end
        return {
            state = setmetatable({
                set = function(_, k, v) b[k] = v end,
            }, { __index = b }),
        }
    end
    _G.GetPlayers = function()
        local out = {}
        for src in pairs(H.players) do out[#out + 1] = tostring(src) end
        table.sort(out)
        return out
    end

    -- ---- OUTSIDE RESOURCES -------------------------------------------------
    local PD = {}
    X.PD = PD
    function X.addPlayer(src, cid, first, last, job, grade, opts)
        opts = opts or {}
        PD[src] = {
            source = src,
            citizenid = cid,
            license = 'license:' .. string.rep(tostring(src % 10), 40),
            charinfo = { firstname = first, lastname = last },
            job = {
                name = job,
                label = job,
                type = (job == 'sast' or job == 'fib') and 'leo' or 'none',
                onduty = job ~= 'unemployed',
                grade = { level = grade, name = grade >= 3 and 'Sergeant' or 'Trooper' },
            },
            metadata = { callsign = 'C-' .. src, isdead = false, inlaststand = false },
        }
        H.players[src] = {
            coords = vec3(0.0, 0.0, 0.0),
            ace = opts.admin and { ['crimsonpolice.admin'] = true } or {},
            state = {},
            identifiers = { PD[src].license },
        }
    end
    local function QbxPlayer(src)
        local pd = PD[tonumber(src)]
        if not pd then return nil end
        return {
            PlayerData = pd,
            Functions = {
                AddMoney = function() return true end,
            },
        }
    end
    H.exportsMock.qbx_core = {
        GetPlayer = function(src) return QbxPlayer(src) end,
        GetPlayerByCitizenId = function(cid)
            for src, pd in pairs(PD) do if pd.citizenid == cid then return QbxPlayer(src) end end
            return nil
        end,
        GetQBPlayers = function()
            local out = {}
            for src in pairs(PD) do out[src] = QbxPlayer(src) end
            return out
        end,
        GetJobs = function()
            local grades = {
                [0] = { name = 'Cadet' },
                [1] = { name = 'Trooper' },
                [2] = { name = 'Corporal' },
                [3] = { name = 'Sergeant' },
                [4] = { name = 'Lieutenant' },
            }
            return {
                sast = { label = 'SAST', type = 'leo', grades = grades },
                fib = { label = 'FIB', type = 'leo', grades = grades },
                unemployed = { label = 'Civilian', grades = { [0] = { name = 'Freelancer' } } },
            }
        end,
    }
    H.exportsMock['sc-dispatch'] = {
        IsPlayerSuspended = function() return false end,
        ClearNotification = function() return true end,
    }
    H.exportsMock['sc-ambulance'] = {
        GetDoctorCount = function() return 0 end,
    }
    H.exportsMock['Renewed-Banking'] = {
        handleTransaction = function() return { id = 'tx' } end,
        removeAccountMoney = function() return true end,
        getAccountMoney = function() return 100000 end,
        addAccountMoney = function() return true end,
    }
    H.exportsMock.ox_inventory = {
        AddItem = function() return true end,
        Search = function() return {} end,
        RemoveItem = function() return true end,
    }
    H.exportsMock.ox_target = {}

    X.addPlayer(1, 'AMOFF001', 'Otto', 'Officer', 'sast', 1)
    X.addPlayer(3, 'AMSUP003', 'Sam', 'Sarge', 'sast', 3)
    X.addPlayer(5, 'AMADM005', 'Ada', 'Admin', 'unemployed', 0, { admin = true })
    X.addPlayer(6, 'AMADM006', 'Abe', 'Admin', 'sast', 4, { admin = true })

    -- a scratch export folder under missions/custom/ (tests/run.lua removes old test_* folders)
    X.exportDir = ('missions/custom/test_%s_%d/'):format(name, os.clock() * 1e6 // 1 + math.random(1, 1e6))
    Config.Builder.exportPath = X.exportDir

    -- ---- THE RESOURCE ------------------------------------------------------
    do
        local files = {}
        local p = io.popen(
            'cd ' .. H.root .. ' && find modules -name server.lua | sort && find blocks -name server.lua | sort')
        for file in p:lines() do files[#files + 1] = file end
        p:close()
        local realCreate = _G.CreateThread
        local deferred = {}
        _G.CreateThread = function(fn) deferred[#deferred + 1] = fn end
        _G.Citizen.CreateThread = _G.CreateThread
        for _, file in ipairs(files) do H.load(file) end
        _G.CreateThread = realCreate
        _G.Citizen.CreateThread = realCreate
        for _, fn in ipairs(deferred) do realCreate(fn) end
        X.files = files
    end
    H.step(0)
    for _ = 1, 3 do H.step(1000) end

    function X.adv(ms, stepMs)
        stepMs = stepMs or 250
        local target = H.clockMs + ms
        while H.clockMs < target do
            local before = H.clockMs
            H.step(stepMs)
            if (before // 1000) ~= (H.clockMs // 1000) then H.time = H.time + 1 end
        end
    end

    local reqN = 0
    -- a NUI action as src: ok, data|errKey
    function X.act(actionName, src, payload)
        reqN = reqN + 1
        local id = name .. reqN
        X.adv(1600)
        local mark = #H.events
        H.fire('crimson-police:' .. actionName, src, payload, id)
        for _ = 1, 40 do
            for i = #H.events, mark + 1, -1 do
                local e = H.events[i]
                if e.name == 'crimson-police:client:actionResult' and e.args[1] == id then
                    return e.args[2], e.args[3]
                end
            end
            X.adv(250)
        end
        return nil, 'no reply'
    end

    -- a callback as src: data | nil, errKey
    function X.cb(cbName, src, args)
        X.adv(1100)
        local res = H.callback('crimson-police:' .. cbName, src, args)
        if type(res) ~= 'table' then return nil, 'no reply' end
        if not res.ok then return nil, res.error end
        return res.data
    end

    -- in a server thread (the module waits for the database)
    function X.async(fn)
        local res
        CreateThread(function() res = table.pack(fn()) end)
        return table.unpack(res or {}, 1, res and res.n or 0)
    end

    local seq = 0
    function X.rid()
        seq = seq + 1
        return ('%08x-0000-4000-8000-%012x'):format(seq, 4242)
    end

    function X.count(sql, params)
        local r = H.sql(sql, params)[1]
        if not r then return 0 end
        for _, v in pairs(r) do return math.floor(tonumber(v) or 0) end
        return 0
    end

    function X.read(rel)
        local f = io.open(H.root .. rel, 'r')
        if not f then return nil end
        local s = f:read('a')
        f:close()
        return s
    end

    function X.write(rel, s)
        local f = assert(io.open(H.root .. rel, 'w'))
        f:write(s)
        f:close()
    end

    function X.exists(rel)
        local f = io.open(H.root .. rel, 'r')
        if f then f:close(); return true end
        return false
    end

    function X.audits(action)
        return H.sql(
            'SELECT actor, role, category, action, target, old_value, new_value, reason FROM cp_audit WHERE action = ? ORDER BY id',
            { action })
    end

    -- the builder's export folder is removed at the end of the spec
    function X.cleanup()
        os.execute(('rm -rf \'%s%s\''):format(H.root, X.exportDir))
    end

    return X
end
