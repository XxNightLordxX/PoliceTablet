// Supervisor UI · Mission Builder (screen key 'sup_builder', title key 'ui.screen.sup_builder').

import { useState } from 'react';
import { EmptyState, Screen } from '../../shared/components';
import { t } from '../../shared/i18n';
import { useCan } from '../../shared/session';
import { BuilderWorkspace, editorMemory } from '../../builder';

export default function SupBuilder() {
    const can = useCan();
    const [open, setOpen] = useState<string | null>(() => editorMemory('sup').openId);
    if (!can('builderEdit')) {
        return (
            <Screen title={t('ui.screen.sup_builder')}>
                <EmptyState
                    icon="lock"
                    title={t('builder.screen.no_access_title')}
                    text={t('builder.screen.no_access_text')}
                />
            </Screen>
        );
    }
    return (
        <Screen
            title={open ? undefined : t('ui.screen.sup_builder')}
            subtitle={open ? undefined : t('builder.screen.sup_subtitle')}
            className="builder_client-screen"
        >
            <BuilderWorkspace scope="sup" onOpenChange={setOpen} />
        </Screen>
    );
}
