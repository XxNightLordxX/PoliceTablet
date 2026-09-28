-- modules/integrations/renewed_banking/server.lua · CP.Banking: the only code that talks to Renewed-Banking.
--
-- Owns exports['Renewed-Banking']:handleTransaction, removeAccountMoney and getAccountMoney (verified
-- signatures in docs/INTEGRATIONS.md). Personal money itself moves through Qbox
-- (CP.Qbx.addMoney); Renewed-Banking only keeps the history, so a payout needs both calls.
--
-- Public API (docs/ARCHITECTURE.md §5.1). Every function returns false/nil instead of raising when
-- Renewed-Banking is stopped or rejects the call. Amounts are rounded half up to whole dollars;
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
--   CP.Banking.societyBalance(account) -> number|nil   getAccountMoney(account); nil for an unknown account.
-- message: apostrophes and backslashes are removed (Renewed-Banking doubles them in the stored text).
-- issuer/receiver: never nil (nil becomes ''). transId: e.g. ('CP-%s-%s'):format(runUuid, citizenid).

CP.Banking = CP.Banking or {}
local B = CP.Banking
local TAG = 'renewed_banking'
local RESOURCE = 'Renewed-Banking'

local errorLoggedAt = {}

local function logError(key, fmt, ...)
    local now = os.time()
    if errorLoggedAt[key] and now - errorLoggedAt[key] < 60 then return end
    errorLoggedAt[key] = now
    CP.err(TAG, fmt, ...)
end

local function available()
    if GetResourceState(RESOURCE) == 'started' then return true end
    logError('stopped', 'Renewed-Banking is not started: bank entries and society accounts are unavailable')
    return false
end

-- A non-negative whole amount, or nil.
local function toAmount(amount)
    local n = tonumber(amount)
    if not n or n ~= n or n == math.huge or n == -math.huge or n < 0 then return nil end
    return math.floor(n + 0.5)
end

-- At most max bytes without splitting a UTF-8 character (the text lands in Renewed-Banking's JSON
-- history; half a character would show as garbage there).
local function text(v, max)
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

local function safeMessage(message)
    local s = text(message, 200)
    return (s:gsub("['\\]", ''))
end

local function title()
    local t = Config.Tablet and Config.Tablet.title
    if type(t) == 'string' and t ~= '' then return t end
    return 'Crimson-Police'
end

local function transaction(account, amount, message, issuer, receiver, transType, transId)
    if type(account) ~= 'string' or account == '' then return false end
    local n = toAmount(amount)
    if not n then return false end
    if n == 0 then return true end
    if not available() then return false end
    local tid = transId ~= nil and text(transId, 128) or nil
    local args = { account, title(), n, safeMessage(message), text(issuer, 100), text(receiver, 100), transType, tid }
    local ok, res = pcall(function()
        return exports[RESOURCE]:handleTransaction(args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8])
    end)
    if not ok then
        logError('handleTransaction', "exports['Renewed-Banking']:handleTransaction failed: %s", tostring(res))
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
    return transaction(citizenid, amount, message, issuer, receiver, 'deposit', transId)
end

function B.recordSocietyWithdraw(account, amount, message, issuer, receiver, transId)
    return transaction(account, amount, message, issuer, receiver, 'withdraw', transId)
end

function B.withdrawSociety(account, amount)
    if type(account) ~= 'string' or account == '' then return false end
    local n = toAmount(amount)
    if not n then return false end
    if n == 0 then return true end
    if not available() then return false end
    local ok, res = pcall(function() return exports[RESOURCE]:removeAccountMoney(account, n) end)
    if not ok then
        logError('removeAccountMoney', "exports['Renewed-Banking']:removeAccountMoney failed: %s", tostring(res))
        return false
    end
    CP.log(TAG, 'withdraw %d from %s -> %s', n, account, tostring(res))
    return res == true
end

function B.societyBalance(account)
    if type(account) ~= 'string' or account == '' then return nil end
    if not available() then return nil end
    local ok, res = pcall(function() return exports[RESOURCE]:getAccountMoney(account) end)
    if not ok then
        logError('getAccountMoney', "exports['Renewed-Banking']:getAccountMoney failed: %s", tostring(res))
        return nil
    end
    if type(res) == 'number' then return res end
    return nil
end
