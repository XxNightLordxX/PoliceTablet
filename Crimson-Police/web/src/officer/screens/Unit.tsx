// Officer UI · Unit (screen key 'unit', title key 'ui.screen.unit').

import { useMemo, useState } from 'react';
import {
    Avatar as ProfileAvatar,
    Badge,
    Button,
    Card,
    ConfirmDialog,
    Countdown,
    EmptyState,
    ErrorState,
    Grid,
    Icon,
    LoadingBlock,
    Screen,
    SearchInput,
    Stack,
} from '../../shared/components';
import { asArray } from '../../shared/data';
import { useAction, usePush, useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { useNavigate } from '../../shared/navigation';
import { useSession } from '../../shared/session';
import { cx } from '../../shared/cx';
import type {
    SizeFitEntry,
    UnitInvitableView,
    UnitInviteView,
    UnitLeaveResult,
    UnitMemberView,
    UnitOperationCard,
    UnitPendingInvite,
    UnitScreenView,
} from '../../types/teams';
import { asList, type TestInvite } from '../../types/testing';
import { ReadyCheckBanner } from '../components/ReadyCheckBanner';
import './Unit.css';

// A leader control waiting for its confirm dialog.
type ManageDialog = null | { kind: 'kick' | 'promote'; m: UnitMemberView } | { kind: 'disband' };

// What the rows may do (the leader, or the officer who sent an invite).
interface RowActions {
    canManage: boolean;
    sent: Set<number>;
    busyKey: string | null;
    onManage: (d: ManageDialog) => void;
    onWithdraw: (p: UnitPendingInvite) => void;
}

const DEFAULT_MAX = 4;

function initials(name: string): string {
    const parts = String(name || '?')
        .trim()
        .split(/\s+/)
        .filter(Boolean);
    const first = parts[0]?.[0] ?? '?';
    const last = parts.length > 1 ? parts[parts.length - 1][0] : '';
    return (first + last).toUpperCase();
}

function subline(rank: string | null | undefined, callsign: string | null | undefined): string {
    return [rank || null, callsign || t('common.no_callsign')].filter(Boolean).join(' · ');
}

// Lua sends empty lists as {} (or leaves them out) and nil fields as missing keys: make every list an array.
function normalizeView(v: UnitScreenView): UnitScreenView {
    const unit = v.unit ?? null;
    return {
        ...v,
        unit: unit
            ? {
                  ...unit,
                  locked: !!unit.locked,
                  canManage: !!unit.canManage,
                  readyCheck: unit.readyCheck ?? null,
                  members: asArray(unit.members).map(m => ({ ...m, callsign: m.callsign ?? null })),
                  pending: asArray(unit.pending).map(p => ({ ...p, callsign: p.callsign ?? null })),
              }
            : null,
        pendingSent: asArray(v.pendingSent),
        sizeFit: v.sizeFit && !Array.isArray(v.sizeFit) ? v.sizeFit : {},
        operation: v.operation ?? null,
        invites: asArray(v.invites).map(i => ({ ...i, fromCallsign: i.fromCallsign ?? null })),
        invitable: asArray(v.invitable).map(o => ({ ...o, callsign: o.callsign ?? null })),
        onRun: !!v.onRun,
        inviteBlocked: v.inviteBlocked ?? null,
    };
}

function matches(o: UnitInvitableView, q: string): boolean {
    if (!q) return true;
    const s = q.toLowerCase();
    return [o.name, o.callsign ?? '', o.departmentShort, o.rank].some(v => String(v).toLowerCase().includes(s));
}

// ============================================================================
//                                     ROWS
// ============================================================================

function Avatar({ name, leader, muted }: { name: string; leader?: boolean; muted?: boolean }) {
    return (
        <span
            className={cx('teams-avatar', leader && 'teams-avatar--leader', muted && 'teams-avatar--muted')}
            aria-hidden
        >
            {initials(name)}
            {leader ? (
                <span className="teams-avatar__crown">
                    <Icon name="star" size={10} strokeWidth={2.4} />
                </span>
            ) : null}
        </span>
    );
}

function MemberRow({ m, isMe, actions }: { m: UnitMemberView; isMe: boolean; actions?: RowActions }) {
    const unavailable = m.available === false;
    const manage = actions?.canManage && !isMe;
    return (
        <li className={cx('teams-row', m.isLeader && 'teams-row--leader', unavailable && 'teams-row--muted')}>
            {m.avatar ? (
                <ProfileAvatar avatar={m.avatar} name={m.name} size={36} />
            ) : (
                <Avatar name={m.name} leader={m.isLeader} muted={unavailable} />
            )}
            <div className="teams-row__main">
                <div className="teams-row__name">
                    <span className="teams-row__text">{m.name}</span>
                    {m.level ? (
                        <Badge size="sm" variant="outline">
                            {t('unit.ui.level', { n: m.level.n })}
                        </Badge>
                    ) : null}
                    {isMe ? (
                        <Badge size="sm" tone="primary">
                            {t('unit.ui.you')}
                        </Badge>
                    ) : null}
                </div>
                <div className="teams-row__sub">{subline(m.rank, m.callsign)}</div>
            </div>
            <div className="teams-row__tags">
                {unavailable ? (
                    <Badge size="sm" tone="warning" icon="alert">
                        {t('unit.ui.unavailable')}
                    </Badge>
                ) : null}
                {m.isLeader ? (
                    <Badge size="sm" tone="accent" icon="star">
                        {t('unit.ui.leader')}
                    </Badge>
                ) : null}
                <Badge size="sm" variant="outline">
                    {m.departmentShort || '?'}
                </Badge>
            </div>
            {manage && actions ? (
                <div className="teams-row__actions">
                    <Button
                        size="sm"
                        variant="ghost"
                        icon="star"
                        disabled={!!actions.busyKey}
                        onClick={() => actions.onManage({ kind: 'promote', m })}
                    >
                        {t('unit.ui.promote')}
                    </Button>
                    <Button
                        size="sm"
                        variant="ghost"
                        icon="x"
                        disabled={!!actions.busyKey}
                        onClick={() => actions.onManage({ kind: 'kick', m })}
                    >
                        {t('unit.ui.kick')}
                    </Button>
                </div>
            ) : null}
        </li>
    );
}

function PendingRow({ p, stamp, actions }: { p: UnitPendingInvite; stamp: unknown; actions?: RowActions }) {
    const canWithdraw = !!actions && (actions.canManage || actions.sent.has(p.src));
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
                <Badge size="sm" variant="outline">
                    {p.departmentShort || '?'}
                </Badge>
            </div>
            {canWithdraw && actions ? (
                <div className="teams-row__actions">
                    <Button
                        size="sm"
                        variant="ghost"
                        icon="x"
                        loading={actions.busyKey === `w${p.src}`}
                        disabled={!!actions.busyKey}
                        onClick={() => actions.onWithdraw(p)}
                    >
                        {t('unit.ui.withdraw')}
                    </Button>
                </div>
            ) : null}
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

// ============================================================================
//                                    CARDS
// ============================================================================

function UnitCard({ view, stamp, actions }: { view: UnitScreenView; stamp: unknown; actions: RowActions }) {
    const session = useSession();
    const navigate = useNavigate();
    const me = session.officer;
    const max = view.maxSize ?? DEFAULT_MAX;
    const unit = view.unit;
    const members = unit?.members ?? [];
    const pending = unit?.pending ?? [];
    const size = unit ? (unit.size ?? members.length) : 1;
    const slots = Math.max(0, max - (unit ? members.length : 1) - pending.length);
    const iLead = unit ? unit.leader === view.me : true;
    const leaderName = members.find(m => m.isLeader)?.name;

    const status = unit?.locked ? (
        <Badge tone="warning" icon="lock">
            {t('unit.ui.status_locked')}
        </Badge>
    ) : unit ? (
        <Badge tone="success" dot>
            {t('unit.ui.status_open')}
        </Badge>
    ) : (
        <Badge tone="neutral">{t('unit.ui.status_solo')}</Badge>
    );

    return (
        <Card
            icon="users"
            title={t('unit.ui.your_unit')}
            subtitle={
                unit
                    ? t('unit.ui.size', { size, max }) +
                      (leaderName ? ' · ' + t('unit.ui.led_by', { name: leaderName }) : '')
                    : t('unit.ui.solo_subtitle')
            }
            actions={status}
            padding="sm"
            footer={
                <div className="teams-footer">
                    <span className="teams-footer__text">
                        <Icon name="info" size={14} />
                        {unit?.locked
                            ? t('unit.ui.hint_locked')
                            : iLead
                              ? t('unit.ui.hint_leader')
                              : t('unit.ui.hint_member', { name: leaderName ?? '?' })}
                    </span>
                    {actions.canManage && members.length >= 2 ? (
                        <Button
                            size="sm"
                            variant="ghost"
                            icon="trash"
                            disabled={!!actions.busyKey}
                            onClick={() => actions.onManage({ kind: 'disband' })}
                        >
                            {t('unit.ui.disband')}
                        </Button>
                    ) : null}
                    {iLead && !unit?.locked && !view.onRun ? (
                        <Button
                            size="sm"
                            variant="secondary"
                            iconRight="chevronRight"
                            onClick={() => navigate('board')}
                        >
                            {t('unit.ui.open_board')}
                        </Button>
                    ) : null}
                </div>
            }
        >
            <ul className="teams-list">
                {unit ? (
                    members.map(m => <MemberRow key={m.src} m={m} isMe={m.src === view.me} actions={actions} />)
                ) : me ? (
                    <MemberRow
                        m={{
                            src: view.me ?? 0,
                            name: me.name,
                            callsign: me.callsign,
                            rank: me.rank,
                            departmentShort: me.departmentShort,
                            isLeader: true,
                        }}
                        isMe
                    />
                ) : null}
                {pending.map(p => (
                    <PendingRow key={`p${p.src}`} p={p} stamp={stamp} actions={actions} />
                ))}
                {Array.from({ length: slots }, (_, i) => (
                    <SlotRow key={`s${i}`} />
                ))}
            </ul>
        </Card>
    );
}

function InvitesCard({
    view,
    stamp,
    onRespond,
    busyKey,
}: {
    view: UnitScreenView;
    stamp: unknown;
    busyKey: string | null;
    onRespond: (invite: UnitInviteView, accepted: boolean) => void;
}) {
    const invites = view.invites ?? [];
    return (
        <Card
            icon="inbox"
            title={t('unit.ui.invites_title')}
            subtitle={t('unit.ui.invites_subtitle', { minutes: Math.max(1, Math.round((view.inviteTtl ?? 120) / 60)) })}
            actions={
                invites.length ? (
                    <Badge tone="accent" size="sm">
                        {invites.length}
                    </Badge>
                ) : null
            }
            padding="sm"
        >
            {invites.length === 0 ? (
                <EmptyState compact icon="inbox" title={t('unit.ui.no_invites')} text={t('unit.ui.no_invites_text')} />
            ) : (
                <ul className="teams-list">
                    {invites.map(inv => {
                        const key = `r${inv.unitId}`;
                        return (
                            <li key={inv.unitId} className="teams-invite">
                                <div className="teams-invite__head">
                                    <Avatar name={inv.from} />
                                    <div className="teams-row__main">
                                        <div className="teams-row__name">
                                            <span className="teams-row__text">{inv.from}</span>
                                            <Badge size="sm" variant="outline">
                                                {inv.departmentShort || '?'}
                                            </Badge>
                                        </div>
                                        <div className="teams-row__sub">
                                            {[
                                                inv.fromCallsign || t('common.no_callsign'),
                                                inv.size ? t('unit.ui.unit_of', { size: inv.size }) : null,
                                            ]
                                                .filter(Boolean)
                                                .join(' · ')}
                                        </div>
                                    </div>
                                    <span className="teams-row__expires" title={t('unit.ui.expires_in')}>
                                        <Icon name="clock" size={13} />
                                        <Countdown
                                            seconds={inv.expiresIn}
                                            resetKey={stamp}
                                            warnBelow={30}
                                            dangerBelow={10}
                                        />
                                    </span>
                                </div>
                                <div className="teams-invite__actions">
                                    <Button
                                        size="sm"
                                        variant="ghost"
                                        icon="x"
                                        loading={busyKey === key + ':no'}
                                        disabled={!!busyKey}
                                        onClick={() => onRespond(inv, false)}
                                    >
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
            {invites.length > 0 && !view.onRun && view.unit ? (
                <p className="teams-note">{t('unit.ui.accept_moves')}</p>
            ) : null}
        </Card>
    );
}

// Test invitations waiting for the viewer (SPEC Admin test mode: testers "accept on their own screen").
// Callback test:pendingInvites (modules/testing, anyone: their own invitations), live via push 'invites';
// Accept / Decline → server:testRespond { inviteId, accepted }. Hidden while there are none.
function TestInvitesCard() {
    const { data, refetch } = useRequest<TestInvite[]>('test:pendingInvites', {}, { pushTopic: 'invites' });
    const { run } = useAction();
    const [busy, setBusy] = useState<string | null>(null);
    const invites = asList(data);
    if (!invites.length) return null;
    const respond = async (inv: TestInvite, accepted: boolean) => {
        setBusy(`${inv.inviteId}:${accepted ? 'yes' : 'no'}`);
        await run(
            'server:testRespond',
            { inviteId: inv.inviteId, accepted },
            { success: accepted ? 'test.ui.invite_accepted' : 'test.ui.invite_declined' },
        );
        setBusy(null);
        void refetch();
    };
    return (
        <Card
            icon="flask"
            title={t('test.ui.invites_title')}
            subtitle={t('test.ui.prompt_sub')}
            actions={
                <Badge tone="accent" size="sm">
                    {invites.length}
                </Badge>
            }
            padding="sm"
        >
            <ul className="teams-list">
                {invites.map(inv => (
                    <li key={inv.inviteId} className="teams-invite">
                        <div className="teams-invite__head">
                            <Avatar name={inv.from} />
                            <div className="teams-row__main">
                                <div className="teams-row__name">
                                    <span className="teams-row__text" title={inv.missionLabel}>
                                        {inv.missionLabel}
                                    </span>
                                </div>
                                <div className="teams-row__sub" title={inv.from}>
                                    {[t('test.ui.prompt_from', { from: inv.from }), inv.fromCallsign || null]
                                        .filter(Boolean)
                                        .join(' · ')}
                                </div>
                            </div>
                            <span className="teams-row__expires" title={t('test.ui.invite_expires')}>
                                <Icon name="clock" size={13} />
                                <Countdown seconds={inv.expiresIn} resetKey={data} warnBelow={30} dangerBelow={10} />
                            </span>
                        </div>
                        <div className="teams-invite__actions">
                            <Button
                                size="sm"
                                variant="ghost"
                                icon="x"
                                loading={busy === `${inv.inviteId}:no`}
                                disabled={!!busy}
                                onClick={() => void respond(inv, false)}
                            >
                                {t('test.ui.decline')}
                            </Button>
                            <Button
                                size="sm"
                                variant="primary"
                                icon="check"
                                loading={busy === `${inv.inviteId}:yes`}
                                disabled={!!busy}
                                onClick={() => void respond(inv, true)}
                            >
                                {t('test.ui.accept')}
                            </Button>
                        </div>
                    </li>
                ))}
            </ul>
        </Card>
    );
}

const BAND_TONE = ['success', 'primary', 'neutral', 'grey'] as const;

function InvitePicker({
    view,
    onInvite,
    onReinvite,
    busyKey,
}: {
    view: UnitScreenView;
    busyKey: string | null;
    onInvite: (o: UnitInvitableView) => void;
    onReinvite: (list: UnitInvitableView[]) => void;
}) {
    const [query, setQuery] = useState('');
    const list = view.invitable ?? [];
    const shown = useMemo(() => list.filter(o => matches(o, query.trim())), [list, query]);
    const canInvite = view.canInvite !== false;
    const partners = list.filter(o => o.lastPartner);

    return (
        <Card
            icon="plus"
            title={t('unit.ui.invite_title')}
            subtitle={t('unit.ui.invite_subtitle')}
            actions={
                canInvite && list.length ? (
                    <Badge size="sm">{t('unit.ui.available_count', { n: list.length })}</Badge>
                ) : null
            }
            padding="sm"
        >
            {!canInvite ? (
                <EmptyState
                    compact
                    icon="lock"
                    title={t('unit.ui.invites_closed')}
                    text={view.inviteBlocked ? t(view.inviteBlocked) : undefined}
                />
            ) : (
                <Stack gap={2}>
                    <SearchInput
                        value={query}
                        onChange={setQuery}
                        placeholder={t('unit.ui.search_placeholder')}
                        aria-label={t('common.search')}
                    />
                    {partners.length ? (
                        <Button
                            size="sm"
                            variant="secondary"
                            icon="refresh"
                            loading={busyKey === 'reinvite'}
                            disabled={!!busyKey}
                            onClick={() => onReinvite(partners)}
                        >
                            {t('unit.ui.reinvite', { n: partners.length })}
                        </Button>
                    ) : null}
                    {list.length === 0 ? (
                        <EmptyState
                            compact
                            icon="users"
                            title={t('unit.ui.none_available')}
                            text={t('unit.ui.none_available_text')}
                        />
                    ) : shown.length === 0 ? (
                        <EmptyState compact icon="search" title={t('unit.ui.no_match', { query: query.trim() })} />
                    ) : (
                        <ul className="teams-list teams-list--scroll">
                            {shown.map(o => {
                                const key = `i${o.src}`;
                                return (
                                    <li key={o.src} className="teams-row teams-row--pick">
                                        <Avatar name={o.name} />
                                        <div className="teams-row__main">
                                            <div className="teams-row__name">
                                                <span className="teams-row__text">{o.name}</span>
                                                <Badge size="sm" variant="outline">
                                                    {o.departmentShort || '?'}
                                                </Badge>
                                                {o.inUnit ? (
                                                    <Badge size="sm" tone="neutral">
                                                        {t('unit.ui.in_unit')}
                                                    </Badge>
                                                ) : null}
                                                {o.lastPartner ? (
                                                    <Badge size="sm" tone="accent">
                                                        {t('unit.ui.last_partner')}
                                                    </Badge>
                                                ) : null}
                                                {o.distanceBand !== undefined ? (
                                                    <Badge size="sm" tone={BAND_TONE[o.distanceBand] ?? 'grey'}>
                                                        {t(`unit.ui.band_${o.distanceBand}`)}
                                                    </Badge>
                                                ) : null}
                                            </div>
                                            <div className="teams-row__sub">{subline(o.rank, o.callsign)}</div>
                                        </div>
                                        <div className="teams-row__actions">
                                            <Button
                                                size="sm"
                                                variant="secondary"
                                                icon="plus"
                                                loading={busyKey === key}
                                                disabled={!!busyKey}
                                                onClick={() => onInvite(o)}
                                            >
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

// Per type: how many missions the unit could draw now and with one more officer (counts only, never names).
function SizeFitCard({ view }: { view: UnitScreenView }) {
    const session = useSession();
    const fit = view.sizeFit ?? {};
    const types = (session.config?.missionTypes ?? []).filter(x => fit[x.key]);
    if (!types.length) return null;
    const size = view.unit ? (view.unit.size ?? view.unit.members.length) : 1;
    const max = view.maxSize ?? DEFAULT_MAX;
    const line = (e: SizeFitEntry) =>
        size < max
            ? t(size === 1 ? 'unit.ui.fit_line_solo' : 'unit.ui.fit_line', { now: e.now, plus: e.plusOne })
            : t('unit.ui.fit_line_full', { now: e.now });
    return (
        <Card icon="layers" title={t('unit.ui.fit_title')} subtitle={t('unit.ui.fit_subtitle')} padding="sm">
            <ul className="teams-fit">
                {types.map(x => (
                    <li key={x.key} className="teams-fit__row">
                        <span className="teams-fit__type">{x.label}</span>
                        <span className="teams-fit__counts">{line(fit[x.key])}</span>
                    </li>
                ))}
            </ul>
        </Card>
    );
}

// The Cross-Department Mission the viewer joined or waits for; Leave before the start (no penalty).
function OperationCard({
    op,
    stamp,
    busyKey,
    onLeave,
}: {
    op: UnitOperationCard;
    stamp: unknown;
    busyKey: string | null;
    onLeave: () => void;
}) {
    const waiting = op.waitlistPosition ?? null;
    return (
        <Card
            icon="globe"
            title={t('unit.ui.op_title')}
            subtitle={op.missionLabel}
            actions={
                waiting ? (
                    <Badge size="sm" tone="warning">
                        {t('unit.ui.op_waitlist', { n: waiting })}
                    </Badge>
                ) : (
                    <Badge size="sm" tone="success">
                        {t('unit.ui.op_joined', { joined: op.joined, max: op.max })}
                    </Badge>
                )
            }
            padding="sm"
        >
            <div className="teams-footer">
                <span className="teams-footer__text">
                    <Icon name="clock" size={14} />
                    {op.joinEndsIn != null ? (
                        <>
                            {t('unit.ui.op_starts_in')} <Countdown seconds={op.joinEndsIn} resetKey={stamp} />
                        </>
                    ) : (
                        t('unit.ui.op_started')
                    )}
                </span>
                {op.canLeave ? (
                    <Button
                        size="sm"
                        variant="ghost"
                        icon="logout"
                        loading={busyKey === 'op'}
                        disabled={!!busyKey}
                        onClick={onLeave}
                    >
                        {waiting ? t('unit.ui.op_leave_waitlist') : t('unit.ui.op_leave')}
                    </Button>
                ) : null}
            </div>
        </Card>
    );
}

// ============================================================================
//                                    SCREEN
// ============================================================================

export default function Unit() {
    const {
        data: raw,
        loading,
        error,
        refetch,
    } = useRequest<UnitScreenView>('getUnit', {}, { pushTopic: 'unit', pollMs: 20000 });
    const data = useMemo(() => (raw ? normalizeView(raw) : null), [raw]);
    const { run } = useAction();
    const [busyKey, setBusyKey] = useState<string | null>(null);
    const [confirmLeave, setConfirmLeave] = useState(false);
    const [manage, setManage] = useState<ManageDialog>(null);
    usePush('operation', () => void refetch());

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
        act(`i${o.src}`, () =>
            run('server:unitInvite', o.src, { success: 'unit.ui.invite_sent_toast', successVars: { name: o.name } }),
        );
    const respond = (inv: UnitInviteView, accepted: boolean) =>
        act(`r${inv.unitId}:${accepted ? 'yes' : 'no'}`, () =>
            run('server:unitRespond', { accepted, unitId: inv.unitId }),
        );
    const reinvite = (list: UnitInvitableView[]) =>
        act('reinvite', async () => {
            for (const o of list) await run('server:unitInvite', o.src);
        });
    const withdraw = (p: UnitPendingInvite) =>
        act(`w${p.src}`, () =>
            run(
                'server:unitCancelInvite',
                { targetSrc: p.src },
                {
                    success: 'unit.ui.withdrawn_toast',
                    successVars: { name: p.name },
                },
            ),
        );
    const leaveOperation = () =>
        act('op', () => run('server:leaveOperation', undefined, { success: 'unit.ui.op_left_toast' }));
    const confirmManage = async () => {
        const d = manage;
        if (!d) return;
        if (d.kind === 'disband') await run('server:unitDisband');
        else if (d.kind === 'kick') await run('server:unitKick', { targetSrc: d.m.src });
        else await run('server:unitPromote', { targetSrc: d.m.src });
        setManage(null);
        void refetch();
    };
    const leave = async () => {
        const res = await run<UnitLeaveResult>('server:unitLeave');
        setConfirmLeave(false);
        void refetch();
        return res;
    };

    const max = data?.maxSize ?? DEFAULT_MAX;
    const unit = data?.unit ?? null;
    const onUnitRun = !!(unit?.locked && data?.onRun);
    const rowActions: RowActions = {
        canManage: !!unit?.canManage,
        sent: new Set((data?.pendingSent ?? []).map(x => x.src)),
        busyKey,
        onManage: setManage,
        onWithdraw: p => void withdraw(p),
    };

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
                    <ReadyCheckBanner check={unit?.readyCheck ?? null} onAnswered={() => void refetch()} />
                    {(unit?.locked && !unit?.readyCheck) || data.onRun ? (
                        <div
                            className={cx(
                                'teams-banner',
                                unit?.locked ? 'teams-banner--warning' : 'teams-banner--info',
                            )}
                            role="status"
                        >
                            <Icon name="lock" size={18} />
                            <div>
                                <div className="teams-banner__title">
                                    {unit?.locked ? t('unit.ui.locked_title') : t('unit.ui.on_run_title')}
                                </div>
                                <div className="teams-banner__text">
                                    {unit?.locked
                                        ? data.onRun
                                            ? t('unit.ui.locked_text')
                                            : t('unit.ui.locked_text_off_run')
                                        : t('unit.ui.on_run_text')}
                                </div>
                            </div>
                        </div>
                    ) : null}
                    <Grid cols="minmax(0, 1.25fr) minmax(0, 1fr)" gap={4} align="start" className="teams-grid">
                        <Stack gap={4}>
                            <UnitCard view={data} stamp={data} actions={rowActions} />
                            <SizeFitCard view={data} />
                        </Stack>
                        <Stack gap={4}>
                            {data.operation ? (
                                <OperationCard
                                    op={data.operation}
                                    stamp={data}
                                    busyKey={busyKey}
                                    onLeave={() => void leaveOperation()}
                                />
                            ) : null}
                            <TestInvitesCard />
                            <InvitesCard view={data} stamp={data} busyKey={busyKey} onRespond={respond} />
                            <InvitePicker
                                view={data}
                                busyKey={busyKey}
                                onInvite={invite}
                                onReinvite={l => void reinvite(l)}
                            />
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
            <ConfirmDialog
                open={manage !== null}
                tone={manage?.kind === 'promote' ? 'primary' : 'danger'}
                title={
                    manage?.kind === 'disband'
                        ? t('unit.ui.disband_title')
                        : manage?.kind === 'kick'
                          ? t('unit.ui.kick_title', { name: manage.m.name })
                          : t('unit.ui.promote_title', { name: manage?.kind === 'promote' ? manage.m.name : '' })
                }
                message={
                    manage?.kind === 'disband'
                        ? t('unit.ui.disband_confirm')
                        : manage?.kind === 'kick'
                          ? t('unit.ui.kick_confirm', { name: manage.m.name })
                          : t('unit.ui.promote_confirm')
                }
                confirmLabel={
                    manage?.kind === 'disband'
                        ? t('unit.ui.disband')
                        : manage?.kind === 'kick'
                          ? t('unit.ui.kick')
                          : t('unit.ui.promote')
                }
                onConfirm={() => confirmManage()}
                onCancel={() => setManage(null)}
            />
        </Screen>
    );
}
