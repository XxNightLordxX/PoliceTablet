// Admin UI -> Mission blips (Config.AdminUi.missionBlipsScreen) walked against the browser mocks (node walk.mjs, a
// gate step): the screen shows under NPC missions unless switched off, lists every part with its look, the pickers
// offer the departments, jobs, mission types and missions, and the rules saved are the value the server checks.

import '../../mocks/settings.mock';
import '../../mocks/builder_client.mock';
import { ADMIN_GROUP_OF } from '../../layouts/adminNav';
import { ADMIN_SCREENS } from '../../layouts/screens';
import { mockLocale } from '../../mocks/samples';
import { setLocale, t } from '../../shared/i18n';
import { action, request } from '../../shared/nui';
import type { Session } from '../../shared/types';
import type { SettingsData } from '../../types/settings';
import {
    COLOURS,
    SPRITES,
    blipParts,
    choicesWith,
    cleanRule,
    colourOf,
    masterSwitch,
    partsOn,
    ruleChoices,
    ruleOf,
    ruleSummary,
    rulesOf,
    toggleIn,
    withRule,
} from './missionBlips';
import { settingsByPath } from './features';

const failures: string[] = [];
let passed = 0;
function ok(cond: unknown, what: string): void {
    if (cond) passed += 1;
    else failures.push(what);
}

async function steps(): Promise<void> {
    // the screen: under NPC missions, shown unless Config.AdminUi.missionBlipsScreen = false
    const def = ADMIN_SCREENS.find(s => s.key === 'admin_blips');
    ok(def, 'the Mission blips screen is in the Admin registry');
    const session = (missionBlipsScreen?: boolean) =>
        ({ config: { adminUi: { groupSidebar: true, missionBlipsScreen } } }) as unknown as Session;
    ok(def?.visible && def.visible(session(true)) === true, 'shipped (true): the screen shows');
    ok(def?.visible && def.visible(session()) === true, 'an older session without the key: the screen shows');
    ok(def?.visible && def.visible(session(false)) === false, 'missionBlipsScreen = false: no screen');
    ok(def?.play === 'npc' && ADMIN_GROUP_OF.admin_blips === 'npc', 'listed under NPC missions in both layouts');
    ok(t('ui.nav.plain.admin_blips') !== 'ui.nav.plain.admin_blips', 'it has a plain name');

    // the rows from the settings data
    const res = await request<SettingsData>('admin:getSettings', {});
    ok(masterSwitch(res.data)?.value === false, 'the master switch ships off');
    const parts = blipParts(res.data);
    ok(parts.map(p => p.id).join(',') === 'coronerVan,evidence,hidingSpot,partner', 'every part, in config order');
    ok(partsOn(parts) === 0, 'every part ships off');
    const van = parts[0];
    ok(
        van.look.sprite?.value === 67 && van.look.colour?.value === 40 && !!van.look.scale && !!van.look.shortRange,
        'a part: its sprite, colour, size and range settings',
    );
    ok(van.look.label?.path === 'MissionBlips.parts.coronerVan.label', 'its label setting');
    ok(t(van.nameKey) === 'Coroner van', 'its built-in name');
    ok(
        parts.every(p => t(`admin.mission_blips.hint.${p.id}`) !== `admin.mission_blips.hint.${p.id}`),
        'every part has a plain hint',
    );
    ok(
        SPRITES.every(x => t(`admin.mission_blips.sprite.${x.key}`) !== `admin.mission_blips.sprite.${x.key}`),
        'sprites',
    );
    ok(
        COLOURS.every(x => t(`admin.mission_blips.colour.${x.key}`) !== `admin.mission_blips.colour.${x.key}`),
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
    const on = await action('server:admin:setSetting', { path: 'MissionBlips.enabled', value: true });
    ok(on.ok, 'one click turns the master switch on');
    await action('server:admin:setSetting', { path: 'MissionBlips.parts.partner.on', value: true });
    await action('server:admin:setSetting', {
        path: 'MissionBlips.rules',
        value: withRule({}, 'partner', { roles: 'leader' }),
    });
    const again = await request<SettingsData>('admin:getSettings', {});
    ok(masterSwitch(again.data)?.value === true && partsOn(blipParts(again.data)) === 1, 'on, with one part on');
    const saved = ruleOf(settingsByPath(again.data).get('MissionBlips.rules')?.value, 'partner');
    ok(saved.roles === 'leader', 'the rule is saved');
    for (const path of ['MissionBlips.enabled', 'MissionBlips.parts.partner.on', 'MissionBlips.rules'])
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
