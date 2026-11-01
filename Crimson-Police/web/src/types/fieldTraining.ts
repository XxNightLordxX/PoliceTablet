// Shapes of field training (modules/fieldtraining, step T1, Config.FieldTraining).

export interface FtoTask {
    type: string;
    label: string;
    need: number;
    runs: number;
    // the count is reached and nobody signed it off yet
    ready: boolean;
    signed?: { by: string; at: number; note?: string } | null;
}

export interface FtoView {
    rookie: { citizenid: string; name: string };
    trainer: { citizenid: string; name: string };
    department?: string;
    pairedAt?: number;
    pairedBy?: string;
    doneAt?: number | null;
    signed: number;
    total: number;
    tasks: FtoTask[];
}

// fto:getMine (Profile): false when the feature is off or the officer has nothing to show
export interface FtoMine {
    training?: FtoView | null;
    rookies: FtoView[];
}

export interface FtoOfficer {
    citizenid: string;
    name: string;
    callsign?: string | null;
    rank?: string | null;
}

// sup:getFieldTraining (Department Report): false when the feature is off
export interface FtoDept {
    department: string;
    departmentLabel: string;
    trainerGrade: number;
    rookiesPerTrainer: number;
    tasks: { type: string; label: string; need: number }[];
    pairs: FtoView[];
    candidates: FtoOfficer[];
    trainers: FtoOfficer[];
}
