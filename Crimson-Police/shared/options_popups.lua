-- The pop-up officer options (My options -> Pop-ups, kept on this PC): how long notifications stay (toastTime), how

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
