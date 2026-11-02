// The criminal tablet: a burner-phone style tablet for players who play real suspects, nothing like the

// The criminal tablet: a burner-phone style tablet for players who play real suspects, nothing like the
// police tablet. Home (volunteer on or off), Jobs (the question he has open), Active (the suspect he plays), History
// (past cases and strikes) and Rules. Every button goes through server:crimtab:act; the server checks everything and
// answers the fresh view.

import { useState } from 'react';
import { Icon, type IconName } from '../shared/components/Icon';
import { formatDateTime, formatDuration } from '../shared/format';
import { useCountdown, useViewport } from '../shared/hooks';
import { t, tOr } from '../shared/i18n';
import { TABLET_H, TABLET_W, tabletScale } from '../layouts/TabletFrame';
import { action, fetchNui } from '../shared/nui';
import { toast } from '../shared/toast';
import type { CrimActive, CrimJob, CrimRole, CrimScreen, CrimView } from '../types/criminal';
import { badgeOf, CRIM_SCREENS, hoursLeft, minutesLeft, normalizeCrimView, outcomeKey, rolesPayload } from './model';
import './criminal.css';

const ICONS: Record<CrimScreen, IconName> = {
    home: 'home',
    jobs: 'inbox',
    active: 'target',
    history: 'list',
    rules: 'info',
};

export interface CriminalTabletProps {
    view: CrimView;
    screen: CrimScreen;
    onScreen: (s: CrimScreen) => void;
    onView: (v: CrimView) => void;
    onClose: () => void;
}

// One action, then the fresh view (or the refusal as a toast).
async function act(payload: Record<string, unknown>, onView: (v: CrimView) => void): Promise<boolean> {
    const res = await action<CrimView>('server:crimtab:act', payload);
    if (!res.ok) {
        toast('error', t(res.error || 'err.internal'));
        return false;
    }
    const v = normalizeCrimView(res.data);
    if (v) onView(v);
    return true;
}

function roleLabel(role: string | null | undefined): string {
    return t(`crimtab.role.${role ?? 'runner'}`);
}

export function CriminalTablet({ view, screen, onScreen, onView, onClose }: CriminalTabletProps) {
    const [busy, setBusy] = useState(false);
    const run = async (payload: Record<string, unknown>) => {
        if (busy) return false;
        setBusy(true);
        const ok = await act(payload, onView);
        setBusy(false);
        return ok;
    };

    const { width, height } = useViewport();
    const scale = tabletScale(width, height);

    return (
        <div className="crim-backdrop">
            <div
                className="crim-frame"
                role="dialog"
                aria-label={t('crimtab.title')}
                style={{ width: TABLET_W, height: TABLET_H, transform: `scale(${scale})` }}
            >
                <header className="crim-header">
                    <span className="crim-brand">{t('crimtab.title')}</span>
                    <span className="crim-signal">
                        {view.status.listed ? t('crimtab.header.on') : t('crimtab.header.off')}
                    </span>
                    <button className="crim-close" onClick={onClose} aria-label={t('crimtab.close')}>
                        <Icon name="x" size={18} />
                    </button>
                </header>
                <div className="crim-body">
                    <nav className="crim-nav">
                        {CRIM_SCREENS.map(s => {
                            const badge = badgeOf(view, s);
                            return (
                                <button
                                    key={s}
                                    className={`crim-tab${s === screen ? ' is-on' : ''}`}
                                    onClick={() => onScreen(s)}
                                >
                                    <Icon name={ICONS[s]} size={16} />
                                    <span>{t(`crimtab.screen.${s}`)}</span>
                                    {badge ? <em className="crim-badge">{badge}</em> : null}
                                </button>
                            );
                        })}
                    </nav>
                    <main className="crim-main">
                        {!view.volunteersOn ? <p className="crim-warn">{t('crimtab.volunteers_off')}</p> : null}
                        {screen === 'home' ? (
                            <Home key={String(view.status.listed)} view={view} busy={busy} run={run} />
                        ) : null}
                        {screen === 'jobs' ? <Jobs view={view} busy={busy} run={run} onScreen={onScreen} /> : null}
                        {screen === 'active' ? <Active active={view.active ?? null} busy={busy} run={run} /> : null}
                        {screen === 'history' ? <History view={view} /> : null}
                        {screen === 'rules' ? <Rules view={view} /> : null}
                    </main>
                </div>
            </div>
        </div>
    );
}

type Run = (payload: Record<string, unknown>) => Promise<boolean>;

function RolePicker({
    all,
    picked,
    onChange,
}: {
    all: CrimRole[];
    picked: Record<string, boolean>;
    onChange: (p: Record<string, boolean>) => void;
}) {
    return (
        <div className="crim-roles">
            {all.map(r => (
                <label key={r} className={`crim-role${picked[r] ? ' is-on' : ''}`}>
                    <input
                        type="checkbox"
                        checked={!!picked[r]}
                        onChange={e => onChange({ ...picked, [r]: e.target.checked })}
                    />
                    <span>{roleLabel(r)}</span>
                </label>
            ))}
        </div>
    );
}

function Home({ view, busy, run }: { view: CrimView; busy: boolean; run: Run }) {
    const s = view.status;
    const start: Record<string, boolean> = {};
    for (const r of s.listed ? s.roles : s.allRoles) start[r] = true;
    const [picked, setPicked] = useState<Record<string, boolean>>(start);
    const [agreed, setAgreed] = useState(false);
    const [confirmStop, setConfirmStop] = useState(false);
    const roles = rolesPayload(picked);

    if (s.listed) {
        return (
            <section className="crim-card">
                <h2>{t('crimtab.home.listed_title')}</h2>
                <p className="crim-big">
                    {t('crimtab.home.minutes_left', { minutes: minutesLeft(s.untilAt, view.now) })}
                </p>
                <p className="crim-muted">{t('crimtab.home.roles_hint')}</p>
                <RolePicker all={s.allRoles} picked={picked} onChange={setPicked} />
                <div className="crim-actions">
                    <button
                        className="crim-btn"
                        disabled={busy || roles.length === 0}
                        onClick={() => void run({ what: 'roles', roles })}
                    >
                        {t('crimtab.home.save_roles')}
                    </button>
                    <button className="crim-btn" disabled={busy} onClick={() => void run({ what: 'renew' })}>
                        {t('crimtab.home.renew', { minutes: view.rules.windowMinutes })}
                    </button>
                    <button
                        className="crim-btn is-danger"
                        disabled={busy}
                        onClick={() => {
                            if (!confirmStop) {
                                setConfirmStop(true);
                                setTimeout(() => setConfirmStop(false), 3000);
                                return;
                            }
                            setConfirmStop(false);
                            void run({ what: 'stop' });
                        }}
                    >
                        {confirmStop ? t('crimtab.confirm') : t('crimtab.home.stop')}
                    </button>
                </div>
            </section>
        );
    }
    const blocked = hoursLeft(s.blockedUntil, view.now);
    return (
        <section className="crim-card">
            <h2>{t('crimtab.home.off_title')}</h2>
            <p>{t('crimtab.home.off_text', { minutes: view.rules.windowMinutes })}</p>
            {blocked > 0 ? <p className="crim-warn">{t('crimtab.home.blocked', { hours: blocked })}</p> : null}
            {!s.canJoin && s.why && blocked === 0 ? (
                <p className="crim-warn">{tOr(`volunteer.refused.${s.why}`, 'volunteer.refused.other')}</p>
            ) : null}
            <RolePicker all={s.allRoles} picked={picked} onChange={setPicked} />
            <label className="crim-agree">
                <input type="checkbox" checked={agreed} onChange={e => setAgreed(e.target.checked)} />
                <span>{t('crimtab.home.agree', { strikes: view.rules.strikes })}</span>
            </label>
            <div className="crim-actions">
                <button
                    className="crim-btn is-primary"
                    disabled={busy || !s.canJoin || !agreed || roles.length === 0}
                    onClick={() => void run({ what: 'join', roles })}
                >
                    {t('crimtab.home.join', { minutes: view.rules.windowMinutes })}
                </button>
            </div>
        </section>
    );
}

function JobCard({
    job,
    busy,
    run,
    onScreen,
}: {
    job: CrimJob;
    busy: boolean;
    run: Run;
    onScreen: (s: CrimScreen) => void;
}) {
    const left = useCountdown(job.seconds, { resetKey: job.token });
    const answer = async (yes: boolean) => {
        const ok = await run({ what: 'answer', token: job.token, yes });
        void fetchNui('crimtabAnswered', { token: job.token });
        if (ok && yes) onScreen('active');
    };
    return (
        <article className="crim-card crim-job">
            <header>
                <h2>{roleLabel(job.role)}</h2>
                <span className="crim-timer">{formatDuration(left ?? 0)}</span>
            </header>
            <dl className="crim-facts">
                <dt>{t('crimtab.jobs.type')}</dt>
                <dd>{job.missionType || t('crimtab.unknown')}</dd>
                <dt>{t('crimtab.jobs.area')}</dt>
                <dd>{job.area || t('crimtab.unknown')}</dd>
                <dt>{t('crimtab.jobs.distance')}</dt>
                <dd>{typeof job.km === 'number' ? t('crimtab.jobs.km', { km: job.km }) : t('crimtab.jobs.near')}</dd>
                <dt>{t('crimtab.jobs.travel')}</dt>
                <dd>{t('crimtab.jobs.minutes', { minutes: job.travelMinutes })}</dd>
                <dt>{t('crimtab.jobs.reward')}</dt>
                <dd>{job.reward || t('crimtab.jobs.no_reward')}</dd>
            </dl>
            <p className="crim-muted">{t('crimtab.jobs.consent')}</p>
            <div className="crim-actions">
                <button className="crim-btn is-primary" disabled={busy || left === 0} onClick={() => void answer(true)}>
                    {t('crimtab.jobs.accept')}
                </button>
                <button className="crim-btn" disabled={busy || left === 0} onClick={() => void answer(false)}>
                    {t('crimtab.jobs.decline')}
                </button>
            </div>
        </article>
    );
}

function Jobs({
    view,
    busy,
    run,
    onScreen,
}: {
    view: CrimView;
    busy: boolean;
    run: Run;
    onScreen: (s: CrimScreen) => void;
}) {
    if (view.jobs.length === 0) {
        return (
            <section className="crim-card crim-empty">
                <h2>{t('crimtab.jobs.empty_title')}</h2>
                <p>{view.status.listed ? t('crimtab.jobs.empty_listed') : t('crimtab.jobs.empty_off')}</p>
            </section>
        );
    }
    return (
        <>
            {view.jobs.map(j => (
                <JobCard key={j.token} job={j} busy={busy} run={run} onScreen={onScreen} />
            ))}
        </>
    );
}

function Active({ active, busy, run }: { active: CrimActive | null; busy: boolean; run: Run }) {
    const left = useCountdown(active?.seconds ?? null, { resetKey: active?.phase });
    // the free Give up runs out on its own: no event refetches the view then (step Z2)
    const graceLeft = useCountdown(active?.graceLeft ?? null, { resetKey: active?.phase });
    const [confirm, setConfirm] = useState(false);
    if (!active) {
        return (
            <section className="crim-card crim-empty">
                <h2>{t('crimtab.active.empty_title')}</h2>
                <p>{t('crimtab.active.empty')}</p>
            </section>
        );
    }
    return (
        <section className="crim-card">
            <h2>{roleLabel(active.role)}</h2>
            <p className="crim-big">{t(`crimtab.phase.${active.phase}`)}</p>
            {active.phase === 'travel' && left !== null ? (
                <p className="crim-timer">{t('crimtab.active.time_left', { time: formatDuration(left) })}</p>
            ) : null}
            {active.meet ? (
                <p className="crim-muted">
                    {t('crimtab.active.meet', { x: Math.round(active.meet.x), y: Math.round(active.meet.y) })}
                </p>
            ) : null}
            <ul className="crim-list">
                <li>{t('crimtab.active.rule_stay')}</li>
                <li>{t('crimtab.active.rule_force')}</li>
                <li>{t('crimtab.active.rule_log')}</li>
            </ul>
            <p className="crim-muted">
                {active.freeCancel && (graceLeft === null || graceLeft > 0)
                    ? t('crimtab.active.cancel_free')
                    : t('crimtab.active.cancel_strike')}
            </p>
            <div className="crim-actions">
                <button
                    className="crim-btn is-danger"
                    disabled={busy}
                    onClick={() => {
                        if (!confirm) {
                            setConfirm(true);
                            setTimeout(() => setConfirm(false), 3000);
                            return;
                        }
                        setConfirm(false);
                        void run({ what: 'cancel' });
                    }}
                >
                    {confirm ? t('crimtab.confirm') : t('crimtab.active.give_up')}
                </button>
            </div>
        </section>
    );
}

function History({ view }: { view: CrimView }) {
    return (
        <>
            <section className="crim-card">
                <h2>{t('crimtab.history.strikes', { count: view.strikes.length, max: view.rules.strikes })}</h2>
                {view.strikes.length === 0 ? <p className="crim-muted">{t('crimtab.history.no_strikes')}</p> : null}
                <ul className="crim-list">
                    {view.strikes.map((at, i) => (
                        <li key={`${at}-${i}`}>{t('crimtab.history.strike_until', { when: formatDateTime(at) })}</li>
                    ))}
                </ul>
                {hoursLeft(view.status.blockedUntil, view.now) > 0 ? (
                    <p className="crim-warn">
                        {t('crimtab.home.blocked', { hours: hoursLeft(view.status.blockedUntil, view.now) })}
                    </p>
                ) : null}
            </section>
            <section className="crim-card">
                <h2>{t('crimtab.history.cases')}</h2>
                {view.history.length === 0 ? <p className="crim-muted">{t('crimtab.history.empty')}</p> : null}
                <table className="crim-table">
                    <tbody>
                        {view.history.map((h, i) => (
                            <tr key={`${h.endedAt}-${i}`}>
                                <td>{formatDateTime(h.endedAt)}</td>
                                <td>{h.missionType || t('crimtab.unknown')}</td>
                                <td>{roleLabel(h.role)}</td>
                                <td className={h.dropout ? 'is-bad' : ''}>{t(outcomeKey(h))}</td>
                            </tr>
                        ))}
                    </tbody>
                </table>
                <p className="crim-muted">{t('crimtab.history.note')}</p>
            </section>
        </>
    );
}

function Rules({ view }: { view: CrimView }) {
    const r = view.rules;
    return (
        <section className="crim-card">
            <h2>{t('crimtab.rules.title')}</h2>
            <ul className="crim-list">
                <li>{t('crimtab.rules.window', { minutes: r.windowMinutes })}</li>
                <li>{t('crimtab.rules.ask', { seconds: r.askSeconds })}</li>
                <li>{t('crimtab.rules.travel', { minutes: r.travelMinutes })}</li>
                <li>{t('crimtab.rules.cancel', { seconds: r.cancelGraceSeconds })}</li>
                <li>{t('crimtab.rules.strikes', { strikes: r.strikes, hours: r.strikeHours, block: r.blockHours })}</li>
                <li>{t('crimtab.rules.police')}</li>
                <li>{t('crimtab.rules.server')}</li>
            </ul>
        </section>
    );
}
