// Supervisor UI · Payouts (screen key 'sup_payouts', title key 'ui.screen.sup_payouts').
// Per mission type: current payout, config default, the supervisor's allowed range, "Set by admin"
// (read-only), the cooldown before it can change again, and a change dialog (NumberInput clamped to the
// range + a required reason). Single-mission payouts are never shown here.
// Data: callback 'sup:getPayouts' (SupPayoutsView, src/types/economy.ts), push topic 'payouts';
// write: action 'server:sup:setTypePayout' { type, amount, reason }.
import { useEffect, useMemo, useState } from 'react';
import {
  Badge, Button, Card, Countdown, Dialog, EmptyState, ErrorState, Field, Icon, KeyValue, LoadingBlock, Money,
  NumberInput, Screen, Table, Textarea,
} from '../../shared/components';
import type { TableColumn } from '../../shared/components';
import { cx } from '../../shared/cx';
import { formatDateTime, formatMoney, formatPercent } from '../../shared/format';
import { useAction, useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import type { SupPayoutType, SupPayoutsView } from '../../types/economy';
import './Payouts.css';

const REASON_MAX = 255;

function minutes(seconds: number): number {
  return Math.max(1, Math.round(seconds / 60));
}

function deltaText(amount: number, base: number): string | null {
  if (!base || amount === base) return null;
  const pct = ((amount - base) / base) * 100;
  const rounded = Math.round(pct);
  return t('sup.payouts.vs_default', { delta: `${rounded > 0 ? '+' : ''}${rounded}%` });
}

function StatusCell({ row, onCooldownDone }: { row: SupPayoutType; onCooldownDone: () => void }) {
  if (row.adminLocked) {
    return (
      <Badge tone="warning" icon="lock" title={t('sup.payouts.locked_hint')}>
        {t('sup.payouts.set_by_admin')}
      </Badge>
    );
  }
  if (row.cooldownLeft > 0) {
    return (
      <span className="economy-pay-cooldown">
        <Icon name="clock" size={13} />
        <span>{t('sup.payouts.cooldown')}</span>
        <Countdown seconds={row.cooldownLeft} onDone={onCooldownDone} />
      </span>
    );
  }
  if (row.stored) {
    return (
      <Badge tone="primary" size="sm" icon="user">
        {t('sup.payouts.changed')}
      </Badge>
    );
  }
  return (
    <Badge tone="neutral" variant="outline" size="sm">
      {t('sup.payouts.config_default')}
    </Badge>
  );
}

function EditDialog({
  row, view, onClose, onSaved,
}: { row: SupPayoutType | null; view: SupPayoutsView | null; onClose: () => void; onSaved: () => void }) {
  const [amount, setAmount] = useState<number | null>(null);
  const [valid, setValid] = useState(true);
  const [reason, setReason] = useState('');
  const { run, busy } = useAction();

  useEffect(() => {
    if (row) {
      setAmount(row.amount);
      setValid(true);
      setReason('');
    }
  }, [row]);

  if (!row) return null;
  const inRange = amount !== null && amount >= row.min && amount <= row.max;
  const changed = amount !== null && amount !== row.amount;
  const reasonOk = reason.trim().length > 0;
  const canSave = valid && inRange && changed && reasonOk && !busy;
  const delta = amount !== null ? deltaText(amount, row.default) : null;
  const cooldownMin = minutes(view?.cooldownSeconds ?? 1800);

  const save = async () => {
    if (!canSave || amount === null) return;
    const res = await run('server:sup:setTypePayout', { type: row.key, amount, reason: reason.trim() }, {
      success: 'sup.payouts.saved',
      successVars: { type: row.label, amount: formatMoney(amount) },
    });
    if (res.ok) onSaved();
  };

  return (
    <Dialog
      open={!!row}
      onClose={busy ? () => undefined : onClose}
      title={t('sup.payouts.edit_title', { type: row.label })}
      description={t('sup.payouts.edit_desc')}
      size="md"
      footer={
        <>
          <Button variant="ghost" onClick={onClose} disabled={busy}>
            {t('common.cancel')}
          </Button>
          <Button variant="primary" icon="check" onClick={save} loading={busy} disabled={!canSave}>
            {t('sup.payouts.save')}
          </Button>
        </>
      }
    >
      <div className="economy-pay-edit">
        <div className="economy-pay-edit__facts">
          <KeyValue label={t('sup.payouts.col_current')}>
            <Money amount={row.amount} />
          </KeyValue>
          <KeyValue label={t('sup.payouts.col_default')}>
            <Money amount={row.default} />
          </KeyValue>
          <KeyValue label={t('sup.payouts.col_range')}>
            <span className="cp-num">{`${formatMoney(row.min)}–${formatMoney(row.max)}`}</span>
          </KeyValue>
        </div>
        <Field label={t('sup.payouts.new_amount')} required hint={delta ?? undefined}>
          <NumberInput
            value={amount}
            onChange={setAmount}
            min={row.min}
            max={row.max}
            step={10}
            prefix="$"
            formatRange={formatMoney}
            onValidityChange={setValid}
            aria-label={t('sup.payouts.new_amount')}
          />
        </Field>
        <Field label={t('common.reason')} required>
          <Textarea value={reason} onChange={setReason} maxLength={REASON_MAX} rows={3} placeholder={t('sup.payouts.reason_placeholder')} />
        </Field>
        <div className="economy-pay-edit__note">
          <Icon name="info" size={14} />
          <span>{t('sup.payouts.edit_note', { minutes: cooldownMin })}</span>
        </div>
      </div>
    </Dialog>
  );
}

export default function SupPayouts() {
  const { data, loading, error, refetch } = useRequest<SupPayoutsView>('sup:getPayouts', {}, { pushTopic: 'payouts' });
  const [editing, setEditing] = useState<SupPayoutType | null>(null);
  const types = useMemo(() => (Array.isArray(data?.types) ? data!.types : []), [data]);
  const cooldownMin = minutes(data?.cooldownSeconds ?? 1800);
  const share = data?.rangeShare ?? { min: 0.5, max: 2 };

  const columns: TableColumn<SupPayoutType>[] = [
    {
      key: 'label',
      header: t('sup.payouts.col_type'),
      render: (r) => (
        <span className={cx('economy-pay-type', r.adminLocked && 'is-locked')}>
          {r.adminLocked ? <Icon name="lock" size={13} /> : null}
          {r.label}
        </span>
      ),
    },
    {
      key: 'amount',
      header: t('sup.payouts.col_current'),
      numeric: true,
      render: (r) => (
        <span className="economy-pay-current">
          <Money amount={r.amount} className="economy-pay-amount" />
          {r.stored && (r.updatedByName || r.updatedAt) ? (
            <span className="economy-pay-current__who">
              {[r.updatedByName, r.updatedAt ? formatDateTime(r.updatedAt) : null].filter(Boolean).join(' · ')}
            </span>
          ) : null}
        </span>
      ),
    },
    {
      key: 'range',
      header: t('sup.payouts.col_range'),
      numeric: true,
      render: (r) => (
        <span className="economy-pay-current">
          <span className={cx('cp-num', 'economy-pay-range', r.adminLocked && 'economy-muted-num')}>{`${formatMoney(r.min)}–${formatMoney(r.max)}`}</span>
          <span className="economy-pay-current__who">{t('sup.payouts.default_line', { amount: formatMoney(r.default) })}</span>
        </span>
      ),
    },
    { key: 'status', header: t('sup.payouts.col_status'), render: (r) => <StatusCell row={r} onCooldownDone={() => void refetch()} /> },
    {
      key: 'action',
      header: '',
      align: 'right',
      width: 110,
      render: (r) => (
        <Button
          size="sm"
          variant="secondary"
          icon={r.adminLocked ? 'lock' : 'edit'}
          disabled={!r.canEdit || r.adminLocked || r.cooldownLeft > 0}
          title={r.adminLocked ? t('sup.payouts.locked_hint') : r.cooldownLeft > 0 ? t('sup.payouts.cooldown_hint') : undefined}
          onClick={() => setEditing(r)}
        >
          {t('sup.payouts.change')}
        </Button>
      ),
    },
  ];

  return (
    <Screen title={t('ui.screen.sup_payouts')} subtitle={t('sup.payouts.subtitle')} className="economy-payouts">
      <div className="economy-pay-rules">
        <div className="economy-pay-rule">
          <Icon name="barChart" size={16} />
          <div>
            <div className="economy-pay-rule__title">{t('sup.payouts.rule_range')}</div>
            <div className="economy-pay-rule__text">
              {t('sup.payouts.rule_range_text', { min: formatPercent(share.min), max: formatPercent(share.max) })}
            </div>
          </div>
        </div>
        <div className="economy-pay-rule">
          <Icon name="clock" size={16} />
          <div>
            <div className="economy-pay-rule__title">{t('sup.payouts.rule_cooldown')}</div>
            <div className="economy-pay-rule__text">{t('sup.payouts.rule_cooldown_text', { minutes: cooldownMin })}</div>
          </div>
        </div>
        <div className="economy-pay-rule">
          <Icon name="fileText" size={16} />
          <div>
            <div className="economy-pay-rule__title">{t('sup.payouts.rule_reason')}</div>
            <div className="economy-pay-rule__text">{t('sup.payouts.rule_reason_text')}</div>
          </div>
        </div>
        <div className="economy-pay-rule">
          <Icon name="lock" size={16} />
          <div>
            <div className="economy-pay-rule__title">{t('sup.payouts.rule_admin')}</div>
            <div className="economy-pay-rule__text">{t('sup.payouts.rule_admin_text')}</div>
          </div>
        </div>
      </div>

      <Card padding="none">
        {!data && loading ? <LoadingBlock /> : null}
        {!data && !loading && error ? <ErrorState error={error} onRetry={() => void refetch()} /> : null}
        {data ? (
          <Table
            columns={columns}
            rows={types}
            rowKey={(r) => r.key}
            empty={<EmptyState compact icon="dollar" title={t('sup.payouts.empty')} />}
            aria-label={t('ui.screen.sup_payouts')}
          />
        ) : null}
      </Card>
      <p className="economy-pay-footnote">{t('sup.payouts.footnote')}</p>

      <EditDialog
        row={editing}
        view={data}
        onClose={() => setEditing(null)}
        onSaved={() => {
          setEditing(null);
          void refetch();
        }}
      />
    </Screen>
  );
}
