// src/types/economy.ts · response shapes of the economy slice's supervisor/admin callbacks and actions
// (modules/payouts/server.lua; documented in docs/notes/economy.md). HomeData and Goal are contract
// shapes and live in src/shared/types.ts.

/** getHome typeOfTheDay (§9.4 key/label) plus the Config values the Home text shows (extras, optional). */
export interface HomeTypeOfTheDay {
  key: string;
  label: string;
  /** Config.Events.todMultiplier (points only). */
  multiplier?: number;
  /** Config.Scoring.scoreCap (× P); the multiplier is applied after it. */
  cap?: number;
}

/** getHome card.streak (§9.4 days/graceLeft) plus the extra graceDays (Config.Scoring.streakGraceDays; 0 = off). */
export interface HomeStreak {
  days: number;
  graceLeft: boolean;
  graceDays?: number;
}

/** One mission type row of the Supervisor UI → Payouts screen (callback 'sup:getPayouts'). */
export interface SupPayoutType {
  key: string;
  label: string;
  /** Current base payout of the type (stored value or the config default). */
  amount: number;
  /** Config.MissionTypes payout. */
  default: number;
  /** Allowed supervisor range (Config.Payouts.supervisorRange of the default, inside Config.Cash limits). */
  min: number;
  max: number;
  /** An admin set this type: permanent and read-only for supervisors. */
  adminLocked: boolean;
  /** Seconds until a supervisor may change this type again (0 = now). */
  cooldownLeft: number;
  /** Display name of whoever changed it last (null for the config default or unknown). */
  updatedByName?: string | null;
  /** Unix seconds of the last change (null/absent for the config default). */
  updatedAt?: number | null;
  /** A value is stored in cp_type_payouts (false = the config default applies). */
  stored: boolean;
  canEdit: boolean;
}

export interface SupPayoutsView {
  types: SupPayoutType[];
  /** Config.Payouts.supervisorRange as shares of the default (0.5 = 50%). */
  rangeShare: { min: number; max: number };
  cooldownSeconds: number;
  requireReason: boolean;
  /** Config.Cash.minPayout / maxPayout. */
  limits: { min: number; max: number };
  serverTime: number;
}

/** One mission type row of the Admin UI → Payouts screen. */
export interface AdminPayoutType {
  key: string;
  label: string;
  points: number;
  amount: number;
  default: number;
  adminLocked: boolean;
  stored: boolean;
  updatedBy?: string | null;
  updatedByName?: string | null;
  updatedAt?: number | null;
  supMin: number;
  supMax: number;
  cooldownLeft: number;
  /** Missions of this type (the Weekly Boss excluded). */
  missions: number;
}

export type PayoutSource = 'admin' | 'type' | 'event';

/** One mission row of the Admin UI → Payouts screen. */
export interface AdminPayoutMission {
  id: string;
  label: string;
  /** Mission type key (absent for a stored payout whose mission is not loaded). */
  type?: string | null;
  typeLabel?: string | null;
  difficulty: number;
  source: 'builtin' | 'custom';
  isBoss: boolean;
  enabled: boolean;
  /** Base payout B used for new runs. */
  base: number;
  payoutSource: PayoutSource;
  /** The admin mission payout, when one is set. */
  missionPayout?: number | null;
  /** B without the mission payout (type payout × stars, or the Weekly Boss's event payout). */
  fallback: number;
  setBy?: string | null;
  setByName?: string | null;
  updatedAt?: number | null;
  /** A stored payout for a mission that is not loaded (archived or removed). */
  missing: boolean;
}

export interface AdminPayoutsView {
  types: AdminPayoutType[];
  missions: AdminPayoutMission[];
  limits: { min: number; max: number };
  requireReason: boolean;
  cooldownSeconds: number;
  serverTime: number;
}

/** Payload of 'server:sup:setTypePayout'. */
export interface SupSetTypePayload { type: string; amount: number; reason: string }
/** Payload of 'server:admin:setTypePayout' (amount null + clear = back to the config payout). */
export interface AdminSetTypePayload { type: string; amount: number | null; reason: string; clear?: boolean }
/** Payload of 'server:admin:setMissionPayout' (amount null + clear = back to the type payout). */
export interface AdminSetMissionPayload { missionId: string; amount: number | null; reason: string; clear?: boolean }
