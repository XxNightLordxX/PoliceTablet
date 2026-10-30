// The screen-edge column that holds the mission HUD and the result card (no NUI focus). The officer options of this PC
// (shared/options_hud.lua) set its side (hudSide), its size on top of the screen size (hudScale) and fewer animations
// (reduceMotion, MotionPref); the officer's textSize (shared/options_look.lua) sets --cp-fs-scale on it.

import { useEffect, useLayoutEffect, useRef, useState, type CSSProperties, type ReactNode } from 'react';
import { useViewport } from '../shared/hooks';
import { textScaleOf, useOption } from '../shared/options';

const MARGIN = 16;

// The officer's HUD size: 1 when unset or not a number, never outside the widest bounds (0.5-2).
export function hudSizeOf(v: unknown): number {
    return typeof v === 'number' && Number.isFinite(v) ? Math.min(2, Math.max(0.5, v)) : 1;
}

// reduceMotion: the body class cp-reduce-motion drops the HUD's slide-in and flash and the toasts' slide-in.
export function MotionPref(): null {
    const reduce = useOption<boolean>('reduceMotion') === true;
    useEffect(() => {
        document.body.classList.toggle('cp-reduce-motion', reduce);
        return () => document.body.classList.remove('cp-reduce-motion');
    }, [reduce]);
    return null;
}

export function HudColumn({ scale, overUi, children }: { scale: number; overUi?: boolean; children: ReactNode }) {
    const ref = useRef<HTMLDivElement>(null);
    const { height } = useViewport();
    const [natural, setNatural] = useState(0);
    const left = useOption<string>('hudSide') === 'left';
    const size = scale * hudSizeOf(useOption<number>('hudScale'));
    const textScale = textScaleOf(useOption('textSize'));

    useLayoutEffect(() => {
        const el = ref.current;
        if (!el) return;
        // offsetHeight ignores the transform, so this is the unscaled height.
        const measure = () => setNatural(el.offsetHeight);
        measure();
        if (typeof ResizeObserver === 'undefined') return;
        const ro = new ResizeObserver(measure);
        ro.observe(el);
        return () => ro.disconnect();
    }, []);

    const fit = natural > 0 ? Math.min(size, (height - MARGIN * 2) / natural) : size;
    return (
        <div
            ref={ref}
            className={`cp-hud-column${left ? ' is-left' : ''}${overUi ? ' is-over-ui' : ''}`}
            style={
                {
                    transform: `translateY(-50%) scale(${Math.max(0.4, fit)})`,
                    '--cp-fs-scale': textScale,
                } as CSSProperties
            }
        >
            {children}
        </div>
    );
}
