-- The translation scanner (tools/check_i18n.py, the gate's lint-i18n step) and the plural helpers it points to:
-- English joined to a translated text, a plural built in place and a count string without plural forms are found;
-- whole sentences, ' · ' joins and tn() / CP.Ln() pass; the shipped code has no hit outside tools/i18n_baseline.txt.

-- The translation scanner (tools/check_i18n.py, the gate's lint-i18n step) and the plural helpers it points to:
-- English joined to a translated text, a plural built in place and a count string without plural forms are found;
-- whole sentences, ' · ' joins and tn() / CP.Ln() pass; the shipped code has no hit outside tools/i18n_baseline.txt.
-- CP.Ln picks key_one / key_other and falls back to the plain key. docs/dev/TESTING.md "Translation scanner".

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })

local function Shell(cmd)
    local p = io.popen(cmd .. ' 2>&1')
    local out = p:read('a')
    local ok = p:close()
    return ok, out
end

local function Write(path, text)
    local f = assert(io.open(path, 'w'))
    f:write(text)
    f:close()
end

local dir = os.tmpname()
os.remove(dir)
os.execute(('mkdir -p \'%s\''):format(dir))

-- ============================================================================
--                           1. THE RULES, ON SAMPLES
-- ============================================================================

Write(dir .. '/bad.tsx', table.concat({
    'const a = t(\'unit.ui.led_by\') + \' and more\';',
    'const b = \'Total: \' + t(\'admin.audit.total\', { n });',
    'const c = n === 1 ? t(\'x.one\') : t(\'x.many\', { n });',
    'const d = 1 === count ? t(\'x.one\') : t(\'x.many\');',
    '',
}, '\n'))
Write(dir .. '/good.tsx', table.concat({
    'const a = t(\'unit.ui.led_by\') + \' · \' + t(\'unit.ui.x\');',
    'const b = tn(\'admin.audit.total\', n);',
    '// const c = n === 1 ? t(\'x.one\') : t(\'x.many\');',
    'const d = n === 1 ? \'one\' : \'many\';',
    '',
}, '\n'))
Write(dir .. '/bad.lua', table.concat({
    'local a = CP.L(\'x.title\') .. \' minutes left\'',
    'local b = \'You got \' .. CP.L(\'x.reward\')',
    'local c = count > 1 and CP.L(\'x.many\', { n = count }) or CP.L(\'x.one\')',
    '',
}, '\n'))
Write(dir .. '/good.lua', table.concat({
    'local a = CP.L(\'x.title\') .. \' \' .. CP.L(\'x.more\')',
    'local b = CP.Ln(\'x.count\', count)',
    '-- local c = count > 1 and CP.L(\'x.many\') or CP.L(\'x.one\')',
    'CP.log(TAG, \'%d desks\', n)',
    '',
}, '\n'))
Write(dir .. '/part.json', [[{
  "x.bad": "{n} entries",
  "x.good_one": "{n} entry",
  "x.good_other": "{n} entries",
  "x.paired": "{n} lines",
  "x.paired_one": "{n} line",
  "x.plain": "Entries"
}
]])

local SCAN = 'timeout 120 python3 tools/check_i18n.py --files '
local ok, out = Shell(SCAN .. ('\'%s/bad.tsx\' \'%s/bad.lua\' \'%s/part.json\''):format(dir, dir, dir))
H.eq(ok, nil, 'the bad samples fail the scan')
local function Has(rule, file, line)
    return out:find(('%s [^\n]*%s:%d:'):format(rule, file:gsub('%.', '%%.'), line)) ~= nil
end
H.ok(Has('J', 'bad.tsx', 1), 'J: t(...) + English (web): ' .. out)
H.ok(Has('J', 'bad.tsx', 2), 'J: English + t(...) (web)')
H.ok(Has('P', 'bad.tsx', 3), 'P: n === 1 ? t(...) : t(...) (web)')
H.ok(Has('P', 'bad.tsx', 4), 'P: 1 === n ? t(...) (web)')
H.ok(Has('J', 'bad.lua', 1), 'J: CP.L(...) .. English (Lua)')
H.ok(Has('J', 'bad.lua', 2), 'J: English .. CP.L(...) (Lua)')
H.ok(Has('P', 'bad.lua', 3), 'P: count > 1 and CP.L(...) (Lua)')
H.ok(out:find('S [^\n]*part%.json:0: x%.bad\n') ~= nil, 'S: a count string with no _one / _other forms')
H.ok(
    out:find('x.good', 1, true) == nil and out:find('x.paired', 1, true) == nil and out:find('x.plain', 1, true) == nil,
    'S: keys with forms, or without a count, pass')
H.ok(out:find('TOTAL hits: 8', 1, true) ~= nil, 'eight hits in all: ' .. out:sub(-80))

ok, out = Shell(SCAN .. ('\'%s/good.tsx\' \'%s/good.lua\''):format(dir, dir))
H.ok(ok == true and out:find('TOTAL hits: 0', 1, true) ~= nil,
    'whole sentences, \' · \' joins, comments and tn() / CP.Ln() pass: ' .. out)

-- ============================================================================
--                    2. THE SHIPPED CODE, WITH ITS BASELINE
-- ============================================================================

ok, out = Shell('timeout 120 python3 tools/check_i18n.py')
H.ok(ok == true and out:find(' 0 new, 0 stale', 1, true) ~= nil,
    'the resource has no hit outside tools/i18n_baseline.txt: ' .. out:sub(-600))

os.execute(('rm -rf \'%s\''):format(dir))

-- ============================================================================
--                                   3. CP.Ln
-- ============================================================================

H.ok(type(CP.Ln) == 'function', 'CP.Ln exists')
if type(CP.Ln) == 'function' then
    H.eq(CP.Ln('admin.audit.total', 1), '1 entry', 'one: the _one form')
    H.eq(CP.Ln('admin.audit.total', 3), '3 entries', 'other: the _other form')
    H.eq(CP.Ln('admin.audit.total', 0), '0 entries', 'zero is "other" in English')
    H.eq(CP.Ln('admin.audit.total', 2, { n = '2,000' }), '2,000 entries', 'vars may give {n} (already formatted)')
    H.eq(CP.Ln('access.health.all_ok', 1), CP.L('access.health.all_ok'), 'a key without forms keeps its own text')
    H.eq(CP.Ln('no.such.key', 2), 'no.such.key', 'an unknown key shows itself')
    Config.Labels = { ['admin.audit.total_one'] = 'One row' }
    H.eq(CP.Ln('admin.audit.total', 1), 'One row', 'a Settings -> Names rename of a form wins')
    Config.Labels = nil
end

return H
