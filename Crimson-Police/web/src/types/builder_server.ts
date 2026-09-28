// src/types/builder_server.ts · Mission Builder protocol shapes (docs/notes/builder_protocol.md).
// Server: modules/builder/server.lua (CP.Builder). Callbacks builder:list / builder:get / builder:config,
// actions server:builder:*, NUI push topic 'builder', client actions builderPlace / builderRecord /
// builderTestDrive / builderResult / builderCancel / builderWaypoint (modules/builder/client.lua).
//
// Units in a BuilderDefinition: seconds, metres, km/h; chances are WHOLE PERCENT (0–100) and progress
// times are SECONDS (see BuilderConfig.percentFields / secondsFields). The server converts them to
// fractions and milliseconds only when it writes the Lua file.

import type { TierName } from '../shared/types';

// ── vectors and location values ──────────────────────────────────────────────

export interface Vec3 { x: number; y: number; z: number }
/** A vec3 with a heading (degrees). */
export interface Vec4 extends Vec3 { w: number }
export type Vec = Vec3 | Vec4;

/** A road route recorded by driving it: road waypoints only. */
export interface BuilderRoute {
  points: Vec3[];
  /** escort only: waypoint index (1-based) and seconds the vehicle waits there */
  stops?: { at: number; wait: number }[];
  /** a race loop (ends within Config.Builder.route.loopClose of its start) */
  loop?: boolean;
}

export interface BuilderStart { coords: Vec3; radius: number }

/** A named placement: a point, a list of points, labelled points, lists of point lists (flee routes) or a road route. */
export type BuilderLocationValue =
  | Vec
  | Vec[]
  | { coords: Vec3; heading?: number; label?: string }[]
  | Vec3[][]
  | BuilderRoute;

export interface BuilderLocation {
  label: string;
  /** missing until the start point is placed */
  start?: BuilderStart;
  [key: string]: BuilderLocationValue | BuilderStart | string | undefined;
}

// ── the draft definition ─────────────────────────────────────────────────────

/** One objective: the block's own fields (ARCHITECTURE §3.3) in builder units. */
export interface BuilderObjective {
  block: string;
  label: string;
  minSeconds: number;
  presenceRange: number;
  [field: string]: unknown;
}

/** A standard bonus or penalty (Config.Bonuses): `points` for flat kinds (penalties negative), `pct` (whole %) for pct kinds. */
export interface BuilderBonusEntry { id: string; points?: number; pct?: number }

export interface BuilderScalingEntryObject { path: string; max: number }
export type BuilderScalingEntry = string | BuilderScalingEntryObject;

export interface BuilderDefinition {
  id: string;
  label: string;
  description: string;
  type: string;
  departments: string[];
  minOfficers: number;
  maxOfficers: number;
  difficulty: number;
  timeLimit: number;
  startTimeout: number;
  cooldown: number;
  vehiclePenalties: boolean;
  locations: BuilderLocation[];
  objectives: BuilderObjective[];
  scaling: BuilderScalingEntry[];
  items: { name: string; count: number }[];
  bonuses: BuilderBonusEntry[];
  penalties: BuilderBonusEntry[];
}

/** One guardrail problem. `message` is translated; `key`/`vars` are set when the text is a builder.error.* key. */
export interface BuilderError {
  path: string;
  message: string;
  key?: string;
  vars?: Record<string, string | number>;
}

// ── builder:list / builder:get ───────────────────────────────────────────────

export type BuilderLifecycle = 'draft' | 'tested' | 'published' | 'archived';
export type BuilderDbStatus = 'draft' | 'published' | 'archived';

export interface BuilderLock { citizenid: string; name: string | null; secondsLeft: number; mine: boolean }
export interface BuilderPerson { citizenid: string; name: string | null }

export interface BuilderCan {
  edit: boolean; publish: boolean; archive: boolean; restore: boolean;
  rollback: boolean; breakLock: boolean; discard: boolean;
}

export interface BuilderListEntry {
  id: string;
  label: string;
  type: string;
  source: 'custom';
  status: BuilderLifecycle;
  dbStatus: BuilderDbStatus;
  /** published_version */
  version: number | null;
  draftVersion: number | null;
  hasDraft: boolean;
  draftTested: boolean;
  editedInCode: boolean;
  filePath: string | null;
  owner: BuilderPerson & { mine: boolean };
  updatedBy: BuilderPerson;
  /** os.time() seconds */
  updatedAt: number;
  lock: BuilderLock | null;
  /** tier the publishing test needs (CP.Scaling.tierFor(maxOfficers)) */
  requiredTier: TierName | string | null;
  can: BuilderCan;
}

export interface BuilderBuiltinEntry { id: string; label: string; type: string; source: 'builtin'; readOnly: true }

export interface BuilderList {
  missions: BuilderListEntry[];
  builtins: BuilderBuiltinEntry[];
  me: string | null;
  serverTime: number;
}

/** builder:get { id } — a custom mission, or a built-in (source 'builtin', read-only, nulls elsewhere). */
export interface BuilderRecord extends Omit<BuilderListEntry, 'source' | 'owner' | 'updatedBy'> {
  source: 'custom' | 'builtin';
  owner: (BuilderPerson & { mine: boolean }) | null;
  updatedBy: BuilderPerson | null;
  /** the draft, or a copy of the published version when there is no draft */
  definition: BuilderDefinition;
  publishedDefinition: BuilderDefinition | null;
  readOnly: boolean;
  errors: BuilderError[];
  /** armed NPCs before scaling, all blocks */
  armed: number;
  /** versions with a <id>.v<n>.lua.bak (rollback targets), newest first */
  backups: number[];
  publishedAt: number | null;
  publishedBy: string | null;
}

// ── builder:config ───────────────────────────────────────────────────────────

/** [min, max, default] or [min, max] */
export type BuilderRange = [number, number, number] | [number, number];

export interface BuilderBonusOption {
  id: string;
  kind: 'points' | 'pct';
  /** points, or whole percent of P */
  value: number;
  each: boolean;
  block: string | null;
  penalty: boolean;
  /** 'bonus.<id>' or 'penalty.<id>' */
  labelKey: string;
}

export interface BuilderBlockOption {
  id: string;
  /** 'builder.block.<id>' */
  labelKey: string;
  /** registered on the server (only available blocks can be used) */
  available: boolean;
  minSeconds: number;
  presenceRange: BuilderRange | null;
}

export interface BuilderRouteConfig {
  snapEvery: number; maxOffRoad: number; turnAngle: number; maxGap: number;
  minLength: number; maxLength: number; minStartEndGap: number; loopClose: number;
  undoMetres: number; testDriveTimeout: number;
}

export interface BuilderConfig {
  enabled: boolean;
  /** Config.Blocks verbatim (details + one entry per block: ranges { min, max, default } as arrays, options, defaults) */
  blocks: Record<string, Record<string, unknown>>;
  blockList: BuilderBlockOption[];
  allowed: { weapons: string[]; peds: string[]; vehicles: string[]; escortVehicles: string[]; animations: string[] };
  maxHostiles: number;
  maxBlocks: number;
  minLocations: number;
  maxLocations: number;
  minLocationGap: number;
  minSpawnFromStart: number;
  /** flat points cap, and the percentage cap in whole percent */
  bonusCap: { points: number; pct: number };
  bonuses: BuilderBonusOption[];
  noBuildZones: { label: string; coords: Vec3; radius: number }[];
  departments: { key: string; label: string; short: string }[];
  missionTypes: { key: string; label: string; points: number }[];
  tiers: { name: string; labelKey: string; maxParticipants: number }[];
  autosaveSeconds: number;
  editLockMinutes: number;
  testAtMaxTier: boolean;
  keepBackups: boolean;
  exportPath: string;
  route: BuilderRouteConfig;
  startRadius: [number, number, number];
  maxItems: number;
  itemCount: [number, number];
  maxScaling: number;
  limits: { label: number; description: number; objectiveLabel: number; locationLabel: number };
  /** block id -> dotted field paths ('*' = every list entry) that are whole percent in the builder */
  percentFields: Record<string, string[]>;
  /** block id -> field paths that are seconds in the builder (milliseconds in the file) */
  secondsFields: Record<string, string[]>;
  /** block id -> objective fields naming NPC/vehicle spawn-point location keys */
  spawnFields: Record<string, string[]>;
  forbiddenItems: string[];
  useStartRoute: boolean;
  /** the caller's builder permissions (admins: all true) */
  permissions: Record<'builderEdit' | 'builderEditAny' | 'builderPublish' | 'builderArchive' | 'builderRollback' | 'breakEditLock', boolean>;
}

// ── action payloads and results (server:builder:*) ───────────────────────────

export interface BuilderIdPayload { id: string }
export interface BuilderCreatePayload { type: string; label?: string }
export interface BuilderSavePayload { id: string; definition: BuilderDefinition }
export interface BuilderValidatePayload { id: string; definition?: BuilderDefinition }
export interface BuilderTestPayload { id: string; tier?: string; location?: number | 'random'; useStartRoute?: boolean }

export interface BuilderCreateResult { id: string; record: BuilderRecord }
export interface BuilderLockResult { id: string; lock: BuilderLock | null }
export interface BuilderSaveResult {
  id: string;
  /** set when saving renamed an unpublished draft (the label's slug changed) */
  previousId?: string | null;
  version: number;
  savedAt: number;
  valid: boolean;
  errors: BuilderError[];
  draftTested: boolean;
  lock: BuilderLock | null;
}
export interface BuilderAutosaveResult { id: string; version: number; savedAt: number; draftTested: boolean; lock: BuilderLock | null }
export interface BuilderValidateResult { valid: boolean; errors: BuilderError[]; armed: number; maxHostiles: number; requiredTier: string | null }
export interface BuilderTestResult { id: string; version: number; tier: string; location: number | 'random'; requiredTier: string }
export interface BuilderPublishResult { id: string; version: number; filePath: string; backup: string | null }
export interface BuilderFileResult { id: string; filePath: string }
export interface BuilderRollbackResult { id: string; version: number; fromVersion: number }
export interface BuilderBreakLockResult { id: string; previous: BuilderPerson | null }
export interface BuilderDiscardResult { id: string; deleted: boolean }

/** Every server:builder:* action name. */
export type BuilderActionName =
  | 'server:builder:create' | 'server:builder:duplicate' | 'server:builder:lock' | 'server:builder:unlock'
  | 'server:builder:save' | 'server:builder:autosave' | 'server:builder:validate' | 'server:builder:test'
  | 'server:builder:publish' | 'server:builder:archive' | 'server:builder:restore' | 'server:builder:rollback'
  | 'server:builder:breakLock' | 'server:builder:discardDraft';

// ── live updates ─────────────────────────────────────────────────────────────

export type BuilderPushEvent =
  | 'changed' | 'published' | 'archived' | 'restored' | 'rolledBack' | 'tested'
  | 'lockBroken' | 'reloaded' | 'deleted' | 'clientResult';

/** NUI push topic 'builder'. `result` is set for event 'clientResult' (sent by the builder client). */
export interface BuilderPush {
  event: BuilderPushEvent;
  id?: string;
  previousId?: string | null;
  by?: string | null;
  result?: BuilderClientResult;
}

// ── client protocol (builder client ↔ builder UI) ────────────────────────────

export type BuilderPlaceKind = 'ped' | 'vehicle' | 'marker' | 'area' | 'start';

export interface BuilderPlacePayload {
  missionId: string;
  /** 1-based location index */
  location: number;
  key: string;
  kind: BuilderPlaceKind;
  model?: string;
  /** vec4 with heading (peds, vehicles) or vec3 */
  heading: boolean;
  multiple: boolean;
  min?: number;
  max?: number;
  radius?: number;
  points: Vec[];
  start: Vec3 | null;
  /** a spawn key: points must be >= minSpawnFromStart from `start` */
  spawn: boolean;
  /** other locations' starts (kind 'start': >= minLocationGap from each) */
  otherStarts: Vec3[];
}
export interface BuilderRecordPayload { missionId: string; location: number; key: string; stops: boolean; loop: boolean }
export interface BuilderTestDrivePayload {
  missionId: string; location: number; key: string; route: BuilderRoute; vehicle: string; speed: number; style: string;
}

export type BuilderClientResult =
  | { kind: 'placement'; missionId: string; location: number; key: string; points: Vec[]; radius?: number; cancelled: boolean }
  | { kind: 'recording'; missionId: string; location: number; key: string; cancelled: boolean; route: BuilderRoute;
      /** metres */ length: number;
      /** samples dropped as "Off road" */ rejected: number;
      rejectedSamples: Vec3[];
      /** waypoint indexes with no road path to the next one */ unreachable: number[] }
  | { kind: 'testdrive'; missionId: string; location: number; key: string; completed: boolean; failed: number[]; cancelled: boolean };

/** Immediate reply of builderPlace / builderRecord / builderTestDrive (the result arrives later). */
export interface BuilderStarted { started: true }
