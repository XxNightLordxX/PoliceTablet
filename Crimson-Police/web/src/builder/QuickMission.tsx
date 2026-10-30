// The New mission wizard (Config.Builder.quickWizard): What, Where, Check, Publish. Step 1 (QuickMissionStart)
// creates the draft from a template card or from scratch; steps 2 to 4 (QuickMission) run inside BuilderEditor on the
// same draft and the same server actions as the full editor, which "Open the full editor" opens at any step.

import { useEffect, useMemo, useRef, useState } from 'react';
import { Badge, Button, Field, Icon, TextInput, type IconName } from '../shared/components';
import { cx } from '../shared/cx';
import { asArray } from '../shared/data';
import { useAction } from '../shared/hooks';
import { t } from '../shared/i18n';
import type { BuilderConfig, BuilderCreateResult, BuilderValidateResult } from '../types/builder_server';
import type { BuilderHereReply } from '../types/builder_client';
import { missionPointSpecs } from './schema';
import {
    FULL_STEP,
    QUICK_STEPS,
    checkGroups,
    fillPlan,
    keepsBaseName,
    missingPoints,
    wizardName,
    workLocation,
    type QuickStep,
} from './quickMission';
import type { QuickMemory } from './store';
import { startSpec } from './useDraftEditor';
import { StepIntro, type StepProps } from './steps/common';
import { StepPublish } from './steps/StepPublish';
import { StepTest } from './steps/StepTest';

const TYPE_ICON: Record<string, IconName> = {
    patrol: 'navigation',
    tactical: 'target',
    investigation: 'search',
    training: 'flask',
};

// The four steps as the editor's step bar draws them, with "Open the full editor" beside them.
function QuickSteps({ step, onFull }: { step: QuickStep; onFull: () => void }) {
    const idx = QUICK_STEPS.indexOf(step);
    return (
        <div className="builder_client-quick__head">
            <nav className="builder_client-steps" aria-label={t('builder.quick.title')}>
                {QUICK_STEPS.map((s, i) => (
                    <span
                        key={s}
                        className={cx('builder_client-steps__item', s === step && 'is-active', i < idx && 'is-done')}
                        aria-current={s === step ? 'step' : undefined}
                    >
                        <span className="builder_client-steps__num cp-num">
                            {i < idx ? <Icon name="check" size={12} strokeWidth={3} /> : i + 1}
                        </span>
                        <span className="builder_client-steps__label">{t(`builder.quick.step.${s}`)}</span>
                    </span>
                ))}
            </nav>
            <Button variant="ghost" size="sm" icon="edit" onClick={onFull}>
                {t('builder.quick.full_editor')}
            </Button>
        </div>
    );
}

// ============================================================================
//                                STEP 1 · WHAT
// ============================================================================

export interface QuickMissionStartProps {
    config: BuilderConfig;
    // the draft was created: its id and the name it was created with
    onCreated: (id: string, base: string) => void;
    onCancel: () => void;
    // the "New mission" dialog and the full editor instead
    onFullEditor: () => void;
}

export function QuickMissionStart({ config, onCreated, onCancel, onFullEditor }: QuickMissionStartProps) {
    const { run, busy } = useAction();
    const [scratch, setScratch] = useState(false);
    const templates = asArray(config.templates);
    const types = asArray(config.missionTypes);
    const typeLabel = (k: string) => types.find(m => m.key === k)?.label ?? k;
    const create = async (payload: { template: string } | { type: string }, fallback: string) => {
        const res = await run<BuilderCreateResult>('server:builder:create', payload, {
            success: 'builder.list.created',
        });
        if (res.ok && res.data)
            onCreated(res.data.id, res.data.record?.definition?.label || res.data.record?.label || fallback);
    };
    return (
        <div className="builder_client-editor builder_client-quick">
            <div className="builder_client-editor__bar">
                <Button variant="ghost" icon="chevronLeft" onClick={onCancel} disabled={busy}>
                    {t('builder.quick.cancel')}
                </Button>
                <div className="builder_client-editor__titles">
                    <div className="builder_client-editor__title">
                        <span>{t('builder.quick.title')}</span>
                    </div>
                </div>
            </div>
            <QuickSteps step="what" onFull={onFullEditor} />
            <div className="builder_client-editor__body">
                <div className="builder_client-step">
                    <StepIntro icon="layers" title={t('builder.quick.what_title')}>
                        {t('builder.quick.what_intro')}
                    </StepIntro>
                    {!templates.length ? (
                        <div className="builder_client-inline-note">{t('builder.quick.no_templates')}</div>
                    ) : null}
                    <div className="builder_client-palette">
                        {templates.map(tp => (
                            <div key={tp.id} className="builder_client-block-card">
                                <div className="builder_client-block-card__head">
                                    <span className="builder_client-block-card__icon">
                                        <Icon name={TYPE_ICON[tp.type] ?? 'target'} size={16} />
                                    </span>
                                    <span className="builder_client-block-card__name">{tp.label}</span>
                                </div>
                                <div className="builder_client-block-card__desc">{tp.blurb}</div>
                                <div className="builder_client-block-card__foot">
                                    <span className="builder_client-muted">{typeLabel(tp.type)}</span>
                                    <Button
                                        size="sm"
                                        variant="primary"
                                        iconRight="chevronRight"
                                        disabled={busy}
                                        onClick={() => void create({ template: tp.id }, tp.label)}
                                    >
                                        {t('builder.quick.use')}
                                    </Button>
                                </div>
                            </div>
                        ))}
                        <div className="builder_client-block-card">
                            <div className="builder_client-block-card__head">
                                <span className="builder_client-block-card__icon">
                                    <Icon name="plus" size={16} />
                                </span>
                                <span className="builder_client-block-card__name">{t('builder.quick.scratch')}</span>
                            </div>
                            <div className="builder_client-block-card__desc">{t('builder.quick.scratch_desc')}</div>
                            {scratch ? (
                                <div className="builder_client-quick__types">
                                    <span className="builder_client-muted">{t('builder.quick.scratch_type')}</span>
                                    {types.map(m => (
                                        <Button
                                            key={m.key}
                                            size="sm"
                                            variant="secondary"
                                            icon={TYPE_ICON[m.key] ?? 'target'}
                                            disabled={busy}
                                            onClick={() => void create({ type: m.key }, m.label)}
                                        >
                                            {m.label}
                                        </Button>
                                    ))}
                                </div>
                            ) : (
                                <div className="builder_client-block-card__foot">
                                    <span />
                                    <Button size="sm" variant="secondary" icon="plus" onClick={() => setScratch(true)}>
                                        {t('builder.quick.scratch')}
                                    </Button>
                                </div>
                            )}
                        </div>
                    </div>
                </div>
            </div>
        </div>
    );
}

// ============================================================================
//                     STEPS 2 TO 4 · WHERE, CHECK, PUBLISH
// ============================================================================

export interface QuickMissionProps extends StepProps {
    quick: QuickMemory;
    setQuick: (q: QuickMemory) => void;
    // leave the wizard for the full editor at that step (the same draft and lock)
    onFull: StepProps['goTo'];
}

export function QuickMission(props: QuickMissionProps) {
    const { quick, setQuick, onFull } = props;
    const step = quick.step;
    const idx = QUICK_STEPS.indexOf(step);
    const go = (s: QuickStep) => {
        if (s !== 'what') setQuick({ ...quick, step: s });
    };
    // the wizard's own steps: the full editor's Fix and Test links leave the wizard
    const inner: StepProps = { ...props, goTo: onFull };
    return (
        <>
            <QuickSteps step={step} onFull={() => onFull(FULL_STEP[step])} />
            <div className="builder_client-editor__body">
                {step === 'where' ? <QuickWhere {...props} /> : null}
                {step === 'check' ? <QuickCheck {...props} /> : null}
                {step === 'publish' ? <StepPublish {...inner} /> : null}
            </div>
            <div className="builder_client-editor__foot">
                <Button variant="ghost" icon="chevronLeft" disabled={idx <= 1} onClick={() => go(QUICK_STEPS[idx - 1])}>
                    {idx > 1 ? t(`builder.quick.step.${QUICK_STEPS[idx - 1]}`) : t('builder.quick.back')}
                </Button>
                <span className="builder_client-muted cp-num">
                    {t('builder.quick.step_of', { n: idx + 1, total: QUICK_STEPS.length })}
                </span>
                <Button
                    variant="primary"
                    iconRight="chevronRight"
                    disabled={idx >= QUICK_STEPS.length - 1}
                    onClick={() => go(QUICK_STEPS[idx + 1])}
                >
                    {idx < QUICK_STEPS.length - 1
                        ? t(`builder.quick.step.${QUICK_STEPS[idx + 1]}`)
                        : t('builder.quick.next')}
                </Button>
            </div>
        </>
    );
}

// Step 2: the start where the builder stands, the spawn points filled around it, another location the same way.
function QuickWhere({ ed, cfg, def, ro, quick }: QuickMissionProps) {
    const specs = useMemo(() => missionPointSpecs(cfg, def), [cfg, def]);
    const [li, setLi] = useState(() => workLocation(def.locations));
    const [filling, setFilling] = useState(false);
    const [filled, setFilled] = useState<{ li: number; n: number } | null>(null);
    const [street, setStreet] = useState<Record<number, string>>({});
    // the last name the wizard proposed: still replaced when the start moves (a typed name never is)
    const proposed = useRef<string | null>(null);
    const n = Math.min(li, Math.max(1, def.locations.length));
    const loc = def.locations[n - 1];
    const busy = ro || ed.toolBusy || filling;
    const here = cfg.useMyPosition !== false;
    const fill = cfg.autoFill !== false ? fillPlan(specs, loc) : [];
    const fillCount = fill.reduce((s, f) => s + f.count, 0);
    const missing = missingPoints(specs, loc);
    const maxLoc = Number(cfg.maxLocations) || 20;
    const maxLabel = cfg.limits?.label ?? 64;

    // the start names its street: the first location's names the mission while it keeps the name it was created with
    const named = (at: number) => (reply: BuilderHereReply) => {
        const s = typeof reply.street === 'string' ? reply.street : '';
        setStreet(m => ({ ...m, [at]: s }));
        if (at !== 1) return;
        const name = wizardName(quick.base, s, maxLabel);
        ed.update(d => {
            if (keepsBaseName(d.label, quick.base) || d.label === proposed.current) d.label = name;
        });
        proposed.current = name;
    };
    const setStart = () => void ed.here(startSpec(), n, undefined, named(n));
    const fillAll = async () => {
        setFilling(true);
        setFilled(null);
        let got = 0;
        try {
            for (const task of fill) {
                const reply = await ed.autoFill(task.spec, n, task.count);
                if (!reply || !reply.result) continue;
                if (await ed.keepFill(task.spec, reply.result)) got += reply.proposed.length;
            }
        } finally {
            setFilling(false);
        }
        if (got) setFilled({ li: n, n: got });
    };
    const addHere = async () => {
        const at = def.locations.length + 1;
        ed.update(d => {
            d.locations.push({ label: t('builder.location_default', { n: at }) });
        });
        setLi(at);
        setFilled(null);
        if (!(await ed.here(startSpec(), at, undefined, named(at)))) {
            // no start where the builder stands: the empty location goes again
            ed.update(d => {
                if (d.locations.length === at && !d.locations[at - 1].start) d.locations.splice(at - 1, 1);
            });
            setLi(Math.max(1, at - 1));
        }
    };

    return (
        <div className="builder_client-step">
            <StepIntro
                icon="mapPin"
                title={t('builder.quick.where_title')}
                aside={
                    <Badge size="sm" tone="neutral">
                        <span className="cp-num">{t('builder.location_default', { n })}</span>
                    </Badge>
                }
            >
                {t('builder.quick.where_intro')}
            </StepIntro>
            {def.locations.length > 1 ? (
                <div className="builder_client-quick__types">
                    {def.locations.map((l, i) => (
                        <Button
                            key={i}
                            size="sm"
                            variant={i + 1 === n ? 'primary' : 'ghost'}
                            icon={l.start ? 'checkCircle' : 'mapPin'}
                            onClick={() => setLi(i + 1)}
                        >
                            {l.label || t('builder.location_default', { n: i + 1 })}
                        </Button>
                    ))}
                </div>
            ) : null}
            <div className="builder_client-quick__row">
                <span className={cx('builder_client-quick__state', loc?.start ? 'is-ok' : 'is-bad')}>
                    <Icon name={loc?.start ? 'checkCircle' : 'flag'} size={16} />
                    {loc?.start
                        ? street[n]
                            ? t('builder.quick.start_at', { street: street[n] })
                            : t('builder.quick.start_placed')
                        : t('builder.quick.no_start')}
                </span>
                {!ro ? (
                    here ? (
                        <Button
                            variant={loc?.start ? 'secondary' : 'primary'}
                            icon="user"
                            disabled={busy}
                            onClick={setStart}
                        >
                            {loc?.start ? t('builder.quick.here_again') : t('builder.quick.here')}
                        </Button>
                    ) : (
                        <Button
                            variant={loc?.start ? 'secondary' : 'primary'}
                            icon="mapPin"
                            disabled={busy}
                            onClick={() => void ed.place(startSpec(), n)}
                        >
                            {t('builder.quick.place_start')}
                        </Button>
                    )
                ) : null}
            </div>
            {cfg.autoFill !== false && !ro ? (
                <div className="builder_client-quick__row">
                    <span className="builder_client-muted">
                        {filled && filled.li === n
                            ? t('builder.quick.filled', { n: filled.n })
                            : loc?.start
                              ? null
                              : t('builder.quick.need_start')}
                    </span>
                    <Button
                        variant="primary"
                        icon="zap"
                        disabled={busy || !fillCount}
                        loading={filling}
                        onClick={() => void fillAll()}
                    >
                        {t('builder.quick.fill', { n: fillCount })}
                    </Button>
                </div>
            ) : null}
            <div className="builder_client-subtitle">{t('builder.quick.missing')}</div>
            {!missing.length && loc?.start ? (
                <div className="builder_client-inline-note is-ok">
                    <Icon name="checkCircle" size={15} />
                    <span>{t('builder.quick.all_placed')}</span>
                </div>
            ) : (
                <ul className="builder_client-quick__list">
                    {missing.map(m => {
                        const s = m.spec;
                        const needStart = s.spawn && !loc?.start;
                        return (
                            <li key={s.key} className="builder_client-quick__row">
                                <span>
                                    {t('builder.quick.points', { label: t(s.labelKey), have: m.have, need: m.need })}
                                </span>
                                {!ro ? (
                                    <span className="builder_client-actions-row">
                                        {s.kind === 'route' ? (
                                            <>
                                                {s.placeable ? (
                                                    <Button
                                                        size="sm"
                                                        icon="mapPin"
                                                        disabled={busy}
                                                        onClick={() =>
                                                            void ed.place(
                                                                {
                                                                    ...s,
                                                                    kind: 'marker',
                                                                    multiple: true,
                                                                    heading: false,
                                                                },
                                                                n,
                                                            )
                                                        }
                                                    >
                                                        {t('builder.loc.place_points')}
                                                    </Button>
                                                ) : null}
                                                <Button
                                                    size="sm"
                                                    icon="radio"
                                                    disabled={busy}
                                                    onClick={() => void ed.recordRoute(s, n)}
                                                >
                                                    {t('builder.loc.record')}
                                                </Button>
                                            </>
                                        ) : (
                                            <>
                                                {here && !s.lists ? (
                                                    <Button
                                                        size="sm"
                                                        variant="secondary"
                                                        icon="user"
                                                        disabled={busy || needStart}
                                                        onClick={() => void ed.here(s, n)}
                                                    >
                                                        {s.multiple
                                                            ? t('builder.loc.add_here')
                                                            : t('builder.loc.set_here')}
                                                    </Button>
                                                ) : null}
                                                <Button
                                                    size="sm"
                                                    icon="mapPin"
                                                    disabled={busy || needStart}
                                                    onClick={() => void ed.place(s, n)}
                                                >
                                                    {t('builder.loc.place')}
                                                </Button>
                                            </>
                                        )}
                                    </span>
                                ) : null}
                            </li>
                        );
                    })}
                </ul>
            )}
            {!ro && here ? (
                <div className="builder_client-quick__row">
                    <span />
                    <Button
                        variant="ghost"
                        icon="plus"
                        disabled={busy || !loc?.start || def.locations.length >= maxLoc}
                        onClick={() => void addHere()}
                    >
                        {t('builder.quick.add_location')}
                    </Button>
                </div>
            ) : null}
            <Field label={t('builder.quick.name')} hint={t('builder.quick.name_hint')}>
                <TextInput
                    value={def.label}
                    onChange={v => ed.update(d => void (d.label = v.slice(0, maxLabel)))}
                    maxLength={maxLabel}
                    disabled={ro}
                />
            </Field>
        </div>
    );
}

// Step 3: today's validation list in plain words, a Fix button per step, and an optional test.
function QuickCheck(props: QuickMissionProps) {
    const { ed, def, onFull } = props;
    const [check, setCheck] = useState<BuilderValidateResult | null>(null);
    const [testing, setTesting] = useState(false);
    useEffect(() => {
        let alive = true;
        void ed.validateNow().then(r => {
            if (alive) setCheck(r);
        });
        return () => {
            alive = false;
        };
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [def]);
    const groups = checkGroups(check ? asArray(check.errors) : ed.errors);
    return (
        <div className="builder_client-step">
            <StepIntro icon="list" title={t('builder.quick.check_title')}>
                {t('builder.quick.check_intro')}
            </StepIntro>
            {!check && ed.validating ? (
                <div className="builder_client-inline-note">{t('builder.quick.checking')}</div>
            ) : !groups.length ? (
                <div className="builder_client-inline-note is-ok">
                    <Icon name="checkCircle" size={15} />
                    <span>{t('builder.quick.check_ok')}</span>
                </div>
            ) : (
                <div className="builder_client-problems">
                    {groups.map(g => (
                        <div key={g.step} className="builder_client-problems__group">
                            <div className="builder_client-problems__head">
                                <span>{t(`builder.step.${g.step}`)}</span>
                                <Button
                                    size="sm"
                                    variant="secondary"
                                    iconRight="chevronRight"
                                    onClick={() => onFull(g.step, { objective: g.objective, location: g.location })}
                                >
                                    {t('builder.quick.fix')}
                                </Button>
                            </div>
                            <ul>
                                {g.messages.map((m, i) => (
                                    <li key={i}>{m}</li>
                                ))}
                            </ul>
                        </div>
                    ))}
                </div>
            )}
            <div className="builder_client-quick__row">
                <span className="builder_client-muted">{t('builder.quick.test_hint')}</span>
                <Button variant="secondary" icon="flask" onClick={() => setTesting(v => !v)}>
                    {testing ? t('builder.quick.test_hide') : t('builder.quick.test')}
                </Button>
            </div>
            {testing ? <StepTest {...props} goTo={onFull} /> : null}
        </div>
    );
}
