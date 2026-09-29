// Browser mocks of the foundation slice: a result with every parity-plus section (?result=parity shows it).

import { emitDebug } from '../shared/nui';
import type { RunResult } from '../shared/types';
import { sampleResult } from './samples';

// A completed Traffic Enforcement style run: level-up, a claimed mission call, a decision ledger and items.
export function parityResult(): RunResult {
    const base = sampleResult('completed');
    return {
        ...base,
        runId: 'run-parity-1',
        missionLabel: 'Traffic Enforcement',
        missionType: 'patrol',
        decisions: [
            {
                contact: 'Car A',
                kind: 'vehicle',
                choice: 'impound',
                best: 'impound',
                verdict: 'best',
                by: 'John Doe',
                truth: 'stolen',
                facts: ['stolen_plate'],
                points: 10,
                discoverable: true,
                knownAtS: 142,
            },
            {
                contact: 'Driver A',
                kind: 'person',
                choice: 'cite',
                best: 'arrest',
                verdict: 'wrong',
                by: 'John Doe',
                truth: 'intoxicated',
                facts: ['odour'],
                points: -15,
                discoverable: true,
                knownAtS: 180,
            },
            {
                contact: 'Passenger B',
                kind: 'person',
                choice: 'release',
                best: 'arrest',
                verdict: 'ok',
                by: 'Maria Lopez',
                truth: 'narcotics',
                facts: [],
                points: 0,
                discoverable: false,
                knownAtS: null,
            },
        ],
        progress: {
            xpBefore: 1120,
            xpAfter: 1481,
            pending: false,
            level: {
                n: 10,
                label: 'Patrol Officer',
                badge: 'bronze',
                xp: 1481,
                levelXp: 1198,
                nextLevelXp: 1382,
                prestige: 0,
            },
            levelUp: true,
            goals: { daily: null, weekly: null },
        },
        stats: { arrests: 1, citations: 1, impounds: 1, decisions_ok: 2, decisions_best: 1, decisions_bad: 1 },
        missionCall: { code: 'MC-0427', responseS: 96, targetS: 140, rapid: true },
        items: [{ name: 'water', label: 'Water', count: 2, status: 'pending' }],
    };
}

if (new URLSearchParams(window.location.search).get('result') === 'parity') {
    emitDebug('result', { result: parityResult() }, 300);
}
