// Admin UI · Real suspects walked against the browser mocks (node walk.mjs, a gate step): the screen shows
// only for admins while live crimes or volunteers are on, a case opens its timeline and damage ledger (never the
// admin's own case), and the tool form sends what modules/opponents/staff expects (or says what is wrong first).

import '../../mocks/admin_rs.mock';
import { ADMIN_GROUP_OF } from '../../layouts/adminNav';
import { ADMIN_SCREENS } from '../../layouts/screens';
import { action, request } from '../../shared/nui';
import type { Session } from '../../shared/types';
import type { RsCaseData, RsCasesData, RsPairsData } from '../../types/admin_rs';
import {
    RS_CLEAR_STRIKES_ACTION,
    RS_LIFT_ACTION,
    cidText,
    filterCases,
    ledgerSuspect,
    liftPayload,
    nameOf,
    personText,
    rowsFor,
    sinceOpen,
    sortListed,
    toolRequest,
    weaponText,
} from './realSuspects';

const failures: string[] = [];
let passed = 0;
function ok(cond: unknown, what: string): void {
    if (cond) passed += 1;
    else failures.push(what);
}

async function refused(p: Promise<unknown>): Promise<string> {
    try {
        const res = (await p) as { ok?: boolean; error?: string } | undefined;
        if (res && res.ok === false) return res.error ?? 'refused';
        return '';
    } catch (e) {
        return e instanceof Error ? e.message : String(e);
    }
}

function session(actions: string[], screen?: boolean): Session {
    return { actions, config: screen === undefined ? {} : { realSuspects: { screen } } } as unknown as Session;
}

async function steps(): Promise<void> {
    // the screen: admins (antiFarmOverride) while the server says live crimes or volunteers are on
    const def = ADMIN_SCREENS.find(s => s.key === 'admin_rs');
    ok(def !== undefined, 'the Admin UI has a Real suspects screen');
    ok(ADMIN_GROUP_OF.admin_rs === 'pvp', 'it sits under Player vs police');
    const visible = def?.visible ?? (() => true);
    ok(visible(session(['antiFarmOverride'], true)) === true, 'shown to an admin while the feature is on');
    ok(visible(session(['antiFarmOverride'], false)) === false, 'hidden while both features are off (as shipped)');
    ok(visible(session(['antiFarmOverride'])) === false, 'hidden for a server that sends no realSuspects');
    ok(visible(session(['reviewFlagged'], true)) === false, 'hidden without the antiFarmOverride key');

    // the cases list and one case
    const list = await request<RsCasesData>('admin:getRsCases', {});
    ok(list.ok && list.data && list.data.cases.length === 4, 'admin:getRsCases answers the cases');
    const cases = list.data?.cases ?? [];
    ok(filterCases(cases, 'open').length === 1, 'the Open filter keeps the running case');
    ok(
        filterCases(cases, 'flagged').every(c => c.flags + c.notes > 0),
        'With flags keeps cases with flags or notes',
    );
    ok(filterCases(cases, 'all').length === cases.length, 'All keeps every case');
    // volunteer cases: their own filter, the part he played, and the volunteer list
    const vols = filterCases(cases, 'volunteer');
    ok(vols.length === 2 && vols.every(c => c.kind === 'volunteer'), 'the Volunteers filter keeps volunteer cases');
    ok(
        filterCases(cases, 'live').every(c => c.kind === 'live'),
        'the Live crimes filter keeps live cases',
    );
    const vLine = vols.find(c => !c.own);
    ok(vLine?.volunteer?.role === 'runner' && vLine.volunteer.why === 'no_show', 'a volunteer line names his part');
    const vCase = await request<RsCaseData>('admin:getRsCase', { runUuid: vLine?.runId });
    ok(vCase.ok && vCase.data?.volunteer?.phase === 'npc', 'a volunteer case opens with its match phase');
    const listed = sortListed(list.data?.listed ?? []);
    ok(listed.length === 2 && listed[0].playing === 'travel', 'the volunteer list: whoever plays first');
    ok(!JSON.stringify(listed).includes('src'), 'and never a server id');
    const own = cases.find(c => c.own);
    ok(own !== undefined, "the admin's own case is marked");
    ok((await refused(request('admin:getRsCase', { runUuid: own?.runId }))) === 'err.own_run', 'and refused');
    const open = cases.find(c => c.open);
    const one = await request<RsCaseData>('admin:getRsCase', { runUuid: open?.runId });
    ok(one.ok && one.data !== undefined, 'a case opens');
    const data = one.data as RsCaseData;
    ok(Array.isArray(data.suspects) && data.suspects.length === 2, 'with its suspects by name');
    ok(data.lines.length > 0 && data.lines.some(l => l.flag) && data.lines.some(l => l.note), 'and its timeline');
    ok(data.ledger.length === 2, 'and its damage ledger');
    ok(!JSON.stringify(data).includes('coords'), 'and no position');
    ok(ledgerSuspect(data.ledger[0], data.suspects)?.citizenid === 'CRIM0001', 'a ledger line names its suspect');
    // the weapon by name, the raw hash only for a weapon the server has no name for
    ok(weaponText(data.ledger[0]) === 'Pistol', 'the ledger names the weapon');
    ok(weaponText({ ...data.ledger[0], weaponName: null }) === '#453432689', 'an unknown weapon reads as its hash');
    ok(weaponText({ ...data.ledger[0], weaponName: null, weapon: null }) === '-', 'no weapon reads -');
    ok(personText(data.suspects[0]) === 'Vince Carter (CRIM0001)', 'a person reads "Name (CITIZENID)"');
    ok(personText({ citizenid: 'X1' }) === 'X1' && personText(null) === '-', 'or the citizenid alone, or -');
    ok(sinceOpen(95) === '+1:35' && sinceOpen(null) === '-', 'times read from the case open');
    ok((await refused(request('admin:getRsCase', { runUuid: 'gone-0000' }))) === 'err.rs_no_case', 'a case gone');

    // the tool form: checked before it is sent, then the server's own checks
    const base = { officer: '', suspect: '', citizenid: '', days: 7, reason: 'Same pair every night' };
    ok(
        (toolRequest({ ...base, tool: 'block', officer: 'ABC12345', suspect: 'ABC12345' }) as { error?: string })
            .error === 'err.invalid_citizenid',
        'a pair needs two different players',
    );
    ok(
        (toolRequest({ ...base, tool: 'exclude', citizenid: 'CRIM0001', days: 0 }) as { error?: string }).error ===
            'err.invalid_days',
        'days must be over 0',
    );
    ok(
        (toolRequest({ ...base, tool: 'suspend', citizenid: 'ABC12345', days: 3651 }) as { error?: string }).error ===
            'err.invalid_days',
        'and at most 3650',
    );
    ok(
        (toolRequest({ ...base, tool: 'suspend', citizenid: 'ABC12345', reason: '  ' }) as { error?: string }).error ===
            'rs.ui.tool.need_reason',
        'a reason is needed',
    );
    ok(
        (toolRequest({ ...base, tool: 'exclude', citizenid: 'bad id!' }) as { error?: string }).error ===
            'err.invalid_citizenid',
        'a citizenid is letters, digits, _ and -',
    );
    const block = toolRequest({ ...base, tool: 'block', officer: ' SAST0031 ', suspect: 'CRIM0001' });
    ok(block.ok && block.action === 'server:admin:rsBlockPair', 'a pair block goes to rsBlockPair');
    if (block.ok) {
        ok(
            JSON.stringify(block.payload) ===
                '{"officer":"SAST0031","suspect":"CRIM0001","days":7,"reason":"Same pair every night"}',
            'with the trimmed citizenids, the days and the reason',
        );
        const res = await action<{ untilAt: number }>(block.action, block.payload);
        ok(res.ok && (res.data?.untilAt ?? 0) > Date.now() / 1000, 'the block runs to its end date');
    }
    const ex = toolRequest({ ...base, tool: 'exclude', citizenid: 'CRIM0001' });
    ok(ex.ok && ex.action === 'server:admin:rsExclude', 'an exclusion goes to rsExclude');
    if (ex.ok) ok((await action(ex.action, ex.payload)).ok, 'and is saved');
    const su = toolRequest({ ...base, tool: 'suspend', citizenid: 'ADM00001' });
    ok(su.ok && su.action === 'server:admin:rsSuspend', 'a suspension goes to rsSuspend');
    if (su.ok) ok((await refused(action(su.action, su.payload))) === 'err.self_target', 'never on his own character');

    // pairs and the admin rows of one player
    const pairs = await request<RsPairsData>('admin:getRsPairs', { citizenid: 'CRIM0001' });
    ok(pairs.ok && pairs.data?.citizenid === 'CRIM0001', 'admin:getRsPairs answers one player');
    ok((pairs.data?.excludedUntil ?? 0) > 0, 'with his exclusion');
    const mine = rowsFor(pairs.data?.admin ?? [], 'CRIM0001');
    ok(mine.length === 2 && mine.some(r => r.kind === 'block'), 'his admin rows: the block and the exclusion');
    ok(rowsFor(pairs.data?.admin ?? [], 'NOBODY').length === 0, "nobody else's");

    // names next to citizen IDs, from the one lookup the server sends with the pairs
    const all = await request<RsPairsData>('admin:getRsPairs', {});
    const names = all.data?.names;
    ok(cidText('ABC12345', names) === 'Maria Lopez (ABC12345)', 'a pair line reads "Name (CITIZENID)"');
    ok(cidText('CRIM0042', names) === 'CRIM0042' && cidText(null, names) === '-', 'or the citizenid alone, or -');
    ok(nameOf([], 'ABC12345') === null, 'an empty Lua table (a list) is no names');

    // lift a running row early, with a reason; a row that is not running any more is refused
    ok(all.data?.lift === true, 'the server offers Lift');
    const row = (all.data?.admin ?? []).find(r => r.kind === 'exclude' && r.suspect === 'CRIM0042');
    ok(row !== undefined, 'the exclusion is running');
    if (row) {
        const payload = liftPayload(row, '  Appeal accepted ');
        ok(
            JSON.stringify(payload) === '{"kind":"exclude","reason":"Appeal accepted","suspect":"CRIM0042"}',
            'a lift sends the kind, the citizenid it names and the trimmed reason',
        );
        ok((await refused(action(RS_LIFT_ACTION, { ...payload, reason: ' ' }))) !== '', 'a lift needs a reason');
        ok((await action(RS_LIFT_ACTION, payload)).ok, 'the exclusion is lifted');
        const after = await request<RsPairsData>('admin:getRsPairs', {});
        ok(!(after.data?.admin ?? []).some(r => r.kind === 'exclude' && r.suspect === 'CRIM0042'), 'and is gone');
        ok((await refused(action(RS_LIFT_ACTION, payload))) === 'err.rs_no_row', 'lifting it again: not running');
    }
    const blockRow = { kind: 'block' as const, officer: 'ABC12345', suspect: 'CRIM0009', untilAt: 0 };
    ok(
        JSON.stringify(liftPayload(blockRow, 'x')) ===
            '{"kind":"block","reason":"x","officer":"ABC12345","suspect":"CRIM0009"}',
        'a pair block names both',
    );

    // clear a volunteer's strikes, with a reason
    const cl = await request<RsCasesData>('admin:getRsCases', {});
    ok(cl.data?.clearStrikes === true, 'the server offers Clear strikes');
    ok(
        (await refused(action(RS_CLEAR_STRIKES_ACTION, { citizenid: 'VOL00002', reason: 'Lag' }))) ===
            'err.rs_no_strikes',
        'a volunteer with no strikes: nothing to clear',
    );
    ok((await action(RS_CLEAR_STRIKES_ACTION, { citizenid: 'VOL00001', reason: 'Lag' })).ok, 'his strikes clear');
    const cl2 = await request<RsCasesData>('admin:getRsCases', {});
    ok((cl2.data?.listed ?? []).find(v => v.citizenid === 'VOL00001')?.strikes === 0, 'and read 0');
}

export async function walk(): Promise<{ passed: number; failures: string[] }> {
    try {
        await steps();
    } catch (e) {
        failures.push(`stopped: ${e instanceof Error ? e.message : String(e)}`);
    }
    return { passed, failures };
}
