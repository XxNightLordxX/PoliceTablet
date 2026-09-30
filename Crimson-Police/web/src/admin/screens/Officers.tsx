// Admin UI · Officers (screen key 'admin_officers').

import { useEffect, useState } from 'react';
import {
    Avatar,
    Badge,
    Button,
    Card,
    ConfirmDialog,
    Dialog,
    EmptyState,
    ErrorState,
    Field,
    Grid,
    Icon,
    IconButton,
    LoadingBlock,
    Money,
    NumberInput,
    Points,
    Row,
    Screen,
    SearchInput,
    Spinner,
    Stat,
    Table,
    Textarea,
    XpBadge,
    type TableColumn,
} from '../../shared/components';
import { DecisionsBlock, PeopleBlock } from '../../hud/Debrief';
import { asArray } from '../../shared/data';
import { fmtDateTime, formatDateTime, formatNumber } from '../../shared/format';
import { useAction, useRequest } from '../../shared/hooks';
import { hasKey, t } from '../../shared/i18n';
import type {
    DisputeView,
    OfficerDetail,
    OfficerRun,
    OfficerSearchData,
    OfficerSearchRow,
} from '../../types/oversight';
import type { AdminOfficerProfile, Commendation } from '../../types/profile';
import { CommendationsCard } from '../../officer/components/CommendationsCard';
import { ServiceRecordCard } from '../../officer/components/ServiceRecordCard';
import { CommendDialog } from '../../supervisor/components/CommendDialog';
import './Officers.css';

const endLabel = (reason: string) => (hasKey(`sup.end.${reason}`) ? t(`sup.end.${reason}`) : reason);
const cashLabel = (status: string) =>
    hasKey(`result.cash_status.${status}`) ? t(`result.cash_status.${status}`) : status;
const stateTone = (s: string) => (s === 'completed' ? 'success' : s === 'failed' ? 'danger' : 'grey');
// Date with the year (suspensions can run for years; formatDateTime leaves the year out).
const fullDate = (ts: number | null | undefined) => (ts ? fmtDateTime(ts) : '—');
const badgeDate = (v: unknown) => (typeof v === 'string' ? v.slice(0, 10) : typeof v === 'number' ? fullDate(v) : '');

function useDebounced<T>(value: T, ms: number): T {
    const [v, setV] = useState(value);
    useEffect(() => {
        const id = setTimeout(() => setV(value), ms);
        return () => clearTimeout(id);
    }, [value, ms]);
    return v;
}

function ResultRow({ o, active, onSelect }: { o: OfficerSearchRow; active: boolean; onSelect: () => void }) {
    return (
        <button
            type="button"
            className={active ? 'oversight-off-result is-active' : 'oversight-off-result'}
            onClick={onSelect}
        >
            <span
                className={o.online ? 'oversight-off-result__dot is-online' : 'oversight-off-result__dot'}
                aria-hidden
            />
            <span className="oversight-off-result__who">
                <span className="oversight-off-result__name">{o.name}</span>
                <span className="oversight-off-result__sub">
                    {[o.callsign || t('common.no_callsign'), o.rank].filter(Boolean).join(' · ')}
                </span>
            </span>
            <span className="oversight-off-result__tags">
                {o.suspendedUntil ? (
                    <Badge size="sm" tone="danger">
                        {t('admin.officers.suspended_short')}
                    </Badge>
                ) : null}
                {o.departmentShort ? (
                    <Badge size="sm" variant="outline">
                        {o.departmentShort}
                    </Badge>
                ) : null}
            </span>
        </button>
    );
}

// Profile moderation, commendations and the service record (admin:getOfficerProfile in modules/profile).
type ModAction =
    | { kind: 'review'; what: 'avatar' | 'bio'; decision: 'approve' | 'reject' }
    | { kind: 'clear'; what: 'avatar' | 'bio' }
    | { kind: 'report'; id: number; decision: 'clear' | 'dismiss' }
    | { kind: 'revoke'; commendation: Commendation };

function ProfileModeration({ citizenid, own }: { citizenid: string; own: boolean }) {
    const { data: p, refetch } = useRequest<AdminOfficerProfile>('admin:getOfficerProfile', { citizenid });
    const { run, busy } = useAction();
    const [mod, setMod] = useState<ModAction | null>(null);
    const [commending, setCommending] = useState(false);
    if (!p) return null;

    const doMod = async (reason: string) => {
        if (!mod) return;
        let res;
        if (mod.kind === 'review') {
            res = await run('server:admin:reviewAvatar', { citizenid, decision: mod.decision, reason, what: mod.what });
        } else if (mod.kind === 'clear') {
            res = await run('server:admin:clearProfile', { citizenid, what: mod.what, reason });
        } else if (mod.kind === 'report') {
            res = await run('server:admin:handleReport', { id: mod.id, decision: mod.decision, reason });
        } else {
            res = await run('server:admin:revokeCommendation', { id: mod.commendation.id, reason });
        }
        setMod(null);
        if (res.ok) void refetch();
    };
    const reports = asArray(p.reports);

    return (
        <>
            <Grid cols="1fr 1fr" gap={4} align="stretch">
                <Card title={t('admin.officers.profile')} icon="user">
                    <div className="oversight-off-profile">
                        <Avatar avatar={p.avatar} name={p.realName ?? p.name} size={56} />
                        <div className="oversight-off-profile__text">
                            <p className="oversight-off-profile__bio">{p.bio || t('admin.officers.no_bio')}</p>
                            <Row gap={2} wrap>
                                {p.bio && !own ? (
                                    <Button
                                        size="sm"
                                        variant="ghost"
                                        onClick={() => setMod({ kind: 'clear', what: 'bio' })}
                                    >
                                        {t('admin.officers.clear_bio')}
                                    </Button>
                                ) : null}
                                {p.avatar && p.avatar.kind !== 'initials' && !own ? (
                                    <Button
                                        size="sm"
                                        variant="ghost"
                                        onClick={() => setMod({ kind: 'clear', what: 'avatar' })}
                                    >
                                        {t('admin.officers.clear_avatar')}
                                    </Button>
                                ) : null}
                            </Row>
                        </div>
                    </div>
                    {p.pendingAvatar ? (
                        <div className="oversight-off-pending">
                            <Avatar
                                avatar={{ kind: 'url', value: p.pendingAvatar, initials: '?', frame: 'grey' }}
                                size={44}
                            />
                            <span className="oversight-off-pending__text" title={p.pendingAvatar}>
                                {t('admin.officers.pending_avatar')}
                            </span>
                            {!own ? (
                                <Row gap={2}>
                                    <Button
                                        size="sm"
                                        variant="primary"
                                        onClick={() => setMod({ kind: 'review', what: 'avatar', decision: 'approve' })}
                                    >
                                        {t('profile.review.approve')}
                                    </Button>
                                    <Button
                                        size="sm"
                                        variant="danger"
                                        onClick={() => setMod({ kind: 'review', what: 'avatar', decision: 'reject' })}
                                    >
                                        {t('profile.review.reject')}
                                    </Button>
                                </Row>
                            ) : null}
                        </div>
                    ) : null}
                    {p.bioPending ? (
                        <div className="oversight-off-pending">
                            <span className="oversight-off-pending__text">
                                {t('admin.officers.pending_bio', { bio: p.bioPending })}
                            </span>
                            {!own ? (
                                <Row gap={2}>
                                    <Button
                                        size="sm"
                                        variant="primary"
                                        onClick={() => setMod({ kind: 'review', what: 'bio', decision: 'approve' })}
                                    >
                                        {t('profile.review.approve')}
                                    </Button>
                                    <Button
                                        size="sm"
                                        variant="danger"
                                        onClick={() => setMod({ kind: 'review', what: 'bio', decision: 'reject' })}
                                    >
                                        {t('profile.review.reject')}
                                    </Button>
                                </Row>
                            ) : null}
                        </div>
                    ) : null}
                    {reports.map(r => (
                        <div key={r.id} className="oversight-off-pending">
                            <Badge tone="warning" size="sm">
                                {t(`profile.report.reason.${r.reason}`)}
                            </Badge>
                            <span className="oversight-off-pending__text">
                                {[r.note, fmtDateTime(r.at)].filter(Boolean).join(' · ')}
                            </span>
                            {!own ? (
                                <Row gap={2}>
                                    <Button
                                        size="sm"
                                        variant="danger"
                                        onClick={() => setMod({ kind: 'report', id: r.id, decision: 'clear' })}
                                    >
                                        {t('profile.review.clear')}
                                    </Button>
                                    <Button
                                        size="sm"
                                        variant="secondary"
                                        onClick={() => setMod({ kind: 'report', id: r.id, decision: 'dismiss' })}
                                    >
                                        {t('profile.review.dismiss')}
                                    </Button>
                                </Row>
                            ) : null}
                        </div>
                    ))}
                </Card>
                <CommendationsCard
                    commendations={p.commendations}
                    onRevoke={c => setMod({ kind: 'revoke', commendation: c })}
                    onCommend={own ? undefined : () => setCommending(true)}
                />
            </Grid>
            <ServiceRecordCard
                lifetime={p.service?.lifetime}
                season={p.service?.season}
                bests={p.bests}
                partner={p.favouritePartner}
                compact
            />
            <ConfirmDialog
                open={!!mod}
                tone={mod && mod.kind === 'review' && mod.decision === 'approve' ? 'primary' : 'danger'}
                title={mod ? t(`admin.officers.mod_title.${mod.kind}`) : ''}
                message={p.realName ?? p.name}
                reason={{ required: true, maxLength: 255, placeholder: t('admin.officers.reason_placeholder') }}
                onConfirm={doMod}
                onCancel={() => setMod(null)}
                busy={busy}
            />
            <CommendDialog
                open={commending}
                onClose={() => setCommending(false)}
                officer={{ citizenid, name: p.realName ?? p.name }}
                scope="admin"
                onDone={() => void refetch()}
            />
        </>
    );
}

interface SuspendState {
    open: boolean;
    days: number | null;
    reason: string;
}

function Detail({ citizenid }: { citizenid: string }) {
    const { data: o, loading, error, refetch } = useRequest<OfficerDetail>('admin:getOfficer', { citizenid });
    const { run, busy } = useAction();
    const [suspend, setSuspend] = useState<SuspendState>({ open: false, days: 7, reason: '' });
    const [unsuspend, setUnsuspend] = useState(false);
    const [award, setAward] = useState<{ dispute: DisputeView; points: number | null; reason: string } | null>(null);
    const [dismiss, setDismiss] = useState<DisputeView | null>(null);
    const [review, setReview] = useState<{ dispute: DisputeView; decision: 'approve' | 'reject' } | null>(null);
    const [voidRow, setVoidRow] = useState<OfficerRun | null>(null);

    if (loading && !o) return <LoadingBlock />;
    if (error && !o)
        return (
            <Card>
                <ErrorState error={error} onRetry={() => void refetch()} />
            </Card>
        );
    if (!o) return null;

    const disputes = asArray(o.disputes);
    const runs = asArray(o.runs);
    const badges = asArray(o.badges);
    const suspensions = asArray(o.suspensions);
    const suspension = o.suspension ?? { suspended: false, untilTs: null };
    const cash = o.cash ?? { total: 0, week: 0 };
    const stats = o.stats ?? { runs: 0, completed: 0, failed: 0, abandoned: 0, flagged: 0, voided: 0 };
    const level = o.level;
    const levelNext = level && level.next ? level.next : null;

    const doSuspend = async () => {
        if (!suspend.days || !suspend.reason.trim()) return;
        const res = await run(
            'server:admin:suspend',
            { citizenid: o.citizenid, days: suspend.days, reason: suspend.reason.trim() },
            { success: 'admin.officers.suspended_toast', successVars: { name: o.name, days: suspend.days } },
        );
        if (res.ok) {
            setSuspend({ open: false, days: 7, reason: '' });
            void refetch();
        }
    };
    const doUnsuspend = async (reason: string) => {
        const res = await run(
            'server:admin:suspend',
            { citizenid: o.citizenid, days: 0, reason },
            { success: 'admin.officers.unsuspended_toast', successVars: { name: o.name } },
        );
        setUnsuspend(false);
        if (res.ok) void refetch();
    };
    const doAward = async () => {
        if (!award || !award.points || !award.reason.trim()) return;
        const res = await run(
            'server:admin:handleDispute',
            {
                disputeId: award.dispute.id,
                decision: 'approve',
                reason: award.reason.trim(),
                awardPoints: award.points,
            },
            { success: 'admin.officers.awarded_toast', successVars: { points: award.points } },
        );
        if (res.ok) {
            setAward(null);
            void refetch();
        }
    };
    const doDismiss = async (reason: string) => {
        if (!dismiss) return;
        const res = await run(
            'server:admin:handleDispute',
            { disputeId: dismiss.id, decision: 'reject', reason },
            { success: 'admin.officers.dismissed_toast' },
        );
        setDismiss(null);
        if (res.ok) void refetch();
    };
    // A flagged or voided run: approve restores the run (held cash released), reject keeps it; never award points.
    const doReview = async (reason: string) => {
        if (!review) return;
        const res = await run(
            'server:admin:handleDispute',
            { disputeId: review.dispute.id, decision: review.decision, reason },
            { success: review.decision === 'approve' ? 'sup.review.dispute_approved' : 'sup.review.dispute_rejected' },
        );
        setReview(null);
        if (res.ok) void refetch();
    };
    const doVoid = async (reason: string) => {
        if (!voidRow) return;
        const res = await run(
            'server:admin:voidRun',
            { rowId: voidRow.id, reason },
            { success: 'admin.officers.voided_toast' },
        );
        setVoidRow(null);
        if (res.ok) void refetch();
    };

    const runColumns: TableColumn<OfficerRun>[] = [
        {
            key: 'mission',
            header: t('admin.officers.col.mission'),
            render: r => (
                <div className="oversight-off-run">
                    <span className="oversight-off-run__name">{r.missionLabel}</span>
                    <span className="oversight-off-run__sub">{r.missionTypeLabel}</span>
                </div>
            ),
        },
        {
            key: 'result',
            header: t('admin.officers.col.result'),
            width: 172,
            render: r => (
                <div className="oversight-off-result-cell">
                    <Row gap={1} wrap>
                        <Badge size="sm" tone={stateTone(r.state)}>
                            {t(`sup.state.${r.state}`)}
                        </Badge>
                        {r.flagged ? (
                            <Badge size="sm" tone="warning" icon="flag">
                                {r.flagReason && hasKey(`flag.${r.flagReason}`)
                                    ? t(`flag.${r.flagReason}`)
                                    : t('flag.flagged')}
                            </Badge>
                        ) : null}
                        {r.voided ? (
                            <Badge size="sm" tone="danger">
                                {t('admin.officers.voided')}
                            </Badge>
                        ) : null}
                    </Row>
                    {r.state !== 'completed' ? (
                        <span className="oversight-off-soft">{endLabel(r.endReason)}</span>
                    ) : null}
                </div>
            ),
        },
        {
            key: 'points',
            header: t('admin.officers.col.points'),
            width: 74,
            numeric: true,
            render: r => <Points value={r.points} />,
        },
        {
            key: 'cash',
            header: t('admin.officers.col.cash'),
            width: 106,
            numeric: true,
            render: r => (
                <div className="oversight-off-cash">
                    <Money amount={r.cashPaid > 0 ? r.cashPaid : r.cash} />
                    <span className="oversight-off-soft">{cashLabel(r.cashStatus)}</span>
                </div>
            ),
        },
        {
            key: 'date',
            header: t('admin.officers.col.date'),
            width: 104,
            render: r => (
                <span className="cp-num oversight-off-soft oversight-off-nowrap">{formatDateTime(r.createdAt)}</span>
            ),
        },
        {
            key: 'actions',
            header: '',
            width: 66,
            align: 'right',
            render: r =>
                !r.voided && !o.own ? (
                    <Button size="sm" variant="ghost" className="oversight-off-void" onClick={() => setVoidRow(r)}>
                        {t('admin.officers.void')}
                    </Button>
                ) : null,
        },
    ];

    return (
        <div className="oversight-off-detail">
            <Card className="oversight-off-head" padding="md">
                <div className="oversight-off-head__row">
                    <span className="oversight-off-head__avatar" aria-hidden>
                        <Icon name="user" size={24} />
                    </span>
                    <div className="oversight-off-head__who">
                        <div className="oversight-off-head__name">
                            {o.name}
                            {level ? <XpBadge badge={level.badge} label={level.label} size="sm" /> : null}
                        </div>
                        <div className="oversight-off-head__line">
                            {[
                                o.rank,
                                o.callsign || t('common.no_callsign'),
                                o.departmentLabel || o.departmentShort || t('admin.officers.no_department'),
                            ]
                                .filter(Boolean)
                                .join(' · ')}
                        </div>
                        <div className="oversight-off-head__cid">{o.citizenid}</div>
                    </div>
                    <div className="oversight-off-head__tags">
                        <Badge tone={o.online ? 'success' : 'grey'} dot>
                            {o.online ? t('admin.officers.online') : t('admin.officers.offline')}
                        </Badge>
                        {suspension.suspended ? (
                            <Badge tone="danger" icon="lock">
                                {t('admin.officers.suspended_short')}
                            </Badge>
                        ) : null}
                        {o.streakDays > 0 ? (
                            <Badge tone="accent" icon="flame">
                                {t('admin.officers.streak', { n: o.streakDays })}
                            </Badge>
                        ) : null}
                        {loading ? <Spinner size={16} /> : null}
                    </div>
                </div>
                {o.own ? (
                    <div className="oversight-off-own">
                        <Icon name="info" size={14} />
                        {t('admin.officers.own')}
                    </div>
                ) : null}
                {!o.known ? (
                    <div className="oversight-off-own">
                        <Icon name="info" size={14} />
                        {t('admin.officers.unknown_row')}
                    </div>
                ) : null}
            </Card>

            <div className="oversight-off-stats">
                <Card padding="sm">
                    <Stat
                        size="sm"
                        icon="star"
                        tone="accent"
                        label={t('admin.officers.stat.xp')}
                        value={formatNumber(o.xp)}
                        hint={
                            levelNext
                                ? t('admin.officers.stat.next', { xp: formatNumber(levelNext) })
                                : level
                                  ? level.label
                                  : undefined
                        }
                    />
                </Card>
                <Card padding="sm">
                    <Stat
                        size="sm"
                        icon="dollar"
                        label={t('admin.officers.stat.cash_total')}
                        value={<Money amount={cash.total} />}
                    />
                </Card>
                <Card padding="sm">
                    <Stat
                        size="sm"
                        icon="calendar"
                        label={t('admin.officers.stat.cash_week')}
                        value={<Money amount={cash.week} />}
                    />
                </Card>
                <Card padding="sm">
                    <Stat
                        size="sm"
                        icon="activity"
                        label={t('admin.officers.stat.runs')}
                        value={formatNumber(stats.runs)}
                        hint={t('admin.officers.stat.runs_hint', {
                            completed: stats.completed,
                            failed: stats.failed,
                            abandoned: stats.abandoned,
                        })}
                    />
                </Card>
            </div>

            <ProfileModeration citizenid={o.citizenid} own={!!o.own} />

            <Grid cols="1fr 1fr" gap={4} align="stretch">
                <Card
                    title={t('admin.officers.suspension')}
                    icon="lock"
                    highlight={suspension.suspended ? 'danger' : undefined}
                >
                    <div className="oversight-off-susp">
                        {suspension.suspended ? (
                            <>
                                <div className="oversight-off-susp__state is-on">
                                    {t('admin.officers.suspended_until', { date: fullDate(suspension.untilTs) })}
                                </div>
                                <div className="oversight-off-soft">{t('admin.officers.suspended_text')}</div>
                                <Row gap={2}>
                                    <Button
                                        variant="secondary"
                                        icon="check"
                                        onClick={() => setUnsuspend(true)}
                                        disabled={busy}
                                    >
                                        {t('admin.officers.unsuspend')}
                                    </Button>
                                    <Button
                                        variant="ghost"
                                        onClick={() => setSuspend({ open: true, days: 7, reason: '' })}
                                        disabled={busy}
                                    >
                                        {t('admin.officers.extend')}
                                    </Button>
                                </Row>
                            </>
                        ) : (
                            <>
                                <div className="oversight-off-susp__state">{t('admin.officers.not_suspended')}</div>
                                <div className="oversight-off-soft">
                                    {t('admin.officers.stat.flag_hint', {
                                        flagged: stats.flagged,
                                        voided: stats.voided,
                                    })}
                                </div>
                                <Row gap={2}>
                                    <Button
                                        variant="danger"
                                        icon="lock"
                                        onClick={() => setSuspend({ open: true, days: 7, reason: '' })}
                                        disabled={busy}
                                    >
                                        {t('admin.officers.suspend')}
                                    </Button>
                                </Row>
                            </>
                        )}
                        <div className="oversight-off-susp-hist">
                            <span className="oversight-off-susp-hist__title">{t('admin.officers.susp_history')}</span>
                            {suspensions.length ? (
                                <ul>
                                    {suspensions.map(h => (
                                        <li key={h.id}>
                                            <Badge
                                                size="sm"
                                                tone={
                                                    h.action === 'unsuspend'
                                                        ? 'success'
                                                        : h.action === 'autoSuspend'
                                                          ? 'warning'
                                                          : 'danger'
                                                }
                                            >
                                                {hasKey(`admin.officers.susp_action.${h.action}`)
                                                    ? t(`admin.officers.susp_action.${h.action}`)
                                                    : h.action}
                                            </Badge>
                                            <span className="oversight-off-susp-hist__main">
                                                <span className="oversight-off-susp-hist__line">
                                                    {h.days ? (
                                                        <strong className="cp-num">
                                                            {t('admin.officers.susp_days', { n: h.days })}
                                                        </strong>
                                                    ) : null}
                                                    <span className="oversight-off-soft">
                                                        {t('admin.officers.susp_by', {
                                                            who:
                                                                h.action === 'autoSuspend'
                                                                    ? t('admin.officers.susp_system')
                                                                    : h.actor === 'console'
                                                                      ? t('admin.actor.console')
                                                                      : h.actorName || h.actor,
                                                            date: fullDate(h.createdAt),
                                                        })}
                                                    </span>
                                                </span>
                                                {h.reason ? (
                                                    <span className="oversight-off-susp-hist__reason" title={h.reason}>
                                                        {h.reason}
                                                    </span>
                                                ) : null}
                                            </span>
                                        </li>
                                    ))}
                                </ul>
                            ) : (
                                <span className="oversight-off-soft">{t('admin.officers.susp_none')}</span>
                            )}
                        </div>
                    </div>
                </Card>
                <Card
                    title={t('admin.officers.badges')}
                    icon="medal"
                    subtitle={t('admin.officers.badges_count', { n: badges.length })}
                >
                    {badges.length ? (
                        <div className="oversight-off-badges">
                            {badges.map(b => (
                                <span key={b.id} className="oversight-off-badge" title={String(b.earnedAt ?? '')}>
                                    <Icon name="medal" size={14} />
                                    <span>{b.label}</span>
                                    <span className="oversight-off-soft">{badgeDate(b.earnedAt)}</span>
                                </span>
                            ))}
                        </div>
                    ) : (
                        <EmptyState compact icon="medal" title={t('admin.officers.no_badges')} />
                    )}
                </Card>
            </Grid>

            <Card
                title={t('admin.officers.disputes')}
                icon="inbox"
                subtitle={t('admin.officers.disputes_hint')}
                padding="md"
            >
                {disputes.length ? (
                    <ul className="oversight-off-disputes">
                        {disputes.map(d => (
                            <li key={d.id} className="oversight-off-dispute">
                                <div className="oversight-off-dispute__main">
                                    <div className="oversight-off-dispute__title">
                                        <strong>{d.missionLabel}</strong>
                                        <span className="oversight-off-soft">{formatDateTime(d.runAt)}</span>
                                        {d.kind !== 'failed' ? (
                                            <Badge size="sm" variant="outline">
                                                {t(`admin.officers.dispute_kind.${d.kind}`)}
                                            </Badge>
                                        ) : null}
                                        <Badge
                                            size="sm"
                                            tone={
                                                d.status === 'open'
                                                    ? 'warning'
                                                    : d.status === 'approved'
                                                      ? 'success'
                                                      : 'grey'
                                            }
                                        >
                                            {t(
                                                d.kind === 'failed'
                                                    ? `admin.officers.dispute_status.${d.status}`
                                                    : `admin.officers.review_status.${d.status}`,
                                            )}
                                        </Badge>
                                    </div>
                                    <div className="oversight-off-dispute__reason">“{d.reason}”</div>
                                    <div className="oversight-off-soft">
                                        {t('admin.officers.dispute_meta', {
                                            date: formatDateTime(d.createdAt),
                                            points: d.points,
                                            end: endLabel(d.endReason),
                                        })}
                                    </div>
                                    {d.decisions ? <DecisionsBlock decisions={d.decisions} detail /> : null}
                                    {d.people ? <PeopleBlock people={d.people} /> : null}
                                </div>
                                {d.status === 'open' && d.kind === 'failed' ? (
                                    <Row gap={2}>
                                        <Button
                                            size="sm"
                                            variant="primary"
                                            icon="plus"
                                            disabled={!d.canHandle || busy}
                                            onClick={() => setAward({ dispute: d, points: 25, reason: '' })}
                                        >
                                            {t('admin.officers.award')}
                                        </Button>
                                        <Button
                                            size="sm"
                                            variant="ghost"
                                            disabled={!d.canHandle || busy}
                                            onClick={() => setDismiss(d)}
                                        >
                                            {t('admin.officers.dismiss')}
                                        </Button>
                                    </Row>
                                ) : d.status === 'open' ? (
                                    <Row gap={2}>
                                        <Button
                                            size="sm"
                                            variant="primary"
                                            icon="check"
                                            disabled={!d.canHandle || busy}
                                            onClick={() => setReview({ dispute: d, decision: 'approve' })}
                                        >
                                            {t('sup.review.approve')}
                                        </Button>
                                        <Button
                                            size="sm"
                                            variant="ghost"
                                            icon="x"
                                            disabled={!d.canHandle || busy}
                                            onClick={() => setReview({ dispute: d, decision: 'reject' })}
                                        >
                                            {t('sup.review.reject')}
                                        </Button>
                                    </Row>
                                ) : null}
                            </li>
                        ))}
                    </ul>
                ) : (
                    <EmptyState compact icon="inbox" title={t('admin.officers.no_disputes')} />
                )}
            </Card>

            <Card
                title={t('admin.officers.runs')}
                icon="list"
                subtitle={t('admin.officers.runs_hint', { n: runs.length })}
                padding="none"
            >
                <Table
                    columns={runColumns}
                    rows={runs}
                    rowKey={r => r.id}
                    dense
                    className="oversight-off-table"
                    empty={t('admin.officers.no_runs')}
                />
            </Card>

            <Dialog
                open={suspend.open}
                onClose={() => setSuspend(s => ({ ...s, open: false }))}
                size="sm"
                title={t('admin.officers.suspend_title', { name: o.name })}
                description={t('admin.officers.suspend_message')}
                footer={
                    <>
                        <Button
                            variant="ghost"
                            onClick={() => setSuspend(s => ({ ...s, open: false }))}
                            disabled={busy}
                        >
                            {t('common.cancel')}
                        </Button>
                        <Button
                            variant="danger"
                            icon="lock"
                            loading={busy}
                            disabled={!suspend.days || !suspend.reason.trim()}
                            onClick={() => void doSuspend()}
                        >
                            {t('admin.officers.suspend')}
                        </Button>
                    </>
                }
            >
                <div className="oversight-off-form">
                    <Field label={t('admin.officers.days')} required>
                        <NumberInput
                            value={suspend.days}
                            onChange={v => setSuspend(s => ({ ...s, days: v }))}
                            min={1}
                            max={3650}
                            step={1}
                            showRange
                            stepper
                            suffix={t('admin.officers.days_suffix')}
                        />
                    </Field>
                    <Field label={t('common.reason')} required>
                        <Textarea
                            value={suspend.reason}
                            onChange={v => setSuspend(s => ({ ...s, reason: v }))}
                            maxLength={255}
                            rows={3}
                            placeholder={t('admin.officers.reason_placeholder')}
                        />
                    </Field>
                </div>
            </Dialog>

            <ConfirmDialog
                open={unsuspend}
                title={t('admin.officers.unsuspend_title')}
                message={t('admin.officers.unsuspend_message', { name: o.name })}
                confirmLabel={t('admin.officers.unsuspend')}
                reason={{ required: true, maxLength: 255, placeholder: t('admin.officers.reason_placeholder') }}
                onConfirm={doUnsuspend}
                onCancel={() => setUnsuspend(false)}
                busy={busy}
            />

            <Dialog
                open={!!award}
                onClose={() => setAward(null)}
                size="sm"
                title={t('admin.officers.award_title')}
                description={
                    award
                        ? t('admin.officers.award_message', { name: o.name, mission: award.dispute.missionLabel })
                        : undefined
                }
                footer={
                    <>
                        <Button variant="ghost" onClick={() => setAward(null)} disabled={busy}>
                            {t('common.cancel')}
                        </Button>
                        <Button
                            variant="primary"
                            icon="plus"
                            loading={busy}
                            disabled={!award?.points || !award?.reason.trim()}
                            onClick={() => void doAward()}
                        >
                            {t('admin.officers.award')}
                        </Button>
                    </>
                }
            >
                {award ? (
                    <div className="oversight-off-form">
                        <div className="oversight-off-quote">“{award.dispute.reason}”</div>
                        <Field label={t('admin.officers.award_points')} required>
                            <NumberInput
                                value={award.points}
                                onChange={v => setAward(a => (a ? { ...a, points: v } : a))}
                                min={1}
                                max={o.maxAward || 10000}
                                step={5}
                                showRange
                                stepper
                                suffix={t('common.pts')}
                            />
                        </Field>
                        <Field label={t('common.reason')} required>
                            <Textarea
                                value={award.reason}
                                onChange={v => setAward(a => (a ? { ...a, reason: v } : a))}
                                maxLength={255}
                                rows={3}
                                placeholder={t('admin.officers.reason_placeholder')}
                            />
                        </Field>
                    </div>
                ) : null}
            </Dialog>

            <ConfirmDialog
                open={!!dismiss}
                tone="danger"
                title={t('admin.officers.dismiss_title')}
                message={t('admin.officers.dismiss_message')}
                confirmLabel={t('admin.officers.dismiss')}
                reason={{ required: true, maxLength: 255, placeholder: t('admin.officers.reason_placeholder') }}
                onConfirm={doDismiss}
                onCancel={() => setDismiss(null)}
                busy={busy}
            />

            <ConfirmDialog
                open={!!review}
                tone={review?.decision === 'reject' ? 'danger' : 'primary'}
                title={
                    review
                        ? t(
                              review.decision === 'approve'
                                  ? 'sup.review.dispute_approve_title'
                                  : 'sup.review.dispute_reject_title',
                          )
                        : ''
                }
                message={
                    review
                        ? t(
                              review.decision === 'approve'
                                  ? 'sup.review.dispute_approve_message'
                                  : 'sup.review.dispute_reject_message',
                              { name: o.name, mission: review.dispute.missionLabel },
                          )
                        : null
                }
                confirmLabel={review?.decision === 'reject' ? t('sup.review.reject') : t('sup.review.approve')}
                reason={{ required: true, maxLength: 255, placeholder: t('admin.officers.reason_placeholder') }}
                onConfirm={doReview}
                onCancel={() => setReview(null)}
                busy={busy}
            />

            <ConfirmDialog
                open={!!voidRow}
                tone="danger"
                title={t('admin.officers.void_title')}
                message={
                    voidRow
                        ? t('admin.officers.void_message', {
                              mission: voidRow.missionLabel,
                              date: formatDateTime(voidRow.createdAt),
                          })
                        : null
                }
                confirmLabel={t('admin.officers.void')}
                reason={{ required: true, maxLength: 255, placeholder: t('admin.officers.reason_placeholder') }}
                onConfirm={doVoid}
                onCancel={() => setVoidRow(null)}
                busy={busy}
            />
        </div>
    );
}

export default function AdminOfficers() {
    const [query, setQuery] = useState('');
    const debounced = useDebounced(query.trim(), 300);
    const { data, loading, error, refetch } = useRequest<OfficerSearchData>('admin:searchOfficers', {
        query: debounced,
    });
    const [selected, setSelected] = useState<string | null>(null);
    const officers = asArray(data?.officers);

    return (
        <Screen
            title={t('ui.screen.admin_officers')}
            subtitle={t('admin.officers.subtitle')}
            className="oversight-screen"
        >
            <div className="oversight-off-layout">
                <Card padding="none" className="oversight-off-list">
                    <div className="oversight-off-list__search">
                        <SearchInput
                            value={query}
                            onChange={setQuery}
                            placeholder={t('admin.officers.search_placeholder')}
                            aria-label={t('admin.officers.search_placeholder')}
                            autoFocus
                        />
                    </div>
                    <div className="oversight-off-list__head">
                        <span>
                            {debounced
                                ? t('admin.officers.results_for', { n: officers.length })
                                : t('admin.officers.results')}
                        </span>
                        {loading ? (
                            <Spinner size={14} />
                        ) : (
                            <IconButton
                                icon="refresh"
                                size="sm"
                                label={t('sup.refresh')}
                                onClick={() => void refetch()}
                            />
                        )}
                    </div>
                    <div className="oversight-off-list__items">
                        {error && !data ? (
                            <ErrorState compact error={error} onRetry={() => void refetch()} />
                        ) : !officers.length && !loading ? (
                            <EmptyState compact icon="search" title={t('admin.officers.no_results')} />
                        ) : (
                            officers.map(o => (
                                <ResultRow
                                    key={o.citizenid}
                                    o={o}
                                    active={o.citizenid === selected}
                                    onSelect={() => setSelected(o.citizenid)}
                                />
                            ))
                        )}
                    </div>
                </Card>
                <div className="oversight-off-main">
                    {selected ? (
                        <Detail key={selected} citizenid={selected} />
                    ) : (
                        <Card padding="none">
                            <EmptyState
                                icon="user"
                                title={t('admin.officers.select_title')}
                                text={t('admin.officers.select_text')}
                            />
                        </Card>
                    )}
                </div>
            </div>
        </Screen>
    );
}
