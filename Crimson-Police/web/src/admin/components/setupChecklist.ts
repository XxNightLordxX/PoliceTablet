// Admin UI -> Home's Setup checklist (Config.Training.setupChecklist): the lines the server ticked from its real state
// (CP.Setup.checklist), each with the screen that fixes it. Text: admin.checklist.<key> and admin.checklist.<key>_hint.

import { asArray } from '../../shared/data';
import type { ScreenKey, ScreenParams } from '../../shared/navigation';
import type { SetupCheck, SetupCheckKey } from '../../types/admin_system';

export const CHECKLIST_KEYS: SetupCheckKey[] = [
    'departments',
    'grades',
    'desks',
    'storage',
    'scripts',
    'money',
    'presets',
    'debug',
];

export const CHECKLIST_OPENS: Record<SetupCheckKey, { screen: ScreenKey; params?: ScreenParams }> = {
    departments: { screen: 'admin_departments' },
    grades: { screen: 'admin_departments' },
    desks: { screen: 'admin_departments' },
    storage: { screen: 'admin_system' },
    scripts: { screen: 'admin_system' },
    money: { screen: 'admin_settings', params: { tab: 'features' } },
    presets: { screen: 'admin_settings', params: { tab: 'presets' } },
    debug: { screen: 'admin_settings', params: { q: 'debug' } },
};

// The known lines in their order (an unknown key from a newer server is left out); null while there is no list.
export function checklistOf(raw: unknown): SetupCheck[] | null {
    if (raw === null || raw === undefined) return null;
    const rows = asArray(raw as SetupCheck[]).filter(r => r && CHECKLIST_KEYS.includes(r.key));
    return CHECKLIST_KEYS.flatMap(k => rows.filter(r => r.key === k).slice(0, 1)).map(r => ({
        key: r.key,
        done: r.done === true,
        n: typeof r.n === 'number' ? r.n : undefined,
    }));
}

// How many lines are still open.
export function checklistLeft(list: SetupCheck[] | null): number {
    return (list ?? []).filter(r => !r.done).length;
}
