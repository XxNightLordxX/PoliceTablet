// Browser mocks of the item rewards: the Rewards locker on Home and Admin UI → Leaderboards → Item rewards.
// ?rewards=off shows the shipped default (off, no rows); ?rewards=arena a locker that cannot be claimed.

import { emitDebug, registerMock } from '../shared/nui';
import type { AdminRewardsView, RewardRow, RewardsLocker } from '../types/rewards';
import { buildSession } from './samples';

const now = () => Math.floor(Date.now() / 1000);
const MODE = typeof window !== 'undefined' ? new URLSearchParams(window.location.search).get('rewards') : null;
const ENABLED = MODE !== 'off';

{
    const cfg = buildSession('officer').config;
    cfg.rewards = { enabled: ENABLED };
}

// ============================================================================
//                                    LOCKER
// ============================================================================

const locker: RewardRow[] = ENABLED
    ? [
          { id: 41, item: 'burger', label: 'Burger', count: 2, source: 'run', status: 'pending', at: now() - 3600 },
          { id: 44, item: 'water', label: 'Water', count: 1, source: 'goal', status: 'pending', at: now() - 900 },
          { id: 47, item: 'sprunk', label: 'Sprunk', count: 1, source: 'run', status: 'held', at: now() - 300 },
      ]
    : [];
const given: RewardRow[] = [];

registerMock('request', 'getRewardsLocker', (): RewardsLocker => {
    const reason = !ENABLED ? 'rewards.reason.off' : MODE === 'arena' ? 'rewards.reason.arena' : null;
    return { rows: locker.map(r => ({ ...r })), canClaim: reason === null, reason };
});

registerMock('action', 'server:rewards:claim', (payload: unknown) => {
    const id = Number((payload as { id?: number } | null)?.id);
    if (!ENABLED) throw new Error('err.rewards_off');
    if (MODE === 'arena') throw new Error('err.reward_in_arena');
    const i = locker.findIndex(r => r.id === id);
    if (i < 0) throw new Error('err.reward_not_found');
    if (locker[i].status !== 'pending') throw new Error('err.reward_not_claimable');
    const [row] = locker.splice(i, 1);
    given.unshift({ ...row, status: 'given', at: now() });
    emitDebug('push', { topic: 'rewards', data: { changed: true } }, 50);
    return { id };
});

// ============================================================================
//                                    ADMIN
// ============================================================================

const OFFICERS = [
    { citizenid: 'ABC12345', name: 'John Doe' },
    { citizenid: 'KLM55512', name: 'Maria Lopez' },
    { citizenid: 'XYZ98765', name: 'Sam Reyes' },
];
const ITEMS = [
    { item: 'water', label: 'Water' },
    { item: 'burger', label: 'Burger' },
    { item: 'sprunk', label: 'Sprunk' },
];
const SOURCES = ['run', 'run', 'run', 'medal', 'goal', 'level'];
const STATUSES = ['given', 'given', 'given', 'pending', 'held', 'forfeited'];

const history: RewardRow[] = ENABLED
    ? Array.from({ length: 60 }, (_, i) => {
          const o = OFFICERS[i % OFFICERS.length];
          const it = ITEMS[i % ITEMS.length];
          return {
              id: 200 - i,
              item: it.item,
              label: it.label,
              count: 1 + (i % 2),
              source: SOURCES[i % SOURCES.length],
              status: STATUSES[i % STATUSES.length],
              at: now() - i * 2400,
              citizenid: o.citizenid,
              name: o.name,
          };
      })
    : [];

registerMock('request', 'admin:getRewards', (args: unknown): AdminRewardsView => {
    const page = Math.max(1, Number((args as { page?: number } | null)?.page) || 1);
    const pageSize = 25;
    const all = [...given.map(r => ({ ...r, citizenid: 'ABC12345', name: 'John Doe' })), ...history];
    const sum = (status: string) => all.filter(r => r.status === status).reduce((n, r) => n + r.count, 0);
    return {
        enabled: ENABLED,
        page,
        pageSize,
        pools: [
            {
                key: 'byType.tactical',
                items: [
                    { item: 'burger', ok: true },
                    { item: 'radio', ok: false },
                ],
            },
            { key: 'medals.gold', items: [{ item: 'water', ok: true }] },
            {
                key: 'examplePools.investigation',
                items: [
                    { item: 'water', ok: true },
                    { item: 'burger', ok: true },
                ],
            },
            { key: 'examplePools.patrol', items: [{ item: 'water', ok: true }] },
            {
                key: 'examplePools.tactical',
                items: [
                    { item: 'burger', ok: true },
                    { item: 'sprunk', ok: true },
                ],
            },
        ],
        week: { given: sum('given'), held: sum('held'), forfeited: sum('forfeited') },
        stuck: ENABLED
            ? [
                  {
                      id: 150,
                      item: 'burger',
                      label: 'Burger',
                      count: 1,
                      source: 'run',
                      status: 'giving',
                      at: now() - 7200,
                      citizenid: 'KLM55512',
                      name: 'Maria Lopez',
                  },
              ]
            : [],
        recent: all.slice((page - 1) * pageSize, page * pageSize),
        health: ENABLED
            ? [
                  { level: 'ok', text: 'Item rewards: on' },
                  {
                      level: 'warn',
                      text: 'Item rewards: "radio" (byType.tactical) does not exist in ox_inventory; it is turned off',
                  },
              ]
            : [{ level: 'ok', text: 'Item rewards: off (example pool available)' }],
    };
});
