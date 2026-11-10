// Admin UI -> Home, the dashboard: the tiles of Live now, the Alerts lines and the shortcuts, all from the one
// admin:getHome answer, each a count that opens its screen. Pure helpers; walk: adminHome.walk.ts.

import type { IconName } from '../../shared/components';
import type { AdminScreenKey, ScreenParams } from '../../shared/navigation';
import type { AdminHomeData, HomeShortcutKey } from '../../types/admin_system';

export interface HomeLine {
    key: string;
    // locale key of the label (admin.home.<key>)
    label: string;
    n: number;
    // true: a number above 0 is something waiting (warning tone); false: just a count
    waits: boolean;
    icon: IconName;
    screen: AdminScreenKey;
    params?: ScreenParams;
}

function whole(v: unknown): number {
    const n = typeof v === 'number' && Number.isFinite(v) ? Math.floor(v) : 0;
    return n > 0 ? n : 0;
}

// Live now: officers on duty and the runs going (counts), then the queues waiting for an admin. The runs only while
// the answer has them (the liveRuns key), the Player suspects line only while the admin has that screen.
export function liveTiles(data: AdminHomeData | null | undefined): HomeLine[] {
    if (!data) return [];
    const live = data.live ?? { onDuty: 0, departments: [] };
    const q = data.queues ?? { flagged: 0, profiles: 0, disputes: 0, payments: 0 };
    const out: HomeLine[] = [
        {
            key: 'onduty',
            label: 'admin.home.live_onduty',
            n: whole(live.onDuty),
            waits: false,
            icon: 'users',
            screen: 'admin_departments',
        },
    ];
    if (live.runs) {
        out.push({
            key: 'runs',
            label: 'admin.home.live_runs',
            n: whole(live.runs.n),
            waits: false,
            icon: 'activity',
            screen: 'admin_live',
        });
    }
    out.push(
        {
            key: 'flagged',
            label: 'admin.home.queue_flagged',
            n: whole(q.flagged),
            waits: true,
            icon: 'flag',
            screen: 'admin_review',
            params: { tab: 'flagged' },
        },
        {
            key: 'profiles',
            label: 'admin.home.queue_profiles',
            n: whole(q.profiles),
            waits: true,
            icon: 'user',
            screen: 'admin_review',
            params: { tab: 'profiles' },
        },
        {
            key: 'disputes',
            label: 'admin.home.queue_disputes',
            n: whole(q.disputes),
            waits: true,
            icon: 'gavel',
            screen: 'admin_review',
            params: { tab: 'disputes' },
        },
        {
            key: 'payments',
            label: 'admin.home.queue_payments',
            n: whole(q.payments),
            waits: true,
            icon: 'dollar',
            screen: 'admin_money',
            params: { moneyTab: 'payments' },
        },
    );
    if (typeof q.rsCases === 'number') {
        out.push({
            key: 'rs',
            label: 'admin.home.queue_rs',
            n: whole(q.rsCases),
            waits: true,
            icon: 'shield',
            screen: 'admin_rs',
        });
    }
    return out;
}

// Alerts: the Problems lines, today's refused starts, Config health (warnings and errors) and the missions the last
// load refused. A line whose answer is missing (health or load not known yet) is left out.
export function alertLines(data: AdminHomeData | null | undefined): HomeLine[] {
    if (!data) return [];
    const a = data.alerts ?? { problems: 0, refusedToday: 0 };
    const out: HomeLine[] = [
        {
            key: 'problems',
            label: 'admin.home.alert_problems',
            n: whole(a.problems),
            waits: true,
            icon: 'alert',
            screen: 'admin_system',
            params: { tab: 'problems' },
        },
        {
            key: 'refused',
            label: 'admin.home.alert_refused',
            n: whole(a.refusedToday),
            waits: true,
            icon: 'xCircle',
            screen: 'admin_live',
            params: { tab: 'refused' },
        },
    ];
    if (a.health) {
        out.push({
            key: 'health',
            label: 'admin.home.alert_health',
            n: whole(a.health.warn) + whole(a.health.error),
            waits: true,
            icon: 'checkCircle',
            screen: 'admin_permissions',
        });
    }
    if (a.load) {
        out.push({
            key: 'load',
            label: a.load.error ? 'admin.home.alert_load_error' : 'admin.home.alert_load',
            n: whole(a.load.refused) + (a.load.error ? 1 : 0),
            waits: true,
            icon: 'layers',
            screen: 'admin_missions',
        });
    }
    return out;
}

// How many lines have something waiting (a card's subtitle and its warning edge).
export function waitingCount(lines: HomeLine[]): number {
    return lines.filter(l => l.waits && l.n > 0).length;
}

export interface ShortcutDef {
    key: HomeShortcutKey;
    icon: IconName;
    // locale keys: admin.home.<key>_title and admin.home.<key>_text
    title: string;
    text: string;
    screen: AdminScreenKey;
    params?: ScreenParams;
    // true: the tile holds a quick form (admin/components/HomeForms) that does the job on Home
    form: boolean;
}

// Every shortcut Config.AdminUi.homeShortcuts may name. newMission opens the wizard (params set by Home).
export const SHORTCUTS: Record<HomeShortcutKey, ShortcutDef> = {
    newMission: {
        key: 'newMission',
        icon: 'plus',
        title: 'admin.home.new_title',
        text: 'admin.home.new_text',
        screen: 'admin_missions',
        form: false,
    },
    missionSwitch: {
        key: 'missionSwitch',
        icon: 'layers',
        title: 'admin.home.onoff_title',
        text: 'admin.home.onoff_form',
        screen: 'admin_missions',
        params: { tab: 'catalog' },
        form: true,
    },
    pay: {
        key: 'pay',
        icon: 'dollar',
        title: 'admin.home.pay_title',
        text: 'admin.home.pay_form',
        screen: 'admin_money',
        form: true,
    },
    points: {
        key: 'points',
        icon: 'star',
        title: 'admin.home.points_title',
        text: 'admin.home.points_form',
        screen: 'admin_officers',
        form: true,
    },
    settings: {
        key: 'settings',
        icon: 'sliders',
        title: 'admin.home.settings_title',
        text: 'admin.home.settings_form',
        screen: 'admin_settings',
        form: true,
    },
    live: {
        key: 'live',
        icon: 'activity',
        title: 'admin.home.live_title_short',
        text: 'admin.home.live_text',
        screen: 'admin_live',
        form: false,
    },
    review: {
        key: 'review',
        icon: 'eye',
        title: 'admin.home.review_title',
        text: 'admin.home.review_text',
        screen: 'admin_review',
        form: false,
    },
    activity: {
        key: 'activity',
        icon: 'fileText',
        title: 'admin.home.activity_title',
        text: 'admin.home.activity_text',
        screen: 'admin_audit',
        form: false,
    },
};

// The shortcuts the answer names, in its order, each once; unknown keys are left out.
export function shortcutsOf(data: AdminHomeData | null | undefined): ShortcutDef[] {
    const seen = new Set<string>();
    const out: ShortcutDef[] = [];
    for (const k of Array.isArray(data?.shortcuts) ? data.shortcuts : []) {
        const def = Object.prototype.hasOwnProperty.call(SHORTCUTS, k) ? SHORTCUTS[k as HomeShortcutKey] : undefined;
        if (def && !seen.has(k)) {
            seen.add(k);
            out.push(def);
        }
    }
    return out;
}
