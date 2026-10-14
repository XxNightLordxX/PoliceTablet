// Browser mocks for full admin control: Live runs, units and anti-farm overrides (modules/livectl/server.lua).

import { registerMock } from '../shared/nui';
import type {
    AdminLiveRun,
    AdminLiveRunsData,
    AdminOfficerRunState,
    AdminTodayData,
    AdminUnit,
    AdminUnitsData,
} from '../types/admin_live';

const nowS = () => Math.floor(Date.now() / 1000);
const TIME_MAX = 600;

const runs: AdminLiveRun[] = [
    {
        runId: '7a1c0f3e-0000-4000-8000-000000000001',
        missionId: 'gang_shootout',
        missionLabel: 'Gang Shootout',
        missionType: 'tactical',
        state: 'in_progress',
        tier: 'reinforced',
        remaining: 742,
        timerRunning: true,
        paused: false,
        timeLimit: 1200,
        timeAdded: 0,
        test: false,
        operationId: null,
        isBoss: false,
        modifier: null,
        acceptedAt: nowS() - 600,
        startedAt: nowS() - 420,
        unitId: 3,
        departments: ['SAST', 'FIB'],
        own: false,
        participants: [
            {
                src: 14,
                citizenid: 'ABC12345',
                name: 'Maria Lopez',
                callsign: '2L-21',
                departmentShort: 'SAST',
                status: 'active',
                arrived: true,
            },
            {
                src: 21,
                citizenid: 'FIB00021',
                name: 'Dana Whitfield',
                callsign: null,
                departmentShort: 'FIB',
                status: 'active',
                arrived: true,
            },
            {
                src: 31,
                citizenid: 'SAST0031',
                name: 'Tom Reed',
                callsign: '2L-33',
                departmentShort: 'SAST',
                status: 'left',
                arrived: true,
                endReason: 'real_call',
            },
        ],
    },
    {
        runId: '7a1c0f3e-0000-4000-8000-000000000002',
        missionId: 'beat_patrol',
        missionLabel: 'Beat Patrol',
        missionType: 'patrol',
        state: 'accepted',
        tier: 'standard',
        remaining: null,
        timerRunning: false,
        paused: false,
        timeLimit: 900,
        timeAdded: 0,
        test: true,
        testBy: 3,
        operationId: null,
        isBoss: false,
        acceptedAt: nowS() - 90,
        departments: ['SAST'],
        own: false,
        participants: [
            {
                src: 17,
                citizenid: 'SAST0017',
                name: 'Ana Silva',
                callsign: '2L-30',
                departmentShort: 'SAST',
                status: 'active',
                arrived: false,
            },
        ],
    },
];

const units: AdminUnit[] = [
    {
        id: 3,
        leader: 14,
        invites: 0,
        locked: true,
        runId: runs[0].runId,
        createdAt: nowS() - 900,
        blocked: 'err.live_unit_locked',
        own: false,
        members: [
            {
                src: 14,
                name: 'Maria Lopez',
                callsign: '2L-21',
                rank: 'Trooper First Class',
                departmentShort: 'SAST',
                leader: true,
                onRun: true,
            },
            {
                src: 21,
                name: 'Dana Whitfield',
                callsign: null,
                rank: 'Special Agent',
                departmentShort: 'FIB',
                leader: false,
                onRun: true,
            },
        ],
    },
    {
        id: 5,
        leader: 19,
        invites: 1,
        locked: false,
        createdAt: nowS() - 120,
        own: false,
        members: [
            {
                src: 19,
                name: 'Marcus Bell',
                callsign: '2L-08',
                rank: 'Lieutenant',
                departmentShort: 'SAST',
                leader: true,
                onRun: false,
            },
            {
                src: 33,
                name: 'Rosa Delgado',
                callsign: 'F-07',
                rank: 'Special Agent',
                departmentShort: 'FIB',
                leader: false,
                onRun: false,
            },
        ],
    },
];

function findRun(id: string): AdminLiveRun {
    const r = runs.find(x => x.runId === id);
    if (!r) throw new Error('err.invalid_run');
    return r;
}

function needReason(p: { reason?: string }) {
    if (!p.reason || !p.reason.trim()) throw new Error('err.reason_required');
}

registerMock('request', 'admin:getLiveRuns', (): AdminLiveRunsData => ({
    runs,
    serverTime: nowS(),
    addMinutesMax: 10,
    runTimeAddMax: TIME_MAX,
}));

registerMock('request', 'admin:getUnits', (): AdminUnitsData => ({ units, serverTime: nowS() }));

registerMock('action', 'server:admin:recall', (p: { runId: string; src: number; reason?: string }) => {
    needReason(p);
    const r = findRun(p.runId);
    const person = r.participants.find(x => x.src === p.src);
    if (!person || person.status !== 'active') throw new Error('err.not_participant');
    person.status = 'left';
    person.endReason = 'force_recall';
    return { runId: p.runId, src: p.src };
});

registerMock('action', 'server:admin:endRun', (p: { runId: string; reason?: string; confirm?: string }) => {
    needReason(p);
    if ((p.confirm ?? '').trim().toUpperCase() !== 'END') throw new Error('err.confirm_mismatch');
    const r = findRun(p.runId);
    if (r.test) throw new Error('err.live_use_end_test');
    runs.splice(runs.indexOf(r), 1);
    return { runId: p.runId, participants: r.participants.length };
});

registerMock('action', 'server:admin:endTest', (p: { runId: string; reason?: string }) => {
    needReason(p);
    const r = findRun(p.runId);
    if (!r.test) throw new Error('err.live_not_test');
    runs.splice(runs.indexOf(r), 1);
    return { runId: p.runId };
});

registerMock('action', 'server:admin:addRunTime', (p: { runId: string; minutes: number; reason?: string }) => {
    needReason(p);
    const r = findRun(p.runId);
    if (!r.timerRunning) throw new Error('err.live_timer_not_running');
    if (p.minutes < 1 || p.minutes > 10) throw new Error('err.live_minutes_range');
    if (r.timeAdded + p.minutes * 60 > TIME_MAX) throw new Error('err.live_time_max');
    r.timeAdded += p.minutes * 60;
    r.remaining = (r.remaining ?? 0) + p.minutes * 60;
    return { runId: r.runId, timeAdded: r.timeAdded };
});

registerMock('action', 'server:admin:removeFromUnit', (p: { unitId: number; src: number; reason?: string }) => {
    needReason(p);
    const u = units.find(x => x.id === p.unitId);
    if (!u) throw new Error('err.unit_gone');
    if (u.blocked) throw new Error(u.blocked);
    u.members = u.members.filter(m => m.src !== p.src);
    if (u.members.length <= 1) units.splice(units.indexOf(u), 1);
    return { removed: p.src };
});

registerMock('action', 'server:admin:disbandUnit', (p: { unitId: number; reason?: string }) => {
    needReason(p);
    const u = units.find(x => x.id === p.unitId);
    if (!u) throw new Error('err.unit_gone');
    if (u.blocked) throw new Error(u.blocked);
    units.splice(units.indexOf(u), 1);
    return { disbanded: true };
});

// ============================================================================
//                              OFFICER RUN STATE
// ============================================================================

const state: AdminOfficerRunState = {
    citizenid: 'ABC12345',
    online: true,
    onRun: false,
    cooldowns: {
        types: [{ key: 'patrol', label: 'Patrol', until: nowS() + 210 }],
        missions: [{ id: 'beat_patrol', label: 'Beat Patrol', until: nowS() + 1500 }],
    },
    clears: { used: 1, max: 3 },
    counts: {
        today: 6,
        maxDay: 8,
        hour: 2,
        maxHour: 8,
        perType: [
            { key: 'investigation', label: 'Investigation', n: 1 },
            { key: 'patrol', label: 'Patrol', n: 3, limit: 5 },
            { key: 'tactical', label: 'Tactical', n: 1 },
            { key: 'training', label: 'Training', n: 1 },
        ],
    },
    extra: { n: 0, usedToday: false, max: 10 },
    cashToday: 4250,
    boss: { enabled: true, used: 1, extra: 0, left: 0, grantedThisWeek: false },
    freeAbandons: [
        {
            runUuid: '7a1c0f3e-0000-4000-8000-0000000000aa',
            missionType: 'patrol',
            typeLabel: 'Patrol',
            missionLabel: 'Beat Patrol',
            at: nowS() - 3600,
        },
    ],
    board: {
        cards: [
            {
                key: 'patrol',
                label: 'Patrol',
                pool: 4,
                busy: false,
                onCall: false,
                typeOfTheDay: false,
                locked: { reason: 'Patrol is on cooldown', until: nowS() + 210 },
            },
            { key: 'training', label: 'Training', pool: 3, busy: false, onCall: false, typeOfTheDay: true },
            { key: 'tactical', label: 'Tactical', pool: 2, busy: true, onCall: false, typeOfTheDay: false },
        ],
        boss: { available: false, locked: { reason: "You used this week's attempt" } },
        operation: false,
        serverTime: nowS(),
        unitSize: 1,
    },
    serverTime: nowS(),
};

registerMock('request', 'admin:getOfficerRunState', (p: { citizenid: string }) => ({
    ...state,
    citizenid: p.citizenid,
    serverTime: nowS(),
}));

registerMock('action', 'server:admin:clearCooldowns', (p: { scope: string; key?: string; reason?: string }) => {
    needReason(p);
    if (state.clears.used >= state.clears.max) throw new Error('err.live_clear_limit');
    state.clears.used += 1;
    if (p.scope === 'all') state.cooldowns = { types: [], missions: [] };
    else if (p.scope === 'type') state.cooldowns.types = state.cooldowns.types.filter(c => c.key !== p.key);
    else state.cooldowns.missions = state.cooldowns.missions.filter(c => c.id !== p.key);
    return { used: state.clears.used, max: state.clears.max };
});

registerMock('action', 'server:admin:allowExtraRuns', (p: { count: number; reason?: string }) => {
    needReason(p);
    if (state.extra.usedToday) throw new Error('err.live_extra_used');
    state.extra = { ...state.extra, n: p.count, usedToday: true };
    return { n: p.count };
});

registerMock('action', 'server:admin:grantBossAttempt', (p: { reason?: string }) => {
    needReason(p);
    if (state.boss.grantedThisWeek) throw new Error('err.live_boss_granted');
    state.boss = { ...state.boss, extra: 1, left: state.boss.left + 1, grantedThisWeek: true };
    return { week: '2026-W41' };
});

registerMock('action', 'server:admin:reclassifyAbandon', (p: { runUuid: string; reason?: string }) => {
    needReason(p);
    state.freeAbandons = state.freeAbandons.filter(a => a.runUuid !== p.runUuid);
    return { runUuid: p.runUuid };
});

// ============================================================================
//                                    TODAY
// ============================================================================

const today: AdminTodayData = {
    day: new Date().toISOString().slice(0, 10),
    todEnabled: true,
    typeOfTheDay: 'investigation',
    typeLabel: 'Investigation',
    rolled: 'investigation',
    override: null,
    todMultiplier: 2,
    boss: { enabled: true, today: true, days: ['friday', 'saturday', 'sunday'] },
    modifierChance: 0.25,
    modifiers: [
        { key: 'armored_hostiles', label: 'Armored Hostiles', tacticalOnly: true, enabled: true },
        { key: 'radio_silence', label: 'Radio Silence', tacticalOnly: false, enabled: false },
        { key: 'time_crunch', label: 'Time Crunch', tacticalOnly: false, enabled: true },
    ],
    types: [
        { key: 'investigation', label: 'Investigation' },
        { key: 'patrol', label: 'Patrol' },
        { key: 'tactical', label: 'Tactical' },
        { key: 'training', label: 'Training' },
    ],
};

registerMock('request', 'admin:getToday', () => today);

registerMock('action', 'server:admin:setTypeOfDay', (p: { type: string; reason?: string }) => {
    needReason(p);
    if (p.type === 'auto') {
        today.override = null;
        today.typeOfTheDay = today.rolled;
    } else {
        today.override = { type: p.type, by: 'console', reason: p.reason };
        today.typeOfTheDay = p.type === 'none' ? null : p.type;
    }
    return { typeOfTheDay: today.typeOfTheDay };
});
