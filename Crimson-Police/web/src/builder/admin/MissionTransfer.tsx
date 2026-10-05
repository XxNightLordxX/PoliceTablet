// Moving missions between servers and owners: Copy as Lua (the published file as text), Import (a preview, then a
// new draft that is never published by the import) and Change owner.

import { useRef, useState } from 'react';
import {
    Badge,
    Button,
    Dialog,
    EmptyState,
    Field,
    Icon,
    LoadingBlock,
    Textarea,
    TextInput,
} from '../../shared/components';
import { useRequest } from '../../shared/hooks';
import { request } from '../../shared/nui';
import { t } from '../../shared/i18n';
import { toast } from '../../shared/toast';
import { OfficerPicker, useAdminAction } from '../../admin/components/kit';
import type { ImportPreview, MissionLuaExport } from '../../types/admin_missions';

const IMPORT_MAX = 262144;

// Copy into the clipboard: CEF usually refuses navigator.clipboard, so the selected textarea goes first.
async function copyText(text: string, el: HTMLTextAreaElement | null): Promise<boolean> {
    if (el) {
        el.focus();
        el.select();
        try {
            if (document.execCommand('copy')) return true;
        } catch {
            // try the async API below
        }
    }
    try {
        if (navigator.clipboard && typeof navigator.clipboard.writeText === 'function') {
            await navigator.clipboard.writeText(text);
            return true;
        }
    } catch {
        // not allowed here
    }
    return false;
}

export function CopyLuaDialog({ id, label, onClose }: { id: string | null; label: string; onClose: () => void }) {
    const exp = useRequest<MissionLuaExport>('admin:exportMissionLua', { id }, { skip: !id });
    const box = useRef<HTMLTextAreaElement | null>(null);
    return (
        <Dialog
            open={!!id}
            onClose={onClose}
            size="lg"
            title={t('admin.missions.copy.title', { mission: label })}
            description={t('admin.missions.copy.text')}
            footer={
                <>
                    <span className="cp-spacer" />
                    <Button variant="ghost" onClick={onClose}>
                        {t('common.close')}
                    </Button>
                    <Button
                        variant="primary"
                        icon="fileText"
                        disabled={!exp.data}
                        onClick={() =>
                            void copyText(exp.data?.lua ?? '', box.current).then(ok =>
                                toast(
                                    ok ? 'success' : 'info',
                                    t(ok ? 'admin.missions.copy.done' : 'admin.missions.copy.manual'),
                                ),
                            )
                        }
                    >
                        {t('admin.missions.copy.button')}
                    </Button>
                </>
            }
        >
            {exp.loading && !exp.data ? (
                <LoadingBlock />
            ) : !exp.data ? (
                <EmptyState compact icon="alert" title={t(exp.error ?? 'err.internal')} />
            ) : (
                <textarea ref={box} className="admin-missions-code" readOnly value={exp.data.lua} rows={18} />
            )}
        </Dialog>
    );
}

export function ImportDialog({
    open,
    onClose,
    onImported,
}: {
    open: boolean;
    onClose: () => void;
    onImported: (id: string) => void;
}) {
    const [lua, setLua] = useState('');
    const [reason, setReason] = useState('');
    const [preview, setPreview] = useState<ImportPreview | null>(null);
    const [error, setError] = useState<string | null>(null);
    const [checking, setChecking] = useState(false);
    const { run, busy } = useAdminAction();
    const close = () => {
        setLua('');
        setReason('');
        setPreview(null);
        setError(null);
        onClose();
    };
    const check = async () => {
        setChecking(true);
        setError(null);
        const res = await request<ImportPreview>('admin:previewImport', { lua });
        setChecking(false);
        if (res.ok && res.data) setPreview(res.data);
        else {
            setPreview(null);
            setError(res.error ?? 'err.internal');
        }
    };
    const doImport = async () => {
        if (!preview) return;
        const res = await run<{ id: string }>(
            'server:builder:importDraft',
            { previewToken: preview.previewToken, reason: reason.trim() },
            { success: 'admin.missions.import.done', successVars: { mission: preview.effect.label } },
        );
        if (res.ok && res.data) {
            const id = res.data.id;
            close();
            onImported(id);
        }
    };
    const e = preview?.effect;
    return (
        <Dialog
            open={open}
            onClose={close}
            size="lg"
            title={t('admin.missions.import.title')}
            description={t('admin.missions.import.text')}
            footer={
                <>
                    <span className="cp-spacer" />
                    <Button variant="ghost" onClick={close}>
                        {t('common.cancel')}
                    </Button>
                    {!preview ? (
                        <Button
                            variant="primary"
                            icon="search"
                            disabled={checking || !lua.trim() || lua.length > IMPORT_MAX}
                            onClick={() => void check()}
                        >
                            {t('admin.missions.import.check')}
                        </Button>
                    ) : (
                        <Button
                            variant="primary"
                            icon="download"
                            disabled={busy || !reason.trim()}
                            onClick={() => void doImport()}
                        >
                            {t('admin.missions.import.button')}
                        </Button>
                    )}
                </>
            }
        >
            <div className="admin-missions-stack">
                {!preview ? (
                    <Field label={t('admin.missions.import.lua')} error={error ? t(error) : undefined}>
                        <Textarea
                            value={lua}
                            onChange={setLua}
                            rows={14}
                            maxLength={IMPORT_MAX}
                            showCount={false}
                            className="admin-missions-code"
                        />
                    </Field>
                ) : e ? (
                    <>
                        <div className="admin-missions-kv">
                            <span>{t('admin.missions.import.label')}</span>
                            <b>{e.label}</b>
                            <span>{t('admin.missions.import.type')}</span>
                            <b>{e.type}</b>
                            {e.sourceId ? (
                                <>
                                    <span>{t('admin.missions.import.source_id')}</span>
                                    <b className="admin-missions-mono">{e.sourceId}</b>
                                </>
                            ) : null}
                            <span>{t('admin.missions.import.locations')}</span>
                            <b>{e.locations.length}</b>
                            <span>{t('admin.missions.import.objectives')}</span>
                            <b>{e.objectives.map(o => o.label || o.block).join(' → ') || '—'}</b>
                        </div>
                        {e.dropped.length ? (
                            <div className="builder_client-callout builder_client-callout--warning">
                                <Icon name="alert" size={15} />
                                <span>{t('admin.missions.import.dropped', { list: e.dropped.join(', ') })}</span>
                            </div>
                        ) : null}
                        {e.errorCount ? (
                            <ul className="builder_client-errors is-compact">
                                {e.errors.map(m => (
                                    <li key={m}>
                                        <Icon name="xCircle" size={13} />
                                        <span>{m}</span>
                                    </li>
                                ))}
                            </ul>
                        ) : (
                            <Badge size="sm" tone="success" icon="checkCircle">
                                {t('admin.missions.import.valid')}
                            </Badge>
                        )}
                        <div className="admin-missions-muted">{t('admin.missions.import.draft_only')}</div>
                        <Field label={t('admin.missions.reason')} required>
                            <TextInput value={reason} onChange={setReason} maxLength={255} />
                        </Field>
                    </>
                ) : null}
            </div>
        </Dialog>
    );
}

export function ChangeOwnerDialog({
    id,
    label,
    onClose,
    onDone,
}: {
    id: string | null;
    label: string;
    onClose: () => void;
    onDone: () => void;
}) {
    const [cid, setCid] = useState<string | null>(null);
    const [reason, setReason] = useState('');
    const { run, busy } = useAdminAction();
    const close = () => {
        setCid(null);
        setReason('');
        onClose();
    };
    const save = async () => {
        if (!id || !cid) return;
        const res = await run(
            'server:builder:changeOwner',
            { id, citizenid: cid, reason: reason.trim() },
            { success: 'admin.missions.owner.done', successVars: { mission: label, citizenid: cid } },
        );
        if (res.ok) {
            onDone();
            close();
        }
    };
    return (
        <Dialog
            open={!!id}
            onClose={close}
            size="md"
            title={t('admin.missions.owner.title', { mission: label })}
            description={t('admin.missions.owner.text')}
            footer={
                <>
                    <span className="cp-spacer" />
                    <Button variant="ghost" onClick={close}>
                        {t('common.cancel')}
                    </Button>
                    <Button
                        variant="primary"
                        icon="user"
                        disabled={busy || !cid || !reason.trim()}
                        onClick={() => void save()}
                    >
                        {t('admin.missions.owner.button')}
                    </Button>
                </>
            }
        >
            <div className="admin-missions-stack">
                <Field label={t('admin.missions.owner.new')}>
                    <OfficerPicker value={cid} onChange={c => setCid(c)} />
                </Field>
                <Field label={t('admin.missions.reason')} required>
                    <TextInput value={reason} onChange={setReason} maxLength={255} />
                </Field>
            </div>
        </Dialog>
    );
}
