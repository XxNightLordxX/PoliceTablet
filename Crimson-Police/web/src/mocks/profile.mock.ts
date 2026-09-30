// Browser mocks of the profile slice: Edit profile, reports, commendations, the Profiles review queue and the Admin
// officer profile. ?profile=empty shows an empty queue.

import { registerMock } from '../shared/nui';
import type { Avatar, Prefs } from '../shared/types';
import type { AdminOfficerProfile, Commendation, ProfileEdit, ProfileQueueItem } from '../types/profile';
import { buildSession } from './samples';

const now = () => Math.floor(Date.now() / 1000);
const MODE = typeof window !== 'undefined' ? new URLSearchParams(window.location.search).get('profile') : null;

// The mock session's shared config and action lists gain the profile values the real getSession sends
// (modules/tablet), when no other mock added them yet.
{
    const officer = buildSession('officer');
    const cfg = officer.config;
    if (!cfg.leaderboardMetrics) {
        cfg.leaderboardMetrics = [
            'points',
            'missions',
            'arrests',
            'impounds',
            'citations',
            'rescues',
            'calls',
            'judgement',
        ];
    }
    if (!cfg.commendationKinds) {
        cfg.commendationKinds = ['valor', 'lifesaving', 'teamwork', 'professionalism', 'leadership', 'investigation'];
    }
    if (!cfg.profile) {
        cfg.profile = {
            bioMax: 280,
            bioLines: 3,
            presets: [
                { id: 'shield', level: null },
                { id: 'star', level: null },
                { id: 'badge', level: null },
                { id: 'dept', level: null },
                { id: 'k9', level: 5 },
                { id: 'motor', level: 10 },
                { id: 'heli', level: 20 },
                { id: 'swat', level: 30 },
                { id: 'detective', level: 40 },
            ],
            urls: true,
            appearances: ['department', 'midnight', 'high_contrast', 'colourblind'],
            accents: [
                { colour: '#f2c230', level: null },
                { colour: '#4cc9f0', level: null },
                { colour: '#80ed99', level: 10 },
                { colour: '#ff8fab', level: 25 },
                { colour: '#c77dff', level: 40 },
            ],
            uiScale: [0.85, 1.25, 1],
        };
    }
    for (const list of [officer.actions, buildSession('admin').actions]) {
        for (const a of ['issueCommendation', 'reviewProfiles']) if (!list.includes(a)) list.push(a);
    }
}

// ============================================================================
//                                 EDIT PROFILE
// ============================================================================

const state: {
    avatar: Avatar;
    pending: ProfileEdit['pending'];
    bio: string | null;
    bioPending: string | null;
    prefs: Prefs;
    urlsLeft: number;
} = {
    avatar: { kind: 'preset', value: 'shield', initials: 'JD', frame: 'bronze' },
    pending: null,
    bio: 'Night shift, Sandy Shores. Ask me about the Grapeseed chase.',
    bioPending: null,
    prefs: { appearance: 'department', accent: null, uiScale: 1, callsMuted: false },
    urlsLeft: 3,
};

registerMock('request', 'getProfileEdit', (): ProfileEdit => ({
    bio: state.bio,
    bioPending: state.bioPending,
    avatar: state.avatar,
    pending: state.pending,
    prefs: state.prefs,
    urlsLeftToday: state.urlsLeft,
    nextEditIn: 0,
    level: {
        n: 12,
        label: 'Patrol Officer',
        badge: 'bronze',
        xp: 1690,
        levelXp: 1578,
        nextLevelXp: 1788,
        prestige: 0,
    },
}));

registerMock('action', 'server:profile:set', (payload: unknown) => {
    const p = (payload ?? {}) as {
        bio?: string | false;
        avatar?: { kind: Avatar['kind']; value?: string | null };
        appearance?: string;
        accent?: string | false;
        uiScale?: number;
        callsMuted?: boolean;
    };
    const pending = { avatar: false, bio: false };
    if (p.avatar) {
        if (p.avatar.kind === 'url') {
            if (
                !/^https:\/\/(r2\.fivemanage\.com|i\.imgur\.com)\/[^?#]*\.(png|jpe?g|webp)(\?.*)?$/i.test(
                    p.avatar.value ?? '',
                )
            ) {
                throw new Error('err.avatar_url_host');
            }
            state.pending = { value: p.avatar.value ?? '', status: 'pending' };
            state.urlsLeft = Math.max(0, state.urlsLeft - 1);
            pending.avatar = true;
        } else {
            state.avatar = { ...state.avatar, kind: p.avatar.kind, value: p.avatar.value ?? null };
            state.pending = null;
        }
    }
    if (p.bio !== undefined) state.bio = p.bio === false ? null : p.bio;
    if (p.appearance) state.prefs = { ...state.prefs, appearance: p.appearance };
    if (p.accent !== undefined) state.prefs = { ...state.prefs, accent: p.accent === false ? null : p.accent };
    if (typeof p.uiScale === 'number') state.prefs = { ...state.prefs, uiScale: p.uiScale };
    if (typeof p.callsMuted === 'boolean') state.prefs = { ...state.prefs, callsMuted: p.callsMuted };
    return { pending };
});

registerMock('action', 'server:profile:report', () => ({ id: 41 }));

// ============================================================================
//                                 REVIEW QUEUE
// ============================================================================

let queue: ProfileQueueItem[] =
    MODE === 'empty'
        ? []
        : [
              {
                  kind: 'avatar',
                  id: null,
                  citizenid: 'SAS30117',
                  name: 'Marcus Reed',
                  callsign: '1A-07',
                  departmentShort: 'SAST',
                  url: 'https://r2.fivemanage.com/pub/reed.png',
                  text: null,
                  reason: null,
                  submittedAt: now() - 3600,
              },
              {
                  kind: 'bio',
                  id: null,
                  citizenid: 'SAS30200',
                  name: 'Jenna Park',
                  callsign: '2L-40',
                  departmentShort: 'SAST',
                  url: null,
                  text: 'Traffic unit. Radar gun enthusiast.\nCoffee first.',
                  current: 'Traffic unit.',
                  reason: null,
                  submittedAt: now() - 7200,
              },
              {
                  kind: 'report',
                  id: 12,
                  citizenid: 'SAS30311',
                  name: 'Tom Brooks',
                  callsign: null,
                  departmentShort: 'SAST',
                  url: null,
                  text: 'Best cop in the county, fight me',
                  reason: 'bio',
                  note: 'Rude bio',
                  submittedAt: now() - 900,
              },
          ];

registerMock('request', 'sup:getProfileQueue', () => queue);

function drop(match: (i: ProfileQueueItem) => boolean) {
    queue = queue.filter(i => !match(i));
    return true;
}

for (const scope of ['sup', 'admin']) {
    registerMock('action', `server:${scope}:reviewAvatar`, (payload: unknown) => {
        const p = payload as { citizenid: string; what?: string };
        return drop(i => i.citizenid === p.citizenid && i.kind === (p.what ?? 'avatar'));
    });
    registerMock('action', `server:${scope}:handleReport`, (payload: unknown) => {
        const p = payload as { id: number };
        return drop(i => i.kind === 'report' && i.id === p.id);
    });
    registerMock('action', `server:${scope}:clearProfile`, () => true);
    registerMock('action', `server:${scope}:commend`, () => ({ id: 99 }));
    registerMock('action', `server:${scope}:revokeCommendation`, () => true);
}

// ============================================================================
//                           ADMIN · OFFICER PROFILE
// ============================================================================

const ADMIN_COMMENDATIONS: Commendation[] = [
    {
        id: 11,
        kind: 'valor',
        citation: 'Held the line at the Vinewood bank until the second unit arrived.',
        by: 'Maria Lopez',
        byRank: 'Lieutenant',
        at: now() - 2 * 86400,
        runUuid: null,
        revoked: false,
        issuedBy: 'LPD10231',
    },
    {
        id: 5,
        kind: 'leadership',
        citation: 'Given by mistake to the wrong officer.',
        by: 'Maria Lopez',
        byRank: 'Lieutenant',
        at: now() - 30 * 86400,
        runUuid: null,
        revoked: true,
        issuedBy: 'LPD10231',
        revokeReason: 'Wrong officer',
    },
];

registerMock('request', 'admin:getOfficerProfile', (args: unknown): AdminOfficerProfile => {
    const cid = (args as { citizenid?: string } | null)?.citizenid ?? 'SAS30117';
    return {
        citizenid: cid,
        name: 'Marcus Reed',
        realName: 'Marcus Reed',
        callsign: '1A-07',
        rank: 'Sergeant',
        departmentShort: 'SAST',
        xp: 21950,
        level: {
            n: 41,
            label: 'Veteran',
            badge: 'gold',
            xp: 21950,
            levelXp: 20550,
            nextLevelXp: 22089,
            prestige: 0,
        },
        avatar: { kind: 'preset', value: 'k9', initials: 'MR', frame: 'gold' },
        pendingAvatar: 'https://r2.fivemanage.com/pub/reed.png',
        avatarStatus: 'pending',
        bio: 'K9 unit, Paleto Bay.',
        bioPending: null,
        badges: [],
        hideName: false,
        own: false,
        runs: [],
        commendations: ADMIN_COMMENDATIONS,
        reports: [{ id: 12, reason: 'picture', note: 'Not a real photo', at: now() - 5000 }],
        service: {
            lifetime: {
                completed: 212,
                failed: 18,
                successRate: 92.2,
                arrests: 140,
                citations: 88,
                impounds: 31,
                vehiclesStopped: 57,
                rescues: 9,
                evidence: 64,
                decisionsOk: 190,
                decisionsBest: 161,
                decisionsBad: 14,
                calls: 71,
                avgResponseS: 104,
                rapidResponses: 3,
                medals: { gold: 3, silver: 5, bronze: 2 },
            },
            season: null,
        },
        bests: [{ missionId: 'beat_patrol', missionLabel: 'Beat Patrol', durationS: 388 }],
        favouritePartner: { name: 'Maria Lopez', callsign: '2L-21' },
    };
});
