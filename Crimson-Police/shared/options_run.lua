-- During a mission's officer options (My options -> During a mission): abandon without the dialog (two presses),
-- recalculate the route in one click (both saved with the character) and distances in miles (kept on this PC).
-- The NUI only: server:abandon still costs the type cooldown, recalcRoute still counts Config.Route.maxRecalcs.

local Defs = CP.OptionDefs

Defs.add('abandonConfirm', { kind = 'bool', default = true, group = 'run', order = 10 })
Defs.add('skipRecalcConfirm', { kind = 'bool', default = false, group = 'run', order = 20 })
Defs.add('distanceUnits',
    { kind = 'enum', values = { 'metric', 'imperial' }, default = 'metric', store = 'local', group = 'run', order = 30 })
