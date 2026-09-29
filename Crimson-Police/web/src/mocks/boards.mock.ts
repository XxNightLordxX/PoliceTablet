// Browser mocks for the boards slice (Leaderboard, Department Challenge, Profile & History, Admin Seasons &

import { registerMock, type MockFn, type MockKind } from '../shared/nui';
import type { BoardRow, RunResult } from '../shared/types';
import type {
    ActivityRun,
    AdminBoardRow,
    AdminBoards,
    AdminRun,
    BoardView,
    BountyHistoryRow,
    BountyView,
    ChallengeData,
    ChallengeDepartment,
    Contributor,
    DeptContributors,
    DeptReport,
    OfficerActivity,
    ProfileData,
    ProfileRunView,
    ReportOfficer,
    SeasonListRow,
    SeasonView,
    SeasonsAdmin,
    StuckPayment,
} from '../types/boards';
import { devState } from './devState';
import { MOCK_DEPARTMENTS, sampleResult } from './samples';

const DAY = 86400;
const now = () => Math.floor(Date.now() / 1000);
const sqlTime = (ts: number) => {
    const d = new Date(ts * 1000);
    const p = (n: number) => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
};
function weekStart(ts = now()): number {
    const d = new Date(ts * 1000);
    const back = (d.getDay() + 6) % 7;
    d.setHours(0, 0, 0, 0);
    d.setDate(d.getDate() - back);
    return Math.floor(d.getTime() / 1000);
}
function monthStart(ts = now()): number {
    const d = new Date(ts * 1000);
    return Math.floor(new Date(d.getFullYear(), d.getMonth(), 1).getTime() / 1000);
}
function hash(s: string): number {
    let h = 2166136261;
    for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619) >>> 0;
    return h;
}

const DEPTS: Record<string, { key: string; label: string; short: string; colour: string }> = {
    sast: { key: 'sast', label: 'San Andreas State Troopers', short: 'SAST', colour: '#1f4e8c' },
    fib: { key: 'fib', label: 'Federal Investigation Bureau', short: 'FIB', colour: '#1c2541' },
};

// ============================================================================
//                               THE OFFICER POOL
// ============================================================================

interface MockOfficer {
    citizenid: string;
    name: string;
    callsign: string | null;
    dept: 'sast' | 'fib';
    rank: string;
    hide: boolean;
    weekly: number;
    runs: number;
    failed: number;
    xp: number;
}
const POOL: MockOfficer[] = [
    ['LPD10231', 'Maria Lopez', '2L-21', 'sast', 'Lieutenant', false, 1540, 9, 0, 38400],
    ['FIB00042', 'Dana Whitfield', null, 'fib', 'Special Agent', false, 1485, 8, 1, 29100],
    ['SAS30117', 'Marcus Reed', '1A-07', 'sast', 'Sergeant', false, 1410, 8, 0, 21950],
    ['FIB00311', 'Priya Natarajan', 'F-311', 'fib', 'Senior Agent', true, 1410, 8, 2, 18720],
    ['SAS20981', 'Tom Hadley', '2L-09', 'sast', 'Trooper', false, 1290, 7, 1, 16400],
    ['FIB00190', 'Elena Sokolova', 'F-190', 'fib', 'Special Agent', false, 1185, 7, 0, 15210],
    ['SAS41100', 'Jamal Brooks', '3K-33', 'sast', 'Senior Trooper', false, 1160, 7, 1, 14020],
    ['SAS10222', 'Grace Kim', '2L-02', 'sast', 'Corporal', false, 1070, 6, 0, 12880],
    ['FIB00418', 'Owen Mercer', 'F-418', 'fib', 'Agent', false, 1040, 6, 2, 11320],
    ['SAS55501', 'Rosa Delgado', '1A-15', 'sast', 'Trooper', true, 985, 6, 1, 9870],
    ['FIB00077', 'Victor Hale', 'F-077', 'fib', 'Supervisory Agent', false, 960, 6, 0, 9450],
    ['SAS62040', 'Nate Ellison', '2L-30', 'sast', 'Trooper', false, 905, 5, 1, 8110],
    ['FIB00502', 'Hannah Cho', 'F-502', 'fib', 'Agent', false, 880, 5, 0, 7760],
    ['SAS70713', 'Luca Romano', '3K-12', 'sast', 'Senior Trooper', false, 845, 5, 2, 7020],
    ['SAS80414', 'Aisha Grant', '1A-22', 'sast', 'Trooper', false, 790, 5, 0, 6400],
    ['FIB00613', 'Caleb Stone', 'F-613', 'fib', 'Agent', true, 760, 5, 1, 5930],
    ['SAS90315', 'Ivy Chen', '2L-41', 'sast', 'Trooper', false, 700, 4, 0, 5100],
    ['FIB00724', 'Samuel Ortiz', 'F-724', 'fib', 'Agent', false, 655, 4, 1, 4480],
    ['SAS11816', 'Derek Walsh', '3K-05', 'sast', 'Corporal', false, 610, 4, 0, 3920],
    ['SAS12917', 'Nina Petrova', '1A-31', 'sast', 'Trooper', false, 575, 4, 2, 3310],
    ['FIB00835', 'Ethan Park', 'F-835', 'fib', 'Probationary Agent', false, 540, 4, 0, 2870],
    ['SAS13018', 'Bianca Russo', '2L-17', 'sast', 'Trooper', false, 505, 3, 0, 2240],
    ['FIB00946', 'Leo Fischer', 'F-946', 'fib', 'Agent', false, 470, 3, 1, 1990],
    ['SAS14119', 'Chloe Adams', '3K-28', 'sast', 'Trooper', false, 440, 3, 0, 1720],
    ['SAS15220', 'Ravi Menon', '1A-40', 'sast', 'Trooper', false, 410, 3, 1, 1480],
    ['FIB01057', 'Sofia Marin', 'F-057', 'fib', 'Agent', false, 385, 3, 0, 1260],
    ['SAS16321', 'Kyle Brennan', '2L-44', 'sast', 'Trooper', false, 360, 3, 1, 1150],
    ['ABC12345', 'John Doe', '2L-14', 'sast', 'Sergeant', false, 335, 3, 1, 11250],
    ['FIB01168', 'Mia Laurent', 'F-168', 'fib', 'Agent', false, 300, 3, 0, 940],
    ['SAS17422', 'Omar Haddad', '3K-19', 'sast', 'Trooper', false, 260, 2, 0, 820],
    ['BCS00777', 'Earl Hutchins', '1K-07', 'sast', 'Deputy', false, 180, 2, 1, 610],
    ['SAS18523', 'Paige Turner', '1A-08', 'sast', 'Trooper', false, 120, 1, 0, 350],
].map(
    ([citizenid, name, callsign, dept, rank, hide, weekly, runs, failed, xp]) =>
        ({
            citizenid,
            name,
            callsign,
            dept,
            rank,
            hide,
            weekly,
            runs,
            failed,
            xp,
        }) as MockOfficer,
);

// ============================================================================
//                       EDGE-CASE MODES FOR SCREENSHOTS
// ============================================================================
// ?boards=edge (64-char names, 32-char callsigns, missing callsigns,
// big numbers) and ?boards=empty (every list arrives as {} the way Lua encodes an empty table) ─────────
const MOCK_MODE = typeof window !== 'undefined' ? new URLSearchParams(window.location.search).get('boards') : null;
const LONG_NAME = 'Maximilian Alexander Montgomery-Fitzgerald Wolfeschlegelsteinhausen';
if (MOCK_MODE === 'edge') {
    POOL.forEach((o, i) => {
        if (i % 3 === 0) o.name = `${o.name.split(' ')[0]} ${LONG_NAME}`.slice(0, 64);
        if (i % 2 === 1) o.callsign = null;
        else if (i % 4 === 0) o.callsign = `${o.callsign ?? 'X'}-SUPERVISOR-UNIT-ALPHA-XRAY`.slice(0, 32);
    });
    POOL[0].weekly = 32767;
    POOL[0].xp = 1250000;
    POOL[0].runs = 999;
}
// Lua's empty table: arrives as {} instead of [].
const LUA_EMPTY = {} as unknown as never[];
function emptied(name: string, data: unknown): unknown {
    if (MOCK_MODE !== 'empty' || !data || typeof data !== 'object') return data;
    const d = { ...(data as Record<string, unknown>) };
    const clear = (...keys: string[]) =>
        keys.forEach(k => {
            d[k] = LUA_EMPTY;
        });
    switch (name) {
        case 'getBoard':
            clear('rows');
            d.ranked = 0;
            d.me = { ...(d.me as object), rank: 0, points: 0, runs: 0, failed: 0 };
            break;
        case 'getProfile':
            clear('runs', 'badges');
            d.xp = 0;
            d.seasonPoints = 0;
            d.callsign = null;
            d.level = { label: 'Probationary', badge: 'grey', xp: 0, next: 1000 };
            break;
        case 'getChallenge':
            clear('topContributors');
            d.departments = (d.departments as ChallengeDepartment[]).map(x => ({
                ...x,
                score: 0,
                activeOfficers: 0,
                officers: 0,
                points: 0,
                completed: 0,
                unitRuns: 0,
                bonus: 0,
            }));
            d.bounty = d.bounty ? { ...(d.bounty as object), leader: null, leaderKey: null, rates: LUA_EMPTY } : null;
            break;
        case 'getDeptContributors':
            clear('contributors');
            break;
        case 'admin:getSeasons':
            clear('bountyHistory', 'seasons', 'standings');
            d.current = null;
            d.latest = null;
            d.bounty = null;
            break;
        case 'admin:getBoards':
            clear('rows', 'unranked', 'stuck');
            if ('runs' in d) clear('runs');
            break;
        case 'sup:getDeptReport':
            clear('officers', 'standings');
            d.standing = null;
            d.bounty = null;
            d.season = null;
            break;
        case 'sup:getOfficerActivity':
            clear('runs');
            break;
        default:
            break;
    }
    return d;
}
function reg(kind: MockKind, name: string, fn: MockFn, opts?: { fallback?: boolean }): void {
    registerMock(
        kind,
        name,
        (payload: unknown) => {
            const out = fn(payload);
            return kind === 'request' ? emptied(name, out) : out;
        },
        opts,
    );
}

const byCid = (cid: string) => POOL.find(o => o.citizenid === cid);
const hidden = new Set(POOL.filter(o => o.hide).map(o => o.citizenid));
const publicName = (o: MockOfficer) => (hidden.has(o.citizenid) ? (o.callsign ?? 'Hidden officer') : o.name);
const viewer = () => (MOCK_DEPARTMENTS[devState.department] ?? MOCK_DEPARTMENTS.sast).officer;

const FILTER_SHARE: Record<string, number> = {
    overall: 1,
    patrol: 0.28,
    training: 0.22,
    investigation: 0.24,
    tactical: 0.34,
    unit: 0.46,
    cross: 0.21,
};

interface Entry {
    o: MockOfficer;
    points: number;
    runs: number;
    failed: number;
    cash: number;
}
function entries(period: string, filter: string, department?: string): Entry[] {
    const mult = period === 'monthly' ? 3.6 : period === 'season' ? 5.2 : 1;
    const list: Entry[] = [];
    for (const o of POOL) {
        if (filter === 'department' && o.dept !== (department ?? 'sast')) continue;
        const jitter = ((hash(`${o.citizenid}:${period}:${filter}`) % 21) - 10) / 100;
        const share = filter === 'department' ? 1 : (FILTER_SHARE[filter] ?? 0.25);
        if (period === 'alltime') {
            list.push({
                o,
                points: o.xp,
                runs: Math.round(o.xp / 95),
                failed: Math.round(o.xp / 1900),
                cash: Math.round(o.xp * 4.1),
            });
            continue;
        }
        const runs = Math.max(
            0,
            Math.round(
                o.runs * mult * (filter === 'overall' || filter === 'department' ? 1 : share * 1.6) * (1 + jitter),
            ),
        );
        const points = Math.max(0, Math.round((o.weekly * mult * share * (1 + jitter)) / 5) * 5);
        const failed = Math.round(o.failed * mult * (filter === 'overall' || filter === 'department' ? 1 : share));
        if (runs === 0 && points === 0) continue;
        list.push({ o, points, runs, failed, cash: Math.round(points * 5.6) });
    }
    // The viewer ranks lower in the weekly overall board (pinned row outside the top 25).
    return list.sort(
        (a, b) => b.points - a.points || a.failed - b.failed || a.o.citizenid.localeCompare(b.o.citizenid),
    );
}

function toRow(e: Entry, rank: number, viewerCid: string): BoardRow {
    const own = e.o.citizenid === viewerCid;
    return {
        rank,
        citizenid: e.o.citizenid,
        name: own ? e.o.name : publicName(e.o),
        callsign: e.o.callsign,
        departmentShort: DEPTS[e.o.dept].short,
        points: e.points,
        runs: e.runs,
        failed: e.failed,
    };
}

const SEASONS: SeasonListRow[] = [
    {
        id: 1,
        name: 'Season 1 · Founders',
        startsAt: now() - 150 * DAY,
        endsAt: now() - 94 * DAY,
        active: false,
        champion: 'sast',
        championShort: 'SAST',
    },
    {
        id: 2,
        name: 'Season 2 · Summer Heat',
        startsAt: now() - 94 * DAY,
        endsAt: now() - 25 * DAY,
        active: false,
        champion: 'fib',
        championShort: 'FIB',
    },
    {
        id: 3,
        name: 'Season 3 · Autumn Offensive',
        startsAt: now() - 25 * DAY,
        endsAt: null,
        active: true,
        champion: null,
        championShort: null,
    },
];
if (MOCK_MODE === 'edge')
    SEASONS[2].name = 'Season 3 · The Very Long Autumn Offensive Against Organised Crime'.slice(0, 64);
const currentSeason = () => SEASONS.find(s => s.active) ?? null;
const latestSeason = () => currentSeason() ?? SEASONS[SEASONS.length - 1] ?? null;
const SEASON_WEEKS = 8;
function seasonView(s: SeasonListRow): SeasonView {
    const week = Math.floor((weekStart(s.endsAt ?? now()) - weekStart(s.startsAt)) / (7 * DAY) + 0.5) + 1;
    const weeksLeft = s.active ? Math.max(0, Math.ceil((s.startsAt + SEASON_WEEKS * 7 * DAY - now()) / (7 * DAY))) : 0;
    return {
        id: s.id,
        name: s.name,
        startsAt: s.startsAt,
        endsAt: s.endsAt ?? null,
        active: s.active,
        week,
        weeksLeft,
    };
}

reg('request', 'getBoard', (args: { period?: string; filter?: string; department?: string } | null) => {
    const period = args?.period ?? 'weekly';
    const filter = period === 'alltime' ? 'overall' : (args?.filter ?? 'overall');
    const me = viewer();
    const department = filter === 'department' ? (args?.department ?? me.department) : undefined;
    if (!['weekly', 'monthly', 'season', 'alltime'].includes(period)) throw new Error('err.invalid_period');
    const season = latestSeason();
    const list = period === 'season' && !season ? [] : entries(period, filter, department);
    const ranked = list.filter(e => e.runs >= 3);
    const rows = ranked.slice(0, 25).map((e, i) => toRow(e, i + 1, me.citizenid));
    const mineIdx = ranked.findIndex(e => e.o.citizenid === me.citizenid);
    const mine = list.find(e => e.o.citizenid === me.citizenid);
    const board: BoardView = {
        period,
        filter,
        department,
        rows,
        me: mine
            ? toRow(mine, mineIdx >= 0 ? mineIdx + 1 : 0, me.citizenid)
            : {
                  rank: 0,
                  citizenid: me.citizenid,
                  name: me.name,
                  callsign: me.callsign,
                  departmentShort: me.departmentShort,
                  points: 0,
                  runs: 0,
                  failed: 0,
              },
        updatedAt: now() - 23,
        minRuns: 3,
        topN: 25,
        ranked: ranked.length,
        window:
            period === 'weekly'
                ? { from: weekStart() }
                : period === 'monthly'
                  ? { from: monthStart() }
                  : period === 'season' && season
                    ? { from: season.startsAt, to: season.endsAt }
                    : null,
        season: period === 'season' && season ? { id: season.id, name: season.name, active: season.active } : null,
    };
    return board;
});

// ============================================================================
//                                   PROFILE
// ============================================================================

const LEVELS = [
    { label: 'Probationary', xp: 0, badge: 'grey' },
    { label: 'Patrol Officer', xp: 1000, badge: 'bronze' },
    { label: 'Senior Patrol', xp: 5000, badge: 'silver' },
    { label: 'Veteran', xp: 15000, badge: 'gold' },
    { label: 'Elite', xp: 40000, badge: 'platinum' },
];
function level(xp: number) {
    let cur = LEVELS[0];
    let next: number | null = LEVELS[1].xp;
    LEVELS.forEach((l, i) => {
        if (xp >= l.xp) {
            cur = l;
            next = LEVELS[i + 1]?.xp ?? null;
        }
    });
    return { label: cur.label, badge: cur.badge, xp: cur.xp, next };
}

const MISSIONS: [string, string, string][] = [
    ['Gang Shootout', 'tactical', 'gang_shootout'],
    ['Beat Patrol', 'patrol', 'beat_patrol'],
    ['Business Check', 'patrol', 'business_check'],
    ['EVOC Course', 'training', 'evoc_course'],
    ['Pursuit Sim', 'training', 'pursuit_sim'],
    ['Warrant Service', 'investigation', 'warrant_service'],
    ['Manhunt', 'investigation', 'manhunt'],
    ['Hostage Rescue', 'tactical', 'hostage_rescue'],
    ['Stolen Vehicle Takedown', 'investigation', 'stolen_vehicle_takedown'],
    ['Street Race Bust', 'patrol', 'street_race_bust'],
];
if (MOCK_MODE === 'edge') MISSIONS[0][0] = 'Armored Truck Escort Through Blaine County And All The Way Back';
const END_REASONS: [string, string][] = [
    ['completed', 'completed'],
    ['completed', 'completed'],
    ['failed', 'time_limit'],
    ['completed', 'completed'],
    ['abandoned', 'real_call'],
    ['completed', 'completed'],
    ['failed', 'downed'],
    ['completed', 'completed'],
    ['abandoned', 'quit'],
    ['completed', 'completed'],
];

function breakdownFor(label: string, type: string, state: string, endReason: string, i: number): RunResult {
    const base = sampleResult(state === 'failed' ? 'failed' : 'completed');
    const P = { patrol: 60, training: 100, investigation: 160, tactical: 200 }[type] ?? 100;
    const b: RunResult = JSON.parse(JSON.stringify(base));
    b.runId = `mock-run-${i}`;
    b.missionLabel = label;
    b.missionType = type;
    b.result = state as RunResult['result'];
    b.endReason = endReason;
    b.points.P = P;
    if (state === 'abandoned') {
        b.points = {
            P,
            bonuses: [],
            penalties: [],
            subtotal: 0,
            mTeam: 1,
            mCross: 1,
            mStreak: 1,
            capped: false,
            tod: false,
            failedShare: null,
            final: 0,
        };
        b.cash = { B: P * 4, mTier: 1, mMod: 1, amount: 0, status: 'none' };
    } else if (state === 'failed') {
        b.points.final = Math.floor(P * 0.25 * 0.5);
        b.points.subtotal = b.points.final;
        b.cash = { B: P * 4, mTier: 1, mMod: 1, amount: 0, status: 'none' };
    } else {
        b.points.subtotal = Math.round(P * 1.3);
        b.points.final = Math.min(
            P * 2,
            Math.floor(b.points.subtotal * b.points.mTeam * b.points.mCross * b.points.mStreak),
        );
        b.cash = { B: P * 4, mTier: b.cash.mTier, mMod: 1, amount: Math.round(P * 4 * b.cash.mTier), status: 'paid' };
    }
    return b;
}

const disputed = new Set<number>();
const voided = new Set<number>();
function runsFor(cid: string, own: boolean): ProfileRunView[] {
    const seed = hash(cid);
    const out: ProfileRunView[] = [];
    const t0 = now();
    for (let i = 0; i < 20; i++) {
        const [label, type, _id] = MISSIONS[(seed + i * 7) % MISSIONS.length];
        void _id;
        const [state, endReason] = END_REASONS[(seed + i) % END_REASONS.length];
        const id = 4800 - i * 3 - (seed % 3);
        const createdTs = t0 - i * 9 * 3600 - (seed % 1800) - 1200;
        const bd = breakdownFor(label, type, state, endReason, id);
        const flagged = own && i === 1;
        const isVoided = voided.has(id) || (own && i === 5);
        if (flagged) {
            bd.flagged = { reason: 'outside_help' };
            bd.cash.status = 'held';
        }
        const cashStatus = flagged ? 'held' : bd.cash.status;
        const inWindow = t0 - createdTs <= 48 * 3600;
        const run: ProfileRunView = {
            id,
            missionLabel: label,
            missionType: type,
            state,
            endReason,
            points: bd.points.final,
            cash: own && !flagged ? bd.cash.amount : 0,
            cashStatus: own ? cashStatus : '',
            flagged,
            voided: isVoided,
            createdAt: sqlTime(createdTs),
            createdTs,
            breakdown: own ? bd : ({ ...bd, cash: undefined } as unknown as RunResult),
            canDispute: own && inWindow && (flagged || isVoided || state === 'failed') && !disputed.has(id),
        };
        out.push(run);
    }
    if (own) {
        out.splice(3, 0, {
            id: 4777,
            missionLabel: 'Manual award',
            missionType: 'manual_award',
            state: 'completed',
            endReason: 'manual_award',
            points: 150,
            cash: 0,
            cashStatus: 'none',
            flagged: false,
            voided: false,
            createdAt: sqlTime(t0 - 30 * 3600),
            createdTs: t0 - 30 * 3600,
            breakdown: null,
            canDispute: false,
        });
        out.splice(8, 0, {
            id: 4760,
            missionLabel: 'Complete 2 Patrol missions',
            missionType: 'goal',
            state: 'completed',
            endReason: 'goal',
            points: 50,
            cash: 0,
            cashStatus: 'none',
            flagged: false,
            voided: false,
            createdAt: sqlTime(t0 - 60 * 3600),
            createdTs: t0 - 60 * 3600,
            breakdown: null,
            canDispute: false,
        });
        out.length = 20;
    }
    return out;
}

let hideOwn = false;
reg('request', 'getProfile', (args: { citizenid?: string } | string | null) => {
    const me = viewer();
    const cid = typeof args === 'string' ? args : args?.citizenid;
    const own = !cid || cid === me.citizenid;
    const o = own ? byCid(me.citizenid) : byCid(cid as string);
    if (!own && !o) throw new Error('err.unknown_officer');
    const xp = o?.xp ?? 11250;
    const profile: ProfileData = {
        citizenid: own ? me.citizenid : (o as MockOfficer).citizenid,
        name: own ? me.name : publicName(o as MockOfficer),
        callsign: own ? me.callsign : (o as MockOfficer).callsign,
        rank: own ? me.rank : (o as MockOfficer).rank,
        departmentShort: own ? me.departmentShort : DEPTS[(o as MockOfficer).dept].short,
        departmentLabel: own ? me.departmentLabel : DEPTS[(o as MockOfficer).dept].label,
        xp,
        level: level(xp),
        badges: own
            ? [
                  {
                      id: 'season_2_champion',
                      label: 'Season 2 · Summer Heat Champions',
                      earnedAt: sqlTime(now() - 25 * DAY),
                      kind: 'champion',
                  },
                  {
                      id: 'officer_of_week_2026-09-14',
                      label: 'Officer of the Week · 14 Sep',
                      earnedAt: sqlTime(now() - 8 * DAY),
                      kind: 'week',
                  },
                  {
                      id: 'season_2_top10',
                      label: 'Season 2 · Summer Heat · Top 10',
                      earnedAt: sqlTime(now() - 25 * DAY),
                      kind: 'top10',
                  },
                  { id: 'iron_wheels', label: 'Iron Wheels', earnedAt: sqlTime(now() - 40 * DAY), kind: 'achievement' },
                  {
                      id: 'partner_in_crime',
                      label: 'Partner in Crime',
                      earnedAt: sqlTime(now() - 51 * DAY),
                      kind: 'achievement',
                  },
                  {
                      id: 'joint_task_force',
                      label: 'Joint Task Force',
                      earnedAt: sqlTime(now() - 63 * DAY),
                      kind: 'achievement',
                  },
              ]
            : [{ id: 'road_warrior', label: 'Road Warrior', earnedAt: sqlTime(now() - 12 * DAY), kind: 'achievement' }],
        hideName: own ? hideOwn : !!o && hidden.has(o.citizenid),
        own,
        runs: runsFor(own ? me.citizenid : (o as MockOfficer).citizenid, own),
        seasonPoints: own ? 2860 : Math.round(((o as MockOfficer).weekly || 100) * 5.2),
        disputeWindowHours: 48,
    };
    return profile;
});

reg('action', 'server:setHideName', (value: unknown) => {
    const v = typeof value === 'object' && value !== null ? (value as { hideName?: unknown }).hideName : value;
    if (typeof v !== 'boolean') throw new Error('err.invalid_payload');
    hideOwn = v;
    return { hideName: v };
});

reg(
    'action',
    'server:dispute',
    (payload: { rowId?: number; reason?: string } | null) => {
        if (!payload?.rowId || !payload.reason?.trim()) throw new Error('err.invalid_payload');
        disputed.add(payload.rowId);
        return { disputeId: 900 + disputed.size };
    },
    { fallback: true },
);

// ============================================================================
//                             DEPARTMENT CHALLENGE
// ============================================================================

let bountyObjective = 'most_cross';
const BOUNTIES = [
    { id: 'most_tactical', label: 'Most Tactical missions' },
    { id: 'most_cross', label: 'Most cross-department runs' },
    { id: 'most_unit', label: 'Most unit runs' },
    { id: 'most_completed', label: 'Most completed runs' },
];
function standings(): ChallengeDepartment[] {
    if (!currentSeason())
        return Object.values(DEPTS).map((d, i) => ({
            ...d,
            score: 0,
            activeOfficers: 0,
            officers: 0,
            points: 0,
            completed: 0,
            unitRuns: 0,
            bonus: 0,
            rank: i + 1,
        }));
    return [
        {
            ...DEPTS.fib,
            score: 1284,
            activeOfficers: 11,
            officers: 13,
            points: 13842,
            completed: 162,
            unitRuns: 71,
            bonus: 281,
            rank: 1,
        },
        {
            ...DEPTS.sast,
            score: 1196,
            activeOfficers: 18,
            officers: 21,
            points: 21115,
            completed: 247,
            unitRuns: 96,
            bonus: 402,
            rank: 2,
        },
    ];
}
function bounty(): BountyView | null {
    if (!currentSeason()) return null;
    const endsIn = weekStart() + 7 * DAY - now();
    const counts: Record<string, [number, number]> = {
        most_cross: [14, 8],
        most_tactical: [22, 17],
        most_unit: [31, 19],
        most_completed: [64, 41],
    };
    const [s, f] = counts[bountyObjective] ?? [10, 10];
    const rates = [
        {
            key: 'sast',
            short: 'SAST',
            colour: DEPTS.sast.colour,
            count: s,
            activeOfficers: 18,
            rate: Math.round((s / 18) * 100) / 100,
        },
        {
            key: 'fib',
            short: 'FIB',
            colour: DEPTS.fib.colour,
            count: f,
            activeOfficers: 11,
            rate: Math.round((f / 11) * 100) / 100,
        },
    ].sort((a, b) => b.rate - a.rate);
    return {
        id: bountyObjective,
        label: BOUNTIES.find(b => b.id === bountyObjective)?.label ?? bountyObjective,
        leader: rates[0].short,
        leaderKey: rates[0].key,
        week: seasonView(currentSeason() as SeasonListRow).week,
        endsIn,
        closed: false,
        overridden: bountyObjective !== 'most_cross',
        rates,
    };
}
function contributors(dept: string, limit = 50): Contributor[] {
    return POOL.filter(o => o.dept === dept)
        .map(o => ({ o, points: Math.round(o.weekly * 5.2), runs: o.runs * 5 }))
        .sort((a, b) => b.points - a.points)
        .slice(0, limit)
        .map((e, i) => ({
            rank: i + 1,
            citizenid: e.o.citizenid,
            name: publicName(e.o),
            callsign: e.o.callsign,
            points: e.points,
            runs: e.runs,
            active: e.runs >= 3,
        }));
}

reg('request', 'getChallenge', () => {
    const me = viewer();
    const season = currentSeason();
    const view: ChallengeData = {
        enabled: true,
        mode: 'average',
        minRunsActive: 3,
        myDepartment: me.department === 'bcso' ? 'sast' : me.department,
        season: season
            ? {
                  id: season.id,
                  name: season.name,
                  weeksLeft: seasonView(season).weeksLeft,
                  week: seasonView(season).week,
                  startsAt: season.startsAt,
              }
            : null,
        departments: standings(),
        bounty: bounty(),
        topContributors: season ? contributors(me.department === 'fib' ? 'fib' : 'sast', 5) : [],
    };
    return view;
});

reg('request', 'getDeptContributors', (args: { department?: string } | null) => {
    const key = args?.department ?? 'sast';
    const d = DEPTS[key];
    if (!d) throw new Error('err.unknown_department');
    const season = currentSeason();
    const out: DeptContributors = {
        department: d,
        season: season ? { id: season.id, name: season.name } : null,
        minRunsActive: 3,
        contributors: season ? contributors(key) : [],
    };
    return out;
});

// ============================================================================
//                                ADMIN: seasons
// ============================================================================

function history(): BountyHistoryRow[] {
    const out: BountyHistoryRow[] = [];
    for (const s of [...SEASONS].reverse()) {
        const weeks = seasonView(s).week;
        for (let w = weeks; w >= 1; w--) {
            const ws = weekStart(s.startsAt) + (w - 1) * 7 * DAY;
            const isCurrent = s.active && w === weeks;
            const objective = isCurrent ? bountyObjective : BOUNTIES[hash(`${s.id}:${w}`) % BOUNTIES.length].id;
            const winner = isCurrent
                ? null
                : hash(`w${s.id}:${w}`) % 5 === 0
                  ? ''
                  : hash(`x${s.id}:${w}`) % 2
                    ? 'sast'
                    : 'fib';
            out.push({
                seasonId: s.id,
                seasonName: s.name,
                week: w,
                objective,
                label: BOUNTIES.find(b => b.id === objective)?.label ?? objective,
                winner: winner || null,
                winnerShort: winner ? DEPTS[winner].short : null,
                bonus: winner ? 120 + (hash(`b${s.id}:${w}`) % 180) : 0,
                closed: !isCurrent,
                current: isCurrent,
                startsAt: Math.max(ws, s.startsAt),
                endsAt: Math.min(ws + 7 * DAY, s.endsAt ?? ws + 7 * DAY),
            });
            if (out.length >= 14) return out;
        }
    }
    return out;
}

reg('request', 'admin:getSeasons', () => {
    const cur = currentSeason();
    const latest = latestSeason();
    const data: SeasonsAdmin = {
        current: cur ? seasonView(cur) : null,
        latest: !cur && latest ? seasonView(latest) : null,
        standings: standings(),
        bounty: bounty(),
        bountyHistory: history(),
        seasons: [...SEASONS].reverse(),
        bounties: BOUNTIES,
        enabled: true,
        weeklyBounty: true,
        mode: 'average',
        seasonWeeks: SEASON_WEEKS,
        minRunsActive: 3,
    };
    return data;
});

reg('action', 'server:admin:startSeason', (payload: { name?: string } | null) => {
    const name = (payload?.name ?? '').trim();
    if (!name || name.length > 64) throw new Error('err.invalid_season_name');
    const cur = currentSeason();
    if (cur) {
        cur.active = false;
        cur.endsAt = now();
        cur.champion = 'fib';
        cur.championShort = 'FIB';
    }
    const s: SeasonListRow = { id: SEASONS.length + 1, name, startsAt: now(), endsAt: null, active: true };
    SEASONS.push(s);
    bountyObjective = BOUNTIES[hash(`${s.id}:1`) % BOUNTIES.length].id;
    return seasonView(s);
});

reg('action', 'server:admin:endSeason', () => {
    const cur = currentSeason();
    if (!cur) throw new Error('err.no_season');
    cur.active = false;
    cur.endsAt = now();
    cur.champion = 'fib';
    cur.championShort = 'FIB';
    return { season: seasonView(cur), champion: 'fib', standings: standings(), top10: [] };
});

reg('action', 'server:admin:overrideBounty', (payload: { objective?: string } | null) => {
    if (!currentSeason()) throw new Error('err.no_season');
    if (!BOUNTIES.some(b => b.id === payload?.objective)) throw new Error('err.invalid_bounty');
    bountyObjective = payload?.objective as string;
    return bounty();
});

// ============================================================================
//                             ADMIN: leaderboards
// ============================================================================

const STUCK: StuckPayment[] = [
    {
        rowId: 48213,
        runUuid: '7c9e6679-7425-40de-944b-e07fc1f90ae7',
        citizenid: 'SAS30117',
        name: 'Marcus Reed',
        callsign: '1A-07',
        missionLabel: 'Armored Truck Escort',
        amount: 1170,
        createdAt: sqlTime(now() - 5 * 3600),
        transId: 'CP-7c9e6679-7425-40de-944b-e07fc1f90ae7-SAS30117',
    },
    {
        rowId: 48214,
        runUuid: '7c9e6679-7425-40de-944b-e07fc1f90ae7',
        citizenid: 'FIB00190',
        name: 'Elena Sokolova',
        callsign: 'F-190',
        missionLabel: 'Armored Truck Escort',
        amount: 1170,
        createdAt: sqlTime(now() - 5 * 3600),
        transId: 'CP-7c9e6679-7425-40de-944b-e07fc1f90ae7-FIB00190',
    },
];
if (MOCK_MODE === 'edge') {
    STUCK[0].name = LONG_NAME.slice(0, 64);
    STUCK[0].callsign = null;
}
const awarded: Record<string, number> = {};

function adminRow(e: Entry, rank: number): AdminBoardRow {
    return {
        ...toRow(e, rank, ''),
        points: e.points + (awarded[e.o.citizenid] ?? 0),
        cash: e.cash,
        realName: e.o.name,
        hidden: hidden.has(e.o.citizenid),
        department: e.o.dept,
    };
}

function adminRuns(cid: string): AdminRun[] {
    return runsFor(cid, true)
        .slice(0, 12)
        .map(r => ({
            id: r.id,
            runUuid: `mock-${r.id}`,
            missionLabel: r.missionLabel,
            missionType: r.missionType,
            state: r.state,
            endReason: r.endReason,
            points: r.points,
            cash: r.cash,
            cashStatus: r.cashStatus,
            flagged: r.flagged,
            flagReason: r.flagged ? 'outside_help' : null,
            voided: r.voided || voided.has(r.id),
            departmentShort: DEPTS[byCid(cid)?.dept ?? 'sast'].short,
            participants: r.breakdown?.participants ?? 1,
            departments: r.breakdown?.departments ?? 1,
            tier: r.breakdown?.payTier ?? 'standard',
            createdAt: r.createdAt,
            createdTs: r.createdTs ?? now(),
        }));
}

reg(
    'request',
    'admin:getBoards',
    (args: { period?: string; filter?: string; department?: string; citizenid?: string } | null) => {
        const period = args?.period ?? 'weekly';
        const filter = period === 'alltime' ? 'overall' : (args?.filter ?? 'overall');
        const department = filter === 'department' ? (args?.department ?? 'fib') : undefined;
        const season = latestSeason();
        const list = period === 'season' && !season ? [] : entries(period, filter, department);
        const ranked = list
            .filter(e => e.runs >= 3)
            .sort((a, b) => b.points + (awarded[b.o.citizenid] ?? 0) - (a.points + (awarded[a.o.citizenid] ?? 0)));
        const data: AdminBoards = {
            period,
            filter,
            department,
            rows: ranked.map((e, i) => adminRow(e, i + 1)),
            unranked: list.filter(e => e.runs < 3).map(e => adminRow(e, 0)),
            stuck: STUCK,
            minRuns: 3,
            updatedAt: now() - 12,
            window:
                period === 'weekly'
                    ? { from: weekStart() }
                    : period === 'monthly'
                      ? { from: monthStart() }
                      : period === 'season' && season
                        ? { from: season.startsAt, to: season.endsAt }
                        : null,
            season: period === 'season' && season ? { id: season.id, name: season.name, active: season.active } : null,
        };
        if (args?.citizenid) {
            data.citizenid = args.citizenid;
            data.runs = adminRuns(args.citizenid);
        }
        return data;
    },
);

reg(
    'action',
    'server:admin:voidRun',
    (payload: { rowId?: number; reason?: string } | null) => {
        if (!payload?.rowId || !payload.reason?.trim()) throw new Error('err.invalid_payload');
        voided.add(payload.rowId);
        return true;
    },
    { fallback: true },
);

reg(
    'action',
    'server:admin:awardPoints',
    (payload: { citizenid?: string; points?: number; reason?: string } | null) => {
        if (!payload?.citizenid || !payload.points || !payload.reason?.trim()) throw new Error('err.invalid_payload');
        if (!byCid(payload.citizenid)) throw new Error('err.unknown_officer');
        awarded[payload.citizenid] = (awarded[payload.citizenid] ?? 0) + payload.points;
        return { rowId: 49000 + Object.keys(awarded).length };
    },
    { fallback: true },
);

// ============================================================================
//                        SUPERVISOR: department report
// ============================================================================

function reportOfficers(dept: string): ReportOfficer[] {
    const t0 = now();
    return POOL.filter(o => o.dept === dept)
        .slice(0, 14)
        .map((o, i) => {
            const runs = o.runs + (i % 3);
            const completed = Math.max(0, runs - o.failed - (i % 2));
            return {
                citizenid: o.citizenid,
                name: o.name,
                callsign: o.callsign,
                rank: o.rank,
                runs,
                completed,
                failed: o.failed,
                abandoned: runs - completed - o.failed,
                flagged: i === 3 ? 1 : 0,
                points: o.weekly,
                cash: Math.round(o.weekly * 5.6),
                lastRunAt: sqlTime(t0 - (i + 1) * 5400),
                lastRunTs: t0 - (i + 1) * 5400,
            };
        });
}

reg('request', 'sup:getDeptReport', () => {
    const me = viewer();
    const key = me.department === 'fib' ? 'fib' : 'sast';
    const season = currentSeason();
    const st = standings();
    const mine = st.find(d => d.key === key) ?? null;
    const report: DeptReport = {
        department: DEPTS[key],
        season: season
            ? {
                  id: season.id,
                  name: season.name,
                  weeksLeft: seasonView(season).weeksLeft,
                  week: seasonView(season).week,
              }
            : null,
        enabled: true,
        standing: season && mine ? { ...mine, of: st.length } : null,
        standings: st,
        bounty: bounty(),
        week: { key: sqlTime(weekStart()).slice(0, 10), startsAt: weekStart() },
        officers: reportOfficers(key),
    };
    return report;
});

reg('request', 'sup:getOfficerActivity', (args: { citizenid?: string } | null) => {
    const o = args?.citizenid ? byCid(args.citizenid) : undefined;
    if (!o) throw new Error('err.unknown_officer');
    const me = viewer();
    if (o.dept !== (me.department === 'fib' ? 'fib' : 'sast')) throw new Error('err.other_department');
    const runs: ActivityRun[] = runsFor(o.citizenid, true)
        .slice(0, Math.max(1, o.runs + 1))
        .map((r, i) => ({
            id: r.id,
            missionLabel: r.missionLabel,
            missionType: r.missionType,
            state: r.state,
            endReason: r.endReason,
            points: r.points,
            cash: r.cash,
            cashStatus: r.cashStatus,
            flagged: r.flagged,
            flagReason: r.flagged ? 'outside_help' : null,
            voided: r.voided,
            participants: r.breakdown?.participants ?? 1,
            departments: r.breakdown?.departments ?? 1,
            tier: r.breakdown?.payTier ?? 'standard',
            durationS: 240 + i * 37,
            createdAt: r.createdAt,
            createdTs: r.createdTs ?? now(),
        }));
    const activity: OfficerActivity = {
        officer: {
            citizenid: o.citizenid,
            name: o.name,
            callsign: o.callsign,
            rank: o.rank,
            departmentShort: DEPTS[o.dept].short,
        },
        week: { key: sqlTime(weekStart()).slice(0, 10), startsAt: weekStart() },
        runs,
    };
    return activity;
});
