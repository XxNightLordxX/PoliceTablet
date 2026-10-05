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
}
export interface LiveRunsData {
    runs: LiveRunEx[];
    serverTime: number;
    canRecall: boolean;
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
    durationS: number;
    createdAt: number;
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

export interface PermissionsData {
    supervisor: { action: string; enabled: boolean }[];
    adminOnly: string[];
    always: string[];
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
