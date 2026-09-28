// Officer UI · Profile & History (screen key 'profile', callback getProfile, actions server:setHideName and
// server:dispute). Own profile by default; navigate('profile', { citizenid }) opens someone's public
// profile (no cash, no cash breakdown, no toggle, no disputes). Shows the XP level badge and bar, badges,
// the hide-name toggle, and the last 20 runs with how each ended; a row opens the points/cash breakdown in
// the same presentation as the HUD result card; flagged, voided or failed runs from the dispute window can
// be disputed (reason required).
import { useState } from 'react';
import {
  Badge, Button, Card, ConfirmDialog, Dialog, EmptyState, ErrorState, Grid, Icon, LoadingBlock, Money, ProgressBar, Row, Screen,
  Stat, Table, TierBadge, Toggle, XpBadge, type IconName, type TableColumn,
} from '../../shared/components';
import { cx } from '../../shared/cx';
import { normalizeResult } from '../../shared/data';
import { formatDateTime, formatDuration, formatMoney, formatMultiplier, formatNumber, formatPercent } from '../../shared/format';
import { useAction, useRequest } from '../../shared/hooks';
import { t, tOr } from '../../shared/i18n';
import { useNavigate, useNavigation } from '../../shared/navigation';
import { useSession } from '../../shared/session';
import type { RunResult, Session } from '../../shared/types';
import { asList, type ProfileData, type ProfileRunView } from '../../types/boards';
import './Profile.css';

const STATE_TONE = { completed: 'success', failed: 'danger', abandoned: 'neutral' } as const;
const BADGE_ICON: Record<string, IconName> = { week: 'star', champion: 'trophy', top10: 'podium', achievement: 'shieldCheck' };

export function missionTypeLabel(type: string, session: Session): string {
  if (type === 'manual_award' || type === 'goal') return t(`profile.type.${type}`);
  const mt = asList(session.config?.missionTypes).find((m) => m.key === type);
  return mt ? mt.label : type;
}

export function StateBadge({ state }: { state: string }) {
  const tone = STATE_TONE[state as keyof typeof STATE_TONE] ?? 'neutral';
  return <Badge tone={tone} size="sm">{tOr(`profile.state.${state}`, 'common.unknown')}</Badge>;
}

/** "How it ended": state badge (+ voided/flagged badges) over the end reason. Shared by every run table. */
export function ResultCell({ state, endReason, flagged, voided, flagReason }: { state: string; endReason: string; flagged?: boolean; voided?: boolean; flagReason?: string | null }) {
  return (
    <span className="boards-resultcell">
      <span className="boards-resultcell__top">
        <StateBadge state={state} />
        {voided ? <Badge tone="danger" size="sm" icon="xCircle">{t('profile.voided')}</Badge> : null}
        {flagged ? (
          <Badge tone="warning" size="sm" icon="alert" title={flagReason ? tOr(`profile.flag_reason.${flagReason}`, 'result.flag_generic') : undefined}>
            {t('profile.flagged')}
          </Badge>
        ) : null}
      </span>
      <span className="boards-resultcell__reason">{tOr(`reason.${endReason}`, 'common.unknown')}</span>
    </span>
  );
}

function Line({ label, value, tone, strong, note }: { label: string; value: string; tone?: 'plus' | 'minus' | 'mult'; strong?: boolean; note?: boolean }) {
  return (
    <div className={cx('cp-result__line', tone && `is-${tone}`, strong && 'is-strong', note && 'is-note')}>
      <span className="cp-result__line-label">{label}</span>
      <span className="cp-result__line-value cp-num">{value}</span>
    </div>
  );
}

/** The points and cash breakdown of one run, in the HUD result card's presentation (cp-result classes). */
export function RunBreakdown({ result: raw, cashStatus }: { result: RunResult; cashStatus?: string }) {
  // Row JSON from Lua: lists may be {} and fields may be missing; public profiles have no cash block at all.
  const hasCash = !!(raw as Partial<RunResult>).cash && typeof raw.cash === 'object';
  const result = normalizeResult(raw);
  const p = raw.points && typeof raw.points === 'object' ? result.points : null;
  const c = hasCash ? result.cash : null;
  const status = cashStatus || c?.status || '';
  const kind = result.result === 'completed' || result.result === 'failed' ? result.result : 'abandoned';
  return (
    <div className={cx('cp-result', `is-${kind}`, 'boards-breakdown')}>
      <div className="cp-result__mission">
        <span className="cp-result__mission-label">{result.missionLabel}</span>
        <span className="cp-result__facts">
          <span>{result.participants > 1 ? t('result.participants', { n: result.participants }) : t('result.solo')}</span>
          {result.departments > 1 ? <span>{t('result.departments', { n: result.departments })}</span> : null}
          <span className="cp-num">{formatDuration(result.durationS)}</span>
        </span>
      </div>
      {result.flagged ? (
        <div className="cp-result__notice is-flagged">
          <Icon name="alert" size={15} />
          <span>
            <strong>{t('result.flagged', { reason: tOr(`profile.flag_reason.${result.flagged.reason}`, 'result.flag_generic') })}</strong> {t('result.flagged_note')}
          </span>
        </div>
      ) : null}
      <div className="cp-result__tiers">
        <span className="cp-result__tier-label">{t('result.tier')}</span>
        <TierBadge tier={result.payTier || result.tier} size="sm" />
      </div>
      {p ? (
        <div className="cp-result__block">
          <div className="cp-result__block-head">
            <Icon name="star" size={14} />
            <span>{t('result.points')}</span>
          </div>
          <Line label={t('result.base')} value={formatNumber(p.P)} />
          {asList(p.bonuses).map((b, i) => (
            <Line key={`b${i}`} label={b.label || tOr(`bonus.${b.id}`, 'profile.bonus')} value={formatNumber(b.points, true)} tone="plus" />
          ))}
          {asList(p.penalties).map((b, i) => (
            <Line key={`p${i}`} label={b.label || tOr(`penalty.${b.id}`, 'profile.penalty')} value={formatNumber(-Math.abs(b.points))} tone="minus" />
          ))}
          {p.failedShare !== null && p.failedShare !== undefined ? (
            <Line label={t('result.failed_share', { share: formatPercent(p.failedShare) })} value="" note />
          ) : null}
          <Line label={t('result.subtotal')} value={formatNumber(p.subtotal)} strong />
          <Line label={t('result.m_team')} value={formatMultiplier(p.mTeam)} tone="mult" />
          <Line label={t('result.m_cross')} value={formatMultiplier(p.mCross)} tone="mult" />
          <Line label={t('result.m_streak')} value={formatMultiplier(p.mStreak)} tone="mult" />
          {p.capped ? <Line label={t('result.capped')} value={formatNumber(p.P * 2)} note /> : null}
          {p.tod ? <Line label={t('result.tod')} value={formatMultiplier(2, 0)} tone="mult" /> : null}
          <div className="cp-result__final">
            <span>{t('result.final')}</span>
            <span className="cp-num">
              {formatNumber(p.final)} <small>{t('common.pts')}</small>
            </span>
          </div>
        </div>
      ) : null}
      {c ? (
        <div className="cp-result__block">
          <div className="cp-result__block-head">
            <Icon name="dollar" size={14} />
            <span>{t('result.cash')}</span>
            {status ? <span className={cx('cp-result__status', `is-${status}`)}>{tOr(`result.cash_status.${status}`, 'common.unknown')}</span> : null}
          </div>
          <div className="cp-result__cash">
            <span className="cp-result__formula cp-num">
              {result.result === 'completed' ? `${formatMoney(c.B)} ${formatMultiplier(c.mTier)} ${formatMultiplier(c.mMod)} =` : t('result.no_cash')}
            </span>
            <span className="cp-result__amount cp-num">{formatMoney(c.amount)}</span>
          </div>
        </div>
      ) : null}
    </div>
  );
}

export default function Profile() {
  const session = useSession();
  const navigate = useNavigate();
  const { params } = useNavigation();
  const target = typeof params.citizenid === 'string' && params.citizenid !== session.officer?.citizenid ? params.citizenid : undefined;
  const { data, loading, error, refetch, setData } = useRequest<ProfileData>('getProfile', target ? { citizenid: target } : {});
  const { run, busy } = useAction();
  const [openRun, setOpenRun] = useState<ProfileRunView | null>(null);
  const [disputeRun, setDisputeRun] = useState<ProfileRunView | null>(null);

  // Do not show the previous profile while another one loads.
  const profile = data && (target ? data.citizenid === target : data.own) ? data : null;
  const own = !!profile?.own;
  const runs = asList(profile?.runs) as ProfileRunView[];
  const badges = asList(profile?.badges);
  const hours = profile?.disputeWindowHours ?? session.config?.disputeWindowHours ?? 48;

  const toggleHide = async (value: boolean) => {
    const res = await run<{ hideName: boolean }>('server:setHideName', value, { success: value ? 'profile.hide_on' : 'profile.hide_off' });
    if (res.ok) setData((prev) => (prev ? { ...prev, hideName: res.data?.hideName ?? value } : prev));
  };

  const sendDispute = async (reason: string) => {
    if (!disputeRun) return;
    const res = await run('server:dispute', { rowId: disputeRun.id, reason }, { success: 'profile.dispute_sent' });
    if (res.ok) {
      setDisputeRun(null);
      void refetch();
    }
  };

  const columns: TableColumn<ProfileRunView>[] = [
    { key: 'createdAt', header: t('profile.col.when'), width: 112, render: (r) => <span className="boards-when cp-num">{formatDateTime(r.createdAt)}</span> },
    {
      key: 'mission',
      header: t('profile.col.mission'),
      render: (r) => (
        <span className="boards-mission">
          <span className="boards-mission__label">{r.missionLabel}</span>
          <span className="boards-mission__type">{missionTypeLabel(r.missionType, session)}</span>
        </span>
      ),
    },
    { key: 'state', header: t('profile.col.result'), width: 230, render: (r) => <ResultCell state={r.state} endReason={r.endReason} flagged={r.flagged} voided={r.voided} /> },
    {
      key: 'points',
      header: t('profile.col.points'),
      numeric: true,
      width: 72,
      render: (r) => <span className={cx('boards-points', (r.voided || r.flagged) && 'is-struck')}>{formatNumber(r.points)}</span>,
    },
  ];
  if (own) {
    columns.push({
      key: 'cash',
      header: t('profile.col.cash'),
      numeric: true,
      width: 104,
      render: (r) => (
        <span className="boards-cash">
          <Money amount={r.cash} />
          {r.cashStatus && r.cashStatus !== 'none' ? <small className={cx('boards-cash__status', `is-${r.cashStatus}`)}>{tOr(`result.cash_status.${r.cashStatus}`, 'common.unknown')}</small> : null}
        </span>
      ),
    });
    columns.push({
      key: 'actions',
      header: '',
      width: 100,
      align: 'right',
      render: (r) =>
        r.canDispute ? (
          <Button
            size="sm"
            variant="secondary"
            icon="flag"
            onClick={(e) => {
              e.stopPropagation();
              setDisputeRun(r);
            }}
          >
            {t('profile.dispute')}
          </Button>
        ) : (
          <Icon name="chevronRight" size={16} className="boards-row-chevron" />
        ),
    });
  }

  if (!profile && loading) {
    return (
      <Screen title={t('ui.screen.profile')}>
        <LoadingBlock text={t('profile.loading')} />
      </Screen>
    );
  }
  if (!profile) {
    return (
      <Screen title={t('ui.screen.profile')} actions={target ? <Button variant="ghost" icon="chevronLeft" onClick={() => navigate('leaderboard')}>{t('profile.back')}</Button> : undefined}>
        <ErrorState error={error ?? 'err.internal'} onRetry={() => void refetch()} />
      </Screen>
    );
  }

  const level = profile.level ?? { label: '', badge: 'grey', xp: 0, next: null };
  const hasNext = typeof level.next === 'number' && level.next > level.xp;
  const into = Math.max(0, profile.xp - (level.xp || 0));
  const span = hasNext ? (level.next as number) - (level.xp || 0) : 1;
  const initials = profile.name
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((w) => w[0])
    .join('')
    .toUpperCase();

  return (
    <Screen
      title={own ? t('ui.screen.profile') : t('profile.public_title', { name: profile.name })}
      subtitle={own ? t('profile.subtitle_own') : t('profile.subtitle_public')}
      actions={!own ? <Button variant="ghost" icon="chevronLeft" onClick={() => navigate('leaderboard')}>{t('profile.back')}</Button> : undefined}
      className="boards-profile-screen"
    >
      <Grid cols="minmax(0, 3fr) minmax(0, 2fr)" gap={4} align="stretch">
        <Card padding="lg" className="boards-idcard">
          <div className="boards-id">
            <span className={cx('boards-avatar', `is-${level.badge}`)} aria-hidden>{initials || '?'}</span>
            <span className="boards-id__text">
              <span className="boards-id__name">{profile.name}</span>
              <span className="boards-id__line">
                {[profile.rank, profile.departmentShort, profile.callsign || t('common.no_callsign')].filter(Boolean).join(' · ')}
              </span>
              <Row gap={2} wrap>
                <XpBadge badge={level.badge} label={level.label} />
                {own && profile.hideName ? <Badge tone="neutral" icon="eye">{t('profile.name_hidden')}</Badge> : null}
              </Row>
            </span>
          </div>
          <ProgressBar
            className="boards-xpbar"
            tone="accent"
            value={hasNext ? into : 1}
            max={span}
            label={hasNext ? t('profile.xp_to_next', { next: formatNumber(level.next as number) }) : t('profile.xp_max')}
            showValue={<span>{formatNumber(profile.xp)} {t('leaderboard.xp')}</span>}
          />
          {own ? (
            <div className="boards-hide">
              <Toggle
                checked={!!profile.hideName}
                onChange={(v) => void toggleHide(v)}
                disabled={busy}
                label={t('profile.hide_name')}
                description={t('profile.hide_name_hint')}
              />
            </div>
          ) : null}
        </Card>
        <Card padding="md" className="boards-statcard">
          <div className="boards-stats">
            <Stat label={t('profile.stat.xp')} value={formatNumber(profile.xp)} icon="star" tone="accent" />
            <Stat label={t('profile.stat.season')} value={formatNumber(profile.seasonPoints ?? 0)} icon="trophy" />
            <Stat label={t('profile.stat.badges')} value={formatNumber(badges.length)} icon="medal" />
            <Stat
              label={t('profile.stat.completed')}
              value={formatNumber(runs.filter((r) => r.state === 'completed' && r.missionType !== 'manual_award' && r.missionType !== 'goal').length)}
              hint={t('profile.stat.completed_hint', { n: runs.length })}
              icon="checkCircle"
            />
          </div>
        </Card>
      </Grid>

      <Card title={t('profile.badges')} icon="medal" padding="sm">
        {badges.length ? (
          <div className="boards-badges">
            {badges.map((b) => (
              <div key={b.id} className={cx('boards-badge', `is-${b.kind ?? 'achievement'}`)} title={b.earnedAt ? t('profile.earned', { when: formatDateTime(b.earnedAt) }) : undefined}>
                <span className="boards-badge__icon">
                  <Icon name={BADGE_ICON[b.kind ?? 'achievement'] ?? 'shieldCheck'} size={16} />
                </span>
                <span className="boards-badge__text">
                  <span className="boards-badge__label">{b.label}</span>
                  {b.earnedAt ? <span className="boards-badge__when">{formatDateTime(b.earnedAt)}</span> : null}
                </span>
              </div>
            ))}
          </div>
        ) : (
          <EmptyState compact icon="medal" title={t('profile.no_badges')} text={own ? t('profile.no_badges_text') : undefined} />
        )}
      </Card>

      <Card
        title={t('profile.history')}
        subtitle={own ? t('profile.history_hint', { hours }) : t('profile.history_public')}
        icon="list"
        padding="none"
      >
        <Table
          columns={columns}
          rows={runs}
          rowKey={(r) => r.id}
          onRowClick={(r) => setOpenRun(r)}
          dense
          stickyHeader
          empty={<EmptyState compact icon="inbox" title={t('profile.no_runs')} text={own ? t('profile.no_runs_text') : undefined} />}
          className="boards-history"
          aria-label={t('profile.history')}
        />
      </Card>

      <Dialog
        open={!!openRun}
        onClose={() => setOpenRun(null)}
        title={openRun ? openRun.missionLabel : ''}
        description={openRun ? `${formatDateTime(openRun.createdAt)} · ${tOr(`reason.${openRun.endReason}`, 'common.unknown')}` : undefined}
        size="sm"
        footer={
          <>
            {openRun && own && openRun.canDispute ? (
              <Button variant="secondary" icon="flag" onClick={() => { setDisputeRun(openRun); setOpenRun(null); }}>
                {t('profile.dispute')}
              </Button>
            ) : null}
            <Button variant="primary" onClick={() => setOpenRun(null)}>{t('common.close')}</Button>
          </>
        }
      >
        {openRun ? (
          <div className="boards-breakdown-wrap">
            <Row gap={2} wrap>
              <StateBadge state={openRun.state} />
              {openRun.voided ? <Badge tone="danger" size="sm" icon="xCircle">{t('profile.voided')}</Badge> : null}
              {openRun.flagged ? <Badge tone="warning" size="sm" icon="alert">{t('profile.flagged')}</Badge> : null}
              {openRun.voided ? <span className="boards-muted">{t('profile.voided_note')}</span> : null}
            </Row>
            {openRun.breakdown ? (
              <RunBreakdown result={openRun.breakdown} cashStatus={own ? openRun.cashStatus : undefined} />
            ) : (
              <div className="boards-award">
                <span className="boards-award__points cp-num">{formatNumber(openRun.points, true)} <small>{t('common.pts')}</small></span>
                <span className="boards-muted">{t(`profile.no_breakdown.${openRun.missionType === 'manual_award' || openRun.missionType === 'goal' ? openRun.missionType : 'run'}`)}</span>
              </div>
            )}
          </div>
        ) : null}
      </Dialog>

      <ConfirmDialog
        open={!!disputeRun}
        title={t('profile.dispute_title')}
        message={disputeRun ? t('profile.dispute_message', { mission: disputeRun.missionLabel, when: formatDateTime(disputeRun.createdAt), hours }) : ''}
        confirmLabel={t('profile.dispute_send')}
        reason={{ label: t('profile.dispute_reason'), placeholder: t('profile.dispute_placeholder'), required: true, maxLength: 255 }}
        onConfirm={sendDispute}
        onCancel={() => setDisputeRun(null)}
        busy={busy}
      />
    </Screen>
  );
}
