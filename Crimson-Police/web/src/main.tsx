import { createRoot } from 'react-dom/client';
import App from './App';
import { isEnvBrowser } from './shared/nui';
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
  if (el) createRoot(el).render(<App />);
}

void boot();
