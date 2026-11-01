// Admin UI -> Settings -> Features: every feature switch (SettingsData.features, modules/settings Play.features) with
// the setting it writes, grouped by section of play. Pure helpers; FeaturesPanel.tsx draws them.

import { asArray } from '../../shared/data';
import type { FeatureEntry, FeaturePlay, SettingsData, SettingView } from '../../types/settings';

// The sections in order: missions against NPCs, real players as suspects, officers working together, money, server.
export const FEATURE_PLAYS: FeaturePlay[] = ['npc', 'pvp', 'team', 'economy', 'system'];

export interface FeatureRow {
    f: FeatureEntry;
    s: SettingView;
    on: boolean;
}

export interface FeatureSection {
    play: FeaturePlay;
    rows: FeatureRow[];
    on: number;
}

// Every setting of the data by path.
export function settingsByPath(data: SettingsData | null | undefined): Map<string, SettingView> {
    const out = new Map<string, SettingView>();
    for (const sec of asArray(data?.sections))
        for (const g of asArray(sec.groups)) for (const s of asArray(g.settings)) out.set(s.path, s);
    return out;
}

// The features by section (in FEATURE_PLAYS order, empty sections left out); a feature whose setting the data does
// not have is left out too.
export function featureSections(data: SettingsData | null | undefined): FeatureSection[] {
    const byPath = settingsByPath(data);
    const features = asArray(data?.features);
    return FEATURE_PLAYS.map(play => {
        const rows = features
            .filter(f => f.play === play)
            .flatMap(f => {
                const s = byPath.get(f.path);
                return s ? [{ f, s, on: s.value === true }] : [];
            });
        return { play, rows, on: rows.filter(r => r.on).length };
    }).filter(sec => sec.rows.length > 0);
}

// What a toggle to `next` waits for: 'money' = the typed ENABLE (the shared save flow asks it), 'risky' = a confirm
// first, null = it saves at once.
export function toggleNeeds(row: FeatureRow, next: boolean): 'money' | 'risky' | null {
    if (row.s.money && next) return 'money';
    if (row.f.risky) return 'risky';
    return null;
}
