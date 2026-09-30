// Officer UI · Home (screen key 'home', title key 'ui.screen.home').

import {
    Avatar,
    Badge,
    Button,
    Card,
    EmptyState,
    ErrorState,
    Grid,
    Icon,
    LoadingBlock,
    ProgressBar,
    Screen,
    XpBadge,
} from '../../shared/components';
import type { IconName } from '../../shared/components';
import { cx } from '../../shared/cx';
import { asArray } from '../../shared/data';
import { formatMoney, formatNumber } from '../../shared/format';
import { usePush, useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { useNavigate } from '../../shared/navigation';
import { useSession } from '../../shared/session';
import type { Goal, HomeData } from '../../shared/types';
import type { HomeStreak, HomeTypeOfTheDay } from '../../types/economy';
import type { HomeExtras } from '../../types/profile';
import { RewardsLocker } from '../components/RewardsLocker';
import './Home.css';

// getHome plus the parity-plus extras (modules/scoring homeData: missionsToday, the home:extras hook).
type HomeView = HomeData & { missionsToday?: { n: number; max: number } | null; extras?: HomeExtras | null };
type Card = HomeData['card'];
// card.level is CP.Scoring.xpLevel: the band label and badge plus the number and where the level starts
type CardLevel = Card['level'] & { n?: number; levelXp?: number; nextLevelXp?: number | null };

function ChampionsBanner({ champions }: { champions: NonNullable<HomeData['champions']> }) {
    return (
        <div className="economy-champions" role="note">
            <span className="economy-champions__icon" aria-hidden>
                <Icon name="trophy" size={18} />
            </span>
            <div className="economy-champions__text">
                <span className="economy-champions__eyebrow">{t('officer.home.champions_eyebrow')}</span>
                <span className="economy-champions__line">
                    {t('officer.home.champions', { department: champions.department, season: champions.season })}
                </span>
            </div>
        </div>
    );
}

function XpBar({ card }: { card: Card }) {
    const level = card.level as CardLevel;
    const start = level.levelXp ?? level.xp;
    const next = level.nextLevelXp !== undefined ? level.nextLevelXp : level.next;
    if (next === null || next === undefined || next <= start) {
        return (
            <div className="economy-xp">
                <ProgressBar
                    value={1}
                    max={1}
                    tone="accent"
                    size="md"
                    label={t('officer.home.xp')}
                    showValue={t('officer.home.xp_value', { xp: formatNumber(card.xp) })}
                />
                <div className="economy-xp__hint">{t('officer.home.xp_max')}</div>
            </div>
        );
    }
    const into = Math.max(0, card.xp - start);
    const span = Math.max(1, next - start);
    return (
        <div className="economy-xp">
            <ProgressBar
                value={Math.min(into, span)}
                max={span}
                tone="accent"
                size="md"
                label={t('officer.home.xp')}
                showValue={t('officer.home.xp_progress', { xp: formatNumber(card.xp), next: formatNumber(next) })}
            />
            <div className="economy-xp__hint">
                {level.n
                    ? t('officer.home.xp_to_level', { xp: formatNumber(Math.max(0, next - card.xp)), n: level.n + 1 })
                    : t('officer.home.xp_to_next', { xp: formatNumber(Math.max(0, next - card.xp)) })}
            </div>
        </div>
    );
}

function CardStat({
    icon,
    label,
    value,
    hint,
    tone,
}: {
    icon: IconName;
    label: string;
    value: string;
    hint?: string;
    tone?: 'accent' | 'success' | 'muted';
}) {
    return (
        <div className="economy-stat">
            <div className="economy-stat__label">
                <Icon name={icon} size={14} />
                <span>{label}</span>
            </div>
            <div
                className={cx(
                    'economy-stat__value',
                    'cp-num',
                    value.length > 12 ? 'is-xlong' : value.length > 9 && 'is-long',
                )}
                title={value}
            >
                {value}
            </div>
            {hint ? <div className={cx('economy-stat__hint', tone && `is-${tone}`)}>{hint}</div> : null}
        </div>
    );
}

function OfficerCard({ card, missionsToday }: { card: Card; missionsToday?: HomeView['missionsToday'] }) {
    const session = useSession();
    const level = card.level as CardLevel;
    const levelText = level.n
        ? level.label
            ? t('officer.home.level_named', { n: level.n, label: level.label })
            : t('officer.home.level', { n: level.n })
        : level.label;
    const streak = (card.streak ?? { days: 0, graceLeft: false }) as HomeStreak;
    const days = Math.max(0, Math.floor(streak.days ?? 0));
    const graceOff = streak.graceDays === 0;
    const streakValue = days === 1 ? t('officer.home.streak_day') : t('officer.home.streak_days', { n: days });
    const streakHint =
        days <= 0
            ? t('officer.home.streak_none')
            : graceOff
              ? t('officer.home.grace_off')
              : streak.graceLeft
                ? t('officer.home.grace_left')
                : t('officer.home.grace_used');
    return (
        <Card padding="lg" className="economy-officer">
            <div className="economy-officer__grid">
                <div className="economy-officer__main">
                    <div className="economy-officer__who">
                        <Avatar
                            avatar={session.officer?.avatar}
                            name={card.name}
                            size={56}
                            className="economy-officer__avatar"
                        />
                        <div className="economy-officer__ident">
                            <div className="economy-officer__name" title={card.name}>
                                {card.name}
                            </div>
                            <div className="economy-officer__meta">
                                <span>{card.rank}</span>
                                <span className="economy-officer__dot" aria-hidden>
                                    ·
                                </span>
                                <span className={cx('cp-num', !card.callsign && 'economy-muted')}>
                                    {card.callsign || t('common.no_callsign')}
                                </span>
                                <Badge tone="primary" size="sm" variant="solid">
                                    {card.departmentShort}
                                </Badge>
                            </div>
                            <div className="economy-officer__level">
                                <XpBadge badge={card.level.badge} label={levelText} />
                                {missionsToday && missionsToday.max > 0 ? (
                                    <Badge
                                        tone={missionsToday.n >= missionsToday.max ? 'warning' : 'neutral'}
                                        size="sm"
                                        icon="target"
                                    >
                                        {t('officer.home.missions_today', {
                                            n: missionsToday.n,
                                            max: missionsToday.max,
                                        })}
                                    </Badge>
                                ) : null}
                            </div>
                        </div>
                    </div>
                    <XpBar card={card} />
                </div>
                <div className="economy-officer__stats">
                    <CardStat
                        icon="flame"
                        label={t('officer.home.streak')}
                        value={streakValue}
                        hint={streakHint}
                        tone={days > 0 && !graceOff && streak.graceLeft ? 'success' : 'muted'}
                    />
                    <CardStat
                        icon="star"
                        label={t('officer.home.season_points')}
                        value={`${formatNumber(card.seasonPoints)} ${t('common.pts')}`}
                        hint={t('officer.home.season_hint')}
                        tone="muted"
                    />
                    <CardStat
                        icon="dollar"
                        label={t('officer.home.cash_week')}
                        value={formatMoney(card.cashThisWeek)}
                        hint={t('officer.home.cash_hint')}
                        tone="muted"
                    />
                </div>
            </div>
        </Card>
    );
}

function GoalCard({ kind, goal }: { kind: 'daily' | 'weekly'; goal: Goal | null | undefined }) {
    const title = kind === 'daily' ? t('officer.home.goal_daily') : t('officer.home.goal_weekly');
    const icon: IconName = kind === 'daily' ? 'target' : 'calendar';
    if (!goal) {
        return (
            <Card title={title} icon={icon} className="economy-goal" highlight="primary">
                <EmptyState
                    compact
                    icon={icon}
                    title={t('officer.home.goal_none')}
                    text={t('officer.home.goal_none_text')}
                />
            </Card>
        );
    }
    const count = Math.max(1, goal.count);
    const progress = Math.min(Math.max(0, goal.progress), count);
    return (
        <Card
            title={title}
            icon={icon}
            className={cx('economy-goal', goal.done && 'is-done')}
            highlight={goal.done ? 'success' : 'primary'}
        >
            <div className="economy-goal__label">{goal.label}</div>
            <ProgressBar
                value={progress}
                max={count}
                tone={goal.done ? 'success' : 'primary'}
                size="md"
                label={t('officer.home.goal_progress')}
                showValue={`${progress} / ${count}`}
            />
            <div className="economy-goal__foot">
                {goal.done ? (
                    <Badge tone="success" icon="checkCircle">
                        {t('officer.home.goal_earned', { points: formatNumber(goal.points) })}
                    </Badge>
                ) : (
                    <Badge tone="accent" icon="star">
                        {t('officer.home.goal_reward', { points: formatNumber(goal.points) })}
                    </Badge>
                )}
                <span className="economy-goal__hint">
                    {kind === 'daily' ? t('officer.home.goal_daily_hint') : t('officer.home.goal_weekly_hint')}
                </span>
            </div>
        </Card>
    );
}

// 2 -> "2", 1.5 -> "1.5" (config multipliers).
function multiplierText(m: number | undefined, fallback: number): string {
    const n = typeof m === 'number' && isFinite(m) && m > 0 ? m : fallback;
    return String(Math.round(n * 100) / 100);
}

function TypeOfTheDay({ tod, onBoard }: { tod: HomeTypeOfTheDay | null; onBoard: () => void }) {
    return (
        <Card title={t('officer.home.tod')} icon="zap" highlight="accent" className="economy-tod">
            {tod ? (
                <div className="economy-tod__body">
                    <span className="economy-tod__tag">
                        <Icon name="zap" size={15} strokeWidth={2.4} />
                        {tod.label}
                    </span>
                    <p className="economy-tod__text">
                        {t('officer.home.tod_text', { type: tod.label, multiplier: multiplierText(tod.multiplier, 2) })}
                    </p>
                    <p className="economy-tod__note">
                        {t('officer.home.tod_note', { cap: multiplierText(tod.cap, 2) })}
                    </p>
                    <div>
                        <Button variant="secondary" size="sm" iconRight="chevronRight" onClick={onBoard}>
                            {t('officer.home.open_board')}
                        </Button>
                    </div>
                </div>
            ) : (
                <EmptyState compact icon="zap" title={t('officer.home.tod_none')} />
            )}
        </Card>
    );
}

// Kinds sent by modules/leaderboard (weekly_top3, monthly_top3) plus the other kinds the notes list.
const ANNOUNCEMENT_ICONS: Record<string, IconName> = {
    weekly_top3: 'trophy',
    monthly_top3: 'podium',
    weekly_top: 'trophy',
    officer_of_week: 'medal',
    monthly_top: 'podium',
    season: 'flag',
    bounty: 'target',
    commendation: 'medal',
    info: 'info',
};

// "3 mission calls open" with a way to Dispatch (the home:extras callsOpen count).
function CallsOpen({ n, onOpen }: { n: number; onOpen: () => void }) {
    if (n <= 0) return null;
    return (
        <div className="economy-calls" role="note">
            <Icon name="radio" size={16} />
            <span>{t('officer.home.calls_open', { n })}</span>
            <Button variant="secondary" size="sm" iconRight="chevronRight" onClick={onOpen}>
                {t('officer.home.open_dispatch')}
            </Button>
        </div>
    );
}

function Announcements({ list, news }: { list: HomeData['announcements']; news?: HomeExtras['news'] }) {
    const items = [...asArray(news ?? undefined), ...asArray(list)].filter(a => a && typeof a.text === 'string');
    return (
        <Card title={t('officer.home.announcements')} icon="radio" className="economy-news">
            {items.length === 0 ? (
                <EmptyState compact icon="inbox" title={t('officer.home.announcements_none')} />
            ) : (
                <ul className="economy-news__list">
                    {items.map((a, i) => (
                        <li key={`${a.kind}-${i}`} className={cx('economy-news__item', `is-${a.kind}`)}>
                            <span className="economy-news__icon" aria-hidden>
                                <Icon name={ANNOUNCEMENT_ICONS[a.kind] ?? 'info'} size={15} />
                            </span>
                            <span className="economy-news__text">{a.text}</span>
                        </li>
                    ))}
                </ul>
            )}
        </Card>
    );
}

export default function Home() {
    const session = useSession();
    const navigate = useNavigate();
    const { data, loading, error, refetch } = useRequest<HomeView>('getHome', {}, { pollMs: 60000 });
    // push 'run' carries the live view every few seconds during a run and no data once it ended (rows,
    // XP, goals and cash are written by then): refetch only on that last push.
    usePush('run', view => {
        if (view === null || view === undefined) void refetch();
    });
    const openBoard = () => navigate('board');
    const firstName = (data?.card.name ?? session.officer?.name ?? '').split(' ')[0];

    return (
        <Screen
            title={t('ui.screen.home')}
            subtitle={firstName ? t('officer.home.greeting', { name: firstName }) : undefined}
            actions={
                <Button variant="primary" icon="list" onClick={openBoard}>
                    {t('officer.home.open_board')}
                </Button>
            }
            className="economy-home"
        >
            {!data && loading ? <LoadingBlock /> : null}
            {!data && !loading && error ? <ErrorState error={error} onRetry={() => void refetch()} /> : null}
            {data ? (
                <>
                    {data.champions ? <ChampionsBanner champions={data.champions} /> : null}
                    <OfficerCard card={data.card} missionsToday={data.missionsToday} />
                    <CallsOpen n={data.extras?.callsOpen ?? 0} onOpen={() => navigate('dispatch')} />
                    <RewardsLocker />
                    <Grid cols={3} gap={4} className="economy-home__row">
                        <GoalCard kind="daily" goal={data.goals?.daily} />
                        <GoalCard kind="weekly" goal={data.goals?.weekly} />
                        <TypeOfTheDay
                            tod={(data.typeOfTheDay as HomeTypeOfTheDay | null | undefined) ?? null}
                            onBoard={openBoard}
                        />
                    </Grid>
                    <Announcements list={data.announcements} news={data.extras?.news} />
                </>
            ) : null}
        </Screen>
    );
}
