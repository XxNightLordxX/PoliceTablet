// Officer UI screen heads and load states (steps H2 and H3, R1): every officer screen (part 1: Home, Mission Board,

export type OfficerHeadKey =
    'home' | 'board' | 'active' | 'dispatch' | 'unit' | 'profile' | 'leaderboard' | 'options' | 'challenge';

// title: the screen name key; help: the one line under it (locale keys).
export interface OfficerHead {
    title: string;
    help: string;
}

export const OFFICER_HEADS: Record<OfficerHeadKey, OfficerHead> = {
    home: { title: 'ui.screen.home', help: 'ui.help.home' },
    board: { title: 'ui.screen.board', help: 'board.subtitle' },
    active: { title: 'ui.screen.active', help: 'ui.help.active' },
    dispatch: { title: 'ui.screen.dispatch', help: 'mc.subtitle' },
    unit: { title: 'ui.screen.unit', help: 'ui.help.unit' },
    profile: { title: 'ui.screen.profile', help: 'ui.help.profile' },
    leaderboard: { title: 'ui.screen.leaderboard', help: 'ui.help.leaderboard' },
    options: { title: 'ui.screen.options', help: 'options.subtitle' },
    challenge: { title: 'ui.screen.challenge', help: 'ui.help.challenge' },
};

// loading: first fetch running; error: first fetch failed; empty: the reply had no data and no error;
// stale: data from before is shown but the last refresh failed; ready: data is shown.
export type ScreenState = 'loading' | 'error' | 'empty' | 'stale' | 'ready';

export function screenStateOf(hasData: boolean, loading: boolean, error: string | null | undefined): ScreenState {
    if (hasData) return error && !loading ? 'stale' : 'ready';
    if (loading) return 'loading';
    return error ? 'error' : 'empty';
}
