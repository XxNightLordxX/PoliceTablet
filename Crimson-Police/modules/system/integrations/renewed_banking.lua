-- The Renewed-Banking adapter of CP.Banking (modules/system/integrations/integrations): the only code that talks to
-- Renewed-Banking. Its functions answer as with no banking script while Config.Integrations.banking names another.

-- Owns exports['Renewed-Banking']:handleTransaction, removeAccountMoney, getAccountMoney and
-- addAccountMoney (verified signatures in docs/dev/INTEGRATIONS.md; addAccountMoney is not in the spec's
-- Appendix, INTEGRATIONS.md "addAccountMoney" names it as the only refund path for a society withdrawal).
-- Personal money itself moves through Qbox (CP.Qbx.addMoney); Renewed-Banking only keeps the history, so
-- a payout needs both calls.
--
-- Adapter functions (CP.Banking, docs/dev/ARCHITECTURE.md §5.1). Every function returns false/nil instead of raising
-- when Renewed-Banking is stopped or rejects the call. Amounts are rounded half up to whole dollars;
-- an amount of 0 is never sent (a $0 history entry) and returns true.
--   CP.Banking.recordDeposit(citizenid, amount, message, issuer, receiver, transId) -> boolean
--       handleTransaction(citizenid, Config.Tablet.title, amount, message, issuer, receiver, 'deposit', transId).
--       true = Renewed-Banking accepted the arguments. It still drops the entry silently when the
--       player's history is not loaded yet (right after QBCore:Server:PlayerLoaded), so pending payouts
--       should wait a few seconds after the player loads.
--   CP.Banking.withdrawSociety(account, amount) -> boolean
--       removeAccountMoney(account, amount): false when the account is unknown or cannot cover it.
--   CP.Banking.recordSocietyWithdraw(account, amount, message, issuer, receiver, transId) -> boolean
--       handleTransaction(account, Config.Tablet.title, amount, message, issuer, receiver, 'withdraw', transId).
--   CP.Banking.available() -> boolean                  Renewed-Banking is started.
--   CP.Banking.societyBalance(account) -> number|nil   getAccountMoney(account); nil for an unknown account.
--   CP.Banking.depositSociety(account, amount) -> boolean
--       addAccountMoney(account, amount): puts money back into a society account (CP.Cash's refund when a
--       society-funded payout's AddMoney failed after withdrawSociety). Society/shared accounts only:
--       Renewed-Banking returns false for a citizenid or an unknown account (and while its account cache
--       loads after a restart). It records no history entry.
-- message: apostrophes and backslashes are removed (Renewed-Banking doubles them in the stored text).
-- issuer/receiver: never nil (nil becomes ''). transId: e.g. ('CP-%s-%s'):format(runUuid, citizenid).

local B = {}
local TAG = 'renewed_banking'
local RESOURCE = 'Renewed-Banking'

local function Available()
    if CP.Ext.started(RESOURCE) then return true end
    CP.errEvery(TAG, 'stopped', 'Renewed-Banking is not started: bank entries and society accounts are unavailable')
    return false
end

-- Renewed-Banking is started (no error line: Settings asks it before reading a balance).
function B.available() return CP.Ext.started(RESOURCE) end

-- A non-negative whole amount, or nil.
local function ToAmount(amount)
    local n = tonumber(amount)
    if not n or n ~= n or n == math.huge or n == -math.huge or n < 0 then return nil end
    return CP.U.round(n)
end

-- At most max bytes without splitting a UTF-8 character (the text lands in Renewed-Banking's JSON
-- history; half a character would show as garbage there).
local function Text(v, max)
    if v == nil then return '' end
    local s = tostring(v)
    if #s <= max then return s end
    s = s:sub(1, max)
    local last = #s
    local j = last
    while j > 1 and j > last - 3 and s:byte(j) >= 0x80 and s:byte(j) < 0xC0 do j = j - 1 end
    local lead = s:byte(j)
    if lead >= 0xC0 then
        local need = (lead >= 0xF0 and 4) or (lead >= 0xE0 and 3) or 2
        if last - j + 1 < need then return s:sub(1, j - 1) end
    end
    return s
end

local function SafeMessage(message)
    local s = Text(message, 200)
    return (s:gsub('[\'\\]', ''))
end

local function Title()
    local t = Config.Tablet and Config.Tablet.title
    if type(t) == 'string' and t ~= '' then return t end
    return 'Crimson-Police'
end

local function Transaction(account, amount, message, issuer, receiver, transType, transId)
    if type(account) ~= 'string' or account == '' then return false end
    local n = ToAmount(amount)
    if not n then return false end
    if n == 0 then return true end
    if not Available() then return false end
    local tid = transId ~= nil and Text(transId, 128) or nil
    local args = { account, Title(), n, SafeMessage(message), Text(issuer, 100), Text(receiver, 100), transType, tid }
    local ok, res = CP.Ext.call(RESOURCE, 'handleTransaction', table.unpack(args, 1, 8))
    if not ok then return false end
    if type(res) ~= 'table' then
        CP.warn(TAG, 'Renewed-Banking rejected the %s entry for %s (invalid arguments)', transType, account)
        return false
    end
    CP.log(TAG, '%s %d recorded for %s (%s)', transType, n, account, tostring(tid))
    return true
end

function B.recordDeposit(citizenid, amount, message, issuer, receiver, transId)
    return Transaction(citizenid, amount, message, issuer, receiver, 'deposit', transId)
end

function B.recordSocietyWithdraw(account, amount, message, issuer, receiver, transId)
    return Transaction(account, amount, message, issuer, receiver, 'withdraw', transId)
end

-- A personal 'withdraw' entry (an admin's clawback) and a society 'deposit' entry (added funds, a refunded clawback).
function B.recordWithdraw(citizenid, amount, message, issuer, receiver, transId)
    return Transaction(citizenid, amount, message, issuer, receiver, 'withdraw', transId)
end

function B.recordSocietyDeposit(account, amount, message, issuer, receiver, transId)
    return Transaction(account, amount, message, issuer, receiver, 'deposit', transId)
end

function B.withdrawSociety(account, amount)
    if type(account) ~= 'string' or account == '' then return false end
    local n = ToAmount(amount)
    if not n then return false end
    if n == 0 then return true end
    if not Available() then return false end
    local ok, res = CP.Ext.call(RESOURCE, 'removeAccountMoney', account, n)
    if not ok then return false end
    CP.log(TAG, 'withdraw %d from %s -> %s', n, account, tostring(res))
    return res == true
end

function B.societyBalance(account)
    if type(account) ~= 'string' or account == '' then return nil end
    if not Available() then return nil end
    local ok, res = CP.Ext.call(RESOURCE, 'getAccountMoney', account)
    if not ok then return nil end
    if type(res) == 'number' then return res end
    return nil
end

function B.depositSociety(account, amount)
    if type(account) ~= 'string' or account == '' then return false end
    local n = ToAmount(amount)
    if not n then return false end
    if n == 0 then return true end
    if not Available() then return false end
    local ok, res = CP.Ext.call(RESOURCE, 'addAccountMoney', account, n)
    if not ok then return false end
    CP.log(TAG, 'deposit %d into %s -> %s', n, account, tostring(res))
    return res == true
end

-- ============================================================================
--                     HISTORY LOOKUP (ADMIN UI → PAYMENTS)
-- ============================================================================
-- A stuck payment is checked against Renewed-Banking's own history: player_transactions (personal, id = citizenid)
-- and bank_accounts_new (society, id = account). Read only, always through the real oxmysql (CP.Storage.realMySQL
-- with the database off), and only the one entry with this transaction id leaves this module: never the officer's
-- other bank history. Not found proves nothing (Renewed-Banking writes its history only for a cached player).

local historyDb = nil   -- test hook: a stand-in for the real oxmysql

local function HistoryDb()
    if historyDb then return historyDb end
    local db = (CP.Storage and CP.Storage.realMySQL) or MySQL
    if type(db) ~= 'table' or type(db.single) ~= 'table' then return nil end
    return db
end

-- { found, amount, type, time } of the entry with this trans_id in one history row, or { found = false }; nil when
-- the table could not be read.
local function FindIn(sql, id, transId)
    local db = HistoryDb()
    if not db then return nil end
    local ok, row = pcall(db.single.await, sql, { id })
    if not ok then
        CP.errEvery(TAG, 'history', 'reading the Renewed-Banking history failed: %s', tostring(row))
        return nil
    end
    if type(row) ~= 'table' or type(row.transactions) ~= 'string' then return { found = false } end
    -- a quick look before the whole history is decoded
    if not row.transactions:find(transId, 1, true) then return { found = false } end
    local okJ, list = pcall(json.decode, row.transactions)
    if not okJ or type(list) ~= 'table' then return { found = false } end
    for _, e in ipairs(list) do
        if type(e) == 'table' and e.trans_id == transId then
            return {
                found = true,
                amount = math.floor(tonumber(e.amount) or 0),
                type = e.trans_type == 'withdraw' and 'withdraw' or 'deposit',
                time = math.floor(tonumber(e.time) or 0),
            }
        end
    end
    return { found = false }
end

-- opts = { citizenid, account }: { personal = entry|nil, society = entry|nil } (nil = that side was not asked or
-- could not be read).
function B.findTxn(transId, opts)
    opts = type(opts) == 'table' and opts or {}
    if type(transId) ~= 'string' or transId == '' or #transId > 128 then return nil end
    local out = {}
    if type(opts.citizenid) == 'string' and opts.citizenid ~= '' and #opts.citizenid <= 50 then
        out.personal = FindIn('SELECT transactions FROM player_transactions WHERE id = ? LIMIT 1', opts.citizenid,
            transId)
    end
    if type(opts.account) == 'string' and opts.account ~= '' and #opts.account <= 50 then
        out.society = FindIn('SELECT transactions FROM bank_accounts_new WHERE id = ? LIMIT 1', opts.account, transId)
    end
    return out
end

-- Test hooks (not part of the contract).
CP.Banking._setHistoryDb = function(db) historyDb = db end

CP.Integrations.register('banking', RESOURCE, B)
