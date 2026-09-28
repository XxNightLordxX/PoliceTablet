// HUD test controls (Admin test mode). STUB: the testing slice replaces this whole file.
//
// Props: { hud: HudState }  — rendered by <Hud/> under the objectives only when hud.testControls is
// true (the admin who started the test). The HUD has no NUI focus by default; the Lua testing client
// gives focus with the +crimsonpolice_testpanel key (F9). Controls call
//   action('server:test:control', { control: 'skip' | 'restart' | 'pause' | 'complete' | 'fail' | 'end' | 'teleport', ... })
// Text keys go in locales/parts/<slice>.json (test.*).
import type { HudState } from '../shared/types';

export interface TestControlsProps {
  hud: HudState;
}

export default function TestControls(_props: TestControlsProps) {
  return null;
}
