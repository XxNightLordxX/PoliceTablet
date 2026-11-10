-- The long Admin UI lists: Config.AdminUi.pageSize (rows per page, 0 = each list as before) read through
-- CP.AdminKit, and the Player suspects cases a page at a time.

-- The long Admin UI lists: CP.AdminKit.pageSize (Config.AdminUi.pageSize, 0 = nil, 10-200), pageOf (one page
-- of a list in memory), and admin:getRsCases a page at a time. The SQL lists (audit, payments, an
-- officer's runs, flagged runs with the board) have one case each in adminkit_spec, admin_economy_spec and
-- admin_boards_spec.

local H = dofile('tests/harness.lua')

-- ============================================================================
--                                  THE SERVER
-- ============================================================================
-- Real: shared/*, modules/admin/adminkit. The Player suspects callback is taken from modules/realplayers/staff with
-- CP.Opponents' case list standing in.

H.boot({ side = 'server' })
_G.GetConvar = function(_, default) return default end
_G.PerformHttpRequest = function() end
H.load('modules/admin/adminkit.lua')
local Kit = CP.AdminKit

-- ============================================================================
--                                 1. PAGE SIZE
-- ============================================================================

do
    H.eq(Config.AdminUi.pageSize, 0, 'pageSize ships 0: every list as before')
    H.eq(Kit.pageSize(), nil, '0: no page size of its own')
    H.eq(Kit.oneRequest, nil, 'BK1: one request per screen open is the only way (no switch)')
    Config.AdminUi.pageSize = 50
    H.eq(Kit.pageSize(), 50, '50 rows a page')
    Config.AdminUi.pageSize = 3
    H.eq(Kit.pageSize(), 10, 'never below 10')
    Config.AdminUi.pageSize = 5000
    H.eq(Kit.pageSize(), 200, 'never above 200')
    Config.AdminUi.pageSize = 'lots'
    H.eq(Kit.pageSize(), nil, 'anything else: as before')
    Config.AdminUi.pageSize = 0

    local list = {}
    for i = 1, 23 do list[i] = i end
    local rows, page, pages, total = Kit.pageOf(list, 3, 10)
    H.ok(#rows == 3 and rows[1] == 21 and page == 3 and pages == 3 and total == 23, 'page 3 of 23 rows by 10')
    rows, page = Kit.pageOf(list, 99, 10)
    H.ok(page == 3 and rows[3] == 23, 'past the end: the last page')
    rows, page = Kit.pageOf(list, 'x', 10)
    H.ok(page == 1 and #rows == 10 and rows[1] == 1, 'anything odd: page 1')
    rows, page, pages = Kit.pageOf({}, 2, 10)
    H.ok(#rows == 0 and page == 1 and pages == 1, 'an empty list is one empty page')
end

-- ============================================================================
--                  2. PLAYER SUSPECTS CASES A PAGE AT A TIME
-- ============================================================================

do
    local cbs = {}
    local realCallback = Kit.callback
    Kit.callback = function(name, key, fn) cbs[name] = { key = key, fn = fn } end
    Kit.selfRun = function() return false end
    CP.Opponents = CP.Opponents or {}
    local Opp = CP.Opponents
    H.load('modules/realplayers/staff.lua')
    Kit.callback = realCallback
    Opp.staffCases = function()
        local out = {}
        for i = 1, 12 do
            out[i] = {
                runId = ('run-%04d'):format(i),
                officers = {},
                open = i > 9,
                kind = i % 2 == 0 and 'live' or 'volunteer',
            }
        end
        return out
    end
    local fn = cbs['admin:getRsCases'] and cbs['admin:getRsCases'].fn
    H.ok(fn ~= nil, 'the cases callback is registered')
    if fn then
        local d = fn({ src = 1, args = { page = 2 } })
        H.ok(#d.cases == 12 and d.casesPage == nil, 'shipped: every case at once')
        Config.AdminUi.pageSize = 10
        d = fn({ src = 1, args = { page = 2 } })
        H.ok(#d.cases == 2 and d.cases[1].runId == 'run-0011', 'pageSize 10: page 2 holds the last two cases')
        H.ok(d.casesPage and d.casesPage.page == 2 and d.casesPage.pages == 2 and d.casesPage.total == 12,
            'casesPage: page 2 of 2, 12 cases')
        -- a filter covers every case, not only the page shown: the three open cases are runs 10 to 12
        d = fn({ src = 1, args = { page = 1, filter = 'open' } })
        H.ok(#d.cases == 3 and d.cases[1].runId == 'run-0010' and d.casesPage.total == 3,
            'pageSize 10, filter open: the open cases from every page')
        d = fn({ src = 1, args = { filter = 'bogus' } })
        H.ok(d.casesPage.total == 12, 'an unknown filter keeps every case')
        Config.AdminUi.pageSize = 0
    end
end

return H
