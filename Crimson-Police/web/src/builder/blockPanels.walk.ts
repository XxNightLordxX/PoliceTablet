// Block settings and Details with Config.Builder.foldAdvanced against the browser mocks (node walk.mjs, a gate
// step): the shootout's four basics open, every other setting under a closed "More settings", Easy/Normal/Hard
// inside the server's ranges, and folding off draws every setting open as before.

import '../mocks/builder_server.mock';
import '../mocks/builder_client.mock';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { request } from '../shared/nui';
import type { BuilderConfig, BuilderDefinition, BuilderObjective } from '../types/builder_server';
import { BlockPanel } from './BlockPanels';
import { foldsAdvanced, hwDifficultyOf, hwDifficultyStats, perWaveOf } from './blockBasics';
import { StepDetails } from './steps/StepDetails';
import type { StepProps } from './steps/common';
import { normalizeConfig } from './useBuilderConfig';

const failures: string[] = [];
let passed = 0;
function ok(cond: unknown, what: string): void {
    if (cond) passed += 1;
    else failures.push(what);
}

export async function walk(): Promise<{ passed: number; failures: string[] }> {
    try {
        await steps();
    } catch (e) {
        failures.push(`stopped: ${e instanceof Error ? e.message : String(e)}`);
    }
    return { passed, failures };
}

const shootout = (): BuilderObjective =>
    ({
        block: 'hostile_waves',
        label: 'Clear the dock',
        minSeconds: 45,
        presenceRange: 150,
        waves: [6, 6],
        nextWave: { aliveAtMost: 2, afterSeconds: 90 },
        weapons: ['WEAPON_PISTOL'],
        accuracy: 25,
        armour: 0,
        health: 200,
    }) as BuilderObjective;

const draft = (obj: BuilderObjective): BuilderDefinition =>
    ({
        id: 'custom_walk',
        label: 'Walk',
        description: '',
        type: 'tactical',
        departments: [],
        minOfficers: 1,
        maxOfficers: 4,
        difficulty: 2,
        timeLimit: 600,
        startTimeout: 600,
        cooldown: 1200,
        vehiclePenalties: true,
        locations: [],
        objectives: [obj],
        scaling: [],
        items: [],
        bonuses: [],
        penalties: [],
    }) as unknown as BuilderDefinition;

function panel(cfg: BuilderConfig, obj: BuilderObjective): string {
    return renderToStaticMarkup(
        createElement(BlockPanel, {
            cfg,
            def: draft(obj),
            obj,
            index: 1,
            ro: false,
            errors: [],
            set: () => {},
            patch: () => {},
        }),
    );
}

// the controls of a piece of markup: number fields, multi-picks and segmented controls, one label each
const controls = (html: string) => (html.match(/class="cp-field__label"/g) ?? []).length;

async function steps(): Promise<void> {
    const r = await request<BuilderConfig>('builder:config', {});
    if (!r.ok || !r.data) throw new Error(`config: ${r.error ?? 'no data'}`);
    const cfg = normalizeConfig(r.data);
    ok(cfg.foldAdvanced === true && foldsAdvanced(cfg), 'builder:config folds (Config.Builder.foldAdvanced)');
    ok(foldsAdvanced({}) && foldsAdvanced(null) && !foldsAdvanced({ foldAdvanced: false }), 'missing = on');

    // the shootout: name, then four basics, then a closed More settings with the rest
    const html = panel(cfg, shootout());
    const at = html.indexOf('<details');
    ok(at > 0 && !/<details[^>]* open/.test(html), 'the block panel has a closed More settings');
    ok(html.includes('builder.settings.more') || html.includes('More settings'), 'it is called More settings');
    const open = at > 0 ? html.slice(0, at) : html;
    const folded = at > 0 ? html.slice(at) : '';
    const g = 'class="builder_client-group"';
    const basics = open.slice(open.indexOf(g, open.indexOf(g) + 1));
    ok(controls(basics) === 4, `the shootout shows 4 controls open (shows ${controls(basics)})`);
    for (const k of ['builder.hw.waves', 'builder.hw.per_wave', 'builder.field.weapons', 'builder.hw.difficulty'])
        ok(basics.includes(`>${k}<`), `${k} is open`);
    for (const k of [
        'builder.field.accuracy',
        'builder.field.peds',
        'builder.hw.boss_group',
        'builder.hw.next_alive',
        'builder.settings.presence',
        'builder.settings.min_seconds',
    ]) {
        ok(!open.includes(`>${k}<`) && folded.includes(`>${k}<`), `${k} is under More settings`);
    }
    ok(!folded.includes('>builder.hw.basics_group<'), 'the basics are not drawn twice');
    ok((html.match(/>builder\.field\.weapons</g) ?? []).length === 1, 'weapons once');
    ok((html.match(/>builder\.hw\.waves</g) ?? []).length === 1, 'the wave count once');
    ok(html.includes('aria-checked="true"'), 'the shipped stats read as one of Easy, Normal, Hard');

    // Easy / Normal / Hard stay inside the ranges the server sends
    const easy = hwDifficultyStats(cfg, 'easy');
    const normal = hwDifficultyStats(cfg, 'normal');
    const hard = hwDifficultyStats(cfg, 'hard');
    ok(normal.accuracy === 25 && normal.armour === 0 && normal.health === 200, 'Normal = the defaults');
    ok(easy.accuracy < normal.accuracy && easy.health < normal.health && easy.armour === 0, 'Easy is softer');
    ok(hard.accuracy > normal.accuracy && hard.armour > 0 && hard.health > normal.health, 'Hard is harder');
    ok(hard.accuracy <= 60 && hard.armour <= 100 && hard.health <= 400 && easy.accuracy >= 5, 'inside the ranges');
    ok(hwDifficultyOf(cfg, hard) === 'hard' && hwDifficultyOf(cfg, easy) === 'easy', 'a level reads back');
    ok(hwDifficultyOf(cfg, { accuracy: 33, armour: 7, health: 211 }) === null, 'hand-set stats read as custom');
    ok(perWaveOf([6, 6], 7).value === 6 && !perWaveOf([6, 6], 7).mixed, 'enemies per wave: every wave');
    ok(perWaveOf([4, 8], 7).value === 8 && perWaveOf([4, 8], 7).mixed, 'waves that differ show the largest');

    // an error on a folded field opens More settings
    const bad = renderToStaticMarkup(
        createElement(BlockPanel, {
            cfg,
            def: draft(shootout()),
            obj: shootout(),
            index: 1,
            ro: false,
            errors: [{ path: 'objectives.1.minSeconds', message: 'too low' }],
            set: () => {},
            patch: () => {},
        }),
    );
    ok(/<details[^>]* open/.test(bad), 'an error under More settings opens it');

    // folding off: every setting open as before, no More settings, no Difficulty
    const off = panel({ ...cfg, foldAdvanced: false }, shootout());
    ok(!off.includes('<details'), 'foldAdvanced = false: no More settings');
    ok(!off.includes('>builder.hw.difficulty<') && off.includes('>builder.field.accuracy<'), 'and every field open');

    // Details: name, type, difficulty and team size open, the rest folded
    const obj = shootout();
    const props = {
        ed: { errors: [], update: () => {} },
        cfg,
        def: draft(obj),
        ro: false,
        scope: 'admin',
        goTo: () => {},
    } as unknown as StepProps;
    const det = renderToStaticMarkup(createElement(StepDetails, props));
    const dAt = det.indexOf('<details');
    const dOpen = dAt > 0 ? det.slice(0, dAt) : det;
    ok(dAt > 0 && !/<details[^>]* open/.test(det), 'Details has a closed More settings');
    for (const k of ['name', 'type', 'difficulty', 'min_officers', 'max_officers'])
        ok(dOpen.includes(`>builder.details.${k}<`), `Details shows ${k} open`);
    for (const k of ['description', 'time_limit', 'cooldown', 'vehicle_penalties'])
        ok(!dOpen.includes(`>builder.details.${k}<`) && det.includes(`>builder.details.${k}<`), `${k} folded`);
    const detOff = renderToStaticMarkup(createElement(StepDetails, { ...props, cfg: { ...cfg, foldAdvanced: false } }));
    ok(!detOff.includes('<details') && detOff.includes('>builder.details.time_limit<'), 'Details unfolded when off');
}
