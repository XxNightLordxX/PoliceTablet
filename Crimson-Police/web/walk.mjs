// node walk.mjs · runs every src/**/*.walk.ts against the browser mocks (vite's module loader, so the mocks load as
// they do in the browser preview) and prints one line per walk. Exit status 1 when a walk fails.

import { readdirSync, statSync } from 'node:fs';
import { dirname, join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createServer } from 'vite';

const WEB = dirname(fileURLToPath(import.meta.url));
// the little of a browser window the mocks use: pushes are window message events, ?ui= picks the UI
globalThis.window = Object.assign(new EventTarget(), { location: { search: '?ui=admin', href: 'http://walk/' } });

function find(dir, out) {
    for (const name of readdirSync(dir)) {
        const p = join(dir, name);
        if (statSync(p).isDirectory()) find(p, out);
        else if (name.endsWith('.walk.ts')) out.push(p);
    }
    return out;
}

const server = await createServer({
    root: WEB,
    logLevel: 'error',
    appType: 'custom',
    server: { middlewareMode: true, hmr: false, watch: null },
    optimizeDeps: { noDiscovery: true, include: [] },
});
// the mocks log what they load and do; a walk prints only its result
const quiet = ['info', 'log', 'debug', 'warn'].map(k => [k, console[k]]);
let failed = 0;
try {
    for (const file of find(join(WEB, 'src'), []).sort()) {
        const rel = relative(WEB, file).split(sep).join('/');
        quiet.forEach(([k]) => (console[k] = () => {}));
        let res;
        try {
            const mod = await server.ssrLoadModule(`/${rel}`);
            res = await mod.walk();
        } catch (e) {
            res = { passed: 0, failures: [`crashed: ${e && e.stack ? e.stack : e}`] };
        } finally {
            quiet.forEach(([k, fn]) => (console[k] = fn));
        }
        if (res.failures.length) failed += 1;
        console.log(`${res.failures.length ? 'FAIL' : 'ok  '} ${rel}: ${res.passed} passed, ${res.failures.length} failed`);
        res.failures.forEach(f => console.log(`  FAIL ${f}`));
    }
} finally {
    await server.close();
}
process.exit(failed ? 1 : 0);
