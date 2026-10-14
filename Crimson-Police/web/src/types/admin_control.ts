// Full admin control: the shapes every admin package shares (docs/ARCHITECTURE.md §9.5, "Admin control").
// Package shapes live in types/admin_officers.ts, admin_missions.ts, admin_live.ts, admin_economy.ts and
// admin_system.ts; this file holds only what the kit and the layouts use.

// ============================================================================
//                               MAINTENANCE LOCK
// ============================================================================

// CP.Maintenance.view(): the session's maintenance and the 'maintenance' push (false = the lock ended).
export interface MaintenanceView {
    kind: 'storage' | 'restore' | 'left_behind';
    since: number;
    // the work is done: only a restart of Crimson-Police (txAdmin or the console) ends the lock
    restart?: boolean;
    by?: string;
}

// ============================================================================
//                                  BULK JOBS
// ============================================================================

// The 'adminjob' push (admin players only) after every batch of a job.
export interface AdminJobProgress {
    id: string;
    kind: string;
    state: 'running' | 'done' | 'failed' | 'rolledback';
    done: number;
    total: number;
}

// ============================================================================
//                             ACTIONS AND PREVIEWS
// ============================================================================

// What every admin action may carry (CP.AdminKit guards): the request id (I), the reason (R), the typed word (T),
// the preview token (V).
export interface AdminActionBase {
    requestId?: string;
    reason?: string;
    confirm?: string;
    previewToken?: string;
}

// A read callback that previews an action: the exact effect and the token the action needs within 120 s.
export interface AdminPreview<E = unknown> {
    previewToken: string;
    expiresAt: number;
    effect: E;
}

// A money effect line of a confirm dialog (MoneyEffect).
export interface MoneyEffectLine {
    label: string;
    amount: number;
    // shown struck through (what it was)
    before?: number;
}

// ============================================================================
//                          SIDEBAR COUNTS (ADMIN UI)
// ============================================================================

// The admin-only NavCounts keys (T.registerNavCount(key, fn, { adminOnly = true })): sent to admin players only.
export interface AdminNavCounts {
    adminReview?: number;
    adminDisputes?: number;
    adminPayments?: number;
    adminLive?: number;
}

// ============================================================================
//                               SLOT COMPONENTS
// ============================================================================
// A screen that shows another package's controls renders its slot; the owning package fills it in.

// Officers → officer detail: OfficerRunControls (P3), OfficerSupport (P5).
export interface OfficerSlotProps {
    citizenid: string;
    online: boolean;
    // the admin:getOfficer reply the host screen shows (OfficerDetail in types/oversight.ts)
    officer?: unknown;
    // the host screen reloads the officer
    onChanged?: () => void;
}

// Departments → each department card: DepartmentFunds (P4).
export interface DepartmentSlotProps {
    department: string;
}

// Settings → Item rewards: RewardPoolEditor (P4). handlesRewardPool(path) says which settings it edits; the host
// shows its own JSON editor for the rest.
export interface RewardPoolSlotProps {
    path: string;
    value: unknown;
    disabled?: boolean;
    onSave: (value: unknown) => void | Promise<unknown>;
}
