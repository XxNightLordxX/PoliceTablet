// Slot: Settings → Item rewards: a structured editor for the reward pools (item picker without forbidden items,
// chance 0–1, rolls 0–10, count 1–100, weight above 0, value 0 or more) with the server's verdict and the expected
// items and value per run at each tier. The server checks every value again (the raw editor gets the same answers).

import { useEffect, useMemo, useState } from 'react';
import {
    Button,
    Field,
    IconButton,
    NumberInput,
    Select,
    Table,
    TextInput,
    type TableColumn,
} from '../../shared/components';
import { formatMoney } from '../../shared/format';
import { useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import type { RewardPoolSlotProps } from '../../types/admin_control';
import type { RewardItemChoices, RewardPoolPreview } from '../../types/rewards';
import './RewardPoolEditor.css';

const ENTRY_PATHS = ['Rewards.byType', 'Rewards.byMission'];
const SPEC_PATHS = ['Rewards.medals', 'Rewards.goals', 'Rewards.levels', 'Rewards.season'];
const BOSS_PATH = 'Rewards.weeklyBoss';

export function handlesRewardPool(path: string): boolean {
    return ENTRY_PATHS.includes(path) || SPEC_PATHS.includes(path) || path === BOSS_PATH;
}

interface SpecRow {
    item: string;
    lo: number;
    hi: number;
    weight: number;
    value: number;
}

interface Group {
    key: string;
    chance: number;
    rolls: number;
    specs: SpecRow[];
}

type Raw = Record<string, unknown>;

function num(v: unknown, d: number): number {
    const n = Number(v);
    return Number.isFinite(n) ? n : d;
}

function toSpec(v: unknown): SpecRow | null {
    if (!v || typeof v !== 'object') return null;
    const s = v as Raw;
    const c = s.count;
    const lo = Array.isArray(c) ? num(c[0], 1) : num(c, 1);
    const hi = Array.isArray(c) ? num(c[1], lo) : lo;
    return { item: String(s.item ?? ''), lo, hi, weight: num(s.weight, 1), value: num(s.value, 0) };
}

function specsOf(v: unknown): SpecRow[] {
    if (!v || typeof v !== 'object') return [];
    if ((v as Raw).item !== undefined) {
        const one = toSpec(v);
        return one ? [one] : [];
    }
    return Object.values(v as Raw)
        .map(toSpec)
        .filter((s): s is SpecRow => !!s);
}

function groupsOf(path: string, value: unknown): Group[] {
    if (path === BOSS_PATH) return [{ key: 'weeklyBoss', chance: 1, rolls: 1, specs: specsOf(value) }];
    const map = value && typeof value === 'object' ? (value as Raw) : {};
    return Object.keys(map)
        .sort()
        .map(key => {
            const e = map[key];
            if (ENTRY_PATHS.includes(path)) {
                const entry = e && typeof e === 'object' ? (e as Raw) : {};
                return { key, chance: num(entry.chance, 0), rolls: num(entry.rolls, 1), specs: specsOf(entry.pool) };
            }
            return { key, chance: 1, rolls: 1, specs: specsOf(e) };
        });
}

function specValue(s: SpecRow, pooled: boolean): Raw {
    const out: Raw = { item: s.item, count: s.lo === s.hi ? s.lo : [s.lo, s.hi], value: s.value };
    if (pooled) out.weight = s.weight;
    return out;
}

function valueOf(path: string, groups: Group[]): unknown {
    if (path === BOSS_PATH) {
        const specs = groups[0]?.specs ?? [];
        if (specs.length === 0) return null;
        return specs.length === 1 ? specValue(specs[0], false) : specs.map(s => specValue(s, false));
    }
    const out: Raw = {};
    for (const g of groups) {
        if (!g.key.trim()) continue;
        if (ENTRY_PATHS.includes(path)) {
            out[g.key.trim()] = { chance: g.chance, rolls: g.rolls, pool: g.specs.map(s => specValue(s, true)) };
        } else {
            out[g.key.trim()] =
                g.specs.length === 1 ? specValue(g.specs[0], false) : g.specs.map(s => specValue(s, false));
        }
    }
    return out;
}

export function RewardPoolEditor({ path, value, disabled, onSave }: RewardPoolSlotProps) {
    const pooled = ENTRY_PATHS.includes(path);
    const [groups, setGroups] = useState<Group[]>(() => groupsOf(path, value));
    const [dirty, setDirty] = useState(false);
    useEffect(() => {
        setGroups(groupsOf(path, value));
        setDirty(false);
    }, [path, value]);
    const built = useMemo(() => valueOf(path, groups), [path, groups]);
    const items = useRequest<RewardItemChoices>('admin:rewardItems', {});
    const preview = useRequest<RewardPoolPreview>('admin:rewardPoolPreview', { path, value: built });
    const options = (items.data?.items ?? []).map(i => ({ value: i.name, label: `${i.label} (${i.name})` }));

    const edit = (gi: number, fn: (g: Group) => Group) => {
        setGroups(gs => gs.map((g, i) => (i === gi ? fn(g) : g)));
        setDirty(true);
    };
    const editSpec = (gi: number, si: number, patch: Partial<SpecRow>) =>
        edit(gi, g => ({ ...g, specs: g.specs.map((s, i) => (i === si ? { ...s, ...patch } : s)) }));

    const err = preview.data?.error;
    const expected = preview.data?.expected ?? [];

    return (
        <div className="reward-pools">
            {groups.map((g, gi) => (
                <div key={gi} className="reward-pools__group">
                    <div className="reward-pools__head">
                        {path === BOSS_PATH ? (
                            <strong>{t('rewardpool.boss')}</strong>
                        ) : (
                            <Field label={t('rewardpool.key')}>
                                <TextInput
                                    value={g.key}
                                    disabled={disabled}
                                    onChange={v => edit(gi, x => ({ ...x, key: v }))}
                                />
                            </Field>
                        )}
                        {pooled ? (
                            <>
                                <Field label={t('rewardpool.chance')}>
                                    <NumberInput
                                        value={g.chance}
                                        integer={false}
                                        step={0.05}
                                        min={0}
                                        max={1}
                                        disabled={disabled}
                                        onChange={v => edit(gi, x => ({ ...x, chance: v ?? 0 }))}
                                    />
                                </Field>
                                <Field label={t('rewardpool.rolls')}>
                                    <NumberInput
                                        value={g.rolls}
                                        min={0}
                                        max={10}
                                        disabled={disabled}
                                        onChange={v => edit(gi, x => ({ ...x, rolls: v ?? 0 }))}
                                    />
                                </Field>
                            </>
                        ) : null}
                        {path !== BOSS_PATH ? (
                            <IconButton
                                icon="trash"
                                size="sm"
                                label={t('rewardpool.remove_key')}
                                disabled={disabled}
                                onClick={() => {
                                    setGroups(gs => gs.filter((_, i) => i !== gi));
                                    setDirty(true);
                                }}
                            />
                        ) : null}
                    </div>
                    {g.specs.map((s, si) => (
                        <div key={si} className="reward-pools__spec">
                            <Field label={t('rewardpool.item')}>
                                {options.length > 0 ? (
                                    <Select
                                        value={s.item}
                                        onChange={v => editSpec(gi, si, { item: v })}
                                        options={options}
                                        placeholder={t('rewardpool.pick_item')}
                                        disabled={disabled}
                                    />
                                ) : (
                                    <TextInput
                                        value={s.item}
                                        disabled={disabled}
                                        onChange={v => editSpec(gi, si, { item: v })}
                                    />
                                )}
                            </Field>
                            <Field label={t('rewardpool.count_lo')}>
                                <NumberInput
                                    value={s.lo}
                                    min={1}
                                    max={100}
                                    disabled={disabled}
                                    onChange={v => editSpec(gi, si, { lo: v ?? 1 })}
                                />
                            </Field>
                            <Field label={t('rewardpool.count_hi')}>
                                <NumberInput
                                    value={s.hi}
                                    min={1}
                                    max={100}
                                    disabled={disabled}
                                    onChange={v => editSpec(gi, si, { hi: v ?? 1 })}
                                />
                            </Field>
                            {pooled ? (
                                <Field label={t('rewardpool.weight')}>
                                    <NumberInput
                                        value={s.weight}
                                        integer={false}
                                        min={0.01}
                                        max={1000}
                                        disabled={disabled}
                                        onChange={v => editSpec(gi, si, { weight: v ?? 1 })}
                                    />
                                </Field>
                            ) : null}
                            <Field label={t('rewardpool.value')}>
                                <NumberInput
                                    value={s.value}
                                    min={0}
                                    max={1000000}
                                    prefix="$"
                                    disabled={disabled}
                                    onChange={v => editSpec(gi, si, { value: v ?? 0 })}
                                />
                            </Field>
                            <IconButton
                                icon="x"
                                size="sm"
                                label={t('rewardpool.remove_item')}
                                disabled={disabled}
                                onClick={() => edit(gi, x => ({ ...x, specs: x.specs.filter((_, i) => i !== si) }))}
                            />
                        </div>
                    ))}
                    <Button
                        size="sm"
                        icon="plus"
                        disabled={disabled}
                        onClick={() =>
                            edit(gi, x => ({
                                ...x,
                                specs: [...x.specs, { item: '', lo: 1, hi: 1, weight: 1, value: 0 }],
                            }))
                        }
                    >
                        {t('rewardpool.add_item')}
                    </Button>
                </div>
            ))}
            {path !== BOSS_PATH ? (
                <Button
                    size="sm"
                    icon="plus"
                    disabled={disabled}
                    onClick={() => {
                        setGroups(gs => [...gs, { key: '', chance: 0.1, rolls: 1, specs: [] }]);
                        setDirty(true);
                    }}
                >
                    {t('rewardpool.add_key')}
                </Button>
            ) : null}
            {err ? <div className="reward-pools__error">{t(err)}</div> : null}
            {expected.map(e => (
                <ExpectedTable key={e.key} name={e.key} tiers={e.tiers} />
            ))}
            <div className="reward-pools__save">
                <Button
                    size="sm"
                    variant="primary"
                    icon="check"
                    disabled={disabled || !dirty || !!err}
                    onClick={() => void onSave(built)}
                >
                    {t('rewardpool.save')}
                </Button>
                {dirty ? (
                    <Button
                        size="sm"
                        variant="ghost"
                        onClick={() => (setGroups(groupsOf(path, value)), setDirty(false))}
                    >
                        {t('common.cancel')}
                    </Button>
                ) : null}
            </div>
        </div>
    );
}

type TierRow = RewardPoolPreview['expected'][number]['tiers'][number];

function ExpectedTable({ name, tiers }: { name: string; tiers: TierRow[] }) {
    const columns: TableColumn<TierRow>[] = [
        { key: 'tier', header: t('rewardpool.tier'), render: r => t(`tier.${r.tier}`) },
        { key: 'chance', header: t('rewardpool.chance'), numeric: true, render: r => `${Math.round(r.chance * 100)}%` },
        { key: 'items', header: t('rewardpool.expected_items'), numeric: true, render: r => r.items.toFixed(2) },
        { key: 'value', header: t('rewardpool.expected_value'), numeric: true, render: r => formatMoney(r.value) },
    ];
    return (
        <div className="reward-pools__expected">
            <span className="reward-pools__expected-title">{t('rewardpool.expected', { key: name })}</span>
            <Table columns={columns} rows={tiers} rowKey={r => r.tier} dense />
        </div>
    );
}
