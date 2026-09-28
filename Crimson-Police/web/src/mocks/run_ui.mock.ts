// Browser mocks of the run_ui slice (Mission Board + Active Mission): getMissionTypes, getRun (overrides
// core.mock.ts's fallback), server:acceptType, server:joinOperation, server:abandon and the client actions
// setGps, recalcRoute and logResult. Lua side effects are faked the way the game does them: 'board' /
// 'operation' / 'run' pushes, the route toasts from modules/route, the run.accepted toast and the result card.
//
// URL variants (screenshots and manual checks):
//   ?board=normal (default) | unit | member | locked | busy | oncall | boss | bossused
//          | operation | opjoined | oprunning | opwaiting | empty | error
//   ?runv=none | accepted | offroute | progress | test | log | silence | boss
//          (default: none, or progress while the dev panel's "run" toggle / ?run=1 is on)
// A type accepted in browser mode starts a simulated run: accepted → In progress after ~10 s → the
// objectives advance every few seconds → completed (result card). Abandon puts the type on cooldown.
import { emitDebug, registerMock } from '../shared/nui';
import type { RunResult } from '../shared/types';
import type {
  AbandonResult, AcceptTypeResult, ActiveMissionData, BoardOperation, BossCard, JoinOperationResult, MissionBoardData,
  RecalcRouteResult, RunObjective, RunPartner, SetGpsResult, TypeCard,
} from '../types/run_ui';
import { devState } from './devState';
import { MOCK_DEPARTMENTS, mockLocale } from './samples';

const params = typeof window !== 'undefined' ? new URLSearchParams(window.location.search) : new URLSearchParams();
const boardVariant = params.get('board') ?? 'normal';
const runVariant = params.get('runv');

const nowS = () => Math.floor(Date.now() / 1000);
const BOSS_KEY = 'weekly_boss';
const ME_SRC = 12;
const MAX_RECALCS = 2;
const ABANDON_COOLDOWN = 300;
const OP_MAX = 8;

/** CP.L in browser mode: the merged locale parts with {var} placeholders. */
function L(key: string, vars: Record<string, string | number> = {}): string {
  const s = mockLocale[key] ?? key;
  return s.replace(/\{([A-Za-z0-9_]+)\}/g, (whole, name: string) => (vars[name] === undefined ? whole : String(vars[name])));
}

function notify(kind: 'info' | 'success' | 'warning' | 'error', text: string, delay = 60) {
  emitDebug('notify', { notification: { id: `run_ui-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`, kind, text, duration: 5000 } }, delay);
}

function push(topic: 'run' | 'board' | 'operation', data: unknown = null, delay = 60) {
  emitDebug('push', { topic, data }, delay);
}

// ── mission catalogue (only the mock draw sees it; the board never lists missions) ──

interface MockMission { id: string; label: string; description: string; timeLimit: number; objectives: string[]; area: string }
interface MockType { key: string; label: string; points: number; payout: number; missions: MockMission[] }

const TYPES: MockType[] = [
  {
    key: 'patrol', label: 'Patrol', points: 60, payout: 250,
    missions: [
      { id: 'beat_patrol', label: 'Beat Patrol', timeLimit: 480, area: 'Strawberry Ave · Strawberry',
        description: 'Patrol your district: drive to each checkpoint in order and hold inside its marker in a police vehicle for 10 seconds.',
        objectives: ['Patrol the checkpoints'] },
      { id: 'business_check', label: 'Business Check', timeLimit: 600, area: 'Innocence Blvd · Strawberry',
        description: 'Check the front doors of the businesses on your beat. Secure any door you find open and log every result on the tablet.',
        objectives: ['Check the business doors'] },
      { id: 'street_race_bust', label: 'Street Race Bust', timeLimit: 240, area: 'Elgin Ave · Pillbox Hill',
        description: 'Street racers are lapping a city loop. Intercept the race, stop the cars and detain every driver before the race ends.',
        objectives: ['Stop the racers', 'Detain every driver'] },
    ],
  },
  {
    key: 'training', label: 'Training', points: 100, payout: 350,
    missions: [
      { id: 'evoc_course', label: 'EVOC Course', timeLimit: 240, area: 'LSIA · Los Santos International',
        description: 'Emergency vehicle operations course: drive through every checkpoint in order in a police vehicle. Every contact costs 2 seconds.',
        objectives: ['Drive the course'] },
      { id: 'pursuit_sim', label: 'Pursuit Sim', timeLimit: 300, area: 'Great Ocean Hwy · Chumash',
        description: 'Pursuit training: a getaway driver flees along a set route. Stay within 150 m for a total of 3 minutes and never touch the car.',
        objectives: ['Follow the getaway car'] },
      { id: 'stolen_vehicle_takedown', label: 'Stolen Vehicle Takedown', timeLimit: 480, area: 'Mirror Park Blvd · Mirror Park',
        description: 'A stolen car was last seen in the area. Light it up, stop it with a PIT or box-in and take every suspect into custody.',
        objectives: ['Stop the stolen car', 'Arrest the suspects'] },
    ],
  },
  {
    key: 'investigation', label: 'Investigation', points: 160, payout: 600,
    missions: [
      { id: 'warrant_service', label: 'Warrant Service', timeLimit: 720, area: 'Grove Street · Davis',
        description: "A judge has signed an arrest warrant. Knock and announce at the suspect's house, take the suspect into custody, deal with any armed associates and search the property.",
        objectives: ['Serve the arrest warrant', 'Search the property'] },
      { id: 'manhunt', label: 'Manhunt', timeLimit: 720, area: 'Marina Dr · Sandy Shores',
        description: 'A fugitive is hiding somewhere in the search area. Check the clues to narrow the circle, then catch and cuff every fugitive. They are unarmed: bring them in alive.',
        objectives: ['Find the clues', 'Catch the fugitive'] },
    ],
  },
  {
    key: 'tactical', label: 'Tactical', points: 200, payout: 800,
    missions: [
      { id: 'gang_shootout', label: 'Gang Shootout', timeLimit: 600, area: 'Senora Way · Grand Senora Desert',
        description: 'Armed gang members are holed up at a remote hideout. Clear it and secure the scene.',
        objectives: ['Neutralise all hostiles', 'Secure the scene'] },
      { id: 'hostage_rescue', label: 'Hostage Rescue', timeLimit: 600, area: 'Vespucci Blvd · Pillbox Hill',
        description: 'Armed robbers are holding hostages inside a bank. Neutralise the hostiles, cut the hostages free and walk them out to the safe point. Watch your fire.',
        objectives: ['Neutralise the robbers', 'Free the hostages', 'Walk the hostages out'] },
      { id: 'bomb_disposal', label: 'Bomb Disposal', timeLimit: 360, area: 'Palomino Ave · Little Seoul',
        description: 'An explosive device has been planted at a store. Search the building, find every device and defuse it before the timer runs out.',
        objectives: ['Find the devices', 'Defuse the devices'] },
      { id: 'armored_truck_escort', label: 'Armored Truck Escort', timeLimit: 720, area: 'Route 68 · Harmony',
        description: 'An armored cash truck is leaving the depot. Escort it along its route, fight off the ambush crews and see it safely to its destination.',
        objectives: ['Escort the armored truck'] },
      { id: 'prison_break', label: 'Prison Break', timeLimit: 600, area: 'Route 68 · Bolingbroke',
        description: 'Inmates have broken out of Bolingbroke Penitentiary and are scattering into the desert. Catch and cuff every inmate before they get away. Some of them are armed.',
        objectives: ['Catch the escaped inmates'] },
    ],
  },
];

const BOSS: MockMission & { points: number; payout: number } = {
  id: 'weekly_boss_kingpin', label: 'Weekly Boss: Kingpin', timeLimit: 900, points: 500, payout: 2500, area: 'Tataviam foothills · Senora',
  description: 'The Kingpin and his crew are dug in at a remote compound. Fight through four waves of gunmen, take down the Kingpin and secure the scene.',
  objectives: ["Break the Kingpin's crew", 'Secure the scene'],
};

const TIERS = [
  { name: 'standard', max: 1, cash: 1.0, points: 1.0 },
  { name: 'reinforced', max: 2, cash: 1.15, points: 1.1 },
  { name: 'heavy', max: 4, cash: 1.3, points: 1.15 },
  { name: 'major', max: 6, cash: 1.5, points: 1.2 },
  { name: 'critical', max: 8, cash: 1.75, points: 1.25 },
];
const tierFor = (n: number) => TIERS.find((x) => n <= x.max) ?? TIERS[TIERS.length - 1];
const tierByName = (name: string) => TIERS.find((x) => x.name === name) ?? TIERS[0];

// ── people ────────────────────────────────────────────────────────────────────

function me(): RunPartner {
  const o = (MOCK_DEPARTMENTS[devState.department] ?? MOCK_DEPARTMENTS.sast).officer;
  return { src: ME_SRC, name: o.name, callsign: o.callsign, departmentShort: o.departmentShort, status: 'active', arrived: false };
}
const MARIA: RunPartner = { src: 14, name: 'Maria Lopez', callsign: '2L-21', departmentShort: 'SAST', status: 'active', arrived: false };
const DANA: RunPartner = { src: 21, name: 'Dana Whitfield', callsign: null, departmentShort: 'FIB', status: 'active', arrived: false };
const RAY: RunPartner = { src: 29, name: 'Ray Chen', callsign: '4A-02', departmentShort: 'FIB', status: 'active', arrived: false };
const TOM: RunPartner = { src: 31, name: 'Tom Reed', callsign: '2L-33', departmentShort: 'SAST', status: 'active', arrived: false };

// ── board state ───────────────────────────────────────────────────────────────

interface Cooldown { until: number; who?: string }

const board = {
  unitSize: ['unit', 'member'].includes(boardVariant) ? 3 : boardVariant === 'locked' ? 2 : 1,
  isLeader: boardVariant !== 'member',
  typeCooldowns: {} as Record<string, Cooldown>,
  emptyPool: {} as Record<string, boolean>,
  busy: boardVariant === 'busy',
  onCall: boardVariant === 'oncall',
  tod: 'tactical' as string | null,
  boss: ['boss', 'bossused'].includes(boardVariant),
  bossUsed: boardVariant === 'bossused',
  errorsLeft: boardVariant === 'error' ? 1 : 0,
  op: null as null | { id: number; missionLabel: string; missionType: string; missionTypeLabel: string; description: string; launcher: string;
    status: 'joining' | 'running' | 'waiting'; joined: number; min: number; joinEndsAt: number | null; joinedByMe: boolean; runState: 'accepted' | 'in_progress' | null },
};

(function initBoard() {
  const t = nowS();
  if (boardVariant === 'locked') {
    board.typeCooldowns.tactical = { until: t + 222 };
    board.typeCooldowns.training = { until: t + 1310, who: 'Maria Lopez' };
    board.emptyPool.investigation = true;
  }
  if (boardVariant === 'boss' || boardVariant === 'bossused') board.tod = 'tactical';
  if (boardVariant === 'normal') board.tod = 'patrol';
  if (['operation', 'opjoined', 'oprunning', 'opwaiting'].includes(boardVariant)) {
    board.op = {
      id: 7, missionLabel: 'Hostage Rescue', missionType: 'tactical', missionTypeLabel: 'Tactical',
      description: 'Armed robbers are holding hostages inside a bank. Neutralise the hostiles, cut the hostages free and walk them out to the safe point. Watch your fire.',
      launcher: 'Sgt. Marcus Bell (SAST)', status: 'joining', joined: 3, min: 2, joinEndsAt: t + 184, joinedByMe: false, runState: null,
    };
    if (boardVariant === 'opjoined') {
      board.op.joined = 4;
      board.op.joinedByMe = true;
    } else if (boardVariant === 'oprunning') {
      board.op.status = 'running';
      board.op.runState = 'in_progress';
      board.op.joined = 6;
      board.op.joinEndsAt = null;
    } else if (boardVariant === 'opwaiting') {
      board.op.status = 'waiting';
      board.op.joined = 0;
      board.op.joinEndsAt = null;
    }
  }
})();

function cashRange(payout: number, size: number, modifiers = true): [number, number] {
  const base = Math.round(payout * tierFor(size).cash);
  return [base, modifiers ? Math.round(base * 1.25) : base];
}

function typeCard(tp: MockType): TypeCard {
  const size = board.unitSize;
  const t = nowS();
  const card: TypeCard = {
    key: tp.key, label: tp.label, points: tp.points, cash: cashRange(tp.payout, size), pool: tp.missions.length,
    mode: size > 1 ? 'unit' : 'solo', locked: null, busy: board.busy, onCall: board.onCall, typeOfTheDay: board.tod === tp.key,
  };
  const cd = board.typeCooldowns[tp.key];
  if (cd && cd.until > t) {
    card.locked = cd.who
      ? { reason: L('board.locked_cooldown_member', { type: tp.label, name: cd.who }), until: cd.until }
      : { reason: L('board.locked_cooldown', { type: tp.label }), until: cd.until };
  } else if (board.emptyPool[tp.key]) {
    card.pool = 0;
    card.locked = size > 1 ? { reason: L('board.locked_empty', { type: tp.label, size }) } : { reason: L('board.locked_empty_solo', { type: tp.label }) };
  }
  return card;
}

function bossCard(): BossCard | null {
  if (!board.boss || board.op) return null;
  const size = board.unitSize;
  const card: BossCard = {
    key: BOSS_KEY, label: BOSS.label, points: BOSS.points, cash: cashRange(BOSS.payout, size, false), pool: 1,
    mode: size > 1 ? 'unit' : 'solo', locked: null, busy: board.busy, onCall: board.onCall, typeOfTheDay: board.tod === 'tactical', available: true,
  };
  if (board.bossUsed) {
    card.locked = { reason: L('board.boss_used') };
    card.available = false;
  }
  return card;
}

function operationCard(): BoardOperation | null {
  const o = board.op;
  if (!o) return null;
  const t = nowS();
  const open = o.status === 'joining' && o.joinEndsAt !== null && o.joinEndsAt > t;
  if (o.status === 'joining' && !open) {
    // The join window closed: the operation starts with whoever joined.
    o.status = 'running';
    o.runState = 'accepted';
  }
  const canJoin = open && !o.joinedByMe && o.joined < OP_MAX && !mockRun && !board.onCall;
  return {
    id: o.id, missionLabel: o.missionLabel, launcher: o.launcher, status: o.status, joined: o.joined, max: OP_MAX,
    joinedByMe: o.joinedByMe, canJoin, joinEndsIn: open && o.joinEndsAt ? o.joinEndsAt - t : null,
    missionType: o.missionType, missionTypeLabel: o.missionTypeLabel, description: o.description, min: o.min, runState: o.runState,
  };
}

function boardData(): MissionBoardData {
  const operation = operationCard();
  return {
    cards: operation ? [] : TYPES.map(typeCard),
    boss: operation ? null : bossCard(),
    operation,
    unit: { size: board.unitSize, isLeader: board.isLeader },
    activeRunId: mockRun ? mockRun.runId : null,
  };
}

// ── run state ─────────────────────────────────────────────────────────────────

interface MockRunState {
  runId: string;
  mission: MockMission;
  missionType: string;
  state: 'accepted' | 'in_progress';
  tier: string;
  payTier: string;
  route: NonNullable<ActiveMissionData['route']>;
  routeWarnAt: number | null;      // local ms when the off-route countdown was sent (secondsLeft counts from it)
  objectives: RunObjective[];
  deadline: number | null;          // local ms when the run timer hits 0
  frozen: number | null;            // remaining seconds while paused
  partners: RunPartner[];
  modifier: ActiveMissionData['modifier'];
  test: boolean;
  isBoss: boolean;
  operationId: number | null;
  recalcsLeft: number;
  radioSilence: boolean;
  log: ActiveMissionData['log'];
  logCount: number;
  startDeadline: number | null;     // local ms of the start timeout
  cashBase: number;
  pointsBase: number;
  simulated: boolean;
}

let mockRun: MockRunState | null = null;
let lastRunToggle: boolean | null = null;
let runSeq = 100;
const timers: number[] = [];

function clearTimers() {
  while (timers.length) window.clearTimeout(timers.pop());
}

function later(ms: number, fn: () => void) {
  timers.push(window.setTimeout(fn, ms));
}

function objectivesFor(m: MockMission, started: boolean): RunObjective[] {
  return m.objectives.map((label, i) => ({ label, done: false, current: started && i === 0 }));
}

function modifierOf(key: string | null): ActiveMissionData['modifier'] {
  return key ? { key, label: L(`modifier.${key}`) } : null;
}

function newRun(tp: MockType | null, mission: MockMission, opts: Partial<MockRunState> = {}): MockRunState {
  const partners = opts.partners ?? [me()];
  const tier = tierFor(Math.max(1, partners.filter((p) => p.status === 'active').length)).name;
  return {
    runId: `run-${mission.id}-${++runSeq}`,
    mission,
    missionType: tp ? tp.key : 'tactical',
    state: 'accepted',
    tier,
    payTier: tier,
    route: { status: 'on', secondsLeft: null, distance: 2150 },
    routeWarnAt: null,
    objectives: objectivesFor(mission, false),
    deadline: null,
    frozen: null,
    partners,
    modifier: null,
    test: false,
    isBoss: false,
    operationId: null,
    recalcsLeft: MAX_RECALCS,
    radioSilence: false,
    log: null,
    logCount: 0,
    startDeadline: Date.now() + 600 * 1000,
    cashBase: tp ? tp.payout : BOSS.payout,
    pointsBase: tp ? tp.points : BOSS.points,
    simulated: false,
    ...opts,
  };
}

function startRun(r: MockRunState, remaining: number) {
  r.state = 'in_progress';
  r.route = { status: 'arrived', secondsLeft: null, distance: 0 };
  r.routeWarnAt = null;
  r.startDeadline = null;
  r.deadline = Date.now() + remaining * 1000;
  r.objectives = r.objectives.map((o, i) => ({ ...o, current: i === 0 }));
  r.partners = r.partners.map((p) => (p.src === ME_SRC ? { ...p, arrived: true } : p));
}

function findType(key: string): MockType | undefined {
  return TYPES.find((x) => x.key === key);
}

function missionOf(typeKey: string, id: string): MockMission {
  return findType(typeKey)?.missions.find((m) => m.id === id) ?? TYPES[0].missions[0];
}

function variantRun(kind: string): MockRunState | null {
  if (kind === 'accepted') {
    const tp = findType('investigation') as MockType;
    const r = newRun(tp, missionOf('investigation', 'warrant_service'), { partners: [me(), { ...MARIA }] });
    r.route = { status: 'on', secondsLeft: null, distance: 1840 };
    r.startDeadline = Date.now() + 512 * 1000;
    return r;
  }
  if (kind === 'offroute') {
    const tp = findType('tactical') as MockType;
    const r = newRun(tp, missionOf('tactical', 'hostage_rescue'), { partners: [me(), { ...MARIA }, { ...DANA, arrived: true }] });
    r.route = { status: 'off', secondsLeft: 18, distance: 2630 };
    r.routeWarnAt = Date.now();
    r.recalcsLeft = 1;
    r.modifier = modifierOf('armored_hostiles');
    r.startDeadline = Date.now() + 371 * 1000;
    return r;
  }
  if (kind === 'progress') {
    const tp = findType('tactical') as MockType;
    const r = newRun(tp, missionOf('tactical', 'gang_shootout'), {
      partners: [me(), { ...MARIA }, { ...DANA }, { ...RAY, status: 'left' }],
    });
    startRun(r, 482);
    r.partners = r.partners.map((p) => (p.status === 'active' && p.src !== MARIA.src ? { ...p, arrived: true } : p));
    r.tier = 'heavy';
    r.payTier = 'heavy';
    r.modifier = modifierOf('armored_hostiles');
    r.objectives = [
      { label: 'Neutralise all hostiles', done: false, current: true, value: 12, max: 20, detail: 'Wave 2 of 3' },
      { label: 'Secure the scene', done: false, current: false },
    ];
    return r;
  }
  if (kind === 'test') {
    const tp = findType('tactical') as MockType;
    const r = newRun(tp, missionOf('tactical', 'bomb_disposal'), { partners: [me(), { ...DANA }, { ...TOM }], test: true });
    startRun(r, 318);
    r.partners = r.partners.map((p) => ({ ...p, arrived: true }));
    r.route = { status: 'disabled', secondsLeft: null, distance: null };
    r.frozen = 318;
    r.deadline = null;
    r.tier = 'critical';
    r.payTier = 'major';
    r.modifier = modifierOf('time_crunch');
    r.objectives = [
      { label: 'Find the devices', done: true, current: false, value: 3, max: 3 },
      { label: 'Defuse the devices', done: false, current: true, value: 1, max: 3, detail: 'Device B: wire panel open' },
    ];
    return r;
  }
  if (kind === 'log') {
    const tp = findType('patrol') as MockType;
    const r = newRun(tp, missionOf('patrol', 'business_check'));
    startRun(r, 431);
    r.objectives = [{ label: 'Check the business doors', done: false, current: true, value: 1, max: 4, detail: 'Discount Store, Innocence Blvd: log the result on the tablet' }];
    r.log = logFor(2);
    r.logCount = 1;
    return r;
  }
  if (kind === 'silence') {
    const tp = findType('investigation') as MockType;
    const r = newRun(tp, missionOf('investigation', 'manhunt'), { partners: [me(), { ...TOM }] });
    startRun(r, 544);
    r.partners = r.partners.map((p) => ({ ...p, arrived: true }));
    r.modifier = modifierOf('radio_silence');
    r.radioSilence = true;
    r.objectives = [
      { label: 'Find the clues', done: false, current: true, value: 1, max: 3, detail: 'Search circle: 300 m' },
      { label: 'Catch the fugitive', done: false, current: false },
    ];
    return r;
  }
  if (kind === 'boss') {
    const r = newRun(null, BOSS, { partners: [me(), { ...MARIA }, { ...DANA }], isBoss: true, missionType: 'tactical' });
    startRun(r, 766);
    r.partners = r.partners.map((p) => ({ ...p, arrived: true }));
    r.tier = 'heavy';
    r.payTier = 'heavy';
    r.objectives = [
      { label: "Break the Kingpin's crew", done: false, current: true, value: 9, max: 36, detail: 'Wave 1 of 4' },
      { label: 'Secure the scene', done: false, current: false },
    ];
    return r;
  }
  return null;
}

function logFor(point: number): ActiveMissionData['log'] {
  return {
    point,
    choices: [
      { id: 'secure', label: L('block.interact_points.log.secure') },
      { id: 'found_open', label: L('block.interact_points.log.found_open') },
    ],
  };
}

if (runVariant && runVariant !== 'none') mockRun = variantRun(runVariant);

/** Keeps the dev panel's run toggle (devState.runActive) and the mock run in step. */
function syncRunToggle() {
  if (lastRunToggle === null) {
    lastRunToggle = devState.runActive;
    if (!mockRun && devState.runActive && runVariant !== 'none') mockRun = variantRun('progress');
    return;
  }
  if (devState.runActive !== lastRunToggle) {
    lastRunToggle = devState.runActive;
    if (devState.runActive && !mockRun) mockRun = variantRun('progress');
    if (!devState.runActive) {
      clearTimers();
      mockRun = null;
    }
  }
}

function setRunActive(active: boolean) {
  devState.runActive = active;
  lastRunToggle = active;
}

function remainingOf(r: MockRunState): number | null {
  if (r.state !== 'in_progress') return null;
  if (r.frozen !== null) return r.frozen;
  if (r.deadline === null) return null;
  return Math.max(0, Math.ceil((r.deadline - Date.now()) / 1000));
}

function expectedOf(r: MockRunState): { cash: number; points: number } {
  const tier = tierByName(r.payTier);
  const mod = r.modifier ? 1.25 : 1;
  const depts = new Set(r.partners.filter((p) => p.status === 'active').map((p) => p.departmentShort)).size;
  const cross = depts >= 2 ? 1.1 : 1;
  const tod = board.tod === r.missionType ? 2 : 1;
  const pts = Math.min(2 * r.pointsBase, (r.pointsBase + (r.modifier ? 0.25 * r.pointsBase : 0)) * tier.points * cross) * tod;
  return { cash: Math.round(r.cashBase * tier.cash * mod), points: Math.floor(pts) };
}

function view(r: MockRunState): ActiveMissionData {
  let route = r.route;
  if (route.status === 'off' && route.secondsLeft !== null && r.routeWarnAt !== null) {
    route = { ...route, secondsLeft: Math.max(0, route.secondsLeft - Math.floor((Date.now() - r.routeWarnAt) / 1000)) };
  }
  return {
    runId: r.runId,
    missionLabel: r.mission.label,
    description: r.mission.description,
    missionType: r.missionType,
    state: r.state,
    tier: r.tier,
    tierExpected: r.state !== 'in_progress',
    payTier: r.payTier,
    route,
    objectives: r.objectives,
    remaining: remainingOf(r),
    paused: r.frozen !== null,
    // The viewer follows the dev panel's department (the run may have been built before it was picked).
    partners: r.partners.map((p) => (p.src === ME_SRC ? { ...me(), status: p.status, arrived: p.arrived } : p)),
    expected: expectedOf(r),
    modifier: r.modifier,
    test: r.test,
    recalcsLeft: r.recalcsLeft,
    radioSilence: r.radioSilence,
    log: r.state === 'in_progress' ? r.log : null,
    me: ME_SRC,
    isBoss: r.isBoss,
    operationId: r.operationId,
    startIn: r.state === 'accepted' && r.startDeadline ? Math.max(0, Math.round((r.startDeadline - Date.now()) / 1000)) : null,
    area: r.radioSilence ? r.mission.area : null,
  };
}

function pushRun() {
  push('run', mockRun ? view(mockRun) : null);
}

// ── simulation of an accepted run (browser mode only) ─────────────────────────

function simulate(r: MockRunState) {
  r.simulated = true;
  // Distance to the start shrinks, then the officer arrives and the run moves to In progress.
  const steps = [1600, 1050, 520];
  steps.forEach((d, i) => later(2500 * (i + 1), () => {
    if (mockRun !== r || r.state !== 'accepted') return;
    r.route = { ...r.route, distance: d };
    pushRun();
  }));
  later(10000, () => {
    if (mockRun !== r || r.state !== 'accepted') return;
    startRun(r, r.mission.timeLimit);
    if (r.mission.id === 'business_check') {
      r.objectives = [{ label: 'Check the business doors', done: false, current: true, value: 0, max: 4 }];
      r.log = logFor(1);
    } else {
      r.objectives = r.objectives.map((o, i) => (i === 0 ? { ...o, value: 0, max: 5 } : o));
    }
    notify('info', L('run.in_progress', { mission: r.mission.label }));
    pushRun();
    later(4000, () => advance(r));
  });
}

function advance(r: MockRunState) {
  if (mockRun !== r || r.state !== 'in_progress' || r.log) return;
  const i = r.objectives.findIndex((o) => o.current && !o.done);
  if (i < 0) return;
  const o = r.objectives[i];
  const max = typeof o.max === 'number' ? o.max : 1;
  const value = Math.min(max, (typeof o.value === 'number' ? o.value : 0) + 1);
  if (value < max) {
    r.objectives[i] = { ...o, value };
  } else {
    r.objectives[i] = { ...o, value: max, done: true, current: false };
    notify('success', L('run.objective_complete', { label: o.label }));
    const next = i + 1;
    if (next >= r.objectives.length) {
      pushRun();
      later(1500, () => finishRun(r, 'completed', 'completed'));
      return;
    }
    r.objectives[next] = { ...r.objectives[next], current: true, value: 0, max: 3 };
  }
  pushRun();
  later(4000, () => advance(r));
}

function resultOf(r: MockRunState, result: RunResult['result'], endReason: string): RunResult {
  const tier = tierByName(r.payTier);
  const exp = expectedOf(r);
  const done = r.objectives.filter((o) => o.done).length;
  const completed = result === 'completed';
  const participants = r.partners.filter((p) => p.status === 'active').length;
  return {
    runId: r.runId, missionLabel: r.mission.label, missionType: r.missionType, result, endReason, test: r.test,
    tier: r.tier, payTier: r.payTier, participants, departments: new Set(r.partners.map((p) => p.departmentShort)).size,
    durationS: r.mission.timeLimit - (remainingOf(r) ?? r.mission.timeLimit),
    points: {
      P: r.pointsBase, bonuses: [], penalties: [], subtotal: completed ? r.pointsBase : 0,
      mTeam: tier.points, mCross: 1, mStreak: 1, capped: false, tod: board.tod === r.missionType,
      failedShare: result === 'failed' ? done / Math.max(1, r.objectives.length) : null, final: completed ? exp.points : 0,
    },
    cash: { B: r.cashBase, mTier: tier.cash, mMod: r.modifier ? 1.25 : 1, amount: completed && !r.test ? exp.cash : 0, status: completed && !r.test ? 'paid' : 'none' },
    flagged: null,
  };
}

function finishRun(r: MockRunState, result: RunResult['result'], endReason: string) {
  if (mockRun !== r) return;
  clearTimers();
  mockRun = null;
  setRunActive(false);
  if (endReason === 'quit' && !r.test && !r.isBoss && !r.operationId) {
    board.typeCooldowns[r.missionType] = { until: nowS() + ABANDON_COOLDOWN };
  }
  if (r.isBoss && endReason !== 'completed') board.bossUsed = true;
  push('run', null);
  push('board', { reason: 'run_ended' });
  emitDebug('result', { result: resultOf(r, result, endReason) }, 200);
  notify(result === 'completed' ? 'success' : 'info', L(`run.ended_${endReason}`), 250);
}

// ── mocks ─────────────────────────────────────────────────────────────────────

registerMock('request', 'getMissionTypes', () => {
  if (board.errorsLeft > 0) {
    board.errorsLeft -= 1;
    throw new Error('err.internal');
  }
  syncRunToggle();
  if (boardVariant === 'empty') return { ...boardData(), cards: [], boss: null };
  return boardData();
});

registerMock('request', 'getRun', () => {
  syncRunToggle();
  return mockRun ? view(mockRun) : null;
});

registerMock('action', 'server:acceptType', (payload: unknown) => {
  const key = typeof payload === 'string' ? payload : typeof payload === 'object' && payload ? String((payload as { missionType?: string }).missionType ?? '') : '';
  syncRunToggle();
  const isBoss = key === BOSS_KEY;
  const tp = findType(key);
  if (!isBoss && !tp) throw new Error('err.invalid_type');
  if (mockRun) throw new Error('err.already_on_run');
  if (!board.isLeader) throw new Error('err.not_leader');
  if (board.op) throw new Error('err.operation_locked');
  if (board.onCall) throw new Error('err.on_call');
  if (isBoss) {
    const b = bossCard();
    if (!b) throw new Error('err.boss_unavailable');
    if (b.locked) throw new Error('err.boss_used');
  } else if (tp) {
    const card = typeCard(tp);
    if (card.locked && board.typeCooldowns[tp.key]) throw new Error(board.typeCooldowns[tp.key].who ? 'err.member_type_cooldown' : 'err.type_cooldown');
    if (card.locked) throw new Error('err.pool_empty');
  }
  if (board.busy) throw new Error('err.server_busy');

  const partners = [me()];
  if (board.unitSize > 1) partners.push({ ...MARIA }, { ...DANA });
  let r: MockRunState;
  if (isBoss) {
    r = newRun(null, BOSS, { partners, isBoss: true, missionType: 'tactical' });
  } else {
    const t = tp as MockType;
    const mission = t.missions[Math.floor(Math.random() * t.missions.length)];
    r = newRun(t, mission, { partners });
    if (Math.random() < 0.25) {
      const pick = t.key === 'tactical' ? ['armored_hostiles', 'time_crunch', 'radio_silence'] : ['time_crunch', 'radio_silence'];
      const mod = pick[Math.floor(Math.random() * pick.length)];
      r.modifier = modifierOf(mod);
      r.radioSilence = mod === 'radio_silence';
    }
  }
  mockRun = r;
  setRunActive(true);
  simulate(r);
  notify('info', L('run.accepted', { mission: r.mission.label }));
  push('board', { reason: 'accepted' });
  pushRun();
  const res: AcceptTypeResult = { runId: r.runId };
  return res;
});

registerMock('action', 'server:joinOperation', (payload: unknown) => {
  const id = Number(typeof payload === 'object' && payload ? (payload as { operationId?: number }).operationId : payload);
  const o = board.op;
  if (!o) throw new Error('err.op_none');
  if (!Number.isInteger(id) || id !== o.id) throw new Error('err.op_not_found');
  const t = nowS();
  if (o.status !== 'joining' || !o.joinEndsAt || o.joinEndsAt <= t) throw new Error('err.op_join_closed');
  if (o.joinedByMe) throw new Error('err.op_already_joined');
  if (o.joined >= OP_MAX) throw new Error('err.op_full');
  if (mockRun) throw new Error('err.already_on_run');
  if (board.onCall) throw new Error('err.on_call');
  o.joined += 1;
  o.joinedByMe = true;
  push('operation', { id: o.id, status: o.status });
  push('board', { id: o.id, status: o.status });
  const res: JoinOperationResult = { id: o.id, joined: o.joined, max: OP_MAX };
  return res;
});

registerMock('action', 'server:abandon', (payload: unknown) => {
  const runId = typeof payload === 'object' && payload ? (payload as { runId?: string }).runId : payload;
  if (typeof runId !== 'string' || runId.length > 64) throw new Error('err.invalid_payload');
  if (!mockRun || mockRun.runId !== runId) throw new Error('err.invalid_run');
  const r = mockRun;
  window.setTimeout(() => finishRun(r, 'abandoned', 'quit'), 80);
  const res: AbandonResult = { runId };
  return res;
});

registerMock('client', 'setGps', () => {
  const r = mockRun;
  if (!r || r.route.status === 'arrived') throw new Error('err.route_inactive');
  notify('info', L('route.gps_set'));
  const res: SetGpsResult = { runId: r.runId };
  return res;
});

registerMock('client', 'recalcRoute', () => {
  const r = mockRun;
  if (!r) throw new Error('err.route_inactive');
  if (r.route.status === 'arrived') throw new Error('err.route_arrived');
  if (r.route.status === 'disabled') throw new Error('err.route_disabled');
  if (r.recalcsLeft <= 0) throw new Error('err.route_no_recalcs');
  r.recalcsLeft -= 1;
  const wasOff = r.route.status === 'off';
  r.route = { status: 'on', secondsLeft: null, distance: Math.max(300, (r.route.distance ?? 2000) - 180) };
  r.routeWarnAt = null;
  notify('info', L('route.recalculated', { left: r.recalcsLeft }));
  if (wasOff) notify('success', L('route.back_on'), 300);
  pushRun();
  const res: RecalcRouteResult = { recalcsLeft: r.recalcsLeft };
  return res;
});

registerMock('client', 'logResult', (payload: unknown) => {
  const r = mockRun;
  if (!r || r.state !== 'in_progress') throw new Error('err.not_on_run');
  const p = payload as { point?: unknown; choice?: unknown } | null;
  const point = Number(p?.point);
  const choice = p?.choice;
  if (!p || !Number.isInteger(point) || point < 1 || typeof choice !== 'string' || !choice || choice.length > 32) throw new Error('err.invalid_payload');
  if (!r.log || r.log.point !== point || !r.log.choices.some((c) => c.id === choice)) throw new Error('err.invalid_payload');
  // The server validates the log a moment later, then moves on to the next door (or completes the objective).
  window.setTimeout(() => {
    if (mockRun !== r || !r.log) return;
    const o = r.objectives[0];
    const max = typeof o.max === 'number' ? o.max : 4;
    const value = Math.min(max, (typeof o.value === 'number' ? o.value : 0) + 1);
    r.logCount += 1;
    if (value >= max) {
      r.log = null;
      r.objectives[0] = { ...o, value: max, done: true, current: false, detail: undefined };
      pushRun();
      window.setTimeout(() => finishRun(r, 'completed', 'completed'), 1200);
      return;
    }
    r.objectives[0] = { ...o, value, detail: undefined };
    r.log = null;
    pushRun();
    // The officer drives to the next business and checks its door, then the next log opens.
    later(3500, () => {
      if (mockRun !== r || r.state !== 'in_progress') return;
      r.log = logFor(point + 1);
      r.objectives[0] = { ...r.objectives[0], detail: 'Door checked: log the result on the tablet' };
      pushRun();
    });
  }, 700);
  return true;
});
