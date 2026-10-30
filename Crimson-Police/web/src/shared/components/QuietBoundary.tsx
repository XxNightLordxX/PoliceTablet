// An error boundary that drops only the broken part (it renders nothing) and says so in the NUI console, so a crashed
// HUD, result card, overlay or toast list never unmounts the whole NUI. onError lets the tablet hand the focus back.

import { Component, type ErrorInfo, type ReactNode } from 'react';

interface Props {
    name: string;
    children: ReactNode;
    resetKey?: unknown; // Changing it clears the error (e.g. the next HUD or result).
    onError?: (error: Error) => void;
    retryMs?: number; // Mount the part again this long after an error (the NUI root), at most MAX_RETRIES times.
    onRetry?: () => void;
}
interface State {
    error: Error | null;
}

const MAX_RETRIES = 3;

export class QuietBoundary extends Component<Props, State> {
    state: State = { error: null };
    private retryTimer: ReturnType<typeof setTimeout> | null = null;
    private retries = 0;

    static getDerivedStateFromError(error: Error): State {
        return { error };
    }

    componentDidCatch(error: Error, info: ErrorInfo) {
        console.error(`[crimson-police:ui] ${this.props.name} crashed`, error, info.componentStack);
        try {
            this.props.onError?.(error);
        } catch (e) {
            console.error(`[crimson-police:ui] ${this.props.name}: onError failed`, e);
        }
        const ms = this.props.retryMs;
        if (!ms || ms <= 0 || this.retryTimer || this.retries >= MAX_RETRIES) return;
        this.retries += 1;
        this.retryTimer = setTimeout(() => {
            this.retryTimer = null;
            this.setState({ error: null });
            this.props.onRetry?.();
        }, ms);
    }

    componentDidUpdate(prev: Props) {
        if (prev.resetKey !== this.props.resetKey && this.state.error) this.setState({ error: null });
    }

    componentWillUnmount() {
        if (this.retryTimer) clearTimeout(this.retryTimer);
    }

    render() {
        return this.state.error ? null : this.props.children;
    }
}
