// Shapes of the oversight slice's callbacks (modules/admin, modules/disputes). The server side is documented in the
// header comments of those modules and in docs/notes/oversight.md.

import type { LiveRun, Logo, Theme } from '../shared/types';
import type { DebriefPerson, DecisionEntry } from './run_ui';

// ============================================================================
//                                getMissionList
// ============================================================================

export interface MissionRunner {
    runId: string;
    src: number;
    name: string;
    callsign: string | null;
    departmentShort: string;
    test: boolean;
}
export interface MissionListEntry {
    id: string;
    label: string;
    type: string;
    typeLabel: string;
    source: 'builtin' | 'custom';
    builtin: boolean;
    version: number | null;
    difficulty: number;
    minOfficers: number;
    maxOfficers: number;
    basePayout: number;
    payoutSource: 'admin' | 'type' | 'event';
    cooldown: number;
    // seconds as it applies now: cooldown x the supervisors' scale for the type (Mission controls)
    cooldownNow?: number;
    timeLimit: number;
    locations: number;
    enabled: boolean;
    isBoss: boolean;
    departments: string[];
    runningNow: MissionRunner[];
    crossDeptEligible: boolean;
}
export interface MissionListData {
    missions: MissionListEntry[];
    canLaunch: boolean;
    crossDeptEnabled: boolean;
    operation: null | { id: number | null; missionId: string | null; missionLabel: string; status: string | null };
}

// ============================================================================
//                               sup:getLiveRuns
// ============================================================================

export type LiveParticipant = LiveRun['participants'][number] & { arrived?: boolean; department?: string | null };
export interface LiveRunEx extends Omit<LiveRun, 'participants'> {
    participants: LiveParticipant[];
    missionId: string;
    acceptedAt: number | null;
    startedAt: number | null;
    isBoss: boolean;
    departments: string[];
    // step P7: seconds admins and supervisors added so far; own = the viewer is or was on it (no + minutes)
    timeAdded?: number;
    own?: boolean;
}
// "+ minutes" for this supervisor (step P7, Config.MissionControls.controls.addRunTime): minutes per click, seconds
// per run in all, additions a day and today's
export interface SupAddTime {
    min: number;
    max: number;
    maxSeconds: number;
    perDay: number;
    usedToday: number;
}
export interface LiveRunsData {
    runs: LiveRunEx[];
    serverTime: number;
    canRecall: boolean;
    addTime?: SupAddTime | null;
}

// ============================================================================
//                            REVIEW QUEUE / FLAGGED
// ============================================================================

export interface FlaggedRow {
    rowId: number;
    runUuid: string;
    citizenid: string;
    name: string;
    callsign: string | null;
    department: string;
    departmentShort: string;
    missionId: string;
    missionLabel: string;
    missionType: string;
    missionTypeLabel: string;
    location: string | null;
    state: 'completed' | 'failed' | 'abandoned';
    endReason: string;
    tier: string;
    participants: number;
    departments: number;
    points: number;
    cash: number;
    cashStatus: string;
    flagReason: string;
    flagDetail: string | null;
    otherReasons: string[];
    // Staff notes (CP.AntiCheat.note, audit runNoted) about this officer or the whole case: they hold no points.
    notes: FlagNote[];
    durationS: number;
    createdAt: number;
}
export interface FlagNote {
    reason: string;
    detail: string | null;
    note: true;
}
export type DisputeKind = 'flagged' | 'voided' | 'failed';
export interface DisputeView {
    id: number;
    rowId: number;
    runUuid: string;
    citizenid: string;
    name: string;
    callsign: string | null;
    department: string;
    departmentShort: string;
    missionId: string;
    missionLabel: string;
    missionType: string;
    missionTypeLabel: string;
    kind: DisputeKind;
    state: string;
    endReason: string;
    tier: string;
    participants: number;
    points: number;
    cash: number;
    cashStatus: string;
    flagged: boolean;
    voided: boolean;
    flagReason: string | null;
    reason: string;
    goesTo: 'supervisor' | 'admin';
    status: 'open' | 'approved' | 'rejected';
    handledBy: string | null;
    createdAt: number;
    handledAt: number | null;
    runAt: number;
    canHandle: boolean;
    // The disputed row's debrief (the decision ledger with each fact's time, and the people), when it has one.
    decisions?: DecisionEntry[] | null;
    people?: DebriefPerson[] | null;
}
export interface ReviewQueueData {
    flagged: FlaggedRow[];
    disputes: DisputeView[];
    canReview: boolean;
    canHandle: boolean;
}

// ============================================================================
//                   admin:searchOfficers / admin:getOfficer
// ============================================================================

export interface OfficerSearchRow {
    citizenid: string;
    name: string;
    callsign: string | null;
    rank: string | null;
    department: string | null;
    departmentShort: string;
    xp: number;
    suspendedUntil: number | null;
    online: boolean;
    // full admin control: retired, kept off the boards, false = an online character with no row yet
    retired?: boolean;
    excluded?: boolean;
    known?: boolean;
}
// admin:searchOfficers filters (A1); every one is optional
export interface OfficerSearchFilters {
    department?: string;
    online?: boolean;
    suspended?: boolean;
    retired?: boolean;
    excluded?: boolean;
    review?: boolean;
    dispute?: boolean;
    flagged?: boolean;
}
export interface OfficerSearchData {
    officers: OfficerSearchRow[];
    query: string;
    total?: number;
    page?: number;
    pages?: number;
}
export interface OfficerRun {
    id: number;
    runUuid: string;
    missionId: string;
    missionLabel: string;
    missionType: string;
    missionTypeLabel: string;
    state: string;
    endReason: string;
    tier: string;
    participants: number;
    points: number;
    cashPaid: number;
    cash: number;
    cashStatus: string;
    flagged: boolean;
    voided: boolean;
    flagReason: string | null;
    createdAt: number;
    // the Renewed-Banking transaction id of a payment (search it in the bank history)
    txnId?: string | null;
}
export interface OfficerSuspension {
    id: number;
    action: 'suspend' | 'unsuspend' | 'autoSuspend';
    actor: string;
    actorName: string | null;
    role: 'supervisor' | 'admin' | 'console';
    days: number | null;
    reason: string | null;
    createdAt: number;
}
export interface OfficerDetail {
    citizenid: string;
    name: string;
    callsign: string | null;
    rank: string | null;
    department: string | null;
    departmentShort: string;
    departmentLabel: string | null;
    xp: number;
    level: null | { label: string; badge: string; xp: number; next: number | null };
    streakDays: number;
    // how each badge came: earned from the rows, granted or blocked by an admin (cp_badge_overrides)
    badges: {
        id: string;
        label: string;
        earnedAt?: string | number;
        source?: 'earned' | 'granted' | 'blocked';
        by?: string | null;
        reason?: string | null;
    }[];
    cash: { total: number; week: number };
    stats: { runs: number; completed: number; failed: number; abandoned: number; flagged: number; voided: number };
    suspension: { suspended: boolean; untilTs: number | null; reason?: string | null };
    // full admin control (P1): the live streak, the first-run bonus (null when offline), the SC-Dispatch suspension
    // (view only), automatic-suspension strikes, retirement, the boards exclusion
    streak?: { days: number; multiplier: number; graceLeft: boolean; stored: number };
    firstRun?: boolean | null;
    dispatch?: { suspended: boolean; available: boolean; untilTs?: number | null };
    strikes?: number;
    retired?: { at: number; batch: string | null } | null;
    boardExcluded?: boolean;
    licenseKnown?: boolean;
    // The last suspend / unsuspend / automatic suspension entries (cp_audit), newest first.
    suspensions: OfficerSuspension[];
    runs: OfficerRun[];
    disputes: DisputeView[];
    online: boolean;
    own: boolean;
    known: boolean;
    maxAward: number;
}

// ============================================================================
//                             admin:getDepartments
// ============================================================================

export interface DepartmentView {
    key: string;
    label: string;
    short: string;
    jobs: string[];
    supervisorGrade: number;
    societyAccount: string;
    theme: Theme;
    logo: Logo | null;
    members: number;
    suspended: number;
    onDuty: number;
    societyBalance: number | null;
}
export interface DepartmentsData {
    departments: DepartmentView[];
    cashSource: 'server' | 'society';
    showSociety: boolean;
}

// ============================================================================
//                             admin:getPermissions
// ============================================================================

// Config.Permissions.builderTeleport for one department: from a grade up, or only the listed grades (absent = off).
export type TeleportGrant = { minGrade: number; grades?: undefined } | { grades: number[]; minGrade?: undefined };
export interface TeleportDepartment {
    key: string;
    label: string;
    short: string;
    supervisorGrade?: number;
    // the Qbox grades of the jobs the department lists (0-10 when Qbox names none), lowest first
    grades: { level: number; name?: string }[];
    grant?: TeleportGrant;
}
export interface PermissionsData {
    supervisor: { action: string; enabled: boolean }[];
    adminOnly: string[];
    always: string[];
    // Admin UI -> Permissions -> Builder teleport (enabled = Config.Builder.teleport and the builder are on)
    teleport?: { enabled: boolean; departments: TeleportDepartment[] };
    // Config.MissionControls.grants by department key (absent = every supervisor of that department)
    missionGrants?: Record<string, TeleportGrant>;
}

// ============================================================================
//              admin:getMissionControls / sup:getMissionControls
// ============================================================================

// One control's bounds: on = the admin switch, min / max = the only values a supervisor may pick.
export interface MissionControlBounds {
    on?: boolean;
    min?: number;
    max?: number;
    // a registered flag (step P8: readyCheck's canTurnOff); a choice control's list (step P9: difficulty's presets)
    [flag: string]: boolean | number | string[] | undefined;
}
// the types control (step P10): the mission types switched off (false) and, under missions, single missions off
export interface TypeSwitches {
    [typeKey: string]: boolean | Record<string, boolean> | undefined;
    missions?: Record<string, boolean>;
}
// one mission the types control may switch off on its own (its viewExtra)
export interface TypeSwitchMission {
    id: string;
    label: string;
    type: string;
}
// a string: a choice control's pick (step P9: difficulty; step P10: featuredType, a mission type key)
// callLane (step P12): a department's own lane of mission calls; areas empty = every area.
export interface CallLaneValue {
    spawnEvery: [number, number];
    maxOpen: number;
    areas: string[];
    types: Record<string, number>;
}
export type MissionControlValue =
    number | boolean | string | Record<string, number> | TypeSwitches | CallLaneValue | null;
// A registered control as one department (or the whole server) has it now (CP.DeptControls ControlView).
export interface MissionControlState {
    key: string;
    // 'action' (step P7): a supervisor action with no value (clearCooldown, addRunTime): only its switch and bounds
    // 'choice' (step P9): one name from the list the admin's bounds give (difficulty: a Config.NpcDifficulty preset)
    kind: 'number' | 'bool' | 'map' | 'action' | 'choice';
    scope: 'between' | 'run';
    serverWide: boolean;
    // false = outside the master switch (Config.Permissions.supervisor.missionControls)
    master: boolean;
    on: boolean;
    // on, and the master switch when the control sits under it
    active: boolean;
    min?: number;
    max?: number;
    value: MissionControlValue;
    configValue: MissionControlValue;
    saved?: MissionControlValue;
    setBy?: string;
    setRole?: string;
    at?: number;
    expiresAt?: number;
    timeLeft?: number;
    waitLeft: number;
    integer?: boolean;
    // false: no min and max (only the admin switch)
    bounded?: boolean;
    // the min and max an admin may set
    range?: [number, number];
    // Config.Departments.<key>.missionControls[key] (never for a server-wide control)
    own?: MissionControlBounds;
    // happyHour (step P6): Config.MissionControls.happyHourPerDay and how many started today; clearCooldown and
    // addRunTime (step P7): uses a supervisor may make a day
    perDay?: number;
    usedToday?: number;
    // addRunTime (step P7): seconds supervisors may add to one run in all
    maxSeconds?: number;
    // the true / false bounds this control takes besides on (step P8: ['canTurnOff'] for readyCheck)
    flags?: string[];
    // readyCheck (step P8): the admin lets supervisors switch the ready check off (value 0)
    canTurnOff?: boolean;
    // a choice control (step P9): the bounds field holding its list ('presets'), the names that list offers this
    // department now and every name it may hold
    list?: string;
    offered?: string[];
    choices?: string[];
    // the types control (step P10): every mission it may switch off on its own
    missions?: TypeSwitchMission[];
    // callLane (step P12): the callable mission types (their server weight), the areas, the most open calls a lane
    // may have (Config.MissionControls.callLaneMaxOpen) and the highest weight
    laneTypes?: { key: string; label: string; weight: number }[];
    laneAreas?: { key: string; label: string }[];
    maxOpenCap?: number;
    weightMax?: number;
}
export interface MissionControlsDepartment {
    key: string;
    label: string;
    short: string;
    controls: MissionControlState[];
    // admins: the setting the department's own bounds are saved in (none for a department added in game)
    boundsPath?: string;
}
export interface MissionControlsView {
    master: boolean;
    changeWait: number;
    selfExempt: boolean;
    departments: MissionControlsDepartment[];
    serverWide: MissionControlState[];
    // admins: Config.MissionControls.controls as saved
    bounds?: Record<string, MissionControlBounds>;
}

// ============================================================================
//                      admin:getAudit / admin:exportAudit
// ============================================================================

export type AuditCategory = 'audit' | 'flags' | 'builder' | 'operations';
export interface AuditRow {
    id: number;
    actor: string;
    actorName: string | null;
    role: 'supervisor' | 'admin' | 'console';
    category: AuditCategory;
    action: string;
    target: string | null;
    oldValue: string | null;
    newValue: string | null;
    reason: string | null;
    // the acting player's license (every character of one player shares it)
    actorIdent?: string | null;
    createdAt: number;
}
export interface AuditFilters {
    category?: string;
    action?: string;
    // a group of actions (at most 30), e.g. the Cash actions preset; ignored when action is set
    actions?: string[];
    actor?: string;
    target?: string;
    role?: string;
    actorIdent?: string;
    reason?: string;
    from?: string;
    to?: string;
    page?: number;
}
export interface AuditPage {
    rows: AuditRow[];
    page: number;
    pages: number;
    total: number;
    pageSize: number;
    actions: string[];
}
export interface AuditExport {
    csv: string;
    rows: number;
    truncated: boolean;
}

// Review Queue tabs: flagged runs, disputes and (reviewProfiles) Profiles: pictures, bios and reports.
export type ReviewTab = 'flagged' | 'disputes' | 'profiles';
