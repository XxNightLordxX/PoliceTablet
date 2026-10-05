// Supervisor UI · Cross-Department Mission (screen key 'sup_crossdept', title key 'ui.screen.sup_crossdept').

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
