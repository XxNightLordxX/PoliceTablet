// Supervisor UI · Cross-Department Mission (screen key 'sup_crossdept', title key 'ui.screen.sup_crossdept').
// The active operation (mission, launcher, joined participants by department, tier, status) with Start now,
// Relaunch after a fail and Cancel, or the launch form when none is active. Everything lives in the
// reusable OperationPanel (also used by the Admin UI → Missions screen); this screen uses the supervisor
// actions server:sup:op*. Visible with the launchCrossDept permission (screen registry).
import { Screen } from '../../shared/components';
import { t } from '../../shared/i18n';
import OperationPanel from '../components/OperationPanel';

export default function SupCrossDept() {
  return (
    <Screen title={t('ui.screen.sup_crossdept')} subtitle={t('sup.crossdept.screen_subtitle')}>
      <OperationPanel scope="sup" />
    </Screen>
  );
}
