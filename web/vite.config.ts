import { readFileSync } from 'node:fs';
import react from '@vitejs/plugin-react';
import { defineConfig } from 'vitest/config';

// Where `npm run dev` and `npm run preview` forward API calls. Defaults to a server running on
// this machine; point it elsewhere with LRRP_SERVER_URL=http://<host>:8787.
const serverUrl = process.env.LRRP_SERVER_URL ?? 'http://localhost:8787';

// The dashboard shows its own version next to the server's.
const { version } = JSON.parse(
  readFileSync(new URL('./package.json', import.meta.url), 'utf8'),
) as { version: string };

export default defineConfig({
  // Relative asset URLs, so the built dashboard also works when a reverse proxy serves the
  // server under a sub-path. The API client uses relative URLs and hash routes for the same
  // reason.
  base: './',
  plugins: [react()],
  define: {
    __APP_VERSION__: JSON.stringify(version),
  },
  server: {
    // `vite preview` uses the same proxy table.
    proxy: {
      '/api': serverUrl,
      '/healthz': serverUrl,
    },
  },
  build: {
    outDir: 'dist',
  },
  test: {
    environment: 'jsdom',
    include: ['src/**/*.test.{ts,tsx}'],
    setupFiles: ['./src/test/setup.ts'],
    restoreMocks: true,
  },
});
