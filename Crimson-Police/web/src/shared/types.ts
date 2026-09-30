// Every NUI data shape (docs/ARCHITECTURE.md §9.2–§9.6, verbatim) plus the UI-side helper types. Screen code imports
// its shapes from here; never redeclare them locally. If a module owner adds a field on the Lua side, add it here
// (optional) rather than casting.

import type { DebriefPerson, DecisionEntry, RunItem, RunMissionCall, RunProgress, RunStats } from '../types/run_ui';

// ============================================================================
//                                 §9.2 SESSION
// ============================================================================

// The XP level (Config.XPCurve): n is the number, label and badge the Config.XPLevels band it falls in, xp the
// officer's XP, levelXp and nextLevelXp where level n and the next level (or prestige star) start.
export interface LevelInfo {
    n: number;
    label: string;
    badge: string;
    xp: number;
    levelXp: number;
    nextLevelXp: number | null;
    prestige: number;
}
// What everyone sees as an officer's picture. frame = the XP level badge colour.
export interface Avatar {
    kind: 'initials' | 'preset' | 'url';
    value: string | null;
    initials: string;
    frame: string;
}
// The officer's own look (cp_officers), applied to their own tablet only.
export interface Prefs {
    appearance: string;
    accent: string | null;
    uiScale: number;
    callsMuted: boolean;
}

export interface Theme {
    primary: string;
    accent: string;
    background: string;
    surface: string;
    text: string;
}
export interface Logo {
    url: string;
    watermark: boolean;
    opacity: number;
    size: number;
    grayscale: boolean;
}
export interface Session {
    ui: 'officer' | 'supervisor' | 'admin';
    title: string; // 'Crimson-Police'
    roles: { officer: boolean; supervisor: boolean; admin: boolean };
    officer: null | {
        citizenid: string;
        name: string;
        department: string;
        departmentLabel: string;
        departmentShort: string;
        rank: string;
        callsign: string | null;
        gradeLevel: number;
        avatar?: Avatar;
        level?: LevelInfo;
    };
    theme: Theme; // department theme, or Config.AdminTheme for admin
    logo: Logo | null; // null for admin
    actions: string[]; // CP.Permissions.actionsFor
    locale: Record<string, string>; // CP.Locale.all()
    config: {
        missionTypes: { key: string; label: string; points: number }[];
        departments: { key: string; label: string; short: string; primary: string }[];
        tiers: { name: string; label: string }[];
        maxRecalcs: number;
        disputeWindowHours: number;
        periods: string[];
        filters: string[];
        // parity-plus config values (modules/tablet getSession)
        dispatch?: { enabled: boolean; areas: { key: string; label: string }[] };
        leaderboardMetrics?: string[];
        profile?: {
            bioMax: number;
            bioLines: number;
            presets: { id: string; level: number | null }[];
            urls: boolean;
            appearances: string[];
            accents: { colour: string; level: number | null }[];
            uiScale: [number, number, number];
        };
        commendationKinds?: string[];
        rewards?: { enabled: boolean };
        format?: { currency: string; currencyAfter: boolean };
    };
    prefs?: Prefs;
    // how the tablet was opened: command, keybind, item, export, desk or dispatch (desk = its index)
    access?: { via: string; desk: number | null };
    serverTime: number; // os.time() at session build
}

// ============================================================================
//                                   §9.3 HUD
// ============================================================================

export interface HudState {
    runId: string;
    test: boolean;
    missionLabel: string;
    phase: 'route' | 'objectives' | 'ended';
    tier: string;
    payTier: string; // tier names
    modifier: null | { key: string; label: string };
    // seconds; the NUI counts down locally. receivedAt (Date.now()) is set by the NUI when the value arrives.
    timer: null | { remaining: number; paused: boolean; receivedAt?: number };
    route: null | {
        status: 'on' | 'off' | 'arrived' | 'disabled';
        secondsLeft: number | null;
        distance: number | null;
        receivedAt?: number;
    };
    objectives: { label: string; done: boolean; current: boolean; detail?: string; value?: number; max?: number }[];
    detail: string | null; // client-side line for the current objective
    message: null | { text: string; kind: 'info' | 'success' | 'warning' | 'error' };
    testControls: boolean; // the admin who started the test
}

// ============================================================================
//                     §9.4 OFFICER SCREEN DATA (callbacks)
// ============================================================================

// getMissionTypes
export interface BoardCard {
    key: string;
    label: string;
    points: number;
    cash: [number, number];
    pool: number;
    mode: 'solo' | 'unit';
    locked: null | { reason: string; until?: number };
    busy: boolean;
    onCall: boolean;
    typeOfTheDay: boolean;
}
export interface BoardData {
    cards: BoardCard[];
    boss: null | (BoardCard & { available: boolean });
    operation: null | {
        id: number;
        missionLabel: string;
        launcher: string;
        status: string;
        joined: number;
        max: number;
        joinedByMe: boolean;
        canJoin: boolean;
        joinEndsIn: number | null;
    };
    unit: { size: number; isLeader: boolean };
    activeRunId: string | null;
}
// getUnit
export interface UnitView {
    unit: null | {
        id: number;
        leader: number;
        locked: boolean;
        members: {
            src: number;
            name: string;
            callsign: string | null;
            rank: string;
            departmentShort: string;
            isLeader: boolean;
        }[];
    };
    invites: {
        unitId: number;
        from: string;
        fromCallsign: string | null;
        departmentShort: string;
        expiresIn: number;
    }[];
    invitable: { src: number; name: string; callsign: string | null; rank: string; departmentShort: string }[];
}
// getRun (and push topic 'run')
export interface ActiveMissionView {
    runId: string;
    missionLabel: string;
    description: string;
    missionType: string;
    state: 'accepted' | 'in_progress';
    tier: string;
    tierExpected: boolean;
    payTier: string;
    route: HudState['route'];
    objectives: HudState['objectives'];
    remaining: number | null;
    paused: boolean;
    partners: {
        src: number;
        name: string;
        callsign: string | null;
        departmentShort: string;
        status: string;
        arrived: boolean;
    }[];
    expected: { cash: number; points: number };
    modifier: HudState['modifier'];
    test: boolean;
    recalcsLeft: number;
    radioSilence: boolean;
    log: null | { point: number; choices: { id: string; label: string }[] };
}
// getHome
export interface HomeData {
    card: {
        callsign: string | null;
        rank: string;
        departmentShort: string;
        name: string;
        xp: number;
        level: { label: string; badge: string; xp: number; next: number | null };
        streak: { days: number; graceLeft: boolean };
        seasonPoints: number;
        cashThisWeek: number;
    };
    goals: { daily: Goal | null; weekly: Goal | null };
    typeOfTheDay: null | { key: string; label: string };
    announcements: { kind: string; text: string }[];
    champions: null | { season: string; department: string };
}
export interface Goal {
    id: string;
    label: string;
    count: number;
    progress: number;
    done: boolean;
    points: number;
}
// getBoard({ period: 'weekly'|'monthly'|'season'|'alltime', filter: 'overall'|'patrol'|'training'|'investigation'|'tactical'|'unit'|'cross'|'department', department?: string })
export interface BoardRow {
    rank: number;
    citizenid: string;
    name: string;
    callsign: string | null;
    departmentShort: string;
    points: number;
    runs: number;
    failed: number;
}
export interface Board {
    period: string;
    filter: string;
    rows: BoardRow[];
    me: BoardRow | null;
    updatedAt: number;
}
// getChallenge
export interface ChallengeView {
    season: null | { id: number; name: string; weeksLeft: number };
    departments: { key: string; label: string; short: string; colour: string; score: number; activeOfficers: number }[];
    bounty: null | { id: string; label: string; leader: string | null };
    topContributors: { name: string; callsign: string | null; points: number }[];
}
// getProfile(citizenid?)
export interface Profile {
    citizenid: string;
    name: string;
    callsign: string | null;
    rank: string;
    departmentShort: string;
    xp: number;
    level: HomeData['card']['level'];
    badges: { id: string; label: string; earnedAt: string }[];
    hideName: boolean;
    own: boolean;
    runs: {
        id: number;
        missionLabel: string;
        missionType: string;
        state: string;
        endReason: string;
        points: number;
        cash: number;
        cashStatus: string;
        flagged: boolean;
        voided: boolean;
        createdAt: string;
        breakdown: RunResult | null;
        canDispute: boolean;
    }[];
}

// ============================================================================
//                        §9.5 SUPERVISOR / ADMIN SHAPES
// ============================================================================

export interface LiveRun {
    runId: string;
    missionType: string;
    missionLabel: string;
    tier: string;
    state: string;
    remaining: number | null;
    test: boolean;
    operationId: number | null;
    participants: { src: number; name: string; callsign: string | null; departmentShort: string; status: string }[];
}

// ============================================================================
//                                §9.6 RunResult
// ============================================================================
// client:runEnded, result screen, Profile breakdown.

export interface RunResult {
    runId: string;
    missionLabel: string;
    missionType: string;
    result: 'completed' | 'failed' | 'abandoned';
    endReason: string;
    test: boolean;
    tier: string;
    payTier: string;
    participants: number;
    departments: number;
    durationS: number;
    points: {
        P: number;
        bonuses: { id: string; label: string; points: number }[];
        penalties: { id: string; label: string; points: number }[];
        subtotal: number;
        mTeam: number;
        mCross: number;
        mStreak: number;
        capped: boolean;
        tod: boolean;
        failedShare: number | null;
        final: number;
        // Extras of a completed result (CP.Scoring.compute; older rows lack them): the points cap in whole
        // points (Config.Scoring.scoreCap × P), Config.Scoring.scoreCap and Config.Events.todMultiplier.
        cap?: number;
        scoreCap?: number;
        todMultiplier?: number;
    };
    cash: { B: number; mTier: number; mMod: number; amount: number; status: string };
    flagged: null | { reason: string };
    // parity-plus sections (each shown only when present; older rows lack them)
    decisions?: DecisionEntry[];
    people?: DebriefPerson[] | null;
    progress?: RunProgress | null;
    stats?: RunStats;
    missionCall?: RunMissionCall | null;
    items?: RunItem[];
}

// Sidebar badge counts (push topic 'nav').
export interface NavCounts {
    invites: number;
    calls: number;
    review: number;
    commendations: number;
    rewards: number;
    onRun: boolean;
}
// A line of Admin UI → Permissions → Config health.
export interface ConfigHealthItem {
    check: string;
    level: 'ok' | 'warn' | 'error';
    text: string;
}

// ============================================================================
//                UI-side HELPER TYPES (not in the Lua contract)
// ============================================================================

// Which UI is open.
export type UiKind = Session['ui'];

// Every reply from the NUI bridge (request, action, client, switchUi). `error` is an `err.*` locale key.
export interface ApiResult<T = unknown> {
    ok: boolean;
    data?: T;
    error?: string;
}

export type NotificationKind = 'info' | 'success' | 'warning' | 'error';

// A Crimson-Police toast (`notify` message; text and title are already translated by Lua).
export interface Notification {
    id: string | number;
    kind: NotificationKind;
    title?: string;
    text: string;
    duration: number; // ms; 0 or less = stays until dismissed
}

export type OverlayKind = 'placement' | 'recording' | 'testdrive' | 'fade';

// `overlay` message payload. 'fade' carries { text }; builder kinds carry builder-specific fields.
export interface Overlay {
    kind: OverlayKind;
    text?: string;
    [key: string]: unknown;
}

// Push topics the server sends (`push` message).
export type PushTopic =
    | 'run'
    | 'unit'
    | 'board'
    | 'operation'
    | 'invites'
    | 'test'
    | 'builder'
    | 'payouts'
    | 'calls'
    | 'nav'
    | 'profile'
    | 'rewards';

export type HudObjective = HudState['objectives'][number];
export type HudRoute = NonNullable<HudState['route']>;
export type OfficerInfo = NonNullable<Session['officer']>;
export type TierName = 'standard' | 'reinforced' | 'heavy' | 'major' | 'critical';
export type XpBadgeColour = 'grey' | 'bronze' | 'silver' | 'gold' | 'platinum';
export type ProfileRun = Profile['runs'][number];

// Every message Lua sends to the NUI (ARCHITECTURE §9.1), keyed by `type`.
export interface NuiMessageMap {
    // `screen` (optional) opens that screen key, e.g. 'active' right after accepting a type.
    // `seq` (optional): the NUI confirms it shows this UI with the 'opened' endpoint ({ seq }).
    open: { type: 'open'; ui: UiKind; session: Session; screen?: string; seq?: number };
    close: { type: 'close' };
    session: { type: 'session'; session: Session };
    notify: { type: 'notify'; notification: Notification };
    hud: { type: 'hud'; hud: HudState | null };
    result: { type: 'result'; result: RunResult | null };
    push: { type: 'push'; topic: PushTopic | string; data: unknown };
    overlay: { type: 'overlay'; overlay: Overlay | null };
    // Sent at login with the officer's department theme so the HUD can use it (locale optional).
    theme: { type: 'theme'; theme: Theme | null; locale?: Record<string, string> };
}
export type NuiMessageType = keyof NuiMessageMap;
export type NuiMessage = NuiMessageMap[NuiMessageType];

// NUI → Lua endpoints (POST https://<resource>/<endpoint>).
export type NuiEndpoint = 'ready' | 'opened' | 'close' | 'request' | 'action' | 'client' | 'switchUi';
