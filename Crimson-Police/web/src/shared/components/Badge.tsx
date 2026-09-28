import type { ReactNode } from 'react';
import { cx } from '../cx';
import { t, tOr } from '../i18n';
import { Icon, type IconName } from './Icon';

export type BadgeTone =
  | 'neutral' | 'primary' | 'accent' | 'success' | 'warning' | 'danger'
  // XP level badge colours (Config.XPLevels badge)
  | 'grey' | 'bronze' | 'silver' | 'gold' | 'platinum';

export interface BadgeProps {
  tone?: BadgeTone;
  /** soft = tinted (default), solid = filled, outline = border only. */
  variant?: 'soft' | 'solid' | 'outline';
  size?: 'sm' | 'md';
  icon?: IconName;
  /** Leading status dot. */
  dot?: boolean;
  title?: string;
  className?: string;
  children?: ReactNode;
}

export function Badge({ tone = 'neutral', variant = 'soft', size = 'md', icon, dot, title, className, children }: BadgeProps) {
  return (
    <span className={cx('cp-badge', `cp-badge--${tone}`, `cp-badge--${variant}`, `cp-badge--${size}`, className)} title={title}>
      {dot ? <span className="cp-badge__dot" aria-hidden /> : null}
      {icon ? <Icon name={icon} size={size === 'sm' ? 11 : 13} strokeWidth={2.2} /> : null}
      {children}
    </span>
  );
}

export const TIER_ORDER = ['standard', 'reinforced', 'heavy', 'major', 'critical'] as const;

/** Tier label with a 5-step intensity meter. `expected` marks a tier not locked in yet. */
export function TierBadge({ tier, label, expected, size = 'md', className }: { tier: string; label?: string; expected?: boolean; size?: 'sm' | 'md'; className?: string }) {
  const idx = Math.max(0, TIER_ORDER.indexOf(tier as (typeof TIER_ORDER)[number]));
  const text = label ?? tOr(`tier.${tier}`, 'common.unknown');
  return (
    <span
      className={cx('cp-tier', `cp-tier--${TIER_ORDER[idx]}`, `cp-tier--${size}`, expected && 'cp-tier--expected', className)}
      title={expected ? t('common.tier_expected', { tier: text }) : text}
    >
      <span className="cp-tier__pips" aria-hidden>
        {TIER_ORDER.map((name, i) => (
          <span key={name} className={cx('cp-tier__pip', i <= idx && 'is-on')} />
        ))}
      </span>
      <span className="cp-tier__label">{text}</span>
      {expected ? <span className="cp-tier__expected">{t('common.expected')}</span> : null}
    </span>
  );
}

const XP_TONES = ['grey', 'bronze', 'silver', 'gold', 'platinum'];

/** XP level badge (Config.XPLevels): medal in the badge colour plus the level label. */
export function XpBadge({ badge, label, size = 'md', className }: { badge: string; label: string; size?: 'sm' | 'md'; className?: string }) {
  const tone = (XP_TONES.includes(badge) ? badge : 'grey') as BadgeTone;
  return (
    <Badge tone={tone} size={size} icon="medal" className={cx('cp-xp-badge', className)}>
      {label}
    </Badge>
  );
}
