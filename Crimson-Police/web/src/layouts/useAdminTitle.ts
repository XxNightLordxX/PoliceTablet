// The title inside an Admin UI screen: its plain name while Config.AdminUi.plainLayout is on (the sidebar's
// and the breadcrumb's name, layouts/adminNav.ts), else ui.screen.<key> as before.

import { t } from '../shared/i18n';
import { useSession } from '../shared/session';
import { adminNavOf, adminTitleKey } from './adminNav';

export function useAdminTitle(key: string): string {
    return t(adminTitleKey(key, adminNavOf(useSession())));
}
