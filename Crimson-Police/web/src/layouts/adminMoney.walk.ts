// The Money screen and one request per screen open against the browser mocks (node walk.mjs, a gate step):
// one Money screen with Pay rates, Rewards, Payments and Department funds tabs (a link names its tab), and Payments
// gets its totals with its list.

import '../mocks/admin_economy.mock';
import '../mocks/oversight.mock';
import paymentsSrc from '../admin/screens/Payments.tsx?raw';
import { mockLocale } from '../mocks/samples';
import { setLocale, t } from '../shared/i18n';
import { request } from '../shared/nui';
import type { Session } from '../shared/types';
import type { BankingCheck, DepartmentFundsView, PaymentsView } from '../types/admin_economy';
import type { DepartmentsData } from '../types/oversight';
import { MONEY_TABS, moneySearchWords, moneyTabOf } from './adminMoney';
import { ADMIN_GROUP_OF } from './adminNav';
import { navBadge, EMPTY_COUNTS } from './navBadges';
import { landingScreen, screensFor } from './screens';

const failures: string[] = [];
let passed = 0;
function ok(cond: unknown, what: string): void {
    if (cond) passed += 1;
    else failures.push(what);
}

const sessionOf = (adminUi: Record<string, unknown>) => ({ actions: [], config: { adminUi } }) as unknown as Session;

async function steps(): Promise<void> {
    // the English texts of every locale part, as in game (run alone, no other walk loads them first)
    setLocale(mockLocale);
    // one Money screen, always: the old money screens are its tabs, not sidebar items
    const shipped = sessionOf({});
    const keys = screensFor('admin', shipped).map(s => s.key);
    ok(keys.includes('admin_money'), 'the Money screen shows');
    ok(
        !(keys as string[]).some(k => ['admin_payouts', 'admin_rewards', 'admin_payments'].includes(k)),
        'Payouts, Rewards and Payments are tabs of Money, not screens of their own',
    );
    ok(keys.indexOf('admin_money') > keys.indexOf('admin_rs'), 'Money sits after Real players, by job');
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

    // a link names its tab; the old screen keys are no screens any more
    ok(moneyTabOf({ moneyTab: 'payments', status: 'paying' }) === 'payments', 'a link opens Payments');
    ok(!keys.some(k => (k as string) === 'admin_blips'), 'no old Mission blips key');
    ok(moneyTabOf({}) === 'pay' && moneyTabOf(null) === 'pay', 'Money opens on Pay rates');
    ok(moneyTabOf({ moneyTab: 'funds' }) === 'funds', 'Department funds can be asked for');
    ok(moneyTabOf({ moneyTab: 'nope' }) === 'pay', 'an unknown tab opens Pay rates');
    ok(navBadge('admin_money', { ...EMPTY_COUNTS, adminPayments: 4 }).badge === '4', 'Money keeps the payments badge');
    ok(ADMIN_GROUP_OF.admin_money === 'money', 'Money has a group of its own');
    const words = moneySearchWords().join(' ').toLowerCase();
    ok(words.includes('payouts') && words.includes('rewards') && words.includes('funds'), 'search finds Money');
    const avail = screensFor('admin', shipped).map(s => s.key);
    ok(landingScreen('admin', shipped, avail) === 'admin_home', 'the Admin UI opens on Home');

    // Department funds: the departments its cards are drawn for
    const depts = await request<DepartmentsData>('admin:getDepartments', {});
    ok(depts.ok && (depts.data?.departments.length ?? 0) > 0, 'Department funds: the departments are listed');
    const funds = await request<DepartmentFundsView>('admin:getDepartmentFunds', {
        department: depts.data?.departments[0]?.key,
    });
    ok(funds.ok && funds.data && typeof funds.data.enabled === 'boolean', "Department funds: a department's card");

    // the list brings its totals when asked for them (the screen always asks)
    const two = await request<PaymentsView>('admin:getPayments', { page: 1, size: 25 });
    ok(two.ok && two.data && two.data.totals === undefined, 'without withTotals: no totals');
    const one = await request<PaymentsView>('admin:getPayments', { page: 1, size: 25, withTotals: true });
    ok(one.ok && one.data?.totals?.byStatus, 'withTotals: the totals come with the list');

    // H2: Retry all pending pays every online officer's pending money, so it takes two clicks (a ConfirmButton): the
    // first click only arms it, and nothing else on the screen calls it
    const calls = paymentsSrc.match(/retryPending\(\)/g) ?? [];
    ok(
        /<ConfirmButton(?:(?!\/>)[\s\S])*onConfirm=\{\(\) => void retryPending\(\)\}/.test(paymentsSrc) &&
            calls.length === 1,
        'Payments: Retry all pending runs only from the second click of a ConfirmButton',
    );

    // A paid or capped row with an admin money tool left part way offers Resolve with its own outcomes, each
    // through the confirm dialog, every outcome named in English
    const list = await request<PaymentsView>('admin:getPayments', { page: 1, size: 50 });
    const follow = list.data?.rows.find(r => r.followUp === 'rest');
    ok(follow !== undefined, 'Payments: a follow-up row is listed');
    const chk = await request<BankingCheck>('admin:checkBankingTxn', { rowId: follow?.id });
    ok(chk.ok && chk.data?.followUp === 'rest' && chk.data.outcomes?.restRelease === true, 'Resolve: its outcomes');
    ok(/r\.status === 'paying' \|\| r\.followUp\) out\.push\('resolve'\)/.test(paymentsSrc), 'Resolve shows for it');
    const outcomes = ['restPaid', 'restRelease', 'backTaken', 'backUndone', 'giveBack', 'giveBackDone'];
    ok(
        outcomes.every(o => t(`payments.followup.${o}`) !== `payments.followup.${o}`) &&
            outcomes.every(o => t(`payments.followup.${o}_msg`) !== `payments.followup.${o}_msg`),
        'every follow-up outcome has its English name and message',
    );
    ok(
        ['withdrawing', 'adding', 'review', 'refunding'].every(s => t(`payments.step.${s}`) !== `payments.step.${s}`),
        'the new step markers have their English text',
    );
    // Pay again stays offered after a cut or raised officer's deposit (the checked box is required); never at an
    // unknown department call or refund
    ok(
        /const UNKNOWN_STEPS = \['added', 'withdrawing', 'refunding'\];/.test(paymentsSrc),
        'Pay again: only added, withdrawing and refunding disable it',
    );
    // A Pay again left at its own 'withdrawing' or 'refunding' step: Resolve shows that step and offers Release only
    // when the server offers it (Pay again on), through the confirm dialog with its own checked box
    const stuck = await request<BankingCheck>('admin:checkBankingTxn', { rowId: 885 });
    ok(stuck.ok && stuck.data?.againStep === 'refunding', 'Resolve: the Pay again step is shown');
    ok(stuck.data?.againOutcomes == null, 'Resolve: no Release of a Pay again while Pay again is off');
    ok(
        /data\?\.againOutcomes\?\.againRelease !== undefined/.test(paymentsSrc) &&
            /disabled=\{data\.busy \|\| !data\.againOutcomes\.againRelease\}/.test(paymentsSrc) &&
            /mode === 'againRelease' \? \(\s*<Checkbox[\s\S]*?label=\{t\('payments\.resolve\.again_checked'\)\}/.test(
                paymentsSrc,
            ),
        'Release of a Pay again: offered by the server, confirmed with its checked box',
    );
    ok(
        ['again_release', 'again_release_msg', 'again_checked', 'again_step', 'again_released'].every(
            k => t(`payments.resolve.${k}`) !== `payments.resolve.${k}`,
        ),
        'Release of a Pay again has its English texts',
    );
}

export async function walk(): Promise<{ passed: number; failures: string[] }> {
    try {
        await steps();
    } catch (e) {
        failures.push(`stopped: ${e instanceof Error ? e.message : String(e)}`);
    }
    return { passed, failures };
}
