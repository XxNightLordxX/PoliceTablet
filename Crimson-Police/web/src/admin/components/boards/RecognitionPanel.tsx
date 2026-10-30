// Leaderboards → Recognition: what officers' Home shows, the last closed weeks (Recount, Post again) and the staff
// notices (Post, Remove).

import { useState } from 'react';
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
    LoadingBlock,
    NumberInput,
    Row,
    Textarea,
} from '../../../shared/components';
import { fmtDateTime, formatNumber } from '../../../shared/format';
import { useRequest } from '../../../shared/hooks';
import { request } from '../../../shared/nui';
import { t } from '../../../shared/i18n';
import { useSession } from '../../../shared/session';
import type { RecognitionData, StaffNotice, WeekRecognition } from '../../../types/admin_officers';
import { useAdminAction } from '../kit';
import '../officers/OfficerTools.css';

const NOTICE_MAX = 280;

export function RecognitionPanel() {
    const session = useSession();
    const { data, loading, error, refetch } = useRequest<RecognitionData>('admin:getRecognition', {});
    const { run, busy } = useAdminAction();
    const [recount, setRecount] = useState<{ week: WeekRecognition; post: boolean } | null>(null);
    const [repost, setRepost] = useState<WeekRecognition | null>(null);
    const [notice, setNotice] = useState<{
        text: string;
        days: number | null;
        departments: string[];
        reason: string;
    } | null>(null);
    const [remove, setRemove] = useState<StaffNotice | null>(null);

    const openRecount = async (week: WeekRecognition) => {
        const res = await request<WeekRecognition>('admin:previewRecount', { weekKey: week.weekKey });
        if (res.ok && res.data) setRecount({ week: res.data, post: true });
    };
    const doRecount = async (reason: string, typed: string) => {
        if (!recount) return;
        const res = await run(
            'server:admin:recountWeek',
            {
                weekKey: recount.week.weekKey,
                post: recount.post,
                reason,
                confirm: typed,
                previewToken: recount.week.previewToken,
            },
            { requestId: false, success: 'ui.admin_officers.done' },
        );
        setRecount(null);
        if (res.ok) void refetch();
    };
    const doRepost = async () => {
        if (!repost) return;
        await run(
            'server:admin:repostWeek',
            { weekKey: repost.weekKey },
            { requestId: false, success: 'ui.admin_officers.done' },
        );
        setRepost(null);
    };
    const noticeOk =
        !!notice && !!notice.text.trim() && notice.text.length <= NOTICE_MAX && !!notice.days && !!notice.reason.trim();
    const doNotice = async () => {
        if (!notice || !noticeOk) return;
        const res = await run(
            'server:admin:postNotice',
            {
                text: notice.text.trim(),
                departments: notice.departments.length ? notice.departments : undefined,
                expiresAt: Math.floor(Date.now() / 1000) + (notice.days ?? 1) * 86400,
                reason: notice.reason.trim(),
            },
            { requestId: false, success: 'ui.admin_officers.done' },
        );
        if (res.ok) {
            setNotice(null);
            void refetch();
        }
    };
    const doRemove = async (reason: string) => {
        if (!remove) return;
        const res = await run('server:admin:removeNotice', { id: remove.id, reason }, { requestId: false });
        setRemove(null);
        if (res.ok) void refetch();
    };

    if (!data && loading) return <LoadingBlock />;
    if (!data && error) return <ErrorState error={error} onRetry={() => void refetch()} />;
    if (!data) return null;
    const depts = session.config?.departments ?? [];

    return (
        <div className="admin-otools">
            <Card
                title={t('ui.admin_officers.recognition.home')}
                icon="home"
                subtitle={t('ui.admin_officers.recognition.home_hint')}
                padding="md"
            >
                <Row gap={2} wrap>
                    <Badge tone={data.announceWeekly ? 'success' : 'grey'}>
                        {t(
                            data.announceWeekly
                                ? 'ui.admin_officers.recognition.weekly_on'
                                : 'ui.admin_officers.recognition.weekly_off',
                        )}
                    </Badge>
                    <Badge tone={data.announceMonthly ? 'success' : 'grey'}>
                        {t(
                            data.announceMonthly
                                ? 'ui.admin_officers.recognition.monthly_on'
                                : 'ui.admin_officers.recognition.monthly_off',
                        )}
                    </Badge>
                </Row>
                {data.home.length ? (
                    <ul className="admin-otools__badges">
                        {data.home.map((a, i) => (
                            <li key={i}>
                                <span>{a.text}</span>
                                <Badge size="sm" variant="outline">
                                    {t(
                                        `ui.admin_officers.recognition.kind.${a.kind === 'staff_notice' ? 'notice' : a.kind === 'monthly_top3' ? 'monthly' : 'weekly'}`,
                                    )}
                                </Badge>
                            </li>
                        ))}
                    </ul>
                ) : (
                    <EmptyState compact icon="home" title={t('ui.admin_officers.recognition.home_empty')} />
                )}
            </Card>

            <Card
                title={t('ui.admin_officers.recognition.notices')}
                icon="bell"
                padding="md"
                actions={
                    <Button
                        size="sm"
                        variant="primary"
                        icon="plus"
                        onClick={() => setNotice({ text: '', days: 3, departments: [], reason: '' })}
                    >
                        {t('ui.admin_officers.recognition.post_notice')}
                    </Button>
                }
            >
                {data.notices.length ? (
                    <ul className="admin-otools__badges">
                        {data.notices.map(n => (
                            <li key={n.id}>
                                <span>{n.text}</span>
                                <span className="admin-otools__soft">
                                    {t('ui.admin_officers.recognition.until', { date: fmtDateTime(n.expiresAt) })}
                                    {n.departments ? ` · ${n.departments.join(', ')}` : ''}
                                </span>
                                <Button size="sm" variant="ghost" icon="trash" onClick={() => setRemove(n)}>
                                    {t('ui.admin_officers.recognition.remove')}
                                </Button>
                            </li>
                        ))}
                    </ul>
                ) : (
                    <EmptyState compact icon="bell" title={t('ui.admin_officers.recognition.no_notices')} />
                )}
            </Card>

            <Card
                title={t('ui.admin_officers.recognition.weeks')}
                icon="trophy"
                subtitle={t('ui.admin_officers.recognition.weeks_hint')}
                padding="md"
            >
                <ul className="admin-otools__badges">
                    {data.weeks.map(w => (
                        <li key={w.weekKey}>
                            <span>
                                {t('ui.admin_officers.recognition.week_of', { week: w.weekKey })}:{' '}
                                {w.top[0] ? `${w.top[0].name} (${formatNumber(w.top[0].points)})` : t('common.none')}
                            </span>
                            <span className="admin-otools__soft">
                                {t('ui.admin_officers.recognition.holder', {
                                    who: w.holders.map(h => h.name).join(', ') || t('common.none'),
                                })}
                            </span>
                            {w.changed ? (
                                <Badge size="sm" tone="warning">
                                    {t('ui.admin_officers.recognition.changed')}
                                </Badge>
                            ) : null}
                            <Button size="sm" variant="secondary" disabled={busy} onClick={() => void openRecount(w)}>
                                {t('ui.admin_officers.recognition.recount')}
                            </Button>
                            <Button
                                size="sm"
                                variant="ghost"
                                disabled={busy || !w.top.length}
                                onClick={() => setRepost(w)}
                            >
                                {t('ui.admin_officers.recognition.repost')}
                            </Button>
                        </li>
                    ))}
                </ul>
            </Card>

            <ConfirmDialog
                open={!!recount}
                tone="danger"
                title={t('ui.admin_officers.recognition.recount')}
                message={
                    recount
                        ? t('ui.admin_officers.recognition.recount_message', {
                              old: recount.week.holders.map(h => h.name).join(', ') || t('common.none'),
                              new: recount.week.top[0]?.name ?? t('common.none'),
                          })
                        : null
                }
                effect={
                    recount ? (
                        <Checkbox
                            checked={recount.post}
                            onChange={v => setRecount({ ...recount, post: v })}
                            label={t('ui.admin_officers.recognition.post_correction')}
                        />
                    ) : null
                }
                typedWord="RECOUNT"
                reason={{ required: true, maxLength: 255 }}
                onConfirm={doRecount}
                onCancel={() => setRecount(null)}
                busy={busy}
            />
            <ConfirmDialog
                open={!!repost}
                title={t('ui.admin_officers.recognition.repost')}
                message={repost ? t('ui.admin_officers.recognition.repost_message', { week: repost.weekKey }) : null}
                onConfirm={doRepost}
                onCancel={() => setRepost(null)}
                busy={busy}
            />
            <ConfirmDialog
                open={!!remove}
                tone="danger"
                title={t('ui.admin_officers.recognition.remove')}
                message={remove?.text}
                reason={{ required: true, maxLength: 255 }}
                onConfirm={doRemove}
                onCancel={() => setRemove(null)}
                busy={busy}
            />
            <Dialog
                open={!!notice}
                onClose={() => setNotice(null)}
                size="sm"
                title={t('ui.admin_officers.recognition.post_notice')}
                description={t('ui.admin_officers.recognition.notice_desc')}
                footer={
                    <>
                        <Button variant="ghost" onClick={() => setNotice(null)} disabled={busy}>
                            {t('common.cancel')}
                        </Button>
                        <Button variant="primary" loading={busy} disabled={!noticeOk} onClick={() => void doNotice()}>
                            {t('ui.admin_officers.recognition.post_notice')}
                        </Button>
                    </>
                }
            >
                {notice ? (
                    <div className="admin-otools__form">
                        <Field label={t('ui.admin_officers.recognition.notice_text')} required>
                            <Textarea
                                value={notice.text}
                                onChange={v => setNotice({ ...notice, text: v })}
                                maxLength={NOTICE_MAX}
                                rows={3}
                            />
                        </Field>
                        <Field label={t('ui.admin_officers.recognition.notice_days')} required>
                            <NumberInput
                                value={notice.days}
                                onChange={v => setNotice({ ...notice, days: v })}
                                min={1}
                                max={30}
                                stepper
                            />
                        </Field>
                        <Field
                            label={t('ui.admin_officers.recognition.notice_depts')}
                            hint={t('ui.admin_officers.recognition.notice_depts_hint')}
                        >
                            <Row gap={2} wrap>
                                {depts.map(d => (
                                    <Checkbox
                                        key={d.key}
                                        checked={notice.departments.includes(d.key)}
                                        onChange={v =>
                                            setNotice({
                                                ...notice,
                                                departments: v
                                                    ? [...notice.departments, d.key]
                                                    : notice.departments.filter(k => k !== d.key),
                                            })
                                        }
                                        label={d.short}
                                    />
                                ))}
                            </Row>
                        </Field>
                        {notice.text.trim() ? (
                            <div>
                                <span className="admin-otools__soft">{t('ui.admin_officers.recognition.preview')}</span>
                                <p>{notice.text.trim()}</p>
                            </div>
                        ) : null}
                        <Field label={t('common.reason')} required>
                            <Textarea
                                value={notice.reason}
                                onChange={v => setNotice({ ...notice, reason: v })}
                                maxLength={255}
                                rows={2}
                            />
                        </Field>
                    </div>
                ) : null}
            </Dialog>
        </div>
    );
}
