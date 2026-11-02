// Active Mission · the live case card (step V16, Config.LiveCrime.caseCard): the reported crime, the suspect count,
// the three steps (the same for every suspect, like the HUD) and when the "last reported" map points were taken.
// It never shows one suspect's state or a live position. Step H3: "Step n of 3" in the title, the current step marked.

import { Badge, Icon } from '../../shared/components';
import { cx } from '../../shared/cx';
import { formatDuration } from '../../shared/format';
import { t } from '../../shared/i18n';
import type { LiveCaseView } from '../../types/run_ui';
import './LiveCaseCard.css';

const STEPS = ['respond', 'secure', 'detain'] as const;

export function stepIndex(phase: LiveCaseView['phase']): number {
    const i = STEPS.indexOf(phase);
    return i < 0 ? 0 : i;
}

// The "last reported" line: off on this server, not yet (still responding), or how long ago and which labels.
function reportedText(live: LiveCaseView, reportsOn: boolean): string {
    if (!reportsOn) return t('run.live.reported_off');
    if (live.reportedAgoS === null || live.reportedAgoS === undefined) return t('run.live.reported_wait');
    const labels = (Array.isArray(live.reported) ? live.reported : [])
        .map(label => t('run.live.suspect_label', { label }))
        .join(', ');
    const ago = formatDuration(live.reportedAgoS);
    return labels ? t('run.live.reported', { ago, labels }) : t('run.live.reported_free_none', { ago });
}

export function LiveCaseCard({ live }: { live: LiveCaseView }) {
    const reportsOn = live.reportsOn !== false;
    const current = stepIndex(live.phase);
    const where = [live.title, live.street].filter(Boolean).join(' · ');
    const need = Number(live.secureNeed ?? 0);
    return (
        <div className="run_ui-notice run_ui-notice--danger live-case" role="region" aria-label={t('run.live.title')}>
            <span className="run_ui-notice__icon" aria-hidden>
                <Icon name="shield" size={17} />
            </span>
            <span className="run_ui-notice__text">
                <span className="run_ui-notice__title live-case__title">
                    <Badge size="sm" tone="danger">
                        {t('run.live.badge')}
                    </Badge>
                    <span>{where || t('run.live.title')}</span>
                    <Badge size="sm" tone="neutral">
                        {t('run.live.step_of', { n: current + 1, total: STEPS.length })}
                    </Badge>
                </span>
                <span className="run_ui-notice__sub">{t('run.live.suspects', { n: Math.max(1, live.suspects) })}</span>
                <ol className="live-case__steps">
                    {STEPS.map((step, i) => (
                        <li
                            key={step}
                            className={cx('live-case__step', i < current && 'is-done', i === current && 'is-current')}
                            aria-current={i === current ? 'step' : undefined}
                        >
                            <Icon name={i < current ? 'check' : 'dot'} size={12} />
                            <span>{t(`block.live_response.check_${step}`)}</span>
                            {step === 'secure' && i === current && need > 0 ? (
                                <span className="live-case__secure cp-num">
                                    {t('run.live.secure_progress', { s: Number(live.secureS ?? 0), need })}
                                </span>
                            ) : null}
                        </li>
                    ))}
                </ol>
                <span className="run_ui-notice__sub">
                    {reportedText(live, reportsOn)}
                    {reportsOn && typeof live.nextReportS === 'number'
                        ? ` · ${t('run.live.next_report', { s: live.nextReportS })}`
                        : null}
                </span>
                <span className="run_ui-notice__sub live-case__fair">{t('run.live.fair')}</span>
                {live.host ? <span className="run_ui-notice__sub">{t('run.live.end_hint')}</span> : null}
            </span>
        </div>
    );
}

export default LiveCaseCard;
