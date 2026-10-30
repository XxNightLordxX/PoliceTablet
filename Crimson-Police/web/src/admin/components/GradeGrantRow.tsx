// Admin UI · Permissions: who may use a supervisor power, by department (from a grade, these grades, or the default).

import { useEffect, useState } from 'react';
import { Badge, Button, Checkbox, Select } from '../../shared/components';
import { t } from '../../shared/i18n';
import type { TeleportDepartment, TeleportGrant } from '../../types/oversight';

type GrantMode = 'off' | 'min' | 'list';

const gradeName = (d: TeleportDepartment, level: number) => {
    const g = d.grades.find(x => x.level === level);
    return g?.name ? `${level} ${g.name}` : String(level);
};

function summary(d: TeleportDepartment, prefix: string): string {
    const g = d.grant;
    if (g?.minGrade !== undefined) return t(`${prefix}.summary_min`, { grade: gradeName(d, g.minGrade) });
    if (g?.grades) return t(`${prefix}.summary_list`, { grades: g.grades.join(', ') });
    return t(`${prefix}.summary_off`);
}

// One department: Off / From grade N / These grades, saved with the whole grant map (Config.Permissions.builderTeleport
// or Config.MissionControls.grants). prefix: the locale keys of the wording (admin.perms.teleport.mode_off ...).
export function GradeGrantRow({
    dept,
    busy,
    onSave,
    prefix = 'admin.perms.teleport',
}: {
    dept: TeleportDepartment;
    busy: boolean;
    onSave: (grant: TeleportGrant | undefined) => void;
    prefix?: string;
}) {
    const initialMode = (): GrantMode =>
        dept.grant?.minGrade !== undefined ? 'min' : dept.grant?.grades ? 'list' : 'off';
    const lowest = dept.supervisorGrade ?? dept.grades[0]?.level ?? 0;
    const [mode, setMode] = useState<GrantMode>(initialMode);
    const [minGrade, setMinGrade] = useState<number>(dept.grant?.minGrade ?? lowest);
    const [picked, setPicked] = useState<number[]>(dept.grant?.grades ?? []);
    const grantKey = JSON.stringify(dept.grant ?? null);
    useEffect(() => {
        setMode(initialMode());
        setMinGrade(dept.grant?.minGrade ?? lowest);
        setPicked(dept.grant?.grades ?? []);
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [grantKey]);
    const next: TeleportGrant | undefined =
        mode === 'min' ? { minGrade } : mode === 'list' ? { grades: [...picked].sort((a, b) => a - b) } : undefined;
    const dirty = JSON.stringify(next ?? null) !== grantKey;
    const invalid = mode === 'list' && picked.length === 0;
    const toggle = (level: number, on: boolean) =>
        setPicked(p => (on ? [...p.filter(x => x !== level), level] : p.filter(x => x !== level)));
    return (
        <li className="oversight-teleport-row">
            <div className="oversight-teleport-row__head">
                <div className="oversight-perm-name">
                    <strong>{dept.label}</strong>
                    <code>{dept.key}</code>
                </div>
                <Badge tone={dept.grant ? 'success' : 'grey'} size="sm">
                    {summary(dept, prefix)}
                </Badge>
            </div>
            <div className="oversight-teleport-row__controls">
                <Select
                    aria-label={t(`${prefix}.mode`)}
                    value={mode}
                    onChange={v => setMode(v as GrantMode)}
                    options={[
                        { value: 'off', label: t(`${prefix}.mode_off`) },
                        { value: 'min', label: t(`${prefix}.mode_min`) },
                        { value: 'list', label: t(`${prefix}.mode_list`) },
                    ]}
                />
                {mode === 'min' ? (
                    <Select
                        aria-label={t(`${prefix}.min_grade`)}
                        value={String(minGrade)}
                        onChange={v => setMinGrade(Number(v))}
                        options={dept.grades.map(g => ({ value: String(g.level), label: gradeName(dept, g.level) }))}
                    />
                ) : null}
                <Button size="sm" icon="check" disabled={busy || !dirty || invalid} onClick={() => onSave(next)}>
                    {t(`${prefix}.save`)}
                </Button>
            </div>
            {mode === 'list' ? (
                <div className="oversight-teleport-row__grades">
                    {dept.grades.map(g => (
                        <Checkbox
                            key={g.level}
                            checked={picked.includes(g.level)}
                            onChange={on => toggle(g.level, on)}
                            label={gradeName(dept, g.level)}
                        />
                    ))}
                    {invalid ? <span className="oversight-perm-desc">{t(`${prefix}.pick_one`)}</span> : null}
                </div>
            ) : null}
            {dept.supervisorGrade !== undefined ? (
                <span className="oversight-perm-desc">
                    {t(`${prefix}.supervisor_from`, { grade: gradeName(dept, dept.supervisorGrade) })}
                </span>
            ) : null}
        </li>
    );
}
