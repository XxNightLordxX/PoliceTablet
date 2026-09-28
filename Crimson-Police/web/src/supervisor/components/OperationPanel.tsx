// Supervisor/Admin UI · OperationPanel: the active Cross-Department Mission and its controls.
//
//   import OperationPanel from '../../supervisor/components/OperationPanel';
//   <OperationPanel scope="admin" />      // Admin UI → Missions
//   <OperationPanel scope="sup" />        // Supervisor UI → Cross-Department Mission
//
// Props (stable): { scope: 'sup' | 'admin' } picks the action family server:<scope>:opLaunch / opStart /
// opRelaunch / opCancel. Data: callback sup:getOperation (OperationView, src/types/teams.ts), refreshed by
// the push topic 'operation' and every 10 s. Shows the mission, launcher, status, tier, join / run / idle
// timers, participants by department, and Start now / Relaunch (after a fail) / Cancel (reason required).
// With no operation active it offers a launch form (missions open to every department that support 2+
// officers; never the Weekly Boss) with the server-wide launch cooldown.
import { useEffect, useMemo, useState } from 'react';
import {
  Badge, Button, Card, ConfirmDialog, Countdown, EmptyState, ErrorState, Field, Grid, Icon, KeyValue, LoadingBlock, Select, Stat, TierBadge,
  type BadgeTone,
} from '../../shared/components';
import { formatDateTime, formatMultiplier } from '../../shared/format';
import { useAction, useRequest } from '../../shared/hooks';
import { t, tOr } from '../../shared/i18n';
import { cx } from '../../shared/cx';
import type { EligibleMission, OperationInfo, OperationParticipant, OperationScope, OperationView } from '../../types/teams';
import './OperationPanel.css';

export interface OperationPanelProps {
  scope: OperationScope;
}

const minutes = (seconds: number) => Math.max(1, Math.round((Number(seconds) || 0) / 60));

const STATUS_TONE: Record<string, BadgeTone> = { joining: 'accent', running: 'primary', waiting: 'warning' };
const STATUS_HIGHLIGHT: Record<string, 'accent' | 'primary' | 'warning'> = { joining: 'accent', running: 'primary', waiting: 'warning' };

function Stars({ n }: { n: number }) {
  const count = Math.max(1, Math.min(5, Math.round(Number(n) || 1)));
  return (
    <span className="teams-op-stars" title={t('sup.crossdept.difficulty', { n: count })} aria-label={t('sup.crossdept.difficulty', { n: count })}>
      {Array.from({ length: count }, (_, i) => <Icon key={i} name="star" size={12} strokeWidth={2.4} />)}
    </span>
  );
}

function participantBadge(p: OperationParticipant) {
  if (p.status === 'left') return <Badge size="sm" tone="grey">{t('sup.crossdept.p_left')}</Badge>;
  if (p.status === 'active') {
    return p.arrived ? (
      <Badge size="sm" tone="success" icon="mapPin">{t('sup.crossdept.p_arrived')}</Badge>
    ) : (
      <Badge size="sm" tone="primary" icon="navigation">{t('sup.crossdept.p_en_route')}</Badge>
    );
  }
  if (p.status === 'waiting') return <Badge size="sm" tone="neutral">{t('sup.crossdept.p_last_attempt')}</Badge>;
  return <Badge size="sm" tone="accent" icon="check">{t('sup.crossdept.p_joined')}</Badge>;
}

// ── participants by department ────────────────────────────────────────────────

function Participants({ op }: { op: OperationInfo }) {
  const groups = useMemo(() => {
    const map = new Map<string, OperationParticipant[]>();
    for (const p of op.participants) {
      const k = p.departmentShort || '?';
      if (!map.has(k)) map.set(k, []);
      map.get(k)!.push(p);
    }
    return [...map.entries()].sort((a, b) => a[0].localeCompare(b[0]));
  }, [op.participants]);

  return (
    <Card
      icon="users"
      title={t('sup.crossdept.participants_title')}
      subtitle={t('sup.crossdept.participants_subtitle', { joined: op.joined, max: op.max, min: op.min })}
      actions={
        op.departments.length ? (
          <span className="teams-op-deptline">
            {op.departments.map((d) => (
              <Badge key={d.short} size="sm" variant="outline">
                {d.short} <span className="cp-num">{d.count}</span>
              </Badge>
            ))}
          </span>
        ) : null
      }
      padding="sm"
    >
      {groups.length === 0 ? (
        <EmptyState compact icon="users" title={t('sup.crossdept.nobody_yet')} text={t('sup.crossdept.nobody_yet_text')} />
      ) : (
        <div className="teams-op-depts">
          {groups.map(([short, list]) => {
            const inCount = list.filter((p) => p.status !== 'left').length;
            return (
              <section key={short} className="teams-op-dept">
                <header className="teams-op-dept__head">
                  <span className="teams-op-dept__tag">{short}</span>
                  <span className="teams-op-dept__count cp-num">{inCount}</span>
                </header>
                <ul className="teams-op-dept__list">
                  {list.map((p) => (
                    <li key={p.src} className={cx('teams-op-person', p.status === 'left' && 'is-left')}>
                      <div className="teams-op-person__main">
                        <span className="teams-op-person__name">{p.name}</span>
                        <span className="teams-op-person__sub">{p.callsign || t('common.no_callsign')}</span>
                      </div>
                      {participantBadge(p)}
                    </li>
                  ))}
                </ul>
              </section>
            );
          })}
        </div>
      )}
    </Card>
  );
}

// ── the active operation ──────────────────────────────────────────────────────

function ActiveOperation({ op, view, stamp, scope, onDone }: { op: OperationInfo; view: OperationView; stamp: unknown; scope: OperationScope; onDone: () => void }) {
  const { run } = useAction();
  const [dialog, setDialog] = useState<null | 'start' | 'relaunch' | 'cancel'>(null);

  const call = async (name: string, payload?: unknown, success?: string) => {
    const res = await run(name, payload, { success, successVars: { mission: op.missionLabel } });
    setDialog(null);
    onDone();
    return res;
  };

  const launcherLine = [op.launcher, op.launcherCallsign || null, op.launcherDepartment || null].filter(Boolean).join(' · ');
  const joining = op.status === 'joining';
  const waiting = op.status === 'waiting';
  const running = op.status === 'running';

  const leftCount = op.participants.filter((p) => p.status === 'left').length;
  const participantsHint = running
    ? leftCount > 0 ? t('sup.crossdept.left_count', { n: leftCount }) : t('sup.crossdept.joining_closed')
    : t('sup.crossdept.min_needed', { min: op.min });

  let timer = null;
  if (joining) {
    timer = <Stat icon="clock" label={t('sup.crossdept.join_closes')} value={<Countdown seconds={op.joinEndsIn ?? null} resetKey={stamp} warnBelow={60} dangerBelow={15} />} hint={t('sup.crossdept.join_closes_hint')} />;
  } else if (running) {
    timer = op.runState === 'in_progress'
      ? <Stat icon="clock" label={t('sup.crossdept.time_left')} value={<Countdown seconds={op.remaining ?? null} resetKey={stamp} warnBelow={120} dangerBelow={30} />} hint={t('sup.crossdept.run_in_progress')} />
      : <Stat icon="navigation" label={t('sup.crossdept.run_state')} value={t('sup.crossdept.run_accepted')} hint={t('sup.crossdept.run_accepted_hint')} />;
  } else if (waiting) {
    timer = <Stat icon="clock" tone="warning" label={t('sup.crossdept.auto_cancel')} value={<Countdown seconds={op.idleCancelIn ?? null} resetKey={stamp} warnBelow={300} dangerBelow={60} />} hint={t('sup.crossdept.auto_cancel_hint')} />;
  }

  return (
    <>
      <Card highlight={STATUS_HIGHLIGHT[op.status] ?? 'primary'} padding="lg" className="teams-op-hero">
        <div className="teams-op-hero__top">
          <div className="teams-op-hero__titles">
            <div className="teams-op-eyebrow">
              <Icon name="globe" size={14} />
              <span>{t('sup.crossdept.eyebrow', { id: op.id })}</span>
              {op.attempt > 1 ? <span className="teams-op-eyebrow__dim">· {t('sup.crossdept.attempt', { n: op.attempt })}</span> : null}
            </div>
            <h3 className="teams-op-title">{op.missionLabel}</h3>
            <div className="teams-op-meta">
              <Badge size="sm" variant="outline">{op.missionTypeLabel}</Badge>
              <Stars n={op.difficulty} />
              <span className="teams-op-meta__launcher">
                <Icon name="user" size={13} />
                {t('sup.crossdept.launched_by', { name: launcherLine })}
                <span className="teams-op-meta__time">· {formatDateTime(op.launchedAt)}</span>
              </span>
            </div>
          </div>
          <Badge tone={STATUS_TONE[op.status] ?? 'neutral'} variant="solid" dot={joining || running}>
            {tOr(`sup.crossdept.status_${op.status}`, 'common.unknown')}
          </Badge>
        </div>

        <Grid cols={4} gap={3} className="teams-op-stats">
          <Stat
            icon="users"
            label={t('sup.crossdept.participants')}
            value={<span><span className="cp-num">{op.joined}</span><span className="teams-op-stats__of cp-num"> / {op.max}</span></span>}
            hint={participantsHint}
          />
          <div className="cp-stat">
            <div className="cp-stat__label">
              <Icon name="layers" size={14} />
              <span>{t('common.tier')}</span>
            </div>
            <div className="teams-op-tier"><TierBadge tier={op.tier} expected={op.tierExpected} /></div>
            <div className="cp-stat__hint">{op.tierExpected ? t('sup.crossdept.tier_expected_hint') : t('sup.crossdept.tier_set_hint')}</div>
          </div>
          {timer ?? <span />}
          <Stat icon="building" label={t('sup.crossdept.departments')} value={<span className="cp-num">{op.departments.length}</span>} hint={op.departments.length >= 2 ? t('sup.crossdept.cross_bonus', { m: formatMultiplier(view.crossBonus ?? 1.1) }) : t('sup.crossdept.cross_bonus_needs')} />
        </Grid>

        {waiting ? (
          <div className="teams-op-notice" role="status">
            <Icon name="alert" size={18} />
            <div>
              <div className="teams-op-notice__title">{tOr(`sup.crossdept.waiting_${op.waitingReason ?? 'failed'}`, 'sup.crossdept.waiting_failed')}</div>
              <div className="teams-op-notice__text">{t('sup.crossdept.waiting_text')}</div>
            </div>
          </div>
        ) : null}

        <div className="teams-op-controls">
          {joining ? (
            <div className="teams-op-controls__group">
              <Button variant="primary" icon="play" disabled={!op.canStart} onClick={() => setDialog('start')}>
                {t('sup.crossdept.start_now')}
              </Button>
              {!op.canStart && op.startBlocked ? <span className="teams-op-controls__hint">{t(op.startBlocked, { min: op.min })}</span> : null}
            </div>
          ) : null}
          {waiting ? (
            <div className="teams-op-controls__group">
              <Button variant="primary" icon="refresh" disabled={!op.canRelaunch} onClick={() => setDialog('relaunch')}>
                {t('sup.crossdept.relaunch')}
              </Button>
            </div>
          ) : null}
          {running ? (
            <span className="teams-op-controls__hint">
              <Icon name="lock" size={13} /> {t('sup.crossdept.running_hint')}
            </span>
          ) : null}
          <span className="cp-spacer" />
          <Button variant="danger" icon="x" disabled={!op.canCancel} onClick={() => setDialog('cancel')}>
            {t('sup.crossdept.cancel')}
          </Button>
        </div>
      </Card>

      <Participants op={op} />

      <ConfirmDialog
        open={dialog === 'start'}
        title={t('sup.crossdept.start_title')}
        message={t('sup.crossdept.start_confirm', { mission: op.missionLabel, n: op.joined })}
        confirmLabel={t('sup.crossdept.start_now')}
        onConfirm={() => call(`server:${scope}:opStart`, undefined, 'sup.crossdept.started_toast')}
        onCancel={() => setDialog(null)}
      />
      <ConfirmDialog
        open={dialog === 'relaunch'}
        title={t('sup.crossdept.relaunch_title')}
        message={t('sup.crossdept.relaunch_confirm', { mission: op.missionLabel, minutes: minutes(view.joinWindow ?? 300) })}
        confirmLabel={t('sup.crossdept.relaunch')}
        onConfirm={() => call(`server:${scope}:opRelaunch`, undefined, 'sup.crossdept.relaunched_toast')}
        onCancel={() => setDialog(null)}
      />
      <ConfirmDialog
        open={dialog === 'cancel'}
        tone="danger"
        title={t('sup.crossdept.cancel_title')}
        message={running ? t('sup.crossdept.cancel_confirm_running', { mission: op.missionLabel }) : t('sup.crossdept.cancel_confirm', { mission: op.missionLabel })}
        confirmLabel={t('sup.crossdept.cancel')}
        cancelLabel={t('sup.crossdept.keep')}
        reason={{ label: t('common.reason'), placeholder: t('sup.crossdept.cancel_reason_placeholder'), required: true, maxLength: 200 }}
        onConfirm={(reason) => call(`server:${scope}:opCancel`, { reason }, 'sup.crossdept.cancelled_toast')}
        onCancel={() => setDialog(null)}
      />
    </>
  );
}

// ── launch (no operation active) ──────────────────────────────────────────────

function LaunchForm({ view, stamp, scope, onDone }: { view: OperationView; stamp: unknown; scope: OperationScope; onDone: () => void }) {
  const { run } = useAction();
  const missions = view.eligibleMissions ?? [];
  const [missionId, setMissionId] = useState<string>('');
  const [confirm, setConfirm] = useState(false);

  useEffect(() => {
    if (!missions.some((m) => m.id === missionId)) setMissionId(missions[0]?.id ?? '');
  }, [missions, missionId]);

  const selected: EligibleMission | undefined = missions.find((m) => m.id === missionId);
  const cooling = view.cooldownLeft > 0;
  const blocked = !view.canLaunch || !selected;

  const launch = async () => {
    const res = await run(`server:${scope}:opLaunch`, { missionId }, { success: 'sup.crossdept.launched_toast', successVars: { mission: selected?.label ?? missionId } });
    setConfirm(false);
    onDone();
    return res;
  };

  return (
    <Card padding="lg" className="teams-op-launch">
      <div className="teams-op-launch__intro">
        <span className="teams-op-launch__icon"><Icon name="globe" size={24} /></span>
        <div>
          <h3 className="teams-op-launch__title">{t('sup.crossdept.none_title')}</h3>
          <p className="teams-op-launch__text">{t('sup.crossdept.none_text', { max: view.maxParticipants ?? 8 })}</p>
        </div>
      </div>

      {!view.enabled ? (
        <EmptyState compact icon="lock" title={t('err.op_disabled')} />
      ) : missions.length === 0 ? (
        <EmptyState compact icon="layers" title={t('sup.crossdept.no_eligible')} text={t('sup.crossdept.no_eligible_text')} />
      ) : (
        <div className="teams-op-launch__form">
          <Field label={t('sup.crossdept.mission')} hint={t('sup.crossdept.mission_hint')}>
            <Select
              value={missionId}
              onChange={setMissionId}
              options={missions.map((m) => ({ value: m.id, label: `${m.label} · ${m.typeLabel}` }))}
            />
          </Field>
          {selected ? (
            <div className="teams-op-launch__details">
              <KeyValue label={t('sup.crossdept.type')}>{selected.typeLabel}</KeyValue>
              <KeyValue label={t('sup.crossdept.difficulty_label')}><Stars n={selected.difficulty} /></KeyValue>
              <KeyValue label={t('sup.crossdept.participants')}>
                <span className="cp-num">{t('sup.crossdept.range', { min: selected.minOfficers, max: selected.maxOfficers })}</span>
              </KeyValue>
              <KeyValue label={t('sup.crossdept.join_window')}>{t('sup.crossdept.join_window_value', { minutes: minutes(view.joinWindow ?? 300) })}</KeyValue>
            </div>
          ) : null}
          <div className="teams-op-launch__actions">
            {cooling ? (
              <span className="teams-op-cooldown">
                <Icon name="clock" size={14} />
                {t('sup.crossdept.cooldown')}
                <Countdown seconds={view.cooldownLeft} resetKey={stamp} onDone={onDone} />
              </span>
            ) : view.launchBlocked ? (
              <span className="teams-op-cooldown">{t(view.launchBlocked)}</span>
            ) : (
              <span className="teams-op-cooldown teams-op-cooldown--ok">
                <Icon name="checkCircle" size={14} />
                {t('sup.crossdept.ready_to_launch')}
              </span>
            )}
            <span className="cp-spacer" />
            <Button variant="primary" icon="zap" disabled={blocked} onClick={() => setConfirm(true)}>
              {t('sup.crossdept.launch')}
            </Button>
          </div>
        </div>
      )}

      <ConfirmDialog
        open={confirm}
        title={t('sup.crossdept.launch_title')}
        message={t('sup.crossdept.launch_confirm', { mission: selected?.label ?? '', minutes: minutes(view.cooldown) })}
        confirmLabel={t('sup.crossdept.launch')}
        onConfirm={() => launch()}
        onCancel={() => setConfirm(false)}
      />
    </Card>
  );
}

// ── panel ─────────────────────────────────────────────────────────────────────

export default function OperationPanel({ scope }: OperationPanelProps) {
  const { data, loading, error, refetch } = useRequest<OperationView>('sup:getOperation', {}, { pushTopic: 'operation', pollMs: 10000 });
  const refresh = () => void refetch();

  if (!data && loading) return <LoadingBlock />;
  if (!data) return <ErrorState error={error} onRetry={refresh} />;

  return (
    <div className="teams-op">
      {data.operation ? (
        <ActiveOperation op={data.operation} view={data} stamp={data} scope={scope} onDone={refresh} />
      ) : (
        <LaunchForm view={data} stamp={data} scope={scope} onDone={refresh} />
      )}
    </div>
  );
}
