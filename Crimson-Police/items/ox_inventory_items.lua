-- The Crimson-Police tablet item for ox_inventory. Paste the entry below into ox_inventory/data/items.lua (inside
-- its return { }), copy crimson_police_tablet.png into ox_inventory/web/images and set Config.Tablet.item =
-- 'crimson_police_tablet'. Crimson-Police never loads this file and never edits ox_inventory (items/README.md).

return {
    ['crimson_police_tablet'] = {
        label = 'Police Tablet',
        weight = 500,
        stack = false,
        close = true,
        description = 'Crimson-Police mission tablet',
        client = {
            image = 'crimson_police_tablet.png',
            export = 'Crimson-Police.useTablet', -- <resource folder name>.useTablet: change it if you renamed the folder
        },
    },
}
