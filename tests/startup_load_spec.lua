-- The script files do no work at load that can wait: the locale and the collation maps are built on first use.

-- A real FXServer restart showed a ~200 ms server hitch while the resource's script files load (their main chunks,
-- before any thread runs). Measured with lua5.4 and this harness, most of it is compiling the files; of the work the
-- main chunks themselves did, shared/locale.lua decoded locales/en.json and modules/system/memsql.lua built its two
-- utf8mb4_general_ci maps (CI_MB, LOWER_MB) from their runs. No main chunk reads either: the locale is first read by
-- the mission loader's thread, the maps by the first non-ASCII text the engine compares. Both are now built the first
-- time they are needed, with the same result. Counted, not timed: the reads of locales/*.json and the utf8.char
-- calls (the maps' only use of it) while the file loads.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })

-- ============================================================================
--                           THE LOCALE ON FIRST USE
-- ============================================================================

do
    local realRead = LoadResourceFile
    local reads = 0
    LoadResourceFile = function(res, path)
        if type(path) == 'string' and path:match('^locales/') then reads = reads + 1 end
        return realRead(res, path)
    end
    H.load('shared/locale.lua')
    H.eq(reads, 0, 'locale: loading shared/locale.lua reads no locale file')
    H.eq(CP.L('payments.resolve.mark_paid'), 'Mark paid', 'locale: the first text comes from locales/en.json')
    H.eq(reads, 1, 'locale: it is read once, on first use')
    H.eq(CP.Ln('admin.audit.total', 1), CP.L('admin.audit.total_one', { n = 1 }), 'locale: plural forms work')
    H.ok(CP.Locale.has('payments.resolve.again_withdrawn') and CP.Locale.inFile('payments.resolve.again_step'),
        'locale: has and inFile read the same texts')
    local n = 0
    for _ in pairs(CP.Locale.all()) do n = n + 1 end
    H.ok(n > 1000, 'locale: all() holds every text (' .. n .. ')')
    H.eq(CP.L('no.such.key'), 'no.such.key', 'locale: an unknown key is shown as it is')
    H.eq(reads, 1, 'locale: never read again')
    LoadResourceFile = realRead
end

-- ============================================================================
--                       THE COLLATION MAPS ON FIRST USE
-- ============================================================================

do
    local saved = CP.Storage and CP.Storage.MemSQL
    local realChar = utf8.char
    local calls = 0
    rawset(utf8, 'char', function(...)
        calls = calls + 1
        return realChar(...)
    end)
    H.load('modules/system/memsql.lua')
    local M = CP.Storage.MemSQL
    H.eq(calls, 0, 'collation: loading modules/system/memsql.lua builds no map')
    H.eq(M.ciKey('abc'), 'ABC', 'collation: ASCII needs no map')
    H.eq(calls, 0, 'collation: ...and builds none')
    H.eq(M.ciKey('Émile'), 'EMILE', 'collation: utf8mb4_general_ci folds É to E')
    local afterCi = calls
    H.ok(afterCi > 0, 'collation: the first non-ASCII text builds the map')
    H.eq(M.ciKey('ñandú'), 'NANDU', 'collation: and keeps it')
    H.eq(calls, afterCi, 'collation: built once')
    H.eq(M.lowerText('ÉCOLE Ñ'), 'école ñ', 'collation: LOWER() over non-ASCII')
    local afterLower = calls
    H.ok(afterLower > afterCi, 'collation: LOWER() builds its own map on first use')
    H.eq(M.lowerText('ÀÖ'), 'àö', 'collation: and keeps it')
    H.eq(calls, afterLower, 'collation: LOWER()\'s map built once')
    rawset(utf8, 'char', realChar)
    if CP.Storage then CP.Storage.MemSQL = saved end
end

return H
