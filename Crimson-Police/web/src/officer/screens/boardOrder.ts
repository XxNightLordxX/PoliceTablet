// The Mission Board's type cards in the officer's order (My options -> Mission Board, step O8): favourites first, then
// the server's order; hidden types fold away, but never a favourite and never the last card to accept.

import type { OfficerOptionValue } from '../../shared/types';

export interface TypeCardOrder<T> {
    // the cards shown, favourites first
    shown: T[];
    // the cards folded under "Hidden types (n)", in the server's order
    folded: T[];
    // the keys of the shown favourites (their badge)
    favourites: Set<string>;
}

// An option value as a list of type keys (anything else: none).
export function typeKeys(v: OfficerOptionValue | undefined): string[] {
    return Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string') : [];
}

// cards: the server's order (getMissionTypes). Only the order and the fold change: every card keeps its own state.
// A card command recommends (featured, step P10) comes right after the favourites; a card switched off for the
// department by command (offByCommand) never counts as the card left to accept.
export function arrangeTypeCards<T extends { key: string; featured?: boolean; offByCommand?: boolean }>(
    cards: T[],
    favouriteKeys: string[],
    hiddenKeys: string[],
): TypeCardOrder<T> {
    const fav = new Set(favouriteKeys);
    const hidden = new Set(hiddenKeys.filter(k => !fav.has(k)));
    const first = cards.filter(c => fav.has(c.key));
    const featured = cards.filter(c => !fav.has(c.key) && !hidden.has(c.key) && c.featured === true);
    const rest = cards.filter(c => !fav.has(c.key) && !hidden.has(c.key) && c.featured !== true);
    const folded = cards.filter(c => hidden.has(c.key));
    const shown = [...first, ...featured, ...rest];
    // never fold the last card to accept: with every type hidden (or every shown one off), the first hidden one that
    // is on stays on the board (or the first hidden one when all are off)
    if (!shown.some(c => c.offByCommand !== true) && folded.length > 0) {
        const i = folded.findIndex(c => c.offByCommand !== true);
        shown.push(folded.splice(Math.max(0, i), 1)[0] as T);
    }
    return { shown, folded, favourites: new Set(first.map(c => c.key)) };
}
