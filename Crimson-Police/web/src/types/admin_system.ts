// Full admin control, System (modules/admin/sysadmin): storage, backups, webhooks, problems, integrations, departments added
// in game, Support (docs/dev/ARCHITECTURE.md §9.5, "Admin control: system").

import type { OfficerOptionValue } from '../shared/types';
import type { MaintenanceView } from './admin_control';

// ============================================================================
//                                   STORAGE
// ============================================================================

export interface StorageTable {
    name: string;
    rows: number;
}

export interface MigrationFile {
    version: number;
    name: string;
    applied: boolean;
    appliedAt?: number;
}

// admin:getStorage: Admin.storageStatus() plus the in-game switch, the marker and the lock.
export interface StorageView {
    mode: 'database' | 'files';
    // the setting's relative folder name, never the server's full path
    folder: string;
    tables: StorageTable[];
    totalRows: number;
    bytes?: number;
    files?: number;
    version?: string | null;
    migrations?: { version: number; files: MigrationFile[]; pending: number; readable?: boolean } | null;
    loadError?: string | null;
    error?: string;
    // the storage switched to in game (server KVP), while it is used instead of config.lua's
    override?: { mode: 'database' | 'files'; folder?: string } | null;
    generation?: string | null;
    state?: 'active' | 'left_behind' | null;
    maintenance?: MaintenanceView | null;
    runsGoing: number;
    busy?: string | null;
    backups: number;
}

export interface StorageCopyReply {
    message?: string;
    vars?: Record<string, unknown>;
    money?: { updated: number; inserted: number } | null;
    restart?: boolean;
    // the fresh Storage view, so the panel needs no second request
    view?: StorageView;
}

// ============================================================================
//                                   BACKUPS
// ============================================================================

export interface BackupView {
    name: string;
    kind: 'manual' | 'daily' | 'prerestore';
    createdAt: number;
    by: string;
    rows: number;
    bytes: number;
    files: number;
    // the newest and the latest automatic one before a restore: never deleted or pruned
    protected?: boolean;
}

export interface BackupsData {
    backups: BackupView[];
    keep: number;
    daily: boolean;
    folder: string;
}

export interface RestorePreview {
    backup: { name: string; kind: string; createdAt: number; by: string; version?: string; rows: number };
    replaced: { name: string; now: number; backup: number }[];
    kept: string[];
    keptSettings: string[];
    files: string[];
    moneyRuns: number;
    moneyItems: number;
    runsGoing: number;
    previewToken: string;
    expiresAt: number;
}

// ============================================================================
//                       WEBHOOKS, PROBLEMS, INTEGRATIONS
// ============================================================================

// Read only: the link itself never reaches the NUI.
export interface WebhookView {
    category: 'audit' | 'flags' | 'board' | 'builder' | 'operations';
    convar: string;
    state: 'on' | 'off' | 'invalid';
    // the link is a Discord webhook link (anchored host check)
    discord: boolean;
    // the server.cfg line to paste (with placeholders)
    line: string;
}

export interface ProblemLine {
    at: number;
    level: 'warn' | 'error';
    tag: string;
    // secrets are cut out before a line is kept
    text: string;
}

export interface ProblemsData {
    lines: ProblemLine[];
    total: number;
    tags: string[];
}

// Config.AdminUi.homeShortcuts: Home's shortcut keys (modules/admin/adminhome AH.SHORTCUTS)
export type HomeShortcutKey =
    'newMission' | 'missionSwitch' | 'pay' | 'points' | 'settings' | 'live' | 'review' | 'activity';

// admin:getHome: Admin UI -> Home, the whole dashboard in one answer.
export interface AdminHomeData {
    live: {
        onDuty: number;
        departments: { key: string; label: string; n: number }[];
        // null / missing: the admin has no liveRuns key (Home shows no runs)
        runs?: { n: number; rows: { runId: string; missionLabel: string; people: number; test: boolean }[] } | null;
    };
    queues: {
        flagged: number;
        profiles: number;
        disputes: number;
        payments: number;
        // null / missing: the admin has no Player suspects screen (no key, or live crimes and volunteers off)
        rsCases?: number | null;
    };
    alerts: {
        problems: number;
        refusedToday: number;
        // null / missing: the checks could not run
        health?: { warn: number; error: number } | null;
        // null / missing: the missions have not loaded yet
        load?: { loaded: number; refused: number; error: boolean } | null;
    };
    shortcuts: HomeShortcutKey[];
    // Config.AdminUi.homeShortcutsByUse: true = the admin's most used shortcuts first (counted on his tablet)
    shortcutsByUse?: boolean;
    // true while the First-start setup shows on Home (Config.AdminUi.setupScreen on, setupDone not yet)
    setup?: boolean;
    serverTime?: number;
}

// admin:getSetup (modules/admin/setup): what the First-start setup shows.
export interface SetupJobGrade {
    level: number;
    name: string;
    boss: boolean;
}
export interface SetupJob {
    name: string;
    label: string;
    police: boolean;
    grades: SetupJobGrade[];
    // the department that lists this job already
    department?: string | null;
}
export interface SetupDepartment {
    key: string;
    label: string;
    short: string;
    jobs: string[];
    supervisorGrade: number;
    enabled: boolean;
    added: boolean;
}
export interface SetupIntegration {
    kind: string;
    setting: string;
    active?: string | null;
    why?: string | null;
    options: string[];
}
export interface SetupView {
    pending: boolean;
    departments: SetupDepartment[];
    jobs: SetupJob[];
    desks: { index: number; label: string; coords?: { x: number; y: number; z: number } | null }[];
    storage: { database: boolean; folder: string; oxmysql: boolean; copyCommand: string };
    integrations: SetupIntegration[];
    presets: { key: string; name: string; help: string; count: number }[];
}
// server:admin:finishSetup's answer
export interface SetupReply {
    changed: number;
    preset?: { key: string; changed: number };
    presetError?: string;
}

export interface ResourceView {
    name: string;
    state: string;
    version?: string | null;
    required: boolean;
    // the jobs (dispatch, ambulance, banking, police) this script serves now
    serves?: string[] | null;
}
// Which script serves one job now (Config.Integrations), or why none does
export interface IntegrationJob {
    kind: string;
    setting: string;
    active?: string | null;
    off?: string | null;
}

export interface IntegrationsData {
    resources: ResourceView[];
    jobs: IntegrationJob[];
    // locale keys of the owner guide 4 checklist (settings in the other resources)
    checklist: string[];
    arena: {
        state: string;
        players: number;
        zones: { label: string; coords: { x: number; y: number; z: number }; radius: number }[];
    };
}

// ============================================================================
//                                 DEPARTMENTS
// ============================================================================

export interface DeptTheme {
    primary?: string;
    accent?: string;
    background?: string;
    surface?: string;
    text?: string;
}

export interface DeptLogoSetting {
    file?: string;
    url?: string;
    watermark?: boolean;
    opacity?: number;
    size?: number;
    grayscale?: boolean;
}

// admin:getDepartmentSetup: each department as set now (added = added in game, one record setting).
export interface DepartmentSetting {
    key: string;
    added: boolean;
    enabled: boolean;
    label: string;
    short: string;
    jobs: string[];
    supervisorGrade: number;
    societyAccount?: string;
    theme?: DeptTheme;
    logo?: DeptLogoSetting;
    // Config.Departments.<key>.officerOptions: the department's own allow, defaults and bounds (over the global ones)
    officerOptions?: DeptOfficerOptions;
}

export interface DeptOfficerOptions {
    allow?: Record<string, boolean>;
    defaults?: Record<string, OfficerOptionValue>;
    bounds?: Record<string, unknown>;
}

// An officer option the department form offers, with the server-wide allow, default and bounds.
export interface OptionDefAdmin {
    key: string;
    kind: 'bool' | 'enum' | 'list' | 'number';
    group: string;
    values?: (string | number)[];
    integer?: boolean;
    allow: boolean;
    default: OfficerOptionValue;
    bounds?: { min?: number; max?: number };
}

export interface QboxJobView {
    name: string;
    label?: string;
    grades: { level: number; name?: string }[];
    // the department that lists it now
    usedBy?: string;
}

export interface DepartmentSetup {
    departments: DepartmentSetting[];
    jobs: QboxJobView[];
    cashSource: 'server' | 'society';
    runsGoing: number;
    optionDefs?: OptionDefAdmin[];
    // Config.OfficerOptions.enabled
    optionsEnabled?: boolean;
}

// The wizard's and the form's fields (the server checks every one again).
export interface DepartmentFields {
    label?: string;
    short?: string;
    jobs?: string[];
    supervisorGrade?: number;
    societyAccount?: string;
    theme?: DeptTheme;
    logo?: DeptLogoSetting;
    // sent only when the Officer options panel changed ({} = back to the global options)
    officerOptions?: DeptOfficerOptions;
}

// ============================================================================
//                                   SUPPORT
// ============================================================================

export interface AccessStep {
    check: 'job' | 'department_on' | 'duty' | 'suspended' | 'suspended_dispatch' | 'retired' | 'arena' | 'way';
    ok: boolean;
    vars?: Record<string, string>;
}

// admin:checkAccess: the opening checks in order; error is the opening code's own answer.
export interface CheckAccessResult {
    ok: boolean;
    error?: string;
    // locale key of the fix (README 8.1)
    fix?: string;
    steps: AccessStep[];
    via: string;
    src?: number;
    citizenid?: string;
    name?: string;
    job?: string;
    department?: string;
}

// admin:getClientState: the player's Diag.state().
export interface ClientStateView {
    screen?: string;
    nuiFocus?: boolean;
    nuiKeepInput?: boolean;
    tabletOpen?: boolean;
    panel?: string;
    testFocus?: string;
    pickup?: boolean;
    run?: string;
    scriptCam?: boolean;
    playerControl?: boolean;
    frozen?: boolean;
    dead?: boolean;
    lastStand?: boolean;
    metaDead?: boolean;
    inVehicle?: boolean;
    pauseMenu?: boolean;
}

// ============================================================================
//                                 AUDIT EXPORT
// ============================================================================

export interface AuditPartView {
    csv: string;
    rows: number;
    part: number;
    parts: number;
    total: number;
    // The newest audit row id the export holds to; sent back with the later parts.
    maxId?: number;
}

export interface AuditSaveReply {
    path: string;
    rows: number;
    truncated: boolean;
}

// ============================================================================
//                                  TIMED JOBS
// ============================================================================

// admin:getJobs (System → Jobs): every timed job (modules/system/schedule.lua Schedule.jobsView).
export interface JobLast {
    at: number;
    by?: string | null;
    durationMs: number;
    // what it did: counts by name (n, archived, kept, auditDeleted, ...)
    result?: Record<string, number> | null;
    error?: string | null;
    // off | busy | running | maintenance | not_started
    skipped?: string | null;
}

export interface JobView {
    id: string;
    when: 'daily' | 'weekly' | 'monthly' | 'every';
    // seconds, for an 'every' job
    every?: number | null;
    on: boolean;
    manual: boolean;
    running: boolean;
    nextRunAt?: number | null;
    last?: JobLast | null;
    settings: { path: string; value?: string | number | boolean | null }[];
}

export interface JobsView {
    jobs: JobView[];
    resetHour: number;
    weekStartsOn: string;
    runNowMinutes: number;
    requestDays: number;
}
