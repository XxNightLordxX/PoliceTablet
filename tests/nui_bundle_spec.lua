-- The NUI bundle (docs/LOOPS.md "Server cost and NUI"): every player's NUI starts with the officer and

-- The NUI bundle (docs/LOOPS.md "Server cost and NUI"): every player's NUI starts with the officer and
-- supervisor screens only; the Admin UI screens, the Supervisor Mission Builder and the criminal tablet load on
-- first use. Every stylesheet still loads with the page, in one fixed order (web/src/styles/order.ts), so the look
-- is the same. Reads web/src and web/dist (tools/check_all.sh build checks dist matches the sources).

local H = dofile('tests/harness.lua')

local WEB = H.root .. 'web/'

local function Read(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return s
end

local function Lines(cmd)
    local out = {}
    local p = io.popen(cmd)
    for line in p:lines() do out[#out + 1] = line end
    p:close()
    return out
end

-- ============================================================================
--                       STYLESHEETS: ONE FILE, ONE ORDER
-- ============================================================================

do
    local order = assert(Read(WEB .. 'src/styles/order.ts'), 'web/src/styles/order.ts exists')
    local listed = {}
    for rel in order:gmatch('import \'([^\']+%.css)\';') do
        local path = rel:match('^%./(.*)$') and ('styles/' .. rel:sub(3)) or rel:gsub('^%.%./', '')
        listed[path] = true
    end
    local missing = {}
    for _, f in ipairs(Lines('cd ' .. WEB .. 'src && find . -name "*.css" -not -path "./mocks/*" | sort')) do
        local rel = f:gsub('^%./', '')
        if not listed[rel] then missing[#missing + 1] = rel end
    end
    H.eq(table.concat(missing, ', '), '', 'every stylesheet of web/src is listed in styles/order.ts')
    local main = assert(Read(WEB .. 'src/main.tsx'))
    local first = main:match('^import [^\n]+') or main:match('\nimport [^\n]+')
    H.eq(first and first:gsub('^\n', ''), 'import \'./styles/order\';',
        'main.tsx imports styles/order before anything else')

    local css = {}
    for _, f in ipairs(Lines('ls ' .. WEB .. 'dist/assets')) do
        if f:match('%.css$') and not f:match('^DevPanel') then css[#css + 1] = f end
    end
    H.eq(#css, 1, 'web/dist has one stylesheet for the game (' .. table.concat(css, ', ') .. ')')
end

-- ============================================================================
--                    SCRIPTS: THE ADMIN SCREENS LOAD ON USE
-- ============================================================================

do
    local screens = assert(Read(WEB .. 'src/layouts/screens.ts'))
    H.eq(screens:find('\nimport %w+ from \'%.%./admin/screens/'), nil, 'screens.ts imports no Admin UI screen up front')
    H.eq(screens:find('\nimport %w+ from \'%.%./supervisor/screens/Builder\''), nil,
        'nor the Supervisor Mission Builder')
    H.ok(screens:find('lazyScreen(\'admin\', () => import(\'../admin/screens/Officers\'))', 1, true) ~= nil,
        'the Officers screen loads on first use')
    local app = assert(Read(WEB .. 'src/App.tsx'))
    H.eq(app:find('\nimport { CriminalTablet }', 1, true), nil, 'App.tsx does not import the criminal tablet up front')

    local html = assert(Read(WEB .. 'dist/index.html'))
    local entry = html:match('src="%./assets/([^"]+%.js)"')
    H.ok(entry ~= nil, 'dist/index.html names its script')
    local f = assert(io.open(WEB .. 'dist/assets/' .. entry, 'rb'))
    local size = f:seek('end')
    f:close()
    -- 1 161 475 bytes with every screen in it; 549 545 after step OP2
    H.ok(size < 700000, ('the script every player loads at start: %d bytes (under 700 000)'):format(size))
    local chunks = table.concat(Lines('ls ' .. WEB .. 'dist/assets'), '\n')
    for _, name in ipairs({ 'Officers', 'Settings', 'BuilderWorkspace', 'CriminalTablet' }) do
        H.ok(chunks:find('\n' .. name .. '%-[%w_%-]+%.js') ~= nil, name .. ' is a script of its own in web/dist')
    end
end

return H
