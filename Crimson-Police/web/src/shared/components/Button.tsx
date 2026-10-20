import { forwardRef, type ButtonHTMLAttributes, type ReactNode } from 'react';
import { cx } from '../cx';
import { Icon, type IconName } from './Icon';
import { Spinner } from './Feedback';

export type ButtonVariant = 'primary' | 'secondary' | 'ghost' | 'danger';
export type ButtonSize = 'sm' | 'md';

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
    variant?: ButtonVariant;
    size?: ButtonSize;
    // Shows a spinner and blocks clicks.
    loading?: boolean;
    icon?: IconName;
    iconRight?: IconName;
    // Full width.
    block?: boolean;
    children?: ReactNode;
}

// Themed button. primary = --cp-primary fill, secondary = raised surface, ghost = text, danger = red.
export const Button = forwardRef<HTMLButtonElement, ButtonProps>(function Button(
    {
        variant = 'secondary',
        size = 'md',
        loading = false,
        icon,
        iconRight,
        block,
        className,
        children,
        disabled,
        type = 'button',
        onClick,
        ...rest
    },
    ref,
) {
    const iconSize = size === 'sm' ? 14 : 16;
    return (
        <button
            ref={ref}
            type={type}
            className={cx(
                'cp-btn',
                `cp-btn--${variant}`,
                `cp-btn--${size}`,
                block && 'cp-btn--block',
                loading && 'is-loading',
                className,
            )}
            disabled={disabled || loading}
            aria-busy={loading || undefined}
            onClick={loading ? undefined : onClick}
            {...rest}
        >
            {loading ? <Spinner size={iconSize} /> : icon ? <Icon name={icon} size={iconSize} /> : null}
            {children !== undefined && children !== null && children !== false ? (
                <span className="cp-btn__label">{children}</span>
            ) : null}
            {iconRight && !loading ? <Icon name={iconRight} size={iconSize} /> : null}
        </button>
    );
});

export interface IconButtonProps extends Omit<ButtonHTMLAttributes<HTMLButtonElement>, 'children'> {
    icon: IconName;
    // Required accessible name (also the tooltip).
    label: string;
    variant?: ButtonVariant;
    size?: ButtonSize;
    loading?: boolean;
}

// Square icon-only button; `label` becomes aria-label and title.
export const IconButton = forwardRef<HTMLButtonElement, IconButtonProps>(function IconButton(
    { icon, label, variant = 'ghost', size = 'md', loading, className, disabled, type = 'button', ...rest },
    ref,
) {
    return (
        <button
            ref={ref}
            type={type}
            className={cx('cp-btn', 'cp-icon-btn', `cp-btn--${variant}`, `cp-btn--${size}`, className)}
            aria-label={label}
            title={label}
            disabled={disabled || loading}
            {...rest}
        >
            {loading ? <Spinner size={size === 'sm' ? 14 : 16} /> : <Icon name={icon} size={size === 'sm' ? 15 : 18} />}
        </button>
    );
});
