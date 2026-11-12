// Admin UI · System (screen key 'admin_system'): storage (status, copy, switch), backups and restore, webhook states
// (read only), recent problems, the other resources and the timed jobs. Every action is checked again on the server.

import { useEffect, useState, type ReactNode } from 'react';
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
    Grid,
    Icon,
    IconButton,
    KeyValue,
    LoadingBlock,
    Screen,
    Select,
    Table,
    Tabs,
    TextInput,
    type TableColumn,
} from '../../shared/components';
import { asArray } from '../../shared/data';
import { formatDateTime, formatNumber } from '../../shared/format';
import { useRequest } from '../../shared/hooks';
import { hasKey, t } from '../../shared/i18n';
import { useNavigation } from '../../shared/navigation';
import { request } from '../../shared/nui';
import { applyReplyView } from '../../shared/replyView';
import { toast } from '../../shared/toast';
import { copyLine } from '../components/copyText';
import { useAdminAction } from '../components/kit';
import type {
    BackupView,
    BackupsData,
    IntegrationsData,
    JobView,
    JobsView,
    ProblemLine,
    ProblemsData,
    RestorePreview,
    StorageCopyReply,
    StorageView,
    WebhookView,
} from '../../types/admin_system';
import './System.css';

type Panel = 'storage' | 'backups' | 'webhooks' | 'problems' | 'integrations' | 'jobs';
// Each tab's text key is written out, so tools/check_contracts.py sees a missing one (a key built from p.key it
// can't check, and the tab then shows the raw key).
const PANELS: {
    key: Panel;
    icon: 'server' | 'download' | 'globe' | 'alert' | 'layers' | 'clock';
    label: () => string;
}[] = [
    { key: 'storage', icon: 'server', label: () => t('sysadmin.ui.tab.storage') },
    { key: 'backups', icon: 'download', label: () => t('sysadmin.ui.tab.backups') },
    { key: 'webhooks', icon: 'globe', label: () => t('sysadmin.ui.tab.webhooks') },
    { key: 'problems', icon: 'alert', label: () => t('sysadmin.ui.tab.problems') },
    { key: 'integrations', icon: 'layers', label: () => t('sysadmin.ui.tab.integrations') },
    { key: 'jobs', icon: 'clock', label: () => t('sysadmin.ui.tab.jobs') },
];

function sizeText(bytes?: number): string {
    if (!bytes) return '—';
    if (bytes >= 1048576) return `${(bytes / 1048576).toFixed(1)} MB`;
    if (bytes >= 1024) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${bytes} B`;
}

function modeLabel(mode: string | undefined): string {
    return t(mode === 'files' ? 'sysadmin.ui.mode_files' : 'sysadmin.ui.mode_database');
}

function Note({ tone = 'info', children }: { tone?: 'info' | 'warning' | 'danger'; children: ReactNode }) {
    return (
        <div className={`system-note system-note--${tone}`}>
            <Icon name={tone === 'info' ? 'info' : 'alert'} size={14} />
            <span>{children}</span>
        </div>
    );
}

function Codes({ label, items }: { label: string; items: string[] }) {
    return (
        <div className="system-codes">
            <strong>{label}</strong>
            {items.length ? items.map(k => <code key={k}>{k}</code>) : <span className="system-muted">—</span>}
        </div>
    );
}

// ============================================================================
//                                   STORAGE
// ============================================================================

function StoragePanel() {
    const { data, loading, error, refetch, setData } = useRequest<StorageView>(
        'admin:getStorage',
        {},
        { pushTopic: 'maintenance' },
    );
    const { run, busy } = useAdminAction();
    const [copy, setCopy] = useState<{ direction: string; force: boolean } | null>(null);
    const [switching, setSwitching] = useState(false);
    const [target, setTarget] = useState<'database' | 'files'>('files');
    const [folder, setFolder] = useState('saves');
    const [startEmpty, setStartEmpty] = useState(false);
    const [useAgain, setUseAgain] = useState(false);

    if (loading && !data) return <LoadingBlock />;
    if (error && !data) return <ErrorState error={error} onRetry={() => void refetch()} />;
    if (!data) return null;
    const files = data.mode === 'files';
    const migrations = data.migrations;
    const blocked = busy || data.runsGoing > 0;
    // the reply carries the fresh Storage view (data.view); an older server's reply asks again
    const fresh = (reply: unknown) => applyReplyView<StorageView>(reply, 'view', setData, () => void refetch());

    const doCopy = async (typed: string) => {
        if (!copy) return;
        const res = await run<StorageCopyReply>(
            'server:admin:storageCopy',
            { direction: copy.direction, force: copy.force, confirm: typed },
            { success: 'sysadmin.ui.copy_done' },
        );
        setCopy(null);
        if (res.ok) fresh(res.data);
    };
    const doSwitch = async (reason: string, typed: string) => {
        const res = await run(
            'server:admin:setStorageMode',
            { enabled: target === 'database', folder, startEmpty, reason, confirm: typed },
            { success: 'sysadmin.ui.switch_done' },
        );
        setSwitching(false);
        if (res.ok) fresh(res.data);
    };
    const doUseAgain = async (reason: string, typed: string) => {
        const res = await run('server:admin:useStoreAgain', { reason, confirm: typed }, { requestId: false });
        setUseAgain(false);
        if (res.ok) fresh(res.data);
    };

    return (
        <div className="system-stack">
            {data.state === 'left_behind' ? (
                <Card highlight="danger" title={t('sysadmin.ui.left_behind_title')} icon="alert">
                    <p className="system-muted">{t('sysadmin.ui.left_behind_text')}</p>
                    <Button variant="danger" icon="undo" disabled={busy} onClick={() => setUseAgain(true)}>
                        {t('sysadmin.ui.use_again')}
                    </Button>
                </Card>
            ) : null}
            {data.maintenance?.restart ? <Note tone="warning">{t('ui.maintenance.restart')}</Note> : null}
            <Card
                title={t('sysadmin.ui.storage_title')}
                subtitle={t('sysadmin.ui.storage_subtitle')}
                icon="server"
                actions={
                    <IconButton
                        icon="refresh"
                        size="sm"
                        variant="secondary"
                        label={t('sup.refresh')}
                        loading={loading}
                        onClick={() => void refetch()}
                    />
                }
            >
                <Grid min={180} gap={3}>
                    <KeyValue label={t('sysadmin.ui.mode')}>
                        <Badge tone={files ? 'accent' : 'primary'}>{modeLabel(data.mode)}</Badge>
                    </KeyValue>
                    <KeyValue label={t('sysadmin.ui.folder')}>
                        <code>{data.folder}</code>
                    </KeyValue>
                    <KeyValue label={t('sysadmin.ui.rows')}>
                        <span className="cp-num">{formatNumber(data.totalRows)}</span>
                    </KeyValue>
                    <KeyValue label={t('sysadmin.ui.size')}>{files ? sizeText(data.bytes) : '—'}</KeyValue>
                    <KeyValue label={t('sysadmin.ui.version')}>{data.version ?? '—'}</KeyValue>
                    <KeyValue label={t('sysadmin.ui.migrations')}>
                        {migrations
                            ? t('sysadmin.ui.migrations_line', {
                                  n: asArray(migrations.files).filter(f => f.applied).length,
                                  total: asArray(migrations.files).length,
                              })
                            : '—'}
                    </KeyValue>
                </Grid>
                {data.override ? (
                    <Note tone="warning">
                        {t('sysadmin.ui.override', {
                            mode: modeLabel(data.override.mode),
                            folder: data.override.folder ?? '',
                        })}
                    </Note>
                ) : null}
                {data.loadError ? <Note tone="danger">{data.loadError}</Note> : null}
                {data.error ? <Note tone="danger">{data.error}</Note> : null}
                {migrations && migrations.pending > 0 ? (
                    <Note tone="danger">{t('sysadmin.ui.migrations_pending', { n: migrations.pending })}</Note>
                ) : null}
            </Card>
            <Card title={t('sysadmin.ui.tables')} icon="list" padding="none">
                <Table
                    columns={[
                        { key: 'name', header: t('sysadmin.ui.table'), render: r => <code>{r.name}</code> },
                        {
                            key: 'rows',
                            header: t('sysadmin.ui.rows'),
                            width: 120,
                            render: r => <span className="cp-num">{formatNumber(r.rows)}</span>,
                        },
                    ]}
                    rows={asArray(data.tables)}
                    rowKey={r => r.name}
                    dense
                    aria-label={t('sysadmin.ui.tables')}
                />
            </Card>
            <Card title={t('sysadmin.ui.copy_title')} icon="swap">
                <p className="system-muted">{t('sysadmin.ui.copy_text')}</p>
                {data.runsGoing > 0 ? (
                    <Note tone="warning">{t('sysadmin.ui.runs_going', { n: data.runsGoing })}</Note>
                ) : null}
                <div className="system-buttons">
                    <Button
                        icon="download"
                        disabled={blocked}
                        onClick={() => setCopy({ direction: 'database-to-files', force: false })}
                    >
                        {t('sysadmin.ui.copy_to_files')}
                    </Button>
                    <Button
                        icon="download"
                        disabled={blocked}
                        onClick={() => setCopy({ direction: 'files-to-database', force: false })}
                    >
                        {t('sysadmin.ui.copy_to_database')}
                    </Button>
                    <Button
                        variant="danger"
                        icon="alert"
                        disabled={blocked}
                        onClick={() =>
                            setCopy({ direction: files ? 'files-to-database' : 'database-to-files', force: true })
                        }
                    >
                        {t('sysadmin.ui.copy_replace', { target: modeLabel(files ? 'database' : 'files') })}
                    </Button>
                </div>
            </Card>
            <Card title={t('sysadmin.ui.switch_title')} icon="refresh">
                <p className="system-muted">{t('sysadmin.ui.switch_text')}</p>
                <div className="system-form">
                    <Field label={t('sysadmin.ui.switch_target')}>
                        <Select
                            value={target}
                            onChange={v => setTarget(v === 'database' ? 'database' : 'files')}
                            options={[
                                { value: 'files', label: modeLabel('files') },
                                { value: 'database', label: modeLabel('database') },
                            ]}
                        />
                    </Field>
                    {target === 'files' ? (
                        <Field label={t('sysadmin.ui.folder')} hint={t('sysadmin.ui.folder_hint')}>
                            <TextInput value={folder} onChange={setFolder} maxLength={64} />
                        </Field>
                    ) : null}
                    <Checkbox checked={startEmpty} onChange={setStartEmpty} label={t('sysadmin.ui.start_empty')} />
                </div>
                <ol className="system-steps">
                    <li>{t('sysadmin.ui.switch_step1')}</li>
                    <li>{t('sysadmin.ui.switch_step2')}</li>
                    <li>{t('sysadmin.ui.switch_step3')}</li>
                    <li>{t('sysadmin.ui.switch_step4')}</li>
                </ol>
                <Button variant="danger" icon="refresh" disabled={blocked} onClick={() => setSwitching(true)}>
                    {t('sysadmin.ui.switch')}
                </Button>
            </Card>
            <ConfirmDialog
                open={!!copy}
                tone={copy?.force ? 'danger' : 'primary'}
                title={t('sysadmin.ui.copy_title')}
                message={t(copy?.force ? 'sysadmin.ui.copy_force_text' : 'sysadmin.ui.copy_confirm_text')}
                typedWord={copy?.force ? 'REPLACE' : undefined}
                confirmLabel={t('sysadmin.ui.copy')}
                onConfirm={(_r, typed) => doCopy(typed)}
                onCancel={() => setCopy(null)}
                busy={busy}
            />
            <ConfirmDialog
                open={switching}
                tone="danger"
                title={t('sysadmin.ui.switch_title')}
                message={t('sysadmin.ui.switch_confirm', { target: modeLabel(target) })}
                reason
                typedWord="SWITCH"
                confirmLabel={t('sysadmin.ui.switch')}
                onConfirm={doSwitch}
                onCancel={() => setSwitching(false)}
                busy={busy}
            />
            <ConfirmDialog
                open={useAgain}
                tone="danger"
                title={t('sysadmin.ui.use_again')}
                message={t('sysadmin.ui.use_again_text')}
                reason
                typedWord="USE"
                confirmLabel={t('sysadmin.ui.use_again')}
                onConfirm={doUseAgain}
                onCancel={() => setUseAgain(false)}
                busy={busy}
            />
        </div>
    );
}

// ============================================================================
//                                   BACKUPS
// ============================================================================

function BackupsPanel() {
    const { data, loading, error, refetch, setData } = useRequest<BackupsData>('admin:getBackups', {});
    const { run, busy } = useAdminAction();
    // the reply carries the fresh Backups list (data.view); an older server's reply asks again
    const fresh = (reply: unknown) => applyReplyView<BackupsData>(reply, 'view', setData, () => void refetch());
    const [preview, setPreview] = useState<RestorePreview | null>(null);
    const [confirmRestore, setConfirmRestore] = useState(false);
    const [deleting, setDeleting] = useState<BackupView | null>(null);

    const backupNow = async () => {
        const res = await run('server:admin:backupNow', {}, { requestId: false, success: 'sysadmin.ui.backup_done' });
        if (res.ok) fresh(res.data);
    };
    const openPreview = async (b: BackupView) => {
        const res = await request<RestorePreview>('admin:previewRestore', { name: b.name });
        if (res.ok && res.data) setPreview(res.data);
        else toast('error', t(res.error || 'err.internal'));
    };
    const doRestore = async (reason: string, typed: string) => {
        if (!preview) return;
        const res = await run(
            'server:admin:restoreBackup',
            { name: preview.backup.name, previewToken: preview.previewToken, reason, confirm: typed },
            { success: 'sysadmin.ui.restore_done' },
        );
        setConfirmRestore(false);
        setPreview(null);
        if (res.ok) fresh(res.data);
    };
    const doDelete = async (reason: string, typed: string) => {
        if (!deleting) return;
        const res = await run(
            'server:admin:deleteBackup',
            { name: deleting.name, reason, confirm: typed },
            { requestId: false, success: 'sysadmin.ui.delete_done' },
        );
        setDeleting(null);
        if (res.ok) fresh(res.data);
    };

    const columns: TableColumn<BackupView>[] = [
        {
            key: 'when',
            header: t('sysadmin.ui.when'),
            width: 150,
            render: b => <span className="cp-num">{formatDateTime(b.createdAt)}</span>,
        },
        {
            key: 'kind',
            header: t('sysadmin.ui.kind'),
            width: 160,
            render: b => (
                <span className="system-inline">
                    <Badge size="sm" tone={b.kind === 'prerestore' ? 'warning' : 'neutral'}>
                        {t(`sysadmin.ui.kind_${b.kind}`)}
                    </Badge>
                    {b.protected ? <Icon name="lock" size={12} /> : null}
                </span>
            ),
        },
        { key: 'by', header: t('sysadmin.ui.by'), width: 120, render: b => <code>{b.by}</code> },
        {
            key: 'rows',
            header: t('sysadmin.ui.rows'),
            width: 110,
            render: b => <span className="cp-num">{formatNumber(b.rows)}</span>,
        },
        { key: 'size', header: t('sysadmin.ui.size'), width: 90, render: b => sizeText(b.bytes) },
        {
            key: 'actions',
            header: '',
            width: 190,
            render: b => (
                <div className="system-buttons">
                    <Button
                        size="sm"
                        variant="secondary"
                        icon="undo"
                        disabled={busy}
                        onClick={() => void openPreview(b)}
                    >
                        {t('sysadmin.ui.restore')}
                    </Button>
                    <IconButton
                        icon="trash"
                        size="sm"
                        variant="ghost"
                        label={t('sysadmin.ui.delete')}
                        disabled={busy || b.protected}
                        onClick={() => setDeleting(b)}
                    />
                </div>
            ),
        },
    ];

    if (loading && !data) return <LoadingBlock />;
    if (error && !data) return <ErrorState error={error} onRetry={() => void refetch()} />;
    return (
        <div className="system-stack">
            <Card
                title={t('sysadmin.ui.backups_title')}
                subtitle={t('sysadmin.ui.backups_subtitle', { keep: data?.keep ?? 7, folder: data?.folder ?? '' })}
                icon="download"
                padding="none"
                actions={
                    <Button variant="primary" icon="plus" loading={busy} onClick={() => void backupNow()}>
                        {t('sysadmin.ui.backup_now')}
                    </Button>
                }
            >
                <Table
                    columns={columns}
                    rows={asArray(data?.backups)}
                    rowKey={b => b.name}
                    dense
                    empty={<EmptyState compact icon="download" title={t('sysadmin.ui.no_backups')} />}
                    aria-label={t('sysadmin.ui.backups_title')}
                />
            </Card>
            <Card title={t('sysadmin.ui.backup_holds_title')} icon="info">
                <p className="system-muted">{t('sysadmin.ui.backup_holds')}</p>
                <p className="system-muted">{t('sysadmin.ui.restore_keeps')}</p>
            </Card>
            <Dialog
                open={!!preview}
                onClose={() => setPreview(null)}
                size="lg"
                title={preview ? t('sysadmin.ui.restore_title', { name: preview.backup.name }) : ''}
                description={
                    preview ? t('sysadmin.ui.restore_desc', { when: formatDateTime(preview.backup.createdAt) }) : ''
                }
                footer={
                    <>
                        <Button variant="ghost" onClick={() => setPreview(null)}>
                            {t('common.cancel')}
                        </Button>
                        <Button
                            variant="danger"
                            icon="undo"
                            disabled={!preview || preview.runsGoing > 0}
                            onClick={() => setConfirmRestore(true)}
                        >
                            {t('sysadmin.ui.restore')}
                        </Button>
                    </>
                }
            >
                {preview ? (
                    <div className="system-stack">
                        {preview.runsGoing > 0 ? (
                            <Note tone="warning">{t('sysadmin.ui.runs_going', { n: preview.runsGoing })}</Note>
                        ) : null}
                        <Note>
                            {t('sysadmin.ui.restore_money', { runs: preview.moneyRuns, items: preview.moneyItems })}
                        </Note>
                        <Table
                            columns={[
                                { key: 'name', header: t('sysadmin.ui.table'), render: r => <code>{r.name}</code> },
                                {
                                    key: 'now',
                                    header: t('sysadmin.ui.rows_now'),
                                    width: 110,
                                    render: r => <span className="cp-num">{formatNumber(r.now)}</span>,
                                },
                                {
                                    key: 'backup',
                                    header: t('sysadmin.ui.rows_backup'),
                                    width: 120,
                                    render: r => <span className="cp-num">{formatNumber(r.backup)}</span>,
                                },
                            ]}
                            rows={asArray(preview.replaced)}
                            rowKey={r => r.name}
                            dense
                            aria-label={t('sysadmin.ui.replaced')}
                        />
                        <Codes label={t('sysadmin.ui.kept')} items={asArray(preview.kept)} />
                        <Codes label={t('sysadmin.ui.kept_settings')} items={asArray(preview.keptSettings)} />
                        <Codes label={t('sysadmin.ui.files')} items={asArray(preview.files)} />
                    </div>
                ) : null}
            </Dialog>
            <ConfirmDialog
                open={confirmRestore}
                tone="danger"
                title={t('sysadmin.ui.restore')}
                message={t('sysadmin.ui.restore_confirm')}
                reason
                typedWord="RESTORE"
                confirmLabel={t('sysadmin.ui.restore')}
                onConfirm={doRestore}
                onCancel={() => setConfirmRestore(false)}
                busy={busy}
            />
            <ConfirmDialog
                open={!!deleting}
                tone="danger"
                title={t('sysadmin.ui.delete')}
                message={t('sysadmin.ui.delete_text')}
                reason
                typedWord={deleting?.name}
                confirmLabel={t('sysadmin.ui.delete')}
                onConfirm={doDelete}
                onCancel={() => setDeleting(null)}
                busy={busy}
            />
        </div>
    );
}

// ============================================================================
//                          WEBHOOKS, PROBLEMS, OTHERS
// ============================================================================

const HOOK_TONE = { on: 'success', invalid: 'danger', off: 'grey' } as const;

function WebhooksPanel() {
    const { data, loading, error, refetch } = useRequest<{ webhooks: WebhookView[] }>('admin:getWebhooks', {});
    if (loading && !data) return <LoadingBlock />;
    if (error && !data) return <ErrorState error={error} onRetry={() => void refetch()} />;
    return (
        <Card title={t('sysadmin.ui.webhooks_title')} subtitle={t('sysadmin.ui.webhooks_subtitle')} icon="globe">
            <ul className="system-hooks">
                {asArray(data?.webhooks).map(w => (
                    <li key={w.category} className="system-hook">
                        <div className="system-hook__head">
                            <strong>{t(`sysadmin.ui.hook_category.${w.category}`)}</strong>
                            <Badge size="sm" tone={HOOK_TONE[w.state] ?? 'grey'}>
                                {t(`sysadmin.ui.hook_${w.state}`)}
                            </Badge>
                            {w.state === 'on' && !w.discord ? (
                                <Badge size="sm" tone="warning">
                                    {t('sysadmin.ui.hook_not_discord')}
                                </Badge>
                            ) : null}
                        </div>
                        <div className="system-hook__line">
                            <code>{w.line}</code>
                            <IconButton
                                icon="fileText"
                                size="sm"
                                variant="ghost"
                                label={t('sysadmin.ui.copy_line')}
                                onClick={() => copyLine(w.line)}
                            />
                        </div>
                    </li>
                ))}
            </ul>
            <Note>{t('sysadmin.ui.webhooks_note')}</Note>
        </Card>
    );
}

function ProblemsPanel() {
    const [tag, setTag] = useState('');
    const [level, setLevel] = useState('');
    const args: Record<string, string> = {};
    if (tag) args.tag = tag;
    if (level) args.level = level;
    const { data, loading, error, refetch } = useRequest<ProblemsData>('admin:getProblems', args);
    const columns: TableColumn<ProblemLine>[] = [
        {
            key: 'at',
            header: t('sysadmin.ui.when'),
            width: 150,
            render: l => <span className="cp-num">{formatDateTime(l.at)}</span>,
        },
        {
            key: 'level',
            header: '',
            width: 80,
            render: l => (
                <Badge size="sm" tone={l.level === 'error' ? 'danger' : 'warning'}>
                    {t(`sysadmin.ui.level_${l.level}`)}
                </Badge>
            ),
        },
        { key: 'tag', header: t('sysadmin.ui.tag'), width: 120, render: l => <code>{l.tag}</code> },
        { key: 'text', header: t('sysadmin.ui.text'), render: l => <span className="system-problem">{l.text}</span> },
    ];
    if (error && !data) return <ErrorState error={error} onRetry={() => void refetch()} />;
    const lines = asArray(data?.lines).map((l, i) => ({ ...l, key: `${l.at}-${i}` }));
    return (
        <Card
            title={t('sysadmin.ui.problems_title')}
            subtitle={t('sysadmin.ui.problems_subtitle', { n: formatNumber(data?.total ?? 0) })}
            icon="alert"
            padding="none"
            actions={
                <div className="system-buttons">
                    <Select
                        value={tag}
                        onChange={setTag}
                        options={[
                            { value: '', label: t('sysadmin.ui.all_tags') },
                            ...asArray(data?.tags).map(x => ({ value: x, label: x })),
                        ]}
                    />
                    <Select
                        value={level}
                        onChange={setLevel}
                        options={[
                            { value: '', label: t('sysadmin.ui.all_levels') },
                            { value: 'error', label: t('sysadmin.ui.level_error') },
                            { value: 'warn', label: t('sysadmin.ui.level_warn') },
                        ]}
                    />
                    <IconButton
                        icon="refresh"
                        size="sm"
                        variant="secondary"
                        label={t('sup.refresh')}
                        loading={loading}
                        onClick={() => void refetch()}
                    />
                </div>
            }
        >
            <Table
                columns={columns}
                rows={lines}
                rowKey={l => l.key}
                dense
                loading={loading}
                empty={<EmptyState compact icon="checkCircle" title={t('sysadmin.ui.no_problems')} />}
                aria-label={t('sysadmin.ui.problems_title')}
            />
        </Card>
    );
}

function stateLabel(state: string): string {
    return hasKey(`sysadmin.ui.res_${state}`) ? t(`sysadmin.ui.res_${state}`) : state;
}

function IntegrationsPanel() {
    const { data, loading, error, refetch } = useRequest<IntegrationsData>('admin:getIntegrations', {});
    if (loading && !data) return <LoadingBlock />;
    if (error && !data) return <ErrorState error={error} onRetry={() => void refetch()} />;
    if (!data) return null;
    return (
        <div className="system-stack">
            <Card
                title={t('sysadmin.ui.resources_title')}
                subtitle={t('sysadmin.ui.resources_subtitle')}
                icon="layers"
                padding="none"
            >
                <Table
                    columns={[
                        { key: 'name', header: t('sysadmin.ui.resource'), render: r => <code>{r.name}</code> },
                        {
                            key: 'state',
                            header: t('sysadmin.ui.state'),
                            width: 130,
                            render: r => (
                                <Badge
                                    size="sm"
                                    tone={r.state === 'started' ? 'success' : r.required ? 'danger' : 'grey'}
                                >
                                    {stateLabel(r.state)}
                                </Badge>
                            ),
                        },
                        { key: 'version', header: t('sysadmin.ui.version'), width: 110, render: r => r.version ?? '—' },
                        {
                            key: 'serves',
                            header: t('sysadmin.ui.serves'),
                            width: 150,
                            render: r =>
                                asArray(r.serves).length > 0 ? (
                                    <Badge size="sm" tone="primary">
                                        {asArray(r.serves)
                                            .map(k => t(`admin.setup.kind.${k}`))
                                            .join(', ')}
                                    </Badge>
                                ) : null,
                        },
                        {
                            key: 'required',
                            header: '',
                            width: 120,
                            render: r => (
                                <span className="system-muted">
                                    {t(r.required ? 'sysadmin.ui.required' : 'sysadmin.ui.optional')}
                                </span>
                            ),
                        },
                    ]}
                    rows={asArray(data.resources)}
                    rowKey={r => r.name}
                    dense
                    aria-label={t('sysadmin.ui.resources_title')}
                />
            </Card>
            <Card title={t('sysadmin.ui.jobs_title')} subtitle={t('sysadmin.ui.jobs_subtitle')} icon="sliders">
                <ul className="system-checklist">
                    {asArray(data.jobs).map(j => (
                        <li key={j.kind}>
                            <Icon name={j.active ? 'check' : 'alert'} size={13} />
                            {j.active
                                ? t('sysadmin.ui.job_served', { job: t(`admin.setup.kind.${j.kind}`), name: j.active })
                                : t('sysadmin.ui.job_off', { job: t(`admin.setup.kind.${j.kind}`), why: j.off ?? '' })}
                        </li>
                    ))}
                </ul>
            </Card>
            <Card title={t('sysadmin.ui.checklist_title')} icon="checkCircle">
                <ul className="system-checklist">
                    {asArray(data.checklist).map(k => (
                        <li key={k}>
                            <Icon name="check" size={13} />
                            {t(k)}
                        </li>
                    ))}
                </ul>
                <Note>{t('sysadmin.ui.checklist_note')}</Note>
            </Card>
            <Card title={t('sysadmin.ui.arena_title')} icon="shield">
                <Grid min={180} gap={3}>
                    <KeyValue label={t('sysadmin.ui.state')}>{stateLabel(data.arena.state)}</KeyValue>
                    <KeyValue label={t('sysadmin.ui.arena_players')}>
                        <span className="cp-num">{formatNumber(data.arena.players)}</span>
                    </KeyValue>
                </Grid>
                <ul className="system-checklist">
                    {asArray(data.arena.zones).map(z => (
                        <li key={z.label}>
                            <Icon name="mapPin" size={13} />
                            {t('sysadmin.ui.arena_zone', { label: z.label, radius: z.radius })}
                        </li>
                    ))}
                </ul>
                <Note>{t('sysadmin.ui.arena_note')}</Note>
            </Card>
        </div>
    );
}

// ============================================================================
//                                  THE SCREEN
// ============================================================================

// Every timed job (modules/system/schedule.lua): what it does, when it runs next, its last result and its settings,
// and Run now for the jobs an admin may start by hand.
const jobName = (id: string) => (hasKey(`sysadmin.jobs.name.${id}`) ? t(`sysadmin.jobs.name.${id}`) : id);

function JobWhen({ job }: { job: JobView }) {
    if (job.when === 'every') return <>{t('sysadmin.jobs.when.every', { min: Math.round((job.every ?? 0) / 60) })}</>;
    if (job.when === 'weekly') return <>{t('sysadmin.jobs.when.weekly')}</>;
    if (job.when === 'monthly') return <>{t('sysadmin.jobs.when.monthly')}</>;
    return <>{t('sysadmin.jobs.when.daily')}</>;
}

function JobLastLine({ job }: { job: JobView }) {
    const last = job.last;
    if (!last) return <Note>{t('sysadmin.jobs.never')}</Note>;
    const head = t('sysadmin.jobs.last_line', {
        at: formatDateTime(last.at),
        by: last.by ?? t('sysadmin.jobs.by_schedule'),
        ms: formatNumber(last.durationMs ?? 0),
    });
    let what: string;
    if (last.error) what = t('sysadmin.jobs.error', { error: last.error });
    else if (last.skipped && hasKey(`sysadmin.jobs.skipped.${last.skipped}`)) {
        what = t(`sysadmin.jobs.skipped.${last.skipped}`);
    } else if (last.result && hasKey(`sysadmin.jobs.result.${job.id}`)) {
        const vars: Record<string, string> = {};
        for (const [k, v] of Object.entries(last.result)) vars[k] = formatNumber(v);
        what = t(`sysadmin.jobs.result.${job.id}`, vars);
    } else what = t('sysadmin.jobs.result_done');
    return <Note tone={last.error ? 'danger' : 'info'}>{`${head} ${what}`}</Note>;
}

function JobsPanel() {
    const { data, loading, error, refetch, setData } = useRequest<JobsView>('admin:getJobs', {});
    const { run, busy } = useAdminAction();
    const [ask, setAsk] = useState<JobView | null>(null);
    if (loading && !data) return <LoadingBlock />;
    if (error && !data) return <ErrorState error={error} onRetry={() => void refetch()} />;
    const list = asArray<JobView>(data?.jobs);
    return (
        <Card
            title={t('sysadmin.jobs.title')}
            subtitle={t('sysadmin.jobs.subtitle', {
                hour: String(data?.resetHour ?? 0).padStart(2, '0'),
                weekday: data?.weekStartsOn ?? 'monday',
            })}
            icon="clock"
            actions={
                <Button size="sm" variant="ghost" icon="refresh" disabled={loading} onClick={() => void refetch()}>
                    {t('sysadmin.jobs.refresh')}
                </Button>
            }
        >
            {list.length === 0 ? <EmptyState title={t('sysadmin.jobs.none')} /> : null}
            <div className="system-jobs">
                {list.map(job => (
                    <Card
                        key={job.id}
                        title={jobName(job.id)}
                        subtitle={
                            hasKey(`sysadmin.jobs.desc.${job.id}`)
                                ? t(`sysadmin.jobs.desc.${job.id}`, { days: data?.requestDays ?? 7 })
                                : undefined
                        }
                        actions={
                            <>
                                <Badge tone={!job.on ? 'neutral' : job.running ? 'warning' : 'success'} size="sm">
                                    {!job.on
                                        ? t('sysadmin.jobs.state_off')
                                        : job.running
                                          ? t('sysadmin.jobs.state_running')
                                          : t('sysadmin.jobs.state_waiting')}
                                </Badge>
                                {job.manual ? (
                                    <Button
                                        size="sm"
                                        variant="secondary"
                                        icon="refresh"
                                        disabled={busy || job.running || !job.on}
                                        onClick={() => setAsk(job)}
                                    >
                                        {t('sysadmin.jobs.run_now')}
                                    </Button>
                                ) : (
                                    <Badge size="sm">{t('sysadmin.jobs.only_on_timer')}</Badge>
                                )}
                            </>
                        }
                    >
                        <Grid min={180} gap={3}>
                            <KeyValue label={t('sysadmin.jobs.next')}>
                                <JobWhen job={job} />
                                {' · '}
                                {job.nextRunAt ? formatDateTime(job.nextRunAt) : t('sysadmin.jobs.next_unknown')}
                            </KeyValue>
                            <KeyValue label={t('sysadmin.jobs.settings')}>
                                {job.settings.length === 0
                                    ? t('sysadmin.jobs.no_settings')
                                    : job.settings.map(st => `${st.path} = ${String(st.value ?? '—')}`).join(' · ')}
                            </KeyValue>
                        </Grid>
                        <JobLastLine job={job} />
                    </Card>
                ))}
            </div>
            <ConfirmDialog
                open={!!ask}
                title={`${t('sysadmin.jobs.run_now')}: ${ask ? jobName(ask.id) : ''}`}
                message={t('sysadmin.jobs.run_now_text', {
                    name: ask ? jobName(ask.id) : '',
                    min: data?.runNowMinutes ?? 10,
                })}
                reason
                onConfirm={async reason => {
                    if (!ask) return;
                    const res = await run<JobsView>(
                        'server:admin:runJobNow',
                        { id: ask.id, reason },
                        { success: 'sysadmin.jobs.run_done' },
                    );
                    if (res.ok && res.data) setData(res.data);
                    else void refetch();
                    setAsk(null);
                }}
                onCancel={() => setAsk(null)}
                busy={busy}
            />
        </Card>
    );
}

export default function AdminSystem() {
    const [panel, setPanel] = useState<Panel>('storage');
    // another screen (Home's Alerts) opens a tab with navigate('admin_system', { tab })
    const { params } = useNavigation();
    useEffect(() => {
        if (PANELS.some(p => p.key === params.tab)) setPanel(params.tab as Panel);
    }, [params]);
    let body: ReactNode = null;
    if (panel === 'storage') body = <StoragePanel />;
    else if (panel === 'backups') body = <BackupsPanel />;
    else if (panel === 'webhooks') body = <WebhooksPanel />;
    else if (panel === 'problems') body = <ProblemsPanel />;
    else if (panel === 'jobs') body = <JobsPanel />;
    else body = <IntegrationsPanel />;
    return (
        <Screen head="admin_system" subtitle={t('sysadmin.ui.subtitle')} className="system-screen">
            <Tabs<Panel>
                value={panel}
                onChange={setPanel}
                items={PANELS.map(p => ({ key: p.key, label: p.label(), icon: p.icon }))}
            />
            {body}
        </Screen>
    );
}
