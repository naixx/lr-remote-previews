import react from '@vitejs/plugin-react';
import { defineConfig } from 'vitest/config';

// Where `npm run dev` and `npm run preview` forward API calls. Defaults to a server running on
// this machine; point it elsewhere with LRRP_SERVER_URL=http://<host>:8787.
const serverUrl = process.env.LRRP_SERVER_URL ?? 'http://localhost:8787';

export default defineConfig({
  // Relative asset URLs, so the built dashboard also works when a reverse proxy serves the
  // server under a sub-path. The API client uses relative URLs for the same reason.
  base: './',
  plugins: [react()],
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
