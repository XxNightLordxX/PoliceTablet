import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// FiveM loads the build as ui_page web/dist/index.html (nui://Crimson-Police/...), so every
// asset path must be relative (base './'). No external URLs anywhere: the game may be offline.
export default defineConfig({
  base: './',
  plugins: [react()],
  build: {
    outDir: 'dist',
    target: 'es2020',
    emptyOutDir: true,
    assetsInlineLimit: 8192,
    chunkSizeWarningLimit: 1500,
  },
  server: {
    // The UI imports locale parts from ../locales/parts (outside web/).
    fs: { allow: ['..'] },
  },
});
