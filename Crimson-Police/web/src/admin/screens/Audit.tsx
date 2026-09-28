// Admin UI · Audit Log (screen key 'admin_audit').
// Every supervisor and admin action (cp_audit), newest first, filterable by category, action, actor and
// date range, 50 per page. Export shows the filtered rows as CSV in a dialog with a copy button.
// Data: callbacks admin:getAudit { category, action, actor, from, to, page } and admin:exportAudit (modules/admin).
import { useEffect, useMemo, useRef, useState } from 'react';
import {
  Badge, Button, Card, Dialog, EmptyState, ErrorState, Field, Icon, IconButton, Screen, SearchInput, Select, Spinner, Table, TextInput,
  type TableColumn,
} from '../../shared/components';
import { asArray } from '../../shared/data';
import { formatDateTime, formatNumber } from '../../shared/format';
import { useRequest } from '../../shared/hooks';
import { hasKey, t } from '../../shared/i18n';
import { request } from '../../shared/nui';
import { toast } from '../../shared/toast';
import type { AuditExport, AuditFilters, AuditPage, AuditRow } from '../../types/oversight';
import './Audit.css';

const CATEGORIES = ['audit', 'flags', 'builder', 'operations'] as const;
const CATEGORY_TONE: Record<string, 'primary' | 'warning' | 'accent' | 'neutral'> = { audit: 'primary', flags: 'warning', builder: 'accent', operations: 'neutral' };
const ROLE_TONE: Record<string, 'danger' | 'primary' | 'grey'> = { admin: 'danger', supervisor: 'primary', console: 'grey' };

const shortTarget = (s: string) => (s.length > 26 ? `${s.slice(0, 24)}…` : s);
const actionLabel = (a: string) => (hasKey(`admin.action.${a}`) ? t(`admin.action.${a}`) : a);

function useDebounced<T>(value: T, ms: number): T {
  const [v, setV] = useState(value);
  useEffect(() => {
    const id = setTimeout(() => setV(value), ms);
    return () => clearTimeout(id);
  }, [value, ms]);
  return v;
}

function copyText(text: string, el: HTMLTextAreaElement | null): boolean {
  try {
    if (navigator.clipboard && window.isSecureContext) {
      void navigator.clipboard.writeText(text);
      return true;
    }
  } catch {
    /* fall back below */
  }
  if (!el) return false;
  el.focus();
  el.select();
  try {
    return document.execCommand('copy');
  } catch {
    return false;
  }
}

export default function AdminAudit() {
  const [category, setCategory] = useState('');
  const [action, setAction] = useState('');
  const [actor, setActor] = useState('');
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [page, setPage] = useState(1);
  const actorQ = useDebounced(actor.trim(), 350);

  const filters: AuditFilters = useMemo(() => {
    const f: AuditFilters = { page };
    if (category) f.category = category;
    if (action) f.action = action;
    if (actorQ) f.actor = actorQ;
    if (from) f.from = from;
    if (to) f.to = to;
    return f;
  }, [category, action, actorQ, from, to, page]);

  useEffect(() => setPage(1), [category, action, actorQ, from, to]);

  const { data, loading, error, refetch } = useRequest<AuditPage>('admin:getAudit', filters);
  const [exporting, setExporting] = useState(false);
  const [exported, setExported] = useState<AuditExport | null>(null);
  const area = useRef<HTMLTextAreaElement>(null);

  const rows = asArray(data?.rows);
  const actions = asArray(data?.actions);
  const pages = data?.pages ?? 1;
  const current = data?.page ?? page;
  const filtered = !!(category || action || actorQ || from || to);

  const doExport = async () => {
    setExporting(true);
    const { page: _unused, ...rest } = filters;
    void _unused;
    const res = await request<AuditExport>('admin:exportAudit', rest);
    setExporting(false);
    if (res.ok && res.data) setExported(res.data);
    else toast('error', t(res.error || 'err.internal'));
  };

  const copy = () => {
    if (!exported) return;
    if (copyText(exported.csv, area.current)) toast('success', t('admin.audit.copied'));
    else toast('warning', t('admin.audit.copy_failed'));
  };

  const clear = () => {
    setCategory('');
    setAction('');
    setActor('');
    setFrom('');
    setTo('');
  };

  const columns: TableColumn<AuditRow>[] = [
    { key: 'time', header: t('admin.audit.col.time'), width: 112, render: (r) => <span className="cp-num oversight-aud-soft oversight-aud-nowrap">{formatDateTime(r.createdAt)}</span> },
    {
      key: 'actor', header: t('admin.audit.col.actor'), width: 172,
      render: (r) => (
        <div className="oversight-aud-actor">
          <span className="oversight-aud-actor__name">{r.actor === 'console' ? t('admin.actor.console') : (r.actorName || r.actor)}</span>
          <span className="oversight-aud-actor__sub">
            <Badge size="sm" tone={ROLE_TONE[r.role] ?? 'grey'}>{t(`admin.role.${r.role}`)}</Badge>
            {r.actorName && r.actor !== 'console' ? <code>{r.actor}</code> : null}
          </span>
        </div>
      ),
    },
    {
      key: 'action', header: t('admin.audit.col.action'), width: 184,
      render: (r) => (
        <div className="oversight-aud-action">
          <strong>{actionLabel(r.action)}</strong>
          <Badge size="sm" variant="outline" tone={CATEGORY_TONE[r.category] ?? 'neutral'}>{t(`admin.category.${r.category}`)}</Badge>
        </div>
      ),
    },
    { key: 'target', header: t('admin.audit.col.target'), width: 150, render: (r) => (r.target ? <code className="oversight-aud-code" title={r.target}>{shortTarget(r.target)}</code> : <span className="oversight-aud-soft">—</span>) },
    {
      key: 'change', header: t('admin.audit.col.change'), width: 176,
      render: (r) => (r.oldValue || r.newValue ? (
        <span className="oversight-aud-change" title={`${r.oldValue ?? '—'} → ${r.newValue ?? '—'}`}>
          <span className="oversight-aud-old">{r.oldValue ?? '—'}</span>
          <Icon name="chevronRight" size={12} />
          <span className="oversight-aud-new">{r.newValue ?? '—'}</span>
        </span>
      ) : <span className="oversight-aud-soft">—</span>),
    },
    { key: 'reason', header: t('admin.audit.col.reason'), render: (r) => (r.reason ? <span className="oversight-aud-reason" title={r.reason}>{r.reason}</span> : <span className="oversight-aud-soft">—</span>) },
  ];

  return (
    <Screen
      title={t('ui.screen.admin_audit')}
      subtitle={t('admin.audit.subtitle')}
      actions={
        <>
          <IconButton icon="refresh" label={t('sup.refresh')} variant="secondary" loading={loading && !!data} onClick={() => void refetch()} />
          <Button variant="primary" icon="download" loading={exporting} onClick={() => void doExport()}>{t('admin.audit.export')}</Button>
        </>
      }
      className="oversight-screen"
    >
      <Card padding="sm" className="oversight-aud-filters">
        <div className="oversight-aud-filters__row">
          <Field label={t('admin.audit.filter.category')} className="oversight-aud-f-cat">
            <Select value={category} onChange={setCategory} options={[{ value: '', label: t('admin.audit.all_categories') }, ...CATEGORIES.map((c) => ({ value: c, label: t(`admin.category.${c}`) }))]} />
          </Field>
          <Field label={t('admin.audit.filter.action')} className="oversight-aud-f-action">
            <Select value={action} onChange={setAction} options={[{ value: '', label: t('admin.audit.all_actions') }, ...actions.map((a) => ({ value: a, label: actionLabel(a) }))]} />
          </Field>
          <Field label={t('admin.audit.filter.actor')} className="oversight-aud-filters__grow">
            <SearchInput value={actor} onChange={setActor} placeholder={t('admin.audit.actor_placeholder')} />
          </Field>
          <Field label={t('admin.audit.filter.from')} className="oversight-aud-f-date">
            <TextInput type="date" value={from} onChange={setFrom} max={to || undefined} />
          </Field>
          <Field label={t('admin.audit.filter.to')} className="oversight-aud-f-date">
            <TextInput type="date" value={to} onChange={setTo} min={from || undefined} />
          </Field>
          <Button variant="ghost" icon="x" disabled={!filtered} onClick={clear} className="oversight-aud-filters__clear">{t('admin.audit.clear')}</Button>
        </div>
      </Card>

      {error && !data ? (
        <Card><ErrorState error={error} onRetry={() => void refetch()} /></Card>
      ) : (
        <Table
          columns={columns}
          rows={rows}
          rowKey={(r) => r.id}
          loading={loading}
          dense
          className="oversight-aud-table"
          empty={<EmptyState compact icon="fileText" title={filtered ? t('admin.audit.empty_filtered') : t('admin.audit.empty')} />}
          aria-label={t('ui.screen.admin_audit')}
        />
      )}

      <div className="oversight-aud-pager">
        <span className="oversight-aud-soft cp-num">{t('admin.audit.total', { n: formatNumber(data?.total ?? 0) })}</span>
        <div className="oversight-aud-pager__nav">
          {loading && data ? <Spinner size={14} /> : null}
          <Button size="sm" variant="secondary" icon="chevronLeft" disabled={current <= 1 || loading} onClick={() => setPage(Math.max(1, current - 1))}>{t('admin.audit.prev')}</Button>
          <span className="cp-num oversight-aud-page">{t('admin.audit.page', { page: current, pages })}</span>
          <Button size="sm" variant="secondary" iconRight="chevronRight" disabled={current >= pages || loading} onClick={() => setPage(Math.min(pages, current + 1))}>{t('admin.audit.next')}</Button>
        </div>
      </div>

      <Dialog
        open={!!exported}
        onClose={() => setExported(null)}
        size="lg"
        title={t('admin.audit.export_title')}
        description={exported ? t('admin.audit.export_desc', { n: formatNumber(exported.rows) }) : undefined}
        footer={
          <>
            <Button variant="ghost" onClick={() => setExported(null)}>{t('common.close')}</Button>
            <Button variant="primary" icon="check" onClick={copy}>{t('admin.audit.copy')}</Button>
          </>
        }
      >
        {exported ? (
          <div className="oversight-aud-export">
            {exported.truncated ? <div className="oversight-aud-warn"><Icon name="alert" size={14} />{t('admin.audit.export_truncated', { n: formatNumber(exported.rows) })}</div> : null}
            <textarea ref={area} className="oversight-aud-csv" readOnly value={exported.csv} spellCheck={false} aria-label={t('admin.audit.export_title')} />
          </div>
        ) : null}
      </Dialog>
    </Screen>
  );
}
