// "Details": name, description, mission type (required), difficulty stars,

import {
    Badge,
    Button,
    Card,
    Checkbox,
    Field,
    Grid,
    Icon,
    NumberInput,
    Select,
    TextInput,
    Textarea,
    Toggle,
    TierBadge,
} from '../../shared/components';
import { asArray } from '../../shared/data';
import { t, tOr } from '../../shared/i18n';
import type { BuilderBonusEntry, BuilderBonusOption } from '../../types/builder_server';
import { MinutesField, RangeNumber, RemoveButton, StarPicker } from '../controls';
import { messageAt } from '../defUtils';
import { detailRange, requiredTierFor, suggestsNoVehiclePenalties, totalArmed } from '../schema';
import { StepIntro, type StepProps } from './common';

function forbiddenItem(name: string): boolean {
    const n = name.trim().toLowerCase();
    return n === 'armour' || n === 'bandage' || n.startsWith('ammo-') || n.startsWith('weapon_');
}

export function StepDetails({ ed, cfg, def, ro }: StepProps) {
    const e = ed.errors;
    const off = detailRange(cfg, 'officers', [1, 4, 4]);
    const stars = detailRange(cfg, 'difficulty', [1, 3, 2]);
    const limits = cfg.limits ?? { label: 64, description: 500, objectiveLabel: 64, locationLabel: 64 };
    const types = asArray(cfg.missionTypes);
    const depts = asArray(cfg.departments);
    const suggest = suggestsNoVehiclePenalties(def);
    const required = requiredTierFor(cfg, def.maxOfficers);
    const set = <K extends keyof typeof def>(k: K, v: (typeof def)[K]) =>
        ed.update(d => {
            d[k] = v;
        });

    return (
        <div className="builder_client-step">
            <StepIntro icon="fileText" title={t('builder.details.title')}>
                {t('builder.details.intro')}
            </StepIntro>
            <Grid cols="3fr 2fr" gap={4} align="start">
                <div className="builder_client-col">
                    <Card title={t('builder.details.mission')} icon="edit" padding="md">
                        <div className="builder_client-form">
                            <Field
                                label={t('builder.details.name')}
                                required
                                error={messageAt(e, 'label')}
                                hint={t('builder.details.name_hint', { max: limits.label })}
                            >
                                <TextInput
                                    value={def.label}
                                    maxLength={limits.label}
                                    disabled={ro}
                                    onChange={v => set('label', v.slice(0, limits.label))}
                                />
                            </Field>
                            <Field label={t('builder.details.description')} error={messageAt(e, 'description')}>
                                <Textarea
                                    value={def.description}
                                    maxLength={limits.description}
                                    rows={3}
                                    disabled={ro}
                                    onChange={v => set('description', v.slice(0, limits.description))}
                                />
                            </Field>
                            <Field
                                label={t('builder.details.type')}
                                required
                                error={messageAt(e, 'type')}
                                hint={t('builder.details.type_hint')}
                            >
                                <Select
                                    value={def.type ?? ''}
                                    disabled={ro}
                                    placeholder={t('builder.details.type_pick')}
                                    onChange={v => set('type', v)}
                                    options={types.map(m => ({
                                        value: m.key,
                                        label: t('builder.details.type_option', { label: m.label, points: m.points }),
                                    }))}
                                />
                            </Field>
                            <div className="builder_client-callout">
                                <Icon name="info" size={15} />
                                <span>{t('builder.details.no_payout')}</span>
                            </div>
                        </div>
                    </Card>
                    <Card
                        title={t('builder.details.bonuses')}
                        icon="star"
                        padding="md"
                        subtitle={t('builder.details.bonuses_sub', {
                            points: cfg.bonusCap?.points ?? 50,
                            pct: cfg.bonusCap?.pct ?? 25,
                        })}
                    >
                        <BonusList kind="bonuses" {...{ ed, cfg, def, ro }} />
                        <div className="builder_client-divider" />
                        <BonusList kind="penalties" {...{ ed, cfg, def, ro }} />
                    </Card>
                </div>
                <div className="builder_client-col">
                    <Card title={t('builder.details.difficulty_group')} icon="users" padding="md">
                        <div className="builder_client-form">
                            <Field
                                label={t('builder.details.difficulty')}
                                error={messageAt(e, 'difficulty')}
                                hint={t('builder.details.difficulty_hint')}
                            >
                                <StarPicker
                                    value={def.difficulty}
                                    min={stars.min}
                                    max={stars.max}
                                    disabled={ro}
                                    onChange={n => set('difficulty', n)}
                                />
                            </Field>
                            <Grid cols={2} gap={3}>
                                <RangeNumber
                                    label={t('builder.details.min_officers')}
                                    value={def.minOfficers}
                                    range={{ ...off, def: off.min }}
                                    disabled={ro}
                                    onChange={v =>
                                        ed.update(d => {
                                            d.minOfficers = v;
                                            if (d.maxOfficers < v) d.maxOfficers = v;
                                        })
                                    }
                                />
                                <RangeNumber
                                    label={t('builder.details.max_officers')}
                                    value={def.maxOfficers}
                                    range={{ ...off, def: off.max }}
                                    disabled={ro}
                                    error={messageAt(e, 'maxOfficers', 'minOfficers')}
                                    onChange={v =>
                                        ed.update(d => {
                                            d.maxOfficers = v;
                                            if (d.minOfficers > v) d.minOfficers = v;
                                        })
                                    }
                                />
                            </Grid>
                            <div className="builder_client-tier-line">
                                <span>{t('builder.details.required_tier')}</span>
                                <TierBadge tier={required} size="sm" />
                            </div>
                        </div>
                    </Card>
                    <Card title={t('builder.details.timing')} icon="clock" padding="md">
                        <div className="builder_client-form">
                            <MinutesField
                                label={t('builder.details.time_limit')}
                                seconds={def.timeLimit}
                                range={detailRange(cfg, 'timeLimit', [120, 1200, 600])}
                                disabled={ro}
                                error={messageAt(e, 'timeLimit')}
                                onChange={s => set('timeLimit', s)}
                            />
                            <MinutesField
                                label={t('builder.details.start_timeout')}
                                seconds={def.startTimeout}
                                range={detailRange(cfg, 'startTimeout', [300, 900, 600])}
                                disabled={ro}
                                error={messageAt(e, 'startTimeout')}
                                onChange={s => set('startTimeout', s)}
                            />
                            <MinutesField
                                label={t('builder.details.cooldown')}
                                seconds={def.cooldown}
                                range={detailRange(cfg, 'cooldown', [300, 3600, 1200])}
                                disabled={ro}
                                error={messageAt(e, 'cooldown')}
                                onChange={s => set('cooldown', s)}
                            />
                        </div>
                    </Card>
                    <Card title={t('builder.details.available_to')} icon="building" padding="md">
                        <Field
                            error={messageAt(e, 'departments')}
                            hint={
                                def.departments.length
                                    ? t('builder.details.available_some')
                                    : t('builder.details.available_all')
                            }
                        >
                            <div className="builder_client-depts">
                                {depts.map(d => (
                                    <Checkbox
                                        key={d.key}
                                        checked={def.departments.includes(d.key)}
                                        disabled={ro}
                                        label={`${d.short} · ${d.label}`}
                                        onChange={on =>
                                            ed.update(x => {
                                                const set2 = new Set(asArray(x.departments));
                                                if (on) set2.add(d.key);
                                                else set2.delete(d.key);
                                                x.departments = depts.map(z => z.key).filter(k => set2.has(k));
                                            })
                                        }
                                    />
                                ))}
                            </div>
                        </Field>
                    </Card>
                    <Card title={t('builder.details.vehicle_group')} icon="car" padding="md">
                        <Toggle
                            checked={def.vehiclePenalties}
                            disabled={ro}
                            label={t('builder.details.vehicle_penalties')}
                            description={t('builder.details.vehicle_penalties_desc')}
                            onChange={v => set('vehiclePenalties', v)}
                        />
                        {suggest && def.vehiclePenalties ? (
                            <div className="builder_client-callout builder_client-callout--warning">
                                <Icon name="alert" size={15} />
                                <span>{t('builder.details.vehicle_suggest', { armed: totalArmed(def) })}</span>
                                {!ro ? (
                                    <Button size="sm" variant="ghost" onClick={() => set('vehiclePenalties', false)}>
                                        {t('builder.details.vehicle_suggest_apply')}
                                    </Button>
                                ) : null}
                            </div>
                        ) : null}
                    </Card>
                    <Card
                        title={t('builder.details.items')}
                        icon="inbox"
                        padding="md"
                        subtitle={t('builder.details.items_sub', { max: cfg.maxItems ?? 10 })}
                    >
                        <Items {...{ ed, cfg, def, ro }} />
                    </Card>
                </div>
            </Grid>
        </div>
    );
}

function Items({ ed, cfg, def, ro }: Pick<StepProps, 'ed' | 'cfg' | 'def' | 'ro'>) {
    const max = cfg.maxItems ?? 10;
    const [cmin, cmax] = cfg.itemCount ?? [1, 100];
    return (
        <div className="builder_client-items">
            {def.items.map((it, i) => {
                const err =
                    messageAt(ed.errors, `items.${i + 1}.name`, `items.${i + 1}.count`) ??
                    (it.name && forbiddenItem(it.name)
                        ? t('builder.details.item_forbidden', { name: it.name })
                        : undefined);
                return (
                    <div key={i} className="builder_client-item-row">
                        <Field label={i === 0 ? t('builder.details.item_name') : undefined} error={err}>
                            <TextInput
                                value={it.name}
                                disabled={ro}
                                maxLength={50}
                                placeholder={t('builder.details.item_placeholder')}
                                onChange={v =>
                                    ed.update(d => {
                                        d.items[i].name = v.replace(/[^\w.-]/g, '').slice(0, 50);
                                    })
                                }
                            />
                        </Field>
                        <Field label={i === 0 ? t('builder.details.item_count') : undefined}>
                            <NumberInput
                                value={it.count}
                                min={cmin}
                                max={cmax}
                                disabled={ro}
                                showRange={false}
                                onChange={v =>
                                    v !== null &&
                                    ed.update(d => {
                                        d.items[i].count = v;
                                    })
                                }
                            />
                        </Field>
                        {!ro ? (
                            <RemoveButton
                                label={t('builder.details.item_remove')}
                                onClick={() =>
                                    ed.update(d => {
                                        d.items.splice(i, 1);
                                    })
                                }
                            />
                        ) : null}
                    </div>
                );
            })}
            {!def.items.length ? <div className="builder_client-muted">{t('builder.details.items_none')}</div> : null}
            {!ro ? (
                <Button
                    size="sm"
                    variant="secondary"
                    icon="plus"
                    disabled={def.items.length >= max}
                    onClick={() =>
                        ed.update(d => {
                            d.items.push({ name: '', count: cmin });
                        })
                    }
                >
                    {t('builder.details.item_add')}
                </Button>
            ) : null}
            <div className="builder_client-hint">{t('builder.details.items_hint', { min: cmin, max: cmax })}</div>
        </div>
    );
}

function BonusList({
    kind,
    ed,
    cfg,
    def,
    ro,
}: Pick<StepProps, 'ed' | 'cfg' | 'def' | 'ro'> & { kind: 'bonuses' | 'penalties' }) {
    const penalty = kind === 'penalties';
    const options = asArray(cfg.bonuses).filter(b => b.penalty === penalty);
    const list = def[kind];
    const blocks = new Set(def.objectives.map(o => o.block));
    const capPts = cfg.bonusCap?.points ?? 50;
    const capPct = cfg.bonusCap?.pct ?? 25;
    const used = new Set(list.map(b => b.id));
    const label = (o: BuilderBonusOption) => tOr(o.labelKey, 'builder.bonus_fallback', { id: o.id });
    const free = options.filter(o => !used.has(o.id));
    const add = (id: string) => {
        const o = options.find(x => x.id === id);
        if (!o) return;
        const entry: BuilderBonusEntry =
            o.kind === 'pct'
                ? { id, pct: Math.min(capPct, Math.max(1, o.value)) }
                : { id, points: Math.max(-capPts, Math.min(capPts, o.value)) };
        ed.update(d => {
            d[kind].push(entry);
        });
    };
    return (
        <div className="builder_client-bonuses">
            <div className="builder_client-subtitle">
                {t(penalty ? 'builder.details.penalties_list' : 'builder.details.bonuses_list')}
            </div>
            {list.map((b, i) => {
                const o = options.find(x => x.id === b.id) ?? asArray(cfg.bonuses).find(x => x.id === b.id);
                const pct = o?.kind === 'pct';
                const needBlock = o?.block && !blocks.has(o.block);
                const err = messageAt(ed.errors, `${kind}.${i + 1}`, `${kind}.${i + 1}.points`, `${kind}.${i + 1}.pct`);
                return (
                    <div key={b.id} className="builder_client-bonus-row">
                        <div className="builder_client-bonus-row__label">
                            <span>{o ? label(o) : b.id}</span>
                            <span className="builder_client-bonus-row__tags">
                                <Badge size="sm" tone="neutral" variant="outline">
                                    {pct ? t('builder.details.kind_pct') : t('builder.details.kind_points')}
                                </Badge>
                                {o?.each ? (
                                    <Badge size="sm" tone="neutral" variant="outline">
                                        {t('builder.details.each')}
                                    </Badge>
                                ) : null}
                                {o?.block ? (
                                    <Badge size="sm" tone={needBlock ? 'danger' : 'grey'} variant="outline">
                                        {t(`builder.block.${o.block}`)}
                                    </Badge>
                                ) : null}
                            </span>
                            {err || needBlock ? (
                                <span className="builder_client-bonus-row__err">
                                    {err ?? t('builder.details.needs_block', { block: t(`builder.block.${o?.block}`) })}
                                </span>
                            ) : null}
                        </div>
                        <NumberInput
                            value={pct ? (b.pct ?? null) : (b.points ?? null)}
                            min={pct ? 1 : penalty ? -capPts : 1}
                            max={pct ? capPct : penalty ? -1 : capPts}
                            suffix={pct ? '%' : t('builder.unit.pts')}
                            showRange={false}
                            disabled={ro}
                            onChange={v =>
                                v !== null &&
                                ed.update(d => {
                                    const entry = d[kind][i];
                                    if (pct) entry.pct = v;
                                    else entry.points = v;
                                })
                            }
                        />
                        {!ro ? (
                            <RemoveButton
                                label={t('builder.details.bonus_remove')}
                                onClick={() =>
                                    ed.update(d => {
                                        d[kind].splice(i, 1);
                                    })
                                }
                            />
                        ) : null}
                    </div>
                );
            })}
            {!list.length ? (
                <div className="builder_client-muted">
                    {t(penalty ? 'builder.details.penalties_none' : 'builder.details.bonuses_none')}
                </div>
            ) : null}
            {!ro && free.length ? (
                <Select
                    value=""
                    onChange={add}
                    placeholder={t(penalty ? 'builder.details.penalty_add' : 'builder.details.bonus_add')}
                    options={free.map(o => ({
                        value: o.id,
                        label: `${label(o)} · ${o.kind === 'pct' ? `${o.value}%` : `${o.value > 0 ? '+' : ''}${o.value} ${t('builder.unit.pts')}`}${o.block && !blocks.has(o.block) ? ` · ${t('builder.details.needs_block', { block: t(`builder.block.${o.block}`) })}` : ''}`,
                        disabled: !!(o.block && !blocks.has(o.block)),
                    }))}
                />
            ) : null}
        </div>
    );
}
