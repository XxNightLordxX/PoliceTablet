// Admin UI → Money (Config.AdminUi.moneyScreen): Mission pay and Payments made as two tabs of one screen.
// Each tab is the old screen itself, with the same params (a Leaderboards link to stuck payments still filters).

// Admin UI · Money (screen key 'admin_money', Config.AdminUi.moneyScreen): Mission pay (admin/screens/Payouts)
// and Payments made (admin/screens/Payments) as two tabs of one screen, each the old screen itself with the same params.
// params.moneyTab ('pay' | 'payments') picks the tab; layouts/adminMoney.ts maps the old keys onto it.

import { useEffect, useState } from 'react';
import { Tabs } from '../../shared/components';
import { t } from '../../shared/i18n';
import { useNavigation } from '../../shared/navigation';
import { useSession } from '../../shared/session';
import { MONEY_SCREEN_OF, MONEY_TABS, moneyTabOf, type MoneyTab } from '../../layouts/adminMoney';
import { adminNavOf, adminTitleKey } from '../../layouts/adminNav';
import AdminPayments from './Payments';
import AdminPayouts from './Payouts';

export default function AdminMoney() {
    const { params } = useNavigation();
    const nav = adminNavOf(useSession());
    const [tab, setTab] = useState<MoneyTab>(moneyTabOf(params));
    // a link opened while the screen shows (Home tile, Needs attention, Leaderboards) picks its tab
    useEffect(() => setTab(moneyTabOf(params)), [params]);
    return (
        <>
            <Tabs<MoneyTab>
                className="admin-money__tabs"
                aria-label={t('admin.money.tabs')}
                value={tab}
                onChange={setTab}
                items={MONEY_TABS.map(k => ({ key: k, label: t(adminTitleKey(MONEY_SCREEN_OF[k], nav)) }))}
            />
            {tab === 'pay' ? <AdminPayouts key="pay" /> : <AdminPayments key="payments" />}
        </>
    );
}
