// Supervisor UI · Mission controls: the one line of help under each group's title (MissionControls.tsx GROUPS).
// The screen headers of the supervisor screens are in shared/screenHeads.ts. Checked by supHead.walk.ts.

// The Mission controls groups (MissionControls.tsx GROUPS): the one line under each group's title.
export const SUP_GROUP_HELP = {
    delays: 'sup.controls.group_help.delays',
    run: 'sup.controls.group_help.run',
    board: 'sup.controls.group_help.board',
    calls: 'sup.controls.group_help.calls',
    officers: 'sup.controls.group_help.officers',
    department: 'sup.controls.group_help.department',
} as const;
