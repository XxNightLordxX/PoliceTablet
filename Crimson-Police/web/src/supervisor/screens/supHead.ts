// Supervisor screens inside (step H4): Mission controls and Review Queue use the Officer UI's header (title, then one
// line of help) and load states (officer/screens/screenHead, ScreenStatus); each Mission controls group card says what
// its task is. Display only. Checked by supHead.walk.ts.

import type { OfficerHead } from '../../officer/screens/screenHead';

export type SupHeadKey = 'controls' | 'review';

export const SUP_HEADS: Record<SupHeadKey, OfficerHead> = {
    controls: { title: 'ui.screen.sup_controls', help: 'ui.help.sup_controls' },
    review: { title: 'ui.screen.sup_review', help: 'ui.help.sup_review' },
};

// The Mission controls groups (MissionControls.tsx GROUPS): the one line under each group's title.
export const SUP_GROUP_HELP = {
    delays: 'sup.controls.group_help.delays',
    run: 'sup.controls.group_help.run',
    board: 'sup.controls.group_help.board',
    calls: 'sup.controls.group_help.calls',
    officers: 'sup.controls.group_help.officers',
    department: 'sup.controls.group_help.department',
} as const;
