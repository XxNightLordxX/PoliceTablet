// Shapes of the Dispatch screen (mission calls): getMissionCalls and push topic 'calls', the supervisor panel and
// the admin area coverage matrix.

export interface MissionCall {
    id: number;
    code: string;
    type: string;
    typeLabel: string;
    titleKey: string;
    priority: 1 | 2 | 3;
    // per viewer; null = county-wide for this viewer
    area: { key: string; label: string } | null;
    distance: number | null;
    ageS: number;
    offerEndsIn: number;
    // paged or created by staff (never earns rapid response)
    staff: boolean;
    crew: 'solo' | 'unit' | 'none';
    minUnit: number | null;
    cash: [number, number];
    points: number;
    rapidPoints: number;
    typeOfTheDay: boolean;
    redispatched: boolean;
    paged: boolean;
    status: 'ready' | 'priority' | 'locked' | 'claiming' | 'claimed' | 'lapsed' | 'withdrawn';
    priorityEndsIn: number | null;
    locked: null | { reason: string; until?: number };
    claimedBy: null | { callsign: string | null; departmentShort: string };
    // the winning unit's ready check
    claiming: null | { callsign: string | null; expiresIn: number };
    // why this viewer's claim lost the window
    lostBy: null | 'distance' | 'recent' | 'first';
}

export interface RecentCall {
    code: string;
    typeLabel: string;
    claimedBy: string | null;
    outcome: string | null;
    at: number;
}

export interface DispatchView {
    calls: MissionCall[];
    unit: { size: number; isLeader: boolean };
    activeRunId: string | null;
    operation: null | { missionLabel: string };
    onCall: boolean;
    realCalls: null | { total: number; p1: number };
    serverTime: number;
    recent: RecentCall[];
}

// A unit a supervisor may page (idle leaders and solo officers, never the viewer's own unit).
export interface PageableUnit {
    src: number;
    name: string;
    callsign: string | null;
    departmentShort: string;
    size: number;
}

export interface SupCallsView {
    open: MissionCall[];
    units?: PageableUnit[];
    today: {
        code: string;
        type: string;
        area: string | null;
        status: string;
        claimedBy: string | null;
        claimants: number;
        claimS: number | null;
        responseS: number | null;
        outcome: string | null;
    }[];
}

export interface AreaCoverage {
    types: string[];
    areas: { key: string; label: string }[];
    cells: Record<string, Record<string, { missions: number; locations: number }>>;
}

// server:claimMissionCall: the run when the claim won, or pending while the unit answers its ready check.
export interface ClaimCallResult {
    runId?: string;
    pending?: boolean;
    code?: string;
}

// The Mission Board's extra field: the mission calls this viewer's unit could claim right now.
export interface BoardCallsInfo {
    callsOpen?: number;
}

// admin:getLocationStats: how often each location of a mission was played.
export interface LocationPlay {
    index: number;
    label: string;
    plays: number;
    lastPlayed: number | null;
    area: string | null;
}
