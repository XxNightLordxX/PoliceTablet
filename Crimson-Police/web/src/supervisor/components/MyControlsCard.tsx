// Supervisor UI · Department → Controls · Used from their own buttons (MG3): each action control this supervisor may
// use now (Give points, Mission ban, notices ...), the admin's limits and today's use against the per-day count.

// Supervisor UI · Department → Controls · Used from their own buttons (MG3): each action control this supervisor may
// use now (Give points, Mission ban, notices ...), the admin's limits and today's use against the per-day count.
// Read only: the rows come from sup:getMyControls (CP.DeptControls.mine, live on push 'missionControls'), read once
// by MissionControls.tsx, which also shows the same limits and today's use inline on each value control's row.
// Rows: myControls.ts (actionControlRows). Walk: supervisor/screens/supHead.walk.ts.

import { Badge, Card, Table, type TableColumn } from '../../shared/components';
import { t } from '../../shared/i18n';
import { controlName } from '../../admin/components/MissionControlsCard';
import type { MyControlRow } from './myControls';

export function ActionControlsCard({ rows }: { rows: MyControlRow[] }) {
    if (rows.length === 0) return null;
    const columns: TableColumn<MyControlRow>[] = [
        { key: 'control', header: t('sup.mine.col.control'), render: r => <strong>{controlName(r.key)}</strong> },
        {
            key: 'limits',
            header: t('sup.mine.col.limits'),
            width: 120,
            render: r =>
                r.limits ? (
                    <span className="cp-num">{t('sup.mine.limits', { min: r.limits.min, max: r.limits.max })}</span>
                ) : (
                    <span className="sup-mc-row__who">{t('sup.mine.no_limits')}</span>
                ),
        },
        {
            key: 'today',
            header: t('sup.mine.col.today'),
            width: 130,
            render: r =>
                r.today === 'none' ? (
                    <span className="sup-mc-row__who">{t('sup.mine.no_count')}</span>
                ) : (
                    <Badge size="sm" tone={r.today === 'used' ? 'danger' : 'success'}>
                        {t('sup.mine.used', { used: r.used, n: r.perDay })}
                    </Badge>
                ),
        },
    ];
    return (
        <Card title={t('sup.mine.actions_title')} subtitle={t('sup.mine.actions_subtitle')} icon="clock">
            <Table columns={columns} rows={rows} rowKey={r => r.key} aria-label={t('sup.mine.actions_title')} />
        </Card>
    );
}
