// Src/builder · the Mission Builder component library (Supervisor UI → Mission Builder, Admin UI → Missions).

//   BuilderWorkspace  mission list + editor (the whole builder)
//   MissionList       drafts, tested, published and archived custom missions with status, version and lock
//   BuilderEditor     the step editor of one mission
// Protocol: docs/dev/ARCHITECTURE.md §5.28 · notes: docs/dev/ARCHITECTURE.md §5.28.7.

import './Builder.css';

export { BuilderWorkspace } from './BuilderWorkspace';
export type { BuilderWorkspaceProps } from './BuilderWorkspace';
export { MissionList, StatusBadge, LockBadge } from './MissionList';
export { BuilderEditor, STEPS } from './BuilderEditor';
export { useBuilderConfig } from './useBuilderConfig';
export { editorMemory, setEditorMemory } from './store';
export type { BuilderScope } from './store';
export { NEW_MISSION_PARAMS, asksNewMission } from './quickMission';
