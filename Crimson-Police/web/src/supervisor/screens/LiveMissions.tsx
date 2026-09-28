// Supervisor UI · Live Missions (screen key 'sup_live').
// Runs involving the supervisor's department: participants, mission type, drawn mission, tier and time
// left (counting down locally). Force recall ends one officer's run as Abandoned with no cooldown.
// Data: callback sup:getLiveRuns (modules/admin, polled every 10 s) · action server:sup:forceRecall { runId, src, reason }.
import { useEffect, useState } from 'react';
import {
  Badge, Button, Card, ConfirmDialog, Countdown, EmptyState, ErrorState, Icon, IconButton, LoadingBlock, Row, Screen, TierBadge,
} from '../../shared/components';
import { asArray } from '../../shared/data';
import { formatDateTime } from '../../shared/format';
import { useAction, useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { useCan, useSession } from '../../shared/session';
import type { LiveParticipant, LiveRunEx, LiveRunsData } from '../../types/oversight';
import './LiveMissions.css';

interface RecallTarget { run: LiveRunEx; p: LiveParticipant }

function typeLabel(session: ReturnType<typeof useSession>, key: string): string {
  return asArray(session.config.missionTypes).find((m) => m.key === key)?.label ?? key;
}

function RunCard({ run, canRecall, onRecall, fetchKey }: { run: LiveRunEx; canRecall: boolean; onRecall: (p: LiveParticipant) => void; fetchKey: number }) {
  const session = useSession();
  const participants = asArray(run.participants);
  const active = participants.filter((p) => p.status === 'active').length;
  const inProgress = run.state === 'in_progress';
  return (
    <Card
      className="oversight-live-card"
      highlight={run.test ? 'warning' : inProgress ? 'success' : 'primary'}
      title={
        <span className="oversight-live-card__title">
          {run.missionLabel}
          {run.test ? <Badge size="sm" tone="warning" variant="solid">{t('sup.live.test')}</Badge> : null}
          {run.operationId ? <Badge size="sm" tone="accent" icon="globe">{t('sup.live.operation')}</Badge> : null}
          {run.isBoss ? <Badge size="sm" tone="accent" icon="star">{t('sup.missions.boss')}</Badge> : null}
        </span>
      }
      subtitle={`${typeLabel(session, run.missionType)} · ${asArray(run.departments).join(' + ')}`}
      actions={<TierBadge tier={run.tier} size="sm" />}
    >
      <div className="oversight-live-card__facts">
        <div className="oversight-live-fact">
          <span className="oversight-live-fact__label">{t('sup.live.state')}</span>
          <Badge size="sm" tone={inProgress ? 'success' : 'primary'} dot>{t(`sup.live.state.${inProgress ? 'in_progress' : 'accepted'}`)}</Badge>
        </div>
        <div className="oversight-live-fact">
          <span className="oversight-live-fact__label">{t('sup.live.time_left')}</span>
          {inProgress && run.remaining !== null && run.remaining !== undefined ? (
            <span className="oversight-live-fact__value">
              <Icon name="clock" size={14} />
              <Countdown seconds={run.remaining} resetKey={fetchKey} warnBelow={120} dangerBelow={30} />
            </span>
          ) : (
            <span className="oversight-live-fact__value oversight-live-muted">{t('sup.live.not_started')}</span>
          )}
        </div>
        <div className="oversight-live-fact">
          <span className="oversight-live-fact__label">{t('sup.live.accepted')}</span>
          <span className="oversight-live-fact__value cp-num">{run.acceptedAt ? formatDateTime(run.acceptedAt) : '—'}</span>
        </div>
        <div className="oversight-live-fact">
          <span className="oversight-live-fact__label">{t('sup.live.participants')}</span>
          <span className="oversight-live-fact__value cp-num">{t('sup.live.active_of', { active, total: participants.length })}</span>
        </div>
      </div>
      <ul className="oversight-live-people">
        {participants.map((p) => {
          const left = p.status !== 'active';
          return (
            <li key={p.src} className={left ? 'oversight-live-person is-left' : 'oversight-live-person'}>
              <span className="oversight-live-person__avatar" aria-hidden><Icon name="user" size={14} /></span>
              <span className="oversight-live-person__who">
                <span className="oversight-live-person__name">{p.name}</span>
                <span className="oversight-live-person__sub">{p.callsign || t('common.no_callsign')}</span>
              </span>
              <Badge size="sm" variant="outline">{p.departmentShort}</Badge>
              <span className="oversight-live-person__status">
                {left ? (
                  <Badge size="sm" tone="grey">{t('sup.live.status.left')}</Badge>
                ) : p.arrived ? (
                  <Badge size="sm" tone="success">{t('sup.live.arrived')}</Badge>
                ) : (
                  <Badge size="sm" tone="primary" icon="navigation">{t('sup.live.en_route')}</Badge>
                )}
              </span>
              {canRecall && !left ? (
                <Button size="sm" variant="ghost" icon="logout" className="oversight-live-recall" onClick={() => onRecall(p)}>
                  {t('sup.live.recall')}
                </Button>
              ) : (
                <span className="oversight-live-recall-placeholder" />
              )}
            </li>
          );
        })}
      </ul>
    </Card>
  );
}

export default function SupLiveMissions() {
  const session = useSession();
  const can = useCan();
  const { data, loading, error, refetch } = useRequest<LiveRunsData>('sup:getLiveRuns', {}, { pollMs: 10000, pushTopic: 'operation' });
  const { run, busy } = useAction();
  const [target, setTarget] = useState<RecallTarget | null>(null);
  const [fetchKey, setFetchKey] = useState(0);

  const runs = asArray(data?.runs);
  const canRecall = !!data?.canRecall && can('forceRecall');
  const isAdminView = !session.officer;

  // Every answer (poll, push or refresh) re-syncs the local countdowns, also when `remaining` did not
  // change (a paused test timer), so a countdown never runs ahead of the server.
  useEffect(() => {
    if (data) setFetchKey((k) => k + 1);
  }, [data]);

  const reload = async () => {
    await refetch();
  };

  const confirmRecall = async (reason: string) => {
    if (!target) return;
    const res = await run('server:sup:forceRecall', { runId: target.run.runId, src: target.p.src, reason: reason || undefined }, { success: 'sup.live.recalled', successVars: { name: target.p.name } });
    setTarget(null);
    if (res.ok) void reload();
  };

  let body;
  if (loading && !data) body = <LoadingBlock />;
  else if (error && !data) body = <Card><ErrorState error={error} onRetry={() => void reload()} /></Card>;
  else if (!runs.length)
    body = (
      <Card padding="none">
        <EmptyState icon="activity" title={t('sup.live.empty_title')} text={t('sup.live.empty_text')} />
      </Card>
    );
  else
    body = (
      <div className="oversight-live-list">
        {runs.map((r) => (
          <RunCard key={r.runId} run={r} canRecall={canRecall} fetchKey={fetchKey} onRecall={(p) => setTarget({ run: r, p })} />
        ))}
      </div>
    );

  return (
    <Screen
      title={t('ui.screen.sup_live')}
      subtitle={isAdminView ? t('sup.live.subtitle_all') : t('sup.live.subtitle', { department: session.officer?.departmentShort ?? '' })}
      actions={
        <Row gap={2}>
          {runs.length ? <Badge tone="success" dot>{t('sup.live.count', { n: runs.length })}</Badge> : null}
          <IconButton icon="refresh" label={t('sup.refresh')} variant="secondary" loading={loading && !!data} onClick={() => void reload()} />
        </Row>
      }
      className="oversight-screen"
    >
      {body}
      <ConfirmDialog
        open={!!target}
        tone="danger"
        title={target ? t('sup.live.recall_title', { name: target.p.name }) : ''}
        message={target ? t('sup.live.recall_message', { mission: target.run.missionLabel }) : null}
        confirmLabel={t('sup.live.recall')}
        reason={{ required: false, label: t('common.reason'), placeholder: t('sup.live.recall_placeholder'), maxLength: 255 }}
        onConfirm={confirmRecall}
        onCancel={() => setTarget(null)}
        busy={busy}
      />
    </Screen>
  );
}
