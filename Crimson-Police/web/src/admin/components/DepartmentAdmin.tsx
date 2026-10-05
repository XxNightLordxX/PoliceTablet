// Admin UI → Departments: add, edit, turn off and delete a department, upload its logo, and edit the mission desks.
// The server checks every value again (the same department and desk checks as the raw Settings editor).

import { useState } from 'react';
import {
    Badge,
    Button,
    Checkbox,
    ConfirmDialog,
    Dialog,
    EmptyState,
    Field,
    Grid,
    Icon,
    IconButton,
    NumberInput,
    Select,
    TextInput,
    Toggle,
} from '../../shared/components';
import { asArray } from '../../shared/data';
import { hasKey, t } from '../../shared/i18n';
import { toast } from '../../shared/toast';
import type { DeskView, TabletAccessView } from '../../types/access';
import type { DepartmentFields, DepartmentSetting, DepartmentSetup, DeptTheme } from '../../types/admin_system';
import { newRequestId, useAdminAction } from './kit';
import '../screens/System.css';

const CHUNK = 16384; // base64 characters per upload chunk (a multiple of 4)
const THEME_KEYS: (keyof DeptTheme)[] = ['primary', 'accent', 'background', 'surface', 'text'];
const HEX = /^#[0-9a-fA-F]{6}$/;

function errText(key?: string): string {
    if (!key) return '';
    return hasKey(key) ? t(key) : key;
}

// ============================================================================
//                        ON THE CARD: EDIT, OFF, DELETE
// ============================================================================

export function DepartmentTools({
    setting,
    onEdit,
    onChanged,
}: {
    setting: DepartmentSetting;
    onEdit: () => void;
    onChanged: () => void;
}) {
    const { run, busy } = useAdminAction();
    const [confirm, setConfirm] = useState<'off' | 'on' | 'delete' | null>(null);
    const act = async (reason: string, typed: string) => {
        if (confirm === 'delete') {
            const res = await run(
                'server:admin:deleteDepartment',
                { key: setting.key, reason, confirm: typed },
                { requestId: false, success: 'sysadmin.ui.dept_deleted' },
            );
            if (res.ok) onChanged();
        } else {
            const res = await run(
                'server:admin:setDepartmentEnabled',
                { key: setting.key, enabled: confirm === 'on', reason, confirm: typed },
                {
                    requestId: false,
                    success: confirm === 'on' ? 'sysadmin.ui.dept_on_done' : 'sysadmin.ui.dept_off_done',
                },
            );
            if (res.ok) onChanged();
        }
        setConfirm(null);
    };
    return (
        <div className="system-buttons dept-admin-tools">
            {!setting.enabled ? (
                <Badge size="sm" tone="danger" icon="minusCircle">
                    {t('sysadmin.ui.dept_off')}
                </Badge>
            ) : null}
            {setting.added ? (
                <Badge size="sm" tone="accent" variant="outline">
                    {t('sysadmin.ui.dept_added_badge')}
                </Badge>
            ) : null}
            <span className="cp-spacer" />
            <Button size="sm" variant="secondary" icon="edit" disabled={busy} onClick={onEdit}>
                {t('sysadmin.ui.dept_edit')}
            </Button>
            {setting.enabled ? (
                <Button size="sm" variant="ghost" icon="minusCircle" disabled={busy} onClick={() => setConfirm('off')}>
                    {t('sysadmin.ui.dept_turn_off')}
                </Button>
            ) : (
                <Button size="sm" variant="ghost" icon="play" disabled={busy} onClick={() => setConfirm('on')}>
                    {t('sysadmin.ui.dept_turn_on')}
                </Button>
            )}
            {setting.added ? (
                <IconButton
                    icon="trash"
                    size="sm"
                    variant="ghost"
                    label={t('sysadmin.ui.dept_delete')}
                    disabled={busy}
                    onClick={() => setConfirm('delete')}
                />
            ) : null}
            <ConfirmDialog
                open={!!confirm}
                tone={confirm === 'on' ? 'primary' : 'danger'}
                title={
                    confirm === 'delete'
                        ? t('sysadmin.ui.dept_delete')
                        : confirm === 'on'
                          ? t('sysadmin.ui.dept_turn_on')
                          : t('sysadmin.ui.dept_turn_off')
                }
                message={
                    confirm === 'delete'
                        ? t('sysadmin.ui.dept_delete_text', { name: setting.label })
                        : confirm === 'on'
                          ? t('sysadmin.ui.dept_on_text', { name: setting.label })
                          : t('sysadmin.ui.dept_off_text', { name: setting.label })
                }
                reason
                typedWord={confirm === 'on' ? undefined : setting.short}
                onConfirm={act}
                onCancel={() => setConfirm(null)}
                busy={busy}
            />
        </div>
    );
}

// ============================================================================
//                            ADD OR EDIT (THE FORM)
// ============================================================================

function readBase64(file: File): Promise<string> {
    return new Promise((resolve, reject) => {
        const r = new FileReader();
        r.onload = () => {
            const s = String(r.result ?? '');
            resolve(s.slice(s.indexOf(',') + 1));
        };
        r.onerror = () => reject(r.error);
        r.readAsDataURL(file);
    });
}

export function DepartmentDialog({
    setup,
    setting,
    onClose,
    onSaved,
}: {
    setup: DepartmentSetup;
    setting: DepartmentSetting | null;
    onClose: () => void;
    onSaved: () => void;
}) {
    const isNew = !setting;
    const { run, busy } = useAdminAction();
    const [key, setKey] = useState('');
    const [label, setLabel] = useState(setting?.label ?? '');
    const [short, setShort] = useState(setting?.short ?? '');
    const [jobs, setJobs] = useState<string[]>(asArray(setting?.jobs));
    const [grade, setGrade] = useState<number | null>(setting?.supervisorGrade ?? 3);
    const [account, setAccount] = useState(setting?.societyAccount ?? '');
    const [themeFrom, setThemeFrom] = useState(asArray(setup.departments)[0]?.key ?? '');
    const [theme, setTheme] = useState<DeptTheme>({ ...(setting?.theme ?? {}) });
    const [logoUrl, setLogoUrl] = useState(setting?.logo?.url ?? '');
    const [logoFile, setLogoFile] = useState(setting?.logo?.file ?? '');
    const [watermark, setWatermark] = useState(setting?.logo?.watermark !== false);
    const [uploading, setUploading] = useState<string | null>(null);

    const firstJob = asArray(setup.jobs).find(j => j.name === jobs[0]);
    const toggleJob = (name: string, on: boolean) =>
        setJobs(prev => (on ? [...prev.filter(j => j !== name), name] : prev.filter(j => j !== name)));

    const fields = (): DepartmentFields => {
        const f: DepartmentFields = {
            label: label.trim(),
            short: short.trim(),
            jobs,
            supervisorGrade: grade ?? 0,
            societyAccount: account.trim(),
            logo: { url: logoUrl.trim(), file: logoFile.trim(), watermark },
        };
        if (!isNew) {
            // an empty text colour goes back to automatic; the four main colours are only sent when set
            const th: DeptTheme = {};
            for (const k of THEME_KEYS) {
                const v = (theme[k] ?? '').trim();
                if (v) th[k] = v;
                else if (k === 'text' && setting.theme?.text) th.text = '';
            }
            f.theme = th;
        }
        return f;
    };
    const save = async () => {
        if (isNew) {
            const res = await run(
                'server:admin:addDepartment',
                { key: key.trim(), themeFrom, ...fields() },
                { requestId: false, success: 'sysadmin.ui.dept_added' },
            );
            if (res.ok) onSaved();
            return;
        }
        const res = await run(
            'server:admin:saveDepartment',
            { key: setting.key, fields: fields() },
            { requestId: false, success: 'sysadmin.ui.dept_saved' },
        );
        if (res.ok) onSaved();
    };
    const upload = async (file: File | undefined) => {
        if (!file || !setting) return;
        if (file.size > 1048576) {
            toast('error', t('err.upload_too_big'));
            return;
        }
        const data = await readBase64(file);
        const id = newRequestId();
        const total = Math.max(1, Math.ceil(data.length / CHUNK));
        for (let i = 0; i < total; i++) {
            setUploading(t('sysadmin.ui.uploading', { n: i + 1, total }));
            const res = await run(
                'server:admin:uploadLogo',
                {
                    department: setting.key,
                    uploadId: id,
                    index: i + 1,
                    total,
                    data: data.slice(i * CHUNK, (i + 1) * CHUNK),
                },
                { requestId: false, silent: true },
            );
            if (!res.ok) {
                setUploading(null);
                toast('error', errText(res.error || 'err.internal'));
                return;
            }
        }
        setUploading(null);
        toast('success', t('sysadmin.ui.upload_done'));
        onSaved();
    };

    return (
        <Dialog
            open
            onClose={onClose}
            size="lg"
            title={isNew ? t('sysadmin.ui.dept_add') : t('sysadmin.ui.dept_edit_title', { name: setting.label })}
            description={isNew ? t('sysadmin.ui.dept_add_desc') : undefined}
            footer={
                <>
                    <Button variant="ghost" onClick={onClose} disabled={busy}>
                        {t('common.cancel')}
                    </Button>
                    <Button
                        variant="primary"
                        icon="check"
                        loading={busy && !uploading}
                        disabled={!label.trim() || !short.trim() || !jobs.length || (isNew && !key.trim())}
                        onClick={() => void save()}
                    >
                        {t('common.save')}
                    </Button>
                </>
            }
        >
            <div className="system-stack">
                <Grid min={200} gap={3}>
                    {isNew ? (
                        <Field label={t('sysadmin.ui.dept_key')} hint={t('sysadmin.ui.dept_key_hint')} required>
                            <TextInput value={key} onChange={v => setKey(v.toLowerCase())} maxLength={32} />
                        </Field>
                    ) : null}
                    <Field label={t('sysadmin.ui.dept_label')} required>
                        <TextInput value={label} onChange={setLabel} maxLength={64} />
                    </Field>
                    <Field label={t('sysadmin.ui.dept_short')} required>
                        <TextInput value={short} onChange={setShort} maxLength={16} />
                    </Field>
                    <Field label={t('sysadmin.ui.dept_grade')} hint={t('sysadmin.ui.dept_grade_hint')}>
                        {firstJob && firstJob.grades.length ? (
                            <Select
                                value={String(grade ?? '')}
                                onChange={v => setGrade(Number(v))}
                                options={firstJob.grades.map(g => ({
                                    value: String(g.level),
                                    label: g.name ? `${g.level} ${g.name}` : String(g.level),
                                }))}
                            />
                        ) : (
                            <NumberInput value={grade} onChange={setGrade} min={0} max={100} integer />
                        )}
                    </Field>
                    {setup.cashSource === 'society' ? (
                        <Field label={t('sysadmin.ui.dept_account')} hint={t('sysadmin.ui.dept_account_hint')}>
                            <TextInput value={account} onChange={setAccount} maxLength={50} />
                        </Field>
                    ) : null}
                    {isNew ? (
                        <Field label={t('sysadmin.ui.dept_theme_from')}>
                            <Select
                                value={themeFrom}
                                onChange={setThemeFrom}
                                options={asArray(setup.departments).map(d => ({ value: d.key, label: d.label }))}
                            />
                        </Field>
                    ) : null}
                </Grid>
                <Field label={t('sysadmin.ui.dept_jobs')} hint={t('sysadmin.ui.dept_jobs_hint')} required>
                    <div className="dept-admin-jobs">
                        {asArray(setup.jobs).length ? (
                            asArray(setup.jobs).map(j => {
                                const taken = !!j.usedBy && j.usedBy !== setting?.key;
                                return (
                                    <Checkbox
                                        key={j.name}
                                        checked={jobs.includes(j.name)}
                                        disabled={taken}
                                        onChange={on => toggleJob(j.name, on)}
                                        label={
                                            taken
                                                ? t('sysadmin.ui.dept_job_taken', { job: j.name, by: j.usedBy ?? '' })
                                                : `${j.name}${j.label ? ` (${j.label})` : ''}`
                                        }
                                    />
                                );
                            })
                        ) : (
                            <TextInput
                                value={jobs.join(', ')}
                                onChange={v =>
                                    setJobs(
                                        v
                                            .split(',')
                                            .map(x => x.trim())
                                            .filter(Boolean),
                                    )
                                }
                            />
                        )}
                    </div>
                </Field>
                {!isNew ? (
                    <Grid min={150} gap={3}>
                        {THEME_KEYS.map(k => (
                            <Field key={k} label={t(`admin.depts.colour.${k}`)}>
                                <TextInput
                                    value={theme[k] ?? ''}
                                    onChange={v => setTheme(prev => ({ ...prev, [k]: v }))}
                                    maxLength={7}
                                    invalid={!!theme[k] && !HEX.test(theme[k] ?? '')}
                                    placeholder="#rrggbb"
                                />
                            </Field>
                        ))}
                    </Grid>
                ) : null}
                <Grid min={220} gap={3}>
                    <Field label={t('sysadmin.ui.dept_logo_url')} hint={t('sysadmin.ui.dept_logo_url_hint')}>
                        <TextInput value={logoUrl} onChange={setLogoUrl} maxLength={512} placeholder="https://" />
                    </Field>
                    <Field label={t('sysadmin.ui.dept_logo_file')} hint={t('sysadmin.ui.dept_logo_file_hint')}>
                        <TextInput value={logoFile} onChange={setLogoFile} maxLength={100} placeholder="bcso.png" />
                    </Field>
                </Grid>
                <Toggle checked={watermark} onChange={setWatermark} label={t('sysadmin.ui.dept_watermark')} />
                {!isNew ? (
                    <Field label={t('sysadmin.ui.dept_upload')} hint={t('sysadmin.ui.dept_upload_hint')}>
                        <input
                            type="file"
                            accept="image/png,image/webp"
                            disabled={busy}
                            onChange={e => void upload(e.target.files?.[0])}
                        />
                    </Field>
                ) : null}
                {uploading ? <div className="system-muted">{uploading}</div> : null}
                <div className="system-note">
                    <Icon name="info" size={14} />
                    <span>{t(isNew ? 'sysadmin.ui.dept_checklist' : 'sysadmin.ui.dept_edit_note')}</span>
                </div>
            </div>
        </Dialog>
    );
}

// ============================================================================
//                                    DESKS
// ============================================================================

type DeskForm = {
    label: string;
    size: { x: number; y: number; z: number };
    rotation: number;
    departments: string[];
    prop: string;
};

function formOf(d: DeskView | null): DeskForm {
    return {
        label: d?.label ?? '',
        size: d?.size ?? { x: 1.2, y: 0.8, z: 1.0 },
        rotation: d?.rotation ?? 0,
        departments: asArray(d?.departments),
        prop: d?.prop ?? '',
    };
}

function DeskDialog({
    desk,
    departments,
    onClose,
    onSaved,
}: {
    desk: DeskView | null;
    departments: DepartmentSetting[];
    onClose: () => void;
    onSaved: () => void;
}) {
    const { run, busy } = useAdminAction();
    const [f, setF] = useState<DeskForm>(formOf(desk));
    const [moveHere, setMoveHere] = useState(false);
    const set = <K extends keyof DeskForm>(k: K, v: DeskForm[K]) => setF(prev => ({ ...prev, [k]: v }));
    const save = async () => {
        const payload = {
            label: f.label.trim(),
            size: f.size,
            rotation: f.rotation,
            departments: f.departments,
            prop: f.prop.trim(),
        };
        const res = desk
            ? await run(
                  'server:admin:updateDesk',
                  { index: desk.index, moveHere, ...payload },
                  { requestId: false, success: 'sysadmin.ui.desk_saved' },
              )
            : await run('server:admin:addDeskHere', payload, { requestId: false, success: 'sysadmin.ui.desk_added' });
        if (res.ok) onSaved();
    };
    return (
        <Dialog
            open
            onClose={onClose}
            title={desk ? t('sysadmin.ui.desk_edit') : t('sysadmin.ui.desk_add')}
            description={desk ? undefined : t('sysadmin.ui.desk_add_desc')}
            footer={
                <>
                    <Button variant="ghost" onClick={onClose} disabled={busy}>
                        {t('common.cancel')}
                    </Button>
                    <Button
                        variant="primary"
                        icon="check"
                        loading={busy}
                        disabled={!f.label.trim()}
                        onClick={() => void save()}
                    >
                        {t('common.save')}
                    </Button>
                </>
            }
        >
            <div className="system-stack">
                <Field label={t('sysadmin.ui.desk_label')} required>
                    <TextInput value={f.label} onChange={v => set('label', v)} maxLength={64} />
                </Field>
                <Grid cols={4} gap={2}>
                    {(['x', 'y', 'z'] as const).map(p => (
                        <Field key={p} label={t(`sysadmin.ui.desk_size_${p}`)}>
                            <NumberInput
                                value={f.size[p]}
                                onChange={v => set('size', { ...f.size, [p]: v ?? 1 })}
                                min={0.3}
                                max={5}
                                step={0.1}
                            />
                        </Field>
                    ))}
                    <Field label={t('sysadmin.ui.desk_rotation')}>
                        <NumberInput
                            value={f.rotation}
                            onChange={v => set('rotation', v ?? 0)}
                            min={0}
                            max={360}
                            step={5}
                        />
                    </Field>
                </Grid>
                <Field label={t('sysadmin.ui.desk_departments')} hint={t('sysadmin.ui.desk_departments_hint')}>
                    <div className="dept-admin-jobs">
                        {departments.map(d => (
                            <Checkbox
                                key={d.key}
                                checked={f.departments.includes(d.key)}
                                onChange={on =>
                                    set(
                                        'departments',
                                        on ? [...f.departments, d.key] : f.departments.filter(k => k !== d.key),
                                    )
                                }
                                label={d.label}
                            />
                        ))}
                    </div>
                </Field>
                <Field label={t('sysadmin.ui.desk_prop')} hint={t('sysadmin.ui.desk_prop_hint')}>
                    <TextInput
                        value={f.prop}
                        onChange={v => set('prop', v)}
                        maxLength={64}
                        placeholder="prop_laptop_01a"
                    />
                </Field>
                {desk ? (
                    <Checkbox checked={moveHere} onChange={setMoveHere} label={t('sysadmin.ui.desk_move_here')} />
                ) : null}
            </div>
        </Dialog>
    );
}

export function DesksPanel({
    access,
    departments,
    onChanged,
}: {
    access: TabletAccessView | null;
    departments: DepartmentSetting[];
    onChanged: () => void;
}) {
    const { run, busy } = useAdminAction();
    const [editing, setEditing] = useState<DeskView | 'new' | null>(null);
    const [removing, setRemoving] = useState<DeskView | null>(null);
    const desks = asArray(access?.desks);
    const remove = async () => {
        if (!removing) return;
        const res = await run(
            'server:admin:removeDesk',
            { index: removing.index },
            { requestId: false, success: 'sysadmin.ui.desk_removed' },
        );
        setRemoving(null);
        if (res.ok) onChanged();
    };
    const teleport = (d: DeskView) => void run('server:admin:teleportToDesk', { index: d.index }, { requestId: false });
    return (
        <div className="system-stack">
            <div className="system-buttons">
                <span className="system-muted">{t('sysadmin.ui.desks_text', { n: desks.length })}</span>
                <span className="cp-spacer" />
                <Button
                    variant="primary"
                    icon="mapPin"
                    disabled={busy || desks.length >= 50}
                    onClick={() => setEditing('new')}
                >
                    {t('sysadmin.ui.desk_add')}
                </Button>
            </div>
            {access && !access.ways.desk ? (
                <div className="system-note system-note--warning">
                    <Icon name="alert" size={14} />
                    <span>{t('access.depts.desks_off')}</span>
                </div>
            ) : null}
            {!desks.length ? (
                <EmptyState compact icon="mapPin" title={t('access.depts.no_desks')} />
            ) : (
                <ul className="access-desks">
                    {desks.map(d => (
                        <li key={d.index} className="access-desk">
                            <Icon name="building" size={16} />
                            <div className="access-desk__main">
                                <strong>{d.label}</strong>
                                <span className="access-desk__coords">
                                    {d.coords.x.toFixed(2)}, {d.coords.y.toFixed(2)}, {d.coords.z.toFixed(2)} ·{' '}
                                    {t('access.depts.desk_size', { x: d.size.x, y: d.size.y, r: d.rotation })}
                                </span>
                            </div>
                            <div className="system-buttons">
                                <IconButton
                                    icon="navigation"
                                    size="sm"
                                    variant="ghost"
                                    label={t('sysadmin.ui.teleport')}
                                    disabled={busy}
                                    onClick={() => teleport(d)}
                                />
                                <IconButton
                                    icon="edit"
                                    size="sm"
                                    variant="ghost"
                                    label={t('sysadmin.ui.desk_edit')}
                                    disabled={busy}
                                    onClick={() => setEditing(d)}
                                />
                                <IconButton
                                    icon="trash"
                                    size="sm"
                                    variant="ghost"
                                    label={t('sysadmin.ui.desk_remove')}
                                    disabled={busy}
                                    onClick={() => setRemoving(d)}
                                />
                            </div>
                        </li>
                    ))}
                </ul>
            )}
            {editing ? (
                <DeskDialog
                    desk={editing === 'new' ? null : editing}
                    departments={departments}
                    onClose={() => setEditing(null)}
                    onSaved={() => {
                        setEditing(null);
                        onChanged();
                    }}
                />
            ) : null}
            <ConfirmDialog
                open={!!removing}
                tone="danger"
                title={t('sysadmin.ui.desk_remove')}
                message={t('sysadmin.ui.desk_remove_text', { name: removing?.label ?? '' })}
                onConfirm={remove}
                onCancel={() => setRemoving(null)}
                busy={busy}
            />
        </div>
    );
}
