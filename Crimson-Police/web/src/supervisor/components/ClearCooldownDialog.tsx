// Supervisor UI · Department Report · Clear cooldown (step P7, Config.MissionControls.controls.clearCooldown): the
// officer's current type and mission cooldowns (sup:getOfficerCooldowns), each with Clear; a reason is required.

import { useEffect, useState } from 'react';
import {
    Button,
    Countdown,
    Dialog,
    EmptyState,
    ErrorState,
    Field,
    LoadingBlock,
    Textarea,
} from '../../shared/components';
import { useAction, useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { asList, type OfficerCooldowns } from '../../types/boards';

interface Target {
    scope: 'type' | 'mission';
    key: string;
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

export function ClearCooldownDialog({
    officer,
    onClose,
}: {
    officer: { citizenid: string; name: string } | null;
    onClose: () => void;
}) {
    const { data, loading, error, refetch } = useRequest<OfficerCooldowns>(
        'sup:getOfficerCooldowns',
        { citizenid: officer?.citizenid },
        { skip: !officer },
    );
    const { run, busy } = useAction();
    const [reason, setReason] = useState('');
    const [fetchKey, setFetchKey] = useState(0);
    useEffect(() => {
        if (data) setFetchKey(k => k + 1);
    }, [data]);
    useEffect(() => setReason(''), [officer?.citizenid]);

    const current = data && data.citizenid === officer?.citizenid ? data : null;
    const types = asList(current?.cooldowns?.types);
    const missions = asList(current?.cooldowns?.missions);
    const now = current?.serverTime ?? Math.floor(Date.now() / 1000);
    const mine = current?.mine ?? null;
    const officerFull = !!current && current.clears.used >= current.clears.max;
    const mineFull = !!mine && mine.perDay !== undefined && (mine.usedToday ?? 0) >= mine.perDay;
    const blocked = busy || !current || current.onRun || officerFull || mineFull || reason.trim() === '';

    const clear = async (target: Target) => {
        if (!officer || reason.trim() === '') return;
        const res = await run(
            'server:sup:clearCooldowns',
            { citizenid: officer.citizenid, scope: target.scope, key: target.key, reason: reason.trim() },
            { success: 'sup.cd.cleared' },
        );
        if (res.ok) void refetch();
    };

    let body;
    if (loading && !current) body = <LoadingBlock />;
    else if (error && !current) body = <ErrorState compact error={error} onRetry={() => void refetch()} />;
    else if (!current) body = null;
    else
        body = (
            <>
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
                                    onClear={() => void clear({ scope: 'type', key: c.key })}
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
                                    onClear={() => void clear({ scope: 'mission', key: c.id })}
                                />
                            ))}
                        </ul>
                    </>
                ) : null}
                <Field label={t('sup.cd.reason')} required>
                    <Textarea value={reason} onChange={setReason} maxLength={255} rows={2} />
                </Field>
            </>
        );

    return (
        <Dialog
            open={!!officer}
            onClose={onClose}
            size="md"
            title={officer ? t('sup.cd.title', { name: officer.name }) : ''}
            description={t('sup.cd.text')}
            footer={
                <Button variant="primary" onClick={onClose}>
                    {t('common.close')}
                </Button>
            }
        >
            {body}
        </Dialog>
    );
}
