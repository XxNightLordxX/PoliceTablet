// Mock: the one notice system (modules/supervisor/notices.lua): notices:get { kind }, server:notice:post and
// server:notice:end, with one list of rows for both kinds like the server's cp_staff_notices.

import { registerMock } from '../shared/nui';
import type { Notice, NoticeKind, NoticesView } from '../types/notices';

const DAY = 86400;
const nowS = () => Math.floor(Date.now() / 1000);
const MOCK_DEPT = 'lspd';

const rows: Notice[] = [
    {
        id: 3,
        kind: 'staff',
        text: 'Training night Friday 8 pm at Mission Row.',
        departments: null,
        by: 'ADM00001',
        createdAt: nowS() - DAY,
        expiresAt: nowS() + 3 * DAY,
    },
    {
        id: 2,
        kind: 'department',
        text: 'Briefing at 20:00, Mission Row.',
        departments: [MOCK_DEPT],
        by: 'sup:SUP00001',
        createdAt: nowS() - 2 * DAY,
        expiresAt: nowS() + DAY,
    },
    {
        id: 1,
        kind: 'staff',
        text: 'The server restarts at 06:00 on Sunday.',
        departments: null,
        by: 'ADM00001',
        createdAt: nowS() - 9 * DAY,
        expiresAt: nowS() - 2 * DAY,
    },
];
let nextId = 4;

const isRunning = (n: Notice) => !n.endedAt && n.expiresAt > nowS();
const ofDept = (n: Notice) => n.kind === 'department' && n.departments?.length === 1 && n.departments[0] === MOCK_DEPT;
const mine = (kind: NoticeKind, n: Notice) => kind === 'staff' || ofDept(n);
const counts = (kind: NoticeKind, n: Notice) => (kind === 'staff' ? n.kind === 'staff' : ofDept(n));
let postedToday = 1;

registerMock('request', 'notices:get', (args: { kind?: NoticeKind }): NoticesView => {
    const kind: NoticeKind = args?.kind === 'staff' ? 'staff' : 'department';
    const ended = rows
        .filter(n => !isRunning(n))
        .map(n => ({
            ...n,
            ended: n.endedAt ? ('removed' as const) : ('expired' as const),
            endedAt: n.endedAt ?? n.expiresAt,
        }));
    return {
        kind,
        canPost: true,
        department: kind === 'department' ? MOCK_DEPT : undefined,
        short: kind === 'department' ? 'LSPD' : undefined,
        reason: kind === 'staff',
        maxLength: 280,
        maxDays: 30,
        maxRunning: 5,
        perDay: kind === 'department' ? 5 : undefined,
        usedToday: kind === 'department' ? postedToday : undefined,
        alert: 'off',
        counted: rows.filter(n => isRunning(n) && counts(kind, n)).length,
        running: rows.filter(n => isRunning(n) && mine(kind, n)),
        history: ended.filter(n => mine(kind, n)),
    };
});

registerMock(
    'action',
    'server:notice:post',
    (p: { kind?: NoticeKind; text?: string; days?: number; departments?: string[]; reason?: string }) => {
        const kind = p.kind;
        if (kind !== 'staff' && kind !== 'department') throw new Error('err.notice_kind');
        if (!p.text || !p.text.trim()) throw new Error('err.notice_text');
        if (!p.days || p.days < 1 || p.days > 30) throw new Error('err.notice_expiry');
        if (kind === 'staff' && !p.reason?.trim()) throw new Error('err.reason_required');
        const now = nowS();
        const id = nextId++;
        rows.unshift({
            id,
            kind,
            text: p.text.trim(),
            departments: kind === 'department' ? [MOCK_DEPT] : p.departments?.length ? p.departments : null,
            by: kind === 'department' ? 'sup:SUP00001' : 'ADM00001',
            createdAt: now,
            expiresAt: now + p.days * DAY,
        });
        if (kind === 'department') postedToday += 1;
        return { id, kind, department: kind === 'department' ? MOCK_DEPT : undefined };
    },
);

registerMock('action', 'server:notice:end', (p: { id?: number }) => {
    const n = rows.find(r => r.id === p.id && isRunning(r));
    if (!n) throw new Error('err.notice_unknown');
    n.endedAt = nowS();
    return { id: n.id };
});
