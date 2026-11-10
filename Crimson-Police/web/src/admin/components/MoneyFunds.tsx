// Admin UI → Money → Department funds: each department's Funds card (the same card as on Departments), one per
// department, with its balance, what it paid, unfunded rows, admin funding and Add funds (ships off).

import { Card, EmptyState, ErrorState, Grid, LoadingBlock, Screen } from '../../shared/components';
import { asArray } from '../../shared/data';
import { useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import type { DepartmentsData } from '../../types/oversight';
import { DepartmentFunds } from './DepartmentFunds';

export function MoneyFunds() {
    const { data, loading, error, refetch } = useRequest<DepartmentsData>('admin:getDepartments', {});
    const departments = asArray(data?.departments);
    let body;
    if (loading && !data) body = <LoadingBlock />;
    else if (error && !data)
        body = (
            <Card>
                <ErrorState error={error} onRetry={() => void refetch()} />
            </Card>
        );
    else if (!departments.length)
        body = (
            <Card padding="none">
                <EmptyState icon="building" title={t('admin.depts.empty')} />
            </Card>
        );
    else
        body = (
            <Grid min={380} gap={4} align="start">
                {departments.map(d => (
                    <Card key={d.key} title={d.label} icon="building">
                        <DepartmentFunds department={d.key} />
                    </Card>
                ))}
            </Grid>
        );
    return (
        <Screen title={t('admin.money.tab.funds')} subtitle={t('admin.money.funds_help')}>
            {body}
        </Screen>
    );
}
