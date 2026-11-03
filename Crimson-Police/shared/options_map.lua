-- The map officer options (My options -> Map): how Objective GPS leads to each objective (saved with the

-- The map officer options (My options -> Map): how Objective GPS leads to each objective (saved with the
-- character: the GPS line as before, a map waypoint, or nothing), the HUD's objective direction line and colour-blind
-- map colours (both kept on this PC). modules/markers/client.lua reads them; they only hide or recolour, never show
-- more than the run allows (Radio Silence still wins).

local Defs = CP.OptionDefs

Defs.add('objectiveGps',
    { kind = 'enum', values = { 'route', 'waypoint', 'off' }, default = 'route', group = 'map', order = 10 })
Defs.add('hudTargetLine', { kind = 'bool', default = true, store = 'local', group = 'map', order = 20 })
Defs.add('colourblindMap', { kind = 'bool', default = false, store = 'local', group = 'map', order = 30 })
