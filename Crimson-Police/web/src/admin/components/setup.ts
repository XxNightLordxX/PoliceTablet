// Admin UI -> Home's First-start setup (admin/components/SetupWizard): the steps, the answers it starts from (what the
// server runs with now) and the one server:admin:finishSetup payload, which names only what the admin changed. Each
// answer the server saves is an ordinary setting (modules/admin/setup), so it stays editable in Settings later.

import type { SetupDepartment, SetupJob, SetupJobGrade, SetupView } from '../../types/admin_system';

export type SetupStep = 'departments' | 'desks' | 'storage' | 'scripts' | 'preset';
export const SETUP_STEPS: SetupStep[] = ['departments', 'desks', 'storage', 'scripts', 'preset'];

export interface DeptAnswer {
    jobs: string[];
    supervisorGrade: number;
    enabled: boolean;
}
export interface SetupAnswers {
    departments: Record<string, DeptAnswer>;
    // Qbox police jobs no department lists yet that get a department of their own
    add: string[];
    // the desk indexes kept
    desks: number[];
    integrations: Record<string, string>;
    // '' = no preset
    preset: string;
}

// The answers as the server runs now: nothing would change.
export function initialAnswers(view: SetupView | null | undefined): SetupAnswers {
    const departments: Record<string, DeptAnswer> = {};
    for (const d of view?.departments ?? []) {
        departments[d.key] = { jobs: [...d.jobs], supervisorGrade: d.supervisorGrade, enabled: d.enabled };
    }
    const integrations: Record<string, string> = {};
    for (const i of view?.integrations ?? []) integrations[i.kind] = i.setting;
    return {
        departments,
        add: [],
        desks: (view?.desks ?? []).map(d => d.index),
        integrations,
        preset: '',
    };
}

// The Qbox police jobs no department lists: each can become a department of its own.
export function unclaimedJobs(view: SetupView | null | undefined): SetupJob[] {
    return (view?.jobs ?? []).filter(j => j.police && !j.department);
}

// The grades a department's supervisor grade may be picked from: every grade of its jobs, once, lowest first.
export function gradeChoices(view: SetupView | null | undefined, jobs: string[]): SetupJobGrade[] {
    const byLevel = new Map<number, SetupJobGrade>();
    for (const j of view?.jobs ?? []) {
        if (!jobs.includes(j.name)) continue;
        for (const g of j.grades) if (!byLevel.has(g.level)) byLevel.set(g.level, g);
    }
    return [...byLevel.values()].sort((a, b) => a.level - b.level);
}

function sameList(a: string[], b: string[]): boolean {
    return a.length === b.length && a.every((v, i) => v === b[i]);
}

function deptChanged(d: SetupDepartment, a: DeptAnswer | undefined): boolean {
    if (!a) return false;
    return !sameList(a.jobs, d.jobs) || a.supervisorGrade !== d.supervisorGrade || a.enabled !== d.enabled;
}

// The server:admin:finishSetup payload: only the departments, desks and scripts the admin changed, the new
// departments and the preset ('' = none). A department left with no job is not sent (the server needs one).
export function finishPayload(view: SetupView | null | undefined, answers: SetupAnswers): Record<string, unknown> {
    const departments: Record<string, DeptAnswer> = {};
    for (const d of view?.departments ?? []) {
        const a = answers.departments[d.key];
        if (a && a.jobs.length > 0 && deptChanged(d, a)) departments[d.key] = a;
    }
    const out: Record<string, unknown> = {};
    if (Object.keys(departments).length > 0) out.departments = departments;
    if (answers.add.length > 0) out.add = [...answers.add];
    const allDesks = (view?.desks ?? []).map(d => d.index);
    if (!sameList(answers.desks.map(String), allDesks.map(String))) out.desks = [...answers.desks];
    const integrations: Record<string, string> = {};
    for (const i of view?.integrations ?? []) {
        const v = answers.integrations[i.kind];
        if (v && v !== i.setting) integrations[i.kind] = v;
    }
    if (Object.keys(integrations).length > 0) out.integrations = integrations;
    if (answers.preset) out.preset = answers.preset;
    return out;
}

// How many things a finish would change (the Finish step's summary): departments, new departments, desks, scripts,
// and the preset as one.
export function changeCount(view: SetupView | null | undefined, answers: SetupAnswers): number {
    const p = finishPayload(view, answers);
    const n = (o: unknown) => (o && typeof o === 'object' ? Object.keys(o).length : 0);
    return n(p.departments) + n(p.add) + (p.desks ? 1 : 0) + n(p.integrations) + (p.preset ? 1 : 0);
}

// What a script setting means now: the script serving it, or why none does (a locale key and its vars).
export function scriptLine(i: { setting: string; active?: string | null; why?: string | null }): {
    key: string;
    vars: Record<string, string>;
} {
    if (i.active) return { key: 'admin.setup.script_active', vars: { name: i.active } };
    if (i.why === 'off' || i.setting === 'none') return { key: 'admin.setup.script_off', vars: {} };
    return { key: 'admin.setup.script_missing', vars: { setting: i.setting } };
}
