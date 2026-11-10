// The one Review queue (review:getQueue): flagged runs and disputes in one list with a type column. Pure helpers of
// supervisor/components/ReviewQueuePanel.tsx (the Supervisor UI's Department -> Review and the Admin UI's Review ->
// Queue); walk: reviewQueue.walk.ts.

import type { ReviewItem, ReviewItemType } from '../../types/oversight';

// What the queue shows: every item, or one type.
export type ReviewShow = 'all' | ReviewItemType;
export const REVIEW_SHOWS: ReviewShow[] = ['all', 'flag', 'dispute'];

export function showOf(v: unknown): ReviewShow {
    return v === 'flag' || v === 'dispute' ? v : 'all';
}

export function itemsOf(items: ReviewItem[] | null | undefined, show: ReviewShow): ReviewItem[] {
    const list = Array.isArray(items) ? items : [];
    return show === 'all' ? list : list.filter(i => i.type === show);
}

export function countsOf(items: ReviewItem[] | null | undefined): Record<ReviewShow, number> {
    const list = Array.isArray(items) ? items : [];
    const flag = list.filter(i => i.type === 'flag').length;
    return { all: list.length, flag, dispute: list.length - flag };
}

// The one key of an item across both types (a row id and a dispute id may be the same number).
export const itemKey = (i: ReviewItem) => `${i.type}:${i.id}`;

export type ReviewDecision = 'approve' | 'void' | 'reject';

// The decisions an item offers: a flag is approved or voided, a dispute approved or rejected.
export const decisionsOf = (i: ReviewItem): ReviewDecision[] =>
    i.type === 'flag' ? ['approve', 'void'] : ['approve', 'reject'];

// server:review:decide's payload for one item; all = the Admin UI's queue (the reply carries that queue).
export function decidePayload(i: ReviewItem, decision: ReviewDecision, reason: string, all?: boolean) {
    return { type: i.type, id: i.id, decision, reason, ...(all ? { all: true } : {}) };
}

// Admins: the other flagged rows of the same run (Approve all of them at once when there are more than one).
export function runRowsOf(items: ReviewItem[], i: ReviewItem): ReviewItem[] {
    if (i.type !== 'flag') return [];
    return items.filter(x => x.type === 'flag' && x.runUuid === i.runUuid);
}
