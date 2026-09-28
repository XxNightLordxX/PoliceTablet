// Browser mocks for Admin test mode (admin/screens/Testing.tsx, hud/TestControls.tsx, hud/DebugOverlay.tsx).
// URL shortcuts (with ?ui=admin&screen=admin_testing for the screen, ?hud=test for the HUD):
//   testactive=1  a running test of mine        testdebug=1  debug overlay data (push 'test')
//   testfocus=1   the HUD panel has NUI focus   testprompt=1 the F9 invitation prompt
//   testinvite=0  no invitation banner for me    testempty=1  an empty test log (everything "Not tested")
//   testlong=1    edge cases: very long mission/location/player names and notes, a mission without locations
//   testlua=1     Lua-shaped replies: empty lists sent as {} objects, false for missing values
import { emitDebug, registerMock } from '../shared/nui';
import { MOCK_DEPARTMENTS, mockLocale } from './samples';
import type {
  TestActive, TestCandidate, TestDebugData, TestInvite, TestLobby, TestLobbyInvite, TestLocationRow, TestMissionRow,
  TestPendingRecord, TestsView, TestState,
} from '../types/testing';

const params = new URLSearchParams(typeof window !== 'undefined' ? window.location.search : '');
const now = () => Math.floor(Date.now() / 1000);
const TIERS = ['standard', 'reinforced', 'heavy', 'major', 'critical'];
const TIER_MAX = [1, 2, 4, 6, 8];
const tierFor = (n: number) => TIERS[TIER_MAX.findIndex((m) => m >= n)] ?? 'critical';
const MAX_TESTERS = 8;

// ── the catalog ───────────────────────────────────────────────────────────────

interface MockMission {
  id: string; label: string; type: string; typeLabel: string; source?: 'builtin' | 'custom'; version?: number;
  maxOfficers: number; minOfficers?: number; locations: string[]; isBoss?: boolean; status?: 'published' | 'archived';
  disabled?: boolean; editedInCode?: boolean;
}

const MISSIONS: MockMission[] = [
  { id: 'beat_patrol', label: 'Beat Patrol', type: 'patrol', typeLabel: 'Patrol', maxOfficers: 2, locations: ['Vespucci Canals', 'Mirror Park', 'Rockford Hills', 'Del Perro Pier', 'Little Seoul'] },
  { id: 'business_check', label: 'Business Check', type: 'patrol', typeLabel: 'Patrol', maxOfficers: 2, locations: ['Strawberry strip', 'Vinewood Blvd', 'Harmony', 'Paleto Bay', 'Sandy Shores'] },
  { id: 'evoc_course', label: 'EVOC Course', type: 'training', typeLabel: 'Training', maxOfficers: 1, locations: ['LSIA runway loop', 'Port of LS', 'Sandy airfield'] },
  { id: 'pursuit_sim', label: 'Pursuit Sim', type: 'training', typeLabel: 'Training', maxOfficers: 2, locations: ['Downtown grid', 'Great Ocean Hwy', 'Senora Fwy', 'Elysian Island', 'Vinewood Hills'] },
  { id: 'street_race_bust', label: 'Street Race Bust', type: 'training', typeLabel: 'Training', maxOfficers: 3, locations: ['La Mesa', 'Cypress Flats', 'Murrieta Heights', 'El Burro', 'Banning'] },
  { id: 'manhunt', label: 'Manhunt', type: 'investigation', typeLabel: 'Investigation', maxOfficers: 4, locations: ['Mount Chiliad', 'Raton Canyon', 'Grapeseed fields', 'Tongva Hills', 'Zancudo marsh'] },
  { id: 'stolen_vehicle_takedown', label: 'Stolen Vehicle Takedown', type: 'investigation', typeLabel: 'Investigation', maxOfficers: 3, locations: ['Legion Square', 'Pillbox Hill', 'Textile City', 'Hawick', 'Burton'] },
  { id: 'warrant_service', label: 'Warrant Service', type: 'investigation', typeLabel: 'Investigation', maxOfficers: 4, locations: ['Grove Street', 'Stab City', 'Mirror Park bungalow', 'Chamberlain Hills', 'Davis motel'] },
  { id: 'armored_truck_escort', label: 'Armored Truck Escort', type: 'tactical', typeLabel: 'Tactical', maxOfficers: 4, locations: ['Union Depository run', 'Fleeca highway run', 'Paleto bank run'] },
  { id: 'bomb_disposal', label: 'Bomb Disposal', type: 'tactical', typeLabel: 'Tactical', maxOfficers: 4, locations: ['Legion plaza', 'Maze Bank Arena', 'Del Perro mall', 'Vinewood Bowl', 'LSIA terminal'] },
  { id: 'gang_shootout', label: 'Gang Shootout', type: 'tactical', typeLabel: 'Tactical', maxOfficers: 4, locations: ['Hideout A · Rancho', 'Hideout B · Elysian', 'Hideout C · La Puerta', 'Hideout D · Strawberry', 'Hideout E · Cypress'] },
  { id: 'hostage_rescue', label: 'Hostage Rescue', type: 'tactical', typeLabel: 'Tactical', maxOfficers: 4, locations: ['Fleeca Great Ocean', 'Vanilla Unicorn', 'Pacific Bluffs club', 'Mirror Park diner', 'Paleto sheriff'] },
  { id: 'prison_break', label: 'Prison Break', type: 'tactical', typeLabel: 'Tactical', maxOfficers: 4, locations: ['North wall', 'East yard', 'Sewer outflow', 'Transport ambush', 'Visitor lot'], disabled: true },
  { id: 'weekly_boss_kingpin', label: 'Weekly Boss: Kingpin', type: 'tactical', typeLabel: 'Tactical', maxOfficers: 4, locations: ['Vinewood mansion', 'Cayo freighter', 'Sandy compound'], isBoss: true },
  { id: 'custom_dockside_raid', label: 'Dockside Raid', type: 'tactical', typeLabel: 'Tactical', source: 'custom', version: 3, maxOfficers: 4, minOfficers: 2, locations: ['Dock 1', 'Dock 4', 'Pier 400'], editedInCode: true },
  { id: 'custom_harbor_sweep', label: 'Harbor Sweep', type: 'investigation', typeLabel: 'Investigation', source: 'custom', version: 1, maxOfficers: 2, locations: ['Terminal A', 'Terminal B', 'Elysian cranes'], status: 'archived' },
];

if (params.get('testlong') === '1') {
  MISSIONS.unshift({
    id: 'custom_extremely_long_mission_identifier_x', label: 'Operation Midnight Harbour Container Terminal Sweep and Clear (Extended Night Shift Edition)',
    type: 'investigation', typeLabel: 'Investigation', source: 'custom', version: 12, maxOfficers: 4,
    locations: ['Elysian Island container terminal north gate by the big blue crane next to the rail yard', 'Terminal B'],
  });
  MISSIONS.push({ id: 'custom_no_locations', label: 'Broken draft copy', type: 'patrol', typeLabel: 'Patrol', source: 'custom', version: 1, maxOfficers: 1, locations: [] });
}

const TESTERS = [
  { cid: 'ADM00001', name: 'Alex Mercer' },
  { cid: 'ABC12345', name: 'John Doe' },
  { cid: 'FIB00042', name: 'Dana Whitfield' },
];

if (params.get('testlong') === '1') TESTERS.push({ cid: 'LONG0001', name: 'Maximilian Alexander Montgomery-Worthington III' });

const NOTES = [
  ...(params.get('testlong') === '1' ? ['Spawn points 3, 4 and 7 are inside the warehouse wall and the second wave never spawns because the armed cap is reached by the first wave staying alive behind the containers'] : []),
  'spawn 3 is inside a wall', 'Wave 2 spawns too close to the start', 'Truck gets stuck at the Fleeca ramp', 'Checkpoint 7 is off the road', 'Hostage 2 clips through the counter'];

// Deterministic "random" so every load looks the same.
let seed = 7;
const rnd = () => {
  seed = (seed * 16807) % 2147483647;
  return seed / 2147483647;
};

const empty = params.get('testempty') === '1';

function buildLocations(m: MockMission): TestLocationRow[] {
  return m.locations.map((label, i) => {
    const r = rnd();
    let last: TestLocationRow['last'] = false;
    let status: TestLocationRow['status'] = 'untested';
    if (!empty && r > 0.22) {
      const failed = r > 0.86;
      const changed = !failed && (m.editedInCode || (r > 0.72 && r < 0.8));
      const who = TESTERS[Math.floor(rnd() * TESTERS.length)];
      const testers = 1 + Math.floor(rnd() * Math.min(4, m.maxOfficers));
      last = {
        id: 100 + i, result: failed ? 'failed' : 'passed', tier: tierFor(m.maxOfficers), testers,
        note: failed ? NOTES[Math.floor(rnd() * NOTES.length)] : rnd() > 0.7 ? 'All good, NPCs behave' : false,
        testedBy: who.cid, testedByName: who.name, testedAt: now() - Math.floor(rnd() * 9 * 86400) - 600,
        version: m.source === 'custom' ? Math.max(1, (m.version ?? 1) - (changed ? 1 : 0)) : false,
        changed, tests: 1 + Math.floor(rnd() * 3),
      };
      status = changed ? 'changed' : failed ? 'failed' : 'passed';
    }
    return { index: i + 1, label, reserved: m.id === 'beat_patrol' && i === 1, active: false, status, last };
  });
}

const catalog: TestMissionRow[] = MISSIONS.map((m) => {
  const locations = buildLocations(m);
  return {
    id: m.id, label: m.label, type: m.type, typeLabel: m.typeLabel, source: m.source ?? 'builtin', status: m.status ?? 'published',
    disabled: !!m.disabled, isBoss: !!m.isBoss, version: m.version ?? false, minOfficers: m.minOfficers ?? 1, maxOfficers: m.maxOfficers,
    maxTier: tierFor(m.maxOfficers), defHash: 'a1b2c3d4', editedInCode: !!m.editedInCode, locations,
    summary: { passed: 0, failed: 0, untested: 0, changed: 0 },
  };
});

function summarise(): TestsView {
  const totals = { missions: catalog.length, locations: 0, passed: 0, failed: 0, untested: 0, changed: 0 };
  catalog.forEach((m) => {
    m.summary = { passed: 0, failed: 0, untested: 0, changed: 0 };
    m.locations.forEach((l) => {
      m.summary[l.status] += 1;
      totals[l.status] += 1;
      totals.locations += 1;
      l.active = !!state.active && state.active.missionId === m.id && state.active.locationIndex === l.index;
    });
  });
  return {
    missions: catalog, totals,
    tiers: TIERS.map((name, i) => ({ name, label: name[0].toUpperCase() + name.slice(1), maxParticipants: TIER_MAX[i] })),
    config: { enabled: true, maxTesters: MAX_TESTERS, useStartRoute: false, allowTeleport: true, debugOverlay: true },
    serverTime: now(),
  };
}

// ── players ───────────────────────────────────────────────────────────────────

const CANDIDATES: TestCandidate[] = [
  { src: 12, name: 'John Doe', callsign: '2L-14', rank: 'Sergeant', departmentShort: 'SAST', role: 'officer', admin: false, onRun: false, inArena: false, invite: false },
  { src: 15, name: 'Maria Lopez', callsign: '2L-21', rank: 'Trooper', departmentShort: 'SAST', role: 'officer', admin: false, onRun: false, inArena: false, invite: false },
  { src: 9, name: 'Dana Whitfield', callsign: false, rank: 'Special Agent', departmentShort: 'FIB', role: 'officer', admin: false, onRun: false, inArena: false, invite: false },
  { src: 21, name: 'Ray Chen', callsign: '4A-02', rank: 'Agent', departmentShort: 'FIB', role: 'officer', admin: false, onRun: true, inArena: false, invite: false },
  { src: 33, name: 'Sam Porter', callsign: false, rank: 'Admin', departmentShort: 'FIB', role: 'admin', admin: true, onRun: false, inArena: false, invite: false },
  { src: 41, name: 'Tess Okafor', callsign: '2L-30', rank: 'Corporal', departmentShort: 'SAST', role: 'officer', admin: false, onRun: false, inArena: true, invite: false },
  { src: 44, name: 'Victor Hale', callsign: '1A-09', rank: 'Lieutenant', departmentShort: 'SAST', role: 'officer', admin: true, onRun: false, inArena: false, invite: false },
];

// ── my test state ─────────────────────────────────────────────────────────────

const state: { lobby: TestLobby; active: TestActive | null; pending: TestPendingRecord[]; invites: TestInvite[] } = {
  lobby: { missionId: false, missionLabel: false, draft: false, invites: [], accepted: 0, maxTesters: MAX_TESTERS },
  active: null,
  pending: [
    {
      key: 'run-pend-1', missionId: 'gang_shootout', missionLabel: 'Gang Shootout', locationIndex: 2, locationLabel: 'Hideout B · Elysian',
      tier: 'heavy', testers: 3, endState: 'completed', endReason: 'completed', endedBy: false, endedAt: now() - 240, draft: false,
    },
  ],
  invites: params.get('testinvite') === '0' ? [] : [
    { inviteId: 'ti7', missionId: 'hostage_rescue', missionLabel: 'Hostage Rescue', from: 'Sam Porter', fromCallsign: false, expiresIn: 96 },
  ],
};

function activeFor(missionId: string, locationIndex: number, tier: string, testers: { src: number; name: string; departmentShort: string | false; callsign: string | false }[], route: boolean): TestActive {
  const m = catalog.find((x) => x.id === missionId) ?? catalog[0];
  const loc = m.locations[locationIndex - 1] ?? m.locations[0];
  return {
    runId: `test-${missionId}-${Date.now()}`, missionId: m.id, missionLabel: m.label, locationIndex: loc.index, locationLabel: loc.label,
    state: 'in_progress', tier, forcedTier: tier, useStartRoute: route, draft: false, startedAt: now() - 95,
    remaining: 412, paused: false, objective: { index: 2, total: 4, label: 'Neutralise the hostiles', status: 'active' },
    participants: [
      { src: 1, name: 'Alex Mercer', callsign: false, departmentShort: 'SAST', status: 'active', arrived: true },
      ...testers.map((x) => ({ src: x.src, name: x.name, callsign: x.callsign, departmentShort: x.departmentShort, status: 'active', arrived: true })),
    ],
    debug: false, allowTeleport: true, debugOverlay: true,
  };
}

if (params.get('testactive') === '1') {
  state.active = activeFor('bomb_disposal', 1, 'critical', [
    { src: 12, name: 'John Doe', departmentShort: 'SAST', callsign: '2L-14' },
    { src: 9, name: 'Dana Whitfield', departmentShort: 'FIB', callsign: false },
  ], false);
  state.active.objective = { index: 3, total: 4, label: 'Disarm the devices', status: 'active' };
  state.active.remaining = 318;
  state.active.paused = true;
  state.active.participants.push({ src: 15, name: 'Maria Lopez', callsign: '2L-21', departmentShort: 'SAST', status: 'left', arrived: true });
}

function lobbyCount() {
  state.lobby.accepted = state.lobby.invites.filter((i) => i.status === 'accepted').length;
}

function pushState() {
  emitDebug('push', { topic: 'test', data: { state: true } });
}
function pushInvites() {
  emitDebug('push', { topic: 'invites', data: { test: true } });
}

function endActive(endState: TestPendingRecord['endState'], endedBy: TestPendingRecord['endedBy']) {
  const a = state.active;
  if (!a) return;
  state.pending.unshift({
    key: a.runId, missionId: a.missionId, missionLabel: a.missionLabel, locationIndex: a.locationIndex, locationLabel: a.locationLabel,
    tier: a.tier, testers: a.participants.length, endState, endReason: endState === 'completed' ? 'completed' : 'mission_failed',
    endedBy, endedAt: now(), draft: a.draft,
  });
  state.active = null;
  emitDebug('push', { topic: 'test', data: { controls: false, debug: false } });
  pushState();
}

// ── debug sample ──────────────────────────────────────────────────────────────

export function sampleDebug(): TestDebugData {
  return {
    runId: 'test-bomb-1', missionId: 'bomb_disposal', missionLabel: 'Bomb Disposal', locationIndex: 1, locationLabel: 'Legion plaza',
    state: 'in_progress', tier: 'critical',
    objective: { index: 3, total: 4, label: 'Disarm the devices', block: 'skill_check', status: 'active' },
    counts: { entities: 67, maxEntities: 80, armedAlive: 21, maxArmedAlive: 25, peds: 38, vehicles: 9, objects: 20, dead: 6 },
    spawnPoints: 26, waypoints: 42, zones: 3, startRadius: 80, host: 1, hostName: 'Alex Mercer', remaining: 318, paused: true, at: now(),
  };
}

// ── registrations ─────────────────────────────────────────────────────────────

registerMock('request', 'admin:getTests', () => summarise());

registerMock('request', 'test:state', (): TestState => {
  lobbyCount();
  return {
    lobby: { ...state.lobby, invites: [...state.lobby.invites] },
    active: state.active ?? false,
    pending: state.pending,
    invites: state.invites,
    serverTime: now(),
  };
});

registerMock('request', 'test:candidates', () =>
  CANDIDATES.map((c) => {
    const inv = state.lobby.invites.find((i) => i.src === c.src);
    return { ...c, invite: inv ? inv.status : false };
  }),
);

registerMock('request', 'test:pendingInvites', () => state.invites);

registerMock('action', 'server:test:invite', (p: { missionId: string; targets: number[] }) => {
  const m = catalog.find((x) => x.id === p?.missionId);
  if (!m) throw new Error('err.test_unknown_mission');
  if (state.lobby.missionId !== m.id) state.lobby = { missionId: m.id, missionLabel: m.label, draft: false, invites: [], accepted: 0, maxTesters: MAX_TESTERS };
  const skipped: { src: number; error: string }[] = [];
  const added: TestLobbyInvite[] = [];
  (p.targets ?? []).forEach((src, i) => {
    const c = CANDIDATES.find((x) => x.src === src);
    if (!c) return skipped.push({ src, error: 'err.test_player_offline' });
    if (c.inArena) return skipped.push({ src, error: 'err.in_arena' });
    if (c.onRun) return skipped.push({ src, error: 'err.test_player_busy' });
    const inv: TestLobbyInvite = {
      inviteId: `ti${100 + state.lobby.invites.length + i}`, src, name: c.name, callsign: c.callsign || null,
      departmentShort: c.departmentShort || null, rank: c.rank || null, role: c.role, status: 'pending', expiresIn: 120,
    };
    state.lobby.invites.push(inv);
    added.push(inv);
  });
  // Simulate answers: the first invitee accepts after 1.5 s, the second after 3 s.
  added.forEach((inv, i) => {
    setTimeout(() => {
      inv.status = i === 2 ? 'declined' : 'accepted';
      pushInvites();
    }, 1500 * (i + 1));
  });
  lobbyCount();
  return { lobby: state.lobby, skipped };
});

registerMock('action', 'server:test:cancelInvites', () => {
  state.lobby = { missionId: false, missionLabel: false, draft: false, invites: [], accepted: 0, maxTesters: MAX_TESTERS };
  return state.lobby;
});

registerMock('action', 'server:testRespond', (p: { inviteId: string; accepted: boolean }) => {
  const inv = state.invites.find((i) => i.inviteId === p?.inviteId);
  if (!inv) throw new Error('err.test_invite_gone');
  state.invites = state.invites.filter((i) => i !== inv);
  pushInvites();
  return { inviteId: inv.inviteId, status: p.accepted ? 'accepted' : 'declined' };
});

registerMock('action', 'server:admin:startTest', (p: { missionId: string; location: number | 'random'; tier?: string; useStartRoute: boolean; testers: number[] }) => {
  if (state.active) throw new Error('err.test_already_running');
  const m = catalog.find((x) => x.id === p?.missionId);
  if (!m) throw new Error('err.test_unknown_mission');
  const free = m.locations.filter((l) => !l.reserved);
  const loc = p.location === 'random' ? free[Math.floor(Math.random() * free.length)] : m.locations[Number(p.location) - 1];
  if (!loc) throw new Error('err.no_location');
  if (loc.reserved) throw new Error('err.test_location_busy');
  const testers = (p.testers ?? []).map((src) => {
    const c = CANDIDATES.find((x) => x.src === src);
    return { src, name: c?.name ?? `#${src}`, departmentShort: c?.departmentShort ?? false, callsign: c?.callsign ?? false };
  });
  const tier = p.tier ?? tierFor(testers.length + 1);
  state.active = activeFor(m.id, loc.index, tier, testers, !!p.useStartRoute);
  state.lobby = { missionId: false, missionLabel: false, draft: false, invites: [], accepted: 0, maxTesters: MAX_TESTERS };
  setTimeout(pushState, 50);
  return { runId: state.active.runId, missionId: m.id, locationIndex: loc.index, tier, testers: testers.length + 1 };
});

registerMock('action', 'server:admin:recordTest', (p: { missionId: string; location: number; tier?: string; result: 'passed' | 'failed'; note?: string }) => {
  const idx = state.pending.findIndex((e) => e.missionId === p?.missionId && e.locationIndex === p.location);
  if (idx < 0) throw new Error('err.test_not_run');
  const e = state.pending[idx];
  state.pending.splice(idx, 1);
  const m = catalog.find((x) => x.id === e.missionId);
  const loc = m?.locations[e.locationIndex - 1];
  if (loc) {
    loc.last = {
      id: Date.now(), result: p.result, tier: e.tier, testers: e.testers, note: p.note || false, testedBy: 'ADM00001',
      testedByName: 'Alex Mercer', testedAt: now(), version: m?.version ?? false, changed: false, tests: (loc.last ? loc.last.tests : 0) + 1,
    };
    loc.status = p.result;
  }
  setTimeout(pushState, 50);
  return { id: Date.now(), missionId: e.missionId, location: e.locationIndex, tier: e.tier, result: p.result, draft: e.draft };
});

registerMock('action', 'server:test:control', (p: { control: string }) => ({ control: p?.control }));

registerMock('client', 'testControl', (p: { control: string }) => {
  const a = state.active;
  const c = p?.control;
  if (c === 'complete') {
    endActive('completed', false);
    return { control: c };
  }
  if (c === 'fail') {
    endActive('failed', 'fail');
    return { control: c };
  }
  if (c === 'end') {
    endActive('failed', 'end');
    return { control: c };
  }
  if (a && (c === 'pause' || c === 'resume')) a.paused = c === 'pause';
  if (a && c === 'skip' && a.objective) a.objective = { ...a.objective, index: Math.min(a.objective.total, a.objective.index + 1) };
  return { control: c, paused: a?.paused ?? false };
});

registerMock('client', 'teleport', (p: { target?: string }) => ({ target: p?.target ?? 'start' }));

registerMock('client', 'toggleDebug', (p: { enabled?: boolean }) => {
  const on = typeof p?.enabled === 'boolean' ? p.enabled : !(state.active?.debug ?? false);
  if (state.active) state.active.debug = on;
  emitDebug('push', { topic: 'test', data: { controls: true, debugOn: on, debug: on ? sampleDebug() : false } });
  return { debug: on };
});

registerMock('client', 'testPanel', (p: { open?: boolean }) => {
  const open = !!p?.open;
  emitDebug('push', { topic: 'test', data: { controls: true, focused: open, key: 'F9', prompt: false } });
  return { focused: open };
});

// ── URL shortcuts for the HUD pieces ──────────────────────────────────────────
// In game the HUD gets the full locale with the login 'theme' message; in the browser the HUD alone only
// has the bundled ui.json fallback, so these shortcuts send the merged mock locale the same way.
const hudShortcut = ['testdebug', 'testfocus', 'testprompt'].some((k) => params.get(k) === '1') || params.get('hud') === 'test';
if (hudShortcut && !params.get('ui')) emitDebug('theme', { theme: MOCK_DEPARTMENTS.sast.theme, locale: mockLocale }, 500);

if (params.get('testdebug') === '1' || params.get('testfocus') === '1') {
  emitDebug('push', {
    topic: 'test',
    data: {
      controls: true, focused: params.get('testfocus') === '1', key: 'F9', runId: 'test-bomb-1',
      debugOn: params.get('testdebug') === '1', debug: params.get('testdebug') === '1' ? sampleDebug() : false,
    },
  }, 900);
}
if (params.get('testprompt') === '1') {
  emitDebug('push', {
    topic: 'test',
    data: {
      controls: false, focused: true, key: 'F9',
      prompt: {
        invites: [
          { inviteId: 'ti7', missionId: 'hostage_rescue', missionLabel: 'Hostage Rescue', from: 'Sam Porter', fromCallsign: false, expiresIn: 96 },
          { inviteId: 'ti8', missionId: 'gang_shootout', missionLabel: 'Gang Shootout', from: 'Victor Hale', fromCallsign: '1A-09', expiresIn: 41 },
        ],
      },
    },
  }, 900);
}
