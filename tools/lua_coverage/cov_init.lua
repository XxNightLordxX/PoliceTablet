-- tools/lua_coverage/cov_init.lua · runs first in every lua5.4 process of a measured run (LUA_INIT_5_4=@<this file>,
-- set by tools/lua_coverage/run.sh). In a test process (tests/run.lua --child <spec>, or any script under tests/,
-- such as the fixture processes a spec starts with io.popen('lua5.4 tests/fixtures/...')) it starts the line hook of
-- ccov.so (CP_COV_SO) and writes the lines it saw to a file of its own in CP_COV_DIR when the process ends (os.exit
-- or the normal end). LUA_INIT_5_4 stays in the environment, so every child process is measured too. Any other
-- process (the run.lua parent, lua5.4 -e ...) is left alone.
local script = arg and arg[0] or ''
local label = nil
for i = 1, #(arg or {}) do
    if arg[i] == '--child' then label = arg[i + 1] end
end
if not label and (script:match('^tests/') or script:match('/tests/')) and not script:match('tests/run%.lua$') then
    label = script
end
local so, out = os.getenv('CP_COV_SO'), os.getenv('CP_COV_DIR')
if not label or not so or not out then return end

local open = package.loadlib(so, 'luaopen_ccov')
if not open then return end
local cov = open()
local sethook = debug.sethook
cov.start()
-- a spec tool that sets a hook of its own (a count hook to stop a runaway loop) keeps it; clearing it restarts ours
debug.sethook = function(...)
    local n = select('#', ...)
    local a = ...
    if n == 0 or (n == 1 and type(a) == 'thread') then return cov.start() end
    return sethook(...)
end

local done = false
local tag = tostring({}):match('0x(%x+)') or '0'
local function Dump()
    if done then return end
    done = true
    local name = label:gsub('[^%w]', '_')
    cov.dump(('%s/cov_%s_%d_%s_%d.txt'):format(out, name, os.time(), tag, math.floor(os.clock() * 1e6)), label)
end
local realExit = os.exit
os.exit = function(...)
    Dump()
    return realExit(...)
end
-- the normal end of the script: lua_close runs this finalizer (kept in the registry, so no global is added)
debug.getregistry()['crimson-police:coverage'] = setmetatable({}, { __gc = Dump })
