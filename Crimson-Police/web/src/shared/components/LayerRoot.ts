import { createContext } from 'react';

// The element dialogs and dropdown lists render into (the tablet screen or the admin panel), so they scale and theme
// with it.
export const LayerRootContext = createContext<HTMLElement | null>(null);
