// The Money screen and one request per screen open against the browser mocks (node walk.mjs, a gate step):
// one Money screen with Pay rates, Rewards, Payments and Department funds tabs, whose old screen keys stay aliases,
// and Config.AdminUi.oneRequest brings Payments' totals with its list.

import '../mocks/admin_economy.mock';
import '../mocks/oversight.mock';
import { t } from '../shared/i18n';
import { request } from '../shared/nui';
import type { Session } from '../shared/types';
import type { DepartmentFundsView, PaymentsView } from '../types/admin_economy';
import type { DepartmentsData } from '../types/oversight';
import { MONEY_TABS, moneySearchWords, moneyTabOf, resolveAdminKey } from './adminMoney';
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
    // one Money screen, always: the old money screens are its tabs, not sidebar items
    const shipped = sessionOf({});
    const keys = screensFor('admin', shipped).map(s => s.key);
    ok(keys.includes('admin_money'), 'the Money screen shows');
    ok(
        !keys.includes('admin_payouts') && !keys.includes('admin_rewards') && !keys.includes('admin_payments'),
        'Payouts, Rewards and Payments are tabs of Money, not screens of their own',
    );
    ok(keys.indexOf('admin_money') === keys.indexOf('admin_home') + 1, 'Money sits right under Home');
    // an older saved setting (moneyScreen or rewardsScreen false) changes nothing
    const old = sessionOf({ moneyScreen: false, rewardsScreen: false });
    ok(
        screensFor('admin', old).some(s => s.key === 'admin_money'),
        'old switches are ignored: Money still shows',
    );
    ok(MONEY_TABS.join(',') === 'pay,rewards,payments,funds', 'tabs: Pay rates, Rewards, Payments, Department funds');
    ok(
        MONEY_TABS.every(k => t(`admin.money.tab.${k}`) !== `admin.money.tab.${k}`),
        'every tab has its English name',
    );

    // the old keys are aliases of their tab, with the link's own params kept
    const pay = resolveAdminKey('admin_payouts', undefined, shipped);
    ok(pay.key === 'admin_money' && moneyTabOf(pay.params) === 'pay', 'admin_payouts opens the Pay rates tab');
    const rew = resolveAdminKey('admin_rewards', undefined, null);
    ok(rew.key === 'admin_money' && moneyTabOf(rew.params) === 'rewards', 'admin_rewards opens the Rewards tab');
    const made = resolveAdminKey('admin_payments', { status: 'paying' }, shipped);
    ok(made.key === 'admin_money' && moneyTabOf(made.params) === 'payments', 'admin_payments opens Payments');
    ok(made.params.status === 'paying', "the link's own params are kept (Leaderboards -> stuck payments)");
    ok(resolveAdminKey('admin_live', { tab: 'refused' }, shipped).key === 'admin_live', 'other screens are untouched');
    ok(resolveAdminKey('admin_blips', {}, shipped).key === 'admin_markers', 'the Mission blips alias still works');
    ok(moneyTabOf({}) === 'pay' && moneyTabOf(null) === 'pay', 'Money opens on Pay rates');
    ok(moneyTabOf({ moneyTab: 'funds' }) === 'funds', 'Department funds can be asked for');
    ok(moneyTabOf({ moneyTab: 'nope' }) === 'pay', 'an unknown tab opens Pay rates');
    ok(navBadge('admin_money', { ...EMPTY_COUNTS, adminPayments: 4 }).badge === '4', 'Money keeps the payments badge');
    ok(ADMIN_GROUP_OF.admin_money === 'economy', 'plain layout: Money under Economy');
    const words = moneySearchWords().join(' ').toLowerCase();
    ok(words.includes('payouts') && words.includes('rewards') && words.includes('funds'), 'search finds Money');
    const landing = sessionOf({ landing: 'payouts' });
    const avail = screensFor('admin', landing).map(s => s.key);
    ok(landingScreen('admin', landing, avail) === 'admin_money', 'a landing of payouts opens Money');

    // Department funds: the departments its cards are drawn for
    const depts = await request<DepartmentsData>('admin:getDepartments', {});
    ok(depts.ok && (depts.data?.departments.length ?? 0) > 0, 'Department funds: the departments are listed');
    const funds = await request<DepartmentFundsView>('admin:getDepartmentFunds', {
        department: depts.data?.departments[0]?.key,
    });
    ok(funds.ok && funds.data && typeof funds.data.enabled === 'boolean', "Department funds: a department's card");

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
