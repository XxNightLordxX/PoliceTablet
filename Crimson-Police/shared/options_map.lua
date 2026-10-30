-- The map officer options (My options -> Map, step O14): how Objective GPS leads to each objective (saved with the

local Defs = CP.OptionDefs

Defs.add('objectiveGps',
    { kind = 'enum', values = { 'route', 'waypoint', 'off' }, default = 'route', group = 'map', order = 10 })
Defs.add('hudTargetLine', { kind = 'bool', default = true, store = 'local', group = 'map', order = 20 })
Defs.add('colourblindMap', { kind = 'bool', default = false, store = 'local', group = 'map', order = 30 })
