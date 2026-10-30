// Supervisor UI · Mission controls (screen key 'sup_controls', title key 'ui.screen.sup_controls', step P5): the

import { useEffect, useState } from 'react';
import {
    Badge,
    Button,
    Card,
    Countdown,
    Dialog,
    EmptyState,
    ErrorState,
    Field,
    Icon,
    LoadingBlock,
    Screen,
    SegmentedControl,
    Textarea,
    Toggle,
} from '../../shared/components';
import { asArray } from '../../shared/data';
import { fmtDateTime, formatDuration } from '../../shared/format';
import { useRequest } from '../../shared/hooks';
import { hasKey, t } from '../../shared/i18n';
import { useSession } from '../../shared/session';
import type { MissionControlState, MissionControlValue, MissionControlsView } from '../../types/oversight';
import { controlName, useValueText } from '../../admin/components/MissionControlsCard';
import { ReasonChips } from '../../admin/components/ReasonChips';
import { useAdminAction } from '../../admin/components/kit';
import './MissionControls.css';

const REASON_MAX = 255;

// The groups in screen order. A control not listed falls into 'run' (scope run) or 'department'.
const GROUPS = ['delays', 'run', 'board', 'calls', 'officers', 'department'] as const;
type GroupKey = (typeof GROUPS)[number];
const CONTROL_GROUP: Record<string, GroupKey> = {
    cooldownScale: 'delays',
    abandonCooldown: 'delays',
    noRepeat: 'delays',
    hourlyCap: 'delays',
    dailyCap: 'delays',
    happyHour: 'delays',
};

export function groupOf(c: MissionControlState): GroupKey {
    return CONTROL_GROUP[c.key] ?? (c.scope === 'run' ? 'run' : 'department');
}

// Lua sends an empty table as [] or {}: a map either way.
function asMap(v: unknown): Record<string, number> {
    return v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, number>) : {};
}

const same = (a: MissionControlValue | undefined, b: MissionControlValue | undefined) =>
    JSON.stringify(a ?? null) === JSON.stringify(b ?? null);

// A value inside [min, max] on the control's step (whole numbers for an integer control).
function fit(c: MissionControlState, n: number): number {
    const lo = c.min ?? 0;
    const hi = c.max ?? Math.max(lo, n);
    const v = Math.min(hi, Math.max(lo, n));
    return c.integer ? Math.round(v) : Math.round(v * 100) / 100;
}

// ============================================================================
//                                EDITOR BY KIND
// ============================================================================

function Slider({
    c,
    label,
    value,
    disabled,
    onChange,
}: {
    c: MissionControlState;
    label: string;
    value: number;
    disabled: boolean;
    onChange: (n: number) => void;
}) {
    const text = useValueText();
    const lo = c.min ?? 0;
    const hi = c.max ?? Math.max(lo, value);
    return (
        <label className="sup-mc-slider">
            <span className="sup-mc-slider__label">{label}</span>
            <input
                type="range"
                aria-label={label}
                min={lo}
                max={hi}
                step={c.integer ? 1 : 0.05}
                value={value}
                disabled={disabled}
                onChange={e => onChange(fit(c, Number(e.target.value)))}
            />
            <span className="sup-mc-slider__value cp-num">{text(c.key, value)}</span>
        </label>
    );
}

function Editor({
    c,
    draft,
    disabled,
    onChange,
}: {
    c: MissionControlState;
    draft: MissionControlValue;
    disabled: boolean;
    onChange: (v: MissionControlValue) => void;
}) {
    const session = useSession();
    const text = useValueText();
    // a choice control (step P9: difficulty): the presets the admin offers
    if (c.kind === 'choice') {
        const offered = asArray<string>(c.offered);
        return (
            <SegmentedControl
                aria-label={controlName(c.key)}
                items={offered.map(n => ({ key: n, label: text(c.key, n), disabled }))}
                value={typeof draft === 'string' ? draft : ''}
                onChange={n => onChange(n)}
            />
        );
    }
    if (c.kind === 'bool') {
        return (
            <Toggle
                checked={draft === true}
                disabled={disabled}
                label={draft === true ? t('admin.perms.mc.value_on') : t('admin.perms.mc.value_off')}
                onChange={v => onChange(v)}
            />
        );
    }
    if (c.kind === 'map') {
        const map = asMap(draft);
        const typeLabel = (k: string) => asArray(session.config?.missionTypes).find(m => m.key === k)?.label ?? k;
        return (
            <div className="sup-mc-sliders">
                {Object.keys(asMap(c.configValue)).map(k => (
                    <Slider
                        key={k}
                        c={c}
                        label={typeLabel(k)}
                        value={fit(c, map[k] ?? asMap(c.configValue)[k] ?? 1)}
                        disabled={disabled}
                        onChange={n => onChange({ ...map, [k]: n })}
                    />
                ))}
            </div>
        );
    }
    const slider = (
        <Slider
            c={c}
            label={controlName(c.key)}
            value={fit(
                c,
                typeof draft === 'number' && !(c.canTurnOff === true && draft === 0)
                    ? draft
                    : Number(c.value) || c.min || 0,
            )}
            disabled={disabled || (c.canTurnOff === true && draft === 0)}
            onChange={n => onChange(n)}
        />
    );
    // readyCheck (step P8): 0 = no ready check, offered only while the admin allows it (canTurnOff)
    if (c.canTurnOff === true) {
        return (
            <div className="sup-mc-sliders">
                <Toggle
                    checked={draft !== 0}
                    disabled={disabled}
                    label={draft !== 0 ? t('admin.perms.mc.value_on') : t('admin.perms.mc.value_off')}
                    onChange={v => onChange(v ? fit(c, Number(c.configValue) || c.min || 0) : 0)}
                />
                {slider}
            </div>
        );
    }
    return slider;
}

// ============================================================================
//                                 ONE CONTROL
// ============================================================================

type Pending =
    { kind: 'set'; c: MissionControlState; value: MissionControlValue } | { kind: 'reset'; c: MissionControlState };

// Happy hour (step P6): minutes and the no-repeat box, Start; while it runs the countdown and End now.
function HappyHourRow({
    c,
    busy,
    onAsk,
    onWaitDone,
}: {
    c: MissionControlState;
    busy: boolean;
    onAsk: (p: Pending) => void;
    onWaitDone: () => void;
}) {
    const text = useValueText();
    const [minutes, setMinutes] = useState(() => fit(c, 15));
    const [noRepeat, setNoRepeat] = useState(false);
    const running = c.saved !== undefined && c.saved !== null && (c.timeLeft ?? 0) > 0;
    const perDay = c.perDay ?? 1;
    const usedUp = (c.usedToday ?? 0) >= perDay;
    const waiting = c.waitLeft > 0;
    return (
        <div className="sup-mc-row">
            <div className="sup-mc-row__head">
                <div>
                    <div className="sup-mc-row__title">
                        <strong>{controlName(c.key)}</strong>
                        <Badge size="sm" tone="neutral" variant="outline" icon="globe">
                            {t('sup.controls.whole_server')}
                        </Badge>
                    </div>
                    <p className="sup-mc-row__desc">{t('mc.control_desc.happyHour')}</p>
                </div>
            </div>
            <div className="sup-mc-row__facts">
                <span>{t('sup.hh.used', { used: c.usedToday ?? 0, perDay })}</span>
                {running ? (
                    <span className="sup-mc-row__who">
                        {t('sup.controls.changed_by', {
                            who: c.setBy ?? '?',
                            role: c.setRole ?? '?',
                            when: fmtDateTime(c.at),
                        })}
                    </span>
                ) : null}
            </div>
            {running ? (
                <div className="sup-mc-row__actions">
                    <span className="sup-mc-row__wait">
                        <Icon name="clock" size={13} />
                        <span>{`${t('sup.hh.running')} `}</span>
                        <Countdown seconds={c.timeLeft ?? 0} resetKey={c.at} onDone={onWaitDone} />
                        <span>{` · ${text(c.key, c.value)}`}</span>
                    </span>
                    <Button
                        size="sm"
                        variant="secondary"
                        icon="undo"
                        disabled={busy}
                        onClick={() => onAsk({ kind: 'reset', c })}
                    >
                        {t('sup.hh.end')}
                    </Button>
                </div>
            ) : (
                <>
                    <Slider
                        c={c}
                        label={t('sup.hh.minutes')}
                        value={minutes}
                        disabled={busy || usedUp}
                        onChange={setMinutes}
                    />
                    <Toggle
                        checked={noRepeat}
                        disabled={busy || usedUp}
                        label={t('sup.hh.norepeat')}
                        onChange={v => setNoRepeat(v)}
                    />
                    <div className="sup-mc-row__actions">
                        {usedUp ? <span className="sup-mc-row__wait">{t('sup.hh.used_up')}</span> : null}
                        {waiting ? (
                            <span className="sup-mc-row__wait">
                                <Icon name="clock" size={13} />
                                <span>{t('sup.controls.wait')}</span>
                                <Countdown seconds={c.waitLeft} onDone={onWaitDone} />
                            </span>
                        ) : null}
                        <Button
                            size="sm"
                            variant="primary"
                            icon="check"
                            disabled={busy || waiting || usedUp}
                            onClick={() => onAsk({ kind: 'set', c, value: { minutes, noRepeat: noRepeat ? 1 : 0 } })}
                        >
                            {t('sup.hh.start')}
                        </Button>
                    </div>
                </>
            )}
        </div>
    );
}

function ControlRow({
    c,
    dept,
    busy,
    onAsk,
    onWaitDone,
}: {
    c: MissionControlState;
    dept: string;
    busy: boolean;
    onAsk: (p: Pending) => void;
    onWaitDone: () => void;
}) {
    if (c.key === 'happyHour') return <HappyHourRow c={c} busy={busy} onAsk={onAsk} onWaitDone={onWaitDone} />;
    return <PlainRow c={c} dept={dept} busy={busy} onAsk={onAsk} onWaitDone={onWaitDone} />;
}

function PlainRow({
    c,
    dept,
    busy,
    onAsk,
    onWaitDone,
}: {
    c: MissionControlState;
    dept: string;
    busy: boolean;
    onAsk: (p: Pending) => void;
    onWaitDone: () => void;
}) {
    const text = useValueText();
    const [draft, setDraft] = useState<MissionControlValue>(c.value);
    const valueKey = JSON.stringify(c.value);
    useEffect(() => {
        setDraft(c.value);
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [valueKey]);
    const changed = c.saved !== undefined && c.saved !== null;
    const waiting = c.waitLeft > 0;
    const dirty = !same(draft, c.value);
    const desc = hasKey(`mc.control_desc.${c.key}`) ? t(`mc.control_desc.${c.key}`) : '';
    return (
        <div className="sup-mc-row">
            <div className="sup-mc-row__head">
                <div>
                    <div className="sup-mc-row__title">
                        <strong>{controlName(c.key)}</strong>
                        <Badge size="sm" tone="neutral" variant="outline" icon={c.serverWide ? 'globe' : 'building'}>
                            {c.serverWide ? t('sup.controls.whole_server') : dept}
                        </Badge>
                    </div>
                    {desc ? <p className="sup-mc-row__desc">{desc}</p> : null}
                </div>
            </div>
            <div className="sup-mc-row__facts">
                <span>{t('sup.controls.config', { value: text(c.key, c.configValue) })}</span>
                <span>
                    <strong>
                        {c.serverWide
                            ? t('sup.controls.now_server', { value: text(c.key, c.value) })
                            : t('sup.controls.now_dept', { dept, value: text(c.key, c.value) })}
                    </strong>
                </span>
                {changed ? (
                    <span className="sup-mc-row__who">
                        {t('sup.controls.changed_by', {
                            who: c.setBy ?? '?',
                            role: c.setRole ?? '?',
                            when: fmtDateTime(c.at),
                        })}
                        {c.timeLeft !== undefined && c.timeLeft !== null
                            ? ` · ${t('admin.perms.mc.ends', { left: formatDuration(c.timeLeft) })}`
                            : ''}
                    </span>
                ) : (
                    <span className="sup-mc-row__who">{t('sup.controls.uses_config')}</span>
                )}
            </div>
            <Editor c={c} draft={draft} disabled={busy || waiting} onChange={setDraft} />
            <div className="sup-mc-row__actions">
                {waiting ? (
                    <span className="sup-mc-row__wait">
                        <Icon name="clock" size={13} />
                        <span>{t('sup.controls.wait')}</span>
                        <Countdown seconds={c.waitLeft} onDone={onWaitDone} />
                    </span>
                ) : null}
                {dirty ? (
                    <Button size="sm" variant="ghost" disabled={busy} onClick={() => setDraft(c.value)}>
                        {t('common.cancel')}
                    </Button>
                ) : null}
                {changed ? (
                    <Button
                        size="sm"
                        variant="secondary"
                        icon="undo"
                        disabled={busy || waiting}
                        onClick={() => onAsk({ kind: 'reset', c })}
                    >
                        {t('sup.controls.back_to_config')}
                    </Button>
                ) : null}
                <Button
                    size="sm"
                    variant="primary"
                    icon="check"
                    disabled={busy || waiting || !dirty}
                    onClick={() => onAsk({ kind: 'set', c, value: draft })}
                >
                    {t('sup.controls.save')}
                </Button>
            </div>
        </div>
    );
}

// ============================================================================
//                                REASON DIALOG
// ============================================================================

function ReasonDialog({
    pending,
    busy,
    onClose,
    onConfirm,
}: {
    pending: Pending | null;
    busy: boolean;
    onClose: () => void;
    onConfirm: (reason: string) => void;
}) {
    const text = useValueText();
    const [reason, setReason] = useState('');
    useEffect(() => setReason(''), [pending]);
    if (!pending) return null;
    const c = pending.c;
    const next = pending.kind === 'set' ? pending.value : c.configValue;
    const ok = reason.trim().length > 0 && !busy;
    const hh = c.key === 'happyHour';
    const minutes = hh && pending.kind === 'set' ? (pending.value as Record<string, number>).minutes : 0;
    const title = hh
        ? pending.kind === 'set'
            ? t('sup.hh.confirm_start', { minutes })
            : t('sup.hh.confirm_end')
        : pending.kind === 'set'
          ? t('sup.controls.confirm_set', { control: controlName(c.key) })
          : t('sup.controls.confirm_reset', { control: controlName(c.key) });
    const description = hh
        ? t(pending.kind === 'set' ? 'sup.hh.confirm_text' : 'sup.hh.confirm_end_text')
        : t('sup.controls.confirm_text', { from: text(c.key, c.value), to: text(c.key, next) });
    const confirmLabel = hh
        ? t(pending.kind === 'set' ? 'sup.hh.start' : 'sup.hh.end')
        : t(pending.kind === 'set' ? 'sup.controls.save' : 'sup.controls.back_to_config');
    return (
        <Dialog
            open
            onClose={busy ? () => undefined : onClose}
            title={title}
            description={description}
            size="md"
            footer={
                <>
                    <Button variant="ghost" onClick={onClose} disabled={busy}>
                        {t('common.cancel')}
                    </Button>
                    <Button
                        variant="primary"
                        icon="check"
                        loading={busy}
                        disabled={!ok}
                        onClick={() => onConfirm(reason.trim())}
                    >
                        {confirmLabel}
                    </Button>
                </>
            }
        >
            {c.serverWide ? <p className="sup-mc-note">{t('sup.controls.server_wide_note')}</p> : null}
            <Field label={t('sup.controls.reason')} required>
                <Textarea value={reason} onChange={setReason} maxLength={REASON_MAX} rows={3} />
            </Field>
            <ReasonChips value={reason} onChange={setReason} disabled={busy} />
        </Dialog>
    );
}

// ============================================================================
//                                    SCREEN
// ============================================================================

export default function MissionControls() {
    const session = useSession();
    const { data, loading, error, refetch } = useRequest<MissionControlsView>(
        'sup:getMissionControls',
        {},
        { pushTopic: 'missionControls' },
    );
    const { run, busy } = useAdminAction();
    const [pending, setPending] = useState<Pending | null>(null);

    const dept = asArray(data?.departments)[0];
    const deptShort = dept?.short ?? session.officer?.departmentShort ?? '';
    // only the controls an admin switched on; an action control (step P7) is used from its own screen
    const controls = [...asArray(data?.serverWide), ...asArray(dept?.controls)].filter(
        c => c.active && c.kind !== 'action',
    );
    const groups = GROUPS.map(g => ({ key: g, rows: controls.filter(c => groupOf(c) === g) })).filter(
        g => g.rows.length > 0,
    );

    const confirm = async (reason: string) => {
        if (!pending) return;
        const res =
            pending.kind === 'set'
                ? await run(
                      'server:sup:setMissionControl',
                      { key: pending.c.key, value: pending.value, reason },
                      pending.c.key === 'happyHour'
                          ? { success: 'sup.hh.started' }
                          : { success: 'sup.controls.saved', successVars: { control: controlName(pending.c.key) } },
                  )
                : await run(
                      'server:sup:resetMissionControl',
                      { key: pending.c.key, reason },
                      pending.c.key === 'happyHour'
                          ? { success: 'sup.hh.ended' }
                          : {
                                success: 'sup.controls.reset_done',
                                successVars: { control: controlName(pending.c.key) },
                            },
                  );
        if (res.ok) setPending(null);
        void refetch();
    };

    return (
        <Screen
            title={t('ui.screen.sup_controls')}
            subtitle={t('sup.controls.subtitle')}
            className="sup-mc"
            actions={
                <Button size="sm" variant="ghost" icon="refresh" disabled={loading} onClick={() => void refetch()}>
                    {t('sup.controls.refresh')}
                </Button>
            }
        >
            {data?.selfExempt ? (
                <p className="sup-mc-note">
                    <Icon name="info" size={14} />
                    <span>{t('sup.controls.self_note')}</span>
                </p>
            ) : null}
            {!data && loading ? <LoadingBlock /> : null}
            {!data && !loading && error ? <ErrorState error={error} onRetry={() => void refetch()} /> : null}
            {data && groups.length === 0 ? (
                <Card>
                    <EmptyState icon="clock" title={t('sup.controls.empty')} text={t('sup.controls.empty_text')} />
                </Card>
            ) : null}
            {groups.map(g => (
                <Card key={g.key} title={t(`sup.controls.group.${g.key}`)}>
                    <div className="sup-mc-list">
                        {g.rows.map(c => (
                            <ControlRow
                                key={c.key}
                                c={c}
                                dept={deptShort}
                                busy={busy}
                                onAsk={setPending}
                                onWaitDone={() => void refetch()}
                            />
                        ))}
                    </div>
                </Card>
            ))}
            <ReasonDialog
                pending={pending}
                busy={busy}
                onClose={() => setPending(null)}
                onConfirm={reason => void confirm(reason)}
            />
        </Screen>
    );
}
