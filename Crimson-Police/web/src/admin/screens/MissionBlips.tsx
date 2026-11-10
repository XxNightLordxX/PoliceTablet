// Admin UI · Mission blips (screen key 'admin_blips', Config.AdminUi.missionBlipsScreen): the extra mission blips.

// Admin UI · Mission blips (screen key 'admin_blips', Config.AdminUi.missionBlipsScreen): the extra mission blips of
// Config.MissionBlips on one page. On top the master switch (shipped off) and how often the server checks; then one
// row per part (the vans and where they wait, evidence, cars, people, devices, hiding spots, the hospital, partners,
// reported points) with its on switch, its look (sprite, colour, size), label and range, and who sees it
// (departments, jobs, lowest grade, mission types, missions, role). Every change saves through the Settings save
// flow (server:admin:setSetting: checked, audited, pushed as 'settings') and works at once, no restart.

import { useEffect, useMemo, useState } from 'react';
import {
    Badge,
    Button,
    Card,
    Checkbox,
    EmptyState,
    ErrorState,
    Field,
    IconButton,
    LoadingBlock,
    NumberInput,
    Screen,
    Select,
} from '../../shared/components';
import { asArray } from '../../shared/data';
import { useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { useNavigate } from '../../shared/navigation';
import type { AdminMissionsData } from '../../types/builder_client';
import type { SettingsData, SettingView } from '../../types/settings';
import {
    COLOURS,
    ROLES,
    SPRITES,
    blipParts,
    choicesWith,
    colourOf,
    masterSwitch,
    partsOn,
    ruleChoices,
    ruleOf,
    ruleSummary,
    toggleIn,
    withRule,
    type BlipPart,
    type BlipRule,
    type ListRule,
    type RuleChoices,
} from '../components/missionBlips';
import { settingsByPath } from '../components/features';
import { Editor, mergeSettingsReply, useSettingSave, type SavePayload } from './Settings';
import { useAdminTitle } from '../../layouts/useAdminTitle';
import './MissionBlips.css';

type Save = (s: SettingView, p: SavePayload) => Promise<boolean>;

// One labelled setting with the Settings screen's own editor.
function SettingField({ label, s, disabled, save }: { label: string; s: SettingView; disabled: boolean; save: Save }) {
    return (
        <div className="mission-blips__field">
            <span className="mission-blips__label">{label}</span>
            <Editor s={s} disabled={disabled || !!s.locked} save={p => save(s, p)} />
        </div>
    );
}

// A picker of named ids (sprite or colour) that saves the id at once; the number box next to it takes any id.
function PresetPicker({
    s,
    options,
    disabled,
    save,
}: {
    s: SettingView;
    options: { id: number; label: string }[];
    disabled: boolean;
    save: Save;
}) {
    const known = options.some(o => o.id === s.value);
    return (
        <Select
            value={known ? String(s.value) : ''}
            placeholder={t('admin.mission_blips.pick')}
            options={options.map(o => ({ value: String(o.id), label: `${o.label} (${o.id})` }))}
            disabled={disabled || !!s.locked}
            aria-label={s.label}
            onChange={v => {
                const n = Number(v);
                if (v !== '' && Number.isFinite(n) && n !== s.value) void save(s, { value: n });
            }}
        />
    );
}

// The rule editor of one part: a draft of its rule, saved into the whole Config.MissionBlips.rules value.
function RuleEditor({
    part,
    rules,
    choices,
    disabled,
    save,
    onDone,
}: {
    part: BlipPart;
    rules: SettingView;
    choices: RuleChoices;
    disabled: boolean;
    save: Save;
    onDone: () => void;
}) {
    const [draft, setDraft] = useState<BlipRule>(() => ruleOf(rules.value, part.id));
    // keyed on the saved rule itself: another save (a new settings object) keeps an unsaved draft
    const savedKey = JSON.stringify(ruleOf(rules.value, part.id));
    // eslint-disable-next-line react-hooks/exhaustive-deps
    useEffect(() => setDraft(ruleOf(rules.value, part.id)), [savedKey, part.id]);
    const [missionPick, setMissionPick] = useState('');
    const set = (patch: Partial<BlipRule>) => setDraft(d => ({ ...d, ...patch }));
    const commit = async (rule: BlipRule | null) => {
        if (await save(rules, { value: withRule(rules.value, part.id, rule) })) onDone();
    };
    const listBox = (k: Exclude<ListRule, 'missions'>) => {
        const list = choicesWith(choices[k], draft[k]);
        return (
            <Field label={t(`admin.mission_blips.rule.${k}`)} hint={t('admin.mission_blips.rule_any')}>
                <div className="mission-blips__checks">
                    {list.length === 0 ? (
                        <span className="mission-blips__muted">{t('admin.mission_blips.none_to_pick')}</span>
                    ) : null}
                    {list.map(c => (
                        <Checkbox
                            key={c.value}
                            label={c.label}
                            checked={(draft[k] ?? []).includes(c.value)}
                            disabled={disabled}
                            onChange={on => set({ [k]: toggleIn(draft[k], c.value, on) })}
                        />
                    ))}
                </div>
            </Field>
        );
    };
    const missions = choicesWith(choices.missions, draft.missions);
    const picked = draft.missions ?? [];
    return (
        <div className="mission-blips__rules-edit">
            {listBox('departments')}
            {listBox('jobs')}
            {listBox('missionTypes')}
            <Field label={t('admin.mission_blips.rule.missions')} hint={t('admin.mission_blips.rule_any')}>
                <div className="mission-blips__checks">
                    {picked.map(id => (
                        <Badge key={id} size="sm" tone="accent">
                            {missions.find(m => m.value === id)?.label ?? id}
                            <IconButton
                                icon="x"
                                size="sm"
                                label={t('admin.mission_blips.remove', { name: id })}
                                disabled={disabled}
                                onClick={() => set({ missions: toggleIn(picked, id, false) })}
                            />
                        </Badge>
                    ))}
                    <Select
                        value={missionPick}
                        placeholder={t('admin.mission_blips.add_mission')}
                        options={missions.filter(m => !picked.includes(m.value))}
                        disabled={disabled}
                        aria-label={t('admin.mission_blips.add_mission')}
                        onChange={v => {
                            setMissionPick('');
                            if (v) set({ missions: toggleIn(picked, v, true) });
                        }}
                    />
                </div>
            </Field>
            <div className="mission-blips__rules-row">
                <Field label={t('admin.mission_blips.rule.grade')} hint={t('admin.mission_blips.grade_hint')}>
                    <NumberInput
                        value={draft.grade ?? null}
                        min={0}
                        max={100}
                        showRange={false}
                        placeholder="0"
                        disabled={disabled}
                        onChange={v => set({ grade: v ?? undefined })}
                    />
                </Field>
                <Field label={t('admin.mission_blips.rule.roles')}>
                    <Select
                        value={draft.roles ?? 'all'}
                        options={ROLES.map(r => ({ value: r, label: t(`admin.mission_blips.role.${r}`) }))}
                        disabled={disabled}
                        onChange={v => set({ roles: v as BlipRule['roles'] })}
                    />
                </Field>
            </div>
            <div className="mission-blips__actions">
                <Button size="sm" icon="check" disabled={disabled} onClick={() => void commit(draft)}>
                    {t('settings.save')}
                </Button>
                <Button size="sm" variant="secondary" disabled={disabled} onClick={() => void commit(null)}>
                    {t('admin.mission_blips.clear_rules')}
                </Button>
                <Button size="sm" variant="ghost" disabled={disabled} onClick={onDone}>
                    {t('common.cancel')}
                </Button>
            </div>
        </div>
    );
}

function PartRow({
    part,
    rules,
    choices,
    masterOn,
    disabled,
    save,
}: {
    part: BlipPart;
    rules?: SettingView;
    choices: RuleChoices;
    masterOn: boolean;
    disabled: boolean;
    save: Save;
}) {
    const navigate = useNavigate();
    const [editing, setEditing] = useState(false);
    const on = part.on.value === true;
    const { sprite, colour, scale, label, shortRange } = part.look;
    const named = colourOf(colour?.value);
    const summary = rules ? ruleSummary(ruleOf(rules.value, part.id), choices) : [];
    const sprites = SPRITES.map(x => ({ id: x.id, label: t(`admin.mission_blips.sprite.${x.key}`) }));
    const colours = COLOURS.map(x => ({ id: x.id, label: t(`admin.mission_blips.colour.${x.key}`) }));
    return (
        <div className={`mission-blips__row${on ? '' : ' is-off'}`}>
            <div className="mission-blips__row-head">
                <span
                    className="mission-blips__swatch"
                    style={{ background: named?.hex ?? 'var(--cp-muted)' }}
                    aria-hidden="true"
                />
                <div className="mission-blips__row-title">
                    <strong>{t(part.nameKey)}</strong>
                    <span className="mission-blips__muted">{t(`admin.mission_blips.hint.${part.id}`)}</span>
                </div>
                {on && !masterOn ? (
                    <Badge size="sm" tone="warning" variant="outline">
                        {t('admin.mission_blips.waits_master')}
                    </Badge>
                ) : null}
                <Editor s={part.on} disabled={disabled || !!part.on.locked} save={p => save(part.on, p)} />
                <IconButton
                    icon="sliders"
                    size="sm"
                    label={t('admin.mission_blips.open_settings')}
                    onClick={() => navigate('admin_settings', { q: `MissionBlips.parts.${part.id}` })}
                />
            </div>
            <div className="mission-blips__look">
                {sprite ? (
                    <div className="mission-blips__field">
                        <span className="mission-blips__label">{t('admin.mission_blips.look.sprite')}</span>
                        <PresetPicker s={sprite} options={sprites} disabled={disabled} save={save} />
                        <Editor s={sprite} disabled={disabled || !!sprite.locked} save={p => save(sprite, p)} />
                    </div>
                ) : null}
                {colour ? (
                    <div className="mission-blips__field">
                        <span className="mission-blips__label">{t('admin.mission_blips.look.colour')}</span>
                        <PresetPicker s={colour} options={colours} disabled={disabled} save={save} />
                        <Editor s={colour} disabled={disabled || !!colour.locked} save={p => save(colour, p)} />
                    </div>
                ) : null}
                {scale ? (
                    <SettingField
                        label={t('admin.mission_blips.look.scale')}
                        s={scale}
                        disabled={disabled}
                        save={save}
                    />
                ) : null}
                {label ? (
                    <SettingField
                        label={t('admin.mission_blips.look.label')}
                        s={label}
                        disabled={disabled}
                        save={save}
                    />
                ) : null}
                {shortRange ? (
                    <SettingField
                        label={t('admin.mission_blips.look.shortRange')}
                        s={shortRange}
                        disabled={disabled}
                        save={save}
                    />
                ) : null}
            </div>
            {rules ? (
                <div className="mission-blips__rules">
                    <span className="mission-blips__label">{t('admin.mission_blips.who')}</span>
                    {editing ? (
                        <RuleEditor
                            part={part}
                            rules={rules}
                            choices={choices}
                            disabled={disabled || !!rules.locked}
                            save={save}
                            onDone={() => setEditing(false)}
                        />
                    ) : (
                        <div className="mission-blips__checks">
                            {summary.length === 0 ? (
                                <span className="mission-blips__muted">{t('admin.mission_blips.everyone')}</span>
                            ) : (
                                summary.map(x => (
                                    <Badge key={x.key} size="sm" tone="neutral">
                                        {`${t(x.key)}: ${
                                            x.key === 'admin.mission_blips.rule.roles'
                                                ? t(`admin.mission_blips.role.${x.text}`)
                                                : x.text
                                        }`}
                                    </Badge>
                                ))
                            )}
                            <Button
                                size="sm"
                                variant="secondary"
                                icon="edit"
                                disabled={disabled || !!rules.locked}
                                onClick={() => setEditing(true)}
                            >
                                {t('admin.mission_blips.edit_rules')}
                            </Button>
                        </div>
                    )}
                </div>
            ) : null}
        </div>
    );
}

export default function AdminMissionBlips() {
    const screenTitle = useAdminTitle('admin_blips');
    const { data, loading, error, refetch, setData } = useRequest<SettingsData>(
        'admin:getSettings',
        {},
        { pushTopic: 'settings' },
    );
    // the mission picker's choices (a failed list only leaves the picker empty)
    const missions = useRequest<AdminMissionsData>('admin:getMissions', {}, { pushTopic: 'operation' });
    // a reply carries the settings it changed: show them at once (the 'settings' push refetches the rest)
    const { save, busy, dialogs } = useSettingSave(reply => {
        if (reply) setData(prev => mergeSettingsReply(prev, reply));
    });
    const parts = useMemo(() => blipParts(data), [data]);
    const choices = useMemo(() => ruleChoices(data, asArray(missions.data?.missions)), [data, missions.data]);
    const master = masterSwitch(data);
    const masterOn = master?.value === true;
    const byPath = useMemo(() => settingsByPath(data), [data]);
    const rules = byPath.get('MissionBlips.rules');
    const refresh = byPath.get('MissionBlips.refreshEvery');
    const disabled = busy || !!data?.safeMode;

    if (loading && !data) return <LoadingBlock />;
    if (error && !data) return <ErrorState error={error} onRetry={() => void refetch()} />;

    return (
        <Screen title={screenTitle} subtitle={t('admin.mission_blips.subtitle')}>
            {master ? (
                <Card
                    title={t('admin.mission_blips.master_title')}
                    subtitle={t(masterOn ? 'admin.mission_blips.master_on' : 'admin.mission_blips.master_off', {
                        n: partsOn(parts, data),
                        total: parts.length,
                    })}
                    icon="mapPin"
                    highlight={masterOn ? 'success' : 'warning'}
                    actions={
                        <Button
                            size="sm"
                            variant={masterOn ? 'secondary' : 'primary'}
                            icon={masterOn ? undefined : 'check'}
                            disabled={disabled || !!master.locked}
                            onClick={() => void save(master, { value: !masterOn })}
                        >
                            {t(masterOn ? 'admin.mission_blips.turn_off' : 'admin.mission_blips.turn_on')}
                        </Button>
                    }
                >
                    <div className="mission-blips__master">
                        <span className="mission-blips__muted">{t('admin.mission_blips.fair')}</span>
                        {refresh ? (
                            <SettingField
                                label={t('admin.mission_blips.refresh')}
                                s={refresh}
                                disabled={disabled}
                                save={save}
                            />
                        ) : null}
                    </div>
                </Card>
            ) : null}
            {parts.length === 0 ? <EmptyState title={t('admin.mission_blips.empty')} icon="mapPin" /> : null}
            {parts.length ? (
                <Card
                    title={t('admin.mission_blips.parts_title')}
                    subtitle={t('admin.mission_blips.parts_hint')}
                    icon="layers"
                    padding="sm"
                >
                    <div className="mission-blips__rows">
                        {parts.map(p => (
                            <PartRow
                                key={p.id}
                                part={p}
                                rules={rules}
                                choices={choices}
                                masterOn={masterOn}
                                disabled={disabled}
                                save={save}
                            />
                        ))}
                    </div>
                </Card>
            ) : null}
            {dialogs}
        </Screen>
    );
}
