// Officers → Runs: one officer's run history, live and archived (admin:getOfficerRuns), and the run dialog
// (admin:getRun) with Void (strike or correction, all participants, goal rewards), Restore, Change kind, Flag.

import { useState } from 'react';
import {
    Badge,
    Button,
    Checkbox,
    ConfirmDialog,
    Dialog,
    ErrorState,
    Field,
    LoadingBlock,
    Money,
    Points,
    Row,
    Select,
    Table,
    Toggle,
    type TableColumn,
} from '../../../shared/components';
import { DecisionsBlock, PeopleBlock } from '../../../hud/Debrief';
import { fmtDateTime, formatNumber } from '../../../shared/format';
import { useRequest } from '../../../shared/hooks';
import { hasKey, t } from '../../../shared/i18n';
import type { OfficerRunRow, OfficerRunsPage, RunDetail, VoidKind } from '../../../types/admin_officers';
import { DateRangeField, Pager, useAdminAction, type DateRange } from '../kit';
import './OfficerTools.css';

type RunTool =
    | { kind: 'void'; all: boolean; strike: boolean; goals: boolean }
    | { kind: 'restore'; lift: boolean }
    | { kind: 'setKind'; to: VoidKind; lift: boolean }
    | { kind: 'flag' };

const cashLabel = (s: string) => (hasKey(`result.cash_status.${s}`) ? t(`result.cash_status.${s}`) : s);

export function RunDialog({
    rowId,
    archived,
    onClose,
    onChanged,
}: {
    rowId: number | null;
    archived?: boolean;
    onClose: () => void;
    onChanged?: () => void;
}) {
    const { data, loading, error, refetch } = useRequest<RunDetail>(
        'admin:getRun',
        { rowId, archived: !!archived },
        { skip: rowId === null },
    );
    const { run, busy } = useAdminAction();
    const [tool, setTool] = useState<RunTool | null>(null);
    const r = data && data.id === rowId ? data : null;
    const manual = r ? r.missionType === 'manual_award' || r.missionType === 'goal' : false;
    const others = r ? r.participantsList.filter(p => !p.voided).length : 0;

    const apply = async (reason: string, typed: string) => {
        if (!r || !tool) return;
        let res;
        if (tool.kind === 'void') {
            res = await run(
                'server:admin:voidRun',
                {
                    rowId: tool.all ? undefined : r.id,
                    runUuid: tool.all ? r.runUuid : undefined,
                    kind: tool.strike ? 'strike' : 'correction',
                    goalRowIds: tool.goals ? r.goalRewards.map(g => g.rowId) : undefined,
                    confirm: typed || undefined,
                    reason,
                },
                { requestId: false, success: 'admin.officers.voided_toast' },
            );
        } else if (tool.kind === 'restore') {
            res = await run(
                'server:admin:restoreRun',
                { rowId: r.id, archived: r.archived, liftSuspension: tool.lift, reason },
                { requestId: false, success: 'ui.admin_officers.run.restored' },
            );
        } else if (tool.kind === 'setKind') {
            res = await run(
                'server:admin:setVoidKind',
                { rowId: r.id, kind: tool.to, liftSuspension: tool.lift, reason },
                { requestId: false, success: 'ui.admin_officers.done' },
            );
        } else {
            res = await run(
                'server:admin:flagRow',
                { rowId: r.id, reason },
                { requestId: false, success: 'ui.admin_officers.run.flagged' },
            );
        }
        setTool(null);
        if (res.ok) {
            void refetch();
            onChanged?.();
        }
    };

    const voidAll = tool?.kind === 'void' && tool.all;
    const word = voidAll && others >= 3 ? `VOID ${others}` : undefined;

    return (
        <>
            <Dialog
                open={rowId !== null}
                onClose={onClose}
                size="lg"
                title={r ? `${r.missionLabel} · #${r.id}` : t('ui.admin_officers.run.title')}
                description={r ? `${fmtDateTime(r.createdAt)} · ${r.missionTypeLabel}` : undefined}
                footer={
                    r && !r.own ? (
                        <Row gap={2} wrap>
                            {!r.voided && !r.archived ? (
                                <Button
                                    variant="danger"
                                    icon="xCircle"
                                    disabled={busy}
                                    onClick={() => setTool({ kind: 'void', all: false, strike: false, goals: true })}
                                >
                                    {t('admin.officers.void')}
                                </Button>
                            ) : null}
                            {r.voided ? (
                                <Button
                                    variant="primary"
                                    icon="undo"
                                    disabled={busy}
                                    onClick={() => setTool({ kind: 'restore', lift: false })}
                                >
                                    {t('ui.admin_officers.run.restore')}
                                </Button>
                            ) : null}
                            {r.voided && !r.archived ? (
                                <Button
                                    variant="secondary"
                                    disabled={busy}
                                    onClick={() =>
                                        setTool({
                                            kind: 'setKind',
                                            to: r.voidKind === 'correction' ? 'strike' : 'correction',
                                            lift: false,
                                        })
                                    }
                                >
                                    {t('ui.admin_officers.run.change_kind')}
                                </Button>
                            ) : null}
                            {!r.voided && !r.flagged && !r.archived && !manual ? (
                                <Button
                                    variant="ghost"
                                    icon="flag"
                                    disabled={busy}
                                    onClick={() => setTool({ kind: 'flag' })}
                                >
                                    {t('ui.admin_officers.run.flag')}
                                </Button>
                            ) : null}
                            <Button variant="ghost" onClick={onClose}>
                                {t('common.close')}
                            </Button>
                        </Row>
                    ) : (
                        <Button variant="primary" onClick={onClose}>
                            {t('common.close')}
                        </Button>
                    )
                }
            >
                {!r && loading ? (
                    <LoadingBlock />
                ) : !r && error ? (
                    <ErrorState compact error={error} onRetry={() => void refetch()} />
                ) : r ? (
                    <div className="admin-otools__form">
                        {r.own ? <p className="admin-otools__warn">{t('ui.admin_officers.run.own')}</p> : null}
                        <Row gap={2} wrap>
                            <Badge
                                tone={r.state === 'completed' ? 'success' : r.state === 'failed' ? 'danger' : 'grey'}
                            >
                                {t(`sup.state.${r.state}`)}
                            </Badge>
                            {r.voided ? (
                                <Badge tone="danger">
                                    {r.voidKind === 'correction'
                                        ? t('ui.admin_officers.run.void_correction')
                                        : t('ui.admin_officers.run.void_strike')}
                                </Badge>
                            ) : null}
                            {r.flagged ? (
                                <Badge tone="warning" icon="flag">
                                    {t('flag.flagged')}
                                </Badge>
                            ) : null}
                            {r.archived ? <Badge variant="outline">{t('ui.admin_officers.archived')}</Badge> : null}
                            <span className="cp-num">
                                <Points value={r.points} />
                            </span>
                            <Money amount={r.cashPaid > 0 ? r.cashPaid : r.cash} />
                            <span className="admin-otools__soft">{cashLabel(r.cashStatus)}</span>
                        </Row>
                        {r.txnId ? (
                            <p className="admin-otools__soft">
                                {t('ui.admin_officers.run.txn')}: <code className="cp-selectable">{r.txnId}</code>
                            </p>
                        ) : null}
                        {r.awardBy ? (
                            <p className="admin-otools__soft">
                                {t('ui.admin_officers.run.award_by', { who: r.awardBy, reason: r.awardReason ?? '' })}
                            </p>
                        ) : null}
                        {r.dispute ? (
                            <p className="admin-otools__soft">
                                {t('ui.admin_officers.run.dispute', {
                                    status: r.dispute.status,
                                    reason: r.dispute.reason,
                                })}
                            </p>
                        ) : null}
                        {r.breakdown?.decisions ? <DecisionsBlock decisions={r.breakdown.decisions} detail /> : null}
                        {r.breakdown?.people ? <PeopleBlock people={r.breakdown.people} /> : null}
                        <ul className="admin-otools__badges">
                            {r.participantsList.map(p => (
                                <li key={`${p.archived ? 'A' : 'L'}${p.rowId}`}>
                                    <span>
                                        {[p.callsign, p.name].filter(Boolean).join(' ')} · {p.department}
                                    </span>
                                    <span className="cp-num">{formatNumber(p.points)}</span>
                                    {p.voided ? (
                                        <Badge size="sm" tone="danger">
                                            {t('admin.officers.voided')}
                                        </Badge>
                                    ) : null}
                                </li>
                            ))}
                        </ul>
                        {r.goalRewards.length ? (
                            <p className="admin-otools__soft">
                                {t('ui.admin_officers.run.goal_rewards', {
                                    list: r.goalRewards.map(g => `${g.label} (+${g.points})`).join(', '),
                                })}
                            </p>
                        ) : null}
                    </div>
                ) : null}
            </Dialog>

            <ConfirmDialog
                open={!!tool && !!r}
                tone={tool?.kind === 'restore' ? 'primary' : 'danger'}
                title={tool ? t(`ui.admin_officers.run.tool.${tool.kind}`) : ''}
                message={r ? `${r.missionLabel} · ${fmtDateTime(r.createdAt)}` : null}
                effect={
                    tool && r ? (
                        <div className="admin-otools__form">
                            {tool.kind === 'void' ? (
                                <>
                                    {others > 1 ? (
                                        <Checkbox
                                            checked={tool.all}
                                            onChange={v => setTool({ ...tool, all: v })}
                                            label={t('ui.admin_officers.run.void_all', { n: others })}
                                        />
                                    ) : null}
                                    <Toggle
                                        checked={tool.strike}
                                        onChange={v => setTool({ ...tool, strike: v })}
                                        label={t('ui.admin_officers.bulk.strike')}
                                        description={t('ui.admin_officers.bulk.strike_hint')}
                                    />
                                    {r.goalRewards.length ? (
                                        <Checkbox
                                            checked={tool.goals}
                                            onChange={v => setTool({ ...tool, goals: v })}
                                            label={t('ui.admin_officers.run.void_goals', { n: r.goalRewards.length })}
                                        />
                                    ) : null}
                                </>
                            ) : null}
                            {tool.kind === 'restore' ? (
                                <>
                                    <p className="admin-otools__soft">{t('ui.admin_officers.run.restore_hint')}</p>
                                    <Checkbox
                                        checked={tool.lift}
                                        onChange={v => setTool({ ...tool, lift: v })}
                                        label={t('ui.admin_officers.run.lift')}
                                    />
                                </>
                            ) : null}
                            {tool.kind === 'setKind' ? (
                                <>
                                    <Field label={t('ui.admin_officers.run.kind')}>
                                        <Select
                                            value={tool.to}
                                            onChange={v => setTool({ ...tool, to: v as VoidKind })}
                                            options={[
                                                {
                                                    value: 'correction',
                                                    label: t('ui.admin_officers.run.void_correction'),
                                                },
                                                { value: 'strike', label: t('ui.admin_officers.run.void_strike') },
                                            ]}
                                        />
                                    </Field>
                                    {tool.to === 'correction' ? (
                                        <Checkbox
                                            checked={tool.lift}
                                            onChange={v => setTool({ ...tool, lift: v })}
                                            label={t('ui.admin_officers.run.lift')}
                                        />
                                    ) : null}
                                </>
                            ) : null}
                            {tool.kind === 'flag' ? (
                                <p className="admin-otools__soft">{t('ui.admin_officers.run.flag_hint')}</p>
                            ) : null}
                        </div>
                    ) : null
                }
                typedWord={word}
                reason={{ required: true, maxLength: 255 }}
                onConfirm={apply}
                onCancel={() => setTool(null)}
                busy={busy}
            />
        </>
    );
}

export function OfficerRuns({ citizenid }: { citizenid: string }) {
    const [page, setPage] = useState(1);
    const [range, setRange] = useState<DateRange>({ from: '', to: '' });
    const [state, setState] = useState('');
    const [only, setOnly] = useState('');
    const [archive, setArchive] = useState(true);
    const [open, setOpen] = useState<OfficerRunRow | null>(null);
    const args = {
        citizenid,
        page,
        size: 25,
        from: range.from || undefined,
        to: range.to || undefined,
        state: state || undefined,
        flagged: only === 'flagged' ? true : undefined,
        voided: only === 'voided' ? true : only === 'counted' ? false : undefined,
        kind: only === 'strike' || only === 'correction' ? only : undefined,
        includeArchive: archive,
    };
    const { data, loading, error, refetch } = useRequest<OfficerRunsPage>('admin:getOfficerRuns', args);
    const rows = data?.runs ?? [];

    const columns: TableColumn<OfficerRunRow>[] = [
        { key: 'when', header: t('ui.admin_officers.col.when'), width: 120, render: r => fmtDateTime(r.createdAt) },
        {
            key: 'mission',
            header: t('ui.admin_officers.col.mission'),
            render: r => (
                <span>
                    {r.missionLabel}{' '}
                    {r.archived ? (
                        <Badge size="sm" variant="outline">
                            {t('ui.admin_officers.archived')}
                        </Badge>
                    ) : null}
                </span>
            ),
        },
        {
            key: 'state',
            header: t('admin.officers.col.result'),
            width: 160,
            render: r => (
                <Row gap={1} wrap>
                    <Badge
                        size="sm"
                        tone={r.state === 'completed' ? 'success' : r.state === 'failed' ? 'danger' : 'grey'}
                    >
                        {t(`sup.state.${r.state}`)}
                    </Badge>
                    {r.flagged ? (
                        <Badge size="sm" tone="warning" icon="flag">
                            {t('flag.flagged')}
                        </Badge>
                    ) : null}
                    {r.voided ? (
                        <Badge size="sm" tone="danger">
                            {r.voidKind === 'correction'
                                ? t('ui.admin_officers.run.void_correction')
                                : t('ui.admin_officers.run.void_strike')}
                        </Badge>
                    ) : null}
                </Row>
            ),
        },
        {
            key: 'points',
            header: t('admin.officers.col.points'),
            numeric: true,
            width: 70,
            render: r => <Points value={r.points} />,
        },
        {
            key: 'cash',
            header: t('admin.officers.col.cash'),
            numeric: true,
            width: 100,
            render: r => <Money amount={r.cashPaid > 0 ? r.cashPaid : r.cash} />,
        },
    ];

    return (
        <div className="admin-otools">
            <Row gap={2} wrap>
                <DateRangeField
                    value={range}
                    onChange={r => {
                        setRange(r);
                        setPage(1);
                    }}
                />
                <Field label={t('ui.admin_officers.runs.state')}>
                    <Select
                        value={state}
                        onChange={v => {
                            setState(v);
                            setPage(1);
                        }}
                        placeholder={t('ui.admin_officers.bulk.any')}
                        options={['completed', 'failed', 'abandoned'].map(s => ({
                            value: s,
                            label: t(`sup.state.${s}`),
                        }))}
                    />
                </Field>
                <Field label={t('ui.admin_officers.runs.only')}>
                    <Select
                        value={only}
                        onChange={v => {
                            setOnly(v);
                            setPage(1);
                        }}
                        placeholder={t('ui.admin_officers.bulk.any')}
                        options={['counted', 'flagged', 'voided', 'strike', 'correction'].map(s => ({
                            value: s,
                            label: t(`ui.admin_officers.runs.only_${s}`),
                        }))}
                    />
                </Field>
                <Checkbox checked={archive} onChange={setArchive} label={t('ui.admin_officers.runs.archive')} />
            </Row>
            {error && !data ? (
                <ErrorState compact error={error} onRetry={() => void refetch()} />
            ) : (
                <Table
                    columns={columns}
                    rows={rows}
                    rowKey={r => `${r.archived ? 'A' : 'L'}${r.id}`}
                    onRowClick={r => setOpen(r)}
                    dense
                    loading={loading && !data}
                    empty={t('admin.officers.no_runs')}
                />
            )}
            <Pager page={data?.page ?? 1} pages={data?.pages ?? 1} onPage={setPage} />
            <RunDialog
                rowId={open ? open.id : null}
                archived={open?.archived}
                onClose={() => setOpen(null)}
                onChanged={() => void refetch()}
            />
        </div>
    );
}
