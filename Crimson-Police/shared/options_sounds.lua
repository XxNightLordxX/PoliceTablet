-- The sound officer options (My options -> Sounds, kept on this PC): the mission call tone (soundCalls), the unit

-- invite and ready check tone (soundUnit) and the objective cues on a run (soundCues: checkpoints, a defused target,
-- a found item). On or off only: the game's frontend sounds have no volume. CP.Options.sound (modules/access/client/options.lua)
-- plays a tone only while its option is on. Config.OfficerOptions holds the allow and defaults.

local Defs = CP.OptionDefs

Defs.add('soundCalls', { kind = 'bool', default = true, store = 'local', group = 'sounds', order = 10 })
Defs.add('soundUnit', { kind = 'bool', default = true, store = 'local', group = 'sounds', order = 20 })
Defs.add('soundCues', { kind = 'bool', default = true, store = 'local', group = 'sounds', order = 30 })
