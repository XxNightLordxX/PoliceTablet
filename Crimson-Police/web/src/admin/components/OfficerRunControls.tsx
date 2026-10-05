// Slot: Officers → officer detail → Today & cooldowns: cooldowns (with Clear), today's counts against every cap (with
// Allow more today), cash today, the Weekly Boss attempt (with Another boss attempt), free abandons (with Treat as a
// normal abandon) and the Mission Board as the officer sees it (modules/livectl/server.lua).

import { useState } from 'react';
import {
    Badge,
    Button,
    Card,
    ConfirmDialog,
    Countdown,
    EmptyState,
    ErrorState,
    Field,
    LoadingBlock,
    Money,
    NumberInput,
    Row,
} from '../../shared/components';
import { asArray } from '../../shared/data';
import { formatDateTime } from '../../shared/format';
import { useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { useCan } from '../../shared/session';
import type { OfficerSlotProps } from '../../types/admin_control';
import type { AdminFreeAbandon, AdminOfficerRunState } from '../../types/admin_live';
import { useAdminAction } from './kit';
import '../screens/Live.css';

type Pending =
    | { kind: 'clear'; scope: 'all' | 'type' | 'mission'; key?: string; label: string }
    | { kind: 'extra' }
    | { kind: 'boss' }
    | { kind: 'abandon'; row: AdminFreeAbandon };

function secondsLeft(until: number, serverTime: number): number {
    return Math.max(0, Math.round(until - serverTime));
}

function pendingTexts(p: Pending | null, name: string): { title: string; message: string; confirm: string } {
    if (!p) return { title: '', message: '', confirm: '' };
    if (p.kind === 'clear') {
        return {
            title: t('admin.runctl.clear_title', { what: p.label }),
            message: t('admin.runctl.clear_message', { name }),
            confirm: t('admin.runctl.clear'),
        };
    }
    if (p.kind === 'extra') {
        return {
            title: t('admin.runctl.extra_title'),
            message: t('admin.runctl.extra_message', { name }),
            confirm: t('admin.runctl.extra'),
        };
    }
    if (p.kind === 'boss') {
        return {
            title: t('admin.runctl.boss_title'),
            message: t('admin.runctl.boss_message', { name }),
            confirm: t('admin.runctl.boss'),
        };
    }
    return {
        title: t('admin.runctl.abandon_title'),
        message: t('admin.runctl.abandon_message', { mission: p.row.missionLabel }),
        confirm: t('admin.runctl.abandon'),
    };
}

export function OfficerRunControls({ citizenid, officer, onChanged }: OfficerSlotProps) {
    const can = useCan();
    const allowed = can('antiFarmOverride');
    const { data, loading, error, refetch } = useRequest<AdminOfficerRunState>(
        'admin:getOfficerRunState',
        { citizenid },
        { skip: !allowed || !citizenid, pollMs: 30000 },
    );
    const { run, busy } = useAdminAction();
    const [pending, setPending] = useState<Pending | null>(null);
    const [count, setCount] = useState<number | null>(1);
    const [showBoard, setShowBoard] = useState(false);

    if (!allowed) return null;
    const name = (officer as { name?: string } | undefined)?.name ?? citizenid;

    let body;
    if (loading && !data) body = <LoadingBlock />;
    else if (error && !data) body = <ErrorState error={error} onRetry={() => void refetch()} />;
    else if (data) body = <RunState data={data} showBoard={showBoard} onBoard={setShowBoard} onPending={setPending} />;

    const confirm = async (reason: string) => {
        const p = pending;
        if (!p) return;
        let res;
        if (p.kind === 'clear') {
            res = await run(
                'server:admin:clearCooldowns',
                { citizenid, scope: p.scope, key: p.key, reason },
                { success: 'admin.runctl.cleared' },
            );
        } else if (p.kind === 'extra') {
            if (!count) return;
            res = await run(
                'server:admin:allowExtraRuns',
                { citizenid, count, reason },
                { success: 'admin.runctl.extra_done', successVars: { n: count } },
            );
        } else if (p.kind === 'boss') {
            res = await run(
                'server:admin:grantBossAttempt',
                { citizenid, reason },
                { success: 'admin.runctl.boss_done' },
            );
        } else {
            res = await run(
                'server:admin:reclassifyAbandon',
                { citizenid, runUuid: p.row.runUuid, reason },
                { success: 'admin.runctl.abandon_done' },
            );
        }
        setPending(null);
        if (res.ok) {
            void refetch();
            onChanged?.();
        }
    };

    const texts = pendingTexts(pending, name);
    return (
        <Card
            title={t('admin.runctl.title')}
            icon="clock"
            subtitle={t('admin.runctl.subtitle')}
            actions={
                data ? (
                    <Row gap={2}>
                        {data.onRun ? (
                            <Badge size="sm" tone="success" dot>
                                {t('admin.runctl.on_run')}
                            </Badge>
                        ) : null}
                        <Badge size="sm" tone={data.online ? 'primary' : 'grey'}>
                            {t(data.online ? 'admin.runctl.online' : 'admin.runctl.offline')}
                        </Badge>
                    </Row>
                ) : null
            }
        >
            {body}
            <ConfirmDialog
                open={!!pending}
                title={texts.title}
                message={texts.message}
                effect={
                    pending?.kind === 'extra' && data ? (
                        <Field label={t('admin.runctl.extra_count')}>
                            <NumberInput value={count} onChange={setCount} min={1} max={Math.max(1, data.extra.max)} />
                        </Field>
                    ) : null
                }
                confirmLabel={texts.confirm}
                reason={{ required: true, label: t('common.reason'), maxLength: 255 }}
                onConfirm={reason => confirm(reason)}
                onCancel={() => setPending(null)}
                busy={busy}
            />
        </Card>
    );
}

function RunState({
    data,
    showBoard,
    onBoard,
    onPending,
}: {
    data: AdminOfficerRunState;
    showBoard: boolean;
    onBoard: (v: boolean) => void;
    onPending: (p: Pending) => void;
}) {
    const types = asArray(data.cooldowns.types);
    const missions = asArray(data.cooldowns.missions);
    const clearsLeft = Math.max(0, data.clears.max - data.clears.used);
    const clearOff = data.onRun || clearsLeft <= 0;
    const clearTitle = data.onRun
        ? t('admin.runctl.on_run_hint')
        : clearsLeft <= 0
          ? t('admin.runctl.clears_used_up')
          : undefined;
    const abandons = asArray(data.freeAbandons);
    const perType = asArray(data.counts.perType);
    return (
        <>
            <div className="admin-runctl-grid">
                <div className="admin-runctl-box">
                    <span className="admin-runctl-box__title">
                        {t('admin.runctl.cooldowns', { used: data.clears.used, max: data.clears.max })}
                    </span>
                    {types.length || missions.length ? (
                        <ul className="admin-runctl-list">
                            {types.map(c => (
                                <li key={`t-${c.key}`} className="admin-runctl-item">
                                    <span className="admin-runctl-item__text">{c.label}</span>
                                    <Countdown seconds={secondsLeft(c.until, data.serverTime)} />
                                    <Button
                                        size="sm"
                                        variant="ghost"
                                        disabled={clearOff}
                                        title={clearTitle}
                                        onClick={() =>
                                            onPending({ kind: 'clear', scope: 'type', key: c.key, label: c.label })
                                        }
                                    >
                                        {t('admin.runctl.clear')}
                                    </Button>
                                </li>
                            ))}
                            {missions.map(c => (
                                <li key={`m-${c.id}`} className="admin-runctl-item">
                                    <span className="admin-runctl-item__text">{c.label}</span>
                                    <Countdown seconds={secondsLeft(c.until, data.serverTime)} />
                                    <Button
                                        size="sm"
                                        variant="ghost"
                                        disabled={clearOff}
                                        title={clearTitle}
                                        onClick={() =>
                                            onPending({ kind: 'clear', scope: 'mission', key: c.id, label: c.label })
                                        }
                                    >
                                        {t('admin.runctl.clear')}
                                    </Button>
                                </li>
                            ))}
                        </ul>
                    ) : (
                        <span className="admin-live-muted">{t('admin.runctl.no_cooldowns')}</span>
                    )}
                    <Button
                        size="sm"
                        variant="secondary"
                        disabled={clearOff || (!types.length && !missions.length)}
                        title={clearTitle}
                        onClick={() => onPending({ kind: 'clear', scope: 'all', label: t('admin.runctl.everything') })}
                    >
                        {t('admin.runctl.clear_all')}
                    </Button>
                </div>

                <div className="admin-runctl-box">
                    <span className="admin-runctl-box__title">{t('admin.runctl.today')}</span>
                    <ul className="admin-runctl-list">
                        <li className="admin-runctl-item">
                            <span className="admin-runctl-item__text">{t('admin.runctl.completions_day')}</span>
                            <span className="cp-num">
                                {data.counts.maxDay
                                    ? t('admin.runctl.n_of', {
                                          n: data.counts.today,
                                          max: data.counts.maxDay + data.extra.n,
                                      })
                                    : data.counts.today}
                            </span>
                        </li>
                        <li className="admin-runctl-item">
                            <span className="admin-runctl-item__text">{t('admin.runctl.completions_hour')}</span>
                            <span className="cp-num">
                                {t('admin.runctl.n_of', { n: data.counts.hour, max: data.counts.maxHour })}
                            </span>
                        </li>
                        {perType.map(p => (
                            <li key={p.key} className="admin-runctl-item">
                                <span className="admin-runctl-item__text">{p.label}</span>
                                <span className="cp-num">
                                    {p.limit ? t('admin.runctl.n_of', { n: p.n, max: p.limit }) : p.n}
                                </span>
                            </li>
                        ))}
                        <li className="admin-runctl-item">
                            <span className="admin-runctl-item__text">{t('admin.runctl.cash_today')}</span>
                            <Money amount={data.cashToday} />
                        </li>
                    </ul>
                    {data.extra.usedToday ? (
                        <Badge size="sm" tone="accent">
                            {t('admin.runctl.extra_given', { n: data.extra.n })}
                        </Badge>
                    ) : null}
                    <Button
                        size="sm"
                        variant="secondary"
                        disabled={data.extra.usedToday || data.extra.max <= 0}
                        title={data.extra.usedToday ? t('admin.runctl.extra_once') : undefined}
                        onClick={() => onPending({ kind: 'extra' })}
                    >
                        {t('admin.runctl.extra')}
                    </Button>
                </div>

                <div className="admin-runctl-box">
                    <span className="admin-runctl-box__title">{t('admin.runctl.boss_box')}</span>
                    <span>
                        {data.boss.enabled
                            ? t('admin.runctl.boss_state', { used: data.boss.used, left: data.boss.left })
                            : t('admin.runctl.boss_off')}
                    </span>
                    <Button
                        size="sm"
                        variant="secondary"
                        disabled={!data.boss.enabled || data.boss.grantedThisWeek}
                        title={data.boss.grantedThisWeek ? t('admin.runctl.boss_once') : undefined}
                        onClick={() => onPending({ kind: 'boss' })}
                    >
                        {t('admin.runctl.boss')}
                    </Button>
                </div>

                <div className="admin-runctl-box">
                    <span className="admin-runctl-box__title">
                        {t('admin.runctl.free_abandons', { n: abandons.length })}
                    </span>
                    {abandons.length ? (
                        <ul className="admin-runctl-list">
                            {abandons.map(a => (
                                <li key={a.runUuid} className="admin-runctl-item">
                                    <span className="admin-runctl-item__text">
                                        {a.typeLabel} · {a.missionLabel}
                                        <br />
                                        <span className="admin-runctl-item__sub">{formatDateTime(a.at)}</span>
                                    </span>
                                    <Button
                                        size="sm"
                                        variant="ghost"
                                        onClick={() => onPending({ kind: 'abandon', row: a })}
                                    >
                                        {t('admin.runctl.abandon')}
                                    </Button>
                                </li>
                            ))}
                        </ul>
                    ) : (
                        <span className="admin-live-muted">{t('admin.runctl.no_abandons')}</span>
                    )}
                </div>
            </div>

            {data.board ? (
                <>
                    <Button size="sm" variant="ghost" icon="eye" onClick={() => onBoard(!showBoard)}>
                        {showBoard ? t('admin.runctl.board_hide') : t('admin.runctl.board_show')}
                    </Button>
                    {showBoard ? (
                        data.board.operation ? (
                            <EmptyState compact icon="globe" title={t('admin.runctl.board_operation')} />
                        ) : (
                            <div className="admin-runctl-board">
                                {asArray(data.board.cards).map(c => (
                                    <div
                                        key={c.key}
                                        className={c.locked ? 'admin-runctl-card is-locked' : 'admin-runctl-card'}
                                    >
                                        <span className="admin-runctl-card__name">
                                            {c.label}
                                            {c.typeOfTheDay ? ` · ${t('admin.runctl.tod')}` : ''}
                                        </span>
                                        <span className="admin-runctl-card__why">
                                            {c.locked
                                                ? c.locked.reason
                                                : c.busy
                                                  ? t('admin.runctl.board_busy')
                                                  : c.onCall
                                                    ? t('admin.runctl.board_on_call')
                                                    : t('admin.runctl.board_open', { n: c.pool })}
                                        </span>
                                    </div>
                                ))}
                                {data.board.boss ? (
                                    <div
                                        className={
                                            data.board.boss.available
                                                ? 'admin-runctl-card'
                                                : 'admin-runctl-card is-locked'
                                        }
                                    >
                                        <span className="admin-runctl-card__name">{t('admin.runctl.board_boss')}</span>
                                        <span className="admin-runctl-card__why">
                                            {data.board.boss.locked?.reason ?? t('admin.runctl.board_boss_open')}
                                        </span>
                                    </div>
                                ) : null}
                            </div>
                        )
                    ) : null}
                </>
            ) : (
                <span className="admin-live-muted">{t('admin.runctl.board_offline')}</span>
            )}
        </>
    );
}
