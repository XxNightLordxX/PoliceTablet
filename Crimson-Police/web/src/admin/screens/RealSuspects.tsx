// Admin UI · Real suspects (screen key 'admin_rs', step V18): the live-crime and volunteer cases for staff. Shown

import { useState } from 'react';
import {
    Badge,
    Button,
    Card,
    Dialog,
    EmptyState,
    ErrorState,
    Field,
    Icon,
    IconButton,
    KeyValue,
    LoadingBlock,
    NumberInput,
    Row,
    Screen,
    SearchInput,
    SegmentedControl,
    Table,
    Tabs,
    TextInput,
    Textarea,
    type BadgeTone,
    type TableColumn,
} from '../../shared/components';
import { asArray } from '../../shared/data';
import { formatDateTime } from '../../shared/format';
import { useAction, useRequest, type UseRequestResult } from '../../shared/hooks';
import { hasKey, t } from '../../shared/i18n';
import type {
    RsAdminRow,
    RsCaseData,
    RsCaseLine,
    RsCasesData,
    RsLedgerLine,
    RsLine,
    RsPairLine,
    RsPairsData,
    RsSuspect,
    RsTool,
} from '../../types/admin_rs';
import { ReasonChips } from '../components/ReasonChips';
import {
    RS_DAYS_MAX,
    RS_REASON_MAX,
    filterCases,
    ledgerSuspect,
    personText,
    rowsFor,
    sinceOpen,
    toolRequest,
    validCid,
    type RsCaseFilter,
    type RsToolForm,
} from '../components/realSuspects';
import './RealSuspects.css';

type Tab = 'cases' | 'pairs';

const STATE_TONE: Record<string, BadgeTone> = {
    free: 'warning',
    cuffed: 'primary',
    detained: 'success',
    booked: 'success',
    lost: 'neutral',
    left: 'neutral',
    void: 'neutral',
};

const stateText = (s: string | null | undefined) => (s ? (hasKey(`opp.state.${s}`) ? t(`opp.state.${s}`) : s) : '-');
const kindText = (k: string) => (hasKey(`rs.ui.kind.${k}`) ? t(`rs.ui.kind.${k}`) : k);
const when = (ts: number | null | undefined) => (ts ? formatDateTime(ts) : '-');

// ============================================================================
//                                  THE TOOLS
// ============================================================================

const EMPTY_FORM: RsToolForm = { tool: 'block', officer: '', suspect: '', citizenid: '', days: 7, reason: '' };

function ToolDialog({
    start,
    onClose,
    onDone,
}: {
    start: Partial<RsToolForm> | null;
    onClose: () => void;
    onDone: () => void;
}) {
    const [form, setForm] = useState<RsToolForm>({ ...EMPTY_FORM, ...(start ?? {}) });
    const [error, setError] = useState<string | null>(null);
    const { run, busy } = useAction();
    const set = (patch: Partial<RsToolForm>) => {
        setError(null);
        setForm(f => ({ ...f, ...patch }));
    };
    const submit = async () => {
        const req = toolRequest(form);
        if (!req.ok) {
            setError(req.error);
            return;
        }
        const res = await run(req.action, req.payload, { success: `rs.ui.tool.done.${form.tool}` });
        if (res.ok) {
            onDone();
            onClose();
        }
    };
    return (
        <Dialog
            open={start !== null}
            onClose={onClose}
            title={t('rs.ui.tool.title')}
            description={t(`rs.ui.tool.desc.${form.tool}`)}
            footer={
                <>
                    <Button variant="secondary" onClick={onClose} disabled={busy}>
                        {t('common.cancel')}
                    </Button>
                    <Button variant="danger" icon="lock" loading={busy} onClick={() => void submit()}>
                        {t(`rs.ui.tool.do.${form.tool}`)}
                    </Button>
                </>
            }
        >
            <div className="rs-tool">
                <SegmentedControl<RsTool>
                    aria-label={t('rs.ui.tool.title')}
                    items={[
                        { key: 'block', label: t('rs.ui.tool.name.block') },
                        { key: 'exclude', label: t('rs.ui.tool.name.exclude') },
                        { key: 'suspend', label: t('rs.ui.tool.name.suspend') },
                    ]}
                    value={form.tool}
                    onChange={tool => set({ tool })}
                />
                {form.tool === 'block' ? (
                    <>
                        <Field label={t('rs.ui.officer_cid')} required>
                            <TextInput value={form.officer} onChange={officer => set({ officer })} maxLength={50} />
                        </Field>
                        <Field label={t('rs.ui.suspect_cid')} required>
                            <TextInput value={form.suspect} onChange={suspect => set({ suspect })} maxLength={50} />
                        </Field>
                    </>
                ) : (
                    <Field label={form.tool === 'exclude' ? t('rs.ui.suspect_cid') : t('rs.ui.officer_cid')} required>
                        <TextInput value={form.citizenid} onChange={citizenid => set({ citizenid })} maxLength={50} />
                    </Field>
                )}
                <Field label={t('rs.ui.tool.days')} hint={t('rs.ui.tool.days_hint')} required>
                    <NumberInput value={form.days} onChange={days => set({ days })} min={1} max={RS_DAYS_MAX} integer />
                </Field>
                <Field label={t('rs.ui.tool.reason')} required>
                    <Textarea
                        value={form.reason}
                        onChange={reason => set({ reason })}
                        maxLength={RS_REASON_MAX}
                        rows={2}
                    />
                    <ReasonChips value={form.reason} onChange={reason => set({ reason })} disabled={busy} />
                </Field>
                <p className="rs-tool__note">{t('rs.ui.tool.no_lift')}</p>
                {error ? (
                    <p className="rs-tool__error" role="alert">
                        {t(error)}
                    </p>
                ) : null}
            </div>
        </Dialog>
    );
}

// ============================================================================
//                                   ONE CASE
// ============================================================================

function SuspectsTable({ suspects, onTool }: { suspects: RsSuspect[]; onTool: (f: Partial<RsToolForm>) => void }) {
    const columns: TableColumn<RsSuspect>[] = [
        { key: 'label', header: t('rs.ui.col.label'), width: 60, render: s => <strong>{s.label}</strong> },
        { key: 'who', header: t('rs.ui.col.suspect'), render: s => personText(s) },
        {
            key: 'state',
            header: t('rs.ui.col.state'),
            render: s => (
                <Badge tone={STATE_TONE[s.state] ?? 'neutral'} size="sm">
                    {stateText(s.outcome || s.state)}
                </Badge>
            ),
        },
        {
            key: 'times',
            header: t('rs.ui.col.times'),
            render: s =>
                t('rs.ui.times', {
                    contact: sinceOpen(s.contactS),
                    cuffed: sinceOpen(s.cuffedS),
                    detained: sinceOpen(s.detainedS),
                    booked: sinceOpen(s.bookedS),
                }),
        },
        {
            key: 'signs',
            header: t('rs.ui.col.signs'),
            render: s => (
                <span className="rs-signs">
                    {s.everArmed ? <Badge size="sm">{t('rs.ui.sign.armed')}</Badge> : null}
                    {s.afk ? (
                        <Badge size="sm" tone="warning">
                            {t('rs.ui.sign.afk')}
                        </Badge>
                    ) : null}
                    {s.down ? (
                        <Badge size="sm" tone="danger">
                            {t('rs.ui.sign.down')}
                        </Badge>
                    ) : null}
                    {s.byLeave ? (
                        <Badge size="sm" tone="neutral">
                            {t('rs.ui.sign.left')}
                        </Badge>
                    ) : null}
                    {!s.online ? (
                        <Badge size="sm" tone="neutral">
                            {t('rs.ui.sign.offline')}
                        </Badge>
                    ) : null}
                    {s.jailTime ? <Badge size="sm">{t('rs.ui.sign.jail', { months: s.jailTime })}</Badge> : null}
                </span>
            ),
        },
        {
            key: 'tools',
            header: '',
            align: 'right',
            render: s => (
                <IconButton
                    icon="lock"
                    size="sm"
                    variant="ghost"
                    label={t('rs.ui.tool.name.exclude')}
                    onClick={() => onTool({ tool: 'exclude', citizenid: s.citizenid })}
                />
            ),
        },
    ];
    return <Table dense columns={columns} rows={suspects} rowKey={s => s.citizenid} empty={t('rs.ui.none')} />;
}

function LinesList({ lines, empty }: { lines: RsLine[]; empty: string }) {
    if (lines.length === 0) return <EmptyState compact title={empty} />;
    return (
        <ol className="rs-lines">
            {lines.map((l, i) => (
                <li
                    key={`${l.t}-${i}`}
                    className={
                        l.flag
                            ? 'rs-lines__item rs-lines__item--flag'
                            : l.note
                              ? 'rs-lines__item rs-lines__item--note'
                              : 'rs-lines__item'
                    }
                >
                    <span className="rs-lines__time">{when(l.t)}</span>
                    {l.flag ? (
                        <Badge size="sm" tone="danger">
                            {t('rs.ui.flag')}
                        </Badge>
                    ) : l.note ? (
                        <Badge size="sm" tone="warning">
                            {t('rs.ui.note')}
                        </Badge>
                    ) : null}
                    <span className="rs-lines__text">{l.text}</span>
                </li>
            ))}
        </ol>
    );
}

function LedgerTable({ ledger, suspects }: { ledger: RsLedgerLine[]; suspects: RsSuspect[] }) {
    const columns: TableColumn<RsLedgerLine>[] = [
        { key: 't', header: t('rs.ui.col.time'), render: l => when(l.t) },
        {
            key: 'dir',
            header: t('rs.ui.col.dir'),
            render: l => (l.dir === 'officer' ? t('rs.ui.dir.officer') : t('rs.ui.dir.suspect')),
        },
        { key: 'officer', header: t('rs.ui.col.officer'), render: l => personText(l.officer) },
        {
            key: 'suspect',
            header: t('rs.ui.col.suspect'),
            render: l => {
                const s = ledgerSuspect(l, suspects);
                return s ? `${s.label}: ${personText(s)}` : (l.label ?? '-');
            },
        },
        { key: 'weapon', header: t('rs.ui.col.weapon'), render: l => (l.weapon ? `#${l.weapon}` : '-') },
        { key: 'n', header: t('rs.ui.col.hits'), numeric: true, render: l => l.n },
        {
            key: 'rules',
            header: t('rs.ui.col.rules'),
            render: l => (
                <span className="rs-signs">
                    {l.willKill ? (
                        <Badge size="sm" tone="danger">
                            {t('rs.ui.sign.lethal')}
                        </Badge>
                    ) : null}
                    {l.state ? <Badge size="sm">{stateText(l.state)}</Badge> : null}
                    {asArray(l.rules).map(r => (
                        <Badge key={r} size="sm" tone="danger">
                            {r}
                        </Badge>
                    ))}
                </span>
            ),
        },
    ];
    return (
        <Table dense columns={columns} rows={ledger} rowKey={(l, i) => `${l.t}-${i}`} empty={t('rs.ui.ledger_none')} />
    );
}

function CaseDrawer({
    runId,
    onClose,
    onTool,
}: {
    runId: string | null;
    onClose: () => void;
    onTool: (f: Partial<RsToolForm>) => void;
}) {
    const { data, loading, error, refetch } = useRequest<RsCaseData>(
        'admin:getRsCase',
        { runUuid: runId },
        { skip: !runId },
    );
    const suspects = asArray(data?.suspects);
    const officers = asArray(data?.officers);
    return (
        <Dialog
            open={runId !== null}
            onClose={onClose}
            placement="right"
            size="lg"
            title={t('rs.ui.case_title')}
            description={runId ?? undefined}
        >
            {loading && !data ? (
                <LoadingBlock />
            ) : error && !data ? (
                <ErrorState error={error} onRetry={() => void refetch()} />
            ) : data ? (
                <div className="rs-case">
                    <div className="rs-case__facts">
                        <KeyValue label={t('rs.ui.col.kind')}>{kindText(data.kind)}</KeyValue>
                        <KeyValue label={t('rs.ui.col.opened')}>{when(data.openedAt)}</KeyValue>
                        <KeyValue label={t('rs.ui.col.closed')}>
                            {data.open ? t('rs.ui.still_open') : when(data.closedAt)}
                        </KeyValue>
                        <KeyValue label={t('rs.ui.crime')}>
                            {data.crimeEnded ? t('rs.ui.crime_ended') : t('rs.ui.crime_running')}
                        </KeyValue>
                    </div>
                    <Card title={t('rs.ui.suspects')} icon="users" padding="none">
                        <SuspectsTable suspects={suspects} onTool={onTool} />
                    </Card>
                    <Card title={t('rs.ui.officers')} icon="shield" padding="sm">
                        <ul className="rs-officers">
                            {officers.map(o => (
                                <li key={o.citizenid}>
                                    <span>
                                        {personText(o)}
                                        {o.callsign ? ` · ${o.callsign}` : ''}
                                    </span>
                                    <Button
                                        size="sm"
                                        variant="ghost"
                                        icon="lock"
                                        onClick={() => onTool({ tool: 'suspend', citizenid: o.citizenid })}
                                    >
                                        {t('rs.ui.tool.name.suspend')}
                                    </Button>
                                    {suspects.length > 0 ? (
                                        <Button
                                            size="sm"
                                            variant="ghost"
                                            icon="x"
                                            onClick={() =>
                                                onTool({
                                                    tool: 'block',
                                                    officer: o.citizenid,
                                                    suspect: suspects[0].citizenid,
                                                })
                                            }
                                        >
                                            {t('rs.ui.tool.name.block')}
                                        </Button>
                                    ) : null}
                                </li>
                            ))}
                        </ul>
                    </Card>
                    <Card title={t('rs.ui.flag_lines')} subtitle={t('rs.ui.flag_lines_sub')} icon="flag" padding="sm">
                        <LinesList lines={asArray(data.flagLines)} empty={t('rs.ui.flags_none')} />
                    </Card>
                    <Card title={t('rs.ui.timeline')} icon="clock" padding="sm">
                        <LinesList lines={asArray(data.lines)} empty={t('rs.ui.none')} />
                    </Card>
                    <Card title={t('rs.ui.ledger')} subtitle={t('rs.ui.ledger_sub')} icon="target" padding="none">
                        <LedgerTable ledger={asArray(data.ledger)} suspects={suspects} />
                    </Card>
                </div>
            ) : null}
        </Dialog>
    );
}

// ============================================================================
//                                   THE TABS
// ============================================================================

function CasesTab({
    req: { data, loading, error, refetch },
    onOpen,
}: {
    req: UseRequestResult<RsCasesData>;
    onOpen: (runId: string) => void;
}) {
    const [filter, setFilter] = useState<RsCaseFilter>('all');
    const rows = filterCases(asArray(data?.cases), filter);
    const columns: TableColumn<RsCaseLine>[] = [
        { key: 'opened', header: t('rs.ui.col.opened'), render: c => when(c.openedAt) },
        { key: 'kind', header: t('rs.ui.col.kind'), render: c => kindText(c.kind) },
        {
            key: 'state',
            header: t('rs.ui.col.state'),
            render: c =>
                c.open ? (
                    <Badge tone="danger" dot size="sm">
                        {t('rs.ui.open')}
                    </Badge>
                ) : (
                    <Badge size="sm">{t('rs.ui.closed')}</Badge>
                ),
        },
        {
            key: 'suspects',
            header: t('rs.ui.col.suspects'),
            render: c => t('rs.ui.counts', { n: c.suspects, detained: c.detained, booked: c.booked }),
        },
        {
            key: 'officers',
            header: t('rs.ui.col.officers'),
            render: c =>
                asArray(c.officers)
                    .map(o => o.name || o.citizenid)
                    .join(', ') || '-',
        },
        {
            key: 'flags',
            header: t('rs.ui.col.flags'),
            render: c => (
                <span className="rs-signs">
                    {c.flags > 0 ? (
                        <Badge size="sm" tone="danger">
                            {t('rs.ui.n_flags', { n: c.flags })}
                        </Badge>
                    ) : null}
                    {c.notes > 0 ? (
                        <Badge size="sm" tone="warning">
                            {t('rs.ui.n_notes', { n: c.notes })}
                        </Badge>
                    ) : null}
                    {c.own ? <Badge size="sm">{t('rs.ui.own')}</Badge> : null}
                </span>
            ),
        },
    ];
    return (
        <Card
            title={t('rs.ui.cases')}
            subtitle={t('rs.ui.cases_sub')}
            icon="activity"
            padding="none"
            actions={
                <Row>
                    <SegmentedControl<RsCaseFilter>
                        size="sm"
                        aria-label={t('rs.ui.cases')}
                        items={[
                            { key: 'all', label: t('rs.ui.filter.all') },
                            { key: 'open', label: t('rs.ui.filter.open') },
                            { key: 'flagged', label: t('rs.ui.filter.flagged') },
                        ]}
                        value={filter}
                        onChange={setFilter}
                    />
                    <IconButton
                        icon="refresh"
                        size="sm"
                        variant="secondary"
                        label={t('rs.ui.refresh')}
                        loading={loading && !!data}
                        onClick={() => void refetch()}
                    />
                </Row>
            }
        >
            {loading && !data ? (
                <LoadingBlock />
            ) : error && !data ? (
                <ErrorState error={error} onRetry={() => void refetch()} />
            ) : (
                <Table
                    columns={columns}
                    rows={rows}
                    rowKey={c => c.runId}
                    onRowClick={c => {
                        if (!c.own) onOpen(c.runId);
                    }}
                    rowClassName={c => (c.own ? 'is-muted' : undefined)}
                    empty={t('rs.ui.cases_none')}
                />
            )}
        </Card>
    );
}

const ADMIN_KIND_TONE: Record<RsAdminRow['kind'], BadgeTone> = {
    block: 'danger',
    exclude: 'warning',
    suspend: 'primary',
};

function PairsTab({ onTool, version }: { onTool: (f: Partial<RsToolForm>) => void; version: number }) {
    const [query, setQuery] = useState('');
    const cid = query.trim();
    const args = validCid(cid) ? { citizenid: cid, v: version } : { v: version };
    const { data, loading, error, refetch } = useRequest<RsPairsData>('admin:getRsPairs', args);
    const pairs = asArray(data?.pairs);
    const admin = asArray(data?.admin);
    const pairCols: TableColumn<RsPairLine>[] = [
        { key: 'officer', header: t('rs.ui.col.officer'), render: p => p.officer },
        { key: 'suspect', header: t('rs.ui.col.suspect'), render: p => p.suspect },
        { key: 'cases', header: t('rs.ui.col.cases'), numeric: true, render: p => p.cases },
        { key: 'scored', header: t('rs.ui.col.scored'), numeric: true, render: p => p.scored },
        { key: 'last', header: t('rs.ui.col.last'), render: p => when(p.lastAt) },
        { key: 'outcome', header: t('rs.ui.col.outcome'), render: p => stateText(p.lastOutcome) },
        { key: 'kinds', header: t('rs.ui.col.kind'), render: p => asArray(p.kinds).map(kindText).join(', ') },
        {
            key: 'block',
            header: '',
            align: 'right',
            render: p => (
                <Button
                    size="sm"
                    variant="ghost"
                    icon="x"
                    onClick={() => onTool({ tool: 'block', officer: p.officer, suspect: p.suspect })}
                >
                    {t('rs.ui.tool.name.block')}
                </Button>
            ),
        },
    ];
    const adminCols: TableColumn<RsAdminRow>[] = [
        {
            key: 'kind',
            header: t('rs.ui.col.kind'),
            render: r => (
                <Badge size="sm" tone={ADMIN_KIND_TONE[r.kind] ?? 'neutral'}>
                    {t(`rs.ui.tool.name.${r.kind}`)}
                </Badge>
            ),
        },
        { key: 'officer', header: t('rs.ui.col.officer'), render: r => r.officer || '-' },
        { key: 'suspect', header: t('rs.ui.col.suspect'), render: r => r.suspect || '-' },
        { key: 'until', header: t('rs.ui.col.until'), render: r => when(r.untilAt) },
    ];
    const mine = cid && data?.citizenid === cid ? rowsFor(admin, cid) : null;
    return (
        <>
            <Card
                title={t('rs.ui.pairs')}
                subtitle={data?.from ? t('rs.ui.pairs_from', { from: when(data.from) }) : t('rs.ui.pairs_sub')}
                icon="users"
                padding="none"
                actions={
                    <Row>
                        <SearchInput
                            value={query}
                            onChange={setQuery}
                            placeholder={t('rs.ui.search_cid')}
                            aria-label={t('rs.ui.search_cid')}
                        />
                        <Button size="sm" icon="lock" onClick={() => onTool({})}>
                            {t('rs.ui.tool.new')}
                        </Button>
                    </Row>
                }
            >
                {mine ? (
                    <div className="rs-who">
                        <Icon name="user" size={14} />
                        <span>
                            {data?.excludedUntil
                                ? t('rs.ui.excluded_until', { until: when(data.excludedUntil) })
                                : t('rs.ui.not_excluded')}
                        </span>
                        <span>
                            {data?.suspendedUntil
                                ? t('rs.ui.suspended_until', { until: when(data.suspendedUntil) })
                                : t('rs.ui.not_suspended')}
                        </span>
                    </div>
                ) : null}
                {loading && !data ? (
                    <LoadingBlock />
                ) : error && !data ? (
                    <ErrorState error={error} onRetry={() => void refetch()} />
                ) : (
                    <Table
                        dense
                        columns={pairCols}
                        rows={pairs}
                        rowKey={p => `${p.officer}|${p.suspect}`}
                        empty={t('rs.ui.pairs_none')}
                    />
                )}
            </Card>
            <Card title={t('rs.ui.admin_rows')} subtitle={t('rs.ui.admin_rows_sub')} icon="lock" padding="none">
                <Table
                    dense
                    columns={adminCols}
                    rows={mine ?? admin}
                    rowKey={r => `${r.kind}|${r.officer ?? ''}|${r.suspect ?? ''}`}
                    empty={t('rs.ui.admin_rows_none')}
                />
            </Card>
        </>
    );
}

export default function RealSuspects() {
    const [tab, setTab] = useState<Tab>('cases');
    const [openRun, setOpenRun] = useState<string | null>(null);
    const [tool, setTool] = useState<Partial<RsToolForm> | null>(null);
    const [version, setVersion] = useState(0);
    const cases = useRequest<RsCasesData>('admin:getRsCases', {});
    const data = cases.data;
    return (
        <Screen title={t('ui.screen.admin_rs')} subtitle={t('rs.ui.subtitle')}>
            {data && !data.enabled ? (
                <div className="rs-banner" role="status">
                    <Icon name="info" size={16} />
                    <span>{t('rs.ui.off_banner')}</span>
                </div>
            ) : null}
            <Tabs<Tab>
                aria-label={t('ui.screen.admin_rs')}
                items={[
                    { key: 'cases', label: t('rs.ui.cases'), icon: 'activity' },
                    { key: 'pairs', label: t('rs.ui.pairs_tab'), icon: 'users' },
                ]}
                value={tab}
                onChange={setTab}
            />
            {tab === 'cases' ? (
                <CasesTab req={cases} onOpen={setOpenRun} />
            ) : (
                <PairsTab onTool={setTool} version={version} />
            )}
            <CaseDrawer runId={openRun} onClose={() => setOpenRun(null)} onTool={setTool} />
            {tool !== null ? (
                <ToolDialog start={tool} onClose={() => setTool(null)} onDone={() => setVersion(v => v + 1)} />
            ) : null}
        </Screen>
    );
}
