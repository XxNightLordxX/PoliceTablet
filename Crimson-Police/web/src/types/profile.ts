// Shapes of the officer profile: commendations, the Edit profile dialog and the supervisors' Profiles queue.

import type { Avatar, LevelInfo, Prefs } from '../shared/types';
import type { ProfileData } from './boards';

export interface Commendation {
    id: number;
    kind: string;
    citation: string;
    by: string;
    byRank: string | null;
    at: number;
    runUuid: string | null;
    revoked: boolean;
    // sup:getOfficerActivity: the viewer issued it (and may revoke it)
    mine?: boolean;
    // admin:getOfficerProfile only
    issuedBy?: string;
    revokeReason?: string | null;
}

// getProfileEdit
export interface ProfileEdit {
    bio: string | null;
    // a new bio waiting for approval (Config.Profile.bioRequiresApproval)
    bioPending?: string | null;
    avatar: Avatar;
    pending: null | { value: string; status: string };
    prefs: Prefs;
    urlsLeftToday: number;
    nextEditIn: number;
    level: LevelInfo;
}

// sup:getProfileQueue (pictures, bios and reports)
export interface ProfileQueueItem {
    kind: 'avatar' | 'bio' | 'report';
    id: number | null;
    citizenid: string;
    name: string;
    callsign: string | null;
    departmentShort: string;
    url: string | null;
    text: string | null;
    reason: string | null;
    submittedAt: number;
    // reports: the reporter's note; bios: the bio everyone sees now
    note?: string | null;
    current?: string | null;
    // reports, admins only: who filed it and how many reports they filed in the last 30 days
    reporter?: { citizenid: string; name: string; callsign: string | null; recent: number } | null;
}

// server:profile:set payload (every field optional; only what changed is sent)
export interface ProfileSetPayload {
    bio?: string | false;
    avatar?: { kind: Avatar['kind']; value?: string | null };
    appearance?: string;
    accent?: string | false;
    uiScale?: number;
    callsMuted?: boolean;
}

// admin:getOfficerProfile: the profile as staff see it
export interface AdminOfficerProfile extends ProfileData {
    realName?: string;
    bioPending?: string | null;
    pendingAvatar?: string | null;
    avatarStatus?: string;
    reports?: { id: number; reason: string; note: string | null; at: number }[];
}

// getHome extras (the home:extras hook): mission calls open, commendation news, rewards waiting
export interface HomeExtras {
    callsOpen?: number;
    commendations?: number;
    rewardsWaiting?: number;
    news?: { kind: string; text: string; at?: number }[];
}
