// Officer UI · Department Challenge (screen key 'challenge', callbacks getChallenge + getDeptContributors).
// One score bar per department in its own theme colour, the season and weeks left, this week's bounty with
// the department currently leading it, and the viewer's department's top 5 contributors. Tapping a
// department opens its full contributor list. DeptBars and BountyCard are reused by the Admin Seasons
// screen and the Supervisor Department Report.
import { useState, type ReactNode } from 'react';
import {
  Badge, Card, Dialog, EmptyState, ErrorState, Grid, Icon, LoadingBlock, Screen, Stack, Table, type TableColumn,
} from '../../shared/components';
import { cx } from '../../shared/cx';
import { formatNumber } from '../../shared/format';
import { useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { useNavigate } from '../../shared/navigation';
import { useSession } from '../../shared/session';
import { asList, type BountyView, type ChallengeData, type ChallengeDepartment, type Contributor, type DeptContributors } from '../../types/boards';
import { RankCell } from './Leaderboard';
import './Challenge.css';

/** "3d 4h" / "5h 12m" / "8m" until the week closes. */
export function formatEndsIn(seconds: number | null | undefined): string {
  const s = Math.max(0, Math.floor(Number(seconds) || 0));
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  if (d > 0) return t('challenge.time.days_hours', { d, h });
  if (h > 0) return t('challenge.time.hours_minutes', { h, m });
  return t('challenge.time.minutes', { m: Math.max(1, m) });
}

export function modeText(mode: string | undefined): string {
  return t(`challenge.mode.${mode === 'total' || mode === 'top10' ? mode : 'average'}`);
}

/** Score bars per department, each in the department's colour. */
export function DeptBars({
  departments, myDepartment, mode, onSelect, compact,
}: {
  departments: ChallengeDepartment[];
  myDepartment?: string;
  mode?: string;
  onSelect?: (dept: ChallengeDepartment) => void;
  compact?: boolean;
}) {
  const list = asList(departments);
  const max = Math.max(0, ...list.map((d) => Number(d.score) || 0));
  if (!list.length) return <EmptyState compact icon="flag" title={t('challenge.no_departments')} />;
  return (
    <div className={cx('boards-depts', compact && 'boards-depts--compact')}>
      {list.map((d, i) => {
        const pct = max > 0 ? Math.max(d.score > 0 ? 3 : 0, (d.score / max) * 100) : 0;
        const mine = d.key === myDepartment;
        const rank = d.rank ?? i + 1;
        const body = (
          <>
            <span className={cx('boards-dept__rank', rank === 1 && max > 0 && 'is-first')}>
              {rank === 1 && max > 0 ? <Icon name="trophy" size={15} /> : <span className="cp-num">{rank}</span>}
            </span>
            <span className="boards-dept__main">
              <span className="boards-dept__head">
                <span className="boards-dept__swatch" style={{ backgroundColor: d.colour }} aria-hidden />
                <span className="boards-dept__name">{d.label}</span>
                <Badge size="sm">{d.short}</Badge>
                {mine ? <Badge tone="accent" size="sm">{t('challenge.your_department')}</Badge> : null}
                <span className="boards-dept__score cp-num">{formatNumber(d.score)}</span>
              </span>
              <span className="boards-dept__track" aria-hidden>
                <span className="boards-dept__fill" style={{ width: `${pct}%`, backgroundColor: d.colour }} />
              </span>
              <span className="boards-dept__meta">
                <span>{t('challenge.active_officers', { n: d.activeOfficers })}</span>
                {d.points !== undefined ? <span className="cp-num">{t('challenge.season_points', { n: formatNumber(d.points) })}</span> : null}
                {d.bonus ? <span className="boards-dept__bonus cp-num">{t('challenge.bonus', { n: formatNumber(d.bonus) })}</span> : null}
                {!compact && mode ? <span className="boards-dept__mode">{modeText(mode)}</span> : null}
              </span>
            </span>
            {onSelect ? <Icon name="chevronRight" size={16} className="boards-dept__chevron" /> : null}
          </>
        );
        return onSelect ? (
          <button key={d.key} type="button" className={cx('boards-dept', mine && 'is-mine')} onClick={() => onSelect(d)} aria-label={t('challenge.open_contributors', { dept: d.label })}>
            {body}
          </button>
        ) : (
          <div key={d.key} className={cx('boards-dept', mine && 'is-mine')}>
            {body}
          </div>
        );
      })}
    </div>
  );
}

/** This week's bounty: objective, time left, the leading department and the count per active officer. */
export function BountyCard({ bounty, myDepartment, actions, footer }: { bounty: BountyView | null; myDepartment?: string; actions?: ReactNode; footer?: ReactNode }) {
  const rates = asList(bounty?.rates);
  const maxRate = Math.max(0, ...rates.map((r) => Number(r.rate) || 0));
  return (
    <Card title={t('challenge.bounty_title')} subtitle={bounty?.week ? t('challenge.bounty_week', { n: bounty.week }) : undefined} icon="target" actions={actions} footer={footer} className="boards-bounty">
      {!bounty ? (
        <EmptyState compact icon="target" title={t('challenge.no_bounty')} />
      ) : (
        <div className="boards-bounty__body">
          <div className="boards-bounty__objective">{bounty.label}</div>
          <div className="boards-bounty__facts">
            {bounty.endsIn !== undefined && !bounty.closed ? (
              <span><Icon name="clock" size={13} /> {t('challenge.ends_in', { time: formatEndsIn(bounty.endsIn) })}</span>
            ) : null}
            {bounty.closed ? <Badge tone="neutral" size="sm">{t('challenge.bounty_closed')}</Badge> : null}
            {bounty.overridden ? <Badge tone="warning" size="sm" icon="edit">{t('challenge.bounty_overridden')}</Badge> : null}
          </div>
          <div className="boards-bounty__leader">
            <span className="boards-bounty__leader-label">{t('challenge.leader')}</span>
            {bounty.leader ? (
              <Badge tone={bounty.leaderKey && bounty.leaderKey === myDepartment ? 'success' : 'accent'} icon="trophy">{bounty.leader}</Badge>
            ) : (
              <span className="boards-muted">{t('challenge.no_leader')}</span>
            )}
          </div>
          {rates.length ? (
            <div className="boards-rates">
              {rates.map((r) => (
                <div key={r.key} className={cx('boards-rate', r.key === myDepartment && 'is-mine')}>
                  <span className="boards-rate__dept">
                    <span className="boards-dept__swatch" style={{ backgroundColor: r.colour }} aria-hidden />
                    {r.short}
                  </span>
                  <span className="boards-rate__track" aria-hidden>
                    <span className="boards-rate__fill" style={{ width: `${maxRate > 0 ? Math.max(r.rate > 0 ? 4 : 0, (r.rate / maxRate) * 100) : 0}%`, backgroundColor: r.colour }} />
                  </span>
                  <span className="boards-rate__value cp-num" title={t('challenge.rate_hint', { count: r.count, n: r.activeOfficers })}>
                    {r.rate.toFixed(2)}
                  </span>
                </div>
              ))}
              <div className="boards-rates__note">{t('challenge.rate_note')}</div>
            </div>
          ) : null}
        </div>
      )}
    </Card>
  );
}

function ContributorList({ list, onOpen }: { list: Contributor[]; onOpen?: (c: Contributor) => void }) {
  if (!list.length) return <EmptyState compact icon="users" title={t('challenge.no_contributors')} text={t('challenge.no_contributors_text')} />;
  return (
    <ol className="boards-contributors">
      {list.map((c, i) => (
        <li key={c.citizenid ?? `${c.name}-${i}`}>
          <button type="button" className="boards-contributor" onClick={onOpen && c.citizenid ? () => onOpen(c) : undefined} disabled={!onOpen || !c.citizenid}>
            <RankCell rank={c.rank ?? i + 1} />
            <span className="boards-contributor__who">
              <span className="boards-contributor__name">{c.name}</span>
              <span className="boards-contributor__callsign">{c.callsign || t('common.no_callsign')}</span>
            </span>
            <span className="boards-contributor__points cp-num">
              {formatNumber(c.points)} <small>{t('common.pts')}</small>
            </span>
          </button>
        </li>
      ))}
    </ol>
  );
}

function ContributorsDialog({ dept, onClose }: { dept: ChallengeDepartment | null; onClose: () => void }) {
  const navigate = useNavigate();
  const { data, loading, error, refetch } = useRequest<DeptContributors>('getDeptContributors', { department: dept?.key }, { skip: !dept });
  const rows = data && data.department?.key === dept?.key ? asList(data.contributors) : [];
  const minRuns = data?.minRunsActive ?? 3;
  const columns: TableColumn<Contributor>[] = [
    { key: 'rank', header: t('leaderboard.col.rank'), width: 70, render: (c, i) => <RankCell rank={c.rank ?? i + 1} /> },
    { key: 'name', header: t('leaderboard.col.officer'), render: (c) => <span className="boards-officer__name">{c.name}</span> },
    { key: 'callsign', header: t('leaderboard.col.callsign'), width: 110, render: (c) => c.callsign || <span className="boards-muted">{t('common.no_callsign')}</span> },
    { key: 'runs', header: t('leaderboard.col.runs'), numeric: true, width: 80, render: (c) => formatNumber(c.runs ?? 0) },
    { key: 'points', header: t('leaderboard.col.points'), numeric: true, width: 100, render: (c) => formatNumber(c.points) },
    {
      key: 'active',
      header: t('challenge.col.status'),
      width: 110,
      render: (c) => (c.active ? <Badge tone="success" size="sm">{t('challenge.active')}</Badge> : <Badge size="sm">{t('challenge.not_active')}</Badge>),
    },
  ];
  return (
    <Dialog
      open={!!dept}
      onClose={onClose}
      size="lg"
      title={dept ? t('challenge.contributors_title', { dept: dept.label }) : ''}
      description={t('challenge.contributors_desc', { n: minRuns })}
    >
      {error && !data ? (
        <ErrorState compact error={error} onRetry={() => void refetch()} />
      ) : (
        <Table
          columns={columns}
          rows={rows}
          rowKey={(c, i) => c.citizenid ?? i}
          loading={loading}
          dense
          maxHeight={380}
          onRowClick={(c) => {
            if (!c.citizenid) return;
            onClose();
            navigate('profile', { citizenid: c.citizenid });
          }}
          empty={t('challenge.no_contributors')}
        />
      )}
    </Dialog>
  );
}

export default function Challenge() {
  const session = useSession();
  const navigate = useNavigate();
  const { data, loading, error, refetch } = useRequest<ChallengeData>('getChallenge', {}, { pollMs: 60000 });
  const [selected, setSelected] = useState<ChallengeDepartment | null>(null);
  const myDept = data?.myDepartment ?? session.officer?.department;
  const mine = asList(data?.departments).find((d) => d.key === myDept);
  const season = data?.season ?? null;

  let content: ReactNode;
  if (!data && loading) content = <LoadingBlock text={t('challenge.loading')} />;
  else if (!data && error) content = <ErrorState error={error} onRetry={() => void refetch()} />;
  else if (data && data.enabled === false) content = <EmptyState icon="flag" title={t('challenge.disabled_title')} text={t('challenge.disabled_text')} />;
  else if (!season) content = <EmptyState icon="calendar" title={t('challenge.no_season_title')} text={t('challenge.no_season_text')} />;
  else {
    content = (
      <>
        <div className="boards-season">
          <span className="boards-season__icon"><Icon name="trophy" size={22} /></span>
          <span className="boards-season__titles">
            <span className="boards-season__label">{t('challenge.season_label')}</span>
            <span className="boards-season__name">{season.name}</span>
          </span>
          <span className="boards-season__stats">
            {season.week ? (
              <span className="boards-season__stat">
                <span className="cp-num">{season.week}</span>
                <small>{t('challenge.week')}</small>
              </span>
            ) : null}
            <span className="boards-season__stat">
              <span className="cp-num">{season.weeksLeft}</span>
              <small>{t('challenge.weeks_left', { n: season.weeksLeft })}</small>
            </span>
            {mine ? (
              <span className="boards-season__stat">
                <span className="cp-num">#{mine.rank ?? '–'}</span>
                <small>{t('challenge.your_rank', { dept: mine.short })}</small>
              </span>
            ) : null}
          </span>
        </div>
        <Grid cols="minmax(0, 3fr) minmax(0, 2fr)" gap={4} align="start">
          <Card title={t('challenge.standings')} subtitle={modeText(data?.mode)} icon="barChart">
            <DeptBars departments={asList(data?.departments)} myDepartment={myDept} onSelect={setSelected} />
            <p className="boards-card-note">{t('challenge.tap_department')}</p>
          </Card>
          <Stack gap={4}>
            <BountyCard bounty={data?.bounty ?? null} myDepartment={myDept} />
            <Card title={t('challenge.top_contributors', { dept: mine?.short ?? session.officer?.departmentShort ?? '' })} icon="users" padding="sm">
              <ContributorList list={asList(data?.topContributors).slice(0, 5)} onOpen={(c) => navigate('profile', { citizenid: c.citizenid })} />
            </Card>
          </Stack>
        </Grid>
      </>
    );
  }

  return (
    <Screen
      title={t('ui.screen.challenge')}
      subtitle={season ? t('challenge.subtitle', { name: season.name, n: season.weeksLeft }) : t('challenge.subtitle_none')}
      className="boards-challenge"
    >
      {content}
      <ContributorsDialog dept={selected} onClose={() => setSelected(null)} />
    </Screen>
  );
}
