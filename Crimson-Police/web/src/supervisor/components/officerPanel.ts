// Supervisor UI · Department → Officers: which actions the officer's side panel offers.

// Supervisor UI · Department → Officers · the officer's side panel: which of his actions the viewer may take
// here, each opening its form in the panel (no dialog of its own). Pure functions, checked by
// layouts/supDepartment.walk.ts. Each action is offered on the same terms as before; the server checks every rule
// again (own department, never himself, the caps, the audit row).

import { asList, type OfficerActivity } from '../../types/boards';
import type { FtoDept, FtoView } from '../../types/fieldTraining';

export type OfficerAction = 'points' | 'ban' | 'cooldown' | 'commend' | 'fto';
export const OFFICER_ACTIONS: OfficerAction[] = ['points', 'ban', 'cooldown', 'commend', 'fto'];

// The officer in field training (sup:getFieldTraining): his training as a rookie (also one done), or a trainer the
// viewer can give a rookie (with the rookies he trains now), or a rookie the viewer can pair with a trainer, or
// nothing (field training off, or the viewer may not manage it).
export type FtoRole =
    | { kind: 'rookie'; view: FtoView }
    // done: his finished training, when he trained before (a done rookie may be paired again)
    | { kind: 'candidate'; done?: FtoView }
    | { kind: 'trainer'; rookies: FtoView[] }
    | null;

export function ftoRoleOf(fto: FtoDept | false | null | undefined, citizenid: string | null | undefined): FtoRole {
    if (!fto || !citizenid) return null;
    const pairs = asList(fto.pairs);
    const view = pairs.find(v => v.rookie?.citizenid === citizenid);
    const candidate = asList(fto.candidates).some(o => o.citizenid === citizenid);
    // a rookie whose training is done is a candidate again: pair him again right here (as the Training tab does)
    if (view && view.doneAt && candidate) return { kind: 'candidate', done: view };
    if (view) return { kind: 'rookie', view };
    // a trainer is a candidate too (every officer not in training is): the trainer first
    const rookies = pairs.filter(v => v.trainer?.citizenid === citizenid && !v.doneAt);
    if (rookies.length || asList(fto.trainers).some(o => o.citizenid === citizenid))
        return { kind: 'trainer', rookies };
    if (candidate) return { kind: 'candidate' };
    return null;
}

// The actions the panel offers, in order: Give points (the awardPoints control), Mission ban (or Lift, only the ban
// the viewer may lift), Clear cooldown, Commend (issueCommendation, never himself) and Field training.
export function officerActions(input: {
    activity: OfficerActivity | null | undefined;
    canCommend: boolean;
    self: boolean;
    fto: FtoRole;
}): OfficerAction[] {
    const a = input.activity;
    const out: OfficerAction[] = [];
    if (a?.awardPoints) out.push('points');
    if (a?.missionBan && (!a.missionBanState || a.missionBan.canLift)) out.push('ban');
    if (a?.cooldownClear) out.push('cooldown');
    if (input.canCommend && !input.self) out.push('commend');
    if (input.fto) out.push('fto');
    return out;
}
