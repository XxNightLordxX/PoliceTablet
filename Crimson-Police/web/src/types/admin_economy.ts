// Full admin control, economy: Admin UI → Payments, Departments → Funds, the clean-up (docs/dev/ARCHITECTURE.md §9.5,
// "Admin control: economy"). Every amount here is the server's; the NUI never sends one it computed itself.

export type CashStatus = 'held' | 'pending' | 'paying' | 'paid' | 'capped' | 'unfunded' | 'forfeited';

// One row of the payments ledger (admin:getPayments).
export interface PaymentRow {
    id: number;
    runUuid: string;
    citizenid: string;
    name?: string | null;
    missionId: string;
    missionLabel: string;
    missionType: string;
    // a manual cash payment (mission_id manual_cash)
    manual: boolean;
    department: string;
    status: CashStatus;
    // what the run earned, what was paid, what an admin took back
    owed: number;
    paid: number;
    reclaimed: number;
    // capped rows: the part the daily cap cut (0 once the rest was paid)
    cut: number;
    // CP-<run_uuid>-<citizenid>
    txn: string;
    account?: string | null;
    source?: 'server' | 'society' | null;
    // the step markers of the last payment attempt: claimed → (withdrawing →) withdrawn → adding → added; review: a
    // money call raised and the balance did not tell whether it moved
    step?: 'claimed' | 'withdrawing' | 'withdrawn' | 'adding' | 'added' | 'review' | null;
    // the capped rest: 'paying' (claimed) or 'paid'
    restPaid?: string | null;
    // Pay again: 'paying' (claimed) or 'paid'
    again?: string | null;
    // an admin money tool left part way on a paid or capped row: Resolve
    followUp?: FollowUpKind | null;
    voided: boolean;
    flagged: boolean;
    // the officer's payment is running right now
    busy: boolean;
    createdAt: number;
}

// The money tools that ship off (Settings, typed ENABLE).
export interface PaymentSwitches {
    payAgain: boolean;
    unfundedRetry: boolean;
    capTopUp: boolean;
    restoreForfeited: boolean;
    clawback: boolean;
    manualCash: boolean;
    addFunds: boolean;
}

// admin:getPayments { status, department, missionType, citizenid, from, to, page, size }
export interface PaymentsView {
    rows: PaymentRow[];
    page: number;
    pages: number;
    total: number;
    size: number;
    switches: PaymentSwitches;
    source: 'server' | 'society';
    maxPayout: number;
    manualDailyLimit: number;
    // seconds until the next forfeiture check (held cash of voided runs)
    nextForfeitIn?: number | null;
    // a maintenance lock holds payments back (its kind)
    held?: string | null;
    serverTime: number;
    // the totals, asked for with withTotals (one request per screen open)
    totals?: PaymentTotals | null;
}

export interface PaymentFilter {
    status?: string;
    department?: string;
    missionType?: string;
    citizenid?: string;
    from?: number;
    to?: number;
    page?: number;
    size?: number;
}

export interface StatusTotal {
    count: number;
    paid: number;
    reclaimed: number;
    owed: number;
}

export interface DepartmentTotal {
    department: string;
    count: number;
    paid: number;
    reclaimed: number;
    unfunded: number;
    // share of everything paid in the filter, in %
    share: number;
}

// admin:getPaymentTotals { department, from, to }
export interface PaymentTotals {
    byStatus: Record<CashStatus, StatusTotal>;
    departments: DepartmentTotal[];
    paidTotal: number;
    cut: number;
    cappedToday: number;
    // more rows than the owed totals read: those are a lower bound
    partial: boolean;
}

// admin:exportPayments
export interface PaymentsExport {
    csv: string;
    rows: number;
    truncated: boolean;
}

// One side of Renewed-Banking's history: only the entry with this transaction id.
export interface BankingEntry {
    found: boolean;
    amount?: number;
    type?: 'deposit' | 'withdraw';
    time?: number;
}

// admin:checkBankingTxn { rowId }
// What an admin money tool left part way on a paid or capped row: the rest of a capped payment, a clawback, or the
// give-back of a clawback to the department.
export type FollowUpKind = 'rest' | 'back' | 'giveBack';
export type FollowUpOutcome =
    'restPaid' | 'restRelease' | 'restWithdrawn' | 'backTaken' | 'backUndone' | 'giveBack' | 'giveBackDone';

export interface BankingCheck {
    id: number;
    status: CashStatus;
    txn: string;
    amount: number;
    step?: string | null;
    source?: string | null;
    account?: string | null;
    societyAccount?: string | null;
    personal?: BankingEntry | null;
    society?: BankingEntry | null;
    busy: boolean;
    online: boolean;
    payAgain: boolean;
    // A follow-up instead of a stuck payment: its kind, amount, step, and the outcomes it offers now
    followUp?: FollowUpKind | null;
    followUpAmount?: number | null;
    followUpStep?: string | null;
    outcomes?: Partial<Record<FollowUpOutcome, boolean>> | null;
    // A Pay again left at its own 'withdrawing', 'refunding' or 'withdrawn' step: that step, and the Release and Mark
    // withdrawn it offers (Pay again on)
    againStep?: string | null;
    againOutcomes?: { againRelease?: boolean; againWithdrawn?: boolean } | null;
    // What a Release gives the department back now (Pay again at 'withdrawn', the rest after its department
    // withdrawal): the confirm then asks for that amount typed
    releaseRefund?: number | null;
}

// admin:previewRetryUnfunded { rowId } | { department, since }
export interface UnfundedPreview {
    previewToken: string;
    expiresAt: number;
    effect: {
        count: number;
        total: number;
        departments: { department: string; label: string; owed: number; balance?: number | null }[];
        rows: PaymentRow[];
        // rows of the admin's own characters or runs, left out
        excluded?: number;
    };
}

// admin:getDepartmentFunds { department }
export interface DepartmentFundsView {
    department: string;
    label: string;
    account: string;
    enabled: boolean;
    source: 'server' | 'society';
    // null: the account was not found in Renewed-Banking
    balance?: number | null;
    lowBalanceWarn: number;
    spent: { today: number; week: number; season?: number | null };
    unfunded: number;
    funded: number;
    recent: {
        id: number;
        amount: number;
        txn?: string | null;
        state: string;
        by: string;
        reason?: string | null;
        at: number;
    }[];
    allowAddFunds: boolean;
    addFundsMax: number;
}

// admin:previewCashSource: before Cash.source changes (Settings).
export interface CashSourcePreview {
    source: 'server' | 'society';
    departments: {
        department: string;
        label: string;
        account: string;
        balance?: number | null;
        rows: number;
        owed: number;
        short?: boolean | null;
    }[];
}

// admin:previewPayoutAdjust { mode, value, scope }
export interface PayoutAdjustRow {
    key: string;
    kind: 'type' | 'mission';
    id: string;
    label: string;
    old: number;
    new: number;
    locked?: boolean;
}

export interface PayoutAdjustPreview {
    previewToken: string;
    expiresAt: number;
    effect: { rows: PayoutAdjustRow[]; total: number };
}
