// The More fold (Config.AdminUi.foldAdvanced): the rarely changed options of a settings-heavy dialog or screen sit

// under a More button. Off, the children show open as before. Each screen remembers, per viewer in the browser,
// whether More was left open (a blocked storage just starts folded). forceOpen keeps it open (an option that is set
// or has an error never hides).

import { useState, type ReactNode } from 'react';
import { t } from '../i18n';
import { useOptionalSession } from '../session';
import { Icon } from './Icon';

export const MORE_PREFIX = 'cp.more.';

export function readMoreOpen(screen: string): boolean {
    try {
        return window.localStorage.getItem(MORE_PREFIX + screen) === '1';
    } catch {
        return false;
    }
}

export function writeMoreOpen(screen: string, open: boolean): void {
    try {
        window.localStorage.setItem(MORE_PREFIX + screen, open ? '1' : '0');
    } catch {
        // storage blocked: the state lasts until the screen closes
    }
}

// Config.AdminUi.foldAdvanced of the open UI (false outside one).
export function useFoldAdvanced(): boolean {
    return useOptionalSession()?.config?.adminUi?.foldAdvanced === true;
}

export interface MoreFoldProps {
    // the screen or dialog the open state is remembered for (e.g. 'dept_dialog')
    screen: string;
    // fold at all (default: Config.AdminUi.foldAdvanced)
    fold?: boolean;
    // keep it open whatever was remembered
    forceOpen?: boolean;
    // how many options are folded (shown on the button)
    count?: number;
    children: ReactNode;
}

export function MoreFold({ screen, fold, forceOpen, count, children }: MoreFoldProps) {
    const folds = useFoldAdvanced();
    const [open, setOpen] = useState(() => readMoreOpen(screen));
    if (!(fold ?? folds)) return <>{children}</>;
    const shown = open || forceOpen === true;
    const toggle = () => {
        const next = !shown;
        setOpen(next);
        writeMoreOpen(screen, next);
    };
    return (
        <div className={`cp-more${shown ? ' cp-more--open' : ''}`} data-more={screen}>
            <button
                type="button"
                className="cp-more__toggle"
                aria-expanded={shown}
                disabled={forceOpen === true}
                onClick={toggle}
            >
                <Icon name={shown ? 'chevronDown' : 'chevronRight'} size={14} />
                <span>
                    {shown
                        ? t('ui.more.hide')
                        : count !== undefined && count > 0
                          ? t('ui.more.show_n', { n: count })
                          : t('ui.more.show')}
                </span>
            </button>
            {shown ? <div className="cp-more__body">{children}</div> : null}
        </div>
    );
}
