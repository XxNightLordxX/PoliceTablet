// Browser mocks for the oversight slice: Supervisor Mission List, Live Missions, Review Queue and Admin
// Officers, Departments, Permissions and Audit Log. Stateful: approving, voiding, recalling, suspending or
// answering a dispute changes what the next request returns.
import { registerMock } from '../shared/nui';
import type {
  AuditExport, AuditFilters, AuditPage, AuditRow, DepartmentsData, DisputeView, FlaggedRow, LiveRunsData, MissionListData,
  MissionListEntry, OfficerDetail, OfficerSearchData, OfficerSearchRow, PermissionsData, ReviewQueueData,
} from '../types/oversight';
import { BROKEN_LOGO, FIB_LOGO, SAST_LOGO } from './logos';

const now = () => Math.floor(Date.now() / 1000);
const H = 3600;

// ── Mission List ──────────────────────────────────────────────────────────────
const missions: MissionListEntry[] = [
  m('beat_patrol', 'Beat Patrol', 'patrol', 1, 1, 2, 250, 'type', 600, []),
  m('business_check', 'Business Check', 'patrol', 1, 1, 2, 250, 'type', 600, [{ runId: 'run-bc-1', src: 14, name: 'Maria Lopez', callsign: '2L-21', departmentShort: 'SAST', test: false }]),
  m('street_race_bust', 'Street Race Bust', 'patrol', 2, 1, 4, 300, 'admin', 900, []),
  m('evoc_course', 'EVOC Course', 'training', 1, 1, 1, 350, 'type', 300, []),
  m('pursuit_sim', 'Pursuit Sim', 'training', 2, 1, 2, 350, 'type', 600, []),
  m('stolen_vehicle_takedown', 'Stolen Vehicle Takedown', 'investigation', 2, 1, 4, 600, 'type', 900, []),
  m('warrant_service', 'Warrant Service', 'investigation', 2, 2, 4, 600, 'type', 1200, [
    { runId: 'run-ws-1', src: 21, name: 'John Doe', callsign: '2L-14', departmentShort: 'SAST', test: false },
    { runId: 'run-ws-1', src: 33, name: 'Dana Whitfield', callsign: null, departmentShort: 'FIB', test: false },
  ]),
  m('manhunt', 'Manhunt', 'investigation', 3, 2, 6, 600, 'type', 1200, []),
  m('gang_shootout', 'Gang Shootout', 'tactical', 3, 2, 4, 1200, 'admin', 1200, [
    { runId: 'run-gs-1', src: 18, name: 'Ray Chen', callsign: '4A-02', departmentShort: 'SAST', test: false },
    { runId: 'run-gs-1', src: 19, name: 'Ava Brooks', callsign: '4A-07', departmentShort: 'SAST', test: false },
    { runId: 'run-gs-1', src: 40, name: 'Leo Grant', callsign: 'F-12', departmentShort: 'FIB', test: false },
  ]),
  m('hostage_rescue', 'Hostage Rescue', 'tactical', 3, 2, 6, 800, 'type', 1800, []),
  m('bomb_disposal', 'Bomb Disposal', 'tactical', 3, 1, 4, 800, 'type', 1800, []),
  m('armored_truck_escort', 'Armored Truck Escort', 'tactical', 3, 2, 8, 800, 'type', 1800, []),
  m('weekly_boss_kingpin', 'Weekly Boss: Kingpin', 'tactical', 3, 2, 8, 2500, 'event', 0, [], { isBoss: true }),
  m('docks_sweep', 'Docks Sweep', 'patrol', 2, 1, 4, 250, 'type', 900, [], { source: 'custom', version: 3 }),
  m('fib_wiretap', 'FIB Wiretap', 'investigation', 2, 2, 4, 600, 'type', 1200, [], { source: 'custom', version: 1, departments: ['fib'] }),
  m('prison_break', 'Prison Break', 'tactical', 3, 2, 8, 800, 'type', 1800, [], { enabled: false }),
];

function m(id: string, label: string, type: string, difficulty: number, minOfficers: number, maxOfficers: number, basePayout: number,
  payoutSource: MissionListEntry['payoutSource'], cooldown: number, runningNow: MissionListEntry['runningNow'], extra: Partial<MissionListEntry> = {}): MissionListEntry {
  const typeLabel = ({ patrol: 'Patrol', training: 'Training', investigation: 'Investigation', tactical: 'Tactical' } as Record<string, string>)[type] ?? type;
  const entry: MissionListEntry = {
    id, label, type, typeLabel, source: 'builtin', builtin: true, version: null, difficulty, minOfficers, maxOfficers, basePayout,
    payoutSource, cooldown, timeLimit: 900, locations: 5, enabled: true, isBoss: false, departments: [], runningNow, crossDeptEligible: false, ...extra,
  };
  entry.builtin = entry.source === 'builtin';
  entry.crossDeptEligible = entry.enabled && !entry.isBoss && entry.departments.length === 0 && entry.maxOfficers >= 2;
  return entry;
}

let operation: MissionListData['operation'] = null;

registerMock('request', 'getMissionList', (): MissionListData => ({ missions, canLaunch: true, crossDeptEnabled: true, operation }));
registerMock('action', 'server:sup:opLaunch', (p: { missionId: string }) => {
  if (operation) throw new Error('err.operation_locked');
  const mission = missions.find((x) => x.id === p?.missionId);
  if (!mission || !mission.crossDeptEligible) throw new Error('err.invalid_mission');
  operation = { id: 7, missionId: mission.id, missionLabel: mission.label, status: 'joining' };
  return { operationId: 7 };
}, { fallback: true });

// ── Live Missions ─────────────────────────────────────────────────────────────
const liveRuns: LiveRunsData['runs'] = [
  {
    runId: 'run-gs-1', missionId: 'gang_shootout', missionType: 'tactical', missionLabel: 'Gang Shootout', tier: 'heavy', state: 'in_progress',
    remaining: 412, test: false, operationId: null, acceptedAt: now() - 7 * 60, startedAt: now() - 5 * 60, isBoss: false, departments: ['SAST', 'FIB'],
    participants: [
      { src: 18, name: 'Ray Chen', callsign: '4A-02', departmentShort: 'SAST', status: 'active', arrived: true, department: 'sast' },
      { src: 19, name: 'Ava Brooks', callsign: '4A-07', departmentShort: 'SAST', status: 'active', arrived: true, department: 'sast' },
      { src: 40, name: 'Leo Grant', callsign: 'F-12', departmentShort: 'FIB', status: 'active', arrived: false, department: 'fib' },
      { src: 22, name: 'Nina Park', callsign: '2L-30', departmentShort: 'SAST', status: 'left', arrived: true, department: 'sast' },
    ],
  },
  {
    runId: 'run-ws-1', missionId: 'warrant_service', missionType: 'investigation', missionLabel: 'Warrant Service', tier: 'reinforced', state: 'accepted',
    remaining: null, test: false, operationId: null, acceptedAt: now() - 90, startedAt: null, isBoss: false, departments: ['SAST', 'FIB'],
    participants: [
      { src: 21, name: 'John Doe', callsign: '2L-14', departmentShort: 'SAST', status: 'active', arrived: false, department: 'sast' },
      { src: 33, name: 'Dana Whitfield', callsign: null, departmentShort: 'FIB', status: 'active', arrived: false, department: 'fib' },
    ],
  },
  {
    runId: 'run-bc-1', missionId: 'business_check', missionType: 'patrol', missionLabel: 'Business Check', tier: 'standard', state: 'in_progress',
    remaining: 95, test: false, operationId: null, acceptedAt: now() - 14 * 60, startedAt: now() - 11 * 60, isBoss: false, departments: ['SAST'],
    participants: [{ src: 14, name: 'Maria Lopez', callsign: '2L-21', departmentShort: 'SAST', status: 'active', arrived: true, department: 'sast' }],
  },
];

registerMock('request', 'sup:getLiveRuns', (): LiveRunsData => ({ runs: liveRuns.filter((r) => r.participants.some((p) => p.status === 'active')), serverTime: now(), canRecall: true }));
registerMock('action', 'server:sup:forceRecall', (p: { runId: string; src: number }) => {
  const run = liveRuns.find((r) => r.runId === p?.runId);
  const part = run?.participants.find((x) => x.src === p?.src);
  if (!run) throw new Error('err.invalid_run');
  if (!part || part.status !== 'active') throw new Error('err.not_participant');
  part.status = 'left';
  return { runId: run.runId, src: part.src };
});

// ── Review Queue ──────────────────────────────────────────────────────────────
const flagged: FlaggedRow[] = [
  {
    rowId: 1204, runUuid: '5f1c2a9e-7d4b-4c1a-9e3f-2b8d6a0c4e11', citizenid: 'KLM44521', name: 'Ava Brooks', callsign: '4A-07', department: 'sast', departmentShort: 'SAST',
    missionId: 'gang_shootout', missionLabel: 'Gang Shootout', missionType: 'tactical', missionTypeLabel: 'Tactical', location: 'Grove Street hideout',
    state: 'completed', endReason: 'completed', tier: 'heavy', participants: 3, departments: 2, points: 312, cash: 1560, cashStatus: 'held',
    flagReason: 'outside_help', flagDetail: 'Killed by: Tony Vega [QWE90876] ×2', otherReasons: [], durationS: 488, createdAt: now() - 2 * H,
  },
  {
    rowId: 1205, runUuid: '5f1c2a9e-7d4b-4c1a-9e3f-2b8d6a0c4e11', citizenid: 'RTY11234', name: 'Ray Chen', callsign: '4A-02', department: 'sast', departmentShort: 'SAST',
    missionId: 'gang_shootout', missionLabel: 'Gang Shootout', missionType: 'tactical', missionTypeLabel: 'Tactical', location: 'Grove Street hideout',
    state: 'completed', endReason: 'completed', tier: 'heavy', participants: 3, departments: 2, points: 312, cash: 1560, cashStatus: 'held',
    flagReason: 'outside_help', flagDetail: 'Killed by: Tony Vega [QWE90876] ×2', otherReasons: ['speed'], durationS: 488, createdAt: now() - 2 * H,
  },
  {
    rowId: 1188, runUuid: '9a0b7c6d-1e2f-4a3b-8c5d-6e7f8a9b0c1d', citizenid: 'PLM33990', name: 'Nina Park', callsign: '2L-30', department: 'sast', departmentShort: 'SAST',
    missionId: 'armored_truck_escort', missionLabel: 'Armored Truck Escort', missionType: 'tactical', missionTypeLabel: 'Tactical', location: 'Paleto bank route',
    state: 'completed', endReason: 'completed', tier: 'reinforced', participants: 2, departments: 1, points: 0, cash: 0, cashStatus: 'held',
    flagReason: 'presence', flagDetail: null, otherReasons: [], durationS: 702, createdAt: now() - 9 * H,
  },
  {
    rowId: 1150, runUuid: '0c9d8e7f-6a5b-4c3d-9e1f-2a3b4c5d6e7f', citizenid: 'GHJ55001', name: 'Omar Haddad', callsign: null, department: 'sast', departmentShort: 'SAST',
    missionId: 'evoc_course', missionLabel: 'EVOC Course', missionType: 'training', missionTypeLabel: 'Training', location: 'LSIA track',
    state: 'completed', endReason: 'completed', tier: 'standard', participants: 1, departments: 1, points: 110, cash: 350, cashStatus: 'held',
    flagReason: 'speed', flagDetail: 'Omar Haddad [GHJ55001] moved 2140 m in 3.0 s (713 m/s, max 80)', otherReasons: [], durationS: 94, createdAt: now() - 26 * H,
  },
];

const disputes: DisputeView[] = [
  dispute(301, 1102, 'PLM33990', 'Nina Park', '2L-30', 'Bomb Disposal', 'tactical', 'Tactical', 'voided', 'speed',
    'I was never teleported. My game froze while I was driving and caught up; the other officer can confirm.', 20 * H),
  dispute(302, 1133, 'KLM44521', 'Ava Brooks', '4A-07', 'Hostage Rescue', 'tactical', 'Tactical', 'flagged', 'outside_help',
    'A civilian drove through the scene and ran over one of the hostiles. We did not ask for any help.', 5 * H),
];

function dispute(id: number, rowId: number, cid: string, name: string, callsign: string | null, missionLabel: string, missionType: string,
  missionTypeLabel: string, kind: DisputeView['kind'], flagReason: string | null, reason: string, ago: number, extra: Partial<DisputeView> = {}): DisputeView {
  return {
    id, rowId, runUuid: `d${id}-4c1a-9e3f-2b8d6a0c4e11`, citizenid: cid, name, callsign, department: 'sast', departmentShort: 'SAST', missionId: missionLabel.toLowerCase().replace(/ /g, '_'),
    missionLabel, missionType, missionTypeLabel, kind, state: kind === 'failed' ? 'failed' : 'completed', endReason: kind === 'failed' ? 'mission_failed' : 'completed',
    tier: 'reinforced', participants: 2, points: kind === 'failed' ? 25 : 240, cash: kind === 'failed' ? 0 : 920, cashStatus: kind === 'failed' ? 'none' : 'held',
    flagged: kind !== 'failed', voided: kind === 'voided', flagReason, reason, goesTo: kind === 'failed' ? 'admin' : 'supervisor', status: 'open', handledBy: null,
    createdAt: now() - ago, handledAt: null, runAt: now() - ago - 2 * H, canHandle: true, ...extra,
  };
}

registerMock('request', 'sup:getReviewQueue', (): ReviewQueueData => ({ flagged, disputes: disputes.filter((d) => d.status === 'open' && d.goesTo === 'supervisor'), canReview: true, canHandle: true }));
registerMock('request', 'admin:getFlagged', () => ({ flagged }));
registerMock('request', 'admin:getDisputes', () => ({ disputes: [...disputes, ...Object.values(officerDetails).flatMap((o) => o.disputes)].filter((d) => d.status === 'open') }));

function reviewFlagged(p: { rowId: number; decision: string; reason: string }) {
  if (!p?.reason || !String(p.reason).trim()) throw new Error('err.reason_required');
  const i = flagged.findIndex((r) => r.rowId === p.rowId);
  if (i < 0) throw new Error('err.not_flagged');
  if (p.decision !== 'approve' && p.decision !== 'void') throw new Error('err.invalid_decision');
  flagged.splice(i, 1);
  return { rowId: p.rowId };
}
registerMock('action', 'server:sup:reviewFlagged', reviewFlagged);
registerMock('action', 'server:admin:reviewFlagged', reviewFlagged);

function handleDispute(p: { disputeId: number; decision: string; reason: string; awardPoints?: number }) {
  if (!p?.reason || !String(p.reason).trim()) throw new Error('err.reason_required');
  const all = [...disputes, ...Object.values(officerDetails).flatMap((o) => o.disputes)];
  const d = all.find((x) => x.id === p.disputeId);
  if (!d) throw new Error('err.dispute_not_found');
  if (d.status !== 'open') throw new Error('err.dispute_closed');
  if (d.kind === 'failed' && p.decision === 'approve' && !(Number(p.awardPoints) >= 1)) throw new Error('err.invalid_points');
  d.status = p.decision === 'approve' ? 'approved' : 'rejected';
  d.canHandle = false;
  d.handledBy = 'ADMIN001';
  d.handledAt = now();
  return { disputeId: d.id, status: d.status };
}
registerMock('action', 'server:sup:handleDispute', handleDispute);
registerMock('action', 'server:admin:handleDispute', handleDispute);

// ── Officers ──────────────────────────────────────────────────────────────────
const officers: OfficerSearchRow[] = [
  { citizenid: 'ABC12345', name: 'John Doe', callsign: '2L-14', rank: 'Sergeant', department: 'sast', departmentShort: 'SAST', xp: 11250, suspendedUntil: null, online: true },
  { citizenid: 'KLM44521', name: 'Ava Brooks', callsign: '4A-07', rank: 'Trooper', department: 'sast', departmentShort: 'SAST', xp: 6420, suspendedUntil: null, online: true },
  { citizenid: 'FIB00042', name: 'Dana Whitfield', callsign: null, rank: 'Special Agent', department: 'fib', departmentShort: 'FIB', xp: 15800, suspendedUntil: null, online: true },
  { citizenid: 'PLM33990', name: 'Nina Park', callsign: '2L-30', rank: 'Trooper', department: 'sast', departmentShort: 'SAST', xp: 2980, suspendedUntil: now() + 4 * 24 * H, online: false },
  { citizenid: 'RTY11234', name: 'Ray Chen', callsign: '4A-02', rank: 'Corporal', department: 'sast', departmentShort: 'SAST', xp: 8730, suspendedUntil: null, online: true },
  { citizenid: 'GHJ55001', name: 'Omar Haddad', callsign: null, rank: 'Cadet Trooper', department: 'sast', departmentShort: 'SAST', xp: 640, suspendedUntil: null, online: false },
  { citizenid: 'FIB00077', name: 'Leo Grant', callsign: 'F-12', rank: 'Agent', department: 'fib', departmentShort: 'FIB', xp: 4410, suspendedUntil: null, online: true },
  { citizenid: 'LSM10101', name: 'Maria Lopez', callsign: '2L-21', rank: 'Lieutenant', department: 'sast', departmentShort: 'SAST', xp: 41200, suspendedUntil: null, online: true },
];

const LEVELS = [
  { label: 'Probationary', xp: 0, badge: 'grey' }, { label: 'Patrol Officer', xp: 1000, badge: 'bronze' }, { label: 'Senior Patrol', xp: 5000, badge: 'silver' },
  { label: 'Veteran', xp: 15000, badge: 'gold' }, { label: 'Elite', xp: 40000, badge: 'platinum' },
];
function levelOf(xp: number): OfficerDetail['level'] {
  let idx = 0;
  LEVELS.forEach((l, i) => { if (xp >= l.xp) idx = i; });
  return { label: LEVELS[idx].label, badge: LEVELS[idx].badge, xp, next: LEVELS[idx + 1]?.xp ?? null };
}

const officerDetails: Record<string, OfficerDetail> = {};
function detailOf(o: OfficerSearchRow): OfficerDetail {
  if (officerDetails[o.citizenid]) return officerDetails[o.citizenid];
  const runs: OfficerDetail['runs'] = [
    run(9001, 'Gang Shootout', 'tactical', 'Tactical', 'completed', 'completed', 312, 1560, 'held', true, false, 'outside_help', 2 * H),
    run(8990, 'Warrant Service', 'investigation', 'Investigation', 'failed', 'mission_failed', 27, 0, 'none', false, false, null, 20 * H),
    run(8971, 'Beat Patrol', 'patrol', 'Patrol', 'completed', 'completed', 66, 288, 'paid', false, false, null, 27 * H),
    run(8950, 'Pursuit Sim', 'training', 'Training', 'abandoned', 'real_call', 0, 0, 'none', false, false, null, 30 * H),
    run(8932, 'Street Race Bust', 'patrol', 'Patrol', 'completed', 'completed', 72, 345, 'paid', false, true, null, 52 * H),
    run(8911, 'Bomb Disposal', 'tactical', 'Tactical', 'failed', 'downed', 25, 0, 'none', false, false, null, 75 * H),
    run(8900, 'EVOC Course', 'training', 'Training', 'completed', 'completed', 110, 350, 'paid', false, false, null, 98 * H),
  ];
  const d: OfficerDetail = {
    citizenid: o.citizenid, name: o.name, callsign: o.callsign, rank: o.rank, department: o.department, departmentShort: o.departmentShort,
    departmentLabel: o.department === 'fib' ? 'Federal Investigation Bureau' : 'San Andreas State Troopers',
    xp: o.xp, level: levelOf(o.xp), streakDays: o.online ? 4 : 0,
    badges: o.xp > 5000
      ? [{ id: 'ironWheels', label: 'Iron Wheels', earnedAt: '2026-09-12' }, { id: 'partnerInCrime', label: 'Partner in Crime', earnedAt: '2026-08-30' }, { id: 'jointTaskForce', label: 'Joint Task Force', earnedAt: '2026-08-02' }]
      : [],
    cash: { total: Math.round(o.xp * 3.1), week: 1040 },
    stats: { runs: 148, completed: 121, failed: 17, abandoned: 10, flagged: 3, voided: 1 },
    suspension: { suspended: !!o.suspendedUntil, untilTs: o.suspendedUntil },
    runs,
    disputes: [
      dispute(410 + officers.indexOf(o), 8990, o.citizenid, o.name, o.callsign, 'Warrant Service', 'investigation', 'Investigation', 'failed', null,
        'The suspect spawned inside the garage wall and could not be reached, so the timer ran out.', 18 * H),
      dispute(420 + officers.indexOf(o), 8911, o.citizenid, o.name, o.callsign, 'Bomb Disposal', 'tactical', 'Tactical', 'failed', null,
        'An NPC car pinned me against the truck and I went down.', 70 * H, { status: 'rejected', canHandle: false, handledBy: 'ADMIN001', handledAt: now() - 60 * H }),
    ],
    online: o.online, own: false, known: true, maxAward: 10000,
  };
  officerDetails[o.citizenid] = d;
  return d;
}
function run(id: number, missionLabel: string, missionType: string, missionTypeLabel: string, state: string, endReason: string, points: number, cash: number,
  cashStatus: string, flaggedRun: boolean, voided: boolean, flagReason: string | null, ago: number): OfficerDetail['runs'][number] {
  return { id, runUuid: `r${id}`, missionId: missionLabel.toLowerCase().replace(/ /g, '_'), missionLabel, missionType, missionTypeLabel, state, endReason, tier: 'reinforced',
    participants: 2, points, cashPaid: cashStatus === 'paid' ? cash : 0, cash, cashStatus, flagged: flaggedRun, voided, flagReason, createdAt: now() - ago };
}

registerMock('request', 'admin:searchOfficers', (a: { query?: string }): OfficerSearchData => {
  const q = String(a?.query ?? '').trim().toLowerCase();
  const list = q ? officers.filter((o) => o.name.toLowerCase().includes(q) || (o.callsign ?? '').toLowerCase().includes(q) || o.citizenid.toLowerCase().includes(q)) : officers;
  return { officers: list, query: q };
});
registerMock('request', 'admin:getOfficer', (a: { citizenid?: string }): OfficerDetail => {
  const o = officers.find((x) => x.citizenid.toLowerCase() === String(a?.citizenid ?? '').toLowerCase());
  if (!o) throw new Error('err.unknown_officer');
  return detailOf(o);
});
registerMock('action', 'server:admin:suspend', (p: { citizenid: string; days: number; reason: string }) => {
  if (!p?.reason || !String(p.reason).trim()) throw new Error('err.reason_required');
  const o = officers.find((x) => x.citizenid === p.citizenid);
  if (!o) throw new Error('err.unknown_officer');
  const days = Number(p.days);
  if (!Number.isInteger(days) || days < 0 || days > 3650) throw new Error('err.invalid_days');
  if (days === 0 && !o.suspendedUntil) throw new Error('err.not_suspended');
  o.suspendedUntil = days === 0 ? null : now() + days * 24 * H;
  const d = detailOf(o);
  d.suspension = { suspended: days > 0, untilTs: o.suspendedUntil };
  return { citizenid: o.citizenid, days, untilTs: o.suspendedUntil };
});
registerMock('action', 'server:admin:voidRun', (p: { rowId?: number; runUuid?: string; reason: string }) => {
  if (!p?.reason || !String(p.reason).trim()) throw new Error('err.reason_required');
  for (const d of Object.values(officerDetails)) {
    const r = d.runs.find((x) => x.id === p.rowId);
    if (r) {
      if (r.voided) throw new Error('err.already_voided');
      r.voided = true;
      d.stats.voided += 1;
      return { voided: 1 };
    }
  }
  // A row from another screen's mock data (e.g. Admin Leaderboards): accept it.
  if (!p.rowId && !p.runUuid) throw new Error('err.invalid_payload');
  return { voided: 1 };
});
registerMock('action', 'server:admin:awardPoints', (p: { citizenid: string; points: number; reason: string }) => {
  if (!p?.reason) throw new Error('err.reason_required');
  if (!(Number(p.points) >= 1)) throw new Error('err.invalid_points');
  return { citizenid: p.citizenid, points: p.points };
});

// ── Departments ───────────────────────────────────────────────────────────────
registerMock('request', 'admin:getDepartments', (): DepartmentsData => ({
  cashSource: 'society',
  showSociety: true,
  departments: [
    {
      key: 'fib', label: 'Federal Investigation Bureau', short: 'FIB', jobs: ['fib'], supervisorGrade: 3, societyAccount: 'fib',
      theme: { primary: '#1c2541', accent: '#c9a227', background: '#0b0c10', surface: '#1a1b24', text: '#ffffff' },
      logo: { url: FIB_LOGO, watermark: true, opacity: 0.1, size: 0.6, grayscale: false }, members: 23, suspended: 0, onDuty: 6, societyBalance: 84250,
    },
    {
      key: 'sast', label: 'San Andreas State Troopers', short: 'SAST', jobs: ['sast', 'sast_k9'], supervisorGrade: 3, societyAccount: 'sast',
      theme: { primary: '#1f4e8c', accent: '#f2c230', background: '#0d1522', surface: '#152235', text: '#ffffff' },
      logo: { url: SAST_LOGO, watermark: true, opacity: 0.08, size: 0.6, grayscale: false }, members: 61, suspended: 1, onDuty: 14, societyBalance: 212940,
    },
    {
      key: 'bcso', label: "Blaine County Sheriff's Office", short: 'BCSO', jobs: ['bcso'], supervisorGrade: 2, societyAccount: 'bcso',
      theme: { primary: '#5c4033', accent: '#d4a017', background: '#14100c', surface: '#231c16', text: '#ffffff' },
      logo: { url: BROKEN_LOGO, watermark: true, opacity: 0.08, size: 0.6, grayscale: false },
      members: 12, suspended: 0, onDuty: 0, societyBalance: null,
    },
  ],
}));

// ── Permissions ───────────────────────────────────────────────────────────────
registerMock('request', 'admin:getPermissions', (): PermissionsData => ({
  supervisor: [
    { action: 'setTypePayout', enabled: true }, { action: 'launchCrossDept', enabled: true }, { action: 'forceRecall', enabled: true },
    { action: 'reviewFlagged', enabled: true }, { action: 'handleDisputes', enabled: true }, { action: 'builderEdit', enabled: true },
    { action: 'builderPublish', enabled: true }, { action: 'builderArchive', enabled: true }, { action: 'builderEditAny', enabled: false },
    { action: 'builderRollback', enabled: false }, { action: 'breakEditLock', enabled: false },
  ],
  adminOnly: ['setMissionPayout', 'clearPayout', 'manualAward', 'handleFailedDispute', 'voidAnyRun', 'seasons', 'bountyOverride', 'suspend', 'reloadMissions', 'testRun', 'openAdmin'],
  always: ['viewMissionList'],
}));

// ── Audit Log ─────────────────────────────────────────────────────────────────
const SAMPLE: Omit<AuditRow, 'id' | 'createdAt'>[] = [
  { actor: 'ABC12345', actorName: 'John Doe', role: 'supervisor', category: 'audit', action: 'setTypePayout', target: 'patrol', oldValue: '250', newValue: '300', reason: 'Quiet night, more patrol incentive' },
  { actor: 'ADMIN001', actorName: 'Server Admin', role: 'admin', category: 'flags', action: 'voidRun', target: '#8932 GHJ55001', oldValue: 'completed', newValue: 'voided', reason: 'Used a modded vehicle on the course' },
  { actor: 'console', actorName: null, role: 'console', category: 'flags', action: 'runFlagged', target: '5f1c2a9e-7d4b-4c1a-9e3f-2b8d6a0c4e11', oldValue: null, newValue: 'outside_help', reason: 'Killed by: Tony Vega [QWE90876] ×2' },
  { actor: 'LSM10101', actorName: 'Maria Lopez', role: 'supervisor', category: 'operations', action: 'opLaunch', target: 'hostage_rescue', oldValue: null, newValue: 'joining', reason: null },
  { actor: 'ABC12345', actorName: 'John Doe', role: 'supervisor', category: 'flags', action: 'approveFlagged', target: '#8870 KLM44521', oldValue: 'presence', newValue: 'approved', reason: 'Was holding the perimeter on my orders' },
  { actor: 'ADMIN001', actorName: 'Server Admin', role: 'admin', category: 'audit', action: 'suspend', target: 'PLM33990', oldValue: null, newValue: '7', reason: 'Three voided runs this month' },
  { actor: 'FIB00042', actorName: 'Dana Whitfield', role: 'supervisor', category: 'builder', action: 'publish', target: 'fib_wiretap', oldValue: '0', newValue: '1', reason: null },
  { actor: 'console', actorName: null, role: 'console', category: 'audit', action: 'reloadMissions', target: null, oldValue: '15', newValue: '16 loaded, 0 rejected', reason: null },
  { actor: 'LSM10101', actorName: 'Maria Lopez', role: 'supervisor', category: 'audit', action: 'forceRecall', target: 'RTY11234', oldValue: 'gang_shootout', newValue: 'force_recall', reason: 'Needed on a bank robbery' },
  { actor: 'ADMIN001', actorName: 'Server Admin', role: 'admin', category: 'flags', action: 'disputeApproved', target: '#8990 ABC12345', oldValue: 'failed', newValue: '+40', reason: 'Spawn bug confirmed in the garage' },
];
const audit: AuditRow[] = Array.from({ length: 137 }, (_, i) => ({ ...SAMPLE[i % SAMPLE.length], id: 5000 - i, createdAt: now() - i * 47 * 60 - 120 }));

function filterAudit(f: AuditFilters): AuditRow[] {
  const actor = (f.actor ?? '').toLowerCase();
  const from = f.from ? new Date(`${f.from}T00:00:00`).getTime() / 1000 : null;
  const to = f.to ? new Date(`${f.to}T00:00:00`).getTime() / 1000 + 86400 : null;
  return audit.filter((r) =>
    (!f.category || r.category === f.category) &&
    (!f.action || r.action === f.action) &&
    (!actor || r.actor.toLowerCase().includes(actor) || (r.actorName ?? '').toLowerCase().includes(actor)) &&
    (from === null || r.createdAt >= from) &&
    (to === null || r.createdAt < to));
}

registerMock('request', 'admin:getAudit', (f: AuditFilters): AuditPage => {
  const rows = filterAudit(f ?? {});
  const pageSize = 50;
  const pages = Math.max(1, Math.ceil(rows.length / pageSize));
  const page = Math.min(Math.max(1, Number(f?.page ?? 1)), pages);
  return { rows: rows.slice((page - 1) * pageSize, page * pageSize), page, pages, total: rows.length, pageSize, actions: [...new Set(audit.map((r) => r.action))].sort() };
});
registerMock('request', 'admin:exportAudit', (f: AuditFilters): AuditExport => {
  const rows = filterAudit(f ?? {});
  const cell = (v: unknown) => {
    if (v === null || v === undefined) return '';
    let s = String(v);
    if (/^[=+\-@]/.test(s)) s = `'${s}`;
    return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  const fmt = (ts: number) => new Date(ts * 1000).toISOString().replace('T', ' ').slice(0, 19);
  const lines = ['id,time,actor,actor_name,role,category,action,target,old_value,new_value,reason',
    ...rows.map((r) => [r.id, fmt(r.createdAt), r.actor, r.actorName, r.role, r.category, r.action, r.target, r.oldValue, r.newValue, r.reason].map(cell).join(','))];
  return { csv: lines.join('\n'), rows: rows.length, truncated: false };
});
