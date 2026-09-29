import { useState, type CSSProperties } from 'react';
import { cx } from '../cx';
import { clientAction } from '../nui';
import type { Logo } from '../types';

// Logos that failed to load, reported once each to the client (CP.Tablet warns in the console).
const failed = new Set<string>();

function reportFailure(url: string, department?: string | null) {
    if (failed.has(url)) return;
    failed.add(url);
    void clientAction('logoFailed', { department: department ?? null, url });
}

// Load/error state of one logo URL. A URL that failed once stays hidden for the whole session.
function useLogo(url: string | undefined, department?: string | null) {
    const [, rerender] = useState(0);
    const [loadedUrl, setLoadedUrl] = useState<string | null>(null);
    return {
        ok: !!url && !failed.has(url),
        loaded: !!url && loadedUrl === url,
        onLoad: () => setLoadedUrl(url ?? null),
        onError: () => {
            if (url) reportFailure(url, department);
            rerender(n => n + 1);
        },
    };
}

export interface WatermarkProps {
    logo: Logo | null | undefined;
    // Department key sent with logoFailed.
    department?: string | null;
    // Height of the tablet in px (default 800, the design height).
    tabletHeight?: number;
    className?: string;
}

// The department logo drawn once, centred behind the screen content. Put it as the first child of
// a positioned container whose scrolling content sits above it (z-index 1): it stays fixed while
// content scrolls, never takes clicks, and hides itself (no broken-image icon) when the image fails.
export function Watermark({ logo, department, tabletHeight = 800, className }: WatermarkProps) {
    const url = logo?.url;
    const { ok, loaded, onLoad, onError } = useLogo(url, department);
    if (!logo || !url || logo.watermark === false || !ok) return null;

    // SPEC defaults: opacity 0.08 (clamped 0–0.25), size 0.6 of the tablet height (clamped 0.05–1).
    const opacity = Math.max(
        0,
        Math.min(0.25, typeof logo.opacity === 'number' && isFinite(logo.opacity) ? logo.opacity : 0.08),
    );
    const size = Math.max(0.05, Math.min(1, typeof logo.size === 'number' && logo.size > 0 ? logo.size : 0.6));
    const style: CSSProperties = {
        height: Math.round(size * tabletHeight),
        opacity: loaded ? opacity : 0,
        filter: logo.grayscale ? 'grayscale(1)' : undefined,
    };
    return (
        <div className={cx('cp-watermark', className)} aria-hidden>
            <img src={url} alt="" draggable={false} style={style} onLoad={onLoad} onError={onError} />
        </div>
    );
}

// Small header logo; renders nothing while missing or when the image fails to load.
export function DeptLogo({
    logo,
    department,
    size = 30,
    alt = '',
    className,
}: {
    logo: Logo | null | undefined;
    department?: string | null;
    size?: number;
    alt?: string;
    className?: string;
}) {
    const url = logo?.url;
    const { ok, loaded, onLoad, onError } = useLogo(url, department);
    if (!url || !ok) return null;
    return (
        <img
            className={cx('cp-dept-logo', className)}
            src={url}
            alt={alt}
            width={size}
            height={size}
            draggable={false}
            style={{ visibility: loaded ? 'visible' : 'hidden' }}
            onLoad={onLoad}
            onError={onError}
        />
    );
}
