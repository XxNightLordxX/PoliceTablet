// Admin UI · Permissions (screen key 'admin_permissions', title key 'ui.screen.admin_permissions').
// STUB: the owner of this screen replaces this whole file. Contract:
//   - default-export a component that takes no props;
//   - get data with hooks: useSession(), useRequest(), useAction(), usePush(), t(), useNavigate();
//   - wrap the content in <Screen title={t('ui.screen.admin_permissions')}> from ../../shared/components;
//   - browser mocks go in src/mocks/<feature>.mock.ts, text in locales/parts/<slice>.json.
import { ScreenStub } from '../../shared/components';

export default function AdminPermissions() {
  return <ScreenStub titleKey="ui.screen.admin_permissions" icon="key" />;
}
