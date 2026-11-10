// The page header of every screen of the four tablets (officer, supervisor, admin, criminal): its title and the one

// The page header of every screen of the four tablets (officer, supervisor, admin, criminal): its title and the one
// line of help under it (locale keys), and the load state every screen shows the same way. <Screen head="key"> reads
// its title and help from here (shared/components/Card.tsx). A screen made of tabs (Admin Money, Supervisor
// Department) has no head of its own: each of its tabs has one. Checked by shared/designSystem.walk.ts.

// title: the screen name key; help: the one line under it (both locale keys).
export interface ScreenHead {
    title: string;
    help: string;
}

export const SCREEN_HEADS = {
    // Officer UI
    home: { title: 'ui.screen.home', help: 'ui.help.home' },
    board: { title: 'ui.screen.board', help: 'ui.help.board' },
    dispatch: { title: 'ui.screen.dispatch', help: 'mc.subtitle' },
    unit: { title: 'ui.screen.unit', help: 'ui.help.unit' },
    active: { title: 'ui.screen.active', help: 'ui.help.active' },
    leaderboard: { title: 'ui.screen.leaderboard', help: 'ui.help.leaderboard' },
    challenge: { title: 'ui.screen.challenge', help: 'ui.help.challenge' },
    profile: { title: 'ui.screen.profile', help: 'ui.help.profile' },
    options: { title: 'ui.screen.options', help: 'options.subtitle' },
    // Supervisor UI (sup_report ... sup_training: the tabs of the Department screen)
    sup_missions: { title: 'ui.screen.sup_missions', help: 'ui.help.sup_missions' },
    sup_crossdept: { title: 'ui.screen.sup_crossdept', help: 'ui.help.sup_crossdept' },
    sup_live: { title: 'ui.screen.sup_live', help: 'ui.help.sup_live' },
    sup_payouts: { title: 'ui.screen.sup_payouts', help: 'ui.help.sup_payouts' },
    sup_builder: { title: 'ui.screen.sup_builder', help: 'ui.help.sup_builder' },
    sup_report: { title: 'ui.screen.sup_report', help: 'ui.help.sup_report' },
    sup_controls: { title: 'ui.screen.sup_controls', help: 'ui.help.sup_controls' },
    sup_review: { title: 'ui.screen.sup_review', help: 'ui.help.sup_review' },
    sup_calls: { title: 'sup.dept.tab.calls', help: 'sup.dept.calls_help' },
    sup_training: { title: 'sup.dept.tab.training', help: 'ui.help.sup_training' },
    // Admin UI: the plain names of the sidebar (layouts/adminNav.ts adminTitleKey); admin_payouts ... admin_funds are
    // the tabs of the Money screen
    admin_home: { title: 'ui.nav.plain.admin_home', help: 'ui.help.admin_home' },
    admin_missions: { title: 'ui.nav.plain.admin_missions', help: 'ui.help.admin_missions' },
    admin_live: { title: 'ui.nav.plain.admin_live', help: 'ui.help.admin_live' },
    admin_markers: { title: 'ui.nav.plain.admin_markers', help: 'ui.help.admin_markers' },
    admin_rs: { title: 'ui.nav.plain.admin_rs', help: 'ui.help.admin_rs' },
    admin_officers: { title: 'ui.nav.plain.admin_officers', help: 'ui.help.admin_officers' },
    admin_departments: { title: 'ui.nav.plain.admin_departments', help: 'ui.help.admin_departments' },
    admin_seasons: { title: 'ui.nav.plain.admin_seasons', help: 'ui.help.admin_seasons' },
    admin_leaderboards: { title: 'ui.nav.plain.admin_leaderboards', help: 'ui.help.admin_leaderboards' },
    admin_permissions: { title: 'ui.nav.plain.admin_permissions', help: 'ui.help.admin_permissions' },
    admin_payouts: { title: 'ui.nav.plain.admin_payouts', help: 'ui.help.admin_payouts' },
    admin_rewards: { title: 'ui.nav.plain.admin_rewards', help: 'ui.help.admin_rewards' },
    admin_payments: { title: 'ui.nav.plain.admin_payments', help: 'ui.help.admin_payments' },
    admin_funds: { title: 'admin.money.tab.funds', help: 'admin.money.funds_help' },
    admin_settings: { title: 'ui.nav.plain.admin_settings', help: 'ui.help.admin_settings' },
    admin_system: { title: 'ui.nav.plain.admin_system', help: 'ui.help.admin_system' },
    admin_review: { title: 'ui.nav.plain.admin_review', help: 'ui.help.admin_review' },
    admin_audit: { title: 'ui.nav.plain.admin_audit', help: 'ui.help.admin_audit' },
    admin_testing: { title: 'ui.nav.plain.admin_testing', help: 'ui.help.admin_testing' },
    // the criminal tablet (criminal/model.ts CRIM_SCREENS, as crim_<screen>)
    crim_home: { title: 'crimtab.screen.home', help: 'crimtab.help.home' },
    crim_jobs: { title: 'crimtab.screen.jobs', help: 'crimtab.help.jobs' },
    crim_active: { title: 'crimtab.screen.active', help: 'crimtab.help.active' },
    crim_history: { title: 'crimtab.screen.history', help: 'crimtab.help.history' },
    crim_rules: { title: 'crimtab.screen.rules', help: 'crimtab.help.rules' },
} satisfies Record<string, ScreenHead>;

export type ScreenHeadKey = keyof typeof SCREEN_HEADS;

// The registered screens made of tabs: no head of their own, each tab has one.
export const TABBED_SCREENS = ['admin_money', 'sup_department'];

// loading: first fetch running; error: first fetch failed; empty: the reply had no data and no error;
// stale: data from before is shown but the last refresh failed; ready: data is shown.
export type ScreenState = 'loading' | 'error' | 'empty' | 'stale' | 'ready';

export function screenStateOf(hasData: boolean, loading: boolean, error: string | null | undefined): ScreenState {
    if (hasData) return error && !loading ? 'stale' : 'ready';
    if (loading) return 'loading';
    return error ? 'error' : 'empty';
}
