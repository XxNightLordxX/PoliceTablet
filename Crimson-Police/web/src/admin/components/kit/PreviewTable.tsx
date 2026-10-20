// PreviewTable: the exact rows an action will change (from a preview callback), with the total and a note when
// only the first rows are listed. Used inside ConfirmDialog's effect.

import type { ReactNode } from 'react';
import { Table, type TableColumn } from '../../../shared/components';
import { t } from '../../../shared/i18n';
import './kit.css';

export function PreviewTable<R>({
    columns,
    rows,
    total,
    note,
    rowKey,
}: {
    columns: TableColumn<R>[];
    rows: R[];
    // every row the action changes (rows may hold only the first of them)
    total?: number;
    note?: ReactNode;
    rowKey?: (row: R, index: number) => string | number;
}) {
    const all = total ?? rows.length;
    return (
        <div className="admin-kit-preview">
            <div className="admin-kit-preview__head">
                {t('ui.kit.preview_rows', { n: all })}
                {all > rows.length ? (
                    <span className="admin-kit-preview__more">{t('ui.kit.preview_first', { n: rows.length })}</span>
                ) : null}
            </div>
            <Table
                columns={columns}
                rows={rows}
                rowKey={rowKey}
                dense
                maxHeight={220}
                empty={t('ui.kit.preview_none')}
            />
            {note ? <div className="admin-kit-preview__note">{note}</div> : null}
        </div>
    );
}
