// The unit ready check: "Ready for Tactical?" with a countdown, Ready / Not ready (the type only, never a mission).

import { useEffect, useState } from 'react';
import { Badge, Button, Countdown, Icon } from '../../shared/components';
import { useAction, usePush } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import type { ReadyCheckView, UnitPushData } from '../../types/teams';
import './ReadyCheckBanner.css';

export interface ReadyCheckBannerProps {
    // The check from getUnit (Unit screen); without it the banner follows the 'unit' push only.
    check?: ReadyCheckView | null;
    onAnswered?: () => void;
}

function asList(v: unknown): number[] {
    return Array.isArray(v) ? v.map(Number) : [];
}

export function ReadyCheckBanner({ check, onAnswered }: ReadyCheckBannerProps) {
    // undefined = nothing pushed since the last prop; null = the push cleared the check
    const [pushed, setPushed] = useState<ReadyCheckView | null | undefined>(undefined);
    const [busy, setBusy] = useState<'yes' | 'no' | null>(null);
    const { run } = useAction();

    useEffect(() => setPushed(undefined), [check]);
    usePush<UnitPushData>('unit', data => setPushed(data?.readyCheck ?? null));

    const current = pushed !== undefined ? pushed : (check ?? null);
    if (!current) return null;
    const ready = asList(current.ready);
    const waiting = asList(current.waiting);
    const total = ready.length + waiting.length;

    const answer = async (accepted: boolean) => {
        setBusy(accepted ? 'yes' : 'no');
        try {
            await run('server:unitReady', { accepted });
        } finally {
            setBusy(null);
            onAnswered?.();
        }
    };

    return (
        <div className="ready-check" role="alertdialog" aria-live="assertive">
            <span className="ready-check__icon" aria-hidden>
                <Icon name="users" size={20} />
            </span>
            <div className="ready-check__main">
                <div className="ready-check__title">{t('unit.ui.ready_title', { type: current.typeLabel })}</div>
                <div className="ready-check__text">
                    {current.waitingForMe
                        ? t('unit.ui.ready_text')
                        : t('unit.ui.ready_waiting', { n: waiting.length, total })}
                </div>
            </div>
            <Badge size="sm" tone="neutral">
                {t('unit.ui.ready_count', { ready: ready.length, total })}
            </Badge>
            <span className="ready-check__timer">
                <Icon name="clock" size={14} />
                <Countdown seconds={current.expiresIn} resetKey={current} warnBelow={10} dangerBelow={5} />
            </span>
            {current.waitingForMe ? (
                <div className="ready-check__actions">
                    <Button
                        size="sm"
                        variant="ghost"
                        icon="x"
                        loading={busy === 'no'}
                        disabled={!!busy}
                        onClick={() => void answer(false)}
                    >
                        {t('unit.ui.ready_no')}
                    </Button>
                    <Button
                        size="sm"
                        variant="primary"
                        icon="check"
                        loading={busy === 'yes'}
                        disabled={!!busy}
                        onClick={() => void answer(true)}
                    >
                        {t('unit.ui.ready_yes')}
                    </Button>
                </div>
            ) : null}
        </div>
    );
}

export default ReadyCheckBanner;
