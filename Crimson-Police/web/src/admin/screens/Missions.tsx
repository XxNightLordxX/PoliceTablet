// Admin UI · Missions (screen key 'admin_missions', title key 'ui.screen.admin_missions').

import { useEffect, useMemo, useState, type SyntheticEvent } from 'react';
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
    Toggle,
    type TableColumn,
} from '../../shared/components';
import { asArray } from '../../shared/data';
import { useAction, usePush, useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { useNavigation } from '../../shared/navigation';
import { useCan } from '../../shared/session';
import { toast } from '../../shared/toast';
import OperationPanel from '../../supervisor/components/OperationPanel';
import MissionCallsPanel, { LocationPlays } from '../../supervisor/components/MissionCallsPanel';
import { BuilderWorkspace, LockBadge, StatusBadge, asksNewMission, editorMemory, setEditorMemory } from '../../builder';
import {
    ChangeOwnerDialog,
    CompareDialog,
    CopyLuaDialog,
    DeletedMissions,
    DispatchHistory,
    ImportDialog,
    LoadProblemDialog,
    LoadResultBanner,
    LoadSummaryBody,
    MissionStats,
    OperationHistory,
    OverrideBadges,
    SwitchRemapCard,
    VersionsDialog,
} from '../../builder/admin';
import { useAdminAction } from '../components/kit';
import { MissionDrawer, type DrawerAction } from '../components/MissionDrawer';
import type { LoadFailure, MissionLoadSummary, OverrideView } from '../../types/admin_missions';
import type {
    BuilderCreateResult,
    BuilderList,
    BuilderListEntry,
    BuilderPublishResult,
    BuilderRollbackResult,
} from '../../types/builder_server';
import type { MissionListEntry } from '../../types/oversight';
import { MissionsToday } from '../components/MissionsToday';
import type { AdminMissionsData } from '../../types/builder_client';
import type { MissionSwitchView } from '../../types/settings';
import './Settings.css';
import './Missions.css';

// Controls inside a catalog row keep their clicks and keys (a click elsewhere on the row opens the mission's drawer).
const stopRow = {
    onClick: (e: SyntheticEvent) => e.stopPropagation(),
    onKeyDown: (e: SyntheticEvent) => e.stopPropagation(),
};

type Tab = 'catalog' | 'builder' | 'operation' | 'dispatch' | 'history' | 'stats' | 'deleted';
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
    // the on/off switches of a loaded mission and its locations (null: a draft not in the pools)
    switch: MissionSwitchView | null;
    entry: BuilderListEntry | null;
    mission: MissionListEntry | null;
    // a built-in for an admin: its override view (Edited, Original changed) and Edit in Builder
    override: OverrideView | null;
    canEditBuiltin: boolean;
    // the last load refused this mission's file: the row is greyed with the plain reason (Show the problem)
    loadError: LoadFailure | null;
}

type ReloadSummary = MissionLoadSummary;

// The admin-only confirmations (reason, and the mission id typed where the server asks for it).
type AdminConfirm = { kind: 'reset' | 'delete' | 'fold' | 'launchAnyway'; row: CatalogRow } | null;

type Open = { kind: 'compare' | 'versions' | 'copy' | 'owner'; row: CatalogRow } | null;

type Confirm =
    | { kind: 'publish' | 'archive' | 'restore' | 'rollback' | 'breakLock'; row: CatalogRow }
    | { kind: 'launch'; row: CatalogRow }
    | { kind: 'reload' }
    | null;

// the navigate() params whose New mission already opened (each Home press passes a new object)
let handledNewParams: unknown = null;

export default function AdminMissions() {
    const can = useCan();
    const [tab, setTabState] = useState<Tab>(
        () => editorMemory('admin').tab ?? (editorMemory('admin').openId ? 'builder' : 'catalog'),
    );
    const setTab = (next: Tab) => {
        setTabState(next);
        // the builder remembers its own three tabs; the Dispatch and admin-only tabs are not among them
        if (next === 'catalog' || next === 'builder' || next === 'operation') setEditorMemory('admin', { tab: next });
    };
    // "New mission" presses (the header button, Home's tile): the Builder tab opens the wizard at once
    const [newRequest, setNewRequest] = useState(0);
    const startNew = () => {
        // a Builder tab that mounts now starts on the list, not on the mission it had open
        setEditorMemory('admin', { openId: null });
        setTab('builder');
        setNewRequest(n => n + 1);
    };
    // Home links here with navigate('admin_missions', { tab }): 'builder' (make a mission, with wizard: 'new' the
    // wizard opens) or 'catalog' (on/off)
    const { params } = useNavigation();
    useEffect(() => {
        // once per press: the params stay while the screen is shown, a reopened tablet must not start it again
        if (asksNewMission(params)) {
            if (params !== handledNewParams) startNew();
            handledNewParams = params;
        } else if (params.tab === 'builder' || params.tab === 'catalog') setTab(params.tab);
    }, [params]); // eslint-disable-line react-hooks/exhaustive-deps
    const missions = useRequest<AdminMissionsData>('admin:getMissions', {}, { pushTopic: 'operation', pollMs: 30000 });
    const builder = useRequest<BuilderList>('builder:list', {}, { pushTopic: 'builder', pollMs: 30000 });
    const load = useRequest<MissionLoadSummary>('admin:getMissionLoad', {}, { pushTopic: 'builder', pollMs: 60000 });
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
    // the mission whose drawer is open (a catalog row click): everything about it in one place
    const [drawerOf, setDrawerOf] = useState<string | null>(null);
    const [adminConfirm, setAdminConfirm] = useState<AdminConfirm>(null);
    const [openDialog, setOpenDialog] = useState<Open>(null);
    const [importOpen, setImportOpen] = useState(false);
    const [problem, setProblem] = useState<CatalogRow | null>(null);
    const admin = useAdminAction();

    const rows = useMemo<CatalogRow[]>(() => {
        const entries = new Map(asArray(builder.data?.missions).map(e => [e.id, e]));
        const builtins = new Map(asArray(builder.data?.builtins).map(b => [b.id, b]));
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
                switch: m.switch ? { ...m.switch, locations: asArray(m.switch.locations) } : null,
                entry,
                mission: m,
                override: builtin ? (builtins.get(m.id)?.override ?? entry?.override ?? null) : null,
                canEditBuiltin: builtin && !!builtins.get(m.id)?.canEdit,
                loadError: null,
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
                switch: null,
                entry: e,
                mission: null,
                override: e.override ?? null,
                canEditBuiltin: false,
                loadError: null,
            });
        });
        // the files the last load refused: a mission in no pool gets the reason; one not listed gets its own row
        asArray(load.data?.failed).forEach(f => {
            const row = out.find(r => r.id === f.id);
            if (row) {
                if (!row.inPool && !row.loadError) row.loadError = f;
                return;
            }
            const builtin = !!f.file && f.file.startsWith('missions/builtin/');
            out.push({
                id: f.id,
                label: f.id,
                type: '',
                typeLabel: '',
                source: builtin ? 'builtin' : 'custom',
                version: null,
                filePath: f.file ?? null,
                editedInCode: false,
                inPool: false,
                enabled: false,
                offInConfig: false,
                isBoss: false,
                eligible: false,
                switch: null,
                entry: null,
                mission: null,
                override: null,
                canEditBuiltin: false,
                loadError: f,
            });
        });
        return out;
    }, [missions.data, builder.data, load.data]);

    const drawerRow = rows.find(r => r.id === drawerOf) ?? null;

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
            off: rows.filter(r => (r.switch ? !r.switch.on : r.offInConfig)).length,
            drafts: rows.filter(r => r.entry?.hasDraft || r.entry?.status === 'draft' || r.entry?.status === 'tested')
                .length,
            locked: rows.filter(r => r.entry?.lock && !r.entry.lock.mine).length,
        }),
        [rows],
    );

    const canLaunch = !!missions.data?.canLaunch && can('launchCrossDept');
    const canMissionAdmin = can('missionAdmin');
    const eligible = rows.filter(r => r.eligible);

    const openInBuilder = (id: string, step: 'details' | 'blocks' | 'publish' = 'details') => {
        setEditorMemory('admin', { openId: id, step, location: 1, objective: 1, tab: 'builder' });
        setTabState('builder');
    };

    const refetchAll = () => {
        void missions.refetch();
        void builder.refetch();
        void load.refetch();
    };

    const doConfirm = async () => {
        const c = confirm;
        if (!c) return;
        if (c.kind === 'reload') {
            const res = await run<ReloadSummary>('server:admin:reloadMissions', null);
            setConfirm(null);
            if (res.ok && res.data) {
                setSummary({
                    ...res.data,
                    failed: asArray(res.data.failed),
                    overrideFailed: asArray(res.data.overrideFailed),
                    warningTexts: asArray(res.data.warningTexts),
                    builder: res.data.builder
                        ? {
                              ...res.data.builder,
                              edited: asArray(res.data.builder.edited),
                              rejected: asArray(res.data.builder.rejected),
                          }
                        : null,
                });
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
                { success: 'admin.missions.launched', successVars: vars, silent: true },
            );
            setConfirm(null);
            if (res.ok) setTab('operation');
            // admins may launch during the server-wide cooldown, with a reason
            else if (res.error === 'err.op_cooldown') setAdminConfirm({ kind: 'launchAnyway', row });
            else toast('error', t(res.error ?? 'err.internal'));
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

    // On/off of a mission (and of its locations in the dialog): saved over config.lua, runs already going finish.
    const setMission = async (row: CatalogRow, enabled: boolean) => {
        const res = await run<MissionSwitchView>(
            'server:admin:setMissionEnabled',
            { missionId: row.id, enabled },
            {
                success: enabled ? 'settings.mission.turned_on' : 'settings.mission.turned_off',
                successVars: { mission: row.label },
            },
        );
        if (res.ok) void missions.refetch();
    };

    const duplicate = async (row: CatalogRow) => {
        const res = await run<BuilderCreateResult>(
            'server:builder:duplicate',
            { id: row.id },
            { success: 'builder.list.duplicated', successVars: { mission: row.label } },
        );
        if (res.ok && res.data) openInBuilder(res.data.id);
    };

    // Edit in Builder: the built-in's override (made from the shipped file the first time)
    const editBuiltin = async (row: CatalogRow) => {
        const res = await admin.run('server:builder:editBuiltin', { id: row.id });
        if (res.ok) {
            refetchAll();
            openInBuilder(row.id);
        }
    };

    // The drawer's buttons, each with its name: the everyday ones first, the expert ones (Compare, Versions, Copy as
    // Lua, Fold, Reset ...) in their own card. Same server actions as before.
    const drawerActions = (r: CatalogRow): { actions: DrawerAction[]; expert: DrawerAction[] } => {
        const actions: DrawerAction[] = [];
        const expert: DrawerAction[] = [];
        const builder = (id: string) => {
            setDrawerOf(null);
            openInBuilder(id);
        };
        if (r.loadError)
            actions.push({
                key: 'problem',
                label: t('admin.missions.problem.open'),
                icon: 'alert',
                onClick: () => setProblem(r),
            });
        const e = r.entry;
        // a file that never loaded and has no Builder entry: only its problem can be opened
        if (r.loadError && !e) return { actions, expert };
        if (r.source === 'builtin') {
            if (r.canEditBuiltin)
                actions.push({
                    key: 'edit',
                    label: t('admin.missions.ovr.edit'),
                    icon: 'edit',
                    variant: 'primary',
                    disabled: admin.busy,
                    onClick: () => {
                        setDrawerOf(null);
                        void editBuiltin(r);
                    },
                });
            else
                actions.push({
                    key: 'view',
                    label: t('admin.missions.view'),
                    icon: 'eye',
                    onClick: () => builder(r.id),
                });
            actions.push({
                key: 'duplicate',
                label: t('admin.missions.duplicate'),
                icon: 'swap',
                disabled: busy,
                onClick: () => {
                    setDrawerOf(null);
                    void duplicate(r);
                },
            });
        } else if (e) {
            actions.push({
                key: 'build',
                label: e.can.edit ? t('admin.missions.build') : t('admin.missions.view'),
                icon: e.can.edit ? 'edit' : 'eye',
                variant: 'primary',
                onClick: () => builder(r.id),
            });
            if (e.can.publish && !e.needsTest)
                actions.push({
                    key: 'publish',
                    label: t('admin.missions.publish'),
                    icon: 'globe',
                    onClick: () => setConfirm({ kind: 'publish', row: r }),
                });
        }
        if (r.eligible && canLaunch)
            actions.push({
                key: 'launch',
                label: t('admin.missions.launch'),
                icon: 'globe',
                onClick: () => setConfirm({ kind: 'launch', row: r }),
            });
        const dialog = (kind: NonNullable<Open>['kind']) => () => setOpenDialog({ kind, row: r });
        const ov = r.override;
        if (r.source === 'builtin') {
            if (ov?.changed)
                expert.push({
                    key: 'compare',
                    label: t('admin.missions.ovr.compare'),
                    icon: 'alert',
                    onClick: dialog('compare'),
                });
            if (ov?.overridden || ov?.hasDraft)
                expert.push({
                    key: 'versions',
                    label: t('admin.missions.versions.open'),
                    icon: 'layers',
                    onClick: dialog('versions'),
                });
            if (ov?.overridden)
                expert.push({
                    key: 'copy',
                    label: t('admin.missions.copy.open'),
                    icon: 'fileText',
                    onClick: dialog('copy'),
                });
            if (ov?.overridden && ov.tweaks)
                expert.push({
                    key: 'fold',
                    label: t('admin.missions.ovr.fold'),
                    icon: 'download',
                    onClick: () => setAdminConfirm({ kind: 'fold', row: r }),
                });
            if (ov?.overridden || ov?.hasDraft)
                expert.push({
                    key: 'reset',
                    label: t('admin.missions.ovr.reset'),
                    icon: 'undo',
                    variant: 'danger',
                    onClick: () => setAdminConfirm({ kind: 'reset', row: r }),
                });
        } else if (e) {
            if (e.can.rollback)
                expert.push({
                    key: 'rollback',
                    label: t('builder.list.rollback'),
                    icon: 'chevronLeft',
                    onClick: () => setConfirm({ kind: 'rollback', row: r }),
                });
            if (canMissionAdmin) {
                expert.push({
                    key: 'versions',
                    label: t('admin.missions.versions.open'),
                    icon: 'layers',
                    onClick: dialog('versions'),
                });
                if (e.version)
                    expert.push({
                        key: 'copy',
                        label: t('admin.missions.copy.open'),
                        icon: 'fileText',
                        onClick: dialog('copy'),
                    });
                expert.push({
                    key: 'owner',
                    label: t('admin.missions.owner.open'),
                    icon: 'user',
                    onClick: dialog('owner'),
                });
            }
            if (e.can.breakLock)
                expert.push({
                    key: 'breakLock',
                    label: t('builder.list.break_lock'),
                    icon: 'key',
                    onClick: () => setConfirm({ kind: 'breakLock', row: r }),
                });
            if (e.can.archive)
                expert.push({
                    key: 'archive',
                    label: t('builder.list.archive'),
                    icon: 'inbox',
                    onClick: () => setConfirm({ kind: 'archive', row: r }),
                });
            if (e.can.restore)
                expert.push({
                    key: 'restore',
                    label: t('builder.list.restore'),
                    icon: 'refresh',
                    onClick: () => setConfirm({ kind: 'restore', row: r }),
                });
            if (canMissionAdmin && e.dbStatus === 'archived')
                expert.push({
                    key: 'delete',
                    label: t('admin.missions.delete.open'),
                    icon: 'trash',
                    variant: 'danger',
                    onClick: () => setAdminConfirm({ kind: 'delete', row: r }),
                });
        }
        return { actions, expert };
    };
    const drawer = drawerRow ? drawerActions(drawerRow) : { actions: [], expert: [] };

    const doAdminConfirm = async (reason: string, typed: string) => {
        const c = adminConfirm;
        if (!c) return;
        const row = c.row;
        const vars = { mission: row.label };
        let res;
        if (c.kind === 'reset')
            res = await admin.run(
                'server:builder:resetBuiltin',
                { id: row.id, reason, confirm: typed },
                { success: 'admin.missions.ovr.reset_done', successVars: vars },
            );
        else if (c.kind === 'delete')
            res = await admin.run(
                'server:builder:deleteMission',
                { id: row.id, reason, confirm: typed },
                { success: 'admin.missions.delete.done', successVars: vars },
            );
        else if (c.kind === 'fold')
            res = await admin.run(
                'server:builder:foldTweaks',
                { id: row.id, reason },
                { success: 'admin.missions.ovr.folded', successVars: vars },
            );
        else {
            res = await admin.run(
                'server:admin:opLaunch',
                { missionId: row.id, skipCooldown: true, reason },
                { success: 'admin.missions.launched', successVars: vars },
            );
            if (res.ok) setTab('operation');
        }
        setAdminConfirm(null);
        if (res.ok) refetchAll();
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
                        <>
                            <Badge size="sm" tone="grey" variant="outline" icon="lock">
                                {t('admin.missions.builtin')}
                            </Badge>
                            <OverrideBadges override={r.override} />
                        </>
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
            width: 230,
            render: r => {
                if (r.loadError) {
                    return (
                        <div className="builder_client-status-cell" title={t('admin.missions.not_loaded_hint')}>
                            <Badge size="sm" tone="danger" icon="xCircle">
                                {t('admin.missions.not_loaded')}
                            </Badge>
                            <span className="admin-missions-muted">{r.loadError.reason ?? r.loadError.error}</span>
                        </div>
                    );
                }
                const sw = r.switch ? (
                    <MissionSwitch row={r} busy={busy} onToggle={setMission} onLocations={setDrawerOf} />
                ) : null;
                if (r.source === 'builtin') {
                    if (sw) return sw;
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
                        {sw}
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
                        {e?.lock ? <LockBadge lock={e.lock} /> : null}
                    </div>
                );
            },
        },
        {
            key: 'actions',
            header: '',
            width: 200,
            align: 'right',
            // every action is in the mission's drawer (a click on the row, or Open), each with its name
            render: r => (
                <div className="builder_client-row-actions" {...stopRow}>
                    {r.loadError ? (
                        <Button size="sm" variant="secondary" icon="alert" onClick={() => setProblem(r)}>
                            {t('admin.missions.problem.open')}
                        </Button>
                    ) : null}
                    <Button size="sm" icon="chevronRight" onClick={() => setDrawerOf(r.id)}>
                        {t('admin.missions.drawer.open')}
                    </Button>
                </div>
            ),
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
                    {canMissionAdmin ? (
                        <Button variant="secondary" icon="download" onClick={() => setImportOpen(true)}>
                            {t('admin.missions.import.open')}
                        </Button>
                    ) : null}
                    {can('builderEdit') ? (
                        <Button variant="primary" icon="plus" onClick={startNew}>
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
                    { key: 'dispatch', label: t('mc.admin.tab'), icon: 'radio' },
                    { key: 'history', label: t('admin.missions.tab.history'), icon: 'clock' },
                    { key: 'stats', label: t('admin.missions.tab.stats'), icon: 'barChart' },
                    ...(canMissionAdmin
                        ? [{ key: 'deleted' as Tab, label: t('admin.missions.tab.deleted'), icon: 'trash' as const }]
                        : []),
                ]}
            />
            {tab === 'catalog' ? <MissionsToday /> : null}
            {tab === 'catalog' ? <LoadResultBanner /> : null}
            {tab === 'catalog' ? <SwitchRemapCard onChanged={() => void missions.refetch()} /> : null}
            {tab === 'history' ? (
                <div className="admin-missions-stack">
                    <OperationHistory />
                    <DispatchHistory />
                </div>
            ) : null}
            {tab === 'stats' ? <MissionStats /> : null}
            {tab === 'deleted' ? <DeletedMissions onChanged={refetchAll} /> : null}
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
                            rowClassName={r => (r.loadError ? 'is-muted' : undefined)}
                            onRowClick={r => setDrawerOf(r.id)}
                            empty={t('admin.missions.none')}
                            aria-label={t('ui.screen.admin_missions')}
                        />
                    </>
                )
            ) : null}
            {tab === 'builder' ? <BuilderWorkspace scope="admin" newRequest={newRequest} /> : null}
            {tab === 'dispatch' ? (
                <div className="builder_client-op">
                    <MissionCallsPanel scope="admin" />
                    <LocationPlays missions={rows.map(r => ({ id: r.id, label: r.label }))} />
                </div>
            ) : null}
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
            <MissionDrawer
                mission={tab === 'catalog' ? drawerRow : null}
                actions={drawer.actions}
                expert={drawer.expert}
                quickEdit={!!drawerRow && drawerRow.source === 'builtin' && !!drawerRow.switch}
                busy={busy}
                onToggle={on => drawerRow && void setMission(drawerRow, on)}
                onChanged={refetchAll}
                onClose={() => setDrawerOf(null)}
            />
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
                {summary ? <LoadSummaryBody summary={summary} /> : null}
            </Dialog>
            <ConfirmDialog
                open={!!adminConfirm}
                title={
                    adminConfirm
                        ? t(`admin.missions.confirm_${adminConfirm.kind}.title`, { mission: adminConfirm.row.label })
                        : ''
                }
                message={
                    adminConfirm
                        ? t(`admin.missions.confirm_${adminConfirm.kind}.message`, { id: adminConfirm.row.id })
                        : ''
                }
                confirmLabel={adminConfirm ? t(`admin.missions.confirm_${adminConfirm.kind}.button`) : ''}
                tone={
                    adminConfirm && (adminConfirm.kind === 'reset' || adminConfirm.kind === 'delete')
                        ? 'danger'
                        : 'primary'
                }
                reason={{ required: true }}
                typedWord={
                    adminConfirm && (adminConfirm.kind === 'reset' || adminConfirm.kind === 'delete')
                        ? adminConfirm.row.id
                        : undefined
                }
                onConfirm={doAdminConfirm}
                onCancel={() => setAdminConfirm(null)}
                busy={admin.busy}
            />
            <LoadProblemDialog
                failure={problem?.loadError ?? null}
                label={problem?.label ?? ''}
                onClose={() => setProblem(null)}
            />
            <CompareDialog
                id={openDialog?.kind === 'compare' ? openDialog.row.id : null}
                label={openDialog?.row.label ?? ''}
                onClose={() => setOpenDialog(null)}
                onDone={refetchAll}
            />
            <VersionsDialog
                id={openDialog?.kind === 'versions' ? openDialog.row.id : null}
                label={openDialog?.row.label ?? ''}
                onClose={() => setOpenDialog(null)}
                onDone={refetchAll}
            />
            <CopyLuaDialog
                id={openDialog?.kind === 'copy' ? openDialog.row.id : null}
                label={openDialog?.row.label ?? ''}
                onClose={() => setOpenDialog(null)}
            />
            <ChangeOwnerDialog
                id={openDialog?.kind === 'owner' ? openDialog.row.id : null}
                label={openDialog?.row.label ?? ''}
                onClose={() => setOpenDialog(null)}
                onDone={refetchAll}
            />
            <ImportDialog
                open={importOpen}
                onClose={() => setImportOpen(false)}
                onImported={id => {
                    refetchAll();
                    openInBuilder(id);
                }}
            />
        </Screen>
    );
}

// ============================================================================
//                        MISSION AND LOCATION SWITCHES
// ============================================================================

function MissionSwitch({
    row,
    busy,
    onToggle,
    onLocations,
}: {
    row: CatalogRow;
    busy: boolean;
    onToggle: (row: CatalogRow, enabled: boolean) => void;
    onLocations: (id: string) => void;
}) {
    const sw = row.switch;
    if (!sw) return null;
    const total = sw.locations.length;
    const on = total - sw.locationsOff;
    return (
        <div className="settings-switch" {...stopRow}>
            <Toggle
                checked={sw.on}
                disabled={busy}
                label={sw.on ? t('settings.mission.on') : t('settings.mission.off')}
                onChange={v => onToggle(row, v)}
            />
            <Button
                size="sm"
                variant="ghost"
                icon="mapPin"
                onClick={() => onLocations(row.id)}
                title={t('settings.mission.locations_hint')}
            >
                {t('settings.mission.locations', { on, total })}
            </Button>
            {sw.changed ? (
                <Badge size="sm" tone="accent" icon="edit" title={t('settings.mission.changed_hint')}>
                    {t('settings.badge.changed')}
                </Badge>
            ) : null}
            {sw.on && total > 0 && on === 0 ? (
                <Badge size="sm" tone="warning" icon="alert">
                    {t('settings.mission.no_locations')}
                </Badge>
            ) : null}
        </div>
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
        const message = t('builder.confirm.publish.message', {
            version: r.entry?.draftVersion ?? 1,
            file: r.filePath ?? '',
        });
        return {
            title: t(
                r.entry?.draftTested ? 'builder.confirm.publish.title' : 'builder.confirm.publish_untested.title',
                vars,
            ),
            message: r.entry?.draftTested ? message : `${t('builder.confirm.publish_untested.message')} ${message}`,
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
