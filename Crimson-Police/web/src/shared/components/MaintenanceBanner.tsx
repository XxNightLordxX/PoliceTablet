// The maintenance banner: shown on every UI while CP.Maintenance holds the lock (a storage copy or switch, a backup
// restore, a store left behind). New runs, claims, tests and payments wait until the owner restarts Crimson-Police.

import { t } from '../i18n';
import { useMaintenance } from '../session';
import { Icon } from './Icon';
import './MaintenanceBanner.css';

export function MaintenanceBanner({ admin = false }: { admin?: boolean }) {
    const m = useMaintenance();
    if (!m) return null;
    const kind = m.kind === 'left_behind' ? 'left_behind' : m.kind === 'restore' ? 'restore' : 'storage';
    return (
        <div className="cp-maintenance" role="status">
            <Icon name="alert" size={16} />
            <div className="cp-maintenance__text">
                <strong>{t(`ui.maintenance.title.${kind}`)}</strong>
                <span>{t(admin ? `ui.maintenance.admin.${kind}` : 'ui.maintenance.officer')}</span>
                {admin && m.restart ? (
                    <span className="cp-maintenance__restart">{t('ui.maintenance.restart')}</span>
                ) : null}
            </div>
        </div>
    );
}
