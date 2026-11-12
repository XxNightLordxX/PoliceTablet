// Where the tour card goes: under the element it points at, else above, else to its right or left, always inside
// the window (MARGIN from each edge). No element: the middle of the window.

export interface Box {
    left: number;
    top: number;
    width: number;
    height: number;
}

export const MARGIN = 12;
const GAP = 14;

function clamp(v: number, lo: number, hi: number): number {
    return Math.max(lo, Math.min(hi, v));
}

export function placeCard(
    target: Box | null,
    card: { width: number; height: number },
    view: { width: number; height: number },
): { left: number; top: number; side: 'below' | 'above' | 'right' | 'left' | 'middle' } {
    const maxLeft = Math.max(MARGIN, view.width - card.width - MARGIN);
    const maxTop = Math.max(MARGIN, view.height - card.height - MARGIN);
    if (!target) {
        return {
            left: clamp((view.width - card.width) / 2, MARGIN, maxLeft),
            top: clamp((view.height - card.height) / 2, MARGIN, maxTop),
            side: 'middle',
        };
    }
    const centreX = clamp(target.left + target.width / 2 - card.width / 2, MARGIN, maxLeft);
    const centreY = clamp(target.top + target.height / 2 - card.height / 2, MARGIN, maxTop);
    const below = target.top + target.height + GAP;
    if (below + card.height <= view.height - MARGIN) return { left: centreX, top: below, side: 'below' };
    const above = target.top - GAP - card.height;
    if (above >= MARGIN) return { left: centreX, top: above, side: 'above' };
    const right = target.left + target.width + GAP;
    if (right + card.width <= view.width - MARGIN) return { left: right, top: centreY, side: 'right' };
    const left = target.left - GAP - card.width;
    if (left >= MARGIN) return { left, top: centreY, side: 'left' };
    // a big element (a whole screen): over it, in its lower right corner
    return {
        left: clamp(target.left + target.width - card.width - GAP, MARGIN, maxLeft),
        top: clamp(target.top + target.height - card.height - GAP, MARGIN, maxTop),
        side: 'middle',
    };
}
