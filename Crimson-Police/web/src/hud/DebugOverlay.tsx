// Test-mode debug overlay (live NPC/entity counts against the caps, etc.). STUB: the testing slice
// replaces this whole file.
//
// Props: { debug, hud }
//   debug — the `debug` field of the last `push` message with topic 'test' (the data of
//           crimson-police:client:test { controls, debug }), passed through untouched; null = hidden.
//   hud   — the current HudState or null.
// Rendered by App at all times (outside the tablet, no NUI focus); return null when there is nothing to show.
import type { HudState } from '../shared/types';

export interface DebugOverlayProps {
  debug: unknown;
  hud: HudState | null;
}

export default function DebugOverlay(_props: DebugOverlayProps) {
  return null;
}
