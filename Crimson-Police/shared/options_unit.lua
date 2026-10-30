-- The unit officer option (My options -> Unit, saved with the character): Auto-Ready answers the unit ready check for

local Defs = CP.OptionDefs

Defs.add('autoReady', { kind = 'bool', default = false, group = 'unit', order = 10 })
