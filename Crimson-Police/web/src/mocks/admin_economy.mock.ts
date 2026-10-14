// Browser mocks for full admin control: Payments, department funds, Adjust all and the clean-up.
// ?money=on shows every money tool switched on (they ship off).

import { registerMock } from '../shared/nui';
import type {
    BankingCheck,
    CashStatus,
    CleanupView,
    DepartmentFundsView,
    PaymentRow,
    PaymentTotals,
    PaymentsView,
    PayoutAdjustPreview,
    UnfundedPreview,
} from '../types/admin_economy';

const now = () => Math.floor(Date.now() / 1000);
const MONEY = typeof window !== 'undefined' ? new URLSearchParams(window.location.search).get('money') === 'on' : false;

const OFFICERS = [
    { citizenid: 'ABC12345', name: 'John Doe', department: 'sast' },
    { citizenid: 'KLM55512', name: 'Maria Lopez', department: 'sast' },
    { citizenid: 'FIB00042', name: 'Dana Scully', department: 'fib' },
];
const MISSIONS = ['Beat Patrol', 'Bank Job', 'Street Race Bust', 'Gang Shootout'];
const STATUSES: CashStatus[] = ['paid', 'paid', 'paid', 'capped', 'pending', 'held', 'paying', 'unfunded', 'forfeited'];

const rows: PaymentRow[] = Array.from({ length: 70 }, (_, i) => {
    const o = OFFICERS[i % OFFICERS.length];
    const status = STATUSES[i % STATUSES.length];
    const owed = 200 + (i % 7) * 75;
    const paid = status === 'paid' ? owed : status === 'capped' ? Math.floor(owed / 2) : 0;
    return {
        id: 900 - i,
        runUuid: `9c1e${i.toString().padStart(4, '0')}-1111-4000-8000-000000000000`,
        citizenid: o.citizenid,
        name: o.name,
        missionId: 'beat_patrol',
        missionLabel: MISSIONS[i % MISSIONS.length],
        missionType: 'patrol',
        manual: false,
        department: o.department,
        status,
        owed,
        paid,
        reclaimed: 0,
        cut: status === 'capped' ? owed - paid : 0,
        txn: `CP-9c1e${i.toString().padStart(4, '0')}-${o.citizenid}`,
        account: 'bank',
        source: 'society',
        step: status === 'paying' ? 'withdrawn' : status === 'paid' ? 'added' : null,
        voided: status === 'held' && i % 2 === 0,
        flagged: false,
        busy: false,
        createdAt: now() - i * 3100,
    };
});

const switches = () => ({
    payAgain: MONEY,
    unfundedRetry: MONEY,
    capTopUp: MONEY,
    restoreForfeited: MONEY,
    clawback: MONEY,
    manualCash: MONEY,
    addFunds: MONEY,
});

function filtered(a: Record<string, unknown>): PaymentRow[] {
    return rows.filter(
        r =>
            (!a.status || r.status === a.status) &&
            (!a.department || r.department === a.department) &&
            (!a.citizenid || r.citizenid === a.citizenid) &&
            (!a.from || r.createdAt >= Number(a.from)) &&
            (!a.to || r.createdAt < Number(a.to)),
    );
}

function byId(p: unknown): PaymentRow {
    const id = Number((p as { rowId?: number } | null)?.rowId);
    const r = rows.find(x => x.id === id);
    if (!r) throw new Error('err.row_not_found');
    return r;
}

function needReason(p: unknown) {
    if (!(p as { reason?: string } | null)?.reason) throw new Error('err.reason_required');
}

function needSwitch() {
    if (!MONEY) throw new Error('err.money_tool_off');
}

registerMock('request', 'admin:getPayments', (args: unknown): PaymentsView => {
    const a = (args ?? {}) as Record<string, unknown>;
    const size = Math.min(50, Number(a.size) || 25);
    const list = filtered(a);
    const pages = Math.max(1, Math.ceil(list.length / size));
    const page = Math.min(pages, Math.max(1, Number(a.page) || 1));
    return {
        rows: list.slice((page - 1) * size, page * size),
        page,
        pages,
        total: list.length,
        size,
        switches: switches(),
        source: 'society',
        maxPayout: 25000,
        manualDailyLimit: 10000,
        nextForfeitIn: 420,
        held: null,
        serverTime: now(),
    };
});

registerMock('request', 'admin:getPaymentTotals', (args: unknown): PaymentTotals => {
    const list = filtered((args ?? {}) as Record<string, unknown>);
    const byStatus = {} as PaymentTotals['byStatus'];
    for (const s of ['held', 'pending', 'paying', 'paid', 'capped', 'unfunded', 'forfeited'] as CashStatus[]) {
        const of = list.filter(r => r.status === s);
        byStatus[s] = {
            count: of.length,
            paid: of.reduce((n, r) => n + r.paid, 0),
            reclaimed: 0,
            owed: of.reduce((n, r) => n + r.owed, 0),
        };
    }
    const paidTotal = byStatus.paid.paid + byStatus.capped.paid;
    const departments = ['fib', 'sast'].map(d => {
        const of = list.filter(r => r.department === d);
        const paid = of.reduce((n, r) => n + r.paid, 0);
        return {
            department: d,
            count: of.length,
            paid,
            reclaimed: 0,
            unfunded: of.filter(r => r.status === 'unfunded').length,
            share: paidTotal ? Math.round((paid * 1000) / paidTotal) / 10 : 0,
        };
    });
    const cut = list.reduce((n, r) => n + r.cut, 0);
    return { byStatus, departments, paidTotal, cut, cappedToday: 2, partial: false };
});

registerMock('request', 'admin:exportPayments', (args: unknown) => {
    const list = filtered((args ?? {}) as Record<string, unknown>);
    const csv = ['id,time,citizenid,name,department,mission,status,owed,paid,taken_back,cut,transaction,account,source']
        .concat(
            list.map(r =>
                [
                    r.id,
                    r.createdAt,
                    r.citizenid,
                    r.name,
                    r.department,
                    r.missionLabel,
                    r.status,
                    r.owed,
                    r.paid,
                    r.reclaimed,
                    r.cut,
                    r.txn,
                    r.account,
                    r.source,
                ].join(','),
            ),
        )
        .join('\n');
    return { csv: `${csv}\n`, rows: list.length, truncated: false };
});

registerMock('request', 'admin:checkBankingTxn', (args: unknown): BankingCheck => {
    const id = Number((args as { rowId?: number } | null)?.rowId);
    const r = rows.find(x => x.id === id) ?? rows[0];
    return {
        id: r.id,
        status: r.status,
        txn: r.txn,
        amount: r.owed,
        step: r.step ?? null,
        source: r.source ?? null,
        account: r.account ?? null,
        societyAccount: r.department,
        personal: { found: false },
        society: { found: true, amount: r.owed, type: 'withdraw', time: r.createdAt },
        busy: false,
        online: true,
        payAgain: MONEY,
    };
});

registerMock('action', 'server:admin:resolvePayment', (p: { outcome?: string; checked?: boolean }) => {
    const r = byId(p);
    needReason(p);
    if (r.status !== 'paying') throw new Error('err.state_changed');
    if (p.outcome === 'payAgain') {
        needSwitch();
        if (!p.checked) throw new Error('err.check_first');
    }
    r.status = 'paid';
    r.paid = r.owed;
    return { id: r.id, status: 'paid', amount: r.owed };
});

registerMock('action', 'server:admin:payNow', (p: unknown) => {
    const r = byId(p);
    if (r.status !== 'pending') throw new Error('err.state_changed');
    r.status = 'paid';
    r.paid = r.owed;
    return { id: r.id, status: 'paid', online: true };
});

registerMock('action', 'server:admin:retryPending', () => {
    let n = 0;
    for (const r of rows) if (r.status === 'pending') ((r.status = 'paid'), (r.paid = r.owed), n++);
    return { paid: n, officers: 3 };
});

registerMock('request', 'admin:previewRetryUnfunded', (args: unknown): UnfundedPreview => {
    const a = (args ?? {}) as { rowId?: number; department?: string };
    const list = rows.filter(
        r => r.status === 'unfunded' && (a.rowId ? r.id === a.rowId : r.department === a.department),
    );
    const total = list.reduce((n, r) => n + r.owed, 0);
    return {
        previewToken: 'mock-token',
        expiresAt: now() + 120,
        effect: {
            count: list.length,
            total,
            departments: [{ department: 'sast', label: 'San Andreas State Troopers', owed: total, balance: 50000 }],
            rows: list,
        },
    };
});

for (const name of [
    'server:admin:retryUnfunded',
    'server:admin:payCapRest',
    'server:admin:repayForfeited',
    'server:admin:clawback',
]) {
    registerMock('action', name, (p: unknown) => {
        needSwitch();
        needReason(p);
        const r = (p as { rowId?: number }).rowId ? byId(p) : null;
        if (r) {
            if (name === 'server:admin:payCapRest') ((r.paid = r.owed), (r.cut = 0), (r.restPaid = 'paid'));
            else if (name === 'server:admin:clawback') r.reclaimed += Number((p as { amount?: number }).amount ?? 0);
            else ((r.status = 'paid'), (r.paid = r.owed));
        }
        return { id: r?.id, status: r?.status, claimed: 1, paid: 1, pending: 0 };
    });
}

for (const name of ['server:admin:forfeitNow', 'server:admin:cancelPayment']) {
    registerMock('action', name, (p: unknown) => {
        needReason(p);
        const r = byId(p);
        if (r.status !== 'held' && r.status !== 'pending') throw new Error('err.state_changed');
        r.status = 'forfeited';
        return { id: r.id, status: 'forfeited' };
    });
}

registerMock('action', 'server:admin:manualCash', (p: { amount?: number }) => {
    needSwitch();
    needReason(p);
    if (!p?.amount || p.amount < 1) throw new Error('err.invalid_amount');
    return { id: 1001, status: 'paid', amount: p.amount };
});

const funds: Record<string, number> = { sast: 48250, fib: 1200 };

registerMock('request', 'admin:getDepartmentFunds', (args: unknown): DepartmentFundsView => {
    const department = String((args as { department?: string } | null)?.department ?? 'sast');
    return {
        department,
        label: department.toUpperCase(),
        account: department,
        enabled: true,
        source: 'society',
        balance: department in funds ? funds[department] : null,
        lowBalanceWarn: 5000,
        spent: { today: 1350, week: 9100, season: 41200 },
        unfunded: department === 'fib' ? 2 : 0,
        funded: 10000,
        recent: [
            {
                id: 3,
                amount: 10000,
                txn: 'CP-FUND-3',
                state: 'done',
                by: 'ADM00001',
                reason: 'monthly top up',
                at: now() - 86400,
            },
        ],
        allowAddFunds: MONEY,
        addFundsMax: 50000,
    };
});

registerMock('action', 'server:admin:addDepartmentFunds', (p: { department?: string; amount?: number }) => {
    needSwitch();
    needReason(p);
    const d = String(p.department ?? 'sast');
    funds[d] = (funds[d] ?? 0) + Number(p.amount ?? 0);
    return { id: 4, txn: 'CP-FUND-4', amount: p.amount };
});

registerMock('request', 'admin:previewPayoutAdjust', (args: unknown): PayoutAdjustPreview => {
    const a = (args ?? {}) as { mode?: string; value?: number };
    const v = Number(a.value ?? 0);
    const base = [
        { key: 'type:patrol', id: 'patrol', label: 'Patrol', old: 400 },
        { key: 'type:investigation', id: 'investigation', label: 'Investigation', old: 700 },
        { key: 'type:tactical', id: 'tactical', label: 'Tactical', old: 1200 },
    ];
    const rowsOut = base.map(b => ({
        ...b,
        kind: 'type' as const,
        new: Math.max(0, Math.min(25000, a.mode === 'pct' ? Math.round((b.old * (100 + v)) / 100) : b.old + v)),
    }));
    return { previewToken: 'mock-adjust', expiresAt: now() + 120, effect: { rows: rowsOut, total: rowsOut.length } };
});

registerMock('action', 'server:admin:adjustAllPayouts', (p: { confirm?: string }) => {
    needReason(p);
    if (String(p?.confirm ?? '').toUpperCase() !== 'ADJUST') throw new Error('err.confirm_mismatch');
    return { changed: 3, failed: 0 };
});

const cleanup: CleanupView = {
    last: {
        at: now() - 6 * 3600,
        by: null,
        archived: 120,
        kept: 3,
        auditDeleted: 40,
        requestsDeleted: 12,
        historyDeleted: 0,
        durationMs: 840,
    },
    running: false,
    nextRunAt: now() + 18 * 3600,
    runArchiveMonths: 12,
    auditDays: 180,
    requestDays: 7,
};

registerMock('request', 'admin:getCleanup', (): CleanupView => cleanup);

registerMock('action', 'server:admin:runCleanupNow', (p: unknown) => {
    needReason(p);
    cleanup.last = { ...cleanup.last!, at: now(), by: 'ADM00001', archived: 0, requestsDeleted: 0 };
    return cleanup;
});
