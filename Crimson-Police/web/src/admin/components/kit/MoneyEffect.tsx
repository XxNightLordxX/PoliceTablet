// MoneyEffect: the money an action moves, line by line (the amount the server computed, never one typed here).

import { Money } from '../../../shared/components';
import { t } from '../../../shared/i18n';
import type { MoneyEffectLine } from '../../../types/admin_control';
import './kit.css';

export function MoneyEffect({ lines, total }: { lines: MoneyEffectLine[]; total?: number }) {
    if (lines.length === 0) return null;
    return (
        <dl className="admin-kit-money">
            {lines.map((l, i) => (
                <div key={`${l.label}-${i}`} className="admin-kit-money__line">
                    <dt>{l.label}</dt>
                    <dd>
                        {l.before !== undefined ? (
                            <s className="admin-kit-money__before">
                                <Money amount={l.before} />
                            </s>
                        ) : null}
                        <Money amount={l.amount} />
                    </dd>
                </div>
            ))}
            {total !== undefined ? (
                <div className="admin-kit-money__line admin-kit-money__line--total">
                    <dt>{t('ui.kit.money_total')}</dt>
                    <dd>
                        <Money amount={total} />
                    </dd>
                </div>
            ) : null}
        </dl>
    );
}
