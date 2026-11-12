// Runs the guided tours (Config.Training) over whichever tablet is open: it reads the player's training view when a

// Runs the guided tours (Config.Training) over whichever tablet is open: it reads the player's training view when a
// tablet opens, starts that tablet's tour by itself the first time (autoTourFor), runs a tour asked for (askTour,
// the 'tour' message of /crimsonhelp), opens each step's screen, rings the element the step points at and shows its
// card (Back, Next, Skip, Don't show again). The ring and the dim around it never take a click: the real tablet
// stays usable under it, and Escape always ends the tour. Arrow keys move between steps.

import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { Button } from '../components';
import { useEscapeLayer, useViewport } from '../hooks';
import { t } from '../i18n';
import { useNavigation } from '../navigation';
import { request, useNuiEvent } from '../nui';
import { useOptionalSession } from '../session';
import { deptTabsFor } from '../../layouts/supDepartment';
import type { CrimScreen } from '../../types/criminal';
import { placeCard, type Box } from './place';
import {
    autoTourFor,
    askTour,
    beginRun,
    endRun,
    moveRun,
    normalizeTraining,
    setTrainingView,
    takeAsked,
    useTourState,
} from './store';
import { TOURS, stepBodyKey, stepTitleKey, stepsToShow, type TourCtx, type TourId, type TourTablet } from './tours';
import './tour.css';

const FIND_MS = 200; // how often the element of the step is looked for (only while a tour runs)
const PAD = 4; // px of ring around the element

function sameBox(a: Box | null, b: Box | null): boolean {
    if (!a || !b) return a === b;
    return (
        Math.abs(a.left - b.left) < 1 &&
        Math.abs(a.top - b.top) < 1 &&
        Math.abs(a.width - b.width) < 1 &&
        Math.abs(a.height - b.height) < 1
    );
}

function typing(e: KeyboardEvent): boolean {
    const el = e.target as HTMLElement | null;
    if (!el) return false;
    const tag = el.tagName;
    return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || el.isContentEditable === true;
}

export function TourHost({
    tablet,
    onCrimScreen,
}: {
    // the tablet open now (null: none)
    tablet: TourTablet | null;
    // the criminal tablet's screen switch
    onCrimScreen?: (screen: CrimScreen) => void;
}) {
    const { view, run, asked } = useTourState();
    const session = useOptionalSession();
    const nav = useNavigation();
    const { width, height } = useViewport();
    const autoTried = useRef<TourTablet | null>(null);

    // /crimsonhelp: the client opened the tablet (or will) and names the tour
    useNuiEvent('tour', m => {
        if (typeof m.tour === 'string' && m.tour in TOURS) askTour(m.tour as TourId);
    });

    // a tablet opened: read the training view once for this open
    useEffect(() => {
        if (!tablet) {
            autoTried.current = null;
            return;
        }
        let gone = false;
        void request('training:get', {}).then(res => {
            if (gone) return;
            if (res.ok) setTrainingView(normalizeTraining(res.data));
        });
        return () => {
            gone = true;
        };
    }, [tablet]);

    const ctx: TourCtx = useMemo(
        () => ({
            session,
            screens: tablet && tablet !== 'criminal' ? nav.available : [],
            deptTabs: tablet === 'supervisor' ? deptTabsFor(session) : [],
            checklist: view?.checklist !== false,
        }),
        [session, tablet, nav.available, view?.checklist],
    );

    // start a tour: an asked one from the start, else this tablet's own the first time
    useEffect(() => {
        if (!tablet || !view || run) return;
        if (!view.enabled) return;
        const wanted = takeAsked(tablet);
        if (wanted) {
            beginRun(
                wanted,
                stepsToShow(TOURS[wanted], 0, true, ctx).map(s => s.id),
            );
            return;
        }
        if (autoTried.current === tablet) return;
        autoTried.current = tablet;
        const auto = autoTourFor(tablet, view);
        if (auto)
            beginRun(
                auto,
                stepsToShow(TOURS[auto], view.seen[auto] ?? 0, false, ctx).map(s => s.id),
            );
    }, [tablet, view, run, asked, ctx]);

    // the tablet closed or another one opened: the tour ends (it starts again next time)
    useEffect(() => {
        if (run && TOURS[run.tour].tablet !== tablet) endRun(false);
    }, [run, tablet]);

    const def = run ? TOURS[run.tour] : null;
    const step = def && run ? (def.steps.find(s => s.id === run.steps[run.index]) ?? null) : null;
    const stepKey = run && step ? `${run.tour}:${run.index}:${step.id}` : '';
    const last = !!run && run.index >= run.steps.length - 1;

    // each step opens its screen first
    const navRef = useRef(nav);
    navRef.current = nav;
    useEffect(() => {
        if (!step) return;
        if (step.crim && onCrimScreen) onCrimScreen(step.crim);
        const want = step.screen;
        if (!want) return;
        const n = navRef.current;
        const params = want.params ?? {};
        if (n.screen === want.key && JSON.stringify(n.params ?? {}) === JSON.stringify(params)) return;
        if (n.available.includes(want.key)) n.navigate(want.key, params);
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [stepKey]);

    // the element of the step: looked for while the step shows (it may appear once its screen has loaded)
    const [box, setBox] = useState<Box | null>(null);
    useEffect(() => {
        setBox(null);
        if (!step?.target) return;
        const selector = `[data-tour="${step.target}"]`;
        let scrolled = false;
        const find = () => {
            const el = document.querySelector<HTMLElement>(selector);
            const r = el?.getBoundingClientRect();
            const next =
                r && r.width > 0 && r.height > 0
                    ? { left: r.left, top: r.top, width: r.width, height: r.height }
                    : null;
            if (el && next && !scrolled) {
                scrolled = true;
                el.scrollIntoView?.({ block: 'nearest', inline: 'nearest' });
            }
            setBox(prev => (sameBox(prev, next) ? prev : next));
        };
        find();
        const id = setInterval(find, FIND_MS);
        return () => clearInterval(id);
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [stepKey]);

    const next = () => (last ? endRun(true) : moveRun(1));

    // a step that waits for the click moves on once the element is clicked
    useEffect(() => {
        if (!step?.target || step.waitFor !== 'click') return;
        const selector = `[data-tour="${step.target}"]`;
        const onClick = (e: MouseEvent) => {
            const el = e.target as Element | null;
            if (el && el.closest(selector)) setTimeout(() => (last ? endRun(true) : moveRun(1)), 0);
        };
        document.addEventListener('click', onClick, true);
        return () => document.removeEventListener('click', onClick, true);
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [stepKey]);

    // Escape ends the tour first (before any dialog under it or the tablet); arrows move between steps
    useEscapeLayer(!!run, () => endRun(false));
    useEffect(() => {
        if (!run) return;
        const onKey = (e: KeyboardEvent) => {
            if (typing(e)) return;
            if (e.key === 'ArrowRight') {
                e.preventDefault();
                if (last) endRun(true);
                else moveRun(1);
            } else if (e.key === 'ArrowLeft') {
                e.preventDefault();
                moveRun(-1);
            }
        };
        window.addEventListener('keydown', onKey);
        return () => window.removeEventListener('keydown', onKey);
    }, [run, last]);

    // the card: measured, then placed next to the element
    const card = useRef<HTMLDivElement>(null);
    const nextBtn = useRef<HTMLButtonElement>(null);
    const [size, setSize] = useState({ width: 340, height: 180 });
    useLayoutEffect(() => {
        const el = card.current;
        if (!el) return;
        const s = { width: el.offsetWidth, height: el.offsetHeight };
        setSize(prev => (prev.width === s.width && prev.height === s.height ? prev : s));
    });
    useEffect(() => {
        if (stepKey) nextBtn.current?.focus({ preventScroll: true });
    }, [stepKey]);

    if (!run || !step || !def || TOURS[run.tour].tablet !== tablet) return null;
    const ring = box
        ? { left: box.left - PAD, top: box.top - PAD, width: box.width + PAD * 2, height: box.height + PAD * 2 }
        : null;
    const at = placeCard(ring, size, { width, height });
    const allowSkip = view?.allowSkip !== false;

    return createPortal(
        <div className="cp-tour" aria-live="polite">
            {ring ? <div className="cp-tour__ring" style={ring} aria-hidden /> : null}
            <div
                ref={card}
                className={`cp-tour__card is-${at.side}`}
                role="dialog"
                aria-label={t(stepTitleKey(run.tour, step))}
                style={{ left: at.left, top: at.top }}
            >
                <div className="cp-tour__count">{t('tour.ui.step', { n: run.index + 1, of: run.steps.length })}</div>
                <h3 className="cp-tour__title">{t(stepTitleKey(run.tour, step))}</h3>
                <p className="cp-tour__body">{t(stepBodyKey(run.tour, step))}</p>
                {step.waitFor === 'click' && box ? <p className="cp-tour__hint">{t('tour.ui.click_hint')}</p> : null}
                <div className="cp-tour__actions">
                    {allowSkip ? (
                        <>
                            <Button size="sm" variant="ghost" onClick={() => endRun(false)}>
                                {t('tour.ui.skip')}
                            </Button>
                            <Button size="sm" variant="ghost" onClick={() => endRun(true)}>
                                {t('tour.ui.never')}
                            </Button>
                        </>
                    ) : null}
                    <span className="cp-tour__spacer" />
                    <Button size="sm" variant="secondary" disabled={run.index === 0} onClick={() => moveRun(-1)}>
                        {t('tour.ui.back')}
                    </Button>
                    <Button ref={nextBtn} size="sm" variant="primary" onClick={next}>
                        {last ? t('tour.ui.done') : t('tour.ui.next')}
                    </Button>
                </div>
            </div>
        </div>,
        document.body,
    );
}
