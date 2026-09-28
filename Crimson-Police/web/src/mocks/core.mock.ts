// Core browser mocks: sessions for the three UIs, the pinned run (fallback) and logo reports.
import { registerMock } from '../shared/nui';
import type { UiKind } from '../shared/types';
import { devState } from './devState';
import { buildSession, sampleRun } from './samples';

registerMock('request', 'getSession', (args: { ui?: UiKind } | null) => buildSession(args?.ui ?? 'officer'));

// Fallback: the Active Mission feature may register a richer 'getRun' in its own mock file.
registerMock('request', 'getRun', () => (devState.runActive ? sampleRun() : null), { fallback: true });

registerMock('client', 'logoFailed', (payload: unknown) => {
  console.info('[crimson-police:mock] logoFailed', payload);
  return true;
});
