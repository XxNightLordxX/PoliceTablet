// Admin UI → Money: Pay rates, Rewards, Payments and Department funds as four tabs of one screen.
// Each tab is the old screen itself, with the same params (a Leaderboards link to stuck payments still filters).

// Admin UI · Money (screen key 'admin_money'): Pay rates (admin/screens/Payouts), Rewards (admin/screens/Rewards),
// Payments (admin/screens/Payments) and Department funds (admin/components/MoneyFunds), each the old screen itself
// with the same params. params.moneyTab picks the tab; layouts/adminMoney.ts maps the old keys onto it.

import { useEffect, useState } from 'react';
import { Tabs } from '../../shared/components';
import { t } from '../../shared/i18n';
import { useNavigation } from '../../shared/navigation';
import { MONEY_TABS, moneyTabOf, type MoneyTab } from '../../layouts/adminMoney';
import { MoneyFunds } from '../components/MoneyFunds';
import AdminPayments from './Payments';
import AdminPayouts from './Payouts';
import AdminRewards from './Rewards';

function TabBody({ tab }: { tab: MoneyTab }) {
    switch (tab) {
        case 'rewards':
            return <AdminRewards key="rewards" />;
        case 'payments':
            return <AdminPayments key="payments" />;
        case 'funds':
            return <MoneyFunds key="funds" />;
        default:
            return <AdminPayouts key="pay" />;
    }
}

export default function AdminMoney() {
    const { params } = useNavigation();
    const [tab, setTab] = useState<MoneyTab>(moneyTabOf(params));
    // a link opened while the screen shows (Home's tiles, Leaderboards) picks its tab
    useEffect(() => setTab(moneyTabOf(params)), [params]);
    return (
        <>
            <Tabs<MoneyTab>
                className="admin-money__tabs"
                aria-label={t('admin.money.tabs')}
                value={tab}
                onChange={setTab}
                items={MONEY_TABS.map(k => ({ key: k, label: t(`admin.money.tab.${k}`) }))}
            />
            <TabBody tab={tab} />
        </>
    );
}
