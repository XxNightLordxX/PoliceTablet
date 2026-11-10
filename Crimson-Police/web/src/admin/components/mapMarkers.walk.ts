// Admin UI -> Map markers walked against the browser mocks (node walk.mjs, a gate step).

// The screen shows under NPC missions, the objective's settings and kinds are listed, every part with its look, the
// prisoner van with its own switch, the pickers offer the departments, jobs, mission types and missions, and the
// rules saved are the value the server checks.

import '../../mocks/settings.mock';
import '../../mocks/builder_client.mock';
import { ADMIN_GROUP_OF } from '../../layouts/adminNav';
import { ADMIN_SCREENS } from '../../layouts/screens';
import { mockLocale } from '../../mocks/samples';
import { setLocale, t } from '../../shared/i18n';
import { action, request } from '../../shared/nui';
import type { SettingsData } from '../../types/settings';
import {
    COLOURS,
    SPRITES,
    blipKinds,
    blipParts,
    choicesWith,
    cleanRule,
    colourOf,
    extraParts,
    masterSwitch,
    objectiveSettings,
    ownSwitch,
    partsOn,
    ruleChoices,
    ruleOf,
    ruleSummary,
    rulesOf,
    toggleIn,
    withRule,
} from './mapMarkers';
import { settingsByPath } from './features';

const failures: string[] = [];
let passed = 0;
function ok(cond: unknown, what: string): void {
    if (cond) passed += 1;
    else failures.push(what);
}

async function steps(): Promise<void> {
    // the screen: under NPC missions, always shown
    const def = ADMIN_SCREENS.find(s => s.key === 'admin_markers');
    ok(def && !def.visible, 'the Map markers screen is in the Admin registry, always shown');
    ok(!ADMIN_SCREENS.some(s => (s.key as string) === 'admin_blips'), 'one screen: no Mission blips screen of its own');
    ok(ADMIN_GROUP_OF.admin_markers === 'npc', 'listed under NPC missions');
    ok(t('ui.nav.plain.admin_markers') !== 'ui.nav.plain.admin_markers', 'it has a plain name');
    ok(t('ui.screen.admin_markers') === 'Map markers', 'its title');

    // the objective's settings and the kinds of objective blip
    const res = await request<SettingsData>('admin:getSettings', {});
    const objective = objectiveSettings(res.data).map(x => x.path);
    ok(objective.join(',') === 'Markers.enabled,Markers.route', "the objective's own settings, not the parts'");
    const kinds = blipKinds(res.data);
    ok(kinds.map(k => k.id).join(',') === 'start,hostile', 'every kind, in config order');
    ok(kinds[0].sprite?.value === 162 && kinds[0].colour?.value === 5 && kinds[0].more.length === 1, 'its look');
    ok(
        kinds.every(k => t(k.nameKey) !== k.nameKey),
        'every kind has a name',
    );

    // the rows from the settings data
    ok(masterSwitch(res.data)?.value === false, 'the extra parts ship off');
    ok(masterSwitch(res.data)?.path === 'Markers.extraParts', 'switched by Markers.extraParts');
    const parts = blipParts(res.data);
    ok(
        parts.map(p => p.id).join(',') === 'prisonerVan,coronerVan,evidence,hidingSpot,partner',
        'every part, in config order',
    );
    ok(parts[0].on.value === true && ownSwitch('prisonerVan') && ownSwitch('towTruck'), 'the prisoner van ships on');
    ok(partsOn(parts) === 0, 'every extra part ships off (the prisoner van is not counted)');
    ok(extraParts(parts).length === 4, 'four extra parts');
    const van = parts[1];
    ok(
        van.look.sprite?.value === 67 && van.look.colour?.value === 40 && !!van.look.scale && !!van.look.shortRange,
        'a part: its sprite, colour, size and range settings',
    );
    ok(van.look.label?.path === 'Markers.parts.coronerVan.label', 'its label setting');
    ok(t(van.nameKey) === 'Coroner van', 'its built-in name');
    ok(
        parts.every(p => t(`admin.map_markers.hint.${p.id}`) !== `admin.map_markers.hint.${p.id}`),
        'every part has a plain hint',
    );
    ok(
        SPRITES.every(x => t(`admin.map_markers.sprite.${x.key}`) !== `admin.map_markers.sprite.${x.key}`),
        'sprites',
    );
    ok(
        COLOURS.every(x => t(`admin.map_markers.colour.${x.key}`) !== `admin.map_markers.colour.${x.key}`),
        'colours',
    );
    ok(colourOf(3)?.key === 'blue' && colourOf(84) === undefined, 'a colour id has a name, or none');

    // the pickers
    const missions = await request<{ missions: { id: string; label?: string }[] }>('admin:getMissions', {});
    const choices = ruleChoices(res.data, missions.data?.missions ?? []);
    ok(choices.departments.map(c => c.value).join(',') === 'sast,fib', 'departments from Config.Departments');
    ok(choices.departments[0]?.label === 'San Andreas State Troopers', 'with their names');
    ok(choices.jobs.map(c => c.value).join(',') === 'sast,fib', 'jobs from each department');
    ok(choices.missionTypes.map(c => c.value).join(',') === 'patrol,tactical', 'mission types from MissionTypes');
    ok(missions.ok && choices.missions.length === (missions.data?.missions ?? []).length, 'every mission to pick');
    ok(
        choicesWith(choices.jobs, ['bcso']).some(c => c.value === 'bcso'),
        'a held value no longer offered stays',
    );

    // the rules value: one part set, the others kept, empty limits dropped
    ok(JSON.stringify(rulesOf([])) === '{}', 'Lua sends no rules as []: no rules');
    const rule = { departments: toggleIn(undefined, 'sast', true), jobs: [], grade: 0, roles: 'leader' as const };
    let value = withRule({ evidence: { grade: 2 } }, 'partner', rule);
    ok(JSON.stringify(value.partner) === '{"departments":["sast"],"roles":"leader"}', 'empty limits are dropped');
    ok(value.evidence?.grade === 2, 'the other parts keep their rules');
    ok(JSON.stringify(cleanRule({ roles: 'all', grade: 3.7 })) === '{"grade":3}', "roles 'all' = no limit");
    const words = ruleSummary(ruleOf(value, 'partner'), choices);
    ok(words.length === 2 && words[0].text === 'San Andreas State Troopers', 'the rule in plain words');
    ok(ruleSummary(ruleOf(value, 'coronerVan')).length === 0, 'no rule: every officer on the run');
    value = withRule(value, 'partner', null);
    ok(!('partner' in value) && 'evidence' in value, 'removing a rule keeps the others');
    ok(JSON.stringify(withRule(value, 'evidence', {})) === '{}', 'an emptied rule removes the part');

    // saving through the Settings save flow (server:admin:setSetting, audited by the server)
    const on = await action('server:admin:setSetting', { path: 'Markers.extraParts', value: true });
    ok(on.ok, 'one click turns the extra parts on');
    await action('server:admin:setSetting', { path: 'Markers.parts.partner.on', value: true });
    await action('server:admin:setSetting', {
        path: 'Markers.rules',
        value: withRule({}, 'partner', { roles: 'leader' }),
    });
    const again = await request<SettingsData>('admin:getSettings', {});
    ok(masterSwitch(again.data)?.value === true && partsOn(blipParts(again.data)) === 1, 'on, with one part on');
    const saved = ruleOf(settingsByPath(again.data).get('Markers.rules')?.value, 'partner');
    ok(saved.roles === 'leader', 'the rule is saved');
    for (const path of ['Markers.extraParts', 'Markers.parts.partner.on', 'Markers.rules'])
        await action('server:admin:resetSetting', { path });
}

export async function walk(): Promise<{ passed: number; failures: string[] }> {
    // the real texts for this walk only (the other walks read the bundled ui texts)
    setLocale(mockLocale);
    try {
        await steps();
    } catch (e) {
        failures.push(`stopped: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
        setLocale(null);
    }
    return { passed, failures };
}
