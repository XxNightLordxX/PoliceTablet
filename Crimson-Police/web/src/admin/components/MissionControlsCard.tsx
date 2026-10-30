// Admin UI · Permissions · Mission controls (step P4): one row per registered control (CP.DeptControls): the admin

import { useEffect, useRef, useState } from 'react';
import {
    Badge,
    Button,
    Card,
    Checkbox,
    ConfirmDialog,
    EmptyState,
    ErrorState,
    Icon,
    LoadingBlock,
    NumberInput,
    Toggle,
} from '../../shared/components';
import { asArray } from '../../shared/data';
import { fmtDateTime, formatDuration, formatFactor } from '../../shared/format';
import { useRequest } from '../../shared/hooks';
import { hasKey, t } from '../../shared/i18n';
import { useOptionalSession } from '../../shared/session';
import type {
    CallLaneValue,
    CrossDeptValue,
    MissionControlBounds,
    MissionControlState,
    MissionControlValue,
    MissionControlsDepartment,
    MissionControlsView,
    TeleportDepartment,
    TeleportGrant,
} from '../../types/oversight';
import { GradeGrantRow } from './GradeGrantRow';
import { useAdminAction } from './kit';

// Lua sends an empty table as [] or {}: a map either way.
function asMap<T>(v: unknown): Record<string, T> {
    return v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, T>) : {};
}

export const controlName = (key: string) => (hasKey(`mc.control.${key}`) ? t(`mc.control.${key}`) : key);
const controlDesc = (key: string) => (hasKey(`mc.control_desc.${key}`) ? t(`mc.control_desc.${key}`) : '');

export function useValueText(): (key: string, v: MissionControlValue | undefined) => string {
    const session = useOptionalSession();
    const typeLabel = (k: string) => asArray(session?.config?.missionTypes).find(m => m.key === k)?.label ?? k;
    return (key, v) => {
        // callLane (step P12): the gap and how many may be open; none = no lane
        if (key === 'callLane') {
            const lane = v && typeof v === 'object' && !Array.isArray(v) ? (v as CallLaneValue) : null;
            if (!lane || !Array.isArray(lane.spawnEvery)) return t('mc.value.callLane_none');
            return t('mc.value.callLane', { lo: lane.spawnEvery[0], hi: lane.spawnEvery[1], max: lane.maxOpen });
        }
        // crossDept (step P13): out, or joining with a cap on places (0 = no cap)
        if (key === 'crossDept') {
            const cd = v && typeof v === 'object' && !Array.isArray(v) ? (v as CrossDeptValue) : null;
            if (cd && cd.join === false) return t('mc.value.crossDept_out');
            if (cd && cd.places > 0) return t('mc.value.crossDept_places', { n: cd.places });
            return t('mc.value.crossDept_open');
        }
        if (v === undefined || v === null) return '-';
        if (typeof v === 'boolean') return v ? t('admin.perms.mc.value_on') : t('admin.perms.mc.value_off');
        // featuredType (step P10): the type's label
        if (typeof v === 'string' && key === 'featuredType') return typeLabel(v);
        // a choice control (step P9: difficulty): the preset's name
        if (typeof v === 'string') return hasKey(`mc.value.preset.${v}`) ? t(`mc.value.preset.${v}`) : v;
        // types (step P10): the types switched off and how many single missions
        if (key === 'types') {
            const sw = asMap<unknown>(v);
            const types = Object.keys(sw).filter(k => k !== 'missions' && sw[k] === false);
            const n = Object.keys(asMap<unknown>(sw.missions)).length;
            const parts: string[] = [];
            if (types.length > 0) parts.push(t('mc.value.types_off', { list: types.map(typeLabel).join(', ') }));
            if (n > 0) parts.push(t('mc.value.missions_off', { n }));
            return parts.length > 0 ? parts.join(' · ') : t('mc.value.types_all_on');
        }
        const one = (n: number) =>
            hasKey(`mc.unit.${key}`) ? t(`mc.unit.${key}`, { n: formatFactor(n) }) : formatFactor(n);
        // readyCheck (step P8): 0 = no ready check
        if (typeof v === 'number' && v === 0 && key === 'readyCheck') return t('admin.perms.mc.value_off');
        if (typeof v === 'number') return one(v);
        if (key === 'happyHour') {
            // { minutes, noRepeat } while one runs (step P6); {} = none
            const hh = asMap<number>(v);
            if (!hh.minutes) return t('admin.perms.mc.value_off');
            return t(hh.noRepeat ? 'mc.value.happyHour_norepeat' : 'mc.value.happyHour', { n: hh.minutes });
        }
        const parts = Object.entries(asMap<number>(v)).map(([k, n]) => `${typeLabel(k)} ${one(n)}`);
        return parts.length > 0 ? parts.join(', ') : '-';
    };
}

// ============================================================================
//                   WHAT APPLIES NOW (ONE DEPARTMENT OR ALL)
// ============================================================================

function StateLine({ s, busy, onReset }: { s: MissionControlState; busy: boolean; onReset: () => void }) {
    const text = useValueText();
    const changed = s.saved !== undefined && s.saved !== null;
    return (
        <div className="oversight-mc-state">
            <span>
                <strong>{t('admin.perms.mc.now', { value: text(s.key, s.value) })}</strong>
                {changed ? null : ` · ${t('admin.perms.mc.config_value')}`}
            </span>
            {changed ? (
                <span className="oversight-perm-desc">
                    {t('admin.perms.mc.config', { value: text(s.key, s.configValue) })}
                    {' · '}
                    {t('admin.perms.mc.set_by', {
                        who: s.setBy ?? '?',
                        role: s.setRole ?? '?',
                        when: fmtDateTime(s.at),
                    })}
                    {s.timeLeft !== undefined && s.timeLeft !== null
                        ? ` · ${t('admin.perms.mc.ends', { left: formatDuration(s.timeLeft) })}`
                        : ''}
                    {s.waitLeft > 0 ? ` · ${t('admin.perms.mc.wait', { left: formatDuration(s.waitLeft) })}` : ''}
                </span>
            ) : null}
            {changed ? (
                <Button size="sm" variant="ghost" icon="refresh" disabled={busy} onClick={onReset}>
                    {t('admin.perms.mc.reset')}
                </Button>
            ) : null}
        </div>
    );
}

// ============================================================================
//                            MIN AND MAX (ONE SET)
// ============================================================================

function BoundsFields({
    control,
    bounds,
    busy,
    switchLabel,
    onSave,
}: {
    control: MissionControlState;
    bounds: MissionControlBounds;
    busy: boolean;
    // a department's own limits: its own switch next to min / max
    switchLabel?: string;
    onSave: (next: MissionControlBounds) => void;
}) {
    const numeric = control.kind !== 'bool' && control.kind !== 'choice' && control.bounded !== false;
    // a choice control (step P9): the names supervisors may pick, a box for each
    const listField = control.kind === 'choice' ? control.list : undefined;
    const choiceNames = asArray<string>(control.choices);
    const savedList = (): string[] => {
        const v = listField ? bounds[listField] : undefined;
        return Array.isArray(v) ? v : [];
    };
    const key = JSON.stringify(bounds);
    const [on, setOn] = useState<boolean | undefined>(bounds.on);
    const [min, setMin] = useState<number | null>(bounds.min ?? null);
    const [max, setMax] = useState<number | null>(bounds.max ?? null);
    // more true / false bounds a control registers (step P8: readyCheck's canTurnOff)
    const flagNames = asArray<string>(control.flags);
    const [flags, setFlags] = useState<Record<string, boolean>>(() =>
        Object.fromEntries(flagNames.map(f => [f, bounds[f] === true])),
    );
    const [picked, setPicked] = useState<string[]>(savedList);
    useEffect(() => {
        setOn(bounds.on);
        setMin(bounds.min ?? null);
        setMax(bounds.max ?? null);
        setFlags(Object.fromEntries(flagNames.map(f => [f, bounds[f] === true])));
        setPicked(savedList());
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [key]);
    const next: MissionControlBounds = { ...bounds };
    if (switchLabel !== undefined) next.on = on;
    if (numeric) {
        next.min = min ?? undefined;
        next.max = max ?? undefined;
    }
    for (const f of flagNames) {
        if (flags[f] || bounds[f] !== undefined) next[f] = flags[f] === true;
    }
    if (listField && (picked.length > 0 || bounds[listField] !== undefined)) {
        next[listField] = choiceNames.filter(n => picked.includes(n));
    }
    for (const k of Object.keys(next) as (keyof MissionControlBounds)[]) if (next[k] === undefined) delete next[k];
    const dirty = JSON.stringify(next) !== JSON.stringify(Object.fromEntries(Object.entries(bounds)));
    const invalid = min !== null && max !== null && min > max;
    if (!numeric && switchLabel === undefined && flagNames.length === 0 && !listField) return null;
    const lo = control.range?.[0];
    const hi = control.range?.[1];
    return (
        <div className="oversight-mc-bounds">
            {switchLabel !== undefined ? (
                <Toggle checked={on === true} disabled={busy} label={switchLabel} onChange={v => setOn(v)} />
            ) : null}
            {numeric ? (
                <>
                    <label className="oversight-mc-field">
                        <span>{t('admin.perms.mc.min')}</span>
                        <NumberInput
                            aria-label={t('admin.perms.mc.min')}
                            value={min}
                            onChange={setMin}
                            min={lo}
                            max={hi}
                            integer={control.integer === true}
                            step={control.integer ? 1 : 0.05}
                            showRange={false}
                        />
                    </label>
                    <label className="oversight-mc-field">
                        <span>{t('admin.perms.mc.max')}</span>
                        <NumberInput
                            aria-label={t('admin.perms.mc.max')}
                            value={max}
                            onChange={setMax}
                            min={lo}
                            max={hi}
                            integer={control.integer === true}
                            step={control.integer ? 1 : 0.05}
                            showRange={false}
                        />
                    </label>
                </>
            ) : null}
            {listField ? (
                <div className="oversight-mc-field">
                    <span>{t('admin.perms.mc.presets')}</span>
                    {choiceNames.map(n => (
                        <Checkbox
                            key={n}
                            checked={picked.includes(n)}
                            disabled={busy}
                            label={hasKey(`mc.value.preset.${n}`) ? t(`mc.value.preset.${n}`) : n}
                            onChange={v => setPicked(prev => (v ? [...prev, n] : prev.filter(x => x !== n)))}
                        />
                    ))}
                </div>
            ) : null}
            {flagNames.map(f => (
                <Checkbox
                    key={f}
                    checked={flags[f] === true}
                    disabled={busy}
                    label={hasKey(`admin.perms.mc.flag.${f}`) ? t(`admin.perms.mc.flag.${f}`) : f}
                    onChange={v => setFlags(prev => ({ ...prev, [f]: v }))}
                />
            ))}
            <Button size="sm" icon="check" disabled={busy || !dirty || invalid} onClick={() => onSave(next)}>
                {t('admin.perms.mc.save')}
            </Button>
            {invalid ? <span className="oversight-perm-desc">{t('admin.perms.mc.min_above_max')}</span> : null}
            {lo !== undefined && hi !== undefined ? (
                <span className="oversight-perm-desc">
                    {t('admin.perms.mc.range', { min: formatFactor(lo), max: formatFactor(hi) })}
                </span>
            ) : null}
        </div>
    );
}

// An action control (step P7): the limits it is used with, set in Settings (Mission controls).
function ActionLimits({ control }: { control: MissionControlState }) {
    const parts: string[] = [];
    if (control.perDay !== undefined) parts.push(t('admin.perms.mc.per_day', { n: control.perDay }));
    if (control.maxSeconds !== undefined) {
        parts.push(t('admin.perms.mc.time_total', { minutes: Math.floor(control.maxSeconds / 60) }));
    }
    if (parts.length === 0) return null;
    return <span className="oversight-perm-desc">{parts.join(' · ')}</span>;
}

// ============================================================================
//                       ONE DEPARTMENT (OWN LIMITS, NOW)
// ============================================================================

function DepartmentRow({
    dept,
    control,
    busy,
    onSaveOwn,
    onReset,
}: {
    dept: MissionControlsDepartment;
    control: MissionControlState;
    busy: boolean;
    onSaveOwn: (own: MissionControlBounds | undefined) => void;
    onReset: () => void;
}) {
    const hasOwn = control.own !== undefined && control.own !== null;
    const [ownOpen, setOwnOpen] = useState(hasOwn);
    useEffect(() => setOwnOpen(hasOwn), [hasOwn]);
    return (
        <li className="oversight-mc-dept">
            <div className="oversight-teleport-row__head">
                <div className="oversight-perm-name">
                    <strong>{dept.label}</strong>
                    <code>{dept.key}</code>
                </div>
                <Badge tone={control.active ? 'success' : 'grey'} size="sm">
                    {control.active ? t('admin.perms.mc.dept_on') : t('admin.perms.mc.dept_off')}
                </Badge>
            </div>
            {control.kind === 'action' ? null : <StateLine s={control} busy={busy} onReset={onReset} />}
            {dept.boundsPath ? (
                <>
                    <Checkbox
                        checked={ownOpen}
                        disabled={busy}
                        label={t('admin.perms.mc.own', { dept: dept.short })}
                        onChange={v => {
                            setOwnOpen(v);
                            if (!v && hasOwn) onSaveOwn(undefined);
                        }}
                    />
                    {ownOpen ? (
                        <BoundsFields
                            control={control}
                            bounds={asMap<never>(control.own) as MissionControlBounds}
                            busy={busy}
                            switchLabel={t('admin.perms.mc.own_switch')}
                            onSave={onSaveOwn}
                        />
                    ) : null}
                </>
            ) : (
                <span className="oversight-perm-desc">{t('admin.perms.mc.own_added')}</span>
            )}
        </li>
    );
}

// ============================================================================
//                                 ONE CONTROL
// ============================================================================

function ControlRow({
    control,
    bounds,
    depts,
    busy,
    onSwitch,
    onSaveBounds,
    onSaveOwn,
    onReset,
}: {
    control: MissionControlState;
    bounds: MissionControlBounds;
    // a control per department: each department's state (empty for a server-wide one)
    depts: { dept: MissionControlsDepartment; control: MissionControlState }[];
    busy: boolean;
    onSwitch: (on: boolean) => void;
    onSaveBounds: (next: MissionControlBounds) => void;
    onSaveOwn: (dept: MissionControlsDepartment, own: MissionControlBounds | undefined) => void;
    onReset: (dept?: MissionControlsDepartment) => void;
}) {
    const [open, setOpen] = useState(false);
    const on = bounds.on === true;
    return (
        <li className="oversight-teleport-row oversight-mc-row">
            <div className="oversight-teleport-row__head">
                <div className="oversight-perm-name">
                    <strong>{controlName(control.key)}</strong>
                    <code>{control.key}</code>
                </div>
                <div className="oversight-mc-badges">
                    {control.serverWide ? (
                        <Badge tone="primary" size="sm" icon="globe">
                            {t('admin.perms.mc.server_wide')}
                        </Badge>
                    ) : null}
                    {!control.master ? (
                        <Badge tone="accent" size="sm" variant="outline">
                            {t('admin.perms.mc.outside')}
                        </Badge>
                    ) : null}
                    <Toggle
                        checked={on}
                        disabled={busy}
                        label={on ? t('admin.perms.on') : t('admin.perms.off')}
                        onChange={v => onSwitch(v)}
                    />
                </div>
            </div>
            {controlDesc(control.key) ? <span className="oversight-perm-desc">{controlDesc(control.key)}</span> : null}
            <BoundsFields control={control} bounds={bounds} busy={busy} onSave={onSaveBounds} />
            {control.kind === 'action' ? <ActionLimits control={control} /> : null}
            {control.kind === 'action' && control.serverWide ? null : control.serverWide ? (
                <StateLine s={control} busy={busy} onReset={() => onReset()} />
            ) : (
                <>
                    <div>
                        <Button
                            size="sm"
                            variant="ghost"
                            icon={open ? 'chevronUp' : 'chevronDown'}
                            onClick={() => setOpen(o => !o)}
                        >
                            {open
                                ? t('admin.perms.mc.depts_hide')
                                : t('admin.perms.mc.depts_show', { n: depts.length })}
                        </Button>
                    </div>
                    {open ? (
                        <ul className="oversight-mc-depts">
                            {depts.map(d => (
                                <DepartmentRow
                                    key={d.dept.key}
                                    dept={d.dept}
                                    control={d.control}
                                    busy={busy}
                                    onSaveOwn={own => onSaveOwn(d.dept, own)}
                                    onReset={() => onReset(d.dept)}
                                />
                            ))}
                        </ul>
                    ) : null}
                </>
            )}
        </li>
    );
}

// ============================================================================
//                        THE CONTROLS (THE CARD'S BODY)
// ============================================================================

export function MasterOffBanner() {
    return (
        <div className="oversight-perm-banner">
            <Icon name="info" size={16} />
            <span>{t('admin.perms.mc.master_off')}</span>
        </div>
    );
}

// Every registered control of an admin view: the server-wide ones, then the per-department ones.
export function MissionControlList({
    view,
    busy,
    onSwitch,
    onSaveBounds,
    onSaveOwn,
    onReset,
}: {
    view: MissionControlsView | null | undefined;
    busy: boolean;
    onSwitch: (key: string, on: boolean) => void;
    onSaveBounds: (key: string, next: MissionControlBounds) => void;
    onSaveOwn: (dept: MissionControlsDepartment, key: string, own: MissionControlBounds | undefined) => void;
    onReset: (key: string, dept?: MissionControlsDepartment) => void;
}) {
    const allBounds = asMap<MissionControlBounds>(view?.bounds);
    const depts = asArray(view?.departments);
    const controls = [...asArray(view?.serverWide), ...asArray(depts[0]?.controls)];
    if (controls.length === 0) return <EmptyState compact title={t('admin.perms.mc.none')} />;
    return (
        <ul className="oversight-teleport">
            {controls.map(c => (
                <ControlRow
                    key={c.key}
                    control={c}
                    bounds={asMap<never>(allBounds[c.key]) as MissionControlBounds}
                    depts={
                        c.serverWide
                            ? []
                            : depts.flatMap(d => {
                                  const dc = asArray(d.controls).find(x => x.key === c.key);
                                  return dc ? [{ dept: d, control: dc }] : [];
                              })
                    }
                    busy={busy}
                    onSwitch={on => onSwitch(c.key, on)}
                    onSaveBounds={next => onSaveBounds(c.key, next)}
                    onSaveOwn={(d, own) => onSaveOwn(d, c.key, own)}
                    onReset={d => onReset(c.key, d)}
                />
            ))}
        </ul>
    );
}

// ============================================================================
//                                   THE CARD
// ============================================================================

export function MissionControlsCard({
    master,
    grantDepartments,
    grants,
    stamp,
    onSettingsSaved,
}: {
    // the master switch (Config.Permissions.supervisor.missionControls)
    master: boolean;
    // every department with its Qbox grades (from admin:getPermissions)
    grantDepartments: TeleportDepartment[];
    grants: Record<string, TeleportGrant>;
    // changes whenever admin:getPermissions answers again (a setting changed): the controls are read again too
    stamp: unknown;
    onSettingsSaved: () => void;
}) {
    const { data, loading, error, refetch } = useRequest<MissionControlsView>(
        'admin:getMissionControls',
        {},
        { pushTopic: 'missionControls' },
    );
    const first = useRef(true);
    useEffect(() => {
        if (first.current) {
            first.current = false;
            return;
        }
        void refetch();
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [stamp]);
    const { run, busy } = useAdminAction();
    const [resetting, setResetting] = useState<{ key: string; dept?: MissionControlsDepartment } | null>(null);

    const allBounds = asMap<MissionControlBounds>(data?.bounds);

    const saved = (ok: boolean) => {
        if (ok) {
            void refetch();
            onSettingsSaved();
        }
    };
    // Config.MissionControls.controls is one setting: the whole map with this control's bounds replaced.
    const saveBounds = async (key: string, next: MissionControlBounds, success: string) => {
        const value: Record<string, MissionControlBounds> = {};
        for (const [k, b] of Object.entries(allBounds)) value[k] = asMap<never>(b) as MissionControlBounds;
        value[key] = next;
        const res = await run(
            'server:admin:setSetting',
            { path: 'MissionControls.controls', value },
            { requestId: false, success, successVars: { name: controlName(key) } },
        );
        saved(res.ok);
    };
    // A department's own limits: Config.Departments.<key>.missionControls, the whole map (none when empty).
    const saveOwn = async (dept: MissionControlsDepartment, key: string, own: MissionControlBounds | undefined) => {
        if (!dept.boundsPath) return;
        const value: Record<string, MissionControlBounds> = {};
        for (const c of asArray(dept.controls)) {
            if (c.own !== undefined && c.own !== null && c.key !== key) value[c.key] = asMap<never>(c.own);
        }
        if (own) value[key] = own;
        const empty = Object.keys(value).length === 0;
        const res = await run(
            'server:admin:setSetting',
            empty ? { path: dept.boundsPath, none: true } : { path: dept.boundsPath, value },
            { requestId: false, success: 'admin.perms.mc.own_saved', successVars: { dept: dept.short } },
        );
        saved(res.ok);
    };
    const saveGrant = async (dept: TeleportDepartment, grant: TeleportGrant | undefined) => {
        const value: Record<string, TeleportGrant> = {};
        for (const d of grantDepartments) {
            const g = d.key === dept.key ? grant : grants[d.key];
            if (g) value[d.key] = g;
        }
        const res = await run(
            'server:admin:setSetting',
            { path: 'MissionControls.grants', value },
            { requestId: false, success: 'admin.perms.mc.grants_saved', successVars: { dept: dept.short } },
        );
        saved(res.ok);
    };
    const reset = async (reason: string) => {
        if (!resetting) return;
        const res = await run(
            'server:admin:resetMissionControl',
            { key: resetting.key, department: resetting.dept?.key, reason },
            { success: 'admin.perms.mc.reset_done', successVars: { name: controlName(resetting.key) } },
        );
        if (res.ok) void refetch();
        setResetting(null);
    };

    let body;
    if (loading && !data) body = <LoadingBlock />;
    else if (error && !data) body = <ErrorState error={error} onRetry={() => void refetch()} />;
    else
        body = (
            <MissionControlList
                view={data}
                busy={busy}
                onSwitch={(key, on) =>
                    void saveBounds(
                        key,
                        { ...asMap<never>(allBounds[key]), on },
                        on ? 'admin.perms.mc.switched_on' : 'admin.perms.mc.switched_off',
                    )
                }
                onSaveBounds={(key, next) => void saveBounds(key, next, 'admin.perms.mc.bounds_saved')}
                onSaveOwn={(d, key, own) => void saveOwn(d, key, own)}
                onReset={(key, d) => setResetting({ key, dept: d })}
            />
        );

    return (
        <Card title={t('admin.perms.mc.title')} icon="sliders" subtitle={t('admin.perms.mc.subtitle')}>
            {!master ? <MasterOffBanner /> : null}
            {body}
            {grantDepartments.length > 0 ? (
                <div className="oversight-mc-grants">
                    <div className="oversight-perm-name">
                        <strong>{t('admin.perms.mc.grants_title')}</strong>
                        <span className="oversight-perm-desc">{t('admin.perms.mc.grants_text')}</span>
                    </div>
                    <ul className="oversight-teleport">
                        {grantDepartments.map(d => (
                            <GradeGrantRow
                                key={d.key}
                                dept={{ ...d, grant: grants[d.key] }}
                                busy={busy}
                                prefix="admin.perms.mc.grant"
                                onSave={g => void saveGrant(d, g)}
                            />
                        ))}
                    </ul>
                </div>
            ) : null}
            <ConfirmDialog
                open={!!resetting}
                tone="danger"
                title={resetting ? t('admin.perms.mc.reset_title', { name: controlName(resetting.key) }) : ''}
                message={
                    resetting
                        ? t('admin.perms.mc.reset_text', {
                              name: controlName(resetting.key),
                              where: resetting.dept ? resetting.dept.label : t('admin.perms.mc.everywhere'),
                          })
                        : ''
                }
                reason
                onConfirm={reset}
                onCancel={() => setResetting(null)}
                busy={busy}
            />
        </Card>
    );
}
