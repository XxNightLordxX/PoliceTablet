// Admin UI · Seasons & Challenge (screen key 'admin_seasons', callback admin:getSeasons, actions
// server:admin:startSeason { name }, server:admin:endSeason, server:admin:overrideBounty { objective }).

import { useEffect, useState } from 'react';
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
    KeyValue,
    LoadingBlock,
    Row,
    Screen,
    Select,
    Table,
    TextInput,
    type TableColumn,
} from '../../shared/components';
import { formatDateTime, formatNumber } from '../../shared/format';
import { useAction, useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import {
    asList,
    type BountyHistoryRow,
    type SeasonListRow,
    type SeasonView,
    type SeasonsAdmin,
} from '../../types/boards';
import { BountyCard, DeptBars, modeText } from '../../officer/screens/Challenge';
import { formatDay } from '../../officer/screens/Leaderboard';
import './Seasons.css';

function SeasonFacts({
    season,
    weeks,
    mode,
    minRuns,
}: {
    season: SeasonView;
    weeks: number;
    mode: string;
    minRuns: number;
}) {
    return (
        <div className="boards-season-facts">
            <KeyValue label={t('admin.seasons.started')}>{formatDateTime(season.startsAt)}</KeyValue>
            {season.endsAt ? (
                <KeyValue label={t('admin.seasons.ended_at')}>{formatDateTime(season.endsAt)}</KeyValue>
            ) : null}
            <KeyValue label={t('admin.seasons.week')}>
                <span className="cp-num">{season.week}</span>
            </KeyValue>
            {season.active ? (
                <KeyValue label={t('admin.seasons.weeks_left')}>
                    <span className="cp-num">
                        {t('admin.seasons.weeks_left_value', { n: season.weeksLeft, total: weeks })}
                    </span>
                </KeyValue>
            ) : null}
            <KeyValue label={t('admin.seasons.scoring')}>{modeText(mode)}</KeyValue>
            <KeyValue label={t('admin.seasons.active_rule')}>
                {t('admin.seasons.active_rule_value', { n: minRuns })}
            </KeyValue>
        </div>
    );
}

export default function AdminSeasons() {
    const { data, loading, error, refetch } = useRequest<SeasonsAdmin>('admin:getSeasons', {}, { pollMs: 60000 });
    const { run, busy } = useAction();
    const [startOpen, setStartOpen] = useState(false);
    const [name, setName] = useState('');
    const [endOpen, setEndOpen] = useState(false);
    const [objective, setObjective] = useState('');
    const [overrideOpen, setOverrideOpen] = useState(false);

    const current = data?.current ?? null;
    const shown = current ?? data?.latest ?? null;
    const bounties = asList(data?.bounties);

    useEffect(() => {
        if (data?.bounty?.id) setObjective(data.bounty.id);
    }, [data?.bounty?.id]);

    const startSeason = async () => {
        if (busy || !name.trim()) return;
        const res = await run(
            'server:admin:startSeason',
            { name: name.trim() },
            { success: 'admin.seasons.started_toast', successVars: { name: name.trim() } },
        );
        if (res.ok) {
            setStartOpen(false);
            setName('');
            void refetch();
        }
    };
    const endSeason = async () => {
        const res = await run('server:admin:endSeason', {}, { success: 'admin.seasons.ended_toast' });
        if (res.ok) {
            setEndOpen(false);
            void refetch();
        }
    };
    const overrideBounty = async () => {
        const res = await run(
            'server:admin:overrideBounty',
            { objective },
            { success: 'admin.seasons.override_toast' },
        );
        if (res.ok) {
            setOverrideOpen(false);
            void refetch();
        }
    };

    const historyColumns: TableColumn<BountyHistoryRow>[] = [
        {
            key: 'season',
            header: t('admin.seasons.col.season'),
            render: r => (
                <span className="boards-strong boards-ellipsis" title={r.seasonName}>
                    {r.seasonName}
                </span>
            ),
        },
        {
            key: 'week',
            header: t('admin.seasons.col.week'),
            numeric: true,
            width: 70,
            render: r => formatNumber(r.week),
        },
        {
            key: 'objective',
            header: t('admin.seasons.col.objective'),
            render: r => (
                <Row gap={2} className="boards-cell-row">
                    <span className="boards-ellipsis" title={r.label}>
                        {r.label}
                    </span>
                    {r.current ? (
                        <Badge tone="accent" size="sm">
                            {t('admin.seasons.this_week')}
                        </Badge>
                    ) : null}
                </Row>
            ),
        },
        {
            key: 'window',
            header: t('admin.seasons.col.window'),
            width: 150,
            render: r => (
                <span className="boards-muted cp-num">{`${formatDay(r.startDate)} – ${formatDay(r.endDate)}`}</span>
            ),
        },
        {
            key: 'winner',
            header: t('admin.seasons.col.winner'),
            width: 130,
            render: r =>
                !r.closed ? (
                    <Badge size="sm" dot>
                        {t('admin.seasons.open')}
                    </Badge>
                ) : r.winnerShort ? (
                    <Badge tone="success" size="sm" icon="trophy">
                        {r.winnerShort}
                    </Badge>
                ) : (
                    <span className="boards-muted">{t('admin.seasons.no_winner')}</span>
                ),
        },
        {
            key: 'bonus',
            header: t('admin.seasons.col.bonus'),
            numeric: true,
            width: 100,
            render: r => (r.bonus ? `+${formatNumber(r.bonus)}` : '–'),
        },
    ];

    const seasonColumns: TableColumn<SeasonListRow>[] = [
        {
            key: 'name',
            header: t('admin.seasons.col.name'),
            render: r => (
                <span className="boards-strong boards-ellipsis" title={r.name}>
                    {r.name}
                </span>
            ),
        },
        {
            key: 'startsAt',
            header: t('admin.seasons.col.started'),
            width: 150,
            render: r => formatDateTime(r.startsAt),
        },
        {
            key: 'endsAt',
            header: t('admin.seasons.col.ended'),
            width: 150,
            render: r => (r.endsAt ? formatDateTime(r.endsAt) : '–'),
        },
        {
            key: 'status',
            header: t('admin.seasons.col.champion'),
            width: 160,
            render: r =>
                r.active ? (
                    <Badge tone="success" size="sm" dot>
                        {t('admin.seasons.running')}
                    </Badge>
                ) : r.championShort ? (
                    <Badge tone="gold" size="sm" icon="trophy">
                        {r.championShort}
                    </Badge>
                ) : (
                    <span className="boards-muted">{t('admin.seasons.no_champion')}</span>
                ),
        },
    ];

    if (!data && loading) {
        return (
            <Screen title={t('ui.screen.admin_seasons')}>
                <LoadingBlock />
            </Screen>
        );
    }
    if (!data) {
        return (
            <Screen title={t('ui.screen.admin_seasons')}>
                <ErrorState error={error ?? 'err.internal'} onRetry={() => void refetch()} />
            </Screen>
        );
    }

    return (
        <Screen
            title={t('ui.screen.admin_seasons')}
            subtitle={t('admin.seasons.subtitle')}
            actions={
                <>
                    <Button variant="danger" icon="flag" disabled={!current || busy} onClick={() => setEndOpen(true)}>
                        {t('admin.seasons.end')}
                    </Button>
                    <Button variant="primary" icon="plus" disabled={busy} onClick={() => setStartOpen(true)}>
                        {t('admin.seasons.start')}
                    </Button>
                </>
            }
            className="boards-admin-seasons"
        >
            {!data.enabled ? (
                <Card highlight="warning" padding="sm">
                    <Row gap={2}>
                        <Badge tone="warning" icon="alert">
                            {t('admin.seasons.challenge_off')}
                        </Badge>
                        <span className="boards-muted">{t('admin.seasons.challenge_off_text')}</span>
                    </Row>
                </Card>
            ) : null}

            {shown ? (
                <Card
                    highlight={current ? 'accent' : undefined}
                    icon="calendar"
                    title={shown.name}
                    subtitle={current ? t('admin.seasons.current') : t('admin.seasons.last_season')}
                    actions={
                        current ? (
                            <Badge tone="success" dot>
                                {t('admin.seasons.running')}
                            </Badge>
                        ) : (
                            <Badge>{t('admin.seasons.ended')}</Badge>
                        )
                    }
                >
                    <SeasonFacts
                        season={shown}
                        weeks={data.seasonWeeks}
                        mode={data.mode}
                        minRuns={data.minRunsActive}
                    />
                    {!current ? <p className="boards-note">{t('admin.seasons.none_running')}</p> : null}
                </Card>
            ) : (
                <Card>
                    <EmptyState
                        icon="calendar"
                        title={t('admin.seasons.none_title')}
                        text={t('admin.seasons.none_text')}
                        action={
                            <Button variant="primary" icon="plus" onClick={() => setStartOpen(true)}>
                                {t('admin.seasons.start')}
                            </Button>
                        }
                    />
                </Card>
            )}

            <Grid cols="minmax(0, 3fr) minmax(0, 2fr)" gap={4} align="start" className="boards-admin-grid">
                <Card
                    title={t('admin.seasons.standings')}
                    subtitle={shown ? t('admin.seasons.standings_of', { name: shown.name }) : undefined}
                    icon="barChart"
                >
                    <DeptBars departments={asList(data.standings)} mode={data.mode} />
                </Card>
                {current && data.weeklyBounty ? (
                    <BountyCard
                        bounty={data.bounty}
                        footer={
                            <div className="boards-override">
                                <Select
                                    value={objective}
                                    onChange={setObjective}
                                    options={bounties.map(b => ({ value: b.id, label: b.label }))}
                                    aria-label={t('admin.seasons.override_label')}
                                    disabled={!data.bounty || data.bounty.closed}
                                />
                                <Button
                                    variant="secondary"
                                    icon="edit"
                                    disabled={
                                        !data.bounty ||
                                        data.bounty.closed ||
                                        !objective ||
                                        objective === data.bounty.id ||
                                        busy
                                    }
                                    onClick={() => setOverrideOpen(true)}
                                >
                                    {t('admin.seasons.override')}
                                </Button>
                            </div>
                        }
                    />
                ) : (
                    <Card title={t('challenge.bounty_title')} icon="target">
                        <EmptyState
                            compact
                            icon="target"
                            title={
                                !data.weeklyBounty ? t('admin.seasons.bounty_off') : t('admin.seasons.bounty_no_season')
                            }
                        />
                    </Card>
                )}
            </Grid>

            <Card
                title={t('admin.seasons.history')}
                subtitle={t('admin.seasons.history_hint')}
                icon="list"
                padding="none"
            >
                <Table
                    columns={historyColumns}
                    rows={asList(data.bountyHistory)}
                    rowKey={r => `${r.seasonId}-${r.week}`}
                    dense
                    maxHeight={320}
                    className="boards-flat-table boards-fixed"
                    empty={t('admin.seasons.history_empty')}
                />
            </Card>

            <Card title={t('admin.seasons.seasons')} icon="trophy" padding="none">
                <Table
                    columns={seasonColumns}
                    rows={asList(data.seasons)}
                    rowKey={r => r.id}
                    dense
                    className="boards-flat-table boards-fixed"
                    empty={t('admin.seasons.seasons_empty')}
                />
            </Card>

            <Dialog
                open={startOpen}
                onClose={() => (busy ? undefined : setStartOpen(false))}
                title={t('admin.seasons.start_title')}
                description={
                    current
                        ? t('admin.seasons.start_ends_current', { name: current.name })
                        : t('admin.seasons.start_desc')
                }
                size="sm"
                footer={
                    <>
                        <Button variant="ghost" onClick={() => setStartOpen(false)} disabled={busy}>
                            {t('common.cancel')}
                        </Button>
                        <Button
                            variant={current ? 'danger' : 'primary'}
                            icon="plus"
                            loading={busy}
                            disabled={!name.trim()}
                            onClick={() => void startSeason()}
                        >
                            {current ? t('admin.seasons.end_and_start') : t('admin.seasons.start')}
                        </Button>
                    </>
                }
            >
                <Field label={t('admin.seasons.name')} hint={t('admin.seasons.name_hint')} required>
                    <TextInput
                        value={name}
                        onChange={setName}
                        maxLength={64}
                        placeholder={t('admin.seasons.name_placeholder')}
                        onEnter={() => void startSeason()}
                        autoFocus
                    />
                </Field>
            </Dialog>

            <ConfirmDialog
                open={endOpen}
                tone="danger"
                title={t('admin.seasons.end_title', { name: current?.name ?? '' })}
                message={t('admin.seasons.end_message')}
                confirmLabel={t('admin.seasons.end')}
                onConfirm={endSeason}
                onCancel={() => setEndOpen(false)}
                busy={busy}
            />

            <ConfirmDialog
                open={overrideOpen}
                title={t('admin.seasons.override_title')}
                message={t('admin.seasons.override_message', {
                    from: data.bounty?.label ?? '',
                    to: bounties.find(b => b.id === objective)?.label ?? objective,
                })}
                confirmLabel={t('admin.seasons.override')}
                onConfirm={overrideBounty}
                onCancel={() => setOverrideOpen(false)}
                busy={busy}
            />
        </Screen>
    );
}
