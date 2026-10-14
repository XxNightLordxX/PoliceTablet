// BulkVoidDialog: void every row an officer, a department, a type, a mission or an operation earned between two
// dates, as one batch that Undo restores (admin:previewBulkVoid, server:admin:bulkVoid). Used by Officers (Void
// runs…), Leaderboards (Void runs in this window…) and the Missions operation history (P2, with operationId).

import { useEffect, useState } from 'react';
import {
    Badge,
    Button,
    Checkbox,
    Dialog,
    ErrorState,
    Field,
    Select,
    TextInput,
    Textarea,
    Toggle,
    type TableColumn,
} from '../../shared/components';
import { formatDateTime, formatMoney, formatNumber } from '../../shared/format';
import { request } from '../../shared/nui';
import { t } from '../../shared/i18n';
import { useSession } from '../../shared/session';
import type { BulkVoidFilter, VoidPreview, VoidPreviewRow } from '../../types/admin_officers';
import { DateRangeField, JobProgress, PreviewTable, useAdminAction, type DateRange } from './kit';
import './BulkVoidDialog.css';

const today = () => new Date().toISOString().slice(0, 10);
const daysAgo = (n: number) => new Date(Date.now() - n * 86400000).toISOString().slice(0, 10);

export interface BulkVoidDialogProps {
    open: boolean;
    onClose: () => void;
    // fixed parts of the filter (the officer of the Officers screen, an operation, a board window)
    initial?: BulkVoidFilter;
    // the officer's name for the title
    name?: string;
    onDone?: (jobId: string) => void;
}

export function BulkVoidDialog({ open, onClose, initial, name, onDone }: BulkVoidDialogProps) {
    const session = useSession();
    const { run, busy } = useAdminAction();
    const [range, setRange] = useState<DateRange>({ from: daysAgo(7), to: today() });
    const [department, setDepartment] = useState('');
    const [missionType, setMissionType] = useState('');
    const [missionId, setMissionId] = useState('');
    const [includeAwards, setIncludeAwards] = useState(false);
    const [strike, setStrike] = useState(false);
    const [preview, setPreview] = useState<VoidPreview | null>(null);
    const [previewErr, setPreviewErr] = useState<string | null>(null);
    const [loading, setLoading] = useState(false);
    const [typed, setTyped] = useState('');
    const [reason, setReason] = useState('');
    const [jobId, setJobId] = useState<string | null>(null);

    useEffect(() => {
        if (!open) return;
        const from = typeof initial?.from === 'string' ? initial.from : daysAgo(7);
        const to = typeof initial?.to === 'string' ? initial.to : today();
        setRange({ from, to });
        setDepartment(initial?.department ?? '');
        setMissionType(initial?.missionType ?? '');
        setMissionId(initial?.missionId ?? '');
        setIncludeAwards(false);
        setStrike(false);
        setPreview(null);
        setPreviewErr(null);
        setTyped('');
        setReason('');
        setJobId(null);
    }, [open, initial]);

    const filter = (): BulkVoidFilter => ({
        ...(initial ?? {}),
        from: typeof initial?.from === 'number' ? initial.from : range.from,
        to: typeof initial?.to === 'number' ? initial.to : range.to,
        department: department || undefined,
        missionType: missionType || undefined,
        missionId: missionId.trim() || undefined,
        includeAwards,
    });

    const doPreview = async () => {
        setLoading(true);
        setPreviewErr(null);
        const res = await request<VoidPreview>('admin:previewBulkVoid', { filter: filter() });
        setLoading(false);
        if (res.ok && res.data) setPreview(res.data);
        else setPreviewErr(res.error ?? 'err.internal');
    };

    const start = async () => {
        if (!preview?.previewToken) return;
        const res = await run<{ jobId: string; rows: number }>('server:admin:bulkVoid', {
            filter: filter(),
            kind: strike ? 'strike' : 'correction',
            reason: reason.trim(),
            confirm: typed.trim(),
            previewToken: preview.previewToken,
        });
        if (res.ok && res.data) {
            setJobId(res.data.jobId);
            onDone?.(res.data.jobId);
        }
    };

    const columns: TableColumn<VoidPreviewRow>[] = [
        { key: 'when', header: t('ui.admin_officers.col.when'), width: 110, render: r => formatDateTime(r.createdAt) },
        {
            key: 'mission',
            header: t('ui.admin_officers.col.mission'),
            render: r => (
                <span>
                    {r.missionLabel}
                    {r.archived ? (
                        <Badge size="sm" variant="outline">
                            {t('ui.admin_officers.archived')}
                        </Badge>
                    ) : null}
                </span>
            ),
        },
        { key: 'cid', header: t('ui.admin_officers.col.officer'), width: 100, render: r => r.citizenid },
        { key: 'points', header: t('ui.admin_officers.col.points'), numeric: true, width: 70, render: r => r.points },
    ];

    const fixedOfficer = !!initial?.citizenid;
    const word = preview?.confirmWord ?? '';
    const ready =
        !!preview?.previewToken &&
        !!reason.trim() &&
        typed.trim().toUpperCase() === word.toUpperCase() &&
        !jobId &&
        (preview?.total ?? 0) > 0;

    return (
        <Dialog
            open={open}
            onClose={busy ? () => undefined : onClose}
            size="lg"
            title={name ? t('ui.admin_officers.bulk.title_for', { name }) : t('ui.admin_officers.bulk.title')}
            description={t('ui.admin_officers.bulk.desc')}
            footer={
                <>
                    <Button variant="ghost" onClick={onClose} disabled={busy}>
                        {jobId ? t('common.close') : t('common.cancel')}
                    </Button>
                    {!jobId ? (
                        <Button variant="secondary" icon="search" loading={loading} onClick={() => void doPreview()}>
                            {t('ui.admin_officers.bulk.preview')}
                        </Button>
                    ) : null}
                    {!jobId ? (
                        <Button
                            variant="danger"
                            icon="xCircle"
                            loading={busy}
                            disabled={!ready}
                            onClick={() => void start()}
                        >
                            {t('ui.admin_officers.bulk.start')}
                        </Button>
                    ) : null}
                </>
            }
        >
            <div className="admin-bulk">
                <div className="admin-bulk__filters">
                    {typeof initial?.from !== 'number' && !initial?.allTime ? (
                        <DateRangeField
                            value={range}
                            onChange={r => {
                                setRange(r);
                                setPreview(null);
                            }}
                        />
                    ) : null}
                    {!fixedOfficer && !initial?.department ? (
                        <Field label={t('ui.admin_officers.bulk.department')}>
                            <Select
                                value={department}
                                onChange={v => {
                                    setDepartment(v);
                                    setPreview(null);
                                }}
                                placeholder={t('ui.admin_officers.bulk.any')}
                                options={(session.config?.departments ?? []).map(d => ({
                                    value: d.key,
                                    label: d.label,
                                }))}
                            />
                        </Field>
                    ) : null}
                    <Field label={t('ui.admin_officers.bulk.type')}>
                        <Select
                            value={missionType}
                            onChange={v => {
                                setMissionType(v);
                                setPreview(null);
                            }}
                            placeholder={t('ui.admin_officers.bulk.any')}
                            options={(session.config?.missionTypes ?? []).map(m => ({ value: m.key, label: m.label }))}
                        />
                    </Field>
                    <Field label={t('ui.admin_officers.bulk.mission')}>
                        <TextInput
                            value={missionId}
                            onChange={v => {
                                setMissionId(v);
                                setPreview(null);
                            }}
                            maxLength={40}
                            placeholder="beat_patrol"
                        />
                    </Field>
                    <Checkbox
                        checked={includeAwards}
                        onChange={v => {
                            setIncludeAwards(v);
                            setPreview(null);
                        }}
                        label={t('ui.admin_officers.bulk.include_awards')}
                    />
                    <Toggle
                        checked={strike}
                        onChange={setStrike}
                        label={t('ui.admin_officers.bulk.strike')}
                        description={t('ui.admin_officers.bulk.strike_hint')}
                    />
                </div>
                {previewErr ? <ErrorState compact error={previewErr} onRetry={() => void doPreview()} /> : null}
                {preview ? (
                    <>
                        <PreviewTable
                            columns={columns}
                            rows={preview.rows}
                            total={preview.total}
                            rowKey={r => r.key}
                            note={
                                <>
                                    {t('ui.admin_officers.bulk.effect', {
                                        officers: formatNumber(preview.officers.length),
                                        points: formatNumber(preview.points),
                                        held: formatMoney(preview.held),
                                        archived: formatNumber(preview.archived),
                                    })}
                                    {preview.excluded ? (
                                        <div className="admin-bulk__note">
                                            {t('ui.admin_officers.bulk.excluded', { n: preview.excluded })}
                                        </div>
                                    ) : null}
                                    {preview.tooMany ? (
                                        <div className="admin-bulk__warn">
                                            {t('ui.admin_officers.bulk.too_many', {
                                                max: formatNumber(preview.max ?? 0),
                                            })}
                                        </div>
                                    ) : null}
                                </>
                            }
                        />
                        {preview.total > 0 && preview.previewToken && !jobId ? (
                            <div className="admin-bulk__confirm">
                                <Field label={t('ui.admin_officers.type_word', { word })} required>
                                    <TextInput value={typed} onChange={setTyped} placeholder={word} />
                                </Field>
                                <Field label={t('common.reason')} required>
                                    <Textarea value={reason} onChange={setReason} maxLength={255} rows={2} />
                                </Field>
                            </div>
                        ) : null}
                    </>
                ) : null}
                {jobId ? <JobProgress jobId={jobId} /> : null}
            </div>
        </Dialog>
    );
}
