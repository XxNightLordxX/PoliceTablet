// Commend an officer: a kind, a citation (10–255 characters) and optionally the run it is for. Supervisors use
// server:sup:commend (own department, never themselves or their own run, 3 a day), admins server:admin:commend.

import { useEffect, useState } from 'react';
import { Button, Dialog, Field, Select, Textarea } from '../../shared/components';
import { useAction } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { useSession } from '../../shared/session';
import { commendationKindLabel } from '../../officer/components/CommendationsCard';

export interface CommendDialogProps {
    open: boolean;
    onClose: () => void;
    officer: { citizenid: string; name: string } | null;
    scope: 'sup' | 'admin';
    // runs the officer took part in that the commendation may be for (optional)
    runs?: { runUuid: string; label: string }[];
    onDone?: () => void;
}

const CITATION_MIN = 10;
const CITATION_MAX = 255;

export function CommendDialog({ open, onClose, officer, scope, runs, onDone }: CommendDialogProps) {
    const session = useSession();
    const kinds = Array.isArray(session.config?.commendationKinds) ? session.config.commendationKinds : [];
    const [kind, setKind] = useState<string>(kinds[0] ?? '');
    const [citation, setCitation] = useState<string>('');
    const [runUuid, setRunUuid] = useState<string>('');
    const { run, busy } = useAction();

    useEffect(() => {
        if (!open) return;
        setKind(kinds[0] ?? '');
        setCitation('');
        setRunUuid('');
    }, [open, officer?.citizenid]);

    const len = [...citation.trim()].length;
    const valid = !!officer && kind !== '' && len >= CITATION_MIN && len <= CITATION_MAX;

    async function send() {
        if (!officer || !valid) return;
        const res = await run(
            scope === 'admin' ? 'server:admin:commend' : 'server:sup:commend',
            { citizenid: officer.citizenid, kind, citation: citation.trim(), runUuid: runUuid || undefined },
            { success: 'profile.commend.sent', successVars: { name: officer.name } },
        );
        if (!res.ok) return;
        onDone?.();
        onClose();
    }

    return (
        <Dialog
            open={open}
            onClose={onClose}
            title={t('profile.commend.dialog_title', { name: officer?.name ?? '' })}
            description={t('profile.commend.dialog_text')}
            size="sm"
            footer={
                <>
                    <Button variant="ghost" onClick={onClose}>
                        {t('common.cancel')}
                    </Button>
                    <Button variant="primary" icon="medal" loading={busy} disabled={!valid} onClick={() => void send()}>
                        {t('profile.commend.give')}
                    </Button>
                </>
            }
        >
            <Field label={t('profile.commend.kind')}>
                <Select
                    value={kind}
                    onChange={setKind}
                    options={kinds.map(k => ({ value: k, label: commendationKindLabel(k) }))}
                />
            </Field>
            <Field
                label={t('profile.commend.citation')}
                hint={t('profile.commend.citation_hint', { min: CITATION_MIN, max: CITATION_MAX })}
            >
                <Textarea value={citation} onChange={setCitation} maxLength={CITATION_MAX} rows={3} />
            </Field>
            {runs && runs.length ? (
                <Field label={t('profile.commend.run')} hint={t('profile.commend.run_hint')}>
                    <Select
                        value={runUuid}
                        onChange={setRunUuid}
                        placeholder={t('profile.commend.run_none')}
                        options={runs.map(r => ({ value: r.runUuid, label: r.label }))}
                    />
                </Field>
            ) : null}
        </Dialog>
    );
}

export default CommendDialog;
