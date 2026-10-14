// HUD · contact card: the newest fact about a contact, a tell hint ("Watch his hands") or a case-fail confirm
// waiting on the tablet (HUD patch 'contact', false clears it). Uses the HUD message styles.

import { Icon } from '../shared/components';
import { cx } from '../shared/cx';
import { t } from '../shared/i18n';
import type { HudContact } from '../types/custody';

export function ContactCard({ contact }: { contact: HudContact | false | null | undefined }) {
    if (!contact || typeof contact !== 'object') return null;
    const { label, fact, hint, confirm, suppressed } = contact;
    if (!fact && !hint && !confirm) return null;
    const kind = confirm ? 'is-error' : hint ? 'is-warning' : suppressed ? 'is-warning' : 'is-info';
    return (
        <div className={cx('cp-hud__message', kind)} role="status">
            <Icon name={confirm ? 'alert' : hint ? 'eye' : 'idCard'} size={15} />
            <span>
                <strong>{t('custody.hud.contact', { label })}</strong>{' '}
                {confirm ? (
                    <>
                        {confirm} {t('custody.hud.confirm_on_tablet')}
                    </>
                ) : hint ? (
                    hint
                ) : suppressed ? (
                    t('custody.hud.inadmissible', { fact: String(fact) })
                ) : (
                    fact
                )}
            </span>
        </div>
    );
}

export default ContactCard;
