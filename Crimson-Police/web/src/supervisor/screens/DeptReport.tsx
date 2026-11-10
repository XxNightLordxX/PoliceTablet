// Supervisor UI · Department → Officers (title key 'ui.screen.sup_report', callbacks sup:getDeptReport and

// sup:getOfficerActivity). The department's challenge standing, this week's bounty, and every officer
// of the department who played this week (runs, completed, points, cash, last run); tapping an officer
// opens his side panel (UI4): his runs of this week, his commendations and every action the viewer may take on him
// (Give points, Mission ban, Clear cooldown, Commend, Field training), each with its form in the panel. Supervisors
// only see their own department (the server enforces it).

import { useEffect, useState } from 'react';
import {
    Badge,
    Button,
    Card,
    Dialog,
    EmptyState,
    ErrorState,
    Grid,
    Icon,
    IconButton,
    LoadingBlock,
    Money,
    Row,
    Screen,
    SearchInput,
    Stat,
    Table,
    Textarea,
    Field,
    type IconName,
    type TableColumn,
} from '../../shared/components';
import { cx } from '../../shared/cx';
import { formatDateTime, formatDuration, formatMoney, formatNumber } from '../../shared/format';
import { useAction, useRequest } from '../../shared/hooks';
import { applyReplyView } from '../../shared/replyView';
import { t } from '../../shared/i18n';
import { useCan, useSession } from '../../shared/session';
import {
    asList,
    type ActivityRun,
    type DeptReport as DeptReportData,
    type OfficerActivity,
    type ReportOfficer,
} from '../../types/boards';
import { BountyCard } from '../../officer/screens/Challenge';
import { formatDay } from '../../officer/screens/Leaderboard';
import { ResultCell, missionTypeLabel } from '../../officer/screens/Profile';
import { CommendationsCard } from '../../officer/components/CommendationsCard';
import type { Commendation } from '../../types/profile';
import type { FtoDept } from '../../types/fieldTraining';
import { AwardPointsForm, ClearCooldownForm, FieldTrainingForm, MissionBanForm } from '../components/OfficerActions';
import { CommendForm } from '../components/CommendDialog';
import { ftoRoleOf, officerActions, type OfficerAction } from '../components/officerPanel';
import './DeptReport.css';

// Best dispositions as a share of all of them ("–" without decisions).
function judgementText(o: ReportOfficer): string {
    const total = (o.decisionsOk ?? 0) + (o.decisionsBad ?? 0);
    if (total <= 0) return '–';
    return `${Math.round(((o.decisionsBest ?? 0) * 1000) / total) / 10}%`;
}

const ACTION_ICON: Record<OfficerAction, IconName> = {
    points: 'medal',
    ban: 'lock',
    cooldown: 'clock',
    commend: 'medal',
    fto: 'idCard',
};

// The officer's side panel (UI4): his week (runs, commendations, a ban in force) and every action the viewer may take
// on him, each opening its form right here under the action buttons (one at a time).
function OfficerPanel({ officer, onClose }: { officer: ReportOfficer | null; onClose: () => void }) {
    const session = useSession();
    const can = useCan();
    const [action, setAction] = useState<OfficerAction | null>(null);
    const [revoking, setRevoking] = useState<Commendation | null>(null);
    const [revokeReason, setRevokeReason] = useState('');
    const { run: act, busy } = useAction();
    const { data, loading, error, refetch, setData } = useRequest<OfficerActivity>(
        'sup:getOfficerActivity',
        { citizenid: officer?.citizenid },
        { skip: !officer },
    );
    const fto = useRequest<FtoDept | false>('sup:getFieldTraining', {}, { skip: !officer });
    useEffect(() => setAction(null), [officer?.citizenid]);
    const current = data && data.officer?.citizenid === officer?.citizenid ? data : null;
    const runs = asList(current?.runs);
    const commendations = asList(current?.commendations);
    const ftoDept = fto.data ? fto.data : null;
    const ftoRole = ftoRoleOf(ftoDept, officer?.citizenid);
    const actions = officerActions({
        activity: current,
        canCommend: can('issueCommendation'),
        self: officer?.citizenid === session.officer?.citizenid,
        fto: ftoRole,
    });
    const shown = action && actions.includes(action) ? action : null;
    // an action's reply carries the officer's fresh activity (an older server: ask for it)
    const applyReply = (reply: unknown) =>
        applyReplyView<OfficerActivity>(reply, 'activity', setData, () => void refetch());
    const done = (reply: unknown) => {
        setAction(null);
        applyReply(reply);
    };

    // Revoke: only the issuer's own commendations (the server checks it too), with a reason.
    async function revoke() {
        if (!revoking || revokeReason.trim() === '') return;
        const res = await act(
            'server:sup:revokeCommendation',
            { id: revoking.id, reason: revokeReason.trim(), activityOf: officer?.citizenid },
            { success: 'profile.commend.revoked_toast' },
        );
        if (!res.ok) return;
        setRevoking(null);
        setRevokeReason('');
        applyReply(res.data);
    }
    const columns: TableColumn<ActivityRun>[] = [
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
                    <span className="boards-mission__type">
                        {[
                            missionTypeLabel(r.missionType, session),
                            r.participants > 1 ? t('result.participants', { n: r.participants }) : t('result.solo'),
                            formatDuration(r.durationS),
                        ].join(' · ')}
                    </span>
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
            render: r => (
                <span className={cx((r.voided || r.flagged) && 'boards-struck')}>{formatNumber(r.points)}</span>
            ),
        },
        {
            key: 'cash',
            header: t('profile.col.cash'),
            numeric: true,
            width: 92,
            render: r => <Money amount={r.cash} />,
        },
    ];
    const who = officer ? { citizenid: officer.citizenid, name: officer.name } : null;
    const actionLabel = (k: OfficerAction) =>
        k === 'points'
            ? t('sup.award.button')
            : k === 'ban'
              ? t(current?.missionBanState ? 'sup.ban.lift' : 'sup.ban.button')
              : k === 'cooldown'
                ? t('sup.cd.button')
                : k === 'commend'
                  ? t('profile.commend.give')
                  : t('fto.title');

    let form = null;
    if (who && shown === 'points' && current?.awardPoints) {
        form = (
            <AwardPointsForm
                officer={who}
                control={current.awardPoints}
                onCancel={() => setAction(null)}
                onDone={done}
            />
        );
    } else if (who && shown === 'ban' && current?.missionBan) {
        form = (
            <MissionBanForm
                officer={who}
                control={current.missionBan}
                state={current.missionBanState ?? null}
                onCancel={() => setAction(null)}
                onDone={done}
            />
        );
    } else if (who && shown === 'cooldown') {
        form = <ClearCooldownForm officer={who} onCancel={() => setAction(null)} />;
    } else if (who && shown === 'commend') {
        form = (
            <CommendForm
                officer={who}
                scope="sup"
                activity
                onCancel={() => setAction(null)}
                onDone={applyReply}
                runs={runs
                    .filter(r => !!r.runUuid && r.state === 'completed')
                    .map(r => ({
                        runUuid: r.runUuid as string,
                        label: `${r.missionLabel} · ${formatDateTime(r.createdAt)}`,
                    }))}
            />
        );
    } else if (who && shown === 'fto' && ftoDept && ftoRole) {
        form = (
            <FieldTrainingForm
                officer={who}
                fto={ftoDept}
                role={ftoRole}
                onCancel={() => setAction(null)}
                onDone={() => void fto.refetch()}
            />
        );
    }

    return (
        <Dialog
            open={!!officer}
            onClose={onClose}
            size="lg"
            placement="right"
            className="sup-panel"
            title={officer ? t('sup.report.activity_title', { name: officer.name }) : ''}
            description={
                officer
                    ? [
                          officer.rank,
                          officer.callsign || t('common.no_callsign'),
                          t('sup.report.activity_week', { from: formatDay(current?.week?.key) }),
                      ]
                          .filter(Boolean)
                          .join(' · ')
                    : undefined
            }
            footer={
                <Button variant="primary" onClick={onClose}>
                    {t('common.close')}
                </Button>
            }
        >
            {current?.missionBanState ? (
                <p className="sup-cd-note is-warning">
                    {t('sup.ban.state', {
                        time: formatDateTime(current.missionBanState.until),
                        by: current.missionBanState.by,
                    })}
                    {current.missionBanState.reason ? ` · ${current.missionBanState.reason}` : ''}
                </p>
            ) : null}
            <Card title={t('sup.panel.actions')} icon="tool" padding="sm" className="sup-panel__card">
                {actions.length === 0 ? (
                    <p className="sup-cd-note">{t(current ? 'sup.panel.no_actions' : 'common.loading')}</p>
                ) : (
                    <div className="sup-panel__actions" role="group" aria-label={t('sup.panel.actions')}>
                        {actions.map(k => (
                            <Button
                                key={k}
                                size="sm"
                                variant={shown === k ? 'primary' : 'secondary'}
                                icon={ACTION_ICON[k]}
                                aria-pressed={shown === k}
                                onClick={() => setAction(shown === k ? null : k)}
                            >
                                {actionLabel(k)}
                            </Button>
                        ))}
                    </div>
                )}
                {form ? <div className="sup-panel__form">{form}</div> : null}
            </Card>
            <Dialog
                open={!!revoking}
                onClose={() => setRevoking(null)}
                size="sm"
                title={t('profile.commend.revoke_title')}
                description={t('profile.commend.revoke_text')}
                footer={
                    <>
                        <Button variant="ghost" onClick={() => setRevoking(null)}>
                            {t('common.cancel')}
                        </Button>
                        <Button
                            variant="danger"
                            icon="xCircle"
                            loading={busy}
                            disabled={revokeReason.trim() === ''}
                            onClick={() => void revoke()}
                        >
                            {t('profile.commend.revoke')}
                        </Button>
                    </>
                }
            >
                <Field label={t('profile.commend.revoke_reason')}>
                    <Textarea value={revokeReason} onChange={setRevokeReason} maxLength={255} rows={2} />
                </Field>
            </Dialog>
            {commendations.length ? (
                <CommendationsCard
                    commendations={commendations}
                    onRevoke={c => {
                        if (!c.mine) return;
                        setRevokeReason('');
                        setRevoking(c);
                    }}
                    canRevoke={c => c.mine === true}
                />
            ) : null}
            <h4 className="cp-section-title">{t('sup.panel.runs')}</h4>
            {error && !current ? (
                <ErrorState compact error={error} onRetry={() => void refetch()} />
            ) : (
                <Table
                    className="boards-fixed"
                    columns={columns}
                    rows={runs}
                    rowKey={r => r.id}
                    dense
                    loading={loading}
                    maxHeight={400}
                    empty={t('sup.report.activity_empty')}
                />
            )}
        </Dialog>
    );
}

// The Department screen's Officers tab (shown with viewMissionList; field training is its own tab).
export default function DeptReport() {
    return <FullDeptReport />;
}

function FullDeptReport() {
    const session = useSession();
    const { data, loading, error, refetch } = useRequest<DeptReportData>('sup:getDeptReport', {}, { pollMs: 60000 });
    const [open, setOpen] = useState<ReportOfficer | null>(null);
    const [search, setSearch] = useState('');

    const officers = asList(data?.officers);
    const q = search.trim().toLowerCase();
    const shown = q
        ? officers.filter(o => [o.name, o.callsign ?? '', o.citizenid, o.rank].some(v => v.toLowerCase().includes(q)))
        : officers;
    const dept = data?.department ?? null;
    const standing = data?.standing ?? null;
    const totals = officers.reduce(
        (s, o) => ({
            runs: s.runs + o.runs,
            completed: s.completed + o.completed,
            points: s.points + o.points,
            cash: s.cash + o.cash,
        }),
        { runs: 0, completed: 0, points: 0, cash: 0 },
    );

    const columns: TableColumn<ReportOfficer>[] = [
        {
            key: 'officer',
            header: t('leaderboard.col.officer'),
            render: o => (
                <span className="boards-report-cell">
                    <span className="boards-report-cell__name">
                        <span className="boards-strong boards-ellipsis" title={o.name}>
                            {o.name}
                        </span>
                        {o.missionBan ? (
                            <Badge
                                tone="danger"
                                size="sm"
                                icon="lock"
                                title={t('sup.ban.state', {
                                    time: formatDateTime(o.missionBan.until),
                                    by: o.missionBan.by,
                                })}
                            >
                                {t('sup.ban.badge')}
                            </Badge>
                        ) : null}
                        {o.flagged ? (
                            <Badge tone="warning" size="sm" icon="alert" title={t('sup.report.col.flagged')}>
                                {formatNumber(o.flagged)}
                            </Badge>
                        ) : null}
                    </span>
                    <span className="boards-report-cell__sub">
                        {[o.rank, o.callsign || t('common.no_callsign')].filter(Boolean).join(' · ')}
                    </span>
                </span>
            ),
        },
        { key: 'runs', header: t('sup.report.col.runs'), numeric: true, width: 68, render: o => formatNumber(o.runs) },
        {
            key: 'completed',
            header: t('sup.report.col.completed'),
            numeric: true,
            width: 112,
            render: o => formatNumber(o.completed),
        },
        {
            key: 'failed',
            header: t('sup.report.col.failed_abandoned'),
            numeric: true,
            width: 124,
            render: o => (
                <span className="boards-muted">{`${formatNumber(o.failed)} / ${formatNumber(o.abandoned)}`}</span>
            ),
        },
        {
            key: 'arrests',
            header: t('sup.report.col.arrests'),
            numeric: true,
            width: 70,
            render: o => formatNumber(o.arrests ?? 0),
        },
        {
            key: 'citations',
            header: t('sup.report.col.citations'),
            numeric: true,
            width: 70,
            render: o => formatNumber(o.citations ?? 0),
        },
        {
            key: 'impounds',
            header: t('sup.report.col.impounds'),
            numeric: true,
            width: 74,
            render: o => formatNumber(o.impounds ?? 0),
        },
        {
            key: 'judgement',
            header: t('sup.report.col.judgement'),
            numeric: true,
            width: 84,
            render: o => (
                <span title={t('sup.report.judgement_hint', { best: o.decisionsBest ?? 0, ok: o.decisionsOk ?? 0 })}>
                    {judgementText(o)}
                </span>
            ),
        },
        {
            key: 'calls',
            header: t('sup.report.col.calls'),
            numeric: true,
            width: 64,
            render: o => formatNumber(o.calls ?? 0),
        },
        {
            key: 'points',
            header: t('sup.report.col.points'),
            numeric: true,
            width: 84,
            render: o => <span className="boards-strong">{formatNumber(o.points)}</span>,
        },
        {
            key: 'cash',
            header: t('sup.report.col.cash'),
            numeric: true,
            width: 100,
            render: o => <Money amount={o.cash} />,
        },
        {
            key: 'last',
            header: t('sup.report.col.last'),
            width: 120,
            render: o => <span className="boards-when cp-num">{o.lastRunAt ? formatDateTime(o.lastRunAt) : '–'}</span>,
        },
        {
            key: 'open',
            header: '',
            width: 44,
            align: 'right',
            render: () => <Icon name="chevronRight" size={16} className="boards-row-chevron" />,
        },
    ];

    if (!data && loading) {
        return (
            <Screen head="sup_report">
                <LoadingBlock />
            </Screen>
        );
    }
    if (!data) {
        return (
            <Screen head="sup_report">
                <ErrorState error={error ?? 'err.internal'} onRetry={() => void refetch()} />
            </Screen>
        );
    }

    return (
        <Screen
            head="sup_report"
            subtitle={t('sup.report.subtitle', {
                dept: dept?.label ?? session.officer?.departmentLabel ?? '',
                from: formatDay(data.week?.key),
            })}
            actions={
                <IconButton
                    icon="refresh"
                    label={t('leaderboard.refresh')}
                    loading={loading}
                    onClick={() => void refetch()}
                />
            }
            className="boards-report"
        >
            <Grid cols="minmax(0, 1fr) minmax(0, 1fr)" gap={4} align="stretch">
                <Card
                    title={t('sup.report.standing')}
                    subtitle={
                        data.season
                            ? t('sup.report.season_line', {
                                  name: data.season.name,
                                  week: data.season.week,
                                  n: data.season.weeksLeft,
                              })
                            : undefined
                    }
                    icon="trophy"
                    className="boards-standing"
                >
                    {!data.season || !standing ? (
                        <EmptyState
                            compact
                            icon="calendar"
                            title={
                                data.enabled === false ? t('challenge.disabled_title') : t('challenge.no_season_title')
                            }
                        />
                    ) : (
                        <div className="boards-standing__body">
                            <div className="boards-standing__rank" style={{ borderColor: dept?.colour }}>
                                <span className="boards-standing__place cp-num">#{standing.rank ?? '–'}</span>
                                <span className="boards-standing__of">
                                    {t('sup.report.of', { n: standing.of ?? asList(data.standings).length })}
                                </span>
                            </div>
                            <div className="boards-standing__stats">
                                <Stat
                                    size="sm"
                                    label={t('sup.report.score')}
                                    value={formatNumber(standing.score)}
                                    tone="accent"
                                />
                                <Stat
                                    size="sm"
                                    label={t('sup.report.active')}
                                    value={formatNumber(standing.activeOfficers)}
                                />
                                <Stat
                                    size="sm"
                                    label={t('sup.report.season_points')}
                                    value={formatNumber(standing.points ?? 0)}
                                />
                                <Stat
                                    size="sm"
                                    label={t('sup.report.bonus')}
                                    value={standing.bonus ? `+${formatNumber(standing.bonus)}` : '0'}
                                    tone={standing.bonus ? 'success' : 'neutral'}
                                />
                            </div>
                        </div>
                    )}
                    {asList(data.standings).length > 1 && data.season ? (
                        <ol className="boards-mini-standings" aria-label={t('sup.report.all_departments')}>
                            {asList(data.standings).map((d, i) => (
                                <li
                                    key={d.key}
                                    className={cx('boards-mini-standing', d.key === dept?.key && 'is-mine')}
                                >
                                    <span className="boards-mini-standing__rank cp-num">{d.rank ?? i + 1}</span>
                                    <span
                                        className="boards-mini-standing__strip"
                                        style={{ backgroundColor: d.colour }}
                                        aria-hidden
                                    />
                                    <span className="boards-mini-standing__name">{d.short}</span>
                                    <span className="boards-mini-standing__meta">
                                        {t('challenge.active_officers', { n: d.activeOfficers })}
                                    </span>
                                    <span className="boards-mini-standing__score cp-num">{formatNumber(d.score)}</span>
                                </li>
                            ))}
                        </ol>
                    ) : null}
                </Card>
                <BountyCard bounty={data.bounty} myDepartment={dept?.key} />
            </Grid>

            <div className="boards-report-stats">
                <Stat
                    size="sm"
                    label={t('sup.report.stat.officers')}
                    value={formatNumber(officers.length)}
                    icon="users"
                />
                <Stat
                    size="sm"
                    label={t('sup.report.stat.runs')}
                    value={formatNumber(totals.runs)}
                    hint={t('sup.report.stat.completed', { n: formatNumber(totals.completed) })}
                    icon="activity"
                />
                <Stat size="sm" label={t('sup.report.stat.points')} value={formatNumber(totals.points)} icon="star" />
                <Stat
                    size="sm"
                    label={t('sup.report.stat.cash')}
                    value={formatMoney(totals.cash)}
                    icon="dollar"
                    tone="success"
                />
            </div>

            <Card
                title={t('sup.report.activity')}
                subtitle={t('sup.report.activity_hint')}
                icon="activity"
                padding="none"
                actions={
                    <SearchInput
                        value={search}
                        onChange={setSearch}
                        placeholder={t('sup.report.search')}
                        className="boards-report-search"
                    />
                }
            >
                <Table
                    columns={columns}
                    rows={shown}
                    rowKey={o => o.citizenid}
                    onRowClick={o => setOpen(o)}
                    dense
                    maxHeight={360}
                    className="boards-flat-table boards-fixed"
                    empty={
                        <EmptyState
                            compact
                            icon="inbox"
                            title={q ? t('sup.report.no_match') : t('sup.report.no_activity')}
                            text={q ? undefined : t('sup.report.no_activity_text')}
                        />
                    }
                />
            </Card>
            <Row gap={2} className="boards-report-note">
                <Icon name="info" size={13} />
                <span>{t('sup.report.note')}</span>
            </Row>

            <OfficerPanel officer={open} onClose={() => setOpen(null)} />
        </Screen>
    );
}
