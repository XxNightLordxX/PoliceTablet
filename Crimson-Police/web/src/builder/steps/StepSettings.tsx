// src/builder/steps/StepSettings.tsx · "Block settings": one panel per objective (BlockPanels.tsx) with its
// guardrail messages (block validate reasons arrive as text on objectives.<n>).
import { useEffect, useState } from 'react';
import { Button, EmptyState, Icon } from '../../shared/components';
import { cx } from '../../shared/cx';
import { t } from '../../shared/i18n';
import { BlockPanel } from '../BlockPanels';
import { ErrorNotes } from '../controls';
import { errorsAt, errorsUnder, setAt } from '../defUtils';
import { armedCount, BLOCK_ICONS } from '../schema';
import { editorMemory, setEditorMemory } from '../store';
import { ErrorCount } from './StepBlocks';
import { StepIntro, type StepProps } from './common';

export function StepSettings({ ed, cfg, def, ro, scope, goTo }: StepProps) {
  const [sel, setSel] = useState(() => Math.min(Math.max(1, editorMemory(scope).objective || 1), Math.max(1, def.objectives.length)));
  useEffect(() => {
    if (sel > def.objectives.length && def.objectives.length) setSel(def.objectives.length);
  }, [def.objectives.length, sel]);
  const pick = (n: number) => {
    setSel(n);
    setEditorMemory(scope, { objective: n });
  };
  if (!def.objectives.length) {
    return (
      <div className="builder_client-step">
        <EmptyState icon="layers" title={t('builder.settings.none_title')} text={t('builder.settings.none_text')}
          action={<Button icon="plus" onClick={() => goTo('blocks')}>{t('builder.settings.go_blocks')}</Button>} />
      </div>
    );
  }
  const obj = def.objectives[sel - 1];
  const i = sel;
  const own = errorsAt(ed.errors, `objectives.${i}`);
  return (
    <div className="builder_client-step">
      <StepIntro icon="tool" title={t('builder.settings.title')}>{t('builder.settings.intro')}</StepIntro>
      <div className="builder_client-split">
        <nav className="builder_client-side" aria-label={t('builder.settings.objectives')}>
          {def.objectives.map((o, k) => {
            const n = errorsUnder(ed.errors, `objectives.${k + 1}`).length;
            const armed = armedCount(o);
            return (
              <button key={k} type="button" className={cx('builder_client-side__item', sel === k + 1 && 'is-active')} onClick={() => pick(k + 1)}>
                <span className="builder_client-side__num cp-num">{k + 1}</span>
                <Icon name={BLOCK_ICONS[o.block] ?? 'target'} size={15} />
                <span className="builder_client-side__text">
                  <span className="builder_client-side__label">{o.label || t(`builder.block.${o.block}`)}</span>
                  <span className="builder_client-side__sub">{t(`builder.block.${o.block}`)}{armed ? ` · ${t('builder.blocks.armed', { n: armed })}` : ''}</span>
                </span>
                <ErrorCount n={n} />
              </button>
            );
          })}
        </nav>
        <div className="builder_client-split__main">
          <div className="builder_client-panel-head">
            <span className="builder_client-panel-head__icon"><Icon name={BLOCK_ICONS[obj.block] ?? 'target'} size={18} /></span>
            <div>
              <div className="builder_client-panel-head__title">{t('builder.settings.objective_n', { n: i, block: t(`builder.block.${obj.block}`) })}</div>
              <div className="builder_client-panel-head__desc">{t(`builder.blockdesc.${obj.block}`)}</div>
            </div>
          </div>
          <ErrorNotes errors={own} />
          <BlockPanel
            cfg={cfg}
            def={def}
            obj={obj}
            index={i}
            ro={ro}
            errors={ed.errors}
            set={(path, value) => ed.update((d) => setAt(d.objectives[i - 1] as unknown as Record<string, unknown>, path, value))}
            patch={(fn) => ed.update((d) => fn(d.objectives[i - 1], d))}
          />
          <div className="builder_client-panel-foot">
            <Button variant="ghost" icon="chevronLeft" disabled={i <= 1} onClick={() => pick(i - 1)}>{t('builder.settings.prev')}</Button>
            <Button variant="ghost" iconRight="chevronRight" disabled={i >= def.objectives.length} onClick={() => pick(i + 1)}>{t('builder.settings.next')}</Button>
          </div>
        </div>
      </div>
    </div>
  );
}
