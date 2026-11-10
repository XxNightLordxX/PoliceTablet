// The Money screen: every money screen of the Admin UI as tabs of one screen (Pay rates, Rewards, Payments and

// The Money screen: every money screen of the Admin UI as tabs of one screen (Pay rates, Rewards, Payments and
// Department funds). The old screen keys stay as aliases: navigating to admin_payouts, admin_rewards or
// admin_payments opens admin_money on that tab, so saved links, Home tiles, Needs attention lines and a landing of
// 'payouts' keep working.

// The Money screen's keys: resolveAdminKey (admin_payouts, admin_rewards and admin_payments open admin_money on their
// tab, params kept; used by App's navigate, the 'open' message and the Admin landing), moneyTabOf(params) and the
// words the plain layout's search finds Money by. adminMoney.walk.ts checks it against the mocks, with oneRequest's
// totals on admin:getPayments.

import { t } from '../shared/i18n';
import type { ScreenKey, ScreenParams } from '../shared/navigation';
import type { Session } from '../shared/types';

export type MoneyTab = 'pay' | 'rewards' | 'payments' | 'funds';
export const MONEY_TABS: MoneyTab[] = ['pay', 'rewards', 'payments', 'funds'];

// The old screen key that opens each tab (Department funds never had a screen of its own).
export const MONEY_ALIASES: Record<string, MoneyTab> = {
    admin_payouts: 'pay',
    admin_rewards: 'rewards',
    admin_payments: 'payments',
};

// The screen a key opens: an old money key opens admin_money on its tab (params kept), the Mission blips key opens
// Map markers, else the key itself. The session is not needed any more (kept for the callers).
export function resolveAdminKey(
    key: ScreenKey,
    params: ScreenParams | undefined,
    _session?: Session | null,
): { key: ScreenKey; params: ScreenParams } {
    // the Mission blips screen is a part of Map markers now: its old key opens Map markers
    if (key === 'admin_blips') return { key: 'admin_markers', params: params ?? {} };
    const tab = MONEY_ALIASES[key];
    if (!tab) return { key, params: params ?? {} };
    return { key: 'admin_money', params: { ...(params ?? {}), moneyTab: tab } };
}

// The tab the Money screen shows for its params (Pay rates unless another tab is asked for).
export function moneyTabOf(params: ScreenParams | null | undefined): MoneyTab {
    const asked = params?.moneyTab;
    return typeof asked === 'string' && (MONEY_TABS as string[]).includes(asked) ? (asked as MoneyTab) : 'pay';
}

// The words the plain layout's search finds Money by: each tab's name and the old screens' names.
export function moneySearchWords(): string[] {
    const words = MONEY_TABS.map(k => t(`admin.money.tab.${k}`));
    for (const key of Object.keys(MONEY_ALIASES)) words.push(t(`ui.screen.${key}`), t(`ui.nav.plain.${key}`));
    return words;
}
