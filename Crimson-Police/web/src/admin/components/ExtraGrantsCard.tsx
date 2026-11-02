// Admin UI -> Permissions -> Extra grants: give one power to people who are not supervisors, by department
// from a grade, Qbox gang from a grade, or single citizenid. Every change saves the setting Permissions.grants
// (server:admin:setSetting), checked and audited like any other setting; the server reads it at every check.

import { useState } from 'react';
import { Badge, Button, Card, EmptyState, Icon, IconButton, TextInput } from '../../shared/components';
import { asArray } from '../../shared/data';
import { useAction } from '../../shared/hooks';
import { hasKey, t } from '../../shared/i18n';
import type { ExtraGrantsData, PowerGrant, TeleportDepartment, TeleportGrant } from '../../types/oversight';
import { CID_PATTERN, grantCount, withCitizenid, withPower, withRule, type ExtraGrants } from './extraGrants';
import { GradeGrantRow } from './GradeGrantRow';

const PREFIX = 'admin.perms.extra.grant';
const label = (a: string) => (hasKey(`admin.perm.${a}`) ? t(`admin.perm.${a}`) : a);
const desc = (a: string) => (hasKey(`admin.perm_desc.${a}`) ? t(`admin.perm_desc.${a}`) : '');

function PowerEditor({
    grant,
    departments,
    gangs,
    busy,
    save,
}: {
    grant: PowerGrant | undefined;
    departments: TeleportDepartment[];
    gangs: ExtraGrantsData['gangs'];
    busy: boolean;
    save: (next: PowerGrant) => void;
}) {
    const [cid, setCid] = useState('');
    const cidOk = CID_PATTERN.test(cid.trim());
    const asRow = (d: TeleportDepartment, rule: TeleportGrant | undefined): TeleportDepartment => ({
        ...d,
        grant: rule,
    });
    const addCid = () => {
        if (!cidOk) return;
        save(withCitizenid(grant, cid, true));
        setCid('');
    };
    return (
        <div className="oversight-extra__editor">
            <h4>{t('admin.perms.extra.departments')}</h4>
            <ul className="oversight-teleport">
                {departments.map(d => (
                    <GradeGrantRow
                        key={d.key}
                        dept={asRow(d, grant?.departments?.[d.key])}
                        busy={busy}
                        prefix={PREFIX}
                        onSave={rule => save(withRule(grant, 'departments', d.key, rule))}
                    />
                ))}
            </ul>
            <h4>{t('admin.perms.extra.gangs')}</h4>
            {gangs.length === 0 ? (
                <span className="oversight-perm-desc">{t('admin.perms.extra.no_gangs')}</span>
            ) : (
                <ul className="oversight-teleport">
                    {gangs.map(g => (
                        <GradeGrantRow
                            key={g.key}
                            dept={{
                                key: g.key,
                                label: g.label,
                                short: g.label,
                                grades: g.grades.length ? g.grades : [{ level: 0 }],
                                grant: grant?.gangs?.[g.key],
                            }}
                            busy={busy}
                            prefix={PREFIX}
                            onSave={rule => save(withRule(grant, 'gangs', g.key, rule))}
                        />
                    ))}
                </ul>
            )}
            <h4>{t('admin.perms.extra.citizenids')}</h4>
            <div className="oversight-extra__cids">
                {asArray(grant?.citizenids).map(c => (
                    <Badge key={c} tone="accent" size="sm">
                        <code>{c}</code>
                        <IconButton
                            icon="x"
                            size="sm"
                            variant="ghost"
                            label={t('admin.perms.extra.remove', { cid: c })}
                            disabled={busy}
                            onClick={() => save(withCitizenid(grant, c, false))}
                        />
                    </Badge>
                ))}
            </div>
            <div className="oversight-extra__add">
                <TextInput
                    value={cid}
                    onChange={setCid}
                    onEnter={addCid}
                    maxLength={16}
                    invalid={cid !== '' && !cidOk}
                    placeholder={t('admin.perms.extra.cid_placeholder')}
                    aria-label={t('admin.perms.extra.citizenids')}
                />
                <Button size="sm" icon="plus" disabled={busy || !cidOk} onClick={addCid}>
                    {t('admin.perms.extra.add')}
                </Button>
            </div>
            {cid !== '' && !cidOk ? (
                <span className="oversight-perm-desc">{t('admin.perms.extra.cid_bad')}</span>
            ) : null}
        </div>
    );
}

export function ExtraGrantsCard({
    data,
    departments,
    onSaved,
}: {
    data: ExtraGrantsData;
    departments: TeleportDepartment[];
    onSaved: () => void;
}) {
    const { run, busy } = useAction();
    const [open, setOpen] = useState<string | null>(null);
    const grants: ExtraGrants = data.grants && !Array.isArray(data.grants) ? data.grants : {};
    const powers = asArray(data.powers);
    const gangs = asArray(data.gangs);
    const save = async (power: string, next: PowerGrant) => {
        const res = await run(
            'server:admin:setSetting',
            { path: 'Permissions.grants', value: withPower(grants, power, next) },
            { success: 'admin.perms.extra.saved', successVars: { power: label(power) } },
        );
        if (res.ok) onSaved();
    };
    return (
        <Card title={t('admin.perms.extra.title')} icon="users" subtitle={t('admin.perms.extra.subtitle')}>
            {powers.length === 0 ? (
                <EmptyState compact title={t('admin.perms.extra.none')} />
            ) : (
                <ul className="oversight-extra">
                    {powers.map(p => {
                        const n = grantCount(grants[p.key]);
                        const editing = open === p.key;
                        return (
                            <li key={p.key} className="oversight-extra__row">
                                <div className="oversight-extra__head">
                                    <div className="oversight-perm-name">
                                        <strong>{label(p.key)}</strong>
                                        <span className="oversight-perm-desc">{desc(p.key)}</span>
                                    </div>
                                    {!p.on ? (
                                        <Badge tone="warning" size="sm" icon="alert">
                                            {t('admin.perms.extra.switched_off')}
                                        </Badge>
                                    ) : null}
                                    <Badge tone={n > 0 ? 'success' : 'grey'} size="sm">
                                        {n > 0 ? t('admin.perms.extra.count', { n }) : t('admin.perms.extra.nobody')}
                                    </Badge>
                                    <Button
                                        size="sm"
                                        variant={editing ? 'secondary' : 'ghost'}
                                        icon={editing ? 'check' : 'edit'}
                                        onClick={() => setOpen(editing ? null : p.key)}
                                    >
                                        {editing ? t('admin.perms.extra.done') : t('admin.perms.extra.edit')}
                                    </Button>
                                </div>
                                {editing ? (
                                    <PowerEditor
                                        grant={grants[p.key]}
                                        departments={departments}
                                        gangs={gangs}
                                        busy={busy}
                                        save={next => void save(p.key, next)}
                                    />
                                ) : null}
                            </li>
                        );
                    })}
                </ul>
            )}
            <div className="oversight-perm-rule">
                <Icon name="shield" size={15} />
                <span>{t('admin.perms.extra.rule')}</span>
            </div>
        </Card>
    );
}
