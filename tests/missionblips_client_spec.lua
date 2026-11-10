-- CP.MissionBlips (modules/missionblips/client.lua): the extra mission blips on the minimap and the big map. Blips
-- change only when a list comes in; a car or partner follows its entity once it streams in; every blip goes at the
-- run's end, a list for another run, logout and resource stop.

local H = dofile('tests/harness.lua')
H.boot({ side = 'client' })

-- ============================================================================
--                               THE GAME: BLIPS
-- ============================================================================

local BL = { all = {}, n = 0, name = nil, calls = 0 }
local streamed = {}             -- [netId] = entity
local ents = {}                 -- [entity] = true
local players = {}              -- [server id] = ped

local function NewBlip(kind, fields)
    BL.n = BL.n + 1
    BL.calls = BL.calls + 1
    local b = { id = BL.n, kind = kind, live = true }
    for k, v in pairs(fields) do b[k] = v end
    BL.all[BL.n] = b
    return BL.n
end
local function Setter(field)
    return function(id, v)
        BL.calls = BL.calls + 1
        local b = BL.all[id]
        if b then b[field] = v end
    end
end
_G.AddBlipForCoord = function(x, y, z) return NewBlip('coord', { x = x, y = y, z = z }) end
_G.AddBlipForEntity = function(e) return NewBlip('entity', { ent = e }) end
_G.DoesBlipExist = function(id) return BL.all[id] ~= nil and BL.all[id].live end
_G.RemoveBlip = function(id)
    BL.calls = BL.calls + 1
    if BL.all[id] then BL.all[id].live = false end
end
_G.SetBlipCoords = function(id, x, y, z)
    BL.calls = BL.calls + 1
    local b = BL.all[id]
    if b then b.x, b.y, b.z = x, y, z end
end
_G.SetBlipSprite = Setter('sprite')
_G.SetBlipColour = Setter('colour')
_G.SetBlipScale = Setter('scale')
_G.SetBlipAsShortRange = Setter('shortRange')
_G.SetBlipDisplay = Setter('display')
_G.BeginTextCommandSetBlipName = function(kind) BL.name = { kind = kind } end
_G.AddTextComponentSubstringPlayerName = function(text) BL.name.text = text end
_G.EndTextCommandSetBlipName = function(id)
    local b = BL.all[id]
    if b and BL.name then b.name = BL.name.text end
end
_G.NetworkDoesNetworkIdExist = function(n) return streamed[n] ~= nil end
_G.NetworkGetEntityFromNetworkId = function(n) return streamed[n] or 0 end
_G.DoesEntityExist = function(e) return ents[e] == true end
_G.GetPlayerFromServerId = function(s) return players[s] and s or -1 end
_G.GetPlayerPed = function(p) return players[p] or 0 end

local function Live()
    local out = {}
    for _, b in pairs(BL.all) do if b.live then out[#out + 1] = b end end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

local current = { id = 'run-a' }
CP.Runs = {
    current = function() return current end,
}

H.load('modules/missionblips/client.lua')
local MB = CP.MissionBlips
local EVENT = 'crimson-police:client:missionBlips'

local function Send(runId, items) H.fire(EVENT, nil, { runId = runId, items = items }) end

-- ============================================================================
--                        A LIST COMES IN: BLIPS, STYLED
-- ============================================================================

Config.MissionBlips.parts.parkedCar.label = ''
Config.MissionBlips.parts.prisonerDrop.label = 'Hand-over'
Send('run-a', {
    { k = 'e11', p = 'parkedCar', n = 11, x = 100.0, y = 100.0, z = 30.0 },
    { k = 'd1', p = 'prisonerDrop', x = 50.0, y = 60.0, z = 30.0 },
})
local live = Live()
H.eq(#live, 2, 'two blips')
H.eq(live[1].kind, 'coord', 'a car not streamed in sits where the server saw it')
H.eq(live[1].sprite, Config.MissionBlips.parts.parkedCar.sprite, 'the part\'s sprite')
H.eq(live[1].colour, Config.MissionBlips.parts.parkedCar.colour, 'its colour')
H.eq(live[1].shortRange, true, 'parked cars ship short range')
H.eq(live[1].display, 2, 'on the minimap and the big map')
H.eq(live[1].name, 'missionblips.part.parkedCar', 'the built-in name when label is empty')
H.eq(live[2].name, 'Hand-over', 'the admin\'s label')
H.eq(live[2].shortRange, false, 'the drop-off shows at the minimap\'s edge however far')

-- the same list again: no native at all
BL.calls = 0
Send('run-a', {
    { k = 'e11', p = 'parkedCar', n = 11, x = 100.0, y = 100.0, z = 30.0 },
    { k = 'd1', p = 'prisonerDrop', x = 50.0, y = 60.0, z = 30.0 },
})
H.eq(BL.calls, 0, 'an unchanged list touches no blip')

-- a moved car not streamed in moves; nothing is made again
Send('run-a', {
    { k = 'e11', p = 'parkedCar', n = 11, x = 125.0, y = 100.0, z = 30.0 },
    { k = 'd1', p = 'prisonerDrop', x = 50.0, y = 60.0, z = 30.0 },
})
H.eq(#Live(), 2, 'still two blips')
H.eq(Live()[1].x, 125.0, 'moved to the new position')

-- ============================================================================
--                    FOLLOWING THE ENTITY ONCE STREAMED IN
-- ============================================================================

streamed[11], ents[5011] = 5011, true
H.step(1000)
local car = Live()[2]
H.eq(car.kind, 'entity', 'once streamed in the car\'s blip follows the entity')
H.eq(car.ent, 5011, 'on that entity')
ents[5011], streamed[11] = nil, nil
H.step(1000)
H.eq(Live()[2].kind, 'coord', 'entity gone again: back where the server saw it')

-- a partner follows his ped
players[4], ents[400] = 400, true
Send('run-a', {
    { k = 'e11', p = 'parkedCar', n = 11, x = 125.0, y = 100.0, z = 30.0 },
    { k = 'd1', p = 'prisonerDrop', x = 50.0, y = 60.0, z = 30.0 },
    { k = 'p4', p = 'partner', s = 4, x = 0.0, y = 0.0, z = 30.0 },
})
local partner = nil
for _, b in ipairs(Live()) do if b.ent == 400 then partner = b end end
H.ok(partner ~= nil and partner.colour == 3, 'a partner near you follows his ped, police blue')

-- a part removed from the list: only its blip goes
Send('run-a', { { k = 'd1', p = 'prisonerDrop', x = 50.0, y = 60.0, z = 30.0 } })
H.eq(#Live(), 1, 'only the drop-off is left')

-- ============================================================================
--                                   CLEAN-UP
-- ============================================================================

Send('run-a', {})
H.eq(#Live(), 0, 'an empty list (run end) takes every blip off')

Send('run-a', { { k = 'd1', p = 'prisonerDrop', x = 50.0, y = 60.0, z = 30.0 } })
Send('run-b', { { k = 'd1', p = 'prisonerDrop', x = 50.0, y = 60.0, z = 30.0 } })
H.eq(#Live(), 1, 'a list for a run this officer is not on is ignored')
current = nil
Send('run-a', {})
H.eq(#Live(), 0, 'the clear still comes through after the run ended here')
current = { id = 'run-a' }

Send('run-a', { { k = 'd1', p = 'prisonerDrop', x = 50.0, y = 60.0, z = 30.0 } })
MB.clear()
H.eq(#Live(), 0, 'the run\'s clean-up (modules/runs) takes them off')

Send('run-a', { { k = 'd1', p = 'prisonerDrop', x = 50.0, y = 60.0, z = 30.0 } })
H.fire('onResourceStop', nil, 'Crimson-Police')
H.eq(#Live(), 0, 'resource stop takes them off')

-- the runs module calls the clean-up at every run end
local src = io.open('Crimson-Police/modules/runs/client.lua'):read('a')
H.ok(src:find('CP.MissionBlips.clear', 1, true) ~= nil, 'modules/runs/client.lua clears the mission blips at run end')

return H
