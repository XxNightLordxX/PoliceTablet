// Shapes of the optional item rewards: the Rewards locker on Home and Admin UI → Leaderboards → Item rewards.

// A cp_item_rewards row. source: run, medal, goal, level, boss or season;
// status: held, pending, giving, given or forfeited. at = given_at, else created_at (unix seconds).
export interface RewardRow {
    id: number;
    item: string;
    label: string;
    count: number;
    source: string;
    status: string;
    at: number;
    // admin:getRewards only
    citizenid?: string;
    name?: string | null;
}

// getRewardsLocker (reason: a locale key when canClaim is false)
export interface RewardsLocker {
    rows: RewardRow[];
    canClaim: boolean;
    reason: string | null;
}

// A Config health line of CP.Rewards.health()
export interface RewardsHealthLine {
    level: 'ok' | 'warn' | 'error';
    text: string;
}

// admin:getRewards
export interface AdminRewardsView {
    pools: { key: string; items: { item: string; ok: boolean }[] }[];
    week: { given: number; held: number; forfeited: number };
    stuck: RewardRow[];
    recent: RewardRow[];
    enabled?: boolean;
    page?: number;
    pageSize?: number;
    health?: RewardsHealthLine[];
}
