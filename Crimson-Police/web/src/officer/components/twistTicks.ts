// The twists the accept step (Mission Board, mission call claim; PLAN M8b) starts with ticked. Pure: no React, so the
// browser walk can check it against the mocks.

import { asArray } from '../../shared/data';
import type { TwistOffer } from '../../shared/types';

// The keys ticked when the dialog opens, in the offered order. The officer's usual twists (My options, step O15) win
// when he picked any: only the ones this card offers are ticked, so a twist the type or his department does not offer
// is never sent. Else the ones his department pre-ticks (step P15), else none.
export function tickedTwists(offered?: TwistOffer[] | null, usual?: unknown): string[] {
    const list = asArray(offered as TwistOffer[] | undefined);
    const mine = asArray(usual as unknown[] | undefined).filter((k): k is string => typeof k === 'string');
    if (mine.length > 0) return list.map(o => o.key).filter(k => mine.includes(k));
    return list.filter(o => o.ticked === true).map(o => o.key);
}
