// Admin UI → Payments: every payment with filters, totals and CSV, and the payment actions. The money tools that
// ship off show only while their Settings switch is on; every amount shown is the server's.

import { useMemo, useRef, useState } from 'react';
import {
    Badge,
    Button,
    Card,
    Checkbox,
    ConfirmDialog,
    Dialog,
    EmptyState,
    ErrorState,
    Field,
    Icon,
    IconButton,
    KeyValue,
    LoadingBlock,
    Money,
    NumberInput,
    Screen,
    Select,
    Stat,
    Table,
    Textarea,
    TextInput,
    type BadgeTone,
    type IconName,
    type TableColumn,
} from '../../shared/components';
import { formatDateTime, formatMoney, formatNumber } from '../../shared/format';
import { useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { request } from '../../shared/nui';
import { useNavigation } from '../../shared/navigation';
import { useSession } from '../../shared/session';
import { toast } from '../../shared/toast';
import type {
    BankingCheck,
    BankingEntry,
    PaymentRow,
    PaymentTotals,
    PaymentsExport,
    PaymentsView,
    UnfundedPreview,
} from '../../types/admin_economy';
import { DateRangeField, MoneyEffect, OfficerPicker, Pager, PreviewTable, useAdminAction } from '../components/kit';
import type { DateRange } from '../components/kit';
import './Payments.css';

const REASON_MAX = 255;
const PAGE_SIZE = 25;
const STATUSES = ['held', 'pending', 'paying', 'paid', 'capped', 'unfunded', 'forfeited'] as const;

const STATUS_TONE: Record<string, BadgeTone> = {
    held: 'warning',
    pending: 'accent',
    paying: 'danger',
    paid: 'success',
    capped: 'primary',
    unfunded: 'danger',
    forfeited: 'neutral',
};

// YYYY-MM-DD (local) → unix seconds; the end date counts whole (to < the next day's start).
function dayStart(day: string, next = false): number | undefined {
    if (!day) return undefined;
    const d = new Date(`${day}T00:00:00`);
    if (isNaN(d.getTime())) return undefined;
    if (next) d.setDate(d.getDate() + 1);
    return Math.floor(d.getTime() / 1000);
}

function statusLabel(s: string): string {
    return t(`payments.status.${s}`);
}

// What the row offers, by status and switch.
type RowAction = 'resolve' | 'payNow' | 'unfunded' | 'capRest' | 'repay' | 'forfeitNow' | 'cancel' | 'clawback';

function rowActions(r: PaymentRow, v: PaymentsView): RowAction[] {
    const out: RowAction[] = [];
    const sw = v.switches;
    if (r.status === 'paying') out.push('resolve');
    if (r.status === 'pending') out.push('payNow');
    if (r.status === 'unfunded' && sw.unfundedRetry && !r.voided) out.push('unfunded');
    if (r.status === 'capped' && r.cut > 0 && !r.restPaid && sw.capTopUp && !r.voided) out.push('capRest');
    if (r.status === 'forfeited' && r.paid === 0 && !r.voided && sw.restoreForfeited) out.push('repay');
    if ((r.status === 'held' || r.status === 'pending') && r.voided) out.push('forfeitNow');
    if (r.status === 'held' || r.status === 'pending') out.push('cancel');
    if ((r.status === 'paid' || r.status === 'capped') && r.paid > r.reclaimed && sw.clawback) out.push('clawback');
    return out;
}

const ACTION_ICON: Record<RowAction, IconName> = {
    resolve: 'search',
    payNow: 'refresh',
    unfunded: 'refresh',
    capRest: 'dollar',
    repay: 'undo',
    forfeitNow: 'x',
    cancel: 'xCircle',
    clawback: 'minus',
};

const ACTION_NAME: Partial<Record<RowAction, string>> = {
    capRest: 'server:admin:payCapRest',
    repay: 'server:admin:repayForfeited',
    forfeitNow: 'server:admin:forfeitNow',
    cancel: 'server:admin:cancelPayment',
    clawback: 'server:admin:clawback',
};

// ============================================================================
//                                RESOLVE DIALOG
// ============================================================================

function EntryLine({ label, e }: { label: string; e?: BankingEntry | null }) {
    if (!e) return null;
    return (
        <KeyValue label={label}>
            {e.found ? (
                <span className="payments-admin__found">
                    <Icon name="checkCircle" size={14} />
                    {t('payments.resolve.found', {
                        amount: formatMoney(e.amount ?? 0),
                        type: t(`payments.resolve.type_${e.type ?? 'deposit'}`),
                        when: formatDateTime(e.time ?? 0),
                    })}
                </span>
            ) : (
                <span className="payments-admin__soft">{t('payments.resolve.not_found')}</span>
            )}
        </KeyValue>
    );
}

function ResolveDialog({ row, onClose, onDone }: { row: PaymentRow | null; onClose: () => void; onDone: () => void }) {
    const { data, loading, error } = useRequest<BankingCheck>(
        'admin:checkBankingTxn',
        { rowId: row?.id ?? 0 },
        { skip: !row },
    );
    const [mode, setMode] = useState<'paid' | 'payAgain' | null>(null);
    const [checked, setChecked] = useState(false);
    const { run } = useAdminAction();
    if (!row) return null;
    const amount = data?.amount ?? row.owed;

    const submit = async (reason: string, typed: string) => {
        const res = await run(
            'server:admin:resolvePayment',
            { rowId: row.id, outcome: mode, checked, reason, confirm: typed },
            { success: mode === 'paid' ? 'payments.resolve.marked' : 'payments.resolve.paid_again' },
        );
        if (res.ok) {
            setMode(null);
            onDone();
        }
    };

    return (
        <>
            <Dialog
                open={!mode}
                onClose={onClose}
                title={t('payments.resolve.title', { name: row.name ?? row.citizenid })}
                description={t('payments.resolve.desc')}
                size="md"
                footer={
                    <>
                        <Button variant="ghost" onClick={onClose}>
                            {t('common.close')}
                        </Button>
                        <Button
                            variant="secondary"
                            icon="check"
                            disabled={!data || data.busy}
                            onClick={() => setMode('paid')}
                        >
                            {t('payments.resolve.mark_paid')}
                        </Button>
                        {data?.payAgain ? (
                            <Button
                                variant="danger"
                                icon="refresh"
                                disabled={data.busy || !data.online || data.step === 'added'}
                                onClick={() => setMode('payAgain')}
                            >
                                {t('payments.resolve.pay_again')}
                            </Button>
                        ) : null}
                    </>
                }
            >
                {loading && !data ? <LoadingBlock /> : null}
                {error && !data ? <ErrorState error={error} /> : null}
                {data ? (
                    <div className="payments-admin__resolve">
                        <KeyValue label={t('payments.col.txn')}>
                            <code className="cp-selectable">{data.txn}</code>
                        </KeyValue>
                        <KeyValue label={t('payments.col.owed')}>
                            <Money amount={data.amount} />
                        </KeyValue>
                        <KeyValue label={t('payments.resolve.step')}>
                            {t(`payments.step.${data.step ?? 'unknown'}`)}
                        </KeyValue>
                        <EntryLine label={t('payments.resolve.personal')} e={data.personal} />
                        <EntryLine label={t('payments.resolve.society')} e={data.society} />
                        <div className="payments-admin__note">
                            <Icon name="info" size={14} />
                            <span>{t('payments.resolve.nothing_proves')}</span>
                        </div>
                        {data.busy ? <div className="payments-admin__warn">{t('err.payment_in_flight')}</div> : null}
                        {data.payAgain && !data.online ? (
                            <div className="payments-admin__warn">{t('payments.resolve.offline')}</div>
                        ) : null}
                    </div>
                ) : null}
            </Dialog>
            <ConfirmDialog
                open={mode !== null}
                title={mode === 'paid' ? t('payments.resolve.mark_paid') : t('payments.resolve.pay_again')}
                message={mode === 'paid' ? t('payments.resolve.mark_paid_msg') : t('payments.resolve.pay_again_msg')}
                effect={
                    mode === 'payAgain' ? (
                        <>
                            <MoneyEffect lines={[{ label: row.missionLabel, amount }]} />
                            <Checkbox checked={checked} onChange={setChecked} label={t('payments.resolve.checked')} />
                        </>
                    ) : null
                }
                typedWord={mode === 'payAgain' ? String(amount) : undefined}
                tone={mode === 'payAgain' ? 'danger' : 'primary'}
                reason={{ required: true, maxLength: REASON_MAX }}
                onConfirm={submit}
                onCancel={() => setMode(null)}
            />
        </>
    );
}

// ============================================================================
//                            ONE-ROW ACTION DIALOG
// ============================================================================

function ActionDialog({
    row,
    kind,
    view,
    onClose,
    onDone,
}: {
    row: PaymentRow;
    kind: RowAction;
    view: PaymentsView;
    onClose: () => void;
    onDone: () => void;
}) {
    const { run } = useAdminAction();
    const [amount, setAmount] = useState<number | null>(null);
    const left = row.paid - row.reclaimed;
    const typed: Record<RowAction, string | undefined> = {
        resolve: undefined,
        payNow: undefined,
        unfunded: String(row.owed),
        capRest: String(row.cut),
        repay: String(row.owed),
        forfeitNow: undefined,
        cancel: String(row.owed),
        clawback: amount ? String(amount) : '-',
    };
    const lines =
        kind === 'capRest'
            ? [{ label: t('payments.effect.rest'), amount: row.cut }]
            : kind === 'clawback'
              ? [{ label: t('payments.effect.take_back'), amount: amount ?? 0, before: left }]
              : [{ label: row.missionLabel, amount: row.owed }];

    const confirm = async (reason: string, word: string) => {
        let ok = false;
        if (kind === 'payNow') {
            ok = (await run('server:admin:payNow', { rowId: row.id }, { success: 'payments.done' })).ok;
        } else if (kind === 'unfunded') {
            const pv = await request<UnfundedPreview>('admin:previewRetryUnfunded', { rowId: row.id });
            if (!pv.ok || !pv.data) {
                toast('error', t(pv.error || 'err.internal'));
                return;
            }
            const payload = { rowId: row.id, reason, confirm: word, previewToken: pv.data.previewToken };
            ok = (await run('server:admin:retryUnfunded', payload, { success: 'payments.done' })).ok;
        } else {
            const name = ACTION_NAME[kind];
            if (!name) return;
            const payload = { rowId: row.id, reason, confirm: word, amount: amount ?? undefined };
            ok = (await run(name, payload, { success: 'payments.done' })).ok;
        }
        if (ok) onDone();
    };

    return (
        <ConfirmDialog
            open
            title={t(`payments.action.${kind}`)}
            message={t(`payments.action_msg.${kind}`, {
                name: row.name ?? row.citizenid,
                amount: formatMoney(row.owed),
                max: formatMoney(view.maxPayout),
            })}
            effect={
                <>
                    {kind === 'clawback' ? (
                        <Field label={t('payments.effect.take_back')} required>
                            <NumberInput
                                value={amount}
                                onChange={setAmount}
                                min={1}
                                max={left}
                                prefix="$"
                                formatRange={formatMoney}
                            />
                        </Field>
                    ) : null}
                    {kind !== 'payNow' && kind !== 'forfeitNow' ? <MoneyEffect lines={lines} /> : null}
                </>
            }
            typedWord={typed[kind]}
            tone={kind === 'payNow' ? 'primary' : 'danger'}
            reason={kind === 'payNow' ? undefined : { required: true, maxLength: REASON_MAX }}
            onConfirm={confirm}
            onCancel={onClose}
        />
    );
}

// ============================================================================
//                          MANUAL CASH PAYMENT DIALOG
// ============================================================================

function ManualDialog({
    open,
    view,
    onClose,
    onDone,
}: {
    open: boolean;
    view: PaymentsView;
    onClose: () => void;
    onDone: () => void;
}) {
    const [cid, setCid] = useState<string | null>(null);
    const [amount, setAmount] = useState<number | null>(null);
    const [reason, setReason] = useState('');
    const [typed, setTyped] = useState('');
    const { run, busy } = useAdminAction();
    const needWord = amount !== null && amount > Math.floor(view.maxPayout / 2);
    const can = !!cid && amount !== null && reason.trim() !== '' && (!needWord || typed.trim() === String(amount));

    const send = async () => {
        if (!can) return;
        const res = await run(
            'server:admin:manualCash',
            { citizenid: cid, amount, reason: reason.trim(), confirm: needWord ? typed.trim() : undefined },
            { success: 'payments.manual.sent' },
        );
        if (res.ok) {
            setCid(null);
            setAmount(null);
            setReason('');
            setTyped('');
            onDone();
        }
    };

    return (
        <Dialog
            open={open}
            onClose={busy ? () => undefined : onClose}
            title={t('payments.manual.title')}
            description={t('payments.manual.desc', { limit: formatMoney(view.manualDailyLimit) })}
            size="md"
            footer={
                <>
                    <Button variant="ghost" onClick={onClose} disabled={busy}>
                        {t('common.cancel')}
                    </Button>
                    <Button variant="danger" icon="dollar" onClick={() => void send()} loading={busy} disabled={!can}>
                        {t('payments.manual.send')}
                    </Button>
                </>
            }
        >
            <div className="payments-admin__form">
                <Field label={t('payments.col.officer')} required>
                    <OfficerPicker value={cid} onChange={c => setCid(c)} />
                </Field>
                <Field label={t('payments.manual.amount')} required>
                    <NumberInput
                        value={amount}
                        onChange={setAmount}
                        min={1}
                        max={view.maxPayout}
                        prefix="$"
                        formatRange={formatMoney}
                    />
                </Field>
                <Field label={t('common.reason')} required>
                    <Textarea value={reason} onChange={setReason} maxLength={REASON_MAX} rows={3} />
                </Field>
                {needWord ? (
                    <Field label={t('ui.confirm.type_word', { word: String(amount) })} required>
                        <TextInput value={typed} onChange={setTyped} autoComplete="off" />
                    </Field>
                ) : null}
                <div className="payments-admin__note">
                    <Icon name="info" size={14} />
                    <span>{t('payments.manual.cap_note')}</span>
                </div>
            </div>
        </Dialog>
    );
}

// ============================================================================
//                                  THE SCREEN
// ============================================================================

export default function AdminPayments() {
    const session = useSession();
    const departments = session.config?.departments ?? [];
    // Leaderboards → stuck payments links here with navigate('admin_payments', { status: 'paying' })
    const { params } = useNavigation();
    const [status, setStatus] = useState(typeof params.status === 'string' ? params.status : '');
    const [department, setDepartment] = useState('');
    const [citizenid, setCitizenid] = useState<string | null>(null);
    const [range, setRange] = useState<DateRange>({ from: '', to: '' });
    const [page, setPage] = useState(1);
    const [resolving, setResolving] = useState<PaymentRow | null>(null);
    const [acting, setActing] = useState<{ row: PaymentRow; kind: RowAction } | null>(null);
    const [manual, setManual] = useState(false);
    const [exported, setExported] = useState<PaymentsExport | null>(null);
    const [bulkPreview, setBulkPreview] = useState<UnfundedPreview | null>(null);
    const area = useRef<HTMLTextAreaElement>(null);
    const { run, busy } = useAdminAction();

    const where = useMemo(() => {
        const f: Record<string, unknown> = {};
        if (department) f.department = department;
        const from = dayStart(range.from);
        const to = dayStart(range.to, true);
        if (from !== undefined) f.from = from;
        if (to !== undefined) f.to = to;
        return f;
    }, [department, range]);
    const filter = useMemo(() => {
        const f: Record<string, unknown> = { ...where, page, size: PAGE_SIZE };
        if (status) f.status = status;
        if (citizenid) f.citizenid = citizenid;
        return f;
    }, [where, status, citizenid, page]);

    const { data, loading, error, refetch } = useRequest<PaymentsView>('admin:getPayments', filter, {
        pushTopic: 'payments',
    });
    const totals = useRequest<PaymentTotals>('admin:getPaymentTotals', where);
    const tot = totals.data;
    const reload = () => {
        void refetch();
        void totals.refetch();
    };
    const pick =
        <T,>(set: (v: T) => void) =>
        (v: T) => {
            set(v);
            setPage(1);
        };

    const doExport = async () => {
        const args: Record<string, unknown> = { ...where };
        if (status) args.status = status;
        if (citizenid) args.citizenid = citizenid;
        const res = await request<PaymentsExport>('admin:exportPayments', args);
        if (res.ok && res.data) setExported(res.data);
        else toast('error', t(res.error || 'err.internal'));
    };

    const copy = () => {
        const el = area.current;
        if (!el) return;
        el.focus();
        el.select();
        let ok = false;
        try {
            ok = document.execCommand('copy');
        } catch {
            ok = false;
        }
        toast(ok ? 'success' : 'warning', t(ok ? 'admin.audit.copied' : 'admin.audit.copy_failed'));
    };

    const retryPending = async () => {
        const res = await run<{ paid: number }>('server:admin:retryPending', {});
        if (res.ok) {
            toast('success', t('payments.retry_pending_done', { n: res.data?.paid ?? 0 }));
            reload();
        }
    };

    const openBulkUnfunded = async () => {
        const res = await request<UnfundedPreview>('admin:previewRetryUnfunded', { department });
        if (res.ok && res.data) setBulkPreview(res.data);
        else toast('error', t(res.error || 'err.internal'));
    };

    const bulkRetry = async (reason: string, typed: string) => {
        if (!bulkPreview) return;
        const payload = { department, reason, confirm: typed, previewToken: bulkPreview.previewToken };
        const res = await run('server:admin:retryUnfunded', payload, { success: 'payments.done' });
        setBulkPreview(null);
        if (res.ok) reload();
    };

    const baseColumns: TableColumn<PaymentRow>[] = [
        {
            key: 'when',
            header: t('payments.col.when'),
            width: 120,
            render: r => <span className="cp-num payments-admin__soft">{formatDateTime(r.createdAt)}</span>,
        },
        {
            key: 'officer',
            header: t('payments.col.officer'),
            render: r => (
                <span className="payments-admin__who">
                    <span>{r.name ?? r.citizenid}</span>
                    {r.name ? <code className="cp-selectable">{r.citizenid}</code> : null}
                </span>
            ),
        },
        {
            key: 'mission',
            header: t('payments.col.mission'),
            render: r => (
                <span className="payments-admin__who">
                    <span>
                        {r.missionLabel}{' '}
                        {r.voided ? (
                            <Badge size="sm" tone="danger">
                                {t('payments.voided')}
                            </Badge>
                        ) : null}
                    </span>
                    <span className="payments-admin__soft">{r.department}</span>
                </span>
            ),
        },
        {
            key: 'status',
            header: t('payments.col.status'),
            width: 110,
            render: r => (
                <Badge size="sm" tone={STATUS_TONE[r.status] ?? 'neutral'}>
                    {statusLabel(r.status)}
                </Badge>
            ),
        },
        { key: 'owed', header: t('payments.col.owed'), numeric: true, render: r => <Money amount={r.owed} /> },
    ];
    const columns: TableColumn<PaymentRow>[] = [
        ...baseColumns,
        {
            key: 'paid',
            header: t('payments.col.paid'),
            numeric: true,
            render: r => (
                <span className="payments-admin__who">
                    <Money amount={r.paid} />
                    {r.cut > 0 ? (
                        <span className="payments-admin__soft">
                            {t('payments.cut', { amount: formatMoney(r.cut) })}
                        </span>
                    ) : null}
                    {r.reclaimed > 0 ? (
                        <span className="payments-admin__soft">
                            {t('payments.reclaimed', { amount: formatMoney(r.reclaimed) })}
                        </span>
                    ) : null}
                </span>
            ),
        },
        {
            key: 'txn',
            header: t('payments.col.txn'),
            render: r => <code className="cp-selectable payments-admin__txn">{r.txn}</code>,
        },
        {
            key: 'actions',
            header: '',
            align: 'right',
            render: r =>
                data ? (
                    <span className="payments-admin__actions">
                        {rowActions(r, data).map(a => (
                            <IconButton
                                key={a}
                                size="sm"
                                variant="ghost"
                                icon={ACTION_ICON[a]}
                                label={t(`payments.action.${a}`)}
                                disabled={r.busy}
                                onClick={() => (a === 'resolve' ? setResolving(r) : setActing({ row: r, kind: a }))}
                            />
                        ))}
                    </span>
                ) : null,
        },
    ];

    const statusOptions = [
        { value: '', label: t('payments.filter.all') },
        ...STATUSES.map(s => ({ value: s, label: statusLabel(s) })),
    ];
    const deptOptions = [
        { value: '', label: t('payments.filter.all_departments') },
        ...departments.map(d => ({ value: d.key, label: d.label })),
    ];
    const deptLabel = (key: string) => departments.find(x => x.key === key)?.label ?? key;

    return (
        <Screen
            title={t('ui.screen.admin_payments')}
            subtitle={t('payments.subtitle')}
            className="payments-admin"
            actions={
                <span className="payments-admin__actions">
                    <Button size="sm" icon="refresh" onClick={() => void retryPending()} loading={busy}>
                        {t('payments.retry_pending')}
                    </Button>
                    {data?.switches.manualCash ? (
                        <Button size="sm" variant="danger" icon="dollar" onClick={() => setManual(true)}>
                            {t('payments.manual.open')}
                        </Button>
                    ) : null}
                    <Button size="sm" icon="download" onClick={() => void doExport()}>
                        {t('payments.export')}
                    </Button>
                </span>
            }
        >
            {data?.held ? (
                <Card highlight="warning" padding="sm">
                    {t('payments.held')}
                </Card>
            ) : null}

            {tot ? (
                <div className="payments-admin__stats">
                    <Stat
                        size="sm"
                        label={statusLabel('paid')}
                        value={formatMoney(tot.paidTotal)}
                        icon="check"
                        tone="success"
                    />
                    <Stat
                        size="sm"
                        label={statusLabel('pending')}
                        value={formatMoney(tot.byStatus.pending.owed)}
                        hint={t('payments.rows', { n: tot.byStatus.pending.count })}
                        icon="clock"
                        tone="accent"
                    />
                    <Stat
                        size="sm"
                        label={statusLabel('held')}
                        value={formatMoney(tot.byStatus.held.owed)}
                        hint={t('payments.rows', { n: tot.byStatus.held.count })}
                        icon="lock"
                        tone="warning"
                    />
                    <Stat
                        size="sm"
                        label={statusLabel('paying')}
                        value={formatNumber(tot.byStatus.paying.count)}
                        icon="alert"
                        tone={tot.byStatus.paying.count ? 'danger' : 'neutral'}
                    />
                    <Stat
                        size="sm"
                        label={statusLabel('unfunded')}
                        value={formatMoney(tot.byStatus.unfunded.owed)}
                        hint={t('payments.rows', { n: tot.byStatus.unfunded.count })}
                        icon="xCircle"
                        tone={tot.byStatus.unfunded.count ? 'danger' : 'neutral'}
                    />
                    <Stat
                        size="sm"
                        label={t('payments.cap_cut')}
                        value={formatMoney(tot.cut)}
                        hint={t('payments.capped_today', { n: tot.cappedToday })}
                        icon="minusCircle"
                    />
                    <Stat
                        size="sm"
                        label={statusLabel('forfeited')}
                        value={formatMoney(tot.byStatus.forfeited.owed)}
                        icon="x"
                    />
                </div>
            ) : null}

            {tot && tot.departments.length > 0 ? (
                <Card title={t('payments.by_department')} icon="building" padding="sm">
                    <ul className="payments-admin__depts">
                        {tot.departments.map(d => (
                            <li key={d.department}>
                                <strong>{deptLabel(d.department)}</strong>
                                <span className="cp-num">{formatMoney(d.paid - d.reclaimed)}</span>
                                <span className="payments-admin__soft">{`${d.share}%`}</span>
                                {d.unfunded > 0 ? (
                                    <Badge size="sm" tone="danger">
                                        {t('payments.unfunded_n', { n: d.unfunded })}
                                    </Badge>
                                ) : null}
                            </li>
                        ))}
                    </ul>
                </Card>
            ) : null}

            <div className="payments-admin__filters">
                <Field label={t('payments.col.status')}>
                    <Select value={status} onChange={pick(setStatus)} options={statusOptions} />
                </Field>
                <Field label={t('payments.col.department')}>
                    <Select value={department} onChange={pick(setDepartment)} options={deptOptions} />
                </Field>
                <Field label={t('payments.col.officer')}>
                    <OfficerPicker value={citizenid} onChange={c => pick(setCitizenid)(c)} />
                </Field>
                <DateRangeField value={range} onChange={pick(setRange)} />
                {status === 'unfunded' && department && data?.switches.unfundedRetry ? (
                    <Button size="sm" variant="danger" icon="refresh" onClick={() => void openBulkUnfunded()}>
                        {t('payments.retry_unfunded_all')}
                    </Button>
                ) : null}
            </div>

            {!data && loading ? <LoadingBlock /> : null}
            {!data && error ? <ErrorState error={error} onRetry={reload} /> : null}
            {data ? (
                <Card padding="none">
                    <Table
                        columns={columns}
                        rows={data.rows}
                        dense
                        empty={<EmptyState compact icon="creditCard" title={t('payments.empty')} />}
                        aria-label={t('ui.screen.admin_payments')}
                    />
                    <div className="payments-admin__foot">
                        <span className="payments-admin__soft">
                            {t('payments.total_rows', { n: data.total })}
                            {data.nextForfeitIn != null
                                ? ` · ${t('payments.next_forfeit', { n: Math.ceil(data.nextForfeitIn / 60) })}`
                                : ''}
                        </span>
                        <Pager page={data.page} pages={data.pages} onPage={setPage} />
                    </div>
                </Card>
            ) : null}

            <ResolveDialog
                row={resolving}
                onClose={() => setResolving(null)}
                onDone={() => {
                    setResolving(null);
                    reload();
                }}
            />
            {data && acting ? (
                <ActionDialog
                    key={`${acting.row.id}-${acting.kind}`}
                    row={acting.row}
                    kind={acting.kind}
                    view={data}
                    onClose={() => setActing(null)}
                    onDone={() => {
                        setActing(null);
                        reload();
                    }}
                />
            ) : null}
            {data ? (
                <ManualDialog
                    open={manual}
                    view={data}
                    onClose={() => setManual(false)}
                    onDone={() => {
                        setManual(false);
                        reload();
                    }}
                />
            ) : null}
            <ConfirmDialog
                open={!!bulkPreview}
                title={t('payments.retry_unfunded_all')}
                message={t('payments.action_msg.unfunded_all')}
                effect={
                    bulkPreview ? (
                        <>
                            <PreviewTable
                                columns={baseColumns.slice(1)}
                                rows={bulkPreview.effect.rows}
                                total={bulkPreview.effect.count}
                            />
                            <MoneyEffect
                                lines={bulkPreview.effect.departments.map(d => ({
                                    label: t('payments.balance_of', { department: d.label }),
                                    amount: d.owed,
                                    before: d.balance ?? undefined,
                                }))}
                                total={bulkPreview.effect.total}
                            />
                        </>
                    ) : null
                }
                typedWord={bulkPreview ? String(bulkPreview.effect.total) : undefined}
                tone="danger"
                reason={{ required: true, maxLength: REASON_MAX }}
                onConfirm={bulkRetry}
                onCancel={() => setBulkPreview(null)}
            />
            <Dialog
                open={!!exported}
                onClose={() => setExported(null)}
                title={t('payments.export_title')}
                size="lg"
                footer={
                    <>
                        <Button variant="ghost" onClick={() => setExported(null)}>
                            {t('common.close')}
                        </Button>
                        <Button variant="primary" icon="check" onClick={copy}>
                            {t('admin.audit.copy')}
                        </Button>
                    </>
                }
            >
                {exported ? (
                    <div className="payments-admin__export">
                        {exported.truncated ? (
                            <div className="payments-admin__warn">
                                {t('admin.audit.export_truncated', { n: formatNumber(exported.rows) })}
                            </div>
                        ) : null}
                        <textarea
                            ref={area}
                            readOnly
                            value={exported.csv}
                            spellCheck={false}
                            aria-label={t('payments.export_title')}
                        />
                    </div>
                ) : null}
            </Dialog>
        </Screen>
    );
}
