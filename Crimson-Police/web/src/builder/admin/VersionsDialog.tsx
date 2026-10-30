// Versions of a custom mission or an edited built-in: roll back to any kept version (with a short diff against the
// published one), and Load saved draft (the draft a hand edit of the file overwrote).

import { useEffect, useState } from 'react';
import { Button, ConfirmDialog, Dialog, EmptyState, Field, LoadingBlock, Select } from '../../shared/components';
import { useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { useAdminAction } from '../../admin/components/kit';
import type { BuilderRecord } from '../../types/builder_server';
import type { VersionDiff } from '../../types/admin_missions';
import { DiffList, DiffSummaryLine } from './OverrideTools';

export function VersionsDialog({
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
    const rec = useRequest<BuilderRecord>('builder:get', { id }, { skip: !id });
    const backups = Array.isArray(rec.data?.backups) ? rec.data.backups : [];
    const [version, setVersion] = useState<number | null>(null);
    useEffect(() => {
        const list = Array.isArray(rec.data?.backups) ? rec.data.backups : [];
        setVersion(list.length ? list[0] : null);
    }, [rec.data]);
    const diff = useRequest<VersionDiff>('builder:versionDiff', { id, version }, { skip: !id || version === null });
    const { run, busy } = useAdminAction();
    const [ask, setAsk] = useState<'rollback' | 'draft' | null>(null);

    const finish = async (reason: string) => {
        if (!id || !ask) return;
        const res =
            ask === 'rollback'
                ? await run(
                      'server:builder:rollback',
                      { id, version },
                      {
                          success: 'admin.missions.versions.rolled_back',
                          successVars: { mission: label, version: version ?? 0 },
                      },
                  )
                : await run(
                      'server:builder:loadBackupDraft',
                      { id, reason: reason || undefined },
                      { success: 'admin.missions.versions.draft_loaded', successVars: { mission: label } },
                  );
        setAsk(null);
        if (res.ok) {
            onDone();
            onClose();
        }
    };

    const r = rec.data;
    return (
        <>
            <Dialog
                open={!!id}
                onClose={onClose}
                size="lg"
                title={t('admin.missions.versions.title', { mission: label })}
                description={t('admin.missions.versions.text')}
                footer={
                    <>
                        {r?.draftBackup ? (
                            <Button icon="download" disabled={busy} onClick={() => setAsk('draft')}>
                                {t('admin.missions.versions.load_draft')}
                            </Button>
                        ) : null}
                        <span className="cp-spacer" />
                        <Button variant="ghost" onClick={onClose}>
                            {t('common.close')}
                        </Button>
                        <Button
                            variant="primary"
                            icon="undo"
                            disabled={busy || version === null || !r?.can?.rollback}
                            onClick={() => setAsk('rollback')}
                        >
                            {t('admin.missions.versions.rollback')}
                        </Button>
                    </>
                }
            >
                {rec.loading && !r ? (
                    <LoadingBlock />
                ) : !r ? (
                    <EmptyState compact icon="alert" title={t(rec.error ?? 'err.internal')} />
                ) : !backups.length ? (
                    <EmptyState compact icon="inbox" title={t('admin.missions.versions.none')} />
                ) : (
                    <div className="admin-missions-stack">
                        <Field label={t('admin.missions.versions.pick', { current: r.version ?? 1 })}>
                            <Select
                                value={version === null ? '' : String(version)}
                                onChange={v => setVersion(v ? Number(v) : null)}
                                options={backups.map(n => ({
                                    value: String(n),
                                    label: t('admin.missions.version_v', { version: n }),
                                }))}
                            />
                        </Field>
                        {diff.loading && !diff.data ? (
                            <LoadingBlock />
                        ) : diff.data ? (
                            <>
                                <DiffSummaryLine summary={diff.data.summary} />
                                <DiffList lines={diff.data.lines} more={diff.data.more} />
                            </>
                        ) : null}
                    </div>
                )}
            </Dialog>
            <ConfirmDialog
                open={ask !== null}
                title={t(
                    ask === 'draft' ? 'admin.missions.versions.draft_title' : 'admin.missions.versions.rollback_title',
                    {
                        mission: label,
                        version: version ?? 0,
                    },
                )}
                message={t(
                    ask === 'draft' ? 'admin.missions.versions.draft_text' : 'admin.missions.versions.rollback_text',
                    {
                        version: version ?? 0,
                    },
                )}
                confirmLabel={t(
                    ask === 'draft' ? 'admin.missions.versions.load_draft' : 'admin.missions.versions.rollback',
                )}
                reason={ask === 'draft' ? { required: false } : undefined}
                onConfirm={finish}
                onCancel={() => setAsk(null)}
                busy={busy}
            />
        </>
    );
}
