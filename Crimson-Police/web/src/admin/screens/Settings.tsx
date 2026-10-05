// Admin UI · Settings (screen key 'admin_settings'): every setting of config/config.lua and config/blocks.lua,
// changed in game. The server checks every value again; this screen only helps to enter a valid one.

import { useEffect, useMemo, useState, type ReactNode } from 'react';
import {
    Badge,
    Button,
    Card,
    Checkbox,
    ConfirmDialog,
    EmptyState,
    ErrorState,
    Icon,
    IconButton,
    LoadingBlock,
    NumberInput,
    Screen,
    SearchInput,
    SegmentedControl,
    Select,
    Table,
    Tabs,
    TextInput,
    Textarea,
    Toggle,
    type TableColumn,
} from '../../shared/components';
import { asArray } from '../../shared/data';
import { formatDateTime } from '../../shared/format';
import { useAction, useRequest } from '../../shared/hooks';
import { hasKey, t } from '../../shared/i18n';
import type { ConfigHealthItem } from '../../shared/types';
import type {
    SettingsData,
    SettingsHistory,
    SettingsHistoryRow,
    SettingsReply,
    SettingsSection,
    SettingView,
} from '../../types/settings';
import './Settings.css';

// The panels of this screen, in tab order. A new admin panel about settings is one more entry here.
type Panel = 'settings' | 'history';
const PANELS: { key: Panel; labelKey: string; icon: 'sliders' | 'clock' }[] = [
    { key: 'settings', labelKey: 'settings.tab.settings', icon: 'sliders' },
    { key: 'history', labelKey: 'settings.tab.history', icon: 'clock' },
];

type Filter = 'all' | 'changed' | 'restart';
type SavePayload = { value?: unknown; json?: string; none?: boolean };
type Vec = { x: number; y: number; z?: number; w?: number };

const VEC_PARTS = ['x', 'y', 'z', 'w'] as const;
const MAX_SHOWN = 90;
const HEALTH_TONE = { ok: 'success', warn: 'warning', error: 'danger' } as const;

// ============================================================================
//                                VALUE HELPERS
// ============================================================================

function isObject(v: unknown): v is Record<string, unknown> {
    return !!v && typeof v === 'object' && !Array.isArray(v);
}

function isVec(v: unknown): v is Vec {
    if (!isObject(v) || typeof v.x !== 'number' || typeof v.y !== 'number') return false;
    return Object.keys(v).every(k => (VEC_PARTS as readonly string[]).includes(k));
}

// Lua sends an empty list as {}.
function listOf(v: unknown): unknown[] {
    return Array.isArray(v) ? v : [];
}

function clip(s: string): string {
    return s.length > MAX_SHOWN ? `${s.slice(0, MAX_SHOWN - 1)}…` : s;
}

function fmtNum(n: unknown): string {
    return typeof n === 'number' ? String(Math.round(n * 1000) / 1000) : String(n);
}

// Short text of a value: "Default:", the pending line.
function showValue(v: unknown, set = true): string {
    if (!set || v === null || v === undefined) return t('settings.value.not_set');
    if (v === true) return t('settings.value.on');
    if (v === false) return t('settings.value.off');
    if (typeof v === 'number') return fmtNum(v);
    if (typeof v === 'string') return v === '' ? t('settings.value.empty') : clip(v);
    if (Array.isArray(v)) return v.length ? clip(v.map(x => showValue(x)).join(', ')) : t('settings.value.none');
    if (isVec(v))
        return VEC_PARTS.filter(p => v[p] !== undefined)
            .map(p => fmtNum(v[p]))
            .join(', ');
    if (isObject(v)) return Object.keys(v).length ? clip(JSON.stringify(v)) : t('settings.value.none');
    return String(v);
}

function errText(key: string | null | undefined): string {
    if (!key) return '';
    return hasKey(key) ? t(key) : key;
}

function matches(s: SettingView, q: string): boolean {
    if (!q) return true;
    return (
        s.label.toLowerCase().includes(q) ||
        s.path.toLowerCase().includes(q) ||
        (s.desc ?? '').toLowerCase().includes(q)
    );
}

function changedIn(sec: SettingsSection): number {
    return asArray(sec.groups).reduce((n, g) => n + asArray(g.settings).filter(s => s.changed).length, 0);
}

function passes(s: SettingView, filter: Filter): boolean {
    if (filter === 'changed') return s.changed || !!s.invalid;
    if (filter === 'restart') return !!s.restart;
    return true;
}

// ============================================================================
//                                   EDITORS
// ============================================================================

interface EditorProps {
    s: SettingView;
    disabled: boolean;
    save: (p: SavePayload) => Promise<boolean>;
}

function EditActions({
    dirty,
    disabled,
    onSave,
    onCancel,
}: {
    dirty: boolean;
    disabled: boolean;
    onSave: () => void;
    onCancel: () => void;
}) {
    if (!dirty) return null;
    return (
        <div className="settings-edit__actions">
            <Button size="sm" icon="check" disabled={disabled} onClick={onSave}>
                {t('settings.save')}
            </Button>
            <Button size="sm" variant="ghost" disabled={disabled} onClick={onCancel}>
                {t('common.cancel')}
            </Button>
        </div>
    );
}

function BoolEditor({ s, disabled, save }: EditorProps) {
    return (
        <Toggle
            checked={s.value === true}
            disabled={disabled}
            label={s.value === true ? t('settings.value.on') : t('settings.value.off')}
            onChange={v => void save({ value: v })}
        />
    );
}

const OFF = '__off__';

function EnumEditor({ s, disabled, save }: EditorProps) {
    const options = listOf(s.options).map(o => ({ value: String(o), label: String(o) }));
    if (s.allowFalse) options.push({ value: OFF, label: t('settings.value.off') });
    const current = s.value === false ? OFF : String(s.value ?? '');
    return (
        <Select
            value={current}
            disabled={disabled}
            options={options}
            onChange={v => void save({ value: v === OFF ? false : v })}
        />
    );
}

function NumberEditor({ s, disabled, save }: EditorProps) {
    const base = typeof s.value === 'number' ? s.value : null;
    const [num, setNum] = useState<number | null>(base);
    const [none, setNone] = useState<boolean>(!s.isSet);
    useEffect(() => {
        setNum(base);
        setNone(!s.isSet);
    }, [base, s.isSet]);
    const dirty = none !== !s.isSet || (!none && num !== base);
    const valid = none || num !== null;
    return (
        <div className="settings-edit">
            {s.nullable ? (
                <Checkbox
                    checked={none}
                    disabled={disabled}
                    label={t('settings.not_set_label')}
                    onChange={v => {
                        setNone(v);
                        if (!v && num === null) setNum(typeof s.default === 'number' ? s.default : (s.min ?? 0));
                    }}
                />
            ) : null}
            {!none ? (
                <NumberInput
                    value={num}
                    onChange={setNum}
                    min={s.min}
                    max={s.max}
                    integer={s.integer !== false}
                    step={s.integer === false ? 0.05 : 1}
                    disabled={disabled}
                    aria-label={s.label}
                />
            ) : null}
            <EditActions
                dirty={dirty}
                disabled={disabled || !valid}
                onSave={() => void save(none ? { none: true } : { value: num })}
                onCancel={() => {
                    setNum(base);
                    setNone(!s.isSet);
                }}
            />
        </div>
    );
}

function TextEditor({ s, disabled, save }: EditorProps) {
    const base = typeof s.value === 'string' ? s.value : '';
    const [text, setText] = useState(base);
    useEffect(() => setText(base), [base]);
    const colour = s.kind === 'colour';
    const dirty = text !== base;
    return (
        <div className="settings-edit">
            <div className="settings-edit__line">
                {colour ? (
                    <input
                        type="color"
                        className="settings-colour"
                        value={/^#[0-9a-f]{6}$/i.test(text) ? text : '#000000'}
                        disabled={disabled}
                        aria-label={s.label}
                        onChange={e => setText(e.target.value)}
                    />
                ) : null}
                <TextInput
                    value={text}
                    onChange={setText}
                    disabled={disabled}
                    maxLength={256}
                    onEnter={() => dirty && void save({ value: text })}
                    aria-label={s.label}
                />
            </div>
            <EditActions
                dirty={dirty}
                disabled={disabled}
                onSave={() => void save({ value: text })}
                onCancel={() => setText(base)}
            />
        </div>
    );
}

// "false or an item name" (Config.Tablet.item and the like): a switch and the name.
function OptionalTextEditor({ s, disabled, save }: EditorProps) {
    const baseOn = typeof s.value === 'string';
    const baseText = typeof s.value === 'string' ? s.value : '';
    const [on, setOn] = useState(baseOn);
    const [text, setText] = useState(baseText);
    useEffect(() => {
        setOn(baseOn);
        setText(baseText);
    }, [baseOn, baseText]);
    const dirty = on !== baseOn || (on && text !== baseText);
    return (
        <div className="settings-edit">
            <Toggle
                checked={on}
                disabled={disabled}
                label={on ? t('settings.value.on') : t('settings.value.off')}
                onChange={setOn}
            />
            {on ? (
                <TextInput
                    value={text}
                    onChange={setText}
                    disabled={disabled}
                    maxLength={128}
                    placeholder={t('settings.name_placeholder')}
                    aria-label={s.label}
                />
            ) : null}
            <EditActions
                dirty={dirty}
                disabled={disabled || (on && text.trim() === '')}
                onSave={() => void save({ value: on ? text.trim() : false })}
                onCancel={() => {
                    setOn(baseOn);
                    setText(baseText);
                }}
            />
        </div>
    );
}

// Vectors (x, y, z), fixed lists of numbers and { min, max, default } ranges.
function NumbersEditor({ s, disabled, save }: EditorProps) {
    const vector = s.kind === 'vector';
    const size = s.size ?? (vector ? 3 : listOf(s.value).length);
    const read = (): (number | null)[] => {
        const out: (number | null)[] = [];
        for (let i = 0; i < size; i++) {
            const v = vector ? (isVec(s.value) ? s.value[VEC_PARTS[i]] : undefined) : listOf(s.value)[i];
            out.push(typeof v === 'number' ? v : null);
        }
        return out;
    };
    const baseKey = JSON.stringify(s.value);
    const [nums, setNums] = useState<(number | null)[]>(read);
    useEffect(() => setNums(read()), [baseKey]); // eslint-disable-line react-hooks/exhaustive-deps
    const base = read();
    const dirty = nums.some((n, i) => n !== base[i]);
    const valid = nums.every(n => n !== null);
    const label = (i: number) => {
        if (vector) return VEC_PARTS[i];
        if (s.kind === 'range') return t(['settings.range.min', 'settings.range.max', 'settings.range.default'][i]);
        return `${i + 1}`;
    };
    const integer = vector ? false : s.integer !== false && listOf(s.default).every(n => Number.isInteger(n));
    const payload = () => {
        if (!vector) return { value: nums };
        const v: Record<string, number> = {};
        nums.forEach((n, i) => {
            v[VEC_PARTS[i]] = n ?? 0;
        });
        return { value: v };
    };
    return (
        <div className="settings-edit">
            <div className="settings-numbers">
                {nums.map((n, i) => (
                    <label key={i} className="settings-numbers__item">
                        <span>{label(i)}</span>
                        <NumberInput
                            value={n}
                            integer={integer}
                            step={integer ? 1 : 0.1}
                            stepper={false}
                            min={
                                !vector && s.kind === 'range' && listOf(s.default).every(x => Number(x) >= 0)
                                    ? 0
                                    : undefined
                            }
                            disabled={disabled}
                            onChange={v => setNums(prev => prev.map((x, j) => (j === i ? v : x)))}
                            aria-label={`${s.label} ${label(i)}`}
                        />
                    </label>
                ))}
            </div>
            <EditActions
                dirty={dirty}
                disabled={disabled || !valid}
                onSave={() => void save(payload())}
                onCancel={() => setNums(read())}
            />
        </div>
    );
}

function ListEditor({ s, disabled, save }: EditorProps) {
    const base = listOf(s.value) as (string | number)[];
    const baseKey = JSON.stringify(base);
    const [items, setItems] = useState<(string | number)[]>(base);
    const [adding, setAdding] = useState('');
    useEffect(() => setItems(listOf(s.value) as (string | number)[]), [baseKey]); // eslint-disable-line react-hooks/exhaustive-deps
    const options = listOf(s.options).map(String);
    const numeric = s.item === 'number';
    const dirty = JSON.stringify(items) !== baseKey;
    const add = (raw: string) => {
        const v = raw.trim();
        if (!v) return;
        const item = numeric ? Number(v) : v;
        if (numeric && !isFinite(item as number)) return;
        setItems(prev => [...prev, item]);
        setAdding('');
    };
    return (
        <div className="settings-edit">
            <div className="settings-chips">
                {items.length === 0 ? <span className="settings-muted">{t('settings.value.none')}</span> : null}
                {items.map((it, i) => (
                    <span key={`${i}-${it}`} className="settings-chip">
                        <span>{String(it)}</span>
                        <button
                            type="button"
                            disabled={disabled}
                            aria-label={t('settings.list.remove', { item: String(it) })}
                            onClick={() => setItems(prev => prev.filter((_, j) => j !== i))}
                        >
                            <Icon name="x" size={11} />
                        </button>
                    </span>
                ))}
            </div>
            <div className="settings-edit__line">
                {options.length ? (
                    <Select
                        value=""
                        disabled={disabled}
                        placeholder={t('settings.list.add_option')}
                        options={options.map(o => ({ value: o, label: o }))}
                        onChange={v => add(v)}
                    />
                ) : (
                    <>
                        <TextInput
                            value={adding}
                            onChange={setAdding}
                            disabled={disabled}
                            maxLength={64}
                            placeholder={t('settings.list.add_placeholder')}
                            onEnter={() => add(adding)}
                            aria-label={t('settings.list.add')}
                        />
                        <IconButton
                            icon="plus"
                            size="sm"
                            variant="secondary"
                            label={t('settings.list.add')}
                            disabled={disabled || !adding.trim()}
                            onClick={() => add(adding)}
                        />
                    </>
                )}
            </div>
            <EditActions
                dirty={dirty}
                disabled={disabled}
                onSave={() => void save({ value: items })}
                onCancel={() => setItems(base)}
            />
        </div>
    );
}

function JsonEditor({ s, disabled, save }: EditorProps) {
    const base = s.isSet ? JSON.stringify(s.value ?? null, null, 2) : '';
    const [text, setText] = useState(base);
    const [bad, setBad] = useState(false);
    useEffect(() => {
        setText(base);
        setBad(false);
    }, [base]);
    const dirty = text !== base;
    const submit = () => {
        if (s.nullable && text.trim() === '') return void save({ none: true });
        try {
            JSON.parse(text);
        } catch {
            setBad(true);
            return;
        }
        setBad(false);
        void save({ json: text });
    };
    return (
        <div className="settings-edit settings-edit--wide">
            <Textarea
                value={text}
                onChange={v => {
                    setText(v);
                    setBad(false);
                }}
                rows={Math.min(14, Math.max(3, text.split('\n').length))}
                disabled={disabled}
                invalid={bad}
                spellCheck={false}
                className="settings-json"
                aria-label={s.label}
            />
            {bad ? <div className="settings-error">{t('err.setting_json')}</div> : null}
            {s.nullable ? <div className="settings-muted">{t('settings.json_empty_hint')}</div> : null}
            <EditActions dirty={dirty} disabled={disabled} onSave={submit} onCancel={() => setText(base)} />
        </div>
    );
}

function Editor(props: EditorProps) {
    switch (props.s.kind) {
        case 'boolean':
            return <BoolEditor {...props} />;
        case 'enum':
            return <EnumEditor {...props} />;
        case 'number':
            return <NumberEditor {...props} />;
        case 'text':
        case 'colour':
            return <TextEditor {...props} />;
        case 'optionalText':
            return <OptionalTextEditor {...props} />;
        case 'vector':
        case 'numbers':
        case 'range':
            return <NumbersEditor {...props} />;
        case 'list':
            return <ListEditor {...props} />;
        default:
            return <JsonEditor {...props} />;
    }
}

// ============================================================================
//                                 ONE SETTING
// ============================================================================

function SettingRow({
    s,
    disabled,
    save,
    reset,
}: {
    s: SettingView;
    disabled: boolean;
    save: (s: SettingView, p: SavePayload) => Promise<boolean>;
    reset: (s: SettingView) => void;
}) {
    return (
        <div className={`settings-row${s.changed ? ' is-changed' : ''}${s.invalid ? ' is-invalid' : ''}`}>
            <div className="settings-row__info">
                <div className="settings-row__title">
                    <strong>{s.label}</strong>
                    {s.changed ? (
                        <Badge size="sm" tone="accent" icon="edit">
                            {t('settings.badge.changed')}
                        </Badge>
                    ) : null}
                    {s.restart ? (
                        <Badge
                            size="sm"
                            tone="warning"
                            variant="outline"
                            icon="refresh"
                            title={t('settings.restart_hint')}
                        >
                            {t('settings.badge.restart')}
                        </Badge>
                    ) : null}
                    {s.reload ? (
                        <Badge
                            size="sm"
                            tone="neutral"
                            variant="outline"
                            icon="layers"
                            title={t('settings.reload_hint')}
                        >
                            {t('settings.badge.reload')}
                        </Badge>
                    ) : null}
                    {s.locked ? (
                        <Badge size="sm" tone="grey" icon="lock">
                            {t('settings.badge.locked')}
                        </Badge>
                    ) : null}
                </div>
                <code className="settings-row__path">{`Config.${s.path}`}</code>
                {s.desc ? <p className="settings-row__desc">{s.desc}</p> : null}
                {s.pending ? (
                    <div className="settings-note settings-note--warning">
                        <Icon name="refresh" size={13} />
                        <span>
                            {t('settings.pending_line', {
                                now: showValue(s.value, s.isSet),
                                next: showValue(s.saved, s.savedSet !== false),
                            })}
                        </span>
                    </div>
                ) : null}
                {s.invalid ? (
                    <div className="settings-note settings-note--danger">
                        <Icon name="alert" size={13} />
                        <span>
                            {t('settings.invalid_line', {
                                value: showValue(s.invalidValue),
                                why: errText(s.invalid),
                            })}
                        </span>
                    </div>
                ) : null}
            </div>
            <div className="settings-row__edit">
                {s.locked ? (
                    <div className="settings-locked">
                        <span className="settings-row__value">{showValue(s.value, s.isSet)}</span>
                        <span className="settings-muted">{errText(s.locked)}</span>
                    </div>
                ) : (
                    <Editor s={s} disabled={disabled} save={p => save(s, p)} />
                )}
                <div className="settings-row__meta">
                    <span className="settings-muted">
                        {t('settings.default', { value: showValue(s.default, s.defaultSet) })}
                    </span>
                    {(s.changed || s.invalid) && !s.locked ? (
                        <Button size="sm" variant="ghost" icon="refresh" disabled={disabled} onClick={() => reset(s)}>
                            {t('settings.reset')}
                        </Button>
                    ) : null}
                </div>
            </div>
        </div>
    );
}

// ============================================================================
//                                CONFIG HEALTH
// ============================================================================

function HealthCard({
    items,
    loading,
    onRecheck,
}: {
    items: ConfigHealthItem[];
    loading: boolean;
    onRecheck: () => void;
}) {
    const problems = items.filter(i => i.level !== 'ok');
    return (
        <Card
            title={t('access.health.title')}
            icon="activity"
            padding="sm"
            subtitle={problems.length ? t('access.health.problems', { n: problems.length }) : t('access.health.all_ok')}
            actions={
                <IconButton
                    icon="refresh"
                    size="sm"
                    variant="secondary"
                    label={t('access.health.recheck')}
                    loading={loading}
                    onClick={onRecheck}
                />
            }
        >
            {problems.length ? (
                <ul className="settings-health">
                    {problems.map((i, n) => (
                        <li key={`${i.check}-${n}`}>
                            <Badge size="sm" tone={HEALTH_TONE[i.level] ?? 'grey'}>
                                {t(`access.health.level.${i.level}`)}
                            </Badge>
                            <span>{i.text}</span>
                        </li>
                    ))}
                </ul>
            ) : (
                <div className="settings-muted">{t('settings.health_clean')}</div>
            )}
        </Card>
    );
}

// ============================================================================
//                                   HISTORY
// ============================================================================

function HistoryPanel() {
    const [page, setPage] = useState(1);
    const { data, loading, error, refetch } = useRequest<SettingsHistory>(
        'admin:getSettingsHistory',
        { page },
        { pushTopic: 'settings' },
    );
    const rows = asArray(data?.rows);
    const columns: TableColumn<SettingsHistoryRow>[] = [
        {
            key: 'when',
            header: t('settings.history.when'),
            width: 150,
            render: r => <span className="settings-nowrap">{formatDateTime(r.createdAt)}</span>,
        },
        {
            key: 'who',
            header: t('settings.history.who'),
            width: 170,
            render: r => (
                <div className="settings-who">
                    <span>{r.actorName || r.actor}</span>
                    <span className="settings-muted">{t(`admin.role.${r.role}`)}</span>
                </div>
            ),
        },
        {
            key: 'what',
            header: t('settings.history.what'),
            render: r => (
                <div className="settings-who">
                    <span>{hasKey(`admin.action.${r.action}`) ? t(`admin.action.${r.action}`) : r.action}</span>
                    {r.target ? <code className="settings-row__path">{r.target}</code> : null}
                    {r.reason ? <span className="settings-muted">{r.reason}</span> : null}
                </div>
            ),
        },
        {
            key: 'change',
            header: t('settings.history.change'),
            render: r =>
                r.oldValue || r.newValue ? (
                    <span className="settings-change">
                        <span>{r.oldValue ?? '—'}</span>
                        <Icon name="chevronRight" size={12} />
                        <strong>{r.newValue ?? '—'}</strong>
                    </span>
                ) : (
                    '—'
                ),
        },
    ];
    if (loading && !data) return <LoadingBlock />;
    if (error && !data) return <ErrorState error={error} onRetry={() => void refetch()} />;
    return (
        <Card
            title={t('settings.history.title')}
            subtitle={t('settings.history.subtitle', { n: data?.total ?? 0 })}
            icon="clock"
            padding="none"
            actions={
                (data?.pages ?? 1) > 1 ? (
                    <div className="settings-pager">
                        <IconButton
                            icon="chevronLeft"
                            size="sm"
                            variant="ghost"
                            label={t('settings.history.newer')}
                            disabled={page <= 1}
                            onClick={() => setPage(p => Math.max(1, p - 1))}
                        />
                        <span className="cp-num">{`${data?.page ?? 1} / ${data?.pages ?? 1}`}</span>
                        <IconButton
                            icon="chevronRight"
                            size="sm"
                            variant="ghost"
                            label={t('settings.history.older')}
                            disabled={page >= (data?.pages ?? 1)}
                            onClick={() => setPage(p => p + 1)}
                        />
                    </div>
                ) : null
            }
        >
            <Table
                columns={columns}
                rows={rows}
                rowKey={r => String(r.id)}
                dense
                empty={<EmptyState compact icon="clock" title={t('settings.history.none')} />}
                aria-label={t('settings.history.title')}
            />
        </Card>
    );
}

// ============================================================================
//                                  THE SCREEN
// ============================================================================

export default function AdminSettings() {
    const { data, loading, error, refetch, setData } = useRequest<SettingsData>(
        'admin:getSettings',
        {},
        { pushTopic: 'settings' },
    );
    const health = useRequest<ConfigHealthItem[]>('admin:getConfigHealth', {});
    const { run, busy } = useAction();
    const [panel, setPanel] = useState<Panel>('settings');
    const [query, setQuery] = useState('');
    const [filter, setFilter] = useState<Filter>('all');
    const [sectionKey, setSectionKey] = useState<string | null>(null);
    const [confirm, setConfirm] = useState<'resetAll' | null>(null);

    const sections = asArray(data?.sections);
    const all = useMemo(
        () => sections.flatMap(sec => asArray(sec.groups).flatMap(g => asArray(g.settings))),
        [sections],
    );
    const counts = useMemo(
        () => ({
            changed: all.filter(s => s.changed).length,
            pending: all.filter(s => s.pending).length,
            invalid: all.filter(s => s.invalid).length,
        }),
        [all],
    );
    const q = query.trim().toLowerCase();
    const searching = q !== '' || filter !== 'all';
    const current = sections.find(s => s.key === sectionKey) ?? sections[0];

    // A reply carries the settings it changed: show them at once (the 'settings' push refetches the rest).
    const apply = (reply: SettingsReply | undefined) => {
        if (!reply) return;
        const byPath = new Map(asArray(reply.settings).map(s => [s.path, s]));
        setData(prev =>
            prev
                ? {
                      ...prev,
                      sections: asArray(prev.sections).map(sec => ({
                          ...sec,
                          groups: asArray(sec.groups).map(g => ({
                              ...g,
                              settings: asArray(g.settings).map(s => byPath.get(s.path) ?? s),
                          })),
                      })),
                  }
                : prev,
        );
        if (reply.health) health.setData(asArray(reply.health));
    };

    const save = async (s: SettingView, p: SavePayload) => {
        const res = await run<SettingsReply>('server:admin:setSetting', { path: s.path, ...p });
        if (res.ok) apply(res.data);
        return res.ok;
    };
    const reset = async (s: SettingView) => {
        const res = await run<SettingsReply>(
            'server:admin:resetSetting',
            { path: s.path },
            { success: 'settings.reset_done', successVars: { name: s.label } },
        );
        if (res.ok) apply(res.data);
    };
    const doConfirm = async () => {
        const res = await run<SettingsReply>(
            'server:admin:resetAllSettings',
            {},
            { success: 'settings.reset_all_done' },
        );
        if (res.ok) {
            if (res.data?.health) health.setData(asArray(res.data.health));
            void refetch();
        }
        setConfirm(null);
    };

    const renderSection = (sec: SettingsSection, list: (s: SettingView) => boolean, heading: boolean) => {
        const groups = asArray(sec.groups)
            .map(g => ({ ...g, settings: asArray(g.settings).filter(list) }))
            .filter(g => g.settings.length);
        if (!groups.length) return null;
        return (
            <Card
                key={sec.key}
                title={heading ? sec.title : undefined}
                icon={heading ? 'sliders' : undefined}
                subtitle={heading ? t(`settings.file.${sec.file}`) : undefined}
                padding="none"
                className="settings-section"
            >
                {groups.map(g => (
                    <div key={g.path || '_'} className="settings-group">
                        {g.label ? (
                            <div className="settings-group__head">
                                <strong>{g.label}</strong>
                                {g.desc ? <span>{g.desc}</span> : null}
                            </div>
                        ) : null}
                        {g.settings.map(s => (
                            <SettingRow key={s.path} s={s} disabled={busy} save={save} reset={reset} />
                        ))}
                    </div>
                ))}
            </Card>
        );
    };

    let body: ReactNode;
    if (loading && !data) body = <LoadingBlock />;
    else if (error && !data)
        body = (
            <Card>
                <ErrorState error={error} onRetry={() => void refetch()} />
            </Card>
        );
    else if (panel === 'history') body = <HistoryPanel />;
    else {
        const found = searching
            ? sections.map(sec => renderSection(sec, s => matches(s, q) && passes(s, filter), true)).filter(Boolean)
            : [];
        body = (
            <>
                <div className="settings-intro">
                    <Icon name="info" size={16} />
                    <div>
                        <strong>{t('settings.intro_title')}</strong>
                        <span>{t('settings.intro')}</span>
                    </div>
                </div>
                {counts.pending > 0 ? (
                    <div className="settings-banner settings-banner--warning">
                        <Icon name="refresh" size={16} />
                        <div>
                            <strong>{t('settings.restart.pending', { n: counts.pending })}</strong>
                            <span>{t('settings.restart.manual', { resource: 'Crimson-Police' })}</span>
                        </div>
                    </div>
                ) : null}
                {counts.invalid > 0 ? (
                    <div className="settings-banner settings-banner--danger">
                        <Icon name="alert" size={16} />
                        <div>
                            <strong>{t('settings.invalid_title', { n: counts.invalid })}</strong>
                            <span>{t('settings.invalid_text')}</span>
                        </div>
                    </div>
                ) : null}
                <HealthCard
                    items={asArray(health.data)}
                    loading={health.loading}
                    onRecheck={() => void health.refetch()}
                />
                <div className="settings-toolbar">
                    <SearchInput
                        value={query}
                        onChange={setQuery}
                        placeholder={t('settings.search')}
                        className="settings-search"
                    />
                    <SegmentedControl<Filter>
                        size="sm"
                        value={filter}
                        onChange={setFilter}
                        items={[
                            { key: 'all', label: t('settings.filter.all') },
                            { key: 'changed', label: t('settings.filter.changed', { n: counts.changed }) },
                            { key: 'restart', label: t('settings.filter.restart') },
                        ]}
                    />
                    <span className="cp-spacer" />
                    <Button
                        variant="danger"
                        size="sm"
                        icon="refresh"
                        disabled={busy || counts.changed + counts.invalid === 0}
                        onClick={() => setConfirm('resetAll')}
                    >
                        {t('settings.reset_all')}
                    </Button>
                </div>
                {searching ? (
                    found.length ? (
                        <div className="settings-results">{found}</div>
                    ) : (
                        <EmptyState icon="search" title={t('settings.no_match')} />
                    )
                ) : (
                    <div className="settings-layout">
                        <nav className="settings-nav" aria-label={t('settings.sections')}>
                            {sections.map(sec => (
                                <button
                                    key={sec.key}
                                    type="button"
                                    className={`settings-nav__item${current?.key === sec.key ? ' is-active' : ''}`}
                                    onClick={() => setSectionKey(sec.key)}
                                >
                                    <span>{sec.title}</span>
                                    {changedIn(sec) > 0 ? (
                                        <Badge size="sm" tone="accent">
                                            {changedIn(sec)}
                                        </Badge>
                                    ) : null}
                                </button>
                            ))}
                        </nav>
                        <div className="settings-main">{current ? renderSection(current, () => true, true) : null}</div>
                    </div>
                )}
            </>
        );
    }

    return (
        <Screen
            title={t('ui.screen.admin_settings')}
            subtitle={t('settings.subtitle', { n: data?.total ?? all.length, changed: counts.changed })}
            actions={
                <IconButton
                    icon="refresh"
                    label={t('sup.refresh')}
                    variant="secondary"
                    loading={loading && !!data}
                    onClick={() => void refetch()}
                />
            }
            className="settings-screen"
        >
            <Tabs<Panel>
                value={panel}
                onChange={setPanel}
                items={PANELS.map(p => ({
                    key: p.key,
                    label: t(p.labelKey),
                    icon: p.icon,
                    badge: p.key === 'settings' && counts.changed ? counts.changed : undefined,
                }))}
            />
            {body}
            <ConfirmDialog
                open={!!confirm}
                tone="danger"
                title={t('settings.reset_all_title')}
                message={t('settings.reset_all_text', { n: counts.changed + counts.invalid })}
                confirmLabel={t('settings.reset_all')}
                onConfirm={doConfirm}
                onCancel={() => setConfirm(null)}
                busy={busy}
            />
        </Screen>
    );
}
