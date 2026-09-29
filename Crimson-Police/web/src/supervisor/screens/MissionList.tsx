// Supervisor UI · Mission List (screen key 'sup_missions').
// Every mission by name, built-in and custom: type, difficulty, officers supported, current base payout
// (and where it comes from), cooldown and who is running it now. Missions open to every department that
// support 2+ officers (never the Weekly Boss) can be launched as a Cross-Department Mission.
// Data: callback getMissionList (modules/admin) · action server:sup:opLaunch { missionId } (modules/operations).
import { useMemo, useState } from 'react';
import {
  Badge, Button, Card, ConfirmDialog, EmptyState, ErrorState, Grid, Icon, IconButton, LoadingBlock, Money, Row, Screen,
  SearchInput, SegmentedControl, Select, Stat, Table, type TableColumn,
} from '../../shared/components';
import { asArray } from '../../shared/data';
import { useAction, useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { useNavigate } from '../../shared/navigation';
import { useCan, useSession } from '../../shared/session';
import type { MissionListData, MissionListEntry } from '../../types/oversight';
import './MissionList.css';

type SourceFilter = 'all' | 'builtin' | 'custom';

function cooldownText(seconds: number): string {
  if (!seconds || seconds <= 0) return t('sup.missions.cooldown_none');
  if (seconds < 60) return t('sup.missions.seconds', { n: seconds });
  const m = Math.round(seconds / 60);
  if (m < 120) return t('sup.missions.minutes', { n: m });
  return t('sup.missions.hours', { n: Math.round((m / 60) * 10) / 10 });
}

function Stars({ value, max = 3 }: { value: number; max?: number }) {
  return (
    <span className="oversight-stars" aria-label={t('sup.missions.difficulty_aria', { n: value, max })} title={t('sup.missions.difficulty_aria', { n: value, max })}>
      {Array.from({ length: max }, (_, i) => (
        <span key={i} className={i < value ? 'oversight-stars__on' : 'oversight-stars__off'}>
          <Icon name="star" size={14} />
        </span>
      ))}
    </span>
  );
}

function Runners({ m }: { m: MissionListEntry }) {
  const list = asArray(m.runningNow);
  if (!list.length) return <span className="oversight-muted">{t('sup.missions.idle')}</span>;
  const shown = list.slice(0, 2);
  const extra = list.length - shown.length;
  return (
    <div className="oversight-runners" title={list.map((r) => `${r.name}${r.callsign ? ` · ${r.callsign}` : ''}`).join('\n')}>
      {shown.map((r) => (
        <span key={`${r.runId}-${r.src}`} className="oversight-runner">
          <span className="oversight-runner__dot" aria-hidden />
          <span className="oversight-runner__name">{r.name}</span>
          <span className="oversight-runner__dept">{r.departmentShort}</span>
        </span>
      ))}
      {extra > 0 ? <span className="oversight-runner oversight-runner--more">{t('sup.missions.more', { n: extra })}</span> : null}
    </div>
  );
}

export default function SupMissionList() {
  const session = useSession();
  const can = useCan();
  const navigate = useNavigate();
  const { data, loading, error, refetch } = useRequest<MissionListData>('getMissionList', {}, { pushTopic: 'operation', pollMs: 20000 });
  const { run, busy } = useAction();
  const [query, setQuery] = useState('');
  const [type, setType] = useState<string>('all');
  const [source, setSource] = useState<SourceFilter>('all');
  const [launch, setLaunch] = useState<MissionListEntry | null>(null);

  const missions = asArray(data?.missions);
  const operation = data?.operation ?? null;
  const canLaunch = !!data?.canLaunch && can('launchCrossDept');

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    return missions.filter((m) => {
      if (type !== 'all' && m.type !== type) return false;
      if (source !== 'all' && m.source !== source) return false;
      if (q && !m.label.toLowerCase().includes(q) && !m.id.toLowerCase().includes(q)) return false;
      return true;
    });
  }, [missions, query, type, source]);

  const stats = useMemo(() => {
    let custom = 0;
    let running = 0;
    let eligible = 0;
    for (const m of missions) {
      if (m.source === 'custom') custom += 1;
      running += asArray(m.runningNow).length;
      if (m.crossDeptEligible) eligible += 1;
    }
    return { custom, running, eligible };
  }, [missions]);

  const typeItems = [
    { key: 'all', label: t('sup.missions.filter.all_types') },
    ...asArray(session.config.missionTypes).map((mt) => ({ key: mt.key, label: mt.label })),
  ];

  const deptShort = (key: string) => asArray(session.config.departments).find((d) => d.key === key)?.short ?? key.toUpperCase();

  const confirmLaunch = async () => {
    if (!launch) return;
    const res = await run('server:sup:opLaunch', { missionId: launch.id }, { success: 'sup.missions.launched', successVars: { mission: launch.label } });
    setLaunch(null);
    void refetch();
    if (res.ok && can('launchCrossDept')) navigate('sup_crossdept');
  };

  const columns: TableColumn<MissionListEntry>[] = [
    {
      key: 'label',
      header: t('sup.missions.col.mission'),
      render: (m) => (
        <div className="oversight-mission">
          <div className="oversight-mission__name">
            <span className="oversight-mission__label" title={m.label}>{m.label}</span>
            {!m.enabled ? <Badge size="sm" tone="grey">{t('sup.missions.disabled')}</Badge> : null}
          </div>
          <div className="oversight-mission__meta">
            <span>{m.typeLabel}</span>
            <span aria-hidden>·</span>
            {m.source === 'custom' ? (
              <Badge size="sm" tone="primary" icon="tool">{t('sup.missions.source.custom_v', { version: m.version ?? 1 })}</Badge>
            ) : (
              <span>{t('sup.missions.source.builtin')}</span>
            )}
            {m.isBoss ? <Badge size="sm" tone="accent" icon="star">{t('sup.missions.boss')}</Badge> : null}
            {asArray(m.departments).length ? (
              <Badge size="sm" tone="warning" variant="outline">{t('sup.missions.departments_only', { depts: asArray(m.departments).map(deptShort).join(', ') })}</Badge>
            ) : null}
          </div>
        </div>
      ),
    },
    { key: 'difficulty', header: t('sup.missions.col.difficulty'), width: 88, render: (m) => <Stars value={m.difficulty} /> },
    {
      key: 'officers',
      header: t('sup.missions.col.officers'),
      width: 76,
      align: 'center',
      render: (m) => (
        <span className="oversight-officers cp-num">
          <Icon name="users" size={13} />
          {m.minOfficers === m.maxOfficers ? t('sup.missions.officers_one', { n: m.maxOfficers }) : t('sup.missions.officers_range', { min: m.minOfficers, max: m.maxOfficers })}
        </span>
      ),
    },
    {
      key: 'payout',
      header: t('sup.missions.col.payout'),
      width: 128,
      numeric: true,
      render: (m) => (
        <span className="oversight-payout" title={t(`sup.missions.payout_hint.${m.payoutSource}`)}>
          <Money amount={m.basePayout} />
          <Badge size="sm" tone={m.payoutSource === 'admin' ? 'accent' : m.payoutSource === 'event' ? 'warning' : 'grey'}>
            {t(`sup.missions.payout_source.${m.payoutSource}`)}
          </Badge>
        </span>
      ),
    },
    { key: 'cooldown', header: t('sup.missions.col.cooldown'), width: 86, numeric: true, render: (m) => <span className="cp-num">{cooldownText(m.cooldown)}</span> },
    { key: 'running', header: t('sup.missions.col.running'), width: 156, render: (m) => <Runners m={m} /> },
    {
      key: 'actions',
      header: '',
      width: 104,
      align: 'right',
      render: (m) =>
        m.crossDeptEligible && canLaunch ? (
          <Button
            size="sm"
            variant="secondary"
            icon="globe"
            disabled={!!operation || busy}
            title={operation ? t('sup.missions.op_active', { mission: operation.missionLabel }) : t('sup.missions.launch_hint')}
            onClick={() => setLaunch(m)}
          >
            {t('sup.missions.launch')}
          </Button>
        ) : null,
    },
  ];

  let body;
  if (loading && !data) body = <LoadingBlock />;
  else if (error && !data) body = <Card><ErrorState error={error} onRetry={() => void refetch()} /></Card>;
  else
    body = (
      <>
        {operation ? (
          <Card highlight="accent" padding="sm" className="oversight-op">
            <Row gap={3}>
              <span className="oversight-op__icon" aria-hidden><Icon name="globe" size={18} /></span>
              <div className="oversight-op__text">
                <strong>{t('sup.missions.op_active', { mission: operation.missionLabel })}</strong>
                <span>{t('sup.missions.op_locked')}</span>
              </div>
              {can('launchCrossDept') ? (
                <Button size="sm" variant="secondary" iconRight="chevronRight" onClick={() => navigate('sup_crossdept')}>
                  {t('sup.missions.op_open')}
                </Button>
              ) : null}
            </Row>
          </Card>
        ) : null}
        <Grid cols={4} gap={3}>
          <Card padding="sm"><Stat size="sm" icon="layers" label={t('sup.missions.stat.total')} value={<span className="cp-num">{missions.length}</span>} /></Card>
          <Card padding="sm"><Stat size="sm" icon="tool" label={t('sup.missions.stat.custom')} value={<span className="cp-num">{stats.custom}</span>} /></Card>
          <Card padding="sm"><Stat size="sm" icon="activity" tone={stats.running ? 'success' : 'neutral'} label={t('sup.missions.stat.running')} value={<span className="cp-num">{stats.running}</span>} /></Card>
          <Card padding="sm"><Stat size="sm" icon="globe" tone="accent" label={t('sup.missions.stat.eligible')} value={<span className="cp-num">{stats.eligible}</span>} /></Card>
        </Grid>
        <div className="oversight-filters">
          <SearchInput value={query} onChange={setQuery} placeholder={t('sup.missions.search')} aria-label={t('sup.missions.search')} className="oversight-filters__search" />
          <SegmentedControl size="sm" items={typeItems} value={type} onChange={setType} aria-label={t('sup.missions.col.type')} />
          <Select
            value={source}
            onChange={(v) => setSource(v as SourceFilter)}
            aria-label={t('sup.missions.filter.source')}
            options={[
              { value: 'all', label: t('sup.missions.filter.all_sources') },
              { value: 'builtin', label: t('sup.missions.source.builtin') },
              { value: 'custom', label: t('sup.missions.source.custom') },
            ]}
          />
        </div>
        <Table
          columns={columns}
          rows={filtered}
          rowKey={(m) => m.id}
          loading={loading}
          empty={missions.length
            ? <EmptyState compact icon="search" title={t('sup.missions.empty')} />
            : <EmptyState compact icon="layers" title={t('sup.missions.none')} text={t('sup.missions.none_text')} />}
          aria-label={t('ui.screen.sup_missions')}
        />
        <div className="oversight-footnote">
          <Icon name="info" size={13} />
          <span>{t('sup.missions.count', { shown: filtered.length, total: missions.length })}</span>
          <span aria-hidden>·</span>
          <span>{t('sup.missions.eligible_rule')}</span>
        </div>
      </>
    );

  return (
    <Screen
      title={t('ui.screen.sup_missions')}
      subtitle={t('sup.missions.subtitle')}
      actions={<IconButton icon="refresh" label={t('sup.refresh')} variant="secondary" loading={loading && !!data} onClick={() => void refetch()} />}
      className="oversight-screen"
    >
      {body}
      <ConfirmDialog
        open={!!launch}
        title={t('sup.missions.launch_title')}
        message={launch ? t('sup.missions.launch_message', { mission: launch.label }) : null}
        confirmLabel={t('sup.missions.launch')}
        onConfirm={confirmLaunch}
        onCancel={() => setLaunch(null)}
        busy={busy}
      />
    </Screen>
  );
}
