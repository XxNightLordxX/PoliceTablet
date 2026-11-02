// The loading, error, empty and stale lines of an officer screen, one look on every screen.

import { Button, EmptyState, ErrorState, Icon, LoadingBlock } from '../../shared/components';
import { t } from '../../shared/i18n';
import type { ScreenState } from '../screens/screenHead';
import './ScreenStatus.css';

export function ScreenStatus({
    state,
    error,
    onRetry,
    loadingText,
}: {
    state: ScreenState;
    error?: string | null;
    onRetry: () => void;
    // the line under the spinner (Profile, Leaderboard); none = the spinner alone
    loadingText?: string;
}) {
    if (state === 'loading') return <LoadingBlock text={loadingText} />;
    if (state === 'error') return <ErrorState error={error} onRetry={onRetry} />;
    if (state === 'empty') {
        return (
            <EmptyState
                icon="inbox"
                title={t('ui.state.empty_title')}
                text={t('ui.state.empty_text')}
                action={
                    <Button variant="secondary" size="sm" icon="refresh" onClick={onRetry}>
                        {t('common.retry')}
                    </Button>
                }
            />
        );
    }
    if (state === 'stale') {
        return (
            <div className="cp-screen-stale" role="status">
                <Icon name="alert" size={14} />
                <span>{t('ui.state.stale')}</span>
                <Button variant="ghost" size="sm" icon="refresh" onClick={onRetry}>
                    {t('common.retry')}
                </Button>
            </div>
        );
    }
    return null;
}
