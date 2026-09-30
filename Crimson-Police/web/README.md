# Crimson-Police · web UI

Full guide: section [12. For developers](../../README.md#12-for-developers) of the `README.md` in the repository
root. This note says the same in short.

**Server owners: you never need to touch this folder.** It holds the tablet's screens (the Officer, Supervisor and
Admin UIs, the mission HUD and notifications). They come ready-built in `web/dist/`, which is the only part FiveM
loads. You never run npm or build anything. Keep this folder as it is, and replace it with the new one when you
update Crimson-Police.

For developers (React 18, TypeScript and Vite). After a change to `web/src/` or `../locales/parts/`, rebuild and
commit `web/dist/`:

```
npm install
npm run build     # type check, build and build stamp: writes web/dist
npm run dev       # the UI in a browser at http://localhost:5173, with sample data
```

The full developer guide (source layout, adding a screen, the NUI bridge, hooks, theme variables and component
props) is `docs/WEB_UI.md` in the repository root.
