// Slot: Departments → each department's Funds card: the society account's balance (shown even while the cash
// source is the server), what it paid, unfunded rows, admin funding and Add funds (ships off).

import { useState } from 'react';
import { Badge, Button, ConfirmDialog, Field, KeyValue, Money, NumberInput } from '../../shared/components';
import { formatDateTime, formatMoney } from '../../shared/format';
import { useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import type { DepartmentSlotProps } from '../../types/admin_control';
import type { DepartmentFundsView } from '../../types/admin_economy';
import { MoneyEffect, useAdminAction } from './kit';
import './DepartmentFunds.css';

export function DepartmentFunds({ department }: DepartmentSlotProps) {
    const { data, refetch } = useRequest<DepartmentFundsView>('admin:getDepartmentFunds', { department });
    const [adding, setAdding] = useState(false);
    const [amount, setAmount] = useState<number | null>(null);
    const { run } = useAdminAction();
    if (!data) return null;
    const low = data.balance != null && data.lowBalanceWarn > 0 && data.balance < data.lowBalanceWarn;

    const add = async (reason: string, typed: string) => {
        const res = await run(
            'server:admin:addDepartmentFunds',
            { department, amount, reason, confirm: typed },
            { success: 'funds.added', successVars: { amount: formatMoney(amount ?? 0) } },
        );
        if (res.ok) {
            setAdding(false);
            setAmount(null);
            void refetch();
        }
    };

    return (
        <div className="dept-funds">
            <div className="dept-funds__head">
                <strong>{t('funds.title')}</strong>
                {data.source !== 'society' ? (
                    <Badge size="sm" tone="neutral">
                        {t('funds.not_used')}
                    </Badge>
                ) : null}
                {!data.enabled ? (
                    <Badge size="sm" tone="warning">
                        {t('funds.turned_off')}
                    </Badge>
                ) : null}
            </div>
            <div className="dept-funds__grid">
                <KeyValue label={t('funds.balance', { account: data.account })}>
                    {data.balance == null ? (
                        <Badge size="sm" tone="danger">
                            {t('funds.no_account')}
                        </Badge>
                    ) : (
                        <span className={low ? 'dept-funds__low' : undefined}>
                            <Money amount={data.balance} />
                        </span>
                    )}
                </KeyValue>
                <KeyValue label={t('funds.spent_today')}>
                    <Money amount={data.spent.today} />
                </KeyValue>
                <KeyValue label={t('funds.spent_week')}>
                    <Money amount={data.spent.week} />
                </KeyValue>
                {data.spent.season != null ? (
                    <KeyValue label={t('funds.spent_season')}>
                        <Money amount={data.spent.season} />
                    </KeyValue>
                ) : null}
                <KeyValue label={t('funds.unfunded')}>
                    <span className="cp-num">{data.unfunded}</span>
                </KeyValue>
                <KeyValue label={t('funds.funded')}>
                    <Money amount={data.funded} />
                </KeyValue>
            </div>
            {data.recent.length > 0 ? (
                <ul className="dept-funds__recent">
                    {data.recent.map(r => (
                        <li key={r.id}>
                            <span className="cp-num">{formatDateTime(r.at)}</span>
                            <Money amount={r.amount} />
                            <Badge
                                size="sm"
                                tone={r.state === 'done' ? 'success' : r.state === 'failed' ? 'danger' : 'warning'}
                            >
                                {t(`funds.state.${r.state}`)}
                            </Badge>
                            {r.txn ? <code className="cp-selectable">{r.txn}</code> : null}
                        </li>
                    ))}
                </ul>
            ) : null}
            {data.allowAddFunds ? (
                <Button size="sm" variant="danger" icon="plus" onClick={() => setAdding(true)}>
                    {t('funds.add')}
                </Button>
            ) : null}
            <ConfirmDialog
                open={adding}
                title={t('funds.add_title', { department: data.label })}
                message={t('funds.add_msg', { account: data.account, max: formatMoney(data.addFundsMax) })}
                effect={
                    <>
                        <Field label={t('funds.amount')} required>
                            <NumberInput
                                value={amount}
                                onChange={setAmount}
                                min={1}
                                max={data.addFundsMax}
                                prefix="$"
                                formatRange={formatMoney}
                            />
                        </Field>
                        <MoneyEffect
                            lines={[
                                {
                                    label: t('funds.after'),
                                    amount: (data.balance ?? 0) + (amount ?? 0),
                                    before: data.balance ?? undefined,
                                },
                            ]}
                        />
                    </>
                }
                typedWord={amount ? String(amount) : '-'}
                tone="danger"
                reason={{ required: true, maxLength: 255 }}
                onConfirm={add}
                onCancel={() => setAdding(false)}
            />
        </div>
    );
}
