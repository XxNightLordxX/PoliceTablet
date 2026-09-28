// src/mocks/index.ts · browser dev mode only (main.tsx imports this only when isEnvBrowser()).
// Eagerly loads every src/mocks/*.mock.ts, so a feature adds mocks by dropping in <feature>.mock.ts:
//   import { registerMock } from '../shared/nui';
//   registerMock('request', 'getBoard', (args) => ({ ... }));
//   registerMock('action', 'server:acceptType', (type) => { if (type === 'tactical') throw new Error('err.server_busy'); return true; });
const modules = import.meta.glob('./*.mock.ts', { eager: true });

export const loadedMocks = Object.keys(modules).sort();
console.info(`[crimson-police:mock] browser mode, loaded ${loadedMocks.length} mock file(s):`, loadedMocks.join(', '));
