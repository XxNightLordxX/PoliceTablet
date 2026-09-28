// Mission Builder in-world overlays (placement tool, route recording, test drive). STUB: the
// builder slice replaces this whole file.
//
// Props: { overlay }  — the `overlay` message payload whose kind is 'placement' | 'recording' |
// 'testdrive' (any extra builder-specific fields the Lua builder sends are on the same object).
// Rendered full-screen by App while such an overlay is set; the tablet is closed at that time.
import type { Overlay } from '../shared/types';

export interface BuilderOverlayProps {
  overlay: Overlay;
}

export default function BuilderOverlay(_props: BuilderOverlayProps) {
  return null;
}
