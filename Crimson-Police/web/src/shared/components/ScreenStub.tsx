import { t } from '../i18n';
import { Screen } from './Card';
import { EmptyState } from './Feedback';
import type { IconName } from './Icon';

// Placeholder rendered by every screen file until its owner replaces it.
export function ScreenStub({ titleKey, icon = 'hammer' }: { titleKey: string; icon?: IconName }) {
    return (
        <Screen title={t(titleKey)}>
            <EmptyState icon={icon} title={t('ui.stub.title')} text={t('ui.stub.text')} />
        </Screen>
    );
}
