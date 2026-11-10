// Browser mocks for Admin UI · Real suspects: modules/realplayers/staff.lua. ?rsOff in the
// browser answers as with Config.RealPlayers.liveCrime.enabled and Config.RealPlayers.volunteer.enabled both false.

import { registerMock } from '../shared/nui';
import { registerRestrictionKind, type MockRestrictionPayload } from './restrictions.mock';
import type {
    RsAdminRow,
    RsCaseData,
    RsCaseLine,
    RsCasesData,
    RsListedVolunteer,
    RsPairLine,
    RsPairsData,
} from '../types/admin_rs';

const nowS = () => Math.floor(Date.now() / 1000);
const rsOff = () => typeof window !== 'undefined' && /[?&]rsOff\b/.test(window.location.search);
const CID = /^[\w-]{1,50}$/;

const OPEN_RUN = '9b2e4c10-0000-4000-8000-0000000000a1';
const CLOSED_RUN = '9b2e4c10-0000-4000-8000-0000000000a2';
const OWN_RUN = '9b2e4c10-0000-4000-8000-0000000000a3';
const VOL_RUN = '9b2e4c10-0000-4000-8000-0000000000a4';

const officers = [
    { citizenid: 'SAST0031', name: 'Tom Reed', callsign: '2L-33', status: 'active' },
    { citizenid: 'ABC12345', name: 'Maria Lopez', callsign: '2L-21', status: 'active' },
];

const cases: RsCaseLine[] = [
    {
        runId: OPEN_RUN,
        kind: 'live',
        open: true,
        openedAt: nowS() - 420,
        missionId: 'live_crime',
        suspects: 2,
        detained: 1,
        booked: 0,
        flags: 1,
        notes: 1,
        officers,
    },
    {
        runId: CLOSED_RUN,
        kind: 'live',
        open: false,
        openedAt: nowS() - 7200,
        closedAt: nowS() - 6100,
        missionId: 'live_crime',
        suspects: 1,
        detained: 1,
        booked: 1,
        flags: 0,
        notes: 0,
        officers: [officers[1]],
    },
    {
        runId: OWN_RUN,
        kind: 'volunteer',
        open: false,
        openedAt: nowS() - 86000,
        closedAt: nowS() - 85000,
        missionId: 'volunteer_case',
        suspects: 1,
        detained: 0,
        booked: 0,
        flags: 0,
        notes: 0,
        officers: [{ citizenid: 'ADM00001', name: 'Alex Admin', callsign: null, status: 'left' }],
    },
    {
        runId: VOL_RUN,
        kind: 'volunteer',
        open: false,
        openedAt: nowS() - 3600,
        closedAt: nowS() - 3000,
        missionId: 'warrant_service',
        suspects: 1,
        detained: 0,
        booked: 0,
        flags: 0,
        notes: 1,
        officers: [officers[0]],
        volunteer: { role: 'runner', mode: 'players_when_available', phase: 'npc', why: 'no_show', engaged: false },
    },
];

// the volunteer list (CP.Volunteers.staffList)
const listed: RsListedVolunteer[] = [
    {
        citizenid: 'VOL00001',
        name: 'Jay Park',
        roles: ['runner', 'driver'],
        since: nowS() - 1500,
        untilAt: nowS() + 2100,
        strikes: 1,
    },
    {
        citizenid: 'VOL00002',
        name: 'Kim Vale',
        roles: ['fugitive'],
        since: nowS() - 600,
        untilAt: nowS() + 3000,
        strikes: 0,
        playing: 'travel',
    },
];

function caseData(line: RsCaseLine): RsCaseData {
    const t0 = line.openedAt ?? nowS();
    const open = line.runId === OPEN_RUN;
    const { own: _own, suspects: _count, ...rest } = line;
    return {
        ...rest,
        crimeEnded: !open,
        serverTime: nowS(),
        suspects: open
            ? [
                  {
                      citizenid: 'CRIM0001',
                      name: 'Vince Carter',
                      label: 'A',
                      state: 'detained',
                      online: true,
                      share: 1,
                      everArmed: true,
                      afk: false,
                      down: false,
                      byLeave: false,
                      contactS: 95,
                      cuffedS: 240,
                      detainedS: 270,
                      notes: 0,
                  },
                  {
                      citizenid: 'CRIM0002',
                      name: 'Rosa Diaz',
                      label: 'B',
                      state: 'void',
                      outcome: 'void',
                      online: false,
                      everArmed: false,
                      afk: false,
                      down: false,
                      byLeave: true,
                      contactS: 110,
                      notes: 1,
                  },
              ]
            : [
                  {
                      citizenid: 'CRIM0003',
                      name: 'Ned Price',
                      label: 'A',
                      state: 'booked',
                      outcome: 'booked',
                      online: true,
                      share: 1,
                      everArmed: true,
                      afk: false,
                      down: false,
                      byLeave: false,
                      contactS: 60,
                      cuffedS: 300,
                      detainedS: 330,
                      bookedS: 900,
                      jailTime: 25,
                      notes: 0,
                  },
              ],
        lines: open
            ? [
                  { t: t0, what: 'suspect', label: 'A', text: 'Suspect A joined the case: Vince Carter (CRIM0001)' },
                  { t: t0, what: 'suspect', label: 'B', text: 'Suspect B joined the case: Rosa Diaz (CRIM0002)' },
                  {
                      t: t0 + 95,
                      what: 'contact',
                      label: 'A',
                      who: { citizenid: 'SAST0031', name: 'Tom Reed' },
                      text: 'Suspect A: contact by Tom Reed (SAST0031)',
                  },
                  {
                      t: t0 + 150,
                      what: 'rs_combat_log',
                      label: 'B',
                      note: true,
                      kind: 'rs_combat_log',
                      text: 'A suspect logged off or switched character during the case. - Suspect B: contact 40 s ago',
                  },
                  {
                      t: t0 + 200,
                      what: 'rs_excessive_force',
                      label: 'A',
                      by: { citizenid: 'ABC12345', name: 'Maria Lopez' },
                      flag: true,
                      kind: 'rs_excessive_force',
                      text: 'An officer hit a real suspect who was still in custody. - Suspect A: hit by this officer while cuffed',
                  },
                  {
                      t: t0 + 270,
                      what: 'state',
                      label: 'A',
                      text: 'Suspect A: cuffed -> detained',
                  },
              ]
            : [
                  { t: t0, what: 'suspect', label: 'A', text: 'Suspect A joined the case: Ned Price (CRIM0003)' },
                  { t: t0 + 900, what: 'jail', label: 'A', text: 'Suspect A: booked for 25 months' },
              ],
        flagLines: [],
        ledger: open
            ? [
                  {
                      t: t0 + 180,
                      dir: 'suspect',
                      officer: officers[0],
                      label: 'A',
                      weapon: 453432689,
                      weaponName: 'Pistol',
                      n: 2,
                      willKill: false,
                      down: false,
                  },
                  {
                      t: t0 + 200,
                      dir: 'officer',
                      officer: officers[1],
                      label: 'A',
                      weapon: 453432689,
                      n: 1,
                      willKill: false,
                      state: 'cuffed',
                      down: false,
                      rules: ['rs_excessive_force'],
                  },
              ]
            : [],
    };
}

const pairs: RsPairLine[] = [
    {
        officer: 'ABC12345',
        suspect: 'CRIM0003',
        cases: 3,
        scored: 2,
        lastAt: nowS() - 6100,
        lastOutcome: 'booked',
        kinds: ['live'],
    },
    {
        officer: 'SAST0031',
        suspect: 'CRIM0001',
        cases: 1,
        scored: 1,
        lastAt: nowS() - 90000,
        lastOutcome: 'detained',
        kinds: ['live', 'volunteer'],
    },
];

const adminRows: RsAdminRow[] = [
    { kind: 'block', officer: 'ABC12345', suspect: 'CRIM0009', untilAt: nowS() + 6 * 86400 },
    { kind: 'exclude', suspect: 'CRIM0042', untilAt: nowS() + 29 * 86400 },
];

// the character names the server sends with the pairs (one lookup per screen load)
const NAMES: Record<string, string> = {
    ABC12345: 'Maria Lopez',
    SAST0031: 'Tom Reed',
    CRIM0001: 'Vince Carter',
    CRIM0003: 'Ned Price',
};

function needReason(p: { reason?: string }) {
    if (!p.reason || !p.reason.trim()) throw new Error('err.reason_required');
}

function days(v: unknown): number {
    const n = Number(v);
    if (!Number.isFinite(n) || n <= 0 || n > 3650) throw new Error('err.invalid_days');
    return n;
}

// a longer row wins (Opp.block / exclude / suspend)
function put(row: RsAdminRow) {
    const same = adminRows.find(r => r.kind === row.kind && r.officer == row.officer && r.suspect == row.suspect);
    if (same) same.untilAt = Math.max(same.untilAt, row.untilAt);
    else adminRows.push(row);
    adminRows.sort((a, b) => b.untilAt - a.untilAt);
}

registerMock('request', 'admin:getRsCases', (): RsCasesData => ({
    enabled: !rsOff(),
    liveCrime: !rsOff(),
    volunteers: !rsOff(),
    cases: rsOff() ? [] : cases.map(c => ({ ...c, own: c.runId === OWN_RUN })),
    listed: rsOff() ? [] : listed,
    clearStrikes: !rsOff(),
    lift: true,
    serverTime: nowS(),
}));

registerMock('request', 'admin:getRsCase', (args: { runUuid?: string }) => {
    if (typeof args?.runUuid !== 'string' || !/^[\w-]{1,36}$/.test(args.runUuid)) throw new Error('err.invalid_run');
    if (args.runUuid === OWN_RUN) throw new Error('err.own_run');
    const line = cases.find(c => c.runId === args.runUuid);
    if (!line) throw new Error('err.rs_no_case');
    return caseData(line);
});

registerMock('request', 'admin:getRsPairs', (args: { citizenid?: string }): RsPairsData => {
    const cid = args?.citizenid;
    if (cid !== undefined && !CID.test(cid)) throw new Error('err.invalid_citizenid');
    const now = nowS();
    const running = adminRows.filter(r => r.untilAt > now);
    const out: RsPairsData = {
        enabled: !rsOff(),
        pairs: cid ? pairs.filter(p => p.officer === cid || p.suspect === cid) : pairs,
        from: now - 30 * 86400,
        admin: running,
        names: NAMES,
        lift: true,
        serverTime: now,
    };
    if (cid) {
        out.citizenid = cid;
        out.excludedUntil = running.find(r => r.kind === 'exclude' && r.suspect === cid)?.untilAt ?? null;
        out.suspendedUntil = running.find(r => r.kind === 'suspend' && r.officer === cid)?.untilAt ?? null;
    }
    return out;
});

registerMock(
    'action',
    'server:admin:rsBlockPair',
    (p: { officer?: string; suspect?: string; days?: number; reason?: string }) => {
        if (rsOff()) throw new Error('err.rs_off');
        if (!CID.test(p.officer ?? '') || !CID.test(p.suspect ?? '') || p.officer === p.suspect) {
            throw new Error('err.invalid_citizenid');
        }
        const d = days(p.days);
        needReason(p);
        if (p.officer === 'ADM00001' || p.suspect === 'ADM00001') throw new Error('err.self_target');
        const untilAt = nowS() + Math.floor(d * 86400);
        put({ kind: 'block', officer: p.officer, suspect: p.suspect, untilAt });
        return { officer: p.officer, suspect: p.suspect, untilAt };
    },
);

for (const [name, kind] of [
    ['server:admin:rsExclude', 'exclude'],
    ['server:admin:rsSuspend', 'suspend'],
] as const) {
    registerMock('action', name, (p: { citizenid?: string; days?: number; reason?: string }) => {
        if (rsOff()) throw new Error('err.rs_off');
        if (!CID.test(p.citizenid ?? '')) throw new Error('err.invalid_citizenid');
        const d = days(p.days);
        needReason(p);
        if (p.citizenid === 'ADM00001') throw new Error('err.self_target');
        const untilAt = nowS() + Math.floor(d * 86400);
        put(kind === 'exclude' ? { kind, suspect: p.citizenid, untilAt } : { kind, officer: p.citizenid, untilAt });
        return { citizenid: p.citizenid, untilAt };
    });
}

// lift a running row early (Opp.lift) or extend it, and clear a volunteer's strikes (CP.Volunteers.clearStrikes):
// kinds of the one restrictions list (restrictions.mock.ts)
const RS_KIND = { pairBlock: 'block', exclusion: 'exclude', rsSuspension: 'suspend' } as const;

function findRow(kind: RsAdminRow['kind'], p: MockRestrictionPayload): number {
    const now = nowS();
    const officer = kind === 'exclude' ? undefined : p.citizenid;
    const suspect = kind === 'exclude' ? p.citizenid : kind === 'block' ? p.other : undefined;
    return adminRows.findIndex(
        r =>
            r.kind === kind &&
            r.untilAt > now &&
            (kind === 'exclude' || r.officer === officer) &&
            (kind === 'suspend' || r.suspect === suspect),
    );
}

for (const [key, kind] of Object.entries(RS_KIND) as [keyof typeof RS_KIND, RsAdminRow['kind']][]) {
    registerRestrictionKind(key, {
        maxHours: 3650 * 24,
        rows: () =>
            rsOff()
                ? []
                : adminRows
                      .filter(r => r.kind === kind)
                      .map(r => ({
                          citizenid: (kind === 'exclude' ? r.suspect : r.officer) ?? '',
                          name: NAMES[(kind === 'exclude' ? r.suspect : r.officer) ?? ''] ?? null,
                          other: kind === 'block' ? r.suspect : null,
                          otherName: kind === 'block' ? (NAMES[r.suspect ?? ''] ?? null) : null,
                          untilAt: r.untilAt,
                      })),
        lift: p => {
            if (rsOff()) throw new Error('err.rs_off');
            if (!CID.test(p.citizenid ?? '')) throw new Error('err.invalid_citizenid');
            const i = findRow(kind, p);
            if (i < 0) throw new Error('err.rs_no_row');
            const row = adminRows[i];
            adminRows.splice(i, 1);
            return { kind, officer: row.officer, suspect: row.suspect };
        },
        extend: (p, hours) => {
            if (rsOff()) throw new Error('err.rs_off');
            const i = findRow(kind, p);
            if (i < 0) throw new Error('err.rs_no_row');
            adminRows[i].untilAt += hours * 3600;
            return { kind, untilAt: adminRows[i].untilAt };
        },
    });
}

registerRestrictionKind('volunteerBlock', {
    maxHours: 8760,
    rows: () => [],
    lift: p => {
        if (rsOff()) throw new Error('err.rs_off');
        if (!CID.test(p.citizenid ?? '')) throw new Error('err.invalid_citizenid');
        const v = listed.find(l => l.citizenid === p.citizenid);
        if (!v || !v.strikes) throw new Error('err.rs_no_strikes');
        const strikes = v.strikes;
        v.strikes = 0;
        return { citizenid: p.citizenid, strikes };
    },
});
