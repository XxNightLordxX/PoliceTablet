// Admin UI · Real suspects (screen key 'admin_rs', step V18): what modules/opponents/staff/server.lua (V17) answers.

export type RsKind = 'live' | 'volunteer';
export type RsState = 'free' | 'cuffed' | 'detained' | 'booked' | 'lost' | 'left' | 'void';

export interface RsPerson {
    citizenid: string;
    name?: string | null;
}

export interface RsOfficer extends RsPerson {
    callsign?: string | null;
    status?: string | null;
}

// A volunteer case's part (V26, CP.Volunteers.staffView): the suspect he plays, the mode, the match phase, why he
// dropped out (a void) and whether an officer reached him. Never a server id or a position.
export interface RsVolunteerInfo {
    role: string;
    mode?: string | null;
    phase?: string | null;
    why?: string | null;
    engaged?: boolean;
}

// One volunteer on the list now (V26, CP.Volunteers.staffList); playing = the phase of the run he is asked for or
// plays.
export interface RsListedVolunteer {
    citizenid: string;
    name?: string | null;
    roles: string[];
    since: number;
    untilAt: number;
    strikes: number;
    playing?: string | null;
}

// One line of admin:getRsCases (the open cases newest first, then the kept closed ones).
export interface RsCaseLine {
    runId: string;
    kind: RsKind;
    open: boolean;
    openedAt?: number | null;
    closedAt?: number | null;
    missionId?: string | null;
    suspects: number;
    detained: number;
    booked: number;
    flags: number;
    notes: number;
    officers: RsOfficer[];
    // a volunteer case (V26): what he plays and how far the match got
    volunteer?: RsVolunteerInfo | null;
    // a case of one of the admin's own characters or accounts: it can't be opened (err.own_run)
    own?: boolean;
}

export interface RsCasesData {
    enabled: boolean;
    liveCrime: boolean;
    volunteers: boolean;
    cases: RsCaseLine[];
    // Config.AdminUi.pageSize (step H6): cases holds one page (asked for with page)
    casesPage?: { page: number; pages: number; total: number } | null;
    // the volunteers on the list now (V26; empty while volunteers are off)
    listed?: RsListedVolunteer[];
    // F2: the Volunteers tab offers Clear strikes (Config.Volunteers.staffClearStrikes)
    clearStrikes?: boolean;
    // F2: blocks, exclusions and suspensions can be lifted early (Config.RealSuspects.staffLift)
    lift?: boolean;
    serverTime: number;
}

export interface RsSuspect {
    citizenid: string;
    name?: string | null;
    label: string;
    state: RsState;
    outcome?: string | null;
    online: boolean;
    share?: number | null;
    everArmed: boolean;
    afk: boolean;
    down: boolean;
    byLeave: boolean;
    // seconds from the case's open
    contactS?: number | null;
    cuffedS?: number | null;
    detainedS?: number | null;
    bookedS?: number | null;
    jailTime?: number | null;
    notes: number;
}

// One timeline entry as text (os.time() t); flag = an officer-conduct flag, note = a suspect note.
export interface RsLine {
    t: number;
    what: string;
    label?: string | null;
    who?: RsPerson | null;
    by?: RsPerson | null;
    text: string;
    flag?: boolean;
    note?: boolean;
    kind?: string | null;
}

// One damage-ledger entry: dir 'officer' = an officer hit a suspect, 'suspect' = a suspect hit an officer.
export interface RsLedgerLine {
    t: number;
    dir: 'officer' | 'suspect';
    officer?: RsOfficer | null;
    label?: string | null;
    weapon?: number | null;
    // F2: the weapon's name (Config.RealSuspects.weaponNames), absent for a weapon not in shared/weapons.lua
    weaponName?: string | null;
    n: number;
    willKill: boolean;
    state?: RsState | null;
    down: boolean;
    rules?: string[];
}

// admin:getRsCase: the line's counts, plus the suspects (the list, in place of the count), the timeline as text, the
// flag lines and the damage ledger. No position is ever answered.
export interface RsCaseData extends Omit<RsCaseLine, 'own' | 'suspects'> {
    crimeEnded: boolean;
    suspects: RsSuspect[];
    lines: RsLine[];
    flagLines: RsLine[];
    ledger: RsLedgerLine[];
    serverTime: number;
}

export interface RsPairLine {
    officer: string;
    suspect: string;
    cases: number;
    scored: number;
    lastAt: number;
    lastOutcome?: string | null;
    kinds: string[];
}

export interface RsAdminRow {
    kind: 'block' | 'exclude' | 'suspend';
    officer?: string | null;
    suspect?: string | null;
    untilAt: number;
}

export interface RsPairsData {
    enabled: boolean;
    pairs: RsPairLine[];
    // os.time() of the oldest ledger row read at start (nil = none)
    from?: number | null;
    admin: RsAdminRow[];
    // F2: character names by citizen ID for the pairs and the running rows (Config.RealSuspects.staffNames; an empty
    // list when there are none)
    names?: Record<string, string> | unknown[] | null;
    // F2: the running rows can be lifted early (Config.RealSuspects.staffLift)
    lift?: boolean;
    serverTime: number;
    citizenid?: string;
    excludedUntil?: number | null;
    suspendedUntil?: number | null;
}

export type RsTool = 'block' | 'exclude' | 'suspend';
