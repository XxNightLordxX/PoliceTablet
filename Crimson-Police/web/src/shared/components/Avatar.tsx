// An officer's picture: a preset image, an approved link (the initials when it fails to load) or the initials, in a
// ring of their XP level badge colour.

import { useEffect, useState } from 'react';
import type { Avatar as AvatarData } from '../types';
import './Avatar.css';

const FRAMES = ['grey', 'bronze', 'silver', 'gold', 'platinum'];

// The preset images (Config.Profile.avatarPresets ids), bundled with the UI.
const PRESET_FILES = import.meta.glob('../../assets/avatars/*.svg', { eager: true, query: '?url', import: 'default' });
export const AVATAR_PRESETS: Record<string, string> = {};
for (const [path, url] of Object.entries(PRESET_FILES)) {
    const id = path.replace(/^.*\//, '').replace(/\.svg$/, '');
    AVATAR_PRESETS[id] = String(url);
}

export interface AvatarProps {
    avatar?: AvatarData | null;
    // used for the initials when there is no avatar data
    name?: string;
    size?: number;
    className?: string;
    // a label for screen readers (hidden when not set: the name is usually next to the picture)
    label?: string;
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

export function Avatar({ avatar, name, size = 36, className, label }: AvatarProps) {
    const frame = avatar && FRAMES.includes(avatar.frame) ? avatar.frame : 'grey';
    const initials = avatar?.initials || initialsOf(name);
    const src =
        avatar?.kind === 'preset' && avatar.value
            ? (AVATAR_PRESETS[avatar.value] ?? null)
            : avatar?.kind === 'url' && avatar.value
              ? avatar.value
              : null;
    const [failed, setFailed] = useState<string | null>(null);
    useEffect(() => setFailed(null), [src]);
    const showImage = !!src && failed !== src;
    return (
        <span
            className={['cp-avatar', showImage ? 'cp-avatar--image' : null, className].filter(Boolean).join(' ')}
            style={{
                width: size,
                height: size,
                fontSize: Math.round(size * 0.38),
                borderColor: `var(--cp-xp-${frame})`,
            }}
            role={label ? 'img' : undefined}
            aria-label={label}
            aria-hidden={label ? undefined : true}
        >
            {showImage ? (
                <img
                    className={avatar?.kind === 'preset' ? 'cp-avatar__preset' : 'cp-avatar__img'}
                    src={src as string}
                    alt=""
                    draggable={false}
                    referrerPolicy="no-referrer"
                    onError={() => setFailed(src)}
                />
            ) : (
                initials
            )}
        </span>
    );
}
