// Renders the current screen inside an error boundary and resets the scroll on screen change.

import { useLayoutEffect, useRef } from 'react';
import { ErrorBoundary } from '../shared/components';
import { useNavigation } from '../shared/navigation';
import type { ScreenDef } from './screens';

export function ScreenHost({ screens, className }: { screens: ScreenDef[]; className?: string }) {
    const { screen, params } = useNavigation();
    const scroller = useRef<HTMLDivElement>(null);
    const def = screens.find(s => s.key === screen) ?? screens[0];

    useLayoutEffect(() => {
        scroller.current?.scrollTo?.(0, 0);
    }, [screen, params]);

    if (!def) return null;
    const Comp = def.component;
    return (
        <div ref={scroller} className={className ?? 'cp-main__scroll'}>
            <ErrorBoundary resetKey={def.key}>
                <Comp key={def.key} />
            </ErrorBoundary>
        </div>
    );
}
