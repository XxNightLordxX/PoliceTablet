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
export function arrangeTypeCards<T extends { key: string }>(
    cards: T[],
    favouriteKeys: string[],
    hiddenKeys: string[],
): TypeCardOrder<T> {
    const fav = new Set(favouriteKeys);
    const hidden = new Set(hiddenKeys.filter(k => !fav.has(k)));
    const first = cards.filter(c => fav.has(c.key));
    const rest = cards.filter(c => !fav.has(c.key) && !hidden.has(c.key));
    const folded = cards.filter(c => hidden.has(c.key));
    const shown = [...first, ...rest];
    // never fold the last card: with every type hidden, the first of them stays on the board
    if (shown.length === 0 && folded.length > 0) shown.push(folded.shift() as T);
    return { shown, folded, favourites: new Set(first.map(c => c.key)) };
}
