-- The sound officer options (My options -> Sounds, kept on this PC): the mission call tone (soundCalls), the unit

local Defs = CP.OptionDefs

Defs.add('soundCalls', { kind = 'bool', default = true, store = 'local', group = 'sounds', order = 10 })
Defs.add('soundUnit', { kind = 'bool', default = true, store = 'local', group = 'sounds', order = 20 })
Defs.add('soundCues', { kind = 'bool', default = true, store = 'local', group = 'sounds', order = 30 })
