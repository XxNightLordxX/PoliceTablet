// Shapes of the builder client slice: the in-world tool overlays sent by

import type { MissionListData, MissionListEntry } from './oversight';
import type {
    BuilderClientResult,
    BuilderPlaceKind,
    BuilderPlacePayload,
    BuilderRecordPayload,
    BuilderRoute,
    BuilderTestDrivePayload,
    Vec,
    Vec3,
} from './builder_server';

// ============================================================================
//                 OVERLAYS (Lua → NUI, message type 'overlay')
// ============================================================================

// The placement tool (Lua sends it every ~150 ms while the tool runs). `reason` is translated text.
export interface PlacementOverlay {
    kind: 'placement';
    key: string;
    // display name of the points being placed (payload.label, else the key)
    label?: string;
    mode?: BuilderPlaceKind;
    placed: number;
    min: number;
    max: number;
    multiple?: boolean;
    // the spot under the aim can be placed
    valid: boolean;
    reason?: string | false;
    // degrees, false when the points carry no heading
    heading?: number | false;
    // metres (starts and areas), else false
    radius?: number | false;
}

export type RecordingWaiting = false | 'vehicle' | 'return' | 'checking';

// Route recording HUD.
export interface RecordingOverlay {
    kind: 'recording';
    key: string;
    label?: string;
    // metres (waypoint polyline, as the server measures it)
    length: number;
    // road waypoints so far
    points: number;
    // snapped samples so far
    samples: number;
    stops: number;
    maxStops: number;
    // E adds stop points (escort)
    stopsEnabled: boolean;
    paused: boolean;
    // the last sample was rejected as off road
    offRoad: boolean;
    rejected: number;
    waiting: RecordingWaiting;
    // metres back to the end of the recording (waiting 'return')
    distance: number | false;
    loop: boolean;
    // race loop: metres from the current end to the first waypoint
    toStart: number | false;
    // label of the no-build zone the current end is in
    zone: string | false;
    tooLong: boolean;
    // metres Backspace removes (Config.Builder.route.undoMetres)
    undoMetres?: number;
    minLength: number;
    maxLength: number;
    // short feedback text (translated), e.g. "Stop point 1 added"
    message: string | false;
}

export type TestDriveWaiting = false | 'approach' | 'clear' | 'spawning';

// Test drive HUD.
export interface TestDriveOverlay {
    kind: 'testdrive';
    key: string;
    label?: string;
    // waypoint the vehicle is driving to (1-based)
    waypoint: number;
    total: number;
    // waypoints not reached within testDriveTimeout
    failed: number[];
    // seconds left to reach the current waypoint
    timeLeft: number | false;
    // seconds left at an escort stop
    stopLeft: number | false;
    waiting: TestDriveWaiting;
    // metres to the route start (waiting 'approach')
    distance: number | false;
    speed?: number;
    done?: boolean;
}

export type BuilderToolOverlay = PlacementOverlay | RecordingOverlay | TestDriveOverlay;

// ============================================================================
//                          CLIENT PROTOCOL EXTENSIONS
// ============================================================================
// Optional fields; the Lua client accepts them.

export type BuilderUi = 'supervisor' | 'admin';

// builderPlace payload as the screens send it: protocol §6 plus display label, reopen UI and spacing.
export interface BuilderPlaceRequest extends BuilderPlacePayload {
    label?: string;
    ui?: BuilderUi;
    // metres between points of this key (escort ambush points: Config.Blocks.escort.ambushGap)
    minGap?: number;
    radiusMin?: number;
    radiusMax?: number;
}
export interface BuilderRecordRequest extends BuilderRecordPayload {
    label?: string;
    ui?: BuilderUi;
}
export interface BuilderTestDriveRequest extends BuilderTestDrivePayload {
    label?: string;
    ui?: BuilderUi;
}

// A result as the Lua client delivers it: `seq` (increasing) plus recording extras.
export type BuilderClientResultEx = BuilderClientResult & {
    seq?: number;
    // recording: stop points dropped because they were on the first or last waypoint
    droppedStops?: number;
};

// ============================================================================
//                                EDITOR HELPERS
// ============================================================================

export type BuilderStepKey = 'blocks' | 'details' | 'settings' | 'locations' | 'scaling' | 'test' | 'publish';

// How one location key of an objective is placed (derived from the block and its settings).
export interface PointSpec {
    // location key the objective references
    key: string;
    // objective field path that names the key (e.g. 'spawns', 'boss.spawn', 'associates.spawns')
    field: string;
    // locale key of the label
    labelKey: string;
    // placement kind; 'route' = recorded by driving
    kind: BuilderPlaceKind | 'route';
    heading: boolean;
    multiple: boolean;
    // a list of lists (flee routes): each placement adds one list
    lists?: boolean;
    min: number;
    max: number;
    // a spawn key: >= minSpawnFromStart from the start
    spawn: boolean;
    model?: string;
    minGap?: number;
    // marker: the circle drawn around the ghost (search area)
    radius?: number;
    // route: E adds stop points while recording (escort)
    stops?: boolean;
    // route: a closed race loop
    loop?: boolean;
    // route: also offer placing the points one by one (checkpoint routes)
    placeable?: boolean;
    // route: at most this many waypoints are kept (checkpoint routes: Config.Blocks.checkpoint_route.checkpoints[2])
    thinTo?: number;
    // kerb spots: each point is { coords, rule, street } (field_contact parked mode); the rule is picked per spot
    ruled?: boolean;
    // test drive vehicle, speed and style for routes
    vehicle?: string;
    speed?: number;
    style?: string;
    // objective index (1-based)
    objective: number;
}

// Client-side meta of a recorded route (not stored in the definition).
export interface RouteMeta {
    length: number;
    rejected: number;
    rejectedSamples: Vec3[];
    unreachable: number[];
    failed?: number[];
    testedAt?: number;
    completed?: boolean;
    droppedStops?: number;
    thinned?: number;
}

// The last draft test started from the builder (kept for recording its result).
export interface BuilderTestMemory {
    missionId: string;
    version: number;
    tier: string;
    location: number | 'random';
    useStartRoute: boolean;
    startedAt: number;
    recorded?: 'passed' | 'failed';
}

// ============================================================================
//                              admin:getMissions
// ============================================================================
// modules/admin: getMissionList plus the Admin UI extras.

export interface AdminMissionEntry extends MissionListEntry {
    filePath?: string | null;
    editedInCode?: boolean;
    defHash?: string | null;
    status?: string;
    // listed in Config.DisabledMissions
    disabledInConfig?: boolean;
}
export interface AdminMissionsData extends Omit<MissionListData, 'missions'> {
    missions: AdminMissionEntry[];
}

export type { BuilderRoute, Vec, Vec3 };
