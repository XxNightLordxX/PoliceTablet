// Admin UI -> Home · First-start setup (Config.AdminUi.setupScreen): shown above the dashboard until an admin

// Admin UI -> Home · First-start setup (Config.AdminUi.setupScreen): shown above the dashboard until an admin
// finishes or skips it. Five steps: departments (their Qbox jobs and supervisor grade, and a department for each
// Qbox police job no department lists, with its colours and logo link), desks, storage, the scripts found, and a preset. Finish sends one
// server:admin:finishSetup with only what changed; every answer is an ordinary setting, editable in Settings later.
// The logic is in admin/components/setup.ts.

import { useEffect, useState } from 'react';
import {
    Badge,
    Button,
    Card,
    Checkbox,
    ConfirmButton,
    LoadingBlock,
    Select,
    TextInput,
    Toggle,
} from '../../shared/components';
import { formatNumber } from '../../shared/format';
import { useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { toast } from '../../shared/toast';
import type { SetupReply, SetupView } from '../../types/admin_system';
import { useAdminAction } from './kit/useAdminAction';
import {
    SETUP_STEPS,
    changeCount,
    finishPayload,
    gradeChoices,
    initialAnswers,
    scriptLine,
    toggledNew,
    unclaimedJobs,
    type NewDept,
    type SetupAnswers,
} from './setup';

function toggled(list: string[], v: string, on: boolean): string[] {
    return on ? (list.includes(v) ? list : [...list, v]) : list.filter(x => x !== v);
}

function Departments({
    view,
    answers,
    set,
}: {
    view: SetupView;
    answers: SetupAnswers;
    set: (a: SetupAnswers) => void;
}) {
    const free = unclaimedJobs(view);
    const police = view.jobs.filter(j => j.police || j.department);
    return (
        <div className="admin-setup__list">
            {view.departments.map(d => {
                const a = answers.departments[d.key];
                if (!a) return null;
                const grades = gradeChoices(view, a.jobs);
                const put = (next: Partial<typeof a>) =>
                    set({ ...answers, departments: { ...answers.departments, [d.key]: { ...a, ...next } } });
                return (
                    <Card key={d.key} padding="sm" title={`${d.short} · ${d.label}`}>
                        <Toggle checked={a.enabled} onChange={on => put({ enabled: on })} label={t('admin.setup.on')} />
                        <div className="admin-setup__label">{t('admin.setup.jobs')}</div>
                        <div className="admin-setup__chips">
                            {police.map(j => (
                                <Checkbox
                                    key={j.name}
                                    checked={a.jobs.includes(j.name)}
                                    onChange={on => put({ jobs: toggled(a.jobs, j.name, on) })}
                                    label={`${j.label} (${j.name})`}
                                />
                            ))}
                        </div>
                        {a.jobs.length === 0 ? <Badge tone="warning">{t('admin.setup.jobs_none')}</Badge> : null}
                        <div className="admin-setup__label">{t('admin.setup.supervisor')}</div>
                        <Select
                            value={String(a.supervisorGrade)}
                            onChange={v => put({ supervisorGrade: Number(v) })}
                            options={(grades.length > 0
                                ? grades
                                : [{ level: a.supervisorGrade, name: String(a.supervisorGrade), boss: false }]
                            ).map(g => ({ value: String(g.level), label: `${g.level} ${g.name}` }))}
                            aria-label={t('admin.setup.supervisor')}
                        />
                    </Card>
                );
            })}
            {free.length > 0 ? (
                <Card padding="sm" title={t('admin.setup.add_title')} subtitle={t('admin.setup.add_text')}>
                    {free.map(j => {
                        const n = answers.add.find(x => x.job === j.name);
                        const put = (next: Partial<NewDept>) =>
                            set({ ...answers, add: answers.add.map(x => (x.job === j.name ? { ...x, ...next } : x)) });
                        return (
                            <div key={j.name}>
                                <Checkbox
                                    checked={!!n}
                                    onChange={on => set({ ...answers, add: toggledNew(answers.add, j.name, on) })}
                                    label={`${j.label} (${j.name})`}
                                />
                                {n ? (
                                    <>
                                        <div className="admin-setup__label">{t('admin.setup.add_look')}</div>
                                        <Select
                                            value={n.themeFrom}
                                            onChange={v => put({ themeFrom: v })}
                                            options={[
                                                { value: '', label: t('admin.setup.add_look_new') },
                                                ...view.departments.map(d => ({
                                                    value: d.key,
                                                    label: t('admin.setup.add_look_from', { name: d.short }),
                                                })),
                                            ]}
                                            aria-label={t('admin.setup.add_look')}
                                        />
                                        <div className="admin-setup__label">{t('admin.setup.add_logo')}</div>
                                        <TextInput
                                            value={n.logoUrl}
                                            onChange={v => put({ logoUrl: v })}
                                            placeholder="https://"
                                            maxLength={512}
                                            aria-label={t('admin.setup.add_logo')}
                                        />
                                    </>
                                ) : null}
                            </div>
                        );
                    })}
                </Card>
            ) : null}
            {view.jobs.length === 0 ? <Badge tone="warning">{t('admin.setup.no_jobs')}</Badge> : null}
        </div>
    );
}

function Desks({ view, answers, set }: { view: SetupView; answers: SetupAnswers; set: (a: SetupAnswers) => void }) {
    return (
        <div className="admin-setup__list">
            <p className="admin-setup__text">{t('admin.setup.desks_text')}</p>
            {view.desks.map(d => (
                <Checkbox
                    key={d.index}
                    checked={answers.desks.includes(d.index)}
                    onChange={on =>
                        set({
                            ...answers,
                            desks: on
                                ? [...answers.desks, d.index].sort((x, y) => x - y)
                                : answers.desks.filter(i => i !== d.index),
                        })
                    }
                    label={
                        d.coords
                            ? `${d.label} (${d.coords.x.toFixed(1)}, ${d.coords.y.toFixed(1)}, ${d.coords.z.toFixed(1)})`
                            : d.label
                    }
                />
            ))}
        </div>
    );
}

function Storage({ view }: { view: SetupView }) {
    const s = view.storage;
    return (
        <div className="admin-setup__list">
            <p className="admin-setup__text">
                {s.database ? t('admin.setup.storage_db') : t('admin.setup.storage_files', { folder: s.folder })}
            </p>
            {!s.database && s.oxmysql ? <p className="admin-setup__text">{t('admin.setup.storage_switch')}</p> : null}
            <p className="admin-setup__text">{t('admin.setup.storage_copy', { cmd: s.copyCommand })}</p>
        </div>
    );
}

function Scripts({ view, answers, set }: { view: SetupView; answers: SetupAnswers; set: (a: SetupAnswers) => void }) {
    return (
        <div className="admin-setup__list">
            {view.integrations.map(i => {
                const line = scriptLine(i);
                return (
                    <Card
                        key={i.kind}
                        padding="sm"
                        title={t(`admin.setup.kind.${i.kind}`)}
                        subtitle={t(line.key, line.vars)}
                    >
                        <Select
                            value={answers.integrations[i.kind] ?? i.setting}
                            onChange={v => set({ ...answers, integrations: { ...answers.integrations, [i.kind]: v } })}
                            options={i.options.map(o => ({ value: o, label: o }))}
                            aria-label={t(`admin.setup.kind.${i.kind}`)}
                        />
                    </Card>
                );
            })}
        </div>
    );
}

function Preset({ view, answers, set }: { view: SetupView; answers: SetupAnswers; set: (a: SetupAnswers) => void }) {
    const rows = [
        { key: '', name: t('admin.setup.preset_none'), help: t('admin.setup.preset_none_help') },
        ...view.presets,
    ];
    return (
        <div className="admin-setup__list">
            {rows.map(p => (
                <Checkbox
                    key={p.key || 'none'}
                    checked={answers.preset === p.key}
                    onChange={on => set({ ...answers, preset: on ? p.key : '' })}
                    label={p.help ? `${p.name}: ${p.help}` : p.name}
                />
            ))}
        </div>
    );
}

export function SetupWizard({ onDone }: { onDone: () => void }) {
    const { data, loading, error, refetch } = useRequest<SetupView>('admin:getSetup', {});
    const [answers, setAnswers] = useState<SetupAnswers>(() => initialAnswers(null));
    const [step, setStep] = useState(0);
    const { run, busy } = useAdminAction();
    useEffect(() => {
        if (data) setAnswers(initialAnswers(data));
    }, [data]);
    const send = async (payload: Record<string, unknown>) => {
        const res = await run<SetupReply>('server:admin:finishSetup', payload);
        if (!res.ok) return;
        if (res.data?.presetError) toast('warning', t(res.data.presetError));
        toast('success', t(payload.skip ? 'admin.setup.skipped' : 'admin.setup.done'));
        onDone();
    };
    const key = SETUP_STEPS[step] ?? 'departments';
    const last = step === SETUP_STEPS.length - 1;
    return (
        <Card
            className="admin-setup"
            title={t('admin.setup.title')}
            subtitle={t('admin.setup.subtitle', { n: formatNumber(step + 1), of: formatNumber(SETUP_STEPS.length) })}
            icon="sliders"
            highlight="accent"
            actions={
                <ConfirmButton
                    variant="ghost"
                    size="sm"
                    label={t('admin.setup.skip')}
                    confirmLabel={t('admin.setup.skip_confirm')}
                    disabled={busy}
                    onConfirm={() => void send({ skip: true })}
                />
            }
        >
            {!data ? (
                error ? (
                    <Button size="sm" onClick={() => void refetch()}>
                        {t('admin.home.load_failed')}
                    </Button>
                ) : (
                    <LoadingBlock text={loading ? undefined : t('admin.home.unknown')} />
                )
            ) : (
                <>
                    <h4 className="admin-setup__step">{t(`admin.setup.step.${key}`)}</h4>
                    <p className="admin-setup__text">{t(`admin.setup.step.${key}_help`)}</p>
                    {key === 'departments' ? <Departments view={data} answers={answers} set={setAnswers} /> : null}
                    {key === 'desks' ? <Desks view={data} answers={answers} set={setAnswers} /> : null}
                    {key === 'storage' ? <Storage view={data} /> : null}
                    {key === 'scripts' ? <Scripts view={data} answers={answers} set={setAnswers} /> : null}
                    {key === 'preset' ? <Preset view={data} answers={answers} set={setAnswers} /> : null}
                    <div className="admin-setup__nav">
                        <Button size="sm" variant="secondary" disabled={step === 0} onClick={() => setStep(step - 1)}>
                            {t('admin.setup.back')}
                        </Button>
                        {last ? (
                            <Button
                                size="sm"
                                variant="primary"
                                disabled={busy}
                                onClick={() => void send(finishPayload(data, answers))}
                            >
                                {t('admin.setup.finish', { n: formatNumber(changeCount(data, answers)) })}
                            </Button>
                        ) : (
                            <Button
                                size="sm"
                                variant="primary"
                                iconRight="chevronRight"
                                onClick={() => setStep(step + 1)}
                            >
                                {t('admin.setup.next')}
                            </Button>
                        )}
                    </div>
                </>
            )}
        </Card>
    );
}
