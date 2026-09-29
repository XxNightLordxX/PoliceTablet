// Shapes of the optional item rewards: the Rewards locker on Home and Admin UI → Leaderboards → Item rewards.

export interface RewardRow {
    id: number;
    item: string;
    label: string;
    count: number;
    source: string;
    status: string;
    at: number;
}

// getRewardsLocker
export interface RewardsLocker {
    rows: RewardRow[];
    canClaim: boolean;
    reason: string | null;
}

// admin:getRewards
export interface AdminRewardsView {
    pools: { key: string; items: { item: string; ok: boolean }[] }[];
    week: { given: number; held: number; forfeited: number };
    stuck: RewardRow[];
    recent: RewardRow[];
}
