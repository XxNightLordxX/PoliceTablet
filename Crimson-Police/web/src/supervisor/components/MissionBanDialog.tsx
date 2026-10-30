// Supervisor UI · Department Report · Mission ban (step P11, Config.MissionControls.controls.missionBan): bar one
// officer from taking missions for a number of hours (the admin's min to max), with a reason; or lift the ban the
// viewer set. The server checks every rule again (own department, a lower grade, never himself, the daily count).

import { useEffect, useState } from 'react';
import { Button, Dialog, Field, NumberInput, Textarea } from '../../shared/components';
import { formatDateTime } from '../../shared/format';
import { useAction } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import type { MissionBanControl, MissionBanState } from '../../types/boards';

export function MissionBanDialog({
    officer,
    control,
    state,
    onClose,
    onDone,
}: {
    officer: { citizenid: string; name: string } | null;
    control: MissionBanControl | null;
    state: MissionBanState | null;
    onClose: () => void;
    onDone: () => void;
}) {
    const { run, busy } = useAction();
    const [hours, setHours] = useState<number | null>(control?.min ?? 1);
    const [reason, setReason] = useState('');
    useEffect(() => {
        setReason('');
        setHours(control?.min ?? 1);
    }, [officer?.citizenid, control?.min]);

    const lifting = !!state;
    const used = control?.perDay !== undefined && (control.usedToday ?? 0) >= control.perDay;
    const blocked =
        busy ||
        !control ||
        reason.trim() === '' ||
        (lifting ? !control.canLift : used || !hours || hours < control.min);

    const submit = async () => {
        if (!officer || blocked) return;
        const res = lifting
            ? await run(
                  'server:sup:liftMissionBan',
                  { citizenid: officer.citizenid, reason: reason.trim() },
                  { success: 'sup.ban.lifted' },
              )
            : await run(
                  'server:sup:missionBan',
                  { citizenid: officer.citizenid, hours, reason: reason.trim() },
                  { success: 'sup.ban.set' },
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
            title={officer ? t(lifting ? 'sup.ban.lift_title' : 'sup.ban.title', { name: officer.name }) : ''}
            description={
                lifting && state
                    ? t('sup.ban.state', { time: formatDateTime(state.until), by: state.by })
                    : t('sup.ban.text')
            }
            footer={
                <>
                    <Button variant="ghost" onClick={onClose}>
                        {t('common.cancel')}
                    </Button>
                    <Button
                        variant={lifting ? 'primary' : 'danger'}
                        icon={lifting ? 'check' : 'xCircle'}
                        loading={busy}
                        disabled={blocked}
                        onClick={() => void submit()}
                    >
                        {t(lifting ? 'sup.ban.lift' : 'sup.ban.confirm')}
                    </Button>
                </>
            }
        >
            {!lifting && control ? (
                <>
                    {control.perDay !== undefined ? (
                        <p className="sup-cd-note">
                            {t('sup.ban.mine_used', { used: control.usedToday ?? 0, n: control.perDay })}
                        </p>
                    ) : null}
                    <Field label={t('sup.ban.hours', { min: control.min, max: control.max })} required>
                        <NumberInput value={hours} onChange={setHours} min={control.min} max={control.max} />
                    </Field>
                </>
            ) : null}
            {lifting && control && !control.canLift ? <p className="sup-cd-note">{t('sup.ban.not_yours')}</p> : null}
            <Field label={t('sup.ban.reason')} required>
                <Textarea value={reason} onChange={setReason} maxLength={255} rows={2} />
            </Field>
        </Dialog>
    );
}
