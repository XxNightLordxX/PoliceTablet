// Admin UI → Settings and the mission switches: the shapes modules/settings/server.lua sends.

import type { ConfigHealthItem } from '../shared/types';

// How the screen edits a setting.
export type SettingKind =
    | 'boolean'
    | 'number'
    | 'text'
    | 'colour'
    | 'enum'
    | 'optionalText'
    | 'vector'
    | 'list'
    | 'numbers'
    | 'range'
    | 'rows'
    | 'labels'
    | 'goals'
    | 'json';

// One field of a row template (Settings → the six lists of tables). key = undefined for a list of bare points.
export interface RowField {
    key?: string;
    kind: 'text' | 'number' | 'enum' | 'vector';
    min?: number;
    max?: number;
    integer?: boolean;
    options?: string[];
    pattern?: string;
    size?: number;
    // a map position: the row editor offers Use my position and Teleport to
    position?: boolean;
    optional?: boolean;
}

// SettingView.rows: the row editor of a list setting (the server checks every row and the list again).
export interface RowsDescriptor {
    fields?: RowField[];
    // the rows are bare values (Downed.dropOffs: points)
    bare?: RowField;
    min?: number;
    max?: number;
}

export interface SettingView {
    path: string;
    key: string;
    label: string;
    // the comment of config.lua (or blocks.lua) for this key
    desc: string;
    kind: SettingKind;
    // what Crimson-Police uses now; vectors are { x, y, z, w }
    value?: unknown;
    isSet: boolean;
    // the value in config.lua
    default?: unknown;
    defaultSet: boolean;
    // a value saved in game is in use (Reset puts config.lua's back)
    changed: boolean;
    // read once at start: a change is used after a restart of Crimson-Police
    restart?: boolean;
    // a change reloads the missions
    reload?: boolean;
    // a restart setting whose saved value is not the one running now
    pending?: boolean;
    saved?: unknown;
    savedSet?: boolean;
    // may be "not set" (nil in config.lua)
    nullable?: boolean;
    integer?: boolean;
    min?: number;
    max?: number;
    // vector parts, or the numbers of a fixed list
    size?: number;
    item?: 'string' | 'number';
    options?: string[];
    // an enum that may also be false (off)
    allowFalse?: boolean;
    // locale key: why it can only change in config.lua
    locked?: string;
    // a saved value that is no longer allowed (ignored, config.lua's value is used)
    invalid?: string;
    invalidValue?: unknown;
    by?: string;
    at?: number;
    // kind 'rows': the row template
    rows?: RowsDescriptor;
    // a point value: a change applies to runs that end after it and posts a notice to the flags webhook
    points?: boolean;
    // a money switch: turning it on needs the typed word ENABLE (payload.confirm)
    money?: boolean;
}

export interface SettingsGroup {
    path: string;
    label: string;
    desc: string;
    settings: SettingView[];
}

export interface SettingsSection {
    key: string;
    title: string;
    file: 'config' | 'blocks';
    groups: SettingsGroup[];
    changed: number;
    count: number;
}

export interface SettingsData {
    sections: SettingsSection[];
    changed: number;
    pending: number;
    invalid: number;
    total: number;
    // the next daily and weekly reset (unix seconds), shown next to Time.resetHour and Leaderboard.weekStartsOn
    resets?: { daily?: number; weekly?: number };
    // set cp_settings_safe 1: the saved settings are ignored for this start
    safeMode?: boolean;
    // departments added in game (Departments.<key> record settings)
    added?: string[];
}

// The reply of every change: the changed settings, the Config health run right after it.
export interface SettingsReply {
    settings: SettingView[];
    health: ConfigHealthItem[];
    pending: number;
}

// One cp_settings_history row: the full old and new values (oldSaved = false: config.lua's value).
export interface SettingsHistoryRow {
    id: number;
    path: string;
    label?: string;
    action: string;
    old?: unknown;
    oldSaved: boolean;
    new?: unknown;
    newSaved: boolean;
    // short texts of the two values
    oldValue?: string | null;
    newValue?: string | null;
    by: string;
    byName?: string | null;
    reason?: string | null;
    revertsId?: number | null;
    createdAt: number;
    // still the last change of its setting (Revert asks again when it is not)
    latest?: boolean;
    canRevert?: boolean;
}

// admin:exportSettings: the settings changed in game as one JSON text.
export interface SettingsExport {
    text: string;
    count: number;
}

// admin:previewSettingsImport: what an import would change (nothing is saved yet).
export interface SettingsImportPreview {
    changes: { path: string; label: string; old: string; new: string }[];
    unknown: string[];
    locked: string[];
    invalid: { path: string; error: string }[];
    // money switches an import never turns on (turn them on by hand)
    money: string[];
    unchanged: number;
    previewToken: string;
    expiresAt: number;
}

export interface SettingsHistory {
    rows: SettingsHistoryRow[];
    page: number;
    pages: number;
    total: number;
}

// Admin UI → Missions: the on/off switches of a mission and its locations.
export interface LocationSwitch {
    index: number;
    label: string;
    on: boolean;
    defaultOn: boolean;
}

export interface MissionSwitchView {
    on: boolean;
    defaultOn: boolean;
    changed: boolean;
    locations: LocationSwitch[];
    locationsOff: number;
}
