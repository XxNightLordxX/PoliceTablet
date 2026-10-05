// Officers → the server-wide tabs: Review (every pending picture, bio and report, plus the banned-words list),
// Disputes (every open dispute) and Corrections (every bulk void, retirement, record move and season reopen, with
// Undo). Each row can open the officer.

import { useState } from 'react';
import {
    Badge,
    Button,
    Card,
    ConfirmDialog,
    EmptyState,
    ErrorState,
    Field,
    LoadingBlock,
    Row,
    Table,
    TextInput,
    Textarea,
    type TableColumn,
} from '../../../shared/components';
import { fmtDateTime, formatNumber } from '../../../shared/format';
import { useRequest } from '../../../shared/hooks';
import { request } from '../../../shared/nui';
import { t } from '../../../shared/i18n';
import type { BannedTest, BannedWords, CorrectionBatch } from '../../../types/admin_officers';
import type { DisputeView } from '../../../types/oversight';
import { ProfilesReview } from '../../../supervisor/components/ProfilesReview';
import { JobProgress, useAdminAction } from '../kit';
import './OfficerTools.css';

// ============================================================================
//                                    REVIEW
// ============================================================================

function BannedWordsCard() {
    const { data, refetch } = useRequest<BannedWords>('admin:getBannedWords', {});
    const { run, busy } = useAdminAction();
    const [add, setAdd] = useState('');
    const [remove, setRemove] = useState('');
    const [test, setTest] = useState('');
    const [result, setResult] = useState<BannedTest | null>(null);
    const [confirm, setConfirm] = useState(false);
    const split = (s: string) =>
        s
            .split(/[\n,]/)
            .map(w => w.trim())
            .filter(Boolean);

    const save = async (reason: string) => {
        const res = await run(
            'server:admin:setBannedWords',
            { add: split(add), remove: split(remove), reason },
            { requestId: false, success: 'ui.admin_officers.done' },
        );
        setConfirm(false);
        if (res.ok) {
            setAdd('');
            setRemove('');
            void refetch();
        }
    };
    const runTest = async () => {
        const res = await request<BannedTest>('admin:testBannedWords', { text: test });
        if (res.ok && res.data) setResult(res.data);
    };

    return (
        <Card title={t('ui.admin_officers.banned.title')} icon="shield" padding="md">
            <p className="admin-otools__soft">
                {data?.file
                    ? t('ui.admin_officers.banned.file', { file: data.file, n: formatNumber(data.words.length) })
                    : t('ui.admin_officers.banned.no_file')}
            </p>
            <div className="admin-otools__form">
                <Field label={t('ui.admin_officers.banned.add')} hint={t('ui.admin_officers.banned.hint')}>
                    <Textarea value={add} onChange={setAdd} rows={2} />
                </Field>
                <Field label={t('ui.admin_officers.banned.remove')}>
                    <Textarea value={remove} onChange={setRemove} rows={2} />
                </Field>
                <Row gap={2}>
                    <Button
                        size="sm"
                        variant="primary"
                        disabled={busy || !data?.file || (!split(add).length && !split(remove).length)}
                        onClick={() => setConfirm(true)}
                    >
                        {t('common.save')}
                    </Button>
                </Row>
                <Field label={t('ui.admin_officers.banned.test')}>
                    <TextInput value={test} onChange={setTest} onEnter={() => void runTest()} maxLength={1000} />
                </Field>
                <Row gap={2}>
                    <Button size="sm" variant="secondary" disabled={!test.trim()} onClick={() => void runTest()}>
                        {t('ui.admin_officers.banned.test_run')}
                    </Button>
                    {result ? (
                        <Badge tone={result.banned ? 'danger' : 'success'}>
                            {result.banned
                                ? t('ui.admin_officers.banned.caught', { words: result.matches.join(', ') })
                                : t('ui.admin_officers.banned.clean')}
                        </Badge>
                    ) : null}
                </Row>
            </div>
            <ConfirmDialog
                open={confirm}
                title={t('ui.admin_officers.banned.title')}
                message={t('ui.admin_officers.banned.confirm', {
                    add: split(add).length,
                    remove: split(remove).length,
                })}
                reason={{ required: true, maxLength: 255 }}
                onConfirm={save}
                onCancel={() => setConfirm(false)}
                busy={busy}
            />
        </Card>
    );
}

export function ReviewTab() {
    return (
        <div className="admin-otools">
            <Card title={t('ui.admin_officers.tab.review')} icon="eye" padding="md">
                <ProfilesReview scope="admin" />
            </Card>
            <BannedWordsCard />
        </div>
    );
}

// ============================================================================
//                                   DISPUTES
// ============================================================================

export function DisputesTab({ onOpen }: { onOpen: (citizenid: string) => void }) {
    const { data, loading, error, refetch } = useRequest<{ disputes: DisputeView[] }>(
        'admin:getDisputes',
        {},
        { pollMs: 60000 },
    );
    const rows = data?.disputes ?? [];
    const columns: TableColumn<DisputeView>[] = [
        { key: 'when', header: t('ui.admin_officers.col.when'), width: 120, render: d => fmtDateTime(d.createdAt) },
        {
            key: 'officer',
            header: t('ui.admin_officers.col.officer'),
            width: 180,
            render: d => [d.callsign, d.name].filter(Boolean).join(' '),
        },
        { key: 'mission', header: t('ui.admin_officers.col.mission'), render: d => d.missionLabel },
        { key: 'reason', header: t('common.reason'), render: d => `“${d.reason}”` },
        {
            key: 'goes',
            header: '',
            width: 110,
            render: d => (
                <Badge size="sm" variant="outline">
                    {d.goesTo === 'admin' ? t('ui.admin_officers.disputes.admin') : t('ui.admin_officers.disputes.sup')}
                </Badge>
            ),
        },
    ];
    if (!data && loading) return <LoadingBlock />;
    if (!data && error) return <ErrorState error={error} onRetry={() => void refetch()} />;
    return (
        <Card
            title={t('ui.admin_officers.tab.disputes')}
            icon="inbox"
            subtitle={t('ui.admin_officers.disputes.hint')}
            padding="none"
        >
            <Table
                columns={columns}
                rows={rows}
                rowKey={d => d.id}
                onRowClick={d => onOpen(d.citizenid)}
                dense
                empty={t('admin.officers.no_disputes')}
            />
        </Card>
    );
}

// ============================================================================
//                                 CORRECTIONS
// ============================================================================

const UNDO_ACTION: Record<string, string> = {
    restoreBatch: 'server:admin:restoreBatch',
    unretire: 'server:admin:unretireOfficer',
    undoRecordMove: 'server:admin:undoRecordMove',
    undoReopen: 'server:admin:undoReopen',
};

export function CorrectionsTab({ citizenid }: { citizenid?: string }) {
    const { data, loading, error, refetch } = useRequest<{ batches: CorrectionBatch[] }>(
        'admin:getCorrections',
        citizenid ? { citizenid } : {},
        { pushTopic: 'adminjob' },
    );
    const { run, busy } = useAdminAction();
    const [undo, setUndo] = useState<CorrectionBatch | null>(null);
    const [jobId, setJobId] = useState<string | null>(null);
    const rows = data?.batches ?? [];

    const doUndo = async (reason: string) => {
        if (!undo?.undo) return;
        const p: Record<string, unknown> = { reason };
        if (undo.undo === 'restoreBatch') p.batchId = undo.id;
        else if (undo.undo === 'unretire') p.citizenid = String(undo.filter.citizenid ?? '');
        else p.jobId = undo.id;
        const res = await run<{ jobId?: string }>(UNDO_ACTION[undo.undo], p, { success: 'ui.admin_officers.done' });
        setUndo(null);
        if (res.ok) {
            if (res.data?.jobId) setJobId(res.data.jobId);
            void refetch();
        }
    };

    const columns: TableColumn<CorrectionBatch>[] = [
        { key: 'when', header: t('ui.admin_officers.col.when'), width: 120, render: b => fmtDateTime(b.createdAt) },
        {
            key: 'kind',
            header: t('ui.admin_officers.corrections.kind'),
            width: 150,
            render: b => t(`ui.admin_officers.batch.${b.kind}`),
        },
        {
            key: 'what',
            header: t('ui.admin_officers.corrections.what'),
            render: b =>
                Object.entries(b.filter)
                    .filter(([, v]) => v !== null && v !== undefined && v !== '' && typeof v !== 'object')
                    .map(([k, v]) => `${k}: ${String(v)}`)
                    .join(' · '),
        },
        {
            key: 'rows',
            header: t('ui.admin_officers.corrections.rows'),
            numeric: true,
            width: 80,
            render: b => `${b.done}/${b.total}`,
        },
        { key: 'by', header: t('ui.admin_officers.corrections.by'), width: 110, render: b => b.actor },
        {
            key: 'undo',
            header: '',
            width: 110,
            align: 'right',
            render: b =>
                b.restored || b.undone ? (
                    <Badge size="sm" tone="grey">
                        {t('ui.admin_officers.corrections.undone')}
                    </Badge>
                ) : b.undo && b.state === 'done' ? (
                    <Button size="sm" variant="secondary" icon="undo" disabled={busy} onClick={() => setUndo(b)}>
                        {t('ui.admin_officers.corrections.undo')}
                    </Button>
                ) : (
                    <Badge size="sm" tone={b.state === 'failed' ? 'danger' : 'grey'}>
                        {t(`ui.kit.job.${b.state}`)}
                    </Badge>
                ),
        },
    ];

    if (!data && loading) return <LoadingBlock />;
    if (!data && error) return <ErrorState error={error} onRetry={() => void refetch()} />;
    return (
        <Card
            title={t('ui.admin_officers.tab.corrections')}
            icon="undo"
            subtitle={t('ui.admin_officers.corrections.hint')}
            padding="none"
        >
            {rows.length ? (
                <Table columns={columns} rows={rows} rowKey={b => b.id} dense />
            ) : (
                <EmptyState compact icon="undo" title={t('ui.admin_officers.corrections.none')} />
            )}
            {jobId ? <JobProgress jobId={jobId} /> : null}
            <ConfirmDialog
                open={!!undo}
                title={t('ui.admin_officers.corrections.undo')}
                message={undo ? t('ui.admin_officers.corrections.undo_message', { n: undo.total }) : null}
                reason={{ required: true, maxLength: 255 }}
                onConfirm={doUndo}
                onCancel={() => setUndo(null)}
                busy={busy}
            />
        </Card>
    );
}
