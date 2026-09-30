// "Scaling": tick which counts scale with the tier (definition.scaling, entries 'objectives.<n>.<field>' or { path,
// max }); each block suggests a default.

import { Badge, Button, Card, Checkbox, EmptyState, Icon, NumberInput } from '../../shared/components';
import { asArray } from '../../shared/data';
import { t } from '../../shared/i18n';
import type { BuilderScalingEntry } from '../../types/builder_server';
import { ErrorNotes } from '../controls';
import { errorsUnder, getAt, scalingPath } from '../defUtils';
import { BLOCK_ICONS, scalables } from '../schema';
import { StepIntro, type StepProps } from './common';

function valueText(v: unknown): string {
    if (Array.isArray(v)) return v.join(' / ');
    if (typeof v === 'number') return String(v);
    return '—';
}

export function StepScaling({ ed, cfg, def, ro }: StepProps) {
    const entries = asArray(def.scaling);
    const find = (path: string) => entries.findIndex(e => scalingPath(e) === path);
    const maxEntries = cfg.maxScaling ?? 20;
    const all = def.objectives.flatMap((o, i) =>
        scalables(cfg, o).map(s => ({ ...s, index: i + 1, obj: o, path: `objectives.${i + 1}.${s.field}` })),
    );
    const toggle = (path: string, on: boolean, max: number) =>
        ed.update(d => {
            const list = asArray(d.scaling).filter(e => scalingPath(e) !== path);
            if (on) list.push({ path, max });
            d.scaling = list;
        });
    const setMax = (path: string, max: number | null) =>
        ed.update(d => {
            d.scaling = asArray(d.scaling).map((e): BuilderScalingEntry =>
                scalingPath(e) === path ? (max ? { path, max } : path) : e,
            );
        });
    const applySuggested = () =>
        ed.update(d => {
            const list = asArray(d.scaling).slice();
            all.filter(s => s.suggested).forEach(s => {
                if (!list.some(e => scalingPath(e) === s.path)) list.push({ path: s.path, max: s.max });
            });
            d.scaling = list.slice(0, maxEntries);
        });
    const unknown = entries.filter(e => !all.some(s => s.path === scalingPath(e)));
    return (
        <div className="builder_client-step">
            <StepIntro
                icon="barChart"
                title={t('builder.scale.title')}
                aside={
                    !ro && all.some(s => s.suggested && find(s.path) < 0) ? (
                        <Button size="sm" variant="secondary" icon="check" onClick={applySuggested}>
                            {t('builder.scale.use_suggested')}
                        </Button>
                    ) : undefined
                }
            >
                {t('builder.scale.intro')}
            </StepIntro>
            <ErrorNotes errors={errorsUnder(ed.errors, 'scaling')} />
            {!all.length ? (
                <EmptyState icon="barChart" title={t('builder.scale.none_title')} text={t('builder.scale.none_text')} />
            ) : (
                <div className="builder_client-scale-list">
                    {def.objectives.map((o, i) => {
                        const items = all.filter(s => s.index === i + 1);
                        if (!items.length) return null;
                        return (
                            <Card
                                key={i}
                                padding="sm"
                                title={
                                    <span className="builder_client-scale-title">
                                        <Icon name={BLOCK_ICONS[o.block] ?? 'target'} size={15} />
                                        {t('builder.scale.objective', {
                                            n: i + 1,
                                            label: o.label || t(`builder.block.${o.block}`),
                                        })}
                                    </span>
                                }
                            >
                                <div className="builder_client-scale-rows">
                                    {items.map(s => {
                                        const idx = find(s.path);
                                        const on = idx >= 0;
                                        const entry = on ? entries[idx] : null;
                                        const max = entry && typeof entry === 'object' ? entry.max : null;
                                        return (
                                            <div key={s.path} className="builder_client-scale-row">
                                                <Checkbox
                                                    checked={on}
                                                    disabled={ro || (!on && entries.length >= maxEntries)}
                                                    label={t(s.labelKey)}
                                                    onChange={v => toggle(s.path, v, s.max)}
                                                />
                                                {s.suggested ? (
                                                    <Badge size="sm" tone="accent" variant="outline" icon="star">
                                                        {t('builder.scale.suggested')}
                                                    </Badge>
                                                ) : null}
                                                <span className="builder_client-muted cp-num">
                                                    {t('builder.scale.base', {
                                                        value: valueText(getAt(s.obj, s.field)),
                                                    })}
                                                </span>
                                                <span className="cp-spacer" />
                                                {on ? (
                                                    <span className="builder_client-inline-field">
                                                        <span>{t('builder.scale.max')}</span>
                                                        <NumberInput
                                                            value={max}
                                                            min={1}
                                                            max={999}
                                                            showRange={false}
                                                            disabled={ro}
                                                            placeholder={t('builder.scale.no_max')}
                                                            onChange={v => setMax(s.path, v)}
                                                        />
                                                    </span>
                                                ) : null}
                                            </div>
                                        );
                                    })}
                                </div>
                            </Card>
                        );
                    })}
                </div>
            )}
            {unknown.length ? (
                <Card padding="sm" title={t('builder.scale.other')}>
                    <div className="builder_client-scale-rows">
                        {unknown.map(e => (
                            <div key={scalingPath(e)} className="builder_client-scale-row">
                                <span className="builder_client-mono">{scalingPath(e)}</span>
                                <span className="cp-spacer" />
                                {!ro ? (
                                    <Button
                                        size="sm"
                                        variant="ghost"
                                        icon="x"
                                        onClick={() =>
                                            ed.update(d => {
                                                d.scaling = asArray(d.scaling).filter(
                                                    x => scalingPath(x) !== scalingPath(e),
                                                );
                                            })
                                        }
                                    >
                                        {t('builder.scale.remove')}
                                    </Button>
                                ) : null}
                            </div>
                        ))}
                    </div>
                </Card>
            ) : null}
            <div className="builder_client-hint">{t('builder.scale.note', { max: maxEntries })}</div>
        </div>
    );
}
