// Officer UI · Active Mission (screen key 'active', title key 'ui.screen.active') · run_ui slice.

import { useEffect, useState, type ReactNode } from 'react';
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
    Money,
    Points,
    Screen,
    TierBadge,
    TIER_ORDER,
} from '../../shared/components';
import type { IconName } from '../../shared/components';
import { cx } from '../../shared/cx';
import { asArray } from '../../shared/data';
import { formatDistance } from '../../shared/format';
import { useAction, useCountdown, usePush, useRequest } from '../../shared/hooks';
import { t, tOr } from '../../shared/i18n';
import { useNavigate } from '../../shared/navigation';
import { clientAction } from '../../shared/nui';
import { useSession } from '../../shared/session';
import { toast } from '../../shared/toast';
import type { Session } from '../../shared/types';
import type {
    AbandonResult,
    ActiveMissionData,
    LogResultPayload,
    RecalcRouteResult,
    RunLog,
    RunObjective,
    RunPartner,
    RunRoute,
    SetGpsResult,
} from '../../types/run_ui';
import './MissionBoard.css';
import './ActiveMission.css';

const POLL_MS = 15000;

// ============================================================================
//                                   HELPERS
// ============================================================================

function typeLabel(session: Session, key: string): string {
    const found = asArray(session.config?.missionTypes).find(m => m.key === key);
    return found?.label ?? key;
}

function tierLabel(session: Session, name: string): string {
    const found = asArray(session.config?.tiers).find(x => x.name === name);
    return found?.label ?? tOr(`tier.${name}`, 'common.unknown');
}

function tierIndex(name: string | null | undefined): number {
    return TIER_ORDER.indexOf(String(name) as (typeof TIER_ORDER)[number]);
}

function initials(name: string): string {
    const parts = String(name || '?')
        .trim()
        .split(/\s+/)
        .filter(Boolean);
    const first = parts[0]?.[0] ?? '?';
    const last = parts.length > 1 ? parts[parts.length - 1][0] : '';
    return (first + last).toUpperCase();
}

function isMe(p: RunPartner, view: ActiveMissionData, session: Session): boolean {
    if (typeof view.me === 'number') return p.src === view.me;
    const o = session.officer;
    if (!o) return false;
    return p.name === o.name && (p.callsign ?? null) === (o.callsign ?? null);
}

function errorToast(error: string | undefined) {
    toast('error', t(error || 'err.internal'));
}

// ============================================================================
//                                     HERO
// ============================================================================

function HeroStat({
    icon,
    label,
    children,
    hint,
    tone,
    className,
}: {
    icon: IconName;
    label: string;
    children: ReactNode;
    hint?: ReactNode;
    tone?: 'muted' | 'warning';
    className?: string;
}) {
    return (
        <div className={cx('run_ui-hstat', className)}>
            <span className="run_ui-hstat__label">
                <Icon name={icon} size={13} />
                {label}
            </span>
            <span className="run_ui-hstat__value">{children}</span>
            {hint ? <span className={cx('run_ui-hstat__hint', tone && `is-${tone}`)}>{hint}</span> : null}
        </div>
    );
}

function Hero({
    view,
    session,
    stamp,
    routeCard,
}: {
    view: ActiveMissionData;
    session: Session;
    stamp: unknown;
    routeCard: boolean;
}) {
    const inProgress = view.state === 'in_progress';
    const payLower =
        inProgress &&
        tierIndex(view.payTier) >= 0 &&
        tierIndex(view.tier) >= 0 &&
        tierIndex(view.payTier) < tierIndex(view.tier);
    const hasTimer = view.remaining !== null && view.remaining !== undefined;

    // Accepted: the start timeout counts down (when the server sends it); In progress: the run timer.
    const showStart = !inProgress && typeof view.startIn === 'number';
    let timerHint: ReactNode = null;
    if (hasTimer && view.paused) timerHint = t('run.hero.timer_paused');
    else if (hasTimer) timerHint = t('run.hero.timer_running');
    else if (showStart) timerHint = t('run.hero.start_hint');
    else if (inProgress) timerHint = t('run.hero.timer_none');
    else timerHint = t('run.hero.timer_waiting');

    return (
        <Card padding="none" className={cx('run_ui-hero', inProgress && 'is-live', view.test && 'is-test')}>
            <div className="run_ui-hero__main">
                <span className="run_ui-hero__eyebrow">
                    <span className={cx('run_ui-hero__pulse', inProgress && 'is-live')} aria-hidden />
                    {t('run.hero.eyebrow', { type: typeLabel(session, view.missionType) })}
                </span>
                <h3 className="run_ui-hero__title">{view.missionLabel}</h3>
                {view.description ? <p className="run_ui-hero__desc">{view.description}</p> : null}
                {view.area ? (
                    <span className="run_ui-hero__area">
                        <Icon name="mapPin" size={13} />
                        {view.area}
                    </span>
                ) : null}
                <div className="run_ui-hero__chips">
                    <Badge tone={inProgress ? 'success' : 'primary'} variant="solid" dot>
                        {inProgress ? t('run.state.in_progress') : t('run.state.accepted')}
                    </Badge>
                    <TierBadge
                        tier={view.tier}
                        label={tierLabel(session, view.tier)}
                        expected={view.tierExpected || !inProgress}
                    />
                    {payLower ? (
                        <Badge tone="warning" icon="dollar" title={t('hud.pay_tier_hint')}>
                            {t('hud.pay_tier', { tier: tierLabel(session, view.payTier) })}
                        </Badge>
                    ) : null}
                    {view.modifier ? (
                        <Badge tone="accent" icon="zap" title={t('run.hero.modifier_hint')}>
                            {view.modifier.label}
                        </Badge>
                    ) : null}
                    {inProgress && !routeCard && view.route?.status === 'arrived' ? (
                        <Badge tone="success" icon="mapPin">
                            {t('run.hero.at_start')}
                        </Badge>
                    ) : null}
                    {inProgress && !routeCard && (!view.route || view.route.status === 'disabled') ? (
                        <Badge tone="neutral" icon="navigation">
                            {t('hud.route.disabled')}
                        </Badge>
                    ) : null}
                    {view.isBoss ? (
                        <Badge tone="accent" variant="outline" icon="flame">
                            {t('run.hero.boss')}
                        </Badge>
                    ) : null}
                    {view.operationId ? (
                        <Badge tone="primary" variant="outline" icon="globe">
                            {t('run.hero.operation')}
                        </Badge>
                    ) : null}
                </div>
            </div>
            <div className="run_ui-hero__stats">
                <HeroStat
                    icon="clock"
                    label={showStart ? t('run.hero.start_label') : t('hud.time_left')}
                    hint={timerHint}
                    tone={view.paused ? 'warning' : 'muted'}
                    className="is-timer"
                >
                    {hasTimer ? (
                        <Countdown
                            seconds={view.remaining}
                            paused={view.paused}
                            resetKey={stamp}
                            warnBelow={60}
                            dangerBelow={15}
                            className="run_ui-hero__timer"
                        />
                    ) : showStart ? (
                        <Countdown
                            seconds={view.startIn}
                            resetKey={stamp}
                            warnBelow={90}
                            dangerBelow={30}
                            className="run_ui-hero__timer"
                        />
                    ) : (
                        <span className="run_ui-hero__timer cp-num is-idle">–:––</span>
                    )}
                </HeroStat>
                <HeroStat
                    icon="dollar"
                    label={t('run.hero.cash')}
                    hint={view.test ? t('run.hero.cash_test') : t('run.hero.cash_hint')}
                >
                    <Money amount={view.expected?.cash} />
                </HeroStat>
                <HeroStat icon="star" label={t('run.hero.points')} hint={t('run.hero.points_hint')}>
                    <Points value={view.expected?.points} />
                </HeroStat>
            </div>
        </Card>
    );
}

// ============================================================================
//                                 START ROUTE
// ============================================================================

function RouteStatus({ route, test, stamp }: { route: RunRoute | null; test: boolean; stamp: unknown }) {
    const offLeft = useCountdown(route?.status === 'off' ? route.secondsLeft : null, { resetKey: stamp });
    if (!route || route.status === 'disabled') {
        return (
            <div className="run_ui-route__status is-disabled">
                <Icon name="navigation" size={18} />
                <div>
                    <div className="run_ui-route__line">{t('hud.route.disabled')}</div>
                    <div className="run_ui-route__sub">
                        {test ? t('run.route.disabled_test') : t('run.route.disabled_text')}
                    </div>
                </div>
            </div>
        );
    }
    if (route.status === 'off') {
        return (
            <div className="run_ui-route__status is-off" role="alert">
                <Icon name="alert" size={18} />
                <div className="run_ui-route__grow">
                    <div className="run_ui-route__line">{t('hud.route.off_title')}</div>
                    <div className="run_ui-route__sub">
                        {offLeft !== null ? t('hud.route.off_prefix') : t('hud.route.off_nolimit')}
                    </div>
                </div>
                {offLeft !== null ? (
                    <span className="run_ui-route__countdown cp-num">{t('common.seconds_short', { n: offLeft })}</span>
                ) : null}
            </div>
        );
    }
    if (route.status === 'arrived') {
        return (
            <div className="run_ui-route__status is-arrived">
                <Icon name="checkCircle" size={18} />
                <div>
                    <div className="run_ui-route__line">{t('hud.route.arrived')}</div>
                    <div className="run_ui-route__sub">{t('run.route.arrived_text')}</div>
                </div>
            </div>
        );
    }
    const distance = route.distance;
    return (
        <div className="run_ui-route__status is-on">
            <Icon name="navigation" size={18} />
            <div className="run_ui-route__grow">
                <div className="run_ui-route__line">{t('hud.route.on')}</div>
                <div className="run_ui-route__sub">{t('run.route.on_text')}</div>
            </div>
            {distance !== null && distance !== undefined ? (
                <span className="run_ui-route__distance cp-num">
                    {t('hud.route.distance', { distance: formatDistance(distance) })}
                </span>
            ) : null}
        </div>
    );
}

function RouteCard({
    view,
    recalcsLeft,
    stamp,
    gpsBusy,
    recalcBusy,
    onGps,
    onRecalc,
}: {
    view: ActiveMissionData;
    recalcsLeft: number;
    stamp: unknown;
    gpsBusy: boolean;
    recalcBusy: boolean;
    onGps: () => void;
    onRecalc: () => void;
}) {
    const route = view.route ?? null;
    const status = route?.status ?? 'disabled';
    const arrived = status === 'arrived';
    const routeOn = status === 'on' || status === 'off';
    const left = recalcsLeft;
    return (
        <Card
            title={t('run.route.title')}
            icon="navigation"
            className={cx('run_ui-route', status === 'off' && 'is-off')}
            actions={
                routeOn ? (
                    <Badge size="sm" tone={left > 0 ? 'neutral' : 'danger'}>
                        {t('run.route.recalcs_left', { n: left })}
                    </Badge>
                ) : null
            }
        >
            <RouteStatus route={route} test={view.test} stamp={stamp} />
            {!arrived ? (
                <div className="run_ui-route__actions">
                    <Button variant="secondary" icon="mapPin" loading={gpsBusy} onClick={onGps}>
                        {t('run.route.set_gps')}
                    </Button>
                    <Button
                        variant="secondary"
                        icon="refresh"
                        loading={recalcBusy}
                        disabled={!routeOn || left <= 0}
                        onClick={onRecalc}
                        title={left <= 0 ? t('run.route.no_recalcs') : undefined}
                    >
                        {t('run.route.recalc')}
                    </Button>
                </div>
            ) : null}
            {routeOn ? <p className="run_ui-route__hint">{t('run.route.rules')}</p> : null}
        </Card>
    );
}

// ============================================================================
//                                  OBJECTIVES
// ============================================================================

function ObjectiveRow({ o, index, pending }: { o: RunObjective; index: number; pending: boolean }) {
    const hasProgress = typeof o.value === 'number' && typeof o.max === 'number' && o.max > 0;
    const pct = hasProgress ? Math.max(0, Math.min(100, ((o.value as number) / (o.max as number)) * 100)) : 0;
    return (
        <li
            className={cx(
                'run_ui-obj',
                o.done && 'is-done',
                o.current && !o.done && 'is-current',
                pending && 'is-pending',
            )}
        >
            <span className="run_ui-obj__mark cp-num" aria-hidden>
                {o.done ? <Icon name="check" size={13} strokeWidth={3} /> : index + 1}
            </span>
            <div className="run_ui-obj__body">
                <div className="run_ui-obj__row">
                    <span className="run_ui-obj__label">{o.label}</span>
                    {o.current && !o.done ? (
                        <Badge size="sm" tone="primary">
                            {t('run.objectives.current')}
                        </Badge>
                    ) : null}
                    {hasProgress ? (
                        <span className="run_ui-obj__count cp-num">
                            {t('hud.objective_progress', { value: o.value as number, max: o.max as number })}
                        </span>
                    ) : null}
                </div>
                {hasProgress && !o.done ? (
                    <div className="run_ui-obj__bar">
                        <div style={{ width: `${pct}%` }} />
                    </div>
                ) : null}
                {o.detail ? <div className="run_ui-obj__detail">{o.detail}</div> : null}
            </div>
        </li>
    );
}

function ObjectivesCard({ view }: { view: ActiveMissionData }) {
    const objectives = asArray(view.objectives);
    const done = objectives.filter(o => o.done).length;
    const pending = view.state !== 'in_progress';
    return (
        <Card
            title={t('hud.objectives')}
            icon="list"
            className="run_ui-objectives"
            actions={
                objectives.length ? (
                    <span className="run_ui-objectives__count cp-num">
                        {t('hud.objectives_count', { done, total: objectives.length })}
                    </span>
                ) : null
            }
        >
            {pending ? (
                <p className="run_ui-objectives__pending">
                    <Icon name="info" size={14} />
                    <span>{t('run.objectives.pending')}</span>
                </p>
            ) : null}
            {objectives.length ? (
                <ol className="run_ui-objlist">
                    {objectives.map((o, i) => (
                        <ObjectiveRow key={`${i}-${o.label}`} o={o} index={i} pending={pending} />
                    ))}
                </ol>
            ) : (
                <EmptyState compact icon="list" title={t('run.objectives.none')} />
            )}
        </Card>
    );
}

// ============================================================================
//                                   PARTNERS
// ============================================================================

function PartnerRow({ p, me }: { p: RunPartner; me: boolean }) {
    const left = p.status !== 'active';
    return (
        <li className={cx('run_ui-partner', left && 'is-left', me && 'is-me')}>
            <span className="run_ui-partner__avatar" aria-hidden>
                {initials(p.name)}
            </span>
            <div className="run_ui-partner__main">
                <div className="run_ui-partner__name">
                    <span className="run_ui-partner__text">{p.name}</span>
                    {me ? (
                        <Badge size="sm" tone="primary">
                            {t('run.partners.you')}
                        </Badge>
                    ) : null}
                </div>
                <div className={cx('run_ui-partner__sub cp-num', !p.callsign && 'is-muted')}>
                    {p.callsign || t('common.no_callsign')}
                </div>
            </div>
            <div className="run_ui-partner__tags">
                {left ? (
                    <Badge size="sm" tone="grey" icon="logout">
                        {t('run.partners.left')}
                    </Badge>
                ) : p.arrived ? (
                    <Badge size="sm" tone="success" icon="mapPin">
                        {t('run.partners.arrived')}
                    </Badge>
                ) : (
                    <Badge size="sm" tone="primary" icon="navigation">
                        {t('run.partners.en_route')}
                    </Badge>
                )}
                <Badge size="sm" variant="outline">
                    {p.departmentShort || '?'}
                </Badge>
            </div>
        </li>
    );
}

function PartnersCard({ view, session }: { view: ActiveMissionData; session: Session }) {
    const partners = asArray(view.partners);
    const active = partners.filter(p => p.status === 'active').length;
    // Departments still on the run (the cross-department bonus needs 2+); a missing tag is not a department.
    const departments = new Set(
        partners.filter(p => p.status === 'active' && !!p.departmentShort).map(p => p.departmentShort),
    ).size;
    return (
        <Card
            title={t('run.partners.title')}
            icon="users"
            className="run_ui-partners"
            actions={
                <span className="run_ui-objectives__count cp-num">
                    {t('run.partners.count', { active, total: partners.length })}
                </span>
            }
        >
            {partners.length ? (
                <ul className="run_ui-partnerlist">
                    {partners.map(p => (
                        <PartnerRow key={p.src} p={p} me={isMe(p, view, session)} />
                    ))}
                </ul>
            ) : (
                <EmptyState compact icon="users" title={t('run.partners.none')} />
            )}
            {partners.length <= 1 ? <p className="run_ui-partners__note">{t('run.partners.solo')}</p> : null}
            {departments >= 2 ? (
                <p className="run_ui-partners__note is-accent">
                    <Icon name="globe" size={13} />
                    <span>{t('run.partners.cross', { n: departments })}</span>
                </p>
            ) : null}
        </Card>
    );
}

// ============================================================================
//                              BUSINESS CHECK LOG
// ============================================================================

function LogPanel({
    log,
    sending,
    sent,
    onPick,
}: {
    log: RunLog;
    sending: string | null;
    sent: boolean;
    onPick: (choice: string) => void;
}) {
    const choices = asArray(log.choices);
    return (
        <Card
            highlight="accent"
            icon="edit"
            className="run_ui-log"
            title={t('run.log.title')}
            subtitle={t('run.log.point', { point: log.point })}
            actions={
                sent ? (
                    <Badge tone="success" icon="check">
                        {t('run.log.sent')}
                    </Badge>
                ) : null
            }
        >
            <p className="run_ui-log__text">{t('run.log.text')}</p>
            <div className="run_ui-log__choices">
                {choices.map(c => (
                    <Button
                        key={c.id}
                        variant="secondary"
                        className="run_ui-log__choice"
                        icon={c.id === 'secure' ? 'lock' : 'shieldCheck'}
                        loading={sending === c.id}
                        disabled={sent || (sending !== null && sending !== c.id)}
                        onClick={() => onPick(c.id)}
                    >
                        {c.label}
                    </Button>
                ))}
            </div>
        </Card>
    );
}

// ============================================================================
//                                    SCREEN
// ============================================================================

export default function ActiveMission() {
    const session = useSession();
    const navigate = useNavigate();
    const { data, loading, error, refetch, setData } = useRequest<ActiveMissionData | null>(
        'getRun',
        {},
        { pollMs: POLL_MS },
    );
    const { run, busy } = useAction();
    const [confirmAbandon, setConfirmAbandon] = useState(false);
    const [confirmRecalc, setConfirmRecalc] = useState(false);
    const [gpsBusy, setGpsBusy] = useState(false);
    const [recalcBusy, setRecalcBusy] = useState(false);
    const [logSending, setLogSending] = useState<string | null>(null);
    const [loggedPoint, setLoggedPoint] = useState<number | null>(null);
    // Recalculations left as the recalcRoute reply reported them, until the next server view arrives
    // (a local copy of the view would restart the timer from its stale value).
    const [recalcsOverride, setRecalcsOverride] = useState<number | null>(null);

    // Push topic 'run' carries this officer's full view (CP.Runs.view), applied as it is: no extra getRun
    // per push (the RunBar already refetches on every push and getRun allows 6 calls per second). When
    // the run ended the push carries nil, which reaches the NUI as a missing field (undefined, not null):
    // ask the server then, so the empty state (or a new run) shows at once.
    usePush<ActiveMissionData | null | undefined>('run', view => {
        if (view && typeof view === 'object' && typeof view.runId === 'string') setData(view);
        else void refetch();
    });

    // Show the loading block only for the very first fetch (later refetches keep the current content).
    const [loadedOnce, setLoadedOnce] = useState(false);
    useEffect(() => {
        if (!loading) setLoadedOnce(true);
    }, [loading]);

    const view = data && typeof data === 'object' && typeof data.runId === 'string' ? data : null;
    // The view object itself is the reset key: every fresh server value restarts the local countdowns.
    const stamp = view;

    useEffect(() => {
        setRecalcsOverride(null);
    }, [data]);

    // The log panel stays "sent" for a point until the server moves on to another point (or closes it).
    // If the server keeps asking for the same point (it refused the log), the buttons come back after 6 s.
    const logPoint = view?.log ? view.log.point : null;
    useEffect(() => {
        if (loggedPoint === null) return;
        if (logPoint !== loggedPoint) {
            setLoggedPoint(null);
            return;
        }
        const id = window.setTimeout(() => setLoggedPoint(null), 6000);
        return () => window.clearTimeout(id);
    }, [logPoint, loggedPoint]);

    const openBoard = () => navigate('board');

    const setGps = async () => {
        if (!view) return;
        setGpsBusy(true);
        const res = await clientAction<SetGpsResult>('setGps', { runId: view.runId });
        setGpsBusy(false);
        if (!res.ok) errorToast(res.error);
    };

    const recalc = async () => {
        if (!view) return;
        setRecalcBusy(true);
        const res = await clientAction<RecalcRouteResult>('recalcRoute', { runId: view.runId });
        setRecalcBusy(false);
        setConfirmRecalc(false);
        if (res.ok && res.data && typeof res.data.recalcsLeft === 'number') {
            setRecalcsOverride(Math.max(0, Math.floor(res.data.recalcsLeft)));
        } else if (!res.ok) {
            errorToast(res.error);
        }
        void refetch();
    };

    const logResult = async (choice: string) => {
        if (!view?.log) return;
        const payload: LogResultPayload = { point: view.log.point, choice };
        setLogSending(choice);
        const res = await clientAction('logResult', payload);
        setLogSending(null);
        if (res.ok) {
            setLoggedPoint(payload.point);
            window.setTimeout(() => void refetch(), 600);
        } else {
            errorToast(res.error);
        }
    };

    const abandon = async () => {
        if (!view) return;
        const res = await run<AbandonResult>('server:abandon', view.runId);
        setConfirmAbandon(false);
        if (res.ok) setData(null);
        // Also after a success: the refetch supersedes any getRun still in flight from before the abandon
        // (useRequest applies only the latest reply), so an old view can never bring the run back.
        void refetch();
    };

    if (!view) {
        return (
            <Screen title={t('ui.screen.active')} className="run_ui-active">
                {!loadedOnce ? <LoadingBlock /> : null}
                {loadedOnce && error ? <ErrorState error={error} onRetry={() => void refetch()} /> : null}
                {loadedOnce && !error ? (
                    <Card padding="lg" className="run_ui-empty">
                        <EmptyState
                            icon="target"
                            title={t('run.empty.title')}
                            text={t('run.empty.text')}
                            action={
                                <Button variant="primary" icon="board" onClick={openBoard}>
                                    {t('run.empty.open_board')}
                                </Button>
                            }
                        />
                    </Card>
                ) : null}
            </Screen>
        );
    }

    const typeName = typeLabel(session, view.missionType);
    const activeOthers = asArray(view.partners).filter(p => p.status === 'active' && !isMe(p, view, session)).length;
    const logOpen = view.state === 'in_progress' && !!view.log && asArray(view.log.choices).length > 0;
    const recalcsLeft = recalcsOverride ?? Math.max(0, Math.floor(Number(view.recalcsLeft) || 0));
    // The route card shows while this participant still heads to the start; once In progress an arrived or
    // untracked route is a chip in the hero instead.
    const routing = !!view.route && (view.route.status === 'on' || view.route.status === 'off');
    // A test run without the start route ('disabled'): the card (Set GPS) stays until this officer arrives.
    const mine = asArray(view.partners).find(p => isMe(p, view, session));
    const untracked = view.route?.status === 'disabled' && !!mine && mine.status === 'active' && !mine.arrived;
    const showRoute = view.state === 'accepted' || routing || untracked;

    const abandonMessage = (
        <div className="run_ui-confirm">
            <p>{t('run.abandon.text')}</p>
            <p className="run_ui-confirm__warn">
                <Icon name="alert" size={14} />
                <span>
                    {view.test
                        ? t('run.abandon.test')
                        : view.isBoss
                          ? t('run.abandon.boss')
                          : t('run.abandon.cooldown', { type: typeName })}
                </span>
            </p>
            {activeOthers > 0 ? <p className="run_ui-confirm__note">{t('run.abandon.team')}</p> : null}
        </div>
    );

    return (
        <Screen
            title={t('ui.screen.active')}
            subtitle={view.state === 'in_progress' ? t('run.subtitle_in_progress') : t('run.subtitle_accepted')}
            className="run_ui-active"
            actions={
                <Button variant="danger" icon="x" onClick={() => setConfirmAbandon(true)} disabled={busy}>
                    {t('run.abandon.button')}
                </Button>
            }
        >
            {view.test ? (
                <div className="run_ui-test" role="note">
                    <Icon name="flask" size={15} />
                    <strong>{t('hud.test_run')}</strong>
                    <span>{t('run.test_note')}</span>
                </div>
            ) : null}

            <Hero view={view} session={session} stamp={stamp} routeCard={showRoute} />

            {view.radioSilence ? (
                <div className="run_ui-notice run_ui-notice--accent" role="note">
                    <span className="run_ui-notice__icon" aria-hidden>
                        <Icon name="radio" size={17} />
                    </span>
                    <span className="run_ui-notice__text">
                        <span className="run_ui-notice__title">{t('run.silence.title')}</span>
                        <span className="run_ui-notice__sub">{t('run.silence.text')}</span>
                    </span>
                </div>
            ) : null}

            {logOpen && view.log ? (
                <LogPanel
                    log={view.log}
                    sending={logSending}
                    sent={loggedPoint === view.log.point}
                    onPick={c => void logResult(c)}
                />
            ) : null}

            <div className="run_ui-active__grid">
                <div className="run_ui-active__col">
                    {showRoute ? (
                        <RouteCard
                            view={view}
                            recalcsLeft={recalcsLeft}
                            stamp={stamp}
                            gpsBusy={gpsBusy}
                            recalcBusy={recalcBusy}
                            onGps={() => void setGps()}
                            onRecalc={() => setConfirmRecalc(true)}
                        />
                    ) : null}
                    <ObjectivesCard view={view} />
                </div>
                <div className="run_ui-active__col">
                    <PartnersCard view={view} session={session} />
                </div>
            </div>

            <ConfirmDialog
                open={confirmAbandon}
                tone="danger"
                title={t('run.abandon.title', { mission: view.missionLabel })}
                message={abandonMessage}
                confirmLabel={t('run.abandon.confirm')}
                onConfirm={abandon}
                onCancel={() => setConfirmAbandon(false)}
                busy={busy}
            />

            <ConfirmDialog
                open={confirmRecalc}
                title={t('run.recalc.title')}
                message={
                    <div className="run_ui-confirm">
                        <p>{t('run.recalc.text', { n: recalcsLeft })}</p>
                    </div>
                }
                confirmLabel={t('run.route.recalc')}
                onConfirm={recalc}
                onCancel={() => setConfirmRecalc(false)}
                busy={recalcBusy}
            />
        </Screen>
    );
}
