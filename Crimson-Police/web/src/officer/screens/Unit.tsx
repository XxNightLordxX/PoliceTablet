// Officer UI · Unit (screen key 'unit', title key 'ui.screen.unit').
// The officer's unit (members with department tag, rank and callsign, the leader marked), invites
// waiting for them (Accept / Decline), an invite picker of on-duty officers from any department, and
// Leave unit (confirm; mid-run it abandons the unit's run). Data: callback getUnit (UnitView + slice
// fields, src/types/teams.ts), live via push topic 'unit'. Actions: server:unitInvite (targetSrc),
// server:unitRespond ({ accepted, unitId }), server:unitLeave. Test invitations (callback test:pendingInvites,
// push 'invites') are answered here too with server:testRespond. Invites close (locked) once the leader
// accepts a mission type and stay closed while the unit's run is active.
import { useMemo, useState } from 'react';
import {
  Badge, Button, Card, ConfirmDialog, Countdown, EmptyState, ErrorState, Grid, Icon, LoadingBlock, Screen, SearchInput, Stack,
} from '../../shared/components';
import { asArray } from '../../shared/data';
import { useAction, useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { useNavigate } from '../../shared/navigation';
import { useSession } from '../../shared/session';
import { cx } from '../../shared/cx';
import type { UnitInvitableView, UnitInviteView, UnitLeaveResult, UnitMemberView, UnitPendingInvite, UnitScreenView } from '../../types/teams';
import { asList, type TestInvite } from '../../types/testing';
import './Unit.css';

const DEFAULT_MAX = 4;

function initials(name: string): string {
  const parts = String(name || '?').trim().split(/\s+/).filter(Boolean);
  const first = parts[0]?.[0] ?? '?';
  const last = parts.length > 1 ? parts[parts.length - 1][0] : '';
  return (first + last).toUpperCase();
}

function subline(rank: string | null | undefined, callsign: string | null | undefined): string {
  return [rank || null, callsign || t('common.no_callsign')].filter(Boolean).join(' · ');
}

/** Lua sends empty lists as {} (or leaves them out) and nil fields as missing keys: make every list an array. */
function normalizeView(v: UnitScreenView): UnitScreenView {
  const unit = v.unit ?? null;
  return {
    ...v,
    unit: unit
      ? {
          ...unit,
          locked: !!unit.locked,
          members: asArray(unit.members).map((m) => ({ ...m, callsign: m.callsign ?? null })),
          pending: asArray(unit.pending).map((p) => ({ ...p, callsign: p.callsign ?? null })),
        }
      : null,
    invites: asArray(v.invites).map((i) => ({ ...i, fromCallsign: i.fromCallsign ?? null })),
    invitable: asArray(v.invitable).map((o) => ({ ...o, callsign: o.callsign ?? null })),
    onRun: !!v.onRun,
    inviteBlocked: v.inviteBlocked ?? null,
  };
}

function matches(o: UnitInvitableView, q: string): boolean {
  if (!q) return true;
  const s = q.toLowerCase();
  return [o.name, o.callsign ?? '', o.departmentShort, o.rank].some((v) => String(v).toLowerCase().includes(s));
}

// ── rows ──────────────────────────────────────────────────────────────────────

function Avatar({ name, leader, muted }: { name: string; leader?: boolean; muted?: boolean }) {
  return (
    <span className={cx('teams-avatar', leader && 'teams-avatar--leader', muted && 'teams-avatar--muted')} aria-hidden>
      {initials(name)}
      {leader ? (
        <span className="teams-avatar__crown">
          <Icon name="star" size={10} strokeWidth={2.4} />
        </span>
      ) : null}
    </span>
  );
}

function MemberRow({ m, isMe }: { m: UnitMemberView; isMe: boolean }) {
  const unavailable = m.available === false;
  return (
    <li className={cx('teams-row', m.isLeader && 'teams-row--leader', unavailable && 'teams-row--muted')}>
      <Avatar name={m.name} leader={m.isLeader} muted={unavailable} />
      <div className="teams-row__main">
        <div className="teams-row__name">
          <span className="teams-row__text">{m.name}</span>
          {isMe ? <Badge size="sm" tone="primary">{t('unit.ui.you')}</Badge> : null}
        </div>
        <div className="teams-row__sub">{subline(m.rank, m.callsign)}</div>
      </div>
      <div className="teams-row__tags">
        {unavailable ? <Badge size="sm" tone="warning" icon="alert">{t('unit.ui.unavailable')}</Badge> : null}
        {m.isLeader ? <Badge size="sm" tone="accent" icon="star">{t('unit.ui.leader')}</Badge> : null}
        <Badge size="sm" variant="outline">{m.departmentShort || '?'}</Badge>
      </div>
    </li>
  );
}

function PendingRow({ p, stamp }: { p: UnitPendingInvite; stamp: unknown }) {
  return (
    <li className="teams-row teams-row--pending">
      <Avatar name={p.name} muted />
      <div className="teams-row__main">
        <div className="teams-row__name">
          <span className="teams-row__text">{p.name}</span>
        </div>
        <div className="teams-row__sub">{subline(null, p.callsign)}</div>
      </div>
      <div className="teams-row__tags">
        <span className="teams-row__timer">
          <Icon name="clock" size={13} />
          <span>{t('unit.ui.invite_sent')}</span>
          <Countdown seconds={p.expiresIn} resetKey={stamp} warnBelow={30} />
        </span>
        <Badge size="sm" variant="outline">{p.departmentShort || '?'}</Badge>
      </div>
    </li>
  );
}

function SlotRow() {
  return (
    <li className="teams-row teams-row--slot">
      <span className="teams-avatar teams-avatar--slot" aria-hidden>
        <Icon name="plus" size={14} />
      </span>
      <div className="teams-row__main">
        <div className="teams-row__sub">{t('unit.ui.open_slot')}</div>
      </div>
    </li>
  );
}

// ── cards ─────────────────────────────────────────────────────────────────────

function UnitCard({ view, stamp }: { view: UnitScreenView; stamp: unknown }) {
  const session = useSession();
  const navigate = useNavigate();
  const me = session.officer;
  const max = view.maxSize ?? DEFAULT_MAX;
  const unit = view.unit;
  const members = unit?.members ?? [];
  const pending = unit?.pending ?? [];
  const size = unit ? unit.size ?? members.length : 1;
  const slots = Math.max(0, max - (unit ? members.length : 1) - pending.length);
  const iLead = unit ? unit.leader === view.me : true;
  const leaderName = members.find((m) => m.isLeader)?.name;

  const status = unit?.locked ? (
    <Badge tone="warning" icon="lock">{t('unit.ui.status_locked')}</Badge>
  ) : unit ? (
    <Badge tone="success" dot>{t('unit.ui.status_open')}</Badge>
  ) : (
    <Badge tone="neutral">{t('unit.ui.status_solo')}</Badge>
  );

  return (
    <Card
      icon="users"
      title={t('unit.ui.your_unit')}
      subtitle={
        unit
          ? t('unit.ui.size', { size, max }) + (leaderName ? ' · ' + t('unit.ui.led_by', { name: leaderName }) : '')
          : t('unit.ui.solo_subtitle')
      }
      actions={status}
      padding="sm"
      footer={
        <div className="teams-footer">
          <span className="teams-footer__text">
            <Icon name="info" size={14} />
            {unit?.locked ? t('unit.ui.hint_locked') : iLead ? t('unit.ui.hint_leader') : t('unit.ui.hint_member', { name: leaderName ?? '?' })}
          </span>
          {iLead && !unit?.locked && !view.onRun ? (
            <Button size="sm" variant="secondary" iconRight="chevronRight" onClick={() => navigate('board')}>
              {t('unit.ui.open_board')}
            </Button>
          ) : null}
        </div>
      }
    >
      <ul className="teams-list">
        {unit ? (
          members.map((m) => <MemberRow key={m.src} m={m} isMe={m.src === view.me} />)
        ) : me ? (
          <MemberRow
            m={{ src: view.me ?? 0, name: me.name, callsign: me.callsign, rank: me.rank, departmentShort: me.departmentShort, isLeader: true }}
            isMe
          />
        ) : null}
        {pending.map((p) => <PendingRow key={`p${p.src}`} p={p} stamp={stamp} />)}
        {Array.from({ length: slots }, (_, i) => <SlotRow key={`s${i}`} />)}
      </ul>
    </Card>
  );
}

function InvitesCard({ view, stamp, onRespond, busyKey }: {
  view: UnitScreenView; stamp: unknown; busyKey: string | null;
  onRespond: (invite: UnitInviteView, accepted: boolean) => void;
}) {
  const invites = view.invites ?? [];
  return (
    <Card
      icon="inbox"
      title={t('unit.ui.invites_title')}
      subtitle={t('unit.ui.invites_subtitle', { minutes: Math.max(1, Math.round((view.inviteTtl ?? 120) / 60)) })}
      actions={invites.length ? <Badge tone="accent" size="sm">{invites.length}</Badge> : null}
      padding="sm"
    >
      {invites.length === 0 ? (
        <EmptyState compact icon="inbox" title={t('unit.ui.no_invites')} text={t('unit.ui.no_invites_text')} />
      ) : (
        <ul className="teams-list">
          {invites.map((inv) => {
            const key = `r${inv.unitId}`;
            return (
              <li key={inv.unitId} className="teams-invite">
                <div className="teams-invite__head">
                  <Avatar name={inv.from} />
                  <div className="teams-row__main">
                    <div className="teams-row__name">
                      <span className="teams-row__text">{inv.from}</span>
                      <Badge size="sm" variant="outline">{inv.departmentShort || '?'}</Badge>
                    </div>
                    <div className="teams-row__sub">
                      {[inv.fromCallsign || t('common.no_callsign'), inv.size ? t('unit.ui.unit_of', { size: inv.size }) : null].filter(Boolean).join(' · ')}
                    </div>
                  </div>
                  <span className="teams-row__expires" title={t('unit.ui.expires_in')}>
                    <Icon name="clock" size={13} />
                    <Countdown seconds={inv.expiresIn} resetKey={stamp} warnBelow={30} dangerBelow={10} />
                  </span>
                </div>
                <div className="teams-invite__actions">
                  <Button size="sm" variant="ghost" icon="x" loading={busyKey === key + ':no'} disabled={!!busyKey} onClick={() => onRespond(inv, false)}>
                    {t('unit.ui.decline')}
                  </Button>
                  <Button
                    size="sm"
                    variant="primary"
                    icon="check"
                    loading={busyKey === key + ':yes'}
                    disabled={!!busyKey || view.onRun}
                    onClick={() => onRespond(inv, true)}
                  >
                    {t('unit.ui.accept')}
                  </Button>
                </div>
              </li>
            );
          })}
        </ul>
      )}
      {invites.length > 0 && view.onRun ? <p className="teams-note">{t('unit.ui.accept_on_run')}</p> : null}
      {invites.length > 0 && !view.onRun && view.unit ? <p className="teams-note">{t('unit.ui.accept_moves')}</p> : null}
    </Card>
  );
}

/** Test invitations waiting for the viewer (SPEC Admin test mode: testers "accept on their own screen").
 *  Callback test:pendingInvites (modules/testing, anyone: their own invitations), live via push 'invites';
 *  Accept / Decline → server:testRespond { inviteId, accepted }. Hidden while there are none. */
function TestInvitesCard() {
  const { data, refetch } = useRequest<TestInvite[]>('test:pendingInvites', {}, { pushTopic: 'invites' });
  const { run } = useAction();
  const [busy, setBusy] = useState<string | null>(null);
  const invites = asList(data);
  if (!invites.length) return null;
  const respond = async (inv: TestInvite, accepted: boolean) => {
    setBusy(`${inv.inviteId}:${accepted ? 'yes' : 'no'}`);
    await run('server:testRespond', { inviteId: inv.inviteId, accepted }, { success: accepted ? 'test.ui.invite_accepted' : 'test.ui.invite_declined' });
    setBusy(null);
    void refetch();
  };
  return (
    <Card icon="flask" title={t('test.ui.invites_title')} subtitle={t('test.ui.prompt_sub')} actions={<Badge tone="accent" size="sm">{invites.length}</Badge>} padding="sm">
      <ul className="teams-list">
        {invites.map((inv) => (
          <li key={inv.inviteId} className="teams-invite">
            <div className="teams-invite__head">
              <Avatar name={inv.from} />
              <div className="teams-row__main">
                <div className="teams-row__name">
                  <span className="teams-row__text" title={inv.missionLabel}>{inv.missionLabel}</span>
                </div>
                <div className="teams-row__sub" title={inv.from}>
                  {[t('test.ui.prompt_from', { from: inv.from }), inv.fromCallsign || null].filter(Boolean).join(' · ')}
                </div>
              </div>
              <span className="teams-row__expires" title={t('test.ui.invite_expires')}>
                <Icon name="clock" size={13} />
                <Countdown seconds={inv.expiresIn} resetKey={data} warnBelow={30} dangerBelow={10} />
              </span>
            </div>
            <div className="teams-invite__actions">
              <Button size="sm" variant="ghost" icon="x" loading={busy === `${inv.inviteId}:no`} disabled={!!busy} onClick={() => void respond(inv, false)}>
                {t('test.ui.decline')}
              </Button>
              <Button size="sm" variant="primary" icon="check" loading={busy === `${inv.inviteId}:yes`} disabled={!!busy} onClick={() => void respond(inv, true)}>
                {t('test.ui.accept')}
              </Button>
            </div>
          </li>
        ))}
      </ul>
    </Card>
  );
}

function InvitePicker({ view, onInvite, busyKey }: { view: UnitScreenView; busyKey: string | null; onInvite: (o: UnitInvitableView) => void }) {
  const [query, setQuery] = useState('');
  const list = view.invitable ?? [];
  const shown = useMemo(() => list.filter((o) => matches(o, query.trim())), [list, query]);
  const canInvite = view.canInvite !== false;

  return (
    <Card
      icon="plus"
      title={t('unit.ui.invite_title')}
      subtitle={t('unit.ui.invite_subtitle')}
      actions={canInvite && list.length ? <Badge size="sm">{t('unit.ui.available_count', { n: list.length })}</Badge> : null}
      padding="sm"
    >
      {!canInvite ? (
        <EmptyState compact icon="lock" title={t('unit.ui.invites_closed')} text={view.inviteBlocked ? t(view.inviteBlocked) : undefined} />
      ) : (
        <Stack gap={2}>
          <SearchInput value={query} onChange={setQuery} placeholder={t('unit.ui.search_placeholder')} aria-label={t('common.search')} />
          {list.length === 0 ? (
            <EmptyState compact icon="users" title={t('unit.ui.none_available')} text={t('unit.ui.none_available_text')} />
          ) : shown.length === 0 ? (
            <EmptyState compact icon="search" title={t('unit.ui.no_match', { query: query.trim() })} />
          ) : (
            <ul className="teams-list teams-list--scroll">
              {shown.map((o) => {
                const key = `i${o.src}`;
                return (
                  <li key={o.src} className="teams-row teams-row--pick">
                    <Avatar name={o.name} />
                    <div className="teams-row__main">
                      <div className="teams-row__name">
                        <span className="teams-row__text">{o.name}</span>
                        <Badge size="sm" variant="outline">{o.departmentShort || '?'}</Badge>
                        {o.inUnit ? <Badge size="sm" tone="neutral">{t('unit.ui.in_unit')}</Badge> : null}
                      </div>
                      <div className="teams-row__sub">{subline(o.rank, o.callsign)}</div>
                    </div>
                    <div className="teams-row__actions">
                      <Button size="sm" variant="secondary" icon="plus" loading={busyKey === key} disabled={!!busyKey} onClick={() => onInvite(o)}>
                        {t('unit.ui.invite')}
                      </Button>
                    </div>
                  </li>
                );
              })}
            </ul>
          )}
        </Stack>
      )}
    </Card>
  );
}

// ── screen ────────────────────────────────────────────────────────────────────

export default function Unit() {
  const { data: raw, loading, error, refetch } = useRequest<UnitScreenView>('getUnit', {}, { pushTopic: 'unit', pollMs: 20000 });
  const data = useMemo(() => (raw ? normalizeView(raw) : null), [raw]);
  const { run } = useAction();
  const [busyKey, setBusyKey] = useState<string | null>(null);
  const [confirmLeave, setConfirmLeave] = useState(false);

  const act = async (key: string, fn: () => Promise<unknown>) => {
    setBusyKey(key);
    try {
      await fn();
    } finally {
      setBusyKey(null);
      void refetch();
    }
  };

  const invite = (o: UnitInvitableView) =>
    act(`i${o.src}`, () => run('server:unitInvite', o.src, { success: 'unit.ui.invite_sent_toast', successVars: { name: o.name } }));
  const respond = (inv: UnitInviteView, accepted: boolean) =>
    act(`r${inv.unitId}:${accepted ? 'yes' : 'no'}`, () => run('server:unitRespond', { accepted, unitId: inv.unitId }));
  const leave = async () => {
    const res = await run<UnitLeaveResult>('server:unitLeave');
    setConfirmLeave(false);
    void refetch();
    return res;
  };

  const max = data?.maxSize ?? DEFAULT_MAX;
  const unit = data?.unit ?? null;
  const onUnitRun = !!(unit?.locked && data?.onRun);

  return (
    <Screen
      title={t('ui.screen.unit')}
      subtitle={t('unit.ui.subtitle', { max })}
      actions={
        unit ? (
          <Button variant="danger" icon="logout" onClick={() => setConfirmLeave(true)} disabled={!!busyKey}>
            {t('unit.ui.leave')}
          </Button>
        ) : null
      }
    >
      {!data && loading ? (
        <LoadingBlock />
      ) : !data ? (
        <ErrorState error={error} onRetry={() => void refetch()} />
      ) : (
        <>
          {unit?.locked || data.onRun ? (
            <div className={cx('teams-banner', unit?.locked ? 'teams-banner--warning' : 'teams-banner--info')} role="status">
              <Icon name="lock" size={18} />
              <div>
                <div className="teams-banner__title">{unit?.locked ? t('unit.ui.locked_title') : t('unit.ui.on_run_title')}</div>
                <div className="teams-banner__text">
                  {unit?.locked ? (data.onRun ? t('unit.ui.locked_text') : t('unit.ui.locked_text_off_run')) : t('unit.ui.on_run_text')}
                </div>
              </div>
            </div>
          ) : null}
          <Grid cols="minmax(0, 1.25fr) minmax(0, 1fr)" gap={4} align="start" className="teams-grid">
            <UnitCard view={data} stamp={data} />
            <Stack gap={4}>
              <TestInvitesCard />
              <InvitesCard view={data} stamp={data} busyKey={busyKey} onRespond={respond} />
              <InvitePicker view={data} busyKey={busyKey} onInvite={invite} />
            </Stack>
          </Grid>
        </>
      )}
      <ConfirmDialog
        open={confirmLeave}
        tone="danger"
        title={t('unit.ui.leave_title')}
        message={onUnitRun ? t('unit.ui.leave_confirm_run') : t('unit.ui.leave_confirm')}
        confirmLabel={onUnitRun ? t('unit.ui.leave_and_abandon') : t('unit.ui.leave')}
        onConfirm={() => leave()}
        onCancel={() => setConfirmLeave(false)}
      />
    </Screen>
  );
}
