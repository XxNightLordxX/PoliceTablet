import { useRef, type KeyboardEvent, type ReactNode } from 'react';
import { cx } from '../cx';
import { Icon, type IconName } from './Icon';

export interface TabItem<K extends string = string> {
    key: K;
    label: ReactNode;
    icon?: IconName;
    // Small count/label after the text.
    badge?: ReactNode;
    disabled?: boolean;
}

interface TabsBaseProps<K extends string> {
    items: TabItem<K>[];
    value: K;
    onChange: (key: K) => void;
    className?: string;
    'aria-label'?: string;
}

function useRovingKeys<K extends string>(items: TabItem<K>[], value: K, onChange: (k: K) => void) {
    const refs = useRef<(HTMLButtonElement | null)[]>([]);
    const onKeyDown = (e: KeyboardEvent<HTMLDivElement>) => {
        if (e.key !== 'ArrowRight' && e.key !== 'ArrowLeft' && e.key !== 'Home' && e.key !== 'End') return;
        e.preventDefault();
        const enabled = items.map((it, i) => (it.disabled ? -1 : i)).filter(i => i >= 0);
        if (!enabled.length) return;
        const cur = enabled.indexOf(items.findIndex(it => it.key === value));
        let next = cur;
        if (e.key === 'ArrowRight') next = (cur + 1) % enabled.length;
        if (e.key === 'ArrowLeft') next = (cur - 1 + enabled.length) % enabled.length;
        if (e.key === 'Home') next = 0;
        if (e.key === 'End') next = enabled.length - 1;
        const idx = enabled[next];
        onChange(items[idx].key);
        refs.current[idx]?.focus();
    };
    return { refs, onKeyDown };
}

// Underlined tabs (primary indicator). Arrow keys move between tabs.
export function Tabs<K extends string>({ items, value, onChange, className, ...aria }: TabsBaseProps<K>) {
    const { refs, onKeyDown } = useRovingKeys(items, value, onChange);
    return (
        <div className={cx('cp-tabs', className)} role="tablist" aria-label={aria['aria-label']} onKeyDown={onKeyDown}>
            {items.map((it, i) => {
                const active = it.key === value;
                return (
                    <button
                        key={it.key}
                        ref={el => {
                            refs.current[i] = el;
                        }}
                        type="button"
                        role="tab"
                        aria-selected={active}
                        tabIndex={active ? 0 : -1}
                        disabled={it.disabled}
                        className={cx('cp-tab', active && 'is-active')}
                        onClick={() => onChange(it.key)}
                    >
                        {it.icon ? <Icon name={it.icon} size={15} /> : null}
                        <span>{it.label}</span>
                        {it.badge !== undefined && it.badge !== null ? (
                            <span className="cp-tab__badge cp-num">{it.badge}</span>
                        ) : null}
                    </button>
                );
            })}
        </div>
    );
}

// Pill segmented control for filters and small option sets.
export function SegmentedControl<K extends string>({
    items,
    value,
    onChange,
    className,
    size = 'md',
    ...aria
}: TabsBaseProps<K> & { size?: 'sm' | 'md' }) {
    const { refs, onKeyDown } = useRovingKeys(items, value, onChange);
    return (
        <div
            className={cx('cp-segmented', `cp-segmented--${size}`, className)}
            role="radiogroup"
            aria-label={aria['aria-label']}
            onKeyDown={onKeyDown}
        >
            {items.map((it, i) => {
                const active = it.key === value;
                return (
                    <button
                        key={it.key}
                        ref={el => {
                            refs.current[i] = el;
                        }}
                        type="button"
                        role="radio"
                        aria-checked={active}
                        tabIndex={active ? 0 : -1}
                        disabled={it.disabled}
                        className={cx('cp-segment', active && 'is-active')}
                        onClick={() => onChange(it.key)}
                    >
                        {it.icon ? <Icon name={it.icon} size={14} /> : null}
                        <span>{it.label}</span>
                        {it.badge !== undefined && it.badge !== null ? (
                            <span className="cp-segment__badge cp-num">{it.badge}</span>
                        ) : null}
                    </button>
                );
            })}
        </div>
    );
}
