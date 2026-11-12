// Admin UI -> Settings -> Presets: a group of settings (Config.AdminUi.presets) set in one click. Preview lists every
// change first (now -> after); Apply saves them as ordinary setting saves (checked, audited, in the history, with the
// preset as the reason). A preset never sets the admins, the permissions, a money switch or a webhook setting.

import { useState } from 'react';
import { Badge, Button, Card, Dialog, EmptyState, Icon, Table, type TableColumn } from '../../shared/components';
import { asArray } from '../../shared/data';
import { useAction } from '../../shared/hooks';
import { hasKey, t } from '../../shared/i18n';
import { request } from '../../shared/nui';
import { toast } from '../../shared/toast';
import type { PresetChange, PresetPreview, SettingsData, SettingsReply } from '../../types/settings';
import { presetState } from './screenSettings';

export function PresetsPanel({
    data,
    disabled,
    show,
    onApplied,
}: {
    data: SettingsData | null;
    disabled: boolean;
    // the short text of a value (Settings.tsx showValue)
    show: (v: unknown, set?: boolean) => string;
    onApplied: (reply: SettingsReply | undefined) => void;
}) {
    const presets = asArray(data?.presets);
    const [preview, setPreview] = useState<PresetPreview | null>(null);
    const [loading, setLoading] = useState<string | null>(null);
    const { run, busy } = useAction();
    const open = async (key: string) => {
        setLoading(key);
        const res = await request<PresetPreview>('admin:previewPreset', { preset: key });
        setLoading(null);
        if (res.ok && res.data) setPreview(res.data);
        else toast('error', t(res.error || 'err.internal'));
    };
    const apply = async () => {
        if (!preview) return;
        const res = await run<SettingsReply>(
            'server:admin:applyPreset',
            { preset: preview.key },
            { success: 'settings.presets.done', successVars: { name: preview.name, n: preview.changes.length } },
        );
        if (res.ok) {
            onApplied(res.data);
            setPreview(null);
        }
    };
    const state = presetState(preview);
    const columns: TableColumn<PresetChange>[] = [
        {
            key: 'label',
            header: t('settings.presets.col_setting'),
            render: c => (
                <div className="settings-preset__setting">
                    <strong>{c.label}</strong>
                    <code className="settings-row__path">{`Config.${c.path}`}</code>
                </div>
            ),
        },
        { key: 'from', header: t('settings.presets.col_now'), render: c => show(c.from, c.fromSet) },
        { key: 'to', header: t('settings.presets.col_after'), render: c => <strong>{show(c.to)}</strong> },
    ];

    return (
        <div className="settings-results">
            <div className="settings-intro">
                <Icon name="info" size={16} />
                <div>
                    <strong>{t('settings.presets.title')}</strong>
                    <span>{t('settings.presets.intro')}</span>
                </div>
            </div>
            {presets.length ? (
                <div className="settings-presets">
                    {presets.map(p => (
                        <Card key={p.key} title={p.name} icon="zap" className="settings-preset">
                            {p.help ? <p className="settings-row__desc">{p.help}</p> : null}
                            <div className="settings-preset__foot">
                                <Badge size="sm" tone="neutral">
                                    {t('settings.presets.count', { n: p.count })}
                                </Badge>
                                <Button
                                    size="sm"
                                    icon="eye"
                                    disabled={disabled}
                                    loading={loading === p.key}
                                    onClick={() => void open(p.key)}
                                >
                                    {t('settings.presets.preview')}
                                </Button>
                            </div>
                        </Card>
                    ))}
                </div>
            ) : (
                <EmptyState icon="zap" title={t('settings.presets.none')} />
            )}
            <Dialog
                open={!!preview}
                onClose={() => setPreview(null)}
                size="lg"
                title={t('settings.presets.preview_title', { name: preview?.name ?? '' })}
                description={
                    state === 'ready'
                        ? t('settings.presets.preview_text', {
                              n: preview?.changes.length ?? 0,
                              same: preview?.same ?? 0,
                          })
                        : state === 'none'
                          ? t('settings.presets.nothing')
                          : t('settings.presets.refused')
                }
                footer={
                    <>
                        <Button variant="secondary" onClick={() => setPreview(null)}>
                            {t('common.cancel')}
                        </Button>
                        <Button
                            icon="check"
                            disabled={state !== 'ready' || disabled}
                            loading={busy}
                            onClick={() => void apply()}
                        >
                            {t('settings.presets.apply', { n: preview?.changes.length ?? 0 })}
                        </Button>
                    </>
                }
            >
                {preview && preview.changes.length ? (
                    <Table<PresetChange> columns={columns} rows={preview.changes} rowKey={c => c.path} />
                ) : null}
                {preview && asArray(preview.refused).length ? (
                    <ul className="settings-preset__refused">
                        {asArray(preview.refused).map(r => (
                            <li key={r.path}>
                                <code>{`Config.${r.path}`}</code> {hasKey(r.error) ? t(r.error) : r.error}
                            </li>
                        ))}
                    </ul>
                ) : null}
            </Dialog>
        </div>
    );
}
