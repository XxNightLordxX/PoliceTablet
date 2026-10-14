// Browser mocks for full admin control: Missions and the Mission Builder (edited built-ins, Quick edit, versions,
// Copy as Lua and Import, the load result, history, stats, the Deleted list, test results).

import { registerMock } from '../shared/nui';
import type {
    BuiltinDiff,
    DeletedMission,
    DispatchHistoryRow,
    ImportPreview,
    MissionLoadSummary,
    MissionStatsData,
    MissionTweakView,
    OperationHistoryRow,
    Paged,
    SwitchRemapData,
    TestHistory,
    VersionDiff,
} from '../types/admin_missions';

const now = () => Math.floor(Date.now() / 1000);
const DAY = 86400;

const tweaks: Record<string, { cooldown?: number; timeLimit?: number; startTimeout?: number }> = {};
let deleted: DeletedMission[] = [
    {
        id: 'custom_old_checkpoint',
        folder: 'missions/custom/deleted/custom_old_checkpoint-20261001120000/',
        label: 'Old Checkpoint',
        type: 'traffic',
        version: 3,
        deletedAt: now() - 3 * DAY,
        deletedBy: 'ADM00001',
        reason: 'replaced by a new route',
    },
];
const hidden = new Set<number>();

registerMock('request', 'admin:getMissionLoad', (): MissionLoadSummary => ({
    loaded: 21,
    builtin: 19,
    custom: 2,
    overridden: 1,
    warnings: 1,
    warningTexts: [{ id: 'custom_night_beat', text: 'location 3: the start is close to another location' }],
    failed: [],
    overrideFailed: [],
    builder: { checked: 3, edited: [], rejected: [], conflicts: [], rewritten: [] },
    at: now() - 3600,
}));

registerMock('request', 'admin:getMissionTweak', (p: { missionId: string }): MissionTweakView => ({
    missionId: p.missionId,
    label: 'Gang Shootout',
    overridden: false,
    file: { cooldown: 1200, timeLimit: 600, startTimeout: 600 },
    live: { cooldown: 1200, timeLimit: 600, startTimeout: 600, ...tweaks[p.missionId] },
    tweak: tweaks[p.missionId] ?? null,
    tweaked: !!tweaks[p.missionId],
    objectives: [
        {
            index: 1,
            block: 'hostile_waves',
            label: 'Neutralise all hostiles',
            weapons: ['WEAPON_PISTOL', 'WEAPON_MICROSMG'],
        },
        { index: 2, block: 'interact_points', label: 'Secure the scene' },
    ],
    allowed: {
        peds: ['g_m_y_lost_01', 'g_m_y_mexgoon_01'],
        vehicles: ['police3', 'sultan'],
        weapons: ['WEAPON_PISTOL', 'WEAPON_MICROSMG', 'WEAPON_SMG', 'WEAPON_PUMPSHOTGUN'],
    },
    ranges: { cooldown: [0, 86400], timeLimit: [60, 3600], startTimeout: [60, 3600] },
}));

registerMock('action', 'server:admin:setMissionTweak', (p: { missionId: string; tweak?: Record<string, number> }) => {
    if (p.tweak) tweaks[p.missionId] = p.tweak;
    else delete tweaks[p.missionId];
    return { missionId: p.missionId, tweak: p.tweak ?? null };
});

registerMock('request', 'admin:builtinDiff', (p: { id: string }): BuiltinDiff => ({
    id: p.id,
    changed: true,
    shippedHash: 'b2c3d4e5',
    baseHash: 'a1b2c3d4',
    original: [{ path: 'cooldown', from: '1500', to: '1200' }],
    originalMore: false,
    yours: [
        { path: 'label', from: 'Gang Shootout', to: 'Gang Shootout (edited)' },
        { path: 'objectives.1.waves.3', from: '6', to: '5' },
    ],
    yoursMore: false,
    summary: {
        label: { from: 'Gang Shootout', to: 'Gang Shootout (edited)' },
        locationsAdded: [],
        locationsRemoved: [],
        objectivesFrom: [],
        objectivesTo: [],
    },
}));

registerMock('request', 'builder:versionDiff', (p: { id: string; version: number }): VersionDiff => ({
    id: p.id,
    version: p.version,
    current: p.version + 1,
    summary: { locationsAdded: [], locationsRemoved: ['Mirror Park'], objectivesFrom: [], objectivesTo: [] },
    lines: [{ path: 'timeLimit', from: '900', to: '600' }],
    more: false,
}));

for (const name of [
    'server:builder:editBuiltin',
    'server:builder:keepOverride',
    'server:builder:resetBuiltin',
    'server:builder:foldTweaks',
    'server:builder:changeOwner',
    'server:builder:deleteMission',
    'server:builder:loadBackupDraft',
    'server:admin:remapLocationSwitches',
    'server:admin:markLocationChecked',
])
    registerMock('action', name, (p: { id?: string }) => ({ id: p?.id ?? null }), { fallback: true });

registerMock('action', 'server:builder:undeleteMission', (p: { folder: string }) => {
    deleted = deleted.filter(d => d.folder !== p.folder);
    return { ok: true };
});

registerMock('request', 'builder:deleted', () => ({ missions: deleted }));

registerMock('request', 'admin:getSwitchRemap', (): SwitchRemapData => ({ missions: [] }));

registerMock('request', 'admin:exportMissionLua', (p: { id: string }) => ({
    id: p.id,
    version: 2,
    lua: `--[[ Crimson-Police · custom mission (written by the Mission Builder) ]]\n\nRegisterMission({\n  id = '${p.id}',\n  label = 'Night Beat',\n  type = 'patrol',\n})\n`,
}));

registerMock('request', 'admin:previewImport', (p: { lua: string }): ImportPreview => {
    if (!p.lua.includes('RegisterMission')) throw new Error('err.import_parse');
    return {
        previewToken: 'mock-token',
        expiresAt: now() + 120,
        effect: {
            label: 'Night Beat',
            type: 'patrol',
            sourceId: 'custom_night_beat',
            objectives: [{ block: 'checkpoint_route', label: 'Patrol the beat' }],
            locations: ['Vespucci Canals', 'Mirror Park'],
            dropped: p.lua.includes('payout') ? ['payout'] : [],
            errors: [],
            errorCount: 0,
        },
    };
});

registerMock('action', 'server:builder:importDraft', () => ({ id: 'custom_night_beat_2' }));

registerMock('request', 'admin:getOperations', (): Paged<OperationHistoryRow> => ({
    rows: [
        {
            id: 12,
            missionId: 'prison_break',
            missionLabel: 'Prison Break',
            launchedBy: 'SUP00001',
            launchedByName: 'John Doe',
            status: 'completed',
            createdAt: now() - 2 * DAY,
            endedAt: now() - 2 * DAY + 1500,
            participants: [
                {
                    citizenid: 'OFF00001',
                    name: 'Otto Officer',
                    department: 'sast',
                    state: 'completed',
                    points: 120,
                    voided: false,
                },
                {
                    citizenid: 'OFF00002',
                    name: 'Fay Agent',
                    department: 'fib',
                    state: 'completed',
                    points: 120,
                    voided: false,
                },
            ],
            points: 240,
        },
    ],
    page: 1,
    pages: 1,
    total: 1,
}));

registerMock('request', 'admin:getMissionCalls', (p: { page?: number }): Paged<DispatchHistoryRow> => {
    const rows: DispatchHistoryRow[] = Array.from({ length: 6 }, (_, i) => ({
        id: 100 - i,
        code: `MC-${String(40 + i).padStart(4, '0')}`,
        type: i % 2 ? 'traffic' : 'patrol',
        typeLabel: i % 2 ? 'Traffic' : 'Patrol',
        priority: 3,
        status: 'closed',
        outcome: i === 2 ? 'failed' : 'completed',
        issuer: i === 1 ? 'SUP00001' : undefined,
        issuerName: i === 1 ? 'John Doe' : undefined,
        claimedBy: 'OFF00001',
        claimedName: 'Otto Officer',
        claimants: 1,
        reopened: false,
        createdAt: now() - (i + 1) * 3600,
        claimedAt: now() - (i + 1) * 3600 + 45,
        claimSeconds: 45,
    }));
    return { rows, page: p?.page ?? 1, pages: 1, total: rows.length };
});

registerMock('request', 'admin:getMissionStats', (): MissionStatsData => {
    const row = (key: string, label: string, runs: number, completed: number) => ({
        key,
        label,
        runs,
        completed,
        failed: runs - completed,
        abandoned: 0,
        points: completed * 90,
        cash: completed * 400,
        flags: 1,
        voids: 0,
        completionRate: Math.round((completed * 1000) / runs) / 10,
        failRate: Math.round(((runs - completed) * 1000) / runs) / 10,
        abandonRate: 0,
        avgDuration: 420,
        avgPoints: Math.round((completed * 900) / runs) / 10,
        avgCash: Math.round((completed * 400) / runs),
        timeLimit: 600,
        durationShare: 70,
    });
    return {
        from: now() - 30 * DAY,
        to: now(),
        missions: [row('gang_shootout', 'Gang Shootout', 40, 31), row('beat_patrol', 'Beat Patrol', 120, 117)],
        types: [row('tactical', 'Tactical', 40, 31), row('patrol', 'Patrol', 120, 117)],
    };
});

registerMock('request', 'admin:getTestHistory', (p: { missionId: string; locationIndex: number }): TestHistory => ({
    missionId: p.missionId,
    location: p.locationIndex,
    results: [
        {
            id: 7,
            version: false,
            tier: 'standard',
            testers: 1,
            result: 'passed',
            note: 'walked it, fine',
            testedBy: 'ADM00001',
            testedByName: 'Ada Admin',
            testedAt: now() - DAY,
            hidden: hidden.has(7),
            unplayed: true,
        },
    ],
}));

registerMock('action', 'server:admin:hideTestResult', (p: { id: number; hidden: boolean }) => {
    if (p.hidden) hidden.add(p.id);
    else hidden.delete(p.id);
    return { id: p.id, hidden: p.hidden };
});
