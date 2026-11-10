import { useMemo, useState, type CSSProperties, type KeyboardEvent, type ReactNode } from 'react';
import { cx } from '../cx';
import { t } from '../i18n';
import { useRowWindow } from '../rowWindow';
import { EmptyState, Spinner } from './Feedback';
import { SearchInput } from './Form';
import { Icon } from './Icon';
import { Pager } from './Pager';

export interface TableColumn<R> {
    key: string;
    header: ReactNode;
    // Cell content; default: String(row[key]).
    render?: (row: R, index: number) => ReactNode;
    width?: number | string;
    align?: 'left' | 'center' | 'right';
    // Tabular numbers, right aligned.
    numeric?: boolean;
    className?: string;
    // Click the header to sort by this column (ascending, descending, then back to the given order).
    sortable?: boolean;
    // The value it sorts by (default: row[key]); numbers sort as numbers, the rest as text.
    sortValue?: (row: R) => string | number | null | undefined;
}

export interface TableSort {
    key: string;
    dir: 'asc' | 'desc';
}

export interface TableProps<R> {
    columns: TableColumn<R>[];
    rows: R[] | null | undefined;
    // Stable row key (default: row.id, then the index).
    rowKey?: (row: R, index: number) => string | number;
    onRowClick?: (row: R, index: number) => void;
    // Rows to highlight (e.g. the viewer's own leaderboard row).
    highlightRow?: (row: R, index: number) => boolean;
    // An extra class for a row (e.g. 'is-muted' for a greyed row).
    rowClassName?: (row: R, index: number) => string | undefined;
    // Shown when rows is empty: a string title or any node.
    empty?: ReactNode;
    loading?: boolean;
    // Header stays visible while scrolling (default true).
    stickyHeader?: boolean;
    // Scroll inside the table at this height (px or CSS length); otherwise the screen scrolls.
    maxHeight?: number | string;
    dense?: boolean;
    // Extra row(s) pinned under the body, e.g. "your row" on a leaderboard.
    footer?: ReactNode;
    // Draw only the rows in view (default true); only with maxHeight and more than 100 rows. false = every row.
    windowRows?: boolean;
    // A search box over the table: rows whose text (default: every column's plain value) holds every typed word.
    filter?: boolean | { text?: (row: R) => string; placeholder?: string };
    // Show this many rows a page with the shared Pager under the table (client side; none = every row).
    pageSize?: number;
    // The sort before the viewer clicks a header.
    defaultSort?: TableSort;
    className?: string;
    'aria-label'?: string;
}

function plain(v: unknown): string {
    if (v === null || v === undefined) return '';
    return typeof v === 'object' ? '' : String(v);
}

// The rows in the order of `sort` (a stable sort; empty values last either way).
export function sortRows<R>(rows: R[], columns: TableColumn<R>[], sort: TableSort | null): R[] {
    const col = sort ? columns.find(c => c.key === sort.key) : undefined;
    if (!sort || !col) return rows;
    const value = (r: R) => (col.sortValue ? col.sortValue(r) : (r as Record<string, unknown>)[col.key]);
    const sign = sort.dir === 'desc' ? -1 : 1;
    return rows
        .map((row, i) => ({ row, i, v: value(row) }))
        .sort((a, b) => {
            const ae = a.v === null || a.v === undefined || a.v === '';
            const be = b.v === null || b.v === undefined || b.v === '';
            if (ae || be) return ae === be ? a.i - b.i : ae ? 1 : -1;
            const d =
                typeof a.v === 'number' && typeof b.v === 'number'
                    ? a.v - b.v
                    : plain(a.v).localeCompare(plain(b.v), undefined, { numeric: true, sensitivity: 'base' });
            return d !== 0 ? d * sign : a.i - b.i;
        })
        .map(x => x.row);
}

// The rows whose text holds every word of `query` (case does not matter); an empty query keeps every row.
export function filterRows<R>(rows: R[], query: string, text: (row: R) => string): R[] {
    const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
    if (!words.length) return rows;
    return rows.filter(r => {
        const hay = text(r).toLowerCase();
        return words.every(w => hay.includes(w));
    });
}

// One page of the rows (pages count from 1; a page past the end shows the last one) and the page count.
export function pageRows<R>(rows: R[], page: number, size: number): { rows: R[]; page: number; pages: number } {
    if (!(size > 0)) return { rows, page: 1, pages: 1 };
    const pages = Math.max(1, Math.ceil(rows.length / size));
    const p = Math.min(Math.max(1, Math.floor(page) || 1), pages);
    return { rows: rows.slice((p - 1) * size, p * size), page: p, pages };
}

function cellValue<R>(row: R, key: string): ReactNode {
    const v = (row as Record<string, unknown>)[key];
    if (v === null || v === undefined) return '';
    return typeof v === 'object' ? JSON.stringify(v) : String(v);
}

export function Table<R>({
    columns,
    rows,
    rowKey,
    onRowClick,
    highlightRow,
    rowClassName,
    empty,
    loading,
    stickyHeader = true,
    maxHeight,
    dense,
    footer,
    className,
    windowRows,
    filter,
    pageSize,
    defaultSort,
    ...aria
}: TableProps<R>) {
    const [sort, setSort] = useState<TableSort | null>(defaultSort ?? null);
    const [query, setQuery] = useState('');
    const [page, setPage] = useState(1);
    const filterText = typeof filter === 'object' && filter.text ? filter.text : null;
    // Lua encodes an empty table as {} (not []), so anything that is not an array counts as no rows.
    const given: R[] = Array.isArray(rows) ? rows : [];
    const shaped = useMemo(() => {
        const text = filterText ?? ((r: R) => columns.map(c => plain((r as Record<string, unknown>)[c.key])).join(' '));
        const found = filter ? filterRows(given, query, text) : given;
        return sortRows(found, columns, sort);
    }, [given, columns, sort, query, filter, filterText]);
    const paged = pageRows(shaped, page, pageSize ?? 0);
    const list = paged.rows;
    const clickSort = (key: string) => {
        setSort(s => (s?.key !== key ? { key, dir: 'asc' } : s.dir === 'asc' ? { key, dir: 'desc' } : null));
        setPage(1);
    };
    const viewGuess = typeof maxHeight === 'number' ? maxHeight : 480;
    const { win, onScroll, rowRef } = useRowWindow(
        list.length,
        maxHeight !== undefined && windowRows !== false,
        viewGuess,
        dense ? 32 : 44,
    );
    const shownRows = win.start === 0 && win.end === list.length ? list : list.slice(win.start, win.end);
    const span = columns.length || 1;
    const wrapStyle: CSSProperties | undefined = maxHeight !== undefined ? { maxHeight, overflow: 'auto' } : undefined;
    const keyOf = (row: R, i: number) => (rowKey ? rowKey(row, i) : ((row as { id?: string | number }).id ?? i));
    const onKey = (row: R, i: number) => (e: KeyboardEvent<HTMLTableRowElement>) => {
        if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault();
            onRowClick?.(row, i);
        }
    };

    const table = (
        <div
            className={cx(
                'cp-table-wrap',
                stickyHeader && 'cp-table-wrap--sticky',
                maxHeight !== undefined && 'cp-table-wrap--scroll',
                className,
            )}
            style={wrapStyle}
            onScroll={maxHeight !== undefined ? onScroll : undefined}
        >
            <table
                className={cx('cp-table', dense && 'cp-table--dense', onRowClick && 'cp-table--clickable')}
                aria-label={aria['aria-label']}
                aria-busy={loading || undefined}
            >
                <thead>
                    <tr>
                        {columns.map(c => (
                            <th
                                key={c.key}
                                style={{ width: c.width, textAlign: c.align ?? (c.numeric ? 'right' : 'left') }}
                                className={cx(c.className, c.sortable && 'cp-table__sortable')}
                                scope="col"
                                aria-sort={
                                    sort?.key === c.key ? (sort.dir === 'asc' ? 'ascending' : 'descending') : undefined
                                }
                            >
                                {c.sortable ? (
                                    <button type="button" className="cp-table__sort" onClick={() => clickSort(c.key)}>
                                        {c.header}
                                        <Icon
                                            name={
                                                sort?.key === c.key && sort.dir === 'desc' ? 'chevronDown' : 'chevronUp'
                                            }
                                            size={12}
                                            className={sort?.key === c.key ? 'is-on' : undefined}
                                        />
                                    </button>
                                ) : (
                                    c.header
                                )}
                            </th>
                        ))}
                    </tr>
                </thead>
                <tbody>
                    {win.padTop > 0 ? (
                        <tr aria-hidden className="cp-table__spacer">
                            <td colSpan={span} style={{ height: win.padTop, padding: 0, border: 0 }} />
                        </tr>
                    ) : null}
                    {shownRows.map((row, k) => {
                        const i = win.start + k;
                        return (
                            <tr
                                key={keyOf(row, i)}
                                ref={k === 0 ? rowRef : undefined}
                                className={cx(highlightRow?.(row, i) && 'is-highlight', rowClassName?.(row, i))}
                                onClick={onRowClick ? () => onRowClick(row, i) : undefined}
                                onKeyDown={onRowClick ? onKey(row, i) : undefined}
                                tabIndex={onRowClick ? 0 : undefined}
                            >
                                {columns.map(c => (
                                    <td
                                        key={c.key}
                                        style={{ textAlign: c.align ?? (c.numeric ? 'right' : 'left') }}
                                        className={cx(c.numeric && 'cp-num', c.className)}
                                    >
                                        {c.render ? c.render(row, i) : cellValue(row, c.key)}
                                    </td>
                                ))}
                            </tr>
                        );
                    })}
                    {win.padBottom > 0 ? (
                        <tr aria-hidden className="cp-table__spacer">
                            <td colSpan={span} style={{ height: win.padBottom, padding: 0, border: 0 }} />
                        </tr>
                    ) : null}
                </tbody>
                {footer ? <tfoot>{footer}</tfoot> : null}
            </table>
            {loading && !list.length ? (
                <div className="cp-table__state">
                    <Spinner size={20} />
                    <span>{t('common.loading')}</span>
                </div>
            ) : null}
            {!loading && !list.length ? (
                <div className="cp-table__state">
                    {typeof empty === 'string' || empty === undefined ? (
                        <EmptyState compact title={empty ?? t('common.empty')} />
                    ) : (
                        empty
                    )}
                </div>
            ) : null}
            {loading && list.length ? <div className="cp-table__refreshing" aria-hidden /> : null}
        </div>
    );
    if (!filter && !pageSize) return table;
    return (
        <div className="cp-table-box">
            {filter ? (
                <SearchInput
                    className="cp-table__filter"
                    value={query}
                    placeholder={typeof filter === 'object' ? filter.placeholder : undefined}
                    onChange={v => {
                        setQuery(v);
                        setPage(1);
                    }}
                />
            ) : null}
            {table}
            {pageSize ? <Pager page={paged.page} pages={paged.pages} onPage={setPage} /> : null}
        </div>
    );
}
