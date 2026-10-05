-- CP.Banking: the only code that talks to Renewed-Banking.

CP.Banking = CP.Banking or {}
local B = CP.Banking
local TAG = 'renewed_banking'
local RESOURCE = 'Renewed-Banking'

local errorLoggedAt = {}

local function LogError(key, fmt, ...)
    local now = os.time()
    if errorLoggedAt[key] and now - errorLoggedAt[key] < 60 then return end
    errorLoggedAt[key] = now
    CP.err(TAG, fmt, ...)
end

local function Available()
    if GetResourceState(RESOURCE) == 'started' then return true end
    LogError('stopped', 'Renewed-Banking is not started: bank entries and society accounts are unavailable')
    return false
end

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
    local ok, res = pcall(function()
        return exports[RESOURCE]:handleTransaction(args[1], args[2], args[3], args[4], args[5], args[6], args[7],
            args[8])
    end)
    if not ok then
        LogError('handleTransaction', 'exports[\'Renewed-Banking\']:handleTransaction failed: %s', tostring(res))
        return false
    end
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
    local ok, res = pcall(function() return exports[RESOURCE]:removeAccountMoney(account, n) end)
    if not ok then
        LogError('removeAccountMoney', 'exports[\'Renewed-Banking\']:removeAccountMoney failed: %s', tostring(res))
        return false
    end
    CP.log(TAG, 'withdraw %d from %s -> %s', n, account, tostring(res))
    return res == true
end

function B.societyBalance(account)
    if type(account) ~= 'string' or account == '' then return nil end
    if not Available() then return nil end
    local ok, res = pcall(function() return exports[RESOURCE]:getAccountMoney(account) end)
    if not ok then
        LogError('getAccountMoney', 'exports[\'Renewed-Banking\']:getAccountMoney failed: %s', tostring(res))
        return nil
    end
    if type(res) == 'number' then return res end
    return nil
end

function B.depositSociety(account, amount)
    if type(account) ~= 'string' or account == '' then return false end
    local n = ToAmount(amount)
    if not n then return false end
    if n == 0 then return true end
    if not Available() then return false end
    local ok, res = pcall(function() return exports[RESOURCE]:addAccountMoney(account, n) end)
    if not ok then
        LogError('addAccountMoney', 'exports[\'Renewed-Banking\']:addAccountMoney failed: %s', tostring(res))
        return false
    end
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
        LogError('history', 'reading the Renewed-Banking history failed: %s', tostring(row))
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
B._setHistoryDb = function(db) historyDb = db end
