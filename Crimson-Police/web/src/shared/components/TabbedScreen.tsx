// TabbedScreen: one screen made of tabs (Admin Money, Admin Review, Supervisor Department). It keeps the shown tab,

// TabbedScreen: one screen made of tabs (Admin Money, Admin Review, Supervisor Department). It keeps the shown tab,
// follows a link opened while the screen shows (tabOf reads the tab from the screen params), falls back to
// tabOf(null) when the shown tab is no longer allowed, and renders the tab row and the shown tab's body. `above`
// draws something over the tabs (the Department's today at a glance) and is handed the tab setter.

import { useEffect, useState, type ReactNode } from 'react';
import { useNavigation, type ScreenParams } from '../navigation';
import { Tabs, type TabItem } from './Tabs';

export interface TabbedScreenProps<K extends string> {
    items: TabItem<K>[];
    tabOf: (params: ScreenParams | null | undefined) => K;
    children: (tab: K) => ReactNode;
    above?: (setTab: (tab: K) => void) => ReactNode;
    className?: string;
    'aria-label'?: string;
}

export function TabbedScreen<K extends string>({
    items,
    tabOf,
    children,
    above,
    className,
    ...aria
}: TabbedScreenProps<K>) {
    const { params } = useNavigation();
    const [tab, setTab] = useState<K>(tabOf(params));
    // a link opened while the screen shows (Home's tiles, the search, a notification) picks its tab
    // eslint-disable-next-line react-hooks/exhaustive-deps
    useEffect(() => setTab(tabOf(params)), [params]);
    const shown = items.some(it => it.key === tab) ? tab : tabOf(null);
    return (
        <>
            {above ? above(setTab) : null}
            <Tabs<K>
                className={className}
                aria-label={aria['aria-label']}
                value={shown}
                onChange={setTab}
                items={items}
            />
            {children(shown)}
        </>
    );
}
