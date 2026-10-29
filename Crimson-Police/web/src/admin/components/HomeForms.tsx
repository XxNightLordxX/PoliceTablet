// Admin UI · Home quick forms (Config.AdminUi.homeForms): the common jobs done on the Home tile itself. Each form

import { useMemo, useState } from 'react';
import { Badge, Button, Field, NumberInput, SearchInput, TextInput, Toggle } from '../../shared/components';
import { asArray } from '../../shared/data';
import { formatMoney, formatNumber } from '../../shared/format';
import { useAction, useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { OfficerPicker, newRequestId } from './kit';
import { SettingRow, mergeSettingsReply, useSettingSave } from '../screens/Settings';
import type { AdminMissionEntry, AdminMissionsData } from '../../types/builder_client';
import type { AdminPayoutsView } from '../../types/economy';
import type { OfficerPoints } from '../../types/admin_officers';
import type { SettingsData, SettingView } from '../../types/settings';

// How many matches a search lists on a tile (the full screen lists them all).
const LISTED = 5;
const REASON_MAX = 255;
// modules/corrections: -10,000 to +10,000 points per adjustment (not 0)
const POINTS_MAX = 10000;

const has = (text: string | null | undefined, q: string) => (text ?? '').toLowerCase().includes(q);

// ============================================================================
//                        SWITCH MISSIONS AND LOCATIONS
// ============================================================================

export function MissionSwitchForm() {
    const missions = useRequest<AdminMissionsData>('admin:getMissions', {}, { pushTopic: 'operation' });
    const { run, busy } = useAction();
    const [query, setQuery] = useState('');
    const [openId, setOpenId] = useState<string | null>(null);
    const q = query.trim().toLowerCase();
    const all = asArray(missions.data?.missions).filter(m => !!m.switch);
    const found = q ? all.filter(m => has(m.label, q) || has(m.id, q) || has(m.typeLabel, q)) : [];
    const off = all.filter(m => !m.switch?.on).length;

    const setMission = async (m: AdminMissionEntry, enabled: boolean) => {
        const res = await run(
            'server:admin:setMissionEnabled',
            { missionId: m.id, enabled },
            {
                success: enabled ? 'settings.mission.turned_on' : 'settings.mission.turned_off',
                successVars: { mission: m.label },
            },
        );
        if (res.ok) void missions.refetch();
    };
    const setLocation = async (m: AdminMissionEntry, index: number, enabled: boolean) => {
        const res = await run('server:admin:setLocationEnabled', { missionId: m.id, index, enabled });
        if (res.ok) void missions.refetch();
    };

    return (
        <div className="admin-home-form">
            <SearchInput
                value={query}
                onChange={setQuery}
                placeholder={t('admin.home.form_mission_search')}
                aria-label={t('admin.home.form_mission_search')}
            />
            {!q ? (
                <div className="admin-home-form__hint">
                    {t('admin.home.form_mission_hint', { n: formatNumber(all.length), off: formatNumber(off) })}
                </div>
            ) : found.length === 0 ? (
                <div className="admin-home-form__hint">{t('admin.home.form_none')}</div>
            ) : (
                <ul className="admin-home-form__list">
                    {found.slice(0, LISTED).map(m => {
                        const sw = m.switch!;
                        const locations = asArray(sw.locations);
                        const on = locations.filter(l => l.on).length;
                        const opened = openId === m.id;
                        return (
                            <li key={m.id} className="admin-home-form__item">
                                <div className="admin-home-form__row">
                                    <Toggle
                                        checked={sw.on}
                                        disabled={busy}
                                        label={m.label}
                                        onChange={v => void setMission(m, v)}
                                    />
                                    {locations.length > 0 ? (
                                        <button
                                            type="button"
                                            className="admin-home-form__more"
                                            aria-expanded={opened}
                                            onClick={() => setOpenId(opened ? null : m.id)}
                                        >
                                            {t('settings.mission.locations', { on, total: locations.length })}
                                        </button>
                                    ) : null}
                                </div>
                                {opened ? (
                                    <div className="admin-home-form__sub">
                                        {locations.map(l => (
                                            <Toggle
                                                key={l.index}
                                                checked={l.on}
                                                disabled={busy}
                                                label={l.label}
                                                onChange={v => void setLocation(m, l.index, v)}
                                            />
                                        ))}
                                    </div>
                                ) : null}
                            </li>
                        );
                    })}
                    {found.length > LISTED ? (
                        <li className="admin-home-form__hint">
                            {t('admin.home.form_more', { n: formatNumber(found.length - LISTED) })}
                        </li>
                    ) : null}
                </ul>
            )}
        </div>
    );
}

// ============================================================================
//                                  CHANGE PAY
// ============================================================================

interface PayTarget {
    kind: 'type' | 'mission';
    id: string;
    label: string;
    current: number;
    // types only: the payout is set and still open to supervisors (a save keeps it so)
    unlocked?: boolean;
}

export function PayForm() {
    const view = useRequest<AdminPayoutsView>('admin:getPayouts', {}, { pushTopic: 'payouts' });
    const { run, busy } = useAction();
    const [query, setQuery] = useState('');
    const [target, setTarget] = useState<PayTarget | null>(null);
    const [amount, setAmount] = useState<number | null>(null);
    const [valid, setValid] = useState(true);
    const [reason, setReason] = useState('');
    const lo = view.data?.limits?.min ?? 0;
    const hi = view.data?.limits?.max ?? 25000;
    const needReason = view.data?.requireReason !== false;
    const targets = useMemo<PayTarget[]>(
        () => [
            ...asArray(view.data?.types).map(r => ({
                kind: 'type' as const,
                id: r.key,
                label: r.label,
                current: r.amount,
                unlocked: r.stored && !r.adminLocked,
            })),
            ...asArray(view.data?.missions)
                .filter(m => !m.missing)
                .map(m => ({ kind: 'mission' as const, id: m.id, label: m.label, current: m.base })),
        ],
        [view.data],
    );
    const q = query.trim().toLowerCase();
    const found = q ? targets.filter(x => has(x.label, q) || has(x.id, q)) : [];

    const pick = (x: PayTarget) => {
        setTarget(x);
        setAmount(x.current);
        setValid(true);
        setReason('');
    };
    const canSave =
        !!target &&
        valid &&
        amount !== null &&
        amount >= lo &&
        amount <= hi &&
        amount !== target.current &&
        (!needReason || reason.trim().length > 0) &&
        !busy;
    const save = async () => {
        if (!target || !canSave || amount === null) return;
        const name = target.kind === 'type' ? 'server:admin:setTypePayout' : 'server:admin:setMissionPayout';
        const payload =
            target.kind === 'type'
                ? { type: target.id, amount, reason: reason.trim(), unlock: !!target.unlocked }
                : { missionId: target.id, amount, reason: reason.trim() };
        const res = await run(name, payload, {
            success: 'admin.payouts.saved',
            successVars: { name: target.label, amount: formatMoney(amount) },
        });
        if (res.ok) {
            setTarget(null);
            setQuery('');
            void view.refetch();
        }
    };

    if (!target) {
        return (
            <div className="admin-home-form">
                <SearchInput
                    value={query}
                    onChange={setQuery}
                    placeholder={t('admin.home.form_pay_search')}
                    aria-label={t('admin.home.form_pay_search')}
                />
                {q && found.length === 0 ? (
                    <div className="admin-home-form__hint">{t('admin.home.form_none')}</div>
                ) : null}
                {found.length > 0 ? (
                    <ul className="admin-home-form__list">
                        {found.slice(0, LISTED).map(x => (
                            <li key={`${x.kind}:${x.id}`}>
                                <button type="button" className="admin-home-form__pick" onClick={() => pick(x)}>
                                    <span className="admin-home-form__label">{x.label}</span>
                                    <Badge size="sm" tone="neutral" variant="outline">
                                        {t(
                                            x.kind === 'type'
                                                ? 'admin.home.form_pay_type'
                                                : 'admin.home.form_pay_mission',
                                        )}
                                    </Badge>
                                    <span className="admin-home-form__meta cp-num">{formatMoney(x.current)}</span>
                                </button>
                            </li>
                        ))}
                    </ul>
                ) : null}
            </div>
        );
    }
    return (
        <div className="admin-home-form">
            <div className="admin-home-form__chosen">
                <strong>{target.label}</strong>
                <span className="admin-home-form__meta cp-num">
                    {t('admin.home.form_pay_now', { amount: formatMoney(target.current) })}
                </span>
                <button type="button" className="admin-home-form__more" onClick={() => setTarget(null)}>
                    {t('ui.kit.change')}
                </button>
            </div>
            <Field label={t('admin.payouts.new_amount')} required>
                <NumberInput
                    value={amount}
                    onChange={setAmount}
                    min={lo}
                    max={hi}
                    step={50}
                    prefix="$"
                    formatRange={formatMoney}
                    onValidityChange={setValid}
                    aria-label={t('admin.payouts.new_amount')}
                />
            </Field>
            <Field
                label={t('common.reason')}
                required={needReason}
                hint={needReason ? undefined : t('common.optional')}
            >
                <TextInput
                    value={reason}
                    onChange={setReason}
                    maxLength={REASON_MAX}
                    placeholder={t('admin.payouts.reason_placeholder')}
                />
            </Field>
            <div className="admin-home-form__actions">
                <Button variant="primary" size="sm" icon="check" disabled={!canSave} loading={busy} onClick={save}>
                    {t('common.save')}
                </Button>
            </div>
        </div>
    );
}

// ============================================================================
//                             GIVE OR TAKE POINTS
// ============================================================================

export function PointsForm() {
    const { run, busy } = useAction();
    const [cid, setCid] = useState<string | null>(null);
    const [name, setName] = useState<string | null>(null);
    const [points, setPoints] = useState<number | null>(null);
    const [reason, setReason] = useState('');
    const [typed, setTyped] = useState('');
    const info = useRequest<OfficerPoints>('admin:getOfficerPoints', { citizenid: cid ?? '' }, { skip: !cid });
    const confirmAbove = info.data?.adjust.confirmAbove ?? 500;
    // at or above Corrections.adjustConfirmAbove the citizen ID is typed (the server asks for it too)
    const word = cid && Math.abs(points ?? 0) >= confirmAbove ? cid : '';
    const ok =
        !!cid &&
        points !== null &&
        points !== 0 &&
        !!reason.trim() &&
        (!word || typed.trim().toUpperCase() === word.toUpperCase()) &&
        !busy;
    const save = async () => {
        if (!ok || !cid || points === null) return;
        const res = await run(
            'server:admin:adjustPoints',
            {
                citizenid: cid,
                points,
                reason: reason.trim(),
                confirm: word ? typed.trim() : undefined,
                requestId: newRequestId(),
            },
            {
                success: 'admin.boards.awarded',
                successVars: { points: formatNumber(points), who: name ?? cid },
            },
        );
        if (res.ok) {
            setPoints(null);
            setReason('');
            setTyped('');
            void info.refetch();
        }
    };
    return (
        <div className="admin-home-form">
            <OfficerPicker
                value={cid}
                onChange={(c, o) => {
                    setCid(c);
                    setName(o?.name ?? null);
                    setTyped('');
                }}
                placeholder={t('admin.home.form_points_search')}
            />
            {cid ? (
                <>
                    {name ? <div className="admin-home-form__hint">{name}</div> : null}
                    <Field label={t('admin.boards.points')} required hint={t('admin.home.form_points_hint')}>
                        <NumberInput
                            value={points}
                            onChange={setPoints}
                            min={-POINTS_MAX}
                            max={POINTS_MAX}
                            integer
                            formatRange={formatNumber}
                            aria-label={t('admin.boards.points')}
                        />
                    </Field>
                    <Field label={t('common.reason')} required>
                        <TextInput
                            value={reason}
                            onChange={setReason}
                            maxLength={REASON_MAX}
                            placeholder={t('admin.boards.reason_placeholder')}
                        />
                    </Field>
                    {word ? (
                        <Field label={t('ui.admin_officers.type_word', { word })} required>
                            <TextInput value={typed} onChange={setTyped} />
                        </Field>
                    ) : null}
                    <div className="admin-home-form__actions">
                        <Button variant="primary" size="sm" icon="check" disabled={!ok} loading={busy} onClick={save}>
                            {t('common.save')}
                        </Button>
                    </div>
                </>
            ) : null}
        </div>
    );
}

// ============================================================================
//                                QUICK SETTINGS
// ============================================================================

export function QuickSettingsForm() {
    const { data, setData } = useRequest<SettingsData>('admin:getSettings', {}, { pushTopic: 'settings' });
    const [query, setQuery] = useState('');
    const { save, reset, busy, dialogs } = useSettingSave(reply => {
        if (reply) setData(prev => mergeSettingsReply(prev, reply));
    });
    const common = useMemo(() => {
        const byPath = new Map<string, SettingView>();
        for (const sec of asArray(data?.sections))
            for (const g of asArray(sec.groups)) for (const s of asArray(g.settings)) byPath.set(s.path, s);
        return asArray(data?.common)
            .map(p => byPath.get(p))
            .filter((s): s is SettingView => !!s);
    }, [data]);
    const q = query.trim().toLowerCase();
    const found = q ? common.filter(s => has(s.label, q) || has(s.help, q) || has(s.path, q)) : [];
    return (
        <div className="admin-home-form">
            <SearchInput
                value={query}
                onChange={setQuery}
                placeholder={t('admin.home.settings_placeholder')}
                aria-label={t('admin.home.settings_placeholder')}
            />
            {!q ? (
                <div className="admin-home-form__hint">
                    {t('admin.home.form_settings_hint', { n: formatNumber(common.length) })}
                </div>
            ) : found.length === 0 ? (
                <div className="admin-home-form__hint">{t('admin.home.form_settings_none')}</div>
            ) : (
                <div className="admin-home-form__settings">
                    {found.slice(0, LISTED).map(s => (
                        <SettingRow
                            key={s.path}
                            s={s}
                            disabled={busy || !!data?.safeMode}
                            save={save}
                            reset={reset}
                            resets={data?.resets}
                            simple
                        />
                    ))}
                    {found.length > LISTED ? (
                        <div className="admin-home-form__hint">
                            {t('admin.home.form_more', { n: formatNumber(found.length - LISTED) })}
                        </div>
                    ) : null}
                </div>
            )}
            {dialogs}
        </div>
    );
}
