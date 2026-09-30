// Tablet header bar (--cp-primary): logo, app title "Crimson-Police" and, for officer and supervisor, the officer's
// picture and level next to "<departmentLabel> · <departmentShort> · <rank> · <callsign>". Right: bell, role, close.

import type { ReactNode } from 'react';
import { Avatar, DeptLogo, Icon, IconButton } from '../shared/components';
import { t } from '../shared/i18n';
import { officerLine } from '../shared/session';
import type { Session, UiKind } from '../shared/types';
import { NotificationBell } from './NotificationBell';
import './access.css';

const XP_TONES = ['grey', 'bronze', 'silver', 'gold', 'platinum'];

export function Header({
    session,
    ui,
    onClose,
    extra,
}: {
    session: Session;
    ui: UiKind;
    onClose: () => void;
    extra?: ReactNode;
}) {
    const line = ui === 'admin' ? '' : officerLine(session.officer, t('common.no_callsign'));
    const officer = ui === 'admin' ? null : session.officer;
    const level = officer?.level ?? null;
    const tone = level && XP_TONES.includes(level.badge) ? level.badge : 'grey';
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
                    {line ? (
                        <div className="cp-header__line" title={line}>
                            {line}
                        </div>
                    ) : null}
                </div>
                {officer ? (
                    <div className="cp-header-officer">
                        <Avatar avatar={officer.avatar} name={officer.name} size={32} />
                        {level ? (
                            <span
                                className={`cp-header-level cp-header-level--${tone}`}
                                title={
                                    level.label
                                        ? t('access.header.level_band', { n: level.n, band: level.label })
                                        : undefined
                                }
                            >
                                {t('access.header.level', { n: level.n })}
                            </span>
                        ) : null}
                    </div>
                ) : null}
            </div>
            <div className="cp-header__right">
                {extra}
                {ui !== 'admin' ? <NotificationBell /> : null}
                <span className={`cp-header__role cp-header__role--${ui}`}>
                    <Icon name={ui === 'officer' ? 'shield' : ui === 'supervisor' ? 'shieldCheck' : 'key'} size={14} />
                    {t(`ui.role.${ui}`)}
                </span>
                <IconButton icon="x" label={t('ui.close')} className="cp-header__close" onClick={onClose} />
            </div>
        </header>
    );
}
