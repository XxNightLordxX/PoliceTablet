// The Money screen (Config.AdminUi.moneyScreen): Mission pay and Payments made as two tabs of one screen.
// The old screen keys stay as aliases: navigating to admin_payouts or admin_payments opens admin_money on that tab,
// so saved links, Home tiles, Needs attention lines and a landing of 'payouts' keep working.

// The Money screen's keys (Config.AdminUi.moneyScreen): moneyScreenOn(session), resolveAdminKey (with the
// switch on, admin_payouts and admin_payments open admin_money on their tab, params kept; used by App's navigate, the
// 'open' message and the Admin landing) and moneyTabOf(params). adminMoney.walk.ts checks it against the mocks, with
// oneRequest's totals on admin:getPayments.

import type { ScreenKey, ScreenParams } from '../shared/navigation';
import type { Session } from '../shared/types';

export type MoneyTab = 'pay' | 'payments';
export const MONEY_TABS: MoneyTab[] = ['pay', 'payments'];

// The old screen of each tab (its title, its component and its sidebar badge).
export const MONEY_SCREEN_OF: Record<MoneyTab, 'admin_payouts' | 'admin_payments'> = {
    pay: 'admin_payouts',
    payments: 'admin_payments',
};

const ALIASES: Record<string, MoneyTab> = { admin_payouts: 'pay', admin_payments: 'payments' };

// The session's switch; an older session or anything but true = two screens as before.
export function moneyScreenOn(session: Session | null | undefined): boolean {
    return session?.config?.adminUi?.moneyScreen === true;
}

// The screen a key opens: with the Money screen on, an old key opens admin_money on its tab (params kept); else the
// key itself.
export function resolveAdminKey(
    key: ScreenKey,
    params: ScreenParams | undefined,
    session: Session | null | undefined,
): { key: ScreenKey; params: ScreenParams } {
    const tab = ALIASES[key];
    if (!tab || !moneyScreenOn(session)) return { key, params: params ?? {} };
    return { key: 'admin_money', params: { ...(params ?? {}), moneyTab: tab } };
}

// The tab the Money screen shows for its params (Mission pay unless Payments made is asked for).
export function moneyTabOf(params: ScreenParams | null | undefined): MoneyTab {
    return params?.moneyTab === 'payments' ? 'payments' : 'pay';
}
