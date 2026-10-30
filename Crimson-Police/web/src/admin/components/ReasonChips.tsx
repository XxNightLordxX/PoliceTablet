// Admin UI · ReasonChips (Config.AdminUi.reasonChips): ready-made reasons as buttons under a reason box. A click
// fills the box with that reason; the box can still be typed in. Used on Set payout (Payouts, Home, the mission
// drawer), Give or take points (Home, Leaderboards, Officers) and Quick edit. {} in config.lua = no buttons.

import { asArray } from '../../shared/data';
import { t } from '../../shared/i18n';
import { useSession } from '../../shared/session';
import './ReasonChips.css';

export function ReasonChips({
    value,
    onChange,
    disabled,
}: {
    value: string;
    onChange: (reason: string) => void;
    disabled?: boolean;
}) {
    const chips = asArray(useSession().config?.adminUi?.reasonChips);
    if (!chips.length) return null;
    const current = value.trim();
    return (
        <div className="admin-reason-chips" role="group" aria-label={t('admin.reason_chips.label')}>
            {chips.map(chip => (
                <button
                    key={chip}
                    type="button"
                    className="admin-reason-chip"
                    aria-pressed={current === chip}
                    disabled={disabled}
                    onClick={() => onChange(chip)}
                >
                    {chip}
                </button>
            ))}
        </div>
    );
}
