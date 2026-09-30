// Officer UI · Profile & History (screen key 'profile', callback getProfile, actions server:setHideName and

import { useState } from 'react';
import { DecisionsBlock, PeopleBlock } from '../../hud/Debrief';
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
    LoadingBlock,
    Money,
    ProgressBar,
    Row,
    Screen,
    Select,
    Stat,
    Table,
    Textarea,
    TierBadge,
    Toggle,
    XpBadge,
    type IconName,
    type TableColumn,
} from '../../shared/components';
import { cx } from '../../shared/cx';
import { normalizeResult, pointsLimits } from '../../shared/data';
import {
    formatDateTime,
    formatDuration,
    formatFactor,
    formatMoney,
    formatMultiplier,
    formatNumber,
    formatPercent,
} from '../../shared/format';
import { useAction, useRequest } from '../../shared/hooks';
import { t, tOr } from '../../shared/i18n';
import { useNavigate, useNavigation } from '../../shared/navigation';
import { useSession } from '../../shared/session';
import type { RunResult, Session } from '../../shared/types';
import { asList, type ProfileData, type ProfileRunView } from '../../types/boards';
import { CommendationsCard } from '../components/CommendationsCard';
import { LookCard } from '../components/LookCard';
import { ProfileEditDialog } from '../components/ProfileEditDialog';
import { ServiceRecordCard } from '../components/ServiceRecordCard';
import './Profile.css';

const REPORT_REASONS = ['picture', 'bio', 'other'];
const REPORT_NOTE_MAX = 140;

const STATE_TONE = { completed: 'success', failed: 'danger', abandoned: 'neutral' } as const;
const BADGE_ICON: Record<string, IconName> = {
    week: 'star',
    champion: 'trophy',
    top10: 'podium',
    achievement: 'shieldCheck',
};

export function missionTypeLabel(type: string, session: Session): string {
    if (type === 'manual_award' || type === 'goal') return t(`profile.type.${type}`);
    const mt = asList(session.config?.missionTypes).find(m => m.key === type);
    return mt ? mt.label : type;
}

export function StateBadge({ state }: { state: string }) {
    const tone = STATE_TONE[state as keyof typeof STATE_TONE] ?? 'neutral';
    return (
        <Badge tone={tone} size="sm">
            {tOr(`profile.state.${state}`, 'common.unknown')}
        </Badge>
    );
}

// "How it ended": state badge (+ voided/flagged badges) over the end reason. Shared by every run table.
export function ResultCell({
    state,
    endReason,
    flagged,
    voided,
    flagReason,
}: {
    state: string;
    endReason: string;
    flagged?: boolean;
    voided?: boolean;
    flagReason?: string | null;
}) {
    return (
        <span className="boards-resultcell">
            <span className="boards-resultcell__top">
                <StateBadge state={state} />
                {voided ? (
                    <Badge tone="danger" size="sm" icon="xCircle">
                        {t('profile.voided')}
                    </Badge>
                ) : null}
                {flagged ? (
                    <Badge
                        tone="warning"
                        size="sm"
                        icon="alert"
                        title={flagReason ? tOr(`profile.flag_reason.${flagReason}`, 'result.flag_generic') : undefined}
                    >
                        {t('profile.flagged')}
                    </Badge>
                ) : null}
            </span>
            <span className="boards-resultcell__reason">{tOr(`reason.${endReason}`, 'common.unknown')}</span>
        </span>
    );
}

function Line({
    label,
    value,
    tone,
    strong,
    note,
}: {
    label: string;
    value: string;
    tone?: 'plus' | 'minus' | 'mult';
    strong?: boolean;
    note?: boolean;
}) {
    return (
        <div className={cx('cp-result__line', tone && `is-${tone}`, strong && 'is-strong', note && 'is-note')}>
            <span className="cp-result__line-label">{label}</span>
            <span className="cp-result__line-value cp-num">{value}</span>
        </div>
    );
}

// The points and cash breakdown of one run, in the HUD result card's presentation (cp-result classes).
export function RunBreakdown({ result: raw, cashStatus }: { result: RunResult; cashStatus?: string }) {
    // Row JSON from Lua: lists may be {} and fields may be missing; public profiles have no cash block at all.
    const hasCash = !!(raw as Partial<RunResult>).cash && typeof raw.cash === 'object';
    const result = normalizeResult(raw);
    const p = raw.points && typeof raw.points === 'object' ? result.points : null;
    const limits = pointsLimits(result.points);
    const c = hasCash ? result.cash : null;
    const status = cashStatus || c?.status || '';
    const kind = result.result === 'completed' || result.result === 'failed' ? result.result : 'abandoned';
    return (
        <div className={cx('cp-result', `is-${kind}`, 'boards-breakdown')}>
            <div className="cp-result__mission">
                <span className="cp-result__mission-label">{result.missionLabel}</span>
                <span className="cp-result__facts">
                    <span>
                        {result.participants > 1
                            ? t('result.participants', { n: result.participants })
                            : t('result.solo')}
                    </span>
                    {result.departments > 1 ? <span>{t('result.departments', { n: result.departments })}</span> : null}
                    <span className="cp-num">{formatDuration(result.durationS)}</span>
                </span>
            </div>
            {result.flagged ? (
                <div className="cp-result__notice is-flagged">
                    <Icon name="alert" size={15} />
                    <span>
                        <strong>
                            {t('result.flagged', {
                                reason: tOr(`profile.flag_reason.${result.flagged.reason}`, 'result.flag_generic'),
                            })}
                        </strong>{' '}
                        {t('result.flagged_note')}
                    </span>
                </div>
            ) : null}
            <div className="cp-result__tiers">
                <span className="cp-result__tier-label">{t('result.tier')}</span>
                <TierBadge tier={result.payTier || result.tier} size="sm" />
            </div>
            {p ? (
                <div className="cp-result__block">
                    <div className="cp-result__block-head">
                        <Icon name="star" size={14} />
                        <span>{t('result.points')}</span>
                    </div>
                    <Line label={t('result.base')} value={formatNumber(p.P)} />
                    {asList(p.bonuses).map((b, i) => (
                        <Line
                            key={`b${i}`}
                            label={b.label || tOr(`bonus.${b.id}`, 'profile.bonus')}
                            value={formatNumber(b.points, true)}
                            tone="plus"
                        />
                    ))}
                    {asList(p.penalties).map((b, i) => (
                        <Line
                            key={`p${i}`}
                            label={b.label || tOr(`penalty.${b.id}`, 'profile.penalty')}
                            value={formatNumber(-Math.abs(b.points))}
                            tone="minus"
                        />
                    ))}
                    {p.failedShare !== null && p.failedShare !== undefined ? (
                        <Line label={t('result.failed_share', { share: formatPercent(p.failedShare) })} value="" note />
                    ) : null}
                    <Line label={t('result.subtotal')} value={formatNumber(p.subtotal)} strong />
                    <Line label={t('result.m_team')} value={formatMultiplier(p.mTeam)} tone="mult" />
                    <Line label={t('result.m_cross')} value={formatMultiplier(p.mCross)} tone="mult" />
                    <Line label={t('result.m_streak')} value={formatMultiplier(p.mStreak)} tone="mult" />
                    {p.capped ? (
                        <Line
                            label={t('result.capped', { cap: formatFactor(limits.scoreCap) })}
                            value={formatNumber(limits.cap)}
                            note
                        />
                    ) : null}
                    {p.tod ? (
                        <Line label={t('result.tod')} value={`×${formatFactor(limits.todMultiplier)}`} tone="mult" />
                    ) : null}
                    <div className="cp-result__final">
                        <span>{t('result.final')}</span>
                        <span className="cp-num">
                            {formatNumber(p.final)} <small>{t('common.pts')}</small>
                        </span>
                    </div>
                </div>
            ) : null}
            {c ? (
                <div className="cp-result__block">
                    <div className="cp-result__block-head">
                        <Icon name="dollar" size={14} />
                        <span>{t('result.cash')}</span>
                        {status ? (
                            <span className={cx('cp-result__status', `is-${status}`)}>
                                {tOr(`result.cash_status.${status}`, 'common.unknown')}
                            </span>
                        ) : null}
                    </div>
                    <div className="cp-result__cash">
                        <span className="cp-result__formula cp-num">
                            {result.result === 'completed'
                                ? `${formatMoney(c.B)} ${formatMultiplier(c.mTier)} ${formatMultiplier(c.mMod)} =`
                                : t('result.no_cash')}
                        </span>
                        <span className="cp-result__amount cp-num">{formatMoney(c.amount)}</span>
                    </div>
                </div>
            ) : null}
            {raw.decisions ? <DecisionsBlock decisions={raw.decisions} /> : null}
            {raw.people ? <PeopleBlock people={raw.people} /> : null}
        </div>
    );
}

export default function Profile() {
    const session = useSession();
    const navigate = useNavigate();
    const { params } = useNavigation();
    const target =
        typeof params.citizenid === 'string' && params.citizenid !== session.officer?.citizenid
            ? params.citizenid
            : undefined;
    const { data, loading, error, refetch, setData } = useRequest<ProfileData>(
        'getProfile',
        target ? { citizenid: target } : {},
    );
    const { run, busy } = useAction();
    const [openRun, setOpenRun] = useState<ProfileRunView | null>(null);
    const [disputeRun, setDisputeRun] = useState<ProfileRunView | null>(null);
    const [editing, setEditing] = useState(false);
    const [lookVersion, setLookVersion] = useState(0);
    const [reporting, setReporting] = useState(false);
    const [reportReason, setReportReason] = useState('picture');
    const [reportNote, setReportNote] = useState('');

    // Do not show the previous profile while another one loads.
    const profile = data && (target ? data.citizenid === target : data.own) ? data : null;
    const own = !!profile?.own;
    const runs = asList(profile?.runs) as ProfileRunView[];
    const badges = asList(profile?.badges);
    const hours = profile?.disputeWindowHours ?? session.config?.disputeWindowHours ?? 48;

    const toggleHide = async (value: boolean) => {
        const res = await run<{ hideName: boolean }>('server:setHideName', value, {
            success: value ? 'profile.hide_on' : 'profile.hide_off',
        });
        if (res.ok) setData(prev => (prev ? { ...prev, hideName: res.data?.hideName ?? value } : prev));
    };

    const sendReport = async () => {
        if (!profile) return;
        const res = await run(
            'server:profile:report',
            { citizenid: profile.citizenid, reason: reportReason, note: reportNote.trim() || undefined },
            { success: 'profile.report.sent' },
        );
        if (res.ok) {
            setReporting(false);
            setReportNote('');
        }
    };

    const sendDispute = async (reason: string) => {
        if (!disputeRun) return;
        const res = await run('server:dispute', { rowId: disputeRun.id, reason }, { success: 'profile.dispute_sent' });
        if (res.ok) {
            setDisputeRun(null);
            void refetch();
        }
    };

    const columns: TableColumn<ProfileRunView>[] = [
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
                    <span className="boards-mission__type">{missionTypeLabel(r.missionType, session)}</span>
                </span>
            ),
        },
        {
            key: 'state',
            header: t('profile.col.result'),
            width: 180,
            render: r => <ResultCell state={r.state} endReason={r.endReason} flagged={r.flagged} voided={r.voided} />,
        },
        {
            key: 'points',
            header: t('profile.col.points'),
            numeric: true,
            width: 84,
            render: r => (
                <span className={cx('boards-points', (r.voided || r.flagged) && 'is-struck')}>
                    {formatNumber(r.points)}
                </span>
            ),
        },
    ];
    if (own) {
        columns.push({
            key: 'cash',
            header: t('profile.col.cash'),
            numeric: true,
            width: 96,
            render: r => (
                <span className="boards-cash">
                    <Money amount={r.cash} />
                    {r.cashStatus && r.cashStatus !== 'none' ? (
                        <small className={cx('boards-cash__status', `is-${r.cashStatus}`)}>
                            {tOr(`result.cash_status.${r.cashStatus}`, 'common.unknown')}
                        </small>
                    ) : null}
                </span>
            ),
        });
        columns.push({
            key: 'actions',
            header: '',
            width: 124,
            align: 'right',
            render: r =>
                r.canDispute ? (
                    <Button
                        size="sm"
                        variant="secondary"
                        icon="flag"
                        onClick={e => {
                            e.stopPropagation();
                            setDisputeRun(r);
                        }}
                    >
                        {t('profile.dispute')}
                    </Button>
                ) : (
                    <Icon name="chevronRight" size={16} className="boards-row-chevron" />
                ),
        });
    }

    if (!profile && loading) {
        return (
            <Screen title={t('ui.screen.profile')}>
                <LoadingBlock text={t('profile.loading')} />
            </Screen>
        );
    }
    if (!profile) {
        return (
            <Screen
                title={t('ui.screen.profile')}
                actions={
                    target ? (
                        <Button variant="ghost" icon="chevronLeft" onClick={() => navigate('leaderboard')}>
                            {t('profile.back')}
                        </Button>
                    ) : undefined
                }
            >
                <ErrorState error={error ?? 'err.internal'} onRetry={() => void refetch()} />
            </Screen>
        );
    }

    const level = profile.level ?? {
        n: 1,
        label: '',
        badge: 'grey',
        xp: 0,
        levelXp: 0,
        nextLevelXp: null,
        prestige: 0,
    };
    const levelStart = level.levelXp ?? 0;
    const levelNext = level.nextLevelXp ?? null;
    const hasNext = typeof levelNext === 'number' && levelNext > levelStart;
    const into = Math.max(0, profile.xp - levelStart);
    const span = hasNext ? (levelNext as number) - levelStart : 1;
    const levelText = level.label
        ? t('profile.level_named', { n: level.n, label: level.label })
        : t('profile.level', { n: level.n });

    return (
        <Screen
            title={own ? t('ui.screen.profile') : t('profile.public_title', { name: profile.name })}
            subtitle={own ? t('profile.subtitle_own') : t('profile.subtitle_public')}
            actions={
                !own ? (
                    <>
                        <Button variant="ghost" icon="flag" onClick={() => setReporting(true)}>
                            {t('profile.report.button')}
                        </Button>
                        <Button variant="ghost" icon="chevronLeft" onClick={() => navigate('leaderboard')}>
                            {t('profile.back')}
                        </Button>
                    </>
                ) : (
                    <Button variant="secondary" icon="edit" onClick={() => setEditing(true)}>
                        {t('profile.edit.button')}
                    </Button>
                )
            }
            className="boards-profile-screen"
        >
            <Grid cols="minmax(0, 3fr) minmax(0, 2fr)" gap={4} align="stretch">
                <Card padding="lg" className="boards-idcard">
                    <div className="boards-id">
                        <Avatar
                            avatar={profile.avatar}
                            name={profile.name}
                            size={64}
                            className="boards-profile-avatar"
                        />
                        <span className="boards-id__text">
                            <span className="boards-id__name">{profile.name}</span>
                            <span className="boards-id__line">
                                {[
                                    profile.rank,
                                    profile.departmentShort,
                                    // the callsign is read live from Qbox; the own profile says how to set it
                                    profile.callsign || t(own ? 'profile.callsign_missing' : 'common.no_callsign'),
                                ]
                                    .filter(Boolean)
                                    .join(' · ')}
                            </span>
                            <Row gap={2} wrap>
                                <XpBadge badge={level.badge} label={levelText} />
                                {own && profile.hideName ? (
                                    <Badge tone="neutral" icon="eye">
                                        {t('profile.name_hidden')}
                                    </Badge>
                                ) : null}
                            </Row>
                        </span>
                    </div>
                    {profile.bio ? <p className="boards-bio">{profile.bio}</p> : null}
                    <ProgressBar
                        className="boards-xpbar"
                        tone="accent"
                        value={hasNext ? into : 1}
                        max={span}
                        label={
                            hasNext
                                ? t('profile.xp_to_next', { next: formatNumber(levelNext as number) })
                                : t('profile.xp_max')
                        }
                        showValue={
                            <span>
                                {formatNumber(profile.xp)} {t('leaderboard.xp')}
                            </span>
                        }
                    />
                    {own ? (
                        <div className="boards-hide">
                            <Toggle
                                checked={!!profile.hideName}
                                onChange={v => void toggleHide(v)}
                                disabled={busy}
                                label={t('profile.hide_name')}
                                description={t('profile.hide_name_hint')}
                            />
                        </div>
                    ) : null}
                </Card>
                <Card padding="md" className="boards-statcard">
                    <div className="boards-stats">
                        <Stat label={t('profile.stat.xp')} value={formatNumber(profile.xp)} icon="star" tone="accent" />
                        <Stat
                            label={t('profile.stat.season')}
                            value={formatNumber(profile.seasonPoints ?? 0)}
                            icon="trophy"
                        />
                        <Stat label={t('profile.stat.badges')} value={formatNumber(badges.length)} icon="medal" />
                        <Stat
                            label={t('profile.stat.completed')}
                            value={formatNumber(
                                runs.filter(
                                    r =>
                                        r.state === 'completed' &&
                                        r.missionType !== 'manual_award' &&
                                        r.missionType !== 'goal',
                                ).length,
                            )}
                            hint={t('profile.stat.completed_hint', { n: runs.length })}
                            icon="checkCircle"
                        />
                    </div>
                </Card>
            </Grid>

            <Card title={t('profile.badges')} icon="medal" padding="sm">
                {badges.length ? (
                    <div className="boards-badges">
                        {badges.map(b => (
                            <div
                                key={b.id}
                                className={cx('boards-badge', `is-${b.kind ?? 'achievement'}`)}
                                title={
                                    b.earnedAt ? t('profile.earned', { when: formatDateTime(b.earnedAt) }) : undefined
                                }
                            >
                                <span className="boards-badge__icon">
                                    <Icon name={BADGE_ICON[b.kind ?? 'achievement'] ?? 'shieldCheck'} size={16} />
                                </span>
                                <span className="boards-badge__text">
                                    <span className="boards-badge__label">{b.label}</span>
                                    {b.earnedAt ? (
                                        <span className="boards-badge__when">{formatDateTime(b.earnedAt)}</span>
                                    ) : null}
                                </span>
                            </div>
                        ))}
                    </div>
                ) : (
                    <EmptyState
                        compact
                        icon="medal"
                        title={t('profile.no_badges')}
                        text={own ? t('profile.no_badges_text') : undefined}
                    />
                )}
            </Card>

            <Grid cols="minmax(0, 3fr) minmax(0, 2fr)" gap={4} align="start">
                <ServiceRecordCard
                    lifetime={profile.service?.lifetime}
                    season={profile.service?.season}
                    bests={profile.bests}
                    partner={profile.favouritePartner}
                    cleanArrestRate={own ? profile.cleanArrestRate : null}
                />
                <div className="boards-profile-side">
                    <CommendationsCard commendations={profile.commendations} mdt={profile.mdtCommendations} />
                    {own ? <LookCard version={lookVersion} onEdit={() => setEditing(true)} /> : null}
                </div>
            </Grid>

            <Card
                title={t('profile.history')}
                subtitle={own ? t('profile.history_hint', { hours }) : t('profile.history_public')}
                icon="list"
                padding="none"
            >
                <Table
                    columns={columns}
                    rows={runs}
                    rowKey={r => r.id}
                    onRowClick={r => setOpenRun(r)}
                    dense
                    stickyHeader
                    empty={
                        <EmptyState
                            compact
                            icon="inbox"
                            title={t('profile.no_runs')}
                            text={own ? t('profile.no_runs_text') : undefined}
                        />
                    }
                    className="boards-history boards-fixed"
                    aria-label={t('profile.history')}
                />
            </Card>

            <Dialog
                open={!!openRun}
                onClose={() => setOpenRun(null)}
                title={openRun ? openRun.missionLabel : ''}
                description={
                    openRun
                        ? `${formatDateTime(openRun.createdAt)} · ${tOr(`reason.${openRun.endReason}`, 'common.unknown')}`
                        : undefined
                }
                size="sm"
                footer={
                    <>
                        {openRun && own && openRun.canDispute ? (
                            <Button
                                variant="secondary"
                                icon="flag"
                                onClick={() => {
                                    setDisputeRun(openRun);
                                    setOpenRun(null);
                                }}
                            >
                                {t('profile.dispute')}
                            </Button>
                        ) : null}
                        <Button variant="primary" onClick={() => setOpenRun(null)}>
                            {t('common.close')}
                        </Button>
                    </>
                }
            >
                {openRun ? (
                    <div className="boards-breakdown-wrap">
                        <Row gap={2} wrap>
                            <StateBadge state={openRun.state} />
                            {openRun.voided ? (
                                <Badge tone="danger" size="sm" icon="xCircle">
                                    {t('profile.voided')}
                                </Badge>
                            ) : null}
                            {openRun.flagged ? (
                                <Badge tone="warning" size="sm" icon="alert">
                                    {t('profile.flagged')}
                                </Badge>
                            ) : null}
                            {openRun.voided ? <span className="boards-muted">{t('profile.voided_note')}</span> : null}
                        </Row>
                        {openRun.breakdown ? (
                            <RunBreakdown
                                result={openRun.breakdown}
                                cashStatus={own ? openRun.cashStatus : undefined}
                            />
                        ) : (
                            <div className="boards-award">
                                <span className="boards-award__points cp-num">
                                    {formatNumber(openRun.points, true)} <small>{t('common.pts')}</small>
                                </span>
                                <span className="boards-muted">
                                    {t(
                                        `profile.no_breakdown.${openRun.missionType === 'manual_award' || openRun.missionType === 'goal' ? openRun.missionType : 'run'}`,
                                    )}
                                </span>
                            </div>
                        )}
                    </div>
                ) : null}
            </Dialog>

            {own ? (
                <ProfileEditDialog
                    open={editing}
                    onClose={() => setEditing(false)}
                    onSaved={() => {
                        void refetch();
                        setLookVersion(v => v + 1);
                    }}
                />
            ) : null}

            <Dialog
                open={reporting}
                onClose={() => setReporting(false)}
                title={t('profile.report.title', { name: profile.name })}
                description={t('profile.report.text')}
                size="sm"
                footer={
                    <>
                        <Button variant="ghost" onClick={() => setReporting(false)}>
                            {t('common.cancel')}
                        </Button>
                        <Button variant="danger" icon="flag" loading={busy} onClick={() => void sendReport()}>
                            {t('profile.report.send')}
                        </Button>
                    </>
                }
            >
                <Field label={t('profile.report.reason')}>
                    <Select
                        value={reportReason}
                        onChange={setReportReason}
                        options={REPORT_REASONS.map(r => ({ value: r, label: t(`profile.report.reason.${r}`) }))}
                    />
                </Field>
                <Field label={t('profile.report.note')} hint={t('profile.report.note_hint')}>
                    <Textarea value={reportNote} onChange={setReportNote} maxLength={REPORT_NOTE_MAX} rows={2} />
                </Field>
            </Dialog>

            <ConfirmDialog
                open={!!disputeRun}
                title={t('profile.dispute_title')}
                message={
                    disputeRun
                        ? t('profile.dispute_message', {
                              mission: disputeRun.missionLabel,
                              when: formatDateTime(disputeRun.createdAt),
                              hours,
                          })
                        : ''
                }
                confirmLabel={t('profile.dispute_send')}
                reason={{
                    label: t('profile.dispute_reason'),
                    placeholder: t('profile.dispute_placeholder'),
                    required: true,
                    maxLength: 255,
                }}
                onConfirm={sendDispute}
                onCancel={() => setDisputeRun(null)}
                busy={busy}
            />
        </Screen>
    );
}
