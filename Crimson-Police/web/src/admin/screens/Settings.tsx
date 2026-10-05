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
import { request } from '../../shared/nui';
import { formatDateTime } from '../../shared/format';
import { useAction, useRequest } from '../../shared/hooks';
import { hasKey, t } from '../../shared/i18n';
import { useNavigation } from '../../shared/navigation';
import { toast } from '../../shared/toast';
import type { ConfigHealthItem } from '../../shared/types';
import { RewardPoolEditor, handlesRewardPool } from '../components/RewardPoolEditor';
import { GoalsField, LabelsField, RowsField, TransferPanel } from '../components/SettingsTools';
import { copyLine } from '../components/copyText';
import { JobProgress, useAdminAction } from '../components/kit';
import type { CashSourcePreview } from '../../types/admin_economy';
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
type Panel = 'settings' | 'history' | 'transfer';
const PANELS: { key: Panel; labelKey: string; icon: 'sliders' | 'clock' | 'swap' }[] = [
    { key: 'settings', labelKey: 'settings.tab.settings', icon: 'sliders' },
    { key: 'history', labelKey: 'settings.tab.history', icon: 'clock' },
    { key: 'transfer', labelKey: 'sysadmin.ui.tab.transfer', icon: 'swap' },
];

// A Config health line may name the setting that fixes it, or a server.cfg line to paste.
type HealthLine = ConfigHealthItem & { fix?: string; cfgLine?: string };

type Filter = 'all' | 'changed' | 'restart';
type SavePayload = { value?: unknown; json?: string; none?: boolean; confirm?: string };
type Vec = { x: number; y: number; z?: number; w?: number };

const VEC_PARTS = ['x', 'y', 'z', 'w'] as const;
const MAX_SHOWN = 90;
const HEALTH_TONE = { ok: 'success', warn: 'warning', error: 'danger' } as const;

// admin:trialMissions: the missions a load-time setting would break (modules/missions, Missions.trial)
type TrialReply = { checked: number; failed: { id: string; label?: string; tweak?: boolean; error: string }[] };
// a save that waits for one more look first: the missions it breaks, the pay it moves, the standings it changes
type Preflight = { title: string; message: string; effect?: ReactNode; tone: 'primary' | 'danger' };

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
    // an optional text (a logo link, a text colour) left empty is "not set"
    const payloadOf = (v: string): SavePayload => (s.nullable && v.trim() === '' ? { none: true } : { value: v });
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
                    maxLength={s.nullable ? 512 : 256}
                    placeholder={s.nullable ? t('settings.value.not_set') : undefined}
                    onEnter={() => dirty && void save(payloadOf(text))}
                    aria-label={s.label}
                />
            </div>
            <EditActions
                dirty={dirty}
                disabled={disabled}
                onSave={() => void save(payloadOf(text))}
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
    // the item reward pools have their own editor (the slot handles the paths it knows)
    if (handlesRewardPool(props.s.path)) {
        return (
            <RewardPoolEditor
                path={props.s.path}
                value={props.s.value}
                disabled={props.disabled}
                onSave={value => props.save({ value })}
            />
        );
    }
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
        case 'rows':
            return <RowsField {...props} />;
        case 'labels':
            return <LabelsField {...props} />;
        case 'goals':
            return <GoalsField {...props} />;
        default:
            return <JsonEditor {...props} />;
    }
}

// ============================================================================
//                                 ONE SETTING
// ============================================================================

// Time.resetHour and Leaderboard.weekStartsOn: when the next reset happens (the new value is used after a restart).
function resetLine(s: SettingView, resets?: SettingsData['resets']): string | null {
    if (s.path === 'Time.resetHour' && resets?.daily)
        return t('sysadmin.ui.next_daily', { when: formatDateTime(resets.daily) });
    if (s.path === 'Leaderboard.weekStartsOn' && resets?.weekly)
        return t('sysadmin.ui.next_weekly', { when: formatDateTime(resets.weekly) });
    return null;
}

function SettingRow({
    s,
    disabled,
    save,
    reset,
    resets,
}: {
    s: SettingView;
    disabled: boolean;
    save: (s: SettingView, p: SavePayload) => Promise<boolean>;
    reset: (s: SettingView) => void;
    resets?: SettingsData['resets'];
}) {
    const next = resetLine(s, resets);
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
                    {s.points ? (
                        <Badge
                            size="sm"
                            tone="warning"
                            variant="outline"
                            icon="star"
                            title={t('sysadmin.ui.points_hint')}
                        >
                            {t('sysadmin.ui.points_badge')}
                        </Badge>
                    ) : null}
                    {s.money ? (
                        <Badge size="sm" tone="danger" variant="outline" icon="dollar">
                            {t('sysadmin.ui.money_badge')}
                        </Badge>
                    ) : null}
                </div>
                <code className="settings-row__path">{`Config.${s.path}`}</code>
                {s.desc ? <p className="settings-row__desc">{s.desc}</p> : null}
                {next ? <div className="settings-muted">{next}</div> : null}
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
    onFix,
}: {
    items: HealthLine[];
    loading: boolean;
    onRecheck: () => void;
    onFix: (path: string) => void;
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
                            {i.fix ? (
                                <Button size="sm" variant="ghost" icon="edit" onClick={() => onFix(i.fix ?? '')}>
                                    {t('sysadmin.ui.fix_open')}
                                </Button>
                            ) : null}
                            {i.cfgLine ? (
                                <Button
                                    size="sm"
                                    variant="ghost"
                                    icon="fileText"
                                    onClick={() => copyLine(i.cfgLine ?? '')}
                                >
                                    {t('sysadmin.ui.copy_line')}
                                </Button>
                            ) : null}
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
    const { run, busy } = useAdminAction();
    // the row a Revert is asked for; again = the setting changed since and the admin confirmed anyway
    const [revert, setRevert] = useState<{ row: SettingsHistoryRow; again: boolean; word?: string } | null>(null);
    const rows = asArray(data?.rows);
    const doRevert = async (reason: string, typed: string) => {
        if (!revert) return;
        const res = await run(
            'server:admin:revertSetting',
            { historyId: revert.row.id, reason, again: revert.again, confirm: typed || undefined },
            { requestId: false, silent: true },
        );
        if (res.ok) {
            toast('success', t('sysadmin.ui.reverted', { name: revert.row.label ?? revert.row.path }));
            setRevert(null);
            void refetch();
        } else if (res.error === 'err.setting_changed_since') {
            setRevert({ ...revert, again: true });
        } else if (res.error === 'err.confirm_enable') {
            setRevert({ ...revert, word: 'ENABLE' });
        } else {
            toast('error', errText(res.error || 'err.internal'));
            setRevert(null);
        }
    };
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
            width: 150,
            render: r => (
                <div className="settings-who">
                    <span>{r.by === 'console' ? t('admin.actor.console') : r.byName || r.by}</span>
                    {r.byName ? <code className="settings-row__path">{r.by}</code> : null}
                </div>
            ),
        },
        {
            key: 'what',
            header: t('settings.history.what'),
            render: r => (
                <div className="settings-who">
                    <span>{hasKey(`admin.action.${r.action}`) ? t(`admin.action.${r.action}`) : r.action}</span>
                    <code className="settings-row__path">{r.path}</code>
                    {r.reason ? <span className="settings-muted">{r.reason}</span> : null}
                </div>
            ),
        },
        {
            key: 'change',
            header: t('settings.history.change'),
            render: r => (
                <span className="settings-change">
                    <span>{r.oldSaved ? (r.oldValue ?? '—') : t('sysadmin.ui.config_value')}</span>
                    <Icon name="chevronRight" size={12} />
                    <strong>{r.newSaved ? (r.newValue ?? '—') : t('sysadmin.ui.config_value')}</strong>
                </span>
            ),
        },
        {
            key: 'revert',
            header: '',
            width: 110,
            render: r =>
                r.canRevert ? (
                    <Button
                        size="sm"
                        variant="ghost"
                        icon="undo"
                        disabled={busy}
                        onClick={() => setRevert({ row: r, again: false })}
                    >
                        {t('sysadmin.ui.revert')}
                    </Button>
                ) : null,
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
            <ConfirmDialog
                open={!!revert}
                tone="danger"
                title={t('sysadmin.ui.revert_title', { name: revert?.row.label ?? revert?.row.path ?? '' })}
                message={
                    revert?.again
                        ? t('sysadmin.ui.revert_again')
                        : t('sysadmin.ui.revert_text', {
                              value: revert?.row.oldSaved
                                  ? (revert.row.oldValue ?? '—')
                                  : t('sysadmin.ui.config_value'),
                          })
                }
                reason
                typedWord={revert?.word}
                confirmLabel={t('sysadmin.ui.revert')}
                onConfirm={doRevert}
                onCancel={() => setRevert(null)}
                busy={busy}
            />
        </Card>
    );
}

// ============================================================================
//                                  THE SCREEN
// ============================================================================

// The value a save sends (raw JSON text parsed; undefined when it can't be read, the server answers then).
function payloadValue(p: SavePayload): unknown {
    if (p.none) return undefined;
    if (p.json !== undefined) {
        try {
            return JSON.parse(p.json);
        } catch {
            return undefined;
        }
    }
    return p.value;
}

// One more look before some saves (nothing is saved here; the server checks every value again).
async function preflight(s: SettingView, p: SavePayload): Promise<Preflight | null> {
    const value = payloadValue(p);
    if (s.reload && (p.none || value !== undefined)) {
        const res = await request<TrialReply>('admin:trialMissions', {
            patch: [{ path: s.path, value, none: p.none === true }],
        });
        const failed = res.ok ? asArray(res.data?.failed) : [];
        if (failed.length) {
            return {
                tone: 'danger',
                title: t('int.ui.trial_title', { name: s.label }),
                message: t('int.ui.trial_text', { n: failed.length, checked: res.data?.checked ?? 0 }),
                effect: (
                    <ul className="settings-preflight">
                        {failed.slice(0, 20).map(f => (
                            <li key={f.id}>
                                <strong>{f.label || f.id}</strong> <code>{f.id}</code>
                                <span>{errText(f.error)}</span>
                            </li>
                        ))}
                    </ul>
                ),
            };
        }
    }
    if (s.path === 'Cash.source' && value === 'society' && s.value !== 'society') {
        const res = await request<CashSourcePreview>('admin:previewCashSource', {});
        const depts = res.ok ? asArray(res.data?.departments) : [];
        const short = depts.some(d => d.short);
        return {
            tone: short ? 'danger' : 'primary',
            title: t('int.ui.source_title'),
            message: t(short ? 'int.ui.source_short' : 'int.ui.source_text'),
            effect: depts.length ? (
                <ul className="settings-preflight">
                    {depts.map(d => (
                        <li key={d.department}>
                            <strong>{d.label}</strong> <code>{d.account}</code>
                            <span>
                                {t('int.ui.source_line', {
                                    balance: typeof d.balance === 'number' ? `$${d.balance}` : '?',
                                    rows: d.rows,
                                    owed: `$${d.owed}`,
                                })}
                                {d.short ? ` · ${t('int.ui.source_line_short')}` : ''}
                            </span>
                        </li>
                    ))}
                </ul>
            ) : undefined,
        };
    }
    if (s.path === 'Challenge.bounties' || s.path.startsWith('Challenge.bounties.')) {
        return {
            tone: 'primary',
            title: t('int.ui.bounty_title'),
            message: t('int.ui.bounty_text'),
        };
    }
    return null;
}

// Settings → Badges: re-check every officer's badges against their rows (a job; the progress is pushed).
function RecheckBadges({ disabled }: { disabled?: boolean }) {
    const { run, busy } = useAdminAction();
    const [jobId, setJobId] = useState<string | null>(null);
    const [open, setOpen] = useState(false);
    return (
        <div className="settings-group__tool">
            <Button
                size="sm"
                variant="secondary"
                icon="refresh"
                disabled={disabled || busy}
                onClick={() => setOpen(true)}
            >
                {t('int.ui.recheck_all')}
            </Button>
            {jobId ? <JobProgress jobId={jobId} /> : null}
            <ConfirmDialog
                open={open}
                title={t('int.ui.recheck_all')}
                message={t('int.ui.recheck_all_text')}
                onConfirm={async () => {
                    const res = await run<{ jobId: string }>('server:admin:recheckAllBadges', {});
                    if (res.ok && res.data?.jobId) setJobId(res.data.jobId);
                    setOpen(false);
                }}
                onCancel={() => setOpen(false)}
                busy={busy}
            />
        </div>
    );
}

export default function AdminSettings() {
    const { data, loading, error, refetch, setData } = useRequest<SettingsData>(
        'admin:getSettings',
        {},
        { pushTopic: 'settings' },
    );
    const health = useRequest<HealthLine[]>('admin:getConfigHealth', {});
    const { run, busy } = useAction();
    const [panel, setPanel] = useState<Panel>('settings');
    // Permissions → Config health → Open setting comes here with the path to show
    const { params } = useNavigation();
    const [query, setQuery] = useState(typeof params.q === 'string' ? params.q.toLowerCase() : '');
    const [filter, setFilter] = useState<Filter>('all');
    const [sectionKey, setSectionKey] = useState<string | null>(null);
    const [confirm, setConfirm] = useState<'resetAll' | null>(null);
    // a money switch turned on waits for the typed word (the server checks it too)
    const [money, setMoney] = useState<{ s: SettingView; p: SavePayload; done: (ok: boolean) => void } | null>(null);
    // a point value waits for its confirm: it applies to runs that end after the change
    const [points, setPoints] = useState<{ s: SettingView; p: SavePayload; done: (ok: boolean) => void } | null>(null);
    // one more look first (missions it breaks, the pay it moves, the standings it changes)
    const [pre, setPre] = useState<
        (Preflight & { s: SettingView; p: SavePayload; done: (ok: boolean) => void }) | null
    >(null);

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

    const send = async (s: SettingView, p: SavePayload) => {
        const res = await run<SettingsReply>('server:admin:setSetting', { path: s.path, ...p });
        if (res.ok) apply(res.data);
        return res.ok;
    };
    const proceed = (s: SettingView, p: SavePayload): Promise<boolean> => {
        if (s.money && p.value === true && s.value !== true) {
            return new Promise<boolean>(done => setMoney({ s, p, done }));
        }
        if (s.points) return new Promise<boolean>(done => setPoints({ s, p, done }));
        return send(s, p);
    };
    const save = async (s: SettingView, p: SavePayload): Promise<boolean> => {
        const look = await preflight(s, p);
        if (!look) return proceed(s, p);
        return new Promise<boolean>(done => setPre({ ...look, s, p, done }));
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
                        {g.path === 'Badges' ? <RecheckBadges disabled={busy} /> : null}
                        {g.settings.map(s => (
                            <SettingRow
                                key={s.path}
                                s={s}
                                disabled={busy || !!data?.safeMode}
                                save={save}
                                reset={reset}
                                resets={data?.resets}
                            />
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
    else if (panel === 'transfer') body = <TransferPanel onImported={() => void refetch()} />;
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
                {data?.safeMode ? (
                    <div className="settings-banner settings-banner--danger">
                        <Icon name="alert" size={16} />
                        <div>
                            <strong>{t('sysadmin.ui.safe_title')}</strong>
                            <span>{t('sysadmin.ui.safe_text')}</span>
                        </div>
                    </div>
                ) : null}
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
                    onFix={path => {
                        setFilter('all');
                        setQuery(path.toLowerCase());
                    }}
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
                open={!!money}
                tone="danger"
                title={t('settings.money_title', { name: money?.s.label ?? '' })}
                message={t('settings.money_text')}
                typedWord="ENABLE"
                confirmLabel={t('settings.money_enable')}
                onConfirm={async (_reason, typed) => {
                    const m = money;
                    if (!m) return;
                    const ok = await send(m.s, { ...m.p, confirm: typed });
                    setMoney(null);
                    m.done(ok);
                }}
                onCancel={() => {
                    money?.done(false);
                    setMoney(null);
                }}
                busy={busy}
            />
            <ConfirmDialog
                open={!!pre}
                tone={pre?.tone ?? 'primary'}
                title={pre?.title ?? ''}
                message={pre?.message}
                effect={pre?.effect}
                confirmLabel={t('settings.save')}
                onConfirm={async () => {
                    const m = pre;
                    if (!m) return;
                    setPre(null);
                    m.done(await proceed(m.s, m.p));
                }}
                onCancel={() => {
                    pre?.done(false);
                    setPre(null);
                }}
                busy={busy}
            />
            <ConfirmDialog
                open={!!points}
                title={t('sysadmin.ui.points_title', { name: points?.s.label ?? '' })}
                message={t('sysadmin.ui.points_text')}
                confirmLabel={t('settings.save')}
                onConfirm={async () => {
                    const m = points;
                    if (!m) return;
                    const ok = await send(m.s, m.p);
                    setPoints(null);
                    m.done(ok);
                }}
                onCancel={() => {
                    points?.done(false);
                    setPoints(null);
                }}
                busy={busy}
            />
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
