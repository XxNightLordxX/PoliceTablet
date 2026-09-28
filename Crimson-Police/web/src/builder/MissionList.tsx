// src/builder/MissionList.tsx · the Mission Builder's mission list: drafts, tested drafts, published and archived
// custom missions (builder:list) with status, version, owner and edit lock, plus the built-ins to duplicate.
// Actions (server:builder:*): create, duplicate, archive, restore, rollback, breakLock, discardDraft — each gated
// by session.actions (builderEdit / builderArchive / builderRollback / breakEditLock) AND the entry's `can` flags
// from the server; destructive ones ask for confirmation.
import { useMemo, useState } from 'react';
import {
  Badge, Button, ConfirmDialog, Dialog, EmptyState, ErrorState, Field, Icon, IconButton, LoadingBlock, SearchInput,
  SegmentedControl, Select, Table, TextInput, type BadgeTone, type TableColumn,
} from '../shared/components';
import { asArray } from '../shared/data';
import { formatDateTime, formatDuration } from '../shared/format';
import { useAction, useRequest } from '../shared/hooks';
import { t } from '../shared/i18n';
import { useCan } from '../shared/session';
import { toast } from '../shared/toast';
import type {
  BuilderConfig, BuilderCreateResult, BuilderDiscardResult, BuilderList, BuilderListEntry, BuilderRollbackResult,
} from '../types/builder_server';
import type { BuilderScope } from './store';
import { setEditorMemory } from './store';

type Filter = 'all' | 'drafts' | 'published' | 'archived';
type Confirm = { kind: 'archive' | 'restore' | 'rollback' | 'breakLock' | 'discard'; entry: BuilderListEntry } | null;

export const STATUS_TONE: Record<string, BadgeTone> = { draft: 'neutral', tested: 'accent', published: 'success', archived: 'grey' };

export function StatusBadge({ status }: { status: string }) {
  const icon = status === 'published' ? 'checkCircle' : status === 'tested' ? 'flask' : status === 'archived' ? 'inbox' : 'edit';
  return (
    <Badge tone={STATUS_TONE[status] ?? 'neutral'} icon={icon} size="sm">
      {t(`builder.status.${status}`)}
    </Badge>
  );
}

export function LockBadge({ lock }: { lock: BuilderListEntry['lock'] }) {
  if (!lock) return <span className="builder_client-muted">{t('builder.list.unlocked')}</span>;
  return (
    <Badge tone={lock.mine ? 'primary' : 'warning'} icon="lock" size="sm" title={t('builder.list.lock_left', { time: formatDuration(lock.secondsLeft) })}>
      {lock.mine ? t('builder.list.lock_you') : lock.name ?? lock.citizenid}
      <span className="cp-num builder_client-lock-time">{formatDuration(lock.secondsLeft)}</span>
    </Badge>
  );
}

export interface MissionListProps {
  scope: BuilderScope;
  config: BuilderConfig | null;
  onOpen: (id: string) => void;
}

export function MissionList({ scope, config, onOpen }: MissionListProps) {
  const can = useCan();
  const { data, loading, error, refetch } = useRequest<BuilderList>('builder:list', {}, { pushTopic: 'builder', pollMs: 30000 });
  const { run, busy } = useAction();
  const [query, setQuery] = useState('');
  const [filter, setFilter] = useState<Filter>('all');
  const [creating, setCreating] = useState(false);
  const [dupOpen, setDupOpen] = useState(false);
  const [confirm, setConfirm] = useState<Confirm>(null);

  const missions = asArray(data?.missions);
  const builtins = asArray(data?.builtins);
  const typeLabel = (key: string) => asArray(config?.missionTypes).find((m) => m.key === key)?.label ?? key;

  const counts = useMemo(() => {
    const c = { all: missions.length, drafts: 0, published: 0, archived: 0 };
    missions.forEach((m) => {
      if (m.status === 'draft' || m.status === 'tested') c.drafts += 1;
      else if (m.status === 'published') c.published += 1;
      else if (m.status === 'archived') c.archived += 1;
    });
    return c;
  }, [missions]);

  const rows = useMemo(() => {
    const q = query.trim().toLowerCase();
    return missions.filter((m) => {
      if (filter === 'drafts' && m.status !== 'draft' && m.status !== 'tested') return false;
      if (filter === 'published' && m.status !== 'published') return false;
      if (filter === 'archived' && m.status !== 'archived') return false;
      if (q && !m.label.toLowerCase().includes(q) && !m.id.toLowerCase().includes(q)) return false;
      return true;
    });
  }, [missions, query, filter]);

  const open = (id: string, step: 'blocks' | 'details' = 'details') => {
    setEditorMemory(scope, { openId: id, step, location: 1, objective: 1 });
    onOpen(id);
  };

  const doConfirm = async () => {
    if (!confirm) return;
    const { kind, entry } = confirm;
    const name = entry.label;
    let res;
    if (kind === 'archive') res = await run('server:builder:archive', { id: entry.id }, { success: 'builder.list.archived', successVars: { mission: name } });
    else if (kind === 'restore') res = await run('server:builder:restore', { id: entry.id }, { success: 'builder.list.restored', successVars: { mission: name } });
    else if (kind === 'rollback') {
      res = await run<BuilderRollbackResult>('server:builder:rollback', { id: entry.id });
      if (res.ok && res.data) toast('success', t('builder.list.rolled_back', { mission: name, version: res.data.version, from: res.data.fromVersion }));
    } else if (kind === 'breakLock') res = await run('server:builder:breakLock', { id: entry.id }, { success: 'builder.list.lock_broken', successVars: { mission: name } });
    else {
      res = await run<BuilderDiscardResult>('server:builder:discardDraft', { id: entry.id });
      if (res.ok && res.data) toast('success', t(res.data.deleted ? 'builder.list.deleted' : 'builder.list.discarded', { mission: name }));
    }
    setConfirm(null);
    if (res?.ok) void refetch();
  };

  const columns: TableColumn<BuilderListEntry>[] = [
    {
      key: 'label',
      header: t('builder.list.col.mission'),
      render: (m) => (
        <div className="builder_client-mission">
          <div className="builder_client-mission__name">
            <span>{m.label}</span>
            {m.editedInCode ? <Badge size="sm" tone="warning" variant="outline" icon="fileText">{t('builder.list.edited_in_code')}</Badge> : null}
          </div>
          <div className="builder_client-mission__meta">
            <span>{typeLabel(m.type)}</span>
          </div>
          <span className="builder_client-mono">{m.id}</span>
        </div>
      ),
    },
    {
      key: 'status',
      header: t('builder.list.col.status'),
      width: 170,
      render: (m) => (
        <div className="builder_client-status-cell">
          <StatusBadge status={m.status} />
          {m.hasDraft && m.dbStatus === 'published' ? (
            <Badge size="sm" tone={m.draftTested ? 'accent' : 'neutral'} variant="outline" icon={m.draftTested ? 'flask' : 'edit'}>
              {t(m.draftTested ? 'builder.list.draft_tested' : 'builder.list.draft_v', { version: m.draftVersion ?? '?' })}
            </Badge>
          ) : null}
        </div>
      ),
    },
    {
      key: 'version',
      header: t('builder.list.col.version'),
      width: 90,
      numeric: true,
      render: (m) => (m.version ? <span className="cp-num">v{m.version}</span> : <span className="builder_client-muted">—</span>),
    },
    { key: 'lock', header: t('builder.list.col.lock'), width: 170, render: (m) => <LockBadge lock={m.lock} /> },
    {
      key: 'updated',
      header: t('builder.list.col.updated'),
      width: 150,
      render: (m) => (
        <div className="builder_client-updated">
          <span>{m.owner.mine ? t('builder.list.owner_you') : m.owner.name ?? m.owner.citizenid}</span>
          <span className="builder_client-muted cp-num">{formatDateTime(m.updatedAt)}</span>
        </div>
      ),
    },
    {
      key: 'actions',
      header: '',
      width: 196,
      align: 'right',
      render: (m) => (
        <div className="builder_client-row-actions" onClick={(e) => e.stopPropagation()}>
          {can('builderEdit') ? (
            <IconButton icon="swap" size="sm" variant="ghost" label={t('builder.list.duplicate')} disabled={busy}
              onClick={async () => {
                const res = await run<BuilderCreateResult>('server:builder:duplicate', { id: m.id }, { success: 'builder.list.duplicated', successVars: { mission: m.label } });
                if (res.ok && res.data) open(res.data.id);
              }} />
          ) : null}
          {m.can.archive && can('builderArchive') ? (
            <IconButton icon="inbox" size="sm" variant="ghost" label={t('builder.list.archive')} onClick={() => setConfirm({ kind: 'archive', entry: m })} />
          ) : null}
          {m.can.restore && can('builderArchive') ? (
            <IconButton icon="refresh" size="sm" variant="ghost" label={t('builder.list.restore')} onClick={() => setConfirm({ kind: 'restore', entry: m })} />
          ) : null}
          {m.can.rollback && can('builderRollback') ? (
            <IconButton icon="chevronLeft" size="sm" variant="ghost" label={t('builder.list.rollback')} onClick={() => setConfirm({ kind: 'rollback', entry: m })} />
          ) : null}
          {m.can.breakLock && can('breakEditLock') ? (
            <IconButton icon="key" size="sm" variant="ghost" label={t('builder.list.break_lock')} onClick={() => setConfirm({ kind: 'breakLock', entry: m })} />
          ) : null}
          {m.can.discard ? (
            <IconButton icon="trash" size="sm" variant="ghost" label={t(m.version ? 'builder.list.discard' : 'builder.list.delete')} onClick={() => setConfirm({ kind: 'discard', entry: m })} />
          ) : null}
          <Button size="sm" variant={m.can.edit ? 'primary' : 'secondary'} icon={m.can.edit ? 'edit' : 'eye'} onClick={() => open(m.id)}>
            {m.can.edit ? t('builder.list.edit') : t('builder.list.view')}
          </Button>
        </div>
      ),
    },
  ];

  const confirmText = confirm ? confirmCopy(confirm) : null;

  return (
    <div className="builder_client-list">
      <div className="builder_client-toolbar">
        <SearchInput value={query} onChange={setQuery} placeholder={t('builder.list.search')} className="builder_client-search" />
        <SegmentedControl<Filter>
          size="sm"
          value={filter}
          onChange={setFilter}
          items={[
            { key: 'all', label: t('builder.list.filter.all'), badge: counts.all },
            { key: 'drafts', label: t('builder.list.filter.drafts'), badge: counts.drafts },
            { key: 'published', label: t('builder.list.filter.published'), badge: counts.published },
            { key: 'archived', label: t('builder.list.filter.archived'), badge: counts.archived },
          ]}
        />
        <span className="cp-spacer" />
        <IconButton icon="refresh" label={t('builder.list.refresh')} variant="ghost" onClick={() => void refetch()} loading={loading && !!data} />
        {can('builderEdit') ? (
          <>
            <Button variant="secondary" icon="layers" size="sm" onClick={() => setDupOpen(true)} disabled={!builtins.length}>{t('builder.list.from_builtin')}</Button>
            <Button variant="primary" icon="plus" size="sm" onClick={() => setCreating(true)}>{t('builder.list.new')}</Button>
          </>
        ) : null}
      </div>

      {error && !data ? (
        <ErrorState error={error} onRetry={() => void refetch()} />
      ) : loading && !data ? (
        <LoadingBlock />
      ) : !missions.length ? (
        <EmptyState
          icon="tool"
          title={t('builder.list.empty_title')}
          text={t('builder.list.empty_text')}
          action={can('builderEdit') ? <Button variant="primary" icon="plus" onClick={() => setCreating(true)}>{t('builder.list.new')}</Button> : undefined}
        />
      ) : (
        <Table
          columns={columns}
          rows={rows}
          rowKey={(m) => m.id}
          onRowClick={(m) => open(m.id)}
          empty={t('builder.list.no_match')}
          aria-label={t('builder.list.aria')}
        />
      )}

      <NewMissionDialog open={creating} config={config} onClose={() => setCreating(false)} onCreated={(id) => { setCreating(false); open(id, 'blocks'); }} />
      <DuplicateDialog
        open={dupOpen}
        builtins={builtins}
        typeLabel={typeLabel}
        onClose={() => setDupOpen(false)}
        onDone={(id) => { setDupOpen(false); open(id); }}
      />
      <ConfirmDialog
        open={!!confirm}
        title={confirmText?.title ?? ''}
        message={confirmText?.message}
        confirmLabel={confirmText?.button}
        tone={confirm && (confirm.kind === 'discard' || confirm.kind === 'breakLock' || confirm.kind === 'archive') ? 'danger' : 'primary'}
        onConfirm={doConfirm}
        onCancel={() => setConfirm(null)}
        busy={busy}
      />
    </div>
  );
}

function confirmCopy(c: NonNullable<Confirm>): { title: string; message: string; button: string } {
  const vars = { mission: c.entry.label, version: c.entry.version ?? 1, previous: Math.max(1, (c.entry.version ?? 2) - 1), name: c.entry.lock?.name ?? c.entry.lock?.citizenid ?? '' };
  const k = c.kind === 'discard' ? (c.entry.version ? 'discard' : 'delete') : c.kind === 'breakLock' ? 'break_lock' : c.kind;
  return {
    title: t(`builder.confirm.${k}.title`, vars),
    message: t(`builder.confirm.${k}.message`, vars),
    button: t(`builder.confirm.${k}.button`, vars),
  };
}

// ── dialogs ──────────────────────────────────────────────────────────────────────

function NewMissionDialog({ open, config, onClose, onCreated }: { open: boolean; config: BuilderConfig | null; onClose: () => void; onCreated: (id: string) => void }) {
  const { run, busy } = useAction();
  const [type, setType] = useState('');
  const [label, setLabel] = useState('');
  const types = asArray(config?.missionTypes);
  const max = config?.limits?.label ?? 64;
  const submit = async () => {
    if (!type) return;
    const res = await run<BuilderCreateResult>('server:builder:create', { type, label: label.trim() || undefined }, { success: 'builder.list.created' });
    if (res.ok && res.data) {
      setType('');
      setLabel('');
      onCreated(res.data.id);
    }
  };
  return (
    <Dialog
      open={open}
      onClose={onClose}
      title={t('builder.new.title')}
      description={t('builder.new.description', { max: config?.maxBlocks ?? 6 })}
      size="sm"
      footer={
        <>
          <Button variant="ghost" onClick={onClose} disabled={busy}>{t('common.cancel')}</Button>
          <Button variant="primary" icon="plus" onClick={submit} loading={busy} disabled={!type}>{t('builder.new.create')}</Button>
        </>
      }
    >
      <div className="builder_client-form">
        <Field label={t('builder.details.type')} required hint={t('builder.details.type_hint')}>
          <Select
            value={type}
            onChange={setType}
            placeholder={t('builder.details.type_pick')}
            options={types.map((m) => ({ value: m.key, label: t('builder.details.type_option', { label: m.label, points: m.points }) }))}
          />
        </Field>
        <Field label={t('builder.details.name')} hint={t('builder.new.name_hint', { max })}>
          <TextInput value={label} onChange={(v) => setLabel(v.slice(0, max))} maxLength={max} placeholder={t('builder.new.name_placeholder')} onEnter={submit} />
        </Field>
        <div className="builder_client-callout">
          <Icon name="info" size={15} />
          <span>{t('builder.details.no_payout')}</span>
        </div>
      </div>
    </Dialog>
  );
}

function DuplicateDialog({ open, builtins, typeLabel, onClose, onDone }: {
  open: boolean; builtins: BuilderList['builtins']; typeLabel: (k: string) => string; onClose: () => void; onDone: (id: string) => void;
}) {
  const { run, busy } = useAction();
  const [pick, setPick] = useState('');
  const submit = async () => {
    if (!pick) return;
    const src = builtins.find((b) => b.id === pick);
    const res = await run<BuilderCreateResult>('server:builder:duplicate', { id: pick }, { success: 'builder.list.duplicated', successVars: { mission: src?.label ?? pick } });
    if (res.ok && res.data) {
      setPick('');
      onDone(res.data.id);
    }
  };
  return (
    <Dialog
      open={open}
      onClose={onClose}
      title={t('builder.dup.title')}
      description={t('builder.dup.description')}
      size="sm"
      footer={
        <>
          <Button variant="ghost" onClick={onClose} disabled={busy}>{t('common.cancel')}</Button>
          <Button variant="primary" icon="swap" onClick={submit} loading={busy} disabled={!pick}>{t('builder.dup.button')}</Button>
        </>
      }
    >
      <Field label={t('builder.dup.pick')}>
        <Select
          value={pick}
          onChange={setPick}
          placeholder={t('builder.dup.placeholder')}
          options={builtins.map((b) => ({ value: b.id, label: `${b.label} · ${typeLabel(b.type)}` }))}
        />
      </Field>
    </Dialog>
  );
}
