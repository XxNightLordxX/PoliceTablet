// Seasons → season tools: rename, planned end, reopen within 24 h and Undo, next week's bounty, a past season
// (Recount bounty week, Recount champion) and a department's contributors.

import { useState } from 'react';
import {
    Badge,
    Button,
    Card,
    ConfirmDialog,
    Dialog,
    ErrorState,
    Field,
    LoadingBlock,
    Row,
    Select,
    TextInput,
} from '../../../shared/components';
import { fmtDateTime, formatNumber } from '../../../shared/format';
import { useRequest } from '../../../shared/hooks';
import { request } from '../../../shared/nui';
import { t } from '../../../shared/i18n';
import { useSession } from '../../../shared/session';
import type {
    BountyRecountPreview,
    ChampionRecountPreview,
    Contributor,
    ReopenPreview,
    SeasonDetail,
} from '../../../types/admin_officers';
import type { DeptContributors, SeasonListRow, SeasonView } from '../../../types/boards';
import { JobProgress, useAdminAction } from '../kit';
import '../officers/OfficerTools.css';

const toLocalInput = (ts: number) => {
    const d = new Date(ts * 1000);
    const p = (n: number) => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
};

export function SeasonDetailDialog({ id, onClose }: { id: number | null; onClose: () => void }) {
    const { data, loading, error, refetch } = useRequest<SeasonDetail>(
        'admin:getSeason',
        { id },
        { skip: id === null },
    );
    const { run, busy } = useAdminAction();
    const [bounty, setBounty] = useState<BountyRecountPreview | null>(null);
    const [champ, setChamp] = useState<ChampionRecountPreview | null>(null);
    const d = data && data.season.id === id ? data : null;

    const openBounty = async (week: number) => {
        const res = await request<BountyRecountPreview>('admin:previewBountyRecount', { week });
        if (res.ok && res.data) setBounty(res.data);
    };
    const openChamp = async () => {
        const res = await request<ChampionRecountPreview>('admin:previewChampionRecount', { seasonId: id });
        if (res.ok && res.data) setChamp(res.data);
    };
    const doBounty = async (reason: string, typed: string) => {
        if (!bounty) return;
        const res = await run(
            'server:admin:recountBountyWeek',
            { week: bounty.week, reason, confirm: typed, previewToken: bounty.previewToken },
            { requestId: false, success: 'ui.admin_officers.done' },
        );
        setBounty(null);
        if (res.ok) void refetch();
    };
    const doChamp = async (reason: string, typed: string) => {
        if (!champ) return;
        const res = await run(
            'server:admin:recountChampion',
            { seasonId: champ.seasonId, reason, confirm: typed, previewToken: champ.previewToken },
            { requestId: false, success: 'ui.admin_officers.done' },
        );
        setChamp(null);
        if (res.ok) void refetch();
    };

    return (
        <>
            <Dialog
                open={id !== null}
                onClose={onClose}
                size="lg"
                title={d ? d.season.name : t('ui.admin_officers.season.title')}
                footer={
                    <Button variant="primary" onClick={onClose}>
                        {t('common.close')}
                    </Button>
                }
            >
                {!d && loading ? (
                    <LoadingBlock />
                ) : !d && error ? (
                    <ErrorState compact error={error} onRetry={() => void refetch()} />
                ) : d ? (
                    <div className="admin-otools__form">
                        <Row gap={2} wrap>
                            <Badge tone={d.season.active ? 'success' : 'grey'}>
                                {d.season.active ? t('admin.seasons.running') : t('admin.seasons.ended')}
                            </Badge>
                            {d.championShort ? (
                                <Badge tone="gold" icon="trophy">
                                    {d.championShort}
                                </Badge>
                            ) : null}
                            {d.championRecount ? (
                                <Button size="sm" variant="secondary" disabled={busy} onClick={() => void openChamp()}>
                                    {t('ui.admin_officers.season.recount_champion')}
                                </Button>
                            ) : null}
                        </Row>
                        <ul className="admin-otools__badges">
                            {d.weeks.map(w => (
                                <li key={w.week}>
                                    <span>
                                        {t('ui.admin_officers.season.week', { n: w.week })} · {w.label} · {w.startDate}{' '}
                                        – {w.endDate}
                                    </span>
                                    <Badge size="sm" tone={w.winnerShort ? 'success' : 'grey'}>
                                        {w.closed
                                            ? (w.winnerShort ?? t('admin.seasons.no_winner'))
                                            : t('admin.seasons.open')}
                                    </Badge>
                                    {w.closed && d.season.active ? (
                                        <Button
                                            size="sm"
                                            variant="ghost"
                                            disabled={busy}
                                            onClick={() => void openBounty(w.week)}
                                        >
                                            {t('ui.admin_officers.season.recount')}
                                        </Button>
                                    ) : null}
                                </li>
                            ))}
                        </ul>
                        {d.trophies.length ? (
                            <p className="admin-otools__soft">
                                {t('ui.admin_officers.season.trophies', {
                                    list: d.trophies.map(h => h.name).join(', '),
                                })}
                            </p>
                        ) : null}
                        {d.top10.length ? (
                            <p className="admin-otools__soft">
                                {t('ui.admin_officers.season.top10', { list: d.top10.map(h => h.name).join(', ') })}
                            </p>
                        ) : null}
                    </div>
                ) : null}
            </Dialog>
            <ConfirmDialog
                open={!!bounty}
                tone="danger"
                title={t('ui.admin_officers.season.recount')}
                message={
                    bounty
                        ? t('ui.admin_officers.season.recount_message', {
                              old: bounty.oldShort ?? t('common.none'),
                              new: bounty.newShort ?? t('common.none'),
                          })
                        : null
                }
                typedWord="RECOUNT"
                reason={{ required: true, maxLength: 255 }}
                onConfirm={doBounty}
                onCancel={() => setBounty(null)}
                busy={busy}
            />
            <ConfirmDialog
                open={!!champ}
                tone="danger"
                title={t('ui.admin_officers.season.recount_champion')}
                message={
                    champ
                        ? t('ui.admin_officers.season.champion_message', {
                              old: champ.oldShort ?? t('common.none'),
                              new: champ.newShort ?? t('common.none'),
                              cancel: champ.rewards.filter(r => r.fate === 'cancel').length,
                              kept: champ.rewards.filter(r => r.fate === 'kept').length,
                          })
                        : null
                }
                typedWord="RECOUNT"
                reason={{ required: true, maxLength: 255 }}
                onConfirm={doChamp}
                onCancel={() => setChamp(null)}
                busy={busy}
            />
        </>
    );
}

function ContributorsDialog({ dept, onClose }: { dept: string | null; onClose: () => void }) {
    const { data, loading } = useRequest<DeptContributors>(
        'admin:getDeptContributors',
        { department: dept },
        { skip: !dept },
    );
    const list: Contributor[] = data?.contributors ?? [];
    return (
        <Dialog
            open={!!dept}
            onClose={onClose}
            size="md"
            title={data?.department?.label ?? t('ui.admin_officers.season.contributors')}
            description={data?.season ? data.season.name : undefined}
            footer={
                <Button variant="primary" onClick={onClose}>
                    {t('common.close')}
                </Button>
            }
        >
            {loading && !data ? (
                <LoadingBlock />
            ) : (
                <ul className="admin-otools__badges">
                    {list.map((c, i) => (
                        <li key={c.citizenid ?? i}>
                            <span>
                                {i + 1}. {[c.callsign, c.name].filter(Boolean).join(' ')}
                            </span>
                            <span className="cp-num">{formatNumber(c.points)}</span>
                            {c.active === false ? (
                                <Badge size="sm" tone="grey">
                                    {t('ui.admin_officers.season.not_active')}
                                </Badge>
                            ) : null}
                        </li>
                    ))}
                </ul>
            )}
        </Dialog>
    );
}

export function SeasonTools({
    current,
    seasons,
    bounties,
    onChanged,
}: {
    current: SeasonView | null;
    seasons: SeasonListRow[];
    bounties: { id: string; label: string }[];
    onChanged: () => void;
}) {
    const session = useSession();
    const { run, busy } = useAdminAction();
    const [rename, setRename] = useState<{ id: number; name: string } | null>(null);
    const [plan, setPlan] = useState<{ at: string; nextName: string; reason: string } | null>(null);
    const [cancelPlan, setCancelPlan] = useState(false);
    const [reopen, setReopen] = useState<ReopenPreview | null>(null);
    const [undoJob, setUndoJob] = useState<string | null>(null);
    const [undoOpen, setUndoOpen] = useState(false);
    const [next, setNext] = useState('');
    const [dept, setDept] = useState<string | null>(null);
    const latest = seasons[0];

    const doRename = async () => {
        if (!rename || !rename.name.trim()) return;
        const res = await run(
            'server:admin:renameSeason',
            { id: rename.id, name: rename.name.trim() },
            { requestId: false },
        );
        if (res.ok) {
            setRename(null);
            onChanged();
        }
    };
    const planTs = plan?.at ? Math.floor(new Date(plan.at).getTime() / 1000) : 0;
    const doPlan = async () => {
        if (!current || !plan || !planTs || !plan.reason.trim()) return;
        const res = await run(
            'server:admin:scheduleSeasonEnd',
            { id: current.id, at: planTs, nextName: plan.nextName.trim() || undefined, reason: plan.reason.trim() },
            { requestId: false, success: 'ui.admin_officers.done' },
        );
        if (res.ok) {
            setPlan(null);
            onChanged();
        }
    };
    const doCancelPlan = async () => {
        if (!current) return;
        const res = await run('server:admin:cancelSeasonEnd', { id: current.id }, { requestId: false });
        setCancelPlan(false);
        if (res.ok) onChanged();
    };
    const openReopen = async () => {
        if (!latest) return;
        const res = await request<ReopenPreview>('admin:previewReopen', { id: latest.id });
        if (res.ok && res.data) setReopen(res.data);
    };
    const doReopen = async (reason: string, typed: string) => {
        if (!reopen) return;
        const res = await run<{ jobId: string }>('server:admin:reopenSeason', {
            id: reopen.season.id,
            reason,
            confirm: typed,
            previewToken: reopen.previewToken,
        });
        setReopen(null);
        if (res.ok && res.data) {
            setUndoJob(res.data.jobId);
            onChanged();
        }
    };
    const doUndo = async (reason: string) => {
        if (!undoJob) return;
        const res = await run('server:admin:undoReopen', { jobId: undoJob, reason });
        setUndoOpen(false);
        if (res.ok) {
            setUndoJob(null);
            onChanged();
        }
    };
    const doNext = async () => {
        if (!next) return;
        const res = await run(
            'server:admin:setNextBounty',
            { objective: next },
            { requestId: false, success: 'ui.admin_officers.done' },
        );
        if (res.ok) onChanged();
    };

    return (
        <Card title={t('ui.admin_officers.season.tools')} icon="sliders" padding="md">
            <div className="admin-otools__form">
                {current ? (
                    <>
                        <p className="admin-otools__soft">
                            {current.plannedEnd
                                ? t('ui.admin_officers.season.planned', {
                                      date: fmtDateTime(current.plannedEnd),
                                      next: current.nextName ?? t('common.none'),
                                  })
                                : t('ui.admin_officers.season.no_plan')}
                        </p>
                        <Row gap={2} wrap>
                            <Button
                                size="sm"
                                variant="secondary"
                                icon="edit"
                                disabled={busy}
                                onClick={() => setRename({ id: current.id, name: current.name })}
                            >
                                {t('ui.admin_officers.season.rename')}
                            </Button>
                            <Button
                                size="sm"
                                variant="secondary"
                                icon="calendar"
                                disabled={busy}
                                onClick={() =>
                                    setPlan({
                                        at: current.plannedEnd ? toLocalInput(current.plannedEnd) : '',
                                        nextName: current.nextName ?? '',
                                        reason: '',
                                    })
                                }
                            >
                                {current.plannedEnd
                                    ? t('ui.admin_officers.season.change_plan')
                                    : t('ui.admin_officers.season.plan')}
                            </Button>
                            {current.plannedEnd ? (
                                <Button size="sm" variant="ghost" disabled={busy} onClick={() => setCancelPlan(true)}>
                                    {t('ui.admin_officers.season.cancel_plan')}
                                </Button>
                            ) : null}
                        </Row>
                        {bounties.length ? (
                            <Row gap={2} wrap>
                                <Select
                                    value={next}
                                    onChange={setNext}
                                    placeholder={t('ui.admin_officers.season.next_bounty')}
                                    options={bounties.map(b => ({ value: b.id, label: b.label }))}
                                    aria-label={t('ui.admin_officers.season.next_bounty')}
                                />
                                <Button
                                    size="sm"
                                    variant="secondary"
                                    disabled={!next || busy}
                                    onClick={() => void doNext()}
                                >
                                    {t('ui.admin_officers.season.set_next')}
                                </Button>
                            </Row>
                        ) : null}
                    </>
                ) : latest?.canReopen ? (
                    <Row gap={2} wrap>
                        <span className="admin-otools__soft">
                            {t('ui.admin_officers.season.reopen_hint', { name: latest.name })}
                        </span>
                        <Button
                            size="sm"
                            variant="secondary"
                            icon="undo"
                            disabled={busy}
                            onClick={() => void openReopen()}
                        >
                            {t('ui.admin_officers.season.reopen')}
                        </Button>
                    </Row>
                ) : null}
                {undoJob ? (
                    <Row gap={2}>
                        <JobProgress jobId={undoJob} />
                        <Button size="sm" variant="ghost" icon="undo" disabled={busy} onClick={() => setUndoOpen(true)}>
                            {t('ui.admin_officers.season.undo_reopen')}
                        </Button>
                    </Row>
                ) : null}
                <Row gap={2} wrap>
                    <span className="admin-otools__soft">{t('ui.admin_officers.season.contributors')}</span>
                    {(session.config?.departments ?? []).map(d => (
                        <Button key={d.key} size="sm" variant="ghost" onClick={() => setDept(d.key)}>
                            {d.short}
                        </Button>
                    ))}
                </Row>
            </div>

            <Dialog
                open={!!rename}
                onClose={() => setRename(null)}
                size="sm"
                title={t('ui.admin_officers.season.rename')}
                footer={
                    <>
                        <Button variant="ghost" onClick={() => setRename(null)}>
                            {t('common.cancel')}
                        </Button>
                        <Button
                            variant="primary"
                            loading={busy}
                            disabled={!rename?.name.trim()}
                            onClick={() => void doRename()}
                        >
                            {t('common.save')}
                        </Button>
                    </>
                }
            >
                {rename ? (
                    <Field label={t('admin.seasons.name')} required>
                        <TextInput
                            value={rename.name}
                            onChange={v => setRename({ ...rename, name: v })}
                            maxLength={64}
                        />
                    </Field>
                ) : null}
            </Dialog>

            <Dialog
                open={!!plan}
                onClose={() => setPlan(null)}
                size="sm"
                title={t('ui.admin_officers.season.plan')}
                description={t('ui.admin_officers.season.plan_desc')}
                footer={
                    <>
                        <Button variant="ghost" onClick={() => setPlan(null)}>
                            {t('common.cancel')}
                        </Button>
                        <Button
                            variant="primary"
                            loading={busy}
                            disabled={!planTs || !plan?.reason.trim()}
                            onClick={() => void doPlan()}
                        >
                            {t('common.save')}
                        </Button>
                    </>
                }
            >
                {plan ? (
                    <div className="admin-otools__form">
                        <Field label={t('ui.admin_officers.season.plan_at')} required>
                            <div className="cp-input">
                                <input
                                    type="datetime-local"
                                    value={plan.at}
                                    onChange={e => setPlan({ ...plan, at: e.target.value })}
                                />
                            </div>
                        </Field>
                        <Field
                            label={t('ui.admin_officers.season.next_name')}
                            hint={t('ui.admin_officers.season.next_name_hint')}
                        >
                            <TextInput
                                value={plan.nextName}
                                onChange={v => setPlan({ ...plan, nextName: v })}
                                maxLength={64}
                            />
                        </Field>
                        <Field label={t('common.reason')} required>
                            <TextInput
                                value={plan.reason}
                                onChange={v => setPlan({ ...plan, reason: v })}
                                maxLength={255}
                            />
                        </Field>
                    </div>
                ) : null}
            </Dialog>

            <ConfirmDialog
                open={cancelPlan}
                title={t('ui.admin_officers.season.cancel_plan')}
                onConfirm={doCancelPlan}
                onCancel={() => setCancelPlan(false)}
                busy={busy}
            />

            <ConfirmDialog
                open={!!reopen}
                tone="danger"
                title={t('ui.admin_officers.season.reopen')}
                message={
                    reopen
                        ? t('ui.admin_officers.season.reopen_message', {
                              champion: reopen.championShort ?? t('common.none'),
                              trophies: reopen.trophies.length,
                              top10: reopen.top10.length,
                              cancel: reopen.rewards.filter(r => r.fate === 'cancel').length,
                              kept: reopen.rewards.filter(r => r.fate === 'kept').length,
                              rows: reopen.gapRows,
                          })
                        : null
                }
                typedWord={reopen?.season.name}
                reason={{ required: true, maxLength: 255 }}
                onConfirm={doReopen}
                onCancel={() => setReopen(null)}
                busy={busy}
            />

            <ConfirmDialog
                open={undoOpen}
                tone="danger"
                title={t('ui.admin_officers.season.undo_reopen')}
                message={t('ui.admin_officers.season.undo_message')}
                reason={{ required: true, maxLength: 255 }}
                onConfirm={doUndo}
                onCancel={() => setUndoOpen(false)}
                busy={busy}
            />

            <ContributorsDialog dept={dept} onClose={() => setDept(null)} />
        </Card>
    );
}
