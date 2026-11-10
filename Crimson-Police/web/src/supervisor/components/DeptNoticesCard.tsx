// Supervisor UI · Department → Calls & notices · Department notices (the notices Mission control): post a short notice

// Supervisor UI · Department → Calls & notices · Department notices (the notices Mission control): post a short notice
// for the supervisor's own department (it shows on that department's Officer Home Announcements card only) and end
// one that is still running. Server: sup:getDeptNotices, server:sup:postNotice, server:sup:endNotice. the
// card is split by task (Post a notice, Running now), shows the stale line when a refresh fails; End takes two clicks.

import { useState } from 'react';
import { Button, Card, EmptyState, Field, NumberInput, Textarea } from '../../shared/components';
import { asArray } from '../../shared/data';
import { fmtDateTime } from '../../shared/format';
import { useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import type { DeptNoticesView } from '../../types/oversight';
import { useAdminAction } from '../../admin/components/kit';
import { ScreenStatus } from '../../officer/components/ScreenStatus';
import { screenStateOf } from '../../officer/screens/screenHead';

export function DeptNoticesCard() {
    const { data, loading, error, refetch } = useRequest<DeptNoticesView>(
        'sup:getDeptNotices',
        {},
        { pushTopic: 'missionControls' },
    );
    const { run, busy } = useAdminAction();
    const [text, setText] = useState('');
    const [days, setDays] = useState<number | null>(3);
    const [ending, setEnding] = useState<number | null>(null);
    if (!data) return null;
    const notices = asArray(data.notices);
    const usedUp = data.perDay !== undefined && (data.usedToday ?? 0) >= data.perDay;
    const full = notices.length >= data.activeMax;
    const ok = !busy && !usedUp && !full && text.trim().length > 0 && text.length <= data.maxLength && !!days;

    const post = async () => {
        if (!ok) return;
        const res = await run(
            'server:sup:postNotice',
            { text: text.trim(), days },
            { requestId: false, success: 'sup.notices.posted' },
        );
        if (res.ok) setText('');
        void refetch();
    };
    const end = async (id: number) => {
        // two clicks: the first arms the button
        if (ending !== id) {
            setEnding(id);
            window.setTimeout(() => setEnding(cur => (cur === id ? null : cur)), 3000);
            return;
        }
        setEnding(null);
        await run('server:sup:endNotice', { id }, { requestId: false, success: 'sup.notices.ended' });
        void refetch();
    };

    return (
        <Card title={t('sup.notices.title', { dept: data.short })} subtitle={t('mc.control_desc.notices')}>
            <div className="sup-mc-notices">
                <ScreenStatus
                    state={screenStateOf(true, loading, error)}
                    error={error}
                    onRetry={() => void refetch()}
                />
                <h4 className="cp-section-title">{t('sup.notices.post_title')}</h4>
                <Field label={t('sup.notices.text', { n: data.maxLength })} required>
                    <Textarea value={text} onChange={setText} maxLength={data.maxLength} rows={3} disabled={busy} />
                </Field>
                <Field label={t('sup.notices.days', { max: data.maxDays })} required>
                    <NumberInput value={days} onChange={setDays} min={1} max={data.maxDays} stepper disabled={busy} />
                </Field>
                <div className="sup-mc-row__actions">
                    {data.perDay !== undefined ? (
                        <span className="sup-mc-row__wait">
                            {t('sup.notices.used', { used: data.usedToday ?? 0, n: data.perDay })}
                        </span>
                    ) : null}
                    {full ? (
                        <span className="sup-mc-row__wait">{t('sup.notices.full', { n: data.activeMax })}</span>
                    ) : null}
                    <Button size="sm" variant="primary" icon="check" disabled={!ok} onClick={() => void post()}>
                        {t('sup.notices.post')}
                    </Button>
                </div>
                <h4 className="cp-section-title">{t('sup.notices.running', { n: notices.length })}</h4>
                {notices.length ? (
                    <ul className="sup-mc-notices__list">
                        {notices.map(n => (
                            <li key={n.id}>
                                <span>{n.text}</span>
                                <span className="sup-mc-row__who">
                                    {t('sup.notices.until', { date: fmtDateTime(n.expiresAt) })}
                                </span>
                                <Button
                                    size="sm"
                                    variant={ending === n.id ? 'danger' : 'ghost'}
                                    icon="trash"
                                    disabled={busy}
                                    onClick={() => void end(n.id)}
                                >
                                    {ending === n.id ? t('sup.notices.end_confirm') : t('sup.notices.end')}
                                </Button>
                            </li>
                        ))}
                    </ul>
                ) : (
                    <EmptyState compact icon="bell" title={t('sup.notices.none')} />
                )}
            </div>
        </Card>
    );
}
