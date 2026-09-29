// Mission Builder in-world overlays: the placement tool, route recording and test drive HUDs.

import type { ReactNode } from 'react';
import { Icon, ProgressBar, type IconName } from '../shared/components';
import { cx } from '../shared/cx';
import { formatDistance } from '../shared/format';
import { useHudScale } from '../shared/hooks';
import { t } from '../shared/i18n';
import type { Overlay } from '../shared/types';
import type { PlacementOverlay, RecordingOverlay, TestDriveOverlay } from '../types/builder_client';
import './BuilderOverlay.css';

export interface BuilderOverlayProps {
    overlay: Overlay;
}

const num = (v: unknown, fb = 0): number => (typeof v === 'number' && isFinite(v) ? v : fb);
const list = (v: unknown): number[] => (Array.isArray(v) ? v.filter((n): n is number => typeof n === 'number') : []);
const text = (v: unknown): string | null => (typeof v === 'string' && v ? v : null);

function Key({ k, label, off }: { k: string; label: string; off?: boolean }) {
    return (
        <span className={cx('builder_client-ov__key', off && 'is-off')}>
            <kbd>{k}</kbd>
            <span>{label}</span>
        </span>
    );
}

function Head({
    icon,
    kind,
    label,
    aside,
    tone,
}: {
    icon: IconName;
    kind: string;
    label: string;
    aside?: ReactNode;
    tone?: string;
}) {
    return (
        <div className="builder_client-ov__head">
            <span className={cx('builder_client-ov__kind', tone)}>
                <Icon name={icon} size={13} />
                {kind}
            </span>
            <span className="builder_client-ov__label">{label}</span>
            {aside ? <span className="builder_client-ov__aside">{aside}</span> : null}
        </div>
    );
}

function Placement({ o }: { o: PlacementOverlay }) {
    const placed = num(o.placed);
    const min = num(o.min);
    const max = num(o.max, 1);
    const multiple = o.multiple !== false && max > 1;
    const area = o.mode === 'start' || o.mode === 'area';
    const enough = placed >= Math.max(1, min);
    const reason = text(o.reason);
    return (
        <>
            <Head
                icon="mapPin"
                kind={t('builder.ov.placement')}
                label={o.label || o.key}
                aside={
                    <span className={cx('builder_client-ov__count cp-num', enough ? 'is-ok' : 'is-short')}>
                        {multiple
                            ? t('builder.ov.placed_of', { n: placed, min: Math.max(1, min), max })
                            : placed
                              ? t('builder.ov.placed_one')
                              : t('builder.ov.not_placed')}
                    </span>
                }
            />
            <div className="builder_client-ov__row">
                <span className={cx('builder_client-ov__spot', o.valid ? 'is-ok' : 'is-bad')}>
                    <Icon name={o.valid ? 'checkCircle' : 'xCircle'} size={15} />
                    {o.valid ? t('builder.ov.spot_ok') : (reason ?? t('builder.ov.spot_bad'))}
                </span>
                <span className="cp-spacer" />
                {typeof o.heading === 'number' ? (
                    <span className="builder_client-ov__chip cp-num">
                        <Icon name="navigation" size={12} />
                        {t('builder.ov.heading', { deg: o.heading })}
                    </span>
                ) : null}
                {typeof o.radius === 'number' ? (
                    <span className="builder_client-ov__chip cp-num">
                        <Icon name="circle" size={12} />
                        {t('builder.ov.radius', { m: o.radius })}
                    </span>
                ) : null}
            </div>
            {multiple && max > 0 ? (
                <ProgressBar
                    value={Math.min(placed, max)}
                    max={Math.max(1, min || max)}
                    size="sm"
                    tone={enough ? 'success' : 'warning'}
                />
            ) : null}
            <div className="builder_client-ov__keys">
                <Key k="E" label={multiple ? t('builder.ov.key_place') : t('builder.ov.key_set')} />
                <Key
                    k={t('builder.ov.scroll')}
                    label={area ? t('builder.ov.key_radius') : t('builder.ov.key_rotate')}
                />
                <Key k="⌫" label={t('builder.ov.key_undo')} off={!placed} />
                <Key k="↵" label={t('builder.ov.key_done')} />
            </div>
        </>
    );
}

function Recording({ o }: { o: RecordingOverlay }) {
    const len = num(o.length);
    const minL = num(o.minLength, 800);
    const maxL = num(o.maxLength, 8000);
    const waiting = o.waiting;
    const zone = text(o.zone);
    const message = text(o.message);
    const lenTone = len > maxL ? 'danger' : len >= minL ? 'success' : 'primary';
    const toStart = typeof o.toStart === 'number' ? o.toStart : null;
    return (
        <>
            <Head
                icon="radio"
                kind={
                    o.paused
                        ? t('builder.ov.paused')
                        : waiting === 'checking'
                          ? t('builder.ov.checking_kind')
                          : t('builder.ov.rec')
                }
                tone={o.paused ? 'is-paused' : waiting === 'checking' ? 'is-check' : 'is-rec'}
                label={o.label || o.key}
                aside={<span className="builder_client-ov__big cp-num">{formatDistance(len)}</span>}
            />
            <div className="builder_client-ov__stats">
                <span>
                    <b className="cp-num">{num(o.points)}</b> {t('builder.ov.waypoints')}
                </span>
                <span>
                    <b className="cp-num">{num(o.samples)}</b> {t('builder.ov.samples')}
                </span>
                <span className={num(o.rejected) ? 'is-bad' : undefined}>
                    <b className="cp-num">{num(o.rejected)}</b> {t('builder.ov.rejected')}
                </span>
                {o.stopsEnabled ? (
                    <span>
                        <b className="cp-num">{num(o.stops)}</b>/{num(o.maxStops, 5)} {t('builder.ov.stops')}
                    </span>
                ) : null}
            </div>
            <div className="builder_client-ov__len">
                <ProgressBar value={Math.min(len, maxL)} max={maxL} size="sm" tone={lenTone} />
                <span className="builder_client-ov__len-text cp-num">
                    {t('builder.ov.length_range', { min: (minL / 1000).toFixed(1), max: (maxL / 1000).toFixed(1) })}
                </span>
            </div>
            {waiting === 'vehicle' ? (
                <div className="builder_client-ov__wait">
                    <Icon name="car" size={14} />
                    {t('builder.ov.wait_vehicle')}
                </div>
            ) : null}
            {waiting === 'return' ? (
                <div className="builder_client-ov__wait">
                    <Icon name="navigation" size={14} />
                    {t('builder.ov.wait_return', { m: num(o.distance) })}
                </div>
            ) : null}
            {waiting === 'checking' ? (
                <div className="builder_client-ov__wait">
                    <Icon name="refresh" size={14} className="builder_client-ov__spin" />
                    {t('builder.ov.wait_checking')}
                </div>
            ) : null}
            <div className="builder_client-ov__warns">
                {o.offRoad ? (
                    <span className="builder_client-ov__warn is-bad">
                        <Icon name="alert" size={13} />
                        {t('builder.ov.off_road')}
                    </span>
                ) : null}
                {zone ? (
                    <span className="builder_client-ov__warn is-bad">
                        <Icon name="xCircle" size={13} />
                        {t('builder.ov.zone', { zone })}
                    </span>
                ) : null}
                {o.tooLong ? (
                    <span className="builder_client-ov__warn is-bad">
                        <Icon name="alert" size={13} />
                        {t('builder.ov.too_long', { km: (maxL / 1000).toFixed(1) })}
                    </span>
                ) : null}
                {o.loop && toStart !== null ? (
                    <span className="builder_client-ov__warn">
                        <Icon name="refresh" size={13} />
                        {t('builder.ov.loop', { m: toStart })}
                    </span>
                ) : null}
                {message ? (
                    <span className="builder_client-ov__warn is-info">
                        <Icon name="info" size={13} />
                        {message}
                    </span>
                ) : null}
            </div>
            <div className="builder_client-ov__keys">
                {o.stopsEnabled ? <Key k="E" label={t('builder.ov.key_stop')} /> : null}
                <Key k="⌫" label={t('builder.ov.key_undo_m', { m: num(o.undoMetres, 100) })} />
                <Key k="P" label={o.paused ? t('builder.ov.key_resume') : t('builder.ov.key_pause')} />
                <Key k="X" label={t('builder.ov.key_finish')} />
            </div>
        </>
    );
}

function TestDrive({ o }: { o: TestDriveOverlay }) {
    const wp = num(o.waypoint, 1);
    const total = Math.max(1, num(o.total, 1));
    const failed = list(o.failed);
    const waiting = o.waiting;
    return (
        <>
            <Head
                icon="car"
                kind={t('builder.ov.testdrive')}
                label={o.label || o.key}
                tone="is-drive"
                aside={
                    <span className="builder_client-ov__big cp-num">
                        {o.done ? t('builder.ov.drive_done') : t('builder.ov.waypoint_of', { n: wp, total })}
                    </span>
                }
            />
            <ProgressBar
                value={o.done ? total : Math.max(0, wp - 1)}
                max={Math.max(1, total - 1)}
                size="sm"
                tone={failed.length ? 'warning' : 'success'}
            />
            <div className="builder_client-ov__row">
                {waiting === 'approach' ? (
                    <span className="builder_client-ov__wait">
                        <Icon name="navigation" size={14} />
                        {t('builder.ov.wait_approach', { m: num(o.distance) })}
                    </span>
                ) : null}
                {waiting === 'clear' ? (
                    <span className="builder_client-ov__wait">
                        <Icon name="alert" size={14} />
                        {t('builder.ov.wait_clear')}
                    </span>
                ) : null}
                {waiting === 'spawning' ? (
                    <span className="builder_client-ov__wait">
                        <Icon name="refresh" size={14} className="builder_client-ov__spin" />
                        {t('builder.ov.wait_spawning')}
                    </span>
                ) : null}
                {!waiting && !o.done && typeof o.timeLeft === 'number' ? (
                    <span className={cx('builder_client-ov__chip cp-num', o.timeLeft <= 5 && 'is-bad')}>
                        <Icon name="clock" size={12} />
                        {t('builder.ov.time_left', { s: o.timeLeft })}
                    </span>
                ) : null}
                {typeof o.stopLeft === 'number' ? (
                    <span className="builder_client-ov__chip cp-num">
                        <Icon name="pause" size={12} />
                        {t('builder.ov.stop_left', { s: o.stopLeft })}
                    </span>
                ) : null}
                {typeof o.speed === 'number' ? (
                    <span className="builder_client-ov__chip cp-num">
                        <Icon name="zap" size={12} />
                        {t('builder.ov.speed', { kmh: o.speed })}
                    </span>
                ) : null}
            </div>
            {failed.length ? (
                <div className="builder_client-ov__warns">
                    <span className="builder_client-ov__warn is-bad">
                        <Icon name="alert" size={13} />
                        {t('builder.ov.failed', { list: failed.join(', ') })}
                    </span>
                </div>
            ) : null}
            <div className="builder_client-ov__keys">
                <Key k="X" label={o.done ? t('builder.ov.key_close') : t('builder.ov.key_stop_drive')} />
            </div>
        </>
    );
}

export default function BuilderOverlay({ overlay }: BuilderOverlayProps) {
    const scale = useHudScale(0.8, 1.6);
    const kind = overlay?.kind;
    if (kind !== 'placement' && kind !== 'recording' && kind !== 'testdrive') return null;
    const o = overlay as unknown;
    return (
        <div className="builder_client-ov-layer" aria-live="polite">
            <div
                className={cx('builder_client-ov', `is-${kind}`)}
                style={{ transform: `translateX(-50%) scale(${scale})` }}
                role="status"
            >
                {kind === 'placement' ? <Placement o={o as PlacementOverlay} /> : null}
                {kind === 'recording' ? <Recording o={o as RecordingOverlay} /> : null}
                {kind === 'testdrive' ? <TestDrive o={o as TestDriveOverlay} /> : null}
            </div>
            {kind === 'placement' ? <div className="builder_client-ov__crosshair" aria-hidden /> : null}
        </div>
    );
}
