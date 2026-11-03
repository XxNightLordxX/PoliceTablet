// The service record of an officer (lifetime or this season), their personal bests and favourite partner. Counted
// from completed runs only; kills are never shown (the own clean-arrest rate is the one exception).

import { useState } from 'react';
import { Card, EmptyState, Icon, SegmentedControl, Stat } from '../../shared/components';
import { formatDuration, formatNumber } from '../../shared/format';
import { t } from '../../shared/i18n';
import type { PersonalBest, ServiceStats } from '../../types/boards';
import { asList } from '../../types/boards';
import './ProfileCards.css';

export interface ServiceRecordCardProps {
    lifetime: ServiceStats | null | undefined;
    season?: ServiceStats | null;
    bests?: PersonalBest[] | null;
    partner?: { name: string; callsign: string | null } | null;
    // own profile only
    cleanArrestRate?: number | null;
    compact?: boolean;
}

function judgement(s: ServiceStats): string {
    const total = s.decisionsOk + s.decisionsBad;
    if (total <= 0) return '–';
    return `${Math.round((s.decisionsBest * 1000) / total) / 10}%`;
}

// "2m 10s average response · 3 rapid responses" (either part only when it has a value).
function callsHint(s: ServiceStats): string | undefined {
    const parts: string[] = [];
    if (s.avgResponseS !== null && s.avgResponseS !== undefined) {
        parts.push(t('profile.service.response', { time: formatDuration(s.avgResponseS) }));
    }
    if (s.rapidResponses) parts.push(t('profile.service.rapid', { n: s.rapidResponses }));
    return parts.length ? parts.join(' · ') : undefined;
}

export function ServiceRecordCard({
    lifetime,
    season,
    bests,
    partner,
    cleanArrestRate,
    compact,
}: ServiceRecordCardProps) {
    const [scope, setScope] = useState<'lifetime' | 'season'>('lifetime');
    const stats = scope === 'season' && season ? season : lifetime;
    const bestList = asList(bests ?? undefined);
    return (
        <Card
            title={t('profile.service.title')}
            icon="barChart"
            padding="md"
            className="profile-service"
            actions={
                season ? (
                    <SegmentedControl
                        size="sm"
                        items={[
                            { key: 'lifetime' as const, label: t('profile.service.lifetime') },
                            { key: 'season' as const, label: t('profile.service.season') },
                        ]}
                        value={scope}
                        onChange={setScope}
                        aria-label={t('profile.service.title')}
                    />
                ) : undefined
            }
        >
            {!stats ? (
                <EmptyState compact icon="barChart" title={t('profile.service.none')} />
            ) : (
                <>
                    <div className={compact ? 'profile-service__grid is-compact' : 'profile-service__grid'}>
                        <Stat
                            size="sm"
                            label={t('profile.service.completed')}
                            value={formatNumber(stats.completed)}
                            hint={t('profile.service.success', { rate: stats.successRate })}
                        />
                        <Stat size="sm" label={t('profile.service.arrests')} value={formatNumber(stats.arrests)} />
                        <Stat size="sm" label={t('profile.service.citations')} value={formatNumber(stats.citations)} />
                        <Stat size="sm" label={t('profile.service.impounds')} value={formatNumber(stats.impounds)} />
                        <Stat
                            size="sm"
                            label={t('profile.service.vehicles')}
                            value={formatNumber(stats.vehiclesStopped)}
                        />
                        <Stat size="sm" label={t('profile.service.rescues')} value={formatNumber(stats.rescues)} />
                        <Stat size="sm" label={t('profile.service.evidence')} value={formatNumber(stats.evidence)} />
                        <Stat
                            size="sm"
                            label={t('profile.service.judgement')}
                            value={judgement(stats)}
                            hint={t('profile.service.decisions', {
                                best: stats.decisionsBest,
                                ok: stats.decisionsOk,
                                total: stats.decisionsOk + stats.decisionsBad,
                            })}
                        />
                        <Stat
                            size="sm"
                            label={t('profile.service.calls')}
                            value={formatNumber(stats.calls)}
                            hint={callsHint(stats)}
                        />
                        <Stat
                            size="sm"
                            label={t('profile.service.medals')}
                            value={`${stats.medals.gold} · ${stats.medals.silver} · ${stats.medals.bronze}`}
                            hint={t('profile.service.medals_hint')}
                        />
                        {cleanArrestRate !== null && cleanArrestRate !== undefined ? (
                            <Stat
                                size="sm"
                                label={t('profile.service.clean')}
                                value={`${cleanArrestRate}%`}
                                hint={t('profile.service.clean_hint')}
                            />
                        ) : null}
                    </div>
                    {partner ? (
                        <p className="profile-service__line">
                            <Icon name="users" size={14} />
                            {t('profile.service.partner', { name: partner.name })}
                            {partner.callsign && partner.callsign !== partner.name ? ` · ${partner.callsign}` : ''}
                        </p>
                    ) : null}
                    {bestList.length ? (
                        <div className="profile-service__bests">
                            <span className="profile-service__label">{t('profile.service.bests')}</span>
                            <ul>
                                {bestList.slice(0, compact ? 5 : 12).map(b => (
                                    <li key={b.missionId ?? b.missionLabel}>
                                        <span className="profile-service__mission" title={b.missionLabel}>
                                            {b.missionLabel}
                                        </span>
                                        <span className="cp-num">{formatDuration(b.durationS)}</span>
                                    </li>
                                ))}
                            </ul>
                        </div>
                    ) : null}
                </>
            )}
        </Card>
    );
}

export default ServiceRecordCard;
