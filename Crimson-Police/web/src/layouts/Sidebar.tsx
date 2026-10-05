// Left navigation: one button per visible screen (active item in --cp-primary with an accent edge), each with an
// optional count badge or live dot (the 'nav' counts), plus a footer slot for the role switch.

import type { ReactNode } from 'react';
import { Icon, type IconName } from '../shared/components';
import { cx } from '../shared/cx';
import './access.css';

export interface SidebarItem {
    key: string;
    label: string;
    icon: IconName;
    badge?: ReactNode;
    // a pulsing dot instead of a count (Active Mission while on a run)
    live?: boolean;
}

export function Sidebar({
    items,
    active,
    onSelect,
    heading,
    footer,
    className,
}: {
    items: SidebarItem[];
    active: string;
    onSelect: (key: string) => void;
    heading?: ReactNode;
    footer?: ReactNode;
    className?: string;
}) {
    return (
        <nav className={cx('cp-sidebar', className)} aria-label={typeof heading === 'string' ? heading : undefined}>
            {heading ? <div className="cp-sidebar__heading">{heading}</div> : null}
            <ul className="cp-sidebar__list">
                {items.map(it => {
                    const on = it.key === active;
                    return (
                        <li key={it.key}>
                            <button
                                type="button"
                                className={cx('cp-nav-item', on && 'is-active')}
                                aria-current={on ? 'page' : undefined}
                                onClick={() => onSelect(it.key)}
                            >
                                <Icon name={it.icon} size={18} className="cp-nav-item__icon" />
                                <span className="cp-nav-item__label">{it.label}</span>
                                {it.live ? <span className="nav-live-dot" aria-hidden /> : null}
                                {it.badge !== undefined && it.badge !== null ? (
                                    <span className="cp-nav-item__badge">{it.badge}</span>
                                ) : null}
                            </button>
                        </li>
                    );
                })}
            </ul>
            {footer ? <div className="cp-sidebar__footer">{footer}</div> : null}
        </nav>
    );
}
