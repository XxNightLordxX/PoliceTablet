// Full admin control, System (modules/sysadmin): storage, backups, webhooks, problems, integrations, departments added
// in game, Support (docs/ARCHITECTURE.md §9.5, "Admin control: system").

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

export interface ResourceView {
    name: string;
    state: string;
    version?: string | null;
    required: boolean;
}

export interface IntegrationsData {
    resources: ResourceView[];
    // locale keys of the README §7 checklist
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
    // locale key of the fix (README 11.1)
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
}

export interface AuditSaveReply {
    path: string;
    rows: number;
    truncated: boolean;
}
