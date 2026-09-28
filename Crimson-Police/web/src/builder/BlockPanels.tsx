// src/builder/BlockPanels.tsx · one settings panel per objective block (SPEC "Mission Builder → Block settings"),
// generated from the builder:config ranges (config/blocks.lua): every number shows its min, max and default and
// refuses values outside them; selects offer only the allowed lists (Config.Builder.allowed); chances are whole
// percent and progress times seconds (builder units, protocol §1.1). Field paths follow ARCHITECTURE §3.3.
import type { ComponentType, ReactNode } from 'react';
import { Checkbox, Field, Grid, Icon, NumberInput, SegmentedControl, Select, TextInput, Toggle } from '../shared/components';
import { asArray } from '../shared/data';
import { t } from '../shared/i18n';
import type { BuilderConfig, BuilderDefinition, BuilderError, BuilderObjective } from '../types/builder_server';
import { GroupTitle, MultiPick, OptionPick, RangeNumber, nameOf } from './controls';
import { getAt, messageAt } from './defUtils';
import {
  flagOf, listOf, numOf, optionsOf, rangeOf, shrinkList, strOf, uniqueKey, SEARCH_MIN_SPOTS, SHARED_DEVICES, type Rng,
} from './schema';

export interface PanelProps {
  cfg: BuilderConfig;
  def: BuilderDefinition;
  obj: BuilderObjective;
  /** 1-based objective index */
  index: number;
  ro: boolean;
  errors: BuilderError[];
  set: (path: string, value: unknown) => void;
  patch: (fn: (o: BuilderObjective, d: BuilderDefinition) => void) => void;
}

const num = (o: BuilderObjective, path: string, fb: number): number => {
  const v = getAt(o, path);
  return typeof v === 'number' && isFinite(v) ? v : fb;
};
const str = (o: BuilderObjective, path: string, fb: string): string => {
  const v = getAt(o, path);
  return typeof v === 'string' ? v : fb;
};
const strs = (o: BuilderObjective, path: string, fb: string[]): string[] => {
  const v = getAt(o, path);
  return Array.isArray(v) ? (v.filter((x) => typeof x === 'string') as string[]) : fb;
};

function Note({ children, tone = 'info' }: { children: ReactNode; tone?: 'info' | 'warning' }) {
  return (
    <div className={`builder_client-callout builder_client-callout--${tone}`}>
      <Icon name={tone === 'warning' ? 'alert' : 'info'} size={15} />
      <span>{children}</span>
    </div>
  );
}

function Group({ title, aside, children }: { title: ReactNode; aside?: ReactNode; children: ReactNode }) {
  return (
    <section className="builder_client-group">
      <GroupTitle aside={aside}>{title}</GroupTitle>
      {children}
    </section>
  );
}

// ── hostile_waves ───────────────────────────────────────────────────────────────

function HostileWaves({ cfg, obj, ro, set, patch }: PanelProps) {
  const b = 'hostile_waves';
  const r = (k: string, fb: [number, number, number]) => rangeOf(cfg, b, k, fb);
  const wavesR = r('waves', [1, 6, 3]);
  const perR = r('perWave', [1, 15, 7]);
  const waves = asArray(obj.waves as number[]);
  const healthR = r('health', [100, 400, 200]);
  const armourR = r('armour', [0, 100, 0]);
  const boss = obj.boss && typeof obj.boss === 'object' ? (obj.boss as Record<string, unknown>) : null;
  const allowedPeds = asArray(cfg.allowed?.peds);
  const allowedWeapons = asArray(cfg.allowed?.weapons);
  const largest = waves.length ? Math.max(...waves) : 0;
  const per = numOf(cfg, b, 'spawnPointsPerHostile', 1.5);
  return (
    <>
      <Group title={t('builder.hw.waves_group')} aside={t('builder.hw.spawn_need', { n: Math.ceil(per * largest - 1e-9), per })}>
        <Grid cols={2} gap={3}>
          <RangeNumber label={t('builder.hw.waves')} value={waves.length} range={wavesR} disabled={ro}
            onChange={(n) => patch((o) => {
              const list = asArray(o.waves as number[]).slice(0, n);
              while (list.length < n) list.push(list.length ? list[list.length - 1] : perR.def);
              o.waves = list;
            })} />
          <div />
        </Grid>
        <div className="builder_client-waves">
          {waves.map((w, i) => (
            <Field key={i} label={t('builder.hw.wave_n', { n: i + 1 })}>
              <NumberInput value={w} min={perR.min} max={perR.max} disabled={ro} showRange={false}
                onChange={(v) => v !== null && patch((o) => { const list = asArray(o.waves as number[]).slice(); list[i] = v; o.waves = list; })} />
            </Field>
          ))}
        </div>
        <div className="builder_client-range builder_client-range--block cp-num">
          {t('builder.hw.per_wave_range', { min: perR.min, max: perR.max, def: perR.def })}
        </div>
        <Grid cols={2} gap={3}>
          <RangeNumber label={t('builder.hw.next_alive')} value={num(obj, 'nextWave.aliveAtMost', 2)} range={r('nextWaveAlive', [0, 5, 2])} disabled={ro}
            onChange={(v) => set('nextWave.aliveAtMost', v)} />
          <RangeNumber label={t('builder.hw.next_after')} unit={t('builder.unit.s')} value={num(obj, 'nextWave.afterSeconds', 90)}
            range={r('nextWaveAfter', [30, 300, 90])} disabled={ro} onChange={(v) => set('nextWave.afterSeconds', v)} />
        </Grid>
      </Group>
      <Group title={t('builder.hw.hostiles_group')}>
        <MultiPick label={t('builder.field.weapons')} value={strs(obj, 'weapons', listOf(cfg, b, 'weapons'))} options={allowedWeapons} disabled={ro} onChange={(v) => set('weapons', v)} />
        <MultiPick label={t('builder.field.peds')} value={strs(obj, 'peds', listOf(cfg, b, 'peds'))} options={allowedPeds} disabled={ro} onChange={(v) => set('peds', v)} />
        <Grid cols={3} gap={3}>
          <RangeNumber label={t('builder.field.accuracy')} value={num(obj, 'accuracy', 25)} range={r('accuracy', [5, 60, 25])} disabled={ro} onChange={(v) => set('accuracy', v)} />
          <RangeNumber label={t('builder.field.armour')} value={num(obj, 'armour', 0)} range={armourR} disabled={ro} onChange={(v) => set('armour', v)} />
          <RangeNumber label={t('builder.field.health')} value={num(obj, 'health', 200)} range={healthR} disabled={ro} onChange={(v) => set('health', v)} />
        </Grid>
        <Grid cols={2} gap={3}>
          <OptionPick label={t('builder.field.behaviour')} value={str(obj, 'behaviour', 'balanced')} options={optionsOf(cfg, b, 'behaviour').options}
            disabled={ro} onChange={(v) => set('behaviour', v)} />
          <RangeNumber label={t('builder.hw.surrender')} unit="%" value={num(obj, 'surrender.chance', 30)} range={r('surrender', [0, 100, 30])} disabled={ro}
            onChange={(v) => patch((o) => { o.surrender = { belowHealth: num(o, 'surrender.belowHealth', 0.25), chance: v }; })} />
        </Grid>
      </Group>
      <Group title={t('builder.hw.boss_group')}>
        <Toggle checked={!!boss} disabled={ro} label={t('builder.hw.boss')} description={t('builder.hw.boss_desc')}
          onChange={(on) => patch((o) => {
            if (!on) o.boss = false;
            else {
              const w = allowedWeapons.includes('WEAPON_ASSAULTRIFLE') ? 'WEAPON_ASSAULTRIFLE' : allowedWeapons[allowedWeapons.length - 1];
              o.boss = { model: strs(o, 'peds', listOf(cfg, b, 'peds'))[0] ?? allowedPeds[0], health: healthR.max, armour: armourR.max, weapon: w };
            }
          })} />
        {boss ? (
          <>
            <Grid cols={2} gap={3}>
              <Field label={t('builder.hw.boss_model')}>
                <Select value={String(boss.model ?? '')} disabled={ro} onChange={(v) => set('boss.model', v)}
                  options={allowedPeds.map((p) => ({ value: p, label: nameOf(p) }))} />
              </Field>
              <Field label={t('builder.hw.boss_weapon')}>
                <Select value={String(boss.weapon ?? '')} disabled={ro} onChange={(v) => set('boss.weapon', v)}
                  options={allowedWeapons.map((w) => ({ value: w, label: nameOf(w) }))} />
              </Field>
              <RangeNumber label={t('builder.field.health')} value={num(obj, 'boss.health', healthR.max)} range={{ ...healthR, def: healthR.max }} disabled={ro}
                onChange={(v) => set('boss.health', v)} />
              <RangeNumber label={t('builder.field.armour')} value={num(obj, 'boss.armour', armourR.max)} range={{ ...armourR, def: armourR.max }} disabled={ro}
                onChange={(v) => set('boss.armour', v)} />
            </Grid>
            <Checkbox checked={typeof boss.spawn === 'string'} disabled={ro} label={t('builder.hw.boss_spawn')}
              onChange={(on) => patch((o, d) => {
                const bo = (o.boss ?? {}) as Record<string, unknown>;
                if (on) bo.spawn = uniqueKey(d, 'boss', 0);
                else delete bo.spawn;
                o.boss = bo;
              })} />
          </>
        ) : null}
      </Group>
      <Group title={t('builder.hw.traffic_group')}>
        <RangeNumber label={t('builder.hw.block_traffic')} unit={t('builder.unit.m')} value={num(obj, 'blockTraffic', 120)} range={r('blockTraffic', [0, 200, 120])}
          disabled={ro} onChange={(v) => set('blockTraffic', v)} />
      </Group>
    </>
  );
}

// ── escort ──────────────────────────────────────────────────────────────────────

function Escort({ cfg, obj, ro, set }: PanelProps) {
  const b = 'escort';
  const r = (k: string, fb: [number, number, number]) => rangeOf(cfg, b, k, fb);
  const hw = (k: string, fb: [number, number, number]) => rangeOf(cfg, 'hostile_waves', k, fb);
  const vehicles = asArray(cfg.allowed?.escortVehicles);
  const wait = r('stopWait', [10, 60, 20]);
  const stops = r('stops', [0, 5, 0]);
  return (
    <>
      <Group title={t('builder.esc.vehicle_group')}>
        <Grid cols={2} gap={3}>
          <Field label={t('builder.esc.vehicle')} hint={t('builder.default_value', { value: nameOf(strOf(cfg, b, 'vehicle', 'stockade')) })}>
            <Select value={str(obj, 'vehicle', vehicles[0] ?? 'stockade')} disabled={ro} onChange={(v) => set('vehicle', v)}
              options={vehicles.map((v) => ({ value: v, label: nameOf(v) }))} />
          </Field>
          <OptionPick label={t('builder.field.style')} value={str(obj, 'style', 'normal')} options={optionsOf(cfg, b, 'style').options} disabled={ro}
            onChange={(v) => set('style', v)} hint={t('builder.esc.style_hint')} />
          <RangeNumber label={t('builder.field.speed')} unit={t('builder.unit.kmh')} value={num(obj, 'speed', 60)} range={r('speed', [20, 120, 60])} disabled={ro}
            onChange={(v) => set('speed', v)} />
          <RangeNumber label={t('builder.esc.toughness')} unit="×" integer={false} step={0.1} value={num(obj, 'toughness', 1.5)} range={r('toughness', [0.5, 3, 1.5])}
            disabled={ro} onChange={(v) => set('toughness', Math.round(v * 10) / 10)} />
          <RangeNumber label={t('builder.esc.stopped_fail')} unit={t('builder.unit.s')} value={num(obj, 'stoppedFail', 60)} range={r('stoppedFail', [15, 120, 60])}
            disabled={ro} onChange={(v) => set('stoppedFail', v)} />
          <RangeNumber label={t('builder.esc.arrival')} unit={t('builder.unit.m')} value={num(obj, 'arrival', 20)} range={r('arrival', [10, 50, 20])} disabled={ro}
            onChange={(v) => set('arrival', v)} />
        </Grid>
        <Note>{t('builder.esc.route_note', { max: stops.max, min: wait.min, maxWait: wait.max, def: wait.def })}</Note>
      </Group>
      <Group title={t('builder.esc.ambush_group')}>
        <Grid cols={3} gap={3}>
          <RangeNumber label={t('builder.esc.ambush_waves')} value={num(obj, 'ambush.waves', 2)} range={r('ambushWaves', [1, 5, 2])} disabled={ro}
            onChange={(v) => set('ambush.waves', v)} />
          <RangeNumber label={t('builder.esc.cars_per_wave')} value={num(obj, 'ambush.carsPerWave', 2)} range={r('carsPerWave', [1, 5, 2])} disabled={ro}
            onChange={(v) => set('ambush.carsPerWave', v)} />
          <RangeNumber label={t('builder.esc.per_car')} value={num(obj, 'ambush.perCar', 2)} range={r('perCar', [1, 4, 2])} disabled={ro}
            onChange={(v) => set('ambush.perCar', v)} />
        </Grid>
        <MultiPick label={t('builder.esc.attacker_weapons')} value={strs(obj, 'ambush.weapons', listOf(cfg, 'hostile_waves', 'weapons'))}
          options={asArray(cfg.allowed?.weapons)} disabled={ro} onChange={(v) => set('ambush.weapons', v)} />
        <Grid cols={2} gap={3}>
          <RangeNumber label={t('builder.field.accuracy')} value={num(obj, 'ambush.accuracy', 25)} range={hw('accuracy', [5, 60, 25])} disabled={ro}
            onChange={(v) => set('ambush.accuracy', v)} />
          <RangeNumber label={t('builder.field.armour')} value={num(obj, 'ambush.armour', 0)} range={hw('armour', [0, 100, 0])} disabled={ro}
            onChange={(v) => set('ambush.armour', v)} />
        </Grid>
        <Note>{t('builder.esc.ambush_note', { min: r('ambushPoints', [1, 10, 5]).min, max: r('ambushPoints', [1, 10, 5]).max, def: r('ambushPoints', [1, 10, 5]).def, gap: numOf(cfg, b, 'ambushGap', 150) })}</Note>
      </Group>
    </>
  );
}

// ── pursuit ─────────────────────────────────────────────────────────────────────

function Pursuit({ cfg, obj, ro, set, patch }: PanelProps) {
  const b = 'pursuit';
  const r = (k: string, fb: [number, number, number]) => rangeOf(cfg, b, k, fb);
  const mode = str(obj, 'mode', 'stop');
  const route = typeof obj.route === 'string' ? obj.route : null;
  const routeMode = !route ? 'free' : /^raceLoop/.test(route) ? 'loop' : 'recorded';
  const lostD = num(obj, 'lost.distance', 250);
  const hold = num(obj, 'hold', 150);
  return (
    <>
      <Group title={t('builder.pur.mode_group')}>
        <OptionPick label={t('builder.pur.mode')} value={mode} options={optionsOf(cfg, b, 'mode').options} disabled={ro}
          hint={t(mode === 'follow' ? 'builder.pur.mode_follow_hint' : 'builder.pur.mode_stop_hint')}
          onChange={(v) => patch((o) => {
            o.mode = v;
            if (v === 'follow') {
              if (o.hold === undefined) o.hold = r('holdDistance', [50, 300, 150]).def;
              if (!o.lost || typeof o.lost !== 'object') o.lost = { distance: r('lostDistance', [150, 600, 250]).def, seconds: r('lostSeconds', [5, 30, 10]).def };
              if (o.duration === undefined) o.duration = r('duration', [60, 600, 180]).def;
            } else {
              delete o.hold;
              delete o.lost;
              delete o.duration;
            }
          })} />
        <Grid cols={2} gap={3}>
          <RangeNumber label={t('builder.pur.vehicles')} value={num(obj, 'vehicles', 1)} range={r('vehicles', [1, 5, 1])} disabled={ro} onChange={(v) => set('vehicles', v)} />
          <RangeNumber label={t('builder.pur.suspects')} value={num(obj, 'suspectsPerVehicle', 1)} range={r('suspects', [1, 4, 1])} disabled={ro}
            onChange={(v) => set('suspectsPerVehicle', v)} />
        </Grid>
        <MultiPick label={t('builder.pur.models')} value={strs(obj, 'models', asArray(cfg.allowed?.vehicles))} options={asArray(cfg.allowed?.vehicles)} disabled={ro}
          onChange={(v) => set('models', v)} />
      </Group>
      <Group title={t('builder.pur.route_group')}>
        <Field label={t('builder.pur.route')} hint={t(`builder.pur.route_${routeMode}_hint`)}>
          <SegmentedControl size="sm" value={routeMode}
            items={[
              { key: 'free', label: t('builder.pur.route_free'), disabled: ro },
              { key: 'recorded', label: t('builder.pur.route_recorded'), disabled: ro },
              { key: 'loop', label: t('builder.pur.route_loop'), disabled: ro },
            ]}
            onChange={(v) => patch((o, d) => {
              if (v === 'free') {
                delete o.route;
                if (typeof o.spawn !== 'string') o.spawn = uniqueKey(d, 'spawn', 0);
              } else {
                o.route = uniqueKey(d, v === 'loop' ? 'raceLoop' : 'route', 0);
                delete o.spawn;
              }
            })} />
        </Field>
        <Grid cols={2} gap={3}>
          <RangeNumber label={t('builder.field.speed')} unit={t('builder.unit.kmh')} value={num(obj, 'speed', 120)} range={r('speed', [40, 160, 120])} disabled={ro}
            onChange={(v) => set('speed', v)} />
          <OptionPick label={t('builder.field.style')} value={str(obj, 'style', 'reckless')} options={optionsOf(cfg, b, 'style').options} disabled={ro}
            onChange={(v) => set('style', v)} />
        </Grid>
        {mode === 'stop' ? (
          <RangeNumber label={t('builder.pur.foot_flee')} unit="%" value={num(obj, 'footFlee', 20)} range={r('footFlee', [0, 100, 20])} disabled={ro}
            onChange={(v) => set('footFlee', v)} />
        ) : null}
      </Group>
      {mode === 'follow' ? (
        <Group title={t('builder.pur.follow_group')}>
          <Grid cols={2} gap={3}>
            <RangeNumber label={t('builder.pur.hold')} unit={t('builder.unit.m')} value={hold} range={r('holdDistance', [50, 300, 150])} disabled={ro}
              onChange={(v) => set('hold', v)} />
            <RangeNumber label={t('builder.pur.duration')} unit={t('builder.unit.s')} value={num(obj, 'duration', 180)} range={r('duration', [60, 600, 180])} disabled={ro}
              onChange={(v) => set('duration', v)} />
            <RangeNumber label={t('builder.pur.lost_distance')} unit={t('builder.unit.m')} value={lostD} range={r('lostDistance', [150, 600, 250])} disabled={ro}
              onChange={(v) => set('lost.distance', v)} />
            <RangeNumber label={t('builder.pur.lost_seconds')} unit={t('builder.unit.s')} value={num(obj, 'lost.seconds', 10)} range={r('lostSeconds', [5, 30, 10])}
              disabled={ro} onChange={(v) => set('lost.seconds', v)} />
          </Grid>
          {lostD <= hold ? <Note tone="warning">{t('builder.pur.lost_vs_hold')}</Note> : null}
        </Group>
      ) : null}
    </>
  );
}

// ── checkpoint_route ────────────────────────────────────────────────────────────

function CheckpointRoute({ cfg, obj, ro, set, patch }: PanelProps) {
  const b = 'checkpoint_route';
  const r = (k: string, fb: [number, number, number]) => rangeOf(cfg, b, k, fb);
  const cp = r('checkpoints', [2, 20, 2]);
  const use = str(obj, 'use', 'all');
  const medals = obj.medals && typeof obj.medals === 'object' ? (obj.medals as Record<string, number>) : null;
  const medalOk = !medals || (medals.gold > 0 && medals.gold <= medals.silver && medals.silver <= medals.bronze);
  return (
    <>
      <Group title={t('builder.cp.group')}>
        <Grid cols={2} gap={3}>
          <OptionPick label={t('builder.field.use')} value={use} options={optionsOf(cfg, b, 'use').options} disabled={ro}
            onChange={(v) => patch((o) => { o.use = v; if (v === 'random' && typeof o.count !== 'number') o.count = Math.min(cp.max, 5); if (v === 'all') delete o.count; })} />
          {use === 'random' ? (
            <RangeNumber label={t('builder.cp.count')} value={num(obj, 'count', 5)} range={{ ...cp, def: Math.min(cp.max, 5) }} disabled={ro} onChange={(v) => set('count', v)} />
          ) : <div />}
          <RangeNumber label={t('builder.cp.radius')} unit={t('builder.unit.m')} value={num(obj, 'radius', 10)} range={r('radius', [3, 20, 10])} disabled={ro}
            onChange={(v) => set('radius', v)} />
          <RangeNumber label={t('builder.cp.stop_for')} unit={t('builder.unit.s')} value={num(obj, 'stopFor', 10)} range={r('stopFor', [0, 30, 10])} disabled={ro}
            onChange={(v) => set('stopFor', v)} note={t('builder.cp.stop_zero')} />
          <RangeNumber label={t('builder.cp.contact')} unit={t('builder.unit.s')} value={num(obj, 'contactPenalty', 2)} range={r('contactPenalty', [0, 10, 2])}
            disabled={ro} onChange={(v) => set('contactPenalty', v)} />
        </Grid>
        <Toggle checked={obj.policeVehicle !== false} disabled={ro} label={t('builder.cp.police_vehicle')} description={t('builder.cp.police_vehicle_desc')}
          onChange={(v) => set('policeVehicle', v)} />
        <Note>{t('builder.cp.points_note', { min: cp.min, max: cp.max })}</Note>
      </Group>
      <Group title={t('builder.cp.medals_group')}>
        <Toggle checked={!!medals} disabled={ro} label={t('builder.cp.medals')} description={t('builder.cp.medals_desc', { def: flagOf(cfg, b, 'medals') ? t('builder.on') : t('builder.off') })}
          onChange={(on) => set('medals', on ? { gold: 60, silver: 90, bronze: 120 } : false)} />
        {medals ? (
          <Grid cols={3} gap={3}>
            {(['gold', 'silver', 'bronze'] as const).map((m) => (
              <Field key={m} label={t(`builder.cp.medal_${m}`)}>
                <NumberInput value={medals[m] ?? null} min={1} max={3600} suffix={t('builder.unit.s')} disabled={ro} showRange={false}
                  onChange={(v) => v !== null && set(`medals.${m}`, v)} />
              </Field>
            ))}
          </Grid>
        ) : null}
        {!medalOk ? <Note tone="warning">{t('builder.cp.medals_order')}</Note> : null}
      </Group>
    </>
  );
}

// ── interact_points ─────────────────────────────────────────────────────────────

function InteractPoints({ cfg, obj, ro, set, patch }: PanelProps) {
  const b = 'interact_points';
  const r = (k: string, fb: [number, number, number]) => rangeOf(cfg, b, k, fb);
  const pr = r('points', [1, 10, 1]);
  const use = str(obj, 'use', 'all');
  const lr = obj.logResult && typeof obj.logResult === 'object' ? (obj.logResult as { choices?: unknown[] }) : null;
  const choices = asArray(lr?.choices as { id: string; label?: string }[]).map((c, i) => (typeof c === 'string' ? { id: c, label: c } : { id: c?.id ?? `choice_${i + 1}`, label: c?.label ?? '' }));
  const lc = r('logChoices', [2, 4, 2]);
  const hidden = !!obj.hidden && typeof obj.hidden === 'object';
  const labelMax = cfg.limits?.objectiveLabel ?? 64;
  return (
    <>
      <Group title={t('builder.ip.group')}>
        <Grid cols={2} gap={3}>
          <OptionPick label={t('builder.field.use')} value={use} options={optionsOf(cfg, b, 'use').options} disabled={ro}
            onChange={(v) => patch((o) => { o.use = v; if (v === 'random' && typeof o.count !== 'number') o.count = pr.min; if (v === 'all') delete o.count; })} />
          {use === 'random' ? (
            <RangeNumber label={t('builder.ip.count')} value={num(obj, 'count', pr.min)} range={{ ...pr, def: pr.min }} disabled={ro} onChange={(v) => set('count', v)} />
          ) : <div />}
          <Field label={t('builder.ip.label')} hint={t('builder.default_value', { value: strOf(cfg, b, 'label', 'Checking…') })}>
            <TextInput value={str(obj, 'progress.label', strOf(cfg, b, 'label', ''))} maxLength={labelMax} disabled={ro}
              onChange={(v) => set('progress.label', v.slice(0, labelMax))} />
          </Field>
          <RangeNumber label={t('builder.ip.duration')} unit={t('builder.unit.s')} integer={false} step={0.5} value={num(obj, 'progress.duration', 5)}
            range={r('progress', [1, 30, 5])} disabled={ro} onChange={(v) => set('progress.duration', Math.round(v * 10) / 10)} />
          <Field label={t('builder.ip.anim')} hint={t('builder.default_value', { value: t(`builder.anim.${strOf(cfg, b, 'animation', 'clipboard')}`) })}>
            <Select value={str(obj, 'progress.anim', strOf(cfg, b, 'animation', 'clipboard'))} disabled={ro} onChange={(v) => set('progress.anim', v)}
              options={asArray(cfg.allowed?.animations).map((a) => ({ value: a, label: t(`builder.anim.${a}`) }))} />
          </Field>
        </Grid>
        <Note>{t('builder.ip.points_note', { min: pr.min, max: pr.max })}</Note>
      </Group>
      <Group title={t('builder.ip.log_group')}>
        <Toggle checked={!!lr} disabled={ro || hidden} label={t('builder.ip.log')} description={t(hidden ? 'builder.ip.log_hidden' : 'builder.ip.log_desc')}
          onChange={(on) => patch((o) => {
            if (!on) delete o.logResult;
            else o.logResult = { choices: Array.from({ length: lc.def }, (_, i) => ({ id: `choice_${i + 1}`, label: t(`builder.ip.choice_default_${i + 1}`) })) };
          })} />
        {lr ? (
          <>
            <RangeNumber label={t('builder.ip.choices')} value={choices.length} range={lc} disabled={ro}
              onChange={(n) => patch((o) => {
                const list = choices.slice(0, n);
                while (list.length < n) list.push({ id: `choice_${list.length + 1}`, label: t(`builder.ip.choice_default_${Math.min(4, list.length + 1)}`) });
                o.logResult = { choices: list.map((c, i) => ({ id: `choice_${i + 1}`, label: c.label })) };
              })} />
            <div className="builder_client-choice-list">
              {choices.map((c, i) => (
                <Field key={c.id} label={t('builder.ip.choice_n', { n: i + 1 })}>
                  <TextInput value={c.label} maxLength={32} disabled={ro}
                    onChange={(v) => patch((o) => {
                      const list = choices.map((x) => ({ ...x }));
                      list[i].label = v.slice(0, 32);
                      o.logResult = { choices: list.map((x, k) => ({ id: `choice_${k + 1}`, label: x.label })) };
                    })} />
                </Field>
              ))}
            </div>
            <Note>{t('builder.ip.log_note')}</Note>
          </>
        ) : null}
      </Group>
    </>
  );
}

// ── skill_check ─────────────────────────────────────────────────────────────────

function SkillCheck({ cfg, def, obj, index, ro, set, patch }: PanelProps) {
  const b = 'skill_check';
  const r = (k: string, fb: [number, number, number]) => rangeOf(cfg, b, k, fb);
  const checksR = r('checks', [1, 8, 4]);
  const diffs = optionsOf(cfg, b, 'difficulty').options;
  const checks = strs(obj, 'checks', []);
  const earlierSearch = def.objectives.slice(0, index - 1).some((o) => o.block === 'interact_points' && o.hidden && typeof o.hidden === 'object');
  const shared = obj.targets === SHARED_DEVICES;
  return (
    <>
      <Group title={t('builder.sc.group')}>
        <RangeNumber label={t('builder.sc.checks')} value={checks.length} range={checksR} disabled={ro}
          onChange={(n) => patch((o) => {
            const list = strs(o, 'checks', []).slice(0, n);
            while (list.length < n) list.push(list.length ? list[list.length - 1] : 'medium');
            o.checks = list;
          })} />
        <div className="builder_client-checks">
          {checks.map((c, i) => (
            <Field key={i} label={t('builder.sc.check_n', { n: i + 1 })}>
              <SegmentedControl size="sm" value={c}
                items={diffs.map((d) => ({ key: d, label: t(`builder.opt.${d}`), disabled: ro }))}
                onChange={(v) => patch((o) => { const list = strs(o, 'checks', []).slice(); list[i] = v; o.checks = list; })} />
            </Field>
          ))}
        </div>
        <Grid cols={2} gap={3}>
          <RangeNumber label={t('builder.sc.miss_penalty')} unit={t('builder.unit.s')} value={num(obj, 'missPenalty', 30)} range={r('missPenalty', [0, 120, 30])}
            disabled={ro} onChange={(v) => set('missPenalty', v)} />
          <RangeNumber label={t('builder.sc.fail_after')} value={num(obj, 'failAfter', 2)} range={r('failAfter', [1, 3, 2])} disabled={ro}
            onChange={(v) => set('failAfter', v)} />
        </Grid>
      </Group>
      <Group title={t('builder.sc.targets_group')}>
        {earlierSearch || shared ? (
          <Field label={t('builder.sc.targets')}>
            <SegmentedControl size="sm" value={shared ? 'shared' : 'placed'}
              items={[
                { key: 'placed', label: t('builder.sc.targets_placed'), disabled: ro },
                { key: 'shared', label: t('builder.sc.targets_shared'), disabled: ro || !earlierSearch },
              ]}
              onChange={(v) => patch((o, d) => { o.targets = v === 'shared' ? SHARED_DEVICES : uniqueKey(d, 'devices', index); })} />
          </Field>
        ) : null}
        <Note>{t(shared ? 'builder.sc.shared_note' : 'builder.sc.placed_note')}</Note>
      </Group>
    </>
  );
}

// ── protect_rescue ──────────────────────────────────────────────────────────────

function ProtectRescue({ cfg, obj, ro, set }: PanelProps) {
  const b = 'protect_rescue';
  const r = (k: string, fb: [number, number, number]) => rangeOf(cfg, b, k, fb);
  return (
    <Group title={t('builder.pr.group')}>
      <Grid cols={2} gap={3}>
        <RangeNumber label={t('builder.pr.npcs')} value={num(obj, 'count', 3)} range={r('npcs', [1, 6, 3])} disabled={ro} onChange={(v) => set('count', v)} />
        <RangeNumber label={t('builder.pr.free_time')} unit={t('builder.unit.s')} integer={false} step={0.5} value={num(obj, 'freeTime', 6)} range={r('freeTime', [1, 15, 6])}
          disabled={ro} onChange={(v) => set('freeTime', Math.round(v * 10) / 10)} />
        <RangeNumber label={t('builder.pr.hit_penalty')} unit={t('builder.unit.pts')} value={num(obj, 'hitPenalty', 50)} range={r('hitPenalty', [0, 100, 50])}
          disabled={ro} onChange={(v) => set('hitPenalty', v)} />
      </Grid>
      <MultiPick label={t('builder.field.peds')} value={strs(obj, 'peds', listOf(cfg, b, 'peds'))} options={asArray(cfg.allowed?.peds)} disabled={ro}
        onChange={(v) => set('peds', v)} />
      <Toggle checked={obj.restrained !== false} disabled={ro} label={t('builder.pr.restrained')} description={t('builder.pr.restrained_desc')}
        onChange={(v) => set('restrained', v)} />
      <Toggle checked={obj.failIfDies !== false} disabled={ro} label={t('builder.pr.fail_if_dies')} description={t('builder.pr.fail_if_dies_desc')}
        onChange={(v) => set('failIfDies', v)} />
      <Note>{t('builder.pr.points_note')}</Note>
    </Group>
  );
}

// ── flee_arrest ─────────────────────────────────────────────────────────────────

function FleeArrest({ cfg, obj, ro, set, patch }: PanelProps) {
  const b = 'flee_arrest';
  const r = (k: string, fb: [number, number, number]) => rangeOf(cfg, b, k, fb);
  const mode = str(obj, 'mode', 'door');
  const suspectsR = r('suspects', [1, 10, 1]);
  const pct: Rng = { min: 0, max: 100, def: 0 };
  const resp = (blockCfgResp(cfg));
  const sum = num(obj, 'responses.surrender', 0) + num(obj, 'responses.flee', 0) + num(obj, 'responses.fight', 0);
  const g = (obj.givesUp && typeof obj.givesUp === 'object' ? obj.givesUp : {}) as { aim?: number | false; stun?: boolean; close?: unknown };
  const aimR = r('aimDistance', [5, 15, 10]);
  const closeD = numOf(cfg, b, 'closeDistance', 3);
  const closeS = numOf(cfg, b, 'closeSeconds', 3);
  const setGives = (patchG: Partial<{ aim: number | false; stun: boolean; close: unknown }>) => patch((o) => {
    const cur = (o.givesUp && typeof o.givesUp === 'object' ? o.givesUp : {}) as Record<string, unknown>;
    o.givesUp = { aim: cur.aim ?? aimR.def, stun: cur.stun ?? true, close: cur.close ?? { distance: closeD, seconds: closeS }, ...patchG };
  });
  return (
    <>
      <Group title={t('builder.fa.mode_group')}>
        <Field label={t('builder.fa.mode')} hint={t(mode === 'scatter' ? 'builder.fa.mode_scatter_hint' : 'builder.fa.mode_door_hint')}>
          <SegmentedControl size="sm" value={mode}
            items={[{ key: 'door', label: t('builder.fa.mode_door'), disabled: ro }, { key: 'scatter', label: t('builder.fa.mode_scatter'), disabled: ro }]}
            onChange={(v) => patch((o, d) => {
              o.mode = v;
              if (v === 'scatter') {
                delete o.door; delete o.suspect; delete o.fleeTo; delete o.responses; delete o.associates; delete o.knock;
                o.spawns = uniqueKey(d, 'spawns', 0);
                o.routes = uniqueKey(d, 'routes', 0);
                o.suspects = suspectsR.def;
                o.armedShare = r('armedChance', [0, 100, 20]).def;
              } else {
                delete o.spawns; delete o.routes; delete o.suspects; delete o.armedShare;
                o.door = uniqueKey(d, 'door', 0);
                o.suspect = uniqueKey(d, 'suspect', 0);
                o.fleeTo = uniqueKey(d, 'fleeTo', 0);
                o.responses = { ...resp };
                o.associates = { count: 0, spawns: uniqueKey(d, 'associates', 0) };
              }
            })} />
        </Field>
        {mode === 'door' ? (
          <>
            <Grid cols={3} gap={3}>
              {(['surrender', 'flee', 'fight'] as const).map((k) => (
                <RangeNumber key={k} label={t(`builder.fa.resp_${k}`)} unit="%" value={num(obj, `responses.${k}`, resp[k])} range={{ ...pct, def: resp[k] }}
                  disabled={ro} onChange={(v) => set(`responses.${k}`, v)} />
              ))}
            </Grid>
            <div className={`builder_client-sum ${sum === 100 ? 'is-ok' : 'is-bad'}`}>
              <Icon name={sum === 100 ? 'checkCircle' : 'alert'} size={14} />
              <span className="cp-num">{t('builder.fa.resp_sum', { sum })}</span>
            </div>
            <RangeNumber label={t('builder.fa.associates')} value={num(obj, 'associates.count', 0)}
              range={{ min: 0, max: Math.max(0, suspectsR.max - 1), def: Math.max(0, suspectsR.def - 1) }} disabled={ro}
              onChange={(v) => patch((o, d) => {
                const a = (o.associates && typeof o.associates === 'object' ? o.associates : {}) as Record<string, unknown>;
                a.count = v;
                if (typeof a.spawns !== 'string') a.spawns = uniqueKey(d, 'associates', 0);
                o.associates = a;
              })}
              note={t('builder.fa.associates_note')} />
          </>
        ) : (
          <Grid cols={2} gap={3}>
            <RangeNumber label={t('builder.fa.suspects')} value={num(obj, 'suspects', suspectsR.def)} range={suspectsR} disabled={ro} onChange={(v) => set('suspects', v)} />
            <RangeNumber label={t('builder.fa.armed_chance')} unit="%" value={num(obj, 'armedShare', 20)} range={r('armedChance', [0, 100, 20])} disabled={ro}
              onChange={(v) => set('armedShare', v)} />
          </Grid>
        )}
        <MultiPick label={t('builder.field.weapons')} value={strs(obj, 'weapons', listOf(cfg, b, 'weapons'))} options={asArray(cfg.allowed?.weapons)} disabled={ro}
          onChange={(v) => set('weapons', v)} />
      </Group>
      <Group title={t('builder.fa.escape_group')}>
        <Grid cols={2} gap={3}>
          <RangeNumber label={t('builder.fa.escape_distance')} unit={t('builder.unit.m')} value={num(obj, 'escape.distance', 400)} range={r('escapeDistance', [200, 800, 400])}
            disabled={ro} onChange={(v) => set('escape.distance', v)} />
          <RangeNumber label={t('builder.fa.escape_seconds')} unit={t('builder.unit.s')} value={num(obj, 'escape.seconds', 20)} range={r('escapeSeconds', [10, 60, 20])}
            disabled={ro} onChange={(v) => set('escape.seconds', v)} />
        </Grid>
      </Group>
      <Group title={t('builder.fa.gives_up_group')}>
        <div className="builder_client-gives-up">
          <Checkbox checked={g.aim !== false} disabled={ro} label={t('builder.fa.gives_up_aim')} onChange={(on) => setGives({ aim: on ? aimR.def : false })} />
          {g.aim !== false ? (
            <RangeNumber label={t('builder.fa.aim_distance')} unit={t('builder.unit.m')} value={typeof g.aim === 'number' ? g.aim : aimR.def} range={aimR} disabled={ro}
              onChange={(v) => setGives({ aim: v })} />
          ) : null}
          <Checkbox checked={g.stun !== false} disabled={ro} label={t('builder.fa.gives_up_stun')} onChange={(on) => setGives({ stun: on })} />
          <Checkbox checked={g.close !== false} disabled={ro} label={t('builder.fa.gives_up_close', { d: closeD, s: closeS })}
            onChange={(on) => setGives({ close: on ? { distance: closeD, seconds: closeS } : false })} />
        </div>
      </Group>
    </>
  );
}

function blockCfgResp(cfg: BuilderConfig): { surrender: number; flee: number; fight: number } {
  const v = (cfg.blocks?.flee_arrest?.responses ?? {}) as Record<string, number>;
  return { surrender: v.surrender ?? 50, flee: v.flee ?? 30, fight: v.fight ?? 20 };
}

// ── search_area ─────────────────────────────────────────────────────────────────

function SearchArea({ cfg, obj, ro, set, patch }: PanelProps) {
  const b = 'search_area';
  const r = (k: string, fb: [number, number, number]) => rangeOf(cfg, b, k, fb);
  const start = num(obj, 'startRadius', 600);
  const shrink = asArray(obj.shrinkTo as number[]);
  return (
    <Group title={t('builder.sa.group')}>
      <Grid cols={2} gap={3}>
        <RangeNumber label={t('builder.sa.start_radius')} unit={t('builder.unit.m')} value={start} range={r('startRadius', [200, 1000, 600])} disabled={ro}
          onChange={(v) => patch((o) => { o.startRadius = v; o.shrinkTo = shrinkList(asArray(o.shrinkTo as number[]), num(o, 'clueCount', 3), v); })} />
        <RangeNumber label={t('builder.sa.clues')} value={num(obj, 'clueCount', 3)} range={r('clues', [1, 5, 3])} disabled={ro}
          onChange={(v) => patch((o) => { o.clueCount = v; o.shrinkTo = shrinkList(asArray(o.shrinkTo as number[]), v, num(o, 'startRadius', 600)); })} />
        <RangeNumber label={t('builder.sa.fugitives')} value={num(obj, 'fugitives', 1)} range={r('fugitives', [1, 5, 1])} disabled={ro} onChange={(v) => set('fugitives', v)} />
        <RangeNumber label={t('builder.sa.run_distance')} unit={t('builder.unit.m')} value={num(obj, 'runDistance', 30)} range={r('runDistance', [10, 60, 30])} disabled={ro}
          onChange={(v) => set('runDistance', v)} />
      </Grid>
      <Field label={t('builder.sa.shrink')} hint={t('builder.sa.shrink_hint', { def: asArray(cfg.blocks?.search_area?.shrinkTo as number[]).join(', ') })}>
        <div className="builder_client-shrink">
          {shrink.map((v, i) => {
            const prev = i === 0 ? start : shrink[i - 1];
            return (
              <div key={i} className="builder_client-shrink__item">
                <span className="builder_client-shrink__label">{t('builder.sa.after_clue', { n: i + 1 })}</span>
                <NumberInput value={v} min={10} max={Math.max(10, prev - 1)} suffix={t('builder.unit.m')} disabled={ro} showRange={false}
                  onChange={(n) => n !== null && patch((o) => { const list = asArray(o.shrinkTo as number[]).slice(); list[i] = n; o.shrinkTo = shrinkList(list, list.length, num(o, 'startRadius', 600)); })} />
              </div>
            );
          })}
        </div>
      </Field>
      <Note>{t('builder.sa.points_note', { n: SEARCH_MIN_SPOTS })}</Note>
    </Group>
  );
}

const PANELS: Record<string, ComponentType<PanelProps>> = {
  hostile_waves: HostileWaves, escort: Escort, pursuit: Pursuit, checkpoint_route: CheckpointRoute, interact_points: InteractPoints,
  skill_check: SkillCheck, protect_rescue: ProtectRescue, flee_arrest: FleeArrest, search_area: SearchArea,
};

/** The settings panel of one objective: label, minimum time and presence range, then the block's own settings. */
export function BlockPanel(props: PanelProps) {
  const { cfg, def, obj, index, ro, errors, set } = props;
  const Panel = PANELS[obj.block];
  const p = `objectives.${index}`;
  const presence = rangeOf(cfg, obj.block, 'presenceRange', [50, 800, 150]);
  const minDefault = asArray(cfg.blockList).find((x) => x.id === obj.block)?.minSeconds ?? 30;
  const labelMax = cfg.limits?.objectiveLabel ?? 64;
  return (
    <div className="builder_client-panel">
      <Group title={t('builder.settings.common')}>
        <Field label={t('builder.settings.label')} error={messageAt(errors, `${p}.label`)} required>
          <TextInput value={str(obj, 'label', '')} maxLength={labelMax} disabled={ro} onChange={(v) => set('label', v.slice(0, labelMax))} />
        </Field>
        <Grid cols={2} gap={3}>
          <RangeNumber label={t('builder.settings.min_seconds')} unit={t('builder.unit.s')} value={num(obj, 'minSeconds', minDefault)}
            range={{ min: 1, max: Math.max(1, def.timeLimit || 1200), def: minDefault }} disabled={ro} error={messageAt(errors, `${p}.minSeconds`)}
            onChange={(v) => set('minSeconds', v)} note={t('builder.settings.min_seconds_note')} />
          <RangeNumber label={t('builder.settings.presence')} unit={t('builder.unit.m')} value={num(obj, 'presenceRange', presence.def)} range={presence}
            disabled={ro} error={messageAt(errors, `${p}.presenceRange`)} onChange={(v) => set('presenceRange', v)} note={t(`builder.presence.${obj.block}`)} />
        </Grid>
      </Group>
      {Panel ? <Panel {...props} /> : <Note tone="warning">{t('builder.settings.unknown_block', { block: obj.block })}</Note>}
    </div>
  );
}
