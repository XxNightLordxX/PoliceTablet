import type { HTMLAttributes, KeyboardEvent, ReactNode } from 'react';
import { cx } from '../cx';
import { Icon, type IconName } from './Icon';

export interface CardProps extends Omit<HTMLAttributes<HTMLDivElement>, 'title'> {
    title?: ReactNode;
    subtitle?: ReactNode;
    icon?: IconName;
    // Right side of the card header (buttons, badges).
    actions?: ReactNode;
    footer?: ReactNode;
    padding?: 'none' | 'sm' | 'md' | 'lg';
    // Coloured top edge.
    highlight?: 'primary' | 'accent' | 'success' | 'warning' | 'danger';
    // Hover/press styling; set automatically when onClick is given.
    interactive?: boolean;
    // Dimmed (e.g. a locked board card).
    muted?: boolean;
}

// Surface container with an optional header (title, subtitle, actions slot) and footer.
export function Card({
    title,
    subtitle,
    icon,
    actions,
    footer,
    padding = 'md',
    highlight,
    interactive,
    muted,
    className,
    children,
    onClick,
    ...rest
}: CardProps) {
    const clickable = interactive ?? !!onClick;
    const onKeyDown =
        clickable && onClick
            ? (e: KeyboardEvent<HTMLDivElement>) => {
                  if ((e.key === 'Enter' || e.key === ' ') && e.target === e.currentTarget) {
                      e.preventDefault();
                      e.currentTarget.click();
                  }
              }
            : undefined;
    return (
        <div
            className={cx(
                'cp-card',
                `cp-card--pad-${padding}`,
                highlight && `cp-card--hl-${highlight}`,
                clickable && 'cp-card--interactive',
                muted && 'cp-card--muted',
                className,
            )}
            onClick={onClick}
            onKeyDown={onKeyDown}
            role={clickable ? 'button' : undefined}
            tabIndex={clickable ? 0 : undefined}
            {...rest}
        >
            {title || actions || subtitle ? (
                <div className="cp-card__header">
                    <div className="cp-card__heading">
                        {icon ? (
                            <span className="cp-card__icon">
                                <Icon name={icon} size={16} />
                            </span>
                        ) : null}
                        <div className="cp-card__titles">
                            {title ? <div className="cp-card__title">{title}</div> : null}
                            {subtitle ? <div className="cp-card__subtitle">{subtitle}</div> : null}
                        </div>
                    </div>
                    {actions ? (
                        <div className="cp-card__actions" onClick={e => e.stopPropagation()}>
                            {actions}
                        </div>
                    ) : null}
                </div>
            ) : null}
            <div className="cp-card__body">{children}</div>
            {footer ? <div className="cp-card__footer">{footer}</div> : null}
        </div>
    );
}

export interface SectionProps {
    title?: ReactNode;
    description?: ReactNode;
    actions?: ReactNode;
    children?: ReactNode;
    className?: string;
}

// A titled group inside a screen (title row with actions, then content).
export function Section({ title, description, actions, children, className }: SectionProps) {
    return (
        <section className={cx('cp-section', className)}>
            {title || actions || description ? (
                <div className="cp-section__header">
                    <div>
                        {title ? <h3 className="cp-section__title">{title}</h3> : null}
                        {description ? <p className="cp-section__desc">{description}</p> : null}
                    </div>
                    {actions ? <div className="cp-section__actions">{actions}</div> : null}
                </div>
            ) : null}
            {children}
        </section>
    );
}

export interface ScreenProps {
    title?: ReactNode;
    subtitle?: ReactNode;
    // Right side of the title row.
    actions?: ReactNode;
    children?: ReactNode;
    className?: string;
}

// Standard screen wrapper: page title row, then content with the screen's vertical rhythm.
export function Screen({ title, subtitle, actions, children, className }: ScreenProps) {
    return (
        <div className={cx('cp-screen', className)}>
            {title || actions ? (
                <header className="cp-screen__header">
                    <div className="cp-screen__titles">
                        {title ? <h2 className="cp-screen__title">{title}</h2> : null}
                        {subtitle ? <p className="cp-screen__subtitle">{subtitle}</p> : null}
                    </div>
                    {actions ? <div className="cp-screen__actions">{actions}</div> : null}
                </header>
            ) : null}
            <div className="cp-screen__body">{children}</div>
        </div>
    );
}
