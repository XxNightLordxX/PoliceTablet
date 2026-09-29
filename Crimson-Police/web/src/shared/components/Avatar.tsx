// An officer's picture: initials in the frame colour of their XP level badge (presets and links come later).

import type { Avatar as AvatarData } from '../types';
import './Avatar.css';

const FRAMES = ['grey', 'bronze', 'silver', 'gold', 'platinum'];

export interface AvatarProps {
    avatar?: AvatarData | null;
    // used for the initials when there is no avatar data
    name?: string;
    size?: number;
    className?: string;
}

function initialsOf(name: string | undefined): string {
    const words = String(name ?? '')
        .trim()
        .split(/\s+/)
        .filter(w => w !== '');
    const out = words
        .slice(0, 2)
        .map(w => w.charAt(0).toUpperCase())
        .join('');
    return out || '?';
}

export function Avatar({ avatar, name, size = 36, className }: AvatarProps) {
    const frame = avatar && FRAMES.includes(avatar.frame) ? avatar.frame : 'grey';
    const initials = avatar?.initials || initialsOf(name);
    return (
        <span
            className={className ? `cp-avatar ${className}` : 'cp-avatar'}
            style={{
                width: size,
                height: size,
                fontSize: Math.round(size * 0.38),
                borderColor: `var(--cp-xp-${frame})`,
            }}
            aria-hidden
        >
            {initials}
        </span>
    );
}
