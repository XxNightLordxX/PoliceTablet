import type { CSSProperties, KeyboardEvent, ReactNode } from 'react';
import { cx } from '../cx';
import { t } from '../i18n';
import { EmptyState, Spinner } from './Feedback';

export interface TableColumn<R> {
  key: string;
  header: ReactNode;
  /** Cell content; default: String(row[key]). */
  render?: (row: R, index: number) => ReactNode;
  width?: number | string;
  align?: 'left' | 'center' | 'right';
  /** Tabular numbers, right aligned. */
  numeric?: boolean;
  className?: string;
}

export interface TableProps<R> {
  columns: TableColumn<R>[];
  rows: R[] | null | undefined;
  /** Stable row key (default: row.id, then the index). */
  rowKey?: (row: R, index: number) => string | number;
  onRowClick?: (row: R, index: number) => void;
  /** Rows to highlight (e.g. the viewer's own leaderboard row). */
  highlightRow?: (row: R, index: number) => boolean;
  /** Shown when rows is empty: a string title or any node. */
  empty?: ReactNode;
  loading?: boolean;
  /** Header stays visible while scrolling (default true). */
  stickyHeader?: boolean;
  /** Scroll inside the table at this height (px or CSS length); otherwise the screen scrolls. */
  maxHeight?: number | string;
  dense?: boolean;
  /** Extra row(s) pinned under the body, e.g. "your row" on a leaderboard. */
  footer?: ReactNode;
  className?: string;
  'aria-label'?: string;
}

function cellValue<R>(row: R, key: string): ReactNode {
  const v = (row as Record<string, unknown>)[key];
  if (v === null || v === undefined) return '';
  return typeof v === 'object' ? JSON.stringify(v) : String(v);
}

export function Table<R>({
  columns, rows, rowKey, onRowClick, highlightRow, empty, loading, stickyHeader = true, maxHeight, dense, footer, className, ...aria
}: TableProps<R>) {
  // Lua encodes an empty table as {} (not []), so anything that is not an array counts as no rows.
  const list: R[] = Array.isArray(rows) ? rows : [];
  const wrapStyle: CSSProperties | undefined = maxHeight !== undefined ? { maxHeight, overflow: 'auto' } : undefined;
  const keyOf = (row: R, i: number) => (rowKey ? rowKey(row, i) : ((row as { id?: string | number }).id ?? i));
  const onKey = (row: R, i: number) => (e: KeyboardEvent<HTMLTableRowElement>) => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      onRowClick?.(row, i);
    }
  };

  return (
    <div className={cx('cp-table-wrap', stickyHeader && 'cp-table-wrap--sticky', maxHeight !== undefined && 'cp-table-wrap--scroll', className)} style={wrapStyle}>
      <table className={cx('cp-table', dense && 'cp-table--dense', onRowClick && 'cp-table--clickable')} aria-label={aria['aria-label']} aria-busy={loading || undefined}>
        <thead>
          <tr>
            {columns.map((c) => (
              <th
                key={c.key}
                style={{ width: c.width, textAlign: c.align ?? (c.numeric ? 'right' : 'left') }}
                className={c.className}
                scope="col"
              >
                {c.header}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {list.map((row, i) => (
            <tr
              key={keyOf(row, i)}
              className={cx(highlightRow?.(row, i) && 'is-highlight')}
              onClick={onRowClick ? () => onRowClick(row, i) : undefined}
              onKeyDown={onRowClick ? onKey(row, i) : undefined}
              tabIndex={onRowClick ? 0 : undefined}
            >
              {columns.map((c) => (
                <td key={c.key} style={{ textAlign: c.align ?? (c.numeric ? 'right' : 'left') }} className={cx(c.numeric && 'cp-num', c.className)}>
                  {c.render ? c.render(row, i) : cellValue(row, c.key)}
                </td>
              ))}
            </tr>
          ))}
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
          {typeof empty === 'string' || empty === undefined ? <EmptyState compact title={empty ?? t('common.empty')} /> : empty}
        </div>
      ) : null}
      {loading && list.length ? <div className="cp-table__refreshing" aria-hidden /> : null}
    </div>
  );
}
