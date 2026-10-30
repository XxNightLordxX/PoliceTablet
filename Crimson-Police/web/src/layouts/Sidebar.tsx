// Left navigation: one button per visible screen (active item in --cp-primary with an accent edge), each with an
// optional count badge or live dot (the 'nav' counts), plus a footer slot for the role switch. With a `more` label,
// items of group 'more' fold under one More button that carries the sum of their badges (Config.AdminUi.groupSidebar).

import { useEffect, useState, type ReactNode } from 'react';
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
    // 'more' = folded under the More button when the sidebar is grouped
    group?: 'main' | 'more';
}

// Per viewer: whether More was left open (browser storage; a blocked storage just starts folded).
const MORE_KEY = 'cp.sidebar.moreOpen';

function readOpen(): boolean {
    try {
        return window.localStorage.getItem(MORE_KEY) === '1';
    } catch {
        return false;
    }
}

function writeOpen(open: boolean) {
    try {
        window.localStorage.setItem(MORE_KEY, open ? '1' : '0');
    } catch {
        // storage blocked: the state lasts until the panel closes
    }
}

// The More button's badge: the folded items' counts added up ('99+' stays '99+'), so an alert never hides.
export function sumBadges(items: SidebarItem[]): string | undefined {
    let total = 0;
    for (const it of items) {
        if (it.badge === undefined || it.badge === null) continue;
        const n = it.badge === '99+' ? 100 : Number(it.badge);
        if (Number.isFinite(n) && n > 0) total += n;
    }
    if (total <= 0) return undefined;
    return total > 99 ? '99+' : String(total);
}

function NavButton({ it, on, onClick }: { it: SidebarItem; on: boolean; onClick: () => void }) {
    return (
        <button
            type="button"
            className={cx('cp-nav-item', on && 'is-active')}
            aria-current={on ? 'page' : undefined}
            onClick={onClick}
        >
            <Icon name={it.icon} size={18} className="cp-nav-item__icon" />
            <span className="cp-nav-item__label">{it.label}</span>
            {it.live ? <span className="nav-live-dot" aria-hidden /> : null}
            {it.badge !== undefined && it.badge !== null ? (
                <span className="cp-nav-item__badge">{it.badge}</span>
            ) : null}
        </button>
    );
}

export function Sidebar({
    items,
    active,
    onSelect,
    heading,
    footer,
    className,
    more,
}: {
    items: SidebarItem[];
    active: string;
    onSelect: (key: string) => void;
    heading?: ReactNode;
    footer?: ReactNode;
    className?: string;
    // the More button's label; left out = one flat list
    more?: string;
}) {
    const folded = more ? items.filter(it => it.group === 'more') : [];
    const shown = folded.length > 0 ? items.filter(it => it.group !== 'more') : items;
    const activeFolded = folded.some(it => it.key === active);
    const [open, setOpen] = useState(readOpen);
    const foldedBadge = sumBadges(folded);

    // Opening a folded screen any other way (a link, a notification) unfolds More.
    useEffect(() => {
        if (activeFolded) setOpen(true);
    }, [activeFolded]);

    const toggle = () => {
        const next = !open;
        setOpen(next);
        writeOpen(next);
    };

    return (
        <nav className={cx('cp-sidebar', className)} aria-label={typeof heading === 'string' ? heading : undefined}>
            {heading ? <div className="cp-sidebar__heading">{heading}</div> : null}
            <ul className="cp-sidebar__list">
                {shown.map(it => (
                    <li key={it.key}>
                        <NavButton it={it} on={it.key === active} onClick={() => onSelect(it.key)} />
                    </li>
                ))}
                {folded.length > 0 ? (
                    <li>
                        <button
                            type="button"
                            className={cx('cp-nav-item', 'cp-nav-item--more', open && 'is-open')}
                            aria-expanded={open}
                            onClick={toggle}
                        >
                            <Icon name={open ? 'chevronUp' : 'chevronDown'} size={18} className="cp-nav-item__icon" />
                            <span className="cp-nav-item__label">{`${more} (${folded.length})`}</span>
                            {!open && folded.some(it => it.live) ? <span className="nav-live-dot" aria-hidden /> : null}
                            {!open && foldedBadge ? <span className="cp-nav-item__badge">{foldedBadge}</span> : null}
                        </button>
                    </li>
                ) : null}
                {open
                    ? folded.map(it => (
                          <li key={it.key} className="cp-sidebar__more-item">
                              <NavButton it={it} on={it.key === active} onClick={() => onSelect(it.key)} />
                          </li>
                      ))
                    : null}
            </ul>
            {footer ? <div className="cp-sidebar__footer">{footer}</div> : null}
        </nav>
    );
}
