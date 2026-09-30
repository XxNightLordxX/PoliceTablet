// The Mission Builder editor for one mission: header (name, lifecycle, version,

import { useEffect, useState, type ReactNode } from 'react';
import {
    Badge,
    Button,
    ConfirmDialog,
    ErrorState,
    Icon,
    IconButton,
    LoadingBlock,
    ProgressBar,
} from '../shared/components';
import { cx } from '../shared/cx';
import { formatDuration } from '../shared/format';
import { useAction, useCountdown } from '../shared/hooks';
import { t } from '../shared/i18n';
import { useCan, useSession } from '../shared/session';
import type { BuilderConfig, BuilderCreateResult } from '../types/builder_server';
import type { BuilderStepKey, BuilderUi } from '../types/builder_client';
import { StatusBadge } from './MissionList';
import { stepOfError } from './defUtils';
import { totalArmed } from './schema';
import { editorMemory, forgetDraft, setEditorMemory, type BuilderScope } from './store';
import { useDraftEditor, type DraftEditor } from './useDraftEditor';
import { StepBlocks } from './steps/StepBlocks';
import { StepDetails } from './steps/StepDetails';
import { StepLocations } from './steps/StepLocations';
import { StepPublish } from './steps/StepPublish';
import { StepScaling } from './steps/StepScaling';
import { StepSettings } from './steps/StepSettings';
import { StepTest } from './steps/StepTest';
import type { StepProps } from './steps/common';
import type { IconName } from '../shared/components';

export const STEPS: { key: BuilderStepKey; icon: IconName }[] = [
    { key: 'blocks', icon: 'layers' },
    { key: 'details', icon: 'fileText' },
    { key: 'settings', icon: 'tool' },
    { key: 'locations', icon: 'mapPin' },
    { key: 'scaling', icon: 'barChart' },
    { key: 'test', icon: 'flask' },
    { key: 'publish', icon: 'checkCircle' },
];

export interface BuilderEditorProps {
    id: string;
    scope: BuilderScope;
    config: BuilderConfig;
    onClose: () => void;
    onRenamed: (id: string) => void;
    // open another mission (after duplicating a read-only one)
    onOpen: (id: string) => void;
}

function LockBanner({ ed, onDuplicate, onBreak }: { ed: DraftEditor; onDuplicate: () => void; onBreak: () => void }) {
    const can = useCan();
    const rec = ed.record;
    const lock = rec?.lock ?? null;
    const other = lock && !lock.mine ? lock : null;
    const left = useCountdown(other ? other.secondsLeft : ed.lock?.mine ? ed.lock.secondsLeft : null, {
        resetKey: other?.citizenid ?? ed.lock?.secondsLeft,
    });
    if (!rec) return null;
    const reason = ed.readOnlyReason;
    if (!reason) {
        if (!ed.lock?.mine) return null;
        return (
            <div className="builder_client-lock is-mine">
                <Icon name="lock" size={15} />
                <span>{t('builder.lock.mine', { time: formatDuration(left ?? 0) })}</span>
            </div>
        );
    }
    let text = '';
    let tone = 'is-warning';
    let action: ReactNode = null;
    if (reason === 'builtin') {
        text = t('builder.lock.builtin');
        tone = 'is-info';
        if (can('builderEdit'))
            action = (
                <Button size="sm" variant="secondary" icon="swap" onClick={onDuplicate}>
                    {t('builder.lock.duplicate')}
                </Button>
            );
    } else if (reason === 'archived') {
        text = t('builder.lock.archived');
        tone = 'is-info';
    } else if (reason === 'permission') {
        text = t('builder.lock.permission');
        tone = 'is-info';
    } else if (reason === 'lost') {
        text = t('builder.lock.lost', { name: ed.lockLostBy ?? t('builder.someone') });
        tone = 'is-danger';
        action = (
            <Button
                size="sm"
                variant="secondary"
                icon="refresh"
                onClick={() => void ed.takeLock().then(() => ed.refresh())}
            >
                {t('builder.lock.retake')}
            </Button>
        );
    } else if (other) {
        text = t('builder.lock.other', {
            name: other.name ?? other.citizenid,
            time: formatDuration(left ?? other.secondsLeft),
        });
        if (rec.can.breakLock && can('breakEditLock'))
            action = (
                <Button size="sm" variant="danger" icon="key" onClick={onBreak}>
                    {t('builder.lock.break')}
                </Button>
            );
    } else {
        text = t('builder.lock.none');
        action = (
            <Button size="sm" variant="secondary" icon="lock" onClick={() => void ed.takeLock()}>
                {t('builder.lock.take')}
            </Button>
        );
    }
    return (
        <div className={cx('builder_client-lock', tone)} role="status">
            <Icon
                name={reason === 'builtin' || reason === 'archived' || reason === 'permission' ? 'eye' : 'lock'}
                size={15}
            />
            <span className="builder_client-lock__text">{text}</span>
            {action}
        </div>
    );
}

function ArmedMeter({ have, max }: { have: number; max: number }) {
    const tone = have > max ? 'danger' : have >= max * 0.8 ? 'warning' : 'success';
    return (
        <div className="builder_client-armed" title={t('builder.editor.armed_hint', { max })}>
            <div className="builder_client-armed__head">
                <span>{t('builder.editor.armed')}</span>
                <span className="cp-num">
                    <b>{have}</b> / {max}
                </span>
            </div>
            <ProgressBar value={Math.min(have, max)} max={max} tone={tone} size="sm" />
        </div>
    );
}

export function BuilderEditor({ id, scope, config, onClose, onRenamed, onOpen }: BuilderEditorProps) {
    const session = useSession();
    const ui: BuilderUi = session.ui === 'admin' ? 'admin' : 'supervisor';
    const [step, setStep] = useState<BuilderStepKey>(() => editorMemory(scope).step || 'blocks');
    const [confirmBreak, setConfirmBreak] = useState(false);
    const [closing, setClosing] = useState(false);
    const { run, busy } = useAction();
    const ed = useDraftEditor(id, scope, ui, config, onRenamed, onClose);

    useEffect(() => {
        setEditorMemory(scope, { step });
    }, [scope, step]);

    const goTo: StepProps['goTo'] = (s, opts) => {
        const patch: Record<string, number> = {};
        if (opts?.objective) patch.objective = opts.objective;
        if (opts?.location) patch.location = opts.location;
        setEditorMemory(scope, { step: s, ...patch });
        setStep(s);
    };

    const close = async () => {
        setClosing(true);
        if (!ed.readOnly && ed.dirty) {
            const ok = await ed.save();
            if (!ok) {
                setClosing(false);
                return;
            }
        }
        await ed.releaseLock();
        forgetDraft(id);
        setClosing(false);
        onClose();
    };

    const duplicate = async () => {
        const res = await run<BuilderCreateResult>(
            'server:builder:duplicate',
            { id },
            { success: 'builder.list.duplicated', successVars: { mission: ed.def?.label ?? id } },
        );
        if (res.ok && res.data) {
            setEditorMemory(scope, { openId: res.data.id, step: 'details' });
            onOpen(res.data.id);
        }
    };

    const breakLock = async () => {
        const res = await run(
            'server:builder:breakLock',
            { id },
            { success: 'builder.list.lock_broken', successVars: { mission: ed.def?.label ?? id } },
        );
        setConfirmBreak(false);
        if (res.ok) {
            await ed.refresh();
            await ed.takeLock();
        }
    };

    if (ed.error && !ed.def) {
        return (
            <div className="builder_client-editor">
                <div className="builder_client-editor__bar">
                    <Button variant="ghost" icon="chevronLeft" onClick={onClose}>
                        {t('builder.editor.back')}
                    </Button>
                </div>
                <ErrorState error={ed.error} onRetry={() => void ed.refresh()} />
            </div>
        );
    }
    if (!ed.def || !ed.record) return <LoadingBlock text={t('builder.editor.loading')} />;

    const def = ed.def;
    const rec = ed.record;
    const armed = totalArmed(def);
    const maxHostiles = Number(config.maxHostiles) || 40;
    const counts: Record<string, number> = {};
    ed.errors.forEach(e => {
        const s = stepOfError(e);
        counts[s] = (counts[s] ?? 0) + 1;
    });
    const done: Record<BuilderStepKey, boolean> = {
        blocks: def.objectives.length > 0,
        details: !!def.type && !!def.label.trim() && !counts.details,
        settings: def.objectives.length > 0 && !counts.settings,
        locations: def.locations.length >= (Number(config.minLocations) || 3) && !counts.locations,
        scaling: def.scaling.length > 0,
        test: !!rec.draftTested,
        publish: rec.dbStatus === 'published' && !rec.hasDraft,
    };
    const idx = STEPS.findIndex(s => s.key === step);
    const props: StepProps = { ed, cfg: config, def, ro: ed.readOnly, scope, goTo };
    const saveState = ed.readOnly
        ? t('builder.editor.read_only')
        : ed.saving
          ? t('builder.editor.saving')
          : ed.dirty
            ? t('builder.editor.unsaved', { s: config.autosaveSeconds ?? 30 })
            : ed.savedAt
              ? t('builder.editor.saved_at', {
                    time: new Date(ed.savedAt * 1000).toLocaleTimeString('en-GB', {
                        hour: '2-digit',
                        minute: '2-digit',
                        second: '2-digit',
                    }),
                })
              : t('builder.editor.up_to_date');

    return (
        <div className="builder_client-editor">
            <div className="builder_client-editor__bar">
                <IconButton
                    icon="chevronLeft"
                    label={t('builder.editor.back')}
                    variant="ghost"
                    onClick={() => void close()}
                    loading={closing}
                />
                <div className="builder_client-editor__titles">
                    <div className="builder_client-editor__title">
                        <span>{def.label || t('builder.editor.untitled')}</span>
                        <StatusBadge status={rec.status} />
                        {rec.version ? (
                            <Badge size="sm" tone="neutral" variant="outline">
                                <span className="cp-num">{t('builder.editor.live_v', { version: rec.version })}</span>
                            </Badge>
                        ) : null}
                        {rec.hasDraft || rec.dbStatus === 'draft' ? (
                            <Badge size="sm" tone="primary" variant="outline">
                                <span className="cp-num">
                                    {t('builder.list.draft_v', { version: rec.draftVersion ?? 1 })}
                                </span>
                            </Badge>
                        ) : null}
                        {rec.editedInCode ? (
                            <Badge size="sm" tone="warning" variant="outline" icon="fileText">
                                {t('builder.list.edited_in_code')}
                            </Badge>
                        ) : null}
                    </div>
                    <div className="builder_client-editor__sub">
                        <span className="builder_client-mono">{rec.id}</span>
                        <span aria-hidden>·</span>
                        <span className={cx('builder_client-save-state', ed.dirty && !ed.readOnly && 'is-dirty')}>
                            {ed.saving || ed.validating ? (
                                <Icon name="refresh" size={12} className="builder_client-spin" />
                            ) : (
                                <Icon name={ed.readOnly ? 'lock' : ed.dirty ? 'edit' : 'check'} size={12} />
                            )}
                            {saveState}
                        </span>
                        {ed.toolBusy ? (
                            <Badge size="sm" tone="accent" icon="radio">
                                {t('builder.editor.tool_running')}
                            </Badge>
                        ) : null}
                    </div>
                </div>
                <ArmedMeter have={armed} max={maxHostiles} />
                {!ed.readOnly ? (
                    <Button
                        icon="check"
                        variant={ed.dirty ? 'primary' : 'secondary'}
                        onClick={() => void ed.save()}
                        loading={ed.saving}
                    >
                        {t('builder.editor.save')}
                    </Button>
                ) : null}
            </div>
            <LockBanner ed={ed} onDuplicate={duplicate} onBreak={() => setConfirmBreak(true)} />
            <nav className="builder_client-steps" aria-label={t('builder.editor.steps')}>
                {STEPS.map((s, i) => (
                    <button
                        key={s.key}
                        type="button"
                        className={cx(
                            'builder_client-steps__item',
                            step === s.key && 'is-active',
                            done[s.key] && 'is-done',
                        )}
                        onClick={() => goTo(s.key)}
                        aria-current={step === s.key ? 'step' : undefined}
                    >
                        <span className="builder_client-steps__num cp-num">
                            {done[s.key] && step !== s.key ? <Icon name="check" size={12} strokeWidth={3} /> : i + 1}
                        </span>
                        <span className="builder_client-steps__label">{t(`builder.step.${s.key}`)}</span>
                        {counts[s.key] ? (
                            <span className="builder_client-steps__err cp-num">{counts[s.key]}</span>
                        ) : null}
                    </button>
                ))}
            </nav>
            <div className="builder_client-editor__body">
                {step === 'blocks' ? <StepBlocks {...props} /> : null}
                {step === 'details' ? <StepDetails {...props} /> : null}
                {step === 'settings' ? <StepSettings {...props} /> : null}
                {step === 'locations' ? <StepLocations {...props} /> : null}
                {step === 'scaling' ? <StepScaling {...props} /> : null}
                {step === 'test' ? <StepTest {...props} /> : null}
                {step === 'publish' ? <StepPublish {...props} /> : null}
            </div>
            <div className="builder_client-editor__foot">
                <Button variant="ghost" icon="chevronLeft" disabled={idx <= 0} onClick={() => goTo(STEPS[idx - 1].key)}>
                    {idx > 0 ? t(`builder.step.${STEPS[idx - 1].key}`) : t('builder.editor.back')}
                </Button>
                <span className="builder_client-muted cp-num">
                    {t('builder.editor.step_of', { n: idx + 1, total: STEPS.length })}
                </span>
                <Button
                    variant="secondary"
                    iconRight="chevronRight"
                    disabled={idx >= STEPS.length - 1}
                    onClick={() => goTo(STEPS[idx + 1].key)}
                >
                    {idx < STEPS.length - 1 ? t(`builder.step.${STEPS[idx + 1].key}`) : t('builder.step.publish')}
                </Button>
            </div>
            <ConfirmDialog
                open={confirmBreak}
                tone="danger"
                title={t('builder.confirm.break_lock.title', { mission: def.label })}
                message={t('builder.confirm.break_lock.message', {
                    mission: def.label,
                    name: rec.lock?.name ?? rec.lock?.citizenid ?? '',
                })}
                confirmLabel={t('builder.confirm.break_lock.button')}
                onConfirm={breakLock}
                onCancel={() => setConfirmBreak(false)}
                busy={busy}
            />
        </div>
    );
}
