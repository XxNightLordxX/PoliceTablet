// Full admin control, live runs, units and anti-farm (modules/livectl/server.lua, docs/ARCHITECTURE.md §5.39 and §9.5).

// ============================================================================
//                                  LIVE RUNS
// ============================================================================

export interface AdminLiveParticipant {
    src: number;
    citizenid: string;
    name: string;
    callsign: string | null;
    departmentShort: string;
    status: 'active' | 'left' | string;
    arrived: boolean;
    // why they left (left participants only)
    endReason?: string | null;
}

export interface AdminLiveRun {
    runId: string;
    missionId: string;
    missionLabel: string;
    missionType: string;
    state: 'accepted' | 'in_progress' | string;
    tier: string | null;
    remaining: number | null;
    timerRunning: boolean;
    paused: boolean;
    timeLimit: number;
    // seconds admins added (run.timeAdded)
    timeAdded: number;
    test: boolean;
    // the admin running the test (src)
    testBy?: number | null;
    operationId: number | null;
    isBoss: boolean;
    modifier?: string | null;
    acceptedAt: number;
    startedAt?: number | null;
    unitId?: number | null;
    departments: string[];
    // the viewing admin (or one of their characters) is or was on it: the controls are refused
    own: boolean;
    participants: AdminLiveParticipant[];
}

// admin:getLiveRuns
export interface AdminLiveRunsData {
    runs: AdminLiveRun[];
    serverTime: number;
    // minutes one "+ minutes" click may add
    addMinutesMax: number;
    // seconds all additions to one run may add up to (Config.AdminControl.runTimeAddMax)
    runTimeAddMax: number;
}

// ============================================================================
//                                    UNITS
// ============================================================================

export interface AdminUnitMember {
    src: number;
    name: string;
    callsign: string | null;
    rank: string;
    departmentShort: string;
    leader: boolean;
    joinedAt?: number;
    onRun: boolean;
}

export interface AdminUnit {
    id: number;
    leader: number;
    members: AdminUnitMember[];
    invites: number;
    locked: boolean;
    readyCheck?: { typeLabel: string } | null;
    runId?: string | null;
    createdAt: number;
    // why Remove and Disband are refused now (err.live_unit_locked | live_unit_ready_check | live_unit_on_run)
    blocked?: string | null;
    // the viewing admin is in it
    own: boolean;
}

// admin:getUnits
export interface AdminUnitsData {
    units: AdminUnit[];
    serverTime: number;
}

// ============================================================================
//                    OFFICER RUN STATE (TODAY & COOLDOWNS)
// ============================================================================

export interface AdminCooldownType {
    key: string;
    label: string;
    until: number;
}

export interface AdminCooldownMission {
    id: string;
    label: string;
    until: number;
}

export interface AdminFreeAbandon {
    runUuid: string;
    missionType: string;
    typeLabel: string;
    missionLabel: string;
    at: number;
}

// The Mission Board as the officer sees it: type cards and lock reasons only, never a mission name.
export interface AdminBoardCard {
    key: string;
    label: string;
    pool: number;
    busy: boolean;
    onCall: boolean;
    typeOfTheDay: boolean;
    locked?: { reason: string; until?: number | null } | null;
}

export interface AdminBoardView {
    cards: AdminBoardCard[];
    boss?: { available: boolean; locked?: { reason: string } | null } | null;
    operation: boolean;
    serverTime: number;
    unitSize: number;
}

// admin:getOfficerRunState { citizenid }
export interface AdminOfficerRunState {
    citizenid: string;
    online: boolean;
    onRun: boolean;
    runId?: string | null;
    cooldowns: { types: AdminCooldownType[]; missions: AdminCooldownMission[] };
    clears: { used: number; max: number };
    counts: {
        today: number;
        maxDay?: number | null;
        hour: number;
        maxHour: number;
        perType: { key: string; label: string; n: number; limit?: number | null }[];
    };
    extra: { n: number; usedToday: boolean; max: number };
    cashToday: number;
    boss: { enabled: boolean; used: number; extra: number; left: number; grantedThisWeek: boolean };
    freeAbandons: AdminFreeAbandon[];
    board?: AdminBoardView | null;
    serverTime: number;
}

// ============================================================================
//                                    TODAY
// ============================================================================

export interface AdminTodayModifier {
    key: string;
    label: string;
    tacticalOnly: boolean;
    enabled: boolean;
}

// admin:getToday
export interface AdminTodayData {
    day: string;
    todEnabled: boolean;
    typeOfTheDay: string | null;
    typeLabel?: string | null;
    // the type the day's seed picks
    rolled: string | null;
    override?: { type: string; by?: string; reason?: string; at?: number } | null;
    todMultiplier: number;
    boss: { enabled: boolean; today: boolean; days: string[] };
    modifierChance: number;
    modifiers: AdminTodayModifier[];
    types: { key: string; label: string }[];
}
