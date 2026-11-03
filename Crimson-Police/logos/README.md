# Department logos

Full guide: section [6.7 Department logos](../../README.md#67-department-logos) of the `README.md` in the
repository root. This note says the same in short.

- One file per department, named as in `Config.Departments[<key>].logo.file` in `config/config.lua` (`sast.png`
  for SAST, `fib.png` for FIB). PNG, WebP or SVG.
- A square, see-through PNG of at least 1024 × 1024 pixels looks best.
- `sast.png` and `fib.png` are placeholders. Replace them with your own art and restart Crimson-Police. Nothing
  needs to be rebuilt.
- Keep this folder when you update Crimson-Police.
- Or upload one in game: Admin UI → **Departments** → **Edit** → **Upload a logo** (PNG or WebP, at most 1 MB). It
  is saved here as `<department key>.png` (or `.webp`) and shows after the next restart of Crimson-Police.
