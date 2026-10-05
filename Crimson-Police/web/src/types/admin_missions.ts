// Full admin control, Missions and Mission Builder (docs/ARCHITECTURE.md §8.4.2): the shapes of the admin reads and
// actions of modules/missions, builder, testing, operations and missioncalls.

// ============================================================================
//                     EDITED BUILT-IN MISSIONS (overrides)
// ============================================================================

// The override view of a built-in (builder:list builtins[].override, builder:get record.override).
export interface OverrideView {
    overridden: boolean; // an override plays now
    shippedHash: string | null;
    baseHash: string | null; // the shipped file the edit was made from (or kept with Keep mine)
    version: number | null;
    hasDraft: boolean;
    status: 'draft' | 'published' | 'archived' | null;
    tweaks: Record<string, unknown> | null; // MissionTweaks on top
    loadError?: string; // the override file did not load (the shipped mission plays)
    changed: boolean; // the original changed since the edit
}

export interface DiffLine {
    path: string;
    from?: string;
    to?: string;
}

export interface DiffSummary {
    label?: { from?: string; to?: string };
    locationsAdded: string[];
    locationsRemoved: string[];
    objectivesFrom: string[];
    objectivesTo: string[];
}

// admin:builtinDiff { id }
export interface BuiltinDiff {
    id: string;
    changed: boolean;
    shippedHash: string | null;
    baseHash: string | null;
    original: DiffLine[] | null; // what the update changed in the original (null: no base copy)
    originalMore: boolean;
    yours: DiffLine[]; // the override against the new original
    yoursMore: boolean;
    summary: DiffSummary;
}

// builder:versionDiff { id, version }
export interface VersionDiff {
    id: string;
    version: number;
    current: number;
    summary: DiffSummary;
    lines: DiffLine[];
    more: boolean;
}

// ============================================================================
//                             THE LOAD RESULT (C4)
// ============================================================================

export interface LoadFailure {
    id: string;
    file?: string;
    error: string;
}

export interface BuilderSync {
    checked: number;
    edited: { id: string; version?: number }[];
    rejected: { id: string; error: string }[];
    conflicts: string[];
    rewritten: string[];
    error?: string;
}

// admin:getMissionLoad, and the answer of server:admin:reloadMissions
export interface MissionLoadSummary {
    loaded: number;
    builtin: number;
    custom: number;
    overridden?: number;
    warnings: number;
    warningTexts?: { id: string; text: string }[];
    failed: LoadFailure[];
    overrideFailed?: LoadFailure[];
    builder?: BuilderSync | null;
    error?: string;
    at?: number;
}

// ============================================================================
//                            QUICK EDIT (#30, #31)
// ============================================================================

export interface TweakObjective {
    index: number;
    block: string;
    label?: string;
    peds?: string[];
    vehicles?: string[];
    weapons?: string[];
}

export interface MissionTweak {
    cooldown?: number;
    timeLimit?: number;
    startTimeout?: number;
    peds?: string[];
    vehicles?: string[];
    weapons?: string[];
    disabledLocations?: unknown;
}

// admin:getMissionTweak { missionId }
export interface MissionTweakView {
    missionId: string;
    label: string;
    overridden: boolean;
    file: { cooldown?: number; timeLimit?: number; startTimeout?: number };
    live: { cooldown?: number; timeLimit?: number; startTimeout?: number };
    tweak: MissionTweak | null;
    tweaked: boolean;
    objectives: TweakObjective[];
    allowed: { peds: string[]; vehicles: string[]; weapons: string[] };
    ranges: Record<'cooldown' | 'timeLimit' | 'startTimeout', [number, number]>;
}

// ============================================================================
//                      SWITCHES THAT NO LONGER MATCH (O3)
// ============================================================================

export interface SwitchRemapMission {
    id: string;
    label: string;
    stale: (string | number)[];
    locations: { index: number; label: string }[];
}

export interface SwitchRemapData {
    missions: SwitchRemapMission[];
}

// ============================================================================
//                        HISTORY AND STATS (C6, C7, C8)
// ============================================================================

export interface OperationParticipant {
    citizenid: string;
    name?: string;
    department: string;
    state: string;
    points: number;
    voided: boolean;
}

export interface OperationHistoryRow {
    id: number;
    missionId: string;
    missionLabel: string;
    launchedBy: string;
    launchedByName?: string;
    status: string;
    createdAt: number;
    endedAt?: number;
    participants: OperationParticipant[];
    points: number;
}

export interface Paged<R> {
    rows: R[];
    page: number;
    pages: number;
    total: number;
}

export interface DispatchHistoryRow {
    id: number;
    code: string;
    type: string;
    typeLabel: string;
    area?: string;
    areaLabel?: string;
    priority: number;
    status: string;
    outcome?: string;
    issuer?: string;
    issuerName?: string;
    pagedTo?: string;
    pagedName?: string;
    claimedBy?: string;
    claimedName?: string;
    claimants: number;
    reopened: boolean;
    reason?: string;
    createdAt: number;
    claimedAt?: number;
    closedAt?: number;
    claimSeconds?: number;
}

export interface MissionStatsRow {
    key: string;
    label: string;
    type?: string;
    runs: number;
    completed: number;
    failed: number;
    abandoned: number;
    points: number;
    cash: number;
    flags: number;
    voids: number;
    completionRate: number;
    failRate: number;
    abandonRate: number;
    avgDuration: number;
    avgPoints: number;
    avgCash: number;
    timeLimit?: number;
    durationShare?: number;
}

export interface MissionStatsData {
    from: number;
    to: number;
    missions: MissionStatsRow[];
    types: MissionStatsRow[];
}

// ============================================================================
//                       DELETE, IMPORT, COPY (#35, C13)
// ============================================================================

export interface DeletedMission {
    id: string;
    folder: string;
    label: string;
    type?: string;
    version?: number;
    deletedAt: number;
    deletedBy?: string;
    reason?: string;
}

export interface ImportPreview {
    previewToken: string;
    expiresAt: number;
    effect: {
        label: string;
        type: string;
        sourceId?: string;
        objectives: { block: string; label: string }[];
        locations: string[];
        dropped: string[];
        errors: string[];
        errorCount: number;
    };
}

export interface MissionLuaExport {
    id: string;
    version: number;
    lua: string;
}

// ============================================================================
//                           TEST RESULTS (#45, C20)
// ============================================================================

export interface TestHistoryResult {
    id: number;
    version: number | false;
    tier: string;
    testers: number;
    result: 'passed' | 'failed';
    note: string | false;
    testedBy: string;
    testedByName: string;
    testedAt: number;
    hidden: boolean;
    unplayed: boolean;
}

export interface TestHistory {
    missionId: string;
    location: number;
    results: TestHistoryResult[];
}
