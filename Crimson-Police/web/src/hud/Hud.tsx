// The mission HUD (ARCHITECTURE §9.3): shown at the right edge while hud is set, without NUI focus.
// The timer and the off-route countdown count down locally; they restart only when Lua sends a new
// value (Lua sends the full merged state on every patch, so an unchanged value keeps counting).

import { Badge, Icon, TierBadge } from '../shared/components';
import { cx } from '../shared/cx';
import { formatDistance, formatDuration } from '../shared/format';
import { useCountdown } from '../shared/hooks';
import { t } from '../shared/i18n';
import type { HudObjective, HudState } from '../shared/types';
import TestControls from './TestControls';

function Timer({ timer }: { timer: NonNullable<HudState['timer']> }) {
    const left = useCountdown(timer.remaining, { paused: timer.paused });
    const s = left ?? 0;
    const tone = timer.paused ? 'is-paused' : s <= 15 ? 'is-danger' : s <= 60 ? 'is-warning' : '';
    return (
        <div className={cx('cp-hud__timer', tone)}>
            <span className="cp-hud__timer-label">
                {timer.paused ? <Icon name="pause" size={10} /> : null}
                {timer.paused ? t('hud.paused') : t('hud.time_left')}
            </span>
            <span className="cp-hud__timer-value cp-num">{formatDuration(s)}</span>
        </div>
    );
}

function RouteLine({ route }: { route: NonNullable<HudState['route']> }) {
    const left = useCountdown(route.status === 'off' ? route.secondsLeft : null);
    switch (route.status) {
        case 'off':
            return (
                <div className="cp-hud__route is-off" role="alert">
                    <Icon name="alert" size={16} />
                    <div className="cp-hud__route-text">
                        <strong>{t('hud.route.off_title')}</strong>
                        <span>
                            {left !== null ? (
                                <>
                                    {t('hud.route.off_prefix')}{' '}
                                    <b className="cp-num">{t('common.seconds_short', { n: left })}</b>
                                </>
                            ) : (
                                t('hud.route.off_nolimit')
                            )}
                        </span>
                    </div>
                </div>
            );
        case 'on':
            return (
                <div className="cp-hud__route is-on">
                    <Icon name="navigation" size={15} />
                    <div className="cp-hud__route-text">
                        <strong>{t('hud.route.on')}</strong>
                        {route.distance !== null && route.distance !== undefined ? (
                            <span className="cp-num">
                                {t('hud.route.distance', { distance: formatDistance(route.distance) })}
                            </span>
                        ) : null}
                    </div>
                </div>
            );
        case 'arrived':
            return (
                <div className="cp-hud__route is-arrived">
                    <Icon name="mapPin" size={15} />
                    <div className="cp-hud__route-text">
                        <strong>{t('hud.route.arrived')}</strong>
                    </div>
                </div>
            );
        default:
            return (
                <div className="cp-hud__route is-disabled">
                    <Icon name="navigation" size={15} />
                    <div className="cp-hud__route-text">
                        <strong>{t('hud.route.disabled')}</strong>
                    </div>
                </div>
            );
    }
}

function Objective({ o }: { o: HudObjective }) {
    const hasProgress = typeof o.value === 'number' && typeof o.max === 'number' && o.max > 0;
    const pct = hasProgress ? Math.max(0, Math.min(100, ((o.value as number) / (o.max as number)) * 100)) : 0;
    return (
        <li className={cx('cp-hud__obj', o.done && 'is-done', o.current && !o.done && 'is-current')}>
            <span className="cp-hud__obj-mark" aria-hidden>
                {o.done ? <Icon name="check" size={12} strokeWidth={3} /> : null}
            </span>
            <div className="cp-hud__obj-body">
                <div className="cp-hud__obj-row">
                    <span className="cp-hud__obj-label">{o.label}</span>
                    {hasProgress ? (
                        <span className="cp-hud__obj-count cp-num">
                            {t('hud.objective_progress', { value: o.value as number, max: o.max as number })}
                        </span>
                    ) : null}
                </div>
                {hasProgress && !o.done ? (
                    <div className="cp-hud__obj-bar">
                        <div style={{ width: `${pct}%` }} />
                    </div>
                ) : null}
                {o.detail ? <div className="cp-hud__obj-detail">{o.detail}</div> : null}
            </div>
        </li>
    );
}

const MESSAGE_ICON = { info: 'info', success: 'checkCircle', warning: 'alert', error: 'xCircle' } as const;

export function Hud({ hud }: { hud: HudState }) {
    const objectives = hud.objectives ?? [];
    const done = objectives.filter(o => o.done).length;
    // Route line: always while heading to the start; afterwards only while still on/off the route
    // (a late participant), never a stale "arrived"/"disabled" line during the objectives.
    const showRoute = !!hud.route && (hud.phase === 'route' || hud.route.status === 'on' || hud.route.status === 'off');
    const phaseKey =
        hud.phase === 'route' ? 'hud.phase.route' : hud.phase === 'ended' ? 'hud.phase.ended' : 'hud.phase.objectives';
    const msgKind = hud.message && MESSAGE_ICON[hud.message.kind] ? hud.message.kind : 'info';

    return (
        <section
            className={cx('cp-hud', hud.test && 'is-test', hud.phase === 'ended' && 'is-ended')}
            aria-label={hud.missionLabel}
        >
            {hud.test ? (
                <div className="cp-hud__test">
                    <Icon name="flask" size={13} />
                    <span>{t('hud.test_run')}</span>
                    <span className="cp-hud__test-note">{t('hud.test_note')}</span>
                </div>
            ) : null}

            <div className="cp-hud__card">
                <div className="cp-hud__head">
                    <div className="cp-hud__titles">
                        <span className="cp-hud__eyebrow">{t(phaseKey)}</span>
                        <span className="cp-hud__mission">{hud.missionLabel}</span>
                    </div>
                    {hud.timer ? <Timer timer={hud.timer} /> : null}
                </div>

                <div className="cp-hud__chips">
                    <TierBadge tier={hud.tier} size="sm" />
                    {hud.payTier && hud.payTier !== hud.tier ? (
                        <Badge tone="neutral" size="sm" icon="dollar" title={t('hud.pay_tier_hint')}>
                            {t('hud.pay_tier', { tier: t(`tier.${hud.payTier}`) })}
                        </Badge>
                    ) : null}
                    {hud.modifier ? (
                        <Badge tone="accent" size="sm" icon="zap">
                            {hud.modifier.label}
                        </Badge>
                    ) : null}
                </div>

                {hud.message ? (
                    <div className={cx('cp-hud__message', `is-${msgKind}`)} role="status">
                        <Icon name={MESSAGE_ICON[msgKind]} size={15} />
                        <span>{hud.message.text}</span>
                    </div>
                ) : null}

                {showRoute && hud.route ? <RouteLine route={hud.route} /> : null}

                {objectives.length ? (
                    <div className="cp-hud__objectives">
                        <div className="cp-hud__section-head">
                            <span>{t('hud.objectives')}</span>
                            <span className="cp-num">
                                {t('hud.objectives_count', { done, total: objectives.length })}
                            </span>
                        </div>
                        <ol className="cp-hud__obj-list">
                            {objectives.map((o, i) => (
                                <Objective key={i} o={o} />
                            ))}
                        </ol>
                    </div>
                ) : hud.phase === 'route' ? (
                    <div className="cp-hud__pending">{t('hud.objectives_pending')}</div>
                ) : null}

                {hud.detail ? (
                    <div className="cp-hud__detail">
                        <Icon name="info" size={14} />
                        <span>{hud.detail}</span>
                    </div>
                ) : null}
            </div>

            {hud.testControls ? <TestControls hud={hud} /> : null}
        </section>
    );
}
