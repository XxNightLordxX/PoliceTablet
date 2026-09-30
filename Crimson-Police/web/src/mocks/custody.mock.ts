// Browser mocks of the custody slice: a Contact panel on the Active Mission screen and the HUD contact card
// (?contact=1), server:contactDecide (a case-failing choice asks for the confirm first) and contactAction.

import { emitDebug, registerMock } from '../shared/nui';
import type { ActiveMissionData } from '../types/run_ui';
import type { ContactDecidePayload, ContactView, HudContact } from '../types/custody';
import { sampleHud, sampleRun } from './samples';

const nowS = () => Math.floor(Date.now() / 1000);

// A Suspicious Activity style scene: a driver with an active warrant (known), a passenger, and their car.
export function sampleContactView(): ContactView {
    return {
        entries: [
            {
                netId: 101,
                label: 'A',
                kind: 'person',
                role: 'driver',
                state: 'contacted',
                tellSeen: null,
                freeToLeave: true,
                notChecked: ['frisk', 'search'],
                facts: [
                    {
                        key: 'id_ok',
                        text: 'ID checked: licence valid',
                        by: '2L-14 John Doe',
                        at: nowS() - 90,
                        suppressed: false,
                        cause: false,
                    },
                    {
                        key: 'warrant',
                        text: 'Active warrant',
                        by: '2L-14 John Doe',
                        at: nowS() - 88,
                        suppressed: false,
                        cause: false,
                    },
                ],
                actions: ['talk', 'frisk', 'detain'],
                choices: [
                    { id: 'release', label: 'Release', failsCase: true },
                    { id: 'cite', label: 'Cite', failsCase: true },
                ],
                offences: [
                    { id: 'loitering', label: 'Loitering' },
                    { id: 'open_container', label: 'Open container' },
                ],
                decided: null,
                confirm: null,
            },
            {
                netId: 102,
                label: 'B',
                kind: 'person',
                role: 'subject',
                state: 'cuffed',
                tellSeen: 'hands',
                freeToLeave: false,
                notChecked: ['id'],
                facts: [
                    {
                        key: 'weapon',
                        text: 'Weapon found in the frisk',
                        by: '2L-21 Maria Lopez',
                        at: nowS() - 40,
                        suppressed: false,
                        cause: true,
                    },
                ],
                actions: ['talk', 'searchPerson'],
                choices: [
                    { id: 'release', label: 'Release', failsCase: true },
                    { id: 'arrest', label: 'Arrest', failsCase: false },
                ],
                offences: [],
                decided: null,
            },
            {
                netId: 103,
                label: 'V1',
                kind: 'vehicle',
                role: 'scene_car',
                state: 'stopped',
                tellSeen: null,
                freeToLeave: false,
                notChecked: ['inside'],
                facts: [
                    {
                        key: 'plate_valid',
                        text: 'Registration valid',
                        by: '2L-14 John Doe',
                        at: nowS() - 60,
                        suppressed: false,
                        cause: false,
                    },
                    {
                        key: 'veh_narcotics',
                        text: 'Narcotics found in the vehicle',
                        by: '2L-14 John Doe',
                        at: nowS() - 20,
                        suppressed: true,
                        cause: false,
                    },
                ],
                actions: ['lookInside', 'runPlate', 'searchVehicle'],
                choices: [
                    { id: 'noAction', label: 'No action', failsCase: false },
                    { id: 'impound', label: 'Impound', failsCase: false },
                ],
                offences: [],
                decided: null,
            },
        ],
        probableCause: { 103: true },
        transport: { status: 'coming', distance: 180 },
    };
}

export function sampleContactRun(): ActiveMissionData {
    return {
        ...sampleRun(),
        missionLabel: 'Suspicious Activity',
        missionType: 'investigation',
        intel: 'A dark sedan has been parked behind the store for an hour',
        missionCall: { code: 'MC-0427', targetS: 140, arrivedS: 96 },
        contact: sampleContactView(),
    };
}

export function sampleHudContact(): HudContact {
    return { label: 'A', fact: 'Active warrant', hint: false, confirm: false, suppressed: false };
}

registerMock('action', 'server:contactDecide', (payload: unknown) => {
    const p = (payload ?? {}) as ContactDecidePayload;
    const entry = sampleContactView().entries.find(e => e.netId === p.netId);
    const choice = entry?.choices.find(c => c.id === p.choice);
    if (!entry || !choice) throw new Error('err.custody_unknown');
    if (choice.failsCase && !p.confirmed)
        return { confirm: { factKey: entry.kind === 'vehicle' ? 'stolen' : 'warrant' } };
    return { ok: true };
});

registerMock('client', 'contactAction', () => true);

if (new URLSearchParams(window.location.search).get('contact') === '1') {
    emitDebug('push', { topic: 'run', data: sampleContactRun() }, 900);
    emitDebug('hud', { hud: { ...sampleHud('progress'), contact: sampleHudContact() } as never }, 600);
}
