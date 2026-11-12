-- The Crimson-Police resource manifest: its dependencies, the scripts in load order and the NUI files.

fx_version 'cerulean'
game 'gta5'
lua54 'yes'
use_experimental_fxv2_oal 'yes'

name 'Crimson-Police'
description 'Crimson-Police: police tablet with random NPC missions, cash payouts and leaderboards (Qbox)'
author 'Crimson-Police'
version '1.0.0'

-- Qbox stack only (see README). Missions need OneSync for server-created entities. Dispatch, ambulance, banking and
-- police scripts are optional: Config.Integrations picks them (README "Supported scripts").
dependencies {
    '/onesync',
    'oxmysql',
    'ox_lib',
    'qbx_core',
    'ox_target',
    'ox_inventory',
}

-- Load order: config, blocks config, shared helpers, storage, feature modules, then objective blocks.
-- Each module is a folder of sub-files (modules/<module>/<part>.lua, client parts in modules/<module>/client/).
-- Mission files are not scripts: modules/missions reads them with LoadResourceFile.
shared_scripts {
    '@ox_lib/init.lua',
    'config/config.lua',
    'config/blocks.lua',
    'shared/*.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    -- storage first: with Config.Database.enabled = false it swaps MySQL for the saves folder engine
    'modules/system/memsql.lua',
    'modules/system/storage.lua',
    -- CP.AdminKit before every module, so any module may register its admin actions as it loads
    'modules/admin/adminkit.lua',
    -- the rest of the system module: the start-up runner, then the calendar and the timed jobs every module joins
    'modules/system/migrations.lua',
    'modules/system/schedule.lua',
    -- the module sub-files, one by one in the order they have always loaded in (some read another's CP table at load)
    'modules/access/access.lua',
    'modules/admin/admin.lua',
    'modules/admin/adminhome.lua',
    'modules/missions/builder.lua',
    'modules/admin/confighealth.lua',
    'modules/npc/custody.lua',
    'modules/supervisor/deptcontrols.lua',
    'modules/runs/downed.lua',
    'modules/runs/draw.lua',
    'modules/system/integrations/integrations.lua',
    'modules/system/integrations/crimson_contracts.lua',
    'modules/system/integrations/ps_dispatch.lua',
    'modules/system/integrations/qbx.lua',
    'modules/system/integrations/qbx_ambulancejob.lua',
    'modules/system/integrations/qbx_policejob.lua',
    'modules/system/integrations/renewed_banking.lua',
    'modules/system/integrations/sc_ambulance.lua',
    'modules/system/integrations/sc_dispatch.lua',
    'modules/system/integrations/sc_police.lua',
    'modules/supervisor/livectl.lua',
    'modules/map/markers.lua',
    'modules/missions/missions.lua',
    'modules/npc/npc.lua',
    'modules/npc/npccombat.lua',
    'modules/access/options.lua',
    'modules/access/permissions.lua',
    'modules/runs/route.lua',
    'modules/runs/runs.lua',
    'modules/runs/scaling.lua',
    'modules/admin/settings.lua',
    'modules/runs/spawn.lua',
    'modules/supervisor/supawards.lua',
    'modules/supervisor/today.lua',
    'modules/admin/sysadmin.lua',
    'modules/admin/setup.lua',
    'modules/access/tablet.lua',
    'modules/access/training.lua',
    'modules/missions/testing.lua',
    'modules/progression/*.lua',
    'modules/supervisor/fieldtraining.lua',
    'modules/supervisor/happyhour.lua',
    'modules/supervisor/missionban.lua',
    'modules/supervisor/notices.lua',
    'modules/supervisor/restrictions.lua',
    'modules/review/*.lua',
    'modules/realplayers/*.lua',
    'modules/dispatch/*.lua',
    'modules/teams/*.lua',
    -- the money module: the one money engine first, then the parts that pay through it
    'modules/money/engine.lua',
    'modules/money/cash.lua',
    'modules/money/featurerewards.lua',
    'modules/money/payments.lua',
    'modules/money/payouts.lua',
    'modules/money/rewards.lua',
    'blocks/**/server.lua',
}

client_scripts {
    -- the module client files, in the order they have always loaded in
    'modules/access/client/access.lua',
    'modules/missions/client/builder.lua',
    'modules/npc/client/custody.lua',
    'modules/admin/client/diag.lua',
    'modules/runs/client/downed.lua',
    'modules/system/client/qbx.lua',
    'modules/system/client/ambulance.lua',
    'modules/map/client/markers.lua',
    'modules/missions/client/missions.lua',
    'modules/npc/client/npc.lua',
    'modules/npc/client/npccombat.lua',
    'modules/access/client/options.lua',
    'modules/runs/client/route.lua',
    'modules/runs/client/runs.lua',
    'modules/admin/client/settings.lua',
    'modules/runs/client/spawn.lua',
    'modules/access/client/tablet.lua',
    'modules/access/client/training.lua',
    'modules/missions/client/testing.lua',
    'modules/realplayers/client/*.lua',
    'modules/dispatch/client/*.lua',
    'modules/teams/client/*.lua',
    -- the block client kit (CP.BlockKit) first, then every block's client half (each listed once)
    'blocks/_kit/client.lua',
    'blocks/checkpoint_route/client.lua',
    'blocks/escort/client.lua',
    'blocks/field_contact/client.lua',
    'blocks/flee_arrest/client.lua',
    'blocks/hostile_waves/client.lua',
    'blocks/interact_points/client.lua',
    'blocks/live_response/client.lua',
    'blocks/process_scene/client.lua',
    'blocks/protect_rescue/client.lua',
    'blocks/pursuit/client.lua',
    'blocks/search_area/client.lua',
    'blocks/skill_check/client.lua',
}

-- FiveM asset escrow: everything a city edits stays readable (README "What you can edit"): the config files and the
-- generic starting config, the locale texts, the built-in missions, the missions made in game and the ox_inventory
-- item snippet an owner pastes (items/). web/dist ships built.
escrow_ignore {
    'config/*.lua',
    'config/examples/*.lua',
    'locales/*',
    'missions/builtin/*',
    'missions/custom/**',
    'items/*.lua',
}

ui_page 'web/dist/index.html'

files {
    'web/dist/index.html',
    'web/dist/**/*',
    'locales/*.json',
    'logos/*',
}
