// Supervisor UI · Department Report · Your controls today (Config.Tablet.supervisorControlsCard): each
// Mission control this supervisor may use now, its current value, the admin's limits and today's use against the
// per-day count. Read only (sup:getMyControls); the controls are changed on Mission controls or their own dialogs.

// Supervisor UI · Department Report · Your controls today (Config.Tablet.supervisorControlsCard, session
// config.supervisorNav.controlsCard): sup:getMyControls (CP.DeptControls.mine, live on push 'missionControls') lists
// each control this player may use now with the value in use, the admin's min and max and today's use against the
// per-day count (a control's usedToday function). Read only. Rows: myControls.ts (myControlRow, myControlRows: the
// most used up first). Walk: supervisor/screens/supHead.walk.ts.

import { Badge, Card, EmptyState, Table, type TableColumn } from '../../shared/components';
import { useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { useSession } from '../../shared/session';
import type { MyControlsView } from '../../types/oversight';
import { controlName, useValueText } from '../../admin/components/MissionControlsCard';
import { ScreenStatus } from '../../officer/components/ScreenStatus';
import { screenStateOf } from '../../officer/screens/screenHead';
import { controlsCardOn, myControlRows, type MyControlRow } from './myControls';

export function MyControlsCard() {
    const session = useSession();
    const on = controlsCardOn(session);
    const { data, loading, error, refetch } = useRequest<MyControlsView>(
        'sup:getMyControls',
        {},
        { skip: !on, pushTopic: 'missionControls' },
    );
    const text = useValueText();
    if (!on) return null;
    const list = data?.controls;
    const byKey = new Map((Array.isArray(list) ? list : []).map(c => [c.key, c]));
    const rows = myControlRows(list);
    const state = screenStateOf(!!data, loading, error);

    const columns: TableColumn<MyControlRow>[] = [
        { key: 'control', header: t('sup.mine.col.control'), render: r => <strong>{controlName(r.key)}</strong> },
        {
            key: 'value',
            header: t('sup.mine.col.value'),
            render: r =>
                r.action ? (
                    <span className="sup-mc-row__who">{t('sup.mine.action')}</span>
                ) : (
                    <span>
                        {text(r.key, byKey.get(r.key)?.value)}{' '}
                        <Badge size="sm" tone={r.changed ? 'warning' : 'neutral'}>
                            {t(r.changed ? 'sup.mine.changed' : 'sup.mine.config')}
                        </Badge>
                    </span>
                ),
        },
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
        <Card title={t('sup.mine.title')} subtitle={t('sup.mine.subtitle')} icon="clock">
            <ScreenStatus state={state} error={error} onRetry={() => void refetch()} />
            {state === 'ready' || state === 'stale' ? (
                <Table
                    columns={columns}
                    rows={rows}
                    rowKey={r => r.key}
                    empty={<EmptyState compact icon="clock" title={t('sup.mine.none')} />}
                    aria-label={t('sup.mine.title')}
                />
            ) : null}
        </Card>
    );
}
