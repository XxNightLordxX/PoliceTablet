// Full admin control, officers and boards (P1): the shapes of modules/corrections, the officers tools in
// modules/profile, scoring, goals, and the recognition and season tools in modules/leaderboard and challenge
// (docs/ARCHITECTURE.md §5.38 and §9.5).

import type { DebriefPerson, DecisionEntry } from './run_ui';
import type { ChallengeDepartment, Contributor, SeasonView } from './boards';

// ============================================================================
//                      RUN HISTORY (admin:getOfficerRuns)
// ============================================================================

export type VoidKind = 'strike' | 'correction';

export interface OfficerRunRow {
    id: number;
    runUuid: string;
    // a row of cp_mission_runs_archive (restore and flag work on live rows; restore also on archived ones)
    archived: boolean;
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
    department: string;
    operationId: number | null;
    points: number;
    cashPaid: number;
    cash: number;
    cashStatus: string;
    flagged: boolean;
    flagReason: string | null;
    voided: boolean;
    voidKind: VoidKind | null;
    voidBatch: string | null;
    durationS: number;
    createdAt: number;
    // the Renewed-Banking transaction id (search it in the bank history)
    txnId: string | null;
    // a manual award or adjustment: who gave it and why
    awardBy: string | null;
    awardReason: string | null;
}

export interface OfficerRunsFilter {
    citizenid: string;
    page?: number;
    size?: number;
    from?: string;
    to?: string;
    type?: string;
    state?: string;
    flagged?: boolean;
    voided?: boolean;
    kind?: VoidKind;
    includeArchive?: boolean;
}

export interface OfficerRunsPage {
    runs: OfficerRunRow[];
    total: number;
    page: number;
    pages: number;
    size: number;
}

// admin:getRun: one row with its debrief, everyone on the run, its dispute and the goal rewards it completed.
export interface RunDetail extends OfficerRunRow {
    citizenid: string;
    breakdown: (Record<string, unknown> & { decisions?: DecisionEntry[]; people?: DebriefPerson[] }) | null;
    participantsList: {
        rowId: number;
        archived: boolean;
        citizenid: string;
        name: string;
        callsign: string | null;
        department: string;
        state: string;
        points: number;
        voided: boolean;
        flagged: boolean;
    }[];
    dispute: { id: number; status: string; reason: string; goesTo: string } | null;
    goalRewards: { rowId: number; goalId: string; label: string; points: number }[];
    // the admin (any of their characters) took part: every change is refused
    own: boolean;
}

// ============================================================================
//                                POINTS AND XP
// ============================================================================

export interface PointsWindow {
    points: number;
    rank: number;
    ranked: number;
}

export interface OfficerPoints {
    citizenid: string;
    windows: { weekly: PointsWindow; monthly: PointsWindow; season: PointsWindow; alltime: PointsWindow };
    seasonPoints: number;
    season: { id: number; name: string } | null;
    xp: number;
    level: { label: string; badge: string; xp: number; next: number | null; n?: number } | null;
    adjust: {
        enabled: boolean;
        max: number;
        // the most a deduction may take now (season points and XP never below 0)
        maxDeduction: number;
        // a typed confirmation (the citizenid) at or above this
        confirmAbove: number;
        dailyLimit: number;
    };
}

export interface XpCheck {
    citizenid: string;
    stored: number;
    derived: number;
    rows: number;
    diff: number;
}

// ============================================================================
//                            BULK VOID AND BATCHES
// ============================================================================

export interface BulkVoidFilter {
    citizenid?: string;
    department?: string;
    missionType?: string;
    missionId?: string;
    operationId?: number;
    from?: string | number;
    to?: string | number;
    allTime?: boolean;
    includeAwards?: boolean;
}

export interface VoidPreviewRow {
    key: string;
    id: number;
    citizenid: string;
    missionLabel: string;
    missionType: string;
    state: string;
    points: number;
    cashStatus: string;
    archived: boolean;
    createdAt: number;
}

export interface VoidPreviewOfficer {
    citizenid: string;
    name?: string;
    rows: number;
    points: number;
    held: number;
    xpBefore?: number;
    xpAfter?: number;
}

// admin:previewBulkVoid and admin:previewRetire
export interface VoidPreview {
    total: number;
    points: number;
    held: number;
    archived: number;
    officers: VoidPreviewOfficer[];
    rows: VoidPreviewRow[];
    // rows of runs the admin (any of their characters) took part in, left out
    excluded?: number;
    max?: number;
    tooMany?: boolean;
    confirmWord: string;
    previewToken?: string;
    // previewRetire: the officer is on a run, in a ready check or on an operation (an err.* key)
    busy?: string | null;
    online?: boolean;
}

export type BatchKind =
    | 'bulkVoid'
    | 'retire'
    | 'restoreBatch'
    | 'recordMove'
    | 'recordMoveUndo'
    | 'seasonReopen'
    | 'reopenUndo'
    | 'recheckBadges';

export interface CorrectionBatch {
    id: string;
    kind: BatchKind;
    state: 'running' | 'done' | 'failed' | 'rolledback';
    filter: Record<string, unknown>;
    done: number;
    total: number;
    actor: string;
    reason: string | null;
    createdAt: number;
    restored: boolean;
    undone: boolean;
    undo: 'restoreBatch' | 'unretire' | 'undoRecordMove' | 'undoReopen' | null;
}

// ============================================================================
//                                 RECORD MOVE
// ============================================================================

export interface RecordMovePreview {
    from: string;
    to: string;
    // both licenses known and equal; otherwise the admin types UNVERIFIED <citizenid>
    verified: boolean;
    confirmWord: string;
    effect: {
        rows: number;
        live: number;
        archived: number;
        points: number;
        held: number;
        badges: number;
        commendations: number;
        disputes: number;
        rewards: number;
    };
    previewToken: string;
}

// ============================================================================
//                             BADGES, GOALS, LOOK
// ============================================================================

export interface BadgeCatalog {
    achievements: { id: string; label: string; need: number }[];
    recognition: string[];
}

export interface GoalItem {
    id: string;
    label: string;
    count: number;
    progress: number;
    done: boolean;
    points: number;
}

export interface OfficerGoals {
    daily: GoalItem | null;
    weekly: GoalItem | null;
}

export interface OfficerLook {
    appearance: string | null;
    accent: string | null;
    uiScale: number | null;
    effective: Record<string, unknown>;
    hideName: boolean;
    callsMuted: boolean;
    nextEditIn: number;
    urlsLeft: number;
}

export interface BannedWords {
    file: string | null;
    words: string[];
    settingsWords: string[];
    max: number;
}

export interface BannedTest {
    banned: boolean;
    matches: string[];
}

// ============================================================================
//                        RECOGNITION AND STAFF NOTICES
// ============================================================================

export interface StaffNotice {
    id: number;
    text: string;
    departments: string[] | null;
    expiresAt: number;
    createdAt: number;
    by: string;
}

export interface HomeAnnouncement {
    kind: 'weekly_top3' | 'monthly_top3' | 'staff_notice' | string;
    text: string;
    period?: string;
    notice?: StaffNotice;
}

export interface BadgeHolder {
    citizenid: string;
    name: string;
    callsign: string | null;
    earnedAt: number;
}

export interface TopEntry {
    citizenid: string;
    name: string;
    callsign?: string | null;
    departmentShort?: string;
    points: number;
}

export interface WeekRecognition {
    weekKey: string;
    from: number;
    to: number;
    badgeId: string;
    top: TopEntry[];
    holders: BadgeHolder[];
    // the badge holder is not the week's #1 any more (a void or a restore since)
    changed: boolean;
    previewToken?: string;
}

export interface RecognitionData {
    home: HomeAnnouncement[];
    notices: StaffNotice[];
    weeks: WeekRecognition[];
    announceWeekly: boolean;
    announceMonthly: boolean;
}

// ============================================================================
//                                 SEASON TOOLS
// ============================================================================

export interface SeasonReward {
    id: number;
    citizenid: string;
    key: string;
    item: string;
    count: number;
    status: string;
    // an unfinished reward is cancelled; a given one stays given
    fate: 'cancel' | 'kept' | 'none';
}

export interface SeasonTop10Row {
    rank: number;
    citizenid: string;
    name: string;
    departmentShort: string;
    points: number;
}

export interface SeasonEndPreview {
    season: SeasonView;
    champion: string | null;
    championShort: string | null;
    trophies: number;
    standings: ChallengeDepartment[];
    top10: SeasonTop10Row[];
}

export interface ReopenPreview {
    season: SeasonView;
    champion: string | null;
    championShort: string | null;
    trophies: BadgeHolder[];
    top10: BadgeHolder[];
    rewards: SeasonReward[];
    // rows written since the end that join the season again
    gapRows: number;
    previewToken: string;
}

export interface BountyRecountPreview {
    seasonId: number;
    week: number;
    objective: string;
    label: string;
    old: string;
    oldShort: string | null;
    new: string;
    newShort: string | null;
    changed: boolean;
    previewToken: string;
}

export interface ChampionRecountPreview {
    seasonId: number;
    seasonName: string;
    old: string;
    oldShort: string | null;
    new: string;
    newShort: string | null;
    changed: boolean;
    badgeId: string;
    oldHolders: BadgeHolder[];
    newHolders: { citizenid: string }[];
    rewards: SeasonReward[];
    previewToken: string;
}

export interface SeasonDetail {
    season: SeasonView;
    standings: ChallengeDepartment[];
    weeks: {
        week: number;
        objective: string;
        label: string;
        winner: string | null;
        winnerShort: string | null;
        closed: boolean;
        startDate: string;
        endDate: string;
    }[];
    champion: string | null;
    championShort: string | null;
    trophies: BadgeHolder[];
    top10: BadgeHolder[];
    championRecount: boolean;
}

export type { Contributor };
