// The twists a leader may add at the accept step (Mission Board, mission call claim; PLAN M8b): one switch per twist
// with its own bonus, and the total bonus of the ones picked ("+45% points, x1.50 cash"), capped as the server caps it.

import { Badge, Icon, Toggle } from '../../shared/components';
import { cx } from '../../shared/cx';
import { asArray } from '../../shared/data';
import { t } from '../../shared/i18n';
import type { TwistCaps, TwistOffer } from '../../shared/types';
import './TwistPicker.css';

// The shipped caps (Config.Events.twistMaxPoints, twistMaxCash) when the server sends none.
const DEFAULT_CAPS: TwistCaps = { points: 0.7, cash: 1.95 };

function pct(share: number): number {
    return Math.round(share * 100);
}

function times(m: number): string {
    return (Math.round(m * 100) / 100).toFixed(2);
}

// The bonus of the picked twists: the points shares add up, the cash multipliers multiply, both stop at the caps
// (CP.Twists.bonus on the server).
export function twistTotal(offered: TwistOffer[], picked: string[], caps?: TwistCaps | null) {
    const max = caps ?? DEFAULT_CAPS;
    let points = 0;
    let cash = 1;
    for (const o of offered) {
        if (!picked.includes(o.key)) continue;
        points += Math.max(0, Number(o.points) || 0);
        cash *= Math.max(1, Number(o.cash) || 1);
    }
    const capped = points > max.points + 1e-9 || cash > max.cash + 1e-9;
    return { points: Math.min(points, max.points), cash: Math.min(cash, max.cash), capped };
}

export interface TwistPickerProps {
    offered?: TwistOffer[] | null;
    caps?: TwistCaps | null;
    // the picked keys, in the offered order
    value: string[];
    onChange: (keys: string[]) => void;
    typeLabel: string;
    // a unit of 2+: the members see the twists on the ready check
    unit?: boolean;
    disabled?: boolean;
}

export function TwistPicker({ offered, caps, value, onChange, typeLabel, unit, disabled }: TwistPickerProps) {
    const list = asArray(offered as TwistOffer[] | undefined);
    if (!list.length) return null;
    const total = twistTotal(list, value, caps);
    const toggle = (key: string, on: boolean) => {
        const next = on ? [...value, key] : value.filter(k => k !== key);
        onChange(list.map(o => o.key).filter(k => next.includes(k)));
    };
    return (
        <div className="twist-picker">
            <div className="twist-picker__head">
                <Icon name="zap" size={14} />
                <span className="twist-picker__title">{t('twist.pick.title')}</span>
            </div>
            <p className="twist-picker__hint">{t('twist.pick.hint')}</p>
            <div className="twist-picker__list">
                {list.map(o => (
                    <Toggle
                        key={o.key}
                        checked={value.includes(o.key)}
                        disabled={disabled}
                        onChange={on => toggle(o.key, on)}
                        label={
                            <span className="twist-picker__label">
                                {o.label}
                                <Badge size="sm" tone="accent">
                                    {t('twist.pick.reward', { points: pct(o.points), cash: times(o.cash) })}
                                </Badge>
                            </span>
                        }
                        description={
                            <>
                                {o.desc ? <span>{o.desc}</span> : null}
                                {o.some ? (
                                    <span className="twist-picker__some">
                                        {t('twist.pick.some', { type: typeLabel })}
                                    </span>
                                ) : null}
                            </>
                        }
                    />
                ))}
            </div>
            <div className={cx('twist-picker__total', value.length > 0 && 'is-on')} role="status">
                {value.length === 0
                    ? t('twist.pick.total_none')
                    : t(total.capped ? 'twist.pick.total_capped' : 'twist.pick.total', {
                          points: pct(total.points),
                          cash: times(total.cash),
                      })}
            </div>
            {unit && value.length > 0 ? <p className="twist-picker__note">{t('twist.pick.unit')}</p> : null}
        </div>
    );
}

export default TwistPicker;
