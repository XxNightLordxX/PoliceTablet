// The tablet device: a 1280×800 screen in a rounded bezel, centred and scaled to fit the viewport
// (never larger than the space, grows on screens above 1080p). Themed with the department theme;
// dialogs render inside it (LayerRootContext) so they scale and theme with the tablet.

import { useLayoutEffect, useRef, useState, type ReactNode } from 'react';
import { LayerRootContext } from '../shared/components';
import { useViewport } from '../shared/hooks';
import { applyTheme } from '../shared/theme';
import type { Theme } from '../shared/types';

export const TABLET_W = 1280;
export const TABLET_H = 800;
const MARGIN = 40;

export function tabletScale(width: number, height: number): number {
    const fit = Math.min((width - MARGIN) / TABLET_W, (height - MARGIN) / TABLET_H);
    const grow = Math.max(1, Math.min(width / 1920, height / 1080));
    return Math.max(0.3, Math.min(fit, grow));
}

export function TabletFrame({ theme, children }: { theme: Theme | null | undefined; children: ReactNode }) {
    const { width, height } = useViewport();
    const scale = tabletScale(width, height);
    const frame = useRef<HTMLDivElement>(null);
    const [layer, setLayer] = useState<HTMLDivElement | null>(null);

    useLayoutEffect(() => {
        applyTheme(frame.current, theme);
    }, [theme]);

    return (
        <div className="cp-tablet-stage">
            <div
                ref={frame}
                className="cp-tablet"
                style={{ width: TABLET_W, height: TABLET_H, transform: `translate(-50%, -50%) scale(${scale})` }}
            >
                <div className="cp-tablet__bezel" aria-hidden>
                    <span className="cp-tablet__camera" />
                </div>
                <div className="cp-tablet__screen">
                    <LayerRootContext.Provider value={layer}>{children}</LayerRootContext.Provider>
                    <div ref={setLayer} className="cp-layer-root" />
                </div>
            </div>
        </div>
    );
}
