// Supervisor UI · Review Queue (screen key 'sup_review').
// Tabs Flagged runs / Disputes: flagged runs involving the supervisor's department with the reason
// (e.g. outside help) and who, and disputes about flagged or voided runs. Their own runs never appear.
// Approve, void or reject, always with a reason; every decision is final and audited.
// Data: callback sup:getReviewQueue · actions server:sup:reviewFlagged { rowId, decision, reason } and
// server:sup:handleDispute { disputeId, decision, reason } (modules/admin, modules/disputes).
import { useState } from 'react';
import {
  Badge, Button, Card, ConfirmDialog, Dialog, EmptyState, ErrorState, Grid, IconButton, KeyValue, LoadingBlock, Money, Points, Row, Screen,
  Table, Tabs, TierBadge, type TableColumn,
} from '../../shared/components';
import { asArray } from '../../shared/data';
import { formatDateTime, formatDuration } from '../../shared/format';
import { useAction, useRequest } from '../../shared/hooks';
import { hasKey, t } from '../../shared/i18n';
import { useCan } from '../../shared/session';
import type { DisputeView, FlaggedRow, ReviewQueueData } from '../../types/oversight';
import './ReviewQueue.css';

type TabKey = 'flagged' | 'disputes';
type Pending =
  | { kind: 'flag'; decision: 'approve' | 'void'; row: FlaggedRow }
  | { kind: 'dispute'; decision: 'approve' | 'reject'; row: DisputeView };
type Detail = { kind: 'flag'; row: FlaggedRow } | { kind: 'dispute'; row: DisputeView };

const flagLabel = (reason: string | null | undefined) => (reason && hasKey(`flag.${reason}`) ? t(`flag.${reason}`) : t('flag.flagged'));
const endLabel = (reason: string) => (hasKey(`sup.end.${reason}`) ? t(`sup.end.${reason}`) : reason);
const stateTone = (s: string) => (s === 'completed' ? 'success' : s === 'failed' ? 'danger' : 'grey');
const resultText = (state: string, endReason: string) => (state === 'completed' ? t(`sup.state.${state}`) : `${t(`sup.state.${state}`)} · ${endLabel(endReason)}`);
const cashLabel = (status: string) => (hasKey(`result.cash_status.${status}`) ? t(`result.cash_status.${status}`) : status);

function Officer({ name, callsign, dept }: { name: string; callsign: string | null; dept: string }) {
  return (
    <div className="oversight-rq-who">
      <span className="oversight-rq-who__name" title={name}>{name}</span>
      <span className="oversight-rq-who__sub">
        <Badge size="sm" variant="outline">{dept}</Badge>
        <span>{callsign || t('common.no_callsign')}</span>
      </span>
    </div>
  );
}

function Mission({ label, type, state, endReason, when }: { label: string; type: string; state: string; endReason: string; when?: number }) {
  return (
    <div className="oversight-rq-mission">
      <span className="oversight-rq-mission__name" title={label}>{label}</span>
      <span className="oversight-rq-mission__sub">
        <span>{type}</span>
        <Badge size="sm" tone={stateTone(state)}>{t(`sup.state.${state}`)}</Badge>
        {state !== 'completed' ? <span title={endReason}>{endLabel(endReason)}</span> : null}
      </span>
      {when ? <span className="oversight-rq-mission__when cp-num">{formatDateTime(when)}</span> : null}
    </div>
  );
}

function FlagCell({ row }: { row: FlaggedRow }) {
  return (
    <div className="oversight-rq-flag">
      <Badge size="sm" tone="danger" variant="outline" icon="flag">{flagLabel(row.flagReason)}</Badge>
      {row.flagDetail ? <span className="oversight-rq-flag__detail" title={row.flagDetail}>{row.flagDetail}</span> : null}
      {asArray(row.otherReasons).length ? (
        <span className="oversight-rq-flag__also">{t('sup.review.also', { reasons: asArray(row.otherReasons).map(flagLabel).join(', ') })}</span>
      ) : null}
    </div>
  );
}

function FlagDetail({ row }: { row: FlaggedRow }) {
  return (
    <div className="oversight-rq-detail">
      <Row gap={2} wrap>
        <Badge tone="danger" variant="outline" icon="flag">{flagLabel(row.flagReason)}</Badge>
        {asArray(row.otherReasons).map((r) => <Badge key={r} tone="warning" variant="outline">{flagLabel(r)}</Badge>)}
        <TierBadge tier={row.tier} size="sm" />
      </Row>
      <div className="oversight-rq-detail__box">
        <span className="oversight-rq-detail__label">{t('sup.review.detail.detail')}</span>
        <span>{row.flagDetail || t('sup.review.no_detail')}</span>
      </div>
      <Grid cols={3} gap={3}>
        <KeyValue label={t('sup.review.detail.officer')}>{row.name}</KeyValue>
        <KeyValue label={t('sup.review.detail.mission')}>{row.missionLabel}</KeyValue>
        <KeyValue label={t('sup.review.detail.location')}>{row.location || '—'}</KeyValue>
        <KeyValue label={t('sup.review.detail.result')}>{resultText(row.state, row.endReason)}</KeyValue>
        <KeyValue label={t('sup.review.detail.participants')}><span className="cp-num">{t('sup.review.participants_value', { n: row.participants, d: row.departments })}</span></KeyValue>
        <KeyValue label={t('sup.review.detail.duration')}><span className="cp-num">{formatDuration(row.durationS)}</span></KeyValue>
        <KeyValue label={t('sup.review.detail.points')}><Points value={row.points} /></KeyValue>
        <KeyValue label={t('sup.review.detail.cash')}><Money amount={row.cash} /> <span className="oversight-rq-soft">{cashLabel(row.cashStatus)}</span></KeyValue>
        <KeyValue label={t('sup.review.detail.when')}><span className="cp-num">{formatDateTime(row.createdAt)}</span></KeyValue>
      </Grid>
      <div className="oversight-rq-uuid">{t('sup.review.detail.run', { id: row.runUuid, row: row.rowId })}</div>
    </div>
  );
}

function DisputeDetail({ row }: { row: DisputeView }) {
  return (
    <div className="oversight-rq-detail">
      <Row gap={2} wrap>
        <Badge tone={row.kind === 'voided' ? 'danger' : 'warning'}>{t(`admin.dispute.kind.${row.kind}`)}</Badge>
        {row.flagReason ? <Badge tone="danger" variant="outline" icon="flag">{flagLabel(row.flagReason)}</Badge> : null}
        <TierBadge tier={row.tier} size="sm" />
      </Row>
      <div className="oversight-rq-detail__box">
        <span className="oversight-rq-detail__label">{t('sup.review.detail.officer_reason')}</span>
        <span className="oversight-rq-quote">{row.reason}</span>
      </div>
      <Grid cols={3} gap={3}>
        <KeyValue label={t('sup.review.detail.officer')}>{row.name}</KeyValue>
        <KeyValue label={t('sup.review.detail.mission')}>{row.missionLabel}</KeyValue>
        <KeyValue label={t('sup.review.detail.result')}>{resultText(row.state, row.endReason)}</KeyValue>
        <KeyValue label={t('sup.review.detail.points')}><Points value={row.points} /></KeyValue>
        <KeyValue label={t('sup.review.detail.cash')}><Money amount={row.cash} /> <span className="oversight-rq-soft">{cashLabel(row.cashStatus)}</span></KeyValue>
        <KeyValue label={t('sup.review.detail.filed')}><span className="cp-num">{formatDateTime(row.createdAt)}</span></KeyValue>
      </Grid>
      <div className="oversight-rq-uuid">{t('sup.review.detail.run', { id: row.runUuid, row: row.rowId })}</div>
    </div>
  );
}

export default function SupReviewQueue() {
  const can = useCan();
  const { data, loading, error, refetch } = useRequest<ReviewQueueData>('sup:getReviewQueue', {}, { pollMs: 30000 });
  const { run, busy } = useAction();
  const canReview = can('reviewFlagged') && data?.canReview !== false;
  const canHandle = can('handleDisputes') && data?.canHandle !== false;
  const [tab, setTab] = useState<TabKey>(canReview ? 'flagged' : 'disputes');
  const [pending, setPending] = useState<Pending | null>(null);
  const [detail, setDetail] = useState<Detail | null>(null);

  const flagged = asArray(data?.flagged);
  const disputes = asArray(data?.disputes);

  const decide = async (reason: string) => {
    if (!pending) return;
    let res;
    if (pending.kind === 'flag') {
      res = await run('server:sup:reviewFlagged', { rowId: pending.row.rowId, decision: pending.decision, reason },
        { success: pending.decision === 'approve' ? 'sup.review.approved' : 'sup.review.voided' });
    } else {
      res = await run('server:sup:handleDispute', { disputeId: pending.row.id, decision: pending.decision, reason },
        { success: pending.decision === 'approve' ? 'sup.review.dispute_approved' : 'sup.review.dispute_rejected' });
    }
    setPending(null);
    setDetail(null);
    if (res.ok) void refetch();
  };

  const flagActions = (r: FlaggedRow) => (
    <Row gap={1} justify="flex-end">
      <IconButton icon="eye" size="sm" label={t('sup.review.details')} onClick={() => setDetail({ kind: 'flag', row: r })} />
      <Button size="sm" variant="secondary" icon="check" onClick={() => setPending({ kind: 'flag', decision: 'approve', row: r })}>{t('sup.review.approve')}</Button>
      <Button size="sm" variant="danger" icon="xCircle" onClick={() => setPending({ kind: 'flag', decision: 'void', row: r })}>{t('sup.review.void')}</Button>
    </Row>
  );

  const disputeActions = (r: DisputeView) => (
    <Row gap={1} justify="flex-end">
      <IconButton icon="eye" size="sm" label={t('sup.review.details')} onClick={() => setDetail({ kind: 'dispute', row: r })} />
      <Button size="sm" variant="secondary" icon="check" disabled={!r.canHandle} onClick={() => setPending({ kind: 'dispute', decision: 'approve', row: r })}>{t('sup.review.approve')}</Button>
      <Button size="sm" variant="danger" icon="x" disabled={!r.canHandle} onClick={() => setPending({ kind: 'dispute', decision: 'reject', row: r })}>{t('sup.review.reject')}</Button>
    </Row>
  );

  const flagColumns: TableColumn<FlaggedRow>[] = [
    { key: 'officer', header: t('sup.review.col.officer'), width: 150, render: (r) => <Officer name={r.name} callsign={r.callsign} dept={r.departmentShort} /> },
    { key: 'mission', header: t('sup.review.col.mission'), render: (r) => <Mission label={r.missionLabel} type={r.missionTypeLabel} state={r.state} endReason={r.endReason} when={r.createdAt} /> },
    { key: 'flag', header: t('sup.review.col.flag'), width: 176, render: (r) => <FlagCell row={r} /> },
    {
      key: 'held', header: t('sup.review.col.held'), width: 96, numeric: true,
      render: (r) => (
        <div className="oversight-rq-held">
          <Points value={r.points} />
          <Money amount={r.cash} />
        </div>
      ),
    },
    { key: 'actions', header: '', width: 228, align: 'right', render: flagActions },
  ];

  const disputeColumns: TableColumn<DisputeView>[] = [
    { key: 'officer', header: t('sup.review.col.officer'), width: 156, render: (r) => <Officer name={r.name} callsign={r.callsign} dept={r.departmentShort} /> },
    {
      key: 'mission', header: t('sup.review.col.mission'), width: 170,
      render: (r) => (
        <div className="oversight-rq-mission">
          <span className="oversight-rq-mission__name">{r.missionLabel}</span>
          <span className="oversight-rq-mission__sub">
            <Badge size="sm" tone={r.kind === 'voided' ? 'danger' : 'warning'}>{t(`admin.dispute.kind.${r.kind}`)}</Badge>
            {r.flagReason ? <span>{flagLabel(r.flagReason)}</span> : null}
          </span>
        </div>
      ),
    },
    { key: 'reason', header: t('sup.review.col.officer_reason'), render: (r) => <span className="oversight-rq-quote oversight-rq-clamp" title={r.reason}>{r.reason}</span> },
    { key: 'when', header: t('sup.review.col.filed'), width: 116, render: (r) => <span className="cp-num oversight-rq-soft oversight-rq-date">{formatDateTime(r.createdAt)}</span> },
    { key: 'actions', header: '', width: 250, align: 'right', render: disputeActions },
  ];

  const tabs = [
    ...(canReview ? [{ key: 'flagged' as const, label: t('sup.review.tab.flagged'), icon: 'flag' as const, badge: flagged.length || undefined }] : []),
    ...(canHandle ? [{ key: 'disputes' as const, label: t('sup.review.tab.disputes'), icon: 'inbox' as const, badge: disputes.length || undefined }] : []),
  ];
  const current: TabKey = tabs.some((x) => x.key === tab) ? tab : (tabs[0]?.key ?? 'flagged');

  let body;
  if (loading && !data) body = <LoadingBlock />;
  else if (error && !data) body = <Card><ErrorState error={error} onRetry={() => void refetch()} /></Card>;
  else if (current === 'flagged')
    body = (
      <Table
        columns={flagColumns}
        rows={flagged}
        rowKey={(r) => r.rowId}
        loading={loading}
        className="oversight-rq-table"
        empty={<EmptyState icon="shieldCheck" title={t('sup.review.empty_flagged_title')} text={t('sup.review.empty_flagged_text')} />}
        aria-label={t('sup.review.tab.flagged')}
      />
    );
  else
    body = (
      <Table
        columns={disputeColumns}
        rows={disputes}
        rowKey={(r) => r.id}
        loading={loading}
        className="oversight-rq-table"
        empty={<EmptyState icon="inbox" title={t('sup.review.empty_disputes_title')} text={t('sup.review.empty_disputes_text')} />}
        aria-label={t('sup.review.tab.disputes')}
      />
    );

  const pendingName = pending ? pending.row.name : '';
  const confirmTitle = !pending ? '' : pending.kind === 'flag'
    ? t(pending.decision === 'approve' ? 'sup.review.approve_title' : 'sup.review.void_title')
    : t(pending.decision === 'approve' ? 'sup.review.dispute_approve_title' : 'sup.review.dispute_reject_title');
  const confirmMessage = !pending ? null : pending.kind === 'flag'
    ? t(pending.decision === 'approve' ? 'sup.review.approve_message' : 'sup.review.void_message', { name: pendingName, mission: pending.row.missionLabel })
    : t(pending.decision === 'approve' ? 'sup.review.dispute_approve_message' : 'sup.review.dispute_reject_message', { name: pendingName, mission: pending.row.missionLabel });
  const destructive = !!pending && pending.decision !== 'approve';

  return (
    <Screen
      title={t('ui.screen.sup_review')}
      subtitle={t('sup.review.subtitle')}
      actions={<IconButton icon="refresh" label={t('sup.refresh')} variant="secondary" loading={loading && !!data} onClick={() => void refetch()} />}
      className="oversight-screen"
    >
      {tabs.length > 1 ? <Tabs items={tabs} value={current} onChange={(k) => setTab(k as TabKey)} aria-label={t('ui.screen.sup_review')} /> : null}
      {body}
      <div className="oversight-rq-note">{t('sup.review.own_rule')}</div>

      <Dialog
        open={!!detail}
        onClose={() => setDetail(null)}
        size="lg"
        title={detail ? (detail.kind === 'flag' ? t('sup.review.detail_title') : t('sup.review.dispute_detail_title')) : ''}
        description={detail ? `${detail.row.name} · ${detail.row.missionLabel}` : undefined}
        footer={
          detail ? (
            <>
              <Button variant="ghost" onClick={() => setDetail(null)}>{t('common.close')}</Button>
              {detail.kind === 'flag' ? (
                <>
                  <Button variant="danger" icon="xCircle" onClick={() => setPending({ kind: 'flag', decision: 'void', row: detail.row })}>{t('sup.review.void')}</Button>
                  <Button variant="primary" icon="check" onClick={() => setPending({ kind: 'flag', decision: 'approve', row: detail.row })}>{t('sup.review.approve')}</Button>
                </>
              ) : detail.row.canHandle ? (
                <>
                  <Button variant="danger" icon="x" onClick={() => setPending({ kind: 'dispute', decision: 'reject', row: detail.row })}>{t('sup.review.reject')}</Button>
                  <Button variant="primary" icon="check" onClick={() => setPending({ kind: 'dispute', decision: 'approve', row: detail.row })}>{t('sup.review.approve')}</Button>
                </>
              ) : null}
            </>
          ) : null
        }
      >
        {detail ? (detail.kind === 'flag' ? <FlagDetail row={detail.row} /> : <DisputeDetail row={detail.row} />) : null}
      </Dialog>

      <ConfirmDialog
        open={!!pending}
        tone={destructive ? 'danger' : 'primary'}
        title={confirmTitle}
        message={confirmMessage}
        confirmLabel={!pending ? '' : pending.decision === 'approve' ? t('sup.review.approve') : pending.decision === 'void' ? t('sup.review.void') : t('sup.review.reject')}
        reason={{ required: true, label: t('common.reason'), placeholder: t('sup.review.reason_placeholder'), maxLength: 255 }}
        onConfirm={decide}
        onCancel={() => setPending(null)}
        busy={busy}
      />
    </Screen>
  );
}
