// Browser mocks for full admin control: Officers, Leaderboards and Seasons (modules/corrections, the officers tools
// of modules/profile, scoring and goals, the recognition and season tools of modules/leaderboard and challenge).

import { registerMock } from '../shared/nui';
import type {
    BadgeCatalog,
    BannedWords,
    CorrectionBatch,
    OfficerGoals,
    OfficerLook,
    OfficerPoints,
    OfficerRunRow,
    OfficerRunsPage,
    RecognitionData,
    RunDetail,
    VoidPreview,
    WeekRecognition,
    XpCheck,
} from '../types/admin_officers';

const DAY = 86400;
const now = () => Math.floor(Date.now() / 1000);
const uuid = (n: number) => `${String(n).padStart(8, '0')}-1111-4000-8000-000000000001`;

function mockRun(i: number, cid: string): OfficerRunRow {
    const voided = i % 7 === 3;
    return {
        id: 4000 + i,
        runUuid: uuid(i),
        archived: i > 18,
        missionId: i % 2 ? 'beat_patrol' : 'traffic_stop',
        missionLabel: i % 2 ? 'Beat Patrol' : 'Traffic Stop',
        missionType: 'patrol',
        missionTypeLabel: 'Patrol',
        location: 'Mission Row',
        state: i % 5 === 4 ? 'failed' : 'completed',
        endReason: 'completed',
        tier: 'standard',
        participants: i % 3 === 0 ? 2 : 1,
        departments: 1,
        department: 'sast',
        operationId: null,
        points: 60 + (i % 4) * 15,
        cashPaid: i % 6 === 0 ? 0 : 250,
        cash: 250,
        cashStatus: i % 6 === 0 ? 'held' : 'paid',
        flagged: i % 9 === 5,
        flagReason: i % 9 === 5 ? 'too_fast' : null,
        voided,
        voidKind: voided ? (i % 2 ? 'correction' : 'strike') : null,
        voidBatch: null,
        durationS: 640,
        createdAt: now() - i * 7200,
        txnId: i % 6 === 0 ? null : `CP-${uuid(i)}-${cid}`,
        awardBy: null,
        awardReason: null,
    };
}

registerMock('request', 'admin:getOfficerRuns', (a: { citizenid?: string; page?: number }): OfficerRunsPage => {
    const cid = a.citizenid ?? 'ABC12345';
    const page = Math.max(1, a.page ?? 1);
    const all = Array.from({ length: 42 }, (_, i) => mockRun(i, cid));
    return { runs: all.slice((page - 1) * 25, page * 25), total: all.length, page, pages: 2, size: 25 };
});

registerMock('request', 'admin:getRun', (a: { rowId?: number }): RunDetail => {
    const r = mockRun((a.rowId ?? 4001) - 4000, 'ABC12345');
    return {
        ...r,
        citizenid: 'ABC12345',
        breakdown: null,
        participantsList: [
            {
                rowId: r.id,
                archived: r.archived,
                citizenid: 'ABC12345',
                name: 'Ada Lane',
                callsign: '1-A-12',
                department: 'sast',
                state: r.state,
                points: r.points,
                voided: r.voided,
                flagged: r.flagged,
            },
        ],
        dispute: null,
        goalRewards: r.voided ? [] : [{ rowId: 9001, goalId: 'daily_points', label: 'Daily points', points: 25 }],
        own: false,
    };
});

registerMock('request', 'admin:getOfficerPoints', (a: { citizenid?: string }): OfficerPoints => ({
    citizenid: a.citizenid ?? 'ABC12345',
    windows: {
        weekly: { points: 420, rank: 3, ranked: 18 },
        monthly: { points: 1630, rank: 4, ranked: 26 },
        season: { points: 3110, rank: 6, ranked: 31 },
        alltime: { points: 8420, rank: 9, ranked: 40 },
    },
    seasonPoints: 3110,
    season: { id: 3, name: 'Autumn Season' },
    xp: 8420,
    level: { label: 'Trooper', badge: 'silver', xp: 8420, next: 10000 },
    adjust: { enabled: true, max: 10000, maxDeduction: 3110, confirmAbove: 500, dailyLimit: 0 },
}));

registerMock('request', 'admin:checkXp', (a: { citizenid?: string }): XpCheck => ({
    citizenid: a.citizenid ?? 'ABC12345',
    stored: 8420,
    derived: 8380,
    rows: 131,
    diff: -40,
}));

registerMock('request', 'admin:getOfficerGoals', (): OfficerGoals => ({
    daily: { id: 'daily_points', label: 'Earn 50 points', count: 50, progress: 35, done: false, points: 25 },
    weekly: { id: 'weekly_arrests', label: 'Make 5 arrests', count: 5, progress: 5, done: true, points: 100 },
}));

registerMock('request', 'admin:getOfficerLook', (): OfficerLook => ({
    appearance: 'dark',
    accent: '#3fa7ff',
    uiScale: 1.1,
    effective: {},
    hideName: false,
    callsMuted: false,
    nextEditIn: 0,
    urlsLeft: 3,
}));

registerMock('request', 'admin:getBadgeCatalog', (): BadgeCatalog => ({
    achievements: [
        { id: 'iron_wheels', label: 'Iron Wheels', need: 20 },
        { id: 'road_warrior', label: 'Road Warrior', need: 100 },
        { id: 'by_the_book', label: 'By the Book', need: 100 },
    ],
    recognition: ['officer_of_week', 'top_metric', 'season_champion', 'season_top10'],
}));

const preview = (total: number): VoidPreview => ({
    total,
    points: total * 70,
    held: 250,
    archived: 1,
    officers: [{ citizenid: 'ABC12345', name: 'Ada Lane', rows: total, points: total * 70, held: 250 }],
    rows: Array.from({ length: Math.min(total, 8) }, (_, i) => ({
        key: `L${4000 + i}`,
        id: 4000 + i,
        citizenid: 'ABC12345',
        missionLabel: 'Beat Patrol',
        missionType: 'patrol',
        state: 'completed',
        points: 70,
        cashStatus: 'paid',
        archived: i === 7,
        createdAt: now() - i * 7200,
    })),
    excluded: 1,
    max: 5000,
    tooMany: false,
    confirmWord: `VOID ${total}`,
    previewToken: 'mock-token',
    busy: null,
    online: false,
});
registerMock('request', 'admin:previewBulkVoid', () => preview(12));
registerMock('request', 'admin:previewRetire', () => ({ ...preview(131), confirmWord: 'ABC12345' }));

const batches: CorrectionBatch[] = [
    {
        id: '11111111-0000-4000-8000-000000000001',
        kind: 'bulkVoid',
        state: 'done',
        filter: { citizenid: 'ABC12345', from: now() - 7 * DAY },
        done: 12,
        total: 12,
        actor: 'ADM00001',
        reason: 'Bugged mission week',
        createdAt: now() - 2 * DAY,
        restored: false,
        undone: false,
        undo: 'restoreBatch',
    },
];
registerMock('request', 'admin:getCorrections', () => ({ batches }));

registerMock('request', 'admin:getBannedWords', (): BannedWords => ({
    file: 'config/banned_words.txt',
    words: ['badword', 'other phrase'],
    settingsWords: [],
    max: 5000,
}));
registerMock('request', 'admin:testBannedWords', (a: { text?: string }) => {
    const hit = (a.text ?? '').toLowerCase().includes('badword');
    return { banned: hit, matches: hit ? ['badword'] : [] };
});

const week = (n: number): WeekRecognition => {
    const from = now() - (n + 1) * 7 * DAY;
    const d = new Date(from * 1000).toISOString().slice(0, 10);
    return {
        weekKey: d,
        from,
        to: from + 7 * DAY,
        badgeId: `officer_of_week_${d}`,
        top: [{ citizenid: 'ABC12345', name: 'Ada Lane', callsign: '1-A-12', departmentShort: 'SAST', points: 940 }],
        holders: [{ citizenid: 'ABC12345', name: 'Ada Lane', callsign: '1-A-12', earnedAt: from + 7 * DAY }],
        changed: n === 1,
        previewToken: 'mock-token',
    };
};
registerMock('request', 'admin:getRecognition', (): RecognitionData => ({
    home: [
        { kind: 'staff_notice', text: 'Training night Friday 8 pm at Mission Row.' },
        { kind: 'weekly_top3', text: 'Top 3 last week: Ada Lane · Ben Ortiz · Cleo Park' },
    ],
    notices: [
        {
            id: 1,
            text: 'Training night Friday 8 pm at Mission Row.',
            departments: null,
            expiresAt: now() + 3 * DAY,
            createdAt: now() - DAY,
            by: 'ADM00001',
        },
    ],
    weeks: [0, 1, 2, 3].map(week),
    announceWeekly: true,
    announceMonthly: true,
}));
registerMock('request', 'admin:previewRecount', () => week(1));

for (const name of [
    'server:admin:adjustPoints',
    'server:admin:bulkVoid',
    'server:admin:resetProgression',
    'server:admin:restoreBatch',
    'server:admin:retireOfficer',
    'server:admin:unretireOfficer',
    'server:admin:moveRecord',
    'server:admin:undoRecordMove',
    'server:admin:reopenSeason',
    'server:admin:undoReopen',
    'server:admin:recheckAllBadges',
]) {
    registerMock('action', name, () => ({ jobId: '22222222-0000-4000-8000-000000000001', rows: 12 }));
}
for (const name of [
    'server:admin:fixXp',
    'server:admin:restoreRun',
    'server:admin:setVoidKind',
    'server:admin:flagRow',
    'server:admin:grantBadge',
    'server:admin:revokeBadge',
    'server:admin:clearBadgeOverride',
    'server:admin:recheckBadges',
    'server:admin:recalcStreak',
    'server:admin:forgiveStreakDays',
    'server:admin:resetFirstRun',
    'server:admin:completeGoal',
    'server:admin:setBoardExcluded',
    'server:admin:refreshOfficer',
    'server:admin:postNotice',
    'server:admin:removeNotice',
    'server:admin:resetLook',
    'server:admin:clearProfileCooldown',
    'server:admin:setBannedWords',
    'server:admin:recountWeek',
    'server:admin:repostWeek',
    'server:admin:approveRun',
    'server:admin:renameSeason',
    'server:admin:scheduleSeasonEnd',
    'server:admin:cancelSeasonEnd',
    'server:admin:setNextBounty',
    'server:admin:recountBountyWeek',
    'server:admin:recountChampion',
]) {
    registerMock('action', name, () => ({}));
}
