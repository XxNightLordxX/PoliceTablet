// Full-screen fade used by the downed pick-up ("Picked up by an NPC unit"): overlay kind 'fade' { text }.

import { useEffect, useState } from 'react';
import type { Overlay } from '../shared/types';

export function FadeOverlay({ overlay }: { overlay: Overlay }) {
    const [shown, setShown] = useState(false);
    useEffect(() => {
        const id = requestAnimationFrame(() => setShown(true));
        return () => cancelAnimationFrame(id);
    }, []);
    return (
        <div className={`cp-fade${shown ? ' is-shown' : ''}`} role="status" aria-live="polite">
            {overlay.text ? <div className="cp-fade__text">{String(overlay.text)}</div> : null}
        </div>
    );
}
