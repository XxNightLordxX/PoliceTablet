-- The unit officer option (My options -> Unit, saved with the character): Auto-Ready answers the unit ready check for

-- the officer. The client sends the answer only while the officer is at the keys; the server counts it only
-- while the department allows it, the officer turned it on and stands within Config.OfficerOptions.autoReadyRange of
-- the leader (CP.Units). Ships locked (allow false) and off.

local Defs = CP.OptionDefs

Defs.add('autoReady', { kind = 'bool', default = false, group = 'unit', order = 10 })
