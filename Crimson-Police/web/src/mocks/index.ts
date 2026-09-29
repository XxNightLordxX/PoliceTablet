// Browser dev mode only (main.tsx imports this only when isEnvBrowser()).

const modules = import.meta.glob('./*.mock.ts', { eager: true });

export const loadedMocks = Object.keys(modules).sort();
console.info(`[crimson-police:mock] browser mode, loaded ${loadedMocks.length} mock file(s):`, loadedMocks.join(', '));
