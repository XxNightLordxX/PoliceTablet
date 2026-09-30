# The tablet item (optional)

Crimson-Police opens with `/CrimsonPolice`, the `crimsonpolice_tablet` key mapping, a mission desk or the
`OpenTablet` export. The ox_inventory item is an extra way, and the only way besides a desk once
`Config.Tablet.access.requireItem = true`.

1. Paste the entry of `ox_inventory_items.lua` into `ox_inventory/data/items.lua`, inside its `return { }`.
   Change the label, weight or description if you like; keep the item name and the `client.export` line.
2. Copy `crimson_police_tablet.png` into `ox_inventory/web/images/`.
3. In `config/config.lua` set `Config.Tablet.item = 'crimson_police_tablet'`.
4. Optional: `Config.Tablet.access.requireItem = true` makes every way except a mission desk need the item in
   the inventory. The server checks it with ox_inventory, and the tablet closes when the item leaves the
   inventory.
5. Restart ox_inventory and Crimson-Police. Admin UI → Permissions → Config health says whether the item was found.

Crimson-Police never edits ox_inventory: this folder is only a snippet and an image to copy. The resource does
not load anything from it.
