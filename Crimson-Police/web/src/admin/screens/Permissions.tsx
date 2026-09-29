// Admin UI · Permissions (screen key 'admin_permissions').

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
    type TableColumn,
} from '../../shared/components';
import { asArray } from '../../shared/data';
import { useRequest } from '../../shared/hooks';
import { hasKey, t } from '../../shared/i18n';
import type { PermissionsData } from '../../types/oversight';
import './Permissions.css';

interface PermRow {
    action: string;
    enabled: boolean;
}

const label = (a: string) => (hasKey(`admin.perm.${a}`) ? t(`admin.perm.${a}`) : a);
const desc = (a: string) => (hasKey(`admin.perm_desc.${a}`) ? t(`admin.perm_desc.${a}`) : '');

export default function AdminPermissions() {
    const { data, loading, error, refetch } = useRequest<PermissionsData>('admin:getPermissions', {});
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
            render: r =>
                r.enabled ? (
                    <Badge tone="success" icon="checkCircle">
                        {t('admin.perms.on')}
                    </Badge>
                ) : (
                    <Badge tone="grey" icon="minusCircle">
                        {t('admin.perms.off')}
                    </Badge>
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
                <div className="oversight-perm-banner">
                    <Icon name="lock" size={16} />
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
