// Admin UI · Leaderboards (screen key 'admin_leaderboards', callback admin:getBoards).

import { useMemo, useState } from 'react';
import {
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
    Row,
    Screen,
    SearchInput,
    SegmentedControl,
    Select,
    Spacer,
    Stat,
    Table,
    Tabs,
    Textarea,
    TextInput,
    type TableColumn,
} from '../../shared/components';
import { cx } from '../../shared/cx';
import { formatDateTime, formatMoney, formatNumber } from '../../shared/format';
import { useAction, useRequest } from '../../shared/hooks';
import { hasKey, t } from '../../shared/i18n';
import { useSession } from '../../shared/session';
import type { FlaggedRow } from '../../types/oversight';
import {
    asList,
    type AdminBoardRow,
    type AdminBoards,
    type AdminRun,
    type BoardPeriod,
    type StuckPayment,
} from '../../types/boards';
import {
    BOARD_PERIODS,
    RankCell,
    boardFilters,
    filterLabel,
    formatClock,
    formatDay,
} from '../../officer/screens/Leaderboard';
import { ResultCell, missionTypeLabel } from '../../officer/screens/Profile';
import { ItemRewardsPanel } from '../components/ItemRewardsPanel';
import './Leaderboards.css';

const AWARD_MAX = 10000; // modules/admin: 1 to 10,000 points per manual award
interface AwardForm {
    citizenid: string;
    name?: string;
    points: number | null;
    reason: string;
}

function StuckPanel({ list }: { list: StuckPayment[] }) {
    return (
        <Card
            title={t('admin.boards.stuck_title')}
            subtitle={t('admin.boards.stuck_hint')}
            icon="alert"
            highlight={list.length ? 'warning' : undefined}
            actions={
                list.length ? (
                    <Badge tone="warning" size="sm">
                        {formatNumber(list.length)}
                    </Badge>
                ) : null
            }
            padding="sm"
            className="boards-stuck"
        >
            {list.length ? (
                <ul className="boards-stuck__list">
                    {list.map(p => (
                        <li key={p.rowId} className="boards-stuck__item">
                            <div className="boards-stuck__head">
                                <span className="boards-strong">{p.name || p.citizenid}</span>
                                {p.callsign ? <span className="boards-muted">{p.callsign}</span> : null}
                                <Spacer />
                                <Money amount={p.amount} className="boards-stuck__amount" />
                            </div>
                            <div className="boards-stuck__meta">
                                <span>{p.missionLabel}</span>
                                <span className="cp-num">{formatDateTime(p.createdAt)}</span>
                                <span className="cp-num">{t('admin.boards.row_id', { id: p.rowId })}</span>
                            </div>
                            <code className="boards-stuck__trans cp-selectable" title={t('admin.boards.trans_hint')}>
                                {p.transId}
                            </code>
                        </li>
                    ))}
                </ul>
            ) : (
                <EmptyState
                    compact
                    icon="checkCircle"
                    title={t('admin.boards.stuck_none')}
                    text={t('admin.boards.stuck_none_text')}
                />
            )}
        </Card>
    );
}

const flagLabel = (reason: string | null | undefined) =>
    reason && hasKey(`flag.${reason}`) ? t(`flag.${reason}`) : t('flag.flagged');

export function FlaggedPanel({
    list,
    loading,
    onDecide,
}: {
    list: FlaggedRow[];
    loading?: boolean;
    onDecide: (row: FlaggedRow, decision: 'approve' | 'void') => void;
}) {
    return (
        <Card
            title={t('admin.boards.flagged_title')}
            subtitle={t('admin.boards.flagged_hint')}
            icon="flag"
            highlight={list.length ? 'warning' : undefined}
            actions={
                list.length ? (
                    <Badge tone="warning" size="sm">
                        {formatNumber(list.length)}
                    </Badge>
                ) : null
            }
            padding="sm"
            className="boards-stuck boards-flagged"
        >
            {!list.length && loading ? (
                <LoadingBlock />
            ) : list.length ? (
                <ul className="boards-stuck__list">
                    {list.map(r => (
                        <li key={r.rowId} className="boards-stuck__item">
                            <div className="boards-stuck__head">
                                <span className="boards-strong boards-ellipsis" title={r.name}>
                                    {r.name || r.citizenid}
                                </span>
                                {r.callsign ? <span className="boards-muted">{r.callsign}</span> : null}
                                <Spacer />
                                <Badge size="sm" tone="danger" variant="outline" icon="flag">
                                    {flagLabel(r.flagReason)}
                                </Badge>
                            </div>
                            <div className="boards-stuck__meta">
                                <span className="boards-ellipsis" title={r.missionLabel}>
                                    {r.missionLabel}
                                </span>
                                <span className="cp-num">{formatDateTime(r.createdAt)}</span>
                                <span className="cp-num">{t('admin.boards.row_id', { id: r.rowId })}</span>
                            </div>
                            {r.flagDetail ? (
                                <div className="boards-stuck__meta">
                                    <span className="boards-ellipsis" title={r.flagDetail}>
                                        {r.flagDetail}
                                    </span>
                                </div>
                            ) : null}
                            <Row gap={1} wrap>
                                <span className="cp-num boards-strong">{formatNumber(r.points)}</span>
                                <Money amount={r.cash} />
                                <Spacer />
                                <Button
                                    size="sm"
                                    variant="secondary"
                                    icon="check"
                                    onClick={() => onDecide(r, 'approve')}
                                >
                                    {t('sup.review.approve')}
                                </Button>
                                <Button size="sm" variant="danger" icon="xCircle" onClick={() => onDecide(r, 'void')}>
                                    {t('sup.review.void')}
                                </Button>
                            </Row>
                        </li>
                    ))}
                </ul>
            ) : (
                <EmptyState
                    compact
                    icon="shieldCheck"
                    title={t('sup.review.empty_flagged_title')}
                    text={t('admin.boards.flagged_none_text')}
                />
            )}
        </Card>
    );
}

// Boards or Item rewards (the optional item rewards, modules/rewards)
type AdminBoardsView = 'boards' | 'rewards';

function ViewTabs({ value, onChange }: { value: AdminBoardsView; onChange: (v: AdminBoardsView) => void }) {
    const items: { key: AdminBoardsView; label: string }[] = [
        { key: 'boards', label: t('admin.rewards.tab_boards') },
        { key: 'rewards', label: t('admin.rewards.tab') },
    ];
    return (
        <SegmentedControl
            size="sm"
            value={value}
            onChange={onChange}
            items={items}
            aria-label={t('admin.rewards.tabs')}
            className="boards-admin-view"
        />
    );
}

export default function AdminLeaderboards() {
    const session = useSession();
    const { run, busy } = useAction();
    const departments = asList(session.config?.departments);
    const [period, setPeriod] = useState<BoardPeriod>('weekly');
    const [filter, setFilter] = useState('overall');
    const [department, setDepartment] = useState(departments[0]?.key ?? '');
    const [list, setList] = useState<'ranked' | 'unranked'>('ranked');
    const [search, setSearch] = useState('');
    const [officer, setOfficer] = useState<AdminBoardRow | null>(null);
    const [voidRun, setVoidRun] = useState<AdminRun | null>(null);
    const [award, setAward] = useState<AwardForm | null>(null);
    const [review, setReview] = useState<{ row: FlaggedRow; decision: 'approve' | 'void' } | null>(null);
    const [view, setView] = useState<AdminBoardsView>('boards');
    const flaggedReq = useRequest<{ flagged: FlaggedRow[] }>('admin:getFlagged', {}, { pollMs: 60000 });
    const flaggedRows = asList(flaggedReq.data?.flagged);

    const allTime = period === 'alltime';
    const eff = allTime ? 'overall' : filter;
    const args = useMemo(
        () => ({ period, filter: eff, ...(eff === 'department' ? { department } : {}) }),
        [period, eff, department],
    );
    const { data, loading, error, refetch } = useRequest<AdminBoards>('admin:getBoards', args, { pollMs: 60000 });
    const runsReq = useRequest<AdminBoards>(
        'admin:getBoards',
        { ...args, citizenid: officer?.citizenid },
        { skip: !officer },
    );

    const board =
        data &&
        data.period === period &&
        data.filter === eff &&
        (eff !== 'department' || !data.department || !department || data.department === department)
            ? data
            : null;
    const rows = asList(list === 'ranked' ? board?.rows : board?.unranked);
    const q = search.trim().toLowerCase();
    const shown = q
        ? rows.filter(r => [r.realName, r.name, r.callsign ?? '', r.citizenid].some(v => v.toLowerCase().includes(q)))
        : rows;
    const ranked = asList(board?.rows);
    const stuck = asList(board?.stuck);
    const totalPoints = ranked.reduce((s, r) => s + (Number(r.points) || 0), 0);
    const totalCash = [...ranked, ...asList(board?.unranked)].reduce((s, r) => s + (Number(r.cash) || 0), 0);
    const officerRuns = runsReq.data && runsReq.data.citizenid === officer?.citizenid ? asList(runsReq.data.runs) : [];

    const openAward = (r?: AdminBoardRow | null) =>
        setAward({ citizenid: r?.citizenid ?? '', name: r?.realName, points: null, reason: '' });
    const awardValid =
        !!award &&
        /^[A-Za-z0-9_-]{1,50}$/.test(award.citizenid.trim()) &&
        award.points !== null &&
        award.points >= 1 &&
        award.points <= AWARD_MAX &&
        !!award.reason.trim();

    const submitAward = async () => {
        if (!award || !awardValid) return;
        const res = await run(
            'server:admin:awardPoints',
            { citizenid: award.citizenid.trim(), points: award.points, reason: award.reason.trim() },
            {
                success: 'admin.boards.awarded',
                successVars: { points: formatNumber(award.points ?? 0), who: award.name ?? award.citizenid },
            },
        );
        if (res.ok) {
            setAward(null);
            void refetch();
            if (officer) void runsReq.refetch();
        }
    };

    const submitVoid = async (reason: string) => {
        if (!voidRun) return;
        const res = await run(
            'server:admin:voidRun',
            { rowId: voidRun.id, reason },
            { success: 'admin.boards.voided' },
        );
        if (res.ok) {
            setVoidRun(null);
            void refetch();
            void runsReq.refetch();
        }
    };

    const submitReview = async (reason: string) => {
        if (!review) return;
        const res = await run(
            'server:admin:reviewFlagged',
            { rowId: review.row.rowId, decision: review.decision, reason },
            {
                success: review.decision === 'approve' ? 'sup.review.approved' : 'sup.review.voided',
            },
        );
        setReview(null);
        if (res.ok) {
            void flaggedReq.refetch();
            void refetch();
            if (officer) void runsReq.refetch();
        }
    };

    const columns: TableColumn<AdminBoardRow>[] = [
        { key: 'rank', header: t('leaderboard.col.rank'), width: 76, render: r => <RankCell rank={r.rank} /> },
        {
            key: 'officer',
            header: t('leaderboard.col.officer'),
            render: r => (
                <span className="boards-admin-officer">
                    <span className="boards-admin-officer__name">
                        <span className="boards-ellipsis" title={r.realName}>
                            {r.realName}
                        </span>
                        {r.hidden ? (
                            <Badge size="sm" icon="eye" title={t('admin.boards.hidden_hint', { shown: r.name })}>
                                {t('admin.boards.hidden')}
                            </Badge>
                        ) : null}
                    </span>
                    <span className="boards-admin-officer__sub cp-num">
                        {[r.callsign || t('common.no_callsign'), r.citizenid].join(' · ')}
                    </span>
                </span>
            ),
        },
        {
            key: 'dept',
            header: t('leaderboard.col.dept'),
            width: 80,
            render: r => (r.departmentShort ? <Badge size="sm">{r.departmentShort}</Badge> : null),
        },
        { key: 'runs', header: t('leaderboard.col.runs'), numeric: true, width: 72, render: r => formatNumber(r.runs) },
        {
            key: 'failed',
            header: t('leaderboard.col.failed'),
            numeric: true,
            width: 72,
            render: r => formatNumber(r.failed),
        },
        {
            key: 'points',
            header: allTime ? t('leaderboard.col.xp') : t('leaderboard.col.points'),
            numeric: true,
            width: 100,
            render: r => <span className="boards-strong">{formatNumber(r.points)}</span>,
        },
        {
            key: 'cash',
            header: t('admin.boards.col.cash'),
            numeric: true,
            width: 110,
            render: r => <Money amount={r.cash} />,
        },
        {
            key: 'actions',
            header: '',
            width: 84,
            align: 'right',
            render: r => (
                <span className="boards-row-actions">
                    <IconButton
                        icon="plus"
                        size="sm"
                        variant="ghost"
                        label={t('admin.boards.award_for', { name: r.realName })}
                        onClick={e => {
                            e.stopPropagation();
                            openAward(r);
                        }}
                    />
                    <Icon name="chevronRight" size={16} className="boards-row-chevron" />
                </span>
            ),
        },
    ];

    const runColumns: TableColumn<AdminRun>[] = [
        {
            key: 'createdAt',
            header: t('profile.col.when'),
            width: 124,
            render: r => <span className="boards-when cp-num">{formatDateTime(r.createdAt)}</span>,
        },
        {
            key: 'mission',
            header: t('profile.col.mission'),
            render: r => (
                <span className="boards-mission">
                    <span className="boards-mission__label" title={r.missionLabel}>
                        {r.missionLabel}
                    </span>
                    <span className="boards-mission__type">{`${missionTypeLabel(r.missionType, session)} · ${r.departmentShort} · #${r.id}`}</span>
                </span>
            ),
        },
        {
            key: 'state',
            header: t('profile.col.result'),
            width: 180,
            render: r => (
                <ResultCell
                    state={r.state}
                    endReason={r.endReason}
                    flagged={r.flagged}
                    voided={r.voided}
                    flagReason={r.flagReason}
                />
            ),
        },
        {
            key: 'points',
            header: t('profile.col.points'),
            numeric: true,
            width: 84,
            render: r => <span className={cx(r.voided && 'boards-struck')}>{formatNumber(r.points)}</span>,
        },
        {
            key: 'cash',
            header: t('profile.col.cash'),
            numeric: true,
            width: 88,
            render: r => <Money amount={r.cash} />,
        },
        {
            key: 'void',
            header: '',
            width: 108,
            align: 'right',
            render: r =>
                r.voided || r.missionType === 'goal' ? null : (
                    <Button size="sm" variant="danger" icon="xCircle" onClick={() => setVoidRun(r)}>
                        {t('admin.boards.void')}
                    </Button>
                ),
        },
    ];

    const tabs = BOARD_PERIODS.map(p => ({ key: p, label: t(`leaderboard.period.${p}`) }));
    const filterOptions = boardFilters(session).map(f => ({ value: f, label: filterLabel(f, session) }));

    if (view === 'rewards') {
        return (
            <Screen
                title={t('ui.screen.admin_leaderboards')}
                subtitle={t('admin.rewards.subtitle')}
                className="boards-admin-boards"
            >
                <ViewTabs value={view} onChange={setView} />
                <ItemRewardsPanel />
            </Screen>
        );
    }

    return (
        <Screen
            title={t('ui.screen.admin_leaderboards')}
            subtitle={t('admin.boards.subtitle')}
            actions={
                <>
                    {board ? (
                        <Badge size="sm" icon="clock">
                            {t('leaderboard.updated', { time: formatClock(board.updatedAt) })}
                        </Badge>
                    ) : null}
                    <IconButton
                        icon="refresh"
                        label={t('leaderboard.refresh')}
                        loading={loading && !!data}
                        onClick={() => void refetch()}
                    />
                    <Button variant="primary" icon="plus" onClick={() => openAward(null)}>
                        {t('admin.boards.award')}
                    </Button>
                </>
            }
            className="boards-admin-boards"
        >
            <ViewTabs value={view} onChange={setView} />
            <div className="boards-admin-toolbar">
                <Tabs items={tabs} value={period} onChange={setPeriod} aria-label={t('leaderboard.periods')} />
                <Row gap={2} wrap>
                    <Select
                        value={eff}
                        onChange={setFilter}
                        options={filterOptions}
                        disabled={allTime}
                        aria-label={t('leaderboard.filters')}
                        className="boards-admin-select"
                    />
                    {eff === 'department' ? (
                        <Select
                            value={department}
                            onChange={setDepartment}
                            options={departments.map(d => ({ value: d.key, label: `${d.short} · ${d.label}` }))}
                            aria-label={t('leaderboard.department')}
                            className="boards-admin-select"
                        />
                    ) : null}
                    <SegmentedControl
                        size="sm"
                        value={list}
                        onChange={setList}
                        items={[
                            {
                                key: 'ranked',
                                label: t('admin.boards.ranked'),
                                badge: board ? formatNumber(asList(board.rows).length) : undefined,
                            },
                            {
                                key: 'unranked',
                                label: t('admin.boards.unranked'),
                                badge: board ? formatNumber(asList(board.unranked).length) : undefined,
                            },
                        ]}
                        aria-label={t('admin.boards.list')}
                    />
                    <Spacer />
                    <SearchInput
                        value={search}
                        onChange={setSearch}
                        placeholder={t('admin.boards.search')}
                        className="boards-admin-search"
                    />
                </Row>
            </div>

            {board ? (
                <div className="boards-admin-stats">
                    <Stat
                        size="sm"
                        label={t('admin.boards.stat.window')}
                        value={
                            period === 'alltime'
                                ? t('leaderboard.period.alltime')
                                : period === 'season'
                                  ? (board.season?.name ?? '–')
                                  : t('admin.boards.stat.since', { from: formatDay(board.window?.fromDate) })
                        }
                        icon="calendar"
                    />
                    <Stat
                        size="sm"
                        label={t('admin.boards.stat.ranked')}
                        value={formatNumber(ranked.length)}
                        hint={t('admin.boards.stat.min', { n: board.minRuns })}
                        icon="users"
                    />
                    <Stat
                        size="sm"
                        label={allTime ? t('admin.boards.stat.xp') : t('admin.boards.stat.points')}
                        value={formatNumber(totalPoints)}
                        icon="star"
                    />
                    <Stat
                        size="sm"
                        label={t('admin.boards.stat.cash')}
                        value={formatMoney(totalCash)}
                        icon="dollar"
                        tone="success"
                    />
                    <Stat
                        size="sm"
                        label={t('admin.boards.stat.stuck')}
                        value={formatNumber(stuck.length)}
                        icon="alert"
                        tone={stuck.length ? 'warning' : 'neutral'}
                    />
                </div>
            ) : null}

            {!board && loading ? (
                <LoadingBlock />
            ) : !board && error ? (
                <ErrorState error={error} onRetry={() => void refetch()} />
            ) : (
                <Grid cols="minmax(0, 1fr) 360px" gap={4} align="start" className="boards-admin-boards-grid">
                    <Table
                        className="boards-fixed"
                        columns={columns}
                        rows={shown}
                        rowKey={r => r.citizenid}
                        onRowClick={r => setOfficer(r)}
                        maxHeight={520}
                        dense
                        loading={loading && !board}
                        empty={
                            period === 'season' && board && !board.season
                                ? t('leaderboard.no_season_title')
                                : q
                                  ? t('admin.boards.no_match')
                                  : list === 'ranked'
                                    ? t('leaderboard.empty_text', { n: board?.minRuns ?? 3 })
                                    : t('admin.boards.unranked_empty')
                        }
                        aria-label={t('ui.screen.admin_leaderboards')}
                    />
                    <div className="boards-admin-side">
                        <FlaggedPanel
                            list={flaggedRows}
                            loading={flaggedReq.loading}
                            onDecide={(row, decision) => setReview({ row, decision })}
                        />
                        <StuckPanel list={stuck} />
                    </div>
                </Grid>
            )}

            <Dialog
                open={!!officer}
                onClose={() => setOfficer(null)}
                size="lg"
                title={officer ? t('admin.boards.runs_title', { name: officer.realName }) : ''}
                description={
                    officer
                        ? t('admin.boards.runs_desc', {
                              board: `${t(`leaderboard.period.${period}`)} · ${filterLabel(eff, session)}`,
                          })
                        : undefined
                }
                footer={
                    <>
                        <Button variant="secondary" icon="plus" onClick={() => openAward(officer)}>
                            {t('admin.boards.award')}
                        </Button>
                        <Button variant="primary" onClick={() => setOfficer(null)}>
                            {t('common.close')}
                        </Button>
                    </>
                }
            >
                {runsReq.error && !runsReq.data ? (
                    <ErrorState compact error={runsReq.error} onRetry={() => void runsReq.refetch()} />
                ) : (
                    <Table
                        className="boards-fixed"
                        columns={runColumns}
                        rows={officerRuns}
                        rowKey={r => r.id}
                        dense
                        loading={runsReq.loading}
                        maxHeight={400}
                        empty={t('admin.boards.runs_empty')}
                    />
                )}
            </Dialog>

            <ConfirmDialog
                open={!!voidRun}
                tone="danger"
                title={t('admin.boards.void_title')}
                message={
                    voidRun
                        ? t('admin.boards.void_message', {
                              mission: voidRun.missionLabel,
                              when: formatDateTime(voidRun.createdAt),
                              points: formatNumber(voidRun.points),
                          })
                        : ''
                }
                confirmLabel={t('admin.boards.void')}
                reason={{ required: true, maxLength: 255, placeholder: t('admin.boards.void_placeholder') }}
                onConfirm={submitVoid}
                onCancel={() => setVoidRun(null)}
                busy={busy}
            />

            <ConfirmDialog
                open={!!review}
                tone={review?.decision === 'void' ? 'danger' : 'primary'}
                title={
                    review
                        ? t(review.decision === 'approve' ? 'sup.review.approve_title' : 'sup.review.void_title')
                        : ''
                }
                message={
                    review
                        ? t(review.decision === 'approve' ? 'sup.review.approve_message' : 'sup.review.void_message', {
                              name: review.row.name,
                              mission: review.row.missionLabel,
                          })
                        : ''
                }
                confirmLabel={
                    review ? t(review.decision === 'approve' ? 'sup.review.approve' : 'sup.review.void') : undefined
                }
                reason={{
                    required: true,
                    label: t('common.reason'),
                    maxLength: 255,
                    placeholder: t('sup.review.reason_placeholder'),
                }}
                onConfirm={submitReview}
                onCancel={() => setReview(null)}
                busy={busy}
            />

            <Dialog
                open={!!award}
                onClose={() => (busy ? undefined : setAward(null))}
                size="sm"
                title={t('admin.boards.award_title')}
                description={t('admin.boards.award_desc')}
                footer={
                    <>
                        <Button variant="ghost" onClick={() => setAward(null)} disabled={busy}>
                            {t('common.cancel')}
                        </Button>
                        <Button
                            variant="primary"
                            icon="plus"
                            loading={busy}
                            disabled={!awardValid}
                            onClick={() => void submitAward()}
                        >
                            {t('admin.boards.award')}
                        </Button>
                    </>
                }
            >
                {award ? (
                    <div className="boards-award-form">
                        <Field label={t('admin.boards.citizenid')} required hint={award.name ? award.name : undefined}>
                            <TextInput
                                value={award.citizenid}
                                onChange={v => setAward({ ...award, citizenid: v, name: undefined })}
                                maxLength={50}
                                placeholder="ABC12345"
                            />
                        </Field>
                        <Field label={t('admin.boards.points')} required>
                            <NumberInput
                                value={award.points}
                                onChange={v => setAward({ ...award, points: v })}
                                min={1}
                                max={AWARD_MAX}
                                integer
                                stepper
                                formatRange={formatNumber}
                            />
                        </Field>
                        <Field label={t('common.reason')} required>
                            <Textarea
                                value={award.reason}
                                onChange={v => setAward({ ...award, reason: v })}
                                maxLength={255}
                                rows={3}
                                placeholder={t('admin.boards.reason_placeholder')}
                            />
                        </Field>
                    </div>
                ) : null}
            </Dialog>
        </Screen>
    );
}
