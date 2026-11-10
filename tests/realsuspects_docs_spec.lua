-- The owner docs for real suspects stay in step with the code. Owner guide section 6 (owner checklist, the rules

-- for cases with real suspects, fairness, troubleshooting) is in the guide's contents, /crimsonheat is in the README's
-- command list, the guide's go-live checklist points to it, every Config.LiveCrime / Config.Volunteers / Config.RealSuspects key path the
-- section names exists, the in-game checklist has a check for every and SPEC's SOP has the rules.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })

local function ReadRepo(rel)
    local f = io.open(H.root .. '../' .. rel, 'r')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return s
end

local function Has(s, needle) return type(s) == 'string' and s:find(needle, 1, true) ~= nil end

local readme = ReadRepo('README.md') or ''
local guide = ReadRepo('docs/OWNER_GUIDE.md') or ''
local checklist = ReadRepo('docs/IN_GAME_CHECKLIST.md') or ''
local spec = ReadRepo('docs/dev/SPEC.md') or ''

-- ============================================================================
--                         OWNER GUIDE 6 AND ITS LINKS
-- ============================================================================

local HEADINGS = {
    { '## 6. Real suspects: live crimes and volunteers', '(#6-real-suspects-live-crimes-and-volunteers)' },
    { '### 6.1 Owner checklist', '(#61-owner-checklist)' },
    { '### 6.2 Rules for cases with real suspects', '(#62-rules-for-cases-with-real-suspects)' },
    { '### 6.3 What is built in for fairness', '(#63-what-is-built-in-for-fairness)' },
    { '### 6.4 When something does not happen', '(#64-when-something-does-not-happen)' },
}
for _, h in ipairs(HEADINGS) do
    H.ok(Has(guide, '\n' .. h[1] .. '\n'), 'the guide has ' .. h[1])
    H.ok(Has(guide, h[2]), '...and the contents link to it')
end

local section = guide:match('\n## 6%. Real suspects.-\n%-%-%-\n') or ''
H.ok(#section > 2000, 'guide 6 has its text')

-- the owner's four promises, in words a player understands
for _, needle in ipairs({
    '**No points for hurting players.**',
    '**No live position.**',
    '**Consent and opt-out.**',
    '**Staff see everything.**',
    'For officers:',
    'For suspects (crew members of a live crime and volunteers):',
    'For staff:',
    '`ContractsConfig.LifecycleEvents = true`',
    '| Issue | Solution |',
}) do
    H.ok(Has(section, needle), 'guide 6 says ' .. needle)
end

-- every config key path the section names exists in the shipped config (none renamed or invented)
local paths = {}
for path in section:gmatch('%f[%w]Config%.([%w_%.]+)') do paths[path:gsub('%.$', '')] = true end
local count = 0
for path in pairs(paths) do
    count = count + 1
    local node = Config
    for key in path:gmatch('[^%.]+') do
        if type(node) == 'table' then node = node[key] else node = nil end
    end
    H.ok(node ~= nil, 'guide 6 names Config.' .. path .. ', which exists')
end
H.ok(count >= 15, ('guide 6 names the config keys (%d)'):format(count))

-- the defaults the section states are the shipped ones
H.eq(Config.LiveCrime.enabled, false, 'live crimes ship off, as guide 6 says')
H.eq(Config.Volunteers.enabled, false, 'volunteers ship off, as guide 6 says')
H.eq(Config.RealSuspects.neutralisedShare, 0.5, '6.3: a downed catch is half a detain')
H.eq(Config.LiveCrime.lastReportedEvery, 60, '6.3: last reported every 60 s')
H.eq(Config.Volunteers.driverReportEvery, 30, '6.3: a driver every 30 s')
H.eq(Config.RealSuspects.maxCatchesPerSuspectDay, 2, '6.3: twice a day')
H.eq(Config.RealSuspects.pairCooldownHours, 24, '6.3: 24 h between pairs')
H.eq(Config.Volunteers.cancelGraceSeconds, 60, '6.2: a free cancel within 60 s')
H.eq(Config.Volunteers.strikes, 3, '6.2: 3 strikes')
H.eq(Config.RealSuspects.custodyHoldSeconds, 30, '6.4: the cuffs hold 30 s')
H.eq(Config.RealSuspects.cuffRange, 3.5, '6.4: within 3.5 m')
H.eq(Config.LiveCrime.suspectRadius, 300.0, '6.4: suspects within 300 m')
H.eq(Config.RealSuspects.casesKept, 16, '6.3: 16 closed cases kept')
H.ok(Has(section, '`' .. Config.RealSuspects.excludeAce .. '`') or Has(section, Config.RealSuspects.excludeAce),
    '6.1 names the exclude ace as shipped')

-- the command list and the go-live checklist
H.ok(Has(readme, '| `/' .. Config.Volunteers.command .. '` |'), 'README 6.1 lists the volunteer command')
local golive = guide:match('### 7%.1 Before go%-live checklist(.-)\n### 7%.2') or ''
H.ok(Has(golive, '(#6-real-suspects-live-crimes-and-volunteers)'), 'guide 7.1 points to guide 6')

-- ============================================================================
--                      THE IN-GAME CHECKLIST AND THE SOP
-- ============================================================================

local realPart = checklist:match('\n## Real suspects %(ships off%)(.-)\n## ') or ''
for _, step in ipairs({
    'V11',
    'V12',
    'V13',
    'V14',
    'V15',
    'V16',
    'V17',
    'V18',
    'V19',
    'V20',
    'V21',
    'V22',
    'V23',
    'V24',
    'V25',
    'V26',
    'V27',
}) do
    local tagged = realPart:find('%(' .. step .. '[,%)]') or realPart:find(', ' .. step .. '[,%)]')
    H.ok(tagged ~= nil, 'the in-game checklist has a check for ' .. step)
end
H.ok(Has(checklist, '\n## Real suspects (ships off)\n'), 'the checklist has one Real suspects section')

local sop = spec:match('\n## SOP: rules of use for officers(.-)\n## ') or ''
H.ok(Has(sop, 'Cases with real suspects'), 'SPEC SOP has the rules for cases with real suspects')
for _, needle in ipairs({
    '- Least force.',
    '- No live tracking.',
    '- No case against yourself or a friend.',
    '- Suspects play it out.',
    '- Staff decide from the case timeline.',
}) do
    H.ok(Has(sop, needle), 'SPEC SOP: ' .. needle)
end

return H
