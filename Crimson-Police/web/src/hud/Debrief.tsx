// The debrief of a run: the decision ledger (with the facts each decider had) and the people's demeanour and what
// they did. Shared by the result card, the Profile & History breakdown and the dispute review.

import { Icon } from '../shared/components';
import { cx } from '../shared/cx';
import { asArray } from '../shared/data';
import { formatDuration, formatNumber } from '../shared/format';
import { hasKey, t } from '../shared/i18n';
import type { DebriefPerson, DecisionEntry } from '../types/run_ui';

const VERDICT_TONE = { best: 'plus', ok: undefined, wrong: 'minus', critical: 'minus' } as const;

// A locale text when the key exists, else the raw value (ids from blocks that may not be labelled yet).
function labelOr(key: string, raw: string): string {
    return hasKey(key) ? t(key) : raw;
}

function Line({ label, value, tone, fact }: { label: string; value: string; tone?: 'plus' | 'minus'; fact?: boolean }) {
    return (
        <div className={cx('cp-result__line', tone && `is-${tone}`, fact && 'is-note is-fact')}>
            <span className="cp-result__line-label">{label}</span>
            <span className="cp-result__line-value cp-num">{value}</span>
        </div>
    );
}

// detail (disputes): every fact with the time it reached the decider.
export function DecisionsBlock({ decisions, detail }: { decisions: DecisionEntry[]; detail?: boolean }) {
    const list = asArray(decisions);
    if (list.length === 0) return null;
    return (
        <div className="cp-result__block">
            <div className="cp-result__block-head">
                <Icon name="gavel" size={14} />
                <span>{t('result.decisions')}</span>
            </div>
            {list.map((d, i) => {
                // rows from before the fact log have none: nothing is shown for them
                const facts = d.factLog === undefined || d.factLog === null ? null : asArray(d.factLog);
                return (
                    <div key={`d${i}`}>
                        <Line
                            label={t('result.decision', {
                                contact: d.contact,
                                choice: labelOr(`custody.choice.${d.choice}`, d.choice),
                                by: d.by,
                                truth: labelOr(`custody.truth.${d.truth}`, d.truth),
                                verdict: t(`result.verdict.${d.verdict}`),
                            })}
                            value={
                                d.points !== 0
                                    ? formatNumber(d.points, true)
                                    : d.discoverable
                                      ? ''
                                      : t('result.not_discoverable')
                            }
                            tone={VERDICT_TONE[d.verdict]}
                        />
                        {facts === null ? null : facts.length > 0 ? (
                            facts.map((f, j) => (
                                <Line
                                    key={`f${j}`}
                                    label={t('result.fact', { text: f.text })}
                                    value={detail && f.atS !== null && f.atS !== undefined ? formatDuration(f.atS) : ''}
                                    fact
                                />
                            ))
                        ) : (
                            <Line label={t('result.no_facts')} value="" fact />
                        )}
                    </div>
                );
            })}
        </div>
    );
}

export function PeopleBlock({ people }: { people: DebriefPerson[] | null | undefined }) {
    const list = asArray(people ?? undefined);
    if (list.length === 0) return null;
    return (
        <div className="cp-result__block">
            <div className="cp-result__block-head">
                <Icon name="users" size={14} />
                <span>{t('result.people')}</span>
            </div>
            {list.map((p, i) => {
                const did = asArray(p.did);
                return (
                    <Line
                        key={`p${i}`}
                        label={t('result.person', {
                            contact: p.contact,
                            demeanour: p.demeanour ? labelOr(`result.demeanour.${p.demeanour}`, p.demeanour) : '?',
                        })}
                        value={
                            did.length > 0
                                ? did.map(k => labelOr(`result.did.${k}`, k)).join(', ')
                                : t('result.did.none')
                        }
                    />
                );
            })}
        </div>
    );
}
