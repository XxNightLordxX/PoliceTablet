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
