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
    // the run row it came from (run and medal rewards), and whether the officer is online now
    rowId?: number | null;
    online?: boolean;
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
    // Take back is on (Config.Rewards.allowTakeBack, ships off)
    allowTakeBack?: boolean;
}

// admin:getRewards filters
export interface AdminRewardsFilter {
    page?: number;
    citizenid?: string;
    status?: string;
    source?: string;
    from?: number;
    to?: number;
}

// admin:checkRewardInventory { id }: found/count stay null while the officer is offline.
export interface RewardInventoryCheck {
    id: number;
    status: string;
    item: string;
    label: string;
    needed: number;
    online: boolean;
    found?: boolean | null;
    count?: number | null;
}

// admin:rewardItems: the item picker (forbidden items left out).
export interface RewardItemChoices {
    items: { name: string; label: string }[];
    inventory: boolean;
}

// admin:rewardPoolPreview { path, value }: the server's verdict and the expected items and value per run.
export interface RewardPoolPreview {
    error?: string | null;
    expected: { key: string; tiers: { tier: string; chance: number; items: number; value: number }[] }[];
}
