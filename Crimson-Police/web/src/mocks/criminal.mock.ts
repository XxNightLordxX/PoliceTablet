// Browser mocks of the criminal tablet (step G2): crimtab:get and server:crimtab:act over one volunteer, with a job
// to answer. ?ui=crimtab opens it on load.

import { emitDebug, registerMock } from '../shared/nui';
import type { CrimRole, CrimView } from '../types/criminal';

const PARAMS = new URLSearchParams(typeof window !== 'undefined' ? window.location.search : '');
const now = () => Math.floor(Date.now() / 1000);

let view: CrimView = {
    now: now(),
    volunteersOn: true,
    name: 'Jamie Cole',
    status: { listed: false, roles: [], allRoles: ['runner', 'driver', 'fugitive'], canJoin: true },
    jobs: [],
    active: null,
    history: [
        {
            endedAt: now() - 5400,
            missionType: 'Investigation',
            role: 'runner',
            outcome: 'got_away',
            result: 'completed',
        },
        { endedAt: now() - 9000, missionType: 'Patrol', role: 'driver', outcome: 'void', dropout: 'no_show' },
    ],
    strikes: [now() + 3600 * 20],
    rules: {
        windowMinutes: 60,
        strikes: 3,
        strikeHours: 24,
        blockHours: 24,
        askSeconds: 30,
        travelMinutes: 5,
        cancelGraceSeconds: 60,
    },
};

function fresh(): CrimView {
    return JSON.parse(JSON.stringify({ ...view, now: now() })) as CrimView;
}

// A job comes in (the walk and the dev panel): what V.askOf answers.
export function mockCrimJob(): void {
    view.jobs = [
        {
            token: `va${Date.now() % 100000}`,
            role: 'runner',
            missionType: 'Investigation',
            area: 'Grove Street, Davis',
            km: 1.4,
            seconds: 30,
            travelMinutes: 5,
            reward: '$1,500 if you get away, $500 if you are caught (a fair case: police reached you and you played it out)',
        },
    ];
}

export function mockCrimReset(): void {
    view.status = { listed: false, roles: [], allRoles: ['runner', 'driver', 'fugitive'], canJoin: true };
    view.jobs = [];
    view.active = null;
}

registerMock('request', 'crimtab:get', () => fresh());

registerMock(
    'action',
    'server:crimtab:act',
    (p: { what?: string; roles?: CrimRole[]; token?: string; yes?: boolean }) => {
        switch (p?.what) {
            case 'join':
                if (view.status.listed) throw new Error('volunteer.refused.already');
                if (!p.roles || p.roles.length === 0) throw new Error('volunteer.refused.no_role');
                view.status = { ...view.status, listed: true, roles: p.roles, canJoin: false, untilAt: now() + 3600 };
                break;
            case 'roles':
                if (!p.roles || p.roles.length === 0) throw new Error('volunteer.refused.no_role');
                view.status.roles = p.roles;
                break;
            case 'renew':
                if (!view.status.listed) throw new Error('volunteer.refused.not_listed');
                view.status.untilAt = now() + 3600;
                break;
            case 'stop':
                mockCrimReset();
                break;
            case 'answer': {
                const job = view.jobs.find(j => j.token === p.token);
                if (!job) throw new Error('err.crimtab_job_gone');
                view.jobs = [];
                if (p.yes)
                    view.active = {
                        phase: 'travel',
                        role: job.role,
                        meet: { x: 102.4, y: -1938.2, z: 20.8 },
                        seconds: 300,
                        freeCancel: true,
                        graceSeconds: 60,
                    };
                break;
            }
            case 'cancel':
                if (!view.active) throw new Error('volunteer.refused.no_case');
                view.active = null;
                break;
            default:
                throw new Error('err.invalid_payload');
        }
        return fresh();
    },
);

if (PARAMS.get('ui') === 'crimtab') {
    mockCrimJob();
    emitDebug('crimtab', { open: true, view: fresh(), screen: null }, 400);
}
