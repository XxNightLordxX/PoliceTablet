// Admin UI · Money → Rewards (old screen key 'admin_rewards', now a tab of admin_money): every feature that pays.

// Admin UI · Money → Rewards (old screen key 'admin_rewards', now a tab of admin_money): every feature that pays on
// one page. Each row shows its switch, its money and how it is paid, and its items (the RewardPoolEditor item picker,
// checked against ox_inventory by the server); the Item rewards switch sits on top with a one-click turn on. Every
// change saves through the Settings save flow (server:admin:setSetting: checked, audited, pushed as 'settings').

import { useEffect, useMemo, useState } from 'react';
import {
    Badge,
    Button,
    Card,
    EmptyState,
    ErrorState,
    Field,
    IconButton,
    LoadingBlock,
    NumberInput,
    Screen,
} from '../../shared/components';
import { formatMoney } from '../../shared/format';
import { useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { useNavigate } from '../../shared/navigation';
import type { SettingsData, SettingView } from '../../types/settings';
import { RewardPoolEditor } from '../components/RewardPoolEditor';
import {
    OUTCOMES,
    REWARD_CARDS,
    itemSwitch,
    missionTypes,
    rewardRows,
    showsMoneyItem,
    typeAmount,
    withTypeAmount,
    type Outcome,
    type RewardRow,
} from '../components/rewardsScreen';
import { Editor, mergeSettingsReply, useSettingSave, type SavePayload } from './Settings';
import { useAdminTitle } from '../../layouts/useAdminTitle';
import './Rewards.css';

type Save = (s: SettingView, p: SavePayload) => Promise<boolean>;

const MAX_MONEY = 1000000;

// One labelled setting with the Settings screen's own editor.
function SettingField({ label, s, disabled, save }: { label: string; s: SettingView; disabled: boolean; save: Save }) {
    return (
        <div className="rewards-screen__field">
            <span className="rewards-screen__label">{label}</span>
            <Editor s={s} disabled={disabled || !!s.locked} save={p => save(s, p)} />
        </div>
    );
}

// Volunteer suspects: dollars by mission type; an empty box pays the per-outcome default.
function ByTypeMoney({
    s,
    types,
    defaults,
    disabled,
    save,
}: {
    s: SettingView;
    types: string[];
    defaults: Record<Outcome, number>;
    disabled: boolean;
    save: Save;
}) {
    const [draft, setDraft] = useState<unknown>(s.value);
    useEffect(() => setDraft(s.value), [s.value]);
    const dirty = JSON.stringify(draft ?? {}) !== JSON.stringify(s.value ?? {});
    return (
        <div className="rewards-screen__bytype">
            <span className="rewards-screen__label">{t('admin.rewards_screen.bytype')}</span>
            <span className="rewards-screen__muted">{t('admin.rewards_screen.bytype_hint')}</span>
            {types.map(type => (
                <div key={type} className="rewards-screen__bytype-row">
                    <code>{type}</code>
                    {OUTCOMES.map(o => (
                        <Field key={o} label={t(`admin.rewards_screen.money.${o}`)}>
                            <NumberInput
                                value={typeAmount(draft, type, o)}
                                min={0}
                                max={MAX_MONEY}
                                prefix="$"
                                showRange={false}
                                placeholder={formatMoney(defaults[o])}
                                disabled={disabled}
                                onChange={v => setDraft(withTypeAmount(draft, type, o, v))}
                            />
                        </Field>
                    ))}
                </div>
            ))}
            {dirty ? (
                <div className="rewards-screen__actions">
                    <Button size="sm" icon="check" disabled={disabled} onClick={() => void save(s, { value: draft })}>
                        {t('settings.save')}
                    </Button>
                    <Button size="sm" variant="ghost" disabled={disabled} onClick={() => setDraft(s.value)}>
                        {t('common.cancel')}
                    </Button>
                </div>
            ) : null}
        </div>
    );
}

function Row({
    row,
    types,
    itemsOn,
    disabled,
    save,
}: {
    row: RewardRow;
    types: string[];
    itemsOn: boolean;
    disabled: boolean;
    save: Save;
}) {
    const navigate = useNavigate();
    const title = row.label ?? t(row.titleKey);
    const on = row.on ? row.on.value === true : true;
    const money = (key: string) => {
        const v = row.money.find(m => m.s.path.endsWith(key))?.s.value;
        return typeof v === 'number' ? v : 0;
    };
    return (
        <div className={`rewards-screen__row${on ? '' : ' is-off'}`}>
            <div className="rewards-screen__row-head">
                <div className="rewards-screen__row-title">
                    <strong>{title}</strong>
                    <span className="rewards-screen__muted">{t(row.hintKey)}</span>
                </div>
                {row.on ? (
                    <Editor s={row.on} disabled={disabled || !!row.on.locked} save={p => save(row.on!, p)} />
                ) : (
                    <Badge size="sm" tone="success">
                        {t('admin.rewards_screen.always')}
                    </Badge>
                )}
                <IconButton
                    icon="sliders"
                    size="sm"
                    label={t('admin.rewards_screen.open_settings')}
                    onClick={() => navigate('admin_settings', { q: (row.on ?? row.money[0]?.s)?.path ?? '' })}
                />
            </div>
            <div className="rewards-screen__row-body">
                <div className="rewards-screen__money">
                    {row.money.map(m => (
                        <SettingField key={m.s.path} label={t(m.labelKey)} s={m.s} disabled={disabled} save={save} />
                    ))}
                    {row.moneyNoteKey ? <span className="rewards-screen__muted">{t(row.moneyNoteKey)}</span> : null}
                    {row.account ? (
                        <SettingField
                            label={t('admin.rewards_screen.account')}
                            s={row.account}
                            disabled={disabled}
                            save={save}
                        />
                    ) : null}
                    {showsMoneyItem(row) && row.moneyItem ? (
                        <SettingField
                            label={t('admin.rewards_screen.money_item')}
                            s={row.moneyItem}
                            disabled={disabled}
                            save={save}
                        />
                    ) : null}
                </div>
                {row.byType ? (
                    <ByTypeMoney
                        s={row.byType}
                        types={types}
                        defaults={{ got_away: money('got_away'), caught: money('caught') }}
                        disabled={disabled}
                        save={save}
                    />
                ) : null}
                {row.items ? (
                    <div className="rewards-screen__items">
                        <span className="rewards-screen__label">
                            {t('admin.rewards_screen.items')}
                            {itemsOn ? null : (
                                <Badge size="sm" tone="warning" variant="outline">
                                    {t('admin.rewards_screen.items_paused')}
                                </Badge>
                            )}
                        </span>
                        {row.items.kind === 'switch' ? (
                            <>
                                <Editor
                                    s={row.items.s}
                                    disabled={disabled}
                                    save={p => save((row.items as { s: SettingView }).s, p)}
                                />
                                <span className="rewards-screen__muted">
                                    {t('admin.rewards_screen.items_from_type')}
                                </span>
                            </>
                        ) : (
                            <RewardPoolEditor
                                path={row.items.s.path}
                                value={row.items.s.value}
                                only={row.items.kind === 'pool' ? row.items.key : undefined}
                                disabled={disabled}
                                onSave={value => save((row.items as { s: SettingView }).s, { value })}
                            />
                        )}
                    </div>
                ) : null}
            </div>
        </div>
    );
}

export default function AdminRewards() {
    const screenTitle = useAdminTitle('admin_rewards');
    const { data, loading, error, refetch, setData } = useRequest<SettingsData>(
        'admin:getSettings',
        {},
        { pushTopic: 'settings' },
    );
    // a reply carries the settings it changed: show them at once (the 'settings' push refetches the rest)
    const { save, busy, dialogs } = useSettingSave(reply => {
        if (reply) setData(prev => mergeSettingsReply(prev, reply));
    });
    const rows = useMemo(() => rewardRows(data), [data]);
    const types = useMemo(() => missionTypes(data), [data]);
    const items = itemSwitch(data);
    const itemsOn = items?.value === true;
    const disabled = busy || !!data?.safeMode;

    if (loading && !data) return <LoadingBlock />;
    if (error && !data) return <ErrorState error={error} onRetry={() => void refetch()} />;

    return (
        <Screen title={screenTitle} subtitle={t('admin.rewards_screen.subtitle')}>
            {items ? (
                <Card
                    title={t('admin.rewards_screen.items_title')}
                    subtitle={t(itemsOn ? 'admin.rewards_screen.items_on' : 'admin.rewards_screen.items_off')}
                    icon="gift"
                    highlight={itemsOn ? 'success' : 'warning'}
                    actions={
                        itemsOn ? (
                            <Button
                                size="sm"
                                variant="secondary"
                                disabled={disabled}
                                onClick={() => void save(items, { value: false })}
                            >
                                {t('admin.rewards_screen.items_turn_off')}
                            </Button>
                        ) : (
                            <Button
                                size="sm"
                                variant="primary"
                                icon="check"
                                disabled={disabled}
                                onClick={() => void save(items, { value: true })}
                            >
                                {t('admin.rewards_screen.items_turn_on')}
                            </Button>
                        )
                    }
                />
            ) : null}
            {rows.length === 0 ? <EmptyState title={t('admin.rewards_screen.empty')} icon="gift" /> : null}
            {REWARD_CARDS.map(card => {
                const list = rows.filter(r => r.card === card);
                if (!list.length) return null;
                return (
                    <Card
                        key={card}
                        title={t(`admin.rewards_screen.card.${card}`)}
                        subtitle={t(`admin.rewards_screen.card_hint.${card}`)}
                        icon="dollar"
                        padding="sm"
                    >
                        <div className="rewards-screen__rows">
                            {list.map(r => (
                                <Row
                                    key={r.key}
                                    row={r}
                                    types={types}
                                    itemsOn={itemsOn}
                                    disabled={disabled}
                                    save={save}
                                />
                            ))}
                        </div>
                    </Card>
                );
            })}
            {dialogs}
        </Screen>
    );
}
