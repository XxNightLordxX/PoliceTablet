// src/builder/BuilderWorkspace.tsx · the Mission Builder as one block: the mission list, or the editor of the
// open mission. Used by Supervisor UI → Mission Builder and Admin UI → Missions → Builder. The open mission and
// step live in the module store (store.ts), so the editor comes back after a tool closed and reopened the tablet.
import { useEffect, useState } from 'react';
import { Button, EmptyState, ErrorState, LoadingBlock } from '../shared/components';
import { t } from '../shared/i18n';
import { BuilderEditor } from './BuilderEditor';
import { MissionList } from './MissionList';
import { editorMemory, hasResults, setEditorMemory, subscribeBuilder, currentTool, type BuilderScope } from './store';
import { useBuilderConfig } from './useBuilderConfig';

export interface BuilderWorkspaceProps {
  scope: BuilderScope;
  /** called when a mission is opened or closed (the admin screen switches tabs) */
  onOpenChange?: (id: string | null) => void;
}

export function BuilderWorkspace({ scope, onOpenChange }: BuilderWorkspaceProps) {
  const { config, error, retry } = useBuilderConfig(scope);
  const [openId, setOpenId] = useState<string | null>(() => editorMemory(scope).openId);

  // a tool result for a mission that is not open (e.g. the NUI reloaded): open it so it can be applied
  useEffect(() => subscribeBuilder(() => {
    const mem = editorMemory(scope);
    const tool = currentTool();
    if (!mem.openId && tool && tool.scope === scope && hasResults(tool.missionId)) {
      setEditorMemory(scope, { openId: tool.missionId, step: 'locations', location: tool.location });
      setOpenId(tool.missionId);
      onOpenChange?.(tool.missionId);
    }
  }), [scope, onOpenChange]);

  const open = (id: string) => {
    setEditorMemory(scope, { openId: id });
    setOpenId(id);
    onOpenChange?.(id);
  };
  const close = () => {
    setEditorMemory(scope, { openId: null, step: 'blocks', location: 1, objective: 1 });
    setOpenId(null);
    onOpenChange?.(null);
  };

  if (!config) {
    return error ? <ErrorState error={error} onRetry={retry} /> : <LoadingBlock />;
  }
  if (config.enabled === false) {
    return <EmptyState icon="tool" title={t('builder.disabled_title')} text={t('err.builder_disabled')} action={<Button variant="secondary" icon="refresh" onClick={retry}>{t('builder.retry')}</Button>} />;
  }
  if (openId) {
    return (
      <BuilderEditor
        key={openId}
        id={openId}
        scope={scope}
        config={config}
        onClose={close}
        onOpen={open}
        onRenamed={(id) => {
          setEditorMemory(scope, { openId: id });
          setOpenId(id);
          onOpenChange?.(id);
        }}
      />
    );
  }
  return <MissionList scope={scope} config={config} onOpen={open} />;
}
