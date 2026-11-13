-- The time limits of the test tools: tests/run.lua stops a spec that hangs (CP_SPEC_TIMEOUT) and reports

-- The time limits of the test tools: tests/run.lua stops a spec that hangs (CP_SPEC_TIMEOUT) and reports
-- it as TIMEOUT <spec>, and tools/check_all.sh stops a step that hangs (CP_STEP_TIMEOUT) and says TIMEOUT in its
-- summary. Both run here as nested runs on this spec itself, which hangs on purpose in its nested child
-- (CP_CHECK_TOOLS_HANG=1). docs/dev/TESTING.md "Time limits".

-- the nested child: a loop that never yields, the kind of hang the limit is for
if os.getenv('CP_CHECK_TOOLS_HANG') == '1' then
    while true do end
end

local H = dofile('tests/harness.lua')

local function Shell(cmd)
    local p = io.popen(cmd .. ' 2>&1')
    local out = p:read('a')
    local ok, _, code = p:close()
    return ok, out, code
end
local function Clock()
    local p = io.popen('date +%s%N')
    local ns = tonumber(p:read('a'):match('%d+'))
    p:close()
    return (ns or 0) / 1e9
end

-- a nested run starts clean: its own run database, saves folder and storage mode, never the outer run's
local CLEAN_ENV = 'env -u CP_TEST_DB -u CP_TEST_SAVES -u CP_TEST_STORAGE -u CP_SHADOW_REPORT -u CP_TEST_JOBS'

-- ============================================================================
--                               1. tests/run.lua
-- ============================================================================
-- A spec over CP_SPEC_TIMEOUT is stopped, named, counted as crashed.
-- The outer `timeout 90` only guards this spec: without the limit in tests/run.lua the nested run would hang until
-- it, and the checks below fail instead of this spec hanging.

do
    local t0 = Clock()
    local ok, out = Shell((
        '%s CP_CHECK_TOOLS_HANG=1 CP_SPEC_TIMEOUT=2 timeout --kill-after=5 90 lua5.4 tests/run.lua '
        .. '--storage=files --jobs=1 check_tools_spec'
    ):format(CLEAN_ENV))
    local secs = Clock() - t0
    H.ok(out:find('✗ TIMEOUT tests/check_tools_spec.lua: no result within 2 s', 1, true) ~= nil,
        'run.lua names the spec that went over CP_SPEC_TIMEOUT: ' .. out:sub(-400))
    H.ok(out:find('1 specs, 0 assertions passed, 0 failed, 1 crashed', 1, true) ~= nil,
        'and counts it as crashed: ' .. out:sub(-200))
    H.eq(ok, nil, 'the run fails')
    H.ok(secs < 60, ('the hang ends at the limit (2 s + the run database), not at the guard: %.1f s'):format(secs))
end

-- CP_SPEC_TIMEOUT=0 turns the limit off: the command is the plain child again (checked on a spec that ends at once)
do
    local ok, out = Shell(
        ('%s CP_SPEC_TIMEOUT=0 timeout 120 lua5.4 tests/run.lua --storage=files --jobs=1 ' .. 'globals_lint'):format(
            CLEAN_ENV))
    H.ok(ok and out:find(', 0 failed, 0 crashed', 1, true) ~= nil,
        'CP_SPEC_TIMEOUT=0: no limit, the spec passes: ' .. out:sub(-200))
end

-- ============================================================================
--                            2. tools/check_all.sh
-- ============================================================================
-- A step over CP_STEP_TIMEOUT is stopped and the summary says TIMEOUT.
-- lint-lua runs luacheck over every Lua file (about 20 s), so a limit of 1 s stops it. Without luacheck the step
-- fails at once with "missing command", which is no test of the limit: skipped then.

do
    local hasLuacheck = Shell('command -v luacheck')
    if not hasLuacheck then
        print('SKIP check_tools: tools/check_all.sh step limit (no luacheck: apt-get install lua-check)')
    else
        local logs = os.tmpname()
        os.remove(logs)
        local ok, out = Shell(
            ('%s CHECK_LOGS=\'%s\' CP_STEP_TIMEOUT=1 timeout 60 bash tools/check_all.sh lint-lua'):format(CLEAN_ENV,
                logs))
        H.ok(out:find('FAIL  lint%-lua +[%d.]+s  TIMEOUT after 1 s %(CP_STEP_TIMEOUT%)') ~= nil,
            'check_all.sh says TIMEOUT for the step over its limit: ' .. out:sub(-300))
        H.eq(ok, nil, 'and fails')
        local _, left = Shell('pgrep -f "[l]uacheck --codes --no-color --formatter plain" || true')
        H.eq(left:gsub('%s+', ''), '', 'nothing of the stopped step is left running')
        os.execute(('rm -rf \'%s\''):format(logs))
    end
end

-- the opt-in steps (clickthrough, race-all, db-check, lua-coverage) come last, after the steps every run has
do
    local ok, out = Shell(('%s timeout 60 bash tools/check_all.sh --list'):format(CLEAN_ENV))
    H.ok(ok and out:find('\nbuild\nrelease\nclickthrough\nrace%-all\ndb%-check\nlua%-coverage\n$') ~= nil,
        'the opt-in steps are listed last: ' .. out)
end

-- ============================================================================
--                              3. tools/mutate.py
-- ============================================================================
-- H13: the mutation tool works on a temporary copy (the working tree stays as it is), never mutates a comment or a
-- string, kills a mutant the specs catch and reports one they miss (exit 1).

do
    local function Md5(path)
        local _, out = Shell(('md5sum \'%s\''):format(path))
        return out:match('^(%x+)')
    end
    local file = 'Crimson-Police/modules/access/permissions.lua'
    local before = Md5(file)
    local py = os.tmpname()
    local f = io.open(py, 'w')
    f:write([=[
import sys
sys.path.insert(0, 'tools')
import mutate
print(repr(mutate.code_mask(['if a == b then -- x == y', "s = 'p == q' .. [[r == t]] .. n"])))
]=])
    f:close()
    local okM, mask = Shell('python3 ' .. py)
    os.remove(py)
    H.ok(okM and mask:find('\'if a == b then          \'', 1, true) ~= nil, 'mutate: a comment is blanked: ' .. mask)
    H.ok(mask:find('p == q', 1, true) == nil and mask:find('r == t', 1, true) == nil and mask:find('.. n', 1, true),
        'mutate: strings and long strings are blanked, the code around them stays: ' .. mask)
    local ok, out = Shell((
        '%s timeout 600 python3 tools/mutate.py %s --specs admin_permissions --storage=files '
        .. '--jobs=1 --only \'118:== => ~=\''
    ):format(CLEAN_ENV, file))
    H.ok(ok and out:find('KILLED by admin_permissions', 1, true) ~= nil and out:find('1 of 1 mutants killed', 1, true),
        'mutate: the grades-list mutant is killed: ' .. out:sub(-300))
    ok, out = Shell((
        '%s timeout 600 python3 tools/mutate.py %s --specs admin_permissions --storage=files '
        .. '--jobs=1 --only \'120:false => false\''
    ):format(CLEAN_ENV, file))
    H.ok(not ok and out:find('SURVIVED', 1, true) ~= nil,
        'mutate: a mutant no spec catches survives, exit 1: ' .. out:sub(-300))
    H.eq(Md5(file), before, 'mutate: the working tree file is unchanged')
    local _, left = Shell('ls -d /tmp/cp_mutate_* 2>/dev/null || true')
    H.eq(left:gsub('%s+', ''), '', 'mutate: no temporary copy is left')
end

-- ============================================================================
--                            4. tools/lua_coverage
-- ============================================================================
-- H15: the line hook measures the spec process and the fixture processes it starts (npc_spec starts
-- tests/fixtures/npc/client_check.lua with io.popen), each into a dump of its own.

do
    local hasCc = Shell('command -v cc')
    if not hasCc then
        print('SKIP check_tools: tools/lua_coverage (no C compiler)')
    else
        local dir = os.tmpname()
        os.remove(dir)
        os.execute(('mkdir -p \'%s/dumps\''):format(dir))
        local okB, outB = Shell(('cc -O2 -shared -fPIC -o \'%s/ccov.so\' tools/lua_coverage/ccov.c'):format(dir))
        H.ok(okB, 'lua_coverage: ccov.c builds: ' .. outB)
        local ok, out = Shell((
            '%s CP_COV_SO=\'%s/ccov.so\' CP_COV_DIR=\'%s/dumps\' LUA_INIT_5_4=@\'%s\' CP_TEST_COVERAGE=1 '
            .. 'timeout 600 lua5.4 tests/run.lua --jobs=1 --storage=files tests/npc_spec'
        ):format(CLEAN_ENV, dir, dir, H.root .. '../tools/lua_coverage/cov_init.lua'))
        H.ok(ok, 'lua_coverage: npc_spec passes under the hook: ' .. out:sub(-300))
        local _, list = Shell(('grep -l -r -h "^#spec " \'%s/dumps\' | xargs head -qn1'):format(dir))
        H.ok(list:find('#spec tests/npc_spec.lua', 1, true) ~= nil,
            'lua_coverage: the spec process is measured: ' .. list)
        H.ok(list:find('#spec tests/fixtures/npc/client_check.lua', 1, true) ~= nil,
            'lua_coverage: and the fixture process it starts: ' .. list)
        local _, npc = Shell(
            ('grep -h -c -F "Crimson-Police/modules/npc/client/npc.lua" \'%s\'/dumps/*client_check*'):format(dir))
        H.ok(tonumber((npc:match('%d+'))) == 1, 'lua_coverage: the fixture\'s lines of npc/client/npc.lua are there')
        os.execute(('rm -rf \'%s\''):format(dir))
    end
end

return H
