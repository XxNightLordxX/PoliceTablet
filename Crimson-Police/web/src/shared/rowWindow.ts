// Windowed lists: a long list draws only the rows in view, plus a few above and below, and two spacers keep the
// scroll bar and the scroll position as if every row were there. docs/dev/LOOPS.md "NUI".

// Windowed lists: a long list draws only the rows in view, plus a few above and below, and two spacers keep the
// scroll bar and the scroll position as if every row were there. docs/dev/LOOPS.md "NUI".
// rowWindow() works out the rows of a scroll position (more than 100 rows, 12 above and below the view, spacers for the
// rest); useRowWindow() is the Table's scroll handler (one update per animation frame) and measures the first drawn
// row; useGrowingLimit() lets the Settings search results start with 60 rows and add 60 each time an
// IntersectionObserver sees the end within 600 px.

import { useCallback, useEffect, useRef, useState, type UIEvent } from 'react';

// Lists up to this many rows always draw every row (a window would save nothing worth the spacers).
export const WINDOW_MIN_ROWS = 100;
// Rows drawn above and below the view, so a quick scroll shows no blank band.
export const WINDOW_OVERSCAN = 12;
// The rows the Settings search results start with, and add each time the end comes near.
export const GROW_CHUNK = 60;

export interface RowWindow {
    start: number; // first row drawn (inclusive)
    end: number; // last row drawn (exclusive)
    padTop: number; // px of the spacer above the drawn rows
    padBottom: number; // px of the spacer below them
}

// The rows to draw for a scroll position. total rows, each rowHeight px (the first drawn row's height, measured);
// viewport = the visible height. An off window (or a short list) is every row with no spacers.
export function rowWindow(
    total: number,
    scrollTop: number,
    viewport: number,
    rowHeight: number,
    on = true,
    overscan = WINDOW_OVERSCAN,
): RowWindow {
    const n = Math.max(0, Math.floor(total));
    if (!on || n <= WINDOW_MIN_ROWS || !(rowHeight > 0) || !(viewport > 0)) {
        return { start: 0, end: n, padTop: 0, padBottom: 0 };
    }
    const first = Math.floor(Math.max(0, scrollTop) / rowHeight);
    const shown = Math.ceil(viewport / rowHeight);
    const start = Math.min(n, Math.max(0, first - overscan));
    const end = Math.min(n, Math.max(start, first + shown + overscan));
    return { start, end, padTop: start * rowHeight, padBottom: (n - end) * rowHeight };
}

// The window of a scrolling element: its onScroll handler and a ref for the first drawn row (its height is measured
// once per list length). Scroll events are folded into one update per animation frame.
export function useRowWindow(total: number, on: boolean, viewportGuess: number, rowGuess: number) {
    const [scrollTop, setScrollTop] = useState(0);
    const [viewport, setViewport] = useState(viewportGuess);
    const [rowHeight, setRowHeight] = useState(rowGuess);
    const frame = useRef(0);
    const rowRef = useRef<HTMLTableRowElement | null>(null);
    const active = on && total > WINDOW_MIN_ROWS;
    useEffect(() => {
        if (!active) return;
        const h = rowRef.current?.getBoundingClientRect().height;
        if (h && h > 0 && Math.abs(h - rowHeight) > 0.5) setRowHeight(h);
        // rowHeight is measured, not a dependency: one measure per list length
    }, [active, total]);
    useEffect(() => () => cancelAnimationFrame(frame.current), []);
    const onScroll = useCallback(
        (e: UIEvent<HTMLElement>) => {
            // the scroll position is kept also while the list is short (no window), so a list that
            // grows past WINDOW_MIN_ROWS again starts from where the element really is (the browser clamped it)
            if (!on) return;
            const el = e.currentTarget;
            cancelAnimationFrame(frame.current);
            frame.current = requestAnimationFrame(() => {
                setScrollTop(el.scrollTop);
                if (active && el.clientHeight > 0) setViewport(el.clientHeight);
            });
        },
        [on, active],
    );
    return { win: rowWindow(total, scrollTop, viewport, rowHeight, active), onScroll, rowRef };
}

// A list that grows as its end comes into view (the Settings search results): limit rows at first, GROW_CHUNK more
// each time the sentinel element is within 600 px of the view. A new list (key) starts again.
export function useGrowingLimit(total: number, key: unknown) {
    const [limit, setLimit] = useState(GROW_CHUNK);
    useEffect(() => setLimit(GROW_CHUNK), [key]);
    const sentinel = useRef<HTMLDivElement | null>(null);
    // no IntersectionObserver (never in CEF, but a plain browser preview might lack it): every row
    const can = typeof IntersectionObserver !== 'undefined';
    const more = can && total > limit;
    useEffect(() => {
        const el = sentinel.current;
        if (!more || !el) return;
        const io = new IntersectionObserver(
            entries => {
                if (entries.some(en => en.isIntersecting)) setLimit(n => n + GROW_CHUNK);
            },
            { rootMargin: '600px 0px' },
        );
        io.observe(el);
        return () => io.disconnect();
    }, [more, limit]);
    return { limit: can ? limit : Infinity, more, sentinel };
}
