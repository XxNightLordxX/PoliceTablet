// Admin UI · Missions (screen key 'admin_missions', title key 'ui.screen.admin_missions').

import { useMemo, useState } from 'react';
import {
    Badge,
    Button,
    Card,
    ConfirmDialog,
    Dialog,
    EmptyState,
    ErrorState,
    Grid,
    Icon,
    IconButton,
    LoadingBlock,
    Screen,
    SearchInput,
    SegmentedControl,
    Stat,
    Table,
    Tabs,
    type TableColumn,
} from '../../shared/components';
import { asArray } from '../../shared/data';
import { useAction, usePush, useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { useCan } from '../../shared/session';
import { toast } from '../../shared/toast';
import OperationPanel from '../../supervisor/components/OperationPanel';
import { BuilderWorkspace, LockBadge, StatusBadge, editorMemory, setEditorMemory } from '../../builder';
import type {
    BuilderCreateResult,
    BuilderList,
    BuilderListEntry,
    BuilderPublishResult,
    BuilderRollbackResult,
} from '../../types/builder_server';
import type { MissionListEntry } from '../../types/oversight';
import type { AdminMissionsData } from '../../types/builder_client';

type Tab = 'catalog' | 'builder' | 'operation';
type SourceFilter = 'all' | 'builtin' | 'custom';

interface CatalogRow {
    id: string;
    label: string;
    type: string;
    typeLabel: string;
    source: 'builtin' | 'custom';
    version: number | null;
    filePath: string | null;
    editedInCode: boolean;
    inPool: boolean;
    enabled: boolean;
    offInConfig: boolean;
    isBoss: boolean;
    eligible: boolean;
    entry: BuilderListEntry | null;
    mission: MissionListEntry | null;
}

interface ReloadSummary {
    loaded: number;
    builtin: number;
    custom: number;
    warnings: number;
    failed: { id: string; file?: string; error: string }[];
    error?: string;
}

type Confirm =
    | { kind: 'publish' | 'archive' | 'restore' | 'rollback' | 'breakLock'; row: CatalogRow }
    | { kind: 'launch'; row: CatalogRow }
    | { kind: 'reload' }
    | null;

export default function AdminMissions() {
    const can = useCan();
    const [tab, setTabState] = useState<Tab>(
        () => editorMemory('admin').tab ?? (editorMemory('admin').openId ? 'builder' : 'catalog'),
    );
    const setTab = (next: Tab) => {
        setTabState(next);
        setEditorMemory('admin', { tab: next });
    };
    const missions = useRequest<AdminMissionsData>('admin:getMissions', {}, { pushTopic: 'operation', pollMs: 30000 });
    const builder = useRequest<BuilderList>('builder:list', {}, { pushTopic: 'builder', pollMs: 30000 });
    // the catalog (loaded missions, pool, eligibility) changes when a custom mission joins or leaves its pool
    usePush<{ event?: string }>('builder', data => {
        const ev = data && typeof data === 'object' ? data.event : undefined;
        if (ev === 'published' || ev === 'archived' || ev === 'restored' || ev === 'rolledBack' || ev === 'reloaded')
            void missions.refetch();
    });
    const { run, busy } = useAction();
    const [query, setQuery] = useState('');
    const [source, setSource] = useState<SourceFilter>('all');
    const [confirm, setConfirm] = useState<Confirm>(null);
    const [summary, setSummary] = useState<ReloadSummary | null>(null);

    const rows = useMemo<CatalogRow[]>(() => {
        const entries = new Map(asArray(builder.data?.missions).map(e => [e.id, e]));
        const out: CatalogRow[] = asArray(missions.data?.missions).map(m => {
            const entry = entries.get(m.id) ?? null;
            entries.delete(m.id);
            const builtin = m.source !== 'custom';
            return {
                id: m.id,
                label: m.label,
                type: m.type,
                typeLabel: m.typeLabel,
                source: builtin ? 'builtin' : 'custom',
                version: builtin ? null : (entry?.version ?? m.version ?? null),
                filePath: m.filePath ?? entry?.filePath ?? (builtin ? `missions/builtin/${m.id}.lua` : null),
                editedInCode: !!(m.editedInCode || entry?.editedInCode),
                inPool: true,
                enabled: m.enabled,
                offInConfig: m.disabledInConfig ?? (builtin && !m.enabled),
                isBoss: m.isBoss,
                eligible: m.crossDeptEligible,
                entry,
                mission: m,
            };
        });
        entries.forEach(e => {
            out.push({
                id: e.id,
                label: e.label,
                type: e.type,
                typeLabel: asArray(missions.data?.missions).find(m => m.type === e.type)?.typeLabel ?? e.type,
                source: 'custom',
                version: e.version,
                filePath: e.filePath,
                editedInCode: e.editedInCode,
                inPool: false,
                enabled: e.status === 'published',
                offInConfig: false,
                isBoss: false,
                eligible: false,
                entry: e,
                mission: null,
            });
        });
        return out;
    }, [missions.data, builder.data]);

    const filtered = useMemo(() => {
        const q = query.trim().toLowerCase();
        return rows.filter(
            r =>
                (source === 'all' || r.source === source) &&
                (!q || r.label.toLowerCase().includes(q) || r.id.includes(q)),
        );
    }, [rows, query, source]);

    const stats = useMemo(
        () => ({
            total: rows.length,
            builtin: rows.filter(r => r.source === 'builtin').length,
            custom: rows.filter(r => r.source === 'custom').length,
            off: rows.filter(r => r.offInConfig).length,
            drafts: rows.filter(r => r.entry?.hasDraft || r.entry?.status === 'draft' || r.entry?.status === 'tested')
                .length,
            locked: rows.filter(r => r.entry?.lock && !r.entry.lock.mine).length,
        }),
        [rows],
    );

    const canLaunch = !!missions.data?.canLaunch && can('launchCrossDept');
    const eligible = rows.filter(r => r.eligible);

    const openInBuilder = (id: string, step: 'details' | 'blocks' | 'publish' = 'details') => {
        setEditorMemory('admin', { openId: id, step, location: 1, objective: 1, tab: 'builder' });
        setTabState('builder');
    };

    const refetchAll = () => {
        void missions.refetch();
        void builder.refetch();
    };

    const doConfirm = async () => {
        const c = confirm;
        if (!c) return;
        if (c.kind === 'reload') {
            const res = await run<ReloadSummary>('server:admin:reloadMissions', null);
            setConfirm(null);
            if (res.ok && res.data) {
                setSummary({ ...res.data, failed: asArray(res.data.failed) });
                refetchAll();
            }
            return;
        }
        const row = c.row;
        const vars = { mission: row.label };
        if (c.kind === 'launch') {
            const res = await run(
                'server:admin:opLaunch',
                { missionId: row.id },
                { success: 'admin.missions.launched', successVars: vars },
            );
            setConfirm(null);
            if (res.ok) setTab('operation');
            return;
        }
        let res;
        if (c.kind === 'publish') {
            res = await run<BuilderPublishResult>('server:builder:publish', { id: row.id });
            if (res.ok && res.data)
                toast('success', t('admin.missions.published', { mission: row.label, version: res.data.version }));
            if (!res.ok && res.error === 'err.builder_invalid') openInBuilder(row.id, 'publish');
        } else if (c.kind === 'archive')
            res = await run(
                'server:builder:archive',
                { id: row.id },
                { success: 'builder.list.archived', successVars: vars },
            );
        else if (c.kind === 'restore')
            res = await run(
                'server:builder:restore',
                { id: row.id },
                { success: 'builder.list.restored', successVars: vars },
            );
        else if (c.kind === 'rollback') {
            res = await run<BuilderRollbackResult>('server:builder:rollback', { id: row.id });
            if (res.ok && res.data)
                toast(
                    'success',
                    t('builder.list.rolled_back', {
                        mission: row.label,
                        version: res.data.version,
                        from: res.data.fromVersion,
                    }),
                );
        } else
            res = await run(
                'server:builder:breakLock',
                { id: row.id },
                { success: 'builder.list.lock_broken', successVars: vars },
            );
        setConfirm(null);
        if (res?.ok) refetchAll();
    };

    const duplicate = async (row: CatalogRow) => {
        const res = await run<BuilderCreateResult>(
            'server:builder:duplicate',
            { id: row.id },
            { success: 'builder.list.duplicated', successVars: { mission: row.label } },
        );
        if (res.ok && res.data) openInBuilder(res.data.id);
    };

    const columns: TableColumn<CatalogRow>[] = [
        {
            key: 'label',
            header: t('admin.missions.col.mission'),
            render: r => (
                <div className="builder_client-mission">
                    <div className="builder_client-mission__name">
                        <span>{r.label}</span>
                        {r.isBoss ? (
                            <Badge size="sm" tone="accent" icon="star">
                                {t('admin.missions.boss')}
                            </Badge>
                        ) : null}
                    </div>
                    <div className="builder_client-mission__meta">
                        <span>{r.typeLabel}</span>
                    </div>
                    <span className="builder_client-mono">{r.id}</span>
                </div>
            ),
        },
        {
            key: 'source',
            header: t('admin.missions.col.source'),
            width: 124,
            render: r => (
                <div className="builder_client-status-cell">
                    {r.source === 'builtin' ? (
                        <Badge size="sm" tone="grey" variant="outline" icon="lock">
                            {t('admin.missions.builtin')}
                        </Badge>
                    ) : (
                        <Badge size="sm" tone="primary" icon="tool">
                            {t('admin.missions.custom')}
                        </Badge>
                    )}
                    {r.version ? (
                        <span className="builder_client-muted cp-num">
                            {t('admin.missions.version_v', { version: r.version })}
                        </span>
                    ) : null}
                </div>
            ),
        },
        {
            key: 'file',
            header: t('admin.missions.col.file'),
            render: r => (
                <div className="builder_client-file">
                    <span className="builder_client-mono" title={r.filePath ?? ''}>
                        {r.filePath ?? t('admin.missions.no_file')}
                    </span>
                    {r.editedInCode ? (
                        <Badge size="sm" tone="warning" variant="outline" icon="fileText">
                            {t('builder.list.edited_in_code')}
                        </Badge>
                    ) : null}
                </div>
            ),
        },
        {
            key: 'status',
            header: t('admin.missions.col.status'),
            width: 190,
            render: r => {
                if (r.source === 'builtin') {
                    if (r.offInConfig)
                        return (
                            <Badge size="sm" tone="grey" icon="minusCircle" title={t('admin.missions.off_config_hint')}>
                                {t('admin.missions.off_config')}
                            </Badge>
                        );
                    return r.enabled ? (
                        <Badge size="sm" tone="success" icon="checkCircle">
                            {t('admin.missions.enabled')}
                        </Badge>
                    ) : (
                        <Badge size="sm" tone="grey" icon="minusCircle">
                            {t('admin.missions.not_enabled')}
                        </Badge>
                    );
                }
                const e = r.entry;
                return (
                    <div className="builder_client-status-cell">
                        {e ? (
                            <StatusBadge status={e.status} />
                        ) : (
                            <Badge size="sm" tone="success">
                                {t('builder.status.published')}
                            </Badge>
                        )}
                        {e?.hasDraft && e.dbStatus === 'published' ? (
                            <Badge
                                size="sm"
                                tone={e.draftTested ? 'success' : 'neutral'}
                                variant="outline"
                                icon={e.draftTested ? 'flask' : 'edit'}
                            >
                                {t(e.draftTested ? 'builder.list.draft_tested' : 'builder.list.draft_v', {
                                    version: e.draftVersion ?? '?',
                                })}
                            </Badge>
                        ) : null}
                        {r.offInConfig ? (
                            <Badge size="sm" tone="grey" title={t('admin.missions.off_config_hint')}>
                                {t('admin.missions.off_config')}
                            </Badge>
                        ) : null}
                        {e?.lock ? <LockBadge lock={e.lock} /> : null}
                    </div>
                );
            },
        },
        {
            key: 'actions',
            header: '',
            width: 220,
            align: 'right',
            render: r => {
                const e = r.entry;
                return (
                    <div className="builder_client-row-actions">
                        {r.eligible && canLaunch ? (
                            <IconButton
                                icon="globe"
                                size="sm"
                                variant="ghost"
                                label={t('admin.missions.launch')}
                                onClick={() => setConfirm({ kind: 'launch', row: r })}
                            />
                        ) : null}
                        {r.source === 'builtin' ? (
                            <>
                                <IconButton
                                    icon="eye"
                                    size="sm"
                                    variant="ghost"
                                    label={t('admin.missions.view')}
                                    onClick={() => openInBuilder(r.id)}
                                />
                                <Button
                                    size="sm"
                                    variant="secondary"
                                    icon="swap"
                                    onClick={() => void duplicate(r)}
                                    disabled={busy}
                                >
                                    {t('admin.missions.duplicate')}
                                </Button>
                            </>
                        ) : e ? (
                            <>
                                {e.can.rollback ? (
                                    <IconButton
                                        icon="chevronLeft"
                                        size="sm"
                                        variant="ghost"
                                        label={t('builder.list.rollback')}
                                        onClick={() => setConfirm({ kind: 'rollback', row: r })}
                                    />
                                ) : null}
                                {e.can.breakLock ? (
                                    <IconButton
                                        icon="key"
                                        size="sm"
                                        variant="ghost"
                                        label={t('builder.list.break_lock')}
                                        onClick={() => setConfirm({ kind: 'breakLock', row: r })}
                                    />
                                ) : null}
                                {e.can.archive ? (
                                    <IconButton
                                        icon="inbox"
                                        size="sm"
                                        variant="ghost"
                                        label={t('builder.list.archive')}
                                        onClick={() => setConfirm({ kind: 'archive', row: r })}
                                    />
                                ) : null}
                                {e.can.restore ? (
                                    <IconButton
                                        icon="refresh"
                                        size="sm"
                                        variant="ghost"
                                        label={t('builder.list.restore')}
                                        onClick={() => setConfirm({ kind: 'restore', row: r })}
                                    />
                                ) : null}
                                {e.can.publish && e.draftTested ? (
                                    <Button
                                        size="sm"
                                        variant="secondary"
                                        icon="globe"
                                        onClick={() => setConfirm({ kind: 'publish', row: r })}
                                    >
                                        {t('admin.missions.publish')}
                                    </Button>
                                ) : null}
                                <Button
                                    size="sm"
                                    icon={e.can.edit ? 'edit' : 'eye'}
                                    onClick={() => openInBuilder(r.id)}
                                >
                                    {e.can.edit ? t('admin.missions.build') : t('admin.missions.view')}
                                </Button>
                            </>
                        ) : null}
                    </div>
                );
            },
        },
    ];

    const loading = (missions.loading && !missions.data) || (builder.loading && !builder.data);
    const error =
        !missions.data && missions.error ? missions.error : !builder.data && builder.error ? builder.error : null;
    const confirmCopy = confirmText(confirm);

    return (
        <Screen
            title={t('ui.screen.admin_missions')}
            subtitle={t('admin.missions.subtitle')}
            className="builder_client-screen"
            actions={
                <>
                    <IconButton icon="refresh" label={t('builder.list.refresh')} variant="ghost" onClick={refetchAll} />
                    {can('reloadMissions') ? (
                        <Button variant="secondary" icon="refresh" onClick={() => setConfirm({ kind: 'reload' })}>
                            {t('admin.missions.reload')}
                        </Button>
                    ) : null}
                    {can('builderEdit') ? (
                        <Button
                            variant="primary"
                            icon="plus"
                            onClick={() => {
                                setEditorMemory('admin', { openId: null });
                                setTab('builder');
                            }}
                        >
                            {t('admin.missions.new')}
                        </Button>
                    ) : null}
                </>
            }
        >
            <Tabs<Tab>
                value={tab}
                onChange={setTab}
                items={[
                    {
                        key: 'catalog',
                        label: t('admin.missions.tab.catalog'),
                        icon: 'layers',
                        badge: rows.length || undefined,
                    },
                    {
                        key: 'builder',
                        label: t('admin.missions.tab.builder'),
                        icon: 'tool',
                        badge: stats.drafts || undefined,
                    },
                    { key: 'operation', label: t('admin.missions.tab.operation'), icon: 'globe' },
                ]}
            />
            {tab === 'catalog' ? (
                error ? (
                    <ErrorState error={error} onRetry={refetchAll} />
                ) : loading ? (
                    <LoadingBlock />
                ) : (
                    <>
                        <Grid cols={6} gap={3}>
                            <Stat label={t('admin.missions.stat.total')} value={stats.total} icon="layers" />
                            <Stat label={t('admin.missions.stat.builtin')} value={stats.builtin} icon="lock" />
                            <Stat
                                label={t('admin.missions.stat.custom')}
                                value={stats.custom}
                                icon="tool"
                                tone="primary"
                            />
                            <Stat
                                label={t('admin.missions.stat.off')}
                                value={stats.off}
                                icon="minusCircle"
                                hint={t('admin.missions.stat.off_hint')}
                            />
                            <Stat
                                label={t('admin.missions.stat.drafts')}
                                value={stats.drafts}
                                icon="edit"
                                tone={stats.drafts ? 'accent' : 'neutral'}
                            />
                            <Stat
                                label={t('admin.missions.stat.locked')}
                                value={stats.locked}
                                icon="key"
                                tone={stats.locked ? 'warning' : 'neutral'}
                            />
                        </Grid>
                        <div className="builder_client-toolbar">
                            <SearchInput
                                value={query}
                                onChange={setQuery}
                                placeholder={t('admin.missions.search')}
                                className="builder_client-search"
                            />
                            <SegmentedControl<SourceFilter>
                                size="sm"
                                value={source}
                                onChange={setSource}
                                items={[
                                    { key: 'all', label: t('admin.missions.filter.all') },
                                    { key: 'builtin', label: t('admin.missions.filter.builtin') },
                                    { key: 'custom', label: t('admin.missions.filter.custom') },
                                ]}
                            />
                            <span className="cp-spacer" />
                            <span className="builder_client-muted builder_client-inline-note">
                                <Icon name="info" size={14} />
                                {t('admin.missions.disabled_note')}
                            </span>
                        </div>
                        <Table
                            className="builder_client-catalog"
                            columns={columns}
                            rows={filtered}
                            rowKey={r => r.id}
                            empty={t('admin.missions.none')}
                            aria-label={t('ui.screen.admin_missions')}
                        />
                    </>
                )
            ) : null}
            {tab === 'builder' ? <BuilderWorkspace scope="admin" /> : null}
            {tab === 'operation' ? (
                <div className="builder_client-op">
                    <OperationPanel scope="admin" />
                    <Card
                        title={t('admin.missions.eligible')}
                        subtitle={t('admin.missions.eligible_sub')}
                        icon="globe"
                        padding="none"
                    >
                        {missions.loading && !missions.data ? (
                            <LoadingBlock />
                        ) : !eligible.length ? (
                            <EmptyState compact icon="globe" title={t('admin.missions.eligible_none')} />
                        ) : (
                            <Table
                                dense
                                rows={eligible}
                                rowKey={r => r.id}
                                columns={[
                                    {
                                        key: 'label',
                                        header: t('admin.missions.col.mission'),
                                        render: r => <span className="builder_client-mission__name">{r.label}</span>,
                                    },
                                    {
                                        key: 'type',
                                        header: t('admin.missions.col.type'),
                                        width: 130,
                                        render: r => r.typeLabel,
                                    },
                                    {
                                        key: 'officers',
                                        header: t('admin.missions.col.officers'),
                                        width: 100,
                                        numeric: true,
                                        render: r => (
                                            <span className="cp-num">
                                                {r.mission ? `${r.mission.minOfficers}–${r.mission.maxOfficers}` : '—'}
                                            </span>
                                        ),
                                    },
                                    {
                                        key: 'launch',
                                        header: '',
                                        width: 120,
                                        align: 'right',
                                        render: r => (
                                            <Button
                                                size="sm"
                                                icon="globe"
                                                disabled={!canLaunch || !!missions.data?.operation}
                                                onClick={() => setConfirm({ kind: 'launch', row: r })}
                                            >
                                                {t('admin.missions.launch')}
                                            </Button>
                                        ),
                                    },
                                ]}
                            />
                        )}
                    </Card>
                </div>
            ) : null}
            <ConfirmDialog
                open={!!confirm}
                title={confirmCopy.title}
                message={confirmCopy.message}
                confirmLabel={confirmCopy.button}
                tone={confirm && (confirm.kind === 'archive' || confirm.kind === 'breakLock') ? 'danger' : 'primary'}
                onConfirm={doConfirm}
                onCancel={() => setConfirm(null)}
                busy={busy}
            />
            <Dialog
                open={!!summary}
                onClose={() => setSummary(null)}
                title={t('admin.missions.reload_done')}
                size="md"
                footer={<Button onClick={() => setSummary(null)}>{t('common.close')}</Button>}
            >
                {summary ? (
                    <div className="builder_client-form">
                        <Grid cols={4} gap={3}>
                            <Stat
                                label={t('admin.missions.sum.loaded')}
                                value={summary.loaded}
                                tone="success"
                                size="sm"
                            />
                            <Stat label={t('admin.missions.sum.builtin')} value={summary.builtin} size="sm" />
                            <Stat label={t('admin.missions.sum.custom')} value={summary.custom} size="sm" />
                            <Stat
                                label={t('admin.missions.sum.warnings')}
                                value={summary.warnings}
                                tone={summary.warnings ? 'warning' : 'neutral'}
                                size="sm"
                            />
                        </Grid>
                        {summary.error ? (
                            <div className="builder_client-callout builder_client-callout--warning">
                                <Icon name="alert" size={15} />
                                <span>{summary.error}</span>
                            </div>
                        ) : null}
                        {summary.failed.length ? (
                            <ul className="builder_client-errors">
                                {summary.failed.map(f => (
                                    <li key={f.id}>
                                        <Icon name="xCircle" size={13} />
                                        <span>
                                            <b>{f.id}</b>
                                            {f.file ? ` (${f.file})` : ''}: {f.error}
                                        </span>
                                    </li>
                                ))}
                            </ul>
                        ) : (
                            <div className="builder_client-inline-note is-ok">
                                <Icon name="checkCircle" size={15} />
                                <span>{t('admin.missions.reload_clean')}</span>
                            </div>
                        )}
                    </div>
                ) : null}
            </Dialog>
        </Screen>
    );
}

function confirmText(c: Confirm): { title: string; message: string; button: string } {
    if (!c) return { title: '', message: '', button: '' };
    if (c.kind === 'reload')
        return {
            title: t('admin.missions.confirm_reload.title'),
            message: t('admin.missions.confirm_reload.message'),
            button: t('admin.missions.confirm_reload.button'),
        };
    const r = c.row;
    const vars = {
        mission: r.label,
        version: r.version ?? 1,
        previous: Math.max(1, (r.version ?? 2) - 1),
        name: r.entry?.lock?.name ?? r.entry?.lock?.citizenid ?? '',
        file: r.filePath ?? '',
    };
    if (c.kind === 'launch')
        return {
            title: t('admin.missions.confirm_launch.title', vars),
            message: t('admin.missions.confirm_launch.message', vars),
            button: t('admin.missions.confirm_launch.button'),
        };
    if (c.kind === 'publish') {
        return {
            title: t('builder.confirm.publish.title', vars),
            message: t('builder.confirm.publish.message', {
                version: r.entry?.draftVersion ?? 1,
                file: r.filePath ?? '',
            }),
            button: t('builder.confirm.publish.button'),
        };
    }
    const k = c.kind === 'breakLock' ? 'break_lock' : c.kind;
    return {
        title: t(`builder.confirm.${k}.title`, vars),
        message: t(`builder.confirm.${k}.message`, vars),
        button: t(`builder.confirm.${k}.button`, vars),
    };
}
