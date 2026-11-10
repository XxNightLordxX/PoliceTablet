// The one notice system (modules/supervisor/notices.lua): notices:get { kind } and the actions server:notice:post
// and server:notice:end. A staff notice (an admin, every department or the ones he picks) and a department notice (a
// supervisor, his own department) are one row each with its kind.

export type NoticeKind = 'staff' | 'department';

export interface Notice {
    id: number;
    kind: NoticeKind;
    text: string;
    // null / missing = every department
    departments?: string[] | null;
    by?: string;
    createdAt: number;
    expiresAt: number;
    // history only: when and how it ended
    endedAt?: number;
    ended?: 'removed' | 'expired';
}

export interface NoticesView {
    kind: NoticeKind;
    // false = this kind is switched off (Config.Notices.staff.on): the running ones can still be ended
    canPost: boolean;
    // department kind: the supervisor's department
    department?: string;
    short?: string;
    // a reason is asked on every post and end
    reason: boolean;
    maxLength: number;
    maxDays: number;
    maxRunning: number;
    // department kind, supervisors only (admins post any number)
    perDay?: number;
    usedToday?: number;
    // what on-duty officers get when one is posted (Config.Notices.<kind>.alert)
    alert: 'off' | 'toast' | 'sound';
    // the notices of this kind running now that count against maxRunning
    counted: number;
    running: Notice[];
    history: Notice[];
}
