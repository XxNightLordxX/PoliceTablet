// "Test": a private test run of the stored draft at any tier and location, in

import { useEffect, useRef, useState } from 'react';
import { Badge, Button, Card, Field, Grid, Icon, Select, Textarea, TierBadge, Toggle } from '../../shared/components';
import { asArray } from '../../shared/data';
import { formatDateTime } from '../../shared/format';
import { useAction } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { useTablet } from '../../shared/session';
import { toast } from '../../shared/toast';
import type { BuilderTestResult } from '../../types/builder_server';
import { lastTest, setLastTest } from '../store';
import { requiredTierFor } from '../schema';
import { StepIntro, type StepProps } from './common';

export function StepTest({ ed, cfg, def, ro }: StepProps) {
    const { run, busy } = useAction();
    const tablet = useTablet();
    const tiers = asArray(cfg.tiers);
    // the draft on screen decides (the record's requiredTier is the stored draft's, stale until the next load)
    const required = requiredTierFor(cfg, def.maxOfficers) || ed.record?.requiredTier || 'standard';
    const [tier, setTierState] = useState<string>(required);
    const picked = useRef(false);
    const setTier = (v: string) => {
        picked.current = true;
        setTierState(v);
    };
    // the default follows maxOfficers until the builder picks a tier
    useEffect(() => {
        if (!picked.current) setTierState(required);
    }, [required]);
    const [location, setLocation] = useState<string>('1');
    const [route, setRoute] = useState<boolean>(!!cfg.useStartRoute);
    const [note, setNote] = useState('');
    const [recLocation, setRecLocation] = useState<string>('');
    const memo = lastTest(ed.id);
    const tested = !!ed.record?.draftTested;
    const tierIdx = (n: string) => tiers.findIndex(x => x.name === n);
    const belowRequired = tierIdx(tier) < tierIdx(required);
    const blocking = ed.errors.length;

    const start = async () => {
        // the test runs the STORED draft: store what is on screen first
        if (ed.dirty && !(await ed.flush())) {
            toast('error', t('builder.test.not_stored'));
            return;
        }
        const loc = location === 'random' ? 'random' : Number(location);
        const res = await run<BuilderTestResult>('server:builder:test', {
            id: ed.id,
            tier,
            location: loc,
            useStartRoute: route,
        });
        if (!res.ok || !res.data) return;
        setLastTest(ed.id, {
            missionId: ed.id,
            version: res.data.version,
            tier: res.data.tier,
            location: res.data.location,
            useStartRoute: route,
            startedAt: Math.floor(Date.now() / 1000),
        });
        toast('success', t('builder.test.started', { tier: t(`tier.${res.data.tier}`) }));
        setTimeout(() => tablet.close(), 900);
    };

    const record = async (result: 'passed' | 'failed') => {
        if (!memo) return;
        const loc = memo.location === 'random' ? Number(recLocation) : memo.location;
        if (!Number.isInteger(loc) || loc < 1) return;
        const res = await run(
            'server:test:record',
            { missionId: ed.id, location: loc, tier: memo.tier, result, note: note.trim() || undefined },
            { success: result === 'passed' ? 'builder.test.recorded_passed' : 'builder.test.recorded_failed' },
        );
        if (res.ok) {
            setLastTest(ed.id, { ...memo, recorded: result });
            setNote('');
            void ed.refresh();
        }
    };

    const locOptions = [
        ...def.locations.map((l, i) => ({
            value: String(i + 1),
            label: `${i + 1} · ${l.label || t('builder.location_default', { n: i + 1 })}`,
        })),
        { value: 'random', label: t('builder.test.random') },
    ];

    return (
        <div className="builder_client-step">
            <StepIntro
                icon="flask"
                title={t('builder.test.title')}
                aside={
                    tested ? (
                        <Badge tone="success" icon="checkCircle">
                            {t('builder.test.draft_tested')}
                        </Badge>
                    ) : (
                        <Badge
                            tone={cfg.requireTestToPublish ? 'warning' : 'neutral'}
                            icon={cfg.requireTestToPublish ? 'alert' : 'info'}
                        >
                            {t(
                                cfg.requireTestToPublish
                                    ? 'builder.test.not_tested'
                                    : 'builder.test.not_tested_optional',
                            )}
                        </Badge>
                    )
                }
            >
                {t('builder.test.intro')}
            </StepIntro>
            <Grid cols="3fr 2fr" gap={4} align="start">
                <Card title={t('builder.test.run')} icon="play" padding="md">
                    <div className="builder_client-form">
                        <Field
                            label={t('builder.test.tier')}
                            hint={t('builder.test.tier_hint', { tier: t(`tier.${required}`), max: def.maxOfficers })}
                        >
                            <Select
                                value={tier}
                                onChange={setTier}
                                disabled={ro}
                                options={tiers.map(x => ({
                                    value: x.name,
                                    label: `${t(x.labelKey)}${x.name === required ? ` · ${t('builder.test.required')}` : ''}`,
                                }))}
                            />
                        </Field>
                        {belowRequired ? (
                            <div className="builder_client-callout builder_client-callout--warning">
                                <Icon name="alert" size={15} />
                                <span>{t('builder.test.below_required', { tier: t(`tier.${required}`) })}</span>
                            </div>
                        ) : null}
                        <Grid cols={2} gap={3}>
                            <Field label={t('builder.test.location')}>
                                <Select
                                    value={location}
                                    onChange={setLocation}
                                    options={locOptions}
                                    disabled={ro || !def.locations.length}
                                />
                            </Field>
                            <Field label={t('builder.test.start_route')}>
                                <Toggle
                                    checked={route}
                                    onChange={setRoute}
                                    disabled={ro}
                                    label={route ? t('builder.on') : t('builder.off')}
                                    description={t('builder.test.start_route_desc')}
                                />
                            </Field>
                        </Grid>
                        {blocking ? (
                            <div className="builder_client-callout builder_client-callout--warning">
                                <Icon name="alert" size={15} />
                                <span>{t('builder.test.has_errors', { n: blocking })}</span>
                            </div>
                        ) : null}
                        <div className="builder_client-actions-row">
                            <span className="builder_client-muted">{t('builder.test.nothing_saved')}</span>
                            <span className="cp-spacer" />
                            <Button
                                variant="primary"
                                icon="play"
                                onClick={start}
                                loading={busy}
                                disabled={ro || !def.locations.length}
                            >
                                {t('builder.test.start')}
                            </Button>
                        </div>
                    </div>
                </Card>
                <div className="builder_client-col">
                    <Card title={t('builder.test.state')} icon="shieldCheck" padding="md">
                        <div className="builder_client-state">
                            <div className="builder_client-state__row">
                                <span>{t('builder.test.required_tier')}</span>
                                <TierBadge tier={required} size="sm" />
                            </div>
                            <div className="builder_client-state__row">
                                <span>{t('builder.test.draft_version')}</span>
                                <span className="cp-num">
                                    {t('builder.version_short', {
                                        version: ed.record?.draftVersion ?? ed.record?.version ?? 1,
                                    })}
                                </span>
                            </div>
                            <div className="builder_client-state__row">
                                <span>{t('builder.test.status')}</span>
                                {tested ? (
                                    <Badge size="sm" tone="success" icon="check">
                                        {t('builder.test.passed_required')}
                                    </Badge>
                                ) : (
                                    <Badge size="sm" tone="neutral">
                                        {t('builder.test.needs_pass')}
                                    </Badge>
                                )}
                            </div>
                            <p className="builder_client-hint">{t('builder.test.reset_note')}</p>
                        </div>
                    </Card>
                    {memo && !memo.recorded ? (
                        <Card
                            title={t('builder.test.record')}
                            icon="edit"
                            padding="md"
                            highlight="accent"
                            subtitle={t('builder.test.record_sub', {
                                tier: t(`tier.${memo.tier}`),
                                when: formatDateTime(memo.startedAt),
                            })}
                        >
                            <div className="builder_client-form">
                                {memo.location === 'random' ? (
                                    <Field label={t('builder.test.which_location')} required>
                                        <Select
                                            value={recLocation}
                                            onChange={setRecLocation}
                                            placeholder={t('builder.test.pick_location')}
                                            options={locOptions.filter(o => o.value !== 'random')}
                                        />
                                    </Field>
                                ) : (
                                    <div className="builder_client-muted">
                                        {t('builder.test.record_location', { n: memo.location })}
                                    </div>
                                )}
                                <Field label={t('builder.test.note')} hint={t('common.optional')}>
                                    <Textarea value={note} onChange={setNote} rows={2} maxLength={200} />
                                </Field>
                                <div className="builder_client-actions-row">
                                    <span className="cp-spacer" />
                                    <Button
                                        variant="danger"
                                        icon="xCircle"
                                        onClick={() => record('failed')}
                                        loading={busy}
                                        disabled={memo.location === 'random' && !recLocation}
                                    >
                                        {t('builder.test.failed')}
                                    </Button>
                                    <Button
                                        variant="primary"
                                        icon="checkCircle"
                                        onClick={() => record('passed')}
                                        loading={busy}
                                        disabled={memo.location === 'random' && !recLocation}
                                    >
                                        {t('builder.test.passed')}
                                    </Button>
                                </div>
                            </div>
                        </Card>
                    ) : memo && memo.recorded ? (
                        <Card padding="sm" muted>
                            <div className="builder_client-inline-note">
                                <Icon name={memo.recorded === 'passed' ? 'checkCircle' : 'xCircle'} size={15} />
                                <span>
                                    {t(
                                        memo.recorded === 'passed'
                                            ? 'builder.test.last_passed'
                                            : 'builder.test.last_failed',
                                        { tier: t(`tier.${memo.tier}`) },
                                    )}
                                </span>
                            </div>
                        </Card>
                    ) : null}
                </div>
            </Grid>
        </div>
    );
}
