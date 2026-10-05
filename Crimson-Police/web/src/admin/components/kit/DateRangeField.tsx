// DateRangeField: a from / to pair of dates (YYYY-MM-DD). The server reads them as from >= day start and
// to < the next day's start (never BETWEEN), so both days are included.

import { Field } from '../../../shared/components';
import { t } from '../../../shared/i18n';
import './kit.css';

export interface DateRange {
    from: string;
    to: string;
}

export function DateRangeField({
    value,
    onChange,
    label,
    disabled,
}: {
    value: DateRange;
    onChange: (next: DateRange) => void;
    label?: string;
    disabled?: boolean;
}) {
    const bad = !!value.from && !!value.to && value.from > value.to;
    return (
        <Field label={label ?? t('ui.kit.date_range')} error={bad ? t('ui.kit.date_order') : undefined}>
            <div className="admin-kit-dates">
                <div className="cp-input admin-kit-dates__input">
                    <input
                        type="date"
                        value={value.from}
                        max={value.to || undefined}
                        disabled={disabled}
                        aria-label={t('ui.kit.date_from')}
                        onChange={e => onChange({ ...value, from: e.target.value })}
                    />
                </div>
                <span className="admin-kit-dates__sep">→</span>
                <div className="cp-input admin-kit-dates__input">
                    <input
                        type="date"
                        value={value.to}
                        min={value.from || undefined}
                        disabled={disabled}
                        aria-label={t('ui.kit.date_to')}
                        onChange={e => onChange({ ...value, to: e.target.value })}
                    />
                </div>
            </div>
        </Field>
    );
}
