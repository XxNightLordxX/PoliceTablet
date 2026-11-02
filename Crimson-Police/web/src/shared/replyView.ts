// An action whose reply carries the screen's fresh view applies it at once, so the
// screen needs no second request after the action. A reply without it (an older server) asks again, as before.

// (smoother workflows): replyView(data, key) reads the fresh view an action reply carries and
// applyReplyView(data, key, set, refetch) applies it, or asks again when an older server sent none. Used by Review
// Queue (server:sup:reviewFlagged and server:sup:handleDispute answer with data.queue) and Dispatch
// (server:declineMissionCall answers with data.view). Walk: replyView.walk.ts (with lastUsed.ts).
// the Admin System screen's Backups (backupNow, restoreBackup, deleteBackup) and Storage (storageCopy,
// setStorageMode, useStoreAgain) panels apply data.view the same way. So do the supervisor's Mission calls
// panel and Live Missions (data.view), the Clear cooldown dialog (data.view), the department report's activity dialog
// (data.activity, asked with activityOf), the Admin run dialog with the run list and the officer detail (data.view,
// data.runs, data.officer, asked with views) and Settings -> Reset all (data.view).

// The view under data[key] when it is an object, else null.
export function replyView<T>(data: unknown, key: string): T | null {
    if (!data || typeof data !== 'object') return null;
    const v = (data as Record<string, unknown>)[key];
    return v && typeof v === 'object' ? (v as T) : null;
}

// Apply the reply's view through set(), or call refetch() when it has none. True when the view was applied.
export function applyReplyView<T>(data: unknown, key: string, set: (v: T) => void, refetch: () => void): boolean {
    const v = replyView<T>(data, key);
    if (v) {
        set(v);
        return true;
    }
    refetch();
    return false;
}
