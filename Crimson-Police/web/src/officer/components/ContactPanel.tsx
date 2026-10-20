// Active Mission · Contact panel: every person and car of the current contact objective, its facts, the checks
// still open, the police actions and the dispositions (CP.Custody.view; decisions go to server:contactDecide).

import { useEffect, useState } from 'react';
import { Badge, Button, Card, ConfirmDialog, Icon, Select } from '../../shared/components';
import type { IconName } from '../../shared/components';
import { cx } from '../../shared/cx';
import { asArray } from '../../shared/data';
import { fmtDateTime, formatDistance } from '../../shared/format';
import { useAction, usePush } from '../../shared/hooks';
import { t, tOr } from '../../shared/i18n';
import { clientAction } from '../../shared/nui';
import { toast } from '../../shared/toast';
import type {
    ContactActionPayload,
    ContactConfirm,
    ContactDecidePayload,
    ContactDecideResult,
    ContactEntry,
    ContactFact,
    ContactView,
} from '../../types/custody';
import './ContactPanel.css';

// Actions the panel can start (the rest are ox_target options on the ped or car).
const PANEL_ACTIONS = new Set([
    'talk',
    'frisk',
    'detain',
    'searchPerson',
    'lookInside',
    'runPlate',
    'inspect',
    'orderOut',
    'searchVehicle',
    'explain',
    'escort',
]);
const CHOICE_ICON: Record<string, IconName> = {
    release: 'check',
    warn: 'info',
    cite: 'fileText',
    arrest: 'gavel',
    noAction: 'checkCircle',
    impound: 'truck',
};

interface Pending {
    netId: number;
    choice: string;
    factKey: string | null;
    // the offence picked for a citation, sent again with the confirm
    offence?: string;
}

function FactRow({ f }: { f: ContactFact }) {
    return (
        <li className={cx('cp-contact__fact', f.suppressed && 'is-suppressed')}>
            <span className="cp-contact__fact-text">{f.text}</span>
            <span className="cp-contact__fact-tags">
                {f.suppressed ? (
                    <Badge tone="danger" size="sm">
                        {t('custody.panel.inadmissible')}
                    </Badge>
                ) : null}
                {f.cause && !f.suppressed ? (
                    <Badge tone="accent" size="sm">
                        {t('custody.panel.cause')}
                    </Badge>
                ) : null}
                {f.by ? (
                    <span className="cp-contact__fact-by">
                        {t('custody.panel.found_by', { by: f.by, at: fmtDateTime(f.at) })}
                    </span>
                ) : null}
            </span>
        </li>
    );
}

function EntryCard({
    e,
    cause,
    busy,
    onAction,
    onChoice,
}: {
    e: ContactEntry;
    cause: boolean | undefined;
    busy: boolean;
    onAction: (netId: number, action: string) => void;
    onChoice: (e: ContactEntry, choice: string, offence: string | undefined, failsCase: boolean) => void;
}) {
    const offences = asArray(e.offences);
    const [offence, setOffence] = useState<string>(offences[0]?.id ?? '');
    const actions = asArray(e.actions).filter(a => PANEL_ACTIONS.has(a));
    const choices = asArray(e.choices);
    const vehicle = e.kind === 'vehicle';
    return (
        <li className={cx('cp-contact__entry', e.decided && 'is-decided')}>
            <div className="cp-contact__head">
                <span className="cp-contact__label">
                    <Icon name={vehicle ? 'car' : 'user'} size={14} />
                    {t(vehicle ? 'custody.panel.vehicle' : 'custody.panel.person', { label: e.label })}
                </span>
                <span className="cp-contact__badges">
                    <Badge tone="neutral" size="sm">
                        {tOr(`custody.state.${e.state}`, 'custody.state.other')}
                    </Badge>
                    {e.freeToLeave ? (
                        <Badge tone="success" size="sm">
                            {t('custody.panel.free_to_leave')}
                        </Badge>
                    ) : null}
                    {e.tellSeen ? (
                        <Badge tone="warning" size="sm" icon="alert">
                            {tOr(`custody.tell.${e.tellSeen}`, 'custody.tell.hands')}
                        </Badge>
                    ) : null}
                    {vehicle && cause !== undefined ? (
                        <Badge tone={cause ? 'accent' : 'neutral'} size="sm">
                            {t(cause ? 'custody.panel.probable_cause' : 'custody.panel.no_cause')}
                        </Badge>
                    ) : null}
                </span>
            </div>
            {asArray(e.facts).length > 0 ? (
                <ul className="cp-contact__facts">
                    {asArray(e.facts).map(f => (
                        <FactRow key={f.key} f={f} />
                    ))}
                </ul>
            ) : (
                <p className="cp-contact__empty">{t('custody.panel.facts_none')}</p>
            )}
            {asArray(e.notChecked).length > 0 && !e.decided ? (
                <div className="cp-contact__open">
                    <span>{t('custody.panel.not_checked')}</span>
                    {asArray(e.notChecked).map(k => (
                        <Badge key={k} tone="neutral" variant="outline" size="sm">
                            {tOr(`custody.check.${k}`, 'custody.check.other')}
                        </Badge>
                    ))}
                </div>
            ) : null}
            {e.decided ? (
                <div className="cp-contact__decided">
                    <Icon name="checkCircle" size={14} />
                    {t('custody.panel.decided', {
                        choice: tOr(`custody.choice.${e.decided.choice}`, 'custody.choice.none'),
                        by: e.decided.by,
                    })}
                </div>
            ) : null}
            {actions.length > 0 ? (
                <div className="cp-contact__actions">
                    {actions.map(a => (
                        <Button
                            key={a}
                            size="sm"
                            variant="secondary"
                            disabled={busy}
                            onClick={() => onAction(e.netId, a)}
                        >
                            {t(`custody.action.${a}`)}
                        </Button>
                    ))}
                </div>
            ) : null}
            {choices.length > 0 ? (
                <div className="cp-contact__choices">
                    {choices.some(c => c.id === 'cite') && offences.length > 0 ? (
                        <Select
                            value={offence}
                            onChange={setOffence}
                            options={offences.map(o => ({ value: o.id, label: o.label }))}
                            aria-label={t('custody.panel.offence')}
                        />
                    ) : null}
                    {choices.map(c => (
                        <Button
                            key={c.id}
                            size="sm"
                            variant={c.failsCase ? 'danger' : 'primary'}
                            icon={CHOICE_ICON[c.id]}
                            disabled={busy}
                            onClick={() =>
                                onChoice(e, c.id, c.id === 'cite' ? offence || undefined : undefined, c.failsCase)
                            }
                        >
                            {c.label}
                        </Button>
                    ))}
                </div>
            ) : null}
        </li>
    );
}

export function ContactPanel({ view, runId }: { view: ContactView; runId: string }) {
    const { run, busy } = useAction();
    const [pending, setPending] = useState<Pending | null>(null);
    const entries = asArray(view.entries);

    // an ox_target choice that would fail the case: the server sends it here instead of deciding
    usePush<ContactConfirm | null>('contactConfirm', data => {
        if (data && typeof data.netId === 'number') setPending({ ...data, factKey: data.factKey ?? null });
    });
    useEffect(() => {
        const waiting = entries.find(e => e.confirm && !e.decided);
        if (waiting && waiting.confirm && !pending) {
            setPending({ netId: waiting.netId, choice: waiting.confirm.choice, factKey: null });
        }
        // only when the server view changes
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [view]);

    const act = async (netId: number, action: string) => {
        const payload: ContactActionPayload = { netId, action };
        const res = await clientAction('contactAction', payload);
        if (!res.ok && res.error !== 'err.cancelled') toast('error', t(res.error || 'err.internal'));
    };

    const decide = async (netId: number, choice: string, offence: string | undefined, confirmed: boolean) => {
        const payload: ContactDecidePayload = { runId, netId, choice, offence, confirmed };
        const res = await run<ContactDecideResult>('server:contactDecide', payload);
        if (res.ok && res.data && res.data.confirm) {
            setPending({ netId, choice, factKey: res.data.confirm.factKey ?? null, offence });
            return;
        }
        setPending(null);
    };

    const choose = (e: ContactEntry, choice: string, offence: string | undefined, failsCase: boolean) => {
        if (failsCase) {
            setPending({ netId: e.netId, choice, factKey: null, offence });
            return;
        }
        void decide(e.netId, choice, offence, false);
    };

    const transport = view.transport;
    const pendingEntry = pending ? entries.find(e => e.netId === pending.netId) : undefined;

    return (
        <Card
            highlight="accent"
            icon="idCard"
            className="cp-contact"
            title={t('custody.panel.title')}
            subtitle={t('custody.panel.subtitle')}
            actions={
                transport ? (
                    <Badge tone={transport.status === 'parked' ? 'success' : 'neutral'} icon="truck">
                        {t(`custody.panel.transport.${transport.status}`)}
                        {transport.distance !== null && transport.distance !== undefined
                            ? ` · ${formatDistance(transport.distance)}`
                            : ''}
                    </Badge>
                ) : null
            }
        >
            <div className="cp-contact__hud">
                {['runPlateFromVehicle', 'seat', 'handover'].map(a => (
                    <Button key={a} size="sm" variant="ghost" disabled={busy} onClick={() => void act(0, a)}>
                        {t(`custody.action.${a}`)}
                    </Button>
                ))}
            </div>
            <ul className="cp-contact__list">
                {entries.map(e => (
                    <EntryCard
                        key={e.netId}
                        e={e}
                        cause={e.kind === 'vehicle' ? view.probableCause?.[e.netId] : undefined}
                        busy={busy}
                        onAction={(netId, a) => void act(netId, a)}
                        onChoice={choose}
                    />
                ))}
            </ul>
            <ConfirmDialog
                open={pending !== null}
                tone="danger"
                title={t('custody.panel.confirm_title', { label: pendingEntry?.label ?? '' })}
                message={
                    <p>
                        {pending?.factKey
                            ? tOr(`custody.confirm.${pending.factKey}`, 'custody.confirm.nil')
                            : t('custody.confirm.nil')}
                    </p>
                }
                confirmLabel={t('custody.panel.confirm_button', {
                    choice: pending ? tOr(`custody.choice.${pending.choice}`, 'custody.choice.none') : '',
                })}
                onConfirm={() => (pending ? decide(pending.netId, pending.choice, pending.offence, true) : undefined)}
                onCancel={() => setPending(null)}
                busy={busy}
            />
        </Card>
    );
}

export default ContactPanel;
