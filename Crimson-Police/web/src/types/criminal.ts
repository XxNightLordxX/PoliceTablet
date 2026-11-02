// The criminal tablet (step G2, modules/crimtab): what crimtab:get and server:crimtab:act answer. Never a run, an
// officer or a live position: only the player's own listing, his open question, the suspect he plays and his past.

export type CrimRole = 'runner' | 'driver' | 'fugitive';
export type CrimScreen = 'home' | 'jobs' | 'active' | 'history' | 'rules';

export interface CrimStatus {
    listed: boolean;
    untilAt?: number | null; // os.time() the window ends
    roles: CrimRole[]; // the suspects he plays (listed) or nothing
    allRoles: CrimRole[];
    canJoin: boolean;
    why?: string | null; // a volunteer refusal reason when he can't join now
    blockedUntil?: number | null; // os.time() a strikes block ends
}

// The question he has open now (Accept / Decline is the same answer as the pop-up).
export interface CrimJob {
    token: string;
    role: CrimRole;
    missionType?: string | null;
    area?: string | null;
    km?: number | null;
    seconds: number; // left to answer
    travelMinutes: number;
    reward?: string | null; // what Pay volunteer suspects pays (server text), null while it is off
}

export interface CrimActive {
    phase: 'travel' | 'in_position' | 'engaged';
    role: CrimRole;
    meet?: { x: number; y: number; z: number } | null;
    seconds?: number | null; // left to reach the meet point while travelling
    freeCancel: boolean;
    graceSeconds: number;
    graceLeft?: number | null; // seconds the free Give up still lasts (0 once it is a strike)
}

export interface CrimHistoryRow {
    endedAt: number;
    missionType?: string | null;
    role?: CrimRole | string | null;
    outcome?: string | null; // detained | booked | got_away | left | void | stopped
    dropout?: string | null; // no_show | cancelled | left | afk | out_of_bounds | on_duty | early_respawn
    result?: string | null;
}

export interface CrimRules {
    windowMinutes: number;
    strikes: number;
    strikeHours: number;
    blockHours: number;
    askSeconds: number;
    travelMinutes: number;
    cancelGraceSeconds: number;
}

export interface CrimView {
    now: number;
    volunteersOn: boolean;
    name?: string | null;
    status: CrimStatus;
    jobs: CrimJob[];
    active?: CrimActive | null;
    history: CrimHistoryRow[];
    strikes: number[]; // os.time() each strike runs out
    rules: CrimRules;
}
