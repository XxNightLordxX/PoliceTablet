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

-- the opt-in steps (clickthrough, race-all, db-check) come last, after the steps every run has
do
    local ok, out = Shell(('%s timeout 60 bash tools/check_all.sh --list'):format(CLEAN_ENV))
    H.ok(ok and out:find('\nbuild\nrelease\nclickthrough\nrace%-all\ndb%-check\n$') ~= nil,
        'the opt-in steps are listed last: ' .. out)
end

return H
