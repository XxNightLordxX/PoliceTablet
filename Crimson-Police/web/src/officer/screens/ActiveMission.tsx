// Officer UI · Active Mission (screen key 'active', title key 'ui.screen.active').
// STUB: the owner of this screen replaces this whole file. Contract:
//   - default-export a component that takes no props;
//   - get data with hooks: useSession(), useRequest(), useAction(), usePush(), t(), useNavigate();
//   - wrap the content in <Screen title={t('ui.screen.active')}> from ../../shared/components;
//   - browser mocks go in src/mocks/<feature>.mock.ts, text in locales/parts/<slice>.json.
import { ScreenStub } from '../../shared/components';

export default function ActiveMission() {
  return <ScreenStub titleKey="ui.screen.active" icon="target" />;
}
