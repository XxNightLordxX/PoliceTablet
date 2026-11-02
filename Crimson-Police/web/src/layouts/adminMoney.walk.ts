// The Money screen and one request per screen open (step H6) against the browser mocks (node walk.mjs, a gate step):
// Config.AdminUi.moneyScreen merges Mission pay and Payments made into one screen whose old keys stay aliases, and
// Config.AdminUi.oneRequest brings Payments made's totals with its list.

import '../mocks/admin_economy.mock';
import { request } from '../shared/nui';
import type { Session } from '../shared/types';
import type { PaymentsView } from '../types/admin_economy';
import { MONEY_SCREEN_OF, moneyScreenOn, moneyTabOf, resolveAdminKey } from './adminMoney';
import { ADMIN_GROUP_OF } from './adminNav';
import { navBadge, EMPTY_COUNTS } from './navBadges';
import { landingScreen, screensFor } from './screens';

const failures: string[] = [];
let passed = 0;
function ok(cond: unknown, what: string): void {
    if (cond) passed += 1;
    else failures.push(what);
}

const sessionOf = (adminUi: Record<string, unknown>) =>
    ({ actions: [], config: { adminUi: { landing: 'home', ...adminUi } } }) as unknown as Session;

async function steps(): Promise<void> {
    // shipped: two screens as before, no Money screen, no alias
    const shipped = sessionOf({});
    const keys = screensFor('admin', shipped).map(s => s.key);
    ok(!moneyScreenOn(shipped), 'shipped: the Money screen is off');
    ok(keys.includes('admin_payouts') && keys.includes('admin_payments'), 'shipped: Payouts and Payments show');
    ok(!keys.includes('admin_money'), 'shipped: no Money screen');
    ok(resolveAdminKey('admin_payouts', { a: 1 }, shipped).key === 'admin_payouts', 'shipped: no alias');
    ok(moneyScreenOn(sessionOf({ moneyScreen: 'yes' })) === false, 'anything but true is off');

    // on: one Money screen in place of the two, the old keys open its tabs with their params kept
    const on = sessionOf({ moneyScreen: true });
    const onKeys = screensFor('admin', on).map(s => s.key);
    ok(onKeys.includes('admin_money'), 'on: the Money screen shows');
    ok(!onKeys.includes('admin_payouts') && !onKeys.includes('admin_payments'), 'on: the two old screens are tabs');
    ok(onKeys.indexOf('admin_money') === keys.indexOf('admin_payouts'), "on: Money takes Payouts' place");
    const pay = resolveAdminKey('admin_payouts', undefined, on);
    ok(pay.key === 'admin_money' && moneyTabOf(pay.params) === 'pay', 'admin_payouts opens the Mission pay tab');
    const made = resolveAdminKey('admin_payments', { status: 'paying' }, on);
    ok(made.key === 'admin_money' && moneyTabOf(made.params) === 'payments', 'admin_payments opens Payments made');
    ok(made.params.status === 'paying', "the link's own params are kept (Leaderboards -> stuck payments)");
    ok(resolveAdminKey('admin_live', { tab: 'refused' }, on).key === 'admin_live', 'other screens are untouched');
    ok(moneyTabOf({}) === 'pay' && moneyTabOf(null) === 'pay', 'Money opens on Mission pay');
    ok(MONEY_SCREEN_OF.payments === 'admin_payments', 'the tab keeps its old screen');
    ok(navBadge('admin_money', { ...EMPTY_COUNTS, adminPayments: 4 }).badge === '4', 'Money keeps the payments badge');
    ok(ADMIN_GROUP_OF.admin_money === 'economy', 'plain layout: Money under Economy');
    const landing = sessionOf({ moneyScreen: true, landing: 'payouts' });
    const avail = screensFor('admin', landing).map(s => s.key);
    ok(landingScreen('admin', landing, avail) === 'admin_money', 'a landing of payouts opens Money');
    const oldLanding = sessionOf({ landing: 'payouts' });
    ok(
        landingScreen(
            'admin',
            oldLanding,
            screensFor('admin', oldLanding).map(s => s.key),
        ) === 'admin_payouts',
        'shipped: a landing of payouts opens Payouts',
    );

    // oneRequest: the list brings its totals when asked for them
    const two = await request<PaymentsView>('admin:getPayments', { page: 1, size: 25 });
    ok(two.ok && two.data && two.data.totals === undefined, 'without withTotals: no totals (the second request)');
    const one = await request<PaymentsView>('admin:getPayments', { page: 1, size: 25, withTotals: true });
    ok(one.ok && one.data?.totals?.byStatus, 'withTotals: the totals come with the list');
}

export async function walk(): Promise<{ passed: number; failures: string[] }> {
    try {
        await steps();
    } catch (e) {
        failures.push(`stopped: ${e instanceof Error ? e.message : String(e)}`);
    }
    return { passed, failures };
}
