// Browser mocks of the teams slice: getUnit + unit actions, sup:getOperation + operation actions.

import { emitDebug, registerMock } from '../shared/nui';
import type {
    EligibleMission,
    OperationInfo,
    OperationParticipant,
    OperationView,
    OperationWaitlistEntry,
    ReadyCheckView,
    UnitOperationCard,
    UnitScreenView,
} from '../types/teams';
import { devState } from './devState';
import { MOCK_DEPARTMENTS } from './samples';

const params = typeof window !== 'undefined' ? new URLSearchParams(window.location.search) : new URLSearchParams();
const LUA = params.get('lua') === '1';

// What a Lua table looks like after msgpack/JSON: [] -> {} and null (nil) keys dropped.
function luaify<T>(v: T): T {
    if (Array.isArray(v)) return (v.length === 0 ? {} : v.map(x => luaify(x))) as T;
    if (v && typeof v === 'object') {
        const out: Record<string, unknown> = {};
        for (const [k, x] of Object.entries(v as Record<string, unknown>)) {
            if (x === null || x === undefined) continue;
            out[k] = luaify(x);
        }
        return out as T;
    }
    return v;
}
const reply = <T>(v: T): T => (LUA ? luaify(v) : v);
const nowS = () => Math.floor(Date.now() / 1000);
const INVITE_TTL = 120;
const MAX_UNIT = 4;

interface Person {
    src: number;
    name: string;
    callsign: string | null;
    rank: string;
    departmentShort: string;
}

const P = {
    dana: { src: 21, name: 'Dana Whitfield', callsign: null, rank: 'Special Agent', departmentShort: 'FIB' },
    maria: { src: 14, name: 'Maria Lopez', callsign: '2L-21', rank: 'Trooper First Class', departmentShort: 'SAST' },
    tom: { src: 31, name: 'Tom Reed', callsign: '2L-33', rank: 'Trooper', departmentShort: 'SAST' },
    grace: { src: 27, name: 'Grace Kim', callsign: 'F-01', rank: 'Supervisory Agent', departmentShort: 'FIB' },
    leo: { src: 28, name: 'Leo Park', callsign: 'F-12', rank: 'Special Agent', departmentShort: 'FIB' },
    ana: { src: 17, name: 'Ana Silva', callsign: '2L-30', rank: 'Corporal', departmentShort: 'SAST' },
    marcus: { src: 19, name: 'Marcus Bell', callsign: '2L-08', rank: 'Lieutenant', departmentShort: 'SAST' },
    rosa: { src: 33, name: 'Rosa Delgado', callsign: 'F-07', rank: 'Special Agent', departmentShort: 'FIB' },
    owen: { src: 36, name: 'Owen Fraser', callsign: null, rank: 'Trooper', departmentShort: 'SAST' },
    priya: { src: 38, name: 'Priya Nair', callsign: 'F-19', rank: 'Agent', departmentShort: 'FIB' },
    long: {
        src: 41,
        name: 'Maximiliano Bartholomew Montgomery-Fitzgerald',
        callsign: 'F-123456789-LONGCALL',
        rank: 'Senior Supervisory Special Agent in Charge',
        departmentShort: 'FIB',
    },
} satisfies Record<string, Person>;

const ME_SRC = 12;
function me(): Person {
    const o = (MOCK_DEPARTMENTS[devState.department] ?? MOCK_DEPARTMENTS.sast).officer;
    return { src: ME_SRC, name: o.name, callsign: o.callsign, rank: o.rank, departmentShort: o.departmentShort };
}

// ============================================================================
//                                    UNITS
// ============================================================================

interface MockUnit {
    id: number;
    leader: number;
    locked: boolean;
    members: Person[];
    pending: { p: Person; expiresAt: number }[];
}
interface MockInvite {
    unitId: number;
    from: Person;
    expiresAt: number;
    size: number;
}

interface MockReadyCheck {
    typeLabel: string;
    expiresAt: number;
    ready: number[];
    waiting: number[];
}

const units: {
    unit: MockUnit | null;
    invites: MockInvite[];
    pool: Person[];
    onRun: boolean;
    inUnit: Set<number>;
    readyCheck: MockReadyCheck | null;
    partners: Set<number>;
    operation: UnitOperationCard | null;
} = {
    unit: null,
    invites: [],
    pool: [P.maria, P.grace, P.leo, P.ana, P.marcus, P.rosa, P.owen, P.priya],
    onRun: false,
    inUnit: new Set([P.marcus.src, P.grace.src]),
    readyCheck: null,
    partners: new Set([P.ana.src, P.rosa.src]),
    operation: null,
};

// Level numbers and distance bands for the mock people (the server works them out).
const LEVELS: Record<number, number> = { 21: 14, 14: 7, 31: 3, 27: 22, 28: 9, 17: 5, 19: 31, 33: 11, 36: 1, 38: 2 };
const BADGES = ['grey', 'bronze', 'silver', 'gold', 'platinum'];
function levelOf(src: number) {
    const n = LEVELS[src] ?? 4;
    return { n, badge: BADGES[Math.min(4, Math.floor(n / 10))] };
}
function initialsOf(name: string) {
    return name
        .split(/\s+/)
        .filter(Boolean)
        .slice(0, 2)
        .map(w => w[0].toUpperCase())
        .join('');
}
const SIZE_FIT: Record<number, number[]> = {
    // missions of each type by unit size 1..5 (patrol, training, investigation, tactical)
    1: [5, 2, 2, 0],
    2: [4, 3, 3, 5],
    3: [2, 2, 2, 7],
    4: [2, 2, 2, 7],
    5: [2, 2, 2, 7],
};
function sizeFit(size: number) {
    const keys = ['patrol', 'training', 'investigation', 'tactical'];
    const now = SIZE_FIT[size] ?? SIZE_FIT[4];
    const plus = SIZE_FIT[Math.min(size + 1, MAX_UNIT)] ?? now;
    const out: Record<string, { now: number; plusOne: number }> = {};
    keys.forEach((k, i) => (out[k] = { now: now[i], plusOne: size < MAX_UNIT ? plus[i] : now[i] }));
    return out;
}

(function initUnits() {
    const v = params.get('teams') ?? 'leader';
    const t = nowS();
    if (v === 'leader') {
        units.unit = {
            id: 3,
            leader: ME_SRC,
            locked: false,
            members: [P.dana],
            pending: [{ p: P.tom, expiresAt: t + 94 }],
        };
        units.pool = units.pool.filter(p => p.src !== P.dana.src);
        units.invites = [{ unitId: 5, from: P.grace, expiresAt: t + 71, size: 2 }];
    } else if (v === 'member') {
        units.unit = { id: 6, leader: P.maria.src, locked: false, members: [P.maria], pending: [] };
        units.pool = units.pool.filter(p => p.src !== P.maria.src);
    } else if (v === 'locked') {
        units.unit = { id: 8, leader: ME_SRC, locked: true, members: [], pending: [] };
        units.onRun = true;
    } else if (v === 'lockedoff') {
        // The unit is on its run; the viewer abandoned it and is still a member.
        units.unit = { id: 8, leader: P.maria.src, locked: true, members: [P.maria, P.dana], pending: [] };
    } else if (v === 'long') {
        units.unit = {
            id: 4,
            leader: P.long.src,
            locked: false,
            members: [P.long, P.owen],
            pending: [{ p: P.dana, expiresAt: t + 48 }],
        };
        units.pool = [
            P.priya,
            { ...P.long, src: 42, name: 'Alexandria Konstantinopoulou-Vanderbilt the Third' },
            P.rosa,
        ];
        units.invites = [{ unitId: 7, from: P.long, expiresAt: t + 9, size: 3 }];
    } else if (v === 'full') {
        units.unit = { id: 2, leader: ME_SRC, locked: false, members: [P.maria, P.dana, P.grace], pending: [] };
    } else if (v === 'ready') {
        // The leader accepted Tactical: the viewer is asked to confirm.
        units.unit = { id: 6, leader: P.maria.src, locked: true, members: [P.maria, P.dana], pending: [] };
        units.readyCheck = {
            typeLabel: 'Tactical',
            expiresAt: t + 18,
            ready: [P.maria.src],
            waiting: [ME_SRC, P.dana.src],
        };
        units.pool = units.pool.filter(p => p.src !== P.maria.src);
    } else if (v === 'op') {
        units.operation = {
            id: 7,
            missionLabel: 'Gang Shootout',
            status: 'joining',
            joined: 8,
            max: 8,
            waitlistPosition: 2,
            joinEndsIn: 184,
            canLeave: true,
        };
    } else if (v === 'invites') {
        units.invites = [
            { unitId: 5, from: P.grace, expiresAt: t + 103, size: 2 },
            { unitId: 9, from: P.marcus, expiresAt: t + 22, size: 3 },
        ];
    }
})();

function unitMembers(u: MockUnit): Person[] {
    // The viewer is always a member of their unit; the leader first when it is not the viewer.
    const others = u.members.filter(m => m.src !== ME_SRC);
    if (u.leader === ME_SRC) return [me(), ...others];
    return [...others, me()];
}

function sweep() {
    const t = nowS();
    units.invites = units.invites.filter(i => i.expiresAt > t);
    if (units.unit) {
        const expired = units.unit.pending.filter(x => x.expiresAt <= t).map(x => x.p);
        units.unit.pending = units.unit.pending.filter(x => x.expiresAt > t);
        units.pool.push(...expired);
    }
}

function unitView(): UnitScreenView {
    sweep();
    const t = nowS();
    const u = units.unit;
    const members = u ? unitMembers(u) : [];
    const pendingN = u ? u.pending.length : 0;
    const size = u ? members.length : 1;
    let inviteBlocked: string | null = null;
    if (units.onRun) inviteBlocked = 'unit.blocked_on_run';
    else if (u?.locked) inviteBlocked = 'unit.blocked_locked';
    else if (size + pendingN >= MAX_UNIT) inviteBlocked = 'unit.blocked_full';
    const canInvite = inviteBlocked === null;
    const taken = new Set([...members.map(m => m.src), ...(u?.pending ?? []).map(x => x.p.src)]);
    return {
        me: ME_SRC,
        maxSize: MAX_UNIT,
        inviteTtl: INVITE_TTL,
        onRun: units.onRun,
        canInvite,
        inviteBlocked,
        unit: u
            ? {
                  id: u.id,
                  leader: u.leader,
                  locked: u.locked,
                  size: members.length,
                  members: members.map(m => {
                      const level = levelOf(m.src);
                      return {
                          ...m,
                          isLeader: m.src === u.leader,
                          available: true,
                          level,
                          avatar: {
                              kind: 'initials' as const,
                              value: null,
                              initials: initialsOf(m.name),
                              frame: level.badge,
                          },
                      };
                  }),
                  pending: u.pending.map(x => ({ ...x.p, expiresIn: x.expiresAt - t })),
                  canManage: u.leader === ME_SRC && !u.locked,
                  readyCheck: readyView(),
              }
            : null,
        pendingSent:
            u && u.leader !== ME_SRC
                ? []
                : (u?.pending ?? []).map(x => ({ src: x.p.src, name: x.p.name, expiresIn: x.expiresAt - t })),
        sizeFit: sizeFit(size),
        operation: units.operation,
        invites: units.invites
            .map(i => ({
                unitId: i.unitId,
                from: i.from.name,
                fromCallsign: i.from.callsign,
                departmentShort: i.from.departmentShort,
                expiresIn: i.expiresAt - t,
                size: i.size,
            }))
            .sort((a, b) => b.expiresIn - a.expiresIn),
        invitable: canInvite
            ? units.pool
                  .filter(p => !taken.has(p.src))
                  .map(p => ({
                      ...p,
                      inUnit: units.inUnit.has(p.src),
                      lastPartner: units.partners.has(p.src),
                      distanceBand: (p.src % 4) as 0 | 1 | 2 | 3,
                  }))
                  .sort(
                      (a, b) =>
                          a.distanceBand - b.distanceBand ||
                          a.departmentShort.localeCompare(b.departmentShort) ||
                          a.name.localeCompare(b.name),
                  )
            : [],
    };
}

function readyView(): ReadyCheckView | null {
    const c = units.readyCheck;
    if (!c) return null;
    const expiresIn = c.expiresAt - nowS();
    if (expiresIn <= 0) {
        units.readyCheck = null;
        if (units.unit) units.unit.locked = false;
        return null;
    }
    return {
        typeLabel: c.typeLabel,
        expiresIn,
        ready: c.ready,
        waiting: c.waiting,
        waitingForMe: c.waiting.includes(ME_SRC),
    };
}

function pushUnit() {
    emitDebug('push', { topic: 'unit', data: { unitId: units.unit?.id ?? false, readyCheck: readyView() } }, 50);
}

function targetOf(payload: unknown): number {
    return Number(typeof payload === 'object' && payload ? (payload as { targetSrc?: number }).targetSrc : payload);
}

function managed(): MockUnit {
    const u = units.unit;
    if (!u) throw new Error('err.unit_none');
    if (u.locked) throw new Error('err.unit_locked');
    if (u.leader !== ME_SRC) throw new Error('err.unit_not_leader');
    return u;
}

registerMock('action', 'server:unitKick', (payload: unknown) => {
    const u = managed();
    const src = targetOf(payload);
    const m = u.members.find(x => x.src === src);
    if (!m) throw new Error('err.unit_not_member');
    u.members = u.members.filter(x => x !== m);
    if (u.members.length === 0) units.unit = null;
    pushUnit();
    return { kicked: src };
});

registerMock('action', 'server:unitPromote', (payload: unknown) => {
    const u = managed();
    const src = targetOf(payload);
    if (!u.members.some(x => x.src === src)) throw new Error('err.unit_not_member');
    u.leader = src;
    pushUnit();
    return { leader: src };
});

registerMock('action', 'server:unitDisband', () => {
    const u = managed();
    units.pool.push(...u.members, ...u.pending.map(x => x.p));
    units.unit = null;
    pushUnit();
    return { disbanded: true };
});

registerMock('action', 'server:unitCancelInvite', (payload: unknown) => {
    const u = units.unit;
    if (!u) throw new Error('err.unit_none');
    const src = targetOf(payload);
    const inv = u.pending.find(x => x.p.src === src);
    if (!inv) throw new Error('err.unit_no_invite_sent');
    u.pending = u.pending.filter(x => x !== inv);
    units.pool.push(inv.p);
    pushUnit();
    return { cancelled: src };
});

registerMock('action', 'server:unitReady', (payload: unknown) => {
    const c = units.readyCheck;
    const accepted = typeof payload === 'boolean' ? payload : !!(payload as { accepted?: boolean })?.accepted;
    if (!c || !c.waiting.includes(ME_SRC)) throw new Error('err.unit_ready_none');
    c.waiting = c.waiting.filter(x => x !== ME_SRC);
    if (!accepted) {
        units.readyCheck = null;
        if (units.unit) units.unit.locked = false;
    } else {
        c.ready.push(ME_SRC);
        // The last member answers a moment later.
        setTimeout(() => {
            if (units.readyCheck !== c) return;
            c.ready.push(...c.waiting);
            c.waiting = [];
            units.readyCheck = null;
            units.onRun = true;
            pushUnit();
        }, 2500);
    }
    pushUnit();
    return { accepted };
});

registerMock('action', 'server:leaveOperation', () => {
    if (!units.operation) throw new Error('err.op_not_joined');
    if (!units.operation.canLeave) throw new Error('err.op_leave_started');
    units.operation = null;
    pushUnit();
    return { left: true };
});

registerMock('request', 'getUnit', () => reply(unitView()));

registerMock('action', 'server:unitInvite', (target: unknown) => {
    const src = Number(typeof target === 'object' && target ? (target as { targetSrc?: number }).targetSrc : target);
    const p = units.pool.find(x => x.src === src);
    if (!p) throw new Error('err.unit_target_unavailable');
    if (units.onRun) throw new Error('err.unit_on_run');
    if (units.unit?.locked) throw new Error('err.unit_locked');
    if (!units.unit) units.unit = { id: 11, leader: ME_SRC, locked: false, members: [], pending: [] };
    const u = units.unit;
    if (unitMembers(u).length + u.pending.length >= MAX_UNIT) throw new Error('err.unit_full');
    u.pending.push({ p, expiresAt: nowS() + INVITE_TTL });
    units.pool = units.pool.filter(x => x.src !== src);
    pushUnit();
    return { unitId: u.id, expiresIn: INVITE_TTL };
});

registerMock('action', 'server:unitRespond', (payload: unknown) => {
    const accepted = typeof payload === 'boolean' ? payload : !!(payload as { accepted?: boolean })?.accepted;
    const unitId = typeof payload === 'object' && payload ? (payload as { unitId?: number }).unitId : undefined;
    const inv = unitId !== undefined ? units.invites.find(i => i.unitId === unitId) : units.invites[0];
    if (!inv) throw new Error('err.unit_no_invite');
    if (inv.expiresAt <= nowS()) throw new Error('err.unit_invite_expired');
    units.invites = units.invites.filter(i => i !== inv);
    if (!accepted) {
        pushUnit();
        return { unitId: null, accepted: false };
    }
    if (units.onRun) throw new Error('err.already_on_run');
    const others = inv.from.src === P.marcus.src ? [P.marcus, P.owen] : [inv.from];
    units.unit = { id: inv.unitId, leader: inv.from.src, locked: false, members: others, pending: [] };
    units.invites = [];
    units.pool = units.pool.filter(p => !others.some(o => o.src === p.src));
    pushUnit();
    return { unitId: inv.unitId, accepted: true };
});

registerMock('action', 'server:unitLeave', () => {
    const u = units.unit;
    if (!u) throw new Error('err.unit_none');
    const abandoned = u.locked && units.onRun;
    units.pool.push(...u.members.filter(m => m.src !== ME_SRC), ...u.pending.map(x => x.p));
    units.unit = null;
    units.onRun = false;
    pushUnit();
    return { left: true, abandoned };
});

// ============================================================================
//                                  OPERATIONS
// ============================================================================

const ELIGIBLE: EligibleMission[] = [
    {
        id: 'armored_truck_escort',
        label: 'Armored Truck Escort',
        type: 'tactical',
        typeLabel: 'Tactical',
        difficulty: 3,
        minOfficers: 2,
        maxOfficers: 8,
    },
    {
        id: 'bomb_disposal',
        label: 'Bomb Disposal',
        type: 'tactical',
        typeLabel: 'Tactical',
        difficulty: 3,
        minOfficers: 2,
        maxOfficers: 8,
    },
    {
        id: 'gang_shootout',
        label: 'Gang Shootout',
        type: 'tactical',
        typeLabel: 'Tactical',
        difficulty: 3,
        minOfficers: 2,
        maxOfficers: 8,
    },
    {
        id: 'hostage_rescue',
        label: 'Hostage Rescue',
        type: 'tactical',
        typeLabel: 'Tactical',
        difficulty: 3,
        minOfficers: 2,
        maxOfficers: 8,
    },
    {
        id: 'manhunt',
        label: 'Manhunt',
        type: 'investigation',
        typeLabel: 'Investigation',
        difficulty: 2,
        minOfficers: 2,
        maxOfficers: 8,
    },
    {
        id: 'prison_break',
        label: 'Prison Break',
        type: 'tactical',
        typeLabel: 'Tactical',
        difficulty: 3,
        minOfficers: 2,
        maxOfficers: 8,
    },
    {
        id: 'stolen_vehicle_takedown',
        label: 'Stolen Vehicle Takedown',
        type: 'training',
        typeLabel: 'Training',
        difficulty: 2,
        minOfficers: 2,
        maxOfficers: 8,
    },
    {
        id: 'warrant_service',
        label: 'Warrant Service',
        type: 'investigation',
        typeLabel: 'Investigation',
        difficulty: 2,
        minOfficers: 2,
        maxOfficers: 8,
    },
];

const COOLDOWN = 1800;
const JOIN_WINDOW = 300;
const IDLE_CANCEL = 1800;
const CONFIG_VIEW = {
    cooldown: COOLDOWN,
    joinWindow: JOIN_WINDOW,
    idleCancel: IDLE_CANCEL,
    maxParticipants: 8,
    crossBonus: 1.1,
};

function part(p: Person, status: OperationParticipant['status'], arrived = false): OperationParticipant {
    return { src: p.src, name: p.name, callsign: p.callsign, departmentShort: p.departmentShort, status, arrived };
}

interface MockOp {
    info: Omit<OperationInfo, 'joinEndsIn' | 'idleCancelIn' | 'remaining' | 'departments' | 'joined'>;
    joinEndsAt?: number;
    idleUntil?: number;
    runEndsAt?: number;
}

const ops: { op: MockOp | null; lastLaunch: number } = { op: null, lastLaunch: 0 };

function baseInfo(id: number, missionId: string, launchedAt: number): MockOp['info'] {
    const m = ELIGIBLE.find(x => x.id === missionId) ?? ELIGIBLE[2];
    return {
        id,
        missionId: m.id,
        missionLabel: m.label,
        missionType: m.type,
        missionTypeLabel: m.typeLabel,
        difficulty: m.difficulty,
        launcher: 'John Doe',
        launcherCallsign: '2L-14',
        launcherDepartment: 'SAST',
        launchedAt,
        status: 'joining',
        runState: null,
        runId: null,
        participants: [],
        max: 8,
        min: m.minOfficers,
        tier: 'reinforced',
        tierExpected: true,
        waitingReason: null,
        attempt: 1,
        canStart: false,
        startBlocked: 'sup.crossdept.start_blocked_min',
        canRelaunch: false,
        canCancel: true,
    };
}

(function initOps() {
    const v = params.get('op') ?? 'joining';
    const t = nowS();
    if (v === 'fresh') {
        // Just launched: nobody joined yet (the list Lua sends as {}).
        ops.lastLaunch = t - 3;
        ops.op = { info: baseInfo(9, 'prison_break', t - 3), joinEndsAt: t + JOIN_WINDOW - 3 };
        return;
    }
    if (v === 'none' || v === 'empty') {
        ops.lastLaunch = t - 7200;
        return;
    }
    if (v === 'cooldown') {
        ops.lastLaunch = t - (COOLDOWN - 1262);
        return;
    }
    ops.lastLaunch = t - 420;
    if (v === 'running') {
        const info = baseInfo(7, 'gang_shootout', t - 900);
        info.status = 'running';
        info.runState = 'in_progress';
        info.runId = 'run-op-7';
        info.tier = 'major';
        info.tierExpected = false;
        info.participants = [
            part(P.maria, 'active', true),
            part(P.tom, 'active', true),
            part(P.ana, 'left'),
            part(P.dana, 'active', true),
            part(P.leo, 'active', false),
            part(P.rosa, 'active', true),
        ];
        ops.op = { info, runEndsAt: t + 512 };
    } else if (v === 'waiting') {
        const info = baseInfo(7, 'hostage_rescue', t - 1500);
        info.status = 'waiting';
        info.waitingReason = 'failed';
        info.canRelaunch = true;
        info.attempt = 1;
        info.tier = 'heavy';
        info.participants = [
            part(P.maria, 'waiting'),
            part(P.dana, 'waiting'),
            part(P.leo, 'waiting'),
            part(P.tom, 'waiting'),
        ];
        ops.op = { info, idleUntil: t + 1520 };
    } else if (v === 'full') {
        // Every place taken: two officers wait for a freed place.
        const info = baseInfo(7, 'gang_shootout', t - 116);
        info.participants = [P.maria, P.dana, P.tom, P.grace, P.leo, P.ana, P.marcus, P.rosa].map(p => ({
            ...part(p, 'joined'),
            canRemove: true,
        }));
        info.waitlist = [waiter(P.owen, 1), waiter(P.priya, 2)];
        info.waitlistEnabled = true;
        ops.op = { info, joinEndsAt: t + 184 };
    } else {
        const info = baseInfo(7, 'gang_shootout', t - 116);
        info.participants = [part(P.maria, 'joined'), part(P.dana, 'joined'), part(P.tom, 'joined')].map(p => ({
            ...p,
            canRemove: true,
        }));
        info.waitlist = [];
        info.waitlistEnabled = true;
        ops.op = { info, joinEndsAt: t + 184 };
    }
})();

function waiter(p: Person, position: number): OperationWaitlistEntry {
    return {
        src: p.src,
        name: p.name,
        callsign: p.callsign,
        departmentShort: p.departmentShort,
        position,
        canRemove: true,
    };
}

function tierFor(n: number): string {
    if (n <= 1) return 'standard';
    if (n <= 2) return 'reinforced';
    if (n <= 4) return 'heavy';
    if (n <= 6) return 'major';
    return 'critical';
}

function opView(): OperationView {
    const t = nowS();
    const cooldownLeft = Math.max(0, ops.lastLaunch + COOLDOWN - t);
    const o = ops.op;
    if (!o) {
        return {
            operation: null,
            cooldownLeft,
            ...CONFIG_VIEW,
            enabled: true,
            canLaunch: cooldownLeft === 0,
            launchBlocked: cooldownLeft > 0 ? 'err.op_cooldown' : null,
            eligibleMissions: params.get('op') === 'empty' ? [] : ELIGIBLE,
            serverTime: t,
        };
    }
    const info = o.info;
    const inList = info.participants.filter(p => p.status !== 'left');
    const counts = new Map<string, number>();
    for (const p of inList) counts.set(p.departmentShort, (counts.get(p.departmentShort) ?? 0) + 1);
    const joining = info.status === 'joining';
    if (joining) {
        info.tier = tierFor(Math.max(info.participants.length, info.min));
        info.canStart = info.participants.length >= info.min;
        info.startBlocked = info.canStart ? null : 'sup.crossdept.start_blocked_min';
    }
    return {
        operation: {
            ...info,
            joined: inList.length,
            departments: [...counts.entries()]
                .sort((a, b) => a[0].localeCompare(b[0]))
                .map(([short, count]) => ({ short, count })),
            joinEndsIn: joining && o.joinEndsAt ? Math.max(0, o.joinEndsAt - t) : null,
            idleCancelIn: info.status === 'waiting' && o.idleUntil ? Math.max(0, o.idleUntil - t) : null,
            remaining: info.status === 'running' && o.runEndsAt ? Math.max(0, o.runEndsAt - t) : null,
        },
        cooldownLeft,
        ...CONFIG_VIEW,
        enabled: true,
        canLaunch: false,
        launchBlocked: 'err.op_active',
        serverTime: t,
    };
}

function pushOp() {
    emitDebug(
        'push',
        { topic: 'operation', data: { id: ops.op?.info.id ?? false, status: ops.op?.info.status ?? false } },
        50,
    );
}

registerMock('request', 'sup:getOperation', () => reply(opView()));

for (const scope of ['sup', 'admin'] as const) {
    registerMock('action', `server:${scope}:opLaunch`, (payload: { missionId?: string } | null) => {
        const t = nowS();
        if (ops.op) throw new Error('err.op_active');
        if (ops.lastLaunch + COOLDOWN > t) throw new Error('err.op_cooldown');
        const m = ELIGIBLE.find(x => x.id === payload?.missionId);
        if (!m) throw new Error('err.op_mission_unknown');
        ops.lastLaunch = t;
        ops.op = { info: baseInfo(12, m.id, t), joinEndsAt: t + JOIN_WINDOW };
        // A few officers join over the next seconds, like a real launch.
        const joiners = [P.maria, P.grace, P.leo];
        joiners.forEach((p, i) =>
            setTimeout(
                () => {
                    if (ops.op?.info.status === 'joining') {
                        ops.op.info.participants.push(part(p, 'joined'));
                        pushOp();
                    }
                },
                1500 * (i + 1),
            ),
        );
        pushOp();
        return { id: 12 };
    });

    registerMock('action', `server:${scope}:opStart`, () => {
        const o = ops.op;
        if (!o) throw new Error('err.op_none');
        if (o.info.status !== 'joining') throw new Error('err.op_not_joining');
        if (o.info.participants.length < o.info.min) throw new Error('err.op_not_enough');
        o.info.status = 'running';
        o.info.runState = 'accepted';
        o.info.runId = 'run-op-' + o.info.id;
        o.info.tier = tierFor(o.info.participants.length);
        o.info.tierExpected = true;
        o.info.participants = o.info.participants.map(p => ({ ...p, status: 'active', arrived: false }));
        o.info.canStart = false;
        o.info.startBlocked = null;
        o.runEndsAt = nowS() + 900;
        pushOp();
        return { runId: o.info.runId, participants: o.info.participants.length };
    });

    registerMock('action', `server:${scope}:opRelaunch`, () => {
        const o = ops.op;
        if (!o) throw new Error('err.op_none');
        if (o.info.status !== 'waiting') throw new Error('err.op_not_waiting');
        o.info.status = 'joining';
        o.info.participants = [];
        o.info.waitingReason = null;
        o.info.canRelaunch = false;
        o.info.attempt += 1;
        o.joinEndsAt = nowS() + JOIN_WINDOW;
        pushOp();
        return { id: o.info.id };
    });

    registerMock('action', `server:${scope}:opRemoveJoiner`, (payload: { src?: number; reason?: string } | null) => {
        const o = ops.op;
        if (!o) throw new Error('err.op_none');
        if (o.info.status !== 'joining') throw new Error('err.op_remove_started');
        const reason = String(payload?.reason ?? '').trim();
        if (!reason) throw new Error('err.op_reason_required');
        const src = Number(payload?.src);
        const wasJoined = o.info.participants.some(p => p.src === src);
        const waits = o.info.waitlist ?? [];
        if (!wasJoined && !waits.some(w => w.src === src)) throw new Error('err.op_not_joined');
        o.info.participants = o.info.participants.filter(p => p.src !== src);
        let rest = waits.filter(w => w.src !== src);
        if (wasJoined && rest.length) {
            const first = rest[0];
            o.info.participants.push({ ...part({ ...first, rank: '' }, 'joined'), canRemove: true });
            rest = rest.slice(1);
        }
        o.info.waitlist = rest.map((w, i) => ({ ...w, position: i + 1 }));
        pushOp();
        return { removed: src };
    });

    registerMock('action', `server:${scope}:opCancel`, (payload: { reason?: string } | null) => {
        if (!ops.op) throw new Error('err.op_none');
        const reason = String(payload?.reason ?? '').trim();
        if (!reason) throw new Error('err.op_reason_required');
        if (reason.length > 200) throw new Error('err.op_reason_too_long');
        const id = ops.op.info.id;
        ops.op = null;
        pushOp();
        return { id };
    });
}
