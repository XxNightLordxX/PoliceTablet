// Admin UI -> Home's dashboard against the browser mocks (node walk.mjs, a gate step): the one batched admin:getHome
// answer, the Live now tiles, the Alerts lines, the screen each one opens, and the shortcuts in the configured order.

import '../../mocks/admin_system.mock';
import { adminTitleKey } from '../../layouts/adminNav';
import { request } from '../../shared/nui';
import type { AdminHomeData } from '../../types/admin_system';
import { SHORTCUTS, alertLines, liveTiles, shortcutsOf, waitingCount } from './adminHome';

const failures: string[] = [];
let passed = 0;
function ok(cond: unknown, what: string): void {
    if (cond) passed += 1;
    else failures.push(what);
}

async function steps(): Promise<void> {
    const res = await request<AdminHomeData>('admin:getHome', {});
    ok(res.ok && res.data, 'admin:getHome answers');
    const data = res.data ?? null;

    // Live now: on duty, runs, then the queues
    const tiles = liveTiles(data);
    ok(tiles.map(l => l.key).join(',') === 'onduty,runs,flagged,profiles,disputes,payments,rs', 'Live now tiles');
    const by = Object.fromEntries(tiles.map(l => [l.key, l]));
    ok(by.onduty?.n === 5 && by.onduty.screen === 'admin_departments' && !by.onduty.waits, 'on duty: Departments');
    ok(by.runs?.n === 2 && by.runs.screen === 'admin_live', 'runs going: Live');
    ok(by.flagged?.screen === 'admin_review' && by.flagged.params?.tab === 'flagged', 'flagged: Review -> Flagged');
    ok(by.profiles?.params?.tab === 'profiles' && by.disputes?.params?.tab === 'disputes', 'Review tabs');
    ok(by.payments?.screen === 'admin_money' && by.payments.params?.moneyTab === 'payments', 'stuck payments: Money');
    ok(by.rs?.screen === 'admin_rs', 'player suspect cases: Player suspects');
    ok(waitingCount(tiles) === 2, 'two queues waiting (the counts of on duty and runs never wait)');

    // no liveRuns key and no Player suspects screen: neither tile
    const plain = liveTiles({
        ...(data as AdminHomeData),
        live: { onDuty: 0, departments: [], runs: null },
        queues: { flagged: -1, profiles: 1.7, disputes: Number.NaN, payments: 0, rsCases: null },
    });
    ok(plain.map(l => l.key).join(',') === 'onduty,flagged,profiles,disputes,payments', 'no runs, no rs tile');
    ok(plain[1]?.n === 0 && plain[2]?.n === 1 && plain[3]?.n === 0, 'counts are whole and never below 0');

    // Alerts
    const alerts = alertLines(data);
    ok(alerts.map(l => l.key).join(',') === 'problems,refused,health,load', 'four alert lines in order');
    const a = Object.fromEntries(alerts.map(l => [l.key, l]));
    ok(a.problems?.screen === 'admin_system' && a.problems.params?.tab === 'problems', 'Problems opens its tab');
    ok(a.refused?.screen === 'admin_live' && a.refused.params?.tab === 'refused', 'refused: Live -> Refused');
    ok(a.health?.screen === 'admin_permissions' && a.health.n === 1, 'Config health: Permissions, warn + error');
    ok(a.load?.screen === 'admin_missions' && a.load.n === 0, 'the last mission load: Missions');
    const broken = alertLines({
        ...(data as AdminHomeData),
        alerts: { problems: 0, refusedToday: 0, health: null, load: { loaded: 0, refused: 2, error: true } },
    });
    ok(broken.length === 3 && !broken.some(l => l.key === 'health'), 'health not known: no line');
    ok(broken[2]?.label === 'admin.home.alert_load_error' && broken[2].n === 3, 'a load error counts as one more');
    ok(alertLines(undefined).length === 0 && liveTiles(null).length === 0, 'no answer: no lines');

    // Shortcuts: the configured keys in order, each once, unknown ones left out
    ok(
        shortcutsOf(data)
            .map(s => s.key)
            .join(',') === 'newMission,missionSwitch,pay,points,settings',
        'the shipped five shortcuts',
    );
    const mixed = shortcutsOf({
        ...(data as AdminHomeData),
        shortcuts: ['review', 'pay', 'review', 'nope' as never, 'activity'],
    });
    ok(mixed.map(s => s.key).join(',') === 'review,pay,activity', 'the order given, each once, unknown left out');
    ok(shortcutsOf({ ...(data as AdminHomeData), shortcuts: [] }).length === 0, '{} = no shortcuts');
    ok(Object.values(SHORTCUTS).filter(s => s.form).length === 4, 'four shortcuts hold a quick form');
    ok(SHORTCUTS.activity.screen === 'admin_audit' && SHORTCUTS.live.screen === 'admin_live', 'open-only shortcuts');

    ok(adminTitleKey('admin_live') === 'ui.nav.plain.admin_live', 'the plain title');
}

export async function walk(): Promise<{ passed: number; failures: string[] }> {
    try {
        await steps();
    } catch (e) {
        failures.push(`stopped: ${e instanceof Error ? e.message : String(e)}`);
    }
    return { passed, failures };
}
