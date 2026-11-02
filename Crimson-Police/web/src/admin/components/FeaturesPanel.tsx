// Admin UI -> Settings -> Features: one card per section of play (NPC missions, Player vs police, Police teamwork,

import { useState } from 'react';
import { Badge, Button, Card, ConfirmDialog, EmptyState, Icon, Toggle } from '../../shared/components';
import { t } from '../../shared/i18n';
import type { SettingsData, SettingView } from '../../types/settings';
import { featureSections, limitValue, toggleNeeds, type FeatureRow } from './features';

export function FeaturesPanel({
    data,
    disabled,
    save,
    onOpen,
}: {
    data: SettingsData | null | undefined;
    disabled: boolean;
    save: (s: SettingView, p: { value: boolean }) => Promise<boolean>;
    // show this setting in All settings
    onOpen: (path: string) => void;
}) {
    const [ask, setAsk] = useState<{ row: FeatureRow; next: boolean } | null>(null);
    const [busy, setBusy] = useState(false);
    const sections = featureSections(data);

    const flip = async (row: FeatureRow, next: boolean) => {
        setBusy(true);
        try {
            await save(row.s, { value: next });
        } finally {
            setBusy(false);
        }
    };
    const onToggle = (row: FeatureRow, next: boolean) => {
        if (toggleNeeds(row, next) === 'risky') setAsk({ row, next });
        else void flip(row, next);
    };

    if (!sections.length) return <EmptyState icon="sliders" title={t('settings.features.title')} />;
    return (
        <div className="settings-results settings-features">
            <div className="settings-intro">
                <Icon name="info" size={16} />
                <div>
                    <strong>{t('settings.features.title')}</strong>
                    <span>{t('settings.features.intro')}</span>
                </div>
            </div>
            {sections.map(sec => (
                <Card
                    key={sec.play}
                    title={t(`settings.features.play.${sec.play}`)}
                    subtitle={t('settings.features.on_n', { n: sec.on, total: sec.rows.length })}
                    icon="sliders"
                    padding="none"
                    className="settings-section"
                >
                    <div className="settings-group">
                        {sec.rows.map(row => (
                            <div key={row.f.key} className="settings-feature">
                                <div className="settings-feature__text">
                                    <strong>{t(`settings.feature.${row.f.key}`)}</strong>
                                    <code className="settings-row__path">{`Config.${row.s.path}`}</code>
                                    {row.s.money ? (
                                        <Badge size="sm" tone="warning">
                                            {t('settings.features.money')}
                                        </Badge>
                                    ) : null}
                                    {row.s.changed ? (
                                        <Badge size="sm" tone="accent">
                                            {t('settings.features.changed')}
                                        </Badge>
                                    ) : null}
                                </div>
                                <Toggle
                                    checked={row.on}
                                    disabled={disabled || busy}
                                    label={row.on ? t('settings.value.on') : t('settings.value.off')}
                                    onChange={v => onToggle(row, v)}
                                />
                                <Button
                                    size="sm"
                                    variant="ghost"
                                    iconRight="chevronRight"
                                    onClick={() => onOpen(row.s.path)}
                                >
                                    {t('settings.features.open')}
                                </Button>
                                {row.limits.length ? (
                                    <div className="settings-feature__limits">
                                        <span>{t('settings.features.limits')}</span>
                                        {row.limits.map(l => (
                                            <Button
                                                key={l.path}
                                                size="sm"
                                                variant="secondary"
                                                title={t('settings.features.limit_open', { path: `Config.${l.path}` })}
                                                onClick={() => onOpen(l.path)}
                                            >
                                                {`${l.label}: ${limitValue(l)}`}
                                            </Button>
                                        ))}
                                    </div>
                                ) : null}
                            </div>
                        ))}
                    </div>
                </Card>
            ))}
            <ConfirmDialog
                open={!!ask}
                tone="danger"
                title={t('settings.features.confirm_title', {
                    name: ask ? t(`settings.feature.${ask.row.f.key}`) : '',
                    state: ask?.next ? t('settings.value.on') : t('settings.value.off'),
                })}
                message={t('settings.features.confirm_text')}
                confirmLabel={t('settings.save')}
                onConfirm={async () => {
                    const a = ask;
                    setAsk(null);
                    if (a) await flip(a.row, a.next);
                }}
                onCancel={() => setAsk(null)}
                busy={busy}
            />
        </div>
    );
}
