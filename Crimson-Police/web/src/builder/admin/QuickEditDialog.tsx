// Quick edit of a built-in mission (MissionTweaks): cooldown, time limit, start timeout and the NPC models, cars and
// weapons, without JSON. Saved through Settings (checked again there, audited as a settings change). Runs already
// going keep their definition.

import { useEffect, useState } from 'react';
import {
    Badge,
    Button,
    Checkbox,
    Dialog,
    EmptyState,
    Field,
    Icon,
    LoadingBlock,
    NumberInput,
    TextInput,
    Toggle,
} from '../../shared/components';
import { formatDuration } from '../../shared/format';
import { useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { useAdminAction } from '../../admin/components/kit';
import type { MissionTweak, MissionTweakView } from '../../types/admin_missions';

type NumKey = 'cooldown' | 'timeLimit' | 'startTimeout';
type ListKey = 'peds' | 'vehicles' | 'weapons';
const NUM_KEYS: NumKey[] = ['cooldown', 'timeLimit', 'startTimeout'];
const LIST_KEYS: ListKey[] = ['peds', 'vehicles', 'weapons'];
const COOLDOWN_WARN = 300;

export function QuickEditDialog({
    missionId,
    label,
    onClose,
    onSaved,
}: {
    missionId: string | null;
    label: string;
    onClose: () => void;
    onSaved: () => void;
}) {
    const view = useRequest<MissionTweakView>('admin:getMissionTweak', { missionId }, { skip: !missionId });
    const { run, busy } = useAdminAction();
    const [nums, setNums] = useState<Partial<Record<NumKey, number | null>>>({});
    const [lists, setLists] = useState<Partial<Record<ListKey, string[] | null>>>({});
    const [reason, setReason] = useState('');
    const v = view.data;

    useEffect(() => {
        if (!v) return;
        const tw = v.tweak ?? {};
        setNums({
            cooldown: tw.cooldown ?? null,
            timeLimit: tw.timeLimit ?? null,
            startTimeout: tw.startTimeout ?? null,
        });
        setLists({ peds: tw.peds ?? null, vehicles: tw.vehicles ?? null, weapons: tw.weapons ?? null });
        setReason('');
    }, [v]);

    const tweak = (): MissionTweak | null => {
        const out: MissionTweak = {};
        NUM_KEYS.forEach(k => {
            const n = nums[k];
            if (typeof n === 'number') out[k] = n;
        });
        LIST_KEYS.forEach(k => {
            const l = lists[k];
            if (l && l.length) out[k] = l;
        });
        return Object.keys(out).length ? out : null;
    };

    const save = async (reset: boolean) => {
        if (!missionId) return;
        const next = reset ? null : tweak();
        const payload: Record<string, unknown> = { missionId, reason: reason.trim() || undefined };
        if (next) payload.tweak = next;
        const res = await run('server:admin:setMissionTweak', payload, {
            success: reset || !next ? 'admin.missions.quick.reset_done' : 'admin.missions.quick.saved',
            successVars: { mission: label },
        });
        if (res.ok) {
            onSaved();
            onClose();
        }
    };

    const cooldown = nums.cooldown ?? v?.file.cooldown ?? null;
    return (
        <Dialog
            open={!!missionId}
            onClose={onClose}
            size="lg"
            title={t('admin.missions.quick.title', { mission: label })}
            description={t('admin.missions.quick.text')}
            footer={
                <>
                    <Button variant="ghost" icon="undo" disabled={busy || !v?.tweak} onClick={() => void save(true)}>
                        {t('admin.missions.quick.reset')}
                    </Button>
                    <span className="cp-spacer" />
                    <Button variant="ghost" onClick={onClose}>
                        {t('common.cancel')}
                    </Button>
                    <Button variant="primary" icon="check" disabled={busy || !v} onClick={() => void save(false)}>
                        {t('admin.missions.quick.save')}
                    </Button>
                </>
            }
        >
            {view.loading && !v ? (
                <LoadingBlock />
            ) : !v ? (
                <EmptyState compact icon="alert" title={t(view.error ?? 'err.internal')} />
            ) : (
                <div className="admin-missions-stack">
                    {v.overridden ? (
                        <div className="builder_client-inline-note">
                            <Icon name="info" size={15} />
                            <span>{t('admin.missions.quick.on_override')}</span>
                        </div>
                    ) : null}
                    <div className="admin-missions-grid3">
                        {NUM_KEYS.map(k => (
                            <Field
                                key={k}
                                label={t(`admin.missions.quick.${k}`)}
                                hint={t('admin.missions.quick.file_live', {
                                    file: formatDuration(v.file[k] ?? 0),
                                    live: formatDuration(v.live[k] ?? 0),
                                })}
                            >
                                <NumberInput
                                    value={nums[k] ?? null}
                                    onChange={n => setNums(s => ({ ...s, [k]: n }))}
                                    min={v.ranges[k]?.[0]}
                                    max={v.ranges[k]?.[1]}
                                    suffix="s"
                                    placeholder={String(v.file[k] ?? '')}
                                />
                            </Field>
                        ))}
                    </div>
                    {typeof cooldown === 'number' && cooldown < COOLDOWN_WARN ? (
                        <div className="builder_client-callout builder_client-callout--warning">
                            <Icon name="alert" size={15} />
                            <span>{t('admin.missions.quick.cooldown_warn', { seconds: COOLDOWN_WARN })}</span>
                        </div>
                    ) : null}
                    {LIST_KEYS.map(k => {
                        const allowed = v.allowed[k] ?? [];
                        const objectives = v.objectives.filter(o => Array.isArray(o[k]) && (o[k] as string[]).length);
                        if (!objectives.length) return null;
                        const chosen = lists[k];
                        return (
                            <div key={k} className="admin-missions-picker">
                                <div className="admin-missions-picker__head">
                                    <b>{t(`admin.missions.quick.${k}`)}</b>
                                    <Toggle
                                        checked={chosen !== null && chosen !== undefined}
                                        label={t('admin.missions.quick.replace')}
                                        onChange={on =>
                                            setLists(s => ({ ...s, [k]: on ? (objectives[0][k] ?? []) : null }))
                                        }
                                    />
                                </div>
                                <div className="admin-missions-muted">
                                    {t('admin.missions.quick.changes', {
                                        list: objectives.map(o => `#${o.index} ${o.label ?? o.block}`).join(', '),
                                    })}
                                </div>
                                {chosen ? (
                                    <div className="admin-missions-chips">
                                        {allowed.map(name => (
                                            <Checkbox
                                                key={name}
                                                checked={chosen.includes(name)}
                                                label={name}
                                                onChange={on =>
                                                    setLists(s => {
                                                        const cur = s[k] ?? [];
                                                        return {
                                                            ...s,
                                                            [k]: on ? [...cur, name] : cur.filter(x => x !== name),
                                                        };
                                                    })
                                                }
                                            />
                                        ))}
                                    </div>
                                ) : (
                                    <div className="admin-missions-chips">
                                        {(objectives[0][k] ?? []).map(name => (
                                            <Badge key={name} size="sm" tone="neutral" variant="outline">
                                                {name}
                                            </Badge>
                                        ))}
                                    </div>
                                )}
                            </div>
                        );
                    })}
                    <Field label={t('admin.missions.quick.reason')}>
                        <TextInput value={reason} onChange={setReason} maxLength={255} />
                    </Field>
                    <div className="admin-missions-muted">{t('admin.missions.quick.runs_keep')}</div>
                </div>
            )}
        </Dialog>
    );
}
