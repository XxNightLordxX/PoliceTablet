// The gear of each Admin UI screen: a drawer with only that screen's settings (modules/settings Play.screens), the
// same rows, checks, saves and audit as Settings -> All settings, which still lists every setting. Loaded on the
// first click (AdminLayout).

import { useMemo, useState } from 'react';
import {
    Button,
    Card,
    Dialog,
    EmptyState,
    ErrorState,
    Icon,
    LoadingBlock,
    SearchInput,
    SegmentedControl,
} from '../../shared/components';
import { asArray } from '../../shared/data';
import { useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { useNavigate } from '../../shared/navigation';
import type { SettingsData } from '../../types/settings';
import { SettingRow, mergeSettingsReply, useSettingSave } from '../screens/Settings';
import { gearFilter, gearSections, settingCount } from './screenSettings';

export default function ScreenSettings({
    screen,
    title,
    onClose,
}: {
    screen: string;
    title: string;
    onClose: () => void;
}) {
    const navigate = useNavigate();
    const { data, loading, error, refetch, setData } = useRequest<SettingsData>(
        'admin:getSettings',
        {},
        { pushTopic: 'settings' },
    );
    const { save, reset, busy, dialogs } = useSettingSave(reply => {
        if (reply) setData(prev => mergeSettingsReply(prev, reply));
    });
    const [query, setQuery] = useState('');
    const [picked, setPicked] = useState<string | null>(null);
    const secs = useMemo(() => gearSections(data, screen), [data, screen]);
    const found = useMemo(() => gearFilter(secs, query), [secs, query]);
    // one section at a time (the first until another is picked); a search looks through all of this screen's
    const searching = query.trim() !== '';
    const current = secs.find(s => s.key === picked) ?? secs[0];
    const shown = searching ? found : current ? [current] : [];
    const openAll = () => {
        onClose();
        navigate('admin_settings', { tab: 'settings' });
    };

    let body;
    if (loading && !data) body = <LoadingBlock />;
    else if (error && !data) body = <ErrorState error={error} onRetry={() => void refetch()} />;
    else if (!secs.length) body = <EmptyState icon="sliders" title={t('settings.gear.none')} />;
    else
        body = (
            <div className="settings-gear">
                {data?.safeMode ? (
                    <div className="settings-banner settings-banner--danger">
                        <Icon name="alert" size={16} />
                        <div>
                            <strong>{t('sysadmin.ui.safe_title')}</strong>
                            <span>{t('sysadmin.ui.safe_text')}</span>
                        </div>
                    </div>
                ) : null}
                <SearchInput value={query} onChange={setQuery} placeholder={t('settings.gear.search')} />
                {secs.length > 1 && !searching ? (
                    <SegmentedControl<string>
                        size="sm"
                        value={current?.key ?? ''}
                        onChange={setPicked}
                        items={secs.map(sec => ({ key: sec.key, label: sec.title }))}
                    />
                ) : null}
                {shown.length ? (
                    shown.map(sec => (
                        <Card
                            key={sec.key}
                            title={sec.title}
                            icon="sliders"
                            padding="none"
                            className="settings-section"
                        >
                            {asArray(sec.groups).map(g => (
                                <div key={g.path || '_'} className="settings-group">
                                    {g.label ? (
                                        <div className="settings-group__head">
                                            <strong>{g.label}</strong>
                                            {g.desc ? <span>{g.desc}</span> : null}
                                        </div>
                                    ) : null}
                                    {asArray(g.settings).map(s => (
                                        <SettingRow
                                            key={s.path}
                                            s={s}
                                            disabled={busy || !!data?.safeMode}
                                            save={save}
                                            reset={reset}
                                            resets={data?.resets}
                                        />
                                    ))}
                                </div>
                            ))}
                        </Card>
                    ))
                ) : (
                    <EmptyState icon="search" title={t('settings.no_match')} />
                )}
            </div>
        );

    return (
        <Dialog
            open
            onClose={onClose}
            placement="right"
            size="lg"
            title={t('settings.gear.title', { screen: title })}
            description={t('settings.gear.help', { n: settingCount(secs) })}
            footer={
                <Button variant="secondary" iconRight="chevronRight" onClick={openAll}>
                    {t('settings.gear.all')}
                </Button>
            }
        >
            {body}
            {dialogs}
        </Dialog>
    );
}
