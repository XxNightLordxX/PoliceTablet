// RowsEditor: the base row editor for a list setting with a row template (SettingView.rows): add, remove and move
// rows, one input per field. The server checks every row and the list again (Settings.check). Position fields take
// an extra button from the host (Use my position, Teleport to) through renderPositionTools.

import type { ReactNode } from 'react';
import { Button, IconButton, NumberInput, Select, TextInput } from '../../../shared/components';
import { t } from '../../../shared/i18n';
import type { RowField, RowsDescriptor } from '../../../types/settings';
import './kit.css';

type Row = Record<string, unknown>;
type Vec = { x: number; y: number; z?: number; w?: number };

function asVec(v: unknown): Vec {
    const o = (v && typeof v === 'object' ? v : {}) as Record<string, unknown>;
    return { x: Number(o.x) || 0, y: Number(o.y) || 0, z: Number(o.z) || 0 };
}

function FieldInput({
    field,
    value,
    onChange,
    disabled,
}: {
    field: RowField;
    value: unknown;
    onChange: (v: unknown) => void;
    disabled?: boolean;
}) {
    if (field.kind === 'enum') {
        return (
            <Select
                value={String(value ?? '')}
                onChange={v => onChange(v)}
                disabled={disabled}
                options={(field.options ?? []).map(o => ({ value: o, label: o }))}
            />
        );
    }
    if (field.kind === 'number') {
        return (
            <NumberInput
                value={typeof value === 'number' ? value : null}
                onChange={v => onChange(v === null ? undefined : v)}
                min={field.min}
                max={field.max}
                integer={field.integer === true}
                step={field.integer ? 1 : 0.05}
                stepper={false}
                showRange={false}
                disabled={disabled}
                aria-label={field.key ?? ''}
            />
        );
    }
    if (field.kind === 'vector') {
        const v = asVec(value);
        const set = (part: 'x' | 'y' | 'z', n: number | null) => onChange({ ...v, [part]: n ?? 0 });
        return (
            <div className="admin-kit-rows__vec">
                {(['x', 'y', 'z'] as const).slice(0, field.size ?? 3).map(part => (
                    <NumberInput
                        key={part}
                        value={v[part] ?? 0}
                        onChange={n => set(part, n)}
                        integer={false}
                        step={0.01}
                        stepper={false}
                        showRange={false}
                        disabled={disabled}
                        aria-label={part}
                    />
                ))}
            </div>
        );
    }
    return (
        <TextInput
            value={String(value ?? '')}
            onChange={v => onChange(v)}
            maxLength={field.max}
            disabled={disabled}
            aria-label={field.key ?? ''}
        />
    );
}

export function RowsEditor({
    rows,
    value,
    onChange,
    disabled,
    renderPositionTools,
}: {
    rows: RowsDescriptor;
    value: unknown[];
    onChange: (next: unknown[]) => void;
    disabled?: boolean;
    renderPositionTools?: (index: number, set: (v: unknown) => void) => ReactNode;
}) {
    const list = Array.isArray(value) ? value : [];
    const max = rows.max ?? 500;
    const min = rows.min ?? 0;
    const fields: RowField[] = rows.bare ? [rows.bare] : (rows.fields ?? []);
    const setRow = (i: number, next: unknown) => onChange(list.map((r, k) => (k === i ? next : r)));
    const move = (i: number, d: number) => {
        const j = i + d;
        if (j < 0 || j >= list.length) return;
        const next = [...list];
        [next[i], next[j]] = [next[j], next[i]];
        onChange(next);
    };
    const blank = (): unknown => {
        if (rows.bare) return { x: 0, y: 0, z: 0 };
        const r: Row = {};
        for (const f of fields) {
            if (f.optional || !f.key) continue;
            r[f.key] =
                f.kind === 'number'
                    ? (f.min ?? 0)
                    : f.kind === 'enum'
                      ? (f.options?.[0] ?? '')
                      : f.kind === 'vector'
                        ? { x: 0, y: 0, z: 0 }
                        : '';
        }
        return r;
    };
    return (
        <div className="admin-kit-rows">
            {list.map((row, i) => (
                <div key={i} className="admin-kit-rows__row">
                    <span className="admin-kit-rows__n cp-num">{i + 1}</span>
                    <div className="admin-kit-rows__fields">
                        {fields.map(f => {
                            const v = rows.bare || !f.key ? row : (row as Row)?.[f.key];
                            const set = (nv: unknown) =>
                                setRow(i, rows.bare || !f.key ? nv : { ...((row as Row) ?? {}), [f.key]: nv });
                            return (
                                <label key={f.key ?? 'value'} className="admin-kit-rows__field">
                                    {f.key ? <span className="admin-kit-rows__label">{f.key}</span> : null}
                                    <FieldInput field={f} value={v} onChange={set} disabled={disabled} />
                                    {f.position && renderPositionTools ? renderPositionTools(i, set) : null}
                                </label>
                            );
                        })}
                    </div>
                    <div className="admin-kit-rows__tools">
                        <IconButton
                            icon="chevronUp"
                            size="sm"
                            label={t('ui.kit.row_up')}
                            disabled={disabled || i === 0}
                            onClick={() => move(i, -1)}
                        />
                        <IconButton
                            icon="chevronDown"
                            size="sm"
                            label={t('ui.kit.row_down')}
                            disabled={disabled || i === list.length - 1}
                            onClick={() => move(i, 1)}
                        />
                        <IconButton
                            icon="trash"
                            size="sm"
                            label={t('ui.kit.row_remove')}
                            disabled={disabled || list.length <= min}
                            onClick={() => onChange(list.filter((_, k) => k !== i))}
                        />
                    </div>
                </div>
            ))}
            <Button
                size="sm"
                variant="ghost"
                icon="plus"
                disabled={disabled || list.length >= max}
                onClick={() => onChange([...list, blank()])}
            >
                {t('ui.kit.row_add')}
            </Button>
        </div>
    );
}
