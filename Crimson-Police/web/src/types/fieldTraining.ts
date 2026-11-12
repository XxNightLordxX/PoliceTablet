// Shapes of field training (modules/supervisor/fieldtraining.lua, Config.Recognition.fieldTraining).

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
    // the mission types this rookie may take only with his trainer in the unit (labels; his own view)
    needsTrainer?: string[];
}

// fto:getMine (Profile): false when the feature is off or the officer has nothing to show
export interface FtoMine {
    training?: FtoView | null;
    rookies: FtoView[];
    // points the trainer gets per signed task (Config.Recognition.fieldTraining.trainerBonus; 0 = none)
    trainerBonus?: number;
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
