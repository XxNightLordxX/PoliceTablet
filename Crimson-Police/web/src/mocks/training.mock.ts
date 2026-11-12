// Browser mocks of the guided tours (modules/access/training.lua): training:get and server:training:done. Every tour

// Browser mocks of the guided tours (modules/access/training.lua): training:get and server:training:done. Every tour
// counts as finished, so none starts by itself (the '?' button and the Tours lists still start one); ?tours=new
// starts each tablet's tour on its first open (and the run tips on the first HUD), ?tours=off turns them off
// (Config.Training.enabled = false).

import { registerMock } from '../shared/nui';
import { TOURS, tourVersion, type TourId } from '../shared/tour/tours';

const PARAMS = new URLSearchParams(typeof window !== 'undefined' ? window.location.search : '');
const MODE = PARAMS.get('tours');

const versions: Partial<Record<TourId, number>> = {};
for (const id of Object.keys(TOURS) as TourId[]) versions[id] = tourVersion(TOURS[id]);
const seen: Partial<Record<TourId, number>> = MODE === 'new' ? {} : { ...versions };

registerMock('request', 'training:get', () => ({
    enabled: MODE !== 'off',
    autoStart: { officer: true, supervisor: true, admin: true, criminal: true, run: true },
    allowSkip: true,
    checklist: true,
    hintSeconds: 12,
    seen: { ...seen },
    versions,
    setupPending: false,
}));

registerMock('action', 'server:training:done', (p: { tour?: TourId; version?: number } | null) => {
    if (!p || !p.tour || !(p.tour in TOURS) || typeof p.version !== 'number') throw new Error('err.invalid_payload');
    seen[p.tour] = Math.max(seen[p.tour] ?? 0, p.version);
    return { seen: { ...seen } };
});

registerMock('action', 'server:admin:resetTours', () => ({ cleared: 2 }));
