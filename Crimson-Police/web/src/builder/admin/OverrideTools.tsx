// Edited built-in missions (overrides): the catalog badges, the Compare dialog with Keep mine and Take the new
// original, and the short diff list the version picker uses too.

import { useState } from 'react';
import { Badge, Button, ConfirmDialog, Dialog, EmptyState, Icon, LoadingBlock } from '../../shared/components';
import { useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { useAdminAction } from '../../admin/components/kit';
import type { BuiltinDiff, DiffLine, DiffSummary, OverrideView } from '../../types/admin_missions';

export function OverrideBadges({ override }: { override: OverrideView | null | undefined }) {
    if (!override) return null;
    return (
        <>
            {override.overridden ? (
                <Badge size="sm" tone="accent" icon="edit" title={t('admin.missions.ovr.edited_hint')}>
                    {t('admin.missions.ovr.edited', { version: override.version ?? 1 })}
                </Badge>
            ) : null}
            {override.changed ? (
                <Badge size="sm" tone="warning" icon="alert" title={t('admin.missions.ovr.changed_hint')}>
                    {t('admin.missions.ovr.changed')}
                </Badge>
            ) : null}
            {override.hasDraft ? (
                <Badge size="sm" tone="neutral" variant="outline" icon="edit">
                    {t('admin.missions.ovr.draft')}
                </Badge>
            ) : null}
            {override.loadError ? (
                <Badge size="sm" tone="danger" icon="xCircle" title={override.loadError}>
                    {t('admin.missions.ovr.load_error')}
                </Badge>
            ) : null}
        </>
    );
}

export function DiffList({ lines, more }: { lines: DiffLine[] | null | undefined; more?: boolean }) {
    const list = Array.isArray(lines) ? lines : [];
    if (!list.length) return <div className="admin-missions-muted">{t('admin.missions.diff.none')}</div>;
    return (
        <div className="admin-missions-diff">
            <table className="cp-table cp-table--dense">
                <thead>
                    <tr>
                        <th>{t('admin.missions.diff.field')}</th>
                        <th>{t('admin.missions.diff.from')}</th>
                        <th>{t('admin.missions.diff.to')}</th>
                    </tr>
                </thead>
                <tbody>
                    {list.map(l => (
                        <tr key={l.path}>
                            <td className="admin-missions-mono">{l.path}</td>
                            <td className="admin-missions-diff__from">{l.from ?? '—'}</td>
                            <td className="admin-missions-diff__to">{l.to ?? '—'}</td>
                        </tr>
                    ))}
                </tbody>
            </table>
            {more ? <div className="admin-missions-muted">{t('admin.missions.diff.more')}</div> : null}
        </div>
    );
}

export function DiffSummaryLine({ summary }: { summary: DiffSummary | null | undefined }) {
    if (!summary) return null;
    const parts: string[] = [];
    if (summary.label) parts.push(t('admin.missions.diff.label', { from: summary.label.from, to: summary.label.to }));
    if (summary.locationsAdded?.length)
        parts.push(t('admin.missions.diff.loc_added', { list: summary.locationsAdded.join(', ') }));
    if (summary.locationsRemoved?.length)
        parts.push(t('admin.missions.diff.loc_removed', { list: summary.locationsRemoved.join(', ') }));
    if ((summary.objectivesFrom ?? []).join('|') !== (summary.objectivesTo ?? []).join('|'))
        parts.push(t('admin.missions.diff.objectives', { n: summary.objectivesTo?.length ?? 0 }));
    if (!parts.length) return null;
    return (
        <ul className="admin-missions-summary">
            {parts.map(p => (
                <li key={p}>{p}</li>
            ))}
        </ul>
    );
}

// Compare: what the update changed in the original, and the edit against the new original.
export function CompareDialog({
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
    const diff = useRequest<BuiltinDiff>('admin:builtinDiff', { id }, { skip: !id });
    const { run, busy } = useAdminAction();
    const [ask, setAsk] = useState<'keep' | 'take' | null>(null);
    const d = diff.data;
    const finish = async (reason: string, typed: string) => {
        if (!id || !ask) return;
        const res =
            ask === 'keep'
                ? await run(
                      'server:builder:keepOverride',
                      { id, reason },
                      { success: 'admin.missions.ovr.kept', successVars: { mission: label } },
                  )
                : await run(
                      'server:builder:resetBuiltin',
                      { id, reason, confirm: typed, takeNew: true },
                      { success: 'admin.missions.ovr.took_new', successVars: { mission: label } },
                  );
        setAsk(null);
        if (res.ok) {
            onDone();
            onClose();
        }
    };
    return (
        <>
            <Dialog
                open={!!id}
                onClose={onClose}
                size="lg"
                title={t('admin.missions.ovr.compare_title', { mission: label })}
                description={t('admin.missions.ovr.compare_text')}
                footer={
                    <>
                        <Button variant="ghost" onClick={onClose}>
                            {t('common.close')}
                        </Button>
                        <span className="cp-spacer" />
                        <Button icon="check" disabled={busy || !d?.changed} onClick={() => setAsk('keep')}>
                            {t('admin.missions.ovr.keep')}
                        </Button>
                        <Button variant="danger" icon="undo" disabled={busy || !d} onClick={() => setAsk('take')}>
                            {t('admin.missions.ovr.take_new')}
                        </Button>
                    </>
                }
            >
                {diff.loading && !d ? (
                    <LoadingBlock />
                ) : !d ? (
                    <EmptyState compact icon="alert" title={t(diff.error ?? 'err.internal')} />
                ) : (
                    <div className="admin-missions-stack">
                        {d.changed ? (
                            <div className="builder_client-callout builder_client-callout--warning">
                                <Icon name="alert" size={15} />
                                <span>{t('admin.missions.ovr.changed_text')}</span>
                            </div>
                        ) : (
                            <div className="builder_client-inline-note is-ok">
                                <Icon name="checkCircle" size={15} />
                                <span>{t('admin.missions.ovr.same_text')}</span>
                            </div>
                        )}
                        <h4 className="admin-missions-h">{t('admin.missions.ovr.what_update_changed')}</h4>
                        {d.original ? (
                            <DiffList lines={d.original} more={d.originalMore} />
                        ) : (
                            <div className="admin-missions-muted">{t('admin.missions.ovr.no_base')}</div>
                        )}
                        <h4 className="admin-missions-h">{t('admin.missions.ovr.yours_vs_new')}</h4>
                        <DiffSummaryLine summary={d.summary} />
                        <DiffList lines={d.yours} more={d.yoursMore} />
                    </div>
                )}
            </Dialog>
            <ConfirmDialog
                open={ask !== null}
                title={t(ask === 'keep' ? 'admin.missions.ovr.keep_title' : 'admin.missions.ovr.take_title', {
                    mission: label,
                })}
                message={t(ask === 'keep' ? 'admin.missions.ovr.keep_text' : 'admin.missions.ovr.take_text')}
                confirmLabel={t(ask === 'keep' ? 'admin.missions.ovr.keep' : 'admin.missions.ovr.take_new')}
                tone={ask === 'take' ? 'danger' : 'primary'}
                reason={{ required: true }}
                typedWord={ask === 'take' && id ? id : undefined}
                onConfirm={finish}
                onCancel={() => setAsk(null)}
                busy={busy}
            />
        </>
    );
}
