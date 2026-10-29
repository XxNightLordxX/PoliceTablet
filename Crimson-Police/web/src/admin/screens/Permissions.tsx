// Admin UI · Permissions (screen key 'admin_permissions'): supervisor powers, admin-only actions and Config health.

import { useEffect, useState } from 'react';
import {
    Badge,
    Button,
    Card,
    Checkbox,
    EmptyState,
    ErrorState,
    Grid,
    Icon,
    IconButton,
    LoadingBlock,
    Screen,
    Select,
    Table,
    Toggle,
    type TableColumn,
} from '../../shared/components';
import { asArray } from '../../shared/data';
import { useAction, useRequest } from '../../shared/hooks';
import { hasKey, t } from '../../shared/i18n';
import { useNavigate } from '../../shared/navigation';
import type { ConfigHealthItem } from '../../shared/types';
import { copyLine } from '../components/copyText';
import type { PermissionsData, TeleportDepartment, TeleportGrant } from '../../types/oversight';
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

// A health line may name the setting that fixes it (opens Settings at it) or a server.cfg line to paste.
type HealthLine = ConfigHealthItem & { fix?: string; cfgLine?: string };

// Config health (modules/confighealth): every check's lines, problems first.
function ConfigHealthCard() {
    const { data, loading, error, refetch } = useRequest<HealthLine[]>('admin:getConfigHealth', {});
    const navigate = useNavigate();
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
                            {i.fix ? (
                                <Button
                                    size="sm"
                                    variant="ghost"
                                    icon="edit"
                                    onClick={() => navigate('admin_settings', { q: i.fix })}
                                >
                                    {t('sysadmin.ui.fix_open')}
                                </Button>
                            ) : null}
                            {i.cfgLine ? (
                                <Button
                                    size="sm"
                                    variant="ghost"
                                    icon="fileText"
                                    onClick={() => copyLine(i.cfgLine ?? '')}
                                >
                                    {t('sysadmin.ui.copy_line')}
                                </Button>
                            ) : null}
                        </li>
                    ))}
                </ul>
            )}
        </Card>
    );
}

type TeleportMode = 'off' | 'min' | 'list';

const gradeName = (d: TeleportDepartment, level: number) => {
    const g = d.grades.find(x => x.level === level);
    return g?.name ? `${level} ${g.name}` : String(level);
};

function summary(d: TeleportDepartment): string {
    const g = d.grant;
    if (g?.minGrade !== undefined) return t('admin.perms.teleport.summary_min', { grade: gradeName(d, g.minGrade) });
    if (g?.grades) return t('admin.perms.teleport.summary_list', { grades: g.grades.join(', ') });
    return t('admin.perms.teleport.summary_off');
}

// One department: Off / From grade N / These grades, saved with the whole Config.Permissions.builderTeleport map.
function TeleportRow({
    dept,
    busy,
    onSave,
}: {
    dept: TeleportDepartment;
    busy: boolean;
    onSave: (grant: TeleportGrant | undefined) => void;
}) {
    const initialMode = (): TeleportMode =>
        dept.grant?.minGrade !== undefined ? 'min' : dept.grant?.grades ? 'list' : 'off';
    const lowest = dept.supervisorGrade ?? dept.grades[0]?.level ?? 0;
    const [mode, setMode] = useState<TeleportMode>(initialMode);
    const [minGrade, setMinGrade] = useState<number>(dept.grant?.minGrade ?? lowest);
    const [picked, setPicked] = useState<number[]>(dept.grant?.grades ?? []);
    const grantKey = JSON.stringify(dept.grant ?? null);
    useEffect(() => {
        setMode(initialMode());
        setMinGrade(dept.grant?.minGrade ?? lowest);
        setPicked(dept.grant?.grades ?? []);
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [grantKey]);
    const next: TeleportGrant | undefined =
        mode === 'min' ? { minGrade } : mode === 'list' ? { grades: [...picked].sort((a, b) => a - b) } : undefined;
    const dirty = JSON.stringify(next ?? null) !== grantKey;
    const invalid = mode === 'list' && picked.length === 0;
    const toggle = (level: number, on: boolean) =>
        setPicked(p => (on ? [...p.filter(x => x !== level), level] : p.filter(x => x !== level)));
    return (
        <li className="oversight-teleport-row">
            <div className="oversight-teleport-row__head">
                <div className="oversight-perm-name">
                    <strong>{dept.label}</strong>
                    <code>{dept.key}</code>
                </div>
                <Badge tone={dept.grant ? 'success' : 'grey'} size="sm">
                    {summary(dept)}
                </Badge>
            </div>
            <div className="oversight-teleport-row__controls">
                <Select
                    aria-label={t('admin.perms.teleport.mode')}
                    value={mode}
                    onChange={v => setMode(v as TeleportMode)}
                    options={[
                        { value: 'off', label: t('admin.perms.teleport.mode_off') },
                        { value: 'min', label: t('admin.perms.teleport.mode_min') },
                        { value: 'list', label: t('admin.perms.teleport.mode_list') },
                    ]}
                />
                {mode === 'min' ? (
                    <Select
                        aria-label={t('admin.perms.teleport.min_grade')}
                        value={String(minGrade)}
                        onChange={v => setMinGrade(Number(v))}
                        options={dept.grades.map(g => ({ value: String(g.level), label: gradeName(dept, g.level) }))}
                    />
                ) : null}
                <Button size="sm" icon="check" disabled={busy || !dirty || invalid} onClick={() => onSave(next)}>
                    {t('admin.perms.teleport.save')}
                </Button>
            </div>
            {mode === 'list' ? (
                <div className="oversight-teleport-row__grades">
                    {dept.grades.map(g => (
                        <Checkbox
                            key={g.level}
                            checked={picked.includes(g.level)}
                            onChange={on => toggle(g.level, on)}
                            label={gradeName(dept, g.level)}
                        />
                    ))}
                    {invalid ? <span className="oversight-perm-desc">{t('admin.perms.teleport.pick_one')}</span> : null}
                </div>
            ) : null}
            {dept.supervisorGrade !== undefined ? (
                <span className="oversight-perm-desc">
                    {t('admin.perms.teleport.supervisor_from', { grade: gradeName(dept, dept.supervisorGrade) })}
                </span>
            ) : null}
        </li>
    );
}

// Admin UI -> Permissions -> Builder teleport: the setting Config.Permissions.builderTeleport, saved and audited like
// every other setting (server:admin:setSetting).
function TeleportCard({
    data,
    busy,
    onSave,
}: {
    data: NonNullable<PermissionsData['teleport']>;
    busy: boolean;
    onSave: (dept: TeleportDepartment, grant: TeleportGrant | undefined) => void;
}) {
    const depts = asArray(data.departments);
    return (
        <Card title={t('admin.perms.teleport.title')} icon="mapPin" subtitle={t('admin.perms.teleport.subtitle')}>
            {!data.enabled ? (
                <div className="oversight-perm-banner">
                    <Icon name="info" size={16} />
                    <span>{t('admin.perms.teleport.off_banner')}</span>
                </div>
            ) : null}
            {depts.length === 0 ? (
                <EmptyState compact title={t('admin.perms.teleport.none')} />
            ) : (
                <ul className="oversight-teleport">
                    {depts.map(d => (
                        <TeleportRow key={d.key} dept={d} busy={busy} onSave={g => onSave(d, g)} />
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
    // The whole map with this department's grant replaced (or removed for Off).
    const saveTeleport = async (dept: TeleportDepartment, grant: TeleportGrant | undefined) => {
        const value: Record<string, TeleportGrant> = {};
        for (const d of asArray(data?.teleport?.departments)) {
            const g = d.key === dept.key ? grant : d.grant;
            if (g) value[d.key] = g;
        }
        const res = await run(
            'server:admin:setSetting',
            { path: 'Permissions.builderTeleport', value },
            { success: 'admin.perms.teleport_saved', successVars: { dept: dept.short } },
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
                {data?.teleport ? (
                    <TeleportCard data={data.teleport} busy={busy} onSave={(d, g) => void saveTeleport(d, g)} />
                ) : null}
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
