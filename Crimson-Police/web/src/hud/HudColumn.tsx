// The right-edge column that holds the mission HUD and the result card (no NUI focus).
// Centred vertically and scaled with the viewport (useHudScale), but never taller than the screen:
// when the HUD and a long result card are shown together (or on 720p) the column scales down to fit,
// since the player cannot scroll a HUD without focus.
import { useLayoutEffect, useRef, useState, type ReactNode } from 'react';
import { useViewport } from '../shared/hooks';

const MARGIN = 16;

export function HudColumn({ scale, overUi, children }: { scale: number; overUi?: boolean; children: ReactNode }) {
  const ref = useRef<HTMLDivElement>(null);
  const { height } = useViewport();
  const [natural, setNatural] = useState(0);

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

  const fit = natural > 0 ? Math.min(scale, (height - MARGIN * 2) / natural) : scale;
  return (
    <div ref={ref} className={`cp-hud-column${overUi ? ' is-over-ui' : ''}`} style={{ transform: `translateY(-50%) scale(${Math.max(0.4, fit)})` }}>
      {children}
    </div>
  );
}
