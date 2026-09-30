import { createRoot } from 'react-dom/client';
import App from './App';
import { QuietBoundary } from './shared/components';
import { clientAction, fetchNui, isEnvBrowser } from './shared/nui';
import { applyTheme, DEFAULT_THEME } from './shared/theme';
import './styles/base.css';
import './styles/components.css';
import './styles/layouts.css';
import './styles/hud.css';

async function boot() {
    // Browser dev mode: register every src/mocks/*.mock.ts before the first request. Never in FiveM.
    if (isEnvBrowser()) await import('./mocks');
    applyTheme(document.documentElement, DEFAULT_THEME);
    const el = document.getElementById('root');
    // The last line of defence: whatever still escapes hands the NUI focus back (Lua closes the tablet and the test
    // panel), and the app mounts again with a fresh state a moment later (Lua sends the HUD, overlay and theme again
    // on 'ready').
    if (el) {
        createRoot(el).render(
            <QuietBoundary
                name="app"
                onError={() => {
                    void fetchNui('close', {});
                    void clientAction('testPanel', { open: false });
                }}
                retryMs={2000}
                onRetry={() => setTimeout(() => void fetchNui('ready', { acks: true }), 250)}
            >
                <App />
            </QuietBoundary>,
        );
    }
}

void boot();
