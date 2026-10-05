// The own profile's Look card: appearance, personal accent, tablet size and call alerts, as saved on cp_officers.
// They apply to the officer's own tablet only. Callback getProfileEdit; editing opens the Edit profile dialog.

import { Badge, Button, Card, LoadingBlock, Stat } from '../../shared/components';
import { useRequest } from '../../shared/hooks';
import { hasKey, t } from '../../shared/i18n';
import type { ProfileEdit } from '../../types/profile';
import './ProfileCards.css';

export interface LookCardProps {
    // bumped after a save, so the card reads the saved look again
    version: number;
    onEdit: () => void;
}

export function LookCard({ version, onEdit }: LookCardProps) {
    const { data, loading } = useRequest<ProfileEdit>('getProfileEdit', { v: version });
    const prefs = data?.prefs;
    const appearance = prefs?.appearance ?? 'department';
    return (
        <Card
            title={t('profile.look.title')}
            icon="eye"
            padding="md"
            className="profile-look"
            actions={
                <Button size="sm" variant="ghost" icon="edit" onClick={onEdit}>
                    {t('profile.edit.button')}
                </Button>
            }
        >
            {!prefs && loading ? (
                <LoadingBlock />
            ) : !prefs ? null : (
                <div className="profile-service__grid is-compact">
                    <Stat
                        size="sm"
                        label={t('profile.edit.appearance')}
                        value={
                            hasKey(`profile.edit.appearance.${appearance}`)
                                ? t(`profile.edit.appearance.${appearance}`)
                                : appearance
                        }
                    />
                    <Stat
                        size="sm"
                        label={t('profile.edit.accent')}
                        value={
                            prefs.accent ? (
                                <span className="profile-look__accent">
                                    <span className="profile-look__swatch" style={{ background: prefs.accent }} />
                                    {prefs.accent}
                                </span>
                            ) : (
                                t('profile.edit.accent_department')
                            )
                        }
                    />
                    <Stat size="sm" label={t('profile.edit.scale')} value={`${Math.round(prefs.uiScale * 100)}%`} />
                    <Stat
                        size="sm"
                        label={t('profile.look.calls')}
                        value={t(prefs.callsMuted ? 'profile.look.muted' : 'profile.look.on')}
                    />
                </div>
            )}
            <Badge tone="neutral" size="sm" icon="info">
                {t('profile.edit.look_own')}
            </Badge>
        </Card>
    );
}

export default LookCard;
