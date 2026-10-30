// The New mission wizard walked through against the browser mocks (node walk.mjs, a gate step): create from a
// template, the start where the builder stands (named after its street), the spawn points filled, the check list,
// publish. The same NUI calls and helpers the wizard uses; the browser preview is the screen itself.

import '../mocks/builder_server.mock';
import '../mocks/builder_client.mock';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { action, clientAction, request } from '../shared/nui';
import type {
    BuilderConfig,
    BuilderCreateResult,
    BuilderDefinition,
    BuilderPublishResult,
    BuilderSaveResult,
    BuilderValidateResult,
} from '../types/builder_server';
import type { BuilderAutoPointsReply, BuilderHereReply, PointSpec } from '../types/builder_client';
import { applyResult } from './applyResult';
import {
    NEW_MISSION_PARAMS,
    asksNewMission,
    checkGroups,
    fillPlan,
    keepsBaseName,
    missingPoints,
    newMissionOpens,
    wizardName,
    workLocation,
} from './quickMission';
import { missionPointSpecs } from './schema';
import { QuickMissionStart } from './QuickMission';
import { normalizeConfig } from './useBuilderConfig';
import { startSpec } from './useDraftEditor';

const failures: string[] = [];
let passed = 0;
function ok(cond: unknown, what: string): void {
    if (cond) passed += 1;
    else failures.push(what);
}

async function data<T>(p: Promise<{ ok: boolean; data?: T; error?: string }>, what: string): Promise<T> {
    const r = await p;
    if (!r.ok || r.data === undefined) throw new Error(`${what}: ${r.error ?? 'no data'}`);
    return r.data;
}

// The builderPlace payload of a key (what useDraftEditor sends for it)
function payload(id: string, def: BuilderDefinition, spec: PointSpec, li: number) {
    const loc = def.locations[li - 1];
    return {
        missionId: id,
        location: li,
        key: spec.key,
        kind: spec.kind === 'route' ? 'marker' : spec.kind,
        model: spec.model,
        heading: spec.heading,
        multiple: spec.multiple,
        min: spec.min,
        max: spec.max,
        points: [],
        start: loc.start ? loc.start.coords : null,
        spawn: spec.spawn,
        otherStarts: [],
        label: spec.key,
        ui: 'admin',
        ...(spec.key === 'start' ? { radius: 60, radiusMin: 20, radiusMax: 150 } : {}),
    };
}

export async function walk(): Promise<{ passed: number; failures: string[] }> {
    try {
        await steps();
    } catch (e) {
        failures.push(`stopped: ${e instanceof Error ? e.message : String(e)}`);
    }
    return { passed, failures };
}

async function steps(): Promise<void> {
    // 1 · What: the wizard is on and offers the templates
    const cfg: BuilderConfig = normalizeConfig(await data(request<BuilderConfig>('builder:config', {}), 'config'));
    ok(cfg.quickWizard === true, 'builder:config says the wizard is on (Config.Builder.quickWizard)');
    // every "New mission" (the Missions header, Home's tile, the Builder list) opens it in one press
    ok(newMissionOpens(cfg) === 'wizard', 'New mission opens the wizard');
    ok(newMissionOpens({ quickWizard: false }) === 'dialog', 'quickWizard = false: New mission opens the dialog');
    ok(newMissionOpens({}) === 'wizard' && newMissionOpens(null) === 'wizard', 'a missing quickWizard means on');
    ok(asksNewMission({ ...NEW_MISSION_PARAMS }), "Home's Make a new mission tile asks for New mission");
    ok(NEW_MISSION_PARAMS.tab === 'builder', "Home's tile opens the Builder tab");
    ok(!asksNewMission({ tab: 'builder' }) && !asksNewMission({ tab: 'catalog' }), 'the other links only switch tab');
    const tpl = (cfg.templates ?? []).find(x => x.id === 'gang_shootout');
    ok(tpl && tpl.label && tpl.blurb, 'the Gang shootout template card has a name and a blurb');
    const first = renderToStaticMarkup(
        createElement(QuickMissionStart, {
            config: cfg,
            onCreated: () => {},
            onCancel: () => {},
            onFullEditor: () => {},
        }),
    );
    ok(
        first.includes(tpl?.label ?? '?') && first.includes('builder.quick.scratch') && first.includes('aria-current'),
        'step 1 draws a card per template, Start from scratch and the four steps',
    );
    const made = await data(
        action<BuilderCreateResult>('server:builder:create', { template: 'gang_shootout' }),
        'create from a template',
    );
    let id = made.id;
    const base = made.record.definition.label;
    let def: BuilderDefinition = made.record.definition;
    ok(def.objectives.length > 0, 'the template brings its objectives');
    ok(def.locations.length === 1 && !def.locations[0].start, 'and one empty location');
    await data(action('server:builder:lock', { id }), 'lock');

    // 2 · Where: the start where the builder stands, named after its street
    const li = workLocation(def.locations);
    ok(li === 1, 'the wizard works on the first location without a start');
    const specs = missionPointSpecs(cfg, def);
    ok(fillPlan(specs, def.locations[0]).length === 0, 'nothing is filled before the start is placed');
    const here = await data(clientAction<BuilderHereReply>('builderHere', payload(id, def, startSpec(), li)), 'here');
    ok(here.ok && here.street === 'Elysian Fields Fwy', 'Use my position answers the street at the start');
    const started = applyResult(def, here.result!, startSpec(), cfg);
    ok(started.def && started.def.locations[0].start, 'the start is set');
    def = started.def!;
    ok(keepsBaseName(def.label, base), 'the mission still has the name it was created with');
    def.label = wizardName(base, here.street, cfg.limits?.label ?? 64);
    ok(def.label === `${base} - Elysian Fields Fwy`, 'the name becomes "<template> - <street at the start>"');

    // the Check step before the points: the locations group with its Fix button
    const early = await data(
        action<BuilderValidateResult>('server:builder:validate', { id, definition: def }),
        'validate early',
    );
    ok(
        checkGroups(early.errors).some(g => g.step === 'locations' && g.location === 1),
        'the check list sends the missing points to the Locations step (Fix)',
    );

    // Fill the points for me: every fillable key gets its missing points
    const plan = fillPlan(specs, def.locations[0]);
    ok(plan.length > 0, 'Fill the points for me has spawn points to fill');
    for (const task of plan) {
        const reply = await data(
            clientAction<BuilderAutoPointsReply>('builderAutoPoints', {
                ...payload(id, def, task.spec, li),
                count: task.count,
            }),
            `fill ${task.spec.key}`,
        );
        ok(reply.ok && reply.proposed.length === task.count, `${task.spec.key}: ${task.count} points proposed`);
        const applied = applyResult(def, reply.result!, task.spec, cfg);
        ok(applied.def, `${task.spec.key}: kept`);
        if (applied.def) def = applied.def;
    }
    ok(fillPlan(specs, def.locations[0]).length === 0, 'nothing is left to fill');
    // a point the game cannot propose (a single marker, a boss): Add here, as the missing list offers
    for (const m of missingPoints(specs, def.locations[0])) {
        for (let i = m.have; i < m.need; i++) {
            const r = await data(
                clientAction<BuilderHereReply>('builderHere', payload(id, def, m.spec, li)),
                `here ${m.spec.key}`,
            );
            const applied = r.result ? applyResult(def, r.result, m.spec, cfg) : null;
            if (applied?.def) def = applied.def;
        }
    }
    ok(missingPoints(specs, def.locations[0]).length === 0, 'every point of the location is placed');

    // 3 · Check: nothing left in the list
    const saved = await data(action<BuilderSaveResult>('server:builder:save', { id, definition: def }), 'save');
    id = saved.id;
    const check = await data(
        action<BuilderValidateResult>('server:builder:validate', { id, definition: def }),
        'validate',
    );
    ok(checkGroups(check.errors).length === 0, `the check list is empty (${check.errors.map(e => e.key).join(', ')})`);

    // 4 · Publish
    const pub = await data(action<BuilderPublishResult>('server:builder:publish', { id }), 'publish');
    ok(pub.version === 1, 'published as version 1');
    const rec = await data(request<{ label: string; status: string }>('builder:get', { id }), 'get');
    ok(rec.status === 'published' && rec.label === `${base} - Elysian Fields Fwy`, 'live under the proposed name');
}
