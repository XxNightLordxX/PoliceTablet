// Response shapes of the teams slice (modules/units, modules/operations; documented in docs/notes/teams.md). UnitView
// and BoardData.operation are contract shapes (src/shared/types.ts); the types below add the optional fields the
// server sends on top of them.

import type { UnitView } from '../shared/types';

// ============================================================================
//                                   getUnit
// ============================================================================

type BaseUnit = NonNullable<UnitView['unit']>;

// A unit member (UnitView member + `available`: false when that member can no longer take missions).
export type UnitMemberView = BaseUnit['members'][number] & { available?: boolean };

// An invite the viewer's unit sent that is still open.
export interface UnitPendingInvite {
    src: number;
    name: string;
    callsign: string | null;
    departmentShort: string;
    // Seconds until the invite expires (invites stay open 120 s).
    expiresIn: number;
}

export type UnitInfoView = Omit<BaseUnit, 'members'> & {
    members: UnitMemberView[];
    // Number of members.
    size?: number;
    pending?: UnitPendingInvite[];
};

// An invite waiting for the viewer (+ `size`: members already in that unit).
export type UnitInviteView = UnitView['invites'][number] & { size?: number };

// An officer the viewer may invite (+ `inUnit`: already in another unit that is not full).
export type UnitInvitableView = UnitView['invitable'][number] & { inUnit?: boolean };

// Callback 'getUnit' (UnitView §9.4 plus the slice fields).
export interface UnitScreenView {
    unit: UnitInfoView | null;
    invites: UnitInviteView[];
    invitable: UnitInvitableView[];
    // The viewer's server id (to mark "You").
    me?: number;
    // Config.Limits.maxUnitSize.
    maxSize?: number;
    // The viewer may send invites now (the invitable list is empty otherwise).
    canInvite?: boolean;
    // Locale key explaining why invites are closed (unit.blocked_*).
    inviteBlocked?: string | null;
    // The viewer is on a run.
    onRun?: boolean;
    // Seconds an invite stays open (120).
    inviteTtl?: number;
}

// Reply of server:unitLeave.
export interface UnitLeaveResult {
    left: boolean;
    abandoned: boolean;
}

// ============================================================================
//                               sup:getOperation
// ============================================================================

export type OperationStatus = 'joining' | 'running' | 'waiting';
export type OperationWaitingReason = 'failed' | 'abandoned' | 'not_enough' | 'no_location' | 'start_failed';

export interface OperationParticipant {
    src: number;
    name: string;
    callsign: string | null;
    departmentShort: string;
    department?: string;
    // joined (join window) · active / left (on the run) · waiting (last joiners of a failed attempt).
    status: 'joined' | 'active' | 'left' | 'waiting';
    arrived: boolean;
}

export interface OperationInfo {
    id: number;
    missionId: string;
    missionLabel: string;
    missionType: string;
    missionTypeLabel: string;
    difficulty: number;
    launcher: string;
    launcherCallsign?: string | null;
    launcherDepartment?: string | null;
    // Unix seconds of the launch.
    launchedAt: number;
    status: OperationStatus;
    // State of the operation's run while it exists.
    runState?: 'accepted' | 'in_progress' | null;
    runId?: string | null;
    participants: OperationParticipant[];
    // Participants still in, per department tag (sorted by tag).
    departments: { short: string; count: number }[];
    joined: number;
    max: number;
    min: number;
    // Seconds until joining closes (joining only).
    joinEndsIn?: number | null;
    // Seconds until the idle auto-cancel (waiting only).
    idleCancelIn?: number | null;
    // Tier name (expected until the run is In progress).
    tier: string;
    tierExpected: boolean;
    // Seconds left on the run timer (running only).
    remaining?: number | null;
    waitingReason?: OperationWaitingReason | null;
    // 1 for the first join window, +1 per relaunch.
    attempt: number;
    canStart: boolean;
    // Locale key (sup.crossdept.start_blocked_*) when joining but Start now is not possible.
    startBlocked?: string | null;
    canRelaunch: boolean;
    canCancel: boolean;
}

export interface EligibleMission {
    id: string;
    label: string;
    type: string;
    typeLabel: string;
    difficulty: number;
    // Participants needed to start (max of Config.CrossDept.minParticipants and the mission's minOfficers).
    minOfficers: number;
    // Config.CrossDept.maxParticipants.
    maxOfficers: number;
}

// Callback 'sup:getOperation' (also used by the Admin UI's Missions screen through OperationPanel).
export interface OperationView {
    operation: OperationInfo | null;
    // Seconds until a new launch is allowed (Config.CrossDept.cooldown after the last launch).
    cooldownLeft: number;
    // Config.CrossDept.cooldown, joinWindow and idleCancel (seconds), maxParticipants.
    cooldown: number;
    joinWindow?: number;
    idleCancel?: number;
    maxParticipants?: number;
    // Config.CrossDepartmentPoints (points multiplier with 2+ departments).
    crossBonus?: number;
    enabled: boolean;
    canLaunch: boolean;
    // err.* key explaining why a launch is not possible now.
    launchBlocked?: string | null;
    // Launchable missions (only while no operation is active).
    eligibleMissions?: EligibleMission[];
    serverTime: number;
}

// Scope of the OperationPanel: which action family it calls (server:sup:op* or server:admin:op*).
export type OperationScope = 'sup' | 'admin';
