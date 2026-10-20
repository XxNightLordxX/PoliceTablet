// The maintenance banner: shown on every UI while CP.Maintenance holds the lock (a storage copy or switch, a backup

import { t } from '../i18n';
import { useMaintenance } from '../session';
import { Icon } from './Icon';
import './MaintenanceBanner.css';

type Kind = 'storage' | 'restore' | 'restore_failed' | 'left_behind';

// The keys are written out, so tools/check_contracts.py checks every one.
const TITLE: Record<Kind, () => string> = {
    storage: () => t('ui.maintenance.title.storage'),
    restore: () => t('ui.maintenance.title.restore'),
    restore_failed: () => t('ui.maintenance.title.restore_failed'),
    left_behind: () => t('ui.maintenance.title.left_behind'),
};

// What admins read: while the copy or restore runs, and once it is done and only the owner's restart ends the lock.
function adminText(kind: Kind, done: boolean, automatic: string): string {
    if (kind === 'storage') return done ? t('ui.maintenance.admin.storage_done') : t('ui.maintenance.admin.storage');
    if (kind === 'restore') return done ? t('ui.maintenance.admin.restore_done') : t('ui.maintenance.admin.restore');
    if (kind === 'restore_failed') return t('ui.maintenance.admin.restore_failed', { automatic });
    return t('ui.maintenance.admin.left_behind');
}

export function MaintenanceBanner({ admin = false }: { admin?: boolean }) {
    const m = useMaintenance();
    if (!m) return null;
    const kind: Kind =
        m.kind === 'left_behind'
            ? 'left_behind'
            : m.kind === 'restore'
              ? m.failed
                  ? 'restore_failed'
                  : 'restore'
              : 'storage';
    const done = !!m.restart && !m.failed;
    return (
        <div className="cp-maintenance" role="status">
            <Icon name="alert" size={16} />
            <div className="cp-maintenance__text">
                <strong>{TITLE[kind]()}</strong>
                <span>{admin ? adminText(kind, done, m.automatic ?? '') : t('ui.maintenance.officer')}</span>
                {admin && done ? <span className="cp-maintenance__restart">{t('ui.maintenance.restart')}</span> : null}
            </div>
        </div>
    );
}
