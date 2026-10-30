// Happy hour (step P6): "Happy hour: no mission cooldowns for 18:00, set by Sgt Doe" on the officer Home and the
// Mission Board. Starts from the session (or the board's data) and follows push 'happyHour' (false = it ended).

import { useEffect, useState } from 'react';
import { Countdown, Icon } from '../../shared/components';
import { usePush } from '../../shared/hooks';
import { hasKey, t } from '../../shared/i18n';
import { useSession } from '../../shared/session';
import type { HappyHourState } from '../../shared/types';
import './HappyHourBanner.css';

export interface HappyHourBannerProps {
    // the board's copy (getMissionTypes); without it the session's
    state?: HappyHourState | false | null;
    // the happy hour started or ended (the board reads its locks again)
    onChange?: () => void;
}

export function happyHourBy(s: HappyHourState): string {
    if (s.by) return s.by;
    const key = `hh.by_role.${s.byRole ?? ''}`;
    return hasKey(key) ? t(key) : t('hh.by_role.supervisor');
}

export function HappyHourBanner({ state, onChange }: HappyHourBannerProps) {
    const session = useSession();
    // undefined = nothing pushed since the last prop
    const [pushed, setPushed] = useState<HappyHourState | false | undefined>(undefined);
    const [over, setOver] = useState(false);
    useEffect(() => {
        setPushed(undefined);
        setOver(false);
    }, [state]);
    usePush<HappyHourState | false | null>('happyHour', data => {
        setPushed(data && typeof data === 'object' ? data : false);
        setOver(false);
        onChange?.();
    });
    const current = pushed !== undefined ? pushed : state !== undefined ? state : session.happyHour;
    if (!current || over) return null;
    return (
        <div className="happy-hour" role="status">
            <span className="happy-hour__icon" aria-hidden>
                <Icon name="clock" size={18} />
            </span>
            <div className="happy-hour__main">
                <div className="happy-hour__title">
                    <span>{t('hh.banner')}</span>{' '}
                    <Countdown
                        seconds={current.left}
                        resetKey={current}
                        warnBelow={120}
                        onDone={() => {
                            setOver(true);
                            onChange?.();
                        }}
                    />
                    <span>{`, ${t('hh.banner_by', { by: happyHourBy(current) })}`}</span>
                </div>
                {current.noRepeat || current.self ? (
                    <div className="happy-hour__text">
                        {[current.noRepeat ? t('hh.banner_norepeat') : '', current.self ? t('hh.banner_self') : '']
                            .filter(Boolean)
                            .join(' ')}
                    </div>
                ) : null}
            </div>
        </div>
    );
}
