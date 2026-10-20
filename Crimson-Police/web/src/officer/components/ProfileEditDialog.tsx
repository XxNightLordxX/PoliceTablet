// Officer UI · Edit profile: picture (initials, presets, an approved link), bio, look (appearance, accent, tablet
// size) and call alerts. Callback getProfileEdit, action server:profile:set.

import { useEffect, useMemo, useState } from 'react';
import {
    Avatar,
    Badge,
    Button,
    Dialog,
    Field,
    Icon,
    LoadingBlock,
    Select,
    SegmentedControl,
    Tabs,
    TextInput,
    Textarea,
    Toggle,
    ErrorState,
} from '../../shared/components';
import { AVATAR_PRESETS } from '../../shared/components/Avatar';
import { cx } from '../../shared/cx';
import { formatDuration } from '../../shared/format';
import { useAction, useRequest } from '../../shared/hooks';
import { hasKey, t } from '../../shared/i18n';
import { useSession } from '../../shared/session';
import { toast } from '../../shared/toast';
import type { Avatar as AvatarData } from '../../shared/types';
import type { ProfileEdit, ProfileSetPayload } from '../../types/profile';
import './ProfileCards.css';

type Tab = 'picture' | 'bio' | 'look';

export interface ProfileEditDialogProps {
    open: boolean;
    onClose: () => void;
    // called after a successful save (the Profile screen refetches)
    onSaved?: () => void;
}

function appearanceLabel(key: string): string {
    return hasKey(`profile.edit.appearance.${key}`) ? t(`profile.edit.appearance.${key}`) : key;
}

export function ProfileEditDialog({ open, onClose, onSaved }: ProfileEditDialogProps) {
    const session = useSession();
    const cfg = session.config?.profile;
    const { data, loading, error, refetch } = useRequest<ProfileEdit>('getProfileEdit', {}, { skip: !open });
    const { run, busy } = useAction();
    const [tab, setTab] = useState<Tab>('picture');
    const [kind, setKind] = useState<AvatarData['kind']>('initials');
    const [preset, setPreset] = useState<string>('');
    const [url, setUrl] = useState<string>('');
    const [bio, setBio] = useState<string>('');
    const [appearance, setAppearance] = useState<string>('department');
    const [accent, setAccent] = useState<string>('');
    const [scale, setScale] = useState<number>(1);
    const [muted, setMuted] = useState<boolean>(false);

    useEffect(() => {
        if (!data) return;
        setKind(data.avatar.kind);
        setPreset(data.avatar.kind === 'preset' ? (data.avatar.value ?? '') : '');
        setUrl(data.pending?.status === 'pending' ? data.pending.value : '');
        setBio(data.bioPending ?? data.bio ?? '');
        setAppearance(data.prefs.appearance);
        setAccent(data.prefs.accent ?? '');
        setScale(data.prefs.uiScale);
        setMuted(data.prefs.callsMuted);
    }, [data]);

    const level = data?.level.n ?? 1;
    const bioMax = cfg?.bioMax ?? 280;
    const bioLines = cfg?.bioLines ?? 3;
    const scaleRange = cfg?.uiScale ?? [0.85, 1.25, 1];
    const presets = useMemo(() => (Array.isArray(cfg?.presets) ? cfg.presets : []), [cfg]);
    const accents = Array.isArray(cfg?.accents) ? cfg.accents : [];
    const appearances = Array.isArray(cfg?.appearances) ? cfg.appearances : ['department'];
    const cooldown = data?.nextEditIn ?? 0;
    const lines = bio.split('\n').length;
    const bioInvalid = [...bio].length > bioMax || lines > bioLines;

    // Only what changed goes to the server; picture and bio share the edit cooldown, the look does not.
    function buildPayload(): ProfileSetPayload | null {
        if (!data) return null;
        const out: ProfileSetPayload = {};
        const cur = data.avatar;
        if (kind === 'initials' && cur.kind !== 'initials') out.avatar = { kind: 'initials' };
        if (kind === 'preset' && preset && (cur.kind !== 'preset' || cur.value !== preset)) {
            out.avatar = { kind: 'preset', value: preset };
        }
        if (kind === 'url' && url.trim() !== '' && url.trim() !== (data.pending?.value ?? cur.value ?? '')) {
            out.avatar = { kind: 'url', value: url.trim() };
        }
        const oldBio = data.bioPending ?? data.bio ?? '';
        if (bio.trim() !== oldBio.trim()) out.bio = bio.trim() === '' ? false : bio;
        if (appearance !== data.prefs.appearance) out.appearance = appearance;
        if ((accent || null) !== (data.prefs.accent ?? null)) out.accent = accent === '' ? false : accent;
        if (Math.abs(scale - data.prefs.uiScale) > 0.001) out.uiScale = scale;
        if (muted !== data.prefs.callsMuted) out.callsMuted = muted;
        return out;
    }

    const payload = buildPayload();
    const changed = !!payload && Object.keys(payload).length > 0;
    const contentChanged = !!payload && (payload.avatar !== undefined || payload.bio !== undefined);

    async function save() {
        if (!payload || !changed) return;
        const res = await run<{ pending?: { avatar: boolean; bio: boolean } }>('server:profile:set', payload);
        if (!res.ok) return;
        // a new link or bio that needs approval says so; everything else is saved at once
        const waits = !!(res.data?.pending?.avatar || res.data?.pending?.bio);
        toast('success', t(waits ? 'profile.edit.saved_pending' : 'profile.edit.saved'));
        onSaved?.();
        onClose();
    }

    const tabs = [
        { key: 'picture' as const, label: t('profile.edit.tab.picture'), icon: 'user' as const },
        { key: 'bio' as const, label: t('profile.edit.tab.bio'), icon: 'fileText' as const },
        { key: 'look' as const, label: t('profile.edit.tab.look'), icon: 'eye' as const },
    ];
    const kinds = [
        { key: 'initials' as const, label: t('profile.edit.kind.initials') },
        { key: 'preset' as const, label: t('profile.edit.kind.preset') },
        ...(cfg?.urls ? [{ key: 'url' as const, label: t('profile.edit.kind.url') }] : []),
    ];
    const preview: AvatarData = {
        kind,
        value: kind === 'preset' ? preset || null : kind === 'url' ? (data?.avatar.value ?? null) : null,
        initials: data?.avatar.initials ?? '?',
        frame: data?.avatar.frame ?? 'grey',
    };

    return (
        <Dialog
            open={open}
            onClose={onClose}
            title={t('profile.edit.title')}
            description={t('profile.edit.description')}
            size="md"
            className="profile-edit"
            footer={
                <>
                    <Button variant="ghost" onClick={onClose}>
                        {t('common.cancel')}
                    </Button>
                    <Button
                        variant="primary"
                        icon="check"
                        onClick={() => void save()}
                        loading={busy}
                        disabled={!changed || bioInvalid || (contentChanged && cooldown > 0)}
                    >
                        {t('profile.edit.save')}
                    </Button>
                </>
            }
        >
            {!data && loading ? (
                <LoadingBlock />
            ) : !data ? (
                <ErrorState error={error ?? 'err.internal'} onRetry={() => void refetch()} />
            ) : (
                <div className="profile-edit__body">
                    <Tabs items={tabs} value={tab} onChange={setTab} aria-label={t('profile.edit.title')} />
                    {contentChanged && cooldown > 0 ? (
                        <p className="profile-edit__note is-warning">
                            <Icon name="clock" size={14} />
                            {t('profile.edit.cooldown', { time: formatDuration(cooldown) })}
                        </p>
                    ) : null}

                    {tab === 'picture' ? (
                        <div className="profile-edit__section">
                            <div className="profile-edit__preview">
                                <Avatar avatar={preview} size={72} />
                                <SegmentedControl
                                    items={kinds}
                                    value={kind}
                                    onChange={setKind}
                                    size="sm"
                                    aria-label={t('profile.edit.tab.picture')}
                                />
                            </div>
                            {kind === 'preset' ? (
                                <div className="profile-edit__presets" role="radiogroup">
                                    {presets.map(p => {
                                        const locked = p.level !== null && p.level !== undefined && level < p.level;
                                        return (
                                            <button
                                                key={p.id}
                                                type="button"
                                                role="radio"
                                                aria-checked={preset === p.id}
                                                disabled={locked}
                                                className={cx(
                                                    'profile-edit__preset',
                                                    preset === p.id && 'is-selected',
                                                    locked && 'is-locked',
                                                )}
                                                title={
                                                    locked
                                                        ? t('profile.edit.unlocks_at', { level: p.level as number })
                                                        : undefined
                                                }
                                                onClick={() => setPreset(p.id)}
                                            >
                                                {AVATAR_PRESETS[p.id] ? (
                                                    <img src={AVATAR_PRESETS[p.id]} alt="" draggable={false} />
                                                ) : (
                                                    <Icon name="user" size={20} />
                                                )}
                                                {locked ? (
                                                    <span className="profile-edit__lock">
                                                        <Icon name="lock" size={11} />{' '}
                                                        {t('profile.edit.lv', { n: p.level as number })}
                                                    </span>
                                                ) : null}
                                            </button>
                                        );
                                    })}
                                </div>
                            ) : null}
                            {kind === 'url' ? (
                                <Field
                                    label={t('profile.edit.url')}
                                    hint={t('profile.edit.url_hint', { n: data.urlsLeftToday })}
                                >
                                    <TextInput
                                        value={url}
                                        onChange={setUrl}
                                        placeholder="https://r2.fivemanage.com/…/picture.png"
                                        maxLength={255}
                                    />
                                </Field>
                            ) : null}
                            {data.pending?.status === 'pending' ? (
                                <p className="profile-edit__note">
                                    <Icon name="clock" size={14} />
                                    {t('profile.edit.pending_picture')}
                                </p>
                            ) : data.pending?.status === 'rejected' ? (
                                <p className="profile-edit__note is-warning">
                                    <Icon name="xCircle" size={14} />
                                    {t('profile.edit.rejected_picture')}
                                </p>
                            ) : null}
                        </div>
                    ) : null}

                    {tab === 'bio' ? (
                        <div className="profile-edit__section">
                            <Field
                                label={t('profile.edit.bio')}
                                hint={t('profile.edit.bio_hint', { max: bioMax, lines: bioLines })}
                                error={lines > bioLines ? t('err.bio_lines') : undefined}
                            >
                                <Textarea value={bio} onChange={setBio} maxLength={bioMax} rows={4} />
                            </Field>
                            <p className="profile-edit__note">
                                <Icon name="eye" size={14} />
                                {t('profile.edit.visible')}
                            </p>
                            {data.bioPending ? (
                                <p className="profile-edit__note">
                                    <Icon name="clock" size={14} />
                                    {t('profile.edit.pending_bio')}
                                </p>
                            ) : null}
                        </div>
                    ) : null}

                    {tab === 'look' ? (
                        <div className="profile-edit__section">
                            <Field label={t('profile.edit.appearance')} hint={t('profile.edit.appearance_hint')}>
                                <Select
                                    value={appearance}
                                    onChange={setAppearance}
                                    options={appearances.map(a => ({ value: a, label: appearanceLabel(a) }))}
                                />
                            </Field>
                            <Field label={t('profile.edit.accent')} hint={t('profile.edit.accent_hint')}>
                                <div className="profile-edit__accents" role="radiogroup">
                                    <button
                                        type="button"
                                        role="radio"
                                        aria-checked={accent === ''}
                                        className={cx(
                                            'profile-edit__swatch is-default',
                                            accent === '' && 'is-selected',
                                        )}
                                        title={t('profile.edit.accent_department')}
                                        onClick={() => setAccent('')}
                                    >
                                        <Icon name="building" size={14} />
                                    </button>
                                    {accents.map(a => {
                                        const locked = a.level !== null && a.level !== undefined && level < a.level;
                                        return (
                                            <button
                                                key={a.colour}
                                                type="button"
                                                role="radio"
                                                aria-checked={accent === a.colour}
                                                disabled={locked}
                                                className={cx(
                                                    'profile-edit__swatch',
                                                    accent === a.colour && 'is-selected',
                                                    locked && 'is-locked',
                                                )}
                                                style={{ background: a.colour }}
                                                title={
                                                    locked
                                                        ? t('profile.edit.unlocks_at', { level: a.level as number })
                                                        : a.colour
                                                }
                                                onClick={() => setAccent(a.colour)}
                                            >
                                                {locked ? <Icon name="lock" size={12} /> : null}
                                            </button>
                                        );
                                    })}
                                </div>
                            </Field>
                            <Field
                                label={t('profile.edit.scale')}
                                hint={t('profile.edit.scale_hint', { value: Math.round(scale * 100) })}
                            >
                                <input
                                    className="profile-edit__range"
                                    type="range"
                                    min={Math.round(scaleRange[0] * 100)}
                                    max={Math.round(scaleRange[1] * 100)}
                                    step={5}
                                    value={Math.round(scale * 100)}
                                    onChange={e => setScale(Number(e.target.value) / 100)}
                                />
                            </Field>
                            <Toggle
                                checked={muted}
                                onChange={setMuted}
                                label={t('profile.edit.mute')}
                                description={t('profile.edit.mute_hint')}
                            />
                            <Badge tone="neutral" size="sm" icon="info">
                                {t('profile.edit.look_own')}
                            </Badge>
                        </div>
                    ) : null}
                </div>
            )}
        </Dialog>
    );
}

export default ProfileEditDialog;
