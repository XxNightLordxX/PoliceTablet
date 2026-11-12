// The gear of each Admin UI screen (admin/components/ScreenSettings.tsx) and Settings -> Presets: which settings a
// screen's gear shows and whether a preset can be applied. Every setting stays in Settings -> All settings too.

import { asArray } from '../../shared/data';
import type { PresetPreview, SettingView, SettingsData, SettingsSection } from '../../types/settings';

// The sections a screen's gear shows, in the server's order for that screen (modules/admin/settings Play.screens).
export function gearSections(data: SettingsData | null | undefined, screen: string): SettingsSection[] {
    const keys = asArray(data?.screens?.[screen]);
    const secs = asArray(data?.sections);
    return keys.flatMap(k => secs.filter(s => s.key === k));
}

function hit(s: SettingView, q: string): boolean {
    return [s.label, s.path, s.desc, s.help ?? ''].some(x => (x ?? '').toLowerCase().includes(q));
}

// The settings of the sections that match the typed words (label, Config path or description); '' = all of them.
export function gearFilter(secs: SettingsSection[], text: string): SettingsSection[] {
    const q = text.trim().toLowerCase();
    if (!q) return secs;
    return secs
        .map(sec => ({
            ...sec,
            groups: asArray(sec.groups)
                .map(g => ({ ...g, settings: asArray(g.settings).filter(s => hit(s, q)) }))
                .filter(g => g.settings.length),
        }))
        .filter(sec => sec.groups.length);
}

// How many settings the sections hold.
export function settingCount(secs: SettingsSection[]): number {
    return secs.reduce((n, sec) => n + asArray(sec.groups).reduce((m, g) => m + asArray(g.settings).length, 0), 0);
}

// A preview's state: 'refused' (a row the server refuses: it cannot be applied), 'none' (every setting already
// matches) or 'ready' (Apply saves preview.changes).
export function presetState(p: PresetPreview | null | undefined): 'refused' | 'none' | 'ready' {
    if (!p) return 'none';
    if (asArray(p.refused).length) return 'refused';
    return asArray(p.changes).length ? 'ready' : 'none';
}
