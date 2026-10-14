// Admin UI · Payouts (screen key 'admin_payouts', title key 'ui.screen.admin_payouts').

import { useEffect, useMemo, useState } from 'react';
import {
    Badge,
    Button,
    Card,
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
    SearchInput,
    SegmentedControl,
    Table,
    Tabs,
    Textarea,
    Toggle,
} from '../../shared/components';
import type { TabItem, TableColumn } from '../../shared/components';
import { cx } from '../../shared/cx';
import { formatDateTime, formatMoney } from '../../shared/format';
import { useAction, useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { request } from '../../shared/nui';
import { toast } from '../../shared/toast';
import type { PayoutAdjustPreview, PayoutAdjustRow } from '../../types/admin_economy';
import type { AdminPayoutMission, AdminPayoutType, AdminPayoutsView } from '../../types/economy';
import { PreviewTable, useAdminAction } from '../components/kit';
import './Payouts.css';

const REASON_MAX = 255;

type TabKey = 'types' | 'missions';

// What an edit targets (a type or a mission), with the numbers the dialogs show.
interface Target {
    kind: 'type' | 'mission';
    id: string;
    label: string;
    current: number;
    // Value an admin payout replaces (config payout for a type, type/event payout for a mission).
    fallback: number;
    hasAdminPayout: boolean;
    // types only: the payout is set and still open to supervisors
    unlocked?: boolean;
}

function typeTarget(r: AdminPayoutType): Target {
    return {
        kind: 'type',
        id: r.key,
        label: r.label,
        current: r.amount,
        fallback: r.default,
        hasAdminPayout: r.adminLocked,
        unlocked: r.stored && !r.adminLocked,
    };
}

function missionTarget(r: AdminPayoutMission): Target {
    return {
        kind: 'mission',
        id: r.id,
        label: r.label,
        current: r.base,
        fallback: r.fallback,
        hasAdminPayout: r.missionPayout !== null && r.missionPayout !== undefined,
    };
}

function Stars({ n }: { n: number }) {
    const count = Math.max(1, Math.min(3, Math.round(n || 1)));
    return (
        <span
            className="economy-admin-pay-stars"
            aria-label={t('admin.payouts.stars', { n: count })}
            title={t('admin.payouts.stars', { n: count })}
        >
            {[1, 2, 3].map(i => (
                <span key={i} className={cx('economy-admin-pay-star', i <= count && 'is-on')}>
                    ★
                </span>
            ))}
        </span>
    );
}

function PermanentBadge() {
    return (
        <Badge tone="accent" variant="solid" icon="lock" size="sm">
            {t('admin.payouts.permanent')}
        </Badge>
    );
}

function TypeSource({ r }: { r: AdminPayoutType }) {
    if (r.adminLocked) return <PermanentBadge />;
    if (r.stored)
        return (
            <Badge tone="neutral" size="sm" icon="user">
                {t('admin.payouts.src_supervisor')}
            </Badge>
        );
    return (
        <Badge tone="neutral" variant="outline" size="sm">
            {t('admin.payouts.src_config')}
        </Badge>
    );
}

function MissionSource({ r }: { r: AdminPayoutMission }) {
    if (r.payoutSource === 'admin') return <PermanentBadge />;
    if (r.payoutSource === 'event')
        return (
            <Badge tone="warning" size="sm" icon="star">
                {t('admin.payouts.src_event')}
            </Badge>
        );
    return (
        <Badge tone="neutral" variant="outline" size="sm">
            {t('admin.payouts.src_type')}
        </Badge>
    );
}

function ChangedBy({ name, at }: { name: string | null | undefined; at: number | null | undefined }) {
    if (!name && !at) return <span className="economy-admin-pay-muted">–</span>;
    return (
        <span className="economy-admin-pay-changed">
            {name ? <span className="economy-admin-pay-changed__name">{name}</span> : null}
            {at ? <span className="economy-admin-pay-changed__at cp-num">{formatDateTime(at)}</span> : null}
        </span>
    );
}

function SetDialog({
    target,
    view,
    onClose,
    onDone,
}: {
    target: Target | null;
    view: AdminPayoutsView | null;
    onClose: () => void;
    onDone: () => void;
}) {
    const [amount, setAmount] = useState<number | null>(null);
    const [valid, setValid] = useState(true);
    const [reason, setReason] = useState('');
    const [unlock, setUnlock] = useState(false);
    const { run, busy } = useAction();
    const lo = view?.limits?.min ?? 0;
    const hi = view?.limits?.max ?? 25000;
    const needReason = view?.requireReason !== false;

    useEffect(() => {
        if (target) {
            setAmount(target.current);
            setValid(true);
            setReason('');
            setUnlock(false);
        }
    }, [target]);

    if (!target) return null;
    const inRange = amount !== null && amount >= lo && amount <= hi;
    const unchanged = amount === target.current && (unlock ? !!target.unlocked : target.hasAdminPayout);
    const canSave = valid && inRange && !unchanged && (!needReason || reason.trim().length > 0) && !busy;

    const save = async () => {
        if (!canSave || amount === null) return;
        const name = target.kind === 'type' ? 'server:admin:setTypePayout' : 'server:admin:setMissionPayout';
        const payload =
            target.kind === 'type'
                ? { type: target.id, amount, reason: reason.trim(), unlock }
                : { missionId: target.id, amount, reason: reason.trim() };
        const res = await run(name, payload, {
            success: 'admin.payouts.saved',
            successVars: { name: target.label, amount: formatMoney(amount) },
        });
        if (res.ok) onDone();
    };

    return (
        <Dialog
            open={!!target}
            onClose={busy ? () => undefined : onClose}
            title={
                target.kind === 'type'
                    ? t('admin.payouts.set_type_title', { name: target.label })
                    : t('admin.payouts.set_mission_title', { name: target.label })
            }
            description={t('admin.payouts.set_desc')}
            size="md"
            footer={
                <>
                    <Button variant="ghost" onClick={onClose} disabled={busy}>
                        {t('common.cancel')}
                    </Button>
                    <Button
                        variant="primary"
                        icon={unlock ? 'users' : 'lock'}
                        onClick={save}
                        loading={busy}
                        disabled={!canSave}
                    >
                        {t('admin.payouts.set_confirm')}
                    </Button>
                </>
            }
        >
            <div className="economy-admin-pay-edit">
                <div className="economy-admin-pay-edit__facts">
                    <KeyValue label={t('admin.payouts.current')}>
                        <Money amount={target.current} />
                    </KeyValue>
                    <KeyValue
                        label={
                            target.kind === 'type' ? t('admin.payouts.col_default') : t('admin.payouts.without_admin')
                        }
                    >
                        <Money amount={target.fallback} />
                    </KeyValue>
                    <KeyValue label={t('admin.payouts.limits')}>
                        <span className="cp-num">{`${formatMoney(lo)}–${formatMoney(hi)}`}</span>
                    </KeyValue>
                </div>
                <Field label={t('admin.payouts.new_amount')} required>
                    <NumberInput
                        value={amount}
                        onChange={setAmount}
                        min={lo}
                        max={hi}
                        step={50}
                        prefix="$"
                        formatRange={formatMoney}
                        onValidityChange={setValid}
                        aria-label={t('admin.payouts.new_amount')}
                    />
                </Field>
                <Field
                    label={t('common.reason')}
                    required={needReason}
                    hint={needReason ? undefined : t('common.optional')}
                >
                    <Textarea
                        value={reason}
                        onChange={setReason}
                        maxLength={REASON_MAX}
                        rows={3}
                        placeholder={t('admin.payouts.reason_placeholder')}
                    />
                </Field>
                {target.kind === 'type' ? (
                    <Toggle
                        checked={unlock}
                        onChange={setUnlock}
                        label={t('admin.payouts.unlock')}
                        description={t('admin.payouts.unlock_desc')}
                    />
                ) : null}
                <div className="economy-admin-pay-review" aria-live="polite">
                    <span className="economy-admin-pay-review__label">{target.label}</span>
                    <span className="economy-admin-pay-review__change cp-num">
                        <span className="economy-admin-pay-review__old">{formatMoney(target.current)}</span>
                        <Icon name="chevronRight" size={14} />
                        <strong>{amount === null ? '–' : formatMoney(amount)}</strong>
                    </span>
                    {unlock ? (
                        <Badge tone="neutral" size="sm" icon="users">
                            {t('admin.payouts.open_to_supervisors')}
                        </Badge>
                    ) : (
                        <PermanentBadge />
                    )}
                </div>
                <div className="economy-admin-pay-note">
                    <Icon name="info" size={14} />
                    <span>
                        {target.kind === 'type' ? t('admin.payouts.type_note') : t('admin.payouts.mission_note')}
                    </span>
                </div>
            </div>
        </Dialog>
    );
}

// Adjust all: one percentage or amount for every type payout and/or admin mission payout, previewed old → new
// (each value clamped to the payout range), typed ADJUST.
function AdjustDialog({ open, onClose, onDone }: { open: boolean; onClose: () => void; onDone: () => void }) {
    const [mode, setMode] = useState<'pct' | 'amount'>('pct');
    const [value, setValue] = useState<number | null>(10);
    const [scope, setScope] = useState<'types' | 'missions' | 'both'>('types');
    const [lockTypes, setLockTypes] = useState(false);
    const [preview, setPreview] = useState<PayoutAdjustPreview | null>(null);
    const { run } = useAdminAction();

    const load = async () => {
        if (value === null) return;
        const res = await request<PayoutAdjustPreview>('admin:previewPayoutAdjust', { mode, value, scope });
        if (res.ok && res.data) setPreview(res.data);
        else toast('error', t(res.error || 'err.internal'));
    };
    const apply = async (reason: string, typed: string) => {
        if (!preview) return;
        const res = await run<{ changed: number }>(
            'server:admin:adjustAllPayouts',
            { mode, value, scope, lockTypes, reason, confirm: typed, previewToken: preview.previewToken },
            { success: 'admin.payouts.adjusted' },
        );
        setPreview(null);
        if (res.ok) onDone();
    };
    const columns: TableColumn<PayoutAdjustRow>[] = [
        { key: 'label', header: t('admin.payouts.col_type'), render: r => r.label },
        { key: 'old', header: t('admin.payouts.current'), numeric: true, render: r => <Money amount={r.old} /> },
        { key: 'new', header: t('admin.payouts.new_amount'), numeric: true, render: r => <Money amount={r.new} /> },
    ];

    return (
        <>
            <Dialog
                open={open && !preview}
                onClose={onClose}
                title={t('admin.payouts.adjust_title')}
                description={t('admin.payouts.adjust_desc')}
                size="md"
                footer={
                    <>
                        <Button variant="ghost" onClick={onClose}>
                            {t('common.cancel')}
                        </Button>
                        <Button variant="primary" icon="eye" disabled={value === null} onClick={() => void load()}>
                            {t('admin.payouts.adjust_preview')}
                        </Button>
                    </>
                }
            >
                <div className="economy-admin-pay-edit">
                    <SegmentedControl
                        items={[
                            { key: 'pct', label: t('admin.payouts.adjust_pct') },
                            { key: 'amount', label: t('admin.payouts.adjust_amount') },
                        ]}
                        value={mode}
                        onChange={setMode}
                        size="sm"
                        aria-label={t('admin.payouts.adjust_title')}
                    />
                    <Field
                        label={mode === 'pct' ? t('admin.payouts.adjust_pct') : t('admin.payouts.adjust_amount')}
                        required
                    >
                        <NumberInput
                            value={value}
                            onChange={setValue}
                            min={mode === 'pct' ? -90 : -100000}
                            max={mode === 'pct' ? 500 : 100000}
                            suffix={mode === 'pct' ? '%' : undefined}
                            prefix={mode === 'amount' ? '$' : undefined}
                        />
                    </Field>
                    <SegmentedControl
                        items={[
                            { key: 'types', label: t('admin.payouts.tab_types') },
                            { key: 'missions', label: t('admin.payouts.adjust_missions') },
                            { key: 'both', label: t('admin.payouts.adjust_both') },
                        ]}
                        value={scope}
                        onChange={setScope}
                        size="sm"
                        aria-label={t('admin.payouts.adjust_scope')}
                    />
                    {scope !== 'missions' ? (
                        <Toggle
                            checked={lockTypes}
                            onChange={setLockTypes}
                            label={t('admin.payouts.adjust_lock')}
                            description={t('admin.payouts.adjust_lock_desc')}
                        />
                    ) : null}
                </div>
            </Dialog>
            <ConfirmDialog
                open={!!preview}
                title={t('admin.payouts.adjust_title')}
                message={t('admin.payouts.adjust_confirm')}
                effect={
                    preview ? <PreviewTable columns={columns} rows={preview.effect.rows} rowKey={r => r.key} /> : null
                }
                typedWord="ADJUST"
                tone="danger"
                reason={{ required: true, maxLength: REASON_MAX }}
                onConfirm={apply}
                onCancel={() => setPreview(null)}
            />
        </>
    );
}

export default function AdminPayouts() {
    const { data, loading, error, refetch } = useRequest<AdminPayoutsView>(
        'admin:getPayouts',
        {},
        { pushTopic: 'payouts' },
    );
    const [tab, setTab] = useState<TabKey>('types');
    const [query, setQuery] = useState('');
    const [typeFilter, setTypeFilter] = useState<string>('all');
    const [editing, setEditing] = useState<Target | null>(null);
    const [clearing, setClearing] = useState<Target | null>(null);
    const [adjusting, setAdjusting] = useState(false);
    const [unlocking, setUnlocking] = useState<Target | null>(null);
    const { run } = useAction();

    const unlockTarget = async (reason: string) => {
        if (!unlocking) return;
        const res = await run(
            'server:admin:setTypePayout',
            { type: unlocking.id, amount: unlocking.current, unlock: true, reason },
            { success: 'admin.payouts.unlocked', successVars: { name: unlocking.label } },
        );
        if (res.ok) {
            setUnlocking(null);
            void refetch();
        }
    };

    const types = useMemo(() => (Array.isArray(data?.types) ? data!.types : []), [data]);
    const missions = useMemo(() => (Array.isArray(data?.missions) ? data!.missions : []), [data]);
    const adminCount = missions.filter(m => m.payoutSource === 'admin').length;
    const lockedTypes = types.filter(ty => ty.adminLocked).length;

    const filtered = useMemo(() => {
        const q = query.trim().toLowerCase();
        return missions.filter(m => {
            if (typeFilter === 'event' && !m.isBoss) return false;
            if (typeFilter === 'admin' && m.payoutSource !== 'admin') return false;
            if (
                typeFilter !== 'all' &&
                typeFilter !== 'event' &&
                typeFilter !== 'admin' &&
                (m.type !== typeFilter || m.isBoss)
            )
                return false;
            if (!q) return true;
            return m.label.toLowerCase().includes(q) || m.id.toLowerCase().includes(q);
        });
    }, [missions, query, typeFilter]);

    const tabs: TabItem<TabKey>[] = [
        { key: 'types', label: t('admin.payouts.tab_types'), icon: 'layers', badge: types.length || undefined },
        { key: 'missions', label: t('admin.payouts.tab_missions'), icon: 'list', badge: missions.length || undefined },
    ];

    const filterItems = [
        { key: 'all', label: t('admin.payouts.filter_all') },
        ...types.map(ty => ({ key: ty.key, label: ty.label })),
        { key: 'event', label: t('admin.payouts.filter_event') },
        { key: 'admin', label: t('admin.payouts.filter_admin') },
    ];

    const clearTarget = async (reason: string) => {
        if (!clearing) return;
        const name = clearing.kind === 'type' ? 'server:admin:setTypePayout' : 'server:admin:setMissionPayout';
        const payload =
            clearing.kind === 'type'
                ? { type: clearing.id, amount: null, clear: true, reason }
                : { missionId: clearing.id, amount: null, clear: true, reason };
        const res = await run(name, payload, {
            success: 'admin.payouts.cleared',
            successVars: { name: clearing.label },
        });
        if (res.ok) {
            setClearing(null);
            void refetch();
        }
    };

    const typeColumns: TableColumn<AdminPayoutType>[] = [
        {
            key: 'label',
            header: t('admin.payouts.col_type'),
            render: r => (
                <span className="economy-admin-pay-name">
                    <span className="economy-admin-pay-name__label">{r.label}</span>
                    <span className="economy-admin-pay-name__sub">
                        {r.missions === 1
                            ? t('admin.payouts.type_missions_one')
                            : t('admin.payouts.type_missions', { n: r.missions })}
                    </span>
                </span>
            ),
        },
        {
            key: 'points',
            header: t('admin.payouts.col_points'),
            numeric: true,
            width: 80,
            render: r => <span className="cp-num">{r.points}</span>,
        },
        {
            key: 'amount',
            header: t('admin.payouts.col_base'),
            numeric: true,
            render: r => <Money amount={r.amount} className="economy-admin-pay-amount" />,
        },
        {
            key: 'default',
            header: t('admin.payouts.col_default'),
            numeric: true,
            render: r => <Money amount={r.default} className="economy-admin-pay-muted" />,
        },
        {
            key: 'source',
            header: t('admin.payouts.col_source'),
            render: r => (
                <span className="economy-admin-pay-source">
                    <TypeSource r={r} />
                    {r.outOfRange ? (
                        <Badge tone="danger" size="sm" icon="alert">
                            {t('admin.payouts.out_of_range')}
                        </Badge>
                    ) : null}
                </span>
            ),
        },
        {
            key: 'changed',
            header: t('admin.payouts.col_changed'),
            render: r =>
                r.stored ? (
                    <ChangedBy name={r.updatedByName ?? r.updatedBy} at={r.updatedAt} />
                ) : (
                    <ChangedBy name={null} at={null} />
                ),
        },
        {
            key: 'actions',
            header: '',
            align: 'right',
            width: 150,
            render: r => (
                <span className="economy-admin-pay-actions">
                    <Button size="sm" variant="secondary" icon="edit" onClick={() => setEditing(typeTarget(r))}>
                        {t('admin.payouts.set')}
                    </Button>
                    {r.adminLocked ? (
                        <IconButton
                            size="sm"
                            variant="ghost"
                            icon="users"
                            label={t('admin.payouts.unlock')}
                            onClick={() => setUnlocking(typeTarget(r))}
                        />
                    ) : null}
                    <IconButton
                        size="sm"
                        variant="ghost"
                        icon="trash"
                        label={r.stored ? t('admin.payouts.clear') : t('admin.payouts.nothing_to_clear')}
                        disabled={!r.stored}
                        onClick={() => setClearing(typeTarget(r))}
                    />
                </span>
            ),
        },
    ];

    const missionColumns: TableColumn<AdminPayoutMission>[] = [
        {
            key: 'label',
            header: t('admin.payouts.col_mission'),
            render: r => (
                <span className="economy-admin-pay-name">
                    <span className="economy-admin-pay-name__label">
                        {r.label}
                        {r.source === 'custom' ? (
                            <Badge tone="primary" size="sm">
                                {t('admin.payouts.custom')}
                            </Badge>
                        ) : null}
                        {r.missing ? (
                            <Badge tone="danger" size="sm" icon="alert">
                                {t('admin.payouts.missing')}
                            </Badge>
                        ) : !r.enabled ? (
                            <Badge tone="neutral" size="sm">
                                {t('admin.payouts.disabled')}
                            </Badge>
                        ) : null}
                    </span>
                    <span className="economy-admin-pay-name__sub cp-num">{r.id}</span>
                </span>
            ),
        },
        {
            key: 'type',
            header: t('admin.payouts.col_type'),
            render: r =>
                r.isBoss ? (
                    <Badge tone="warning" size="sm" icon="star">
                        {t('admin.payouts.boss')}
                    </Badge>
                ) : (
                    <span>{r.typeLabel ?? '–'}</span>
                ),
        },
        { key: 'difficulty', header: t('admin.payouts.col_stars'), width: 90, render: r => <Stars n={r.difficulty} /> },
        {
            key: 'base',
            header: t('admin.payouts.col_base'),
            numeric: true,
            render: r => <Money amount={r.base} className="economy-admin-pay-amount" />,
        },
        {
            key: 'source',
            header: t('admin.payouts.col_source'),
            render: r => (
                <span className="economy-admin-pay-source">
                    <MissionSource r={r} />
                    {r.outOfRange ? (
                        <Badge tone="danger" size="sm" icon="alert">
                            {t('admin.payouts.out_of_range')}
                        </Badge>
                    ) : null}
                    {r.payoutSource === 'admin' && !r.missing ? (
                        <span className="economy-admin-pay-muted cp-num" title={t('admin.payouts.without_admin')}>
                            {t('admin.payouts.instead_of', { amount: formatMoney(r.fallback) })}
                        </span>
                    ) : null}
                </span>
            ),
        },
        {
            key: 'actions',
            header: '',
            align: 'right',
            width: 110,
            render: r => (
                <span className="economy-admin-pay-actions">
                    <Button
                        size="sm"
                        variant="secondary"
                        icon="edit"
                        disabled={r.missing}
                        onClick={() => setEditing(missionTarget(r))}
                    >
                        {t('admin.payouts.set')}
                    </Button>
                    <IconButton
                        size="sm"
                        variant="ghost"
                        icon="trash"
                        label={
                            r.payoutSource === 'admin' ? t('admin.payouts.clear') : t('admin.payouts.nothing_to_clear')
                        }
                        disabled={r.payoutSource !== 'admin'}
                        onClick={() => setClearing(missionTarget(r))}
                    />
                </span>
            ),
        },
    ];

    const clearMessage = clearing
        ? clearing.kind === 'type'
            ? t('admin.payouts.clear_type_msg', { name: clearing.label, amount: formatMoney(clearing.fallback) })
            : t('admin.payouts.clear_mission_msg', { name: clearing.label, amount: formatMoney(clearing.fallback) })
        : '';

    return (
        <Screen
            title={t('ui.screen.admin_payouts')}
            subtitle={t('admin.payouts.subtitle')}
            actions={
                data ? (
                    <span className="economy-admin-pay-summary">
                        <Badge tone="accent" icon="lock">
                            {t('admin.payouts.summary_types', { n: lockedTypes })}
                        </Badge>
                        <Badge tone="accent" icon="lock">
                            {t('admin.payouts.summary_missions', { n: adminCount })}
                        </Badge>
                        <Button size="sm" icon="sliders" onClick={() => setAdjusting(true)}>
                            {t('admin.payouts.adjust_open')}
                        </Button>
                    </span>
                ) : undefined
            }
            className="economy-admin-payouts"
        >
            <Tabs items={tabs} value={tab} onChange={setTab} aria-label={t('ui.screen.admin_payouts')} />

            {data && (data.outOfRange ?? 0) > 0 ? (
                <Card highlight="warning" padding="sm">
                    {t('admin.payouts.out_of_range_note', {
                        n: data.outOfRange ?? 0,
                        min: formatMoney(data.limits?.min ?? 0),
                        max: formatMoney(data.limits?.max ?? 25000),
                    })}
                </Card>
            ) : null}

            {!data && loading ? <LoadingBlock /> : null}
            {!data && !loading && error ? <ErrorState error={error} onRetry={() => void refetch()} /> : null}

            {data && tab === 'types' ? (
                <Card padding="none">
                    <Table
                        columns={typeColumns}
                        rows={types}
                        rowKey={r => r.key}
                        empty={<EmptyState compact icon="layers" title={t('admin.payouts.empty_types')} />}
                        aria-label={t('admin.payouts.tab_types')}
                    />
                </Card>
            ) : null}

            {data && tab === 'missions' ? (
                <>
                    <div className="economy-admin-pay-toolbar">
                        <SearchInput
                            value={query}
                            onChange={setQuery}
                            placeholder={t('admin.payouts.search')}
                            className="economy-admin-pay-search"
                        />
                        <SegmentedControl
                            items={filterItems}
                            value={typeFilter}
                            onChange={setTypeFilter}
                            size="sm"
                            aria-label={t('admin.payouts.col_type')}
                        />
                    </div>
                    <Card padding="none">
                        <Table
                            columns={missionColumns}
                            rows={filtered}
                            rowKey={r => r.id}
                            highlightRow={r => r.payoutSource === 'admin'}
                            empty={
                                <EmptyState
                                    compact
                                    icon="search"
                                    title={
                                        missions.length
                                            ? t('admin.payouts.empty_filter')
                                            : t('admin.payouts.empty_missions')
                                    }
                                />
                            }
                            aria-label={t('admin.payouts.tab_missions')}
                        />
                    </Card>
                </>
            ) : null}

            {data ? (
                <p className="economy-admin-pay-footnote">
                    {t('admin.payouts.footnote', {
                        min: formatMoney(data.limits?.min ?? 0),
                        max: formatMoney(data.limits?.max ?? 25000),
                    })}
                </p>
            ) : null}

            <SetDialog
                target={editing}
                view={data}
                onClose={() => setEditing(null)}
                onDone={() => {
                    setEditing(null);
                    void refetch();
                }}
            />
            <AdjustDialog
                open={adjusting}
                onClose={() => setAdjusting(false)}
                onDone={() => {
                    setAdjusting(false);
                    void refetch();
                }}
            />
            <ConfirmDialog
                open={!!unlocking}
                title={unlocking ? t('admin.payouts.unlock_title', { name: unlocking.label }) : ''}
                message={unlocking ? t('admin.payouts.unlock_msg', { amount: formatMoney(unlocking.current) }) : ''}
                confirmLabel={t('admin.payouts.unlock')}
                reason={{ required: data?.requireReason !== false, maxLength: REASON_MAX }}
                onConfirm={unlockTarget}
                onCancel={() => setUnlocking(null)}
            />
            <ConfirmDialog
                open={!!clearing}
                title={clearing ? t('admin.payouts.clear_title', { name: clearing.label }) : ''}
                message={clearMessage}
                confirmLabel={t('admin.payouts.clear_confirm')}
                tone="danger"
                reason={{
                    required: data?.requireReason !== false,
                    maxLength: REASON_MAX,
                    placeholder: t('admin.payouts.reason_placeholder'),
                }}
                onConfirm={clearTarget}
                onCancel={() => setClearing(null)}
            />
        </Screen>
    );
}
