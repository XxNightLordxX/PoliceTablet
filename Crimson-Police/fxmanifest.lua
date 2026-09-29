fx_version 'cerulean'
game 'gta5'
lua54 'yes'
use_experimental_fxv2_oal 'yes'

name 'Crimson-Police'
description 'Crimson-Police: police tablet with random NPC missions, cash payouts and leaderboards (Qbox)'
author 'Crimson-Police'
version '1.0.0'

-- Qbox stack only (see README). Missions need OneSync for server-created entities.
dependencies {
    '/onesync',
    'oxmysql',
    'ox_lib',
    'qbx_core',
    'ox_target',
    'ox_inventory',
    'sc-dispatch',
    'sc-ambulance',
    'Renewed-Banking',
}

-- Load order: config, blocks config, shared helpers, storage, feature modules, then objective blocks.
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
    'modules/storage/memsql.lua',
    'modules/storage/server.lua',
    'modules/**/server.lua',
    'blocks/**/server.lua',
}

client_scripts {
    'modules/**/client.lua',
    'blocks/**/client.lua',
}

ui_page 'web/dist/index.html'

files {
    'web/dist/index.html',
    'web/dist/**/*',
    'locales/*.json',
    'logos/*',
}
