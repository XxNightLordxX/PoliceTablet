// Supervisor UI · Department Report (screen key 'sup_report', callbacks sup:getDeptReport and
// sup:getOfficerActivity). The department's challenge standing, this week's bounty, and every officer
// of the department who played this week (runs, completed, points, cash, last run); tapping an officer
// opens their runs of this week. Supervisors only see their own department (the server enforces it).
import { useState } from 'react';
import {
  Badge, Button, Card, Dialog, EmptyState, ErrorState, Grid, Icon, IconButton, LoadingBlock, Money, Row, Screen, SearchInput,
  Stat, Table, type TableColumn,
} from '../../shared/components';
import { cx } from '../../shared/cx';
import { formatDateTime, formatDuration, formatMoney, formatNumber } from '../../shared/format';
import { useRequest } from '../../shared/hooks';
import { t, tOr } from '../../shared/i18n';
import { useSession } from '../../shared/session';
import { asList, type ActivityRun, type DeptReport as DeptReportData, type OfficerActivity, type ReportOfficer } from '../../types/boards';
import { BountyCard, DeptBars } from '../../officer/screens/Challenge';
import { formatDay } from '../../officer/screens/Leaderboard';
import { StateBadge, missionTypeLabel } from '../../officer/screens/Profile';
import './DeptReport.css';

function ActivityDialog({ officer, onClose }: { officer: ReportOfficer | null; onClose: () => void }) {
  const session = useSession();
  const { data, loading, error, refetch } = useRequest<OfficerActivity>('sup:getOfficerActivity', { citizenid: officer?.citizenid }, { skip: !officer });
  const current = data && data.officer?.citizenid === officer?.citizenid ? data : null;
  const runs = asList(current?.runs);
  const columns: TableColumn<ActivityRun>[] = [
    { key: 'createdAt', header: t('profile.col.when'), width: 118, render: (r) => <span className="boards-muted cp-num">{formatDateTime(r.createdAt)}</span> },
    {
      key: 'mission',
      header: t('profile.col.mission'),
      render: (r) => (
        <span className="boards-report-cell">
          <span className="boards-strong">{r.missionLabel}</span>
          <span className="boards-report-cell__sub">
            {[missionTypeLabel(r.missionType, session), r.participants > 1 ? t('result.participants', { n: r.participants }) : t('result.solo'), formatDuration(r.durationS)].join(' · ')}
          </span>
        </span>
      ),
    },
    {
      key: 'state',
      header: t('profile.col.result'),
      render: (r) => (
        <span className="boards-report-result">
          <StateBadge state={r.state} />
          <span className="boards-muted">{tOr(`reason.${r.endReason}`, 'common.unknown')}</span>
        </span>
      ),
    },
    {
      key: 'flags',
      header: '',
      width: 120,
      render: (r) => (
        <span className="boards-report-flags">
          {r.voided ? <Badge tone="danger" size="sm">{t('profile.voided')}</Badge> : null}
          {r.flagged ? (
            <Badge tone="warning" size="sm" icon="alert">
              {r.flagReason ? tOr(`profile.flag_reason.${r.flagReason}`, 'profile.flagged') : t('profile.flagged')}
            </Badge>
          ) : null}
        </span>
      ),
    },
    { key: 'points', header: t('profile.col.points'), numeric: true, width: 76, render: (r) => <span className={cx((r.voided || r.flagged) && 'boards-struck')}>{formatNumber(r.points)}</span> },
    { key: 'cash', header: t('profile.col.cash'), numeric: true, width: 96, render: (r) => <Money amount={r.cash} /> },
  ];
  return (
    <Dialog
      open={!!officer}
      onClose={onClose}
      size="lg"
      title={officer ? t('sup.report.activity_title', { name: officer.name }) : ''}
      description={officer ? [officer.rank, officer.callsign || t('common.no_callsign'), t('sup.report.activity_week', { from: formatDay(current?.week?.startsAt) })].filter(Boolean).join(' · ') : undefined}
      footer={<Button variant="primary" onClick={onClose}>{t('common.close')}</Button>}
    >
      {error && !current ? (
        <ErrorState compact error={error} onRetry={() => void refetch()} />
      ) : (
        <Table columns={columns} rows={runs} rowKey={(r) => r.id} dense loading={loading} maxHeight={400} empty={t('sup.report.activity_empty')} />
      )}
    </Dialog>
  );
}

export default function DeptReport() {
  const session = useSession();
  const { data, loading, error, refetch } = useRequest<DeptReportData>('sup:getDeptReport', {}, { pollMs: 60000 });
  const [open, setOpen] = useState<ReportOfficer | null>(null);
  const [search, setSearch] = useState('');

  const officers = asList(data?.officers);
  const q = search.trim().toLowerCase();
  const shown = q ? officers.filter((o) => [o.name, o.callsign ?? '', o.citizenid, o.rank].some((v) => v.toLowerCase().includes(q))) : officers;
  const dept = data?.department ?? null;
  const standing = data?.standing ?? null;
  const totals = officers.reduce(
    (s, o) => ({ runs: s.runs + o.runs, completed: s.completed + o.completed, points: s.points + o.points, cash: s.cash + o.cash }),
    { runs: 0, completed: 0, points: 0, cash: 0 },
  );

  const columns: TableColumn<ReportOfficer>[] = [
    {
      key: 'officer',
      header: t('leaderboard.col.officer'),
      render: (o) => (
        <span className="boards-report-cell">
          <span className="boards-strong">{o.name}</span>
          <span className="boards-report-cell__sub">{[o.rank, o.callsign || t('common.no_callsign')].filter(Boolean).join(' · ')}</span>
        </span>
      ),
    },
    { key: 'runs', header: t('sup.report.col.runs'), numeric: true, width: 70, render: (o) => formatNumber(o.runs) },
    { key: 'completed', header: t('sup.report.col.completed'), numeric: true, width: 96, render: (o) => formatNumber(o.completed) },
    {
      key: 'failed',
      header: t('sup.report.col.failed_abandoned'),
      numeric: true,
      width: 110,
      render: (o) => <span className="boards-muted">{`${formatNumber(o.failed)} / ${formatNumber(o.abandoned)}`}</span>,
    },
    { key: 'flagged', header: t('sup.report.col.flagged'), numeric: true, width: 80, render: (o) => (o.flagged ? <Badge tone="warning" size="sm">{formatNumber(o.flagged)}</Badge> : <span className="boards-muted">0</span>) },
    { key: 'points', header: t('sup.report.col.points'), numeric: true, width: 90, render: (o) => <span className="boards-strong">{formatNumber(o.points)}</span> },
    { key: 'cash', header: t('sup.report.col.cash'), numeric: true, width: 100, render: (o) => <Money amount={o.cash} /> },
    { key: 'last', header: t('sup.report.col.last'), width: 118, render: (o) => <span className="boards-muted cp-num">{o.lastRunAt ? formatDateTime(o.lastRunAt) : '–'}</span> },
    { key: 'open', header: '', width: 36, align: 'right', render: () => <Icon name="chevronRight" size={16} className="boards-row-chevron" /> },
  ];

  if (!data && loading) {
    return (
      <Screen title={t('ui.screen.sup_report')}>
        <LoadingBlock />
      </Screen>
    );
  }
  if (!data) {
    return (
      <Screen title={t('ui.screen.sup_report')}>
        <ErrorState error={error ?? 'err.internal'} onRetry={() => void refetch()} />
      </Screen>
    );
  }

  return (
    <Screen
      title={t('ui.screen.sup_report')}
      subtitle={t('sup.report.subtitle', { dept: dept?.label ?? session.officer?.departmentLabel ?? '', from: formatDay(data.week?.startsAt) })}
      actions={<IconButton icon="refresh" label={t('leaderboard.refresh')} loading={loading} onClick={() => void refetch()} />}
      className="boards-report"
    >
      <Grid cols="minmax(0, 1fr) minmax(0, 1fr)" gap={4} align="stretch">
        <Card
          title={t('sup.report.standing')}
          subtitle={data.season ? t('sup.report.season_line', { name: data.season.name, week: data.season.week, n: data.season.weeksLeft }) : undefined}
          icon="trophy"
          className="boards-standing"
        >
          {!data.season || !standing ? (
            <EmptyState compact icon="calendar" title={data.enabled === false ? t('challenge.disabled_title') : t('challenge.no_season_title')} />
          ) : (
            <div className="boards-standing__body">
              <div className="boards-standing__rank" style={{ borderColor: dept?.colour }}>
                <span className="boards-standing__place cp-num">#{standing.rank ?? '–'}</span>
                <span className="boards-standing__of">{t('sup.report.of', { n: standing.of ?? asList(data.standings).length })}</span>
              </div>
              <div className="boards-standing__stats">
                <Stat size="sm" label={t('sup.report.score')} value={formatNumber(standing.score)} tone="accent" />
                <Stat size="sm" label={t('sup.report.active')} value={formatNumber(standing.activeOfficers)} />
                <Stat size="sm" label={t('sup.report.season_points')} value={formatNumber(standing.points ?? 0)} />
                <Stat size="sm" label={t('sup.report.bonus')} value={standing.bonus ? `+${formatNumber(standing.bonus)}` : '0'} tone={standing.bonus ? 'success' : 'neutral'} />
              </div>
            </div>
          )}
          {asList(data.standings).length > 1 && data.season ? (
            <div className="boards-standing__bars">
              <DeptBars departments={asList(data.standings)} myDepartment={dept?.key} compact />
            </div>
          ) : null}
        </Card>
        <BountyCard bounty={data.bounty} myDepartment={dept?.key} />
      </Grid>

      <div className="boards-report-stats">
        <Stat size="sm" label={t('sup.report.stat.officers')} value={formatNumber(officers.length)} icon="users" />
        <Stat size="sm" label={t('sup.report.stat.runs')} value={formatNumber(totals.runs)} hint={t('sup.report.stat.completed', { n: formatNumber(totals.completed) })} icon="activity" />
        <Stat size="sm" label={t('sup.report.stat.points')} value={formatNumber(totals.points)} icon="star" />
        <Stat size="sm" label={t('sup.report.stat.cash')} value={formatMoney(totals.cash)} icon="dollar" tone="success" />
      </div>

      <Card
        title={t('sup.report.activity')}
        subtitle={t('sup.report.activity_hint')}
        icon="activity"
        padding="none"
        actions={<SearchInput value={search} onChange={setSearch} placeholder={t('sup.report.search')} className="boards-report-search" />}
      >
        <Table
          columns={columns}
          rows={shown}
          rowKey={(o) => o.citizenid}
          onRowClick={(o) => setOpen(o)}
          dense
          maxHeight={360}
          className="boards-flat-table"
          empty={
            <EmptyState compact icon="inbox" title={q ? t('sup.report.no_match') : t('sup.report.no_activity')} text={q ? undefined : t('sup.report.no_activity_text')} />
          }
        />
      </Card>
      <Row gap={2} className="boards-report-note">
        <Icon name="info" size={13} />
        <span>{t('sup.report.note')}</span>
      </Row>

      <ActivityDialog officer={open} onClose={() => setOpen(null)} />
    </Screen>
  );
}
