// Admin UI · Permissions (screen key 'admin_permissions'): supervisor powers, admin-only actions and Config health.

import {
    Badge,
    Card,
    EmptyState,
    ErrorState,
    Grid,
    Icon,
    IconButton,
    LoadingBlock,
    Screen,
    Table,
    Toggle,
    type TableColumn,
} from '../../shared/components';
import { asArray } from '../../shared/data';
import { useAction, useRequest } from '../../shared/hooks';
import { hasKey, t } from '../../shared/i18n';
import type { ConfigHealthItem } from '../../shared/types';
import type { PermissionsData } from '../../types/oversight';
import './Permissions.css';
import '../components/access-admin.css';

interface PermRow {
    action: string;
    enabled: boolean;
}

const label = (a: string) => (hasKey(`admin.perm.${a}`) ? t(`admin.perm.${a}`) : a);
const desc = (a: string) => (hasKey(`admin.perm_desc.${a}`) ? t(`admin.perm_desc.${a}`) : '');

const HEALTH_TONE = { ok: 'success', warn: 'warning', error: 'danger' } as const;
const HEALTH_ICON = { ok: 'checkCircle', warn: 'alert', error: 'xCircle' } as const;

// Config health (modules/confighealth): every check's lines, problems first.
function ConfigHealthCard() {
    const { data, loading, error, refetch } = useRequest<ConfigHealthItem[]>('admin:getConfigHealth', {});
    const items = asArray(data);
    const problems = items.filter(i => i.level !== 'ok').length;
    return (
        <Card
            title={t('access.health.title')}
            icon="activity"
            subtitle={
                data
                    ? problems > 0
                        ? t('access.health.problems', { n: problems })
                        : t('access.health.all_ok')
                    : t('access.health.subtitle')
            }
            actions={
                <IconButton
                    icon="refresh"
                    label={t('access.health.recheck')}
                    variant="secondary"
                    size="sm"
                    loading={loading && !!data}
                    onClick={() => void refetch()}
                />
            }
        >
            {loading && !data ? (
                <LoadingBlock />
            ) : error && !data ? (
                <ErrorState error={error} onRetry={() => void refetch()} />
            ) : items.length === 0 ? (
                <EmptyState compact title={t('access.health.none')} />
            ) : (
                <ul className="access-health">
                    {items.map((i, n) => (
                        <li key={`${i.check}-${n}`} className={`access-health__item access-health__item--${i.level}`}>
                            <Badge
                                tone={HEALTH_TONE[i.level] ?? 'grey'}
                                size="sm"
                                icon={HEALTH_ICON[i.level] ?? 'info'}
                            >
                                {t(`access.health.level.${i.level}`)}
                            </Badge>
                            <span className="access-health__check">
                                {hasKey(`access.health.check.${i.check}`)
                                    ? t(`access.health.check.${i.check}`)
                                    : i.check}
                            </span>
                            <span className="access-health__text">{i.text}</span>
                        </li>
                    ))}
                </ul>
            )}
        </Card>
    );
}

export default function AdminPermissions() {
    const { data, loading, error, refetch } = useRequest<PermissionsData>(
        'admin:getPermissions',
        {},
        { pushTopic: 'settings' },
    );
    const { run, busy } = useAction();
    // A switch is the setting Config.Permissions.supervisor.<action> (Admin UI → Settings), saved over config.lua.
    const setPermission = async (action: string, enabled: boolean) => {
        const res = await run(
            'server:admin:setSetting',
            { path: `Permissions.supervisor.${action}`, value: enabled },
            {
                success: enabled ? 'admin.perms.switched_on' : 'admin.perms.switched_off',
                successVars: { action: label(action) },
            },
        );
        if (res.ok) void refetch();
    };
    const rows = asArray(data?.supervisor);
    const adminOnly = asArray(data?.adminOnly);
    const always = asArray(data?.always);
    const on = rows.filter(r => r.enabled).length;

    const columns: TableColumn<PermRow>[] = [
        {
            key: 'action',
            header: t('admin.perms.col.action'),
            width: 250,
            render: r => (
                <div className="oversight-perm-name">
                    <strong>{label(r.action)}</strong>
                    <code>{r.action}</code>
                </div>
            ),
        },
        {
            key: 'desc',
            header: t('admin.perms.col.description'),
            render: r => <span className="oversight-perm-desc">{desc(r.action)}</span>,
        },
        {
            key: 'status',
            header: t('admin.perms.col.status'),
            width: 130,
            align: 'center',
            render: r => (
                <Toggle
                    checked={r.enabled}
                    disabled={busy}
                    label={r.enabled ? t('admin.perms.on') : t('admin.perms.off')}
                    onChange={v => void setPermission(r.action, v)}
                />
            ),
        },
    ];

    let body;
    if (loading && !data) body = <LoadingBlock />;
    else if (error && !data)
        body = (
            <Card>
                <ErrorState error={error} onRetry={() => void refetch()} />
            </Card>
        );
    else
        body = (
            <>
                <ConfigHealthCard />
                <div className="oversight-perm-banner">
                    <Icon name="sliders" size={16} />
                    <div>
                        <strong>{t('admin.perms.readonly')}</strong>
                        <span>{t('admin.perms.edit_hint')}</span>
                    </div>
                </div>
                <Card
                    title={t('admin.perms.supervisor')}
                    icon="shieldCheck"
                    subtitle={t('admin.perms.supervisor_count', { on, total: rows.length })}
                    padding="none"
                >
                    <Table
                        columns={columns}
                        rows={rows}
                        rowKey={r => r.action}
                        empty={<EmptyState compact title={t('admin.perms.none')} />}
                        aria-label={t('admin.perms.supervisor')}
                    />
                </Card>
                <Grid cols="1fr 1fr" gap={4} align="start">
                    <Card title={t('admin.perms.always')} icon="checkCircle" subtitle={t('admin.perms.always_text')}>
                        <ul className="oversight-perm-list">
                            {always.map(a => (
                                <li key={a}>
                                    <Badge tone="success" size="sm" icon="check">
                                        {t('admin.perms.on')}
                                    </Badge>
                                    <div>
                                        <strong>{label(a)}</strong>
                                        <span>{desc(a)}</span>
                                    </div>
                                </li>
                            ))}
                        </ul>
                    </Card>
                    <Card title={t('admin.perms.admin_only')} icon="key" subtitle={t('admin.perms.admin_only_text')}>
                        <ul className="oversight-perm-list">
                            {adminOnly.map(a => (
                                <li key={a}>
                                    <Badge tone="danger" size="sm" icon="lock">
                                        {t('admin.perms.admin')}
                                    </Badge>
                                    <div>
                                        <strong>{label(a)}</strong>
                                        <span>{desc(a)}</span>
                                    </div>
                                </li>
                            ))}
                        </ul>
                    </Card>
                </Grid>
                <div className="oversight-perm-rule">
                    <Icon name="shield" size={15} />
                    <span>{t('admin.perms.own_rule')}</span>
                </div>
            </>
        );

    return (
        <Screen
            title={t('ui.screen.admin_permissions')}
            subtitle={t('admin.perms.subtitle')}
            actions={
                <IconButton
                    icon="refresh"
                    label={t('sup.refresh')}
                    variant="secondary"
                    loading={loading && !!data}
                    onClick={() => void refetch()}
                />
            }
            className="oversight-screen"
        >
            {body}
        </Screen>
    );
}
