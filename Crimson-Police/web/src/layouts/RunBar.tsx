// The officer's current run, pinned above every Officer UI screen while a run is active.
// Data: request 'getRun' (ActiveMissionView or null), refetched on push topic 'run'. Click → Active Mission.
import { Badge, Countdown, Icon, TierBadge } from '../shared/components';
import { cx } from '../shared/cx';
import { asArray } from '../shared/data';
import { formatDistance } from '../shared/format';
import { useCountdown, usePush, useRequest } from '../shared/hooks';
import { t } from '../shared/i18n';
import { useNavigation } from '../shared/navigation';
import type { ActiveMissionView } from '../shared/types';

function RouteStatus({ route }: { route: ActiveMissionView['route'] }) {
  const left = useCountdown(route?.status === 'off' ? route.secondsLeft : null);
  if (!route) return null;
  if (route.status === 'off') {
    return (
      <span className="cp-runbar__status is-warning">
        <Icon name="alert" size={14} />
        {left !== null ? t('ui.runbar.off_route', { seconds: left }) : t('hud.route.off_nolimit')}
      </span>
    );
  }
  if (route.status === 'on') {
    return (
      <span className="cp-runbar__status is-ok">
        <Icon name="navigation" size={13} />
        {route.distance !== null && route.distance !== undefined
          ? t('ui.runbar.on_route_distance', { distance: formatDistance(route.distance) })
          : t('hud.route.on')}
      </span>
    );
  }
  if (route.status === 'arrived') {
    return (
      <span className="cp-runbar__status is-ok">
        <Icon name="mapPin" size={13} />
        {t('hud.route.arrived')}
      </span>
    );
  }
  return <span className="cp-runbar__status">{t('hud.route.disabled')}</span>;
}

export function RunBar() {
  const { data, error, setData } = useRequest<ActiveMissionView | null>('getRun', {}, { pushTopic: 'run' });
  const { navigate, screen } = useNavigation();
  // A 'run' push carrying the view applies at once; the refetch confirms it. The end of the run is
  // CP.Tablet.push(src, 'run', nil): Lua drops the nil field, so `data` arrives missing (undefined), not null.
  usePush<ActiveMissionView | null | undefined>('run', (view) => {
    if (view === null || view === undefined) setData(null);
    else if (typeof view === 'object' && typeof view.runId === 'string') setData(view);
  });
  if (error || !data || !data.runId) return null;

  const objectives = asArray(data.objectives);
  const done = objectives.filter((o) => o.done).length;
  const total = objectives.length;
  const inProgress = data.state === 'in_progress';

  return (
    <button
      type="button"
      className={cx('cp-runbar', screen === 'active' && 'is-current', data.test && 'is-test')}
      onClick={() => navigate('active')}
      aria-label={t('ui.runbar.open')}
    >
      <span className={cx('cp-runbar__pulse', inProgress && 'is-live')} aria-hidden />
      <span className="cp-runbar__main">
        <span className="cp-runbar__eyebrow">
          {data.test ? <Badge tone="warning" variant="solid" size="sm">{t('hud.test_run')}</Badge> : null}
          {inProgress ? t('ui.runbar.in_progress') : t('ui.runbar.en_route')}
        </span>
        <span className="cp-runbar__title">{data.missionLabel}</span>
      </span>
      <span className="cp-runbar__meta">
        <TierBadge tier={data.tier} expected={data.tierExpected} size="sm" />
        {inProgress ? (
          <span className="cp-runbar__status">
            <Icon name="checkCircle" size={13} />
            {t('ui.runbar.objectives', { done, total })}
          </span>
        ) : (
          <RouteStatus route={data.route} />
        )}
        {data.remaining !== null && data.remaining !== undefined ? (
          <span className="cp-runbar__timer">
            <Icon name="clock" size={14} />
            <Countdown seconds={data.remaining} paused={data.paused} warnBelow={60} dangerBelow={15} />
          </span>
        ) : null}
      </span>
      <span className="cp-runbar__open">
        {t('ui.runbar.view')}
        <Icon name="chevronRight" size={15} />
      </span>
    </button>
  );
}
