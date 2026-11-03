// Active Mission notices: the intel line a block set (view.intel) and the claimed mission call's response target.

import { Icon } from '../../shared/components';
import { cx } from '../../shared/cx';
import { t } from '../../shared/i18n';
import type { ActiveMissionData } from '../../types/run_ui';

export function IntelLine({ intel }: { intel: string }) {
    return (
        <div className="run_ui-notice run_ui-notice--accent" role="note">
            <span className="run_ui-notice__icon" aria-hidden>
                <Icon name="radio" size={17} />
            </span>
            <span className="run_ui-notice__text">
                <span className="run_ui-notice__title">{t('run.intel.title')}</span>
                <span className="run_ui-notice__sub">{intel}</span>
            </span>
        </div>
    );
}

// The response target, then how long this officer took to reach the start.
export function MissionCallLine({ call }: { call: NonNullable<ActiveMissionData['missionCall']> }) {
    const arrived = call.arrivedS !== null && call.arrivedS !== undefined;
    const inTime = arrived && (call.arrivedS as number) <= call.targetS;
    return (
        <div className={cx('run_ui-notice', inTime && 'run_ui-notice--accent')} role="note">
            <span className="run_ui-notice__icon" aria-hidden>
                <Icon name="bell" size={17} />
            </span>
            <span className="run_ui-notice__text">
                <span className="run_ui-notice__title">{t('run.call.title', { code: call.code })}</span>
                <span className="run_ui-notice__sub">
                    {arrived
                        ? t(inTime ? 'run.call.arrived_in_time' : 'run.call.arrived_late', {
                              s: call.arrivedS as number,
                          })
                        : t('run.call.target', { s: call.targetS })}
                </span>
            </span>
        </div>
    );
}
