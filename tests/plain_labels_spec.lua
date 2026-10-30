-- Plain-language admin labels (A9): the Payouts dialog, the Mission Builder and Settings read in plain words, with no
-- file names or game jargon in what an admin or supervisor sees.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })

local expect = {
    ['admin.payouts.col_default'] = 'Default from config',
    ['admin.payouts.permanent'] = 'Set by an admin',
    ['admin.payouts.unlock'] = 'Let supervisors change it again',
    ['builder.editor.armed'] = 'Armed enemies',
    ['builder.details.required_tier'] = 'Team size needed',
    ['builder.pub.required_tier'] = 'Team size needed',
    ['builder.test.required_tier'] = 'Team size needed',
    ['builder.pub.pool'] = 'Offered to',
    ['builder.block.hostile_waves'] = 'Shootout (enemies in waves)',
    ['builder.block.interact_points'] = 'Search spots',
    ['builder.block.flee_arrest'] = 'Suspect who runs or hides',
    ['builder.loc.edit_points'] = 'Place again',
    ['settings.badge.reload'] = 'Applies to missions at once',
    ['settings.badge.restart'] = 'Needs a server restart',
    ['settings.filter.restart'] = 'Needs a server restart',
    ['ui.admin_officers.points.adjust'] = 'Give or take points',
    ['admin.boards.award'] = 'Give points',
    ['admin.officers.award'] = 'Approve and give points',
}
for key, text in pairs(expect) do H.eq(CP.L(key), text, key) end

for _, key in ipairs({ 'builder.blocks.intro', 'builder.settings.intro', 'settings.subtitle', 'settings.intro' }) do
    H.ok(not CP.L(key):find('.lua', 1, true), key .. ': no file name')
end

return H
