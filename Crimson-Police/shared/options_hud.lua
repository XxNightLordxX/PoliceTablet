-- The mission HUD's officer options (My options -> Mission HUD, kept on this PC): which side of the screen it sits on,
-- its size, a compact view (the current objective only) and fewer animations. The tablet applies them at once
-- (web/src/hud/HudColumn.tsx, hud/Hud.tsx); Config.OfficerOptions holds the allow, defaults and bounds.

local Defs = CP.OptionDefs

Defs.add('hudSide',
    { kind = 'enum', values = { 'right', 'left' }, default = 'right', store = 'local', group = 'hud', order = 10 })
Defs.add('hudScale', { kind = 'number', min = 0.5, max = 2, default = 1.0, store = 'local', group = 'hud', order = 20 })
Defs.add('hudCompact', { kind = 'bool', default = false, store = 'local', group = 'hud', order = 30 })
Defs.add('reduceMotion', { kind = 'bool', default = false, store = 'local', group = 'hud', order = 40 })
