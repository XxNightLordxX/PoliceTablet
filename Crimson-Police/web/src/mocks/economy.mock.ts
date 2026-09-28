// Browser-mode mocks for the economy slice: getHome, sup:getPayouts, admin:getPayouts and the three
// payout actions. State is kept in memory so a change on one screen shows on the others.
// URL switch for screenshots: ?economy=empty (no goals / no Type of the Day / no announcements, a fresh
// officer), ?economy=lua (the same empties the way Lua encodes them: {} / [] for empty tables, keys of nil
// values missing, no callsign), ?economy=edge (long names and labels, huge numbers, top XP level, a
// config multiplier of 1.5) or ?economy=error (every economy request fails with err.internal).
import { registerMock } from '../shared/nui';
import type { HomeData } from '../shared/types';
import type {
  AdminPayoutMission, AdminPayoutType, AdminPayoutsView, AdminSetMissionPayload, AdminSetTypePayload,
  SupPayoutsView, SupSetTypePayload,
} from '../types/economy';
import { devState } from './devState';
import { MOCK_DEPARTMENTS } from './samples';

const mode = typeof window !== 'undefined' ? new URLSearchParams(window.location.search).get('economy') : null;
const now = () => Math.floor(Date.now() / 1000);

const LIMITS = { min: 0, max: 25000 };
const RANGE = { min: 0.5, max: 2.0 };
const COOLDOWN = 1800;

interface TypeState {
  key: string; label: string; points: number; default: number;
  stored: null | { amount: number; adminLocked: boolean; by: string; byName: string; at: number };
}

const TYPES: TypeState[] = [
  { key: 'patrol', label: 'Patrol', points: 60, default: 250, stored: { amount: 300, adminLocked: false, by: 'LOP20021', byName: 'Maria Lopez', at: now() - 540 } },
  { key: 'training', label: 'Training', points: 100, default: 350, stored: null },
  { key: 'investigation', label: 'Investigation', points: 160, default: 600, stored: { amount: 750, adminLocked: true, by: 'ADM00001', byName: 'Server Admin', at: now() - 86400 * 3 } },
  { key: 'tactical', label: 'Tactical', points: 200, default: 800, stored: { amount: 880, adminLocked: false, by: 'FIB00042', byName: 'Dana Whitfield', at: now() - 7200 } },
];

interface MissionState {
  id: string; label: string; type: string | null; difficulty: number; source: 'builtin' | 'custom';
  isBoss?: boolean; enabled?: boolean; missing?: boolean;
  payout?: { amount: number; by: string; byName: string; at: number };
}

const MISSIONS: MissionState[] = [
  { id: 'beat_patrol', label: 'Beat Patrol', type: 'patrol', difficulty: 1, source: 'builtin' },
  { id: 'business_check', label: 'Business Check', type: 'patrol', difficulty: 1, source: 'builtin' },
  { id: 'street_race_bust', label: 'Street Race Bust', type: 'patrol', difficulty: 2, source: 'builtin' },
  { id: 'evoc_course', label: 'EVOC Course', type: 'training', difficulty: 2, source: 'builtin' },
  { id: 'pursuit_sim', label: 'Pursuit Sim', type: 'training', difficulty: 3, source: 'builtin' },
  { id: 'stolen_vehicle_takedown', label: 'Stolen Vehicle Takedown', type: 'training', difficulty: 3, source: 'builtin' },
  { id: 'warrant_service', label: 'Warrant Service', type: 'investigation', difficulty: 3, source: 'builtin' },
  { id: 'manhunt', label: 'Manhunt', type: 'investigation', difficulty: 2, source: 'builtin' },
  { id: 'gang_shootout', label: 'Gang Shootout', type: 'tactical', difficulty: 3, source: 'builtin' },
  { id: 'hostage_rescue', label: 'Hostage Rescue', type: 'tactical', difficulty: 3, source: 'builtin', payout: { amount: 1200, by: 'ADM00001', byName: 'Server Admin', at: now() - 86400 * 9 } },
  { id: 'bomb_disposal', label: 'Bomb Disposal', type: 'tactical', difficulty: 2, source: 'builtin' },
  { id: 'armored_truck_escort', label: 'Armored Truck Escort', type: 'tactical', difficulty: 3, source: 'builtin' },
  { id: 'prison_break', label: 'Prison Break', type: 'tactical', difficulty: 3, source: 'builtin', enabled: false },
  { id: 'ammunation_robbery', label: 'Ammu-Nation Robbery', type: 'tactical', difficulty: 2, source: 'custom' },
  { id: 'dockside_smuggling', label: 'Dockside Smuggling Sting', type: 'investigation', difficulty: 3, source: 'custom' },
  { id: 'weekly_boss_kingpin', label: 'Weekly Boss: Kingpin', type: 'tactical', difficulty: 3, source: 'builtin', isBoss: true },
  { id: 'old_bank_job', label: 'old_bank_job', type: null, difficulty: 1, source: 'custom', missing: true, payout: { amount: 1500, by: 'ADM00001', byName: 'Server Admin', at: now() - 86400 * 40 } },
];

const BOSS_PAYOUT = 2500;

function fail(): void {
  if (mode === 'error') throw new Error('err.internal');
}

function typeAmount(ty: TypeState): number {
  return ty.stored ? ty.stored.amount : ty.default;
}

function supRange(ty: TypeState): [number, number] {
  return [Math.max(LIMITS.min, Math.ceil(ty.default * RANGE.min)), Math.min(LIMITS.max, Math.floor(ty.default * RANGE.max))];
}

function cooldownLeft(ty: TypeState): number {
  if (!ty.stored || ty.stored.adminLocked) return 0;
  return Math.max(0, COOLDOWN - (now() - ty.stored.at));
}

function adminType(ty: TypeState): AdminPayoutType {
  const [lo, hi] = supRange(ty);
  return {
    key: ty.key, label: ty.label, points: ty.points, amount: typeAmount(ty), default: ty.default,
    adminLocked: !!ty.stored?.adminLocked, stored: !!ty.stored,
    updatedBy: ty.stored?.by ?? null, updatedByName: ty.stored?.byName ?? null, updatedAt: ty.stored?.at ?? null,
    supMin: lo, supMax: hi, cooldownLeft: cooldownLeft(ty),
    missions: MISSIONS.filter((m) => m.type === ty.key && !m.isBoss && !m.missing).length,
  };
}

function fallbackOf(m: MissionState): number {
  if (m.isBoss) return BOSS_PAYOUT;
  const ty = TYPES.find((x) => x.key === m.type);
  return ty ? typeAmount(ty) : 0;
}

function adminMission(m: MissionState): AdminPayoutMission {
  const ty = TYPES.find((x) => x.key === m.type);
  const fallback = fallbackOf(m);
  return {
    id: m.id, label: m.label, type: m.type, typeLabel: ty?.label ?? null, difficulty: m.difficulty, source: m.source,
    isBoss: !!m.isBoss, enabled: m.enabled !== false && !m.missing,
    base: m.payout ? m.payout.amount : fallback,
    payoutSource: m.payout ? 'admin' : m.isBoss ? 'event' : 'type',
    missionPayout: m.payout?.amount ?? null, fallback: m.missing ? 0 : fallback,
    setBy: m.payout?.by ?? null, setByName: m.payout?.byName ?? null, updatedAt: m.payout?.at ?? null,
    missing: !!m.missing,
  };
}

function validAmount(amount: unknown): number {
  if (typeof amount !== 'number' || !Number.isInteger(amount)) throw new Error('err.invalid_amount');
  if (amount < LIMITS.min || amount > LIMITS.max) throw new Error('err.payout_out_of_range');
  return amount;
}

function validReason(reason: unknown): string {
  const r = typeof reason === 'string' ? reason.trim() : '';
  if (!r) throw new Error('err.reason_required');
  if (r.length > 255) throw new Error('err.reason_too_long');
  return r;
}

// ── Home ──────────────────────────────────────────────────────────────────────

registerMock('request', 'getHome', (): HomeData => {
  fail();
  const d = MOCK_DEPARTMENTS[devState.department] ?? MOCK_DEPARTMENTS.sast;
  const o = d.officer;
  if (mode === 'lua') {
    // Lua: nil values are missing keys, an empty table arrives as {} or [].
    return {
      card: {
        rank: o.rank, departmentShort: o.departmentShort, name: o.name, xp: 0,
        level: { label: 'Probationary', badge: 'grey', xp: 0 },
        streak: { days: 0, graceLeft: false }, seasonPoints: 0, cashThisWeek: 0,
      },
      goals: [],
      announcements: {},
    } as unknown as HomeData;
  }
  if (mode === 'edge') {
    return {
      card: {
        rank: 'Senior Deputy Chief Inspector', departmentShort: o.departmentShort,
        name: 'Maximilian Alexander Montgomery-Worthington III', xp: 1234567,
        level: { label: 'Elite', badge: 'platinum', xp: 40000 },
        streak: { days: 12, graceLeft: false }, seasonPoints: 987654, cashThisWeek: 12345678,
      },
      goals: {
        daily: { id: 'any_3', label: 'Complete 3 missions of any type, including at least one with a unit of officers from another department', count: 3, progress: 5, done: true, points: 50 },
      },
      typeOfTheDay: { key: 'investigation', label: 'Investigation', multiplier: 1.5, cap: 2.5 },
      announcements: [
        { kind: 'weekly_top3', text: 'Last week\'s top 3: Maximilian Alexander Montgomery-Worthington III (2L-114) 12,480 · Dana Whitfield 11,920 · Christopherson-Vanderbilt 9,875' },
        { kind: 'monthly_top3', text: 'August top 3: Ray Chen · Maria Lopez · Earl Hutchins' },
        { kind: 'something_new', text: 'An announcement of a kind this screen does not know yet' },
      ],
      champions: { season: 'Season 12 · The Very Long Summer Heatwave Championship Series', department: "Blaine County Sheriff's Office" },
    } as unknown as HomeData;
  }
  if (mode === 'empty') {
    return {
      card: {
        callsign: o.callsign, rank: o.rank, departmentShort: o.departmentShort, name: o.name, xp: 0,
        level: { label: 'Probationary', badge: 'grey', xp: 0, next: 1000 },
        streak: { days: 0, graceLeft: true }, seasonPoints: 0, cashThisWeek: 0,
      },
      goals: { daily: null, weekly: null },
      typeOfTheDay: null,
      announcements: [],
      champions: null,
    };
  }
  return {
    card: {
      callsign: o.callsign, rank: o.rank, departmentShort: o.departmentShort, name: o.name, xp: 11250,
      level: { label: 'Senior Patrol', badge: 'silver', xp: 5000, next: 15000 },
      streak: { days: 4, graceLeft: true }, seasonPoints: 3975, cashThisWeek: 4280,
    },
    goals: {
      daily: { id: 'patrol_2', label: 'Complete 2 Patrol missions', count: 2, progress: 1, done: false, points: 50 },
      weekly: { id: 'cross_2', label: 'Complete 2 cross-department runs', count: 2, progress: 2, done: true, points: 200 },
    },
    typeOfTheDay: { key: 'tactical', label: 'Tactical' },
    announcements: [
      { kind: 'officer_of_week', text: 'Officer of the Week: Maria Lopez (2L-21) with 4,820 points' },
      { kind: 'weekly_top', text: 'Last week\'s top 3: Maria Lopez · Dana Whitfield · John Doe' },
      { kind: 'monthly_top', text: 'August top 3: Ray Chen · Maria Lopez · Earl Hutchins' },
    ],
    champions: { season: 'Season 2 · Summer Heat', department: 'Federal Investigation Bureau' },
  };
});

// ── Supervisor ────────────────────────────────────────────────────────────────

function supView(): SupPayoutsView {
  return {
    types: TYPES.map((ty) => {
      const [lo, hi] = supRange(ty);
      const left = cooldownLeft(ty);
      const locked = !!ty.stored?.adminLocked;
      return {
        key: ty.key, label: ty.label, amount: typeAmount(ty), default: ty.default, min: lo, max: hi,
        adminLocked: locked, cooldownLeft: locked ? 0 : left, updatedByName: ty.stored?.byName ?? null,
        updatedAt: ty.stored?.at ?? null, stored: !!ty.stored, canEdit: !locked && left <= 0,
      };
    }),
    rangeShare: RANGE, cooldownSeconds: COOLDOWN, requireReason: true, limits: LIMITS, serverTime: now(),
  };
}

function edgeTypes<T extends { label: string }>(list: T[]): T[] {
  return list.map((x, i) => (i === 1 ? { ...x, label: 'Training & Certification (Advanced Driving and Firearms)' } : x));
}

registerMock('request', 'sup:getPayouts', () => {
  fail();
  const v = supView();
  if (mode === 'lua') return { ...v, types: {} } as unknown as SupPayoutsView;
  if (mode === 'edge') return { ...v, types: edgeTypes(v.types) };
  return v;
});

registerMock('action', 'server:sup:setTypePayout', (p: SupSetTypePayload) => {
  const ty = TYPES.find((x) => x.key === p?.type);
  if (!ty) throw new Error('err.unknown_type');
  const amount = validAmount(p.amount);
  validReason(p.reason);
  if (ty.stored?.adminLocked) throw new Error('err.payout_locked');
  const [lo, hi] = supRange(ty);
  if (amount < lo || amount > hi) throw new Error('err.payout_out_of_range');
  if (cooldownLeft(ty) > 0) throw new Error('err.payout_cooldown');
  if (amount === typeAmount(ty)) throw new Error('err.payout_unchanged');
  ty.stored = { amount, adminLocked: false, by: 'ABC12345', byName: MOCK_DEPARTMENTS[devState.department]?.officer.name ?? 'John Doe', at: now() };
  return supView().types.find((x) => x.key === ty.key);
});

// ── Admin ─────────────────────────────────────────────────────────────────────

function adminView(): AdminPayoutsView {
  return {
    types: TYPES.map(adminType),
    missions: MISSIONS.map(adminMission),
    limits: LIMITS, requireReason: true, cooldownSeconds: COOLDOWN, serverTime: now(),
  };
}

registerMock('request', 'admin:getPayouts', () => {
  fail();
  const v = adminView();
  if (mode === 'lua') return { ...v, types: {}, missions: {} } as unknown as AdminPayoutsView;
  if (mode === 'edge') {
    return {
      ...v,
      types: edgeTypes(v.types),
      missions: v.missions.map((m, i) => (i === 0 ? { ...m, label: 'Beat Patrol through the Entire Vinewood Hills and Downtown Area' } : m)),
    };
  }
  return v;
});

registerMock('action', 'server:admin:setTypePayout', (p: AdminSetTypePayload) => {
  const ty = TYPES.find((x) => x.key === p?.type);
  if (!ty) throw new Error('err.unknown_type');
  validReason(p.reason);
  if (p.clear || p.amount === null || p.amount === undefined) {
    if (!ty.stored) throw new Error('err.payout_unchanged');
    ty.stored = null;
  } else {
    const amount = validAmount(p.amount);
    if (ty.stored?.adminLocked && ty.stored.amount === amount) throw new Error('err.payout_unchanged');
    ty.stored = { amount, adminLocked: true, by: 'ADM00001', byName: 'Server Admin', at: now() };
  }
  return adminType(ty);
});

registerMock('action', 'server:admin:setMissionPayout', (p: AdminSetMissionPayload) => {
  const m = MISSIONS.find((x) => x.id === p?.missionId);
  if (!m) throw new Error('err.unknown_mission');
  validReason(p.reason);
  if (p.clear || p.amount === null || p.amount === undefined) {
    if (!m.payout) throw new Error('err.payout_unchanged');
    m.payout = undefined;
    if (m.missing) MISSIONS.splice(MISSIONS.indexOf(m), 1);
  } else {
    if (m.missing) throw new Error('err.unknown_mission');
    const amount = validAmount(p.amount);
    if (m.payout?.amount === amount) throw new Error('err.payout_unchanged');
    m.payout = { amount, by: 'ADM00001', byName: 'Server Admin', at: now() };
  }
  return adminMission(m);
});
