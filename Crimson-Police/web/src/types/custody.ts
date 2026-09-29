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
}

export interface ContactView {
    entries: ContactEntry[];
    probableCause: Record<number, boolean>;
    transport: null | { status: 'coming' | 'parked' | 'leaving'; distance: number | null };
}
