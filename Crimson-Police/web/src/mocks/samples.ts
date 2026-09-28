// Sample data for browser mode. Feature mocks may import these (e.g. sampleResult for a Profile breakdown).
import uiLocale from '../../../locales/parts/ui.json';
import type { ActiveMissionView, HudState, RunResult, Session, Theme, UiKind } from '../shared/types';
import { devState, type DevDept } from './devState';
import { BROKEN_LOGO, FIB_LOGO, SAST_LOGO } from './logos';

// Every locale part (locales/parts/*.json, ui.json included) merged, like locales/en.json in game.
const parts = import.meta.glob('../../../locales/parts/*.json', { eager: true, import: 'default' }) as Record<string, Record<string, string>>;
export const mockLocale: Record<string, string> = Object.assign({}, ...Object.values(parts), uiLocale);

export const ADMIN_THEME: Theme = { primary: '#a4161a', accent: '#e5383b', background: '#0b090a', surface: '#161a1d', text: '#f5f3f4' };

interface MockDept {
  key: string; label: string; short: string; theme: Theme; logo: Session['logo'];
  officer: NonNullable<Session['officer']>;
}

export const MOCK_DEPARTMENTS: Record<DevDept, MockDept> = {
  sast: {
    key: 'sast', label: 'San Andreas State Troopers', short: 'SAST',
    theme: { primary: '#1f4e8c', accent: '#f2c230', background: '#0d1522', surface: '#152235', text: '#ffffff' },
    logo: { url: SAST_LOGO, watermark: true, opacity: 0.08, size: 0.6, grayscale: false },
    officer: { citizenid: 'ABC12345', name: 'John Doe', department: 'sast', departmentLabel: 'San Andreas State Troopers', departmentShort: 'SAST', rank: 'Sergeant', callsign: '2L-14', gradeLevel: 3 },
  },
  fib: {
    key: 'fib', label: 'Federal Investigation Bureau', short: 'FIB',
    theme: { primary: '#1c2541', accent: '#c9a227', background: '#0b0c10', surface: '#1a1b24', text: '#ffffff' },
    logo: { url: FIB_LOGO, watermark: true, opacity: 0.1, size: 0.6, grayscale: false },
    officer: { citizenid: 'FIB00042', name: 'Dana Whitfield', department: 'fib', departmentLabel: 'Federal Investigation Bureau', departmentShort: 'FIB', rank: 'Special Agent', callsign: null, gradeLevel: 3 },
  },
  bcso: {
    key: 'bcso', label: "Blaine County Sheriff's Office", short: 'BCSO',
    theme: { primary: '#5c4033', accent: '#d4a017', background: '#14100c', surface: '#231c16', text: '#ffffff' },
    logo: { url: BROKEN_LOGO, watermark: true, opacity: 0.08, size: 0.6, grayscale: false },
    officer: { citizenid: 'BCS00777', name: 'Earl Hutchins', department: 'bcso', departmentLabel: "Blaine County Sheriff's Office", departmentShort: 'BCSO', rank: 'Deputy', callsign: '1K-07', gradeLevel: 4 },
  },
};

const SUPERVISOR_ACTIONS = ['viewMissionList', 'setTypePayout', 'launchCrossDept', 'forceRecall', 'reviewFlagged', 'handleDisputes', 'builderEdit', 'builderPublish', 'builderArchive'];
const ADMIN_ACTIONS = [
  ...SUPERVISOR_ACTIONS, 'builderEditAny', 'builderRollback', 'breakEditLock', 'setMissionPayout', 'clearPayout', 'manualAward',
  'handleFailedDispute', 'voidAnyRun', 'seasons', 'bountyOverride', 'suspend', 'reloadMissions', 'testRun', 'openAdmin',
];

const CONFIG: Session['config'] = {
  missionTypes: [
    { key: 'patrol', label: 'Patrol', points: 60 },
    { key: 'training', label: 'Training', points: 100 },
    { key: 'investigation', label: 'Investigation', points: 160 },
    { key: 'tactical', label: 'Tactical', points: 200 },
  ],
  departments: [
    { key: 'fib', label: 'Federal Investigation Bureau', short: 'FIB', primary: '#1c2541' },
    { key: 'sast', label: 'San Andreas State Troopers', short: 'SAST', primary: '#1f4e8c' },
  ],
  tiers: ['standard', 'reinforced', 'heavy', 'major', 'critical'].map((name) => ({ name, label: mockLocale[`tier.${name}`] ?? name })),
  maxRecalcs: 2,
  disputeWindowHours: 48,
  periods: ['weekly', 'monthly', 'season', 'alltime'],
  filters: ['overall', 'patrol', 'training', 'investigation', 'tactical', 'unit', 'cross', 'department'],
};

/** getSession({ ui }) in browser mode. The officer is a supervisor (roles.supervisor = true). */
export function buildSession(ui: UiKind = 'officer'): Session {
  const d = MOCK_DEPARTMENTS[devState.department] ?? MOCK_DEPARTMENTS.sast;
  const base = {
    title: 'Crimson-Police',
    locale: mockLocale,
    config: CONFIG,
    serverTime: Math.floor(Date.now() / 1000),
  };
  if (ui === 'admin') {
    return {
      ...base, ui: 'admin',
      roles: { officer: false, supervisor: false, admin: true },
      officer: null, theme: ADMIN_THEME, logo: null, actions: ADMIN_ACTIONS,
    };
  }
  return {
    ...base, ui,
    roles: { officer: true, supervisor: true, admin: false },
    officer: d.officer, theme: d.theme, logo: d.logo, actions: SUPERVISOR_ACTIONS,
  };
}

// ── HUD ───────────────────────────────────────────────────────────────────────

export type SampleHudKind = 'progress' | 'offroute' | 'test';

export function sampleHud(kind: SampleHudKind = 'progress'): HudState {
  if (kind === 'offroute') {
    return {
      runId: 'run-beat-1', test: false, missionLabel: 'Beat Patrol', phase: 'route',
      tier: 'reinforced', payTier: 'reinforced', modifier: null, timer: null,
      route: { status: 'off', secondsLeft: 23, distance: 1480 },
      objectives: [], detail: null, message: null, testControls: false,
    };
  }
  if (kind === 'test') {
    return {
      runId: 'test-bomb-1', test: true, missionLabel: 'Bomb Disposal', phase: 'objectives',
      tier: 'critical', payTier: 'major', modifier: { key: 'time_crunch', label: 'Time Crunch' },
      timer: { remaining: 318, paused: true },
      route: { status: 'disabled', secondsLeft: null, distance: null },
      objectives: [
        { label: 'Evacuate the plaza', done: true, current: false },
        { label: 'Find the devices', done: true, current: false, value: 3, max: 3 },
        { label: 'Disarm the devices', done: false, current: true, value: 1, max: 3, detail: 'Device B: wire panel open' },
        { label: 'Secure the scene', done: false, current: false },
      ],
      detail: 'Hold still: 6 s',
      message: { text: 'Timer paused by the test controls', kind: 'info' },
      testControls: true,
    };
  }
  return {
    runId: 'run-gang-1', test: false, missionLabel: 'Gang Shootout', phase: 'objectives',
    tier: 'heavy', payTier: 'heavy', modifier: { key: 'armored_hostiles', label: 'Armored Hostiles' },
    timer: { remaining: 482, paused: false },
    route: { status: 'arrived', secondsLeft: null, distance: 0 },
    objectives: [
      { label: 'Reach the hideout', done: true, current: false },
      { label: 'Neutralise the hostiles', done: false, current: true, value: 12, max: 20, detail: 'Wave 2 of 3' },
      { label: 'Arrest the gang leader', done: false, current: false },
      { label: 'Search the hideout', done: false, current: false },
    ],
    detail: null,
    message: null,
    testControls: false,
  };
}

// ── Result ────────────────────────────────────────────────────────────────────

export type SampleResultKind = 'completed' | 'failed' | 'test' | 'flagged';

export function sampleResult(kind: SampleResultKind = 'completed'): RunResult {
  if (kind === 'failed') {
    return {
      runId: 'run-hostage-1', missionLabel: 'Hostage Rescue', missionType: 'tactical', result: 'failed', endReason: 'time_limit', test: false,
      tier: 'reinforced', payTier: 'reinforced', participants: 2, departments: 1, durationS: 600,
      points: { P: 200, bonuses: [], penalties: [], subtotal: 25, mTeam: 1.1, mCross: 1, mStreak: 1, capped: false, tod: false, failedShare: 0.5, final: 27 },
      cash: { B: 800, mTier: 1.15, mMod: 1, amount: 0, status: 'none' },
      flagged: null,
    };
  }
  if (kind === 'test') {
    return {
      runId: 'test-bomb-1', missionLabel: 'Bomb Disposal', missionType: 'tactical', result: 'completed', endReason: 'completed', test: true,
      tier: 'critical', payTier: 'major', participants: 6, departments: 2, durationS: 431,
      points: {
        P: 200,
        bonuses: [
          { id: 'fast', label: 'Finished within 75% of the time limit', points: 40 },
          { id: 'modifier', label: 'Modifier: Time Crunch', points: 50 },
          { id: 'no_participant_downed', label: 'No participant downed', points: 20 },
        ],
        penalties: [],
        subtotal: 310, mTeam: 1.2, mCross: 1.1, mStreak: 1.15, capped: true, tod: true, failedShare: null, final: 800,
      },
      cash: { B: 800, mTier: 1.5, mMod: 1.25, amount: 1500, status: 'none' },
      flagged: null,
    };
  }
  const flagged = kind === 'flagged';
  return {
    runId: 'run-gang-1', missionLabel: 'Gang Shootout', missionType: 'tactical', result: 'completed', endReason: 'completed', test: false,
    tier: 'heavy', payTier: 'heavy', participants: 4, departments: 2, durationS: 512,
    points: {
      P: 200,
      bonuses: [
        { id: 'fast', label: 'Finished within 75% of the time limit', points: 40 },
        { id: 'no_participant_downed', label: 'No participant downed', points: 20 },
        { id: 'hostile_arrested', label: 'Hostile arrested × 3', points: 15 },
        { id: 'first_run', label: 'First completed run since going on duty', points: 15 },
      ],
      penalties: [{ id: 'ped_hit', label: 'NPC pedestrian hit', points: -30 }],
      subtotal: 260, mTeam: 1.15, mCross: 1.1, mStreak: 1.1, capped: false, tod: false, failedShare: null, final: 361,
    },
    cash: { B: 800, mTier: 1.3, mMod: 1, amount: 1040, status: flagged ? 'held' : 'paid' },
    flagged: flagged ? { reason: 'outside_help' } : null,
  };
}

// ── Active run (getRun / push 'run') ──────────────────────────────────────────

export function sampleRun(): ActiveMissionView {
  const hud = sampleHud('progress');
  return {
    runId: hud.runId, missionLabel: hud.missionLabel,
    description: 'A crew is holed up in a warehouse on Elysian Island. Clear it room by room and arrest the leader.',
    missionType: 'tactical', state: 'in_progress', tier: 'heavy', tierExpected: false, payTier: 'heavy',
    route: hud.route, objectives: hud.objectives, remaining: 482, paused: false,
    partners: [
      { src: 12, name: 'John Doe', callsign: '2L-14', departmentShort: 'SAST', status: 'active', arrived: true },
      { src: 15, name: 'Maria Lopez', callsign: '2L-21', departmentShort: 'SAST', status: 'active', arrived: true },
      { src: 9, name: 'Dana Whitfield', callsign: null, departmentShort: 'FIB', status: 'active', arrived: true },
      { src: 21, name: 'Ray Chen', callsign: '4A-02', departmentShort: 'FIB', status: 'active', arrived: false },
    ],
    expected: { cash: 1040, points: 260 }, modifier: hud.modifier, test: false,
    recalcsLeft: 2, radioSilence: false, log: null,
  };
}
