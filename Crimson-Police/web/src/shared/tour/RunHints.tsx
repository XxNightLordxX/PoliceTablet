// The tips of the first mission run (Config.Training: autoStart.run, hintSeconds): a small card at the top of the

// The tips of the first mission run (Config.Training: autoStart.run, hintSeconds): a small card at the top of the
// HUD column, one tip at a time, each once its part of the run is on screen (the HUD, its objectives, its GPS line,
// the result card) and that part outlined. There is no NUI focus during a run, so a tip takes no click and no key:
// it closes by itself after hintSeconds and the game keeps playing. Saved per character like the tours, once the
// result card's tip showed (or every tip did).

import { useEffect, useMemo, useRef } from 'react';
import { t } from '../i18n';
import { request } from '../nui';
import type { HudState } from '../types';
import { hintCond, hintsFinished, hintsToShow, nextHint } from './runHints';
import {
    finishHints,
    hintShown,
    normalizeTraining,
    setTrainingView,
    takeHintsAgain,
    tourState,
    useTourState,
} from './store';
import { stepBodyKey, stepTitleKey } from './tours';

const GLOW = 'cp-hint-glow';

export function RunHints({ hud, result }: { hud: HudState | null; result: boolean }) {
    const { view, hintsAgain, hints } = useTourState();
    const active = !!hud || result;

    // a run before the tablet ever opened: read the training view once
    const asked = useRef(false);
    useEffect(() => {
        if (!active || view || asked.current) return;
        asked.current = true;
        void request('training:get', {}).then(res => {
            if (res.ok && !tourState().view) setTrainingView(normalizeTraining(res.data));
        });
    }, [active, view]);

    useEffect(() => {
        if (hintsAgain && active) takeHintsAgain();
    }, [hintsAgain, active]);

    const steps = useMemo(() => hintsToShow(view, hints.again), [view, hints.again]);
    const shown = useMemo(() => new Set(hints.shown), [hints.shown]);
    const step = nextHint(steps, shown, hintCond(hud, result));
    const id = step?.id ?? null;
    const seconds = view?.hintSeconds ?? 12;

    // each tip shows for hintSeconds; one whose part went away (the tablet opened over the HUD) shows again later
    useEffect(() => {
        if (!id) return;
        const timer = setTimeout(() => hintShown(id), seconds * 1000);
        return () => clearTimeout(timer);
    }, [id, seconds]);

    // finished: saved once, and no tip shows again until asked for
    useEffect(() => {
        if (hintsFinished(steps, shown)) finishHints();
    }, [steps, shown]);

    // the part of the run the tip is about, outlined while it shows
    const target = step?.target ?? null;
    useEffect(() => {
        if (!target) return;
        const el = document.querySelector<HTMLElement>(`[data-tour="${target}"]`);
        el?.classList.add(GLOW);
        return () => el?.classList.remove(GLOW);
    }, [target, hud?.runId, result]);

    if (!step) return null;
    return (
        <div className="cp-hint" role="status" aria-live="polite">
            <div className="cp-tour__count">{t('tour.ui.step', { n: steps.indexOf(step) + 1, of: steps.length })}</div>
            <strong className="cp-hint__title">{t(stepTitleKey('run', step))}</strong>
            <p className="cp-hint__body">{t(stepBodyKey('run', step))}</p>
            <p className="cp-hint__auto">{t('tour.ui.hint_auto')}</p>
        </div>
    );
}
