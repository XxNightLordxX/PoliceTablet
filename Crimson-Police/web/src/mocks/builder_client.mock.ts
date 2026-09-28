// Browser mocks for the builder client slice (modules/builder/client.lua and the builder screens).
//
// Client actions builderPlace / builderRecord / builderTestDrive play the whole in-game flow: the reply is
// { started: true }, then the tablet closes (message 'close'), the tool HUD overlay animates for a few seconds,
// the result is kept for builderResult and pushed (topic 'builder', event 'clientResult'), the overlay hides and
// the tablet reopens on the UI the tool was started from (payload.ui). builderCancel / builderWaypoint answer
// like the Lua client. Also: server:test:record (recording a draft test result), server:admin:reloadMissions
// (summary), and fallbacks for builder:list / builder:get / builder:config, every server:builder:* action,
// getMissionList and server:admin:opLaunch — builder_server.mock.ts, oversight.mock.ts and teams.mock.ts register
// the full versions, which win over these fallbacks.
//
// URL shortcuts (dev only):
//   &bopen=<missionId>&bstep=blocks|details|settings|locations|scaling|test|publish&bloc=<n>&bobj=<n>
//        open that mission in the builder (Supervisor: scope sup; Admin: Missions → Builder tab)
//   &bov=placement|placement_bad|recording|recording_wait|testdrive   show a static tool overlay
import { emitDebug, registerMock, request } from '../shared/nui';
import type { Session } from '../shared/types';
import type {
  BuilderClientResult, BuilderConfig, BuilderDefinition, BuilderListEntry, BuilderRecord, Vec, Vec3, Vec4,
} from '../types/builder_server';
import type {
  BuilderPlaceRequest, BuilderRecordRequest, BuilderStepKey, BuilderTestDriveRequest, BuilderToolOverlay,
} from '../types/builder_client';
import { setEditorMemory } from '../builder/store';

const params = typeof window !== 'undefined' ? new URLSearchParams(window.location.search) : new URLSearchParams();
const now = () => Math.floor(Date.now() / 1000);
const r2 = (n: number) => Math.round(n * 100) / 100;
const v3 = (x: number, y: number, z: number): Vec3 => ({ x: r2(x), y: r2(y), z: r2(z) });
const v4 = (x: number, y: number, z: number, w: number): Vec4 => ({ x: r2(x), y: r2(y), z: r2(z), w: r2(((w % 360) + 360) % 360) });
const DOCKS: Vec3 = { x: 1017.52, y: -3108.44, z: 5.9 };

// ── the Lua client, simulated ──────────────────────────────────────────────────────
let pending: (BuilderClientResult & { seq: number }) | null = null;
let seq = 0;
let running: { cancel: boolean } | null = null;

function overlay(o: BuilderToolOverlay | null, delay = 0) {
  emitDebug('overlay', { overlay: o as never }, delay);
}

async function reopen(ui: string | undefined) {
  const target = ui === 'admin' ? 'admin' : 'supervisor';
  const res = await request<Session>('getSession', { ui: target });
  if (res.ok && res.data) emitDebug('open', { ui: target, session: res.data });
}

function finish(result: BuilderClientResult, ui: string | undefined, at: number) {
  setTimeout(() => {
    seq += 1;
    pending = { ...result, seq };
    running = null;
    overlay(null);
    emitDebug('push', { topic: 'builder', data: { event: 'clientResult', id: result.missionId, result: pending } });
    void reopen(ui);
  }, at);
}

function begin(): { cancel: boolean } | null {
  if (running) return null;
  running = { cancel: false };
  emitDebug('close', {}, 60);
  return running;
}

function ring(c: Vec3, n: number, r: number, heading: boolean): Vec[] {
  return Array.from({ length: n }, (_, i) => {
    const a = (i / n) * Math.PI * 2 + 0.3;
    const x = c.x + Math.cos(a) * r;
    const y = c.y + Math.sin(a) * r;
    return heading ? v4(x, y, c.z + 1, (a * 180) / Math.PI + 90) : v3(x, y, c.z + 0.2);
  });
}

registerMock('client', 'builderPlace', (p: BuilderPlaceRequest) => {
  if (!p || typeof p.missionId !== 'string' || typeof p.key !== 'string') throw new Error('err.invalid_payload');
  const job = begin();
  if (!job) throw new Error('err.builder_busy');
  const start = p.start ?? DOCKS;
  const existing = Array.isArray(p.points) ? p.points : [];
  let points: Vec[];
  let radius: number | undefined;
  if (p.kind === 'start') {
    const others = Array.isArray(p.otherStarts) ? p.otherStarts : [];
    const base = others.length ? others[others.length - 1] : DOCKS;
    points = [others.length ? v3(base.x + 210 + others.length * 35, base.y + 160, base.z) : v3(base.x, base.y, base.z)];
    radius = typeof p.radius === 'number' ? p.radius : 60;
  } else if (p.multiple) {
    const want = Math.min(p.max ?? 40, Math.max(p.min ?? 1, existing.length + 3, 4));
    const r = p.spawn ? 46 : p.kind === 'vehicle' ? 120 : 18;
    points = ring(start, want, r, p.heading);
  } else {
    points = [p.heading ? v4(start.x + 42, start.y + 18, start.z + 1, 205) : v3(start.x + 42, start.y + 18, start.z + 0.3)];
  }
  const label = p.label ?? p.key;
  const max = p.multiple ? p.max ?? 40 : 1;
  const min = p.multiple ? p.min ?? 1 : 1;
  const frame = (placed: number, valid: boolean, reason?: string): BuilderToolOverlay => ({
    kind: 'placement', key: p.key, label, mode: p.kind, placed, min, max, multiple: !!p.multiple, valid,
    reason: reason ?? false, heading: p.heading ? 245 : false, radius: p.kind === 'start' || p.kind === 'area' ? radius ?? 60 : false,
  });
  const steps = Math.max(1, Math.min(points.length, 5));
  overlay(frame(0, false, 'Aim at the ground'), 200);
  for (let i = 1; i <= steps; i += 1) overlay(frame(Math.round((points.length * i) / steps), true), 200 + i * 450);
  overlay(frame(points.length, false, `Closer than ${30} m to the start`), 250 + (steps + 1) * 450);
  overlay(frame(points.length, true), 250 + (steps + 2) * 450);
  finish({ kind: 'placement', missionId: p.missionId, location: p.location, key: p.key, points, radius, cancelled: job.cancel }, p.ui, 400 + (steps + 3) * 450);
  return { started: true };
});

function sampleRoute(start: Vec3, loop: boolean): Vec3[] {
  const pts: Vec3[] = [];
  let x = start.x + 36;
  let y = start.y + 12;
  let h = 0.35;
  for (let i = 0; i < 16; i += 1) {
    pts.push(v3(x, y, start.z));
    if (i === 5) h += 1.25;
    if (i === 10) h -= 0.9;
    x += Math.cos(h) * 118;
    y += Math.sin(h) * 118;
  }
  if (loop) {
    const back = pts.slice(1, -1).reverse().map((p) => v3(p.x + 22, p.y - 26, p.z));
    return [...pts, ...back, v3(start.x + 44, start.y + 4, start.z)];
  }
  return pts;
}

registerMock('client', 'builderRecord', (p: BuilderRecordRequest) => {
  if (!p || typeof p.missionId !== 'string') throw new Error('err.invalid_payload');
  const job = begin();
  if (!job) throw new Error('err.builder_busy');
  const points = sampleRoute(DOCKS, !!p.loop);
  const length = Math.round(points.slice(1).reduce((s, q, i) => s + Math.hypot(q.x - points[i].x, q.y - points[i].y), 0));
  const label = p.label ?? p.key;
  const frame = (k: number, extra: Partial<BuilderToolOverlay> = {}): BuilderToolOverlay => ({
    kind: 'recording', key: p.key, label, length: Math.round((length * k) / 10), points: Math.max(1, Math.round((points.length * k) / 10)),
    samples: Math.round((length * k) / 10 / 25), stops: p.stops && k > 5 ? 1 : 0, maxStops: 5, stopsEnabled: !!p.stops, paused: false,
    offRoad: false, rejected: k > 3 ? 2 : 0, waiting: false, distance: false, loop: !!p.loop, toStart: p.loop ? Math.round(900 - k * 85) : false,
    zone: false, tooLong: false, minLength: 800, maxLength: 8000, message: false, ...extra,
  } as BuilderToolOverlay);
  overlay(frame(0, { waiting: 'vehicle' }), 200);
  for (let k = 1; k <= 10; k += 1) {
    const extra: Partial<BuilderToolOverlay> = k === 4 ? { offRoad: true } : k === 6 && p.stops ? { message: 'Stop point 1 added (20 s)' } : {};
    overlay(frame(k, extra), 300 + k * 320);
  }
  overlay(frame(10, { waiting: 'checking', message: 'Checking the road paths…' }), 300 + 11 * 320);
  finish({
    kind: 'recording', missionId: p.missionId, location: p.location, key: p.key, cancelled: job.cancel,
    route: { points, stops: p.stops ? [{ at: 7, wait: 20 }] : [], loop: p.loop || undefined },
    length, rejected: 2, rejectedSamples: [v3(DOCKS.x + 380, DOCKS.y + 190, 5.9), v3(DOCKS.x + 402, DOCKS.y + 196, 5.9)], unreachable: [],
  }, p.ui, 300 + 13 * 320);
  return { started: true };
});

registerMock('client', 'builderTestDrive', (p: BuilderTestDriveRequest) => {
  if (!p || typeof p.missionId !== 'string' || !p.route || !Array.isArray(p.route.points) || p.route.points.length < 2) throw new Error('err.invalid_payload');
  const job = begin();
  if (!job) throw new Error('err.builder_busy');
  const total = p.route.points.length;
  const failed = total > 6 ? [Math.min(total - 1, 4)] : [];
  const label = p.label ?? p.key;
  const frame = (waypoint: number, extra: Partial<BuilderToolOverlay> = {}): BuilderToolOverlay => ({
    kind: 'testdrive', key: p.key, label, waypoint, total, failed: failed.filter((f) => f < waypoint), timeLeft: 22, stopLeft: false,
    waiting: false, distance: false, speed: p.speed, done: false, ...extra,
  } as BuilderToolOverlay);
  overlay(frame(1, { waiting: 'approach', distance: 640 }), 200);
  overlay(frame(1, { waiting: 'spawning' }), 700);
  const steps = Math.min(total, 8);
  for (let i = 1; i <= steps; i += 1) overlay(frame(Math.max(2, Math.round((total * i) / steps)), { timeLeft: 30 - i * 2 }), 900 + i * 350);
  overlay(frame(total, { done: true, timeLeft: false, failed }), 1000 + (steps + 1) * 350);
  finish({ kind: 'testdrive', missionId: p.missionId, location: p.location, key: p.key, completed: true, failed, cancelled: job.cancel }, p.ui, 1000 + (steps + 3) * 350);
  return { started: true };
});

registerMock('client', 'builderResult', () => {
  const r = pending;
  pending = null;
  return r;
});

registerMock('client', 'builderCancel', () => {
  if (!running) return { cancelled: false };
  running.cancel = true;
  return { cancelled: true };
});

registerMock('client', 'builderWaypoint', (p: { coords?: Vec3 }) => {
  if (!p || !p.coords || typeof p.coords.x !== 'number') throw new Error('err.invalid_payload');
  return { ok: true };
});

// ── server actions the builder screens call that other mocks do not cover ─────────────
registerMock('action', 'server:test:record', (p: { missionId?: string; location?: number; tier?: string; result?: string; note?: string }) => {
  if (!p || typeof p.missionId !== 'string' || !Number.isInteger(p.location) || (p.result !== 'passed' && p.result !== 'failed')) throw new Error('err.invalid_payload');
  setTimeout(() => emitDebug('push', { topic: 'builder', data: { event: 'tested', id: p.missionId } }), 300);
  return { id: Date.now(), missionId: p.missionId, location: p.location, tier: p.tier ?? 'heavy', result: p.result, draft: true };
});

registerMock('action', 'server:admin:reloadMissions', () => ({
  loaded: 16, builtin: 14, custom: 2, warnings: 1,
  failed: [{ id: 'custom_vinewood_stakeout', file: 'missions/custom/custom_vinewood_stakeout.lua', error: 'objective 1 (flee_arrest): responses must add up to 100 %' }],
}));

// ── fallbacks (the builder_server / oversight / teams mocks register the full versions) ──
const FB_CONFIG: BuilderConfig = {
  enabled: true,
  blocks: {
    details: { difficulty: [1, 3, 2], officers: [1, 4], timeLimit: [120, 1200, 600], startTimeout: [300, 900, 600], cooldown: [300, 3600, 1200], vehiclePenalties: { default: true } },
    hostile_waves: { waves: [1, 6, 3], perWave: [1, 15, 7], nextWaveAlive: [0, 5, 2], nextWaveAfter: [30, 300, 90], weapons: ['WEAPON_PISTOL', 'WEAPON_MICROSMG'], accuracy: [5, 60, 25], armour: [0, 100, 0], health: [100, 400, 200], behaviour: { options: ['hold', 'balanced', 'push'], default: 'balanced' }, surrender: [0, 100, 30], peds: ['g_m_y_ballaeast_01', 'g_m_y_famca_01'], boss: { default: false }, blockTraffic: [0, 200, 120], spawnPointsPerHostile: 1.5, presenceRange: [50, 800, 150] },
    interact_points: { points: [1, 10], use: { options: ['all', 'random'], default: 'all' }, progress: [1, 30, 5], label: 'Checking…', animation: 'clipboard', logResult: { default: false }, logChoices: [2, 4, 2], presenceRange: [50, 800, 150] },
  },
  blockList: [
    { id: 'hostile_waves', labelKey: 'builder.block.hostile_waves', available: true, minSeconds: 60, presenceRange: [50, 800, 150] },
    { id: 'interact_points', labelKey: 'builder.block.interact_points', available: true, minSeconds: 5, presenceRange: [50, 800, 150] },
  ],
  allowed: { weapons: ['WEAPON_PISTOL', 'WEAPON_MICROSMG', 'WEAPON_SMG'], peds: ['g_m_y_ballaeast_01', 'g_m_y_famca_01', 'a_m_m_business_01'], vehicles: ['sultan', 'buffalo'], escortVehicles: ['stockade'], animations: ['clipboard', 'search'] },
  maxHostiles: 40, maxBlocks: 6, minLocations: 3, maxLocations: 20, minLocationGap: 100, minSpawnFromStart: 30,
  bonusCap: { points: 50, pct: 25 },
  bonuses: [
    { id: 'no_participant_downed', kind: 'pct', value: 10, each: false, block: null, penalty: false, labelKey: 'bonus.no_participant_downed' },
    { id: 'hostile_arrested', kind: 'points', value: 5, each: true, block: 'hostile_waves', penalty: false, labelKey: 'bonus.hostile_arrested' },
    { id: 'wrong_log', kind: 'points', value: -5, each: true, block: 'interact_points', penalty: true, labelKey: 'penalty.wrong_log' },
  ],
  noBuildZones: [{ label: 'Mission Row PD and FIB HQ', coords: { x: 470.63, y: -974.11, z: 30.18 }, radius: 120 }],
  departments: [{ key: 'fib', label: 'Federal Investigation Bureau', short: 'FIB' }, { key: 'sast', label: 'San Andreas State Troopers', short: 'SAST' }],
  missionTypes: [{ key: 'patrol', label: 'Patrol', points: 60 }, { key: 'tactical', label: 'Tactical', points: 200 }],
  tiers: [
    { name: 'standard', labelKey: 'tier.standard', maxParticipants: 1 }, { name: 'reinforced', labelKey: 'tier.reinforced', maxParticipants: 2 },
    { name: 'heavy', labelKey: 'tier.heavy', maxParticipants: 4 }, { name: 'major', labelKey: 'tier.major', maxParticipants: 6 },
    { name: 'critical', labelKey: 'tier.critical', maxParticipants: 8 },
  ],
  autosaveSeconds: 30, editLockMinutes: 30, testAtMaxTier: true, keepBackups: true, exportPath: 'missions/custom/',
  route: { snapEvery: 25, maxOffRoad: 8, turnAngle: 30, maxGap: 150, minLength: 800, maxLength: 8000, minStartEndGap: 300, loopClose: 50, undoMetres: 100, testDriveTimeout: 30 },
  startRadius: [20, 150, 60], maxItems: 10, itemCount: [1, 100], maxScaling: 20,
  limits: { label: 64, description: 500, objectiveLabel: 64, locationLabel: 64 },
  percentFields: { hostile_waves: ['surrender.chance', 'boss.surrender.chance'] }, secondsFields: { interact_points: ['progress.duration'] },
  spawnFields: { hostile_waves: ['spawns', 'boss.spawn'] }, forbiddenItems: ['armour', 'bandage', 'ammo-*', 'weapon_*'],
  useStartRoute: false,
  permissions: { builderEdit: true, builderEditAny: false, builderPublish: true, builderArchive: true, builderRollback: false, breakEditLock: false },
};

const fbDef = (id: string, label: string): BuilderDefinition => ({
  id, label, description: 'A crew is holed up at the docks.', type: 'tactical', departments: [], minOfficers: 2, maxOfficers: 4, difficulty: 3,
  timeLimit: 720, startTimeout: 600, cooldown: 1200, vehiclePenalties: false,
  locations: [{ label: 'Dock 1', start: { coords: DOCKS, radius: 60 }, spawns: ring(DOCKS, 11, 46, true) as Vec4[] }],
  objectives: [{ block: 'hostile_waves', label: 'Clear the dock', minSeconds: 45, presenceRange: 150, spawns: 'spawns', waves: [6, 6] }],
  scaling: ['objectives.1.waves'], items: [], bonuses: [{ id: 'no_participant_downed', pct: 10 }], penalties: [],
});
const fbStore = new Map<string, BuilderDefinition>([['custom_dock_raid', fbDef('custom_dock_raid', 'Dock Raid')]]);
const fbCan = { edit: true, publish: true, archive: false, restore: false, rollback: false, breakLock: false, discard: true };
const fbEntry = (id: string): BuilderListEntry => {
  const d = fbStore.get(id)!;
  return {
    id, label: d.label, type: d.type, source: 'custom', status: 'draft', dbStatus: 'draft', version: null, draftVersion: 1, hasDraft: true,
    draftTested: false, editedInCode: false, filePath: null, owner: { citizenid: 'ABC12345', name: 'John Doe', mine: true },
    updatedBy: { citizenid: 'ABC12345', name: 'John Doe' }, updatedAt: now() - 300, lock: { citizenid: 'ABC12345', name: 'John Doe', secondsLeft: 1500, mine: true },
    requiredTier: 'heavy', can: fbCan,
  };
};
const fbRecord = (id: string): BuilderRecord => ({
  ...fbEntry(id), definition: fbStore.get(id)!, publishedDefinition: null, readOnly: false, errors: [], armed: 12, backups: [], publishedAt: null, publishedBy: null,
});
const need = (id: unknown) => {
  if (typeof id !== 'string' || !fbStore.has(id)) throw new Error('err.builder_unknown_mission');
  return id;
};

registerMock('request', 'builder:config', () => FB_CONFIG, { fallback: true });
registerMock('request', 'builder:list', () => ({ missions: [...fbStore.keys()].map(fbEntry), builtins: [], me: 'ABC12345', serverTime: now() }), { fallback: true });
registerMock('request', 'builder:get', (a: { id?: string }) => fbRecord(need(a?.id)), { fallback: true });
registerMock('action', 'server:builder:create', (p: { type?: string; label?: string }) => {
  const id = `custom_${(p?.label || 'new_mission').toLowerCase().replace(/[^a-z0-9]+/g, '_')}`;
  fbStore.set(id, { ...fbDef(id, p?.label || 'New mission'), objectives: [], scaling: [], type: p?.type ?? 'patrol' });
  return { id, record: fbRecord(id) };
}, { fallback: true });
registerMock('action', 'server:builder:duplicate', (p: { id?: string }) => {
  const src = fbStore.get(need(p?.id))!;
  const id = `${src.id}_copy`;
  fbStore.set(id, { ...src, id, label: `${src.label} (copy)` });
  return { id, record: fbRecord(id) };
}, { fallback: true });
registerMock('action', 'server:builder:lock', (p: { id?: string }) => ({ id: need(p?.id), lock: fbEntry(p!.id!).lock }), { fallback: true });
registerMock('action', 'server:builder:unlock', (p: { id?: string }) => ({ id: need(p?.id) }), { fallback: true });
const fbSave = (p: { id?: string; definition?: BuilderDefinition }, full: boolean) => {
  const id = need(p?.id);
  if (p.definition) fbStore.set(id, { ...p.definition, id });
  const base = { id, version: 1, savedAt: now(), draftTested: false, lock: fbEntry(id).lock };
  return full ? { ...base, previousId: null, valid: true, errors: [] } : base;
};
registerMock('action', 'server:builder:save', (p) => fbSave(p, true), { fallback: true });
registerMock('action', 'server:builder:autosave', (p) => fbSave(p, false), { fallback: true });
registerMock('action', 'server:builder:validate', (p: { id?: string }) => ({ valid: true, errors: [], armed: 12, maxHostiles: 40, requiredTier: need(p?.id) && 'heavy' }), { fallback: true });
registerMock('action', 'server:builder:test', (p: { id?: string; tier?: string; location?: number | 'random' }) => ({ id: need(p?.id), version: 1, tier: p.tier ?? 'heavy', location: p.location ?? 1, requiredTier: 'heavy' }), { fallback: true });
registerMock('action', 'server:builder:publish', (p: { id?: string }) => {
  throw new Error(need(p?.id) ? 'err.builder_not_tested' : 'err.invalid_payload');
}, { fallback: true });
for (const name of ['archive', 'restore', 'rollback', 'breakLock']) {
  registerMock('action', `server:builder:${name}`, (p: { id?: string }) => {
    need(p?.id);
    throw new Error(name === 'archive' || name === 'rollback' ? 'err.builder_not_published' : name === 'restore' ? 'err.builder_not_archived' : 'err.no_permission');
  }, { fallback: true });
}
registerMock('action', 'server:builder:discardDraft', (p: { id?: string }) => {
  const id = need(p?.id);
  fbStore.delete(id);
  return { id, deleted: true };
}, { fallback: true });
registerMock('request', 'getMissionList', () => ({ missions: [], canLaunch: true, crossDeptEnabled: true, operation: null }), { fallback: true });
registerMock('action', 'server:admin:opLaunch', () => ({ operationId: 1 }), { fallback: true });

// ── dev shortcuts ─────────────────────────────────────────────────────────────────
const STEPS: BuilderStepKey[] = ['blocks', 'details', 'settings', 'locations', 'scaling', 'test', 'publish'];
const openId = params.get('bopen');
if (openId) {
  const step = (STEPS.includes(params.get('bstep') as BuilderStepKey) ? params.get('bstep') : 'details') as BuilderStepKey;
  const patch = { openId, step, location: Number(params.get('bloc')) || 1, objective: Number(params.get('bobj')) || 1 };
  setEditorMemory(params.get('ui') === 'admin' ? 'admin' : 'sup', params.get('ui') === 'admin' ? { ...patch, tab: 'builder' } : patch);
}

const STATIC: Record<string, BuilderToolOverlay> = {
  placement: { kind: 'placement', key: 'spawns', label: 'Hostile spawn points', mode: 'ped', placed: 7, min: 9, max: 40, multiple: true, valid: true, reason: false, heading: 245, radius: false },
  placement_bad: { kind: 'placement', key: 'spawns', label: 'Hostile spawn points', mode: 'ped', placed: 7, min: 9, max: 40, multiple: true, valid: false, reason: 'Closer than 30 m to the start', heading: 245, radius: false },
  recording: { kind: 'recording', key: 'route', label: 'Escort route', length: 1420, points: 14, samples: 57, stops: 1, maxStops: 5, stopsEnabled: true, paused: false, offRoad: true, rejected: 3, waiting: false, distance: false, loop: false, toStart: false, zone: false, tooLong: false, minLength: 800, maxLength: 8000, message: 'Stop point 1 added (20 s)' },
  recording_wait: { kind: 'recording', key: 'raceLoop', label: 'Race loop', length: 2380, points: 22, samples: 95, stops: 0, maxStops: 5, stopsEnabled: false, paused: true, offRoad: false, rejected: 0, waiting: 'return', distance: 140, loop: true, toStart: 610, zone: false, tooLong: false, minLength: 800, maxLength: 8000, message: 'Undid 100 m' },
  testdrive: { kind: 'testdrive', key: 'route', label: 'Escort route', waypoint: 9, total: 24, failed: [4], timeLeft: 17, stopLeft: false, waiting: false, distance: false, speed: 60, done: false },
};
const bov = params.get('bov');
if (bov && STATIC[bov]) overlay(STATIC[bov], 700);
