// The criminal tablet: a burner-phone style tablet for players who play real suspects, nothing like the

// The criminal tablet: a burner-phone style tablet for players who play real suspects, nothing like the
// police tablet. Home (volunteer on or off), Jobs (the question he has open), Active (the suspect he plays), History
// (past cases and strikes) and Rules. Every button goes through server:crimtab:act; the server checks everything and
// answers the fresh view. Built from the shared components like the police tablets, in the dark street theme
// (.cp-theme-street, styles/base.css); only the frame, the header and the side tabs are its own.

import { useState } from 'react';
import {
    Badge,
    Button,
    Card,
    Checkbox,
    ConfirmButton,
    EmptyState,
    Grid,
    Icon,
    type IconName,
    KeyValue,
    Row,
    Screen,
    Table,
    type TableColumn,
} from '../shared/components';
import { formatDateTime, formatDuration } from '../shared/format';
import { useCountdown, useViewport } from '../shared/hooks';
import { t, tOr } from '../shared/i18n';
import { TABLET_H, TABLET_W, tabletScale } from '../layouts/TabletFrame';
import { action, fetchNui } from '../shared/nui';
import { toast } from '../shared/toast';
import type { CrimActive, CrimHistoryRow, CrimJob, CrimRole, CrimScreen, CrimView } from '../types/criminal';
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
                className="crim-frame cp-theme-street"
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
                                    {badge ? (
                                        <Badge tone="danger" variant="solid" size="sm" className="crim-tab__badge">
                                            {badge}
                                        </Badge>
                                    ) : null}
                                </button>
                            );
                        })}
                    </nav>
                    <main className="crim-main">
                        <Screen head={`crim_${screen}`}>
                            {!view.volunteersOn ? <p className="crim-warn">{t('crimtab.volunteers_off')}</p> : null}
                            {screen === 'home' ? (
                                <Home key={String(view.status.listed)} view={view} busy={busy} run={run} />
                            ) : null}
                            {screen === 'jobs' ? <Jobs view={view} busy={busy} run={run} onScreen={onScreen} /> : null}
                            {screen === 'active' ? <Active active={view.active ?? null} busy={busy} run={run} /> : null}
                            {screen === 'history' ? <History view={view} /> : null}
                            {screen === 'rules' ? <Rules view={view} /> : null}
                        </Screen>
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
        <Row gap={2} wrap className="crim-roles">
            {all.map(r => (
                <Checkbox
                    key={r}
                    checked={!!picked[r]}
                    onChange={on => onChange({ ...picked, [r]: on })}
                    label={roleLabel(r)}
                />
            ))}
        </Row>
    );
}

function Home({ view, busy, run }: { view: CrimView; busy: boolean; run: Run }) {
    const s = view.status;
    const start: Record<string, boolean> = {};
    for (const r of s.listed ? s.roles : s.allRoles) start[r] = true;
    const [picked, setPicked] = useState<Record<string, boolean>>(start);
    const [agreed, setAgreed] = useState(false);
    const roles = rolesPayload(picked);

    if (s.listed) {
        return (
            <Card title={t('crimtab.home.listed_title')} highlight="primary">
                <p className="crim-big">
                    {t('crimtab.home.minutes_left', { minutes: minutesLeft(s.untilAt, view.now) })}
                </p>
                <p className="crim-muted">{t('crimtab.home.roles_hint')}</p>
                <RolePicker all={s.allRoles} picked={picked} onChange={setPicked} />
                <Row gap={2} wrap className="crim-actions">
                    <Button disabled={busy || roles.length === 0} onClick={() => void run({ what: 'roles', roles })}>
                        {t('crimtab.home.save_roles')}
                    </Button>
                    <Button disabled={busy} onClick={() => void run({ what: 'renew' })}>
                        {t('crimtab.home.renew', { minutes: view.rules.windowMinutes })}
                    </Button>
                    <ConfirmButton
                        disabled={busy}
                        label={t('crimtab.home.stop')}
                        confirmLabel={t('crimtab.confirm')}
                        onConfirm={() => void run({ what: 'stop' })}
                    />
                </Row>
            </Card>
        );
    }
    const blocked = hoursLeft(s.blockedUntil, view.now);
    return (
        <Card title={t('crimtab.home.off_title')} highlight="primary">
            <p>{t('crimtab.home.off_text', { minutes: view.rules.windowMinutes })}</p>
            {blocked > 0 ? <p className="crim-warn">{t('crimtab.home.blocked', { hours: blocked })}</p> : null}
            {!s.canJoin && s.why && blocked === 0 ? (
                <p className="crim-warn">{tOr(`volunteer.refused.${s.why}`, 'volunteer.refused.other')}</p>
            ) : null}
            <RolePicker all={s.allRoles} picked={picked} onChange={setPicked} />
            <Checkbox
                className="crim-agree"
                checked={agreed}
                onChange={setAgreed}
                label={t('crimtab.home.agree', { strikes: view.rules.strikes })}
            />
            <Row gap={2} wrap className="crim-actions">
                <Button
                    variant="primary"
                    disabled={busy || !s.canJoin || !agreed || roles.length === 0}
                    onClick={() => void run({ what: 'join', roles })}
                >
                    {t('crimtab.home.join', { minutes: view.rules.windowMinutes })}
                </Button>
            </Row>
        </Card>
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
        <Card
            title={roleLabel(job.role)}
            highlight="primary"
            actions={<span className="crim-timer">{formatDuration(left ?? 0)}</span>}
        >
            <Grid cols={2} gap={3} className="crim-facts">
                <KeyValue label={t('crimtab.jobs.type')}>{job.missionType || t('crimtab.unknown')}</KeyValue>
                <KeyValue label={t('crimtab.jobs.area')}>{job.area || t('crimtab.unknown')}</KeyValue>
                <KeyValue label={t('crimtab.jobs.distance')}>
                    {typeof job.km === 'number' ? t('crimtab.jobs.km', { km: job.km }) : t('crimtab.jobs.near')}
                </KeyValue>
                <KeyValue label={t('crimtab.jobs.travel')}>
                    {t('crimtab.jobs.minutes', { minutes: job.travelMinutes })}
                </KeyValue>
                <KeyValue label={t('crimtab.jobs.reward')}>{job.reward || t('crimtab.jobs.no_reward')}</KeyValue>
            </Grid>
            <p className="crim-muted">{t('crimtab.jobs.consent')}</p>
            <Row gap={2} wrap className="crim-actions">
                <Button variant="primary" disabled={busy || left === 0} onClick={() => void answer(true)}>
                    {t('crimtab.jobs.accept')}
                </Button>
                <Button disabled={busy || left === 0} onClick={() => void answer(false)}>
                    {t('crimtab.jobs.decline')}
                </Button>
            </Row>
        </Card>
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
            <Card>
                <EmptyState
                    icon="inbox"
                    title={t('crimtab.jobs.empty_title')}
                    text={view.status.listed ? t('crimtab.jobs.empty_listed') : t('crimtab.jobs.empty_off')}
                />
            </Card>
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
    // the free Give up runs out on its own: no event refetches the view then
    const graceLeft = useCountdown(active?.graceLeft ?? null, { resetKey: active?.phase });
    if (!active) {
        return (
            <Card>
                <EmptyState icon="target" title={t('crimtab.active.empty_title')} text={t('crimtab.active.empty')} />
            </Card>
        );
    }
    return (
        <Card title={roleLabel(active.role)} highlight="primary">
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
            <Row gap={2} wrap className="crim-actions">
                <ConfirmButton
                    disabled={busy}
                    label={t('crimtab.active.give_up')}
                    confirmLabel={t('crimtab.confirm')}
                    onConfirm={() => void run({ what: 'cancel' })}
                />
            </Row>
        </Card>
    );
}

// The past cases, newest first (the server's order).
function historyColumns(): TableColumn<CrimHistoryRow>[] {
    return [
        { key: 'endedAt', header: t('crimtab.history.col.when'), render: h => formatDateTime(h.endedAt) },
        {
            key: 'missionType',
            header: t('crimtab.history.col.type'),
            render: h => h.missionType || t('crimtab.unknown'),
        },
        { key: 'role', header: t('crimtab.history.col.role'), render: h => roleLabel(h.role) },
        {
            key: 'outcome',
            header: t('crimtab.history.col.outcome'),
            render: h => <span className={h.dropout ? 'crim-bad' : undefined}>{t(outcomeKey(h))}</span>,
        },
    ];
}

function History({ view }: { view: CrimView }) {
    const blocked = hoursLeft(view.status.blockedUntil, view.now);
    return (
        <>
            <Card
                title={t('crimtab.history.strikes', { count: view.strikes.length, max: view.rules.strikes })}
                highlight="primary"
            >
                {view.strikes.length === 0 ? <p className="crim-muted">{t('crimtab.history.no_strikes')}</p> : null}
                <ul className="crim-list">
                    {view.strikes.map((at, i) => (
                        <li key={`${at}-${i}`}>{t('crimtab.history.strike_until', { when: formatDateTime(at) })}</li>
                    ))}
                </ul>
                {blocked > 0 ? <p className="crim-warn">{t('crimtab.home.blocked', { hours: blocked })}</p> : null}
            </Card>
            <Card title={t('crimtab.history.cases')} highlight="primary" footer={t('crimtab.history.note')}>
                <Table
                    dense
                    columns={historyColumns()}
                    rows={view.history}
                    rowKey={(h, i) => `${h.endedAt}-${i}`}
                    empty={t('crimtab.history.empty')}
                    aria-label={t('crimtab.history.cases')}
                />
            </Card>
        </>
    );
}

function Rules({ view }: { view: CrimView }) {
    const r = view.rules;
    return (
        <Card title={t('crimtab.rules.title')} highlight="primary">
            <ul className="crim-list">
                <li>{t('crimtab.rules.window', { minutes: r.windowMinutes })}</li>
                <li>{t('crimtab.rules.ask', { seconds: r.askSeconds })}</li>
                <li>{t('crimtab.rules.travel', { minutes: r.travelMinutes })}</li>
                <li>{t('crimtab.rules.cancel', { seconds: r.cancelGraceSeconds })}</li>
                <li>{t('crimtab.rules.strikes', { strikes: r.strikes, hours: r.strikeHours, block: r.blockHours })}</li>
                <li>{t('crimtab.rules.police')}</li>
                <li>{t('crimtab.rules.server')}</li>
            </ul>
        </Card>
    );
}
