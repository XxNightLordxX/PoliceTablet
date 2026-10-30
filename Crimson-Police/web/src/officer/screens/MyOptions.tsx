// Officer UI · My options (screen key 'options'): one place where an officer sets the tablet up for himself. One

import { useCallback, useEffect, useRef, useState } from 'react';
import {
    Badge,
    Button,
    Card,
    Checkbox,
    EmptyState,
    ErrorState,
    Field,
    Icon,
    LoadingBlock,
    NumberInput,
    Screen,
    Select,
    Toggle,
} from '../../shared/components';
import { cx } from '../../shared/cx';
import { useAction, useRequest } from '../../shared/hooks';
import { hasKey, t } from '../../shared/i18n';
import { clientAction } from '../../shared/nui';
import { useOptions } from '../../shared/options';
import { useSession } from '../../shared/session';
import type { OfficerOptionValue } from '../../shared/types';
import type { ProfileData } from '../../types/boards';
import type { KeyLabel, OptionDef, OptionsView } from '../../types/options';
import type { ProfileEdit, ProfileSetPayload } from '../../types/profile';
import '../components/ProfileCards.css';
import './MyOptions.css';

const SAVE_DELAY_MS = 500;
const SAVED_SHOW_MS = 2500;

// The text of each Crimson-Police key mapping: the same words GTA Settings > Key Bindings > FiveM shows.
const KEY_TEXT: Record<string, string> = {
    crimsonpolice_tablet: 'tablet.keybind_label',
    crimsonpolice_dispatch: 'tablet.dispatch_key_label',
    crimsonpolice_ready: 'unit.ready.keybind_label',
    crimsonpolice_contact: 'npc.contact_keybind',
};

function textOr(key: string, fallback: string): string {
    return hasKey(key) ? t(key) : fallback;
}

// A key or group without its own text: 'board_view' -> 'Board view'.
function humanize(key: string): string {
    const words = key.replace(/[_.-]+/g, ' ').trim();
    return words.charAt(0).toUpperCase() + words.slice(1);
}

function same(a: OfficerOptionValue | undefined, b: OfficerOptionValue | undefined): boolean {
    if (Array.isArray(a) && Array.isArray(b)) return a.length === b.length && a.every((x, i) => x === b[i]);
    return a === b;
}

// Saves one value after the officer stops changing it (SAVE_DELAY_MS); pending saves run at once on unmount.
function useDebouncedSave(save: (key: string, value: OfficerOptionValue) => void) {
    const timers = useRef<Record<string, { id: ReturnType<typeof setTimeout>; value: OfficerOptionValue }>>({});
    const saveRef = useRef(save);
    saveRef.current = save;
    useEffect(
        () => () => {
            for (const [key, p] of Object.entries(timers.current)) {
                clearTimeout(p.id);
                saveRef.current(key, p.value);
            }
            timers.current = {};
        },
        [],
    );
    return useCallback((key: string, value: OfficerOptionValue) => {
        const old = timers.current[key];
        if (old) clearTimeout(old.id);
        const id = setTimeout(() => {
            delete timers.current[key];
            saveRef.current(key, value);
        }, SAVE_DELAY_MS);
        timers.current[key] = { id, value };
    }, []);
}

// The keys saved a moment ago (the inline "Saved").
function useSavedMarks() {
    const [marks, setMarks] = useState<Record<string, number>>({});
    useEffect(() => {
        const keys = Object.keys(marks);
        if (keys.length === 0) return;
        const id = setTimeout(() => {
            const now = Date.now();
            setMarks(m => Object.fromEntries(Object.entries(m).filter(([, at]) => now - at < SAVED_SHOW_MS)));
        }, SAVED_SHOW_MS);
        return () => clearTimeout(id);
    }, [marks]);
    const mark = useCallback((key: string) => setMarks(m => ({ ...m, [key]: Date.now() })), []);
    return { marks, mark };
}

function Saved({ show }: { show: boolean }) {
    return show ? (
        <span className="my-options__saved" role="status">
            <Icon name="check" size={12} />
            {t('options.saved')}
        </span>
    ) : null;
}

function StoreChip({ store }: { store: 'server' | 'local' }) {
    return (
        <Badge
            size="sm"
            tone={store === 'local' ? 'primary' : 'neutral'}
            icon={store === 'local' ? 'server' : 'user'}
            title={t(store === 'local' ? 'options.chip.local_hint' : 'options.chip.server_hint')}
        >
            {t(store === 'local' ? 'options.chip.local' : 'options.chip.server')}
        </Badge>
    );
}

// ============================================================================
//                                 OPTION ROWS
// ============================================================================

function OptionControl({
    def,
    value,
    label,
    onChange,
}: {
    def: OptionDef;
    value: OfficerOptionValue;
    label: string;
    onChange: (v: OfficerOptionValue) => void;
}) {
    const values = Array.isArray(def.values) ? def.values : [];
    const valueLabel = (v: string | number) => textOr(`options.value.${def.key}.${v}`, humanize(String(v)));
    if (def.kind === 'bool') return <Toggle checked={value === true} onChange={onChange} />;
    if (def.kind === 'enum') {
        return (
            <Select
                value={String(value)}
                onChange={s => onChange(values.find(v => String(v) === s) ?? s)}
                options={values.map(v => ({ value: String(v), label: valueLabel(v) }))}
                aria-label={label}
            />
        );
    }
    if (def.kind === 'list') {
        const picked = Array.isArray(value) ? value : [];
        return (
            <div className="my-options__list">
                {values.map(v => (
                    <Checkbox
                        key={String(v)}
                        checked={picked.includes(v)}
                        label={valueLabel(v)}
                        onChange={on => onChange(on ? [...picked, v] : picked.filter(x => x !== v))}
                    />
                ))}
            </div>
        );
    }
    return (
        <NumberInput
            value={typeof value === 'number' ? value : null}
            onChange={n => {
                if (n !== null) onChange(n);
            }}
            min={def.bounds?.min}
            max={def.bounds?.max}
            integer={false}
            aria-label={label}
        />
    );
}

function OptionGroup({
    group,
    defs,
    valueOf,
    onChange,
    onReset,
    marks,
}: {
    group: string;
    defs: OptionDef[];
    valueOf: (def: OptionDef) => OfficerOptionValue;
    onChange: (def: OptionDef, v: OfficerOptionValue) => void;
    onReset: (defs: OptionDef[]) => void;
    marks: Record<string, number>;
}) {
    const changed = defs.filter(d => !same(valueOf(d), d.default));
    return (
        <Card
            title={textOr(`options.group.${group}`, humanize(group))}
            icon="sliders"
            padding="md"
            className="my-options__card"
            actions={
                <Button
                    size="sm"
                    variant="ghost"
                    icon="undo"
                    disabled={changed.length === 0}
                    onClick={() => onReset(changed)}
                >
                    {t('options.reset')}
                </Button>
            }
        >
            <div className="my-options__rows">
                {defs.map(def => {
                    const label = textOr(`options.key.${def.key}`, humanize(def.key));
                    const hint = hasKey(`options.key.${def.key}_hint`) ? t(`options.key.${def.key}_hint`) : null;
                    return (
                        <div key={def.key} className="my-options__row">
                            <div className="my-options__text">
                                <span className="my-options__label">
                                    {label} <StoreChip store={def.store} />
                                    <Saved show={!!marks[def.key]} />
                                </span>
                                {hint ? <span className="my-options__hint">{hint}</span> : null}
                            </div>
                            <div className={cx('my-options__control', `is-${def.kind}`)}>
                                <OptionControl
                                    def={def}
                                    value={valueOf(def)}
                                    label={label}
                                    onChange={v => onChange(def, v)}
                                />
                            </div>
                        </div>
                    );
                })}
            </div>
        </Card>
    );
}

// ============================================================================
//                           TABLET LOOK AND PRIVACY
// ============================================================================

function appearanceLabel(key: string): string {
    return textOr(`profile.edit.appearance.${key}`, key);
}

function LookCard() {
    const session = useSession();
    const cfg = session.config?.profile;
    const edit = useRequest<ProfileEdit>('getProfileEdit', {});
    const profile = useRequest<ProfileData>('getProfile', {});
    const { run } = useAction();
    const { marks, mark } = useSavedMarks();
    const [scale, setScale] = useState<number | null>(null);
    const prefs = edit.data?.prefs;
    const level = edit.data?.level.n ?? 1;
    const scaleRange = cfg?.uiScale ?? [0.85, 1.25, 1];
    const accents = Array.isArray(cfg?.accents) ? cfg.accents : [];
    const appearances = Array.isArray(cfg?.appearances) ? cfg.appearances : ['department'];

    // the same action and checks as the Edit profile dialog's Look tab; the look applies at once
    const save = useCallback(
        async (patch: ProfileSetPayload, mk: string) => {
            const res = await run('server:profile:set', patch);
            if (!res.ok) return;
            edit.setData(prev =>
                prev
                    ? {
                          ...prev,
                          prefs: {
                              ...prev.prefs,
                              ...(patch.appearance !== undefined ? { appearance: patch.appearance } : {}),
                              ...(patch.accent !== undefined ? { accent: patch.accent || null } : {}),
                              ...(patch.uiScale !== undefined ? { uiScale: patch.uiScale } : {}),
                              ...(patch.callsMuted !== undefined ? { callsMuted: patch.callsMuted } : {}),
                          },
                      }
                    : prev,
            );
            mark(mk);
        },
        [run, edit, mark],
    );
    const saveLater = useDebouncedSave((_key, v) => {
        void save({ uiScale: v as number }, 'uiScale');
    });

    const toggleHide = async (value: boolean) => {
        const res = await run<{ hideName: boolean }>('server:setHideName', value, {
            success: value ? 'profile.hide_on' : 'profile.hide_off',
        });
        if (res.ok) {
            profile.setData(prev => (prev ? { ...prev, hideName: res.data?.hideName ?? value } : prev));
            mark('hideName');
        }
    };

    const shownScale = scale ?? prefs?.uiScale ?? 1;
    return (
        <Card title={t('options.look.title')} icon="eye" padding="md" className="my-options__card">
            {!prefs && edit.loading ? (
                <LoadingBlock />
            ) : !prefs ? (
                <ErrorState error={edit.error ?? 'err.internal'} onRetry={() => void edit.refetch()} />
            ) : (
                <div className="my-options__rows">
                    <Field
                        label={
                            <>
                                {t('profile.edit.appearance')} <StoreChip store="server" />
                                <Saved show={!!marks.appearance} />
                            </>
                        }
                        hint={t('profile.edit.appearance_hint')}
                    >
                        <Select
                            value={prefs.appearance}
                            onChange={v => void save({ appearance: v }, 'appearance')}
                            options={appearances.map(a => ({ value: a, label: appearanceLabel(a) }))}
                        />
                    </Field>
                    <Field
                        label={
                            <>
                                {t('profile.edit.accent')} <StoreChip store="server" />
                                <Saved show={!!marks.accent} />
                            </>
                        }
                        hint={t('profile.edit.accent_hint')}
                    >
                        <div className="profile-edit__accents" role="radiogroup">
                            <button
                                type="button"
                                role="radio"
                                aria-checked={!prefs.accent}
                                className={cx('profile-edit__swatch is-default', !prefs.accent && 'is-selected')}
                                title={t('profile.edit.accent_department')}
                                onClick={() => void save({ accent: false }, 'accent')}
                            >
                                <Icon name="building" size={14} />
                            </button>
                            {accents.map(a => {
                                const locked = a.level !== null && a.level !== undefined && level < a.level;
                                return (
                                    <button
                                        key={a.colour}
                                        type="button"
                                        role="radio"
                                        aria-checked={prefs.accent === a.colour}
                                        disabled={locked}
                                        className={cx(
                                            'profile-edit__swatch',
                                            prefs.accent === a.colour && 'is-selected',
                                            locked && 'is-locked',
                                        )}
                                        style={{ background: a.colour }}
                                        title={
                                            locked
                                                ? t('profile.edit.unlocks_at', { level: a.level as number })
                                                : a.colour
                                        }
                                        onClick={() => void save({ accent: a.colour }, 'accent')}
                                    >
                                        {locked ? <Icon name="lock" size={12} /> : null}
                                    </button>
                                );
                            })}
                        </div>
                    </Field>
                    <Field
                        label={
                            <>
                                {t('profile.edit.scale')} <StoreChip store="server" />
                                <Saved show={!!marks.uiScale} />
                            </>
                        }
                        hint={t('profile.edit.scale_hint', { value: Math.round(shownScale * 100) })}
                    >
                        <input
                            className="profile-edit__range"
                            type="range"
                            min={Math.round(scaleRange[0] * 100)}
                            max={Math.round(scaleRange[1] * 100)}
                            step={5}
                            value={Math.round(shownScale * 100)}
                            onChange={e => {
                                const v = Number(e.target.value) / 100;
                                setScale(v);
                                saveLater('uiScale', v);
                            }}
                        />
                    </Field>
                    <div className="my-options__toggle">
                        <Toggle
                            checked={prefs.callsMuted}
                            onChange={v => void save({ callsMuted: v }, 'callsMuted')}
                            label={t('profile.edit.mute')}
                            description={t('profile.edit.mute_hint')}
                        />
                        <span className="my-options__chips">
                            <StoreChip store="server" />
                            <Saved show={!!marks.callsMuted} />
                        </span>
                    </div>
                    {profile.data ? (
                        <div className="my-options__toggle">
                            <Toggle
                                checked={!!profile.data.hideName}
                                onChange={v => void toggleHide(v)}
                                label={t('profile.hide_name')}
                                description={t('profile.hide_name_hint')}
                            />
                            <span className="my-options__chips">
                                <StoreChip store="server" />
                                <Saved show={!!marks.hideName} />
                            </span>
                        </div>
                    ) : null}
                </div>
            )}
        </Card>
    );
}

// ============================================================================
//                                   MY KEYS
// ============================================================================

function KeysCard() {
    const [keys, setKeys] = useState<KeyLabel[] | null>(null);
    useEffect(() => {
        let live = true;
        void clientAction<{ keys?: KeyLabel[] }>('getKeyLabels').then(res => {
            if (live) setKeys(res.ok && Array.isArray(res.data?.keys) ? res.data.keys : []);
        });
        return () => {
            live = false;
        };
    }, []);
    return (
        <Card
            title={t('options.keys.title')}
            subtitle={t('options.keys.hint')}
            icon="key"
            padding="md"
            className="my-options__card"
        >
            {keys === null ? (
                <LoadingBlock />
            ) : (
                <div className="my-options__rows">
                    {keys.map(k => (
                        <div key={k.command} className="my-options__row is-key">
                            <span className="my-options__label">
                                {KEY_TEXT[k.command] ? t(KEY_TEXT[k.command]) : k.command}
                            </span>
                            {k.state === 'set' ? (
                                <kbd className="my-options__kbd">{k.label}</kbd>
                            ) : (
                                <span className="my-options__unset">
                                    {t(k.state === 'other' ? 'options.keys.other' : 'options.keys.unset')}
                                </span>
                            )}
                        </div>
                    ))}
                </div>
            )}
        </Card>
    );
}

// ============================================================================
//                                    SCREEN
// ============================================================================

export default function MyOptions() {
    const { data, loading, error, refetch } = useRequest<OptionsView>('getOptions', {});
    const { local, server, setLocal } = useOptions();
    const { run } = useAction();
    const { marks, mark } = useSavedMarks();
    const [draft, setDraft] = useState<Record<string, OfficerOptionValue>>({});

    const schema = data && Array.isArray(data.schema) ? data.schema : [];
    const fetched = data && !Array.isArray(data.values) ? data.values : {};

    const valueOf = (def: OptionDef): OfficerOptionValue => {
        if (def.key in draft) return draft[def.key];
        if (def.store === 'local') return def.key in local ? local[def.key] : def.default;
        if (def.key in server) return server[def.key];
        return def.key in fetched ? fetched[def.key] : def.default;
    };

    const saveServer = useCallback(
        async (patch: Record<string, OfficerOptionValue>) => {
            const res = await run('server:options:set', patch);
            if (res.ok) for (const key of Object.keys(patch)) mark(key);
            return res.ok;
        },
        [run, mark],
    );
    const saveLocal = useCallback(
        async (key: string, value: OfficerOptionValue) => {
            const res = await setLocal(key, value);
            if (res.ok) mark(key);
            return res.ok;
        },
        [setLocal, mark],
    );
    const saveLater = useDebouncedSave((key, value) => {
        const def = schema.find(d => d.key === key);
        const done = () =>
            setDraft(d => {
                if (!same(d[key], value)) return d;
                const next = { ...d };
                delete next[key];
                return next;
            });
        if (def?.store === 'local') void saveLocal(key, value).then(done);
        else void saveServer({ [key]: value }).then(done);
    });

    const change = (def: OptionDef, value: OfficerOptionValue) => {
        setDraft(d => ({ ...d, [def.key]: value }));
        saveLater(def.key, value);
    };

    const reset = async (defs: OptionDef[]) => {
        const patch: Record<string, OfficerOptionValue> = {};
        for (const def of defs) {
            if (def.store === 'local') await saveLocal(def.key, def.default);
            else patch[def.key] = def.default;
        }
        if (Object.keys(patch).length > 0) await saveServer(patch);
        setDraft(d => Object.fromEntries(Object.entries(d).filter(([k]) => !defs.some(x => x.key === k))));
    };

    const groups: { group: string; defs: OptionDef[] }[] = [];
    for (const def of schema) {
        const g = groups.find(x => x.group === def.group);
        if (g) g.defs.push(def);
        else groups.push({ group: def.group, defs: [def] });
    }

    return (
        <Screen title={t('ui.screen.options')} subtitle={t('options.subtitle')} className="my-options">
            {!data && loading ? (
                <LoadingBlock />
            ) : !data ? (
                <ErrorState error={error ?? 'err.internal'} onRetry={() => void refetch()} />
            ) : data.enabled === false ? (
                <EmptyState icon="lock" title={t('options.locked_title')} text={t('options.locked_text')} />
            ) : (
                <div className="my-options__column">
                    <LookCard />
                    {groups.map(g => (
                        <OptionGroup
                            key={g.group}
                            group={g.group}
                            defs={g.defs}
                            valueOf={valueOf}
                            onChange={change}
                            onReset={defs => void reset(defs)}
                            marks={marks}
                        />
                    ))}
                    <KeysCard />
                </div>
            )}
        </Screen>
    );
}
