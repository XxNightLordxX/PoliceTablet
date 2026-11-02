-- The pop-up officer options (My options -> Pop-ups, kept on this PC): how long notifications stay (toastTime), how

-- long the result card stays (resultTime, seconds) and fewer pop-ups during a mission (quietRun: unit invites,
-- commendations, rewards and profile news go only to the bell while a run is on; route, custody, run messages,
-- warnings and errors always show). The NUI applies the first two (web/src/shared/toast.ts, hud/ResultScreen.tsx);
-- CP.Tablet.notify (client) applies quietRun. Key hints (keyHints, on by default) name the bound key on the
-- ready check banner, a new mission call and the contact HUD line (CP.Options.keyHint, web/src/shared/keyHints.ts).
-- Config.OfficerOptions holds the allow, defaults and bounds.

local Defs = CP.OptionDefs

Defs.add('toastTime', {
    kind = 'enum',
    values = { 'short', 'normal', 'long' },
    default = 'normal',
    store = 'local',
    group = 'popups',
    order = 10,
})
Defs.add('resultTime', {
    kind = 'number',
    min = 5,
    max = 120,
    integer = true,
    default = 25,
    store = 'local',
    group = 'popups',
    order = 20,
})
Defs.add('quietRun', { kind = 'bool', default = false, store = 'local', group = 'popups', order = 30 })
-- Key hints (step O11): the ready check banner, a new mission call and the contact HUD line name the key bound to
-- it ("or press K"); an unbound key is never named. On by default: it only adds text.
Defs.add('keyHints', { kind = 'bool', default = true, store = 'local', group = 'popups', order = 40 })
