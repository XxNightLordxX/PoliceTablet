// Supervisor UI · Department Report · Mission ban (Config.MissionControls.controls.missionBan): bar one
// officer from taking missions for a number of hours (the admin's min to max), with a reason; or lift the ban the
// viewer set. The server checks every rule again (own department, a lower grade, never himself, the daily count).

// Supervisor UI · Department Report · Mission ban: hours (the admin's min to max) and a reason, or Lift for
// the ban the viewer set. The server checks every rule again (own department, a lower grade, never himself, the
// officer online, the supervisor's bans a day).

import { useEffect, useState } from 'react';
import { Button, Dialog, Field, NumberInput, Textarea } from '../../shared/components';
import { formatDateTime } from '../../shared/format';
import { useAction } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { useOptionalSession } from '../../shared/session';
import type { MissionBanControl, MissionBanState } from '../../types/boards';
import { keepLastUsed, lastUsed, rememberOn, startNumber } from './lastUsed';

export function MissionBanDialog({
    officer,
    control,
    state,
    onClose,
    onDone,
    activity,
}: {
    officer: { citizenid: string; name: string } | null;
    control: MissionBanControl | null;
    state: MissionBanState | null;
    onClose: () => void;
    // reply: the action's reply (with activity = true it carries the officer's fresh activity, step FX1)
    onDone: (reply: unknown) => void;
    activity?: boolean;
}) {
    const { run, busy } = useAction();
    // Config.Tablet.supervisorRemember (step WF2): a new ban opens with the hours and reason last used
    const remember = rememberOn(useOptionalSession());
    const [hours, setHours] = useState<number | null>(control?.min ?? 1);
    const [reason, setReason] = useState('');
    const liftOpen = !!state;
    useEffect(() => {
        const last = liftOpen ? {} : lastUsed('ban', remember);
        const min = control?.min ?? 1;
        setReason(last.reason ?? '');
        setHours(startNumber(last.number, min, control?.max, min));
    }, [officer?.citizenid, control?.min, control?.max, remember, liftOpen]);

    const lifting = !!state;
    const used = control?.perDay !== undefined && (control.usedToday ?? 0) >= control.perDay;
    const blocked =
        busy ||
        !control ||
        reason.trim() === '' ||
        (lifting ? !control.canLift : used || !hours || hours < control.min);

    const submit = async () => {
        if (!officer || blocked) return;
        const activityOf = activity ? officer.citizenid : undefined;
        const res = lifting
            ? await run(
                  'server:sup:liftMissionBan',
                  { citizenid: officer.citizenid, reason: reason.trim(), activityOf },
                  { success: 'sup.ban.lifted' },
              )
            : await run(
                  'server:sup:missionBan',
                  { citizenid: officer.citizenid, hours, reason: reason.trim(), activityOf },
                  { success: 'sup.ban.set' },
              );
        if (!res.ok) return;
        if (!lifting) keepLastUsed('ban', remember, { number: hours ?? undefined, reason });
        onDone(res.data);
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
