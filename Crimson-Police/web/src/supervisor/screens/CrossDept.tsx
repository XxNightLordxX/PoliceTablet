// Supervisor UI · Cross-Department Mission (screen key 'sup_crossdept', title key 'ui.screen.sup_crossdept').
// STUB: the owner of this screen replaces this whole file. Contract:
//   - default-export a component that takes no props;
//   - get data with hooks: useSession(), useRequest(), useAction(), usePush(), t(), useNavigate();
//   - wrap the content in <Screen title={t('ui.screen.sup_crossdept')}> from ../../shared/components;
//   - browser mocks go in src/mocks/<feature>.mock.ts, text in locales/parts/<slice>.json.
import { ScreenStub } from '../../shared/components';

export default function SupCrossDept() {
  return <ScreenStub titleKey="ui.screen.sup_crossdept" icon="globe" />;
}
