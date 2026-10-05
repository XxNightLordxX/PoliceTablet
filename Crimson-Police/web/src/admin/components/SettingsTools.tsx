// Admin UI → Settings: the structured editors (row lists with Use my position and Teleport to, Names, Goals) and the
// Export / Import panel. The server checks every value again (the same templates as the raw editor).

import { useEffect, useState } from 'react';
import {
    Badge,
    Button,
    Card,
    Checkbox,
    ConfirmDialog,
    EmptyState,
    IconButton,
    NumberInput,
    Select,
    TextInput,
    Textarea,
    Toggle,
} from '../../shared/components';
import { asArray } from '../../shared/data';
import { hasKey, t } from '../../shared/i18n';
import { request } from '../../shared/nui';
import { toast } from '../../shared/toast';
import type { SettingView, SettingsExport, SettingsImportPreview } from '../../types/settings';
import { copyLine } from './copyText';
import { RowsEditor, useAdminAction } from './kit';

export interface ToolEditorProps {
    s: SettingView;
    disabled: boolean;
    save: (p: { value?: unknown; none?: boolean }) => Promise<boolean>;
}

function same(a: unknown, b: unknown): boolean {
    return JSON.stringify(a) === JSON.stringify(b);
}

function errText(key?: string | null): string {
    if (!key) return '';
    return hasKey(key) ? t(key) : key;
}

function Actions({
    dirty,
    disabled,
    onSave,
    onCancel,
}: {
    dirty: boolean;
    disabled: boolean;
    onSave: () => void;
    onCancel: () => void;
}) {
    if (!dirty) return null;
    return (
        <div className="settings-edit__actions">
            <Button size="sm" icon="check" disabled={disabled} onClick={onSave}>
                {t('settings.save')}
            </Button>
            <Button size="sm" variant="ghost" disabled={disabled} onClick={onCancel}>
                {t('common.cancel')}
            </Button>
        </div>
    );
}

// ============================================================================
//                   ROW LISTS (USE MY POSITION, TELEPORT TO)
// ============================================================================

export function RowsField({ s, disabled, save }: ToolEditorProps) {
    const base = asArray(s.value as unknown[]);
    const [rows, setRows] = useState<unknown[]>(base);
    const { run, busy } = useAdminAction();
    const baseKey = JSON.stringify(base);
    useEffect(() => setRows(JSON.parse(baseKey) as unknown[]), [baseKey]);
    const dirty = !same(rows, base);
    if (!s.rows) return null;
    const usePosition = async (set: (v: unknown) => void) => {
        const res = await request<{ x: number; y: number; z: number }>('admin:myPosition', {});
        if (res.ok && res.data) set({ x: res.data.x, y: res.data.y, z: res.data.z });
        else toast('error', errText(res.error || 'err.internal'));
    };
    return (
        <div className="settings-edit">
            <RowsEditor
                rows={s.rows}
                value={rows}
                onChange={setRows}
                disabled={disabled}
                renderPositionTools={(index, set) => (
                    <span className="system-inline">
                        <IconButton
                            icon="mapPin"
                            size="sm"
                            variant="ghost"
                            label={t('sysadmin.ui.use_position')}
                            disabled={disabled}
                            onClick={() => void usePosition(set)}
                        />
                        <IconButton
                            icon="navigation"
                            size="sm"
                            variant="ghost"
                            label={t('sysadmin.ui.teleport')}
                            disabled={disabled || busy || dirty || index >= base.length}
                            onClick={() =>
                                void run(
                                    'server:admin:teleportTo',
                                    { path: s.path, index: index + 1 },
                                    { requestId: false },
                                )
                            }
                        />
                    </span>
                )}
            />
            <Actions
                dirty={dirty}
                disabled={disabled}
                onSave={() => void save({ value: rows })}
                onCancel={() => setRows(base)}
            />
        </div>
    );
}

// ============================================================================
//                                NAMES (LABELS)
// ============================================================================

const LABEL_KINDS = ['custody.offence.', 'profile.commend.kind.', 'badge.', 'bonus.', 'penalty.'];

export function LabelsField({ s, disabled, save }: ToolEditorProps) {
    const base = (s.value && typeof s.value === 'object' && !Array.isArray(s.value) ? s.value : {}) as Record<
        string,
        string
    >;
    const [map, setMap] = useState<Record<string, string>>(base);
    const [kind, setKind] = useState(LABEL_KINDS[0]);
    const [id, setId] = useState('');
    const [name, setName] = useState('');
    const baseKey = JSON.stringify(base);
    useEffect(() => setMap(JSON.parse(baseKey) as Record<string, string>), [baseKey]);
    const dirty = !same(map, base);
    const keys = Object.keys(map).sort();
    const add = () => {
        const k = `${kind}${id.trim()}`;
        if (!id.trim() || !name.trim()) return;
        setMap(prev => ({ ...prev, [k]: name.trim() }));
        setId('');
        setName('');
    };
    return (
        <div className="settings-edit">
            {keys.length ? (
                <ul className="settings-labels">
                    {keys.map(k => (
                        <li key={k} className="settings-labels__row">
                            <code>{k}</code>
                            <TextInput
                                value={map[k]}
                                onChange={v => setMap(prev => ({ ...prev, [k]: v }))}
                                maxLength={64}
                                disabled={disabled}
                                aria-label={k}
                            />
                            <IconButton
                                icon="trash"
                                size="sm"
                                variant="ghost"
                                label={t('ui.kit.row_remove')}
                                disabled={disabled}
                                onClick={() =>
                                    setMap(prev => {
                                        const next = { ...prev };
                                        delete next[k];
                                        return next;
                                    })
                                }
                            />
                        </li>
                    ))}
                </ul>
            ) : (
                <div className="settings-muted">{t('sysadmin.ui.labels_none')}</div>
            )}
            <div className="settings-edit__line">
                <Select
                    value={kind}
                    onChange={setKind}
                    disabled={disabled}
                    options={LABEL_KINDS.map(k => ({
                        value: k,
                        label: t(`sysadmin.ui.label_kind.${k.replace(/\.$/, '').replace(/\./g, '_')}`),
                    }))}
                />
                <TextInput
                    value={id}
                    onChange={setId}
                    maxLength={64}
                    placeholder={t('sysadmin.ui.label_id')}
                    disabled={disabled}
                />
                <TextInput
                    value={name}
                    onChange={setName}
                    maxLength={64}
                    placeholder={t('sysadmin.ui.label_name')}
                    disabled={disabled}
                />
                <Button
                    size="sm"
                    variant="secondary"
                    icon="plus"
                    disabled={disabled || !id.trim() || !name.trim()}
                    onClick={add}
                >
                    {t('ui.kit.row_add')}
                </Button>
            </div>
            <Actions
                dirty={dirty}
                disabled={disabled}
                onSave={() => void save({ value: map })}
                onCancel={() => setMap(base)}
            />
        </div>
    );
}

// ============================================================================
//                                    GOALS
// ============================================================================

type Goal = {
    id: string;
    label: string;
    count: number;
    type?: string;
    mission?: string;
    stat?: string;
    unit?: boolean;
    crossDepartment?: boolean;
    missionCall?: boolean;
    enabled?: boolean;
};

function cleanGoal(g: Goal): Goal {
    const out: Goal = { id: g.id, label: g.label, count: g.count };
    if (g.type) out.type = g.type;
    if (g.mission) out.mission = g.mission;
    if (g.stat) out.stat = g.stat;
    if (g.unit) out.unit = true;
    if (g.crossDepartment) out.crossDepartment = true;
    if (g.missionCall) out.missionCall = true;
    if (g.enabled === false) out.enabled = false;
    return out;
}

export function GoalsField({ s, disabled, save }: ToolEditorProps) {
    const base = asArray(s.value as Goal[]);
    const [goals, setGoals] = useState<Goal[]>(base);
    const baseKey = JSON.stringify(base);
    useEffect(() => setGoals(JSON.parse(baseKey) as Goal[]), [baseKey]);
    const dirty = !same(goals, base);
    const stats = asArray(s.options);
    const set = (i: number, patch: Partial<Goal>) =>
        setGoals(prev => prev.map((g, k) => (k === i ? { ...g, ...patch } : g)));
    return (
        <div className="settings-edit">
            {goals.map((g, i) => (
                <div key={i} className="settings-goal">
                    <div className="settings-edit__line">
                        <Toggle
                            checked={g.enabled !== false}
                            onChange={v => set(i, { enabled: v })}
                            disabled={disabled}
                            label=""
                        />
                        <TextInput
                            value={g.id}
                            onChange={v => set(i, { id: v })}
                            maxLength={32}
                            placeholder="id"
                            disabled={disabled}
                            aria-label="id"
                        />
                        <TextInput
                            value={g.label}
                            onChange={v => set(i, { label: v })}
                            maxLength={64}
                            disabled={disabled}
                            aria-label={t('sysadmin.ui.goal_label')}
                        />
                        <NumberInput
                            value={g.count}
                            onChange={v => set(i, { count: v ?? 1 })}
                            min={1}
                            max={1000}
                            integer
                            disabled={disabled}
                            aria-label={t('sysadmin.ui.goal_count')}
                        />
                        <IconButton
                            icon="trash"
                            size="sm"
                            variant="ghost"
                            label={t('ui.kit.row_remove')}
                            disabled={disabled}
                            onClick={() => setGoals(prev => prev.filter((_, k) => k !== i))}
                        />
                    </div>
                    <div className="settings-edit__line">
                        <TextInput
                            value={g.type ?? ''}
                            onChange={v => set(i, { type: v })}
                            maxLength={32}
                            placeholder={t('sysadmin.ui.goal_type')}
                            disabled={disabled}
                        />
                        <TextInput
                            value={g.mission ?? ''}
                            onChange={v => set(i, { mission: v })}
                            maxLength={64}
                            placeholder={t('sysadmin.ui.goal_mission')}
                            disabled={disabled}
                        />
                        <Select
                            value={g.stat ?? ''}
                            onChange={v => set(i, { stat: v || undefined })}
                            disabled={disabled}
                            options={[
                                { value: '', label: t('sysadmin.ui.goal_runs') },
                                ...stats.map(x => ({ value: String(x), label: String(x) })),
                            ]}
                        />
                        <Checkbox
                            checked={!!g.unit}
                            onChange={v => set(i, { unit: v })}
                            label={t('sysadmin.ui.goal_unit')}
                            disabled={disabled}
                        />
                        <Checkbox
                            checked={!!g.crossDepartment}
                            onChange={v => set(i, { crossDepartment: v })}
                            label={t('sysadmin.ui.goal_cross')}
                            disabled={disabled}
                        />
                        <Checkbox
                            checked={!!g.missionCall}
                            onChange={v => set(i, { missionCall: v })}
                            label={t('sysadmin.ui.goal_call')}
                            disabled={disabled}
                        />
                    </div>
                </div>
            ))}
            <Button
                size="sm"
                variant="ghost"
                icon="plus"
                disabled={disabled || goals.length >= 30}
                onClick={() => setGoals(prev => [...prev, { id: `goal_${prev.length + 1}`, label: '', count: 1 }])}
            >
                {t('ui.kit.row_add')}
            </Button>
            <Actions
                dirty={dirty}
                disabled={disabled}
                onSave={() => void save({ value: goals.map(cleanGoal) })}
                onCancel={() => setGoals(base)}
            />
        </div>
    );
}

// ============================================================================
//                              EXPORT AND IMPORT
// ============================================================================

export function TransferPanel({ onImported }: { onImported: () => void }) {
    const { run, busy } = useAdminAction();
    const [exported, setExported] = useState<SettingsExport | null>(null);
    const [text, setText] = useState('');
    const [preview, setPreview] = useState<SettingsImportPreview | null>(null);
    const [confirm, setConfirm] = useState(false);
    const doExport = async () => {
        const res = await request<SettingsExport>('admin:exportSettings', {});
        if (res.ok && res.data) setExported(res.data);
        else toast('error', errText(res.error || 'err.internal'));
    };
    const doPreview = async () => {
        const res = await request<SettingsImportPreview>('admin:previewSettingsImport', { text });
        if (res.ok && res.data) setPreview(res.data);
        else toast('error', errText(res.error || 'err.internal'));
    };
    const doImport = async (reason: string, typed: string) => {
        if (!preview) return;
        const res = await run(
            'server:admin:importSettings',
            { previewToken: preview.previewToken, reason, confirm: typed },
            { success: 'sysadmin.ui.import_done' },
        );
        setConfirm(false);
        if (res.ok) {
            setPreview(null);
            setText('');
            onImported();
        }
    };
    return (
        <div className="system-stack">
            <Card title={t('sysadmin.ui.export_title')} subtitle={t('sysadmin.ui.export_subtitle')} icon="download">
                <div className="system-buttons">
                    <Button icon="download" onClick={() => void doExport()}>
                        {t('sysadmin.ui.export')}
                    </Button>
                    {exported ? (
                        <Button variant="secondary" icon="fileText" onClick={() => copyLine(exported.text)}>
                            {t('sysadmin.ui.copy_export', { n: exported.count })}
                        </Button>
                    ) : null}
                </div>
                {exported ? <Textarea value={exported.text} onChange={() => undefined} rows={6} readOnly /> : null}
            </Card>
            <Card title={t('sysadmin.ui.import_title')} subtitle={t('sysadmin.ui.import_subtitle')} icon="layers">
                <Textarea value={text} onChange={setText} rows={6} placeholder={t('sysadmin.ui.import_placeholder')} />
                <div className="system-buttons">
                    <Button icon="eye" disabled={!text.trim()} onClick={() => void doPreview()}>
                        {t('sysadmin.ui.import_preview')}
                    </Button>
                </div>
                {preview ? (
                    <div className="system-stack">
                        {preview.changes.length ? (
                            <ul className="settings-import">
                                {preview.changes.map(c => (
                                    <li key={c.path}>
                                        <code>{c.path}</code> <span className="settings-muted">{c.old}</span> →{' '}
                                        <strong>{c.new}</strong>
                                    </li>
                                ))}
                            </ul>
                        ) : (
                            <EmptyState compact title={t('sysadmin.ui.import_none')} />
                        )}
                        {[
                            ['unknown', preview.unknown],
                            ['locked', preview.locked],
                            ['money', preview.money],
                        ].map(([k, list]) =>
                            asArray(list as string[]).length ? (
                                <div key={k as string} className="system-codes">
                                    <Badge size="sm" tone="warning">
                                        {t(`sysadmin.ui.import_${k as string}`)}
                                    </Badge>
                                    {asArray(list as string[]).map(p => (
                                        <code key={p}>{p}</code>
                                    ))}
                                </div>
                            ) : null,
                        )}
                        {preview.invalid.length ? (
                            <div className="system-codes">
                                <Badge size="sm" tone="danger">
                                    {t('sysadmin.ui.import_invalid')}
                                </Badge>
                                {preview.invalid.map(x => (
                                    <code key={x.path} title={errText(x.error)}>
                                        {x.path}
                                    </code>
                                ))}
                            </div>
                        ) : null}
                        <div className="system-buttons">
                            <span className="settings-muted">
                                {t('sysadmin.ui.import_unchanged', { n: preview.unchanged })}
                            </span>
                            <Button
                                variant="danger"
                                icon="check"
                                disabled={busy || !preview.changes.length}
                                onClick={() => setConfirm(true)}
                            >
                                {t('sysadmin.ui.import', { n: preview.changes.length })}
                            </Button>
                        </div>
                    </div>
                ) : null}
            </Card>
            <ConfirmDialog
                open={confirm}
                tone="danger"
                title={t('sysadmin.ui.import_title')}
                message={t('sysadmin.ui.import_confirm', { n: preview?.changes.length ?? 0 })}
                reason
                typedWord="IMPORT"
                onConfirm={doImport}
                onCancel={() => setConfirm(false)}
                busy={busy}
            />
        </div>
    );
}
