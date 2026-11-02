// Renders the current screen inside an error boundary and resets the scroll on screen change. A screen that loads on
// first use (screens.ts) waits inside Suspense: the sidebar and header stay while it loads.

import { Suspense, useLayoutEffect, useRef } from 'react';
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
                {/* a screen that loads on first use (screens.ts lazyScreen) shows nothing for the moment it loads */}
                <Suspense fallback={null}>
                    <Comp key={def.key} />
                </Suspense>
            </ErrorBoundary>
        </div>
    );
}
