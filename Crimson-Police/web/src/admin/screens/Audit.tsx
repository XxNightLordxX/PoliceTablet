// Admin UI · Audit Log (screen key 'admin_audit', title key 'ui.screen.admin_audit').
// STUB: the owner of this screen replaces this whole file. Contract:
//   - default-export a component that takes no props;
//   - get data with hooks: useSession(), useRequest(), useAction(), usePush(), t(), useNavigate();
//   - wrap the content in <Screen title={t('ui.screen.admin_audit')}> from ../../shared/components;
//   - browser mocks go in src/mocks/<feature>.mock.ts, text in locales/parts/<slice>.json.
import { ScreenStub } from '../../shared/components';

export default function AdminAudit() {
  return <ScreenStub titleKey="ui.screen.admin_audit" icon="fileText" />;
}
