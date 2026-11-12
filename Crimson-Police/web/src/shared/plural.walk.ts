// Plural forms (shared/i18n.tsx tn, the NUI twin of CP.Ln in shared/locale.lua): key_one / key_other by the
// locale's plural rule, then key_other, then the plain key, so '1 entries' cannot happen (node walk.mjs, a gate step).

import { setLocale, t, tn } from './i18n';

const failures: string[] = [];
let passed = 0;
function ok(cond: unknown, what: string): void {
    if (cond) passed += 1;
    else failures.push(what);
}

export async function walk(): Promise<{ passed: number; failures: string[] }> {
    try {
        steps();
    } catch (e) {
        failures.push(`stopped: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
        setLocale({});
    }
    return { passed, failures };
}

// sample keys (held in a table, so tools/check_contracts.py does not look for them in the shipped locale)
const X = {
    rows: 'x.rows',
    only: 'x.only',
    plain: 'x.plain',
    missing: 'x.missing',
    few: 'x.few',
};

function steps(): void {
    setLocale({
        'x.rows_one': '{n} row',
        'x.rows_other': '{n} rows',
        'x.only_other': '{n} things',
        'x.plain': '{n} items',
    });
    ok(tn(X.rows, 1) === '1 row', `one: the _one form (${tn(X.rows, 1)})`);
    ok(tn(X.rows, 2) === '2 rows', 'two: the _other form');
    ok(tn(X.rows, 0) === '0 rows', 'zero is "other" in English');
    ok(tn(X.rows, 1200, { n: '1,200' }) === '1,200 rows', 'vars may give {n}, already formatted');
    ok(tn(X.only, 1) === '1 things', 'no _one: _other');
    ok(tn(X.plain, 1) === t(X.plain, { n: 1 }), 'no forms: the plain key, as before');
    ok(tn(X.missing, 3) === 'x.missing', 'an unknown key shows itself');
    ok(tn('', 3) === '', 'no key: no text');
    ok(tn(X.rows, Number.NaN) === 'NaN rows', 'a count that is not a number picks no form and never throws');

    // a translation sets its own rule with 'locale.lang' (the 'pl' rule has one, few and many; sample text only)
    setLocale({
        'locale.lang': 'pl',
        'x.few_one': '{n} form one',
        'x.few_few': '{n} form few',
        'x.few_many': '{n} form many',
        'x.few_other': '{n} form other',
    });
    ok(tn(X.few, 1) === '1 form one', 'pl one');
    ok(tn(X.few, 3) === '3 form few', 'pl few');
    ok(tn(X.few, 5) === '5 form many', 'pl many');
    setLocale({ 'locale.lang': 'not a language', 'x.rows_one': '{n} row', 'x.rows_other': '{n} rows' });
    ok(tn(X.rows, 1) === '1 row', 'an unknown locale.lang falls back to English');
}
