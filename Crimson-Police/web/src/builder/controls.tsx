// Form controls of the Mission Builder: a NumberInput that shows its min, max and default and refuses values outside
// them, minute inputs for second values, option pickers from the config lists, chip multi-pickers, the star picker and
// inline error notes.

import { useState, type ReactNode } from 'react';
import { Badge, Field, Icon, IconButton, NumberInput, SegmentedControl, Select } from '../shared/components';
import { cx } from '../shared/cx';
import { t, tOr } from '../shared/i18n';
import type { BuilderError } from '../types/builder_server';
import type { Rng } from './schema';

function fmt(n: number): string {
    return Number.isInteger(n) ? n.toLocaleString('en-US') : String(Math.round(n * 100) / 100);
}

export interface RangeNumberProps {
    label: ReactNode;
    value: number | null | undefined;
    onChange: (v: number) => void;
    range: Rng;
    // unit key suffix shown in the box and the hint (e.g. 's', 'm', 'km/h', '%', '×')
    unit?: string;
    integer?: boolean;
    step?: number;
    disabled?: boolean;
    error?: string;
    // extra hint text after the range
    note?: ReactNode;
    showDefault?: boolean;
    className?: string;
}

// Number field with "min–max · default" under it; out-of-range input is refused (never reaches onChange).
export function RangeNumber({
    label,
    value,
    onChange,
    range,
    unit,
    integer = true,
    step,
    disabled,
    error,
    note,
    showDefault = true,
    className,
}: RangeNumberProps) {
    const [invalid, setInvalid] = useState(false);
    const u = unit ? ` ${unit}` : '';
    const hint = (
        <span className="builder_client-range">
            <span className="cp-num">{t('builder.range', { min: fmt(range.min), max: fmt(range.max), unit: u })}</span>
            {showDefault ? (
                <span className="cp-num"> · {t('builder.default_value', { value: `${fmt(range.def)}${u}` })}</span>
            ) : null}
            {note ? <span> · {note}</span> : null}
        </span>
    );
    const isDefault = typeof value === 'number' && Math.abs(value - range.def) < 1e-9;
    return (
        <Field
            label={
                <span className="builder_client-label-row">
                    <span>{label}</span>
                    {!disabled && showDefault && typeof value === 'number' && !isDefault ? (
                        <button
                            type="button"
                            className="builder_client-reset"
                            onClick={() => onChange(range.def)}
                            title={t('builder.reset_default')}
                        >
                            <Icon name="refresh" size={11} />
                            {t('builder.reset')}
                        </button>
                    ) : null}
                </span>
            }
            error={invalid ? t('builder.out_of_range', { min: fmt(range.min), max: fmt(range.max), unit: u }) : error}
            hint={hint}
            className={className}
        >
            <NumberInput
                value={typeof value === 'number' && isFinite(value) ? value : null}
                onChange={v => {
                    if (v !== null) onChange(v);
                }}
                min={range.min}
                max={range.max}
                integer={integer}
                step={step ?? (integer ? 1 : 0.1)}
                suffix={unit}
                showRange={false}
                disabled={disabled}
                onValidityChange={ok => setInvalid(!ok)}
            />
        </Field>
    );
}

// A seconds value edited in minutes (time limit, start timeout, cooldown).
export function MinutesField({
    label,
    seconds,
    onChange,
    range,
    disabled,
    error,
}: {
    label: ReactNode;
    seconds: number;
    onChange: (s: number) => void;
    range: Rng;
    disabled?: boolean;
    error?: string;
}) {
    const toMin = (s: number) => Math.round((s / 60) * 10) / 10;
    const r: Rng = { min: toMin(range.min), max: toMin(range.max), def: toMin(range.def) };
    return (
        <RangeNumber
            label={label}
            value={toMin(seconds)}
            onChange={m => onChange(Math.round(m * 60))}
            range={r}
            unit={t('builder.unit.min')}
            integer={false}
            step={1}
            disabled={disabled}
            error={error}
        />
    );
}

// Pick one of the config options; labels from builder.opt.<value>.
export function OptionPick({
    label,
    value,
    options,
    onChange,
    disabled,
    error,
    hint,
    labelPrefix = 'builder.opt.',
}: {
    label: ReactNode;
    value: string;
    options: string[];
    onChange: (v: string) => void;
    disabled?: boolean;
    error?: string;
    hint?: ReactNode;
    labelPrefix?: string;
}) {
    const items = options.map(o => ({ key: o, label: tOr(`${labelPrefix}${o}`, 'builder.opt.unknown', { value: o }) }));
    return (
        <Field label={label} error={error} hint={hint}>
            {options.length <= 3 ? (
                <SegmentedControl
                    items={items.map(i => ({ ...i, disabled }))}
                    value={value}
                    onChange={v => !disabled && onChange(v)}
                    size="sm"
                />
            ) : (
                <Select
                    value={value}
                    onChange={onChange}
                    options={items.map(i => ({ value: i.key, label: i.label }))}
                    disabled={disabled}
                />
            )}
        </Field>
    );
}

// Model / weapon names as readable text: WEAPON_MICROSMG → Micro SMG via builder.name.<value>, else the raw name.
export function nameOf(value: string): string {
    return tOr(`builder.name.${value.toLowerCase()}`, 'builder.opt.unknown', { value });
}

// Chip multi-picker for lists from Config.Builder.allowed; at least `min` stay selected.
export function MultiPick({
    label,
    value,
    options,
    onChange,
    min = 1,
    disabled,
    error,
    hint,
}: {
    label: ReactNode;
    value: string[];
    options: string[];
    onChange: (v: string[]) => void;
    min?: number;
    disabled?: boolean;
    error?: string;
    hint?: ReactNode;
}) {
    const extra = value.filter(v => !options.includes(v));
    const all = [...options, ...extra];
    const toggle = (o: string) => {
        if (disabled) return;
        if (value.includes(o)) {
            if (value.length <= min) return;
            onChange(value.filter(v => v !== o));
        } else onChange([...value, o]);
    };
    return (
        <Field label={label} error={error} hint={hint ?? t('builder.pick_hint', { min })}>
            <div className="builder_client-chips" role="group">
                {all.map(o => {
                    const on = value.includes(o);
                    const notAllowed = extra.includes(o);
                    return (
                        <button
                            key={o}
                            type="button"
                            className={cx('builder_client-chip', on && 'is-on', notAllowed && 'is-bad')}
                            aria-pressed={on}
                            disabled={disabled}
                            onClick={() => toggle(o)}
                            title={notAllowed ? t('builder.not_allowed') : o}
                        >
                            {on ? <Icon name="check" size={12} strokeWidth={2.6} /> : null}
                            <span>{nameOf(o)}</span>
                        </button>
                    );
                })}
            </div>
        </Field>
    );
}

// Difficulty stars.
export function StarPicker({
    value,
    min,
    max,
    onChange,
    disabled,
}: {
    value: number;
    min: number;
    max: number;
    onChange: (n: number) => void;
    disabled?: boolean;
}) {
    return (
        <div className="builder_client-stars" role="radiogroup" aria-label={t('builder.details.difficulty')}>
            {Array.from({ length: max }, (_, i) => i + 1).map(n => (
                <button
                    key={n}
                    type="button"
                    role="radio"
                    aria-checked={value === n}
                    className={cx('builder_client-star', n <= value && 'is-on')}
                    disabled={disabled || n < min}
                    onClick={() => onChange(n)}
                    title={t('builder.details.stars', { n })}
                >
                    <Icon name="star" size={20} strokeWidth={2} />
                </button>
            ))}
            <span className="builder_client-stars__text">{t('builder.details.stars', { n: value })}</span>
        </div>
    );
}

// A list of guardrail messages (already translated by the server).
export function ErrorNotes({ errors, compact }: { errors: BuilderError[]; compact?: boolean }) {
    if (!errors.length) return null;
    return (
        <ul className={cx('builder_client-errors', compact && 'is-compact')} role="alert">
            {errors.map((e, i) => (
                <li key={`${e.path}-${i}`}>
                    <Icon name="alert" size={13} />
                    <span>{e.message}</span>
                </li>
            ))}
        </ul>
    );
}

// Small header of a settings group inside a panel.
export function GroupTitle({ children, aside }: { children: ReactNode; aside?: ReactNode }) {
    return (
        <div className="builder_client-group-title">
            <span>{children}</span>
            {aside ? <span className="builder_client-group-title__aside">{aside}</span> : null}
        </div>
    );
}

// "3 placed · min 11" count badge: success when enough, warning when short.
export function CountBadge({ have, need, max }: { have: number; need: number; max?: number }) {
    const ok = have >= need && (max === undefined || have <= max);
    return (
        <Badge size="sm" tone={ok ? 'success' : have === 0 ? 'danger' : 'warning'} icon={ok ? 'check' : 'alert'}>
            <span className="cp-num">{t('builder.count_of', { have, need })}</span>
        </Badge>
    );
}

export function RemoveButton({ onClick, label, disabled }: { onClick: () => void; label: string; disabled?: boolean }) {
    return <IconButton icon="trash" label={label} size="sm" variant="ghost" onClick={onClick} disabled={disabled} />;
}
