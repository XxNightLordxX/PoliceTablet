// src/types/testing.ts · Admin test mode shapes (modules/testing/server.lua, docs/notes/testing.md).
// Lua sends `false` for "no value" (a Lua table cannot hold nil) and may encode an empty list as {}:
// read every list through asList().

export type TestLocationStatus = 'passed' | 'failed' | 'untested' | 'changed';
export type TestResult = 'passed' | 'failed';
export type TestInviteStatus = 'pending' | 'accepted' | 'declined' | 'expired' | 'withdrawn' | 'started';
export type TestControl = 'skip' | 'restart' | 'pause' | 'resume' | 'complete' | 'fail' | 'end' | 'teleport' | 'debug';

// ── callback admin:getTests ───────────────────────────────────────────────────

export interface TestLastResult {
  id: number;
  result: TestResult;
  tier: string;
  testers: number;
  note: string | false;
  testedBy: string;              // citizenid
  testedByName: string;
  testedAt: number;              // unix seconds
  version: number | false;       // custom missions: the version tested
  changed: boolean;              // def_hash (or version) differs from the mission now
  tests: number;                 // tests recorded for this location
}

export interface TestLocationRow {
  index: number;
  label: string;
  reserved: boolean;             // a run holds this location now
  active: boolean;               // a test run is on it now
  status: TestLocationStatus;
  last: TestLastResult | false;
}

export interface TestMissionRow {
  id: string;
  label: string;
  type: string;
  typeLabel: string;
  source: 'builtin' | 'custom';
  status: 'published' | 'archived' | 'draft';
  disabled: boolean;             // Config.DisabledMissions
  isBoss: boolean;
  version: number | false;
  minOfficers: number;
  maxOfficers: number;
  maxTier: string;               // tier maxOfficers reaches (the publishing test tier)
  defHash: string | false;
  editedInCode: boolean;
  locations: TestLocationRow[];
  summary: Record<TestLocationStatus, number>;
}

export interface TestsView {
  missions: TestMissionRow[];
  totals: { missions: number; locations: number } & Record<TestLocationStatus, number>;
  tiers: { name: string; label: string; maxParticipants: number }[];
  config: { enabled: boolean; maxTesters: number; useStartRoute: boolean; allowTeleport: boolean; debugOverlay: boolean };
  serverTime: number;
}

// ── callback test:state ───────────────────────────────────────────────────────

export interface TestLobbyInvite {
  inviteId: string;
  src: number;
  name: string;
  callsign?: string | null;
  departmentShort?: string | null;
  rank?: string | null;
  role: 'officer' | 'admin';
  status: TestInviteStatus;
  expiresIn: number;
}

export interface TestLobby {
  missionId: string | false;
  missionLabel: string | false;
  draft: boolean;
  invites: TestLobbyInvite[];
  accepted: number;
  maxTesters: number;
}

export interface TestParticipant {
  src: number;
  name: string;
  callsign: string | false;
  departmentShort: string | false;
  status: string;                // 'active' | 'left'
  arrived: boolean;
}

export interface TestActive {
  runId: string;
  missionId: string;
  missionLabel: string;
  locationIndex: number;
  locationLabel: string;
  state: 'accepted' | 'in_progress';
  tier: string;
  forcedTier: string | false;
  useStartRoute: boolean;
  draft: boolean;
  startedAt: number;
  remaining: number | false;
  paused: boolean;
  objective: false | { index: number; total: number; label: string; status: string };
  participants: TestParticipant[];
  debug: boolean;
  allowTeleport: boolean;
  debugOverlay: boolean;
}

export interface TestPendingRecord {
  key: string;
  missionId: string;
  missionLabel: string;
  locationIndex: number;
  locationLabel: string;
  tier: string;
  testers: number;
  endState: 'completed' | 'failed' | 'abandoned';
  endReason: string;
  endedBy: false | 'end' | 'fail' | 'admin_left';
  endedAt: number;
  draft: boolean;
}

/** An invitation waiting for the viewer (callback test:pendingInvites, TestState.invites, prompt). */
export interface TestInvite {
  inviteId: string;
  missionId: string;
  missionLabel: string;
  from: string;
  fromCallsign: string | false;
  expiresIn: number;
}

export interface TestState {
  lobby: TestLobby;
  active: TestActive | false;
  pending: TestPendingRecord[];
  invites: TestInvite[];
  serverTime: number;
}

// ── callback test:candidates ──────────────────────────────────────────────────

export interface TestCandidate {
  src: number;
  name: string;
  callsign: string | false;
  rank: string | false;
  departmentShort: string | false;
  role: 'officer' | 'admin';
  admin: boolean;
  onRun: boolean;
  inArena: boolean;
  invite: TestInviteStatus | false;
}

// ── action replies ────────────────────────────────────────────────────────────

export interface TestInviteResult { lobby: TestLobby; skipped: { src: number | false; error: string }[] }
export interface TestStartResult { runId: string; missionId: string; locationIndex: number; tier: string; testers: number }
export interface TestRecordResult { id: number; missionId: string; location: number; tier: string; result: TestResult; draft: boolean }

// ── push 'test' from the Lua testing client (HUD panel, debug overlay, invite prompt) ─────

export interface TestDebugData {
  runId: string;
  missionId: string;
  missionLabel: string;
  locationIndex: number;
  locationLabel: string;
  state: 'accepted' | 'in_progress';
  tier: string;
  objective: false | { index: number; total: number; label: string; block: string; status: string };
  counts: {
    entities: number; maxEntities: number; armedAlive: number; maxArmedAlive: number;
    peds: number; vehicles: number; objects: number; dead: number;
  };
  spawnPoints: number;
  waypoints: number;
  zones: number;
  startRadius: number;
  host: number | false;
  hostName: string | false;
  remaining: number | false;
  paused: boolean;
  at: number;
}

export interface TestPush {
  controls?: boolean;
  focused?: boolean;
  key?: string;                  // the bound key of +crimsonpolice_testpanel (default F9)
  debugOn?: boolean;
  allowTeleport?: boolean;       // Config.Testing.allowTeleport (the Lua client reads it)
  debugOverlay?: boolean;        // Config.Testing.debugOverlay
  runId?: string | false;
  debug?: TestDebugData | false | null;
  prompt?: false | { invites: TestInvite[] };
  state?: boolean;               // server push: the admin's test state changed (refetch test:state)
}

/** Lua may encode an empty list as {}: anything that is not an array is an empty list. */
export function asList<T>(v: T[] | Record<string, never> | null | undefined | false): T[] {
  return Array.isArray(v) ? v : [];
}

/** A Lua `false`/nil/'' becomes null. */
export function orNull<T>(v: T | false | null | undefined): T | null {
  return v === false || v === undefined || v === null || (v as unknown) === '' ? null : v;
}
