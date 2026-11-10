// The title inside an Admin UI screen: its plain name (the sidebar's and the breadcrumb's name, layouts/adminNav.ts).

import { t } from '../shared/i18n';
import { adminTitleKey } from './adminNav';

export function useAdminTitle(key: string): string {
    return t(adminTitleKey(key));
}
