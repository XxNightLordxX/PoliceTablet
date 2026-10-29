// Admin UI · Missions: one drawer per mission (opened by clicking a catalog row). Everything about the mission in one

import { useEffect, useState } from 'react';
import {
    Badge,
    Button,
    Card,
    Dialog,
    EmptyState,
    Field,
    LoadingBlock,
    Money,
    NumberInput,
    TextInput,
    Toggle,
    type BadgeTone,
    type IconName,
} from '../../shared/components';
import { asArray } from '../../shared/data';
import { formatMoney } from '../../shared/format';
import { useAction, useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { useNavigate } from '../../shared/navigation';
import { useCan } from '../../shared/session';
import { QuickEditPanel } from '../../builder/admin';
import type { AdminPayoutsView } from '../../types/economy';
import type { MissionSwitchView } from '../../types/settings';
import type { TestLocationStatus, TestsView } from '../../types/testing';

// The part of a Missions catalog row the drawer shows.
export interface DrawerMission {
    id: string;
    label: string;
    typeLabel: string;
    source: 'builtin' | 'custom';
    isBoss: boolean;
    inPool: boolean;
    switch: MissionSwitchView | null;
}

// One labelled button of the drawer (the Missions screen decides which apply to the mission).
export interface DrawerAction {
    key: string;
    label: string;
    icon: IconName;
    onClick: () => void;
    variant?: 'primary' | 'secondary' | 'ghost' | 'danger';
    disabled?: boolean;
}

const TEST_TONE: Record<TestLocationStatus, BadgeTone> = {
    passed: 'success',
    failed: 'danger',
    untested: 'neutral',
    changed: 'warning',
    checked: 'primary',
};

export function MissionDrawer({
    mission,
    actions,
    expert,
    quickEdit,
    busy,
    onToggle,
    onChanged,
    onClose,
}: {
    mission: DrawerMission | null;
    // the everyday actions (Edit in Builder, Duplicate, Launch, Publish ...) and the expert ones (Compare, Versions ...)
    actions: DrawerAction[];
    expert: DrawerAction[];
    // Quick edit applies to a loaded built-in
    quickEdit: boolean;
    busy: boolean;
    onToggle: (enabled: boolean) => void;
    onChanged: () => void;
    onClose: () => void;
}) {
    const m = mission;
    return (
        <Dialog
            open={!!m}
            onClose={onClose}
            placement="right"
            size="lg"
            className="admin-mission-drawer"
            title={m ? m.label : ''}
            description={m ? [m.typeLabel, m.id].filter(Boolean).join(' · ') : undefined}
        >
            {m ? (
                <div className="admin-missions-stack">
                    <div className="admin-missions-chips">
                        <Badge
                            size="sm"
                            tone={m.source === 'builtin' ? 'grey' : 'primary'}
                            variant={m.source === 'builtin' ? 'outline' : 'soft'}
                            icon={m.source === 'builtin' ? 'lock' : 'tool'}
                        >
                            {t(m.source === 'builtin' ? 'admin.missions.builtin' : 'admin.missions.custom')}
                        </Badge>
                        {m.isBoss ? (
                            <Badge size="sm" tone="accent" icon="star">
                                {t('admin.missions.boss')}
                            </Badge>
                        ) : null}
                    </div>
                    {actions.length ? <ActionRow items={actions} /> : null}
                    <Card title={t('admin.missions.drawer.switches')} icon="mapPin">
                        {m.switch ? (
                            <Switches mission={m} sw={m.switch} busy={busy} onToggle={onToggle} onChanged={onChanged} />
                        ) : (
                            <div className="admin-missions-muted">{t('admin.missions.drawer.not_in_pool')}</div>
                        )}
                    </Card>
                    <PayoutSection mission={m} />
                    {quickEdit ? (
                        <Card title={t('admin.missions.quick.open')} icon="sliders">
                            <QuickEditPanel missionId={m.id} label={m.label} onSaved={onChanged} />
                        </Card>
                    ) : null}
                    <TestsSection mission={m} />
                    {expert.length ? (
                        <Card title={t('admin.missions.drawer.expert')} icon="tool">
                            <div className="admin-missions-muted">{t('admin.missions.drawer.expert_text')}</div>
                            <ActionRow items={expert} />
                        </Card>
                    ) : null}
                </div>
            ) : null}
        </Dialog>
    );
}

function ActionRow({ items }: { items: DrawerAction[] }) {
    return (
        <div className="admin-missions-buttons">
            {items.map(a => (
                <Button
                    key={a.key}
                    size="sm"
                    variant={a.variant ?? 'secondary'}
                    icon={a.icon}
                    disabled={a.disabled}
                    onClick={a.onClick}
                >
                    {a.label}
                </Button>
            ))}
        </div>
    );
}

// On/off of the mission and of each location: saved over config.lua, runs already going finish.
function Switches({
    mission,
    sw,
    busy,
    onToggle,
    onChanged,
}: {
    mission: DrawerMission;
    sw: MissionSwitchView;
    busy: boolean;
    onToggle: (enabled: boolean) => void;
    onChanged: () => void;
}) {
    const { run, busy: saving } = useAction();
    const locations = asArray(sw.locations);
    const on = locations.filter(l => l.on).length;
    const setLocation = async (index: number, enabled: boolean) => {
        const res = await run<MissionSwitchView>('server:admin:setLocationEnabled', {
            missionId: mission.id,
            index,
            enabled,
        });
        if (res.ok) onChanged();
    };
    const reset = async () => {
        const res = await run<MissionSwitchView>(
            'server:admin:resetMissionSwitches',
            { missionId: mission.id },
            { success: 'settings.mission.reset_done', successVars: { mission: mission.label } },
        );
        if (res.ok) onChanged();
    };
    return (
        <div className="admin-missions-stack">
            <div className="settings-switch">
                <Toggle
                    checked={sw.on}
                    disabled={busy || saving}
                    label={sw.on ? t('settings.mission.on') : t('settings.mission.off')}
                    onChange={onToggle}
                />
                <span className="admin-missions-muted">
                    {t('settings.mission.locations', { on, total: locations.length })}
                </span>
                {sw.on && locations.length > 0 && on === 0 ? (
                    <Badge size="sm" tone="warning" icon="alert">
                        {t('settings.mission.no_locations')}
                    </Badge>
                ) : null}
                <span className="cp-spacer" />
                <Button
                    size="sm"
                    variant="ghost"
                    icon="refresh"
                    disabled={busy || saving || !sw.changed}
                    onClick={() => void reset()}
                >
                    {t('settings.mission.reset')}
                </Button>
            </div>
            <div className="settings-locations">
                {locations.map(l => (
                    <div key={l.index} className="settings-locations__row">
                        <span className="cp-num settings-muted">{`#${l.index}`}</span>
                        <span className="settings-locations__label">{l.label}</span>
                        {l.on !== l.defaultOn ? (
                            <Badge size="sm" tone="accent">
                                {t('settings.badge.changed')}
                            </Badge>
                        ) : null}
                        <Toggle
                            checked={l.on}
                            disabled={busy || saving}
                            label={l.on ? t('settings.mission.on') : t('settings.mission.off')}
                            onChange={v => void setLocation(l.index, v)}
                        />
                    </div>
                ))}
            </div>
        </div>
    );
}

// The mission's payout (Payouts > Missions): set an admin payout or go back to the type payout.
function PayoutSection({ mission }: { mission: DrawerMission }) {
    const can = useCan();
    const allowed = can('setMissionPayout');
    const view = useRequest<AdminPayoutsView>('admin:getPayouts', {}, { skip: !allowed, pushTopic: 'payouts' });
    const { run, busy } = useAction();
    const row = asArray(view.data?.missions).find(p => p.id === mission.id) ?? null;
    const [amount, setAmount] = useState<number | null>(null);
    const [valid, setValid] = useState(true);
    const [reason, setReason] = useState('');
    useEffect(() => {
        setAmount(row ? row.base : null);
        setReason('');
    }, [row?.base, mission.id]); // eslint-disable-line react-hooks/exhaustive-deps
    if (!allowed) return null;
    const lo = view.data?.limits?.min ?? 0;
    const hi = view.data?.limits?.max ?? 25000;
    const needReason = view.data?.requireReason !== false;
    const hasAdmin = !!row && row.missionPayout !== null && row.missionPayout !== undefined;
    const reasonOk = !needReason || reason.trim().length > 0;
    const canSave = !!row && valid && amount !== null && amount >= lo && amount <= hi && amount !== row.base;
    const save = async (clear: boolean) => {
        if (!row) return;
        const payload = clear
            ? { missionId: mission.id, amount: null, clear: true, reason: reason.trim() }
            : { missionId: mission.id, amount, reason: reason.trim() };
        const res = await run('server:admin:setMissionPayout', payload, {
            success: clear ? 'admin.payouts.cleared' : 'admin.payouts.saved',
            successVars: { name: mission.label, amount: formatMoney(amount ?? 0) },
        });
        if (res.ok) void view.refetch();
    };
    return (
        <Card title={t('admin.missions.drawer.payout')} icon="dollar">
            {view.loading && !view.data ? (
                <LoadingBlock />
            ) : !row ? (
                <div className="admin-missions-muted">{t('admin.missions.drawer.payout_none')}</div>
            ) : (
                <div className="admin-missions-stack">
                    <div className="settings-switch">
                        <span>{t('admin.payouts.current')}</span>
                        <b>
                            <Money amount={row.base} />
                        </b>
                        <Badge
                            size="sm"
                            tone={hasAdmin ? 'accent' : 'neutral'}
                            variant={hasAdmin ? 'solid' : 'outline'}
                        >
                            {t(
                                row.payoutSource === 'admin'
                                    ? 'admin.payouts.permanent'
                                    : row.payoutSource === 'event'
                                      ? 'admin.payouts.src_event'
                                      : 'admin.payouts.src_type',
                            )}
                        </Badge>
                        <span className="admin-missions-muted">
                            {t('admin.missions.drawer.payout_without', { amount: formatMoney(row.fallback) })}
                        </span>
                    </div>
                    <div className="admin-missions-grid2">
                        <Field label={t('admin.payouts.new_amount')}>
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
                            <TextInput value={reason} onChange={setReason} maxLength={255} />
                        </Field>
                    </div>
                    <div className="admin-missions-buttons">
                        <Button
                            size="sm"
                            variant="ghost"
                            icon="undo"
                            disabled={busy || !hasAdmin || !reasonOk}
                            onClick={() => void save(true)}
                        >
                            {t('admin.missions.drawer.payout_clear')}
                        </Button>
                        <span className="cp-spacer" />
                        <Button
                            size="sm"
                            variant="primary"
                            icon="lock"
                            disabled={busy || !canSave || !reasonOk}
                            onClick={() => void save(false)}
                        >
                            {t('admin.payouts.set_confirm')}
                        </Button>
                    </div>
                </div>
            )}
        </Card>
    );
}

// The mission's locations as Testing shows them, with a link to the Testing screen.
function TestsSection({ mission }: { mission: DrawerMission }) {
    const can = useCan();
    const navigate = useNavigate();
    const allowed = can('testRun');
    const view = useRequest<TestsView>('admin:getTests', {}, { skip: !allowed });
    if (!allowed) return null;
    const row = asArray(view.data?.missions).find(x => x.id === mission.id) ?? null;
    return (
        <Card
            title={t('admin.missions.drawer.tests')}
            icon="flask"
            actions={
                <Button size="sm" variant="ghost" icon="flask" onClick={() => navigate('admin_testing')}>
                    {t('admin.missions.drawer.tests_open')}
                </Button>
            }
        >
            {view.loading && !view.data ? (
                <LoadingBlock />
            ) : !row || !asArray(row.locations).length ? (
                <EmptyState compact icon="flask" title={t('admin.missions.drawer.tests_none')} />
            ) : (
                <div className="settings-locations">
                    {asArray(row.locations).map(l => (
                        <div key={l.index} className="settings-locations__row">
                            <span className="cp-num settings-muted">{`#${l.index}`}</span>
                            <span className="settings-locations__label">{l.label}</span>
                            {l.last ? <span className="admin-missions-muted">{l.last.testedByName}</span> : null}
                            <Badge size="sm" tone={TEST_TONE[l.status] ?? 'neutral'}>
                                {t(`test.ui.status.${l.status}`)}
                            </Badge>
                        </div>
                    ))}
                </div>
            )}
        </Card>
    );
}
