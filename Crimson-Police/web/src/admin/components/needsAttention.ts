// Admin UI -> Home's Needs attention panel (step H5, Config.AdminUi.needsAttention): the lines of
// admin:getNeedsAttention, each a count that opens its screen. Pure helpers; walk: needsAttention.walk.ts.

import type { AdminScreenKey, ScreenParams } from '../../shared/navigation';
import type { NeedsAttentionData } from '../../types/admin_system';

export interface AttentionLine {
    key: 'problems' | 'refused' | 'disputes' | 'flagged' | 'rs';
    // locale key of the label (admin.home.attention_<key>)
    label: string;
    n: number;
    screen: AdminScreenKey;
    params?: ScreenParams;
}

function whole(v: unknown): number {
    const n = typeof v === 'number' && Number.isFinite(v) ? Math.floor(v) : 0;
    return n > 0 ? n : 0;
}

// The panel's lines in order. The Player suspects line only while the answer has it (the admin has that screen).
export function attentionLines(data: NeedsAttentionData | null | undefined): AttentionLine[] {
    if (!data) return [];
    const lines: AttentionLine[] = [
        {
            key: 'problems',
            label: 'admin.home.attention_problems',
            n: whole(data.problems),
            screen: 'admin_system',
            params: { tab: 'problems' },
        },
        {
            key: 'refused',
            label: 'admin.home.attention_refused',
            n: whole(data.refusedToday),
            screen: 'admin_live',
            params: { tab: 'refused' },
        },
        {
            key: 'disputes',
            label: 'admin.home.attention_disputes',
            n: whole(data.disputes),
            screen: 'admin_officers',
            params: { tab: 'disputes' },
        },
        { key: 'flagged', label: 'admin.home.attention_flagged', n: whole(data.flagged), screen: 'admin_leaderboards' },
    ];
    if (typeof data.rsCases === 'number') {
        lines.push({ key: 'rs', label: 'admin.home.attention_rs', n: whole(data.rsCases), screen: 'admin_rs' });
    }
    return lines;
}

// How many lines have something waiting (the panel's subtitle and its warning edge).
export function attentionWaiting(lines: AttentionLine[]): number {
    return lines.filter(l => l.n > 0).length;
}

// The lines of Home's Something wrong? tile, in order. With the Needs attention panel on, Problems and Refused starts
// are on the panel already, so the tile leaves them out (they would show twice).
export function wrongCheckKeys(attention: boolean): string[] {
    const all = ['load', 'health', 'problems', 'payments', 'refused'];
    return attention ? all.filter(k => k !== 'problems' && k !== 'refused') : all;
}
