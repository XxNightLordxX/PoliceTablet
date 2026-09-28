// Admin UI · Testing (screen key 'admin_testing'). SPEC "Admin test mode".
//
// Data: request 'admin:getTests' (TestsView: every mission × location with its last result),
//       request 'test:state' (TestState: my invitation lobby, my running test, ended tests waiting for a
//       result, invitations waiting for me), request 'test:candidates' (on-duty officers and admins).
// Actions: server:test:invite { missionId, targets } · server:test:cancelInvites · server:testRespond
//       { inviteId, accepted } · server:admin:startTest { missionId, location, tier, useStartRoute, testers }
//       · server:admin:recordTest { missionId, location, tier, result, note }.
// Client actions (Lua testing client): testControl { control } · teleport { target } · toggleDebug { enabled }.
// Pushes: 'test' { state: true } and 'invites' refetch the state (debug pushes from the Lua client are ignored).
// Flow: invite first, then Start — the start dialog invites testers, shows who accepted, and starts with them.
import { useEffect, useMemo, useState } from 'react';
import {
  Badge, Button, Card, Checkbox, ConfirmDialog, Countdown, Dialog, EmptyState, ErrorState, Field, Icon, IconButton,
  LoadingBlock, Screen, SearchInput, SegmentedControl, Select, Spinner, Stat, Textarea, TierBadge, Toggle,
} from '../../shared/components';
import type { BadgeTone, IconName } from '../../shared/components';
import { cx } from '../../shared/cx';
import { formatDateTime } from '../../shared/format';
import { useAction, usePush, useRequest } from '../../shared/hooks';
import { t, tOr } from '../../shared/i18n';
import { clientAction } from '../../shared/nui';
import { toast } from '../../shared/toast';
import {
  asList, orNull,
  type TestActive, type TestCandidate, type TestInvite, type TestInviteResult, type TestLobby, type TestLocationRow,
  type TestLocationStatus, type TestMissionRow, type TestPendingRecord, type TestPush, type TestRecordResult,
  type TestResult, type TestStartResult, type TestState, type TestsView,
} from '../../types/testing';
import './Testing.css';

// ── helpers ───────────────────────────────────────────────────────────────────

const STATUS_TONE: Record<TestLocationStatus, BadgeTone> = { passed: 'success', failed: 'danger', untested: 'neutral', changed: 'warning' };
const STATUS_ICON: Record<TestLocationStatus, IconName> = { passed: 'checkCircle', failed: 'xCircle', untested: 'minusCircle', changed: 'refresh' };

type StatusFilter = 'all' | 'todo' | 'failed' | 'passed';

function timeAgo(ts: number, now: number): string {
  const s = Math.max(0, Math.floor(now - ts));
  if (s < 60) return t('test.ui.ago_now');
  if (s < 3600) return t('test.ui.ago_min', { n: Math.floor(s / 60) });
  if (s < 86400) return t('test.ui.ago_hour', { n: Math.floor(s / 3600) });
  return t('test.ui.ago_day', { n: Math.floor(s / 86400) });
}

function StatusBadge({ status, size = 'sm' }: { status: TestLocationStatus; size?: 'sm' | 'md' }) {
  return (
    <Badge tone={STATUS_TONE[status]} size={size} icon={STATUS_ICON[status]}>
      {t(`test.ui.status.${status}`)}
    </Badge>
  );
}

function sameLocation(p: TestPendingRecord, missionId: string, index: number) {
  return p.missionId === missionId && p.locationIndex === index;
}

function endKey(p: TestPendingRecord): string {
  if (p.endedBy === 'end') return 'test.ui.ended.by_you';
  if (p.endedBy === 'admin_left') return 'test.ui.ended.admin_left';
  if (p.endedBy === 'fail') return 'test.ui.ended.forced_fail';
  return tOr(`test.ui.ended.${p.endState}`, 'test.ui.ended.abandoned');
}

interface StartPreset { missionId: string; location: number | 'random' }

// ── invitations waiting for me ────────────────────────────────────────────────

function InviteBanner({ invites, onChanged }: { invites: TestInvite[]; onChanged: () => void }) {
  const { run } = useAction();
  const [busyId, setBusyId] = useState<string | null>(null);
  if (!invites.length) return null;
  const respond = async (inv: TestInvite, accepted: boolean) => {
    setBusyId(inv.inviteId);
    await run('server:testRespond', { inviteId: inv.inviteId, accepted }, { success: accepted ? 'test.ui.invite_accepted' : 'test.ui.invite_declined' });
    setBusyId(null);
    onChanged();
  };
  return (
    <div className="testing-invites" role="region" aria-label={t('test.ui.invites_title')}>
      {invites.map((inv) => (
        <div key={inv.inviteId} className="testing-invite">
          <span className="testing-invite__icon" aria-hidden>
            <Icon name="flask" size={18} />
          </span>
          <div className="testing-invite__text">
            <strong>{t('test.ui.invite_line', { from: inv.from, mission: inv.missionLabel })}</strong>
            <span className="testing-invite__meta">
              {t('test.ui.invite_expires')} <Countdown seconds={inv.expiresIn} warnBelow={30} dangerBelow={10} />
            </span>
          </div>
          <div className="testing-invite__actions">
            <Button size="sm" variant="ghost" disabled={busyId === inv.inviteId} onClick={() => respond(inv, false)}>
              {t('test.ui.decline')}
            </Button>
            <Button size="sm" variant="primary" icon="check" loading={busyId === inv.inviteId} onClick={() => respond(inv, true)}>
              {t('test.ui.accept')}
            </Button>
          </div>
        </div>
      ))}
    </div>
  );
}

// ── my running test ───────────────────────────────────────────────────────────

type ConfirmKind = 'end' | 'fail' | 'complete' | null;

function ActiveTestCard({ active, onChanged }: { active: TestActive; onChanged: () => void }) {
  const [busy, setBusy] = useState<string | null>(null);
  const [confirm, setConfirm] = useState<ConfirmKind>(null);
  const inProgress = active.state === 'in_progress';

  const send = async (key: string, name: string, payload: unknown, successKey?: string) => {
    setBusy(key);
    const res = await clientAction(name, payload);
    setBusy(null);
    if (!res.ok) toast('error', t(res.error || 'err.internal'));
    else if (successKey) toast('success', t(successKey));
    onChanged();
    return res.ok;
  };
  const control = (control: string, successKey?: string) => send(control, 'testControl', { control }, successKey);

  const participants = asList(active.participants);
  const activeCount = participants.filter((p) => p.status === 'active').length;
  const obj = active.objective;

  return (
    <Card
      className="testing-active"
      highlight="warning"
      icon="flask"
      title={
        <span className="testing-active__title">
          {active.missionLabel}
          <Badge tone="warning" size="sm" variant="solid">{t('hud.test_run')}</Badge>
          {active.draft ? <Badge tone="accent" size="sm">{t('test.ui.draft')}</Badge> : null}
        </span>
      }
      subtitle={t('test.ui.active_subtitle', { n: active.locationIndex, location: active.locationLabel })}
      actions={
        <div className="testing-active__head-right">
          <TierBadge tier={active.tier} size="sm" />
          {active.remaining !== false ? (
            <span className={cx('testing-active__timer', active.paused && 'is-paused')}>
              <Icon name={active.paused ? 'pause' : 'clock'} size={13} />
              <Countdown seconds={active.remaining} paused={active.paused} showPaused={false} warnBelow={60} dangerBelow={15} />
            </span>
          ) : null}
        </div>
      }
    >
      <div className="testing-active__grid">
        <div className="testing-active__facts">
          <div className="testing-fact">
            <span className="testing-fact__label">{t('test.ui.state')}</span>
            <span className="testing-fact__value">{t(inProgress ? 'test.ui.state_in_progress' : 'test.ui.state_accepted')}</span>
          </div>
          <div className="testing-fact">
            <span className="testing-fact__label">{t('test.ui.objective')}</span>
            <span className="testing-fact__value">
              {obj ? t('test.ui.objective_value', { index: obj.index, total: obj.total, label: obj.label }) : t('test.ui.objective_none')}
            </span>
          </div>
          <div className="testing-fact">
            <span className="testing-fact__label">{t('test.ui.start_route')}</span>
            <span className="testing-fact__value">{t(active.useStartRoute ? 'test.ui.on' : 'test.ui.off')}</span>
          </div>
          <div className="testing-fact">
            <span className="testing-fact__label">{t('test.ui.testers_n', { n: activeCount })}</span>
            <span className="testing-fact__chips">
              {participants.map((p) => (
                <Badge key={p.src} size="sm" tone={p.status === 'active' ? (p.arrived ? 'success' : 'neutral') : 'grey'} dot title={t(`test.ui.participant.${p.status === 'active' ? (p.arrived ? 'arrived' : 'travelling') : 'left'}`)}>
                  {p.name}
                  {orNull(p.departmentShort) ? <span className="testing-muted"> · {p.departmentShort}</span> : null}
                </Badge>
              ))}
            </span>
          </div>
        </div>

        <div className="testing-active__controls" role="group" aria-label={t('test.ui.controls')}>
          <Button size="sm" icon="chevronRight" disabled={!inProgress} loading={busy === 'skip'} onClick={() => control('skip', 'test.ui.skipped')}>
            {t('test.control.skip')}
          </Button>
          <Button size="sm" icon="refresh" disabled={!inProgress} loading={busy === 'restart'} onClick={() => control('restart', 'test.ui.restarted')}>
            {t('test.control.restart')}
          </Button>
          <Button
            size="sm"
            icon={active.paused ? 'play' : 'pause'}
            disabled={!inProgress || active.remaining === false}
            loading={busy === 'pause' || busy === 'resume'}
            onClick={() => control(active.paused ? 'resume' : 'pause')}
          >
            {t(active.paused ? 'test.control.resume' : 'test.control.pause')}
          </Button>
          {active.debugOverlay ? (
            <Button
              size="sm"
              icon="eye"
              variant={active.debug ? 'primary' : 'secondary'}
              loading={busy === 'debug'}
              onClick={() => send('debug', 'toggleDebug', { enabled: !active.debug })}
              aria-pressed={active.debug}
            >
              {t('test.control.debug')}
            </Button>
          ) : null}
          {active.allowTeleport ? (
            <>
              <Button size="sm" icon="mapPin" loading={busy === 'tp_start'} onClick={() => send('tp_start', 'teleport', { target: 'start' })}>
                {t('test.control.teleport_start')}
              </Button>
              <Button size="sm" icon="target" disabled={!inProgress} loading={busy === 'tp_obj'} onClick={() => send('tp_obj', 'teleport', { target: 'objective' })}>
                {t('test.control.teleport_objective')}
              </Button>
            </>
          ) : null}
          <Button size="sm" icon="checkCircle" loading={busy === 'complete'} onClick={() => setConfirm('complete')}>
            {t('test.control.complete')}
          </Button>
          <Button size="sm" icon="xCircle" loading={busy === 'fail'} onClick={() => setConfirm('fail')}>
            {t('test.control.fail')}
          </Button>
          <Button size="sm" variant="danger" icon="x" loading={busy === 'end'} onClick={() => setConfirm('end')}>
            {t('test.control.end')}
          </Button>
        </div>
      </div>

      <ConfirmDialog
        open={confirm !== null}
        title={t(`test.ui.confirm_${confirm ?? 'end'}_title`)}
        message={t(`test.ui.confirm_${confirm ?? 'end'}_text`, { mission: active.missionLabel })}
        confirmLabel={t(`test.control.${confirm ?? 'end'}`)}
        tone={confirm === 'complete' ? 'primary' : 'danger'}
        onCancel={() => setConfirm(null)}
        onConfirm={async () => {
          const kind = confirm;
          if (!kind) return;
          await control(kind);
          setConfirm(null);
        }}
      />
    </Card>
  );
}

// ── ended tests waiting for a result ──────────────────────────────────────────

function PendingCard({ pending, now, onRecord }: { pending: TestPendingRecord[]; now: number; onRecord: (p: TestPendingRecord) => void }) {
  if (!pending.length) return null;
  return (
    <Card icon="edit" title={t('test.ui.pending_title')} subtitle={t('test.ui.pending_subtitle')} padding="none" highlight="accent">
      <ul className="testing-pending">
        {pending.map((p) => (
          <li key={p.key} className="testing-pending__row">
            <div className="testing-pending__main">
              <span className="testing-pending__mission">
                {p.missionLabel}
                {p.draft ? <Badge tone="accent" size="sm">{t('test.ui.draft')}</Badge> : null}
              </span>
              <span className="testing-pending__meta">
                {t('test.ui.location_short', { n: p.locationIndex, label: p.locationLabel })} · {t('test.ui.testers_count', { n: p.testers })} ·{' '}
                {t(endKey(p))} · {timeAgo(p.endedAt, now)}
              </span>
            </div>
            <TierBadge tier={p.tier} size="sm" />
            <Button size="sm" variant="primary" icon="edit" onClick={() => onRecord(p)}>
              {t('test.ui.record')}
            </Button>
          </li>
        ))}
      </ul>
    </Card>
  );
}

// ── catalog ───────────────────────────────────────────────────────────────────

function matchesFilter(loc: TestLocationRow, filter: StatusFilter): boolean {
  if (filter === 'all') return true;
  if (filter === 'todo') return loc.status === 'untested' || loc.status === 'changed';
  return loc.status === filter;
}

interface CatalogProps {
  view: TestsView;
  pending: TestPendingRecord[];
  canStart: boolean;
  onTest: (preset: StartPreset) => void;
  onRecord: (p: TestPendingRecord) => void;
}

function Catalog({ view, pending, canStart, onTest, onRecord }: CatalogProps) {
  const [search, setSearch] = useState('');
  const [filter, setFilter] = useState<StatusFilter>('all');
  const [type, setType] = useState('');
  const [collapsed, setCollapsed] = useState<Record<string, boolean>>({});
  const missions = asList(view.missions);
  const now = view.serverTime || Math.floor(Date.now() / 1000);

  const types = useMemo(() => {
    const seen = new Map<string, string>();
    missions.forEach((m) => seen.set(m.type, m.typeLabel));
    return [...seen.entries()].map(([value, label]) => ({ value, label }));
  }, [missions]);

  const q = search.trim().toLowerCase();
  const groups = missions
    .filter((m) => (!type || m.type === type) && (!q || m.label.toLowerCase().includes(q) || m.id.toLowerCase().includes(q)))
    .map((m) => ({ m, locs: asList(m.locations).filter((l) => matchesFilter(l, filter)) }))
    .filter((g) => g.locs.length > 0 || (filter === 'all' && asList(g.m.locations).length === 0));

  const todo = view.totals.untested + view.totals.changed;
  const allCollapsed = groups.length > 0 && groups.every((g) => collapsed[g.m.id]);

  return (
    <div className="testing-catalog">
      <div className="testing-toolbar">
        <SearchInput value={search} onChange={setSearch} placeholder={t('test.ui.search')} className="testing-toolbar__search" aria-label={t('test.ui.search')} />
        <SegmentedControl<StatusFilter>
          size="sm"
          value={filter}
          onChange={setFilter}
          aria-label={t('test.ui.filter')}
          items={[
            { key: 'all', label: t('test.ui.filter_all') },
            { key: 'todo', label: t('test.ui.filter_todo'), badge: todo || undefined },
            { key: 'failed', label: t('test.ui.filter_failed'), badge: view.totals.failed || undefined },
            { key: 'passed', label: t('test.ui.filter_passed') },
          ]}
        />
        <Select
          value={type}
          onChange={setType}
          options={[{ value: '', label: t('test.ui.all_types') }, ...types]}
          className="testing-toolbar__type"
          aria-label={t('test.ui.type')}
        />
        <Button
          size="sm"
          variant="ghost"
          icon={allCollapsed ? 'chevronDown' : 'chevronUp'}
          onClick={() => {
            const next: Record<string, boolean> = {};
            if (!allCollapsed) groups.forEach((g) => (next[g.m.id] = true));
            setCollapsed(next);
          }}
        >
          {t(allCollapsed ? 'test.ui.expand_all' : 'test.ui.collapse_all')}
        </Button>
      </div>

      {groups.length === 0 ? (
        <Card padding="none">
          <EmptyState
            icon="search"
            title={t(filter === 'todo' ? 'test.ui.empty_todo_title' : 'test.ui.empty_filter_title')}
            text={t(filter === 'todo' ? 'test.ui.empty_todo_text' : 'test.ui.empty_filter_text')}
          />
        </Card>
      ) : (
        <div className="cp-table-wrap testing-table-wrap">
          <table className="cp-table cp-table--dense testing-table" aria-label={t('test.ui.catalog')}>
            <thead>
              <tr>
                <th>{t('test.ui.col_location')}</th>
                <th>{t('test.ui.col_result')}</th>
                <th>{t('test.ui.col_tier')}</th>
                <th className="testing-num testing-col-testers">{t('test.ui.col_testers')}</th>
                <th>{t('test.ui.col_tester')}</th>
                <th>{t('test.ui.col_when')}</th>
                <th className="testing-col-note">{t('test.ui.col_note')}</th>
                <th className="testing-col-actions" aria-label={t('test.ui.col_actions')} />
              </tr>
            </thead>
            {groups.map(({ m, locs }) => (
              <MissionGroup
                key={m.id}
                m={m}
                locs={locs}
                now={now}
                pending={pending}
                canStart={canStart}
                collapsed={!!collapsed[m.id]}
                onToggle={() => setCollapsed((c) => ({ ...c, [m.id]: !c[m.id] }))}
                onTest={onTest}
                onRecord={onRecord}
              />
            ))}
          </table>
        </div>
      )}
    </div>
  );
}

interface GroupProps {
  m: TestMissionRow;
  locs: TestLocationRow[];
  now: number;
  pending: TestPendingRecord[];
  canStart: boolean;
  collapsed: boolean;
  onToggle: () => void;
  onTest: (preset: StartPreset) => void;
  onRecord: (p: TestPendingRecord) => void;
}

function MissionGroup({ m, locs, now, pending, canStart, collapsed, onToggle, onTest, onRecord }: GroupProps) {
  const s = m.summary ?? { passed: 0, failed: 0, untested: 0, changed: 0 };
  return (
    <tbody className={cx('testing-group', collapsed && 'is-collapsed')}>
      <tr className="testing-group__head">
        <td colSpan={8}>
          <div className="testing-group__row">
            <button type="button" className="testing-group__toggle" onClick={onToggle} aria-expanded={!collapsed}>
              <Icon name={collapsed ? 'chevronRight' : 'chevronDown'} size={15} />
              <span className="testing-group__label">{m.label}</span>
              <span className="testing-group__id">{m.id}</span>
            </button>
            <Badge size="sm" tone="primary">{m.typeLabel}</Badge>
            <Badge size="sm" tone="neutral">
              {m.source === 'custom' ? t('test.ui.custom_v', { v: m.version === false ? '—' : m.version }) : t('test.ui.builtin')}
            </Badge>
            {m.isBoss ? <Badge size="sm" tone="accent" icon="star">{t('test.ui.boss')}</Badge> : null}
            {m.status === 'archived' ? <Badge size="sm" tone="grey" icon="inbox">{t('test.ui.archived')}</Badge> : null}
            {m.disabled ? <Badge size="sm" tone="grey" icon="lock">{t('test.ui.disabled')}</Badge> : null}
            {m.editedInCode ? <Badge size="sm" tone="warning" icon="edit">{t('test.ui.edited_in_code')}</Badge> : null}
            <div className="testing-group__right">
              <span className="testing-group__tier" title={t('test.ui.max_tier_hint')}>
                <span className="testing-group__tier-text">{t('test.ui.max_tier', { n: m.maxOfficers })}</span>
                <TierBadge tier={m.maxTier} size="sm" />
              </span>
              <span className="testing-group__summary cp-num">
                {s.passed ? <span className="is-passed">{t('test.ui.sum_passed', { n: s.passed })}</span> : null}
                {s.failed ? <span className="is-failed">{t('test.ui.sum_failed', { n: s.failed })}</span> : null}
                {s.changed ? <span className="is-changed">{t('test.ui.sum_changed', { n: s.changed })}</span> : null}
                {s.untested ? <span className="is-untested">{t('test.ui.sum_untested', { n: s.untested })}</span> : null}
              </span>
              <Button size="sm" variant="secondary" icon="play" disabled={!canStart} onClick={() => onTest({ missionId: m.id, location: 'random' })}>
                {t('test.ui.test_random')}
              </Button>
            </div>
          </div>
        </td>
      </tr>
      {!collapsed && locs.length === 0 ? (
        <tr>
          <td colSpan={8} className="testing-muted">{t('test.ui.no_locations')}</td>
        </tr>
      ) : null}
      {!collapsed
        ? locs.map((loc) => {
            const last = loc.last || null;
            const record = pending.find((p) => sameLocation(p, m.id, loc.index));
            return (
              <tr key={loc.index} className={cx('testing-loc', `is-${loc.status}`)}>
                <td>
                  <div className="testing-loc__name">
                    <span className="testing-loc__index cp-num">#{loc.index}</span>
                    <span className="testing-loc__label">{loc.label}</span>
                    {loc.active ? <Badge size="sm" tone="warning" dot>{t('test.ui.testing_now')}</Badge> : loc.reserved ? <Badge size="sm" tone="neutral" dot>{t('test.ui.in_use')}</Badge> : null}
                  </div>
                </td>
                <td>
                  <div className="testing-loc__result">
                    {loc.status === 'changed' && last ? (
                      <>
                        <StatusBadge status="changed" />
                        <span className={cx('testing-loc__was', `is-${last.result}`)}>{t('test.ui.was', { result: t(`test.ui.status.${last.result}`) })}</span>
                      </>
                    ) : (
                      <StatusBadge status={loc.status} />
                    )}
                  </div>
                </td>
                <td>{last ? <TierBadge tier={last.tier} size="sm" /> : <span className="testing-muted">—</span>}</td>
                <td className="testing-num testing-col-testers cp-num">{last ? last.testers : <span className="testing-muted">—</span>}</td>
                <td className="testing-ellipsis" title={last ? last.testedBy : undefined}>
                  {last ? last.testedByName : <span className="testing-muted">—</span>}
                </td>
                <td className="testing-nowrap" title={last ? formatDateTime(last.testedAt) : undefined}>
                  {last ? timeAgo(last.testedAt, now) : <span className="testing-muted">—</span>}
                </td>
                <td className="testing-col-note">
                  {last && last.note ? (
                    <span className="testing-note" title={last.note}>
                      {last.note}
                    </span>
                  ) : (
                    <span className="testing-muted">—</span>
                  )}
                </td>
                <td className="testing-col-actions">
                  <div className="testing-loc__actions">
                    {record ? (
                      <Button size="sm" variant="primary" icon="edit" onClick={() => onRecord(record)}>
                        {t('test.ui.record')}
                      </Button>
                    ) : null}
                    <IconButton
                      icon="play"
                      size="sm"
                      variant="secondary"
                      label={t('test.ui.test_location', { n: loc.index })}
                      disabled={!canStart || loc.reserved}
                      onClick={() => onTest({ missionId: m.id, location: loc.index })}
                    />
                  </div>
                </td>
              </tr>
            );
          })
        : null}
    </tbody>
  );
}

// ── start dialog (invite first, then Start) ───────────────────────────────────

interface StartDialogProps {
  open: boolean;
  preset: StartPreset | null;
  view: TestsView;
  lobby: TestLobby | null;
  onClose: () => void;
  onChanged: () => void;
  onStarted: () => void;
}

function StartDialog({ open, preset, view, lobby, onClose, onChanged, onStarted }: StartDialogProps) {
  const missions = asList(view.missions);
  const tiers = asList(view.tiers);
  const [missionId, setMissionId] = useState('');
  const [location, setLocation] = useState<string>('random');
  const [tier, setTier] = useState<string>('auto');
  const [route, setRoute] = useState(view.config.useStartRoute);
  const [selected, setSelected] = useState<Record<number, boolean>>({});
  const { run, busy } = useAction();
  const [starting, setStarting] = useState(false);
  const candidates = useRequest<TestCandidate[]>('test:candidates', {}, { skip: !open, pollMs: open ? 10000 : 0 });

  const mission = missions.find((m) => m.id === missionId) ?? null;

  useEffect(() => {
    if (!open) return;
    const m = missions.find((x) => x.id === preset?.missionId) ?? missions[0];
    setMissionId(m ? m.id : '');
    setLocation(preset && preset.location !== 'random' ? String(preset.location) : 'random');
    setTier(m ? m.maxTier : 'auto');
    setRoute(view.config.useStartRoute);
    setSelected({});
    // Only when the dialog opens or the preset changes.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, preset]);

  const lobbyForThis = lobby && lobby.missionId === missionId ? lobby : null;
  const lobbyOther = lobby && lobby.missionId && lobby.missionId !== missionId && asList(lobby.invites).length > 0 ? lobby : null;
  const invites = lobbyForThis ? asList(lobbyForThis.invites) : [];
  const accepted = invites.filter((i) => i.status === 'accepted');
  const waiting = invites.filter((i) => i.status === 'pending');
  const seats = Math.max(0, view.config.maxTesters - 1);
  const openSeats = Math.max(0, seats - accepted.length - waiting.length);
  const chosen = Object.keys(selected).filter((k) => selected[Number(k)]).map(Number);
  const candidateList = asList(candidates.data);

  const pickMission = (id: string) => {
    setMissionId(id);
    setLocation('random');
    const m = missions.find((x) => x.id === id);
    if (m) setTier(m.maxTier);
    setSelected({});
  };

  const invite = async () => {
    if (!mission || !chosen.length) return;
    const res = await run<TestInviteResult>('server:test:invite', { missionId: mission.id, targets: chosen });
    if (res.ok && res.data) {
      const skipped = asList(res.data.skipped);
      const invited = chosen.length - skipped.length;
      if (invited > 0) toast('success', t('test.ui.invited', { n: invited }));
      skipped.forEach((s) => {
        const who = candidateList.find((c) => c.src === s.src)?.name ?? `#${s.src}`;
        toast('warning', `${who}: ${t(s.error)}`);
      });
      setSelected({});
      onChanged();
      void candidates.refetch();
    }
  };

  const withdraw = async () => {
    await run('server:test:cancelInvites', {}, { success: 'test.ui.withdrawn' });
    onChanged();
    void candidates.refetch();
  };

  const start = async () => {
    if (!mission) return;
    setStarting(true);
    const res = await run<TestStartResult>(
      'server:admin:startTest',
      {
        missionId: mission.id,
        location: location === 'random' ? 'random' : Number(location),
        tier: tier === 'auto' ? undefined : tier,
        useStartRoute: route,
        testers: accepted.map((i) => i.src),
      },
      { success: 'test.ui.started' },
    );
    setStarting(false);
    if (res.ok) onStarted();
  };

  const locationOptions = [
    { value: 'random', label: t('test.ui.location_random') },
    ...asList(mission?.locations).map((l) => ({
      value: String(l.index),
      label: `#${l.index} · ${l.label}${l.reserved ? ` (${t('test.ui.in_use')})` : ''}`,
      disabled: l.reserved,
    })),
  ];
  const tierOptions = [
    { value: 'auto', label: t('test.ui.tier_auto') },
    ...tiers.map((x) => ({ value: x.name, label: `${x.label} · ${t('test.ui.tier_up_to', { n: x.maxParticipants })}` })),
  ];

  return (
    <Dialog
      open={open}
      onClose={onClose}
      size="lg"
      className="testing-start"
      title={t('test.ui.start_title')}
      description={t('test.ui.start_desc')}
      footer={
        <>
          {waiting.length ? <span className="testing-start__footnote">{t('test.ui.waiting_withdrawn', { n: waiting.length })}</span> : null}
          <Button variant="ghost" onClick={onClose} disabled={starting}>
            {t('common.cancel')}
          </Button>
          <Button variant="primary" icon="play" onClick={start} loading={starting} disabled={!mission || !view.config.enabled}>
            {accepted.length ? t('test.ui.start_with', { n: accepted.length }) : t('test.ui.start_solo')}
          </Button>
        </>
      }
    >
      <div className="testing-start__grid">
        <div className="testing-start__col">
          <Field label={t('test.ui.mission')} required>
            <Select
              value={missionId}
              onChange={pickMission}
              options={missions.map((m) => ({
                value: m.id,
                label: `${m.label} · ${m.typeLabel}${m.disabled ? ` · ${t('test.ui.disabled')}` : ''}${m.status === 'archived' ? ` · ${t('test.ui.archived')}` : ''}`,
              }))}
            />
          </Field>
          <Field label={t('test.ui.location')} hint={t('test.ui.location_hint')}>
            <Select value={location} onChange={setLocation} options={locationOptions} />
          </Field>
          <Field
            label={t('test.ui.tier')}
            hint={mission ? t('test.ui.tier_hint', { tier: t(`tier.${mission.maxTier}`), n: mission.maxOfficers }) : undefined}
          >
            <Select value={tier} onChange={setTier} options={tierOptions} />
          </Field>
          <Toggle checked={route} onChange={setRoute} label={t('test.ui.route_label')} description={t(route ? 'test.ui.route_on' : 'test.ui.route_off')} />
          <div className="testing-start__note">
            <Icon name="info" size={14} />
            <span>{t('test.ui.nothing_saved')}</span>
          </div>
        </div>

        <div className="testing-start__col testing-start__testers">
          <div className="testing-start__head">
            <span className="testing-start__label">{t('test.ui.testers_title')}</span>
            <span className="testing-muted cp-num">{t('test.ui.seats', { n: accepted.length + 1, max: view.config.maxTesters })}</span>
            <IconButton icon="refresh" size="sm" label={t('test.ui.refresh')} onClick={() => void candidates.refetch()} loading={candidates.loading && !!candidates.data} />
          </div>

          {lobbyOther ? (
            <div className="testing-start__warn">
              <Icon name="alert" size={14} />
              <span>{t('test.ui.lobby_other', { mission: String(lobbyOther.missionLabel) })}</span>
              <Button size="sm" variant="ghost" onClick={withdraw} disabled={busy}>
                {t('test.ui.withdraw')}
              </Button>
            </div>
          ) : null}

          {invites.length ? (
            <ul className="testing-lobby">
              {invites.map((i) => (
                <li key={i.inviteId} className={cx('testing-lobby__row', `is-${i.status}`)}>
                  <span className="testing-lobby__name">
                    {i.name}
                    {i.callsign ? <span className="testing-muted"> · {i.callsign}</span> : null}
                  </span>
                  {i.departmentShort ? <Badge size="sm">{i.departmentShort}</Badge> : null}
                  <span className="testing-lobby__status">
                    <Badge size="sm" tone={i.status === 'accepted' ? 'success' : i.status === 'pending' ? 'warning' : 'grey'} dot>
                      {t(`test.ui.invite_status.${i.status}`)}
                    </Badge>
                    {i.status === 'pending' ? <Countdown seconds={i.expiresIn} className="testing-muted" /> : null}
                  </span>
                </li>
              ))}
            </ul>
          ) : null}
          {invites.length ? (
            <Button size="sm" variant="ghost" icon="x" onClick={withdraw} disabled={busy} className="testing-start__withdraw">
              {t('test.ui.withdraw_all')}
            </Button>
          ) : null}

          <div className="testing-cands">
            {candidates.loading && !candidates.data ? (
              <div className="testing-cands__state">
                <Spinner size={18} />
                <span>{t('common.loading')}</span>
              </div>
            ) : candidates.error && !candidates.data ? (
              <ErrorState compact error={candidates.error} onRetry={() => void candidates.refetch()} />
            ) : candidateList.length === 0 ? (
              <EmptyState compact icon="users" title={t('test.ui.no_candidates')} text={t('test.ui.no_candidates_text')} />
            ) : (
              candidateList.map((c) => {
                const invited = invites.some((i) => i.src === c.src && (i.status === 'pending' || i.status === 'accepted'));
                const blocked = c.onRun || c.inArena || invited;
                const reason = c.inArena ? 'test.ui.cand_arena' : c.onRun ? 'test.ui.cand_on_run' : invited ? 'test.ui.cand_invited' : null;
                const disabled = blocked || (!selected[c.src] && chosen.length >= openSeats);
                return (
                  <div key={c.src} className={cx('testing-cand', disabled && 'is-disabled')}>
                    <Checkbox
                      checked={!!selected[c.src]}
                      disabled={disabled}
                      onChange={(v) => setSelected((s) => ({ ...s, [c.src]: v }))}
                      label={
                        <span className="testing-cand__label">
                          <span className="testing-cand__name">{c.name}</span>
                          <span className="testing-muted">
                            {[orNull(c.callsign), orNull(c.rank)].filter(Boolean).join(' · ')}
                          </span>
                        </span>
                      }
                    />
                    <span className="testing-cand__tags">
                      {orNull(c.departmentShort) ? <Badge size="sm">{c.departmentShort}</Badge> : null}
                      {c.admin ? <Badge size="sm" tone="primary" icon="key">{t('test.ui.role_admin')}</Badge> : null}
                      {reason ? <span className="testing-cand__reason">{t(reason)}</span> : null}
                    </span>
                  </div>
                );
              })
            )}
          </div>
          <Button size="sm" icon="users" onClick={invite} disabled={!chosen.length || busy || !mission} loading={busy && chosen.length > 0}>
            {chosen.length ? t('test.ui.invite_n', { n: chosen.length }) : t('test.ui.invite')}
          </Button>
        </div>
      </div>
    </Dialog>
  );
}

// ── record dialog ─────────────────────────────────────────────────────────────

function RecordDialog({ entry, onClose, onRecorded }: { entry: TestPendingRecord | null; onClose: () => void; onRecorded: () => void }) {
  const [result, setResult] = useState<TestResult | ''>('');
  const [note, setNote] = useState('');
  const { run, busy } = useAction();
  useEffect(() => {
    if (entry) {
      setResult(entry.endState === 'completed' ? 'passed' : '');
      setNote('');
    }
  }, [entry]);
  const submit = async () => {
    if (!entry || !result) return;
    const res = await run<TestRecordResult>(
      'server:admin:recordTest',
      { missionId: entry.missionId, location: entry.locationIndex, tier: entry.tier, result, note: note.trim() || undefined },
      { success: result === 'passed' ? 'test.ui.recorded_passed' : 'test.ui.recorded_failed' },
    );
    if (res.ok) onRecorded();
  };
  return (
    <Dialog
      open={!!entry}
      onClose={onClose}
      size="md"
      title={t('test.ui.record_title')}
      description={entry ? t('test.ui.record_desc', { mission: entry.missionLabel, n: entry.locationIndex, location: entry.locationLabel }) : undefined}
      footer={
        <>
          <Button variant="ghost" onClick={onClose} disabled={busy}>
            {t('common.cancel')}
          </Button>
          <Button variant="primary" icon="check" onClick={submit} loading={busy} disabled={!result}>
            {t('test.ui.record_save')}
          </Button>
        </>
      }
    >
      {entry ? (
        <div className="testing-record">
          <div className="testing-record__facts">
            <TierBadge tier={entry.tier} size="sm" />
            <Badge size="sm">{t('test.ui.testers_count', { n: entry.testers })}</Badge>
            <Badge size="sm" tone={entry.endState === 'completed' ? 'success' : entry.endState === 'failed' ? 'danger' : 'neutral'}>{t(endKey(entry))}</Badge>
            {entry.draft ? <Badge tone="accent" size="sm">{t('test.ui.draft')}</Badge> : null}
          </div>
          <Field label={t('test.ui.result')} required>
            <div className="testing-record__choices" role="radiogroup" aria-label={t('test.ui.result')}>
              {(['passed', 'failed'] as TestResult[]).map((r) => (
                <button
                  key={r}
                  type="button"
                  role="radio"
                  aria-checked={result === r}
                  className={cx('testing-choice', `is-${r}`, result === r && 'is-on')}
                  onClick={() => setResult(r)}
                >
                  <Icon name={r === 'passed' ? 'checkCircle' : 'xCircle'} size={20} />
                  <span className="testing-choice__title">{t(`test.ui.status.${r}`)}</span>
                  <span className="testing-choice__text">{t(`test.ui.record_${r}_hint`)}</span>
                </button>
              ))}
            </div>
          </Field>
          <Field label={t('test.ui.note')} hint={t('test.ui.note_hint')}>
            <Textarea value={note} onChange={setNote} maxLength={255} rows={3} placeholder={t('test.ui.note_placeholder')} />
          </Field>
          {entry.draft ? (
            <div className="testing-start__note">
              <Icon name="info" size={14} />
              <span>{t('test.ui.record_draft_note')}</span>
            </div>
          ) : null}
        </div>
      ) : null}
    </Dialog>
  );
}

// ── the screen ────────────────────────────────────────────────────────────────

export default function AdminTesting() {
  const [startOpen, setStartOpen] = useState(false);
  const [preset, setPreset] = useState<StartPreset | null>(null);
  const [recording, setRecording] = useState<TestPendingRecord | null>(null);
  const catalog = useRequest<TestsView>('admin:getTests', {});
  const [pollMs, setPollMs] = useState(8000);
  const state = useRequest<TestState>('test:state', {}, { pollMs });

  const st = state.data;
  const active = st && st.active ? st.active : null;
  useEffect(() => setPollMs(active ? 3000 : 8000), [active]);

  const refreshAll = () => {
    void state.refetch();
    void catalog.refetch();
  };
  usePush<TestPush | null>('test', (d) => {
    if (d && d.state) refreshAll();
  });
  usePush('invites', () => void state.refetch());

  const view = catalog.data;
  const pending = st ? asList(st.pending) : [];
  const invites = st ? asList(st.invites) : [];
  const lobby = st ? st.lobby : null;
  const enabled = view ? view.config.enabled : true;
  const canStart = enabled && !active;
  const now = view?.serverTime || Math.floor(Date.now() / 1000);

  const openStart = (p: StartPreset | null) => {
    if (active) {
      toast('warning', t('err.test_already_running'));
      return;
    }
    setPreset(p);
    setStartOpen(true);
  };

  const totals = view?.totals;
  const tested = totals ? totals.passed + totals.failed : 0;

  return (
    <Screen
      className="testing-screen"
      title={t('ui.screen.admin_testing')}
      subtitle={t('test.ui.subtitle')}
      actions={
        <>
          <IconButton icon="refresh" label={t('test.ui.refresh')} onClick={refreshAll} loading={catalog.loading && !!catalog.data} />
          <Button variant="primary" icon="play" onClick={() => openStart(null)} disabled={!view || !canStart}>
            {t('test.ui.start_test')}
          </Button>
        </>
      }
    >
          <InviteBanner invites={invites} onChanged={() => void state.refetch()} />

          {!enabled ? (
            <Card highlight="warning" muted>
              <div className="testing-disabled">
                <Icon name="lock" size={18} />
                <span>{t('test.ui.disabled_config')}</span>
              </div>
            </Card>
          ) : null}

          {active ? <ActiveTestCard active={active} onChanged={() => void state.refetch()} /> : null}

          <PendingCard pending={pending} now={now} onRecord={setRecording} />

          {catalog.loading && !view ? (
            <Card>
              <LoadingBlock text={t('test.ui.loading')} />
            </Card>
          ) : catalog.error && !view ? (
            <Card>
              <ErrorState error={catalog.error} onRetry={() => void catalog.refetch()} />
            </Card>
          ) : view ? (
            <>
              <div className="testing-stats">
                <Card padding="sm">
                  <Stat size="sm" icon="layers" label={t('test.ui.stat_missions')} value={totals?.missions ?? 0} hint={t('test.ui.stat_locations', { n: totals?.locations ?? 0 })} />
                </Card>
                <Card padding="sm">
                  <Stat size="sm" icon="checkCircle" tone={totals?.passed ? 'success' : 'neutral'} label={t('test.ui.stat_passed')} value={totals?.passed ?? 0} hint={t('test.ui.stat_tested', { n: tested })} />
                </Card>
                <Card padding="sm">
                  <Stat size="sm" icon="xCircle" tone={totals?.failed ? 'danger' : 'neutral'} label={t('test.ui.stat_failed')} value={totals?.failed ?? 0} />
                </Card>
                <Card padding="sm">
                  <Stat size="sm" icon="refresh" tone={totals?.changed ? 'warning' : 'neutral'} label={t('test.ui.stat_changed')} value={totals?.changed ?? 0} />
                </Card>
                <Card padding="sm">
                  <Stat size="sm" icon="minusCircle" label={t('test.ui.stat_untested')} value={totals?.untested ?? 0} />
                </Card>
              </div>
              {asList(view.missions).length === 0 ? (
                <Card padding="none">
                  <EmptyState icon="layers" title={t('test.ui.empty_title')} text={t('test.ui.empty_text')} />
                </Card>
              ) : (
                <Catalog view={view} pending={pending} canStart={canStart} onTest={openStart} onRecord={setRecording} />
              )}
            </>
          ) : null}

      {view ? (
        <StartDialog
          open={startOpen}
          preset={preset}
          view={view}
          lobby={lobby}
          onClose={() => setStartOpen(false)}
          onChanged={() => void state.refetch()}
          onStarted={() => {
            setStartOpen(false);
            refreshAll();
          }}
        />
      ) : null}
      <RecordDialog
        entry={recording}
        onClose={() => setRecording(null)}
        onRecorded={() => {
          setRecording(null);
          refreshAll();
        }}
      />
    </Screen>
  );
}
