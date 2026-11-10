// Supervisor UI · Department · Training (Config.FieldTraining): every pairing of the department

// Supervisor UI · Department · Training (Config.FieldTraining): every pairing of the department
// with its progress, Pair trainer (a rookie of the department and an online trainer at or above the trainer grade) and
// End training (two clicks). The server checks every rule again. Nothing shows while the feature is off. a
// Pairings heading with the count, and the stale line when a refresh fails.

import { useState } from 'react';
import { Button, Card, ConfirmButton, Dialog, EmptyState, Field, Select, ScreenStatus } from '../../shared/components';
import { useAction, useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { asList } from '../../types/boards';
import type { FtoDept, FtoView } from '../../types/fieldTraining';
import { FtoProgress, FtoTaskList } from '../../officer/components/FieldTrainingCard';
import { screenStateOf } from '../../shared/screenHeads';
import '../../officer/components/ProfileCards.css';

function EndButton({ view, onDone }: { view: FtoView; onDone: () => void }) {
    const { run, busy } = useAction();
    const end = async () => {
        const res = await run(
            'server:sup:ftoUnpair',
            { rookie: view.rookie.citizenid },
            { success: 'fto.unpaired_toast' },
        );
        if (res.ok) onDone();
    };
    return (
        <ConfirmButton
            size="sm"
            variant="ghost"
            icon="x"
            loading={busy}
            label={t('fto.unpair')}
            confirmLabel={t('fto.unpair_confirm')}
            onConfirm={() => void end()}
        />
    );
}

// showOff (the Department screen's Training tab): say so while Config.FieldTraining is off, else show nothing.
export function FieldTrainingPanel({ showOff = false }: { showOff?: boolean }) {
    const { data, loading, error, refetch } = useRequest<FtoDept | false>('sup:getFieldTraining', {});
    const { run, busy } = useAction();
    const [pairing, setPairing] = useState(false);
    const [rookie, setRookie] = useState('');
    const [trainer, setTrainer] = useState('');
    if (data === false && showOff) {
        return (
            <Card>
                <EmptyState icon="idCard" title={t('sup.dept.training_off')} text={t('sup.dept.training_off_text')} />
            </Card>
        );
    }
    if (!data) return null;
    const pairs = asList(data.pairs);
    const trainers = asList(data.trainers);

    const submit = async () => {
        if (!rookie || !trainer) return;
        const res = await run('server:sup:ftoPair', { rookie, trainer }, { success: 'fto.paired_toast' });
        if (!res.ok) return;
        setPairing(false);
        void refetch();
    };

    return (
        <Card
            title={t('fto.title')}
            subtitle={t('fto.subtitle')}
            icon="idCard"
            padding="sm"
            className="profile-commend"
            actions={
                <Button
                    size="sm"
                    variant="secondary"
                    icon="plus"
                    onClick={() => {
                        setRookie('');
                        setTrainer('');
                        setPairing(true);
                    }}
                >
                    {t('fto.pair')}
                </Button>
            }
        >
            <ScreenStatus state={screenStateOf(true, loading, error)} error={error} onRetry={() => void refetch()} />
            <h4 className="cp-section-title">{t('fto.pairs_title', { n: pairs.length })}</h4>
            {pairs.length === 0 ? <EmptyState compact icon="idCard" title={t('fto.none')} /> : null}
            {pairs.map(v => (
                <div key={v.rookie.citizenid}>
                    <p className="profile-commend__head">
                        <strong>{v.rookie.name}</strong>
                        <span className="profile-commend__by">
                            {t('fto.trainer')}: {v.trainer.name}
                        </span>
                        <FtoProgress view={v} />
                        {!v.doneAt ? <EndButton view={v} onDone={() => void refetch()} /> : null}
                    </p>
                    <FtoTaskList view={v} />
                </div>
            ))}
            <Dialog
                open={pairing}
                onClose={() => setPairing(false)}
                size="sm"
                title={t('fto.pair_title')}
                description={t('fto.pair_text', { grade: data.trainerGrade, n: data.rookiesPerTrainer })}
                footer={
                    <>
                        <Button variant="ghost" onClick={() => setPairing(false)}>
                            {t('common.cancel')}
                        </Button>
                        <Button
                            variant="primary"
                            icon="check"
                            loading={busy}
                            disabled={!rookie || !trainer || rookie === trainer}
                            onClick={() => void submit()}
                        >
                            {t('fto.pair')}
                        </Button>
                    </>
                }
            >
                <Field label={t('fto.rookie')} required>
                    <Select
                        value={rookie}
                        onChange={setRookie}
                        placeholder={t('fto.pick')}
                        options={asList(data.candidates).map(o => ({
                            value: o.citizenid,
                            label: o.callsign ? `${o.name} · ${o.callsign}` : o.name,
                        }))}
                    />
                </Field>
                <Field label={t('fto.trainer')} required hint={trainers.length ? undefined : t('fto.no_trainers')}>
                    <Select
                        value={trainer}
                        onChange={setTrainer}
                        placeholder={t('fto.pick')}
                        options={trainers.map(o => ({
                            value: o.citizenid,
                            label: o.rank ? `${o.name} · ${o.rank}` : o.name,
                        }))}
                    />
                </Field>
            </Dialog>
        </Card>
    );
}
