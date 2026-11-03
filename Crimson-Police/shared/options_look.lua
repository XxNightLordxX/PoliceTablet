-- The officer options that make the tablet easier to read (My options -> Easier to read, saved with the character):

-- the officer's tablet look (appearance and accent) on the mission HUD, the result card and the notifications too,
-- and larger text on the tablet and the HUD. The tablet applies them (web/src/App.tsx AmbientLook,
-- layouts/TabletFrame.tsx, hud/HudColumn.tsx); Config.OfficerOptions holds the allow and defaults.

local Defs = CP.OptionDefs

Defs.add('hudLook', { kind = 'bool', default = false, store = 'server', group = 'look', order = 10 })
Defs.add('textSize',
    { kind = 'enum', values = { 'normal', 'large' }, default = 'normal', store = 'server', group = 'look', order = 20 })
