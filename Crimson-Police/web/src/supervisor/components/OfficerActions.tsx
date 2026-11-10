// Supervisor UI · Department → Officers: the action forms of the officer's side panel (UI4).

// Supervisor UI · Department → Officers · the forms of the officer's side panel (UI4): Give points, Mission ban
// (or Lift), Clear cooldown and Field training, each shown in the panel under its action (the dialogs before). The
// same fields, limits and reasons as before; the server checks every rule again (own department, never himself, a
// lower grade for a ban, the supervisor's and the officer's uses a day, Config.AdminControl) and writes the audit row.
// Commend is CommendForm (CommendDialog.tsx, also the Admin UI's dialog).

import { useEffect, useState, type ReactNode } from 'react';
import {
    Button,
    ConfirmButton,
    Countdown,
    EmptyState,
    ErrorState,
    Field,
    LoadingBlock,
    NumberInput,
    Select,
    TextInput,
    Textarea,
} from '../../shared/components';
import { formatDateTime } from '../../shared/format';
import { useAction, useRequest } from '../../shared/hooks';
import { applyReplyView } from '../../shared/replyView';
import { t } from '../../shared/i18n';
import {
    asList,
    type AwardPointsControl,
    type MissionBanControl,
    type MissionBanState,
    type OfficerCooldowns,
} from '../../types/boards';
import type { FtoDept } from '../../types/fieldTraining';
import { FtoProgress, FtoTaskList } from '../../officer/components/FieldTrainingCard';
import { keepLastUsed, lastUsed, startNumber } from './lastUsed';
import type { FtoRole } from './officerPanel';

export interface PanelOfficer {
    citizenid: string;
    name: string;
}

// The buttons under a form: Cancel closes it, the main button sends.
export function FormButtons({ onCancel, children }: { onCancel: () => void; children?: ReactNode }) {
    return (
        <div className="sup-panel__buttons">
            <Button variant="ghost" size="sm" onClick={onCancel}>
                {t('common.cancel')}
            </Button>
            {children}
        </div>
    );
}

// Give points (Config.MissionControls.controls.awardPoints): points (the admin's min to max), a reason and, at or
// above AdminControl.adjustConfirmAbove, the officer's citizenid typed. Opens with the points and reason last given.
export function AwardPointsForm({
    officer,
    control,
    onCancel,
    onDone,
}: {
    officer: PanelOfficer;
    control: AwardPointsControl;
    onCancel: () => void;
    // the reply carries the officer's fresh activity
    onDone: (reply: unknown) => void;
}) {
    const { run, busy } = useAction();
    const [points, setPoints] = useState<number | null>(control.min ?? 1);
    const [reason, setReason] = useState('');
    const [confirm, setConfirm] = useState('');
    useEffect(() => {
        const last = lastUsed('award');
        const min = control.min ?? 1;
        setReason(last.reason ?? '');
        setConfirm('');
        setPoints(startNumber(last.number, min, control.max, min));
    }, [officer.citizenid, control.min, control.max]);

    const left = control.perDay !== undefined ? control.perDay - (control.usedToday ?? 0) : undefined;
    const needsConfirm = !!control.confirmAbove && (points ?? 0) >= control.confirmAbove;
    const blocked =
        busy ||
        reason.trim() === '' ||
        !points ||
        points < control.min ||
        points > control.max ||
        (left !== undefined && points > left) ||
        (needsConfirm && confirm.trim() !== officer.citizenid);

    const submit = async () => {
        if (blocked) return;
        const res = await run(
            'server:sup:awardPoints',
            {
                citizenid: officer.citizenid,
                points,
                reason: reason.trim(),
                confirm: needsConfirm ? confirm.trim() : undefined,
                activityOf: officer.citizenid,
            },
            { success: 'sup.award.done' },
        );
        if (!res.ok) return;
        keepLastUsed('award', { number: points ?? undefined, reason });
        onDone(res.data);
    };

    return (
        <>
            <p className="sup-cd-note">{t('sup.award.text')}</p>
            {control.perDay !== undefined ? (
                <p className="sup-cd-note">
                    {t('sup.award.mine_used', { used: control.usedToday ?? 0, n: control.perDay })}
                </p>
            ) : null}
            <Field label={t('sup.award.points', { min: control.min, max: control.max })} required>
                <NumberInput value={points} onChange={setPoints} min={control.min} max={control.max} />
            </Field>
            <Field label={t('sup.award.reason')} required>
                <Textarea value={reason} onChange={setReason} maxLength={255} rows={2} />
            </Field>
            {needsConfirm ? (
                <Field label={t('sup.award.confirm_label', { word: officer.citizenid })} required>
                    <TextInput value={confirm} onChange={setConfirm} maxLength={50} />
                </Field>
            ) : null}
            <FormButtons onCancel={onCancel}>
                <Button
                    variant="primary"
                    size="sm"
                    icon="medal"
                    loading={busy}
                    disabled={blocked}
                    onClick={() => void submit()}
                >
                    {t('sup.award.confirm')}
                </Button>
            </FormButtons>
        </>
    );
}

// Mission ban (Config.MissionControls.controls.missionBan): hours (the admin's min to max) and a reason, or Lift for
// the ban the viewer may lift. A new ban opens with the hours and reason last used.
export function MissionBanForm({
    officer,
    control,
    state,
    onCancel,
    onDone,
}: {
    officer: PanelOfficer;
    control: MissionBanControl;
    state: MissionBanState | null;
    onCancel: () => void;
    onDone: (reply: unknown) => void;
}) {
    const { run, busy } = useAction();
    const [hours, setHours] = useState<number | null>(control.min ?? 1);
    const [reason, setReason] = useState('');
    const lifting = !!state;
    useEffect(() => {
        const last = lifting ? {} : lastUsed('ban');
        const min = control.min ?? 1;
        setReason(last.reason ?? '');
        setHours(startNumber(last.number, min, control.max, min));
    }, [officer.citizenid, control.min, control.max, lifting]);

    const used = control.perDay !== undefined && (control.usedToday ?? 0) >= control.perDay;
    const blocked =
        busy || reason.trim() === '' || (lifting ? !control.canLift : used || !hours || hours < control.min);

    const submit = async () => {
        if (blocked) return;
        const activityOf = officer.citizenid;
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
        if (!lifting) keepLastUsed('ban', { number: hours ?? undefined, reason });
        onDone(res.data);
    };

    return (
        <>
            <p className="sup-cd-note">
                {lifting && state
                    ? t('sup.ban.state', { time: formatDateTime(state.until), by: state.by })
                    : t('sup.ban.text')}
            </p>
            {!lifting ? (
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
            {lifting && !control.canLift ? <p className="sup-cd-note">{t('sup.ban.not_yours')}</p> : null}
            <Field label={t('sup.ban.reason')} required>
                <Textarea value={reason} onChange={setReason} maxLength={255} rows={2} />
            </Field>
            <FormButtons onCancel={onCancel}>
                <Button
                    variant={lifting ? 'primary' : 'danger'}
                    size="sm"
                    icon={lifting ? 'check' : 'xCircle'}
                    loading={busy}
                    disabled={blocked}
                    onClick={() => void submit()}
                >
                    {t(lifting ? 'sup.ban.lift' : 'sup.ban.confirm')}
                </Button>
            </FormButtons>
        </>
    );
}

function CooldownRow({
    label,
    left,
    fetchKey,
    disabled,
    onClear,
}: {
    label: string;
    left: number;
    fetchKey: number;
    disabled: boolean;
    onClear: () => void;
}) {
    return (
        <li className="sup-cd-row">
            <span className="sup-cd-row__label">{label}</span>
            <Countdown seconds={left} resetKey={fetchKey} />
            <Button size="sm" variant="secondary" icon="refresh" disabled={disabled} onClick={onClear}>
                {t('sup.cd.clear')}
            </Button>
        </li>
    );
}

// Clear cooldown (Config.MissionControls.controls.clearCooldown): the officer's current type and mission cooldowns
// (sup:getOfficerCooldowns), each with Clear; a reason is required (the one last used to start with). The server
// refuses the supervisor's own character, an officer on a run, the officer's daily clears (all staff) and the
// supervisor's own clears a day.
export function ClearCooldownForm({
    officer,
    onCancel,
    onCleared,
}: {
    officer: PanelOfficer;
    onCancel: () => void;
    onCleared?: () => void;
}) {
    const { data, loading, error, refetch, setData } = useRequest<OfficerCooldowns>('sup:getOfficerCooldowns', {
        citizenid: officer.citizenid,
    });
    const { run, busy } = useAction();
    const [reason, setReason] = useState('');
    const [fetchKey, setFetchKey] = useState(0);
    useEffect(() => {
        if (data) setFetchKey(k => k + 1);
    }, [data]);
    useEffect(() => setReason(lastUsed('cooldown').reason ?? ''), [officer.citizenid]);

    const current = data && data.citizenid === officer.citizenid ? data : null;
    if (loading && !current) return <LoadingBlock />;
    if (error && !current) return <ErrorState compact error={error} onRetry={() => void refetch()} />;
    if (!current) return null;
    const types = asList(current.cooldowns?.types);
    const missions = asList(current.cooldowns?.missions);
    const now = current.serverTime ?? Math.floor(Date.now() / 1000);
    const mine = current.mine ?? null;
    const officerFull = current.clears.used >= current.clears.max;
    const mineFull = !!mine && mine.perDay !== undefined && (mine.usedToday ?? 0) >= mine.perDay;
    const blocked = busy || current.onRun || officerFull || mineFull || reason.trim() === '';

    const clear = async (scope: 'type' | 'mission', key: string) => {
        if (reason.trim() === '') return;
        const res = await run(
            'server:sup:clearCooldowns',
            { citizenid: officer.citizenid, scope, key, reason: reason.trim() },
            { success: 'sup.cd.cleared' },
        );
        if (!res.ok) return;
        keepLastUsed('cooldown', { reason });
        onCleared?.();
        // the reply carries the fresh list (an older server: ask for it)
        applyReplyView<OfficerCooldowns>(res.data, 'view', setData, () => void refetch());
    };

    return (
        <>
            <p className="sup-cd-note">{t('sup.cd.text')}</p>
            <p className="sup-cd-note">
                {t('sup.cd.officer_used', { used: current.clears.used, max: current.clears.max })}
                {mine && mine.perDay !== undefined
                    ? ` · ${t('sup.cd.mine_used', { used: mine.usedToday ?? 0, n: mine.perDay })}`
                    : ''}
            </p>
            {current.onRun ? <p className="sup-cd-note is-warning">{t('sup.cd.on_run')}</p> : null}
            {types.length === 0 && missions.length === 0 ? (
                <EmptyState compact icon="clock" title={t('sup.cd.none')} />
            ) : null}
            {types.length > 0 ? (
                <>
                    <h4 className="sup-cd-head">{t('sup.cd.types')}</h4>
                    <ul className="sup-cd-list">
                        {types.map(c => (
                            <CooldownRow
                                key={c.key}
                                label={c.label}
                                left={Math.max(0, c.until - now)}
                                fetchKey={fetchKey}
                                disabled={blocked}
                                onClear={() => void clear('type', c.key)}
                            />
                        ))}
                    </ul>
                </>
            ) : null}
            {missions.length > 0 ? (
                <>
                    <h4 className="sup-cd-head">{t('sup.cd.missions')}</h4>
                    <ul className="sup-cd-list">
                        {missions.map(c => (
                            <CooldownRow
                                key={c.id}
                                label={c.label}
                                left={Math.max(0, c.until - now)}
                                fetchKey={fetchKey}
                                disabled={blocked}
                                onClear={() => void clear('mission', c.id)}
                            />
                        ))}
                    </ul>
                </>
            ) : null}
            <Field label={t('sup.cd.reason')} required>
                <Textarea value={reason} onChange={setReason} maxLength={255} rows={2} />
            </Field>
            <FormButtons onCancel={onCancel} />
        </>
    );
}

// Field training (Config.Recognition.fieldTraining) for this officer: his training as a rookie with End training (two clicks);
// a rookie paired with a trainer picked here; a trainer given a rookie picked here (with the rookies he trains). The
// same server actions as Department → Training (server:sup:ftoPair, server:sup:ftoUnpair).
export function FieldTrainingForm({
    officer,
    fto,
    role,
    onCancel,
    onDone,
}: {
    officer: PanelOfficer;
    fto: FtoDept;
    role: Exclude<FtoRole, null>;
    onCancel: () => void;
    onDone: () => void;
}) {
    const { run, busy } = useAction();
    const [other, setOther] = useState('');
    useEffect(() => setOther(''), [officer.citizenid, role.kind]);

    const end = async (rookie: string) => {
        const res = await run('server:sup:ftoUnpair', { rookie }, { success: 'fto.unpaired_toast' });
        if (res.ok) onDone();
    };
    const pair = async () => {
        if (!other) return;
        const args =
            role.kind === 'candidate'
                ? { rookie: officer.citizenid, trainer: other }
                : { rookie: other, trainer: officer.citizenid };
        const res = await run('server:sup:ftoPair', args, { success: 'fto.paired_toast' });
        if (!res.ok) return;
        setOther('');
        onDone();
    };

    if (role.kind === 'rookie') {
        const v = role.view;
        return (
            <>
                <p className="profile-commend__head">
                    <span className="profile-commend__by">
                        {t('fto.trainer')}: {v.trainer.name}
                    </span>
                    <FtoProgress view={v} />
                    {!v.doneAt ? (
                        <ConfirmButton
                            size="sm"
                            variant="ghost"
                            icon="x"
                            loading={busy}
                            label={t('fto.unpair')}
                            confirmLabel={t('fto.unpair_confirm')}
                            onConfirm={() => void end(v.rookie.citizenid)}
                        />
                    ) : null}
                </p>
                <FtoTaskList view={v} />
                <FormButtons onCancel={onCancel} />
            </>
        );
    }
    const options =
        role.kind === 'candidate'
            ? asList(fto.trainers)
                  .filter(o => o.citizenid !== officer.citizenid)
                  .map(o => ({ value: o.citizenid, label: o.rank ? `${o.name} · ${o.rank}` : o.name }))
            : asList(fto.candidates)
                  .filter(o => o.citizenid !== officer.citizenid)
                  .map(o => ({ value: o.citizenid, label: o.callsign ? `${o.name} · ${o.callsign}` : o.name }));
    return (
        <>
            <p className="sup-cd-note">{t('fto.pair_text', { grade: fto.trainerGrade, n: fto.rookiesPerTrainer })}</p>
            {role.kind === 'candidate' && role.done ? (
                <p className="profile-commend__head">
                    <span className="profile-commend__by">
                        {t('fto.trainer')}: {role.done.trainer.name}
                    </span>
                    <FtoProgress view={role.done} />
                </p>
            ) : null}
            {role.kind === 'trainer' && role.rookies.length ? (
                <ul className="sup-cd-list">
                    {role.rookies.map(v => (
                        <li key={v.rookie.citizenid} className="sup-cd-row">
                            <span className="sup-cd-row__label">{v.rookie.name}</span>
                            <FtoProgress view={v} />
                        </li>
                    ))}
                </ul>
            ) : null}
            <Field
                label={t(role.kind === 'candidate' ? 'fto.trainer' : 'fto.rookie')}
                required
                hint={
                    options.length
                        ? undefined
                        : t(role.kind === 'candidate' ? 'fto.no_trainers' : 'sup.panel.no_rookies')
                }
            >
                <Select value={other} onChange={setOther} placeholder={t('fto.pick')} options={options} />
            </Field>
            <FormButtons onCancel={onCancel}>
                <Button
                    variant="primary"
                    size="sm"
                    icon="check"
                    loading={busy}
                    disabled={!other}
                    onClick={() => void pair()}
                >
                    {t('fto.pair')}
                </Button>
            </FormButtons>
        </>
    );
}
