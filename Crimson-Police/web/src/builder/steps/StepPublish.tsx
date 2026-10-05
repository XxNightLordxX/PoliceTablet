// "Publish": enabled when the draft passes every guardrail (a test is optional unless the server asks for one)

import { useEffect, useState } from 'react';
import { Badge, Button, Card, ConfirmDialog, Icon, KeyValue, TierBadge } from '../../shared/components';
import { asArray } from '../../shared/data';
import { formatDateTime } from '../../shared/format';
import { useAction } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { useCan } from '../../shared/session';
import { toast } from '../../shared/toast';
import type { BuilderDiscardResult, BuilderPublishResult, BuilderValidateResult } from '../../types/builder_server';
import type { BuilderStepKey } from '../../types/builder_client';
import { locationOfError, objectiveOfError, stepOfError } from '../defUtils';
import { requiredTierFor } from '../schema';
import { forgetDraft } from '../store';
import { StepIntro, type StepProps } from './common';

const STEP_ORDER: BuilderStepKey[] = ['blocks', 'details', 'settings', 'locations', 'scaling', 'test', 'publish'];

export function StepPublish({ ed, cfg, def, ro, goTo }: StepProps) {
    const can = useCan();
    const { run, busy } = useAction();
    const [check, setCheck] = useState<BuilderValidateResult | null>(null);
    const [confirm, setConfirm] = useState<'publish' | 'discard' | null>(null);
    const [done, setDone] = useState<BuilderPublishResult | null>(null);
    const rec = ed.record;

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

    const errors = check ? asArray(check.errors) : ed.errors;
    // the draft on screen decides (the record's requiredTier is the stored draft's, stale until the next load)
    const required = requiredTierFor(cfg, def.maxOfficers) || rec?.requiredTier || 'standard';
    const lockMine = !!ed.lock?.mine;
    const mayPublish = can('builderPublish') && !!rec?.can.publish;
    const tested = !!rec?.draftTested;
    const testRequired = !!cfg.requireTestToPublish;
    const hasDraft = !!rec?.hasDraft || rec?.dbStatus === 'draft';
    const items = [
        {
            ok: !!check && errors.length === 0,
            key: check
                ? errors.length
                    ? 'builder.pub.check_errors'
                    : 'builder.pub.check_valid'
                : 'builder.pub.check_running',
            vars: { n: errors.length },
        },
        {
            ok: tested || !testRequired,
            key: tested
                ? 'builder.pub.check_tested'
                : testRequired
                  ? 'builder.pub.check_not_tested'
                  : 'builder.pub.check_untested_optional',
            vars: { tier: t(`tier.${required}`) },
            info: !tested && !testRequired,
        },
        { ok: lockMine, key: lockMine ? 'builder.pub.check_lock' : 'builder.pub.check_no_lock', vars: {} },
        {
            ok: mayPublish,
            key: mayPublish ? 'builder.pub.check_permission' : 'builder.pub.check_no_permission',
            vars: {},
        },
        { ok: hasDraft, key: hasDraft ? 'builder.pub.check_draft' : 'builder.pub.check_no_draft', vars: {} },
    ];
    const ready = items.every(i => i.ok) && !ro;

    const grouped = STEP_ORDER.map(s => ({ step: s, list: errors.filter(e => stepOfError(e) === s) })).filter(
        g => g.list.length,
    );

    const publish = async () => {
        // publishing uses the stored draft: store what is on screen first (a stored change needs a new test)
        if (ed.dirty && !(await ed.flush())) {
            setConfirm(null);
            toast('error', t('builder.pub.not_stored'));
            return;
        }
        const res = await run<BuilderPublishResult>(
            'server:builder:publish',
            { id: ed.id },
            { success: 'builder.pub.published', successVars: { mission: def.label } },
        );
        setConfirm(null);
        if (res.ok && res.data) {
            setDone(res.data);
            // the server cleared the draft and released the lock: load the live version (and lock it again)
            void ed.reload();
        } else if (res.error === 'err.builder_not_tested') void ed.refresh();
    };
    const discard = async () => {
        const res = await run<BuilderDiscardResult>('server:builder:discardDraft', { id: ed.id });
        setConfirm(null);
        if (res.ok && res.data) {
            forgetDraft(ed.id);
            // a never-published mission is deleted; otherwise the editor goes back to the live version
            if (res.data.deleted) ed.gone();
            else void ed.reload();
        }
    };

    if (done) {
        return (
            <div className="builder_client-step">
                <Card highlight="success" padding="lg">
                    <div className="builder_client-done">
                        <span className="builder_client-done__icon">
                            <Icon name="checkCircle" size={30} />
                        </span>
                        <div className="builder_client-done__title">
                            {t('builder.pub.done_title', { mission: def.label, version: done.version })}
                        </div>
                        <div className="builder_client-done__text">{t('builder.pub.done_text')}</div>
                        <div className="builder_client-done__meta">
                            <KeyValue label={t('builder.pub.file')}>
                                <span className="builder_client-mono">{done.filePath}</span>
                            </KeyValue>
                            <KeyValue label={t('builder.pub.backup')}>
                                <span className="builder_client-mono">{done.backup ?? t('builder.pub.no_backup')}</span>
                            </KeyValue>
                        </div>
                        <div className="builder_client-actions-row">
                            <Button
                                variant="secondary"
                                icon="edit"
                                onClick={() => {
                                    setDone(null);
                                    void ed.takeLock();
                                }}
                            >
                                {t('builder.pub.keep_editing')}
                            </Button>
                        </div>
                    </div>
                </Card>
            </div>
        );
    }

    return (
        <div className="builder_client-step">
            <StepIntro icon="checkCircle" title={t('builder.pub.title')}>
                {t('builder.pub.intro')}
            </StepIntro>
            <div className="builder_client-publish">
                <Card title={t('builder.pub.checklist')} icon="list" padding="md">
                    <ul className="builder_client-checks-list is-large">
                        {items.map(i => (
                            <li key={i.key} className={i.ok ? 'is-ok' : 'is-bad'}>
                                <Icon
                                    name={'info' in i && i.info ? 'info' : i.ok ? 'checkCircle' : 'xCircle'}
                                    size={16}
                                />
                                <span>{t(i.key, i.vars)}</span>
                                {!tested &&
                                (i.key === 'builder.pub.check_not_tested' ||
                                    i.key === 'builder.pub.check_untested_optional') ? (
                                    <Button size="sm" variant="ghost" onClick={() => goTo('test')}>
                                        {t('builder.pub.go_test')}
                                    </Button>
                                ) : null}
                            </li>
                        ))}
                    </ul>
                    <div className="builder_client-publish__meta">
                        <KeyValue label={t('builder.pub.required_tier')}>
                            <TierBadge tier={required} size="sm" />
                        </KeyValue>
                        <KeyValue label={t('builder.pub.next_version')}>
                            <span className="cp-num">
                                {t('builder.version_short', { version: rec?.draftVersion ?? (rec?.version ?? 0) + 1 })}
                            </span>
                        </KeyValue>
                        <KeyValue label={t('builder.pub.pool')}>
                            {t('builder.pub.pool_text', {
                                type: asArray(cfg.missionTypes).find(m => m.key === def.type)?.label ?? def.type,
                                depts: def.departments.length
                                    ? def.departments
                                          .map(k => asArray(cfg.departments).find(d => d.key === k)?.short ?? k)
                                          .join(', ')
                                    : t('builder.pub.all_depts'),
                            })}
                        </KeyValue>
                        <KeyValue label={t('builder.pub.file')}>
                            <span className="builder_client-mono">{`${cfg.exportPath ?? 'missions/custom/'}${ed.id}.lua`}</span>
                        </KeyValue>
                    </div>
                    <div className="builder_client-actions-row">
                        {rec?.can.discard && hasDraft && !ro ? (
                            <Button variant="ghost" icon="trash" onClick={() => setConfirm('discard')}>
                                {t(rec?.version ? 'builder.list.discard' : 'builder.list.delete')}
                            </Button>
                        ) : null}
                        <span className="cp-spacer" />
                        <Button
                            variant="primary"
                            icon="globe"
                            disabled={!ready}
                            onClick={() => setConfirm('publish')}
                            title={ready ? undefined : t('builder.pub.not_ready')}
                        >
                            {t('builder.pub.publish')}
                        </Button>
                    </div>
                </Card>
                <Card
                    title={t('builder.pub.problems')}
                    icon="alert"
                    padding="md"
                    actions={
                        <Badge size="sm" tone={errors.length ? 'danger' : 'success'}>
                            <span className="cp-num">{errors.length}</span>
                        </Badge>
                    }
                >
                    {!grouped.length ? (
                        <div className="builder_client-inline-note is-ok">
                            <Icon name="checkCircle" size={15} />
                            <span>{t('builder.pub.no_problems')}</span>
                        </div>
                    ) : (
                        <div className="builder_client-problems">
                            {grouped.map(g => (
                                <div key={g.step} className="builder_client-problems__group">
                                    <div className="builder_client-problems__head">
                                        <span>{t(`builder.step.${g.step}`)}</span>
                                        <Button
                                            size="sm"
                                            variant="ghost"
                                            iconRight="chevronRight"
                                            onClick={() =>
                                                goTo(g.step, {
                                                    objective: objectiveOfError(g.list[0]) ?? undefined,
                                                    location: locationOfError(g.list[0]) ?? undefined,
                                                })
                                            }
                                        >
                                            {t('builder.pub.go_fix')}
                                        </Button>
                                    </div>
                                    <ul>
                                        {g.list.map((e, i) => (
                                            <li key={i}>{e.message}</li>
                                        ))}
                                    </ul>
                                </div>
                            ))}
                        </div>
                    )}
                </Card>
                {rec?.version ? (
                    <Card title={t('builder.pub.live')} icon="globe" padding="md" muted>
                        <div className="builder_client-publish__meta">
                            <KeyValue label={t('builder.pub.live_version')}>
                                <span className="cp-num">{t('builder.version_short', { version: rec.version })}</span>
                            </KeyValue>
                            <KeyValue label={t('builder.pub.published_at')}>
                                {rec.publishedAt ? formatDateTime(rec.publishedAt) : '—'}
                            </KeyValue>
                            <KeyValue label={t('builder.pub.published_by')}>{rec.publishedBy ?? '—'}</KeyValue>
                            <KeyValue label={t('builder.pub.backups')}>
                                <span className="cp-num">
                                    {asArray(rec.backups).length
                                        ? asArray(rec.backups)
                                              .map(v => t('builder.version_short', { version: v }))
                                              .join(', ')
                                        : '—'}
                                </span>
                            </KeyValue>
                        </div>
                    </Card>
                ) : null}
            </div>
            <ConfirmDialog
                open={confirm === 'publish'}
                title={t(tested ? 'builder.confirm.publish.title' : 'builder.confirm.publish_untested.title', {
                    mission: def.label,
                })}
                message={`${tested ? '' : `${t('builder.confirm.publish_untested.message')} `}${t(
                    'builder.confirm.publish.message',
                    {
                        version: rec?.draftVersion ?? 1,
                        file: `${cfg.exportPath ?? 'missions/custom/'}${ed.id}.lua`,
                    },
                )}`}
                confirmLabel={t('builder.confirm.publish.button')}
                onConfirm={publish}
                onCancel={() => setConfirm(null)}
                busy={busy}
            />
            <ConfirmDialog
                open={confirm === 'discard'}
                tone="danger"
                title={t(rec?.version ? 'builder.confirm.discard.title' : 'builder.confirm.delete.title', {
                    mission: def.label,
                })}
                message={t(rec?.version ? 'builder.confirm.discard.message' : 'builder.confirm.delete.message', {
                    mission: def.label,
                    version: rec?.version ?? 1,
                })}
                confirmLabel={t(rec?.version ? 'builder.confirm.discard.button' : 'builder.confirm.delete.button')}
                onConfirm={discard}
                onCancel={() => setConfirm(null)}
                busy={busy}
            />
        </div>
    );
}
