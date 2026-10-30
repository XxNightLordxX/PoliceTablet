// My options -> Mission Board (step O8) against the browser mocks (node walk.mjs, a gate step): the type cards of the
// mock board in the officer's order (favourites first, hidden folded, never the last card) and the options' schema.

import '../../mocks/options.mock';
import '../../mocks/run_ui.mock';
import { request, action } from '../../shared/nui';
import type { OptionsView } from '../../types/options';
import type { MissionBoardData, TypeCard } from '../../types/run_ui';
import { arrangeTypeCards, typeKeys } from './boardOrder';

const failures: string[] = [];
let passed = 0;
function ok(cond: unknown, what: string): void {
    if (cond) passed += 1;
    else failures.push(what);
}

const keysOf = (cards: { key: string }[]) => cards.map(c => c.key).join(',');

export async function walk(): Promise<{ passed: number; failures: string[] }> {
    try {
        await steps();
    } catch (e) {
        failures.push(`stopped: ${e instanceof Error ? e.message : String(e)}`);
    }
    return { passed, failures };
}

async function steps(): Promise<void> {
    const res = await request<MissionBoardData>('getMissionTypes', {});
    ok(res.ok, 'getMissionTypes answers');
    const cards = Object.values(res.data?.cards ?? []) as TypeCard[];
    const server = keysOf(cards);
    ok(cards.length >= 3, 'the mock board has the type cards');

    // shipped (no favourites, nothing hidden): the server's order, nothing folded
    const plain = arrangeTypeCards(cards, [], []);
    ok(keysOf(plain.shown) === server && plain.folded.length === 0, 'no options: the board as today');

    // favourite Tactical: it is the first card, the rest keep the server's order
    const fav = arrangeTypeCards(cards, ['tactical'], []);
    ok(fav.shown[0]?.key === 'tactical', 'favourite tactical: the first card');
    ok(keysOf(fav.shown.slice(1)) === keysOf(cards.filter(c => c.key !== 'tactical')), '...then the server order');
    ok(fav.favourites.has('tactical') && fav.favourites.size === 1, '...with its Favourite badge');

    // two favourites: in the server's order, not the order picked
    const two = arrangeTypeCards(cards, ['tactical', 'patrol'], []);
    ok(two.shown[0]?.key === 'patrol' && two.shown[1]?.key === 'tactical', 'two favourites: in the board order');

    // hide Training: folded, every other card shown
    const hid = arrangeTypeCards(cards, [], ['training']);
    ok(keysOf(hid.folded) === 'training', 'hide training: folded');
    ok(!hid.shown.some(c => c.key === 'training') && hid.shown.length === cards.length - 1, '...the rest shown');

    // a favourite is never folded; a removed type in a saved list changes nothing
    const both = arrangeTypeCards(cards, ['training'], ['training', 'gone_type']);
    ok(both.folded.length === 0 && both.shown[0]?.key === 'training', 'a favourite and hidden type stays a favourite');

    // every type hidden (a type removed since): the first stays, never an empty board
    const all = arrangeTypeCards(
        cards,
        [],
        cards.map(c => c.key),
    );
    ok(all.shown.length === 1 && all.shown[0]?.key === cards[0]?.key, 'all hidden: the first card stays');
    ok(all.folded.length === cards.length - 1, '...the others folded');

    ok(typeKeys(['a', 3, 'b'] as never).join(',') === 'a,b' && typeKeys(true).length === 0, 'typeKeys: strings only');

    // My options lists the three board options; hiding every type is refused, one type is fine
    const view = await request<OptionsView>('getOptions', {});
    const board = (view.data?.schema ?? []).filter(d => d.group === 'board').map(d => d.key);
    ok(board.join(',') === 'favouriteTypes,hiddenTypes,skipAcceptConfirm', 'My options: the Mission Board group');
    const allTypes = ['patrol', 'training', 'investigation', 'tactical'];
    const refused = await action('server:options:set', { hiddenTypes: allTypes });
    ok(!refused.ok && refused.error === 'err.option_hide_all', 'hiding every type is refused');
    const one = await action('server:options:set', { hiddenTypes: ['training'] });
    ok(one.ok, 'hiding one type is saved');
    await action('server:options:set', { hiddenTypes: [] });
}
