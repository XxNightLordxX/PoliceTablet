// Admin UI → Live: every live run (tests and Cross-Department Missions too) and every unit, with Recall, End run,
// End test, + minutes, Remove from unit and Disband (modules/livectl/server.lua).

import { useEffect, useState } from 'react';
import {
    Badge,
    Button,
    Card,
    ConfirmDialog,
    Countdown,
    EmptyState,
    ErrorState,
    Field,
    Icon,
    IconButton,
    LoadingBlock,
    NumberInput,
    Row,
    Screen,
    Tabs,
    TierBadge,
} from '../../shared/components';
import { asArray } from '../../shared/data';
import { formatDateTime, formatDuration } from '../../shared/format';
import { useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { useNavigate } from '../../shared/navigation';
import { useSession } from '../../shared/session';
import type {
    AdminLiveParticipant,
    AdminLiveRun,
    AdminLiveRunsData,
    AdminUnit,
    AdminUnitsData,
} from '../../types/admin_live';
import { useAdminAction } from '../components/kit';
import './Live.css';

type Tab = 'runs' | 'units';

type RunDialog =
    | { kind: 'recall'; run: AdminLiveRun; p: AdminLiveParticipant }
    | { kind: 'end'; run: AdminLiveRun }
    | { kind: 'endTest'; run: AdminLiveRun }
    | { kind: 'time'; run: AdminLiveRun };

type UnitDialog = { kind: 'remove'; unit: AdminUnit; src: number; name: string } | { kind: 'disband'; unit: AdminUnit };

function typeLabel(session: ReturnType<typeof useSession>, key: string): string {
    return asArray(session.config.missionTypes).find(m => m.key === key)?.label ?? key;
}

// ============================================================================
//                                   RUN CARD
// ============================================================================

function addTimeTitle(run: AdminLiveRun, maxLeft: number): string | undefined {
    if (run.own) return t('admin.live.own_run');
    if (!run.timerRunning) return t('admin.live.time_not_running');
    if (maxLeft < 60) return t('admin.live.time_max_reached');
    return undefined;
}

function RunCard({
    run,
    fetchKey,
    maxLeft,
    onDialog,
}: {
    run: AdminLiveRun;
    fetchKey: number;
    maxLeft: number;
    onDialog: (d: RunDialog) => void;
}) {
    const session = useSession();
    const navigate = useNavigate();
    const people = asArray(run.participants);
    const active = people.filter(p => p.status === 'active').length;
    const inProgress = run.state === 'in_progress';
    const ownTitle = run.own ? t('admin.live.own_run') : undefined;
    const canAdd = inProgress && run.timerRunning && !run.own && maxLeft >= 60;
    return (
        <Card
            className="admin-live-card"
            highlight={run.test ? 'warning' : run.operationId ? 'accent' : inProgress ? 'success' : 'primary'}
            title={
                <span className="admin-live-card__title">
                    {run.missionLabel}
                    {run.test ? (
                        <Badge size="sm" tone="warning" variant="solid">
                            {t('admin.live.kind.test')}
                        </Badge>
                    ) : null}
                    {run.operationId ? (
                        <Badge size="sm" tone="accent" icon="globe">
                            {t('admin.live.kind.operation')}
                        </Badge>
                    ) : null}
                    {run.isBoss ? (
                        <Badge size="sm" tone="accent" icon="star">
                            {t('admin.live.kind.boss')}
                        </Badge>
                    ) : null}
                    {run.own ? (
                        <Badge size="sm" tone="grey" icon="user">
                            {t('admin.live.yours')}
                        </Badge>
                    ) : null}
                </span>
            }
            subtitle={`${typeLabel(session, run.missionType)} · ${asArray(run.departments).join(' + ') || '—'}`}
            actions={run.tier ? <TierBadge tier={run.tier} size="sm" /> : null}
            footer={
                <Row gap={2} className="admin-live-card__actions">
                    <Button
                        size="sm"
                        variant="secondary"
                        icon="plus"
                        disabled={!canAdd}
                        title={addTimeTitle(run, maxLeft)}
                        onClick={() => onDialog({ kind: 'time', run })}
                    >
                        {t('admin.live.add_time')}
                    </Button>
                    {run.test ? (
                        <Button size="sm" variant="danger" icon="x" onClick={() => onDialog({ kind: 'endTest', run })}>
                            {t('admin.live.end_test')}
                        </Button>
                    ) : (
                        <Button
                            size="sm"
                            variant="danger"
                            icon="x"
                            disabled={run.own}
                            title={ownTitle}
                            onClick={() => onDialog({ kind: 'end', run })}
                        >
                            {t('admin.live.end_run')}
                        </Button>
                    )}
                </Row>
            }
        >
            <div className="admin-live-facts">
                <div className="admin-live-fact">
                    <span className="admin-live-fact__label">{t('admin.live.state')}</span>
                    <Badge size="sm" tone={inProgress ? 'success' : 'primary'} dot>
                        {t(`admin.live.state.${inProgress ? 'in_progress' : 'accepted'}`)}
                    </Badge>
                </div>
                <div className="admin-live-fact">
                    <span className="admin-live-fact__label">{t('admin.live.time_left')}</span>
                    {inProgress && run.remaining !== null && run.remaining !== undefined ? (
                        <span className="admin-live-fact__value">
                            <Icon name="clock" size={14} />
                            <Countdown
                                seconds={run.remaining}
                                paused={run.paused}
                                resetKey={fetchKey}
                                warnBelow={120}
                                dangerBelow={30}
                            />
                        </span>
                    ) : (
                        <span className="admin-live-fact__value admin-live-muted">{t('admin.live.not_started')}</span>
                    )}
                </div>
                <div className="admin-live-fact">
                    <span className="admin-live-fact__label">{t('admin.live.time_added')}</span>
                    <span className="admin-live-fact__value cp-num">
                        {run.timeAdded > 0 ? `+${formatDuration(run.timeAdded)}` : '—'}
                    </span>
                </div>
                <div className="admin-live-fact">
                    <span className="admin-live-fact__label">{t('admin.live.accepted')}</span>
                    <span className="admin-live-fact__value cp-num">{formatDateTime(run.acceptedAt)}</span>
                </div>
                <div className="admin-live-fact">
                    <span className="admin-live-fact__label">{t('admin.live.participants')}</span>
                    <span className="admin-live-fact__value cp-num">
                        {t('admin.live.active_of', { active, total: people.length })}
                    </span>
                </div>
            </div>
            <ul className="admin-live-people">
                {people.map(p => {
                    const left = p.status !== 'active';
                    return (
                        <li key={p.src} className={left ? 'admin-live-person is-left' : 'admin-live-person'}>
                            <button
                                type="button"
                                className="admin-live-person__who"
                                title={t('admin.live.open_officer')}
                                onClick={() => navigate('admin_officers', { citizenid: p.citizenid })}
                            >
                                <span className="admin-live-person__name">{p.name}</span>
                                <span className="admin-live-person__sub">
                                    {p.callsign || t('common.no_callsign')} · {p.citizenid}
                                </span>
                            </button>
                            <Badge size="sm" variant="outline">
                                {p.departmentShort}
                            </Badge>
                            {left ? (
                                <Badge size="sm" tone="grey">
                                    {p.endReason
                                        ? t('admin.live.left', { reason: t(`reason.${p.endReason}`) })
                                        : t('admin.live.left_plain')}
                                </Badge>
                            ) : p.arrived ? (
                                <Badge size="sm" tone="success">
                                    {t('admin.live.arrived')}
                                </Badge>
                            ) : (
                                <Badge size="sm" tone="primary" icon="navigation">
                                    {t('admin.live.en_route')}
                                </Badge>
                            )}
                            {!left && !run.test ? (
                                <Button
                                    size="sm"
                                    variant="ghost"
                                    icon="logout"
                                    disabled={run.own}
                                    title={ownTitle}
                                    onClick={() => onDialog({ kind: 'recall', run, p })}
                                >
                                    {t('admin.live.recall')}
                                </Button>
                            ) : (
                                <span className="admin-live-person__placeholder" />
                            )}
                        </li>
                    );
                })}
            </ul>
        </Card>
    );
}

// ============================================================================
//                                  UNITS TAB
// ============================================================================

function blockedText(unit: AdminUnit): string | undefined {
    if (unit.own) return t('admin.live.own_unit');
    if (unit.blocked) return t(unit.blocked);
    return undefined;
}

function unitSubtitle(unit: AdminUnit): string {
    if (unit.readyCheck) return t('admin.live.unit_ready_check', { type: unit.readyCheck.typeLabel });
    if (unit.runId) return t('admin.live.unit_on_run');
    if (unit.locked) return t('admin.live.unit_locked');
    return t('admin.live.unit_open', { invites: unit.invites });
}

function UnitCard({ unit, onDialog }: { unit: AdminUnit; onDialog: (d: UnitDialog) => void }) {
    const blocked = blockedText(unit);
    const members = asArray(unit.members);
    return (
        <Card
            className="admin-live-card"
            highlight={unit.locked ? 'warning' : 'primary'}
            title={t('admin.live.unit_title', { id: unit.id, n: members.length })}
            subtitle={unitSubtitle(unit)}
            actions={
                <Button
                    size="sm"
                    variant="danger"
                    icon="users"
                    disabled={!!blocked}
                    title={blocked}
                    onClick={() => onDialog({ kind: 'disband', unit })}
                >
                    {t('admin.live.disband')}
                </Button>
            }
        >
            <ul className="admin-live-people">
                {members.map(m => (
                    <li key={m.src} className="admin-live-person">
                        <span className="admin-live-person__who admin-live-person__who--static">
                            <span className="admin-live-person__name">
                                {m.name}
                                {m.leader ? (
                                    <Badge size="sm" tone="accent" className="admin-live-leader">
                                        {t('admin.live.leader')}
                                    </Badge>
                                ) : null}
                            </span>
                            <span className="admin-live-person__sub">
                                {m.callsign || t('common.no_callsign')} · {m.rank}
                            </span>
                        </span>
                        <Badge size="sm" variant="outline">
                            {m.departmentShort}
                        </Badge>
                        {m.onRun ? (
                            <Badge size="sm" tone="success">
                                {t('admin.live.on_run')}
                            </Badge>
                        ) : (
                            <span className="admin-live-person__placeholder" />
                        )}
                        <Button
                            size="sm"
                            variant="ghost"
                            icon="logout"
                            disabled={!!blocked}
                            title={blocked}
                            onClick={() => onDialog({ kind: 'remove', unit, src: m.src, name: m.name })}
                        >
                            {t('admin.live.remove')}
                        </Button>
                    </li>
                ))}
            </ul>
        </Card>
    );
}

// ============================================================================
//                                   DIALOGS
// ============================================================================

function runDialogTexts(d: RunDialog | null, left: number): { title: string; message: string; confirm: string } {
    if (!d) return { title: '', message: '', confirm: '' };
    if (d.kind === 'recall') {
        return {
            title: t('admin.live.recall_title', { name: d.p.name }),
            message: t('admin.live.recall_message', { mission: d.run.missionLabel }),
            confirm: t('admin.live.recall'),
        };
    }
    if (d.kind === 'end') {
        const n = asArray(d.run.participants).filter(p => p.status === 'active').length;
        return {
            title: t('admin.live.end_title', { mission: d.run.missionLabel }),
            message: t('admin.live.end_message', { n }),
            confirm: t('admin.live.end_run'),
        };
    }
    if (d.kind === 'endTest') {
        return {
            title: t('admin.live.end_test_title', { mission: d.run.missionLabel }),
            message: t('admin.live.end_test_message'),
            confirm: t('admin.live.end_test'),
        };
    }
    return {
        title: t('admin.live.time_title', { mission: d.run.missionLabel }),
        message: t('admin.live.time_message', { left: formatDuration(left) }),
        confirm: t('admin.live.add_time'),
    };
}

// ============================================================================
//                                    SCREEN
// ============================================================================

export default function AdminLive() {
    const [tab, setTab] = useState<Tab>('runs');
    const runsReq = useRequest<AdminLiveRunsData>('admin:getLiveRuns', {}, { pollMs: 10000, pushTopic: 'operation' });
    const unitsReq = useRequest<AdminUnitsData>('admin:getUnits', {}, { pollMs: 10000, skip: tab !== 'units' });
    const { run, busy } = useAdminAction();
    const [runDialog, setRunDialog] = useState<RunDialog | null>(null);
    const [unitDialog, setUnitDialog] = useState<UnitDialog | null>(null);
    const [minutes, setMinutes] = useState<number | null>(5);
    const [fetchKey, setFetchKey] = useState(0);

    const runs = asArray(runsReq.data?.runs);
    const units = asArray(unitsReq.data?.units);
    const maxTotal = runsReq.data?.runTimeAddMax ?? 600;
    const clickMax = runsReq.data?.addMinutesMax ?? 10;

    // every answer re-syncs the local countdowns
    useEffect(() => {
        if (runsReq.data) setFetchKey(k => k + 1);
    }, [runsReq.data]);

    useEffect(() => {
        if (runDialog?.kind === 'time') setMinutes(Math.min(5, clickMax));
    }, [runDialog, clickMax]);

    const leftFor = (r: AdminLiveRun) => Math.max(0, maxTotal - (r.timeAdded || 0));

    const confirmRun = async (reason: string, typed: string) => {
        const d = runDialog;
        if (!d) return;
        let res;
        if (d.kind === 'recall') {
            res = await run(
                'server:admin:recall',
                { runId: d.run.runId, src: d.p.src, reason },
                { success: 'admin.live.recalled', successVars: { name: d.p.name } },
            );
        } else if (d.kind === 'end') {
            res = await run(
                'server:admin:endRun',
                { runId: d.run.runId, reason, confirm: typed },
                { success: 'admin.live.ended', successVars: { mission: d.run.missionLabel } },
            );
        } else if (d.kind === 'endTest') {
            res = await run(
                'server:admin:endTest',
                { runId: d.run.runId, reason },
                { success: 'admin.live.test_ended', successVars: { mission: d.run.missionLabel } },
            );
        } else {
            if (!minutes) return;
            res = await run(
                'server:admin:addRunTime',
                { runId: d.run.runId, minutes, reason },
                { success: 'admin.live.time_added_ok', successVars: { minutes } },
            );
        }
        setRunDialog(null);
        if (res.ok) void runsReq.refetch();
    };

    const confirmUnit = async (reason: string) => {
        const d = unitDialog;
        if (!d) return;
        const res =
            d.kind === 'remove'
                ? await run(
                      'server:admin:removeFromUnit',
                      { unitId: d.unit.id, src: d.src, reason },
                      { success: 'admin.live.removed', successVars: { name: d.name } },
                  )
                : await run(
                      'server:admin:disbandUnit',
                      { unitId: d.unit.id, reason },
                      { success: 'admin.live.disbanded' },
                  );
        setUnitDialog(null);
        if (res.ok) void unitsReq.refetch();
    };

    const current = tab === 'runs' ? runsReq : unitsReq;
    let body;
    if (current.loading && !current.data) body = <LoadingBlock />;
    else if (current.error && !current.data)
        body = (
            <Card>
                <ErrorState error={current.error} onRetry={() => void current.refetch()} />
            </Card>
        );
    else if (tab === 'runs')
        body = runs.length ? (
            <div className="admin-live-list">
                {runs.map(r => (
                    <RunCard key={r.runId} run={r} fetchKey={fetchKey} maxLeft={leftFor(r)} onDialog={setRunDialog} />
                ))}
            </div>
        ) : (
            <Card padding="none">
                <EmptyState icon="activity" title={t('admin.live.empty_title')} text={t('admin.live.empty_text')} />
            </Card>
        );
    else
        body = units.length ? (
            <div className="admin-live-list">
                {units.map(u => (
                    <UnitCard key={u.id} unit={u} onDialog={setUnitDialog} />
                ))}
            </div>
        ) : (
            <Card padding="none">
                <EmptyState
                    icon="users"
                    title={t('admin.live.units_empty_title')}
                    text={t('admin.live.units_empty_text')}
                />
            </Card>
        );

    const d = runDialog;
    const texts = runDialogTexts(d, d ? leftFor(d.run) : 0);
    const timeMax =
        d && d.kind === 'time' ? Math.max(1, Math.min(clickMax, Math.floor(leftFor(d.run) / 60))) : clickMax;

    return (
        <Screen
            title={t('ui.screen.admin_live')}
            subtitle={t('admin.live.subtitle')}
            actions={
                <Row gap={2}>
                    {runs.length ? (
                        <Badge tone="success" dot>
                            {t('admin.live.count', { n: runs.length })}
                        </Badge>
                    ) : null}
                    <IconButton
                        icon="refresh"
                        label={t('admin.live.refresh')}
                        variant="secondary"
                        loading={current.loading && !!current.data}
                        onClick={() => void current.refetch()}
                    />
                </Row>
            }
            className="admin-live-screen"
        >
            <Tabs<Tab>
                items={[
                    { key: 'runs', label: t('admin.live.tab.runs'), icon: 'activity', badge: runs.length || undefined },
                    { key: 'units', label: t('admin.live.tab.units'), icon: 'users' },
                ]}
                value={tab}
                onChange={setTab}
                aria-label={t('ui.screen.admin_live')}
            />
            {body}
            <ConfirmDialog
                open={!!d}
                tone={d && d.kind !== 'time' ? 'danger' : 'primary'}
                title={texts.title}
                message={texts.message}
                effect={
                    d && d.kind === 'time' ? (
                        <Field label={t('admin.live.minutes')}>
                            <NumberInput value={minutes} onChange={setMinutes} min={1} max={timeMax} suffix="min" />
                        </Field>
                    ) : null
                }
                typedWord={d && d.kind === 'end' ? 'END' : undefined}
                confirmLabel={texts.confirm}
                reason={{ required: true, label: t('common.reason'), maxLength: 255 }}
                onConfirm={confirmRun}
                onCancel={() => setRunDialog(null)}
                busy={busy}
            />
            <ConfirmDialog
                open={!!unitDialog}
                tone="danger"
                title={
                    unitDialog
                        ? unitDialog.kind === 'remove'
                            ? t('admin.live.remove_title', { name: unitDialog.name })
                            : t('admin.live.disband_title', { id: unitDialog.unit.id })
                        : ''
                }
                message={
                    unitDialog
                        ? t(unitDialog.kind === 'remove' ? 'admin.live.remove_message' : 'admin.live.disband_message')
                        : null
                }
                confirmLabel={unitDialog?.kind === 'remove' ? t('admin.live.remove') : t('admin.live.disband')}
                reason={{ required: true, label: t('common.reason'), maxLength: 255 }}
                onConfirm={reason => confirmUnit(reason)}
                onCancel={() => setUnitDialog(null)}
                busy={busy}
            />
        </Screen>
    );
}
