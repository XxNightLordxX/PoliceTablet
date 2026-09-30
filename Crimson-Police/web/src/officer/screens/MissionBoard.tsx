// Officer UI · Mission Board (screen key 'board', title key 'ui.screen.board') · run_ui slice.

import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
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
    ProgressBar,
    Screen,
} from '../../shared/components';
import type { IconName } from '../../shared/components';
import { cx } from '../../shared/cx';
import { asArray } from '../../shared/data';
import { formatNumber } from '../../shared/format';
import { useAction, usePush, useRequest } from '../../shared/hooks';
import { hasKey, t } from '../../shared/i18n';
import { useNavigate } from '../../shared/navigation';
import { useSession } from '../../shared/session';
import { toast } from '../../shared/toast';
import type { Session } from '../../shared/types';
import type {
    AcceptTypeResult,
    BoardOperation,
    BossCard,
    JoinOperationResult,
    MissionBoardData,
    TypeCard,
} from '../../types/run_ui';
import type { BoardCallsInfo } from '../../types/missioncalls';
import { CallsOpenLink, DailyLimitBadge, readyCheckSentText } from '../components/MissionCallsLink';
import './MissionBoard.css';

const BOSS_KEY = 'weekly_boss';
const POLL_MS = 30000;
// Pushes come in bursts ('operation' + 'board', 'unit' + 'board', 'run' + 'board'): one refetch per burst.
const PUSH_DEBOUNCE_MS = 150;
// getMissionTypes allows 4 calls per second; a refused refetch is retried once after this long.
const RATE_RETRY_MS = 1200;

const TYPE_ICONS: Record<string, IconName> = {
    patrol: 'car',
    training: 'target',
    investigation: 'search',
    tactical: 'shield',
};

// ============================================================================
//                                 SERVER CLOCK
// ============================================================================
// Cooldown ends (`locked.until`) are server os.time() stamps. The difference between the server clock and
// this client's clock is constant, so one good measurement is enough: the board's own serverTime when the
// server sends it, else the serverTime of the last session message ('open' / 'session') at the moment it
// arrived, else the session's serverTime the first time this screen saw that session.

let messageOffset: number | null = null;
if (typeof window !== 'undefined') {
    window.addEventListener('message', (event: MessageEvent) => {
        const d = event.data as { type?: string; session?: { serverTime?: unknown } } | null;
        if (!d || (d.type !== 'open' && d.type !== 'session')) return;
        const st = Number(d.session?.serverTime);
        if (st > 0) messageOffset = st - Date.now() / 1000;
    });
}
const sessionSeenAt = new WeakMap<object, number>();

function clockOffset(session: Session, board: MissionBoardData | null, receivedAt: number): number {
    const own = Number(board?.serverTime);
    if (own > 0) return own - receivedAt;
    if (messageOffset !== null) return messageOffset;
    const st = Number(session.serverTime);
    if (st > 0) {
        let seen = sessionSeenAt.get(session);
        if (seen === undefined) {
            seen = Date.now() / 1000;
            sessionSeenAt.set(session, seen);
        }
        return st - seen;
    }
    return 0;
}

// Seconds until a server timestamp (a value below 1e9 is taken as seconds left already).
function secondsUntil(until: unknown, offset: number): number | null {
    const n = Number(until);
    if (until === null || until === undefined || !isFinite(n) || n <= 0) return null;
    if (n < 1e9) return Math.max(0, Math.round(n));
    return Math.max(0, Math.round(n - (Date.now() / 1000 + offset)));
}

// ============================================================================
//                                   HELPERS
// ============================================================================

type Blocker = null | { icon: IconName; tone: 'warning' | 'danger' | 'info' | 'neutral'; text: string };

// Why the viewer can't accept anything right now (board-wide), or null.
function boardBlocker(data: MissionBoardData): Blocker {
    if (data.activeRunId) return { icon: 'target', tone: 'info', text: t('board.blocked.on_run') };
    if (data.unit && data.unit.size > 1 && !data.unit.isLeader)
        return { icon: 'users', tone: 'neutral', text: t('board.blocked.not_leader') };
    return null;
}

// Config.Events.todMultiplier as text (BoardData.todMultiplier when the server sends it, else the default 2).
function todMultiplierText(data: MissionBoardData | null): string {
    const m = Number(data?.todMultiplier);
    return String(isFinite(m) && m > 0 ? Math.round(m * 100) / 100 : 2);
}

function poolText(n: number): string {
    if (n <= 0) return t('board.card.pool_none');
    return n === 1 ? t('board.card.pool_one') : t('board.card.pool_many', { n: formatNumber(n) });
}

function modeBadge(card: TypeCard, size: number) {
    return card.mode === 'unit' ? (
        <Badge size="sm" variant="outline" icon="users">
            {t('board.card.mode_unit', { size: Math.max(2, size) })}
        </Badge>
    ) : (
        <Badge size="sm" variant="outline" icon="user">
            {t('board.card.mode_solo')}
        </Badge>
    );
}

// ============================================================================
//                                    PIECES
// ============================================================================

function UnitLine({ data, onUnit }: { data: MissionBoardData; onUnit: () => void }) {
    const size = Math.max(1, Number(data.unit?.size) || 1);
    const leader = !!data.unit?.isLeader;
    const text =
        size <= 1 ? t('board.unit.solo') : leader ? t('board.unit.leader', { size }) : t('board.unit.member', { size });
    return (
        <div className={cx('run_ui-unitline', size > 1 && !leader && 'is-member')}>
            <span className="run_ui-unitline__icon" aria-hidden>
                <Icon name={size > 1 ? 'users' : 'user'} size={16} />
            </span>
            <span className="run_ui-unitline__text">
                <span className="run_ui-unitline__title">
                    {size <= 1 ? t('board.unit.solo_title') : t('board.unit.unit_title', { size })}
                </span>
                <span className="run_ui-unitline__sub">{text}</span>
            </span>
            <Button variant="ghost" size="sm" iconRight="chevronRight" onClick={onUnit}>
                {size <= 1 ? t('board.unit.build') : t('board.unit.manage')}
            </Button>
        </div>
    );
}

function Notice({
    icon,
    tone,
    title,
    text,
    action,
}: {
    icon: IconName;
    tone: 'info' | 'warning' | 'danger' | 'accent';
    title: string;
    text?: string;
    action?: ReactNode;
}) {
    return (
        <div className={cx('run_ui-notice', `run_ui-notice--${tone}`)} role="status">
            <span className="run_ui-notice__icon" aria-hidden>
                <Icon name={icon} size={17} />
            </span>
            <span className="run_ui-notice__text">
                <span className="run_ui-notice__title">{title}</span>
                {text ? <span className="run_ui-notice__sub">{text}</span> : null}
            </span>
            {action ? <span className="run_ui-notice__action">{action}</span> : null}
        </div>
    );
}

function CardStatus({
    card,
    offset,
    stamp,
    onUnlocked,
    readyText,
    blocker,
    unit,
}: {
    card: TypeCard;
    offset: number;
    stamp: unknown;
    onUnlocked: () => void;
    readyText?: string;
    blocker?: Blocker;
    unit: boolean;
}) {
    if (card.locked) {
        const left = secondsUntil(card.locked.until, offset);
        return (
            <div className="run_ui-status run_ui-status--locked">
                <Icon name="lock" size={14} />
                <span className="run_ui-status__text">{card.locked.reason || t('board.card.locked')}</span>
                {left !== null && left > 0 ? (
                    <span className="run_ui-status__timer" title={t('board.card.cooldown_left')}>
                        <Icon name="clock" size={12} />
                        <Countdown seconds={left} resetKey={stamp} onDone={onUnlocked} />
                    </span>
                ) : null}
            </div>
        );
    }
    if (card.onCall) {
        return (
            <div className="run_ui-status run_ui-status--call">
                <Icon name="radio" size={14} />
                <span className="run_ui-status__text">
                    <strong>{t('board.card.on_call')}</strong> ·{' '}
                    {unit ? t('board.card.on_call_text_unit') : t('board.card.on_call_text')}
                </span>
            </div>
        );
    }
    if (card.busy) {
        return (
            <div className="run_ui-status run_ui-status--busy">
                <Icon name="activity" size={14} />
                <span className="run_ui-status__text">
                    <strong>{t('board.card.busy')}</strong> · {t('board.card.busy_text')}
                </span>
            </div>
        );
    }
    if (blocker) {
        return (
            <div className="run_ui-status run_ui-status--muted">
                <Icon name={blocker.icon} size={14} />
                <span className="run_ui-status__text">{blocker.text}</span>
            </div>
        );
    }
    return (
        <div className="run_ui-status run_ui-status--ready">
            <Icon name="checkCircle" size={14} />
            <span className="run_ui-status__text">{readyText ?? t('board.card.ready')}</span>
        </div>
    );
}

function cardBlocked(card: TypeCard, board: Blocker): boolean {
    return !!board || !!card.locked || card.onCall || card.busy || (Number(card.pool) || 0) <= 0;
}

function TypeCardView({
    card,
    size,
    board,
    offset,
    stamp,
    busy,
    todX,
    onAccept,
    onUnlocked,
}: {
    card: TypeCard;
    size: number;
    board: Blocker;
    offset: number;
    stamp: unknown;
    busy: boolean;
    todX: string;
    onAccept: (card: TypeCard) => void;
    onUnlocked: () => void;
}) {
    const blocked = cardBlocked(card, board);
    const icon = TYPE_ICONS[card.key] ?? 'layers';
    return (
        <Card
            padding="none"
            className={cx(
                'run_ui-type',
                `run_ui-type--${card.key}`,
                card.locked && 'is-locked',
                card.typeOfTheDay && 'is-tod',
            )}
            highlight={card.typeOfTheDay ? 'accent' : undefined}
        >
            <div className="run_ui-type__head">
                <span className="run_ui-type__icon" aria-hidden>
                    <Icon name={icon} size={20} />
                </span>
                <div className="run_ui-type__titles">
                    <div className="run_ui-type__label" title={card.label}>
                        {card.label}
                    </div>
                    <div className="run_ui-type__tags">
                        {modeBadge(card, size)}
                        {card.typeOfTheDay ? (
                            <Badge
                                size="sm"
                                tone="accent"
                                variant="solid"
                                icon="zap"
                                title={t('board.card.tod_hint', { multiplier: todX })}
                            >
                                {t('board.card.tod')}
                            </Badge>
                        ) : null}
                        {card.busy ? (
                            <Badge size="sm" tone="warning" icon="activity">
                                {t('board.card.busy')}
                            </Badge>
                        ) : null}
                        <DailyLimitBadge locked={card.locked} />
                        {card.onCall ? (
                            <Badge size="sm" tone="primary" icon="radio">
                                {t('board.card.on_call')}
                            </Badge>
                        ) : null}
                    </div>
                </div>
            </div>

            <div className="run_ui-type__stats">
                <div className="run_ui-stat">
                    <span className="run_ui-stat__label">{t('board.card.points')}</span>
                    <span className="run_ui-stat__value">
                        <Points value={card.points} />
                    </span>
                    {card.typeOfTheDay ? (
                        <span className="run_ui-stat__hint is-accent">
                            {t('board.card.tod_points', { multiplier: todX })}
                        </span>
                    ) : null}
                </div>
                <div className="run_ui-stat run_ui-stat--wide">
                    <span className="run_ui-stat__label">{t('board.card.cash')}</span>
                    <span className="run_ui-stat__value">
                        <MoneyRange range={asArray(card.cash as number[])} />
                    </span>
                    <span className="run_ui-stat__hint">{t('board.card.cash_hint')}</span>
                </div>
                <div className="run_ui-stat">
                    <span className="run_ui-stat__label">{t('board.card.pool')}</span>
                    <span className="run_ui-stat__value cp-num">{formatNumber(card.pool)}</span>
                    <span className="run_ui-stat__hint">{poolText(Number(card.pool) || 0)}</span>
                </div>
            </div>

            <div className="run_ui-type__foot">
                <CardStatus
                    card={card}
                    offset={offset}
                    stamp={stamp}
                    onUnlocked={onUnlocked}
                    blocker={board}
                    unit={size > 1}
                />
                <Button
                    variant={blocked ? 'secondary' : 'primary'}
                    icon="play"
                    disabled={blocked || busy}
                    onClick={() => onAccept(card)}
                    title={board ? board.text : undefined}
                >
                    {t('board.card.accept')}
                </Button>
            </div>
        </Card>
    );
}

function BossCardView({
    boss,
    size,
    board,
    offset,
    stamp,
    busy,
    todX,
    onAccept,
    onUnlocked,
}: {
    boss: BossCard;
    size: number;
    board: Blocker;
    offset: number;
    stamp: unknown;
    busy: boolean;
    todX: string;
    onAccept: (card: BossCard) => void;
    onUnlocked: () => void;
}) {
    const unavailable = !boss.available && !boss.locked;
    const blocked = !!board || !boss.available || !!boss.locked || boss.onCall || boss.busy;
    const statusCard: TypeCard = unavailable ? { ...boss, locked: { reason: t('board.boss.unavailable') } } : boss;
    return (
        <Card padding="none" highlight="accent" className={cx('run_ui-boss', blocked && 'is-blocked')}>
            <div className="run_ui-boss__body">
                <span className="run_ui-boss__icon" aria-hidden>
                    <Icon name="flame" size={26} />
                </span>
                <div className="run_ui-boss__main">
                    <span className="run_ui-boss__eyebrow">
                        <Icon name="star" size={12} strokeWidth={2.4} />
                        {t('board.boss.eyebrow')}
                    </span>
                    <span className="run_ui-boss__title">{boss.label}</span>
                    <span className="run_ui-boss__text">{t('board.boss.text')}</span>
                    <div className="run_ui-type__tags">
                        {modeBadge(boss, size)}
                        {boss.typeOfTheDay ? (
                            <Badge
                                size="sm"
                                tone="accent"
                                variant="solid"
                                icon="zap"
                                title={t('board.card.tod_hint', { multiplier: todX })}
                            >
                                {t('board.card.tod')}
                            </Badge>
                        ) : null}
                    </div>
                </div>
                <div className="run_ui-boss__stats">
                    <div className="run_ui-stat">
                        <span className="run_ui-stat__label">{t('board.card.points')}</span>
                        <span className="run_ui-stat__value">
                            <Points value={boss.points} />
                        </span>
                    </div>
                    <div className="run_ui-stat run_ui-stat--wide">
                        <span className="run_ui-stat__label">{t('board.card.cash')}</span>
                        <span className="run_ui-stat__value">
                            <MoneyRange range={asArray(boss.cash as number[])} />
                        </span>
                    </div>
                </div>
            </div>
            <div className="run_ui-type__foot">
                <CardStatus
                    card={statusCard}
                    offset={offset}
                    stamp={stamp}
                    onUnlocked={onUnlocked}
                    readyText={t('board.boss.ready')}
                    blocker={board}
                    unit={size > 1}
                />
                <Button
                    variant={blocked ? 'secondary' : 'primary'}
                    icon="flame"
                    disabled={blocked || busy}
                    onClick={() => onAccept(boss)}
                >
                    {t('board.boss.accept')}
                </Button>
            </div>
        </Card>
    );
}

function opStatus(op: BoardOperation): { tone: 'success' | 'warning' | 'primary' | 'neutral'; text: string } {
    if (op.status === 'joining') {
        // joinEndsIn is only sent while the window is open; without it Start now closed joining a moment ago.
        const open = typeof op.joinEndsIn === 'number' && op.joinEndsIn > 0;
        return open
            ? { tone: 'success', text: t('board.op.status_joining') }
            : { tone: 'primary', text: t('board.op.status_starting') };
    }
    if (op.status === 'running') {
        return {
            tone: 'primary',
            text: op.runState === 'in_progress' ? t('board.op.status_in_progress') : t('board.op.status_running'),
        };
    }
    if (op.status === 'waiting') return { tone: 'warning', text: t('board.op.status_waiting') };
    return { tone: 'neutral', text: op.status };
}

function joinHint(op: BoardOperation, activeRunId: string | null): string {
    if (op.joinedByMe) {
        if (op.status === 'joining') return t('board.op.joined_wait');
        if (op.status === 'running') return t('board.op.joined_running');
        return t('board.op.joined_waiting');
    }
    if (op.status === 'running') return t('board.op.closed_running');
    if (op.status === 'waiting') return t('board.op.closed_waiting');
    // CP.Operations.boardCard sends joinEndsIn only while the join window is open (nil once Start now closed it).
    if (op.joinEndsIn === null || op.joinEndsIn === undefined || op.joinEndsIn <= 0) return t('board.op.closed');
    if (op.joined >= op.max) return t('board.op.full');
    if (activeRunId) return t('board.op.on_run');
    if (op.canJoin) return t('board.op.can_join');
    // joinBlocked (CP.Operations.boardCard): the err.* key a Join would return right now.
    if (op.joinBlocked) {
        if (op.joinBlocked === 'err.op_full') return t('board.op.full');
        if (op.joinBlocked === 'err.op_join_closed') return t('board.op.closed');
        if (op.joinBlocked === 'err.already_on_run') return t('board.op.on_run');
        if (hasKey(op.joinBlocked)) return t(op.joinBlocked);
    }
    return t('board.op.cannot_join');
}

function OperationCardView({
    op,
    activeRunId,
    stamp,
    joining,
    onJoin,
    onOpenRun,
    onClosed,
}: {
    op: BoardOperation;
    activeRunId: string | null;
    stamp: unknown;
    joining: boolean;
    onJoin: () => void;
    onOpenRun: () => void;
    onClosed: () => void;
}) {
    const status = opStatus(op);
    const max = Math.max(1, Number(op.max) || 1);
    const joined = Math.max(0, Number(op.joined) || 0);
    const min = Number(op.min) || 0;
    const joinOpen =
        op.status === 'joining' && op.joinEndsIn !== null && op.joinEndsIn !== undefined && op.joinEndsIn > 0;
    return (
        <Card padding="none" highlight="primary" className="run_ui-op">
            <div className="run_ui-op__body">
                <span className="run_ui-op__icon" aria-hidden>
                    <Icon name="globe" size={26} />
                </span>
                <div className="run_ui-op__main">
                    <span className="run_ui-op__eyebrow">{t('board.op.eyebrow')}</span>
                    <span className="run_ui-op__title">{op.missionLabel}</span>
                    <div className="run_ui-type__tags">
                        {op.missionTypeLabel ? (
                            <Badge size="sm" variant="outline" icon="layers">
                                {op.missionTypeLabel}
                            </Badge>
                        ) : null}
                        <Badge size="sm" tone={status.tone} dot>
                            {status.text}
                        </Badge>
                        {op.joinedByMe ? (
                            <Badge size="sm" tone="success" variant="solid" icon="check">
                                {t('board.op.joined_badge')}
                            </Badge>
                        ) : null}
                    </div>
                    {op.description ? <p className="run_ui-op__desc">{op.description}</p> : null}
                    <span className="run_ui-op__launcher">
                        <Icon name="user" size={13} />
                        {t('board.op.launcher', { name: op.launcher })}
                    </span>
                </div>
                <div className="run_ui-op__side">
                    <ProgressBar
                        value={Math.min(joined, max)}
                        max={max}
                        tone={joined >= Math.max(1, min) ? 'success' : 'primary'}
                        size="md"
                        label={t('board.op.participants')}
                        showValue={t('board.op.joined_of', { joined, max })}
                    />
                    {min > 0 ? <span className="run_ui-op__min">{t('board.op.min', { min })}</span> : null}
                    {joinOpen ? (
                        <div className="run_ui-op__countdown">
                            <span className="run_ui-op__countdown-label">{t('board.op.join_closes')}</span>
                            <Countdown
                                seconds={op.joinEndsIn}
                                resetKey={stamp}
                                warnBelow={60}
                                dangerBelow={20}
                                onDone={onClosed}
                            />
                        </div>
                    ) : null}
                </div>
            </div>
            <div className="run_ui-op__facts">
                <span>
                    <Icon name="users" size={13} /> {t('board.op.fact_any_dept', { max })}
                </span>
                <span>
                    <Icon name="star" size={13} /> {t('board.op.fact_bonus')}
                </span>
                <span>
                    <Icon name="lock" size={13} /> {t('board.op.fact_lock')}
                </span>
            </div>
            <div className="run_ui-type__foot">
                <div
                    className={cx(
                        'run_ui-status',
                        op.joinedByMe
                            ? 'run_ui-status--ready'
                            : op.canJoin
                              ? 'run_ui-status--ready'
                              : 'run_ui-status--muted',
                    )}
                >
                    <Icon name={op.joinedByMe ? 'checkCircle' : op.canJoin ? 'info' : 'lock'} size={14} />
                    <span className="run_ui-status__text">{joinHint(op, activeRunId)}</span>
                </div>
                {op.joinedByMe && activeRunId ? (
                    <Button variant="primary" icon="target" onClick={onOpenRun}>
                        {t('board.op.open_run')}
                    </Button>
                ) : op.joinedByMe ? (
                    <Button variant="secondary" icon="check" disabled>
                        {t('board.op.joined_badge')}
                    </Button>
                ) : (
                    <Button variant="primary" icon="plus" loading={joining} disabled={!op.canJoin} onClick={onJoin}>
                        {t('board.op.join')}
                    </Button>
                )}
            </div>
        </Card>
    );
}

// ============================================================================
//                                    SCREEN
// ============================================================================

type Pending = null | { kind: 'type'; card: TypeCard } | { kind: 'boss'; card: BossCard };

export default function MissionBoard() {
    const session = useSession();
    const navigate = useNavigate();
    const { data, loading, error, refetch } = useRequest<MissionBoardData>('getMissionTypes', {}, { pollMs: POLL_MS });
    const { run, busy } = useAction();
    const [pending, setPending] = useState<Pending>(null);
    const [joining, setJoining] = useState(false);

    // Live updates: push topics 'board', 'operation' and 'run' (active run and cooldowns) schedule one
    // coalesced refetch, so a burst of pushes never runs into the callback's rate limit (a refused refetch
    // would leave the old board up until the next poll).
    const refetchRef = useRef(refetch);
    refetchRef.current = refetch;
    const timer = useRef<number | null>(null);
    const retried = useRef(false);
    const schedule = useCallback((delay: number = PUSH_DEBOUNCE_MS) => {
        if (timer.current !== null) return;
        timer.current = window.setTimeout(() => {
            timer.current = null;
            void refetchRef.current().then(res => {
                if (!res.ok && res.error === 'err.rate_limited' && !retried.current) {
                    retried.current = true;
                    schedule(RATE_RETRY_MS);
                } else {
                    retried.current = false;
                }
            });
        }, delay);
    }, []);
    useEffect(
        () => () => {
            if (timer.current !== null) window.clearTimeout(timer.current);
        },
        [],
    );
    usePush('board', () => schedule());
    usePush('operation', () => schedule());
    // 'run' carries the officer's run view every few seconds during a run; the board only changes when a
    // run starts or ends (active run, cooldowns), i.e. when the pushed runId differs from activeRunId.
    usePush<{ runId?: unknown } | null | undefined>('run', view => {
        const runId = view && typeof view === 'object' && typeof view.runId === 'string' ? view.runId : null;
        if (runId !== (data?.activeRunId ?? null)) schedule();
    });

    // A fresh stamp per board fetch restarts every countdown from the server's values.
    const [stamp, setStamp] = useState(0);
    const receivedAt = useMemo(() => Date.now() / 1000, [data]);
    useEffect(() => {
        if (data) setStamp(s => s + 1);
    }, [data]);
    const offset = clockOffset(session, data, receivedAt);

    const cards = asArray(data?.cards as TypeCard[] | undefined);
    const size = Math.max(1, Number(data?.unit?.size) || 1);
    const blocker = data ? boardBlocker(data) : null;
    const onCall = cards.some(c => c.onCall) || !!data?.boss?.onCall;
    const allBusy = cards.length > 0 && cards.every(c => c.busy);
    const todX = todMultiplierText(data);
    const refresh = () => void refetch();
    const refreshSoon = () => schedule(300);

    const accept = async () => {
        if (!pending) return;
        const key = pending.kind === 'boss' ? BOSS_KEY : pending.card.key;
        const res = await run<AcceptTypeResult & { pending?: boolean }>('server:acceptType', key);
        setPending(null);
        // a unit of 2+ answers the ready check first: the run starts when everyone accepted
        if (res.ok && res.data?.pending) toast('info', readyCheckSentText());
        else if (res.ok) navigate('active');
        else void refetch();
    };

    const join = async (op: BoardOperation) => {
        setJoining(true);
        try {
            const res = await run<JoinOperationResult>('server:joinOperation', op.id, {
                success: 'board.op.joined_toast',
                successVars: { mission: op.missionLabel },
            });
            void refetch();
            return res;
        } finally {
            setJoining(false);
        }
    };

    const pendingLabel = pending ? pending.card.label : '';
    const confirmMessage = pending ? (
        <div className="run_ui-confirm">
            {pending.kind === 'boss' ? (
                <>
                    <p>{t('board.confirm.boss_random', { mission: pendingLabel })}</p>
                    <p className="run_ui-confirm__warn">
                        <Icon name="alert" size={14} />
                        <span>{t('board.confirm.boss_abandon')}</span>
                    </p>
                </>
            ) : (
                <>
                    <p>{t('board.confirm.random', { type: pendingLabel })}</p>
                    <p className="run_ui-confirm__warn">
                        <Icon name="alert" size={14} />
                        <span>{t('board.confirm.abandon', { type: pendingLabel })}</span>
                    </p>
                </>
            )}
            {size > 1 ? <p className="run_ui-confirm__note">{t('board.confirm.unit', { size })}</p> : null}
            <p className="run_ui-confirm__note">{t('board.confirm.route')}</p>
        </div>
    ) : null;

    const operation = data?.operation ?? null;

    return (
        <Screen
            title={t('ui.screen.board')}
            subtitle={operation ? t('board.subtitle_operation') : t('board.subtitle')}
            className="run_ui-board"
        >
            {!data && loading ? <LoadingBlock /> : null}
            {!data && !loading && error ? <ErrorState error={error} onRetry={refresh} /> : null}

            {data ? (
                <>
                    {data.activeRunId ? (
                        <Notice
                            icon="target"
                            tone="info"
                            title={t('board.notice.on_run_title')}
                            text={t('board.notice.on_run_text')}
                            action={
                                <Button
                                    variant="primary"
                                    size="sm"
                                    iconRight="chevronRight"
                                    onClick={() => navigate('active')}
                                >
                                    {t('board.notice.open_run')}
                                </Button>
                            }
                        />
                    ) : null}

                    {operation ? (
                        <>
                            <Notice
                                icon="globe"
                                tone="accent"
                                title={t('board.notice.op_title')}
                                text={t('board.notice.op_text')}
                            />
                            <OperationCardView
                                op={operation}
                                activeRunId={data.activeRunId}
                                stamp={stamp}
                                joining={joining}
                                onJoin={() => void join(operation)}
                                onOpenRun={() => navigate('active')}
                                onClosed={refreshSoon}
                            />
                        </>
                    ) : (
                        <>
                            <UnitLine data={data} onUnit={() => navigate('unit')} />
                            <CallsOpenLink
                                n={(data as MissionBoardData & BoardCallsInfo).callsOpen ?? 0}
                                onOpen={() => navigate('dispatch')}
                            />
                            {onCall && !data.activeRunId ? (
                                <Notice
                                    icon="radio"
                                    tone="warning"
                                    title={t('board.notice.on_call_title')}
                                    text={
                                        size > 1 ? t('board.notice.on_call_text_unit') : t('board.notice.on_call_text')
                                    }
                                />
                            ) : null}
                            {allBusy && !onCall && !data.activeRunId ? (
                                <Notice
                                    icon="activity"
                                    tone="warning"
                                    title={t('board.notice.busy_title')}
                                    text={t('board.notice.busy_text')}
                                />
                            ) : null}

                            {data.boss ? (
                                <BossCardView
                                    boss={data.boss}
                                    size={size}
                                    board={blocker}
                                    offset={offset}
                                    stamp={stamp}
                                    busy={busy}
                                    todX={todX}
                                    onAccept={card => setPending({ kind: 'boss', card })}
                                    onUnlocked={refreshSoon}
                                />
                            ) : null}

                            {cards.length ? (
                                <div className="run_ui-types">
                                    {cards.map(card => (
                                        <TypeCardView
                                            key={card.key}
                                            card={card}
                                            size={size}
                                            board={blocker}
                                            offset={offset}
                                            stamp={stamp}
                                            busy={busy}
                                            todX={todX}
                                            onAccept={c => setPending({ kind: 'type', card: c })}
                                            onUnlocked={refreshSoon}
                                        />
                                    ))}
                                </div>
                            ) : (
                                <Card>
                                    <EmptyState
                                        icon="board"
                                        title={t('board.empty.title')}
                                        text={t('board.empty.text')}
                                    />
                                </Card>
                            )}

                            <p className="run_ui-footnote">
                                <Icon name="info" size={13} />
                                <span>{t('board.footnote')}</span>
                            </p>
                        </>
                    )}
                </>
            ) : null}

            <ConfirmDialog
                open={pending !== null}
                title={
                    pending?.kind === 'boss'
                        ? t('board.confirm.boss_title', { mission: pendingLabel })
                        : t('board.confirm.title', { type: pendingLabel })
                }
                message={confirmMessage}
                confirmLabel={
                    pending?.kind === 'boss'
                        ? t('board.confirm.boss_accept')
                        : t('board.confirm.accept', { type: pendingLabel })
                }
                onConfirm={accept}
                onCancel={() => setPending(null)}
                busy={busy}
            />
        </Screen>
    );
}
