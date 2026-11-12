// Admin UI -> Money -> Rewards walked against the browser mocks (node walk.mjs, a gate
// step): the Rewards tab of Money lists every feature that pays with its money, account and items, saves
// through server:admin:setSetting, and the item editors build the values the server checks.

import '../../mocks/settings.mock';
import { moneyTabOf } from '../../layouts/adminMoney';
import { ADMIN_SCREENS } from '../../layouts/screens';
import { action, request } from '../../shared/nui';
import type { SettingsData } from '../../types/settings';
import { groupsOf, handlesRewardPool, valueOf } from './RewardPoolEditor';
import { itemSwitch, missionTypes, rewardRows, showsMoneyItem, typeAmount, withTypeAmount } from './rewardsScreen';

const failures: string[] = [];
let passed = 0;
function ok(cond: unknown, what: string): void {
    if (cond) passed += 1;
    else failures.push(what);
}

async function steps(): Promise<void> {
    // the screen: a tab of Money (no screen of its own)
    ok(!ADMIN_SCREENS.some(s => (s.key as string) === 'admin_rewards'), 'no Rewards screen of its own in the sidebar');
    ok(moneyTabOf({ moneyTab: 'rewards' }) === 'rewards', 'navigate(admin_money, { moneyTab: rewards }) opens Rewards');

    // the rows from the settings data
    const res = await request<SettingsData>('admin:getSettings', {});
    const rows = rewardRows(res.data);
    const keys = rows.map(r => r.key);
    ok(
        keys.join(',') ===
            'type_patrol,type_tactical,live,volunteer_case,suspect,surrender,ftoSignOff,ftoComplete,supAward',
        `every feature that pays, NPC missions first: ${keys.join(',')}`,
    );
    ok(missionTypes(res.data).join(',') === 'patrol,tactical', 'the mission types of the data');
    const patrol = rows.find(r => r.key === 'type_patrol');
    ok(patrol?.label === 'Patrol' && !patrol.on, 'a mission type: its label, always paid (no switch)');
    ok(patrol?.money[0]?.s.path === 'MissionTypes.patrol.payout', 'a mission type: its payout');
    ok(patrol?.account?.path === 'Cash.account', 'a mission type: paid as Config.Cash.account');
    ok(
        patrol?.items?.kind === 'pool' && patrol.items.key === 'patrol' && patrol.items.s.path === 'Rewards.byType',
        'a mission type: its own Rewards.byType pool',
    );
    const live = rows.find(r => r.key === 'live');
    ok(
        live?.on?.path === 'RealPlayers.liveCrime.cash' && live.money.length === 0 && !!live.moneyNoteKey,
        'live cases: a switch',
    );
    ok(
        live?.items?.kind === 'switch' && live.items.s.path === 'RealPlayers.liveCrime.items',
        'live cases: the item switch',
    );
    const suspect = rows.find(r => r.key === 'suspect');
    ok(
        suspect?.money.map(m => m.s.path).join(',') ===
            'FeatureRewards.suspect.money.got_away,FeatureRewards.suspect.money.caught',
        'volunteer suspects: money by outcome',
    );
    ok(suspect?.byType?.path === 'FeatureRewards.suspect.byType', 'volunteer suspects: money by mission type');
    ok(suspect?.items?.kind === 'list' && suspect.items.s.path === 'FeatureRewards.suspect.items', 'its items list');
    ok(suspect?.on?.value === false, 'shipped: the feature is off');
    const sup = rows.find(r => r.key === 'supAward');
    ok(sup?.money.length === 2 && sup.card === 'team', 'supervisor awards: per point and the most per award');
    ok(suspect && !showsMoneyItem(suspect), 'paid as cash: no money item box');

    // the global item switch and a save (the Settings save flow: audited by the server)
    ok(itemSwitch(res.data)?.value === false, 'item rewards ship off');
    const on = await action('server:admin:setSetting', { path: 'Rewards.enabled', value: true });
    ok(on.ok, 'one click turns item rewards on through server:admin:setSetting');
    await action('server:admin:setSetting', { path: 'FeatureRewards.suspect.account', value: 'item' });
    const again = await request<SettingsData>('admin:getSettings', {});
    ok(itemSwitch(again.data)?.value === true, 'item rewards show on');
    const paidAsItem = rewardRows(again.data).find(r => r.key === 'suspect');
    ok(paidAsItem && showsMoneyItem(paidAsItem), 'paid as an item: the money item box shows');
    await action('server:admin:resetSetting', { path: 'Rewards.enabled' });
    await action('server:admin:resetSetting', { path: 'FeatureRewards.suspect.account' });

    // money by mission type: an empty box is the per-outcome default
    let by = withTypeAmount({}, 'tactical', 'got_away', 3000);
    ok(typeAmount(by, 'tactical', 'got_away') === 3000, 'a type amount is set');
    ok(typeAmount(by, 'tactical', 'caught') === null, 'the other outcome stays the default');
    ok(typeAmount(by, 'patrol', 'got_away') === null, 'another type stays the default');
    by = withTypeAmount(by, 'tactical', 'got_away', null);
    ok(JSON.stringify(by) === '{}', 'clearing the last amount removes the type');

    // the item editors: a feature's items list, one key of Rewards.byType
    ok(handlesRewardPool('FeatureRewards.suspect.items'), 'a feature items list uses the item picker');
    ok(!handlesRewardPool('FeatureRewards.suspect.money'), 'its money does not');
    const list = groupsOf('FeatureRewards.ftoComplete.items', [
        { item: 'water', count: [1, 3], chance: 0.5, value: 20 },
    ]);
    ok(list.length === 1 && list[0].specs[0]?.chance === 0.5 && list[0].specs[0].hi === 3, 'the list reads back');
    ok(
        JSON.stringify(valueOf('FeatureRewards.ftoComplete.items', list)) ===
            '[{"item":"water","count":[1,3],"value":20,"chance":0.5}]',
        'the list saves as { item, count, value, chance } entries',
    );
    const base = {
        patrol: { chance: 0.2, rolls: 1, pool: [{ item: 'water', count: 1, weight: 1, value: 5 }] },
        tactical: { chance: 0.1, rolls: 1, pool: [{ item: 'bandage', count: 2, weight: 1, value: 10 }] },
    };
    const one = groupsOf('Rewards.byType', base, 'tactical');
    ok(one.length === 1 && one[0].key === 'tactical' && one[0].specs[0]?.item === 'bandage', 'one type only');
    one[0].chance = 0.3;
    const merged = valueOf('Rewards.byType', one, base, 'tactical') as typeof base;
    ok(merged.tactical.chance === 0.3 && merged.patrol.chance === 0.2, 'saving one type keeps the others');
    const none = groupsOf('Rewards.byType', base, 'investigation');
    ok(none[0]?.specs.length === 0, 'a type with no pool starts empty');
    const removed = valueOf('Rewards.byType', [{ ...one[0], specs: [] }], base, 'tactical') as Record<string, unknown>;
    ok(!('tactical' in removed) && 'patrol' in removed, 'an emptied pool removes only that type');
}

export async function walk(): Promise<{ passed: number; failures: string[] }> {
    try {
        await steps();
    } catch (e) {
        failures.push(`stopped: ${e instanceof Error ? e.message : String(e)}`);
    }
    return { passed, failures };
}
