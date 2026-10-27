-- Full admin control, Missions and Mission Builder (P2): editing a built-in mission in the Mission Builder (an
-- override under the same id), the admin-only override rows (S4), the shipped file as a baseline by value (S30),
-- Keep mine / Take the new original / Reset to original, Fold tweaks in, testing optional (O2) and the switches (O3).

local H = dofile('tests/harness.lua')
local X = dofile('tests/fixtures/admin_missions/boot.lua')(H, 'builtin_override')
local U = CP.U
local cjson = require('cjson')

local ID = 'gang_shootout'
local OVR_DIR = X.exportDir .. 'overrides/'
local SHIPPED = 'missions/builtin/' .. ID .. '.lua'
local shippedText = X.read(SHIPPED)
local shippedHash = U.hashHex(shippedText)
local function Plain(v) return cjson.decode(cjson.encode(U.serialize(v))) end

-- the supervisor (src 3) holds every Builder key, builderEditAny too: an override row is still not theirs
Config.Permissions.supervisor = U.copy(Config.Permissions.supervisor)
for _, k in ipairs({ 'builderEdit', 'builderEditAny', 'builderPublish', 'builderArchive', 'builderRollback', 'testRun' }) do
    Config.Permissions.supervisor[k] = true
end
-- testing switched on for supervisors: an admin still never needs a test (O2)
Config.Builder.requireTestToPublish = true

local function Row()
    return H.sql(
        [[SELECT id, status, overrides_builtin, base_hash, published_version, draft_version, created_by, file_path
        FROM cp_custom_missions WHERE id = ?]], { ID })[1]
end

local function Record(src) return X.cb('builder:get', src, { id = ID }) end

local function Save(src, def) return X.act('server:builder:save', src, { id = ID, definition = def }) end

-- ============================================================================
--                      1. OPEN A BUILT-IN IN THE BUILDER
-- ============================================================================

local shippedDef = CP.Missions.get(ID)
H.ok(shippedDef and shippedDef.source == 'builtin' and not shippedDef.overridden, 'the shipped mission plays at start')

do
    local ok, err = X.act('server:builder:editBuiltin', 3, { id = ID })
    H.ok(not ok and err == 'err.no_permission',
        'a supervisor with builderEditAny can\'t edit a built-in: ' .. tostring(err))
    local okC, errC = X.act('server:builder:editBuiltin', 5, { id = 'custom_nothing_here' })
    H.ok(not okC, 'an id that is not a built-in is refused: ' .. tostring(errC))

    local okE, data = X.act('server:builder:editBuiltin', 5, { id = ID })
    H.eq(okE, true, 'an admin opens the built-in in the Builder: ' .. tostring(data))
    local row = Row()
    H.ok(row and H.bit(row.overrides_builtin) == 1 and row.status == 'draft',
        'an override row (draft) under the same id')
    H.eq(row and row.base_hash, shippedHash, 'base_hash = the shipped file\'s hash')
    H.ok(X.exists(OVR_DIR .. ID .. '.base.lua'), 'a copy of the shipped file is kept to compare with later')
    local def = type(data) == 'table' and data.record and data.record.definition
    H.eq(def and def.label, 'Gang Shootout', 'the draft is the shipped mission')
    H.eq(def and def.objectives and #def.objectives, 3, 'with every objective')
    local waves = {}
    for i, n in ipairs(def and def.objectives[1].waves or {}) do waves[i] = math.floor(n) end
    H.eq(table.concat(waves, ','), '7,7,6', 'and the same waves')
    H.ok(type(data) == 'table' and data.record.can.publish == true and data.record.can.archive == false,
        'the admin may publish it; an override is never archived (Reset does that)')
    local again, d2 = X.act('server:builder:editBuiltin', 5, { id = ID })
    H.ok(again and d2.existing == true, 'opening it again returns the same override')
    H.eq(#X.audits('overrideEdit'), 1, 'audited once: overrideEdit')
end

-- ============================================================================
--                  2. OVERRIDE ROWS ARE FOR ADMINS ONLY (S4)
-- ============================================================================

do
    local list = X.cb('builder:list', 3)
    local seen = false
    for _, m in ipairs(list and list.missions or {}) do if m.id == ID then seen = true end end
    H.ok(list ~= nil and not seen, 'a supervisor\'s Builder list does not show the override row')
    for _, b in ipairs(list and list.builtins or {}) do
        if b.id == ID then H.ok(b.canEdit == nil and b.override == nil, 'nor any override detail on the built-in') end
    end
    local rec = Record(3)
    H.ok(rec and rec.source == 'builtin' and rec.readOnly == true and rec.override == nil,
        'builder:get for a supervisor: the built-in as it plays, read-only')
    local okS, eS = Save(3, rec and rec.definition or {})
    H.ok(not okS, 'a supervisor can\'t save the override: ' .. tostring(eS))
    local okP, eP = X.act('server:builder:publish', 3, { id = ID })
    H.ok(not okP, 'nor publish it: ' .. tostring(eP))
    local okA, eA = X.act('server:builder:archive', 3, { id = ID })
    H.ok(not okA, 'nor archive it: ' .. tostring(eA))
    local okR, eR = X.act('server:builder:rollback', 3, { id = ID, version = 1 })
    H.ok(not okR, 'nor roll it back: ' .. tostring(eR))
    local okD, eD = X.act('server:builder:discardDraft', 3, { id = ID })
    H.ok(not okD, 'nor discard its draft: ' .. tostring(eD))
    local okO, eO = X.act('server:builder:changeOwner', 5, { id = ID, citizenid = 'AMSUP003', reason = 'mine now' })
    H.ok(not okO and eO == 'err.override_owner',
        'change owner refuses an override, even for an admin: ' .. tostring(eO))
    local okX, eX = X.act('server:builder:changeOwner', 3, { id = ID, citizenid = 'AMSUP003', reason = 'mine now' })
    H.ok(not okX and eX == 'err.no_permission', 'and a supervisor never passes missionAdmin: ' .. tostring(eX))
    local okDel, eDel = X.act('server:builder:deleteMission', 5, { id = ID, reason = 'x', confirm = ID })
    H.ok(not okDel and eDel == 'err.override_delete', 'an override is not deleted: ' .. tostring(eDel))
end

-- ============================================================================
--              3. THE SHIPPED FILE AS A BASELINE, BY VALUE (S30)
-- ============================================================================

local draft
do
    local rec = Record(5)
    draft = Plain(rec.definition)
    H.ok(rec.overridesBuiltin == true and rec.override ~= nil, 'builder:get for an admin: the override with its view')
    H.ok(rec.live ~= nil, 'and the definition that plays now (View live)')
    H.ok(U.contains(draft.objectives[1].weapons, 'WEAPON_COMBATPISTOL'), 'the shipped file\'s weapons')

    local okV, v = X.act('server:builder:validate', 5, { id = ID, definition = draft })
    H.ok(okV and v and v.valid == true, 'the shipped definition passes as an override: ' .. cjson.encode(Plain(v)))

    local bad = Plain(draft)
    bad.objectives[1].weapons = { 'WEAPON_PISTOL', 'WEAPON_RPG' }
    local okW, w = X.act('server:builder:validate', 5, { id = ID, definition = bad })
    H.ok(okW and w and w.valid == false, 'a new weapon outside the allowed list is refused')

    local many = Plain(draft)
    many.objectives[1].waves = { 7, 7, 60 }
    local okM, m = X.act('server:builder:validate', 5, { id = ID, definition = many })
    H.ok(okM and m and m.valid == false, 'hostiles raised above the custom-mission cap are refused')

    local other = Plain(draft)
    other.type = 'patrol'
    local okT, t = X.act('server:builder:validate', 5, { id = ID, definition = other })
    H.ok(okT and t and t.valid == false, 'the type of a built-in stays its type')
end

-- ============================================================================
--                             4. PUBLISH UNTESTED
-- ============================================================================
-- THE OVERRIDE PLAYS UNDER THE SAME ID.

local before = CP.Missions.get(ID)
do
    local edit = Plain(draft)
    edit.label = 'Gang Shootout (edited)'
    edit.objectives[1].waves = { 6, 6, 6 }
    edit.payout = 99999
    edit.cashBase = 99999
    local okS, s = Save(5, edit)
    H.eq(okS, true, 'the admin saves the edit: ' .. tostring(s))
    local stored = H.sql('SELECT draft_definition FROM cp_custom_missions WHERE id = ?', { ID })[1]
    local text = stored and tostring(stored.draft_definition) or ''
    H.ok(not text:find('99999', 1, true), 'a payout field never reaches the draft')

    local okP, p = X.act('server:builder:publish', 5, { id = ID })
    H.eq(okP, true, 'an admin publishes it untested, with Builder.requireTestToPublish on: ' .. tostring(p))
    local a = X.audits('publishUntested')
    H.ok(#a == 1 and a[1].target == ID and a[1].category == 'builder', 'audited: publishUntested (builder webhook)')

    local def = CP.Missions.get(ID)
    H.ok(def and def.id == ID and def.source == 'builtin' and def.overridden == true,
        'the loader serves the override under the same id, still a built-in')
    H.eq(def and def.label, 'Gang Shootout (edited)', 'with the edited text')
    H.eq(def and def.shippedHash, shippedHash, 'and the shipped file\'s hash beside it')
    H.eq(before.label, 'Gang Shootout', 'a run already going keeps the definition it started with')
    H.eq(X.read(SHIPPED), shippedText, 'missions/builtin/ is never written')
    H.ok(X.exists(OVR_DIR .. ID .. '.lua'), 'the override file is in missions/custom/<export>/overrides/')
    local file = X.read(OVR_DIR .. ID .. '.lua') or ''
    H.ok(file:find('Gang Shootout (edited)', 1, true) ~= nil and not file:find('99999', 1, true),
        'the file has the edit and no payout field')

    -- what the Builder does not model is carried unchanged (in the normalised definition)
    local raw = CP.Missions.rawOf(ID)
    local shippedRaw = CP.Builder.shippedOf(ID).raw
    local sa, sb = raw.objectives[1].surrender or {}, shippedRaw.objectives[1].surrender or {}
    H.ok(sa.chance == sb.chance and sa.belowHealth == sb.belowHealth, 'surrender survives the round trip')
    H.eq(raw.objectives[1].blockTraffic, shippedRaw.objectives[1].blockTraffic, 'blockTraffic survives')
    H.eq(cjson.encode(Plain(raw.scaling)), cjson.encode(Plain(shippedRaw.scaling)), 'scaling survives')
    H.eq(raw.payout, nil, 'no payout field in the live definition')

    local pool = CP.Draw.pool('tactical', { 6 })
    local inPool = nil
    for _, d in ipairs(pool or {}) do if d.id == ID then inPool = d end end
    H.ok(inPool ~= nil and inPool.overridden == true, 'the draw pool has the override under the same id')

    local list = X.cb('builder:list', 5)
    local entry
    for _, b in ipairs(list and list.builtins or {}) do if b.id == ID then entry = b end end
    H.ok(
        entry and entry.canEdit == true and entry.override and entry.override.overridden == true
            and entry.override.changed == false,
        'the admin\'s list: Edited, the original not changed'
    )
end

-- ============================================================================
--  4b. THE LIST READS EACH SHIPPED FILE, PARSES IT ONLY WHEN IT CHANGED (Q9)
-- ============================================================================

do
    local realParse, realLoad = U.parseMissionFile, LoadResourceFile
    local parsed = 0
    U.parseMissionFile = function(...)
        parsed = parsed + 1
        return realParse(...)
    end
    local swap = {}   -- built-in id -> the text its file has now (false: the file is gone)
    LoadResourceFile = function(res, path)
        local id = type(path) == 'string' and path:match('^missions/builtin/([%w_]+)%.lua$') or nil
        if id and swap[id] ~= nil then return swap[id] or nil end
        return realLoad(res, path)
    end
    local builtins = {}
    for _, def in ipairs(CP.Missions.list()) do
        if def.source == 'builtin' then builtins[#builtins + 1] = def.id end
    end
    local function List()
        parsed = 0
        local list = X.cb('builder:list', 5)
        local entry, row
        for _, b in ipairs(list and list.builtins or {}) do if b.id == ID then entry = b end end
        for _, m in ipairs(list and list.missions or {}) do if m.id == ID then row = m end end
        return entry, parsed, row
    end
    local ok, err = pcall(function()
        -- every shipped file edited (a resource update): each is parsed once, the override's file only once too
        for _, id in ipairs(builtins) do swap[id] = '-- updated\n' .. X.read('missions/builtin/' .. id .. '.lua') end
        local e1, n1 = List()
        H.eq(n1, #builtins, 'an admin\'s list parses each shipped file once')
        H.ok(e1 and e1.override.shippedHash == U.hashHex(swap[ID]) and e1.override.changed == true,
            'the edited file\'s hash: the original changed')
        local e2, n2, r2 = List()
        H.eq(n2, 0, 'the next list parses none: no file changed')
        H.ok(e2 and e2.override.shippedHash == U.hashHex(swap[ID]), 'and gives the same hash')
        -- the list's override view is the one builder:get builds from the full row
        local rec = Record(5)
        local okR, why = true, nil
        for k, v in pairs(rec and rec.override or { missing = true }) do
            if cjson.encode(Plain(v)) ~= cjson.encode(Plain(e2.override[k])) then okR, why = false, k end
            if cjson.encode(Plain(v)) ~= cjson.encode(Plain(r2 and r2.override and r2.override[k])) then
                okR, why = false, 'row ' .. k
            end
        end
        H.ok(okR and r2 ~= nil, 'the list shows the override as builder:get does: ' .. tostring(why))
        -- one file edited again: only that one is parsed, and its new hash shows at once
        swap[ID] = '-- updated twice\n' .. shippedText
        local e3, n3 = List()
        H.eq(n3, 1, 'only the edited file is parsed')
        H.ok(e3 and e3.override.shippedHash == U.hashHex(swap[ID]) and e3.override.changed == true, 'with its new hash')
        swap[ID] = nil
        local e4, n4 = List()
        H.eq(n4, 1, 'the file as shipped again: parsed once')
        H.ok(e4 and e4.override.shippedHash == shippedHash and e4.override.changed == false, 'not changed again')
        -- missing, broken or another mission: no hash, as before, and still none from the memory
        swap[ID] = false
        H.eq(CP.Builder.shippedHash(ID), nil, 'a missing shipped file has no hash')
        swap[ID] = 'return { id = '
        H.eq(CP.Builder.shippedHash(ID), nil, 'a broken file has no hash')
        parsed = 0
        H.eq(CP.Builder.shippedHash(ID), nil, 'nor the second time')
        H.eq(parsed, 0, 'which is not parsed again')
        swap[ID] = (shippedText:gsub('\'gang_shootout\'', '\'gang_shootout_two\'', 1))
        H.eq(CP.Builder.shippedHash(ID), nil, 'a file of another mission has no hash')
        H.eq(CP.Builder.shippedHash('../gang_shootout'), nil, 'nor a path')
        swap[ID] = nil
        H.eq(CP.Builder.shippedHash(ID), shippedHash, 'the shipped file\'s hash again')
    end)
    U.parseMissionFile, LoadResourceFile = realParse, realLoad
    H.ok(ok, 'shipped files counted: ' .. tostring(err))
end

-- ============================================================================
--            5. SWITCHES AND QUICK EDIT APPLY TO THE OVERRIDE (O3)
-- ============================================================================

do
    local okM, eM = X.act('server:admin:setMissionEnabled', 5, { missionId = ID, enabled = false })
    H.eq(okM, true, 'the mission switch takes the overridden id: ' .. tostring(eM))
    local pool = CP.Draw.pool('tactical', { 6 })
    local inPool = false
    for _, d in ipairs(pool or {}) do if d.id == ID then inPool = true end end
    H.ok(not inPool, 'switched off: not drawn')
    X.act('server:admin:setMissionEnabled', 5, { missionId = ID, enabled = true })

    local okT, t = X.act('server:admin:setMissionTweak', 5, { missionId = ID, tweak = { cooldown = 900 } })
    H.eq(okT, true, 'Quick edit on an edited built-in: ' .. tostring(t))
    X.adv(2000)   -- Settings reloads the missions a second after a burst of changes
    local def = CP.Missions.get(ID)
    H.ok(def.cooldown == 900 and def.overridden == true, 'MissionTweaks still apply on top of the override')

    local okF, f = X.act('server:builder:foldTweaks', 5, { id = ID, reason = 'make it part of the file' })
    H.eq(okF, true, 'Fold tweaks in: ' .. tostring(f))
    X.adv(2000)
    def = CP.Missions.get(ID)
    H.ok(def.cooldown == 900 and def.overrideVersion == 2, 'the cooldown is now in the override (v2)')
    local tw = type(Config.MissionTweaks) == 'table' and Config.MissionTweaks[ID] or nil
    H.ok(tw == nil or tw.cooldown == nil, 'and the tweak is cleared in Settings')
    H.eq(#X.audits('overrideFoldTweaks'), 1, 'audited: overrideFoldTweaks')
end

-- ============================================================================
--                     6. ROLLBACK TO A KEPT VERSION (A11)
-- ============================================================================

do
    local diff, err = X.cb('builder:versionDiff', 5, { id = ID, version = 1 })
    H.ok(diff and diff.version == 1 and diff.current == 2 and type(diff.lines) == 'table' and #diff.lines > 0,
        'a short diff of v1 against v2: ' .. tostring(err))
    local okR, r = X.act('server:builder:rollback', 5, { id = ID, version = 1 })
    H.eq(okR, true, 'roll the override back to v1: ' .. tostring(r))
    H.eq(CP.Missions.get(ID).cooldown, shippedDef.cooldown, 'v1 plays again (as v3)')
end

-- ============================================================================
--                           7. THE ORIGINAL CHANGED
-- ============================================================================
-- KEEP MINE / TAKE THE NEW ORIGINAL.

local function ChangeTheOriginal()
    -- a resource update: the kept base copy is an older original than what ships now
    X.write(OVR_DIR .. ID .. '.base.lua', (shippedText:gsub('cooldown     = 1200', 'cooldown     = 1500')))
    H.sql('UPDATE cp_custom_missions SET base_hash = ? WHERE id = ?', { U.hashHex('an older original'), ID })
end

do
    ChangeTheOriginal()
    local list = X.cb('builder:list', 5)
    local entry
    for _, b in ipairs(list and list.builtins or {}) do if b.id == ID then entry = b end end
    H.ok(entry and entry.override and entry.override.changed == true, 'the original changed since the edit: changed')
    local diff = X.cb('admin:builtinDiff', 5, { id = ID })
    H.ok(diff and diff.changed == true and type(diff.original) == 'table' and #diff.original > 0,
        'Compare lists what the update changed in the original')
    H.ok(diff and type(diff.yours) == 'table', 'and the override against the new original')
    local okK0, eK0 = X.act('server:builder:keepOverride', 5, { id = ID })
    H.ok(not okK0, 'Keep mine needs a reason: ' .. tostring(eK0))
    local okK, k = X.act('server:builder:keepOverride', 5, { id = ID, reason = 'ours is better' })
    H.ok(okK and k.changed == false, 'Keep mine: ' .. tostring(k))
    H.eq(Row().base_hash, shippedHash, 'base_hash is the new shipped hash')
    H.eq(#X.audits('overrideKeep'), 1, 'audited: overrideKeep')
    H.ok(CP.Missions.get(ID).overridden == true, 'the override keeps playing')
end

-- Compare lists only what someone changed: an edit saved from the Builder comes back through the NUI's JSON, where
-- the shipped radius = 80.0 and blockTraffic = 120.0 arrive as 80 and 120.
do
    local function Paths(lines)
        local out = {}
        for _, l in ipairs(type(lines) == 'table' and lines or {}) do out[#out + 1] = l.path end
        return table.concat(out, ', ')
    end
    local edit = H.viaNui(Record(5).definition)
    H.eq(math.type(edit.objectives[1].blockTraffic), 'integer', 'through the NUI the shipped 120.0 is the integer 120')
    edit.objectives[1].waves = { 7, 7, 6 }   -- the shipped waves again (the draft of section 5 has 6, 6, 6)
    edit.label = 'Gang Shootout (renamed)'
    H.eq(Save(5, edit), true, 'the renamed draft is saved from the Builder')
    ChangeTheOriginal()
    local diff = X.cb('admin:builtinDiff', 5, { id = ID })
    H.eq(Paths(diff and diff.original), 'cooldown', 'Compare: the update changed only the cooldown')
    H.eq(Paths(diff and diff.yours), 'label', 'Compare: your edit against the new original is only the name')
    local okK = X.act('server:builder:keepOverride', 5, { id = ID, reason = 'keep the new name' })
    H.eq(okK, true, 'Keep mine again')
end

do
    ChangeTheOriginal()
    local okN, eN = X.act('server:builder:resetBuiltin', 5, { id = ID, reason = 'take the update' })
    H.ok(not okN, 'Take the new original asks for the mission id: ' .. tostring(eN))
    local okT, t = X.act('server:builder:resetBuiltin', 5,
        { id = ID, reason = 'take the update', confirm = ID, takeNew = true })
    H.eq(okT, true, 'Take the new original: ' .. tostring(t))
    local def = CP.Missions.get(ID)
    H.ok(def and not def.overridden and def.label == 'Gang Shootout', 'the shipped mission plays again')
    H.eq(Row().status, 'archived', 'the override row is put away, not erased')
    H.ok(X.exists(OVR_DIR .. 'archived/' .. ID .. '.lua') and not X.exists(OVR_DIR .. ID .. '.lua'),
        'its file is moved to overrides/archived/')
    local a = X.audits('overrideReset')
    H.ok(#a == 1 and a[1].new_value == 'new original', 'audited: overrideReset (new original)')
end

-- ============================================================================
--                8. EDIT AGAIN, RESET TO ORIGINAL, SWITCHED OFF
-- ============================================================================

do
    local okE, e = X.act('server:builder:editBuiltin', 5, { id = ID })
    H.ok(okE and Row().status == 'draft',
        'editing again starts a new override draft from the shipped file: ' .. tostring(e))
    local rec = Record(5)
    local edit = Plain(rec.definition)
    edit.label = 'Gang Shootout (second)'
    Save(5, edit)
    local okP = X.act('server:builder:publish', 5, { id = ID })
    H.ok(okP and CP.Missions.get(ID).label == 'Gang Shootout (second)', 'published again')
    local okR, r = X.act('server:builder:resetBuiltin', 5, { id = ID, reason = 'back to stock', confirm = ID })
    H.eq(okR, true, 'Reset to original: ' .. tostring(r))
    H.eq(CP.Missions.get(ID).label, 'Gang Shootout', 'the shipped definition plays')

    X.act('server:builder:editBuiltin', 5, { id = ID })
    Save(5, edit)
    X.act('server:builder:publish', 5, { id = ID })
    H.ok(CP.Missions.get(ID).overridden == true, 'an override plays')
    Config.AdminControl.editBuiltins = false
    local okO, eO = X.act('server:builder:editBuiltin', 5, { id = ID })
    H.ok(not okO and eO == 'err.edit_builtins_off', 'editBuiltins off: refused for admins too: ' .. tostring(eO))
    local recOff = Record(5)
    H.ok(recOff == nil or recOff.source == 'builtin', 'builder:get no longer opens the override')
    CP.Missions.loadAll()
    H.ok(not CP.Missions.get(ID).overridden, 'after a reload the shipped mission plays')
    Config.AdminControl.editBuiltins = true
    CP.Missions.loadAll()
    H.ok(CP.Missions.get(ID).overridden == true, 'switched back on: the override plays again')

    os.remove(H.root .. OVR_DIR .. ID .. '.lua')
    CP.Missions.loadAll()
    H.ok(CP.Missions.get(ID).overridden == true and X.exists(OVR_DIR .. ID .. '.lua'),
        'a deleted override file is written again from the row')

    X.act('server:builder:resetBuiltin', 5, { id = ID, reason = 'clean up', confirm = ID })
    H.ok(not CP.Missions.get(ID).overridden, 'reset again')
end

-- ============================================================================
--                      9. TESTING IS NEVER REQUIRED (O2)
-- ============================================================================

do
    local file = X.read('config/config.lua') or ''
    H.ok(file:find('requireTestToPublish%s*=%s*false') ~= nil, 'config.lua ships Builder.requireTestToPublish = false')
    local list = X.cb('builder:list', 5)
    local nag = false
    for _, m in ipairs(list and list.missions or {}) do if m.needsTest then nag = true end end
    H.ok(not nag, 'an admin is never told a mission needs a test')
end

X.cleanup()
return H
