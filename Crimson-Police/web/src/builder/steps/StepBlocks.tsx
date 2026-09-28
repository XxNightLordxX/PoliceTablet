// src/builder/steps/StepBlocks.tsx · "New mission": pick up to Config.Builder.maxBlocks objective blocks in the
// order officers will do them. Adding creates the objective with the block's config defaults; removing or
// moving one keeps the scaling paths and location keys consistent.
import { useState } from 'react';
import { Badge, Button, ConfirmDialog, Icon, IconButton } from '../../shared/components';
import { asArray } from '../../shared/data';
import { t } from '../../shared/i18n';
import { ErrorNotes } from '../controls';
import { errorsAt, remapScaling } from '../defUtils';
import { armedCount, BLOCK_ICONS, KEY_FIELDS, keyOf, newObjective, usedKeys } from '../schema';
import { StepIntro, type StepProps } from './common';

const ORDER = ['hostile_waves', 'interact_points', 'skill_check', 'protect_rescue', 'flee_arrest', 'search_area', 'pursuit', 'escort', 'checkpoint_route'];

export function StepBlocks({ ed, cfg, def, ro, goTo }: StepProps) {
  const [remove, setRemove] = useState<number | null>(null);
  const max = Number(cfg.maxBlocks) || 6;
  const blocks = asArray(cfg.blockList).slice().sort((a, b) => ORDER.indexOf(a.id) - ORDER.indexOf(b.id));
  const full = def.objectives.length >= max;

  const add = (block: string) => ed.update((d) => {
    if (d.objectives.length >= max) return;
    d.objectives.push(newObjective(cfg, d, block, d.objectives.length + 1, t(`builder.objective_default.${block}`)));
  });

  const move = (i: number, dir: -1 | 1) => ed.update((d) => {
    const j = i + dir;
    if (j < 0 || j >= d.objectives.length) return;
    const tmp = d.objectives[i];
    d.objectives[i] = d.objectives[j];
    d.objectives[j] = tmp;
    d.scaling = remapScaling(asArray(d.scaling), (old) => (old === i + 1 ? j + 1 : old === j + 1 ? i + 1 : old));
  });

  const doRemove = () => {
    if (remove === null) return;
    const i = remove;
    ed.update((d) => {
      const gone = d.objectives[i];
      d.objectives.splice(i, 1);
      d.scaling = remapScaling(asArray(d.scaling), (old) => (old === i + 1 ? null : old > i + 1 ? old - 1 : old));
      if (gone) {
        const used = usedKeys(d);
        const keys = (KEY_FIELDS[gone.block] ?? []).map((f) => keyOf(gone, f)).filter((k): k is string => typeof k === 'string' && !used.has(k));
        d.locations.forEach((l) => keys.forEach((k) => {
          delete l[k];
        }));
      }
    });
    setRemove(null);
  };

  return (
    <div className="builder_client-step">
      <StepIntro icon="layers" title={t('builder.blocks.title')} aside={<Badge tone={full ? 'warning' : 'neutral'} size="sm"><span className="cp-num">{t('builder.blocks.count', { n: def.objectives.length, max })}</span></Badge>}>
        {t('builder.blocks.intro', { max })}
      </StepIntro>
      <ErrorNotes errors={errorsAt(ed.errors, 'objectives')} />
      <div className="builder_client-blocks">
        <div className="builder_client-blocks__order">
          <div className="builder_client-subtitle">{t('builder.blocks.order')}</div>
          {def.objectives.length ? (
            <ol className="builder_client-order">
              {def.objectives.map((o, i) => {
                const armed = armedCount(o);
                return (
                  <li key={`${o.block}-${i}`} className="builder_client-order__item">
                    <span className="builder_client-order__num cp-num">{i + 1}</span>
                    <span className="builder_client-order__icon"><Icon name={BLOCK_ICONS[o.block] ?? 'target'} size={16} /></span>
                    <button type="button" className="builder_client-order__text" onClick={() => goTo('settings', { objective: i + 1 })}>
                      <span className="builder_client-order__label">{o.label || t(`builder.block.${o.block}`)}</span>
                      <span className="builder_client-order__block">{t(`builder.block.${o.block}`)}{armed ? ` · ${t('builder.blocks.armed', { n: armed })}` : ''}</span>
                    </button>
                    <ErrorCount n={ed.errors.filter((e) => e.path === `objectives.${i + 1}` || e.path.startsWith(`objectives.${i + 1}.`)).length} />
                    {!ro ? (
                      <span className="builder_client-order__actions">
                        <IconButton icon="chevronUp" size="sm" variant="ghost" label={t('builder.blocks.up')} disabled={i === 0} onClick={() => move(i, -1)} />
                        <IconButton icon="chevronDown" size="sm" variant="ghost" label={t('builder.blocks.down')} disabled={i === def.objectives.length - 1} onClick={() => move(i, 1)} />
                        <IconButton icon="trash" size="sm" variant="ghost" label={t('builder.blocks.remove')} onClick={() => setRemove(i)} />
                      </span>
                    ) : null}
                  </li>
                );
              })}
            </ol>
          ) : (
            <div className="builder_client-placeholder">
              <Icon name="layers" size={20} />
              <span>{t('builder.blocks.none')}</span>
            </div>
          )}
        </div>
        <div className="builder_client-blocks__palette">
          <div className="builder_client-subtitle">{t('builder.blocks.palette')}</div>
          <div className="builder_client-palette">
            {blocks.map((b) => (
              <div key={b.id} className={`builder_client-block-card${!b.available ? ' is-off' : ''}`}>
                <div className="builder_client-block-card__head">
                  <span className="builder_client-block-card__icon"><Icon name={BLOCK_ICONS[b.id] ?? 'target'} size={16} /></span>
                  <span className="builder_client-block-card__name">{t(b.labelKey)}</span>
                </div>
                <div className="builder_client-block-card__desc">{t(`builder.blockdesc.${b.id}`)}</div>
                <div className="builder_client-block-card__foot">
                  <span className="builder_client-muted cp-num">{t('builder.blocks.min_time', { s: b.minSeconds })}</span>
                  <Button size="sm" variant="secondary" icon="plus" disabled={ro || full || !b.available} onClick={() => add(b.id)}>
                    {b.available ? t('builder.blocks.add') : t('builder.blocks.unavailable')}
                  </Button>
                </div>
              </div>
            ))}
          </div>
        </div>
      </div>
      <ConfirmDialog
        open={remove !== null}
        title={t('builder.blocks.remove_title')}
        message={t('builder.blocks.remove_message', { label: remove !== null ? def.objectives[remove]?.label ?? '' : '' })}
        confirmLabel={t('builder.blocks.remove')}
        tone="danger"
        onConfirm={doRemove}
        onCancel={() => setRemove(null)}
      />
    </div>
  );
}

export function ErrorCount({ n }: { n: number }) {
  if (!n) return null;
  return <Badge size="sm" tone="danger" icon="alert"><span className="cp-num">{n}</span></Badge>;
}
