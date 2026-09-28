// Admin UI · Seasons & Challenge (screen key 'admin_seasons', title key 'ui.screen.admin_seasons').
// STUB: the owner of this screen replaces this whole file. Contract:
//   - default-export a component that takes no props;
//   - get data with hooks: useSession(), useRequest(), useAction(), usePush(), t(), useNavigate();
//   - wrap the content in <Screen title={t('ui.screen.admin_seasons')}> from ../../shared/components;
//   - browser mocks go in src/mocks/<feature>.mock.ts, text in locales/parts/<slice>.json.
import { ScreenStub } from '../../shared/components';

export default function AdminSeasons() {
  return <ScreenStub titleKey="ui.screen.admin_seasons" icon="calendar" />;
}
