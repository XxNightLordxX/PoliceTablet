// Slot: Officers → officer detail → Support: check why the tablet won't open, give the tablet item, release a stuck
// screen and show what holds it. Every action is checked again on the server (admins only, rate limits, audit).

import { useState } from 'react';
import { Badge, Button, Card, ConfirmDialog, Icon } from '../../shared/components';
import { hasKey, t } from '../../shared/i18n';
import { request } from '../../shared/nui';
import { toast } from '../../shared/toast';
import type { OfficerSlotProps } from '../../types/admin_control';
import type { CheckAccessResult, ClientStateView } from '../../types/admin_system';
import { useAdminAction } from './kit';
import '../screens/System.css';

function errText(key?: string): string {
    if (!key) return '';
    return hasKey(key) ? t(key) : key;
}

function yesNo(v: unknown): string {
    if (v === undefined || v === null) return '?';
    if (typeof v === 'boolean') return t(v ? 'sysadmin.ui.yes' : 'sysadmin.ui.no');
    return String(v);
}

const STATE_KEYS: (keyof ClientStateView)[] = [
    'screen',
    'nuiFocus',
    'tabletOpen',
    'panel',
    'pickup',
    'run',
    'scriptCam',
    'playerControl',
    'frozen',
    'dead',
    'lastStand',
    'metaDead',
    'inVehicle',
    'pauseMenu',
];

export function OfficerSupport({ citizenid, online }: OfficerSlotProps) {
    const { run, busy } = useAdminAction();
    const [check, setCheck] = useState<CheckAccessResult | null>(null);
    const [state, setState] = useState<ClientStateView | null>(null);
    const [giving, setGiving] = useState(false);
    const [releasing, setReleasing] = useState(false);
    const [loading, setLoading] = useState<'check' | 'state' | null>(null);

    const doCheck = async () => {
        setLoading('check');
        const res = await request<CheckAccessResult>('admin:checkAccess', { citizenid });
        setLoading(null);
        if (res.ok && res.data) setCheck(res.data);
        else toast('error', errText(res.error || 'err.internal'));
    };
    const doState = async () => {
        setLoading('state');
        const res = await request<ClientStateView>('admin:getClientState', { citizenid });
        setLoading(null);
        if (res.ok && res.data) setState(res.data);
        else toast('error', errText(res.error || 'err.internal'));
    };
    const doGive = async (reason: string) => {
        await run(
            'server:admin:giveTabletItem',
            { citizenid, reason },
            { requestId: false, success: 'sysadmin.ui.item_given' },
        );
        setGiving(false);
    };
    const doRelease = async () => {
        await run(
            'server:admin:releaseScreen',
            { citizenid },
            { requestId: false, success: 'sysadmin.ui.screen_released' },
        );
        setReleasing(false);
    };

    return (
        <Card title={t('sysadmin.ui.support_title')} icon="tool" subtitle={t('sysadmin.ui.support_subtitle')}>
            {!online ? <div className="system-muted">{t('sysadmin.ui.support_offline')}</div> : null}
            <div className="system-buttons">
                <Button
                    size="sm"
                    icon="search"
                    disabled={!online || busy}
                    loading={loading === 'check'}
                    onClick={() => void doCheck()}
                >
                    {t('sysadmin.ui.check_access')}
                </Button>
                <Button size="sm" icon="gift" disabled={!online || busy} onClick={() => setGiving(true)}>
                    {t('sysadmin.ui.give_item')}
                </Button>
                <Button
                    size="sm"
                    icon="eye"
                    disabled={!online || busy}
                    loading={loading === 'state'}
                    onClick={() => void doState()}
                >
                    {t('sysadmin.ui.show_state')}
                </Button>
                <Button
                    size="sm"
                    variant="danger"
                    icon="undo"
                    disabled={!online || busy}
                    onClick={() => setReleasing(true)}
                >
                    {t('sysadmin.ui.release_screen')}
                </Button>
            </div>
            {check ? (
                <div className="system-stack">
                    <ul className="system-steps-list">
                        {check.steps.map(s => (
                            <li key={s.check} className={s.ok ? 'system-step--ok' : 'system-step--bad'}>
                                <Icon name={s.ok ? 'checkCircle' : 'xCircle'} size={13} />
                                {t(`sysadmin.ui.step.${s.check}`, s.vars)}
                            </li>
                        ))}
                    </ul>
                    {check.ok ? (
                        <Badge tone="success" icon="check">
                            {t('sysadmin.ui.access_ok')}
                        </Badge>
                    ) : (
                        <div className="system-note system-note--warning">
                            <Icon name="alert" size={14} />
                            <span>
                                <strong>{errText(check.error)}</strong> {check.fix ? errText(check.fix) : null}
                            </span>
                        </div>
                    )}
                </div>
            ) : null}
            {state ? (
                <div className="system-state">
                    {STATE_KEYS.map(k => (
                        <span key={k}>
                            {t(`sysadmin.ui.state.${k}`)}: <strong>{yesNo(state[k])}</strong>
                        </span>
                    ))}
                </div>
            ) : null}
            <ConfirmDialog
                open={giving}
                title={t('sysadmin.ui.give_item')}
                message={t('sysadmin.ui.give_item_text')}
                reason
                confirmLabel={t('sysadmin.ui.give_item')}
                onConfirm={doGive}
                onCancel={() => setGiving(false)}
                busy={busy}
            />
            <ConfirmDialog
                open={releasing}
                tone="danger"
                title={t('sysadmin.ui.release_screen')}
                message={t('sysadmin.ui.release_text')}
                confirmLabel={t('sysadmin.ui.release_screen')}
                onConfirm={doRelease}
                onCancel={() => setReleasing(false)}
                busy={busy}
            />
        </Card>
    );
}
