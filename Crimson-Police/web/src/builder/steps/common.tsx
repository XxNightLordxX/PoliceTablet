// src/builder/steps/common.tsx · props shared by the Mission Builder steps and small shared pieces.
import type { ReactNode } from 'react';
import { Icon, type IconName } from '../../shared/components';
import type { BuilderConfig, BuilderDefinition } from '../../types/builder_server';
import type { BuilderStepKey } from '../../types/builder_client';
import type { DraftEditor } from '../useDraftEditor';
import type { BuilderScope } from '../store';

export interface StepProps {
  ed: DraftEditor;
  cfg: BuilderConfig;
  def: BuilderDefinition;
  /** read-only (built-in, archived, locked by someone else, no permission) */
  ro: boolean;
  scope: BuilderScope;
  goTo: (step: BuilderStepKey, opts?: { objective?: number; location?: number }) => void;
}

/** Step intro line with an icon. */
export function StepIntro({ icon, title, children, aside }: { icon: IconName; title: ReactNode; children?: ReactNode; aside?: ReactNode }) {
  return (
    <div className="builder_client-intro">
      <span className="builder_client-intro__icon"><Icon name={icon} size={18} /></span>
      <div className="builder_client-intro__text">
        <div className="builder_client-intro__title">{title}</div>
        {children ? <div className="builder_client-intro__desc">{children}</div> : null}
      </div>
      {aside ? <div className="builder_client-intro__aside">{aside}</div> : null}
    </div>
  );
}
