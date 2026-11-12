// The one Review queue: flagged runs and disputes in one table with a Type column, a filter (All / Flagged runs /

// The one Review queue: flagged runs and disputes in one table with a Type column, a filter (All / Flagged runs /
// Disputes) and one decide action for both. Used by the Supervisor UI (Department -> Review: the supervisor's
// department) and the Admin UI (Review -> Queue, all: every department, with Approve all rows of a run and Open the
// officer for a dispute about a failed run, whose approval awards points).
// Data: callback review:getQueue { all? } · action server:review:decide { type, id, decision, reason, all? }
// (modules/review/queue.lua). Every decision needs a reason and is audited. The Admin UI's queue also lists the
// correction batches that can still be undone, each with its Undo, and right after a Void offers Undo (Restore run;
// Config.AdminUi.reviewUndo). History opens one run's whole timeline (review:getRunHistory, RunHistory.tsx).

import { useEffect, useState } from 'react';
import {
    Badge,
    Button,
    ConfirmDialog,
    Dialog,
    EmptyState,
    Grid,
    IconButton,
    KeyValue,
    Money,
    Points,
    Row,
    ScreenStatus,
    Table,
    Tabs,
    TierBadge,
    type TableColumn,
} from '../../shared/components';
import { DecisionsBlock, PeopleBlock } from '../../hud/Debrief';
import { asArray } from '../../shared/data';
import { formatDateTime, formatDuration, formatMoney } from '../../shared/format';
import { useAction, usePush, useRequest } from '../../shared/hooks';
import { hasKey, t } from '../../shared/i18n';
import { applyReplyView } from '../../shared/replyView';
import { toast } from '../../shared/toast';
import { screenStateOf } from '../../shared/screenHeads';
import type { DisputeView, FlaggedRow, ReviewBatchItem, ReviewItem, ReviewQueueData } from '../../types/oversight';
import { RunHistoryDialog } from './RunHistory';
import {
    batchesOf,
    countsOf,
    decidePayload,
    decisionsOf,
    itemKey,
    itemsOf,
    runRowsOf,
    undoPayload,
    type ReviewDecision,
    type ReviewShow,
} from './reviewQueue';
import '../screens/ReviewQueue.css';

type Pending = { item: ReviewItem; decision: ReviewDecision } | { run: ReviewItem; rows: ReviewItem[] };
// an Undo waiting for its reason: a run voided here (its row id) or a correction batch
type Undo = { type: 'flag'; id: number; name: string; mission: string } | { type: 'batch'; batch: ReviewBatchItem };

function batchWhat(b: ReviewBatchItem): string {
    return Object.entries(b.filter ?? {})
        .filter(([, v]) => v !== null && v !== undefined && v !== '' && typeof v !== 'object')
        .map(([k, v]) => `${k}: ${String(v)}`)
        .join(' · ');
}

const flagLabel = (reason: string | null | undefined) =>
    reason && hasKey(`flag.${reason}`) ? t(`flag.${reason}`) : t('flag.flagged');
const noteLabel = (reason: string) => (hasKey(`flag.${reason}`) ? t(`flag.${reason}`) : reason);
const endLabel = (reason: string) => (hasKey(`sup.end.${reason}`) ? t(`sup.end.${reason}`) : reason);
const stateTone = (s: string) => (s === 'completed' ? 'success' : s === 'failed' ? 'danger' : 'grey');
const resultText = (state: string, endReason: string) =>
    state === 'completed' ? t(`sup.state.${state}`) : `${t(`sup.state.${state}`)} · ${endLabel(endReason)}`;
const cashLabel = (status: string) =>
    hasKey(`result.cash_status.${status}`) ? t(`result.cash_status.${status}`) : status;

function Officer({ name, callsign, dept }: { name: string; callsign: string | null; dept: string }) {
    return (
        <div className="oversight-rq-who">
            <span className="oversight-rq-who__name" title={name}>
                {name}
            </span>
            <span className="oversight-rq-who__sub">
                <Badge size="sm" variant="outline">
                    {dept}
                </Badge>
                <span>{callsign || t('common.no_callsign')}</span>
            </span>
        </div>
    );
}

function Mission({
    label,
    type,
    state,
    endReason,
    when,
}: {
    label: string;
    type: string;
    state: string;
    endReason: string;
    when?: number;
}) {
    return (
        <div className="oversight-rq-mission">
            <span className="oversight-rq-mission__name" title={label}>
                {label}
            </span>
            <span className="oversight-rq-mission__sub">
                <span>{type}</span>
                <Badge size="sm" tone={stateTone(state)}>
                    {t(`sup.state.${state}`)}
                </Badge>
                {state !== 'completed' ? <span title={endReason}>{endLabel(endReason)}</span> : null}
            </span>
            {when ? <span className="oversight-rq-mission__when cp-num">{formatDateTime(when)}</span> : null}
        </div>
    );
}

function FlagCell({ row }: { row: FlaggedRow }) {
    return (
        <div className="oversight-rq-flag">
            <Badge size="sm" tone="danger" variant="outline" icon="flag">
                {flagLabel(row.flagReason)}
            </Badge>
            {row.flagDetail ? (
                <span className="oversight-rq-flag__detail" title={row.flagDetail}>
                    {row.flagDetail}
                </span>
            ) : null}
            {row.voidPending ? (
                <Badge size="sm" tone="warning" variant="outline" icon="clock">
                    {t('sup.review.void_waiting', { name: row.voidPending.name ?? '-' })}
                </Badge>
            ) : null}
            {asArray(row.otherReasons).length ? (
                <span className="oversight-rq-flag__also">
                    {t('sup.review.also', { reasons: asArray(row.otherReasons).map(flagLabel).join(', ') })}
                </span>
            ) : null}
        </div>
    );
}

function FlagDetail({ row }: { row: FlaggedRow }) {
    return (
        <div className="oversight-rq-detail">
            <Row gap={2} wrap>
                <Badge tone="danger" variant="outline" icon="flag">
                    {flagLabel(row.flagReason)}
                </Badge>
                {asArray(row.otherReasons).map(r => (
                    <Badge key={r} tone="warning" variant="outline">
                        {flagLabel(r)}
                    </Badge>
                ))}
                <TierBadge tier={row.tier} size="sm" />
            </Row>
            <div className="oversight-rq-detail__box">
                <span className="oversight-rq-detail__label">{t('sup.review.detail.detail')}</span>
                <span>{row.flagDetail || t('sup.review.no_detail')}</span>
            </div>
            {asArray(row.notes).length ? (
                <div className="oversight-rq-detail__box oversight-rq-detail__box--note">
                    <span className="oversight-rq-detail__label">{t('sup.review.detail.notes')}</span>
                    {asArray(row.notes).map((n, i) => (
                        <span key={`${n.reason}-${i}`} className="oversight-rq-note">
                            {t('sup.review.note', { line: noteLabel(n.reason) })}
                            {n.detail ? <span className="oversight-rq-soft"> · {n.detail}</span> : null}
                        </span>
                    ))}
                </div>
            ) : null}
            <Grid cols={3} gap={3}>
                <KeyValue label={t('sup.review.detail.officer')}>{row.name}</KeyValue>
                <KeyValue label={t('sup.review.detail.mission')}>{row.missionLabel}</KeyValue>
                <KeyValue label={t('sup.review.detail.location')}>{row.location || '—'}</KeyValue>
                <KeyValue label={t('sup.review.detail.result')}>{resultText(row.state, row.endReason)}</KeyValue>
                <KeyValue label={t('sup.review.detail.participants')}>
                    <span className="cp-num">
                        {t('sup.review.participants_value', { n: row.participants, d: row.departments })}
                    </span>
                </KeyValue>
                <KeyValue label={t('sup.review.detail.duration')}>
                    <span className="cp-num">{formatDuration(row.durationS)}</span>
                </KeyValue>
                <KeyValue label={t('sup.review.detail.points')}>
                    <Points value={row.points} />
                </KeyValue>
                <KeyValue label={t('sup.review.detail.cash')}>
                    <Money amount={row.cash} /> <span className="oversight-rq-soft">{cashLabel(row.cashStatus)}</span>
                </KeyValue>
                <KeyValue label={t('sup.review.detail.when')}>
                    <span className="cp-num">{formatDateTime(row.createdAt)}</span>
                </KeyValue>
            </Grid>
            <div className="oversight-rq-uuid">{t('sup.review.detail.run', { id: row.runUuid, row: row.rowId })}</div>
        </div>
    );
}

function DisputeDetail({ row }: { row: DisputeView }) {
    return (
        <div className="oversight-rq-detail">
            <Row gap={2} wrap>
                <Badge tone={row.kind === 'voided' ? 'danger' : 'warning'}>{t(`admin.dispute.kind.${row.kind}`)}</Badge>
                {row.flagReason ? (
                    <Badge tone="danger" variant="outline" icon="flag">
                        {flagLabel(row.flagReason)}
                    </Badge>
                ) : null}
                <TierBadge tier={row.tier} size="sm" />
            </Row>
            <div className="oversight-rq-detail__box">
                <span className="oversight-rq-detail__label">{t('sup.review.detail.officer_reason')}</span>
                <span className="oversight-rq-quote">{row.reason}</span>
            </div>
            <Grid cols={3} gap={3}>
                <KeyValue label={t('sup.review.detail.officer')}>{row.name}</KeyValue>
                <KeyValue label={t('sup.review.detail.mission')}>{row.missionLabel}</KeyValue>
                <KeyValue label={t('sup.review.detail.result')}>{resultText(row.state, row.endReason)}</KeyValue>
                <KeyValue label={t('sup.review.detail.points')}>
                    <Points value={row.points} />
                </KeyValue>
                <KeyValue label={t('sup.review.detail.cash')}>
                    <Money amount={row.cash} /> <span className="oversight-rq-soft">{cashLabel(row.cashStatus)}</span>
                </KeyValue>
                <KeyValue label={t('sup.review.detail.filed')}>
                    <span className="cp-num">{formatDateTime(row.createdAt)}</span>
                </KeyValue>
            </Grid>
            {row.decisions ? <DecisionsBlock decisions={row.decisions} detail /> : null}
            {row.people ? <PeopleBlock people={row.people} /> : null}
            <div className="oversight-rq-uuid">{t('sup.review.detail.run', { id: row.runUuid, row: row.rowId })}</div>
        </div>
    );
}

const DECISION_ICON = { approve: 'check', void: 'xCircle', reject: 'x' } as const;

function TypeCell({ item }: { item: ReviewItem }) {
    if (item.type === 'flag') return <FlagCell row={item} />;
    return (
        <div className="oversight-rq-flag">
            <Badge size="sm" tone={item.kind === 'voided' ? 'danger' : 'warning'} icon="inbox">
                {t('sup.review.type.dispute', { kind: t(`admin.dispute.kind.${item.kind}`) })}
            </Badge>
            <span className="oversight-rq-quote oversight-rq-clamp" title={item.reason}>
                {item.reason}
            </span>
        </div>
    );
}

export function ReviewQueuePanel({
    all,
    show: shown,
    onOpenOfficer,
}: {
    all?: boolean;
    show?: ReviewShow;
    onOpenOfficer?: (citizenid: string) => void;
}) {
    const { data, loading, error, refetch, setData } = useRequest<ReviewQueueData>(
        'review:getQueue',
        all ? { all: true } : {},
        { pollMs: all ? 60000 : 30000 },
    );
    // another reviewer's decision pushes this supervisor's fresh queue (the Admin UI's queue polls)
    usePush<ReviewQueueData | null>('reviewQueue', q => {
        if (!all && q && typeof q === 'object') setData(q);
    });
    const { run, busy } = useAction();
    const [show, setShow] = useState<ReviewShow>(shown ?? 'all');
    useEffect(() => setShow(shown ?? 'all'), [shown]);
    const [pending, setPending] = useState<Pending | null>(null);
    const [detail, setDetail] = useState<ReviewItem | null>(null);
    const [history, setHistory] = useState<string | null>(null);
    // the last run this admin voided here (Undo restores it), and an Undo waiting for its reason
    const [lastVoid, setLastVoid] = useState<{ id: number; name: string; mission: string } | null>(null);
    const [undo, setUndo] = useState<Undo | null>(null);

    const items = asArray(data?.items);
    const counts = countsOf(items);
    const rows = itemsOf(items, show);
    const batches = batchesOf(items, show);
    // a dispute about a failed run is approved with points, on the officer's page (Admin UI)
    const opensOfficer = (i: ReviewItem) => !!onOpenOfficer && i.type === 'dispute' && i.kind === 'failed';
    const canDecide = (i: ReviewItem) => i.type === 'flag' || i.canHandle !== false;

    const decide = async (reason: string) => {
        if (!pending) return;
        const payload =
            'item' in pending
                ? decidePayload(pending.item, pending.decision, reason, all)
                : { type: 'flag', runUuid: pending.run.runUuid, decision: 'approve', reason, all: true };
        const res = await run<{ pending?: boolean; queue?: ReviewQueueData }>('server:review:decide', payload);
        if (res.ok) {
            // the department wants a second supervisor's Void (the first only marks the row pending)
            const waits = res.data?.pending === true;
            const key =
                'item' in pending
                    ? pending.item.type === 'flag'
                        ? pending.decision === 'approve'
                            ? 'sup.review.approved'
                            : 'sup.review.voided'
                        : pending.decision === 'approve'
                          ? 'sup.review.dispute_approved'
                          : 'sup.review.dispute_rejected'
                    : 'ui.admin_officers.done';
            toast(waits ? 'info' : 'success', t(waits ? 'sup.review.void_pending' : key));
            const voided = 'item' in pending && pending.item.type === 'flag' && pending.decision === 'void';
            if (voided && !waits && 'item' in pending && data?.canUndo) {
                setLastVoid({
                    id: Number(pending.item.id),
                    name: pending.item.name,
                    mission: pending.item.missionLabel,
                });
            }
        }
        setPending(null);
        setDetail(null);
        // the reply carries the fresh queue (an older server: ask for it)
        if (res.ok) applyReplyView<ReviewQueueData>(res.data, 'queue', setData, () => void refetch());
    };

    const doUndo = async (reason: string) => {
        if (!undo) return;
        const payload =
            undo.type === 'flag' ? undoPayload('flag', undo.id, reason) : undoPayload('batch', undo.batch.id, reason);
        const res = await run<{ queue?: ReviewQueueData }>('server:review:decide', payload, {
            success: 'sup.review.undo_done',
        });
        setUndo(null);
        if (res.ok) {
            if (undo.type === 'flag') setLastVoid(null);
            applyReplyView<ReviewQueueData>(res.data, 'queue', setData, () => void refetch());
        }
    };

    const actionsOf = (i: ReviewItem, size: 'sm' | 'md') =>
        i.type === 'dispute' && opensOfficer(i) ? (
            <Button size={size} variant="secondary" icon="user" onClick={() => onOpenOfficer?.(i.citizenid)}>
                {t('sup.review.open_officer')}
            </Button>
        ) : (
            decisionsOf(i).map(d => (
                <Button
                    key={d}
                    size={size}
                    variant={d === 'approve' ? (size === 'md' ? 'primary' : 'secondary') : 'danger'}
                    icon={DECISION_ICON[d]}
                    disabled={!canDecide(i)}
                    onClick={() => setPending({ item: i, decision: d })}
                >
                    {t(`sup.review.${d}`)}
                </Button>
            ))
        );

    const columns: TableColumn<ReviewItem>[] = [
        {
            key: 'officer',
            header: t('sup.review.col.officer'),
            width: 150,
            render: r => <Officer name={r.name} callsign={r.callsign} dept={r.departmentShort} />,
        },
        {
            key: 'mission',
            header: t('sup.review.col.mission'),
            render: r => (
                <Mission
                    label={r.missionLabel}
                    type={r.missionTypeLabel}
                    state={r.state}
                    endReason={r.endReason}
                    when={r.createdAt}
                />
            ),
        },
        { key: 'type', header: t('sup.review.col.type'), width: 190, render: r => <TypeCell item={r} /> },
        {
            key: 'held',
            header: t('sup.review.col.held'),
            width: 96,
            numeric: true,
            render: r => (
                <div className="oversight-rq-held">
                    <Points value={r.points} />
                    <Money amount={r.cash} />
                </div>
            ),
        },
        {
            key: 'actions',
            header: '',
            width: 250,
            align: 'right',
            render: r => {
                const runRows = all ? runRowsOf(items, r) : [];
                return (
                    <Row gap={1} justify="flex-end" wrap>
                        <IconButton icon="eye" size="sm" label={t('sup.review.details')} onClick={() => setDetail(r)} />
                        <IconButton
                            icon="clock"
                            size="sm"
                            label={t('sup.history.open')}
                            onClick={() => setHistory(r.runUuid)}
                        />
                        {actionsOf(r, 'sm')}
                        {runRows.length > 1 ? (
                            <Button
                                size="sm"
                                variant="ghost"
                                icon="check"
                                onClick={() => setPending({ run: r, rows: runRows })}
                            >
                                {t('ui.admin_officers.flagged.approve_run', { n: runRows.length })}
                            </Button>
                        ) : null}
                    </Row>
                );
            },
        },
    ];

    const filters = [
        { key: 'all' as const, label: t('sup.review.show_all'), icon: 'list' as const },
        ...(data?.canReview !== false
            ? [{ key: 'flag' as const, label: t('sup.review.tab.flagged'), icon: 'flag' as const }]
            : []),
        ...(data?.canHandle !== false
            ? [{ key: 'dispute' as const, label: t('sup.review.tab.disputes'), icon: 'inbox' as const }]
            : []),
        ...(counts.batch > 0
            ? [{ key: 'batch' as const, label: t('sup.review.tab.batches'), icon: 'undo' as const }]
            : []),
    ].map(f => ({ ...f, badge: counts[f.key] || undefined }));

    const batchColumns: TableColumn<ReviewBatchItem>[] = [
        {
            key: 'kind',
            header: t('sup.review.col.type'),
            width: 190,
            render: b => (
                <Badge size="sm" tone="danger" variant="outline" icon="undo">
                    {t(`ui.admin_officers.batch.${b.kind}`)}
                </Badge>
            ),
        },
        { key: 'what', header: t('ui.admin_officers.corrections.what'), render: batchWhat },
        {
            key: 'rows',
            header: t('ui.admin_officers.corrections.rows'),
            width: 80,
            numeric: true,
            render: b => b.total,
        },
        {
            key: 'by',
            header: t('ui.admin_officers.corrections.by'),
            width: 150,
            render: b => (
                <span>
                    {b.actor} <span className="oversight-rq-soft cp-num">{formatDateTime(b.createdAt)}</span>
                </span>
            ),
        },
        {
            key: 'actions',
            header: '',
            width: 120,
            align: 'right',
            render: b =>
                data?.canUndoBatch ? (
                    <Button
                        size="sm"
                        variant="secondary"
                        icon="undo"
                        disabled={busy}
                        onClick={() => setUndo({ type: 'batch', batch: b })}
                    >
                        {t('sup.review.undo')}
                    </Button>
                ) : null,
        },
    ];

    const loadState = screenStateOf(!!data, loading, error);
    let confirmTitle = '';
    let confirmMessage: string | null = null;
    if (pending && 'item' in pending) {
        const { item, decision } = pending;
        const vars = { name: item.name, mission: item.missionLabel };
        confirmTitle = t(
            item.type === 'flag'
                ? decision === 'approve'
                    ? 'sup.review.approve_title'
                    : 'sup.review.void_title'
                : decision === 'approve'
                  ? 'sup.review.dispute_approve_title'
                  : 'sup.review.dispute_reject_title',
        );
        confirmMessage = t(
            item.type === 'flag'
                ? decision === 'approve'
                    ? 'sup.review.approve_message'
                    : 'sup.review.void_message'
                : decision === 'approve'
                  ? 'sup.review.dispute_approve_message'
                  : 'sup.review.dispute_reject_message',
            vars,
        );
    } else if (pending) {
        confirmTitle = t('ui.admin_officers.flagged.approve_run_title');
        confirmMessage = t('ui.admin_officers.flagged.approve_run_message', {
            n: pending.rows.length,
            cash: formatMoney(pending.rows.reduce((sum, x) => sum + (Number(x.cash) || 0), 0)),
        });
    }
    const destructive = !!pending && 'item' in pending && pending.decision !== 'approve';

    return (
        <>
            {filters.length > 2 ? (
                <Tabs
                    items={filters}
                    value={show}
                    onChange={k => setShow(k as ReviewShow)}
                    aria-label={t('sup.review.col.type')}
                />
            ) : null}
            {loadState !== 'ready' && loadState !== 'stale' ? (
                <ScreenStatus state={loadState} error={error} onRetry={() => void refetch()} />
            ) : (
                <>
                    {loadState === 'stale' ? (
                        <ScreenStatus state="stale" error={error} onRetry={() => void refetch()} />
                    ) : null}
                    {show !== 'batch' ? (
                        <Table
                            columns={columns}
                            rows={rows}
                            rowKey={itemKey}
                            loading={loading}
                            className="oversight-rq-table"
                            empty={
                                <EmptyState
                                    icon="shieldCheck"
                                    title={t('sup.review.empty_title')}
                                    text={t(all ? 'sup.review.empty_text_all' : 'sup.review.empty_text')}
                                />
                            }
                            aria-label={t('sup.review.tab.queue')}
                        />
                    ) : null}
                </>
            )}
            {lastVoid ? (
                <Row gap={2} className="oversight-rq-undo">
                    <span>{t('sup.review.undo_void_text', { name: lastVoid.name, mission: lastVoid.mission })}</span>
                    <Button
                        size="sm"
                        variant="secondary"
                        icon="undo"
                        disabled={busy}
                        onClick={() => setUndo({ type: 'flag', ...lastVoid })}
                    >
                        {t('sup.review.undo')}
                    </Button>
                    <IconButton icon="x" size="sm" label={t('common.close')} onClick={() => setLastVoid(null)} />
                </Row>
            ) : null}
            {batches.length ? (
                <Table
                    columns={batchColumns}
                    rows={batches}
                    rowKey={itemKey}
                    className="oversight-rq-table"
                    aria-label={t('sup.review.tab.batches')}
                />
            ) : null}
            <div className="oversight-rq-note">{t('sup.review.own_rule')}</div>
            <RunHistoryDialog runUuid={history} onClose={() => setHistory(null)} />
            <ConfirmDialog
                open={!!undo}
                tone="danger"
                title={t('sup.review.undo_title')}
                message={
                    undo
                        ? undo.type === 'flag'
                            ? t('sup.review.undo_void_message', { name: undo.name, mission: undo.mission })
                            : t('sup.review.undo_batch_message', {
                                  kind: t(`ui.admin_officers.batch.${undo.batch.kind}`),
                                  n: undo.batch.total,
                              })
                        : null
                }
                confirmLabel={t('sup.review.undo')}
                reason={{ required: true, label: t('common.reason'), maxLength: 255 }}
                onConfirm={doUndo}
                onCancel={() => setUndo(null)}
                busy={busy}
            />

            <Dialog
                open={!!detail}
                onClose={() => setDetail(null)}
                size="lg"
                title={
                    detail
                        ? detail.type === 'flag'
                            ? t('sup.review.detail_title')
                            : t('sup.review.dispute_detail_title')
                        : ''
                }
                description={detail ? `${detail.name} · ${detail.missionLabel}` : undefined}
                footer={
                    detail ? (
                        <>
                            <Button variant="ghost" onClick={() => setDetail(null)}>
                                {t('common.close')}
                            </Button>
                            {actionsOf(detail, 'md')}
                        </>
                    ) : null
                }
            >
                {detail ? detail.type === 'flag' ? <FlagDetail row={detail} /> : <DisputeDetail row={detail} /> : null}
            </Dialog>

            <ConfirmDialog
                open={!!pending}
                tone={destructive ? 'danger' : 'primary'}
                title={confirmTitle}
                message={confirmMessage}
                confirmLabel={pending && 'item' in pending ? t(`sup.review.${pending.decision}`) : undefined}
                reason={{
                    required: true,
                    label: t('common.reason'),
                    placeholder: t('sup.review.reason_placeholder'),
                    maxLength: 255,
                }}
                onConfirm={decide}
                onCancel={() => setPending(null)}
                busy={busy}
            />
        </>
    );
}
