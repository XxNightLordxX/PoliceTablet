// Shapes of the officer profile: commendations, the Edit profile dialog and the supervisors' Profiles queue.

import type { Avatar, LevelInfo, Prefs } from '../shared/types';

export interface Commendation {
    id: number;
    kind: string;
    citation: string;
    by: string;
    byRank: string | null;
    at: number;
    runUuid: string | null;
    revoked: boolean;
}

// getProfileEdit
export interface ProfileEdit {
    bio: string | null;
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
}
