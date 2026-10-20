import { Component, type ErrorInfo, type ReactNode } from 'react';
import { t } from '../i18n';
import { EmptyState } from './Feedback';
import { Button } from './Button';

interface Props {
    children: ReactNode;
    resetKey?: unknown; // Changing it clears the error (e.g. the screen key).
}
interface State {
    error: Error | null;
}

// Keeps one broken screen from taking the whole tablet down.
export class ErrorBoundary extends Component<Props, State> {
    state: State = { error: null };

    static getDerivedStateFromError(error: Error): State {
        return { error };
    }

    componentDidCatch(error: Error, info: ErrorInfo) {
        console.error('[crimson-police:ui] screen crashed', error, info.componentStack);
    }

    componentDidUpdate(prev: Props) {
        if (prev.resetKey !== this.props.resetKey && this.state.error) this.setState({ error: null });
    }

    render() {
        if (!this.state.error) return this.props.children;
        return (
            <EmptyState
                icon="alert"
                className="cp-empty--error"
                title={t('ui.screen_error')}
                text={this.state.error.message}
                action={
                    <Button size="sm" icon="refresh" onClick={() => this.setState({ error: null })}>
                        {t('common.retry')}
                    </Button>
                }
            />
        );
    }
}
