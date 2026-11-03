// Shapes of the Contact panel (ActiveMissionView.contact, built by CP.Custody.view for a field_contact objective).

// A fact about a contact that a validated police action revealed. suppressed: found by an unlawful search (shown
// struck through, never graded); cause: it gives probable cause for a vehicle search.
export interface ContactFact {
    key: string;
    text: string;
    by: string | null;
    at: number;
    suppressed: boolean;
    cause: boolean;
}

// A person or car of the contact. tellSeen is a tell a participant already saw, never derived from the hidden
// demeanour; notChecked lists the checks still open ('id' | 'plate' | 'frisk' | 'inside' | 'search').
export interface ContactEntry {
    netId: number;
    label: string;
    kind: 'person' | 'vehicle';
    role: string;
    state: string;
    tellSeen: string | null;
    freeToLeave: boolean;
    notChecked: string[];
    facts: ContactFact[];
    actions: string[];
    choices: { id: string; label: string; failsCase: boolean }[];
    offences: { id: string; label: string }[];
    decided: null | { choice: string; by: string };
    // An ox_target choice of this viewer waiting for the case-fail confirm (client:contactConfirm).
    confirm?: null | { choice: string };
}

export interface ContactView {
    entries: ContactEntry[];
    probableCause: Record<number, boolean>;
    transport: null | { status: 'coming' | 'parked' | 'leaving'; distance: number | null };
}

// Payload of server:contactDecide and its reply: { ok } when decided, { confirm } when the choice would fail the
// case and confirmed was not set.
export interface ContactDecidePayload {
    runId: string;
    netId: number;
    choice: string;
    offence?: string;
    confirmed?: boolean;
}
export interface ContactDecideResult {
    ok?: boolean;
    confirm?: { factKey: string | null };
}

// Push topic 'contactConfirm' (client:contactConfirm): an ox_target choice that would fail the case.
export interface ContactConfirm {
    netId: number;
    choice: string;
    factKey: string | null;
}

// Payload of the client action contactAction (the Contact panel's action buttons).
export interface ContactActionPayload {
    netId: number;
    action: string;
}

// HudState.contact (HUD patch 'contact', false to clear): the newest fact, a tell hint, a confirm waiting.
export interface HudContact {
    label: string;
    fact?: string | false | null;
    hint?: string | false | null;
    confirm?: string | false | null;
    suppressed?: boolean;
}
