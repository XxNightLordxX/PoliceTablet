// The result card (ARCHITECTURE §9.6): points, cash, and when present the level bar, the mission call, the debrief
// (decision ledger and people) and item rewards. Shown on the HUD for 25 s or until dismissed.

import { useEffect, useState } from 'react';
import { Badge, Icon, IconButton, ProgressBar, TierBadge } from '../shared/components';
import { cx } from '../shared/cx';
import { pointsLimits } from '../shared/data';
import {
    formatDuration,
    formatFactor,
    formatMoney,
    formatMultiplier,
    formatNumber,
    formatPercent,
} from '../shared/format';
import { t, tOr } from '../shared/i18n';
import type { RunResult } from '../shared/types';
import type { RunItem, RunMissionCall, RunProgress } from '../types/run_ui';
import { DecisionsBlock, PeopleBlock } from './Debrief';

export const RESULT_SECONDS = 25;

const RESULT_ICON = { completed: 'checkCircle', failed: 'xCircle', abandoned: 'minusCircle' } as const;

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

function LevelBlock({ progress }: { progress: RunProgress }) {
    const lv = progress.level;
    const gained = Math.max(0, progress.xpAfter - progress.xpBefore);
    const next = lv.nextLevelXp;
    const into = Math.max(0, progress.xpAfter - lv.levelXp);
    const span = next !== null && next > lv.levelXp ? next - lv.levelXp : 1;
    const left = next !== null ? Math.max(0, next - progress.xpAfter) : 0;
    return (
        <div className="cp-result__block">
            <div className="cp-result__block-head">
                <Icon name="medal" size={14} />
                <span>{t('result.level', { n: lv.n, label: lv.label })}</span>
            </div>
            {progress.levelUp ? (
                <div className="cp-result__notice is-test">
                    <Icon name="star" size={15} />
                    <strong>{t('result.level_up', { n: lv.n })}</strong>
                </div>
            ) : null}
            <ProgressBar
                value={next !== null ? into : 1}
                max={span}
                size="sm"
                label={
                    progress.pending
                        ? t('result.xp_pending')
                        : t('result.xp_gained', { xp: formatNumber(gained), left: formatNumber(left), next: lv.n + 1 })
                }
            />
        </div>
    );
}

function MissionCallBlock({ call }: { call: RunMissionCall }) {
    return (
        <div className="cp-result__block">
            <div className="cp-result__block-head">
                <Icon name="radio" size={14} />
                <span>{t('result.mission_call', { code: call.code })}</span>
            </div>
            <Line
                label={
                    call.responseS !== null
                        ? t('result.response', {
                              time: formatDuration(call.responseS),
                              target: formatDuration(call.targetS),
                          })
                        : t('result.response_none', { target: formatDuration(call.targetS) })
                }
                value={call.rapid ? t('result.rapid') : ''}
                tone={call.rapid ? 'plus' : undefined}
            />
        </div>
    );
}

function ItemsBlock({ items }: { items: RunItem[] }) {
    return (
        <div className="cp-result__block">
            <div className="cp-result__block-head">
                <Icon name="gift" size={14} />
                <span>{t('result.items')}</span>
            </div>
            {items.map((it, i) => (
                <Line
                    key={`i${i}`}
                    label={t('result.item', { count: it.count, label: it.label || it.name })}
                    value={t(`result.item_status.${it.status}`)}
                />
            ))}
        </div>
    );
}

export function ResultScreen({ result, onDismiss }: { result: RunResult; onDismiss: () => void }) {
    const [closing, setClosing] = useState(false);

    useEffect(() => {
        setClosing(false);
        const id = setTimeout(() => setClosing(true), RESULT_SECONDS * 1000);
        return () => clearTimeout(id);
    }, [result]);

    useEffect(() => {
        if (!closing) return;
        const id = setTimeout(onDismiss, 200);
        return () => clearTimeout(id);
    }, [closing, onDismiss]);

    const kind = RESULT_ICON[result.result] ? result.result : 'abandoned';
    const p = result.points;
    const limits = pointsLimits(p);
    const c = result.cash;
    const completed = result.result === 'completed';
    const cashStatus = c.status ? tOr(`result.cash_status.${c.status}`, 'common.unknown') : '';
    const flagText = result.flagged
        ? tOr(`flag.${result.flagged.reason}`, 'result.flag_generic', { reason: result.flagged.reason })
        : '';

    return (
        <section
            className={cx('cp-result', `is-${kind}`, closing && 'is-leaving')}
            aria-label={t(`result.title.${kind}`)}
        >
            <div className="cp-result__head">
                <span className="cp-result__icon">
                    <Icon name={RESULT_ICON[kind]} size={22} />
                </span>
                <div className="cp-result__titles">
                    <span className="cp-result__title">{t(`result.title.${kind}`)}</span>
                    <span className="cp-result__reason">{t(`reason.${result.endReason}`)}</span>
                </div>
                <IconButton icon="x" size="sm" label={t('result.dismiss')} onClick={() => setClosing(true)} />
            </div>

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

            {result.test ? (
                <div className="cp-result__notice is-test">
                    <Icon name="flask" size={15} />
                    <span>{t('result.test_note')}</span>
                </div>
            ) : null}
            {result.flagged ? (
                <div className="cp-result__notice is-flagged">
                    <Icon name="alert" size={15} />
                    <span>
                        <strong>{t('result.flagged', { reason: flagText })}</strong> {t('result.flagged_note')}
                    </span>
                </div>
            ) : null}

            <div className="cp-result__tiers">
                <span className="cp-result__tier-label">{t('result.tier')}</span>
                <TierBadge tier={result.tier} size="sm" />
                {result.payTier && result.payTier !== result.tier ? (
                    <Badge tone="neutral" size="sm" icon="dollar">
                        {t('hud.pay_tier', { tier: t(`tier.${result.payTier}`) })}
                    </Badge>
                ) : null}
            </div>

            <div className="cp-result__block">
                <div className="cp-result__block-head">
                    <Icon name="star" size={14} />
                    <span>{t('result.points')}</span>
                </div>
                <Line label={t('result.base')} value={formatNumber(p.P)} />
                {p.bonuses.map((b, i) => (
                    <Line
                        key={`b${i}`}
                        label={b.label || t(`bonus.${b.id}`)}
                        value={formatNumber(b.points, true)}
                        tone="plus"
                    />
                ))}
                {p.penalties.map((b, i) => (
                    <Line
                        key={`p${i}`}
                        label={b.label || t(`penalty.${b.id}`)}
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

            <div className="cp-result__block">
                <div className="cp-result__block-head">
                    <Icon name="dollar" size={14} />
                    <span>{t('result.cash')}</span>
                    {cashStatus ? (
                        <span className={cx('cp-result__status', `is-${c.status}`)}>{cashStatus}</span>
                    ) : null}
                </div>
                {completed ? (
                    <div className="cp-result__cash">
                        <span className="cp-result__formula cp-num">
                            {formatMoney(c.B)} {formatMultiplier(c.mTier)} {formatMultiplier(c.mMod)} =
                        </span>
                        <span className="cp-result__amount cp-num">{formatMoney(c.amount)}</span>
                    </div>
                ) : (
                    <div className="cp-result__cash">
                        <span className="cp-result__formula">{t('result.no_cash')}</span>
                        <span className="cp-result__amount cp-num">{formatMoney(c.amount)}</span>
                    </div>
                )}
            </div>

            {result.progress ? <LevelBlock progress={result.progress} /> : null}
            {result.missionCall ? <MissionCallBlock call={result.missionCall} /> : null}
            {result.decisions ? <DecisionsBlock decisions={result.decisions} /> : null}
            {result.people ? <PeopleBlock people={result.people} /> : null}
            {result.items && result.items.length > 0 ? <ItemsBlock items={result.items} /> : null}

            <div
                className="cp-result__timer"
                style={{ animationDuration: `${RESULT_SECONDS}s` }}
                key={result.runId + result.endReason}
                aria-hidden
            />
        </section>
    );
}
