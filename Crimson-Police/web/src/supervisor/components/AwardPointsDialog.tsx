// Supervisor UI · Department Report · Give points (step P22, Config.MissionControls.controls.awardPoints): a logged
// manual award of the admin's min to max points to an officer of the viewer's own department, with a reason. The
// server checks every rule again (own department, never himself, the daily total, Config.AdminControl's limits).

import { useEffect, useState } from 'react';
import { Button, Dialog, Field, NumberInput, TextInput, Textarea } from '../../shared/components';
import { useAction } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import type { AwardPointsControl } from '../../types/boards';

export function AwardPointsDialog({
    officer,
    control,
    onClose,
    onDone,
}: {
    officer: { citizenid: string; name: string } | null;
    control: AwardPointsControl | null;
    onClose: () => void;
    onDone: () => void;
}) {
    const { run, busy } = useAction();
    const [points, setPoints] = useState<number | null>(control?.min ?? 1);
    const [reason, setReason] = useState('');
    const [confirm, setConfirm] = useState('');
    useEffect(() => {
        setReason('');
        setConfirm('');
        setPoints(control?.min ?? 1);
    }, [officer?.citizenid, control?.min]);

    const left = control?.perDay !== undefined ? control.perDay - (control.usedToday ?? 0) : undefined;
    const needsConfirm = !!control?.confirmAbove && (points ?? 0) >= control.confirmAbove;
    const blocked =
        busy ||
        !control ||
        !officer ||
        reason.trim() === '' ||
        !points ||
        points < control.min ||
        points > control.max ||
        (left !== undefined && points > left) ||
        (needsConfirm && confirm.trim() !== officer.citizenid);

    const submit = async () => {
        if (!officer || blocked) return;
        const res = await run(
            'server:sup:awardPoints',
            {
                citizenid: officer.citizenid,
                points,
                reason: reason.trim(),
                confirm: needsConfirm ? confirm.trim() : undefined,
            },
            { success: 'sup.award.done' },
        );
        if (!res.ok) return;
        onDone();
        onClose();
    };

    return (
        <Dialog
            open={!!officer && !!control}
            onClose={onClose}
            size="sm"
            title={officer ? t('sup.award.title', { name: officer.name }) : ''}
            description={t('sup.award.text')}
            footer={
                <>
                    <Button variant="ghost" onClick={onClose}>
                        {t('common.cancel')}
                    </Button>
                    <Button
                        variant="primary"
                        icon="medal"
                        loading={busy}
                        disabled={blocked}
                        onClick={() => void submit()}
                    >
                        {t('sup.award.confirm')}
                    </Button>
                </>
            }
        >
            {control ? (
                <>
                    {control.perDay !== undefined ? (
                        <p className="sup-cd-note">
                            {t('sup.award.mine_used', { used: control.usedToday ?? 0, n: control.perDay })}
                        </p>
                    ) : null}
                    <Field label={t('sup.award.points', { min: control.min, max: control.max })} required>
                        <NumberInput value={points} onChange={setPoints} min={control.min} max={control.max} />
                    </Field>
                </>
            ) : null}
            <Field label={t('sup.award.reason')} required>
                <Textarea value={reason} onChange={setReason} maxLength={255} rows={2} />
            </Field>
            {needsConfirm && officer ? (
                <Field label={t('sup.award.confirm_label', { word: officer.citizenid })} required>
                    <TextInput value={confirm} onChange={setConfirm} maxLength={50} />
                </Field>
            ) : null}
        </Dialog>
    );
}
