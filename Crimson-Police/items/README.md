# The tablet item (optional)

Full guide: section [3.1 The tablet item](../../docs/OWNER_GUIDE.md#31-the-tablet-item) of `docs/OWNER_GUIDE.md` in the
repository root. This note says the same in short.

Officers open Crimson-Police with `/CrimsonPolice`, a key or a mission desk. The ox_inventory item is an extra way.
Crimson-Police never loads anything from this folder and never edits ox_inventory: you copy two things yourself.

1. Copy the `['crimson_police_tablet'] = { ... },` entry of `ox_inventory_items.lua` into
   `ox_inventory/data/items.lua`, inside its `return { }`. You may change the label, weight or description. Keep
   the item name and the `export = 'Crimson-Police.useTablet'` line.
2. Copy `crimson_police_tablet.png` into `ox_inventory/web/images/`.
3. In `config/config.lua`, set `item = 'crimson_police_tablet'` inside `Config.Tablet`.
4. Optional: `requireItem = true` in `Config.Tablet.access` makes every way except a mission desk need the item in
   the inventory. The server checks it, and the tablet closes when the item leaves the inventory.
5. Restart the server (or restart ox_inventory, then Crimson-Police). The start-up check in the console (and Admin UI → Permissions →
   Config health) says whether the item and its picture were found.

## The criminal tablet item (optional)

The `['crimson_criminal_tablet'] = { ... },` entry opens the criminal tablet for volunteer suspects
(`Config.CriminalTablet`). Copy it the same way, then set `item = 'crimson_criminal_tablet'` inside
`Config.CriminalTablet`. It shows the police tablet's picture until you add a picture of your own.
