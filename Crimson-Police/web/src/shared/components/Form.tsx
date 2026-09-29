import {
    createContext,
    forwardRef,
    useContext,
    useEffect,
    useId,
    useRef,
    useState,
    type InputHTMLAttributes,
    type ReactNode,
    type SelectHTMLAttributes,
    type TextareaHTMLAttributes,
} from 'react';
import { cx } from '../cx';
import { t } from '../i18n';
import { Icon } from './Icon';

// ============================================================================
//                                    FIELD
// ============================================================================

interface FieldCtx {
    id: string;
    hintId: string;
    invalid: boolean;
}
const FieldContext = createContext<FieldCtx | null>(null);

export interface FieldProps {
    label?: ReactNode;
    // Help text under the control.
    hint?: ReactNode;
    // Error text (replaces the hint, marks the control invalid).
    error?: ReactNode;
    required?: boolean;
    // Label left, control right.
    inline?: boolean;
    className?: string;
    children: ReactNode;
}

// Label + control + hint/error. Controls inside pick up the id and aria wiring automatically.
export function Field({ label, hint, error, required, inline, className, children }: FieldProps) {
    const id = useId();
    const ctx: FieldCtx = { id: `${id}-control`, hintId: `${id}-hint`, invalid: !!error };
    return (
        <FieldContext.Provider value={ctx}>
            <div className={cx('cp-field', inline && 'cp-field--inline', error && 'is-invalid', className)}>
                {label ? (
                    <label className="cp-field__label" htmlFor={ctx.id}>
                        {label}
                        {required ? (
                            <span className="cp-field__req" aria-hidden>
                                {' '}
                                *
                            </span>
                        ) : null}
                    </label>
                ) : null}
                <div className="cp-field__control">{children}</div>
                {error ? (
                    <div className="cp-field__error" id={ctx.hintId} role="alert">
                        {error}
                    </div>
                ) : hint ? (
                    <div className="cp-field__hint" id={ctx.hintId}>
                        {hint}
                    </div>
                ) : null}
            </div>
        </FieldContext.Provider>
    );
}

function useFieldIds(id?: string, invalid?: boolean) {
    const ctx = useContext(FieldContext);
    return {
        id: id ?? ctx?.id,
        describedBy: ctx ? ctx.hintId : undefined,
        invalid: !!(invalid || ctx?.invalid),
    };
}

// ============================================================================
//                                  TextInput
// ============================================================================

export interface TextInputProps extends Omit<InputHTMLAttributes<HTMLInputElement>, 'onChange' | 'value' | 'prefix'> {
    value: string;
    onChange: (value: string) => void;
    // Text or icon shown inside the box, before the value.
    prefix?: ReactNode;
    suffix?: ReactNode;
    invalid?: boolean;
    // Called on Enter (once while the key is held).
    onEnter?: () => void;
}

export const TextInput = forwardRef<HTMLInputElement, TextInputProps>(function TextInput(
    { value, onChange, prefix, suffix, invalid, onEnter, className, id, onKeyDown, type = 'text', ...rest },
    ref,
) {
    const f = useFieldIds(id, invalid);
    return (
        <div className={cx('cp-input', f.invalid && 'is-invalid', rest.disabled && 'is-disabled', className)}>
            {prefix ? <span className="cp-input__affix">{prefix}</span> : null}
            <input
                ref={ref}
                id={f.id}
                type={type}
                value={value}
                aria-invalid={f.invalid || undefined}
                aria-describedby={f.describedBy}
                onChange={e => onChange(e.target.value)}
                onKeyDown={e => {
                    if (e.key === 'Enter' && !e.repeat && onEnter) onEnter();
                    onKeyDown?.(e);
                }}
                {...rest}
            />
            {suffix ? <span className="cp-input__affix">{suffix}</span> : null}
        </div>
    );
});

// Text input with a search icon.
export function SearchInput(props: Omit<TextInputProps, 'prefix'>) {
    return <TextInput prefix={<Icon name="search" size={15} />} placeholder={t('common.search')} {...props} />;
}

// ============================================================================
//                                 NumberInput
// ============================================================================

export interface NumberInputProps {
    value: number | null;
    // Only called with valid, in-range values (or null when cleared).
    onChange: (value: number | null) => void;
    min?: number;
    max?: number;
    step?: number;
    // Whole numbers only (default true).
    integer?: boolean;
    prefix?: ReactNode;
    suffix?: ReactNode;
    // Show the "Between min and max" hint (default: whenever min or max is set).
    showRange?: boolean;
    // Formats min/max in the hint (e.g. formatMoney).
    formatRange?: (n: number) => string;
    // Up/down stepper buttons (default true).
    stepper?: boolean;
    onValidityChange?: (valid: boolean) => void;
    disabled?: boolean;
    placeholder?: string;
    id?: string;
    className?: string;
    'aria-label'?: string;
}

// Numeric input that refuses out-of-range values: while the typed number is outside [min, max]
// (or not a number) onChange is not called, the box turns red and the hint explains the range.
// On blur an invalid entry reverts to the last valid value.
export function NumberInput({
    value,
    onChange,
    min,
    max,
    step = 1,
    integer = true,
    prefix,
    suffix,
    showRange,
    formatRange,
    stepper = true,
    onValidityChange,
    disabled,
    placeholder,
    id,
    className,
    ...aria
}: NumberInputProps) {
    const f = useFieldIds(id);
    const [draft, setDraft] = useState<string>(value === null || value === undefined ? '' : String(value));
    const [invalid, setInvalid] = useState(false);
    const focused = useRef(false);
    const fmt = formatRange ?? ((n: number) => n.toLocaleString('en-US'));

    useEffect(() => {
        if (focused.current && invalid) return;
        setDraft(value === null || value === undefined ? '' : String(value));
    }, [value]);

    const inRange = (n: number) => (min === undefined || n >= min) && (max === undefined || n <= max);
    const setValidity = (ok: boolean) => {
        if (ok === !invalid) return;
        setInvalid(!ok);
        onValidityChange?.(ok);
    };

    const commit = (raw: string) => {
        setDraft(raw);
        const trimmed = raw.trim();
        if (trimmed === '') {
            setValidity(true);
            onChange(null);
            return;
        }
        const n = Number(trimmed.replace(/,/g, ''));
        const ok = isFinite(n) && (!integer || Number.isInteger(n)) && inRange(n);
        setValidity(ok);
        if (ok) onChange(n);
    };

    const bump = (dir: 1 | -1) => {
        const base = value ?? (min !== undefined ? min : 0);
        let next = base + dir * step;
        if (min !== undefined) next = Math.max(min, next);
        if (max !== undefined) next = Math.min(max, next);
        if (integer) next = Math.round(next);
        setDraft(String(next));
        setValidity(true);
        onChange(next);
    };

    const hasRange = min !== undefined || max !== undefined;
    const rangeText =
        min !== undefined && max !== undefined
            ? t('common.range', { min: fmt(min), max: fmt(max) })
            : min !== undefined
              ? t('common.min', { min: fmt(min) })
              : max !== undefined
                ? t('common.max', { max: fmt(max) })
                : '';
    const showHint = (showRange ?? hasRange) && hasRange;

    return (
        <div className={cx('cp-number', className)}>
            <div className={cx('cp-input', 'cp-input--number', invalid && 'is-invalid', disabled && 'is-disabled')}>
                {prefix ? <span className="cp-input__affix">{prefix}</span> : null}
                <input
                    id={f.id}
                    inputMode={integer ? 'numeric' : 'decimal'}
                    value={draft}
                    disabled={disabled}
                    placeholder={placeholder}
                    aria-label={aria['aria-label']}
                    aria-invalid={invalid || undefined}
                    aria-describedby={f.describedBy}
                    aria-valuemin={min}
                    aria-valuemax={max}
                    onFocus={() => {
                        focused.current = true;
                    }}
                    onBlur={() => {
                        focused.current = false;
                        if (invalid) {
                            setDraft(value === null || value === undefined ? '' : String(value));
                            setValidity(true);
                        }
                    }}
                    onChange={e => commit(e.target.value.replace(/[^0-9.,-]/g, ''))}
                    onKeyDown={e => {
                        if (e.key === 'ArrowUp') {
                            e.preventDefault();
                            bump(1);
                        } else if (e.key === 'ArrowDown') {
                            e.preventDefault();
                            bump(-1);
                        }
                    }}
                />
                {suffix ? <span className="cp-input__affix">{suffix}</span> : null}
                {stepper ? (
                    <span className="cp-input__stepper">
                        <button
                            type="button"
                            tabIndex={-1}
                            aria-label={t('common.increase')}
                            disabled={disabled || (max !== undefined && (value ?? -Infinity) >= max)}
                            onClick={() => bump(1)}
                        >
                            <Icon name="chevronUp" size={12} strokeWidth={2.4} />
                        </button>
                        <button
                            type="button"
                            tabIndex={-1}
                            aria-label={t('common.decrease')}
                            disabled={disabled || (min !== undefined && (value ?? Infinity) <= min)}
                            onClick={() => bump(-1)}
                        >
                            <Icon name="chevronDown" size={12} strokeWidth={2.4} />
                        </button>
                    </span>
                ) : null}
            </div>
            {showHint ? (
                <div className={cx('cp-number__range', invalid && 'is-invalid')}>
                    {invalid
                        ? t('common.out_of_range', {
                              min: min !== undefined ? fmt(min) : '',
                              max: max !== undefined ? fmt(max) : '',
                          })
                        : rangeText}
                </div>
            ) : null}
        </div>
    );
}

// ============================================================================
//                                    SELECT
// ============================================================================

export interface SelectOption {
    value: string;
    label: string;
    disabled?: boolean;
}

export interface SelectProps extends Omit<SelectHTMLAttributes<HTMLSelectElement>, 'onChange' | 'value'> {
    value: string;
    onChange: (value: string) => void;
    options: SelectOption[];
    // First, empty option.
    placeholder?: string;
    invalid?: boolean;
}

export function Select({ value, onChange, options, placeholder, invalid, className, id, ...rest }: SelectProps) {
    const f = useFieldIds(id, invalid);
    return (
        <div
            className={cx(
                'cp-input',
                'cp-select',
                f.invalid && 'is-invalid',
                rest.disabled && 'is-disabled',
                className,
            )}
        >
            <select
                id={f.id}
                value={value}
                aria-invalid={f.invalid || undefined}
                aria-describedby={f.describedBy}
                onChange={e => onChange(e.target.value)}
                {...rest}
            >
                {placeholder !== undefined ? <option value="">{placeholder}</option> : null}
                {options.map(o => (
                    <option key={o.value} value={o.value} disabled={o.disabled}>
                        {o.label}
                    </option>
                ))}
            </select>
            <span className="cp-select__arrow" aria-hidden>
                <Icon name="chevronDown" size={14} />
            </span>
        </div>
    );
}

// ============================================================================
//                                   TEXTAREA
// ============================================================================

export interface TextareaProps extends Omit<TextareaHTMLAttributes<HTMLTextAreaElement>, 'onChange' | 'value'> {
    value: string;
    onChange: (value: string) => void;
    invalid?: boolean;
    // Show "n / maxLength" (default true when maxLength is set).
    showCount?: boolean;
}

export function Textarea({
    value,
    onChange,
    invalid,
    showCount,
    maxLength,
    className,
    id,
    rows = 3,
    ...rest
}: TextareaProps) {
    const f = useFieldIds(id, invalid);
    const count = showCount ?? maxLength !== undefined;
    return (
        <div className={cx('cp-textarea', className)}>
            <textarea
                id={f.id}
                className={cx('cp-input', 'cp-textarea__box', f.invalid && 'is-invalid')}
                value={value}
                rows={rows}
                maxLength={maxLength}
                aria-invalid={f.invalid || undefined}
                aria-describedby={f.describedBy}
                onChange={e => onChange(e.target.value)}
                {...rest}
            />
            {count && maxLength ? (
                <div className="cp-textarea__count cp-num">{`${value.length} / ${maxLength}`}</div>
            ) : null}
        </div>
    );
}

// ============================================================================
//                              TOGGLE / CHECKBOX
// ============================================================================

export interface ToggleProps {
    checked: boolean;
    onChange: (checked: boolean) => void;
    label?: ReactNode;
    description?: ReactNode;
    disabled?: boolean;
    id?: string;
    className?: string;
}

// Switch (role="switch").
export function Toggle({ checked, onChange, label, description, disabled, id, className }: ToggleProps) {
    const f = useFieldIds(id);
    return (
        <label className={cx('cp-toggle', checked && 'is-on', disabled && 'is-disabled', className)}>
            <button
                id={f.id}
                type="button"
                role="switch"
                aria-checked={checked}
                disabled={disabled}
                className="cp-toggle__track"
                onClick={() => onChange(!checked)}
            >
                <span className="cp-toggle__thumb" />
            </button>
            {label || description ? (
                <span className="cp-toggle__text">
                    {label ? <span className="cp-toggle__label">{label}</span> : null}
                    {description ? <span className="cp-toggle__desc">{description}</span> : null}
                </span>
            ) : null}
        </label>
    );
}

export interface CheckboxProps {
    checked: boolean;
    onChange: (checked: boolean) => void;
    label?: ReactNode;
    disabled?: boolean;
    indeterminate?: boolean;
    id?: string;
    className?: string;
}

export function Checkbox({ checked, onChange, label, disabled, indeterminate, id, className }: CheckboxProps) {
    const f = useFieldIds(id);
    const ref = useRef<HTMLInputElement>(null);
    useEffect(() => {
        if (ref.current) ref.current.indeterminate = !!indeterminate;
    }, [indeterminate]);
    return (
        <label
            className={cx(
                'cp-checkbox',
                checked && 'is-on',
                indeterminate && 'is-mixed',
                disabled && 'is-disabled',
                className,
            )}
        >
            <input
                ref={ref}
                id={f.id}
                type="checkbox"
                checked={checked}
                disabled={disabled}
                onChange={e => onChange(e.target.checked)}
            />
            <span className="cp-checkbox__box" aria-hidden>
                <Icon name={indeterminate ? 'minus' : 'check'} size={12} strokeWidth={3} />
            </span>
            {label ? <span className="cp-checkbox__label">{label}</span> : null}
        </label>
    );
}
