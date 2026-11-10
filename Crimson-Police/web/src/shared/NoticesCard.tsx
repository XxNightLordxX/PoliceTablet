// The one notices card (modules/supervisor/notices.lua), the same for both kinds: post a notice, the notices running

// The one notices card (modules/supervisor/notices.lua), the same for both kinds: post a notice, the notices running
// now (End) and the history of ended ones. kind 'staff': Admin UI -> Leaderboards -> Recognition (pick departments, a
// reason on every post and end, every running notice listed); kind 'department': Supervisor UI -> Department -> Calls
// & notices (his own department, End takes two clicks). Server: notices:get, server:notice:post, server:notice:end.

import { useState } from 'react';
import {
    Badge,
    Button,
    Card,
    Checkbox,
    ConfirmDialog,
    EmptyState,
    Field,
    MoreFold,
    NumberInput,
    Row,
    ScreenStatus,
    Textarea,
} from './components';
import { asArray } from './data';
import { fmtDateTime } from './format';
import { useRequest } from './hooks';
import { t } from './i18n';
import { screenStateOf } from './screenHeads';
import { useSession } from './session';
import type { Notice, NoticeKind, NoticesView } from '../types/notices';
import { useAdminAction } from '../admin/components/kit';
import './NoticesCard.css';

export function NoticesCard({ kind }: { kind: NoticeKind }) {
    const session = useSession();
    const { data, loading, error, refetch } = useRequest<NoticesView>(
        'notices:get',
        { kind },
        { pushTopic: 'missionControls' },
    );
    const { run, busy } = useAdminAction();
    const [text, setText] = useState('');
    const [days, setDays] = useState<number | null>(3);
    const [departments, setDepartments] = useState<string[]>([]);
    const [reason, setReason] = useState('');
    const [ending, setEnding] = useState<number | null>(null);
    const [endAsk, setEndAsk] = useState<Notice | null>(null);
    if (!data) return null;
    const running = asArray(data.running);
    const history = asArray(data.history);
    const usedUp = data.perDay !== undefined && (data.usedToday ?? 0) >= data.perDay;
    const full = data.counted >= data.maxRunning;
    const ok =
        !busy &&
        data.canPost &&
        !usedUp &&
        !full &&
        text.trim().length > 0 &&
        text.length <= data.maxLength &&
        !!days &&
        (!data.reason || reason.trim().length > 0);
    const depts = session.config?.departments ?? [];
    const title =
        kind === 'staff' ? t('notices.title.staff') : t('sup.notices.title', { dept: data.short ?? data.department });

    const post = async () => {
        if (!ok) return;
        const res = await run(
            'server:notice:post',
            {
                kind,
                text: text.trim(),
                days,
                departments: kind === 'staff' && departments.length ? departments : undefined,
                reason: data.reason ? reason.trim() : undefined,
            },
            { requestId: false, success: kind === 'staff' ? 'notices.posted.staff' : 'sup.notices.posted' },
        );
        if (res.ok) {
            setText('');
            setReason('');
        }
        void refetch();
    };
    const endNow = async (id: number, why?: string) => {
        await run('server:notice:end', { id, reason: why }, { requestId: false, success: 'sup.notices.ended' });
        void refetch();
    };
    const end = (n: Notice) => {
        // a reason-asking kind confirms in a dialog, the other takes two clicks
        if (data.reason) {
            setEndAsk(n);
            return;
        }
        if (ending !== n.id) {
            setEnding(n.id);
            window.setTimeout(() => setEnding(cur => (cur === n.id ? null : cur)), 3000);
            return;
        }
        setEnding(null);
        void endNow(n.id);
    };
    const where = (n: Notice) => (n.departments?.length ? n.departments.join(', ') : t('notices.everyone'));

    return (
        <Card
            title={title}
            icon="bell"
            subtitle={t(kind === 'staff' ? 'notices.desc.staff' : 'mc.control_desc.notices')}
        >
            <div className="cp-notices">
                <ScreenStatus
                    state={screenStateOf(true, loading, error)}
                    error={error}
                    onRetry={() => void refetch()}
                />
                <h4 className="cp-section-title">{t('sup.notices.post_title')}</h4>
                {!data.canPost ? <p className="cp-notices__soft">{t('notices.off')}</p> : null}
                <Field label={t('sup.notices.text', { n: data.maxLength })} required>
                    <Textarea
                        value={text}
                        onChange={setText}
                        maxLength={data.maxLength}
                        rows={3}
                        disabled={busy || !data.canPost}
                    />
                </Field>
                <Field label={t('sup.notices.days', { max: data.maxDays })} required>
                    <NumberInput
                        value={days}
                        onChange={setDays}
                        min={1}
                        max={data.maxDays}
                        stepper
                        disabled={busy || !data.canPost}
                    />
                </Field>
                {kind === 'staff' ? (
                    <Field
                        label={t('ui.admin_officers.recognition.notice_depts')}
                        hint={t('ui.admin_officers.recognition.notice_depts_hint')}
                    >
                        <Row gap={2} wrap>
                            {depts.map(d => (
                                <Checkbox
                                    key={d.key}
                                    checked={departments.includes(d.key)}
                                    onChange={v =>
                                        setDepartments(
                                            v ? [...departments, d.key] : departments.filter(k => k !== d.key),
                                        )
                                    }
                                    label={d.short}
                                />
                            ))}
                        </Row>
                    </Field>
                ) : null}
                {data.reason ? (
                    <Field label={t('common.reason')} required>
                        <Textarea value={reason} onChange={setReason} maxLength={255} rows={2} disabled={busy} />
                    </Field>
                ) : null}
                <div className="cp-notices__actions">
                    <span className="cp-notices__soft">{t(`notices.alert_mode.${data.alert}`)}</span>
                    {data.perDay !== undefined ? (
                        <span className="cp-notices__wait">
                            {t('sup.notices.used', { used: data.usedToday ?? 0, n: data.perDay })}
                        </span>
                    ) : null}
                    {full ? (
                        <span className="cp-notices__wait">{t('sup.notices.full', { n: data.maxRunning })}</span>
                    ) : null}
                    <Button size="sm" variant="primary" icon="check" disabled={!ok} onClick={() => void post()}>
                        {t('sup.notices.post')}
                    </Button>
                </div>
                <h4 className="cp-section-title">{t('sup.notices.running', { n: running.length })}</h4>
                {running.length ? (
                    <ul className="cp-notices__list">
                        {running.map(n => (
                            <li key={n.id}>
                                <span>{n.text}</span>
                                {kind === 'staff' ? (
                                    <Badge size="sm" variant="outline">
                                        {t(`notices.kind.${n.kind}`)}
                                    </Badge>
                                ) : null}
                                <span className="cp-notices__soft">
                                    {t('sup.notices.until', { date: fmtDateTime(n.expiresAt) })}
                                    {kind === 'staff' ? ` · ${where(n)}` : ''}
                                </span>
                                <Button
                                    size="sm"
                                    variant={ending === n.id ? 'danger' : 'ghost'}
                                    icon="trash"
                                    disabled={busy}
                                    onClick={() => end(n)}
                                >
                                    {ending === n.id ? t('sup.notices.end_confirm') : t('sup.notices.end')}
                                </Button>
                            </li>
                        ))}
                    </ul>
                ) : (
                    <EmptyState compact icon="bell" title={t('sup.notices.none')} />
                )}
                <h4 className="cp-section-title">{t('notices.history', { n: history.length })}</h4>
                <MoreFold screen={`notices_${kind}`} count={history.length}>
                    {history.length ? (
                        <ul className="cp-notices__list">
                            {history.map(n => (
                                <li key={n.id}>
                                    <span>{n.text}</span>
                                    {kind === 'staff' ? (
                                        <Badge size="sm" variant="outline">
                                            {t(`notices.kind.${n.kind}`)}
                                        </Badge>
                                    ) : null}
                                    <span className="cp-notices__soft">
                                        {t(`notices.ended.${n.ended ?? 'expired'}`, {
                                            date: fmtDateTime(n.endedAt ?? n.expiresAt),
                                        })}
                                        {kind === 'staff' ? ` · ${where(n)}` : ''}
                                    </span>
                                </li>
                            ))}
                        </ul>
                    ) : (
                        <EmptyState compact icon="bell" title={t('notices.history_none')} />
                    )}
                </MoreFold>
            </div>
            <ConfirmDialog
                open={!!endAsk}
                tone="danger"
                title={t('sup.notices.end')}
                message={endAsk?.text}
                reason={{ required: true, maxLength: 255 }}
                onConfirm={async why => {
                    const n = endAsk;
                    setEndAsk(null);
                    if (n) await endNow(n.id, why);
                }}
                onCancel={() => setEndAsk(null)}
                busy={busy}
            />
        </Card>
    );
}
