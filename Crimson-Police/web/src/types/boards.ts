// Shapes of the boards slice (modules/leaderboard, modules/challenge).

import type { Board, BoardRow, ChallengeView, Profile, ProfileRun } from '../shared/types';

export type BoardPeriod = 'weekly' | 'monthly' | 'season' | 'alltime';

// getBoard reply: Board (§9.4) plus window/season details. me.rank = 0 means "not ranked yet".
export interface BoardView extends Board {
    department?: string;
    minRuns?: number;
    topN?: number;
    ranked?: number;
    // fromDate/toDate: 'YYYY-MM-DD' in server time; show these, never from/to read in the player's time zone.
    window?: { from: number; to?: number | null; fromDate?: string | null; toDate?: string | null } | null;
    season?: { id: number; name: string; active: boolean } | null;
}

export interface ChallengeDepartment {
    key: string;
    label: string;
    short: string;
    colour: string;
    score: number;
    activeOfficers: number;
    officers?: number;
    points?: number;
    completed?: number;
    unitRuns?: number;
    bonus?: number;
    rank?: number;
}

export interface BountyRate {
    key: string;
    short: string;
    colour: string;
    count: number;
    activeOfficers: number;
    rate: number;
}

export interface BountyView {
    id: string;
    label: string;
    leader: string | null;
    leaderKey?: string | null;
    week?: number;
    endsIn?: number;
    closed?: boolean;
    overridden?: boolean;
    rates?: BountyRate[];
}

export interface Contributor {
    rank?: number;
    citizenid?: string;
    name: string;
    callsign: string | null;
    points: number;
    runs?: number;
    active?: boolean;
}

// getChallenge reply: ChallengeView (§9.4) plus the optional extras.
export interface ChallengeData extends Omit<ChallengeView, 'season' | 'departments' | 'bounty' | 'topContributors'> {
    season: null | { id: number; name: string; weeksLeft: number; week?: number; startsAt?: number };
    departments: ChallengeDepartment[];
    bounty: BountyView | null;
    topContributors: Contributor[];
    enabled?: boolean;
    mode?: 'average' | 'total' | 'top10';
    minRunsActive?: number;
    myDepartment?: string;
}

export interface DeptInfo {
    key: string;
    label: string;
    short: string;
    colour: string;
}

// getDeptContributors({ department })
export interface DeptContributors {
    department: DeptInfo | null;
    season: null | { id: number; name: string };
    minRunsActive: number;
    contributors: Contributor[];
}

// getProfile reply: Profile (§9.4) plus extras. Public profiles: cash 0, cashStatus '', breakdown.cash missing.
export interface ProfileData extends Omit<Profile, 'badges'> {
    badges: { id: string; label: string; earnedAt: string; kind?: 'week' | 'champion' | 'top10' | 'achievement' }[];
    departmentLabel?: string;
    seasonPoints?: number;
    disputeWindowHours?: number;
}
export type ProfileRunView = ProfileRun & { createdTs?: number };

// ============================================================================
//                             ADMIN: Leaderboards
// ============================================================================

export interface AdminBoardRow extends BoardRow {
    cash: number;
    realName: string;
    hidden: boolean;
    department?: string;
}

export interface StuckPayment {
    rowId: number;
    runUuid: string;
    citizenid: string;
    name?: string | null;
    callsign?: string | null;
    missionLabel: string;
    amount: number;
    createdAt: string;
    transId: string;
}

export interface AdminRun {
    id: number;
    runUuid: string;
    missionLabel: string;
    missionType: string;
    state: string;
    endReason: string;
    points: number;
    cash: number;
    cashStatus: string;
    flagged: boolean;
    flagReason?: string | null;
    voided: boolean;
    departmentShort: string;
    participants: number;
    departments: number;
    tier: string;
    createdAt: string;
    createdTs: number;
}

// admin:getBoards({ period, filter, department, citizenid? })
export interface AdminBoards {
    period: string;
    filter: string;
    department?: string;
    rows: AdminBoardRow[];
    unranked: AdminBoardRow[];
    stuck: StuckPayment[];
    minRuns: number;
    updatedAt: number;
    // fromDate/toDate: 'YYYY-MM-DD' in server time; show these, never from/to read in the player's time zone.
    window?: { from: number; to?: number | null; fromDate?: string | null; toDate?: string | null } | null;
    season?: { id: number; name: string; active: boolean } | null;
    citizenid?: string;
    runs?: AdminRun[];
}

// ============================================================================
//                          ADMIN: Seasons & Challenge
// ============================================================================

export interface SeasonView {
    id: number;
    name: string;
    startsAt: number;
    endsAt?: number | null;
    active: boolean;
    week: number;
    weeksLeft: number;
}

export interface BountyHistoryRow {
    seasonId: number;
    seasonName: string;
    week: number;
    objective: string;
    label: string;
    winner?: string | null;
    winnerShort?: string | null;
    bonus: number;
    closed: boolean;
    current: boolean;
    startsAt: number;
    endsAt: number;
    startDate?: string | null;
    endDate?: string | null;
}

export interface SeasonListRow {
    id: number;
    name: string;
    startsAt: number;
    endsAt?: number | null;
    active: boolean;
    champion?: string | null;
    championShort?: string | null;
}

// admin:getSeasons
export interface SeasonsAdmin {
    current: SeasonView | null;
    latest: SeasonView | null;
    standings: ChallengeDepartment[];
    bounty: BountyView | null;
    bountyHistory: BountyHistoryRow[];
    seasons: SeasonListRow[];
    bounties: { id: string; label: string }[];
    enabled: boolean;
    weeklyBounty: boolean;
    mode: string;
    seasonWeeks: number;
    minRunsActive: number;
}

// ============================================================================
//                        SUPERVISOR: Department Report
// ============================================================================

export interface ReportOfficer {
    citizenid: string;
    name: string;
    callsign: string | null;
    rank: string;
    runs: number;
    completed: number;
    failed: number;
    abandoned: number;
    flagged: number;
    points: number;
    cash: number;
    lastRunAt: string;
    lastRunTs: number;
}

// sup:getDeptReport
export interface DeptReport {
    department: DeptInfo | null;
    season: null | { id: number; name: string; weeksLeft: number; week: number };
    enabled?: boolean;
    standing: (ChallengeDepartment & { of?: number }) | null;
    standings: ChallengeDepartment[];
    bounty: BountyView | null;
    week: { key: string; startsAt: number };
    officers: ReportOfficer[];
}

export interface ActivityRun {
    id: number;
    missionLabel: string;
    missionType: string;
    state: string;
    endReason: string;
    points: number;
    cash: number;
    cashStatus: string;
    flagged: boolean;
    flagReason?: string | null;
    voided: boolean;
    participants: number;
    departments: number;
    tier: string;
    durationS: number;
    createdAt: string;
    createdTs: number;
}

// sup:getOfficerActivity({ citizenid })
export interface OfficerActivity {
    officer: { citizenid: string; name: string; callsign: string | null; rank: string; departmentShort: string };
    week: { key: string; startsAt: number };
    runs: ActivityRun[];
}

// Lua encodes an empty table as {} (not []): anything that is not an array is an empty list.
export function asList<T>(v: T[] | null | undefined | Record<string, never>): T[] {
    return Array.isArray(v) ? v : [];
}
