// Browser mocks of the Dispatch screen (mission calls): getMissionCalls, server:claimMissionCall, the staff panel
// (sup:getMissionCalls and the mc* actions) and the admin area coverage and location plays.
// ?calls=empty shows no calls, ?calls=run the "on a run" notice, ?calls=op the Cross-Department Mission banner.

import { registerMock } from '../shared/nui';
import type {
    AreaCoverage,
    ClaimCallResult,
    DispatchView,
    LocationPlay,
    MissionCall,
    RecentCall,
    SupCallsView,
} from '../types/missioncalls';

const params = typeof window !== 'undefined' ? new URLSearchParams(window.location.search) : new URLSearchParams();
const MODE = params.get('calls') ?? 'default';
const nowS = () => Math.floor(Date.now() / 1000);

const AREAS = [
    { key: 'south_ls', label: 'South Los Santos' },
    { key: 'downtown', label: 'Downtown' },
    { key: 'vinewood', label: 'Vinewood' },
    { key: 'east_ls', label: 'East Los Santos' },
    { key: 'senora', label: 'Grand Senora' },
];

interface MockCall {
    call: MissionCall;
    postedAt: number;
    offer: number;
}

function base(id: number, over: Partial<MissionCall>): MissionCall {
    return {
        id,
        code: `MC-04${20 + id}`,
        type: 'patrol',
        typeLabel: 'Patrol',
        titleKey: 'mc.title.patrol.1',
        priority: 3,
        area: null,
        distance: 1400,
        ageS: 0,
        offerEndsIn: 180,
        staff: false,
        crew: 'solo',
        minUnit: null,
        cash: [250, 310],
        points: 60,
        rapidPoints: 6,
        typeOfTheDay: false,
        redispatched: false,
        paged: false,
        status: 'ready',
        priorityEndsIn: null,
        locked: null,
        claimedBy: null,
        claiming: null,
        lostBy: null,
        ...over,
    };
}

const state: { calls: MockCall[]; recent: RecentCall[]; onRun: boolean } = {
    calls: [],
    recent: [
        { code: 'MC-0417', typeLabel: 'Tactical', claimedBy: '2L-14', outcome: 'completed', at: nowS() - 900 },
        { code: 'MC-0418', typeLabel: 'Patrol', claimedBy: null, outcome: 'lapsed', at: nowS() - 700 },
        { code: 'MC-0419', typeLabel: 'Investigation', claimedBy: 'F-07', outcome: 'reopened', at: nowS() - 400 },
    ],
    onRun: MODE === 'run',
};

(function init() {
    if (MODE === 'empty') return;
    const t = nowS();
    state.calls = [
        {
            postedAt: t - 40,
            offer: 180,
            call: base(1, {
                type: 'tactical',
                typeLabel: 'Tactical',
                titleKey: 'mc.title.tactical.2',
                priority: 1,
                area: AREAS[0],
                distance: 1900,
                crew: 'unit',
                cash: [820, 1040],
                points: 200,
                rapidPoints: 20,
                status: 'priority',
                priorityEndsIn: 9,
            }),
        },
        {
            postedAt: t - 70,
            offer: 180,
            call: base(2, {
                type: 'investigation',
                typeLabel: 'Investigation',
                titleKey: 'mc.title.investigation.3',
                priority: 2,
                distance: 3100,
                cash: [600, 720],
                points: 160,
                rapidPoints: 16,
                typeOfTheDay: true,
            }),
        },
        { postedAt: t - 20, offer: 180, call: base(3, { area: AREAS[1], distance: 650 }) },
        {
            postedAt: t - 120,
            offer: 180,
            call: base(4, {
                area: AREAS[2],
                distance: 2400,
                status: 'locked',
                locked: { reason: 'Patrol is on cooldown', until: t + 190 },
            }),
        },
        {
            postedAt: t - 10,
            offer: 120,
            call: base(5, {
                titleKey: 'mc.title.patrol.5',
                area: AREAS[3],
                redispatched: true,
                staff: true,
                rapidPoints: 0,
            }),
        },
    ];
})();

function view(): DispatchView {
    const t = nowS();
    const calls = state.calls
        .map(m => ({ ...m.call, ageS: t - m.postedAt, offerEndsIn: Math.max(0, m.postedAt + m.offer - t) }))
        .filter(c => c.offerEndsIn > 0 || c.status === 'claimed');
    return {
        calls,
        unit: { size: 1, isLeader: true },
        activeRunId: state.onRun ? 'run-mock-1' : null,
        operation: MODE === 'op' ? { missionLabel: 'Prison Break' } : null,
        onCall: false,
        realCalls: { total: 3, p1: 1 },
        serverTime: t,
        recent: state.recent,
    };
}

registerMock('request', 'getMissionCalls', () => view());

registerMock('action', 'server:claimMissionCall', (payload: { callId?: number }): ClaimCallResult => {
    const m = state.calls.find(c => c.call.id === Number(payload?.callId));
    if (!m) throw new Error('err.mc_gone');
    if (m.call.status === 'priority') throw new Error('err.mc_priority');
    if (m.call.status !== 'ready') throw new Error('err.mc_taken_by');
    if (state.onRun) throw new Error('err.already_on_run');
    m.call = { ...m.call, status: 'claimed', claimedBy: { callsign: '2L-21', departmentShort: 'SAST' } };
    state.recent = [
        { code: m.call.code, typeLabel: m.call.typeLabel, claimedBy: '2L-21', outcome: 'in_progress', at: nowS() },
        ...state.recent,
    ].slice(0, 5);
    return { pending: true, code: m.call.code };
});

registerMock('request', 'sup:getMissionCalls', (): SupCallsView => {
    const v = view();
    return {
        open: v.calls.filter(c => c.status !== 'claimed'),
        units: [
            { src: 14, name: 'Maria Lopez', callsign: '2L-21', departmentShort: 'SAST', size: 2 },
            { src: 28, name: 'Leo Park', callsign: 'F-12', departmentShort: 'FIB', size: 1 },
        ],
        today: [
            {
                code: 'MC-0417',
                type: 'tactical',
                area: 'south_ls',
                status: 'closed',
                claimedBy: '2L-14',
                claimants: 2,
                claimS: 34,
                responseS: 96,
                outcome: 'completed',
            },
            {
                code: 'MC-0418',
                type: 'patrol',
                area: null,
                status: 'lapsed',
                claimedBy: null,
                claimants: 0,
                claimS: null,
                responseS: null,
                outcome: null,
            },
        ],
    };
});

for (const scope of ['sup', 'admin']) {
    registerMock('action', `server:${scope}:mcWithdraw`, (payload: { callId?: number; reason?: string }) => {
        if (!payload?.reason) throw new Error('err.reason_required');
        state.calls = state.calls.filter(c => c.call.id !== Number(payload.callId));
        return true;
    });
    registerMock('action', `server:${scope}:mcCreate`, (payload: { type?: string; area?: string | null }) => {
        const id = Math.max(0, ...state.calls.map(c => c.call.id)) + 1;
        const area = AREAS.find(a => a.key === payload?.area) ?? null;
        state.calls.push({ postedAt: nowS(), offer: 180, call: base(id, { area, staff: true, rapidPoints: 0 }) });
        return { id, code: `MC-04${20 + id}` };
    });
    registerMock('action', `server:${scope}:mcPage`, (payload: { leaderSrc?: number }) => {
        if (!payload?.leaderSrc) throw new Error('err.mc_page_target');
        const id = Math.max(0, ...state.calls.map(c => c.call.id)) + 1;
        state.calls.push({
            postedAt: nowS(),
            offer: 180,
            call: base(id, { paged: true, staff: true, rapidPoints: 0 }),
        });
        return { id, code: `MC-04${20 + id}` };
    });
}

registerMock('request', 'admin:getAreaCoverage', (): AreaCoverage => {
    const types = ['investigation', 'patrol', 'tactical', 'training'];
    const cells: AreaCoverage['cells'] = {};
    types.forEach((ty, i) => {
        cells[ty] = {};
        AREAS.forEach((a, j) => {
            const missions = (i + j) % 4;
            cells[ty][a.key] = { missions, locations: missions * 2 + (j % 2) };
        });
    });
    return { types, areas: AREAS, cells };
});

registerMock('request', 'admin:getLocationStats', (): LocationPlay[] =>
    [1, 2, 3, 4, 5, 6].map(i => ({
        index: i,
        label: `Location ${i}`,
        plays: (i * 7) % 11,
        lastPlayed: i % 3 === 0 ? null : nowS() - i * 3600,
        area: AREAS[i % AREAS.length].key,
    })),
);
