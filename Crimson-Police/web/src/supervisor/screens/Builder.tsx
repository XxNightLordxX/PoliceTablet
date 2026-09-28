// Supervisor UI · Mission Builder (screen key 'sup_builder', title key 'ui.screen.sup_builder').
// The supervisor's drafts plus the published and archived custom missions (builder:list), and the step editor
// (src/builder). Actions follow session.actions: builderEdit (build, record routes, test their own missions),
// builderPublish, builderArchive, builderEditAny (other people's missions), builderRollback, breakEditLock —
// the server re-checks every one (docs/notes/builder_protocol.md §2). Placement, route recording and test
// drives close the tablet (modules/builder/client.lua) and reopen it here when they end.
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
        <EmptyState icon="lock" title={t('builder.screen.no_access_title')} text={t('builder.screen.no_access_text')} />
      </Screen>
    );
  }
  return (
    <Screen title={open ? undefined : t('ui.screen.sup_builder')} subtitle={open ? undefined : t('builder.screen.sup_subtitle')} className="builder_client-screen">
      <BuilderWorkspace scope="sup" onOpenChange={setOpen} />
    </Screen>
  );
}
