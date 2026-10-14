// Response shapes of the run_ui slice (Mission Board and Active Mission screens,

import type { ActiveMissionView, BoardCard, BoardData, Goal, LevelInfo } from '../shared/types';
import type { ContactView } from './custody';

// ============================================================================
//            getMissionTypes (push topics 'board' and 'operation')
// ============================================================================

// A mission type card (BoardCard §9.4). `locked.until` is a Unix timestamp (os.time) of the cooldown end.
export type TypeCard = BoardCard;

// The Weekly Boss event card (BoardCard + available). Accepted with the key 'weekly_boss'.
export type BossCard = NonNullable<BoardData['boss']>;

// BoardData.operation: the §9.4 fields plus the extras CP.Operations.boardCard sends (docs/notes/teams.md).
export type BoardOperation = NonNullable<BoardData['operation']> & {
    missionType?: string;
    missionTypeLabel?: string;
    description?: string | null;
    // Participants needed to start.
    min?: number;
    // State of the operation's run while it exists.
    runState?: 'accepted' | 'in_progress' | null;
    // Why this viewer cannot join (the err.* key server:joinOperation would return); missing when canJoin.
    joinBlocked?: string | null;
};

// Callback 'getMissionTypes'. Optional extras (requested from modules/draw, docs/notes/run_ui.md):
// `serverTime` = os.time() when the board was built; `todMultiplier` = Config.Events.todMultiplier (the
// Type of the Day's points multiplier; the board assumes the default 2 without it).
export interface MissionBoardData extends Omit<BoardData, 'operation'> {
    operation: BoardOperation | null;
    serverTime?: number;
    todMultiplier?: number;
}

// Reply of server:acceptType.
export interface AcceptTypeResult {
    runId: string;
}

// Reply of server:joinOperation.
export interface JoinOperationResult {
    id: number;
    joined: number;
    max: number;
}

// ============================================================================
//                          getRun (push topic 'run')
// ============================================================================

export type RunPartner = ActiveMissionView['partners'][number];
export type RunObjective = ActiveMissionView['objectives'][number];
export type RunRoute = NonNullable<ActiveMissionView['route']>;
export type RunLog = NonNullable<ActiveMissionView['log']>;

// ActiveMissionView plus optional extras (requested from modules/runs, see docs/notes/run_ui.md).
export interface ActiveMissionData extends ActiveMissionView {
    // The viewer's server id (marks "You" in the partners list).
    me?: number;
    // The Weekly Boss run (abandoning uses up the week's attempt instead of a type cooldown).
    isBoss?: boolean;
    // Cross-Department Mission id when the run belongs to one.
    operationId?: number | null;
    // Seconds left to reach the start (Accepted only, this participant).
    startIn?: number | null;
    // Street and zone name of the current objective area (shown instead of map details, e.g. Radio Silence).
    area?: string | null;
    // The intel line a block set (e.g. hostile_waves spawn sets), already in the player's language.
    intel?: string | null;
    // The claimed mission call: its code, the response target and when this viewer arrived (seconds from the claim).
    missionCall?: null | { code: string; targetS: number; arrivedS: number | null };
    // The current objective's contacts (field_contact, through CP.Custody.view).
    contact?: ContactView | null;
}

// ============================================================================
//                   RunResult ADDITIONS (the result screen)
// ============================================================================

// One graded disposition of the decision ledger. discoverable: whether the truth was lawfully findable;
// knownAtS: when the deciding fact reached the decider (seconds from the start); factLog: every fact the decider
// had when choosing, as text, with when it reached them (older rows lack it).
export interface DecisionEntry {
    contact: string;
    kind: 'person' | 'vehicle';
    choice: string;
    best: string;
    verdict: 'best' | 'ok' | 'wrong' | 'critical';
    by: string;
    truth: string;
    facts: string[];
    factLog?: DecisionFact[];
    points: number;
    discoverable: boolean;
    knownAtS: number | null;
}
export interface DecisionFact {
    key: string;
    text: string;
    atS: number | null;
}
// The people debrief: each person with a demeanour, and what they did (walked_away, ran, drew, surrendered,
// feinted, cuffed, escaped, killed; empty = stayed and complied). Only in the result of a run that ended.
export interface DebriefPerson {
    contact: string;
    demeanour: string | null;
    did: string[];
}
// XP before and after this row, the level, a level-up and the goals (pending = XP waits for a review).
export interface RunProgress {
    xpBefore: number;
    xpAfter: number;
    pending: boolean;
    level: LevelInfo;
    levelUp: boolean;
    goals: { daily: Goal | null; weekly: Goal | null };
}
export type RunStatKey =
    | 'arrests'
    | 'citations'
    | 'impounds'
    | 'rescues'
    | 'vehicles_stopped'
    | 'evidence'
    | 'decisions_ok'
    | 'decisions_best'
    | 'decisions_bad';
export type RunStats = Partial<Record<RunStatKey, number>>;
export interface RunMissionCall {
    code: string;
    responseS: number | null;
    targetS: number;
    rapid: boolean;
}
export interface RunItem {
    name: string;
    label: string;
    count: number;
    status: 'given' | 'pending' | 'held';
}

// Reply of server:abandon.
export interface AbandonResult {
    runId: string;
}

// Reply of the client action recalcRoute.
export interface RecalcRouteResult {
    recalcsLeft: number;
}

// Reply of the client action setGps.
export interface SetGpsResult {
    runId: string;
}

// Payload of the client action logResult (Business Check tablet log).
export interface LogResultPayload {
    point: number;
    choice: string;
}
