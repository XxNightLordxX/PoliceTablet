import {
    createContext,
    forwardRef,
    useContext,
    useEffect,
    useId,
    useLayoutEffect,
    useRef,
    useState,
    type InputHTMLAttributes,
    type KeyboardEvent,
    type ReactNode,
    type TextareaHTMLAttributes,
} from 'react';
import { createPortal } from 'react-dom';
import { cx } from '../cx';
import { fmtPlain } from '../format';
import { t } from '../i18n';
import { useEscapeLayer } from '../hooks';
import { LayerRootContext } from './LayerRoot';
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
    const fmt = formatRange ?? fmtPlain;

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
// A button plus a listbox drawn in the tablet's layer root, not a native select element: CEF draws a native list as
// a separate popup outside the tablet's scale, so it would not match the tablet's size or look. Later screens use
// this Select for every dropdown.

export interface SelectOption {
    value: string;
    label: string;
    disabled?: boolean;
}

export interface SelectProps {
    value: string;
    onChange: (value: string) => void;
    options: SelectOption[];
    // First, empty option.
    placeholder?: string;
    invalid?: boolean;
    disabled?: boolean;
    id?: string;
    className?: string;
    title?: string;
    'aria-label'?: string;
    'aria-labelledby'?: string;
}

// Gap between the box and the list, and the list's tallest size (unscaled tablet pixels).
const LIST_GAP = 4;
const LIST_MAX_H = 280;
// Type-ahead: letters typed within this many milliseconds build one search.
const TYPE_AHEAD_MS = 600;

interface ListPos {
    left: number;
    top?: number;
    bottom?: number;
    width: number;
    maxHeight: number;
}

// Where the list goes inside `root` (or the window), below the box, or above it when there is more room there.
function listPosition(anchor: HTMLElement, root: HTMLElement | null): ListPos {
    const a = anchor.getBoundingClientRect();
    const r = root
        ? root.getBoundingClientRect()
        : { left: 0, top: 0, width: window.innerWidth, height: window.innerHeight };
    const scale = root && root.offsetWidth > 0 ? r.width / root.offsetWidth : 1;
    const height = r.height / scale;
    const left = (a.left - r.left) / scale;
    const top = (a.top - r.top) / scale;
    const boxH = a.height / scale;
    const below = height - (top + boxH) - LIST_GAP * 2;
    const above = top - LIST_GAP * 2;
    const pos: ListPos = { left, width: a.width / scale, maxHeight: LIST_MAX_H };
    if (below >= Math.min(LIST_MAX_H, 160) || below >= above) {
        pos.top = top + boxH + LIST_GAP;
        pos.maxHeight = Math.max(80, Math.min(LIST_MAX_H, below));
    } else {
        pos.bottom = height - top + LIST_GAP;
        pos.maxHeight = Math.max(80, Math.min(LIST_MAX_H, above));
    }
    return pos;
}

export function Select({
    value,
    onChange,
    options,
    placeholder,
    invalid,
    disabled,
    className,
    id,
    title,
    ...aria
}: SelectProps) {
    const f = useFieldIds(id, invalid);
    const root = useContext(LayerRootContext);
    const listId = useId();
    const box = useRef<HTMLDivElement>(null);
    const button = useRef<HTMLButtonElement>(null);
    const list = useRef<HTMLUListElement>(null);
    const typed = useRef({ text: '', at: 0 });
    const [open, setOpen] = useState(false);
    const [active, setActive] = useState(-1);
    const [pos, setPos] = useState<ListPos | null>(null);

    const items: SelectOption[] = placeholder !== undefined ? [{ value: '', label: placeholder }, ...options] : options;
    const selected = items.findIndex(o => o.value === value);
    const shown = selected >= 0 ? items[selected] : null;
    const isPlaceholder = !shown || (placeholder !== undefined && selected === 0);

    const enabled = (i: number) => i >= 0 && i < items.length && !items[i].disabled;
    const step = (from: number, dir: 1 | -1) => {
        for (let i = from + dir; i >= 0 && i < items.length; i += dir) if (enabled(i)) return i;
        return enabled(from) ? from : -1;
    };
    const first = () => step(-1, 1);
    const last = () => step(items.length, -1);

    const close = () => {
        setOpen(false);
        setPos(null);
    };
    const show = (at?: number) => {
        if (disabled) return;
        setActive(at ?? (enabled(selected) ? selected : first()));
        setOpen(true);
    };
    const choose = (i: number) => {
        if (!enabled(i)) return;
        close();
        button.current?.focus();
        if (items[i].value !== value) onChange(items[i].value);
    };

    useEscapeLayer(open, close);

    useLayoutEffect(() => {
        if (!open) return;
        const place = () => {
            if (box.current) setPos(listPosition(box.current, root));
        };
        place();
        window.addEventListener('resize', place);
        window.addEventListener('scroll', place, true);
        return () => {
            window.removeEventListener('resize', place);
            window.removeEventListener('scroll', place, true);
        };
    }, [open, root]);

    useEffect(() => {
        if (!open) return;
        const onDown = (e: MouseEvent) => {
            const target = e.target as Node;
            if (box.current?.contains(target) || list.current?.contains(target)) return;
            close();
        };
        window.addEventListener('mousedown', onDown);
        return () => window.removeEventListener('mousedown', onDown);
    }, [open]);

    useEffect(() => {
        if (!open || active < 0 || !list.current) return;
        const el = list.current.children[active] as HTMLElement | undefined;
        el?.scrollIntoView?.({ block: 'nearest' });
    }, [open, active, pos]);

    useEffect(() => {
        if (disabled && open) close();
    }, [disabled]);

    // Letters jump to the next option whose label starts with what was typed (closed: picks it straight away).
    const typeAhead = (ch: string) => {
        const now = Date.now();
        const t0 = typed.current;
        t0.text = now - t0.at < TYPE_AHEAD_MS ? t0.text + ch.toLowerCase() : ch.toLowerCase();
        t0.at = now;
        const from = open ? active : selected;
        const repeat = t0.text.length > 1 && t0.text.split('').every(c => c === t0.text[0]);
        const needle = repeat ? t0.text[0] : t0.text;
        const start = repeat || t0.text.length === 1 ? from + 1 : Math.max(from, 0);
        for (let n = 0; n < items.length; n++) {
            const i = (start + n) % items.length;
            if (enabled(i) && items[i].label.toLowerCase().startsWith(needle)) {
                if (open) setActive(i);
                else if (items[i].value !== value) onChange(items[i].value);
                return;
            }
        }
    };

    const onKeyDown = (e: KeyboardEvent<HTMLButtonElement>) => {
        if (disabled) return;
        const key = e.key;
        if (!open) {
            if (key === 'ArrowDown' || key === 'ArrowUp' || key === 'Enter' || key === ' ') {
                e.preventDefault();
                show();
            } else if (key === 'Home' || key === 'End') {
                e.preventDefault();
                show(key === 'Home' ? first() : last());
            } else if (key.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey) {
                e.preventDefault();
                typeAhead(key);
            }
            return;
        }
        if (key === 'ArrowDown' || key === 'ArrowUp') {
            e.preventDefault();
            setActive(i => step(i, key === 'ArrowDown' ? 1 : -1));
        } else if (key === 'Home' || key === 'End') {
            e.preventDefault();
            setActive(key === 'Home' ? first() : last());
        } else if (key === 'Enter' || (key === ' ' && Date.now() - typed.current.at >= TYPE_AHEAD_MS)) {
            e.preventDefault();
            choose(active);
        } else if (key === 'Tab') {
            close();
        } else if (key.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey) {
            e.preventDefault();
            typeAhead(key);
        }
    };

    const optionId = (i: number) => `${listId}-opt-${i}`;
    const popover =
        open && pos ? (
            <ul
                ref={list}
                id={listId}
                role="listbox"
                aria-label={aria['aria-label']}
                aria-labelledby={aria['aria-labelledby']}
                className={cx('cp-select__list', root ? 'cp-select__list--layer' : 'cp-select__list--fixed')}
                style={{
                    left: pos.left,
                    top: pos.top,
                    bottom: pos.bottom,
                    minWidth: pos.width,
                    maxHeight: pos.maxHeight,
                }}
                onMouseDown={e => e.preventDefault()}
            >
                {items.map((o, i) => (
                    <li
                        key={`${i}:${o.value}`}
                        id={optionId(i)}
                        role="option"
                        aria-selected={i === selected}
                        aria-disabled={o.disabled || undefined}
                        className={cx(
                            'cp-select__option',
                            i === active && 'is-active',
                            i === selected && 'is-selected',
                            o.disabled && 'is-disabled',
                            placeholder !== undefined && i === 0 && 'is-placeholder',
                        )}
                        onMouseEnter={() => {
                            if (!o.disabled) setActive(i);
                        }}
                        onClick={() => choose(i)}
                    >
                        <span className="cp-select__option-label">{o.label}</span>
                        {i === selected ? <Icon name="check" size={13} strokeWidth={2.6} /> : null}
                    </li>
                ))}
            </ul>
        ) : null;

    return (
        <div
            ref={box}
            className={cx(
                'cp-input',
                'cp-select',
                f.invalid && 'is-invalid',
                disabled && 'is-disabled',
                open && 'is-open',
                className,
            )}
        >
            <button
                ref={button}
                id={f.id}
                type="button"
                role="combobox"
                title={title}
                disabled={disabled}
                aria-label={aria['aria-label']}
                aria-labelledby={aria['aria-labelledby']}
                aria-haspopup="listbox"
                aria-expanded={open}
                aria-controls={open ? listId : undefined}
                aria-activedescendant={open && active >= 0 ? optionId(active) : undefined}
                aria-invalid={f.invalid || undefined}
                aria-describedby={f.describedBy}
                className={cx('cp-select__button', isPlaceholder && 'is-placeholder')}
                onClick={() => (open ? close() : show())}
                onKeyDown={onKeyDown}
            >
                <span className="cp-select__value">{shown ? shown.label : (placeholder ?? '')}</span>
            </button>
            <span className="cp-select__arrow" aria-hidden>
                <Icon name="chevronDown" size={14} />
            </span>
            {popover ? createPortal(popover, root ?? document.body) : null}
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
