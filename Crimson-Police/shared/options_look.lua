-- The officer options that make the tablet easier to read (My options -> Easier to read, saved with the character):

local Defs = CP.OptionDefs

Defs.add('hudLook', { kind = 'bool', default = false, store = 'server', group = 'look', order = 10 })
Defs.add('textSize',
    { kind = 'enum', values = { 'normal', 'large' }, default = 'normal', store = 'server', group = 'look', order = 20 })
