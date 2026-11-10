// Admin UI -> Mission blips (Config.AdminUi.missionBlipsScreen): the extra mission blips of Config.MissionBlips as

// Admin UI -> Mission blips (Config.AdminUi.missionBlipsScreen): the extra mission blips of Config.MissionBlips as
// rows built from the settings data (admin:getSettings): the master switch, each part's settings and its rules, and
// the pickers' choices. Pure helpers; admin/screens/MissionBlips.tsx draws them and saves through the Settings save
// flow (server:admin:setSetting, checked and audited by the server).

// The Mission blips screen's rows (blipParts, masterSwitch), the rule pickers' choices (ruleChoices) and the rules
// value of one part (ruleOf, withRule, ruleSummary). Pure helpers; walk: missionBlips.walk.ts.

import type { SettingsData, SettingView } from '../../types/settings';
import { settingsByPath } from './features';

// The look fields of a part, in screen order (each is its own setting: MissionBlips.parts.<id>.<field>).
export const LOOK_FIELDS = ['sprite', 'colour', 'scale', 'label', 'shortRange'] as const;
export type LookField = (typeof LOOK_FIELDS)[number];

export interface BlipPart {
    id: string;
    // locale key of its built-in name
    nameKey: string;
    on: SettingView;
    look: Partial<Record<LookField, SettingView>>;
}

// One part's rules (Config.MissionBlips.rules.<part>); every key optional, all must match.
export interface BlipRule {
    departments?: string[];
    jobs?: string[];
    grade?: number;
    missionTypes?: string[];
    missions?: string[];
    roles?: 'all' | 'leader' | 'supervisor';
}
export type BlipRules = Record<string, BlipRule>;

export const ROLES: NonNullable<BlipRule['roles']>[] = ['all', 'leader', 'supervisor'];
export const LIST_RULES = ['departments', 'jobs', 'missionTypes', 'missions'] as const;
export type ListRule = (typeof LIST_RULES)[number];

export interface Choice {
    value: string;
    label: string;
}
export type RuleChoices = Record<ListRule, Choice[]>;

// The blip colours most used (GTA blip colour ids), named for the colour picker; any other id still works.
export const COLOURS: { id: number; key: string; hex: string }[] = [
    { id: 0, key: 'white', hex: '#f0f0f0' },
    { id: 1, key: 'red', hex: '#e03232' },
    { id: 2, key: 'green', hex: '#72cc72' },
    { id: 3, key: 'blue', hex: '#5db6e5' },
    { id: 5, key: 'yellow', hex: '#eec64e' },
    { id: 17, key: 'orange', hex: '#f39b2f' },
    { id: 27, key: 'purple', hex: '#ab3ce6' },
    { id: 38, key: 'dark_blue', hex: '#2c6db8' },
    { id: 40, key: 'grey', hex: '#4c4c4c' },
    { id: 46, key: 'gold', hex: '#eeb44d' },
];

// Blip sprites the parts use (GTA blip ids), named for the sprite picker; any other id still works.
export const SPRITES: { id: number; key: string }[] = [
    { id: 1, key: 'dot' },
    { id: 50, key: 'garage' },
    { id: 60, key: 'police_station' },
    { id: 61, key: 'hospital' },
    { id: 67, key: 'van' },
    { id: 68, key: 'tow_truck' },
    { id: 162, key: 'scene' },
    { id: 225, key: 'car' },
    { id: 280, key: 'person' },
    { id: 285, key: 'prisoner_van' },
];

function isObject(v: unknown): v is Record<string, unknown> {
    return !!v && typeof v === 'object' && !Array.isArray(v);
}

// Config.MissionBlips.enabled: the switch every part follows.
export function masterSwitch(data: SettingsData | null | undefined): SettingView | undefined {
    return settingsByPath(data).get('MissionBlips.enabled');
}

// Every part the data has (MissionBlips.parts.<id>.on), in its order, with its look settings.
export function blipParts(data: SettingsData | null | undefined): BlipPart[] {
    const by = settingsByPath(data);
    const out: BlipPart[] = [];
    for (const [path, s] of by) {
        const m = /^MissionBlips\.parts\.([A-Za-z]+)\.on$/.exec(path);
        if (!m) continue;
        const look: BlipPart['look'] = {};
        for (const f of LOOK_FIELDS) {
            const x = by.get(`MissionBlips.parts.${m[1]}.${f}`);
            if (x) look[f] = x;
        }
        out.push({ id: m[1], nameKey: `missionblips.part.${m[1]}`, on: s, look });
    }
    return out;
}

// The parts switched on (they show only while the master switch is on too).
export function partsOn(parts: BlipPart[]): number {
    return parts.filter(p => p.on.value === true).length;
}

// The choices of each list rule: departments and their jobs (Departments.<key>), mission types (MissionTypes.<type>)
// and the missions of admin:getMissions. A value already in a rule but no longer offered is kept as a choice.
export function ruleChoices(
    data: SettingsData | null | undefined,
    missions: { id: string; label?: string }[] = [],
): RuleChoices {
    const by = settingsByPath(data);
    const departments: Choice[] = [];
    const jobs: Choice[] = [];
    const types: Choice[] = [];
    const seenJobs = new Set<string>();
    for (const [path, s] of by) {
        const d = /^Departments\.([^.]+)\.label$/.exec(path);
        if (d) {
            const label = typeof s.value === 'string' && s.value ? s.value : d[1];
            departments.push({ value: d[1], label });
            const list = by.get(`Departments.${d[1]}.jobs`)?.value;
            for (const j of Array.isArray(list) ? list : []) {
                if (typeof j === 'string' && !seenJobs.has(j)) {
                    seenJobs.add(j);
                    jobs.push({ value: j, label: j });
                }
            }
        }
        const tm = /^MissionTypes\.([^.]+)\.label$/.exec(path);
        if (tm) types.push({ value: tm[1], label: typeof s.value === 'string' && s.value ? s.value : tm[1] });
    }
    const ms = missions
        .filter(m => typeof m?.id === 'string' && m.id !== '')
        .map(m => ({ value: m.id, label: m.label || m.id }));
    return { departments, jobs, missionTypes: types, missions: ms };
}

// The choices of one list rule plus any value the rule holds that is not offered (so it can still be removed).
export function choicesWith(choices: Choice[], held: string[] | undefined): Choice[] {
    const out = [...choices];
    for (const v of held ?? []) if (!out.some(c => c.value === v)) out.push({ value: v, label: v });
    return out;
}

// The rules value as a map (Lua sends an empty table as []).
export function rulesOf(value: unknown): BlipRules {
    return isObject(value) ? (value as BlipRules) : {};
}

// One part's rule (an empty rule when it has none).
export function ruleOf(value: unknown, part: string): BlipRule {
    const r = rulesOf(value)[part];
    return isObject(r) ? { ...r } : {};
}

// A rule with its empty keys removed: an empty list, a grade of 0 and roles 'all' all mean "no limit".
export function cleanRule(rule: BlipRule): BlipRule {
    const out: BlipRule = {};
    for (const k of LIST_RULES) {
        const list = (rule[k] ?? []).filter((v, i, a) => typeof v === 'string' && v !== '' && a.indexOf(v) === i);
        if (list.length) out[k] = list;
    }
    if (typeof rule.grade === 'number' && Number.isFinite(rule.grade) && rule.grade > 0)
        out.grade = Math.floor(rule.grade);
    if (rule.roles === 'leader' || rule.roles === 'supervisor') out.roles = rule.roles;
    return out;
}

// The whole rules value with one part's rule set; an empty rule (or null) removes the part, keeping the others.
export function withRule(value: unknown, part: string, rule: BlipRule | null): BlipRules {
    const out: BlipRules = {};
    for (const [k, r] of Object.entries(rulesOf(value))) if (k !== part) out[k] = { ...r };
    const clean = rule ? cleanRule(rule) : {};
    if (Object.keys(clean).length) out[part] = clean;
    return out;
}

// A list rule with one value added or taken out.
export function toggleIn(list: string[] | undefined, v: string, on: boolean): string[] {
    const cur = (list ?? []).filter(x => x !== v);
    return on ? [...cur, v] : cur;
}

// The rule in plain words, one entry per limit: [locale key, its values]. Empty = every officer on the run.
export function ruleSummary(rule: BlipRule, choices?: RuleChoices): { key: string; text: string }[] {
    const clean = cleanRule(rule);
    const out: { key: string; text: string }[] = [];
    const name = (k: ListRule, v: string) => choices?.[k].find(c => c.value === v)?.label ?? v;
    for (const k of LIST_RULES) {
        const list = clean[k];
        if (list?.length)
            out.push({ key: `admin.mission_blips.rule.${k}`, text: list.map(v => name(k, v)).join(', ') });
    }
    if (clean.grade !== undefined) out.push({ key: 'admin.mission_blips.rule.grade', text: String(clean.grade) });
    if (clean.roles) out.push({ key: 'admin.mission_blips.rule.roles', text: clean.roles });
    return out;
}

// The named colour of a blip colour id (undefined = an id without a name here).
export function colourOf(id: unknown): (typeof COLOURS)[number] | undefined {
    return COLOURS.find(c => c.id === id);
}
