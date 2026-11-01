// Profile · Field training (step T1, Config.FieldTraining): the officer's own training as a rookie and, as a trainer,
// his rookies with a Sign off button on every task whose count is reached. The server checks every rule again (only
// the rookie's own trainer, only a task that is ready and not signed yet). Nothing shows while the feature is off.

import { useState } from 'react';
import { Badge, Button, Card, Dialog, Field, ProgressBar, Textarea } from '../../shared/components';
import { formatDateTime } from '../../shared/format';
import { useAction, useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { asList } from '../../types/boards';
import type { FtoMine, FtoTask, FtoView } from '../../types/fieldTraining';
import './ProfileCards.css';

// One training's tasks: progress per task, who signed it off, and (onSign) a Sign off button on the ready ones.
export function FtoTaskList({ view, onSign }: { view: FtoView; onSign?: (task: FtoTask) => void }) {
    return (
        <ul className="profile-commend__list">
            {asList(view.tasks).map(task => (
                <li key={task.type} className="profile-commend__item">
                    <span className="profile-commend__text">
                        <span className="profile-commend__head">
                            <strong>{task.label}</strong>
                            {task.signed ? (
                                <Badge tone="success" size="sm" icon="check">
                                    {t('fto.done')}
                                </Badge>
                            ) : null}
                        </span>
                        <ProgressBar
                            size="sm"
                            value={task.runs}
                            max={task.need}
                            tone={task.signed ? 'success' : undefined}
                            showValue={t('fto.task_runs', { runs: task.runs, need: task.need })}
                        />
                        {task.signed ? (
                            <span className="profile-commend__by">
                                {t('fto.signed_by', { name: task.signed.by, time: formatDateTime(task.signed.at) })}
                                {task.signed.note ? ` · ${task.signed.note}` : ''}
                            </span>
                        ) : null}
                    </span>
                    {onSign && task.ready ? (
                        <Button size="sm" variant="secondary" icon="check" onClick={() => onSign(task)}>
                            {t('fto.sign')}
                        </Button>
                    ) : null}
                </li>
            ))}
        </ul>
    );
}

export function FtoProgress({ view }: { view: FtoView }) {
    return view.doneAt ? (
        <Badge tone="success" size="sm" icon="medal">
            {t('fto.done_on', { time: formatDateTime(view.doneAt) })}
        </Badge>
    ) : (
        <Badge tone="neutral" size="sm">
            {t('fto.progress', { signed: view.signed, total: view.total })}
        </Badge>
    );
}

export function FieldTrainingCard() {
    const { data, refetch } = useRequest<FtoMine | false>('fto:getMine', {});
    const { run, busy } = useAction();
    const [signing, setSigning] = useState<{ view: FtoView; task: FtoTask } | null>(null);
    const [note, setNote] = useState('');
    if (!data) return null;
    const rookies = asList(data.rookies);

    const submit = async () => {
        if (!signing) return;
        const res = await run(
            'server:fto:signOff',
            { rookie: signing.view.rookie.citizenid, task: signing.task.type, note: note.trim() || undefined },
            { success: 'fto.signed_toast' },
        );
        if (!res.ok) return;
        setSigning(null);
        setNote('');
        void refetch();
    };

    return (
        <Card
            title={t('fto.title')}
            subtitle={t('fto.subtitle')}
            icon="idCard"
            padding="sm"
            className="profile-commend"
        >
            {data.training ? (
                <>
                    <p className="profile-commend__head">
                        <strong>{t('fto.my_training', { name: data.training.trainer.name })}</strong>
                        <FtoProgress view={data.training} />
                    </p>
                    <FtoTaskList view={data.training} />
                </>
            ) : null}
            {rookies.length ? <p className="profile-commend__head">{t('fto.my_rookies')}</p> : null}
            {rookies.map(v => (
                <div key={v.rookie.citizenid}>
                    <p className="profile-commend__head">
                        <strong>{v.rookie.name}</strong>
                        <FtoProgress view={v} />
                    </p>
                    <FtoTaskList
                        view={v}
                        onSign={task => {
                            setNote('');
                            setSigning({ view: v, task });
                        }}
                    />
                </div>
            ))}
            <Dialog
                open={!!signing}
                onClose={() => setSigning(null)}
                size="sm"
                title={signing ? t('fto.sign_title', { task: signing.task.label, name: signing.view.rookie.name }) : ''}
                description={t('fto.sign_text')}
                footer={
                    <>
                        <Button variant="ghost" onClick={() => setSigning(null)}>
                            {t('common.cancel')}
                        </Button>
                        <Button variant="primary" icon="check" loading={busy} onClick={() => void submit()}>
                            {t('fto.sign')}
                        </Button>
                    </>
                }
            >
                <Field label={t('fto.note')}>
                    <Textarea value={note} onChange={setNote} maxLength={255} rows={2} />
                </Field>
            </Dialog>
        </Card>
    );
}
