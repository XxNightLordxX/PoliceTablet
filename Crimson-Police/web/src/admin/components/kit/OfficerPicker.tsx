// OfficerPicker: find an officer by name, callsign or citizenid (admin:searchOfficers) and pick one. An officer
// without a row yet can still be named by citizenid.

import { useEffect, useState } from 'react';
import { Badge, SearchInput, Spinner } from '../../../shared/components';
import { useRequest } from '../../../shared/hooks';
import { t } from '../../../shared/i18n';
import type { OfficerSearchData, OfficerSearchRow } from '../../../types/oversight';
import './kit.css';

function useDebounced<T>(value: T, ms: number): T {
    const [v, setV] = useState(value);
    useEffect(() => {
        const id = setTimeout(() => setV(value), ms);
        return () => clearTimeout(id);
    }, [value, ms]);
    return v;
}

export function OfficerPicker({
    value,
    onChange,
    disabled,
    placeholder,
}: {
    value: string | null;
    onChange: (citizenid: string | null, officer: OfficerSearchRow | null) => void;
    disabled?: boolean;
    placeholder?: string;
}) {
    const [query, setQuery] = useState('');
    const q = useDebounced(query.trim(), 300);
    const { data, loading } = useRequest<OfficerSearchData>('admin:searchOfficers', { query: q }, { skip: q === '' });
    const list = q === '' ? [] : (data?.officers ?? []);

    if (value) {
        return (
            <div className="admin-kit-picker admin-kit-picker--chosen">
                <Badge tone="primary" icon="user">
                    {value}
                </Badge>
                {!disabled ? (
                    <button type="button" className="admin-kit-picker__clear" onClick={() => onChange(null, null)}>
                        {t('ui.kit.change')}
                    </button>
                ) : null}
            </div>
        );
    }
    return (
        <div className="admin-kit-picker">
            <SearchInput
                value={query}
                onChange={setQuery}
                disabled={disabled}
                placeholder={placeholder ?? t('ui.kit.officer_search')}
                suffix={loading ? <Spinner size={14} /> : undefined}
            />
            {list.length > 0 ? (
                <ul className="admin-kit-picker__list">
                    {list.map(o => (
                        <li key={o.citizenid}>
                            <button type="button" onClick={() => onChange(o.citizenid, o)}>
                                <span className="admin-kit-picker__name">{o.name}</span>
                                <span className="admin-kit-picker__meta">
                                    {[o.callsign, o.departmentShort, o.citizenid].filter(Boolean).join(' · ')}
                                </span>
                            </button>
                        </li>
                    ))}
                </ul>
            ) : null}
            {q !== '' && !loading && list.length === 0 && /^[A-Za-z0-9_-]{3,50}$/.test(q) ? (
                <button type="button" className="admin-kit-picker__raw" onClick={() => onChange(q, null)}>
                    {t('ui.kit.use_citizenid', { citizenid: q })}
                </button>
            ) : null}
        </div>
    );
}
