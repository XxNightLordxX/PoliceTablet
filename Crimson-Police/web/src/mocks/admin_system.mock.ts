// Browser mocks for full admin control, System: storage, backups, webhooks, problems, integrations, departments added
// in game, desks and Support (the shapes of modules/sysadmin).

import { registerMock } from '../shared/nui';
import type {
    BackupView,
    BackupsData,
    CheckAccessResult,
    ClientStateView,
    DepartmentSetup,
    IntegrationsData,
    ProblemsData,
    RestorePreview,
    StorageView,
    WebhookView,
} from '../types/admin_system';

const now = () => Math.floor(Date.now() / 1000);

const backups: BackupView[] = [
    {
        name: '20261004-180000-daily',
        kind: 'daily',
        createdAt: now() - 86400,
        by: 'console',
        rows: 4210,
        bytes: 912000,
        files: 3,
    },
    {
        name: '20261005-090000-manual',
        kind: 'manual',
        createdAt: now() - 3600,
        by: 'ABC12345',
        rows: 4380,
        bytes: 948000,
        files: 3,
        protected: true,
    },
];

registerMock('request', 'admin:getStorage', (): StorageView => ({
    mode: 'files',
    folder: 'saves',
    tables: [
        { name: 'cp_audit', rows: 812 },
        { name: 'cp_mission_runs', rows: 3120 },
        { name: 'cp_officers', rows: 46 },
        { name: 'cp_settings', rows: 12 },
    ],
    totalRows: 3990,
    bytes: 1830000,
    files: 21,
    version: '1.0.0',
    migrations: {
        version: 8,
        pending: 0,
        files: Array.from({ length: 8 }, (_, i) => ({ version: i + 1, name: `00${i + 1}.sql`, applied: true })),
    },
    override: null,
    state: 'active',
    runsGoing: 0,
    backups: backups.length,
}));

registerMock('action', 'server:admin:storageCopy', () => ({ message: 'admin.cmd.storage_copied', restart: false }));
registerMock('action', 'server:admin:setStorageMode', () => ({ mode: 'database', restart: true }));
registerMock('action', 'server:admin:useStoreAgain', () => ({ state: 'active' }));

registerMock('request', 'admin:getBackups', (): BackupsData => ({
    backups: [...backups].reverse(),
    keep: 7,
    daily: false,
    folder: 'saves/_backups',
}));

registerMock('action', 'server:admin:backupNow', () => {
    const b: BackupView = {
        name: `mock-${now()}-manual`,
        kind: 'manual',
        createdAt: now(),
        by: 'ABC12345',
        rows: 4400,
        bytes: 950000,
        files: 3,
    };
    for (const x of backups) x.protected = false;
    b.protected = true;
    backups.push(b);
    return b;
});

registerMock('request', 'admin:previewRestore', (a: { name?: string }): RestorePreview => ({
    backup: { name: a?.name ?? '', kind: 'manual', createdAt: now() - 3600, by: 'ABC12345', rows: 4380 },
    replaced: [
        { name: 'cp_mission_runs', now: 3120, backup: 3080 },
        { name: 'cp_officers', now: 46, backup: 45 },
    ],
    kept: ['cp_audit', 'cp_settings_history', 'cp_dept_funding'],
    keptSettings: ['AdminControl.', 'Cash.allow', 'Retention.auditDays'],
    files: ['missions/custom/my_mission.lua'],
    moneyRuns: 211,
    moneyItems: 4,
    runsGoing: 0,
    previewToken: 'mock-restore',
    expiresAt: now() + 120,
}));

registerMock('action', 'server:admin:restoreBackup', () => ({ restart: true }));
registerMock('action', 'server:admin:deleteBackup', (p: { name?: string }) => {
    const i = backups.findIndex(b => b.name === p?.name);
    if (i >= 0) backups.splice(i, 1);
    return { name: p?.name };
});

registerMock('request', 'admin:getWebhooks', (): { webhooks: WebhookView[] } => ({
    webhooks: (['audit', 'flags', 'board', 'builder', 'operations'] as const).map((c, i) => ({
        category: c,
        convar: `cp_webhook_${c}`,
        state: i < 2 ? 'on' : 'off',
        discord: i < 2,
        line: `set cp_webhook_${c} "https://discord.com/api/webhooks/<id>/<token>"`,
    })),
}));

registerMock('request', 'admin:getProblems', (): ProblemsData => ({
    lines: [
        {
            at: now() - 120,
            level: 'warn',
            tag: 'confighealth',
            text: 'items: the tablet item police_tablet is not an ox_inventory item',
        },
        { at: now() - 900, level: 'error', tag: 'admin', text: 'webhook audit failed: <webhook link> answered 404' },
    ],
    total: 2,
    tags: ['admin', 'confighealth'],
}));

registerMock('request', 'admin:getIntegrations', (): IntegrationsData => ({
    resources: [
        { name: 'qbx_core', state: 'started', version: '1.20.0', required: true },
        { name: 'ox_inventory', state: 'started', version: '2.41.0', required: true },
        { name: 'sc-dispatch', state: 'started', version: '3.2.1', required: true },
        { name: 'sc-police', state: 'started', required: false },
        { name: 'Crimson-Arena', state: 'missing', required: false },
    ],
    checklist: ['sysadmin.checklist.dispatch_jobs', 'sysadmin.checklist.police_jobs', 'sysadmin.checklist.arena'],
    arena: {
        state: 'missing',
        players: 0,
        zones: [{ label: 'Crimson-Arena (Maze Bank Arena)', coords: { x: -324, y: -1968, z: 66 }, radius: 220 }],
    },
}));

const setup: DepartmentSetup = {
    departments: [
        {
            key: 'sast',
            added: false,
            enabled: true,
            label: 'San Andreas State Troopers',
            short: 'SAST',
            jobs: ['sast'],
            supervisorGrade: 3,
            societyAccount: 'sast',
            theme: { primary: '#1f4e8c', accent: '#f2c230', background: '#0d1522', surface: '#152235' },
        },
        {
            key: 'fib',
            added: false,
            enabled: true,
            label: 'Federal Investigation Bureau',
            short: 'FIB',
            jobs: ['fib'],
            supervisorGrade: 3,
            societyAccount: 'fib',
            theme: { primary: '#1c2541', accent: '#c9a227', background: '#0b0c10', surface: '#1a1b24' },
        },
    ],
    jobs: [
        {
            name: 'sast',
            label: 'SAST',
            grades: [
                { level: 0, name: 'Trooper' },
                { level: 3, name: 'Sergeant' },
            ],
            usedBy: 'sast',
        },
        {
            name: 'fib',
            label: 'FIB',
            grades: [
                { level: 0, name: 'Agent' },
                { level: 3, name: 'Lead' },
            ],
            usedBy: 'fib',
        },
        {
            name: 'bcso',
            label: 'BCSO',
            grades: [
                { level: 0, name: 'Deputy' },
                { level: 3, name: 'Sergeant' },
            ],
        },
    ],
    cashSource: 'server',
    runsGoing: 0,
};

registerMock('request', 'admin:getDepartmentSetup', (): DepartmentSetup => setup);
registerMock(
    'action',
    'server:admin:addDepartment',
    (p: { key?: string; label?: string; short?: string; jobs?: string[] }) => {
        setup.departments.push({
            key: p.key ?? 'x',
            added: true,
            enabled: true,
            label: p.label ?? '',
            short: p.short ?? '',
            jobs: p.jobs ?? [],
            supervisorGrade: 3,
        });
        return { key: p.key };
    },
);
registerMock('action', 'server:admin:saveDepartment', () => ({}));
registerMock('action', 'server:admin:setDepartmentEnabled', (p: { key?: string; enabled?: boolean }) => {
    const d = setup.departments.find(x => x.key === p.key);
    if (d) d.enabled = !!p.enabled;
    return { key: p.key, enabled: p.enabled };
});
registerMock('action', 'server:admin:deleteDepartment', (p: { key?: string }) => {
    setup.departments = setup.departments.filter(x => x.key !== p.key);
    return { key: p.key };
});
registerMock('action', 'server:admin:uploadLogo', (p: { index?: number; total?: number; department?: string }) =>
    p.index === p.total ? { file: `${p.department}.png`, restart: true } : { received: p.index, total: p.total },
);

registerMock('action', 'server:admin:addDeskHere', () => ({ index: 3 }));
registerMock('action', 'server:admin:updateDesk', (p: { index?: number }) => ({ index: p.index }));
registerMock('action', 'server:admin:removeDesk', (p: { index?: number }) => ({ index: p.index }));
registerMock('action', 'server:admin:teleportToDesk', () => ({}));
registerMock('request', 'admin:myPosition', () => ({ x: 441.2, y: -978.9, z: 30.69, heading: 90 }));
registerMock('action', 'server:admin:teleportTo', () => ({}));

registerMock('request', 'admin:checkAccess', (): CheckAccessResult => ({
    ok: false,
    error: 'err.not_on_duty',
    fix: 'sysadmin.fix.not_on_duty',
    via: 'command',
    steps: [
        { check: 'job', ok: true, vars: { job: 'sast' } },
        { check: 'department_on', ok: true, vars: { department: 'sast' } },
        { check: 'duty', ok: false },
        { check: 'suspended', ok: true },
    ],
}));
registerMock('request', 'admin:getClientState', (): ClientStateView => ({
    screen: 'faded in',
    nuiFocus: true,
    tabletOpen: false,
    scriptCam: false,
    playerControl: true,
    frozen: false,
}));
registerMock('action', 'server:admin:giveTabletItem', () => ({ item: 'police_tablet' }));
registerMock('action', 'server:admin:releaseScreen', () => ({}));

registerMock('request', 'admin:exportAuditPart', (a: { part?: number }) => ({
    csv: 'id,time,actor,actor_name,role,category,action,target,old_value,new_value,reason\n1,2026-10-05 09:00:00,ABC12345,John,admin,audit,settingChanged,Tablet.deskDistance,3,4.5,',
    rows: 1,
    part: a?.part ?? 1,
    parts: 2,
    total: 6200,
}));
registerMock('action', 'server:admin:saveAuditExport', () => ({
    path: 'saves/exports/audit-20261005-090000.csv',
    rows: 6200,
    truncated: false,
}));
