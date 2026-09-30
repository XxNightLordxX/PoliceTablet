// Officer UI · Dispatch (screen key 'dispatch'): mission calls. A call names a type, a priority and an area, never
// a mission; the mission is drawn at random after the claim. Mission calls never reach SC-Dispatch.

import { useEffect, useMemo, useState } from 'react';
import {
    Badge,
    Button,
    Card,
    ConfirmDialog,
    Countdown,
    EmptyState,
    ErrorState,
    Icon,
    LoadingBlock,
    MoneyRange,
    Points,
    Screen,
    SegmentedControl,
    Toggle,
} from '../../shared/components';
import type { BadgeTone, IconName } from '../../shared/components';
import { cx } from '../../shared/cx';
import { asArray } from '../../shared/data';
import { formatDistance } from '../../shared/format';
import { useAction, usePush, useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { useNavigate } from '../../shared/navigation';
import { useSession } from '../../shared/session';
import { toast } from '../../shared/toast';
import type { ClaimCallResult, DispatchView, MissionCall, RecentCall } from '../../types/missioncalls';
import './Dispatch.css';

const POLL_MS = 15000;
// "Near me": calls whose area (or nearest eligible area) is within this many metres.
const NEAR_M = 3000;
// The officer's own profile setting (cp_officers.calls_muted); the action belongs to the profile module.
const PROFILE_SET = 'server:profile:set';

type Filter = 'all' | 'claimable' | 'near';

const PRIORITY_TONE: Record<number, BadgeTone> = { 1: 'danger', 2: 'warning', 3: 'primary' };
const TYPE_ICONS: Record<string, IconName> = {
    patrol: 'car',
    training: 'target',
    investigation: 'search',
    tactical: 'shield',
};

// ============================================================================
//                                   HELPERS
// ============================================================================

function areaText(call: MissionCall): string {
    return call.area ? call.area.label : t('mc.county_wide');
}

function distanceText(call: MissionCall): string | null {
    if (call.distance === null || call.distance === undefined) return null;
    const km = formatDistance(call.distance);
    return call.area ? t('mc.card.distance_area', { distance: km }) : t('mc.card.distance_county', { distance: km });
}

function crewText(call: MissionCall): string {
    if (call.crew === 'solo') return t('mc.card.crew_solo');
    if (call.crew === 'unit') return t('mc.card.crew_unit');
    return call.minUnit ? t('mc.card.crew_needs', { n: call.minUnit }) : t('mc.card.crew_none');
}

function lostText(call: MissionCall): string | null {
    if (!call.lostBy || !call.claimedBy) return null;
    return t(`mc.status.lost_${call.lostBy}`, {
        callsign: call.claimedBy.callsign ?? '?',
        department: call.claimedBy.departmentShort,
    });
}

function outcomeText(r: RecentCall): string {
    return r.outcome ? t(`mc.outcome.${r.outcome}`) : t('mc.outcome.unknown');
}

// ============================================================================
//                                    PIECES
// ============================================================================

function Notice({ icon, tone, title, text }: { icon: IconName; tone: string; title: string; text?: string }) {
    return (
        <div className={cx('mc-notice', `mc-notice--${tone}`)} role="status">
            <Icon name={icon} size={16} />
            <span className="mc-notice__text">
                <span className="mc-notice__title">{title}</span>
                {text ? <span className="mc-notice__sub">{text}</span> : null}
            </span>
        </div>
    );
}

function StatusLine({ call, stamp, onChanged }: { call: MissionCall; stamp: number; onChanged: () => void }) {
    if (call.status === 'priority') {
        return (
            <span className="mc-status mc-status--priority">
                <Icon name="navigation" size={13} />
                {t('mc.status.priority')}
                <Countdown seconds={call.priorityEndsIn} resetKey={stamp} onDone={onChanged} />
            </span>
        );
    }
    if (call.status === 'claiming') {
        return (
            <span className="mc-status mc-status--claiming">
                <Icon name="clock" size={13} />
                {t('mc.status.claiming', { callsign: call.claiming?.callsign ?? '?' })}
                {call.claiming ? <Countdown seconds={call.claiming.expiresIn} resetKey={stamp} /> : null}
            </span>
        );
    }
    if (call.status === 'claimed') {
        const lost = lostText(call);
        return (
            <span className="mc-status mc-status--claimed">
                <Icon name="check" size={13} />
                {lost ??
                    t('mc.status.claimed', {
                        callsign: call.claimedBy?.callsign ?? '?',
                        department: call.claimedBy?.departmentShort ?? '',
                    })}
            </span>
        );
    }
    if (call.status === 'lapsed') {
        return (
            <span className="mc-status mc-status--lapsed">
                <Icon name="minusCircle" size={13} />
                {t('mc.status.lapsed')}
            </span>
        );
    }
    if (call.status === 'locked') {
        return (
            <span className="mc-status mc-status--locked">
                <Icon name="lock" size={13} />
                {call.locked?.reason || t('mc.status.locked')}
            </span>
        );
    }
    return (
        <span className="mc-status mc-status--ready">
            <Icon name="checkCircle" size={13} />
            {call.redispatched ? t('mc.status.redispatched') : t('mc.status.ready')}
        </span>
    );
}

function CallCard({
    call,
    stamp,
    busy,
    blocked,
    onClaim,
    onChanged,
}: {
    call: MissionCall;
    stamp: number;
    busy: boolean;
    blocked: boolean;
    onClaim: (call: MissionCall) => void;
    onChanged: () => void;
}) {
    const distance = distanceText(call);
    const canClaim = call.status === 'ready' && !blocked;
    return (
        <Card
            padding="none"
            className={cx('mc-card', `mc-card--p${call.priority}`, call.status !== 'ready' && 'is-muted')}
            highlight={call.priority === 1 ? 'danger' : undefined}
        >
            <div className="mc-card__head">
                <span className="mc-card__icon" aria-hidden>
                    <Icon name={TYPE_ICONS[call.type] ?? 'radio'} size={18} />
                </span>
                <div className="mc-card__titles">
                    <div className="mc-card__line">
                        <span className="mc-card__code cp-num">{call.code}</span>
                        <Badge size="sm" tone={PRIORITY_TONE[call.priority] ?? 'neutral'} variant="solid">
                            {t('mc.card.priority', { n: call.priority })}
                        </Badge>
                        <Badge size="sm" variant="outline" icon="layers">
                            {call.typeLabel}
                        </Badge>
                        {call.typeOfTheDay ? (
                            <Badge size="sm" tone="accent" icon="zap">
                                {t('board.card.tod')}
                            </Badge>
                        ) : null}
                        {call.redispatched ? (
                            <Badge size="sm" tone="warning" icon="refresh">
                                {t('mc.card.redispatched')}
                            </Badge>
                        ) : null}
                        {call.paged ? (
                            <Badge size="sm" tone="primary" icon="bell">
                                {t('mc.card.paged')}
                            </Badge>
                        ) : null}
                    </div>
                    <div className="mc-card__title">{t(call.titleKey)}</div>
                    <div className="mc-card__meta">
                        <span>
                            <Icon name="mapPin" size={12} /> {areaText(call)}
                        </span>
                        {distance ? (
                            <span>
                                <Icon name="navigation" size={12} /> {distance}
                            </span>
                        ) : null}
                        <span>
                            <Icon name="users" size={12} /> {crewText(call)}
                        </span>
                    </div>
                </div>
                <div className="mc-card__offer">
                    <span className="mc-card__offer-label">{t('mc.card.offer')}</span>
                    {call.status === 'ready' || call.status === 'priority' || call.status === 'locked' ? (
                        <Countdown
                            seconds={call.offerEndsIn}
                            resetKey={stamp}
                            warnBelow={60}
                            dangerBelow={20}
                            onDone={onChanged}
                        />
                    ) : (
                        <span className="mc-card__offer-none">–</span>
                    )}
                </div>
            </div>
            <div className="mc-card__pay">
                <MoneyRange range={asArray(call.cash as number[])} />
                <span className="mc-card__sep">·</span>
                <Points value={call.points} />
                {call.rapidPoints > 0 ? (
                    <span className="mc-card__rapid" title={t('mc.card.rapid_hint')}>
                        <Icon name="zap" size={12} />
                        {t('mc.card.rapid', { n: call.rapidPoints })}
                    </span>
                ) : call.staff ? (
                    <span className="mc-card__rapid is-off">{t('mc.card.staff')}</span>
                ) : null}
            </div>
            <div className="mc-card__foot">
                <StatusLine call={call} stamp={stamp} onChanged={onChanged} />
                <Button
                    variant={canClaim ? 'primary' : 'secondary'}
                    icon="radio"
                    size="sm"
                    disabled={!canClaim || busy}
                    onClick={() => onClaim(call)}
                >
                    {t('mc.card.claim')}
                </Button>
            </div>
        </Card>
    );
}

function RecentList({ recent }: { recent: RecentCall[] }) {
    return (
        <Card title={t('mc.recent.title')} icon="clock" padding="none" className="mc-recent">
            {recent.length === 0 ? (
                <EmptyState compact icon="inbox" title={t('mc.recent.empty')} />
            ) : (
                <ul className="mc-recent__list">
                    {recent.map(r => (
                        <li key={`${r.code}-${r.at}`} className="mc-recent__row">
                            <span className="mc-recent__code cp-num">{r.code}</span>
                            <span className="mc-recent__type">{r.typeLabel}</span>
                            <span className="mc-recent__by">{r.claimedBy ?? t('mc.recent.nobody')}</span>
                            <Badge size="sm" tone={r.outcome === 'completed' ? 'success' : 'neutral'}>
                                {outcomeText(r)}
                            </Badge>
                        </li>
                    ))}
                </ul>
            )}
        </Card>
    );
}

// ============================================================================
//                                    SCREEN
// ============================================================================

export default function Dispatch() {
    const session = useSession();
    const navigate = useNavigate();
    const { data, loading, error, refetch, setData } = useRequest<DispatchView>(
        'getMissionCalls',
        {},
        { pollMs: POLL_MS },
    );
    usePush<DispatchView>('calls', view => {
        if (view && typeof view === 'object') setData(view);
    });
    const { run, busy } = useAction();
    const [filter, setFilter] = useState<Filter>('all');
    const [pending, setPending] = useState<MissionCall | null>(null);
    const [muted, setMuted] = useState<boolean>(!!session.prefs?.callsMuted);
    const [stamp, setStamp] = useState(0);
    useEffect(() => {
        if (data) setStamp(s => s + 1);
    }, [data]);

    const calls = asArray(data?.calls as MissionCall[] | undefined);
    const shown = useMemo(() => {
        if (filter === 'claimable') return calls.filter(c => c.status === 'ready');
        if (filter === 'near') return calls.filter(c => c.distance !== null && c.distance <= NEAR_M);
        return calls;
    }, [calls, filter]);
    const blocked = !!data?.activeRunId || !!data?.onCall || !!data?.operation || !data?.unit?.isLeader;
    const refresh = () => void refetch();

    const claim = async () => {
        if (!pending) return;
        const call = pending;
        const res = await run<ClaimCallResult>('server:claimMissionCall', { callId: call.id });
        setPending(null);
        if (res.ok && res.data?.runId) navigate('active');
        else if (res.ok && res.data?.pending) toast('info', t('mc.toast.ready_check', { code: call.code }));
        void refetch();
    };

    const toggleMute = async (next: boolean) => {
        setMuted(next);
        const res = await run(PROFILE_SET, { callsMuted: next }, { success: next ? 'mc.mute.on' : 'mc.mute.off' });
        if (!res.ok) setMuted(!next);
    };

    const real = data?.realCalls ?? null;

    return (
        <Screen
            title={t('ui.screen.dispatch')}
            subtitle={t('mc.subtitle')}
            className="mc-screen"
            actions={
                <Toggle checked={muted} onChange={v => void toggleMute(v)} label={t('mc.mute.label')} disabled={busy} />
            }
        >
            {!data && loading ? <LoadingBlock /> : null}
            {!data && !loading && error ? <ErrorState error={error} onRetry={refresh} /> : null}
            {data ? (
                <>
                    {real ? (
                        <div className="mc-real" role="status">
                            <Icon name="radio" size={14} />
                            <span>{t('mc.real.strip', { total: real.total, p1: real.p1 })}</span>
                        </div>
                    ) : null}
                    {data.activeRunId ? (
                        <Notice
                            icon="target"
                            tone="info"
                            title={t('mc.notice.on_run')}
                            text={t('mc.notice.on_run_text')}
                        />
                    ) : null}
                    {data.onCall ? (
                        <Notice
                            icon="radio"
                            tone="warning"
                            title={t('mc.notice.on_call')}
                            text={t('mc.notice.on_call_text')}
                        />
                    ) : null}
                    {data.operation ? (
                        <Notice
                            icon="globe"
                            tone="accent"
                            title={t('mc.notice.operation')}
                            text={t('mc.notice.operation_text', { mission: data.operation.missionLabel })}
                        />
                    ) : null}
                    {!data.unit.isLeader ? (
                        <Notice icon="users" tone="neutral" title={t('mc.notice.not_leader')} />
                    ) : null}
                    <div className="mc-toolbar">
                        <SegmentedControl<Filter>
                            size="sm"
                            value={filter}
                            onChange={setFilter}
                            items={[
                                { key: 'all', label: t('mc.filter.all') },
                                { key: 'claimable', label: t('mc.filter.claimable') },
                                { key: 'near', label: t('mc.filter.near') },
                            ]}
                        />
                        <span className="mc-toolbar__count">{t('mc.count', { n: shown.length })}</span>
                    </div>
                    {shown.length ? (
                        <div className="mc-list">
                            {shown.map(c => (
                                <CallCard
                                    key={c.id}
                                    call={c}
                                    stamp={stamp}
                                    busy={busy}
                                    blocked={blocked}
                                    onClaim={setPending}
                                    onChanged={() => setTimeout(refresh, 400)}
                                />
                            ))}
                        </div>
                    ) : (
                        <Card>
                            <EmptyState icon="radio" title={t('mc.empty.title')} text={t('mc.empty.text')} />
                        </Card>
                    )}
                    <RecentList recent={asArray(data.recent as RecentCall[] | undefined)} />
                    <p className="mc-footnote">
                        <Icon name="info" size={13} />
                        <span>{t('mc.footnote')}</span>
                    </p>
                </>
            ) : null}
            <ConfirmDialog
                open={pending !== null}
                title={pending ? t('mc.confirm.title', { code: pending.code }) : ''}
                message={
                    pending ? (
                        <div className="mc-confirm">
                            <p>{t('mc.confirm.random', { type: pending.typeLabel })}</p>
                            <p className="mc-confirm__warn">
                                <Icon name="alert" size={14} />
                                <span>{t('mc.confirm.abandon', { type: pending.typeLabel })}</span>
                            </p>
                        </div>
                    ) : null
                }
                confirmLabel={t('mc.confirm.claim')}
                onConfirm={claim}
                onCancel={() => setPending(null)}
                busy={busy}
            />
        </Screen>
    );
}
