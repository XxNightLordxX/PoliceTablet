// Officers → officer detail: the admin cards for points (adjust), XP (check, fix), streak, goals, look, badges and
// the record (refresh, boards, void runs, reset, retire, move record). The server checks and audits each one.

import { useState, type ReactNode } from 'react';
import {
    Badge,
    Button,
    Card,
    ConfirmDialog,
    Dialog,
    Field,
    Grid,
    KeyValue,
    NumberInput,
    Row,
    Select,
    TextInput,
    Textarea,
    Toggle,
} from '../../../shared/components';
import { fmtDateTime, formatMoney, formatNumber } from '../../../shared/format';
import { useRequest } from '../../../shared/hooks';
import { request } from '../../../shared/nui';
import { hasKey, t } from '../../../shared/i18n';
import type {
    BadgeCatalog,
    OfficerGoals,
    OfficerLook,
    OfficerPoints,
    RecordMovePreview,
    VoidPreview,
    XpCheck,
} from '../../../types/admin_officers';
import type { OfficerDetail } from '../../../types/oversight';
import type { Commendation } from '../../../types/profile';
import { BulkVoidDialog } from '../BulkVoidDialog';
import { JobProgress, useAdminAction } from '../kit';
import './OfficerTools.css';

type Simple =
    | { kind: 'fixXp' }
    | { kind: 'recalcStreak' }
    | { kind: 'firstRun' }
    | { kind: 'resetLook' }
    | { kind: 'editNow' }
    | { kind: 'recheck' }
    | { kind: 'refresh' }
    | { kind: 'exclude'; excluded: boolean }
    | { kind: 'unretire' }
    | { kind: 'revoke'; badgeId: string; label: string }
    | { kind: 'clearOverride'; badgeId: string; label: string }
    | { kind: 'goal'; goal: 'daily' | 'weekly'; goalId: string; label: string };

const SIMPLE_ACTION: Record<Simple['kind'], string> = {
    fixXp: 'server:admin:fixXp',
    recalcStreak: 'server:admin:recalcStreak',
    firstRun: 'server:admin:resetFirstRun',
    resetLook: 'server:admin:resetLook',
    editNow: 'server:admin:clearProfileCooldown',
    recheck: 'server:admin:recheckBadges',
    refresh: 'server:admin:refreshOfficer',
    exclude: 'server:admin:setBoardExcluded',
    unretire: 'server:admin:unretireOfficer',
    revoke: 'server:admin:revokeBadge',
    clearOverride: 'server:admin:clearBadgeOverride',
    goal: 'server:admin:completeGoal',
};
// the actions that take no reason
const NO_REASON: Partial<Record<Simple['kind'], boolean>> = { recheck: true, refresh: true };

const errText = (e: string | null | undefined) => (e && hasKey(e) ? t(e) : (e ?? ''));

function KVList({ items }: { items: { label: ReactNode; value: ReactNode }[] }) {
    return (
        <div className="admin-otools__kv">
            {items.map((it, i) => (
                <KeyValue key={i} label={it.label}>
                    {it.value}
                </KeyValue>
            ))}
        </div>
    );
}

export function OfficerTools({ o, onChanged }: { o: OfficerDetail; onChanged: () => void }) {
    const cid = o.citizenid;
    const own = !!o.own;
    const { run, busy } = useAdminAction();
    const points = useRequest<OfficerPoints>('admin:getOfficerPoints', { citizenid: cid });
    const goals = useRequest<OfficerGoals>('admin:getOfficerGoals', { citizenid: cid });
    const look = useRequest<OfficerLook>('admin:getOfficerLook', { citizenid: cid });
    const catalog = useRequest<BadgeCatalog>('admin:getBadgeCatalog', {});
    const [simple, setSimple] = useState<Simple | null>(null);
    const [xp, setXp] = useState<XpCheck | null>(null);
    const [adjust, setAdjust] = useState<{ points: number | null; reason: string; typed: string } | null>(null);
    const [forgive, setForgive] = useState<{ days: number | null; reason: string } | null>(null);
    const [grant, setGrant] = useState<{ badgeId: string; reason: string } | null>(null);
    const [bulk, setBulk] = useState(false);
    const [reset, setReset] = useState<VoidPreview | null>(null);
    const [retire, setRetire] = useState<{
        preview: VoidPreview;
        excludeFromBoards: boolean;
        suspendDays: number | null;
    } | null>(null);
    const [move, setMove] = useState<{ to: string; preview: RecordMovePreview | null; error: string | null } | null>(
        null,
    );
    const [jobId, setJobId] = useState<string | null>(null);

    const refreshAll = () => {
        onChanged();
        void points.refetch();
        void goals.refetch();
        void look.refetch();
    };

    const doSimple = async (reason: string) => {
        if (!simple) return;
        const p: Record<string, unknown> = { citizenid: cid };
        if (!NO_REASON[simple.kind]) p.reason = reason;
        if (simple.kind === 'exclude') p.excluded = simple.excluded;
        if (simple.kind === 'revoke' || simple.kind === 'clearOverride') p.badgeId = simple.badgeId;
        if (simple.kind === 'goal') {
            p.kind = simple.goal;
            p.goalId = simple.goalId;
        }
        const res = await run<{ jobId?: string }>(SIMPLE_ACTION[simple.kind], p, { success: 'ui.admin_officers.done' });
        setSimple(null);
        if (res.ok) {
            if (res.data && typeof res.data.jobId === 'string') setJobId(res.data.jobId);
            if (simple.kind === 'fixXp') setXp(null);
            refreshAll();
        }
    };

    const checkXp = async () => {
        const res = await request<XpCheck>('admin:checkXp', { citizenid: cid });
        if (res.ok && res.data) setXp(res.data);
    };

    const adj = points.data?.adjust;
    const adjustWord = adjust && adj && Math.abs(adjust.points ?? 0) >= adj.confirmAbove ? cid : '';
    const adjustOk =
        !!adjust &&
        adjust.points !== null &&
        adjust.points !== 0 &&
        !!adjust.reason.trim() &&
        (!adjustWord || adjust.typed.trim().toUpperCase() === adjustWord.toUpperCase());
    const doAdjust = async () => {
        if (!adjust || !adjustOk) return;
        const res = await run('server:admin:adjustPoints', {
            citizenid: cid,
            points: adjust.points,
            reason: adjust.reason.trim(),
            confirm: adjustWord ? adjust.typed.trim() : undefined,
        });
        if (res.ok) {
            setAdjust(null);
            refreshAll();
        }
    };

    const doForgive = async () => {
        if (!forgive || !forgive.days || !forgive.reason.trim()) return;
        const res = await run('server:admin:forgiveStreakDays', {
            citizenid: cid,
            days: forgive.days,
            reason: forgive.reason.trim(),
        });
        if (res.ok) {
            setForgive(null);
            refreshAll();
        }
    };

    const doGrant = async () => {
        if (!grant || !grant.badgeId.trim() || !grant.reason.trim()) return;
        const res = await run('server:admin:grantBadge', {
            citizenid: cid,
            badgeId: grant.badgeId.trim(),
            reason: grant.reason.trim(),
        });
        if (res.ok) {
            setGrant(null);
            refreshAll();
        }
    };

    const openReset = async () => {
        const res = await request<VoidPreview>('admin:previewBulkVoid', {
            filter: { citizenid: cid, allTime: true, includeAwards: true },
        });
        if (res.ok && res.data) setReset(res.data);
    };
    const doReset = async (reason: string, typed: string) => {
        const res = await run<{ jobId: string }>('server:admin:resetProgression', {
            citizenid: cid,
            reason,
            confirm: typed,
            previewToken: reset?.previewToken,
        });
        setReset(null);
        if (res.ok && res.data) {
            setJobId(res.data.jobId);
            refreshAll();
        }
    };

    const openRetire = async () => {
        const res = await request<VoidPreview>('admin:previewRetire', { citizenid: cid });
        if (res.ok && res.data) setRetire({ preview: res.data, excludeFromBoards: true, suspendDays: null });
    };
    const doRetire = async (reason: string, typed: string) => {
        if (!retire) return;
        const res = await run<{ jobId: string }>('server:admin:retireOfficer', {
            citizenid: cid,
            reason,
            confirm: typed,
            previewToken: retire.preview.previewToken,
            excludeFromBoards: retire.excludeFromBoards,
            suspendDays: retire.suspendDays ?? undefined,
        });
        setRetire(null);
        if (res.ok && res.data) {
            setJobId(res.data.jobId);
            refreshAll();
        }
    };

    const previewMove = async () => {
        if (!move) return;
        const res = await request<RecordMovePreview>('admin:previewRecordMove', { from: cid, to: move.to.trim() });
        setMove({ ...move, preview: res.ok ? (res.data ?? null) : null, error: res.ok ? null : (res.error ?? null) });
    };
    const doMove = async (reason: string, typed: string) => {
        if (!move?.preview) return;
        const res = await run<{ jobId: string }>('server:admin:moveRecord', {
            from: cid,
            to: move.preview.to,
            reason,
            confirm: typed,
            previewToken: move.preview.previewToken,
        });
        if (res.ok) {
            setMove(null);
            refreshAll();
        }
    };

    const w = points.data?.windows;
    const streak = o.streak;
    const g = goals.data;
    const lk = look.data;
    const achievements = catalog.data?.achievements ?? [];

    return (
        <div className="admin-otools">
            <Card title={t('ui.admin_officers.record.title')} icon="user" padding="md">
                <p className="admin-otools__soft">{t('ui.admin_officers.record.source')}</p>
                <Row gap={2} wrap>
                    <Button
                        size="sm"
                        variant="secondary"
                        icon="refresh"
                        disabled={!o.online || busy}
                        onClick={() => setSimple({ kind: 'refresh' })}
                    >
                        {t('ui.admin_officers.record.refresh')}
                    </Button>
                    <Button
                        size="sm"
                        variant="secondary"
                        icon="eye"
                        disabled={busy}
                        onClick={() => setSimple({ kind: 'exclude', excluded: !o.boardExcluded })}
                    >
                        {o.boardExcluded
                            ? t('ui.admin_officers.record.include')
                            : t('ui.admin_officers.record.exclude')}
                    </Button>
                    <Button
                        size="sm"
                        variant="secondary"
                        icon="xCircle"
                        disabled={own || busy}
                        onClick={() => setBulk(true)}
                    >
                        {t('ui.admin_officers.record.void_runs')}
                    </Button>
                    <Button
                        size="sm"
                        variant="ghost"
                        icon="undo"
                        disabled={own || busy}
                        onClick={() => void openReset()}
                    >
                        {t('ui.admin_officers.record.reset')}
                    </Button>
                    {o.retired ? (
                        <Button
                            size="sm"
                            variant="primary"
                            icon="check"
                            disabled={busy}
                            onClick={() => setSimple({ kind: 'unretire' })}
                        >
                            {t('ui.admin_officers.record.unretire')}
                        </Button>
                    ) : (
                        <Button
                            size="sm"
                            variant="danger"
                            icon="lock"
                            disabled={own || busy}
                            onClick={() => void openRetire()}
                        >
                            {t('ui.admin_officers.record.retire')}
                        </Button>
                    )}
                    <Button
                        size="sm"
                        variant="ghost"
                        icon="users"
                        disabled={own || o.online || busy}
                        onClick={() => setMove({ to: '', preview: null, error: null })}
                    >
                        {t('ui.admin_officers.record.move')}
                    </Button>
                </Row>
                {o.retired ? (
                    <p className="admin-otools__warn">
                        {t('ui.admin_officers.record.retired_since', { date: fmtDateTime(o.retired.at) })}
                    </p>
                ) : null}
                {jobId ? <JobProgress jobId={jobId} /> : null}
            </Card>

            <Grid cols="1fr 1fr" gap={4} align="stretch">
                <Card title={t('ui.admin_officers.points.title')} icon="star" padding="md">
                    {w ? (
                        <KVList
                            items={(['weekly', 'monthly', 'season', 'alltime'] as const).map(k => ({
                                label: t(`leaderboard.period.${k}`),
                                value: w[k].rank
                                    ? t('ui.admin_officers.points.ranked', {
                                          points: formatNumber(w[k].points),
                                          rank: w[k].rank,
                                          of: w[k].ranked,
                                      })
                                    : formatNumber(w[k].points),
                            }))}
                        />
                    ) : null}
                    <Row gap={2}>
                        <Button
                            size="sm"
                            variant="primary"
                            icon="plus"
                            disabled={own || busy}
                            onClick={() => setAdjust({ points: null, reason: '', typed: '' })}
                        >
                            {t('ui.admin_officers.points.adjust')}
                        </Button>
                    </Row>
                </Card>

                <Card title={t('ui.admin_officers.xp.title')} icon="activity" padding="md">
                    <KVList
                        items={[
                            { label: t('ui.admin_officers.xp.stored'), value: formatNumber(xp?.stored ?? o.xp) },
                            ...(xp
                                ? [
                                      { label: t('ui.admin_officers.xp.derived'), value: formatNumber(xp.derived) },
                                      { label: t('ui.admin_officers.xp.diff'), value: formatNumber(xp.diff, true) },
                                  ]
                                : []),
                        ]}
                    />
                    <Row gap={2}>
                        <Button size="sm" variant="secondary" icon="search" onClick={() => void checkXp()}>
                            {t('ui.admin_officers.xp.check')}
                        </Button>
                        <Button
                            size="sm"
                            variant="primary"
                            disabled={!xp || xp.diff === 0 || busy}
                            onClick={() => setSimple({ kind: 'fixXp' })}
                        >
                            {t('ui.admin_officers.xp.fix')}
                        </Button>
                    </Row>
                </Card>

                <Card title={t('ui.admin_officers.streak.title')} icon="flame" padding="md">
                    <KVList
                        items={[
                            {
                                label: t('ui.admin_officers.streak.days'),
                                value: formatNumber(streak?.days ?? o.streakDays),
                            },
                            {
                                label: t('ui.admin_officers.streak.multiplier'),
                                value: `×${(streak?.multiplier ?? 1).toFixed(2)}`,
                            },
                            {
                                label: t('ui.admin_officers.streak.grace'),
                                value: streak?.graceLeft ? t('common.yes') : t('common.no'),
                            },
                            {
                                label: t('ui.admin_officers.streak.first_run'),
                                value:
                                    o.firstRun === null || o.firstRun === undefined
                                        ? t('ui.admin_officers.offline')
                                        : o.firstRun
                                          ? t('ui.admin_officers.streak.first_run_yes')
                                          : t('ui.admin_officers.streak.first_run_no'),
                            },
                        ]}
                    />
                    <Row gap={2} wrap>
                        <Button
                            size="sm"
                            variant="secondary"
                            disabled={busy}
                            onClick={() => setSimple({ kind: 'recalcStreak' })}
                        >
                            {t('ui.admin_officers.streak.recalc')}
                        </Button>
                        <Button
                            size="sm"
                            variant="secondary"
                            disabled={own || busy}
                            onClick={() => setForgive({ days: 1, reason: '' })}
                        >
                            {t('ui.admin_officers.streak.forgive')}
                        </Button>
                        <Button
                            size="sm"
                            variant="ghost"
                            disabled={own || !o.online || o.firstRun === true || busy}
                            onClick={() => setSimple({ kind: 'firstRun' })}
                        >
                            {t('ui.admin_officers.streak.first_run_again')}
                        </Button>
                    </Row>
                </Card>

                <Card title={t('ui.admin_officers.goals.title')} icon="target" padding="md">
                    {(['daily', 'weekly'] as const).map(kind => {
                        const goal = g?.[kind];
                        return (
                            <div key={kind} className="admin-otools__goal">
                                <span className="admin-otools__goal-name">
                                    {t(`ui.admin_officers.goals.${kind}`)}: {goal ? goal.label : t('common.none')}
                                </span>
                                {goal ? (
                                    <span className="admin-otools__soft cp-num">
                                        {goal.progress} / {goal.count}
                                    </span>
                                ) : null}
                                {goal && goal.done ? (
                                    <Badge size="sm" tone="success">
                                        {t('ui.admin_officers.goals.done')}
                                    </Badge>
                                ) : goal ? (
                                    <Button
                                        size="sm"
                                        variant="ghost"
                                        disabled={own || busy}
                                        onClick={() =>
                                            setSimple({ kind: 'goal', goal: kind, goalId: goal.id, label: goal.label })
                                        }
                                    >
                                        {t('ui.admin_officers.goals.complete')}
                                    </Button>
                                ) : null}
                            </div>
                        );
                    })}
                </Card>

                <Card title={t('ui.admin_officers.look.title')} icon="sliders" padding="md">
                    {lk ? (
                        <KVList
                            items={[
                                {
                                    label: t('ui.admin_officers.look.appearance'),
                                    value: lk.appearance ?? t('ui.admin_officers.look.default'),
                                },
                                {
                                    label: t('ui.admin_officers.look.accent'),
                                    value: lk.accent ?? t('ui.admin_officers.look.default'),
                                },
                                {
                                    label: t('ui.admin_officers.look.scale'),
                                    value: lk.uiScale ? String(lk.uiScale) : t('ui.admin_officers.look.default'),
                                },
                                {
                                    label: t('ui.admin_officers.look.hide_name'),
                                    value: lk.hideName ? t('common.yes') : t('common.no'),
                                },
                                {
                                    label: t('ui.admin_officers.look.calls_muted'),
                                    value: lk.callsMuted ? t('common.yes') : t('common.no'),
                                },
                            ]}
                        />
                    ) : null}
                    <Row gap={2}>
                        <Button
                            size="sm"
                            variant="secondary"
                            disabled={own || busy}
                            onClick={() => setSimple({ kind: 'resetLook' })}
                        >
                            {t('ui.admin_officers.look.reset')}
                        </Button>
                        <Button
                            size="sm"
                            variant="ghost"
                            disabled={own || busy}
                            onClick={() => setSimple({ kind: 'editNow' })}
                        >
                            {t('ui.admin_officers.look.edit_now')}
                        </Button>
                    </Row>
                </Card>

                <Card title={t('ui.admin_officers.badges.title')} icon="medal" padding="md">
                    <ul className="admin-otools__badges">
                        {(o.badges ?? []).map(b => (
                            <li key={b.id}>
                                <span>{b.label}</span>
                                <Badge
                                    size="sm"
                                    tone={
                                        b.source === 'blocked' ? 'danger' : b.source === 'granted' ? 'accent' : 'grey'
                                    }
                                >
                                    {t(`ui.admin_officers.badges.${b.source ?? 'earned'}`)}
                                </Badge>
                                {b.source === 'blocked' || b.source === 'granted' ? (
                                    <Button
                                        size="sm"
                                        variant="ghost"
                                        disabled={own || busy}
                                        onClick={() =>
                                            setSimple({ kind: 'clearOverride', badgeId: b.id, label: b.label })
                                        }
                                    >
                                        {t('ui.admin_officers.badges.automatic')}
                                    </Button>
                                ) : null}
                                {b.source !== 'blocked' ? (
                                    <Button
                                        size="sm"
                                        variant="ghost"
                                        disabled={own || busy}
                                        onClick={() => setSimple({ kind: 'revoke', badgeId: b.id, label: b.label })}
                                    >
                                        {t('ui.admin_officers.badges.revoke')}
                                    </Button>
                                ) : null}
                            </li>
                        ))}
                    </ul>
                    <Row gap={2}>
                        <Button
                            size="sm"
                            variant="secondary"
                            icon="plus"
                            disabled={own || busy}
                            onClick={() => setGrant({ badgeId: achievements[0]?.id ?? '', reason: '' })}
                        >
                            {t('ui.admin_officers.badges.grant')}
                        </Button>
                        <Button
                            size="sm"
                            variant="ghost"
                            icon="refresh"
                            disabled={busy}
                            onClick={() => setSimple({ kind: 'recheck' })}
                        >
                            {t('ui.admin_officers.badges.recheck')}
                        </Button>
                    </Row>
                </Card>
            </Grid>

            <ConfirmDialog
                open={!!simple}
                tone={simple && (simple.kind === 'revoke' || simple.kind === 'exclude') ? 'danger' : 'primary'}
                title={simple ? t(`ui.admin_officers.confirm.${simple.kind}`) : ''}
                message={
                    simple
                        ? t('ui.admin_officers.confirm.message', {
                              name: o.name,
                              what: 'label' in simple ? simple.label : '',
                          })
                        : null
                }
                reason={
                    simple && NO_REASON[simple.kind]
                        ? false
                        : { required: true, maxLength: 255, placeholder: t('admin.officers.reason_placeholder') }
                }
                onConfirm={doSimple}
                onCancel={() => setSimple(null)}
                busy={busy}
            />

            <Dialog
                open={!!adjust}
                onClose={() => setAdjust(null)}
                size="sm"
                title={t('ui.admin_officers.points.adjust_title', { name: o.name })}
                description={t('ui.admin_officers.points.adjust_desc', {
                    max: formatNumber(adj?.maxDeduction ?? 0),
                })}
                footer={
                    <>
                        <Button variant="ghost" onClick={() => setAdjust(null)} disabled={busy}>
                            {t('common.cancel')}
                        </Button>
                        <Button variant="primary" loading={busy} disabled={!adjustOk} onClick={() => void doAdjust()}>
                            {t('ui.admin_officers.points.adjust')}
                        </Button>
                    </>
                }
            >
                {adjust ? (
                    <div className="admin-otools__form">
                        <Field
                            label={t('ui.admin_officers.points.amount')}
                            required
                            hint={t('ui.admin_officers.points.amount_hint')}
                        >
                            <NumberInput
                                value={adjust.points}
                                onChange={v => setAdjust({ ...adjust, points: v })}
                                min={-(adj?.maxDeduction ?? 0)}
                                max={adj?.max ?? 10000}
                                stepper
                                suffix={t('common.pts')}
                            />
                        </Field>
                        {adjust.points !== null && w ? (
                            <p className="admin-otools__soft">
                                {t('ui.admin_officers.points.after', {
                                    week: formatNumber(w.weekly.points + (adjust.points ?? 0)),
                                    season: formatNumber((points.data?.seasonPoints ?? 0) + (adjust.points ?? 0)),
                                    xp: formatNumber(Math.max(0, o.xp + (adjust.points ?? 0))),
                                })}
                            </p>
                        ) : null}
                        {adjustWord ? (
                            <Field label={t('ui.admin_officers.type_word', { word: adjustWord })} required>
                                <TextInput value={adjust.typed} onChange={v => setAdjust({ ...adjust, typed: v })} />
                            </Field>
                        ) : null}
                        <Field label={t('common.reason')} required>
                            <Textarea
                                value={adjust.reason}
                                onChange={v => setAdjust({ ...adjust, reason: v })}
                                maxLength={255}
                                rows={2}
                            />
                        </Field>
                    </div>
                ) : null}
            </Dialog>

            <Dialog
                open={!!forgive}
                onClose={() => setForgive(null)}
                size="sm"
                title={t('ui.admin_officers.streak.forgive')}
                description={t('ui.admin_officers.streak.forgive_desc')}
                footer={
                    <>
                        <Button variant="ghost" onClick={() => setForgive(null)} disabled={busy}>
                            {t('common.cancel')}
                        </Button>
                        <Button
                            variant="primary"
                            loading={busy}
                            disabled={!forgive?.days || !forgive?.reason.trim()}
                            onClick={() => void doForgive()}
                        >
                            {t('ui.admin_officers.streak.forgive')}
                        </Button>
                    </>
                }
            >
                {forgive ? (
                    <div className="admin-otools__form">
                        <Field label={t('ui.admin_officers.streak.days')} required>
                            <NumberInput
                                value={forgive.days}
                                onChange={v => setForgive({ ...forgive, days: v })}
                                min={1}
                                max={7}
                                stepper
                            />
                        </Field>
                        <Field label={t('common.reason')} required>
                            <Textarea
                                value={forgive.reason}
                                onChange={v => setForgive({ ...forgive, reason: v })}
                                maxLength={255}
                                rows={2}
                            />
                        </Field>
                    </div>
                ) : null}
            </Dialog>

            <Dialog
                open={!!grant}
                onClose={() => setGrant(null)}
                size="sm"
                title={t('ui.admin_officers.badges.grant')}
                description={t('ui.admin_officers.badges.grant_desc')}
                footer={
                    <>
                        <Button variant="ghost" onClick={() => setGrant(null)} disabled={busy}>
                            {t('common.cancel')}
                        </Button>
                        <Button
                            variant="primary"
                            loading={busy}
                            disabled={!grant?.badgeId.trim() || !grant?.reason.trim()}
                            onClick={() => void doGrant()}
                        >
                            {t('ui.admin_officers.badges.grant')}
                        </Button>
                    </>
                }
            >
                {grant ? (
                    <div className="admin-otools__form">
                        <Field label={t('ui.admin_officers.badges.badge')} required>
                            <Select
                                value={achievements.some(a => a.id === grant.badgeId) ? grant.badgeId : ''}
                                onChange={v => setGrant({ ...grant, badgeId: v })}
                                placeholder={t('ui.admin_officers.badges.other')}
                                options={achievements.map(a => ({ value: a.id, label: a.label }))}
                            />
                        </Field>
                        <Field
                            label={t('ui.admin_officers.badges.badge_id')}
                            hint={t('ui.admin_officers.badges.badge_id_hint')}
                        >
                            <TextInput
                                value={grant.badgeId}
                                onChange={v => setGrant({ ...grant, badgeId: v })}
                                maxLength={40}
                            />
                        </Field>
                        <Field label={t('common.reason')} required>
                            <Textarea
                                value={grant.reason}
                                onChange={v => setGrant({ ...grant, reason: v })}
                                maxLength={255}
                                rows={2}
                            />
                        </Field>
                    </div>
                ) : null}
            </Dialog>

            <ConfirmDialog
                open={!!reset}
                tone="danger"
                title={t('ui.admin_officers.record.reset')}
                message={t('ui.admin_officers.record.reset_message', {
                    rows: formatNumber(reset?.total ?? 0),
                    points: formatNumber(reset?.points ?? 0),
                })}
                typedWord={cid}
                reason={{ required: true, maxLength: 255 }}
                onConfirm={doReset}
                onCancel={() => setReset(null)}
                busy={busy}
            />

            <ConfirmDialog
                open={!!retire}
                tone="danger"
                title={t('ui.admin_officers.record.retire')}
                message={
                    retire?.preview.busy
                        ? errText(retire.preview.busy)
                        : t('ui.admin_officers.record.retire_message', {
                              rows: formatNumber(retire?.preview.total ?? 0),
                              points: formatNumber(retire?.preview.points ?? 0),
                              held: formatMoney(retire?.preview.held ?? 0),
                          })
                }
                effect={
                    retire ? (
                        <div className="admin-otools__form">
                            <Toggle
                                checked={retire.excludeFromBoards}
                                onChange={v => setRetire({ ...retire, excludeFromBoards: v })}
                                label={t('ui.admin_officers.record.exclude')}
                            />
                            <Field label={t('ui.admin_officers.record.suspend_days')}>
                                <NumberInput
                                    value={retire.suspendDays}
                                    onChange={v => setRetire({ ...retire, suspendDays: v })}
                                    min={1}
                                    max={3650}
                                />
                            </Field>
                        </div>
                    ) : null
                }
                typedWord={cid}
                reason={{ required: true, maxLength: 255 }}
                onConfirm={doRetire}
                onCancel={() => setRetire(null)}
                busy={busy}
            />

            <Dialog
                open={!!move && !move.preview}
                onClose={() => setMove(null)}
                size="sm"
                title={t('ui.admin_officers.record.move')}
                description={t('ui.admin_officers.record.move_desc')}
                footer={
                    <>
                        <Button variant="ghost" onClick={() => setMove(null)}>
                            {t('common.cancel')}
                        </Button>
                        <Button variant="primary" disabled={!move?.to.trim()} onClick={() => void previewMove()}>
                            {t('ui.admin_officers.bulk.preview')}
                        </Button>
                    </>
                }
            >
                {move ? (
                    <div className="admin-otools__form">
                        <Field
                            label={t('ui.admin_officers.record.move_to')}
                            required
                            error={move.error ? errText(move.error) : undefined}
                        >
                            <TextInput
                                value={move.to}
                                onChange={v => setMove({ ...move, to: v, error: null })}
                                maxLength={50}
                            />
                        </Field>
                    </div>
                ) : null}
            </Dialog>
            <ConfirmDialog
                open={!!move?.preview}
                tone="danger"
                title={t('ui.admin_officers.record.move')}
                message={
                    move?.preview
                        ? t(
                              move.preview.verified
                                  ? 'ui.admin_officers.record.move_message'
                                  : 'ui.admin_officers.record.move_unverified',
                              {
                                  rows: formatNumber(move.preview.effect.rows),
                                  points: formatNumber(move.preview.effect.points),
                                  badges: formatNumber(move.preview.effect.badges),
                                  held: formatMoney(move.preview.effect.held),
                                  to: move.preview.to,
                              },
                          )
                        : null
                }
                typedWord={move?.preview?.confirmWord}
                reason={{ required: true, maxLength: 255 }}
                onConfirm={doMove}
                onCancel={() => setMove(null)}
                busy={busy}
            />

            <BulkVoidDialog
                open={bulk}
                onClose={() => {
                    setBulk(false);
                    refreshAll();
                }}
                initial={{ citizenid: cid }}
                name={o.name}
            />
        </div>
    );
}

// Commendations: put a revoked one back, or correct a citation (A5). Both need a reason and are audited.
export function CommendationTools({
    commendations,
    onChanged,
}: {
    commendations: Commendation[];
    onChanged: () => void;
}) {
    const { run, busy } = useAdminAction();
    const [unrevoke, setUnrevoke] = useState<Commendation | null>(null);
    const [edit, setEdit] = useState<{ c: Commendation; citation: string; reason: string } | null>(null);
    if (!commendations.length) return null;
    const doUnrevoke = async (reason: string) => {
        if (!unrevoke) return;
        const res = await run('server:admin:unrevokeCommendation', { id: unrevoke.id, reason }, { requestId: false });
        setUnrevoke(null);
        if (res.ok) onChanged();
    };
    const doEdit = async () => {
        if (!edit || !edit.citation.trim() || !edit.reason.trim()) return;
        const res = await run(
            'server:admin:editCitation',
            { id: edit.c.id, citation: edit.citation.trim(), reason: edit.reason.trim() },
            { requestId: false },
        );
        if (res.ok) {
            setEdit(null);
            onChanged();
        }
    };
    return (
        <Card title={t('ui.admin_officers.commend.title')} icon="medal" padding="md">
            <ul className="admin-otools__badges">
                {commendations.map(c => (
                    <li key={c.id}>
                        <span>
                            {c.kind} · “{c.citation}”
                        </span>
                        {c.revoked ? (
                            <>
                                <Badge size="sm" tone="danger">
                                    {t('ui.admin_officers.commend.revoked')}
                                </Badge>
                                <Button size="sm" variant="ghost" disabled={busy} onClick={() => setUnrevoke(c)}>
                                    {t('ui.admin_officers.commend.unrevoke')}
                                </Button>
                            </>
                        ) : null}
                        <Button
                            size="sm"
                            variant="ghost"
                            icon="edit"
                            disabled={busy}
                            onClick={() => setEdit({ c, citation: c.citation, reason: '' })}
                        >
                            {t('ui.admin_officers.commend.edit')}
                        </Button>
                    </li>
                ))}
            </ul>
            <ConfirmDialog
                open={!!unrevoke}
                title={t('ui.admin_officers.commend.unrevoke')}
                message={unrevoke ? `“${unrevoke.citation}”` : null}
                reason={{ required: true, maxLength: 255 }}
                onConfirm={doUnrevoke}
                onCancel={() => setUnrevoke(null)}
                busy={busy}
            />
            <Dialog
                open={!!edit}
                onClose={() => setEdit(null)}
                size="sm"
                title={t('ui.admin_officers.commend.edit')}
                footer={
                    <>
                        <Button variant="ghost" onClick={() => setEdit(null)} disabled={busy}>
                            {t('common.cancel')}
                        </Button>
                        <Button
                            variant="primary"
                            loading={busy}
                            disabled={!edit?.citation.trim() || !edit?.reason.trim()}
                            onClick={() => void doEdit()}
                        >
                            {t('common.save')}
                        </Button>
                    </>
                }
            >
                {edit ? (
                    <div className="admin-otools__form">
                        <Field label={t('ui.admin_officers.commend.citation')} required>
                            <Textarea
                                value={edit.citation}
                                onChange={v => setEdit({ ...edit, citation: v })}
                                maxLength={255}
                                rows={3}
                            />
                        </Field>
                        <Field label={t('common.reason')} required>
                            <Textarea
                                value={edit.reason}
                                onChange={v => setEdit({ ...edit, reason: v })}
                                maxLength={255}
                                rows={2}
                            />
                        </Field>
                    </div>
                ) : null}
            </Dialog>
        </Card>
    );
}
