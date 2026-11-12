// The one restrictions list as a panel (FM5, FIN4): every restriction running now, each with its kind, who it names,

// The one restrictions list as a panel (FM5, FIN4): every restriction running now, each with its kind, who it names,
// until when, who set it and why, a kind filter, and Extend / Lift with a reason through server:restriction (each
// kind keeps its own rules on the server, modules/supervisor/restrictions.lua). Used by the Admin UI's Restrictions
// screen (scope 'admin': admin:getRestrictions) and the Supervisor UI's Department -> Restrictions tab (scope 'sup':
// sup:getRestrictions, his department, Lift on his own mission bans). The tools that set a restriction stay where
// they were (Officers -> Suspend, the supervisor's officer dialog for a mission ban, Real suspects -> Pairs and
// blocks).

import { useState } from 'react';
import {
    Badge,
    Button,
    Card,
    ConfirmDialog,
    ErrorState,
    Field,
    LoadingBlock,
    NumberInput,
    Row,
    SegmentedControl,
    Table,
    type BadgeTone,
    type TableColumn,
} from '../../shared/components';
import { asArray } from '../../shared/data';
import { formatDateTime } from '../../shared/format';
import { useAction, useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import type { RestrictionKind, RestrictionKindInfo, RestrictionRow, RestrictionsData } from '../../types/restrictions';
import {
    RESTRICTION_ACTION,
    RESTRICTION_KINDS,
    extendHours,
    restrictionPayload,
    restrictionsRead,
    rowCanLift,
    rowsOfKind,
} from './restrictions';

const REASON_MAX = 255;

const KIND_TONE: Record<RestrictionKind, BadgeTone> = {
    suspension: 'danger',
    missionBan: 'warning',
    pairBlock: 'danger',
    exclusion: 'warning',
    rsSuspension: 'primary',
    volunteerBlock: 'neutral',
};

function who(cid: string, name?: string | null): string {
    return name ? `${name} (${cid})` : cid;
}

function setBy(r: RestrictionRow): string {
    if (r.auto) return t('restrict.ui.by_strikes');
    if (r.byName && r.by) return who(r.by, r.byName);
    return r.byName || r.by || '-';
}

// scope 'admin': every kind this admin may see, Extend and Lift by the kind's rules; 'sup': the supervisor's
// department (sup:getRestrictions), Lift only on the rows that say so (his own mission bans).
export function RestrictionsPanel({ scope }: { scope: 'admin' | 'sup' }) {
    const { data, loading, error, refetch } = useRequest<RestrictionsData>(restrictionsRead(scope), {});
    const [kind, setKind] = useState<RestrictionKind | 'all'>('all');
    const [lifting, setLifting] = useState<RestrictionRow | null>(null);
    const [extending, setExtending] = useState<RestrictionRow | null>(null);
    const [hours, setHours] = useState<number | null>(24);
    const { run, busy } = useAction();
    const kinds = asArray(data?.kinds);
    const info = (k: RestrictionKind): RestrictionKindInfo | undefined => kinds.find(x => x.key === k);
    const rows = rowsOfKind(asArray(data?.rows), kind);

    const doLift = async (reason: string) => {
        if (!lifting) return;
        const res = await run(RESTRICTION_ACTION, restrictionPayload('lift', lifting, reason), {
            success: 'restrict.ui.lift_done',
        });
        if (res.ok) {
            setLifting(null);
            void refetch();
        }
    };
    const extInfo = extending ? info(extending.kind) : undefined;
    const extHours = extInfo ? extendHours(hours, extInfo.maxHours) : null;
    const doExtend = async (reason: string) => {
        if (!extending || extHours === null) return;
        const res = await run(RESTRICTION_ACTION, restrictionPayload('extend', extending, reason, extHours), {
            success: 'restrict.ui.extend_done',
        });
        if (res.ok) {
            setExtending(null);
            void refetch();
        }
    };

    const columns: TableColumn<RestrictionRow>[] = [
        {
            key: 'kind',
            header: t('restrict.ui.col.kind'),
            render: r => (
                <Badge size="sm" tone={KIND_TONE[r.kind] ?? 'neutral'}>
                    {t(`restrict.kind.${r.kind}`)}
                </Badge>
            ),
        },
        {
            key: 'who',
            header: t('restrict.ui.col.who'),
            render: r =>
                r.other ? `${who(r.citizenid, r.name)} / ${who(r.other, r.otherName)}` : who(r.citizenid, r.name),
        },
        { key: 'until', header: t('restrict.ui.col.until'), render: r => formatDateTime(r.untilAt) },
        { key: 'by', header: t('restrict.ui.col.by'), render: setBy },
        { key: 'reason', header: t('restrict.ui.col.reason'), render: r => r.reason || '-' },
        {
            key: 'actions',
            header: '',
            align: 'right',
            render: r => (
                <Row>
                    {info(r.kind)?.canExtend ? (
                        <Button size="sm" variant="ghost" icon="clock" onClick={() => setExtending(r)}>
                            {t('restrict.ui.extend')}
                        </Button>
                    ) : null}
                    {rowCanLift(r, info(r.kind), scope) ? (
                        <Button size="sm" variant="ghost" icon="undo" onClick={() => setLifting(r)}>
                            {t('restrict.ui.lift')}
                        </Button>
                    ) : null}
                </Row>
            ),
        },
    ];
    const filterItems = [
        { key: 'all' as const, label: t('restrict.ui.all') },
        ...RESTRICTION_KINDS.filter(k => info(k)).map(k => ({ key: k, label: t(`restrict.kind.${k}`) })),
    ];

    return (
        <>
            <Card
                title={t(scope === 'sup' ? 'restrict.ui.sup_title' : 'restrict.ui.title')}
                subtitle={scope === 'sup' ? t('restrict.ui.sup_hint') : undefined}
                icon="lock"
                padding="none"
                actions={
                    <Row>
                        <SegmentedControl
                            size="sm"
                            items={filterItems}
                            value={kind}
                            onChange={setKind}
                            aria-label={t('restrict.ui.col.kind')}
                        />
                        <Button size="sm" variant="ghost" icon="refresh" onClick={() => void refetch()}>
                            {t('restrict.ui.refresh')}
                        </Button>
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
                        rowKey={r => `${r.kind}|${r.citizenid}|${r.other ?? ''}`}
                        empty={t('restrict.ui.none')}
                    />
                )}
            </Card>
            <ConfirmDialog
                open={lifting !== null}
                title={t('restrict.ui.lift_title')}
                message={
                    lifting
                        ? t('restrict.ui.lift_message', {
                              what: t(`restrict.kind.${lifting.kind}`),
                              who: who(lifting.citizenid, lifting.name),
                              until: formatDateTime(lifting.untilAt),
                          })
                        : null
                }
                confirmLabel={t('restrict.ui.lift')}
                tone="danger"
                reason={{ required: true, maxLength: REASON_MAX }}
                onConfirm={doLift}
                onCancel={() => setLifting(null)}
                busy={busy}
            />
            <ConfirmDialog
                open={extending !== null}
                title={t('restrict.ui.extend_title')}
                message={
                    extending
                        ? t('restrict.ui.extend_message', {
                              what: t(`restrict.kind.${extending.kind}`),
                              who: who(extending.citizenid, extending.name),
                              until: formatDateTime(extending.untilAt),
                          })
                        : null
                }
                effect={
                    <Field label={t('restrict.ui.hours')}>
                        <NumberInput value={hours} onChange={setHours} min={1} max={extInfo?.maxHours ?? 24} />
                    </Field>
                }
                confirmLabel={t('restrict.ui.extend')}
                reason={{ required: true, maxLength: REASON_MAX }}
                onConfirm={doExtend}
                onCancel={() => setExtending(null)}
                busy={busy}
            />
        </>
    );
}
