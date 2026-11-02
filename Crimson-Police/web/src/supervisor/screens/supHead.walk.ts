// Supervisor screens inside against the browser mocks (node walk.mjs, a gate step): Mission controls and

// Supervisor screens inside against the browser mocks (node walk.mjs, a gate step): Mission controls and
// Review Queue use the shared header and load states, each Mission controls group says what it is for, Notices and
// Field training are split by task with the stale line, the risky actions still ask first, and the Department
// Report's 'Your controls today' rows (myControls.ts) show value, limits and today's use.

import '../../mocks/core.mock';
import fieldTraining from '../../../../locales/parts/field_training.json';
import missionControls from '../../../../locales/parts/mission_controls.json';
import ui from '../../../../locales/parts/ui.json';
import type { Session } from '../../shared/types';
import type { MyControl } from '../../types/oversight';
import noticesSrc from '../components/DeptNoticesCard.tsx?raw';
import ftoSrc from '../components/FieldTrainingPanel.tsx?raw';
import cardSrc from '../components/MyControlsCard.tsx?raw';
import { controlsCardOn, myControlRow, myControlRows } from '../components/myControls';
import reportSrc from './DeptReport.tsx?raw';
import controlsSrc from './MissionControls.tsx?raw';
import reviewSrc from './ReviewQueue.tsx?raw';
import { SUP_GROUP_HELP, SUP_HEADS } from './supHead';

const failures: string[] = [];
let passed = 0;
function ok(cond: unknown, what: string): void {
    if (cond) passed += 1;
    else failures.push(what);
}

const locale = { ...fieldTraining, ...missionControls, ...ui } as Record<string, string>;
const line = (k: string) => typeof locale[k] === 'string' && locale[k].length > 0 && !locale[k].includes('\n');

export async function walk(): Promise<{ passed: number; failures: string[] }> {
    try {
        steps();
    } catch (e) {
        failures.push(`stopped: ${e instanceof Error ? e.message : String(e)}`);
    }
    return { passed, failures };
}

function steps(): void {
    // headers and load states: Mission controls and Review Queue
    const sources: [keyof typeof SUP_HEADS, string][] = [
        ['controls', controlsSrc],
        ['review', reviewSrc],
    ];
    for (const [key, src] of sources) {
        const head = SUP_HEADS[key];
        ok(line(head.title), `${key}: title in the locale`);
        ok(line(head.help) && locale[head.help].length <= 120, `${key}: help is one short line`);
        ok(src.includes(`SUP_HEADS.${key}.title`) && src.includes(`SUP_HEADS.${key}.help`), `${key}: SUP_HEADS`);
        ok(src.includes('<ScreenStatus'), `${key}: ScreenStatus for its load states`);
        ok(!src.includes('<LoadingBlock') && !src.includes('<ErrorState'), `${key}: no own loading or error block`);
    }

    // Mission controls: every group has its one line of help, and the group cards show it
    const groups = /const GROUPS = \[([^\]]+)\]/.exec(controlsSrc)?.[1] ?? '';
    const keys = [...groups.matchAll(/'(\w+)'/g)].map(m => m[1]);
    ok(keys.length === 6, 'controls: six groups');
    for (const g of keys) {
        const k = (SUP_GROUP_HELP as Record<string, string>)[g];
        ok(k && line(k), `controls: group ${g} has a help line`);
    }
    ok(controlsSrc.includes('subtitle={t(SUP_GROUP_HELP[g.key])}'), 'controls: the group card shows its help');

    // Notices and Field training: split by task, the stale line
    ok(noticesSrc.includes("t('sup.notices.post_title')") && line('sup.notices.post_title'), 'notices: Post heading');
    ok(
        noticesSrc.includes("t('sup.notices.running'") && locale['sup.notices.running']?.includes('{n}'),
        'notices: Running now heading with its count',
    );
    ok(noticesSrc.includes('<ScreenStatus'), 'notices: the stale line');
    ok(!noticesSrc.includes('sup-mc-row__desc'), 'notices: the description is the card subtitle');
    ok(ftoSrc.includes("t('fto.pairs_title'") && locale['fto.pairs_title']?.includes('{n}'), 'fto: Pairings heading');
    ok(ftoSrc.includes('<ScreenStatus'), 'fto: the stale line');

    // risky actions still ask first (no behaviour change)
    ok(noticesSrc.includes("'sup.notices.end_confirm'"), 'notices: End takes two clicks');
    ok(ftoSrc.includes("'fto.unpair_confirm'"), 'fto: End training takes two clicks');
    ok(/<ConfirmDialog[\s\S]*required: true/.test(reviewSrc), 'review: Approve / Void / Reject ask for a reason');
    ok(controlsSrc.includes('<ReasonDialog'), 'controls: every change and reset asks for a reason');

    // Your controls today: shown only when switched on, on the Department Report
    const session = (on: unknown) => ({ config: { supervisorNav: { controlsCard: on } } }) as unknown as Session;
    ok(controlsCardOn(session(true)), 'card: on with supervisorControlsCard = true');
    ok(!controlsCardOn(session(false)) && !controlsCardOn(session('yes')) && !controlsCardOn(null), 'card: else off');
    ok(reportSrc.includes('<MyControlsCard />'), 'card: on the Department Report');
    ok(cardSrc.includes('skip: !on') && cardSrc.includes("'sup:getMyControls'"), 'card: asks only when switched on');
    for (const k of ['title', 'subtitle', 'col.control', 'col.value', 'col.limits', 'col.today', 'action', 'none']) {
        ok(line(`sup.mine.${k}`), `card: sup.mine.${k} in the locale`);
    }
    ok(locale['sup.mine.used']?.includes('{used}') && locale['sup.mine.used'].includes('{n}'), 'card: used of n');
    ok(line('err.controls_card_off'), 'card: the server error when switched off');

    const value: MyControl = { key: 'hourlyCap', kind: 'number', value: 8, configValue: 8, min: 1, max: 16 };
    const r1 = myControlRow(value);
    ok(!r1.action && r1.limits?.min === 1 && r1.limits.max === 16, 'row: value control with its limits');
    ok(r1.today === 'none' && !r1.changed, 'row: no day count, config value in use');
    const changed = myControlRow({ ...value, changed: true, min: undefined });
    ok(changed.changed && changed.limits === null, 'row: a change in use; no limits without both ends');
    const award: MyControl = { key: 'awardPoints', kind: 'action', perDay: 100, usedToday: 40 };
    const r2 = myControlRow(award);
    ok(r2.action && r2.today === 'left' && r2.used === 40 && r2.perDay === 100, 'row: action with uses left');
    const ban: MyControl = { key: 'missionBan', kind: 'action', perDay: 3, usedToday: 3 };
    ok(myControlRow(ban).today === 'used', 'row: every use of today spent');
    ok(myControlRow({ ...ban, usedToday: undefined }).used === 0, 'row: no count from the server = 0 used');
    ok(myControlRow({ ...ban, perDay: 0 }).today === 'none', 'row: perDay 0 = no day count');
    const order = myControlRows([value, award, ban]).map(r => r.key);
    ok(order.join() === 'missionBan,awardPoints,hourlyCap', 'rows: most used up first, the rest in server order');
    ok(myControlRows(null).length === 0 && myControlRows(undefined).length === 0, 'rows: nothing sent, no rows');
}
