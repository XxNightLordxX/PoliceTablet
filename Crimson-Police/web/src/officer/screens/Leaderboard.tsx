// Officer UI · Leaderboard (screen key 'leaderboard', callback getBoard).

import { useEffect, useMemo, useState } from 'react';
import {
    Avatar,
    Badge,
    EmptyState,
    ErrorState,
    Icon,
    IconButton,
    LoadingBlock,
    Row,
    Screen,
    SegmentedControl,
    Select,
    Spacer,
    Table,
    Tabs,
    type TableColumn,
} from '../../shared/components';
import { cx } from '../../shared/cx';
import { fmtDate, fmtDateTime, formatNumber } from '../../shared/format';
import { useRequest } from '../../shared/hooks';
import { hasKey, t } from '../../shared/i18n';
import { useNavigate } from '../../shared/navigation';
import { useSession } from '../../shared/session';
import type { Session } from '../../shared/types';
import { asList, type BoardPeriod, type BoardRowView, type BoardView } from '../../types/boards';
import './Leaderboard.css';

export const BOARD_PERIODS: BoardPeriod[] = ['weekly', 'monthly', 'season', 'alltime'];
const DEFAULT_FILTERS = ['overall', 'patrol', 'training', 'investigation', 'tactical', 'unit', 'cross', 'department'];
const REFRESH_MS = 60000;

// Label of a board filter: mission types from the session config, the rest from the locale.
export function filterLabel(key: string, session: Session): string {
    const type = asList(session.config?.missionTypes).find(m => m.key === key);
    if (type) return type.label;
    return t(`leaderboard.filter.${key}`);
}

export function boardFilters(session: Session): string[] {
    const list = asList(session.config?.filters);
    return list.length ? list : DEFAULT_FILTERS;
}

// A server date ('YYYY-MM-DD', the server's calendar) as its noon UTC, formatted by format.ts: noon keeps the same
// calendar day in every time zone from UTC-11 to UTC+11, so the player's own zone never moves a week start.
function serverDateTs(day: string | null | undefined): number | null {
    const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(day ?? '');
    if (!m) return null;
    return Math.floor(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]), 12) / 1000);
}

// "21 Sep 2026" from a server date ('YYYY-MM-DD').
export function formatDay(day: string | null | undefined): string {
    const ts = serverDateTs(day);
    return ts === null ? '' : fmtDate(ts);
}

// "30 Sep 2026, 14:05" from os.time() seconds.
export function formatClock(ts: number | null | undefined): string {
    if (!ts) return '';
    return fmtDateTime(ts);
}

// Rank by label (points is XP on the All-time tab).
export function metricLabel(metric: string, allTime = false): string {
    if (metric === 'points' && allTime) return t('leaderboard.col.xp');
    return hasKey(`leaderboard.metric.${metric}`) ? t(`leaderboard.metric.${metric}`) : metric;
}

// A row's value for the metric: points and XP with their unit, Judgement as a share.
export function metricValue(r: BoardRowView, metric: string, allTime = false) {
    if (metric === 'judgement') return <span className="boards-points">{`${r.value ?? 0}%`}</span>;
    if (metric === 'points' || !metric) {
        return (
            <span className="boards-points">
                {formatNumber(r.points)} <small>{allTime ? t('leaderboard.xp') : t('common.pts')}</small>
            </span>
        );
    }
    return <span className="boards-points">{formatNumber(r.value ?? 0)}</span>;
}

// The level number next to a name (the header and rows carry the number only).
export function LevelTag({ level }: { level?: { n: number; badge: string } | null }) {
    if (!level) return null;
    return (
        <Badge tone={level.badge as 'grey'} size="sm" className="boards-level">
            {t('leaderboard.level', { n: level.n })}
        </Badge>
    );
}

// A callsign cell (ellipsised, full text as tooltip), or "No callsign" when Qbox has none.
export function CallsignText({ callsign }: { callsign: string | null | undefined }) {
    if (!callsign) return <span className="boards-ellipsis boards-muted">{t('common.no_callsign')}</span>;
    return (
        <span className="boards-ellipsis" title={callsign}>
            {callsign}
        </span>
    );
}

// Rank cell: gold/silver/bronze medals for 1–3, a dash when not ranked.
export function RankCell({ rank }: { rank: number }) {
    if (!rank) return <span className="boards-rank boards-rank--none">–</span>;
    if (rank <= 3) {
        return (
            <span className={cx('boards-medal', `boards-medal--${rank}`)} title={t(`leaderboard.medal.${rank}`)}>
                <Icon name="medal" size={13} strokeWidth={2.2} />
                <span className="cp-num">{rank}</span>
            </span>
        );
    }
    return <span className="boards-rank cp-num">{rank}</span>;
}

function windowText(board: BoardView | null, period: BoardPeriod): string {
    if (!board) return '';
    if (period === 'alltime') return t('leaderboard.window.alltime');
    if (period === 'season') {
        if (!board.season) return t('leaderboard.window.no_season');
        return board.season.active
            ? t('leaderboard.window.season', { name: board.season.name })
            : t('leaderboard.window.season_ended', { name: board.season.name });
    }
    const from = board.window?.fromDate;
    if (!from) return '';
    if (period === 'monthly') return t('leaderboard.window.monthly', { month: formatDay(from) });
    return t('leaderboard.window.weekly', { from: formatDay(from) });
}

export default function Leaderboard() {
    const session = useSession();
    const navigate = useNavigate();
    const myDept = session.officer?.department ?? '';
    const myCid = session.officer?.citizenid ?? '';
    const [period, setPeriod] = useState<BoardPeriod>('weekly');
    const [filter, setFilter] = useState<string>('overall');
    const [department, setDepartment] = useState<string>(myDept);
    const [metric, setMetric] = useState<string>('points');
    const metrics = asList(session.config?.leaderboardMetrics);

    const allTime = period === 'alltime';
    const effectiveFilter = allTime ? 'overall' : filter;
    const args = useMemo(
        () => ({
            period,
            filter: effectiveFilter,
            ...(effectiveFilter === 'department' ? { department } : {}),
            ...(metric !== 'points' ? { metric } : {}),
        }),
        [period, effectiveFilter, department, metric],
    );
    const { data, loading, error, refetch } = useRequest<BoardView>('getBoard', args, { pollMs: REFRESH_MS });

    // A stale reply for other args must not be shown as the current board.
    const board =
        data &&
        data.period === period &&
        data.filter === effectiveFilter &&
        (data.metric ?? 'points') === metric &&
        (effectiveFilter !== 'department' || !data.department || data.department === department)
            ? data
            : null;
    const rows = asList(board?.rows);
    const me = board?.me ?? null;
    const minRuns = board?.minRuns ?? 3;
    const meInList = !!me && me.rank > 0 && rows.some(r => r.citizenid === me.citizenid);

    useEffect(() => {
        if (!department && myDept) setDepartment(myDept);
    }, [department, myDept]);

    const tabs = BOARD_PERIODS.map(p => ({
        key: p,
        label: t(`leaderboard.period.${p}`),
        icon: p === 'alltime' ? ('star' as const) : undefined,
    }));
    const filters = boardFilters(session).map(f => ({
        key: f,
        label: filterLabel(f, session),
        disabled: allTime && f !== 'overall',
    }));
    const deptOptions = asList(session.config?.departments).map(d => ({ value: d.key, label: d.short }));

    const metricOptions = (metrics.length ? metrics : ['points']).map(m => ({
        value: m,
        label: metricLabel(m, allTime),
    }));

    const columns: TableColumn<BoardRowView>[] = [
        { key: 'rank', header: t('leaderboard.col.rank'), width: 76, render: r => <RankCell rank={r.rank} /> },
        {
            key: 'name',
            header: t('leaderboard.col.officer'),
            render: r => (
                <span className="boards-officer">
                    <Avatar avatar={r.avatar} name={r.name} size={26} />
                    <span className="boards-officer__name" title={r.name}>
                        {r.name}
                    </span>
                    <LevelTag level={r.level} />
                    {r.citizenid === myCid ? (
                        <Badge tone="accent" size="sm">
                            {t('leaderboard.you')}
                        </Badge>
                    ) : null}
                </span>
            ),
        },
        {
            key: 'callsign',
            header: t('leaderboard.col.callsign'),
            width: 130,
            render: r => <CallsignText callsign={r.callsign} />,
        },
        {
            key: 'departmentShort',
            header: t('leaderboard.col.dept'),
            width: 90,
            render: r => (r.departmentShort ? <Badge size="sm">{r.departmentShort}</Badge> : null),
        },
        {
            key: 'runs',
            header: allTime ? t('leaderboard.col.runs_life') : t('leaderboard.col.runs'),
            numeric: true,
            width: 90,
            render: r => formatNumber(r.runs),
        },
        {
            key: 'failed',
            header: t('leaderboard.col.failed'),
            numeric: true,
            width: 84,
            render: r => formatNumber(r.failed),
        },
        {
            key: 'points',
            header:
                metric === 'points'
                    ? allTime
                        ? t('leaderboard.col.xp')
                        : t('leaderboard.col.points')
                    : metricLabel(metric, allTime),
            numeric: true,
            width: 140,
            render: r => metricValue(r, metric, allTime),
        },
    ];

    const pinned = me ? (
        <tr
            className={cx('boards-pinned', meInList && 'is-listed')}
            onClick={() => navigate('profile')}
            title={t('leaderboard.open_own')}
        >
            <td>
                <RankCell rank={me.rank} />
            </td>
            <td>
                <span className="boards-officer">
                    <span className="boards-pinned__label">{t('leaderboard.your_position')}</span>
                    <span className="boards-pinned__who">
                        <Avatar avatar={me.avatar} name={me.name} size={26} />
                        <span className="boards-officer__name" title={me.name}>
                            {me.name}
                        </span>
                        <LevelTag level={me.level} />
                        {me.rank > 0 ? null : (
                            <span
                                className="boards-unranked"
                                title={t('leaderboard.unranked_runs', { n: Math.max(1, minRuns - me.runs) })}
                            >
                                {t('leaderboard.unranked_runs', { n: Math.max(1, minRuns - me.runs) })}
                            </span>
                        )}
                    </span>
                </span>
            </td>
            <td>
                <CallsignText callsign={me.callsign} />
            </td>
            <td>{me.departmentShort ? <Badge size="sm">{me.departmentShort}</Badge> : null}</td>
            <td className="cp-num" style={{ textAlign: 'right' }}>
                {formatNumber(me.runs)}
            </td>
            <td className="cp-num" style={{ textAlign: 'right' }}>
                {formatNumber(me.failed)}
            </td>
            <td className="cp-num" style={{ textAlign: 'right' }}>
                {metricValue(me, metric, allTime)}
            </td>
        </tr>
    ) : null;

    const noSeason = period === 'season' && board && !board.season;

    return (
        <Screen
            title={t('ui.screen.leaderboard')}
            subtitle={windowText(board, period) || t('leaderboard.subtitle')}
            actions={
                <>
                    {board ? (
                        <Badge tone="neutral" size="sm" icon="clock" title={t('leaderboard.refresh_hint')}>
                            {t('leaderboard.updated', { time: formatClock(board.updatedAt) })}
                        </Badge>
                    ) : null}
                    <IconButton
                        icon="refresh"
                        label={t('leaderboard.refresh')}
                        size="sm"
                        loading={loading && !!data}
                        onClick={() => void refetch()}
                    />
                </>
            }
            className="boards-leaderboard"
        >
            <div className="boards-toolbar">
                <Tabs items={tabs} value={period} onChange={setPeriod} aria-label={t('leaderboard.periods')} />
                <Row wrap gap={2} className="boards-filters">
                    <SegmentedControl
                        items={filters}
                        value={effectiveFilter}
                        onChange={setFilter}
                        size="sm"
                        aria-label={t('leaderboard.filters')}
                    />
                    {effectiveFilter === 'department' ? (
                        <Select
                            value={department}
                            onChange={setDepartment}
                            options={deptOptions}
                            aria-label={t('leaderboard.department')}
                            title={asList(session.config?.departments).find(d => d.key === department)?.label}
                            className="boards-dept-select"
                        />
                    ) : null}
                    {metricOptions.length > 1 ? (
                        <Select
                            value={metric}
                            onChange={setMetric}
                            options={metricOptions}
                            aria-label={t('leaderboard.rank_by')}
                            title={t('leaderboard.rank_by')}
                            className="boards-metric-select"
                        />
                    ) : null}
                    <Spacer />
                    {allTime ? (
                        <span className="boards-hint">
                            <Icon name="info" size={13} /> {t('leaderboard.alltime_hint')}
                        </span>
                    ) : null}
                    {period === 'season' && board?.season && !board.season.active ? (
                        <Badge tone="warning" size="sm" icon="flag">
                            {t('leaderboard.final_results')}
                        </Badge>
                    ) : null}
                </Row>
            </div>

            {!board && loading ? (
                <LoadingBlock text={t('leaderboard.loading')} />
            ) : !board && error ? (
                <ErrorState error={error} onRetry={() => void refetch()} />
            ) : noSeason ? (
                <EmptyState
                    icon="calendar"
                    title={t('leaderboard.no_season_title')}
                    text={t('leaderboard.no_season_text')}
                />
            ) : (
                <>
                    <Table
                        className="boards-board boards-fixed"
                        columns={columns}
                        rows={rows}
                        rowKey={r => r.citizenid}
                        onRowClick={r => navigate('profile', r.citizenid === myCid ? {} : { citizenid: r.citizenid })}
                        highlightRow={r => r.citizenid === myCid}
                        loading={loading && !board}
                        maxHeight={440}
                        empty={
                            <EmptyState
                                compact
                                icon="trophy"
                                title={t('leaderboard.empty_title')}
                                text={t('leaderboard.empty_text', { n: minRuns })}
                            />
                        }
                        footer={pinned}
                        aria-label={t('ui.screen.leaderboard')}
                    />
                    <p className="boards-footnote">
                        <Icon name="info" size={13} />
                        <span>
                            {t('leaderboard.rules', { n: minRuns, top: board?.topN ?? 25 })}
                            {metric === 'judgement'
                                ? ` ${t('leaderboard.judgement_rule', { n: board?.minDecisions ?? 10 })}`
                                : ''}
                        </span>
                    </p>
                </>
            )}
        </Screen>
    );
}
