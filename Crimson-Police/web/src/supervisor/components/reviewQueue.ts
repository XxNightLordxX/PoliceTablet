// The one Review queue (review:getQueue): flagged runs and disputes in one list with a type column. Pure helpers of
// supervisor/components/ReviewQueuePanel.tsx (the Supervisor UI's Department -> Review and the Admin UI's Review ->
// Queue); walk: reviewQueue.walk.ts.

import type { ReviewBatchItem, ReviewItem, ReviewItemType, RunHistoryEvent } from '../../types/oversight';

type AnyItem = ReviewItem | ReviewBatchItem;

// What the queue shows: every item, or one type (batch: the admin's correction batches).
export type ReviewShow = 'all' | ReviewItemType | 'batch';
export const REVIEW_SHOWS: ReviewShow[] = ['all', 'flag', 'dispute', 'batch'];

export function showOf(v: unknown): ReviewShow {
    return v === 'flag' || v === 'dispute' || v === 'batch' ? v : 'all';
}

const isBatch = (i: AnyItem): i is ReviewBatchItem => i.type === 'batch';

// The flagged runs and disputes the queue's table shows (All: both; a batch filter: none).
export function itemsOf(items: AnyItem[] | null | undefined, show: ReviewShow): ReviewItem[] {
    const list = (Array.isArray(items) ? items : []).filter((i): i is ReviewItem => !isBatch(i));
    if (show === 'batch') return [];
    return show === 'all' ? list : list.filter(i => i.type === show);
}

// The correction batches the queue shows under the table (All or the batch filter).
export function batchesOf(items: AnyItem[] | null | undefined, show: ReviewShow): ReviewBatchItem[] {
    if (show !== 'all' && show !== 'batch') return [];
    return (Array.isArray(items) ? items : []).filter(isBatch);
}

export function countsOf(items: AnyItem[] | null | undefined): Record<ReviewShow, number> {
    const list = Array.isArray(items) ? items : [];
    const flag = list.filter(i => i.type === 'flag').length;
    const batch = list.filter(isBatch).length;
    return { all: list.length, flag, dispute: list.length - flag - batch, batch };
}

// server:review:decide's Undo: a run voided here (type flag, id = its row id) or a correction batch (type batch).
export function undoPayload(type: 'flag' | 'batch', id: number | string, reason: string) {
    return { type, id, decision: 'undo', reason, all: true };
}

// One history line's locale key: a decision by its audit action, the other kinds by kind and action.
export function historyKey(e: RunHistoryEvent): string {
    if (e.kind === 'decision') return `sup.history.action.${e.action}`;
    if (e.kind === 'row') return 'sup.history.row';
    if (e.kind === 'batch') return 'sup.history.batch';
    return `sup.history.${e.kind}`;
}

// The one key of an item across the types (a row id and a dispute id may be the same number).
export const itemKey = (i: AnyItem) => `${i.type}:${i.id}`;

export type ReviewDecision = 'approve' | 'void' | 'reject';

// The decisions an item offers: a flag is approved or voided, a dispute approved or rejected.
export const decisionsOf = (i: ReviewItem): ReviewDecision[] =>
    i.type === 'flag' ? ['approve', 'void'] : ['approve', 'reject'];

// server:review:decide's payload for one item; all = the Admin UI's queue (the reply carries that queue).
export function decidePayload(i: ReviewItem, decision: ReviewDecision, reason: string, all?: boolean) {
    return { type: i.type, id: i.id, decision, reason, ...(all ? { all: true } : {}) };
}

// Admins: the other flagged rows of the same run (Approve all of them at once when there are more than one).
export function runRowsOf(items: AnyItem[], i: ReviewItem): ReviewItem[] {
    if (i.type !== 'flag') return [];
    return items.filter((x): x is ReviewItem => x.type === 'flag' && x.runUuid === i.runUuid);
}
