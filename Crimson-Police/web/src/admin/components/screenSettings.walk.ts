// The gear of each Admin UI screen and Settings -> Presets walked against the browser mocks (node walk.mjs, a gate

// The gear of each Admin UI screen and Settings -> Presets walked against the browser mocks (node walk.mjs, a gate
// step): a gear shows only its screen's sections (in the server's order, a missing one left out) and searches
// them; Settings has no gear; the search jumps to the Presets tab; a preset previews every change and the one it
// refuses, and Apply saves the changes as ordinary settings.

import '../../mocks/settings.mock';
import { action, request } from '../../shared/nui';
import { ADMIN_JUMPS, gearShown } from '../../layouts/adminNav';
import type { PresetPreview, SettingsData, SettingsReply } from '../../types/settings';
import { gearFilter, gearSections, presetState, settingCount } from './screenSettings';

const failures: string[] = [];
let passed = 0;
function ok(cond: unknown, what: string): void {
    if (cond) passed += 1;
    else failures.push(what);
}

async function steps(): Promise<void> {
    const res = await request<SettingsData>('admin:getSettings', {});
    const data = res.data;
    // the gear
    ok(gearShown('admin_home', true) && gearShown('admin_markers', true), 'Home and the other screens have a gear');
    ok(!gearShown('admin_settings', true), 'Settings itself has no gear (it is the full editor)');
    ok(!gearShown('admin_home', false), 'no gear while the admin may not open Settings');
    ok(!gearShown('home', true), 'the officer screens have no gear');
    const home = gearSections(data, 'admin_home');
    ok(home.map(s => s.key).join(',') === 'general,tablet_and_commands', 'Home gear: its sections in order');
    const money = gearSections(data, 'admin_money');
    ok(money.map(s => s.key).join(',') === 'limits_and_cash,feature_rewards', 'a section the data lacks is left out');
    ok(gearSections(data, 'admin_audit').length === 0, 'a screen with no sections shows none');
    ok(settingCount(home) === 9, `Home gear counts its settings (${settingCount(home)})`);
    const debug = gearFilter(home, 'debug');
    ok(settingCount(debug) === 1 && debug[0].key === 'general', 'the gear search finds a setting by its words');
    ok(gearFilter(home, '').length === home.length, 'an empty search shows every section');
    ok(gearFilter(home, 'zzz-nothing').length === 0, 'a search with no match shows none');
    // every setting stays in All settings: the gears show the same rows as the full list
    const all = new Set(data?.sections.flatMap(sec => sec.groups.flatMap(g => g.settings.map(s => s.path))));
    const gearRows = Object.keys(data?.screens ?? {}).flatMap(k =>
        gearSections(data, k).flatMap(sec => sec.groups.flatMap(g => g.settings.map(s => s.path))),
    );
    ok(
        gearRows.every(p => all.has(p)),
        'every gear row is a setting of All settings',
    );
    ok(
        ADMIN_JUMPS.some(j => j.screen === 'admin_settings' && j.params.tab === 'presets'),
        'the search jumps to Settings -> Presets',
    );

    // presets
    ok(data?.presets?.map(p => p.key).join(',') === 'casual,golive,broken', 'the presets in order');
    const casual = (await request<PresetPreview>('admin:previewPreset', { preset: 'casual' })).data!;
    ok(casual.changes.length === 2 && presetState(casual) === 'ready', 'Casual previews its two changes');
    const route = casual.changes.find(c => c.path === 'Markers.route');
    ok(route && route.from === true && route.to === false, 'each change shows its value now and after');
    const live = (await request<PresetPreview>('admin:previewPreset', { preset: 'golive' })).data!;
    ok(live.same === 2 && presetState(live) === 'none', 'a preset whose settings already match has nothing to apply');
    const broken = (await request<PresetPreview>('admin:previewPreset', { preset: 'broken' })).data!;
    ok(presetState(broken) === 'refused' && broken.refused[0].error === 'err.preset_path', 'a refused row blocks it');
    ok(presetState(null) === 'none', 'no preview: nothing to apply');
    const unknown = await request('admin:previewPreset', { preset: 'nope' });
    ok(!unknown.ok, 'an unknown preset is refused');
    const applied = await action<SettingsReply>('server:admin:applyPreset', { preset: 'casual' });
    ok(applied.ok && applied.data?.preset?.changed === 2, 'Apply saves every change');
    ok(
        applied.data?.settings.some(s => s.path === 'Markers.route' && s.value === false),
        'the reply has the rows',
    );
    const again = (await request<PresetPreview>('admin:previewPreset', { preset: 'casual' })).data!;
    ok(presetState(again) === 'none' && again.same === 2, 'applied again: nothing left to change');
    const refused = await action('server:admin:applyPreset', { preset: 'broken' });
    ok(!refused.ok, 'a preset with a refused row is not applied');
    await action('server:admin:resetSetting', { path: 'Markers.route' });
    await action('server:admin:resetSetting', { path: 'Limits.maxUnitSize' });
}

export async function walk(): Promise<{ passed: number; failures: string[] }> {
    try {
        await steps();
    } catch (e) {
        failures.push(`stopped: ${e instanceof Error ? e.message : String(e)}`);
    }
    return { passed, failures };
}
