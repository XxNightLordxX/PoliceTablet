// The Money screen: every money screen of the Admin UI as tabs of one screen (Pay rates, Rewards, Payments and
// Department funds). A link to a tab is navigate('admin_money', { moneyTab: 'pay' | 'rewards' | 'payments' | 'funds' }).

// The Money screen: every money screen of the Admin UI as tabs of one screen (Pay rates, Rewards, Payments and
// Department funds). A link to a tab is navigate('admin_money', { moneyTab: 'pay' | 'rewards' | 'payments' | 'funds' }).
// moneyTabOf(params) picks the tab; moneySearchWords are the words the screen search finds Money by. adminMoney.walk.ts
// checks it against the mocks, with the totals on admin:getPayments.

import { t } from '../shared/i18n';
import type { ScreenParams } from '../shared/navigation';

export type MoneyTab = 'pay' | 'rewards' | 'payments' | 'funds';
export const MONEY_TABS: MoneyTab[] = ['pay', 'rewards', 'payments', 'funds'];

// The title key of each tab's part (its own heading inside the tab): ui.nav.plain.<key>.
export const MONEY_TITLES: Record<Exclude<MoneyTab, 'funds'>, string> = {
    pay: 'admin_payouts',
    rewards: 'admin_rewards',
    payments: 'admin_payments',
};

// The tab the Money screen shows for its params (Pay rates unless another tab is asked for).
export function moneyTabOf(params: ScreenParams | null | undefined): MoneyTab {
    const asked = params?.moneyTab;
    return typeof asked === 'string' && (MONEY_TABS as string[]).includes(asked) ? (asked as MoneyTab) : 'pay';
}

// The words the screen search finds Money by: each tab's name and each part's title (Payouts, Rewards, Payments).
export function moneySearchWords(): string[] {
    const words = MONEY_TABS.map(k => t(`admin.money.tab.${k}`));
    for (const key of Object.values(MONEY_TITLES)) words.push(t(`ui.screen.${key}`), t(`ui.nav.plain.${key}`));
    return words;
}
