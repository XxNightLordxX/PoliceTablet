import type { HTMLAttributes, KeyboardEvent, ReactNode } from 'react';
import { cx } from '../cx';
import { t } from '../i18n';
import { SCREEN_HEADS, type ScreenHeadKey } from '../screenHeads';
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
    // The page header from shared/screenHeads.ts: its title and its one line of help (each overridden by title or
    // help when given). Every screen of the four tablets passes it; undefined = no header (e.g. the open builder).
    head?: ScreenHeadKey;
    title?: ReactNode;
    subtitle?: ReactNode;
    // One line of help under the subtitle (muted, smaller); default: the head's help.
    help?: ReactNode;
    // Right side of the title row.
    actions?: ReactNode;
    children?: ReactNode;
    className?: string;
}

// The page header and body of every screen: title, subtitle, the one line of help and the actions, then the content
// with the screen's vertical rhythm (the --cp-space tokens of styles/base.css).
export function Screen({ head, title, subtitle, help, actions, children, className }: ScreenProps) {
    const def = head ? SCREEN_HEADS[head] : undefined;
    const shownTitle = title ?? (def ? t(def.title) : undefined);
    const shownHelp = help ?? (def ? t(def.help) : undefined);
    return (
        <div className={cx('cp-screen', className)} data-head={head} data-tour={head ? `screen-${head}` : undefined}>
            {shownTitle || actions ? (
                <header className="cp-screen__header">
                    <div className="cp-screen__titles">
                        {shownTitle ? <h2 className="cp-screen__title">{shownTitle}</h2> : null}
                        {subtitle ? <p className="cp-screen__subtitle">{subtitle}</p> : null}
                        {shownHelp ? <p className="cp-screen__help">{shownHelp}</p> : null}
                    </div>
                    {actions ? <div className="cp-screen__actions">{actions}</div> : null}
                </header>
            ) : null}
            <div className="cp-screen__body">{children}</div>
        </div>
    );
}
