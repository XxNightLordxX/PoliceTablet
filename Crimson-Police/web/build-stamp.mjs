// Writes dist/build-stamp.json after `vite build`: a sha256 over every input of the NUI bundle
// (web/src/**, web/index.html, the build config and locales/parts/ui.json, which the bundle embeds as the
// fallback text). tools/check_contracts.py recomputes the same hash and fails when web/dist was not rebuilt
// after a source change (the shipped UI must be the reviewed source). Keep both algorithms identical:
// files sorted by their path relative to Crimson-Police/ (posix), hashed as path \0 bytes \0.
import { createHash } from 'node:crypto';
import { readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const WEB = dirname(fileURLToPath(import.meta.url));
const RES = join(WEB, '..');
const IGNORE = new Set(['.DS_Store']);

function walk(dir, out) {
  for (const name of readdirSync(dir)) {
    if (IGNORE.has(name)) continue;
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p, out);
    else out.push(p);
  }
  return out;
}

export function sourceHash() {
  const files = [
    ...walk(join(WEB, 'src'), []),
    ...['index.html', 'package.json', 'tsconfig.json', 'vite.config.ts'].map((f) => join(WEB, f)),
    join(RES, 'locales', 'parts', 'ui.json'),
  ].map((p) => ({ p, rel: relative(RES, p).split(sep).join('/') }));
  files.sort((a, b) => (a.rel < b.rel ? -1 : a.rel > b.rel ? 1 : 0));
  const h = createHash('sha256');
  for (const f of files) {
    h.update(f.rel + '\0');
    h.update(readFileSync(f.p));
    h.update('\0');
  }
  return { hash: h.digest('hex'), files: files.length };
}

const { hash, files } = sourceHash();
writeFileSync(join(WEB, 'dist', 'build-stamp.json'), JSON.stringify({ sourceHash: hash, files }, null, 2) + '\n');
console.log(`build-stamp: ${files} source files, ${hash.slice(0, 12)}`);
