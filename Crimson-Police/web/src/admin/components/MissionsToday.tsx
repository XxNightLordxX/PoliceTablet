// Slot: Missions → Today: Type of the Day (with today's override), the Weekly Boss day and the run modifiers with their
// switches (Settings → Events). modules/livectl/server.lua (admin:getToday, server:admin:setTypeOfDay).

import { useEffect, useState } from 'react';
import { Badge, Button, Card, ConfirmDialog, Field, Row, Select } from '../../shared/components';
import { asArray } from '../../shared/data';
import { useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { useCan } from '../../shared/session';
import type { AdminTodayData } from '../../types/admin_live';
import { useAdminAction } from './kit';
import '../screens/Live.css';

export function MissionsToday(_props: Record<string, never>) {
    const can = useCan();
    const allowed = can('liveRuns');
    const { data, refetch } = useRequest<AdminTodayData>('admin:getToday', {}, { skip: !allowed, pollMs: 60000 });
    const { run, busy } = useAdminAction();
    const [open, setOpen] = useState(false);
    const [choice, setChoice] = useState('auto');

    useEffect(() => {
        if (open) setChoice(data?.override?.type ?? 'auto');
    }, [open, data]);

    if (!allowed || !data) return null;

    const types = asArray(data.types);
    const labelOf = (key: string | null | undefined) => types.find(x => x.key === key)?.label ?? key ?? '';
    const options = [
        { value: 'auto', label: t('admin.today.choice_auto', { type: labelOf(data.rolled) || '—' }) },
        { value: 'none', label: t('admin.today.choice_none') },
        ...types.map(x => ({ value: x.key, label: x.label })),
    ];

    const save = async (reason: string) => {
        const res = await run(
            'server:admin:setTypeOfDay',
            { type: choice, reason },
            { success: 'admin.today.saved', requestId: false },
        );
        setOpen(false);
        if (res.ok) void refetch();
    };

    return (
        <Card
            title={t('admin.today.title')}
            icon="calendar"
            subtitle={t('admin.today.subtitle', { day: data.day })}
            actions={
                <Button
                    size="sm"
                    variant="secondary"
                    icon="edit"
                    disabled={!data.todEnabled}
                    title={data.todEnabled ? undefined : t('admin.today.tod_off')}
                    onClick={() => setOpen(true)}
                >
                    {t('admin.today.change')}
                </Button>
            }
        >
            <div className="admin-runctl-grid">
                <div className="admin-runctl-box">
                    <span className="admin-runctl-box__title">{t('admin.today.tod')}</span>
                    {!data.todEnabled ? (
                        <span className="admin-live-muted">{t('admin.today.tod_off')}</span>
                    ) : (
                        <>
                            <Row gap={2}>
                                <strong>
                                    {data.typeOfTheDay ? labelOf(data.typeOfTheDay) : t('admin.today.none')}
                                </strong>
                                {data.override ? (
                                    <Badge size="sm" tone="accent">
                                        {t('admin.today.overridden')}
                                    </Badge>
                                ) : null}
                            </Row>
                            <span className="admin-runctl-item__sub">
                                {data.override
                                    ? t('admin.today.override_by', {
                                          by: data.override.by ?? '?',
                                          reason: data.override.reason ?? '',
                                      })
                                    : t('admin.today.multiplier', { x: data.todMultiplier })}
                            </span>
                        </>
                    )}
                </div>
                <div className="admin-runctl-box">
                    <span className="admin-runctl-box__title">{t('admin.today.boss')}</span>
                    <span>
                        {!data.boss.enabled
                            ? t('admin.today.boss_off')
                            : data.boss.today
                              ? t('admin.today.boss_today')
                              : t('admin.today.boss_not_today')}
                    </span>
                </div>
                <div className="admin-runctl-box">
                    <span className="admin-runctl-box__title">
                        {t('admin.today.modifiers', { pct: Math.round(data.modifierChance * 100) })}
                    </span>
                    <Row gap={2} className="admin-runctl-actions">
                        {asArray(data.modifiers).map(m => (
                            <Badge key={m.key} size="sm" tone={m.enabled ? 'success' : 'grey'}>
                                {m.label} · {t(m.enabled ? 'admin.today.on' : 'admin.today.off')}
                            </Badge>
                        ))}
                    </Row>
                    <span className="admin-runctl-item__sub">{t('admin.today.modifiers_hint')}</span>
                </div>
            </div>
            <ConfirmDialog
                open={open}
                title={t('admin.today.change_title')}
                message={t('admin.today.change_message')}
                effect={
                    <Field label={t('admin.today.tod')}>
                        <Select value={choice} onChange={setChoice} options={options} />
                    </Field>
                }
                confirmLabel={t('admin.today.save')}
                reason={{ required: true, label: t('common.reason'), maxLength: 255 }}
                onConfirm={reason => save(reason)}
                onCancel={() => setOpen(false)}
                busy={busy}
            />
        </Card>
    );
}
