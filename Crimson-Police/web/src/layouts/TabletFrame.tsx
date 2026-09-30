// The tablet device: a 1280×800 screen in a rounded bezel, centred and scaled to fit the viewport (never larger than
// the space, grows on screens above 1080p), times the officer's tablet size. Themed with the department theme and
// the officer's look; dialogs render inside it (LayerRootContext) so they scale and theme with the tablet.

import { useLayoutEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { LayerRootContext } from '../shared/components';
import { useViewport } from '../shared/hooks';
import { applyAppearance, mergeAppearance } from '../shared/theme';
import type { Prefs, Session, Theme } from '../shared/types';

export const TABLET_W = 1280;
export const TABLET_H = 800;
const MARGIN = 40;
const DEFAULT_RANGE: [number, number, number] = [0.85, 1.25, 1];

// The size factor of the open tablet (Prefs.uiScale, clamped); tabletScale uses it unless given one.
let currentUiScale = 1;

// The tablet size an officer saved, inside Config.Profile.uiScale (min, max, default).
export function clampUiScale(value: unknown, range?: [number, number, number] | null): number {
    const [lo, hi, def] = Array.isArray(range) && range.length === 3 ? range : DEFAULT_RANGE;
    const n = typeof value === 'number' && isFinite(value) ? value : def;
    return Math.min(hi, Math.max(lo, n));
}

export function tabletScale(width: number, height: number, uiScale: number = currentUiScale): number {
    const fit = Math.min((width - MARGIN) / TABLET_W, (height - MARGIN) / TABLET_H);
    const grow = Math.max(1, Math.min(width / 1920, height / 1080));
    return Math.max(0.3, Math.min(fit, Math.min(fit, grow) * uiScale));
}

export function TabletFrame({
    theme,
    prefs,
    profile,
    children,
}: {
    theme: Theme | null | undefined;
    // the officer's look (Session.prefs); the Admin UI and older sessions have none
    prefs?: Prefs | null;
    profile?: Session['config']['profile'];
    children: ReactNode;
}) {
    const { width, height } = useViewport();
    const uiScale = prefs ? clampUiScale(prefs.uiScale, profile?.uiScale) : 1;
    currentUiScale = uiScale;
    const scale = tabletScale(width, height, uiScale);
    const frame = useRef<HTMLDivElement>(null);
    const [layer, setLayer] = useState<HTMLDivElement | null>(null);
    const appearance = prefs?.appearance ?? 'department';
    const accents = profile?.accents ?? null;
    const look = useMemo(
        () => mergeAppearance(theme, appearance, prefs?.accent ?? null, accents),
        [theme, appearance, prefs?.accent, accents],
    );

    useLayoutEffect(() => {
        applyAppearance(frame.current, look, appearance);
    }, [look, appearance]);

    return (
        <div className="cp-tablet-stage">
            <div
                ref={frame}
                className="cp-tablet"
                data-appearance={appearance}
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
