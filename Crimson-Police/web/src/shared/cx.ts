// Tiny className joiner (clsx-style): cx('a', cond && 'b', { c: true }).

type CxValue = string | number | false | null | undefined | Record<string, unknown> | CxValue[];

export function cx(...values: CxValue[]): string {
    const out: string[] = [];
    for (const v of values) {
        if (!v) continue;
        if (typeof v === 'string' || typeof v === 'number') out.push(String(v));
        else if (Array.isArray(v)) {
            const inner = cx(...v);
            if (inner) out.push(inner);
        } else {
            for (const k of Object.keys(v)) if (v[k]) out.push(k);
        }
    }
    return out.join(' ');
}
