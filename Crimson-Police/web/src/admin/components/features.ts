// Admin UI -> Settings -> Features: every feature switch (SettingsData.features, modules/admin/settings Play.features) with
// the setting it writes, grouped by section of play. Pure helpers; FeaturesPanel.tsx draws them.

import { asArray } from '../../shared/data';
import type { FeatureEntry, FeaturePlay, SettingsData, SettingView } from '../../types/settings';

// The sections in order: missions against NPCs, real players as suspects, officers working together, money, server.
export const FEATURE_PLAYS: FeaturePlay[] = ['npc', 'pvp', 'team', 'economy', 'system'];

export interface FeatureRow {
    f: FeatureEntry;
    s: SettingView;
    on: boolean;
    // the feature's limits that the data has, in the server's order
    limits: SettingView[];
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
                const limits = asArray(f.limits).flatMap(p => {
                    const l = byPath.get(p);
                    return l ? [l] : [];
                });
                return s ? [{ f, s, on: s.value === true, limits }] : [];
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

// A limit's value on its button: a number, text or switch as is, a list or map as its size, nothing as a dash.
export function limitValue(s: SettingView): string {
    const v = s.value;
    if (typeof v === 'number' || typeof v === 'string' || typeof v === 'boolean') return String(v);
    if (Array.isArray(v)) return `[${v.length}]`;
    if (v && typeof v === 'object') return `{${Object.keys(v).length}}`;
    return '–';
}
