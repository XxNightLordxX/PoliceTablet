// Admin UI -> Rewards (Config.AdminUi.rewardsScreen): every feature that pays, as rows built from the
// settings data (admin:getSettings), each with its switch, money, how the money is paid and its items. Pure helpers;
// admin/screens/Rewards.tsx draws them and saves through the Settings save flow (server:admin:setSetting, audited).

// The Rewards screen's rows built from the settings data (rewardRows, missionTypes, itemSwitch) and the volunteer
// suspect's money by mission type (typeAmount, withTypeAmount). Pure helpers; walk: rewardsScreen.walk.ts.

import type { SettingsData, SettingView } from '../../types/settings';
import { settingsByPath } from './features';

// The cards in order: NPC missions, cases against real players, officers working together.
export type RewardCard = 'missions' | 'pvp' | 'team';
export const REWARD_CARDS: RewardCard[] = ['missions', 'pvp', 'team'];

export type Outcome = 'got_away' | 'caught';
export const OUTCOMES: Outcome[] = ['got_away', 'caught'];

export interface MoneyField {
    s: SettingView;
    // locale key of its label
    labelKey: string;
}

export type RewardItems =
    // FeatureRewards.<feature>.items: the feature's own items list
    | { kind: 'list'; s: SettingView }
    // Rewards.byType: the pool of one mission type
    | { kind: 'pool'; s: SettingView; key: string }
    // LiveCrime.items / Volunteers.payRewards: a switch, the case rolls its mission type's pool
    | { kind: 'switch'; s: SettingView };

export interface RewardRow {
    key: string;
    card: RewardCard;
    // locale key of the title (a mission type row shows the type's label instead)
    titleKey: string;
    label?: string;
    hintKey: string;
    // the row's own switch; none = always paid (an NPC mission type)
    on?: SettingView;
    money: MoneyField[];
    // locale key: the money is set elsewhere (a case pays its mission type's payout)
    moneyNoteKey?: string;
    // how the money is paid ('bank' | 'cash' | 'item') and the money item when 'item'
    account?: SettingView;
    moneyItem?: SettingView;
    items?: RewardItems;
    // volunteer suspects: dollars by mission type (FeatureRewards.suspect.byType)
    byType?: SettingView;
}

// The feature rows (Config.FeatureRewards) in screen order: the card, the money fields and their labels.
const FEATURES: { key: string; card: RewardCard; money: [string, string][]; byType?: boolean }[] = [
    {
        key: 'suspect',
        card: 'pvp',
        money: [
            ['money.got_away', 'admin.rewards_screen.money.got_away'],
            ['money.caught', 'admin.rewards_screen.money.caught'],
        ],
        byType: true,
    },
    { key: 'surrender', card: 'pvp', money: [['money', 'admin.rewards_screen.money.each']] },
    { key: 'ftoSignOff', card: 'team', money: [['money', 'admin.rewards_screen.money.each']] },
    { key: 'ftoComplete', card: 'team', money: [['money', 'admin.rewards_screen.money.each']] },
    {
        key: 'supAward',
        card: 'team',
        money: [
            ['money', 'admin.rewards_screen.money.per_point'],
            ['maxMoney', 'admin.rewards_screen.money.max'],
        ],
    },
];

// The officers' pay of cases against real players: a switch for the money and one for the items, both from the
// case's mission type.
const CASES: { key: string; cash: string; items: string }[] = [
    { key: 'live', cash: 'LiveCrime.cash', items: 'LiveCrime.items' },
    { key: 'volunteer_case', cash: 'Volunteers.payCash', items: 'Volunteers.payRewards' },
];

// The mission type keys the data has (MissionTypes.<type>.payout), in its order.
export function missionTypes(data: SettingsData | null | undefined): string[] {
    const out: string[] = [];
    for (const path of settingsByPath(data).keys()) {
        const m = /^MissionTypes\.([^.]+)\.payout$/.exec(path);
        if (m) out.push(m[1]);
    }
    return out;
}

// Config.Rewards.enabled: the switch every item of this screen follows.
export function itemSwitch(data: SettingsData | null | undefined): SettingView | undefined {
    return settingsByPath(data).get('Rewards.enabled');
}

// Every row the data can show, in card order; a row whose settings the data does not have is left out.
export function rewardRows(data: SettingsData | null | undefined): RewardRow[] {
    const by = settingsByPath(data);
    const rows: RewardRow[] = [];
    const cashAccount = by.get('Cash.account');
    const pools = by.get('Rewards.byType');
    for (const type of missionTypes(data)) {
        const payout = by.get(`MissionTypes.${type}.payout`);
        if (!payout) continue;
        const label = by.get(`MissionTypes.${type}.label`)?.value;
        rows.push({
            key: `type_${type}`,
            card: 'missions',
            titleKey: 'admin.rewards_screen.row.type',
            label: typeof label === 'string' && label ? label : type,
            hintKey: 'admin.rewards_screen.hint.type',
            money: [{ s: payout, labelKey: 'admin.rewards_screen.money.payout' }],
            account: cashAccount,
            items: pools ? { kind: 'pool', s: pools, key: type } : undefined,
        });
    }
    for (const c of CASES) {
        const on = by.get(c.cash);
        if (!on) continue;
        const items = by.get(c.items);
        rows.push({
            key: c.key,
            card: 'pvp',
            titleKey: `admin.rewards_screen.row.${c.key}`,
            hintKey: `admin.rewards_screen.hint.${c.key}`,
            on,
            money: [],
            moneyNoteKey: 'admin.rewards_screen.money.from_type',
            account: cashAccount,
            items: items ? { kind: 'switch', s: items } : undefined,
        });
    }
    for (const f of FEATURES) {
        const base = `FeatureRewards.${f.key}`;
        const on = by.get(`${base}.enabled`);
        if (!on) continue;
        const items = by.get(`${base}.items`);
        rows.push({
            key: f.key,
            card: f.card,
            titleKey: `admin.rewards_screen.row.${f.key}`,
            hintKey: `admin.rewards_screen.hint.${f.key}`,
            on,
            money: f.money.flatMap(([p, labelKey]) => {
                const s = by.get(`${base}.${p}`);
                return s ? [{ s, labelKey }] : [];
            }),
            account: by.get(`${base}.account`),
            moneyItem: by.get(`${base}.moneyItem`),
            items: items ? { kind: 'list', s: items } : undefined,
            byType: f.byType ? by.get(`${base}.byType`) : undefined,
        });
    }
    // the cards' order, keeping each card's own order
    return REWARD_CARDS.flatMap(card => rows.filter(r => r.card === card));
}

// The money item shows only while the row pays as an item.
export function showsMoneyItem(row: RewardRow): boolean {
    return !!row.moneyItem && row.account?.value === 'item';
}

type ByType = Record<string, Partial<Record<Outcome, number>>>;

function byTypeOf(v: unknown): ByType {
    return v && typeof v === 'object' && !Array.isArray(v) ? (v as ByType) : {};
}

// A mission type's own amount for an outcome (null = it pays the per-outcome default).
export function typeAmount(byType: unknown, type: string, outcome: Outcome): number | null {
    const n = byTypeOf(byType)[type]?.[outcome];
    return typeof n === 'number' && Number.isFinite(n) ? n : null;
}

// byType with one amount set (null = back to the default); a type with no amount left is removed.
export function withTypeAmount(byType: unknown, type: string, outcome: Outcome, n: number | null): ByType {
    const out: ByType = {};
    for (const [k, e] of Object.entries(byTypeOf(byType))) out[k] = { ...e };
    const e = { ...(out[type] ?? {}) };
    if (n === null) delete e[outcome];
    else e[outcome] = n;
    if (Object.keys(e).length) out[type] = e;
    else delete out[type];
    return out;
}
