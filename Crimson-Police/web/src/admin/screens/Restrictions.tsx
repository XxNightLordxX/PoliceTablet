// Admin UI · Restrictions (screen key 'admin_restrictions'): every restriction running now in one list (tablet
// suspensions, mission bans, the Real suspects pair blocks, exclusions and suspensions, volunteers' strikes blocks)
// with Extend and Lift (admin/components/RestrictionsPanel.tsx, scope 'admin').

import { Screen } from '../../shared/components';
import { RestrictionsPanel } from '../components/RestrictionsPanel';

export default function AdminRestrictions() {
    return (
        <Screen head="admin_restrictions">
            <RestrictionsPanel scope="admin" />
        </Screen>
    );
}
