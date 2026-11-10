// Admin UI · Review (screen key 'admin_review'): everything an admin checks and decides, as four tabs. Flagged runs

// Admin UI · Review (screen key 'admin_review'): everything an admin checks and decides, as four tabs. Flagged runs
// (callback admin:getFlagged, the admin's own runs left out; each row Approve / Void with a required reason ->
// server:admin:reviewFlagged { rowId, decision: 'approve'|'void', reason }, a run with more flagged rows Approve all ->
// server:admin:approveRun { runUuid, reason }), Profiles (every pending picture, bio and report, and the banned
// words), Disputes (every open dispute; a row opens the officer) and Corrections (bulk voids, retirements, record moves
// and season reopens, with Undo). A link to a tab is navigate('admin_review', { tab }). The Activity log (Audit) sits
// beside it in the Review group.

import { useEffect, useState } from 'react';
import {
    Badge,
    Button,
    Card,
    ConfirmDialog,
    EmptyState,
    LoadingBlock,
    Money,
    Row,
    Screen,
    Spacer,
    Tabs,
} from '../../shared/components';
import { formatDateTime, formatMoney, formatNumber } from '../../shared/format';
import { useAction, useRequest } from '../../shared/hooks';
import { hasKey, t } from '../../shared/i18n';
import { useNavigation, type ScreenParams } from '../../shared/navigation';
import type { FlaggedRow } from '../../types/oversight';
import { CorrectionsTab, DisputesTab, ReviewTab } from '../components/officers/OfficerLists';
import './Leaderboards.css';

export type AdminReviewTab = 'flagged' | 'profiles' | 'disputes' | 'corrections';
export const REVIEW_TABS: AdminReviewTab[] = ['flagged', 'profiles', 'disputes', 'corrections'];
const TAB_ICONS = { flagged: 'flag', profiles: 'eye', disputes: 'inbox', corrections: 'undo' } as const;

// The tab the screen shows for its params (Flagged runs unless another tab is asked for).
export function reviewTabOf(params: ScreenParams | null | undefined): AdminReviewTab {
    const asked = params?.tab;
    return typeof asked === 'string' && (REVIEW_TABS as string[]).includes(asked)
        ? (asked as AdminReviewTab)
        : 'flagged';
}

const flagLabel = (reason: string | null | undefined) =>
    reason && hasKey(`flag.${reason}`) ? t(`flag.${reason}`) : t('flag.flagged');

function FlaggedPanel({
    list,
    loading,
    onDecide,
    onApproveRun,
}: {
    list: FlaggedRow[];
    loading?: boolean;
    onDecide: (row: FlaggedRow, decision: 'approve' | 'void') => void;
    // admins: approve every flagged row of the run at once
    onApproveRun?: (row: FlaggedRow, rows: FlaggedRow[]) => void;
}) {
    return (
        <Card
            title={t('admin.boards.flagged_title')}
            subtitle={t('admin.boards.flagged_hint')}
            icon="flag"
            highlight={list.length ? 'warning' : undefined}
            actions={
                list.length ? (
                    <Badge tone="warning" size="sm">
                        {formatNumber(list.length)}
                    </Badge>
                ) : null
            }
            padding="sm"
            className="boards-stuck boards-flagged"
        >
            {!list.length && loading ? (
                <LoadingBlock />
            ) : list.length ? (
                <ul className="boards-stuck__list">
                    {list.map(r => (
                        <li key={r.rowId} className="boards-stuck__item">
                            <div className="boards-stuck__head">
                                <span className="boards-strong boards-ellipsis" title={r.name}>
                                    {r.name || r.citizenid}
                                </span>
                                {r.callsign ? <span className="boards-muted">{r.callsign}</span> : null}
                                <Spacer />
                                <Badge size="sm" tone="danger" variant="outline" icon="flag">
                                    {flagLabel(r.flagReason)}
                                </Badge>
                            </div>
                            <div className="boards-stuck__meta">
                                <span className="boards-ellipsis" title={r.missionLabel}>
                                    {r.missionLabel}
                                </span>
                                <span className="cp-num">{formatDateTime(r.createdAt)}</span>
                                <span className="cp-num">{t('admin.boards.row_id', { id: r.rowId })}</span>
                            </div>
                            {r.flagDetail ? (
                                <div className="boards-stuck__meta">
                                    <span className="boards-ellipsis" title={r.flagDetail}>
                                        {r.flagDetail}
                                    </span>
                                </div>
                            ) : null}
                            <Row gap={1} wrap>
                                <span className="cp-num boards-strong">{formatNumber(r.points)}</span>
                                <Money amount={r.cash} />
                                <Spacer />
                                <Button
                                    size="sm"
                                    variant="secondary"
                                    icon="check"
                                    onClick={() => onDecide(r, 'approve')}
                                >
                                    {t('sup.review.approve')}
                                </Button>
                                <Button size="sm" variant="danger" icon="xCircle" onClick={() => onDecide(r, 'void')}>
                                    {t('sup.review.void')}
                                </Button>
                            </Row>
                            {onApproveRun && list.filter(x => x.runUuid === r.runUuid).length > 1 ? (
                                <Button
                                    size="sm"
                                    variant="ghost"
                                    icon="check"
                                    onClick={() =>
                                        onApproveRun(
                                            r,
                                            list.filter(x => x.runUuid === r.runUuid),
                                        )
                                    }
                                >
                                    {t('ui.admin_officers.flagged.approve_run', {
                                        n: list.filter(x => x.runUuid === r.runUuid).length,
                                    })}
                                </Button>
                            ) : null}
                        </li>
                    ))}
                </ul>
            ) : (
                <EmptyState
                    compact
                    icon="shieldCheck"
                    title={t('sup.review.empty_flagged_title')}
                    text={t('admin.boards.flagged_none_text')}
                />
            )}
        </Card>
    );
}

function FlaggedRunsTab() {
    const { run, busy } = useAction();
    const { data, loading, refetch } = useRequest<{ flagged: FlaggedRow[] }>('admin:getFlagged', {}, { pollMs: 60000 });
    const list = Array.isArray(data?.flagged) ? data.flagged : [];
    const [review, setReview] = useState<{ row: FlaggedRow; decision: 'approve' | 'void' } | null>(null);
    const [approveRun, setApproveRun] = useState<{ row: FlaggedRow; rows: FlaggedRow[] } | null>(null);

    const submitReview = async (reason: string) => {
        if (!review) return;
        const res = await run(
            'server:admin:reviewFlagged',
            { rowId: review.row.rowId, decision: review.decision, reason },
            {
                success: review.decision === 'approve' ? 'sup.review.approved' : 'sup.review.voided',
            },
        );
        setReview(null);
        // a decided row leaves the list
        if (res.ok) void refetch();
    };

    const submitApproveRun = async (reason: string) => {
        if (!approveRun) return;
        const res = await run(
            'server:admin:approveRun',
            { runUuid: approveRun.row.runUuid, reason },
            { success: 'ui.admin_officers.done' },
        );
        setApproveRun(null);
        if (res.ok) void refetch();
    };

    return (
        <>
            <FlaggedPanel
                list={list}
                loading={loading}
                onDecide={(row, decision) => setReview({ row, decision })}
                onApproveRun={(row, rows) => setApproveRun({ row, rows })}
            />
            <ConfirmDialog
                open={!!approveRun}
                title={t('ui.admin_officers.flagged.approve_run_title')}
                message={
                    approveRun
                        ? t('ui.admin_officers.flagged.approve_run_message', {
                              n: approveRun.rows.length,
                              cash: formatMoney(approveRun.rows.reduce((sum, x) => sum + (Number(x.cash) || 0), 0)),
                          })
                        : null
                }
                reason={{ required: true, maxLength: 255 }}
                onConfirm={submitApproveRun}
                onCancel={() => setApproveRun(null)}
                busy={busy}
            />
            <ConfirmDialog
                open={!!review}
                tone={review?.decision === 'void' ? 'danger' : 'primary'}
                title={
                    review
                        ? t(review.decision === 'approve' ? 'sup.review.approve_title' : 'sup.review.void_title')
                        : ''
                }
                message={
                    review
                        ? t(review.decision === 'approve' ? 'sup.review.approve_message' : 'sup.review.void_message', {
                              name: review.row.name,
                              mission: review.row.missionLabel,
                          })
                        : ''
                }
                confirmLabel={
                    review ? t(review.decision === 'approve' ? 'sup.review.approve' : 'sup.review.void') : undefined
                }
                reason={{
                    required: true,
                    label: t('common.reason'),
                    maxLength: 255,
                    placeholder: t('sup.review.reason_placeholder'),
                }}
                onConfirm={submitReview}
                onCancel={() => setReview(null)}
                busy={busy}
            />
        </>
    );
}

export default function AdminReview() {
    const { params, navigate } = useNavigation();
    const [tab, setTab] = useState<AdminReviewTab>(reviewTabOf(params));
    // a link opened while the screen shows (Home's Needs attention, the search) picks its tab
    useEffect(() => setTab(reviewTabOf(params)), [params]);
    return (
        <Screen head="admin_review" className="oversight-screen">
            <Tabs<AdminReviewTab>
                items={REVIEW_TABS.map(k => ({ key: k, label: t(`admin.review.tab.${k}`), icon: TAB_ICONS[k] }))}
                value={tab}
                onChange={setTab}
                aria-label={t('ui.nav.plain.admin_review')}
            />
            {tab === 'flagged' ? <FlaggedRunsTab /> : null}
            {tab === 'profiles' ? <ReviewTab /> : null}
            {tab === 'disputes' ? <DisputesTab onOpen={cid => navigate('admin_officers', { citizenid: cid })} /> : null}
            {tab === 'corrections' ? <CorrectionsTab /> : null}
        </Screen>
    );
}
