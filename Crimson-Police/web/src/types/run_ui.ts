// src/types/run_ui.ts · response shapes of the run_ui slice (Mission Board and Active Mission screens,
// documented in docs/notes/run_ui.md). BoardData and ActiveMissionView are contract shapes
// (src/shared/types.ts, ARCHITECTURE §9.4); the types below only add the optional fields the server
// sends (or may send) on top of them. Every extra field is optional: the screens work without them.
import type { ActiveMissionView, BoardCard, BoardData } from '../shared/types';

// ── getMissionTypes (push topics 'board' and 'operation') ─────────────────────

/** A mission type card (BoardCard §9.4). `locked.until` is a Unix timestamp (os.time) of the cooldown end. */
export type TypeCard = BoardCard;

/** The Weekly Boss event card (BoardCard + available). Accepted with the key 'weekly_boss'. */
export type BossCard = NonNullable<BoardData['boss']>;

/** BoardData.operation: the §9.4 fields plus the extras CP.Operations.boardCard sends (docs/notes/teams.md). */
export type BoardOperation = NonNullable<BoardData['operation']> & {
  missionType?: string;
  missionTypeLabel?: string;
  description?: string | null;
  /** Participants needed to start. */
  min?: number;
  /** State of the operation's run while it exists. */
  runState?: 'accepted' | 'in_progress' | null;
};

/** Callback 'getMissionTypes'. Optional extras (requested from modules/draw, docs/notes/run_ui.md):
 *  `serverTime` = os.time() when the board was built; `todMultiplier` = Config.Events.todMultiplier (the
 *  Type of the Day's points multiplier; the board assumes the default 2 without it). */
export interface MissionBoardData extends Omit<BoardData, 'operation'> {
  operation: BoardOperation | null;
  serverTime?: number;
  todMultiplier?: number;
}

/** Reply of server:acceptType. */
export interface AcceptTypeResult { runId: string }

/** Reply of server:joinOperation. */
export interface JoinOperationResult { id: number; joined: number; max: number }

// ── getRun (push topic 'run') ─────────────────────────────────────────────────

export type RunPartner = ActiveMissionView['partners'][number];
export type RunObjective = ActiveMissionView['objectives'][number];
export type RunRoute = NonNullable<ActiveMissionView['route']>;
export type RunLog = NonNullable<ActiveMissionView['log']>;

/** ActiveMissionView plus optional extras (requested from modules/runs, see docs/notes/run_ui.md). */
export interface ActiveMissionData extends ActiveMissionView {
  /** The viewer's server id (marks "You" in the partners list). */
  me?: number;
  /** The Weekly Boss run (abandoning uses up the week's attempt instead of a type cooldown). */
  isBoss?: boolean;
  /** Cross-Department Mission id when the run belongs to one. */
  operationId?: number | null;
  /** Seconds left to reach the start (Accepted only, this participant). */
  startIn?: number | null;
  /** Street and zone name of the current objective area (shown instead of map details, e.g. Radio Silence). */
  area?: string | null;
}

/** Reply of server:abandon. */
export interface AbandonResult { runId: string }

/** Reply of the client action recalcRoute. */
export interface RecalcRouteResult { recalcsLeft: number }

/** Reply of the client action setGps. */
export interface SetGpsResult { runId: string }

/** Payload of the client action logResult (Business Check tablet log). */
export interface LogResultPayload { point: number; choice: string }
