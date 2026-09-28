// Browser dev mode only: a component gallery inside the tablet frame (DevPanel → Gallery, or ?gallery=1).
// Shows every shared component in the current department theme. Sample text is English on purpose.
import { useEffect, useState } from 'react';
import {
  Badge, Button, Card, Checkbox, ConfirmDialog, Countdown, Dialog, EmptyState, Field, Grid, IconButton, Money, MoneyRange,
  NumberInput, Points, ProgressBar, Row, Screen, SearchInput, Section, SegmentedControl, Select, Spinner, Stat, Table, Tabs,
  Textarea, TextInput, TierBadge, Toggle, XpBadge, type TableColumn,
} from '../shared/components';
import { formatMoney } from '../shared/format';
import { useSession } from '../shared/session';
import { Header } from '../layouts/Header';
import { TabletFrame } from '../layouts/TabletFrame';
import { Watermark } from '../shared/components';
import { closeTopLayer } from '../shared/hooks';

interface GalleryRow { rank: number; name: string; callsign: string | null; dept: string; points: number; runs: number; me?: boolean }
const ROWS: GalleryRow[] = [
  { rank: 1, name: 'Maria Lopez', callsign: '2L-21', dept: 'SAST', points: 4820, runs: 31 },
  { rank: 2, name: 'Dana Whitfield', callsign: null, dept: 'FIB', points: 4410, runs: 27 },
  { rank: 3, name: 'John Doe', callsign: '2L-14', dept: 'SAST', points: 3975, runs: 25, me: true },
  { rank: 4, name: 'Ray Chen', callsign: '4A-02', dept: 'FIB', points: 3120, runs: 22 },
];

const COLUMNS: TableColumn<GalleryRow>[] = [
  { key: 'rank', header: '#', width: 48, numeric: true },
  { key: 'name', header: 'Officer', render: (r) => <strong>{r.name}</strong> },
  { key: 'callsign', header: 'Callsign', render: (r) => r.callsign ?? <span style={{ color: 'var(--cp-subtle)' }}>No callsign</span> },
  { key: 'dept', header: 'Dept', render: (r) => <Badge size="sm">{r.dept}</Badge> },
  { key: 'runs', header: 'Runs', numeric: true },
  { key: 'points', header: 'Points', numeric: true, render: (r) => <Points value={r.points} /> },
];

export default function Gallery({ onClose }: { onClose: () => void }) {
  const session = useSession();
  const [tab, setTab] = useState<'weekly' | 'monthly' | 'season' | 'alltime'>('weekly');
  const [seg, setSeg] = useState<'overall' | 'patrol' | 'tactical'>('overall');
  const [payout, setPayout] = useState<number | null>(800);
  const [name, setName] = useState('');
  const [note, setNote] = useState('');
  const [sel, setSel] = useState('patrol');
  const [on, setOn] = useState(true);
  const [check, setCheck] = useState(false);
  const [dialog, setDialog] = useState(false);
  const [confirm, setConfirm] = useState(false);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && !closeTopLayer()) onClose();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onClose]);

  return (
    <TabletFrame theme={session.theme}>
      <Header session={session} ui="officer" onClose={onClose} />
      <div className="cp-tablet__body">
        <main className="cp-main">
          <Watermark logo={session.logo} department={session.officer?.department} />
          <div className="cp-main__scroll">
            <Screen
              title="Component gallery"
              subtitle="Every shared component in the current department theme"
              actions={
                <>
                  <Button icon="eye" onClick={() => setDialog(true)}>Dialog</Button>
                  <Button variant="danger" icon="trash" onClick={() => setConfirm(true)}>Confirm</Button>
                </>
              }
            >
              <Section title="Buttons">
                <Row wrap gap={2}>
                  <Button variant="primary" icon="check">Accept type</Button>
                  <Button>Secondary</Button>
                  <Button variant="ghost">Ghost</Button>
                  <Button variant="danger">Abandon</Button>
                  <Button variant="primary" loading>Saving</Button>
                  <Button size="sm" variant="primary">Small</Button>
                  <Button size="sm">Small</Button>
                  <Button disabled>Disabled</Button>
                  <IconButton icon="refresh" label="Refresh" variant="secondary" />
                  <IconButton icon="x" label="Close" />
                  <Spinner />
                </Row>
              </Section>

              <Section title="Badges">
                <Row wrap gap={2}>
                  {(['neutral', 'primary', 'accent', 'success', 'warning', 'danger'] as const).map((t) => (
                    <Badge key={t} tone={t}>{t}</Badge>
                  ))}
                  <Badge tone="accent" variant="solid" icon="star">Type of the Day</Badge>
                  <Badge tone="danger" variant="outline" dot>Flagged</Badge>
                </Row>
                <Row wrap gap={2}>
                  {(['grey', 'bronze', 'silver', 'gold', 'platinum'] as const).map((b, i) => (
                    <XpBadge key={b} badge={b} label={['Probationary', 'Patrol Officer', 'Senior Patrol', 'Veteran', 'Elite'][i]} />
                  ))}
                </Row>
                <Row wrap gap={2}>
                  {(['standard', 'reinforced', 'heavy', 'major', 'critical'] as const).map((t) => (
                    <TierBadge key={t} tier={t} />
                  ))}
                  <TierBadge tier="heavy" expected />
                </Row>
              </Section>

              <Grid cols={4}>
                <Card padding="md"><Stat label="Season points" icon="star" value={<Points value={3975} />} hint="+420 this week" tone="accent" /></Card>
                <Card padding="md"><Stat label="Cash this week" icon="dollar" value={<Money amount={1040} />} hint="3 paid runs" /></Card>
                <Card padding="md"><Stat label="Streak" icon="flame" value="4 days" hint="Grace day left" tone="primary" /></Card>
                <Card padding="md"><Stat label="Time left" icon="clock" value={<Countdown seconds={75} warnBelow={60} dangerBelow={15} />} hint="Counts down locally" /></Card>
              </Grid>

              <Grid cols="3fr 2fr">
                <Card title="Leaderboard" subtitle="Top 25 plus your row" icon="trophy" padding="none" actions={<Badge tone="accent" size="sm">Live</Badge>}>
                  <div style={{ padding: '12px 16px 0' }}>
                    <Tabs
                      items={[
                        { key: 'weekly', label: 'Weekly' },
                        { key: 'monthly', label: 'Monthly' },
                        { key: 'season', label: 'Season', badge: 3 },
                        { key: 'alltime', label: 'All-time' },
                      ]}
                      value={tab}
                      onChange={setTab}
                    />
                  </div>
                  <div style={{ padding: 16 }}>
                    <Table columns={COLUMNS} rows={ROWS} rowKey={(r) => r.rank} highlightRow={(r) => !!r.me} onRowClick={() => undefined} maxHeight={260} />
                  </div>
                </Card>
                <Card title="Progress & filters" icon="barChart">
                  <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
                    <SegmentedControl
                      items={[
                        { key: 'overall', label: 'Overall' },
                        { key: 'patrol', label: 'Patrol' },
                        { key: 'tactical', label: 'Tactical' },
                      ]}
                      value={seg}
                      onChange={setSeg}
                    />
                    <ProgressBar label="Daily goal: 2 Patrol missions" value={1} max={2} showValue />
                    <ProgressBar label="XP to Veteran" value={11250} max={15000} tone="accent" showValue={`${(11250).toLocaleString('en-US')} / 15,000`} />
                    <ProgressBar label="SAST vs FIB" value={62} tone="success" size="lg" />
                    <Row gap={3}>
                      <MoneyRange range={[1040, 1300]} />
                      <Points value={-30} sign />
                      <Points value={45} sign />
                    </Row>
                  </div>
                </Card>
              </Grid>

              <Grid cols={2}>
                <Card title="Form controls" icon="edit">
                  <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
                    <Field label="Tactical payout" required>
                      <NumberInput value={payout} onChange={setPayout} min={400} max={1600} step={50} prefix="$" formatRange={formatMoney} />
                    </Field>
                    <Field label="Search officer" hint="Name, callsign or citizen id">
                      <SearchInput value={name} onChange={setName} />
                    </Field>
                    <Field label="Mission type">
                      <Select value={sel} onChange={setSel} options={[{ value: 'patrol', label: 'Patrol' }, { value: 'training', label: 'Training' }, { value: 'tactical', label: 'Tactical' }]} />
                    </Field>
                  </div>
                </Card>
                <Card title="More controls" icon="tool">
                  <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
                    <Field label="Reason" error={note.length > 0 && note.length < 5 ? 'At least 5 characters' : undefined}>
                      <Textarea value={note} onChange={setNote} maxLength={120} placeholder="Why are you changing this payout?" />
                    </Field>
                    <Field label="Callsign">
                      <TextInput value="2L-14" onChange={() => undefined} disabled />
                    </Field>
                    <Toggle checked={on} onChange={setOn} label="Start route" description="Test runs start with the route off" />
                    <Checkbox checked={check} onChange={setCheck} label="Hide my name on leaderboards" />
                  </div>
                </Card>
              </Grid>

              <Grid cols={2}>
                <Card padding="none"><EmptyState title="No invites" text="Invites from other officers show up here." icon="users" /></Card>
                <Card title="Locked card" muted highlight="warning" subtitle="Cooldown 12:40">
                  Board cards use muted + highlight for locked states.
                </Card>
              </Grid>
            </Screen>
          </div>
        </main>
      </div>
      <Dialog
        open={dialog}
        onClose={() => setDialog(false)}
        title="Run breakdown"
        description="Gang Shootout · Heavy tier"
        footer={<Button variant="primary" onClick={() => setDialog(false)}>Close</Button>}
      >
        <p style={{ color: 'var(--cp-muted)' }}>Dialogs render inside the tablet, scale with it and close with Escape before the UI does.</p>
        <Field label="Amount">
          <NumberInput value={250} onChange={() => undefined} min={0} max={25000} prefix="$" formatRange={formatMoney} />
        </Field>
      </Dialog>
      <ConfirmDialog
        open={confirm}
        title="Abandon this mission?"
        message="You will be removed from the run as Abandoned and a type cooldown applies."
        tone="danger"
        confirmLabel="Abandon"
        reason={{ required: true, placeholder: 'Optional note for the log' }}
        onConfirm={() => new Promise((r) => setTimeout(() => { setConfirm(false); r(null); }, 600))}
        onCancel={() => setConfirm(false)}
      />
    </TabletFrame>
  );
}
