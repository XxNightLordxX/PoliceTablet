// Admin UI · Departments (screen key 'admin_departments'): themes, members, mission desks, personal accents and a
// preview of each officer look.

import { useState, type CSSProperties } from 'react';
import {
    Badge,
    Button,
    Card,
    DeptLogo,
    Dialog,
    EmptyState,
    ErrorState,
    Grid,
    Icon,
    IconButton,
    KeyValue,
    LoadingBlock,
    Money,
    ProgressBar,
    Screen,
    SegmentedControl,
} from '../../shared/components';
import { asArray } from '../../shared/data';
import { formatNumber } from '../../shared/format';
import { useRequest } from '../../shared/hooks';
import { hasKey, t } from '../../shared/i18n';
import { useSession } from '../../shared/session';
import { APPEARANCES, appearanceVars, mergeAppearance, themeVars } from '../../shared/theme';
import type { Theme } from '../../shared/types';
import type { DeskView, TabletAccessView } from '../../types/access';
import type { DepartmentView, DepartmentsData } from '../../types/oversight';
import './Departments.css';
import '../components/access-admin.css';

type Accent = { colour: string; level: number | null };

function appearanceLabel(key: string): string {
    return hasKey(`profile.edit.appearance.${key}`) ? t(`profile.edit.appearance.${key}`) : key;
}

function fmtCoord(n: number): string {
    return (Math.round(n * 100) / 100).toFixed(2);
}

const COLOUR_KEYS: (keyof Theme)[] = ['primary', 'accent', 'background', 'surface', 'text'];

function Swatches({ theme }: { theme: Theme }) {
    return (
        <div className="oversight-dep-swatches">
            {COLOUR_KEYS.map(k => (
                <div key={k} className="oversight-dep-swatch" title={`${t(`admin.depts.colour.${k}`)} ${theme[k]}`}>
                    <span className="oversight-dep-swatch__chip" style={{ background: theme[k] }} />
                    <span className="oversight-dep-swatch__label">{t(`admin.depts.colour.${k}`)}</span>
                    <span className="oversight-dep-swatch__hex">{theme[k]}</span>
                </div>
            ))}
        </div>
    );
}

function ThemePreview({
    dept,
    title,
    appearance = 'department',
    accent = null,
}: {
    dept: DepartmentView;
    title: string;
    appearance?: string;
    accent?: string | null;
}) {
    const look = mergeAppearance(dept.theme, appearance, accent);
    const vars = { ...themeVars(look), ...appearanceVars(appearance) } as CSSProperties;
    return (
        <div
            className="oversight-dep-preview"
            style={vars}
            aria-label={t('admin.depts.preview_title', { name: dept.label })}
        >
            <div className="oversight-dep-preview__header">
                <span className="oversight-dep-preview__logo" data-initials={dept.short.slice(0, 4)}>
                    {dept.logo ? <DeptLogo logo={dept.logo} department={dept.key} size={30} /> : null}
                </span>
                <div className="oversight-dep-preview__titles">
                    <strong>{title}</strong>
                    <span>{t('admin.depts.preview.header_line', { label: dept.label, short: dept.short })}</span>
                </div>
                <Badge size="sm" icon="shield">
                    {t('ui.role.officer')}
                </Badge>
            </div>
            <div className="oversight-dep-preview__body">
                <nav className="oversight-dep-preview__nav">
                    {(['home', 'board', 'leaderboard', 'profile'] as const).map((k, i) => (
                        <span
                            key={k}
                            className={
                                i === 1 ? 'oversight-dep-preview__item is-active' : 'oversight-dep-preview__item'
                            }
                        >
                            {t(`ui.screen.${k}`)}
                        </span>
                    ))}
                </nav>
                <div className="oversight-dep-preview__main">
                    {dept.logo && dept.logo.watermark !== false ? (
                        <div className="oversight-dep-preview__watermark" aria-hidden>
                            <DeptLogo logo={dept.logo} department={dept.key} size={170} />
                        </div>
                    ) : null}
                    <div className="oversight-dep-preview__title">{t('ui.screen.board')}</div>
                    <div className="oversight-dep-preview__card">
                        <div className="oversight-dep-preview__card-head">
                            <strong>{t('admin.depts.preview.card_title')}</strong>
                            <Badge size="sm" tone="accent" variant="solid" icon="star">
                                {t('admin.depts.preview.badge')}
                            </Badge>
                        </div>
                        <p>{t('admin.depts.preview.card_text')}</p>
                        <ProgressBar value={2} max={3} label={t('admin.depts.preview.progress')} showValue />
                        <div className="oversight-dep-preview__buttons">
                            <Button size="sm" variant="primary" icon="check" tabIndex={-1}>
                                {t('admin.depts.preview.primary')}
                            </Button>
                            <Button size="sm" variant="secondary" tabIndex={-1}>
                                {t('admin.depts.preview.secondary')}
                            </Button>
                        </div>
                    </div>
                </div>
            </div>
        </div>
    );
}

// The desks a department may use (departments = null: every department).
function desksFor(access: TabletAccessView | null, dept: string): DeskView[] {
    return asArray(access?.desks).filter(d => !d.departments || asArray(d.departments).includes(dept));
}

function AccentChips({
    accents,
    picked,
    onPick,
}: {
    accents: Accent[];
    picked?: string | null;
    onPick?: (c: string) => void;
}) {
    if (!accents.length) return <span className="oversight-dep-soft">{t('access.depts.no_accents')}</span>;
    return (
        <span className="access-accents">
            {accents.map(a => {
                const chip = (
                    <span
                        className={picked === a.colour ? 'access-accent__chip is-picked' : 'access-accent__chip'}
                        style={{ background: a.colour }}
                    />
                );
                return (
                    <span key={a.colour} className="access-accent" title={a.colour}>
                        {onPick ? (
                            <button type="button" aria-label={a.colour} onClick={() => onPick(a.colour)}>
                                {chip}
                            </button>
                        ) : (
                            chip
                        )}
                        {a.level ? t('access.depts.accent_level', { n: a.level }) : null}
                    </span>
                );
            })}
        </span>
    );
}

function DeskList({ desks }: { desks: DeskView[] }) {
    if (!desks.length) return <span className="oversight-dep-soft">{t('access.depts.no_desks')}</span>;
    return (
        <ul className="access-desks">
            {desks.map(d => (
                <li key={d.index} className="access-desk">
                    <Icon name="building" size={16} />
                    <div className="access-desk__main">
                        <strong>{d.label}</strong>
                        <span className="access-desk__coords">
                            {fmtCoord(d.coords.x)}, {fmtCoord(d.coords.y)}, {fmtCoord(d.coords.z)} ·{' '}
                            {t('access.depts.desk_size', { x: d.size.x, y: d.size.y, r: d.rotation })}
                        </span>
                    </div>
                    {d.departments ? (
                        <Badge size="sm" variant="outline">
                            {t('access.depts.desk_restricted')}
                        </Badge>
                    ) : null}
                    {d.prop ? (
                        <Badge size="sm" icon="eye">
                            {d.prop}
                        </Badge>
                    ) : null}
                </li>
            ))}
        </ul>
    );
}

function DeptCard({
    d,
    showSociety,
    onPreview,
    access,
}: {
    d: DepartmentView;
    showSociety: boolean;
    onPreview: () => void;
    access: TabletAccessView | null;
}) {
    return (
        <Card
            className="oversight-dep-card"
            padding="md"
            footer={
                <div className="oversight-dep-card__footer">
                    <span className="oversight-dep-soft">{t('admin.depts.key', { key: d.key })}</span>
                    <Button size="sm" variant="secondary" icon="eye" onClick={onPreview}>
                        {t('admin.depts.preview')}
                    </Button>
                </div>
            }
        >
            <div className="oversight-dep-card__head">
                {/* The initials show whenever the span is empty: no logo configured, or the image failed to load
            (DeptLogo then renders nothing and reports logoFailed). */}
                <span
                    className="oversight-dep-card__logo"
                    style={{ background: d.theme.primary, color: d.theme.text }}
                    data-initials={d.short.slice(0, 4)}
                >
                    {d.logo ? <DeptLogo logo={d.logo} department={d.key} size={40} alt={d.short} /> : null}
                </span>
                <div className="oversight-dep-card__titles">
                    <strong>{d.label}</strong>
                    <span className="oversight-dep-card__tags">
                        <Badge size="sm" variant="outline">
                            {d.short}
                        </Badge>
                        {!d.logo ? <span className="oversight-dep-soft">{t('admin.depts.no_logo')}</span> : null}
                    </span>
                </div>
            </div>
            <div
                className="oversight-dep-card__strip"
                style={{ background: `linear-gradient(90deg, ${d.theme.primary}, ${d.theme.accent})` }}
                aria-hidden
            />
            <Swatches theme={d.theme} />
            <Grid cols={3} gap={3} className="oversight-dep-card__stats">
                <KeyValue label={t('admin.depts.members')}>
                    <span className="cp-num">{formatNumber(d.members)}</span>
                </KeyValue>
                <KeyValue label={t('admin.depts.on_duty')}>
                    <span className="cp-num oversight-dep-duty">
                        <span className={d.onDuty ? 'oversight-dep-dot is-on' : 'oversight-dep-dot'} />
                        {formatNumber(d.onDuty)}
                    </span>
                </KeyValue>
                <KeyValue label={t('admin.depts.suspended')}>
                    <span className="cp-num">{formatNumber(d.suspended)}</span>
                </KeyValue>
            </Grid>
            {showSociety ? (
                <div className="oversight-dep-society">
                    <span className="oversight-dep-society__icon" aria-hidden>
                        <Icon name="dollar" size={16} />
                    </span>
                    <div className="oversight-dep-society__text">
                        <span className="oversight-dep-card__label">{t('admin.depts.society')}</span>
                        <code>{d.societyAccount}</code>
                    </div>
                    <span className="oversight-dep-society__value">
                        {d.societyBalance === null || d.societyBalance === undefined ? (
                            <span className="oversight-dep-soft">{t('admin.depts.society_unknown')}</span>
                        ) : (
                            <Money amount={d.societyBalance} />
                        )}
                    </span>
                </div>
            ) : null}
            <div className="oversight-dep-card__meta">
                <div>
                    <span className="oversight-dep-card__label">{t('admin.depts.jobs')}</span>
                    <span className="oversight-dep-jobs">
                        {asArray(d.jobs).length ? (
                            asArray(d.jobs).map(j => <code key={j}>{j}</code>)
                        ) : (
                            <span className="oversight-dep-soft">{t('admin.depts.no_jobs')}</span>
                        )}
                    </span>
                </div>
                <div>
                    <span className="oversight-dep-card__label">{t('admin.depts.supervisor_grade')}</span>
                    <span className="cp-num">
                        {d.supervisorGrade >= 1000
                            ? t('admin.depts.no_supervisors')
                            : t('admin.depts.grade', { n: d.supervisorGrade })}
                    </span>
                </div>
            </div>
            {access ? (
                <div className="oversight-dep-card__meta">
                    <div>
                        <span className="oversight-dep-card__label">{t('access.depts.accents')}</span>
                        <AccentChips accents={asArray(access.accents?.[d.key])} />
                    </div>
                    <div>
                        <span className="oversight-dep-card__label">
                            {access.ways.desk ? t('access.depts.desks') : t('access.depts.desks_off')}
                        </span>
                        {access.ways.desk ? <DeskList desks={desksFor(access, d.key)} /> : null}
                    </div>
                </div>
            ) : null}
        </Card>
    );
}

export default function AdminDepartments() {
    const session = useSession();
    const { data, loading, error, refetch } = useRequest<DepartmentsData>('admin:getDepartments', {});
    const [preview, setPreview] = useState<DepartmentView | null>(null);
    const [look, setLook] = useState<string>('department');
    const [accent, setAccent] = useState<string | null>(null);
    const { data: access } = useRequest<TabletAccessView>('admin:getTabletAccess', {});
    const appearances = asArray(access?.appearances).length ? asArray(access?.appearances) : APPEARANCES;
    const openPreview = (d: DepartmentView) => {
        setLook('department');
        setAccent(null);
        setPreview(d);
    };
    const departments = asArray(data?.departments);
    const showSociety = !!data?.showSociety;

    let body;
    if (loading && !data) body = <LoadingBlock />;
    else if (error && !data)
        body = (
            <Card>
                <ErrorState error={error} onRetry={() => void refetch()} />
            </Card>
        );
    else if (!departments.length)
        body = (
            <Card padding="none">
                <EmptyState icon="building" title={t('admin.depts.empty')} />
            </Card>
        );
    else
        body = (
            <Grid min={380} gap={4} align="start">
                {departments.map(d => (
                    <DeptCard
                        key={d.key}
                        d={d}
                        showSociety={showSociety}
                        onPreview={() => openPreview(d)}
                        access={access}
                    />
                ))}
            </Grid>
        );

    return (
        <Screen
            title={t('ui.screen.admin_departments')}
            subtitle={showSociety ? t('admin.depts.subtitle_society') : t('admin.depts.subtitle')}
            actions={
                <IconButton
                    icon="refresh"
                    label={t('sup.refresh')}
                    variant="secondary"
                    loading={loading && !!data}
                    onClick={() => void refetch()}
                />
            }
            className="oversight-screen"
        >
            {!showSociety && data ? (
                <div className="oversight-dep-note">
                    <Icon name="info" size={14} />
                    {t('admin.depts.cash_source_server')}
                </div>
            ) : null}
            {body}
            <Dialog
                open={!!preview}
                onClose={() => setPreview(null)}
                size="lg"
                title={preview ? t('admin.depts.preview_title', { name: preview.label }) : ''}
                description={t('admin.depts.preview_note')}
                footer={
                    <Button variant="primary" onClick={() => setPreview(null)}>
                        {t('common.close')}
                    </Button>
                }
            >
                {preview ? (
                    <>
                        <div className="access-look-bar">
                            <SegmentedControl
                                size="sm"
                                aria-label={t('access.depts.look')}
                                items={appearances.map(a => ({ key: a, label: appearanceLabel(a) }))}
                                value={look}
                                onChange={setLook}
                            />
                            <AccentChips
                                accents={asArray(access?.accents?.[preview.key])}
                                picked={accent}
                                onPick={c => setAccent(prev => (prev === c ? null : c))}
                            />
                        </div>
                        <ThemePreview
                            dept={preview}
                            title={session.title || t('admin.depts.preview.app')}
                            appearance={look}
                            accent={accent}
                        />
                    </>
                ) : null}
            </Dialog>
        </Screen>
    );
}
