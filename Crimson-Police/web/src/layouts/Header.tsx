// Tablet header bar (--cp-primary): logo, app title "Crimson-Police" and, for officer and supervisor,
// "<departmentLabel> · <departmentShort> · <rank> · <callsign>". Right side: role chip and close.
import type { ReactNode } from 'react';
import { DeptLogo, Icon, IconButton } from '../shared/components';
import { t } from '../shared/i18n';
import { officerLine } from '../shared/session';
import type { Session, UiKind } from '../shared/types';

export function Header({ session, ui, onClose, extra }: { session: Session; ui: UiKind; onClose: () => void; extra?: ReactNode }) {
  const line = ui === 'admin' ? '' : officerLine(session.officer, t('common.no_callsign'));
  return (
    <header className="cp-header">
      <div className="cp-header__brand">
        {session.logo ? (
          <span className="cp-header__logo">
            <DeptLogo logo={session.logo} department={session.officer?.department} size={34} />
          </span>
        ) : null}
        <div className="cp-header__titles">
          <div className="cp-header__title">{session.title || 'Crimson-Police'}</div>
          {line ? <div className="cp-header__line" title={line}>{line}</div> : null}
        </div>
      </div>
      <div className="cp-header__right">
        {extra}
        <span className={`cp-header__role cp-header__role--${ui}`}>
          <Icon name={ui === 'officer' ? 'shield' : ui === 'supervisor' ? 'shieldCheck' : 'key'} size={14} />
          {t(`ui.role.${ui}`)}
        </span>
        <IconButton icon="x" label={t('ui.close')} className="cp-header__close" onClick={onClose} />
      </div>
    </header>
  );
}
