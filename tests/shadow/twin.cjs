// tests/shadow/twin.cjs · the MariaDB twin of CP_TEST_STORAGE=shadow (started by tests/harness.lua, one per spec).
//
// It answers every MySQL call the way the real oxmysql would on MariaDB: mysql2 with oxmysql's connection
// options (supportBigNumbers, jsonStrings, flags), its typeCast (TINYINT(1) -> boolean, DATETIME/DATE ->
// milliseconds), its parseArguments (missing parameters padded with NULL, too many refused) and its
// parseResponse (query / single / scalar / insert / update), and it formats errors like oxmysql's logError.
// The harness compares these answers with the saves folder engine (modules/storage/memsql.lua).
//
//   node tests/shadow/twin.cjs <fifo>    requests: one JSON object per line on stdin
//                                         answers: one JSON object per line written to <fifo>
//   { "op": "q", "db": name, "kind": "query", "sql": "...", "params": [..], "ts": unix seconds }
//        -> { "ok": true, "r": <parseResponse>, "f": [[column, type name], ..] }   (f only for result sets)
//        -> { "ok": false, "e": "<oxmysql error text>", "m": "<MariaDB message>" }
//   { "op": "reset", "db": name }   drop and create the database (utf8mb4), -> { "ok": true }
//   "ts" pins NOW() for the statement (SET timestamp), so the engine can run with the same clock.
// Needs the mysql2 package: cd tests/shadow && npm install (node_modules is not committed).
'use strict';
const fs = require('fs');
const readline = require('readline');

const out = fs.openSync(process.argv[2], 'w');   // first, so the harness never waits on a twin that died
function send(obj) {
  const buf = Buffer.from(JSON.stringify(obj) + '\n', 'utf8');
  let off = 0;
  while (off < buf.length) {
    try {
      off += fs.writeSync(out, buf, off, buf.length - off);
    } catch (e) {
      if (e.code !== 'EAGAIN') throw e;
    }
  }
}

let mysql;
try {
  mysql = require('mysql2/promise');
} catch (e) {
  send({ fatal: 'the shadow twin needs the mysql2 package: cd tests/shadow && npm install (' + e.message + ')' });
  process.exit(1);
}
const TYPES = mysql.Types;

const RESOURCE = 'Crimson-Police';
const BINARY_CHARSET = 63;

// oxmysql src/utils/typeCast.ts (mysql-async compatible typecasting), with one fix: oxmysql 2.14.1 calls next()
// after field.string() / field.buffer() returned NULL for a TINYINT(1) or BIT(1) column, so mysql2 reads the
// value a second time from the bytes that follow (the next column, or past the row): a garbage number and the
// following columns shifted. That is not a value anything can match, so the twin returns NULL there (what the
// engine returns, and what SQL means). The same double read happens for a TINYINT(1) value other than 0 and 1;
// the twin returns the number there (what next() would have read).
function typeCast(field, next) {
  switch (field.type) {
    case 'DATETIME':
    case 'DATETIME2':
    case 'TIMESTAMP':
    case 'TIMESTAMP2':
    case 'NEWDATE': {
      const value = field.string();
      return value ? new Date(value).getTime() : null;
    }
    case 'DATE': {
      const value = field.string();
      return value ? new Date(value + ' 00:00:00').getTime() : null;
    }
    case 'TINY': {
      if (field.length !== 1) return next();
      const value = field.string();
      if (value === null) return null;   // the fix (see above)
      return value === '0' ? false : value === '1' ? true : Number(value);   // the fix: next() would read again
    }
    case 'BIT': {
      const buffer = field.buffer();
      if (buffer === null) return null;   // the fix (see above)
      if (buffer.length !== 1) return [...buffer];   // the fix: next() would read again (BIT is not used)
      const value = buffer[0];
      return value === 0 ? false : value === 1 ? true : value;
    }
    case 'TINY_BLOB':
    case 'MEDIUM_BLOB':
    case 'LONG_BLOB':
    case 'BLOB':
      if (field.charset === BINARY_CHARSET) {
        const value = field.buffer();
        if (value === null) return [value];
        return [...value];
      }
      return field.string();
    default:
      return next();
  }
}

// oxmysql src/utils/parseArguments.ts (array parameters; named placeholders are not used by Crimson-Police)
function parseArguments(query, parameters) {
  if (typeof query !== 'string') throw new Error(`Expected query to be a string but received ${typeof query} instead.`);
  if (!parameters) parameters = [];
  const placeholders = query.match(/\?(?!\?)/g)?.length ?? 0;
  if (!Array.isArray(parameters)) {
    const arr = [];
    for (let i = 0; i < placeholders; i++) arr[i] = parameters[i + 1] ?? null;
    parameters = arr;
  } else if (placeholders) {
    const diff = placeholders - parameters.length;
    if (diff > 0) parameters = [...parameters, ...new Array(diff).fill(null)];
    else if (diff < 0) throw new Error(`Expected ${placeholders} parameters, but received ${parameters.length}.`);
  }
  return [query, parameters];
}

// oxmysql src/utils/parseResponse.ts
function parseResponse(type, result) {
  switch (type) {
    case 'insert':
      return result?.insertId ?? null;
    case 'update':
      return result?.affectedRows ?? null;
    case 'single':
      return result?.[0] ?? null;
    case 'scalar': {
      const row = result?.[0];
      return (row && Object.values(row)[0]) ?? null;
    }
    default:
      return result ?? null;
  }
}

// oxmysql src/logger/index.ts logError: the text the Lua caller receives
function errorText(err, query, parameters, includeParameters) {
  const message = typeof err === 'object' ? err.message : String(err);
  return `${RESOURCE} was unable to execute a query!${query ? `\nQuery: ${query}` : ''}${
    includeParameters ? `\n${JSON.stringify(parameters)}` : ''
  }\n${message}`;
}

const socketPath = process.env.CP_SHADOW_SOCKET || '/run/mysqld/mysqld.sock';
const user = process.env.CP_SHADOW_USER || 'root';
const conns = new Map();
let admin = null;

async function conn(db) {
  let c = conns.get(db);
  if (c) return c;
  const flags = ['CONNECT_WITH_DB'];   // oxmysql getConnectionOptions
  c = await mysql.createConnection({
    socketPath, user, database: db,
    connectTimeout: 60000, trace: false, supportBigNumbers: true, jsonStrings: true,
    typeCast, namedPlaceholders: false, flags,
  });
  conns.set(db, c);
  return c;
}

async function handle(req) {
  if (req.op === 'reset') {
    const c = conns.get(req.db);
    if (c) { conns.delete(req.db); await c.end().catch(() => {}); }
    if (!admin) admin = await mysql.createConnection({ socketPath, user });
    const name = String(req.db).replace(/`/g, '');
    await admin.query(`DROP DATABASE IF EXISTS \`${name}\``);
    await admin.query(`CREATE DATABASE \`${name}\` CHARACTER SET utf8mb4`);
    return { ok: true };
  }
  if (req.op === 'drop') {
    const c = conns.get(req.db);
    if (c) { conns.delete(req.db); await c.end().catch(() => {}); }
    if (!admin) admin = await mysql.createConnection({ socketPath, user });
    await admin.query(`DROP DATABASE IF EXISTS \`${String(req.db).replace(/`/g, '')}\``);
    return { ok: true };
  }
  const c = await conn(req.db);
  let query = req.sql, params = req.params;
  try {
    [query, params] = parseArguments(query, params);
  } catch (e) {
    return { ok: false, e: errorText(e, query, params, false), m: e.message };
  }
  if (typeof req.ts === 'number') await c.query('SET timestamp = ?', [req.ts]);
  try {
    const [result, fields] = await c.query(query, params);
    const res = { ok: true, r: parseResponse(req.kind, result) };
    if (Array.isArray(result) && Array.isArray(fields)) {
      res.f = fields.map((f) => [f.name, TYPES[f.columnType] || String(f.columnType), f.columnLength]);
    }
    return res;
  } catch (e) {
    return { ok: false, e: errorText(e, query, params, true), m: e.message, code: e.code };
  }
}

send({ ready: true });
const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
let chain = Promise.resolve();
rl.on('line', (line) => {
  chain = chain.then(async () => {
    let req;
    try {
      req = JSON.parse(line);
    } catch (e) {
      send({ ok: false, e: 'twin: bad request ' + e.message, m: 'bad request' });
      return;
    }
    try {
      send(await handle(req));
    } catch (e) {
      send({ ok: false, e: 'twin: ' + (e && e.message), m: String(e && e.message), twin: true });
    }
  });
});
rl.on('close', () => {
  chain.then(async () => {
    for (const c of conns.values()) await c.end().catch(() => {});
    if (admin) await admin.end().catch(() => {});
    process.exit(0);
  });
});
